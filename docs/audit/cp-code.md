# Code Audit: cp

**Date**: 2026-03-28
**Re-audit note**: Original report used macOS as the primary
behavioral reference. Corrected framing: **GNU coreutils is
the primary reference**. Flags present in GNU must match GNU
semantics. Flags absent from GNU but present in macOS/OpenBSD
follow that platform's spec. Findings F1, F2, F5, and F6 are
reclassified below.

**Source**: src/cp.zig
**Specs**: cp-gnu.txt (PRIMARY), cp-flags.md (flag matrix)

## Executive Summary

NEEDS_FIXES

The implementation covers the core copy mechanics correctly
(file copy, recursive directory copy, symlinks, hard links,
backup, verbose). One flag has genuinely wrong behavior (-N),
two flags have partial implementations (-p, -f), and two
flags are complete stubs (-c, -X). Several findings from the
original report are cleared after correcting the spec frame.

---

## Reclassifications from Original Report

**F1 (-N wrong semantics) — CRITICAL downgraded to IMPORTANT**

The original report said -N is wrong per macOS spec because
our implementation treats it as a symlink no-dereference flag.
The flag matrix confirms -N appears only in macOS (not GNU).
So macOS semantics apply: -N with -p should suppress copying
BSD file flags (`chflags`-style: hidden, immutable, etc.).
Our implementation treats -N identically to -P (symlink
follow_none), which is wrong, but the severity is IMPORTANT,
not CRITICAL, because this is a macOS-only extension.

**F2 (-S wrong semantics) — CLEARED**

The original report called -S wrong because we implement GNU
backup-suffix semantics while macOS -S means suppress sparse
holes. The flag matrix shows -S exists in BOTH macOS and GNU
with different meanings. Since GNU is the primary reference,
our GNU behavior (backup suffix / `--suffix=SUFFIX`) is
CORRECT. The macOS sparse-hole suppression does not apply.
The "CONFIRMED BUG" in the dynamic verification table was
based on the wrong spec frame.

**F5 (-P/-H/-L without -R) — CLEARED**

The original report said these flags must be ignored without
-R, citing the macOS spec. The GNU man page says nothing about
ignoring them without -R; `-H`, `-L`, and `-P` simply control
symlink follow behavior for SOURCE operands. Under GNU
semantics, applying them without -R is correct. The
"CONFIRMED BUG" in the dynamic verification table was a
false positive.

**F6 (-r should imply -L) — CLEARED**

The original report said -r should behave like -RL (macOS
FreeBSD compat note). The GNU man page explicitly states
`-R, -r, --recursive` are all synonyms. Under GNU semantics,
-r = -R with no implied -L. Our implementation is correct.

---

## Flag-by-Flag Compliance (Updated)

| Flag | Tier | Parsed? | Implemented? | Correct? | Notes |
|------|------|---------|--------------|----------|-------|
| -a | MUST | yes | yes | yes | -dR --preserve=all semantics correct |
| -b | SHOULD | yes | yes | yes | Backup with rename suffix |
| -c | SHOULD | yes | no | no | STUB: macOS-only; parsed, no clonefile |
| -d | SHOULD | yes | yes | yes | --no-dereference --preserve=links |
| -f | MUST | yes | yes | partial | Always unlinks; GNU says only when open fails |
| -H | MUST | yes | yes | yes | Follows cmdline symlinks when set |
| -i | MUST | yes | yes | yes | Interactive prompt works |
| -l | SHOULD | yes | yes | yes | Hard links created |
| -L | MUST | yes | yes | yes | Follows all symlinks |
| -n | SHOULD | yes | yes | yes | No-clobber works |
| -N | SHOULD | yes | yes | no | WRONG: symlink no-deref instead of suppress file flags |
| -p | MUST | yes | partial | partial | Mode+timestamps preserved; uid/gid not preserved |
| -P | MUST | yes | yes | yes | Never follow symlinks |
| -R | MUST | yes | yes | yes | Recursive copy correct |
| -r | MUST | yes | yes | yes | GNU synonym for -R; correct |
| -s | SHOULD | yes | yes | yes | Symbolic links created |
| -S | SHOULD | yes | yes | yes | GNU backup suffix; correct per primary spec |
| -v | MUST | yes | yes | yes | Verbose output correct |
| -x | SHOULD | yes | yes | partial | Linux correct; openFile on dir silently fails on macOS |
| -X | SHOULD | yes | no | no | STUB: macOS-only; parsed, no EA logic |
| --backup | SHOULD | yes | yes | yes | Same as -b |
| --parents | SHOULD | yes | yes | yes | Full path created under dest |
| --preserve | SHOULD | yes | partial | partial | All ATTR values treated identically |

---

## Findings

### [IMPORTANT] -f always unlinks destination
**Location**: `src/cp.zig:487-492`

GNU spec: "if an existing destination file cannot be opened,
remove it and try again."

The implementation unconditionally unlinks the destination
whenever `-f` is set and the destination exists, even when
the file is writable:

```zig
if (fileExists(dest_path) and options.force) {
    handleForceOverwrite(dest_path) catch |err| { ... };
}
```

This breaks hard links pointing to the destination (the link
is severed by the unlink even when unnecessary). The correct
behavior is to attempt to open the destination for writing
first; only unlink if that attempt fails.

**Fix**: Attempt `openFile(dest_path, .{ .mode = .write_only })`
first. Only call `handleForceOverwrite` on `error.AccessDenied`
or `error.PermissionDenied`.

---

### [IMPORTANT] -p does not preserve ownership (uid/gid)
**Location**: `src/cp.zig:654-678` (`copyFileWithAttributes`)

GNU spec: `-p` is `--preserve=mode,ownership,timestamps`.
Ownership means uid and gid must be copied via `chown`.

The implementation preserves mode (via `createFile` mode
argument) and timestamps (via `updateTimes`) but never reads
uid/gid from the source and never calls `chown` or `fchown`
on the destination. GNU cp silently ignores chown failures
when not running as root (EPERM is non-fatal), but the
attempt must be made.

`std.fs.File.Stat` does not expose uid/gid. The fix requires
calling `std.posix.stat()` to obtain the raw `std.posix.Stat`
struct and then `std.posix.fchown()` on the destination fd.

**Fix**: In `copyFileWithAttributes`, after writing the file,
call `std.posix.stat(source_path, &src_stat)` and then
`std.posix.fchown(dest_file.handle, src_stat.uid, src_stat.gid)`
with EPERM silently ignored.

---

### [IMPORTANT] -N implements wrong behavior
**Location**: `src/cp.zig:61`, `src/cp.zig:106`

-N is macOS-only (not in GNU). macOS spec: "When used with
-p, do not copy file flags." File flags are BSD `chflags(2)`
values (hidden, immutable, nodump, etc.).

Our implementation sets `symlink_mode = .follow_none` when
`-N` is present (line 61: `self.P or self.no_dereference or
self.N or is_archive`), treating -N as equivalent to -P.
The help text reads "Do not follow symbolic links in source"
which matches -d/-P, not the macOS -N meaning.

Since -p ownership preservation is not yet implemented (see
above), -N's interact with -p cannot be tested until that
is fixed. However, the flag mapping is clearly wrong.

**Fix**: Remove `self.N` from the `follow_none` branch.
Store a `suppress_file_flags: bool` in RuntimeOptions. In
`copyFileWithAttributes`, when `suppress_file_flags` is
false and on macOS, copy BSD file flags via `fchflags(2)`.
On Linux, no-op (no BSD flags).

---

### [IMPORTANT] Special files not recreated under -R
**Location**: `src/cp.zig:471-475`

GNU spec (`--copy-contents` aside): with `-R`, cp copies
special files as special files (devices, fifos). Without
`-copy-contents`, a fifo in the source tree should become
a fifo in the dest tree, and a character device should
become a character device.

The implementation returns an error for all special files
regardless of whether `-R` is set:

```zig
.special => blk: {
    common.printErrorWithProgram(..., "'{s}': unsupported file type", ...);
    break :blk false;
},
```

**Fix**: In the `-R` path, detect special file kind from the
raw `std.posix.Stat.mode` field and call `std.posix.mknod`
to recreate fifos (S_IFIFO) and device nodes (S_IFCHR,
S_IFBLK) at the destination.

---

### [IMPORTANT] -x uses openFile on directory (silent failure on macOS)
**Location**: `src/cp.zig:596`, `src/cp.zig:626`

The one-file-system code opens a directory path with
`openFile()` to obtain a device ID via `fstat`. On Linux
this succeeds. On macOS `openFile()` on a directory returns
`EISDIR`, which the `catch break :blk null` silently swallows,
setting `source_dev = null` and disabling the filesystem
boundary check entirely.

**Fix**: Use `std.posix.stat()` directly on the path instead
of `openFile` + `fstat`. This avoids the directory-open
restriction on macOS.

---

### [SUGGESTION] -c stub with misleading help text
**Location**: `src/cp.zig:104`, help text line ~796

-c is macOS-only. Parsed and stored but never wired to any
behavior. The help text says "(no-op)". On macOS, `-c` should
attempt `clonefile(2)` with fallback to a regular copy.
On Linux `clonefile` does not exist; silent fallback is
acceptable. The "(no-op)" label is misleading because it
implies permanent intent rather than unimplemented work.

**Fix**: Either remove "-c" until it is implemented, or
change the help text to note that it has no effect on Linux.

---

### [SUGGESTION] -X stub with misleading help text
**Location**: `src/cp.zig:110`, help text line ~814

-X is macOS-only. Parsed and stored but the field is never
referenced in `RuntimeOptions` or any copy path. No
extended-attribute logic exists. The help text says "(no-op)".

On macOS, `-X` should suppress copying EAs and resource forks.
On Linux EAs are uncommon but the flag still has no effect.

**Fix**: Same options as -c: either remove until implemented,
or be explicit in help text that it has no effect on Linux.

---

## I/O Correctness

No I/O issues found:

- Uses `.writerStreaming()` on both stdout and stderr
  (lines 160, 164) — correct
- 8192-byte buffers for both (lines 159, 163) — correct
- Both flushed before `std.process.exit()` (lines 170-171)
  — correct
- Errors go to `stderr_writer`, output to `stdout_writer`
  — correct

---

## Dynamic Verification

Build: `zig build` succeeded with no errors.

Previously confirmed bugs cleared by spec reclassification:

| Scenario | Status |
|----------|--------|
| -S .bak sets backup suffix | CORRECT (GNU primary) |
| -P without -R: copies symlink itself | CORRECT (GNU has no ignore rule) |
| -r without -L: no symlink follow | CORRECT (GNU -r = -R synonym) |

Remaining confirmed bugs:

| Scenario | Status |
|----------|--------|
| -f on writable file unconditionally unlinks | CONFIRMED BUG |
| -p does not preserve uid/gid | CONFIRMED BUG |
| -N sets symlink_mode instead of suppress-file-flags | CONFIRMED BUG |
| -x device check fails silently on macOS | CONFIRMED BUG (Linux passes) |
| Special files in -R mode return error | CONFIRMED BUG |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -f always unlinks — src/cp.zig:487-492
2. [IMPORTANT] -p missing chown — src/cp.zig:654-678 (copyFileWithAttributes)
3. [IMPORTANT] -N wrong semantics — src/cp.zig:61,106
4. [IMPORTANT] Special files in -R mode — src/cp.zig:471-475
5. [IMPORTANT] -x openFile on directory — src/cp.zig:596,626
6. [SUGGESTION] -c stub / misleading help text — src/cp.zig:104
7. [SUGGESTION] -X stub / misleading help text — src/cp.zig:110
```

REVIEW COMPLETE - NEEDS_FIXES
