# sleep Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/sleep_test.sh`
**Tests:** 10 run; all 10 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Pass? |
|---|-----------|------|-------|
| 1 | sleep help flag (via test_basic_flags) | behavioral | PASS |
| 2 | sleep version flag (via test_basic_flags) | behavioral | PASS |
| 3 | sleep 0 succeeds | behavioral | PASS |
| 4 | sleep 0.1 succeeds | behavioral | PASS |
| 5 | sleep multiple args summed | behavioral | PASS |
| 6 | sleep invalid arg (abc) | behavioral | PASS |
| 7 | sleep negative duration (-1) | behavioral | PASS |
| 8 | sleep missing operand | behavioral | PASS |
| 9 | sleep 0 exits 0 (arena safety net) | behavioral | PASS (duplicate of test 3) |
| 10 | (--help and --version are from test_basic_flags; 2 tests consumed there) | — | — |

Note: `test_basic_flags` contributes 2 of the 10 tests (help and version). Tests 3 and 9 are duplicate: both assert `sleep 0` exits 0.

---

## Findings

### [IMPORTANT] No test verifies that sleep actually pauses for the requested duration

**Location:** `tests/utilities/sleep_test.sh`

The suite confirms that `sleep` returns exit 0, but no test checks that the delay is honored. A version of `sleep` that returned immediately for all inputs would pass every test in this file. The minimum credible check is a wall-clock measurement: run `sleep 0.1` and verify at least 50 ms elapsed (generous lower bound to avoid flakiness).

**Fix:** Add a test that times `sleep 0.1` and asserts elapsed time is at least 80 ms.

---

### [IMPORTANT] `TimeOverflow` error path (very large value) has no integration test

**Location:** `tests/utilities/sleep_test.sh`

The production code path `"invalid time interval: value too large"` is exercised by neither the unit tests nor the integration tests. A value like `"999999999999999d"` should trigger it. Untested error paths can silently regress.

**Fix:** Add `test_command_fails "sleep overflow value" "$binary" 999999999999999d` and check stderr contains "value too large".

---

### [IMPORTANT] Suffix units (`m`, `h`, `d`) have no integration test

**Location:** `tests/utilities/sleep_test.sh`

The unit tests cover time parsing thoroughly, but no integration test runs the binary with minute, hour, or day suffixes. These all have zero seconds of actual sleep at value 0 — e.g., `sleep 0m` should succeed immediately. A regression in suffix-stripping in the integration binary would be undetected.

**Fix:** Add `test_command_exit_code "sleep 0m succeeds" 0 "$binary" 0m`, `0h`, `0d`.

---

### [IMPORTANT] Invalid time format error message content is not checked

**Location:** `tests/utilities/sleep_test.sh:33`

```bash
test_command_fails "sleep invalid arg (abc)" "$binary" abc
```

`test_command_fails` only checks that the command exits non-zero. It does not verify the error message on stderr says `"invalid time interval"`. A regression to a generic error (e.g., segfault or "unexpected error") would pass.

**Fix:** Use a direct invocation that captures stderr and asserts the message contains `"invalid time interval"`, similar to how timeout's integration tests capture error output.

---

### [SUGGESTION] Test 9 (`sleep 0 exits 0 (arena safety net)`) duplicates test 3

**Location:** `tests/utilities/sleep_test.sh:42-44`

```bash
test_command_exit_code "sleep 0 exits 0 (arena safety net)" 0 "$binary" 0
```

This is identical to test 3 (`sleep 0 succeeds`). The comment says it is a "regression test after arena allocator change" — that change is now long since merged. This duplicate adds noise to the test count.

**Fix:** Remove this test or repurpose it to cover a different scenario (e.g., `0s` suffix form).

---

### [SUGGESTION] No test for `--` end-of-options separator

**Location:** `tests/utilities/sleep_test.sh`

The unit tests use `-- -1` to pass a negative number through the positional path. No integration test exercises `sleep -- 1` (end-of-options with a valid duration) or `sleep -- -1` (negative through separator). These are valid command-line patterns.

---

### [SUGGESTION] Error exit code is not explicitly verified for invalid inputs

**Location:** `tests/utilities/sleep_test.sh:33-38`

`test_command_fails` only checks for a non-zero exit. GNU sleep exits 1 for invalid operands. The implementation currently exits 2 (misuse). Neither the test for invalid format nor the negative duration test checks the specific exit code. A change from exit 2 to exit 1 would pass.

**Fix:** Use `test_command_exit_code "sleep invalid arg exits 2" 2 "$binary" abc` instead of `test_command_fails`.

---

## Summary

- **CRITICAL:** 0
- **IMPORTANT:** 4 (no duration timing test; TimeOverflow not tested; suffix units not tested; error message content not checked)
- **SUGGESTION:** 3 (duplicate test 9; `--` separator untested; error exit code imprecise)

**All 10 tests pass.** The suite covers the basic happy path and two error conditions but misses any behavioral verification that sleep actually delays, and leaves several error paths unexercised.

**Overall: NEEDS_FIXES**

Fix order:
1. [IMPORTANT] Add wall-clock timing test for `sleep 0.1` — `sleep_test.sh`
2. [IMPORTANT] Add integration test for TimeOverflow large value — `sleep_test.sh`
3. [IMPORTANT] Add integration tests for `0m`, `0h`, `0d` suffix forms — `sleep_test.sh`
4. [IMPORTANT] Check error message content in invalid-arg tests, not just exit code — `sleep_test.sh:33`
5. [SUGGESTION] Remove duplicate test 9 or repurpose to cover `0s` — `sleep_test.sh:42`
6. [SUGGESTION] Use `test_command_exit_code ... 2` instead of `test_command_fails` for error cases — `sleep_test.sh:33-38`
