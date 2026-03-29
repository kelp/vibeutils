# Integration Test Audit: cut

**Date**: 2026-03-28
**Test file**: tests/utilities/cut_test.sh
**Run result**: 64 tests, 64 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 64 tests pass. Core MUST-tier flag behavior is well
covered and stdin piping is genuinely exercised. However,
the two SHOULD-tier flags `-w` (whitespace delimiter) and
`-z` (NUL-terminated lines) have zero integration tests.
The `-n` multi-byte tests use a custom run_command harness
that does not call `print_test_result` via the standard
path, making the count inflated by one meta-count test
rather than extra coverage. Three error-condition tests
redirect stderr before passing to the binary, hiding
whether the binary itself emits the error (see detail
below). The `--output-delimiter` test for field 6 embeds
a double-slash assumption that is fragile.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|-------------------|---------|
| cut binary | binary check | STRONG |
| cut --help / --version | exit-code + content | STRONG |
| cut -b 1 | stdout content | STRONG |
| cut -b 1-3 | stdout content | STRONG |
| cut -b 1,3,5 | stdout content | STRONG |
| cut -b 3- | stdout content | STRONG |
| cut -b -3 | stdout content | STRONG |
| cut -b 1-3 file | stdout content | STRONG |
| cut --bytes=2-4 | stdout content | STRONG |
| cut -c 1 | stdout content | STRONG |
| cut -c 2-4 | stdout content | STRONG |
| cut -c 1,3,5 | stdout content | STRONG |
| cut --characters=1-3 | stdout content | STRONG |
| cut -f 1 tab | stdout content | STRONG |
| cut -f 1,3 tab | stdout content | STRONG |
| cut -f 2-3 tab | stdout content | STRONG |
| cut -f 2- tab | stdout content | STRONG |
| cut --fields=1 tab | stdout content | STRONG |
| cut -d: -f1 passwd | stdout content | STRONG |
| cut -d: -f3 passwd | stdout content | STRONG |
| cut -d, -f1 csv | stdout content | STRONG |
| cut -d, -f1,3 csv | stdout content | STRONG |
| cut --delimiter=: --fields=1 | stdout content | STRONG |
| cut -f1 mixed (no -s) | stdout content | STRONG |
| cut -sf1 mixed | stdout content | STRONG |
| cut --only-delimited -f1 | stdout content | STRONG |
| cut --complement -b 2,4 | stdout content | STRONG |
| cut --complement -f2 tab | stdout content | STRONG |
| cut --output-delimiter=, -f1,3 tab | stdout content | STRONG |
| cut -d: --output-delimiter=/ -f1,6 passwd | stdout content | FRAGILE |
| cut -b 3-100 short | stdout content | STRONG |
| cut -b 100 short | stdout content (empty) | STRONG |
| cut -b 1-3,2-4 | stdout content | STRONG |
| cut -b 1-2,3-4 | stdout content | STRONG |
| cut -b 3,1,5 | stdout content | STRONG |
| cut stdin -b 1-3 | stdout content via pipe | STRONG |
| cut stdin multiline | stdout content via pipe | STRONG |
| cut empty stdin | stdout empty via pipe | STRONG |
| cut stdin dash | stdout content via explicit - | STRONG |
| cut -n -b 1 suppresses partial multi-byte | stdout empty | STRONG |
| cut -n -b 1-2 suppresses partial 3-byte char | stdout empty | STRONG |
| cut -n -b 1-3 outputs full multi-byte char | stdout content | STRONG |
| cut -b 1 without -n outputs single raw byte | byte-count check | STRONG |
| cut -n -b 1-3 ASCII | stdout content | STRONG |
| cut -n -b 4-6 after multi-byte char | stdout content | STRONG |
| cut -n suppresses / no-n outputs raw byte | contrast check | STRONG |
| cut no mode | exit-code 2 | WEAK |
| cut -b and -f | exit-code 2 | WEAK |
| cut -s without -f | exit-code 2 | WEAK |
| cut -d without -f | exit-code 2 | WEAK |
| cut invalid range 0 | exit-code 2 | WEAK |
| cut invalid flag | exit-code 2 | WEAK |
| cut nonexistent file | exit-code 1 | WEAK |
| cut POSIX success | exit-code 0 | WEAK |
| cut POSIX misuse | exit-code 2 | WEAK |
| cut POSIX default delim | stdout content | STRONG |
| cut POSIX no delim passthrough | stdout content | STRONG |
| cut multiple files | stdout content | STRONG |
| cut comprehensive test count | meta-count >= 40 | META |
| cut nonexistent file exits non-zero | exit-code != 0 | WEAK |
| cut nonexistent file prints error | stderr non-empty | STRONG |
| cut error mentions filename | stderr contains path | STRONG |
| cut --version contains vibeutils | stdout content | STRONG |

---

## Coverage Gaps

### MUST-tier flags — all covered

All six POSIX/MUST flags (-b, -c, -d, -f, -n, -s) have
behavioral integration tests that verify stdout content.

### SHOULD-tier flags with zero tests

**`-w` (whitespace delimiter, macOS/SHOULD)**

There is no test that passes whitespace-separated input
and checks that consecutive spaces/tabs count as one
separator. The flag is listed as SHOULD in cut-flags.md
and is implemented (`yes` in the Ours column).

**`-z` / `--zero-terminated` (GNU/SHOULD)**

There is no test that feeds NUL-separated records and
checks that cut operates on NUL-delimited lines. The flag
is listed as SHOULD and implemented.

---

## Issues

### [IMPORTANT] `-w` flag has zero integration tests
Location: tests/utilities/cut_test.sh (missing section)
Problem: The whitespace-delimiter mode is entirely
untested. A regression in whitespace tokenisation
(consecutive spaces collapsing, tab+space mixing) would
not be caught.
Fix: Add a section that pipes `"one  two   three"` and
`$'one\t two\tthree'` through `cut -w -f 2` and verifies
the output is `"two"` in both cases.

### [IMPORTANT] `-z` flag has zero integration tests
Location: tests/utilities/cut_test.sh (missing section)
Problem: NUL-delimited input/output is untested. A
regression in NUL handling is invisible to the suite.
Fix: Add a test that pipes `printf 'a:b\0c:d'` through
`cut -z -d: -f1` and verifies output is `$'a\0c'`
(two NUL-terminated records).

### [IMPORTANT] Three error tests silently swallow stderr
Location: tests/utilities/cut_test.sh:226-241
Problem: The tests for "cut -b and -f", "cut -s without
-f", "cut -d without -f", and "cut invalid range 0" all
redirect stderr to /dev/null before the binary even runs
(the `2>/dev/null` is on the outer bash -c or binary
invocation). They only check exit code 2, not that a
diagnostic message is emitted. A silent failure with
exit 2 would pass.
Fix: Capture stderr and assert it is non-empty, following
the pattern used by "cut nonexistent file prints error"
at line 282.

### [SUGGESTION] Fragile --output-delimiter test
Location: tests/utilities/cut_test.sh:124
Problem: The expected value `$'root//root\nnobody//nonexistent'`
assumes field 6 of the passwd-format file begins with `/`.
This holds because the test fixture hardcodes `/root` and
`/nonexistent`, so the test is self-consistent. However
the double-slash (output-delimiter `/` between fields,
field value `/root`) makes the expected string visually
confusing and the comment above it is the only
explanation. A reader may mistake this for a bug.
Fix: Add an inline comment explaining that the `//` is
correct: one `/` from `--output-delimiter` plus one `/`
from the field value.

### [SUGGESTION] Meta-count test is not a coverage gate
Location: tests/utilities/cut_test.sh:264
Problem: `if [[ $TESTS_RUN -ge 40 ]]` passes as soon as
any 40 tests have run. Because TESTS_RUN is a global
shared across all utilities in a session, this check can
pass even if cut-specific coverage drops well below 40
tests. It also inflates the reported count by 1 without
adding signal.
Fix: Either remove the meta-count test or compare against
a local counter that is reset at the start of test_cut.

---

## Strengths

- Stdin piping is exercised properly with pipes, not just
  file arguments. Four dedicated stdin tests exist and all
  use `bash -c "... | '$binary' ..."` patterns.
- The `-n` multi-byte section is the most thorough in the
  entire test suite: seven cases including contrast,
  boundary, and ASCII fallback checks.
- Error diagnostics (stderr content, filename mention) are
  verified with run_command, not just exit code.
- Long-option equivalents (--bytes, --characters, --fields,
  --delimiter, --only-delimited) are all tested.
- `--complement` is tested for both `-b` and `-f` modes.
- Range edge cases (beyond-length, overlapping, unsorted)
  are all present.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Add -w behavioral tests — cut_test.sh (missing)
2. [IMPORTANT] Add -z behavioral tests — cut_test.sh (missing)
3. [IMPORTANT] Assert stderr non-empty in error-condition tests
               — cut_test.sh:226-241
4. [SUGGESTION] Add comment to --output-delimiter double-slash
               test — cut_test.sh:124
5. [SUGGESTION] Remove or fix meta-count gate — cut_test.sh:264
```

REVIEW COMPLETE - NEEDS_FIXES
