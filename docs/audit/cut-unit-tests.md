# Unit Test Audit: cut

**Date**: 2026-03-28
**File**: src/cut.zig (tests embedded)
**Test run**: `zig build test --summary all`
**Result**: 53 tests, all pass

---

## Filter Utility Risk Assessment

cut reads from stdin when no file arguments are given.
All 53 unit tests avoid stdin by either:

- Calling `runCut` with a temp-file path argument, or
- Calling internal functions (`cutBytesOrChars`,
  `cutFields`, `cutFieldsWhitespace`, `parseRangeList`,
  `isSelected`, `processFile`) directly with in-memory
  buffers.

**No stdin hang risk.** The `runUtilWithInput()` pattern is
not needed here because the file-argument path is exercised
instead.

---

## Test Inventory (53 tests)

| # | Test name | Type |
|---|-----------|------|
| 1 | cut --help shows help message | behavioral |
| 2 | cut --version shows version information | behavioral |
| 3 | cut no mode specified returns error | behavioral |
| 4 | cut multiple modes returns error | behavioral |
| 5 | cut -s without -f returns error | behavioral |
| 6 | cut -d without -f returns error | behavioral |
| 7 | cut unknown flag returns error | behavioral |
| 8 | parseRangeList single value | unit |
| 9 | parseRangeList multiple values | unit |
| 10 | parseRangeList range N-M | unit |
| 11 | parseRangeList range N- | unit |
| 12 | parseRangeList range -M | unit |
| 13 | parseRangeList complex list | unit |
| 14 | parseRangeList overlapping ranges merge | unit |
| 15 | parseRangeList adjacent ranges merge | unit |
| 16 | parseRangeList unsorted ranges are sorted | unit |
| 17 | parseRangeList zero value is invalid | unit |
| 18 | parseRangeList reversed range is invalid | unit |
| 19 | parseRangeList empty string is invalid | unit |
| 20 | parseRangeList bare dash is invalid | unit |
| 21 | isSelected basic | unit |
| 22 | isSelected with complement | unit |
| 23 | cutBytesOrChars single byte | unit |
| 24 | cutBytesOrChars range | unit |
| 25 | cutBytesOrChars multiple selections | unit |
| 26 | cutBytesOrChars complement | unit |
| 27 | cutFields basic | unit |
| 28 | cutFields multiple fields | unit |
| 29 | cutFields range | unit |
| 30 | cutFields custom delimiter | unit |
| 31 | cutFields no delimiter in line prints line | unit |
| 32 | cutFields no delimiter in line with -s suppresses output | unit |
| 33 | cutFields complement | unit |
| 34 | cutFields output delimiter | unit |
| 35 | cut with file input bytes | behavioral |
| 36 | cut with file input fields | behavioral |
| 37 | cut nonexistent file returns error | behavioral |
| 38 | cut: -n flag is accepted with -b | behavioral |
| 39 | cut: -n -b preserves multi-byte characters | behavioral |
| 40 | cut: -w splits on whitespace | behavioral |
| 41 | cut: -w handles multiple consecutive spaces | behavioral |
| 42 | cut: -w skips leading whitespace | behavioral |
| 43 | cut: -w with no whitespace prints whole line | behavioral |
| 44 | cut: -w and -d are mutually exclusive | behavioral |
| 45 | cut: -w without -f returns error | behavioral |
| 46 | cutFieldsWhitespace basic | unit |
| 47 | cutFieldsWhitespace multiple spaces | unit |
| 48 | cutFieldsWhitespace tabs and spaces | unit |
| 49 | cutFieldsWhitespace no whitespace prints line | unit |
| 50 | cutFieldsWhitespace no whitespace with -s suppresses | unit |
| 51 | cut: -n without -b has no effect on field mode | behavioral |
| 52 | cut --version output contains common.name | behavioral |
| 53 | cut: processFile reports read errors to stderr | behavioral |

Parse-only stubs: **0**. Every test either checks output
content, exit code, or stderr content.

---

## Flag Coverage Against Spec

| Flag | Tier | Covered? | Notes |
|------|------|----------|-------|
| -b | MUST | yes | tests 35, 38, 39 via runCut |
| -c | MUST | no end-to-end | only exercised at cutBytesOrChars level; no runCut test for -c |
| -d | MUST | yes | tests 30, 36 |
| -f | MUST | yes | tests 36 and field-mode tests |
| -n | MUST | yes | tests 38, 39, 51 |
| -s | MUST | yes | tests 5, 32, 50 |
| -w | SHOULD | yes | tests 40-45, 46-50 |
| -z | SHOULD | no | no runCut test; zero-terminated mode untested end-to-end |
| --complement | SHOULD | partial | tested at internal level (22, 26, 33); no runCut test wiring --complement flag |
| --output-delimiter | SHOULD | partial | tested at internal level (34); no runCut test wiring --output-delimiter flag |

---

## Issues

### [IMPORTANT] -c has no end-to-end test through runCut

Location: src/cut.zig:647 (test section)
Problem: `-c` is a MUST flag. Tests 23-26 exercise
`cutBytesOrChars` directly (the same function -b uses),
but no test calls `runCut` with `-c`. This leaves the
argument-parsing path for `-c`, the `mode == .characters`
branch at line 324, and the `no_split == false` guarantee
for character mode (line 490) untested end-to-end. A
regression in the argument parser's `-c` wiring would not
be caught.
Fix: Add a `runCut` test that passes `-c 2-4` with a known
ASCII string and verifies the output matches the expected
substring.

---

### [IMPORTANT] -z has no end-to-end test through runCut

Location: src/cut.zig:647 (test section)
Problem: `-z` (zero-terminated line mode) is a SHOULD
flag. The `line_terminator` variable at line 381 and the
`readLine` loop both depend on it, but no test calls
`runCut` with `-z`. A file containing NUL-delimited records
never exercises the live code path.
Fix: Add a `runCut` test that creates a temp file
containing NUL-delimited records (`"one\x00two\x00"`) and
verifies `-z -b 1` emits `"o\x00o\x00"`.

---

### [IMPORTANT] --complement has no end-to-end test
through runCut

Location: src/cut.zig:647 (test section)
Problem: `--complement` is a SHOULD flag. Tests 22, 26,
and 33 call internal functions with `do_complement = true`,
but no test calls `runCut` with `--complement`. The
argument-parser wiring and the pass-through at lines 394,
415, and 439 are untested.
Fix: Add a `runCut` test that passes `--complement -b 2`
with `"abc"` and asserts the output is `"ac"`.

---

### [IMPORTANT] --output-delimiter has no end-to-end test
through runCut

Location: src/cut.zig:647 (test section)
Problem: `--output-delimiter` is a SHOULD flag. Test 34
calls `cutFields` directly with a custom `output_delim`
argument, but no test calls `runCut` with
`--output-delimiter=`. The argument-parser wiring at line
372, and the logic that lets it override the default
delimiter, are untested end-to-end.
Fix: Add a `runCut` test that passes
`--output-delimiter=| -f 1,3 -d :` and verifies that
`"a:b:c"` produces `"a|c"`.

---

### [SUGGESTION] Stale RED-phase comment in test 53

Location: src/cut.zig:1297-1299, 1338
Problem: The test `"cut: processFile reports read errors to
stderr"` contains a comment claiming the test should fail:

```
// the bug (line 469: _ = stderr_writer) means stderr
// stays empty.
// This assertion will FAIL because processFile discards
// stderr_writer
```

This is false. The `_ = stderr_writer` discard was removed
when the bug was fixed; the implementation now uses
`stderr_writer` correctly (line 481). The test passes. The
stale comment misleads maintainers into thinking it is an
intentionally-failing red-phase test.
Fix: Remove lines 1297-1299 and 1338. Replace with a
plain description: "processFile must write a diagnostic
to stderr when a read error occurs."

---

### [SUGGESTION] parseRangeList whitespace separator not
tested

Location: src/cut.zig:718 (parseRangeList test block)
Problem: The code audit (cut-code.md) found that the
range parser does not accept whitespace-separated lists
(`"1 3 5"`), which both GNU cut and macOS cut support.
There is no unit test documenting or asserting this
limitation. A test like
`parseRangeList(alloc, "1 3 5")` returning `error.InvalidRange`
would pin the current (deficient) behaviour and make the
expected fix obvious.
Fix: Add a test `"parseRangeList whitespace-separated list"` that
documents the expected pass-through behaviour after the fix
is applied. Until the fix is in, mark it with a clear
comment explaining the current limitation.

---

## Summary

**Total tests**: 53
**Passing**: 53
**Parse-only stubs**: 0
**Stdin hang risk**: none

**Counts by severity**:
- CRITICAL: 0
- IMPORTANT: 4
- SUGGESTION: 2

**Assessment**: NEEDS_FIXES

**Fix Order**:
```
1. [IMPORTANT] Add runCut end-to-end test for -c flag
   — src/cut.zig test section
2. [IMPORTANT] Add runCut end-to-end test for -z flag
   — src/cut.zig test section
3. [IMPORTANT] Add runCut end-to-end test for --complement
   — src/cut.zig test section
4. [IMPORTANT] Add runCut end-to-end test for
   --output-delimiter — src/cut.zig test section
5. [SUGGESTION] Remove stale RED-phase comment in test 53
   — src/cut.zig:1297-1299, 1338
6. [SUGGESTION] Add parseRangeList whitespace-separator
   test pinning known gap — src/cut.zig:718 area
```

REVIEW COMPLETE - NEEDS_FIXES
