# Unit Test Audit: mv

**Date**: 2026-03-28
**Source file**: src/mv.zig
**Total tests**: 26
**Run result**: All 26 pass (all pass against the full suite)

---

## Executive Summary

NEEDS_FIXES

The unit test suite is meaningfully stronger than most other
utilities in this repo. The core behavioral paths (`moveFile`
with `-f`, `-n`, `-b`, `-h`, `-v`) each have at least one real
test. However, four parse-only stubs add false confidence, one
test has a logic flaw that makes it unable to catch a real
failure, and the `runUtility` error paths (missing operands,
multiple sources, unknown flags) have zero unit coverage.

---

## Test Inventory

| # | Test Name | Lines | Type | Strength |
|---|-----------|-------|------|----------|
| 1 | mv: basic test | 98 | **parse-only** | WEAK |
| 2 | mv: file rename in same directory | 107 | behavioral | STRONG |
| 3 | mv: move to different directory | 144 | behavioral | STRONG |
| 4 | mv: directory move | 187 | behavioral | MODERATE — see F1 |
| 5 | mv: force mode overwrites existing file | 228 | behavioral | STRONG |
| 6 | mv: no-clobber mode preserves existing file | 259 | behavioral | STRONG |
| 7 | mv: files with spaces in names | 294 | behavioral | STRONG |
| 8 | mv: files with unicode characters | 328 | behavioral | STRONG |
| 9 | mv: files with special characters | 362 | behavioral | STRONG |
| 10 | mv: empty file | 396 | behavioral | STRONG |
| 11 | mv: force overwrite existing file on same filesystem | 915 | behavioral | STRONG |
| 12 | mv: large file copy preserves content integrity | 945 | behavioral | STRONG |
| 13 | mv: overwrite hint printed when destination exists with -f | 995 | behavioral | STRONG |
| 14 | mv: overwrite hint NOT printed with -i flag | 1022 | behavioral | MODERATE — see F2 |
| 15 | mv: overwrite hint NOT printed with -f and -i flags | 1050 | behavioral | STRONG |
| 16 | mv: overwrite hint NOT printed when destination does not exist | 1077 | behavioral | STRONG |
| 17 | mv: -b flag creates backup of destination | 1106 | behavioral | STRONG |
| 18 | mv: -b flag does nothing when dest does not exist | 1141 | behavioral | STRONG |
| 19 | mv: -h flag prevents following symlink to directory | 1178 | behavioral | STRONG |
| 20 | mv: -h flag still follows real directories | 1204 | behavioral | STRONG |
| 21 | mv: -b flag is parsed | 1219 | **parse-only** | WEAK |
| 22 | mv: --backup flag is parsed | 1226 | **parse-only** | WEAK |
| 23 | mv: -h flag is parsed as no_follow_symlink | 1233 | **parse-only** | WEAK |
| 24 | mv: --help still works as long-only flag | 1241 | **parse-only** | WEAK |
| 25 | mv: verbose move prints arrow to stdout | 1249 | behavioral | STRONG |
| 26 | mv: verbose move does not print arrow to stderr | 1283 | behavioral | STRONG |

**Parse-only tests**: 4 of 26 (tests 1, 21, 22, 23, 24)
**Behavioral tests**: 22 of 26

---

## Findings

### [CRITICAL] F1 — "directory move" cannot catch a silent failure

```
Location: src/mv.zig:214
```

The source-removal check is written as:

```zig
test_dir.tmp_dir.dir.access("source_dir", .{}) catch |err| {
    try testing.expect(err == error.FileNotFound);
};
```

If `access` succeeds (source directory was never removed), the
`catch` block is skipped entirely and the test passes with no
complaint. The move could fail silently and this test would
still pass.

**Fix**:

```zig
// access returns void on success, error on failure.
// We need the inverse: fail if the directory still exists.
const source_gone = blk: {
    test_dir.tmp_dir.dir.access("source_dir", .{}) catch |err| {
        if (err == error.FileNotFound) break :blk true;
        return err;
    };
    break :blk false;
};
try testing.expect(source_gone);
```

---

### [IMPORTANT] F2 — "overwrite hint NOT printed with -i flag" ignores its own error

```
Location: src/mv.zig:1044
```

The test calls `moveFile` with `.interactive = true`, discards
any error with `catch {}`, then asserts `!hinted`. With an
interactive destination conflict and no tty, `moveFile` will
attempt a prompt that may return an error or EOF. Swallowing
the error means the assertions that follow are based on
whatever state `hinted` happens to be in after a partially
executed function, not after a cleanly verified run.

The test effectively confirms "hint is false at point-of-read
after some error was swallowed," which passes trivially because
`hinted` starts false and the function errored before reaching
the hint logic.

**Fix**: Use `runUtility` (which wraps errors into exit codes)
or restructure so that the interactive mode is tested with a
controlled stdin pipe, or explicitly verify that the absence of
the hint is due to the function returning cleanly at the prompt
path rather than aborting.

---

### [IMPORTANT] F3 — Parse-only tests for -b, --backup, -h give false coverage signal

```
Location: src/mv.zig:1219-1247
```

Tests 21-24 only verify that the argparser sets a boolean.
The behavioral tests for `-b` (tests 17-18) and `-h`
(tests 19-20) already exist, so these parse stubs add no
coverage. They falsely inflate the test count and suggest flag
routes are tested at multiple levels when the parse layer is
trivially covered by the underlying argparse module's own
tests.

**Fix**: Remove tests 21-24. The behavioral tests that call
`moveFile` and `isDestDirectory` already verify the flags are
wired correctly. If argparse integration is important, add a
single `runUtility` call that exercises the complete flag-to-
behavior chain instead.

---

### [IMPORTANT] F4 — No unit tests for `runUtility` error paths

```
Location: src/mv.zig:778-913
```

`runUtility` handles several distinct error conditions that
have no unit test:

- No operands: prints "missing file operand", exits misuse (2)
- Single operand: prints "missing destination file operand
  after...", exits misuse (2)
- Multiple sources to non-directory: prints "target is not a
  directory", exits general_error (1)
- Unknown flag: prints "unrecognized option", exits misuse (2)
- `--version`: prints version string, exits success (0)

All five paths are exercised only at the integration level (or
not at all). Because `runUtility` is the entry point that wires
parsed flags into `moveFile`, a bug in argument counting logic
would be invisible until integration tests run.

**Fix**: Add one `runUtility`-based test per error path:

```zig
test "mv: no operands exits misuse" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(
        testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(
        testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{};
    const exit_code = try runUtility(
        testing.allocator, &args,
        stdout_buf.writer(testing.allocator),
        stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(
        std.mem.indexOf(u8, stderr_buf.items,
                        "missing file operand") != null);
}
```

Repeat for single operand, multiple-sources-to-non-directory,
and unknown flag.

---

### [IMPORTANT] F5 — No unit test for same-file detection

```
Location: src/mv.zig:644-648
```

`moveFile` calls `common.file_ops.isSameFile` at entry and
returns `error.SameFile` if the check passes. There is no unit
test verifying that `mv source source` emits an error and
returns an error exit code. The integration test for this path
causes the binary to abort (signal 6) rather than exit cleanly,
which is a separate bug, but the unit layer should still assert
the correct error is returned from `moveFile`.

**Fix**:

```zig
test "mv: same file returns SameFile error" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const name = try test_dir.createUniqueFile("same", "data");
    defer testing.allocator.free(name);
    const path = try test_dir.getPath(name);
    defer testing.allocator.free(path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(
        testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(
        testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;

    const result = moveFile(
        testing.allocator, path, path, .{},
        stdout_buf.writer(testing.allocator),
        stderr_buf.writer(testing.allocator), &hinted);
    try testing.expectError(error.SameFile, result);
    try testing.expect(
        std.mem.indexOf(u8, stderr_buf.items,
                        "same file") != null);
}
```

---

### [SUGGESTION] S1 — "basic test" tests nothing

```
Location: src/mv.zig:98-105
```

This test constructs a `MoveOptions{}` and asserts all default
fields are false. These are compile-time constants; they can
never be wrong unless someone changes the defaults, at which
point the test would fail for the wrong reason. It adds no
behavioral signal. Remove it.

---

### [SUGGESTION] S2 — Verbose tests do not verify the move completed

```
Location: src/mv.zig:1249-1312
```

Tests 25 and 26 call `runUtility` with `-v` and check that
stdout/stderr contain or do not contain `->`. Neither test
confirms that the source file was removed or that the
destination file has the expected content. A bug that prints
verbose output but skips the actual rename would pass both
tests.

**Fix**: After checking exit code and stream content, also
assert source is gone and destination content is correct.

---

## Flag Coverage Summary

| Flag | Tier | Has Behavioral Unit Test? | Strength |
|------|------|--------------------------|----------|
| -f   | MUST | Yes (tests 5, 11) | STRONG |
| -i   | MUST | Indirect only (test 14 — F2) | WEAK |
| -v   | MUST | Yes (tests 25, 26) | MODERATE (S2) |
| -n   | SHOULD | Yes (test 6) | STRONG |
| -h   | SHOULD | Yes (tests 19, 20) | STRONG |
| -b   | SHOULD | Yes (tests 17, 18) | STRONG |
| --backup | SHOULD | Yes (covered by tests 17, 18) | STRONG |

`-i` is the only MUST flag without a solid behavioral unit
test. Test 14 exercises the hint-suppression side effect of
`-i` but swallows the error that would verify the actual
interactive-skip path works.

---

## Findings Summary

| ID | Severity | Description |
|----|----------|-------------|
| F1 | CRITICAL | "directory move" source-removal check cannot fail; access success silently passes |
| F2 | IMPORTANT | "overwrite hint NOT printed with -i" swallows error; assertions are unreliable |
| F3 | IMPORTANT | 4 parse-only stubs (-b, --backup, -h, --help) add no coverage over behavioral tests |
| F4 | IMPORTANT | `runUtility` error paths (no args, 1 arg, bad flag, multi-to-non-dir) have zero unit tests |
| F5 | IMPORTANT | Same-file detection path has no unit test; binary aborts at integration level |
| S1 | SUGGESTION | "basic test" checks only compile-time default values; remove |
| S2 | SUGGESTION | Verbose tests do not verify actual file move completed |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Fix "directory move" source-removal assertion
   to detect silent failure — src/mv.zig:214
2. [IMPORTANT] Add runUtility unit tests for: no operands,
   single operand, unknown flag, multi-to-non-dir
   — src/mv.zig after line 1313
3. [IMPORTANT] Add "same file returns SameFile error" unit
   test — src/mv.zig after line 1313
4. [IMPORTANT] Fix "overwrite hint NOT printed with -i" to
   not swallow errors; verify clean interactive-skip path
   — src/mv.zig:1044
5. [IMPORTANT] Remove 4 parse-only stubs (tests 21-24,
   lines 1219-1247)
6. [SUGGESTION] Extend verbose tests (25, 26) to also assert
   src gone + dest content correct — src/mv.zig:1249, 1283
7. [SUGGESTION] Remove "basic test" (test 1, line 98)
```

REVIEW COMPLETE - NEEDS_FIXES
