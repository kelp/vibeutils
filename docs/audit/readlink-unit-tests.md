# readlink Unit Test Audit

**Date:** 2026-03-28
**File:** `src/readlink.zig`
**Tests:** 24 embedded unit tests
**Status:** NEEDS_FIXES

## Summary

All 24 tests pass. No parse-only stubs. Coverage is genuinely
behavioral: every test exercises `runReadlink` end-to-end via real
temp directories or live path arguments. One important semantic bug
is present in the implementation that no test catches: `-f` and `-e`
are treated identically, but GNU requires different behavior.

## Test Inventory

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | readlink basic symlink | Yes | |
| 2 | readlink not a symlink | Yes | |
| 3 | readlink nonexistent file | Yes | |
| 4 | readlink verbose error | Yes | checks stderr content |
| 5 | readlink quiet suppresses errors | Yes | |
| 6 | readlink canonicalize (-f) | Yes | |
| 7 | readlink canonicalize regular file (-f) | Yes | |
| 8 | readlink canonicalize-existing (-e) | Yes | |
| 9 | readlink canonicalize nonexistent fails with -f | Yes | |
| 10 | readlink canonicalize-missing (-m) with nonexistent path | Yes | |
| 11 | readlink no-newline (-n) | Yes | |
| 12 | readlink zero delimiter (-z) | Yes | checks NUL byte |
| 13 | readlink multiple files | Yes | |
| 14 | readlink mixed success and failure | Yes | |
| 15 | readlink missing operand | Yes | checks stderr |
| 16 | readlink help | Yes | checks stdout content |
| 17 | readlink version | Yes | checks stdout content |
| 18 | readlink unknown flag | Yes | checks stderr |
| 19 | readlink dangling symlink | Yes | |
| 20 | readlink dangling symlink with -f fails | Yes | |
| 21 | readlink canonicalize-missing with dangling symlink (-m) | Yes | |
| 22 | readlink -m dotdot past root returns root | Yes | |
| 23 | readlink -m multi-level dotdot past root returns root | Yes | |
| 24 | readlink -m single component dotdot returns root | Yes | |

## Findings

---

[IMPORTANT] -f and -e have identical implementations; -f semantic untested
Location: `src/readlink.zig:62-65`
Problem: GNU `readlink -f` specifies "all but the last component must
exist" while `-e` requires "all components must exist". Both flags map
to `.strict` mode which calls `realpathAlloc`, requiring every
component including the last to exist. The divergence is documented in
the meta description (line 40: "all but the last component must
exist") and the help text (line 174-175), but the implementation does
not honor it. No unit test probes `-f /existing/dir/NONEXISTENT_LAST`
which should succeed under `-f` but fail under `-e`. The bug is latent
and will silently produce wrong exit codes on this class of inputs.
Fix: Implement `-f` using the same `canonicalizeMissing`-style logic
that resolves all but the last component, keeping `-e` mapped to
`realpathAlloc`. Add a test:
```zig
test "readlink -f last component may be missing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    // Parent exists, last component does not
    const path = try std.fmt.allocPrint(testing.allocator,
        "{s}/nonexistent_last", .{dir_path});
    defer testing.allocator.free(path);
    var out = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer out.deinit(testing.allocator);
    const result = try runReadlink(testing.allocator, &[_][]const u8{"-f", path},
        out.writer(testing.allocator), common.null_writer);
    // -f should succeed; -e would fail
    try testing.expectEqual(@as(u8, 0), result);
}
```

---

[IMPORTANT] --silent long-form flag has no unit test
Location: `src/readlink.zig:29,48`
Problem: `--silent` is a documented alias for `--quiet`. The unit
test for quiet only exercises `-q` combined with `-v`
(`src/readlink.zig:301`). No test passes `--silent` directly to
verify parsing and behavior. A parse regression would go undetected.
Fix: Add a test that passes `--silent` and confirms error output is
suppressed.

---

[SUGGESTION] -m dangling-symlink test checks only len > 0, not content
Location: `src/readlink.zig:617-618`
Problem: "readlink canonicalize-missing with dangling symlink (-m)"
asserts only `stdout_buf.items.len > 0`. It does not verify the
resolved path contains the canonical base directory, nor that the
symlink target name appears. This makes the test vacuous with respect
to output content.
Fix: Assert the output ends with the expected resolved path, similar
to the stricter tests at lines 407-408 and 653.

---

[SUGGESTION] No unit test for -v with a regular file (NotLink error path)
Location: `src/readlink.zig:126-133`
Problem: The verbose error test (line 289) uses a nonexistent path,
triggering the `FileNotFound` branch. The `NotLink` branch (regular
file that is not a symlink) has no verbose-mode unit test. If the
error message string were changed, no test would catch it.
Fix: Add a test passing `-v` against a regular (non-symlink) file and
asserting "Invalid argument" appears in stderr.

## Overall Assessment

NEEDS_FIXES

Fix Order:
1. [IMPORTANT] -f treats last-missing component as failure — `src/readlink.zig:62-65`
2. [IMPORTANT] --silent alias has no unit test — `src/readlink.zig:29,48`
3. [SUGGESTION] -m dangling-symlink test checks only len > 0 — `src/readlink.zig:617`
4. [SUGGESTION] -v NotLink error path untested — `src/readlink.zig:126-133`
