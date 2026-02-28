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

/// Main entry point
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runWc(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Run the wc utility with given arguments
pub fn runWc(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const options = common.argparse.ArgParser.parse(WcOptions, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "wc", "invalid option\nTry 'wc --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "wc", "option requires an argument\nTry 'wc --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "wc", "invalid argument value\nTry 'wc --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(options.positionals);

    if (options.help) {
        try printHelp(stdout_writer);
        return 0;
    }

    if (options.version) {
        try printVersion(stdout_writer);
        return 0;
    }

    // Handle -c/-m mutual exclusion: "last flag wins" behavior (GNU wc compatibility)
    var opts = options;
    if (opts.bytes and opts.chars) {
        // Both -c and -m specified, need to determine which was last
        // Use a sequence counter to handle combined flags like -cm/-mc correctly
        var last_byte_char: enum { none, bytes, chars } = .none;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--bytes")) {
                last_byte_char = .bytes;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--chars")) {
                last_byte_char = .chars;
            } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
                // Handle combined flags like -cm or -mc
                for (arg[1..]) |flag_char| {
                    if (flag_char == 'c') last_byte_char = .bytes;
                    if (flag_char == 'm') last_byte_char = .chars;
                }
            }
        }

        // Last flag wins
        switch (last_byte_char) {
            .bytes => opts.chars = false,
            .chars => opts.bytes = false,
            .none => opts.bytes = false, // fallback
        }
    }

    // If no count options specified, default to lines, words, and bytes
    if (!opts.lines and !opts.words and !opts.bytes and !opts.chars and !opts.max_line_length) {
        opts.lines = true;
        opts.words = true;
        opts.bytes = true;
    }

    var total_stats = FileStats{};
    var has_error = false;

    if (options.positionals.len == 0) {
        // Read from stdin
        var stdin_buffer: [8192]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
        const stats = try countReader(&stdin_reader.interface, opts);
        try printStats(stdout_writer, stats, null, opts);
    } else {
        // Process each file
        for (options.positionals) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                // Stdin
                var stdin_buffer: [8192]u8 = undefined;
                var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
                const stats = try countReader(&stdin_reader.interface, opts);
                try printStats(stdout_writer, stats, file_path, opts);
                addStats(&total_stats, stats);
            } else {
                // Check if it's a directory first
                const stat = std.fs.cwd().statFile(file_path) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: {s}", .{ file_path, @errorName(err) });
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
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: {s}", .{ file_path, @errorName(err) });
                    has_error = true;
                    continue;
                };
                defer file.close();

                var file_buffer: [8192]u8 = undefined;
                var file_reader = file.reader(&file_buffer);
                const stats = countReader(&file_reader.interface, opts) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "wc", "{s}: {s}", .{ file_path, @errorName(err) });
                    has_error = true;
                    continue;
                };
                try printStats(stdout_writer, stats, file_path, opts);
                addStats(&total_stats, stats);
            }
        }

        // Print total if multiple files were requested (not just successful ones)
        if (options.positionals.len > 1) {
            try printStats(stdout_writer, total_stats, "total", opts);
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
                in_word = false; // newline breaks words
            } else {
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
fn printStats(writer: anytype, stats: FileStats, filename: ?[]const u8, options: WcOptions) !void {
    // Print counts in the order: lines words bytes/chars max_line_length filename
    // Mutual exclusion between -c and -m is handled during argument processing
    if (options.lines) {
        try writer.print("{d: >8}", .{stats.lines});
    }
    if (options.words) {
        try writer.print("{d: >8}", .{stats.words});
    }
    if (options.bytes) {
        try writer.print("{d: >8}", .{stats.bytes});
    }
    if (options.chars) {
        try writer.print("{d: >8}", .{stats.chars});
    }
    if (options.max_line_length) {
        try writer.print("{d: >8}", .{stats.max_line_length});
    }
    if (filename) |name| {
        try writer.print(" {s}", .{name});
    }
    try writer.print("\n", .{});
}

/// Print help message
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
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
        \\
        \\The options -c and -m are mutually exclusive.
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

    try printStats(buffer.writer(testing.allocator), stats, "test.txt", .{
        .lines = true,
        .words = true,
        .bytes = true,
    });

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
