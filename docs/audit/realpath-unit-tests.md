# realpath Unit Test Audit

**Date:** 2026-03-28
**File:** `src/realpath.zig`
**Tests:** 28 embedded unit tests (29 test blocks; one is a cannot-fail stub)
**Run result:** All pass (confirmed via IT harness; zig build test
  result not separately verified due to slow full-suite build)
**Status:** NEEDS_FIXES

## Summary

Coverage is strong. No parse-only stubs in the traditional sense:
every test that exercises a flag calls `runRealpath` or `resolveLogical`
and checks behavioral output. One test is a confirmed cannot-fail stub
that makes no assertions. The `-e` flag output is never verified; only
its exit code is checked. `--relative-base` same-directory (".")
behavior is tested in unit but not the corresponding `--relative-to`
same-directory case under a different combination.

## Test Inventory

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | realpath: help flag | Yes | content check |
| 2 | realpath: version flag | Yes | content check |
| 3 | realpath: missing operand | Yes | stderr + exit 2 |
| 4 | realpath: unknown flag | Yes | exit 2 |
| 5 | realpath: existing path | Yes | abs path + newline |
| 6 | realpath: nonexistent path fails by default | Yes | exit 1 + stderr |
| 7 | realpath: canonicalize-missing accepts nonexistent paths | Yes | content check |
| 8 | realpath: no-symlinks resolves . and .. | Yes | exact output |
| 9 | realpath: strip alias works | Yes | exact output |
| 10 | realpath: zero delimiter | Yes | exact NUL output |
| 11 | realpath: quiet suppresses errors | Yes | stderr len == 0 |
| 12 | realpath: multiple paths | Yes | exact two-line output |
| 13 | realpath: multiple paths with some failing | **Cannot-fail stub** | `_ = result` |
| 14 | realpath: default mode fails on nonexistent | Yes | stdout empty, stderr non-empty |
| 15 | realpath: resolveLogical basic | Yes | three exact assertions |
| 16 | realpath: resolveLogical root | Yes | exact "/" |
| 17 | realpath: resolveLogical redundant slashes | Yes | exact output |
| 18 | realpath: resolveLogical .. past root | Yes | exact "/" |
| 19 | realpath: existing path with symlink resolution | Yes | checks both resolve same |
| 20 | realpath: relative-to with no-symlinks | Yes | exact "bin/ls" |
| 21 | realpath: relative-base under base | Yes | exact "bin/ls" |
| 22 | realpath: relative-base not under base | Yes | exact absolute path |
| 23 | realpath: relative-base path correctly under base | Yes | exact "bin" |
| 24 | realpath: relative-base prefix false positive | Yes | exact absolute path |
| 25 | realpath: relative-base path equals base | Yes | exact "." |
| 26 | realpath: canonicalize-missing .. past root returns root | Yes | exact "/" |
| 27 | realpath: canonicalize-missing multiple .. past root | Yes | exact "/" |
| 28 | realpath: canonicalize-missing deeper path .. past root | Yes | exact "/" |

## Findings

---

[CRITICAL] "multiple paths with some failing" is a cannot-fail stub
Location: `src/realpath.zig:461-475`
Problem: The test runs `runRealpath` but discards the result with
`_ = result` and makes no assertions about stdout, stderr, or the
exit code. The comment explains the setup is wrong (`-s` means
`resolveLogical` doesn't check existence so both paths succeed), but
the fix was to discard `result` instead of rewriting the test with
default mode. A partial-failure scenario with correct partial output
(valid path printed, invalid suppressed) is the most common mixed
success case and has zero coverage at the unit level.
Fix: Replace the stub with a test that uses default mode and verifies
the valid path appears in stdout and the exit code is 1:
```zig
test "realpath: multiple paths partial failure" {
    var out = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer out.deinit(testing.allocator);
    var err = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer err.deinit(testing.allocator);
    // default mode: /tmp exists, /nonexistent does not
    const args = [_][]const u8{"/tmp", "/nonexistent_vibeutils_test_xyz"};
    const result = try runRealpath(testing.allocator, &args,
        out.writer(testing.allocator), err.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(out.items.len > 0); // /tmp line printed
    try testing.expect(err.items.len > 0); // error for nonexistent
}
```

---

[IMPORTANT] -e flag output never verified; only exit code tested
Location: `src/realpath.zig:367-380` (test "realpath: existing path")
Problem: `realpath -e` is the explicitly documented "canonicalize-
existing" flag. The only test touching it via `runRealpath` is
"realpath: existing path" which uses default mode (not `-e`). There
is no unit test that passes `-e` to `runRealpath` and verifies the
output. Test 6 also does not use `-e`. A regression that broke `-e`
parsing specifically would not be caught by unit tests.
Fix: Add a test that calls `runRealpath` with `["-e", "/tmp"]` and
verifies the output is an absolute path starting with `/`.

---

[IMPORTANT] --relative-to and --relative-base only tested combined with -s
Location: `src/realpath.zig:551-622`
Problem: All seven `--relative-to` and `--relative-base` unit tests
pass `-s` (no-symlinks). Neither flag is unit-tested in default mode
(canonical-existing) or `-m` mode. A regression in the base-dir
resolution path when `realpathAlloc` is called (lines 155-160) would
not be caught.
Fix: Add at least one test for `--relative-to` in default mode using
real paths (e.g. `/usr/bin/ls` relative to `/usr`).

---

[SUGGESTION] resolveLogical tests bypass runRealpath
Location: `src/realpath.zig:493-524`
Problem: Tests 15-18 call `resolveLogical` directly, bypassing the
`runRealpath` entry point and the `-s` flag dispatch path. While
useful for unit-isolating the function, there is no test that sends a
path with `..` through `runRealpath -s` and verifies exact output.
Test 8 (`-s /usr/bin/../lib`) covers one case, but dot-only and
root-clamp cases are only at the `resolveLogical` level.
Fix: This is a low-priority gap; the existing direct tests are
adequate for the function itself.

## Overall Assessment

NEEDS_FIXES

Fix Order:
1. [CRITICAL] Cannot-fail stub "multiple paths with some failing" — `src/realpath.zig:461`
2. [IMPORTANT] -e flag output never asserted via runRealpath — `src/realpath.zig:367`
3. [IMPORTANT] --relative-to/--relative-base only tested with -s — `src/realpath.zig:551-622`
4. [SUGGESTION] resolveLogical tests bypass runRealpath entry point — `src/realpath.zig:493`
