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
  `last_output_slot`: every positional is a slot (`-` is a
  stdin sentinel). Same slot twice → no header. Different
  slots, even with the same path → header.
- Header text stays GNU `\n==> {path} <==\n` (leading newline).
  For stdin, the dump already uses `==> standard input <==`.
  Print a switch header only when the follow chunk is
  **non-empty**; only then update `last_output_slot` (GNU
  `check_fspec`).
- Seed `last_output_slot` from the **last positional**, including
  failed opens, empty files, and `-`. GNU reprints a header
  for `tail -f a missing` when `a` later grows (last operand
  failed, so `a` is a different slot). `tail -f missing a`
  then append to `a` does **not** reprint. Do not seed "no
  slot".
- `-q` / `--quiet`: no switch headers. Reuse
  `TailOptions.shouldShowHeaders`; verbose already beats quiet.
  `shouldShowHeaders` keeps using **operand count** (including
  failed `-f` opens), not follow-set size.
- `-v` / `--verbose`: headers enabled even for one file, but a
  switch still requires a **slot** change, so one slot never
  reprints.
- `-F`: per-file rotation/reopen. Diagnostics:
  `cannot open '{s}' for reading` (initial miss),
  `'{s}' has become inaccessible` (gone during follow),
  `'{s}' has appeared;  following new file` (inactive slot's
  first successful open — GNU, two spaces after the semicolon),
  `'{s}' has been replaced;  following new file` (inode change).
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
  (same as today's single-file `-F`). When the first later
  `openFile` succeeds, print the GNU appeared diagnostic. Do not call today's
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
getting events. The inotify/`kevent` wait still uses a
**1-second timeout** so a quiet set of files wakes the loop.
That timeout is an internal bound, not `--sleep-interval`.

Do **not** retry inactive `-F` slots only when the wait returns
0: a busy sibling would starve appear/rotate. On every loop
wake (event or timeout), if at least one second has elapsed
since the last inactive scan, try `openFile` on each inactive
`-F` slot. Bound that scan by `follow_files_max`.

On success, register a watch, set `last_pos = 0`, print the
GNU appeared diagnostic on the first successful open of a
slot that was missing (once per appear transition, not every
retry tick), print the replaced diagnostic when the inode
changed, and read.
Plain `-f` is descriptor-follow: do **not** deactivate a slot
on `DELETE_SELF` / `MOVE_SELF` / `NOTE.DELETE` / `NOTE.RENAME`.

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
  `inotify_rm_watch` only when **no remaining slot** still
  references that wd. Rotating one of two hard-linked names
  must not drop the watch for the other.

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
   Empty follow chunk → false and `last_output_slot` unchanged.
4. `tail follow switch header after last positional` — last
   positional is slot B (even if B failed to open), follow data
   from B → false; follow data from earlier slot A → true
   (`tail -f a missing` reprints for `a`). Last positional
   stdin, follow slot 0 → true. Guards a "no slot" seed.
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
8. `tail follow inotify rm_watch waits for last slot` — two slots
   share wd 7; releasing slot 0 does not call `rm_watch`;
   releasing slot 1 does. RED-able helper, not the follow loop.
9. Existing `tail: -f flag is parsed`, `tail: -f with nonexistent
   file gives error` / `returns error` stay green (exit 1).

Integration (`tests/utilities/tail_test.sh`): background `tail
-f`, then append, then kill **by PID** (never `pkill -f`). Do
**not** wrap the background `tail` or `wait` in `run_with_limit`
(killing the limiter orphans the child). Track the tail PID,
poll for expected output with a bounded loop, then `kill` that
PID. PATH stays `zig-out/bin`.

10. `tail -f two files sees appends to both` — start `tail -f a
    b`, append a line to `a` and to `b`, both lines appear in
    stdout. No "multiple-file follow not yet supported" on
    stderr.
11. `tail -f two files prints switch headers` — after initial
    dump, append to the **first** file; the appended line is
    **immediately** preceded by `\n==> …a <==\n`. A leftover
    dump header for `a` must not satisfy this.
12. `tail -f two files omits switch header for last dump file` —
    after dumping **non-empty** `a` then **non-empty** `b`,
    append to `b`; the new line appears and is **not**
    immediately preceded by `\n==> …b <==\n`. An empty `b`
    would leave the dump header glued to the append. Teeth:
    unit test 4, not RED against last-file-only.
13. `tail -fq two files omits switch headers` — append to the
    **first** (non-last) file so the test is RED on last-file-only
    follow, and stdout has no `==>`.
14. `tail -f missing existing follows the live file` — named
    case: operands `missing existing`. Open error for missing
    still prints; appends to the live file appear; process does
    not exit before the append.
15. `tail -f existing missing follows the live file` — named
    case: operands `existing missing`. Same live-file follow.
    First follow chunk from `existing` **does** need a switch
    header (last positional failed).
16. `tail -F missing existing follows then both` — live file
    delivers appends while the other path is still missing; after
    the missing path appears, appends to it appear too, and
    stderr contains the literal two-space substring
    `has appeared;  following new file`.
17. `tail -F two files rotate one still follows the other` —
    rotate `a`; appends to `b` still appear; `a`'s replacement is
    followed.
18. `tail -f duplicate operands both emit` — `tail -f a a`; an
    append appears twice **and** the second copy is immediately
    preceded by a switch header for `a`.
19. Existing single-file `-f` / `-F` rotation tests stay green.

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

Round 3: Grok REQUEST CHANGES (seed last positional even on
failed open; `-F` retry must not wait for a quiet timeout),
GPT REQUEST CHANGES (`inotify_rm_watch` shared-wd lifetime),
Fable APPROVE.

Round 5: Grok APPROVE, GPT APPROVE, Fable APPROVE. Consensus.
Nits folded here: appear once per transition; test 16 greps the
two-space substring. No further plan round.
