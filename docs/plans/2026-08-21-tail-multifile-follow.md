# Slice: `#### 37. tail ✓` (multi-file follow)

## Slice name

`#### 37. tail ✓` remaining unchecked item:

- Implement: Multi-file follow (GNU tail follows all files)

One heading, one PR. Already-checked tail items stay untouched.

## In scope

GNU is the behavioral reference. `tail -f a b` follows **every**
real (non-`-`) positional, not only the last one.

- Remove the stderr warning
  `following only '{s}'; multiple-file follow not yet supported`.
- After the initial dump, multiplex inotify (Linux) / kqueue
  (macOS) across all followed files.
- When new data arrives from a different file than the last one
  that produced follow output, print GNU's switch header
  `\n==> {path} <==\n` (leading newline). The first follow-time
  header after the initial dump also uses that form when the
  producing file is not the last file of the initial dump.
- `-q` / `--quiet`: no switch headers (same as initial dump).
- `-v` / `--verbose`: switch headers even for a single followed
  file when GNU would print them (only on a file change, so a
  single file never reprints).
- `-F`: per-file rotation/reopen, same quoted
  `'{s}' has been replaced;  following new file` diagnostic.
- Truncation detection stays per file.
- Hard cap `follow_files_max = 256`. More real files with `-f`
  is a diagnostic and exit 1 (Tiger bound). GNU has no cap; this
  is a documented limit, not silent truncation.
- Skip `-` in the follow set (stdin already consumed).

Files: `src/tail.zig`, `tests/utilities/tail_test.sh`,
`man/man1/tail.1`, `CHANGELOG.md`, `TODO.md`. No `build.zig`.
No `src/common/` extraction. No df/free changes.

## Out of scope

- `#### 38. wc ✓` and every later heading
- `--follow=name|descriptor` (argparse already rejects a value;
  WONT-adjacent GNU extra)
- `--pid`, `--sleep-interval`, `--retry`, `--max-unchanged-stats`
  (WONT in `docs/specs/tail-flags.md`)
- Changing `-f` on a stdin pipe (POSIX: ignore; already the case)
- FIFO vs pipe distinction from the macOS man page
- The `-r` combined with `-c`/`-b` audit note

## Spec impact

No flag-matrix change. `-f` is already MUST / `yes`. This slice
implements the remaining GNU/macOS multi-file semantics of that
flag. Design note only in the man page: `-f` follows every
operand, with GNU headers when switching files.

## Tests (failing first, separate test-writer)

Names must not contain `#`. Follow loops are infinite; do not
call `followFile` from a unit test without a bound. Prefer
helpers plus integration.

Unit (`src/tail.zig`):

1. `tail follow switch header uses GNU form` — helper that
   formats the switch header is `\n==> path <==\n`.
2. `tail follow switch header is omitted when quiet` — given
   quiet, `headerNeeded` is false even when the active file
   changes.
3. `tail follow switch header is needed when the file changes` —
   last file A, new data from B → true; same file A → false.
4. `tail follow rejects more than follow_files_max files` —
   `runTail` with `-f` and 257 file operands (or a test that
   calls the resolver with a 257-long slice) exits 1 and mentions
   the cap. Do not create 257 real files if a resolver helper
   can take the count.
5. Existing `tail: -f flag is parsed` and single-file follow
   tests stay green.

Integration (`tests/utilities/tail_test.sh`), background `tail
-f` then append, then kill **by PID** (never `pkill -f`). Use
`run_with_limit` around any wait. PATH stays `zig-out/bin`.

6. `tail -f two files sees appends to both` — start `tail -f a
   b`, append a line to `a` and to `b`, both lines appear in
   stdout. No "multiple-file follow not yet supported" on
   stderr.
7. `tail -f two files prints switch headers` — after initial
   dump, append to the first file; stdout contains
   `==> …a <==` (or the path as printed) before that new line.
8. `tail -fq two files omits switch headers`.
9. Existing single-file `-f` / `-F` rotation tests stay green.

Prove RED against the current last-file-only loop. No stdin hang
in unit tests. No privileged tests.

## Risks

- **Infinite follow loop:** already `tiger:allow:unbounded-loop`.
  Keep one loop; bound the inner scan of `n` files by
  `follow_files_max`.
- **macOS kqueue:** one kqueue, one kevent per fd. Rotation
  must replace that fd's kevent. ident is the fd.
- **Linux inotify:** one inotify fd, one wd per path. Map wd
  back to the file slot with a bounded scan.
- **isatty / headers:** switch headers are not color; they are
  GNU text. Do not emit them into a test buffer unless `-f`
  actually runs.
- **Flush:** flush stdout after each follow chunk so the
  integration test can observe appends.
- **Tiger:** new helpers ≤70 lines, two asserts, no recursion,
  `u32` counts. `followFile` / `runInotify` / `runKqueue` will
  grow — split a `FollowedFile` struct and per-event handlers
  rather than tripling those functions.
- **Trust the OS:** no path-traversal checks.
- **Hard cap vs GNU:** 256 is a new documented limit. Call it
  out in the man page so it is not a silent WONT.
