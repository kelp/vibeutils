# Slice: `### Shared Components` (remaining common-library boxes)

## Slice name

`### Shared Components` remaining unchecked items under
"Create common library for:":

- Terminal width detection for responsive layouts
- Parallel I/O utilities for performance

One heading, one PR. Do not pull `### Build System` (man-page
install), `### Color Support` (`LS_COLORS`), or later headings.

## In scope

### Terminal width

`src/common/terminal.zig` already implements ioctl `TIOCGWINSZ`
plus `COLUMNS` / `LINES`. The leftover work is correctness, not a
new module:

- Never return 0. `COLUMNS=0`, empty, non-numeric, and ioctl
  `ws.col == 0` fall back to `DEFAULT_TERMINAL_WIDTH` (80). Same
  for height / `LINES` / `DEFAULT_TERMINAL_HEIGHT`.
- `std.debug.assert(result > 0)` before every return (G14 note in
  `docs/tiger-style-review/G14-common-foundation.md`).
- Keep Unix ioctl + env fallback. Windows stays the existing
  default-constant path (not a supported target).
- `ls` / `df` already call `common.terminal.getWidth`. No API
  rename. No `src/ls/` layout rewrite.

### Parallel I/O

GNU coreutils has no shared parallel-copy library. This checkbox
is a common helper, not a `cp` behavior change.

Add `src/common/parallel.zig`, exported from `src/common/lib.zig`
(force-import so tests run):

- Hard cap `parallel_workers_max: u32 = 8`.
- `runBounded(allocator, n_workers, ctx, work_fn, n_jobs)` runs
  `work_fn(ctx, job_index)` for `job_index` in `0 .. n_jobs` with
  at most `min(n_workers, parallel_workers_max, n_jobs)` threads.
- `n_workers == 0` means 1. `n_jobs == 0` is a no-op.
- First error from any worker is returned after join. Remaining
  workers still join (no leaked threads).
- No recursion. Inner spawn/join loops bounded by
  `parallel_workers_max`. Two asserts per function, ≤70 lines.
- Do **not** wire this into `cp`, `cat`, `dd`, or `sort` in this
  slice. `sort --parallel` already parses; leaving it sequential
  is existing behavior.

Files: `src/common/terminal.zig`, `src/common/parallel.zig`,
`src/common/lib.zig`, `TODO.md`, `CHANGELOG.md` only if
user-visible (terminal `COLUMNS=0` fallback is user-visible for
`ls` column layout). No `build.zig`. No man pages.

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
hangs.

Terminal (`src/common/terminal.zig`):

1. `terminal width falls back when COLUMNS is 0` — with
   `COLUMNS=0`, `getWidth` returns `DEFAULT_TERMINAL_WIDTH`.
2. `terminal width uses COLUMNS when positive` — `COLUMNS=120`
   returns 120 when ioctl is unavailable or skipped (test can
   force the env path, or set COLUMNS and accept ioctl-or-env
   ≥1). Prefer a helper that parses the env fallback so RED is
   deterministic without a tty.
3. `terminal height falls back when LINES is 0`.
4. Existing `terminal width detection` / `height detection` stay
   green (`> 0`).

Parallel (`src/common/parallel.zig`):

5. `parallel runBounded with 0 jobs is a no-op`.
6. `parallel runBounded runs every job` — 5 jobs increment a
   counter; counter == 5.
7. `parallel runBounded caps workers at parallel_workers_max` —
   request 64 workers, 9 jobs; still all 9 run; never spawn more
   than 8 threads (assert via a spawn-count in the helper or by
   capping the spawn loop).
8. `parallel runBounded returns the first worker error` — one of
   4 jobs returns an error; `runBounded` returns that error;
   all threads joined.

Prove RED: (1)–(3) fail while `COLUMNS=0` can yield 0; (5)–(8)
fail until the module exists (test-writer may stub functions so
tests compile and fail assertions).

## Risks

- **Env mutation in tests:** set/restore `COLUMNS`/`LINES`; do
  not leak into other tests. Prefer a parse helper over process
  env if `env.getEnv` is global.
- **`env.getEnv` in 0.16:** follow zig-patterns; do not use
  removed `std.posix.getenv`.
- **Threads:** join on every path. Cap 8. No detached threads.
- **macOS:** ioctl `TIOCGWINSZ` is the existing path; do not
  `@intCast` signed fields that can have the high bit set
  (`ws.col` is unsigned).
- **Dead-code concern:** `parallel.zig` is used by its tests and
  force-imported. That is the common-library checkbox, not a
  silent `cp` change.
- **Trust the OS:** no path-traversal checks in the helper.

## Plan review

Predecessor slices `#### 28. free` and `#### 37. tail` are still
open PRs (#182, #183). This branch is from `origin/main` and
does not touch those files. Recorded so reviewers know why the
listed-order predecessor is not on `main` yet.
