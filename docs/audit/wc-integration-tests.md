---
utility: wc
audit_date: 2026-03-28
test_file: tests/utilities/wc_test.sh
result: NEEDS_FIXES
tests_run: 96
tests_passed: 96
---

# wc Integration Test Audit

## Summary

96/96 tests pass. The suite is substantial and covers the
happy path well — stdin filter, flag combinations, Unicode,
multiple files, error recovery, and output formatting all
have real behavioral assertions. However, several gaps let
production bugs hide behind passing tests.

---

## Findings

### CRITICAL

```
[CRITICAL] Column-width scaling is untested — fixed 8-char
           format breaks when counts reach 9+ digits
Location:  tests/utilities/wc_test.sh (no test exists)
Problem:   GNU wc dynamically widens columns to fit the
           largest count in the run (e.g., a 10-digit byte
           count forces all numbers to 10 chars wide).
           src/wc.zig uses a hard-coded {d: >8} format.
           Nothing in the test suite exercises a file large
           enough to expose this. All test files are tiny so
           all counts fit in 8 chars and the format passes.
Fix:       Add a test that synthesizes a file whose byte
           count > 99,999,999 (9+ digits). Pipe through
           wc -c and assert the count is not truncated and
           the column is at least as wide as the count.
           Example:
             python3 -c "import sys; sys.stdout.buffer.write(b'x'*100000000)" \
               > "$big_file"
             out=$("$binary" -c "$big_file" | awk '{print $1}')
             [[ "$out" == "100000000" ]] || fail
```

```
[CRITICAL] -L (max line length) measures bytes, not display
           columns — tab expansion and multi-byte chars are
           untested
Location:  tests/utilities/wc_test.sh (no test exists)
Problem:   GNU wc -L counts display columns (tabs expand to
           next 8-column stop; each multi-byte char counts
           as its display width, usually 1 for Latin, 2 for
           CJK). The implementation counts raw bytes for
           non-newline characters (src/wc.zig:325
           `current_line_length += 1`). A line containing a
           tab or a 3-byte UTF-8 character will produce a
           wrong -L value, but no test catches it because
           all -L test inputs use ASCII-only content.
Fix:       Add two tests:
           1. Tab expansion: printf "a\tb\n" has display
              width 9 (tab advances to column 8). Assert
              `wc -L` returns 9, not 3.
           2. CJK: printf "ab\n" vs printf "中文\n". The
              two-character CJK string has display width 4.
              Assert `wc -L` returns 4.
```

---

### IMPORTANT

```
[IMPORTANT] Byte-count assertion for simple_file assumes
            no trailing newline but create_temp_file uses
            echo -n which omits newline — this is correct,
            but the comment is misleading and the expected
            value is fragile
Location:  tests/utilities/wc_test.sh:34
Problem:   `create_temp_file "Hello world"` uses `echo -n`
           (common.sh:419), so the file is 11 bytes with 0
           newlines. The test expects "0 2 11". If
           create_temp_file ever changes to include a
           trailing newline (as is conventional), this test
           will fail — but more importantly, the test does
           NOT separately verify the -l 0 result is
           correct for a file that was intended to have
           0 newlines. The intent is hidden.
Fix:       Use printf explicitly in the test to make the
           content deterministic:
             printf '%s' "Hello world" > "$simple_file"
           and add a comment explaining the 0 newline count
           is because the file has no trailing newline.
```

```
[IMPORTANT] Multiple-files total line check uses a weak
            pattern match that passes even if individual
            file lines are wrong
Location:  tests/utilities/wc_test.sh:128-133
Problem:   The "wc multiple files shows total" test only
           checks that the string "total" appears somewhere
           in the output. It does not verify:
           - the counts on the total line are arithmetically
             correct (sum of per-file counts)
           - the per-file lines themselves appear and are
             correct
Fix:       Capture full output and assert exact expected
           string, or at minimum assert the total line
           contains the expected sum. Example:
             out=$("$binary" "$file1" "$file2" "$file3")
             total_line=$(echo "$out" | grep "total")
             [[ "$total_line" =~ "    2  total" ]] || fail
```

```
[IMPORTANT] Error recovery "processes all valid files" test
            uses the system wc to count lines in the output,
            creating a self-referential dependency
Location:  tests/utilities/wc_test.sh:396-402
Problem:   line_count=$(echo "$error_recovery_output" | wc -l)
           This invokes the system wc, not the binary under
           test. If the system wc is not installed or
           behaves differently (e.g., on a minimal container
           image), the test will fail for the wrong reason.
           More importantly, checking line count alone does
           not verify the content of those lines.
Fix:       Replace with a direct string check:
             [[ "$error_recovery_output" =~ "$good1" ]] || fail
             [[ "$error_recovery_output" =~ "$good2" ]] || fail
             [[ "$error_recovery_output" =~ total ]] || fail
```

```
[IMPORTANT] stdin "no arguments" tests do not verify the
            output has no filename field
Location:  tests/utilities/wc_test.sh:104-107
Problem:   The four stdin tests assert exact output values
           (e.g., "       1       2      12") but they do
           not assert the absence of a filename. GNU wc
           with no arguments and stdin input prints counts
           only, with no filename. A bug that adds a blank
           filename field or a "-" would not be caught.
Fix:       Assert the output matches exactly and contains
           no trailing filename:
             [[ "$out" == "       1       2      12" ]] || fail
           The current test_command_output already does
           exact matching, so this is already correct for
           lines 104-107. However, no test specifically
           asserts that a trailing space or empty field is
           absent. Add:
             test_command_output "wc stdin no filename field" \
               "       1       2      12" \
               bash -c "echo 'hello world' | '$binary'"
           and verify no extra whitespace follows the count.
           (This is already tested via exact match — the gap
           is that the test name does not signal this intent,
           making future regressions less obvious.)
```

```
[IMPORTANT] -c and -m "last flag wins" tests use hardcoded
            expected byte values that are locale-dependent
Location:  tests/utilities/wc_test.sh:91-92
Problem:   The tests at lines 91-92 assert exact numeric
           values ("      23 $unicode_file" for -m and
           "      28 $unicode_file" for -c). These values
           depend on the exact content written by
           create_temp_file for $unicode_file (which itself
           depends on the shell interpreting $'Hello 世界\n
           Unicode test ñ'). If the locale is not UTF-8,
           the byte/char counts will differ, causing a
           false failure. No locale guard is present.
Fix:       Add a locale guard:
             if [[ "${LANG:-}${LC_ALL:-}" =~ UTF-8 ]]; then
               test_command_output "wc -m unicode" \
                 "      23 $unicode_file" "$binary" -m "$unicode_file"
             else
               print_test_result "wc -m unicode" "SKIP" \
                 "Requires UTF-8 locale"
             fi
```

```
[IMPORTANT] -L test for long_line_file expects 101 but the
            content is 101 bytes only if interpreted as
            ASCII — the assertion is fragile with Unicode
            environments and the source content is wrong
Location:  tests/utilities/wc_test.sh:29, 77, 80
Problem:   long_line_file is created with a 101-character
           ASCII string. The -L assertion of 101 is correct
           for ASCII. But the same test also provides the
           only coverage for -L with a "long" line, and
           that content happens to be exactly ASCII with no
           tabs. As noted in the CRITICAL finding above,
           tab/Unicode -L behavior is untested. Additionally,
           the content string should be explicitly measured
           to avoid off-by-one errors if it is ever edited.
Fix:       Define the expected length as a variable:
             local content="This is a very long line..."
             local expected_len=${#content}
             test_command_output "wc -L long line" \
               "$(printf '%7d' $expected_len) $long_line_file" \
               "$binary" -L "$long_line_file"
```

```
[IMPORTANT] wc -L for multiline_file: expected value of 6
            is based on "Line 1" being 6 chars, but this
            silently passes even if -L counts newlines
Location:  tests/utilities/wc_test.sh:75
Problem:   multiline_file contains $'Line 1\nLine 2\nLine 3'
           Each line is 6 bytes. The test expects "6". This
           is correct, but if the implementation were to
           include the newline in the line length (a common
           off-by-one), the value would be 7 and the test
           would catch it. This test is therefore genuinely
           behavioral — but the comment says "Longest line
           is 'Line 1', 'Line 2', or 'Line 3'" without
           noting why the value is 6 (not 7), obscuring the
           off-by-one boundary being tested.
Fix:       Add a comment:
             # 6 = len("Line 1"), newline NOT counted by -L
```

---

### SUGGESTION

```
[SUGGESTION] test_command_output_pattern for multiple-files
             -l and -w uses a regex that would match garbage
Location:  tests/utilities/wc_test.sh:136-137
Problem:   The pattern ".*0.*0.*2.*2 total" for -l and
           ".*2.*3.*3.*8 total" for -w are so permissive
           that they would match almost any output
           containing those digits in any spacing. A correct
           but misformatted total line (e.g., "2total")
           would pass the pattern test.
Fix:       Use more precise patterns or use exact
           test_command_output with known expected strings.
```

```
[SUGGESTION] No test verifies that --color=always / --color=never
             affects output, and --color=invalid produces exit 2
Location:  tests/utilities/wc_test.sh (no test exists)
Problem:   The --color flag is in the wc-flags.md spec as
           KEEP priority. It is implemented in wc.zig but
           has zero integration test coverage.
Fix:       Add:
             test_command_succeeds "wc --color=never" \
               "$binary" --color=never "$simple_file"
             test_command_exit_code "wc --color=invalid" 2 \
               "$binary" --color=invalid "$simple_file" 2>/dev/null
```

```
[SUGGESTION] "wc comprehensive test count" gate (line 407)
             counts ALL tests in the session, not wc tests
Location:  tests/utilities/wc_test.sh:407
Problem:   $TESTS_RUN is a global counter shared across the
           session. If the test runner executes wc last, the
           counter includes tests from every other utility
           run before it, making the 70-test gate
           meaningless as a wc-specific coverage check.
Fix:       Capture the count at function entry and check
           the delta:
             local start_count=$TESTS_RUN
             # ... all tests ...
             local wc_tests=$(( TESTS_RUN - start_count ))
             [[ $wc_tests -ge 70 ]] || fail
```

```
[SUGGESTION] Mixed file+stdin tests use a weak regex that
             does not verify individual file counts
Location:  tests/utilities/wc_test.sh:205-207
Problem:   ".*2.*2.*total" matches any output with at least
           two 2s and the word total. The per-file line
           content is not verified.
Fix:       Use more specific patterns or exact matching.
```

```
[SUGGESTION] No test for wc with /dev/null as input
Location:  tests/utilities/wc_test.sh (no test exists)
Problem:   /dev/null is a common idiom for counting lines
           in a pipeline. Verifying wc /dev/null produces
           "0 0 0 /dev/null" is a useful baseline.
Fix:       Add:
             test_command_output "wc /dev/null" \
               "       0       0       0 /dev/null" \
               "$binary" /dev/null
```

---

## Coverage Against wc-flags.md

| Flag       | Tier   | Behavioral Test | Quality        |
|------------|--------|-----------------|----------------|
| -c         | MUST   | yes             | good           |
| -l         | MUST   | yes             | good           |
| -m         | MUST   | yes             | locale risk    |
| -w         | MUST   | yes             | good           |
| -L         | SHOULD | yes             | missing tab/CJK|
| --color    | KEEP   | no              | zero coverage  |
| --libxo    | SHOULD | no (WONT impl)  | n/a            |

---

## Fix Order

```
Fix Order:
1. [CRITICAL]   Column-width scaling with 9+ digit counts —
                tests/utilities/wc_test.sh (add test)
2. [CRITICAL]   -L tab expansion and CJK display width —
                tests/utilities/wc_test.sh (add test)
3. [IMPORTANT]  Multiple-files total line: verify sum, not
                just presence of "total" — line 128
4. [IMPORTANT]  Unicode -c/-m tests: add UTF-8 locale guard
                — lines 91-92, 67-71
5. [IMPORTANT]  Error recovery: remove system wc dependency
                — line 396
6. [IMPORTANT]  -L long_line_file: derive expected value
                programmatically — lines 77, 80
7. [SUGGESTION] --color flag: add existence and error tests
8. [SUGGESTION] test_command_output_pattern patterns too
                permissive — lines 136-137, 205-207
9. [SUGGESTION] Fix TESTS_RUN gate to count only wc tests
                — line 407
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
