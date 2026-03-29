---
date: 2026-03-28
utility: touch
verdict: NEEDS_FIXES
build: PASS (zig build test — 1783/1783 tests pass)
integration: PASS (107/107 tests pass)
---

# touch Code Audit

## Summary

**3 CRITICAL, 4 IMPORTANT, 2 SUGGESTION**
**Overall verdict: NEEDS_FIXES**

All unit and integration tests pass. The issues below are behavioral
divergences from the macOS primary spec that tests do not catch.

---

## Flag-by-Flag Verdict

| Flag      | Tier   | Status | Notes                                  |
|-----------|--------|--------|----------------------------------------|
| -a        | MUST   | PASS   | Correctly updates only access time     |
| -c        | MUST   | PASS   | Correctly skips creation               |
| -d        | MUST   | FAIL   | TZ ignored; Z suffix has no effect     |
| -m        | MUST   | PASS   | Correctly updates only mtime           |
| -r        | MUST   | PASS   | Correctly copies timestamps            |
| -t        | MUST   | FAIL   | Rejects SS=60 (leap second); pre-1970  |
| -A        | SHOULD | STUB   | Exits non-zero with "not yet impl"     |
| -f        | SHOULD | PASS   | Correctly ignored per GNU spec         |
| -h        | SHOULD | FAIL   | Does not imply -c as macOS requires    |
| --time    | SHOULD | PASS   | access/atime/use/modify/mtime work     |

---

## Critical Issues

```
[CRITICAL] -A is a documented SHOULD stub
Location: src/touch.zig:104-107
Problem: -A exits non-zero with "not yet implemented". The flag table
  marks it SHOULD. Per ground rules, a parsed flag that does not
  change output is CRITICAL. The flag is accepted but its effect
  (adjusting timestamps by a delta) is not implemented. This is
  not the same as ignored (-f); it fails loudly. A SHOULD flag
  must either be implemented or, if deliberately omitted, removed
  from the flag table.
Fix: Implement the -A adjustment logic per macOS spec:
  argument form [-][[hh]mm]SS, apply signed delta to current
  atime/mtime. Also: -A implies -c (do not create).
```

```
[CRITICAL] -h does not imply -c
Location: src/touch.zig:110-113
Problem: macOS spec states "Note that -h implies -c and thus will not
  create any new files." The code sets no_dereference from -h but
  never sets no_create. Running `touch -h new_file` creates a
  regular file named new_file. Verified live:
    $ touch -h new_non_symlink
    $ ls new_non_symlink   # file exists — wrong
Fix: In runTouch, after resolving flags:
  const no_create = parsed_args.c or parsed_args.no_create
    or parsed_args.h or parsed_args.no_dereference;
```

```
[CRITICAL] -d treats all times as UTC regardless of timezone
Location: src/touch.zig:454-502 (parseIso8601)
Problem: parseIso8601 converts date components directly to a
  seconds-since-epoch value using a UTC-only calculation. It
  reads a trailing Z or fractional seconds but does not use
  either — anything after position 19 is silently discarded
  (no branch for Z or +HH:MM offset handling). Both
  "2024-01-15T00:00:00" and "2024-01-15T00:00:00Z" produce
  the same timestamp (1705276800). On a non-UTC system, a
  local-time input such as "2024-01-15T00:00:00" should
  produce a timestamp shifted by the local UTC offset.
  macOS/GNU spec: "The time is assumed to be in local time.
  Local time is affected by the value of the TZ environment
  variable."
Fix: After extracting HH:MM:SS, check for trailing Z or
  +/-HH:MM offset. Without a suffix, apply the local UTC
  offset (read TZ or call localtime_r) before converting to
  epoch seconds.
```

---

## Important Issues

```
[IMPORTANT] -t rejects SS=60 (leap second)
Location: src/touch.zig:415
Problem: macOS spec: "The second of the minute, from 00 to 60."
  GNU spec agrees. The code validates `second > 59` which
  rejects 60. Running:
    $ touch -t 202401150000.60 file
    touch: invalid date format '202401150000.60'
Fix: Change validation to `second > 60` at line 415 and the
  matching line 489 for parseIso8601.
```

```
[IMPORTANT] Pre-1970 timestamps rejected by both -t and -d
Location: src/touch.zig:419, 490
Problem: Both parse functions reject year < 1970. The macOS
  obsolescent form description says years 1939-1999 are valid
  (YY range 39-99). GNU touch on 64-bit systems accepts
  arbitrary years. The comment at line 417 says "GNU touch
  supports years 1970-2037 for 32-bit time_t" but this is
  the 32-bit limitation — the project targets 64-bit where
  negative epoch offsets are valid.
Fix: Remove the `year < 1970` guard. The daysFromYMD function
  already handles years before 1970 correctly (it returns
  negative values). The .sec field cast to i64 can hold
  negative values on 64-bit targets.
```

```
[IMPORTANT] "-" as file argument creates a file named "-" instead
  of updating stdout's timestamps
Location: src/touch.zig:136 (file loop)
Problem: GNU spec: "A FILE argument string of - is handled specially
  and causes touch to change the times of the file associated
  with standard output." Our implementation treats "-" as a
  literal path and creates a file named "-". Verified live:
    $ touch -; ls -- -   # file "-" exists
Fix: In the file loop, before calling touchFile, check:
  if (std.mem.eql(u8, file_path, "-")) {
      // update fd 1 (stdout) timestamps via futimens
  }
```

```
[IMPORTANT] Unit test "touch with -t timestamp" is a cannot-fail
  test
Location: src/touch.zig:878
Problem: The test sets a specific timestamp with -t and then only
  checks `stat.mtime > 0`. Any positive mtime satisfies this
  condition, including the current time if the -t parsing
  silently falls back. The correct check is to compare against
  the expected epoch value for 2023-12-31 13:59:00 UTC.
Fix: Replace:
  try testing.expect(stat.mtime > 0);
  With a range check against the expected epoch value:
  // 202312311359.00 -> 2023-12-31 13:59:00 UTC = 1703930340s
  const expected_ns: i128 = 1703930340 * std.time.ns_per_s;
  try expectTimestampsEqual(expected_ns, stat.mtime);
```

---

## Suggestions

```
[SUGGESTION] parseTimestamp and parseIso8601 duplicate validation
  logic and year-floor constraints
Location: src/touch.zig:352-447, 454-502
Problem: Both functions contain nearly identical range-check
  blocks and year-floor logic. A shared helper would reduce
  the surface area for future inconsistency.
Fix: Extract a validateAndConvertToTimespec(year, month, day,
  hour, minute, second) helper used by both callers.
```

```
[SUGGESTION] Obsolescent form (MMDDhhmm[YY] as first positional)
  not supported
Location: src/touch.zig:130-133
Problem: macOS compatibility note: when no -r/-t is specified,
  there are >= 2 arguments, and the first is 8 or 10 digits,
  it is treated as MMDDhhmm[YY]. Not implementing this is
  acceptable (it is a compatibility note, not a MUST/SHOULD),
  but the flags table does not document the omission.
Fix: Either implement or add a comment in the code noting
  this compatibility form is intentionally not supported.
```

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -h does not imply -c — src/touch.zig:113
2. [CRITICAL] -d ignores TZ; Z suffix silently discarded
   — src/touch.zig:493-496
3. [CRITICAL] -A is a SHOULD stub that fails loudly
   — src/touch.zig:104-107
4. [IMPORTANT] "-" creates file instead of updating stdout fd
   — src/touch.zig:136
5. [IMPORTANT] -t and -d reject SS=60 (leap second)
   — src/touch.zig:415, 489
6. [IMPORTANT] Pre-1970 timestamps rejected on 64-bit target
   — src/touch.zig:419, 490
7. [IMPORTANT] Cannot-fail unit test for -t timestamp value
   — src/touch.zig:878
8. [SUGGESTION] Deduplicate parse validation helpers
9. [SUGGESTION] Document or implement obsolescent form
```

State: "REVIEW COMPLETE - NEEDS_FIXES"
