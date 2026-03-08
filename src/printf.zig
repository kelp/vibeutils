//! printf - format and print data
//!
//! The printf utility formats and prints its arguments under the control
//! of a format string. Unlike echo, printf uses explicit format strings
//! like C's printf, giving precise control over output formatting.
//!
//! This implementation is compatible with GNU printf and supports
//! backslash escape sequences, format specifiers with width and
//! precision, and format string reuse when extra arguments remain.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// CLI entry point -- parses process arguments and sets up I/O buffers.
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

    const exit_code = try runPrintf(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(exit_code);
}

/// Run the printf utility with given arguments.
///
/// printf does not use ArgParser since FORMAT is a positional argument.
/// Only --help and --version are handled as special cases.
pub fn runPrintf(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    if (args.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "printf", std.fs.File.stderr().isTty(), "usage: printf FORMAT [ARGUMENT...]", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Check for --help and --version before treating first arg as format
    if (std.mem.eql(u8, args[0], "--help")) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (std.mem.eql(u8, args[0], "--version")) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const format = args[0];
    const arguments = args[1..];

    var had_error = false;
    var arg_idx: usize = 0;

    // Process format string, reusing it if arguments remain
    while (true) {
        const start_arg_idx = arg_idx;
        const result = processFormat(format, arguments, &arg_idx, stdout_writer, stderr_writer, allocator);
        if (result) |_| {
            // success
        } else |_| {
            had_error = true;
        }

        // If no arguments were consumed, or all arguments have been used, stop
        if (arg_idx <= start_arg_idx or arg_idx >= arguments.len) {
            break;
        }
    }

    if (had_error) {
        return @intFromEnum(common.ExitCode.general_error);
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Process one pass of the format string, consuming arguments as needed.
/// Returns the number of arguments consumed.
fn processFormat(
    format: []const u8,
    arguments: []const []const u8,
    arg_idx: *usize,
    writer: anytype,
    stderr_writer: anytype,
    allocator: Allocator,
) !void {
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '\\') {
            // Escape sequence in format string
            const result = processEscape(format, i, writer);
            i = result.new_pos;
        } else if (format[i] == '%') {
            if (i + 1 < format.len and format[i + 1] == '%') {
                // Literal percent
                try writer.writeByte('%');
                i += 2;
            } else {
                // Format specifier
                const result = try processSpecifier(format, i, arguments, arg_idx, writer, stderr_writer, allocator);
                i = result;
            }
        } else {
            try writer.writeByte(format[i]);
            i += 1;
        }
    }
}

/// Result from processing an escape sequence
const EscapeResult = struct {
    new_pos: usize,
};

/// Process a backslash escape sequence in the format string.
/// Handles \n, \t, \r, \a, \b, \f, \v, \\, \0NNN, \xHH.
fn processEscape(format: []const u8, pos: usize, writer: anytype) EscapeResult {
    if (pos + 1 >= format.len) {
        // Trailing backslash, output literally
        writer.writeByte('\\') catch {};
        return .{ .new_pos = pos + 1 };
    }

    switch (format[pos + 1]) {
        'a' => {
            writer.writeByte('\x07') catch {};
            return .{ .new_pos = pos + 2 };
        },
        'b' => {
            writer.writeByte('\x08') catch {};
            return .{ .new_pos = pos + 2 };
        },
        'f' => {
            writer.writeByte('\x0c') catch {};
            return .{ .new_pos = pos + 2 };
        },
        'n' => {
            writer.writeByte('\n') catch {};
            return .{ .new_pos = pos + 2 };
        },
        'r' => {
            writer.writeByte('\r') catch {};
            return .{ .new_pos = pos + 2 };
        },
        't' => {
            writer.writeByte('\t') catch {};
            return .{ .new_pos = pos + 2 };
        },
        'v' => {
            writer.writeByte('\x0b') catch {};
            return .{ .new_pos = pos + 2 };
        },
        '\\' => {
            writer.writeByte('\\') catch {};
            return .{ .new_pos = pos + 2 };
        },
        '0' => {
            // Octal: \0NNN (up to 3 octal digits after the 0)
            var value: u8 = 0;
            var j: usize = pos + 2;
            var count: usize = 0;
            while (count < 3 and j < format.len and format[j] >= '0' and format[j] <= '7') : ({
                j += 1;
                count += 1;
            }) {
                value = value *% 8 +% (format[j] - '0');
            }
            writer.writeByte(value) catch {};
            return .{ .new_pos = j };
        },
        'x' => {
            // Hex: \xHH (1-2 hex digits)
            var value: u8 = 0;
            var j: usize = pos + 2;
            var hex_digits: usize = 0;
            while (hex_digits < 2 and j < format.len) : ({
                j += 1;
                hex_digits += 1;
            }) {
                const c = format[j];
                const digit: u8 = switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => break,
                };
                value = value * 16 + digit;
            }
            if (hex_digits > 0) {
                writer.writeByte(value) catch {};
                return .{ .new_pos = j };
            } else {
                // No hex digits, output \x literally
                writer.writeByte('\\') catch {};
                writer.writeByte('x') catch {};
                return .{ .new_pos = pos + 2 };
            }
        },
        else => {
            // Unknown escape, output backslash literally
            writer.writeByte('\\') catch {};
            return .{ .new_pos = pos + 1 };
        },
    }
}

/// Parse and process a format specifier starting at '%'.
/// Returns the new position in the format string.
fn processSpecifier(
    format: []const u8,
    pos: usize,
    arguments: []const []const u8,
    arg_idx: *usize,
    writer: anytype,
    stderr_writer: anytype,
    allocator: Allocator,
) !usize {
    var i = pos + 1; // Skip the '%'

    // Parse flags: -, +, space, 0, #
    var left_justify = false;
    var plus_sign = false;
    var space_sign = false;
    var zero_pad = false;
    var hash_flag = false;

    while (i < format.len) {
        switch (format[i]) {
            '-' => left_justify = true,
            '+' => plus_sign = true,
            ' ' => space_sign = true,
            '0' => zero_pad = true,
            '#' => hash_flag = true,
            else => break,
        }
        i += 1;
    }

    // Parse width
    var width: ?usize = null;
    if (i < format.len and format[i] == '*') {
        // Width from argument
        const w_str = getNextArg(arguments, arg_idx);
        width = @as(usize, @intCast(@max(0, std.fmt.parseInt(i64, w_str, 10) catch 0)));
        i += 1;
    } else {
        var w: usize = 0;
        var has_width = false;
        while (i < format.len and format[i] >= '0' and format[i] <= '9') {
            w = w * 10 + (format[i] - '0');
            has_width = true;
            i += 1;
        }
        if (has_width) width = w;
    }

    // Parse precision
    var precision: ?usize = null;
    if (i < format.len and format[i] == '.') {
        i += 1;
        if (i < format.len and format[i] == '*') {
            // Precision from argument
            const p_str = getNextArg(arguments, arg_idx);
            const p_val = std.fmt.parseInt(i64, p_str, 10) catch 0;
            precision = if (p_val >= 0) @as(usize, @intCast(p_val)) else null;
            i += 1;
        } else {
            var p: usize = 0;
            while (i < format.len and format[i] >= '0' and format[i] <= '9') {
                p = p * 10 + (format[i] - '0');
                i += 1;
            }
            precision = p;
        }
    }

    // Parse conversion character
    if (i >= format.len) {
        // Incomplete format specifier, output as literal
        try writer.writeByte('%');
        return pos + 1;
    }

    const conv = format[i];
    i += 1;

    const spec = FormatSpec{
        .left_justify = left_justify,
        .plus_sign = plus_sign,
        .space_sign = space_sign,
        .zero_pad = zero_pad,
        .hash_flag = hash_flag,
        .width = width,
        .precision = precision,
    };

    switch (conv) {
        's' => {
            const arg = getNextArg(arguments, arg_idx);
            try formatString(writer, arg, spec);
        },
        'b' => {
            const arg = getNextArg(arguments, arg_idx);
            try formatBString(writer, arg);
        },
        'c' => {
            const arg = getNextArg(arguments, arg_idx);
            if (arg.len > 0) {
                try writer.writeByte(arg[0]);
            }
        },
        'd', 'i' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseIntArg(arg);
            try formatSignedInt(writer, val, 10, false, spec, stderr_writer, allocator, arg);
        },
        'u' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseUintArg(arg);
            try formatUnsignedInt(writer, val, 10, false, spec);
        },
        'o' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseUintArg(arg);
            try formatUnsignedInt(writer, val, 8, spec.hash_flag, spec);
        },
        'x' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseUintArg(arg);
            try formatHex(writer, val, false, spec);
        },
        'X' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseUintArg(arg);
            try formatHex(writer, val, true, spec);
        },
        'f' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseFloatArg(arg);
            try formatFloat(writer, val, 'f', spec);
        },
        'e' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseFloatArg(arg);
            try formatFloat(writer, val, 'e', spec);
        },
        'E' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseFloatArg(arg);
            try formatFloat(writer, val, 'E', spec);
        },
        'g' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseFloatArg(arg);
            try formatFloat(writer, val, 'g', spec);
        },
        'G' => {
            const arg = getNextArg(arguments, arg_idx);
            const val = parseFloatArg(arg);
            try formatFloat(writer, val, 'G', spec);
        },
        else => {
            // Unknown specifier, output literally
            try writer.writeByte('%');
            try writer.writeByte(conv);
        },
    }

    return i;
}

/// Format specifier flags and modifiers
const FormatSpec = struct {
    left_justify: bool = false,
    plus_sign: bool = false,
    space_sign: bool = false,
    zero_pad: bool = false,
    hash_flag: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
};

/// Get the next argument, or empty string if none remain
fn getNextArg(arguments: []const []const u8, arg_idx: *usize) []const u8 {
    if (arg_idx.* < arguments.len) {
        const arg = arguments[arg_idx.*];
        arg_idx.* += 1;
        return arg;
    }
    return "";
}

/// Parse string as signed integer. Handles 0x, 0, and leading quote/dquote
/// for character values. Returns 0 for unparseable strings.
fn parseIntArg(s: []const u8) i64 {
    if (s.len == 0) return 0;

    // Leading ' or " means character value
    if ((s[0] == '\'' or s[0] == '"') and s.len >= 2) {
        return @as(i64, s[1]);
    }

    // Try hex (0x or 0X prefix)
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        return std.fmt.parseInt(i64, s[2..], 16) catch 0;
    }

    // Try octal (0 prefix, but not just "0")
    if (s.len > 1 and s[0] == '0') {
        return std.fmt.parseInt(i64, s[1..], 8) catch {
            return std.fmt.parseInt(i64, s, 10) catch 0;
        };
    }

    return std.fmt.parseInt(i64, s, 10) catch 0;
}

/// Parse string as unsigned integer with same rules as parseIntArg.
fn parseUintArg(s: []const u8) u64 {
    if (s.len == 0) return 0;

    // Leading ' or " means character value
    if ((s[0] == '\'' or s[0] == '"') and s.len >= 2) {
        return @as(u64, s[1]);
    }

    // Try hex
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        return std.fmt.parseInt(u64, s[2..], 16) catch 0;
    }

    // Try octal
    if (s.len > 1 and s[0] == '0') {
        return std.fmt.parseInt(u64, s[1..], 8) catch {
            return std.fmt.parseInt(u64, s, 10) catch 0;
        };
    }

    return std.fmt.parseInt(u64, s, 10) catch 0;
}

/// Parse string as floating-point number. Returns 0.0 for unparseable strings.
fn parseFloatArg(s: []const u8) f64 {
    if (s.len == 0) return 0.0;

    // Leading ' or " means character value
    if ((s[0] == '\'' or s[0] == '"') and s.len >= 2) {
        return @as(f64, @floatFromInt(@as(i64, s[1])));
    }

    // Try hex integer first (parseFloat doesn't handle 0x)
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        const val = std.fmt.parseInt(i64, s[2..], 16) catch return 0.0;
        return @as(f64, @floatFromInt(val));
    }

    return std.fmt.parseFloat(f64, s) catch 0.0;
}

/// Format a string with width and precision
fn formatString(writer: anytype, s: []const u8, spec: FormatSpec) !void {
    // Precision truncates the string
    const truncated = if (spec.precision) |p|
        s[0..@min(p, s.len)]
    else
        s;

    const w = spec.width orelse 0;
    if (truncated.len >= w) {
        try writer.writeAll(truncated);
    } else {
        const padding = w - truncated.len;
        if (spec.left_justify) {
            try writer.writeAll(truncated);
            try writePadding(writer, ' ', padding);
        } else {
            try writePadding(writer, ' ', padding);
            try writer.writeAll(truncated);
        }
    }
}

/// Format a %b string (with backslash escape interpretation like echo -e)
fn formatBString(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'a' => {
                    try writer.writeByte('\x07');
                    i += 2;
                },
                'b' => {
                    try writer.writeByte('\x08');
                    i += 2;
                },
                'c' => {
                    // \c suppresses further output -- for %b this means
                    // we stop and the caller should stop too. Since we
                    // can only control our own output, just return.
                    return;
                },
                'f' => {
                    try writer.writeByte('\x0c');
                    i += 2;
                },
                'n' => {
                    try writer.writeByte('\n');
                    i += 2;
                },
                'r' => {
                    try writer.writeByte('\r');
                    i += 2;
                },
                't' => {
                    try writer.writeByte('\t');
                    i += 2;
                },
                'v' => {
                    try writer.writeByte('\x0b');
                    i += 2;
                },
                '\\' => {
                    try writer.writeByte('\\');
                    i += 2;
                },
                '0'...'7' => {
                    var value: u8 = 0;
                    var j: usize = 1;
                    while (j <= 3 and i + j < s.len and s[i + j] >= '0' and s[i + j] <= '7') : (j += 1) {
                        value = value *% 8 +% (s[i + j] - '0');
                    }
                    try writer.writeByte(value);
                    i += j;
                },
                'x' => {
                    var value: u8 = 0;
                    var j: usize = 2;
                    var hex_digits: usize = 0;
                    while (hex_digits < 2 and i + j < s.len) : ({
                        j += 1;
                        hex_digits += 1;
                    }) {
                        const c = s[i + j];
                        const digit: u8 = switch (c) {
                            '0'...'9' => c - '0',
                            'a'...'f' => c - 'a' + 10,
                            'A'...'F' => c - 'A' + 10,
                            else => break,
                        };
                        value = value * 16 + digit;
                    }
                    if (hex_digits > 0) {
                        try writer.writeByte(value);
                        i += j;
                    } else {
                        try writer.writeByte('\\');
                        try writer.writeByte('x');
                        i += 2;
                    }
                },
                else => {
                    try writer.writeByte('\\');
                    i += 1;
                },
            }
        } else {
            try writer.writeByte(s[i]);
            i += 1;
        }
    }
}

/// Format a signed integer with the given radix and spec
fn formatSignedInt(
    writer: anytype,
    val: i64,
    radix: u8,
    _: bool,
    spec: FormatSpec,
    stderr_writer: anytype,
    allocator: Allocator,
    arg_str: []const u8,
) !void {
    _ = stderr_writer;
    _ = allocator;
    _ = arg_str;
    var buf: [128]u8 = undefined;
    const negative = val < 0;
    const abs_val: u64 = if (negative) @intCast(-val) else @intCast(val);

    // Format the number without sign
    var num_buf: [64]u8 = undefined;
    const num_str = formatUnsignedBuf(&num_buf, abs_val, radix, false);

    // Build the full string with sign, padding
    var sign_char: ?u8 = null;
    if (negative) {
        sign_char = '-';
    } else if (spec.plus_sign) {
        sign_char = '+';
    } else if (spec.space_sign) {
        sign_char = ' ';
    }

    const sign_len: usize = if (sign_char != null) 1 else 0;
    const total_digits = num_str.len;
    const w = spec.width orelse 0;
    const min_digits = spec.precision orelse 0;

    // Precision specifies minimum digits
    const zero_prefix = if (min_digits > total_digits) min_digits - total_digits else 0;
    const content_len = sign_len + zero_prefix + total_digits;

    const padding = if (w > content_len) w - content_len else 0;

    // With precision, zero_pad flag is ignored
    const use_zero_pad = spec.zero_pad and spec.precision == null and !spec.left_justify;

    var pos: usize = 0;
    if (spec.left_justify) {
        if (sign_char) |sc| {
            buf[pos] = sc;
            pos += 1;
        }
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
        pos = fillBuf(&buf, pos, ' ', padding);
    } else if (use_zero_pad) {
        if (sign_char) |sc| {
            buf[pos] = sc;
            pos += 1;
        }
        pos = fillBuf(&buf, pos, '0', padding);
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
    } else {
        pos = fillBuf(&buf, pos, ' ', padding);
        if (sign_char) |sc| {
            buf[pos] = sc;
            pos += 1;
        }
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
    }

    try writer.writeAll(buf[0..pos]);
}

/// Format an unsigned integer with the given radix and spec
fn formatUnsignedInt(writer: anytype, val: u64, radix: u8, prefix: bool, spec: FormatSpec) !void {
    var buf: [128]u8 = undefined;
    var num_buf: [64]u8 = undefined;
    const num_str = formatUnsignedBuf(&num_buf, val, radix, false);

    const prefix_str: []const u8 = if (prefix and val != 0 and radix == 8) "0" else "";
    const w = spec.width orelse 0;
    const min_digits = spec.precision orelse 0;

    const zero_prefix = if (min_digits > num_str.len) min_digits - num_str.len else 0;
    const content_len = prefix_str.len + zero_prefix + num_str.len;
    const padding = if (w > content_len) w - content_len else 0;
    const use_zero_pad = spec.zero_pad and spec.precision == null and !spec.left_justify;

    var pos: usize = 0;
    if (spec.left_justify) {
        @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
        pos += prefix_str.len;
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
        pos = fillBuf(&buf, pos, ' ', padding);
    } else if (use_zero_pad) {
        @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
        pos += prefix_str.len;
        pos = fillBuf(&buf, pos, '0', padding);
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
    } else {
        pos = fillBuf(&buf, pos, ' ', padding);
        @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
        pos += prefix_str.len;
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
    }

    try writer.writeAll(buf[0..pos]);
}

/// Format a hex integer with optional uppercase
fn formatHex(writer: anytype, val: u64, uppercase: bool, spec: FormatSpec) !void {
    var buf: [128]u8 = undefined;
    var num_buf: [64]u8 = undefined;
    const num_str = formatUnsignedBuf(&num_buf, val, 16, uppercase);

    const prefix_str: []const u8 = if (spec.hash_flag and val != 0)
        (if (uppercase) "0X" else "0x")
    else
        "";

    const w = spec.width orelse 0;
    const min_digits = spec.precision orelse 0;
    const zero_prefix = if (min_digits > num_str.len) min_digits - num_str.len else 0;
    const content_len = prefix_str.len + zero_prefix + num_str.len;
    const padding = if (w > content_len) w - content_len else 0;
    const use_zero_pad = spec.zero_pad and spec.precision == null and !spec.left_justify;

    var pos: usize = 0;
    if (spec.left_justify) {
        @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
        pos += prefix_str.len;
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
        pos = fillBuf(&buf, pos, ' ', padding);
    } else if (use_zero_pad) {
        @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
        pos += prefix_str.len;
        pos = fillBuf(&buf, pos, '0', padding);
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
    } else {
        pos = fillBuf(&buf, pos, ' ', padding);
        @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
        pos += prefix_str.len;
        pos = fillBuf(&buf, pos, '0', zero_prefix);
        @memcpy(buf[pos .. pos + num_str.len], num_str);
        pos += num_str.len;
    }

    try writer.writeAll(buf[0..pos]);
}

/// Format an unsigned integer into a buffer. Returns the formatted slice.
fn formatUnsignedBuf(buf: []u8, val: u64, radix: u8, uppercase: bool) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    var v = val;
    var pos: usize = buf.len;
    while (v > 0) {
        pos -= 1;
        const digit: u8 = @intCast(v % radix);
        if (digit < 10) {
            buf[pos] = '0' + digit;
        } else if (uppercase) {
            buf[pos] = 'A' + digit - 10;
        } else {
            buf[pos] = 'a' + digit - 10;
        }
        v /= radix;
    }

    return buf[pos..];
}

/// Fill buffer with a repeated character
fn fillBuf(buf: []u8, start: usize, char: u8, count: usize) usize {
    var i: usize = 0;
    while (i < count and start + i < buf.len) : (i += 1) {
        buf[start + i] = char;
    }
    return start + i;
}

/// Write padding characters to writer
fn writePadding(writer: anytype, char: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(char);
    }
}

/// Format a floating-point number.
/// conv is one of: 'f', 'e', 'E', 'g', 'G'
fn formatFloat(writer: anytype, val: f64, conv: u8, spec: FormatSpec) !void {
    var buf: [256]u8 = undefined;
    const prec = spec.precision orelse 6;

    const formatted = switch (conv) {
        'f' => try formatFixedFloat(&buf, val, prec),
        'e' => try formatSciFloat(&buf, val, prec, false),
        'E' => try formatSciFloat(&buf, val, prec, true),
        'g' => try formatGeneralFloat(&buf, val, prec, false),
        'G' => try formatGeneralFloat(&buf, val, prec, true),
        else => try formatFixedFloat(&buf, val, prec),
    };

    // Apply sign prefix
    var sign_char: ?u8 = null;
    var formatted_start: usize = 0;
    const is_negative = formatted.len > 0 and formatted[0] == '-';
    if (is_negative) {
        sign_char = '-';
        formatted_start = 1;
    } else if (spec.plus_sign) {
        sign_char = '+';
    } else if (spec.space_sign) {
        sign_char = ' ';
    }

    const content = formatted[formatted_start..];
    const sign_len: usize = if (sign_char != null) 1 else 0;
    const content_len = sign_len + content.len;
    const w = spec.width orelse 0;
    const padding = if (w > content_len) w - content_len else 0;
    const use_zero_pad = spec.zero_pad and !spec.left_justify;

    if (spec.left_justify) {
        if (sign_char) |sc| try writer.writeByte(sc);
        try writer.writeAll(content);
        try writePadding(writer, ' ', padding);
    } else if (use_zero_pad) {
        if (sign_char) |sc| try writer.writeByte(sc);
        try writePadding(writer, '0', padding);
        try writer.writeAll(content);
    } else {
        try writePadding(writer, ' ', padding);
        if (sign_char) |sc| try writer.writeByte(sc);
        try writer.writeAll(content);
    }
}

/// Format a floating-point number in fixed notation (%f).
fn formatFixedFloat(buf: []u8, val: f64, precision: usize) ![]const u8 {
    const negative = val < 0;
    const abs_val = @abs(val);
    const int_part = @as(u64, @intFromFloat(abs_val));
    const frac = abs_val - @as(f64, @floatFromInt(int_part));

    var pos: usize = 0;
    if (negative) {
        buf[pos] = '-';
        pos += 1;
    }

    // Format integer part
    var int_buf: [64]u8 = undefined;
    const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{int_part}) catch "0";
    @memcpy(buf[pos .. pos + int_str.len], int_str);
    pos += int_str.len;

    if (precision > 0) {
        buf[pos] = '.';
        pos += 1;

        // Compute fractional digits
        var f = frac;
        var i: usize = 0;
        while (i < precision) : (i += 1) {
            f *= 10.0;
            const digit: u8 = @intFromFloat(@mod(f, 10.0));
            buf[pos] = '0' + digit;
            pos += 1;
        }

        // Round last digit
        const next_f = f * 10.0;
        const next_digit: u8 = @intFromFloat(@mod(next_f, 10.0));
        if (next_digit >= 5 and pos > 0) {
            // Carry
            var carry_pos = pos - 1;
            while (true) {
                if (buf[carry_pos] == '.') {
                    if (carry_pos == 0) break;
                    carry_pos -= 1;
                    continue;
                }
                if (buf[carry_pos] < '9') {
                    buf[carry_pos] += 1;
                    break;
                }
                buf[carry_pos] = '0';
                if (carry_pos == 0 or (negative and carry_pos == 1)) break;
                carry_pos -= 1;
            }
        }
    }

    return buf[0..pos];
}

/// Format a floating-point number in scientific notation (%e/%E).
fn formatSciFloat(buf: []u8, val: f64, precision: usize, uppercase: bool) ![]const u8 {
    if (val == 0.0) {
        var pos: usize = 0;
        buf[pos] = '0';
        pos += 1;
        if (precision > 0) {
            buf[pos] = '.';
            pos += 1;
            var i: usize = 0;
            while (i < precision) : (i += 1) {
                buf[pos] = '0';
                pos += 1;
            }
        }
        buf[pos] = if (uppercase) 'E' else 'e';
        pos += 1;
        buf[pos] = '+';
        pos += 1;
        buf[pos] = '0';
        pos += 1;
        buf[pos] = '0';
        pos += 1;
        return buf[0..pos];
    }

    const negative = val < 0;
    var abs_val = @abs(val);
    var exponent: i32 = 0;

    if (abs_val >= 10.0) {
        while (abs_val >= 10.0) {
            abs_val /= 10.0;
            exponent += 1;
        }
    } else if (abs_val < 1.0 and abs_val > 0.0) {
        while (abs_val < 1.0) {
            abs_val *= 10.0;
            exponent -= 1;
        }
    }

    // Format the mantissa
    var mant_buf: [128]u8 = undefined;
    const mant_val = if (negative) -abs_val else abs_val;
    const mant_str = try formatFixedFloat(&mant_buf, mant_val, precision);

    var pos: usize = 0;
    @memcpy(buf[pos .. pos + mant_str.len], mant_str);
    pos += mant_str.len;

    buf[pos] = if (uppercase) 'E' else 'e';
    pos += 1;

    buf[pos] = if (exponent >= 0) '+' else '-';
    pos += 1;

    const abs_exp: u32 = if (exponent >= 0) @intCast(exponent) else @intCast(-exponent);
    var exp_buf: [16]u8 = undefined;
    const exp_str = std.fmt.bufPrint(&exp_buf, "{d:0>2}", .{abs_exp}) catch "00";
    @memcpy(buf[pos .. pos + exp_str.len], exp_str);
    pos += exp_str.len;

    return buf[0..pos];
}

/// Format a floating-point number in general notation (%g/%G).
/// Uses %e if exponent < -4 or >= precision, otherwise %f.
/// Trailing zeros are removed from the fractional part.
fn formatGeneralFloat(buf: []u8, val: f64, precision: usize, uppercase: bool) ![]const u8 {
    const prec = if (precision == 0) 1 else precision;

    if (val == 0.0) {
        buf[0] = '0';
        return buf[0..1];
    }

    const abs_val = @abs(val);
    var exponent: i32 = 0;
    var tmp = abs_val;

    if (tmp >= 10.0) {
        while (tmp >= 10.0) {
            tmp /= 10.0;
            exponent += 1;
        }
    } else if (tmp < 1.0 and tmp > 0.0) {
        while (tmp < 1.0) {
            tmp *= 10.0;
            exponent -= 1;
        }
    }

    if (exponent < -4 or exponent >= @as(i32, @intCast(prec))) {
        // Use scientific notation
        var sci_buf: [256]u8 = undefined;
        const sci = try formatSciFloat(&sci_buf, val, if (prec > 1) prec - 1 else 0, uppercase);
        @memcpy(buf[0..sci.len], sci);
        return stripTrailingZerosSci(buf[0..sci.len]);
    } else {
        // Use fixed notation
        // Precision for %g means significant digits, not decimal places
        const decimal_places = if (@as(i32, @intCast(prec)) > exponent + 1)
            @as(usize, @intCast(@as(i32, @intCast(prec)) - exponent - 1))
        else
            0;
        var fixed_buf: [256]u8 = undefined;
        const fixed = try formatFixedFloat(&fixed_buf, val, decimal_places);
        @memcpy(buf[0..fixed.len], fixed);
        return stripTrailingZerosFixed(buf[0..fixed.len]);
    }
}

/// Strip trailing zeros from a fixed-notation number (after the decimal point)
fn stripTrailingZerosFixed(s: []u8) []const u8 {
    // Find the decimal point
    var dot_pos: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }
    if (dot_pos == null) return s;

    var end = s.len;
    while (end > dot_pos.? + 1 and s[end - 1] == '0') {
        end -= 1;
    }
    // Remove trailing dot
    if (end > 0 and s[end - 1] == '.') {
        end -= 1;
    }
    return s[0..end];
}

/// Strip trailing zeros from a scientific-notation number (before the e/E)
fn stripTrailingZerosSci(s: []u8) []const u8 {
    // Find the e/E
    var e_pos: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == 'e' or c == 'E') {
            e_pos = i;
            break;
        }
    }
    if (e_pos == null) return s;

    // Find the dot
    var dot_pos: ?usize = null;
    for (s[0..e_pos.?], 0..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }
    if (dot_pos == null) return s;

    // Strip zeros between dot and e
    var strip_end = e_pos.?;
    while (strip_end > dot_pos.? + 1 and s[strip_end - 1] == '0') {
        strip_end -= 1;
    }
    // Remove dot if no fractional part
    if (strip_end > 0 and s[strip_end - 1] == '.') {
        strip_end -= 1;
    }

    // Move the exponent part
    const exp_part = s[e_pos.?..];
    var i: usize = 0;
    while (i < exp_part.len) : (i += 1) {
        s[strip_end + i] = exp_part[i];
    }
    return s[0 .. strip_end + exp_part.len];
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: printf FORMAT [ARGUMENT...]
        \\Print ARGUMENT(s) according to FORMAT.
        \\
        \\FORMAT controls the output, with the following interpreted sequences:
        \\  \"      double quote
        \\  \\\\     backslash
        \\  \\a     alert (BEL)
        \\  \\b     backspace
        \\  \\f     form feed
        \\  \\n     new line
        \\  \\r     carriage return
        \\  \\t     horizontal tab
        \\  \\v     vertical tab
        \\  \\0NNN  byte with octal value NNN (1 to 3 digits)
        \\  \\xHH   byte with hexadecimal value HH (1 to 2 digits)
        \\  %%     a single %
        \\  %b     ARGUMENT as a string with '\\' escapes interpreted
        \\  %s     ARGUMENT as a string
        \\  %c     first character of ARGUMENT
        \\  %d,%i  ARGUMENT as a signed decimal integer
        \\  %u     ARGUMENT as an unsigned decimal integer
        \\  %o     ARGUMENT as an unsigned octal integer
        \\  %x,%X  ARGUMENT as an unsigned hexadecimal integer
        \\  %f     ARGUMENT as a floating-point number
        \\  %e,%E  ARGUMENT in scientific notation
        \\  %g,%G  ARGUMENT in shorter of %f or %e
        \\
        \\  --help     display this help and exit
        \\  --version  output version information and exit
        \\
        \\FORMAT is reused as necessary to consume all ARGUMENTs.
        \\Missing arguments are treated as empty strings or zero.
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("printf ({s}) {s}\n", .{ common.name, common.version });
}

// ========== TESTS ==========

test "printf basic string" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%s", "hello" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello", buffer.items);
}

test "printf string with newline escape" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%s\\n", "hello" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", buffer.items);
}

test "printf integer formatting" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%d", "42" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("42", buffer.items);
}

test "printf negative integer" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%d", "-7" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-7", buffer.items);
}

test "printf octal" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%o", "255" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("377", buffer.items);
}

test "printf hex lowercase" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%x", "255" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("ff", buffer.items);
}

test "printf hex uppercase" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%X", "255" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("FF", buffer.items);
}

test "printf unsigned integer" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%u", "42" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("42", buffer.items);
}

test "printf character" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%c", "A" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer.items);
}

test "printf float" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%f", "3.14" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3.140000", buffer.items);
}

test "printf literal percent" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"100%%"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("100%", buffer.items);
}

test "printf width right-aligned" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%10s", "hello" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("     hello", buffer.items);
}

test "printf width left-aligned" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%-10s", "hello" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello     ", buffer.items);
}

test "printf precision truncates string" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%.3s", "hello" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hel", buffer.items);
}

test "printf zero-padded integer" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%05d", "42" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("00042", buffer.items);
}

test "printf format string reuse" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%s\\n", "a", "b", "c" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\nb\nc\n", buffer.items);
}

test "printf missing argument defaults to empty string" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"%s"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer.items);
}

test "printf missing argument defaults to zero for integers" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"%d"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0", buffer.items);
}

test "printf escape sequences in format" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"\\t\\n\\r\\a"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\n\r\x07", buffer.items);
}

test "printf octal escape in format" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"\\0101"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer.items);
}

test "printf hex escape in format" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"\\x41"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer.items);
}

test "printf backslash escape" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"\\\\"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\\", buffer.items);
}

test "printf %b with escape sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%b", "hello\\nworld" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "printf no arguments shows usage error" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    var stderr = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), stderr.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "printf --help" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: printf") != null);
}

test "printf --version" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "printf") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.version) != null);
}

test "printf multiple format specifiers" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "Name: %s Age: %d\\n", "Alice", "30" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("Name: Alice Age: 30\n", buffer.items);
}

test "printf character from quote syntax" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%d", "'A" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("65", buffer.items);
}

test "printf hex argument prefix" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%d", "0xff" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("255", buffer.items);
}

test "printf octal argument prefix" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%d", "010" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("8", buffer.items);
}

test "printf scientific notation" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%e", "100000" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.000000e+05", buffer.items);
}

test "printf plus sign flag" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%+d", "42" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("+42", buffer.items);
}

test "printf hash flag for octal" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%#o", "8" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("010", buffer.items);
}

test "printf hash flag for hex" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%#x", "255" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0xff", buffer.items);
}

test "printf width with integer" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%8d", "42" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("      42", buffer.items);
}

test "printf empty format" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{""};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer.items);
}

test "printf plain text no specifiers" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"hello world"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world", buffer.items);
}

test "printf %g removes trailing zeros" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%g", "3.0" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3", buffer.items);
}

test "printf %c with empty argument" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%c", "" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer.items);
}

test "printf %c with missing argument" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"%c"};
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer.items);
}

test "printf float with precision" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%.2f", "3.14159" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3.14", buffer.items);
}

test "printf float zero" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "%f", "0" };
    const result = try runPrintf(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.000000", buffer.items);
}
