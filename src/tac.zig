//! tac - concatenate and print files in reverse
//!
//! Write each FILE to standard output, last line first.
//! With no FILE, or when FILE is -, read standard input.
//! By default, lines are delimited by newline characters.

const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
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
        .separator = .{
            .short = 's',
            .desc = "Use STRING as separator instead of newline",
            .value_name = "STRING",
        },
    };
};

/// Main entry point
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTac);
}

/// Public API that reads from stdin when no files given
pub fn runTac(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parseOrExit(
        TacArgs,
        allocator,
        args,
        "tac",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
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
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tac",
            "-r (--regex) is not supported",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    const separator = parsed.separator orelse "\n";
    const files = parsed.positionals;

    if (files.len == 0) {
        // Read from stdin
        const stdin_file = std.Io.File.stdin();
        return runTacOnInput(
            allocator,
            io,
            stdin_file,
            separator,
            parsed.before,
            stdout_writer,
            stderr_writer,
        );
    }

    return runTacOnFiles(
        allocator,
        io,
        files,
        separator,
        parsed.before,
        stdout_writer,
        stderr_writer,
    );
}

/// Process each named file (or stdin for "-") and combine exit codes
fn runTacOnFiles(
    allocator: Allocator,
    io: std.Io,
    files: []const []const u8,
    separator: []const u8,
    before: bool,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var has_error = false;
    for (files) |file_path| {
        if (std.mem.eql(u8, file_path, "-")) {
            const stdin_file = std.Io.File.stdin();
            const rc = try runTacOnInput(
                allocator,
                io,
                stdin_file,
                separator,
                before,
                stdout_writer,
                stderr_writer,
            );
            if (rc != 0) has_error = true;
        } else {
            const rc = try runTacOnFile(
                allocator,
                io,
                file_path,
                separator,
                before,
                stdout_writer,
                stderr_writer,
            );
            if (rc != 0) has_error = true;
        }
    }

    return if (has_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
}

/// Process a named file
fn runTacOnFile(
    allocator: Allocator,
    io: std.Io,
    file_path: []const u8,
    separator: []const u8,
    before: bool,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tac",
            "failed to open '{s}' for reading: {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer file.close(io);

    return runTacOnInput(allocator, io, file, separator, before, stdout_writer, stderr_writer);
}

/// Core implementation: read all input, split by separator, output in reverse
fn runTacOnInput(
    allocator: Allocator,
    io: std.Io,
    input_file: std.Io.File,
    separator: []const u8,
    before: bool,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = stderr_writer;

    // Read all input into memory
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    var read_buf: [8192]u8 = undefined;
    var file_reader = input_file.readerStreaming(io, &read_buf);
    const reader = &file_reader.interface;
    while (true) { // tiger:allow:unbounded-loop terminates at EOF (readSliceShort == 0 -> break)
        var chunk: [4096]u8 = undefined;
        const bytes_read = reader.readSliceShort(&chunk) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        // readSliceShort reads at most chunk.len bytes; guards the slice below.
        std.debug.assert(bytes_read <= chunk.len);
        if (bytes_read == 0) break;
        try content.appendSlice(allocator, chunk[0..bytes_read]);
    }

    if (content.items.len == 0) {
        return @intFromEnum(common.ExitCode.success);
    }

    // The empty-content early return above guarantees a non-empty buffer here.
    std.debug.assert(content.items.len > 0);

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
fn reverseByByteSeparator(
    allocator: Allocator,
    data: []const u8,
    sep: u8,
    before: bool,
    writer: *std.Io.Writer,
) !void {
    var records: std.ArrayListUnmanaged([]const u8) = .empty;
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
        // Remaining content from start to end.
        // start is only ever assigned i where i < data.len, so start <= data.len.
        std.debug.assert(start <= data.len);
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
        // start is only ever assigned i + 1 where i < data.len, so start <= data.len.
        std.debug.assert(start <= data.len);
        if (start < data.len) {
            try records.append(allocator, data[start..]);
        }
    }

    // Write records in reverse order
    try writeRecordsReversed(records.items, writer);
}

/// Reverse records delimited by a multi-byte string
fn reverseByStringSeparator(
    allocator: Allocator,
    data: []const u8,
    sep: []const u8,
    before: bool,
    writer: *std.Io.Writer,
) !void {
    // Caller dispatches the len==0 and len==1 cases to reverseByByteSeparator;
    // a multi-byte separator is required so the match loop makes progress.
    std.debug.assert(sep.len >= 2);

    var records: std.ArrayListUnmanaged([]const u8) = .empty;
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
        // The while guard keeps pos + sep.len <= data.len at every match, and
        // start is only assigned pos there, so start <= data.len.
        std.debug.assert(start <= data.len);
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
        // The while guard keeps pos + sep.len <= data.len at every match, and
        // start is only assigned pos + sep.len there, so start <= data.len.
        std.debug.assert(start <= data.len);
        if (start < data.len) {
            try records.append(allocator, data[start..]);
        }
    }

    try writeRecordsReversed(records.items, writer);
}

/// Write records in reverse order. Records are already correctly formed
/// (with trailing separators in default mode, or leading separators in -b mode).
fn writeRecordsReversed(records: []const []const u8, writer: *std.Io.Writer) !void {
    if (records.len == 0) return;

    var i: usize = records.len;
    while (i > 0) {
        i -= 1;
        // i starts at records.len and the loop only enters when i > 0, so after
        // the decrement i is a valid index into records.
        std.debug.assert(i < records.len);
        try writer.writeAll(records[i]);
    }
}

/// Print help message
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
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
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("tac ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "tac --help shows help message" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: tac") != null);
}

test "tac --version shows version information" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "tac") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.version) != null);
}

test "tac with unknown flag returns exit code 1" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runTac(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const found_unrecognized =
        std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") != null;
    try testing.expect(found_unrecognized);
}

test "tac -r returns error (unsupported)" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-r"};
    const result = try runTac(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "not supported") != null);
}

test "tac reverses lines of a file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "line1\nline2\nline3\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("line3\nline2\nline1\n", stdout_aw.writer.buffered());
}

test "tac reverses lines without trailing newline" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "line1\nline2\nline3");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("line3line2\nline1\n", stdout_aw.writer.buffered());
}

test "tac handles single line" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "only line\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("only line\n", stdout_aw.writer.buffered());
}

test "tac handles empty file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{test_path};
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "tac with custom separator" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "a:b:c:");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", ":", test_path };
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("c:b:a:", stdout_aw.writer.buffered());
}

test "tac with multi-byte separator" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "one<>two<>three<>");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "<>", test_path };
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("three<>two<>one<>", stdout_aw.writer.buffered());
}

test "tac with --before flag" {
    // GNU: printf 'line1\nline2\nline3\n' | tac -b → "\n\nline3\nline2line1"
    // With -b, records are delimited by a preceding separator:
    //   "line1", "\nline2", "\nline3", "\n" (empty trailing)
    // Reversed: "\n", "\nline3", "\nline2", "line1"
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "line1\nline2\nline3\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-b", test_path };
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n\nline3\nline2line1", stdout_aw.writer.buffered());
}

test "tac with multiple files" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file1 = try tmp_dir.dir().createFile(io, "a.txt", .{});
    try file1.writeStreamingAll(io, "a1\na2\n");
    file1.close(io);

    const file2 = try tmp_dir.dir().createFile(io, "b.txt", .{});
    try file2.writeStreamingAll(io, "b1\nb2\n");
    file2.close(io);

    var path_buf1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path1_len = try tmp_dir.dir().realPathFile(io, "a.txt", &path_buf1);
    const path1 = path_buf1[0..path1_len];
    var path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path2_len = try tmp_dir.dir().realPathFile(io, "b.txt", &path_buf2);
    const path2 = path_buf2[0..path2_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ path1, path2 };
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Each file is reversed independently
    try testing.expectEqualStrings("a2\na1\nb2\nb1\n", stdout_aw.writer.buffered());
}

test "tac with nonexistent file returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent/file.txt"};
    const result = try runTac(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const found_no_such_file =
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null;
    try testing.expect(found_no_such_file);
}

test "tac reverseByByteSeparator basic" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByByteSeparator(testing.allocator, "a\nb\nc\n", '\n', false, &stdout_aw.writer);
    try testing.expectEqualStrings("c\nb\na\n", stdout_aw.writer.buffered());
    _ = io;
}

test "tac reverseByByteSeparator no trailing separator" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByByteSeparator(testing.allocator, "a\nb\nc", '\n', false, &stdout_aw.writer);
    try testing.expectEqualStrings("cb\na\n", stdout_aw.writer.buffered());
    _ = io;
}

test "tac reverseByByteSeparator with before" {
    // GNU: printf 'a\nb\nc\n' | tac -b → "\n\nc\nba"
    // With -b, records are delimited by a *preceding* separator:
    //   "a", "\nb", "\nc", "\n" (empty trailing)
    // Reversed: "\n", "\nc", "\nb", "a" → "\n\nc\nba"
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByByteSeparator(testing.allocator, "a\nb\nc\n", '\n', true, &stdout_aw.writer);
    try testing.expectEqualStrings("\n\nc\nba", stdout_aw.writer.buffered());
    _ = io;
}

test "tac reverseByStringSeparator basic" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByStringSeparator(testing.allocator, "x<>y<>z<>", "<>", false, &stdout_aw.writer);
    try testing.expectEqualStrings("z<>y<>x<>", stdout_aw.writer.buffered());
    _ = io;
}

test "tac reverseByStringSeparator with before" {
    // GNU: printf 'a<>b<>c<>' | tac -s '<>' -b → "<><>c<>ba"
    // With -b, records are delimited by a preceding separator:
    //   "a", "<>b", "<>c", "<>" (empty trailing)
    // Reversed: "<>", "<>c", "<>b", "a" → "<><>c<>ba"
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByStringSeparator(testing.allocator, "a<>b<>c<>", "<>", true, &stdout_aw.writer);
    try testing.expectEqualStrings("<><>c<>ba", stdout_aw.writer.buffered());
    _ = io;
}

test "tac -b with single-byte custom separator" {
    // GNU: printf 'a:b:c:' | tac -s: -b → "::c:ba"
    // With -b, records delimited by preceding separator:
    //   "a", ":b", ":c", ":" (empty trailing)
    // Reversed: ":", ":c", ":b", "a" → "::c:ba"
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "a:b:c:");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", ":", "-b", test_path };
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("::c:ba", stdout_aw.writer.buffered());
}

test "tac -b with multi-byte separator" {
    // GNU: printf 'a<>b<>c<>' | tac -s '<>' -b → "<><>c<>ba"
    // This tests the full runTac path with multi-byte separator + before flag.
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "a<>b<>c<>");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "<>", "-b", test_path };
    const result = try runTac(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("<><>c<>ba", stdout_aw.writer.buffered());
}

test "tac -b with single-byte separator no trailing separator" {
    // GNU: printf 'a:b:c' | tac -s: -b → ":c:ba"
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByByteSeparator(testing.allocator, "a:b:c", ':', true, &stdout_aw.writer);
    try testing.expectEqualStrings(":c:ba", stdout_aw.writer.buffered());
    _ = io;
}

test "tac -b with multi-byte separator no trailing separator" {
    // GNU: printf 'a<>b<>c' | tac -s '<>' -b | od -c shows: "<>c<>ba"
    // Records: "a", "<>b", "<>c" (no trailing) → reversed: "<>c", "<>b", "a" → "<>c<>ba"
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByStringSeparator(testing.allocator, "a<>b<>c", "<>", true, &stdout_aw.writer);
    try testing.expectEqualStrings("<>c<>ba", stdout_aw.writer.buffered());
    _ = io;
}

test "tac reverseByByteSeparator with before single-byte custom sep" {
    // GNU: printf 'a:b:c:' | tac -s: -b → "::c:ba"
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try reverseByByteSeparator(testing.allocator, "a:b:c:", ':', true, &stdout_aw.writer);
    try testing.expectEqualStrings("::c:ba", stdout_aw.writer.buffered());
    _ = io;
}
