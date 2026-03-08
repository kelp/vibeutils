//! nl - number lines of files
//!
//! Reads lines from named files or stdin and writes them with line numbers.
//! Supports logical page sections (header/body/footer), numbering styles,
//! and number formatting. POSIX-compliant with GNU extensions.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Numbering style for a section
const NumberingStyle = enum {
    all, // a: number all lines
    non_empty, // t: number only non-empty lines (default body)
    none, // n: do not number lines
};

/// Number output format
const NumberFormat = enum {
    left, // ln: left justified
    right, // rn: right justified (default)
    right_zero, // rz: right justified with leading zeros
};

/// Resolved options after argument parsing
const NlOptions = struct {
    body_style: NumberingStyle = .non_empty,
    header_style: NumberingStyle = .none,
    footer_style: NumberingStyle = .none,
    format: NumberFormat = .right,
    width: u32 = 6,
    separator: []const u8 = "\t",
    start: i64 = 1,
    increment: i64 = 1,
    no_renumber: bool = false,
    delimiter: [2]u8 = .{ '\\', ':' },
    join_blank_lines: u32 = 1,
};

/// Command-line arguments for nl
const NlArgs = struct {
    help: bool = false,
    version: bool = false,
    body_numbering: ?[]const u8 = null,
    b: ?[]const u8 = null,
    header_numbering: ?[]const u8 = null,
    h: ?[]const u8 = null,
    footer_numbering: ?[]const u8 = null,
    f: ?[]const u8 = null,
    number_format: ?[]const u8 = null,
    n: ?[]const u8 = null,
    number_width: ?[]const u8 = null,
    w: ?[]const u8 = null,
    number_separator: ?[]const u8 = null,
    s: ?[]const u8 = null,
    starting_line_number: ?[]const u8 = null,
    v: ?[]const u8 = null,
    line_increment: ?[]const u8 = null,
    i: ?[]const u8 = null,
    no_renumber: bool = false,
    p: bool = false,
    section_delimiter: ?[]const u8 = null,
    d: ?[]const u8 = null,
    join_blank_lines: ?[]const u8 = null,
    l: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        // -h is header-numbering, so help has no short flag
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .body_numbering = .{ .short = 0, .desc = "Set body numbering style (a, t, n)", .value_name = "STYLE" },
        .b = .{ .desc = "Set body numbering style (a, t, n)", .value_name = "STYLE" },
        .header_numbering = .{ .short = 0, .desc = "Set header numbering style (a, t, n)", .value_name = "STYLE" },
        .h = .{ .desc = "Set header numbering style (a, t, n)", .value_name = "STYLE" },
        .footer_numbering = .{ .short = 0, .desc = "Set footer numbering style (a, t, n)", .value_name = "STYLE" },
        .f = .{ .desc = "Set footer numbering style (a, t, n)", .value_name = "STYLE" },
        .number_format = .{ .short = 0, .desc = "Set number format (ln, rn, rz)", .value_name = "FORMAT" },
        .n = .{ .desc = "Set number format (ln, rn, rz)", .value_name = "FORMAT" },
        .number_width = .{ .short = 0, .desc = "Set number width", .value_name = "NUMBER" },
        .w = .{ .desc = "Set number width", .value_name = "NUMBER" },
        .number_separator = .{ .short = 0, .desc = "Set separator between number and text", .value_name = "STRING" },
        .s = .{ .desc = "Set separator between number and text", .value_name = "STRING" },
        .starting_line_number = .{ .short = 0, .desc = "Set initial line number", .value_name = "NUMBER" },
        .v = .{ .desc = "Set initial line number", .value_name = "NUMBER" },
        .line_increment = .{ .short = 0, .desc = "Set line number increment", .value_name = "NUMBER" },
        .i = .{ .desc = "Set line number increment", .value_name = "NUMBER" },
        .no_renumber = .{ .short = 0, .desc = "Do not reset line numbers at logical pages" },
        .p = .{ .desc = "Do not reset line numbers at logical pages" },
        .section_delimiter = .{ .short = 0, .desc = "Set section delimiter characters", .value_name = "CC" },
        .d = .{ .desc = "Set section delimiter characters", .value_name = "CC" },
        .join_blank_lines = .{ .short = 0, .desc = "Count N consecutive blank lines as one", .value_name = "NUMBER" },
        .l = .{ .desc = "Count N consecutive blank lines as one", .value_name = "NUMBER" },
    };
};

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("nl ({s}) {s}\n", .{ common.name, common.version });
}

/// Print help information
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: nl [OPTION]... [FILE]...
        \\Write each FILE to standard output, with line numbers added.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --body-numbering=STYLE     use STYLE for numbering body lines
        \\  -d, --section-delimiter=CC     use CC for logical page delimiters
        \\  -f, --footer-numbering=STYLE   use STYLE for numbering footer lines
        \\  -h, --header-numbering=STYLE   use STYLE for numbering header lines
        \\  -i, --line-increment=NUMBER    line number increment at each line
        \\  -l, --join-blank-lines=NUMBER  group of NUMBER empty lines counted as one
        \\  -n, --number-format=FORMAT     insert line numbers according to FORMAT
        \\  -p, --no-renumber              do not reset line numbers for each section
        \\  -s, --number-separator=STRING  add STRING after (possible) line number
        \\  -v, --starting-line-number=NUMBER  first line number for each section
        \\  -w, --number-width=NUMBER      use NUMBER columns for line numbers
        \\      --help                     display this help and exit
        \\  -V, --version                  output version information and exit
        \\
        \\STYLE is one of:
        \\  a   number all lines
        \\  t   number only nonempty lines
        \\  n   number no lines
        \\
        \\FORMAT is one of:
        \\  ln   left justified, no leading zeros
        \\  rn   right justified, no leading zeros
        \\  rz   right justified, leading zeros
        \\
        \\Default options are: -bt -d'\\:' -fn -hn -i1 -l1 -nrn -s<TAB> -v1 -w6
        \\
    );
}

/// Parse a numbering style string
fn parseNumberingStyle(s: []const u8) ?NumberingStyle {
    if (std.mem.eql(u8, s, "a")) return .all;
    if (std.mem.eql(u8, s, "t")) return .non_empty;
    if (std.mem.eql(u8, s, "n")) return .none;
    return null;
}

/// Parse a number format string
fn parseNumberFormat(s: []const u8) ?NumberFormat {
    if (std.mem.eql(u8, s, "ln")) return .left;
    if (std.mem.eql(u8, s, "rn")) return .right;
    if (std.mem.eql(u8, s, "rz")) return .right_zero;
    return null;
}

/// Parse a positive integer from a string
fn parsePositiveInt(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch return null;
}

/// Parse a signed integer from a string
fn parseSignedInt(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch return null;
}

/// Resolve parsed arguments into options, returning error messages
fn resolveOptions(args: NlArgs, stderr_writer: anytype, allocator: Allocator) !?NlOptions {
    var opts = NlOptions{};

    // Body numbering: -b takes precedence, --body-numbering as long form
    const body_val = args.b orelse args.body_numbering;
    if (body_val) |val| {
        opts.body_style = parseNumberingStyle(val) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid body numbering style: '{s}'", .{val});
            return null;
        };
    }

    // Header numbering: -h takes precedence, --header-numbering as long form
    const header_val = args.h orelse args.header_numbering;
    if (header_val) |val| {
        opts.header_style = parseNumberingStyle(val) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid header numbering style: '{s}'", .{val});
            return null;
        };
    }

    // Footer numbering: -f takes precedence, --footer-numbering as long form
    const footer_val = args.f orelse args.footer_numbering;
    if (footer_val) |val| {
        opts.footer_style = parseNumberingStyle(val) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid footer numbering style: '{s}'", .{val});
            return null;
        };
    }

    // Number format: -n takes precedence, --number-format as long form
    const format_val = args.n orelse args.number_format;
    if (format_val) |val| {
        opts.format = parseNumberFormat(val) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid line number format: '{s}'", .{val});
            return null;
        };
    }

    // Width: -w takes precedence, --number-width as long form
    const width_val = args.w orelse args.number_width;
    if (width_val) |val| {
        const w = parsePositiveInt(val);
        if (w == null or w.? == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid line number field width: '{s}'", .{val});
            return null;
        }
        opts.width = w.?;
    }

    // Separator: -s takes precedence, --number-separator as long form
    const sep_val = args.s orelse args.number_separator;
    if (sep_val) |val| {
        opts.separator = val;
    }

    // Starting number: -v takes precedence, --starting-line-number as long form
    const start_val = args.v orelse args.starting_line_number;
    if (start_val) |val| {
        opts.start = parseSignedInt(val) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid starting line number: '{s}'", .{val});
            return null;
        };
    }

    // Increment: -i takes precedence, --line-increment as long form
    const inc_val = args.i orelse args.line_increment;
    if (inc_val) |val| {
        opts.increment = parseSignedInt(val) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid line number increment: '{s}'", .{val});
            return null;
        };
    }

    // No renumber: -p or --no-renumber
    opts.no_renumber = args.p or args.no_renumber;

    // Section delimiter: -d takes precedence, --section-delimiter as long form
    const delim_val = args.d orelse args.section_delimiter;
    if (delim_val) |val| {
        if (val.len == 1) {
            opts.delimiter = .{ val[0], ':' };
        } else if (val.len == 2) {
            opts.delimiter = .{ val[0], val[1] };
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid section delimiter: '{s}'", .{val});
            return null;
        }
    }

    // Join blank lines: -l takes precedence, --join-blank-lines as long form
    const join_val = args.l orelse args.join_blank_lines;
    if (join_val) |val| {
        const j = parsePositiveInt(val);
        if (j == null or j.? == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid line number of blank lines: '{s}'", .{val});
            return null;
        }
        opts.join_blank_lines = j.?;
    }

    return opts;
}

/// Section type within a logical page
const Section = enum {
    header,
    body,
    footer,
};

/// State maintained across line numbering
const NlState = struct {
    line_number: i64,
    section: Section = .body,
    blank_count: u32 = 0,
};

/// Check if a line is a section delimiter. Returns the section type if it is.
/// Section delimiters are lines consisting only of the delimiter pair repeated:
///   3 times = header (\:\:\:)
///   2 times = body (\:\:)
///   1 time  = footer (\:)
fn isSectionDelimiter(line: []const u8, delimiter: [2]u8) ?Section {
    // Must be exact multiples of 2 chars (the delimiter pair)
    if (line.len == 0 or line.len % 2 != 0 or line.len > 6) return null;
    const pairs = line.len / 2;
    if (pairs < 1 or pairs > 3) return null;

    // Verify all pairs match the delimiter
    var j: usize = 0;
    while (j < line.len) : (j += 2) {
        if (line[j] != delimiter[0] or line[j + 1] != delimiter[1]) return null;
    }

    return switch (pairs) {
        3 => .header,
        2 => .body,
        1 => .footer,
        else => null,
    };
}

/// Get the numbering style for the current section
fn getStyleForSection(opts: NlOptions, section: Section) NumberingStyle {
    return switch (section) {
        .header => opts.header_style,
        .body => opts.body_style,
        .footer => opts.footer_style,
    };
}

/// Format a number into a buffer with the given format and width.
/// Returns the formatted slice.
fn formatNumber(buf: []u8, number: i64, format: NumberFormat, width: u32) []const u8 {
    const w: usize = @intCast(width);

    // First, format the number into a scratch area
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{number}) catch return "";
    const num_len = num_str.len;

    if (w > buf.len) return "";

    switch (format) {
        .left => {
            // Left justified: number then spaces
            if (num_len >= w) {
                @memcpy(buf[0..num_len], num_str);
                return buf[0..num_len];
            }
            @memcpy(buf[0..num_len], num_str);
            @memset(buf[num_len..w], ' ');
            return buf[0..w];
        },
        .right => {
            // Right justified: spaces then number
            if (num_len >= w) {
                @memcpy(buf[0..num_len], num_str);
                return buf[0..num_len];
            }
            const pad_len = w - num_len;
            @memset(buf[0..pad_len], ' ');
            @memcpy(buf[pad_len..w], num_str);
            return buf[0..w];
        },
        .right_zero => {
            // Right justified with leading zeros
            if (number >= 0) {
                if (num_len >= w) {
                    @memcpy(buf[0..num_len], num_str);
                    return buf[0..num_len];
                }
                const pad_len = w - num_len;
                @memset(buf[0..pad_len], '0');
                @memcpy(buf[pad_len..w], num_str);
                return buf[0..w];
            } else {
                // Negative: - then zero-padded digits
                const abs_str = num_str[1..]; // skip the '-'
                const total_len = 1 + @max(abs_str.len, w - 1);
                if (total_len > buf.len) return "";
                buf[0] = '-';
                if (abs_str.len >= w - 1) {
                    @memcpy(buf[1 .. 1 + abs_str.len], abs_str);
                    return buf[0 .. 1 + abs_str.len];
                }
                const zero_pad = w - 1 - abs_str.len;
                @memset(buf[1 .. 1 + zero_pad], '0');
                @memcpy(buf[1 + zero_pad .. w], abs_str);
                return buf[0..w];
            }
        },
    }
}

/// Write a formatted line number followed by separator and line content
fn writeNumberedLine(writer: anytype, number: i64, line: []const u8, opts: NlOptions) !void {
    var num_buf: [64]u8 = undefined;
    const formatted = formatNumber(&num_buf, number, opts.format, opts.width);
    try writer.writeAll(formatted);
    try writer.writeAll(opts.separator);
    try writer.writeAll(line);
    try writer.writeAll("\n");
}

/// Count the number of characters needed to display a number
fn countDigits(n: i64) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var val: i64 = n;
    if (val < 0) {
        count += 1; // for the minus sign
        val = -val;
    }
    while (val > 0) {
        count += 1;
        val = @divTrunc(val, 10);
    }
    return count;
}

/// Write an unnumbered line (spaces for the number field, separator, then content)
fn writeUnnumberedLine(writer: anytype, line: []const u8, opts: NlOptions) !void {
    // Fill number field with spaces
    var pad: u32 = 0;
    while (pad < opts.width) : (pad += 1) {
        try writer.writeAll(" ");
    }
    try writer.writeAll(opts.separator);
    try writer.writeAll(line);
    try writer.writeAll("\n");
}

/// Process lines from a reader with nl numbering logic
fn numberLines(reader: anytype, writer: anytype, opts: NlOptions, state: *NlState) !void {
    while (true) {
        const line_with_nl = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Line exceeds buffer - process partial
                const partial = reader.buffered();
                if (partial.len > 0) {
                    // For very long lines, just output them without numbering logic
                    try writer.writeAll(partial);
                    reader.toss(partial.len);
                }
                continue;
            },
            error.EndOfStream => {
                // Handle remaining data without trailing newline
                const remaining = reader.buffered();
                if (remaining.len > 0) {
                    try processLine(writer, remaining, opts, state);
                    reader.toss(remaining.len);
                }
                break;
            },
            else => |e| return e,
        };

        // Strip trailing newline for processing
        const line = line_with_nl[0 .. line_with_nl.len - 1];
        try processLine(writer, line, opts, state);
    }
}

/// Process a single line: check for section delimiters, apply numbering
fn processLine(writer: anytype, line: []const u8, opts: NlOptions, state: *NlState) !void {
    // Check for section delimiter
    if (isSectionDelimiter(line, opts.delimiter)) |new_section| {
        state.section = new_section;
        state.blank_count = 0;
        // Reset line number on new logical page (header) unless -p
        if (new_section == .header and !opts.no_renumber) {
            state.line_number = opts.start;
        }
        // Delimiter lines become empty lines in output
        try writer.writeAll("\n");
        return;
    }

    const style = getStyleForSection(opts, state.section);
    const is_blank = line.len == 0;

    switch (style) {
        .all => {
            if (is_blank) {
                state.blank_count += 1;
                if (state.blank_count >= opts.join_blank_lines) {
                    try writeNumberedLine(writer, state.line_number, line, opts);
                    state.line_number += opts.increment;
                    state.blank_count = 0;
                } else {
                    try writer.writeAll("\n");
                }
            } else {
                state.blank_count = 0;
                try writeNumberedLine(writer, state.line_number, line, opts);
                state.line_number += opts.increment;
            }
        },
        .non_empty => {
            if (is_blank) {
                state.blank_count = 0;
                try writer.writeAll("\n");
            } else {
                state.blank_count = 0;
                try writeNumberedLine(writer, state.line_number, line, opts);
                state.line_number += opts.increment;
            }
        },
        .none => {
            try writeUnnumberedLine(writer, line, opts);
        },
    }
}

/// Main entry point for nl
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

    const exit_code = try runNl(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Run the nl utility with given arguments
pub fn runNl(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed_args = common.argparse.ArgParser.parse(NlArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "nl", "unrecognized option\nTry 'nl --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "nl", "option requires an argument\nTry 'nl --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "nl", "invalid argument value\nTry 'nl --help' for more information.", .{});
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

    // Resolve options
    const opts = resolveOptions(parsed_args, stderr_writer, allocator) catch {
        return @intFromEnum(common.ExitCode.misuse);
    } orelse {
        return @intFromEnum(common.ExitCode.misuse);
    };

    var state = NlState{ .line_number = opts.start };
    var has_error = false;

    if (parsed_args.positionals.len == 0) {
        // Read from stdin
        var stdin_buffer: [8192]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
        numberLines(&stdin_reader.interface, stdout_writer, opts, &state) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "nl", "stdin: {s}", .{@errorName(err)});
            has_error = true;
        };
    } else {
        for (parsed_args.positionals) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                var stdin_buffer: [8192]u8 = undefined;
                var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
                numberLines(&stdin_reader.interface, stdout_writer, opts, &state) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "nl", "stdin: {s}", .{@errorName(err)});
                    has_error = true;
                };
            } else {
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "nl", "{s}: {s}", .{ file_path, @errorName(err) });
                    has_error = true;
                    continue;
                };
                defer file.close();

                var file_buffer: [8192]u8 = undefined;
                var file_reader = file.reader(&file_buffer);
                numberLines(&file_reader.interface, stdout_writer, opts, &state) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "nl", "{s}: {s}", .{ file_path, @errorName(err) });
                    has_error = true;
                };
            }
        }
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

// ============================================================================
// TESTS
// ============================================================================

test "nl --help" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const exit_code = try runNl(testing.allocator, &.{"--help"}, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage: nl") != null);
}

test "nl --version" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const exit_code = try runNl(testing.allocator, &.{"--version"}, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "nl (vibeutils)") != null);
}

test "nl invalid flag" {
    const exit_code = try runNl(testing.allocator, &.{"--invalid-flag"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "nl invalid body style" {
    const exit_code = try runNl(testing.allocator, &.{ "-b", "x" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "nl invalid number format" {
    const exit_code = try runNl(testing.allocator, &.{ "-n", "xx" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "nl invalid width" {
    const exit_code = try runNl(testing.allocator, &.{ "-w", "abc" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "nl non-existent file" {
    const exit_code = try runNl(testing.allocator, &.{"/tmp/nonexistent_nl_test_file_12345"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), exit_code);
}

test "nl parseNumberingStyle" {
    try testing.expectEqual(NumberingStyle.all, parseNumberingStyle("a").?);
    try testing.expectEqual(NumberingStyle.non_empty, parseNumberingStyle("t").?);
    try testing.expectEqual(NumberingStyle.none, parseNumberingStyle("n").?);
    try testing.expect(parseNumberingStyle("x") == null);
    try testing.expect(parseNumberingStyle("") == null);
}

test "nl parseNumberFormat" {
    try testing.expectEqual(NumberFormat.left, parseNumberFormat("ln").?);
    try testing.expectEqual(NumberFormat.right, parseNumberFormat("rn").?);
    try testing.expectEqual(NumberFormat.right_zero, parseNumberFormat("rz").?);
    try testing.expect(parseNumberFormat("xx") == null);
    try testing.expect(parseNumberFormat("") == null);
}

test "nl countDigits" {
    try testing.expectEqual(@as(u32, 1), countDigits(0));
    try testing.expectEqual(@as(u32, 1), countDigits(1));
    try testing.expectEqual(@as(u32, 2), countDigits(10));
    try testing.expectEqual(@as(u32, 3), countDigits(100));
    try testing.expectEqual(@as(u32, 2), countDigits(-1));
    try testing.expectEqual(@as(u32, 3), countDigits(-10));
}

test "nl isSectionDelimiter" {
    const delim = [2]u8{ '\\', ':' };
    try testing.expectEqual(Section.footer, isSectionDelimiter("\\:", delim).?);
    try testing.expectEqual(Section.body, isSectionDelimiter("\\:\\:", delim).?);
    try testing.expectEqual(Section.header, isSectionDelimiter("\\:\\:\\:", delim).?);
    try testing.expect(isSectionDelimiter("hello", delim) == null);
    try testing.expect(isSectionDelimiter("", delim) == null);
    try testing.expect(isSectionDelimiter("\\:\\:\\:\\:", delim) == null);
}

test "nl default numbers non-empty lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{file_path}, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("     1\thello\n     2\tworld\n", stdout_buf.items);
}

test "nl default skips blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\n\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{file_path}, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("     1\thello\n\n     2\tworld\n", stdout_buf.items);
}

test "nl -b a numbers all lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\n\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-b", "a", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("     1\thello\n     2\t\n     3\tworld\n", stdout_buf.items);
}

test "nl -b n numbers no lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-b", "n", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("      \thello\n      \tworld\n", stdout_buf.items);
}

test "nl -n ln left justified" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-n", "ln", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("1     \thello\n2     \tworld\n", stdout_buf.items);
}

test "nl -n rz zero filled" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-n", "rz", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("000001\thello\n000002\tworld\n", stdout_buf.items);
}

test "nl -w 3 narrow width" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-w", "3", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("  1\thello\n  2\tworld\n", stdout_buf.items);
}

test "nl -s custom separator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-s", ": ", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("     1: hello\n     2: world\n", stdout_buf.items);
}

test "nl -v 10 start at 10" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-v", "10", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("    10\thello\n    11\tworld\n", stdout_buf.items);
}

test "nl -i 5 increment by 5" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "line1\nline2\nline3\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-i", "5", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("     1\tline1\n     6\tline2\n    11\tline3\n", stdout_buf.items);
}

test "nl combined -v 100 -i 10 -n rz" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "hello\nworld\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-v", "100", "-i", "10", "-n", "rz", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("000100\thello\n000110\tworld\n", stdout_buf.items);
}

test "nl empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{file_path}, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "nl section delimiters" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // header delimiter, header content, body delimiter, body content
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "\\:\\:\\:\nHEADER\n\\:\\:\nbody1\nbody2\n");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{ "-h", "a", file_path }, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Delimiter lines become blank lines, header and body lines are numbered
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "HEADER") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "body1") != null);
}

test "nl no final newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write file without final newline
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello");
    file.close();

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const exit_code = try runNl(testing.allocator, &.{file_path}, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("     1\thello\n", stdout_buf.items);
}
