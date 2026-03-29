# Integration Test Audit: chmod

**Date**: 2026-03-28
**Test file**: tests/utilities/chmod_test.sh
**Flags spec**: docs/specs/chmod-flags.md
**Test run**: 87 tests, 87 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 87 tests pass, but the suite has two confirmed bugs masked
by weak verification, four MUST-tier flags with zero behavioral
tests, and one MUST-tier behavioral divergence (umask handling)
that is entirely untested. The verbose output format contains
two GNU-incompatibilities that the existing tests cannot detect
because they check for non-empty output rather than content.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| chmod binary | binary exists | Weak |
| chmod --help | exit code 0 | Weak |
| chmod --version | exit code 0 | Weak |
| chmod 644 basic | exit code 0 | Weak |
| chmod 755 executable | exit code 0 | Weak |
| chmod 600 restricted | exit code 0 | Weak |
| chmod 600 verification | `stat` octal compare | Strong |
| chmod 755 verification | `stat` octal compare | Strong |
| chmod u=rw basic | exit code 0 | Weak |
| chmod g=r basic | exit code 0 | Weak |
| chmod o= basic | exit code 0 | Weak |
| chmod a=rwx all | exit code 0 | Weak |
| chmod u+x add execute | exit code 0 | Weak |
| chmod g+w add write | exit code 0 | Weak |
| chmod o+r add read | exit code 0 | Weak |
| chmod a+x add all execute | exit code 0 | Weak |
| chmod u-w remove write | exit code 0 | Weak |
| chmod g-x remove execute | exit code 0 | Weak |
| chmod o-r remove read | exit code 0 | Weak |
| chmod a-w remove all write | exit code 0 | Weak |
| chmod u+s setuid | exit code 0 | Weak |
| chmod g+s setgid | exit code 0 | Weak |
| chmod +t sticky | exit code 0 | Weak |
| chmod multiple modes | exit code 0 | Weak |
| chmod mixed operations | exit code 0 | Weak |
| chmod complex modes | exit code 0 | Weak |
| chmod -R 755 recursive | exit code 0 | Weak |
| chmod -R verification file1 | `stat` octal compare | Strong |
| chmod -R verification file2 | `stat` octal compare | Strong |
| chmod -R verification file3 | `stat` octal compare | Strong |
| chmod -R 644 makes dirs inaccessible | exit code 0 | Weak |
| chmod -R 644 on directory | `stat` octal compare | Strong |
| chmod -R 644 makes directory inaccessible | `[[ ! -x ]]` | Strong |
| chmod -R u+x recursive symbolic | exit code 0 | Weak |
| chmod -R single file | exit code 0 | Weak |
| chmod --reference basic | exit code 0 | Weak |
| chmod --reference verification | `stat` octal compare (both files) | Strong |
| chmod --reference multiple | exit code 0 | Weak |
| chmod -v produces output | `[[ -n "$output" ]]` | Weak |
| chmod -v no change output | `[[ -n "$output" ]]` | Weak — and masks bug |
| chmod -c shows changes | `[[ -n "$output" ]]` | Weak |
| chmod -c no output for no change | `[[ -z "$output" ]]` | Moderate |
| chmod -f suppresses errors | `[[ -z "$output" ]]` | Moderate |
| chmod -f successful operation | exit code 0 | Weak |
| chmod -Rv combination | exit code 0 | Weak |
| chmod -cf combination | exit code 0 | Weak |
| chmod invalid octal 999 | exit non-zero | Moderate |
| chmod invalid octal 888 | exit non-zero | Moderate |
| chmod invalid symbolic xyz | exit non-zero | Moderate |
| chmod invalid operator u%r | exit non-zero | Moderate |
| chmod non-existent file | exit non-zero | Moderate |
| chmod in readonly dir | exit code 0 | Weak |
| chmod no arguments | exit non-zero | Moderate |
| chmod mode only | exit non-zero | Moderate |
| chmod 4755 setuid | exit code 0 | Weak |
| chmod 2755 setgid | exit code 0 | Weak |
| chmod 1755 sticky | exit code 0 | Weak |
| chmod 6755 setuid+setgid | exit code 0 | Weak |
| chmod u+s,g+s special | exit code 0 | Weak |
| chmod =rwx,+t special | exit code 0 | Weak |
| chmod g=u copy user to group | exit code 0 | Weak |
| chmod o=g copy group to other | exit code 0 | Weak |
| chmod u=o copy other to user | exit code 0 | Weak |
| chmod multiple files | exit code 0 | Weak |
| chmod multiple files verification (x2) | `stat` octal compare | Strong |
| chmod partial failure | exit non-zero | Moderate |
| chmod --recursive | exit code 0 | Weak |
| chmod --verbose | exit code 0 | Weak |
| chmod --changes | exit code 0 | Weak |
| chmod --silent | exit code 0 | Weak |
| POSIX: octal mode | exit code 0 | Weak |
| POSIX: symbolic mode | exit code 0 | Weak |
| POSIX: recursive | exit code 0 | Weak |
| chmod success exit code | exit code 0 | Moderate |
| chmod failure exit code | exit code 1 | Moderate |
| chmod -R large tree | exit code 0 | Weak |
| chmod -R large tree verification | `stat` octal compare (1 file) | Moderate |
| files 644, directories 755 (proper pattern) | `stat` octal compare | Strong |
| chmod u+t sets sticky bit | exit code 0 | Weak |
| chmod u+t sticky bit verification | `stat` octal compare | Strong |
| chmod g+t sets sticky bit | exit code 0 | Weak |
| chmod g+t sticky bit verification | `stat` octal compare | Strong |
| chmod a-t removes sticky bit | exit code 0 | Weak |
| chmod a-t sticky bit removed | `stat` octal compare | Strong |
| chmod inaccessible dir exits non-zero | exit non-zero | Moderate |
| chmod inaccessible dir reports Permission denied | stderr substring match | Strong |

---

## Confirmed Bugs Masked by Weak Tests

### Bug 1: Verbose no-change format is wrong

**Location**: tests/utilities/chmod_test.sh:197-203

The test "chmod -v no change output" only checks `[[ -n "$output" ]]`.
The actual output when the mode does not change is:

```
mode of 'file' changed from 644 (rw-r--r--) to 644 (rw-r--r--)
```

GNU coreutils emits:

```
mode of 'file' retained as 0644 (rw-r--r--)
```

Two divergences in one line: the word "retained" vs "changed from X
to X", and the 4-digit zero-prefixed octal (0644) vs 3-digit (644).
The test passes because any non-empty string satisfies it.

### Bug 2: Verbose changed-mode format omits leading zero in octal

**Location**: tests/utilities/chmod_test.sh:188-194 (and all -v tests)

When a mode *does* change, vibeutils emits:

```
mode of 'file' changed from 755 (rwxr-xr-x) to 644 (rw-r--r--)
```

GNU emits:

```
mode of 'file' changed from 0755 (rwxr-xr-x) to 0644 (rw-r--r--)
```

The leading `0` is absent in vibeutils output. No test checks the
exact string, so this goes undetected.

---

## Missing Coverage: MUST-Tier Flags

The following flags are rated MUST in docs/specs/chmod-flags.md but
have no behavioral integration test.

### -h (no-dereference) — MUST

There is no test that creates a symlink, runs `chmod -h`, and
verifies that the symlink's own mode changed while the target's
mode did not. This is the entire purpose of the flag.

### -H (traverse command-line symlinks with -R) — MUST

There is no test that creates a symlink-to-directory, runs
`chmod -R -H`, and verifies that the target directory's contents
were recursively changed.

### -L (traverse all symlinks with -R) — MUST

There is no test verifying that `-R -L` follows every encountered
symlink to a directory during traversal.

### -P (no traversal, default with -R) — MUST

There is no test verifying that `-R -P` (or `-R` alone) leaves
symlink targets unchanged.

---

## Missing Coverage: SHOULD-Tier Flags

### --preserve-root / --no-preserve-root — SHOULD

No integration test. The unit tests in chmod.zig cover parse-only
behavior; no integration test verifies that `--preserve-root -R /`
exits non-zero with a message, nor that `--no-preserve-root`
overrides it.

### --dereference — SHOULD

No behavioral test. This is the inverse of `-h`; a test should
verify that the default (and explicit `--dereference`) changes the
target of a symlink, not the symlink itself.

---

## Missing Coverage: Behavioral Gaps

### Umask interaction with no-who symbolic modes

When no `who` is specified in a symbolic mode (e.g., `+w`, `+x`),
POSIX and GNU require that the umask mask the result: bits set in the
umask must not be added. Vibeutils does not implement this. With
umask 002:

- GNU `chmod +w file` starting from 644 produces 664 (others-write
  masked by umask bit 002).
- Vibeutils produces 666 (umask ignored).

This is a correctness bug. There is no integration test for this
class of mode at all.

### +X (conditional execute) — no behavioral integration test

The unit tests in chmod.zig cover `+X` logic. The integration test
suite has no test for `+X`, which should skip adding execute on a
regular file that has no existing execute bit, but should add it
when any execute bit is already set or the target is a directory.

### Verbose output stream (stdout vs stderr)

GNU verbose output goes to stdout. Existing tests use `2>&1`,
capturing both streams together. There is no test that verifies
`-v` output arrives on stdout and not stderr.

### Mode-copy clauses (`g=u-w`, `=rw,+X`) — no output verification

The tests for `g=u`, `o=g`, and `u=o` (mode copying) are exit-code
only. None verify the resulting permission bits.

### Symbolic mode: `=` clears unspecified bits

`chmod o= file` should clear all other bits. The test calls
`test_command_succeeds` (exit code only) but never reads back the
mode to confirm bits were cleared.

### Special bits after 4-digit octal

`chmod 4755`, `chmod 2755`, `chmod 1755`, `chmod 6755` tests are
exit-code only. None verify that the setuid, setgid, or sticky bits
are actually set in the resulting inode.

---

## Issues by Severity

```
[IMPORTANT] Verbose no-change output emits wrong text
Location: tests/utilities/chmod_test.sh:197-203
Problem: "chmod -v no change output" passes because it checks
         [[ -n "$output" ]], but the output says "changed from X
         to X" instead of GNU's "retained as 0X". The test
         validates the bug rather than catching it.
Fix: Replace the non-empty check with an exact-match:
     [[ "$verbose_output" == *"retained as"* ]]
     Then fix src/chmod.zig to emit "retained as 0NNN" when
     old_mode == new_mode.

[IMPORTANT] Verbose output omits leading zero from octal values
Location: tests/utilities/chmod_test.sh:188-194
Problem: Output is "changed from 755" instead of GNU's
         "changed from 0755". No test checks the exact format.
Fix: Add an exact format test:
     [[ "$verbose_output" == *"0644"* ]]
     Then fix src/chmod.zig to zero-prefix octal in verbose output.

[IMPORTANT] No behavioral test for -h (no-dereference) — MUST tier
Location: tests/utilities/chmod_test.sh (missing)
Problem: The flag's purpose — operating on the symlink itself rather
         than its target — is never exercised.
Fix: Create a symlink, run chmod -h 600 <link>, stat both link and
     target, verify target unchanged.

[IMPORTANT] No behavioral test for -H, -L, -P traversal — MUST tier
Location: tests/utilities/chmod_test.sh (missing)
Problem: Three symlink-traversal flags are implemented but untested
         at the integration level.
Fix: Write one test per flag using a symlink-to-directory setup,
     verify target contents changed (-H, -L) or did not change (-P).

[IMPORTANT] Umask not applied for no-who symbolic modes (bug + no test)
Location: tests/utilities/chmod_test.sh (missing)
Problem: chmod +w with umask 002 should not set others-write.
         vibeutils ignores the umask and sets it. Neither the bug
         nor the correct behavior is tested.
Fix: Add test that sets umask to known value, runs chmod +w,
     verifies others-write was not added. Then fix src/chmod.zig
     to consult umask when who is absent.

[SUGGESTION] 30+ symbolic mode tests are exit-code only
Location: tests/utilities/chmod_test.sh:48-76, 289-298
Problem: Symbolic add/remove/assign tests confirm the command does
         not crash but do not verify the resulting permission bits.
Fix: Add stat-based verification after each symbolic mode test,
     or at minimum after a representative set: u=rw, u+x, u-w,
     g=u (mode copy), o= (clear).

[SUGGESTION] Special bits (setuid, setgid, sticky) not verified
Location: tests/utilities/chmod_test.sh:283-290
Problem: 4-digit octal tests (4755, 2755, 1755, 6755) are
         exit-code only.
Fix: After each, stat the file and confirm the expected 4-digit
     octal (e.g., 4755, 2755, 1755).

[SUGGESTION] --preserve-root has no integration test
Location: tests/utilities/chmod_test.sh (missing)
Problem: The safety guard against recursive operation on / is
         only covered by unit tests.
Fix: Test that chmod --preserve-root -R 755 / exits non-zero and
     emits the expected error message.
```

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Verbose no-change text wrong ("changed" not "retained")
   — tests/utilities/chmod_test.sh:197-203 + src/chmod.zig
2. [IMPORTANT] Verbose octal missing leading zero — same locations
3. [IMPORTANT] No -h behavioral test — tests/utilities/chmod_test.sh
4. [IMPORTANT] No -H/-L/-P behavioral tests — tests/utilities/chmod_test.sh
5. [IMPORTANT] Umask bug + missing test — src/chmod.zig +
   tests/utilities/chmod_test.sh
6. [SUGGESTION] Symbolic mode tests: add stat verification
   — tests/utilities/chmod_test.sh:48-76, 289-298
7. [SUGGESTION] Special bits tests: add stat verification
   — tests/utilities/chmod_test.sh:283-290
8. [SUGGESTION] --preserve-root integration test
   — tests/utilities/chmod_test.sh
```

REVIEW COMPLETE - NEEDS_FIXES
