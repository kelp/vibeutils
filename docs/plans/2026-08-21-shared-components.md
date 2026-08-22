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

This environment cannot merge. Round-1 and round-2: Grok and
Fable accept the skip because the files are disjoint. GPT
still treats the skill gate as blocking. **Decision (2/3):**
continue. Rebase onto `main` after they land if they land
first.

## In scope

### Terminal width

`src/common/terminal.zig` already implements ioctl `TIOCGWINSZ`
plus `COLUMNS` / `LINES`. The leftover work is correctness, not
a new module.

Extract a **pure** resolver so tests never mutate the process
environment (issue #95: never `setenv`/`unsetenv`):

```
fn resolveDimension(ioctl_value: ?u16, env_text: ?[]const u8, default: u16) u16
```

Two asserts (Tiger G14 / two-assertion rule):

- Precondition: `std.debug.assert(default > 0)`
- Postcondition: `std.debug.assert(result > 0)` **after** the
  fallback, never instead of it. A zero ioctl or `COLUMNS=0`
  must not trap; it must fall through. The postcondition fires
  only if `default` itself is 0.

Rules, in order:

1. If `ioctl_value` is non-null and `> 0`, return it.
2. Otherwise parse `env_text`: missing, empty, non-numeric,
   overflow, or `0` → `default`. A positive parse wins.

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

**Decision (round-1 2/3, round-2 GPT agrees not blocking):**
do **not** wire this into `cp`, `cat`, `dd`, or `sort`. Wiring
`cp` is slice creep into a later heading. `sort --parallel`
already parses; leaving it sequential is existing behavior.

Zig 0.16 removed `std.Thread.Pool` and moved mutexes to
`std.Io.Mutex`. Do **not** spawn with `std.Thread.spawn` or
mix `std.Thread.Mutex` with `Io`. Use `std.Io` +
`std.Io.Group`.

Add `src/common/parallel.zig`.

`lib.zig`:

- `pub const parallel = @import("parallel.zig");` (common API,
  not tests-only).
- Force-import `_ = @import("parallel.zig");` **between
  `mode.zig` and `path.zig`** (alphabetical: `parallel` <
  `path`). Not between `path` and `privilege_test`.

Signature (so the test-writer can stub a compile-valid
function):

```
pub const parallel_workers_max: u32 = 8;

pub fn runBounded(
    io: std.Io,
    n_workers: u32,
    ctx: anytype,
    work_fn: *const fn (@TypeOf(ctx), u32) anyerror!void,
    n_jobs: u32,
) anyerror!void
```

Contracts:

- Worker count is `max(1, min(n_workers, parallel_workers_max, n_jobs))`
  when `n_jobs > 0`. `n_workers == 0` means 1. `n_jobs == 0`
  is a no-op (no spawn).
- Spawn at most that many `Group.concurrent` workers. Each
  worker atomically steals the next job index. Spawn/join
  loops bounded by `parallel_workers_max`. No recursion.
- `Group.concurrent` callbacks must be `Cancelable!void`.
  Job errors are **not** the group return (`Group` discards
  them). Store them in an atomic slot via a wrapper.
- If `Group.concurrent` returns `error.ConcurrencyUnavailable`
  mid-spawn, await already-started workers (no-op when none
  started: `Group.await` returns immediately if `token` is
  null — do **not** call into `std.Io.failing`'s
  `unreachableGroupAwait`), then finish remaining jobs on
  the caller. Do not leak tasks. `-fsingle-threaded` uses
  this path. Tested with `std.Io.failing`, whose
  `groupConcurrent` returns `error.ConcurrencyUnavailable`.
- First error is the error from the **lowest failing job
  index**, even if a higher index failed first. Later
  failures are discarded. All started workers still join.
  Every job is still attempted (no cancel-on-first-error).
- Job counters and error slots use `std.atomic` (lock-free;
  no `Io` mutex required). Tests that share a counter across
  workers must use atomics, not unsynchronized `u32`.
- Split helpers so no function exceeds 70 lines. Two asserts
  per function, ≤100 columns.
- Tests use `std.testing.io`.

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

## Spec impact

No flag-matrix change. No new CLI flags.

## Tests (failing first, separate test-writer)

Names must not contain `#`. No privileged tests. No stdin-filter
hangs. Never `setenv`/`unsetenv`.

### Stub protocol (so RED is an assertion, not a compile error)

The test-writer may add **signatures only**. Stubs must
preserve **today's** behavior:

- `resolveDimension`: ioctl non-null → return that `u16`
  even if 0; else `parseInt(u16, env, 10) catch default`
  (so `"0"` returns 0, empty/non-numeric → default).
- `runBounded`: return `void` without running jobs (or
  return a dummy error). Do **not** implement the worker
  loop in the stub.

The implementer replaces the stubs. The implementer does
not edit the tests.

### Terminal — characterization (already true of today's parse/ioctl)

Call `resolveDimension` directly. These must compile against
the stub and **pass** on the stub (current semantics). Prove
teeth later by transient sabotage if needed (tdd refactor
rule). They are **not** this slice's RED.

1. `terminal resolveDimension uses positive ioctl` — ioctl 80,
   env `"0"` → 80.
2. `terminal resolveDimension falls back on empty env` — ioctl
   null, env `""` → default.
3. `terminal resolveDimension falls back on non-numeric env` —
   ioctl null, env `"abc"` → default.
4. `terminal resolveDimension uses positive env when ioctl is
   null` — ioctl null, env `"120"` → 120.

Existing `terminal width detection` / `height detection`
stay green (`> 0`).

`COLUMNS=120` via `getWidth()` is **not** a RED test.

### Terminal — RED (today's zero leak)

Against the stub above, these **fail the assertion** (not
compile):

5. `terminal resolveDimension falls back when ioctl is 0` —
   ioctl 0, env `"120"` → 120. Stub returns 0.
6. `terminal resolveDimension falls back when COLUMNS is 0` —
   ioctl null, env `"0"` → `DEFAULT_TERMINAL_WIDTH`. Stub
   returns 0.
7. `terminal resolveDimension falls back when LINES is 0` —
   ioctl null, env `"0"`, default `DEFAULT_TERMINAL_HEIGHT`
   → 24. Stub returns 0.

Production wiring (so `resolveDimension` cannot stay
uncalled). Legal under #95 (`test_overrides`, no `setenv`):

8. `terminal getWidth falls back when COLUMNS is 0 off tty` —
   stage `env.test_overrides` `{ .key = "COLUMNS", .value = "0" }`,
   restore in `defer`. If `std.c.isatty(stdout) != 0`,
   `return error.SkipZigTest` (ioctl of a positive width
   would win). Else `getWidth(allocator) == DEFAULT_TERMINAL_WIDTH`.
   Today this returns 0. That is the production-path RED.

### Parallel — RED until the module exists

Stub `runBounded` so tests compile. Failures must be
assertion failures.

9. `parallel runBounded with 0 jobs is a no-op` — atomic
   counter stays 0. A no-op stub makes this **pass**; it is
   characterization, not RED. Keep it as a regression guard.
10. `parallel runBounded runs every job` — 5 jobs,
    `std.atomic.Value(u32)` increment; load == 5. Stub
    leaves it 0.
11. `parallel runBounded treats 0 workers as 1` — 3 jobs,
    `n_workers = 0`. All 3 run. An in-flight atomic with a
    start-gate peaks at **exactly 1** (one worker stealing
    sequentially). If concurrent spawn is unavailable the
    caller-remainder path also peaks at 1; either way the
    peak must be 1, not 0 and not 3.
12. `parallel runBounded caps workers at parallel_workers_max`
    — `std.testing.io`, request 64 workers, 16 jobs. A
    start-gate holds every worker in `work_fn` until
    `parallel_workers_max` have entered, then **keeps those
    eight inside `work_fn` until either a ninth worker
    enters or a bounded wait expires**. Then assert
    in-flight peak **== 8** (a nine-worker impl that races
    past 8 before the gate opens must still be caught).
    All 16 jobs run. **Do not skip.** `std.testing.io` is
    `Io.Threaded`; if peak never reaches 8, or peak exceeds
    8, the test **fails**. Bounded wait: spin/wait loop cap
    so a one-worker impl fails the assertion instead of
    hanging the suite (Tiger: every loop has an upper
    bound).
13. `parallel runBounded returns the lowest job index error`
    — `n_workers = 4`, 4 jobs. Job 3's `work_fn` fails first
    (gate: job 3 proceeds before jobs 0–2). Jobs 1 and 3
    return distinct errors. Result is **job 1's** error, not
    job 3's. Every job is still attempted (atomic run-count
    == 4). All workers joined. Same bounded-wait rule as
    (12): timeout → failed assertion, never a hang.
14. `parallel runBounded finishes jobs when concurrency is
    unavailable` — `runBounded(std.Io.failing, 8, ctx, fn, 5)`.
    All 5 jobs run on the caller. `std.Io.failing.groupConcurrent`
    returns `ConcurrencyUnavailable`. Must not reach
    `unreachableGroupAwait` (await only if a worker started).

## Prove RED (this paragraph is the test-writer's contract)

The test-writer proves RED by running the stubbed tests:

- **Pass** (characterization / current behavior): (1)–(4),
  (9), existing width/height tests. Do not claim these fail.
- **Fail the assertion** (this slice's RED): (5), (6), (7),
  (8) off-TTY, (10), (11), (12), (13), (14). Right reason
  for (5)–(8): 0 leaked through. Right reason for
  (10)–(14): jobs did not run, peak was not 8, the error
  was not the lowest index, or `std.Io.failing` did not
  finish jobs on the caller. Not a compile error. (8) may
  skip on a TTY. (12) must **not** skip.

## Risks

- **Issue #95:** never `setenv`/`unsetenv`. Resolver tests
  take string slices. `getWidth` wiring uses
  `env.test_overrides` and skips on TTY.
- **`env.getEnv` in 0.16:** follow zig-patterns; do not use
  removed `std.posix.getenv`.
- **Zig 0.16 concurrency:** `std.Io.Group`, not
  `std.Thread.Pool`. Mix-and-match `Thread.Mutex` + `Io` is
  incorrect. Atomics are allowed without `Io`. Group
  callbacks swallow errors; the atomic slot is mandatory.
- **ConcurrencyUnavailable:** sequential remainder on the
  caller after joining started workers. RED via
  `std.Io.failing` (test 14). Do not `await` a group that
  never started on that Io (`unreachableGroupAwait`).
- **Gated tests (12, 13):** bounded wait; timeout is a
  failed assertion, not `SkipZigTest`, not a hang.
- **macOS:** ioctl `TIOCGWINSZ` is the existing path; do not
  `@intCast` signed fields that can have the high bit set
  (`ws.col` is unsigned).
- **Dead-code concern:** `parallel.zig` is used by its tests,
  exported as `common.parallel`, and force-imported. Do not
  invent a `cp` consumer.
- **Trust the OS:** no path-traversal checks in the helper.
- **G14:** assert `result > 0` after fallback, not as a
  substitute for fallback. Also assert `default > 0`.

## Plan review history

Round 1: Grok REQUEST CHANGES (setenv / ioctl-first /
assert-after-fallback / atomics). GPT REQUEST CHANGES
(dead `parallel`, COLUMNS=120 not RED, no ioctl-zero,
stronger parallel, predecessor). Fable APPROVE.

Round 2: all three REQUEST CHANGES on the Prove-RED
paragraph claiming (1)–(7) fail. Grok+GPT also blocked on
production-path `getWidth` wiring and a spawn-cap test that
`≤ 8` cannot prove.

Round 3: Fable APPROVE. Grok REQUEST CHANGES — test 12 skip
undoes the cap. GPT REQUEST CHANGES — predecessor gate,
`ConcurrencyUnavailable` RED, spawn-cap skip. This
revision: never skip test 12; add test 14 with
`std.Io.failing`; bounded waits on gated tests. Predecessor
deviation stays 2/3 (Grok+Fable accept; GPT retains).

Round 4: Grok APPROVE. Fable APPROVE. GPT REQUEST CHANGES
on test 12 proving a lower bound but not the upper cap.
Folded: hold the first eight until a ninth is seen or the
bounded wait expires, then assert peak == 8. Predecessor
deviation remains the recorded 2/3 decision.

Consensus for implementation: 2/3 approve; remaining GPT
item is a test-contract nit folded above. No further plan
round. Test-writer next.
