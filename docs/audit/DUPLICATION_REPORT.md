# Vibeutils Code Duplication & Reuse Opportunities Report

**Date:** 2026-04-04
**Codebase:** 73,156 lines of Zig, 47 utilities, 26 common modules
**Sources:** 5 independent audit agents (summary, section-A, stub-report, remediation-plan, refactoring-roadmap), cross-referenced against actual codebase

---

## Executive Summary

Cross-referencing all 5 audit agents reveals **9 major duplication patterns** spanning
113+ files. The highest-confidence finding — error-to-POSIX-string mapping — was
independently flagged by **all 5 agents** and has 9 separate reimplementations plus
114 raw `@errorName` call sites. Phase 0 created the common functions
(`posixErrorString`, `printTryHelp`, `isatty` guard) but **zero utilities have adopted
them yet**. The biggest wins are consolidating the 9 error mapping functions (~280 lines
saved) and rolling out `posixErrorString` to replace 114 `@errorName` sites.

**Top-line numbers:**
- 9 independent `error→string` mapping functions → 1 common function
- 114 raw `@errorName` call sites → use `posixErrorString`
- 5 independent numeric-with-suffix parsers → 1 common function
- 4 utilities with independent `force/interactive/no_clobber` booleans → 1 shared enum
- 3 utilities with independent backup suffix logic → 1 common module
- 28 utilities missing "Try --help" hint → use `printTryHelp`
- 2 independent `parseIso8601` implementations → 1 common module

---

## 1. Patterns Found by 3+ Agents (Highest Confidence)

### 1.1 Error-to-POSIX-String Mapping (All 5 agents)

**Similarity:** 80–95% (identical switch structure, overlapping error sets, all fall back to `@errorName`)

Nine independent implementations of the same pattern — map Zig errors to POSIX strings:

| # | File | Function | Line | Errors Mapped | Notes |
|---|------|----------|------|---------------|-------|
| 1 | `src/common/lib.zig` | `posixErrorString` | 130 | 15 | **Phase 0 canonical** — not yet adopted |
| 2 | `src/cp.zig` | `getStandardErrorName` | 809 | 28 | Most complete; includes cp-specific errors |
| 3 | `src/tee.zig` | `errorToMessage` | 180 | 12 | Includes `BrokenPipe`, `DiskQuota` |
| 4 | `src/head.zig` | `errorToMessage` | 380 | 3 | Minimal: FileNotFound, AccessDenied, IsDir |
| 5 | `src/tail.zig` | `errorToMessage` | 405 | 6 | Includes PermissionDenied, DeviceBusy |
| 6 | `src/mkdir.zig` | `errorToMessage` | 314 | 7 | Includes PathAlreadyExists, ReadOnlyFS |
| 7 | `src/chmod.zig` | `errorToMessage` | 798 | 3 | Minimal: FileNotFound, AccessDenied, NotDir |
| 8 | `src/rmdir.zig` | `formatError` | 67 | 5 | Includes DirNotEmpty |
| 9 | `src/realpath.zig` | `posixErrorName` | 103 | 8 | Includes SymLinkLoop, InvalidPath |
| 10 | `src/ls/main.zig` | `posixErrorName` | 543 | 6 | Includes InputOutput |

**Additionally:** 114 raw `@errorName(err)` call sites across 30+ files that bypass any mapping entirely:
- `src/rm.zig`: 7 sites (lines 225, 243, 264, 389, 404, 439, 466)
- `src/ln.zig`: 12 sites (lines 433, 472, 489, 501, 506, 514, 544, 562, 570, 586, 615, 1192)
- `src/dd.zig`: 18 sites (lines 552, 564, 575, 591, 634, 644, 653, 694, 731, 736, 755, 763, 787, 804, 817, 822, 838, 854)
- `src/sort.zig`: 6 sites (lines 459, 464, 502, 524, 560, 580)
- `src/find.zig`: 6 sites (lines 2197, 2203, 2561, 2622, 2644, 2676)
- `src/cat.zig`: 4 sites (lines 116, 125, 131, 140)
- `src/grep.zig`: 4 sites (lines 1026, 1047, 1253, 1267)
- `src/cut.zig`: 7 sites (lines 425, 481, 491, 495, 509, 513, 531)
- `src/uniq.zig`: 4 sites (lines 183, 199, 248, 252)
- `src/wc.zig`: 3 sites (lines 230, 243, 252)
- `src/nl.zig`: 4 sites (lines 641, 650, 655, 664)
- `src/env.zig`: 4 sites (lines 189, 210, 461, 466)
- `src/tac.zig`: 1 site (line 127)
- `src/touch.zig`: 1 site (line 588)
- `src/du.zig`: 1 site (line 574)
- `src/pwd.zig`: 1 site (line 61)
- `src/timeout.zig`: 1 site (line 112)
- `src/chown.zig`: 1 site (line 396)
- `src/cp.zig`: 2 sites (lines 550, 718) — these use `@errorName` despite `getStandardErrorName` existing in the same file

**Agents that flagged:** Summary (Theme A1/A2), Section-A (Theme E pattern b), Stub-Report (implicit), Remediation-Plan (I-MV-05, mkdir SUGGESTION), Roadmap (A1/A2)

---

### 1.2 "Try --help" Hint Duplication (4 agents)

**Similarity:** 100% (identical string pattern, duplicated inline in every error path)

The hint `"Try '<prog> --help' for more information."` is:
- **Present as inline strings** in 19 utilities across 54 call sites
- **Missing entirely** from 28 utilities
- **Available as `common.printTryHelp()`** since Phase 0 — **zero adopters**

Utilities with inline duplication (should use `printTryHelp`):
| Utility | File | Count | Example Line |
|---------|------|-------|--------------|
| chmod | `src/chmod.zig` | 2 | 95, 119 |
| chown | `src/chown.zig` | 1 | 112 |
| cp | `src/cp.zig` | 2 | 201, 205 |
| cut | `src/cut.zig` | 8 | 282, 286, 290, 315, 320, 328, 334, 340 |
| du | `src/du.zig` | 3 | 608, 612, 616 |
| env | `src/env.zig` | 2 | 89, 93 |
| grep | `src/grep.zig` | 1 | 1190 |
| mktemp | `src/mktemp.zig` | 4 | 85, 89, 93, 113 |
| mv | `src/mv.zig` | 4 | 845, 849, 871, 875 |
| nl | `src/nl.zig` | 5 | 584, 588, 592, 612, 614 |
| sleep | `src/sleep.zig` | 1 | 116 |
| sort | `src/sort.zig` | 2 | 197, 301 |
| stat | `src/stat.zig` | 2 | 1044, 1059 |
| tac | `src/tac.zig` | 3 | 69, 73, 77 |
| timeout | `src/timeout.zig` | 1 | (via error handler) |
| touch | `src/touch.zig` | 3 | 79, 83, 131 |
| tr | `src/tr.zig` | 1+ | (via error handler) |
| uniq | `src/uniq.zig` | 4 | 132, 136, 140, 171 |
| wc | `src/wc.zig` | 3 | 149, 153, 157 |

Utilities **missing the hint entirely** (28):
`basename`, `cat`, `date`, `dd`, `df`, `dirname`, `echo`, `false`, `find`, `free`,
`head`, `id`, `ln`, `mkdir`, `printf`, `pwd`, `readlink`, `realpath`, `rm`, `rmdir`,
`seq`, `tail`, `tee`, `test`, `true`, `whoami`, `yes`

**Agents that flagged:** Summary (Theme A3), Section-A (Theme E pattern a, I-BASENAME-01, I-DIRNAME-01), Remediation-Plan (implicit), Roadmap (A3)

---

### 1.3 Overwrite Mode Flag Precedence (4 agents)

**Similarity:** 90% (identical pattern: 3 independent booleans for mutually exclusive modes)

Four utilities store `-f`/`-i`/`-n` as independent booleans instead of a single enum
with last-flag-wins semantics:

| Utility | File | `force` Line | `interactive` Line | `no_clobber` Line | Bug |
|---------|------|-------------|-------------------|-------------------|-----|
| cp | `src/cp.zig` | 22, 117 | 23, 118 | 32, 122 | Last-wins untested |
| mv | `src/mv.zig` | 17, 46 | 15, 44 | 21, 50 | `-n -f` leaves no_clobber winning |
| rm | `src/rm.zig` | 12 | 13 | N/A | `-f` always wins over `-i` |
| ln | `src/ln.zig` | 16, 280 | 17, 281 | N/A | `-b` bypasses interactive |

**Runtime config structs that duplicate the pattern:**
- `src/cp.zig:117-129` — `CpRuntimeConfig` with `force`, `interactive`, `no_clobber` bools
- `src/mv.zig:44-54` — `MvRuntimeConfig` with `force`, `interactive`, `no_clobber` bools
- `src/rm.zig:12-14` — `RmArgs` with `force`, `interactive`, `interactive_once` bools
- `src/ln.zig:280-289` — `LnRuntimeConfig` with `force`, `interactive` bools

**Agents that flagged:** Section-A (Theme B: C-MV-03, I-RM-01), Roadmap (D2), Remediation-Plan (flag precedence in mv, rm), Stub-Report (mv -i dead on Linux)

---

### 1.4 Parse-Only Stub Tests (All 5 agents)

Not a code duplication per se, but an anti-pattern duplicated ~186 times across the test suite. Tests that call `parseArgs()` and assert struct field values without ever running the utility. The pattern is identical in structure:

```zig
test "flag is parsed" {
    const args = parseArgs(&.{"-f"});
    try testing.expect(args.flag == true);
}
```

| Utility | File | Count | Lines |
|---------|------|-------|-------|
| chmod | `src/chmod.zig` | 49 | throughout test section |
| sort | `src/sort.zig` | 32 | throughout test section |
| grep | `src/grep.zig` | 35 | throughout test section |
| cp | `src/cp.zig` | 10 | 1302–1345, 1623–1652 |
| chown | `src/chown.zig` | 8 | throughout test section |
| df | `src/df.zig` | 36 | throughout test section |
| stat | `src/stat.zig` | 9 | throughout test section |
| dd | `src/dd.zig` | 7+ | throughout test section |
| ln | `src/ln.zig` | 8 | throughout test section |
| rm | `src/rm.zig` | 5 | throughout test section |
| mv | `src/mv.zig` | 4 | 1219–1247 |
| touch | `src/touch.zig` | 2+ | 753, 761 |
| mktemp | `src/mktemp.zig` | 2+ | throughout test section |

**Agents that flagged:** All 5

---

### 1.5 Exit Code Misuse (exit 2 for value errors) (3 agents)

`ExitCode.misuse` (exit 2) used for value errors that should be exit 1. Found 171 total
`ExitCode.misuse` usages, many of which are correct (genuine flag-syntax errors). But
specific misuses:

| Utility | File | Line(s) | Bug |
|---------|------|---------|-----|
| sleep | `src/sleep.zig` | 116 | Invalid duration → exit 2 (should be 1) |
| seq | `src/seq.zig` | multiple | Invalid numeric → exit 2 |
| yes | `src/yes.zig` | 33 | Unknown flag → exit 2 (should be 1) |
| whoami | `src/whoami.zig` | multiple | Invalid args → exit 2 |
| date | `src/date.zig` | 559, 578 | Invalid date → exit 2 |
| free | `src/free.zig` | multiple | Invalid args → exit 2 |
| dd | `src/dd.zig` | multiple | Invalid operand → exit 2 |
| printf | `src/printf.zig` | multiple | Invalid format → exit 2 |

**Agents that flagged:** Summary (A4), Roadmap (A4), Remediation-Plan (yes, seq)

---

## 2. Patterns Found by 2 Agents

### 2.1 Numeric-with-Suffix Parsing (2 agents + codebase verification)

**Similarity:** 70–85% (same concept, different suffix sets and return types)

Five independent implementations of "parse a number with optional K/M/G/T suffix":

| # | File | Function | Line | Suffixes | Return | Notes |
|---|------|----------|------|----------|--------|-------|
| 1 | `src/common/format.zig` | `parseBlockSize` | 64 | K/M/G/T + KB/MB/GB/TB | `?u64` | Shared by du, df |
| 2 | `src/tail.zig` | `parseSuffixedNumber` | 367 | K/M/G + KB/MB/GB + KiB/MiB/GiB + b(512) | `!u64` | Most complete suffix set |
| 3 | `src/sort.zig` | `parseBufferSize` | 1267 | K/M/G | `?usize` | Simplest; case-insensitive via `toUpper` |
| 4 | `src/dd.zig` | `parseSingleSize` | 87 | c/w/b/k/K/M/G + multiplication via `x` | `!usize` | Unique: supports `1024x1024` syntax |
| 5 | `src/find.zig` | `parseSize` | 253 | c/k/M/G/T/P (byte units) | `!SizeExpr` | Returns struct with comparison operator |

**Additionally**, `du.zig:295` and `df.zig:352` wrap `format.parseBlockSize()` in local `parseBlockSize()` functions — unnecessary indirection.

**Divergences that cause bugs:**
- `sort.zig` rejects valid suffixes that `tail.zig` accepts (no `kB`, `MB`, etc.)
- `dd.zig` supports `c`/`w`/`b` suffixes that no other parser handles
- `find.zig` uses a different struct-based return for comparison semantics
- `tail.zig` supports IEC suffixes (`KiB`, `MiB`, `GiB`) that others don't

**Agents that flagged:** Roadmap (D3), Section-A (implicit in Theme G)

---

### 2.2 Backup Suffix Logic (2 agents)

**Similarity:** 85% (identical concept: resolve suffix from flag → env → default "~", then rename)

| # | File | Lines | Reads Env? | Default | Notes |
|---|------|-------|-----------|---------|-------|
| 1 | `src/cp.zig` | 69–70, 437–446 | **NO** | `"~"` | Ignores `SIMPLE_BACKUP_SUFFIX` |
| 2 | `src/ln.zig` | 484–492 | **YES** (line 485) | `"~"` | Reads `SIMPLE_BACKUP_SUFFIX` |
| 3 | `src/mv.zig` | 742–750 | **NO** | `"~"` | Ignores `SIMPLE_BACKUP_SUFFIX` |

All three follow the same pattern:
1. Check if backup enabled and destination exists
2. Create backup path: `std.fmt.allocPrint(allocator, "{s}{s}", .{path, suffix})`
3. Rename original to backup path
4. Report error if rename fails

**Bugs from duplication:**
- cp and mv don't read `SIMPLE_BACKUP_SUFFIX` env var (ln does)
- None implement `--backup=CONTROL` (numbered, existing, simple) — ln panics on it

**Agents that flagged:** Section-A (Theme I, I-LN-02), Roadmap (implicit in D2)

---

### 2.3 ISO 8601 Timestamp Parsing (2 agents)

**Similarity:** 75% (same format, different error handling and timezone bugs)

| # | File | Function | Line | TZ Support | Bug |
|---|------|----------|------|-----------|-----|
| 1 | `src/date.zig` | `parseIso8601` | 283 | **Ignores TZ** | Z/+HH:MM discarded |
| 2 | `src/touch.zig` | `parseIso8601` | 454 | **Ignores TZ** | Z/+HH:MM discarded |

Both functions:
- Parse `YYYY-MM-DD` and `YYYY-MM-DDTHH:MM:SS` format
- Use `mktime` for conversion (assumes local time)
- Silently discard timezone information
- Have the exact same timezone bug (C-TOUCH-03, date F63)

Additionally, `src/touch.zig` has `parseTimestamp` at line 352 which handles the `-t` format
(`CCYYMMDDhhmm.ss`) with duplicated range-validation logic.

**Agents that flagged:** Section-A (Theme G, C-TOUCH-03), Roadmap (D5)

---

### 2.4 File Header Pattern (2 agents)

**Similarity:** 100% (identical format string)

The `==> filename <==` header used by head and tail for multi-file output:

| # | File | Line | Code |
|---|------|------|------|
| 1 | `src/head.zig` | 184 | `try stdout_writer.writeAll("==> standard input <==\n");` |
| 2 | `src/head.zig` | 208 | `try stdout_writer.print("==> {s} <==\n", .{file_path});` |
| 3 | `src/tail.zig` | 249 | `try stdout_writer.writeAll("==> standard input <==\n");` |
| 4 | `src/tail.zig` | 267 | `try stdout_writer.print("==> {s} <==\n", .{file_path});` |

**Agents that flagged:** Roadmap (D4), Remediation-Plan (implicit)

---

### 2.5 Interactive Prompt Without TTY Check (2 agents)

**Similarity:** 100% (all callers use `promptYesNo` without isatty guard)

Phase 0 added the isatty guard INTO `promptYesNo` itself. But let's verify all call sites
are still correct:

| # | File | Line | Prompt |
|---|------|------|--------|
| 1 | `src/rm.zig` | 178 | `rm: remove {d} arguments?` |
| 2 | `src/rm.zig` | 294 | `rm: remove regular file '{s}'?` |
| 3 | `src/rm.zig` | 302 | `rm: remove write-protected regular file '{s}'?` |
| 4 | `src/rm.zig` | 450 | `rm: remove directory '{s}'?` |
| 5 | `src/mv.zig` | 729 | `mv: overwrite '{s}'?` |
| 6 | `src/cp.zig` | 423 | `cp: overwrite '{s}'?` |

**Status:** Phase 0 fix (D1) added isatty guard inside `promptYesNo` at `src/common/prompt.zig:21-23`. This is now a solved problem — all 6 callers automatically benefit.

**Agents that flagged:** Section-A (Theme J, I-RM-02), Roadmap (D1)

---

## 3. Proposed common/ Module Extractions

### 3.1 Module: `common/errors.zig` — Unified Error String Mapping

**Purpose:** Single source of truth for Zig error → POSIX string mapping. Replace all 9 independent implementations and 114 raw `@errorName` sites.

**Functions to include:**
```
pub fn posixErrorString(err: anyerror) []const u8
```
**Note:** This already exists at `src/common/lib.zig:130` with 15 mappings. It needs to be
expanded to 30+ mappings by merging the superset from `cp.zig:getStandardErrorName` (28 mappings),
`tee.zig:errorToMessage` (12 mappings), and `mkdir.zig:errorToMessage` (7 mappings).

**Merged error set (union of all implementations):**

| Error | POSIX String | Present In |
|-------|-------------|------------|
| `AccessDenied` | "Permission denied" | all 10 |
| `FileNotFound` | "No such file or directory" | all 10 |
| `IsDir` | "Is a directory" | lib, cp, head, tail |
| `NotDir` | "Not a directory" | lib, cp, chmod, mkdir, realpath, tail, tee |
| `FileTooBig` | "File too large" | lib, cp, tee |
| `NoSpaceLeft` | "No space left on device" | lib, cp, tee |
| `DeviceBusy` | "Device or resource busy" | lib, cp, tail |
| `FileBusy` | "Text file busy" | lib, cp |
| `NameTooLong` | "File name too long" | lib, cp, mkdir, realpath, ls, rmdir |
| `SymLinkLoop` | "Too many levels of symbolic links" | lib, cp, realpath, ls |
| `ProcessFdQuotaExceeded` | "Too many open files" | lib, cp |
| `SystemFdQuotaExceeded` | "Too many open files in system" | lib, cp |
| `SystemResources` | "Out of memory" | lib |
| `OutOfMemory` | "Cannot allocate memory" | cp, tee, realpath |
| `PathAlreadyExists` | "File exists" | cp, mkdir |
| `ReadOnlyFileSystem` | "Read-only file system" | cp, mkdir, tee, realpath |
| `DiskQuota` | "Disk quota exceeded" | cp, tee, tail |
| `BrokenPipe` | "Broken pipe" | tee |
| `ConnectionResetByPeer` | "Connection reset by peer" | tee |
| `InputOutput` | "Input/output error" | tee, ls |
| `PermissionDenied` | "Permission denied" | cp, tee, tail |
| `BadPathName` | "Invalid file name" | cp |
| `CrossDeviceLink` | "Invalid cross-device link" | cp |
| `EmptyPath` | "Empty path" | cp |
| `InvalidHandle` | "Invalid file handle" | cp |
| `InvalidPath` | "Invalid argument" | cp, realpath, lib |
| `NotLink` | "Not a symbolic link" | cp |
| `PathTooLong` | "File name too long" | cp |
| `WouldBlock` | "Resource temporarily unavailable" | cp |
| `Unexpected` | "Unexpected error" | cp |
| `DirNotEmpty` | "Directory not empty" | rmdir |
| `InvalidUtf8` | "Invalid or incomplete multibyte or wide character" | lib |

**Which utilities would use it:** ALL 47 utilities (30+ have `@errorName` sites)

**Estimated lines saved:**
- Delete 9 local functions: ~130 lines removed
- Replace 114 `@errorName` call sites: ~114 lines changed (same count, better output)
- Expand `posixErrorString` to 32 mappings: +17 lines to common
- **Net: ~113 lines removed**

**Dependencies:** None (already exists in lib.zig, just needs expansion + rollout)

---

### 3.2 Module: `common/overwrite.zig` — Shared OverwriteMode Enum

**Purpose:** Replace independent boolean flags with a single enum that tracks parse order
for last-flag-wins semantics.

**Functions to include:**
```
pub const OverwriteMode = enum { default, force, interactive, no_clobber };
```

**Which utilities would use it:** cp, mv, rm, ln (4 utilities)

**Estimated lines saved:**
- Remove 3 booleans × 4 utilities × 2 structs (parse + runtime): ~24 lines
- Add OverwriteMode enum + resolver: +15 lines
- Fix precedence bugs in rm, mv (bonus correctness)
- **Net: ~10 lines removed + 4 bug fixes**

**Dependencies:** None

---

### 3.3 Module: `common/backup.zig` — Shared Backup Logic

**Purpose:** Single implementation for backup file creation with proper env var support.

**Functions to include:**
```
pub fn resolveBackupSuffix(flag_suffix: ?[]const u8) []const u8
pub fn createBackup(allocator, path: []const u8, suffix: []const u8) ![]u8
```

**Which utilities would use it:** cp, mv, ln (3 utilities)

**Estimated lines saved:**
- Remove 3 inline backup implementations: ~45 lines removed
- Add common module: +25 lines
- **Net: ~20 lines removed + 2 bug fixes** (cp and mv now read SIMPLE_BACKUP_SUFFIX)

**Dependencies:** None

---

### 3.4 Module: `common/numeric.zig` — Unified Numeric-with-Suffix Parser

**Purpose:** Single parser for numbers with K/M/G/T/P/E suffixes, supporting both
binary (1024) and SI (1000) bases, IEC suffixes, and dd-style multiplication.

**Functions to include:**
```
pub const NumericOptions = struct {
    allow_si: bool = true,           // KB, MB, GB
    allow_iec: bool = false,         // KiB, MiB, GiB
    allow_dd_suffixes: bool = false, // c, w, b
    allow_multiplication: bool = false, // 1024x1024
};

pub fn parseNumericWithSuffix(str: []const u8, opts: NumericOptions) !u64
```

**Which utilities would use it:**
- `tail.zig` (lines 335–401): `parseNumericArg` + `parseSuffixedNumber` + MULTIPLIERS table
- `sort.zig` (line 1267): `parseBufferSize`
- `dd.zig` (lines 69–115): `parseByteSize` + `parseSingleSize`
- `du.zig` (line 295): wrapper around `format.parseBlockSize`
- `df.zig` (line 352): wrapper around `format.parseBlockSize`
- `head.zig`: uses argparse for count, but `-c` byte count could benefit

**Estimated lines saved:**
- Remove 3 independent parsers (tail: 67 lines, sort: 22 lines, dd: 47 lines): ~136 lines
- Simplify du/df wrappers: ~10 lines
- Add common module: +60 lines
- **Net: ~86 lines removed + suffix consistency fixes**

**Dependencies:** Replaces/extends `common/format.zig:parseBlockSize`

---

### 3.5 Module: `common/time.zig` (expand existing) — Shared Timestamp Parsing

**Purpose:** Move both `parseIso8601` implementations into common/time.zig with
proper timezone support.

**Functions to include:**
```
pub fn parseIso8601(date_str: []const u8) !Timespec  // with TZ support
pub fn parseTimestamp(stamp: []const u8) !Timespec    // -t format
pub fn validateDateComponents(year, month, day, hour, min, sec) !void
```

**Which utilities would use it:** date, touch (2 currently), potentially stat, find

**Estimated lines saved:**
- Remove date.zig `parseIso8601`: ~70 lines
- Remove touch.zig `parseIso8601` + `parseTimestamp`: ~120 lines
- Add to common/time.zig: +110 lines
- **Net: ~80 lines removed + timezone bug fix**

**Dependencies:** `common/time.zig` already exists (handles duration parsing for sleep/timeout)

---

### 3.6 Rollout: `common.printTryHelp` Adoption

**Purpose:** Not a new module — rollout of existing Phase 0 function to 19 utilities
with inline duplication, and add it to 28 missing utilities.

**Current state:** `src/common/lib.zig:164` — `printTryHelp(writer, prog_name)` exists, zero callers.

**Rollout plan:**
- 19 utilities with inline `"Try '... --help'"`: Replace ~54 inline strings with
  `common.printTryHelp(stderr_writer, prog_name)` call after the error message
- 28 utilities missing the hint: Add `common.printTryHelp()` call to error paths

**Estimated lines saved:**
- Each inline site embeds the hint in the format string. Extracting it into a separate call
  is roughly line-neutral but improves consistency.
- **Net: ~0 lines changed, 47 utilities made GNU-compatible**

**Dependencies:** None (function already exists)

---

### 3.7 Module: `common/file_header.zig` — Multi-file Output Headers

**Purpose:** Shared `==> filename <==` header for multi-file output utilities.

**Functions to include:**
```
pub fn writeFileHeader(writer: anytype, filename: []const u8) !void
pub fn writeStdinHeader(writer: anytype) !void
```

**Which utilities would use it:** head, tail (cat and nl could also benefit for future
multi-file support)

**Estimated lines saved:**
- Remove 4 inline header writes: ~4 lines
- Add common module: +10 lines
- **Net: ~6 lines added** (tiny, but prevents format drift)

**Dependencies:** None

---

## 4. Execution Order

### Batch 1: Independent Foundations (can be parallelized)

All of these have zero dependencies on each other:

| Task | Module | Est. Lines | Depends On |
|------|--------|-----------|------------|
| 3.1 | Expand `posixErrorString` in lib.zig to 32 mappings | +17 | Nothing |
| 3.2 | Create `common/overwrite.zig` | +15 | Nothing |
| 3.3 | Create `common/backup.zig` | +25 | Nothing |
| 3.7 | Create `common/file_header.zig` | +10 | Nothing |

**Parallelism:** All 4 tasks can run simultaneously.
**Deliverable:** 4 new/expanded common modules with tests.

---

### Batch 2: Rollout Wave 1 — Error Strings (depends on Batch 1)

| Task | Scope | Est. Changes |
|------|-------|-------------|
| Delete 9 local error-mapping functions | head, tail, tee, mkdir, chmod, rmdir, cp, realpath, ls | 9 files, ~130 lines removed |
| Replace 114 `@errorName` sites with `common.posixErrorString` | 30+ files | 114 site changes |

**Parallelism:** Each file can be done independently. Up to 30 parallel tasks.
**Deliverable:** All user-facing error messages are POSIX-compliant.

---

### Batch 3: Rollout Wave 2 — Overwrite + Backup + Headers (depends on Batch 1)

| Task | Scope | Est. Changes |
|------|-------|-------------|
| Adopt `OverwriteMode` in cp, mv, rm, ln | 4 files | ~24 lines changed per file |
| Adopt `common/backup.zig` in cp, mv, ln | 3 files | ~15 lines changed per file |
| Adopt `common/file_header.zig` in head, tail | 2 files | ~4 lines changed per file |
| Rollout `printTryHelp` to 47 utilities | 47 files | ~1-3 lines per file |

**Parallelism:** Overwrite, backup, headers, and printTryHelp rollouts are independent.
**Deliverable:** 4 utilities with correct flag precedence, 3 with correct backup, all with GNU-style hints.

---

### Batch 4: Numeric Parser Consolidation (independent of Batches 2–3)

| Task | Scope | Est. Changes |
|------|-------|-------------|
| Create `common/numeric.zig` | New file | +60 lines |
| Migrate tail.zig | Replace parseSuffixedNumber + MULTIPLIERS | ~67 lines removed |
| Migrate sort.zig | Replace parseBufferSize | ~22 lines removed |
| Migrate dd.zig | Replace parseByteSize + parseSingleSize | ~47 lines removed |
| Simplify du.zig/df.zig wrappers | Remove thin wrappers | ~10 lines removed |

**Parallelism:** Can run alongside Batches 2–3. Internal migrations are sequential.
**Deliverable:** Unified numeric parsing with consistent suffix support.

---

### Batch 5: Timestamp Consolidation (depends on common/time.zig stability)

| Task | Scope | Est. Changes |
|------|-------|-------------|
| Expand `common/time.zig` with parseIso8601 + TZ | Expand existing file | +110 lines |
| Migrate date.zig | Remove local parseIso8601 | ~70 lines removed |
| Migrate touch.zig | Remove local parseIso8601 + parseTimestamp | ~120 lines removed |

**Parallelism:** Sequential (expand common first, then migrate).
**Deliverable:** Timezone-aware ISO 8601 parsing available project-wide.

---

### Dependency Graph

```
Batch 1 (parallel)
├── Expand posixErrorString ──────→ Batch 2 (rollout @errorName)
├── Create overwrite.zig ─────────→ Batch 3a (adopt in cp/mv/rm/ln)
├── Create backup.zig ────────────→ Batch 3b (adopt in cp/mv/ln)
└── Create file_header.zig ───────→ Batch 3c (adopt in head/tail)

Batch 4 (independent)
└── Create numeric.zig ───────────→ migrate tail/sort/dd/du/df

Batch 5 (independent)
└── Expand time.zig ──────────────→ migrate date/touch
```

---

## 5. What the Agents Missed

### 5.1 Phase 0 Functions Have Zero Adopters

The most significant gap: **all 5 agents recommended creating common functions, and Phase 0
created them, but nobody noticed they're still unused**. Specifically:

- `common.posixErrorString()` at `lib.zig:130` — 0 callers outside tests
- `common.printTryHelp()` at `lib.zig:164` — 0 callers outside tests
- `promptYesNo` isatty guard at `prompt.zig:21-23` — working (built into function)

**This means 2 of 3 Phase 0 deliverables have zero production impact yet.**

### 5.2 `cp.zig` Uses `@errorName` Despite Having Its Own `getStandardErrorName`

At `src/cp.zig:550` and `src/cp.zig:718`, the code uses `@errorName(err)` even though
`getStandardErrorName` is defined at line 809 in the same file. This means even within
a single file, the local error-mapping function isn't consistently used. No agent flagged
this internal inconsistency.

### 5.3 `du.zig` and `df.zig` Thin Wrapper Indirection

Both files define a local `parseBlockSize` that simply delegates to `common.format.parseBlockSize`:
- `src/du.zig:295-296`: `fn parseBlockSize(str) ?u64 { return format.parseBlockSize(str); }`
- `src/df.zig:352-353`: `fn parseBlockSize(s) ?u64 { return common.format.parseBlockSize(s); }`

This unnecessary indirection was not flagged by any agent. Both also have their own
full test suites for `parseBlockSize` that duplicate the tests in `format.zig`.

### 5.4 Utilities Not Audited for Duplication Patterns

The audit focused on correctness, not systematically on duplication. These areas were
not cross-referenced:

- **`writerStreaming` boilerplate**: Every utility has identical ~8-line writer setup
  (stdout buffer, stderr buffer, writerStreaming calls). Lines like:
  ```zig
  var stdout_buffer: [8192]u8 = undefined;
  var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
  var stderr_buffer: [8192]u8 = undefined;
  var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
  ```
  This appears in all 47 utilities. A `common.io.stdWriters()` function could eliminate ~4 lines per utility (~188 lines total).

- **`ExitCode` return boilerplate**: Many utilities end with identical `return @intFromEnum(common.ExitCode.success)` / `.general_error` / `.misuse` patterns.

- **Recursive directory traversal**: `rm.zig`, `find.zig`, `du.zig`, `chown.zig`, `chmod.zig` all implement their own recursive directory walking. While the traversal logic differs (pre-order vs post-order, different filtering), the core `openDir` → `iterate` → `recurse` pattern has significant overlap.

### 5.5 `@divTrunc` Pattern in find.zig

The `@divTrunc` time calculation pattern appears 8 times in `src/find.zig` (lines 1784, 1806, 1817, 1837, 1857, 1868, 1972, 1986) with the identical structure:
```zig
const age_days: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 86400) else 0;
```
This is both a bug (should use ceiling division per POSIX) and internal duplication.
The Roadmap (D3 suggestion about `ceilDivU64`) flagged the bug but none of the agents
counted the 8 identical sites as an extraction target within find.zig itself.

### 5.6 Symbolic Mode Parsing

Both `chmod.zig` and `mkdir.zig` need to parse symbolic mode strings (`u+rwx`, `go-w`).
`chmod.zig` has a full parser (lines ~600–795). `mkdir.zig` currently rejects symbolic
modes entirely (I-MKDIR-01), but when fixed, will need the same parser. No agent
flagged this as a future duplication/extraction opportunity.

---

## Appendix: Cross-Reference Matrix

| Pattern | Summary | Section-A | Stub-Report | Remediation | Roadmap |
|---------|:-------:|:---------:|:-----------:|:-----------:|:-------:|
| Error-to-POSIX mapping (9 impls) | ✓ A1/A2 | ✓ Theme E | ✓ (implicit) | ✓ I-MV-05 | ✓ A1/A2 |
| "Try --help" hint (54 inline) | ✓ A3 | ✓ Theme E(a) | | ✓ (implicit) | ✓ A3 |
| OverwriteMode booleans (4 utils) | | ✓ Theme B | ✓ mv-i | ✓ mv/rm flags | ✓ D2 |
| Parse-only stub tests (~186) | ✓ G1 | ✓ Theme D | ✓ (table) | ✓ (table) | ✓ G1-G4 |
| Exit code 2→1 misuse (8 utils) | ✓ A4 | | | ✓ yes/seq | ✓ A4 |
| Numeric suffix parsing (5 impls) | | | | ✓ (implicit) | ✓ D3 |
| Backup suffix logic (3 impls) | | ✓ Theme I | | ✓ I-LN-02 | ✓ (implicit) |
| ISO 8601 parsing (2 impls) | | ✓ Theme G | | ✓ date/touch | ✓ D5 |
| File header pattern (2 utils) | | | | | ✓ D4 |
| promptYesNo isatty (6 callers) | | ✓ Theme J | | ✓ I-RM-02 | ✓ D1 |

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Duplication patterns identified | 9 major + 3 minor |
| Independent error-mapping functions | 9 (+ 114 raw @errorName sites) |
| Independent numeric suffix parsers | 5 |
| Independent backup implementations | 3 |
| Utilities needing OverwriteMode | 4 |
| Utilities missing "Try --help" | 28 |
| Utilities with inline "Try --help" | 19 (54 sites) |
| Phase 0 functions with 0 adopters | 2 of 3 |
| Proposed new common modules | 4 (overwrite, backup, numeric, file_header) |
| Proposed common module expansions | 2 (lib.zig error mappings, time.zig timestamps) |
| Estimated total lines removable | ~310 lines |
| Estimated total lines added to common | ~120 lines |
| **Net reduction** | **~190 lines + 47 utilities made consistent** |
