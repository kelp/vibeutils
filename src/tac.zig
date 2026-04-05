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
    common.utilityMain(runTac);
}

/// Public API that reads from stdin when no files given
pub fn runTac(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parseOrExit(TacArgs, allocator, args, "tac", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
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
        common.printErrorWithProgram(allocator, stderr_writer, "tac", "-r (--regex) is not supported", .{});
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
        common.printErrorWithProgram(allocator, stderr_writer, "tac", "{s}: {s}", .{ file_path, common.posixErrorString(err) });
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
    var records = std.ArrayListUnmanaged([]const u8){};
    defer records.deinit(allocator);

    if (before) {
        // In -b mode, the separator is prepended to each record.
        // For "a\nb\nc\n", records are: "a", "\nb", "\nc", "\n"
        // First record runs from start to (but not including) the first separator.
        // Subsequent records start at the separator and run to (but not including) the next.
        var start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == sep and i > start) {
                // End the previous record just before this separator
                try records.append(allocator, data[start..i]);
                start = i; // Next record starts at the separator
            } else if (byte == sep and i == start) {
                // Separator at the very start of remaining data — look for next boundary
                // Just continue; the separator is part of the next record
            }
        }
        // Remaining content from start to end
        if (start < data.len) {
            try records.append(allocator, data[start..]);
        }
    } else {
        // Default mode: separator trails each record.
        var start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == sep) {
                try records.append(allocator, data[start .. i + 1]);
                start = i + 1;
            }
        }
        if (start < data.len) {
            try records.append(allocator, data[start..]);
        }
    }

    // Write records in reverse order
    try writeRecordsReversed(records.items, writer);
}

/// Reverse records delimited by a multi-byte string
fn reverseByStringSeparator(allocator: Allocator, data: []const u8, sep: []const u8, before: bool, writer: anytype) !void {
    var records = std.ArrayListUnmanaged([]const u8){};
    defer records.deinit(allocator);

    if (before) {
        // In -b mode, the separator is prepended to each record.
        // For "a<>b<>c<>", records are: "a", "<>b", "<>c", "<>"
        var start: usize = 0;
        var pos: usize = 0;
        while (pos + sep.len <= data.len) {
            if (std.mem.eql(u8, data[pos .. pos + sep.len], sep)) {
                if (pos > start) {
                    try records.append(allocator, data[start..pos]);
                    start = pos;
                }
                pos += sep.len;
            } else {
                pos += 1;
            }
        }
        if (start < data.len) {
            try records.append(allocator, data[start..]);
        }
    } else {
        // Default mode: separator trails each record.
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
        if (start < data.len) {
            try records.append(allocator, data[start..]);
        }
    }

    try writeRecordsReversed(records.items, writer);
}

/// Write records in reverse order. Records are already correctly formed
/// (with trailing separators in default mode, or leading separators in -b mode).
fn writeRecordsReversed(records: []const []const u8, writer: anytype) !void {
    if (records.len == 0) return;

    var i: usize = records.len;
    while (i > 0) {
        i -= 1;
        try writer.writeAll(records[i]);
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
    // GNU: printf 'line1\nline2\nline3\n' | tac -b → "\n\nline3\nline2line1"
    // With -b, records are delimited by a preceding separator:
    //   "line1", "\nline2", "\nline3", "\n" (empty trailing)
    // Reversed: "\n", "\nline3", "\nline2", "line1"
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
    try testing.expectEqualStrings("\n\nline3\nline2line1", stdout_buffer.items);
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
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "No such file or directory") != null);
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
    // GNU: printf 'a\nb\nc\n' | tac -b → "\n\nc\nba"
    // With -b, records are delimited by a *preceding* separator:
    //   "a", "\nb", "\nc", "\n" (empty trailing)
    // Reversed: "\n", "\nc", "\nb", "a" → "\n\nc\nba"
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByByteSeparator(testing.allocator, "a\nb\nc\n", '\n', true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("\n\nc\nba", buffer.items);
}

test "tac reverseByStringSeparator basic" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByStringSeparator(testing.allocator, "x<>y<>z<>", "<>", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("z<>y<>x<>", buffer.items);
}

test "tac reverseByStringSeparator with before" {
    // GNU: printf 'a<>b<>c<>' | tac -s '<>' -b → "<><>c<>ba"
    // With -b, records are delimited by a preceding separator:
    //   "a", "<>b", "<>c", "<>" (empty trailing)
    // Reversed: "<>", "<>c", "<>b", "a" → "<><>c<>ba"
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByStringSeparator(testing.allocator, "a<>b<>c<>", "<>", true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("<><>c<>ba", buffer.items);
}

test "tac -b with single-byte custom separator" {
    // GNU: printf 'a:b:c:' | tac -s: -b → "::c:ba"
    // With -b, records delimited by preceding separator:
    //   "a", ":b", ":c", ":" (empty trailing)
    // Reversed: ":", ":c", ":b", "a" → "::c:ba"
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("a:b:c:");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", ":", "-b", test_path };
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("::c:ba", stdout_buffer.items);
}

test "tac -b with multi-byte separator" {
    // GNU: printf 'a<>b<>c<>' | tac -s '<>' -b → "<><>c<>ba"
    // This tests the full runTac path with multi-byte separator + before flag.
    // Bug F57: reverseByStringSeparator passes sep_byte=0, so -b is inert.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("a<>b<>c<>");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "<>", "-b", test_path };
    const result = try runTac(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("<><>c<>ba", stdout_buffer.items);
}

test "tac -b with single-byte separator no trailing separator" {
    // GNU: printf 'a:b:c' | tac -s: -b → ":c:ba"
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByByteSeparator(testing.allocator, "a:b:c", ':', true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings(":c:ba", buffer.items);
}

test "tac -b with multi-byte separator no trailing separator" {
    // GNU: printf 'a<>b<>c' | tac -s '<>' -b | od -c shows: "<>c<>ba"
    // Records: "a", "<>b", "<>c" (no trailing) → reversed: "<>c", "<>b", "a" → "<>c<>ba"
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByStringSeparator(testing.allocator, "a<>b<>c", "<>", true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("<>c<>ba", buffer.items);
}

test "tac reverseByByteSeparator with before single-byte custom sep" {
    // GNU: printf 'a:b:c:' | tac -s: -b → "::c:ba"
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    try reverseByByteSeparator(testing.allocator, "a:b:c:", ':', true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("::c:ba", buffer.items);
}
