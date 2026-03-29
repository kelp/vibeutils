# whoami Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/whoami_test.sh`
**Tests:** 7 run; all 7 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Pass? |
|---|-----------|------|-------|
| 1 | whoami help flag (via test_basic_flags) | behavioral | PASS |
| 2 | whoami version flag (via test_basic_flags) | behavioral | PASS |
| 3 | whoami matches system whoami | behavioral | PASS |
| 4 | whoami --help shows usage | behavioral | PASS |
| 5 | whoami --version shows version | behavioral | PASS |
| 6 | whoami invalid flag exits 2 | behavioral | PASS |

Note: 7 tests run because `test_basic_flags` contributes 2 tests (help + version), plus the 4 explicit tests in the file body. Tests 4 and 5 partially overlap with tests 1 and 2 from `test_basic_flags`.

---

## Findings

### [IMPORTANT] `-h` and `-V` short flags have no dedicated integration test

**Location:** `tests/utilities/whoami_test.sh`

`test_basic_flags "$util"` tests only `--help` and `--version` long options. The short forms `-h` and `-V` are not tested in integration. A regression that broke short-option parsing for whoami specifically would not be caught here. The unit tests do cover `-h` and `-V`.

**Fix:** Add explicit tests for `-h` (exit 0, contains "Usage") and `-V` (exit 0, contains "whoami").

---

### [IMPORTANT] Extra positional arguments are not tested in integration

**Location:** `tests/utilities/whoami_test.sh`

GNU whoami exits with an error (exit 1) for extra arguments: `whoami extra-arg` should fail with "extra operand". The unit tests cover this (test 8 in the unit suite), but no integration test exercises it. A regression in the binary's argument handling would not be caught.

**Fix:** Add `test_command_exit_code "whoami extra arg fails" 2 "$binary" extra-arg` and a stderr check for "extra operand".

---

### [IMPORTANT] Error message content for invalid flag is not verified

**Location:** `tests/utilities/whoami_test.sh:60-61`

```bash
test_command_exit_code "whoami invalid flag exits 2" 2 \
    "$binary" --invalid-flag
```

The test verifies exit code 2 but not the stderr content. The error message should contain `"whoami:"` and `"unrecognized option"`. A regression that produced the correct exit code with a garbled or empty error message would pass.

**Fix:** Capture stderr and assert it contains `"whoami:"` and `"unrecognized"`.

---

### [IMPORTANT] No test verifies output format (ends with newline, no extra text)

**Location:** `tests/utilities/whoami_test.sh:20-29`

```bash
if [[ "$output" == "$expected" ]]; then
```

`$()` command substitution strips trailing newlines. The test confirms the username text matches `$(whoami)` but cannot verify the trailing newline that the binary must emit. On a platform where the binary omits the newline, this test would still pass because both sides would have no trailing newline after substitution.

**Fix:** Capture output to a file and use `hexdump` or `od` to verify the final byte is `0x0a` (newline), similar to the pwd test suite approach.

---

### [SUGGESTION] `whoami --help` and `whoami --version` tests overlap `test_basic_flags`

**Location:** `tests/utilities/whoami_test.sh:32-55`

The file contains explicit `--help` and `--version` tests that check exit code and output content. `test_basic_flags "$util"` runs the same flags. This means help and version are tested twice with slightly different assertions. The duplication is not harmful but adds to the test count without adding coverage.

---

### [SUGGESTION] No test for output when running as root

**Location:** `tests/utilities/whoami_test.sh`

When running as root (UID 0), whoami should print "root". This is exercised in privileged test environments but not in the integration suite. Not required for normal CI, but worth noting as a gap for container/privileged test runs.

---

## Summary

- **CRITICAL:** 0
- **IMPORTANT:** 4 (short flags -h/-V missing; extra positionals missing; error message content not checked; newline not verified)
- **SUGGESTION:** 2 (help/version overlap with test_basic_flags; no root test)

**All 7 tests pass.** The suite is the smallest of the four utilities audited. The core behavioral test (output matches `$(whoami)`) is correct and sufficient for the happy path, but the error paths and output format are under-specified.

**Overall: NEEDS_FIXES**

Fix order:
1. [IMPORTANT] Add `-h` and `-V` short-flag integration tests — `whoami_test.sh`
2. [IMPORTANT] Add extra-positional-argument integration test — `whoami_test.sh`
3. [IMPORTANT] Add stderr content check to invalid-flag test — `whoami_test.sh:60`
4. [IMPORTANT] Verify trailing newline in output (file-based capture) — `whoami_test.sh`
5. [SUGGESTION] Deduplicate --help/--version with test_basic_flags — `whoami_test.sh:32`
