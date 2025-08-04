# Fuzzing Guide

This document describes the fuzzing infrastructure for vibeutils and how to use it effectively.

## Overview

vibeutils uses Zig 0.14.1's native fuzzing support to provide property-based testing and fuzzing capabilities. The fuzzing infrastructure is designed to:

- Integrate seamlessly with existing tests
- Provide unified coverage reporting for both regular and fuzz tests
- Follow the project's TDD workflow
- Maintain simplicity over complexity

## Quick Start

```bash
# Run all fuzz tests (property-based testing)
make fuzz

# Run fuzz tests for a specific utility
make fuzz UTIL=echo

# For macOS users: Run fuzzing with web UI in Linux container
make fuzz-linux              # All fuzz tests with web UI at http://localhost:8080
make fuzz-linux UTIL=echo    # Specific utility fuzz tests with web UI
make fuzz-linux-shell        # Interactive shell for manual fuzzing

# Direct fuzzing command (Linux only, has issues on macOS)
# Note: --fuzz flag has debug info format issues on macOS
zig build fuzz --fuzz --port 8080
```

### macOS Development

Since the `--fuzz` flag with web UI doesn't work properly on macOS due to debug info format issues (expecting ELF, getting Mach-O), use the Docker-based Linux environment:

```bash
# Build the Docker image if needed
make docker-build

# Run fuzzing with web UI in Linux container
make fuzz-linux

# The web UI will be available at http://localhost:8080
# The fuzzer will run continuously until you stop it with Ctrl+C
```

## Architecture

### Test Organization

Fuzz tests are embedded directly in utility source files, following the existing TDD pattern. They are distinguished by the `"fuzz:"` prefix:

```zig
// Regular test
test "echo handles empty input" {
    // ...
}

// Fuzz test
test "fuzz: echo never panics with arbitrary arguments" {
    // ...
}
```

### Common Fuzzing Utilities

The `src/common/fuzz.zig` module provides utilities for fuzzing:

- `generatePath()` - Creates path-like strings with edge cases
- `generateArgs()` - Generates command-line argument patterns
- `generateEscapeSequence()` - Creates escape sequence patterns
- Property verification helpers

## Writing Fuzz Tests

### Basic Pattern

```zig
test "fuzz: utility handles arbitrary input" {
    try std.testing.fuzz(struct {
        fn run(input: []const u8) !void {
            // Your fuzzing logic here
            // Should never panic, only return errors
        }
    }.run, .{});
}
```

### Testing Command-Line Utilities

```zig
test "fuzz: utility argument parsing" {
    try std.testing.fuzz(struct {
        fn run(input: []const u8) !void {
            const allocator = testing.allocator;
            
            // Generate arguments from fuzz input
            const args = try common.fuzz.generateArgs(allocator, input);
            defer {
                for (args) |arg| allocator.free(arg);
                allocator.free(args);
            }
            
            // Run utility - should handle all inputs gracefully
            var stdout_buf = std.ArrayList(u8).init(allocator);
            defer stdout_buf.deinit();
            
            _ = runUtility(allocator, args, stdout_buf.writer(), common.null_writer) catch |err| {
                // Errors are acceptable, panics are not
                _ = err;
            };
        }
    }.run, .{});
}
```

### Property-Based Testing

```zig
test "fuzz: output is deterministic" {
    try std.testing.fuzz(struct {
        fn run(input: []const u8) !void {
            const allocator = testing.allocator;
            
            // Run twice with same input
            const output1 = try runWithInput(allocator, input);
            defer allocator.free(output1);
            
            const output2 = try runWithInput(allocator, input);
            defer allocator.free(output2);
            
            // Property: same input produces same output
            try testing.expectEqualStrings(output1, output2);
        }
    }.run, .{});
}
```

## Coverage Integration

The fuzzing infrastructure uses Zig's native coverage system, which works for both regular and fuzz tests:

```bash
# Run tests with coverage
zig build test -Dcoverage=true

# Run fuzz tests with coverage
zig build fuzz -Dcoverage=true

# View coverage report (when web server is implemented)
zig build fuzz --fuzz --port 8080
# Then browse to http://localhost:8080
```

## Adding Fuzzing to a New Utility

1. **Add fuzz tests to the utility's source file:**

```zig
// In src/myutil.zig

test "fuzz: myutil handles arbitrary input" {
    try std.testing.fuzz(struct {
        fn run(input: []const u8) !void {
            // Fuzzing logic
        }
    }.run, .{});
}
```

2. **Update build.zig if needed** (already done for all utilities):

The `addFuzzSteps()` function in `build.zig` automatically creates fuzz targets for all utilities.

3. **Add Makefile target** (optional, for convenience):

```makefile
.PHONY: fuzz-myutil
fuzz-myutil:
	zig build fuzz-myutil
```

## Best Practices

### DO:
- Keep fuzz tests focused on specific properties
- Use the common fuzzing utilities for consistency
- Handle all errors gracefully (no panics)
- Limit input sizes to prevent resource exhaustion
- Test both valid and invalid inputs

### DON'T:
- Don't write to actual files during fuzzing
- Don't perform network operations
- Don't use unbounded recursion
- Don't leak memory (use `testing.allocator`)

## Properties to Test

### Safety Properties
- Never panic with any input
- Handle all allocation failures gracefully
- Prevent buffer overflows
- Avoid infinite loops

### Correctness Properties
- Deterministic behavior for same input
- Round-trip correctness (parse → format → parse)
- Invariant preservation
- Error handling consistency

### Performance Properties
- Bounded memory usage
- Reasonable execution time
- Graceful degradation with large inputs

## Debugging Fuzz Failures

When a fuzz test fails:

1. **Save the failing input:**
```zig
std.debug.print("Failing input: {s}\n", .{input});
```

2. **Create a regression test:**
```zig
test "regression: specific failing case" {
    const input = "failing input here";
    // Test the specific case
}
```

3. **Use the debugger:**
```bash
zig test src/utility.zig --test-filter "fuzz:" --debug
```

## Performance Considerations

- Fuzz tests run with `std.testing.fuzz()` which may execute many iterations
- Use `generateArgs()` and similar helpers to limit input complexity
- Consider adding timeouts for long-running operations
- Profile with `zig build -Doptimize=ReleaseFast` if needed

## Future Enhancements

As Zig's fuzzing support matures, we plan to:

1. Add corpus-based fuzzing with seed inputs
2. Integrate with AFL++ or libFuzzer as alternatives
3. Add continuous fuzzing in CI
4. Create dashboard for tracking fuzzing metrics
5. Implement coverage-guided fuzzing optimization

## Related Documentation

- [TESTING_STRATEGY.md](TESTING_STRATEGY.md) - Overall testing approach
- [CLAUDE.md](../CLAUDE.md) - Codebase guidance including testing patterns
- Zig 0.14.0 [Release Notes](https://ziglang.org/download/0.14.0/release-notes.html#Fuzzer) - Fuzzing feature documentation