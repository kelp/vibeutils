# head Unit Test Audit

**Date:** 2026-03-28
**Auditor:** reviewer agent
**Result:** NEEDS_FIXES

## Test Run

```
Tests run: 21
Passed:    21
Failed:    0
Runtime:   ~11ms (no anomaly)
```

All 21 tests pass. Runtime is normal — no stdin hang risk from
the current test suite.

---

## Filter Utility Assessment

`head` is a filter utility (reads stdin when no files given).
The relevant question is: do any unit tests call `runHead` with
no file arguments, causing a live read from `std.fs.File.stdin()`?

**Answer: No.** Every unit test passes at least one file path as
a positional argument. The stdin branch inside `runHead` is never
reached by any unit test.

However, there is a latent architectural issue: `runHead` opens
`std.fs.File.stdin()` unconditionally at line 119, before
checking whether any files were passed. This means the file
descriptor is acquired on every call, even when reading files.
In the current tests this causes no hang because `stdin` is
never read — but the resource is acquired unnecessarily and the
pattern diverges from the `runUtilWithInput()` architecture used
by other filter utilities. This is flagged below.

---

## Test Inventory

| # | Test Name | Category | Behavioral? |
|---|---|---|---|
| 1 | head outputs first 10 lines by default | default behavior | Yes |
| 2 | head with -n 5 outputs first 5 lines | -n flag | Yes |
| 3 | head with -c 10 outputs first 10 bytes | -c flag | Yes |
| 4 | head handles fewer lines than requested | EOF edge | Yes |
| 5 | head handles fewer bytes than requested | EOF edge | Yes |
| 6 | head handles empty input | empty file | Yes |
| 7 | head with -n 0 outputs nothing | -n boundary | Yes |
| 8 | head with -c 0 outputs nothing | -c boundary | Yes |
| 9 | head processes lines efficiently | -n small count | Yes |
| 10 | head processes bytes efficiently | -c small count | Yes |
| 11 | head handles invalid line count | error path | Yes |
| 12 | head help flag works | --help | Weak (content check) |
| 13 | head version flag works | --version | Weak (content check) |
| 14 | head with line count larger than available lines | -n overflow | Yes |
| 15 | head byte count takes precedence over line count | -c overrides -n | Yes |
| 16 | head continues after file error and outputs remaining files | multi-file error | Yes |
| 17 | head with multiple files shows headers | multi-file headers | Weak (contains check) |
| 18 | head with -z uses NUL as line delimiter | -z + -n | Yes |
| 19 | head with -z and default line count | -z default | Yes |
| 20 | head with -z and fewer items than requested | -z EOF | Yes |
| 21 | head with obsolete -NUM syntax | legacy compat | Yes |

No parse-only tests. Every test calls `runHead` and inspects either
output content or exit code. This is a well-structured test suite.

---

## Findings

### [IMPORTANT] stdin path has zero unit test coverage

**Location:** `src/head.zig:122-124`

**Problem:** The no-args (stdin) branch of `runHead` — where
`parsed_args.positionals.len == 0` and the code calls
`processInput(stdin, ...)` — is never exercised by any unit test.
The integration tests cover stdin via shell pipes, but the unit
test suite has no coverage of this path.

The `processInput` function itself is indirectly covered by all
the file-based tests, so the logic is tested. What is untested
is the argument-routing path that selects stdin when no files
are provided.

**Fix:** Add a unit test using `processInput` directly with a
fixed-content reader, mirroring how other filter utilities
handle this:

```zig
test "head reads stdin when no files given" {
    // Use processInput directly with a fixed reader to avoid
    // live stdin reads in unit tests.
    var content = "line1\nline2\nline3\n".*;
    var fbs = std.io.fixedBufferStream(&content);
    var buf: [8192]u8 = undefined;
    var rdr = fbs.reader(&buf);

    var out = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer out.deinit(testing.allocator);

    const opts = HeadOptions{ .line_count = 2 };
    try processInput(&rdr.interface, out.writer(testing.allocator), opts);
    try testing.expectEqualStrings("line1\nline2\n", out.items);
}
```

---

### [IMPORTANT] Architecture: stdin opened unconditionally in runHead

**Location:** `src/head.zig:118-120`

**Problem:** `runHead` allocates a stdin reader on every invocation,
even when file arguments are present:

```zig
var stdin_buffer: [8192]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;
```

This means:

1. The stdin file descriptor is opened even in the common case of
   processing named files. Other utilities in this project follow the
   `runUtilWithInput()` pattern and inject the reader as a parameter,
   which makes the function testable without relying on the process's
   stdin at all.

2. It makes it structurally impossible to write a `runHead`-level
   unit test for the stdin path without the test reading from the
   real process stdin (causing a hang if no data is provided).

The integration tests work around this by using shell pipes, which
is correct for integration testing, but the unit suite cannot safely
test the stdin routing at the `runHead` level.

**Fix:** Refactor `runHead` to accept a stdin reader parameter, or
adopt the `runUtilWithInput()` split used by `tail` and other filter
utilities. The minimal change is to move the stdin reader construction
outside `runHead` into `main()`, then inject it:

```zig
pub fn runHead(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdin_reader: anytype,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 { ... }
```

This would allow unit tests to inject a `fixedBufferStream` reader
and cover the stdin routing path without any hang risk.

---

### [IMPORTANT] -q and -v flags have no unit tests

**Location:** `src/head.zig` — no test named "quiet" or "verbose"

**Problem:** `-q` (quiet) and `-v` (verbose) are SHOULD-tier flags
per `docs/specs/head-flags.md`. They affect the `show_headers` field
which controls whether `==> filename <==` headers are printed.

The only header-related unit test (#17) checks that `==>` and `<==`
appear in the output when two files are passed — it does not test
suppression with `-q` or forced display with `-v` on a single file.

The following behaviors are untested in unit tests:

- `-q` with two files: output must contain no headers
- `-v` with one file: output must contain the header
- `-q -v` conflict: quiet wins (verified by integration tests but
  not unit tests)

**Fix:** Add three tests:

```zig
test "head -q suppresses headers for multiple files" { ... }
test "head -v forces header for single file" { ... }
test "head -q overrides -v" { ... }
```

---

### [SUGGESTION] Test #17 uses contains-check for header format

**Location:** `src/head.zig:617-619`

```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "==>") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "<==") != null);
```

**Problem:** This verifies that `==>` and `<==` appear somewhere in
the output, but does not verify the full header format
`==> <path> <==` nor the blank-line separator between files. A
regression that emits malformed headers (e.g., `>> file <<`) would
pass this test.

**Fix:** Assert the exact header strings:

```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items,
    try std.fmt.allocPrint(testing.allocator, "==> {s} <==\n", .{path1})) != null);
```

---

### [SUGGESTION] Test #11 uses `TEST_NEGATIVE_VALUE` constant indirection

**Location:** `src/head.zig:287,496`

```zig
const TEST_NEGATIVE_VALUE: []const u8 = "-5";
...
const args = [_][]const u8{ "-n", TEST_NEGATIVE_VALUE };
```

**Problem:** `-5` is not invalid because it is negative (the argparse
layer rejects it because it cannot parse `-5` as a `u64`). The
constant name `TEST_NEGATIVE_VALUE` implies the test is about
negative numbers, but the test is actually about argparse rejecting a
non-numeric value in `-n` context (since `-5` expands via
`expandObsoleteArgs` to `-n 5` before reaching argparse, and the
literal string `"-5"` in this position is treated as an invalid
number for `-n`). The indirection adds confusion without clarity.

**Fix:** Inline the value and add a comment:

```zig
// "-5" is rejected by argparse as a non-u64 value for -n
const args = [_][]const u8{ "-n", "-5" };
```

---

### [SUGGESTION] -z + -c combination not tested

**Location:** `src/head.zig` — no `-z -c` test

**Problem:** The three `-z` unit tests all use `-z` with `-n` (line
mode with NUL delimiter). The combination of `-z` with `-c` (byte
mode) is untested. In byte mode the delimiter is ignored, so `-z -c`
should behave identically to `-c` alone. A test confirming this
equivalence would pin the behavior.

**Fix:** Add one test:

```zig
test "head -z with -c ignores delimiter (byte mode)" {
    // -z should have no effect when -c is also specified
    ...
    const args = [_][]const u8{ "-z", "-c", "5", file_path };
    ...
    try testing.expectEqualStrings("Hello", stdout_buffer.items);
}
```

---

## Coverage Summary

| Flag | Tier | Unit Tests | Quality |
|---|---|---|---|
| -n / --lines | MUST | Yes (tests 2,7,9,14) | Strong |
| -c / --bytes | SHOULD | Yes (tests 3,5,8,10,15) | Strong |
| -q / --quiet | SHOULD | None | None |
| -v / --verbose | SHOULD | None | None |
| -z | SHOULD | Yes (tests 18,19,20) | Good (missing -c combo) |
| Multi-file headers | behavior | Weak (contains-only) | Weak |
| stdin path | core | None at runHead level | None |
| -NUM obsolete syntax | compat | Yes (test 21) | Strong |
| Error / misuse exit | error | Yes (test 11,16) | Strong |

---

## Summary

**Counts:**
- CRITICAL: 0
- IMPORTANT: 3
- SUGGESTION: 4

**Overall Assessment:** NEEDS_FIXES

The test suite is above average for this project. No parse-only
stubs exist; all 21 tests make behavioral assertions. The primary
gaps are: the stdin routing path is completely untested at the unit
level, `-q`/`-v` behavioral coverage is absent in unit tests (though
present in integration tests), and the `runHead` architecture makes
the stdin path structurally untestable without refactoring.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] stdin routing path untested at runHead level
   — src/head.zig (add processInput-direct test as interim)
2. [IMPORTANT] runHead opens stdin unconditionally, blocking
   injectable testing — src/head.zig:118-120 (refactor)
3. [IMPORTANT] -q / -v have no unit tests — src/head.zig
4. [SUGGESTION] Header format check is contains-only — src/head.zig:617-619
5. [SUGGESTION] -z + -c combination untested — src/head.zig
6. [SUGGESTION] TEST_NEGATIVE_VALUE constant name misleads — src/head.zig:287
```

REVIEW COMPLETE - NEEDS_FIXES
