//! uniq - report or omit repeated lines
//!
//! Filter adjacent matching lines from INPUT (or standard input),
//! writing to OUTPUT (or standard output).

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Command-line arguments for uniq
const UniqArgs = struct {
    /// Prefix lines by number of occurrences
    count: bool = false,
    /// Only print duplicate lines (one each)
    repeated: bool = false,
    /// Print all duplicate lines
    all_repeated: bool = false,
    /// Skip N fields before comparing
    skip_fields: ?u32 = null,
    /// Ignore case when comparing
    ignore_case: bool = false,
    /// Skip N characters after fields before comparing
    skip_chars: ?u32 = null,
    /// Only print unique lines
    unique: bool = false,
    /// Compare no more than N characters
    check_chars: ?u32 = null,
    /// Use NUL as line delimiter instead of newline
    zero_terminated: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Positional arguments: [INPUT [OUTPUT]]
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .count = .{ .short = 'c', .desc = "Prefix lines by the number of occurrences" },
        .repeated = .{ .short = 'd', .desc = "Only print duplicate lines, one for each group" },
        .all_repeated = .{ .short = 'D', .desc = "Print all duplicate lines" },
        .skip_fields = .{ .short = 'f', .desc = "Avoid comparing the first N fields", .value_name = "N" },
        .ignore_case = .{ .short = 'i', .desc = "Ignore differences in case when comparing" },
        .skip_chars = .{ .short = 's', .desc = "Avoid comparing the first N characters", .value_name = "N" },
        .unique = .{ .short = 'u', .desc = "Only print unique lines" },
        .check_chars = .{ .short = 'w', .desc = "Compare no more than N characters in lines", .value_name = "N" },
        .zero_terminated = .{ .short = 'z', .desc = "Line delimiter is NUL, not newline" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
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

    const exit_code = try runUniq(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Public entry point that reads from stdin
pub fn runUniq(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const parsed_args = common.argparse.ArgParser.parse(UniqArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "invalid option\nTry 'uniq --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "option requires an argument\nTry 'uniq --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "invalid argument value\nTry 'uniq --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate positional count: at most 2 (INPUT, OUTPUT)
    if (parsed_args.positionals.len > 2) {
        common.printErrorWithProgram(allocator, stderr_writer, "uniq", "extra operand '{s}'\nTry 'uniq --help' for more information.", .{parsed_args.positionals[2]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Open input
    const input_path = if (parsed_args.positionals.len >= 1 and !std.mem.eql(u8, parsed_args.positionals[0], "-"))
        parsed_args.positionals[0]
    else
        null;

    const input_file = if (input_path) |path|
        std.fs.cwd().openFile(path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "uniq", "{s}: {s}", .{ path, @errorName(err) });
            return @intFromEnum(common.ExitCode.general_error);
        }
    else
        std.fs.File.stdin();

    defer if (input_path != null) input_file.close();

    // Open output
    const output_path = if (parsed_args.positionals.len >= 2 and !std.mem.eql(u8, parsed_args.positionals[1], "-"))
        parsed_args.positionals[1]
    else
        null;

    if (output_path) |path| {
        const output_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "uniq", "{s}: {s}", .{ path, @errorName(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer output_file.close();

        var out_buffer: [8192]u8 = undefined;
        var out_writer = output_file.writer(&out_buffer);
        const out = &out_writer.interface;
        defer out.flush() catch {};

        return runUniqWithInput(allocator, parsed_args, input_file, out, stderr_writer);
    } else {
        return runUniqWithInput(allocator, parsed_args, input_file, stdout_writer, stderr_writer);
    }
}

/// Internal function that processes input. Testable with mock input.
fn runUniqWithInput(
    allocator: Allocator,
    opts: UniqArgs,
    input_file: std.fs.File,
    out_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    const delimiter: u8 = if (opts.zero_terminated) 0 else '\n';

    var input_buffer: [8192]u8 = undefined;
    var reader = input_file.reader(&input_buffer);
    const input = &reader.interface;

    var prev_line: ?[]u8 = null;
    defer if (prev_line) |p| allocator.free(p);

    var count: u64 = 0;

    while (true) {
        const line = readLine(allocator, input, delimiter) catch |err| switch (err) {
            error.OutOfMemory => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "read error: {s}", .{@errorName(err)});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "read error: {s}", .{@errorName(err)});
                return @intFromEnum(common.ExitCode.general_error);
            },
        };

        if (line == null) {
            // End of input: flush last group
            if (prev_line) |prev| {
                try outputLine(out_writer, prev, count, opts, delimiter);
            }
            break;
        }

        const current = line.?;

        if (prev_line) |prev| {
            if (linesEqual(prev, current, opts)) {
                count += 1;
                allocator.free(current);
            } else {
                // Group boundary: output the previous group
                try outputLine(out_writer, prev, count, opts, delimiter);
                allocator.free(prev);
                prev_line = current;
                count = 1;
            }
        } else {
            prev_line = current;
            count = 1;
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Read one line delimited by `delimiter`. Returns null on EOF.
/// Caller owns the returned slice.
fn readLine(allocator: Allocator, reader: anytype, delimiter: u8) !?[]u8 {
    var line = std.ArrayListUnmanaged(u8){};
    errdefer line.deinit(allocator);

    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (line.items.len == 0) {
                    line.deinit(allocator);
                    return null;
                }
                return try line.toOwnedSlice(allocator);
            },
            else => return err,
        };

        if (byte == delimiter) {
            return try line.toOwnedSlice(allocator);
        }
        try line.append(allocator, byte);
    }
}

/// Compare two lines according to uniq options (skip fields, skip chars,
/// check chars, ignore case).
fn linesEqual(a: []const u8, b: []const u8, opts: UniqArgs) bool {
    const a_cmp = getCompareSlice(a, opts);
    const b_cmp = getCompareSlice(b, opts);

    if (opts.ignore_case) {
        return std.ascii.eqlIgnoreCase(a_cmp, b_cmp);
    } else {
        return std.mem.eql(u8, a_cmp, b_cmp);
    }
}

/// Extract the comparison portion of a line after applying skip_fields,
/// skip_chars, and check_chars.
fn getCompareSlice(line: []const u8, opts: UniqArgs) []const u8 {
    var pos: usize = 0;

    // Skip fields: fields are runs of blanks then non-blanks
    if (opts.skip_fields) |n| {
        var fields_skipped: u32 = 0;
        while (fields_skipped < n and pos < line.len) {
            // Skip leading blanks
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) {
                pos += 1;
            }
            // Skip non-blanks
            while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') {
                pos += 1;
            }
            fields_skipped += 1;
        }
    }

    // Skip chars
    if (opts.skip_chars) |n| {
        const skip = @min(n, @as(u32, @intCast(line.len -| pos)));
        pos += skip;
    }

    if (pos >= line.len) return "";

    const remaining = line[pos..];

    // Limit comparison to check_chars characters
    if (opts.check_chars) |n| {
        const limit = @min(n, @as(u32, @intCast(remaining.len)));
        return remaining[0..limit];
    }

    return remaining;
}

/// Output a line (or not) according to count/repeated/unique/all_repeated flags.
fn outputLine(writer: anytype, line: []const u8, count: u64, opts: UniqArgs, delimiter: u8) !void {
    // -D (all_repeated): handled differently -- we need to print all copies.
    // However, since we collapsed them already, for -D we print `count` copies.
    if (opts.all_repeated) {
        // Only print if this is a duplicate group (count > 1)
        if (count > 1) {
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                try writer.writeAll(line);
                try writer.writeByte(delimiter);
            }
        }
        return;
    }

    // -d (repeated): only groups that appeared more than once, print once
    if (opts.repeated) {
        if (count <= 1) return;
    }

    // -u (unique): only groups that appeared exactly once
    if (opts.unique) {
        if (count != 1) return;
    }

    // -c (count): prefix with count
    if (opts.count) {
        try writer.print("{d: >7} ", .{count});
    }

    try writer.writeAll(line);
    try writer.writeByte(delimiter);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: uniq [OPTION]... [INPUT [OUTPUT]]
        \\Filter adjacent matching lines from INPUT (or standard input),
        \\writing to OUTPUT (or standard output).
        \\
        \\With no options, matching lines are merged to the first occurrence.
        \\
        \\  -c, --count           prefix lines by the number of occurrences
        \\  -d, --repeated        only print duplicate lines, one for each group
        \\  -D                    print all duplicate lines
        \\  -f, --skip-fields=N   avoid comparing the first N fields
        \\  -i, --ignore-case     ignore differences in case when comparing
        \\  -s, --skip-chars=N    avoid comparing the first N characters
        \\  -u, --unique          only print unique lines
        \\  -w, --check-chars=N   compare no more than N characters in lines
        \\  -z, --zero-terminated  line delimiter is NUL, not newline
        \\  -h, --help            display this help and exit
        \\  -V, --version         output version information and exit
        \\
        \\A field is a run of blanks (usually spaces and/or TABs), then
        \\non-blank characters. Fields are skipped before chars.
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("uniq (vibeutils) {s}\n", .{common.version});
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "uniq --help shows help message" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runUniq(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: uniq") != null);
}

test "uniq --version shows version information" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runUniq(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "uniq") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.version) != null);
}

test "uniq with unknown flag returns misuse" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runUniq(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "uniq getCompareSlice no options" {
    const opts = UniqArgs{};
    const result = getCompareSlice("hello world", opts);
    try testing.expectEqualStrings("hello world", result);
}

test "uniq getCompareSlice skip fields" {
    const opts = UniqArgs{ .skip_fields = 1 };
    const result = getCompareSlice("field1 field2 field3", opts);
    try testing.expectEqualStrings(" field2 field3", result);
}

test "uniq getCompareSlice skip fields with leading blanks" {
    const opts = UniqArgs{ .skip_fields = 1 };
    const result = getCompareSlice("  field1 field2", opts);
    try testing.expectEqualStrings(" field2", result);
}

test "uniq getCompareSlice skip chars" {
    const opts = UniqArgs{ .skip_chars = 5 };
    const result = getCompareSlice("hello world", opts);
    try testing.expectEqualStrings(" world", result);
}

test "uniq getCompareSlice check chars" {
    const opts = UniqArgs{ .check_chars = 5 };
    const result = getCompareSlice("hello world", opts);
    try testing.expectEqualStrings("hello", result);
}

test "uniq getCompareSlice skip fields and chars combined" {
    const opts = UniqArgs{ .skip_fields = 1, .skip_chars = 2 };
    const result = getCompareSlice("field1 field2 field3", opts);
    try testing.expectEqualStrings("ield2 field3", result);
}

test "uniq getCompareSlice skip more fields than exist" {
    const opts = UniqArgs{ .skip_fields = 10 };
    const result = getCompareSlice("only two", opts);
    try testing.expectEqualStrings("", result);
}

test "uniq getCompareSlice skip more chars than exist" {
    const opts = UniqArgs{ .skip_chars = 100 };
    const result = getCompareSlice("short", opts);
    try testing.expectEqualStrings("", result);
}

test "uniq linesEqual basic" {
    const opts = UniqArgs{};
    try testing.expect(linesEqual("hello", "hello", opts));
    try testing.expect(!linesEqual("hello", "world", opts));
}

test "uniq linesEqual ignore case" {
    const opts = UniqArgs{ .ignore_case = true };
    try testing.expect(linesEqual("Hello", "hello", opts));
    try testing.expect(linesEqual("HELLO", "hello", opts));
    try testing.expect(!linesEqual("hello", "world", opts));
}

test "uniq linesEqual with skip fields" {
    const opts = UniqArgs{ .skip_fields = 1 };
    try testing.expect(linesEqual("a same", "b same", opts));
    try testing.expect(!linesEqual("a same", "b diff", opts));
}

test "uniq linesEqual with check chars" {
    const opts = UniqArgs{ .check_chars = 3 };
    try testing.expect(linesEqual("abcXXX", "abcYYY", opts));
    try testing.expect(!linesEqual("abcXXX", "abdYYY", opts));
}

test "uniq removes adjacent duplicates from file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\nbbb\nccc\nccc\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\nbbb\nccc\n", stdout_buffer.items);
}

test "uniq -c counts occurrences" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\naaa\nbbb\nccc\nccc\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .count = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("      3 aaa\n      1 bbb\n      2 ccc\n", stdout_buffer.items);
}

test "uniq -d only prints duplicates" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\nbbb\nccc\nccc\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .repeated = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\nccc\n", stdout_buffer.items);
}

test "uniq -u only prints unique lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\nbbb\nccc\nccc\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .unique = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bbb\n", stdout_buffer.items);
}

test "uniq -D prints all duplicate lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\nbbb\nccc\nccc\nccc\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .all_repeated = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\naaa\nccc\nccc\nccc\n", stdout_buffer.items);
}

test "uniq -i ignore case" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("Hello\nhello\nHELLO\nworld\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .ignore_case = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("Hello\nworld\n", stdout_buffer.items);
}

test "uniq empty input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items);
}

test "uniq single line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("hello\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", stdout_buffer.items);
}

test "uniq no adjacent duplicates" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\nbbb\naaa\nbbb\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    // Non-adjacent duplicates are NOT collapsed
    try testing.expectEqualStrings("aaa\nbbb\naaa\nbbb\n", stdout_buffer.items);
}

test "uniq -f skip fields" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("1 foo\n2 foo\n3 bar\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .skip_fields = 1 };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1 foo\n3 bar\n", stdout_buffer.items);
}

test "uniq -w check chars" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("abcXXX\nabcYYY\nabdZZZ\n");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{ .check_chars = 3 };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abcXXX\nabdZZZ\n", stdout_buffer.items);
}

test "uniq input without final newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aaa\naaa\nbbb");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\nbbb\n", stdout_buffer.items);
}

test "uniq extra operand returns misuse" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "input", "output", "extra" };
    const result = try runUniq(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "extra operand") != null);
}

test "uniq --all-repeated=none does not crash" {
    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    // Create a temp file with input "a\na\nb\n"
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("a\na\nb\n");
    input_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const input_path = try tmp_dir.dir.realpath("input.txt", &path_buf);

    const args = [_][]const u8{ "--all-repeated=none", input_path };
    const result = try runUniq(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // GNU outputs "a\na\n" and exits 0
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_buffer.items);
}

test "uniq --all-repeated=prepend does not crash" {
    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("a\na\nb\n");
    input_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const input_path = try tmp_dir.dir.realpath("input.txt", &path_buf);

    const args = [_][]const u8{ "--all-repeated=prepend", input_path };
    const result = try runUniq(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // GNU outputs "\na\na\n" and exits 0
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\na\na\n", stdout_buffer.items);
}

test "uniq --all-repeated=separate does not crash" {
    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("a\na\nb\n");
    input_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const input_path = try tmp_dir.dir.realpath("input.txt", &path_buf);

    const args = [_][]const u8{ "--all-repeated=separate", input_path };
    const result = try runUniq(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // GNU outputs "a\na\n" and exits 0
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_buffer.items);
}

test "uniq --all-repeated=separate with multiple groups" {
    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("a\na\nb\nc\nc\n");
    input_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const input_path = try tmp_dir.dir.realpath("input.txt", &path_buf);

    const args = [_][]const u8{ "--all-repeated=separate", input_path };
    const result = try runUniq(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // GNU outputs "a\na\n\nc\nc\n" (empty line between groups)
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n\nc\nc\n", stdout_buffer.items);
}

test "uniq --all-repeated bare form (no =METHOD) does not crash" {
    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("a\na\nb\n");
    input_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const input_path = try tmp_dir.dir.realpath("input.txt", &path_buf);

    // Bare --all-repeated without =METHOD should behave like =none
    const args = [_][]const u8{ "--all-repeated", input_path };
    const result = try runUniq(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_buffer.items);
}

test "uniq read errors print diagnostic to stderr" {
    // Create a valid file, then close its handle so reads will fail.
    // runUniqWithInput should write a diagnostic to stderr, but
    // the bug (line 164: _ = stderr_writer) means stderr stays empty.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try tmp_file.writeAll("hello\n");
    // Close the handle to make subsequent reads fail
    tmp_file.close();

    // Create a File struct with the now-invalid handle
    const bad_file = std.fs.File{ .handle = tmp_file.handle };

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        bad_file,
        stdout_buffer.writer(testing.allocator),
        stderr_buffer.writer(testing.allocator),
    );

    // Should return non-zero exit code
    try testing.expectEqual(@as(u8, 1), result);
    // Should have written a diagnostic message to stderr.
    // This assertion will FAIL because runUniqWithInput discards stderr_writer.
    try testing.expect(stderr_buffer.items.len > 0);
}
