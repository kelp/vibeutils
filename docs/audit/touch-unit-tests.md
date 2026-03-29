# Unit Test Audit: touch

**Date**: 2026-03-28
**Source**: `src/touch.zig`
**Tests run**: 22 total; all 22 pass (7s wall time)

## Executive Summary

NEEDS_FIXES

The touch unit tests have good behavioral coverage for the core
MUST flags (-a, -c, -m, -r, -d). However, two `parseTimestamp`
tests are parse-only (check `sec > 0` instead of the actual epoch
value), and the `-t` behavioral test is weak for the same reason.
The SHOULD flag `-h` has zero unit tests. Three `--time=WORD`
aliases (`atime`, `use`, `mtime`) are untested. The `runTouch`
error paths have no direct unit coverage. Six tests each sleep
1 second, producing a 7-second suite runtime that will compound
as the suite grows.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| touch creates new file | Yes — verifies file exists after creation | PASS |
| touch updates existing file timestamp | Yes — sleeps, checks mtime increased | PASS |
| touch -c does not create file | Yes — verifies file absent after -c | PASS |
| touch -a updates only access time | Yes — verifies atime up, mtime preserved | PASS |
| touch -m updates only modification time | Yes — verifies mtime up, atime preserved | PASS |
| touch -r uses reference file times | Yes — verifies target matches reference | PASS |
| parseTimestamp with full format CCYYMMDDhhmm.ss | No — only checks `sec > 0`, not value | STUB |
| parseTimestamp with YYMMDDhhmm format | No — only checks `sec > 0`, not value | STUB |
| parseTimestamp with invalid format | Yes — verifies error returns | PASS |
| touch --time=access updates only access time | Yes — verifies atime up, mtime preserved | PASS |
| touch --time=modify updates only modification time | Yes — verifies mtime up, atime preserved | PASS |
| touch multiple files | Yes — verifies both files exist | PASS |
| touch with -t timestamp | Weak — checks file exists and `mtime > 0` only | WEAK |
| touch: -A flag is accepted with warning | Yes — verifies exit != 0 and stderr message | PASS |
| touch: -d flag is parsed by argparser | No — only checks exit code 0, no value | STUB |
| touch: -d with ISO date sets timestamp | Yes — verifies exact epoch value | PASS |
| touch: -d with date and time sets timestamp | Yes — verifies exact epoch value | PASS |
| touch: -d with invalid date gives error | Yes — verifies exit code 1 | PASS |
| touch: -d with space-separated datetime | Yes — verifies exact epoch value | PASS |
| touch: -A flag should exit non-zero because it is unimplemented | Yes — exit != 0 | PASS |
| touch: -A flag stderr mentions unimplemented or unsupported | Yes — stderr text check | PASS |
| touch: -A flag should not modify file timestamps | Yes — verifies timestamps unchanged | PASS |

---

## Issues

---

### [CRITICAL] `parseTimestamp` tests are parse-only — wrong epoch uncatchable

**Location**: `src/touch.zig:753` and `src/touch.zig:761`

**Problem**: Both `parseTimestamp` tests only assert `result.sec > 0`.
An off-by-year bug in `daysFromYMD`, a wrong century rule, or a
sign error in the accumulation would produce an incorrect but
positive epoch value and these tests would still pass. The full
12-digit format (CCYYMMDDhhmm) is the canonical -t path; an
undetected bug there means `-t` silently sets the wrong time.

**Fix**: Assert the exact expected epoch in each test. For the full
format test:

```zig
// 2023-12-31 13:59:45 UTC = 1704031185 seconds since epoch
const result = try parseTimestamp("202312311359.45");
try testing.expectEqual(@as(i64, 1704031185), result.sec);
try testing.expectEqual(@as(i64, 0), result.nsec);
```

For the YY-format test (YY=23 → 2023, YY=99 → 1999):

```zig
// 2023-12-31 13:59:00 UTC
const result1 = try parseTimestamp("2312311359");
try testing.expectEqual(@as(i64, 1704031140), result1.sec);
// 1999-12-31 13:59:00 UTC
const result2 = try parseTimestamp("9912311359");
try testing.expectEqual(@as(i64, 946649940), result2.sec);
```

---

### [CRITICAL] `touch with -t timestamp` does not verify the applied timestamp

**Location**: `src/touch.zig:856`

**Problem**: The test uses `timestamp_str = "202312311359.00"` but
only asserts `stat.mtime > 0`. This is equivalent to a parse-only
test: any positive timestamp (including the current time) would
pass. If `parseTimestamp` returns the right value but
`touchFileWithTimes` applies `times[1]` incorrectly, this test
would still pass.

**Fix**: Assert the exact expected modification time after the call:

```zig
// 2023-12-31 13:59:00 UTC = 1704031140 seconds since epoch
const stat = try common.file.FileInfo.stat(test_file);
const expected_ns: i128 = 1704031140 * std.time.ns_per_s;
try testing.expectEqual(expected_ns, stat.mtime);
```

---

### [IMPORTANT] `-h` / `--no-dereference` flag has zero unit tests

**Location**: `src/touch.zig` — `no_dereference` field, flag tier SHOULD

**Problem**: The `AT_SYMLINK_NOFOLLOW` path in `updateFileTimes`
(line 324) is never exercised in unit tests. A regression that
removes the flag or inverts the condition would go undetected
at the unit level.

**Fix**: Add a unit test using `testing.tmpDir`, create a symlink,
and verify that with `no_dereference = true` the symlink's own
mtime changes (or that the target's mtime does not change):

```zig
test "touch -h changes symlink not target" {
    // create target, create symlink to target, record both mtimes,
    // sleep 1s, touchFile with no_dereference = true,
    // verify symlink mtime changed and target mtime preserved
}
```

---

### [IMPORTANT] `--time=WORD` aliases `atime`, `use`, and `mtime` are untested

**Location**: `src/touch.zig:239-254`

**Problem**: The implementation accepts five WORD values: `access`,
`atime`, `use`, `modify`, `mtime`. Only `access` and `modify` have
behavioral unit tests. The three untested aliases share the same
code paths, but a future refactor (e.g., a `std.mem.eql` call
accidentally removed) would break them silently.

**Fix**: Add one test each for `atime`, `use`, and `mtime` using the
same pattern as the existing `--time=access` and `--time=modify`
tests.

---

### [IMPORTANT] `runTouch` error paths have no unit tests

**Location**: `src/touch.zig:73` — `runTouch` function

**Problem**: Three misuse paths in `runTouch` have no direct unit
coverage:

1. Unknown flag → `error.UnknownFlag` → exit code 2, stderr message
2. Missing flag value → `error.MissingValue` → exit code 2
3. No file operand → `files.len == 0` → exit code 2

These are simple `runTouch` calls with a captured `stderr_buffer`
and an `expectEqual` on exit code plus a message substring check.
Without them, a regression in error message text or exit code
would only surface in integration tests.

**Fix**: Add three tests calling `runTouch` directly:

```zig
test "touch: unknown flag returns misuse exit code" {
    const args = [_][]const u8{"--no-such-flag", "x.txt"};
    const exit_code = try runTouch(testing.allocator, &args, ...);
    try testing.expectEqual(@as(u8, 2), exit_code);
}
test "touch: no files returns misuse exit code" {
    const args = [_][]const u8{};
    const exit_code = try runTouch(testing.allocator, &args, ...);
    try testing.expectEqual(@as(u8, 2), exit_code);
}
```

---

### [IMPORTANT] `touch: -d flag is parsed by argparser` is a parse-only test

**Location**: `src/touch.zig:907`

**Problem**: The test name says "parsed by argparser" and only
checks exit code 0. `touch: -d with ISO date sets timestamp`
(line 926) already covers this case behaviorally, so this test
adds no signal. If it were deleted it would not reduce coverage.
Left in place, it adds noise and misleads reviewers counting
behavioral tests.

**Fix**: Either delete this test (the behavioral test below it
covers the same path) or fold it into that test.

---

### [SUGGESTION] Six 1-second sleeps add ~6s to the unit test suite

**Location**: `src/touch.zig:622, 671, 702, 737, 797, 821`

**Problem**: Each behavioral test that verifies a timestamp
increased calls `std.Thread.sleep(1_000_000_000)`. With six
such tests the suite already takes 7 seconds. Adding more
behavioral tests will push this further.

**Fix**: Instead of waiting for wall-clock time, use `-t` or
`-d` to apply a known past timestamp to a file before recording
`stat_before`, then apply a different known timestamp and compare.
This eliminates the sleep entirely:

```zig
// Set a known past timestamp
const options_before = TouchOptions{ .timestamp_str = "202001010000.00" };
try touchFile(test_file, options_before, testing.allocator);
const stat_before = try common.file.FileInfo.stat(test_file);

// Now touch with current time (no options)
const options = TouchOptions{};
try touchFile(test_file, options, testing.allocator);
const stat_after = try common.file.FileInfo.stat(test_file);
try testing.expect(stat_after.mtime > stat_before.mtime);
```

---

## Flag Coverage Summary

| Flag | Tier | Has behavioral unit test? |
|------|------|--------------------------|
| -a | MUST | Yes |
| -c | MUST | Yes |
| -d | MUST | Yes (exact value) |
| -m | MUST | Yes |
| -r | MUST | Yes |
| -t | MUST | Weak (no exact value check) |
| -A | SHOULD | Yes (stub behavior) |
| -f | SHOULD | None needed (no-op) |
| -h | SHOULD | No |
| --time=access | SHOULD | Yes |
| --time=atime | SHOULD | No |
| --time=use | SHOULD | No |
| --time=modify | SHOULD | Yes |
| --time=mtime | SHOULD | No |

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 4 |
| SUGGESTION | 1 |

**Overall**: NEEDS_FIXES

---

## Fix Order

```
Fix Order:
1. [CRITICAL] parseTimestamp tests are parse-only (sec > 0 only)
   — src/touch.zig:753, 761
2. [CRITICAL] touch with -t timestamp does not verify applied value
   — src/touch.zig:856
3. [IMPORTANT] -h flag has zero unit tests
   — src/touch.zig (no test exists)
4. [IMPORTANT] --time= aliases atime/use/mtime untested
   — src/touch.zig:239-254
5. [IMPORTANT] runTouch error paths (unknown flag, missing operand) untested
   — src/touch.zig:73
6. [IMPORTANT] "-d flag is parsed by argparser" is a redundant parse-only test
   — src/touch.zig:907
7. [SUGGESTION] Replace 1-second sleeps with known-timestamp comparison
   — src/touch.zig:622, 671, 702, 737, 797, 821
```

REVIEW COMPLETE - NEEDS_FIXES
