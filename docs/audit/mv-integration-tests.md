# Integration Test Audit: mv

**Date**: 2026-03-28
**Test file**: tests/utilities/mv_test.sh
**Run result**: 95 tests, 94 passed, 0 failed, 1 skipped

## Executive Summary

NEEDS_FIXES

All 94 active tests pass. Core flag coverage is thorough and
most behavioral verification is strong. However, the `-h` and
`-b`/`--backup` SHOULD-tier flags have no integration tests,
several flag-interaction tests make no assertion about which
flag won, and the `-i` prompt behavior (feeding `y` to
confirm an overwrite) is completely untested.

One test emits an abort signal during execution (line 343,
"mv file to itself") that leaks to the terminal but is
otherwise caught by the exit-code check.

---

## Test Inventory

| Test Name (abbreviated) | Verification Type | Verdict |
|-------------------------|-------------------|---------|
| mv binary exists | binary check | STRONG |
| mv --help / --version | exit-code | STRONG |
| mv basic rename | exit-code + output + src gone | STRONG |
| mv file to directory | exit-code + output + src gone | STRONG |
| mv multiple files to directory | output x3 + src gone x3 | STRONG |
| mv empty file | exit-code + empty output | STRONG |
| mv empty directory | exit-code + dir exists + src gone | STRONG |
| mv directory with contents | output x2 | STRONG |
| mv directory into directory | output | STRONG |
| mv with force flag (-f) | exit-code + output + src gone | STRONG |
| mv force to new file | exit-code + output | STRONG |
| mv interactive mode (no tty) | manual `$?` accept-any | WEAK |
| mv interactive to new file | exit-code + output | STRONG |
| mv verbose output (-v) | stderr/stdout pattern | MODERATE |
| mv verbose operation (content) | output | STRONG |
| mv verbose multiple files | stdout pattern | MODERATE |
| mv no-clobber existing (-n) | exit-code + output + src kept | STRONG |
| mv no-clobber to new | exit-code + output | STRONG |
| mv force+verbose output | stdout pattern | MODERATE |
| mv interactive+force | exit-code + output | STRONG |
| mv no-clobber+force | content branching check | MODERATE |
| mv file with spaces | exit-code + output | STRONG |
| mv file with special chars | exit-code + output | STRONG |
| mv unicode filename | exit-code + output | STRONG |
| mv very long filename | conditional exit-code | MODERATE |
| mv binary file | exit-code + size | MODERATE |
| mv non-existent source | `test_command_fails` | WEAK |
| mv to non-existent directory | `test_command_fails` | WEAK |
| mv file to itself | `test_command_fails` + abort leak | WEAK |
| mv directory to its child | `test_command_fails` | WEAK |
| mv permission denied | conditional `$?` | MODERATE |
| mv no operands / single operand | `test_command_fails` x2 | WEAK |
| mv multiple files to non-directory | `test_command_fails` | WEAK |
| mv invalid flag / short flag | `test_command_fails` x2 | WEAK |
| mv symlink preserved | `[[ -L ]]` + target unchanged | STRONG |
| mv file to symlink dir | exit-code + output | STRONG |
| mv success / error exit code | manual `$?` checks | MODERATE |
| mv POSIX atomic operation | src gone + dest exists | STRONG |
| mv large file | exit-code + size check | STRONG |
| mv cross-filesystem | skipped | — |
| mv directory with trailing slash | exit-code + output | STRONG |
| mv hidden file | exit-code + output | STRONG |
| mv file starting with dash (--) | exit-code + output | STRONG |
| mv chain moves | exit-code + output + intermediates gone | STRONG |
| mv overwrite hint shown | stderr pattern | STRONG |
| mv no hint with -i | stderr absence | STRONG |
| mv no hint without -f | stderr absence | STRONG |
| mv no hint for new destination | stderr absence | STRONG |
| mv -v arrow on stdout (regression) | stream separation | STRONG |
| mv -v arrow not on stderr (regression) | stream separation | STRONG |
| mv symlink is still symlink (regression) | `[[ -L ]]` | STRONG |

---

## Weak Tests

### [IMPORTANT] `mv interactive mode (non-interactive env)` — line 166
The test feeds `/dev/null` to `-i` with an existing
destination and accepts any exit code 0 as a PASS. This
covers neither of the two behaviors that matter:
1. With empty stdin, the overwrite should be skipped
   (destination unchanged, source still present).
2. With `y` on stdin, the overwrite should proceed.

The follow-up "mv interactive to new file" covers case where
destination does not exist, which does not exercise the
prompt at all.

**Fix**: Split into two tests:

```bash
# Case 1: empty stdin → skip
local i_src=$(create_temp_file "New interactive")
local i_dst=$(create_temp_file "Old interactive")
"$binary" -i "$i_src" "$i_dst" </dev/null >/dev/null 2>&1
test_command_output "mv -i empty stdin preserves dest" \
    "Old interactive" cat "$i_dst"
if [[ -e "$i_src" ]]; then
    print_test_result "mv -i empty stdin source kept" "PASS"
else
    print_test_result "mv -i empty stdin source kept" "FAIL"
fi

# Case 2: 'y' on stdin → overwrite
local i_src2=$(create_temp_file "New interactive 2")
local i_dst2=$(create_temp_file "Old interactive 2")
echo "y" | "$binary" -i "$i_src2" "$i_dst2" >/dev/null 2>&1
test_command_output "mv -i y response overwrites dest" \
    "New interactive 2" cat "$i_dst2"
```

### [IMPORTANT] `mv interactive+force` — line 256
Tests that the combination exits 0 and the destination has
the source content, which passes for `-f` alone. Does not
verify that the last flag wins according to GNU/POSIX rules
(`-f` is last here, so `-f` should prevail). If both were
reversed to `-f -i`, the result should differ and there is
no test for that case.

**Fix**: Add a `-f -i` case (with `-i` last) and verify
that it prompts:

```bash
# -i last: should prompt
local fi_src=$(create_temp_file "fi source")
local fi_dst=$(create_temp_file "fi dest")
echo "y" | "$binary" -f -i "$fi_src" "$fi_dst" >/dev/null 2>&1
test_command_output "mv -f -i (last flag -i wins)" \
    "fi source" cat "$fi_dst"
```

### [IMPORTANT] `mv no-clobber+force` — line 263
Runs `mv -n -f` without a `test_command_exit_code` wrapper,
then branches based on which content won. Both branches
print PASS. This means the test accepts any behavior — `-n`
winning, `-f` winning, or a silent error — as correct. GNU
behavior is that the last flag wins (`-f` here), so the
destination should be overwritten.

**Fix**: Assert the expected content directly:

```bash
test_command_exit_code "mv no-clobber+force (-f last wins)" \
    0 "$binary" -n -f "$nf_src" "$nf_dest"
test_command_output "mv no-clobber+force dest content" \
    "No-clobber force" cat "$nf_dest"
```

### [SUGGESTION] Error condition tests — lines 335-377
Eight tests use `test_command_fails` (non-zero exit only):
non-existent source, non-existent directory, file to itself,
directory to child, no operands, single operand, multiple
files to non-directory, invalid flags. None verify that an
error message appears on stderr. A silent non-zero exit would
pass every one of them.

**Fix**: For the most critical cases (non-existent source,
same-file), also assert a non-empty stderr:

```bash
local err_stderr
err_stderr=$("$binary" "/nonexistent/source.txt" \
    "$TEMP_DIR/dest.txt" 2>&1 >/dev/null)
if [[ -n "$err_stderr" ]]; then
    print_test_result "mv non-existent source emits error" "PASS"
else
    print_test_result "mv non-existent source emits error" "FAIL"
fi
```

---

## Missing Coverage

| Flag | Tier | Has Integration Test? | Strength |
|------|------|-----------------------|---------|
| -f   | MUST | Yes (content + src gone) | STRONG |
| -i   | MUST | Yes, but prompt path untested | WEAK |
| -v   | MUST | Yes (pattern match) | MODERATE |
| -n   | SHOULD | Yes (content preserved + src kept) | STRONG |
| -h   | SHOULD | **No** | — |
| -b   | SHOULD | **No** | — |
| --backup | SHOULD | **No** | — |

### `-h` flag (do not follow symlink at target)

The `-h` flag is implemented (`no_follow_symlink`) and has
unit tests in `src/mv.zig` (lines 1178-1215), but there is
no integration test that runs the binary with `-h` and
verifies the end-to-end behavior: when the destination is a
symlink to a directory, `mv -h src symlink` should rename
`src` to the path `symlink` (replacing the symlink) rather
than moving `src` into the directory the symlink points to.

**Missing test**:

```bash
local h_target=$(create_temp_dir)
local h_symlink="$TEMP_DIR/h_dir_symlink"
ln -s "$h_target" "$h_symlink"
local h_src=$(create_temp_file "h flag source")

test_command_exit_code "mv -h with symlink target" 0 \
    "$binary" -h "$h_src" "$h_symlink"

# The symlink should now be gone (replaced by the file)
if [[ ! -L "$h_symlink" ]] && [[ -f "$h_symlink" ]]; then
    print_test_result "mv -h replaces symlink not target dir" "PASS"
else
    print_test_result "mv -h replaces symlink not target dir" "FAIL" \
        "Expected regular file, found symlink or missing"
fi
# The original directory should still exist (not moved into)
if [[ -d "$h_target" ]]; then
    print_test_result "mv -h target directory unchanged" "PASS"
else
    print_test_result "mv -h target directory unchanged" "FAIL"
fi
```

### `-b` / `--backup` flag

The flag is implemented (see `src/mv.zig` line 679-688) with
a unit test, but no integration test exercises it end-to-end.
A backup test must verify both that `dest~` is created with
the original destination content and that the destination now
holds the source content.

**Missing test**:

```bash
local b_src=$(create_temp_file "backup source")
local b_dst=$(create_temp_file "backup existing")

test_command_exit_code "mv -b creates backup" 0 \
    "$binary" -b "$b_src" "$b_dst"
test_command_output "mv -b dest has source content" \
    "backup source" cat "$b_dst"
test_command_output "mv -b backup file has original content" \
    "backup existing" cat "${b_dst}~"
if [[ ! -e "$b_src" ]]; then
    print_test_result "mv -b source removed" "PASS"
else
    print_test_result "mv -b source removed" "FAIL"
fi

# --backup long form
local bl_src=$(create_temp_file "backup long source")
local bl_dst=$(create_temp_file "backup long existing")
test_command_exit_code "mv --backup creates backup" 0 \
    "$binary" --backup "$bl_src" "$bl_dst"
test_command_output "mv --backup backup file has original" \
    "backup long existing" cat "${bl_dst}~"
```

---

## Abort Signal Leak

The "mv file to itself" test at line 343 causes the binary to
abort (signal 6), which the test runner correctly records as a
non-zero exit code and marks PASS. However, the abort message
leaks to the terminal:

```
/home/tcole/code/vibeutils/tests/lib/common.sh: line 289:
352325 Aborted  "$@" > "$stdout_file" 2> "$stderr_file"
```

This is not a test failure but signals that the binary panics
(via `@panic` or `unreachable`) on same-file detection rather
than returning a graceful error exit. The correct behavior is
to print an error message and exit with code 1.

---

## System Comparison

The macOS man page (`docs/specs/mv-macos.txt`) lists `-h` as
moving the source to the symlink path rather than following
it. This flag is implemented in the binary but has no
integration test confirming end-to-end behavior.

The GNU spec adds `-b`/`--backup`, which is also implemented
but untested at the integration level. GNU's last-flag-wins
rule for `-f`, `-i`, `-n` conflicts is partially tested
(`-i -f`, `-n` alone), but the reverse orderings (`-f -i`,
`-f -n`) are not exercised.

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| F1 | IMPORTANT | `-i` test does not verify skip-on-empty-stdin or overwrite-on-y; prompt path entirely untested |
| F2 | IMPORTANT | `-i -f` combination verifies only exit-code + content; reverse ordering (`-f -i`) not tested |
| F3 | IMPORTANT | `-n -f` combination test accepts any outcome as PASS; GNU last-flag-wins rule not asserted |
| F4 | IMPORTANT | `-h` flag (SHOULD) has no integration test; end-to-end symlink-not-followed behavior unverified |
| F5 | IMPORTANT | `-b`/`--backup` flag (SHOULD) has no integration test; backup file content not verified |
| F6 | SUGGESTION | Eight error-condition tests check only non-zero exit; stderr message not verified |
| F7 | SUGGESTION | Binary aborts (signal 6) on same-file move instead of a clean error exit |
| F8 | SUGGESTION | `-v` tests use loose `*pattern*` matching; pattern can match source filename or arrow anywhere in combined output |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -i test: add empty-stdin skip and y-response
   overwrite cases — line 166
2. [IMPORTANT] -n -f combination: assert GNU last-flag-wins,
   not accept-any — line 263
3. [IMPORTANT] Add integration test for -h (symlink not
   followed at target) — missing
4. [IMPORTANT] Add integration test for -b/--backup
   (verify backup content + dest content) — missing
5. [IMPORTANT] -i -f / -f -i ordering: add reversed-flag
   test — line 256
6. [SUGGESTION] Fix binary: same-file move should return
   exit 1, not abort — src/mv.zig
7. [SUGGESTION] Add stderr-message checks to 2-3 error
   condition tests — lines 335-377
8. [SUGGESTION] Tighten -v tests to use stream-separation
   pattern from the regression test — line 187
```

REVIEW COMPLETE - NEEDS_FIXES
