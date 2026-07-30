# New Utility Template

Replace `<UTILITY>` with the utility name (e.g., `sort`),
`<Utility>` with PascalCase (e.g., `Sort`).

## Standard Utility Template

```zig
//! <UTILITY> - one-line description

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Command-line arguments for the <UTILITY> utility
const <Utility>Args = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    // Add flags here
    /// Positional arguments
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        // Add flag metadata here
    };
};

/// Core <UTILITY> functionality.
pub fn run<Utility>(
    allocator: Allocator,
    args: []const []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    const parsed = common.argparse.ArgParser.parse(
        <Utility>Args,
        allocator,
        args,
    ) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "<UTILITY>",
                    "invalid argument",
                    .{},
                );
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Implementation here

    return @intFromEnum(common.ExitCode.success);
}

/// Entry point for the <UTILITY> binary.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try run<Utility>(
        allocator,
        args[1..],
        stdout,
        stderr,
    );

    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(exit_code);
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: <UTILITY> [OPTION]... [ARG]...
        \\One-line description.
        \\
        \\  -h, --help      display this help and exit
        \\  -V, --version   output version information and exit
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("<UTILITY> ({s}) {s}\n", .{
        common.name,
        common.version,
    });
}

// === Tests ===

test "<UTILITY>: help flag" {
    const allocator = testing.allocator;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run<Utility>(
        allocator,
        &.{"--help"},
        stdout_writer.writer(),
        stderr_writer.writer(),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    const output = stdout_buf[0..stdout_writer.pos];
    try testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
}

test "<UTILITY>: version flag" {
    const allocator = testing.allocator;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run<Utility>(
        allocator,
        &.{"--version"},
        stdout_writer.writer(),
        stderr_writer.writer(),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    const output = stdout_buf[0..stdout_writer.pos];
    try testing.expect(std.mem.indexOf(u8, output, common.name) != null);
}
```

## Filter Utility Template (reads stdin)

Add this pattern for utilities that read from stdin (cat, sort,
uniq, tr, cut, nl, tac, head, tail, wc, tee):

```zig
/// Core functionality with explicit input source.
/// Used by both main (stdin) and tests (file/buffer).
fn run<Utility>WithInput(
    allocator: Allocator,
    args: []const []const u8,
    input_file: std.fs.File,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // Parse args, then read input:
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = input_file.reader(&stdin_buffer);
    const reader = &stdin_reader.interface;

    var content_list = std.ArrayListUnmanaged(u8){};
    defer content_list.deinit(allocator);
    reader.appendRemaining(allocator, &content_list, .{ .max = 1 << 30 }) catch |err| {
        return err;
    };
    const content = content_list.items;

    // Process content...
    _ = content;
    return @intFromEnum(common.ExitCode.success);
}

/// Public entry: reads from stdin.
pub fn run<Utility>(
    allocator: Allocator,
    args: []const []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    return run<Utility>WithInput(
        allocator,
        args,
        std.fs.File.stdin(),
        stdout_writer,
        stderr_writer,
    );
}
```

Test filter utilities with a temp file instead of stdin:

```zig
test "<UTILITY>: basic filter" {
    const allocator = testing.allocator;

    // Write test input to a temp file
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = try tmp_dir.dir.createFile("input.txt", .{});
    try tmp_file.writeAll("line1\nline2\nline3\n");
    try tmp_file.seekTo(0);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run<Utility>WithInput(
        allocator,
        &.{},
        tmp_file,
        stdout_writer.writer(),
        stderr_writer.writer(),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}
```

## build/utils.zig Entry

Add to the `utilities` array:

```zig
.{ .name = "<UTILITY>", .path = "src/<UTILITY>.zig",
   .needs_libc = true, .description = "<One-line description>" },
```

## Man Page Skeleton (man/man1/<UTILITY>.1)

```mdoc
.\" vibeutils <UTILITY> man page
.Dd $Mdocdate$
.Dt <UTILITY_UPPER> 1
.Os
.Sh NAME
.Nm <UTILITY>
.Nd one-line description
.Sh SYNOPSIS
.Nm <UTILITY>
.Op Fl hV
.Op Ar file ...
.Sh DESCRIPTION
Description of the utility.
.Pp
The options are as follows:
.Bl -tag -width Ds
.It Fl h , Fl Fl help
Display help and exit.
.It Fl V , Fl Fl version
Output version information and exit.
.El
.Sh EXIT STATUS
.Ex -std <UTILITY>
.Sh EXAMPLES
.Bd -literal -offset indent
$ <UTILITY> file.txt
output here
.Ed
.Sh SEE ALSO
.Xr related 1
.Sh STANDARDS
The
.Nm
utility conforms to
.St -p1003.1-2008 .
.Sh AUTHORS
.An vibeutils implementation by Travis Cole
```
