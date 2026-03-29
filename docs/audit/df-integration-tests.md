# Integration Test Audit: df

**Date**: 2026-03-28
**Test file**: tests/utilities/df_test.sh
**Run result**: 13 tests, 13 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 13 tests pass. The test file covers 6 of the 10
implemented MUST-tier flags and has genuine output
verification for each (header string checks). However,
4 MUST-tier flags (-k, -l, -t, -n) have no integration
tests whatsoever. All 11 SHOULD-tier flags except -T and
--total are completely untested. The two error-condition
tests are exit-code-only, with no stderr content assertion.
The `-P` test checks for the column header `1K-blocks`
which is a good behavioral signal, but the remaining header
checks only match a single word (`"Size"`, `"Inodes"`,
`"Type"`) and would pass even with a spurious occurrence
of that word in the filesystem path.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|-------------------|---------|
| df binary | binary check | STRONG |
| df --help | exit-code 0 | WEAK |
| df --version | exit-code 0 | WEAK |
| df default output has expected header | stdout contains "Filesystem" and "Mounted on" | STRONG |
| df default shows Size header | stdout contains "Size" | ADEQUATE |
| df -P shows 1K-blocks | stdout contains "1K-blocks" | STRONG |
| df / shows root filesystem | stdout contains "/" | WEAK |
| df -h shows Size header | stdout contains "Size" | ADEQUATE |
| df -T shows Type column | stdout contains "Type" | ADEQUATE |
| df -i shows Inodes header | stdout contains "Inodes" | ADEQUATE |
| df --total shows total row | stdout contains "total" | ADEQUATE |
| df invalid flag exits 2 | exit-code 2 | WEAK |
| df nonexistent file exits 1 | exit-code 1 | WEAK |

---

## Coverage Gaps

### MUST-tier flags (from df-flags.md)

| Flag | Tested | Notes |
|------|--------|-------|
| -h   | yes    | header string only |
| -i   | yes    | header string only |
| -k   | NO     | zero tests |
| -l   | NO     | zero tests |
| -n   | NO     | zero tests |
| -P   | yes    | header "1K-blocks" checked |
| -t   | NO     | zero tests |
| -T   | yes (SHOULD) | header "Type" checked |

Note: -T is listed as SHOULD in df-flags.md, not MUST,
and is already tested. -k, -l, -n, and -t are all MUST
with zero coverage.

### SHOULD-tier flags with zero tests

All of the following are implemented (`yes` in Ours
column of df-flags.md) and have no integration test:

- `-a` (show all mount points including MNT_IGNORE)
- `-b` (512-byte blocks)
- `-c` (grand total, macOS alias for --total)
- `-g` (1 GiB blocks)
- `-H` / `--si` (SI suffixes, powers of 1000)
- `-I` (exclude filesystem type)
- `-m` (1 MiB blocks)
- `-x` (exclude filesystem type, GNU alias)
- `-Y` (include filesystem type column, macOS)
- `-,` (thousands grouping)
- `--block-size` (custom block size)
- `--output` (custom field selection)

### Long-option aliases not tested

The following long-option equivalents are implemented but
have no integration test:

- `--all` (alias for -a)
- `--human-readable` (alias for -h)
- `--inodes` (alias for -i)
- `--local` (alias for -l)
- `--portability` (alias for -P)
- `--print-type` (alias for -T)
- `--type` (alias for -t)
- `--exclude-type` (alias for -x)

---

## Issues

### [IMPORTANT] -k flag has zero integration tests
Location: tests/utilities/df_test.sh (missing section)
Problem: `-k` is MUST-tier (POSIX). The flag disables
human-readable mode and switches to 1024-byte block
counts. No integration test checks that the `1K-blocks`
header appears (as the `-P` test does) or that a numeric
value is present in the output.
Fix: Add a test that runs `df -k /` and asserts output
contains `"1K-blocks"` and a numeric block count on the
data row.

### [IMPORTANT] -l flag has zero integration tests
Location: tests/utilities/df_test.sh (missing section)
Problem: `-l` is MUST-tier. It filters the output to
locally-mounted filesystems only, which is the main
behavioral difference tested by this flag. On a typical
system there is at least one local filesystem.
Fix: Add a test that runs `df -l` and asserts exit code
0 and that output contains `"Filesystem"`. For a stronger
check, also assert that the number of rows is less than or
equal to `df` without `-l` on a system with network mounts.

### [IMPORTANT] -t flag has zero integration tests
Location: tests/utilities/df_test.sh (missing section)
Problem: `-t` is MUST-tier (POSIX). On the test platform
`df -t tmpfs` (Linux) or `df -t apfs` (macOS) should
return only filesystems of that type, or an empty list.
Fix: Add a test that runs `df -t tmpfs` on Linux and
`df -t apfs` on macOS, checking exit code 0 and that the
output contains the requested type string. Use the
existing `$PLATFORM` variable to branch.

### [IMPORTANT] -n flag has zero integration tests
Location: tests/utilities/df_test.sh (missing section)
Problem: `-n` is MUST-tier. The source code sets
`no_sync = true` but otherwise the flag should be a
no-op on most systems (returns cached stats). There is
no test that even confirms the flag is accepted without
error.
Fix: Add a test that runs `df -n /` and asserts exit
code 0 and that output contains `"Filesystem"`.

### [IMPORTANT] Error tests are exit-code-only
Location: tests/utilities/df_test.sh:111-116
Problem: The `test_command_exit_code` helper only checks
the exit code. Neither test asserts that stderr contains
a diagnostic message. A silent non-zero exit would pass.
Fix: Use `run_command` to capture stderr, then assert
it is non-empty. For the invalid-flag case also assert
the message mentions the unrecognized option name.

### [IMPORTANT] -h / -T / -i / --total tests check header
words that could match path components
Location: tests/utilities/df_test.sh:63-106
Problem: The checks `[[ "$output" =~ "Size" ]]`,
`[[ "$output" =~ "Type" ]]`, `[[ "$output" =~ "Inodes" ]]`,
and `[[ "$output" =~ "total" ]]` would pass if a mounted
filesystem path happened to contain those strings (e.g.
`/mnt/Size`, `/srv/Inodes`). The header test for `-P` is
stronger because `1K-blocks` is unlikely to appear in a
path.
Fix: Anchor the header check to the first line of output.
Capture line 1 with `head -n1` and assert it contains the
expected column header.

### [SUGGESTION] -h test is redundant with the default test
Location: tests/utilities/df_test.sh:62-70
Problem: The default output test at line 30-35 already
confirms `"Size"` appears. The `-h` test at line 62-70
passes the same assertion against `-h` output, which is
also the default mode. This provides no additional
confidence that `-h` specifically enables the mode or
changes behavior from a non-human-readable baseline.
Fix: Either add a test that first runs `df -k` (which
should show `1K-blocks`) then runs `df -h` and confirms
the header reverts to `Size`, or document the intent of
the test with a comment.

### [SUGGESTION] "df / shows root filesystem" is effectively
exit-code-only
Location: tests/utilities/df_test.sh:51-58
Problem: `[[ "$output" =~ "/" ]]` will always be true
because the filesystem column, the mount point column,
and the path argument itself all contain `/`. The test
does not verify that the output row is actually for the
root filesystem (e.g. that the `Mounted on` column shows
exactly `/`).
Fix: Check that the last field of the data row is `/`:
```bash
if echo "$output" | awk 'NR==2{print $NF}' | grep -qx '/'; then
```

---

## Strengths

- All tests have genuine output content assertions (header
  strings), not bare exit-code checks for the functional
  flags.
- The `-P` test uses the uniquely-identifying `1K-blocks`
  string, which is a strong behavioral signal.
- `--total` uses the distinctive `"total"` row label.
- Error exit codes are split correctly: 1 for missing path,
  2 for invalid flag.
- Platform-agnostic: all tested flags work on both macOS
  and Linux without branching.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Add -k behavioral test — df_test.sh (missing)
2. [IMPORTANT] Add -l behavioral test — df_test.sh (missing)
3. [IMPORTANT] Add -t behavioral test (platform-branched)
               — df_test.sh (missing)
4. [IMPORTANT] Add -n acceptance test — df_test.sh (missing)
5. [IMPORTANT] Assert stderr non-empty in error-condition
               tests — df_test.sh:111-116
6. [IMPORTANT] Anchor header checks to first output line
               — df_test.sh:63-106
7. [SUGGESTION] Strengthen "df / shows root filesystem"
               check — df_test.sh:51-58
8. [SUGGESTION] Differentiate -h test from default test
               — df_test.sh:62-70
```

REVIEW COMPLETE - NEEDS_FIXES
