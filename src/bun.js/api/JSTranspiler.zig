const JSTranspiler = @This();

pub const js = jsc.Codegen.JSTranspiler;
pub const toJS = js.toJS;
pub const fromJS = js.fromJS;
pub const fromJSDirect = js.fromJSDirect;

transpiler: bun.transpiler.Transpiler,
arena: bun.ArenaAllocator,
transpiler_options: TranspilerOptions,
scan_pass_result: ScanPassResult,
buffer_writer: ?JSPrinter.BufferWriter = null,
log_level: logger.Log.Level = .err,

const default_transform_options: api.TransformOptions = brk: {
    var opts = std.mem.zeroes(api.TransformOptions);
    opts.disable_hmr = true;
    opts.target = api.Target.browser;
    break :brk opts;
};

const TranspilerOptions = struct {
    transform: api.TransformOptions = default_transform_options,
    default_loader: options.Loader = options.Loader.jsx,
    macro_map: MacroMap = MacroMap{},
    tsconfig: ?*TSConfigJSON = null,
    tsconfig_buf: []const u8 = "",
    macros_buf: []const u8 = "",
    log: logger.Log,
    runtime: Runtime.Features = Runtime.Features{ .top_level_await = true },
    tree_shaking: bool = false,
    trim_unused_imports: ?bool = null,
    inlining: bool = false,

    dead_code_elimination: bool = true,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    no_macros: bool = false,
};

// Mimalloc gets unstable if we try to move this to a different thread
// threadlocal var transform_buffer: bun.MutableString = undefined;
// threadlocal var transform_buffer_loaded: bool = false;

// This is going to be hard to not leak
pub const TransformTask = struct {
    input_code: jsc.Node.StringOrBuffer = jsc.Node.StringOrBuffer{ .buffer = .{} },
    output_code: bun.String = bun.String.empty,
    transpiler: Transpiler.Transpiler = undefined,
    log: logger.Log,
    err: ?anyerror = null,
    macro_map: MacroMap = MacroMap{},
    tsconfig: ?*TSConfigJSON = null,
    loader: Loader,
    global: *JSGlobalObject,
    replace_exports: Runtime.Features.ReplaceableExport.Map = .{},

    pub const new = bun.TrivialNew(@This());

    pub const AsyncTransformTask = jsc.ConcurrentPromiseTask(TransformTask);
    pub const AsyncTransformEventLoopTask = AsyncTransformTask.EventLoopTask;

    pub fn create(transpiler: *JSTranspiler, input_code: bun.jsc.Node.StringOrBuffer, globalThis: *JSGlobalObject, loader: Loader) !*AsyncTransformTask {
        var transform_task = TransformTask.new(.{
            .input_code = input_code,
            .transpiler = undefined,
            .global = globalThis,
            .macro_map = transpiler.transpiler_options.macro_map,
            .tsconfig = transpiler.transpiler_options.tsconfig,
            .log = logger.Log.init(bun.default_allocator),
            .loader = loader,
            .replace_exports = transpiler.transpiler_options.runtime.replace_exports,
        });
        transform_task.log.level = transpiler.transpiler_options.log.level;
        transform_task.transpiler = transpiler.transpiler;
        transform_task.transpiler.linker.resolver = &transform_task.transpiler.resolver;

        transform_task.transpiler.setLog(&transform_task.log);
        transform_task.transpiler.setAllocator(bun.default_allocator);
        return try AsyncTransformTask.createOnJSThread(bun.default_allocator, globalThis, transform_task);
    }

    pub fn run(this: *TransformTask) void {
        const name = this.loader.stdinName();
        const source = logger.Source.initPathString(name, this.input_code.slice());

        var arena = MimallocArena.init() catch unreachable;
        defer arena.deinit();

        const allocator = arena.allocator();
        var ast_memory_allocator = allocator.create(JSAst.ASTMemoryAllocator) catch bun.outOfMemory();
        var ast_scope = ast_memory_allocator.enter(allocator);
        defer ast_scope.exit();

        this.transpiler.setAllocator(allocator);
        this.transpiler.setLog(&this.log);
        this.log.msgs.allocator = bun.default_allocator;

        const jsx = if (this.tsconfig != null)
            this.tsconfig.?.mergeJSX(this.transpiler.options.jsx)
        else
            this.transpiler.options.jsx;

        const parse_options = Transpiler.Transpiler.ParseOptions{
            .allocator = allocator,
            .macro_remappings = this.macro_map,
            .dirname_fd = .invalid,
            .file_descriptor = null,
            .loader = this.loader,
            .jsx = jsx,
            .path = source.path,
            .virtual_source = &source,
            .replace_exports = this.replace_exports,
            // .allocator = this.
        };

        const parse_result = this.transpiler.parse(parse_options, null) orelse {
            this.err = error.ParseError;
            return;
        };

        if (parse_result.empty) {
            this.output_code = bun.String.empty;
            return;
        }

        var buffer_writer = JSPrinter.BufferWriter.init(allocator);
        buffer_writer.buffer.list.ensureTotalCapacity(allocator, 512) catch unreachable;
        buffer_writer.reset();

        // defer {
        //     transform_buffer = buffer_writer.buffer;
        // }

        var printer = JSPrinter.BufferPrinter.init(buffer_writer);
        const printed = this.transpiler.print(parse_result, @TypeOf(&printer), &printer, .esm_ascii) catch |err| {
            this.err = err;
            return;
        };

        if (printed > 0) {
            buffer_writer = printer.ctx;
            buffer_writer.buffer.list.items = buffer_writer.written;
            this.output_code = bun.String.cloneUTF8(buffer_writer.written);
        } else {
            this.output_code = bun.String.empty;
        }
    }

    pub fn then(this: *TransformTask, promise: *jsc.JSPromise) void {
        if (this.log.hasAny() or this.err != null) {
            const error_value: bun.OOM!JSValue = brk: {
                if (this.err) |err| {
                    if (!this.log.hasAny()) {
                        break :brk bun.api.BuildMessage.create(
                            this.global,
                            bun.default_allocator,
                            logger.Msg{
                                .data = logger.Data{ .text = bun.asByteSlice(@errorName(err)) },
                            },
                        );
                    }
                }

                break :brk this.log.toJS(this.global, bun.default_allocator, "Transform failed") catch return; // TODO: properly propagate exception upwards
            };

            promise.reject(this.global, error_value);
            return;
        }

        const global = this.global;
        const code = this.output_code;
        this.output_code = bun.String.empty;
        this.deinit();

        finish(code, global, promise);
    }

    noinline fn finish(code: bun.String, global: *JSGlobalObject, promise: *jsc.JSPromise) void {
        promise.resolve(global, code.toJS(global));
        code.deref();
    }

    pub fn deinit(this: *TransformTask) void {
        this.log.deinit();
        this.input_code.deinitAndUnprotect();
        this.output_code.deref();
        if (this.tsconfig) |tsconfig| {
            tsconfig.deinit();
        }
        bun.destroy(this);
    }
};

fn exportReplacementValue(value: JSValue, globalThis: *JSGlobalObject) bun.JSError!?JSAst.Expr {
    if (value.isBoolean()) {
        return Expr{
            .data = .{
                .e_boolean = .{
                    .value = value.toBoolean(),
                },
            },
            .loc = logger.Loc.Empty,
        };
    }

    if (value.isNumber()) {
        return Expr{
            .data = .{
                .e_number = .{ .value = value.asNumber() },
            },
            .loc = logger.Loc.Empty,
        };
    }

    if (value.isNull()) {
        return Expr{
            .data = .{
                .e_null = .{},
            },
            .loc = logger.Loc.Empty,
        };
    }

    if (value.isUndefined()) {
        return Expr{
            .data = .{
                .e_undefined = .{},
            },
            .loc = logger.Loc.Empty,
        };
    }

    if (value.isString()) {
        const str = JSAst.E.String{
            .data = try std.fmt.allocPrint(bun.default_allocator, "{}", .{try value.getZigString(globalThis)}),
        };
        const out = try bun.default_allocator.create(JSAst.E.String);
        out.* = str;
        return Expr{
            .data = .{
                .e_string = out,
            },
            .loc = logger.Loc.Empty,
        };
    }

    return null;
}

fn transformOptionsFromJSC(globalObject: *jsc.JSGlobalObject, temp_allocator: std.mem.Allocator, args: *jsc.CallFrame.ArgumentsSlice) (bun.JSError || bun.OOM)!TranspilerOptions {
    const globalThis = globalObject;
    const object = args.next() orelse return TranspilerOptions{ .log = logger.Log.init(temp_allocator) };
    if (object.isUndefinedOrNull()) return TranspilerOptions{ .log = logger.Log.init(temp_allocator) };

    args.eat();
    var allocator = args.arena.allocator();

    var transpiler = TranspilerOptions{
        .default_loader = .jsx,
        .transform = default_transform_options,
        .log = logger.Log.init(allocator),
    };

    if (!object.isObject()) {
        return globalObject.throwInvalidArguments("Expected an object", .{});
    }

    if (try object.getTruthy(globalObject, "define")) |define| {
        define: {
            if (define.isUndefinedOrNull()) {
                break :define;
            }

            const define_obj = define.getObject() orelse {
                return globalObject.throwInvalidArguments("define must be an object", .{});
            };

            var define_iter = try jsc.JSPropertyIterator(.{
                .skip_empty_name = true,

                .include_value = true,
            }).init(globalThis, define_obj);
            defer define_iter.deinit();

            // cannot be a temporary because it may be loaded on different threads.
            var map_entries = allocator.alloc([]u8, define_iter.len * 2) catch unreachable;
            var names = map_entries[0..define_iter.len];

            var values = map_entries[define_iter.len..];

            while (try define_iter.next()) |prop| {
                const property_value = define_iter.value;
                const value_type = property_value.jsType();

                if (!value_type.isStringLike()) {
                    return globalObject.throwInvalidArguments("define \"{s}\" must be a JSON string", .{prop});
                }

                names[define_iter.i] = prop.toOwnedSlice(allocator) catch unreachable;
                var val = jsc.ZigString.init("");
                try property_value.toZigString(&val, globalThis);
                if (val.len == 0) {
                    val = jsc.ZigString.init("\"\"");
                }
                values[define_iter.i] = std.fmt.allocPrint(allocator, "{}", .{val}) catch unreachable;
            }

            transpiler.transform.define = api.StringMap{
                .keys = names,
                .values = values,
            };
        }
    }

    if (try object.get(globalThis, "external")) |external| {
        external: {
            if (external.isUndefinedOrNull()) break :external;

            const toplevel_type = external.jsType();
            if (toplevel_type.isStringLike()) {
                var zig_str = jsc.ZigString.init("");
                try external.toZigString(&zig_str, globalThis);
                if (zig_str.len == 0) break :external;
                var single_external = allocator.alloc(string, 1) catch unreachable;
                single_external[0] = std.fmt.allocPrint(allocator, "{}", .{zig_str}) catch unreachable;
                transpiler.transform.external = single_external;
            } else if (toplevel_type.isArray()) {
                const count = try external.getLength(globalThis);
                if (count == 0) break :external;

                var externals = allocator.alloc(string, count) catch unreachable;
                var iter = try external.arrayIterator(globalThis);
                var i: usize = 0;
                while (try iter.next()) |entry| {
                    if (!entry.jsType().isStringLike()) {
                        return globalObject.throwInvalidArguments("external must be a string or string[]", .{});
                    }

                    var zig_str = jsc.ZigString.init("");
                    try entry.toZigString(&zig_str, globalThis);
                    if (zig_str.len == 0) continue;
                    externals[i] = std.fmt.allocPrint(allocator, "{}", .{zig_str}) catch unreachable;
                    i += 1;
                }

                transpiler.transform.external = externals[0..i];
            } else {
                return globalObject.throwInvalidArguments("external must be a string or string[]", .{});
            }
        }
    }

    if (try object.get(globalThis, "loader")) |loader| {
        if (try Loader.fromJS(globalThis, loader)) |resolved| {
            if (!resolved.isJavaScriptLike()) {
                return globalObject.throwInvalidArguments("only JavaScript-like loaders supported for now", .{});
            }

            transpiler.default_loader = resolved;
        }
    }

    if (try object.get(globalThis, "target")) |target| {
        if (try Target.fromJS(globalThis, target)) |resolved| {
            transpiler.transform.target = resolved.toAPI();
        }
    }

    if (try object.get(globalThis, "tsconfig")) |tsconfig| {
        tsconfig: {
            if (tsconfig.isUndefinedOrNull()) break :tsconfig;
            const kind = tsconfig.jsType();
            var out = bun.String.empty;
            defer out.deref();

            if (kind.isArray()) {
                return globalObject.throwInvalidArguments("tsconfig must be a string or object", .{});
            }

            if (!kind.isStringLike()) {
                try tsconfig.jsonStringify(globalThis, 0, &out);
            } else {
                out = try tsconfig.toBunString(globalThis);
            }

            if (out.isEmpty()) break :tsconfig;
            transpiler.tsconfig_buf = out.toOwnedSlice(allocator) catch bun.outOfMemory();

            // TODO: JSC -> Ast conversion
            if (TSConfigJSON.parse(
                allocator,
                &transpiler.log,
                &logger.Source.initPathString("tsconfig.json", transpiler.tsconfig_buf),
                &jsc.VirtualMachine.get().transpiler.resolver.caches.json,
            ) catch null) |parsed_tsconfig| {
                transpiler.tsconfig = parsed_tsconfig;
            }
        }
    }

    transpiler.runtime.allow_runtime = false;

    if (try object.getTruthy(globalThis, "macro")) |macros| {
        macros: {
            if (macros.isUndefinedOrNull()) break :macros;
            if (macros.isBoolean()) {
                transpiler.no_macros = !macros.asBoolean();
                break :macros;
            }
            const kind = macros.jsType();
            const is_object = kind.isObject();
            if (!(kind.isStringLike() or is_object)) {
                return globalObject.throwInvalidArguments("macro must be an object", .{});
            }

            var out = bun.String.empty;
            defer out.deref();
            // TODO: write a converter between JSC types and Bun AST types
            if (is_object) {
                try macros.jsonStringify(globalThis, 0, &out);
            } else {
                out = try macros.toBunString(globalThis);
            }

            if (out.isEmpty()) break :macros;
            transpiler.macros_buf = out.toOwnedSlice(allocator) catch bun.outOfMemory();
            const source = &logger.Source.initPathString("macros.json", transpiler.macros_buf);
            const json = (jsc.VirtualMachine.get().transpiler.resolver.caches.json.parseJSON(
                &transpiler.log,
                source,
                allocator,
                .json,
                false,
            ) catch null) orelse break :macros;
            transpiler.macro_map = PackageJSON.parseMacrosJSON(allocator, json, &transpiler.log, source);
        }
    }

    if (try object.getBooleanLoose(globalThis, "autoImportJSX")) |flag| {
        transpiler.runtime.auto_import_jsx = flag;
    }

    if (try object.getBooleanLoose(globalThis, "allowBunRuntime")) |flag| {
        transpiler.runtime.allow_runtime = flag;
    }

    if (try object.getBooleanLoose(globalThis, "inline")) |flag| {
        transpiler.runtime.inlining = flag;
    }

    if (try object.getBooleanLoose(globalThis, "minifyWhitespace")) |flag| {
        transpiler.minify_whitespace = flag;
    }

    if (try object.getBooleanLoose(globalThis, "deadCodeElimination")) |flag| {
        transpiler.dead_code_elimination = flag;
    }

    if (try object.getTruthy(globalThis, "minify")) |minify| {
        if (minify.isBoolean()) {
            transpiler.minify_whitespace = minify.toBoolean();
            transpiler.minify_syntax = transpiler.minify_whitespace;
            transpiler.minify_identifiers = transpiler.minify_syntax;
        } else if (minify.isObject()) {
            if (try minify.getBooleanLoose(globalThis, "whitespace")) |whitespace| {
                transpiler.minify_whitespace = whitespace;
            }
            if (try minify.getBooleanLoose(globalThis, "syntax")) |syntax| {
                transpiler.minify_syntax = syntax;
            }
            if (try minify.getBooleanLoose(globalThis, "identifiers")) |syntax| {
                transpiler.minify_identifiers = syntax;
            }
        } else {
            return globalObject.throwInvalidArguments("Expected minify to be a boolean or an object", .{});
        }
    }

    if (try object.get(globalThis, "sourcemap")) |flag| {
        if (flag.isBoolean() or flag.isUndefinedOrNull()) {
            if (flag.toBoolean()) {
                transpiler.transform.source_map = .@"inline";
            } else {
                transpiler.transform.source_map = .none;
            }
        } else {
            if (try options.SourceMapOption.Map.fromJS(globalObject, flag)) |source| {
                transpiler.transform.source_map = source.toAPI();
            } else {
                return globalObject.throwInvalidArguments("sourcemap must be one of \"inline\", \"linked\", \"external\", or \"none\"", .{});
            }
        }
    }

    if (try object.getOptionalEnum(globalThis, "packages", options.PackagesOption)) |packages| {
        transpiler.transform.packages = packages.toAPI();
    }

    var tree_shaking: ?bool = null;
    if (try object.getBooleanLoose(globalThis, "treeShaking")) |treeShaking| {
        tree_shaking = treeShaking;
    }

    var trim_unused_imports: ?bool = null;
    if (try object.getBooleanLoose(globalThis, "trimUnusedImports")) |trimUnusedImports| {
        trim_unused_imports = trimUnusedImports;
    }

    if (try object.getTruthy(globalThis, "exports")) |exports| {
        if (!exports.isObject()) {
            return globalObject.throwInvalidArguments("exports must be an object", .{});
        }

        var replacements = Runtime.Features.ReplaceableExport.Map{};
        errdefer replacements.clearAndFree(bun.default_allocator);

        if (try exports.getTruthy(globalThis, "eliminate")) |eliminate| {
            if (!eliminate.jsType().isArray()) {
                return globalObject.throwInvalidArguments("exports.eliminate must be an array", .{});
            }

            var total_name_buf_len: u32 = 0;
            var string_count: u32 = 0;
            const iter = try jsc.JSArrayIterator.init(eliminate, globalThis);
            {
                var length_iter = iter;
                while (try length_iter.next()) |value| {
                    if (value.isString()) {
                        const length: u32 = @truncate(try value.getLength(globalThis));
                        string_count += @intFromBool(length > 0);
                        total_name_buf_len += length;
                    }
                }
            }

            if (total_name_buf_len > 0) {
                var buf = try std.ArrayListUnmanaged(u8).initCapacity(bun.default_allocator, total_name_buf_len);
                try replacements.ensureUnusedCapacity(bun.default_allocator, string_count);
                {
                    var length_iter = iter;
                    while (try length_iter.next()) |value| {
                        if (!value.isString()) continue;
                        const str = try value.getZigString(globalThis);
                        if (str.len == 0) continue;
                        const name = std.fmt.bufPrint(buf.items.ptr[buf.items.len..buf.capacity], "{}", .{str}) catch {
                            return globalObject.throwInvalidArguments("Error reading exports.eliminate. TODO: utf-16", .{});
                        };
                        buf.items.len += name.len;
                        if (name.len > 0) {
                            replacements.putAssumeCapacity(name, .{ .delete = {} });
                        }
                    }
                }
            }
        }

        if (try exports.getTruthy(globalThis, "replace")) |replace| {
            const replace_obj = replace.getObject() orelse {
                return globalObject.throwInvalidArguments("replace must be an object", .{});
            };

            var iter = try jsc.JSPropertyIterator(.{
                .skip_empty_name = true,
                .include_value = true,
            }).init(globalThis, replace_obj);
            defer iter.deinit();

            if (iter.len > 0) {
                try replacements.ensureUnusedCapacity(bun.default_allocator, iter.len);

                // We cannot set the exception before `try` because it could be
                // a double free with the `errdefer`.
                defer if (globalThis.hasException()) {
                    for (replacements.keys()) |key| {
                        bun.default_allocator.free(@constCast(key));
                    }
                    replacements.clearAndFree(bun.default_allocator);
                };

                while (try iter.next()) |key_| {
                    const value = iter.value;
                    if (value == .zero) continue;

                    const key = try key_.toOwnedSlice(bun.default_allocator);

                    if (!JSLexer.isIdentifier(key)) {
                        bun.default_allocator.free(key);
                        return globalObject.throwInvalidArguments("\"{s}\" is not a valid ECMAScript identifier", .{key});
                    }

                    const entry = replacements.getOrPutAssumeCapacity(key);

                    if (try exportReplacementValue(value, globalThis)) |expr| {
                        entry.value_ptr.* = .{ .replace = expr };
                        continue;
                    }

                    if (value.isObject() and try value.getLength(globalObject) == 2) {
                        const replacementValue = try value.getIndex(globalThis, 1);
                        if (try exportReplacementValue(replacementValue, globalThis)) |to_replace| {
                            const replacementKey = try value.getIndex(globalThis, 0);
                            var slice = (try (try replacementKey.toSlice(globalThis, bun.default_allocator)).cloneIfNeeded(bun.default_allocator));
                            const replacement_name = slice.slice();

                            if (!JSLexer.isIdentifier(replacement_name)) {
                                slice.deinit();
                                return globalObject.throwInvalidArguments("\"{s}\" is not a valid ECMAScript identifier", .{replacement_name});
                            }

                            entry.value_ptr.* = .{
                                .inject = .{
                                    .name = replacement_name,
                                    .value = to_replace,
                                },
                            };
                            continue;
                        }
                    }

                    return globalObject.throwInvalidArguments("exports.replace values can only be string, null, undefined, number or boolean", .{});
                }
            }
        }

        tree_shaking = tree_shaking orelse (replacements.count() > 0);
        transpiler.runtime.replace_exports = replacements;
    }

    if (try object.getTruthy(globalThis, "logLevel")) |logLevel| {
        if (try logger.Log.Level.Map.fromJS(globalObject, logLevel)) |level| {
            transpiler.log.level = level;
        } else {
            return globalObject.throwInvalidArguments("logLevel must be one of \"verbose\", \"debug\", \"info\", \"warn\", or \"error\"", .{});
        }
    }

    transpiler.tree_shaking = tree_shaking orelse false;
    transpiler.trim_unused_imports = trim_unused_imports orelse transpiler.tree_shaking;

    return transpiler;
}

pub fn constructor(globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!*JSTranspiler {
    var temp = bun.ArenaAllocator.init(bun.default_allocator);
    const arguments = callframe.arguments_old(3);
    var args = jsc.CallFrame.ArgumentsSlice.init(
        globalThis.bunVM(),
        arguments.slice(),
    );

    defer temp.deinit();
    const transpiler_options: TranspilerOptions = if (arguments.len > 0)
        try transformOptionsFromJSC(globalThis, temp.allocator(), &args)
    else
        TranspilerOptions{ .log = logger.Log.init(bun.default_allocator) };

    if (globalThis.hasException()) {
        return error.JSError;
    }

    const allocator = bun.default_allocator;

    if ((transpiler_options.log.warnings + transpiler_options.log.errors) > 0) {
        return globalThis.throwValue(try transpiler_options.log.toJS(globalThis, allocator, "Failed to create transpiler"));
    }

    var log = try allocator.create(logger.Log);
    log.* = transpiler_options.log;
    var transpiler = Transpiler.Transpiler.init(
        allocator,
        log,
        transpiler_options.transform,
        jsc.VirtualMachine.get().transpiler.env,
    ) catch |err| {
        if ((log.warnings + log.errors) > 0) {
            return globalThis.throwValue(try log.toJS(globalThis, allocator, "Failed to create transpiler"));
        }

        return globalThis.throwError(err, "Error creating transpiler");
    };
    transpiler.options.no_macros = transpiler_options.no_macros;
    transpiler.configureLinkerWithAutoJSX(false);
    transpiler.options.env.behavior = .disable;
    transpiler.configureDefines() catch |err| {
        if ((log.warnings + log.errors) > 0) {
            return globalThis.throwValue(try log.toJS(globalThis, allocator, "Failed to load define"));
        }
        return globalThis.throwError(err, "Failed to load define");
    };

    if (transpiler_options.macro_map.count() > 0) {
        transpiler.options.macro_remap = transpiler_options.macro_map;
    }

    transpiler.options.dead_code_elimination = transpiler_options.dead_code_elimination;
    transpiler.options.minify_whitespace = transpiler_options.minify_whitespace;

    // Keep defaults for these
    if (transpiler_options.minify_syntax)
        transpiler.options.minify_syntax = true;

    if (transpiler_options.minify_identifiers)
        transpiler.options.minify_identifiers = true;

    transpiler.options.transform_only = !transpiler.options.allow_runtime;

    transpiler.options.tree_shaking = transpiler_options.tree_shaking;
    transpiler.options.trim_unused_imports = transpiler_options.trim_unused_imports;
    transpiler.options.allow_runtime = transpiler_options.runtime.allow_runtime;
    transpiler.options.auto_import_jsx = transpiler_options.runtime.auto_import_jsx;
    transpiler.options.inlining = transpiler_options.runtime.inlining;
    transpiler.options.hot_module_reloading = transpiler_options.runtime.hot_module_reloading;
    transpiler.options.react_fast_refresh = false;

    const instance = try allocator.create(JSTranspiler);
    instance.* = JSTranspiler{
        .transpiler_options = transpiler_options,
        .transpiler = transpiler,
        .arena = args.arena,
        .scan_pass_result = ScanPassResult.init(allocator),
    };

    return instance;
}

pub fn finalize(this: *JSTranspiler) void {
    this.transpiler.log.deinit();
    this.scan_pass_result.named_imports.deinit(this.scan_pass_result.import_records.allocator);
    this.scan_pass_result.import_records.deinit();
    this.scan_pass_result.used_symbols.deinit();
    if (this.buffer_writer != null) {
        this.buffer_writer.?.buffer.deinit();
    }

    // bun.default_allocator.free(this.transpiler_options.tsconfig_buf);
    // bun.default_allocator.free(this.transpiler_options.macros_buf);
    this.arena.deinit();
    jsc.VirtualMachine.get().allocator.destroy(this);
}

fn getParseResult(this: *JSTranspiler, allocator: std.mem.Allocator, code: []const u8, loader: ?Loader, macro_js_ctx: Transpiler.MacroJSValueType) ?Transpiler.ParseResult {
    const name = this.transpiler_options.default_loader.stdinName();
    const source = &logger.Source.initPathString(name, code);

    const jsx = if (this.transpiler_options.tsconfig != null)
        this.transpiler_options.tsconfig.?.mergeJSX(this.transpiler.options.jsx)
    else
        this.transpiler.options.jsx;

    const parse_options = Transpiler.Transpiler.ParseOptions{
        .allocator = allocator,
        .macro_remappings = this.transpiler_options.macro_map,
        .dirname_fd = .invalid,
        .file_descriptor = null,
        .loader = loader orelse this.transpiler_options.default_loader,
        .jsx = jsx,
        .path = source.path,
        .virtual_source = source,
        .replace_exports = this.transpiler_options.runtime.replace_exports,
        .macro_js_ctx = macro_js_ctx,
        // .allocator = this.
    };

    return this.transpiler.parse(parse_options, null);
}

pub fn scan(this: *JSTranspiler, globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    jsc.markBinding(@src());
    const arguments = callframe.arguments_old(3);
    var args = jsc.CallFrame.ArgumentsSlice.init(globalThis.bunVM(), arguments.slice());
    defer args.deinit();
    const code_arg = args.next() orelse {
        return globalThis.throwInvalidArgumentType("scan", "code", "string or Uint8Array");
    };

    const code_holder = try jsc.Node.StringOrBuffer.fromJS(globalThis, args.arena.allocator(), code_arg) orelse {
        return globalThis.throwInvalidArgumentType("scan", "code", "string or Uint8Array");
    };
    defer code_holder.deinit();
    const code = code_holder.slice();
    args.eat();

    const loader: ?Loader = brk: {
        if (args.next()) |arg| {
            args.eat();
            break :brk try Loader.fromJS(globalThis, arg);
        }

        break :brk null;
    };

    if (globalThis.hasException()) {
        return .zero;
    }

    var arena = MimallocArena.init() catch unreachable;
    const prev_allocator = this.transpiler.allocator;
    const allocator = arena.allocator();
    this.transpiler.setAllocator(allocator);
    var log = logger.Log.init(arena.backingAllocator());
    defer log.deinit();
    this.transpiler.setLog(&log);
    defer {
        this.transpiler.setLog(&this.transpiler_options.log);
        this.transpiler.setAllocator(prev_allocator);
        arena.deinit();
    }
    var ast_memory_allocator = allocator.create(JSAst.ASTMemoryAllocator) catch bun.outOfMemory();
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    var parse_result = getParseResult(this, allocator, code, loader, Transpiler.MacroJSValueType.zero) orelse {
        if ((this.transpiler.log.warnings + this.transpiler.log.errors) > 0) {
            return globalThis.throwValue(try this.transpiler.log.toJS(globalThis, globalThis.allocator(), "Parse error"));
        }

        return globalThis.throw("Failed to parse", .{});
    };

    if ((this.transpiler.log.warnings + this.transpiler.log.errors) > 0) {
        return globalThis.throwValue(try this.transpiler.log.toJS(globalThis, globalThis.allocator(), "Parse error"));
    }

    const exports_label = jsc.ZigString.static("exports");
    const imports_label = jsc.ZigString.static("imports");
    const named_imports_value = try namedImportsToJS(
        globalThis,
        parse_result.ast.import_records.slice(),
    );

    const named_exports_value = try namedExportsToJS(
        globalThis,
        &parse_result.ast.named_exports,
    );
    return jsc.JSValue.createObject2(globalThis, imports_label, exports_label, named_imports_value, named_exports_value);
}

pub fn transform(this: *JSTranspiler, globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    jsc.markBinding(@src());
    const arguments = callframe.arguments_old(3);
    var args = jsc.CallFrame.ArgumentsSlice.init(globalThis.bunVM(), arguments.slice());
    defer args.arena.deinit();
    const code_arg = args.next() orelse {
        return globalThis.throwInvalidArgumentType("transform", "code", "string or Uint8Array");
    };

    const allow_string_object = true;
    var code = try jsc.Node.StringOrBuffer.fromJSWithEncodingMaybeAsync(globalThis, bun.default_allocator, code_arg, .utf8, true, allow_string_object) orelse {
        return globalThis.throwInvalidArgumentType("transform", "code", "string or Uint8Array");
    };
    errdefer code.deinit();

    args.eat();
    const loader: ?Loader = brk: {
        if (args.next()) |arg| {
            args.eat();
            break :brk try Loader.fromJS(globalThis, arg);
        }

        break :brk null;
    };

    if (code == .buffer) {
        code_arg.protect();
    }
    var task = TransformTask.create(
        this,
        code,
        globalThis,
        loader orelse this.transpiler_options.default_loader,
    ) catch {
        if (code == .buffer) {
            code_arg.unprotect();
        }
        globalThis.throwOutOfMemory();
        return error.JSError;
    };
    task.schedule();
    return task.promise.value();
}

pub fn transformSync(
    this: *JSTranspiler,
    globalThis: *jsc.JSGlobalObject,
    callframe: *jsc.CallFrame,
) bun.JSError!jsc.JSValue {
    jsc.markBinding(@src());
    const arguments = callframe.arguments_old(3);

    var args = jsc.CallFrame.ArgumentsSlice.init(globalThis.bunVM(), arguments.slice());
    defer args.arena.deinit();
    const code_arg = args.next() orelse {
        return globalThis.throwInvalidArgumentType("transformSync", "code", "string or Uint8Array");
    };

    var arena = MimallocArena.init() catch unreachable;
    defer arena.deinit();
    const code_holder = try jsc.Node.StringOrBuffer.fromJS(globalThis, arena.allocator(), code_arg) orelse {
        return globalThis.throwInvalidArgumentType("transformSync", "code", "string or Uint8Array");
    };
    defer code_holder.deinit();
    const code = code_holder.slice();
    arguments.ptr[0].ensureStillAlive();
    defer arguments.ptr[0].ensureStillAlive();

    args.eat();
    var js_ctx_value: jsc.JSValue = jsc.JSValue.zero;
    const loader: ?Loader = brk: {
        if (args.next()) |arg| {
            args.eat();
            if (arg.isNumber() or arg.isString()) {
                break :brk try Loader.fromJS(globalThis, arg);
            }

            if (arg.isObject()) {
                js_ctx_value = arg;
                break :brk null;
            }
        }

        break :brk null;
    };

    if (args.nextEat()) |arg| {
        if (arg.isObject()) {
            js_ctx_value = arg;
        } else {
            return globalThis.throwInvalidArgumentType("transformSync", "context", "object or loader");
        }
    }
    if (js_ctx_value != .zero) {
        js_ctx_value.ensureStillAlive();
    }

    defer {
        if (js_ctx_value != .zero) {
            js_ctx_value.ensureStillAlive();
        }
    }

    const allocator = arena.allocator();

    var ast_memory_allocator = allocator.create(JSAst.ASTMemoryAllocator) catch bun.outOfMemory();
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    const prev_bundler = this.transpiler;
    this.transpiler.setAllocator(allocator);
    this.transpiler.macro_context = null;
    var log = logger.Log.init(arena.backingAllocator());
    log.level = this.transpiler_options.log.level;
    this.transpiler.setLog(&log);

    defer {
        this.transpiler = prev_bundler;
    }
    const parse_result = getParseResult(
        this,
        allocator,
        code,
        loader,
        js_ctx_value,
    ) orelse {
        if ((this.transpiler.log.warnings + this.transpiler.log.errors) > 0) {
            return globalThis.throwValue(try this.transpiler.log.toJS(globalThis, globalThis.allocator(), "Parse error"));
        }

        return globalThis.throw("Failed to parse code", .{});
    };

    if ((this.transpiler.log.warnings + this.transpiler.log.errors) > 0) {
        return globalThis.throwValue(try this.transpiler.log.toJS(globalThis, globalThis.allocator(), "Parse error"));
    }

    var buffer_writer = this.buffer_writer orelse brk: {
        var writer = JSPrinter.BufferWriter.init(arena.backingAllocator());

        writer.buffer.growIfNeeded(code.len) catch unreachable;
        writer.buffer.list.expandToCapacity();
        break :brk writer;
    };

    defer {
        this.buffer_writer = buffer_writer;
    }

    buffer_writer.reset();
    var printer = JSPrinter.BufferPrinter.init(buffer_writer);
    _ = this.transpiler.print(parse_result, @TypeOf(&printer), &printer, .esm_ascii) catch |err| {
        return globalThis.throwError(err, "Failed to print code");
    };

    // TODO: benchmark if pooling this way is faster or moving is faster
    buffer_writer = printer.ctx;
    var out = jsc.ZigString.init(buffer_writer.written);
    out.setOutputEncoding();

    return out.toJS(globalThis);
}

fn namedExportsToJS(global: *JSGlobalObject, named_exports: *JSAst.Ast.NamedExports) bun.JSError!jsc.JSValue {
    if (named_exports.count() == 0)
        return JSValue.createEmptyArray(global, 0);

    var named_exports_iter = named_exports.iterator();
    var stack_fallback = std.heap.stackFallback(@sizeOf(bun.String) * 32, bun.default_allocator);
    var allocator = stack_fallback.get();
    var names = allocator.alloc(
        bun.String,
        named_exports.count(),
    ) catch unreachable;
    defer allocator.free(names);
    named_exports.sort(strings.StringArrayByIndexSorter{
        .keys = named_exports.keys(),
    });
    var i: usize = 0;
    while (named_exports_iter.next()) |entry| {
        names[i] = bun.String.cloneUTF8(entry.key_ptr.*);
        i += 1;
    }
    return bun.String.toJSArray(global, names);
}

fn namedImportsToJS(global: *JSGlobalObject, import_records: []const ImportRecord) bun.JSError!jsc.JSValue {
    const path_label = jsc.ZigString.static("path");
    const kind_label = jsc.ZigString.static("kind");

    const array = try jsc.JSValue.createEmptyArray(global, import_records.len);
    array.ensureStillAlive();

    for (import_records, 0..) |record, i| {
        if (record.is_internal) continue;

        array.ensureStillAlive();
        const path = jsc.ZigString.init(record.path.text).toJS(global);
        const kind = jsc.ZigString.init(record.kind.label()).toJS(global);
        try array.putIndex(global, @as(u32, @truncate(i)), try jsc.JSValue.createObject2(global, path_label, kind_label, path, kind));
    }

    return array;
}

pub fn scanImports(this: *JSTranspiler, globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const arguments = callframe.arguments_old(2);
    var args = jsc.CallFrame.ArgumentsSlice.init(globalThis.bunVM(), arguments.slice());
    defer args.deinit();

    const code_arg = args.next() orelse {
        return globalThis.throwInvalidArgumentType("scanImports", "code", "string or Uint8Array");
    };

    const code_holder = try jsc.Node.StringOrBuffer.fromJS(globalThis, args.arena.allocator(), code_arg) orelse {
        if (!globalThis.hasException()) {
            return globalThis.throwInvalidArgumentType("scanImports", "code", "string or Uint8Array");
        }
        return .zero;
    };
    args.eat();
    defer code_holder.deinit();
    const code = code_holder.slice();

    var loader: Loader = this.transpiler_options.default_loader;
    if (args.next()) |arg| {
        if (try Loader.fromJS(globalThis, arg)) |_loader| {
            loader = _loader;
        }
        args.eat();
    }

    if (!loader.isJavaScriptLike()) {
        return globalThis.throwInvalidArguments("Only JavaScript-like files support this fast path", .{});
    }

    var arena = MimallocArena.init() catch unreachable;
    const prev_allocator = this.transpiler.allocator;
    const allocator = arena.allocator();
    var ast_memory_allocator = allocator.create(JSAst.ASTMemoryAllocator) catch bun.outOfMemory();
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    this.transpiler.setAllocator(allocator);
    var log = logger.Log.init(arena.backingAllocator());
    defer log.deinit();
    this.transpiler.setLog(&log);
    defer {
        this.transpiler.setLog(&this.transpiler_options.log);
        this.transpiler.setAllocator(prev_allocator);
        arena.deinit();
    }

    const source = logger.Source.initPathString(loader.stdinName(), code);
    var transpiler = &this.transpiler;
    const jsx = if (this.transpiler_options.tsconfig != null)
        this.transpiler_options.tsconfig.?.mergeJSX(this.transpiler.options.jsx)
    else
        this.transpiler.options.jsx;

    var opts = JSParser.Parser.Options.init(jsx, loader);
    if (this.transpiler.macro_context == null) {
        this.transpiler.macro_context = JSAst.Macro.MacroContext.init(&this.transpiler);
    }
    opts.macro_context = &this.transpiler.macro_context.?;

    transpiler.resolver.caches.js.scan(
        transpiler.allocator,
        &this.scan_pass_result,
        opts,
        transpiler.options.define,
        &log,
        &source,
    ) catch |err| {
        defer this.scan_pass_result.reset();
        if ((log.warnings + log.errors) > 0) {
            return globalThis.throwValue(try log.toJS(globalThis, globalThis.allocator(), "Failed to scan imports"));
        }

        return globalThis.throwError(err, "Failed to scan imports");
    };

    defer this.scan_pass_result.reset();

    if ((log.warnings + log.errors) > 0) {
        return globalThis.throwValue(try log.toJS(globalThis, globalThis.allocator(), "Failed to scan imports"));
    }

    const named_imports_value = try namedImportsToJS(
        globalThis,
        this.scan_pass_result.import_records.items,
    );
    return named_imports_value;
}

const string = []const u8;

const std = @import("std");
const ImportRecord = @import("../../import_record.zig").ImportRecord;
const Runtime = @import("../../runtime.zig").Runtime;
const TSConfigJSON = @import("../../resolver/tsconfig_json.zig").TSConfigJSON;

const options = @import("../../options.zig");
const Loader = options.Loader;
const Target = options.Target;

const MacroMap = @import("../../resolver/package_json.zig").MacroMap;
const PackageJSON = @import("../../resolver/package_json.zig").PackageJSON;

const bun = @import("bun");
const JSLexer = bun.js_lexer;
const JSPrinter = bun.js_printer;
const Transpiler = bun.transpiler;
const logger = bun.logger;
const strings = bun.strings;
const MimallocArena = bun.allocators.MimallocArena;
const api = bun.schema.api;

const JSAst = bun.ast;
const Expr = JSAst.Expr;

const JSParser = bun.js_parser;
const ScanPassResult = JSParser.ScanPassResult;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = bun.jsc.JSValue;
const ZigString = jsc.ZigString;
