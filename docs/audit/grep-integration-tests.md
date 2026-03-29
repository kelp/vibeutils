# Integration Test Audit: grep

**Date**: 2026-03-28
**Test file**: tests/utilities/grep_test.sh
**Flags spec**: docs/specs/grep-flags.md
**Test run**: 47 tests, 47 passed, 0 failed

## Executive Summary

PASS WITH ISSUES

All 47 tests pass. The test suite covers core POSIX flags
well with strong output-verifying tests. However, 14 MUST-tier
flags have no integration test at all, 6 SHOULD-tier flags
with behavioral impact are also untested, and several existing
tests use weak verification (pattern match on output substring
rather than exact match).

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| grep binary | binary exists | Weak |
| grep --help | exit code 0 | Weak |
| grep --version | exit code 0 | Weak |
| grep basic match | `test_command_output` exact | Strong |
| grep multiple matches | `test_command_output` exact | Strong |
| grep no match exit 1 | `test_command_exit_code` | Weak |
| grep empty input exit 1 | `test_command_exit_code` | Weak |
| grep -i case insensitive | `test_command_output` exact | Strong |
| grep --ignore-case | `test_command_output` exact | Strong |
| grep -v invert | `test_command_output` exact | Strong |
| grep -c count | `test_command_output` exact | Strong |
| grep -c no match | `test_command_output` exact | Strong |
| grep -n line number | `test_command_output` exact | Strong |
| grep -l files with matches | `run_command` + regex `=~` | Moderate |
| grep -L files without match | `run_command` + regex `=~` | Moderate |
| grep -E alternation | `test_command_output` exact | Strong |
| grep -E plus | `test_command_output` exact | Strong |
| grep -F literal dot | `test_command_output` exact | Strong |
| grep -F literal brackets | `test_command_output` exact | Strong |
| grep -o only matching | `test_command_output` exact | Strong |
| grep -q match exits 0 | `test_command_exit_code` | Weak |
| grep -q no match exits 1 | `test_command_exit_code` | Weak |
| grep -x whole line | `test_command_output` exact | Strong |
| grep -m 1 | `test_command_output` exact | Strong |
| grep -e multiple patterns | `test_command_output` exact | Strong |
| grep -f pattern file | `test_command_output` exact | Strong |
| grep -A1 after context | `test_command_output` exact | Strong |
| grep -B1 before context | `test_command_output` exact | Strong |
| grep -C1 context | `test_command_output` exact | Strong |
| grep -H with filename | `run_command` + regex `=~` | Moderate |
| grep -h no filename | `run_command` + regex `=~` | Moderate |
| grep -r recursive | `run_command` + regex `=~` | Moderate |
| grep --include=*.c | `run_command` + regex `=~` | Moderate |
| grep --exclude=*.o | `run_command` + regex `=~` | Moderate |
| grep --exclude-dir=.git | `run_command` + regex `=~` | Moderate |
| grep --color=always produces ANSI | `run_command` + regex `=~` | Moderate |
| grep --color=never no ANSI | `run_command` + negative `=~` | Moderate |
| grep no pattern exit 2 | `test_command_exit_code` | Weak |
| grep invalid option exit 2 | `test_command_exit_code` | Weak |
| grep nonexistent file exit 2 | `test_command_exit_code` | Weak |
| grep invalid regex exit 2 | `test_command_exit_code` | Weak |
| grep -- handles dash files | `test_command_output` exact | Strong |
| grep - means stdin | `test_command_output` exact | Strong |
| grep -ivn combined | `test_command_output` exact | Strong |
| grep multi-file shows filenames | `run_command` + regex `=~` | Moderate |
| grep -s suppresses errors | `run_command` + empty stderr check | Moderate |
| grep -f with data file (regression) | `test_command_output` exact | Strong |

---

## Weak Tests

### Exit-code-only tests that cannot detect a no-op flag

**grep -q match exits 0** and **grep -q no match exits 1**
(lines 97-98)

These verify only the exit code, not that output is
suppressed. A correct `-q` must produce zero stdout. The
test would pass even if the implementation printed all
matching lines while returning the right code.

Fix: add an output-verifying assertion that stdout is
empty when `-q` is active.

```bash
run_command cmd out err exit_code bash -c \
    "printf 'hello\n' | '$binary' --color=never -q hello"
if [[ $exit_code -eq 0 && -z "$out" ]]; then
    print_test_result "grep -q suppresses output" "PASS"
else
    print_test_result "grep -q suppresses output" "FAIL" \
        "exit=$exit_code out='$out'"
fi
```

**grep no match exit 1**, **grep empty input exit 1**
(lines 26-29)

Correct behavior, but these are pure exit-code checks. A
stub that always exits 1 would pass them. Acceptable as
supporting tests only when paired with positive-match
output tests (which do exist).

**Error condition tests** (lines 219-228)

All four error tests check only exit code 2. They do not
verify that an error message is written to stderr. A
silent crash returning 2 would pass. Low priority, but
worth noting.

---

## Missing Coverage

| Flag | Tier | Has Integration Test? | Strength |
|------|------|-----------------------|----------|
| -E | MUST | Yes | Strong |
| -F | MUST | Yes | Strong |
| -G | MUST | No | — |
| -H | MUST | Yes | Moderate |
| -I | MUST | No | — |
| -L | MUST | Yes | Moderate |
| -R | MUST | Yes (via -r) | Moderate |
| -U | MUST | No | — |
| -V | MUST | Weak (exit 0 only) | Weak |
| -a | MUST | No | — |
| -b | MUST | No | — |
| -c | MUST | Yes | Strong |
| -e | MUST | Yes | Strong |
| -f | MUST | Yes | Strong |
| -h | MUST | Yes | Moderate |
| -i | MUST | Yes | Strong |
| -l | MUST | Yes | Moderate |
| -m | MUST | Yes | Strong |
| -n | MUST | Yes | Strong |
| -o | MUST | Yes | Strong |
| -q | MUST | Yes (exit only) | Weak |
| -r | MUST | Yes | Moderate |
| -s | MUST | Yes | Moderate |
| -v | MUST | Yes | Strong |
| -w | MUST | No | — |
| -x | MUST | Yes | Strong |
| -Z | MUST | No | — |
| -z | SHOULD | No | — |
| -D | SHOULD | No | — |
| -d | SHOULD | No | — |
| -P | SHOULD | No | — |
| --label | SHOULD | No | — |
| --null | SHOULD | No | — |
| --binary-files | SHOULD | No | — |
| --line-buffered | SHOULD | No | — |
| --include | SHOULD | Yes | Moderate |
| --exclude | SHOULD | Yes | Moderate |
| --exclude-dir | SHOULD | Yes | Moderate |
| --include-dir | SHOULD | No | — |
| --color | SHOULD | Yes | Moderate |
| -J, -M, -O, -p, -S | SHOULD | No | — |
| -u, -X, -y | SHOULD | No | — |

### MUST flags with no output-verifying test

**-G (basic regexp)** — MUST tier, no test. The default
grep mode is BRE; `-G` forces it explicitly. No test
verifies BRE-specific syntax (e.g., `\+` is literal in
BRE, not a quantifier).

**-I (ignore binary files)** — MUST tier, no test.
Behavior: binary files produce no output and no error.
Without a test, a no-op or crash on binary input is
invisible.

**-U (binary search mode)** — MUST tier, no test. Should
search binary files without printing them.

**-a (treat as text)** — MUST tier, no test. With a
binary-content file, `-a` should force text output. No
test confirms this distinction from default behavior.

**-b (byte offset)** — MUST tier, no test. Should prefix
each matching line with its byte offset. No test confirms
the prefix format.

**-w (word regexp)** — MUST tier, no test. Critical
correctness gap: `-w` changes which lines match. For
example, `grep -w foo` should match `foo bar` but not
`foobar`. A missing test here means a broken `-w`
(e.g., treated as no-op) would never be caught.

**-Z (decompress)** — MUST tier, no test. Decompressed
file handling is out of scope for basic CI but the flag
should at minimum not crash when given a non-compressed
file or return a clear error.

### SHOULD flags with behavioral impact and no test

**--label** — Changes the stdin label in `-l`/`-L`/`-H`
output. Untested.

**--null** — Changes output field separator to NUL byte
instead of newline. Untested. Incorrect output format
would corrupt downstream pipelines silently.

**--binary-files=value** — Three distinct modes
(`binary`, `without-match`, `text`). Untested. Different
from `-I` and `-a`; each mode has different output.

**--line-buffered** — Affects buffering behavior. Hard to
test correctly but at minimum should not crash.

**-z (null-data)** — Treats NUL as line delimiter instead
of newline. Untested.

**-d (directories action)** — Controls behavior when a
directory is given as an argument (`read`, `skip`,
`recurse`). Currently untested. `-d recurse` is
equivalent to `-r` and could mask a broken `-r`.

---

## Expected Output Issues

### Context separator missing from multi-match context tests

The tests for `-A`, `-B`, and `-C` use single-match
inputs, so the `--` group separator between context
blocks is never exercised. With multiple non-adjacent
matches, GNU/BSD grep prints `--` between groups.
No test verifies this separator appears (or that it can
be suppressed).

### -n with multi-file input

The `-n` test uses stdin only (line 49). When grep reads
multiple files, line numbers reset per file. No test
verifies reset behavior.

### -c with multiple files

The `-c` test uses stdin (line 43). With multiple files,
grep prints `filename:count` per file. No test verifies
this format.

### -m interaction with context

`-m` stops after N matches. With `-A`, trailing context
lines after the last match should still print. This
edge case is untested.

---

## System Comparison

No explicit comparison against `/usr/bin/grep` output is
performed in the test suite. The tests use hard-coded
expected strings rather than comparing against system
grep. This is the correct approach for a clean-room
implementation, but it means behavioral drift from the
spec is only caught when a human notices a discrepancy.

Flags worth spot-checking against system grep manually:
- `-b` byte-offset format (colon separator, position of
  offset relative to filename prefix)
- Context separator `--` between non-adjacent match groups
- `-n` + `-H` combined output format (`file:lineno:text`)
- `-l` stdin label (`(standard input)` vs custom `--label`)

---

## Missing Test Scenarios

1. **Anchored patterns** — `^` and `$` anchors in BRE/ERE.
   Basic matching tests use literal strings only.

2. **Multiline pattern file** — `-f` with a pattern file
   containing blank lines (which match everything per spec).

3. **Binary file detection** — Feeding a file with NUL
   bytes to default grep should print "Binary file ...
   matches" (or suppress output per `-I`/`-a`).

4. **Symlink traversal** — `-r` vs `-R` behavior with
   symlinks (macOS spec distinguishes these: `-r` does not
   follow symlinks, `-S` follows all, `-O` follows only
   command-line symlinks).

5. **-n + -H combined format** — Should produce
   `filename:lineno:text`. No test covers this combination.

6. **-c + -l interaction** — Spec says `-n` is ignored
   when `-c`/`-L`/`-l`/`-q` is active. No test verifies
   suppression interactions.

7. **Empty pattern** — An empty string pattern should match
   every line. Untested.

8. **GREP_OPTIONS environment variable** — The macOS spec
   documents this env var. No test verifies it is honored
   or intentionally ignored.

9. **NUL-terminated output with --null** — With `-l
   --null`, filenames should be NUL-delimited. No test.

10. **stdin label with --label** — `grep -l --label=FOO`
    on stdin should print `FOO` instead of
    `(standard input)`. Untested.

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| G-01 | IMPORTANT | `-w` (word regexp) is MUST tier with no integration test; a no-op implementation passes undetected |
| G-02 | IMPORTANT | `-b` (byte offset) is MUST tier with no integration test; output format unverified |
| G-03 | IMPORTANT | `-G` (basic regexp) is MUST tier with no test; BRE-specific syntax unverified |
| G-04 | IMPORTANT | `-I` (ignore binary files) is MUST tier with no test |
| G-05 | IMPORTANT | `-a` (treat as text) is MUST tier with no test |
| G-06 | IMPORTANT | `-q` tests verify exit code only; stdout suppression not verified |
| G-07 | IMPORTANT | Context separator `--` between non-adjacent match groups is never tested |
| G-08 | IMPORTANT | `--null` is SHOULD tier; NUL-delimited output is completely untested |
| G-09 | IMPORTANT | `--binary-files` is SHOULD tier; all three modes are untested |
| G-10 | SUGGESTION | Error condition tests check exit code only; stderr message content not verified |
| G-11 | SUGGESTION | `-c` and `-n` tested only with stdin; multi-file format (`file:count`, line number reset) untested |
| G-12 | SUGGESTION | `-U` (binary mode) is MUST tier with no test |
| G-13 | SUGGESTION | `-Z` (decompress) is MUST tier with no test |
| G-14 | SUGGESTION | `--label` is SHOULD tier with no test |
| G-15 | SUGGESTION | `-d` (directories action) is SHOULD tier with no test |
| G-16 | SUGGESTION | Anchored patterns (`^`, `$`) have no test coverage |
| G-17 | SUGGESTION | Empty pattern (matches all lines) is not tested |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Add -w word-regexp behavioral test
   — tests/utilities/grep_test.sh (new test block)
2. [IMPORTANT] Add -b byte-offset output format test
   — tests/utilities/grep_test.sh (new test block)
3. [IMPORTANT] Add -G basic-regexp test with BRE syntax
   — tests/utilities/grep_test.sh (new test block)
4. [IMPORTANT] Add binary file tests for -I and -a flags
   — tests/utilities/grep_test.sh (new test block)
5. [IMPORTANT] Strengthen -q tests to verify empty stdout
   — tests/utilities/grep_test.sh:97-98
6. [IMPORTANT] Add context separator test (--) for
   non-adjacent matches with -A/-B/-C
   — tests/utilities/grep_test.sh (extend context block)
7. [IMPORTANT] Add --null output format test
   — tests/utilities/grep_test.sh (new test block)
8. [IMPORTANT] Add --binary-files mode tests
   — tests/utilities/grep_test.sh (new test block)
9. [SUGGESTION] Add -c and -n multi-file format tests
   — tests/utilities/grep_test.sh (extend count/lineno blocks)
10. [SUGGESTION] Add stderr content checks to error tests
    — tests/utilities/grep_test.sh:219-228
11. [SUGGESTION] Add --label stdin label test
    — tests/utilities/grep_test.sh (new test block)
12. [SUGGESTION] Add empty pattern test
    — tests/utilities/grep_test.sh (new test block)
13. [SUGGESTION] Add anchored pattern tests (^, $)
    — tests/utilities/grep_test.sh (new test block)
```

REVIEW COMPLETE - NEEDS_FIXES
