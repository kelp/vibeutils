# Integration Test Audit: cp

**Date**: 2026-03-28
**Test file**: tests/utilities/cp_test.sh
**Run result**: 131 tests, 131 passed, 0 failed

## Executive Summary

PASS WITH ISSUES

All 131 tests pass. Core flag coverage is solid and most
behavioral verification is strong. However, seven SHOULD-tier
flags have no integration test at all (`-b`, `-c`, `-l`, `-s`,
`-S`, `-x`, `-X`), and several existing tests verify only
exit-code or existence rather than the behavior the flag is
supposed to change.

---

## Test Inventory

| Test Name (abbreviated) | Verification Type | Verdict |
|-------------------------|-------------------|---------|
| cp single file | exit-code + output | STRONG |
| cp to directory (content) | output | STRONG |
| cp multiple files to directory | output x2 | STRONG |
| cp empty file content | output | STRONG |
| cp without force to existing file | manual `$?` + no-op | WEAK |
| cp with force flag (content) | output | STRONG |
| cp interactive mode (CI environment) | manual `$?` | WEAK |
| cp interactive produced output | `[[ -n "$actual_content" ]]` | WEAK |
| cp interactive to new file (content) | output | STRONG |
| cp directory without -r flag | `test_command_fails` | WEAK |
| cp directory without -r cleanup | filesystem check | MODERATE |
| cp directory with -r flag (content x4) | output | STRONG |
| cp with preserve (content) | output | STRONG |
| cp preserve user permissions | octal comparison | STRONG |
| cp symlink with -d (is symlink) | `[[ -L ]]` | STRONG |
| cp -H follows command-line symlink | `[[ -f ]]` | STRONG |
| cp -H preserves inner symlinks | `[[ -L ]]` | STRONG |
| cp -L converts symlinks to files | `[[ -f && ! -L ]]` + output | STRONG |
| cp -P preserves symlinks | `[[ -L ]]` + target check | STRONG |
| cp -n preserves original | output | STRONG |
| cp -v shows copy operation | stderr/stdout pattern | STRONG |
| cp -a preserves permissions | octal comparison | STRONG |
| cp -a preserves timestamps | mtime comparison | STRONG |
| cp -a preserves symlinks | `[[ -L ]]` | STRONG |
| cp -f -i combination | `$?` + `[[ -f && -s ]]` | WEAK |
| cp -r -p combination | `$?` + `[[ -f ]]` | WEAK |
| cp --force (content) | output | STRONG |
| cp --recursive (content) | output | STRONG |
| cp --preserve (content) | output only (no mtime/mode check) | WEAK |
| cp --no-dereference preserves symlink | `[[ -L ]]` | STRONG |
| cp overwrite hint shown | stderr pattern | STRONG |
| cp -v output on stdout | stream check | STRONG |
| cp -f read-only dir exits non-zero | exit-code | MODERATE |
| cp -f read-only dir reports error on stderr | `[[ -n "$ro_err" ]]` | MODERATE |
| cp --backup still works (regression) | exit-code + `[[ -f ]]` | STRONG |
| error conditions (5 tests) | `test_command_fails` | WEAK |
| POSIX compliance (4 tests) | output | STRONG |
| edge cases: binary, large, special chars, etc. | cmp / output | STRONG |

---

## Weak Tests

### [IMPORTANT] `cp interactive mode (CI environment)` — line 78
The test pipes `/dev/null` to `-i` and accepts any exit code.
When stdin is empty, `-i` on an overwrite silently skips the
copy in many implementations (exit 0, destination unchanged).
The test passes in both the "overwrote" and "skipped" cases.
The follow-up "cp interactive produced output" check passes
as long as *any* content is in the destination — even the
pre-existing "Interactive dest" string placed there before
the flag fires.

**Fix**: After feeding `/dev/null`, verify the destination
still has the *original* content (copy was skipped, not
performed). That is the correct POSIX behavior for `-i` with
no `y` response.

```bash
"$binary" -i "$interactive_src" "$interactive_dst" </dev/null >/dev/null 2>&1
test_command_output "cp -i with empty stdin preserves original" \
    "Interactive dest" cat "$interactive_dst"
```

### [IMPORTANT] `cp --preserve` — line 723
The long-option form `--preserve` only checks that the
command exits 0 and the content is correct. It does not
verify that timestamps or permissions are actually preserved.
The short-form `-p` test at line 148 does check permissions,
but that test does not cover the long-option path. If
`--preserve` were accidentally mapped to a no-op, this test
would not catch it.

**Fix**: After `cp --preserve`, compare source and destination
mtimes the same way the `-a` timestamp test does (lines
383-388).

### [IMPORTANT] `cp -f -i combination` — line 223
Tests only that the command exits 0 and that *some* file
exists with *some* content (`-f && -s`). Does not verify
which flag won or what the destination content is. The
comment says "test without making assumptions about behavior"
but the correct GNU/POSIX behavior is defined: `-i` overrides
`-f`, so with stdin closed the copy should be skipped.

**Fix**: Feed `y\n` via process substitution for one test
(expect overwrite) and `/dev/null` for another (expect
original preserved).

### [SUGGESTION] `cp -r -p combination` — line 247
Accepts a non-zero exit code and falls back to checking file
existence. While the comment acknowledges CI filesystem
variability, a non-zero exit from `-r -p` means attribute
preservation failed silently. The test can then pass without
`-p` doing anything useful.

**Fix**: Always assert exit 0, or skip on known-hostile
filesystems (e.g., detect tmpfs and skip the
attribute-preservation assertion only, not the whole test).

---

## Missing Coverage

| Flag | Tier | Has Integration Test? | Strength |
|------|------|-----------------------|---------|
| -a   | MUST | Yes (permissions, timestamps, symlinks) | STRONG |
| -b   | SHOULD | **No** | — |
| -c   | SHOULD | **No** | — |
| -d   | SHOULD | Yes (symlink preserved) | STRONG |
| -f   | MUST | Yes (content verified) | STRONG |
| -H   | MUST | Yes (filesystem check) | STRONG |
| -i   | MUST | Yes, but behavior wrong | WEAK |
| -l   | SHOULD | **No** | — |
| -L   | MUST | Yes (file type + content) | STRONG |
| -n   | SHOULD | Yes (content preserved) | STRONG |
| -N   | SHOULD | **No** | — |
| -p   | MUST | Yes (permissions) | STRONG |
| -P   | MUST | Yes (symlink + target) | STRONG |
| -R   | MUST | Yes (content verified) | STRONG |
| -s   | SHOULD | **No** | — |
| -S   | SHOULD | **No** | — |
| -v   | MUST | Yes (stdout stream check) | STRONG |
| -x   | SHOULD | **No** | — |
| -X   | SHOULD | **No** | — |
| --backup | SHOULD | Yes (file existence only) | MODERATE |
| --parents | SHOULD | **No** | — |
| --preserve | SHOULD | Yes (content only, no mtime) | WEAK |

---

## Expected Output Issues

### `cp -v` output format not pinned — lines 329-351
The `-v` test checks that both the source filename and `"->`
appear somewhere in stdout or stderr combined. This is
deliberately loose to tolerate platform differences, but it
means any string containing `->` anywhere passes — including
error messages. The regression test at line 812 tightens this
for stdout, but the primary test at line 329 still accepts
stderr as a valid output stream for the arrow.

The CLAUDE.md spec and the regression test at line 812 imply
the correct stream is stdout. The primary test should be
equally strict.

### `--backup` only checks file existence — lines 856-863
The test verifies that `${backup_dst}~` is created. It does
not verify the backup file contains the *original* content of
the destination, nor does it verify the destination now
contains the source content. A buggy implementation that
creates an empty `~` file would pass.

**Fix**:
```bash
test_command_output "cp --backup backup file contains original" \
    "backup regression existing" cat "${backup_dst}~"
test_command_output "cp --backup dest has source content" \
    "backup regression source" cat "$backup_dst"
```

---

## System Comparison

The macOS man page (`docs/specs/cp-macos.txt`) lists `-c`
(clonefile), `-N` (suppress flags with `-p`), `-S` (no sparse
holes), `-X` (no extended attributes), and `-x` (one
filesystem) as implemented. The implementation marks `-c` and
`-X` as no-ops. None of these five flags have integration
tests confirming their behavior (or their no-op status).

The GNU spec adds `-b` (backup), `-l` (hard link), `-s`
(symlink), `-S` (backup suffix), `--parents`, and
`--preserve`. The unit tests in `src/cp.zig` cover `-b`,
`-l`, `-s`, `-S`, and `--parents` at the unit level but
**none of these have integration tests**.

---

## Missing Test Scenarios

1. **`-b` creates a backup**: copy over an existing file
   without `--backup` spelled out; verify `~` file appears
   and destination is updated.

2. **`-S` changes backup suffix**: copy with `-b -S .orig`;
   verify `.orig` backup exists, not `~`.

3. **`-l` creates a hard link**: after copy, verify source
   and destination share the same inode number.

4. **`-s` creates a symlink**: after copy, verify destination
   `[[ -L ]]` and `readlink` returns the source path.

5. **`-x` stays on one filesystem**: recursively copy a
   directory that contains a mount point; verify the mount
   point's contents are not copied. (This is environment-
   dependent; skip if no secondary mount is available, but
   at minimum test that the flag is accepted and basic copy
   still works.)

6. **`-X` skips extended attributes**: macOS-only; verify
   that xattrs present on the source are absent on the
   destination. Skip on Linux.

7. **`-N` with `-p`**: verify that BSD file flags are
   *not* copied when `-N -p` is used. macOS-only.

8. **`--parents` preserves directory structure**: copy
   `a/b/c.txt` to a dest dir; verify
   `dest/a/b/c.txt` is created.

9. **`--preserve` actually preserves mtime**: verify the
   destination mtime matches the source after `--preserve`.

10. **`-i` with no response skips overwrite**: verify the
    destination is unchanged when stdin is empty.

11. **`-i` with `y` response overwrites**: verify the
    destination is updated when `y` is fed to stdin.

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| F1 | IMPORTANT | `-i` test does not verify that the overwrite was skipped when stdin is empty; passes regardless of behavior |
| F2 | IMPORTANT | `--preserve` long-option test checks only content, not mtime or permissions; a no-op `--preserve` would pass |
| F3 | IMPORTANT | `-f -i` combination test makes no assertion about which flag won or what the destination contains |
| F4 | IMPORTANT | `--backup` test checks only that `~` file exists, not its content or the destination content |
| F5 | IMPORTANT | Seven SHOULD flags (`-b`, `-c`, `-l`, `-s`, `-S`, `-x`, `-X`) have no integration tests |
| F6 | IMPORTANT | `--parents` (SHOULD) has no integration test |
| F7 | SUGGESTION | `-v` primary test accepts stderr for the `->` arrow; regression test at line 812 is stricter and should replace the looser check |
| F8 | SUGGESTION | `-r -p` combination test accepts non-zero exit and only checks file existence; attribute preservation may silently fail |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -i test verifies wrong behavior — lines 78-91
2. [IMPORTANT] --preserve long option test: add mtime check — line 723
3. [IMPORTANT] --backup test: verify content of backup and dest — lines 856-863
4. [IMPORTANT] -f -i combination: assert what flag won — lines 223-237
5. [IMPORTANT] Add integration tests for -b and -S — missing
6. [IMPORTANT] Add integration tests for -l, -s — missing
7. [IMPORTANT] Add integration test for --parents — missing
8. [IMPORTANT] Add integration tests for -x, -X, -c (or document as no-op) — missing
9. [SUGGESTION] Tighten -v test to require stdout only — line 329
10. [SUGGESTION] Fix -r -p test to assert exit 0 — lines 247-258
```

REVIEW COMPLETE - NEEDS_FIXES
