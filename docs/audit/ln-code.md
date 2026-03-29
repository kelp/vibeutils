# ln Code Audit

**Date:** 2026-03-28
**File:** `src/ln.zig`
**Build:** passes (`just build-util ln`)
**Integration tests:** 57/57 pass
**Assessment:** NEEDS_FIXES

---

## Flag Verdict Table

| Flag | Tier | Verdict | Notes |
|------|------|---------|-------|
| -f | MUST | PASS | Correctly removes existing destination |
| -L | MUST | PASS | Follows symlinks for hard links via `linkat` |
| -P | MUST | PASS | Hard links to symlink itself via `linkat` flags=0 |
| -s | MUST | PASS | Creates symbolic links |
| -h | MUST | STUB (CRITICAL) | Parsed, stored, never read in logic |
| -n | MUST | STUB (CRITICAL) | Same field as -h; never read in logic |
| -i | SHOULD | BROKEN (CRITICAL) | 'y' response doesn't delete existing file |
| -v | SHOULD | PASS (minor issue) | Correct output; -r shows wrong target in verbose |
| -F | SHOULD | WRONG (IMPORTANT) | Activates force without -s; violates macOS spec |
| -w | SHOULD | PASS | Warns on dangling symlink target |
| -b | SHOULD | PARTIAL (IMPORTANT) | Works but ignores SIMPLE_BACKUP_SUFFIX env var |
| -r | SHOULD | PASS | Relative symlinks created correctly |
| -t | SHOULD | PASS | Creates links in target directory |
| -T | SHOULD | PASS | Treats LINK_NAME as normal file |

---

## CRITICAL Issues

### [CRITICAL] -h and -n are parsed but never applied

**Location:** `src/ln.zig:211`, `src/ln.zig:278`

**Problem:** `no_dereference` is populated at line 211 and stored in
`LinkOptions` at line 278, but `grep` for `options.no_dereference` in
the file returns zero results. `createSingleLink` never consults the
flag. When `link_name` is a symlink to an existing directory, the code
follows the symlink through to the directory instead of treating
`link_name` as a normal file.

Concrete failure:

```
mkdir real_dir
ln -s real_dir dir_link
ln -sfn target.txt dir_link    # should replace dir_link
# result: target.txt created INSIDE real_dir as a circular symlink
# dir_link still points to real_dir
```

The integration test `"ln -sfn replaces symlink"` only tests a symlink
to a regular file (not a directory), so it passes despite the stub.
The macOS man page example (`ln -shf baz foo`) is the canonical test
case; it silently misbehaves here.

**Fix:** In `createSingleLink`, when `options.no_dereference` is true
and `link_name` is a symlink to a directory:

1. Use `std.fs.cwd().statFile()` with `FollowSymlinks.no` (lstat) to
   detect the symlink without following it.
2. Set `link_exists = true` based on the lstat result.
3. When removing the existing entry under `--force`, use
   `deleteFile(link_name)` directly (which unlinks without following
   the symlink on both Linux and macOS).

---

### [CRITICAL] -i with 'y' fails to remove existing destination

**Location:** `src/ln.zig:423-454`

**Problem:** After the user types 'y' at the interactive prompt, the
code falls through to `symLink`/`linkat` without first removing the
existing destination. The call fails with `PathAlreadyExists`.

```
echo "old" > existing.txt
echo "y" | ln -si target.txt existing.txt
# ln: replace 'existing.txt'? ln: cannot create symbolic link
#   'existing.txt' to 'target.txt': PathAlreadyExists
# exit: 1
```

The interactive 'y' path (line ~447) exits the `if` block but there
is no deletion code there. The deletion at line 466 is only reached
when `options.force` is true.

**Fix:** After the 'y' branch (line ~449), insert:

```zig
// Delete the existing destination before relinking
std.fs.cwd().deleteFile(link_name) catch |del_err| switch (del_err) {
    error.FileNotFound => {},
    else => {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name,
            "cannot remove '{s}': {s}", .{ link_name, @errorName(del_err) });
        return del_err;
    },
};
```

---

## IMPORTANT Issues

### [IMPORTANT] -F activates force without -s, violating macOS spec

**Location:** `src/ln.zig:209`

**Problem:** `LnArgs` maps `-F` to `force_dir`, and line 209 sets
`.force = parsed_args.force or parsed_args.force_dir`. This means
`-F` alone (without `-s`) enables forced removal of existing hard link
destinations.

macOS man page states: "The -F option is a no-op unless -s is
specified." Our implementation silently overwrites existing files when
`-F` is given without `-s`.

Verified:

```
echo "new" > existing_hard_target.txt
ln -F source.txt existing_hard_target.txt
# exit 0, existing_hard_target.txt is replaced
# macOS /bin/ln would refuse (file exists)
```

**Fix:** In `createLinks` (or when building `LinkOptions`), only set
`force = parsed_args.force_dir` when `parsed_args.symbolic` is also
true. When `-F` is used without `-s`, treat it as if neither `-f` nor
`-F` was given.

---

### [IMPORTANT] -b ignores SIMPLE_BACKUP_SUFFIX environment variable

**Location:** `src/ln.zig:459`

**Problem:** The backup suffix is hardcoded to `~` at line 459:

```zig
const backup_name = try std.fmt.allocPrint(allocator, "{s}~", .{link_name});
```

GNU ln reads `SIMPLE_BACKUP_SUFFIX` to override the default `~`. Our
implementation ignores it.

Verified:

```
echo "existing" > test.txt
SIMPLE_BACKUP_SUFFIX=".bak" ln -sb target.txt test.txt
ls test.txt*
# our:  test.txt~        (wrong - should be test.txt.bak)
# GNU:  test.txt.bak     (correct)
```

**Fix:** Before building the backup name, read the env var:

```zig
const suffix = std.posix.getenv("SIMPLE_BACKUP_SUFFIX") orelse "~";
const backup_name = try std.fmt.allocPrint(allocator, "{s}{s}",
    .{ link_name, suffix });
```

---

### [IMPORTANT] --backup=CONTROL panics instead of clean error

**Location:** `src/ln.zig:183-190`

**Problem:** `--backup=simple` (with `=CONTROL` argument) causes an
unhandled `ParseError.TooManyValues` panic at runtime with a Zig stack
trace:

```
/home/tcole/code/vibeutils/zig-out/bin/ln --backup=simple target.txt link
# error: TooManyValues
# argparse.zig:227: in parseLongFlagWithValue
# ... full stack trace printed ...
# exit: 1
```

The error handler at line 183 catches `UnknownFlag`, `MissingValue`,
and `InvalidValue` but not `TooManyValues`. GNU ln accepts
`--backup=CONTROL` and selects the version control method.

**Fix (minimal):** Add `error.TooManyValues` to the error switch at
line 183:

```zig
error.TooManyValues => {
    common.printErrorWithProgram(allocator, stderr_writer, prog_name,
        "option '--backup' does not allow an argument", .{});
    return @intFromEnum(common.ExitCode.misuse);
},
```

**Fix (correct):** Implement `--backup=CONTROL` by changing `backup`
from `bool` to `?[]const u8` and parsing the control word.

---

### [IMPORTANT] -v with -r shows original target, not stored relative path

**Location:** `src/ln.zig:587-593`

**Problem:** When `-v` (verbose) is combined with `-r` (relative
symlinks), the verbose output shows the original target argument, not
the actual relative path stored in the symlink. GNU ln shows the
stored path.

```
ln -svr target.txt subdir/link.txt
# ours:  'subdir/link.txt' -> 'target.txt'   (wrong)
# GNU:   'subdir/link.txt' -> '../target.txt' (correct)
```

**Fix:** In `createSingleLink`, pass `target_path` (the computed
relative path) to the verbose print instead of `target`:

```zig
if (options.verbose) {
    if (options.symbolic) {
        try stdout_writer.print("'{s}' -> '{s}'\n",
            .{ link_name, target_path });  // was: target
    } else {
        try stdout_writer.print("'{s}' => '{s}'\n",
            .{ link_name, target });
    }
}
```

Note: `target_path` is currently declared inside the `if
(options.symbolic)` block scope. It must be hoisted to be accessible
at the verbose print site.

---

## SUGGESTION Issues

### [SUGGESTION] -b and -i interact incorrectly: backup bypasses prompt

**Location:** `src/ln.zig:423`

**Problem:** The condition `if (link_exists and !options.force and
!options.backup)` means that when both `-b` and `-i` are given, the
backup is created and the link replaced without any interactive prompt.
GNU ln still prompts when `-i` is set even with `-b`:

```
echo "n" | ln -sbi target.txt existing.txt
# GNU:   prompts, user says n, no backup created, original preserved
# ours:  no prompt, backup created, link replaced silently
```

**Fix:** Remove `!options.backup` from the condition at line 423 (or
check `options.interactive` separately). The backup should only happen
after the user confirms.

---

### [SUGGESTION] Integration tests don't cover the -h/-n stub with symlink-to-directory

**Location:** `tests/utilities/ln_test.sh:389-434`

**Problem:** All `-n` tests use a symlink to a regular file as
`LINK_NAME`. The bug in `-h`/`-n` only manifests when `LINK_NAME` is a
symlink to an **existing directory**. The passing tests give false
confidence that `-n` is implemented.

**Fix:** Add a test case:

```bash
mkdir real_dir
ln -s real_dir dir_link
"$binary" -sfn target.txt dir_link
if [[ "$(readlink dir_link)" == "target.txt" ]]; then
    print_test_result "ln -sfn replaces symlink-to-dir" "PASS"
else
    print_test_result "ln -sfn replaces symlink-to-dir" "FAIL" \
        "link still points to $(readlink dir_link)"
fi
```

---

### [SUGGESTION] -w applies warn check for hard links

**Location:** `src/ln.zig:541`

**Problem:** `isTargetMissing` is called when `options.warn_missing`
is true regardless of whether `options.symbolic` is set. For hard
links the target access check at line 546 already enforces existence
(the link will fail if the target is missing), so the warning is
redundant and slightly misleading. macOS defines `-w` as "Warn if the
source of a symbolic link does not currently exist" — implying it only
applies to symlinks.

**Fix:** Guard the warn check:

```zig
if (options.symbolic and options.warn_missing and
    isTargetMissing(target_path, link_name))
{
    ...
}
```

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 4 |
| SUGGESTION | 3 |

**Overall assessment: NEEDS_FIXES**

```
Fix Order:
1. [CRITICAL] -h/-n stub: no_dereference never applied — src/ln.zig:211,278
2. [CRITICAL] -i with 'y' fails to remove existing dest — src/ln.zig:447
3. [IMPORTANT] -F without -s incorrectly enables force — src/ln.zig:209
4. [IMPORTANT] --backup=CONTROL panics (TooManyValues uncaught) — src/ln.zig:183
5. [IMPORTANT] -b ignores SIMPLE_BACKUP_SUFFIX env var — src/ln.zig:459
6. [IMPORTANT] -v with -r shows original target not relative path — src/ln.zig:587
7. [SUGGESTION] -b+i: backup bypasses interactive prompt — src/ln.zig:423
8. [SUGGESTION] Integration tests miss -h/-n with symlink-to-dir — ln_test.sh:389
9. [SUGGESTION] -w check runs for hard links — src/ln.zig:541
```

REVIEW COMPLETE - NEEDS_FIXES
