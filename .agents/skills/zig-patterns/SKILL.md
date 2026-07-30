---
description: Zig 0.16.0 correct patterns for vibeutils
model-invocation: true
---

# Zig 0.16.0 Patterns -- Quick Reference

Your Zig training is outdated. These are the CORRECT patterns
for the 0.16.0 stdlib (post-Writergate, post-I/O-as-an-Interface).
Full migration catalog in `docs/ZIG_BREAKING_CHANGES.md`.

## I/O: Buffered Writers (writerStreaming, NOT writer)

```zig
pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer =
        std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer =
        std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};
}
```

WRONG: `std.fs.File.stdout()` -- namespace moved to `std.Io.File`.
WRONG: `.writer(io, &buf)` -- positional mode ignores O_APPEND,
       breaks shell `>>` on macOS. Use `writerStreaming`.
ALWAYS `defer flush() catch {}` before buffer goes out of scope.

## Reading Input (file reader, stdin reader)

```zig
// stdin (filter utilities)
var stdin_buffer: [8192]u8 = undefined;
var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
const stdin = &stdin_reader.interface;

// file reader
var file_buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &file_buffer);
const reader = &file_reader.interface;
```

For read-all-at-once, use `appendRemaining`:

```zig
var content_list: std.ArrayListUnmanaged(u8) = .empty;
defer content_list.deinit(allocator);
try reader.appendRemaining(allocator, &content_list, .{ .max = 1 << 30 });
const content = content_list.items;
```

WRONG: `while (reader.takeDelimiterExclusive('\n'))` in a loop --
hangs on stdin in unit tests.

## "Juicy Main" Entry Point

```zig
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runUtil);
}

// or, for utilities that need to return errors directly:
pub fn main(init: std.process.Init) !void {
    // ... manual setup ...
}
```

The `init` parameter exposes: `gpa`, `io`, `arena`, `environ_map`,
`preopens`, plus `init.minimal.{args, environ}`.

WRONG: `pub fn main() !void` -- can't access args or env.

## runUtil Signature

```zig
pub fn runUtil(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    return @intFromEnum(common.ExitCode.success);
}
```

WRONG: `anytype` writers -- use `*std.Io.Writer` concretely.
WRONG: missing `io: std.Io` parameter.

## Filesystem APIs

```zig
const dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
try file.close(io);
try dir.createDir(io, "name");
try dir.createDirPath(io, "a/b/c");
try file.setPermissions(io, perms);
const len = try file.length(io);
```

WRONG: `std.fs.cwd()` -- moved to `std.Io.Dir.cwd()`.
WRONG: `file.close()` -- must pass `io`.
WRONG: `dir.makeDir` / `dir.makePath` -- renamed `createDir` /
       `createDirPath`.

## ArrayList: `.empty` Init, Allocator on Every Call

```zig
var list: std.ArrayListUnmanaged(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, value);
try list.appendSlice(allocator, slice);
```

WRONG: `std.ArrayList(u8).init(allocator)` -- managed variant gone.
WRONG: `list.append(value)` without allocator.

## FixedBufferStream is Gone

```zig
var reader: std.Io.Reader = .fixed(data);
var writer: std.Io.Writer = .fixed(buffer);
```

WRONG: `std.io.fixedBufferStream(data)` -- removed.

## Format Strings: Explicit Specifiers

```zig
try writer.print("{s}: {d} bytes\n", .{ name, count });
```

WRONG: `"{}"` -- must use `{s}`, `{d}`, `{any}`, etc.

## Division: Runtime Signed Ints

```zig
const result = @divTrunc(a, b);   // truncate toward zero
const result = @divFloor(a, b);   // round toward negative infinity
const result = @divExact(a, b);   // assert evenly divisible
```

WRONG: `a / b` on runtime signed integers.

## Exit Codes

```zig
return @intFromEnum(common.ExitCode.success);       // 0
return @intFromEnum(common.ExitCode.general_error); // 1
return @intFromEnum(common.ExitCode.misuse);        // 2
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

## Environment Variables (Non-Global in 0.16)

```zig
// Public entry takes init.environ_map and plumbs it down.
pub fn main(init: std.process.Init) !void {
    _ = try runEnv(init.gpa, init.io, args, init.environ_map, ...);
}
```

WRONG: `std.os.environ` -- gone. WRONG: `std.posix.getenv` --
gone. WRONG: `std.posix.setenv` C-extern workarounds -- obsolete.
Plumb `init.environ_map` as a parameter; see `src/env.zig`.

## Args

```zig
const args = try init.minimal.args.toSlice(init.arena.allocator());
```

WRONG: `std.process.argsAlloc(allocator)` -- removed.

## Testing

- Use `std.testing.allocator` for standard tests (detects leaks)
- Use `std.testing.io` wherever you'd normally pass `io`
- Use `privilege_test.TestArena` for privileged tests (fakeroot)
- Prefix privileged test names with `"privileged: "`
- Filter utilities: use `std.Io.Reader.fixed(input)` to inject
  test input into a `runUtilWithInput`-style helper
- Buffer size: 8192 consistently

```zig
test "demo" {
    const io = std.testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    _ = try runUtil(testing.allocator, io, &.{}, &stdout_aw.writer, common.null_writer);
    try testing.expectEqualStrings("expected\n", stdout_aw.writer.buffered());
}
```

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

const parsed = common.argparse.ArgParser.parseOrExit(
    Args, allocator, args, "name", stderr_writer,
) catch return @intFromEnum(common.ExitCode.misuse);
defer allocator.free(parsed.positionals);
```

## Security: Trust the OS

NO path validation, no "../" checks, no "protected" file lists.
Let the OS kernel handle permissions. Only validate for
correctness (same-file detection, buffer overflows, atomics).
