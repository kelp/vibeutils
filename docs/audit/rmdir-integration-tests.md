---
name: rmdir integration test audit
description: 2026-03-28 integration test audit for rmdir; 45/45 pass;
  verbose message format not verified; -p with absolute paths documented
  workaround masks one gap
type: project
---

# rmdir Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/rmdir_test.sh`
**Test count:** 45
**Passed:** 45
**Status:** NEEDS_FIXES

## Coverage by Flag / Feature

| Feature | Covered | Notes |
|---------|---------|-------|
| Remove empty dir | YES | verified absent |
| Fail on non-empty | YES | verified preserved |
| Non-empty error message | YES | "not empty" / "Directory not empty" |
| Missing operand | YES | exit 2 + message |
| `-p` / `--parents` | YES | full chain removed |
| `-p` stops on non-empty | YES | exact state verified |
| `--ignore-fail-on-non-empty` | YES | 3 sub-cases |
| `--ignore-fail-on-non-empty` no stderr | YES | |
| `-p --ignore-fail-on-non-empty` | YES | graceful stop |
| `-v` / `--verbose` | YES | "removing directory" in stdout |
| `--verbose` long option | YES | |
| `-pv` verbose per-level | YES | weak (path substring only) |
| Multiple dirs | YES | all verified absent |
| Mixed empty/non-empty | YES | empty removed, non-empty preserved |
| Nonexistent dir | YES | exit 1 + message |
| File instead of dir | YES | exit 1 + "Not a directory" |
| Invalid flag | YES | exit 2 |
| Trailing slash | YES | |
| Special characters | YES | |
| Spaces in name | YES | |
| Unicode | YES | locale-gated |
| `-pv` combined | YES | |
| `-v --ignore-fail-on-non-empty` | YES | exit 0 only |
| POSIX exit codes | YES | 0 success, 1 failure |
| Refuse `.` | YES | "refusing" in stderr |
| Refuse `..` | YES | "refusing" in stderr |

## Issues Found

### [IMPORTANT] `-pv` verbose output check is a substring match, not format check

**Location:** `tests/utilities/rmdir_test.sh:193` and `318`

**Problem:** Both `-pv` tests check:
```bash
if [[ "$vp_out" =~ "a/b" && "$vp_out" =~ removing.*directory ]]; then
```
and
```bash
if [[ "$pv_out" =~ "removing directory" && ! -d "$pv_base/x/y" ]]; then
```

These checks confirm the directory path appears and the phrase
"removing directory" is somewhere in the output, but do not verify the
exact GNU format: `rmdir: removing directory, 'PATH'`.
A regression that drops the program name prefix or changes the
punctuation (e.g., omitting the comma) would not be caught.

**Fix:**
```bash
if [[ "$vp_out" == *"rmdir: removing directory, '$pv_base/x/y'"* && \
      ! -d "$pv_base/x/y" ]]; then
```

### [IMPORTANT] `-pv` shows each removal — test does not verify intermediate paths

**Location:** `tests/utilities/rmdir_test.sh:191-197`

**Problem:** The test for "rmdir -pv shows each removal" uses path
`$verb_parent_base/a/b` and only checks that `"a/b"` appears in output.
It does not verify that the intermediate path `a` also appears (i.e.,
that the parent chain produces two separate verbose lines).

**Fix:** Add a check that the parent path is also present:
```bash
if [[ "$vp_out" =~ "a/b" && "$vp_out" =~ "a'" && "$vp_out" =~ removing.*directory ]]; then
```
Or, preferably, use exact message matching for each line.

### [IMPORTANT] `-v --ignore-fail-on-non-empty` test only checks exit code

**Location:** `tests/utilities/rmdir_test.sh:331-336`

**Problem:**
```bash
if [[ $vi_exit -eq 0 ]]; then
    print_test_result "rmdir -v --ignore-fail-on-non-empty" "PASS"
```

When the directory is non-empty and `--ignore-fail-on-non-empty` is
set, the verbose flag should not print "removing directory" because the
directory was not removed. The test does not verify that no verbose
message is emitted for a non-removed directory.

**Fix:** Assert that `$vi_out` does not contain "removing directory"
when the directory was not actually removed.

### [SUGGESTION] `-p` with absolute paths uses `|| true` workaround

**Location:** `tests/utilities/rmdir_test.sh:78`

**Problem:** The test comment documents that `-p` with absolute paths
returns exit 1 because it eventually tries (and fails) to remove a
non-empty ancestor. The test works around this by calling the binary
directly without a test assertion:
```bash
"$binary" -p "$parent_base/a/b/c" >/dev/null 2>&1
```

This means no assertion is made about the exit code at all. If the
binary returns exit 0 or exit 2, the test still passes.

**Fix:** Assert exit 1 explicitly (since GNU rmdir exits 1 when it
stops at a non-empty parent), then verify the target chain was removed:
```bash
test_command_exit_code "rmdir -p removes parent chain" 1 "$binary" -p "$parent_base/a/b/c"
```

### [SUGGESTION] No test for `rmdir` refusing bare `.` without `-p`

**Location:** `tests/utilities/rmdir_test.sh` (gap)

**Problem:** The refuse-`.`/`..` regression tests use the `-p` flag.
The implementation's `.`/`..` guard in `removeDirectories` runs
regardless of whether `-p` is set. There is no test for `rmdir .` or
`rmdir ..` without `-p`.

**Fix:** Add tests for bare `rmdir .` and `rmdir ..` (without `-p`).

## What Is NOT Tested

- Concurrent removal of multiple dirs where one fails mid-list: the
  test "mixed empty/non-empty" covers this partially but stops at the
  boundary between three dirs, not at a middle failure
- Very long path names
- Deeply nested `-p` chains (more than 3 levels)

## Summary

- 45/45 tests pass
- Coverage is broadly good for a simple utility
- Main weakness is verbose-output assertions using substring checks
  rather than the full message format
- One test uses a raw binary call with no assertion instead of
  `test_command_exit_code` (the `-p` absolute path case)

## Fix Order

1. [IMPORTANT] Strengthen `-pv` verbose format checks to full message
   pattern — `tests/utilities/rmdir_test.sh:193` and `318`
2. [IMPORTANT] Verify intermediate paths in `-pv` per-level test —
   `tests/utilities/rmdir_test.sh:191`
3. [IMPORTANT] Verify verbose not emitted when dir not removed under
   `--ignore-fail-on-non-empty` — `tests/utilities/rmdir_test.sh:331`
4. [SUGGESTION] Assert exit 1 for `-p` absolute-path test —
   `tests/utilities/rmdir_test.sh:78`
5. [SUGGESTION] Add `rmdir .` and `rmdir ..` tests without `-p` flag —
   `tests/utilities/rmdir_test.sh` (gap)

**REVIEW COMPLETE - NEEDS_FIXES**
