# readlink Code Audit

Date: 2026-03-28
Auditor: reviewer agent
Reference: GNU coreutils readlink (primary), docs/specs/readlink-flags.md
Test suite: 33/33 integration tests pass, 16 unit tests pass
Assessment: NEEDS_FIXES

## Behavioral Comparison Environment

- GNU readlink: `/usr/bin/readlink` (coreutils 9.10 via Nix)
- Platform: Linux (Debian)

---

## CRITICAL Issues

### [CRITICAL] `-f` incorrectly requires ALL components to exist

Location: `src/readlink.zig:62-66`, `src/readlink.zig:151-155`

Problem: `getCanonicalizeMode()` maps both `-f` and `-e` to
`.strict`, which calls `std.fs.cwd().realpathAlloc()`. This
syscall fails if the final component does not exist. GNU
`readlink -f` allows the last component to be missing — only
the parent directory chain must exist ("all but the last
component must exist"). Our implementation rejects any path
where `realpathAlloc` fails, including the common and correct
case of a nonexistent last component.

Observed:
```
$ readlink -f /tmp/new_file_to_create
# GNU: /tmp/new_file_to_create  (exit 0)
# ours: (empty, exit 1)
```

Fix: Introduce a new canonicalize mode (e.g. `.strict_last_ok`)
for `-f` that calls `realpathAlloc` on the parent directory and
appends the final component, rather than running `realpathAlloc`
on the full path. Use the current `.strict` mode only for `-e`.

```zig
const CanonicalizeMode = enum {
    none,
    strict_last_ok,   // -f: all but last must exist
    strict,           // -e: all components must exist
    missing,          // -m: nothing need exist
};

fn getCanonicalizeMode(args: ReadlinkArgs) CanonicalizeMode {
    if (args.@"canonicalize-missing") return .missing;
    if (args.canonicalize) return .strict_last_ok;       // -f
    if (args.@"canonicalize-existing") return .strict;   // -e
    return .none;
}
```

In `resolveLink`, implement `.strict_last_ok`:
```zig
.strict_last_ok => {
    const parent = std.fs.path.dirname(path) orelse "/";
    const base = std.fs.path.basename(path);
    const resolved_parent = try std.fs.cwd().realpathAlloc(allocator, parent);
    defer allocator.free(resolved_parent);
    return try std.fs.path.join(allocator, &.{ resolved_parent, base });
},
```

---

### [CRITICAL] `-f` with dangling symlink exits 1, should exit 0

Location: `src/readlink.zig:580-598` (unit test also wrong)

Problem: This is a consequence of the above `-f` bug. A dangling
symlink `dangling.txt -> nonexistent_target` (relative) has an
absolute target of `{tmpdir}/nonexistent_target`. The parent
`{tmpdir}` exists. GNU `readlink -f` resolves this to
`{tmpdir}/nonexistent_target` and exits 0. Our implementation
calls `realpathAlloc` on the full path, which follows the
symlink to the nonexistent target and fails.

Observed:
```
$ ln -s nonexistent_target /tmp/test/dangling.txt
$ readlink -f /tmp/test/dangling.txt
# GNU: /tmp/test/nonexistent_target  (exit 0)
# ours: (empty, exit 1)
```

Fix: Fixed by the `-f` behavior fix above. The unit test at
line 580 ("readlink dangling symlink with -f fails") must also
be corrected — it currently asserts `expectEqual(@as(u8, 1), result)`
which is wrong. After the fix it should assert exit 0 and verify
the output is `{tmpdir}/nonexistent_target`.

---

## IMPORTANT Issues

### [IMPORTANT] `-n` with multiple arguments: no warning, wrong output

Location: `src/readlink.zig:118-120`

Problem: GNU emits a warning to stderr and ignores `-n` when
multiple arguments are given, using newlines for all output.
Our implementation silently applies `-n` to all files, stripping
every newline delimiter.

GNU behavior:
```
$ readlink -n link1 link2
readlink: ignoring --no-newline with multiple arguments
/target1
/target2
```

Our behavior:
```
/target1/target2   (no newlines, no warning)
```

Fix: After argument parsing, check if `parsed.@"no-newline"` is
set and `parsed.positionals.len > 1`. If so, emit the warning to
`stderr_writer` and clear the `no-newline` flag:

```zig
var no_newline = parsed.@"no-newline";
if (no_newline and parsed.positionals.len > 1) {
    common.printErrorWithProgram(allocator, stderr_writer, "readlink",
        "ignoring --no-newline with multiple arguments", .{});
    no_newline = false;
}
```

---

### [IMPORTANT] Unit test "canonicalize nonexistent fails with -f" is wrong

Location: `src/readlink.zig:380-388`

Problem: The test calls `readlink -f /tmp/definitely_nonexistent_readlink_test`.
The parent `/tmp` exists, so GNU exits 0 and outputs the path.
The test asserts exit 1. This test passes today only because
the implementation is wrong — it hides the `-f` semantics bug.

Fix: After fixing the `-f` behavior, update this test to assert:
- Exit code 0
- Output equals `/tmp/definitely_nonexistent_readlink_test\n`

---

### [IMPORTANT] Integration test "readlink -f nonexistent fails" is wrong

Location: `tests/utilities/readlink_test.sh:148-149`

Problem: `test_command_exit_code "readlink -f nonexistent fails" 1 \
    "$binary" -f "/tmp/nonexistent_readlink_canon_$$"`

When the parent `/tmp` exists, GNU exits 0. This test passes
today only because the implementation is incorrect.

Fix: Replace the exit-code test with a test that verifies the
output equals the absolute path, and that exit is 0.

---

### [IMPORTANT] Missing test: `-f` with truly nonexistent parent fails

Location: unit tests / integration tests

Problem: There is no test verifying that `-f` properly fails
when the parent directory itself does not exist (e.g.
`/nonexistent_parent/file`). This is the true failure case
that `-f` must distinguish.

Fix: Add a unit test:
```zig
test "readlink -f fails when parent nonexistent" {
    // ...
    const args = [_][]const u8{ "-f", "/nonexistent_parent_xyz/file" };
    const result = try runReadlink(...);
    try testing.expectEqual(@as(u8, 1), result);
}
```

And an integration test case alongside the existing `-f` tests.

---

## SUGGESTION Issues

### [SUGGESTION] `getCanonicalizeMode` doc comment is misleading

Location: `src/readlink.zig:53-65`

Problem: The `CanonicalizeMode.strict` variant is documented as
"all components must exist" but `-f` maps to it, and `-f`
semantics are "all but last must exist". The comment should
distinguish the two cases.

Fix: Rename `.strict` to `.strict_all` (for `-e`) and add
`.strict_last_ok` (for `-f`) with accurate doc comments.

---

### [SUGGESTION] No test for `-v` verbose output format

Location: unit tests

Problem: The verbose error test at line 283 checks that stderr
contains "No such file or directory" but does not verify the
format `readlink: {path}: {message}`. The IT test at line 280
checks only that stderr is nonempty.

Fix: Add an assertion that stderr matches the GNU format:
`readlink: /path: No such file or directory`.

---

## Test Coverage Summary

| Behavior | Unit | IT | Correct? |
|---|---|---|---|
| Basic symlink | yes | yes | ok |
| Relative symlink | no | yes | ok |
| Dangling symlink (no flags) | yes | yes | ok |
| `-f` last component missing | no | no | **missing** |
| `-f` dangling, parent exists | yes | no | **wrong assertion** |
| `-f` dangling, parent missing | no | no | **missing** |
| `-e` all must exist | yes | yes | ok |
| `-m` missing paths | yes | yes | ok |
| `-n` single file | yes | yes | ok |
| `-n` multiple files | no | no | **missing** |
| `-z` NUL delimiter | yes | yes | ok |
| `-v` verbose errors | yes | yes | ok |
| `-q` quiet | yes | yes | ok |
| Multiple files | yes | yes | ok |
| Mixed success/failure | yes | yes | ok |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -f requires only parent to exist, not last component
   — src/readlink.zig:62-66, resolveLink .strict branch
2. [CRITICAL] Unit test "dangling symlink with -f fails" expects wrong exit code
   — src/readlink.zig:580-598
3. [IMPORTANT] -n with multiple arguments: emit warning, ignore flag
   — src/readlink.zig:118-120
4. [IMPORTANT] Unit test "canonicalize nonexistent fails with -f" wrong
   — src/readlink.zig:380-388
5. [IMPORTANT] IT test "readlink -f nonexistent fails" wrong
   — tests/utilities/readlink_test.sh:148-149
6. [IMPORTANT] Add test for -f with truly nonexistent parent
   — src/readlink.zig (unit), readlink_test.sh (IT)
7. [SUGGESTION] Rename CanonicalizeMode variants for clarity
   — src/readlink.zig:54-60
8. [SUGGESTION] Strengthen -v output format assertion
   — src/readlink.zig:283
```

REVIEW COMPLETE - NEEDS_FIXES
