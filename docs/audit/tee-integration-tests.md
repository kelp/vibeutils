---
audit: tee integration tests
date: 2026-03-28
file: tests/utilities/tee_test.sh
result: NEEDS_FIXES
build: 87/87 pass
---

# tee Integration Test Audit

## Summary

87 integration tests, all pass. Happy-path coverage is
thorough: single and multiple files, append mode, multiline
input, large input, boundary conditions (empty, single char,
newline-only), filenames with spaces, subdirectory creation,
and stress tests. The test structure is solid.

Three categories of defects:

1. A broken guard in the "dash is stdout not file" test —
   the condition is always true so the test never actually
   validates the invariant it claims to test.

2. Dash-operand tests expect two stdout copies per `-` arg,
   which diverges from GNU coreutils 9.10 behavior (GNU
   produces one copy regardless of how many `-` args are
   given, because they share the same fd).

3. The `-i` and `-p` flag tests are happy-path only. `-i`
   never sends SIGINT; `-p` never creates a write-error
   condition. Binary data tests check exit code only. Error
   condition tests suppress stderr with `2>/dev/null`.

---

## Issues

```
[CRITICAL] "dash is stdout not file" guard is always true
Location: tests/utilities/tee_test.sh:81
Problem: After running `echo 'stdout_data' | tee -`, the
test checks whether a file named '-' was created:

  if [[ ! -f ./ ]]; then
      print_test_result "tee dash is stdout not file" "PASS"

The check is `! -f ./` (not a file named "./"). The current
working directory is always a directory, never a file, so
this condition is always true and the test always prints
PASS regardless of whether tee actually created a file
named '-'. The correct check is `! -f "./-"`.

Impact: If tee ever created a file named '-' instead of
writing to stdout, this test would not catch it.

Fix:
  if [[ ! -f "./-" ]]; then
      print_test_result "tee dash is stdout not file" "PASS"
  else
      print_test_result "tee dash is stdout not file" "FAIL" \
          "File named '-' was created"
      rm -f "./-"
  fi
```

```
[IMPORTANT] Dash-operand tests encode wrong GNU semantics
Location: tests/utilities/tee_test.sh:79, 89, 93, 255-256
Problem: GNU coreutils 9.10 tee treats '-' as a reference to
stdout's file descriptor. Since both the normal output and the
'-' write go to the same fd, only one copy appears in the
output:

  python3 -c "
  import subprocess
  r = subprocess.run(['tee', '-'], input=b'hello\n',
                    capture_output=True)
  print(r.stdout.count(b'\n'))   # 1, not 2
  r2 = subprocess.run(['tee', '-', '-'], input=b'hello\n',
                      capture_output=True)
  print(r2.stdout.count(b'\n'))  # 1, not 3
  "

The integration tests expect doubled (or tripled) output:

  Line 79:  expects $'stdout_data\nstdout_data' (2 copies)
  Line 89:  expects $'mixed_output\nmixed_output' (2 copies)
  Line 93:  expects $'dash_test\ndash_test\ndash_test' (3 copies)
  Line 255: expects $'hello\nhello' (2 copies, regression test)

These tests pass because the vibeutils binary matches the
tests — but both the tests and the binary are wrong relative
to GNU. These tests provide false confidence.

Fix: Confirm the intended behavior against the GNU coreutils
source (the reference per CLAUDE.md). If GNU behavior is
the target, fix the binary and update these four tests to
expect a single copy. If intentional divergence, document it
explicitly.
```

```
[IMPORTANT] -i tests are parse-only happy path
Location: tests/utilities/tee_test.sh:139-148
Problem: The four -i/-i-a tests verify that the flag is
accepted and that data flows through normally. They do not
verify that SIGINT is actually ignored during processing.
A broken -i implementation (one that parses but does not
call sigaction, or calls it with the wrong arguments) would
pass all four tests.

Fix: Add a test that sends SIGINT to the tee process while
it is reading stdin and verifies the process continues and
produces correct output. Example approach:
  # Start tee reading a slow fifo, send SIGINT, confirm output
  mkfifo /tmp/tee_fifo
  $binary -i /tmp/tee_out < /tmp/tee_fifo &
  TEE_PID=$!
  echo "before" > /tmp/tee_fifo
  kill -INT $TEE_PID
  echo "after" > /tmp/tee_fifo
  exec 3>/tmp/tee_fifo; exec 3>&-  # close to send EOF
  wait $TEE_PID
  grep -q "after" /tmp/tee_out || FAIL
```

```
[IMPORTANT] -p tests are parse-only happy path
Location: tests/utilities/tee_test.sh:153-162
Problem: The -p tests verify the flag is accepted and that
data flows through. None of them create a write-error
condition. Per the code audit (tee-code.md), -p has incorrect
semantics relative to GNU: without -p, vibeutils silently
swallows write errors (GNU always diagnoses non-pipe errors);
with -p, vibeutils prints a message but doesn't change pipe
exit behavior (GNU continues after stdout SIGPIPE). These
bugs are invisible because no test produces a write failure.

Fix: Add tests that exercise the actual -p behavior:
  # Test 1: write error is silent without -p
  echo "data" | $binary /dev/full 2>/tmp/errs
  [[ -z "$(cat /tmp/errs)" ]] && PASS "no-p silent on error"
  # Note: per code audit, this should actually FAIL (GNU
  # always diagnoses), confirming the bug.

  # Test 2: write error produces stderr output with -p
  echo "data" | $binary -p /dev/full 2>/tmp/errs
  grep -q "write error\|No space" /tmp/errs && PASS "-p diagnoses"
```

```
[IMPORTANT] Binary data test is exit-code-only
Location: tests/utilities/tee_test.sh:47-48
Problem: The binary data test sends bytes 0x00 0x01 0x02 0xFF
through tee but redirects stdout to /dev/null. It only checks
that tee exits 0 and that a file was created. It does not
verify that the file contains the correct binary content. A
tee that silently dropped null bytes would pass this test.

Fix:
  printf '\x00\x01\x02\xFF' | '$binary' '$test_file1' >/dev/null
  local file_size=$(wc -c < "$test_file1")
  [[ "$file_size" -eq 4 ]] && PASS "binary content preserved" \
      || FAIL "expected 4 bytes, got $file_size"
  # Or use xxd/od to verify exact byte values.
```

```
[IMPORTANT] Error condition tests suppress stderr
Location: tests/utilities/tee_test.sh:184-185, 191, 195
Problem: All four error condition tests use 2>/dev/null,
suppressing stderr. They verify exit codes but not error
message content:

  Line 184: tee invalid flag -x        2>/dev/null
  Line 185: tee invalid long flag      2>/dev/null
  Line 191: tee readonly directory     2>/dev/null
  Line 195: tee non-existent dir       2>/dev/null

A tee that exited with the right code but printed no message,
or printed the wrong message, would pass. Per the code audit,
error messages use @errorName() (Zig symbols) rather than
POSIX strerror strings.

Fix: Capture stderr and assert expected substrings. Example:
  local errs
  errs=$(echo 'fail' | '$binary' '$readonly_dir/x' 2>&1 >/dev/null)
  [[ "$errs" == *"Permission denied"* ]] && PASS || FAIL
```

---

## Coverage Gaps (SHOULD-level flags)

| Feature | Covered | Notes |
|---------|---------|-------|
| -a / --append | yes | behavioral, thorough |
| -i accept (happy path) | yes | not behavioral for SIGINT |
| -p accept (happy path) | yes | not behavioral for errors |
| - dash operand | yes | wrong expected value |
| no-files passthrough | yes | |
| binary data content | no | exit-code-only |
| SIGINT actually ignored | no | |
| Write error behavior | no | |
| SIGPIPE / pipe-exit | no | |
| stderr message content | no | all 4 error tests suppress stderr |

---

## Regression Test Note

The test at lines 253-256 is labeled "Regression test: echo
hello | tee - should output 'hello' twice". This comment is
incorrect: the documented regression being tested is the
vibeutils behavior (2 copies), not GNU behavior (1 copy).
If the implementation is corrected to match GNU, this
"regression test" becomes the bug test.

---

## Fix Order

1. [CRITICAL] Fix `! -f ./` guard to `! -f "./-"` —
   tests/utilities/tee_test.sh:81
2. [IMPORTANT] Resolve dash-operand expected value vs GNU —
   tee_test.sh:79, 89, 93, 255-256
3. [IMPORTANT] Add behavioral test for -p with write error
   condition — tee_test.sh
4. [IMPORTANT] Verify binary data file content, not just
   existence — tee_test.sh:47-48
5. [IMPORTANT] Capture and assert stderr in error tests —
   tee_test.sh:184-185, 191, 195
6. [IMPORTANT] Add SIGINT behavioral test for -i — tee_test.sh

REVIEW COMPLETE - NEEDS_FIXES
