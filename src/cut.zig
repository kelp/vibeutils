//! cut - remove sections from each line of files
//!
//! Supports byte (-b), character (-c), and field (-f) selection
//! with customizable delimiters. POSIX-compliant with GNU extensions.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// A single range (1-indexed, inclusive on both ends)
const Range = struct {
    start: usize, // 1-indexed
    end: usize, // 1-indexed, max_usize means "to end of line"

    const END: usize = std.math.maxInt(usize);
};

/// What kind of selection the user requested
const CutMode = enum {
    bytes,
    characters,
    fields,
};

/// Command-line arguments for cut
const CutArgs = struct {
    help: bool = false,
    version: bool = false,
    bytes: ?[]const u8 = null,
    characters: ?[]const u8 = null,
    delimiter: ?[]const u8 = null,
    fields: ?[]const u8 = null,
    only_delimited: bool = false,
    complement: bool = false,
    output_delimiter: ?[]const u8 = null,
    no_split: bool = false,
    zero_terminated: bool = false,
    whitespace_delim: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .bytes = .{ .short = 'b', .desc = "Select only these bytes", .value_name = "LIST" },
        .characters = .{ .short = 'c', .desc = "Select only these characters", .value_name = "LIST" },
        .delimiter = .{ .short = 'd', .desc = "Use DELIM instead of TAB", .value_name = "DELIM" },
        .fields = .{ .short = 'f', .desc = "Select only these fields", .value_name = "LIST" },
        .only_delimited = .{ .short = 's', .desc = "print only lines containing delimiters" },
        .complement = .{ .short = 0, .desc = "Complement the set of selected bytes/chars/fields" },
        .output_delimiter = .{ .short = 0, .desc = "Use STRING as output delimiter", .value_name = "STRING" },
        .no_split = .{ .short = 'n', .desc = "Do not split multi-byte characters (with -b)" },
        .whitespace_delim = .{ .short = 'w', .desc = "Use whitespace (spaces and tabs) as field delimiter" },
        .zero_terminated = .{ .short = 'z', .desc = "Line delimiter is NUL, not newline" },
    };
};

/// Parse a range list string like "1,3,5-7" or "-3" or "5-"
/// Returns a sorted, merged array of Range values.
/// Caller owns the returned slice.
fn parseRangeList(allocator: Allocator, list_str: []const u8) ![]Range {
    var ranges = std.ArrayListUnmanaged(Range){};
    defer ranges.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, list_str, ", ");
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_pos| {
            const left = std.mem.trim(u8, trimmed[0..dash_pos], " ");
            const right = std.mem.trim(u8, trimmed[dash_pos + 1 ..], " ");

            if (left.len == 0 and right.len == 0) {
                // Just "-" alone is invalid
                return error.InvalidRange;
            }

            const start: usize = if (left.len == 0) 1 else std.fmt.parseInt(usize, left, 10) catch return error.InvalidRange;
            const end: usize = if (right.len == 0) Range.END else std.fmt.parseInt(usize, right, 10) catch return error.InvalidRange;

            if (start == 0 or (end != Range.END and end == 0)) return error.InvalidRange;
            if (end != Range.END and start > end) return error.InvalidRange;

            try ranges.append(allocator, .{ .start = start, .end = end });
        } else {
            const val = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidRange;
            if (val == 0) return error.InvalidRange;
            try ranges.append(allocator, .{ .start = val, .end = val });
        }
    }

    if (ranges.items.len == 0) return error.InvalidRange;

    // Sort by start position
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.end < b.end;
        }
    }.lessThan);

    // Merge overlapping ranges
    var merged = std.ArrayListUnmanaged(Range){};
    errdefer merged.deinit(allocator);

    try merged.append(allocator, ranges.items[0]);

    for (ranges.items[1..]) |r| {
        const last = &merged.items[merged.items.len - 1];
        // Check if r overlaps or is adjacent to last
        if (last.end == Range.END or (r.start <= last.end + 1)) {
            // Merge
            if (r.end == Range.END) {
                last.end = Range.END;
            } else if (last.end != Range.END and r.end > last.end) {
                last.end = r.end;
            }
        } else {
            try merged.append(allocator, r);
        }
    }

    return merged.toOwnedSlice(allocator);
}

/// Check if a 1-indexed position is selected by the ranges
fn isSelected(ranges: []const Range, pos: usize, do_complement: bool) bool {
    var selected = false;
    for (ranges) |r| {
        if (pos >= r.start and (r.end == Range.END or pos <= r.end)) {
            selected = true;
            break;
        }
        if (pos < r.start) break; // ranges are sorted
    }
    return if (do_complement) !selected else selected;
}

/// Return the number of bytes in the UTF-8 character starting at the given byte.
/// If the byte is a continuation byte or invalid, returns 1.
fn utf8CharLen(byte: u8) usize {
    if (byte < 0x80) return 1; // ASCII
    if (byte & 0xE0 == 0xC0) return 2; // 110xxxxx
    if (byte & 0xF0 == 0xE0) return 3; // 1110xxxx
    if (byte & 0xF8 == 0xF0) return 4; // 11110xxx
    return 1; // continuation byte or invalid
}

/// Cut bytes or characters from a line
fn cutBytesOrChars(
    line: []const u8,
    ranges: []const Range,
    do_complement: bool,
    no_split: bool,
    writer: anytype,
) !void {
    if (!no_split) {
        // Simple byte-by-byte selection
        var pos: usize = 1;
        for (line) |byte| {
            if (isSelected(ranges, pos, do_complement)) {
                try writer.writeAll(&.{byte});
            }
            pos += 1;
        }
        return;
    }

    // With -n: don't split multi-byte characters.
    // For each UTF-8 character, output it only if ALL its bytes are selected.
    var i: usize = 0;
    while (i < line.len) {
        const char_len = utf8CharLen(line[i]);
        // Clamp to remaining bytes
        const actual_len = @min(char_len, line.len - i);

        // Check if all bytes of this character are selected
        var all_selected = true;
        for (0..actual_len) |offset| {
            const pos = i + offset + 1; // 1-indexed
            if (!isSelected(ranges, pos, do_complement)) {
                all_selected = false;
                break;
            }
        }

        if (all_selected) {
            try writer.writeAll(line[i .. i + actual_len]);
        }

        i += actual_len;
    }
}

/// Cut fields from a line
fn cutFields(
    line: []const u8,
    ranges: []const Range,
    do_complement: bool,
    delimiter: u8,
    output_delim: []const u8,
    only_delimited: bool,
    writer: anytype,
) !void {
    // Check if line contains delimiter
    if (std.mem.indexOfScalar(u8, line, delimiter) == null) {
        if (!only_delimited) {
            try writer.writeAll(line);
        }
        return;
    }

    var field_num: usize = 1;
    var first_output = true;
    var iter = std.mem.splitScalar(u8, line, delimiter);

    while (iter.next()) |field| {
        if (isSelected(ranges, field_num, do_complement)) {
            if (!first_output) {
                try writer.writeAll(output_delim);
            }
            try writer.writeAll(field);
            first_output = false;
        }
        field_num += 1;
    }
}

/// Cut fields from a line using whitespace as delimiter.
/// Multiple consecutive whitespace characters count as a single delimiter.
/// Leading whitespace is skipped.
fn cutFieldsWhitespace(
    line: []const u8,
    ranges: []const Range,
    do_complement: bool,
    output_delim: []const u8,
    only_delimited: bool,
    writer: anytype,
) !void {
    // Check if line contains any whitespace
    var has_whitespace = false;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') {
            has_whitespace = true;
            break;
        }
    }

    if (!has_whitespace) {
        if (!only_delimited) {
            try writer.writeAll(line);
        }
        return;
    }

    // Tokenize by whitespace (spaces and tabs), which automatically
    // handles multiple consecutive delimiters and leading whitespace
    var field_num: usize = 1;
    var first_output = true;
    var iter = std.mem.tokenizeAny(u8, line, " \t");

    while (iter.next()) |field| {
        if (isSelected(ranges, field_num, do_complement)) {
            if (!first_output) {
                try writer.writeAll(output_delim);
            }
            try writer.writeAll(field);
            first_output = false;
        }
        field_num += 1;
    }
}

/// Main entry point for cut utility
pub fn runCut(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parse(CutArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "unrecognized option\nTry 'cut --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "option requires an argument\nTry 'cut --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "invalid argument value\nTry 'cut --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return 0;
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return 0;
    }

    // Determine mode and validate mutual exclusivity
    var mode_count: u8 = 0;
    if (parsed.bytes != null) mode_count += 1;
    if (parsed.characters != null) mode_count += 1;
    if (parsed.fields != null) mode_count += 1;

    if (mode_count == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "you must specify a list of bytes, characters, or fields\nTry 'cut --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    if (mode_count > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "only one type of list may be specified\nTry 'cut --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const mode: CutMode = if (parsed.bytes != null) .bytes else if (parsed.characters != null) .characters else .fields;

    // -s is only valid with -f
    if (parsed.only_delimited and mode != .fields) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "suppressing non-delimited lines makes sense only when operating on fields\nTry 'cut --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -d is only valid with -f
    if (parsed.delimiter != null and mode != .fields) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "an input delimiter may be specified only when operating on fields\nTry 'cut --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -w is only valid with -f
    if (parsed.whitespace_delim and mode != .fields) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "-w may only be used with -f\nTry 'cut --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -w and -d are mutually exclusive
    if (parsed.whitespace_delim and parsed.delimiter != null) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "-w and -d may not both be specified\nTry 'cut --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Parse the range list
    const list_str = parsed.bytes orelse parsed.characters orelse parsed.fields.?;
    const ranges = parseRangeList(allocator, list_str) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "invalid range: '{s}'", .{list_str});
        return @intFromEnum(common.ExitCode.misuse);
    };
    defer allocator.free(ranges);

    // Determine delimiter
    const delimiter: u8 = if (parsed.delimiter) |d| blk: {
        if (d.len == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "cut", "the delimiter must be a single character", .{});
            return @intFromEnum(common.ExitCode.misuse);
        }
        if (d.len > 1) {
            common.printErrorWithProgram(allocator, stderr_writer, "cut", "the delimiter must be a single character", .{});
            return @intFromEnum(common.ExitCode.misuse);
        }
        break :blk d[0];
    } else '\t';

    // Determine output delimiter
    const output_delim: []const u8 = if (parsed.output_delimiter) |od|
        od
    else if (parsed.whitespace_delim)
        " "
    else switch (mode) {
        .fields => &.{delimiter},
        .bytes, .characters => "",
    };

    const line_terminator: u8 = if (parsed.zero_terminated) 0 else '\n';

    // Process files or stdin
    if (parsed.positionals.len == 0) {
        const stdin_file = std.fs.File.stdin();
        return processFile(
            allocator,
            stdin_file,
            ranges,
            mode,
            delimiter,
            output_delim,
            parsed.only_delimited,
            parsed.complement,
            parsed.no_split,
            parsed.whitespace_delim,
            line_terminator,
            stdout_writer,
            stderr_writer,
        );
    }

    var has_error = false;
    for (parsed.positionals) |file_path| {
        if (std.mem.eql(u8, file_path, "-")) {
            const stdin_file = std.fs.File.stdin();
            const result = processFile(
                allocator,
                stdin_file,
                ranges,
                mode,
                delimiter,
                output_delim,
                parsed.only_delimited,
                parsed.complement,
                parsed.no_split,
                parsed.whitespace_delim,
                line_terminator,
                stdout_writer,
                stderr_writer,
            );
            if (result > 0) has_error = true;
        } else {
            const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "{s}: {s}", .{ file_path, @errorName(err) });
                has_error = true;
                continue;
            };
            defer file.close();

            const result = processFile(
                allocator,
                file,
                ranges,
                mode,
                delimiter,
                output_delim,
                parsed.only_delimited,
                parsed.complement,
                parsed.no_split,
                parsed.whitespace_delim,
                line_terminator,
                stdout_writer,
                stderr_writer,
            );
            if (result > 0) has_error = true;
        }
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else 0;
}

/// Process a single file/stream
fn processFile(
    allocator: Allocator,
    file: std.fs.File,
    ranges: []const Range,
    mode: CutMode,
    delimiter: u8,
    output_delim: []const u8,
    only_delimited: bool,
    do_complement: bool,
    no_split: bool,
    whitespace_delim: bool,
    line_terminator: u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) u8 {
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(&read_buf);

    // Read line by line using the reader interface
    var line_buf = std.ArrayListUnmanaged(u8){};
    defer line_buf.deinit(allocator);

    while (true) {
        line_buf.clearRetainingCapacity();

        // Read until line terminator or EOF
        const eof = readLine(&reader.interface, &line_buf, allocator, line_terminator) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cut", "read error: {s}", .{@errorName(err)});
            return @intFromEnum(common.ExitCode.general_error);
        };

        if (eof and line_buf.items.len == 0) break;

        // Process the line
        switch (mode) {
            .bytes, .characters => {
                cutBytesOrChars(line_buf.items, ranges, do_complement, if (mode == .bytes) no_split else false, stdout_writer) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{@errorName(err)});
                    return @intFromEnum(common.ExitCode.general_error);
                };
                stdout_writer.writeAll(&.{line_terminator}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{@errorName(err)});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            },
            .fields => {
                if (whitespace_delim) {
                    cutFieldsWhitespace(
                        line_buf.items,
                        ranges,
                        do_complement,
                        output_delim,
                        only_delimited,
                        stdout_writer,
                    ) catch |err| {
                        common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{@errorName(err)});
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    stdout_writer.writeAll(&.{line_terminator}) catch |err| {
                        common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{@errorName(err)});
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                } else {
                    const line_has_delim = std.mem.indexOfScalar(u8, line_buf.items, delimiter) != null;

                    if (!line_has_delim and only_delimited) {
                        // Skip this line
                    } else {
                        cutFields(
                            line_buf.items,
                            ranges,
                            do_complement,
                            delimiter,
                            output_delim,
                            only_delimited,
                            stdout_writer,
                        ) catch |err| {
                            common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{@errorName(err)});
                            return @intFromEnum(common.ExitCode.general_error);
                        };
                        stdout_writer.writeAll(&.{line_terminator}) catch |err| {
                            common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{@errorName(err)});
                            return @intFromEnum(common.ExitCode.general_error);
                        };
                    }
                }
            },
        }

        if (eof) break;
    }

    return 0;
}

/// Read a line from reader into buffer, stopping at line_terminator.
/// Returns true if EOF was reached.
fn readLine(
    reader: anytype,
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    line_terminator: u8,
) !bool {
    while (true) {
        const chunk = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return true,
            else => |e| return e,
        };

        if (chunk.len == 0) return true;

        // Look for line terminator in chunk
        if (std.mem.indexOfScalar(u8, chunk, line_terminator)) |pos| {
            // Append everything before the terminator
            try buf.appendSlice(allocator, chunk[0..pos]);
            reader.toss(pos + 1);
            return false;
        }

        // No terminator found, append entire chunk
        try buf.appendSlice(allocator, chunk);
        reader.toss(chunk.len);
    }
}

/// Main entry point for the cut command
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

    const exit_code = try runCut(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(exit_code);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: cut OPTION... [FILE]...
        \\Print selected parts of lines from each FILE to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --bytes=LIST        select only these bytes
        \\  -c, --characters=LIST   select only these characters
        \\  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter
        \\  -f, --fields=LIST       select only these fields; also print any line
        \\                            that contains no delimiter character, unless
        \\                            the -s option is specified
        \\  -s, --only-delimited    print only lines containing delimiters
        \\      --complement         complement the set of selected bytes, characters
        \\                            or fields
        \\      --output-delimiter=STRING  use STRING as the output delimiter;
        \\                            the default is to use the input delimiter
        \\  -z, --zero-terminated   line delimiter is NUL, not newline
        \\  -h, --help              display this help and exit
        \\  -V, --version           output version information and exit
        \\
        \\Use one, and only one, of -b, -c or -f.  Each LIST is made up of one
        \\range, or many ranges separated by commas.
        \\
        \\Each range is one of:
        \\  N     N'th byte, character or field, counted from 1
        \\  N-    from N'th byte, character or field, to end of line
        \\  N-M   from N'th to M'th byte, character or field
        \\  -M    from first to M'th byte, character or field
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("cut ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "cut --help shows help message" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runCut(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: cut") != null);
}

test "cut --version shows version information" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runCut(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "cut") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.version) != null);
}

test "cut no mode specified returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "you must specify") != null);
}

test "cut multiple modes returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", "1", "-f", "1" };
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "only one type") != null);
}

test "cut -s without -f returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", "1", "-s" };
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "suppressing") != null);
}

test "cut -d without -f returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", "1", "-d", ":" };
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "input delimiter") != null);
}

test "cut unknown flag returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unrecognized option") != null);
}

test "parseRangeList single value" {
    const ranges = try parseRangeList(testing.allocator, "3");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 3), ranges[0].start);
    try testing.expectEqual(@as(usize, 3), ranges[0].end);
}

test "parseRangeList multiple values" {
    const ranges = try parseRangeList(testing.allocator, "1,3,5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 3), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 3), ranges[1].start);
    try testing.expectEqual(@as(usize, 5), ranges[2].start);
}

test "parseRangeList range N-M" {
    const ranges = try parseRangeList(testing.allocator, "2-5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 2), ranges[0].start);
    try testing.expectEqual(@as(usize, 5), ranges[0].end);
}

test "parseRangeList range N-" {
    const ranges = try parseRangeList(testing.allocator, "3-");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 3), ranges[0].start);
    try testing.expectEqual(Range.END, ranges[0].end);
}

test "parseRangeList range -M" {
    const ranges = try parseRangeList(testing.allocator, "-5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 5), ranges[0].end);
}

test "parseRangeList complex list" {
    const ranges = try parseRangeList(testing.allocator, "1,3-5,7,10-");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 4), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 1), ranges[0].end);
    try testing.expectEqual(@as(usize, 3), ranges[1].start);
    try testing.expectEqual(@as(usize, 5), ranges[1].end);
    try testing.expectEqual(@as(usize, 7), ranges[2].start);
    try testing.expectEqual(@as(usize, 7), ranges[2].end);
    try testing.expectEqual(@as(usize, 10), ranges[3].start);
    try testing.expectEqual(Range.END, ranges[3].end);
}

test "parseRangeList overlapping ranges merge" {
    const ranges = try parseRangeList(testing.allocator, "1-3,2-5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 5), ranges[0].end);
}

test "parseRangeList adjacent ranges merge" {
    const ranges = try parseRangeList(testing.allocator, "1-3,4-6");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 6), ranges[0].end);
}

test "parseRangeList unsorted ranges are sorted" {
    const ranges = try parseRangeList(testing.allocator, "5,1,3");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 3), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 3), ranges[1].start);
    try testing.expectEqual(@as(usize, 5), ranges[2].start);
}

test "parseRangeList zero value is invalid" {
    const result = parseRangeList(testing.allocator, "0");
    try testing.expectError(error.InvalidRange, result);
}

test "parseRangeList reversed range is invalid" {
    const result = parseRangeList(testing.allocator, "5-3");
    try testing.expectError(error.InvalidRange, result);
}

test "parseRangeList empty string is invalid" {
    const result = parseRangeList(testing.allocator, "");
    try testing.expectError(error.InvalidRange, result);
}

test "parseRangeList bare dash is invalid" {
    const result = parseRangeList(testing.allocator, "-");
    try testing.expectError(error.InvalidRange, result);
}

test "isSelected basic" {
    const ranges = try parseRangeList(testing.allocator, "1,3,5-7");
    defer testing.allocator.free(ranges);

    try testing.expect(isSelected(ranges, 1, false));
    try testing.expect(!isSelected(ranges, 2, false));
    try testing.expect(isSelected(ranges, 3, false));
    try testing.expect(!isSelected(ranges, 4, false));
    try testing.expect(isSelected(ranges, 5, false));
    try testing.expect(isSelected(ranges, 6, false));
    try testing.expect(isSelected(ranges, 7, false));
    try testing.expect(!isSelected(ranges, 8, false));
}

test "isSelected with complement" {
    const ranges = try parseRangeList(testing.allocator, "1,3");
    defer testing.allocator.free(ranges);

    try testing.expect(!isSelected(ranges, 1, true)); // complemented
    try testing.expect(isSelected(ranges, 2, true)); // complemented
    try testing.expect(!isSelected(ranges, 3, true)); // complemented
    try testing.expect(isSelected(ranges, 4, true)); // complemented
}

test "cutBytesOrChars single byte" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, false, false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("a", buffer.items);
}

test "cutBytesOrChars range" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "2-4");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, false, false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("bcd", buffer.items);
}

test "cutBytesOrChars multiple selections" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1,3,5");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, false, false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("ace", buffer.items);
}

test "cutBytesOrChars complement" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "2,4");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, true, false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("ace", buffer.items);
}

test "cutFields basic" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, false, '\t', "\t", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("one", buffer.items);
}

test "cutFields multiple fields" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1,3");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, false, '\t', "\t", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("one\tthree", buffer.items);
}

test "cutFields range" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "2-3");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree\tfour", ranges, false, '\t', "\t", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("two\tthree", buffer.items);
}

test "cutFields custom delimiter" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "2");
    defer testing.allocator.free(ranges);

    try cutFields("one:two:three", ranges, false, ':', ":", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("two", buffer.items);
}

test "cutFields no delimiter in line prints line" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFields("no delimiters here", ranges, false, '\t', "\t", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("no delimiters here", buffer.items);
}

test "cutFields no delimiter in line with -s suppresses output" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFields("no delimiters here", ranges, false, '\t', "\t", true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("", buffer.items);
}

test "cutFields complement" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "2");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, true, '\t', "\t", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("one\tthree", buffer.items);
}

test "cutFields output delimiter" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1,3");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, false, '\t', ",", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("one,three", buffer.items);
}

test "cut with file input bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("abcde\nfghij\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", "1-3", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abc\nfgh\n", stdout_buffer.items);
}

test "cut with file input fields" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("one:two:three\nfour:five:six\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "2", "-d", ":", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("two\nfive\n", stdout_buffer.items);
}

test "cut nonexistent file returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", "1", "/nonexistent_test_file" };
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "nonexistent_test_file") != null);
}

// ============================================================================
//                          -n FLAG TESTS (RED PHASE)
// ============================================================================

test "cut: -n flag is accepted with -b" {
    // The -n flag should be accepted without error when used with -b.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("hello\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "-b", "1-3", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hel\n", stdout_buffer.items);
}

test "cut: -n -b preserves multi-byte characters" {
    // Input "caf\xc3\xa9" is "cafe" with e-acute (2 bytes: 0xC3 0xA9).
    // "cafe" is 4 characters but 5 bytes.
    // With -b1-4 alone, bytes 1-4 are "caf\xc3" which splits the e-acute.
    // With -n -b1-4, the partial multi-byte character at byte 4 should be
    // excluded, producing "caf" (3 bytes).
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    // "cafe" with e-acute: c(0x63) a(0x61) f(0x66) e-acute(0xC3 0xA9)
    try test_file.writeAll("caf\xc3\xa9\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "-b", "1-4", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // With -n, partial multi-byte chars should be excluded.
    // Byte 4 is 0xC3 (first byte of 2-byte sequence), byte 5 is 0xA9.
    // Since only byte 4 is selected (not 5), the character is partial
    // and should be excluded entirely, giving "caf".
    try testing.expectEqualStrings("caf\n", stdout_buffer.items);
}

// ============================================================================
//                          -w FLAG TESTS
// ============================================================================

test "cut: -w splits on whitespace" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("one two three\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-f", "2", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("two\n", stdout_buffer.items);
}

test "cut: -w handles multiple consecutive spaces" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("one   two\t\tthree\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-f", "1,3", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("one three\n", stdout_buffer.items);
}

test "cut: -w skips leading whitespace" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("  leading space\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-f", "1", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("leading\n", stdout_buffer.items);
}

test "cut: -w with no whitespace prints whole line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("nowhitespace\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-f", "1", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("nowhitespace\n", stdout_buffer.items);
}

test "cut: -w and -d are mutually exclusive" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-f", "1", "-d", ":" };
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "-w and -d") != null);
}

test "cut: -w without -f returns error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-b", "1" };
    const result = try runCut(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "-w may only be used with -f") != null);
}

test "cutFieldsWhitespace basic" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "2");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("one two three", ranges, false, " ", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("two", buffer.items);
}

test "cutFieldsWhitespace multiple spaces" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1-2");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("a    b    c", ranges, false, " ", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("a b", buffer.items);
}

test "cutFieldsWhitespace tabs and spaces" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "3");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("x\t y\t z", ranges, false, " ", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("z", buffer.items);
}

test "cutFieldsWhitespace no whitespace prints line" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("solid", ranges, false, " ", false, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("solid", buffer.items);
}

test "cutFieldsWhitespace no whitespace with -s suppresses" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("solid", ranges, false, " ", true, buffer.writer(testing.allocator));
    try testing.expectEqualStrings("", buffer.items);
}

test "cut: -n without -b has no effect on field mode" {
    // -n only affects -b mode. When used with -f, it should have no
    // effect and the command should work normally.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
    try test_file.writeAll("a,b,c\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "-f", "1", "-d", ",", test_path };
    const result = try runCut(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\n", stdout_buffer.items);
}

// ============================================================================
//                  processFile stderr diagnostic tests (RED)
// ============================================================================

test "cut --version output contains common.name" {
    // The version string must use common.name (not a hardcoded project name).
    // This ensures the output stays consistent if common.name ever changes.
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runCut(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.name) != null);
}

test "cut: processFile reports read errors to stderr" {
    // Create a valid file, then close its handle so reads will fail.
    // processFile should write a diagnostic message to stderr, but
    // the bug (line 469: _ = stderr_writer) means stderr stays empty.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("readable.txt", .{ .read = true });
    try tmp_file.writeAll("hello\n");
    // Close the handle to make subsequent reads fail
    tmp_file.close();

    // Create a File struct with the now-invalid handle
    const bad_file = std.fs.File{ .handle = tmp_file.handle };

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const result = processFile(
        testing.allocator,
        bad_file,
        ranges,
        .bytes,
        '\t',
        "\t",
        false,
        false,
        false,
        false,
        '\n',
        stdout_buffer.writer(testing.allocator),
        stderr_buffer.writer(testing.allocator),
    );

    // Should return non-zero exit code
    try testing.expectEqual(@as(u8, 1), result);
    // Should have written a diagnostic message to stderr
    // This assertion will FAIL because processFile discards stderr_writer
    try testing.expect(stderr_buffer.items.len > 0);
}
