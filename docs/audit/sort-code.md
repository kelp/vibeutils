# sort Code Audit

**Date:** 2026-03-28
**File:** `src/sort.zig`
**Auditor:** reviewer agent
**Assessment:** NEEDS_FIXES

---

## Summary

The sort implementation has a solid foundation for basic sorting and
correctly implements most POSIX-required flags. However, it has
several behavioral divergences from the macOS (BSD) spec, two
CRITICAL flag collisions/omissions, and several parse-only stubs.
The most serious bug is the wrong algorithm for `-h` human-numeric
sort and the `-V`/`--version-sort` flag misassignment.

---

## Issues

---

### [CRITICAL] -V mapped to --version instead of version-sort

**Location:** `src/sort.zig:248`

**Problem:** `-V` is a standard flag on macOS, GNU, and OpenBSD
meaning version sort (`--version-sort`). The implementation
incorrectly maps it to `--version` (print version and exit). This
means any pipeline using `sort -V` for version-sort will silently
print the program version and exit instead of sorting. The
`--version-sort` long form is also completely unrecognized (exits 2).

Verified:
```
printf "file-1.10\nfile-1.9\n" | ./zig-out/bin/sort -V
# prints: sort (vibeutils) 0.8.2
# expected: file-1.9\nfile-1.10
```

**Fix:** Remove `'V' => opts.version = true` from the short-option
parser. Add a `version_sort` field to `SortFlags`, set it for `-V`
and `--version-sort`. Implement `compareVersionSort()`. The `--version`
long flag alone covers the version-print use case; `-V` must not be
aliased to it. The flags.md marks `-V` as "yes" for Ours, but this
is incorrect — it is currently unimplemented as a sort mode.

---

### [CRITICAL] -h human-numeric sort uses wrong ordering algorithm

**Location:** `src/sort.zig:1006-1061` (`compareHumanNumeric`,
`parseHumanNumber`)

**Problem:** The implementation converts values to raw bytes and
compares numerically. The macOS man page specifies a three-level
sort: first by sign, then by SI suffix rank (empty < K < M < G <
T < P < E < Z < Y), then by numeric value within the same suffix.
This means `12345K` sorts before `1M` (K rank < M rank) regardless
of raw byte values.

Verified:
```
printf "1M\n12345K\n1K\n" | ./zig-out/bin/sort -h
# vibeutils: 1K, 1M, 12345K  (WRONG: 1M=1048576 < 12345K=12636160)
# reference: 1K, 12345K, 1M  (CORRECT: K suffix < M suffix)
```

The integration test at `tests/utilities/sort_test.sh:68` uses
`printf '1G\n1M\n2K\n1K\n'` which happens to produce the same
output either way because all values ascend within the same suffix
ordering. It does not exercise the cross-suffix edge case.

**Fix:** `parseHumanNumber` must return a struct with `{sign, suffix_rank,
numeric_value}` rather than a scalar. `compareHumanNumeric` must
compare the three levels in order. Suffix rank: (none)=0, K/k=1,
M=2, G=3, T=4, P=5, E=6, Z=7, Y=8.

---

### [CRITICAL] -s stable sort is a parse-only stub (last-resort
comparison is also missing)

**Location:** `src/sort.zig:59, 142, 244`

**Problem:** Two linked issues:

1. Without `-s`, sort should perform a "last-resort" comparison
   of the full original line when all keys compare equal. GNU and
   macOS both do this. vibeutils always returns `false` (equal)
   when keys tie, preserving insertion order — which is the
   behavior of `-s`, not the default.

2. The `-s` flag is parsed and stored but never consulted in
   `compareLines` or `compareLinesWrapper`. Since the default
   already behaves as if `-s` is set, `-s` has no observable
   effect.

Verified:
```
printf "b 1\na 1\nc 1\n" | sort -k2,2n   # reference: a 1, b 1, c 1
printf "b 1\na 1\nc 1\n" | ./zig-out/bin/sort -k2,2n  # vibeutils: b 1, a 1, c 1 (WRONG)

printf "b 1\na 1\n" | sort -k2,2n     # reference: a 1, b 1  (last-resort)
printf "b 1\na 1\n" | sort -k2,2n -s  # reference: b 1, a 1  (stable, no last-resort)
# vibeutils: b 1, a 1 for BOTH (behaves like -s always)
```

**Fix:** In `compareLines`, after all keys compare equal, when
`opts.stable` is false, fall back to a full-line byte comparison
(`std.mem.order(u8, a, b) == .lt`). When `opts.stable` is true,
return false (preserve original order).

---

### [IMPORTANT] -R random sort uses fixed seed (--random-source
is a parse-only stub)

**Location:** `src/sort.zig:1071-1076`

**Problem:** `compareRandom` hashes with `Wyhash.hash(0, ...)` —
seed hardcoded to 0. This makes `-R` deterministic: the same input
always produces the same permutation. The `random_source` field is
parsed but never read in `runSort`. Per spec, the hash seed should
come from `/dev/random` by default, or from the file given to
`--random-source`.

Verified: invoking `sort -R` twice on the same input produces
identical output. The reference implementation produces different
output each run.

**Fix:** At sort startup, when `random_sort` is true, read 8 bytes
from `opts.random_source` (defaulting to `/dev/random`) and use
them as the Wyhash seed. Store the seed in `SortContext` and pass it
into `compareRandom`.

---

### [IMPORTANT] --debug is a parse-only stub

**Location:** `src/sort.zig:174-175`

**Problem:** `opts.debug` is set to true but never read after
`parseArgs` returns. GNU/macOS `--debug` annotates the key portion
used to sort (underlines it in output) and warns about questionable
key usage to stderr. No annotation or warning is produced.

**Fix:** In `writeLines` (or a parallel path), when `opts.debug` is
true, write an underline line after each sorted line showing which
characters were used as the sort key. This is a significant feature;
if not planned, the flag should be marked as unimplemented in help
output or rejected with an error.

---

### [IMPORTANT] --compress-program, --batch-size, --parallel,
-S, -T are parse-only stubs

**Location:** `src/sort.zig:62-69` (fields), parsing at 132-183

**Problem:** These operational-control options are parsed and
validated but have zero effect on runtime behavior:

- `compress_program`: never invoked; temporary file compression
  does not exist.
- `batch_size`: never consulted; merge fanout is unbounded.
- `parallel`: never consulted; always single-threaded.
- `buffer_size` (`-S`): parsed but ignored; all input is read into
  memory unconditionally via `readToEndAlloc`.
- `temp_dir` (`-T`): parsed but ignored; no temporary files are
  ever created.

For a pre-1.0 utility, silently accepting and ignoring these is
acceptable if documented. However, the flags.md marks all as "yes"
for Ours, implying they work.

**Fix (minimum):** Accept and silently ignore `-S`, `-T`,
`--batch-size`, `--parallel` (they are hints). Add a comment in
`runSort` and in the flags matrix noting they are accepted but
unimplemented. For `--compress-program`, consider rejecting with an
unimplemented error since it has a functional contract (compress temp
files) that cannot silently degrade.

---

### [IMPORTANT] -m (merge) with a single file falls through to
sort path

**Location:** `src/sort.zig:480`

**Problem:** The merge path is only entered when
`opts.merge_only and opts.files.items.len > 1`. With one file (or
stdin), execution falls through to the regular sort. The spec says
`-m` assumes inputs are pre-sorted and outputs them without
sorting. A single unsorted file with `-m` should output in original
order, not sorted.

Verified:
```
printf "c\na\nb\n" > /tmp/f.txt
./zig-out/bin/sort -m /tmp/f.txt   # outputs: a, b, c  (WRONG: sorted)
/usr/bin/sort -m /tmp/f.txt        # outputs: c, a, b  (CORRECT: unsorted passthrough)
```

**Fix:** Change the condition at line 480 from `> 1` to `>= 1`, or
restructure so that any `merge_only` invocation bypasses the sort
step and goes directly to `writeLines`.

---

### [IMPORTANT] -S buffer-size rejects valid suffixes from spec

**Location:** `src/sort.zig:1118-1138` (`parseBufferSize`)

**Problem:** The macOS and GNU specs allow `%`, `b`, `K`, `M`, `G`,
`T`, `P`, `E`, `Z`, `Y` as size multipliers. vibeutils only handles
`K`, `M`, `G`. Passing `-S 50%` or `-S 1b` returns an error exit
code 2, which diverges from the reference which accepts these.

Verified:
```
./zig-out/bin/sort -S 50% 2>&1   # exit 2: invalid buffer size
/usr/bin/sort -S 50% < /dev/null # exit 0
```

Since `-S` is otherwise a no-op (see above), this creates a
failure case that blocks valid invocations from succeeding.

**Fix:** Expand `parseBufferSize` to handle all spec suffixes:
`b`=1, `%`=percentage-of-memory (or just accept silently),
`T`=TiB, `P`=PiB, `E`=EiB, `Z`=ZiB, `Y`=YiB. At minimum, accept
them without erroring even if the value is unused.

---

### [IMPORTANT] Default field splitting strips leading blanks,
breaking character-position offsets

**Location:** `src/sort.zig:744-765` (`splitFields`)

**Problem:** When no field separator is given (`separator == null`),
POSIX specifies that initial blank spaces are included in the field.
`splitFields` skips leading blanks entirely, treating them as
whitespace between fields. This makes character-position offsets
within field 1 wrong when the line has leading blanks.

Verified:
```
printf " ba\n ab\n" | sort -k1.2,1.2
# reference:  ab (field1.char2='a'), then  ba (field1.char2='b')
# vibeutils:  ba first (field1 after blank-strip is "ba"; char2='a' > field1="ab"; char2='b')
# WRONG ORDER
```

**Fix:** In the default-separator path, the first field should
begin at offset 0 (including any leading blanks up to the first
blank-to-non-blank transition). Fields are separated at the
transition from non-blank to blank. The macOS spec: "the first blank
space of a sequence of blank spaces acts as the field separator and
is included in the field."

---

### [SUGGESTION] -R is deterministic — different from spec intent
but not user-visible as a correctness bug per se

**Location:** `src/sort.zig:1073`

This is already captured under the `--random-source` stub issue
above. Including here for completeness in the fix list.

---

### [SUGGESTION] -V help text says "--version" instead of
"--version-sort"

**Location:** `src/sort.zig:1278`

**Problem:** The help text reads:
```
-V, --version    output version information and exit
```

This is wrong on two counts: `-V` should be `--version-sort`
(a sort mode, not a version-print flag), and the help conflates
`-V` with `--version`. After fixing the `-V` flag collision (see
CRITICAL above), the help text must be updated to reflect the
correct semantics.

**Fix:** Change to:
```
-V, --version-sort   sort version numbers
    --version        output version information and exit
```

---

### [SUGGESTION] Integration test for -s only checks exit code
(parse-only stub test)

**Location:** `tests/utilities/sort_test.sh:117`

**Problem:**
```bash
test_command_exit_code "sort -s stable flag accepted" 0 ...
```
This only verifies the flag is accepted, not that it changes
behavior. The actual stable-sort behavior (preserve equal-key input
order) is never tested.

**Fix:** Add a behavioral test: two lines with equal keys should
preserve their input order when `-s` is given, but not when it is
omitted. This will also expose the missing last-resort comparison
bug.

---

### [SUGGESTION] Integration test for -h does not cover
cross-suffix ordering

**Location:** `tests/utilities/sort_test.sh:68`

**Problem:** The test uses input `1G, 1M, 2K, 1K` which happens to
work correctly under either algorithm (all ascending in both
value-based and suffix-rank-based ordering). The spec example
`12345K sorts before 1M` is not tested.

**Fix:** Add test case:
```bash
test_command_output "sort -h cross-suffix" $'12345K\n1M' \
    bash -c "printf '1M\n12345K\n' | '$binary' -h"
```

---

## Verdict Table

| Flag | Parses | Behavior | Status |
|------|--------|----------|--------|
| `-b` | yes | strips before compare, not in key boundary | IMPORTANT |
| `-c` / `-C` | yes | correct | OK |
| `-d` | yes | correct | OK |
| `-f` | yes | correct | OK |
| `-g` | yes | correct | OK |
| `-h` | yes | WRONG algorithm for cross-suffix | CRITICAL |
| `-i` | yes | correct | OK |
| `-k` | yes | char offset wrong with leading blanks | IMPORTANT |
| `-m` | yes | single-file falls through to sort | IMPORTANT |
| `-M` | yes | correct | OK |
| `-n` | yes | correct | OK |
| `-o` | yes | correct (incl. in-place) | OK |
| `-r` | yes | correct | OK |
| `-R` | yes | deterministic (fixed seed) | IMPORTANT |
| `-s` | yes | no-op (default already behaves like -s) | CRITICAL |
| `-S` | yes | accepted; unused; % and b suffixes rejected | IMPORTANT |
| `-t` | yes | correct | OK |
| `-T` | yes | accepted; unused | stub |
| `-u` | yes | correct | OK |
| `-V` | yes | mapped to --version, NOT version-sort | CRITICAL |
| `-z` | yes | correct | OK |
| `--batch-size` | yes | accepted; unused | stub |
| `--compress-program` | yes | accepted; unused | stub |
| `--debug` | yes | accepted; no annotation produced | IMPORTANT |
| `--files0-from` | yes | implemented | OK |
| `--heapsort/mergesort/mmap/qsort/radixsort` | yes | no-ops (documented) | OK |
| `--parallel` | yes | accepted; unused | stub |
| `--random-source` | yes | accepted; never used | stub/IMPORTANT |
| `--version-sort` | no | errors out | CRITICAL |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -V mapped to --version instead of version-sort
   — src/sort.zig:248, also add --version-sort long flag
2. [CRITICAL] -h human-numeric wrong algorithm (suffix rank, not
   raw bytes) — src/sort.zig:1006-1061
3. [CRITICAL] Default behavior missing last-resort comparison;
   -s is a no-op — src/sort.zig:644-669
4. [IMPORTANT] -m single-file bypasses merge path, sorts instead
   — src/sort.zig:480
5. [IMPORTANT] Default field splitting strips leading blanks, breaks
   -k char offsets — src/sort.zig:744-765
6. [IMPORTANT] --debug is a parse-only stub — src/sort.zig:174
7. [IMPORTANT] -R fixed seed (--random-source unused)
   — src/sort.zig:1073
8. [IMPORTANT] -S rejects valid % and b suffixes — src/sort.zig:1118
9. [SUGGESTION] Help text -V description is wrong — src/sort.zig:1278
10. [SUGGESTION] Integration test -s is parse-only stub
    — tests/utilities/sort_test.sh:117
11. [SUGGESTION] Integration test -h missing cross-suffix case
    — tests/utilities/sort_test.sh:68
```

---

## Counts

- CRITICAL: 3
- IMPORTANT: 6 (excluding pure stubs with no user impact)
- SUGGESTION: 3

**REVIEW COMPLETE — NEEDS_FIXES**
