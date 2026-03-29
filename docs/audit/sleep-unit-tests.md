# sleep Unit Test Audit

**Date:** 2026-03-28
**File:** `src/sleep.zig`
**Tests:** 24 declared; all 24 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Notes |
|---|-----------|------|-------|
| 1 | `parseTimeString - basic integer seconds` | behavioral | delegates to common/time.zig |
| 2 | `parseTimeString - decimal seconds` | behavioral | delegates to common/time.zig |
| 3 | `parseTimeString - seconds with suffix` | behavioral | delegates to common/time.zig |
| 4 | `parseTimeString - minutes` | behavioral | delegates to common/time.zig |
| 5 | `parseTimeString - hours` | behavioral | delegates to common/time.zig |
| 6 | `parseTimeString - days` | behavioral | delegates to common/time.zig |
| 7 | `parseTimeString - invalid formats` | behavioral | delegates to common/time.zig |
| 8 | `parseTimeString - reject NaN and Inf` | behavioral | delegates to common/time.zig |
| 9 | `parseTimeString - negative values` | behavioral | delegates to common/time.zig |
| 10 | `parseTotalTime - single arguments` | behavioral | good |
| 11 | `parseTotalTime - multiple arguments sum` | behavioral | good |
| 12 | `parseTotalTime - no arguments` | behavioral | error path |
| 13 | `parseTotalTime - invalid arguments` | behavioral | error path |
| 14 | `runSleep - help option` | behavioral | checks output content |
| 15 | `runSleep - version option` | behavioral | checks output content |
| 16 | `runSleep - missing arguments` | behavioral | checks exit 2 + stderr |
| 17 | `runSleep - invalid time format` | behavioral | checks exit 2 + stderr |
| 18 | `runSleep - negative time (with separator)` | behavioral | checks exit 2 + stderr |
| 19 | `runSleep - negative flag treated as unknown argument` | behavioral | checks exit 2 + stderr |
| 20 | `runSleep - zero seconds (should succeed immediately)` | behavioral | fast |
| 21 | `runSleep - very small sleep time` | behavioral | wall-clock timing check |
| 22 | `runSleep - multiple time arguments` | behavioral | accepts multiple args |
| 23 | `runSleep - zero sleep with captured output` | behavioral | allocator safety net |
| 24 | `TimeUnit.toNanos - verify unit conversions` | behavioral | delegates to common/time.zig |

---

## Findings

### [IMPORTANT] `runSleep - very small sleep time` uses wall-clock timing with a fragile upper bound

**Location:** `src/sleep.zig:329-337`

```zig
try testing.expect(end_time - start_time < 100);
```

This test asserts that a 1 ms sleep finishes in less than 100 ms. On a heavily loaded CI machine this can flake — `sleep(1ms)` can take >100 ms if the OS scheduler is under load. The upper bound is 100× the requested sleep, which is generous but not impossible to exceed in containerized CI environments.

Additionally the test asserts `result == 0` but does not assert anything about how long the process actually slept (i.e., it could return immediately without sleeping and this test would still pass).

**Fix:** Either remove the wall-clock assertion and rely on exit-code-only checking, or widen the bound significantly (e.g., 1000 ms) with a comment explaining it is a hang detection guard, not a performance test.

---

### [IMPORTANT] `TimeOverflow` error path in `parseTotalTime` has no `runSleep` test

**Location:** `src/sleep.zig:118-121`

`parseTotalTime` returns `error.TimeOverflow` when the sum would overflow `u64`. The `runSleep` function maps this to `"invalid time interval: value too large"`. No test exercises this path through `runSleep`. A regression removing the overflow check would not be caught.

**Fix:** Add a `runSleep` test with an astronomically large value (e.g., `"999999999999999999999d"`) and assert exit 2 with `"value too large"` in stderr.

---

### [IMPORTANT] `runSleep - version option` hardcodes "vibeutils" — will break if project name changes

**Location:** `src/sleep.zig:280`

```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "sleep (vibeutils)") != null);
```

Other utilities check for the generic `common.name` constant or just for the utility name. Hardcoding `"vibeutils"` makes this test break if the project name changes. The version test for `runTimeout` uses `"timeout"` without the project name, which is safer.

**Fix:** Replace the hardcoded string with a check for `common.name` or check for just `"sleep"` in the output, consistent with how other utilities handle this.

---

### [SUGGESTION] Tests 1-9 duplicate common/time.zig tests

**Location:** `src/sleep.zig:164-231`

All nine `parseTimeString` tests in `sleep.zig` are identical copies of the tests in `src/common/time.zig` and `src/timeout.zig`. They add no new coverage — `common/time.zig` has its own test suite. The copies increase maintenance burden: a change to `parseTimeString` behavior requires updating three files.

This is a minor concern since the copies pass, but they create a false sense of per-utility coverage.

---

### [SUGGESTION] `runSleep - negative flag treated as unknown argument` tests argparse behavior, not sleep behavior

**Location:** `src/sleep.zig:313-321`

```zig
const result = try runSleep(testing.allocator, &.{"-1"}, ...);
try testing.expectEqual(@as(u8, 2), result);
try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid argument") != null);
```

`-1` is parsed as an unknown short flag (`-1`), not as a negative number. The message "invalid argument" is the argparse error path, not the time-parsing error path. This is technically correct behavior but the test name implies time semantics. The companion test 18 correctly uses `-- -1` to pass a negative number through positionals. Test 19 is fine but its name is misleading.

**Fix:** Rename to `runSleep - numeric flag -1 treated as unknown short option` for clarity.

---

## Summary

- **CRITICAL:** 0
- **IMPORTANT:** 3 (wall-clock flakiness; TimeOverflow not tested through runSleep; hardcoded project name)
- **SUGGESTION:** 2 (duplicate common/time.zig tests; misleading test name for -1 flag)

**No parse-only tests.** All `runSleep` tests exercise the full function path. `parseTotalTime` is tested directly in addition to through `runSleep`, which is appropriate since it is a non-trivial internal function.

**Overall: NEEDS_FIXES**

Fix order:
1. [IMPORTANT] Widen or remove wall-clock upper bound in `very small sleep time` — `src/sleep.zig:336`
2. [IMPORTANT] Add `runSleep` test for `TimeOverflow` error path — `src/sleep.zig`
3. [IMPORTANT] Replace hardcoded `"sleep (vibeutils)"` with `common.name` reference — `src/sleep.zig:280`
4. [SUGGESTION] Rename test 19 to clarify it tests argparse, not time parsing — `src/sleep.zig:313`
