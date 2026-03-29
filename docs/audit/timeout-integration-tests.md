# timeout Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/timeout_test.sh`
**Tests:** 20 run; 19 pass, 1 fail (`timeout with -s KILL`)
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Pass? |
|---|-----------|------|-------|
| 1 | timeout help flag (via test_basic_flags) | behavioral | PASS |
| 2 | timeout version flag (via test_basic_flags) | behavioral | PASS |
| 3 | timeout command succeeds | behavioral | PASS |
| 4 | timeout command fails | behavioral | PASS |
| 5 | timeout kills slow command | behavioral | PASS |
| 6 | timeout 0 disables timeout | behavioral | PASS |
| 7 | timeout missing operand | behavioral | PASS |
| 8 | timeout missing command | behavioral | PASS |
| 9 | timeout invalid duration | behavioral | PASS |
| 10 | timeout command not found | behavioral | PASS |
| 11 | timeout with -s KILL | behavioral | **FAIL** |
| 12 | timeout --preserve-status | behavioral | **FAIL** (not counted — see note) |
| 13 | timeout with seconds suffix | behavioral | PASS |
| 14 | timeout with fractional duration | behavioral | PASS |
| 15 | timeout -s USR1 is accepted | behavioral | PASS |
| 16 | timeout -s USR2 is accepted | behavioral | PASS |
| 17 | timeout --help documents --signal flag | behavioral | PASS |
| 18 | timeout no args exits 125 | behavioral | PASS |
| 19 | timeout --bad-flag exits 2 | behavioral | PASS |

Note: The runner reports 20 tests run, 19 pass, 1 fail. `--preserve-status` also fails (exit 0, expected 143) but the runner stops counting after hitting the first failure in that block only if structured that way. Confirmed by direct binary test: both `-s KILL` and `--preserve-status` return exit 0.

---

## Confirmed Production Bugs

### [CRITICAL] `-s KILL 0.5 sleep 60` returns exit 0 instead of 137

Direct invocation:
```
/home/tcole/code/vibeutils/zig-out/bin/timeout -s KILL 0.5 sleep 60
echo $?   # → 0
```

Expected: `137` (128 + SIGKILL). The child is not being killed, or its exit code is being misread. This affects the core purpose of the utility.

**Location:** `tests/utilities/timeout_test.sh:73`

---

### [CRITICAL] `--preserve-status 0.5 sleep 60` returns exit 0 instead of 143

Direct invocation:
```
/home/tcole/code/vibeutils/zig-out/bin/timeout --preserve-status 0.5 sleep 60
echo $?   # → 0
```

Expected: `143` (128 + SIGTERM). The unit test for this path is skipped on Linux CI (see unit test audit), so this production bug has no test safety net on the primary CI platform.

**Location:** `tests/utilities/timeout_test.sh:76-83`

---

## Missing Coverage

### [IMPORTANT] `--kill-after` / `-k` has zero integration tests

The `--kill-after` flag sends SIGKILL if the child is still running after a second duration. It is documented in the GNU man page and in the help text. No integration test exercises it. Expected behavior: `timeout -k 0.2 0.1 sleep 60` should return 137 within ~0.3 seconds.

---

### [IMPORTANT] `--verbose` / `-v` has zero integration tests

The `--verbose` flag should write a diagnostic to stderr when a signal is sent. No test captures stderr and checks for the expected message (e.g. `timeout: sending signal 15 to command 'sleep'`). GNU behavior: message on stderr, one per signal sent.

---

### [IMPORTANT] `--foreground` has zero integration tests

The `--foreground` flag prevents creation of a new process group. No integration test verifies this changes process group behavior. This is a MUST flag per the GNU spec.

---

### [IMPORTANT] Numeric signal argument (`-s 9`, `-s 15`) has zero integration tests

Only named signals (`KILL`, `USR1`, `USR2`) are tested. GNU timeout accepts numeric signal values. The `parseSignal` function handles numerics, but no integration test exercises that path end-to-end.

---

### [IMPORTANT] `--preserve-status` test is a known live failure, not just a gap

The test at line 76 runs but produces the wrong exit code (0 instead of 143). This is a confirmed bug, not a missing test. The test exists and is correctly written — the implementation is wrong.

---

### [SUGGESTION] `timeout command not found` accepts exit 1 or 127 — too permissive

**Location:** `tests/utilities/timeout_test.sh:61-68`

```bash
if [[ $exit_code -eq 127 || $exit_code -eq 1 ]]; then
```

GNU timeout must exit 127 for command not found. Accepting exit 1 hides a divergence. On Linux this should always be 127.

**Fix:** Assert `exit_code -eq 127` on Linux; add a platform guard for macOS if genuinely needed.

---

### [SUGGESTION] `--preserve-status` with a command that exits non-zero (not just signal) is untested

GNU timeout with `--preserve-status` and a command that exits normally with a non-zero code should propagate that exit code. Only the signal-timeout path is tested (and that path is currently broken). A test like `timeout --preserve-status 10 false` should exit 1.

---

## Summary

- **CRITICAL:** 2 confirmed production bugs (`-s KILL` returns 0; `--preserve-status` returns 0)
- **IMPORTANT:** 5 (--kill-after, --verbose, --foreground, numeric signal, --preserve-status bug)
- **SUGGESTION:** 2 (command-not-found too permissive; --preserve-status normal exit untested)

**Overall: NEEDS_FIXES**

Fix order:
1. [CRITICAL] Fix `-s KILL` exit code bug (returns 0, should be 137) — production bug
2. [CRITICAL] Fix `--preserve-status` exit code bug (returns 0, should be 143) — production bug
3. [IMPORTANT] Add `--kill-after` integration test
4. [IMPORTANT] Add `--verbose` stderr output integration test
5. [IMPORTANT] Add `--foreground` integration test
6. [IMPORTANT] Add numeric signal integration tests (`-s 9`, `-s 15`)
7. [SUGGESTION] Tighten command-not-found to assert 127 on Linux — `timeout_test.sh:64`
8. [SUGGESTION] Add `--preserve-status` with normal non-zero exit test
