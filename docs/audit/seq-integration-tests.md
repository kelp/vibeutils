---
utility: seq
audit_type: integration-tests
date: 2026-03-28
test_count: 13
status: NEEDS_FIXES
---

# seq Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/seq_test.sh`
**Test count:** ~13 assertions (including `test_basic_flags`)

---

## Summary

The integration test suite is very thin. It covers only three
sequence forms, `--help`, `--version`, one error condition, `-s`,
and `-w`. GNU-primary features like `-f`, negative increments,
float sequences, multiple error cases, and the `--` separator
are entirely absent. The test also contains a weak helper check
pattern for `-s` that does not use `test_command_output`.

---

## Test Inventory

| Test | Behavioral? | Notes |
|------|-------------|-------|
| test_binary_exists | Infrastructure | Not a feature test |
| test_basic_flags | Infrastructure | --help/--version/--invalid |
| seq 5 outputs 1-5 | Yes | Basic LAST form |
| seq 2 5 outputs 2-5 | Yes | FIRST LAST form |
| seq 1 2 10 outputs 1,3,5,7,9 | Yes | FIRST INCR LAST form |
| seq --help shows usage | Weak | Exit code + regex match only |
| seq --version shows version | Weak | Exit code + regex match only |
| seq invalid flag exits 2 | Exit-code only | No stderr check |
| seq -s separator | Yes | Exact string match |
| seq -w equal width | Yes | Exact string match |

`test_basic_flags` internally tests `--help`, `--version`, and an
invalid flag, all at exit-code level only.

---

## Issues Found

### [CRITICAL] -f flag (MUST) has zero integration tests
Location: `tests/utilities/seq_test.sh`
Problem: GNU's primary format flag `-f` (`--format`) is completely
absent from the integration suite. `seq -f "%e" 3`,
`seq -f "%g" 3`, `seq -f "%.2f" 3` are all untested. A broken
`-f` implementation would pass all integration tests.
Fix: Add tests for `-f %f`, `-f %e`, and `-f "%.2f"`.

### [CRITICAL] Negative increment (countdown) has zero integration
tests
Location: `tests/utilities/seq_test.sh`
Problem: `seq 5 -1 1` is a core GNU use case and is covered only
in unit tests. Because it requires the `--` separator to prevent
`-1` being parsed as a flag, this integration path (passing
negative args in shell) is distinct from the unit test. It is
entirely absent.
Fix: Add `"$binary" -- 5 -1 1` integration test.

### [CRITICAL] Float sequences have zero integration tests
Location: `tests/utilities/seq_test.sh`
Problem: `seq 0.5 0.5 2.0` and similar float inputs are only in
unit tests. The real binary's float-to-string conversion path
is untested at the integration level.
Fix: Add `"$binary" 0.5 0.5 2.0` and check output is
`0.5\n1.0\n1.5\n2.0`.

### [IMPORTANT] Error cases: missing operand not tested
Location: `tests/utilities/seq_test.sh`
Problem: `seq` with no arguments should print an error to stderr
and exit 2. Only the "invalid flag" error case is tested. The
"missing operand", "extra operand", "invalid number", and "zero
increment" error paths from the implementation are absent.
Fix: Add tests for each distinct error case checking exit code
and stderr content.

### [IMPORTANT] -s and -w checks do not use test_command_output
Location: `tests/utilities/seq_test.sh:68-87`
Problem: The `-s` and `-w` tests use ad-hoc `if [[ ... ]]`
comparisons rather than `test_command_output`. This is
inconsistent with the rest of the suite and makes failures
harder to diagnose (no "expected vs got" is printed for -w).
Fix: Refactor to use `test_command_output`.

### [IMPORTANT] --help and --version are exit-code-only stubs
Location: `tests/utilities/seq_test.sh:33-56`
Problem: Both the manual `--help`/`--version` blocks and the
`test_basic_flags` helper check only that the exit code is 0 and
the output contains a regex pattern ("Usage" or "seq"). They do
not verify any specific output fields.
Fix: Check for specific strings like "seq [OPTION]... LAST" and
the version format.

### [SUGGESTION] No test for -w combined with -f
Location: `tests/utilities/seq_test.sh`
Problem: `-w` and `-f` interact in GNU seq (format string takes
precedence). No integration test exercises this combination.
Fix: Add a combined flag test.

### [SUGGESTION] No test for -s with empty string
Location: `tests/utilities/seq_test.sh`
Problem: `seq -s '' 3` (empty separator, output `123`) is a
valid and useful case not covered.
Fix: Add test.

---

## GNU Behavioral Coverage

| GNU Feature | Covered |
|-------------|---------|
| seq LAST | Yes |
| seq FIRST LAST | Yes |
| seq FIRST INCR LAST | Yes (positive only) |
| Negative increment (countdown) | No |
| Float sequences | No |
| -f / --format | No |
| -s / --separator | Yes |
| -w / --equal-width | Yes |
| No-arg error | No |
| Invalid number error | No |
| Zero increment error | No |
| inf/nan inputs | No |

---

## Overall Assessment: NEEDS_FIXES

3 critical, 3 important, 2 suggestion.
The suite covers only the happy-path integer forms and two flags.
Three MUST-tier behaviors (-f, countdown, floats) have zero
integration tests.
