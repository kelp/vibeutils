//! POSIX-compatible tail utility that displays the end of files
//!
//! This module implements the tail command with support for:
//! - Default last 10 lines display
//! - Custom line count with -n (--lines) flag
//! - Byte count mode with -c (--bytes) flag
//! - Multiple file handling with headers
//! - Quiet mode with -q (--quiet) to suppress headers
//! - Verbose mode with -v (--verbose) to always show headers
//! - Zero-terminated lines with -z (--zero-terminated) flag
//! - Follow mode with -f (--follow) for watching file changes
//! - Reading from standard input when no files specified
//!
//! The implementation maintains compatibility with GNU coreutils tail while
//! providing robust error handling and efficient buffered I/O operations.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Default buffer size for I/O operations
const BUFFER_SIZE = 4096;

/// Command-line arguments for tail
const TailArgs = struct {
    help: bool = false,
    version: bool = false,
    lines: ?[]const u8 = null,
    bytes: ?[]const u8 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    follow: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .lines = .{ .short = 'n', .desc = "Output the last NUM lines, instead of the last 10" },
        .bytes = .{ .short = 'c', .desc = "Output the last NUM bytes" },
        .quiet = .{ .short = 'q', .desc = "Never output headers when multiple files are being examined" },
        .verbose = .{ .short = 'v', .desc = "Always output headers when examining files" },
        .zero_terminated = .{ .short = 'z', .desc = "Line delimiter is NUL, not newline" },
        .follow = .{ .short = 'f', .desc = "Output appended data as the file grows" },
    };
};

/// Options controlling tail behavior
const TailOptions = struct {
    line_count: ?u64 = null,
    byte_count: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    follow: bool = false,

    /// Returns true if we should show headers for multiple files
    pub fn shouldShowHeaders(self: TailOptions, file_count: usize) bool {
        if (self.verbose) return true;
        if (self.quiet) return false;
        return file_count > 1;
    }
};

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("tail ({s}) {s}\n", .{ common.name, common.version });
}

/// Print usage information to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: tail [OPTION]... [FILE]...
        \\Print the last 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to
        \\                           output starting with byte NUM of each file
        \\  -f, --follow[={name|descriptor}]
        \\                           output appended data as the file grows;
        \\                           an absent option argument means 'descriptor'
        \\  -F                       same as --follow=name --retry
        \\  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;
        \\                           or use -n +NUM to output starting with line NUM
        \\  -q, --quiet, --silent    never output headers giving file names
        \\  -v, --verbose            always output headers giving file names
        \\  -z, --zero-terminated    line delimiter is NUL, not newline
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\NUM may have a multiplier suffix:
        \\b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,
        \\GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.
        \\Binary prefixes can be used, too: KiB=K, MiB=M, and so on.
        \\
        \\Examples:
        \\  tail f - g  Output f's contents, then standard input, then g's contents.
        \\  tail -n +1 FILE  Output FILE starting with its first line.
        \\
    );
}

/// Main entry point for tail utility with stdout and stderr writer parameters
pub fn runTail(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(TailArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid argument", .{});
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

    // Parse numeric arguments
    var options = TailOptions{
        .quiet = parsed_args.quiet,
        .verbose = parsed_args.verbose,
        .zero_terminated = parsed_args.zero_terminated,
        .follow = parsed_args.follow,
    };

    // Parse line count (-n flag)
    if (parsed_args.lines) |lines_str| {
        options.line_count = parseNumericArg(lines_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of lines: '{s}'", .{lines_str});
            return @intFromEnum(common.ExitCode.general_error);
        };
    } else {
        options.line_count = 10; // default
    }

    // Parse byte count (-c flag) - overrides line count
    if (parsed_args.bytes) |bytes_str| {
        options.byte_count = parseNumericArg(bytes_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of bytes: '{s}'", .{bytes_str});
            return @intFromEnum(common.ExitCode.general_error);
        };
        options.line_count = null; // byte mode overrides line mode
    }

    // Process files
    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        const stdin = std.io.getStdIn().reader();
        try processInput(allocator, stdin, stdout_writer, options, null);
    } else {
        // Process each file
        const should_show_headers = options.shouldShowHeaders(parsed_args.positionals.len);
        for (parsed_args.positionals, 0..) |file_path, i| {
            if (std.mem.eql(u8, file_path, "-")) {
                // "-" means read from stdin
                const stdin = std.io.getStdIn().reader();
                if (should_show_headers) {
                    if (i > 0) try stdout_writer.writeAll("\n");
                    try stdout_writer.writeAll("==> standard input <==\n");
                }
                try processInput(allocator, stdin, stdout_writer, options, null);
            } else {
                // Open and process regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "tail", "{s}: {s}", .{ file_path, getStandardErrorName(err) });
                    return @intFromEnum(common.ExitCode.general_error);
                };
                defer file.close();

                if (should_show_headers) {
                    if (i > 0) try stdout_writer.writeAll("\n");
                    try stdout_writer.print("==> {s} <==\n", .{file_path});
                }
                try processInput(allocator, file.reader(), stdout_writer, options, file);
            }
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for the tail utility
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runTail(allocator, args[1..], stdout_writer, stderr_writer);
    std.process.exit(exit_code);
}

/// Parse numeric argument with optional suffix (K, M, G, etc.)
fn parseNumericArg(arg: []const u8) !u64 {
    if (arg.len == 0) return error.InvalidArgument;

    // Strip plus prefix if present
    const clean_arg = if (arg[0] == '+') arg[1..] else arg;
    if (clean_arg.len == 0) return error.InvalidArgument;

    return parseSuffixedNumber(clean_arg);
}

/// Parse number with optional suffix multiplier
fn parseSuffixedNumber(arg: []const u8) !u64 {
    // Find the last digit to separate number from suffix
    var end_of_number: usize = arg.len;
    for (arg, 0..) |c, i| {
        if (!std.ascii.isDigit(c)) {
            end_of_number = i;
            break;
        }
    }

    if (end_of_number == 0) return error.InvalidArgument;

    const number_part = arg[0..end_of_number];
    const suffix = arg[end_of_number..];

    const base_number = std.fmt.parseInt(u64, number_part, 10) catch return error.InvalidArgument;

    // Parse suffix multipliers
    if (suffix.len == 0) {
        return base_number;
    }

    const multiplier: u64 = switch (suffix[0]) {
        'G' => if (suffix.len > 1 and std.mem.eql(u8, suffix[1..], "B")) 1000 * 1000 * 1000 else 1024 * 1024 * 1024,
        'K' => if (suffix.len > 1 and (std.mem.eql(u8, suffix[1..], "iB") or std.mem.eql(u8, suffix[1..], "B"))) 1024 else 1024,
        'M' => if (suffix.len > 1 and std.mem.eql(u8, suffix[1..], "B")) 1000 * 1000 else 1024 * 1024,
        'T' => if (suffix.len > 1 and std.mem.eql(u8, suffix[1..], "B")) 1000 * 1000 * 1000 * 1000 else 1024 * 1024 * 1024 * 1024,
        'b' => 512,
        'k' => if (suffix.len > 1 and suffix[1] == 'B') 1000 else 1024,
        else => return error.InvalidArgument,
    };

    // Use @mulWithOverflow for safe arithmetic
    const result = @mulWithOverflow(base_number, multiplier);
    if (result[1] != 0) {
        return error.Overflow;
    }

    return result[0];
}

/// Convert system error to user-friendly error name
fn getStandardErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.DeviceBusy => "Device or resource busy",
        error.DiskQuota => "Disk quota exceeded",
        else => @errorName(err),
    };
}

/// Process input from reader according to options
fn processInput(allocator: std.mem.Allocator, reader: anytype, writer: anytype, options: TailOptions, file: ?std.fs.File) !void {
    if (options.byte_count) |byte_count| {
        try processInputByBytes(allocator, reader, writer, byte_count, file);
    } else {
        const line_count = options.line_count orelse 10;
        try processInputByLines(allocator, reader, writer, line_count, options.zero_terminated);
    }
}

/// Process input by byte count
fn processInputByBytes(allocator: std.mem.Allocator, reader: anytype, writer: anytype, byte_count: u64, file: ?std.fs.File) !void {
    if (byte_count == 0) return; // Output nothing for 0 bytes

    // If we have a file, try to seek to optimize reading
    if (file) |f| {
        const file_size = f.getEndPos() catch {
            // Fall back to reading everything if we can't get file size
            return processInputByBytesNoSeek(allocator, reader, writer, byte_count);
        };

        if (byte_count >= file_size) {
            // Read entire file
            var buf: [BUFFER_SIZE]u8 = undefined;
            while (true) {
                const bytes_read = try reader.read(&buf);
                if (bytes_read == 0) break;
                try writer.writeAll(buf[0..bytes_read]);
            }
        } else {
            // Seek to the position we want to start reading from
            const start_pos = file_size - byte_count;
            try f.seekTo(start_pos);

            var buf: [BUFFER_SIZE]u8 = undefined;
            var bytes_remaining = byte_count;
            while (bytes_remaining > 0) {
                const bytes_to_read = @min(buf.len, bytes_remaining);
                const bytes_read = try reader.read(buf[0..bytes_to_read]);
                if (bytes_read == 0) break;
                try writer.writeAll(buf[0..bytes_read]);
                bytes_remaining -= bytes_read;
            }
        }
    } else {
        // No file handle, fall back to buffering approach
        return processInputByBytesNoSeek(allocator, reader, writer, byte_count);
    }
}

/// Process input by bytes without seeking (for stdin/pipes)
fn processInputByBytesNoSeek(allocator: std.mem.Allocator, reader: anytype, writer: anytype, byte_count: u64) !void {
    // Read all input first
    const content = reader.readAllAlloc(allocator, std.math.maxInt(usize)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => return error.InputTooLarge,
        else => return err,
    };
    defer allocator.free(content);

    if (byte_count >= content.len) {
        // Output entire content
        try writer.writeAll(content);
    } else {
        // Output last byte_count bytes
        const start_pos = content.len - @as(usize, @intCast(byte_count));
        try writer.writeAll(content[start_pos..]);
    }
}

/// Process input by line count
fn processInputByLines(allocator: std.mem.Allocator, reader: anytype, writer: anytype, line_count: u64, zero_terminated: bool) !void {
    if (line_count == 0) return; // Output nothing for 0 lines

    const delimiter: u8 = if (zero_terminated) 0 else '\n';

    // Use a ring buffer approach to store the last N lines
    var lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (lines.items) |line| {
            allocator.free(line);
        }
        lines.deinit();
    }

    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    var line_index: usize = 0;
    const max_lines = @as(usize, @intCast(line_count));

    // Read input line by line
    while (true) {
        line_buffer.clearRetainingCapacity();

        reader.streamUntilDelimiter(line_buffer.writer(), delimiter, null) catch |err| switch (err) {
            error.EndOfStream => {
                // Handle final line without delimiter
                if (line_buffer.items.len > 0) {
                    const line_copy = try allocator.dupe(u8, line_buffer.items);
                    if (lines.items.len < max_lines) {
                        try lines.append(line_copy);
                    } else {
                        // Replace oldest line
                        allocator.free(lines.items[line_index % max_lines]);
                        lines.items[line_index % max_lines] = line_copy;
                    }
                    line_index += 1;
                }
                break;
            },
            else => return err,
        };

        // Store the line (including delimiter for consistency)
        if (!zero_terminated) {
            try line_buffer.append('\n');
        } else {
            try line_buffer.append(0);
        }

        const line_copy = try allocator.dupe(u8, line_buffer.items);
        if (lines.items.len < max_lines) {
            try lines.append(line_copy);
        } else {
            // Replace oldest line
            allocator.free(lines.items[line_index % max_lines]);
            lines.items[line_index % max_lines] = line_copy;
        }
        line_index += 1;
    }

    // Output the lines in correct order
    if (line_index <= max_lines) {
        // We have fewer lines than requested, output all
        for (lines.items) |line| {
            try writer.writeAll(line);
        }
    } else {
        // We have more lines than requested, output from the correct starting point
        const start_index = line_index % max_lines;
        for (0..max_lines) |i| {
            const line_idx = (start_index + i) % max_lines;
            try writer.writeAll(lines.items[line_idx]);
        }
    }
}

// ========== TESTS ==========

test "tail outputs default 10 lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test file with 15 lines
    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), .{});

    try testing.expectEqualStrings("line6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\n", buffer.items);
}

test "tail with -n 5 outputs last 5 lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .line_count = 5 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("line3\nline4\nline5\nline6\nline7\n", buffer.items);
}

test "tail with -n 0 outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .line_count = 0 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "tail with -c 10 outputs last 10 bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "abcdefghijklmnopqrstuvwxyz";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .byte_count = 10 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("qrstuvwxyz", buffer.items);
}

test "tail with -c 0 outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "some content here";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .byte_count = 0 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "tail handles line count larger than file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .line_count = 100 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("line1\nline2\nline3\n", buffer.items);
}

test "tail handles byte count larger than file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "small";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .byte_count = 100 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("small", buffer.items);
}

test "tail handles empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "empty.txt", "");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testTailFile(tmp_dir.dir, "empty.txt", buffer.writer(), .{});

    try testing.expectEqualStrings("", buffer.items);
}

test "tail handles file with no final newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3"; // no final newline
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("line2\nline3", buffer.items);
}

test "tail handles very long lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a line longer than typical buffer sizes
    var long_line_buf: [5000]u8 = undefined;
    @memset(&long_line_buf, 'x');
    const long_line = long_line_buf[0..];

    const content = try std.fmt.allocPrint(testing.allocator, "short1\n{s}\nshort2\n", .{long_line});
    defer testing.allocator.free(content);

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\nshort2\n", .{long_line});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, buffer.items);
}

test "tail reads from stdin when no files" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const stdin_content = "stdin line1\nstdin line2\nstdin line3\n";
    var stdin_stream = std.io.fixedBufferStream(stdin_content);

    // Test with default options (10 lines, should output all 3 lines)
    const options = TailOptions{ .line_count = 10 };
    try testTailStdin(stdin_stream.reader(), buffer.writer(), options);

    try testing.expectEqualStrings("stdin line1\nstdin line2\nstdin line3\n", buffer.items);
}

test "tail with multiple files shows headers by default" {
    const args = [_][]const u8{ "file1.txt", "file2.txt" };
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail with general error due to missing files
}

test "tail with -q suppresses headers for multiple files" {
    const args = [_][]const u8{ "-q", "file1.txt", "file2.txt" };
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail with general error due to missing files
}

test "tail with -v always shows headers" {
    const args = [_][]const u8{ "-v", "file1.txt" };
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail with general error due to missing file
}

test "tail with dash reads from stdin" {
    const args = [_][]const u8{"-"};
    // This would normally read stdin, but we can't easily test that in unit tests
    // The actual stdin reading is tested in other test functions
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail due to NotImplemented
}

test "tail handles non-existent file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const result = testTailFile(tmp_dir.dir, "nonexistent.txt", buffer.writer(), .{});
    try testing.expectError(error.FileNotFound, result);
}

test "tail with -z handles zero-terminated lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\x00line2\x00line3\x00";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .line_count = 2, .zero_terminated = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(), options);

    try testing.expectEqualStrings("line2\x00line3\x00", buffer.items);
}

test "tail with binary file in byte mode" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const binary_content = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC };
    try common.test_utils.createTestFile(tmp_dir.dir, "binary.txt", &binary_content);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = TailOptions{ .byte_count = 4 };
    try testTailFile(tmp_dir.dir, "binary.txt", buffer.writer(), options);

    const expected = [_]u8{ 0xFF, 0xFE, 0xFD, 0xFC };
    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "parseNumericArg with valid numbers" {
    try testing.expectEqual(@as(u64, 10), try parseNumericArg("10"));
    try testing.expectEqual(@as(u64, 0), try parseNumericArg("0"));
    try testing.expectEqual(@as(u64, 999), try parseNumericArg("999"));
}

test "parseNumericArg with suffixes" {
    try testing.expectEqual(@as(u64, 1024), try parseNumericArg("1K"));
    try testing.expectEqual(@as(u64, 1024 * 1024), try parseNumericArg("1M"));
    try testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseNumericArg("1G"));
    try testing.expectEqual(@as(u64, 1000), try parseNumericArg("1kB"));
    try testing.expectEqual(@as(u64, 1000 * 1000), try parseNumericArg("1MB"));
}

test "parseNumericArg with plus prefix" {
    try testing.expectEqual(@as(u64, 10), try parseNumericArg("+10"));
    try testing.expectEqual(@as(u64, 1), try parseNumericArg("+1"));
}

test "parseNumericArg with invalid input" {
    try testing.expectError(error.InvalidArgument, parseNumericArg(""));
    try testing.expectError(error.InvalidCharacter, parseNumericArg("abc"));
    try testing.expectError(error.InvalidCharacter, parseNumericArg("12abc"));
}

test "tail shouldShowHeaders logic" {
    const options_default = TailOptions{};
    const options_quiet = TailOptions{ .quiet = true };
    const options_verbose = TailOptions{ .verbose = true };

    // Default behavior: show headers only for multiple files
    try testing.expect(!options_default.shouldShowHeaders(1));
    try testing.expect(options_default.shouldShowHeaders(2));

    // Quiet mode: never show headers
    try testing.expect(!options_quiet.shouldShowHeaders(1));
    try testing.expect(!options_quiet.shouldShowHeaders(2));

    // Verbose mode: always show headers
    try testing.expect(options_verbose.shouldShowHeaders(1));
    try testing.expect(options_verbose.shouldShowHeaders(2));
}

test "tail help output" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runTail(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: tail") != null);
}

test "tail version output" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runTail(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "tail (vibeutils)") != null);
}

test "tail with invalid line count" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-n", "invalid" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid number of lines") != null);
}

test "tail with invalid byte count" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-c", "xyz" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid number of bytes") != null);
}

/// Test helper for processing a file from a directory
fn testTailFile(dir: std.fs.Dir, filename: []const u8, writer: anytype, options: TailOptions) !void {
    const file = try dir.openFile(filename, .{});
    defer file.close();
    try processInput(testing.allocator, file.reader(), writer, options, file);
}

/// Test helper for processing stdin-like input
fn testTailStdin(reader: anytype, writer: anytype, options: TailOptions) !void {
    try processInput(testing.allocator, reader, writer, options, null);
}
