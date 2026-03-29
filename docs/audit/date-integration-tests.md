# date Integration Test Audit

**Date:** 2026-03-28
**Auditor:** reviewer agent
**Test file:** `tests/utilities/date_test.sh`
**Result:** NEEDS_FIXES

---

## Test Run

```
Tests run: 11
Passed:    11
Failed:     0
```

All 11 tests pass. The suite covers only the most basic
surface of the utility.

---

## Implemented Flags (from `date-flags.md`)

| Flag | Tier | Tested | Quality |
|------|------|--------|---------|
| `-u` | MUST | exit-code only | weak |
| `-r` | MUST | none | missing |
| `-f` | MUST | none | missing |
| `-j` | MUST | none | missing |
| `-z` | MUST | none | missing |
| `-I` | SHOULD | none | missing |
| `-R` | SHOULD | none | missing |
| `-d` | SHOULD | none | missing |
| `-n` | SHOULD | none | missing |
| `--rfc-3339` | SHOULD | none | missing |
| `-v` | SHOULD | exit-code only | weak |
| `+FORMAT` | -- | one format (`%Y`) | partial |

---

## Findings

### IMPORTANT

---

**[IMPORTANT] `-u` test is exit-code-only**
Location: `tests/utilities/date_test.sh:76`
Problem: `test_command_exit_code "date -u exits 0" 0 "$binary"
-u` checks only that the command succeeds. It does not verify
that `-u` actually causes UTC output. The field `%Z` is `GMT`
in our implementation but `UTC` in the system date. That
divergence is invisible to this test.
Fix:
```bash
local utc_out
utc_out=$("$binary" -u "+%Z" 2>/dev/null)
if [[ "$utc_out" == "UTC" || "$utc_out" == "GMT" ]]; then
    print_test_result "date -u outputs UTC/GMT zone" "PASS"
else
    print_test_result "date -u outputs UTC/GMT zone" "FAIL" \
        "Expected UTC or GMT, got '$utc_out'"
fi
```

---

**[IMPORTANT] `-v` test does not verify error message**
Location: `tests/utilities/date_test.sh:84`
Problem: Tests only check non-zero exit and empty stdout.
It does not confirm that stderr contains a diagnostic. A
crash or a silent wrong exit also passes.
Fix: Capture stderr and assert it contains the expected
stub message:
```bash
if [[ "$dv_err" =~ "not yet implemented" ]]; then
    print_test_result "date -v reports not-implemented error" "PASS"
else
    print_test_result "date -v reports not-implemented error" "FAIL" \
        "Expected error message, got: '$dv_err'"
fi
```

---

**[IMPORTANT] `-r FILE` (MUST) has no integration test**
Location: `tests/utilities/date_test.sh` (absent)
Problem: `-r` is a MUST-tier flag. There is no test for `-r`
with a real file, no test comparing the mtime output to a
known value, and no test for the error case when the file
does not exist.
Fix:
```bash
local tmpfile
tmpfile=$(mktemp "$TEMP_DIR/ref_XXXXXX")
touch -t 202401010000 "$tmpfile"
test_command_output_pattern \
    "date -r FILE outputs modification time" \
    "^[A-Z][a-z]{2} [A-Z][a-z]{2}" \
    "$binary" -r "$tmpfile"
test_command_exit_code \
    "date -r missing-file exits non-zero" 1 \
    "$binary" -r "$TEMP_DIR/nonexistent_$$"
```

---

**[IMPORTANT] `-j` (MUST) has no integration test**
Location: `tests/utilities/date_test.sh` (absent)
Problem: `-j` prevents date-setting and is required for
format-conversion workflows. Not tested at all.
Fix:
```bash
test_command_succeeds "date -j exits 0" "$binary" -j "+%Y"
```

---

**[IMPORTANT] `-f` (MUST) is a silent stub — no test exposes
it**
Location: `tests/utilities/date_test.sh` (absent),
`src/date.zig:36,164-174`
Problem: The source parses `-f` into `opts.input_fmt` but
`runDate` never reads `opts.input_fmt`. Running
`date -j -f "%Y-%m-%d" "2024-01-15" "+%Y-%m-%d"` exits 2
("extra operand") because the bare string `2024-01-15` is
rejected as a non-flag, non-format argument. No integration
test exercises this path, so the broken behavior is
invisible.
Fix (test):
```bash
local cmd_out cmd_err cmd_exit
run_command cmd_out cmd_err cmd_exit _ \
    "$binary" -j -f "%Y-%m-%d" "2024-01-15" "+%Y-%m-%d"
if [[ "$cmd_out" == "2024-01-15" ]]; then
    print_test_result "date -j -f converts date format" "PASS"
else
    print_test_result "date -j -f converts date format" "FAIL" \
        "Got: '$cmd_out' (err: '$cmd_err')"
fi
```
Note: this test will fail until the implementation is fixed.

---

**[IMPORTANT] `-z output_zone` (MUST) is a silent stub — no
test exposes it**
Location: `tests/utilities/date_test.sh` (absent),
`src/date.zig:37,177-188`
Problem: The source parses `-z` into `opts.output_zone` but
`runDate` never reads it. Running
`date -z America/New_York "+%Z"` silently outputs the local
timezone instead of `EST`/`EDT`. No test catches this.
Fix (test):
```bash
local tz_out
tz_out=$("$binary" -z UTC "+%Z" 2>/dev/null)
if [[ "$tz_out" == "UTC" || "$tz_out" == "GMT" ]]; then
    print_test_result "date -z UTC sets output timezone" "PASS"
else
    print_test_result "date -z UTC sets output timezone" "FAIL" \
        "Expected UTC/GMT, got '$tz_out'"
fi
```
Note: this test will fail until the implementation is fixed.

---

**[IMPORTANT] `-R` / `--rfc-email` (SHOULD) has no
integration test**
Location: `tests/utilities/date_test.sh` (absent)
Problem: No test verifies RFC 5322 output format
(`Www, DD Mon YYYY HH:MM:SS +ZZZZ`).
Fix:
```bash
test_command_output_pattern \
    "date -R outputs RFC 5322 format" \
    "^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\$" \
    "$binary" -R
```

---

**[IMPORTANT] `-I`/`--iso-8601` (SHOULD) has no integration
test**
Location: `tests/utilities/date_test.sh` (absent)
Problem: No test verifies ISO 8601 output for any precision
level (`date`, `hours`, `minutes`, `seconds`, `ns`).
Fix:
```bash
test_command_output_pattern \
    "date -I outputs ISO 8601 date" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}\$" \
    "$binary" -I
test_command_output_pattern \
    "date -Iseconds outputs ISO 8601 with seconds" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-]" \
    "$binary" -Iseconds
```

---

**[IMPORTANT] `--rfc-3339` (SHOULD) has no integration test**
Location: `tests/utilities/date_test.sh` (absent)
Problem: No test verifies RFC 3339 output for `date`,
`seconds`, or `ns` precision. Invalid precision value is
also untested.
Fix:
```bash
test_command_output_pattern \
    "date --rfc-3339=date outputs RFC 3339 date" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}\$" \
    "$binary" --rfc-3339=date
test_command_output_pattern \
    "date --rfc-3339=seconds outputs RFC 3339 with offset" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[+-]" \
    "$binary" --rfc-3339=seconds
test_command_exit_code \
    "date --rfc-3339=invalid exits 2" 2 \
    "$binary" --rfc-3339=invalid
```

---

**[IMPORTANT] `-d STRING` (SHOULD) has no integration test**
Location: `tests/utilities/date_test.sh` (absent)
Problem: No test for `@EPOCH` notation, ISO 8601 date
strings, or the error path for an unparseable date string.
Fix:
```bash
test_command_output \
    "date -d @0 -u +%Y-%m-%d outputs epoch date" \
    "1970-01-01" \
    "$binary" -d "@0" -u "+%Y-%m-%d"
test_command_exit_code \
    "date -d invalid-string exits non-zero" 1 \
    "$binary" -d "not-a-date"
```

---

### SUGGESTION

---

**[SUGGESTION] Default output format comparison against system
date is absent**
Location: `tests/utilities/date_test.sh:20-27`
Problem: The default-output test checks only non-emptiness.
It does not confirm the day-of-week/month/year structure that
users depend on.
Fix: Add a pattern check:
```bash
test_command_output_pattern \
    "date default output matches expected structure" \
    "^[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}" \
    "$binary"
```

---

**[SUGGESTION] `%Z` outputs `GMT` under `-u` but GNU date
outputs `UTC`**
Location: `src/date.zig` (strftime behavior)
Problem: When run with `-u`, `strftime` on this system
returns `GMT` for `%Z` rather than `UTC`. The system
`/usr/bin/date` returns `UTC`. This is a platform
difference exposed only by comparing outputs — no test
currently catches it.
Fix: Document the known divergence or normalize it in
`formatDate`. Add a note in the test so the discrepancy is
visible:
```bash
local utc_tz
utc_tz=$("$binary" -u "+%Z" 2>/dev/null)
# GNU date returns UTC; our impl may return GMT (strftime behavior)
if [[ "$utc_tz" == "UTC" ]]; then
    print_test_result "date -u +%Z returns UTC (GNU-compatible)" "PASS"
elif [[ "$utc_tz" == "GMT" ]]; then
    print_test_result "date -u +%Z returns UTC (GNU-compatible)" "FAIL" \
        "Got GMT instead of UTC — strftime divergence"
fi
```

---

**[SUGGESTION] Multi-format specifier coverage is thin**
Location: `tests/utilities/date_test.sh:64-71`
Problem: Only `%Y` is tested. Format specifiers `%s`
(epoch seconds), `%N` (nanoseconds), `%R` (RFC short time),
`%T` (time), `%z` (numeric offset), `%:z` (colon offset),
and compound formats like `+%Y-%m-%d` are all untested in
integration tests.
Fix: Add at least:
```bash
test_command_output_pattern "date +%s outputs epoch" \
    "^[0-9]{10,}\$" "$binary" "+%s"
test_command_output_pattern "date +%T outputs HH:MM:SS" \
    "^[0-9]{2}:[0-9]{2}:[0-9]{2}\$" "$binary" "+%T"
test_command_output_pattern "date +%z outputs offset" \
    "^[+-][0-9]{4}\$" "$binary" "+%z"
```

---

## Summary

| Severity | Count |
|----------|-------|
| IMPORTANT | 8 |
| SUGGESTION | 3 |

**Overall assessment: NEEDS_FIXES**

Two of the eight IMPORTANT issues are tests for **silent
stubs** in the implementation (`-z` and `-f`): the flags
are parsed but never acted upon. Tests would fail today and
should be written first (red), then the implementation
fixed (green). The remaining six IMPORTANT issues are
coverage gaps for MUST/SHOULD flags that the implementation
does support.

## Prioritized Fix List

```
Fix Order:
1. [IMPORTANT] Write test exposing -f stub bug (fails today)
   — tests/utilities/date_test.sh
2. [IMPORTANT] Write test exposing -z stub bug (fails today)
   — tests/utilities/date_test.sh
3. [IMPORTANT] Add -r FILE behavioral test
   — tests/utilities/date_test.sh
4. [IMPORTANT] Add -j behavioral test
   — tests/utilities/date_test.sh
5. [IMPORTANT] Add -R output-format test
   — tests/utilities/date_test.sh
6. [IMPORTANT] Add -I / --iso-8601 output tests
   — tests/utilities/date_test.sh
7. [IMPORTANT] Add --rfc-3339 output tests
   — tests/utilities/date_test.sh
8. [IMPORTANT] Add -d STRING behavioral tests
   — tests/utilities/date_test.sh
9. [IMPORTANT] Strengthen -u test to verify UTC output
   — tests/utilities/date_test.sh:76
10. [IMPORTANT] Strengthen -v test to verify stderr message
    — tests/utilities/date_test.sh:84
11. [SUGGESTION] Add pattern check for default output format
    — tests/utilities/date_test.sh:20-27
12. [SUGGESTION] Document/fix %Z GMT vs UTC divergence
    — src/date.zig
13. [SUGGESTION] Expand format-specifier coverage (%s %T %z)
    — tests/utilities/date_test.sh
```

REVIEW COMPLETE - NEEDS_FIXES
