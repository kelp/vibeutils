# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🔴 MANDATORY: Always Use Agent Workflow for Coding

**The multi-agent workflow is required for ANY code changes beyond trivial fixes:**

1. **architect agent** → Design the solution
2. **programmer agent** → Implement the code  
3. **reviewer agent** → Review for quality
4. **optimizer agent** → Optimize if needed

### Agent Usage Required For:
- Implementing new utilities or features
- Refactoring existing code
- Fixing bugs requiring more than 5 lines of change
- Adding new functions or modifying APIs
- Performance improvements
- Any architectural decisions
- Searching for code patterns across the codebase
- Understanding existing implementations
- Researching how something works

### Direct Coding Acceptable For (RARE):
- Fixing typos in comments or docs
- Updating single constant values
- Adding a single test case
- Trivial one-line fixes

**Default: Use agents. When uncertain, use agents. Start with architect agent for any real coding task.**

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

Run `make help` for all available commands. Key commands:

```bash
# Essential
make build          # Build all utilities
make test           # Run tests
make coverage       # Generate coverage report
make fmt            # Format code

# Zig-specific
zig build test --summary all     # Test summary
zig build -Doptimize=ReleaseFast # Optimized build
zig test src/echo.zig            # Test single file
```

## Git Hooks

The project includes a pre-commit hook that automatically:
- Runs `make fmt` to format code before every commit
- Adds any formatting changes to the commit
- Runs tests to ensure code integrity

The hook is located at `.git/hooks/pre-commit` and is automatically set up for this repository.

## Test Coverage

Target: 90%+ coverage. Run `make coverage` to generate reports.

### Privileged Tests

Tests requiring file permission changes or other privileged operations are:
- Named with `"privileged: "` prefix
- Automatically skipped during regular `zig build test`
- Run separately with `./scripts/run-privileged-tests.sh` or `fakeroot zig build test-privileged`
- Use `privilege_test.requiresPrivilege()` or `privilege_test.withFakeroot()` to check for fakeroot environment
- **CRITICAL**: Must use `privilege_test.TestArena` allocators, NOT `testing.allocator` (Zig 0.14 fakeroot issue)

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
5. Create man page in `man/man1/<utility>.1` (see Man Page Style Guide below)
6. Update TODO.md to mark tasks complete

### Man Page Style Guide

Use mdoc format with consistent section ordering:

**Required sections:** NAME, SYNOPSIS, DESCRIPTION, EXIT STATUS, EXAMPLES, SEE ALSO, STANDARDS, AUTHORS

**Key rules:**
- No HISTORY section (clean room implementation)
- Validate with `mandoc -T lint`  
- Include 2-3 practical examples
- Document both short (`-f`) and long (`--force`) flags
- Author: `vibeutils implementation by Travis Cole`

### Referencing Man Pages

When implementing a new command, always consult POSIX specifications, OpenBSD, and GNU coreutils man pages to determine the most useful set of flags to support:

1. **POSIX.1-2017 Specifications**: The authoritative standard at `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/contents.html`
   - Direct utility lookup: `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/<command>.html`
   - Example: `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/echo.html`
   - Defines required behavior, flags, and exit codes for POSIX compliance
   - Free online access without registration
   - Includes rationale for design decisions
   - Full index at: `https://pubs.opengroup.org/onlinepubs/9699919799/idx/utilities.html`
   - Utility conventions: `https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html`

2. **OpenBSD man pages**: Access online at `https://man.openbsd.org/<command>`
   - Example: `https://man.openbsd.org/mkdir` for the mkdir command
   - Focus on security, simplicity, and correctness
   - Often have cleaner, more focused flag sets

3. **GNU coreutils man pages**: 
   - **On Linux**: Available locally via `man <command>`
   - **On macOS with GNU coreutils installed**: Use g-prefixed commands for man pages
     - Example: `man gls` for GNU ls, `man gcp` for GNU cp
     - GNU coreutils can be installed via Homebrew: `brew install coreutils`
     - All GNU utilities are prefixed with 'g' to avoid conflicts with BSD versions
   - **Online reference**: `https://www.gnu.org/software/coreutils/manual/html_node/index.html`
     - Example: `https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html`
     - Note: macOS ships with BSD versions by default, not GNU coreutils
   - More extensive feature set with many flags
   - Required for GNU compatibility

4. **Implementation strategy**:
   - Start with POSIX-required functionality as the baseline
   - Verify behavior against the POSIX specification for compliance
   - Add commonly used GNU extensions for compatibility
   - Include OpenBSD security/safety features where applicable
   - Document any intentional differences from POSIX/GNU/BSD behavior

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

### Fuzzing (Zig 0.14)

**⚠️ Critical Limitations:**
- **Linux-only** - Returns "no fuzz tests found" on macOS
- **Cannot select specific tests** - `zig build test --fuzz` runs ALL fuzz tests, gets stuck on first forever
- **No workaround** - No `--test-filter` support for fuzzing

**Required Pattern (wrapper function needed):**
```zig
// At end of src/myutil.zig (NOT separate _fuzz.zig files)
const enable_fuzz_tests = builtin.os.tag == .linux;

test "myutil fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testWrapper, .{});
}

fn testWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    const Fuzzer = common.fuzz.createIntelligentFuzzer(MyUtilArgs, runMyUtil);
    try Fuzzer.testComprehensive(allocator, input, common.null_writer);
}
```

**Zig 0.14 Fixes We've Applied:**
- `@typeInfo(T).@"struct"` not `.Struct`
- `@setEvalBranchQuota(10000)` for compile-time loops
- Cannot store `type` fields in runtime structs
- Use `&array` for pointer iteration on arrays

**Use Intelligent Fuzzer** (`common/fuzz.zig`):
- Automatic flag discovery via compile-time reflection
- Understands flag relationships (force vs interactive, etc.)
- 70% less code than manual fuzz tests

See `docs/FUZZING.md` for full details.


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

## Agent Workflow Details

**Required sequence for all non-trivial code changes:**

### architect agent (ALWAYS FIRST)
- System design and architectural decisions
- Planning implementation approach
- Evaluating trade-offs
- Designing APIs and interfaces

### programmer agent (ALWAYS SECOND)
- Writing clean, maintainable code
- Following established patterns
- Implementing the architect's design
- Test-driven development

### reviewer agent (ALWAYS THIRD)
- Quality and security review
- Bug and edge case identification
- Verification of requirements
- Code style compliance

### optimizer agent (WHEN NEEDED)
- Performance bottleneck analysis
- Memory optimization
- Algorithm improvements
- Binary size reduction

**Workflow: architect → programmer → reviewer → (optimizer if needed)**

Even "simple" features need architecture review - hidden complexity is often discovered during design phase.

## CRITICAL: Trust the OS for Security (Don't Add Security Theater)

**System utilities must trust the OS kernel to handle security. Do NOT add unnecessary validation that belongs in the kernel.**

### What NOT to Do (Security Theater)
```zig
// ❌ WRONG: Don't check for path traversal in system utilities
fn validatePath(path: []const u8) !void {
    if (std.mem.indexOf(u8, path, "../") != null) {
        return error.PathTraversal;  // WRONG!
    }
}

// ❌ WRONG: Don't maintain lists of "protected" paths
const PROTECTED_PATHS = [_][]const u8{
    "/", "/etc", "/usr", "/bin", // WRONG!
};

// ❌ WRONG: Don't prevent legitimate operations
if (std.mem.startsWith(u8, path, "/etc/")) {
    return error.ProtectedPath;  // WRONG!
}
```

### Why This is Wrong
1. **The OS already handles this**: File permissions, directory access, and security are enforced by the kernel
2. **Prevents legitimate use**: Users should be able to `rm ../old-file` or `mv /etc/config.old /etc/config` if they have permission
3. **Not our job**: System utilities are not a security layer - the kernel is
4. **Added complexity**: Security theater makes code harder to maintain and more likely to have bugs

### What System Utilities SHOULD Do
```zig
// ✅ CORRECT: Let the OS handle security
pub fn removeFile(path: []const u8) !void {
    // Just try the operation - let the OS decide if it's allowed
    std.fs.cwd().deleteFile(path) catch |err| {
        // OS said no - report the error
        return err;
    };
}

// ✅ CORRECT: Focus on correctness, not security
pub fn moveFile(source: []const u8, dest: []const u8) !void {
    // Check for same file (correctness issue, not security)
    const source_stat = try std.fs.cwd().statFile(source);
    const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
        error.FileNotFound => {
            // Destination doesn't exist, that's fine
            return std.posix.rename(source, dest);
        },
        else => return err,
    };
    
    if (source_stat.inode == dest_stat.inode) {
        return error.SameFile;  // Prevent data loss, not security issue
    }
    
    // Let the OS handle the actual move
    try std.posix.rename(source, dest);
}
```

### What Validation IS Appropriate

Only validate for **correctness** and **technical limitations**:

1. **Same file detection** - Prevent `mv file file` (would lose data)
2. **Buffer sizes** - Prevent overflow in user input buffers
3. **Atomic operations** - Ensure operations complete fully or not at all

### Examples from Real Issues

**WRONG (from old rmdir.zig):**
```zig
// 70+ lines of "protected" paths
const PROTECTED_PATHS = [_][]const u8{
    "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64",
    "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys",
    "/tmp", "/usr", "/var", "C:\\", "D:\\", // ... and 30 more
};
```

**RIGHT (simplified rmdir.zig):**
```zig
pub fn removeDir(path: []const u8) !void {
    // Just try it - the OS will prevent removing /etc if not allowed
    try std.fs.cwd().deleteDir(path);
}
```

### The Principle

> **"System utilities implement functionality, the OS kernel enforces security."**

When implementing utilities:
1. Try the operation the user requested
2. Report any errors the OS returns
3. Don't try to be smarter than the OS
4. Focus on correctness, not security

## Writing Style Guidelines

Follow "The Elements of Style" principles for all documentation and code comments:

### Core Principles
- **Brevity**: Omit needless words - every word should serve a purpose
- **Active voice**: Prefer "The function validates input" over "Input is validated by the function"
- **Avoid repetition**: State information once in the most logical location
- **Parallel construction**: Keep lists and series grammatically consistent
- **Positive form**: Say what something is, not what it isn't
- **Specific over general**: Use concrete, specific language instead of abstract terms

### List Organization
- **Alphabetize lists** unless there's a logical reason not to (e.g., order of operations, priority)
- Examples where alphabetization is appropriate:
  - Import statements (after grouping by std/third-party/local)
  - Error set members
  - Struct field lists (unless grouped by functionality)
  - Command-line flag documentation
- Examples where order matters:
  - Step-by-step instructions
  - Priority-based lists
  - Chronological sequences
  - Build dependencies

### Avoiding Repetition
- **Single source of truth**: State facts once in the most appropriate location
- **Cross-reference don't duplicate**: Link to information rather than restating it
- **Maintenance burden**: Every repeated fact must be updated in multiple places
- Examples of unnecessary repetition:
  - Stating test count in multiple sections
  - Listing features in both overview and details
  - Repeating build commands in different contexts
  - Duplicating flag descriptions across documents

### Documentation Examples

**Good (clear, active, specific, no repetition):**
```zig
/// Copies file from source to destination, preserving permissions.
/// Returns error.DiskFull when destination volume lacks space.
```

**Poor (passive, vague, repetitive):**
```zig
/// The file is copied by this function and various attributes might be preserved.
/// An error could be returned if issues are encountered.
/// This function copies files. // Repetition of first line
```

## Code Style and Conventions

### Writer-Based Error Handling

All utilities accept `stdout_writer` and `stderr_writer` parameters to prevent test pollution:

```zig
pub fn runUtil(allocator: Allocator, args: []const []const u8,
               stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Output to stdout_writer, errors to stderr_writer
    common.printErrorWithProgram(stderr_writer, "util", "error: {s}", .{msg});
    return @intFromEnum(common.ExitCode.general_error);
}
```

**Key points:**
- Pass writers explicitly, no abstractions
- Use `common.printErrorWithProgram()` for errors
- Tests use `common.null_writer` to suppress stderr
- Old functions (`common.fatal()`, `common.printError()`) cause compile errors


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

## Privileged Testing

**⚠️ CRITICAL: Zig 0.14 Fakeroot Issue**
- **Problem**: `testing.allocator` breaks under fakeroot when bypassing `--listen=-` server mode
- **Solution**: Use `privilege_test.TestArena` for ALL privileged tests
- **See**: https://github.com/ziglang/zig/issues/15091

```zig
test "privileged: chmod operation" {
    // REQUIRED: Use arena allocator, NOT testing.allocator
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    
    try privilege_test.requiresPrivilege();
    // Use 'allocator' throughout test, not 'testing.allocator'
}
```

Run with: `make test-privileged` or `scripts/run-privileged-tests.sh`

## Cross-Platform Testing

Docker-based Linux testing from macOS:
```bash
make test-linux        # Ubuntu tests
make shell-linux       # Interactive Ubuntu shell
make ci-linux          # Full CI locally
```
