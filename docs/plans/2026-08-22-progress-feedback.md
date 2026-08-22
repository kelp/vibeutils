# Slice: Progress Feedback for `cp`/`mv`/`dd`

## Slice name

`### 6. Progress Feedback for cp/mv/dd`

Boxes:

- Progress module in `src/common/`
- Show status line on stderr after 2s delay
- Update in place, clear when done
- Only when stderr is a TTY

One heading, one PR. Do not pull Smarter Error Messages
(`### 7`, PR #191), `tree` (`### 5`, PR #190), leftover
`du` color (`### 4`, PR #199), Shared Components
(`## Architecture Decisions`, PR #184), or Success
Criteria.

## Predecessor gate (recorded deviation)

This environment cannot merge. `src/dd.zig` is already
heavily edited on PR #177 (`cursor/fix-159-end-of-options-16f1`,
`35bd4df`, +427). Stack **on that branch**, not on
`github/main` (`a41eccd`), so the progress patch does not
fight the `--` delimiter work.

`TODO.md` / `CHANGELOG.md` will still conflict with
other stacked slices. GitHub base for this PR is
`cursor/fix-159-end-of-options-16f1` (merge **after**
#177). Full Test/Integration CI may not run until the
base is `main`; retarget after #177 lands.

`#184` added `parallel.zig` and said **do not wire it
into cp/cat/dd/sort**. This slice is a different
module. Do not import or call `parallel.zig`.

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

1. **`src/common/progress.zig`** — a `Tracker` that
   holds program name, label, optional total bytes,
   delay, interval, start time, last-emit time, shown
   flag, last line width, enabled flag, and a `Style`.
   Callers pass `now_ns` into `update` / `finish` so
   tests never sleep. Production copy loops pass
   `std.Io.Timestamp.now(io, .real).nanoseconds`.
   Per-instance `injected_now_ns: ?i128 = null` is
   **not** needed if every call site passes `now_ns`;
   do that. No process-global clock (Zig tests can
   run in parallel).

   Two styles:

   - `.copy_line` (cp/mv KEEP): after `delay_ns`
     (2_000_000_000) on an **enabled** tracker, emit
     `\r` +
     `{program}: copying {label}  {done}/{total}  {pct}%`
     and refresh at `interval_ns` (500_000_000).
     Human sizes use `format.formatHumanReadable` with
     `si = true`, `suffix = .iec` so the design mock
     `248MB/1.2GB` is reachable. Percent is
     `@divFloor(@as(u128, done) * 100, @as(u128, total))`
     capped at 100; `total == 0` or unknown total
     omits `/{total}` and the percent (show done
     bytes only). `finish` if shown: `\r` + spaces to
     `last_width` + `\r` (clear; no leftover
     characters, no newline). If never shown, finish
     is a no-op.
   - `.gnu_xfer` (dd `status=progress`): `delay_ns = 0`
     (first update may emit), same 0.5s interval,
     **enabled even when stderr is not a TTY** (GNU
     prints progress into pipes and logs). Line shape
     matches today's `printStats` transfer line /
     GNU: `N bytes (SI, IEC) copied, T s, RATE`
     with `\r` and no trailing newline while live.
     `finish` writes the last line with `\n` (GNU
     leaves the line; then existing `printStats`
     still prints records in/out). Do not replace
     final `printStats`.

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

2. **`copyFileContents` / `copyFileWithAttributes`**
   gain a last parameter `tracker: ?*progress.Tracker`.
   The copy loop, after each successful write, calls
   `tracker.update(now_ns, copied)` when non-null.
   `finish` is the caller's job (`defer` after the
   copy returns, including error paths). Existing
   tests pass `null`.

3. **`cp`**: file-to-file regular-file copies only
   (the `copyFileContents` / `copyFileWithAttributes`
   paths, including in-place). Not directories, not
   symlinks. One tracker per file, 2s timer starts
   when that file's copy starts. `enabled` is
   `common.env.isTty(std.Io.File.stderr().handle)`
   checked at the start of each file (macOS isatty
   class: do not reuse the first file's answer for
   later files). Style `.copy_line`. Total is the
   source `stat` size.

4. **`mv`**: same tracker on the EXDEV
   `copyFileWithAttributes` paths only (single-file
   and `copyTreeFile`). Same-filesystem `rename` stays
   silent. Directory trees: per regular file, not one
   bar for the whole tree. Same TTY gate and 2s delay.

5. **`dd`**: when `status == .progress`, construct a
   `.gnu_xfer` tracker (`delay_ns = 0`, `enabled =
   true`) and `update` it from the copy loop whenever
   `bytes_copied` advances. Total is known when
   `count=` is set (blocks: `count * ibs`; byte mode:
   `count`); otherwise unknown. Do not auto-progress
   default/`none`/`noxfer`. SIGUSR1/SIGINFO reprint
   is out of scope.

6. Check the four `TODO.md` boxes. CHANGELOG
   Unreleased: cp/mv TTY auto-progress after 2s; dd
   `status=progress` live line. Man pages: cp/mv
   DESCRIPTION note; dd `status=progress` currently
   says it prints default stats — describe the live
   line.

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

## Spec impact

No flag-matrix edit. `status=progress` stays SHOULD.
cp/mv auto-progress is KEEP (design Feature 5), not a
new flag. Man pages document behavior that already
had a `status=progress` row.

## Tests

TDD. Test-writer and implementer are separate
agents. Implementer does not edit the guarding
tests.

Tooth (today vs Feature 5):

- A no-op `update` never emits. After `now_ns =
  start + 2s + 1` with `.copy_line` and
  `enabled = true`, stderr must contain `\r` and
  `copying`. That is RED on a stub.
- `dd status=progress` of several blocks must contain
  `\r` on stderr. Today `printStats` only writes
  `\n` at the end, so this is RED.

Never `sleep` for the 2s delay. Never `unsetenv`
(issue #95); use `common.env.test_overrides` if an
env key is needed. `dd` is a stdin filter: tests
must use `if=` or `runUtilWithInput`, never a hanging
stdin read.

1. `src/common/progress.zig` (stub + tests from
   test-writer; implementer fills bodies):
   - `.copy_line`, enabled, before delay: empty
     stderr (positive: still empty after an update;
     negative: no `\r`).
   - After delay: `\r`, program name, `copying`,
     label, human done/total, percent. 10 MiB of 20
     MiB is `50%` not `70%`. 0 of 0 omits percent.
     `done > total` caps at `100%`. u128: a
     near-`u64`-max `done` with a matching total is
     `100%` (would wrap on `u64` `* 100`).
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
   - `.gnu_xfer`, delay 0: first update emits `\r`
     and `bytes` / `copied`; `finish` ends with
     `\n`.
   - At least two asserts per test (positive and
     negative).

2. `src/common/file_ops.zig`: `copyFileContents`
   with a tracker and a 3-block source calls
   `update` with monotonic `copied` (a test tracker
   records the last byte count; after copy it equals
   the file size). `null` tracker still copies.
   `copyFileWithAttributes(..., null)` keeps today's
   mode/mtime tests green.

3. `src/cp.zig`: constructing a `.copy_line`
   tracker around a regular-file copy is covered via
   file_ops; add a unit test that a TTY-off path
   (tracker `enabled = false`, or a helper that
   skips the tracker) leaves stderr without `\r`.
   Do not assert live TTY progress through `runCp`
   against `File.stderr().isatty` — that fd is the
   test process, not the buffer writer.

4. `src/mv.zig`: EXDEV/`copyFileWithAttributes`
   path accepts a tracker; rename-only path never
   constructs one (no `\r` in stderr on a same-fs
   rename).

5. `src/dd.zig`: `status=progress` with `if=` a
   small file, `bs=` smaller than the file, writes
   `\r` to the captured stderr writer. `status=none`
   has no transfer line and no `\r`. `status=noxfer`
   has records in/out and no `\r`. Default status
   still has the final newline stats and no `\r`.

6. `tests/utilities/dd_test.sh`: `status=progress`
   of a multi-block file; stderr contains a carriage
   return. `status=none` does not. This runs in CI
   without a PTY because GNU progress is not
   TTY-gated. No cp/mv shell test that requires a
   PTY (those would skip in CI).

RED: run the after-delay copy_line test and the dd
`\r` test; they must fail on missing `\r` / empty
progress, not on compile errors. Test-writer may add
`progress.zig` as a **no-op stub** (`update`/`finish`
write nothing) plus `pub const progress` and the
force-import so tests compile. Implementer replaces
stub bodies and wires call sites. Implementer does
not edit the guarding test blocks.

## TDD ownership

- Test-writer: tests above; no-op stub only; force-
  import + `pub const` so the stub is reached. No
  real delay/interval/format/clear. No cp/mv/dd
  copy-loop wiring.
- Implementer: Tracker bodies, copy-loop hooks,
  TTY gate, TODO boxes, CHANGELOG, man pages. Do
  not alter the guarding tests.

## Risks

- `dd` reads stdin: unit tests must not hang
  (TESTING_STRATEGY filter utilities). Use `if=` /
  `runUtilWithInput`.
- isatty: gate on `env.isTty(File.stderr().handle)`,
  per file, not once per `cp` invocation.
- I/O buffers must flush after each progress write
  or the line is invisible until process exit.
- Tiger: no recursion; `update`/`finish`/`format`
  split so no new function exceeds 70 lines; 256-byte
  line cap is the loop bound; `copyFileContents`
  already has `tiger:allow:unbounded-loop` for EOF.
  Do not grow `copyFileContents` past 70 — keep the
  progress call to a one-liner helper.
- `src/common/` boundary: `progress.zig` must not
  import `file_ops.zig` (file_ops imports progress).
  Force-import alphabetically (`path.zig`,
  **`progress.zig`**, `prompt.zig`).
- macOS signed-stat: total bytes from `FileInfo`
  size; use the existing size field (already u64),
  no `@intCast` of `st_dev`.
- Privileged tests: none.
- Color/`NO_COLOR`: progress is not colored.
- Stacked `TODO.md`/`CHANGELOG.md` will conflict
  with other open slices; expected.

## Files

| File | Who | What |
|---|---|---|
| `docs/plans/2026-08-22-progress-feedback.md` | planner | this plan |
| `src/common/progress.zig` | test-writer stub+tests; implementer bodies | Tracker |
| `src/common/lib.zig` | test-writer `pub const` + force-import | reach tests |
| `src/common/file_ops.zig` | test-writer tests; implementer param | copy hook |
| `src/cp.zig` | test-writer tests; implementer wire | TTY 2s |
| `src/mv.zig` | test-writer tests; implementer wire | EXDEV 2s |
| `src/dd.zig` | test-writer tests; implementer wire | live GNU |
| `tests/utilities/dd_test.sh` | test-writer | `\r` on progress |
| `man/man1/cp.1` `mv.1` `dd.1` | implementer | document |
| `TODO.md` | implementer | check four boxes |
| `CHANGELOG.md` | implementer | Unreleased |

## Stop condition

- cp/mv: TTY, per regular file, after 2s, `.copy_line`,
  clear on finish; pipes stay silent
- dd `status=progress`: live GNU `\r` line, no TTY
  gate, final `printStats` unchanged
- No new flags, no `parallel.zig`, no PTY-only tests
- Four `### 6` boxes checked
