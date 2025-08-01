/// In pipeline expressions, assigns (e.g. `FOO=bar BAR=baz | echo hi`) have
/// no effect on the environment of the shell, so we can skip them.
pub const Assigns = @This();

base: State,
node: []const ast.Assign,
parent: ParentPtr,
state: union(enum) {
    idle,
    expanding: struct {
        idx: u32 = 0,
        current_expansion_result: std.ArrayList([:0]const u8),
        expansion: Expansion,
    },
    err: bun.shell.ShellErr,
    done,
},
ctx: AssignCtx,
owned: bool = true,
io: IO,

pub const ParentPtr = StatePtrUnion(.{
    Stmt,
    Binary,
    Cmd,
    Pipeline,
});

pub const ChildPtr = StatePtrUnion(.{
    Expansion,
});

pub inline fn deinit(this: *Assigns) void {
    if (this.state == .expanding) {
        this.state.expanding.current_expansion_result.deinit();
    }
    this.io.deinit();
    this.base.endScope();
    if (this.owned) this.parent.destroy(this);
}

pub fn start(this: *Assigns) Yield {
    return .{ .assigns = this };
}

pub fn init(
    interpreter: *Interpreter,
    shell_state: *ShellExecEnv,
    node: []const ast.Assign,
    ctx: AssignCtx,
    parent: ParentPtr,
    io: IO,
) *Assigns {
    const this = parent.create(Assigns);
    log("Assigns(0x{x}) init", .{@intFromPtr(this)});
    this.* = .{
        .base = State.initWithNewAllocScope(.assign, interpreter, shell_state),
        .node = node,
        .parent = parent,
        .state = .idle,
        .ctx = ctx,
        .io = io,
    };
    return this;
}

pub fn initBorrowed(
    this: *Assigns,
    interpreter: *Interpreter,
    shell_state: *ShellExecEnv,
    node: []const ast.Assign,
    ctx: AssignCtx,
    parent: ParentPtr,
    io: IO,
) void {
    this.* = .{
        .base = State.initWithNewAllocScope(.assign, interpreter, shell_state),
        .node = node,
        .parent = parent,
        .state = .idle,
        .ctx = ctx,
        .owned = false,
        .io = io,
    };
}

pub fn next(this: *Assigns) Yield {
    while (!(this.state == .done)) {
        switch (this.state) {
            .idle => {
                this.state = .{ .expanding = .{
                    .current_expansion_result = std.ArrayList([:0]const u8).init(this.base.allocator()),
                    .expansion = undefined,
                } };
                continue;
            },
            .expanding => {
                if (this.state.expanding.idx >= this.node.len) {
                    this.state.expanding.current_expansion_result.clearAndFree();
                    this.state = .done;
                    continue;
                }

                Expansion.init(
                    this.base.interpreter,
                    this.base.shell,
                    &this.state.expanding.expansion,
                    &this.node[this.state.expanding.idx].value,
                    Expansion.ParentPtr.init(this),
                    .{
                        .array_of_slice = &this.state.expanding.current_expansion_result,
                    },
                    this.io.copy(),
                );
                return this.state.expanding.expansion.start();
            },
            .done => unreachable,
            .err => return this.parent.childDone(this, 1),
        }
    }

    return this.parent.childDone(this, 0);
}

pub fn childDone(this: *Assigns, child: ChildPtr, exit_code: ExitCode) Yield {
    if (child.ptr.is(Expansion)) {
        bun.assert(this.state == .expanding);
        const expansion = child.ptr.as(Expansion);
        if (exit_code != 0) {
            this.state.expanding.current_expansion_result.clearAndFree();
            this.state = .{
                .err = expansion.state.err,
            };
            expansion.deinit();
            return .failed;
        }
        var expanding = &this.state.expanding;

        const label = this.node[expanding.idx].label;

        // Did it expand to a single word?
        if (expanding.current_expansion_result.items.len == 1) {
            const value = expanding.current_expansion_result.items[0];
            // We're going to let `EnvStr` manage the allocation for `value`
            // from here on out
            this.base.leakSlice(value);
            expanding.current_expansion_result.clearAndFree();

            const ref = EnvStr.initRefCounted(value);
            defer ref.deref();

            this.base.shell.assignVar(this.base.interpreter, EnvStr.initSlice(label), ref, this.ctx);
        } else {
            // Multiple words, need to concatenate them together. First
            // calculate size of the total buffer.
            const size = brk: {
                var total: usize = 0;
                const last = expanding.current_expansion_result.items.len -| 1;
                for (expanding.current_expansion_result.items, 0..) |slice, i| {
                    total += slice.len;
                    if (i != last) {
                        // Let's not forget to count the space in between the
                        // words!
                        total += 1;
                    }
                }
                break :brk total;
            };

            const value: []const u8 = brk: {
                if (size == 0) break :brk "";
                var merged = this.base.allocator().alloc(u8, size) catch bun.outOfMemory();
                var i: usize = 0;
                const last = expanding.current_expansion_result.items.len -| 1;
                for (expanding.current_expansion_result.items, 0..) |slice, j| {
                    @memcpy(merged[i .. i + slice.len], slice[0..slice.len]);
                    i += slice.len;
                    if (j != last) {
                        merged[i] = ' ';
                        i += 1;
                    }
                }
                break :brk merged;
            };

            // We're going to let `EnvStr` manage the allocation for `value`
            // from here on out
            this.base.leakSlice(value);

            const value_ref = EnvStr.initRefCounted(value);
            defer value_ref.deref();

            this.base.shell.assignVar(this.base.interpreter, EnvStr.initSlice(label), value_ref, this.ctx);
            for (expanding.current_expansion_result.items) |slice| {
                this.base.allocator().free(slice);
            }
            expanding.current_expansion_result.clearRetainingCapacity();
        }

        expanding.idx += 1;
        expansion.deinit();
        return .{ .assigns = this };
    }

    @panic("Invalid child to Assigns expression, this indicates a bug in Bun. Please file a report on Github.");
}

pub const AssignCtx = enum {
    cmd,
    shell,
    exported,
};

const bun = @import("bun");
const std = @import("std");

const ExitCode = bun.shell.ExitCode;
const Yield = bun.shell.Yield;
const ast = bun.shell.AST;

const Interpreter = bun.shell.Interpreter;
const Binary = bun.shell.Interpreter.Binary;
const Cmd = bun.shell.Interpreter.Cmd;
const Expansion = bun.shell.Interpreter.Expansion;
const IO = bun.shell.Interpreter.IO;
const Pipeline = bun.shell.Interpreter.Pipeline;
const ShellExecEnv = Interpreter.ShellExecEnv;
const State = bun.shell.Interpreter.State;
const Stmt = bun.shell.Interpreter.Stmt;

const EnvStr = bun.shell.interpret.EnvStr;
const StatePtrUnion = bun.shell.interpret.StatePtrUnion;
const log = bun.shell.interpret.log;
