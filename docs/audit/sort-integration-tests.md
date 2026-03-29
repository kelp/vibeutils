# Integration Test Audit: sort

**Date**: 2026-03-28
**Test file**: tests/utilities/sort_test.sh
**Flags spec**: docs/specs/sort-flags.md
**Test run**: 39 tests, 39 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 39 tests pass, but the suite has a confirmed correctness bug
(`-V` flag), two weak behavioral tests (`-z`, `-s`), and large
coverage gaps across 19 MUST-tier flags from the spec. The `-f`
flag output differs from GNU/system sort in tie-breaking order,
and `-d` differs in sub-sort order for punctuation-equivalent
strings — both warrant investigation.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| sort binary | binary exists | Weak |
| sort --help | exit code 0 | Weak |
| sort --version | exit code 0 | Weak |
| sort alphabetical | `test_command_output` exact | Strong |
| sort already sorted | `test_command_output` exact | Strong |
| sort reverse input | `test_command_output` exact | Strong |
| sort single line | `test_command_output` exact | Strong |
| sort empty input | `test_command_output` exact | Strong |
| sort -r reverse | `test_command_output` exact | Strong |
| sort --reverse | `test_command_output` exact | Strong |
| sort -n numeric | `test_command_output` exact | Strong |
| sort -n with negatives | `test_command_output` exact | Strong |
| sort -rn reverse numeric | `test_command_output` exact | Strong |
| sort -f case insensitive | `test_command_output` exact | Strong* |
| sort -u unique | `test_command_output` exact | Strong |
| sort -u already unique | `test_command_output` exact | Strong |
| sort -d dictionary | `test_command_output` exact | Strong* |
| sort -b ignore blanks | `test_command_output` exact | Strong |
| sort -h human numeric | `test_command_output` exact | Strong |
| sort -g general numeric | `test_command_output` exact | Strong |
| sort -c sorted input | exit code 0 | Weak |
| sort -c unsorted input | exit code 1 | Weak |
| sort -C quiet check sorted | exit code 0 | Weak |
| sort -C quiet check unsorted | exit code 1 | Weak |
| sort -t: -k2 | `test_command_output` exact | Strong |
| sort -t: -k2n | `test_command_output` exact | Strong |
| sort file input | `test_command_output` exact | Strong |
| sort -o output file | `test_command_output` exact | Strong |
| sort -z zero terminated | exit code 0 | Weak |
| sort -nru combined | `test_command_output` exact | Strong |
| sort -s stable flag accepted | exit code 0 | Weak |
| sort invalid flag | exit code 2 | Weak |
| sort invalid long flag | exit code 2 | Weak |
| sort nonexistent file | exit code 2 | Weak |
| sort -- handles dash files | `test_command_output` exact | Strong |
| sort multiple files | `test_command_output` exact | Strong |
| sort dash means stdin | `test_command_output` exact | Strong |
| sort multi-line file (readLines regression) | `test_command_output` exact | Strong |
| sort basic b-a to a-b (argsFree safety net) | `test_command_output` exact | Strong |

*Strong in isolation but tested with inputs that do not expose
known divergences from GNU behavior (see Bugs section).

---

## Confirmed Bug

### `-V` (--version-sort) is broken

`sort -V` with stdin input prints the `--version` string and exits
0 instead of performing version sort. The flag is conflicting with
`--version` in the argument parser.

```
$ printf 'v1.10\nv1.9\nv1.2\n' | ./sort -V
sort (vibeutils) 0.8.2
```

Expected:
```
v1.2
v1.9
v1.10
```

System `/usr/bin/sort -V` produces the correct version-sorted
output. The test suite has no `-V` test at all, so the bug is
fully invisible to CI.

---

## Behavioral Divergences from System sort

These are not confirmed bugs — they may be acceptable per spec —
but they differ from GNU/system sort output and should be verified.

### `-f` tie-breaking order

For inputs with the same fold-equivalent key, vibeutils and system
sort produce different orderings for the non-equal originals.

```
Input: banana / Apple / cherry / APPLE
vibeutils -f: Apple, APPLE, banana, cherry
system -f:    APPLE, Apple, banana, cherry
```

GNU sort is stable and preserves input order among fold-equal
lines. vibeutils appears to reverse the order of fold-equal pairs.
This suggests `-f` does not respect stability for equal keys.

### `-d` sub-sort order for punctuation-stripped equivalents

When punctuation is stripped and strings sort equal under `-d`,
the final ordering of the originals differs:

```
Input: a.b / a-b / a b / ab
vibeutils -d: a b, a.b, a-b, ab
system -d:    a b, a-b, a.b, ab
```

---

## Weak Tests — Details

**`sort -z zero terminated`** (line 109)
Checks exit code 0 only. Does not verify that NUL-separated
records are sorted correctly. Verified manually that output is
correct, but a passing test here gives no regression protection.

**`sort -s stable flag accepted`** (line 117)
Checks exit code 0 only. Does not verify that equal-key records
maintain original input order. This is the entire behavioral
guarantee of `-s` and it is untested.

**`sort -c sorted input`** / **`sort -c unsorted input`** (lines
77-80)
Exit-code-only. Does not verify:
- That `-c` sends disorder messages to stderr (not stdout)
- That `-C` produces no output at all (silent mode)
- That `-c -u` detects duplicate keys

**`sort -C quiet check unsorted`** (line 84)
Does not verify that no output is written (the "quiet" contract
of `-C`).

---

## Coverage Gaps — MUST-Tier Flags

Flags listed as MUST in docs/specs/sort-flags.md with no test
of any kind:

| Flag | What it does | Risk |
|------|-------------|------|
| `-V` | Version sort | **BROKEN** — no test masks the bug |
| `-i` | Ignore non-printing chars | No behavioral test |
| `-M` | Month sort | No test at all |
| `-m` | Merge pre-sorted files | No test at all |
| `-R` | Random sort | No test at all |
| `-S` | Buffer size | No test at all |
| `-T` | Temp directory | No test at all |
| `--batch-size` | Max open files | No test at all |
| `--compress-program` | Compress temp files | No test at all |
| `--debug` | Debug output | No test at all |
| `--files0-from` | NUL-separated file list | No test at all |
| `--heapsort` | Use heap sort | No test at all |
| `--mergesort` | Use merge sort | No test at all |
| `--mmap` | Use mmap | No test at all |
| `--parallel` | Thread count | No test at all |
| `--qsort` | Use quicksort | No test at all |
| `--radixsort` | Use radix sort | No test at all |
| `--random-source` | Seed file for -R | No test at all |
| multiple `-k` keys | Tie-breaking | No test at all |
| `-k` without end field | Key to end of line | No test at all |
| `-c -u` combined | Check unique + sorted | No test at all |

---

## Missing Behavioral Tests for Covered Flags

These flags have tests but are missing coverage for important
behavioral contracts:

**`-c` / `-C`**
- No test that disorder message goes to stderr only
- No test that `-C` produces zero stdout and zero stderr
- No test for `-c -u` detecting duplicates (verified to work
  manually, but unprotected by tests)
- No test for `-c` on empty input (verified exit 0, unprotected)

**`-o`**
- No test for in-place sort (output file same as input file).
  Verified to work, but this is a known edge case that has broken
  other implementations.

**`-u`**
- No test that `-u` deduplicates non-adjacent equal keys (i.e.,
  that it sorts first, then deduplicates — not just removes
  consecutive duplicates). Verified correct but unprotected.

**`-b`**
- Tests only global `-b`. No test for `-b` attached to a key
  field (e.g., `-k1,1b`).

**Stdin filter** (no-args case)
- The existing tests use `printf ... | sort` via bash -c. There
  is no test that invokes `$binary` directly with piped stdin and
  zero arguments, verifying it behaves as a filter. This is the
  most common real-world use and is exercised only indirectly.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -V flag treated as --version — sort -V does not sort
   Location: tests/utilities/sort_test.sh (add test), src/sort.zig (fix)
   Add a test first: printf 'v1.10\nv1.9\nv1.2\n' | sort -V
   Expected: v1.2 / v1.9 / v1.10

2. [IMPORTANT] Upgrade sort -z to output-verifying test
   Location: tests/utilities/sort_test.sh:109
   Replace exit-code-only check with NUL-delimited output comparison

3. [IMPORTANT] Add behavioral test for sort -s (stability)
   Location: tests/utilities/sort_test.sh:117
   Use input with equal primary keys; verify original order is
   preserved in output

4. [IMPORTANT] Add -c/-C behavioral tests
   Location: tests/utilities/sort_test.sh
   - Verify -c disorder message goes to stderr
   - Verify -C produces no output
   - Verify -c -u detects duplicate keys

5. [IMPORTANT] Add -V behavioral test (after fix)
   Location: tests/utilities/sort_test.sh
   Test version-sort ordering with v1.2 / v1.9 / v1.10 input

6. [IMPORTANT] Add -M month sort test
   Location: tests/utilities/sort_test.sh
   printf 'Dec\nJan\nMar\nFeb\n' | sort -M → Jan/Feb/Mar/Dec

7. [IMPORTANT] Add -i ignore-nonprinting test
   Location: tests/utilities/sort_test.sh
   Verify control characters are ignored in comparison

8. [IMPORTANT] Add -m merge test
   Location: tests/utilities/sort_test.sh
   Two pre-sorted files merged in order

9. [IMPORTANT] Add multiple -k tie-breaking test
   Location: tests/utilities/sort_test.sh
   Verify second key is used when first key ties

10. [SUGGESTION] Investigate -f and -d divergence from system sort
    -f: vibeutils reverses equal fold-key pairs vs GNU stable behavior
    -d: sub-sort order differs for punctuation-stripped equivalents

11. [SUGGESTION] Add -o in-place test
    Location: tests/utilities/sort_test.sh
    Sort with -o pointing to the same file as input

12. [SUGGESTION] Add -R smoke test with output verification
    Verify output has same line count and same lines (any order)

13. [SUGGESTION] Add -S and -T acceptance tests with output verification
    Currently these are untested entirely; at minimum verify they
    don't change output correctness
```

---

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| IMPORTANT | 8 |
| SUGGESTION | 4 |

**Assessment: NEEDS_FIXES**

The `-V` flag bug is a confirmed correctness failure masked by
absent tests. Eight important behavioral gaps leave real contracts
unprotected. The core sort operations (alphabetical, numeric,
reverse, unique, field/key) are well tested with strong output
verification.
