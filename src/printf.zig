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
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runPrintf);
}

/// Run the printf utility with given arguments.
///
/// printf does not use ArgParser since FORMAT is a positional argument.
/// Only --help and --version are handled as special cases.
pub fn runPrintf(
    allocator: Allocator,
    _: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "printf",
            "missing operand\nTry 'printf --help' for more information.",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
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
    while (true) { // tiger:allow:unbounded-loop terminates: breaks when no arg consumed or all used
        const start_arg_idx = arg_idx;
        const halted = processFormat(
            format,
            arguments,
            &arg_idx,
            stdout_writer,
            stderr_writer,
            allocator,
            &had_error,
        ) catch blk: {
            had_error = true;
            break :blk false;
        };

        // \c halts all output immediately
        if (halted) break;

        // arg_idx is only ever advanced (never decremented) while consuming
        // arguments, so after one pass it cannot fall below where it started.
        // The loop-stop check below relies on this monotonicity.
        std.debug.assert(arg_idx >= start_arg_idx);

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
/// Returns true if a \c halt was encountered.
fn processFormat(
    format: []const u8,
    arguments: []const []const u8,
    arg_idx: *usize,
    writer: anytype,
    stderr_writer: anytype,
    allocator: Allocator,
    had_error: *bool,
) !bool {
    var i: usize = 0;
    while (i < format.len) {
        // Loop invariant: no branch advances i past the end of the format.
        std.debug.assert(i <= format.len);
        if (format[i] == '\\') {
            // Escape sequence in format string
            const result = try processEscape(format, i, writer);
            if (result.halt) return true;
            i = result.new_pos;
        } else if (format[i] == '%') {
            if (i + 1 < format.len and format[i + 1] == '%') {
                // Literal percent
                try writer.writeByte('%');
                i += 2;
            } else {
                // Format specifier
                const result = try processSpecifier(
                    format,
                    i,
                    arguments,
                    arg_idx,
                    writer,
                    stderr_writer,
                    allocator,
                    had_error,
                );
                if (result.halt) return true;
                i = result.pos;
            }
        } else {
            try writer.writeByte(format[i]);
            i += 1;
        }
    }
    return false;
}

/// Result from processing an escape sequence
const EscapeResult = struct {
    new_pos: usize,
    halt: bool = false,
};

/// Process a backslash escape sequence in the format string.
/// Handles \n, \t, \r, \a, \b, \f, \v, \\, \0NNN, \xHH.
fn processEscape(format: []const u8, pos: usize, writer: anytype) !EscapeResult {
    std.debug.assert(pos < format.len);
    std.debug.assert(format[pos] == '\\');

    if (pos + 1 >= format.len) {
        // Trailing backslash, output literally
        try writer.writeByte('\\');
        return .{ .new_pos = pos + 1 };
    }

    switch (format[pos + 1]) {
        'a' => {
            try writer.writeByte('\x07');
            return .{ .new_pos = pos + 2 };
        },
        'b' => {
            try writer.writeByte('\x08');
            return .{ .new_pos = pos + 2 };
        },
        'f' => {
            try writer.writeByte('\x0c');
            return .{ .new_pos = pos + 2 };
        },
        'n' => {
            try writer.writeByte('\n');
            return .{ .new_pos = pos + 2 };
        },
        'r' => {
            try writer.writeByte('\r');
            return .{ .new_pos = pos + 2 };
        },
        't' => {
            try writer.writeByte('\t');
            return .{ .new_pos = pos + 2 };
        },
        'v' => {
            try writer.writeByte('\x0b');
            return .{ .new_pos = pos + 2 };
        },
        '\\' => {
            try writer.writeByte('\\');
            return .{ .new_pos = pos + 2 };
        },
        'c' => {
            // \c halts all output immediately
            return .{ .new_pos = pos + 2, .halt = true };
        },
        '0' => {
            // Octal: \0NNN (up to 3 octal digits after the leading 0)
            const new_pos = try processEscape_octalWithPrefix(format, pos + 2, writer);
            return .{ .new_pos = new_pos };
        },
        '1'...'7' => {
            // Octal: \NNN (up to 3 octal digits, first digit included)
            const new_pos = try processEscape_octalNoPrefix(format, pos + 1, writer);
            return .{ .new_pos = new_pos };
        },
        'x' => {
            // Hex: \xHH (1-2 hex digits)
            return try processEscape_hex(format, pos + 2, writer);
        },
        else => {
            // Unknown escape, output backslash literally
            try writer.writeByte('\\');
            return .{ .new_pos = pos + 1 };
        },
    }
}

/// Scan up to 3 octal digits starting at value_start, accumulate into a byte,
/// write it, and return the position after the consumed digits. Used for the
/// \0NNN form where the leading '0' is a prefix, so digits begin past it.
fn processEscape_octalWithPrefix(
    format: []const u8,
    value_start: usize, // tiger:allow:usize-arch slice index
    writer: anytype,
) !usize { // tiger:allow:usize-arch slice index
    std.debug.assert(value_start <= format.len);

    var value: u8 = 0;
    var j: usize = value_start; // tiger:allow:usize-arch slice index
    var count: usize = 0; // tiger:allow:usize-arch loop counter
    while (count < 3 and j < format.len and format[j] >= '0' and format[j] <= '7') : ({
        j += 1;
        count += 1;
    }) {
        value = value *% 8 +% (format[j] - '0');
    }
    try writer.writeByte(value);

    std.debug.assert(j >= value_start);
    std.debug.assert(j <= value_start + 3);
    return j;
}

/// Scan up to 3 octal digits starting at value_start, accumulate into a byte,
/// write it, and return the position after the consumed digits. Used for the
/// \NNN form where the first digit is part of the value. Kept separate from
/// the prefixed variant so the start offset stays exact.
fn processEscape_octalNoPrefix(
    format: []const u8,
    value_start: usize, // tiger:allow:usize-arch slice index
    writer: anytype,
) !usize { // tiger:allow:usize-arch slice index
    std.debug.assert(value_start <= format.len);

    var value: u8 = 0;
    var j: usize = value_start; // tiger:allow:usize-arch slice index
    var count: usize = 0; // tiger:allow:usize-arch loop counter
    while (count < 3 and j < format.len and format[j] >= '0' and format[j] <= '7') : ({
        j += 1;
        count += 1;
    }) {
        value = value *% 8 +% (format[j] - '0');
    }
    try writer.writeByte(value);

    std.debug.assert(j >= value_start);
    std.debug.assert(j <= value_start + 3);
    return j;
}

/// Scan up to 2 hex digits starting at value_start for the \xHH form. Writes
/// the decoded byte and returns the new position; if no hex digit follows,
/// outputs "\x" literally and returns value_start (just past the 'x').
fn processEscape_hex(
    format: []const u8,
    value_start: usize, // tiger:allow:usize-arch slice index
    writer: anytype,
) !EscapeResult {
    std.debug.assert(value_start <= format.len);

    var value: u8 = 0;
    var j: usize = value_start; // tiger:allow:usize-arch slice index
    var hex_digits: usize = 0; // tiger:allow:usize-arch loop counter
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
    std.debug.assert(hex_digits <= 2);
    // j is only ever incremented from value_start, so it cannot fall below it;
    // pairs the lower bound with the existing upper-bound digit-count check.
    std.debug.assert(j >= value_start);

    if (hex_digits > 0) {
        try writer.writeByte(value);
        return .{ .new_pos = j };
    } else {
        // No hex digits, output \x literally
        try writer.writeByte('\\');
        try writer.writeByte('x');
        return .{ .new_pos = value_start };
    }
}

/// Result from processing a format specifier
const SpecifierResult = struct {
    pos: usize,
    halt: bool = false,
};

/// Parse and process a format specifier starting at '%'.
/// Returns the new position and whether \c halt was encountered.
fn processSpecifier(
    format: []const u8,
    pos: usize,
    arguments: []const []const u8,
    arg_idx: *usize,
    writer: anytype,
    stderr_writer: anytype,
    allocator: Allocator,
    had_error: *bool,
) !SpecifierResult {
    std.debug.assert(pos < format.len);
    std.debug.assert(format[pos] == '%');
    const arg_idx_entry = arg_idx.*;

    var i = pos + 1; // Skip the '%'
    // The specifier consumes at least the '%', and the parse helpers only ever
    // advance i, so forward progress in processFormat's loop is guaranteed.
    std.debug.assert(i > pos);

    // Parse flags, then width and precision, accumulating into one spec.
    // A '*' width can flip left_justify when negative, so parseWidth gets a
    // pointer into the spec's flag.
    var spec = processSpecifier_parseFlags(format, &i);
    spec.width = processSpecifier_parseWidth(format, &i, arguments, arg_idx, &spec.left_justify);
    spec.precision = processSpecifier_parsePrecision(format, &i, arguments, arg_idx);

    // Parse conversion character
    if (i >= format.len) {
        // Incomplete format specifier, output as literal
        try writer.writeByte('%');
        return .{ .pos = pos + 1 };
    }

    const conv = format[i];
    i += 1;

    switch (conv) {
        's' => {
            const arg = getNextArg(arguments, arg_idx);
            try formatString(writer, arg, spec);
        },
        'b' => {
            const arg = getNextArg(arguments, arg_idx);
            const halted = try formatBString(writer, arg);
            if (halted) return .{ .pos = i, .halt = true };
        },
        'c' => {
            const arg = getNextArg(arguments, arg_idx);
            if (arg.len > 0) {
                try writer.writeByte(arg[0]);
            }
        },
        'd', 'i', 'u', 'o', 'x', 'X' => {
            const arg = getNextArg(arguments, arg_idx);
            try processSpecifier_dispatchInt(
                writer,
                conv,
                arg,
                spec,
                allocator,
                stderr_writer,
                had_error,
            );
        },
        'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => {
            const arg = getNextArg(arguments, arg_idx);
            try processSpecifier_dispatchFloat(writer, conv, arg, spec);
        },
        else => {
            // Unknown specifier, output literally
            try writer.writeByte('%');
            try writer.writeByte(conv);
        },
    }

    std.debug.assert(arg_idx.* >= arg_idx_entry);
    std.debug.assert(i <= format.len);
    return .{ .pos = i };
}

/// Parse the leading flag characters (-, +, space, 0, #) of a format
/// specifier, advancing i_ptr past them. Returns a FormatSpec with only the
/// flag fields set; width and precision stay null for the caller to fill.
fn processSpecifier_parseFlags(
    format: []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch slice index
) FormatSpec {
    std.debug.assert(i_ptr.* <= format.len);
    const i_entry = i_ptr.*;

    var spec = FormatSpec{};
    while (i_ptr.* < format.len) {
        switch (format[i_ptr.*]) {
            '-' => spec.left_justify = true,
            '+' => spec.plus_sign = true,
            ' ' => spec.space_sign = true,
            '0' => spec.zero_pad = true,
            '#' => spec.hash_flag = true,
            else => break,
        }
        i_ptr.* += 1;
    }

    std.debug.assert(i_ptr.* >= i_entry);
    std.debug.assert(i_ptr.* <= format.len);
    return spec;
}

/// Parse a width field for a format specifier, advancing i_ptr past it. A '*'
/// reads the width from the next argument; a negative '*' width flips
/// left_justify_ptr (GNU behavior). Otherwise reads decimal digits in place.
/// Returns the parsed width, or null if none is present.
fn processSpecifier_parseWidth(
    format: []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch slice index
    arguments: []const []const u8,
    arg_idx: *usize, // tiger:allow:usize-arch slice index
    left_justify_ptr: *bool,
) ?usize { // tiger:allow:usize-arch slice padding count
    std.debug.assert(i_ptr.* <= format.len);
    const i_entry = i_ptr.*;

    var width: ?usize = null;
    if (i_ptr.* < format.len and format[i_ptr.*] == '*') {
        // Width from argument
        const w_str = getNextArg(arguments, arg_idx);
        const w_val = std.fmt.parseInt(i64, w_str, 10) catch 0;
        if (w_val < 0) {
            // Negative width implies left-justify (GNU behavior)
            left_justify_ptr.* = true;
            width = @as(usize, @intCast(-w_val));
        } else {
            width = @as(usize, @intCast(w_val));
        }
        i_ptr.* += 1;
    } else {
        var w: usize = 0;
        var has_width = false;
        while (i_ptr.* < format.len and format[i_ptr.*] >= '0' and format[i_ptr.*] <= '9') {
            w = w * 10 + (format[i_ptr.*] - '0');
            has_width = true;
            i_ptr.* += 1;
        }
        if (has_width) width = w;
    }

    std.debug.assert(i_ptr.* >= i_entry);
    std.debug.assert(i_ptr.* <= format.len);
    return width;
}

/// Parse a precision field ('.' optionally followed by '*' or digits) for a
/// format specifier, advancing i_ptr past it. A '*' reads precision from the
/// next argument (negative becomes null). Returns the parsed precision, or null
/// if no '.' is present.
fn processSpecifier_parsePrecision(
    format: []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch slice index
    arguments: []const []const u8,
    arg_idx: *usize, // tiger:allow:usize-arch slice index
) ?usize { // tiger:allow:usize-arch slice precision count
    std.debug.assert(i_ptr.* <= format.len);

    var precision: ?usize = null;
    if (i_ptr.* < format.len and format[i_ptr.*] == '.') {
        std.debug.assert(format[i_ptr.*] == '.');
        i_ptr.* += 1;
        if (i_ptr.* < format.len and format[i_ptr.*] == '*') {
            // Precision from argument
            const p_str = getNextArg(arguments, arg_idx);
            const p_val = std.fmt.parseInt(i64, p_str, 10) catch 0;
            precision = if (p_val >= 0) @as(usize, @intCast(p_val)) else null;
            i_ptr.* += 1;
        } else {
            var p: usize = 0;
            while (i_ptr.* < format.len and format[i_ptr.*] >= '0' and format[i_ptr.*] <= '9') {
                p = p * 10 + (format[i_ptr.*] - '0');
                i_ptr.* += 1;
            }
            precision = p;
        }
    }
    return precision;
}

/// Dispatch the integer conversions (d, i, u, o, x, X) for a parsed argument.
/// The d/i path reports a non-numeric warning via had_error. Error sink params
/// go last per Tiger Style.
fn processSpecifier_dispatchInt(
    writer: anytype,
    conv: u8,
    arg: []const u8,
    spec: FormatSpec,
    allocator: Allocator,
    stderr_writer: anytype,
    had_error: *bool,
) !void {
    // Membership in d/i/u/o/x/X is enforced positively by the switch's
    // `else => unreachable`; assert the negative space we must never see here.
    std.debug.assert(conv != 's');
    std.debug.assert(conv != 'b');

    switch (conv) {
        'd', 'i' => {
            const parse_result = parseIntArgEx(arg);
            if (!parse_result.ok and arg.len > 0) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "printf",
                    "'{s}': expected a numeric value",
                    .{arg},
                );
                had_error.* = true;
            }
            try formatSignedInt(writer, parse_result.value, 10, false, spec);
        },
        'u' => try formatUnsignedInt(writer, parseUintArg(arg), 10, false, spec),
        'o' => try formatUnsignedInt(writer, parseUintArg(arg), 8, spec.hash_flag, spec),
        'x' => try formatHex(writer, parseUintArg(arg), false, spec),
        'X' => try formatHex(writer, parseUintArg(arg), true, spec),
        else => unreachable,
    }
}

/// Dispatch the floating-point conversions (f, F, e, E, g, G, a, A) for a
/// parsed argument. Each arm parses the float once and selects the formatter by
/// conversion letter.
fn processSpecifier_dispatchFloat(
    writer: anytype,
    conv: u8,
    arg: []const u8,
    spec: FormatSpec,
) !void {
    // Membership in f/F/e/E/g/G/a/A is enforced positively by the switch's
    // `else => unreachable`; assert the negative space we must never see here.
    std.debug.assert(conv != 'd');
    std.debug.assert(conv != 's');

    const val = parseFloatArg(arg);
    switch (conv) {
        'f', 'F' => try formatFloat(writer, val, 'f', spec),
        'e' => try formatFloat(writer, val, 'e', spec),
        'E' => try formatFloat(writer, val, 'E', spec),
        'g' => try formatFloat(writer, val, 'g', spec),
        'G' => try formatFloat(writer, val, 'G', spec),
        'a' => try formatHexFloat(writer, val, false, spec),
        'A' => try formatHexFloat(writer, val, true, spec),
        else => unreachable,
    }
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

/// Result from parsing an integer argument
const IntParseResult = struct {
    value: i64,
    ok: bool,
};

/// Parse string as signed integer with extended result reporting.
/// Returns the parsed value and whether parsing was fully successful.
/// For partial numeric input like "5abc", returns {.value=5, .ok=false}.
fn parseIntArgEx(s: []const u8) IntParseResult {
    if (s.len == 0) return .{ .value = 0, .ok = true };

    // Leading ' or " means character value
    if ((s[0] == '\'' or s[0] == '"') and s.len >= 2) {
        return .{ .value = @as(i64, s[1]), .ok = true };
    }

    // Try hex (0x or 0X prefix)
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        if (std.fmt.parseInt(i64, s[2..], 16)) |v| {
            return .{ .value = v, .ok = true };
        } else |_| {
            return .{ .value = 0, .ok = false };
        }
    }

    // Try octal (0 prefix, but not just "0")
    if (s.len > 1 and s[0] == '0') {
        if (std.fmt.parseInt(i64, s[1..], 8)) |v| {
            return .{ .value = v, .ok = true };
        } else |_| {
            if (std.fmt.parseInt(i64, s, 10)) |v| {
                return .{ .value = v, .ok = true };
            } else |_| {
                return .{ .value = 0, .ok = false };
            }
        }
    }

    // Try full decimal parse first
    if (std.fmt.parseInt(i64, s, 10)) |v| {
        return .{ .value = v, .ok = true };
    } else |_| {}

    // Try float parse and truncate to integer (GNU behavior).
    // GNU printf '%d' 3.9 outputs 3 (truncate), '%d' 1e2 outputs 100.
    if (std.fmt.parseFloat(f64, s)) |fval| {
        const truncated = @as(i64, @intFromFloat(@trunc(fval)));
        return .{ .value = truncated, .ok = false };
    } else |_| {}

    // Try partial parse: find longest leading numeric prefix
    var end: usize = 0;
    if (end < s.len and (s[end] == '-' or s[end] == '+')) end += 1;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
    // end is only advanced while end < s.len, so the slice s[0..end] below is
    // always in bounds (holds for empty s, where end stays 0).
    std.debug.assert(end <= s.len);
    if (end > 0 and !(end == 1 and (s[0] == '-' or s[0] == '+'))) {
        if (std.fmt.parseInt(i64, s[0..end], 10)) |v| {
            return .{ .value = v, .ok = false };
        } else |_| {}
    }

    return .{ .value = 0, .ok = false };
}

/// Parse string as signed integer. Handles 0x, 0, and leading quote/dquote
/// for character values. Returns 0 for unparseable strings.
fn parseIntArg(s: []const u8) i64 {
    return parseIntArgEx(s).value;
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
    // truncated is either s or a @min-bounded prefix of it, never longer.
    std.debug.assert(truncated.len <= s.len);

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

/// Format a %b string (with backslash escape interpretation like echo -e).
/// Returns true if \c was encountered (halt all output).
fn formatBString(writer: anytype, s: []const u8) !bool {
    var i: usize = 0;
    while (i < s.len) {
        std.debug.assert(i < s.len);
        if (s[i] == '\\' and i + 1 < s.len) {
            std.debug.assert(s[i] == '\\');
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
                    // \c suppresses further output -- halt everything
                    return true;
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
                '0' => {
                    // \0NNN: '0' is a prefix, read up to 3 octal digits after it
                    i = try formatBString_octalWithPrefix(s, i + 2, writer);
                },
                '1'...'7' => {
                    // \NNN: first digit is part of the value, up to 3 digits total
                    i = try formatBString_octalNoPrefix(s, i + 1, writer);
                },
                'x' => {
                    i = try formatBString_hex(s, i, writer);
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
    return false;
}

/// Scan up to 3 octal digits starting at value_start in a %b string, write the
/// decoded byte, and return the new index. Used for the \0NNN form where the
/// leading '0' is a prefix, so digits begin past it.
fn formatBString_octalWithPrefix(
    s: []const u8,
    value_start: usize, // tiger:allow:usize-arch slice index
    writer: anytype,
) !usize { // tiger:allow:usize-arch slice index
    std.debug.assert(value_start <= s.len);

    var value: u8 = 0;
    var j: usize = value_start; // tiger:allow:usize-arch slice index
    var count: usize = 0; // tiger:allow:usize-arch loop counter
    while (count < 3 and j < s.len and s[j] >= '0' and s[j] <= '7') : ({
        j += 1;
        count += 1;
    }) {
        value = value *% 8 +% (s[j] - '0');
    }
    try writer.writeByte(value);

    std.debug.assert(j >= value_start);
    std.debug.assert(j <= value_start + 3);
    return j;
}

/// Scan up to 3 octal digits starting at value_start in a %b string, write the
/// decoded byte, and return the new index. Used for the \NNN form where the
/// first digit is part of the value. Kept separate from the prefixed variant so
/// the start offset stays exact.
fn formatBString_octalNoPrefix(
    s: []const u8,
    value_start: usize, // tiger:allow:usize-arch slice index
    writer: anytype,
) !usize { // tiger:allow:usize-arch slice index
    std.debug.assert(value_start <= s.len);

    var value: u8 = 0;
    var j: usize = value_start; // tiger:allow:usize-arch slice index
    var count: usize = 0; // tiger:allow:usize-arch loop counter
    while (count < 3 and j < s.len and s[j] >= '0' and s[j] <= '7') : ({
        j += 1;
        count += 1;
    }) {
        value = value *% 8 +% (s[j] - '0');
    }
    try writer.writeByte(value);

    std.debug.assert(j >= value_start);
    std.debug.assert(j <= value_start + 3);
    return j;
}

/// Scan up to 2 hex digits for the \xHH form in a %b string. escape_start is
/// the index of the backslash; digits are read at escape_start+2 onward via the
/// original `j`-from-2 offset to preserve identical indexing. Returns the new
/// absolute index: escape_start+j on success, escape_start+2 when no hex digit
/// follows (in which case "\x" is emitted literally).
fn formatBString_hex(
    s: []const u8,
    escape_start: usize, // tiger:allow:usize-arch slice index
    writer: anytype,
) !usize { // tiger:allow:usize-arch slice index
    std.debug.assert(escape_start + 1 < s.len);

    var value: u8 = 0;
    var j: usize = 2; // tiger:allow:usize-arch slice index
    var hex_digits: usize = 0; // tiger:allow:usize-arch loop counter
    while (hex_digits < 2 and escape_start + j < s.len) : ({
        j += 1;
        hex_digits += 1;
    }) {
        const c = s[escape_start + j];
        const digit: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        value = value * 16 + digit;
    }
    std.debug.assert(hex_digits <= 2);

    if (hex_digits > 0) {
        try writer.writeByte(value);
        return escape_start + j;
    } else {
        try writer.writeByte('\\');
        try writer.writeByte('x');
        return escape_start + 2;
    }
}

/// Format a signed integer with the given radix and spec
fn formatSignedInt(
    writer: anytype,
    val: i64,
    radix: u8,
    _: bool,
    spec: FormatSpec,
) !void {
    // formatUnsignedBuf divides by radix and maps digits 10..radix-1 to a-f, so
    // the radix must be in [2, 16] for terminating, well-encoded output.
    std.debug.assert(radix >= 2);
    std.debug.assert(radix <= 16);

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
    // formatUnsignedBuf divides by radix and maps digits 10..radix-1 to a-f, so
    // the radix must be in [2, 16] for terminating, well-encoded output.
    std.debug.assert(radix >= 2);
    std.debug.assert(radix <= 16);

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
    // The loop computes v % radix and v /= radix; radix < 2 would be div-by-zero
    // or a non-terminating loop. The val==0 branch writes buf[0], so at least one
    // byte of space is required.
    std.debug.assert(radix >= 2);
    std.debug.assert(buf.len >= 1);

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

    // formatted_start is 1 only when formatted[0] == '-' (so len >= 1), else 0;
    // the content slice below is therefore always in bounds.
    std.debug.assert(formatted_start <= formatted.len);
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

/// Format a hex float (%a/%A) using Zig's std.fmt.
fn formatHexFloat(writer: anytype, val: f64, uppercase: bool, spec: FormatSpec) !void {
    var buf: [256]u8 = undefined;

    // Use Zig's builtin hex float formatter
    const formatted = std.fmt.bufPrint(&buf, "{x}", .{val}) catch "0x0p+0";
    // formatted is either a slice into buf or the short literal "0x0p+0", so it
    // fits in buf; this guards the uppercase loop indexing upper_buf by its len.
    std.debug.assert(formatted.len <= buf.len);

    if (uppercase) {
        // Convert to uppercase: 0x -> 0X, a-f -> A-F, p -> P
        var upper_buf: [256]u8 = undefined;
        for (formatted, 0..) |c, idx| {
            upper_buf[idx] = switch (c) {
                'a'...'f' => c - 'a' + 'A',
                'x' => 'X',
                'p' => 'P',
                else => c,
            };
        }
        const upper = upper_buf[0..formatted.len];
        try applyFloatPadding(writer, upper, spec);
    } else {
        try applyFloatPadding(writer, formatted, spec);
    }
}

/// Apply width/padding to a pre-formatted float string.
fn applyFloatPadding(writer: anytype, formatted: []const u8, spec: FormatSpec) !void {
    const w = spec.width orelse 0;
    if (formatted.len >= w) {
        try writer.writeAll(formatted);
    } else {
        const padding = w - formatted.len;
        if (spec.left_justify) {
            try writer.writeAll(formatted);
            try writePadding(writer, ' ', padding);
        } else if (spec.zero_pad) {
            // Insert zeros after sign/prefix
            const has_hex_prefix =
                formatted.len > 1 and (formatted[1] == 'x' or formatted[1] == 'X');
            const has_sign = formatted.len > 0 and formatted[0] == '-';
            const prefix_end: usize = // tiger:allow:usize-arch slice index
                if (has_hex_prefix) 2 else if (has_sign) 1 else 0;
            // Each prefix_end value is guarded by the matching length check, so
            // both slices of formatted below stay in bounds.
            std.debug.assert(prefix_end <= formatted.len);
            try writer.writeAll(formatted[0..prefix_end]);
            try writePadding(writer, '0', padding);
            try writer.writeAll(formatted[prefix_end..]);
        } else {
            try writePadding(writer, ' ', padding);
            try writer.writeAll(formatted);
        }
    }
}

/// Format a floating-point number in fixed notation (%f).
/// Delegates to std.fmt.float.render (Ryu algorithm) for correct rounding.
fn formatFixedFloat(buf: []u8, val: f64, precision: usize) ![]const u8 {
    return std.fmt.float.render(buf, val, .{ .mode = .decimal, .precision = precision });
}

/// Format Inf/NaN per GNU printf semantics: "inf", "-inf", "nan",
/// uppercased for %E / %G. The normalization loops in formatSciFloat
/// and formatGeneralFloat don't terminate for non-finite input, so
/// every float-formatting entry point handles those cases up front.
fn formatNonFiniteFloat(buf: []u8, val: f64, uppercase: bool) ![]const u8 {
    const s: []const u8 = if (std.math.isNan(val))
        (if (uppercase) "NAN" else "nan")
    else if (val < 0)
        (if (uppercase) "-INF" else "-inf")
    else if (uppercase) "INF" else "inf";
    if (buf.len < s.len) return error.NoSpaceLeft;
    // The early return above rules out buf.len < s.len, so the @memcpy fits.
    std.debug.assert(s.len <= buf.len);
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Format a floating-point number in scientific notation (%e/%E).
fn formatSciFloat(buf: []u8, val: f64, precision: usize, uppercase: bool) ![]const u8 {
    if (!std.math.isFinite(val)) return formatNonFiniteFloat(buf, val, uppercase);
    // Past the early return val is finite, which the normalization loops below
    // (while abs_val >= 10.0 / < 1.0) require to terminate.
    std.debug.assert(std.math.isFinite(val));
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
    if (!std.math.isFinite(val)) return formatNonFiniteFloat(buf, val, uppercase);
    // Past the early return val is finite, which the normalization loops below
    // (while tmp >= 10.0 / < 1.0) require to terminate.
    std.debug.assert(std.math.isFinite(val));
    const prec = if (precision == 0) 1 else precision;
    // %g always keeps at least one significant digit, so prec is never 0; the
    // @intCast(prec) comparison and decimal_places math rely on this.
    std.debug.assert(prec >= 1);

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
    // dot_pos was set from an index over s, so it is a valid in-bounds position.
    std.debug.assert(dot_pos.? < s.len);

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
    // e_pos was set from an index over s, so the s[0..e_pos.?] / s[e_pos.?..]
    // slices below are in bounds.
    std.debug.assert(e_pos.? < s.len);

    // Find the dot
    var dot_pos: ?usize = null;
    for (s[0..e_pos.?], 0..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }
    if (dot_pos == null) return s;
    // dot_pos was found only within the prefix before e_pos, so it is strictly
    // less than e_pos; the strip loop seeded at e_pos relies on this ordering.
    std.debug.assert(dot_pos.? < e_pos.?);

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
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%s", "hello" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello", buffer_aw.writer.buffered());
}

test "printf string with newline escape" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%s\\n", "hello" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", buffer_aw.writer.buffered());
}

test "printf integer formatting" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%d", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("42", buffer_aw.writer.buffered());
}

test "printf negative integer" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%d", "-7" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-7", buffer_aw.writer.buffered());
}

test "printf octal" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%o", "255" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("377", buffer_aw.writer.buffered());
}

test "printf hex lowercase" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%x", "255" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("ff", buffer_aw.writer.buffered());
}

test "printf hex uppercase" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%X", "255" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("FF", buffer_aw.writer.buffered());
}

test "printf unsigned integer" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%u", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("42", buffer_aw.writer.buffered());
}

test "printf character" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%c", "A" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer_aw.writer.buffered());
}

test "printf float" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%f", "3.14" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3.140000", buffer_aw.writer.buffered());
}

test "printf literal percent" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"100%%"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("100%", buffer_aw.writer.buffered());
}

test "printf width right-aligned" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%10s", "hello" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("     hello", buffer_aw.writer.buffered());
}

test "printf width left-aligned" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%-10s", "hello" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello     ", buffer_aw.writer.buffered());
}

test "printf precision truncates string" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.3s", "hello" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hel", buffer_aw.writer.buffered());
}

test "printf zero-padded integer" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%05d", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("00042", buffer_aw.writer.buffered());
}

test "printf format string reuse" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%s\\n", "a", "b", "c" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\nb\nc\n", buffer_aw.writer.buffered());
}

test "printf missing argument defaults to empty string" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"%s"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer_aw.writer.buffered());
}

test "printf missing argument defaults to zero for integers" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"%d"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0", buffer_aw.writer.buffered());
}

test "printf escape sequences in format" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"\\t\\n\\r\\a"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\n\r\x07", buffer_aw.writer.buffered());
}

test "printf octal escape in format" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"\\0101"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer_aw.writer.buffered());
}

test "printf hex escape in format" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"\\x41"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer_aw.writer.buffered());
}

test "printf backslash escape" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"\\\\"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\\", buffer_aw.writer.buffered());
}

test "printf %b with escape sequences" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%b", "hello\\nworld" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer_aw.writer.buffered());
}

// The exact stderr GNU coreutils emits with no operands, hint line
// included. Verified with `LC_ALL=C /usr/bin/printf` on Ubuntu:
//   printf: missing operand
//   Try 'printf --help' for more information.
// exit 1, empty stdout. GNU echoes argv[0] verbatim; we print the plain
// utility name, matching uniq and whoami.
test "printf no arguments shows usage error" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", buffer_aw.writer.buffered());
    try testing.expectEqualStrings(
        "printf: missing operand\nTry 'printf --help' for more information.\n",
        stderr_aw.writer.buffered(),
    );
}

test "printf --help" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "Usage: printf") != null);
}

test "printf --version" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "printf") != null);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), common.version) != null);
}

test "printf multiple format specifiers" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "Name: %s Age: %d\\n", "Alice", "30" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("Name: Alice Age: 30\n", buffer_aw.writer.buffered());
}

test "printf character from quote syntax" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%d", "'A" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("65", buffer_aw.writer.buffered());
}

test "printf hex argument prefix" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%d", "0xff" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("255", buffer_aw.writer.buffered());
}

test "printf octal argument prefix" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%d", "010" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("8", buffer_aw.writer.buffered());
}

test "printf scientific notation" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%e", "100000" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.000000e+05", buffer_aw.writer.buffered());
}

test "printf plus sign flag" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%+d", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("+42", buffer_aw.writer.buffered());
}

test "printf hash flag for octal" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%#o", "8" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("010", buffer_aw.writer.buffered());
}

test "printf hash flag for hex" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%#x", "255" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0xff", buffer_aw.writer.buffered());
}

test "printf width with integer" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%8d", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("      42", buffer_aw.writer.buffered());
}

test "printf empty format" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{""};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer_aw.writer.buffered());
}

test "printf plain text no specifiers" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"hello world"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world", buffer_aw.writer.buffered());
}

test "printf %g removes trailing zeros" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%g", "3.0" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3", buffer_aw.writer.buffered());
}

test "printf %c with empty argument" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%c", "" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer_aw.writer.buffered());
}

test "printf %c with missing argument" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"%c"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", buffer_aw.writer.buffered());
}

test "printf float with precision" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.2f", "3.14159" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3.14", buffer_aw.writer.buffered());
}

test "printf float zero" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%f", "0" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.000000", buffer_aw.writer.buffered());
}

test "processEscape should propagate write errors not swallow them" {
    // A writer that always fails, simulating a broken pipe or disk-full
    // condition.  processEscape currently swallows all write errors via
    // `catch {}`, so this test documents the bug: printf reports success
    // (exit 0) even though output was lost.
    var fw = std.Io.Writer.failing;

    // Format string "\\n" is a single escape sequence with no literal
    // characters, so all output goes through processEscape.  If write
    // errors propagated, runPrintf would return a non-zero exit code.
    const args = [_][]const u8{"\\n"};
    const result = try runPrintf(testing.allocator, testing.io, &args, &fw, common.null_writer);

    // The write failed, so printf should report an error.
    // BUG: processEscape swallows the error, so result is 0.
    try testing.expect(result != 0);
}

test "printf float carry propagation past decimal: 9.995 -> 10.00" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.2f", "9.995" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("10.00", buffer_aw.writer.buffered());
}

test "printf float carry propagation past decimal: 9.95 -> 10.0" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.1f", "9.95" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("10.0", buffer_aw.writer.buffered());
}

test "printf float carry propagation zero precision: 9.5 -> 10" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.0f", "9.5" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("10", buffer_aw.writer.buffered());
}

test "printf float carry propagation multi-digit integer: 99.999 -> 100.00" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.2f", "99.999" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("100.00", buffer_aw.writer.buffered());
}

test "printf float simple rounding no carry overflow: 1.005 -> 1.01" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%.2f", "1.005" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.01", buffer_aw.writer.buffered());
}

// ========== AUDIT FINDING TESTS ==========

// F31: \NNN octal escape without leading zero in format string
// GNU printf treats \101 as octal 101 = 65 = 'A'.
// Our processEscape only matches '0' after backslash, so \1xx falls
// through to the else branch and outputs a literal backslash.
test "F31: format string \\NNN octal without leading zero" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // \101 = octal 101 = 65 = 'A'
    const args = [_][]const u8{"\\101"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer_aw.writer.buffered());
}

test "F31: format string \\NNN octal 1-digit" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // \7 = octal 7 = 0x07
    const args = [_][]const u8{"\\7"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\x07", buffer_aw.writer.buffered());
}

test "F31: format string \\NNN octal 2-digit" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // \62 = octal 62 = 50 = '2'
    const args = [_][]const u8{"\\62"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("2", buffer_aw.writer.buffered());
}

test "F31: format string \\NNN octal 3-digit" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // \110 = octal 110 = 72 = 'H'
    const args = [_][]const u8{"\\110"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("H", buffer_aw.writer.buffered());
}

// F32: %b octal \0NNN off-by-one -- first digit re-read after consuming '0'
// GNU printf '%b' '\0101' outputs 'A' (octal 101 = 65).
// Our formatBString re-reads the initial digit in the while loop because
// j starts at 1 (the position of the matched digit), causing an off-by-one.
test "F32: percent-b octal \\0NNN produces correct byte" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // %b with \0101: the '0' is a prefix, '101' is octal = 65 = 'A'
    const args = [_][]const u8{ "%b", "\\0101" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A", buffer_aw.writer.buffered());
}

test "F32: percent-b octal \\0NNN 3-digit non-zero start" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // %b \0110: the '0' is a prefix, '110' is octal = 72 = 'H'
    // Bug: code re-reads the '0' prefix, processes '011' = 9 instead
    const args = [_][]const u8{ "%b", "\\0110" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("H", buffer_aw.writer.buffered());
}

test "F32: percent-b octal \\0NNN followed by text" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // %b \0101X: octal 101 = 65 = 'A', then literal 'X'
    // Bug: code reads '010' = 8, then outputs char(8) + '1' + 'X'
    const args = [_][]const u8{ "%b", "\\0101X" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("AX", buffer_aw.writer.buffered());
}

// F33: \c in format string not handled
// GNU printf 'before\cafter' outputs "before" and stops immediately.
// Our processEscape does not handle 'c' -- it falls through to else
// and outputs a literal backslash, continuing with the rest.
test "F33: format string \\c stops output" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"before\\cafter"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    _ = result;
    // Should output only "before", nothing after \c
    try testing.expectEqualStrings("before", buffer_aw.writer.buffered());
}

test "F33: format string \\c at start produces no output" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"\\chello"};
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    _ = result;
    try testing.expectEqualStrings("", buffer_aw.writer.buffered());
}

// F34: %b \c does not halt format-string reuse
// GNU printf '%b\n' 'hello\c' 'world' outputs "hello" only.
// Our formatBString returns early on \c, but runPrintf continues
// reusing the format string for the remaining "world" argument.
test "F34: percent-b \\c halts format-string reuse" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%b\\n", "hello\\c", "world" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    _ = result;
    // Should output only "hello" -- \c stops everything, no newline, no "world"
    try testing.expectEqualStrings("hello", buffer_aw.writer.buffered());
}

test "F34: percent-b \\c halts even within single format pass" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%b %b", "hi\\c", "bye" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    _ = result;
    // \c in first %b should halt all output; "bye" never printed
    try testing.expectEqualStrings("hi", buffer_aw.writer.buffered());
}

// F35: %F, %a, %A format specifiers not implemented
// GNU printf '%F\n' 3.14 outputs "3.140000" (uppercase version of %f).
// GNU printf '%a\n' 1.5 outputs hex float like "0xcp-3".
// Our processSpecifier falls through to else for these, outputting literals.
test "F35: percent-F uppercase float" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%F", "3.14" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3.140000", buffer_aw.writer.buffered());
}

test "F35: percent-F with zero" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%F", "0" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.000000", buffer_aw.writer.buffered());
}

test "F35: percent-a hex float" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%a", "1.5" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    // GNU outputs "0xcp-3" for 1.5 -- hex float representation
    // Must start with "0x" and contain "p" (hex float format)
    try testing.expect(buffer_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.startsWith(u8, buffer_aw.writer.buffered(), "0x"));
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "p") != null);
}

test "F35: percent-A hex float uppercase" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%A", "1.5" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    // GNU outputs "0XCP-3" for 1.5
    try testing.expect(buffer_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.startsWith(u8, buffer_aw.writer.buffered(), "0X"));
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "P") != null);
}

// ========== AUDIT WAVE 4: printf IMPORTANT findings ==========

// IMPORTANT: %d with non-numeric input should warn on stderr and exit 1
// GNU printf '%d\n' abc outputs "0\n" to stdout, warns on stderr, exits 1.
// Our implementation silently returns "0\n" and exits 0.
test "audit: printf %d with non-numeric input exits 1 and warns" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "%d\\n", "abc" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    // GNU outputs "0\n" to stdout
    try testing.expectEqualStrings("0\n", stdout_aw.writer.buffered());
    // Must exit 1 (not 0) when argument is not a valid number
    try testing.expectEqual(@as(u8, 1), result);
    // Must emit a warning on stderr
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

// IMPORTANT: %d with partial numeric input (e.g. "5abc") should also warn
test "audit: printf %d with partial numeric input warns" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "%d", "5abc" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    // GNU outputs "5" for partial numeric
    try testing.expectEqualStrings("5", stdout_aw.writer.buffered());
    // Must exit 1 and warn
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

// Test gap: %i format specifier (synonym for %d)
// GNU printf '%i\n' 42 outputs "42\n"
test "audit: printf %i format specifier" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%i", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("42", buffer_aw.writer.buffered());
}

// Test gap: %i with negative number
test "audit: printf %i negative" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%i", "-7" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-7", buffer_aw.writer.buffered());
}

// Test gap: %E format specifier (uppercase scientific notation)
// GNU printf '%E\n' 1234.5 outputs "1.234500E+03\n"
test "audit: printf %E uppercase scientific" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%E", "1234.5" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.234500E+03", buffer_aw.writer.buffered());
}

// Test gap: %G format specifier (uppercase general float)
// GNU printf '%G\n' 0.00001 outputs "1E-05\n"
test "audit: printf %G uppercase general" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%G", "0.00001" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    // Must contain uppercase E, not lowercase e
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "E") != null);
}

// Test gap: * dynamic width
// GNU printf '%*d\n' 10 42 outputs "        42\n"
test "audit: printf dynamic width with *" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%*d", "10", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("        42", buffer_aw.writer.buffered());
}

// IMPORTANT: Negative * width implies left-justify
// GNU printf '"%*d"\n' -5 42 outputs '"42   "'
test "audit: printf negative dynamic width implies left-justify" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%*d", "-5", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("42   ", buffer_aw.writer.buffered());
}

// Test gap: space-sign flag
// GNU printf '% d\n' 42 outputs " 42\n" (space before positive number)
test "audit: printf space-sign flag positive" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "% d", "42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(" 42", buffer_aw.writer.buffered());
}

// GNU printf '% d\n' -42 outputs "-42\n" (negative sign replaces space)
test "audit: printf space-sign flag negative" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "% d", "-42" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-42", buffer_aw.writer.buffered());
}

// %u is already tested in "printf unsigned integer" above -- no gap.

// Regression: formatSciFloat and formatGeneralFloat normalize via
// `while (abs_val >= 10.0) abs_val /= 10.0;`. For Inf, the condition is
// always true and the loop never terminates. Verified by running with
// `--test-timeout=10s` against printf.zig prior to the isFinite guard:
// the test runner hangs. GNU printf outputs "inf" / "-inf" / "nan"
// (uppercase for %E and %G).

test "printf %e with positive infinity outputs inf" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%e", "inf" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("inf", buffer_aw.writer.buffered());
}

test "printf %e with negative infinity outputs -inf" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%e", "-inf" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-inf", buffer_aw.writer.buffered());
}

test "printf %e with NaN outputs nan" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%e", "nan" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("nan", buffer_aw.writer.buffered());
}

test "printf %E with positive infinity outputs INF (uppercase)" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%E", "inf" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("INF", buffer_aw.writer.buffered());
}

test "printf %g with positive infinity outputs inf" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%g", "inf" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("inf", buffer_aw.writer.buffered());
}

test "printf %g with NaN outputs nan" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%g", "nan" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("nan", buffer_aw.writer.buffered());
}

test "printf %G with NaN outputs NAN (uppercase)" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{ "%G", "nan" };
    const result = try runPrintf(
        testing.allocator,
        testing.io,
        &args,
        &buffer_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("NAN", buffer_aw.writer.buffered());
}
