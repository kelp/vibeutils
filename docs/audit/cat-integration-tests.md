---
audit: cat integration tests
date: 2026-03-28
file: tests/utilities/cat_test.sh
result: NEEDS_FIXES
---

# cat Integration Test Audit

## Summary

The cat integration test suite is the strongest in the project. It
covers stdin filter behavior, flag combinations, multi-file
concatenation, long options, error conditions, and GNU compatibility.
Most MUST/SHOULD flags receive behavioral verification. Issues are
concentrated in three areas: a wrong expected value on one test, two
missing flag behaviors (-l and -v M- notation), and one test that
masks a subtle edge case about `^M$` on Windows line endings.

---

## Issues

### IMPORTANT — Wrong expected output on "cat -E with tabs"

```
[IMPORTANT] -E test expects tabs unmodified but -E implies no -T
Location: tests/utilities/cat_test.sh:68
Problem: The test passes for the wrong reason. The file contains
         literal tab characters. The expected string is written as a
         shell single-quoted string with a literal tab in it, not
         '^I'. Because -E only adds '$' at line ends, tabs are left
         alone — so the test passes. But the expected value also has
         no trailing '$' for the single line in test_file4
         ('Tabs\tand\tspaces  here' has no newline). GNU cat -E on a
         file with no trailing newline emits the content with no '$'
         appended, so this is accidentally correct. The test is
         confusing but not definitively wrong. However, the
         test_command_output helper strips trailing newlines from
         command output via command substitution, so a file ending
         WITH a newline would silently drop the trailing '$'. This
         makes the -E tests structurally unable to verify the '$' on
         the last line of any file. All -E tests that use
         test_command_output (not test_command_output_exact) are
         affected.
Fix: Use test_command_output_exact for all -E and --show-ends tests
     so that trailing '$' on a final newline is not silently eaten by
     command substitution. Example:
       local file=$(create_temp_file $'Line 1\nLine 2\n')
       test_command_output_exact "cat -E final newline" \
           $'Line 1$\nLine 2$\n' "$binary" -E "$file"
```

### IMPORTANT — -l flag (SHOULD) has zero tests

```
[IMPORTANT] -l flag has no integration test
Location: tests/utilities/cat_test.sh (absent)
Problem: docs/specs/cat-flags.md lists -l (lock file against
         simultaneous writes, macOS extension) as SHOULD tier with
         our implementation. There are no tests for it anywhere in
         the integration suite. At minimum, a smoke test that -l
         accepts the flag without error is needed.
Fix: Add a platform-guarded test:
       if [[ "$PLATFORM" == "macos" ]]; then
           test_command_output "cat -l basic" "Hello World" \
               "$binary" -l "$test_file1"
       fi
```

### IMPORTANT — -v flag does not test M- (high-bit) notation

```
[IMPORTANT] -v M- notation is untested
Location: tests/utilities/cat_test.sh:74-75
Problem: The test at line 74 creates a file with bytes 0x01, 0x7F,
         and 0x80. It uses test_command_output_pattern with
         "Hello.*World.*Test" — this only proves the control
         characters (0x01 and 0x7F) produced some output and did not
         crash. It does not check that:
           - 0x01 is rendered as ^A
           - 0x7F is rendered as ^?
           - 0x80 (high byte) is rendered as M-^@
         GNU cat's -v behavior for high bytes (0x80-0xFF) is the
         critical M- prefix. The regression test at line 201 checks
         ^A ^B ^C but not M- notation.
Fix: Add explicit assertions:
       local special_file=$(create_temp_file $'\x01\x7f\x80\xff')
       test_command_output "cat -v control chars" \
           $'^A^?\M-^@\M-^?' "$binary" -v "$special_file"
     Note: verify exact GNU output for 0xFF before finalizing the
     expected string.
```

### IMPORTANT — -E does not test ^M$ (CRLF line endings)

```
[IMPORTANT] No test for -E with Windows CRLF input
Location: tests/utilities/cat_test.sh (absent)
Problem: GNU cat's man page states -E displays "$ or ^M$ at end of
         each line". The ^M$ case (carriage return before newline)
         is the CRLF path, which is a distinct code path. None of
         the -E tests use a file with \r\n line endings.
Fix: Add:
       local crlf_file=$(create_temp_file $'line1\r\nline2\r\n')
       test_command_output_exact "cat -E CRLF" \
           $'line1^M$\nline2^M$\n' "$binary" -E "$crlf_file"
```

### SUGGESTION — "cat -n multiple files" expected value is malformed

```
[SUGGESTION] Line 142 expected string is missing newlines
Location: tests/utilities/cat_test.sh:142
Problem: The expected value is:
           $'     1\tA     2\tB     3\tC'
         The files A, B, C contain single characters with no newlines.
         GNU cat -n numbers output lines; when there are no newlines,
         all three files concatenate into one line and only line 1 is
         numbered. The expected string above implies three separate
         numbered lines with no newline separator between them, which
         is not how GNU cat behaves. If the files truly have no
         trailing newlines, GNU cat -n would output:
           "     1\tABC"
         because it numbers lines, and no newline means no new line.
         This test may be asserting incorrect GNU behavior or may be
         passing by accident because test_command_output strips
         trailing newlines.
Fix: Verify against GNU cat with the exact same input. If files
     without newlines should each be on their own numbered line,
     document why. Otherwise correct the expected value.
```

### SUGGESTION — "cat -s only blanks" uses printf escape that is
                  ambiguous

```
[SUGGESTION] printf '\n\n\n\n\n' pipe behavior depends on squeeze
             semantics
Location: tests/utilities/cat_test.sh:93
Problem: The test pipes five newlines through cat -s and expects a
         single newline ($'\n'). GNU cat -s squeezes *consecutive*
         blank lines: runs of more than one blank line are replaced
         by one. Five consecutive blank lines (no content lines)
         should produce one blank line. The expected value $'\n'
         (one newline character) is correct. However,
         test_command_output_exact is used here (good), but the
         expected string is $'\n' which is a single newline. Since
         bash command substitution in test_command_output would strip
         the trailing newline, the use of test_command_output_exact
         is the right choice. This is fine — just noting it is
         correct and should stay as test_command_output_exact.
Fix: No change needed; this test is correctly implemented.
```

### SUGGESTION — "cat multiple stdin refs" semantic is underspecified

```
[SUGGESTION] Line 152: cat - - - behavior is implementation-defined
             once stdin is drained
Location: tests/utilities/cat_test.sh:152
Problem: The test pipes "echo 'test'" through "cat - - -" and
         expects "test". After the first - drains stdin, the second
         and third - attempt to read a closed/EOF stdin. GNU cat
         treats subsequent reads from an exhausted stdin as zero
         bytes. The test relies on this behavior without documenting
         it. The expected output "test" is correct for GNU, but a
         comment would help.
Fix: Add inline comment:
       # GNU: stdin is read once; subsequent - refs on drained stdin
       # yield empty; total output is the single echo line.
```

---

## Flag Coverage Matrix

| Flag              | Tier   | Has test | Test type        | Adequate |
|-------------------|--------|----------|------------------|----------|
| -b / --number-nonblank | MUST | yes | output verify | yes |
| -e                | MUST   | yes      | pattern only     | weak |
| -n / --number     | MUST   | yes      | output verify    | yes |
| -s / --squeeze-blank | MUST | yes   | output verify    | yes |
| -t                | MUST   | yes      | pattern only     | weak |
| -u                | MUST   | yes      | output verify    | yes |
| -v / --show-nonprinting | MUST | yes | pattern only  | weak (no M-) |
| -A / --show-all   | SHOULD | yes      | pattern only     | weak |
| -E / --show-ends  | SHOULD | yes      | output verify    | structurally flawed (see above) |
| -l                | SHOULD | no       | absent           | missing |
| -T / --show-tabs  | SHOULD | yes      | output verify    | yes |

---

## Strengths

- Stdin filter behavior is explicitly tested: no-args, `-` arg,
  file-then-stdin, stdin-then-file, multiple `-` references.
- Multi-file concatenation order is tested in both directions.
- All long-option aliases are verified with output checks.
- Error paths (non-existent file, directory, permission denied) are
  tested with `test_command_fails`.
- Binary file passthrough is tested.
- The `-s` tests cover edge cases: no blanks, only blanks, blanks
  with content.
- The `test_command_output_exact` helper is used where trailing
  newline precision matters (line 93).
- Flag combination tests exist for -ns, -bs, -ET, -n -b conflict.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -E tests use test_command_output, silently dropping
               trailing '$' — use test_command_output_exact
               — tests/utilities/cat_test.sh:67,68,102,166
2. [IMPORTANT] -v M- notation for high bytes (0x80-0xFF) untested
               — tests/utilities/cat_test.sh:74-75
3. [IMPORTANT] -E CRLF (^M$) case has no test
               — tests/utilities/cat_test.sh (absent)
4. [IMPORTANT] -l flag (SHOULD) has zero tests
               — tests/utilities/cat_test.sh (absent)
5. [SUGGESTION] "cat -n multiple files" expected value may be wrong
                — tests/utilities/cat_test.sh:142
```

REVIEW COMPLETE - NEEDS_FIXES
