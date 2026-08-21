# Integration Testing

Shell suites that run the compiled binaries under `zig-out/bin`. Unit
tests live next to the Zig they cover (`src/<util>.zig`); this document
is only the bash side.

There is no `tests/integration/` tree. An earlier draft of this file
described `tests/integration/{lib,utils}/`, `init_framework`, and
`exec_utility`. Those paths and helpers were never merged. Follow the
layout below, not that sketch.

## Layout

```
tests/
├── integration.sh              # Suite driver (not the entry point)
├── lib/
│   ├── common.sh               # Assertions, temp dirs, host-tool isolation
│   ├── test_runner.sh          # Per-utility dispatch
│   └── flag_parser.sh          # Automatic --help flag probes
├── utilities/
│   ├── echo_test.sh            # One file per utility: test_<util>()
│   ├── tee_test.sh
│   └── …
├── tools/                      # Tests for repo shell tooling, not utilities
│   ├── audit-check_test.sh
│   ├── tiger-check_test.sh
│   ├── run-integration_test.sh
│   └── host_path_test.sh
├── fixtures/                   # Shared data (utf8, binary, audit trees)
├── privilege_integration/      # Zig tests for privileged file-ops flows
└── fuzz/                       # Linux-only corpora (`just fuzz <name>`)
```

`tests/utilities/<util>_test.sh` is sourced by `test_runner.sh`, which
already loaded `common.sh`. Do not source a fictional `lib/lib.sh`.
The entry function is `test_<util>` (`test_bracket` for `[`).

## Entry point

**Never run `bash tests/integration.sh` directly.** It is the suite.
It prepends `zig-out/bin` to `PATH` and does no privilege dropping.
As uid 0, roughly two dozen "permission denied" assertions pass for
the wrong reason — root bypasses DAC — and look like product bugs.

Always go through the wrapper:

```
just it                      # all utilities
just it-util tee             # one utility
scripts/run-integration.sh tee
```

`scripts/run-integration.sh`:

1. Drops to `VIBEUTILS_TEST_USER` (default `vibedev`) when the caller
   is root and `setpriv` exists. `VIBEUTILS_NO_DEMOTE=1` skips this.
2. Runs the suite from a private working directory (#125), so two
   concurrent `just it` invocations cannot share relative fixtures.
3. Then execs `tests/integration.sh` with the same arguments.

CI and `just it` both use the wrapper. Workflow prompts that tell an
agent to run `bash tests/integration.sh` must use the wrapper instead
(`.claude/workflows/wave2-walker.js` is the one that previously did
not).

On Cursor Cloud the image exports `NO_COLOR=1`. vibeutils honors that
even over `--color=always`, so color-sensitive cases fail unless the
variable is scrubbed: `env -u NO_COLOR just it`.

## What a utility test looks like

```bash
# tests/utilities/tee_test.sh — sourced; common.sh is already loaded

test_tee() {
    local util="tee"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1
    test_basic_flags "$util"

    test_command_output "tee no files (stdout only)" "simple_data" \
        bash -c "echo 'simple_data' | '$binary'"
}
```

Helpers in `tests/lib/common.sh` (not `assert_equals` / `exec_utility`):

| Helper | Role |
| --- | --- |
| `test_binary_exists` | Fail the suite if `zig-out/bin/<util>` is missing |
| `test_basic_flags` | `--help` / `--version` smoke |
| `test_command_output` | Exact stdout match |
| `test_command_output_exact` | Exact stdout, including no trailing newline |
| `test_command_output_pattern` | Regex on stdout |
| `test_command_exit_code` | Exit status |
| `test_command_succeeds` / `test_command_fails` | Zero / nonzero |
| `print_test_result` | Manual PASS/FAIL/SKIP with a name |
| `run_with_limit SECONDS CMD …` | Bounded run; **never** `timeout(1)` — macOS CI has no GNU timeout |
| `run_with_stderr_tty` | Capture stderr from a PTY (isatty-gated prompts) |
| `create_temp_file` / `create_temp_dir` | Under the session `TEMP_DIR` |
| `host` / `host_resolve` | Host coreutils, not vibeutils, for fixture setup (#167) |

`BIN_DIR` is set by `tests/integration.sh` and exported. PATH is pinned
to `zig-out/bin` so a forgotten `$binary` still tests this build, not
the system one. Fixture setup that needs Darwin `chmod +a` or GNU
`timeout` must go through `host` so it cannot see `zig-out/bin`.

## PATH and the binary under test

A test that resolves the system `ls` / `grep` / `chmod` passes for the
wrong implementation. Use `"$binary"` or an unqualified name only after
the suite prepend. For anything that is *not* the unit under test, use
`host`.

## Filter utilities

`tee`, `cat`, `sort`, `uniq`, and friends block forever on stdin in
Zig unit tests. Integration tests are the place to feed them a pipe.
Keep the pipe finite; `run_with_limit` is the watchdog if a hang is
possible. See `docs/TESTING_STRATEGY.md`, "Filter Utilities and
Stdin-Dependent Testing".

## Tooling tests

Scripts that test the repo's own shell (`audit-check`, `tiger-check`,
`run-integration.sh`, host-PATH wrappers) live in `tests/tools/` and
are invoked from their GitHub workflows, not from `just it`. They are
not per-utility suites.

## Running

```
just build
just it                     # wrapper → all utilities
just it-util cat            # wrapper → one utility
just it-list                # lists tests/utilities/*_test.sh
just stress --concurrent 2 --iterations 20 mkdir
```

`just it-list` calls `tests/integration.sh --list` only to print names;
it does not run the suite. `just test-run-integration` is the contract
suite for the wrapper itself (`tests/tools/run-integration_test.sh`).

There is no `make test-integration`, no `./tests/integration/run.sh`,
and no `INTEGRATION_JOBS` / `INTEGRATION_TIMEOUT` driver. Parallelism
is `just stress --concurrent`, not a job flag on the suite.

## Coverage expectations

Each utility's `tests/utilities/<util>_test.sh` should cover:

1. Primary use, stdin/stdout, and the flags in `docs/specs/<util>-flags.md`
   that are MUST/SHOULD/KEEP (not WONT)
2. Empty input, binary data, and Unicode where the utility handles them
3. Error exits — argument errors are 1 in this tree (not GNU's 2) unless
   that utility's `ExitCode` documents otherwise
4. `--help` / `--version`

Permission-denied cases only have teeth when the wrapper has demoted
away from root.

## Debugging

```
just it-util tee            # one utility, full log
bash -x tests/utilities/tee_test.sh
# does not work: the file is sourced and expects common.sh + BIN_DIR
```

To trace a single file, run the wrapper; it sources the test. Failed
commands print as `Failed command:` next to the assertion. Temp files
live in the session `TEMP_DIR` inside the wrapper's throwaway cwd and
are removed when the run exits.

## See also

- `docs/TOOLCHAIN.md` — demotion, `VIBEUTILS_TEST_USER`, Cloud caveats
- `docs/TESTING_STRATEGY.md` — unit vs integration vs privileged
- `scripts/run-integration.sh` — the actual entry point
