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

# Single Utility Development (NEW!)
make build UTIL=chown      # Build only chown
make test UTIL=chown       # Test only chown (smoke test + binary check)
make run UTIL=chown ARGS="-h"  # Run chown with arguments

# Zig-specific
zig build test --summary all     # Test summary
zig build -Doptimize=ReleaseFast # Optimized build
zig test src/echo.zig            # Test single file (requires module setup)
```

### Working with Individual Utilities

When developing or debugging a specific utility, use the `UTIL` variable:

```bash
# Build and test workflow for a single utility
make build UTIL=basename   # Build just basename
make test UTIL=basename    # Quick test of basename
make run UTIL=basename ARGS="/path/to/file"  # Run it

# The UTIL variable works consistently across operations:
make build UTIL=cp         # Build cp
make test UTIL=cp          # Test cp  
make fuzz UTIL=cp          # Fuzz cp (Linux only)
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

**📖 See `docs/TESTING_STRATEGY.md` for comprehensive testing guide**
**📖 See `docs/ZIG_PATTERNS.md` for Zig-specific patterns**

Quick note: Always use `testing.allocator` to detect memory leaks.

### Fuzzing

**📖 See `docs/FUZZING.md` for complete fuzzing guide**
**📖 See `docs/SELECTIVE_FUZZING.md` for selective fuzzing system**
**📖 See `docs/FUZZ_ARCHITECTURE.md` for architecture details**

Quick notes:
- Linux-only (returns "no fuzz tests found" on macOS)
- Use `zig build fuzz-<utility>` for selective fuzzing
- Fuzz tests go at end of utility files (not separate files)


## Zig 0.15.1 Critical Changes

### Removed Features (Will Not Compile)
- **`usingnamespace`** keyword - completely removed
- **`async`/`await`** - removed from language
- **`BoundedArray`** - use regular arrays or ArrayList
- **Generic readers/writers** - see Writer Migration above

### Changed APIs
- **ArrayList** now defaults to unmanaged version
- **Build system** requires explicit `root_module` configuration
- **I/O completely redesigned** - see migration guide

### New Restrictions
- Stricter `undefined` usage in arithmetic
- More restrictive compile-time type coercion
- Cannot store `type` fields in runtime structs

## ⚠️ CRITICAL: Dealing with Zig's Rapid Evolution

**Zig 0.15.1 has breaking changes that happened after your training cutoff. You MUST verify everything.**

### How to Find Current Zig 0.15.1 APIs

**When you encounter a Zig compilation error or need to look up an API:**

1. **First, check the release notes for breaking changes:**
   ```
   Use Grep tool:
   - pattern: "ArrayList" or "Writergate" or the specific API
   - path: docs/zig-0.15.1-release-notes.md
   - This file is only 1,620 lines, documents all breaking changes
   ```

2. **Then look up the current API in the full docs:**
   ```
   Use Grep tool:
   - pattern: "std\.ArrayList" or "std\.fs\.File" or specific function
   - path: docs/zig-0.15.1-docs.md  
   - This file is 15,664 lines but Grep with -C flag gives context
   ```

3. **Find working examples in our codebase:**
   ```
   Use Grep tool:
   - pattern: "initCapacity" or "writer\(&" or the new pattern
   - path: src/
   - Look especially at src/basename.zig (already migrated)
   ```

### Example: When you see "no member named 'init'" error

```
1. Grep "ArrayList.*init" in docs/zig-0.15.1-release-notes.md
   → Find: "ArrayList: make unmanaged the default"
   
2. Grep "ArrayList" in src/basename.zig
   → Find: "std.ArrayList(u8).initCapacity(allocator, 0)"
   
3. Now you know: init() → initCapacity(allocator, 0)
```

### Quick Reference for Common Breaking Changes

Instead of remembering these, use Grep to find them:
- **I/O changes**: Grep "Writergate" in release notes
- **ArrayList changes**: Grep "ArrayList: make unmanaged" in release notes  
- **Removed features**: Grep "usingnamespace|async|BoundedArray" in release notes

### Documentation Priority Order

1. **Compiler errors are truth** - If it doesn't compile, the API changed
2. **docs/zig-0.15.1-release-notes.md** - Explains what changed and why
3. **docs/zig-0.15.1-docs.md** - Shows current API syntax
4. **src/basename.zig** - Working example of migrated code
5. **docs/ZIG_0_15_1_WRITER_MIGRATION.md** - Our migration guide

**Remember: You have Grep tool. Use it liberally on these docs rather than guessing!**

#### Project Zig Version

This project requires **Zig 0.15.1** (minimum version set in `build.zig.zon`). When looking up documentation, ensure compatibility with this version.

**⚠️ CRITICAL: Zig 0.15.1 Breaking Changes ("Writergate")**

Zig 0.15.1 fundamentally changed how I/O works. **Readers and Writers are no longer generic** - they use `std.Io.Writer` and `std.Io.Reader` (capital I, lowercase o) with explicit buffers:

```zig
// OLD (Zig 0.14.1) - DO NOT USE
const stdout = std.io.getStdOut().writer();

// NEW (Zig 0.15.1) - REQUIRED PATTERN
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
// MUST flush before buffer goes out of scope!
defer stdout.flush() catch {};
```

**Key changes:**
- `std.io.getStdOut()` → `std.fs.File.stdout()`
- `std.io.bufferedWriter` → REMOVED (use buffer in writer)
- Writers return `std.Io.Writer` interface (not generic!)

**See `docs/ZIG_0_15_1_WRITER_MIGRATION.md` for complete migration guide.**

### Critical Zig 0.15.1 Migration Notes (From Real Experience)

#### ArrayList API Changes
ArrayList is now "unmanaged" by default, requiring allocator parameters everywhere:

```zig
// OLD (Zig 0.14.1)
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append(value);
const slice = try list.toOwnedSlice();
const writer = list.writer();

// NEW (Zig 0.15.1) - allocator required for ALL operations
var list = try std.ArrayList(u8).initCapacity(allocator, 0);
defer list.deinit(allocator);  // Note: allocator parameter
try list.append(allocator, value);  // Note: allocator parameter
const slice = try list.toOwnedSlice(allocator);  // Note: allocator parameter
const writer = list.writer(allocator);  // Note: allocator parameter
```

#### Migration Order (Learned from basename.zig)
1. **Fix main() first** - Update I/O patterns
2. **Fix ArrayList usage** - Add allocator parameters everywhere
3. **Fix tests** - Update test helpers and ArrayList usage
4. **Fix common libraries** - argparse.zig, test_utils.zig, etc.

#### Common Compilation Errors and Fixes
```zig
// ERROR: struct 'Io' has no member named 'getStdOut'
// OLD: std.io.getStdOut()
// NEW: std.fs.File.stdout()

// ERROR: struct 'array_list.Aligned' has no member named 'init'
// OLD: std.ArrayList(T).init(allocator)
// NEW: std.ArrayList(T).initCapacity(allocator, 0)

// ERROR: member function expected 1 argument(s), found 0
// OLD: list.deinit()
// NEW: list.deinit(allocator)

// ERROR: member function expected 1 argument(s), found 0
// OLD: list.writer()
// NEW: list.writer(allocator)
```

#### Recommended Zig Documentation Sources

When working with Zig, use the following library IDs for best results:
- `/jedisct1/zig-mcp-doc` - MCP-friendly Zig documentation (9054 code snippets, trust score 9.7)
- `/context7/ziglang` - General Zig documentation (5449 code snippets, trust score 7.5)
- `/jedisct1/zig-for-mcp` - Alternative MCP-friendly docs (8836 code snippets, trust score 9.7)
- `/ziglang/zig` - Official Zig documentation (279 code snippets, version 0.14.1 available)

For version-specific documentation:
- Some libraries support version queries (e.g., `/ziglang/zig/0.15.1`)
- When in doubt, check the documentation source to ensure it covers Zig 0.15.1 features

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
//   - context7CompatibleLibraryID: "/ziglang/zig/0.15.1"
//   - topic: "std.fs"

// For memory management:
// Use same command but with topic: "allocator" or "std.mem"

// For specific modules:
// - topic: "std.process" for process operations
// - topic: "std.io" for I/O operations
// - topic: "builtin" for builtin functions
// - topic: "std.heap" for heap allocators
```

**Best Practices for Using context7:**
1. **Check early and often** - Don't wait until you're stuck
2. **Verify assumptions** - What worked in Zig 0.14 may have changed in 0.15.1
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

## Documentation References

**📖 Core Documentation:**
- `docs/ZIG_PATTERNS.md` - Zig idioms and patterns
- `docs/ZIG_STYLE_GUIDE.md` - Code style conventions
- `docs/STD_LIBRARY_SUMMARY.md` - Zig std library reference
- `docs/TESTING_STRATEGY.md` - Testing patterns and practices
- `docs/DESIGN_PHILOSOPHY.md` - Project design decisions
- `docs/ZIG_0_15_1_WRITER_MIGRATION.md` - I/O migration guide

**📖 Fuzzing Documentation:**
- `docs/FUZZING.md` - Main fuzzing guide
- `docs/SELECTIVE_FUZZING.md` - Selective fuzzing system
- `docs/FUZZ_ARCHITECTURE.md` - Fuzzing architecture

**⚠️ IMPORTANT: Use grep/search to find examples in these docs**

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

### Code Style and Patterns

**📖 See `docs/ZIG_STYLE_GUIDE.md` for complete style guide**
**📖 See `docs/ZIG_PATTERNS.md` for idiomatic Zig patterns**
**📖 See `docs/STD_LIBRARY_SUMMARY.md` for std library reference**

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

### OrbStack Linux Testing
Use OrbStack to run commands on Linux distributions directly from macOS:
```bash
orb list                          # List available Linux VMs
orb -m ubuntu <command>           # Run command on Ubuntu
orb -m debian <command>           # Run command on Debian  
orb -m arch <command>             # Run command on Arch Linux

# Examples:
orb -m ubuntu zig build test      # Run tests on Ubuntu
orb -m debian make build          # Build on Debian
orb -m arch ./zig-out/bin/ls -la  # Test binary on Arch

# The repo is accessible at the same path in all VMs:
# /Users/tcole/code/vibeutils-project/vibeutils
```

**Available distributions:**
- ubuntu (plucky) - arm64
- debian (trixie) - arm64  
- arch (current) - arm64

### Docker-based Testing (Alternative)
```bash
make test-linux        # Ubuntu tests
make shell-linux       # Interactive Ubuntu shell
make ci-linux          # Full CI locally
```
