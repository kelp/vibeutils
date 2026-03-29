---
date: 2026-03-28
utility: ln
audit_type: unit-tests
result: NEEDS_FIXES
---

# ln Unit Test Audit

## Test Run

26 tests — all pass.

```
run test 26 passed
```

## Test Inventory

| # | Test Name | Type |
|---|-----------|------|
| 1 | ln creates hard link to existing file | behavioral |
| 2 | ln creates symbolic link | behavioral |
| 3 | ln fails on non-existent target for hard link | behavioral |
| 4 | ln allows non-existent target for symbolic link | behavioral |
| 5 | ln with force removes existing file | behavioral |
| 6 | ln fails without force on existing file | behavioral |
| 7 | ln creates relative symbolic link with -r | PARSE-ONLY (see below) |
| 8 | ln relative path calculation | unit (makeRelativePath helper) |
| 9 | isTargetMissing returns true for nonexistent target | behavioral |
| 10 | isTargetMissing returns false for existing target | behavioral |
| 11 | dangling symlink produces warning via createSingleLink with -w | behavioral |
| 12 | dangling symlink no warning without -w | behavioral |
| 13 | ln: -h flag is parsed as no_dereference | parse-only |
| 14 | ln: --help still works as long-only flag | parse-only |
| 15 | ln: -L flag is parsed | parse-only |
| 16 | ln: -P flag is parsed | parse-only |
| 17 | ln: -L creates hard link to symlink target | behavioral |
| 18 | ln: -P creates hard link to symlink itself | CANNOT-FAIL (see below) |
| 19 | ln: -b flag creates backup of destination | behavioral |
| 20 | ln: -b flag is parsed | parse-only |
| 21 | ln: --backup flag is parsed | parse-only |
| 22 | ln: -F flag is parsed | parse-only |
| 23 | ln: -w flag is parsed | parse-only |
| 24 | ln: -F implies force | parse-only (options struct construction) |
| 25 | ln: -w flag enables dangling symlink warning | behavioral |
| 26 | ln: -sb without -f creates backup and replaces symlink | behavioral |

**Parse-only count: 8** (tests 13, 14, 15, 16, 20, 21, 22, 23)
**Cannot-fail count: 1** (test 18)
**Stub test: 1** (test 7)

---

## Findings

### [CRITICAL] -P test is a cannot-fail test that hides a known
implementation bug

Location: `src/ln.zig:970`

Problem: The test comment at line 1008 states "This test should
FAIL because -P is not implemented yet". The test passes because
`lstat` on a hard link to the symlink's target happens to share
the same inode as the target file when `linkat` with
`AT_SYMLINK_FOLLOW` is used. The assertion `symlink_info.inode ==
hardlink_info.inode` is trivially true in the non-P case too,
because the symlink inode and the regular file inode are
different. The test is comparing symlink inode to hardlink inode
but both point to the regular file's inode when `-P` is not
working, making this a false green. The comment itself confirms
`-P` is not implemented but the test passes anyway.

Fix: Rewrite the test to confirm the hardlink is itself a
symlink (i.e., `lstat` shows `kind == .sym_link`). The current
test cannot distinguish `-P` working from `-P` silently
falling back to `-L`.

```zig
// Correct assertion for -P: the new hardlink should
// itself be of kind .sym_link
try testing.expectEqual(
    std.fs.File.Kind.sym_link,
    hardlink_info.kind,
);
// And share the inode of the *symlink*, not the target
try testing.expectEqual(symlink_info.inode, hardlink_info.inode);
```

---

### [CRITICAL] -r test does not exercise the -r code path at all

Location: `src/ln.zig:750`

Problem: The test comment at line 758 says "This test is complex
because relative links require the real createSingleLink
function / For now, let's test the relative path calculation
directly and create a simple symlink". The test body manually
calls `tmp_dir.dir.symLink("../target.txt", ...)` — it never
calls `runLn` or `createSingleLink` with `relative = true`. The
`-r` / `--relative` flag (SHOULD tier) has zero behavioral
coverage through `runLn`.

Fix: Replace the stub with an end-to-end test using `runLn`:

```zig
test "ln: -r creates symlink with relative path via runLn" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("subdir");
    try createTestFile(tmp_dir.dir, "target.txt", "content");

    const tmp_path = try tmp_dir.dir.realpathAlloc(
        testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{tmp_path, "target.txt"});
    defer testing.allocator.free(target_abs);
    const link_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{tmp_path, "subdir", "link.txt"});
    defer testing.allocator.free(link_abs);

    const exit_code = try runLn(
        testing.allocator,
        &[_][]const u8{"-s", "-r", target_abs, link_abs},
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stored = try tmp_dir.dir.readLink("subdir/link.txt",
        &buf);
    // Should be a relative path, not an absolute one
    try testing.expect(!std.fs.path.isAbsolute(stored));
    try testing.expectEqualStrings("../target.txt", stored);
}
```

---

### [IMPORTANT] -v (SHOULD) has zero behavioral tests

Location: `src/ln.zig` — no test for `--verbose` output

Problem: `-v` prints `'LINK' -> 'TARGET'` or `'LINK' =>
'TARGET'` to stdout. No test verifies this output appears, that
the `->` vs `=>` distinction is correct, or that no output
appears when `-v` is absent.

Fix: Add a `runLn` test that captures stdout and asserts the
verbose line is emitted with the correct arrow style for both
hard and symbolic links.

---

### [IMPORTANT] -i (SHOULD) interactive path has zero behavioral
tests

Location: `src/ln.zig` — no test calls `runLn` or
`createSingleLink` with `interactive = true`

Problem: The `test_mode = true` escape hatch exists precisely
so that tests can exercise the interactive branch. No test does
so. The code path where the prompt fires and the user answers
`y` is entirely untested at the unit level.

Fix: Add a unit test that calls `createSingleLink` with
`interactive = true, test_mode = true` when the destination
exists, and asserts it returns `error.FileExists` (the
test-mode "no" response).

---

### [IMPORTANT] -t and -T (both SHOULD) have zero behavioral
tests

Location: `src/ln.zig` — no test covers `target_directory` or
`no_target_directory` options via `runLn`

Problem: The `-t DIRECTORY TARGET...` form (Form 4) and the
`-T` "treat LINK_NAME as normal file" flag both go through
distinct code paths in `createLinks`. Neither is exercised by
any unit test. A regression in either branch would go
undetected.

Fix: Add at least one `runLn` test per flag verifying the
resulting link is created in the right location (for `-t`) and
that a pre-existing symlink-to-directory is not entered when
`-T` is set.

---

### [IMPORTANT] -F behavioral path (remove directory destination)
has zero tests

Location: `src/ln.zig:1082` — the `-F implies force` test only
constructs the `LinkOptions` struct; it never calls `runLn`

Problem: The `-F` code path in `createSingleLink` (lines
468–482) attempts `deleteFile` then falls back to `deleteDir`.
The `deleteDir` branch is entirely untested. The parse-only
"implies force" test (#24) does not call `runLn` at all.

Fix: Add a `runLn` test that places a directory at the
destination path, runs `ln -sF src dest_dir`, and asserts the
directory was removed and the symlink was created.

---

### [SUGGESTION] Parse-only tests for -b and --backup are
redundant

Location: `src/ln.zig:1054` and `1061`

Problem: Tests #20 (`-b flag is parsed`) and #21 (`--backup
flag is parsed`) add no value beyond the argparse framework's
own self-tests, since test #19 already exercises `-b` end-to-end
through `runLn`.

Fix: Delete tests #20 and #21 and add a test covering `ln -b`
without `-f` on an existing hard-link destination (the no-force
backup path for hard links is untested).

---

### [SUGGESTION] -n and -h aliasing is only tested via parse,
not behavior

Location: `src/ln.zig:886` (test #13)

Problem: `-h` / `-n` are MUST-tier flags. The parse test
confirms `no_deref_h` is set but does not verify the program
behaves differently — that is, that a symlink-to-directory as
the destination is treated as a normal file rather than being
entered. The behavioral difference is what matters for users
(see the `ln -shf baz foo` example in the macOS man page).

Fix: Add a `runLn` test that creates a symlink pointing to a
directory, then runs `ln -h -f src link_to_dir` and verifies
the symlink was replaced rather than the link being created
inside the directory it points to.

---

## Flag Coverage Summary

| Flag | Tier | Parse test | Behavioral test |
|------|------|-----------|-----------------|
| -f | MUST | implicit | yes (tests 5, 6) |
| -L | MUST | yes (#15) | yes (#17) |
| -P | MUST | yes (#16) | CANNOT-FAIL (#18) |
| -s | MUST | implicit | yes (tests 2, 4, etc.) |
| -h / -n | MUST | yes (#13) | NO |
| -i | SHOULD | implicit | NO |
| -v | SHOULD | implicit | NO |
| -F | SHOULD | yes (#22) | partial (no dir-removal test) |
| -w | SHOULD | yes (#23) | yes (#11, #25) |
| -b / --backup | SHOULD | yes (#20, #21) | yes (#19, #26) |
| -r / --relative | SHOULD | implicit | STUB (#7) |
| -t | SHOULD | implicit | NO |
| -T | SHOULD | implicit | NO |

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 4 |
| SUGGESTION | 2 |

**Overall assessment: NEEDS_FIXES**

Fix Order:

1. [CRITICAL] `-P` test is a cannot-fail false green that
   conceals an unimplemented feature —
   `src/ln.zig:970`
2. [CRITICAL] `-r` test is a stub that never calls `runLn`;
   `-r` / `--relative` has zero end-to-end coverage —
   `src/ln.zig:750`
3. [IMPORTANT] `-v` verbose output has no behavioral test —
   `src/ln.zig` (no test)
4. [IMPORTANT] `-i` interactive path has no behavioral test —
   `src/ln.zig` (no test)
5. [IMPORTANT] `-t` and `-T` have no behavioral tests —
   `src/ln.zig` (no test)
6. [IMPORTANT] `-F` directory-removal branch has no behavioral
   test — `src/ln.zig:468`
7. [SUGGESTION] `-h`/`-n` aliasing tested parse-only; no
   behavioral no-dereference test — `src/ln.zig:886`
8. [SUGGESTION] Redundant `-b`/`--backup` parse-only tests;
   replace with a hard-link backup test —
   `src/ln.zig:1054`

REVIEW COMPLETE - NEEDS_FIXES
