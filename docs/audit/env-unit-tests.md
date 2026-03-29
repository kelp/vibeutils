# Unit Test Audit: env

**Date**: 2026-03-28
**Source**: src/env.zig
**Tests run**: 56 total; all 56 pass

## Executive Summary

NEEDS_FIXES

The env unit tests are better structured than most utilities
in this codebase. Eighteen tests go through `runEnv` or a
real output function and check content, giving genuine
behavioral coverage for the core paths. However, 30 of 56
tests are `parseArgs`-only stubs that validate struct fields
without running the program. Three specific behavioral gaps
are notable: `-u` has no `runEnv` test that verifies the
variable is absent from output; the lone-dash (`-`) alias
for `-i` is both unimplemented and untested; and the `-C`
success path is never exercised. The `buildEnvMap` unset
ordering test is logically unsound and cannot catch real
ordering bugs.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| parseArgs: no arguments | No — parse-only | STUB |
| parseArgs: -i flag | No — parse-only | STUB |
| parseArgs: --ignore-environment flag | No — parse-only | STUB |
| parseArgs: -0 flag | No — parse-only | STUB |
| parseArgs: -z flag | No — parse-only | STUB |
| parseArgs: --null flag | No — parse-only | STUB |
| parseArgs: -u flag | No — parse-only | STUB |
| parseArgs: --unset=NAME | No — parse-only | STUB |
| parseArgs: --unset NAME | No — parse-only | STUB |
| parseArgs: -C flag | No — parse-only | STUB |
| parseArgs: --chdir=DIR | No — parse-only | STUB |
| parseArgs: --chdir DIR | No — parse-only | STUB |
| parseArgs: NAME=VALUE assignment | No — parse-only | STUB |
| parseArgs: NAME=VALUE with empty value | No — parse-only | STUB |
| parseArgs: command after assignment | No — parse-only | STUB |
| parseArgs: -- separates options from command | No — parse-only | STUB |
| parseArgs: combined short flags | No — parse-only | STUB |
| parseArgs: unknown flag | Yes — error path | PASS |
| parseArgs: missing value for -u | Yes — error path | PASS |
| parseArgs: missing value for -C | Yes — error path | PASS |
| parseArgs: missing value for --unset | Yes — error path | PASS |
| parseArgs: missing value for --chdir | Yes — error path | PASS |
| parseArgs: help flag | No — parse-only | STUB |
| parseArgs: version flag | No — parse-only | STUB |
| parseArgs: -h short help | No — parse-only | STUB |
| parseArgs: -V short version | No — parse-only | STUB |
| parseArgs: multiple unsets | No — parse-only | STUB |
| parseArgs: multiple assignments | No — parse-only | STUB |
| parseArgs: -uNAME inline value | No — parse-only | STUB |
| parseArgs: -C/tmp inline value | No — parse-only | STUB |
| parseArgs: -P flag | No — parse-only | STUB |
| parseArgs: -P inline value | No — parse-only | STUB |
| parseArgs: -P missing value | Yes — error path | PASS |
| parseArgs: -S flag | No — parse-only | STUB |
| parseArgs: --split-string=VALUE | No — parse-only | STUB |
| parseArgs: --split-string VALUE | No — parse-only | STUB |
| parseArgs: -S missing value | Yes — error path | PASS |
| parseArgs: -v flag | No — parse-only | STUB |
| buildEnvMap: ignore environment | Yes | PASS |
| buildEnvMap: ignore environment with assignments | Yes | PASS |
| buildEnvMap: unset before assign | Weak — logically unsound | SEE NOTE |
| printEnvironment: basic output | Yes | PASS |
| printEnvironment: null delimiter | Yes | PASS |
| printEnvironment: empty environment | Yes | PASS |
| runEnv: help flag | Yes | PASS |
| runEnv: version flag | Yes | PASS |
| runEnv: print environment with -i and assignment | Yes | PASS |
| runEnv: empty environment with -i | Yes | PASS |
| runEnv: -i with multiple assignments | Yes | PASS |
| runEnv: null delimiter output | Yes | PASS |
| runEnv: unknown flag | Yes | PASS |
| runEnv: invalid chdir | Yes | PASS |
| runEnv: -P sets alternate PATH in environment | Yes | PASS |
| runEnv: -S prints stub warning | Yes (stub confirmation) | PASS |
| runEnv: -v verbose with -i | Yes | PASS |
| runEnv: -v verbose with -u | Weak — checks message, not unset | SEE NOTE |

---

## Parse-Only Tests (CRITICAL)

### Option parsing stubs

```
[CRITICAL] Parse-only stubs: 25 parseArgs tests check struct fields
Location: src/env.zig:445-860
Problem: 25 tests call parseArgs() and assert that a field in
  EnvOptions is set (e.g., options.ignore_environment == true,
  options.chdir == "/tmp"). None call runEnv() and verify the flag
  changes program output or behavior. A bug where the parsed field
  is correctly set but then ignored in runEnv() would pass all 25
  tests.
  The error-path tests (missing value, unknown flag) are genuine
  behavioral tests and are correctly counted as PASS above.
Fix: The critical gaps are the MUST and SHOULD flags with no
  runEnv behavioral counterpart. See Missing Coverage section.
  The parse-layer tests may be kept as regression guards for
  the argument parser, but each MUST/SHOULD flag needs at least
  one runEnv test that verifies observable output or behavior.
```

---

## Logically Unsound Tests (IMPORTANT)

```
[IMPORTANT] buildEnvMap: unset before assign cannot catch ordering bugs
Location: src/env.zig:667-683
Problem: The test is titled "unset before assign" and comments say
  "Unset happens first (on empty env), then assignment sets it."
  The test starts with ignore_environment=true (empty env), then
  unsets "X" (which is already absent) and assigns "X"="new".
  The unset is a no-op here, so the test only verifies that an
  assignment into an empty map works. It does NOT verify that
  -u removes a pre-existing variable from the inherited env.
  A bug where unsets were applied AFTER assignments (or not at all)
  would pass this test.
Fix: Rebuild the test with ignore_environment=false (so the env
  map starts with at least one real variable) or manually put a
  variable into the map before the unset step:
    var env_map = process.EnvMap.init(allocator);
    try env_map.put("X", "old");
    // Then apply unset — verify "X" is gone.
  Alternatively, write a runEnv-level test:
    runEnv(alloc, &.{"-i", "X=set", "-u", "X"}, stdout, stderr)
  and assert "X=" does not appear in stdout.
```

---

## Missing Coverage

| Flag | Tier | Has Behavioral Test? | Notes |
|------|------|---------------------|-------|
| -i   | MUST | Yes | runEnv tests cover -i + assignment |
| -u   | MUST | No  | runEnv test checks verbose message only; actual removal from output unchecked |
| -0   | SHOULD | Yes | runEnv: null delimiter output is solid |
| -C   | SHOULD | Partial | Error path tested; success path not tested |
| -P   | SHOULD | Yes | runEnv: -P sets alternate PATH in environment |
| -S   | SHOULD | No  | Stub; test confirms warning, not splitting |
| -v   | SHOULD | Yes | Verbose message tested via runEnv |
| lone - | MUST | No  | Both unimplemented and untested; see F04 below |

### -u behavioral gap

```
[IMPORTANT] -u: variable removal not verified in output
Location: src/env.zig:900-908
Problem: "env runEnv: -v verbose with -u" is the only runEnv
  test that exercises -u. It checks that stderr contains
  "unsetenv NONEXISTENT_VAR_TEST" — the verbose log line.
  It does not assert that the variable is absent from stdout.
  A bug where env_map.remove() was accidentally deleted or
  skipped would still produce the verbose line (written before
  the map operation at line 131-133) and pass this test.
Fix: Add a runEnv test:
  1. Pass -i to start with empty env.
  2. Set a known variable: X=original.
  3. Then unset it: -u X.
  4. Assert stdout does not contain "X=".
  Or use the process environment with a known variable.
```

### -C success path gap

```
[IMPORTANT] -C: working directory change not verified
Location: src/env.zig:805-813
Problem: Only the error path (chdir to nonexistent directory)
  is tested. The success path — where chdir succeeds and the
  command runs in the new directory — has no test. A regression
  where chdir() was called but the error result was silently
  swallowed would not be caught.
Fix: Add a runEnv test that chdirs to /tmp (which exists),
  passes no command, and verifies exit code 0. For stronger
  coverage, run `pwd` as the command and assert the output
  contains /tmp (or the realpath of /tmp).
```

### Lone dash (-) unimplemented and untested

```
[CRITICAL] Lone dash (-) is documented but not implemented
Location: src/env.zig (no test exists; implementation missing)
Problem: The help text at line 411 states "A mere - implies -i."
  This is POSIX behavior (also documented in env-macos.txt).
  However, parseArgs() does not handle a bare "-" argument. The
  relevant path at line 196 checks
  `!std.mem.startsWith(u8, arg, "-")` — a lone "-" starts with
  "-" and is not "--", so it falls into the short-flag parsing
  block. The short-flag loop immediately hits `else =>
  return error.UnknownFlag` because the character after "-" is
  end-of-string.
  This means `env - FOO=bar` returns exit code 2 (misuse) instead
  of treating "-" as equivalent to "-i".
Fix (implementation): In parseArgs(), before the short-flag
  block, add:
    if (std.mem.eql(u8, arg, "-")) {
        options.ignore_environment = true;
        continue;
    }
Fix (test): Add a runEnv test:
    runEnv(alloc, &.{ "-", "X=1" }, stdout, stderr)
  Assert exit code 0 and stdout == "X=1\n". Also add a
  parseArgs test asserting that options.ignore_environment is
  true when args = &.{"-"}.
```

---

## Findings

| ID  | Severity  | Description |
|-----|-----------|-------------|
| F01 | CRITICAL  | Lone dash (-) is documented in help, implied by POSIX, but unimplemented and untested |
| F02 | CRITICAL  | 25 parseArgs stubs check struct fields; none verify observable behavior |
| F03 | IMPORTANT | buildEnvMap unset-ordering test cannot catch actual ordering bugs |
| F04 | IMPORTANT | -u has no runEnv test that verifies variable removal from output |
| F05 | IMPORTANT | -C success path has no test (only error path covered) |

---

## Summary

**Parse-only stubs**: 25 of 56 tests (F02)
**CRITICAL issues**: 2 (F01, F02)
**IMPORTANT issues**: 3 (F03, F04, F05)
**All tests pass**: yes

**Fix Order:**
1. [CRITICAL] Implement and test lone-dash (-) as alias for -i
   — src/env.zig (no current test or implementation)
2. [CRITICAL] Add runEnv behavioral counterparts for -u, -C
   success path, and -S (when implemented) — src/env.zig
3. [IMPORTANT] Rewrite buildEnvMap unset-before-assign test
   to start with a pre-existing variable so the unset is not
   a no-op — src/env.zig:667-683
4. [IMPORTANT] Add runEnv test asserting -u removes variable
   from printed output — src/env.zig (no current test)
5. [IMPORTANT] Add runEnv test for -C success path
   — src/env.zig (no current test)

REVIEW COMPLETE - NEEDS_FIXES
