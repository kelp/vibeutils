# true — Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/true_test.sh`
**Tests:** 8 (all pass)
**Assessment:** APPROVED

## Test Inventory

| # | Test Name | Type | Verdict |
|---|-----------|------|---------|
| 1 | `true binary` | binary exists | OK |
| 2 | `true exit code` (via `test_basic_flags`) | behavioral | OK |
| 3 | `true exits with code 0` | behavioral | OK |
| 4 | `true no stdout output` | behavioral | OK |
| 5 | `true no stderr output` | behavioral | OK |
| 6 | `true ignores --some-flag` | behavioral | OK |
| 7 | `true ignores positional args` | behavioral | OK |
| 8 | `true ignores mixed args` | behavioral | OK |

## GNU Reference (primary)

GNU `true` behavior:
- Always exits 0.
- Produces no output.
- Ignores all arguments including `--help` and `--version`.
- POSIX specifies ignoring all arguments; GNU follows this.

## Findings

**No critical or important issues found.**

All three testable properties of `true` — exit code, no stdout, no
stderr — are directly covered. Argument-ignoring is tested across
three representative argument shapes. `test_basic_flags` contains
special handling for `true` that correctly verifies exit code 0
without testing `--help`/`--version` output (which `true` must
ignore per POSIX).

### [SUGGESTION] No test for large argument count
GNU `true` ignores hundreds of arguments without error. Not a
behavioral risk since the implementation discards all args, but the
test only verifies up to 7 args in a single call.

### [SUGGESTION] stderr capture idiom is slightly non-portable
Location: `true_test.sh:43`
Problem: `stderr_output=$("$binary" 2>&1 >/dev/null)` redirects
stderr to stdout before redirecting stdout to /dev/null, so
`stderr_output` captures stderr only. This idiom is correct but
non-obvious and would fail on `sh` without `$()` support. Not a
risk on bash 4+.

## Summary

8/8 pass. For a trivially simple utility the integration suite is
thorough. No gaps relative to GNU behavior.

**Assessment: APPROVED**
