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
  (macOS) across the follow set in **one** event loop.
- When new data arrives from a different file than the last one
  that produced output (initial dump or follow), print GNU's
  switch header `\n==> {path} <==\n` (leading newline).
- Seed `last_header_path` from the **last file that actually
  produced initial-dump output**, including `-` (stdin). Do not
  seed `null` (that would header the first follow event even when
  it is the same file as the last dump). If the last dump was
  stdin, the first follow chunk from any real file needs a header.
- `-q` / `--quiet`: no switch headers. Reuse
  `TailOptions.shouldShowHeaders`; verbose already beats quiet.
- `-v` / `--verbose`: headers are enabled even for one file, but
  a switch still requires a path change, so a single file never
  reprints.
- `-F`: per-file rotation/reopen, same quoted
  `'{s}' has been replaced;  following new file` diagnostic.
- Truncation detection stays per file.
- Hard cap `follow_files_max = 256`. Count real (non-`-`)
  positionals **before any file I/O**. More than 256 with `-f` /
  `-F` is a diagnostic and exit 1 (Tiger bound). GNU has no cap;
  this is a documented limit, not silent truncation.
- Skip `-` in the follow set (stdin already consumed).

Files: `src/tail.zig`, `tests/utilities/tail_test.sh`,
`man/man1/tail.1`, `CHANGELOG.md`, `TODO.md`. No `build.zig`.
No `src/common/` extraction. No df/free changes.

### Follow-set membership

A naive `try` around every open would exit 1 on the first
unopenable path and drop files that GNU keeps following.

- Plain `-f`: omit unopenable paths from the follow set. Keep
  following every path that opened. `tail -f missing existing`
  and `tail -f existing missing` both follow `existing`.
- `-F`: keep unopenable paths as **inactive** slots (appear-wait).
  Do not call today's wait-forever helpers (`followFile_openInitial`
  / `followFile_waitForReappear`) from the multiplex loop — those
  stall every other file.
- Empty follow set after only `-` (no real files): success; POSIX
  `-f` on a pipe is ignored.
- Empty follow set after every real file failed (`tail -f missing`,
  not `-F`): exit 1.
- Non-empty follow set: enter the loop even if some `-f` opens
  failed.

### `-F` multiplex (no wait-forever)

Missing and replaced slots stay inactive. Active slots keep
getting events. Retry inactive slots on a **1-second wait
timeout** even when no watcher event arrives. That timeout is an
internal bound, not `--sleep-interval` (that flag stays WONT).

On timeout, for each inactive `-F` slot, try `openFile`. On
success, register a watch, set `last_pos = 0`, print the existing
replaced/appeared diagnostic, and read. Bound the slot scan by
`follow_files_max`.

Rotate one of two followed files: the other file must still
deliver appends during the wait.

### Watcher dispatch

- **kqueue:** one kqueue, one kevent per **fd** (ident is the fd).
  Duplicate operands are two fds; each slot has its own `last_pos`.
  `eventlist` of 1 is fine. Rotation replaces that fd's kevent.
- **inotify:** one inotify fd. Duplicate operands and the same
  path added twice share a wd. Map each event to **every** slot
  with that wd (GNU duplicate-operand output: an append can appear
  once per operand, with switch headers between them). Hard links
  are separate paths / wds. Parse **every** `inotify_event` in the
  read buffer; one `read` can deliver several records. Bound the
  record walk and the per-wd fan-out by `follow_files_max`.

### Cap diagnostic

Before the initial dump, if the number of real files is greater
than 256:

```
tail: cannot follow more than 256 files
```

Exit 1. No watches, no dump. Same path repeated 257 times still
counts as 257 (each positional is a slot).

## Out of scope

- `#### 38. wc ✓` and every later heading
- `--follow=name|descriptor`: not in the flag matrix; argparse
  already rejects a value; keep rejecting
- `--pid`, `--sleep-interval`, `--retry`, `--max-unchanged-stats`
  (WONT in `docs/specs/tail-flags.md`)
- Changing `-f` on a stdin pipe (POSIX: ignore; already the case)
- FIFO vs pipe distinction from the macOS man page
- The `-r` combined with `-c`/`-b` audit note
- Changing the existing `had_error and !options.follow` swallow
  for a follow loop that never returns on success

## Spec impact

No flag-matrix change. `-f` is already MUST / `yes`. This slice
implements the remaining GNU/macOS multi-file semantics of that
flag. Man page: `-f` follows every operand, GNU headers when
switching files, and the 256-file cap. Optional example:
`tail -f a b`.

## Tests (failing first, separate test-writer)

Names must not contain `#`. Follow loops are infinite; do not
call `followFile` / the multiplex loop from a unit test. Prefer
helpers plus integration. RED on Linux here; macOS via CI.

Unit (`src/tail.zig`):

1. `tail follow switch header uses GNU form` — helper that
   formats the switch header is `\n==> path <==\n`.
2. `tail follow switch header is omitted when quiet` — given
   quiet, `headerNeeded` is false even when the active file
   changes.
3. `tail follow switch header is needed when the file changes` —
   last file A, new data from B → true; same file A → false.
4. `tail follow switch header is not needed after last dump file` —
   last dump path B, follow data from B → false (guards a
   `last_path = null` seed).
5. `tail follow rejects more than follow_files_max files` —
   `runTail` with `-f` and 257 operands (repeat one path; do not
   create 257 files). Exit 1, stderr mentions the cap, **before**
   any inotify/kqueue registration. Not a resolver-only helper.
6. Existing `tail: -f flag is parsed` and single-file follow
   parse tests stay green.

Integration (`tests/utilities/tail_test.sh`): background `tail
-f`, then append, then kill **by PID** (never `pkill -f`). Do
**not** wrap the background `tail` or `wait` in `run_with_limit`
(killing the limiter orphans the child). Track the tail PID,
poll for expected output with a bounded loop, then `kill` that
PID. PATH stays `zig-out/bin`.

7. `tail -f two files sees appends to both` — start `tail -f a
   b`, append a line to `a` and to `b`, both lines appear in
   stdout. No "multiple-file follow not yet supported" on
   stderr.
8. `tail -f two files prints switch headers` — after initial
   dump, append to the **first** file; stdout contains
   `==> …a <==` before that new line.
9. `tail -f two files omits switch header for last dump file` —
   after dumping `a` then `b`, append to `b`; the new line
   appears and is **not** preceded by a new `==> …b <==`.
10. `tail -fq two files omits switch headers` — append to the
    **first** (non-last) file so the test is RED on last-file-only
    follow, and stdout has no `==>`.
11. `tail -f missing existing follows the live file` — one
    unopenable path, one live path, in either order; appends to
    the live file appear; process does not exit before the append.
12. `tail -F missing existing follows then both` — live file
    delivers appends while the other path is still missing; after
    the missing path appears, appends to it appear too.
13. `tail -F two files rotate one still follows the other` —
    rotate `a`; appends to `b` still appear; `a`'s replacement is
    followed.
14. `tail -f duplicate operands both emit` — `tail -f a a`; an
    append appears twice (GNU duplicate-operand output).
15. Existing single-file `-f` / `-F` rotation tests stay green.

Prove RED against the current last-file-only loop. No stdin hang
in unit tests. No privileged tests.

## Risks

- **Infinite follow loop:** already `tiger:allow:unbounded-loop`.
  Keep one loop; bound the inner scan of `n` files and inotify
  records by `follow_files_max`.
- **macOS kqueue:** one kqueue, one kevent per fd. Rotation
  must replace that fd's kevent. ident is the fd. 1s timeout for
  inactive `-F` retries.
- **Linux inotify:** one inotify fd; wd is **not** 1:1 with slots.
  Fan out; parse the whole event buffer.
- **isatty / headers:** switch headers are not color; they are
  GNU text.
- **Flush:** flush stdout after each follow chunk so the
  integration test can observe appends.
- **Tiger:** new helpers ≤70 lines, two asserts, no recursion,
  `u32` counts. Split a `FollowedFile` struct and per-event
  handlers rather than growing `runInotify` / `runKqueue` past
  70 lines.
- **Trust the OS:** no path-traversal checks.
- **Hard cap vs GNU:** 256 is a new documented limit. Fail-fast
  before the dump. Call it out in the man page.

## Plan review

Round 1 (plan as first committed): Grok REQUEST CHANGES, GPT
REQUEST CHANGES, Fable APPROVE. Blocking items from Grok/GPT
are written into this revision: follow-set/open-failure, negative
switch-header test, `-F` multiplex without wait-forever, inotify
wd fan-out, `runTail` cap test, quiet test on the non-last file,
PID-poll integration (no `run_with_limit` around `wait`).
Fable's non-blocking notes on unopenable files and fail-fast cap
are included. `--follow=name` wording is corrected (not a matrix
flag).
