# head Integration Test Audit

**Date:** 2026-03-28
**Auditor:** reviewer agent
**Result:** NEEDS_FIXES

## Test Run

```
Tests run: 76
Passed:    76
Failed:    0
```

All 76 tests pass on the current platform (Linux).

---

## Test Inventory

| Category | Tests | Quality |
|---|---|---|
| Binary / basic flags | 3 | Strong |
| Default behavior (10 lines) | 5 | Strong |
| -n / --lines | 8 | Strong |
| -c / --bytes | 11 | Mixed (2 exit-code-only) |
| -q / --quiet / -v / --verbose | 8 | Strong |
| -q/-v conflict | 2 | Behavioral |
| stdin piping | 5 | Strong |
| Flag combinations | 5 | Strong |
| Error conditions | 9 | Strong |
| POSIX compliance section | 6 | Mostly strong |
| Edge / boundary cases | 12 | Mixed |
| Regression fix | 1 | Behavioral |

---

## Findings

### [IMPORTANT] -z flag has zero integration tests

**Location:** `tests/utilities/head_test.sh` — no `-z` test exists

**Problem:** `-z` (NUL-delimited line mode) is a SHOULD-tier flag per
`docs/specs/head-flags.md`. It is implemented and unit-tested in
`src/head.zig`, but the integration test file never exercises it. The
following behaviors are untested end-to-end:

- NUL-delimited input from stdin (`-z` reads records separated by `\0`,
  not `\n`)
- `-z -n N` file argument path
- `-z -c N` (byte count with NUL mode — expected to behave identically to
  without `-z` since `-c` is byte-based)
- `-z -q` and `-z -v` with multiple files (headers should still use `\n`
  separators per GNU behavior)

**Fix:** Add a stdin pipe test and a file-argument test:

```bash
# -z with NUL-delimited stdin
test_command_output "head -z -n 2 from stdin" \
    $'rec1\x00rec2\x00' \
    bash -c "printf 'rec1\x00rec2\x00rec3\x00' | '$binary' -z -n 2"

# -z with file (NUL records, -n 2 should yield first two NUL-terminated records)
local nul_file=$(mktemp "$TEMP_DIR/nulfile_XXXXXX")
printf 'rec1\x00rec2\x00rec3\x00' > "$nul_file"
test_command_output "head -z -n 2 from file" \
    $'rec1\x00rec2\x00' \
    "$binary" -z -n 2 "$nul_file"
```

Note: the output comparison requires `test_command_output_exact` or a
hex-compare helper because `test_command_output` uses bash string
comparison which drops embedded NULs. This is a framework limitation
worth noting in the test comment.

---

### [IMPORTANT] --silent advertised in help but not parsed

**Location:** `src/head.zig:203` (help text string)

**Problem:** The help text prints:

```
-q, --quiet, --silent    never print headers giving file names
```

But `--silent` is not registered as a long alias for `quiet` in the
`HeadArgs.meta` struct. Running `head --silent` returns exit code 2
with "unrecognized option". The test file contains a TODO comment
acknowledging this (line 105–106) but skips the test rather than
flagging the discrepancy.

This is a documentation bug that becomes a behavioral bug: users who
follow the help text will get an error.

**Fix (code, not tests):** Either register `--silent` as an alias in
argparse, or remove it from the help text. Adding an integration test
that asserts `head --silent /dev/null` exits 0 would catch regressions
either way:

```bash
test_command_succeeds "head --silent /dev/null" "$binary" --silent /dev/null
```

---

### [IMPORTANT] -c with newlines: two tests are exit-code-only stubs

**Location:** `tests/utilities/head_test.sh:79-80`

**Problem:** The tests `"head -c 6 works"` and `"head -c 12 works"` use
`test_command_exit_code` with exit code 0. They do not verify output
content. The commented block above (lines 71–76) explains the output
tests were removed because the test framework drops trailing newlines
via bash `$(...)` substitution. Exit-code-only tests for `-c` with
newline content provide no behavioral coverage.

The actual behavior (`-c 6` of `"Line1\nLine2\nLine3\n"` should yield
`"Line1\n"`) is correct, but is not verified.

**Fix:** Use `test_command_output_exact` (already present in common.sh)
which uses `cmp -s` on a temp file and does not strip trailing newlines:

```bash
test_command_output_exact "head -c 6 with newlines" \
    $'Line1\n' "$binary" -c 6 "$newline_file"
test_command_output_exact "head -c 12 with newlines" \
    $'Line1\nLine2\n' "$binary" -c 12 "$newline_file"
```

---

### [SUGGESTION] -n and -c suffix support is untested when feature absent

**Location:** `tests/utilities/head_test.sh:229-235`

**Problem:** The suffix tests (`-c 1k`, `-c 1KB`) are guarded by a
runtime probe (`if "$binary" ... >/dev/null 2>&1`). When the feature is
not implemented the tests silently disappear from the run count. There
is no SKIP record. A reader of the test summary cannot tell whether
suffix support was probed and absent, or was never checked.

**Fix:** Replace the silent skip with an explicit `print_test_result
... SKIP` so the omission is visible in the summary output.

---

### [SUGGESTION] "head -c 6 works" test name is misleading

**Location:** `tests/utilities/head_test.sh:79-80`

**Problem:** The test names say "works" but only verify exit 0. A future
reader may assume these tests cover output content. The names should
reflect what is actually tested.

**Fix:** Rename to `"head -c 6 exit code"` and `"head -c 12 exit code"`.

---

### [SUGGESTION] Duplicate "head default (10 lines)" tests

**Location:** `tests/utilities/head_test.sh:26` and `:34`

**Problem:** `"head default (10 lines)"` and `"head no options default"`
run the identical command (`"$binary" "$test_file2"`) with the identical
expected output. One of them contributes nothing to coverage.

**Fix:** Remove one of the two; the POSIX section at line 174 provides a
third copy of the same assertion, which can cover the POSIX label.

---

## Coverage Summary

| Flag | Tier | Integration Tests | Quality |
|---|---|---|---|
| -n / --lines | MUST | Yes | Strong |
| -c / --bytes | SHOULD | Yes (partial — newline tests stub) | Weak |
| -q / --quiet | SHOULD | Yes | Strong |
| --silent | SHOULD | None (feature broken) | None |
| -v / --verbose | SHOULD | Yes | Strong |
| -z | SHOULD | None | None |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] --silent unrecognized despite being in help text — src/head.zig:203
2. [IMPORTANT] -z (SHOULD) has zero integration tests — tests/utilities/head_test.sh
3. [IMPORTANT] -c with newlines: exit-code-only stubs — tests/utilities/head_test.sh:79-80
4. [SUGGESTION] Suffix tests silently absent from summary — tests/utilities/head_test.sh:229-235
5. [SUGGESTION] "works" test names are misleading — tests/utilities/head_test.sh:79-80
6. [SUGGESTION] Duplicate default-10-lines tests — tests/utilities/head_test.sh:26,34
```

REVIEW COMPLETE - NEEDS_FIXES
