# Testing Strategy

This document outlines the comprehensive testing strategy for the Zig coreutils
project, including unit tests, integration tests, and privileged testing.

## Overview

Our testing philosophy follows Test-Driven Development (TDD) principles:
1. Write failing tests first
2. Implement minimal code to pass
3. Refactor with confidence
4. Target 90%+ test coverage

## Test Organization

### Unit Tests

Unit tests are embedded directly in source files using Zig's built-in testing
framework:

```zig
test "function description" {
    // Test implementation
}
```

**Location**: Same file as the code being tested
**Naming**: Descriptive test names that explain the behavior being tested
**Scope**: Test individual functions, edge cases, and error conditions

### Integration Tests

Integration tests verify interactions between modules and real-world scenarios:

- **Location**: `src/<utility>/integration_test.zig`
- **Purpose**: Test complete command workflows
- **Coverage**: Cross-module interactions, file system operations

### POSIX I/O Contracts

The POSIX I/O suite covers four runtime contracts:

1. `>>` preserves a seeded prefix rather than overwriting it.
2. A closed stdout pipe is observed as SIGPIPE or EPIPE without hanging.
3. Stderr is unbuffered.
4. Plain, help, and unknown-option invocations use the measured POSIX/GNU
   exit-status table.

`tests/lib/posix_io.sh` applies contracts 1, 2, and 4 to every utility.
The explicit fixture table is the fifth contract: every name in
`build/utils.zig`, including `[`, must have deterministic arguments and stdin
from `/dev/null`. When adding a utility, add its
`posix_io_has_fixture` row at the same time.

`tests/tools/posix_io_test.sh` is the coverage oracle. Its cat wait-test
requires a missing-file diagnostic while cat is still blocked on stdin, and
its env wait-test requires the verbose clearing diagnostic while env is still
waiting for its child. These two representatives prove stderr is visible
before process exit without repeating a timing-sensitive wait-test 48 times.
Per-utility runs use `$TEMP_DIR/posix_io_scratch`, whose name and child files
must not contain utility names; `test_posix_io` removes it at its single
return and must not replace the integration runner's `EXIT` trap.

### Test Utilities

Common testing utilities are provided in:
- `src/common/test_utils.zig` - General test helpers
- `src/<utility>/test_utils.zig` - Utility-specific helpers

## Running Tests

### Basic Test Commands

```bash
# Run all tests
make test
zig build test

# Run tests with coverage
make coverage
# View coverage report: coverage/index.html

# Run a single test file
zig test src/echo.zig
zig test src/common/lib.zig

# Run tests in debug mode
make debug test
```

### Test Output

Tests use the standard Zig test runner output:
- Green checkmarks for passing tests
- Red X marks for failing tests
- Detailed error messages and stack traces on failure

## Memory Testing

All tests use `testing.allocator` to detect memory leaks:

```zig
test "no memory leaks" {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(testing.allocator);
    
    // Test operations that allocate memory
    try list.append(testing.allocator, 'a');
    
    // Allocator automatically checks for leaks when test ends
}
```

## Error Testing

Test error conditions and edge cases:

```zig
test "handles file not found" {
    const result = openFile("nonexistent.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "handles permission denied" {
    const result = writeToReadOnlyFile();
    try testing.expectError(error.PermissionDenied, result);
}
```

## Privileged Testing

For operations requiring elevated privileges (chmod, chown, etc.), we use a
specialized testing infrastructure that simulates privileges without requiring
actual root access.

### Architecture

The privileged testing system (`src/common/privilege_test.zig`) provides:

1. **Platform Detection**: Automatically detects Linux, macOS, BSD
2. **Tool Detection**: Checks for fakeroot, unshare, or container support
3. **Graceful Fallback**: Skips tests when privilege simulation unavailable
4. **Helper Functions**: Simple API for writing privileged tests

### Writing Privileged Tests

```zig
const privilege_test = @import("common").privilege_test;

test "chmod changes file permissions" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();
    
    // Run test block under privilege simulation
    try privilege_test.withFakeroot(struct {
        fn testFn() !void {
            // Create test file
            const file = try std.fs.cwd().createFile("test.txt", .{});
            file.close();
            defer std.fs.cwd().deleteFile("test.txt") catch {};
            
            // Change permissions (simulated under fakeroot)
            try std.os.chmod("test.txt", 0o600);
            
            // Verify permissions
            const stat = try std.fs.cwd().statFile("test.txt");
            try testing.expect(stat.mode & 0o777 == 0o600);
        }
    }.testFn);
}
```

### Running Privileged Tests

```bash
# Run with fakeroot (fails if unavailable)
make test-privileged

# Run with best available method (graceful fallback)
make test-privileged-local

# Run specific privileged tests
./scripts/run-privileged-tests.sh --filter chmod

# Force specific method
./scripts/run-privileged-tests.sh --force-unshare
```

### Privilege Simulation Methods

1. **fakeroot** (Linux primary)
   - Intercepts system calls to simulate root operations
   - No actual privilege elevation
   - Some limitations with Zig's direct syscalls

2. **unshare** (Linux fallback)
   - Uses user namespaces for privilege simulation
   - More limited than fakeroot but works reliably
   - Requires kernel support for user namespaces

3. **Containers** (cross-platform fallback)
   - Uses podman/docker for isolated testing
   - Most comprehensive but slower
   - Good for CI/CD environments

4. **Skip** (no simulation available)
   - Tests are skipped with clear messaging
   - Non-zero exit only for actual failures
   - Ensures tests pass on all platforms

## Test Patterns

### File System Testing

Use `common.test_dir.TestDir` for isolation. Pass absolute
paths from `getPath` / `getBasePath` into the utility under
test so parallel tests do not share a process cwd. Use
`join` for a dest that does not exist yet (`getPath`
realpaths and fails if the name is missing).

```zig
test "file operations" {
    const TestDir = common.test_dir.TestDir;
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("test.txt", "content", null);
    const path = try test_dir.getPath("test.txt");
    defer testing.allocator.free(path);

    // Perform file operations in isolated directory
}
```

### Output Testing

Capture and verify command output:

```zig
test "command output" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    
    try runCommand(&args, buffer.writer(testing.allocator));
    
    try testing.expectEqualStrings(
        "expected output\n",
        buffer.items
    );
}
```

### Argument Parsing Testing

Test various argument combinations:

```zig
test "parses short flags" {
    const args = [_][]const u8{ "prog", "-n", "-l" };
    const parsed = try parseArgs(&args);
    
    try testing.expect(parsed.number_lines);
    try testing.expect(parsed.show_ends);
}

test "parses long options" {
    const args = [_][]const u8{ "prog", "--number", "--show-ends" };
    const parsed = try parseArgs(&args);
    
    try testing.expect(parsed.number_lines);
    try testing.expect(parsed.show_ends);
}
```

## Filter Utilities and Stdin-Dependent Testing

### The Problem

Filter utilities that read from stdin (like `tee`, `cat`, `sort`, `uniq`, `tr`, `cut`, `nl`, `tac`) 
present a special challenge for unit testing. Calling their main `runUtil()` function in tests will 
block indefinitely waiting for stdin input that never comes, causing test hangs.

### Utility Categories

Before implementing a utility, identify its category:

**A. Filter Utilities** (read stdin by default):
- `cat`, `tee`, `sort`, `uniq`, `tr`, `cut`, `nl`, `tac`, `head`, `tail`, `wc`
- **Testing Challenge**: Will block on stdin in unit tests
- **Solution**: Skip unit tests or create `runUtilWithInput()` variant

**B. File/Path Utilities** (operate on files/paths):
- `ls`, `cp`, `mv`, `rm`, `mkdir`, `chmod`, `chown`, `ln`, `du`, `stat`
- **Testing**: Standard unit tests work fine
- **Solution**: Mock file operations as needed

**C. Generator Utilities** (produce output):
- `echo`, `yes`, `seq`, `date`, `printf`, `whoami`, `id`
- **Testing**: Standard unit tests work fine
- **Solution**: Capture and verify output

**D. Process Utilities** (spawn processes):
- `env`, `timeout`, `nice`, `nohup`
- **Testing Challenge**: Process spawning in tests
- **Solution**: Mock process operations or skip tests

### Testing Patterns for Filter Utilities

#### Pattern 1: Skip Unit Tests (Simple)

```zig
test "filter utility basic test" {
    // Skip this test as it would block waiting for stdin
    // This functionality is tested via binary smoke tests
    return error.SkipZigTest;
}
```

#### Pattern 2: Dual Function Architecture (Recommended)

Create two functions — one for public API, one for testing. The
public function opens stdin; the inner function takes a
`*std.Io.Reader` so tests can pass `std.Io.Reader.fixed(input)`.
See `src/tee.zig` for the canonical pattern.

```zig
// Public API that reads from stdin
pub fn runUtil(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    return runUtilWithInput(allocator, io, args, &stdin_reader.interface,
                            stdout_writer, stderr_writer);
}

// Testable function that accepts an arbitrary reader
fn runUtilWithInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    reader: *std.Io.Reader,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Implementation here
}

test "filter utility with mock input" {
    const io = std.testing.io;
    var input: std.Io.Reader = .fixed("hello\nworld\n");
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    _ = try runUtilWithInput(testing.allocator, io, &.{}, &input,
                             &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqualStrings("hello\nworld\n", stdout_aw.writer.buffered());
}
```

### Common Pitfalls and Solutions

#### 1. Fuzz Tests with Stdin Dependencies

**Problem**: Fuzz tests calling `runUtil()` will hang
```zig
// ❌ WRONG
fn testFuzz(allocator: Allocator, input: []const u8) !void {
    _ = runUtil(allocator, &args, writer, writer) catch {};  // HANGS!
}
```

**Solution**: Skip execution or test only parsing
```zig
// ✅ RIGHT
fn testFuzz(allocator: Allocator, input: []const u8) !void {
    _ = allocator;  // Must be FIRST to avoid "pointless discard" error
    _ = input;
    if (!common.fuzz.shouldFuzzUtilityRuntime("util")) return;
    // Skip actual execution for stdin-dependent utilities
}
```

#### 2. Exit Code Conventions

**Always use correct POSIX exit codes**:
```zig
// Argument errors return 1. Exit 2 for "misuse" is a bash convention for
// shell builtins; coreutils has no such concept. See common.ExitCode for
// the few utilities that need serious_error (2) or internal_error (125).
error.UnknownFlag => return @intFromEnum(common.ExitCode.general_error),
error.MissingValue => return @intFromEnum(common.ExitCode.general_error),
error.InvalidValue => return @intFromEnum(common.ExitCode.general_error),
```

#### 3. Buffer Size Consistency

Always use **8192 bytes** for I/O buffers to maintain consistency:
```zig
var buffer: [8192]u8 = undefined;  // Not 4096
```

### Pre-Implementation Checklist

Before implementing any utility:

1. **Identify category**: Is it a filter/file/generator/process utility?
2. **Plan test strategy**: Can you unit test it or need smoke tests?
3. **Check similar utilities**: Look for existing patterns to follow
4. **Review POSIX spec**: Understand required behavior and exit codes
5. **Design testable architecture**: Consider `runUtilWithInput()` pattern for filters

### Post-Implementation Verification

**CRITICAL: Always run the FULL test suite before declaring a utility complete**:

```bash
# ❌ WRONG: Only testing your utility
make test UTIL=tee  # Not sufficient!

# ✅ RIGHT: Full test suite verification
zig build test           # Run ALL tests
make test                # Full test suite with smoke tests
make test-privileged     # If applicable

# Also verify no hanging tests with timeout
timeout 60 zig build test || echo "Tests hung!"
```

**Why this matters**:
- Your utility's tests might pass in isolation but cause hangs in full suite
- Your changes might break other utilities' tests
- Memory leaks might only show up in full test runs
- Integration issues between utilities only appear in full suite

**Completion Checklist**:
1. ✅ Individual utility tests pass (`make test UTIL=yourutil`)
2. ✅ Full test suite passes (`zig build test`)
3. ✅ No test hangs (completes within reasonable time)
4. ✅ Binary smoke tests pass
5. ✅ No new compiler warnings
6. ✅ Code formatted (`make fmt`)

### Binary Smoke Tests

For filter utilities, rely on binary smoke tests in the Makefile:

```bash
# Test via Makefile's smoke test infrastructure
make test UTIL=tee

# These tests can properly pipe input:
echo "test" | ./zig-out/bin/tee output.txt
```

### Documentation Requirements

When tests must be skipped, always document why:

```zig
test "utility test" {
    // Skip this test as it would block waiting for stdin
    // This functionality is tested via binary smoke tests
    return error.SkipZigTest;
}
```

## File Descriptor Mode Tests

Issue #5 was `File.writer()` seeking to offset 0 and
ignoring `O_APPEND`. A source grep in `src/common/lib.zig`
and one `echo` case are not enough for the next utility
that grows its own `main()`.

`tests/lib/fd_modes.sh` runs every `build/utils.zig` binary
under `>> file`, `| cat`, `> file`, `2>&1 >> file`, and
`>> file 2>&1`. A missing fixture is FAIL. Default argv is
`--help` with stdin `/dev/null`; locked rows (echo, true,
false, test, `[`, yes, sleep) are in that file.

`tests/tools/fd_modes_test.sh` is the coverage oracle
(`just test-fd-modes`, and `just it` via
`run_all_utility_tests`). Do not add
`tests/utilities/fd_modes_test.sh`.

When adding a utility, add a `fd_modes_has_fixture` row
in the same change.

## Coverage Guidelines

### Target Coverage

- **Overall**: 90%+ line coverage
- **Core Logic**: 95%+ coverage
- **Error Paths**: 100% coverage
- **Edge Cases**: Comprehensive testing

### Measuring Coverage

```bash
# Generate coverage report
make coverage

# View in browser
open coverage/index.html

# Check coverage percentage
grep -A 1 "Total coverage" coverage/index.html
```

### Coverage Exceptions

Acceptable reasons for lower coverage:
- Platform-specific code on other platforms
- Panic handlers and unreachable code
- Interactive prompts (tested manually)

## CI/CD Integration

### Automated Testing

All tests run automatically on:
- Pull requests
- Commits to main branch
- Nightly builds

### Test Matrix

Tests run across:
- **Operating Systems**: Linux, macOS, Windows (WSL)
- **Architectures**: x86_64, aarch64
- **Zig Versions**: Latest stable, latest master

### Privileged Tests

#### Test Naming Convention

Tests requiring privilege simulation must be prefixed with `"privileged: "`:

```zig
test "privileged: chmod changes file permissions" {
    try privilege_test.requiresPrivilege();
    // Test implementation
}
```

#### Running Privileged Tests

```bash
# Run all tests (privileged tests will be skipped)
zig build test

# Run only privileged tests under fakeroot
./scripts/run-privileged-tests.sh

# Run specific privileged test
./scripts/run-privileged-tests.sh -f "chmod"

# Run privileged tests manually
fakeroot zig build test-privileged
```

#### Implementation Pattern

```zig
test "privileged: file operation test" {
    // Check if under fakeroot, skip if not
    try privilege_test.requiresPrivilege();
    
    // Or use withFakeroot for inline test function
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            // Test implementation
        }
    }.testFn);
}
```

### Privileged Tests in CI

CI environments run privileged tests using:
1. Container-based testing for isolation
2. User namespace support where available
3. Clear reporting of skipped tests
4. Separate test target: `zig build test-privileged`

## Best Practices

### DO

- Write tests before implementation
- Test edge cases and error conditions
- Use descriptive test names
- Clean up resources in defer blocks
- Test with minimal allocations
- Mock external dependencies
- Test both success and failure paths

### DON'T

- Skip writing tests for "simple" functions
- Ignore memory leaks in tests
- Test implementation details
- Write brittle tests dependent on timing
- Leave commented-out tests
- Test private implementation details

## Debugging Tests

### Verbose Output

```bash
# Run with verbose output
zig build test --verbose

# Debug specific test
zig test src/echo.zig --test-filter "specific test name"
```

### Test Isolation

```bash
# Run single test to isolate failures
zig test src/module.zig --test-filter "test name"

# Run with GDB
gdb --args zig test src/module.zig
```

### Memory Debugging

```bash
# Run with valgrind (if testing allocator misses something)
valgrind ./zig-out/bin/utility

# Check for leaks in specific test
zig test src/module.zig --test-filter "test" 2>&1 | grep -i leak
```

## Future Enhancements

1. **Property-Based Testing**: Add fuzzing for input validation
2. **Performance Testing**: Benchmark critical operations
3. **Stress Testing**: Test with large files and many operations
4. **Security Testing**: Validate security-sensitive operations
5. **Cross-Platform Matrix**: Expand platform coverage

## Contributing Tests

When adding new utilities or features:

1. Write comprehensive unit tests in the source file
2. Add integration tests for real-world scenarios
3. Include privileged tests for permission operations
4. Update coverage targets if needed
5. Document any special testing requirements
6. Ensure all tests pass locally before submitting

Remember: Tests are documentation that never goes out of date!