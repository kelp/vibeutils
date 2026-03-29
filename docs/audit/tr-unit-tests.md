# tr Unit Test Audit

**Date:** 2026-03-28
**File:** `src/tr.zig`
**Tests:** 30 total — all pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test Name | Type | Verdict |
|---|-----------|------|---------|
| 1 | tr --help shows help message | Behavioral | OK |
| 2 | tr --version shows version information | Behavioral | OK |
| 3 | tr with no arguments returns misuse | Behavioral | OK |
| 4 | tr translate missing SET2 returns misuse | Behavioral | OK |
| 5 | tr -u flag is accepted and ignored | Behavioral | OK |
| 6 | tr unknown flag returns misuse | Behavioral | OK |
| 7 | tr parseSet literal characters | Unit (parser) | OK |
| 8 | tr parseSet range | Unit (parser) | OK |
| 9 | tr parseSet digit range | Unit (parser) | OK |
| 10 | tr parseSet escape sequences | Unit (parser) | OK |
| 11 | tr parseSet octal escape | Unit (parser) | OK |
| 12 | tr parseSet character class upper | Unit (parser) | OK |
| 13 | tr parseSet character class lower | Unit (parser) | OK |
| 14 | tr parseSet character class digit | Unit (parser) | OK |
| 15 | tr parseSet equivalence class | Unit (parser) | OK |
| 16 | tr parseSet repetition | Unit (parser) | OK — but note below |
| 17 | tr parseSet mixed | Unit (parser) | OK |
| 18 | tr parseSet invalid range returns error | Unit (parser) | OK |
| 19 | tr buildTranslationTable basic | Unit (internal) | OK |
| 20 | tr buildTranslationTable set2 shorter extends last char | Unit (internal) | OK |
| 21 | tr complementSet | Unit (internal) | OK |
| 22 | tr buildSetMembership | Unit (internal) | OK |
| 23 | tr translate with mock input | Behavioral | OK |
| 24 | tr delete with mock input | Behavioral | OK |
| 25 | tr squeeze with mock input | Behavioral | OK |
| 26 | tr translate and squeeze with mock input | Behavioral | OK |
| 27 | tr delete and squeeze with mock input | Behavioral | OK |
| 28 | tr complement delete with mock input | Behavioral | OK |
| 29 | tr case conversion upper to lower | Behavioral | OK |
| 30 | tr empty input produces empty output | Behavioral | OK |

**Parse-only stubs:** 0. All tests with mock file input call
`runTrWithInput` and verify output bytes. Parser unit tests test
`parseSet` directly, which is correct.

---

## Stdin Hang Risk Assessment

**SAFE.** The filter architecture is correctly split:

- `runTr` (public) reads `std.fs.File.stdin()` at line 441, but
  only after all argument validation has passed.
- Tests 1–4 and 6 call `runTr` with args that trigger early
  returns (help, version, missing-operand, unknown-flag) before
  stdin is ever opened. No hang risk.
- Tests 5 and 23–30 call the internal `runTrWithInput` with a
  `tmpDir`-backed file, completely bypassing stdin. Correct
  pattern.

---

## Flag Coverage

| Flag | MUST/SHOULD | Has Behavioral Test |
|------|-------------|---------------------|
| -c   | MUST | Yes — test 28 |
| -C   | MUST | No |
| -d   | MUST | Yes — test 24 |
| -s   | MUST | Yes — tests 25, 26 |
| -t   | SHOULD | No |
| -u   | SHOULD | Yes (parse + ignored) — test 5 |

---

## Issues

### [CRITICAL] `[c*]` fill-to-SET1-length is silently unimplemented

**Location:** `src/tr.zig:290-292` (parseRepeat), `src/tr.zig:483-486`
(runTrWithInput)

**Problem:** When `[c*]` appears in SET2, `parseRepeat` returns
`count = 0` as a sentinel (line 292). The loop at line 93
executes `for (0..0)` — zero iterations — so the character is
never appended to the parsed set. The comment at line 483 says
"we re-expand set2 if needed" but the code that follows does
nothing. `[c*]` in SET2 produces an empty set, silently
discarding the fill request.

GNU tr uses `[c*]` specifically to pad SET2 to match SET1's
length (e.g., `tr '[:upper:]' '[x*]'` replaces all uppercase
with `x`). This is a documented and commonly used feature.

**Fix:** After parsing set2 (line 481), check whether any
`count == 0` sentinel survived into the result (or track it
separately during parsing) and then expand the character to fill
`set1.len - set2_without_fill.len` copies.

---

### [CRITICAL] -C (complement-C) has no behavioral test

**Location:** `src/tr.zig:19-42` (TrArgs), tests section

**Problem:** `-C` is a distinct flag from `-c` and is MUST-tier.
`TrArgs.complement_c` is parsed separately and `isComplement()`
ORs both fields (line 39-41). Test 28 exercises `-c` (via
`TrArgs.complement = true`) but no test sets
`TrArgs.complement_c = true` or passes `-C` through `runTr`.
If `complement_c` were accidentally dropped from `isComplement`,
all tests would still pass.

**Fix:** Add a test using `TrArgs{ .complement_c = true, ... }`
with `runTrWithInput`, verifying the same behavioral outcome as
the existing complement test.

---

### [IMPORTANT] -t (truncate-set1) has no behavioral test

**Location:** `src/tr.zig:489-492`, tests section

**Problem:** `-t` is a SHOULD-tier GNU extension. The
implementation truncates set1 to set2's length before
translation. No unit test exercises this flag. The integration
test in `tr_test.sh` line 102 does cover it, but a unit-level
regression would be silent.

**Fix:** Add a `runTrWithInput` test with
`TrArgs{ .truncate_set1 = true, .positionals = &.{ "abc", "xy" } }`
and input `"abcabc"`, expecting `"xycxyc"` (c passes through
unmapped because set1 is truncated to `"ab"`).

---

### [IMPORTANT] No test for `[c*n]` with octal count

**Location:** `src/tr.zig:293-299` (parseRepeat octal branch)

**Problem:** Test 16 covers `[x*3]` (decimal count). The octal
branch (count string starting with `'0'`) is exercised by no
test. An off-by-one in the octal parsing would go undetected.

**Fix:** Add a `parseSet` unit test for `"[x*03]"` (octal 3 =
decimal 3) and `"[x*010]"` (octal 10 = decimal 8), asserting
the correct expansion lengths.

---

### [IMPORTANT] No test for invalid SET1 or SET2 passed to
`runTrWithInput`

**Location:** `src/tr.zig:455-458`, `src/tr.zig:477-480`

**Problem:** The error paths for `parseSet` failure on SET1 and
SET2 inside `runTrWithInput` (lines 455-458 and 477-480) emit
an error message and return `misuse`. No unit test exercises
these paths.

**Fix:** Add unit tests passing `TrArgs` with positionals
containing invalid set strings (e.g., `"z-a"` which returns
`error.InvalidRange`) and verifying exit code 2 with an error
message on stderr.

---

### [SUGGESTION] No test for character classes beyond upper/lower/digit

**Location:** `src/tr.zig:190-251` (expandClass), tests section

**Problem:** Tests 12–14 cover `upper`, `lower`, and `digit`.
The `expandClass` function also implements `xdigit`, `alpha`,
`alnum`, `space`, `blank`, `cntrl`, `print`, `graph`, and
`punct`. An invalid class name returns `error.InvalidClass`.
None of these are unit-tested.

**Fix:** Add `parseSet` unit tests for at least `[:alpha:]`,
`[:space:]`, and an invalid class name (e.g., `"[:bogus:]"`
expecting `error.InvalidClass`).

---

### [SUGGESTION] No test crossing the 8192-byte buffer boundary

**Location:** `src/tr.zig:521`, `src/tr.zig:582`, etc.

**Problem:** All behavioral tests use short inputs (under 20
bytes). The processing loop reads in 8192-byte chunks. A
translation that spans a chunk boundary (e.g., a squeeze
spanning the last byte of chunk N and the first byte of chunk
N+1) is exercised only by the integration test's "large input"
case, and that test only checks exit code, not output content.

**Fix:** Add a `runTrWithInput` test with input length > 8192
for the squeeze path, verifying that runs crossing the buffer
boundary are correctly collapsed.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 3 |
| SUGGESTION | 2 |

**Overall: NEEDS_FIXES**

The filter architecture is sound — no stdin hang risk. The test
suite has good behavioral coverage for the core modes (-d, -s,
-c, translate, combined). The critical gaps are the silently
broken `[c*]` fill feature and the untested `-C` flag path.

**Fix Order:**
1. [CRITICAL] `[c*]` fill-to-SET1-length produces empty set —
   `src/tr.zig:290-292` and `src/tr.zig:483-486`
2. [CRITICAL] `-C` flag has no behavioral test —
   `src/tr.zig:19-42` (tests section)
3. [IMPORTANT] `-t` flag has no unit test — `src/tr.zig:489-492`
4. [IMPORTANT] Octal `[c*n]` count untested —
   `src/tr.zig:293-299`
5. [IMPORTANT] Invalid SET1/SET2 error paths untested —
   `src/tr.zig:455-458`, `src/tr.zig:477-480`
6. [SUGGESTION] Character classes beyond upper/lower/digit
   untested — `src/tr.zig:190-251`
7. [SUGGESTION] No cross-buffer-boundary squeeze test —
   `src/tr.zig:521` et al.
