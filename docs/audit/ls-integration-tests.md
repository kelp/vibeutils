# Integration Test Audit: ls

**Date**: 2026-03-28
**Test file**: tests/utilities/ls_test.sh
**Test run**: 45 tests, 45 passed, 0 failed

## Executive Summary

PASS WITH ISSUES

All 45 tests pass, but the suite has significant gaps. Many MUST-tier
flags have no integration test at all. Several tests use weak
substring-in-output checks that could pass even if a flag were a
no-op. Two confirmed behavioral bugs are untested: `-a` does not show
`.` and `..` entries (matches `-A` behavior instead), and nonexistent
paths exit 0 instead of 2. The suite gives a false green signal.

---

## Test Inventory

| # | Test Name | Method | Verification Type |
|---|-----------|--------|-------------------|
| 1 | ls binary | binary_exists | EXISTENCE |
| 2 | ls --help | test_basic_flags | EXIT\_ONLY |
| 3 | ls --version | test_basic_flags | EXIT\_ONLY |
| 4 | ls basic listing contains files | inline substring | OUTPUT (substring) |
| 5 | ls basic exit code | test\_command\_exit\_code | EXIT\_ONLY |
| 6 | ls -1 one per line count | inline line count | OUTPUT (count) |
| 7 | ls -1 each file on own line | inline grep -x | OUTPUT (strong) |
| 8 | ls -l contains filenames | inline substring | OUTPUT (substring) |
| 9 | ls -l shows permissions | inline grep regex | OUTPUT (pattern) |
| 10 | ls -l shows sizes | inline grep regex | OUTPUT (pattern) |
| 11 | ls without -a hides dotfiles | inline substring neg | OUTPUT (negative) |
| 12 | ls -a shows hidden files | inline substring | OUTPUT (substring) |
| 13 | ls -a shows dotfiles | inline grep | OUTPUT (substring) |
| 14 | ls -A shows hidden files | inline substring | OUTPUT (substring) |
| 15 | ls -A hides . and .. | inline grep -x neg | OUTPUT (negative) |
| 16 | ls -d lists directory entry | inline substring | OUTPUT (substring) |
| 17 | ls -d does not list contents | inline substring neg | OUTPUT (negative) |
| 18 | ls -R shows all nested files | inline substring | OUTPUT (substring) |
| 19 | ls -R shows subdirectories | inline substring | OUTPUT (substring) |
| 20 | ls -lh lists file | inline substring | OUTPUT (substring) |
| 21 | ls -lh shows human-readable size | inline grep regex | OUTPUT (pattern) |
| 22 | ls -S largest file first | inline head -1 exact | OUTPUT (strong) |
| 23 | ls -S smallest file last | inline tail -1 exact | OUTPUT (strong) |
| 24 | ls -t newest file first | inline head -1 exact | OUTPUT (strong) |
| 25 | ls empty directory | inline empty check | OUTPUT (exact) |
| 26 | ls empty directory exit code | test\_command\_exit\_code | EXIT\_ONLY |
| 27 | ls nonexistent directory error message | inline stderr check | OUTPUT (stderr) |
| 28 | ls multiple dirs shows all files | inline substring | OUTPUT (substring) |
| 29 | ls multiple dirs exit code | test\_command\_exit\_code | EXIT\_ONLY |
| 30 | ls invalid flag | test\_command\_fails | EXIT\_ONLY |
| 31 | ls no arguments | test\_command\_exit\_code | EXIT\_ONLY |
| 32 | ls -la shows hidden files with details | inline compound | OUTPUT (compound) |
| 33 | ls -lR recursive long format | inline compound | OUTPUT (compound) |
| 34 | ls single file argument | inline substring | OUTPUT (substring) |
| 35 | ls single file exit code | test\_command\_exit\_code | EXIT\_ONLY |
| 36 | POSIX: ls no args succeeds | test\_command\_exit\_code | EXIT\_ONLY |
| 37 | POSIX: ls directory operand | test\_command\_exit\_code | EXIT\_ONLY |
| 38 | POSIX: success exit code | test\_command\_exit\_code | EXIT\_ONLY |
| 39 | POSIX: nonexistent path error message | inline stderr check | OUTPUT (stderr) |
| 40 | ls files with special names | inline substring | OUTPUT (substring) |
| 41 | ls shows symlinks | inline substring | OUTPUT (substring) |
| 42 | ls -l shows symlink arrow | inline substring | OUTPUT (substring) |
| 43 | ls truecolor icons emit RGB sequences | inline grep | OUTPUT (pattern) |
| 44 | ls NO\_COLOR suppresses escapes | inline grep neg | OUTPUT (negative) |
| 45 | ls NO\_COLOR overrides --color=always | inline grep neg | OUTPUT (negative) |

---

## Weak Tests

### Tests that would pass if a flag were a no-op

**Test 5 — "ls basic exit code"** (EXIT_ONLY)
`test_command_exit_code 0 "$binary" "$test_dir"` passes if ls exits 0
for any reason. A no-op implementation passes.

**Tests 26, 29, 35, 36, 37, 38** (EXIT_ONLY)
All pure exit-code checks. None verifies that the listed content is
correct or affected by the flag being tested.

**Test 31 — "ls no arguments"** (EXIT_ONLY)
Checks exit 0 with no args. Does not verify that the current directory
contents appear in output.

**Test 30 — "ls invalid flag"** (EXIT_ONLY via test_command_fails)
Correct that it fails, but does not verify an error message is printed
to stderr.

**Tests 8, 12, 14, 18, 19, 28, 34** (substring only)
These check that a filename appears somewhere in output. They would
pass even if the flag being tested had no effect, because the filename
would appear regardless.

**Tests 20–21 — `-lh`**
Test 20 only checks the filename is present (passes without `-h`).
Test 21 matches `[0-9]+(\.[0-9])?[KMGT]?` — the `?` makes `KMGT`
optional, so any numeric output matches. A file showing raw byte size
`0` satisfies this regex. This test cannot detect a broken `-h`.

---

## Missing Coverage

The following MUST/SHOULD flags have no integration test that verifies
behavior. "EXIT_ONLY" means only an exit-code check exists; "NONE"
means no test at all.

| Flag | Tier | Has Integration Test? | Strength |
|------|------|-----------------------|----------|
| -1 | MUST | Yes | MODERATE |
| -a | MUST | Yes — but **BUG: . and .. absent** | WEAK |
| -A | MUST | Yes | MODERATE |
| -c | MUST | **NONE** | — |
| -C | MUST | **NONE** | — |
| -d | MUST | Yes | MODERATE |
| -f | MUST | **NONE** | — |
| -F | MUST | **NONE** | — |
| -g | MUST | **NONE** | — |
| -H | MUST | **NONE** | — |
| -i | MUST | **NONE** | — |
| -k | MUST | **NONE** | — |
| -l | MUST | Yes | MODERATE |
| -L | MUST | **NONE** | — |
| -m | MUST | **NONE** | — |
| -n | MUST | **NONE** | — |
| -o | MUST | **NONE** | — |
| -p | MUST | **NONE** | — |
| -q | MUST | **NONE** | — |
| -r | MUST | **NONE** | — |
| -R | MUST | Yes | MODERATE |
| -s | MUST | **NONE — and BUG exists** | — |
| -S | MUST | Yes | STRONG |
| -t | MUST | Yes | STRONG |
| -T | MUST | **NONE** | — |
| -u | MUST | **NONE** | — |
| -x | MUST | **NONE** | — |
| -h | MUST | Yes | WEAK (regex too loose) |
| -b | SHOULD | **NONE** | — |
| -B | SHOULD | **NONE** | — |
| -G | SHOULD | **NONE** | — |
| -I | SHOULD | **NONE** | — |
| -v | SHOULD | **NONE** | — |
| -w | SHOULD | **NONE** | — |
| -X | SHOULD | **NONE** | — |
| --color | SHOULD | Yes (truecolor/NO_COLOR) | MODERATE |
| --group-directories-first | SHOULD | **NONE** | — |
| --time-style | SHOULD | **NONE** | — |
| --git | KEEP | **NONE** | — |
| --icons | KEEP | Partial (truecolor test) | WEAK |

Of 45 MUST/SHOULD/KEEP flags, **27 have no behavioral integration
test**.

---

## Confirmed Behavioral Bugs (Found by System Comparison)

### BUG-1: `-a` does not show `.` and `..`

System ls with `-a`:
```
.
..
.hidden
a.txt
```

Our ls with `-a`:
```
.hidden
a.txt
```

Our `-a` behaves identically to `-A`. POSIX requires `-a` to include
`.` and `..`. This is a spec violation. The test suite comment at
line 117 acknowledges this: "our ls currently does not include . and
.. entries, matching -A behavior" — but this is listed as `-a`'s
defined contract, which is wrong. The test therefore validates
incorrect behavior and masks the bug.

### BUG-2: Nonexistent path exits 0 instead of 2

System ls:
```
$ ls /nonexistent; echo $?
2
```

Our ls:
```
$ ls /nonexistent; echo $?
0
```

POSIX requires exit code > 0 when an error occurs. GNU ls uses exit 2
for usage/access errors. The test suite at lines 283–289 and 366–372
explicitly tests only for stderr output, with comments acknowledging
the wrong exit code. The test validates the bug's presence as expected
behavior rather than failing on it.

### BUG-3: `-s` block count wrong for symlinks

System ls `-s` on a symlink with 0 blocks allocated:
```
total 0
0 file.txt
0 link.txt
```

Our ls:
```
total 1
   0 file.txt
   1 link.txt
```

Our implementation charges 1 block for the symlink. The system reports
0. The `total` line is also off by 1. No integration test covers `-s`.

---

## Expected Output Issues

### `-h` test regex is too loose (line 209)

```bash
if echo "$lh_output" | grep -qEi '[0-9]+(\.[0-9])?[KMGT]?'; then
```

The `KMGT` group is optional (`?`). Any output containing a digit
passes. A file showing raw byte count `0` satisfies this. The test
cannot distinguish `-lh` (human sizes) from `-l` (raw bytes).

**Fix**: Create a file of known size (>= 1024 bytes) and assert the
output contains a suffix: `grep -qE '[0-9]+(\.[0-9]+)?[KMGT]'`
(suffix required, not optional).

### `-a` test validates wrong behavior (lines 117–126)

The comment at line 117 says "our implementation does not include
. and .. entries, matching -A behavior". The tests then pass because
they only check for `.hidden_file` and `.config`. No test checks for
the absence of `.` and `..` under `-a` — it only checks their absence
under `-A`. The net result: the suite hides BUG-1 rather than
detecting it.

### Nonexistent-path exit code tests are suppressed (lines 280–289,
363–372)

Both tests deliberately skip the exit code check because of BUG-2.
They substitute a weaker stderr-presence check. This encodes a known
bug as passing behavior. Once BUG-2 is fixed, these tests must be
updated to assert `exit code 2`.

---

## System Comparison Summary

| Flag | System Behavior | Our Behavior | Match? |
|------|----------------|--------------|--------|
| -a | Shows `.` and `..` | Does not show them | **NO** |
| nonexistent exit | Exit 2 | Exit 0 | **NO** |
| -s symlink blocks | 0 blocks | 1 block | **NO** |
| -s total | 0 | 1 | **NO** |
| -F | `link@`, `dir/`, `exec*` | Same | YES |
| -p | Appends `/` to dirs | Same | YES |
| -i | Shows inode numbers | Same | YES |
| -m | Comma-separated | Same | YES |
| -n | Numeric uid/gid | Same | YES |
| -r | Reverse sort | Same | YES |
| -C | Multi-column | Same (extra space) | ~YES |
| -T (GNU) | Invalid (macOS -T is tab) | Full timestamp | YES (GNU) |
| -o | Omits group | Same | YES |
| -g | Omits owner | Same | YES |
| --group-directories-first | Dirs first | Same | YES |
| --time-style=iso | ISO dates | Same | YES |
| --time-style=relative | Relative times | Same | YES |
| -f (no-sort) | Shows `.` `..` + unsorted | No `.` `..` | **NO** |
| -B (hide backups) | Hides `~` files | Same | YES |
| -I PATTERN | Hides matches | Same | YES |

Note: `-f` (no-sort) must imply `-a` per spec. Our implementation
omits `.` and `..` from `-f` output, consistent with the same root
cause as BUG-1.

---

## Missing Test Scenarios

These scenarios are not covered at all:

1. **`-r` reverse sort** — no test verifies output order is reversed
2. **`-c` ctime sort** — no test verifies ctime is used vs mtime
3. **`-u` atime sort** — no test verifies atime is used
4. **`-n` numeric IDs** — no test checks UID/GID appear as numbers
5. **`-i` inodes** — no test checks inode number appears in output
6. **`-m` comma format** — no test checks comma-separated output
7. **`-s` block display** — no test at all; active bug undetected
8. **`-F` file type indicators** — no test checks `@`, `/`, `*`
   appended to entries
9. **`-p` slash after dirs** — no test verifies `/` appended
10. **`-C` multi-column vs `-1`** — no test verifies layout change
11. **`-T` full timestamp** — no test checks seconds appear in output
12. **`-o` / `-g`** — no test checks which id column is absent
13. **`--time-style`** — no test verifies date format changes
14. **`--group-directories-first`** — no test verifies sort order
15. **`-a` with `.` and `..`** — test should FAIL until BUG-1 is fixed
16. **nonexistent path exit code 2** — test should FAIL until BUG-2
    is fixed
17. **`-l` total line** — no test verifies the `total N` header
18. **Multiple dirs: headers** — with 2+ dirs, output should include
    directory name headers (`dirname:`)
19. **`-f` implies `-a`** — no test verifies dotfiles appear with
    unsorted flag

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| F-01 | CRITICAL | BUG: `-a` does not show `.` and `..`; suite hides this |
| F-02 | CRITICAL | BUG: nonexistent path exits 0; suite encodes bug as pass |
| F-03 | IMPORTANT | BUG: `-s` charges 1 block to symlinks; no test exists |
| F-04 | IMPORTANT | 27 of 45 MUST/SHOULD flags have zero behavioral tests |
| F-05 | IMPORTANT | `-h` test regex accepts raw byte output; cannot detect broken flag |
| F-06 | IMPORTANT | `-r` (reverse sort) has no test despite being MUST tier |
| F-07 | IMPORTANT | `-F` (file type indicators) has no test despite being MUST tier |
| F-08 | IMPORTANT | `-m` (comma format) has no test despite being MUST tier |
| F-09 | IMPORTANT | `-i` (inodes) has no test despite being MUST tier |
| F-10 | IMPORTANT | `-n` (numeric IDs) has no test despite being MUST tier |
| F-11 | IMPORTANT | `-s` (blocks) has no test despite being MUST tier |
| F-12 | IMPORTANT | `-T` (full time) has no test despite being MUST tier |
| F-13 | IMPORTANT | `-c`/`-u` time-field selection have no behavioral tests |
| F-14 | SUGGESTION | Multiple-dir header format (dirpath:) not tested |
| F-15 | SUGGESTION | `-l` `total` line not tested |
| F-16 | SUGGESTION | Several EXIT_ONLY tests add no value beyond the binary-exists check |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -a must show . and .. — src/ls/entry_collector.zig (see BUG-1)
2. [CRITICAL] nonexistent path must exit 2 — src/ls/core.zig (see BUG-2)
3. [CRITICAL] Update -a test: assert . and .. are present, remove
              masking comment — tests/utilities/ls_test.sh:117
4. [CRITICAL] Update nonexistent-path tests: assert exit code 2, not
              just stderr content — tests/utilities/ls_test.sh:283, 363
5. [IMPORTANT] Fix -s block count for symlinks — BUG-3, then add test
6. [IMPORTANT] Add behavioral test for -r (verify last file is first)
7. [IMPORTANT] Add behavioral test for -F (verify @ on symlink, / on dir)
8. [IMPORTANT] Add behavioral test for -m (verify comma-separated output)
9. [IMPORTANT] Add behavioral test for -i (verify inode number present)
10. [IMPORTANT] Add behavioral test for -n (verify numeric uid/gid)
11. [IMPORTANT] Add behavioral test for -T (verify seconds in timestamp)
12. [IMPORTANT] Add behavioral test for -c/-u (verify different sort order)
13. [IMPORTANT] Fix -h test regex to require size suffix (not optional)
14. [SUGGESTION] Add test for multi-dir header format
15. [SUGGESTION] Add test for -l total line
```

State: "REVIEW COMPLETE - NEEDS_FIXES"
