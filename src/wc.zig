const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Options for the wc utility
const WcOptions = struct {
    /// Count lines (-l)
    lines: bool = false,
    /// Count words (-w)
    words: bool = false,
    /// Count bytes (-c)
    bytes: bool = false,
    /// Count characters (-m)
    chars: bool = false,
    /// Max line length (-L)
    max_line_length: bool = false,
    /// Show help
    help: bool = false,
    /// Show version
    version: bool = false,
    /// Colorize the output
    color: ?[]const u8 = null,
    /// libxo structured output format (not supported)
    libxo: ?[]const u8 = null,
    /// Positional arguments (files)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .lines = .{ .short = 'l', .desc = "Print the newline counts" },
        .words = .{ .short = 'w', .desc = "Print the word counts" },
        .bytes = .{ .short = 'c', .desc = "Print the byte counts" },
        .chars = .{ .short = 'm', .desc = "Print the character counts" },
        .max_line_length = .{ .short = 'L', .desc = "Print the maximum line length" },
        .color = .{ .short = 0, .desc = "Colorize the output; WHEN can be 'always', 'auto', or 'never'", .value_name = "WHEN" },
        .libxo = .{ .short = 0, .desc = "Generate output via libxo (not supported)", .value_name = "FORMAT" },
    };
};

/// Statistics for a single file or stream
const FileStats = struct {
    lines: u64 = 0,
    words: u64 = 0,
    bytes: u64 = 0,
    chars: u64 = 0,
    max_line_length: u64 = 0,
};

// ============================================================================
// Resolved configuration after processing option interactions
// ============================================================================

const WcConfig = struct {
    display: common.display_config.DisplayConfig,
};

fn resolveConfig(allocator: Allocator, opts: WcOptions) !WcConfig {
    var config = WcConfig{
        .display = common.display_config.DisplayConfig.resolve(allocator),
    };

    // Parse explicit --color mode (overrides DisplayConfig)
    if (opts.color) |when| {
        if (std.mem.eql(u8, when, "always")) {
            config.display.color = .on;
        } else if (std.mem.eql(u8, when, "auto")) {
            // Keep resolved value (TTY-dependent)
        } else if (std.mem.eql(u8, when, "never")) {
            config.display.color = .off;
        } else {
            return error.InvalidColorMode;
        }
    }

    return config;
}

// ============================================================================
// Semantic column colors
// ============================================================================

const WcColumn = enum { lines, words, bytes_chars, max_line_length };

fn applyWcColumnColor(style_inst: anytype, column: WcColumn) !void {
    switch (style_inst.color_mode) {
        .truecolor => {
            switch (column) {
                .lines => try style_inst.setRgb(100, 200, 210),
                .words => try style_inst.setRgb(115, 195, 120),
                .bytes_chars => try style_inst.setRgb(210, 195, 100),
                .max_line_length => try style_inst.setRgb(180, 140, 200),
            }
        },
        .extended => {
            switch (column) {
                .lines => try style_inst.set256(116),
                .words => try style_inst.set256(114),
                .bytes_chars => try style_inst.set256(185),
                .max_line_length => try style_inst.set256(176),
            }
        },
        .basic => {
            switch (column) {
                .lines => try style_inst.setColor(.cyan),
                .words => try style_inst.setColor(.green),
                .bytes_chars => try style_inst.setColor(.yellow),
                .max_line_length => try style_inst.setColor(.magenta),
            }
        },
        .none => return,
    }
}

/// Main entry point
pub fn main() !void {
    common.utilityMain(runWc);
}

/// Run the wc utility with given arguments
pub fn runWc(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const options = common.argparse.ArgParser.parseOrExit(WcOptions, allocator, args, "wc", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(options.positionals);

    if (options.help) {
        try printHelp(allocator, stdout_writer);
        return 0;
    }

    if (options.version) {
        try printVersion(stdout_writer);
        return 0;
    }

    // Handle --libxo: not supported, print error and exit
    if (options.libxo != null) {
        common.printErrorWithProgram(allocator, stderr_writer, "wc", "libxo output is not supported", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // GNU wc: -c and -m are NOT mutually exclusive.
    // When both are specified, both columns are printed (chars before bytes).
    var opts = options;

    // If no count options specified, default to lines, words, and bytes
    if (!opts.lines and !opts.words and !opts.bytes and !opts.chars and !opts.max_line_length) {
        opts.lines = true;
        opts.words = true;
        opts.bytes = true;
    }

    // Resolve display configuration
    const config = resolveConfig(allocator, opts) catch |err| switch (err) {
        error.InvalidColorMode => {
            common.printErrorWithProgram(allocator, stderr_writer, "wc", "invalid argument '{s}' for '--color'\nValid arguments are: 'always', 'auto', 'never'", .{opts.color orelse ""});
            return @intFromEnum(common.ExitCode.misuse);
        },
    };

    // Initialize styling based on resolved display config
    const StyleType = common.style.Style(@TypeOf(stdout_writer));
    var style_inst = StyleType{ .color_mode = .none, .writer = stdout_writer };
    if (config.display.color == .on) {
        const detected = StyleType.ColorMode.detect(allocator) catch .basic;
        style_inst.color_mode = if (detected == .none) .basic else detected;
    }

    var total_stats = FileStats{};
    var has_error = false;

    if (options.positionals.len == 0) {
        // Read from stdin
        var stdin_buffer: [8192]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
        const stats = try countReader(&stdin_reader.interface, opts);
        try printStats(stdout_writer, stats, null, opts, style_inst);
    } else {
        // Process each file
        for (options.positionals) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                // Stdin
                var stdin_buffer: [8192]u8 = undefined;
                var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
                const stats = try countReader(&stdin_reader.interface, opts);
                try printStats(stdout_writer, stats, file_path, opts, style_inst);
                addStats(&total_stats, stats);
            } else {
                // Check if it's a directory first
                const stat = std.fs.cwd().statFile(file_path) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: {s}", .{ file_path, common.posixErrorString(err) });
                    has_error = true;
                    continue;
                };

                if (stat.kind == .directory) {
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: Is a directory", .{file_path});
                    has_error = true;
                    continue;
                }

                // Regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: {s}", .{ file_path, common.posixErrorString(err) });
                    has_error = true;
                    continue;
                };
                defer file.close();

                var file_buffer: [8192]u8 = undefined;
                var file_reader = file.reader(&file_buffer);
                const stats = countReader(&file_reader.interface, opts) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: {s}", .{ file_path, common.posixErrorString(err) });
                    has_error = true;
                    continue;
                };
                try printStats(stdout_writer, stats, file_path, opts, style_inst);
                addStats(&total_stats, stats);
            }
        }

        // Print total if multiple files were requested (not just successful ones)
        if (options.positionals.len > 1) {
            try printStats(stdout_writer, total_stats, "total", opts, style_inst);
        }
    }

    return if (has_error) @as(u8, 1) else 0;
}

/// Count statistics from a reader - POSIX compliant implementation
/// Streams data in 8192-byte chunks to avoid loading entire file into memory
/// POSIX: lines are counted as the number of newline characters (\n)
/// A file without a final newline has 0 lines (even if it has content)
fn countReader(reader: anytype, options: WcOptions) !FileStats {
    var stats = FileStats{};
    var in_word = false;
    var current_line_length: u64 = 0;

    // UTF-8 decoding state for -L display width calculation
    var utf8_remaining: u3 = 0; // continuation bytes remaining
    var utf8_codepoint: u21 = 0; // accumulated codepoint

    while (true) {
        const chunk = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        // Process each byte in the chunk
        for (chunk) |byte| {
            // Count all bytes exactly
            stats.bytes += 1;

            // Count newlines (POSIX: this is what defines a "line")
            if (byte == '\n') {
                stats.lines += 1;
                // Track max line length
                if (current_line_length > stats.max_line_length) {
                    stats.max_line_length = current_line_length;
                }
                current_line_length = 0;
                utf8_remaining = 0; // reset UTF-8 state on newline
                in_word = false; // newline breaks words
            } else if (options.max_line_length) {
                // Compute display width for -L flag
                if (byte == '\t') {
                    // Tab: advance to next 8-column tab stop
                    current_line_length = (current_line_length + 8) & ~@as(u64, 7);
                    utf8_remaining = 0;
                } else if (utf8_remaining > 0) {
                    // UTF-8 continuation byte
                    utf8_codepoint = (utf8_codepoint << 6) | @as(u21, byte & 0x3F);
                    utf8_remaining -= 1;
                    if (utf8_remaining == 0) {
                        // Codepoint complete - add its display width
                        current_line_length += common.unicode.codepointWidth(utf8_codepoint);
                    }
                } else if (byte < 0x80) {
                    // ASCII character
                    if (byte >= 0x20 and byte != 0x7F) {
                        current_line_length += 1;
                    }
                    // Control chars (except tab/newline handled above): width 0
                } else {
                    // UTF-8 start byte
                    if (byte & 0xE0 == 0xC0) {
                        // 2-byte sequence
                        utf8_remaining = 1;
                        utf8_codepoint = @as(u21, byte & 0x1F);
                    } else if (byte & 0xF0 == 0xE0) {
                        // 3-byte sequence
                        utf8_remaining = 2;
                        utf8_codepoint = @as(u21, byte & 0x0F);
                    } else if (byte & 0xF8 == 0xF0) {
                        // 4-byte sequence
                        utf8_remaining = 3;
                        utf8_codepoint = @as(u21, byte & 0x07);
                    } else {
                        // Invalid start byte - count as width 1
                        current_line_length += 1;
                    }
                }
            } else {
                // No -L flag: simple byte count for line length
                current_line_length += 1;
            }

            // Count UTF-8 characters (only if -m flag specified)
            if (options.chars) {
                // UTF-8 continuation bytes have pattern 10xxxxxx
                if ((byte & 0b11000000) != 0b10000000) {
                    stats.chars += 1;
                }
            }

            // Word counting logic
            const is_space = std.ascii.isWhitespace(byte);
            if (!is_space and !in_word) {
                stats.words += 1;
                in_word = true;
            } else if (is_space) {
                in_word = false;
            }
        }

        // Mark chunk as consumed
        reader.toss(chunk.len);
    }

    // Handle final line length (for files not ending with newline)
    if (current_line_length > stats.max_line_length) {
        stats.max_line_length = current_line_length;
    }

    // Set character count to byte count if not explicitly counting UTF-8 chars
    if (!options.chars) {
        stats.chars = stats.bytes;
    }

    return stats;
}

/// Add stats together for totals
fn addStats(total: *FileStats, stats: FileStats) void {
    total.lines += stats.lines;
    total.words += stats.words;
    total.bytes += stats.bytes;
    total.chars += stats.chars;
    if (stats.max_line_length > total.max_line_length) {
        total.max_line_length = stats.max_line_length;
    }
}

/// Print statistics for a file
fn printStats(writer: anytype, stats: FileStats, filename: ?[]const u8, options: WcOptions, style_inst: anytype) !void {
    // Print counts in GNU column order: lines words chars bytes max_line_length filename
    // When both -c and -m are given, both columns appear (chars before bytes).
    if (options.lines) {
        try applyWcColumnColor(style_inst, .lines);
        try writer.print("{d: >8}", .{stats.lines});
        try style_inst.reset();
    }
    if (options.words) {
        try applyWcColumnColor(style_inst, .words);
        try writer.print("{d: >8}", .{stats.words});
        try style_inst.reset();
    }
    if (options.chars) {
        try applyWcColumnColor(style_inst, .bytes_chars);
        try writer.print("{d: >8}", .{stats.chars});
        try style_inst.reset();
    }
    if (options.bytes) {
        try applyWcColumnColor(style_inst, .bytes_chars);
        try writer.print("{d: >8}", .{stats.bytes});
        try style_inst.reset();
    }
    if (options.max_line_length) {
        try applyWcColumnColor(style_inst, .max_line_length);
        try writer.print("{d: >8}", .{stats.max_line_length});
        try style_inst.reset();
    }
    if (filename) |name| {
        // Bold for "total" label
        if (std.mem.eql(u8, name, "total")) {
            try style_inst.setBold();
            try writer.print(" {s}", .{name});
            try style_inst.reset();
        } else {
            try writer.print(" {s}", .{name});
        }
    }
    try writer.print("\n", .{});
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: wc [OPTION]... [FILE]...
        \\Print newline, word, and byte counts for each FILE, and a total line if
        \\more than one FILE is specified. A word is a non-zero-length sequence of
        \\characters delimited by white space.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes            print the byte counts
        \\  -m, --chars            print the character counts
        \\  -l, --lines            print the newline counts
        \\  -L, --max-line-length  print the maximum line length
        \\  -w, --words            print the word counts
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\      --color=WHEN      colorize columns; WHEN is 'always', 'auto' (default),
        \\                          or 'never'
        \\
        \\When both -c and -m are given, both character and byte counts are shown.
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("wc (vibeutils) {s}\n", .{common.version});
}

// ========== TESTS ==========

test "wc counts lines correctly" {
    // Create a test file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("line1\nline2\nline3\n");
    test_file.close();

    // Open and count
    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .lines = true });
    try testing.expectEqual(@as(u64, 3), stats.lines);
}

test "wc counts words correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello world\nthis is a test\n");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .words = true });
    try testing.expectEqual(@as(u64, 6), stats.words);
}

test "wc counts bytes correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("12345\n67890\n");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .bytes = true });
    try testing.expectEqual(@as(u64, 12), stats.bytes);
}

test "wc counts UTF-8 characters correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello 世界\n"); // 5 ASCII + 1 space + 2 CJK + 1 newline = 9 chars, 13 bytes
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .chars = true });
    try testing.expectEqual(@as(u64, 9), stats.chars);
    try testing.expectEqual(@as(u64, 13), stats.bytes);
}

test "wc finds maximum line length" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("short\nthis is a longer line\nmedium\n");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .max_line_length = true });
    try testing.expectEqual(@as(u64, 21), stats.max_line_length); // "this is a longer line" = 21 chars
}

test "wc handles empty input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{});
    try testing.expectEqual(@as(u64, 0), stats.lines);
    try testing.expectEqual(@as(u64, 0), stats.words);
    try testing.expectEqual(@as(u64, 0), stats.bytes);
}

test "wc handles input without final newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("line1\nline2");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .lines = true });
    try testing.expectEqual(@as(u64, 1), stats.lines); // POSIX: 1 newline = 1 line
}

test "wc counts multiple whitespace correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("word1   word2\t\tword3\n\n  word4");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .words = true, .lines = true });
    try testing.expectEqual(@as(u64, 4), stats.words);
    try testing.expectEqual(@as(u64, 2), stats.lines); // POSIX: 2 newlines = 2 lines
}

test "wc handles all counts together" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("Hello world\nThis is test\n");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{
        .lines = true,
        .words = true,
        .bytes = true,
    });
    try testing.expectEqual(@as(u64, 2), stats.lines);
    try testing.expectEqual(@as(u64, 5), stats.words);
    try testing.expectEqual(@as(u64, 25), stats.bytes); // "Hello world\nThis is test\n" = 25 bytes
}

test "wc addStats combines statistics correctly" {
    var total = FileStats{};
    const stats1 = FileStats{ .lines = 5, .words = 10, .bytes = 50, .chars = 45, .max_line_length = 20 };
    const stats2 = FileStats{ .lines = 3, .words = 8, .bytes = 30, .chars = 28, .max_line_length = 25 };

    addStats(&total, stats1);
    addStats(&total, stats2);

    try testing.expectEqual(@as(u64, 8), total.lines);
    try testing.expectEqual(@as(u64, 18), total.words);
    try testing.expectEqual(@as(u64, 80), total.bytes);
    try testing.expectEqual(@as(u64, 73), total.chars);
    try testing.expectEqual(@as(u64, 25), total.max_line_length);
}

test "wc output formatting" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const stats = FileStats{
        .lines = 10,
        .words = 50,
        .bytes = 250,
        .chars = 240,
        .max_line_length = 80,
    };

    // Create a no-op style (color_mode = .none)
    var style_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer style_buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const test_style = TestStyle{ .color_mode = .none, .writer = style_buffer.writer(testing.allocator) };

    try printStats(buffer.writer(testing.allocator), stats, "test.txt", .{
        .lines = true,
        .words = true,
        .bytes = true,
    }, test_style);

    try testing.expectEqualStrings("      10      50     250 test.txt\n", buffer.items);
}

test "wc runWc with default options" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Create a test file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("line1\nline2\nline3\n");
    test_file.close();

    // Create path to the test file
    const test_filename = "test.txt";
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath(test_filename, &path_buffer);

    const args = &[_][]const u8{test_path};
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Default shows lines, words, bytes
    const expected_prefix = "       3       3      18 ";
    try testing.expect(std.mem.startsWith(u8, stdout_buffer.items, expected_prefix));
}

test "wc with multiple files shows total" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file1 = try tmp_dir.dir.createFile("a.txt", .{});
    try file1.writeAll("one two\n");
    file1.close();

    const file2 = try tmp_dir.dir.createFile("b.txt", .{});
    try file2.writeAll("three four five\n");
    file2.close();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    const path1 = try tmp_dir.dir.realpath("a.txt", &path_buf1);
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = try tmp_dir.dir.realpath("b.txt", &path_buf2);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ path1, path2 };
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should contain "total" line for multiple files
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "total") != null);

    // Total should be 2 lines, 5 words, 24 bytes
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "       2       5      24 total") != null);
}

test "wc --help shows usage" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--help"};
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: wc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--bytes") != null);
}

test "wc --version shows version" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--version"};
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "wc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
}

test "wc reports error for directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath("subdir", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{dir_path};
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "Is a directory") != null);
}

// ========== COLOR TESTS ==========

// C library functions for environment manipulation in tests
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

test "resolveConfig defaults: color off in test (no TTY)" {
    const config = try resolveConfig(testing.allocator, .{});
    // In test environment (no TTY), color should default to off
    try testing.expectEqual(common.display_config.ResolvedMode.off, config.display.color);
}

test "resolveConfig --color=always sets display.color on" {
    const config = try resolveConfig(testing.allocator, .{ .color = "always" });
    try testing.expectEqual(common.display_config.ResolvedMode.on, config.display.color);
}

test "resolveConfig --color=never sets display.color off" {
    const config = try resolveConfig(testing.allocator, .{ .color = "never" });
    try testing.expectEqual(common.display_config.ResolvedMode.off, config.display.color);
}

test "resolveConfig --color=invalid returns error" {
    const result = resolveConfig(testing.allocator, .{ .color = "invalid" });
    try testing.expectError(error.InvalidColorMode, result);
}

test "applyWcColumnColor truecolor: lines" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .lines);
    try testing.expectEqualSlices(u8, "\x1b[38;2;100;200;210m", buffer.items);
}

test "applyWcColumnColor truecolor: words" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .words);
    try testing.expectEqualSlices(u8, "\x1b[38;2;115;195;120m", buffer.items);
}

test "applyWcColumnColor truecolor: bytes_chars" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .bytes_chars);
    try testing.expectEqualSlices(u8, "\x1b[38;2;210;195;100m", buffer.items);
}

test "applyWcColumnColor truecolor: max_line_length" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .max_line_length);
    try testing.expectEqualSlices(u8, "\x1b[38;2;180;140;200m", buffer.items);
}

test "applyWcColumnColor basic: lines uses cyan" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .lines);
    try testing.expectEqualSlices(u8, "\x1b[36m", buffer.items);
}

test "applyWcColumnColor basic: words uses green" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .words);
    try testing.expectEqualSlices(u8, "\x1b[32m", buffer.items);
}

test "applyWcColumnColor basic: bytes_chars uses yellow" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .bytes_chars);
    try testing.expectEqualSlices(u8, "\x1b[33m", buffer.items);
}

test "applyWcColumnColor basic: max_line_length uses magenta" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .max_line_length);
    try testing.expectEqualSlices(u8, "\x1b[35m", buffer.items);
}

test "applyWcColumnColor none: no output" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .none, .writer = buffer.writer(testing.allocator) };
    try applyWcColumnColor(s, .lines);
    try testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "wc --libxo prints error and exits with code 1" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "--libxo=xml", "-l" };
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "libxo output is not supported") != null);
}

test "wc --color=invalid exits with code 2" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--color=invalid"};
    const exit_code = try runWc(testing.allocator, args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid argument") != null);
}
