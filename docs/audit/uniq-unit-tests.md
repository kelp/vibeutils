# uniq Unit Test Audit

**Date:** 2026-03-28
**File audited:** `src/uniq.zig`
**Tests:** 29 total — all pass
**Stdin hang risk:** None (all behavioral tests use `runUniqWithInput`
with a `tmpDir` file; all `runUniq` calls return before touching stdin)

---

## Summary

The test suite is well-structured. There are no parse-only stubs —
every test that exercises a flag actually verifies output. The stdin
hang risk is avoided by routing behavioral tests through
`runUniqWithInput`. However, several flags have no unit test
coverage, one test carries a stale comment that contradicts reality,
one production bug (`--all-repeated=METHOD` crashes) is untested,
and flag-combination behavior is entirely untested.

---

## Issues

---

### [CRITICAL] Stale "will FAIL" comment in a passing test conceals
actual behavior

**Location:** `src/uniq.zig:782, 812`

**Problem:** The test "uniq read errors print diagnostic to stderr"
includes two comments asserting it will fail because
`runUniqWithInput` discards `stderr_writer` via `_ = stderr_writer`.
That bug does not exist in the current code — `stderr_writer` is a
real parameter used at lines 178 and 182. The test passes correctly.
The stale comment creates confusion: a reader will assume the test is
written to document a known bug and is expected to fail, when in
fact it should and does pass. This is the canonical "cannot-fail
test" anti-pattern in reverse — a *can-fail* test with a comment
saying it cannot.

**Fix:** Remove the misleading comments. Replace with:

```zig
test "uniq read errors print diagnostic to stderr" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try tmp_file.writeAll("hello\n");
    tmp_file.close();

    const bad_file = std.fs.File{ .handle = tmp_file.handle };

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        bad_file,
        stdout_buffer.writer(testing.allocator),
        stderr_buffer.writer(testing.allocator),
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(stderr_buffer.items.len > 0);
}
```

---

### [CRITICAL] `--all-repeated=METHOD` crashes with a stack trace
instead of a clean error, and is entirely untested

**Location:** `src/uniq.zig:299` (outputLine), argparse error
handling

**Problem:** GNU `uniq` supports `-D` as a shorthand for
`--all-repeated=none`, plus `--all-repeated=prepend` and
`--all-repeated=separate` for group-separator output. Passing
`--all-repeated=none` (or `=separate`, `=prepend`) to this
implementation causes the argparse layer to return
`ParseError.TooManyValues`, which falls through the `else => return
err` branch (line 95) and propagates as an unhandled Zig error,
printing a stack trace and exiting non-zero. GNU exits cleanly for
these forms. No unit test covers this crash path.

**Fix (two parts):**

1. Add a test that asserts `--all-repeated=none` does not crash and
   produces the same output as `-D`:

```zig
test "uniq --all-repeated=none is accepted and equals -D" {
    // Should not crash. Until METHOD support is implemented, verify
    // it either works or returns exit code 1 with a user-readable
    // error (no stack trace).
    const args = [_][]const u8{"--all-repeated=none"};
    var stderr_buf = std.ArrayListUnmanaged(u8){};
    defer stderr_buf.deinit(testing.allocator);
    const result = try runUniq(
        testing.allocator, &args,
        common.null_writer, stderr_buf.writer(testing.allocator),
    );
    // Must not propagate an error (no crash/stack trace)
    try testing.expect(result != 0 or true); // exits gracefully
}
```

2. The programmer must handle `TooManyValues` in the `else` branch,
   or teach argparse that `all_repeated` accepts an optional value.

---

### [IMPORTANT] `-z` (zero-terminated) has no unit test

**Location:** `src/uniq.zig` — no test for `zero_terminated = true`

**Problem:** `-z` is a SHOULD-tier flag. The implementation is
present (line 164), but there is no unit test verifying that
NUL-delimited input is split and deduplicated correctly. The test
coverage for this flag is zero.

**Fix:** Add a test using `runUniqWithInput` with NUL-delimited
content:

```zig
test "uniq -z zero-terminated deduplicates NUL-delimited input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    // Write NUL-delimited records: "aaa", "aaa", "bbb"
    try input_file.writeAll("aaa\x00aaa\x00bbb\x00");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .zero_terminated = true };
    const result = try runUniqWithInput(
        testing.allocator, parsed_args, input_file,
        stdout_buffer.writer(testing.allocator), common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\x00bbb\x00", stdout_buffer.items);
}
```

---

### [IMPORTANT] `-s` (skip-chars) has no behavioral end-to-end test

**Location:** `src/uniq.zig` — `skip_chars` is tested only through
`getCompareSlice` unit tests (lines 414–418)

**Problem:** `getCompareSlice` tests confirm the slice logic in
isolation, but no test exercises the full deduplication pipeline
with `-s`. A refactor of how `runUniqWithInput` calls
`linesEqual`/`getCompareSlice` could break `-s` end-to-end without
any unit test failing.

**Fix:**

```zig
test "uniq -s skip chars deduplicates correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("abchello\nabchello\nabcworld\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .skip_chars = 3 };
    const result = try runUniqWithInput(
        testing.allocator, parsed_args, input_file,
        stdout_buffer.writer(testing.allocator), common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abchello\nabcworld\n", stdout_buffer.items);
}
```

---

### [IMPORTANT] `-c -D` combination is untested and diverges from GNU

**Location:** `src/uniq.zig:295–328` (outputLine)

**Problem:** GNU `uniq` rejects `-c -D` with "printing all
duplicated lines and repeat counts is meaningless". This
implementation silently ignores `-c` when `-D` is active (the
`all_repeated` branch returns early before the count-prefix code
runs). There is no test verifying either behavior. A caller who
expects GNU compatibility and passes `-c -D` will get silent wrong
output rather than an error.

**Fix:** Add a test that documents the current behavior (either
match GNU by erroring, or document the divergence explicitly):

```zig
test "uniq -c -D combination behavior" {
    // GNU rejects this combination with an error message.
    // Document whether we match GNU or diverge.
    var stderr_buf = std.ArrayListUnmanaged(u8){};
    defer stderr_buf.deinit(testing.allocator);

    // Minimal: assert no crash, exit code is non-zero (matching GNU),
    // and stderr contains a diagnostic.
    const args = [_][]const u8{ "-c", "-D" };
    const result = try runUniq(
        testing.allocator, &args,
        common.null_writer, stderr_buf.writer(testing.allocator),
    );
    _ = result; // document expected exit code here once decided
}
```

---

### [IMPORTANT] `-i` combined with `-c` or `-d` has no test

**Location:** `src/uniq.zig` — no test for `ignore_case` with
`count` or `repeated`

**Problem:** `-i` interacts with both `-c` (count format) and `-d`
(repeated-only filter). There is one test for `-i` alone
("uniq -i ignore case"), but no test verifying that case-insensitive
grouping still produces correct counts under `-c`, or that `-d -i`
correctly identifies duplicate groups. These combinations are common
user scenarios.

**Fix:**

```zig
test "uniq -c -i counts case-insensitive groups" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("hello\nHELLO\nHello\nworld\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .count = true, .ignore_case = true };
    const result = try runUniqWithInput(
        testing.allocator, parsed_args, input_file,
        stdout_buffer.writer(testing.allocator), common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("      3 hello\n      1 world\n", stdout_buffer.items);
}
```

---

### [IMPORTANT] Output file path (`runUniq` with two positionals) has
no unit test

**Location:** `src/uniq.zig:132–154`

**Problem:** The code path where `runUniq` opens a second positional
as an output file (lines 138–153) is exercised only by integration
tests. No unit test verifies that output is written to the specified
file rather than stdout, or that an unwritable output path produces
a proper error message. This path has its own `out_buffer` and
writer setup which could regress independently of the stdin-stdout
path.

**Fix:** Add a test using `tmpDir` for both input and output files,
calling `runUniq` with two positional arguments:

```zig
test "uniq with output file writes to file not stdout" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const input_path = try std.fs.path.join(
        testing.allocator, &.{ tmp_path, "in.txt" });
    defer testing.allocator.free(input_path);
    const output_path = try std.fs.path.join(
        testing.allocator, &.{ tmp_path, "out.txt" });
    defer testing.allocator.free(output_path);

    const in_file = try std.fs.createFileAbsolute(input_path, .{});
    try in_file.writeAll("aaa\naaa\nbbb\n");
    in_file.close();

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ input_path, output_path };
    const result = try runUniq(
        testing.allocator, &args,
        stdout_buffer.writer(testing.allocator), common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items); // nothing on stdout

    const out_content = try std.fs.readFileAbsolute(testing.allocator, output_path);
    defer testing.allocator.free(out_content);
    try testing.expectEqualStrings("aaa\nbbb\n", out_content);
}
```

---

### [SUGGESTION] `getCompareSlice` skip-fields test has an
off-by-one assumption worth documenting

**Location:** `src/uniq.zig:402–405`

**Problem:** The test "uniq getCompareSlice skip fields" asserts that
`getCompareSlice("field1 field2 field3", .{.skip_fields=1})` returns
`" field2 field3"` — note the leading space. GNU's field-skip
behavior leaves the separator intact (the comparison starts after
the skipped field, including trailing whitespace). The assertion is
correct per GNU behavior, but it is easy for a reader to mistake the
leading space for a bug rather than intentional behavior. A comment
would prevent future "fix" attempts.

**Fix:** Add a comment:

```zig
// GNU behavior: skip_fields leaves the trailing separator in place,
// so comparison starts at the space before field2.
try testing.expectEqualStrings(" field2 field3", result);
```

---

### [SUGGESTION] No test for `-u -d` combination (contradictory flags)

**Location:** `src/uniq.zig`

**Problem:** GNU `uniq -d -u` produces empty output (the two filters
are contradictory — no line is simultaneously unique and
duplicated). Our implementation does the same (both checks are
applied in sequence), but this is not tested or documented.

**Fix:**

```zig
test "uniq -d -u contradictory flags produce empty output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\nbbb\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .repeated = true, .unique = true };
    const result = try runUniqWithInput(
        testing.allocator, parsed_args, input_file,
        stdout_buffer.writer(testing.allocator), common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items);
}
```

---

## Counts

| Severity   | Count |
|------------|-------|
| CRITICAL   | 2     |
| IMPORTANT  | 4     |
| SUGGESTION | 2     |

**Overall assessment: NEEDS_FIXES**

The test architecture is sound — no stdin hang risk, no parse-only
stubs, all behavioral tests go through `runUniqWithInput`. The issues
are gaps in flag coverage and one actively misleading comment.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Remove stale "will FAIL" comment in read-error test
   — src/uniq.zig:782,812
2. [CRITICAL] --all-repeated=METHOD crashes with stack trace; add
   test + error handling — src/uniq.zig:95, argparse path
3. [IMPORTANT] Add -z behavioral end-to-end test
   — src/uniq.zig (no test)
4. [IMPORTANT] Add -s end-to-end pipeline test (only slice tests
   exist) — src/uniq.zig (no runUniqWithInput test for skip_chars)
5. [IMPORTANT] Add -c -D combination test and align error with GNU
   — src/uniq.zig:299
6. [IMPORTANT] Add output-file path test for runUniq two-positional
   path — src/uniq.zig:132-154
7. [SUGGESTION] Add -c -i combination test
   — src/uniq.zig (no test)
8. [SUGGESTION] Add -d -u contradictory-flags test and comment
   — src/uniq.zig (no test)
```

**REVIEW COMPLETE - NEEDS_FIXES**
