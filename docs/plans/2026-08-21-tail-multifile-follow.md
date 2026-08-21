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
- Switch headers use **slot identity**, not pathname identity.
  GNU `tail -f a a` prints a header before each operand's
  appended chunk even though the paths are equal. Track
  `last_output_slot`: stdin is a sentinel; each follow-set
  member is a distinct slot. Same slot twice → no header.
  Different slots, even with the same path → header.
- Header text stays GNU `\n==> {path} <==\n` (leading newline).
  For stdin, the dump already uses `==> standard input <==`.
- Seed `last_output_slot` from the **last operand that was
  successfully dumped**, including empty files and `-`. Do not
  seed "no slot" (that would header the first follow event even
  when it is the same slot as the last dump). If the last dump
  was stdin, the first follow chunk from any real slot needs a
  header.
- `-q` / `--quiet`: no switch headers. Reuse
  `TailOptions.shouldShowHeaders`; verbose already beats quiet.
  `shouldShowHeaders` keeps using **operand count** (including
  failed `-f` opens), not follow-set size.
- `-v` / `--verbose`: headers enabled even for one file, but a
  switch still requires a **slot** change, so one slot never
  reprints.
- `-F`: per-file rotation/reopen. Diagnostics stay the existing
  ones: `cannot open '{s}' for reading` (initial miss),
  `'{s}' has become inaccessible` (gone during follow),
  `'{s}' has been replaced;  following new file` (inode change).
  Do not invent an "appeared" message.
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
  and `tail -f existing missing` both follow `existing`. The
  open error for `missing` still prints during the dump.
- `-F`: keep unopenable paths as **inactive** slots (appear-wait).
  Print `cannot open` once when the slot is first seen missing
  (same as today's single-file `-F`). Do not call today's
  wait-forever helpers (`followFile_openInitial` /
  `followFile_waitForReappear`) from the multiplex loop — those
  stall every other file.
- Empty follow set after only `-` (no real files): success; POSIX
  `-f` on a pipe is ignored. Existing unit coverage of `-f` plus
  a missing file stays exit 1.
- Empty follow set after every real file failed (`tail -f missing`,
  not `-F`): exit 1.
- Non-empty follow set: enter the loop even if some `-f` opens
  failed.

### `-F` multiplex (no wait-forever)

Missing and replaced slots stay inactive. Active slots keep
getting events. Retry inactive slots on a **1-second wait
timeout** (`poll` on the inotify fd; `timespec` on `kevent`)
even when no watcher event arrives. That timeout is an internal
bound, not `--sleep-interval` (that flag stays WONT).

On timeout, for each inactive `-F` slot, try `openFile`. On
success, register a watch, set `last_pos = 0`, print the existing
replaced diagnostic when the inode changed, and read. Bound the
slot scan by `follow_files_max`.

Rotate one of two followed files: the other file must still
deliver appends during the wait.

### Watcher dispatch

- **kqueue:** one kqueue, one kevent per **fd** (ident is the fd).
  Duplicate operands are two fds; each slot has its own `last_pos`.
  `eventlist` of 1 is fine. Rotation replaces that fd's kevent.
- **inotify:** one inotify fd. Watches are inode objects: duplicate
  operands and hard links of the same inode can share a wd. Map
  each event to **every** slot with that wd (GNU duplicate-operand
  output: an append appears once per operand, with switch headers
  between slots). Parse **every** `inotify_event` in the read
  buffer; one `read` can deliver several records. Bound the
  record walk and the per-wd fan-out by `follow_files_max`.

### Cap diagnostic

Before the initial dump, if the number of real files is greater
than 256:

```
tail: cannot follow more than 256 files
```

Exit 1. No watches, no dump, no per-file `cannot open`. Same path
repeated 257 times still counts as 257 (each positional is a slot).

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
switching **slots**, and the 256-file cap. Optional example:
`tail -f a b`.

## Tests (failing first, separate test-writer)

Names must not contain `#`. Follow loops are infinite; do not
call `followFile` / the multiplex loop from a unit test. Prefer
helpers plus integration. RED on Linux here; macOS via CI.

Local gates after GREEN: `just fmt-check`,
`zig build test -Dtest-util=tail`, `just it-util tail`. CI covers
Linux and macOS.

Unit (`src/tail.zig`):

1. `tail follow switch header uses GNU form` — helper that
   formats the switch header is `\n==> path <==\n`.
2. `tail follow switch header is omitted when quiet` — given
   quiet, `headerNeeded` is false even when the active **slot**
   changes.
3. `tail follow switch header is needed when the slot changes` —
   last slot A, new data from slot B → true; same slot A → false.
   Two slots with the same path → true (duplicate operands).
4. `tail follow switch header is not needed after last dump slot` —
   last dump slot B, follow data from B → false (guards a
   "no slot" seed). Last dump stdin sentinel, follow slot 0 →
   true.
5. `tail follow rejects more than follow_files_max files` —
   `runTail` with `-f` and 257 **nonexistent** operands (repeat
   one missing path). Finite RED: today's code follows the last
   missing file and prints `cannot open`, not the cap line. GREEN:
   exit 1, stderr is the cap diagnostic, stdout empty, no
   `cannot open` flood, no inotify/kqueue registration. Do not
   pass 257 openable files to `runTail` (that hangs today).
6. `tail follow inotify buffer walks every record` — helper that
   parses a synthetic buffer with two packed `inotify_event`
   records returns both wds. Appending to two files is not a
   substitute (one `read` is not guaranteed).
7. `tail follow wd fans out to every matching slot` — given two
   slots sharing wd 7, dispatch returns both slot indexes. Covers
   duplicate operands and hard-linked inodes.
8. Existing `tail: -f flag is parsed`, `tail: -f with nonexistent
   file gives error` / `returns error` stay green (exit 1).

Integration (`tests/utilities/tail_test.sh`): background `tail
-f`, then append, then kill **by PID** (never `pkill -f`). Do
**not** wrap the background `tail` or `wait` in `run_with_limit`
(killing the limiter orphans the child). Track the tail PID,
poll for expected output with a bounded loop, then `kill` that
PID. PATH stays `zig-out/bin`.

9. `tail -f two files sees appends to both` — start `tail -f a
   b`, append a line to `a` and to `b`, both lines appear in
   stdout. No "multiple-file follow not yet supported" on
   stderr.
10. `tail -f two files prints switch headers` — after initial
    dump, append to the **first** file; the appended line is
    **immediately** preceded by `\n==> …a <==\n`. A leftover
    dump header for `a` must not satisfy this.
11. `tail -f two files omits switch header for last dump file` —
    after dumping `a` then `b`, append to `b`; the new line
    appears and is **not** immediately preceded by
    `\n==> …b <==\n`. Teeth: unit test 4 (null-seed sabotage),
    not RED against last-file-only.
12. `tail -fq two files omits switch headers` — append to the
    **first** (non-last) file so the test is RED on last-file-only
    follow, and stdout has no `==>`.
13. `tail -f missing existing follows the live file` — named
    case: operands `missing existing`. Open error for missing
    still prints; appends to the live file appear; process does
    not exit before the append.
14. `tail -f existing missing follows the live file` — named
    case: operands `existing missing`. Same live-file follow.
15. `tail -F missing existing follows then both` — live file
    delivers appends while the other path is still missing; after
    the missing path appears, appends to it appear too.
16. `tail -F two files rotate one still follows the other` —
    rotate `a`; appends to `b` still appear; `a`'s replacement is
    followed.
17. `tail -f duplicate operands both emit` — `tail -f a a`; an
    append appears twice **and** the second copy is immediately
    preceded by a switch header for `a`.
18. Existing single-file `-f` / `-F` rotation tests stay green.

Prove RED against the current last-file-only loop for tests that
the last-file loop can fail. Characterization tests of already-
working behavior stay green; prove teeth with transient sabotage
only when they cannot go RED on the current loop. No stdin hang
in unit tests. No privileged tests.

## Risks

- **Infinite follow loop:** already `tiger:allow:unbounded-loop`.
  Keep one loop; bound the inner scan of `n` files and inotify
  records by `follow_files_max`.
- **macOS kqueue:** one kqueue, one kevent per fd. Rotation
  must replace that fd's kevent. ident is the fd. 1s timeout for
  inactive `-F` retries.
- **Linux inotify:** one inotify fd; wd is **not** 1:1 with slots.
  Fan out by wd (duplicates and hard links); parse the whole
  event buffer.
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

Round 1: Grok REQUEST CHANGES, GPT REQUEST CHANGES, Fable
APPROVE. Follow-set, `-F` multiplex, cap, quiet-on-first-file,
and PID-poll landed in revision 2.

Round 2: Grok REQUEST CHANGES (cap test must be finite RED;
switch-header integration must require the follow-time header
immediately before the appended line), GPT REQUEST CHANGES
(slot identity vs path; inotify hard-link/wd; extra helper
tests), Fable APPROVE.

This revision: slot identity; 257 nonexistent paths for a
finite cap RED; immediate-precede header assertion; inotify
inode/wd correction; synthetic multi-record parser + wd fan-out
unit tests; two named missing/existing cases; no invented
"appeared" diagnostic; local gates named.
