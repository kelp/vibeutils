---
date: 2026-03-28
utility: tac
audit_type: integration-tests
status: NEEDS_FIXES
tests_counted: 25
---

# tac Integration Test Audit

## Summary

25 integration tests, all passing. The suite covers basic line
reversal, file input, custom separators, the `--before` flag,
error conditions, edge cases, and exit codes. Core happy-path
behavior is well covered. The `-b` flag is tested for one
case only, and a production bug (`-b` ignored with multi-byte
separators) is not detected. The `-` stdin alias, empty
separator, and error message content are untested.

---

## Issues

```
[CRITICAL] -b with multi-byte separator is broken and untested
Location: tests/utilities/tac_test.sh (no test exists)
Problem: The integration suite tests -b only with the default
  newline separator (the "tac -b basic" case). The production
  code silently ignores -b when -s uses a multi-byte string
  (reverseByStringSeparator passes sep_byte=0 which disables
  the before-mode branch in writeRecordsReversed).
  GNU: printf 'one<>two<>three<>' | tac -s '<>' -b
  produces: <><>three<>twoone
  Ours produces: three<>two<>one<> (no change from no -b)
  No integration test detects this divergence.
Fix: Add a test:
  test_command_output "tac -b with multi-byte sep" \
    "<><>three<>twoone" \
    bash -c "printf 'one<>two<>three<>' | '$binary' -b -s '<>'"
  This will fail until the code bug is fixed, confirming the
  red-green cycle.
```

```
[IMPORTANT] -b with single-byte separator: only one case tested
Location: tests/utilities/tac_test.sh:62
Problem: The single -b test uses input with a trailing newline
  ("tac -b basic"). The behavior of -b with no trailing newline
  is not tested. GNU and our implementation produce different
  output for 'a\nb\nc' with -b (GNU: '\nc\nba', ours: 'c\nb\na').
  This divergence is undetected by the integration suite.
Fix: Add a test:
  test_command_output_exact "tac -b no trailing newline" \
    $'\nc\nba' \
    bash -c "printf 'a\nb\nc' | '$binary' -b"
  Verify the expected value against GNU first.
```

```
[IMPORTANT] "-" stdin argument has no integration test
Location: tests/utilities/tac_test.sh (no test exists)
Problem: When "-" is passed as a file argument, tac reads stdin.
  The code path (src/tac.zig:111) is separate from the no-args
  stdin path. No integration test exercises this.
Fix: Add:
  test_command_output "tac dash reads stdin" $'c\nb\na' \
    bash -c "printf 'a\nb\nc\n' | '$binary' -"
```

```
[IMPORTANT] Error message content never asserted
Location: tests/utilities/tac_test.sh:67-74
Problem: All four error-condition tests (invalid flag, invalid
  long flag, nonexistent file, -r unsupported) only check the
  exit code. The stderr message content is silently discarded
  with 2>/dev/null. A regression that changes the error text
  (e.g., from "unrecognized option" to nothing) would be
  invisible.
Fix: Remove the 2>/dev/null redirects and use
  test_command_stderr_contains to assert key error strings:
  - "unrecognized option" for unknown flags
  - "not supported" or similar for -r
  - the file path appears in the nonexistent-file error
```

```
[SUGGESTION] Empty separator (-s '') not tested
Location: tests/utilities/tac_test.sh (no test exists)
Problem: GNU tac -s '' uses NUL as the separator. The code
  has a branch for this (separator.len == 0). No integration
  test exercises it, so the NUL-separator path is fully dark.
Fix: Add a test using NUL-delimited input and verify the
  reversed output.
```

```
[SUGGESTION] -b tested with only one input shape
Location: tests/utilities/tac_test.sh:62
Problem: The -b test uses three lines with a trailing newline.
  Additional shapes worth testing: single line (no reversal
  needed), two lines, and the interaction of -b with -s.
Fix: Add "tac -b single line" and "tac -b with -s colon"
  test cases.
```

```
[SUGGESTION] Large-file test uses indirect checks only
Location: tests/utilities/tac_test.sh:91-106
Problem: The large-file test pipes tac output through head/tail
  to check only the first and last lines. It does not verify
  that the ordering of all 100 lines is correct. A bug that
  scrambles middle lines would pass.
Fix: Either check the full output with diff against a known-
  reversed sequence, or at minimum add a check that line 50
  appears in the correct position.
```

---

## Flag Coverage Matrix

| Flag | Tier   | Integration test | Behavioral verification |
|------|--------|-----------------|------------------------|
| -b   | SHOULD | partial (one case, trailing \n only) | weak — bug undetected |
| -r   | SHOULD | yes (unsupported) | exit code only |
| -s single-byte | SHOULD | yes | yes |
| -s multi-byte | SHOULD | yes | yes (but -b combo missing) |
| -b + -s multi-byte | n/a | **no** | **no** |
| -s ''  | n/a  | **no** | none |
| "-" arg | n/a | **no** | none |
| error messages | n/a | **no** | only exit codes |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Add -b + multi-byte sep test (exposes production bug)
   — tests/utilities/tac_test.sh
2. [IMPORTANT] Add -b no-trailing-newline test vs GNU behavior
   — tests/utilities/tac_test.sh
3. [IMPORTANT] Add "-" stdin argument test
   — tests/utilities/tac_test.sh
4. [IMPORTANT] Assert error message content, remove 2>/dev/null
   — tests/utilities/tac_test.sh:67-74
5. [SUGGESTION] Add -s '' NUL-separator test
   — tests/utilities/tac_test.sh
6. [SUGGESTION] Add additional -b shapes (single line, -b + -s)
   — tests/utilities/tac_test.sh
7. [SUGGESTION] Strengthen large-file test to check ordering
   — tests/utilities/tac_test.sh:91
```

REVIEW COMPLETE - NEEDS_FIXES
