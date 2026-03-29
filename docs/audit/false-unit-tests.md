# false — Unit Test Audit

**Date:** 2026-03-28
**File:** `src/false.zig`
**Tests:** 2 (all pass)
**Assessment:** APPROVED

## Test Inventory

| # | Test Name | Type | Verdict |
|---|-----------|------|---------|
| 1 | `false always returns 1 and ignores all arguments` | behavioral | OK |
| 2 | `false produces no output` | behavioral | OK |

## Parse-Only Tests

None. Both tests call `runFalse` and assert on observable behavior
(return value 1 and empty output). There is no parsed struct to
inspect.

## Findings

**No critical or important issues found.**

The utility is trivially simple: `runFalse` ignores all arguments
and returns `ExitCode.general_error` (1). Both behavioral properties
(exit 1, no output) are tested. The `test_cases` slice in test 1
covers no arguments, `--help`, `--version`, positionals, short
flags, and mixed args.

### [SUGGESTION] Exit code value is `general_error`, not a dedicated constant
Location: `src/false.zig:18`
Problem: The implementation returns `@intFromEnum(common.ExitCode
.general_error)`. If `general_error` is ever changed to a value
other than 1, `false` would silently break. A dedicated
`ExitCode.failure` constant with value 1 would be more expressive,
but this is a project-wide naming decision.
Fix: No action required unless `ExitCode.general_error` changes.

### [SUGGESTION] No stdin hang risk
`false` does not read stdin. No filter-utility concern.

### [SUGGESTION] main() not covered by unit tests
Location: `src/false.zig:22-24`
Problem: `main()` calls `std.process.exit(1)` directly and bypasses
`runFalse`. It cannot be unit-tested and is trivially correct, but
it means `main()` is outside test coverage. This is acceptable for
a one-line function.

## Summary

2/2 tests pass. No parse-only stubs. For a utility this simple the
test suite is complete.

**Assessment: APPROVED**
