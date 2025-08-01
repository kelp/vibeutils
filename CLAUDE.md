# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Pre-1.0 Development Philosophy

**This is pre-1.0 software with zero external users. We prioritize getting the design right over backward compatibility.**

### Migration Principles:
- **Break things to fix them**: If the current API is wrong, change it completely
- **No deprecated code**: Remove old patterns entirely rather than maintaining compatibility layers
- **Full migrations only**: When changing a pattern, update ALL code to use the new pattern
- **Zero external users assumption**: We can make breaking changes without concern for downstream impact
- **Simplicity over compatibility**: Choose the simpler, cleaner design even if it requires rewriting existing code

### When NOT to maintain compatibility:
- Function signatures that take too many parameters
- Inconsistent error handling patterns
- Over-engineered abstractions that add complexity
- Any API that makes the codebase harder to understand or maintain

This philosophy allows us to iterate quickly and find the right abstractions before 1.0.

## Build and Test Commands

```bash
# Build all utilities
zig build
make build

# Run tests
zig build test
make test

# Run tests with coverage report (uses kcov)
make coverage
# Coverage report: coverage/index.html

# Run privileged tests (requires fakeroot)
./scripts/run-privileged-tests.sh
# Or manually:
fakeroot zig build test-privileged

# Build and run specific utility
zig build run-echo -- hello world
make run-echo ARGS="hello world"

# Build with specific optimization
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
zig build -Doptimize=Debug
make debug      # Debug build
make release    # Optimized for size

# Clean build artifacts
make clean

# Install optimized binaries
make install

# Format source code
make fmt

# Generate documentation
zig build docs
make docs

# Run a single test file
zig test src/echo.zig
zig test src/common/lib.zig
```

## Git Hooks

The project includes a pre-commit hook that automatically:
- Runs `make fmt` to format code before every commit
- Adds any formatting changes to the commit
- Runs tests to ensure code integrity

The hook is located at `.git/hooks/pre-commit` and is automatically set up for this repository.

## Makefile Targets

The project includes a comprehensive Makefile with the following targets:

- `make build` - Build all utilities (default target)
- `make test` - Run all tests
- `make coverage` - Run tests with coverage analysis using kcov
- `make clean` - Remove build artifacts and coverage files
- `make install` - Build optimized binaries for production
- `make run-<utility>` - Run specific utility (e.g., `make run-echo ARGS="hello"`)
- `make debug` - Build with debug information
- `make release` - Build optimized for smallest size
- `make fmt` - Format all source code with `zig fmt`
- `make docs` - Generate HTML API documentation
- `make help` - Show all available targets

## Test Coverage

The project has **74 tests** covering:
- **echo.zig**: 16 tests (basic output, flags, escape sequences)
- **cat.zig**: 10 tests (file reading, numbering, formatting)
- **ls.zig**: 27 tests (listing, formatting, sorting, filtering)
- **common modules**: 21 tests (utilities, file operations, styling)

Coverage reports are generated using `kcov` and can be viewed at `coverage/index.html` after running `make coverage`.

### Privileged Tests

Tests requiring file permission changes or other privileged operations are:
- Named with `"privileged: "` prefix
- Automatically skipped during regular `zig build test`
- Run separately with `./scripts/run-privileged-tests.sh` or `fakeroot zig build test-privileged`
- Use `privilege_test.requiresPrivilege()` or `privilege_test.withFakeroot()` to check for fakeroot environment

## Architecture Overview

This is a Zig implementation of GNU coreutils with modern enhancements. The project follows OpenBSD engineering principles (correctness, simplicity, security) while adding modern UX features (colors, icons, progress bars).

### Key Design Decisions

1. **Common Library Pattern**: All utilities import a shared `common` module that provides:
   - Terminal capability detection (NO_COLOR support, color modes)
   - Error handling with program name prefixes
   - Progress indicators for long operations
   - Styling abstractions with graceful degradation

2. **TDD Workflow**: Each utility follows this cycle:
   - Write failing tests first (in the same .zig file)
   - Implement minimal code to pass
   - Add more test cases for flags and edge cases
   - Target 90%+ test coverage

3. **Module Structure**:
   - `src/common/lib.zig` - Entry point for common functionality
   - `src/common/style.zig` - Terminal styling and color detection
   - `src/common/args.zig` - Argument parsing utilities
   - `src/common/file.zig` - File operation helpers
   - `src/common/terminal.zig` - Terminal capability detection
   - `src/<utility>.zig` - Each utility with embedded tests
   - Man pages in `man/man1/` using mdoc format

### Terminal Adaptation Strategy

The styling system (`src/common/style.zig`) automatically detects:
- NO_COLOR environment variable
- Terminal type (dumb, 16-color, 256-color, truecolor)
- Unicode support via LANG/LC_ALL
- Falls back gracefully when features aren't available

### Adding a New Utility

1. Create `src/<utility>.zig` with embedded tests
2. Add to `build.zig` following this pattern:
   - Add the executable in `b.addExecutable()`
   - Set up module dependencies (common, clap)
   - Create install and run steps
   - Add to test step
3. Write failing tests first (see echo.zig for examples)
4. Implement using common library functions
5. Create man page in `man/man1/<utility>.1` (OpenBSD style)
6. Update TODO.md to mark tasks complete

### Referencing Man Pages

When implementing a new command, always consult both OpenBSD and GNU coreutils man pages to determine the most useful set of flags to support:

1. **OpenBSD man pages**: Access online at `https://man.openbsd.org/<command>`
   - Example: `https://man.openbsd.org/mkdir` for the mkdir command
   - Focus on security, simplicity, and correctness
   - Often have cleaner, more focused flag sets

2. **GNU coreutils man pages**: 
   - **On Linux**: Available locally via `man <command>`
   - **On macOS**: Access online at `https://www.gnu.org/software/coreutils/manual/html_node/index.html`
     - Example: `https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html`
     - Note: macOS ships with BSD versions, not GNU coreutils
   - More extensive feature set with many flags
   - Required for GNU compatibility

3. **Implementation strategy**:
   - Start with the core flags that appear in both implementations
   - Add GNU-specific flags that are commonly used in scripts
   - Include OpenBSD security/safety features where applicable
   - Document any intentional differences in behavior

### Testing Patterns

```zig
// Use testing allocator to detect leaks
test "description" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    
    // Test against buffer output
    try function(&args, buffer.writer());
    try testing.expectEqualStrings("expected", buffer.items);
}
```

### Implementation Priorities

Utilities are implemented in phases (see TODO.md):
1. Phase 1: Essential utilities (echo, cat, ls, cp, mv, rm, mkdir, rmdir, touch, pwd)
2. Phase 2: Text processing (head, tail, wc, sort, uniq, cut, tr)
3. Phase 3: File information (stat, du, df)
4. Phase 4: Advanced (find, grep)

Each utility requires:
- Full GNU compatibility tests
- Man page with 2-3 practical examples
- Modern enhancements (colors, progress, parallel processing where applicable)

## Zig Documentation Tools

### context7 MCP Tool

The `context7` MCP (Model Context Protocol) tool provides instant access to up-to-date documentation for any library, including Zig. 

**CRITICAL: Zig changes regularly between versions. ALWAYS use context7 liberally when:**
- Looking up any Zig standard library function or type
- Checking function signatures, parameters, or error sets
- Verifying if a feature exists in Zig 0.14.1
- Understanding memory allocator behavior
- Implementing any new functionality
- **Even when you think you know the answer** - Zig's APIs evolve frequently

Available commands:
- `mcp__context7__resolve-library-id` - Search for and get the Context7-compatible library ID
- `mcp__context7__get-library-docs` - Fetch comprehensive documentation with code examples

#### Project Zig Version

This project requires **Zig 0.14.1** (as specified in `build.zig.zon`). When looking up documentation, ensure compatibility with this version.

#### Recommended Zig Documentation Sources

When working with Zig, use the following library IDs for best results:
- `/jedisct1/zig-mcp-doc` - MCP-friendly Zig documentation (9054 code snippets, trust score 9.7)
- `/context7/ziglang` - General Zig documentation (5449 code snippets, trust score 7.5)
- `/jedisct1/zig-for-mcp` - Alternative MCP-friendly docs (8836 code snippets, trust score 9.7)
- `/ziglang/zig` - Official Zig documentation (279 code snippets, version 0.14.1 available)

For version-specific documentation:
- Some libraries support version queries (e.g., `/ziglang/zig/0.14.1`)
- When in doubt, check the documentation source to ensure it covers Zig 0.14.1 features

#### Example Usage

When implementing file operations:
```zig
// Step 1: Get documentation for file system operations
// Use: mcp__context7__get-library-docs with:
//   - context7CompatibleLibraryID: "/jedisct1/zig-mcp-doc"
//   - topic: "std.fs"  // For file system operations
//   - tokens: 5000     // Adjust based on how much context you need

// For version-specific documentation (when available):
// Use: mcp__context7__get-library-docs with:
//   - context7CompatibleLibraryID: "/ziglang/zig/0.14.1"
//   - topic: "std.fs"

// For memory management:
// Use same command but with topic: "allocator" or "std.mem"

// For specific modules:
// - topic: "std.process" for process operations
// - topic: "std.io" for I/O operations
// - topic: "builtin" for builtin functions
// - topic: "std.heap" for heap allocators (note: SmpAllocator is recommended in 0.14.1)
```

**Best Practices for Using context7:**
1. **Check early and often** - Don't wait until you're stuck
2. **Verify assumptions** - What worked in Zig 0.13 may have changed in 0.14.1
3. **Look for examples** - Request code snippets showing actual usage
4. **Check multiple sources** - Try different library IDs if needed
5. **Be specific with topics** - Use precise module names like "std.fs.File" not just "file"

The tool returns actual code snippets from real Zig projects, making it more reliable than memory or outdated documentation.

## Claude Code Agent Usage

When working with Claude Code, use specialized agents for different tasks to get the best results:

### architect agent
Use the architect agent for:
- System design and architectural decisions
- Planning the structure of new utilities or features
- Evaluating design trade-offs and architectural patterns
- Creating high-level implementation strategies

Example: "Use the architect agent to design how the cp utility should handle recursive copying with progress indication"

### programmer agent
Use the programmer agent for:
- Writing new code implementations
- Refactoring existing code for better maintainability
- Implementing features with focus on clean architecture
- Following SOLID principles and best practices

Example: "Use the programmer agent to implement the mkdir utility with all GNU-compatible flags"

### reviewer agent
Use the reviewer agent for:
- Code quality reviews after implementing features
- Security and vulnerability analysis
- Identifying potential bugs or edge cases
- Suggesting improvements for maintainability

Example: "Use the reviewer agent to check the ls implementation for security issues and code quality"

### optimizer agent
Use the optimizer agent for:
- Analyzing performance bottlenecks
- Optimizing memory usage and allocations
- Improving algorithm efficiency
- Reducing binary size for release builds

Example: "Use the optimizer agent to improve the performance of sorting large directories in ls"

**Best Practice**: Use these agents in sequence - architect for design, programmer for implementation, reviewer for quality checks, and optimizer for performance improvements.

## Code Style and Conventions

### Simple Writer-Based Error Handling
All utilities follow a simple pattern: accept `stdout_writer` and `stderr_writer` parameters. This removes direct stderr access from utility functions, preventing stderr pollution during tests.

**Core principle: Pass writers explicitly, use them directly. No frameworks, no abstractions.**

#### Complete Working Example
Here's a complete, compilable example of the simple writer-based approach:

```zig
const std = @import("std");
const common = @import("common");

// Simple, direct approach - pass the writers you need
pub fn runCat(allocator: std.mem.Allocator, args: []const []const u8,
              stdout_writer: anytype, stderr_writer: anytype) !u8 {
    if (args.len == 0) {
        common.printErrorWithProgram(stderr_writer, "cat", "missing file operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }
    
    for (args) |file_path| {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            common.printErrorWithProgram(stderr_writer, "cat", "{s}: {s}", .{ file_path, @errorName(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer file.close();
        
        // Copy file to stdout - direct, no abstraction
        try file.reader().streamUntilDelimiter(stdout_writer, 0, null);
    }
    
    return @intFromEnum(common.ExitCode.success);
}

// Main function - simple setup, no framework
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    // Simple, direct approach - get the writers and pass them
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    
    const exit_code = try runCat(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}
```

#### DEPRECATED API (Do Not Use)
These functions are deprecated and will cause compile errors:
```zig
// DEPRECATED: These will cause @compileError
common.fatal("error message", .{});
common.printError("error message", .{});
common.printWarning("warning message", .{});
```

#### NEW API (Required)
Use the simple writer-based API:

```zig
// REQUIRED: All utilities must accept both stdout_writer and stderr_writer
pub fn myUtil(allocator: Allocator, args: []const []const u8, 
              stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Normal output goes to stdout_writer
    try stdout_writer.print("Processing file...\n", .{});
    
    // Error messages go to stderr_writer with program name
    common.printErrorWithProgram(stderr_writer, "myutil", "cannot open file: {s}", .{filename});
    
    // Fatal errors that should exit
    common.fatalWithWriter(stderr_writer, "cannot continue: {s}", .{@errorName(err)});
}

// In main() function:
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    // Simple, direct approach - get the writers and pass them
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    const result = try myUtil(allocator, args[1..], stdout, stderr);
    
    std.process.exit(result);
}

// In tests - suppress error output with null writer:
test "handles missing file gracefully" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    
    // Use null_writer for stderr to suppress error messages in tests
    const result = try myUtil(testing.allocator, &.{"missing.txt"}, 
                              buffer.writer(), common.null_writer);
    
    try testing.expectEqual(@as(u8, 1), result);
    // No "test: cannot open file" messages in test output!
}

// Complete test example:
test "error message format" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();
    
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    
    // Call the utility function - it will write errors to stderr_buffer
    const result = try myUtil(testing.allocator, &.{"nonexistent.txt"}, 
                              stdout_buffer.writer(), stderr_buffer.writer());
    
    // Verify the function returned error code
    try testing.expectEqual(@as(u8, 1), result);
    
    // Verify error messages went to stderr only
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "myutil: cannot open file: nonexistent.txt") != null);
    try testing.expectEqualStrings("", stdout_buffer.items);
    
    // For utilities that write normal output, test that too
    stderr_buffer.clearRetainingCapacity();
    stdout_buffer.clearRetainingCapacity();
    
    const success_result = try myUtil(testing.allocator, &.{"--help"}, 
                                      stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), success_result);
    try testing.expect(stdout_buffer.items.len > 0); // Help text went to stdout
    try testing.expectEqualStrings("", stderr_buffer.items); // No errors
}
```

#### Architecture Benefits
This pattern enables:
- **Clean test output**: No more "test: cannot remove '': No such file or directory" noise
- **Proper separation**: stdout and stderr are completely isolated  
- **Easy testing**: Error messages can be captured and verified
- **Consistent formatting**: All utilities use the same error message format
- **Compile-time safety**: Deprecated functions cause build failures, preventing accidental stderr pollution
- **Simple and direct**: No abstractions, just pass the writers you need

#### Migration Guide

**Migration steps:**
1. Replace `common.fatal()` with `common.fatalWithWriter(stderr_writer, ...)`
2. Replace `common.printError()` with `common.printErrorWithProgram(stderr_writer, prog_name, ...)`  
3. Replace `common.printWarning()` with `common.printWarningWithProgram(stderr_writer, prog_name, ...)`
4. Update function signatures to accept `stdout_writer, stderr_writer` parameters
5. In main(), get writers with `std.io.getStdOut().writer()` and `std.io.getStdErr().writer()`
6. Run tests to ensure no stderr pollution occurs during normal operation

### Error Handling (Updated)
```zig
// DEPRECATED: These functions cause compile errors
// common.printError("file.txt: {s}", .{@errorName(err)});
// common.fatal("cannot continue", .{});

// Use writer-based API with explicit stderr_writer
pub fn processFile(allocator: Allocator, file_path: []const u8, 
                   stdout_writer: anytype, stderr_writer: anytype) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        common.printErrorWithProgram(stderr_writer, "cat", "file.txt: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();
    
    // For warnings
    common.printWarningWithProgram(stderr_writer, "cat", "file truncated", .{});
    
    // For fatal errors
    common.fatalWithWriter(stderr_writer, "cannot continue: {s}", .{@errorName(err)});
}

// Exit codes from common.ExitCode enum  
return @intFromEnum(common.ExitCode.general_error);
```

**Critical**: The deprecated functions (`common.printError()`, `common.fatal()`, `common.printWarning()`) now cause compile-time errors. This prevents accidental stderr pollution during tests. All utility functions must use the two-writer pattern.

### Memory Management
- **CLI Tools**: Use Arena allocator (preferred) - all memory freed at once
  ```zig
  var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  defer arena.deinit();
  const allocator = arena.allocator();
  ```
- **Testing**: Always use `testing.allocator` to detect memory leaks
- **Debug builds**: GeneralPurposeAllocator for leak detection
  ```zig
  const gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();
  ```
- Use `defer` for cleanup immediately after allocation
- Pass allocator as first parameter to functions that allocate

### Argument Parsing
- Use zig-clap for consistent GNU-style argument parsing
- Support both short (`-n`) and long (`--number`) options
- Include `--help` and `--version` for all utilities

### Performance Considerations
- Use buffered I/O for file operations
- Pre-allocate buffers when size is known
- Consider parallel processing for independent operations (e.g., multiple files)

### Idiomatic Zig Practices

#### Documentation Comments
Zig uses special doc comments (`///`) for generating documentation. Follow these guidelines:

**Required Documentation:**
- All public functions, types, and constants
- Error sets with descriptions of when each error occurs
- Complex algorithms or non-obvious implementation details
- Parameters and return values for public functions

**Documentation Format:**
```zig
/// Process file at given path and return its content.
/// The file is read entirely into memory using the provided allocator.
/// Returns error if file cannot be read or memory allocation fails.
pub fn processFile(allocator: Allocator, path: []const u8, options: FileOptions) ![]u8 {
    // Implementation
}

/// Copy file attributes including permissions and timestamps.
/// Requires appropriate permissions on both source and destination.
pub fn copyAttributes(source: []const u8, dest: []const u8) !void {
    // Implementation
}

/// Configuration options for file processing.
pub const FileOptions = struct {
    /// Skip files larger than this size in bytes (0 = no limit)
    max_size: usize = 0,
    
    /// Follow symbolic links when traversing directories
    follow_symlinks: bool = true,
    
    /// Validation mode for input data
    validation: enum {
        /// No validation performed
        none,
        /// Basic syntax checking
        basic,
        /// Full validation with schema
        strict,
    } = .basic,
};
```

**Best Practices:**
- Start with a brief sentence that could stand alone
- Use present tense ("Returns" not "Will return")
- Document assumptions and preconditions
- Include examples for non-trivial usage
- Cross-reference related functions with `see also:`

#### Common Zig Idioms
- **Comptime**: Use `comptime` for compile-time computation and type generation
- **Error Sets**: Define explicit error sets for functions that can fail
- **Optionals**: Use `?T` for nullable values, not sentinel values
- **Slices**: Prefer slices (`[]const u8`) over pointers for string/array parameters
- **Allocators**: Always accept an allocator parameter for functions that allocate
- **Defer**: Use `defer` for cleanup immediately after resource acquisition
- **Error Unions**: Return `!T` for fallible operations, not success/failure booleans

```zig
// Good: Explicit error set
const FileError = error{
    NotFound,
    PermissionDenied,
    DiskFull,
};

// Good: Slice parameter with clear ownership
pub fn processFile(allocator: Allocator, path: []const u8) FileError!void {
    const file = try openFile(path);
    defer file.close();  // Cleanup immediately after acquisition
    
    // Process file...
}

// Good: Optional for nullable value
pub fn findChar(str: []const u8, char: u8) ?usize {
    for (str, 0..) |c, i| {
        if (c == char) return i;
    }
    return null;
}
```

#### Build System Integration
For documentation generation, ensure all public APIs have doc comments:
```bash
# Generate documentation
zig build docs

# Documentation will be in zig-out/docs/
# Can be served locally or published to GitHub Pages
```

### Zig Style Guide Quick Reference

**Naming Conventions:**
- `camelCase`: Functions (`copyFile`, `printError`, `shouldOverwrite`)
- `snake_case`: Variables (`file_path`, `dest_exists`, `buffer_size`)
- `PascalCase`: Types (structs, unions, enums) and error sets
- `UPPER_SNAKE_CASE`: True constants only (rarely used, prefer `const`)
- Acronyms: Treat as words (`HttpServer` not `HTTPServer`)

**Code Organization:**
```zig
// 1. Imports (std first, then third-party, then local)
const std = @import("std");
const clap = @import("clap");
const common = @import("common");

// 2. Type aliases
const Allocator = std.mem.Allocator;

// 3. Constants and globals
const MAX_PATH_SIZE = 4096;

// 4. Error sets
const FileError = error{ NotFound, PermissionDenied };

// 5. Types (structs, enums, unions)
pub const Options = struct { ... };

// 6. Public functions
pub fn processFile(...) !void { ... }

// 7. Private functions
fn helperFunction(...) void { ... }

// 8. Tests (at end of file)
test "description" { ... }
```

**Formatting Rules:**
- 4 spaces for indentation (enforced by `zig fmt`)
- Opening braces on same line
- Max line length: 100 characters (recommended)
- Blank line between function definitions
- Group related declarations

**Error Handling:**
- Use error unions (`!T`) for fallible operations
- Define specific error sets when possible
- Handle all possible errors explicitly
- Use `try` for propagation, `catch` for handling

**Testing:**
- Test names describe what is being tested
- Use `testing.allocator` to detect memory leaks
- Test both success and error cases
- Keep tests close to implementation

## Privileged Testing Infrastructure

The project includes infrastructure for testing operations that require elevated privileges (like chmod, chown) using fakeroot and other privilege simulation tools.

### Key Components

1. **src/common/privilege_test.zig** - Core privilege testing module
   - Platform detection (Linux, macOS, BSD)
   - FakerootContext for managing privilege simulation
   - Helper functions for privilege-aware tests
   - Automatic detection of available tools (fakeroot, unshare)

2. **scripts/run-privileged-tests.sh** - Smart test runner
   - Auto-detects available privilege simulation tools
   - Falls back gracefully: fakeroot → unshare → skip
   - Provides clear reporting of what was tested

3. **Build System Integration**
   - `zig build test-privileged` - Run with privilege simulation
   - `make test-privileged` - Requires fakeroot (fails if unavailable)
   - `make test-privileged-local` - Uses best available method

### Writing Privileged Tests

```zig
const common = @import("common");
const privilege_test = common.privilege_test;

test "operation requiring privileges" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();
    
    // Test will only run under fakeroot or similar
    // Perform privileged operations here
}

test "conditional privileged operation" {
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        // This code only runs under fakeroot
        // Note: Not all syscalls work through fakeroot with Zig's APIs
    }
}
```

### Running Privileged Tests

```bash
# Run with specific method
scripts/run-privileged-tests.sh -m fakeroot

# Run only specific tests
scripts/run-privileged-tests.sh -f "chmod"

# Use Makefile targets
make test-privileged      # Fails if fakeroot not available
make test-privileged-local # Graceful fallback
```

### Platform Notes

- **Linux**: Full support with fakeroot and unshare
- **macOS**: Limited support (fakeroot may not be available)
- **BSD**: Limited support (may require doas/sudo)

The infrastructure gracefully handles missing tools and provides clear error messages when privilege simulation is not available.

## Cross-Platform Testing

### macOS Development with Linux Testing

For macOS developers, the project includes Docker-based Linux testing infrastructure:

```bash
# Run Linux tests from macOS
make test-linux         # Run tests in Ubuntu container
make test-linux-alpine  # Run tests in Alpine container

# Interactive Linux environment
make shell-linux        # Ubuntu shell with project mounted
make shell-linux-alpine # Alpine shell with project mounted

# Full CI simulation
make ci-linux          # Run complete CI pipeline locally
```

### Docker Infrastructure
- **Dockerfile.ubuntu**: Ubuntu-based testing with kcov support
- **Dockerfile.alpine**: Minimal Alpine Linux testing
- Containers automatically mount project at `/workspace`
- Pre-installed with Zig 0.14.1 and testing tools

### Platform-Specific Considerations
- **File permissions**: Linux containers preserve Unix permissions better than macOS
- **Path separators**: Always use forward slashes for cross-platform compatibility
- **Line endings**: Ensure LF line endings (not CRLF) for Linux compatibility
- **System calls**: Some syscalls behave differently between macOS and Linux
