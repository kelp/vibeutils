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

**This is pre-1.0 software with zero external users. We
prioritize getting the design right over backward
compatibility.**

- NEVER maintain backwards compatibility: no deprecated
  code, no compatibility layers, no preserved intermediate
  iterations. Delete old code when replacing it.
- If the current API is wrong, change it completely.
- Full migrations only: when changing a pattern, update
  ALL code to the new pattern in the same change.

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

The repo ships a tracked pre-commit hook at
`.githooks/pre-commit` that **blocks any commit unless
`zig fmt` is clean**. When formatting is not clean it runs
`zig build fmt` to fix it and then aborts, so you review the
reformatted files and re-commit. When the tree is already
clean (the common case — the dev and the TDD workflow run
`just fmt`), it is a fast no-op and the commit proceeds.

Install it once per clone:

```bash
just install-hooks   # sets core.hooksPath to .githooks
```

The hook does NOT run the test suite (kept fast); run
`zig build test` yourself, or rely on CI.

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

`scripts/release.sh` and `scripts/release-tag.sh` are the
authority on the exact gate sequence (clean tree on main,
non-empty `## Unreleased`, both test suites on both
platforms, version bumps in `build.zig.zon` + `flake.nix`,
changelog promotion, CI-green wait before tagging). Read
them before changing the flow; don't reimplement their
checks by hand.

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

**Where GNU and BSD directly conflict, we follow BSD.**
A direct conflict is the same spelling — flag letter,
format directive, or default behavior — meaning
different things in the two specs. In that case
macOS/OpenBSD wins.

Everywhere else, the spec that defines the flag governs:

- Flag in GNU only → GNU semantics.
- Flag in macOS/OpenBSD only → that spec's semantics.
- Flag in both with the same meaning → no decision to
  make; this is 95%+ of the surface.

So GNU remains the reference for the large majority of
behavior. The rule only bites on true collisions, of
which there are few — `stat`'s `-f` and `-t` are the
canonical examples, and `stat` implements the BSD
interface because of it.

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

**Why BSD on conflicts?** A collision is the one case
where a script cannot be written portably, so the tie
has to break somewhere. It breaks toward BSD because
that is where the damage lands: we ship a Homebrew
formula whose `vibebin` directory is meant to go on
`PATH` ahead of `/usr/bin`, so on macOS our binary
shadows the platform's own tool. Under GNU semantics a
BSD script does not fail — it silently means something
else. On Linux there is no such shadowing, and GNU
users reach for the long spellings anyway.

The specs agree on 95%+ of the surface, so this rule
decides very little. Where it does decide, prefer being
the same as the tool we displace.

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
- [ ] Register in the `utilities` array in `build/utils.zig`
      (metadata-driven; `build.zig` reads it — don't edit
      `build.zig` itself)
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

### MANDATORY: Test-First Discipline for All Code Changes

The goal is not ceremony — it is that **no change lands
without a test that provably catches a regression in the
behavior being changed.** Two things are STRICTLY enforced;
everything else is judgment.

#### Strictly enforced (no exceptions)

1. **For a single unit of work, tests and implementation are
   written by SEPARATE agents** — never the same agent. A
   fix-writing agent must not author or alter the test that
   guards its fix; that contaminates the verification.
   Parallelism is fine and encouraged ACROSS independent
   units (different utilities, unrelated areas) to move
   faster — the only prohibition is test-writing and
   code-writing the SAME thing at the same time. If, during
   implementation, the implementer concludes a TEST (not the
   code) is wrong, it must NOT edit the test — it routes the
   change back to the test-writer with instructions. The
   test-writer adjudicates judge-first: it fixes the test
   (keeping it toothful) only if the test is genuinely wrong,
   otherwise it refuses and the implementer fixes the code.
   This keeps the separation intact instead of letting a
   fix-writer dodge a real bug by rewriting the test that
   caught it.
2. **A test must be proven able to fail before its change is
   trusted.** How you prove it depends on the kind of work
   (below). A test that can never fail is a bug in the test;
   fix it.

#### Bug fixes — classic red→green

1. Write the failing test FIRST (separate agent).
2. **Verify RED** — run it and SEE it fail for the RIGHT
   reason (the assertion matching the bug, not a compile
   error or a skip). Validate on macOS AND Linux (via
   `orb -m ubuntu`); push to CI and confirm failure.
3. ONLY THEN write the fix (separate agent), minimal change.
4. **Verify GREEN** — same platforms, same CI.

#### New features — define behavior, then build

1. Write tests that define the expected behavior.
2. Verify they fail (RED) for the right reason.
3. Implement until they pass (GREEN).
4. Refactor if needed (stay GREEN).

#### Refactors — behavior-preserving (e.g. the walker migration)

A refactor changes structure, not behavior, so its tests
*should not* fail on the real code — demanding a red here is
theater. Instead, **prove the tests have teeth by transient
sabotage** (manual mutation testing):

1. Write/identify characterization tests for the behavior
   being preserved.
2. Confirm they pass on the REAL, unchanged code (GREEN).
3. **Prove red-ability:** temporarily mutate the
   implementation to break the asserted behavior, run the
   tests, confirm they go RED — then REVERT the mutation
   (never commit it) and confirm GREEN again. A test that
   stays green under sabotage is worthless; fix it.
4. Perform the refactor; all tests stay GREEN throughout.

#### Always

- Integration tests must actually RUN in CI — verify the
  runner picks them up (binary-name matching, bash version
  requirements, etc.).
- Validate on both macOS and Linux before pushing. Use
  `orb -m ubuntu` for Linux validation.

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
- **`takeDelimiterInclusive` returns `error.StreamTooLong`**,
  not `EndOfStream`, when a line exceeds the 8KB buffer.
  Handle both or long lines crash the utility (3847931).
- **Integration tests must keep PATH pinned to
  `zig-out/bin`** (tests/integration.sh does this). A test
  that resolves the system binary passes for the wrong
  implementation (fa8be65).

## macOS Failure Classes

These account for most fix commits in this repo's history.
Check each one whenever you touch syscalls, libc, or
integration tests:

- **Signed stat fields**: macOS `st_dev` on devfs is a
  signed i32 with the high bit set. `@intCast` to u64
  traps; use `@bitCast` (6b97443, `ls /` panic).
- **Static libc buffers**: `getpwuid`/`getgrgid` return
  pointers into a buffer the next re-entrant libc call
  reuses. Copy strings out before calling anything else,
  and cap retry loops around `getgrouplist` (8d75aad,
  a 29-minute CI hang).
- **BSD vs GNU tools**: macOS ships BSD `dd`, `du`, etc.
  without GNU flags, and CI runners have no GNU
  `timeout(1)` — use the `run_with_limit` helper in
  `tests/lib/common.sh`, never `timeout N cmd` (618be2c).
- **isatty guards**: every interactive prompt needs its
  own `isatty` check, not just the first prompt on the
  code path (c03e2c0, `mv -i` hang).

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

Use `writerStreaming`, never `writer`, for stdout/stderr —
see "Common Pitfalls" above for why, and note the lint in
`src/common/lib.zig` fails the build on violations.

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

This project follows [Tiger Style][upstream]. The full
rules live in the tiger-style plugin: run
`/tiger-style:tiger-patterns` before writing Zig, and
`/tiger-style:tiger-check` after changes to scan for
mechanical violations (oversized functions, long lines,
`usize`, recursion, compound asserts, unbounded
`while (true)`).

Rules agents most often break here:

- Minimum two assertions per function; assert positive
  AND negative space; split compound assertions.
- No recursion; every loop has an explicit upper bound.
- Hard limits: 70 lines per function, 100 columns per
  line. `zig fmt`, 4-space indent.
- Explicitly-sized types (`u32`) over `usize`; show
  division intent with `@divExact`/`@divFloor`.
- snake_case names, units as suffixes by descending
  significance (`latency_ms_max`).
- Comments are full sentences that say why, not what.

Project deltas from upstream Tiger Style: CLI utilities
use a per-invocation arena allocator (see Memory
Management) rather than strictly static allocation, and
tests are embedded in implementation files.

[upstream]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

