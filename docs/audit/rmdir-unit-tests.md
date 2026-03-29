---
name: rmdir unit test audit
description: 2026-03-28 unit test audit for src/rmdir.zig; 14 tests; 0
  parse-only stubs; strong behavioral coverage with one weak verbose check
type: project
---

# rmdir Unit Test Audit

**Date:** 2026-03-28
**File:** `src/rmdir.zig`
**Test count:** 14
**Status:** NEEDS_FIXES

## Test Inventory

All 14 tests call internal functions directly (`removeDirectories`,
`runRmdir`, `ParentIterator`, `formatError`) — none are parse-only
stubs.

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | rmdir: remove empty directory | YES | verifies deletion via statFile |
| 2 | rmdir: fail on non-empty directory | YES | exit general_error + dir preserved |
| 3 | rmdir: ignore fail on non-empty with flag | YES | exit success + dir preserved |
| 4 | rmdir: verbose output | PARTIAL | checks path name in stdout but not "removing directory" phrase |
| 5 | rmdir: remove with parents | YES | all three levels verified absent |
| 6 | rmdir: multiple directories | YES | verifies all 3 deleted |
| 7 | rmdir: error on non-existent directory | YES | exit general_error |
| 8 | rmdir: error on file instead of directory | YES | exit general_error + file preserved |
| 9 | rmdir: parents stops on error | YES | deep removed, sub and base remain |
| 10 | rmdir: unicode path handling | YES | creates + removes unicode dir |
| 11 | rmdir: parent iterator memory management | YES | walks all parent levels |
| 12 | rmdir: error message consistency | YES | formatError table |
| 13 | rmdir: -p dotdot should fail with refusing message | YES | exit != 0 + "refusing" in stderr |
| 14 | rmdir: -p dot should fail with refusing message | YES | exit != 0 + "refusing" in stderr |

## Issues Found

### [IMPORTANT] Test 4 verbose output assertion is too weak

**Location:** `src/rmdir.zig:352-353`

**Problem:**
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_rmdir_verbose") != null);
```

This only checks that the directory name appears in stdout. It does not
verify the message format `"rmdir: removing directory, 'test_rmdir_verbose'"`.
The implementation at line 221 outputs:
```zig
try stdout_writer.print("rmdir: removing directory, '{s}'\n", .{path});
```

A regression that changes the verb (e.g., "removed" instead of
"removing directory,") would not be caught.

**Fix:**
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items,
    "rmdir: removing directory, 'test_rmdir_verbose'") != null);
```

### [IMPORTANT] No unit test for verbose output with `-p` (parent removal messages)

**Location:** `src/rmdir.zig` (gap)

**Problem:** Test 5 (`remove with parents`) uses verbose and checks
that each of the three path strings appears in stdout. However, the
check is for the path strings only (same weak pattern as test 4), not
for the full "rmdir: removing directory, 'X'" message per level.

**Fix:** Add stronger assertions to test 5:
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items,
    "rmdir: removing directory, 'test_rmdir_parents/sub/deep'") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items,
    "rmdir: removing directory, 'test_rmdir_parents/sub'") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items,
    "rmdir: removing directory, 'test_rmdir_parents'") != null);
```

### [IMPORTANT] No unit test for `runRmdir` / `runUtility` error message format

**Location:** `src/rmdir.zig` (gap)

**Problem:** Tests 7 and 8 verify exit codes but do not check the
`stderr_buffer` content for the expected error message format
(`"rmdir: failed to remove 'X': No such file or directory"`). A
regression that changes the error message format would not be caught at
the unit level.

**Fix:** Add stderr content assertions to tests 7 and 8.

### [SUGGESTION] Tests 13 and 14 use `exit_code != 0` rather than a specific value

**Location:** `src/rmdir.zig:556` and `src/rmdir.zig:571`

**Problem:**
```zig
try testing.expect(exit_code != 0);
```

GNU rmdir returns exit 1 for this error. The test accepts any non-zero
exit code. Using a general inequality is less precise than asserting
the expected value.

**Fix:**
```zig
try testing.expectEqual(@as(u8, 1), exit_code);
```

### [SUGGESTION] ParentIterator test does not test root stop condition for absolute paths

**Location:** `src/rmdir.zig:511-536`

**Problem:** Test 11 uses the relative path `"a/b/c/d/e"` and verifies
the iterator stops at `"a"`. The stop condition in `ParentIterator.next`
also stops when `parent == "/"`. This branch is never exercised by any
unit test.

**Fix:** Add a test case with an absolute path to verify the iterator
stops at root without returning `"/"`.

## Summary

- 14 tests, all behavioral (0 parse-only stubs)
- No stdin hang risk (rmdir is not a filter utility)
- Verbose output assertions are consistently too weak (path name only,
  not full message format)
- Error message stderr content is untested at the unit level
- Exit code precision is weak in tests 13 and 14

## Fix Order

1. [IMPORTANT] Strengthen verbose assertion in test 4 to full message
   format — `src/rmdir.zig:352`
2. [IMPORTANT] Strengthen verbose assertions in test 5 (`-p` verbose)
   — `src/rmdir.zig:381-383`
3. [IMPORTANT] Add stderr content assertions to tests 7 and 8 —
   `src/rmdir.zig:417-451`
4. [SUGGESTION] Use exact exit code in tests 13 and 14 —
   `src/rmdir.zig:556,571`
5. [SUGGESTION] Add absolute-path test to ParentIterator —
   `src/rmdir.zig:511`

**REVIEW COMPLETE - NEEDS_FIXES**
