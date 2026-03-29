# Integration Test Audit: test (and [)

**Date**: 2026-03-28
**Test file**: tests/utilities/test_test.sh
**Flags spec**: docs/specs/test-flags.md
**Test run**: 137 tests, 137 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 137 tests pass. The suite has broad coverage of string
comparisons, numeric comparisons, logical operators, and
common file tests. However, 12 MUST-tier file-type primaries
from the spec are untested (-b, -g, -h, -k, -p, -S, -t, -u,
-G, -O) or tested only via or-true guards that mask failures
(-c). String comparison operators `<` and `>` (MUST tier) are
fully absent. File comparison operators `-nt` and `-ot` (MUST
tier) are absent. Several error-condition tests use `|| true`
which turns failures into silently-ignored passes.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| test binary | binary exists | Weak |
| [ binary | binary exists | Weak |
| test --help | exit code 0 | Strong |
| test --version | exit code 0 | Strong |
| test string equality (true) | exit code 0 | Strong |
| test string equality (false) | exit code 1 | Strong |
| test string inequality (true) | exit code 0 | Strong |
| test string inequality (false) | exit code 1 | Strong |
| test -n non-empty string | exit code 0 | Strong |
| test -n empty string | exit code 1 | Strong |
| test -z empty string | exit code 0 | Strong |
| test -z non-empty string | exit code 1 | Strong |
| test string exists | exit code 0 | Strong |
| test empty string exists | exit code 1 | Strong |
| test -eq equal numbers | exit code 0 | Strong |
| test -eq unequal numbers | exit code 1 | Strong |
| test -ne unequal numbers | exit code 0 | Strong |
| test -ne equal numbers | exit code 1 | Strong |
| test -lt less than | exit code 0 | Strong |
| test -lt not less than | exit code 1 | Strong |
| test -le less than or equal (less) | exit code 0 | Strong |
| test -le less than or equal (equal) | exit code 0 | Strong |
| test -le not less than or equal | exit code 1 | Strong |
| test -gt greater than | exit code 0 | Strong |
| test -gt not greater than | exit code 1 | Strong |
| test -ge greater than or equal (greater) | exit code 0 | Strong |
| test -ge greater than or equal (equal) | exit code 0 | Strong |
| test -ge not greater than or equal | exit code 1 | Strong |
| test zero equality | exit code 0 | Strong |
| test negative numbers | exit code 0 | Strong |
| test negative and positive | exit code 0 | Strong |
| test -e existing file | exit code 0 | Strong |
| test -e nonexistent file | exit code 1 | Strong |
| test -e directory | exit code 0 | Strong |
| test -f regular file | exit code 0 | Strong |
| test -f directory (false) | exit code 1 | Strong |
| test -f nonexistent | exit code 1 | Strong |
| test -d directory | exit code 0 | Strong |
| test -d regular file (false) | exit code 1 | Strong |
| test -d nonexistent | exit code 1 | Strong |
| test -r readable file | exit code 0 | Strong |
| test -w writable file | exit code 0 | Strong |
| test -x executable file | exit code 0 | Strong |
| test -x non-executable file | exit code 1 | Strong |
| test -s non-empty file | exit code 0 | Strong |
| test -s empty file | exit code 1 | Strong |
| test -s nonexistent file | exit code 1 | Strong |
| test /dev/null character special | exit code 0 OR true | Weak |
| test regular file not character special | exit code 1 | Strong |
| test -a both true | exit code 0 | Strong |
| test -a first false | exit code 1 | Strong |
| test -a second false | exit code 1 | Strong |
| test -a both false | exit code 1 | Strong |
| test -o both true | exit code 0 | Strong |
| test -o first true second false | exit code 0 | Strong |
| test -o first false second true | exit code 0 | Strong |
| test -o both false | exit code 1 | Strong |
| test ! true expression | exit code 1 | Strong |
| test ! false expression | exit code 0 | Strong |
| test ! file exists | exit code 1 | Strong |
| test ! file not exists | exit code 0 | Strong |
| test parentheses grouping 1 | exit code 0 | Strong |
| test parentheses grouping 2 | exit code 1 | Strong |
| test parentheses with negation | exit code 0 | Strong |
| test file and string | exit code 0 | Strong |
| test file or nonexistent | exit code 0 | Strong |
| test numeric and file | exit code 0 | Strong |
| [ string equality ] | exit code 0 | Strong |
| [ string inequality ] | exit code 0 | Strong |
| [ file test ] | exit code 0 | Strong |
| [ numeric test ] | exit code 0 | Strong |
| [ logical and ] | exit code 0 | Strong |
| [ logical or ] | exit code 0 | Strong |
| [ logical not ] | exit code 0 | Strong |
| [ complex expression ] | exit code 0 | Strong |
| test no arguments | exit code 1 | Strong |
| test invalid operator | exit code 2 OR true | Weak |
| test missing operand for -eq | exit code 2 OR true | Weak |
| test missing file for -f | exit code 2 OR true | Weak |
| test non-numeric comparison | exit code 2 OR true | Weak |
| test non-numeric both sides | exit code 2 OR true | Weak |
| [ without closing bracket | exit code 2 OR true | Weak |
| [ with wrong closing | exit code 2 OR true | Weak |
| test /dev/null exists | exit code 0 | Strong |
| test /dev/null is character special | exit code 0 OR true | Weak |
| test /tmp is directory | exit code 0 | Strong |
| test -L symbolic link | exit code 0 (conditional) | Strong |
| test -L regular file | exit code 1 (conditional) | Strong |
| test precedence -o -a | exit code 0 | Strong |
| test precedence with parens | exit code 1 | Strong |
| test double negation | exit code 0 | Strong |
| test double negation false | exit code 1 | Strong |
| test empty string equality | exit code 0 | Strong |
| test empty vs non-empty | exit code 1 | Strong |
| test numeric strings with = | exit code 0 | Strong |
| test numeric strings with -eq | exit code 0 | Strong |
| test different numeric strings | exit code 1 | Strong |
| test strings with spaces | exit code 0 | Strong |
| test strings with quotes | exit code 0 | Strong |
| test strings with backslashes | exit code 0 | Strong |
| test large numbers | exit code 0 | Strong |
| test leading zeros | exit code 0 | Strong |
| test octal interpretation | exit code 0 OR true | Weak |
| test floating point (should fail) | exit code 2 OR true | Weak |
| POSIX: * (12 tests) | exit code | Strong (duplicate of above) |
| test --help flag | exit code 0 OR true | Weak |
| test --version flag | exit code 0 OR true | Weak |
| [ treats --help as expression | exit code 0 | Strong |
| test very long string | exit code 0 | Strong |
| test many parentheses | exit code 0 | Strong |
| test and [ consistency | manual check | Strong |
| error handling consistency | manual check | Strong |
| test file1 -ef file1 same file | exit code 0 | Strong |
| test file1 -ef file2 different files | exit code 1 | Strong |
| test -o left-to-right eval | exit code 0 | Strong |
| test -a left-to-right eval | exit code 1 | Strong |

---

## Coverage Gaps

### MUST-tier primaries with no test

| Primary | Description | Gap |
|---------|-------------|-----|
| -b | Block special file | No test at all |
| -g | Set-group-ID flag set | No test at all |
| -h | Symbolic link (legacy alias for -L) | No test at all |
| -k | Sticky bit set | No test at all |
| -p | Named pipe (FIFO) | No test at all |
| -S | Socket exists | No test at all |
| -t | File descriptor open on terminal | No test at all |
| -u | Set-user-ID flag set | No test at all |
| -G | Owned by effective GID | No test at all |
| -O | Owned by effective UID | No test at all |

### MUST-tier operators with no test

| Operator | Description | Gap |
|----------|-------------|-----|
| `<` | String less-than (lexicographic) | No test at all |
| `>` | String greater-than (lexicographic) | No test at all |
| `-nt` | File1 newer than file2 | No test at all |
| `-ot` | File1 older than file2 | No test at all |

---

## Issues

### [IMPORTANT] `|| true` silences all exit-code assertions in
error-condition tests

Location: tests/utilities/test_test.sh:157-168

Problem: Six error-condition tests all use `|| true` at the
end. `test_command_exit_code` returns non-zero when the actual
exit differs from expected. The `|| true` converts any failure
to a pass, so these tests can never fail regardless of what
the binary emits. They provide zero protection against
regressions in error handling.

Affected tests:
- test invalid operator (line 157)
- test missing operand for -eq (line 160)
- test missing file for -f (line 161)
- test non-numeric comparison (line 164)
- test non-numeric both sides (line 165)
- [ without closing bracket (line 168)
- [ with wrong closing (line 169)

Fix: Remove `|| true`. The binary already passes when these
are run manually. The guards are unnecessary and make the
tests vacuous.

```bash
# Before (vacuous)
test_command_exit_code "test invalid operator" 2 \
    "$binary" "hello" -invalid "world" 2>/dev/null || true

# After (meaningful)
test_command_exit_code "test invalid operator" 2 \
    "$binary" "hello" -invalid "world" 2>/dev/null
```

---

### [IMPORTANT] 10 MUST-tier file primaries have zero tests

Location: tests/utilities/test_test.sh (absent)

Problem: The following primaries are MUST-tier in
docs/specs/test-flags.md and have no tests at all: `-b`,
`-g`, `-h`, `-k`, `-p`, `-S`, `-t`, `-u`, `-G`, `-O`.

For most of these, test cases are straightforward to
construct:
- `-h file`: Create a symlink, test `-h "$link"` (true) and
  `-h "$test_file"` (false). Unlike `-L`, `-h` is the
  retained legacy alias; both should resolve the same.
- `-p file`: `mkfifo` a pipe, test `-p "$pipe"` (true) and
  `-p "$regular"` (false).
- `-S file`: Sockets require a running process but can be
  created with `python3 -c` or skipped with a conditional.
- `-t fd`: `test -t 0` should be 1 (false) in a non-terminal
  test; pipe stdin and verify.
- `-u`/`-g`/`-k`: `chmod u+s`/`g+s`/`+t` on a temp file,
  then test the flag.
- `-G`/`-O`: The current process's effective GID/UID matches
  files it creates in TEMP_DIR; test both true and false
  cases.

Fix: Add behavioral tests for each. The `-b` (block device)
primary is the only one reasonably skipped on most CI
environments (no block device creation without root); it
should be marked as platform-conditional rather than omitted.

---

### [IMPORTANT] String comparison operators `<` and `>` have
no tests

Location: tests/utilities/test_test.sh (absent)

Problem: `<` and `>` are MUST-tier per docs/specs/test-flags.md
(present in macOS, OpenBSD, and our implementation). There
are no tests for either the true or false case, nor for the
`[` form. These operators require shell quoting (`\<`, `\>`)
to avoid shell redirection — a known source of implementation
bugs.

Fix: Add tests covering both operators in both true and
false cases, and in the `[` form:

```bash
test_command_exit_code "test < string less-than (true)" 0 \
    "$binary" "apple" \< "banana"
test_command_exit_code "test < string less-than (false)" 1 \
    "$binary" "banana" \< "apple"
test_command_exit_code "test > string greater-than (true)" 0 \
    "$binary" "banana" \> "apple"
test_command_exit_code "test > string greater-than (false)" 1 \
    "$binary" "apple" \> "banana"
test_command_exit_code "[ < bracket form ]" 0 \
    "$bracket_binary" "apple" \< "banana" ]
```

---

### [IMPORTANT] File comparison operators `-nt` and `-ot` have
no tests

Location: tests/utilities/test_test.sh (absent)

Problem: `-nt` and `-ot` are MUST-tier per
docs/specs/test-flags.md and have no tests. The `-ef`
operator has a regression test (lines 310-315), but its
partner operators are entirely absent. Timestamp-based
comparisons are a distinct code path from inode comparison.

Fix: Add true and false cases for both, using `touch -t` or
sequential `create_temp_file` calls (mtime of later-created
file is newer):

```bash
local older=$(create_temp_file "older")
sleep 0.01  # or touch with explicit timestamps
local newer=$(create_temp_file "newer")
test_command_exit_code "test -nt newer than" 0 \
    "$binary" "$newer" -nt "$older"
test_command_exit_code "test -nt not newer than" 1 \
    "$binary" "$older" -nt "$newer"
test_command_exit_code "test -ot older than" 0 \
    "$binary" "$older" -ot "$newer"
test_command_exit_code "test -ot not older than" 1 \
    "$binary" "$newer" -ot "$older"
```

---

### [SUGGESTION] `-c` tests use `|| true` masking real
failures on Linux

Location: tests/utilities/test_test.sh:100, 175

Problem: Two tests for `-c /dev/null` use `|| true`. On all
Linux and macOS systems, `/dev/null` is a character special
device. The guard was presumably added for unusual
environments, but it makes the test vacuous everywhere.
Neither test will fail even if `-c` returns the wrong exit
code.

Fix: Remove `|| true` from both. If portability to oddball
environments is a concern, gate with a conditional:

```bash
if [[ -c /dev/null ]]; then
    test_command_exit_code "test -c /dev/null" 0 \
        "$binary" -c /dev/null
fi
```

---

### [SUGGESTION] `== ` (double-equals) string operator is
undocumented but present in macOS man page as compatibility
alias; not tested

Location: tests/utilities/test_test.sh (absent)

Problem: The macOS man page (docs/specs/test-macos.txt:159)
notes: "the = primary can be substituted with == with the
same meaning." This is an extension present in our spec
(`test-flags.md` lists no `==`, but the macos man page
explicitly calls it out). Whether we support it or reject it
with exit code 2 should be tested.

Fix: Add one test verifying the behavior — either that `==`
works as an alias or that it correctly returns exit code 2:

```bash
test_command_exit_code "test == (double-equals alias)" 0 \
    "$binary" "hello" == "hello" 2>/dev/null || \
test_command_exit_code "test == unsupported returns 2" 2 \
    "$binary" "hello" == "hello" 2>/dev/null
```

---

### [SUGGESTION] POSIX section duplicates earlier tests; adds
no new coverage

Location: tests/utilities/test_test.sh:225-251

Problem: The 18 "POSIX: ..." tests starting at line 226 are
exact behavioral duplicates of tests already present in
earlier sections (string equality, string inequality, -n,
-z, -eq, -ne, -lt, -gt, -e, -f, -d, -r, -w, -a, -o, !). No
new expressions are exercised. They inflate the test count
from ~119 to 137 without adding value, and they make coverage
gaps easier to miss.

Fix: Remove the POSIX section and reallocate the lines to
tests for the 14 untested MUST-tier primaries and operators
identified above.

---

## Coverage Summary

### MUST-tier primaries: 13 file type + 6 permission + 2 string = 21 total

| Primary | Tested | Quality |
|---------|--------|---------|
| -b | No | Missing |
| -c | Partial | `\|\| true` guard |
| -d | Yes | Strong |
| -e | Yes | Strong |
| -f | Yes | Strong |
| -g | No | Missing |
| -h | No | Missing |
| -k | No | Missing |
| -L | Yes | Strong (conditional) |
| -p | No | Missing |
| -S | No | Missing |
| -t | No | Missing |
| -G | No | Missing |
| -O | No | Missing |
| -r | Yes | Strong |
| -s | Yes | Strong |
| -u | No | Missing |
| -w | Yes | Strong |
| -x | Yes | Strong |
| -n | Yes | Strong |
| -z | Yes | Strong |

### MUST-tier operators

| Operator | Tested | Quality |
|----------|--------|---------|
| = | Yes | Strong |
| != | Yes | Strong |
| `<` | No | Missing |
| `>` | No | Missing |
| -eq | Yes | Strong |
| -ne | Yes | Strong |
| -gt | Yes | Strong |
| -ge | Yes | Strong |
| -lt | Yes | Strong |
| -le | Yes | Strong |
| -nt | No | Missing |
| -ot | No | Missing |
| -ef | Yes | Strong |
| ! | Yes | Strong |
| -a | Yes | Strong |
| -o | Yes | Strong |
| ( ) | Yes | Strong |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Remove `|| true` from 7 error-condition tests
   — test_test.sh:157-169
2. [IMPORTANT] Add tests for 10 untested MUST-tier file
   primaries (-b, -g, -h, -k, -p, -S, -t, -u, -G, -O)
   — test_test.sh (absent)
3. [IMPORTANT] Add tests for string < and > operators
   — test_test.sh (absent)
4. [IMPORTANT] Add tests for -nt and -ot file comparison
   operators — test_test.sh (absent)
5. [SUGGESTION] Remove `|| true` from -c /dev/null tests
   — test_test.sh:100, 175
6. [SUGGESTION] Add test for == double-equals alias behavior
   — test_test.sh (absent)
7. [SUGGESTION] Remove duplicate POSIX section (18 tests)
   — test_test.sh:225-251
```

REVIEW COMPLETE - NEEDS_FIXES
