# Unit Test Audit: find

**Date**: 2026-03-28
**Source**: `src/find.zig`

## Executive Summary

PASS WITH ISSUES

All 82 find-related unit tests pass. However, eight MUST-tier
primaries/-options have no unit tests at all (`-exec`, `-user`,
`-group`, `-nogroup`, `-newer`, `-follow`/`-L`, `-H`, `-and`/`-a`),
two MUST-tier tests only verify exit-code 0 with no behavioral
assertion (`-fstype`, `-flags`), two tests only verify the command
was "accepted" without checking behavior (`-ok`, `-execdir`), and
`-regex`/`-iregex` are explicitly documented as stubs that return
no matches — meaning programs relying on them will get wrong results.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| `parseSize: basic sizes` | YES — checks parsed struct fields for a pure parsing function | GOOD (parser unit test) |
| `parseSize: toBytes` | YES — arithmetic correctness | GOOD |
| `parseSize: errors` | YES — error propagation | GOOD |
| `parseMtime: basic` | YES — parser unit test | GOOD |
| `parseMtime: errors` | YES | GOOD |
| `parsePerm: basic` | YES | GOOD |
| `parsePerm: errors` | YES | GOOD |
| `parseFileType: basic` | YES | GOOD |
| `parseFileType: errors` | YES | GOOD |
| `find: help flag` | YES — checks output contains "Usage:" | GOOD |
| `find: version flag` | YES — checks output contains "vibeutils" | GOOD |
| `find: basic directory search` | YES — output contains expected filenames | GOOD |
| `find: -name filter` | YES — includes match, excludes non-match | GOOD |
| `find: -type filter` | YES — f/d discrimination | GOOD |
| `find: -empty` | YES | GOOD |
| `find: -maxdepth` | YES | GOOD |
| `find: -not / !` | YES | GOOD |
| `find: -or operator` | YES — `-o` tested | GOOD |
| `find: parentheses grouping` | YES | GOOD |
| `find: -print0` | YES — checks NUL delimiter, no newline | GOOD |
| `find: nonexistent path` | YES — exit code 1, stderr populated | GOOD |
| `find: unknown predicate` | YES — error message checked | GOOD |
| `find: -mindepth` | YES | GOOD |
| `find: -delete` | YES — file is actually removed | GOOD |
| `find: -iname` | YES — case-insensitive match verified | GOOD |
| `find: -size filter` | YES | GOOD |
| `find: -perm filter` | YES — 755 vs 644 discrimination | GOOD |
| `find: -path matches full path pattern` | YES | GOOD |
| `find: -prune prevents descending into directory` | YES — hidden file not found | GOOD |
| `find: -depth lists directory contents before directory` | YES — position ordering checked | GOOD |
| `find: -path with non-matching pattern returns no results` | YES | GOOD |
| `find: -atime +9999 matches nothing` | YES — negative behavioral check | GOOD |
| `find: -ctime +9999 matches nothing` | YES | GOOD |
| `find: -links 99 matches nothing` | YES — negative check | GOOD |
| `find: -nouser matches nothing for normal files` | YES — negative check only | PARTIAL (see U9) |
| `find: -xdev is accepted without error` | NO — only checks exit 0, no cross-device boundary | WEAK (see U5) |
| `find: -d is alias for -depth` | YES — ordering verified | GOOD |
| `find: -f specifies explicit search path` | YES | GOOD |
| `find: -x is alias for -xdev` | WEAK — same issue as -xdev | WEAK |
| `find: -X warns about xargs-unsafe filenames` | YES — stderr and skip verified | GOOD |
| `find: -mmin matches recently modified files` | YES | GOOD |
| `find: -mmin +9999 matches nothing` | YES | GOOD |
| `find: -inum matches file by inode number` | YES | GOOD |
| `find: -inum with non-matching inode returns nothing` | YES | GOOD |
| `find: -amin -5 matches recently accessed files` | YES | GOOD |
| `find: -amin +9999 matches nothing` | YES | GOOD |
| `find: -cmin -5 matches recently changed files` | YES | GOOD |
| `find: -cmin +9999 matches nothing` | YES | GOOD |
| `find: -anewer matches files accessed after reference` | YES | GOOD |
| `find: -cnewer matches files changed after reference` | YES | GOOD |
| `find: -ok is parsed as valid primary` | NO — comment says execution cannot be tested; only checks exit 0 | STUB (see U1) |
| `find: -execdir runs command in file directory` | NO — comment says "parsed and accepted"; no cwd verification | STUB (see U2) |
| `find: -ls produces listing output` | YES — filename and "rw" in output | GOOD |
| `find: -fstype is accepted without error` | NO — hardcoded "apfs" may match or not; only checks exit 0 | WEAK (see U6) |
| `find: -flags is accepted without error` | NO — only checks exit 0 | WEAK (see U7) |
| `find: -P global option accepted as no-op` | YES — file still found | GOOD |
| `find: -E global option accepted as no-op` | YES — file still found | GOOD |
| `find: -s global option accepted as no-op` | YES — file found, but order NOT verified | WEAK (see U3) |
| `find: -ipath case-insensitive path matching` | YES | GOOD |
| `find: -iwholename is alias for -ipath` | YES | GOOD |
| `find: -regex stub returns no matches` | YES — but this tests a STUB, not the real feature | STUB (see U11) |
| `find: -iregex stub returns no matches` | YES — same | STUB (see U11) |
| `find: -Bmin stub accepted (always true)` | YES — output non-empty | GOOD |
| `find: -Bnewer stub accepted (always true)` | YES | GOOD |
| `find: -Btime stub accepted (always true)` | YES | GOOD |
| `find: -acl stub accepted (always false)` | YES — output empty | GOOD |
| `find: -depth N matches files at exact depth` | YES | GOOD |
| `find: -gid matches numeric group ID` | YES | GOOD |
| `find: -gid with non-matching GID returns nothing` | YES | GOOD |
| `find: -uid matches numeric user ID` | YES | GOOD |
| `find: -uid with non-matching UID returns nothing` | YES | GOOD |
| `find: -ignore_readdir_race accepted as no-op` | YES — file found | GOOD |
| `find: -noignore_readdir_race accepted as no-op` | YES — file found | GOOD |
| `find: -noleaf accepted as no-op` | YES — file found | GOOD |
| `find: -lname matches symlink target` | YES | GOOD |
| `find: -ilname case-insensitive symlink target matching` | YES | GOOD |
| `find: -mnewer is alias for -newer` | YES — time manipulation used | GOOD |
| `find: -mount is alias for -xdev` | WEAK — same as -xdev (see U5) | WEAK |
| `find: -newerXY stub accepted (always true)` | YES — output non-empty | GOOD |
| `find: -okdir stub accepted (always false)` | NO — only checks exit 0 | STUB |
| `find: -quit is accepted as valid primary` | YES — uses `-false -quit` to avoid process exit | GOOD |
| `find: -samefile matches files with same inode` | YES | GOOD |
| `find: -sparse stub accepted (always false)` | YES — output empty | GOOD |
| `find: -xattr stub accepted (always false)` | YES — output empty | GOOD |
| `find: -xattrname stub accepted (always false)` | YES — output empty | GOOD |
| `find: -printf stub accepted (prints like -print)` | YES — filename found | GOOD |
| `find: -false always evaluates to false` | YES | GOOD |
| `find: -true always evaluates to true` | YES | GOOD |
| `find: -false -o -true evaluates to true` | YES | GOOD |
| `find: -regex stub should not match everything` | YES — documents known failure | GOOD (documents stub) |
| `find: -iregex stub should not match everything` | YES — documents known failure | GOOD (documents stub) |

---

## Parse-Only Tests (CRITICAL)

No tests in this file follow the classic parse-only pattern of
asserting struct field values instead of output. The failing
patterns here are "acceptance-only" tests (exit 0 with no behavioral
assertion) rather than struct-field-only tests. See the WEAK and STUB
entries above.

---

## Missing Coverage

### MUST-Tier Flags With No Tests

| Flag | Tier | Has Test? | Notes |
|------|------|-----------|-------|
| `-exec` | MUST | NO | Implemented at line 855; zero tests |
| `-user` | MUST | NO | Implemented at line 815; zero tests |
| `-group` | MUST | NO | Implemented at line 826; zero tests |
| `-nogroup` | MUST | NO (negative only) | `nouser` only tested negative (see U9); `nogroup` has no test |
| `-newer` | MUST | NO | Implemented at line 771; only `-mnewer` (alias) is tested |
| `-follow` | MUST | NO | Implemented at line 435; `-L` is equivalent; neither is tested |
| `-H` | MUST | NO | Implemented at line 438; zero tests |
| `-L` | MUST | NO | Implemented at line 435; zero tests |
| `-and` / `-a` | MUST | NO | Implemented at line 632; only `-o` / `-or` is tested |

### MUST-Tier Flags With Only Acceptance Tests

| Flag | Tier | Test Type | Problem |
|------|------|-----------|---------|
| `-fstype` | MUST | Acceptance (exit 0) | No filter behavior verified |
| `-flags` | MUST | Acceptance (exit 0) | No filter behavior verified |
| `-xdev` | MUST | Acceptance (exit 0) | Cross-device filtering not verified |
| `-ok` | MUST | Acceptance (exit 0) | Prompting behavior untested |
| `-execdir` | MUST | Acceptance (exit 0) | Working-directory change not verified |

### SHOULD-Tier Flags With Only Acceptance/Stub Tests

| Flag | Tier | Test Type |
|------|------|-----------|
| `-regex` | SHOULD | Stub — always returns false |
| `-iregex` | SHOULD | Stub — always returns false |
| `-s` (lexicographic sort) | SHOULD | Acceptance — order not verified |
| `-printf` | SHOULD | Acceptance — format specifiers not verified |

---

## Other Issues

### Weak Assertions

**`-xdev` / `-x` / `-mount`**: All three tests only check that the
utility exits 0 and the target file still appears. They do NOT create
a second filesystem mount point and verify that files on it are
excluded. A broken `-xdev` implementation would pass these tests.

**`-nouser` negative-only**: The test verifies that a normally-owned
file is not reported by `-nouser`, but there is no test that
`-nouser` reports a file whose UID maps to no passwd entry.

**`-s` sort order not verified**: The test for `-s` creates one file
and checks it is found, but never creates multiple files and verifies
they appear in lexicographic order.

**`-printf` format not verified**: The test checks that `file.txt`
appears in output when `-printf "%p\\n"` is used, but does not
verify that format specifiers (`%f`, `%d`, `%s`, etc.) expand
correctly. A stub that ignores the format string and calls `-print`
passes this test.

### Documented Stubs Accepted as Final State

The tests for `-regex` and `-iregex` explicitly assert "returns no
matches" as the expected behavior. Both test comments say "the stub
currently returns true for all files, so this test will FAIL until
the stub is fixed." But the tests pass — meaning the stub was fixed
to always return false instead of always return true. The feature
is still unimplemented (the test verifies a stub behavior, not
correct regex matching). This is documented but the SHOULD-tier
primaries are not functional.

### `-execdir` Behavior Not Verified

The test comment says "-execdir should be parsed and accepted." It
calls `echo {} ;` and checks exit 0, but does NOT verify that `echo`
was invoked from the directory containing the matched file. A correct
`-execdir` implementation changes cwd before running the utility;
the test cannot distinguish that from running from the starting
directory.

### `-ok` Behavior Not Verified

The test comment explicitly says "we cannot test execution." The test
uses `-maxdepth 0` so no files are visited, meaning `-ok` never
fires. This confirms the test verifies nothing about the primary's
actual prompt-then-execute behavior.

### Platform Sensitivity

**`-fstype apfs`**: The test passes `"apfs"` as the fstype, which
only exists on macOS. On Linux (via `orb -m ubuntu`), this test
likely produces no output regardless of whether `-fstype` filtering
is implemented correctly. Exit code 0 is returned in both cases. This
means the test gives false confidence on Linux.

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| U1 | IMPORTANT | `-ok` test only checks exit 0 with `-maxdepth 0` — primary never fires |
| U2 | IMPORTANT | `-execdir` test only checks exit 0; cwd change not verified |
| U3 | SUGGESTION | `-s` test verifies file is found but not that output is sorted |
| U4 | CRITICAL | `-exec` MUST-tier primary has no unit test at all |
| U5 | IMPORTANT | `-xdev`/`-x`/`-mount` tests do not verify cross-device filtering |
| U6 | IMPORTANT | `-fstype` test is platform-specific (apfs) and only checks exit 0 |
| U7 | IMPORTANT | `-flags` test only checks exit 0; filter behavior not verified |
| U8 | CRITICAL | `-user` MUST-tier primary has no unit test |
| U9 | CRITICAL | `-group` MUST-tier primary has no unit test |
| U10 | CRITICAL | `-nogroup` MUST-tier primary has no unit test |
| U11 | IMPORTANT | `-regex`/`-iregex` are stubs (always false); feature not implemented |
| U12 | CRITICAL | `-newer` MUST-tier primary has no unit test (only alias `-mnewer` tested) |
| U13 | CRITICAL | `-follow`/`-L`/`-H` MUST-tier options have no unit tests |
| U14 | CRITICAL | `-and`/`-a` MUST-tier operator has no unit test |
| U15 | SUGGESTION | `-printf` format specifier expansion not verified |
| U16 | SUGGESTION | `-nouser` only tested negative; no test for file with unknown UID |

---

## Summary

**Counts by severity:**
- CRITICAL: 7 (U4, U8, U9, U10, U12, U13, U14)
- IMPORTANT: 6 (U1, U2, U5, U6, U7, U11)
- SUGGESTION: 3 (U3, U15, U16)

**Assessment: NEEDS_FIXES**

The test suite is broad and most implemented features have genuine
behavioral tests. The primary failure mode is missing coverage for
eight MUST-tier primaries and operators, and acceptance-only tests
for five others. The `-regex`/`-iregex` stubs are a functional
gap, not just a test gap.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -exec has no test — src/find.zig (no line; add after line ~3437)
2. [CRITICAL] -newer has no test (only alias -mnewer) — src/find.zig
3. [CRITICAL] -user has no test — src/find.zig
4. [CRITICAL] -group has no test — src/find.zig
5. [CRITICAL] -nogroup has no test — src/find.zig
6. [CRITICAL] -L/-follow and -H have no tests — src/find.zig
7. [CRITICAL] -and/-a operator has no test — src/find.zig
8. [IMPORTANT] -ok test does not exercise the primary — src/find.zig:3424
9. [IMPORTANT] -execdir test does not verify cwd change — src/find.zig:3438
10. [IMPORTANT] -regex/-iregex are unimplemented stubs — src/find.zig
11. [IMPORTANT] -fstype test is platform-specific, no filter check — src/find.zig:3484
12. [IMPORTANT] -flags test only checks exit 0 — src/find.zig:3505
13. [IMPORTANT] -xdev/-x/-mount tests do not verify cross-device filtering — src/find.zig:3032
14. [SUGGESTION] -s test should verify lexicographic order — src/find.zig:3572
15. [SUGGESTION] -printf test should verify format expansion — src/find.zig:4206
16. [SUGGESTION] -nouser needs a positive test — src/find.zig:3009
```

REVIEW COMPLETE - NEEDS_FIXES
