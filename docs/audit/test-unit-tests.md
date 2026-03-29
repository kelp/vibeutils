# Unit Test Audit: test (and [)

**Date**: 2026-03-28
**Test file**: src/test.zig (embedded tests)
**Flags spec**: docs/specs/test-flags.md
**Integration test file**: tests/utilities/test_test.sh
**Result**: NEEDS_FIXES

---

## Test Run Results

All 45 unit tests pass. No failures.

---

## Test Inventory

| # | Test Name | Type |
|---|-----------|------|
| 1 | empty expression returns false | behavioral |
| 2 | single non-empty string returns true | behavioral |
| 3 | single empty string returns false | behavioral |
| 4 | string length tests -z and -n | behavioral |
| 5 | string equality tests | behavioral |
| 6 | numeric comparison tests | behavioral |
| 7 | file existence tests | behavioral |
| 8 | directory tests | behavioral |
| 9 | file size tests (-s) | behavioral |
| 10 | bracket form requires closing bracket | behavioral |
| 11 | bracket form works correctly | behavioral |
| 12 | terminal test with invalid fd (-t 999) | behavioral |
| 13 | terminal test with valid fd (-t 1) | behavioral (weak) |
| 14 | numeric comparison with invalid numbers | behavioral |
| 15 | invalid expressions return error | behavioral |
| 16 | negation operator (!) | behavioral |
| 17 | logical AND operator -a | behavioral |
| 18 | logical OR operator -o | behavioral |
| 19 | parentheses grouping | behavioral |
| 20 | operator precedence -o vs -a | behavioral |
| 21 | complex nested expressions | behavioral |
| 22 | error handling for malformed expressions | behavioral |
| 23 | evaluateUnary function | behavioral |
| 24 | evaluateBinary function | behavioral |
| 25 | operator detection | parse-only |
| 26 | NumericComparison module | behavioral |
| 27 | FileAccess module | behavioral (non-existent only) |
| 28 | invalid operator should return exit code 2 | behavioral |
| 29 | parentheses expression with logical operators | behavioral |
| 30 | complex nested expressions should parse correctly | behavioral |
| 31 | bracket form should handle errors identically | behavioral |
| 32 | POSIX: string 'false' is non-empty | behavioral |
| 33 | POSIX: string 'true' is non-empty | behavioral |
| 34 | POSIX: -o is left-associative | behavioral |
| 35 | symlink detection with -L and -h operators | behavioral |
| 36 | setuid and sticky bit operators -u and -k | behavioral (weak) |
| 37 | file comparison operators -nt, -ot, -ef | behavioral |
| 38 | string ordering operator < (less than) | behavioral |
| 39 | string ordering operator > (greater than) | behavioral |
| 40 | string ordering operators are recognized as binary operators | parse-only |
| 41 | -G operator: file group matches effective group ID | behavioral |
| 42 | -O operator: file user matches effective user ID | behavioral |
| 43 | -G and -O are recognized as unary operators | parse-only |
| 44 | evaluateBinary with < and > operators | behavioral |
| 45 | evaluateUnary with -G and -O operators | behavioral (non-existent only) |

**Parse-only tests**: 3 of 45 (tests 25, 40, 43)

---

## Coverage by Primary/Operator

### File Type Primaries

| Primary | Spec Tier | Has Behavioral Test | Notes |
|---------|-----------|---------------------|-------|
| -b | MUST | NO | No unit test at all |
| -c | MUST | NO | Only integration test via `/dev/null` |
| -d | MUST | YES | Test #8 |
| -e | MUST | YES | Test #7 |
| -f | MUST | YES | Test #7 |
| -g | MUST | NO | No unit test at all |
| -h | MUST | YES | Test #35 |
| -L | MUST | YES | Test #35 |
| -p | MUST | NO | No unit test at all |
| -S | MUST | NO | No unit test at all |
| -k | MUST | WEAK | Test #36 only checks non-existent file |
| -G | MUST | YES | Test #41 |
| -O | MUST | YES | Test #42 |

### File Permission/Attribute Primaries

| Primary | Spec Tier | Has Behavioral Test | Notes |
|---------|-----------|---------------------|-------|
| -r | MUST | NO | No unit test at all |
| -s | MUST | YES | Test #9 |
| -t | MUST | WEAK | Test #12 non-existent fd; test #13 doesn't assert result |
| -u | MUST | WEAK | Test #36 only checks non-existent file |
| -w | MUST | NO | No unit test at all |
| -x | MUST | NO | No unit test at all |

### String Primaries

| Primary | Spec Tier | Has Behavioral Test | Notes |
|---------|-----------|---------------------|-------|
| -n | MUST | YES | Test #4 |
| -z | MUST | YES | Test #4 |

### String Comparison Operators

| Operator | Spec Tier | Has Behavioral Test | Notes |
|----------|-----------|---------------------|-------|
| = | MUST | YES | Test #5 |
| != | MUST | YES | Test #5 |
| < | MUST | YES | Test #38 |
| > | MUST | YES | Test #39 |

### Integer Comparison Operators

| Operator | Spec Tier | Has Behavioral Test | Notes |
|----------|-----------|---------------------|-------|
| -eq | MUST | YES | Test #6 |
| -ne | MUST | YES | Test #6 |
| -gt | MUST | YES | Test #6 |
| -ge | MUST | YES | Test #6 |
| -lt | MUST | YES | Test #6 |
| -le | MUST | YES | Test #6 |

### File Comparison Operators

| Operator | Spec Tier | Has Behavioral Test | Notes |
|----------|-----------|---------------------|-------|
| -nt | MUST | YES | Test #37 |
| -ot | MUST | YES | Test #37 |
| -ef | MUST | YES | Test #37 |

### Logical Operators

| Operator | Spec Tier | Has Behavioral Test | Notes |
|----------|-----------|---------------------|-------|
| ! | MUST | YES | Test #16 |
| -a | MUST | YES | Test #17 |
| -o | MUST | YES | Test #18 |
| ( ) | MUST | YES | Test #19 |

---

## Issues Found

### IMPORTANT

**[IMPORTANT] No behavioral tests for -r, -w, -x**
Location: src/test.zig — missing tests
Problem: Three MUST-tier POSIX primaries have zero unit tests. The
implementation at lines 362-364 calls `FileAccess.check()` with
`R_OK`, `W_OK`, `X_OK` respectively, but no test creates a temp file,
changes permissions, and verifies the correct result. These paths
are exercised only in integration tests.
Fix: Add a test that creates a temp file, uses `chmod` to make it
non-writable, and verifies `-w` returns false; creates an executable
file and verifies `-x` returns true; verifies `-r` returns true on a
readable file. The `testing.tmpDir` pattern already used throughout
the file is suitable.

**[IMPORTANT] No behavioral tests for -b, -p, -S**
Location: src/test.zig — missing tests
Problem: Three MUST-tier primaries (`-b` block device, `-p` named
pipe, `-S` socket) have zero unit tests of any kind. The
implementations at lines 369, 367, 368 can be exercised on Linux
with `/dev/null` for `-c`, but `-b` and `-p` require either a real
device node or creating a FIFO. `-S` requires a real Unix socket.
Fix: For `-b`, test with a known block device path (e.g.,
`/dev/sda` or `/dev/loop0`) guarded by `if (std.fs.cwd().access
(...) != error.FileNotFound)` to skip where unavailable. For `-p`,
use `std.posix.mkfifo` to create a FIFO in a `tmpDir`, then
verify `-p` returns true. For `-S`, create a Unix domain socket
via `std.net.Address.initUnix` and verify `-S` returns true.

**[IMPORTANT] No behavioral tests for -g (setgid)**
Location: src/test.zig — missing tests
Problem: The `-g` primary (MUST tier) has no unit test. Test #36
covers `-u` and `-k` but omits `-g`. The implementation at line 371
calls `hasSetgid()` but correctness is never verified.
Fix: Add to test #36 (or a new test): verify `-g` returns false on a
normal file, and true on a file after `chmod g+s`. Example:
```zig
const stat_check = try std.posix.fstat(test_file.handle);
_ = stat_check;
try std.posix.fchmod(test_file.handle,
    std.posix.S.IRUSR | std.posix.S.IWUSR | std.posix.S.ISGID);
var result = try runTest(testing.allocator,
    &[_][]const u8{ "-g", temp_path }, ...);
try testing.expectEqual(@intFromEnum(ExitCode.true), result);
```

**[IMPORTANT] -u and -k tests only verify non-existent file**
Location: src/test.zig:1139
Problem: Test #36 is titled "setuid and sticky bit operators -u and
-k" but only asserts that they return false on `/nonexistent`. The
comment explicitly says "just test they don't crash". This means no
test exercises the `true` path of `hasSetuid()` or `hasSticky()` —
i.e., a file with the setuid or sticky bit set.
Fix: Create a temp file, call `fchmod` to set the setuid bit, then
verify `-u` returns true. For sticky bit, same pattern with
`std.posix.S.ISVTX`.

**[IMPORTANT] -nt when file2 does not exist returns false (possible
wrong behavior)**
Location: src/test.zig:496-501
Problem: `isNewerThan()` returns false if `getStat(path2)` fails
(line 499). Per POSIX and most implementations, if file1 exists and
file2 does not, `file1 -nt file2` should return true (file1 is
"newer" than a nonexistent file). The current implementation returns
false in that case. There is no test covering the case where file1
exists and file2 does not.
Fix: Add a test case to test #37:
```zig
// existing file -nt nonexistent should be true
result = try runTest(testing.allocator,
    &[_][]const u8{ newer_path, "-nt", "/nonexistent/file" },
    common.null_writer, common.null_writer);
try testing.expectEqual(@intFromEnum(ExitCode.true), result);
```
Then fix `isNewerThan` to only require `path1` to exist:
```zig
fn isNewerThan(path1: []const u8, path2: []const u8) bool {
    const stat1 = FileAccess.getStat(path1) orelse return false;
    const stat2 = FileAccess.getStat(path2) orelse return true;
    return stat1.mtime > stat2.mtime;
}
```
Similarly for `isOlderThan` (if file1 does not exist and file2 does,
`file1 -ot file2` should arguably be true).

### SUGGESTION

**[SUGGESTION] Test #13 does not assert a result value**
Location: src/test.zig:826-832
Problem: "terminal test with valid fd" calls `runTest` with `-t 1`
and only asserts the result is not an error exit code. This makes
the test useless for detecting regressions — it will pass whether
`-t 1` returns 0 or 1 in any environment.
Fix: In CI/test environments, fd 1 is typically not a tty. Assert
the expected value (`ExitCode.false`) directly, or skip with a
compile-time note. Alternatively, open a pty in the test and verify
`-t <fd>` returns true on it.

**[SUGGESTION] `==` alias for `=` is not implemented or tested**
Location: src/test.zig — missing implementation
Problem: The macOS man page documents `==` as a compatibility alias
for `=`. The implementation's `evaluateBinary` function (lines
387-400) does not handle `==`, and `isBinaryOperator` does not list
it. If shell scripts pass `==`, it will return error exit code 2.
This is not in the vibeutils flags spec as "Ours: yes", so it may
be intentional. If it is intentional to omit it, a comment should
say so.
Fix: Either add `if (std.mem.eql(u8, op, "==")) return std.mem.eql
(u8, left, right);` to `evaluateBinary` and add `"=="` to
`isBinaryOperator`, with a test; or add a comment to `evaluateBinary`
explicitly noting `==` is not supported.

**[SUGGESTION] Parse-only operator detection tests add no value**
Location: src/test.zig:975-985 (test #25), :1228-1231 (test #40),
:1273-1276 (test #43)
Problem: Three tests only call `isUnaryOperator()` or
`isBinaryOperator()` without exercising any observable program
behavior. If the operator dispatch table were broken these tests
would still pass.
Fix: Merge the operator-recognition assertions into the behavioral
tests that already exercise those operators (e.g., add
`isUnaryOperator` checks into the symlink or file tests). These
standalone tests can then be removed.

---

## Summary

| Severity | Count |
|----------|-------|
| IMPORTANT | 5 |
| SUGGESTION | 3 |

**Assessment: NEEDS_FIXES**

The test suite is substantially better than most utilities audited
in this project. All 45 tests pass, the core expression types
(strings, numeric, logical operators, parentheses, file existence,
symlinks, file comparisons) have genuine behavioral tests. The gaps
are concentrated in the file-permission and special-file-type
primaries (`-r`, `-w`, `-x`, `-b`, `-p`, `-S`, `-g`, `-u`, `-k`),
most of which only verify the false-on-nonexistent-file path.

Fix Order:
1. [IMPORTANT] -nt false when file2 missing is wrong — src/test.zig:496-501
2. [IMPORTANT] Add -r, -w, -x behavioral tests — src/test.zig (missing)
3. [IMPORTANT] Add -g behavioral test — src/test.zig (missing)
4. [IMPORTANT] Add -u/-k true-path tests — src/test.zig:1139
5. [IMPORTANT] Add -b/-p/-S behavioral tests — src/test.zig (missing)
6. [SUGGESTION] Assert -t 1 result, not just non-error — src/test.zig:826
7. [SUGGESTION] Clarify == alias stance with comment or implementation — src/test.zig:387
8. [SUGGESTION] Remove or merge parse-only operator tests — src/test.zig:975, 1228, 1273
