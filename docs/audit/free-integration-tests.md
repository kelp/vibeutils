# Integration Test Audit: free

**Date:** 2026-03-28
**File:** `tests/utilities/free_test.sh`
**Result:** NEEDS_FIXES

## Test Counts

- Total tests: 16
- Passed: 16
- Failed: 0
- Exit-code-only stubs: 5 (`-b`, `-k`, `-m`, `-g`, `-h`)
- Flags with zero integration tests: `--si`, `-s`, `-c`, `-V`

---

## Test Inventory

| Test | What is verified | Verdict |
|------|-----------------|---------|
| `free binary` | Binary exists | OK |
| `free --help` | Exits 0, "Usage" in output | OK |
| `free --version` | Exits 0, "free" in output | OK |
| `free default output contains Mem: and Swap:` | Regex on combined output | OK |
| `free header contains total/used/free` | Regex match on combined output | WEAK (see below) |
| `free --help shows usage` | Exit 0 + "Usage" | Duplicate of basic flag test; OK |
| `free --version shows version` | Exit 0 + "free" | OK |
| `free -b exits 0` | Exit code only | STUB |
| `free -k exits 0` | Exit code only | STUB |
| `free -m exits 0` | Exit code only | STUB |
| `free -g exits 0` | Exit code only | STUB |
| `free -h exits 0` | Exit code only | STUB |
| `free -h shows unit suffixes` | Regex `[KMGT]i` or `[0-9]B` | WEAK (see below) |
| `free -t shows Total line` | "Total:" in output | OK |
| `free -w shows buffers and cache` | "buffers" and "cache" in output | OK |
| `free invalid flag exits 2` | Exit code 2 | OK |

---

## Issues

### [IMPORTANT] Unit flags `-b`, `-k`, `-m`, `-g` are exit-code-only stubs
Location: `tests/utilities/free_test.sh:66-78`
Problem: Five `test_command_exit_code` calls verify only that the
binary exits 0 with each unit flag. A regression that silently ignored
`-b` and emitted kibi output instead would pass. The unit flag exists
to change numeric output; not verifying the numbers means the flag is
untested.
Fix: Capture output and assert the numeric scale is appropriate. For
`-b`, the total value should be well above 1,000,000,000 on any
modern machine. For `-k` (default), the total should be in the
millions. For `-m`, the total should be in the thousands. For `-g`,
the total should be a small integer. Use a numeric comparison, e.g.:

```bash
local val
val=$(free -m | awk '/^Mem:/{print $2}')
[[ "$val" -gt 100 && "$val" -lt 1000000 ]] || ...
```

### [IMPORTANT] `-h` human-readable regex is too loose
Location: `tests/utilities/free_test.sh:85`
Problem: The check `[KMGT]i || [0-9]B` matches any line containing
those patterns. On a machine with very small or very large memory this
could match a column header or label rather than a data value. The
test does not verify the pattern appears on the `Mem:` data row.
Fix: Parse the Mem: row specifically and check it contains a suffix.
Example:

```bash
local mem_line
mem_line=$(free -h | grep '^Mem:')
[[ "$mem_line" =~ [KMGT]i ]] || print_test_result ... "FAIL"
```

### [IMPORTANT] Header column check uses an unanchored regex on all output
Location: `tests/utilities/free_test.sh:30-35`
Problem: The check `[[ "$output" =~ total && "$output" =~ used && \
"$output" =~ free ]]` matches anywhere in the multiline string,
including in error messages or label substrings. It does not verify
that "total", "used", and "free" all appear on the same header line, or
that their column positions are correct.
Fix: Extract the first line (the header) and check it:

```bash
local header
header=$(echo "$output" | head -1)
[[ "$header" =~ total ]] && [[ "$header" =~ used ]] && ...
```

### [IMPORTANT] `--si` flag has zero integration tests
Location: `tests/utilities/free_test.sh` (absent)
Problem: The `--si` flag switches divisors from 1024 to 1000, changing
all numeric output. It has no integration test at all — not even an
exit-code check.
Fix: Add a test that runs `free --si -k` and `free -k`, captures the
Mem: total from both, and verifies the SI value is slightly larger than
the IEC value (SI kilobytes are smaller units, so more of them).

### [IMPORTANT] `-s` and `-c` continuous mode has zero integration tests
Location: `tests/utilities/free_test.sh` (absent)
Problem: `-s N` (repeat every N seconds) and `-c N` (repeat N times)
are SHOULD-tier flags with no tests whatsoever. The combination
`-s 1 -c 2` should produce two outputs separated by a blank line.
Fix: Add a test for `free -s 1 -c 2` that verifies the output contains
two `Mem:` lines and at least one blank line separator between them.
Use a short interval to keep test time low.

### [SUGGESTION] `-V` (short version flag) has no integration test
Location: `tests/utilities/free_test.sh` (absent)
Problem: `--version` is tested but `-V` is not. The two code paths
both set `parsed.version = true`, but the short flag should be
explicitly exercised at the integration level.
Fix: Add `test_command_exit_code "free -V exits 0" 0 "$binary" -V`
and verify the output contains "free".

### [SUGGESTION] `-w` test does not verify column layout
Location: `tests/utilities/free_test.sh:108-114`
Problem: The test checks that "buffers" and "cache" appear in output,
but does not verify they appear as separate columns in the header (as
opposed to the default merged "buff/cache" column).
Fix: Check that the header line contains "buffers" and "cache" as
distinct tokens, and that it does NOT contain "buff/cache".

```bash
local header
header=$(echo "$wide_output" | head -1)
[[ "$header" =~ buffers && "$header" =~ cache ]] &&
    [[ ! "$header" =~ buff/cache ]] || ...
```

### [SUGGESTION] Numeric sanity test missing for default output
Location: `tests/utilities/free_test.sh` (absent)
Problem: The default output test verifies only that "Mem:" and "Swap:"
lines are present. No test checks that the Mem: total is a plausible
memory value (e.g. > 0 kibibytes, not a garbage number).
Fix: Add a check that the value in the total column of the Mem: row
is a positive integer above a conservative threshold (e.g. > 1024
kibibytes = 1 MiB), ruling out zero or corrupt output.

---

## Summary

16/16 tests pass. 5 of the 16 tests are exit-code-only stubs for unit
flags (`-b`, `-k`, `-m`, `-g`, `-h`). Three important flags (`--si`,
`-s`, `-c`) have no integration coverage at all. Two structural checks
(header columns, human suffix) use over-broad regexes that would not
catch misformatted output. The `-V` short version flag is also absent.
