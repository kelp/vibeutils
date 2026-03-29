# Integration Test Audit: du

**Date**: 2026-03-28
**Test file**: tests/utilities/du_test.sh
**Run result**: 18 tests, 18 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 18 tests pass. The suite covers the most common flags
(`-s`, `-h`, `-b`, `-c`, `-a`, `-d`) and verifies actual
output content for most of them. Hardlink deduplication is
tested with a numeric comparison, which is a genuine
behavioral check. However, ten MUST-tier flags (`-H`, `-k`,
`-L`, `-x`, `-P`, `-r`, and the symlink traversal semantics
they control) have zero integration tests. Eleven
SHOULD-tier flags (`-A`/`--apparent-size`, `-B`/`--block-size`,
`-g`, `-I`, `-l`, `-m`, `-n`, `-t`, `-S`, `--si`, `--icons`)
are also untested. Three tests are exit-code-only or
non-empty-output-only (weak). The `-h` human-readable test
does not verify that a suffix (K, M, G) actually appears in
the output.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|-------------------|---------|
| du binary | binary check | STRONG |
| du --help | exit-code 0 | WEAK |
| du --version | exit-code 0 | WEAK |
| du default output is non-empty | exit-code + non-empty | WEAK |
| du -s produces single line | line count == 1 | STRONG |
| du -h produces output | exit-code + non-empty | WEAK |
| du -b shows apparent size in bytes | output starts with "5" | STRONG |
| du -c shows total line | stdout contains "total" | STRONG |
| du -a shows individual files | stdout contains filename | STRONG |
| du -d 0 produces single line | line count == 1 | STRONG |
| du invalid flag exits 2 | exit-code 2 | WEAK |
| du nonexistent path exits 1 | exit-code 1 | WEAK |
| du deduplicates hardlinks | numeric size comparison | STRONG |
| du --color=never produces no ANSI | no ESC bytes in output | STRONG |
| du --color=always produces ANSI | ESC bytes present | STRONG |
| du --color=auto (non-TTY) no ANSI | no ESC bytes in output | STRONG |
| du --color=invalid exits 2 | exit-code 2 | WEAK |
| du basic operation (regression) | exit-code + non-empty | WEAK |

---

## Coverage Gaps

### MUST-tier flags with zero tests

**`-H` (follow symlinks on command line only)**

No test creates a symlink to a directory, runs `du -H`, and
verifies that the symlink target's contents are counted. A
regression to `-H` symlink traversal is completely invisible.

**`-k` (1024-byte blocks)**

No test verifies that `-k` changes the unit of output. A
file of known size passed through `du -k` should produce a
specific numeric result.

**`-L` (follow all symlinks)**

No test distinguishes `-L` behavior from `-P` or the
default. Symlink loop detection under `-L` is also untested.

**`-x` (do not cross mount points)**

No test verifies that `-x` stops traversal at mount
boundaries. This is hard to test portably but at minimum
a directory-only test could verify that a bind-mounted or
`tmpfs`-overlaid subtree is excluded.

**`-P` (no symlinks followed — default)**

No test explicitly verifies that `-P` excludes symlink
targets from the count, or that a symlink to a large file
does not inflate the reported size.

**`-r` (report errors for unreadable)**

No test creates an unreadable directory and verifies that
`-r` causes a diagnostic message to stderr. Currently the
suite discards stderr with `2>/dev/null` on every call.

### SHOULD-tier flags with zero tests

**`-A` / `--apparent-size` (apparent vs. disk size)**

No test verifies the difference between apparent size and
disk usage for a sparse file or a compressed volume. The
`-b` test is labelled "bytes/apparent size" but `-b` is a
GNU alias; the canonical `-A` flag is untested on its own.

**`-B` / `--block-size` (custom block size)**

No test passes `--block-size=4096` or `-B 4096` and
verifies the numeric output changes as expected relative
to `-k` or `-b`.

**`-g` (GiB blocks), `-m` (MiB blocks), `-k` (KiB blocks)**

None of the size-unit flags are tested for correct numeric
output. A file of known size should produce a predictable
value under each unit flag.

**`-I mask` (ignore matching files)**

No test passes a mask and confirms that matching filenames
are absent from the output.

**`-l` (count hardlinks multiple times)**

The hardlink dedup test confirms that `-l` is NOT the
default. But there is no test that explicitly passes `-l`
and verifies that the same inode is counted twice.

**`-n` (ignore nodump flag, macOS/BSD)**

Not tested. Admittedly the nodump flag (UF_NODUMP) is only
settable on macOS/BSD, making Linux testing awkward.

**`-t threshold` (filter by size threshold)**

No test verifies that entries below (or above) a threshold
are suppressed from output.

**`-S` (do not count subdirectory sizes)**

No test verifies that `-S` excludes subdirectory blocks from
a parent directory's reported size.

**`--si` (SI units, powers of 1000)**

No test verifies SI-formatted output (e.g., "1.0K" vs
"1.0Ki"). A file of known size could distinguish `--si`
from `-h`.

**`--icons`**

No test verifies that `--icons` adds icon characters to
output, or that `--color=never --icons` suppresses color
while retaining icons.

### Weak tests that should be strengthened

**`du -h produces output`**

The test only checks exit-code 0 and non-empty output. It
does not verify that a human-readable suffix (K, M, G, T)
actually appears. A broken `-h` that emits raw byte counts
would pass.

**`du default output is non-empty`**

This only checks exit 0 and non-empty output. It does not
verify the format: `<number>\t<path>` on each line. A
broken default-output format would be invisible.

**`du basic operation (regression)`**

Identical weakness to the default output test. The comment
says it guards against an allocator change, but the
guard is too loose — any non-empty output passes.

---

## Issues

### [IMPORTANT] Ten MUST-tier flags have zero integration tests
Location: tests/utilities/du_test.sh (missing sections)
Problem: `-H`, `-k`, `-L`, `-x`, `-P`, and `-r` are all
MUST-tier per du-flags.md. None have integration tests.
A regression in any of these flags would not be caught.
Fix: Add sections for each flag. At minimum:
- `-k`: `du -k "$file_of_known_bytes"` and verify the
  numeric result is `ceil(bytes / 1024)`.
- `-H` / `-L` / `-P`: create a symlink chain, run each
  flag, and compare the reported sizes to distinguish the
  three modes.
- `-x`: skip if no second mount point is available; else
  verify a bind-mounted subtree is excluded.
- `-r`: create an unreadable subdirectory, capture stderr,
  and assert it is non-empty.

### [IMPORTANT] `-h` test does not verify suffix format
Location: tests/utilities/du_test.sh:51-58
Problem: The test checks `exit_code -eq 0 && -n "$output"`.
A regression that drops the human-readable suffix and
emits raw byte counts would produce non-empty output with
exit 0, so the test would still pass.
Fix: Change the check to verify a suffix appears:
```bash
if [[ "$output" =~ [0-9][KMGTPEZYkmgtpezy] ]]; then
    print_test_result "du -h shows human-readable suffix" "PASS"
```

### [IMPORTANT] `-l` (count hardlinks multiple times) untested
Location: tests/utilities/du_test.sh (missing)
Problem: The hardlink dedup test confirms the default
behavior. The `-l` flag that inverts it is never exercised.
A broken or missing `-l` implementation would not be caught.
Fix: After the existing hardlink dedup test, add:
```bash
size_l=$("$binary" -lb "$hldir_hardlink" 2>/dev/null \
    | tail -1 | awk '{print $1}')
if [[ "$size_l" -ge "$size_copy" ]]; then
    print_test_result "du -l counts hardlinks multiple times" "PASS"
```

### [IMPORTANT] `-t threshold` untested
Location: tests/utilities/du_test.sh (missing)
Problem: Threshold filtering is a SHOULD-tier flag that is
implemented (du-flags.md Ours column: yes). A broken
threshold filter (e.g., off-by-one, wrong comparison
direction) is invisible to the suite.
Fix: Create two files of different sizes and verify that
`du -a -t <mid-size> "$tmpdir"` includes the large file
and excludes the small file.

### [IMPORTANT] stderr is always discarded; error diagnostics untested
Location: tests/utilities/du_test.sh (every binary invocation)
Problem: Every call uses `2>/dev/null`. The "nonexistent
path exits 1" test confirms the exit code but never
verifies that an error message is emitted to stderr.
A silent failure (exit 1 with no message) would pass.
Fix: For the nonexistent-path test, capture stderr and
assert it contains the missing path or a diagnostic string,
following the pattern in other test files:
```bash
run_command cmd out err code "$binary" /nonexistent/path/xyz
if [[ $code -eq 1 && -n "$err" ]]; then
    print_test_result "du nonexistent path reports error" "PASS"
```

### [SUGGESTION] `-S` (separate subdirectories) untested
Location: tests/utilities/du_test.sh (missing)
Problem: `-S` is SHOULD-tier and implemented. A test that
verifies a parent directory's size under `-S` does not
include its subdirectory's blocks would be a useful guard.

### [SUGGESTION] `--si` vs `-h` not contrasted
Location: tests/utilities/du_test.sh (missing)
Problem: `--si` uses powers of 1000 while `-h` uses 1024.
No test distinguishes them. For a file near a power-of-two
boundary, the two flags would produce different numeric
values, making the distinction testable.

---

## Strengths

- Hardlink deduplication is tested with a real numeric
  comparison between two identically-sized directories —
  one using hardlinks, one using copies. This is one of the
  most behaviorally thorough tests in the suite.
- The `-b` test creates a file with exactly 5 bytes and
  verifies the output starts with `5`, which is a genuine
  value check.
- The `-a` test checks for a specific filename in the
  output, confirming that individual file entries appear,
  not just directory summaries.
- The `--color` section is comprehensive: never/always/auto
  modes and an invalid-value error are all covered, and the
  checks inspect actual output bytes rather than exit codes.
- The `-d 0` and `-s` tests both verify line count, which
  is a concrete behavioral check for depth-limiting.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Add -k/-H/-L/-P/-x behavioral tests
               — du_test.sh (missing sections)
2. [IMPORTANT] Add -r error-reporting test (stderr non-empty)
               — du_test.sh (missing section)
3. [IMPORTANT] Strengthen -h test to verify suffix format
               — du_test.sh:51-58
4. [IMPORTANT] Add -l hardlink-multiply test
               — du_test.sh (after hardlink dedup section)
5. [IMPORTANT] Add -t threshold test
               — du_test.sh (missing section)
6. [IMPORTANT] Assert stderr non-empty in nonexistent-path test
               — du_test.sh:109-111
7. [SUGGESTION] Add -S subdirectory-separation test
               — du_test.sh (missing)
8. [SUGGESTION] Add --si vs -h contrast test
               — du_test.sh (missing)
```

REVIEW COMPLETE - NEEDS_FIXES
