Bun's test runner now supports built-in _code coverage reporting_. This makes it easy to see how much of the codebase is covered by tests, and find areas that are not currently well-tested.

## Enabling coverage

`bun:test` supports seeing which lines of code are covered by tests. To use this feature, pass `--coverage` to the CLI. It will print out a coverage report to the console:

```js
$ bun test --coverage
-------------|---------|---------|-------------------
File         | % Funcs | % Lines | Uncovered Line #s
-------------|---------|---------|-------------------
All files    |   38.89 |   42.11 |
 index-0.ts  |   33.33 |   36.84 | 10-15,19-24
 index-1.ts  |   33.33 |   36.84 | 10-15,19-24
 index-10.ts |   33.33 |   36.84 | 10-15,19-24
 index-2.ts  |   33.33 |   36.84 | 10-15,19-24
 index-3.ts  |   33.33 |   36.84 | 10-15,19-24
 index-4.ts  |   33.33 |   36.84 | 10-15,19-24
 index-5.ts  |   33.33 |   36.84 | 10-15,19-24
 index-6.ts  |   33.33 |   36.84 | 10-15,19-24
 index-7.ts  |   33.33 |   36.84 | 10-15,19-24
 index-8.ts  |   33.33 |   36.84 | 10-15,19-24
 index-9.ts  |   33.33 |   36.84 | 10-15,19-24
 index.ts    |  100.00 |  100.00 |
-------------|---------|---------|-------------------
```

To always enable coverage reporting by default, add the following line to your `bunfig.toml`:

```toml
[test]

# always enable coverage
coverage = true
```

By default coverage reports will _include_ test files and _exclude_ sourcemaps. This is usually what you want, but it can be configured otherwise in `bunfig.toml`.

```toml
[test]
coverageSkipTestFiles = true       # default false
```

### Coverage thresholds

It is possible to specify a coverage threshold in `bunfig.toml`. If your test suite does not meet or exceed this threshold, `bun test` will exit with a non-zero exit code to indicate the failure.

```toml
[test]

# to require 90% line-level and function-level coverage
coverageThreshold = 0.9

# to set different thresholds for lines and functions
coverageThreshold = { lines = 0.9, functions = 0.9, statements = 0.9 }
```

Setting any of these thresholds enables `fail_on_low_coverage`, causing the test run to fail if coverage is below the threshold.

### Sourcemaps

Internally, Bun transpiles all files by default, so Bun automatically generates an internal [source map](https://web.dev/source-maps/) that maps lines of your original source code onto Bun's internal representation. If for any reason you want to disable this, set `test.coverageIgnoreSourcemaps` to `true`; this will rarely be desirable outside of advanced use cases.

```toml
[test]
coverageIgnoreSourcemaps = true   # default false
```

### Exclude files from coverage

#### Skip test files

By default, test files themselves are included in coverage reports. You can exclude them with:

```toml
[test]
coverageSkipTestFiles = true   # default false
```

This will exclude files matching test patterns (e.g., _.test.ts, _\_spec.js) from the coverage report.

#### Ignore specific paths and patterns

You can exclude specific files or file patterns from coverage reports using `coveragePathIgnorePatterns`:

```toml
[test]
# Single pattern
coveragePathIgnorePatterns = "**/*.spec.ts"

# Multiple patterns
coveragePathIgnorePatterns = [
  "**/*.spec.ts",
  "**/*.test.ts",
  "src/utils/**",
  "*.config.js"
]
```

This option accepts glob patterns and works similarly to Jest's `collectCoverageFrom` ignore patterns. Files matching any of these patterns will be excluded from coverage calculation and reporting in both text and LCOV outputs.

Common use cases:

- Exclude utility files: `"src/utils/**"`
- Exclude configuration files: `"*.config.js"`
- Exclude specific test patterns: `"**/*.spec.ts"`
- Exclude build artifacts: `"dist/**"`

### Coverage defaults

By default, coverage reports:

1. Exclude `node_modules` directories
2. Exclude files loaded via non-JS/TS loaders (e.g., .css, .txt) unless a custom JS loader is specified
3. Include test files themselves (can be disabled with `coverageSkipTestFiles = true` as shown above)
4. Can exclude additional files with `coveragePathIgnorePatterns` as shown above

### Coverage reporters

By default, coverage reports will be printed to the console.

For persistent code coverage reports in CI environments and for other tools, you can pass a `--coverage-reporter=lcov` CLI option or `coverageReporter` option in `bunfig.toml`.

```toml
[test]
coverageReporter  = ["text", "lcov"]  # default ["text"]
coverageDir = "path/to/somewhere"  # default "coverage"
```

| Reporter | Description                                                                 |
| -------- | --------------------------------------------------------------------------- |
| `text`   | Prints a text summary of the coverage to the console.                       |
| `lcov`   | Save coverage in [lcov](https://github.com/linux-test-project/lcov) format. |

#### lcov coverage reporter

To generate an lcov report, you can use the `lcov` reporter. This will generate an `lcov.info` file in the `coverage` directory.

```toml
[test]
coverageReporter = "lcov"
```
