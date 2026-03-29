# Unit Test Audit: chown

**Date**: 2026-03-28
**Source**: src/chown.zig
**Tests run**: 33 total (10 privileged, 23 regular); all pass
  (privileged tests skipped without fakeroot)

## Executive Summary

NEEDS_FIXES

The chown unit tests have reasonable coverage of the parsing and
error-handling paths. However, the majority of privileged tests
are cannot-fail shells that call `chownFile()` with the file's own
current uid:gid, so no syscall change ever occurs and no assertion
verifies the outcome. -v/-c behavioral output is unchecked, -f does
not suppress errors correctly in the tested path, -H/-L/-P have
zero behavioral coverage, --dereference and --no-preserve-root are
parse-only stubs, and the -x flag test is acceptance-only. Six
MUST-tier flags have no behavioral test beyond "does not crash."

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| privileged: chown basic functionality | No — cannot-fail | STUB |
| chown with invalid owner specification | Yes | PASS |
| privileged: chown user only specification | No — cannot-fail | STUB |
| privileged: chown group only specification | No — cannot-fail | STUB |
| privileged: chown with reference file | No — cannot-fail | STUB |
| chown nonexistent file | Yes | PASS |
| OwnershipSpec parsing | Yes — parse layer | WEAK |
| getOwnershipFromReference | Partial — only checks non-null | WEAK |
| privileged: changeOwnership with same values | No — cannot-fail | STUB |
| privileged: chownSingle basic operation | No — cannot-fail | STUB |
| privileged: chown recursive option | No — cannot-fail | STUB |
| privileged: chown with verbose option | No — output unchecked | WEAK |
| privileged: chown with changes option | No — output unchecked | WEAK |
| privileged: chown with no-dereference option | No — cannot-fail | STUB |
| chown with silent option suppresses errors | Incorrect — see note | BUG |
| privileged: chown traverse options | No — no symlinks, no assert | STUB |
| error handling different error types | Yes | PASS |
| reportChange function | Yes (minimal) | PASS |
| chown printHelp does not crash | Yes | PASS |
| chown --help flag works via runChown | Yes | PASS |
| chown --version flag works | Yes | PASS |
| isNumericOwnerSpec accepts numeric specs | Yes | PASS |
| isNumericOwnerSpec rejects name specs | Yes | PASS |
| chown -n flag rejects non-numeric owner spec | Yes | PASS |
| chown -n flag accepts numeric owner spec | Partial — see note | WEAK |
| chown --preserve-root blocks recursive on / | Yes | PASS |
| chown --preserve-root allows non-recursive on / | Partial — exit code discarded | WEAK |
| chown --dereference flag is accepted | Parse-only via --help | STUB |
| chown --no-preserve-root flag is accepted | Parse-only via --help | STUB |
| chown -x flag is accepted | Parse-only via --help | STUB |
| runChown production path with valid file and owner spec | Partial — no change occurs | WEAK |
| chown help text includes new flags | Yes | PASS |

---

## Cannot-Fail Tests (CRITICAL)

### Privileged tests that never change ownership

```
[CRITICAL] 8 privileged tests call chownFile() with the file's own
  current uid:gid, guaranteeing no ownership change ever occurs
Location: src/chown.zig:539, 604, 641, 678, 765, 800, 844, 960
Problem: Every "basic functionality", "user only", "group only",
  "with reference file", "changeOwnership with same values",
  "chownSingle basic operation", "recursive option", and
  "no-dereference option" test constructs an owner_spec from
  getCurrentUserId()/getCurrentGroupId() — the file's actual
  owner — so chownSingle() detects no change needed and skips
  the syscall entirely. The `changed` flag at line 350 stays
  false; changeOwnership() is never called. These tests verify
  only that the code does not crash, not that it applies
  ownership correctly.
Fix: For each test, after chownFile() succeeds, stat the file
  and assert ownership equals the expected uid/gid. For genuine
  behavioral coverage under fakeroot, use a different uid/gid
  (e.g., current_uid + 1) so the change path is exercised and
  verify via stat.
```

### -v and -c output never checked

```
[CRITICAL] "privileged: chown with verbose option" and "privileged:
  chown with changes option" do not assert stdout output
Location: src/chown.zig:886 and 923
Problem: Both tests set verbose=true / changes=true and call
  chownFile(), but neither asserts that stdout_buffer contains
  any output. Because the tests use the file's own uid (cannot-
  fail pattern above), no change is detected, so -c would produce
  no output and -v would produce "retained" output — but neither
  is verified. A complete regression in reportChange() or
  reportNoChange() would pass both tests.
Fix: For -v: change the uid/gid so a real change occurs, then
  assert stdout_buffer contains "changed ownership of". For -c:
  assert stdout_buffer is empty when no change occurs, then run
  again with a different uid and assert it contains "changed
  ownership of".
```

---

## Silent Flag Bug (CRITICAL)

```
[CRITICAL] "chown with silent option suppresses errors" tests the
  wrong behavior: the test expects the error to propagate
Location: src/chown.zig:1003
Problem: The test sets options.silent = true and calls chownFile()
  on a nonexistent path, then asserts `expectError(error.FileNotFound)`.
  But the documented purpose of -f/--silent is to suppress errors
  and NOT return a failure exit code. The handleError() function at
  line 514 does suppress stderr output when silent=true, but
  chownSingle() still returns the error to its caller (line 341-342),
  which means exit_code is set to general_error. The test is asserting
  the WRONG behavior: a real chown -f on a nonexistent file exits 0.
  Additionally, the test calls chownFile() (internal helper) not
  runChown() — so the exit-code suppression logic in runChown() is
  not exercised at all.
Fix: The test should call runChown() with ["-f", "uid", "/nonexistent"]
  and assert exit_code == 0. The implementation likely needs fixing
  too: handleError() should not only suppress the message but also
  set a "suppress_errors" flag so the caller's exit_code stays 0.
```

---

## Parse-Only / Acceptance Stubs (IMPORTANT)

```
[IMPORTANT] --dereference flag test routes through --help
Location: src/chown.zig:1205
Problem: The args are ["--dereference", "--help"]. --help triggers
  early exit at line 122, so --dereference is parsed but never
  reaches any file operation. The test verifies only that
  ArgParser does not reject the flag.
Fix: Replace with a test that passes ["--dereference", spec, file]
  against a real file (or confirm it is a no-op flag and document
  that explicitly).

[IMPORTANT] --no-preserve-root flag test routes through --help
Location: src/chown.zig:1217
Problem: Same pattern as --dereference above. No file operation
  is performed.
Fix: Same as above.

[IMPORTANT] -x flag test routes through --help
Location: src/chown.zig:1229
Problem: Same pattern. -x (SHOULD-tier, no_cross_device) is
  completely untested behaviorally.
Fix: Add a privileged test that creates a directory structure,
  runs chown -Rx against it, and verifies ownership was applied
  only within the same mount point.
```

---

## Weak Tests (IMPORTANT)

```
[IMPORTANT] "privileged: chown traverse options" uses a regular
  file, not a symlink tree
Location: src/chown.zig:1019
Problem: The test creates only "test.txt" (a regular file) and
  runs chownFile() twice — once with traverse_all_symlinks=true
  (-L) and once with no_traverse_symlinks=true (-P). Both apply
  to a non-symlink, so neither branch of the symlink-traversal
  logic is exercised. The MUST flags -H, -L, -P are completely
  untested behaviorally.
Fix: Create a symlink pointing into a subdirectory. For -L: run
  chown -R -L and assert the symlink target's ownership changed.
  For -P (default): run chown -R -P and assert the symlink target
  is unchanged. For -H: create a symlink on the command line and
  assert it is followed.

[IMPORTANT] "chown -n flag accepts numeric owner spec" does not
  assert the exit code or behavior
Location: src/chown.zig:1163
Problem: The comment says "Should fail due to nonexistent file,
  not due to -n validation." The assertion is
  `expect(exit_code != misuse)`. This only confirms -n validation
  passed, not that the file operation was attempted. The test
  passes even if the implementation silently swallows the
  nonexistent-file error.
Fix: Assert the specific exit code (general_error = 1) and that
  stderr contains "No such file or directory".

[IMPORTANT] "chown --preserve-root allows non-recursive on /"
  discards the exit code
Location: src/chown.zig:1190
Problem: The test calls runChown() with ["--preserve-root",
  "1000:1000", "/"] and then does `_ = exit_code`. It asserts only
  that the preserve-root error message is absent. It does not check
  whether the command succeeded or failed.
Fix: Assert the exit code explicitly. Without -R, --preserve-root
  should not block the command. On a real system the operation
  would fail with PermissionDenied (exit 1), but the test should at
  minimum confirm it is not the preserve-root error code path.

[IMPORTANT] "getOwnershipFromReference" only checks non-null
Location: src/chown.zig:747
Problem: The test creates a file, calls getOwnershipFromReference,
  and asserts `ownership.user != null` and `ownership.group != null`.
  It does not verify the uid/gid match the file's actual stat values.
  A bug that returns hardcoded zeros would pass.
Fix: Stat the file directly and compare ownership.user and
  ownership.group against stat_info.uid and stat_info.gid.

[IMPORTANT] "OwnershipSpec parsing" tests the common library, not chown
Location: src/chown.zig:732
Problem: This test calls common.user_group.OwnershipSpec.parse()
  directly with numeric strings. It is a unit test of the common
  library, not of chown's behavior. It provides no coverage of the
  chown-specific parsing path (owner_spec extraction from positionals,
  --reference override, -n validation).
Fix: Acceptable to keep as a sanity check, but it should not be
  counted toward chown's behavioral coverage.
```

---

## Missing Coverage

| Flag | Tier | Has Behavioral Test? | Notes |
|------|------|---------------------|-------|
| -c   | SHOULD | No — cannot-fail pattern | Output never changes, never checked |
| -f   | SHOULD | No — incorrect test | Test asserts wrong behavior |
| -h   | MUST | No | Cannot-fail; lchown path never exercised |
| -H   | MUST | No | No symlink tree in test |
| -L   | MUST | No | No symlink tree in test |
| -P   | MUST | No | No symlink tree in test |
| -R   | MUST | No — cannot-fail | Recursive structure exists but uid unchanged |
| -v   | SHOULD | No — output unchecked | stdout_buffer never asserted |
| -x   | SHOULD | No | Parse-only via --help |
| -n   | SHOULD | Partial | Rejection tested; acceptance test weak |
| --reference | SHOULD | No — cannot-fail | Same uid/gid used |
| --dereference | SHOULD | No | Parse-only via --help |
| --preserve-root | SHOULD | Yes | Good behavioral test |
| --no-preserve-root | SHOULD | No | Parse-only via --help |

### -h (no_dereference) gap

The `chownSingle()` function at line 338 selects between `lstat()`
and `stat()` based on `options.no_dereference`, and `changeOwnership()`
at line 460 selects between `lchown()` and `chown()`. The privileged
"no-dereference option" test creates a symlink but then uses
getCurrentUserId() — the same uid — so neither lstat nor lchown is
reached with a real change. There is no test that verifies lchown()
is called instead of chown() when -h is set.

### -f (silent) implementation gap

The `handleError()` function suppresses the stderr message when
`options.silent` is true. However, `chownSingle()` still propagates
the error to its caller, which sets exit_code = general_error. GNU
chown with -f exits 0 on permission errors and file-not-found.
The test at line 1003 accidentally validates this broken behavior
by calling the internal `chownFile()` and expecting the error to
propagate — so the test would need to be fixed alongside the
implementation.

---

## Findings

| ID  | Severity   | Description |
|-----|------------|-------------|
| F01 | CRITICAL   | 8 privileged tests never trigger a real ownership change |
| F02 | CRITICAL   | -v and -c stdout output never asserted |
| F03 | CRITICAL   | -f silent test asserts wrong behavior (error should be suppressed) |
| F04 | IMPORTANT  | --dereference, --no-preserve-root, -x tests are parse-only via --help |
| F05 | IMPORTANT  | -H, -L, -P traverse tests use a regular file, not a symlink tree |
| F06 | IMPORTANT  | -n acceptance test does not assert specific exit code or stderr |
| F07 | IMPORTANT  | --preserve-root non-recursive test discards exit code |
| F08 | IMPORTANT  | getOwnershipFromReference does not compare uid/gid values |

---

## Summary

**Cannot-fail stubs**: 8 privileged tests (F01)
**Behavioral output unchecked**: 2 tests (F02)
**Incorrect test**: 1 (F03)
**IMPORTANT issues**: 5 (F04-F08)
**All tests pass**: yes (under normal, non-privileged execution)

**Fix Order:**
1. [CRITICAL] Fix -f/-silent implementation so exit_code stays 0
   when errors are suppressed; rewrite test to call runChown() and
   assert exit_code == 0 — src/chown.zig:1003, runChown() error path
2. [CRITICAL] Fix 8 privileged cannot-fail tests to use a different
   uid/gid and assert post-change stat values —
   src/chown.zig:539, 604, 641, 678, 765, 800, 844, 960
3. [CRITICAL] Fix -v test to assert stdout contains "changed
   ownership of"; fix -c test to assert stdout is empty on no-change
   and non-empty on change — src/chown.zig:886, 923
4. [IMPORTANT] Add privileged symlink-tree tests for -H, -L, -P
   that verify whether the symlink target's ownership changes —
   src/chown.zig:1019 (replace or supplement)
5. [IMPORTANT] Replace --dereference, --no-preserve-root, -x
   acceptance stubs with tests that reach a file operation —
   src/chown.zig:1205, 1217, 1229
6. [IMPORTANT] Fix getOwnershipFromReference to assert uid/gid
   match actual stat values — src/chown.zig:747
7. [IMPORTANT] Fix -n acceptance test to assert general_error exit
   code and "No such file" in stderr — src/chown.zig:1163
8. [IMPORTANT] Fix --preserve-root non-recursive test to assert
   the exit code explicitly — src/chown.zig:1190

REVIEW COMPLETE - NEEDS_FIXES
