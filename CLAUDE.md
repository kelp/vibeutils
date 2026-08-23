# CLAUDE.md

A Zig implementation of GNU coreutils with modern
enhancements. Follows OpenBSD engineering principles —
correctness, simplicity, security — while adding modern
UX (colors, icons, progress bars).

Utilities live one-per-file in `src/<utility>.zig` with
their tests embedded. Shared code is in `src/common/`;
man pages in `man/man1/`. A new utility is registered in
the `utilities` array in `build/utils.zig` — that array
is metadata-driven and `build.zig` reads it, so don't
edit `build.zig` itself.

`just` lists every command. If `zig` is missing, run
`scripts/bootstrap.sh`; in remote/web sessions it is
already running in the background and re-running it
blocks until it finishes. Details, the optional-tool
matrix, and container caveats:
[`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md).

## Pre-1.0 Development Philosophy

**Zero external users. Getting the design right beats
backward compatibility.**

- Never maintain backwards compatibility: no deprecated
  code, no compatibility layers, no preserved
  intermediate iterations. Delete old code when
  replacing it.
- If the current API is wrong, change it completely.
- Full migrations only: when changing a pattern, update
  all code to the new pattern in the same change.

## Your Zig Training Is Out of Date

This project targets **Zig 0.16.0**, pinned by
`minimum_zig_version` in `build.zig.zon` and by
`flake.nix`. 0.16 landed Writergate-scale breaking
changes on top of the 0.15.x ones you may have absorbed;
the 0.15 → 0.16 migration here is complete.

Load the **`zig-patterns` skill** before writing Zig —
it has the correct 0.16 shapes for I/O, entry points,
filesystem, ArrayList, args, environment, and testing.
When an error message doesn't match, grep it in
[`docs/ZIG_BREAKING_CHANGES.md`](docs/ZIG_BREAKING_CHANGES.md),
the full migration catalog. Prefer both over anything
you remember.

## Spec Reference Hierarchy

**GNU coreutils is the primary behavioral reference.**
Where a flag exists in GNU, match GNU semantics. For
flags that exist only in macOS/OpenBSD, follow that
spec. For `stat` we follow the GNU interface — BSD and
GNU `stat` have incompatible semantics for `-f`, `-t`,
and others.

The per-utility flag matrices in
`docs/specs/<util>-flags.md` are authoritative for which
flags are implemented and at what priority. Check the
matrix before implementing or auditing a flag; it
resolves which spec to follow.

- **MUST** — present across multiple specs (POSIX plus
  at least one other). Implement.
- **SHOULD** — useful flags from a single spec.
  Implement when practical.
- **WONT** — explicitly declined. Do not implement.
- **KEEP** — vibeutils-specific additions (`--git`,
  `--icons`). Not in any upstream spec.

Don't invent custom behavior, emit warnings for
unimplemented features, or silently degrade. Either
implement the full behavior or don't add the flag.

## Testing

Target 90%+ coverage (`just coverage`).

Before writing a fix, a feature, or a behavior-
preserving refactor, load the **`tdd` skill**. It covers
the two enforced rules — tests and implementation come
from separate agents, and a test must be proven able to
fail — and how to prove red-ability for each kind of
work. Patterns, fixtures, and the privileged-test
architecture:
[`docs/TESTING_STRATEGY.md`](docs/TESTING_STRATEGY.md).

## Releases

Two commands, two gates. Always use the `just` recipes;
never hand-edit `build.zig.zon` and tag.

```
just release x.y.z       # Gate 1 (local): both suites, both
                         # platforms, then push main
# ... wait for CI, get explicit confirmation ...
just release-tag x.y.z   # Gate 2 (CI): wait for green, push tag
```

`scripts/release.sh` and `scripts/release-tag.sh` are
the authority on the exact gate sequence. Read them
before changing the flow; don't reimplement their checks
by hand.

**Never push a release tag without specific, explicit
confirmation.** The tag push is irreversible — it
triggers publish, and [immutable releases][imm] lock the
tag and assets at that moment. Pushing the version-bump
commit to `main` is safe; pushing the *tag* requires the
human to confirm, after CI is green on both
`macos-latest` and `ubuntu-latest`, that this specific
release should go out. Running `just release-tag` **is**
that confirmation — do not run it on the human's behalf,
and do not infer confirmation from an earlier "cut a
release" instruction.

`CHANGELOG.md` is the source of truth for release notes;
the GitHub release body is extracted from it. Add
bullets under `## Unreleased` as you land user-visible
changes. Never write a `## vX.Y.Z` heading by hand — the
release script promotes it.

[imm]: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases

## Commit Signing

All commits must be signed; the repo enforces verified
signatures on all branches. Never use
`-c commit.gpgsign=false` or otherwise work around
verification.

If signing fails, where you are determines what to do.
On the **dev machine** the SSH signing key is managed by
1Password and needs a live agent connection from the
host; if the agent drops (laptop sleep, SSH reconnect)
signing fails until the session is refreshed — stop and
wait for instructions. In an **agent container** signing
is pre-configured by the environment and works, so a
failure there is a real problem to surface, not
something to sit out.

`.githooks/pre-commit` blocks any commit unless
`zig fmt` is clean; run `just install-hooks` once per
clone. It does not run tests.

## macOS Failure Classes

These account for most fix commits in this repo's
history. Check each whenever you touch syscalls, libc,
or integration tests.

- **Signed stat fields**: macOS `st_dev` on devfs is a
  signed i32 with the high bit set. `@intCast` to u64
  traps; use `@bitCast` (6b97443, `ls /` panic).
- **Static libc buffers**: `getpwuid`/`getgrgid` return
  pointers into a buffer the next re-entrant libc call
  reuses. Copy strings out before calling anything else,
  and cap retry loops around `getgrouplist` (8d75aad, a
  29-minute CI hang).
- **BSD vs GNU tools**: macOS ships BSD `dd`, `du`, etc.
  without GNU flags, and CI runners have no GNU
  `timeout(1)` — use the `run_with_limit` helper in
  `tests/lib/common.sh`, never `timeout N cmd`
  (618be2c).
- **isatty guards**: every interactive prompt needs its
  own `isatty` check, not just the first prompt on the
  code path (c03e2c0, `mv -i` hang).

## Gotchas

- **Filter utilities hang in unit tests.** Anything
  reading stdin (`tee`, `cat`, `sort`, `uniq`, …) blocks
  forever. Use the `runUtilWithInput()` pattern or skip
  the unit test, keep 8192-byte buffers, and return
  `ExitCode.general_error` for arg errors — a few
  utilities use 2 or 125 instead, listed in the
  `ExitCode` doc comment in `src/common/lib.zig`. Full
  checklist: `docs/TESTING_STRATEGY.md`, "Filter
  Utilities and Stdin-Dependent Testing".
- **Privileged tests must use
  `privilege_test.TestArena`, never
  `testing.allocator`** — the latter hangs under
  fakeroot. Name them with a `"privileged: "` prefix and
  run them via `just test-privileged`.
- **Running as root breaks permission tests.** Root
  bypasses DAC, so a test asserting "this is denied"
  cannot pass. `just it` drops to an unprivileged user
  via `scripts/run-integration.sh`; unit tests guard
  with `if (std.c.geteuid() == 0) return
  error.SkipZigTest;` (see `src/common/walker.zig`,
  `src/common/file_ops.zig`). Use that guard for any new
  permission-dependent unit test.
- **`takeDelimiterInclusive` returns
  `error.StreamTooLong`**, not `EndOfStream`, when a
  line exceeds the 8KB buffer. Handle both or long lines
  crash the utility (3847931).
- **Color must be gated on `isTty()`**, not just
  `ColorMode.detect()` — detect only reads env vars
  (`TERM`, `NO_COLOR`), so without an isatty check ANSI
  codes leak into pipes, files, and test buffers. See
  `src/df.zig` or `src/ls/` for the pattern.
- **Integration tests must keep PATH pinned to
  `zig-out/bin`** (`tests/integration.sh` does this). A
  test that resolves the system binary passes for the
  wrong implementation (fa8be65).
- **I/O buffers must be flushed before they go out of
  scope**, or the output is lost.
- Cross-platform runs: OrbStack (`orb -m ubuntu zig
  build test`) on the macOS dev machine, `just
  test-linux` for Docker. Agent containers have neither
  and are already on Linux — run the suites natively and
  let CI cover macOS. Don't try to make `orb` work.
- Fuzzing is Linux-only: `just fuzz <name>`.

## Security Philosophy: Trust the OS

System utilities implement functionality; the kernel
enforces security. Don't add path validation, maintain
"protected" lists, or block `../` paths — let the OS
handle permissions and report its errors.

```zig
// ❌ WRONG: security theater
if (std.mem.find(u8, path, "../") != null) return error.PathTraversal;

// ✅ RIGHT: trust the OS
try std.Io.Dir.cwd().deleteFile(io, path);
```

Validate only for **correctness**: same-file detection
(data loss), buffer overflow, atomicity guarantees.

## Tiger Style

This project follows [Tiger Style][upstream]. The full
rules live in the tiger-style plugin: run
`/tiger-style:tiger-patterns` before writing Zig, and
`/tiger-style:tiger-check` after changes to scan for
mechanical violations.

Rules agents most often break here:

- Minimum two assertions per function; assert positive
  and negative space; split compound assertions.
- No recursion; every loop has an explicit upper bound.
- Hard limits: 70 lines per function, 100 columns per
  line. `zig fmt`, 4-space indent.
- Explicitly-sized types (`u32`) over `usize`; show
  division intent with `@divExact`/`@divFloor`.
- snake_case names, units as suffixes by descending
  significance (`latency_ms_max`).
- Comments are full sentences that say why, not what.

Project deltas from upstream: CLI utilities use a
per-invocation arena allocator rather than strictly
static allocation, and tests are embedded in
implementation files.

[upstream]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

## Where to Look

- Landing one `TODO.md` heading → the
  `next-todo@agent-plugins` skill. One heading is one
  pull request.
- Implementing a new utility → the `new-util` skill
  (classification, TDD phases, template).
- Writing Zig → the `zig-patterns` skill;
  `docs/ZIG_BREAKING_CHANGES.md` for error messages.
- Writing tests → the `tdd` skill;
  `docs/TESTING_STRATEGY.md` for patterns;
  `docs/INTEGRATION_TESTING.md` for the shell suites.
- Writing a man page → `docs/MAN_PAGE_REFERENCES.md`
  (spec URLs plus our house style).
- Design rationale → `docs/DESIGN_PHILOSOPHY.md`.
- Zig language reference → `docs/zig-0.16.0-docs.md`,
  `docs/zig-0.16.0-release-notes.md`. Grep them rather
  than reading straight through.

## Next TODO binding

The `next-todo@agent-plugins` plugin reads these values. Where this
section conflicts with the rest of this file, follow the
rest of this file.

1. **Backlog** — `TODO.md` from the start of the current
   milestone. Take the first unchecked **PR slice** in
   listed order. One heading is one pull request. Nested
   checkboxes under that heading belong to the slice.
2. **Plan** — `docs/plans/YYYY-MM-DD-<slice-slug>.md`.
3. **Spec** — `docs/specs/<util>-flags.md`. User approval
   before Zig against a new spec or design note.
4. **Gates** — `just fmt-check` before each commit, and
   `just test` when Zig files changed. For a utility
   behavior change, also `just it-util <name>` (with
   `env -u NO_COLOR` when color is involved).
5. **CI** — **Test**, **Integration Tests**,
   **Changelog**, **Audit Pre-Pass**, **Tiger Style**,
   and required bot reviews on the PR.
6. **Review axes** — plugin defaults (Grok, Sol, Opus 5).
7. **Rules** — this file and `AGENTS.md`. Load
   `zig-patterns` and `tdd` before writing a fix or
   feature. Run `/tiger-style:tiger-patterns` before
   Zig, and `/tiger-style:tiger-check` after.
