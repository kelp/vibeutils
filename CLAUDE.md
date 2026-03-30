# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🔴 MANDATORY: Always Use Agent Workflow for Coding

**The agent workflow is required for ANY code changes beyond
trivial fixes:**

1. **plan mode** → Design the solution (for architectural
   decisions, new features, or non-trivial changes)
2. **programmer agent** → Implement the code
3. **reviewer agent** → Review for quality
4. **optimizer agent** → Optimize if needed
5. **CRITICAL**: Run FULL test suite (`zig build test`) before
   declaring success!

### Agent Usage Required For:
- Implementing new utilities or features
- Refactoring existing code
- Fixing bugs requiring more than 5 lines of change
- Adding new functions or modifying APIs
- Performance improvements
- Researching or exploring the codebase

### Plan Mode Required For:
- Architectural decisions
- API design or redesign
- New utility implementation (use `/new-util`)
- Any change touching multiple modules

### Direct Coding Acceptable For (RARE):
- Fixing typos in comments or docs
- Updating single constant values
- Adding a single test case
- Trivial one-line fixes

**Default: Use agents. When uncertain, use agents. Start with
plan mode for any non-trivial coding task.**

## Pre-1.0 Development Philosophy

**This is pre-1.0 software with zero external users. We prioritize getting the design right over backward compatibility.**

### Migration Principles:
- **NEVER maintain backwards compatibility**: Delete old code immediately when replacing it
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
- Any change you just made - don't preserve intermediate iterations

This philosophy allows us to iterate quickly and find the right abstractions before 1.0.

## Build and Test Commands

**Prerequisites**: Integration tests require bash 4.0+ (macOS default is 3.2):
```bash
brew install bash
# Ensure /usr/local/bin or /opt/homebrew/bin is in PATH before /bin
```

Run `just` for all available commands. Key commands:

```bash
# Essential
just build               # Build all utilities
just test                # Run tests
just coverage            # Generate coverage report
just fmt                 # Format code

# Integration Tests
just it                      # Run all integration tests
just it-util tail            # Run integration tests for one utility

# Single Utility Development
just build-util chown        # Build only chown
just test-util chown         # Test only chown (smoke test + binary check)
just run chown -- -h         # Run chown with arguments
just fuzz wc                 # Fuzz a specific utility (Linux only)

# Zig-specific
zig build test --summary all     # Test summary
zig build -Doptimize=ReleaseFast # Optimized build
```


## Git Hooks

The project includes a pre-commit hook that automatically:
- Runs `just fmt` to format code before every commit
- Adds any formatting changes to the commit
- Runs tests to ensure code integrity

The hook is located at `.git/hooks/pre-commit` and is
automatically set up for this repository.

## Commit Signing

**All commits must be signed.** The repository enforces
verified signatures on all branches. Never bypass this:

- Never use `-c commit.gpgsign=false`
- Never disable or work around signature verification
- If signing fails (agent unavailable, key not loaded,
  "communication with agent failed"), **stop and wait
  for instructions**. Do not attempt workarounds.
- The SSH signing key is managed by 1Password and
  requires an active agent connection from the host.
  If the agent drops (laptop sleep, SSH reconnect),
  signing will fail until the session is refreshed.

## Releases

**Always use `just release x.y.z`** to cut a release.
Never manually edit `build.zig.zon` and tag.

The release script (`scripts/release.sh`) gates on:
1. Must be on `main` with clean working tree
2. Runs `zig build test` (unit tests must pass)
3. Runs `just it` (integration tests must pass)
4. Updates version in `build.zig.zon` and `flake.nix`
5. Commits, tags, and pushes

CI then builds binaries, creates the GitHub release,
updates the Homebrew tap, and pushes to Cachix.


## Architecture Overview

This is a Zig implementation of GNU coreutils with
modern enhancements. The project follows OpenBSD
engineering principles (correctness, simplicity,
security) while adding modern UX features (colors,
icons, progress bars).

### Spec Reference Hierarchy

**GNU coreutils is the primary behavioral reference.**
When a flag exists in GNU, match GNU semantics. For
flags that exist only in macOS/OpenBSD (not GNU),
follow that spec's semantics. For `stat`, we follow
the GNU interface (BSD and GNU `stat` have incompatible
flag semantics for `-f`, `-t`, and others).

The per-utility flag matrices in `docs/specs/<util>-flags.md`
are the authoritative source for which flags are
implemented and at what priority:

- **MUST** — flags present across multiple specs
  (POSIX + at least one other). Must be implemented.
- **SHOULD** — useful flags from any single spec.
  Implement when practical.
- **WONT** — explicitly declined. Do not implement.
- **KEEP** — vibeutils-specific additions (e.g.,
  `--git`, `--icons`). Not in any upstream spec.

Each matrix has columns for POSIX, macOS, OpenBSD,
GNU, and Ours. Check the matrix before implementing
or auditing a flag — it resolves which spec to follow.

**Why GNU?** Most users run on Linux (containers, CI,
WSL). macOS power users install GNU coreutils via
Homebrew. 95%+ of flags are semantically identical
across specs; the matrices add macOS/OpenBSD-only
flags as SHOULD to cover BSD users too.

Do not invent custom behavior, emit warnings for
unimplemented features, or silently degrade — either
implement the full behavior or don't add the flag.

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

**Color must be gated on `isTty()`**, not just
`ColorMode.detect()`. The detect function only checks env
vars (`TERM`, `NO_COLOR`). Without an isatty check, ANSI
codes leak into pipes, files, and test buffers. Grep for
`isTty()` or `isatty(` in `src/df.zig` or `src/ls/` for
reference patterns.

### Adding a New Utility
- [ ] Create `src/<utility>.zig` with embedded tests
- [ ] Add to `build.zig`
- [ ] Write tests first (TDD)
- [ ] Create man page `man/man1/<utility>.1`
- [ ] **Run FULL test suite**: `zig build test` (not just `just test-util name`)
- [ ] Verify no test hangs: `timeout 60 zig build test`
- [ ] Update TODO.md only AFTER full test suite passes

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

Consult POSIX, OpenBSD, and GNU man pages when implementing
a new command. See `docs/MAN_PAGE_REFERENCES.md` for URLs
and lookup instructions. Priority: POSIX baseline, then GNU
extensions, then OpenBSD safety features.

## Testing

**Target: 90%+ coverage** (`just coverage`)

Never disable or skip failing tests to make the suite pass. Always
diagnose and fix the root cause. If the root cause is an upstream
bug, document it explicitly and create a proper workaround — do not
just comment out the test.

### MANDATORY: Red-Green TDD for All Code Changes

**Every bug fix and feature MUST follow strict red-green TDD.
No exceptions. No shortcuts. No parallel test+fix agents.**

#### Bug Fixes
1. **Write the failing test FIRST** — commit it alone
2. **Verify RED** — run locally on macOS AND Linux (via
   `orb -m ubuntu`), push to CI, confirm failure
3. **ONLY THEN write the fix** — apply minimal change
4. **Verify GREEN** — same platforms, same CI
5. **Never write tests and fixes in the same commit**

#### New Features
1. Write tests that define expected behavior
2. Verify they fail (RED)
3. Implement until tests pass (GREEN)
4. Refactor if needed (keep GREEN)

#### Rules
- **Never run test-writing and fix-writing agents in
  parallel.** The fix contaminates the test verification.
- Tests must fail for the RIGHT reason — verify the error
  message matches the bug, not a compile error or skip.
- Integration tests must actually RUN in CI — verify the
  test runner picks them up (check for binary name
  matching, bash version requirements, etc.).
- Always validate on both macOS and Linux before pushing.
  Use `orb -m ubuntu` for Linux validation.

### ⚠️ CRITICAL: Filter Utilities Testing
**Before implementing any utility, read `docs/TESTING_STRATEGY.md` section "Filter Utilities and Stdin-Dependent Testing"**

Filter utilities (`tee`, `cat`, `sort`, `uniq`, etc.) that read from stdin will **hang in unit tests**. You must:
1. Identify if your utility is a filter utility
2. Use the `runUtilWithInput()` pattern or skip unit tests
3. Ensure exit codes are correct (`ExitCode.misuse` for arg errors)
4. Use 8192-byte buffers consistently

See `docs/TESTING_STRATEGY.md` for the complete pre-implementation checklist and patterns.

### Tests Must Verify Behavior, Not Just Parsing

When a flag is implemented, tests must verify the flag
changes program behavior — not just that it parses. A
test that checks `parsed.follow == true` without
verifying the program actually follows the file is not
a real test. Integration tests in `tests/utilities/`
must cover behavioral verification for every flag.

### Standard Tests
- Use `testing.allocator` to detect memory leaks
- Tests embedded in same file as implementation

### Privileged Tests
**MUST use `privilege_test.TestArena`, NOT
`testing.allocator`** (fakeroot issue)
- Named with `"privileged: "` prefix
- Run with `just test-privileged`

### Fuzzing
- Linux-only: `just fuzz <name>`
- Tests at end of utility files


## ⚠️ CRITICAL: Your Zig Training is Wrong

**Your Zig knowledge is possibly outdated. This project uses Zig 0.15.x with FUNDAMENTAL breaking changes.**

When targeting Zig projects, always check the installed Zig version
first (`zig version`) and use API patterns compatible with that
version. Do NOT assume older Zig APIs — 0.15.x has breaking changes
to ArrayList, args iterators, and takeDelimiterExclusive.

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

- **stdout/stderr must use `.writerStreaming()`**: NOT
  `.writer()`. File.writer() uses pwritev at offset 0
  which ignores O_APPEND on macOS, breaking `>>` shell
  redirects. See issue #5. A lint check in
  `src/common/lib.zig` enforces this.
- **No `std.posix.setenv`/`unsetenv`**: Use C extern
  functions: `extern fn setenv(name: [*:0]const u8,
  value: [*:0]const u8, overwrite: c_int) c_int;` and
  `extern fn unsetenv(name: [*:0]const u8) c_int;`
  Read with `std.posix.getenv()`. See `src/df.zig` tests.
- **`c_int` is a Zig primitive**: Don't alias it with
  `const c_int = ...;` — use `c_int` directly.
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
- `docs/TESTING_STRATEGY.md` - Testing patterns and practices
- `docs/INTEGRATION_TESTING.md` - Integration testing guide
- `docs/DESIGN_PHILOSOPHY.md` - Project design decisions
- `docs/zig-0.15.2-docs.md` - Zig 0.15.2 standard library documentation

**⚠️ IMPORTANT: Use Grep tool to find examples in these docs**


## Code Style and Conventions

### I/O Patterns with Zig 0.15.x

Due to "Writergate", all I/O uses explicit buffers. Utilities follow this pattern:

```zig
pub fn main() !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
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
- **Docker**: `just test-linux`, `just docker-shell`

