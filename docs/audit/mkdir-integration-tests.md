---
name: mkdir integration test audit
description: 2026-03-28 integration test audit for mkdir; 98/98 pass;
  1 important behavioral divergence from GNU (-m + -p intermediate dirs);
  1 important test ordering concern
type: project
---

# mkdir Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/mkdir_test.sh`
**Test count:** 98
**Passed:** 98
**Status:** NEEDS_FIXES

## Coverage by Flag / Feature

| Feature | Covered | Notes |
|---------|---------|-------|
| Basic creation | YES | single, multiple, absolute path |
| `-p` / `--parents` | YES | parents, existing, partial |
| `-v` / `--verbose` | YES | single, multi, long option |
| `-m` / `--mode` | YES | 755, 644, 777, 000, 4-digit, equals syntax |
| `-p -v` combined | YES | output checked for all 3 levels |
| `-p -m` combined | YES | mode checked on all levels |
| `-v -m` combined | YES | |
| `-p -v -m` all flags | YES | |
| Missing operand | YES | exit 2 |
| Invalid flags | YES | `--invalid-flag`, `-z` |
| Invalid mode | YES | abc, 888, 9999, empty |
| Existing dir (no -p) | YES | exit 1 |
| Permission denied | YES | |
| File conflict | YES | |
| Trailing slash | YES | |
| Double slashes | YES | |
| Dot components | YES | |
| Long name | YES | 100 chars |
| Special chars | YES | |
| Nested without -p | YES | fails |
| Empty name | YES | fails |
| Flag terminator `--` | YES | `-looks-like-flag` |
| Deep nesting | YES | 5 levels |
| Unicode names | YES | locale-gated |
| Case sensitivity | YES | fs-type gated |
| Many dirs (50) | YES | |
| Very deep (10 levels) | YES | |
| POSIX error messages | YES | "File exists" regression |
| `-p -m 700` intermediate dirs | YES | regression test |
| Symlink conflict | YES | |
| Preserves existing perms with `-p` | YES | |

## Issues Found

### [IMPORTANT] `-p -m` mode on intermediate directories contradicts GNU

**Location:** `tests/utilities/mkdir_test.sh:404-443`

**Problem:** The regression test block "Testing -p -m mode on
intermediate directories" asserts that `-p -m 700` sets mode 700 on
all created directories including intermediate parents. GNU coreutils
documents the opposite:

```
-p, --parents
    no error if existing, make parent directories as needed,
    with their file modes unaffected by any -m option
```

On GNU, only the final (leaf) directory gets the mode specified by
`-m`; parent directories are created with the default umask-derived
mode. The integration tests are validating a non-GNU behavior and will
pass only because the implementation also implements the non-GNU
behavior.

**Fix:** Verify against actual GNU coreutils. If GNU behavior is
confirmed (mode applies only to leaf), rewrite the regression tests so
that intermediate dir permissions are asserted to equal the default
umask mode, not 700. The leaf-only assertion should remain.

### [IMPORTANT] `test_command_output` checks for exact prefix match on -pv output

**Location:** `tests/utilities/mkdir_test.sh:135`

**Problem:** The expected string for `-pv` is:
```
$'mkdir: created directory \'combo\'\nmkdir: created directory \'combo/test\'\nmkdir: created directory \'combo/test/path\''
```

This is an exact full-output match. If the verbose output order ever
changes (e.g., different path separator handling on some platforms), the
test will fail. More importantly, the expected path is `combo/test/path`
but `createPathComponents` builds paths incrementally; the actual order
depends on the split traversal. Confirm this matches actual output on
both Linux and macOS.

**Fix:** Consider using `test_command_output_pattern` for ordering-
independent checks on each component, or document that the exact order
is a specified contract.

### [SUGGESTION] `test_command_exit_code "POSIX: mkdir failure exit code"` uses `|| true`

**Location:** `tests/utilities/mkdir_test.sh:244`

**Problem:**
```bash
test_command_exit_code "POSIX: mkdir failure exit code" 1 "$binary" "/dev/null/impossible" 2>/dev/null || true
```

The `|| true` means a test failure (exit code mismatch) is silently
swallowed. If the binary returns 0 for this path, the test will still
pass the overall suite.

**Fix:** Remove `|| true`. If the command should fail with exit 1, let
the test framework report failure properly.

### [SUGGESTION] `test_command_exit_code "mkdir mixed success/failure"` uses `|| true`

**Location:** `tests/utilities/mkdir_test.sh:264`

**Problem:** Same pattern as above — failure is silently swallowed:
```bash
test_command_exit_code "mkdir mixed success/failure" 1 "$binary" "new_success" "exists_already" 2>/dev/null || true
```

**Fix:** Remove `|| true`.

## What Is NOT Tested

- `-Z` / `--context` (SELinux) — acceptable; platform-specific, not
  applicable on most targets
- Symbolic mode strings for `-m` (e.g., `u+rwx`) — the implementation
  only supports octal; no test documents this limitation explicitly

## Summary

- 98/98 tests pass
- Coverage is broad and generally strong
- Primary concern is the `-pm` intermediate-directory behavior that
  diverges from GNU and is locked in by regression tests
- Two `|| true` constructs mask potential exit-code failures

## Fix Order

1. [IMPORTANT] Verify and correct `-p -m` intermediate dir behavior
   against GNU — `tests/utilities/mkdir_test.sh:404-443`
2. [IMPORTANT] Confirm exact `-pv` output order matches implementation
   on both platforms — `tests/utilities/mkdir_test.sh:135`
3. [SUGGESTION] Remove `|| true` from exit-code tests —
   `tests/utilities/mkdir_test.sh:244` and `264`

**REVIEW COMPLETE - NEEDS_FIXES**
