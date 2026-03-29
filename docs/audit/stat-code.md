# stat Code Audit

**Date:** 2026-03-28
**File:** `src/stat.zig`
**Build:** passes (`zig build`)
**Tests:** all unit and integration tests pass

> **Re-audit note (2026-03-28):** The original audit was
> written under incorrect framing (macOS stat as reference).
> This report uses GNU coreutils as the primary behavioral
> reference, per `docs/specs/stat-flags.md`. Findings that
> were based solely on BSD/macOS divergence have been removed.
> The `%r`/`%R` and sub-field specifier gaps are valid GNU
> correctness issues and are retained. The Device line format
> finding is reclassified: our `1fh/31d` output follows BSD
> convention; GNU outputs `major,minor` in decimal, making
> this a genuine GNU conformance bug.

---

## CRITICAL

---

**[CRITICAL] Default output: spurious `+` prefix on all
numeric fields**
Location: `src/stat.zig:675`
Problem: `{d: <10}` with a space-fill alignment specifier on
a *signed* integer type causes Zig's formatter to prefix `+`
on non-negative values. `stat_buf.size`, `stat_buf.blocks`,
and `stat_buf.blksize` are signed types in `c.Stat` on Linux.
Output produced:
```
  Size: +1840     Blocks: +0         IO Block: +4096
```
GNU produces:
```
  Size: 1840      	Blocks: 0          IO Block: 4096
```
Confirmed by compiling a minimal reproduction with Zig 0.15.2.
Fix: cast to unsigned before printing:
```zig
try writer.print(
    "  Size: {d: <10}Blocks: {d: <11}IO Block: {d: <7}{s}\n",
    .{
        @as(u64, @intCast(stat_buf.size)),
        @as(u64, @intCast(stat_buf.blocks)),
        @as(u64, @intCast(stat_buf.blksize)),
        file_type,
    });
```

---

**[CRITICAL] macOS `StatFs` struct used unconditionally on
Linux — corrupts all `-f` (file-system) output**
Location: `src/stat.zig:20-38` and `:811-842`
Problem: The `StatFs` extern struct at lines 20–38 is the
macOS layout. On Linux, `statfs(2)` uses a different struct
(`struct statfs64`): `f_type` is a 64-bit value at offset 0,
`f_bsize` is also 64-bit, and the field order differs. The
macOS struct is used unconditionally with no
`if (builtin.os.tag == .linux)` guard, so every `-f` call on
Linux reads garbage field values.

GNU stat on `/tmp`:
```
  File: "/tmp"
  Type: tmpfs  Block size: 4096
  Blocks: Total: 1016702  Free: 646219
```
Our output on Linux produces garbage block-size and type
values from the wrong struct layout.
Fix: define a separate `StatFsLinux` extern struct matching
Linux's `struct statfs64` layout and select it at comptime:
```zig
const StatFs = if (builtin.os.tag == .macos or
    builtin.os.tag.isDarwin())
    StatFsMacos
else
    StatFsLinux;
```

---

**[CRITICAL] `-f` (file-system mode) ignores `-c`/`--format`
and `--printf`**
Location: `src/stat.zig:876-883`
Problem: The `file_system` branch (line 876) calls
`printFileSystemInfo` unconditionally then `continue`s,
never reaching the `opts.format` / `opts.printf_fmt` check.
GNU stat applies the format string to filesystem data when
`-f` and `-c` are combined. Format specifiers valid with
`-f` include `%n`, `%i`, `%l`, `%t`, `%s`, `%S`, `%b`,
`%f`, `%a`, `%c`, `%d`.
```
$ stat -f -c "%n" /tmp   # GNU → /tmp
$ ./stat -f -c "%n" /tmp # ours → full default filesystem block
```
Fix: when `opts.file_system` is true and a format string
is set, apply the format using filesystem stat specifiers
rather than calling `printFileSystemInfo`.

---

**[CRITICAL] Format specifiers `%r` and `%R` missing**
Location: `src/stat.zig:352-585` (`expandFormatDirective`)
Problem: GNU stat defines `%r` (device type in decimal,
`st_rdev`) and `%R` (device type in hex, `st_rdev`). Neither
case exists in the switch; both fall through to the `else`
branch which emits the literal string `%r` / `%R`.
```
$ stat -c "%r" /tmp   → 0
$ ./stat -c "%r" /tmp → %r
```
Fix: add cases to the switch:
```zig
'r' => try writer.print("{d}", .{stat_buf.rdev}),
'R' => try writer.print("{x}", .{stat_buf.rdev}),
```

---

**[CRITICAL] Terse output (`-t`) has wrong field count and
wrong field order vs GNU**
Location: `src/stat.zig:776-795`
Problem: The GNU man page defines terse format as equivalent
to:
```
%n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o
```
(16 space-separated fields). The current implementation
emits 14 fields in an incorrect order with two missing fields:

1. Fields 10–11 (`%t` major-device-hex, `%T`
   minor-device-hex) are absent.
2. Field 15 (`%W` birth-time seconds) is absent.
3. Field 14 is a duplicate of `%b` (blocks) rather than
   `%o` (optimal I/O block size, `blksize`).

Current output (14 fields):
```
/tmp 1840 0 43ff 0 0 1f 1 37 1774712562 1774713306 1774713306 4096 0
```
GNU output (16 fields):
```
/tmp 1840 0 43ff 0 0 1f 1 37 0 0 1774712562 1774713306 1774713306 1774049268 4096
```
Fix: rewrite `printTerseFormat` to emit the documented
16-field format, computing `%t`/`%T` (major/minor of
`st_rdev`) and `%W` (birth time, 0 when unknown):
```zig
fn printTerseFormat(stat_buf: c.Stat, path: []const u8,
    writer: anytype) !void {
    const mode: u32 = @intCast(stat_buf.mode);
    const dev: u64 = @intCast(stat_buf.dev);
    const rdev: u64 = @intCast(stat_buf.rdev);
    const major_val = majorDevice(rdev);
    const minor_val = minorDevice(rdev);
    try writer.print(
        "{s} {d} {d} {x} {d} {d} {x} {d} {d} {x} {x}" ++
        " {d} {d} {d} {d} {d}\n",
        .{
            path,
            stat_buf.size, stat_buf.blocks, mode,
            stat_buf.uid, stat_buf.gid, dev,
            stat_buf.ino, stat_buf.nlink,
            major_val, minor_val,
            getTimespecSec(stat_buf, .atime),
            getTimespecSec(stat_buf, .mtime),
            getTimespecSec(stat_buf, .ctime),
            getTimespecSec(stat_buf, .btime), // 0 when unknown
            stat_buf.blksize,
        });
}
```

---

## IMPORTANT

---

**[IMPORTANT] Default output: Device line uses BSD format
instead of GNU format**
Location: `src/stat.zig:684`
Problem: Line 684 prints `Device: 1fh/31d` (hex+`h`
suffix / decimal+`d` suffix) — the BSD `stat -x` convention.
GNU stat outputs `Device: major,minor` in decimal with no
letter suffixes, e.g. `Device: 8,1`.
Fix: extract major and minor from the device number and print
them decimal with a comma separator:
```zig
const dev_major = (dev >> 8) & 0xfff;  // Linux glibc major()
const dev_minor = dev & 0xff;           // Linux glibc minor()
try writer.print(
    "Device: {d},{d}\tInode: {d: <12}Links: {d}\n",
    .{ dev_major, dev_minor, stat_buf.ino, stat_buf.nlink });
```
Note: major/minor extraction is platform-specific; gate with
comptime for macOS vs Linux (same as the `%t`/`%T` cases).

---

**[IMPORTANT] `%m` (mount point) always returns empty string
on Linux**
Location: `src/stat.zig:424-440`
Problem: `%m` calls `statfs()` and reads `f_mntonname`,
which is a macOS-specific field. The macOS-layout `StatFs`
struct is used on Linux (the StatFs CRITICAL above), so
`f_mntonname` reads garbage or zero bytes, producing an
empty mount point.
```
$ stat -c "%m" /tmp   → /tmp
$ ./stat -c "%m" /tmp → (empty)
```
Fix: on Linux, look up the mount point by scanning
`/proc/self/mountinfo` for the entry whose device number
matches `st_dev`. On macOS, `f_mntonname` is valid once the
struct is correctly platform-gated (depends on StatFs
CRITICAL fix).

---

**[IMPORTANT] Birth time (`%w`, `%W`) always returns `-`/`0`
on Linux**
Location: `src/stat.zig:229-233`
Problem: `getTimespecSec(.btime)` returns `0` on non-Darwin
platforms (line 230). Linux kernels ≥ 4.11 expose birth time
via `statx(2)` with `STATX_BTIME`. The implementation falls
back to `0` unconditionally without attempting `statx`.
```
$ stat -c "%W" /tmp   → 1774049268  (real birth time)
$ ./stat -c "%W" /tmp → 0
```
Fix: on Linux, call `statx(2)` with `STATX_BTIME` to
retrieve birth time. Fall back to `0`/`-` if the syscall
fails or the filesystem does not support it.

---

**[IMPORTANT] Sub-field specifiers (`%Hd`, `%Ld`, `%Hr`,
`%Lr`) completely unimplemented**
Location: `src/stat.zig:591-641` (`processFormatString`)
Problem: GNU stat supports two-character format directives
where the first character is `H`, `L`, or `M` (sub-field
modifier). `%Hd` = major device decimal, `%Ld` = minor device
decimal, `%Hr` = major rdev decimal, `%Lr` = minor rdev
decimal. `processFormatString` reads one byte after `%` and
dispatches; it never reads a second byte for sub-field
modifiers. All such specifiers fall through to the `else`
branch and emit literal text.
```
$ stat -c "%Hd %Ld" /tmp   → 0 31
$ ./stat -c "%Hd %Ld" /tmp → %Hd %Ld
```
Fix: in `processFormatString`, after consuming `%`, check
whether the next byte is `H`, `L`, or `M`; if so, read one
more character and dispatch to a `expandSubfieldDirective`
function.

---

**[IMPORTANT] Terse test verifies only that output is
non-empty, not field correctness**
Location: `src/stat.zig:1367-1390`
Problem: The `"stat -t terse output"` test checks that
output is one line starting with the path. It does not
verify field count, field order, or any field values. The
test passes even with the current 14-field bug.
Fix: parse the terse output into fields and assert
`count == 16`; assert fields 10–11 are hex strings
(major/minor); assert field 15 is a non-negative integer
(birth time).

---

**[IMPORTANT] Exit code 2 for missing operand; GNU stat
exits 1**
Location: `src/stat.zig:869`
Problem: Our code returns `ExitCode.misuse = 2` for a
missing operand. GNU stat exits 1. This is a project-wide
convention that deliberately diverges from GNU. The
integration test at `tests/utilities/stat_test.sh:129`
documents and enforces this non-GNU behavior, which is
acceptable as a known project convention but should be
recorded explicitly in `docs/specs/stat-flags.md` so
it is not treated as a bug later.

---

## SUGGESTIONS

---

**[SUGGESTION] `%C` (SELinux context) emits literal `%C`
instead of `?` when unsupported**
Location: `src/stat.zig:579-584` (else branch)
Problem: GNU stat outputs `?` for `%C` when SELinux is not
available. Our implementation prints the literal `%C` via the
unknown-directive fallback.
Fix: add an explicit `'C'` case:
```zig
'C' => try writer.writeAll("?"),
```

---

**[SUGGESTION] Dead conditional in `%o` branch**
Location: `src/stat.zig:459-465`
Problem: Both branches of the macOS/non-macOS conditional
execute the same `writer.print("{d}", .{stat_buf.blksize})`
statement.
Fix: collapse to a single unconditional statement.

---

**[SUGGESTION] `statfs` failure always reported as "No such
file or directory"**
Location: `src/stat.zig:878`
Problem: The error message is hardcoded regardless of the
actual errno (e.g., `EACCES`, `EIO`).
Fix: propagate the actual error from `printFileSystemInfo`
and map it using the same switch already used for regular
stat errors at line 886–896.

---

## Summary

| Severity   | Count |
|------------|-------|
| CRITICAL   | 5     |
| IMPORTANT  | 5     |
| SUGGESTION | 3     |

**Assessment: BLOCKED**

All five critical findings from the original report survive
re-audit unchanged — each is a genuine GNU correctness bug,
not a BSD/macOS divergence. The Device line format finding
is reclassified from CRITICAL to IMPORTANT (correct GNU
behavior required, but does not corrupt data). All other
findings are unchanged.

The implementation follows the correct GNU interface, but has
five blocking correctness bugs: spurious `+` signs on all
numeric fields (confirmed in Zig 0.15.2), a macOS-only
`StatFs` struct producing garbage on all Linux `-f` calls,
`-c` format silently ignored when combined with `-f`, missing
`%r`/`%R` format specifiers, and terse output with wrong
field count and order.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] + sign on numeric fields — src/stat.zig:675
   (cast stat_buf.size/blocks/blksize to u64 before print)
2. [CRITICAL] StatFs struct wrong on Linux — src/stat.zig:20
   (add Linux-specific struct, gate with comptime)
3. [CRITICAL] %r and %R missing — src/stat.zig:361
   (add cases to expandFormatDirective switch)
4. [CRITICAL] -f ignores -c/--format — src/stat.zig:876
   (check opts.format before calling printFileSystemInfo)
5. [CRITICAL] Terse output wrong fields/order — src/stat.zig:776
   (rewrite printTerseFormat to 16-field GNU format)
6. [IMPORTANT] Device line format wrong (BSD vs GNU) — src/stat.zig:684
   (use major,minor decimal not hex/dec with letter suffixes)
7. [IMPORTANT] %m empty on Linux — src/stat.zig:424
   (implement mount-point lookup via /proc/self/mountinfo)
8. [IMPORTANT] Birth time 0 on Linux — src/stat.zig:229
   (use statx(2) on Linux to retrieve STATX_BTIME)
9. [IMPORTANT] Sub-field specifiers unimplemented — src/stat.zig:591
   (handle H/L/M prefix in processFormatString)
10. [IMPORTANT] Terse test too weak — src/stat.zig:1367
    (verify 16-field count and field values)
11. [SUGGESTION] %C should print ? — src/stat.zig:579
12. [SUGGESTION] Dead conditional in %o — src/stat.zig:459
13. [SUGGESTION] statfs error message hardcoded — src/stat.zig:878
```

REVIEW COMPLETE - BLOCKED
