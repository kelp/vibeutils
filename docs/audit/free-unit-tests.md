# Unit Test Audit: free

**Date:** 2026-03-28
**File:** `src/free.zig`
**Result:** NEEDS_FIXES

## Test Counts

- Total tests: 34
- Pass: 34 (all pass at time of audit)
- Parse-only stubs: 0
- Cannot-fail tests: 0 (pure logic or mock I/O, all correctly
  structured)

## Test Inventory

### Pure arithmetic / pure-logic tests (no I/O, no OS calls)

| Test | Verdict |
|------|---------|
| `scaleValue bytes` | OK — asserts exact values |
| `scaleValue kibi` | OK |
| `scaleValue mebi` | OK |
| `scaleValue gibi` | OK |
| `scaleValue si mode` | OK |
| `formatHumanReadable small values` | OK |
| `formatHumanReadable kibi` | OK |
| `formatHumanReadable mebi` | OK |
| `formatHumanReadable gibi` | OK |
| `formatHumanReadable si mode` | OK |
| `formatHumanReadable si mebi` | OK |
| `resolveUnit defaults to kibi` | OK |
| `resolveUnit bytes flag` | OK |
| `resolveUnit human flag` | OK |
| `resolveUnit gibi flag` | OK |
| `resolveUnit mebi flag` | OK |
| `resolveUnit human takes priority` | OK |
| `parseMemInfoLine valid` | OK |
| `parseMemInfoLine no match` | OK |
| `parseMemInfoLine empty value` | OK |

### printReport tests (mock MemInfo, mock writer)

| Test | Verdict |
|------|---------|
| `printReport with mock data` | WEAK — checks only that "total", "Mem:", "Swap:" appear; does not assert column count, whitespace alignment, or numeric values |
| `printReport with total line` | WEAK — checks only that "Total:" appears |
| `printReport wide mode` | WEAK — checks only that "buffers" and "cache" appear in output |
| `printReport human readable` | WEAK — checks only that "Gi" appears anywhere in output |

### runFree end-to-end tests (hit real OS via `getMemInfo`)

| Test | Verdict |
|------|---------|
| `runFree help flag` | OK — exit 0, "Usage: free" in stdout, empty stderr |
| `runFree version flag` | OK — exit 0, "free" and `common.name` in stdout |
| `runFree unknown flag returns misuse` | OK — exit 2, "free:" prefix in stderr |
| `runFree extra arguments returns misuse` | OK — exit 2, "extra operand" in stderr |
| `runFree default output` | OK — exit 0, non-empty, "Mem:" and "Swap:" present |
| `runFree bytes flag` | WEAK — exit 0 and non-empty output only; no unit verification |
| `runFree mebi flag` | WEAK — exit 0 and non-empty output only |
| `runFree gibi flag` | WEAK — exit 0 and non-empty output only |
| `runFree human flag` | WEAK — exit 0 and non-empty output only; unit suffix not checked |
| `runFree total flag` | OK — checks "Total:" present |
| `runFree wide flag` | OK — checks "buffers" and "cache" present |
| `runFree short version flag` | WEAK — only checks "free" substring; any output containing that word would pass |
| `getMemInfo returns valid data` | WEAK — skips silently on error (`catch return`); only checks total > 0 and used <= total |

---

## Issues

### [IMPORTANT] Unit flag tests verify only exit 0, not output content
Location: `src/free.zig:776-818`
Problem: `runFree bytes flag`, `runFree mebi flag`, `runFree gibi flag`,
and `runFree human flag` each check only that the exit code is 0 and the
output is non-empty. A regression that silently used the wrong unit would
pass all four tests. The bytes test should verify values are large (e.g.
> 1,000,000 for total), the mebi/gibi tests should verify values are
smaller than the kibi default, and the human test should verify a unit
suffix is present.
Fix: After capturing output, parse a value from the Mem: row and assert
it is within an expected range for the given unit, or at minimum verify
the human test contains a suffix like "Ki", "Mi", or "Gi".

### [IMPORTANT] `printReport` mock tests check presence only, not values
Location: `src/free.zig:607-697`
Problem: All four `printReport` tests use `MemInfo` with known exact
values (e.g. total = 16 GiB) but then only check that certain label
strings appear. They never assert numeric correctness. A bug in
`scaleValue` wiring inside `printReport` (e.g. displaying raw bytes
instead of kibibytes) would not be caught.
Fix: For at least the default kibi test, assert that the total column
shows the expected value (16 * 1024 * 1024 = 16777216 kibibytes in this
case).

### [IMPORTANT] `resolveUnit` priority ordering is only partially tested
Location: `src/free.zig:599-605`
Problem: Only one priority-conflict test exists (`human` over `bytes` +
`mebi`). The full priority chain is `human > gibi > mebi > bytes >
kibi`, but no test covers `gibi` beating `mebi` or `bytes`, or `mebi`
beating `bytes`.
Fix: Add tests for `gibi` + `mebi`, `gibi` + `bytes`, and `mebi` +
`bytes` combinations to pin the full priority order.

### [IMPORTANT] `getMemInfo` test skips silently on error
Location: `src/free.zig:869-875`
Problem: `catch return` means that on a platform where `getMemInfo`
fails, the test passes vacuously. This is a cannot-fail pattern: if
`getMemInfo` returns an error, the test reports success.
Fix: Change `catch return` to `catch |err| return err` so a failure
surfaces as a test failure. If the intent is to skip on unsupported
platforms, use a conditional on `builtin.os.tag` to skip explicitly,
not silently.

### [SUGGESTION] `-s` / `-c` continuous-mode behavior has zero coverage
Location: `src/free.zig` (no test)
Problem: The continuous polling path (`interval > 0`) is entirely
untested. The interaction between `-c` without `-s` (treated as single
display), the iteration counter, and the blank-line separator between
iterations are all dark.
Fix: Add unit tests for `runFree` with `["-s", "1", "-c", "2"]`
using a mock writer to verify the blank-line separator and that output
is produced exactly twice. This does not require sleeping — test the
logic, not wall-clock timing.

### [SUGGESTION] `--si` flag has no behavioral test
Location: `src/free.zig` (no test)
Problem: `--si` switches divisors from 1024 to 1000. `scaleValue si
mode` tests the math, but no `runFree` or `printReport` test exercises
`--si` end-to-end.
Fix: Add a `runFree si flag` test that checks output values differ from
the default kibi output.

### [SUGGESTION] Wide mode buffers column is hardcoded to 0 on macOS
Location: `src/free.zig:314`
Problem: In `printMemRow`, when `wide == true`, the buffers column is
always printed as 0 on macOS because there is no clean split of
`buff_cache`. This is a known limitation, but there is no test or
comment asserting that wide mode shows 0 in the buffers column on macOS
(versus a meaningful value on Linux).
Fix: Document the limitation with a comment in `printMemRow` and add a
test for `printReport` in wide mode that explicitly asserts the buffers
column is 0 when `buff_cache` is provided but no explicit buffers
split exists.

## Summary

34 tests pass. No parse-only stubs. The pure-logic layer (`scaleValue`,
`resolveUnit`, `parseMemInfoLine`) is well covered. The behavioral
layer has gaps: unit-flag tests verify only exit codes, `printReport`
tests check labels but not numeric correctness, and the continuous-mode
path is untested. The `getMemInfo` test silently passes on error (a
cannot-fail pattern). `--si` and `-s`/`-c` have no end-to-end coverage.
