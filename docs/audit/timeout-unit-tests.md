# timeout Unit Test Audit

**Date:** 2026-03-28
**File:** `src/timeout.zig`
**Tests:** 30 declared; 29 pass, 1 skipped (preserve-status skipped on Linux CI)
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Notes |
|---|-----------|------|-------|
| 1 | `parseTimeString - basic integer seconds` | behavioral | delegates to common/time.zig |
| 2 | `parseTimeString - decimal seconds` | behavioral | delegates to common/time.zig |
| 3 | `parseTimeString - suffixes` | behavioral | delegates to common/time.zig |
| 4 | `parseTimeString - invalid formats` | behavioral | delegates to common/time.zig |
| 5 | `parseTimeString - negative values` | behavioral | delegates to common/time.zig |
| 6 | `parseSignal - numeric signals` | behavioral | good coverage |
| 7 | `parseSignal - named signals` | behavioral | good coverage |
| 8 | `parseSignal - SIG prefix` | behavioral | good coverage |
| 9 | `parseSignal - case insensitive` | behavioral | good coverage |
| 10 | `parseSignal - invalid signals` | behavioral | good coverage |
| 11 | `asciiEqlIgnoreCase` | behavioral | good |
| 12 | `runTimeout - help option` | behavioral | checks output content |
| 13 | `runTimeout - version option` | behavioral | checks output content |
| 14 | `runTimeout - missing operand` | behavioral | checks exit code + stderr |
| 15 | `runTimeout - missing command` | behavioral | checks exit code + stderr |
| 16 | `runTimeout - invalid duration` | behavioral | checks exit code + stderr |
| 17 | `runTimeout - invalid signal` | behavioral | checks exit code + stderr |
| 18 | `runTimeout - command not found` | behavioral | weak: accepts 0 or 127 |
| 19 | `runTimeout - command completes before timeout` | behavioral | spawns real process |
| 20 | `runTimeout - command fails before timeout` | behavioral | spawns real process |
| 21 | `runTimeout - zero timeout disables timeout` | behavioral | spawns real process |
| 22 | `runTimeout - command times out` | behavioral | 1-second wall time |
| 23 | `runTimeout - preserve-status on timeout` | behavioral | **skipped on Linux CI** |
| 24 | `signal_table - USR1 matches platform signal number` | behavioral | platform-correctness |
| 25 | `signal_table - USR2 matches platform signal number` | behavioral | platform-correctness |
| 26 | `parseSignal - USR1 returns platform-correct value` | behavioral | platform-correctness |
| 27 | `parseSignal - USR2 returns platform-correct value` | behavioral | platform-correctness |
| 28 | `runTimeout - no arguments returns 125` | behavioral | duplicate of test 14 |
| 29 | `runTimeout - unknown flag returns misuse exit code` | behavioral | checks exit 2 |
| 30 | `runTimeout - missing command after duration returns 125` | behavioral | duplicate of test 15 |

---

## Findings

### [CRITICAL] `preserve-status on timeout` is skipped on Linux CI — the exact platform where it matters

**Location:** `src/timeout.zig:570-584`

The test guards itself with:

```zig
if (comptime builtin.os.tag == .linux) {
    if (std.process.getEnvVarOwned(testing.allocator, "CI")) |ci_val| {
        testing.allocator.free(ci_val);
        return error.SkipZigTest;
    } else |_| {}
}
```

The comment says "process group signal delivery is unreliable in the Zig test runner's IPC mode". However, the integration test for `--preserve-status` is **also failing** in the live environment — `timeout --preserve-status 0.5 sleep 60` returns exit 0 instead of 143. This skip masks a real production bug. The unit test is not merely being cautious; it is concealing a broken behavior path that the integration tests confirmed as broken.

**Fix:** Investigate and fix the signal delivery bug for `--preserve-status`. Do not widen the skip; narrow or remove it once the bug is fixed. Write the test to fail when the bug is present.

---

### [CRITICAL] `runTimeout - command not found` accepts exit 0 or 127 — conceals a real failure

**Location:** `src/timeout.zig:538-548`

```zig
try testing.expect(result != 0);
```

The comment acknowledges "on macOS, posix_spawn may succeed and child exits with 1" but the assertion only checks `!= 0`. On a platform where spawn succeeds but the child produces an unexpected code, the test would still pass. GNU requires exit 127 for command not found. The test should check for `result == 127` on Linux and document a known macOS divergence rather than accepting any non-zero value.

**Fix:** Assert `result == 127` on Linux. Add a compile-time branch for macOS if genuinely divergent.

---

### [IMPORTANT] `-k`/`--kill-after` has zero unit test coverage

**Location:** `src/timeout.zig`

The `--kill-after` flag is a major GNU timeout feature. No unit test exercises the `kill_after_nanos` code path (lines 322-346). The integration tests also do not test it. A kill-after loop that exits early, sends SIGKILL to the wrong process group, or uses the wrong exit code would go undetected.

**Fix:** Add a unit test that runs `timeout -k 0.2 0.1 sleep 60` and checks the child is killed and exit code is 137 (128+SIGKILL). Keep duration short to avoid slowing CI.

---

### [IMPORTANT] `-v`/`--verbose` has zero unit test coverage

**Location:** `src/timeout.zig`

The `--verbose` flag writes to stderr when a signal is sent (line 316-317, 340-342). No test checks that the expected diagnostic line appears on stderr when a timeout occurs with `--verbose`. A typo in the format string or a wrong variable reference would go undetected.

**Fix:** Add a unit test with a short timeout and `--verbose` that checks the stderr buffer contains the signal number and command name.

---

### [IMPORTANT] `extractExitCode` and `tryWaitChild`/`waitChild` have zero direct tests

**Location:** `src/timeout.zig:103-139`

These functions decode `waitpid` status words. Bugs in bit-twiddling (wrong mask, wrong shift) directly affect exit code reporting. They are not tested directly; they are only exercised transitively by the slow live-process tests.

**Fix:** Add unit tests for `extractExitCode` with synthetic status values covering WIFEXITED, WIFSIGNALED, and the SIGKILL case.

---

### [IMPORTANT] `--foreground` flag has zero unit test coverage

**Location:** `src/timeout.zig:54,287-289`

The `--foreground` flag skips `setpgid`. No test checks that this flag is parsed and applied. This is a MUST flag in the GNU spec.

**Fix:** Add at least a parse-level test checking the flag is accepted; ideally a behavioral test confirming no process group is created.

---

### [SUGGESTION] Tests 28 and 30 duplicate tests 14 and 15

**Location:** `src/timeout.zig:635-664`

`runTimeout - no arguments returns 125` duplicates `runTimeout - missing operand` and `runTimeout - missing command after duration returns 125` duplicates `runTimeout - missing command`. The later tests add no new coverage. The extra tests slow the suite by 2 additional `runTimeout` calls.

**Fix:** Remove tests 28 and 30 and add a clarifying comment to tests 14/15 about the exit code.

---

## Summary

- **CRITICAL:** 2 (preserve-status skip conceals live bug; command-not-found accepts any non-zero exit)
- **IMPORTANT:** 4 (--kill-after, --verbose, extractExitCode, --foreground uncovered)
- **SUGGESTION:** 1 (duplicate tests 28/30)

**No parse-only tests.** All `runTimeout` tests exercise the full function. The `parseTimeString` tests delegate to the common module (which has its own test suite) rather than testing through `runTimeout`, which is appropriate.

**Overall: NEEDS_FIXES**

Fix order:
1. [CRITICAL] Investigate and fix `--preserve-status` + signal delivery bug masked by Linux CI skip — `src/timeout.zig:570`
2. [CRITICAL] Tighten command-not-found assertion to `== 127` on Linux — `src/timeout.zig:547`
3. [IMPORTANT] Add `--kill-after` behavioral unit test — `src/timeout.zig`
4. [IMPORTANT] Add `--verbose` stderr output unit test — `src/timeout.zig`
5. [IMPORTANT] Add `extractExitCode` direct unit tests with synthetic status words — `src/timeout.zig:103`
6. [IMPORTANT] Add `--foreground` unit test — `src/timeout.zig:54`
7. [SUGGESTION] Remove duplicate tests 28 and 30 — `src/timeout.zig:635,656`
