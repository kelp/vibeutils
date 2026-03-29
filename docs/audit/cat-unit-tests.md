---
date: 2026-03-28
utility: cat
audit_type: unit-tests
status: NEEDS_FIXES
tests_counted: 17
---

# cat Unit Test Audit

## Summary

17 unit tests. All tests use real temp files and call `runCat()`
directly — no stdin hang risk exists in the current test suite
because every test passes at least one file path argument,
bypassing the `positionals.len == 0` stdin branch.

However, the stdin path in `runCat()` (triggered when no
positionals are given, or when `"-"` is passed) has **zero unit
test coverage**. That is an important gap. The `-v` flag (MUST
tier) also has no standalone unit test. And the `-e` test verifies
the wrong behavior (see CRITICAL below).

---

## Filter Utility Assessment

`cat` is a filter utility per `docs/TESTING_STRATEGY.md`. The
implementation exposes `runCat()` (not a
`runCatWithInput()` split). All 17 unit tests supply a file-path
argument, so they never reach the stdin branch and will **not
hang**. The stdin-blocked path is untested, not a test-hang risk.

No `runCatWithInput()` pattern is implemented. That is the correct
pattern for testing the stdin path, but it is missing entirely.

---

## Issues

```
[CRITICAL] -e test verifies wrong expected output
Location: src/cat.zig:548-565
Problem: `-e` is equivalent to `-vE` (show non-printing chars AND
  line ends). The test input "Line 1\nLine 2\n" contains only
  printable ASCII, so `-v` makes no visible difference. The test
  asserts "Line 1$\nLine 2$\n" — identical output to a `-E`-only
  test. This test would pass even if -v were never applied, making
  it a cannot-fail test for the `-v` component of `-e`.
Fix: Use input that contains at least one non-printing character
  (e.g., "Line\x01End\n") and assert the caret notation appears
  in the output alongside the $ end marker.
```

```
[IMPORTANT] -v flag (MUST tier) has no standalone unit test
Location: src/cat.zig (no test targeting -v alone)
Problem: `-v` is listed as MUST in docs/specs/cat-flags.md.
  The only exercising of show_nonprinting logic is through
  -A (show_all) and the -e/-t combo tests. None of those tests
  isolate -v behavior. A bug in -v that only affects the
  standalone flag path would go undetected.
Fix: Add a test "cat with -v shows non-printing chars" that
  calls runCat with ["-v", file_path] where the file contains
  control characters and high-byte characters, and asserts the
  correct caret/M- notation output.
```

```
[IMPORTANT] stdin path (no-args and "-" arg) has zero unit coverage
Location: src/cat.zig:113-127
Problem: When positionals.len == 0 or a positional equals "-",
  runCat reads from the real stdin. This path is never exercised
  by any unit test. Bugs in that branch (error handling, line
  state continuity, flush ordering) are invisible to the unit
  suite.
Fix: Add a runCatWithInput() internal function that accepts a
  reader instead of opening stdin, following the pattern in
  src/tr.zig:447. Then write unit tests that supply a
  std.io.fixedBufferStream as the input source, covering the
  no-args stdin path and the "-" literal path.
```

```
[IMPORTANT] -b overrides -n: no unit test
Location: src/cat.zig (no test for -n -b together)
Problem: The GNU spec says -b overrides -n. The integration test
  covers this (cat_test.sh:62), but there is no unit test. The
  implementation merges the two flags in processFormattedLineChunk
  with a conditional; a regression there would only be caught
  by the integration suite, which is slower to run.
Fix: Add "cat with -n -b conflict: -b wins" unit test using a
  file with blank and non-blank lines, asserting that blank lines
  are not numbered.
```

```
[IMPORTANT] Line number continuity across multiple files: no unit test
Location: src/cat.zig:109 (LineNumberState shared across files)
Problem: Line numbers are meant to be continuous across files
  when -n or -b is used. The multi-file test ("cat concatenates
  multiple files") does not use -n. No unit test verifies that
  line_number increments continuously when cat processes two
  files in one invocation.
Fix: Add "cat -n continuous numbering across files" unit test
  using two temp files and asserting numbers continue from the
  last line of the first file into the second.
```

```
[SUGGESTION] -s squeeze: no test for exactly two consecutive blanks
Location: src/cat.zig:451 (test "cat with -s squeezes blank lines")
Problem: The existing -s test uses four consecutive blank lines.
  The squeeze logic triggers when prev_blank is true on a second
  consecutive blank. A test with exactly two blanks (the minimal
  triggering case) would be a cleaner boundary test and would
  catch an off-by-one in the consecutive-blank counter.
Fix: Add or extend the -s test with input "Line\n\n\nEnd\n"
  (exactly two blanks) and assert "Line\n\nEnd\n".
```

```
[SUGGESTION] -E flag: no test for file with no trailing newline
Location: src/cat.zig:470 (test "cat with -E shows ends")
Problem: GNU cat -E appends $ before each newline but does NOT
  add $ at true end-of-file when there is no trailing newline.
  The existing test uses "Line 1\nLine 2\n" (has trailing newline)
  and the integration test file2 also lacks a no-trailing-newline
  case for -E. If processFormattedLineChunk incorrectly appends
  $ to the last partial line, no unit test would catch it.
Fix: Add a test with input "Line1\nLine2" (no trailing newline)
  and assert "Line1$\nLine2" (no $ after Line2).
```

```
[SUGGESTION] -A test uses a file with only printable non-tab chars
  in its second line — the -v component goes unexercised
Location: src/cat.zig:529-546
Problem: "Line 1\t\nLine 2\n" — Line 2 has no non-printing
  chars, so the show_nonprinting path for that line is
  never triggered. This is a minor coverage gap; the
  -A+control-chars test (line 626) is a better -A test.
Fix: Consider removing the redundant simple -A test and
  keeping only the control-char variant, or rename the
  simple test to focus only on -E/-T and leave -v to the
  dedicated test once it exists.
```

---

## Flag Coverage Matrix

| Flag | Tier   | Standalone unit test | Behavioral verification |
|------|--------|---------------------|------------------------|
| -n   | MUST   | yes                 | yes                    |
| -b   | MUST   | yes                 | yes                    |
| -s   | MUST   | yes                 | yes                    |
| -t   | MUST   | yes (combo only)    | yes                    |
| -u   | MUST   | yes                 | yes (ignored)          |
| -v   | MUST   | **no**              | partial (via -A, -t)   |
| -e   | MUST   | yes                 | **partially wrong**    |
| -E   | SHOULD | yes                 | yes                    |
| -T   | SHOULD | yes                 | yes                    |
| -A   | SHOULD | yes                 | yes                    |
| -l   | SHOULD | yes                 | yes (ignored)          |
| `-`  | n/a    | **no**              | none                   |
| stdin (no args) | n/a | **no** | none              |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -e test cannot-fail for -v component — src/cat.zig:548
2. [IMPORTANT] Add -v standalone unit test — src/cat.zig (new test)
3. [IMPORTANT] Add runCatWithInput() + stdin/dash unit tests — src/cat.zig:113
4. [IMPORTANT] Add -n -b conflict unit test — src/cat.zig (new test)
5. [IMPORTANT] Add -n multi-file continuity unit test — src/cat.zig (new test)
6. [SUGGESTION] Add -s two-blank boundary test — src/cat.zig:451
7. [SUGGESTION] Add -E no-trailing-newline test — src/cat.zig:470
8. [SUGGESTION] Clean up redundant -A test — src/cat.zig:529
```

REVIEW COMPLETE - NEEDS_FIXES
