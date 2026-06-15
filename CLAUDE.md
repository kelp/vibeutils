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

A release is a **two-command, two-gate** flow. Always use
the `just` recipes; never manually edit `build.zig.zon` and
tag.

```
just release x.y.z       # Gate 1 (local): tests + push main
# ... wait for CI, confirm ...
just release-tag x.y.z   # Gate 2 (CI): wait for green, push tag
```

### 🔴 MANDATORY release gate

**Unit AND integration tests are hard gates at BOTH layers.
Local first, then CI — neither may be skipped.**

1. **Local hard gate** (`just release`, via
   `scripts/release.sh`): runs `zig build test` and
   `just it` on the host. **When run from macOS, it also
   runs both suites on Linux via OrbStack (`orb -m ubuntu
   zig build test` for units; `orb -m ubuntu zig build`
   then `orb -m ubuntu bash tests/integration.sh` for
   integration — the VM has `zig` but not `just`)** — a
   release cut from the Mac must pass on BOTH platforms
   locally. If any suite fails
   — or if integration tests can't run (bash 4+ required;
   macOS default is 3.2) or `orb` is missing — the script
   aborts before pushing anything. It then pushes only the
   version-bump commit to `main`, which triggers CI. **It
   never creates or pushes the tag.**
2. **CI hard gate** (`just release-tag`, via
   `scripts/release-tag.sh`): waits for `test.yml` AND
   `integration.yml` to pass on the exact release commit
   on **every** runner (`macos-latest` AND
   `ubuntu-latest`) before creating and pushing the tag.

**Never push a release tag without specific, explicit
confirmation first.** The tag push is the irreversible
step — it triggers the build/publish pipeline and
[immutable releases][imm] locks the tag and assets at
publish. Pushing the version-bump commit to `main` is
safe (it triggers CI); pushing the *tag* requires the
human to confirm, after CI is green on all runners, that
this specific release should go out. Running
`just release-tag` IS that confirmation — do not run it
on the human's behalf, and do not infer confirmation from
an earlier "cut a release" instruction.

Required ordering:
1. `just release x.y.z` — local tests pass, version-bump
   commit lands on `main`.
2. Wait for `test.yml` and `integration.yml` to pass on
   that commit on **both** `macos-latest` and
   `ubuntu-latest`.
3. Get explicit confirmation to release.
4. `just release-tag x.y.z` — re-verifies green CI, then
   pushes the tag.

### Changelog workflow

`CHANGELOG.md` is the source of truth for release notes.
The GitHub release body is extracted from it at release
time. Workflow:

1. As you land user-visible changes, add bullets under the
   `## Unreleased` heading at the top of `CHANGELOG.md`.
   Use `### Added`, `### Changed`, `### Fixed`,
   `### Infrastructure`, etc. as subsections.
2. When cutting a release, `just release x.y.z` rewrites
   that heading to `## vX.Y.Z — YYYY-MM-DD` and commits
   the change alongside the version bumps.
3. After release, add a fresh empty `## Unreleased`
   section at the top for the next cycle.

Never write a `## vX.Y.Z` heading by hand — the release
script handles the promotion. Versions in the changelog
are always `v`-prefixed; the `v` is stripped when passing
the version to the script (`just release 0.9.3`, not
`just release v0.9.3`).

### Release script gates

`scripts/release.sh` (`just release x.y.z`) gates on:
1. Must be on `main` with clean working tree
2. `## Unreleased` section exists and is non-empty
3. Runs `zig build test` (unit tests must pass)
4. Runs `just it` (integration tests must pass) — a hard
   gate: aborts if bash 4+ is unavailable rather than
   skipping
5. On macOS, re-runs both suites on Linux via OrbStack
   (`orb -m ubuntu`) — a hard gate; aborts if `orb` is
   missing
6. Updates version in `build.zig.zon` and `flake.nix`
7. Promotes `## Unreleased` to `## vX.Y.Z — <date>` in
   `CHANGELOG.md`
8. Commits the bump and pushes it to `main`. **Stops
   there — it does not create or push the tag.**

`scripts/release-tag.sh` (`just release-tag x.y.z`) gates
on:
1. Must be on `main` with clean working tree
2. `build.zig.zon` is already at `x.y.z` (i.e. `just
   release` ran)
3. `HEAD` matches `origin/main` (the release commit is
   pushed, so CI is running on it)
4. Tag `vx.y.z` does not already exist locally or on
   origin
5. Waits for `test.yml` AND `integration.yml` to conclude
   **success** on the release commit (each run covers the
   full `macos-latest` + `ubuntu-latest` matrix, via
   `gh run watch --exit-status`)
6. Only then creates the tag and pushes it

CI then builds binaries, creates a **draft** release
with assets and notes extracted from the `## vX.Y.Z`
section of `CHANGELOG.md`, publishes the release,
updates the Homebrew tap, and pushes to Cachix.

The repo has [immutable releases][imm] enabled, which
locks the git tag and assets the moment a release is
published — so CI must attach every asset to the draft
before flipping it to published. Only the title and
release notes remain editable after publish.

[imm]: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases


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

**Your Zig knowledge is outdated. This project targets Zig 0.16.0.
0.16 introduced Writergate-scale breaking changes on top of the
0.15.x changes you may have absorbed.**

`build.zig.zon` pins `minimum_zig_version = "0.16.0"` and `flake.nix`
pins the same toolchain. The 0.15 → 0.16 migration is complete.
Always check `zig version` and prefer the patterns in
`docs/ZIG_BREAKING_CHANGES.md` over anything you remember from
training.

### MANDATORY: Check Breaking Changes First

**Before writing ANY Zig code:**
1. Open `docs/ZIG_BREAKING_CHANGES.md` — full 0.15.x → 0.16
   migration catalog with old/new code blocks per item.
2. When you get an error, grep that doc for the error message
   or symbol name.
3. The patterns you know are likely WRONG — always verify.

**Most common 0.16 mistakes you WILL make:**
- ❌ Forgetting the `io: Io` parameter on blocking APIs
  (`file.close()` → `file.close(io)`)
- ❌ `std.fs.File.stdout()` — namespace moved to
  `std.Io.File.stdout()`
- ❌ `std.os.environ` / global args — gone; route
  `std.process.Init` through your call chain
- ❌ `std.mem.indexOf*` — renamed to `find*`
- ❌ `std.fs.cwd()` / `std.fs.path` / `std.fs.Dir` /
  `std.fs.File` — moved to `std.Io.*`
- ❌ `File.Stat.atime` as non-optional — must
  `orelse error.FileAccessTimeUnavailable`
- ❌ `usingnamespace`, `async`/`await` — removed in 0.15
  and still gone
- ❌ `@Type(.{ .int = ... })` — replaced by `@Int(.unsigned, 10)`
  and 7 other concrete builtins
- ❌ Runtime indexing of vectors — coerce to array first
- ❌ Returning `&local_var` for trivial cases — now an error
- ❌ `std.process.Child.init/spawn` — use
  `std.process.spawn(io, .{...})`
- ❌ `std.Thread.{Mutex,Condition,ResetEvent,WaitGroup,...}`
  — moved to `std.Io.{Mutex,Condition,Event,Group,...}`

**Quick lookup:** `grep "error message" docs/ZIG_BREAKING_CHANGES.md`

## Common Pitfalls You WILL Hit

- **Stdout/stderr buffered writer in 0.16:** verified by
  running against installed 0.16.0. Use
  `std.Io.File.stdout().writerStreaming(init.io, &buf)` —
  `writerStreaming` initializes in `.streaming` mode (O_APPEND
  respected, shell `>>` works); `writer` initializes in
  `.positional` mode and silently breaks `>>`. Same lesson as
  0.15. The lang ref's "Hello World" example uses the
  unbuffered `writeStreamingAll(io, "...")` shortcut — fine
  for one-off prints, not for utilities that print streams.
- **The `writerStreaming` lint check in `src/common/lib.zig`**
  (issue #5 regression test) scans `src/` for the buggy
  `.stdout().writer(` / `.stderr().writer(` patterns and fails
  the build if any utility uses positional mode. Already updated
  for 0.16's `writerStreaming(io, &buf)` signature.
- **Environment variables are not global in 0.16** — route them
  through `init.environ_map` from `std.process.Init`. See
  `src/env.zig` for the canonical plumbing pattern; no
  `std.posix.setenv`/`unsetenv` C-extern workarounds remain.
- **ArrayList allocator parameter** survived 0.15;
  every method (append, deinit, writer) takes it.
  `.empty` is the new init form.
- **I/O buffer scoping**: must flush before the buffer goes
  out of scope or data is lost.
- **Privileged test hang**: use `privilege_test.TestArena`,
  never `testing.allocator` (fakeroot incompatibility).
- **Tests use `std.testing.io`** in addition to
  `std.testing.allocator`.
- **`fixedBufferStream` is gone**: use
  `var w: std.Io.Writer = .fixed(buffer);` /
  `var r: std.Io.Reader = .fixed(data);`.

## Security Philosophy: Trust the OS

System utilities implement functionality; the OS kernel enforces security.

**DON'T**: Add path validation, maintain "protected" lists, prevent "../" paths
**DO**: Let the OS handle permissions and report its errors

```zig
// ❌ WRONG: Security theater
if (std.mem.find(u8, path, "../") != null) return error.PathTraversal;

// ✅ RIGHT: Trust the OS
try std.Io.Dir.cwd().deleteFile(io, path);
```

Only validate for **correctness**:
- Same-file detection (prevent data loss)
- Buffer overflow prevention
- Atomic operation guarantees

## Documentation References

**📖 Core Documentation:**
- **`docs/ZIG_BREAKING_CHANGES.md`** - ⚠️ READ FIRST - 0.15.x → 0.16 migration catalog
- `docs/ZIG_PATTERNS.md` - Zig 0.16.x idioms and patterns
- `docs/TESTING_STRATEGY.md` - Testing patterns and practices
- `docs/INTEGRATION_TESTING.md` - Integration testing guide
- `docs/DESIGN_PHILOSOPHY.md` - Project design decisions
- `docs/zig-0.16.0-docs.md` - Zig 0.16.0 language reference (current target)
- `docs/zig-0.16.0-release-notes.md` - Zig 0.16.0 release notes
- `docs/zig-0.15.2-docs.md` - Zig 0.15.2 reference (historical, for migration diffs)

**⚠️ IMPORTANT: Use Grep tool to find examples in these docs**


## Code Style and Conventions

### I/O Patterns with Zig 0.16.x

In 0.16 every blocking API takes an `Io` parameter. The
recommended entry shape is "Juicy Main" with
`std.process.Init`, which bundles allocator, io, arena,
environ_map, and args. **Verified by compiling against
installed 0.16.0:**

```zig
pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer =
        std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer =
        std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    try stdout.print("hello: {s}\n", .{name});
}

pub fn runUtil(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    common.printErrorWithProgram(allocator, stderr_writer, "util", "error: {s}", .{msg});
    return @intFromEnum(common.ExitCode.general_error);
}
```

Use `writerStreaming` (not `writer`) for stdout/stderr:
`writer` runs in `.positional` mode and silently ignores
O_APPEND, breaking shell `>>` redirects on macOS. Same
lesson as 0.15. The lang ref's `writeStreamingAll(io, "...")`
shortcut is fine for one-off prints (e.g. "Hello, World!")
but not for utilities that stream output.

For utilities that don't need allocator/io, use
`pub fn main(init: std.process.Init.Minimal) !void` — it
exposes only `args` and `environ`.


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

## Tiger Style (TigerBeetle Coding Methodology)

This project follows [Tiger Style][upstream]. Apply these
rules when writing or modifying Zig in this repo.

For the long-form reference with rationale and examples,
read `${CLAUDE_PLUGIN_ROOT}/docs/TIGER_STYLE_REFERENCE.md`
or run `/tiger-style:tiger-patterns`.

[upstream]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

### Safety: Assertions

- Assert every function's arguments, return values,
  pre/postconditions, and invariants.
- **Minimum two assertions per function** on average.
- Pair assertions: for every property, assert it in at
  least two different code paths.
- Assert the **positive space** you expect AND the
  **negative space** you don't expect.
- Split compound assertions: prefer `assert(a); assert(b);`
  over `assert(a and b);`.
- Assert relationships of compile-time constants as a
  sanity check.

### Safety: Bounded Loops, No Recursion

- **Do not use recursion.** All bounded executions must be
  bounded by explicit iteration.
- Every loop and every queue must have a fixed upper bound
  to prevent infinite loops or tail latency spikes.
- Where a loop cannot terminate (e.g. an event loop), this
  must be asserted.

### Safety: Static Memory

- **All memory must be statically allocated at startup.**
- No memory may be dynamically allocated (or freed and
  reallocated) after initialization.

### Safety: Error Handling and Control Flow

- **All errors must be handled.** No silent drops.
- Add braces to `if` statements unless the body fits on a
  single line (defense against `goto fail;` bugs).
- Split compound conditions into nested branches; state
  invariants positively.
- Don't react directly to external events; run at your own
  pace. Decouple input from action.
- Ensure functions run to completion without suspending,
  so precondition assertions hold throughout the function.

### Naming

- Use `snake_case` for function, variable, and file names.
- **Do not abbreviate variable names**, with the rare
  exception of primitive integers used as sort/matrix
  arguments.
- Acronyms get proper capitalization: `VSRState`, not
  `VsrState`.
- Add units or qualifiers as **suffixes, sorted by
  descending significance**: `latency_ms_max`, not
  `max_latency_ms`.
- When naming related variables, prefer names with the
  same character count so they line up in source.
- A helper called by a single function should be prefixed
  with the caller's name: `read_sector_callback()`.
- Callbacks go **last** in the parameter list.
- Use Zig's named-argument pattern (`options: struct`)
  when arguments could be mixed up at the call site.

### Function Shape

- **Hard limit: 70 lines per function.** No exceptions.
- Aim for the inverse-hourglass: few parameters, simple
  return type, meaty logic in between.
- **Centralize control flow.** Don't duplicate branching
  in handlers and helpers.
- **Push `if`s up, push `for`s down.** Keep branching in
  one function; move non-branchy work to helpers.

### Variable Scope

- Declare variables at the **smallest possible scope**.
- **Minimize the number of variables in scope** to reduce
  the probability of misuse.
- Calculate or check variables close to where they're
  used. Don't introduce variables before they're needed.
- **Don't duplicate variables or take aliases to them.**
- For arguments larger than 16 bytes that shouldn't be
  copied, pass `*const T`.
- Group resource allocation and its corresponding `defer`
  with surrounding newlines so leaks are easier to spot.

### Comments

- Comments are **sentences**: space after the slash,
  capital letter, full stop (or colon if introducing a
  following block).
- **Always motivate. Always say why.** Code already shows
  what; comments explain why.
- Don't forget to say *how* for non-obvious tests:
  describe goal and methodology.

### Formatting (Zig-Specific)

- Run `zig fmt`.
- **4 spaces of indentation** (not 2).
- **Hard limit all line lengths to 100 columns**, no
  exceptions. Never hide code behind horizontal scroll.
- To wrap a function signature or struct, add a trailing
  comma and let `zig fmt` do the rest.

### Types, Division, and Library Calls

- Use **explicitly-sized types** like `u32`. Avoid
  architecture-dependent `usize` unless interfacing with
  APIs that require it.
- Show intent for division: use `@divExact`, `@divFloor`,
  or `div_ceil` rather than bare `/`. (See `/zig-check`
  for `@divTrunc`/`@divFloor` enforcement.)
- **Pass options explicitly** at the call site rather
  than relying on defaults.

### Performance Mindset

- The huge (1000x) performance wins come at the **design
  phase**, before you can measure. Sketch back-of-envelope
  numbers for the four resources (network, disk, memory,
  CPU) and their two characteristics (bandwidth, latency).
- **Optimize the slowest resource first**: network, then
  disk, then memory, then CPU.
- **Amortize** costs by batching accesses.
- Extract hot loops into standalone functions with
  primitive arguments (no `self`) to enable compiler
  optimization and human inspection.

### When Auditing

Run `/tiger-style:tiger-check` to scan changed Zig files
for mechanical Tiger Style violations: oversized
functions, long lines, `usize` usage, direct recursion,
compound asserts, and unbounded `while (true)`.

