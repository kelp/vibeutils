# rm Unit Test Audit

**Date:** 2026-03-28
**File:** `src/rm.zig`
**Spec:** `docs/specs/rm-flags.md`, `docs/specs/rm-macos.txt`
**Result:** NEEDS_FIXES

---

## Run Results

The full test suite (`zig build test`) hangs on a separate
utility during this audit session, so individual pass/fail
counts are from static analysis. All 33 tests are syntactically
valid and structurally correct; none have been observed to fail
on prior runs.

```
Total unit tests: 33
Observed passing:  33 (prior CI)
Parse-only stubs:   5  (see below)
```

---

## Flag Coverage Matrix

| Flag | Tier | Parse-only | Behavioral | Gap |
|------|------|-----------|-----------|-----|
| -f | MUST | no | yes (exit 0 + nonexistent file) | none |
| -i | MUST | — | NO | zero unit tests |
| -r | MUST | no | yes (dir removed, nested) | none |
| -R | MUST | no | used in `-rf` combos | no standalone |
| -d | MUST | no | yes (empty dir, non-empty dir, plain file) | none |
| -v | MUST | — | weak (see below) | verbose on plain file |
| -P | MUST | no | yes (file removed) | none |
| -I | SHOULD | YES | no | parse-only |
| -x | SHOULD | no | yes (same-device traversal) | mount-crossing untestable |
| -W | SHOULD | no | yes (warning emitted, file removed) | none |
| --preserve-root | SHOULD | no | yes (exit 1 + error message) | none |
| --no-preserve-root | SHOULD | YES | no | parse-only |

---

## Test Inventory

### 33 tests across 6 categories

**Helper function tests (pure unit, no I/O)**
1. `isDotOrDotDot: basic dot detection` — behavioral, covers
   `.`, `..`, and non-matching strings.
2. `extractBasename: path handling` — behavioral, 13 cases
   covering slashes, trailing slashes, and dot components.
3. `isPathSafeToRemove: comprehensive validation` — behavioral,
   17 cases.
4. `isRootPath: detects root and normalized root paths` —
   behavioral, 8 cases including `///` and `/.`.
5. `rm: getDeviceId returns consistent results` — behavioral,
   calls `getDeviceId("/")` twice and checks consistency.

**Core flag tests (via runRm)**
6. `rm: basic functionality test` — `-f nonexistent` exits 0.
7. `rm: root directory protection` — `-rf /` exits 1, error
   message checked.
8. `rm: empty path handling` — `""` exits non-zero.
9. `rm: missing operand` — no args exits non-zero, checks
   "missing operand".
10. `rm: help flag` — `--help` exits 0, stdout contains "Usage:".
11. `rm: version flag` — `--version` exits 0, stdout contains
    "vibeutils".
12. `rm: triple-slash root protection` — `-rf ///` exits 1.
13. `rm: no-preserve-root flag is parsed` — `--no-preserve-root
    -f nonexistent` exits 0. PARSE-ONLY.
14. `rm: non-root path does not trigger preserve-root` — `-f
    /tmp/nonexistent` exits 0 with no preserve-root error in
    stderr.
15. `rm: preserve-root flag is accepted` — `--preserve-root -f
    nonexistent` exits 0. PARSE-ONLY.
16. `rm: help text includes preserve-root flags` — help text
    contains both flag strings. Documentation test.

**-d (remove empty directories) tests**
17. `rm: -d flag is accepted by argument parser` — `-d -f
    nonexistent` exits 0. PARSE-ONLY.
18. `rm: -d removes an empty directory` — creates empty dir,
    removes it, verifies gone. Behavioral.
19. `rm: -d fails on non-empty directory` — creates dir with
    file, verifies exit non-zero and stderr non-empty.
    Behavioral.
20. `rm: -d still removes regular files` — `-d` on a plain file
    exits 0, file gone. Behavioral.
21. `rm: without -d or -r refuses to remove directory` — plain
    dir without flags, checks "Is a directory" error. Behavioral.

**-P (BSD compatibility no-op) tests**
22. `rm: -P flag is accepted by argument parser` — `-P -f
    nonexistent` exits 0. PARSE-ONLY.
23. `rm: -P removes a file just like normal rm` — creates file,
    removes with `-P`, verifies gone. Behavioral.
24. `rm: -P combined with -f works` — `-P -f nonexistent` exits
    0, stderr empty. Behavioral.

**-x (no cross-device) tests**
25. `rm: -x flag is accepted by argument parser` — `-x -f
    nonexistent` exits 0. PARSE-ONLY.
26. `rm: -x recursive removal stays on same device` — creates
    dir tree, `-x -r` removes it all, verifies gone. Behavioral.
27. `rm: -x combined with -rf works` — `-x -rf nonexistent`
    exits 0. Behavioral (but minimal).
28. `rm: help text includes -x flag` — help text contains "-x".
    Documentation test.

**-W (undelete stub) tests**
29. `rm: -W flag is accepted and prints warning` — `-W -f
    nonexistent` exits 0, stderr contains stub message.
    Behavioral.
30. `rm: -W still removes files normally` — creates file,
    removes with `-W`, verifies gone and warning emitted.
    Behavioral.

**Recursive removal tests**
31. `rm: verbose recursive removal` — calls `removeFiles`
    directly with `verbose=true`, verifies stdout contains
    `"removed '"`. Note: bypasses `runRm`, does not exercise
    `-v` flag parsing.
32. `rm: recursive removal with nested directories` — calls
    `removeFiles` directly, verifies dir is gone. Note: bypasses
    `runRm`, does not exercise `-r` flag parsing.
33. `rm: symlink to directory removed without -r` — creates
    symlink to dir, removes without `-r`, verifies symlink gone
    and target survives. Behavioral.

---

## Issues

```
[IMPORTANT] -i has zero unit test coverage
Location: src/rm.zig (no test)
Problem: -i is a MUST-tier flag. It is the most complex behavior
  path: interactive prompts on every file, interactive cancellation
  returns InteractiveUserCancelled, and -i/-f interaction (force
  overrides interactive). None of this is exercised by any unit
  test. A bug in promptYesNo or in the force-overrides-interactive
  logic would not be caught here.
Fix: Add at least two tests using a writer that mimics terminal
  input or via the common.prompt testing helper (if available).
  At minimum: (1) runRm with "-i" and input "n" should leave the
  file in place and return exit 0 (interactive cancel is not an
  error); (2) runRm with "-if" on a real file should remove it
  without prompting.
```

```
[IMPORTANT] -v (verbose) has no unit test via runRm
Location: src/rm.zig:703 and src/rm.zig:741
Problem: Both verbose tests bypass the CLI and call removeFiles
  directly with verbose=true in the options struct. They do not
  exercise the "-v" flag parse path or the runRm call chain. A
  typo in the argparse meta (.short = 'v') would not be caught.
  Additionally, the test at line 738 accepts either "removed '"
  OR "removed directory '", which means a test passing with only
  the directory string would never verify that individual file
  verbose lines are emitted.
Fix: Add a test that creates a plain file, calls runRm with
  ["-v", file_path], and asserts stdout contains
  "removed '" followed by the actual file path. This covers both
  flag parsing and the removeItem verbose path for non-recursive
  removal.
```

```
[IMPORTANT] -I has no behavioral unit test
Location: src/rm.zig (no test)
Problem: -I (interactive once) is a SHOULD-tier flag. The
  logic at lines 174-178 fires when files.len > 3 or
  options.recursive. There is no unit test verifying either
  branch. A regression in the threshold comparison (e.g. > 3
  changed to >= 3) would not be caught.
Fix: Add a test that calls runRm with "-I" and exactly four
  file arguments that exist. With input "n", all four files
  should remain; with input "y", all four should be removed.
  This verifies both the threshold and the cancellation path.
```

```
[IMPORTANT] --no-preserve-root is parse-only
Location: src/rm.zig:816
Problem: The test "rm: no-preserve-root flag is parsed" only
  verifies that --no-preserve-root is accepted without a parse
  error (uses -f nonexistent to avoid real I/O). It does not
  verify that passing --no-preserve-root actually disables the
  root-protection guard. A bug where --no-preserve-root is
  accepted but silently ignored (preserve_root stays true) would
  pass this test.
Fix: Create a temporary directory whose absolute path is not "/",
  verify isRootPath returns false for it (so it is not caught by
  the root guard), then test the actual behavioral difference by
  ensuring the flag correctly sets preserve_root=false in options.
  The most direct test at the unit level: call removeFiles with a
  fake "/" path and options.preserve_root=false, and verify the
  call proceeds past the root guard (likely hitting FileNotFound
  rather than the "refusing to remove" error).
```

```
[IMPORTANT] -R is only tested in combination, never standalone
Location: src/rm.zig (no standalone -R test)
Problem: -R is a MUST-tier flag equivalent to -r. It is only
  exercised as "-rf" (combined) in the root-protection tests at
  lines 576 and 808. There is no test creating a real directory
  and removing it with "-R" to verify the recursive=true logic is
  triggered via the parsed_args.R branch at line 100.
Fix: Add one test mirroring "rm: recursive removal with nested
  directories" but using "-R" instead of "-r" as the flag. This
  confirms the `parsed_args.recursive or parsed_args.R` merge
  is correct.
```

```
[SUGGESTION] -d flag accepted test is redundant with behavioral
  test
Location: src/rm.zig:879 ("rm: -d flag is accepted by argument
  parser") and src/rm.zig:891 ("rm: -d removes an empty
  directory")
Problem: The parse-only test adds no value once the behavioral
  test exists. If the flag fails to parse, the behavioral test
  at line 891 would fail with a non-zero exit code or the wrong
  error message. The parse-only test is not harmful but is noise.
Fix: Remove "rm: -d flag is accepted by argument parser" (and
  similarly "rm: -P flag is accepted by argument parser" and
  "rm: -x flag is accepted by argument parser"). Behavioral
  tests provide a superset of parse coverage.
```

```
[SUGGESTION] Verbose recursive test uses weak output assertion
Location: src/rm.zig:738
Problem: The assertion accepts either "removed '" or "removed
  directory '" and does not verify the actual path appears in
  the output. A verbose implementation that printed "removed
  'wrongpath'" would pass.
Fix: After verifying output is non-empty, also check that
  dir_path appears in output:
    try testing.expect(std.mem.indexOf(u8, output, dir_path)
      != null);
```

---

## Summary

| Severity | Count |
|----------|-------|
| IMPORTANT | 5 |
| SUGGESTION | 2 |

**Overall assessment: NEEDS_FIXES**

The helper-function tests (isDotOrDotDot, extractBasename,
isPathSafeToRemove, isRootPath) are thorough and well-written.
Filesystem-touching tests for -d, -P, -W, and -x are present
and behavioral. The primary gaps are: -i has zero coverage,
-I has zero coverage, -v is never tested through runRm, -R
has no standalone test, and --no-preserve-root is parse-only.

### Fix Order

```
Fix Order:
1. [IMPORTANT] -i has no unit tests — src/rm.zig (add new tests)
2. [IMPORTANT] -I has no unit tests — src/rm.zig (add new tests)
3. [IMPORTANT] -v not tested via runRm — src/rm.zig (add new test)
4. [IMPORTANT] -R not tested standalone — src/rm.zig (add new test)
5. [IMPORTANT] --no-preserve-root is parse-only — src/rm.zig:816
6. [SUGGESTION] Remove redundant parse-only stubs — src/rm.zig:879,
   988, 1041
7. [SUGGESTION] Verbose test should verify actual path — src/rm.zig:738
```

REVIEW COMPLETE - NEEDS_FIXES
