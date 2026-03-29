# sort Unit Test Audit

**Date:** 2026-03-28
**File audited:** `src/sort.zig`
**Total tests:** 61
**Test run:** All pass (confirmed via `zig build test --summary all`)

---

## Stdin Hang Risk Assessment

`sort` is a filter utility: when called with no file arguments it reads
from stdin (line 547-549 of `runSort`). The implementation does not use
a `runUtilWithInput()` pattern. Instead, every behavioral test that
calls `runSort` passes an explicit temp file path as an argument, so the
stdin code path is never exercised by unit tests.

This is safe for the tests that exist, but it means the stdin code path
has **zero unit-test coverage**. It is not a hang risk for the current
suite, but it is a coverage gap.

---

## Test Inventory

### Parse-Only Tests (verify struct fields, not behavior)

These tests call `parseArgs` and inspect the resulting `SortOptions`
struct. They confirm flags are stored, but prove nothing about what the
program does with them at runtime.

| # | Test name | Flag(s) |
|---|-----------|---------|
| 1 | `parseArgs basic flags` | -n, -r, -u |
| 2 | `parseArgs combined flags` | -nru |
| 3 | `parseArgs -k with value` | -k |
| 4 | `parseArgs -t with value` | -t |
| 5 | `parseArgs -o with value` | -o |
| 6 | `parseArgs --check variants` | -c, -C, --check=quiet |
| 7 | `parseArgs files and --` | -- separator |
| 8 | `parseArgs -m sets merge_only` | -m |
| 9 | `parseArgs --merge sets merge_only` | --merge |
| 10 | `parseArgs -M sets month_sort` | -M |
| 11 | `parseArgs --month-sort sets month_sort` | --month-sort |
| 12 | `parseArgs -R sets random_sort` | -R |
| 13 | `parseArgs --random-sort sets random_sort` | --random-sort |
| 14 | `parseArgs -S accepts buffer size` | -S 10M |
| 15 | `parseArgs --buffer-size accepts value` | --buffer-size=1G |
| 16 | `parseArgs -S accepts plain number` | -S 4096 |
| 17 | `parseArgs -S accepts K suffix` | -S 64K |
| 18 | `parseArgs -T accepts temp directory` | -T |
| 19 | `parseArgs --temporary-directory accepts value` | --temporary-directory= |
| 20 | `parseArgs --batch-size=N stores batch size` | --batch-size= |
| 21 | `parseArgs --compress-program=PROG stores program` | --compress-program= |
| 22 | `parseArgs --debug sets debug flag` | --debug |
| 23 | `parseArgs --files0-from=FILE stores path` | --files0-from= |
| 24 | `parseArgs --parallel=N stores value` | --parallel= |
| 25 | `parseArgs --random-source=FILE stores path` | --random-source= |
| 26 | `parseArgs --heapsort accepted as no-op` | --heapsort |
| 27 | `parseArgs --mergesort accepted as no-op` | --mergesort |
| 28 | `parseArgs --mmap accepted as no-op` | --mmap |
| 29 | `parseArgs --qsort accepted as no-op` | --qsort |
| 30 | `parseArgs --radixsort accepted as no-op` | --radixsort |
| 31 | `parseArgs --batch-size invalid returns null` | --batch-size= |
| 32 | `parseArgs --parallel invalid returns null` | --parallel= |

**32 of 61 tests are parse-only.**

### Internal Helper Tests (unit tests of non-public functions)

These test pure functions with no I/O. They are legitimately
unit-level and do verify behavioral logic.

| # | Test name | Notes |
|---|-----------|-------|
| 1 | `parseKeyDef simple field` | behavioral |
| 2 | `parseKeyDef field with char offset` | behavioral |
| 3 | `parseKeyDef field range` | behavioral |
| 4 | `parseKeyDef field range with chars` | behavioral |
| 5 | `parseKeyDef with options` | behavioral |
| 6 | `parseKeyDef invalid` | behavioral |
| 7 | `parseKeyDef with M option` | behavioral |
| 8 | `parseLeadingNumber basic` | behavioral |
| 9 | `parseHumanNumber with suffixes` | behavioral |
| 10 | `compareCaseInsensitive` | behavioral |
| 11 | `compareDictionary` | behavioral |
| 12 | `stripLeadingBlanks` | behavioral |
| 13 | `splitFields with separator` | behavioral |
| 14 | `splitFields with blanks (default)` | behavioral |
| 15 | `compareGeneralNumeric with scientific notation` | behavioral |
| 16 | `parseMonthName` | behavioral |
| 17 | `parseMonthName with leading whitespace` | behavioral |
| 18 | `compareMonth ordering` | behavioral |
| 19 | `parseBufferSize` | behavioral |

### End-to-End Behavioral Tests (call `runSort` with a file)

These create a temp file, call `runSort`, and verify output. They are
the only tests that exercise the full sort pipeline.

| # | Test name | Flags covered | Quality |
|---|-----------|--------------|---------|
| 1 | `sort --help shows help message` | --help | good |
| 2 | `sort --version shows version` | --version | good |
| 3 | `sort -V shows version` | -V | good |
| 4 | `sort unknown flag returns misuse` | error path | good |
| 5 | `sort invalid short flag returns misuse` | error path | good |
| 6 | `sort -R produces all input lines` | -R | partial — checks presence, not order |
| 7 | `sort -m merges pre-sorted files` | -m | good |
| 8 | `sort -M sorts by month name` | -M | good |
| 9 | `runSort basic alphabetical sort` | (default) | good |
| 10 | `readLines does not leak the content buffer` | (readLines) | good |

---

## Findings

---

### [CRITICAL] 32 parse-only tests for MUST-tier flags

**Location:** `src/sort.zig:1435–1843`

**Problem:** Every MUST-tier flag that changes sort behavior has only a
`parseArgs` test proving the field was stored. None of these tests verify
the flag changes output:

- `-n` / `--numeric-sort`: no behavioral test
- `-r` / `--reverse`: no behavioral test
- `-u` / `--unique`: no behavioral test
- `-f` / `--ignore-case`: no behavioral test
- `-b` / `--ignore-leading-blanks`: no behavioral test
- `-d` / `--dictionary-order`: no behavioral test
- `-i` / `--ignore-nonprinting`: no behavioral test
- `-g` / `--general-numeric-sort`: no behavioral test (only a
  `compareGeneralNumeric` helper test)
- `-h` / `--human-numeric-sort`: no behavioral test (only a
  `parseHumanNumber` helper test)
- `-k` / `--key=`: no behavioral test for actual key-based sorting
- `-t` / `--field-separator`: no behavioral test
- `-c` / `--check`: no behavioral test (result code not checked)
- `-C` / `--check=quiet`: no behavioral test
- `-u` combined with `-c`: no behavioral test
- `-o` / `--output=`: no behavioral test (file is never written and read
  back)
- `-z` / `--zero-terminated`: no behavioral test
- `-s` / `--stable`: no behavioral test

The parse-only tests for these flags are false confidence. A bug that
makes any flag silently have no effect would pass all 32 of them.

**Fix:** For each MUST-tier sort mode, add an end-to-end test that feeds
known input, runs `runSort` with the flag, and asserts the expected
output string. Example for `-n`:

```zig
test "sort -n sorts numerically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer = std.ArrayListUnmanaged(u8){};
    const tmp = "/tmp/sort_test_numeric.txt";
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        var wb: [8192]u8 = undefined;
        var w = file.writer(&wb);
        try w.interface.writeAll("10\n9\n2\n100\n");
        try w.interface.flush();
    }
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const args = [_][]const u8{ "-n", tmp };
    const result = try runSort(
        allocator, &args, buffer.writer(allocator), common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("2\n9\n10\n100\n", buffer.items);
}
```

---

### [CRITICAL] `-c`/`-C` check mode has no behavioral test

**Location:** `src/sort.zig:1480–1498`

**Problem:** The `parseArgs --check variants` test only confirms the
`CheckMode` enum value is stored. `checkSorted` (lines 1178–1203) is
never called from any test. Critical behaviors are untested:

1. `-c` on a sorted file must exit 0.
2. `-c` on an unsorted file must exit 1 and print a disorder message to
   stderr.
3. `-C` on an unsorted file must exit 1 silently.
4. `-c -u` must reject duplicate lines.

**Fix:** Add four end-to-end tests using temp files with known
sorted/unsorted content, calling `runSort` and asserting exit code and
stderr content.

---

### [CRITICAL] `-o` output-to-file has no behavioral test

**Location:** `src/sort.zig:1472–1478`

**Problem:** The `parseArgs -o with value` test only checks
`opts.output_file`. The code path that creates the output file (lines
575–588) is never exercised. A bug in file creation, truncation, or
flushing would pass all tests.

**Fix:** Add a test that calls `runSort` with `-o /tmp/sort_out.txt`,
then reads and verifies the file contents.

---

### [IMPORTANT] `-r` reverse sort has no behavioral test

**Location:** `src/sort.zig:1435–1443`

**Problem:** `parseArgs basic flags` confirms `opts.global_flags.reverse
== true`. Nothing verifies that sorted output is actually reversed. The
`compareLines` reverse-path logic (lines 655–657, 665–667) is untested
end-to-end.

**Fix:** Feed `a\nb\nc\n`, run with `-r`, assert `c\nb\na\n`.

---

### [IMPORTANT] `-u` unique deduplication has no behavioral test

**Location:** `src/sort.zig:1435–1443`

**Problem:** `parseArgs basic flags` confirms `opts.unique == true`. The
`writeLines` deduplication path (lines 1210–1219) is never exercised.
`linesEqual` is also untested.

**Fix:** Feed `a\na\nb\nb\nc\n`, run with `-u`, assert `a\nb\nc\n`.

---

### [IMPORTANT] `-k` key-based sort has no behavioral test

**Location:** `src/sort.zig:1455–1462`

**Problem:** `parseArgs -k with value` confirms the key is stored. The
`extractKey`, `compareLines` key-dispatch path, and `splitFields`
integration are only tested via pure-function helper tests. No test
verifies that `-k 2` actually sorts by the second field of structured
input.

**Fix:** Feed `b 2\na 1\nc 3\n`, run with `-k 2,2n`, assert `a 1\nb
2\nc 3\n`.

---

### [IMPORTANT] `-t` field separator has no behavioral test

**Location:** `src/sort.zig:1464–1470`

**Problem:** `parseArgs -t with value` confirms `opts.field_separator ==
':'`. The `splitFields(line, ':')` integration with `-k` is never tested
end-to-end.

**Fix:** Add a test combining `-t :` and `-k 2,2n` on colon-delimited
input.

---

### [IMPORTANT] `-z` zero-terminated has no behavioral test

**Location:** `src/sort.zig` (no test)

**Problem:** The `delimiter` variable at line 472 switches to NUL when
`zero_terminated` is true. This changes both how input is read and how
output is written. Neither path is tested.

**Fix:** Create a NUL-delimited temp file (binary content), run with
`-z`, verify NUL-delimited output.

---

### [IMPORTANT] `-h` human-numeric sort has no behavioral test

**Location:** `src/sort.zig:1394–1399`

**Problem:** `parseHumanNumber with suffixes` tests the parser in
isolation. No test calls `runSort` with `-h` and verifies that `1K`
sorts before `1M` which sorts before `1G`.

**Fix:** Add an end-to-end test: input `1G\n100M\n1K\n`, run with `-h`,
assert `1K\n100M\n1G\n`.

---

### [IMPORTANT] `-g` general-numeric sort has no behavioral test

**Location:** `src/sort.zig:1511–1515`

**Problem:** `compareGeneralNumeric with scientific notation` tests the
comparator directly. No test runs `runSort` with `-g` and verifies
output ordering.

**Fix:** Add end-to-end test: input `1e3\n1e2\n1e1\n`, run with `-g`,
assert `1e1\n1e2\n1e3\n`.

---

### [IMPORTANT] stdin code path has zero test coverage

**Location:** `src/sort.zig:546–549`

**Problem:** When `opts.files.items.len == 0`, `runSort` reads from
`std.fs.File.stdin()`. No test exercises this path. A bug here (e.g.
wrong delimiter, off-by-one in `readLines`) would be invisible to the
test suite.

The comment at line 1845–1846 acknowledges one test was removed to
avoid hangs. The project does not implement `runUtilWithInput()`, so
there is no standard mechanism for testing this path in unit tests.

**Fix (option A):** Implement `runSortWithInput(allocator, args,
input_file, ...)` and add a test that passes a temp file as the stdin
substitute.

**Fix (option B):** Add an integration test in
`tests/utilities/sort.sh` that pipes input and verifies output.

---

### [SUGGESTION] Test write buffers use 4096 bytes, not 8192

**Location:** `src/sort.zig:1671, 1701, 1709, 1735, 1859, 1881`

**Problem:** CLAUDE.md and TESTING_STRATEGY.md require 8192-byte I/O
buffers for consistency. Six test setup blocks create `write_buf:
[4096]u8` when writing temp file content. This is not a correctness bug
(test data is tiny), but it deviates from the project standard and
could mask buffer-boundary bugs if tests were ever scaled up.

**Fix:** Change all test `write_buf` declarations from `[4096]u8` to
`[8192]u8`.

---

### [SUGGESTION] `-R` random-sort test checks presence, not grouping

**Location:** `src/sort.zig:1657–1686`

**Problem:** `sort -R produces all input lines` verifies all three lines
appear but never verifies that equal lines are grouped (the documented
property of random sort per the help text: "shuffle, but group identical
keys"). A regression that broke the grouping guarantee would pass.

**Fix:** Add a case with duplicate lines: `apple\nbanana\napple\n`. After
`-R`, verify the two `apple` entries are adjacent.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 7 |
| SUGGESTION | 2 |

**Assessment: NEEDS_FIXES**

32 of 61 tests are parse-only stubs. The three MUST-tier behavioral
categories with zero end-to-end coverage — check mode (`-c`/`-C`),
output-to-file (`-o`), and stdin reading — represent complete blind
spots. All other MUST-tier sort modes (`-n`, `-r`, `-u`, `-f`, `-b`,
`-d`, `-i`, `-g`, `-h`, `-k`, `-t`, `-z`) are covered only by
parse-only tests.

---

## Prioritized Fix List

```
Fix Order:
1. [CRITICAL] -c/-C check mode — no behavioral test — src/sort.zig:1178
2. [CRITICAL] 32 parse-only MUST-tier flag tests — src/sort.zig:1435–1843
3. [CRITICAL] -o output-to-file — no behavioral test — src/sort.zig:575
4. [IMPORTANT] -r reverse sort — no behavioral test — src/sort.zig:655
5. [IMPORTANT] -u unique deduplication — no behavioral test — src/sort.zig:1210
6. [IMPORTANT] -k key-based sort — no behavioral test — src/sort.zig:647
7. [IMPORTANT] -t field separator — no behavioral test — src/sort.zig:267
8. [IMPORTANT] -z zero-terminated — no behavioral test — src/sort.zig:472
9. [IMPORTANT] -h human-numeric — no e2e test — src/sort.zig:789
10. [IMPORTANT] stdin path — zero test coverage — src/sort.zig:546
11. [SUGGESTION] test write buffers 4096→8192 — src/sort.zig:1671+
12. [SUGGESTION] -R grouping not verified — src/sort.zig:1657
```

REVIEW COMPLETE - NEEDS_FIXES
