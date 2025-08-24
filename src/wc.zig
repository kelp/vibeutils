const std = @import("std");
const common = @import("common");
const testing = std.testing;
const print = std.debug.print;

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
        .max_line_length = .{ .short = 'L', .desc = "Print the maximum display width" },
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

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
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
                try stderr_writer.print("wc: invalid option\nTry 'wc --help' for more information.\n", .{});
                return 1;
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

    // If no count options specified, default to lines, words, and bytes
    var opts = options;
    if (!opts.lines and !opts.words and !opts.bytes and !opts.chars and !opts.max_line_length) {
        opts.lines = true;
        opts.words = true;
        opts.bytes = true;
    }

    var total_stats = FileStats{};
    var file_count: usize = 0;
    var has_error = false;

    if (options.positionals.len == 0) {
        // Read from stdin
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
        const stats = try countReader(&stdin_reader.interface, opts);
        try printStats(stdout_writer, stats, null, opts);
        total_stats = stats;
        file_count = 1;
    } else {
        // Process each file
        for (options.positionals) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                // Stdin
                var stdin_buffer: [4096]u8 = undefined;
                var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
                const stats = try countReader(&stdin_reader.interface, opts);
                try printStats(stdout_writer, stats, file_path, opts);
                addStats(&total_stats, stats);
                file_count += 1;
            } else {
                // Regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    try stderr_writer.print("wc: {s}: {s}\n", .{ file_path, @errorName(err) });
                    has_error = true;
                    continue;
                };
                defer file.close();

                var file_buffer: [4096]u8 = undefined;
                var file_reader = file.reader(&file_buffer);
                const stats = countReader(&file_reader.interface, opts) catch |err| {
                    try stderr_writer.print("wc: {s}: {s}\n", .{ file_path, @errorName(err) });
                    has_error = true;
                    continue;
                };
                try printStats(stdout_writer, stats, file_path, opts);
                addStats(&total_stats, stats);
                file_count += 1;
            }
        }

        // Print total if multiple files
        if (file_count > 1) {
            try printStats(stdout_writer, total_stats, "total", opts);
        }
    }

    return if (has_error) @as(u8, 1) else 0;
}

/// Count statistics from a reader
fn countReader(reader: anytype, options: WcOptions) !FileStats {
    var stats = FileStats{};
    var in_word = false;

    // Process the file line by line using the new Reader API
    while (reader.takeDelimiterExclusive('\n')) |line| {
        // Count the line
        stats.lines += 1;

        // Count bytes (line + newline)
        stats.bytes += line.len + 1; // +1 for the newline

        // Count characters (UTF-8 aware)
        if (options.chars) {
            for (line) |byte| {
                if ((byte & 0b11000000) != 0b10000000) {
                    stats.chars += 1;
                }
            }
            stats.chars += 1; // +1 for newline
        } else {
            stats.chars = stats.bytes;
        }

        // Track max line length
        if (line.len > stats.max_line_length) {
            stats.max_line_length = line.len;
        }

        // Count words in the line
        var i: usize = 0;
        in_word = false;
        while (i < line.len) : (i += 1) {
            const is_space = std.ascii.isWhitespace(line[i]);
            if (!is_space and !in_word) {
                stats.words += 1;
                in_word = true;
            } else if (is_space) {
                in_word = false;
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {
            // End of stream reached - the Reader API handles lines without final newline correctly
            // Any data without a final delimiter has already been returned by takeDelimiterExclusive
        },
        else => return err,
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
    if (options.lines) {
        try writer.print("{d: >8}", .{stats.lines});
    }
    if (options.words) {
        try writer.print("{d: >8}", .{stats.words});
    }
    if (options.bytes) {
        try writer.print("{d: >8}", .{stats.bytes});
    }
    if (options.chars and !options.bytes) {
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
        \\  -L, --max-line-length  print the maximum display width
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
    var file_buffer: [4096]u8 = undefined;
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
    var file_buffer: [4096]u8 = undefined;
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
    var file_buffer: [4096]u8 = undefined;
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
    var file_buffer: [4096]u8 = undefined;
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
    var file_buffer: [4096]u8 = undefined;
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
    var file_buffer: [4096]u8 = undefined;
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
    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .lines = true });
    try testing.expectEqual(@as(u64, 2), stats.lines); // takeDelimiterExclusive counts both lines
}

test "wc counts multiple whitespace correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("word1   word2\t\tword3\n\n  word4");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const stats = try countReader(&file_reader.interface, .{ .words = true, .lines = true });
    try testing.expectEqual(@as(u64, 4), stats.words);
    try testing.expectEqual(@as(u64, 3), stats.lines); // Actually has 3 lines (two \n chars plus final line)
}

test "wc handles all counts together" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("Hello world\nThis is test\n");
    test_file.close();

    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();
    var file_buffer: [4096]u8 = undefined;
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

// ============================================================================
//                                FUZZ TESTS
// ============================================================================
const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("wc");

test "wc fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testWcIntelligentWrapper, .{});
}

fn testWcIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtility("wc")) return;

    // Create intelligent fuzzer
    const fuzzer = try common.fuzz.createIntelligentFuzzer(WcOptions, runWc).init(allocator);
    defer fuzzer.deinit();

    // Fuzz with the input
    try fuzzer.fuzz(input);
}
