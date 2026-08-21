# Slice: main() Function Coverage

## Slice name

`### 5. main() Function Coverage`

One heading, one PR. Nested boxes under that heading
belong here. Do not pull `### 6` dd `conv=`, `### 1`
fd-mode, `### 2` POSIX I/O, `### 3` TestDir, `## Bugs`
(`ls` pipe columns), leftover `du` color, or progress
feedback.

## Predecessor gate (recorded deviation)

Listed Testing Improvements order would wait for `### 3`
(PR #194) to land on `main`. This environment cannot
merge. Branch from `github/main` (`a41eccd`).

`TODO.md` / `CHANGELOG.md` will conflict with stacked
slices; rebase after predecessors land. Do **not** stack
on #192/#193/#194, and do **not** source or copy
`tests/lib/fd_modes.sh` or `tests/lib/posix_io.sh`.

`### 1` already owns the per-binary `>>` / pipe /
truncate / dup matrix. This slice is the missing
**writer-setup** coverage: 8KB `writerStreaming` buffers
and the flush-before-exit that `runUtil()` tests never
see because they inject `Allocating` writers.

## Classification

Test coverage of existing I/O initialization. Issue #5
(`writer` vs `writerStreaming`) is already fixed in
`src/common/main.zig` and already linted in
`src/common/lib.zig`. This slice does not change
user-visible behavior, flags, or man pages. No
`CHANGELOG` bullet.

## In scope

The two TODO boxes:

1. Test the writer setup code path in `main()`, not
   just `runUtil()` with test-provided writers.
2. Integration tests that exercise the compiled
   binary's actual I/O initialization.

### Why `runWithBufferedIO` is not enough

`runWithBufferedIO` is the testable inner loop of
`utilityMain`, but it takes caller-supplied writers and
never constructs the 8KB `writerStreaming` buffers or
flushes them. Unit tests of `runEcho` / `runLs` do the
same. A regression that drops `stdout.flush()` (or
shrinks the buffer and forgets to flush the tail) is
invisible to those tests.

### Box 1 — Zig: extract a File-backed setup path

Extract `runWithStreamingFiles` from `utilityMain` in
`src/common/main.zig`:

- Same `runFn` contract as `utilityMain`.
- Takes explicit `stdout_file` / `stderr_file`
  (`std.Io.File`), not process-global stdout.
- `args[0]` is the program name; strip it the same way
  `utilityMain` does (`args[1..]`). Assert `args.len >= 1`.
- Allocates `[8192]u8` stdout and stderr buffers.
- Wraps each file with `writerStreaming`.
- Calls `runFn`. On `runFn` error, print to stderr,
  `stderr.flush()`, return 1. Do **not** flush
  stdout on that branch — today's `utilityMain`
  `catch` calls `process.exit(1)` before the success-
  path `stdout.flush()`.
- On success, `stdout.flush()` and `stderr.flush()`,
  then return the exit code.
- Does **not** call `std.process.exit`.
- Two asserts: buffer len `== 8192`, and
  `stdout_buffer.len == stderr_buffer.len`.

`utilityMain` becomes: parse argv, call
`runWithStreamingFiles` with `File.stdout()` /
`File.stderr()`, then `process.exit`. It is a
modified function. Three separate asserts (do not
compound them): `args.len >= 1`, stdout handle
`>= 0`, stderr handle `>= 0`. Do **not** assert
`args[0].len > 0` — empty `argv[0]` is legal and
must not trap in debug. Keep `runWithBufferedIO`
unchanged for Allocating-writer tests. Function
bodies stay ≤ 70 lines.

`env` keeps its own `main()` (`environ_map`). Do not
rewrite env onto `utilityMain`. Do not duplicate the
extract into env.

### Box 2 — Shell: compiled-binary I/O init

New `tests/tools/main_io_test.sh`. Invoke it once from
`tests/integration.sh` on the all-utilities path, next
to `help_consistency_checks.sh` (the existing
cross-cutting hook). Do not add
`tests/utilities/main_io_test.sh` (there is no
`main_io` binary; the runner would skip it).

Export `test_main_io` as the entry function. Missing
file is FAIL, not a skip. Fold its `print_test_summary`
status into `overall_result`. The sourced file must
`return`, never `exit`, so a failure cannot abort the
rest of `just it`.

PATH stays pinned to `zig-out/bin`. Spawn
`"$BIN_DIR/echo"` / `"$BIN_DIR/pwd"` / `"$BIN_DIR/env"`,
never the unqualified names. Wrap every spawn in
`run_with_limit`. Stdin is `/dev/null`.

Locked cases:

| case | binary | what it pins |
| --- | --- | --- |
| short stdout | `echo hi` | payload `< 8192` survives process exit (flush) |
| long stdout | `echo` of 9000 bytes | full payload, including the tail after a full 8KB buffer |
| stderr flush | `pwd --not-a-flag` | exit non-zero; stderr contains `unrecognized option` |
| custom main | `env --help` | env's own 8KB `writerStreaming` + flush, not `utilityMain` |

Do **not** use `echo --not-a-flag`. GNU and vibeutils
`echo` treat unknown tokens as operands; `runEcho`
never writes `stderr_writer`, so that case cannot pin
flush. `pwd` uses `utilityMain` and prints
`unrecognized option` on stderr.

Do not iterate all 48 binaries. That matrix is `### 1`.

## Review revision (round 2)

Round 1 (Grok + Bugbot): `echo --not-a-flag` cannot
pin stderr flush. Replaced with `pwd --not-a-flag`.
Hook is `tests/integration.sh` beside help-consistency.

Round 2 (Grok, Sol, Fable all REQUEST CHANGES):

1. **TDD is characterization, not compile-error RED.**
   This is a behavior-preserving coverage refactor
   (`tdd` skill). Test-writer's first commit must
   compile and GREEN on current `utilityMain`. Prove
   teeth by uncommitted flush sabotage through
   `just it`, then extract. An absent-symbol compile
   failure is not teeth.
2. **Test-writer owns the hook.** Implementer does
   not decide whether the suite runs. Test-writer
   adds the `tests/integration.sh` source +
   `test_main_io` call and folds `print_test_summary`
   into `overall_result`. Missing file is FAIL.
   Prove a failing case makes `just it` non-zero.
3. **Uncaught-error path does not flush stdout.**
   Match today's `catch` + `process.exit(1)`.
4. **Tiger:** every new or modified function has two
   asserts, including the slimmed `utilityMain`.
5. **Stderr sabotage** is its own uncommitted proof
   (omit `stderr.flush()`; `pwd --not-a-flag` loses
   the diagnostic).

Round 3 (Sol still REQUEST CHANGES; Grok+Fable
APPROVE):

6. **No `args[0].len > 0`.** Empty argv[0] is
   legal. `utilityMain` has three separate
   asserts: `args.len >= 1`, stdout handle
   `>= 0`, stderr handle `>= 0`. Do not
   compound the two handle checks.
7. **Source-scan cannot live in `main.zig`.**
   Needles in the test strings would self-satisfy.
   Scan production `main.zig` from `lib.zig` / a
   sibling lint, skipping tests/comments/strings.
8. **Catch-branch assertions** are locked for the
   follow-up Zig tests (exit 1, stderr persisted,
   stdout not flushed). `pwd --not-a-flag` is not
   that branch. Prove those tests RED after they
   exist.
9. **TODO boxes** are checked in the implementer
   commit, not in the same commit as the hook.
   Docs below match that.

Round 4 (Sol still REQUEST CHANGES; Grok+Fable
APPROVE round 3):

10. **Scanner RED** is `zig build test` plus
    decoy fixtures, not `just it`.
11. **Catch-path RED** is three separate
    mutations (exit code, stderr flush, stdout
    non-flush), not one "or".
12. **Split compound asserts** on the two
    file handles.

## Tests

TDD split (test-writer ≠ implementer).

### Test-writer (commit 1, compiles, GREEN)

- `tests/tools/main_io_test.sh` with the four locked
  cases. `pwd --not-a-flag` asserts non-zero exit
  and that stderr contains `unrecognized option`.
- Hook in `tests/integration.sh` (all-utilities
  path only). Own this file. Do not leave the hook
  for the implementer.
- Zig source-scan in a file that is **not**
  `src/common/main.zig` (put it in `src/common/lib.zig`
  next to the issue #5 `writer(` lint, or a tiny
  `main_io_lint.zig` force-imported from `lib.zig`).
  Scan production `main.zig` only: skip `test "`
  bodies, comments, and string literals so the scan
  cannot self-satisfy. Needles: `[8192]u8`,
  `writerStreaming`, `stdout.flush()`,
  `stderr.flush()`. GREEN on current `utilityMain`.
  After the extract those needles still live in
  production `runWithStreamingFiles`.

  Scanner RED proof is `zig build test`, not
  `just it`. Test-writer ships fixture coverage
  (a decoy comment/string/test-body needle must
  not fire; a production needle missing must
  fire). Uncommitted sabotage: delete one
  production needle from `utilityMain` and
  confirm `zig build test` fails for that
  needle, then revert.

Do **not** call `runWithStreamingFiles` in this
commit — the symbol does not exist yet, and a
compile failure is not the RED.

Uncommitted sabotage (mandatory, Linux and macOS):

- Omit `stdout.flush()` in `utilityMain` → `echo hi`
  writes nothing; `just it` fails.
- Omit `stderr.flush()` on the success path →
  `pwd --not-a-flag` stderr is empty; `just it`
  fails.
- Omit env's `stdout.flush()` → `env --help` is
  empty; `just it` fails. `utilityMain` sabotage
  must not RED env.

Revert every sabotage. Never commit it.

### Implementer (commit 2)

Extract `runWithStreamingFiles`, point `utilityMain`
at it, keep both functions within Tiger caps.
`utilityMain` has three split asserts; the extract
keeps its buffer asserts plus `args.len >= 1`. Check the two TODO boxes **in this
commit** (the extract is what completes the slice;
the hook landed earlier still unchecked). Add the
`TESTING_STRATEGY.md` note. Does not edit the shell
assertions, the Zig scan, or the integration.sh
hook.

File-backed Zig tests that *call*
`runWithStreamingFiles` are a **test-writer
follow-up** after the symbol exists. They are not
the first RED. Locked assertions for that
follow-up:

- short write: file contains the payload (flush)
- write `> 8192`: full payload including the tail
- uncaught `runFn` error: exit code `1`, stderr
  file contains the diagnostic (flushed), stdout
  file does **not** contain a pending short write
  (this path must not flush stdout)

`pwd --not-a-flag` is the success-path stderr
flush (runFn returns 1). It does **not** cover
the `catch` branch; the follow-up Zig uncaught-
error test does. After those tests exist, prove
them RED with **three separate** uncommitted
mutations, then revert each:

- return 0 from the catch path → exit-code
  assertion fails
- omit `stderr.flush()` on the catch path →
  stderr file empty
- add `stdout.flush()` on the catch path →
  pending stdout appears in the file

One mutation covering only one of the three
assertions is not enough.

Existing `lib.zig` issue #5 `writer(` lint stays. Do
not treat that grep as this slice. Existing
`echo_test.sh` issue #5 `>>` case stays.

## Out of scope

- Per-utility `>>` / pipe / truncate / dup (`### 1`)
- POSIX exit-code / SIGPIPE / unbuffered stderr (`### 2`)
- `testing.tmpDir` migration (`### 3`)
- dd `conv=` (`### 6`)
- Rewiring `env` onto `utilityMain`
- Production behavior, flags, man pages
- `build.zig`

## Spec impact

None. No `docs/specs/` edit.

## Risks

- Filter stdin hangs: locked cases use `/dev/null`.
- `yes` is unbounded: not a representative.
- `run_with_limit`, not GNU `timeout` (macOS CI).
- Root: `scripts/run-integration.sh` already demotes.
- `src/common/` boundary: extract stays in
  `main.zig`; do not grow `lib.zig`.
- Tiger Style: every new or modified function ≤ 70
  lines. Split compound asserts. `utilityMain`
  has three asserts (argv length, each handle).
  `runWithStreamingFiles` keeps buffer-len 8192
  and stdout/stderr lens equal as two asserts,
  plus `args.len >= 1`.
- `TestDir` on github/main is the pre-#194 API
  (`getPath`, no `join` / `chdirToBase` required
  here). Tests create files via `createFile` / open
  the sandbox file handle.
- Flush sabotage of `utilityMain` does not RED env;
  env is a separate case.

## Docs

One short section in `docs/TESTING_STRATEGY.md` under
File System Testing / a new "main() I/O init" note:
unit tests of `runUtil` do not cover writer setup;
`runWithStreamingFiles` and `tests/tools/main_io_test.sh`
do. Check both TODO boxes in the implementer
commit (the extract), not in the test-writer hook
commit.
