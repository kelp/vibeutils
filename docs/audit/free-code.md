# Code Audit: free

**Date:** 2026-03-28
**File:** `src/free.zig`
**Build:** Passes (`just build-util free`)
**Tests:** 37/37 unit pass; 16/16 integration pass
**Result:** NEEDS_FIXES

---

## Summary of Findings

- 0 CRITICAL
- 3 IMPORTANT
- 3 SUGGESTION

---

## Issues

### [IMPORTANT] `-s` short flag hijacked by the `si` bool field
Location: `src/free.zig:211` (`si` field), `src/free.zig:236`
(`seconds.short = 's'`)

Problem: `FreeArgs` declares `si: bool` with no explicit `short`
in its meta entry. The argparse `getShortFlag` function returns
`name[0]` for single-word field names with no underscore, so `"si"`
maps to `'s'`. Because `si` is declared before `seconds` in the
struct, `parseShortFlag` matches `'s'` as the `si` bool and returns
`true` before `parseShortFlagWithValue` ever reaches the `seconds`
optional field.

Consequence: both `-s N` (space) and `-sN` (no space) are broken:
- `-s 1 -c 2`: `si=true`, `"1"` becomes a positional, exits 2
  with "extra operand '1'"
- `-s1`: `si=true`, `"1"` is an unknown flag, exits 2 with
  "unrecognized option"

The only working forms are `--seconds=N` and `--seconds N`. Since
`-s N` is the canonical GNU invocation, continuous mode is
effectively unreachable via its documented short flag.

Fix: Add an explicit `short = 0` (or any sentinel meaning
"no short flag") to `si`'s meta entry, or rename the field to
`use_si` so `getShortFlag` returns `0` (no match). The simplest
safe fix:

```zig
.si = .{ .short = 0, .desc = "Use powers of 1000 instead of 1024" },
```

Check whether argparse treats `short = 0` as "no short flag";
if not, rename the field to `use_si`.

---

### [IMPORTANT] `-w` wide mode always shows 0 for the buffers column
Location: `src/free.zig:314`

Problem: `printMemRow` hardcodes `0` for the buffers column when
`wide == true`:

```zig
try printValue(writer, 0, unit, use_si);       // buffers: always 0
try printValue(writer, info.buff_cache, unit, use_si); // cache
```

`MemInfo.buff_cache` is the merged sum (`buffers + cached +
SReclaimable` on Linux; `inactive + speculative + compressor pages`
on macOS). Once merged, the individual `buffers` value is lost.
GNU `free -w` shows the actual kernel buffer allocation in the
`buffers` column and `cached + SReclaimable` in the `cache`
column. Our output always prints `0` for buffers regardless of
platform.

Fix: Add a `buffers` field to `MemInfo` and populate it on Linux
from the `Buffers:` `/proc/meminfo` line (already parsed into the
local variable `buffers` at line 128 but discarded into
`buff_cache`). On macOS, store `0`. Use that field for the wide
`buffers` column and compute `buff_cache - buffers` (or a separate
`cache` field) for the `cache` column.

---

### [IMPORTANT] `-c N` without `-s` silently displays once; GNU
rejects it
Location: `src/free.zig:417-419`

Problem: The comment says "If -c is given without -s, treat as a
single display". GNU `free` exits with an error: `free: -c requires
-s option`. Our implementation silently ignores the intent of `-c`
and displays once, giving the user no feedback that their invocation
was wrong.

Fix: Detect `-c` given without `-s` and emit an error:

```zig
if (repeat_count != 0 and interval == 0) {
    common.printErrorWithProgram(allocator, stderr_writer,
        prog_name, "-c requires -s option", .{});
    return @intFromEnum(common.ExitCode.misuse);
}
```

---

### [SUGGESTION] `/proc/meminfo` buffer is fixed at 8192 bytes;
silent truncation on large systems
Location: `src/free.zig:121-123`

Problem: `getMemInfoLinux` reads `/proc/meminfo` into a fixed
`[8192]u8` stack buffer. `File.readAll` silently stops at `buf.len`
and returns the count read; it does not error on overflow. On a
typical system `/proc/meminfo` is around 1.5 KB, but heavily
configured machines (many NUMA nodes, memory zones, or kernel
versions with additional fields) can exceed 8 KB. If truncation
occurs, fields that appear late in the file (e.g. `SReclaimable`,
`SwapFree`) are silently zero, producing wrong output with no error.

Fix: Either increase the buffer to 32 KiB (conservative ceiling for
any realistic `/proc/meminfo`), or read line-by-line using
`std.io.BufferedReader` so the file size is irrelevant.

---

### [SUGGESTION] `--seconds=0` is silently treated as "no interval"
Location: `src/free.zig:415-419`

Problem: `parsed.seconds` is `?u32`. When `--seconds=0` is given,
`interval = 0` and the code falls into the single-display branch.
The user's explicit `0` is silently discarded. GNU `free` rejects
it: `free: seconds argument '0' is not positive`.

Fix: After parsing, validate `interval > 0` when `-s` was
explicitly provided:

```zig
if (parsed.seconds) |sec| {
    if (sec == 0) {
        common.printErrorWithProgram(allocator, stderr_writer,
            prog_name, "seconds argument '0' is not positive", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }
}
```

---

### [SUGGESTION] Help text advertises `-s N` which is currently broken
Location: `src/free.zig:492`

Problem: The help line reads `-s N, --seconds=N` implying `-s N`
(space-separated) works. Because of the `-s`/`si` conflict
(IMPORTANT issue above), `-s N` exits with "extra operand" and
`-sN` exits with "unrecognized option". The help text is
misleading until the flag collision is fixed.

Fix: Fix the underlying `-s` collision first (IMPORTANT #1). Once
fixed, no separate help change is needed; the documented behavior
will match the implementation.

---

## Behavioral Notes (not bugs, informational)

**`-c N` without `-s` interaction:** Addressed in IMPORTANT #3
above.

**`--si` flag works correctly:** `--si` produces SI-scaled output
(powers of 1000). Verified with `free --si -h` showing `GB`/`MB`
suffixes and numeric values consistent with dividing by 1000.

**Swap row column count:** Swap prints only `total`, `used`,
`free` (3 numeric columns) while Mem prints 6. This matches GNU
`free` behavior.

**macOS memory mapping:** The macOS implementation uses
`host_statistics64` (Mach API). The `shared` field maps to
purgeable pages and `buff_cache` to inactive + speculative +
compressor pages. These are reasonable approximations but differ
from Linux semantics.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -s hijacked by si bool field — src/free.zig:211
2. [IMPORTANT] -w buffers column always 0 — src/free.zig:314
3. [IMPORTANT] -c without -s silently succeeds — src/free.zig:417
4. [SUGGESTION] --seconds=0 not validated — src/free.zig:415
5. [SUGGESTION] /proc/meminfo 8192-byte silent truncation — src/free.zig:121
6. [SUGGESTION] Help text for -s misleading (fixed by #1) — src/free.zig:492
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
