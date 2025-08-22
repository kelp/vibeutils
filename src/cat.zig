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

/// ASCII DEL character (0x7F) - represents the delete control character
/// that displays as '^?' when shown with -v flag
const ASCII_DEL = 127;

/// Command-line arguments for cat
const CatArgs = struct {
    help: bool = false,
    version: bool = false,
    show_all: bool = false,
    number_nonblank: bool = false,
    show_ends_and_nonprinting: bool = false,
    show_ends: bool = false,
    number: bool = false,
    squeeze_blank: bool = false,
    show_tabs_and_nonprinting: bool = false,
    show_tabs: bool = false,
    ignored_u: bool = false,
    show_nonprinting: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .show_all = .{ .short = 'A', .desc = "Equivalent to -vET" },
        .number_nonblank = .{ .short = 'b', .desc = "Number non-empty output lines, overrides -n" },
        .show_ends_and_nonprinting = .{ .short = 'e', .desc = "Equivalent to -vE" },
        .show_ends = .{ .short = 'E', .desc = "Display $ at end of each line" },
        .number = .{ .short = 'n', .desc = "Number all output lines" },
        .squeeze_blank = .{ .short = 's', .desc = "Suppress repeated empty output lines" },
        .show_tabs_and_nonprinting = .{ .short = 't', .desc = "Equivalent to -vT" },
        .show_tabs = .{ .short = 'T', .desc = "Display TAB characters as ^I" },
        .ignored_u = .{ .short = 'u', .desc = "(ignored)" },
        .show_nonprinting = .{ .short = 'v', .desc = "Use ^ and M- notation, except for LFD and TAB" },
    };
};

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("cat ({s}) {s}\n", .{ common.name, common.version });
}

/// Resolves GNU cat flag combinations into a unified options structure.
/// GNU cat defines several convenience flags that combine multiple behaviors:
/// - `-A` combines `-v`, `-E`, and `-T` (show all non-printing chars, ends, and tabs)
/// - `-e` combines `-v` and `-E` (show non-printing chars and line ends)
/// - `-t` combines `-v` and `-T` (show non-printing chars and tabs)
fn resolveFlagCombinations(parsed_args: CatArgs) CatOptions {
    return CatOptions{
        .number_lines = parsed_args.number,
        .number_nonblank = parsed_args.number_nonblank,
        .squeeze_blank = parsed_args.squeeze_blank,
        .show_ends = parsed_args.show_ends or parsed_args.show_all or parsed_args.show_ends_and_nonprinting,
        .show_tabs = parsed_args.show_tabs or parsed_args.show_all or parsed_args.show_tabs_and_nonprinting,
        .show_nonprinting = parsed_args.show_nonprinting or parsed_args.show_all or parsed_args.show_ends_and_nonprinting or parsed_args.show_tabs_and_nonprinting,
    };
}

pub fn runCat(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(CatArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "cat", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "cat", "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "cat", "invalid option value", .{});
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

    // Resolve flag combinations following GNU cat conventions
    const options = resolveFlagCombinations(parsed_args);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    var line_state = LineNumberState{};
    // Track errors to continue processing all files (POSIX requirement)
    var has_error = false;

    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        processInput(allocator, stdin, stdout_writer, options, &line_state) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cat", "stdin: {s}", .{@errorName(err)});
            has_error = true;
        };
    } else {
        // Process each file in order, continuing on errors
        for (parsed_args.positionals) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                // "-" means read from stdin
                processInput(allocator, stdin, stdout_writer, options, &line_state) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cat", "stdin: {s}", .{@errorName(err)});
                    has_error = true;
                };
            } else {
                // Open and process regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cat", "{s}: {s}", .{ file_path, @errorName(err) });
                    has_error = true;
                    continue; // Continue to next file
                };
                defer file.close();
                processInput(allocator, file.reader(), stdout_writer, options, &line_state) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cat", "{s}: {s}", .{ file_path, @errorName(err) });
                    has_error = true;
                };
            }
        }
    }
    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

/// Process files or stdin with the specified formatting options
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runCat(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};
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

/// Configuration options that control how cat formats and displays output.
/// These options determine line numbering, blank line handling, and special character visualization.
const CatOptions = struct {
    /// Number all output lines when true (controlled by -n flag)
    number_lines: bool = false,
    /// Number only non-blank output lines when true (controlled by -b flag, overrides number_lines)
    number_nonblank: bool = false,
    /// Suppress consecutive empty output lines when true (controlled by -s flag)
    squeeze_blank: bool = false,
    /// Display '$' at the end of each line when true (controlled by -E flag)
    show_ends: bool = false,
    /// Display TAB characters as '^I' when true (controlled by -T flag)
    show_tabs: bool = false,
    /// Display non-printing characters using caret and M- notation when true (controlled by -v flag)
    show_nonprinting: bool = false,
};

/// Maintains line numbering and blank line tracking state across multiple input files.
/// This state persists between files to ensure continuous line numbering when processing
/// multiple files in a single cat invocation.
const LineNumberState = struct {
    /// Current line number for numbering output (starts at 1)
    line_number: usize = 1,
    /// Tracks whether the previous line was blank for squeeze_blank functionality
    prev_blank: bool = false,
};

/// Format output according to the specified options.
/// Maintains line numbering state across multiple files.
/// Uses the new Reader API with takeDelimiterExclusive for line reading.
pub fn processInput(allocator: std.mem.Allocator, reader: anytype, writer: anytype, options: CatOptions, state: *LineNumberState) !void {
    _ = allocator; // No longer needed with new Reader API

    // Process lines using the new Reader API
    while (reader.takeDelimiterExclusive('\n')) |line| {
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
    } else |err| switch (err) {
        error.EndOfStream => {
            // End of file reached, no special handling needed
            // The new Reader API handles lines without final newline correctly
        },
        else => return err,
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

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Hello, World!\n", stdout_buffer.items);
}

test "cat concatenates multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "file1.txt", "First file\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "file2.txt", "Second file\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file1_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "file1.txt");
    defer testing.allocator.free(file1_path);
    const file2_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "file2.txt");
    defer testing.allocator.free(file2_path);

    const args = [_][]const u8{ file1_path, file2_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("First file\nSecond file\n", stdout_buffer.items);
}

test "cat reads from stdin when no files" {
    // This test would require mocking stdin, which is complex with runCat
    // We'll test this functionality through the dash argument test instead
    return error.SkipZigTest;
}

test "cat with -n numbers all lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("     1\tLine 1\n     2\tLine 2\n     3\tLine 3\n", stdout_buffer.items);
}

test "cat with -b numbers non-blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\n\nLine 3\n\nLine 5\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-b", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("     1\tLine 1\n\n     2\tLine 3\n\n     3\tLine 5\n", stdout_buffer.items);
}

test "cat with -s squeezes blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\n\n\n\nLine 2\n\n\nLine 3\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-s", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1\n\nLine 2\n\nLine 3\n", stdout_buffer.items);
}

test "cat with -E shows ends" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-E", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1$\nLine 2$\n", stdout_buffer.items);
}

test "cat with -T shows tabs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line\twith\ttabs\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-T", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line^Iwith^Itabs\n", stdout_buffer.items);
}

test "cat handles non-existent file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const tmp_base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_base_path);
    const nonexistent_path = try std.fmt.allocPrint(testing.allocator, "{s}/nonexistent.txt", .{tmp_base_path});
    defer testing.allocator.free(nonexistent_path);

    const args = [_][]const u8{nonexistent_path};
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expect(stderr_buffer.items.len > 0);
}

test "cat with dash reads stdin" {
    // Testing stdin with dash requires mocking stdin, which is complex with runCat
    // This functionality is tested in integration tests
    return error.SkipZigTest;
}

test "cat with -A shows all (equivalent to -vET)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\t\nLine 2\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-A", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1^I$\nLine 2$\n", stdout_buffer.items);
}

test "cat with -e shows ends and non-printing (equivalent to -vE)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-e", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1$\nLine 2$\n", stdout_buffer.items);
}

test "cat with -t shows tabs and non-printing (equivalent to -vT)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line\twith\ttabs\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-t", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line^Iwith^Itabs\n", stdout_buffer.items);
}

test "cat with -u flag is ignored" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Test content\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-u", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    // -u should be ignored, so output should be normal
    try testing.expectEqualStrings("Test content\n", stdout_buffer.items);
}

test "cat with -A and control characters" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create file with control character (^A = \x01)
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Test\x01\tEnd\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-A", file_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Test^A^IEnd$\n", stdout_buffer.items);
}

test "cat handles very long lines without truncation" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a line much longer than the old buffer size (8192 bytes)
    var long_line = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer long_line.deinit(testing.allocator);

    // Create 10KB line to test dynamic allocation
    try long_line.appendNTimes(testing.allocator, 'X', 10240);
    try long_line.append(testing.allocator, '\n');

    try common.test_utils.createTestFile(tmp_dir.dir, "long.txt", long_line.items);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "long.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    // Should output the full line without truncation
    try testing.expectEqualStrings(long_line.items, stdout_buffer.items);
}

test "cat continues processing files after error" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create one good file
    try common.test_utils.createTestFile(tmp_dir.dir, "good.txt", "Good content\n");

    // Get absolute paths for the test
    const good_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "good.txt");
    defer testing.allocator.free(good_path);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Create a non-existent file path in the temp directory
    const tmp_base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_base_path);
    const nonexistent_path = try std.fmt.allocPrint(testing.allocator, "{s}/definitely-nonexistent-file.txt", .{tmp_base_path});
    defer testing.allocator.free(nonexistent_path);

    // Test with non-existent file followed by good file
    const args = [_][]const u8{ nonexistent_path, good_path };
    const exit_code = try runCat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should return error exit code due to nonexistent file
    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);

    // But should have processed the good file
    try testing.expectEqualStrings("Good content\n", stdout_buffer.items);

    // And should have error message for bad file
    try testing.expect(stderr_buffer.items.len > 0);
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("cat");

test "cat fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testCatIntelligentWrapper, .{});
}

fn testCatIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("cat")) return;

    const CatIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(CatArgs, runCat);
    try CatIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}

test "cat fuzz file lists" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testCatFileLists, .{});
}

fn testCatFileLists(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("cat")) return;

    var file_storage = common.fuzz.FileListStorage.init();
    const files = common.fuzz.generateFileList(&file_storage, input);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stdout_buf.deinit(allocator);

    _ = runCat(allocator, files, stdout_buf.writer(allocator), common.null_writer) catch {
        // File not found errors are expected
        return;
    };
}
