# date — Code Audit

**Date:** 2026-03-28
**Verdict:** NEEDS_FIXES
**Binary tested:** `zig-out/bin/date` vs `/usr/bin/date` (GNU coreutils 9.10 on Linux)
**Spec authority:** `docs/specs/date-macos.txt` (macOS/BSD is CORRECT per ground rules)

---

## Flag Verdict Table

| Flag | Tier | Status | Notes |
|------|------|--------|-------|
| `-u` | MUST | PASS | Correctly uses UTC |
| `-r file` | MUST | PASS | Correctly returns mtime of file |
| `-r seconds` | MUST | FAIL | Numeric seconds not supported — tries to stat |
| `-j` | MUST | PASS | Accepted, does not set date |
| `-f input_fmt` | MUST | FAIL | Positional `new_date` arg after `-f` causes "extra operand" error |
| `-z output_zone` | MUST | FAIL | Parsed but never applied — output is unchanged |
| `-I[FMT]` | SHOULD | PASS | Correct output for date/hours/minutes/seconds/ns |
| `-R` | SHOULD | PASS | Correct RFC 2822 output |
| `-n` | SHOULD | PASS | Accepted as no-op (correct for macOS compat) |
| `-v` | SHOULD | FAIL | Parsed but returns exit code 1 with error message — stub |
| `--rfc-3339=FMT` | SHOULD | PASS | Correct for date/seconds/ns |
| `+format` | MUST | PASS | Passed to strftime correctly |
| `%s` | — | PASS | Epoch seconds formatted correctly |
| `%N` | — | PASS | Nanoseconds formatted correctly |
| `%:z` | — | PASS | Colon-separated tz offset correct |
| `%z` | — | PASS | Numeric tz offset correct |

---

## Findings

```
[CRITICAL] -z output_zone is a no-op stub
Location: src/date.zig:177-189, src/date.zig:518-584
Problem: -z is parsed into opts.output_zone but runDate never reads it.
  The timezone change before printing (via setenv("TZ", ...) or equivalent)
  is never performed. `date -z America/New_York -d @0` outputs UTC time
  instead of EST.
Fix: Before converting the timestamp with localtime_r, apply the -z zone.
  The cleanest approach is:
    if (opts.output_zone) |zone| {
        _ = setenv("TZ", zone.ptr, 1);
        tzset();
    }
  Then call localtime_r (not gmtime_r) to get local time in that zone.
  After formatting, restore TZ if needed. See extern fn patterns in
  src/df.zig for setenv usage.
```

```
[CRITICAL] -r does not accept numeric seconds (MUST per macOS spec)
Location: src/date.zig:260-267
Problem: resolveTimestamp calls std.fs.cwd().statFile(ref) on whatever
  string was passed to -r. When the argument is a number like `0` or
  `86400`, statFile fails and returns "cannot stat reference file".
  macOS date(1) allows `date -r 0` to mean epoch 0.
Fix: Before calling statFile, try to parse the argument as a decimal
  integer. If it parses cleanly (no leftover characters), treat it as
  epoch seconds directly. Fall back to statFile if parsing fails.
  Example:
    const epoch = std.fmt.parseInt(i64, ref, 10) catch null;
    if (epoch) |secs| return .{ .secs = secs, .ns = 0, .err = null };
    // then statFile as before
```

```
[CRITICAL] -f input_fmt is completely broken — positional argument
  after flags is rejected as "extra operand"
Location: src/date.zig:55-64, src/date.zig:164-175
Problem: parseArgs rejects any positional argument (not starting with
  '+' or '-') with "extra operand". The macOS -f synopsis is:
    date [-j...] -f input_fmt new_date [+output_fmt]
  `new_date` is a positional argument. There is no way to pass it.
  `date -j -f "%Y-%m-%d" "2025-01-15"` exits 2 with "extra operand".
Fix: Track whether -f has been seen in the parse loop. After all flag
  processing, if opts.input_fmt is set, the next non-flag non-format
  token should be stored as opts.new_date (a new field). Then call
  strptime(new_date, input_fmt, &tm) in resolveTimestamp when
  input_fmt is set.
```

```
[IMPORTANT] -v is a SHOULD-tier flag that is a silent stub returning
  exit code 1 with an error message
Location: src/date.zig:546-550
Problem: -v is SHOULD tier per docs/specs/date-flags.md. Calling
  `date -v +1d` prints "date: -v adjustment not yet implemented" and
  exits 1 (general_error). The integration test at line 78-95 codifies
  this broken behavior as expected, which masks the gap.
Fix: Either implement -v date arithmetic or, if deferring, document
  clearly in the audit tracker. The current behavior (exit 1 + error
  message) is not equivalent to "unimplemented" — a SHOULD flag must
  work or be absent, not error. The integration test should be updated
  to reflect the real target behavior.
```

```
[IMPORTANT] Conflicting output formats (-I and -R combined) produce no
  error — macOS spec says this must error
Location: src/date.zig:334-370 (getFormatString), src/date.zig:518-584
Problem: macOS date(1) DIAGNOSTICS section explicitly states: "It is
  invalid to combine the -I flag with either -R or an output format
  (+...) operand. If this occurs, date prints: 'multiple output formats
  specified' and exits with status 1."
  Our implementation silently uses the first matching branch in
  getFormatString; `date -I -R` outputs RFC 2822 without error.
Fix: Add a validation step after parsing (similar to validatePrecision)
  that counts how many of {opts.iso_8601, opts.rfc_email, opts.rfc_3339,
  opts.format} are non-null. If more than one is set, print
  "multiple output formats specified" and return exit code 1.
```

```
[IMPORTANT] -d only supports @EPOCH and ISO 8601 date strings; it
  silently fails on all other inputs
Location: src/date.zig:228-258 (resolveTimestamp)
Problem: When -d is given a string that is not @EPOCH and not
  YYYY-MM-DD[THH:MM[:SS]], parseIso8601 returns .err = "invalid date".
  Natural-language strings ("yesterday", "next monday", "2 days ago")
  are common real-world uses. The error message is correct but the
  scope of what is supported is very narrow and undocumented.
  Additionally, timezone offsets in ISO strings (e.g.
  "2025-01-15T10:30:00+05:00") are silently ignored — the +05:00 part
  is discarded and local time is used.
Fix (scope issue): Document in --help and man page that -d only accepts
  @SECONDS and YYYY-MM-DD[THH:MM:SS] strings. If GNU-style natural
  language is desired, that is a larger feature.
Fix (timezone offset): After parsing HH:MM:SS, check whether the
  remaining string matches [+-]HH:MM or Z and apply that offset when
  converting to epoch (use timegm + manual offset rather than mktime).
```

```
[SUGGESTION] parseIso8601 uses mktime (local time) for conversion
Location: src/date.zig:313-331
Problem: When -d "2025-01-15" is given without -u, mktime interprets
  the struct tm as local time. This is arguably correct (the user said
  midnight on Jan 15 in their local zone). However, the tm struct has
  tm_zone set to "UTC" and tm_gmtoff = 0 even when mktime will apply
  local offsets, which is misleading. The field values do not match
  what mktime uses.
Fix: Remove the tm_zone and tm_gmtoff assignments from the struct
  literal in parseIso8601 (lines 324-325). They have no effect on
  mktime and create a false impression of UTC behavior.
```

```
[SUGGESTION] -u and -z together: -u wins silently, -z is ignored
Location: src/date.zig:562-572
Problem: When both -u and -z are specified, -u is applied (gmtime_r)
  and -z is never read. This is unlikely to be the correct priority
  (the user explicitly named a zone with -z). macOS uses localtime_r
  after applying -z even when -u is set. No error is reported.
Fix: Document the precedence or, better, treat -u and -z as mutually
  exclusive — error if both are specified.
```

---

## Test Coverage Gaps

- **-r numeric seconds**: zero unit tests; zero integration tests
- **-f/-j with new_date**: zero unit tests (feature is broken)
- **-z**: one unit test exists (`date -z output_zone`) but tests only
  parse acceptance (`opts.output_zone != null`), not behavioral output
- **-v**: integration test verifies non-zero exit, not correct
  adjustment behavior — locked to stub behavior
- **Conflicting format flags**: zero tests for -I + -R conflict error
- **-d timezone offset in ISO string**: zero tests

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 3 |
| SUGGESTION | 2 |

**Overall: NEEDS_FIXES**

### Fix Order

1. [CRITICAL] `-z output_zone` is a no-op — `src/date.zig:177-189`
2. [CRITICAL] `-r` numeric seconds not supported — `src/date.zig:260-267`
3. [CRITICAL] `-f input_fmt` completely broken, positional arg rejected — `src/date.zig:55-64`
4. [IMPORTANT] Conflicting output formats produce no error — `src/date.zig:334-370`
5. [IMPORTANT] `-v` stub exits 1 with error; integration test codifies wrong behavior — `src/date.zig:546-550`
6. [IMPORTANT] `-d` silently ignores timezone offset in ISO strings — `src/date.zig:298-310`
7. [SUGGESTION] `parseIso8601` has misleading `tm_zone`/`tm_gmtoff` values — `src/date.zig:323-325`
8. [SUGGESTION] `-u` and `-z` conflict is silent — `src/date.zig:562-572`

REVIEW COMPLETE - NEEDS_FIXES
