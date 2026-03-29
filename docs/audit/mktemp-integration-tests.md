---
date: 2026-03-28
utility: mktemp
audit_type: integration-tests
status: NEEDS_FIXES
tests_counted: 24
---

# mktemp Integration Test Audit

## Summary

24/24 integration tests pass. The suite covers the core flags
well: file creation, `-d`, `-u`, `-p`/`--tmpdir`, `-q`, `--suffix`,
error conditions, and file/directory permissions.

Critical gaps: the `-t` flag (MUST tier) has no integration test.
`TMPDIR` environment-variable behavior is not exercised. GNU
specifies that when no template is given `--tmpdir` is implied;
this is untested as a behavioral assertion. The `--tmpdir` long
form without `=DIR` (bare `--tmpdir`) is unexercised. Several
`test_command_fails` calls do not capture or inspect stderr,
so they only verify the exit code.

---

## Test-by-Test Analysis

### `test_binary_exists "mktemp"` / `test_basic_flags "mktemp"`

Framework sanity checks. **Expected.**

### `mktemp creates file with default template`

Behavioral. Checks exit 0 and that the output path is a regular
file. **Good.**

### `mktemp default template starts with tmp.`

Behavioral. Checks `basename "$output" == tmp.*`. **Good.**

### `mktemp with custom template`

Behavioral. Checks basename starts with "mytest." and file
exists. **Good.**

### `mktemp -d creates directory`

Behavioral. Checks exit 0 and `-d "$output"`. **Good.**

### `mktemp --directory creates directory`

Behavioral. Tests long form. **Good.**

### `mktemp -u does not create file`

Behavioral. Checks exit 0 and `! -e "$output"`. **Good.**

### `mktemp -u -d does not create directory`

Behavioral. Tests combined `-u -d`. **Good.**

### `mktemp -p DIR uses specified directory`

Behavioral. Checks exit 0, path prefix matches `$tmpdir`, and file
exists. **Good.**

### `mktemp --tmpdir=DIR uses specified directory`

Behavioral. Tests long form `--tmpdir=DIR`. **Good.**

Note: `--tmpdir` without `=DIR` (which GNU treats as equivalent to
using `$TMPDIR`) is not tested.

### `mktemp -q suppresses error messages`

Behavioral. Runs `"$binary" -q "noX" 2>&1`, checks exit non-zero
and stdout+stderr both empty. **Good.**

### `error: too few X's` / `error: no X's`

Uses `test_command_fails`. This framework function checks for
non-zero exit but typically does not capture stderr. The description
string is used as the test name only, not as an assertion on output.
Neither test verifies the "too few X's" error message appears on
stderr.

### `error: too many templates`

Same `test_command_fails` pattern; exit code only.

### `error: invalid flag` / `error: invalid short flag`

Same pattern; exit code only. `-x` is the unlisted short flag
tested, which is reasonable.

### `error: suffix with slash`

Uses `test_command_fails`; exit code only. Does not verify the
"contains directory separator" message.

### `mktemp produces unique names`

Behavioral. Runs two consecutive invocations and compares output.
**Good.**

### `help output contains expected content`

Behavioral. Checks "Usage:", "--directory", and "--dry-run" present
in `--help` output. **Good.**

### `version output contains utility name`

Behavioral. Checks "mktemp" in `--version` output. Weak: does not
check the version number string. **Minor gap.**

### `mktemp file has mode 0600`

Behavioral. Uses `get_file_permissions` helper and checks "600".
**Good.** This is the most important permission test.

### `mktemp directory has mode 0700`

Behavioral. Checks "700". **Good.**

---

## Coverage Gaps

### CRITICAL

None.

### IMPORTANT

**[IMPORTANT] `-t` flag (MUST tier) has zero integration tests.**
Location: `tests/utilities/mktemp_test.sh`
Problem: `-t` is listed as MUST in `docs/specs/mktemp-flags.md`.
GNU defines `-t` as "interpret TEMPLATE as a single file name
component, relative to a directory: $TMPDIR, if set; else the
directory specified via -p; else /tmp [deprecated]". No test
verifies this behavior.
Fix: Add a test block such as:
```bash
# -t flag: template treated as basename, resolved via TMPDIR
TMPDIR="$TEMP_DIR/mktemp_t_test"
mkdir -p "$TMPDIR"
export TMPDIR
output=$("$binary" -t tmpXXXXXX)
if [[ $? -eq 0 && "$output" == "$TMPDIR"/* && -f "$output" ]]; then
    print_test_result "mktemp -t resolves via TMPDIR" "PASS"
    rm -f "$output"
else
    print_test_result "mktemp -t resolves via TMPDIR" "FAIL" "got: $output"
fi
unset TMPDIR
```

**[IMPORTANT] `TMPDIR` env var resolution untested.**
Location: `tests/utilities/mktemp_test.sh`
Problem: GNU specifies that when no template is provided (default)
or `-t` is used, `$TMPDIR` is consulted. No integration test sets
`TMPDIR` and verifies the output path is under it. A regression
in `resolveTmpdir` would go undetected.
Fix: Set `TMPDIR` to a test-controlled dir, invoke `"$binary"`
with no template, assert output starts with `$TMPDIR/`.

**[IMPORTANT] `test_command_fails` calls do not inspect stderr.**
Location: `tests/utilities/mktemp_test.sh:131–142`
Problem: Five error-condition tests rely solely on non-zero exit
code. If the error message is silenced or changed, the tests still
pass. Particularly for "too few X's" and "suffix with slash", the
message is part of the behavioral contract.
Fix: Capture stderr explicitly and assert expected substrings:
```bash
stderr_out=$("$binary" "tmp.XX" 2>&1 >/dev/null)
if [[ $? -ne 0 && "$stderr_out" =~ "too few X" ]]; then
    print_test_result "error: too few X's message" "PASS"
else
    print_test_result "error: too few X's message" "FAIL" \
        "stderr='$stderr_out'"
fi
```

### SUGGESTION

**[SUGGESTION] `--tmpdir` without `=DIR` is not tested.**
Location: `tests/utilities/mktemp_test.sh`
Problem: GNU accepts `--tmpdir` (no value) as equivalent to
`-p $TMPDIR`. The integration test covers `--tmpdir=DIR` but not
bare `--tmpdir`.

**[SUGGESTION] `--version` output does not check version number.**
Location: `tests/utilities/mktemp_test.sh:169–175`
Problem: Only `"mktemp"` in the output is checked. The version
string itself is not verified, so a regressed version would pass.

**[SUGGESTION] Default-template path prefix not asserted.**
Location: `tests/utilities/mktemp_test.sh:20–28`
Problem: The "creates file with default template" test checks
exit code and file existence but not that the file is under `/tmp`
(or `$TMPDIR`). A broken `resolveTmpdir` placing the file in cwd
would pass.

**[SUGGESTION] `-u` with a custom template is not tested.**
Location: `tests/utilities/mktemp_test.sh`
Problem: Both `-u` tests use the default template. No test
verifies `-u myapp.XXXXXX` prints a name matching the template
prefix.

---

## Findings Summary

| Severity  | Count |
|-----------|-------|
| CRITICAL  | 0     |
| IMPORTANT | 3     |
| SUGGESTION| 4     |

**Assessment: NEEDS_FIXES**

Fix Order:
1. [IMPORTANT] `-t` flag (MUST tier) has zero integration tests —
   `tests/utilities/mktemp_test.sh`
2. [IMPORTANT] `TMPDIR` env var resolution untested —
   `tests/utilities/mktemp_test.sh`
3. [IMPORTANT] Error-condition tests do not assert stderr content —
   `tests/utilities/mktemp_test.sh:131–142`

REVIEW COMPLETE - NEEDS_FIXES
