# Slice: Progress Feedback for `cp`/`mv`/`dd`

## Slice name

`### 6. Progress Feedback for cp/mv/dd`

Boxes:

- Progress module in `src/common/`
- Show status line on stderr after 2s delay
- Update in place, clear when done
- Only when stderr is a TTY

The TTY box applies to KEEP auto-progress (`cp`/`mv`).
`dd status=progress` is a GNU SHOULD flag and is **not**
TTY-gated (GNU writes into pipes and logs). Check the
box; the man page and this plan record the GNU
exemption. Do not rewrite the box into a new heading.

One heading, one PR. Do not pull Smarter Error Messages
(`### 7`, PR #191), `tree` (`### 5`, PR #190), leftover
`du` color (`### 4`, PR #199), Shared Components
(`## Architecture Decisions`, PR #184), or Success
Criteria.

## Predecessor gate (recorded deviation)

This environment cannot merge. The campaign objective
is to land every remaining `TODO.md` heading, and
predecessors `#182`–`#199` are open drafts waiting on
the user. Waiting would stall the campaign.

`src/dd.zig` is already heavily edited on PR #177
(`cursor/fix-159-end-of-options-16f1`, `35bd4df`,
+427). Stack **on that branch**, not on `github/main`
(`a41eccd`), so the progress patch does not fight the
`--` delimiter work.

`TODO.md` / `CHANGELOG.md` will still conflict with
other stacked slices. GitHub base for this PR is
`cursor/fix-159-end-of-options-16f1` (merge **after**
#177). Full Test/Integration CI may not run until the
base is `main`; retarget after #177 lands.

`#184` added `parallel.zig` and said **do not wire it
into cp/cat/dd/sort**. This slice is a different
module. Do not import or call `parallel.zig`.

## Plan revision (r2)

Three-model plan review of r1: Grok, Sol, and Fable
all **REQUEST CHANGES**. This revision resolves every
blocking item.

| Item | Decision |
|---|---|
| Tracker writer | Field `writer: *std.Io.Writer`. `update`/`finish` write **only** to that writer (the utility's `stderr_writer` / `ctx.stderr`), never `File.stderr()`. AGENTS.md writer-based I/O. |
| Feature 5 "unify the style" | Infrastructure only (shared Tracker, CR, interval helper). `dd` keeps GNU line / delay / TTY rules because CLAUDE.md GNU-flag semantics outrank the design sentence. |
| GNU `dd` delay | `.gnu_xfer` delay **1s**, interval **1s** (GNU SIGALRM cadence). Not delay 0. Tests never sleep: they pass `now_ns` or set the test overlay (below). A fast shell `dd` of a tiny file will **not** show `\r`; that matches GNU. |
| Double final line | After a live line, GNU prints the transfer line with newline, then records in/out, then the transfer line again. `finish` + existing `printStats` is that shape. Fast copies that never crossed the 1s delay emit only `printStats` (GNU). |
| cp/mv wiring tests | Positive-emission tests through **every** production copy path, via `runCp`/`runMv` plus the test overlay. Negative TTY-off / same-fs rename tests are guards, not the tooth. |
| `tracker` param ownership | Test-writer adds `copyFileContentsWithProgress` (stub ignores the tracker so the "update was called" test is RED on an assertion). Existing `copyFileContents` signature stays; it calls the new function with `null`. |
| Error vs clear | `finish` **before** any diagnostic. A `defer finish` after a `catch` print would `\r`-wipe the error line. `copyFileContentsWithProgress` finishes on every return. Finish is idempotent. Test: failed copy leaves the error text intact. |
| Observable bytes | `Tracker.bytes_done: u64` last value passed to `update`. |
| `total` | `?u64`. `null` = unknown (omit `/total` and percent). `Some(0)` also omits percent. Test both. |
| Force-import | Alphabetically between `privilege_test.zig` and `prompt.zig`. |
| 70-line sites | Do not grow `copyFileWithAttributes` (already ~79). Extract tracker construction so `copyRegularFile` and `runDd_copyLoop` stay ≤70. |
| Stacking | Campaign authorization recorded above. Not a code blocker. |

## Plan revision (r3)

r2: Fable **APPROVE**. Grok and Sol **REQUEST
CHANGES** on leftover test/lifecycle holes. This
revision is those holes only.

| Item | Decision |
|---|---|
| `copyTreeFile` tooth | Overlay test through `crossFilesystemMove` on a **directory** with a regular file (`src/a.txt` larger than `COPY_BUFFER_SIZE`). Captured stderr has `\r` and `copying`. The single-file EXDEV test does not cover this caller. |
| finish-before-diag tooth | Require `delay_ns = 0`, at least one successful `update` (`shown == true`), **then** a later write error. A dest that fails on the first write never shows, so `finish` is a no-op and cannot catch a wipe. |
| dd diagnostics vs live line | `runDd_writeError` and the `conv=noerror` diagnostic path call `tracker.finish(now)` **before** `printErrorWithProgram`. Recoverable noerror may `update` again afterward (delay already elapsed, so the next update may emit on the following line). Test `runDd_writeError` with a shown `.gnu_xfer` tracker: the write-error text is present and not spaces. Parse-time errors (before the copy loop) need no finish. |

## Classification

KEEP auto-progress for `cp`/`mv` (no flag in
`docs/specs/cp-flags.md` / `mv-flags.md`; do **not**
add GNU `cp --progress` / `-g`). Implement Feature 5
in `docs/plans/2026-03-01-modern-features-design.md`.

`dd status=progress` is already SHOULD in
`docs/specs/dd-flags.md` and is parsed, but it only
prints the same end-of-run `printStats` newline as
default — there is no live `\r` line today. This slice
gives that flag a live updater via the shared module
without changing GNU flag semantics.

## In scope

1. **`src/common/progress.zig`** — `Tracker`:

   ```
   writer: *std.Io.Writer
   program: []const u8
   label: []const u8
   total: ?u64
   delay_ns: i128
   interval_ns: i128
   start_ns: i128
   last_emit_ns: i128
   bytes_done: u64
   shown: bool
   last_width: u32
   enabled: bool
   kind: Kind  // .copy_line or .gnu_xfer, not "Style"
   ```

   `update(self, now_ns, copied)` / `finish(self, now_ns)`
   take `now_ns` from the caller. Production copy loops
   call `self.now(io)`:

   ```
   fn now(self: *const Tracker, io: std.Io) i128
   ```

   which returns `test_now_ns` when `builtin.is_test`
   and that overlay is set, else
   `std.Io.Timestamp.now(io, .real).nanoseconds`.
   Tests never sleep. No process-global clock in
   production. The test overlay is the `env.test_overrides`
   pattern (issue #95: never libc unsetenv):

   ```
   // builtin.is_test only
   pub var test_enabled: ?bool = null;
   pub var test_delay_ns: ?i128 = null;
   pub var test_now_ns: ?i128 = null;
   ```

   Production `cp`/`mv` enabled =
   `test_enabled orelse env.isTty(File.stderr().handle)`.
   Production `cp`/`mv` delay =
   `test_delay_ns orelse 2_000_000_000`.
   `dd` `.gnu_xfer` delay =
   `test_delay_ns orelse 1_000_000_000`.
   Tests restore overlays to `null` in `defer`.

   Two kinds:

   - `.copy_line` (`cp`/`mv` KEEP): after `delay_ns`
     (2s default) on an **enabled** tracker, emit
     `\r` +
     `{program}: copying {label}  {done}/{total}  {pct}%`
     and refresh at `interval_ns` (500_000_000).
     Human sizes use `format.formatHumanReadable` with
     `si = true`, `suffix = .iec` so the design mock
     `248MB/1.2GB` is reachable. Percent is
     `@divFloor(@as(u128, done) * 100, @as(u128, total))`
     capped at 100; unknown/`0` total omits `/{total}`
     and the percent. `finish` if shown: `\r` + spaces
     to `last_width` + `\r` (clear; no leftover
     characters, no newline). If never shown, finish
     is a no-op.
   - `.gnu_xfer` (`dd status=progress`): delay 1s,
     interval 1s, **enabled even when stderr is not a
     TTY**. Line shape matches today's `printStats`
     transfer line / GNU: `N bytes (SI, IEC) copied,
     T s, RATE` with `\r` and no trailing newline
     while live. Reuse `formatByteCount` / the
     `printStats` transfer formatter so the two copies
     cannot drift (move that formatter to a shared
     fn `dd` and `progress` both call, **or** keep
     formatting in `dd.zig` and have `.gnu_xfer`
     call a `*const fn` the tracker stores — do not
     duplicate the string). `finish` if shown: last
     line with `\n`. If never shown, no extra line
     (`printStats` still prints the final stats).
     Do not replace final `printStats`.

   `enabled == false`: `update`/`finish` write
   nothing. Write errors are swallowed (progress must
   not fail the copy), matching `printStats`. Flush
   the writer after every progress write so a
   buffered stderr still shows. Label is the source
   basename; replace `\r`/`\n`/`\t` in the label with
   `?` so a hostile name cannot break the status
   line. Cap the formatted line at a 256-byte stack
   buffer (truncate the label, never the counters).
   No heap allocation in the module.

2. **Copy hook.** Keep `copyFileContents(io, src, dest)`
   as today's signature. Add
   `copyFileContentsWithProgress(io, src, dest,
   tracker: ?*Tracker) !void`. The copy loop, after
   each successful write, calls
   `tracker.update(tracker.now(io), copied)` when
   non-null, stores `bytes_done`, and calls
   `finish` on **every** return (success and error)
   before the caller prints a diagnostic. Existing
   `copyFileContents` is
   `return copyFileContentsWithProgress(..., null)`.
   `copyFileWithAttributes` must not grow: extract
   the content-copy line to call
   `copyFileContentsWithProgress` with a new last
   `tracker: ?*Tracker` parameter, or pass the
   tracker through a tiny helper so the 79-line
   function does not gain logic. Existing
   `copyFileWithAttributes` tests keep compiling
   (add `null` only if the signature changes; prefer
   a wrapper `copyFileWithAttributesTracked` if
   adding a param would force a 70-line regression).

3. **`cp`**: file-to-file regular-file copies on
   **all three** paths that copy bytes:
   `copyRegularFile_simpleCopy` (`copyFileContents`),
   `copyInPlace` (`copyFileContents`), and the `-p`
   `copyFileWithAttributes` path. Not directories,
   not symlinks. One tracker per file. `enabled` as
   above, checked at the start of **each** file
   (macOS isatty class). Kind `.copy_line`. Total is
   `source_info.size`. Extract
   `fn makeCopyTracker(writer, program, path, total,
   now_ns) Tracker` so `copyRegularFile` stays ≤70.

4. **`mv`**: same tracker on **both** EXDEV
   `copyFileWithAttributes` paths (single-file around
   `mv.zig:592` and `copyTreeFile` around `885`).
   Same-filesystem `rename` stays silent. Directory
   trees: per regular file, not one bar for the whole
   tree. Same TTY gate and 2s delay.

5. **`dd`**: when `status == .progress`, construct a
   `.gnu_xfer` tracker (`enabled = true`, delay 1s)
   and `update` it from the copy loop whenever
   `bytes_copied` advances. Total is known when
   `count=` is set: blocks use
   `std.math.mul(u64, count, ibs)` (checked; on
   overflow treat total as unknown, do not panic);
   byte mode uses `count`. Otherwise unknown. Do not
   auto-progress default/`none`/`noxfer`.
   SIGUSR1/SIGINFO reprint is out of scope. Extract
   the update call so `runDd_copyLoop` stays ≤70.
   Copy-loop diagnostics (`runDd_writeError`,
   `conv=noerror` read-error messages) call
   `finish` on the tracker before printing so a live
   `\r` line cannot glue to or wipe the diagnostic.
   After a recoverable noerror, later `update`s may
   emit again.

6. Check the four `TODO.md` boxes. CHANGELOG
   Unreleased: cp/mv TTY auto-progress after 2s; dd
   `status=progress` live GNU line after 1s. Man
   pages: cp/mv DESCRIPTION note; dd
   `status=progress` currently says it prints default
   stats — describe the live line and that it is not
   TTY-gated. Note the 1s cadence vs GNU's ~1s
   SIGALRM (match) and vs Feature 5's 0.5s (dd is
   GNU, not Feature 5 interval).

## Out of scope

- GNU `cp --progress` / `-g` / `mv --progress` (not
  in the flag matrices; spec-first needs user
  approval).
- Wiring `parallel.zig` into cp/cat/dd/sort.
- Auto-progress for default `dd` (no `status=`).
- SIGUSR1/SIGINFO, ETA, progress bars, color.
- Recursive directory aggregate progress.
- `files=` / `sparse` / `par*` (not this heading).
- Smarter errors, tree, du color, Success Criteria.
- PTY-only shell tests for cp/mv (they skip in CI).

## Spec impact

No flag-matrix edit. `status=progress` stays SHOULD.
cp/mv auto-progress is KEEP (design Feature 5), not a
new flag. Man pages document behavior that already
had a `status=progress` row.

## Tests

TDD. Test-writer and implementer are separate
agents. Implementer does not edit the guarding
tests.

Tooth (today vs Feature 5 / GNU progress):

- A no-op `update` never emits. After `now_ns =
  start + 2s + 1` with `.copy_line` and
  `enabled = true`, stderr must contain `\r` and
  `copying`. That is RED on a stub.
- `dd status=progress` with overlay `test_delay_ns
  = 0` (or `test_now_ns` past 1s) of several blocks
  must contain `\r` on the **captured** stderr
  writer. Today `printStats` only writes `\n` at the
  end, so this is RED.

Never `sleep` for the delay. Never `unsetenv`. `dd`
is a stdin filter: tests must use `if=` or
`runUtilWithInput`.

1. `src/common/progress.zig` (stub + tests from
   test-writer; implementer fills bodies):
   - `.copy_line`, enabled, before delay: empty
     stderr (positive: still empty after an update;
     negative: no `\r`).
   - After delay: `\r`, program name, `copying`,
     label, human done/total, percent. 10 MiB of 20
     MiB is `50%` not `70%`. `total == null` and
     `total == 0` omit percent. `done > total` caps
     at `100%`. u128: a near-`u64`-max `done` with a
     matching total is `100%` (would wrap on `u64`
     `* 100`).
   - Second update inside the 0.5s interval does not
     grow the writer; after interval the line
     changes.
   - `finish` after shown: no leftover label
     characters (spaces cover `last_width`); no
     extra newline. `finish` when never shown: still
     empty.
   - `enabled = false`: nothing, even after delay.
   - Label with `\r`/`\n` does not inject a newline
     into stderr.
   - `.gnu_xfer`, before 1s: empty; after 1s: `\r`
     and `bytes` / `copied`; `finish` ends with
     `\n`.
   - Writes go to `Tracker.writer`, not a raw fd.
   - At least two asserts per test (positive and
     negative).

2. `src/common/file_ops.zig`:
   `copyFileContentsWithProgress` with a tracker
   (`delay_ns = 0`, enabled) and a 3-block source:
   `tracker.bytes_done` equals the file size, and
   the writer contains `\r`. `copyFileContents`
   (null tracker) still copies and writes nothing
   to a dummy tracker-less stderr.    A copy that
   fails **after** at least one successful `update`
   (`delay_ns = 0` so `shown == true`, then a later
   write error — not a dest that fails on the first
   write) calls `finish` **before** the caller
   prints; the error text on the same writer is not
   wiped to spaces.

3. `src/cp.zig` — positive emission through
   `runCp`, using the test overlay (not a PTY):
   `progress.test_enabled = true`,
   `progress.test_delay_ns = 0`, restore in
   `defer`. Source larger than one `COPY_BUFFER_SIZE`
   (64KiB) so the loop updates at least once.
   Assert captured stderr contains `\r` and
   `copying` for:
   - plain `cp src dst` (`copyRegularFile_simpleCopy`)
   - `cp -p src dst` (`copyFileWithAttributes`)
   - `cp src existing` (`copyInPlace`)
   Overlay `test_enabled = false`: same plain copy,
   stderr has no `\r`. The live `isatty` hop is the
   overlay's production fallback; no PTY test.

4. `src/mv.zig` — positive emission on **both**
   EXDEV callers, same overlay, assert `\r` +
   `copying`:
   - single-file `crossFilesystemMove` (issue #81
     helper; no real EXDEV)
   - directory `crossFilesystemMove` of a tree with
     a regular file larger than `COPY_BUFFER_SIZE`
     (`copyTreeFile`)
   Same-filesystem rename: overlay enabled, stderr
   has no `\r`.

5. `src/dd.zig`: overlay `test_delay_ns = 0`,
   `status=progress`, `if=` a small file, `bs=`
   smaller than the file, writes `\r` to the
   **captured** `stderr_writer`. `status=none` has
   no transfer line and no `\r`. `status=noxfer`
   has records in/out and no `\r`. Default status
   still has the final newline stats and no `\r`.
   Without the overlay, a sub-second copy with
   `status=progress` has **no** `\r` (GNU 1s delay)
   and still has final `printStats`.
   `runDd_writeError` with a shown `.gnu_xfer`
   tracker: captured stderr contains the
   `write error:` diagnostic and that text is not
   replaced by spaces.

6. `tests/utilities/dd_test.sh`: `status=progress`
   still prints records in/out (final stats).
   `status=none` prints nothing. Do **not** assert
   `\r` in the shell suite (tiny files finish under
   1s; a PTY/slow-source test would skip or flake
   in CI). The live `\r` tooth is the unit test in
   (5).

RED: run the after-delay copy_line test, the
file_ops `bytes_done` / `\r` test, the `runCp`
plain-copy overlay test, and the dd overlay `\r`
test. They must fail on missing `\r` / zero
`bytes_done`, not on compile errors. Test-writer
may add `progress.zig` as a **no-op stub**
(`update`/`finish` write nothing, `bytes_done`
unstaged) plus `pub const progress`, the
force-import, `copyFileContentsWithProgress` as
`copyFileContents` ignoring the tracker, and the
test overlay variables so tests compile.
Implementer replaces stub bodies and wires
`runCp`/`runMv`/`runDd`. Implementer does not
edit the guarding test blocks.

After GREEN, prove the green-on-stub negatives
(before-delay empty, `enabled=false`) by
transient sabotage of the real bodies (emit
always / ignore `enabled`); revert; do not
commit the sabotage.

## TDD ownership

- Test-writer: tests above; no-op stub only;
  `copyFileContentsWithProgress` that ignores the
  tracker; force-import + `pub const`; overlay
  vars. No real delay/interval/format/clear. No
  cp/mv/dd copy-loop wiring (do not construct a
  Tracker inside `runCp`/`runMv`/`runDd`).
- Implementer: Tracker bodies, honor the tracker
  in `copyFileContentsWithProgress`, construct
  trackers in cp/mv/dd, TODO boxes, CHANGELOG,
  man pages. Do not alter the guarding tests.
  Split any function that would exceed 70 lines.

## Risks

- `dd` reads stdin: unit tests must not hang
  (TESTING_STRATEGY filter utilities). Use `if=` /
  `runUtilWithInput`.
- isatty: production gate on
  `env.isTty(File.stderr().handle)`, per file, not
  once per `cp` invocation. Tests use
  `progress.test_enabled`, never libc unsetenv.
- `finish` before diagnostics or `\r` wipes the
  error line.
- I/O buffers must flush after each progress write
  or the line is invisible until process exit.
- Tiger: no recursion; `update`/`finish`/`format`
  split so no new function exceeds 70 lines;
  256-byte line cap is the loop bound;
  `copyFileContents` already has
  `tiger:allow:unbounded-loop` for EOF. Do not grow
  `copyFileWithAttributes`. Extract
  `makeCopyTracker`.
- `src/common/` boundary: `progress.zig` must not
  import `file_ops.zig`. Force-import between
  `privilege_test.zig` and `prompt.zig`.
- macOS signed-stat: total bytes from `FileInfo.size`
  (`u64`); no `@intCast` of `st_dev`.
- Privileged tests: none.
- Color/`NO_COLOR`: progress is not colored.
- Overlay vars are process-global under
  `builtin.is_test`. Restore in `defer`. Zig unit
  tests in one binary are sequential; do not leave
  overlays set.
- Stacked `TODO.md`/`CHANGELOG.md` will conflict
  with other open slices; expected.

## Files

| File | Who | What |
|---|---|---|
| `docs/plans/2026-08-22-progress-feedback.md` | planner | this plan |
| `src/common/progress.zig` | test-writer stub+tests; implementer bodies | Tracker |
| `src/common/lib.zig` | test-writer `pub const` + force-import | reach tests |
| `src/common/file_ops.zig` | test-writer tests+stub wrapper; implementer honor tracker | copy hook |
| `src/cp.zig` | test-writer overlay tests; implementer wire all 3 paths | TTY 2s |
| `src/mv.zig` | test-writer overlay tests; implementer wire both EXDEV paths | EXDEV 2s |
| `src/dd.zig` | test-writer overlay tests; implementer wire | live GNU 1s |
| `tests/utilities/dd_test.sh` | test-writer | final stats only, no `\r` |
| `man/man1/cp.1` `mv.1` `dd.1` | implementer | document |
| `TODO.md` | implementer | check four boxes |
| `CHANGELOG.md` | implementer | Unreleased |

## Stop condition

- cp/mv: TTY (or `test_enabled`), per regular file,
  after 2s, `.copy_line`, clear on finish; pipes
  stay silent; all three cp paths and both mv copy
  paths emit under the overlay
- dd `status=progress`: live GNU `\r` line after 1s,
  no TTY gate, final `printStats` unchanged; fast
  copies have no live line
- No new flags, no `parallel.zig`, no PTY-only tests
- Four `### 6` boxes checked
