# basename Integration Test Audit

**Date:** 2026-03-28
**Source:** `tests/utilities/basename_test.sh`
**Run result:** 78/78 pass
**Assessment:** NEEDS_FIXES

## Test Coverage Summary

Tests are grouped into sections:

| Section | Count | Quality |
|---|---|---|
| Basic infrastructure | 4 | Good |
| POSIX core functionality | 12 | CRITICAL issue |
| Suffix handling | 7 | Good |
| GNU: -a flag | 5 | Good |
| GNU: -s flag | 4 | Good |
| GNU: -z flag | 3 | IMPORTANT issue |
| Flag combinations | 4 | Good |
| Error conditions | 5 | IMPORTANT issue |
| POSIX compliance verification | 6 | IMPORTANT issue |
| Complex path cases | 5 | Good |
| Edge cases and boundaries | 6 | Good |
| Platform compatibility | 3 | Good |
| Performance scenarios | 3 | Good |
| Help and version | 2 | Good |

## Issues

---

```
[CRITICAL] "POSIX: empty string becomes dot" asserts wrong GNU behavior
Location: tests/utilities/basename_test.sh:40
Problem: test_command_output "POSIX: empty string becomes dot" "." "$binary" ""
         GNU coreutils basename outputs an empty line (empty string + newline)
         for `basename ""`.  This test asserts "." and currently passes
         because the implementation also returns ".".  Both the
         implementation and the test encode the wrong value.  The test name
         says "POSIX" but POSIX marks the behavior implementation-defined;
         the header says GNU is the primary reference.
         Confirmed: `basename "" | od -c` → `0000000 \n 0000001`
Fix: Change the expected value to "" (empty string):
     test_command_output "GNU: empty string" "" "$binary" ""
     The implementation must also be fixed (see code audit).
```

---

```
[IMPORTANT] -z output tests do not actually verify NUL termination via
            test_command_output; the one robust NUL test uses cmp but only
            for the single-file case
Location: tests/utilities/basename_test.sh:99
Problem: test_command_exit_code "GNU: --zero flag exists" 0 "$binary" --zero "test"
         Only checks exit code.  The two robust cmp-based NUL tests (lines
         83-96) cover single file and -az, which is good.  But --zero long
         form is only verified as exit-code 0 — actual NUL byte is not
         confirmed.
Fix: Add a cmp test for --zero long form:
     "$binary" --zero "test/file" > "$temp_out_long_zero"
     if printf "file\0" | cmp -s - "$temp_out_long_zero"; then
         print_test_result "GNU: --zero long form NUL terminator" "PASS"
     else
         print_test_result "GNU: --zero long form NUL terminator" "FAIL" \
             "Expected NUL terminator"
     fi
```

---

```
[IMPORTANT] "POSIX: error exit code" test is masked with || true
Location: tests/utilities/basename_test.sh:152
Problem: test_command_exit_code "POSIX: error exit code" 2 "$binary" 2>/dev/null || true
         The trailing || true means even if test_command_exit_code returns
         non-zero (test FAIL), the overall script continues without counting
         a failure.  The test can never produce a FAIL result.
Fix: Remove the || true:
     test_command_exit_code "POSIX: error exit code" 2 "$binary" 2>/dev/null
     Note: test_command_exit_code passes "$binary" 2>/dev/null as the command,
     but 2>/dev/null appears after "$binary" — it redirects the shell's fd 2
     inside run_command.  This is fine; what is broken is the || true.
```

---

```
[IMPORTANT] No test for -s with --suffix= using equals syntax that
            verifies NUL terminator for -z combined with --suffix=
Location: tests/utilities/basename_test.sh
Problem: test_command_output "GNU: --suffix long form" ... tests
         --suffix=".txt" but the -sz cmp test at line 115 uses short -s -z
         flags.  There is no behavioral test for --suffix= combined with
         --zero.
Fix: Add:
     "$binary" --suffix=".txt" --zero "hello.txt" "world.txt" > "$temp_out"
     if printf "hello\0world\0" | cmp -s - "$temp_out"; then
         print_test_result "GNU: --suffix= --zero combination" "PASS"
     else
         print_test_result "GNU: --suffix= --zero combination" "FAIL" ...
     fi
```

---

```
[SUGGESTION] Comment on line 123 says "combined short flags not supported
             yet" but -az is tested and passing at line 91
Location: tests/utilities/basename_test.sh:123
Problem: The comment is stale/misleading. -az does work.  The comment
         refers to -sz (treating z as the suffix value), which is
         documented as intentional.  The comment should be updated or
         removed to avoid confusion.
Fix: Replace the comment block (lines 122-127) with:
     # Note: -sz is not a combined flag — argparse treats 'z' as the
     # suffix value for -s. Use separate -s SUFFIX -z flags instead.
```

---

```
[SUGGESTION] No test for -a with zero paths (edge case: -a but no
             positionals)
Location: tests/utilities/basename_test.sh
Problem: In GNU basename, `basename -a` with no paths should print
         "missing operand" and exit 2 (same as no args at all).  No test
         covers this.
Fix: Add:
     test_command_fails "error: -a with no paths" "$binary" -a
```

## Summary

- CRITICAL: 1 (empty-string expected value wrong per GNU primary reference)
- IMPORTANT: 3
- SUGGESTION: 2

All 78 tests pass. The suite is well structured and covers the main
behavioral flags. The empty-string issue and the masked exit-code test are
the most important fixes.

**REVIEW COMPLETE — NEEDS_FIXES**

Fix Order:
1. [CRITICAL] "POSIX: empty string becomes dot" wrong expected value — line 40
2. [IMPORTANT] "POSIX: error exit code" masked with || true — line 152
3. [IMPORTANT] --zero long form not verified for NUL byte — line 99
4. [IMPORTANT] --suffix= --zero combination has no NUL-verified test
5. [SUGGESTION] Stale comment about combined flags — line 123
6. [SUGGESTION] No test for -a with no positionals — (missing)
