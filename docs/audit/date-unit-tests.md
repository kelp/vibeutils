# date Unit Test Audit

**Date:** 2026-03-28
**Auditor:** reviewer agent
**Source file:** `src/date.zig`
**Result:** NEEDS_FIXES

---

## Test Run

```
Tests: 55 total — all pass
```

All 55 tests pass. The pass rate is not the issue; coverage
depth and parse-only stubs are.

---

## Test Inventory

### Parse-only tests (verify field assignment, not behavior)

| # | Test name | What it actually checks |
|---|-----------|-------------------------|
| 1 | `date parseArgs -j sets no_set_date` | `parsed.opts.no_set_date == true` |
| 2 | `date parseArgs -f stores input_fmt` | `parsed.opts.input_fmt == "%Y-%m-%d"` |
| 3 | `date parseArgs -z stores output_zone` | `parsed.opts.output_zone == "America/New_York"` |
| 4 | `date parseArgs -n is silently accepted` | `parsed.err == null` |
| 5 | `date parseArgs -v stores v_adjust` | `parsed.opts.v_adjust == "+2H"` |
| 6 | `date parseArgs -v with inline value` | `parsed.opts.v_adjust == "+1d"` |

6 of 55 tests are pure parse-only stubs.

### Tests that accept wrong behavior as correct

| # | Test name | Problem |
|---|-----------|---------|
| 7 | `date -f flag accepts input format` | Passes `-j -f "%Y-%m-%d" -u -d @0 "+%Y"` — never exercises `input_fmt` because `-d @0` overrides. Tests `runDate` exits 0, not that `-f` parses a date string. |
| 8 | `date -z flag accepts output timezone` | Passes `-z UTC -u -d @0 "+%Y"`. `-z` is a no-op stub (`opts.output_zone` is parsed but never applied). Test verifies exit 0, not that the timezone is used. |
| 9 | `date -j flag is accepted (no-op)` | Only verifies `-j` does not break `-d @0` output. Does not verify the flag's purpose (prevent date-setting), which requires a behavioral scenario. |
| 10 | `date -v flag accepts value and prints diagnostic` | Verifies the stub error path (exit 1, stderr message). This locks stub behavior as expected — when `-v` is eventually implemented this test will fail even on correct behavior. |
| 11 | `date -v should exit with non-zero code` | Duplicate of above stub-behavior codification. |
| 12 | `date -v should not produce stdout output` | Duplicate of above stub-behavior codification. |
| 13 | `date -v stderr should contain error message` | Duplicate of above stub-behavior codification. |

Tests 10-13 are four tests for one stub path — they verify
the "not yet implemented" error message rather than actual
`-v` behavior.

### Behavioral tests with correct assertions

The remaining 42 tests do verify real output:

- Default output non-empty and contains "20" (year)
- `+%Y`, `+%Y-%m-%d`, `+%H:%M:%S`, `+%s`, `+%N`, `+%%`,
  `+%n`, `+%t` format specifiers — all using `-u -d @0`
  as deterministic input
- `-u` outputs UTC/GMT `%Z`
- `-R` RFC 5322 full string match
- `-d @0`, `-d @86400` epoch arithmetic
- `--rfc-3339=date/seconds/ns` — output string match
- `--rfc-3339=invalid` — exit code 2
- `-I`, `-Iseconds`, `-Ihours`, `-Iminutes`, `-Ins` — all
  output string matches
- `-d @notanumber` error path
- `-d` / `-r` / `-f` / `-z` / `-v` missing-argument paths
- `-r file` with real file (year digit check)
- `-r nonexistent` error path
- `--help`, `--version`, `-h`, `-V`
- Combined `-uR`, `--date=@0`, `--iso-8601`, `--iso-8601=seconds`
- `-n` no-op behavioral check
- `-d @946684800` known timestamp verification
- `--rfc-3339` space-separated form

---

## Findings

```
[CRITICAL] -z "behavioral" test is a parse-only stub that
  tests a broken no-op implementation
Location: src/date.zig:1176-1187
Problem: The test passes "-z UTC -u -d @0 +%Y" and checks
  only that exit is 0 and output is "1970\n". The -u flag
  does all the work; -z is never applied (confirmed in the
  code audit: opts.output_zone is parsed but runDate never
  reads it). This test provides false confidence that -z
  works. A reader sees a passing -z test and concludes -z
  is functional.
Fix: Either replace with a test that detects the stub
  (e.g., assert -z America/New_York changes %Z output), or
  leave the parse-only parseArgs-style test and remove the
  false behavioral name. The real test should fail today:
    const args = [_][]const u8{ "-d", "@0", "-z", "UTC",
        "+%Z" };
    // should output "UTC\n" or "GMT\n"
    // CURRENTLY outputs local timezone — not UTC
```

```
[CRITICAL] -f "behavioral" test is a parse-only stub for a
  broken implementation
Location: src/date.zig:1152-1163
Problem: The test passes "-j -f %Y-%m-%d -u -d @0 +%Y".
  -d @0 takes over timestamp resolution, so -f is never
  exercised. The test verifies that the presence of -f does
  not crash, not that -f parses a date string. The real -f
  use case (date -j -f "%Y-%m-%d" "2025-01-15" "+%s") is
  completely untested and would exit 2 "extra operand"
  (confirmed in code audit).
Fix: The correct test is:
    // date -j -f "%Y-%m-%d" "2025-01-15" "+%Y"
    // should output "2025\n"
    // CURRENTLY exits 2 with "extra operand"
  Write the failing test first (red-green TDD), then fix
  the implementation.
```

```
[IMPORTANT] -v stub behavior is codified in 4 separate tests
  that will block a correct implementation
Location: src/date.zig:1241-1317
Problem: Four tests (lines 1241, 1281, 1294, 1307) all
  assert the stub behavior: exit 1, empty stdout, stderr
  containing "not yet implemented". When -v is correctly
  implemented, all four tests will fail on valid output.
  The tests are also redundant — all four test the same
  path with overlapping assertions.
Fix: Collapse to one test that documents the stub:
    // TODO: -v not implemented, remove when fixed
    test "date -v unimplemented stub" { ... }
  And add a TODO comment noting these tests need to be
  replaced with behavioral tests for each adjustment unit
  (y, m, w, d, H, M, S).
```

```
[IMPORTANT] -r numeric seconds (MUST flag) has zero unit
  tests
Location: src/date.zig (absent)
Problem: macOS date(1) allows "date -r 0" to mean epoch 0
  (numeric seconds form). The code audit (date-code.md)
  identifies this as a CRITICAL code bug — statFile is
  called on the string "0" which fails. No unit test
  exposes this path. The existing -r tests use a real
  file path or a nonexistent path.
Fix: Add a failing test (red first):
    const args = [_][]const u8{ "-r", "0", "-u", "+%Y" };
    // should output "1970\n"
    // CURRENTLY exits 1 with "cannot stat reference file"
```

```
[IMPORTANT] -z behavioral output is never verified (MUST
  flag with zero behavioral coverage)
Location: src/date.zig (absent for behavior)
Problem: The only -z test is the false-behavioral test
  identified above plus one parse-only test (line 1214).
  Neither verifies that output zone is actually applied.
  -z is MUST tier.
Fix: Add a test that detects the no-op behavior:
    const args = [_][]const u8{ "-d", "@0", "-z", "UTC",
        "+%Z" };
    // expect "UTC\n" or "GMT\n"; currently outputs local TZ
  This test will fail until the code bug is fixed.
```

```
[IMPORTANT] -f with positional new_date argument is
  completely untested (MUST flag, broken in impl)
Location: src/date.zig (absent)
Problem: No unit test passes a positional argument after
  -f. The code audit confirms the feature is broken:
  any non-flag, non-format argument causes "extra operand".
  The correct invocation is:
    date -j -f "%Y-%m-%d" "2025-01-15" "+%Y"
  No test covers this code path.
Fix: Add a failing test first:
    const args = [_][]const u8{ "-j", "-f", "%Y-%m-%d",
        "2025-01-15", "+%Y" };
    // should output "2025\n"
    // CURRENTLY exits 2 with "extra operand"
```

```
[IMPORTANT] Conflicting output format error (-I + -R or
  -I + +format) has zero unit tests
Location: src/date.zig (absent)
Problem: macOS date(1) requires exit 1 with "multiple
  output formats specified" when -I is combined with -R
  or a +format operand. The code audit confirms this
  validation is missing — they silently pick a format.
  No unit test exercises the conflict path.
Fix: Add tests for both conflicts:
    // -I combined with -R — should exit 1
    const args1 = [_][]const u8{ "-I", "-R" };
    // expect exit 1, stderr "multiple output formats"

    // -I combined with +format — should exit 1
    const args2 = [_][]const u8{ "-I", "+%Y" };
    // expect exit 1, stderr "multiple output formats"
```

```
[SUGGESTION] -d with ISO 8601 datetime (not just date)
  has no dedicated test
Location: src/date.zig (absent)
Problem: parseIso8601 handles YYYY-MM-DDTHH:MM:SS but
  there is no test for this path. The -d tests only use
  @EPOCH notation. If parseIso8601's time branch regresses,
  no unit test catches it.
Fix: Add one deterministic test:
    const args = [_][]const u8{ "-u", "-d",
        "1970-01-01T00:00:01", "+%S" };
    try testing.expectEqualStrings("01\n", ...);
```

```
[SUGGESTION] -d fractional epoch seconds (@0.5) has no
  unit test
Location: src/date.zig:233-248 (fractional branch)
Problem: The fractional-seconds branch in resolveTimestamp
  is exercised by no unit test. If the multiplier loop
  regresses, nothing catches it. The -Ins and --rfc-3339=ns
  tests only use @0 which has zero nanoseconds.
Fix: Add a test that passes @0.500000000 and checks %N:
    const args = [_][]const u8{ "-u", "-d", "@0.5",
        "+%N" };
    try testing.expectEqualStrings("500000000\n", ...);
```

```
[SUGGESTION] --rfc-3339 without = separator (space form) is
  not tested
Location: src/date.zig (absent)
Problem: The parser handles both "--rfc-3339=seconds" and
  "--rfc-3339 seconds" (two-token form, lines 78-86). Only
  the = form is tested. The two-token path has no coverage.
Fix:
    const args = [_][]const u8{ "-u", "-d", "@0",
        "--rfc-3339", "seconds" };
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00+00:00\n", ...);
```

---

## Flag Coverage Matrix

| Flag | Tier | Parse test | Behavioral test | Quality |
|------|------|-----------|-----------------|---------|
| `-u` | MUST | — | yes (UTC/GMT %Z) | good |
| `-r file` | MUST | — | yes (real file, error) | partial |
| `-r seconds` | MUST | — | none | **missing** |
| `-j` | MUST | yes (parse-only) | exit-0 only | weak |
| `-f input_fmt` | MUST | yes (parse-only) | false-behavioral | **missing** |
| `-z output_zone` | MUST | yes (parse-only) | false-behavioral | **missing** |
| `+FORMAT` | MUST | — | many specifiers | good |
| `-I[FMT]` | SHOULD | — | all 5 precisions | good |
| `-R` | SHOULD | — | exact string match | good |
| `-n` | SHOULD | yes (parse-only) | exit-0 + no-stderr | ok |
| `-d STRING` | SHOULD | — | @EPOCH, ISO date | partial |
| `--rfc-3339` | SHOULD | — | all 3 precisions + error | good |
| `-v` | SHOULD | yes (parse-only x2) | stub-only x4 | **misleading** |
| `--utc` / `--universal` | — | — | via -u | ok |
| `--date=` | — | — | yes | good |
| `--reference=` | — | — | absent | gap |
| `--iso-8601=` | — | — | yes | good |
| conflicting formats | — | — | none | **missing** |

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 4 |
| SUGGESTION | 3 |

**Overall assessment: NEEDS_FIXES**

The suite has 55 passing tests and good coverage of
format specifiers, RFC output modes, and error paths. The
critical gaps are:

1. Two "behavioral" tests (`-z` and `-f`) hide broken
   implementations — they pass because a different flag
   does the work.
2. Four `-v` tests codify stub behavior and will fail when
   `-v` is correctly implemented.
3. Three MUST-tier flags have no real behavioral coverage:
   `-r numeric`, `-z output`, `-f new_date`.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Replace false -z behavioral test with one
   that detects the no-op bug
   — src/date.zig:1176-1187
2. [CRITICAL] Replace false -f behavioral test with one
   that exercises positional new_date parsing
   — src/date.zig:1152-1163
3. [IMPORTANT] Add -r numeric seconds failing test (red)
   — src/date.zig (new test)
4. [IMPORTANT] Add -z actual timezone output failing test
   — src/date.zig (new test)
5. [IMPORTANT] Add -f positional new_date failing test
   — src/date.zig (new test)
6. [IMPORTANT] Collapse 4 -v stub tests into 1 TODO test;
   plan replacement tests for each adjustment unit
   — src/date.zig:1241-1317
7. [IMPORTANT] Add conflicting output format error tests
   (-I + -R, -I + +format)
   — src/date.zig (new tests)
8. [SUGGESTION] Add -d YYYY-MM-DDTHH:MM:SS datetime test
   — src/date.zig (new test)
9. [SUGGESTION] Add -d @0.5 fractional epoch test
   — src/date.zig (new test)
10. [SUGGESTION] Add --rfc-3339 space-separated form test
    — src/date.zig (new test)
```

STATE: "REVIEW COMPLETE - NEEDS_FIXES"
