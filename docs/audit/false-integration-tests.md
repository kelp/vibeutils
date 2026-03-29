# false — Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/false_test.sh`
**Tests:** 8 (all pass)
**Assessment:** APPROVED

## Test Inventory

| # | Test Name | Type | Verdict |
|---|-----------|------|---------|
| 1 | `false binary` | binary exists | OK |
| 2 | `false exit code` (via `test_basic_flags`) | behavioral | OK |
| 3 | `false exits with code 1` | behavioral | OK |
| 4 | `false no stdout output` | behavioral | OK |
| 5 | `false no stderr output` | behavioral | OK |
| 6 | `false ignores --some-flag` | behavioral | OK |
| 7 | `false ignores positional args` | behavioral | OK |
| 8 | `false ignores mixed args` | behavioral | OK |

## GNU Reference (primary)

GNU `false` behavior:
- Always exits 1.
- Produces no output.
- Ignores all arguments including `--help` and `--version`.
- POSIX specifies ignoring all arguments; GNU follows this.

## Findings

**No critical or important issues found.**

All three testable properties of `false` — exit code 1, no stdout,
no stderr — are directly covered. Argument-ignoring is tested across
three representative shapes. `test_basic_flags` contains special
handling for `false` that correctly verifies exit code 1 without
testing `--help`/`--version` (which `false` must ignore per POSIX).

The `|| true` guards on the output-capture lines (lines 33 and 43)
are correct: without them the non-zero exit from `false` would cause
the subshell assignment to propagate a non-zero status and abort the
test under `set -e`.

### [SUGGESTION] No test for large argument count
Same observation as `true`: not a behavioral risk given the
implementation discards all args.

### [SUGGESTION] stderr capture idiom is slightly non-portable
Location: `false_test.sh:43`
Same observation as `true_test.sh`: `"$binary" 2>&1 >/dev/null`
is correct but non-obvious.

## Summary

8/8 pass. For a trivially simple utility the integration suite is
thorough. No gaps relative to GNU behavior.

**Assessment: APPROVED**
