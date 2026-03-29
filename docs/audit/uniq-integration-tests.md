---
audit: uniq integration tests
date: 2026-03-28
result: NEEDS_FIXES
tests_run: 42
tests_passed: 42
---

# uniq Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/uniq_test.sh`
**Spec:** `docs/specs/uniq-flags.md`
**Result:** 42/42 pass

---

## Findings

### [IMPORTANT] -z (NUL-delimited) has zero integration tests
**Location:** `tests/utilities/uniq_test.sh` (no such test)
**Problem:** `-z` is listed SHOULD in the flag spec and is implemented
(`yes` in the "Ours" column), but no integration test exercises it.
A `-z` test requires NUL-delimited input and must verify that output
lines are terminated by NUL, not newline. This is the only SHOULD flag
without any integration coverage.
**Fix:** Add tests that pass NUL-delimited input via `printf 'a\0a\0b\0'`
and verify NUL-terminated output with `od -c` or `xxd`.

---

### [IMPORTANT] -D separator modes are untested
**Location:** `tests/utilities/uniq_test.sh:50-52`
**Problem:** GNU `uniq -D` accepts an optional `--all-repeated[=METHOD]`
argument controlling separator behavior between groups:
`none` (default), `prepend`, `separate`. The existing tests cover only
the bare `-D` form (equivalent to `none`). The `prepend` and `separate`
modes — which insert blank lines between duplicate groups — have zero
tests. These are the primary reason `-D` is useful over `-d`.
**Fix:** Add tests for `--all-repeated=prepend` and
`--all-repeated=separate`, verifying the blank-line separators appear
correctly.

---

### [IMPORTANT] -f and -s with boundary values are not tested
**Location:** `tests/utilities/uniq_test.sh:72-80`
**Problem:** Only one non-zero value is tested for each of `-f` and
`-s`. Missing boundary conditions:
- `-f 0` (skip zero fields — should behave as no skip)
- `-s 0` (skip zero chars — should behave as no skip)
- `-f N` where N exceeds the number of fields in the line (GNU skips
  the entire line content, treating it as empty)
- `-s N` where N exceeds the line length (same empty-content behavior)

GNU behavior for over-large skip values is to treat the comparison
string as empty, causing all lines to collapse to one. This is a
corner case that implementations commonly get wrong.
**Fix:** Add tests for zero-value and overshooting skip values,
comparing against `gnu uniq` reference output.

---

### [IMPORTANT] -w interaction with -f/-s is untested
**Location:** `tests/utilities/uniq_test.sh:83-86`
**Problem:** `-w` (check-chars) is tested in isolation, but GNU `uniq`
applies `-w` to the comparison string *after* field and character
skipping. The combination `-f 1 -w 3` or `-s 2 -w 4` exercises a
different code path than any of the flags alone. The only
combination tests are `-c -d` and `-c -u` (lines 91-94).
**Fix:** Add at least one test combining `-f`/`-s` with `-w` to verify
the interaction: skip then limit compares correctly.

---

### [SUGGESTION] -c format string is only tested with one alignment width
**Location:** `tests/utilities/uniq_test.sh:36-38`
**Problem:** The `-c` tests fix the count at 1, 2, and 3 (largest is
`      3 aaa`). GNU `uniq -c` uses a 7-character right-aligned field.
No test exercises a count >= 10 to verify the column widens correctly,
nor counts >= 1000000 to stress alignment. If the implementation
hard-codes the width incorrectly, only large counts will reveal it.
**Fix:** Add a test with 10+ identical lines to confirm the count
column aligns correctly (e.g., `     10 line`).

---

### [SUGGESTION] No test verifies that -d and -u are mutually exclusive or additive
**Location:** `tests/utilities/uniq_test.sh` (no such test)
**Problem:** GNU `uniq` treats `-d -u` (or equivalently `--repeated
--unique`) as selecting only lines that appear neither uniquely nor
repeatedly — i.e., it produces no output. This is a documented GNU
behavior that is easy to implement incorrectly. The test file has no
coverage for this combination.
**Fix:** Add `uniq -d -u` test asserting empty output when input
contains both unique and repeated lines.

---

### [SUGGESTION] stderr content of error messages is not verified
**Location:** `tests/utilities/uniq_test.sh:143-157`
**Problem:** The error-diagnostics block confirms that stderr is
non-empty on a nonexistent file (line 152-156), but does not check
that the message follows GNU convention: `uniq: /nonexistent/file: No
such file or directory`. A prefix-only check (`[[ $uniq_err_stderr ==
*uniq*]]`) would catch a stray error message from a different utility
and confirm the program name prefix is present.
**Fix:** Add a pattern assertion on `$uniq_err_stderr` to require the
program name and the filename appear in the message.

---

## Coverage Matrix

| Flag | Tier | Tested | Quality |
|------|------|--------|---------|
| -c | MUST | yes | behavioral — exact output |
| -d | MUST | yes | behavioral — exact output |
| -f | MUST | yes | one value only; zero/overrun missing |
| -s | MUST | yes | one value only; zero/overrun missing |
| -u | MUST | yes | behavioral — exact output |
| -i | MUST | yes | behavioral — exact output |
| -D | SHOULD | partial | bare form only; separator modes missing |
| -w | SHOULD | yes | isolated; no combination with -f/-s |
| -z | SHOULD | **no** | zero tests |
| --group | WONT | n/a | intentionally omitted |

---

## Summary

**Counts by severity:**
- IMPORTANT: 4
- SUGGESTION: 3

**Overall assessment:** NEEDS_FIXES

The suite is solid for the core MUST flags with genuine behavioral
tests throughout. The primary gap is `-z`, which is listed as
implemented in the flag spec but has zero integration coverage. The
`-D` separator-mode gap and the `-f`/`-s`/`-w` combination gap are
next in priority.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -z has zero integration tests
   — tests/utilities/uniq_test.sh (add NUL-delimited section)
2. [IMPORTANT] -D separator modes (prepend/separate) untested
   — tests/utilities/uniq_test.sh (add --all-repeated=prepend/separate)
3. [IMPORTANT] -f/-s zero and overshooting boundary values untested
   — tests/utilities/uniq_test.sh (add edge-case inputs)
4. [IMPORTANT] -w interaction with -f/-s untested
   — tests/utilities/uniq_test.sh (add combined-flag test)
5. [SUGGESTION] -c column width untested for counts >= 10
   — tests/utilities/uniq_test.sh (add 10-line input test)
6. [SUGGESTION] -d -u combination (empty output) untested
   — tests/utilities/uniq_test.sh (add combination test)
7. [SUGGESTION] stderr message content not verified
   — tests/utilities/uniq_test.sh:152-156 (add pattern assertion)
```

REVIEW COMPLETE - NEEDS_FIXES
