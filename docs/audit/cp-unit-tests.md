# Unit Test Audit: cp

**Date**: 2026-03-28
**Source**: src/cp.zig
**Tests run**: all pass (confirmed via `zig build test --summary all`)

## Executive Summary

PASS WITH ISSUES

The cp unit tests are substantially better than most utilities
audited so far. Behavioral coverage exists for the core flags.
However, ten tests verify only config struct fields (parse-only
stubs), two `--preserve` tests fail to assert the preserved
attribute, and one test has a misleading comment that obscures a
partially-fixed bug. Three MUST flags have no behavioral tests.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| cp: single file copy | Yes | PASS |
| cp: copy to existing directory | Yes | PASS |
| cp: error on directory without recursive flag | Yes | PASS |
| cp: recursive directory copy | Yes | PASS |
| cp: preserve attributes | Yes | PASS |
| cp: symbolic link handling - follow by default | Yes | PASS |
| cp: symbolic link handling - no dereference (-d) | Yes | PASS |
| cp: multiple sources to directory | Yes | PASS |
| cp: large file copy | Yes | PASS |
| privileged: permission preservation with mode bits | Yes | PASS |
| cp: same file detection across devices via hardlink | Yes | PASS |
| cp: overwrite hint printed when destination exists | Yes | PASS |
| cp: overwrite hint NOT printed with -i flag | Yes | PASS |
| cp: overwrite hint NOT printed with -f flag | Yes | PASS |
| cp: overwrite hint printed only once for multiple files | Yes | PASS |
| cp: no hint when destination does not exist | Yes | PASS |
| cp: -R flag triggers recursive copy | Yes | PASS |
| cp: default symlink mode without -R is follow_all | Parse-only | STUB |
| cp: default symlink mode with -R is follow_none | Parse-only | STUB |
| cp: -P flag sets symlink mode to follow_none | Parse-only | STUB |
| cp: -L flag sets symlink mode to follow_all | Parse-only | STUB |
| cp: -H flag sets symlink mode to follow_cmdline | Parse-only | STUB |
| cp: -R -P preserves symlinks in directory tree | Yes | PASS |
| cp: -R -L follows all symlinks and copies as regular files | Yes | PASS |
| cp: -R -H follows command-line symlinks | Yes | PASS |
| cp: -R alone defaults to -P behavior | Yes | PASS |
| cp: without -R, symlinks are always followed | Yes | PASS |
| cp: -a flag enables recursive, preserve, and follow_none | Parse-only | STUB |
| cp: -n flag skips existing files | Yes | PASS |
| cp: -n flag creates file when destination does not exist | Yes | PASS |
| cp: -v flag prints verbose output to stdout | Yes | PASS |
| cp: -v flag with recursive prints each copied file | Yes | PASS |
| cp: -L -P last flag wins (POSIX) | Parse-only | STUB |
| cp: -P -L last flag wins (POSIX) | Parse-only | STUB |
| cp: -n -i last flag wins | Parse-only | STUB |
| cp: -b creates backup of existing destination | Yes | PASS |
| cp: -b does nothing when destination does not exist | Yes | PASS |
| cp: -S changes backup suffix | Yes | PASS |
| cp: -c flag accepted silently (no-op) | Yes | PASS |
| cp: -X flag accepted silently (no-op) | Yes | PASS |
| cp: -l creates hard link instead of copy | Yes | PASS |
| cp: -s creates symbolic link instead of copy | Yes | PASS |
| cp: -N flag sets follow_none (alias for -P) | Parse-only | STUB |
| cp: --parents creates intermediate directories | Yes | PASS |
| cp: --backup flag enables backup | Yes | PASS |
| cp: --backup=simple accepted | Yes | PASS |
| cp: --preserve flag enables preserve mode | Weak | SEE NOTE |
| cp: --preserve=mode accepted | Weak | SEE NOTE |
| cp: -x flag config sets one_file_system | Parse-only | STUB |
| cp: -l flag config sets hard_link | Parse-only | STUB |
| cp: -s flag config sets symbolic | Parse-only | STUB |
| cp: -b flag config sets backup | Parse-only | STUB |
| cp: -b -S sets backup with custom suffix | Parse-only | STUB |
| cp: -v verbose output goes to stdout not stderr | Yes | PASS |
| cp: -v stderr empty after successful verbose copy | Yes | PASS |
| cp: -v verbose message format matches GNU cp | Yes | PASS |
| cp: -f reports error when force-remove fails | Misleading | SEE NOTE |

---

## Parse-Only Tests (CRITICAL)

The following tests parse arguments and check `runtime()` struct
fields but do not run `runUtility()` against the filesystem. They
cannot catch a regression where parsing works but the runtime
ignores the resolved value.

```
[CRITICAL] Parse-only stub: symlink mode defaults
Location: src/cp.zig:1302, 1311
Problem: Checks rt.symlink_mode via config.runtime() only. Does
  not copy a symlink and verify the outcome changes. The behavioral
  tests at lines 1347-1510 already cover -R -P, -R -L, -R -H, and
  non-R behavior, making these stubs redundant — they can be deleted
  rather than upgraded.
Fix: Remove the four tests at lines 1302, 1311, 1320, 1329, 1338
  (covered by behavioral equivalents below them). If retained,
  each must create a symlink, run runUtility(), and assert whether
  the destination is or is not a symlink.

[CRITICAL] Parse-only stub: -a archive flag
Location: src/cp.zig:1511
Problem: Checks rt.recursive, rt.preserve, rt.symlink_mode via
  config.runtime(). Does not verify -a actually recursively copies
  a directory tree while preserving attributes and symlinks.
Fix: Replace with a test that creates a directory with a symlink
  and a file with a non-default mode, runs cp -a, and asserts the
  tree was copied, the symlink was preserved as a symlink, and the
  mode was preserved.

[CRITICAL] Parse-only stub: -L -P / -P -L / -n -i last-wins
Location: src/cp.zig:1623, 1633, 1643
Problem: Calls resolveConflicts() directly and checks struct fields.
  Does not invoke runUtility(), so cannot catch a bug in
  resolveConflicts wiring.
Fix: Each test should copy a symlink (for the -L/-P cases) or an
  existing file (for -n/-i), pass the conflicting flags in the
  correct order, and assert on filesystem outcome.

[CRITICAL] Parse-only stubs: -x, -l, -s, -b, -b -S config
Location: src/cp.zig:1956, 1965, 1973, 1981, 1990
Problem: Five tests that follow behavioral tests for the same flag
  (e.g., there is a full behavioral test for -l at line 1773 and a
  config stub at 1965). The stubs duplicate coverage already provided
  and add no value.
Fix: Delete lines 1956-1997. The behavioral tests at 1773, 1799,
  1656, and 1704 already cover these flags end-to-end.

[CRITICAL] Parse-only stub: -N flag
Location: src/cp.zig:1824
Problem: Checks follow_none via config.runtime() only. No behavioral
  test copies a symlink with -N and verifies the result.
Fix: Create a test that copies a symlink with -N and asserts the
  destination is a symlink (same as the -d / -P behavioral pattern).
```

---

## Weak Tests (IMPORTANT)

```
[IMPORTANT] --preserve and --preserve=mode do not assert
  preserved attributes
Location: src/cp.zig:1910, 1933
Problem: Both tests copy a file with mode 0o644 and call
  expectFileContent(). They do not stat the destination file to
  verify the mode was preserved. The existing privileged test
  (line 1076) and the -p behavioral test (line 927) do check modes,
  but those use -p, not --preserve. If --preserve were silently
  broken (e.g., mapped to a no-op), these tests would still pass.
Fix: After the copy, stat the destination and assert the mode bits
  match the source. Pattern is already shown at lines 948-954.

[IMPORTANT] -f test comment contradicts test behavior
Location: src/cp.zig:2079
Problem: The comment says "currently this fails because catch {}
  silently discards the error." But the test PASSES. The comment
  is wrong: at line 488, the regular-file copy path uses
  `catch |err| { printError(...) }` and DOES report the error.
  The test passes because the test exercises the copyFile path,
  not the createHardLink path. The bug described in the comment
  still EXISTS in createHardLink (line 538, `catch {}`), but there
  is no test for it. The stale comment will mislead future readers
  into thinking this is a known-failing test.
Fix:
  1. Update the comment to accurately describe what is happening:
     the regular-file path reports the error, but the -l (hard
     link) path silently swallows it.
  2. Add a separate test: cp -f -l source readonly_dir/dest
     and assert stderr contains "cannot" or "permission denied".
```

---

## Missing Coverage

| Flag | Tier | Has Behavioral Test? | Notes |
|------|------|---------------------|-------|
| -a   | MUST | No                  | Parse-only stub at 1511 |
| -H   | MUST | Yes (1407)          | OK |
| -i   | MUST | No                  | Hint-suppression tests exist but -i overwrite prompt flow is untested |
| -L   | MUST | Yes (1378)          | OK |
| -P   | MUST | Yes (1347)          | OK |
| -R   | MUST | Yes (1278)          | OK |
| -v   | MUST | Yes (1567, 1591)    | OK |
| -f   | MUST | Partial             | Regular-file path tested; hard-link path not tested (see above) |
| -p   | MUST | Yes (927, 1076)     | OK |
| -b   | SHOULD | Yes (1656)        | OK |
| -c   | SHOULD | Yes (1727)        | Accepted as no-op — correct |
| -d   | SHOULD | Yes (983)         | OK |
| -l   | SHOULD | Yes (1773)        | OK |
| -n   | SHOULD | Yes (1521)        | OK |
| -N   | SHOULD | No                | Parse-only stub only |
| -s   | SHOULD | Yes (1799)        | OK |
| -S   | SHOULD | Yes (1704)        | OK |
| -x   | SHOULD | No                | Parse-only stub only |
| -X   | SHOULD | Yes (1750)        | Accepted as no-op — correct |
| --parents | SHOULD | Yes (1833)  | OK |
| --preserve | SHOULD | Weak (1910) | Content verified, mode not |

### -i flag gap

The interactive flag has no behavioral test for the actual prompt
flow. The existing tests only confirm the overwrite hint is
suppressed when -i is present. There is no test that feeds 'y' or
'n' to stdin and verifies whether the copy proceeds or is skipped.
This is a known hard test to write (requires stdin injection), but
the gap is real.

---

## Findings

| ID  | Severity   | Description |
|-----|------------|-------------|
| F01 | CRITICAL   | Parse-only stubs: 5 symlink-mode tests check struct fields, not behavior |
| F02 | CRITICAL   | Parse-only stub: -a checks rt fields only, not recursive+preserve behavior |
| F03 | CRITICAL   | Parse-only stubs: last-wins flag tests call resolveConflicts directly |
| F04 | CRITICAL   | Parse-only stubs: 5 config tests duplicate existing behavioral tests |
| F05 | CRITICAL   | Parse-only stub: -N has no behavioral symlink test |
| F06 | IMPORTANT  | --preserve / --preserve=mode tests confirm content, not mode preservation |
| F07 | IMPORTANT  | -f test comment wrong: describes a bug that was partially fixed; stale |
| F08 | IMPORTANT  | -f + hard link path swallows errors silently (catch {}), no test |
| F09 | IMPORTANT  | -i overwrite prompt (y/n stdin) has zero behavioral test coverage |
| F10 | IMPORTANT  | -x (one_file_system) has no behavioral test — parse-only stub only |

---

## Summary

**Parse-only stubs**: 10 tests (F01-F05)
**IMPORTANT issues**: 5 (F06-F10)
**All tests pass**: yes

**Fix Order:**
1. [CRITICAL] Delete 5 redundant config-stub tests for -x, -l, -s,
   -b, -b -S — src/cp.zig:1956-1997
2. [CRITICAL] Delete 4 redundant symlink-mode parse stubs (behavioral
   equivalents exist) — src/cp.zig:1302-1345
3. [CRITICAL] Replace -a stub with behavioral test (dir+symlink+mode
   tree) — src/cp.zig:1511
4. [CRITICAL] Replace -N stub with symlink behavioral test —
   src/cp.zig:1824
5. [CRITICAL] Replace 3 last-wins stubs with runUtility-based tests —
   src/cp.zig:1623-1652
6. [IMPORTANT] Fix stale comment in -f test; add separate test for
   -f -l (hard link) path not reporting errors — src/cp.zig:2079,
   src/cp.zig:538
7. [IMPORTANT] Add mode-bit assertions to --preserve and
   --preserve=mode tests — src/cp.zig:1910, 1933
8. [IMPORTANT] Add -x behavioral test (requires crossing a mount
   point, or document as integration-test-only) — src/cp.zig:1956
9. [IMPORTANT] Add -i stdin-injection test or document the gap
   explicitly — src/cp.zig (no current test)

REVIEW COMPLETE - NEEDS_FIXES
