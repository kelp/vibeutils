# nl Unit Test Audit

**Date:** 2026-03-28
**File:** `src/nl.zig`
**Test count:** 27 tests, 27 passed
**Stdin hang risk:** None — all unit tests pass file paths; zero
positionals (stdin) path is never exercised, which is correct.

---

## Parse-Only Test Assessment

No pure parse-only stubs found. Every test calls `runNl` end-to-end
and inspects either exit code or output content. Flag error-path tests
(`nl invalid flag`, `nl invalid body style`, `nl invalid number
format`, `nl invalid width`) check exit code 2, which is real
behavioral verification even though they do not exercise file I/O.

---

## Issues

### IMPORTANT: `-f` footer numbering has zero behavioral tests

```
[IMPORTANT] -f (footer numbering) is a MUST flag with no test
Location: src/nl.zig (no test)
Problem: -f is POSIX MUST. There is no runNl call that exercises
         footer section numbering. The footer code path in
         processLine/getStyleForSection is entirely untested.
Fix: Add a test with a file containing a footer delimiter (\:),
     use -f a, and assert exact numbered output for footer lines.
```

### IMPORTANT: `-p` (no-renumber) has zero behavioral tests

```
[IMPORTANT] -p / --no-renumber has no test
Location: src/nl.zig (no test)
Problem: -p is a POSIX MUST flag. The no_renumber branch in
         processLine (skipping the line_number reset on new header)
         is never exercised.
Fix: Add a test with multiple logical pages and -p, asserting that
     line numbers continue across page boundaries rather than
     resetting to opts.start.
```

### IMPORTANT: `-d` (custom section delimiter) has no runNl test

```
[IMPORTANT] -d custom delimiter exercised only in isSectionDelimiter
            unit test, never via runNl
Location: src/nl.zig (no runNl test for -d)
Problem: The resolveOptions -d parsing and the downstream
         isSectionDelimiter call with a non-default delimiter are
         never integrated. A bug in how resolveOptions feeds
         opts.delimiter into numberLines would go undetected.
Fix: Add a test: write a file using a custom delimiter (e.g., "!@"),
     call runNl with -d "!@", and assert sections are recognized.
```

### IMPORTANT: `-l` (join-blank-lines) has zero behavioral tests

```
[IMPORTANT] -l (join blank lines) is a POSIX MUST flag with no test
Location: src/nl.zig (no test)
Problem: The blank_count accumulation logic in the .all branch of
         processLine is untested. -l 2 should treat two consecutive
         blank lines as one; this path is never executed by any test.
Fix: Add a test with -b a -l 2 on a file with two consecutive blank
     lines; assert the pair produces one numbered blank-line output.
```

### IMPORTANT: `nl section delimiters` test uses weak containment
check

```
[IMPORTANT] "nl section delimiters" uses indexOf instead of exact
            string comparison
Location: src/nl.zig:887-888
Problem: The test only checks that "HEADER" and "body1" appear
         somewhere in the output. It cannot detect wrong line numbers,
         wrong separators, extra blank lines, or missing numbering.
         A regression that produces "HEADER" with no number or a
         wrong number would pass silently.
Fix: Replace the indexOf checks with an expectEqualStrings call on
     the exact expected output, including line numbers, separators,
     and delimiter blank lines.
```

### IMPORTANT: `-i 0` (zero increment) is untested and silently
accepted

```
[IMPORTANT] Zero increment accepted without validation; behavior
            untested
Location: src/nl.zig:232-239 (resolveOptions increment parsing)
Problem: parseSignedInt accepts 0. With -i 0 every line gets the same
         line number. GNU nl also accepts 0 (it is defined behavior),
         but this project never verifies the output. If the intent is
         to reject it, the validation gap would be invisible.
Fix: Add a test with -i 0 to document and assert the actual behavior
     (e.g., every line numbered 1). This pins the behavior and flags
     any unintended change.
```

### SUGGESTION: Long-form flags (`--body-numbering`, etc.) have no
behavioral tests

```
[SUGGESTION] Long-form equivalents of all short flags are untested
Location: src/nl.zig (no runNl test uses any --long-form flag)
Problem: The argparse dual-field pattern (args.b orelse
         args.body_numbering, etc.) is never exercised via long flags.
         A bug in the long-name wiring would be invisible.
Fix: Add at least one test using a long flag, e.g.,
     --body-numbering=a or --number-format=rz, and assert correct
     output.
```

### SUGGESTION: `-v` with negative starting number is untested

```
[SUGGESTION] Negative start value accepted but not tested
Location: src/nl.zig:225-231 (resolveOptions start parsing)
Problem: parseSignedInt accepts negatives. formatNumber has a
         negative-number branch for right_zero. Neither is exercised
         via runNl. The negative path in formatNumber is only hit
         by the "formatNumber right-zero" unit test directly.
Fix: Add a runNl test with -v -5 and assert the output shows
     negative line numbers formatted correctly.
```

### SUGGESTION: `-h` flag with no header delimiter in file is
untested

```
[SUGGESTION] -h behavior when no header delimiter exists is
             undocumented by tests
Location: src/nl.zig (no test)
Problem: When -h a is passed but the file contains no \:\:\: header
         delimiter, the entire file stays in .body section and -h has
         no visible effect. The section-delimiter test uses -h a but
         its file has a header delimiter. A file without one is never
         tested with -h, so the no-op case is undocumented.
Fix: Add a test passing -h a with a plain file and asserting that
     output is identical to the default (body numbering only).
```

### SUGGESTION: stdin via "-" positional path has zero unit coverage

```
[SUGGESTION] The "-" positional stdin code path is untested
Location: src/nl.zig:566-572
Problem: The branch that handles "-" as a filename (reading from
         stdin) is structurally separate from the no-positionals
         stdin path. It is never exercised at the unit level.
         (Note: not a hang risk — tests always provide file paths.
         This is a coverage gap only.)
Fix: Use common.test_utils or a pipe to feed input and call
     runNl with &.{"-"} to cover this branch.
```

---

## Flag Coverage Summary

| Flag | MUST | Has behavioral runNl test |
|------|------|---------------------------|
| -b   | yes  | yes (a, t, n styles)      |
| -d   | yes  | no (only unit isSectionDelimiter) |
| -f   | yes  | no                        |
| -h   | yes  | weak (indexOf only)       |
| -i   | yes  | yes                       |
| -l   | yes  | no                        |
| -n   | yes  | yes (ln, rz)              |
| -p   | yes  | no                        |
| -s   | yes  | yes                       |
| -v   | yes  | yes (positive only)       |
| -w   | yes  | yes                       |

MUST flags with zero behavioral coverage: **-d, -f, -l, -p** (4 of 11)

---

## Summary

| Severity   | Count |
|------------|-------|
| CRITICAL   | 0     |
| IMPORTANT  | 5     |
| SUGGESTION | 4     |

**Overall assessment: NEEDS_FIXES**

No stdin hang risk. No parse-only stubs. The implementation tests are
real end-to-end tests using temporary files — a solid foundation. The
gaps are coverage omissions for MUST flags, not structural problems.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Add -f footer numbering test — src/nl.zig
2. [IMPORTANT] Add -p no-renumber test — src/nl.zig
3. [IMPORTANT] Add -l join-blank-lines test — src/nl.zig
4. [IMPORTANT] Replace indexOf in section-delimiters test with
               exact string assertion — src/nl.zig:887-888
5. [IMPORTANT] Add -d custom delimiter runNl test — src/nl.zig
6. [SUGGESTION] Add --body-numbering long-form test — src/nl.zig
7. [SUGGESTION] Add -v negative start test — src/nl.zig
8. [SUGGESTION] Add -h with no header delimiter test — src/nl.zig
9. [SUGGESTION] Add "-" positional stdin test — src/nl.zig
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
