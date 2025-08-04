//! POSIX-compatible cat utility for concatenating and displaying files
//!
//! This module implements the cat command with full support for:
//! - Reading from multiple files or standard input
//! - Line numbering with -n (all lines) and -b (non-blank lines only)
//! - Blank line squeezing with -s
//! - Special character visualization with -T (tabs), -E (line ends), -v (non-printing)
//! - Combined flag shortcuts: -A (-vET), -e (-vE), -t (-vT)
//! - Proper handling of binary data and control characters
//!
//! The implementation maintains compatibility with GNU coreutils cat while
//! providing robust error handling and efficient buffered I/O operations.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// ASCII DEL character (0x7F)
const ASCII_DEL = 127;

/// Command-line arguments for cat
const CatArgs = struct {
    help: bool = false,
    version: bool = false,
    show_all: bool = false,
    number_nonblank: bool = false,
    e: bool = false,
    show_ends: bool = false,
    number: bool = false,
    squeeze_blank: bool = false,
    t: bool = false,
    show_tabs: bool = false,
    u: bool = false,
    show_nonprinting: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .show_all = .{ .short = 'A', .desc = "Equivalent to -vET" },
        .number_nonblank = .{ .short = 'b', .desc = "Number non-empty output lines, overrides -n" },
        .e = .{ .short = 'e', .desc = "Equivalent to -vE" },
        .show_ends = .{ .short = 'E', .desc = "Display $ at end of each line" },
        .number = .{ .short = 'n', .desc = "Number all output lines" },
        .squeeze_blank = .{ .short = 's', .desc = "Suppress repeated empty output lines" },
        .t = .{ .short = 't', .desc = "Equivalent to -vT" },
        .show_tabs = .{ .short = 'T', .desc = "Display TAB characters as ^I" },
        .u = .{ .short = 'u', .desc = "(ignored)" },
        .show_nonprinting = .{ .short = 'v', .desc = "Use ^ and M- notation, except for LFD and TAB" },
    };
};

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("cat ({s}) {s}\n", .{ common.name, common.version });
}

/// Main entry point for cat utility with stdout and stderr writer parameters
/// Standardized entry point for cat utility
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    return runCat(allocator, args, stdout_writer, stderr_writer);
}

pub fn runCat(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(CatArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "cat", "invalid argument", .{});
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

    // Create options struct with proper flag combinations
    // -A is equivalent to -vET, -e is equivalent to -vE, -t is equivalent to -vT
    const options = CatOptions{
        .number_lines = parsed_args.number,
        .number_nonblank = parsed_args.number_nonblank,
        .squeeze_blank = parsed_args.squeeze_blank,
        .show_ends = parsed_args.show_ends or parsed_args.show_all or parsed_args.e,
        .show_tabs = parsed_args.show_tabs or parsed_args.show_all or parsed_args.t,
        .show_nonprinting = parsed_args.show_nonprinting or parsed_args.show_all or parsed_args.e or parsed_args.t,
    };

    const stdin = std.io.getStdIn().reader();

    var line_state = LineNumberState{};

    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        try processInput(stdin, stdout_writer, options, &line_state);
    } else {
        // Process each file in order
        for (parsed_args.positionals) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                // "-" means read from stdin
                try processInput(stdin, stdout_writer, options, &line_state);
            } else {
                // Open and process regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cat", "{s}: {s}", .{ file_path, @errorName(err) });
                    return @intFromEnum(common.ExitCode.general_error);
                };
                defer file.close();
                try processInput(file.reader(), stdout_writer, options, &line_state);
            }
        }
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Process files or stdin with the specified formatting options
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runCat(allocator, args[1..], stdout_writer, stderr_writer);
    std.process.exit(exit_code);
}

/// Print usage information to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: cat [OPTION]... [FILE]...
        \\Concatenate FILE(s) to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -A, --show-all           equivalent to -vET
        \\  -b, --number-nonblank    number nonempty output lines, overrides -n
        \\  -e                       equivalent to -vE
        \\  -E, --show-ends          display $ at end of each line
        \\  -n, --number             number all output lines
        \\  -s, --squeeze-blank      suppress repeated empty output lines
        \\  -t                       equivalent to -vT
        \\  -T, --show-tabs          display TAB characters as ^I
        \\  -u                       (ignored)
        \\  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Examples:
        \\  cat f - g  Output f's contents, then standard input, then g's contents.
        \\  cat        Copy standard input to standard output.
        \\
    );
}

/// Options controlling output formatting
const CatOptions = struct {
    number_lines: bool = false,
    number_nonblank: bool = false,
    squeeze_blank: bool = false,
    show_ends: bool = false,
    show_tabs: bool = false,
    show_nonprinting: bool = false,
};

/// Line numbering state maintained across multiple files
const LineNumberState = struct {
    line_number: usize = 1,
    prev_blank: bool = false,
};

/// Format output according to the specified options.
/// Maintains line numbering state across multiple files.
pub fn processInput(reader: anytype, writer: anytype, options: CatOptions, state: *LineNumberState) !void {
    var buf_reader = std.io.bufferedReader(reader);
    var input = buf_reader.reader();

    var line_buf: [common.constants.LINE_BUFFER_SIZE]u8 = undefined;
    while (true) {
        const maybe_line = try input.readUntilDelimiterOrEof(&line_buf, '\n');
        if (maybe_line) |line| {
            const is_blank = line.len == 0;

            // Handle squeeze blank
            if (options.squeeze_blank and is_blank and state.prev_blank) {
                continue;
            }
            state.prev_blank = is_blank;

            // Handle line numbering
            if (options.number_nonblank and !is_blank) {
                // Number non-blank lines only (-b option)
                try writer.print("{d: >6}\t", .{state.line_number});
                state.line_number += 1;
            } else if (options.number_lines and !options.number_nonblank) {
                // Number all lines (-n option, but -b takes precedence)
                try writer.print("{d: >6}\t", .{state.line_number});
                state.line_number += 1;
            }

            // Write the line content
            if (options.show_tabs or options.show_nonprinting) {
                try writeWithSpecialChars(writer, line, options);
            } else {
                try writer.writeAll(line);
            }

            // Handle line ending
            if (options.show_ends) {
                try writer.writeAll("$");
            }
            try writer.writeAll("\n");
        } else {
            // EOF reached
            break;
        }
    }
}

/// Write line with special characters shown in caret and M- notation
fn writeWithSpecialChars(writer: anytype, line: []const u8, options: CatOptions) !void {
    for (line) |ch| {
        if (ch == '\t' and options.show_tabs) {
            try writer.writeAll("^I");
        } else if (options.show_nonprinting and ch < 32 and ch != '\t' and ch != '\n') {
            // Control characters
            try writer.print("^{c}", .{ch + 64});
        } else if (options.show_nonprinting and ch == ASCII_DEL) {
            try writer.writeAll("^?");
        } else if (options.show_nonprinting and ch >= 128) {
            // High bit set - use M- notation
            try writer.writeAll("M-");
            const ch_low = ch & 0x7F; // Strip high bit
            if (ch_low < 32) {
                // Control character in high range
                try writer.print("^{c}", .{ch_low + 64});
            } else if (ch_low == ASCII_DEL) {
                // DEL character
                try writer.writeAll("^?");
            } else {
                // Regular printable character
                try writer.writeByte(ch_low);
            }
        } else {
            try writer.writeByte(ch);
        }
    }
}

test "cat reads single file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Hello, World!\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{});

    try testing.expectEqualStrings("Hello, World!\n", buffer.items);
}

test "cat concatenates multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "file1.txt", "First file\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "file2.txt", "Second file\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Cat multiple files
    try testCatFile(tmp_dir.dir, "file1.txt", buffer.writer(), .{});
    try testCatFile(tmp_dir.dir, "file2.txt", buffer.writer(), .{});

    try testing.expectEqualStrings("First file\nSecond file\n", buffer.items);
}

test "cat reads from stdin when no files" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const stdin_content = "Input from stdin\n";
    var stdin_stream = std.io.fixedBufferStream(stdin_content);

    try testCatStdin(stdin_stream.reader(), buffer.writer(), .{});

    try testing.expectEqualStrings("Input from stdin\n", buffer.items);
}

test "cat with -n numbers all lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .number_lines = true });

    try testing.expectEqualStrings("     1\tLine 1\n     2\tLine 2\n     3\tLine 3\n", buffer.items);
}

test "cat with -b numbers non-blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\n\nLine 3\n\nLine 5\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .number_nonblank = true });

    try testing.expectEqualStrings("     1\tLine 1\n\n     2\tLine 3\n\n     3\tLine 5\n", buffer.items);
}

test "cat with -s squeezes blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\n\n\n\nLine 2\n\n\nLine 3\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .squeeze_blank = true });

    try testing.expectEqualStrings("Line 1\n\nLine 2\n\nLine 3\n", buffer.items);
}

test "cat with -E shows ends" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .show_ends = true });

    try testing.expectEqualStrings("Line 1$\nLine 2$\n", buffer.items);
}

test "cat with -T shows tabs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line\twith\ttabs\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .show_tabs = true });

    try testing.expectEqualStrings("Line^Iwith^Itabs\n", buffer.items);
}

test "cat handles non-existent file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const result = testCatFile(tmp_dir.dir, "nonexistent.txt", buffer.writer(), .{});

    try testing.expectError(error.FileNotFound, result);
}

test "cat with dash reads stdin" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const stdin_content = "From stdin\n";
    var stdin_stream = std.io.fixedBufferStream(stdin_content);

    try testCatStdin(stdin_stream.reader(), buffer.writer(), .{});

    try testing.expectEqualStrings("From stdin\n", buffer.items);
}

test "cat with -A shows all (equivalent to -vET)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\t\nLine 2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .show_nonprinting = true, .show_ends = true, .show_tabs = true });

    try testing.expectEqualStrings("Line 1^I$\nLine 2$\n", buffer.items);
}

test "cat with -e shows ends and non-printing (equivalent to -vE)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .show_nonprinting = true, .show_ends = true });

    try testing.expectEqualStrings("Line 1$\nLine 2$\n", buffer.items);
}

test "cat with -t shows tabs and non-printing (equivalent to -vT)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line\twith\ttabs\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .show_nonprinting = true, .show_tabs = true });

    try testing.expectEqualStrings("Line^Iwith^Itabs\n", buffer.items);
}

test "cat with -u flag is ignored" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Test content\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // -u is ignored, so just use default options
    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{});

    // -u should be ignored, so output should be normal
    try testing.expectEqualStrings("Test content\n", buffer.items);
}

test "cat with -A and control characters" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create file with control character (^A = \x01)
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Test\x01\tEnd\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try testCatFile(tmp_dir.dir, "test.txt", buffer.writer(), .{ .show_nonprinting = true, .show_ends = true, .show_tabs = true });

    try testing.expectEqualStrings("Test^A^IEnd$\n", buffer.items);
}

/// Test helper for processing a file from a directory
fn testCatFile(dir: std.fs.Dir, filename: []const u8, writer: anytype, options: CatOptions) !void {
    const file = try dir.openFile(filename, .{});
    defer file.close();
    var line_state = LineNumberState{};
    try processInput(file.reader(), writer, options, &line_state);
}

/// Test helper for processing stdin-like input
fn testCatStdin(reader: anytype, writer: anytype, options: CatOptions) !void {
    var line_state = LineNumberState{};
    try processInput(reader, writer, options, &line_state);
}
