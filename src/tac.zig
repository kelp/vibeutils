//! tac - concatenate and print files in reverse
//!
//! Write each FILE to standard output, last line first.
//! With no FILE, or when FILE is -, read standard input.
//! By default, lines are delimited by newline characters.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Command-line arguments for the tac utility
const TacArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Attach separator before instead of after
    before: bool = false,
    /// Interpret separator as a regex
    regex: bool = false,
    /// Use STRING as separator instead of newline
    separator: ?[]const u8 = null,
    /// Positional arguments (files)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .before = .{ .short = 'b', .desc = "Attach separator before instead of after" },
        .regex = .{ .short = 'r', .desc = "Interpret separator as a regular expression" },
        .separator = .{ .short = 's', .desc = "Use STRING as separator instead of newline", .value_name = "STRING" },
    };
};

/// Main entry point
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runTac(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Public API that reads from stdin when no files given
pub fn runTac(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parse(TacArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "tac", std.fs.File.stderr().isTty(), "unrecognized option\nTry 'tac --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tac", std.fs.File.stderr().isTty(), "option requires an argument\nTry 'tac --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tac", std.fs.File.stderr().isTty(), "invalid option value\nTry 'tac --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.regex) {
        common.printErrorWithProgram(allocator, stderr_writer, "tac", std.fs.File.stderr().isTty(), "-r (--regex) is not supported", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const separator = parsed.separator orelse "\n";
    const files = parsed.positionals;

    if (files.len == 0) {
        // Read from stdin
        const stdin_file = std.fs.File.stdin();
        return runTacOnInput(allocator, stdin_file, separator, parsed.before, stdout_writer, stderr_writer);
    }

    var has_error = false;
    for (files) |file_path| {
        if (std.mem.eql(u8, file_path, "-")) {
            const stdin_file = std.fs.File.stdin();
            const rc = try runTacOnInput(allocator, stdin_file, separator, parsed.before, stdout_writer, stderr_writer);
            if (rc != 0) has_error = true;
        } else {
            const rc = try runTacOnFile(allocator, file_path, separator, parsed.before, stdout_writer, stderr_writer);
            if (rc != 0) has_error = true;
        }
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

/// Process a named file
fn runTacOnFile(allocator: Allocator, file_path: []const u8, separator: []const u8, before: bool, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "tac", std.fs.File.stderr().isTty(), "{s}: {s}", .{ file_path, @errorName(err) });
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer file.close();

    return runTacOnInput(allocator, file, separator, before, stdout_writer, stderr_writer);
}

/// Core implementation: read all input, split by separator, output in reverse
fn runTacOnInput(allocator: Allocator, input_file: std.fs.File, separator: []const u8, before: bool, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = stderr_writer;

    // Read all input into memory
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(allocator);

    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = input_file.read(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        if (bytes_read == 0) break;
        try content.appendSlice(allocator, buffer[0..bytes_read]);
    }

    if (content.items.len == 0) {
        return @intFromEnum(common.ExitCode.success);
    }

    // Split content by separator and reverse
    if (separator.len == 0) {
        // Empty separator: treat as NUL byte separator
        try reverseByByteSeparator(allocator, content.items, 0, before, stdout_writer);
    } else if (separator.len == 1) {
        try reverseByByteSeparator(allocator, content.items, separator[0], before, stdout_writer);
    } else {
        try reverseByStringSeparator(allocator, content.items, separator, before, stdout_writer);
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Reverse records delimited by a single byte
fn reverseByByteSeparator(allocator: Allocator, data: []const u8, sep: u8, before: bool, writer: anytype) !void {
    // Collect record boundaries
    var records = std.ArrayListUnmanaged([]const u8){};
    defer records.deinit(allocator);

    var start: usize = 0;
    for (data, 0..) |byte, i| {
        if (byte == sep) {
            // Record includes the separator at the end (or we handle before/after)
            try records.append(allocator, data[start .. i + 1]);
            start = i + 1;
        }
    }
    // Handle trailing content without a final separator
    if (start < data.len) {
        try records.append(allocator, data[start..]);
    }

    // Write records in reverse order
    try writeRecordsReversed(records.items, sep, before, writer);
}

/// Reverse records delimited by a multi-byte string
fn reverseByStringSeparator(allocator: Allocator, data: []const u8, sep: []const u8, before: bool, writer: anytype) !void {
    var records = std.ArrayListUnmanaged([]const u8){};
    defer records.deinit(allocator);

    var start: usize = 0;
    var pos: usize = 0;
    while (pos + sep.len <= data.len) {
        if (std.mem.eql(u8, data[pos .. pos + sep.len], sep)) {
            try records.append(allocator, data[start .. pos + sep.len]);
            start = pos + sep.len;
            pos = start;
        } else {
            pos += 1;
        }
    }
    // Trailing content
    if (start < data.len) {
        try records.append(allocator, data[start..]);
    }

    try writeRecordsReversed(records.items, 0, before, writer);
}

/// Write records in reverse. For single-byte separator with --before mode,
/// we need to move separators from trailing to leading position.
fn writeRecordsReversed(records: []const []const u8, sep_byte: u8, before: bool, writer: anytype) !void {
    if (records.len == 0) return;

    if (!before) {
        // Default mode: separator trails each record (already stored that way)
        var i: usize = records.len;
        while (i > 0) {
            i -= 1;
            try writer.writeAll(records[i]);
        }
    } else {
        // Before mode: separator precedes each record instead of trailing.
        // Records are stored with trailing separators.
        // We need to output: sep + content (without trailing sep).
        var i: usize = records.len;
        while (i > 0) {
            i -= 1;
            const rec = records[i];
            // Check if the record has a trailing separator byte
            if (rec.len > 0 and sep_byte != 0 and rec[rec.len - 1] == sep_byte) {
                // Move separator from end to beginning
                try writer.writeByte(sep_byte);
                try writer.writeAll(rec[0 .. rec.len - 1]);
            } else {
                // No trailing separator (last record or multi-byte sep)
                try writer.writeAll(rec);
            }
        }
    }
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: tac [OPTION]... [FILE]...
        \\Write each FILE to standard output, last line first.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --before           attach the separator before instead of after
        \\  -r, --regex            interpret the separator as a regular expression
        \\  -s, --separator=STRING use STRING as the separator instead of newline
        \\  -h, --help             display this help and exit
        \\  -V, --version          output version information and exit
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("tac ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "tac --help shows help message" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runTac(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: tac") != null);
}

test "tac --version shows version information" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runTac(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "tac") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.version) != null);
}

test "tac with unknown flag returns misuse" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runTac(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unrecognized option") != null);
}

test "tac -r returns error (unsupported)" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-r"};
    const result = try runTac(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "not supported") != null);
}

test "tac reverses lines of a file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("line1\nline2\nline3\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("line3\nline2\nline1\n", stdout_buffer.items);
}

test "tac reverses lines without trailing newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("line1\nline2\nline3");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("line3line2\nline1\n", stdout_buffer.items);
}

test "tac handles single line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("only line\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("only line\n", stdout_buffer.items);
}

test "tac handles empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items);
}

test "tac with custom separator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("a:b:c:");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", ":", test_path };
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("c:b:a:", stdout_buffer.items);
}

test "tac with multi-byte separator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("one<>two<>three<>");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "<>", test_path };
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("three<>two<>one<>", stdout_buffer.items);
}

test "tac with --before flag" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("line1\nline2\nline3\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", test_path };
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // With --before, separator moves from trailing to leading
    try testing.expectEqualStrings("\nline3\nline2\nline1", stdout_buffer.items);
}

test "tac with multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file1 = try tmp_dir.dir.createFile("a.txt", .{ .read = true });
    try file1.writeAll("a1\na2\n");
    file1.close();

    const file2 = try tmp_dir.dir.createFile("b.txt", .{ .read = true });
    try file2.writeAll("b1\nb2\n");
    file2.close();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    const path1 = try tmp_dir.dir.realpath("a.txt", &path_buf1);
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = try tmp_dir.dir.realpath("b.txt", &path_buf2);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ path1, path2 };
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Each file is reversed independently
    try testing.expectEqualStrings("a2\na1\nb2\nb1\n", stdout_buffer.items);
}

test "tac with nonexistent file returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"/nonexistent/file.txt"};
    const result = try runTac(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "FileNotFound") != null);
}

test "tac reverseByByteSeparator basic" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByByteSeparator(testing.allocator, "a\nb\nc\n", '\n', false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("c\nb\na\n", buffer.items);
}

test "tac reverseByByteSeparator no trailing separator" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByByteSeparator(testing.allocator, "a\nb\nc", '\n', false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("cb\na\n", buffer.items);
}

test "tac reverseByByteSeparator with before" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByByteSeparator(testing.allocator, "a\nb\nc\n", '\n', true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("\nc\nb\na", buffer.items);
}

test "tac reverseByStringSeparator basic" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByStringSeparator(testing.allocator, "x<>y<>z<>", "<>", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("z<>y<>x<>", buffer.items);
}
