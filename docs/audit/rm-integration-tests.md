# rm Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/rm_test.sh`
**Spec:** `docs/specs/rm-flags.md`, `docs/specs/rm-macos.txt`
**Result:** NEEDS_FIXES

---

## Run Results

```
Tests run: 91
Passed:    91
Failed:    0
```

All 91 tests pass. The issues below are coverage gaps,
not failures.

---

## Flag Coverage Matrix

| Flag | Tier | Has output test | Exit-code-only | Gap |
|------|------|----------------|----------------|-----|
| -f | MUST | yes (stderr suppression) | — | none |
| --force | MUST | yes | — | none |
| -i | MUST | yes (file removed/preserved) | — | none |
| -r | MUST | yes (dir gone) | — | none |
| -R | MUST | yes (dir gone) | — | none |
| --recursive | MUST | yes (dir gone) | — | none |
| -d | MUST | NO | NO | MISSING entirely |
| -v | MUST | yes (regex on output) | — | filename not verified |
| --verbose | MUST | yes (regex on output) | — | filename not verified |
| -P | MUST | NO | NO | MISSING entirely |
| -I | SHOULD | yes (files removed/preserved) | — | none |
| -x | SHOULD | NO | NO | MISSING entirely |
| -W | SHOULD | NO | NO | MISSING entirely |
| --preserve-root | SHOULD | exit-code only | yes | weak |
| --no-preserve-root | SHOULD | NO | NO | MISSING entirely |

---

## Test Inventory

### Passing with good behavioral coverage
- Single/multiple/empty file removal with filesystem
  verification (lines 28-52)
- `-f` on nonexistent files: exit code + stderr suppression
  (lines 60-90)
- `-f` on write-protected file: exit code + filesystem check
  (lines 70-77)
- `-i` yes/no: file-presence verification (lines 96-123)
- `-I` threshold behavior: file-presence verification
  (lines 131-191)
- `-r`/`-R`/`--recursive`: filesystem verification
  (lines 212-253)
- `-v` verbose: output regex `removed.*'.*'` (lines 262-292)
- `-rv` verbose directory: output regex `removed.*directory`
  (lines 270-280)
- `-fv`, `-rv`, `-if`, `-rI` combinations (lines 296-341)
- Error conditions: invalid flag, no args, permission denied,
  error message format (lines 354-394)
- `rm -rf /` protection (line 399)
- `rm -rf .` and `rm -rf ..` protection (lines 407-429)
- Symlink removal with target preserved (lines 490-499)
- Write-protected file behavior with `-i` and `-f`
  (lines 504-551)
- Error message text: "No such file or directory",
  "Is a directory" (lines 556-577)
- Error recovery: continues past errors (lines 669-680)
- Symlink-to-directory without `-r` (lines 755-770)

### Weak tests (exit-code-only or loose regex)

**`--preserve-root` (SHOULD tier)**
Location: `rm_test.sh:399`
The test `rm root directory protection` passes `-rf /`
and checks for exit code 1. It does not check the error
message content, so it passes equally whether protection
fires or the OS simply denies write access to `/`. The
test does not distinguish between the two.

**`-v` filename absent from check (MUST tier)**
Location: `rm_test.sh:263` and `rm_test.sh:599`
Both verbose output tests match `removed.*'.*'`, which
accepts any quoted string. If the implementation printed
`removed 'wrongfile'` the test would still pass. Neither
test captures `verb_exact_file` (or `verbose_file`) and
verifies the actual path appears in the output.

**`-rv` directory verbose check (MUST tier)**
Location: `rm_test.sh:276` and `rm_test.sh:611`
Pattern `removed.*directory` does not verify the
directory name appears in the output.

---

## Issues

```
[IMPORTANT] -d flag has zero test coverage
Location: tests/utilities/rm_test.sh (no line — entirely absent)
Problem: -d removes empty directories without -r. It is a MUST-tier
  flag. No test invokes "$binary" -d at all. The implementation
  exists (src/rm.zig:227-248) but is completely unexercised by
  integration tests. Three cases need coverage: empty dir removed
  successfully, non-empty dir refused, and -dv output format.
Fix: Add three tests in the -d section:
  1. create empty dir; run "$binary" -d "$dir"; verify dir gone,
     exit 0.
  2. create dir with file inside; run "$binary" -d "$dir"; verify
     dir still exists, exit 1.
  3. create empty dir; run "$binary" -dv "$dir"; verify output
     matches "removed directory '...'" with the actual path.
```

```
[IMPORTANT] --no-preserve-root has zero test coverage
Location: tests/utilities/rm_test.sh (no line — entirely absent)
Problem: --no-preserve-root is a SHOULD-tier flag with no test of
  any kind. A programmer could silently break it (for example,
  mis-parse it as --preserve-root) without any test catching it.
  Even a behavioral smoke test is needed.
Fix: Add a test that passes --no-preserve-root with a safe target
  and verifies the file is actually removed (exit 0, file gone).
  This confirms the flag parses and does not accidentally invoke
  the root-protection path on non-root targets.
```

```
[IMPORTANT] -P flag has zero test coverage
Location: tests/utilities/rm_test.sh (no line — entirely absent)
Problem: -P is a MUST-tier flag. Even though the spec says it is a
  no-op kept for compatibility, the implementation must accept it
  without error. There is no test verifying that "$binary" -P file
  parses the flag, removes the file, and exits 0.
Fix: Add one test: create a file, run "$binary" -P "$file", verify
  exit 0 and file gone.
```

```
[IMPORTANT] -x flag has zero test coverage
Location: tests/utilities/rm_test.sh (no line — entirely absent)
Problem: -x is a SHOULD-tier flag (do not cross mount points during
  recursive removal). No test invokes it. At minimum, a smoke test
  should verify it is accepted and does not error on a normal
  directory removal where no mount points are present.
Fix: Add one test: create a dir tree, run "$binary" -rx "$dir",
  verify exit 0 and dir gone. This confirms the flag parses without
  error even when no mount boundary is crossed.
```

```
[IMPORTANT] -W flag has zero test coverage
Location: tests/utilities/rm_test.sh (no line — entirely absent)
Problem: -W is a SHOULD-tier flag. Even if undelete is a no-op on
  Linux, the flag must be accepted without crashing. No test
  verifies this.
Fix: Add a platform-conditional test. On Linux: run "$binary" -W
  "/tmp/nosuchfile_$$" and verify it exits non-zero with an
  appropriate error message (not a crash or unknown-flag error).
  On macOS: behavior is system-dependent; at minimum verify the
  flag is accepted.
```

```
[SUGGESTION] -v output does not verify the actual filename
Location: tests/utilities/rm_test.sh:263, 287, 598-603
Problem: The verbose output checks use pattern removed.*'.*',
  which matches any quoted string. A bug printing the wrong
  filename would pass. The test should verify the actual path
  being removed appears in the output.
Fix: After capturing verb_exact_out, add a check such as:
  [[ "$verb_exact_out" == *"'$verb_exact_file'"* ]]
  Do the same for --verbose and the directory verbose tests.
```

```
[SUGGESTION] --preserve-root test relies on OS, not flag behavior
Location: tests/utilities/rm_test.sh:399
Problem: The test "rm root directory protection" passes -rf / and
  expects exit 1. The OS itself will refuse to unlink / on most
  systems, so this test would pass even if --preserve-root were
  completely removed from the implementation. The test does not
  check that the error message mentions preserve-root.
Fix: Capture stderr from the -rf / invocation and assert it
  contains "preserve-root" or a recognizable sentinel from the
  flag's code path. Alternatively, test with --no-preserve-root
  on a non-root target to confirm the complementary flag works.
```

---

## Summary

| Severity | Count |
|----------|-------|
| IMPORTANT | 5 |
| SUGGESTION | 2 |

**Overall assessment: NEEDS_FIXES**

Five MUST/SHOULD flags are entirely untested: `-d`, `-P`,
`-x`, `-W`, and `--no-preserve-root`. The remaining issues
are test-quality weaknesses that allow output bugs to slip
through.

### Fix Order

```
Fix Order:
1. [IMPORTANT] -d has no tests — tests/utilities/rm_test.sh
2. [IMPORTANT] --no-preserve-root has no tests — tests/utilities/rm_test.sh
3. [IMPORTANT] -P has no tests — tests/utilities/rm_test.sh
4. [IMPORTANT] -x has no tests — tests/utilities/rm_test.sh
5. [IMPORTANT] -W has no tests — tests/utilities/rm_test.sh
6. [SUGGESTION] -v output should verify actual filename — rm_test.sh:263,287,598
7. [SUGGESTION] --preserve-root test should check error message — rm_test.sh:399
```

REVIEW COMPLETE - NEEDS_FIXES
