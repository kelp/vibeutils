# sleep - Code Audit

Date: 2026-03-28
Files reviewed: `src/sleep.zig`
GNU reference: `docs/specs/sleep-gnu.txt`, `docs/specs/sleep-flags.md`
Build: PASS
Integration tests: 10/10 PASS
Unit tests: all PASS

---

## Findings

### IMPORTANT: Invalid time interval error omits the invalid token

Location: `src/sleep.zig:113-117` (`parseTotalTime` error handler)

Problem: GNU sleep prints the invalid value in the error message:
```
sleep: invalid time interval 'invalid'
Try '/path/to/sleep --help' for more information.
```
Vibeutils prints only:
```
sleep: invalid time interval
```
The invalid token is omitted, and the "Try..." hint is also absent for this
error path. For `error.NegativeTime`, the message is identically terse. GNU
shows the actual bad value in both cases, which is required for diagnosing
scripts that pass variables.

Fix: Thread the failing argument string through the error path. The cleanest
approach is to move validation into `runSleep` rather than `parseTotalTime`,
or return the offending argument alongside the error. Since `parseTotalTime`
loops over `args`, the simplest approach is to inline the loop in `runSleep`:

```zig
for (parsed_args.positionals) |arg| {
    time.parseTimeString(arg) catch |err| {
        switch (err) {
            error.InvalidTimeFormat, error.NegativeTime => {
                common.printErrorWithProgram(allocator, stderr_writer, "sleep",
                    "invalid time interval '{s}'", .{arg});
                common.printErrorWithProgram(allocator, stderr_writer, "sleep",
                    "Try 'sleep --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            // ...
        }
    };
}
```

---

### IMPORTANT: 'inf' and 'infinity' not accepted; GNU sleeps forever on them

Location: `src/common/time.zig` (`parseTimeString`)

Problem: `sleep inf` and `sleep infinity` are valid on GNU and sleep
indefinitely. Vibeutils rejects them with "invalid time interval". This is a
behavioral divergence for a documented GNU feature.

```
$ gnu-sleep inf &; sleep 0.1; kill %1  # GNU: process runs (correct)
$ vibeutils-sleep inf                   # exit 2, invalid time interval
```

Fix: Add a special case in `parseTimeString` (or in `parseTotalTime`) that
detects the strings "inf" and "infinity" (case-insensitive) and returns
`std.math.maxInt(u64)`. Since `std.Thread.sleep(u64)` accepts a nanosecond
value, passing `maxInt(u64)` gives approximately 584 years — effectively
infinite.

---

### SUGGESTION: Error exit code is 2 (misuse); GNU uses 1

Location: `src/sleep.zig:109`, `src/sleep.zig:113`, `src/sleep.zig:117`,
`src/sleep.zig:122`

Problem: GNU sleep exits 1 for all error conditions (missing operand, invalid
time, negative time, overflow). Vibeutils returns
`@intFromEnum(common.ExitCode.misuse)` which is 2. This is a project-wide
convention that diverges from GNU. It affects scripts that test
`if sleep bad_value; then ...` using the exact exit code.

This is a project-wide convention issue, not unique to sleep. Fix would
require changing `ExitCode.misuse` to 1, or using `general_error` for these
errors.

---

### SUGGESTION: "Try '...' for more information." hint missing for most errors

Location: `src/sleep.zig:106-107` (only missing-operand path has the hint)

Problem: The "Try 'sleep --help' for more information." hint is printed only
for `error.MissingTimeArgument`. GNU prints it for all error cases. The hint
is absent for `InvalidTimeFormat`, `NegativeTime`, and `TimeOverflow` (lines
113-122). Additionally, the hint line is printed with a "sleep:" prefix
(`common.printErrorWithProgram`), while GNU prints it without the program
name prefix.

Fix: Add the hint line to each error path. Use a plain `stderr_writer.print`
call (not `printErrorWithProgram`) to match GNU's format without the "sleep:"
prefix.

---

## Test Coverage Assessment

Unit tests cover `parseTimeString` exhaustively (integers, decimals, suffixes,
invalid formats, NaN/Inf rejection, negatives) and `parseTotalTime` (single
args, multiple-arg summing, no-args, invalid args). The `runSleep` tests cover
help, version, missing operand, invalid format, negative time, zero sleep,
small sleep timing, multiple arguments, and a full-path allocator-safety test.

Coverage gap: no test verifies that the error message includes the invalid
token (e.g., `"invalid time interval 'badval'"`). Tests only check the static
string "invalid time interval". This means the missing-token bug would not be
caught by adding such a test first under TDD — the test currently passes
despite the bug.

---

## Summary

Counts: 0 CRITICAL, 2 IMPORTANT, 2 SUGGESTIONS

Overall assessment: NEEDS_FIXES

The two IMPORTANT issues are behavioral divergences from GNU that affect
real use. The missing token in error messages is a usability regression
(scripts and users can't tell which argument was bad). The `inf`/`infinity`
omission affects scripts that use indefinite sleep. Both are straightforward
to fix.

Fix Order:
1. [IMPORTANT] Error message must include invalid token —
   src/sleep.zig:113-117 (and src/common/time.zig for thread-through)
2. [IMPORTANT] Accept 'inf'/'infinity' as valid (sleep forever) —
   src/common/time.zig (parseTimeString)
3. [SUGGESTION] Add "Try '...' hint" to all error paths —
   src/sleep.zig:113-122
4. [SUGGESTION] Resolve exit code 2 vs GNU exit code 1 for errors —
   project-wide convention
