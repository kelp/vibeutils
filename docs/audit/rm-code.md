# rm Code Audit

**Date:** 2026-03-28
**Auditor:** reviewer agent
**File:** `src/rm.zig`
**Result:** NEEDS_FIXES

---

## Flag Verdict Table

| Flag | Tier | Status | Notes |
|------|------|--------|-------|
| `-f` | MUST | PASS | Correct: suppresses errors and prompts |
| `-i` | MUST | PASS | Correct: prompts per file |
| `-r` | MUST | PASS | Correct: recursive removal |
| `-R` | MUST | PASS | Alias for `-r`, works |
| `-d` | MUST | PASS* | Works but has verbose-suppression bug |
| `-v` | MUST | PASS* | Works but suppressed by `-d` verbose bug |
| `-P` | MUST | PASS | Correct no-op (BSD compatibility) |
| `-I` | SHOULD | PASS | Prompts once for >3 files or recursive |
| `-x` | SHOULD | PASS | No-cross-device implemented |
| `-W` | SHOULD | FAIL | Deletes files instead of undeleting; exits 0 |
| `--preserve-root` | SHOULD | PASS | Blocks `/`, `//`, `/.` correctly |
| `--no-preserve-root` | SHOULD | PASS | Disables root check |

---

## Issues

### [CRITICAL] `-W` flag deletes files instead of attempting undelete

**Location:** `src/rm.zig:89-92` and `removeFiles()` call at line 107

**Problem:** `-W` (undelete) is supposed to attempt to recover files
covered by whiteouts in a union filesystem. The implementation prints
a warning but then proceeds to call `removeFiles()`, which deletes the
files. The exit code is 0. All three behaviors are wrong:
1. The file is deleted (should not be touched).
2. Exit code is 0 (should be 1 — undelete failed).
3. The stub comment says "skip undelete operation" but skipping only
   the undelete means the deletion still runs.

**Fix:**

```zig
if (parsed_args.undelete) {
    common.printErrorWithProgram(allocator, stderr_writer, "rm",
        "-W (undelete) not supported on this system", .{});
    return @intFromEnum(common.ExitCode.general_error);
}
```

Return immediately after the error. Do not fall through to
`removeFiles()`.

---

### [IMPORTANT] `-f`/`-i` flag ordering: force always wins, ignoring
last-flag-wins semantics

**Location:** `src/rm.zig:287-303` (`removeItem`)

**Problem:** macOS `rm` treats `-f` and `-i` as mutually exclusive
with last-one-wins semantics: `-fi` means interactive (the final
flag), while `-if` means force. The implementation stores both as
independent booleans and always checks `force` first, so `-fi` and
`-if` both behave as force (no prompt). On macOS, `rm -fi file` would
prompt.

**Fix:** Track which of `-f` or `-i` was specified last during
argument parsing (e.g., by recording the parse order or using an enum
`{ none, force, interactive }`), and honor only the last one.

---

### [IMPORTANT] Write-protected file prompt issued even when stdin is
not a tty

**Location:** `src/rm.zig:294-303` (`removeItem`)

**Problem:** POSIX specifies: "If the permissions of the file do not
permit writing, and the standard input device is a terminal, the user
is prompted." The implementation calls `promptYesNo` without first
checking `std.posix.isatty(std.fs.File.stdin().handle)`. When stdin is
a pipe or `/dev/null`, rm prompts on stderr (visible) and reads EOF
from stdin, which causes it to treat the file as "not removed" and
exit 1. Correct behavior when stdin is not a tty: skip the prompt and
proceed with the removal (or fail with no message if a real permission
error occurs).

**Fix:**

```zig
} else {
    // Default mode: prompt only for write-protected files
    // when stdin is a terminal (POSIX requirement)
    const mode = stat_result.mode;
    const user_write = (mode & 0o200) != 0;
    if (!user_write and std.posix.isatty(std.fs.File.stdin().handle)) {
        if (!try common.prompt.promptYesNo(stderr_writer,
            "rm: remove write-protected regular file '{s}'? ",
            .{file_path})) {
            return error.UserCancelled;
        }
    } else if (!user_write) {
        // stdin not a tty: attempt removal (OS will reject if
        // truly unwritable)
    }
}
```

---

### [IMPORTANT] `-d` verbose output suppressed by unrelated prior error

**Location:** `src/rm.zig:245`

**Problem:** The verbose output for a successful `-d` directory
removal is gated on the loop-wide `any_errors` flag:

```zig
if (!any_errors and options.verbose) {
    try stdout_writer.print("removed directory '{s}'\n", .{file});
}
```

If an earlier operand in the same invocation caused an error (setting
`any_errors = true`), verbose output is silently suppressed for all
subsequent successful `-d` removals. The directory is still removed
but not reported. Verified dynamically:

```
$ rm -dv /nonexistent /tmp/emptydir
rm: cannot remove '/nonexistent': No such file or directory
# no "removed directory" line printed, even though emptydir was deleted
```

**Fix:** Track success per item. Move the verbose print to immediately
after `deleteDir` succeeds, before the `catch` block:

```zig
std.fs.cwd().deleteDir(file) catch |dir_err| {
    switch (dir_err) { ... set any_errors ... }
    continue; // skip verbose on error
};
// Reaches here only on success
if (options.verbose) {
    try stdout_writer.print("removed directory '{s}'\n", .{file});
}
```

---

### [SUGGESTION] `-I` prompt message is generic for recursive case

**Location:** `src/rm.zig:175`

**Problem:** `rm -rI dir` prints `rm: remove 1 arguments?` even
though only one directory is named. GNU rm prints
`remove directory 'dir' and its contents?` for the recursive case.
The current message is grammatically odd for a single argument and
less informative than the GNU form.

**Fix:** When `options.recursive` is true and `files.len == 1`, use:

```zig
if (!try common.prompt.promptYesNo(stderr_writer,
    "rm: remove directory '{s}' and its contents? ", .{files[0]}))
```

For `files.len > 3` with no recursive, keep the current form.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| IMPORTANT | 3 |
| SUGGESTION | 1 |

**Overall: NEEDS_FIXES**

### Fix Order

```
Fix Order:
1. [CRITICAL] -W deletes files instead of returning error — src/rm.zig:89-92,107
2. [IMPORTANT] Write-protected prompt ignores stdin tty check — src/rm.zig:294-303
3. [IMPORTANT] -d verbose suppressed by prior error in loop — src/rm.zig:245
4. [IMPORTANT] -f/-i ordering: force always wins, last-flag-wins missing — src/rm.zig:287
5. [SUGGESTION] -I prompt message is generic for recursive single-dir case — src/rm.zig:175
```
