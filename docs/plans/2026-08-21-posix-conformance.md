# Slice: POSIX Behavioral Conformance Suite

## Slice name

`### 2. POSIX Behavioral Conformance Suite`

One heading, one PR. Nested boxes under that heading
belong here. Do not pull `### 1. File Descriptor Mode
Tests` (the five fd configurations), `### 3` TestDir,
`### 5` main() coverage, `### 6` dd `conv=`, `## Bugs`
(`ls` pipe columns), or any Modern Features heading.

## Predecessor gate (recorded deviation)

Listed Testing Improvements order would wait for `### 1`
(PR #192) to land on `main`. This environment cannot
merge. Branch from `github/main` (`a41eccd`).

`TODO.md` / `CHANGELOG.md` will conflict with stacked
slices; rebase after predecessors land. Do **not** stack
on #192, and do **not** source, copy, or extend
`tests/lib/fd_modes.sh`. That harness owns append / pipe
/ truncate / dup as *fd configurations*. This slice owns
the POSIX I/O *contracts* (SIGPIPE/EPIPE, unbuffered
stderr, POSIX exit codes, and the POSIX-named `>>`
append rule). Overlap with #192 on `>>` is one
assertion per binary (prefix survives), not a
reimplementation of the five-mode matrix.

Do not stack on #177 (`dd.zig`) or #189 (`du.zig`).
Do not stack on #191.

## Review revision (2026-08-21, round 2)

Three-model plan review (Grok, Sol, Fable) all voted
REQUEST CHANGES. Decisions, recorded here:

1. **Wait-test is test-writer-owned.** Inline Python in
   `tests/tools/posix_io_test.sh`. It talks to
   `$BIN_DIR/cat` directly. It does **not** go through
   `posix_io_unbuffered_stderr` in the implementer
   harness. RED is `select` timeout while cat is still
   blocked — proven against current `main` cat
   (`select_ready=False elapsed=2.002 still_running=True
   stderr_bytes=b''`). A missing harness is a *second*
   RED (coverage), never a substitute for the buffering
   assertion. A `return 0` stub cannot satisfy the
   wait-test because the wait-test does not call the
   stub.
2. **Exit table is measured, not guessed.**
   `--posix-io-no-such-flag` is an operand for `echo`
   and `printf` (both exit 0). Default unknown → 1 is
   wrong for those two. Do not "fix" echo/printf.
3. **`env` stderr has a tooth.** Shared
   `unbufferedStderr` helper used by `utilityMain`
   (including the arg-allocation failure path) and
   `env.zig`. A `lib.zig` source lint fails if either
   file constructs stderr with a positive-length
   buffer. The cat wait-test remains the runtime tooth
   for `utilityMain`.
4. **Append sabotage is not `.writer()` on Linux.**
   Linux honors `O_APPEND` even for `pwrite`, and
   `.writer()` also trips the issue #5 source lint.
   Append teeth are the echo+seed integration
   assertion; macOS CI is the platform that would
   catch a positional-writer regression. Do not
   require a Linux sabotage that cannot go RED.
5. **Closed-pipe tooth is unbounded `yes`.** The other
   ~46 `--help` rows are hang-detection. Zig's
   `std.Io.Threaded.init` installs a no-op SIGPIPE
   handler, so binaries see `error.BrokenPipe` rather
   than dying 141. The PASS set (SIGPIPE **or** exit
   0/1) stays.
6. **Wait-test accumulates** until the marker
   `posix-io-missing` appears or the 2s deadline
   fires. Do not assert on the first `read` (`cat: `
   is a separate `print` from the filename). FAIL if
   the process exits before the marker is visible
   (flush-on-exit cheat).
7. **GREEN gate includes `env -u NO_COLOR just it`**,
   not only a handful of `it-util` names.
8. **Empty buffer shape is `&[0]u8{}`**, not `&.{}`.
9. **RED invocation is `bash tests/tools/posix_io_test.sh`.**
   The `just test-posix-io` recipe may be test-writer
   or implementer; do not require it before it exists.

## Classification

Mostly test infrastructure. One production behavior
change: **stderr is unbuffered** via a shared helper
used by `utilityMain` (both the success path and the
arg-allocation failure path) and `env`'s custom
`main()`. No flags, no man-page flag tables, no
`docs/specs/` edits.

`CHANGELOG.md` gets one user-visible bullet for the
stderr change (diagnostics no longer sit in an 8KB
buffer until exit; `cat MISSING -` emits the
diagnostic before copying stdin). `TODO.md` checks
the five boxes under this heading.

## In scope

The five TODO boxes:

1. `>>` must append, not overwrite.
2. Stdout to a closed pipe must produce SIGPIPE/EPIPE.
3. Stderr must be unbuffered.
4. Exit codes conform to POSIX / GNU (this repo's
   `common.ExitCode` doc comment).
5. Utility-agnostic: the same I/O contract tests run
   against every `build/utils.zig` binary.

### Harness vs oracle (agent split)

**Test-writer owns** `tests/tools/posix_io_test.sh`
end-to-end: name parser, fixture coverage loop, the
inline cat wait-test, echo/true append assertions,
yes closed-pipe assertion, and the exit-code table.
The test-writer does not edit production Zig and does
not write `tests/lib/posix_io.sh` bodies that make
those assertions pass.

**Implementer owns** `tests/lib/posix_io.sh` (fixture
table, spawn helpers, `test_posix_io` runner hook),
the `test_runner.sh` hook, production stderr
unbuffer + source lint, `CHANGELOG.md` / `TODO.md` /
`TESTING_STRATEGY.md`. The implementer does **not**
edit the oracle's assertions or the wait-test Python.

Do **not** add `tests/utilities/posix_io_test.sh`
(the runner would look for a `posix_io` binary).

New `tests/lib/posix_io.sh`, sourced from
`tests/lib/test_runner.sh`. After `init_test_session`
(so `$TEMP_DIR` exists), `run_utility_tests` calls
`test_posix_io "$util"`. PATH stays pinned to
`zig-out/bin` (issue #167). Invoke the oracle once
from `run_all_utility_tests`. A `just test-posix-io`
recipe may wrap `bash tests/tools/posix_io_test.sh`;
it is not a substitute for the `just it` hook.

`tests/lib/common.sh` enables `set -euo pipefail`.
Capture every spawn status (`set +e` then restore
`set -e`, as `test_command_output_exact` does).
`false` exiting 1 is success for the I/O assertions.
`run_with_limit` returning 124 is FAIL.

Scratch lives under `$TEMP_DIR/posix_io_scratch`.
That directory name must **not** contain a utility
name. Dest files inside it are `append`, `seed`,
`help.out`, never `*dirname*` / `*pwd*` / `*touch*`
/ `*wc*` / `*rm*` / `*test*`. `trap` `rm -rf` the
scratch on EXIT inside `test_posix_io` so a mid-loop
FAIL still cleans up. `dirname_test.sh` and siblings
fail when leftover `$TEMP_DIR` files matching
`*<util>*` exceed a threshold.

Python 3 is already required by `run_with_limit` and
`run_with_stderr_tty`. Use it for the closed-pipe
helper and the wait-test. Do not add a C helper.

### Fixtures

Every `build/utils.zig` name has an explicit argv
recipe. Missing fixture is a FAIL, not a skip.

Default argv is `--help` with stdin `/dev/null`, except
the locked rows below. Spawn `$BIN_DIR/$name` (never
bash builtins). Prefix `NO_COLOR=1` on each spawn; do
not export it.

Locked exceptions:

| util | argv | why |
| --- | --- | --- |
| `echo` | `echo posix-io` | known payload; append tooth |
| `true` / `false` | no extra args | POSIX ignores args |
| `test` | `test -n x` | `--help` is an expression |
| `[` | `[ -n x ]` | same; trailing `]` required |
| `sleep` | `sleep 0` | no delay |
| `yes` | `yes --help` for append / help-exit; unbounded `yes` only for the closed-pipe probe | `--help` exits; never hang the suite |
| `env` | `env --help` | env's own `main()`, not a child |
| `timeout` | `timeout --help` | timeout's own writers, not a child |
| `printf` | `printf posix-io` | `--help` is fine for help-exit; unknown flag is an operand (see exit table) |
| `date` / `mktemp` / `free` / `df` / `ls` / `find` / `du` | `--help` | deterministic; do not walk the repo or create `/tmp` files |
| filters (`cat`, `tee`, `sort`, `head`, `tail`, `wc`, `grep`, `nl`, `tac`, `uniq`, `cut`, `tr`) | `--help` | never block on stdin |

### Contract 1 — `>>` must append

Seed the dest file with the exact bytes `EXISTING\n`
(`printf`, not `echo`; compare with `cmp`, not
`$(...)` which strips a trailing newline). Run the
fixture `>> file`. Assert the file **starts with**
`EXISTING\n`.

`echo posix-io` is the tooth: dest becomes seed +
`posix-io\n`. `true` is the vacuous case: dest equals
the seed.

This is the POSIX-named sibling of issue #5, not
fd-mode's five-mode matrix. Do not test pipe /
truncate / dup here.

On current `main` this contract is expected GREEN
(issue #5 is already fixed). The test-writer still
lands it. Do **not** sabotage via `.writer()`: on
Linux that still appends, and it trips the issue #5
source lint in `zig build test`. Teeth: the echo+seed
assertion stays in the oracle; macOS CI is the
platform that would catch a positional-writer
regression.

### Contract 2 — closed pipe → SIGPIPE / EPIPE

Python helper in the **implementer** harness (spawn
glue only): `pipe()`, `os.close(read_end)`,
`dup2(write_end, 1)`, `execv` the fixture. The read
end is already closed **before** exec, so this is not
the racy `cmd | true` shape.

Wrap with `run_with_limit 2`. 124 is FAIL (hang).

PASS if the process terminates and the wait status is
any of:

- signaled `SIGPIPE` (parent sees 141 = 128+13)
- exited 0 or 1 after catching `error.BrokenPipe`

FAIL: hang, or any other signal.

Zig `std.Io.Threaded.init` installs a no-op SIGPIPE
handler, so vibeutils binaries observe
`error.BrokenPipe` rather than dying with 141. Keep
that. This contract is "the write observes the closed
pipe", not "die with 141". Do not change SIGPIPE
disposition. Do not make `yes` `_exit` on EPIPE; it
already catches BrokenPipe and exits 0.

`--help` fixtures write less than the 8KB stdout
buffer, so they are hang-detection only. The tooth is
**unbounded `yes`**: it writes more than the buffer
and must terminate on a closed stdout rather than
run until the limit.

`true` writes 0 bytes; the closed-pipe probe is
vacuous (exits 0 without a write). That is allowed.

### Contract 3 — stderr is unbuffered

POSIX XCU 2.5.1: stderr is not fully buffered.
Zig `std.Io.Writer` documents that a zero-length
buffer is unbuffered and `flush` is a no-op.

**Production change.** Add
`common.unbufferedStderr(io: std.Io, buffer: *[0]u8)`
(name may vary; one helper, two call sites) that
returns `std.Io.File.stderr().writerStreaming(io, buffer)`.
Callers pass a local `var buf: [0]u8 = .{};` —
`&[0]u8{}` is the locked shape, not `&.{}`.

Call sites:

- `src/common/main.zig` `utilityMain` success path
- `src/common/main.zig` arg-allocation failure path
  (today a 256-byte buffer then flush; that path
  must use the same zero-length helper)
- `src/env.zig` custom `main()` (today 8192)

Leave stdout at 8192. Drop the assertion that stdout
and stderr buffer lengths are equal; replace it with
`stderr writer buffer.len == 0` and
`stdout_buffer.len == 8192`. Update the module
comment: stdout is 8KB buffered; stderr is
unbuffered.

Do **not** flush inside `printErrorWithProgram`. The
unbuffered writer makes each print a syscall. Adding
a flush there would make a still-buffered stderr
pass the wait-test and hide a regression.

**Source lint (implementer, in `lib.zig` next to the
issue #5 `writerStreaming` scan).** Fail `zig build
test` if `src/common/main.zig` or `src/env.zig`
contains `stderr_buffer: [` with a positive length,
or calls `.stderr().writerStreaming(` with a buffer
that is not the shared helper / a `[0]u8`. This is
the tooth for `env` (no wait-after-stderr path) and
the mechanical guard against the flush-cheat plus a
still-buffered writer.

**Behavioral lock (test-writer, inline in the
oracle).** `printErrorWithProgram` does not flush.
`cat MISSING -` reports the missing operand, then
reads stdin for `-`. Python in
`tests/tools/posix_io_test.sh`:

1. Hold stdin open (pipe, keep the write end).
2. Put stderr on a pipe.
3. Spawn `$BIN_DIR/cat "$TEMP_DIR/posix-io-missing" -`
   with `NO_COLOR=1`. The missing path lives under
   `$TEMP_DIR` / the oracle scratch dir, never the
   repo root.
4. Loop `select` + `read` for up to 2 seconds,
   **accumulating** bytes. PASS only if the
   accumulated buffer contains `posix-io-missing`
   **and** `poll()` is still `None` (blocked on
   stdin). FAIL if the process exits before the
   marker is visible. FAIL if the deadline fires
   with no marker (current `main`: select times out,
   `stderr_bytes=b''`, cat still running).
5. Then close stdin and `wait` with a 2s bound.

Do not use `rm -i`: `promptYesNo` already flushes.

This wait-test is **one** representative (`cat`), not
48. The utility-agnostic box is contracts 1, 2, 4
plus the fixture table. Document that in
`docs/TESTING_STRATEGY.md`.

### Contract 4 — exit codes

Measured against `/workspace/zig-out/bin` on
2026-08-21 (current `main`). This is the I/O-contract
matrix, not a per-utility POSIX encyclopedia.

| spawn | expected |
| --- | --- |
| `true` (no args) | 0 |
| `false` (no args) | 1 |
| `false --help` | 1 (POSIX ignores args, still fails) |
| `$name --help` for every other name except `test`, `[` | 0 |
| `test --help` | 0 (`test STRING` is true) |
| `[ --help` | 2 (missing `]`) |
| `$name --posix-io-no-such-flag` default | 1 |
| `echo --posix-io-no-such-flag` | 0 (operand; prints the token) |
| `printf --posix-io-no-such-flag` | 0 (format/operand; prints the token) |
| `true --posix-io-no-such-flag` | 0 (POSIX ignores args) |
| `false --posix-io-no-such-flag` | 1 (POSIX ignores args, still fails) |
| `test --posix-io-no-such-flag` | 0 (nonempty STRING) |
| `[ --posix-io-no-such-flag ]` | 0 (nonempty STRING; `]` required) |
| `grep --posix-io-no-such-flag` | 2 (`ExitCode.serious_error`) |
| `ls --posix-io-no-such-flag` | 2 |
| `sort --posix-io-no-such-flag` | 2 |
| `env --posix-io-no-such-flag` | 125 (`ExitCode.internal_error`) |
| `timeout --posix-io-no-such-flag` | 125 |

Do not reintroduce exit 2 as a generic "misuse" code.
Do not change echo/printf to treat unknown longs as
errors. Do not test every operand-missing path.

On current `main` this contract is expected GREEN.
Prove teeth by transient sabotage of **one expected
code in the oracle**, confirm RED, revert. Never
commit that sabotage.

Implementer API: `posix_io_exit NAME KIND` prints
the numeric status on stdout. `KIND` is `help` or
`unknown` (and for `true`/`false` default, `plain`).
Do not overload a single argv.

### Contract 5 — coverage oracle

`tests/tools/posix_io_test.sh` (test-writer owns this
file; implementer does not edit its assertions):

- Parse 48 `.name = "..."` entries including `[`.
- Source `tests/lib/posix_io.sh` or FAIL (coverage
  RED, distinct from wait-test RED).
- Require `posix_io_has_fixture NAME` for every parsed
  name.
- Run the **inline** cat wait-test (does not need the
  harness; still runs if sourcing fails after the
  wait-test, or run the wait-test first).
- Call implementer API for echo/true append, yes
  closed-pipe, and the exit table.
- `MIN_ASSERTIONS` high enough that an empty harness
  cannot tally green **and** that skipping the
  wait-test cannot tally green.

### Implementer API (`tests/lib/posix_io.sh`)

The oracle sources this file and calls only:

- `posix_io_has_fixture NAME` — 0 iff NAME has a
  fixture row. Empty/missing table is RED for every
  name.
- `posix_io_run CONTRACT NAME FILE` — `CONTRACT` is
  `append` or `closed-pipe`. For `append`, seed FILE
  then `>> FILE`. For `closed-pipe`, exec with stdout
  already a closed pipe; FILE may be unused. Return
  the spawn status (`124` on limit).
- `posix_io_exit NAME KIND` — `KIND` is `plain`,
  `help`, or `unknown`. Print the numeric status on
  stdout.

There is **no** `posix_io_unbuffered_stderr`. The
wait-test lives in the oracle.

`test_posix_io NAME` is the runner hook. The oracle
does not call it.

### Docs

Add a section to `docs/TESTING_STRATEGY.md` describing
the five TODO boxes, the four runtime contracts plus
the fixture table, the cat wait-test, the scratch
directory rule, and "when adding a utility, add a
`posix_io_has_fixture` row". Check the five TODO.md
boxes in the same commit as the GREEN implementation.

## Out of scope

- `### 1` fd-mode five-mode matrix (`>>` / `| cat` /
  `> file` / `2>&1 >> file` as fd configurations).
- `### 3` shared TestDir migration.
- `### 5` `main()` writer-setup coverage beyond what
  the cat wait-test already exercises through the
  compiled binary.
- `### 6` dd `conv=`.
- `## Bugs` ls pipe single-column (already one-per-line
  when stdout is not a TTY; that heading is a later
  docs check-off).
- `### 4` du color (blocked on #189).
- `### 6` (Modern Features) progress bars (blocked on
  #177).
- `### 7` smarter errors (#191).
- Changing stdout buffering (keep 8192).
- Changing SIGPIPE default disposition.
- Flushing inside `printErrorWithProgram`.
- Editing `docs/specs/` flag matrices.
- Wiring `src/common/file_ops.zig`.
- Making `echo` / `printf` reject unknown longs.

## Spec impact

No change. This slice does not add or reinterpret a
flag. GNU remains the behavioral reference for exit
codes where a flag exists; POSIX XCU 2.5.1 is the
reference for stderr buffering.

## Tests

Test-writer and implementer are separate agents.

**Required RED on current `main` (right reason):**
the inline cat wait-test. Confirmed 2026-08-21:
`select_ready=False elapsed_s=2.002 still_running=True
stderr_bytes=b''` then `exit_after_stdin_close=1`.

**Coverage RED:** missing `tests/lib/posix_io.sh` /
empty fixture table. Distinct from the wait-test.
Must not be the only RED.

**Expected GREEN on current `main` (characterization):**
append, closed-pipe `yes` terminates, exit-code table.
Prove exit-table teeth by sabotaging one expected
code in the oracle, then revert. Never commit
sabotage. Do not sabotage append via `.writer()`.

Do not skip a failing wait-test. Do not weaken it to
"stderr appears after exit".

## Risks

- **Filter-stdin hangs.** Fixtures use `--help` or the
  locked rows; stdin is `/dev/null` except the cat
  wait-test, which holds stdin open on purpose and
  closes it before the 2s wait bound.
- **Leftover-file scans.** Scratch dir and dest names
  must not contain a utility name. Always `rm -rf` on
  EXIT.
- **`src/common/` boundary.** `main.zig` plus a small
  helper/lint in `lib.zig`, and `env.zig`'s custom
  main. Do not touch `file_ops.zig`.
- **Tiger Style.** `utilityMain` stays well under 70
  lines. Zero-length buffer is the documented
  unbuffered shape.
- **`NO_COLOR`.** Prefix per spawn. The cat wait-test
  must set `NO_COLOR=1` so the diagnostic is plain
  bytes.
- **Race vs `promptYesNo` flush.** Do not substitute
  `rm -i`.
- **Python 3.** Already used by `run_with_limit`.
  Present on Ubuntu and macOS CI images.
- **Partial stderr reads.** Accumulate until marker
  or deadline.

## TDD sequence

1. Plan consensus (this file, after round-2 review).
2. Test-writer: oracle including the inline cat
   wait-test. No production Zig. No harness bodies
   that make the wait-test pass.
3. Prove RED: `bash tests/tools/posix_io_test.sh`
   fails because `select` timed out while cat was
   still running (right reason). Coverage may also
   fail; that is extra, not instead.
4. Implementer: helper + unbuffer + source lint,
   harness, `test_runner.sh` hook, docs, TODO,
   CHANGELOG. Do not edit the oracle's assertions
   or the wait-test Python.
5. Prove GREEN: `bash tests/tools/posix_io_test.sh`
   (wait-test now sees `posix-io-missing` while cat
   is blocked), `just fmt-check`, `zig build test`
   (lint + `main.zig` unit tests), `just it-util cat`,
   `just it-util echo`, `just it-util yes`,
   `just it-util true`, `just it-util false`,
   `just it-util '['`, `just it-util env`,
   then `env -u NO_COLOR just it`.
