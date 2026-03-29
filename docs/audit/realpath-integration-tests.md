# realpath Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/realpath_test.sh`
**Tests:** 50 integration tests
**Run result:** 50/50 pass
**Status:** NEEDS_FIXES

## Summary

The suite is the most thorough in the project for a path-resolution
utility. Behavioral output is verified for most flags. Key gaps: `-e`
output is never verified (exit-code-only), `--canonicalize-missing`
long form is never tested, and the relative-to/relative-base suite
always uses `-s`, leaving default and `-m` resolution of the base dir
untested. One test uses `|| true`-equivalent stderr-redirect masking
that could hide real errors.

## Test Inventory

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | test_basic_flags | Yes | common helper |
| 2 | help output contains expected content | Yes | substring check |
| 3 | version output contains utility name | Yes | substring check |
| 4 | existing path succeeds | Exit-only | correct |
| 5 | root path succeeds | Exit-only | correct |
| 6 | output is absolute path | Yes | `== /*` check |
| 7 | nonexistent path fails | Exit-only | correct |
| 8 | error message includes program name | Yes | stderr check |
| 9 | -e existing path succeeds | Exit-only | no output check |
| 10 | -e nonexistent path fails | Exit-only | correct |
| 11 | -m nonexistent path succeeds | Exit-only | correct |
| 12 | -m preserves nonexistent component | Yes | substring check |
| 13 | -m resolves .. in nonexistent paths | Yes | negative check (no ..) |
| 14 | -s resolves .. | Yes | exact `/usr/lib` |
| 15 | -s resolves . | Yes | exact `/usr/bin` |
| 16 | -s resolves complex .. | Yes | exact `/a/d` |
| 17 | -s resolves root .. | Yes | exact `/` |
| 18 | -s removes redundant slashes | Yes | exact output |
| 19 | --strip alias | Yes | exact output |
| 20 | --no-symlinks long form | Yes | exact output |
| 21 | -z NUL delimiter | Yes | cmp against NUL-terminated |
| 22 | --zero flag exists | Exit-only | no NUL check |
| 23 | -q suppresses error messages | Yes | stderr empty |
| 24 | -q still returns error code | Exit-only | correct |
| 25 | --relative-to basic | Yes | exact `bin/ls` |
| 26 | --relative-to same dir | Yes | exact `.` |
| 27 | --relative-to parent | Yes | exact `..` |
| 28 | --relative-base under base | Yes | exact `bin/ls` |
| 29 | --relative-base not under base | Yes | exact `/etc/hosts` |
| 30 | multiple paths | Yes | exact two-line output |
| 31 | multiple paths: valid one succeeds | Yes | partial output check |
| 32 | multiple paths with failure returns error | Exit-only | correct |
| 33 | no arguments | Exit-only | correct (exit 2) |
| 34 | missing operand error message | Yes | stderr check |
| 35 | invalid flag | Exit-only | correct |
| 36 | invalid short flag | Exit-only | correct |
| 37 | default mode resolves symlinks | Yes | `*real_file*` check |
| 38 | -s mode preserves symlinks | Yes | `*link_file*` check |
| 39 | -m -s combined | Yes | exact output |
| 40 | -m -s combined succeeds | Exit-only | correct |
| 41 | -q -m succeeds for nonexistent | Exit-only | correct |
| 42 | -z -s combined | Yes | cmp NUL-terminated |
| 43 | -s root | Yes | exact `/` |
| 44 | dot path succeeds | Exit-only | correct |
| 45 | double dash with path | Exit-only | correct |
| 46 | --relative-base under base is relative | Yes | exact `lib` |
| 47 | --relative-base prefix mismatch is absolute | Yes | `== /*` check |
| 48 | realpath -m .. past root returns / | Yes | exact `/` |
| 49-50 | (2 tests counted in test_basic_flags) | Yes | |

## Findings

---

[IMPORTANT] -e output never verified in integration tests
Location: `tests/utilities/realpath_test.sh:65-66`
Problem: Both `-e` integration tests check only exit code. GNU
`realpath -e` must produce the same canonicalized absolute path as the
default mode (since both require all components to exist). No test
verifies that `-e` actually outputs a path. A regression that made
`-e` print nothing on success would pass.
Fix: Add output verification:
```bash
local ce_output
ce_output=$("$binary" -e /tmp 2>/dev/null)
if [[ "$ce_output" == /* ]]; then
    print_test_result "-e output is absolute path" "PASS"
else
    print_test_result "-e output is absolute path" "FAIL" \
        "Output: $ce_output"
fi
```

---

[IMPORTANT] --canonicalize-missing long form never tested
Location: `tests/utilities/realpath_test.sh` (entire file)
Problem: The suite tests `-m` (short) and the combination `-m -s`,
but `--canonicalize-missing` as a long flag is never exercised. An
argparse meta regression on the long name would go undetected.
Fix: Add at minimum an exit-code test:
```bash
test_command_exit_code "--canonicalize-missing flag works" 0 \
    "$binary" --canonicalize-missing /tmp/nonexistent_vibeutils_path
```

---

[IMPORTANT] --relative-to and --relative-base always use -s; base-dir
resolution untested in default or -m mode
Location: `tests/utilities/realpath_test.sh:135-145`
Problem: Every `--relative-to` and `--relative-base` test passes `-s`.
The code path that resolves the base directory via `realpathAlloc`
(lines 155-160 of `realpath.zig`) is never exercised by integration
tests. A regression there (e.g. it silently returned an error) would
not be caught.
Fix: Add at least one test without `-s` using a real directory:
```bash
test_command_output "--relative-to default mode" "bin" \
    "$binary" --relative-to=/usr /usr/bin
```

---

[IMPORTANT] --zero integration test is exit-only
Location: `tests/utilities/realpath_test.sh:117`
Problem: "--zero flag exists" checks only exit 0. The short-form `-z`
test at line 108-113 correctly uses `cmp -s` to verify the NUL byte.
The long-form test does not. A regression that turned `--zero` into a
no-op would pass.
Fix: Reuse the cmp pattern from lines 108-113 for the `--zero` test.

---

[SUGGESTION] stderr-redirect masking in error tests could hide real failures
Location: `tests/utilities/realpath_test.sh:52,66`
Problem: `test_command_exit_code "nonexistent path fails" 1 "$binary"
/nonexistent_vibeutils_path 2>/dev/null` redirects stderr to
/dev/null, which silently discards error output. If the binary
printed to stdout instead of stderr on error, the test would still
pass. Two tests use this pattern. (The companion test at line 56-60
does separately verify stderr content, so this is minor.)
Fix: Use `run_command` and assert stderr non-empty, or at minimum
remove the `2>/dev/null` to ensure test_command_exit_code sees all
output.

---

[SUGGESTION] -m output check uses substring, not exact canonical path
Location: `tests/utilities/realpath_test.sh:74-79`
Problem: "-m preserves nonexistent component" checks
`*nonexistent_vibeutils_path*`, which is correct but weak. It does
not verify the path is absolute (starts with `/`) or that no `..`
components remain. The `-m resolves ..` test (lines 83-88) covers the
latter, so this is low severity.
Fix: Also assert `missing_output` starts with `/`.

## Overall Assessment

NEEDS_FIXES

Fix Order:
1. [IMPORTANT] -e output never verified — `realpath_test.sh:65-66`
2. [IMPORTANT] --canonicalize-missing long form untested — entire file
3. [IMPORTANT] --relative-to/--relative-base only with -s — lines 135-145
4. [IMPORTANT] --zero is exit-only — `realpath_test.sh:117`
5. [SUGGESTION] 2>/dev/null masking on error tests — lines 52, 66
6. [SUGGESTION] -m output check weak — `realpath_test.sh:74-79`
