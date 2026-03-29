# chown Code Audit

**Date:** 2026-03-28
**Files reviewed:** `src/chown.zig`, `src/common/user_group.zig`
**Build:** PASSES (`just build-util chown`)
**Integration tests:** 83/83 PASS (`just it-util chown`)
**Unit tests:** Not runnable in isolation (build system hangs on full suite)

---

## Flag Verdict

| Flag | Tier | Verdict | Notes |
|------|------|---------|-------|
| -c   | SHOULD | PASS | Reports only changes |
| -f   | SHOULD | PASS | Suppresses errors |
| -h   | MUST | PASS | lchown() used correctly |
| -H   | MUST | PASS | Follows cmdline symlinks via stat() |
| -L   | MUST | PASS | Follows all symlinks during traversal |
| -n   | SHOULD | PASS | Rejects symbolic names (functional equivalent) |
| -P   | MUST | BUG | See CRITICAL #1 |
| -R   | MUST | BUG | See CRITICAL #1 (same root cause) |
| -v   | SHOULD | PASS | Reports operations |
| -x   | SHOULD | PASS | Stops at mount points |
| --reference | SHOULD | PASS | Uses stat() as required (always dereferences) |
| --dereference | SHOULD | PASS | Parse-only no-op (correct: it is the default) |
| --preserve-root | SHOULD | PASS | Blocks recursive `/` |
| --no-preserve-root | SHOULD | PASS | Parse-only no-op (correct: it is the default) |

---

## Issues

```
[CRITICAL] -P and default -R incorrectly traverse into cmdline symlink-to-dir
Location: src/chown.zig:388
Problem: chownRecursive() always calls FileInfo.stat() (which follows symlinks) to
  determine whether to recurse. When -P is set (or by default with -R and no
  -H/-L/-P flag), a symlink-to-directory passed on the command line should have its
  ownership changed without descending into the target directory. Instead, stat()
  follows the symlink, sees a directory, and recurses into the target.

  Confirmed with:
    mkdir target; touch target/file.txt; ln -s target link
    fakeroot chown -RP -v 999 link
    # Output: changes both link/file.txt AND link — should only change link

  macOS spec: "-P Do not traverse any symbolic links. Instead, the user and/or group
  ID of the link itself are modified. This is the default."

  Note: symlinks encountered DURING traversal are handled correctly at line 424
  (they stop at the symlink and do not recurse). The bug is only at the entry point
  of chownRecursive when the path IS the cmdline argument.

Fix: At line 388, when no_traverse_symlinks is true (or when neither traverse_all_symlinks
  nor traverse_cmdline_symlinks is set), use lstat() instead of stat() so the symlink
  is not followed:
    const stat_info = if (options.no_traverse_symlinks or
        (!options.traverse_all_symlinks and !options.traverse_cmdline_symlinks))
        try common.file.FileInfo.lstat(path)
    else
        try common.file.FileInfo.stat(path);
```

```
[CRITICAL] 'user:' format does not set group to user's primary (login) group
Location: src/common/user_group.zig:74-87
Problem: When the owner spec is "user:" (a user name or UID followed by a colon
  and no group), POSIX/GNU/macOS all require that the group be changed to the
  user's primary login group. The current code leaves group as null (unchanged)
  when group_part is empty after the colon.

  Confirmed with:
    # User 1000 (tcole) has primary group 1000
    fakeroot chown -v tcole: file
    # Output: "changed ownership of 'file' from 0:0 to 1000:0"
    # Expected: "changed ownership of 'file' from 0:0 to 1000:1000"

  GNU --help output: "Group is unchanged if missing, but changed to login group if
  implied by a ':' following a symbolic OWNER."
  macOS help says the same.

Fix: In OwnershipSpec.parse(), when the colon is present and group_part is empty,
  look up the user's primary group (via getpwuid/getpwnam) and set result.group:
    if (group_part.len == 0 and result.user != null) {
        result.group = try getPrimaryGroupForUid(result.user.?, allocator);
    }
  Add a helper that calls getpwuid() and returns pw_gid.
```

```
[IMPORTANT] chownFile() is dead code: tests exercise it but runChown() bypasses it
Location: src/chown.zig:307-332
Problem: chownFile() is called only from unit tests (11 call sites), never from
  runChown(). runChown() calls chownSingle() and chownRecursive() directly after
  pre-parsing ownership (lines 192-224). The unit tests therefore exercise a
  different and partially inconsistent code path:
  - chownFile() re-parses the owner spec from scratch, ignoring any pre-parsed
    OwnershipSpec that runChown() would have produced.
  - chownFile() skips the -n validation that runChown() performs at lines 184-189.
  The tests for chownFile() pass but they are not testing the actual execution path
  used by main().

Fix: Remove chownFile(). Rewrite the unit tests to call runChown() with appropriate
  args slices, or call chownSingle()/chownRecursive() directly with a pre-constructed
  OwnershipSpec. Alternatively, make runChown() delegate through chownFile() so
  there is one code path.
```

```
[IMPORTANT] -H/-L/-P unit tests are parse-only — no behavioral verification
Location: src/chown.zig:1019-1058 ("privileged: chown traverse options")
Problem: The traverse options test creates a regular file (not a directory), sets
  traverse_all_symlinks=true and no_traverse_symlinks=true, and calls chownFile().
  Because the target is not a directory, no traversal occurs at all. The test
  verifies only that the flags parse and that the function does not crash; it does
  not verify that -L actually follows symlinks during traversal or that -P actually
  stops at them. Per the project's own testing rules: "A test that checks
  parsed.follow == true without verifying the program actually follows the file is
  not a real test."

Fix: Write behavioral tests that create a directory containing a symlink-to-subdir,
  then verify:
  - With -L: ownership changes in the symlinked subtree
  - With -P: only the symlink itself is changed, not the subtree
  - With -H: a cmdline symlink-to-dir IS entered; symlinks inside are NOT
```

```
[IMPORTANT] Integration test for 'user:' format only checks exit code
Location: tests/utilities/chown_test.sh:51-53
Problem: The integration test "chown user: format" and "chown uid: format" call
  test_command_succeeds, which only verifies exit code 0. It does not stat the file
  afterward to confirm the group was changed to the user's primary group. Because the
  login-group bug (CRITICAL #2) exists, this test passes while hiding the wrong behavior.

Fix: After calling chown with "user:" format, stat the file and assert that its group
  equals the user's primary gid:
    chown "$current_user:" "$test_file"
    actual_gid=$(stat -c %g "$test_file")
    expected_gid=$(id -g "$current_user")
    assert_equals "chown user: sets login group" "$expected_gid" "$actual_gid"
```

```
[SUGGESTION] -vv (double verbose) not implemented: macOS has two-level verbosity
Location: src/chown.zig:26-30, 503-509
Problem: macOS documents two distinct verbosity levels for -v: single -v shows each
  file being modified; double -vv additionally prints the old and new numeric
  user/group IDs. The current ChownArgs struct uses a bool for verbose, collapsing
  both levels to the same behavior. The implementation always prints the full
  "changed ownership of 'X' from UID:GID to UID:GID" message regardless of how
  many -v flags are given.
  This is a minor macOS compat gap; GNU does not have this distinction.

Fix: Change verbose to a count (u8), and in reportNoChange / reportChange, check
  the count: level 1 prints only the filename, level 2 prints old and new IDs.
  This matches macOS behavior.
```

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 3 |
| SUGGESTION | 1 |

**Assessment: NEEDS_FIXES**

The integration suite passes 83/83 because the tests check only exit codes for the
affected cases. Both critical bugs produce wrong ownership silently.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] 'user:' format leaves group unchanged instead of setting login group
   — src/common/user_group.zig:74-87
2. [CRITICAL] -RP (and default -R) follows cmdline symlink-to-dir, violating -P semantics
   — src/chown.zig:388
3. [IMPORTANT] Add behavioral tests for -H/-L/-P symlink traversal
   — src/chown.zig:1019-1058
4. [IMPORTANT] Fix integration test for 'user:' format to verify group value
   — tests/utilities/chown_test.sh:51-53
5. [IMPORTANT] Remove or wire in chownFile() dead code
   — src/chown.zig:307-332
6. [SUGGESTION] Implement two-level -v verbosity to match macOS behavior
   — src/chown.zig:26-30, 503-509
```

REVIEW COMPLETE - NEEDS_FIXES
