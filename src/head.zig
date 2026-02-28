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
    lines: ?u64 = null,
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

/// Expand obsolete -NUM syntax (e.g., -5) to -n NUM for backwards compatibility
fn expandObsoleteArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    // Count how many extra args we need (one extra per -NUM arg)
    var extra: usize = 0;
    for (args) |arg| {
        if (isObsoleteNumArg(arg)) extra += 1;
    }
    if (extra == 0) return allocator.dupe([]const u8, args);

    const expanded = try allocator.alloc([]const u8, args.len + extra);
    var i: usize = 0;
    for (args) |arg| {
        if (isObsoleteNumArg(arg)) {
            expanded[i] = "-n";
            i += 1;
            expanded[i] = arg[1..]; // strip leading '-'
            i += 1;
        } else {
            expanded[i] = arg;
            i += 1;
        }
    }
    return expanded;
}

/// Check if an argument matches the obsolete -NUM pattern (e.g., "-5", "-100")
fn isObsoleteNumArg(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Core head functionality accepting parsed arguments and writers.
/// Processes files or stdin according to the provided options.
pub fn runHead(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const expanded_args = try expandObsoleteArgs(allocator, args);
    defer allocator.free(expanded_args);

    const parsed_args = common.argparse.ArgParser.parse(HeadArgs, allocator, expanded_args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "head", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "head", "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "head", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
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
    const line_count = parsed_args.lines orelse DEFAULT_LINE_COUNT;

    const options = HeadOptions{
        .line_count = line_count,
        .byte_count = parsed_args.bytes,
        .show_headers = if (parsed_args.quiet) false else if (parsed_args.verbose) true else parsed_args.positionals.len > 1,
    };

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        try processInput(stdin, stdout_writer, options);
    } else {
        var had_error = false;
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
                    had_error = true;
                    continue;
                };
                defer file.close();

                if (options.show_headers) {
                    try stdout_writer.print("==> {s} <==\n", .{file_path});
                }
                var file_buffer: [8192]u8 = undefined;
                var file_reader = file.reader(&file_buffer);
                try processInput(&file_reader.interface, stdout_writer, options);
            }
        }
        if (had_error) {
            return @intFromEnum(common.ExitCode.general_error);
        }
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Entry point for the head binary.
/// Sets up allocator, parses system arguments, and calls runHead.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runHead(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

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

/// Process input from a reader and output first lines/bytes to writer.
/// Streams data without reading the entire input into memory.
pub fn processInput(reader: anytype, writer: anytype, options: HeadOptions) !void {
    if (options.byte_count) |byte_count| {
        // Byte mode: read chunks and write until byte_count reached
        var remaining: u64 = byte_count;
        while (remaining > 0) {
            // peekGreedy(1) fills the buffer and returns all available bytes
            const available = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            const to_write = @min(@as(usize, @intCast(@min(remaining, std.math.maxInt(usize)))), available.len);
            try writer.writeAll(available[0..to_write]);
            reader.toss(to_write);
            remaining -= to_write;
        }
    } else {
        // Line mode: output first N lines
        var lines_written: u64 = 0;
        while (lines_written < options.line_count) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    // Output any remaining partial line (no trailing newline)
                    const remaining = reader.buffered();
                    if (remaining.len > 0) {
                        try writer.writeAll(remaining);
                        reader.toss(remaining.len);
                    }
                    break;
                },
                else => |e| return e,
            };
            try writer.writeAll(line);
            lines_written += 1;
        }
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

const TEST_NEGATIVE_VALUE: []const u8 = "-5";

// ========== TESTS ==========

test "head outputs first 10 lines by default" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 15 lines
    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n" ++
        "Line 6\nLine 7\nLine 8\nLine 9\nLine 10\n" ++
        "Line 11\nLine 12\nLine 13\nLine 14\nLine 15\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    const expected = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n" ++
        "Line 6\nLine 7\nLine 8\nLine 9\nLine 10\n";
    try testing.expectEqualStrings(expected, stdout_buffer.items);
}

test "head with -n 5 outputs first 5 lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "5", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n", stdout_buffer.items);
}

test "head with -c 10 outputs first 10 bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Hello, World! This is a test.\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-c", "10", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Hello, Wor", stdout_buffer.items);
}

test "head handles fewer lines than requested" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    // Request 10 lines (default) but file only has 2
    const args = [_][]const u8{file_path};
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\n", stdout_buffer.items);
}

test "head handles fewer bytes than requested" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Short");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    // Request 1000 bytes but file only has 5
    const args = [_][]const u8{ "-c", "1000", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Short", stdout_buffer.items);
}

test "head handles empty input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_buffer.items);
}

test "head with -n 0 outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "0", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_buffer.items);
}

test "head with -c 0 outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Hello, World!\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-c", "0", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_buffer.items);
}

test "head processes lines efficiently" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with many lines, request only the first 3
    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "3", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\n", stdout_buffer.items);
}

test "head processes bytes efficiently" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "ABCDEFGHIJKLMNOP");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-c", "5", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("ABCDE", stdout_buffer.items);
}

test "head handles invalid line count" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", TEST_NEGATIVE_VALUE };
    const result = try runHead(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 2), result);
}

test "head help flag works" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runHead(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: head") != null);
}

test "head version flag works" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runHead(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "head") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.version) != null);
}

test "head with line count larger than available lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Only one line\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    // Request 100 lines but file only has 1
    const args = [_][]const u8{ "-n", "100", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Only one line\n", stdout_buffer.items);
}

test "head byte count takes precedence over line count" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    // Use -c (bytes) which should override default line count
    const args = [_][]const u8{ "-c", "10", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLin", stdout_buffer.items);
}

test "head continues after file error and outputs remaining files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "valid.txt", content);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const valid_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "valid.txt");
    defer testing.allocator.free(valid_path);

    // First file is nonexistent, second is valid
    const args = [_][]const u8{ "/nonexistent/file.txt", valid_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should return error exit code
    try testing.expectEqual(@as(u8, 1), exit_code);

    // But valid file output should still appear
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Line 1") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Line 2") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Line 3") != null);

    // And stderr should report the error
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "No such file or directory") != null);
}

test "head with multiple files shows headers" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "file1.txt", "Content A\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "file2.txt", "Content B\n");

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const path1 = try tmp_dir.dir.realpathAlloc(testing.allocator, "file1.txt");
    defer testing.allocator.free(path1);
    const path2 = try tmp_dir.dir.realpathAlloc(testing.allocator, "file2.txt");
    defer testing.allocator.free(path2);

    const args = [_][]const u8{ path1, path2 };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should contain file headers
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "==>") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "<==") != null);

    // Should contain both files' content
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Content A") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Content B") != null);
}

test "head with obsolete -NUM syntax" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-3", file_path };
    const exit_code = try runHead(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\n", stdout_buffer.items);
}
