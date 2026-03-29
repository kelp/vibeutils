# realpath Code Audit

Date: 2026-03-28
Auditor: reviewer agent
Reference: GNU coreutils realpath 9.10 (primary), docs/specs/realpath-flags.md
Test suite: 50/50 integration tests pass, 14 unit tests pass
Assessment: NEEDS_FIXES

## Behavioral Comparison Environment

- GNU realpath: `/nix/store/.../coreutils-9.10/bin/realpath` (GNU 9.10)
- Platform: Linux (Debian)

---

## CRITICAL Issues

### [CRITICAL] Default mode uses all-components-must-exist (-e), not -E semantics

Location: `src/realpath.zig:124-132`, `src/realpath.zig:19`

Problem: GNU `realpath` default mode is `-E`: "all but the last
component must exist." When no canonicalization flag is given,
GNU resolves the path and succeeds even when the last component
is missing, provided all parent directories exist. Our default
calls `std.fs.cwd().realpathAlloc()`, which fails if the final
component does not exist — matching `-e` semantics, not the
GNU default.

The help text explicitly labels our `-e` as "(default)" which
is wrong: GNU's default is `-E`, not `-e`.

Observed:
```
$ realpath /tmp/new_file_to_create
# GNU: /tmp/new_file_to_create  (exit 0)
# ours: (error, exit 1)

$ realpath -e /tmp/new_file_to_create
# GNU: realpath: No such file or directory  (exit 1)
# ours: realpath: FileNotFound  (exit 1)  ← correct for -e
```

Fix: The default processing branch must use `-E` semantics:
resolve symlinks in all parent components but allow the final
component to be absent. Implement a `resolveDefaultMode()`
function that calls `realpathAlloc` on the parent directory and
appends the basename:

```zig
fn resolveDefaultMode(allocator: Allocator, path: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(path) orelse "/";
    const base = std.fs.path.basename(path);
    const resolved_parent = try std.fs.cwd().realpathAlloc(allocator, parent);
    defer allocator.free(resolved_parent);
    return try std.fs.path.join(allocator, &.{ resolved_parent, base });
}
```

Change `processPath`:
```zig
// Default mode: -E semantics (all but last must exist)
break :blk resolveDefaultMode(allocator, path) catch |err| { ... };
```

Also fix the help text: remove "(default)" from the `-e` description.

---

### [CRITICAL] Error messages use `@errorName` instead of POSIX strings

Location: `src/realpath.zig:113`, `src/realpath.zig:120`, `src/realpath.zig:127`

Problem: When a path resolution fails, `processPath` passes
the raw Zig error name to `printErrorWithProgram` via
`@errorName(err)`. This produces `FileNotFound` instead of the
POSIX string `No such file or directory`, `NotDir` instead of
`Not a directory`, etc.

Observed:
```
$ realpath /nonexistent_xyz 2>&1
# GNU: realpath: /nonexistent_xyz: No such file or directory
# ours: realpath: /nonexistent_xyz: FileNotFound
```

By contrast, `readlink.zig` correctly maps errors to POSIX
strings in its `resolveLink` error handler (line 126-132).
`realpath.zig` has no such mapping.

Fix: Add an error-to-string mapping in `processPath`, mirroring
what `readlink.zig` does:

```zig
const err_msg = switch (err) {
    error.FileNotFound => "No such file or directory",
    error.NotDir       => "Not a directory",
    error.AccessDenied => "Permission denied",
    error.NameTooLong  => "File name too long",
    else               => "cannot resolve path",
};
common.printErrorWithProgram(allocator, stderr_writer, "realpath",
    "{s}: {s}", .{ path, err_msg });
```

This fix is needed in all three `err` catch arms inside
`processPath` (default mode, `-m`, and `-e`), and also in the
two arms resolving `base_dir` for `--relative-to` /
`--relative-base`.

---

### [CRITICAL] Unit test "nonexistent path fails by default" tests wrong behavior

Location: `src/realpath.zig:382-391`

Problem: The test asserts that `realpath /nonexistent/path/...`
exits 1. This passes today only because the implementation uses
wrong `-e` semantics as the default. After correcting the
default mode to `-E`, this test must be updated: a path where
only the last component is missing should succeed (exit 0), and
a path where an intermediate component is missing should fail
(exit 1).

Fix: Replace with two tests:
1. Last component missing, parent exists → expect exit 0.
2. Intermediate component missing → expect exit 1.

---

### [CRITICAL] Integration test "nonexistent path fails" tests wrong behavior

Location: `tests/utilities/realpath_test.sh:52`

Problem: `test_command_exit_code "nonexistent path fails" 1 \
    "$binary" /nonexistent_vibeutils_path 2>/dev/null`

`/nonexistent_vibeutils_path` has `/` as its parent, which
exists. GNU exits 0. This test passes today only because the
implementation is wrong.

Fix: Replace with:
- A test that passes `/nonexistent_parent_xyz/file` (parent
  missing) and expects exit 1.
- A test that passes `/tmp/nonexistent_last_xyz` (parent /tmp
  exists) and expects exit 0.

---

## IMPORTANT Issues

### [IMPORTANT] `-e` flag does not change behavior from (wrong) default

Location: `src/realpath.zig:39`, `src/realpath.zig:117-131`

Problem: The `canonicalize_existing` field defaults to `false`.
When set to `true` via `-e`, `processPath` falls through to the
same `realpathAlloc` call used as the default. Once the default
is corrected to `-E` semantics, `-e` must remain using strict
`realpathAlloc` (all components must exist). Currently the
flag has no behavioral effect — both default and `-e` run the
same code path.

Fix: After fixing the default mode, verify that `-e` continues
to use `realpathAlloc` for strict checking. Add a test:
```zig
test "realpath -e requires all components to exist" {
    // /tmp exists, /tmp/nonexistent does not
    const args = [_][]const u8{ "-e", "/tmp/nonexistent_vibeutils_last" };
    const result = try runRealpath(testing.allocator, &args, ...);
    try testing.expectEqual(@as(u8, 1), result);
}
```

---

### [IMPORTANT] Help text incorrectly labels `-e` as the default

Location: `src/realpath.zig:39`, `src/realpath.zig:270`

Problem: The help string reads:
```
-e, --canonicalize-existing  all components must exist (default)
```
GNU's default is `-E` ("all but the last component must exist"),
not `-e`. The parenthetical "(default)" is factually wrong and
will mislead users.

Fix: Remove "(default)" from the `-e` help line. Optionally
add a line explaining the default mode:
```
The default mode is: all but the last component must exist.
```

---

### [IMPORTANT] No test for `-s` with nonexistent intermediate path

Location: unit tests, integration tests

Problem: `-s` (no-symlinks / logical resolution) does not call
`realpathAlloc` and resolves paths purely by cleaning `.` and
`..`. Tests verify it against `/usr/bin/../lib` but never test
that it succeeds when paths are wholly nonexistent. The positive
case `/completely/nonexistent/path` works correctly — a
behavioral test would prevent regression.

Fix: Add an integration test:
```bash
test_command_output "-s with nonexistent path" \
    "/nonexistent/path" "$binary" -s /nonexistent/path
test_command_exit_code "-s nonexistent exits 0" 0 \
    "$binary" -s /nonexistent/path
```

---

### [IMPORTANT] `--relative-to` and `--relative-base` resolve base using same mode as path

Location: `src/realpath.zig:136-194`

Problem: When `--relative-to=DIR` or `--relative-base=DIR` is
used, the base directory is resolved using the same
canonicalization mode as the input path. If the default mode is
fixed to `-E` semantics, the base resolution must also be
updated. A missing base directory that should fail under `-e`
but succeed under default mode now follows the same logic.
Currently there is no test that verifies the base resolution
uses the correct mode.

Fix: Add a test covering `--relative-to` with a nonexistent
base (should fail with default mode after the fix).

---

## SUGGESTION Issues

### [SUGGESTION] `resolveLogical` (-s) not tested with relative input paths

Location: `src/realpath.zig:51-100`, unit tests

Problem: All unit tests for `resolveLogical` use absolute
inputs. The function converts relative paths by prepending
`cwd`, but this code path has no test coverage.

Fix: Add a unit test that passes a relative path and verifies
the output is absolute:
```zig
test "realpath: resolveLogical relative path" {
    // Assumes cwd is known or at least absolute
    const result = try resolveLogical(testing.allocator, "usr/bin/../lib");
    defer testing.allocator.free(result);
    try testing.expect(std.fs.path.isAbsolute(result));
    try testing.expect(std.mem.endsWith(u8, result, "/usr/lib") or
        std.mem.endsWith(u8, result, "/lib"));
}
```

---

### [SUGGESTION] Multiple-paths-with-some-failing unit test is a no-op

Location: `src/realpath.zig:461-475`

Problem: The test `"realpath: multiple paths with some failing"` discards
the result (`_ = result`) and makes no assertions. It
effectively tests nothing. The comment explains the reasoning
but the test should be marked to skip or rewritten.

Fix: Either delete the test or rewrite it to use default mode
(not `-s`) to actually observe partial failure:
```zig
// /tmp should succeed, nonexistent should fail
const args = [_][]const u8{ "/tmp", "/nonexistent_vibeutils_xyz" };
const result = try runRealpath(...);
// After default mode fix: exit 0 (both succeed, /tmp/* OK)
// OR: test with -e so nonexistent fails
```

---

## Test Coverage Summary

| Behavior | Unit | IT | Correct? |
|---|---|---|---|
| Default mode: last component missing | no | **wrong** | **WRONG** |
| Default mode: intermediate missing, fail | no | no | **missing** |
| `-e` all must exist | partial | yes | ok |
| `-m` missing paths | yes | yes | ok |
| `-s` logical resolution | yes | yes | ok |
| `-s` relative input | no | no | **missing** |
| `--strip` alias | yes | yes | ok |
| `-z` NUL delimiter | yes | yes | ok |
| `-q` quiet suppresses errors | yes | yes | ok |
| `--relative-to` | yes | yes | ok |
| `--relative-base` | yes | yes | ok |
| `--relative-base` prefix boundary | yes | yes | ok |
| Error message POSIX format | no | no | **wrong** |
| Multiple paths partial failure | **no-op** | partial | **weak** |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Default mode wrong: must implement -E semantics
   — src/realpath.zig:124-132, processPath default branch
2. [CRITICAL] Error messages use @errorName not POSIX strings
   — src/realpath.zig:113,120,127 (and base resolution arms)
3. [CRITICAL] Unit test "nonexistent path fails by default" wrong
   — src/realpath.zig:382-391
4. [CRITICAL] IT test "nonexistent path fails" wrong
   — tests/utilities/realpath_test.sh:52
5. [IMPORTANT] -e flag has no distinct behavior from (wrong) default
   — src/realpath.zig:117-131 (verify after default fix)
6. [IMPORTANT] Help text labels -e as default (wrong)
   — src/realpath.zig:270
7. [IMPORTANT] Add test: -s with wholly nonexistent path
   — tests/utilities/realpath_test.sh
8. [SUGGESTION] Test resolveLogical with relative input
   — src/realpath.zig (unit tests)
9. [SUGGESTION] Fix no-op multiple-paths-with-failure test
   — src/realpath.zig:461-475
```

REVIEW COMPLETE - NEEDS_FIXES
