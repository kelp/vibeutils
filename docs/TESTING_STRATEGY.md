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
    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    
    // Test operations that allocate memory
    try list.append('a');
    
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

Use temporary directories for isolation:

```zig
test "file operations" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const tmp_path = try tmp_dir.dir.realpathAlloc(
        testing.allocator, "."
    );
    defer testing.allocator.free(tmp_path);
    
    // Perform file operations in isolated directory
    try tmp_dir.dir.writeFile("test.txt", "content");
}
```

### Output Testing

Capture and verify command output:

```zig
test "command output" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    
    try runCommand(&args, buffer.writer());
    
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