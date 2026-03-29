# whoami Unit Test Audit

**Date:** 2026-03-28
**File:** `src/whoami.zig`
**Tests:** 9 declared; all 9 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Notes |
|---|-----------|------|-------|
| 1 | `whoami prints current username` | behavioral | checks len > 1, ends with newline, no stderr |
| 2 | `whoami help flag` | behavioral | checks output content + empty stderr |
| 3 | `whoami short help flag` | behavioral | checks output content |
| 4 | `whoami version flag` | behavioral | checks output content + common.name |
| 5 | `whoami short version flag` | behavioral | checks output content |
| 6 | `whoami unknown flag returns misuse` | behavioral | checks exit 2 + stderr |
| 7 | `whoami unknown short flag returns misuse` | behavioral | checks exit non-0 + stderr non-empty |
| 8 | `whoami extra arguments returns misuse` | behavioral | checks exit 2 + "extra operand" in stderr |
| 9 | `whoami output matches current user` | behavioral | compares against user_group directly |

---

## Findings

### [IMPORTANT] `whoami unknown short flag returns misuse` does not assert exit code 2

**Location:** `src/whoami.zig:220-227`

```zig
const result = try runWhoami(testing.allocator, &args, ...);
try testing.expectEqual(@as(u8, 2), result);  // ← not present
try testing.expectEqualStrings("", stdout_buffer.items);
try testing.expect(stderr_buffer.items.len > 0);
```

The test asserts exit 2 for `--invalid` (test 6) but only `!= 0` (via `stderr.items.len > 0`) for `-x` (test 7). The exit code for the short-flag case is not checked. A regression that returned exit 1 for unknown short flags but exit 2 for unknown long flags would pass.

**Fix:** Add `try testing.expectEqual(@as(u8, 2), result);` to test 7.

---

### [IMPORTANT] `whoami prints current username` does not verify the username is non-trivially formatted

**Location:** `src/whoami.zig:124-143`

The test checks `stdout_buffer.items.len > 1` and ends with `\n`. It does not check that the username contains no newline characters within it, no leading/trailing whitespace, and no null bytes. A bug that emitted extra whitespace or a newline-prefixed name would pass. Test 9 (`whoami output matches current user`) is a better behavioral test for this, but it is the last test rather than the primary one.

---

### [IMPORTANT] No test for the `cannot find name for user ID` error path

**Location:** `src/whoami.zig:68-71`

```zig
const user_info = common.user_group.getUserById(uid, allocator) catch {
    common.printErrorWithProgram(..., "cannot find name for user ID {d}", .{uid});
    return @intFromEnum(common.ExitCode.general_error);
};
```

The error path — where the user ID has no corresponding passwd entry — is never exercised. A test would need to call `runWhoami` in a context where `getUserById` fails (e.g., by injecting a fake implementation or running as a UID with no passwd entry). This path returns `general_error` (exit 1), and a regression removing that error handling would go undetected.

This is a genuine gap: the error code and message could change silently.

---

### [SUGGESTION] `whoami version flag` test checks `common.name` but not the version number

**Location:** `src/whoami.zig:171-184`

```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "whoami") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.name) != null);
```

These checks confirm the output contains the utility name and project name, but not the version string. `common.version` is also available. Optionally checking for a version number pattern (e.g., `"0."`) would make this more meaningful.

---

### [SUGGESTION] Test 1 and Test 9 are somewhat redundant

**Location:** `src/whoami.zig:124-143, 244-261`

Test 1 checks that output is non-empty and ends with newline. Test 9 checks that the output exactly matches the `user_group` API result. Test 9 is strictly stronger and subsumes test 1. Both can be retained for clarity, but their relationship is not documented.

---

## Summary

- **CRITICAL:** 0
- **IMPORTANT:** 3 (short flag exit code not checked; getUserById error path untested; username format not validated)
- **SUGGESTION:** 2 (version string not checked; test 1/9 redundancy)

**No parse-only tests.** All 9 tests are behavioral, exercising `runWhoami` or the underlying `user_group` API. The suite is compact and correct but has one weak assertion (test 7) and a completely untested error path.

**Overall: NEEDS_FIXES**

Fix order:
1. [IMPORTANT] Add `expectEqual(@as(u8, 2), result)` to test 7 (unknown short flag) — `src/whoami.zig:220`
2. [IMPORTANT] Add test or document for `getUserById` failure path — `src/whoami.zig:68`
3. [IMPORTANT] Add username format validation (no embedded newlines, no leading spaces) to test 1 — `src/whoami.zig:124`
4. [SUGGESTION] Add `common.version` check to version flag test — `src/whoami.zig:171`
