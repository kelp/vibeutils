# Slice: `### Shared Components` (remaining common-library boxes)

## Slice name

`### Shared Components` remaining unchecked items under
"Create common library for:":

- Terminal width detection for responsive layouts
- Parallel I/O utilities for performance

One heading, one PR. Do not pull `### Build System` (man-page
install), `### Color Support` (`LS_COLORS`), or later headings.

## Predecessor gate (recorded deviation)

`land-todo-slice` says: stop if a predecessor is still open.
The listed-order predecessors `#### 28. free` (#182) and
`#### 37. tail` (#183) are still open drafts. This branch is
cut from `origin/main` (`a41eccd`). It does not touch those
PRs' files (`src/free.zig`, `src/tail.zig`).

This environment cannot merge. The deviation is intentional so
the slice can be planned and implemented while those PRs wait
on a human merge. Rebase onto `main` after they land if they
land first.

## In scope

### Terminal width

`src/common/terminal.zig` already implements ioctl `TIOCGWINSZ`
plus `COLUMNS` / `LINES`. The leftover work is correctness, not
a new module.

Extract a **pure** resolver so tests never mutate the process
environment (issue #95: never `setenv`/`unsetenv`; `env.getEnv`
already consults `env.test_overrides`, but ioctl runs first on
a TTY, so `getWidth()` + env is not a deterministic RED):

```
resolveDimension(ioctl_value: ?u16, env_text: ?[]const u8, default: u16) u16
```

Rules, in order:

1. If `ioctl_value` is non-null and `> 0`, return it.
2. Otherwise parse `env_text`: missing, empty, non-numeric,
   overflow, or `0` → `default`. A positive parse wins.
3. `std.debug.assert(result > 0)` **after** the fallback, never
   instead of it. A zero ioctl or `COLUMNS=0` must not trap;
   it must fall through. The assert fires only if `default`
   itself is 0 (already guarded by the existing
   `DEFAULT_TERMINAL_* > 0` asserts).

`getTerminalDimension` stays ioctl-first, then
`env.getEnv("COLUMNS"|"LINES")`, then `resolveDimension`.
Windows stays the existing default-constant path.

`ls` / `df` already call `common.terminal.getWidth`. No API
rename. No `src/ls/` layout rewrite.

`COLUMNS=0` falling back to 80 is user-visible for `ls` column
layout. Update `CHANGELOG.md` under Unreleased / Changed.

### Parallel I/O

GNU coreutils has no shared parallel-copy library. This
checkbox is a common helper, not a `cp` behavior change.

**Decision (round-1 2/3):** do **not** wire this into `cp`,
`cat`, `dd`, or `sort`. Grok and Fable treated an unwired
force-imported module as the checkbox; GPT wanted a production
consumer. Wiring `cp` is slice creep into a later heading
("progress-for-cp") and a behavior change GNU does not make
by default. Recorded: no production consumer in this PR.
`sort --parallel` already parses; leaving it sequential is
existing behavior.

Zig 0.16 removed `std.Thread.Pool` and moved mutexes to
`std.Io.Mutex`. Do **not** spawn with `std.Thread.spawn` or
mix `std.Thread.Mutex` with `Io`. Use `std.Io` +
`std.Io.Group`.

Add `src/common/parallel.zig`, force-imported from
`src/common/lib.zig` (alphabetical, between `path.zig` and
`privilege_test.zig`):

- Hard cap `parallel_workers_max: u32 = 8`.
- `runBounded(io, n_workers, ctx, work_fn, n_jobs)`:
  `work_fn(ctx, job_index)` for `job_index` in `0 .. n_jobs`.
- Worker count is `max(1, min(n_workers, parallel_workers_max, n_jobs))`
  when `n_jobs > 0`. `n_workers == 0` means 1. `n_jobs == 0`
  is a no-op (no spawn).
- Spawn at most that many `Group.concurrent` workers. Each
  worker atomically steals the next job index. Spawn/join
  loops bounded by `parallel_workers_max`. No recursion.
- If `Group.concurrent` returns `error.ConcurrencyUnavailable`
  mid-spawn, await already-started workers, then finish
  remaining jobs on the caller. Do not leak tasks.
- First error is the error from the **lowest failing job
  index**. Later failures are discarded. All started workers
  still join.
- Job counters and error slots use `std.atomic` (lock-free;
  no `Io` mutex required). Tests that share a counter across
  workers must use atomics, not unsynchronized `u32`.
- Two asserts per function, ≤70 lines, ≤100 columns.
- Tests use `std.testing.io` (already a threaded `Io`).

Files: `src/common/terminal.zig`, `src/common/parallel.zig`,
`src/common/lib.zig`, `TODO.md`, `CHANGELOG.md`. No
`build.zig`. No man pages. No `src/cp.zig`.

## Out of scope

- `### Build System` man-page install targets
- `### Color Support` `LS_COLORS`
- BSD VM testing, `tree`, progress-for-cp, smarter errors
- Windows console APIs
- Changing `cp`/`mv`/`dd` to copy in parallel
- `sort --parallel` actually spawning workers
- Tiger Style CI job (deferred heading)
- `getWidth()` tests that require a TTY ioctl of 0 (not
  injectable). The pure resolver covers that case.

## Spec impact

No flag-matrix change. No new CLI flags.

## Tests (failing first, separate test-writer)

Names must not contain `#`. No privileged tests. No stdin-filter
hangs. Never `setenv`/`unsetenv`. Prefer calling
`resolveDimension` directly so ioctl cannot skip the case.
Do not use `env.test_overrides` unless a test specifically
exercises `getWidth`'s `env.getEnv` wiring; even then, a TTY
ioctl of a positive width still wins, so that is not the RED
for the 0-fallback.

`COLUMNS=120` already returns 120 via `parseInt` when ioctl is
skipped. That is **not** a RED test for this slice.

Terminal (`src/common/terminal.zig`), against
`resolveDimension`:

1. `terminal resolveDimension uses positive ioctl` — ioctl 80,
   env `"0"` → 80 (ioctl wins; env ignored).
2. `terminal resolveDimension falls back when ioctl is 0` —
   ioctl 0, env `"120"` → 120.
3. `terminal resolveDimension falls back when COLUMNS is 0` —
   ioctl null, env `"0"` → `DEFAULT_TERMINAL_WIDTH`.
4. `terminal resolveDimension falls back on empty env` — ioctl
   null, env `""` → default.
5. `terminal resolveDimension falls back on non-numeric env` —
   ioctl null, env `"abc"` → default.
6. `terminal resolveDimension uses positive env when ioctl is
   null` — ioctl null, env `"120"` → 120.
7. `terminal resolveDimension falls back when LINES is 0` —
   same as (3) with `DEFAULT_TERMINAL_HEIGHT`.
8. Existing `terminal width detection` / `height detection`
   stay green (`> 0`).

Parallel (`src/common/parallel.zig`):

9. `parallel runBounded with 0 jobs is a no-op` — counter
   stays 0; no spawn.
10. `parallel runBounded runs every job` — 5 jobs,
    `std.atomic.Value(u32)` increment; load == 5.
11. `parallel runBounded treats 0 workers as 1` — 3 jobs, 0
    workers; all 3 run.
12. `parallel runBounded caps workers at parallel_workers_max`
    — request 64 workers, 16 jobs. An atomic in-flight counter
    peaks at ≤ 8 and all 16 jobs run. The spawn loop itself
    is bounded by `parallel_workers_max`.
13. `parallel runBounded returns the lowest job index error` —
    jobs 1 and 3 fail with distinct errors; result is job 1's
    error; all workers joined (no leak under the testing
    allocator / no hang).

Prove RED:

- (1)–(7) fail while ioctl 0 / env 0 / invalid env can yield 0
  or skip the fallback (today `parseInt("0")` succeeds and
  returns 0; ioctl `ws.col == 0` returns 0).
- (9)–(13) fail until the module exists. Test-writer may stub
  `runBounded` so tests compile and fail assertions. Do not
  implement the worker loop in the stub.

## Risks

- **Issue #95:** never `setenv`/`unsetenv`. Tests of the
  resolver take string slices. `env.test_overrides` is only
  for a future `getWidth` wiring test, not for the 0-fallback
  RED.
- **`env.getEnv` in 0.16:** follow zig-patterns; do not use
  removed `std.posix.getenv`.
- **Zig 0.16 concurrency:** `std.Io.Group`, not
  `std.Thread.Pool`. Mix-and-match `Thread.Mutex` + `Io` is
  incorrect. Atomics are allowed without `Io`.
- **ConcurrencyUnavailable:** sequential remainder on the
  caller after joining started workers. `-fsingle-threaded`
  builds must still complete jobs.
- **macOS:** ioctl `TIOCGWINSZ` is the existing path; do not
  `@intCast` signed fields that can have the high bit set
  (`ws.col` is unsigned).
- **Dead-code concern:** `parallel.zig` is used by its tests
  and force-imported. Round-1 2/3 accepted that as the
  checkbox. Do not invent a `cp` consumer to silence it.
- **Trust the OS:** no path-traversal checks in the helper.
- **G14:** assert `result > 0` after fallback, not as a
  substitute for fallback.

## Plan review (round 1 → this revision)

Blocking items folded in:

- Grok: no `setenv`; extract a pure helper because ioctl
  runs first on a TTY; assert after fallback; atomics in
  parallel tests; `n_workers == 0` → 1; spawn cap observable.
- GPT: `COLUMNS=120` is not RED; add ioctl-zero coverage;
  stronger parallel contracts (lowest failing index, join
  after error). Declined: production `cp` consumer (2/3).
- Fable: approved the library+force-import checkbox and the
  predecessor deviation.

Re-run the three reviewers on this delta before any Zig.
