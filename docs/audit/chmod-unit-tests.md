# Unit Test Audit: chmod

**Date**: 2026-03-28
**Source**: src/chmod.zig
**Tests run**: 76 total; all pass (privileged tests skipped
  without fakeroot)

## Executive Summary

NEEDS_FIXES

The chmod unit tests have strong behavioral coverage for the
core mode-parsing and symbolic-mode machinery. However, 18 of
76 tests are parse-only stubs that check struct fields instead
of filesystem outcomes. The three MUST flags with symlink
semantics (-H, -L, -P) have zero behavioral tests. The -c
(changes) and -v (verbose) flags are covered by privileged
tests only, with no non-privileged behavioral path. Two known
bugs are documented inside failing tests instead of being
tracked as failing tests — masking real regressions.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| parseMode handles 3-digit octal modes | No — parse-only | STUB |
| parseMode handles 4-digit octal modes | No — parse-only | STUB |
| parseMode rejects invalid octal digits | Yes | PASS |
| parseMode rejects modes over 777 | No — parse-only | STUB |
| parseMode rejects empty mode | No — parse-only | STUB |
| parseMode accepts 1-4 digit octal modes | No — parse-only | STUB |
| Mode.fromOctal and toOctal roundtrip | No — parse-only | STUB |
| modeToString converts correctly | No — parse-only | STUB |
| privileged: applyModeSpecToFile basic functionality | Yes | PASS |
| privileged: chmodFiles handles multiple files | Yes | PASS |
| chmodFiles handles nonexistent files gracefully | Yes | PASS |
| privileged: chmod integration test with octal mode | Yes | PASS |
| chmod handles invalid mode strings | No — parse-only | STUB |
| Mode struct supports special permissions | No — parse-only | STUB |
| parseMode handles 4-digit octal with special bits | No — parse-only | STUB |
| modeToString includes special permission bits | No — parse-only | STUB |
| parseSymbolicMode basic additions | No — parse-only | STUB |
| parseSymbolicMode basic subtractions | No — parse-only | STUB |
| parseSymbolicMode basic assignments | No — parse-only | STUB |
| parseSymbolicMode multiple targets | No — parse-only | STUB |
| parseSymbolicMode complex combinations | No — parse-only | STUB |
| parseSymbolicMode special permission bits | No — parse-only | STUB |
| parseSymbolicModeString with special bits | No — parse-only | STUB |
| parseSymbolicMode permission copying | No — parse-only | STUB |
| parseSymbolicMode permission copying with + operator | No — parse-only | STUB |
| parseSymbolicMode permission copying with - operator | No — parse-only | STUB |
| X permission skipped on regular file without existing execute | No — parse-only | STUB |
| X permission applied on directory | No — parse-only | STUB |
| X permission applied when file already has user execute | No — parse-only | STUB |
| X permission applied when file already has group execute | No — parse-only | STUB |
| X permission applied when file already has other execute | No — parse-only | STUB |
| X permission skipped with null current_mode | No — parse-only | STUB |
| X permission for specific user class on directory | No — parse-only | STUB |
| X permission combined with other perms on file without execute | No — parse-only | STUB |
| X permission combined with other perms on directory | No — parse-only | STUB |
| privileged: recursive chmod on directory structure | Yes (weak) | SEE NOTE |
| privileged: recursive flag processes files and directories | Yes (weak) | SEE NOTE |
| privileged: verbose flag outputs changes | Yes | PASS |
| privileged: changes flag only outputs when mode changes | Yes | PASS |
| quiet flag suppresses error messages | Yes | PASS |
| error handling consistency | No — parse-only | STUB |
| hasNonOctalDigits detects 8 and 9 in mode string | No — parse-only | STUB |
| hasNonOctalDigits returns false for valid octal modes | No — parse-only | STUB |
| hasNonOctalDigits returns false for symbolic modes | No — parse-only | STUB |
| non-octal digit warning is printed to stderr | Yes | PASS |
| no non-octal digit warning for valid octal mode | Yes | PASS |
| parse -H flag | Parse-only | STUB |
| parse -L flag | Parse-only | STUB |
| parse -P flag | Parse-only | STUB |
| ChmodOptions has symlink traversal fields | Parse-only | STUB |
| ChmodOptions symlink traversal defaults to false | Parse-only | STUB |
| chmod: -h flag is parsed as no_dereference | Parse-only | STUB |
| chmod: --help still works as long-only flag | Parse-only | STUB |
| ChmodOptions has no_dereference field | Parse-only | STUB |
| chmod --preserve-root blocks recursive on / | Yes | PASS |
| chmod --preserve-root allows non-recursive on / | Yes (weak) | SEE NOTE |
| chmod --dereference flag is accepted | Parse-only | STUB |
| chmod --no-preserve-root flag is accepted | Parse-only | STUB |
| chmod -C flag is accepted (ACL no-op) | Parse-only | STUB |
| chmod -E flag is accepted (ACL no-op) | Parse-only | STUB |
| chmod -i flag is accepted (ACL no-op) | Parse-only | STUB |
| chmod -I flag is accepted (ACL no-op) | Parse-only | STUB |
| chmod -N flag is accepted (ACL no-op) | Parse-only | STUB |
| chmod help text includes new flags | Yes | PASS |
| chmod ChmodOptions has preserve_root field | Parse-only | STUB |
| chmod ChmodOptions preserve_root defaults to false | Parse-only | STUB |
| a+t sets sticky bit on file with mode 0644 | No — parse-only | STUB |
| u+t sets sticky bit on file with mode 0644 | No — parse-only | STUB |
| g+t sets sticky bit on file with mode 0644 | No — parse-only | STUB |
| o+t sets sticky bit on file with mode 0644 | No — parse-only | STUB |
| a-t removes sticky bit from file with mode 01644 | No — parse-only | STUB |
| u-t removes sticky bit from file with mode 01644 | No — parse-only | STUB |
| chmod stat AccessDenied produces correct message | Yes (buggy) | SEE NOTE |
| chmod stat AccessDenied returns AccessDenied | Yes (buggy) | SEE NOTE |
| parseMode with symbolic string routes through fallback | No — parse-only | STUB |
| parseMode with octal string returns correct mode | No — parse-only | STUB |

---

## Parse-Only Tests (CRITICAL)

### Symbolic mode and octal parsing stubs

```
[CRITICAL] Parse-only stubs: mode parsing and Mode struct tests
Location: src/chmod.zig:903-962
Problem: 9 tests validate parseMode(), Mode.fromOctal(),
  Mode.toOctal(), and modeToString() in isolation without touching
  the filesystem. They test the internal representation, not whether
  a real file's permissions change when those modes are applied.
  A bug where the parsed Mode is constructed correctly but discarded
  before the chmod() syscall would pass all of these.
Fix: Each distinct mode class (3-digit, 4-digit, special bits)
  should have one privileged test that creates a tmp file, runs
  runUtility() with that mode, and stats the file to assert the
  bits match.
```

### Symbolic mode clause tests

```
[CRITICAL] Parse-only stubs: applySymbolicMode tests
Location: src/chmod.zig:1193-1460
Problem: 19 tests call applySymbolicMode() or
  parseSymbolicModeString() directly and assert Mode struct fields.
  None of them call runUtility() or chmodFiles() and verify an
  actual file's mode changed. A regression in applyModeSpecToFile()
  that ignores the symbolic path would pass all 19 tests.
Fix: Representative tests (additions, subtractions, assignments,
  special bits, X permission, permission copying) each need a
  privileged counterpart that applies the mode to a real file and
  stats the result. The parse-layer tests may be kept as unit tests
  of the parser, but the filesystem path must also be covered.
```

### -H, -L, -P symlink traversal flag stubs

```
[CRITICAL] Parse-only stubs: -H, -L, -P flags
Location: src/chmod.zig:1698-1741
Problem: 5 tests check parsed struct fields (parsed.H, parsed.L,
  parsed.P, ChmodOptions.traverse_cmdline_symlinks, etc.). None
  create a symlink and a directory, run chmod -R with one of these
  flags, and verify whether the symlink target's mode changed or
  not. These are MUST-tier flags per chmod-flags.md and have zero
  behavioral coverage.
Fix: Write three privileged behavioral tests:
  - chmod -R -H: symlink on the command line should be followed;
    assert the target directory's mode changes, not the link's.
  - chmod -R -L: symlink encountered during traversal should be
    followed; assert linked-to directory's mode changes.
  - chmod -R -P (default): symlink encountered during traversal
    should NOT be followed; assert linked-to dir's mode is
    unchanged.
```

### -h (no_dereference) and flag-conflict stubs

```
[CRITICAL] Parse-only stubs: -h, --dereference, --no-preserve-root
Location: src/chmod.zig:1743-1820
Problem: "chmod: -h flag is parsed as no_dereference" and
  "ChmodOptions has no_dereference field" check struct fields only.
  "chmod --dereference flag is accepted" and
  "chmod --no-preserve-root flag is accepted" route through
  --help (exit 0) rather than applying a mode to a file.
  None verify that -h actually changes the symlink rather than
  the target file.
Fix: Add one privileged behavioral test: create a symlink,
  run chmod -h <mode> <symlink>, and stat the symlink itself via
  lstat to verify the mode changed on the link, not the target.
  The --dereference and --no-preserve-root acceptance tests can
  remain as-is since they test a no-op flag.
```

### ACL no-op flag stubs

```
[CRITICAL] Parse-only stubs: -C, -E, -i, -I, -N
Location: src/chmod.zig:1822-1855
Problem: Five tests call ArgParser.parse() and check the
  acl_check / acl_stdin / etc. fields. None call runUtility() and
  verify the exit code is 0 (accepted without error) when a real
  file is present. A bug that treats -C as an unknown flag would
  return exit code 1; these tests would still pass.
Fix: Replace parse-only checks with 5 brief runUtility() calls
  that pass a real (or tmpdir) file alongside the flag and assert
  exit code 0. The filesystem result need not be checked (flags
  are no-ops), but the exit code must be.
```

### ChmodOptions field stubs

```
[CRITICAL] Parse-only stubs: ChmodOptions field assertions
Location: src/chmod.zig:1725-1741, 1761-1766, 1869-1879
Problem: 7 tests construct a ChmodOptions{} literal and assert
  that a field is true or false. These tests cannot fail unless
  someone renames the field, which the compiler would catch anyway.
  They add zero behavioral signal.
Fix: Delete all 7 tests. They are redundant: the compiler enforces
  struct field existence; behavioral tests confirm wiring.
```

### Sticky bit and mode-round-trip stubs

```
[CRITICAL] Parse-only stubs: sticky bit via applySymbolicMode
Location: src/chmod.zig:1883-1925
Problem: 6 tests call applySymbolicMode() and check mode.sticky
  or mode.toOctal(). No file is created; no chmod syscall is made.
  The same coverage gap as the symbolic mode stubs above: a bug
  in the syscall path for sticky bits would not be caught.
Fix: Add one privileged behavioral test that creates a tmpdir,
  runs chmod +t on it, and stats to verify the sticky bit is set
  in the real kernel-reported mode.
```

---

## Weak Tests (IMPORTANT)

```
[IMPORTANT] "privileged: recursive chmod on directory structure"
  does not assert file modes
Location: src/chmod.zig:1464-1504
Problem: The test verifies only that stdout_buffer.items.len > 0
  (verbose output was produced). It does not stat any file in the
  tree to confirm the mode was actually applied. A verbose output
  bug that prints to stdout but applies the wrong mode would pass.
Fix: After chmodFiles(), stat at least one file and one
  subdirectory and assert the mode equals 0o755.

[IMPORTANT] "privileged: recursive flag processes files and
  directories" has no assertion
Location: src/chmod.zig:1506-1537
Problem: The comment says "The test passes if no errors are
  thrown." No mode is verified. This tests only that the code
  does not crash, not that it applies the correct mode.
Fix: After chmodFiles(), stat the directory and the inner file
  and assert mode 0o644 on both.

[IMPORTANT] "chmod --preserve-root allows non-recursive on /"
  discards the exit code
Location: src/chmod.zig:1783-1796
Problem: The test calls runUtility() and then does `_ = exit_code`.
  It checks only that the preserve-root error message is absent.
  It does not verify what exit code was returned or that a
  Permission denied message was (or wasn't) present.
Fix: Assert the exit code. At minimum, assert it is not 0 (chmod
  on / without permission should fail) or document why the test
  intentionally ignores the code.
```

---

## Known-Bug Tests (IMPORTANT)

```
[IMPORTANT] Two tests document known bugs but are written to PASS
Location: src/chmod.zig:1928-2022
Problem: "chmod stat AccessDenied produces correct Permission
  denied message" and "chmod stat AccessDenied returns
  AccessDenied not PermissionDenied" both contain extensive
  in-line bug descriptions explaining that applyModeSpecToFile()
  substitutes a zeroed Stat instead of propagating AccessDenied.
  The tests are written to accept the BUGGY behavior (the first
  accepts "Permission denied" from PermissionDenied; the second
  uses expectError(error.AccessDenied) against the BUGGY code path).
  If the bug is later fixed, the second test would fail on the
  wrong error — but if the bug is NOT fixed, a reader cannot tell
  from the test result that a bug exists.
Fix: Write the tests to assert CORRECT behavior and let them fail
  RED until the bug is fixed. Add a TODO comment linking to a
  tracked issue. The current approach gives false-green confidence
  that this code path works correctly.
```

---

## Missing Coverage

| Flag | Tier | Has Behavioral Test? | Notes |
|------|------|---------------------|-------|
| -c   | SHOULD | Yes (privileged only) | OK under fakeroot |
| -f   | SHOULD | Partial — nonexistent file tested; permission-denied suppression not tested | Gap |
| -h   | MUST | No | Parse-only stub; no symlink-mode behavioral test |
| -H   | MUST | No | Parse-only stub only |
| -L   | MUST | No | Parse-only stub only |
| -P   | MUST | No | Parse-only stub only |
| -R   | MUST | Yes (privileged) | Weak — no mode assertions |
| -v   | SHOULD | Yes (privileged) | OK |
| -C   | SHOULD | No | Parse-only stub; no exit-code test |
| -E   | SHOULD | No | Parse-only stub; no exit-code test |
| -i   | SHOULD | No | Parse-only stub; no exit-code test |
| -I   | SHOULD | No | Parse-only stub; no exit-code test |
| -N   | SHOULD | No | Parse-only stub; no exit-code test |
| --reference | SHOULD | No | No test at all |
| --dereference | SHOULD | No | Acceptance test uses --help, not a file |
| --preserve-root | SHOULD | Yes | Good behavioral test |
| --no-preserve-root | SHOULD | No | Parse-only stub |

### --reference gap

The `--reference=RFILE` path is implemented in `chmodFiles()` at
line 301 but has no unit test of any kind. A test should create two
tmp files, stat the first to get its mode, run chmod with
--reference pointing to the first, and stat the second to confirm
its mode now matches.

### -f (silent) flag gap

The quiet flag is tested only for a file-not-found case. There is
no test that confirms -f suppresses an AccessDenied error message
when a real permission failure occurs.

---

## Findings

| ID  | Severity   | Description |
|-----|------------|-------------|
| F01 | CRITICAL   | 9 mode-parsing stubs test internal structs, not filesystem |
| F02 | CRITICAL   | 19 symbolic-mode stubs call applySymbolicMode directly |
| F03 | CRITICAL   | 3 symlink traversal flag tests are parse-only (-H, -L, -P) |
| F04 | CRITICAL   | -h flag test is parse-only; no symlink behavioral test |
| F05 | CRITICAL   | 5 ACL no-op flag tests parse only; exit code unchecked |
| F06 | CRITICAL   | 7 ChmodOptions field assertions add zero signal; delete them |
| F07 | CRITICAL   | 6 sticky-bit tests call applySymbolicMode directly |
| F08 | IMPORTANT  | Recursive test passes with no mode assertion |
| F09 | IMPORTANT  | Recursive flag test has no assertion ("no error" only) |
| F10 | IMPORTANT  | --preserve-root non-recursive test discards exit code |
| F11 | IMPORTANT  | Two bug-documenting tests written to accept buggy output |
| F12 | IMPORTANT  | --reference flag has no test of any kind |
| F13 | IMPORTANT  | -f suppression of AccessDenied not tested |

---

## Summary

**Parse-only stubs**: 49 tests (F01-F07)
**IMPORTANT issues**: 6 (F08-F13)
**All tests pass**: yes (under normal, non-privileged execution)

**Fix Order:**
1. [CRITICAL] Delete 7 ChmodOptions field stubs; they cannot fail
   — src/chmod.zig:1725-1741, 1761-1766, 1869-1879
2. [CRITICAL] Add 3 privileged behavioral tests for -H, -L, -P:
   create a symlink tree, run chmod -R with each flag, verify
   whether the symlink target's mode changes — src/chmod.zig
   (no current test)
3. [CRITICAL] Add one privileged behavioral test for -h:
   create a symlink, run chmod -h, lstat to verify the link
   itself changed — src/chmod.zig (no current test)
4. [CRITICAL] Replace 5 ACL flag parse stubs with runUtility()
   calls that assert exit code 0 on a real file —
   src/chmod.zig:1822-1855
5. [CRITICAL] Add privileged behavioral counterparts for
   representative symbolic mode and X permission cases —
   src/chmod.zig:1193-1460
6. [CRITICAL] Add one privileged behavioral test for sticky bit
   via symbolic mode — src/chmod.zig:1883-1925
7. [IMPORTANT] Fix the two AccessDenied tests to assert correct
   behavior (fail RED until bug is fixed) —
   src/chmod.zig:1928-2022
8. [IMPORTANT] Add mode assertions to both recursive tests —
   src/chmod.zig:1464-1537
9. [IMPORTANT] Add --reference behavioral test —
   src/chmod.zig (no current test)
10. [IMPORTANT] Fix --preserve-root non-recursive test: assert
    exit code explicitly — src/chmod.zig:1783-1796
11. [IMPORTANT] Add -f AccessDenied suppression test

REVIEW COMPLETE - NEEDS_FIXES
