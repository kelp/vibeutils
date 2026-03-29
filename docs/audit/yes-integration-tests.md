# yes — Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/yes_test.sh`
**Tests:** 8 (all pass)
**Assessment:** NEEDS_FIXES

## Test Inventory

| # | Test Name | Type | Verdict |
|---|-----------|------|---------|
| 1 | `yes binary` | binary exists | OK |
| 2 | `yes --help` | exit code 0 + help output | OK |
| 3 | `yes --version` | exit code 0 | OK |
| 4 | `yes default output is y` | behavioral | OK |
| 5 | `yes custom string` | behavioral | OK |
| 6 | `yes multiple args joined` | behavioral | OK |
| 7 | `yes clean exit on broken pipe` | behavioral | OK |
| 8 | `yes large string (9000 chars)` | behavioral | OK |

## GNU Reference (primary)

GNU `yes` behavior:
- Default output: `y` repeated, one per line.
- `yes STRING...`: outputs `STRING1 STRING2 ...` per line.
- Exits 0 on SIGPIPE / write error.
- Does not accept any flags other than `--help` and `--version`;
  any unrecognized option prints an error to stderr and exits 1
  (GNU actually exits with status 1, not 2).
- No `-n` flag, no `--null`, no other options.

## Findings

### [IMPORTANT] No test for unrecognized flag error handling
Location: `tests/utilities/yes_test.sh` (not present)
Problem: GNU `yes --badopt` prints an error to stderr and exits 1.
The implementation handles this via `runYes`'s `UnknownFlag` branch
returning `ExitCode.misuse` (2). Neither exit code 1 vs 2 nor the
error message is tested.
Fix: Add a test:
```bash
"$binary" --badopt >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    print_test_result "yes rejects unknown flag" "PASS"
else
    print_test_result "yes rejects unknown flag" "FAIL" \
        "Expected non-zero exit, got $exit_code"
fi
```

### [IMPORTANT] --version content not verified
Location: `tests/utilities/yes_test.sh:18` (via `test_basic_flags`)
Problem: `test_basic_flags` only checks that `--version` exits 0.
It does not verify that a version string or program name appears in
the output.
Fix: Capture `"$binary" --version` output and assert it contains
`"yes"` or a version number.

### [SUGGESTION] --help content not verified
Location: `tests/utilities/yes_test.sh:18` (via `test_basic_flags`)
Problem: `test_basic_flags` checks `--help` exits 0 but does not
inspect the output. A binary that exits 0 with empty help output
would pass.
Fix: Check that `--help` output contains `"Usage:"` or similar.

### [SUGGESTION] No test for `yes ""` (empty string argument)
Location: `tests/utilities/yes_test.sh` (not present)
Problem: GNU `yes ""` outputs a blank line repeatedly (just `\n`).
This edge case is not covered.
Fix: Add:
```bash
set +o pipefail
output=$("$binary" "" | head -n 1)
set -o pipefail
if [[ "$output" == "" ]]; then
    print_test_result "yes empty string arg" "PASS"
else
    print_test_result "yes empty string arg" "FAIL" \
        "Expected empty line, got '$output'"
fi
```

### [SUGGESTION] SIGPIPE test only checks exit code, not signal safety
Location: `tests/utilities/yes_test.sh:64-73`
Problem: The test checks exit code 0 after `head -n 1` breaks the
pipe, but does not verify the program did not crash or produce a
core dump. In practice this is fine since exit 0 implies clean
termination, but worth noting.

## Summary

8/8 pass. Core behaviors are covered. The missing unrecognized-flag
test is the most significant gap: the implementation returns
`ExitCode.misuse` (2) for unknown flags but GNU returns 1 — this
discrepancy is untested and undetected.

**Fix Order:**
1. [IMPORTANT] Add unknown-flag error test — `yes_test.sh`
2. [IMPORTANT] Verify `--version` output content — `yes_test.sh`
3. [SUGGESTION] Verify `--help` output content — `yes_test.sh`
4. [SUGGESTION] Add empty-string argument test — `yes_test.sh`

**Assessment: NEEDS_FIXES**
