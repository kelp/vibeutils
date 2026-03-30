//! seq - print a sequence of numbers
//!
//! The seq utility prints a sequence of numbers, one per line (by default),
//! from FIRST through LAST, incrementing by INCREMENT. If FIRST or INCREMENT
//! is omitted, it defaults to 1. When given one argument, it generates numbers
//! from 1 to LAST.
//!
//! This implementation follows GNU seq specifications with support for
//! floating-point numbers, custom separators, equal-width padding, and
//! printf-style format strings.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Command-line arguments for the seq utility
const SeqArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Use STRING as separator instead of newline
    separator: ?[]const u8 = null,
    /// Use printf-style FORMAT string
    format: ?[]const u8 = null,
    /// Equalize width by padding with leading zeroes
    equal_width: bool = false,
    /// Positional arguments (FIRST, INCREMENT, LAST)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .separator = .{ .short = 's', .desc = "Use STRING as separator", .value_name = "STRING" },
        .format = .{ .short = 'f', .desc = "Use printf-style format", .value_name = "FORMAT" },
        .equal_width = .{ .short = 'w', .desc = "Equalize width by padding with leading zeroes" },
    };
};

/// Check if a string represents an integer (no decimal point)
fn isInteger(s: []const u8) bool {
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') return false;
    }
    return true;
}

/// Count decimal places in a number string
fn decimalPlaces(s: []const u8) usize {
    // Find the decimal point
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '.') {
            // Count digits after decimal point (before any e/E)
            var count: usize = 0;
            var j = i + 1;
            while (j < s.len) : (j += 1) {
                if (s[j] == 'e' or s[j] == 'E') break;
                count += 1;
            }
            return count;
        }
    }
    return 0;
}

/// Format a float value as an integer string (no decimal point)
fn formatInteger(buf: []u8, value: f64) ![]const u8 {
    const int_val = @as(i64, @intFromFloat(value));
    return std.fmt.bufPrint(buf, "{d}", .{int_val});
}

/// Format a float value with a given number of decimal places
fn formatDecimal(buf: []u8, value: f64, precision: usize) ![]const u8 {
    // Use bufPrint with the appropriate precision
    // We need to format manually since we can't use runtime precision
    // with comptime format strings
    return formatWithPrecision(buf, value, precision);
}

/// Format a number with runtime-determined precision
fn formatWithPrecision(buf: []u8, value: f64, precision: usize) ![]const u8 {
    if (precision == 0) {
        return formatInteger(buf, value);
    }

    // Format the integer part
    const negative = value < 0;
    const abs_val = @abs(value);
    const int_part = @as(u64, @intFromFloat(abs_val));

    // Calculate fractional part
    var multiplier: f64 = 1.0;
    for (0..precision) |_| {
        multiplier *= 10.0;
    }
    const frac_raw = (abs_val - @as(f64, @floatFromInt(int_part))) * multiplier;
    const frac_part = @as(u64, @intFromFloat(frac_raw + 0.5));

    // Check if rounding the fractional part causes carry
    var frac_limit: u64 = 1;
    for (0..precision) |_| {
        frac_limit *= 10;
    }

    if (frac_part >= frac_limit) {
        // Carry into integer part
        const carried_int = int_part + 1;
        if (negative) {
            const result = std.fmt.bufPrint(buf, "-{d}.{d:0>1}", .{ carried_int, @as(u64, 0) });
            if (result) |r| {
                // Pad fractional part to correct width
                return padFractional(buf, r, precision);
            } else |_| return error.NoSpaceLeft;
        } else {
            const result = std.fmt.bufPrint(buf, "{d}.{d:0>1}", .{ carried_int, @as(u64, 0) });
            if (result) |r| {
                return padFractional(buf, r, precision);
            } else |_| return error.NoSpaceLeft;
        }
    }

    // Format with enough digits
    if (negative) {
        const result = std.fmt.bufPrint(buf, "-{d}.", .{int_part});
        if (result) |r| {
            return appendFracDigits(buf, r.len, frac_part, precision);
        } else |_| return error.NoSpaceLeft;
    } else {
        const result = std.fmt.bufPrint(buf, "{d}.", .{int_part});
        if (result) |r| {
            return appendFracDigits(buf, r.len, frac_part, precision);
        } else |_| return error.NoSpaceLeft;
    }
}

/// Append fractional digits with zero-padding to precision width
fn appendFracDigits(buf: []u8, offset: usize, frac: u64, precision: usize) ![]const u8 {
    // Write digits in reverse order
    var digits: [32]u8 = undefined;
    var f = frac;
    var count: usize = 0;
    while (count < precision) : (count += 1) {
        digits[precision - 1 - count] = @intCast((f % 10) + '0');
        f /= 10;
    }
    // Copy digits to buffer
    if (offset + precision > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[offset .. offset + precision], digits[0..precision]);
    return buf[0 .. offset + precision];
}

/// Fix fractional part to have correct precision (pad with zeros)
fn padFractional(buf: []u8, formatted: []const u8, precision: usize) []const u8 {
    // Find the dot
    var dot_pos: usize = 0;
    for (formatted, 0..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }
    const current_frac_len = formatted.len - dot_pos - 1;
    if (current_frac_len >= precision) {
        return formatted[0 .. dot_pos + 1 + precision];
    }
    // Pad with zeros
    const needed = precision - current_frac_len;
    var end = formatted.len;
    for (0..needed) |_| {
        if (end < buf.len) {
            buf[end] = '0';
            end += 1;
        }
    }
    return buf[0..end];
}

/// Format number according to -f format specifier
fn formatWithSpec(buf: []u8, value: f64, fmt_str: []const u8) ![]const u8 {
    // Parse the format string to find the specifier
    // Support: %g (default), %f (fixed 6 decimals), %e (scientific)
    // Look for the conversion specifier
    var i: usize = 0;
    while (i < fmt_str.len) : (i += 1) {
        if (fmt_str[i] == '%') {
            if (i + 1 < fmt_str.len and fmt_str[i + 1] == '%') {
                i += 1; // Skip %%
                continue;
            }
            // Found format spec, skip to conversion char
            var j = i + 1;
            // Skip flags
            while (j < fmt_str.len and (fmt_str[j] == '-' or fmt_str[j] == '+' or
                fmt_str[j] == ' ' or fmt_str[j] == '0' or fmt_str[j] == '#')) : (j += 1)
            {}
            // Skip width
            while (j < fmt_str.len and fmt_str[j] >= '0' and fmt_str[j] <= '9') : (j += 1) {}
            // Skip precision
            if (j < fmt_str.len and fmt_str[j] == '.') {
                j += 1;
                while (j < fmt_str.len and fmt_str[j] >= '0' and fmt_str[j] <= '9') : (j += 1) {}
            }
            // Conversion character
            if (j < fmt_str.len) {
                switch (fmt_str[j]) {
                    'f' => return formatDecimal(buf, value, 6),
                    'e', 'E' => return formatScientific(buf, value),
                    'g', 'G' => return formatGeneral(buf, value),
                    else => return formatGeneral(buf, value),
                }
            }
        }
    }
    // No format spec found, use default
    return formatGeneral(buf, value);
}

/// Format in scientific notation (like %e)
fn formatScientific(buf: []u8, value: f64) ![]const u8 {
    if (value == 0.0) {
        return std.fmt.bufPrint(buf, "0.000000e+00", .{});
    }
    const negative = value < 0;
    const abs_val = @abs(value);
    var exp: i32 = 0;
    var mantissa = abs_val;

    if (mantissa >= 10.0) {
        while (mantissa >= 10.0) {
            mantissa /= 10.0;
            exp += 1;
        }
    } else if (mantissa < 1.0 and mantissa > 0.0) {
        while (mantissa < 1.0) {
            mantissa *= 10.0;
            exp -= 1;
        }
    }

    // Format mantissa with 6 decimal places
    var mant_buf: [64]u8 = undefined;
    const mant_str = try formatDecimal(&mant_buf, if (negative) -mantissa else mantissa, 6);

    const sign: u8 = if (exp >= 0) '+' else '-';
    const abs_exp = if (exp >= 0) @as(u32, @intCast(exp)) else @as(u32, @intCast(-exp));
    return std.fmt.bufPrint(buf, "{s}e{c}{d:0>2}", .{ mant_str, sign, abs_exp });
}

/// Format using %g style (remove trailing zeros)
fn formatGeneral(buf: []u8, value: f64) ![]const u8 {
    // For %g, use the shorter of %f and %e, with trailing zeros removed
    // Simple approach: format with high precision, trim trailing zeros
    var tmp_buf: [64]u8 = undefined;
    const formatted = try formatDecimal(&tmp_buf, value, 10);

    // Find the decimal point
    var has_dot = false;
    for (formatted) |c| {
        if (c == '.') {
            has_dot = true;
            break;
        }
    }

    if (!has_dot) {
        @memcpy(buf[0..formatted.len], formatted);
        return buf[0..formatted.len];
    }

    // Trim trailing zeros after decimal point
    var end = formatted.len;
    while (end > 0 and formatted[end - 1] == '0') {
        end -= 1;
    }
    // Remove trailing dot too
    if (end > 0 and formatted[end - 1] == '.') {
        end -= 1;
    }

    @memcpy(buf[0..end], formatted[0..end]);
    return buf[0..end];
}

/// Compute the display width of a number for -w padding
fn numberWidth(value: f64, use_decimal: bool, precision: usize) usize {
    var buf: [64]u8 = undefined;
    const formatted = if (use_decimal)
        formatDecimal(&buf, value, precision) catch return 1
    else
        formatInteger(&buf, value) catch return 1;
    return formatted.len;
}

/// Main entry point for the seq utility
pub fn runSeq(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments
    const parsed_args = common.argparse.ArgParser.parse(SeqArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "option missing required argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate positional arguments
    const positionals = parsed_args.positionals;
    if (positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "seq", "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }
    if (positionals.len > 3) {
        common.printErrorWithProgram(allocator, stderr_writer, "seq", "extra operand '{s}'", .{positionals[3]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Parse FIRST, INCREMENT, LAST
    var first: f64 = 1.0;
    var increment: f64 = 1.0;
    var last: f64 = undefined;
    var first_str: []const u8 = "1";
    var incr_str: []const u8 = "1";
    var last_str: []const u8 = undefined;

    switch (positionals.len) {
        1 => {
            last = std.fmt.parseFloat(f64, positionals[0]) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid floating point argument: '{s}'", .{positionals[0]});
                return @intFromEnum(common.ExitCode.misuse);
            };
            last_str = positionals[0];
        },
        2 => {
            first = std.fmt.parseFloat(f64, positionals[0]) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid floating point argument: '{s}'", .{positionals[0]});
                return @intFromEnum(common.ExitCode.misuse);
            };
            first_str = positionals[0];
            last = std.fmt.parseFloat(f64, positionals[1]) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid floating point argument: '{s}'", .{positionals[1]});
                return @intFromEnum(common.ExitCode.misuse);
            };
            last_str = positionals[1];
        },
        3 => {
            first = std.fmt.parseFloat(f64, positionals[0]) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid floating point argument: '{s}'", .{positionals[0]});
                return @intFromEnum(common.ExitCode.misuse);
            };
            first_str = positionals[0];
            increment = std.fmt.parseFloat(f64, positionals[1]) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid floating point argument: '{s}'", .{positionals[1]});
                return @intFromEnum(common.ExitCode.misuse);
            };
            incr_str = positionals[1];
            last = std.fmt.parseFloat(f64, positionals[2]) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid floating point argument: '{s}'", .{positionals[2]});
                return @intFromEnum(common.ExitCode.misuse);
            };
            last_str = positionals[2];
        },
        else => unreachable,
    }

    // Validate increment
    if (increment == 0.0) {
        common.printErrorWithProgram(allocator, stderr_writer, "seq", "invalid Zero increment value: '{s}'", .{incr_str});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Determine formatting mode
    const use_format = parsed_args.format;
    const separator = parsed_args.separator orelse "\n";

    // Determine if we should use integer or decimal formatting
    const all_integers = isInteger(first_str) and isInteger(incr_str) and isInteger(last_str);
    const precision = if (all_integers)
        @as(usize, 0)
    else
        @max(@max(decimalPlaces(first_str), decimalPlaces(incr_str)), decimalPlaces(last_str));

    // Compute width for -w flag
    var pad_width: usize = 0;
    if (parsed_args.equal_width) {
        const first_width = numberWidth(first, !all_integers, precision);
        const last_width = numberWidth(last, !all_integers, precision);
        pad_width = @max(first_width, last_width);
    }

    // Generate the sequence
    var printed_first = false;
    var current = first;

    if (increment > 0) {
        while (current <= last + (increment * 0.5e-10)) : (current += increment) {
            // Avoid floating point drift past last
            if (current > last + (increment * 0.5e-10)) break;

            if (printed_first) {
                try stdout_writer.writeAll(separator);
            }
            printed_first = true;

            try printNumber(stdout_writer, current, all_integers, precision, pad_width, use_format);
        }
    } else {
        // Negative increment (counting down)
        while (current >= last - (@abs(increment) * 0.5e-10)) : (current += increment) {
            if (current < last - (@abs(increment) * 0.5e-10)) break;

            if (printed_first) {
                try stdout_writer.writeAll(separator);
            }
            printed_first = true;

            try printNumber(stdout_writer, current, all_integers, precision, pad_width, use_format);
        }
    }

    // Print final newline if we printed anything
    if (printed_first) {
        try stdout_writer.writeAll("\n");
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Print a single number with the appropriate formatting
fn printNumber(writer: anytype, value: f64, all_integers: bool, precision: usize, pad_width: usize, format_str: ?[]const u8) !void {
    var buf: [128]u8 = undefined;

    const formatted = if (format_str) |fmt|
        try formatWithSpec(&buf, value, fmt)
    else if (all_integers)
        try formatInteger(&buf, value)
    else
        try formatDecimal(&buf, value, precision);

    // Apply zero-padding for -w
    if (pad_width > 0 and formatted.len < pad_width) {
        // Check if negative
        var start: usize = 0;
        if (formatted.len > 0 and formatted[0] == '-') {
            try writer.writeAll("-");
            start = 1;
        }
        const needed = pad_width - formatted.len;
        for (0..needed) |_| {
            try writer.writeAll("0");
        }
        try writer.writeAll(formatted[start..]);
    } else {
        try writer.writeAll(formatted);
    }
}

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

    const exit_code = try runSeq(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: seq [OPTION]... LAST
        \\   or: seq [OPTION]... FIRST LAST
        \\   or: seq [OPTION]... FIRST INCREMENT LAST
        \\Print numbers from FIRST to LAST, in steps of INCREMENT.
        \\
        \\  -f, --format=FORMAT  use printf style floating-point FORMAT
        \\  -s, --separator=STRING  use STRING to separate numbers (default: \n)
        \\  -w, --equal-width   equalize width by padding with leading zeroes
        \\  -h, --help          display this help and exit
        \\  -V, --version       output version information and exit
        \\
        \\If FIRST or INCREMENT is omitted, it defaults to 1. An omitted
        \\INCREMENT defaults to 1 even when LAST is smaller than FIRST.
        \\The sequence stops when adding INCREMENT would go past LAST.
        \\FIRST, INCREMENT, and LAST are interpreted as floating point values.
        \\
        \\FORMAT must be suitable for printing one argument of type 'double';
        \\it defaults to the auto-detected format based on input precision.
        \\Supported format specifiers: %f, %e, %g.
        \\
        \\Examples:
        \\  seq 5                 Print 1 through 5.
        \\  seq 3 7               Print 3 through 7.
        \\  seq 0 2 10            Print 0, 2, 4, 6, 8, 10.
        \\  seq -s ", " 3         Print "1, 2, 3".
        \\  seq -w 1 10           Print 01 through 10.
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("seq ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "seq basic: seq 5" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"5"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n2\n3\n4\n5\n", stdout_buf.items);
}

test "seq basic: seq 3 5" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "3", "5" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3\n4\n5\n", stdout_buf.items);
}

test "seq basic: seq 1 2 10" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "1", "2", "10" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n3\n5\n7\n9\n", stdout_buf.items);
}

test "seq countdown: seq 5 -1 1" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "5", "--", "-1", "1" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n4\n3\n2\n1\n", stdout_buf.items);
}

test "seq separator: seq -s ', ' 3" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", ", ", "3" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1, 2, 3\n", stdout_buf.items);
}

test "seq equal width: seq -w 1 10" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "1", "10" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("01\n02\n03\n04\n05\n06\n07\n08\n09\n10\n", stdout_buf.items);
}

test "seq empty output when direction wrong" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    // seq 5 1 with default increment 1 should print nothing
    const args = [_][]const u8{ "5", "1" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "seq single number" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"1"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n", stdout_buf.items);
}

test "seq float: seq 0.5 0.5 2.0" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "0.5", "0.5", "2.0" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.5\n1.0\n1.5\n2.0\n", stdout_buf.items);
}

test "seq error: no args" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "missing operand") != null);
}

test "seq error: too many args" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "1", "2", "3", "4" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "extra operand") != null);
}

test "seq error: invalid number" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"abc"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "invalid floating point argument") != null);
}

test "seq error: zero increment" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "1", "0", "5" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Zero increment") != null);
}

test "seq negative numbers" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "--", "-3", "-1" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-3\n-2\n-1\n", stdout_buf.items);
}

test "seq negative to positive" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "--", "-2", "2" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-2\n-1\n0\n1\n2\n", stdout_buf.items);
}

test "seq equal width with negative" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "1", "100" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    // First few should be zero-padded
    try testing.expect(std.mem.startsWith(u8, stdout_buf.items, "001\n002\n003\n"));
    // Last should not be padded
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "099\n100\n"));
}

test "seq format %f" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "%f", "3" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.000000\n2.000000\n3.000000\n", stdout_buf.items);
}

test "seq help" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage: seq") != null);
}

test "seq version" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "seq") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, common.name) != null);
}

test "seq large step" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "0", "5", "20" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0\n5\n10\n15\n20\n", stdout_buf.items);
}

test "seq decimal precision preserved" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "1.0", "0.1", "1.3" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.0\n1.1\n1.2\n1.3\n", stdout_buf.items);
}

test "seq separator with equal width" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-w", "-s", ":", "8", "10" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("08:09:10\n", stdout_buf.items);
}

// ============================================================================
// Internal function tests
// ============================================================================

test "isInteger" {
    try testing.expect(isInteger("42"));
    try testing.expect(isInteger("-7"));
    try testing.expect(isInteger("0"));
    try testing.expect(!isInteger("3.14"));
    try testing.expect(!isInteger("1e5"));
    try testing.expect(!isInteger("2.0"));
}

test "decimalPlaces" {
    try testing.expectEqual(@as(usize, 0), decimalPlaces("42"));
    try testing.expectEqual(@as(usize, 1), decimalPlaces("3.1"));
    try testing.expectEqual(@as(usize, 2), decimalPlaces("3.14"));
    try testing.expectEqual(@as(usize, 3), decimalPlaces("1.000"));
}

test "formatInteger" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("42", try formatInteger(&buf, 42.0));
    try testing.expectEqualStrings("0", try formatInteger(&buf, 0.0));
    try testing.expectEqualStrings("-5", try formatInteger(&buf, -5.0));
}

test "formatDecimal" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("3.14", try formatDecimal(&buf, 3.14, 2));
    try testing.expectEqualStrings("1.0", try formatDecimal(&buf, 1.0, 1));
    try testing.expectEqualStrings("0.5", try formatDecimal(&buf, 0.5, 1));
}

// ========== AUDIT WAVE 4: seq IMPORTANT findings ==========

// IMPORTANT: Negative increment without -- rejected as unknown option
// GNU seq 5 -1 1 outputs "5\n4\n3\n2\n1\n" (countdown).
// Our argparse sees -1 as an unknown short flag and exits with error.
test "audit: seq negative increment without double-dash" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    // seq 5 -1 1 should count down without needing --
    const args = [_][]const u8{ "5", "-1", "1" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n4\n3\n2\n1\n", stdout_buf.items);
}

// IMPORTANT: Error exit code is 2 (misuse) where GNU uses 1
// GNU seq with invalid input exits 1, not 2.
test "audit: seq invalid number exits 1 not 2" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"abc"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    // GNU uses exit code 1, not 2
    try testing.expectEqual(@as(u8, 1), result);
}

// IMPORTANT: seq with zero increment should exit 1 not 2
test "audit: seq zero increment exits 1 not 2" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "1", "0", "5" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    // GNU uses exit code 1, not 2
    try testing.expectEqual(@as(u8, 1), result);
}

// IMPORTANT: seq with no args should exit 1 not 2
test "audit: seq no args exits 1 not 2" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    // GNU uses exit code 1, not 2
    try testing.expectEqual(@as(u8, 1), result);
}

// IMPORTANT: nan input silently produces empty output instead of error
// GNU seq nan outputs error and exits 1.
test "audit: seq nan input produces error" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"nan"};
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    // Must exit non-zero (GNU uses 1)
    try testing.expect(result != 0);
    // Must emit error on stderr
    try testing.expect(stderr_buf.items.len > 0);
}

// nan as increment should also be rejected
test "audit: seq nan as increment produces error" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "1", "nan", "5" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expect(result != 0);
    try testing.expect(stderr_buf.items.len > 0);
}

// IMPORTANT: -f format prefix/suffix text dropped
// GNU seq -f 'val=%g!' 3 outputs "val=1!\nval=2!\nval=3!\n"
// Our implementation drops prefix "val=" and suffix "!"
test "audit: seq -f format preserves prefix and suffix" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "val=%g!", "3" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("val=1!\nval=2!\nval=3!\n", stdout_buf.items);
}

// IMPORTANT: -f format width and precision ignored
// GNU seq -f '%05.1f' 3 outputs "001.0\n002.0\n003.0\n"
test "audit: seq -f format respects width and precision" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "%05.1f", "3" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("001.0\n002.0\n003.0\n", stdout_buf.items);
}

// Test gap: float sequences
test "audit: seq float sequence 0.1 0.1 0.5" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "0.1", "0.1", "0.5" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.1\n0.2\n0.3\n0.4\n0.5\n", stdout_buf.items);
}

// Test gap: countdown (without -- workaround, using -- for now to
// verify the basic countdown logic works, independent of the
// argparse issue tested above)
test "audit: seq countdown with double-dash" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "10", "--", "-2", "1" };
    const result = try runSeq(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("10\n8\n6\n4\n2\n", stdout_buf.items);
}
