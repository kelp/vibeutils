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
`tests/lib/test_runner.sh`. `run_utility_tests` calls
`test_fd_modes "$util"` for every utility `just it` /
`just it-util` already visits, **before** the per-utility
`*_test.sh`. PATH stays pinned to `zig-out/bin` (issue
#167 / `tests/integration.sh`).

A coverage oracle `tests/tools/fd_modes_test.sh` parses
`build/utils.zig` `utilities` names and fails if any name
lacks a fixture. `just test-run-integration` stays
untouched; wire the oracle through a new `just` recipe
`test-fd-modes` **and** call it from the existing
integration path so CI (`just it`) cannot skip it. Prefer
one call site: `run_all_utility_tests` already walks every
built binary, so per-util `test_fd_modes` plus the oracle
is enough. Do not add `tests/utilities/fd_modes_test.sh`
(the runner would look for a `fd_modes` binary).

### Fixtures

Every `build/utils.zig` name has an explicit argv + stdin
recipe. Missing fixture is a FAIL, not a skip.

Default template (overridden per util when needed):

- stdin: `/dev/null` (never the runner TTY)
- argv: a **bounded** invocation that returns without a
  prompt
- wrap every spawn in `run_with_limit` (macOS has no GNU
  `timeout(1)`)
- non-zero exit is allowed; fd assertions are about the
  file/pipe, not POSIX exit codes (`### 2` owns those)

Locked exceptions:

| util | argv | stdin | why |
| --- | --- | --- | --- |
| `echo` | `echo fd-mode` | `/dev/null` | known payload; matches issue #5 |
| `true` / `false` | no extra args | `/dev/null` | POSIX ignores args; stdout empty |
| `test` | `test -n x` | `/dev/null` | `--help` is an expression |
| `[` | `[ -n x ]` | `/dev/null` | same; trailing `]` required |
| `yes` | `yes --help` | `/dev/null` | `--help` exits; never unbounded `yes` |
| `sleep` | `sleep 0` | `/dev/null` | no delay |
| `cat`/`tee`/`sort`/other filters | file operand **or** `--help` if that path uses the same `utilityMain` stdout writer | `/dev/null` when using `--help`; otherwise a here-string closed after one write | never block on stdin |
| `rm`/`cp`/`mv` | `--help` | `/dev/null` | avoid prompts; `--help` still flushes `utilityMain` stdout |
| `dd` | `dd --help` | `/dev/null` | avoid copying forever |
| `env` | `env true` | `/dev/null` | bounded child |
| `timeout` | `timeout 0.1 true` | `/dev/null` | bounded child |

`--help` is allowed only because every utility that
parses it prints through `common.utilityMain`'s
`writerStreaming` stdout, which is the issue #5 path.
Do not use `--help` for `test` / `[`. Do not use
`yes` without `--help` or a limit.

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
   `run_with_limit … util args | cat` must finish (not
   124) and stdout must equal a direct capture of the
   same argv. Stdin still `/dev/null` or the fixture
   here-string. This is "stdout is a pipe", not "the util
   is the right-hand side of a pipe".

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
`NO_COLOR=1` for the harness so color cannot leak into
byte compares. `env -u NO_COLOR` is not required here.

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
3. **Sabotage (uncommitted):** temporarily change
   `utilityMain` stdout to `writer(` instead of
   `writerStreaming(`, run the echo append case, confirm
   RED (marker overwritten), revert, confirm GREEN.
   Same for stderr on `>> file 2>&1` if a util writes
   stderr (or `ls` of a missing path). Never commit the
   mutation.

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
- CI time: ~50 utils × 5 spawns; keep limits ≤ 2s;
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
