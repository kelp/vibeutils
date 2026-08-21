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

## Classification

Mostly test infrastructure. One production behavior
change: **stderr is unbuffered** in `utilityMain` and in
`env`'s custom `main()`. No flags, no man-page flag
tables, no `docs/specs/` edits.

`CHANGELOG.md` gets one user-visible bullet for the
stderr change. `TODO.md` checks the five boxes under
this heading.

## In scope

The five TODO boxes:

1. `>>` must append, not overwrite.
2. Stdout to a closed pipe must produce SIGPIPE/EPIPE.
3. Stderr must be unbuffered.
4. Exit codes conform to POSIX / GNU (this repo's
   `common.ExitCode` doc comment).
5. Utility-agnostic: the same I/O contract tests run
   against every `build/utils.zig` binary.

### Harness

New `tests/lib/posix_io.sh`, sourced from
`tests/lib/test_runner.sh`. After `init_test_session`
(so `$TEMP_DIR` exists), `run_utility_tests` calls
`test_posix_io "$util"` for every utility `just it` /
`just it-util` already visits. PATH stays pinned to
`zig-out/bin` (issue #167).

A coverage oracle `tests/tools/posix_io_test.sh` parses
`build/utils.zig` `utilities` names (48 entries,
including `[`) and fails if any name lacks a fixture.
Invoke the oracle once from `run_all_utility_tests`
(the `just it` path CI actually runs). A
`just test-posix-io` recipe may exist for local
iteration; it is not a substitute for the `just it`
hook. Do **not** add
`tests/utilities/posix_io_test.sh` (the runner would
look for a `posix_io` binary).

`tests/lib/common.sh` enables `set -euo pipefail`.
Capture every spawn status (`set +e` then restore
`set -e`, as `test_command_output_exact` does).
`false` exiting 1 is success for the I/O assertions.
`run_with_limit` returning 124 is FAIL.

Scratch lives under `$TEMP_DIR/posix_io_scratch`. That
directory name must **not** contain a utility name.
`dirname_test.sh` / `pwd_test.sh` / `touch_test.sh` /
`rm_test.sh` / `wc_test.sh` fail when leftover
`$TEMP_DIR` files matching `*<util>*` exceed a
threshold. `rm -rf` the scratch at the end of
`test_posix_io`.

Python 3 is already required by `run_with_limit` and
`run_with_stderr_tty`. Use it for the closed-pipe and
unbuffered-stderr probes. Do not add a C helper.

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
| `yes` | `yes --help` for append / exit-help; unbounded `yes` only for the closed-pipe probe | `--help` exits; never hang the suite |
| `env` | `env --help` | env's own `main()`, not a child |
| `timeout` | `timeout --help` | timeout's own writers, not a child |
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
lands it. Prove teeth by transient sabotage: switch
one stdout setup back to `.writer()` (positional),
confirm RED, revert. Never commit the sabotage.

### Contract 2 — closed pipe → SIGPIPE / EPIPE

Python helper: `pipe()`, `os.close(read_end)`,
`dup2(write_end, 1)`, `execv` the fixture. The read
end is already closed **before** exec, so this is not
the racy `cmd | true` shape.

Wrap with `run_with_limit 2`. 124 is FAIL (hang).

PASS if the process terminates and the wait status is
any of:

- signaled `SIGPIPE` (parent sees 141 = 128+13, or
  `WIFSIGNALED` / `WTERMSIG == 13`)
- exited 0 or 1 after catching `error.BrokenPipe`
  (Zig `utilityMain` does `stdout.flush() catch {}`;
  `yes` catches BrokenPipe and exits 0)

FAIL: hang, or any other signal.

`--help` fixtures write less than the 8KB stdout
buffer, so the kernel may only see EPIPE at the final
flush. That is still "produce EPIPE". The tooth is
**unbounded `yes`**: it writes more than the buffer
and must terminate on a closed stdout rather than
run until the limit.

`true` writes 0 bytes, so the closed-pipe probe is
vacuous (exits 0 without a write). That is allowed.

Do not change SIGPIPE disposition. Do not make
utilities `_exit` on EPIPE if they already catch
BrokenPipe and return 0. GNU `yes` dies 141; vibeutils
`yes` already exits 0; keep that. This contract is
"the write observes the closed pipe", not "die with
141".

### Contract 3 — stderr is unbuffered

POSIX XCU 2.5.1: stderr is not fully buffered.
Zig `std.Io.Writer` documents that a zero-length
buffer is unbuffered and `flush` is a no-op.

**Production change.** In `src/common/main.zig`
`utilityMain`, construct stderr with a zero-length
buffer (`&.{}` / `&[0]u8{}`). Leave stdout at 8192.
Drop the assertion that stdout and stderr buffer
lengths are equal; replace it with
`stderr_writer.interface.buffer.len == 0` and
`stdout_buffer.len == 8192`. Update the module
comment (it currently says "8KB buffered
stdout/stderr").

`src/env.zig` has its own `main()` and its own 8192
stderr buffer. Change that stderr setup the same way.
Do not chase every other file: every remaining
utility already calls `common.utilityMain`.

Do **not** flush inside `printErrorWithProgram`. The
unbuffered writer makes each print a syscall. Adding
a flush there would make a still-buffered stderr pass
the wait-test and hide a regression.

**Behavioral lock (the RED expected on current
main).** `printErrorWithProgram` does not flush.
`cat MISSING -` reports the missing operand, then
reads stdin for `-`. Python:

1. Hold stdin open (pipe, keep the write end).
2. Put stderr on a pipe.
3. Spawn `$BIN_DIR/cat posix-io-missing -` with
   `NO_COLOR=1`.
4. `select` on the stderr pipe for 2 seconds **without
   waiting for exit**.
5. PASS only if bytes arrive and contain
   `posix-io-missing`, **and** `poll()` is still
   `None` (the process is blocked on stdin).
6. Then close stdin and wait.

An 8KB fully-buffered stderr keeps those ~40 bytes
in userspace until `utilityMain` flushes at exit, so
`select` times out while cat is still running. That
is this slice's required RED.

This wait-test is **one** representative (`cat`), not
48, because most utilities exit after writing stderr
and the final flush would hide buffering. The
utility-agnostic box is the other four contracts plus
the fixture table. Document that in
`docs/TESTING_STRATEGY.md`.

Do not use `rm -i` as the wait-test: `promptYesNo`
already flushes, so a buffered stderr would still
pass.

### Contract 4 — exit codes

This is the I/O-contract matrix, not a per-utility
POSIX encyclopedia. Locked rows:

| spawn | expected |
| --- | --- |
| `true` (no args) | 0 |
| `false` (no args) | 1 |
| `$name --help` for every name except `true`, `false`, `test`, `[` | 0 |
| `test --help` | 0 (`test STRING` is true) |
| `[ --help` | 2 (missing `]`) |
| `$name --posix-io-no-such-flag` default | 1 |
| `true --posix-io-no-such-flag` | 0 (POSIX ignores args) |
| `false --posix-io-no-such-flag` | 1 (POSIX ignores args, still fails) |
| `test --posix-io-no-such-flag` | 0 (nonempty STRING) |
| `[ --posix-io-no-such-flag ]` | 0 (nonempty STRING) |
| `grep --posix-io-no-such-flag` | 2 (`ExitCode.serious_error`) |
| `ls --posix-io-no-such-flag` | 2 |
| `sort --posix-io-no-such-flag` | 2 |
| `env --posix-io-no-such-flag` | 125 (`ExitCode.internal_error`) |
| `timeout --posix-io-no-such-flag` | 125 |

Do not reintroduce exit 2 as a generic "misuse" code.
Do not test every operand-missing path; those live in
per-utility suites.

On current `main` this contract is expected GREEN.
Prove teeth by transient sabotage of one expected
code in the oracle, confirm RED, revert.

### Contract 5 — coverage oracle

`tests/tools/posix_io_test.sh` (test-writer owns this
file; implementer does not edit its assertions):

- Parse 48 `.name = "..."` entries including `[`.
- Source `tests/lib/posix_io.sh` or FAIL.
- Require `posix_io_has_fixture NAME` for every parsed
  name.
- Call implementer API (below) for echo/true append,
  yes closed-pipe, cat unbuffered wait, and the exit
  table for `true`/`false`/`echo`.
- `MIN_ASSERTIONS` high enough that an empty harness
  cannot tally green.

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
- `posix_io_unbuffered_stderr` — the `cat` wait-test.
  Return 0 on PASS (bytes visible while still
  running).
- `posix_io_exit NAME` — run the exit-code spawn for
  NAME; print the numeric status on stdout.

`test_posix_io NAME` is the runner hook. The oracle
does not call it.

### Docs

Add a section to `docs/TESTING_STRATEGY.md` describing
the four contracts, the cat wait-test, the scratch
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

## Spec impact

No change. This slice does not add or reinterpret a
flag. GNU remains the behavioral reference for exit
codes where a flag exists; POSIX XCU 2.5.1 is the
reference for stderr buffering.

## Tests

Test-writer and implementer are separate agents.

**Expected RED on current `main`:** the cat
unbuffered-stderr wait-test. That is the feature.

**Expected GREEN on current `main` (characterization):**
append, closed-pipe (yes terminates), exit-code table.
Prove red-ability by transient sabotage, then revert.
Never commit sabotage.

Do not skip a failing wait-test. Do not weaken it to
"stderr appears after exit".

## Risks

- **Filter-stdin hangs.** Fixtures use `--help` or the
  locked rows; stdin is `/dev/null` except the cat
  wait-test, which holds stdin open on purpose and
  closes it before the 2s limit.
- **Leftover-file scans.** Scratch dir name must not
  contain a utility name.
- **macOS `realpath` / chmod.** This slice does not
  chmod 000 files.
- **`src/common/` boundary.** Only `main.zig` (and
  `env.zig`'s custom main) change. Do not touch
  `file_ops.zig`.
- **Tiger Style.** `utilityMain` stays well under 70
  lines. Zero-length buffer is the documented
  unbuffered shape; do not invent a flush-every-write
  wrapper.
- **`env` custom main.** Forgetting it leaves one
  binary fully-buffered. Change it in the GREEN
  commit.
- **`NO_COLOR`.** Prefix per spawn. The cat wait-test
  must set `NO_COLOR=1` so the diagnostic is plain
  bytes.
- **Race vs `promptYesNo` flush.** Do not substitute
  `rm -i`.
- **Python 3.** Already used by `run_with_limit`.
  Present on Ubuntu and macOS CI images.

## TDD sequence

1. Plan consensus (this file).
2. Test-writer: oracle + API comments + cat wait-test
   assertions. No production Zig. No
   `tests/lib/posix_io.sh` bodies that make the suite
   pass (missing harness is RED).
3. Prove RED: `just test-posix-io` fails on the
   wait-test / missing harness, not on a parse error.
4. Implementer: harness, `utilityMain` + `env` stderr
   unbuffer, `test_runner.sh` hook, `just` recipe,
   TESTING_STRATEGY.md, TODO.md, CHANGELOG.md. Do not
   edit the oracle's assertions.
5. Prove GREEN: `just test-posix-io`,
   `just it-util cat`, `just it-util echo`,
   `just it-util yes`, `just it-util true`,
   `just it-util false`, `just it-util '['`,
   `just fmt-check`, `zig build test -Dtest-util=cat`
   is unnecessary unless Zig in cat.zig changed
   (it should not). `zig build test` covers
   `src/common/main.zig`.
