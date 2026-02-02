---
description: Zig 0.15.x correct patterns for vibeutils
model-invocation: true
---

# Zig 0.15.x Patterns -- Quick Reference

Your Zig training is outdated. These are the CORRECT patterns.

## I/O: Buffered Writers (Writergate)

```zig
// main() setup
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
defer stdout.flush() catch {};

// stdin reader
var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;

// File reader
var file_buffer: [4096]u8 = undefined;
var file_reader = file.reader(&file_buffer);
const reader = &file_reader.interface;
```

WRONG: `std.io.getStdOut()`, `std.io.getStdErr()` -- deleted.
ALWAYS `defer flush() catch {}` before buffer goes out of scope.

## Reading Input: appendRemaining (NOT takeDelimiterExclusive)

```zig
// CORRECT: read all input at once
var content_list = std.ArrayListUnmanaged(u8){};
defer content_list.deinit(allocator);
reader.appendRemaining(allocator, &content_list, .{ .max = 1 << 30 }) catch |err| {
    return err;
};
const content = content_list.items;
```

WRONG: `while (reader.takeDelimiterExclusive('\n'))` in a loop.
That pattern hangs on stdin in unit tests.

## ArrayList: Allocator on Every Call

```zig
var list = std.ArrayListUnmanaged(u8){};
defer list.deinit(allocator);
try list.append(allocator, value);
try list.appendSlice(allocator, slice);
```

WRONG: `list.append(value)` without allocator.

## Format Strings: Explicit Specifiers

```zig
try writer.print("{s}: {d} bytes\n", .{ name, count });
```

WRONG: `"{}"` -- must use `{s}`, `{d}`, `{any}`, etc.

## Division: Runtime Signed Ints

```zig
const result = @divTrunc(a, b);   // truncate toward zero
const result = @divFloor(a, b);   // round toward negative infinity
```

WRONG: `a / b` on runtime signed integers.

## Exit Codes

```zig
return @intFromEnum(common.ExitCode.success);       // 0
return @intFromEnum(common.ExitCode.general_error);  // 1
return @intFromEnum(common.ExitCode.misuse);          // 2
```

Use `misuse` (2) for argument errors (UnknownFlag, MissingValue,
InvalidValue). Use `general_error` (1) for runtime failures.

## Error Messages

```zig
common.printErrorWithProgram(
    allocator, stderr_writer, "utility_name",
    "{s}: {s}", .{ path, error_msg },
);
```

## runUtil Signature

```zig
pub fn runUtil(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
```

## Testing

- Use `testing.allocator` for standard tests (detects leaks)
- Use `privilege_test.TestArena` for privileged tests (fakeroot)
- Prefix privileged test names with `"privileged: "`
- Filter utilities: skip stdin-dependent unit tests, use
  `runUtilWithInput()` or binary smoke tests
- Buffer size: 8192 consistently

## Argument Parsing

```zig
const Args = struct {
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

const parsed = common.argparse.ArgParser.parse(Args, allocator, args) catch |err| {
    switch (err) {
        error.UnknownFlag, error.MissingValue, error.InvalidValue => {
            common.printErrorWithProgram(allocator, stderr_writer, "name", "invalid argument", .{});
            return @intFromEnum(common.ExitCode.misuse);
        },
        else => return err,
    }
};
defer allocator.free(parsed.positionals);
```

## Security: Trust the OS

NO path validation, no "../" checks, no "protected" file lists.
Let the OS kernel handle permissions. Only validate for
correctness (same-file detection, buffer overflows, atomics).
