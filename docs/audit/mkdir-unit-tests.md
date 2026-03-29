---
name: mkdir unit test audit
description: 2026-03-28 unit test audit for src/mkdir.zig; 24 tests; 0
  parse-only stubs; strong behavioral coverage with one important gap
type: project
---

# mkdir Unit Test Audit

**Date:** 2026-03-28
**File:** `src/mkdir.zig`
**Test count:** 24
**Status:** NEEDS_FIXES

## Test Inventory

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | mkdir creates single directory | YES | opens dir to verify |
| 2 | mkdir with parents flag creates directory tree | YES | verifies parent and child |
| 3 | mkdir with verbose flag prints creation messages | YES | checks stdout content |
| 4 | mkdir with mode flag sets permissions | YES | stat and check mode bits |
| 5 | mkdir fails for existing directory without parents flag | YES | exit 1 + stderr check |
| 6 | mkdir with parents flag succeeds for existing directory | YES | exit 0 |
| 7 | mkdir fails with missing operand | YES | exit 2 + stderr content |
| 8 | mkdir shows help with -h flag | YES | stdout content |
| 9 | mkdir shows version with -V flag | YES | stdout content |
| 10 | mkdir handles invalid mode | YES | exit 1 + stderr content |
| 11 | mkdir combines parents and verbose flags | YES | exit 0 + stdout check |
| 12 | mkdir handles multiple directories | YES | verifies all 3 created |
| 13 | parseMode handles valid octal modes | YES | direct function call |
| 14 | parseMode rejects invalid modes | YES | error type assertion |
| 15 | mkdir handles paths with double slashes | YES | verifies normalized path |
| 16 | mkdir handles paths with dot components | YES | verifies resolved path |
| 17 | mkdir verbose with parents shows directory creation | YES | stdout pattern |
| 18 | mkdir with mode applies to all created directories with -p | PARTIAL | only verifies dir exists, not mode |
| 19 | mkdir -pv prints each intermediate directory | YES | checks all three paths in output |
| 20 | mkdir -pm sets mode on intermediate directories | YES | stat both dirs |
| 21 | mkdir -pm sets mode on all directories including first parent | YES | stat all three levels |
| 22 | mkdir -p handles absolute-like paths | YES | tmpDir + realpath |
| 23 | mkdir -p with trailing slashes | YES | verifies directory created |
| 24 | mkdir error for existing directory uses POSIX-style message | YES | checks "File exists" not "PathAlreadyExists" |

## Issues Found

### [IMPORTANT] Test 18 does not verify mode on -pm with shallow path

**Location:** `src/mkdir.zig:534-554`

**Problem:** "mkdir with mode applies to all created directories with -p" only
opens the directory to confirm existence. The comment says "mode testing
would require platform-specific code" but tests 20 and 21 do exactly
that with `std.fs.cwd().statFile`. This test does not verify any modes
are actually set and provides no coverage value beyond what tests 20/21
already cover.

**Fix:** Either assert modes via `statFile` (following the pattern in
tests 20 and 21) or remove the test as redundant.

### [IMPORTANT] GNU behavior: -m does not apply to intermediate -p directories

**Location:** `src/mkdir.zig:271-281` (createPathComponents)

**Problem:** GNU mkdir documents that `-p` with `-m` applies the mode
only to the final directory, not to intermediate parent directories:

```
with their file modes unaffected by any -m option
```

The code and tests 20, 21 actively assert that `-pm` sets the mode on
ALL intermediate directories, which contradicts GNU behavior. This is a
behavioral divergence that tests are encoding as correct.

**Fix:** The programmer must decide whether to match GNU (mode only on
leaf) or the current behavior. If matching GNU, tests 20 and 21 need to
be rewritten to assert that intermediate directories have their default
umask-based mode, not the `-m` value. The current tests are locking in
non-GNU behavior.

### [SUGGESTION] No test for runUtility unknown flag error path

**Location:** `src/mkdir.zig:74-80`

**Problem:** The `error.UnknownFlag` / `error.MissingValue` /
`error.InvalidValue` branch returns exit code 2 with "invalid argument"
on stderr. There is no unit test exercising this path via `runUtility`.
The integration tests cover it, but unit coverage is absent.

**Fix:** Add a test:
```zig
test "mkdir rejects unknown flag" {
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    const args = [_][]const u8{"-z"};
    const result = try runUtility(testing.allocator, &args, common.null_writer,
                                   stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "invalid argument") != null);
}
```

## Summary

- 24 tests, all behavioral (0 parse-only stubs)
- No stdin hang risk (mkdir is not a filter utility)
- One test is a near-no-op (test 18)
- One important behavioral divergence from GNU is locked in by tests 20
  and 21: `-pm` mode is applied to all intermediate dirs, but GNU
  explicitly documents that `-p` leaves intermediate dirs' modes
  unaffected by `-m`

## Fix Order

1. [IMPORTANT] Resolve GNU -m + -p behavior divergence and rewrite
   tests 20 and 21 accordingly — `src/mkdir.zig:573-622`
2. [IMPORTANT] Add behavioral assertion to test 18 or remove it —
   `src/mkdir.zig:534`
3. [SUGGESTION] Add unit test for unknown-flag error path —
   `src/mkdir.zig:74`

**REVIEW COMPLETE - NEEDS_FIXES**
