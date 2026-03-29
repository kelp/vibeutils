---
utility: seq
audit_type: unit-tests
date: 2026-03-28
test_count: 26
status: NEEDS_FIXES
---

# seq Unit Test Audit

**Date:** 2026-03-28
**Test count:** 26 unit tests
**Run status:** Unable to run in isolation (requires build system);
counts based on source analysis of `src/seq.zig`

---

## Summary

The seq unit tests are behaviorally solid — no parse-only stubs.
Every test calls `runSeq()` and asserts actual output. Coverage of
the core sequence-generation paths is good. Gaps exist around
`-f` format strings (only `%f` covered), the `-w` sign-carrying
edge case, and GNU-compat behaviors like `inf`/`nan` inputs and
scientific notation (`%e`/`%g`).

---

## Test Inventory

| Test | Behavioral? | Notes |
|------|-------------|-------|
| seq basic: seq 5 | Yes | Checks stdout content |
| seq basic: seq 3 5 | Yes | FIRST LAST form |
| seq basic: seq 1 2 10 | Yes | FIRST INCR LAST form |
| seq countdown: seq 5 -1 1 | Yes | Negative increment |
| seq separator: seq -s ', ' 3 | Yes | -s flag behavior |
| seq equal width: seq -w 1 10 | Yes | -w flag behavior |
| seq empty output when direction wrong | Yes | Empty output verified |
| seq single number | Yes | Edge: LAST==1 |
| seq float: seq 0.5 0.5 2.0 | Yes | Decimal output format |
| seq error: no args | Yes | Exit code + stderr |
| seq error: too many args | Yes | Exit code + stderr |
| seq error: invalid number | Yes | Exit code + stderr |
| seq error: zero increment | Yes | Exit code + stderr |
| seq negative numbers | Yes | `-- -3 -1` form |
| seq negative to positive | Yes | Cross-zero range |
| seq equal width with negative | Yes | Checks prefix and suffix |
| seq format %f | Yes | -f %f produces 6 decimals |
| seq help | Yes | Checks "Usage: seq" in output |
| seq version | Yes | Checks "seq" and name in output |
| seq large step | Yes | Step skips numbers |
| seq decimal precision preserved | Yes | 1dp inputs kept 1dp |
| seq separator with equal width | Yes | -w -s combined |
| isInteger | Yes (unit fn) | Pure function test |
| decimalPlaces | Yes (unit fn) | Pure function test |
| formatInteger | Yes (unit fn) | Pure function test |
| formatDecimal | Yes (unit fn) | Pure function test |

**0 parse-only stubs.** All 22 runSeq-level tests assert stdout
and/or exit code content.

---

## Issues Found

### [IMPORTANT] -f format: only %f tested; %e and %g have zero
coverage
Location: `src/seq.zig` — `formatScientific`, `formatGeneral`
Problem: GNU seq supports `seq -f "%e" 3` (scientific) and
`seq -f "%g" 3` (general). The code paths for `%e`/`%g` in
`formatWithSpec` are never exercised by tests. A regression there
would be silent.
Fix: Add tests:
```zig
// seq -f "%e" 3 should produce scientific notation
// seq -f "%g" 3 should produce trimmed decimal
```

### [IMPORTANT] -f format: width/precision modifiers not tested
Location: `src/seq.zig:181` — `formatWithSpec`
Problem: `seq -f "%5.2f" 3` (explicit precision via format) is
a common GNU use case. The parser skips width/precision digits but
only calls `formatDecimal(buf, value, 6)` for `%f` regardless of
the parsed precision. No test catches the ignored precision.
Fix: Add test for `seq -f "%.2f" 3` and verify `1.00\n2.00\n3.00`.

### [IMPORTANT] -w with negative FIRST: sign character not counted
in pad width
Location: `src/seq.zig:464-478` — `printNumber`
Problem: The padding logic checks if `formatted[0] == '-'` and
emits a separate `-` plus zeros. The test `seq equal width with
negative` uses `1 100` (no negatives). A sequence like `-2 1`
with `-w` has no test. GNU pads to the width of the widest
absolute representation; the sign handling may over-pad or
under-pad.
Fix: Add test:
```zig
// seq -w -- -2 2: should produce "-2 -1 00 01 02" or
// "-2 -1  0  1  2" (verify against GNU)
```

### [IMPORTANT] inf / nan inputs not tested
Location: `src/seq.zig:351` — float parsing
Problem: `seq inf` and `seq nan` are valid GNU inputs (`inf`
produces an infinite loop on GNU; should error). Zig's
`parseFloat` accepts `inf` and `nan`. No test verifies the
behavior of these edge-case inputs.
Fix: Add error test for `inf` and `nan` inputs.

### [IMPORTANT] -s with empty-string separator not tested
Location: `src/seq.zig:397` — separator logic
Problem: `seq -s '' 3` (empty separator) should produce
`123`. No test covers this. The code uses `orelse "\n"` so an
explicit empty string separator is a distinct case.
Fix: Add test for `-s ""`.

### [SUGGESTION] version test is a weak substring check
Location: `src/seq.zig:776-777`
Problem: The version test checks only that stdout contains "seq"
and `common.name`. A misformatted version line would still pass.
Fix: Check for the full pattern like `seq (vibeutils)`.

### [SUGGESTION] formatWithSpec ignores prefix/suffix text in
format string
Location: `src/seq.zig:181`
Problem: GNU seq allows `seq -f "value: %g\n" 3`. The prefix
"value: " would be silently lost by the current implementation.
No test covers this, so the silent incorrect behavior goes
undetected.
Fix: Add test for format string with surrounding literal text.

---

## Coverage Assessment

| Area | Coverage |
|------|----------|
| Basic forms (1, 2, 3 arg) | Good |
| -s separator | Good |
| -w equal width (positive) | Good |
| -w equal width (negative values) | Missing |
| -f %f | Minimal (only basic) |
| -f %e / %g | None |
| -f with precision modifiers | None |
| Error paths (no args, too many, invalid, zero incr) | Good |
| Float sequences | Good |
| Countdown sequences | Good |
| inf/nan inputs | None |
| Empty separator | None |
| Help / version | Weak substring only |

---

## Overall Assessment: NEEDS_FIXES

0 critical, 5 important, 2 suggestion.
No parse-only stubs. Core paths well covered. Fix the `-f`
format gaps and edge cases before declaring this suite complete.
