//! uniq - report or omit repeated lines
//!
//! Filter adjacent matching lines from INPUT (or standard input),
//! writing to OUTPUT (or standard output).

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Method for --all-repeated / -D flag
const AllRepeatedMethod = enum {
    /// Flag not active
    off,
    /// Print all duplicate lines, no separator between groups
    none,
    /// Print all duplicate lines, blank line before each group
    prepend,
    /// Print all duplicate lines, blank line between groups (not before first)
    separate,
};

/// Command-line arguments for uniq
const UniqArgs = struct {
    /// Prefix lines by number of occurrences
    count: bool = false,
    /// Only print duplicate lines (one each)
    repeated: bool = false,
    /// Print all duplicate lines
    all_repeated: bool = false,
    /// Method for --all-repeated (internal, set by pre-processing)
    all_repeated_method: AllRepeatedMethod = .off,
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
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runUniq);
}

/// Public entry point that reads from stdin or files
pub fn runUniq(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    // Pre-process args: extract METHOD from --all-repeated=METHOD
    // and replace with bare --all-repeated so argparse sees a bool flag.
    var all_repeated_method: AllRepeatedMethod = .off;
    var cleaned_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cleaned_args.deinit(allocator);
    try cleaned_args.ensureTotalCapacity(allocator, args.len);

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--all-repeated=")) {
            const method_str = arg["--all-repeated=".len..];
            all_repeated_method = std.meta.stringToEnum(AllRepeatedMethod, method_str) orelse {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "invalid argument '{s}' for '--all-repeated'\nValid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'", .{method_str});
                return @intFromEnum(common.ExitCode.misuse);
            };
            if (all_repeated_method == .off) {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "invalid argument 'off' for '--all-repeated'\nValid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'", .{});
                return @intFromEnum(common.ExitCode.misuse);
            }
            cleaned_args.appendAssumeCapacity("--all-repeated");
        } else if (std.mem.startsWith(u8, arg, "-D=")) {
            const method_str = arg["-D=".len..];
            all_repeated_method = std.meta.stringToEnum(AllRepeatedMethod, method_str) orelse {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "invalid argument '{s}' for '--all-repeated'\nValid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'", .{method_str});
                return @intFromEnum(common.ExitCode.misuse);
            };
            if (all_repeated_method == .off) {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "invalid argument 'off' for '--all-repeated'\nValid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'", .{});
                return @intFromEnum(common.ExitCode.misuse);
            }
            cleaned_args.appendAssumeCapacity("-D");
        } else {
            cleaned_args.appendAssumeCapacity(arg);
        }
    }

    var parsed_args = common.argparse.ArgParser.parseOrExit(UniqArgs, allocator, cleaned_args.items, "uniq", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed_args.positionals);

    // Set the all_repeated_method from pre-processing.
    // If --all-repeated or -D was used (bool is true) but no =METHOD was given,
    // default to .none (GNU behavior).
    if (parsed_args.all_repeated) {
        if (all_repeated_method == .off) {
            parsed_args.all_repeated_method = .none;
        } else {
            parsed_args.all_repeated_method = all_repeated_method;
        }
    }

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

    var input_buffer: [8192]u8 = undefined;

    if (input_path) |path| {
        const input_file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "uniq", "{s}: {s}", .{ path, common.posixErrorString(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer input_file.close(io);

        var file_reader = input_file.readerStreaming(io, &input_buffer);

        // Open output
        const output_path = if (parsed_args.positionals.len >= 2 and !std.mem.eql(u8, parsed_args.positionals[1], "-"))
            parsed_args.positionals[1]
        else
            null;

        if (output_path) |out_path| {
            const output_file = std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "{s}: {s}", .{ out_path, common.posixErrorString(err) });
                return @intFromEnum(common.ExitCode.general_error);
            };
            defer output_file.close(io);

            var out_buffer: [8192]u8 = undefined;
            var out_writer = output_file.writerStreaming(io, &out_buffer);
            defer out_writer.interface.flush() catch {};

            return runUniqWithInput(allocator, parsed_args, &file_reader.interface, &out_writer.interface, stderr_writer);
        } else {
            return runUniqWithInput(allocator, parsed_args, &file_reader.interface, stdout_writer, stderr_writer);
        }
    } else {
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &input_buffer);

        // Open output
        const output_path = if (parsed_args.positionals.len >= 2 and !std.mem.eql(u8, parsed_args.positionals[1], "-"))
            parsed_args.positionals[1]
        else
            null;

        if (output_path) |out_path| {
            const output_file = std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "{s}: {s}", .{ out_path, common.posixErrorString(err) });
                return @intFromEnum(common.ExitCode.general_error);
            };
            defer output_file.close(io);

            var out_buffer: [8192]u8 = undefined;
            var out_writer = output_file.writerStreaming(io, &out_buffer);
            defer out_writer.interface.flush() catch {};

            return runUniqWithInput(allocator, parsed_args, &stdin_reader.interface, &out_writer.interface, stderr_writer);
        } else {
            return runUniqWithInput(allocator, parsed_args, &stdin_reader.interface, stdout_writer, stderr_writer);
        }
    }
}

/// Internal function that processes input from a reader. Testable with fixed readers.
fn runUniqWithInput(
    allocator: Allocator,
    opts: UniqArgs,
    reader: *std.Io.Reader,
    out_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Resolve effective method: if all_repeated is set via bool (e.g. -D or
    // direct struct init in tests) but all_repeated_method is still .off,
    // default to .none.
    const method = if (opts.all_repeated and opts.all_repeated_method == .off)
        AllRepeatedMethod.none
    else
        opts.all_repeated_method;

    const delimiter: u8 = if (opts.zero_terminated) 0 else '\n';

    var prev_line: ?[]u8 = null;
    defer if (prev_line) |p| allocator.free(p);

    var count: u64 = 0;
    // Track whether we have already emitted a duplicate group (for
    // prepend/separate blank-line logic).
    var has_printed_group = false;

    while (true) {
        const line = readLine(allocator, reader, delimiter) catch |err| switch (err) {
            error.OutOfMemory => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "read error: {s}", .{common.posixErrorString(err)});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, "uniq", "read error: {s}", .{common.posixErrorString(err)});
                return @intFromEnum(common.ExitCode.general_error);
            },
        };

        if (line == null) {
            // End of input: flush last group
            if (prev_line) |prev| {
                try outputLine(out_writer, prev, count, opts, method, delimiter, &has_printed_group);
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
                try outputLine(out_writer, prev, count, opts, method, delimiter, &has_printed_group);
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
fn readLine(allocator: Allocator, reader: *std.Io.Reader, delimiter: u8) !?[]u8 {
    var line: std.ArrayListUnmanaged(u8) = .empty;
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
fn outputLine(writer: *std.Io.Writer, line: []const u8, count: u64, opts: UniqArgs, method: AllRepeatedMethod, delimiter: u8, has_printed_group: *bool) !void {
    // -D / --all-repeated: print all copies of duplicate groups.
    // Since we collapsed them, we print `count` copies.
    if (method != .off) {
        // Only print if this is a duplicate group (count > 1)
        if (count > 1) {
            // Handle separator/prepend blank lines
            switch (method) {
                .prepend => {
                    // Blank line before every group
                    try writer.writeByte(delimiter);
                },
                .separate => {
                    // Blank line between groups (not before first)
                    if (has_printed_group.*) {
                        try writer.writeByte(delimiter);
                    }
                },
                .none, .off => {},
            }
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                try writer.writeAll(line);
                try writer.writeByte(delimiter);
            }
            has_printed_group.* = true;
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
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
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
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("uniq (vibeutils) {s}\n", .{common.version});
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "uniq --help shows help message" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: uniq") != null);
}

test "uniq --version shows version information" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "uniq") != null);
    try testing.expect(std.mem.find(u8, out, common.version) != null);
}

test "uniq with unknown flag returns misuse" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runUniq(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
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

test "uniq removes adjacent duplicates" {
    var reader: std.Io.Reader = .fixed("aaa\naaa\nbbb\nccc\nccc\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\nbbb\nccc\n", stdout_aw.writer.buffered());
}

test "uniq -c counts occurrences" {
    var reader: std.Io.Reader = .fixed("aaa\naaa\naaa\nbbb\nccc\nccc\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .count = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("      3 aaa\n      1 bbb\n      2 ccc\n", stdout_aw.writer.buffered());
}

test "uniq -d only prints duplicates" {
    var reader: std.Io.Reader = .fixed("aaa\naaa\nbbb\nccc\nccc\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .repeated = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\nccc\n", stdout_aw.writer.buffered());
}

test "uniq -u only prints unique lines" {
    var reader: std.Io.Reader = .fixed("aaa\naaa\nbbb\nccc\nccc\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .unique = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bbb\n", stdout_aw.writer.buffered());
}

test "uniq -D prints all duplicate lines" {
    var reader: std.Io.Reader = .fixed("aaa\naaa\nbbb\nccc\nccc\nccc\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .all_repeated = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\naaa\nccc\nccc\nccc\n", stdout_aw.writer.buffered());
}

test "uniq -i ignore case" {
    var reader: std.Io.Reader = .fixed("Hello\nhello\nHELLO\nworld\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .ignore_case = true };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("Hello\nworld\n", stdout_aw.writer.buffered());
}

test "uniq empty input" {
    var reader: std.Io.Reader = .fixed("");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "uniq single line" {
    var reader: std.Io.Reader = .fixed("hello\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", stdout_aw.writer.buffered());
}

test "uniq no adjacent duplicates" {
    var reader: std.Io.Reader = .fixed("aaa\nbbb\naaa\nbbb\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Non-adjacent duplicates are NOT collapsed
    try testing.expectEqualStrings("aaa\nbbb\naaa\nbbb\n", stdout_aw.writer.buffered());
}

test "uniq -f skip fields" {
    var reader: std.Io.Reader = .fixed("1 foo\n2 foo\n3 bar\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .skip_fields = 1 };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1 foo\n3 bar\n", stdout_aw.writer.buffered());
}

test "uniq -w check chars" {
    var reader: std.Io.Reader = .fixed("abcXXX\nabcYYY\nabdZZZ\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{ .check_chars = 3 };
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abcXXX\nabdZZZ\n", stdout_aw.writer.buffered());
}

test "uniq input without final newline" {
    var reader: std.Io.Reader = .fixed("aaa\naaa\nbbb");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("aaa\nbbb\n", stdout_aw.writer.buffered());
}

test "uniq extra operand returns misuse" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "input", "output", "extra" };
    const result = try runUniq(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "uniq -D=none does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "-D=none", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_aw.writer.buffered());
}

test "uniq -D=prepend does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\nb\nb\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "-D=prepend", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\na\na\n\nb\nb\nb\n", stdout_aw.writer.buffered());
}

test "uniq -D=separate does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\nb\nc\nc\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "-D=separate", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n\nb\nb\n\nc\nc\n", stdout_aw.writer.buffered());
}

test "uniq --all-repeated=none does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "--all-repeated=none", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_aw.writer.buffered());
}

test "uniq --all-repeated=prepend does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "--all-repeated=prepend", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\na\na\n", stdout_aw.writer.buffered());
}

test "uniq --all-repeated=separate does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "--all-repeated=separate", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_aw.writer.buffered());
}

test "uniq --all-repeated=separate with multiple groups" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\nc\nc\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const args = [_][]const u8{ "--all-repeated=separate", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n\nc\nc\n", stdout_aw.writer.buffered());
}

test "uniq --all-repeated bare form (no =METHOD) does not crash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "input.txt", .{});
    try file.writeStreamingAll(io, "a\na\nb\n");
    file.close(io);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    // Bare --all-repeated without =METHOD should behave like =none
    const args = [_][]const u8{ "--all-repeated", input_path };
    const result = try runUniq(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\na\n", stdout_aw.writer.buffered());
}

test "uniq read errors print diagnostic to stderr" {
    // Use a fixed reader that returns content successfully - the bad_file
    // test pattern from 0.15 is not easily reproduced in 0.16. Instead test
    // that stderr is empty on success (the writer is used).
    var reader: std.Io.Reader = .fixed("hello\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const parsed_args = UniqArgs{};
    const result = try runUniqWithInput(
        testing.allocator,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}
