# Code Audit: du

**Date**: 2026-03-28
**Re-audit**: 2026-03-28 — reclassified against corrected spec framing
(GNU coreutils is primary behavioral reference; macOS-only flags follow
macOS semantics).
**File**: `src/du.zig`
**Build result**: passes (`just build-util du`)
**Integration tests**: 18/18 pass (`just it-util du`)
**Unit tests**: substantial suite present (see unit audit)

---

## Spec Framing (Re-audit Note)

The original audit used macOS as primary reference in two places where
GNU should be authoritative. Corrections applied:

- **-B rounding to 512**: This is a macOS-only requirement. GNU `-B`
  simply scales by the given SIZE with no 512-alignment. The original
  IMPORTANT finding is **removed** — it is not a bug against the GNU
  spec.
- **-n (nodump)**: `-n` is macOS-only (GNU column is blank in the flag
  matrix). Therefore macOS semantics (ignore `UF_NODUMP` files) are the
  correct target. The original finding is confirmed: our implementation
  maps `-n` to no-follow-symlinks, which is wrong under any spec.
- **-I (ignore pattern)**: `-I` is macOS-only. macOS semantics apply and
  the stub finding stands.
- **-A directory apparent size**: Confirmed against GNU empirically (see
  issue 2). Finding stands.
- **-L / -S / BLOCKSIZE**: All GNU-spec findings. Unchanged.

---

## Flag Verdict Table

| Flag | Tier | Verdict |
|------|------|---------|
| -a | MUST | PASS |
| -H | MUST | PASS |
| -k | MUST | PASS |
| -L | MUST | FAIL — double-counts symlink targets (see issue 1) |
| -s | MUST | PASS |
| -x | MUST | PASS |
| -c | MUST | PASS |
| -d | MUST | PASS |
| -h | MUST | PASS |
| -P | MUST | PASS |
| -r | MUST | PASS (accepted, no-op per spec) |
| -A | SHOULD | FAIL — adds directory inode size in apparent mode (see issue 2) |
| -B | SHOULD | PASS (GNU: no 512 rounding required) |
| -g | SHOULD | PASS |
| -I | SHOULD | STUB — parsed but ignored entirely (see issue 3) |
| -l | SHOULD | PASS |
| -m | SHOULD | PASS |
| -n | SHOULD | WRONG — mapped to -P instead of nodump ignore (see issue 4) |
| -t | SHOULD | PASS |
| -b | SHOULD | FAIL — inherits apparent-size bug from -A (see issue 2) |
| -S | SHOULD | FAIL — shows only dir-inode blocks, not direct-file sum (see issue 5) |
| --si | SHOULD | PASS |
| --apparent-size | SHOULD | FAIL — same as -A (see issue 2) |
| --block-size | SHOULD | PASS |
| BLOCKSIZE env | GNU/POSIX | STUB — not read (see issue 6) |
| POSIXLY_CORRECT | GNU/POSIX | STUB — not read; help text claims it is (see issue 6) |

---

## Issues

```
[CRITICAL] -L double-counts symlink targets
Location: src/du.zig:397-407 (inode dedup), lines 362-387
Problem: When -L is active, fstatat() resolves symlinks so
  link.txt and real.txt inside the same directory both stat to
  the same inode. However, the dedup guard requires nlink > 1:
    if (nlink > 1 and !is_dir and !config.count_links)
  Symlink targets typically have nlink == 1, so dedup never
  triggers. Both the symlink entry and the real file are
  counted, inflating the total by the size of every symlinked
  file.

  Verified: `du -aL /tmp/dutest3` (which has real.txt and
  link.txt -> real.txt) shows 8 blocks; GNU shows 4.

Fix: When dereference_mode is .all (or .args_only for
  depth == 0), track seen_inodes unconditionally, not only
  when nlink > 1. The nlink > 1 guard is an optimisation for
  hard links; symlink following requires always checking.
```

```
[CRITICAL] -A / --apparent-size / -b: directory apparent size
  includes directory inode bytes
Location: src/du.zig:334-342 (getFileSize), line 421
Problem: getFileSize returns stat.size for directories in
  apparent_size mode. On ext4 a directory's stat.size is
  4096, so every directory adds 4096 bytes to the apparent-
  size total even though those bytes are not file content.

  GNU du --apparent-size adds 0 for directory metadata; only
  file content is summed. This inflates every apparent-size
  result by 4096 bytes per subdirectory.

  Verified on /home/tcole/code/vibeutils/src (3 dirs):
    GNU: 2641282  Ours: 2653570  Diff: 12288 (3 x 4096)

Fix: In getFileSize, when apparent_size is true AND
  stat.mode indicates a directory, return 0.
```

```
[CRITICAL] -I (ignore pattern) is a complete stub
Location: src/du.zig:63,99
Problem: ignore_pattern is parsed and stored but never
  consulted during traversal. `du -I "*.txt" /some/dir`
  produces identical output to `du /some/dir`. The field
  comment in DuOptions even says "(stub)".
  Spec: macOS-only flag; macOS defines -I PATTERN as exclude
  files/directories matching PATTERN during traversal.
Fix: In calculateDu, after resolving the entry name, call
  std.mem.matchesPosixPattern (or fnmatch via C) against
  config.ignore_pattern when it is non-null and skip the
  entry if it matches.
```

```
[CRITICAL] -S (--separate-dirs) shows only dir-inode blocks,
  not the sum of files directly inside the directory
Location: src/du.zig:465 (total_size assignment), line 471
Problem: With separate_dirs, total_size is set to
  dir_own_size, which is the disk usage of the directory
  inode itself (often 8 blocks = 4 KiB on ext4, or 0 on
  tmpfs). The files directly inside the directory are
  accumulated in subtree_size but then excluded from
  total_size.

  Expected (GNU): -S should print for each directory the sum
  of its directly-contained files only, excluding
  subdirectories' sizes (which are reported separately). The
  directory inode's own blocks MAY be included (GNU does).

  Verified: GNU `du -S /home/tcole/code 2>/dev/null` shows
  files-in-dir sums; ours shows only 4 (one dir inode block).

Fix: Change calculateDu to track direct_file_size separately
  (size of non-directory children at this level). With
  separate_dirs, set total_size = dir_own_size +
  direct_file_size and return dir_own_size + subtree_size
  unchanged (so parent accumulation is not affected).
  Requires splitting subtree_size into direct_files and
  subdirs.
```

```
[IMPORTANT] BLOCKSIZE and POSIXLY_CORRECT env vars not read
Location: src/du.zig:194-287 (resolveConfig)
Problem: The help text at lines 735-736 states:
  "Display values are in units of the first available SIZE
   from --block-size, and the DU_BLOCK_SIZE, BLOCK_SIZE and
   BLOCKSIZE environment variables. Otherwise, units default
   to 1024 bytes (or 512 if POSIXLY_CORRECT is set)."
  The GNU man page specifies the same precedence chain.
  None of this is implemented. resolveConfig never calls
  std.posix.getenv for BLOCKSIZE, DU_BLOCK_SIZE, or
  POSIXLY_CORRECT.
  Verified: BLOCKSIZE=4096 du /tmp produces 4-block output
  instead of expected 1-block output.
Fix: In resolveConfig, after applying explicit flags, check
  env vars in order: DU_BLOCK_SIZE, BLOCK_SIZE, BLOCKSIZE
  (only when no explicit --block-size flag was given). Also
  check POSIXLY_CORRECT; if set and block_size is still 1024,
  set it to 512.
```

```
[IMPORTANT] -n mapped to -P (no-follow symlinks) instead of
  ignore-nodump
Location: src/du.zig:47-48, 91, 162
Problem: The macOS man page defines -n as: "Ignore files
  and directories with user 'nodump' flag (UF_NODUMP) set."
  Our implementation assigns -n to the no_follow field and
  treats it as an alias for -P in resolveDerefMode (line 162:
  'P', 'n' => mode = .none).
  -n is macOS-only (not in GNU). macOS semantics are
  therefore the correct reference. Our behavior is completely
  wrong: a user passing -n to skip nodump files silently gets
  no-follow-symlinks behavior instead.
Fix: Remove 'n' from the resolveDerefMode scan (line 162).
  Add a separate `ignore_nodump: bool` field. On Linux,
  UF_NODUMP does not exist, so the flag is a no-op, but it
  must not change symlink-following behavior.
```

---

## Removed Finding (from original audit)

**-B blocksize rounding to 512** (was IMPORTANT, issue 4 in original):
GNU `-B` / `--block-size=SIZE` applies no 512-alignment constraint —
it scales by whatever SIZE is given. The rounding requirement appeared
only in the macOS man page. Since `-B` is in GNU and GNU is the primary
reference, this is not a bug. Removed.

---

## Test Coverage Gaps

The unit tests cover: parseBlockSize, formatHumanReadable,
resolveConfig flag combinations, -s, -c, -a, and printEntry.
None of the identified behavioral bugs are caught because the
tests do not compare output against a reference implementation
and the -b/-A tests use single files (no directories), so the
directory-apparent-size over-counting is invisible.

The integration test for `-b` checks only a single file, which
masks the directory-size bug. The `-I`, `-S`, `-L`, and
BLOCKSIZE env-var bugs have no integration test coverage.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4 |
| IMPORTANT | 2 |
| SUGGESTION | 0 |

**Assessment: BLOCKED**

The utility has four critical correctness bugs: apparent-size
calculation adds directory metadata bytes (inflating `-b`/`-A`
output), `-L` double-counts symlinked files, `-S` reports only
the directory inode size rather than the direct-file sum, and
`-I` is a complete stub despite being a SHOULD flag. Two
additional important issues (-n wrong semantic, BLOCKSIZE env
vars ignored) mean the help text actively misleads users.

One prior finding (-B rounding) is removed: it was a macOS-only
requirement not applicable to the GNU primary reference.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -A/-b: directory adds 4096 bytes in apparent mode
   — src/du.zig:335-341 (getFileSize)
2. [CRITICAL] -S shows only dir-inode blocks, not direct-file sum
   — src/du.zig:465,471 (calculateDu)
3. [CRITICAL] -L double-counts symlink targets (nlink == 1 guard)
   — src/du.zig:400 (inode dedup guard)
4. [CRITICAL] -I is a complete stub
   — src/du.zig:63,99 (ignore_pattern field and calculateDu)
5. [IMPORTANT] BLOCKSIZE/POSIXLY_CORRECT env vars not read;
   help text is false — src/du.zig:194 (resolveConfig)
6. [IMPORTANT] -n changes symlink mode instead of nodump
   — src/du.zig:47,91,162
```

REVIEW COMPLETE - BLOCKED
