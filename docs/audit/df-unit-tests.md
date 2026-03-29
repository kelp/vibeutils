# df Unit Test Audit

**Date:** 2026-03-28
**File:** `src/df.zig`
**Tests found:** 135
**Test run result:** all 135 pass (all df tests pass; suite total 1783/1802)

---

## Summary

df has the largest unit test file in the project at 135 tests covering
parsing, filtering, formatting, classification, and end-to-end `runDf`
paths. The overall quality is high. Most behavioral paths are covered.
However, a cluster of parse-only stubs exists around flags that are
either acknowledged stubs (`--output`, `-n`) or genuinely broken (`-I`,
`-P`, `-T`) per the code audit. Three `runDf` tests verify only exit
code 0 with no output assertions, masking stub and wrong-behavior bugs.

---

## Test Inventory

### parseArgs tests (36 tests)
All check struct field values after parsing. All are by definition
parse-only with respect to program output behavior, but that is
appropriate for a unit test of a parsing function. They are not
counted as "stubs" below because testing the parser directly is
correct practice; the problem is where the parser result is never
exercised further.

Flags covered by parseArgs tests:
`-a`, `-h`, `-H`, `-i`, `-T`, `-l`, `-P`, `-n`, `-b`, `-c`, `-g`,
`-I`, `-m`, `-Y`, `,-`, `--all`, `--human-readable`, `--inodes`,
`--print-type`, `--total`, `--output`, `--block-size`, `--si`,
`--portability`, `-t`, `-x`, `--exclude-type`, `--`

### shouldIncludeFs tests (5 tests)
All behavioral: actually call `shouldIncludeFs` and check return
value. Cover: default filter, pseudo fs excluded, pseudo fs with
`-a`, type include filter, type exclude filter, local-only.

### runDf behavioral tests (17 tests)
Drive `runDf` with full output capture. Quality varies (see issues
below).

### Formatting / utility tests (77 tests)
Cover: `formatHumanReadable`, `formatPercent`, `formatSize`,
`formatWithCommas`, `formatUsageBar`, `calcUsagePercent`,
`truncatePath`, `smartFormatSource`, `smartFormatMount`,
`extractCString`, `extractDevicePrefix`, `groupDarwinVolumes`,
`computeColumnWidths`, `padLeft`, `padRight`, `printHeader`,
`printFsRow`, `printTotal`, `applyUsageColor`, `usageGradientRgb`,
`classifyFs`, `isTimeMachineSnapshot`, `isTimeMachineBackup`,
`isCloudFs`, `getFsIcon`, `parseBlockSize`.

---

## Findings

### [CRITICAL] `--output` is a silently ignored stub with parse-only tests
**Location:** `src/df.zig:2338-2352`
**Problem:** The two `parseArgs - output flag *` tests verify that
`output_fields` is set in `DfOptions`, but `output_fields` is never
read by any output function (confirmed by grep: 5 occurrences total,
all in parsing or test code). `--output` does nothing to program
output. The tests pass, giving false confidence that the flag works.
**Fix:** Mark the tests with a `// TODO: stub — output_fields is
parsed but not consumed` comment, or delete the parse-only tests and
replace them with a `runDf` test that verifies `--output=source`
produces only the source column.

---

### [CRITICAL] `runDf - n flag accepted` is an exit-code-only stub test, masking a MUST-tier bug
**Location:** `src/df.zig:3200-3209`
**Problem:** The test only checks `result == 0`. The code audit
(`df-code.md`) documents that `-n` is a stub: `no_sync` is set but
`getfsstat` always uses `MNT_NOWAIT` on Darwin and on Linux `-n` is
silently accepted instead of rejected. The test cannot fail on the
stub because it makes no output assertions.
**Fix:** For Darwin: verify that `-n` and no `-n` produce identical
output (both call cached stat path). For Linux: verify that `-n`
returns exit code 2 with an error on stderr (GNU df rejects it).

---

### [CRITICAL] No behavioral test for `-P` portability column headers
**Location:** Test gap — no `runDf` test for `-P` output format
**Problem:** The code audit documents that `-P` emits wrong POSIX
column headers (`1K-blocks` / `Avail` / `Use%` instead of
`1024-blocks` / `Available` / `Capacity`). The only test for `-P` is
`parseArgs - P flag disables human readable and sets plain`, which is
parse-only. There is no `runDf` test that checks the actual header
line content, so the compliance bug is invisible at test time.
**Fix:** Add:
```zig
test "runDf - P flag uses POSIX column headers" {
    // run df -P / and check stdout contains "1024-blocks" and "Capacity"
    try testing.expect(std.mem.indexOf(u8, stdout, "1024-blocks") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "Capacity") != null);
}
```

---

### [IMPORTANT] `runDf - comma flag accepted` is exit-code-only
**Location:** `src/df.zig:3414-3423`
**Problem:** The test checks `result == 0` only. It does not verify
that numeric columns actually contain commas (e.g., `1,024`). A
regression that silently drops `thousands_grouping` would pass.
**Fix:** Assert a comma appears in the output:
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, ",") != null);
```

---

### [IMPORTANT] `runDf - Y flag accepted` is exit-code-only
**Location:** `src/df.zig:3403-3412`
**Problem:** The test only checks `result == 0`. `-Y` is documented
as a no-op ("don't resolve NFS paths"), so exit-code-only is
arguably acceptable. However, the test is indistinguishable from a
test for a broken flag that silently does nothing, and there is no
comment explaining the intentional no-op.
**Fix:** Add a comment: `// -Y is intentionally a no-op (don't
resolve NFS paths); exit 0 is sufficient.`

---

### [IMPORTANT] `-T` (`--print-type`) `runDf` test verifies column header only, not type data
**Location:** `src/df.zig:2590-2600`
**Problem:** `runDf - print type flag` checks that `"Type"` appears
in stdout, which only proves the header branch fires. It does not
verify that an actual filesystem type string (e.g., `apfs`, `ext4`)
appears in the type column. The code audit found `-T` uses a
fixed-width format that wraps long type names, and the column is not
present in the dynamic-width path when `print_type` is true. A
regression dropping the type data row would not be caught.
**Fix:** Also assert a known non-empty type string is present:
```zig
// At least one known type must appear
const has_type = std.mem.indexOf(u8, stdout_buf.items, "apfs") != null or
    std.mem.indexOf(u8, stdout_buf.items, "ext4") != null or
    std.mem.indexOf(u8, stdout_buf.items, "tmpfs") != null;
try testing.expect(has_type);
```

---

### [IMPORTANT] `-i` inodes `runDf` test verifies column header only
**Location:** `src/df.zig:2602-2612`
**Problem:** `runDf - inodes flag` only checks that `"Inodes"` is in
the output. It does not check that inode count values are numeric and
present, nor that the `"IUsed"`, `"IFree"`, `"IUse%"` columns appear.
A regression producing only the header row would pass.
**Fix:** Assert at least one numeric value and additional headers:
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "IUsed") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "IFree") != null);
```

---

### [IMPORTANT] No `runDf` test for `-a` (show all filesystems)
**Location:** Test gap
**Problem:** `-a` is a SHOULD-tier flag. `shouldIncludeFs` has three
unit tests for the `all` path, but there is no `runDf`-level test
that verifies the count of output lines increases when `-a` is passed
versus without `-a`. The interaction between `-a` and the Linux
`/proc/mounts` enumeration path has no integration point in unit tests.
**Fix:** Add:
```zig
test "runDf - a flag shows more filesystems than default" {
    // run df / and df -a /, check -a output is >= default output
    try testing.expect(all_buf.items.len >= default_buf.items.len);
}
```

---

### [IMPORTANT] No behavioral test for `-l` (local-only) via `runDf`
**Location:** Test gap
**Problem:** `shouldIncludeFs - local only` tests the filter logic in
isolation using a hardcoded NFS entry. There is no `runDf` test that
passes `-l` and verifies NFS entries are absent or local entries are
present. On Linux the `isNetworkFs` path is exercised only through the
unit test mock; the real `getMountedFilesystemsLinux` + filter
interaction is not covered.
**Fix:** Add a `runDf -l /` test that checks exit code 0 and the
header appears (at minimum).

---

### [SUGGESTION] `parseArgs - n flag accepted as no-op` comment is misleading
**Location:** `src/df.zig:3183`
**Problem:** The test name calls it a "no-op," but `-n` is a MUST-tier
flag that should alter `getfsstat` mode (see code audit). Labeling it
a no-op in the test name treats a known bug as intentional design.
**Fix:** Rename to `parseArgs - n flag sets no_sync` and add a
`// TODO: no_sync must affect getfsstat MNT_WAIT/MNT_NOWAIT` comment.

---

### [SUGGESTION] `parseArgs - Y flag accepted as no-op` — same issue
**Location:** `src/df.zig:3273`
**Problem:** `-Y` (don't resolve NFS paths) is genuinely a no-op, but
the test makes no distinction between "intentional no-op" and "stub
bug." A short comment would clarify.
**Fix:** Add: `// -Y: macOS no-NFS-resolve flag; deliberately a no-op.`

---

### [SUGGESTION] `printHeader - color mode no Usage column` is a duplicate of the plain-mode test
**Location:** `src/df.zig:2935-2942`
**Problem:** Both tests set `opts.display.icons = .off` and assert
`"Usage"` is absent. The "color mode" test does not set
`opts.display.color = .on`, so it is functionally identical to the
plain-mode test. It provides no additional coverage.
**Fix:** Either add `opts.display.color = .on` to differentiate, or
remove the duplicate.

---

## Flag Coverage Matrix

| Flag | Tier | parseArgs test | runDf behavioral test | Notes |
|------|------|---------------|-----------------------|-------|
| -a   | SHOULD | yes | no | gap |
| -b   | SHOULD | yes | yes (header check) | adequate |
| -c   | SHOULD | yes | yes (total line) | adequate |
| -g   | SHOULD | yes | yes (header check) | adequate |
| -h   | MUST | yes | yes (header check) | adequate |
| -H   | SHOULD | yes | no | parse-only gap |
| -i   | MUST | yes (via short flags) | yes (header only) | weak |
| -I   | SHOULD | yes | no | stub bug, no behavioral test |
| -k   | MUST | yes | no | parse-only gap |
| -l   | MUST | yes (via short flags) | no | gap |
| -m   | SHOULD | yes | yes (header check) | adequate |
| -n   | MUST | yes | exit-code-only | masks stub bug |
| -P   | MUST | yes | no | missing POSIX header test |
| -t   | MUST | yes | no | parse-only gap |
| -T   | SHOULD | yes (via short flags) | yes (header only) | weak |
| -x   | SHOULD | yes | no | parse-only gap |
| -Y   | SHOULD | yes | exit-code-only | intentional no-op |
| -,   | SHOULD | yes | exit-code-only | missing comma assertion |
| --block-size | SHOULD | yes | no | parse-only gap |
| --output | SHOULD | yes | no | stub, parse-only |
| --total | SHOULD | yes | yes (total line) | adequate |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] --output tests give false confidence; flag is a stub
   — src/df.zig:2338-2352
2. [CRITICAL] runDf - n flag accepted is exit-code-only, masks MUST bug
   — src/df.zig:3200-3209
3. [CRITICAL] No runDf test for -P portability column headers
   — test gap (related production bug: src/df.zig:1384)
4. [IMPORTANT] runDf - comma flag accepted: no comma assertion
   — src/df.zig:3414-3423
5. [IMPORTANT] runDf - T flag: header-only check, no type data assertion
   — src/df.zig:2590-2600
6. [IMPORTANT] runDf - i flag: header-only check, no IUsed/IFree columns
   — src/df.zig:2602-2612
7. [IMPORTANT] No runDf test for -a (all filesystems)
   — test gap
8. [IMPORTANT] No runDf test for -l (local only)
   — test gap
9. [SUGGESTION] parseArgs - n flag name calls it "no-op" (it's a bug)
   — src/df.zig:3183
10. [SUGGESTION] parseArgs - Y flag name needs no-op comment
    — src/df.zig:3273
11. [SUGGESTION] printHeader - color mode test is duplicate of plain-mode
    — src/df.zig:2935
```

REVIEW COMPLETE - NEEDS_FIXES
