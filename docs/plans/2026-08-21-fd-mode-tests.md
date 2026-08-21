# Slice: file descriptor mode tests

## Slice name

`### 1. File Descriptor Mode Tests`

One heading, one PR. Nested boxes under that heading
belong here. Do not pull `### 2. POSIX Behavioral
Conformance Suite` (SIGPIPE, unbuffered stderr, POSIX
exit-code matrix), `### 3` TestDir, `### 5` main()
coverage, `### 6` dd `conv=`, `## Bugs`, or any Modern
Features heading.

## Predecessor gate (recorded deviation)

Listed Modern Features order still has open predecessors
this environment cannot merge:

- `### 4` leftover `du` color waits on PR #189 (`src/du.zig`)
- `### 6` progress waits on PR #177 (`src/dd.zig`)
- `### 7` smarter errors is PR #191

This heading is the first unblocked slice after those.
Branch from `github/main` (`a41eccd`). `TODO.md` /
`CHANGELOG.md` will conflict with stacked slices; rebase
after predecessors land. Do not stack on #177, #189, or
#191.

## Classification

Test infrastructure only. No production Zig, no flags, no
man pages, no user-visible CHANGELOG bullet. The O_APPEND
writer bug (issue #5) is already fixed in
`src/common/main.zig` (`writerStreaming`). This slice is
the missing **runtime** matrix that would have caught it
on every binary, not just `echo` and a source grep.

`src/common/lib.zig` already scans for `.stdout().writer(`
/ `.stderr().writer(`. Keep that lint. Do not treat the
grep as this slice.

## In scope

The five TODO boxes:

1. Generic harness that runs each binary under different
   fd configurations.
2. `>> file` append mode for every utility.
3. Pipe mode (`| cat`) for every utility.
4. Truncate mode (`> file`) for every utility.
5. Dup'd descriptors (`2>&1 >> file`) for every utility.

### Harness

New `tests/lib/fd_modes.sh`, sourced from
`tests/lib/test_runner.sh`. After `init_test_session`
(so `$TEMP_DIR` exists), `run_utility_tests` calls
`test_fd_modes "$util"` for every utility `just it` /
`just it-util` already visits, **before** the per-utility
`*_test.sh`. PATH stays pinned to `zig-out/bin` (issue
#167 / `tests/integration.sh`).

A coverage oracle `tests/tools/fd_modes_test.sh` parses
`build/utils.zig` `utilities` names (48 entries, including
`[`) and fails if any name lacks a fixture. Invoke the
oracle once from `run_all_utility_tests` (the `just it`
path CI actually runs). A `just test-fd-modes` recipe may
exist for local iteration; it is not a substitute for the
`just it` hook. Do not add
`tests/utilities/fd_modes_test.sh` (the runner would look
for a `fd_modes` binary).

`tests/lib/common.sh` enables `set -euo pipefail`.
Capture every spawn status (`set +e` around the command,
as `test_command_output_exact` does). `false` exiting 1
is success for fd assertions. `run_with_limit` returning
124 is FAIL. For pipe mode, do not let `| cat` hide the
left-hand status: run under `pipefail` and inspect
`PIPESTATUS[0]` so a 124 is visible.

### Fixtures

Every `build/utils.zig` name has an explicit argv + stdin
recipe. Missing fixture is a FAIL, not a skip.

Default argv is `--help` with stdin `/dev/null`, except
the locked rows below. `--help` is bounded, prompt-free,
and for utilities that use `common.utilityMain` it writes
through the issue #5 `writerStreaming` stdout. `env` has
its **own** `main()` (`src/env.zig`); it still uses
`writerStreaming`, so its fixture must write through
*env's* writers, not a child.

Every spawn: `run_with_limit` (macOS has no GNU
`timeout(1)`). Non-zero exit is allowed; fd assertions
are about the file/pipe, not POSIX exit codes (`### 2`
owns those). Run directory utilities against `$TEMP_DIR`
(or `cd "$TEMP_DIR"`) so `ls`/`find`/`du` do not walk the
repo.

Locked exceptions:

| util | argv | stdin | why |
| --- | --- | --- | --- |
| `echo` | `echo fd-mode` | `/dev/null` | known payload; issue #5 oracle |
| `true` / `false` | no extra args | `/dev/null` | POSIX ignores args; stdout empty |
| `test` | `test -n x` | `/dev/null` | `--help` is an expression |
| `[` | `[ -n x ]` | `/dev/null` | same; trailing `]` required |
| `yes` | `yes --help` | `/dev/null` | `--help` exits; never unbounded `yes` |
| `sleep` | `sleep 0` | `/dev/null` | no delay |
| `env` | `env --help` | `/dev/null` | env's own writers, not `env true` |
| `timeout` | `timeout --help` | `/dev/null` | timeout's own writers, not a child |
| `date` / `mktemp` / `free` / `df` | `--help` | `/dev/null` | deterministic; no `/tmp` files |
| `ls` / `find` / `du` | `--help` | `/dev/null` | do not list the repo |
| `cat` / `tee` / `sort` / `head` / `tail` / `wc` / `grep` / `nl` / `tac` / `uniq` / `cut` / `tr` | `--help` | `/dev/null` | filters; never block on stdin |

`true` writes 0 bytes, so it cannot catch seek-to-0
overwrite; the echo payload plus sabotage stays
mandatory. Do not use `--help` for `test` / `[`. Do not
use `yes` without `--help` or a limit.

### The four modes

Seed marker is the exact bytes `EXISTING\n` (no more, no
less). Work in `$TEMP_DIR`.

1. **Append (`>> file`)**
   Write the seed, run the fixture `>> file`, assert the
   file **starts with** `EXISTING\n`. If the util wrote N
   stdout bytes, the file is seed + those bytes. Empty
   stdout leaves the file equal to the seed. This is the
   issue #5 assertion: positional `writer()` seeks to 0
   and overwrites the marker.

2. **Pipe (`| cat`)**
   `run_with_limit … util args | cat` must finish and
   stdout must equal a direct capture of the same argv.
   Fail if `PIPESTATUS[0]` is 124. Stdin still
   `/dev/null`. This is "stdout is a pipe", not "the util
   is the right-hand side of a pipe". Fixtures are
   `--help` or the locked rows, so pipe/truncate compares
   stay deterministic.

3. **Truncate (`> file`)**
   Run the fixture `> file` twice. After the second run,
   file contents equal one run, not the concatenation of
   two. Empty stdout → empty file.

4. **Dup'd (`2>&1 >> file`)**
   Exact shell shape from the TODO: `util args 2>&1 >> file`
   with the seed pre-written. Meaning:
   - fd 1 appends to `file` (marker survives)
   - fd 2 is a dup of the **original** stdout (the test's
     capture), so stderr is **not** in `file` unless the
     util writes that text to stdout
   Also run `util args >> file 2>&1` as a second dup
   case: both streams append; marker still survives.
   Issue #5 on stderr used the same `writer()` footgun.

Do not assert TTY layout, color, or column padding.
Prefix **each spawn** with `NO_COLOR=1`. Do **not**
`export NO_COLOR=1` from the sourced harness — that
poisons later `*_test.sh` in the same `just it` process
(AGENTS.md: ambient `NO_COLOR` fails `ls truecolor icons`
even with `--color=always`). `env -u NO_COLOR` is not
required for these four modes (stdout is already a
file/pipe).

## Out of scope

- `### 2` SIGPIPE/EPIPE, unbuffered stderr, POSIX exit
  codes, "utility-agnostic I/O contract" as a second
  suite
- `### 3` migrating `testing.tmpDir` to `TestDir`
- `### 5` extra `main()` coverage beyond what these
  binary spawns already hit (`utilityMain`)
- `### 6` dd `conv=`
- Production writer changes unless sabotage proof (never
  commit sabotage)
- New flags, man pages, CHANGELOG user-facing bullets

## Spec impact

None. No `docs/specs/` edit.

## Tests

TDD split (test-writer ≠ implementer):

1. **Test-writer** adds `tests/tools/fd_modes_test.sh`:
   coverage oracle (every `utilities` name has a fixture)
   and contract tests of the four modes using `echo` and
   `true` as oracles. Proven RED: the oracle fails while
   the fixture table is empty / the library is missing.
2. **Implementer** adds `tests/lib/fd_modes.sh`, the
   per-util table, and the `run_utility_tests` hook.
   Does not edit the oracle's assertions.
3. **Sabotage (uncommitted, mandatory):**
   Issue #5 is macOS-specific: `File.writer()` uses
   `pwritev` at offset 0 and ignores `O_APPEND`. On
   Linux, `writer()` still appends, so mutating
   `utilityMain` to `writer(` **will not** go RED here
   or on ubuntu CI. Do not treat that mutation as the
   Linux proof.

   Linux-capable teeth (this agent, ubuntu CI):

   - Coverage oracle: empty fixture table → RED.
   - Append assertion: point the harness at a
     known-bad command that `lseek(0)` then writes
     over the seed (a one-off Python snippet, never
     committed). Confirm RED (file no longer starts
     with `EXISTING\n`). Point it at real `echo
     fd-mode` → GREEN.
   - Stderr dual-append: same seek-0 overwrite on a
     command that writes stderr, for `>> file 2>&1`.

   macOS (CI `macos-26`, optional locally): also
   temporarily change `utilityMain` stdout/stderr to
   `writer(`, run echo / `ls` missing-path, confirm
   RED, revert. Never commit the mutation. `env`
   sabotage is its own `main()`; out of scope unless
   env is the oracle.

Existing `echo_test.sh` issue #5 case stays. Do not
delete it.

## Risks

- Filter stdin hangs: fixtures must close stdin;
  `run_with_limit` is the backstop (124 = FAIL).
- `yes` without `--help` is unbounded: locked above.
- Interactive prompts: `--help` / `-f` / no TTY stdin.
- Root: `scripts/run-integration.sh` already demotes;
  do not add a second demote.
- macOS: `run_with_limit`, not GNU `timeout`.
- `[` binary name and `test_[` function naming already
  special-cased in `test_runner.sh`; fixtures must use
  `$BIN_DIR/[`.
- CI time: 48 utils × 5 spawns; keep limits ≤ 2s;
  `sleep 0` / `yes --help` keep it small.
- `src/common/` boundaries: no Zig change.
- Tiger Style: shell only; `scripts/tiger-check.sh`
  new=0; do not grow Zig functions.

## Docs

One short section in `docs/TESTING_STRATEGY.md` pointing
at `tests/lib/fd_modes.sh` and the fixture table, so a
new utility cannot land without a fixture (the oracle
enforces that; the doc says why). Check the five TODO
boxes in the same commit as the harness.
