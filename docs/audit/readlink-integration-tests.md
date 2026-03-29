# readlink Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/readlink_test.sh`
**Tests:** 33 integration tests
**Run result:** 33/33 pass
**Status:** NEEDS_FIXES

## Summary

The suite is well-structured and behaviorally solid. No test merely
checks an exit code without verifying output where output matters.
Two important gaps exist: the `-f`/`-e` semantic difference is not
covered (same production bug as in unit tests), and several
documented long-form aliases (`--quiet`, `--verbose`, `--no-newline`,
`--silent`) are never exercised. A minor readability issue appears in
the `--zero` test.

## Test Inventory

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | test_basic_flags | Yes | common helper |
| 2 | readlink basic symlink | Yes | output verified |
| 3 | readlink relative symlink | Yes | output verified |
| 4 | readlink dangling symlink | Yes | output verified |
| 5 | readlink regular file fails | Exit-only | correct: output is empty |
| 6 | readlink nonexistent file fails | Exit-only | correct: output is empty |
| 7 | readlink directory fails | Exit-only | correct |
| 8 | readlink -f symlink | Yes | output vs _canon() |
| 9 | readlink -f regular file | Yes | output vs _canon() |
| 10 | readlink --canonicalize | Exit-only | no output check |
| 11 | readlink -f nonexistent fails | Exit-only | correct |
| 12 | readlink -e existing file | Yes | output verified |
| 13 | readlink -e nonexistent fails | Exit-only | correct |
| 14 | readlink --canonicalize-existing | Exit-only | no output check |
| 15 | readlink -m existing file | Yes | output verified |
| 16 | readlink -m nonexistent path succeeds | Yes | output non-empty check |
| 17 | readlink --canonicalize-missing | Yes | output non-empty check |
| 18 | readlink -n no trailing newline | Yes | byte count check |
| 19 | readlink -z NUL terminator | Yes | last-byte check |
| 20 | readlink --zero flag accepted | Exit-only | no NUL check |
| 21 | readlink -v shows error | Yes | stderr non-empty |
| 22 | readlink -q suppresses errors | Yes | stderr empty |
| 23 | readlink multiple symlinks | Exit-only | no output check |
| 24 | readlink mixed success/failure exit code | Exit-only | correct |
| 25 | readlink no arguments | Exit-only | correct (misuse) |
| 26 | readlink invalid flag | Exit-only | correct |
| 27 | readlink help output | Yes | substring check |
| 28 | readlink version output | Yes | substring check |
| 29 | readlink chain immediate target | Yes | output verified |
| 30 | readlink -f chain resolves to end | Yes | output vs _canon() |
| 31 | readlink -m .. past root returns / | Yes | exact output |

## Findings

---

[IMPORTANT] -f "all but the last component must exist" is untested
Location: `tests/utilities/readlink_test.sh:147-149`
Problem: The integration test for `-f` only covers success (existing
symlink and file) and whole-path nonexistent failure. GNU `readlink
-f` must succeed when the parent directory exists but the last
component does not (e.g. `readlink -f /tmp/existing_dir/new_name`).
No test probes this. The production code treats `-f` identically to
`-e` (both fail in this case), and this test gap means the divergence
from GNU behavior goes undetected.
Fix: Add a test:
```bash
local f_missing_last_dir
f_missing_last_dir=$(create_temp_dir)
local f_expected="$f_missing_last_dir/nonexistent_last"
local f_actual
f_actual=$("$binary" -f "$f_expected" 2>/dev/null)
if [[ $? -eq 0 && "$f_actual" == "$f_expected" ]]; then
    print_test_result "readlink -f last component may not exist" "PASS"
else
    print_test_result "readlink -f last component may not exist" "FAIL" \
        "Expected '$f_expected', got '$f_actual'"
fi
```

---

[IMPORTANT] --quiet, --verbose, --no-newline, --silent long forms never tested
Location: `tests/utilities/readlink_test.sh` (entire file)
Problem: The suite exercises `-q`, `-v`, and `-n` by short flag only.
Long forms `--quiet`, `--verbose`, `--no-newline`, and `--silent` are
all documented flags with no integration coverage. A typo in the
argparse meta entry would not be caught.
Fix: Add at minimum exit-code checks for each long form:
```bash
test_command_exit_code "readlink --quiet accepted" 1 \
    "$binary" --quiet /tmp/nonexistent_readlink_$$
test_command_exit_code "readlink --verbose accepted" 1 \
    "$binary" --verbose /tmp/nonexistent_readlink_$$
test_command_exit_code "readlink --no-newline accepted" 1 \
    "$binary" --no-newline /tmp/nonexistent_readlink_$$
test_command_exit_code "readlink --silent accepted" 1 \
    "$binary" --silent /tmp/nonexistent_readlink_$$
```
The `--quiet`/`--silent` tests should also confirm empty stderr.

---

[IMPORTANT] Multiple-files output content not verified
Location: `tests/utilities/readlink_test.sh:319-327`
Problem: "readlink multiple symlinks" checks only exit code 0. The
two symlink targets are created, but the test never verifies the
output contains both targets. A regression that printed only one
target (or printed them in wrong order) would pass.
Fix: Verify output equals `"$m_target1\n$m_target2"` (in creation
order) after capturing it.

---

[SUGGESTION] --canonicalize and --canonicalize-existing tests are exit-only
Location: `tests/utilities/readlink_test.sh:139-145, 177-184`
Problem: Both long-form tests check only `exit == 0`, not that the
output matches the canonicalized path. The short-flag counterparts
do verify output content. This is inconsistent and weak.
Fix: Assert output equals `reg_expected` / `ce_expected` for the
long-form variants, consistent with the short-flag tests above them.

---

[SUGGESTION] --zero test is exit-only, NUL not checked
Location: `tests/utilities/readlink_test.sh:274-276`
Problem: "readlink --zero flag accepted" runs `--zero "$z_link"` and
checks only exit 0. The short-form `-z` test correctly checks the
last byte is `00`. The long-form should do the same.
Fix: Reuse the `$z_file` byte-check pattern from lines 261-270.

## Overall Assessment

NEEDS_FIXES

Fix Order:
1. [IMPORTANT] -f last-component-missing semantics untested — `readlink_test.sh:147`
2. [IMPORTANT] --quiet/--verbose/--no-newline/--silent long forms untested — entire file
3. [IMPORTANT] Multiple-files output not verified — `readlink_test.sh:319-327`
4. [SUGGESTION] --canonicalize/--canonicalize-existing exit-only — lines 139-145, 177-184
5. [SUGGESTION] --zero test is exit-only — `readlink_test.sh:274-276`
