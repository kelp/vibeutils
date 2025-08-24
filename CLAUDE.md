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

# Single Utility Development
make build UTIL=chown      # Build only chown
make test UTIL=chown       # Test only chown (smoke test + binary check)
make run UTIL=chown ARGS="-h"  # Run chown with arguments
make fuzz UTIL=wc          # Fuzz a specific utility (Linux only)

# Zig-specific
zig build test --summary all     # Test summary
zig build -Doptimize=ReleaseFast # Optimized build
zig test src/echo.zig            # Test single file (requires module setup)
```


## Git Hooks

The project includes a pre-commit hook that automatically:
- Runs `make fmt` to format code before every commit
- Adds any formatting changes to the commit
- Runs tests to ensure code integrity

The hook is located at `.git/hooks/pre-commit` and is automatically set up for this repository.


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
   - Common library in `src/common/` - see source for modules
   - Each utility in `src/<utility>.zig` with embedded tests
   - Man pages in `man/man1/` using mdoc format

### Terminal Adaptation Strategy

The styling system (`src/common/style.zig`) automatically detects:
- NO_COLOR environment variable
- Terminal type (dumb, 16-color, 256-color, truecolor)
- Unicode support via LANG/LC_ALL
- Falls back gracefully when features aren't available

### Adding a New Utility
- [ ] Create `src/<utility>.zig` with embedded tests
- [ ] Add to `build.zig`
- [ ] Write tests first (TDD)
- [ ] Create man page `man/man1/<utility>.1`
- [ ] Update TODO.md

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

## Testing

**Target: 90%+ coverage** (`make coverage`)

### Standard Tests
- Use `testing.allocator` to detect memory leaks
- Tests embedded in same file as implementation

### Privileged Tests 
**⚠️ MUST use `privilege_test.TestArena`, NOT `testing.allocator`** (fakeroot issue)
- Named with `"privileged: "` prefix
- Run with `make test-privileged`

### Fuzzing
- Linux-only: `make fuzz UTIL=<name>`
- Tests at end of utility files


## ⚠️ CRITICAL: Your Zig Training is Wrong

**Your Zig knowledge is from pre-0.11.0. This project uses 0.15.1 with FUNDAMENTAL breaking changes.**

### MANDATORY: Check Breaking Changes First

**Before writing ANY Zig code:**
1. Open `docs/ZIG_BREAKING_CHANGES.md` - quick reference table of what changed
2. When you get an error, grep that doc for the error message
3. The patterns you know are WRONG - always verify

**Most common mistakes you WILL make:**
- ❌ `std.io.getStdOut()` - doesn't exist (Writergate)
- ❌ `usingnamespace` - removed from language  
- ❌ `async`/`await` - removed from language
- ❌ Generic writers - everything is concrete now
- ❌ `/` on runtime signed ints - use `@divTrunc`

**Quick lookup:** `grep "error message" docs/ZIG_BREAKING_CHANGES.md`

## Common Pitfalls You WILL Hit

- **ArrayList forgot allocator**: Every method needs it now (append, deinit, writer, etc.)
- **I/O buffer scoping**: Must flush before buffer goes out of scope or data is lost
- **Privileged test hang**: Using `testing.allocator` instead of `privilege_test.TestArena`
- **Import errors**: Many std lib items moved - grep the docs
- **Generic types**: Writers/Readers aren't generic anymore - use `anytype` or concrete types

## Security Philosophy: Trust the OS

System utilities implement functionality; the OS kernel enforces security.

**DON'T**: Add path validation, maintain "protected" lists, prevent "../" paths
**DO**: Let the OS handle permissions and report its errors

```zig
// ❌ WRONG: Security theater
if (std.mem.indexOf(u8, path, "../") != null) return error.PathTraversal;

// ✅ RIGHT: Trust the OS
try std.fs.cwd().deleteFile(path);
```

Only validate for **correctness**:
- Same-file detection (prevent data loss)
- Buffer overflow prevention
- Atomic operation guarantees

## Documentation References

**📖 Core Documentation:**
- **`docs/ZIG_BREAKING_CHANGES.md`** - ⚠️ READ FIRST - fixes your outdated training
- `docs/ZIG_PATTERNS.md` - Zig idioms and patterns
- `docs/ZIG_STYLE_GUIDE.md` - Code style conventions
- `docs/STD_LIBRARY_SUMMARY.md` - Zig std library reference
- `docs/TESTING_STRATEGY.md` - Testing patterns and practices
- `docs/DESIGN_PHILOSOPHY.md` - Project design decisions
- `docs/zig-0.15.1-release-notes.md` - Full release notes
- `docs/zig-0.15.1-docs.md` - Full Zig 0.15.1 documentation

**📖 Fuzzing Documentation:**
- `docs/FUZZING.md` - Comprehensive fuzzing guide (quick start, architecture, usage patterns)

**⚠️ IMPORTANT: Use Grep tool to find examples in these docs**


## Code Style and Conventions

### I/O Patterns with Zig 0.15.1

Due to "Writergate", all I/O uses explicit buffers. Utilities follow this pattern:

```zig
pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    
    // Similar for stderr
}

pub fn runUtil(allocator: Allocator, args: []const []const u8,
               stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Use passed writers for output
    common.printErrorWithProgram(allocator, stderr_writer, "util", "error: {s}", .{msg});
    return @intFromEnum(common.ExitCode.general_error);
}
```


### Memory Management
- **CLI tools**: Arena allocator (preferred)
- **Tests**: `testing.allocator` (detects leaks)
- **Privileged tests**: `privilege_test.TestArena` (fakeroot issue)
- Always `defer` cleanup immediately after allocation

### Argument Parsing
- Use our custom argparse module (`src/common/argparse.zig`)
- Support both short (`-n`) and long (`--number`) options
- Include `--help` and `--version` for all utilities


### Project Style Notes

**This project follows standard Zig conventions** with these specifics:
- Tests embedded in same file as implementation
- Use our custom argparse, not external libraries
- Error messages via `common.printErrorWithProgram(allocator, stderr, "prog", "msg", .{})`


## Cross-Platform Testing
- **OrbStack**: `orb -m ubuntu zig build test` (ubuntu, debian, arch available)
- **Docker**: `make test-linux`, `make shell-linux`, `make ci-linux`
