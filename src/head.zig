//! head - output the first part of files

const common = @import("common");
const std = @import("std");
const testing = std.testing;

/// Command-line arguments for the head utility
const HeadArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Number of lines to output (default: 10)
    lines: ?i64 = null,
    /// Number of bytes to output (overrides -n)
    bytes: ?u64 = null,
    /// Quiet flag - never print headers
    quiet: bool = false,
    /// Verbose flag - always print headers
    verbose: bool = false,
    /// Files to process
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .bytes = .{ .short = 'c', .desc = "Print the first NUM bytes of each file" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .lines = .{ .short = 'n', .desc = "Print the first NUM lines instead of the first 10" },
        .quiet = .{ .short = 'q', .desc = "Never print headers giving file names" },
        .verbose = .{ .short = 'v', .desc = "Always print headers giving file names" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Core head functionality accepting parsed arguments and writers.
/// Processes files or stdin according to the provided options.
pub fn runHead(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(HeadArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "head", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Create options struct
    const line_count = if (parsed_args.lines) |n| blk: {
        if (n < 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "head", "invalid number of lines", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
        break :blk @as(u64, @intCast(n));
    } else DEFAULT_LINE_COUNT;

    const options = HeadOptions{
        .line_count = line_count,
        .byte_count = parsed_args.bytes,
        .show_headers = if (parsed_args.quiet) false else if (parsed_args.verbose) true else parsed_args.positionals.len > 1,
    };

    const stdin = std.io.getStdIn().reader();

    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        try processInput(stdin, stdout_writer, options);
    } else {
        // Process each file in order
        for (parsed_args.positionals, 0..) |file_path, i| {
            if (i > 0 and options.show_headers) {
                try stdout_writer.writeAll("\n");
            }

            if (std.mem.eql(u8, file_path, "-")) {
                // "-" means read from stdin
                if (options.show_headers) {
                    try stdout_writer.writeAll("==> standard input <==\n");
                }
                try processInput(stdin, stdout_writer, options);
            } else {
                // Open and process regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "head", "{s}: {s}", .{ file_path, errorToMessage(err) });
                    return @intFromEnum(common.ExitCode.general_error);
                };
                defer file.close();

                if (options.show_headers) {
                    try stdout_writer.print("==> {s} <==\n", .{file_path});
                }
                try processInput(file.reader(), stdout_writer, options);
            }
        }
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Entry point for the head binary.
/// Sets up allocator, parses system arguments, and calls runHead.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runHead(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Print help message to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: head [OPTION]... [FILE]...
        \\Print the first 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes=[-]NUM       print the first NUM bytes of each file
        \\  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10
        \\  -q, --quiet, --silent    never print headers giving file names
        \\  -v, --verbose            always print headers giving file names
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\NUM may have a multiplier suffix:
        \\b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,
        \\GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("head ({s}) {s}\n", .{ common.name, common.version });
}

/// Options for head behavior
const HeadOptions = struct {
    /// Number of lines to output (ignored if byte_count is set)
    line_count: u64 = 10,
    /// Number of bytes to output (overrides line_count if set)
    byte_count: ?u64 = null,
    /// Whether to show file headers
    show_headers: bool = false,
};

/// Process input from a reader and output first lines/bytes to writer
pub fn processInput(reader: anytype, writer: anytype, options: HeadOptions) !void {
    if (options.byte_count) |byte_count| {
        // Process by bytes
        try processBytes(reader, writer, byte_count);
    } else {
        // Process by lines
        try processLines(reader, writer, options.line_count);
    }
}

/// Process input by lines
fn processLines(reader: anytype, writer: anytype, line_count: u64) !void {
    var buf_reader = std.io.bufferedReader(reader);
    var input = buf_reader.reader();

    var line_buf: [common.constants.LINE_BUFFER_SIZE]u8 = undefined;
    var lines_written: u64 = 0;

    while (lines_written < line_count) {
        const maybe_line = try input.readUntilDelimiterOrEof(&line_buf, '\n');
        if (maybe_line) |line| {
            try writer.writeAll(line);
            try writer.writeAll("\n");
            lines_written += 1;
        } else {
            // EOF reached
            break;
        }
    }
}

/// Process input by bytes
fn processBytes(reader: anytype, writer: anytype, byte_count: u64) !void {
    var buf_reader = std.io.bufferedReader(reader);
    var input = buf_reader.reader();

    var buffer: [common.constants.LINE_BUFFER_SIZE]u8 = undefined;
    var bytes_written: u64 = 0;

    while (bytes_written < byte_count) {
        const bytes_to_read = @min(buffer.len, byte_count - bytes_written);
        const bytes_read = try input.read(buffer[0..bytes_to_read]);
        if (bytes_read == 0) {
            // EOF reached
            break;
        }
        try writer.writeAll(buffer[0..bytes_read]);
        bytes_written += bytes_read;
    }
}

// ========== CONSTANTS ==========

/// Default number of lines to display when no -n option is provided
const DEFAULT_LINE_COUNT: u64 = 10;

// ========== ERROR HANDLING ==========

/// Convert error to user-friendly message
fn errorToMessage(err: anytype) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.IsDir => "Is a directory",
        else => @errorName(err),
    };
}

// ========== TEST CONSTANTS ==========

/// Test constants to replace magic numbers in tests
const TEST_BYTE_COUNT: u64 = 10;
const TEST_LARGE_BYTE_COUNT: u64 = 1000;
const TEST_LARGE_LINE_COUNT: u64 = 100;
const TEST_LINE_COUNT: u64 = 3;
const TEST_NEGATIVE_VALUE: []const u8 = "-5";
const TEST_SMALL_BYTE_COUNT: u64 = 5;
const TEST_ZERO_COUNT: u64 = 0;

// ========== TESTS ==========

test "head outputs first 10 lines by default" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{};
    try processInput(input_stream.reader(), buffer.writer(), options);

    const expected = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n";
    try testing.expectEqualStrings(expected, buffer.items);
}

test "head with -n 5 outputs first 5 lines" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .line_count = 5 };
    try processInput(input_stream.reader(), buffer.writer(), options);

    const expected = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try testing.expectEqualStrings(expected, buffer.items);
}

test "head with -c 10 outputs first 10 bytes" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "1234567890abcdefghij";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .byte_count = TEST_BYTE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("1234567890", buffer.items);
}

test "head handles fewer lines than requested" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "Line 1\nLine 2\nLine 3\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .line_count = DEFAULT_LINE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\n", buffer.items);
}

test "head handles fewer bytes than requested" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "12345";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .byte_count = TEST_BYTE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("12345", buffer.items);
}

test "head handles empty input" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{};
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "head with -n 0 outputs nothing" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "Line 1\nLine 2\nLine 3\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .line_count = TEST_ZERO_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "head with -c 0 outputs nothing" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "1234567890";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .byte_count = TEST_ZERO_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "head processes lines efficiently" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Create input with exactly the number of lines requested
    const input = "1\n2\n3\n4\n5\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .line_count = TEST_LINE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("1\n2\n3\n", buffer.items);
}

test "head processes bytes efficiently" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Create input larger than buffer size to test chunked reading
    var large_input = std.ArrayList(u8).init(testing.allocator);
    defer large_input.deinit();

    // Write 8KB of data
    var i: usize = 0;
    while (i < 8192) : (i += 1) {
        try large_input.append(@as(u8, @intCast(i % 256)));
    }

    var input_stream = std.io.fixedBufferStream(large_input.items);

    const options = HeadOptions{ .byte_count = TEST_LARGE_BYTE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqual(@as(usize, TEST_LARGE_BYTE_COUNT), buffer.items.len);
    // Verify first few bytes are correct
    try testing.expectEqual(@as(u8, 0), buffer.items[0]);
    try testing.expectEqual(@as(u8, 1), buffer.items[1]);
    try testing.expectEqual(@as(u8, 255), buffer.items[255]);
}

test "head handles invalid line count" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", TEST_NEGATIVE_VALUE };
    const result = try runHead(testing.allocator, &args, buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 1), result);
}

test "head help flag works" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runHead(testing.allocator, &args, buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: head") != null);
}

test "head version flag works" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runHead(testing.allocator, &args, buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "head") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.version) != null);
}

test "head with line count larger than available lines" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "Only\nTwo\nLines\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .line_count = TEST_LARGE_LINE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("Only\nTwo\nLines\n", buffer.items);
}

test "head byte count takes precedence over line count" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const input = "Line 1\nLine 2\nLine 3\n";
    var input_stream = std.io.fixedBufferStream(input);

    const options = HeadOptions{ .line_count = DEFAULT_LINE_COUNT, .byte_count = TEST_SMALL_BYTE_COUNT };
    try processInput(input_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("Line ", buffer.items);
}
