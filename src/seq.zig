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

/// GNU seq's error for an operand that is not a valid finite float.
const invalid_float_msg = "invalid floating point argument: '{s}'";

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
            // Digits counted strictly after the dot cannot exceed the string.
            std.debug.assert(count <= s.len);
            return count;
        }
    }
    return 0;
}

/// Format a float value as an integer string (no decimal point)
fn formatInteger(buf: []u8, value: f64) ![]const u8 {
    // @intFromFloat is illegal on NaN/Inf; callers pass finite sequence values.
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));
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
    // @intFromFloat(abs_val) below is illegal on NaN/Inf; callers pass finite.
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));
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
    // offset is a prior bufPrint result length into the same buf, so it fits.
    std.debug.assert(offset <= buf.len);
    // Reached only past the precision == 0 early exit, so the loop runs once.
    std.debug.assert(precision >= 1);
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
    // formatted is a prior bufPrint result into the same buf, so it fits.
    std.debug.assert(formatted.len <= buf.len);
    // Reached only from the carry branch past precision == 0, so precision > 0.
    std.debug.assert(precision >= 1);
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

/// Write a single byte to buf[pos], returning error.NoSpaceLeft if buf is full.
fn writeByteBounded(buf: []u8, pos: *usize, b: u8) !void {
    // Write cursor never overruns: every advance is gated on the write fitting.
    std.debug.assert(pos.* <= buf.len);
    if (pos.* >= buf.len) return error.NoSpaceLeft;
    buf[pos.*] = b;
    pos.* += 1;
}

/// Write src into buf starting at pos, returning error.NoSpaceLeft if it won't fit.
fn writeSliceBounded(buf: []u8, pos: *usize, src: []const u8) !void {
    // Same write-cursor invariant on a second path: pos stays within bounds.
    std.debug.assert(pos.* <= buf.len);
    if (pos.* + src.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos.* .. pos.* + src.len], src);
    pos.* += src.len;
}

/// Result of parsing one %spec: the formatted number plus padding metadata
/// and the index just past the conversion character.
const SpecResult = struct {
    formatted: []const u8,
    width: usize, // tiger:allow:usize-arch printf field width feeds slice/std.fmt math
    zero_pad: bool,
    left_justify: bool,
    next: usize, // tiger:allow:usize-arch index into fmt_str (slice indexing)
};

/// Parse a single %spec at fmt_str[spec_at] (flags, width, precision,
/// conversion char) and format `value` into the caller-owned `num_buf`.
/// Returns null when no conversion character follows (control flow preserved
/// from the original `if (j < fmt_str.len)` guard). The returned slice points
/// into `num_buf`, which must outlive the result.
fn formatWithSpec_parseSpec(
    num_buf: []u8,
    value: f64,
    fmt_str: []const u8,
    spec_at: usize, // tiger:allow:usize-arch index into fmt_str (slice indexing)
) !?SpecResult {
    std.debug.assert(spec_at < fmt_str.len);
    std.debug.assert(fmt_str[spec_at] == '%');

    var j = spec_at + 1;

    // Parse flags
    var zero_pad = false;
    var left_justify = false;
    while (j < fmt_str.len and (fmt_str[j] == '-' or fmt_str[j] == '+' or
        fmt_str[j] == ' ' or fmt_str[j] == '0' or fmt_str[j] == '#')) : (j += 1)
    {
        if (fmt_str[j] == '0') zero_pad = true;
        if (fmt_str[j] == '-') left_justify = true;
    }

    // Parse width
    var width: usize = 0; // tiger:allow:usize-arch field width feeds slice/std.fmt math
    while (j < fmt_str.len and fmt_str[j] >= '0' and fmt_str[j] <= '9') : (j += 1) {
        width = width * 10 + (fmt_str[j] - '0');
    }

    // Parse precision
    var precision: usize = 6; // default %f; tiger:allow:usize-arch feeds std.fmt
    var has_precision = false;
    if (j < fmt_str.len and fmt_str[j] == '.') {
        j += 1;
        precision = 0;
        has_precision = true;
        while (j < fmt_str.len and fmt_str[j] >= '0' and fmt_str[j] <= '9') : (j += 1) {
            precision = precision * 10 + (fmt_str[j] - '0');
        }
    }

    // j only advances from spec_at + 1, so we are past the '%'.
    std.debug.assert(j > spec_at);

    // Conversion character
    if (j >= fmt_str.len) return null;

    const formatted = switch (fmt_str[j]) {
        'f' => try formatDecimal(num_buf, value, precision),
        'e', 'E' => try formatScientific(num_buf, value),
        'g', 'G' => blk: {
            if (has_precision) {
                // %g with precision: use fixed-point with trailing zero removal
                break :blk try formatDecimal(num_buf, value, precision);
            }
            break :blk try formatGeneral(num_buf, value);
        },
        else => try formatGeneral(num_buf, value),
    };

    return .{
        .formatted = formatted,
        .width = width,
        .zero_pad = zero_pad,
        .left_justify = left_justify,
        .next = j + 1,
    };
}

/// Write `formatted` into `buf` at `pos`, applying width/justification/zero
/// padding. Advances `pos` and propagates error.NoSpaceLeft.
fn formatWithSpec_writePadded(
    buf: []u8,
    pos: *usize, // tiger:allow:usize-arch write cursor (slice index into buf)
    formatted: []const u8,
    width: usize, // tiger:allow:usize-arch printf field width feeds slice/std.fmt math
    zero_pad: bool,
    left_justify: bool,
) !void {
    std.debug.assert(pos.* <= buf.len);
    std.debug.assert(formatted.len <= buf.len);

    if (width > 0 and formatted.len < width) {
        const padding = width - formatted.len;
        if (left_justify) {
            try writeSliceBounded(buf, pos, formatted);
            for (0..padding) |_| {
                try writeByteBounded(buf, pos, ' ');
            }
        } else if (zero_pad) {
            // Zero-pad: put sign first, then zeros, then digits
            var fmt_start: usize = 0; // tiger:allow:usize-arch slice index into formatted
            if (formatted.len > 0 and (formatted[0] == '-' or formatted[0] == '+')) {
                try writeByteBounded(buf, pos, formatted[0]);
                fmt_start = 1;
            }
            for (0..padding) |_| {
                try writeByteBounded(buf, pos, '0');
            }
            try writeSliceBounded(buf, pos, formatted[fmt_start..]);
        } else {
            for (0..padding) |_| {
                try writeByteBounded(buf, pos, ' ');
            }
            try writeSliceBounded(buf, pos, formatted);
        }
    } else {
        try writeSliceBounded(buf, pos, formatted);
    }
}

/// Format number according to -f format specifier.
/// Supports prefix/suffix text around the %specifier and width/precision.
fn formatWithSpec(buf: []u8, value: f64, fmt_str: []const u8) ![]const u8 {
    var pos: usize = 0;

    // Find the format specifier
    var i: usize = 0;
    while (i < fmt_str.len) : (i += 1) {
        // Loop invariant: the bounded writers keep pos within buf each pass.
        std.debug.assert(pos <= buf.len);
        if (fmt_str[i] == '%') {
            if (i + 1 < fmt_str.len and fmt_str[i + 1] == '%') {
                // Literal %%
                try writeByteBounded(buf, &pos, '%');
                i += 1;
                continue;
            }

            var num_buf: [64]u8 = undefined;
            const result = (try formatWithSpec_parseSpec(&num_buf, value, fmt_str, i)) orelse
                continue;

            try formatWithSpec_writePadded(
                buf,
                &pos,
                result.formatted,
                result.width,
                result.zero_pad,
                result.left_justify,
            );

            // Copy suffix (everything after the conversion character)
            const suffix = fmt_str[result.next..];
            try writeSliceBounded(buf, &pos, suffix);

            return buf[0..pos];
        } else {
            // Prefix text before the format specifier
            try writeByteBounded(buf, &pos, fmt_str[i]);
        }
    }

    // No format spec found, use default
    const formatted = try formatGeneral(buf[pos..], value);
    // Move formatted data to fill after pos
    // Since formatGeneral writes to buf[pos..], the data is already in place
    return buf[0 .. pos + formatted.len];
}

/// Format in scientific notation (like %e)
fn formatScientific(buf: []u8, value: f64) ![]const u8 {
    // Downstream formatDecimal -> @intFromFloat is illegal on NaN/Inf.
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));
    if (value == 0.0) {
        return std.fmt.bufPrint(buf, "0.000000e+00", .{});
    }
    const negative = value < 0;
    const abs_val = @abs(value);
    var exp: i32 = 0;
    var mantissa = abs_val;

    if (mantissa >= 10.0) {
        // f64 max exponent is 308; 400 iterations is a safe upper bound.
        var iter: usize = 0;
        while (mantissa >= 10.0) : (iter += 1) {
            std.debug.assert(iter < 400);
            mantissa /= 10.0;
            exp += 1;
        }
    } else if (mantissa < 1.0 and mantissa > 0.0) {
        // f64 min exponent is -308; 400 iterations is a safe upper bound.
        var iter: usize = 0;
        while (mantissa < 1.0) : (iter += 1) {
            std.debug.assert(iter < 400);
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
    // formatDecimal -> @intFromFloat below is illegal on NaN/Inf.
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));
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
    // Callers pass first/last operands already proven finite by parse.
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));
    var buf: [64]u8 = undefined;
    const formatted = if (use_decimal)
        formatDecimal(&buf, value, precision) catch return 1
    else
        formatInteger(&buf, value) catch return 1;
    return formatted.len;
}

/// Check if a string looks like a negative number (e.g., "-1", "-3.5", "-.5")
fn looksLikeNegativeNumber(s: []const u8) bool {
    if (s.len < 2 or s[0] != '-') return false;
    // Must start with digit or decimal point after the minus sign
    return (s[1] >= '0' and s[1] <= '9') or s[1] == '.';
}

/// Classification of a single argument for negative-number preprocessing.
const Class = enum { bool_flag, value_flag, negative_number, other };

/// Categorize one arg as a known boolean flag, a value-taking flag, a
/// negative number, or anything else. Only categorizes; value-flag index
/// advancement stays in the callers.
fn preprocessArgs_classify(arg: []const u8) Class {
    // Empty and single-char args carry no flag/negative-number meaning; the
    // original gated all such logic behind `arg.len > 1`, so they fall through
    // inertly to argparse. Treat them as .other (never assert against them).
    if (arg.len < 2) return .other;

    const class: Class = blk: {
        if (arg.len == 2 and arg[0] == '-' and arg[1] != '-') {
            switch (arg[1]) {
                'h', 'V', 'w' => break :blk .bool_flag, // Known boolean flags
                's', 'f' => break :blk .value_flag, // Known value-taking flags
                else => {},
            }
        }
        if (looksLikeNegativeNumber(arg)) break :blk .negative_number;
        break :blk .other;
    };

    // Positive space: a classified flag/number is at least two chars long.
    std.debug.assert(arg.len >= 2);
    // Negative space: a value_flag is always a 2-char short option.
    if (class == .value_flag) std.debug.assert(arg.len == 2);
    return class;
}

/// Scan args for the first negative number reached before any "--" or
/// value-flag skip. Returns true when such a number exists (argparse would
/// misread it as a flag, so a "--" must be inserted).
fn preprocessArgs_needsFixup(args: []const []const u8) bool {
    var i: usize = 0;
    std.debug.assert(i == 0); // Positive space: scan starts at the front.

    while (i < args.len) : (i += 1) {
        std.debug.assert(i <= args.len); // Loop invariant.
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break; // Already has separator
        switch (preprocessArgs_classify(arg)) {
            .value_flag => i += 1, // Skip the value arg
            .negative_number => return true,
            .bool_flag, .other => {},
        }
    }
    return false;
}

/// Build a new args array with "--" inserted before the first negative number.
/// Preserves value-flag value passthrough and "--" early passthrough.
fn preprocessArgs_rebuild(allocator: Allocator, args: []const []const u8) ![]const []const u8 {
    std.debug.assert(args.len >= 1);

    var new_args = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    var j: usize = 0;
    var inserted = false;
    while (j < args.len) : (j += 1) {
        const arg = args[j];
        if (!inserted and std.mem.eql(u8, arg, "--")) {
            // Already has separator, pass through rest
            try new_args.append(allocator, arg);
            j += 1;
            while (j < args.len) : (j += 1) {
                try new_args.append(allocator, args[j]);
            }
            break;
        }
        if (!inserted) {
            switch (preprocessArgs_classify(arg)) {
                .value_flag => {
                    try new_args.append(allocator, arg);
                    j += 1;
                    if (j < args.len) try new_args.append(allocator, args[j]);
                    continue;
                },
                .negative_number => {
                    try new_args.append(allocator, "--");
                    inserted = true;
                    try new_args.append(allocator, arg);
                    continue;
                },
                .bool_flag, .other => {},
            }
        }
        try new_args.append(allocator, arg);
    }

    const result = try new_args.toOwnedSlice(allocator);
    std.debug.assert(result.len >= args.len); // We only add args.
    return result;
}

/// Pre-process args to handle negative numbers that argparse would
/// misinterpret as flags. Inserts "--" before the first negative number
/// that appears in a positional context (i.e., not a known flag value).
fn preprocessArgs(allocator: Allocator, args: []const []const u8) ![]const []const u8 {
    const needs_fixup = preprocessArgs_needsFixup(args);
    if (!needs_fixup) {
        const passthrough = @constCast(args);
        std.debug.assert(passthrough.ptr == args.ptr); // No copy on the fast path.
        return passthrough;
    }

    const result = try preprocessArgs_rebuild(allocator, args);
    std.debug.assert(result.len >= args.len); // Fixup only inserts "--".
    return result;
}

/// Parsed FIRST/INCREMENT/LAST operands plus the original strings used for
/// precision detection and error messages.
const Operands = struct {
    first: f64,
    increment: f64,
    last: f64,
    first_str: []const u8,
    incr_str: []const u8,
    last_str: []const u8,
};

/// Parse one operand string to f64, emitting the GNU "invalid floating point
/// argument" message and returning null on a parse failure. Does NOT check
/// NaN/Inf: the parent runs those checks afterward, preserving the original's
/// "parse all, then reject NaN/Inf in order" sequencing.
fn run_parseOperands_value(
    operand: []const u8,
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
) ?f64 {
    // No length precondition: an empty operand is a valid (if unparseable)
    // input the original passed straight to parseFloat, which rejects it with
    // the GNU error below. Asserting `operand.len >= 1` would crash on `seq ""`.
    const value = std.fmt.parseFloat(f64, operand) catch {
        const m = invalid_float_msg;
        common.printErrorWithProgram(allocator, stderr_writer, "seq", m, .{operand});
        return null;
    };

    // Postcondition (not a precondition, so no crash on empty input): a
    // successful parseFloat consumed at least one char, so the operand is
    // non-empty here. Negative space: parseFloat never returns a signaling NaN.
    std.debug.assert(operand.len >= 1);
    std.debug.assert(!std.math.isSignalNan(value));
    return value;
}

/// Reject NaN/Inf for one operand with the GNU message, returning false (after
/// emitting) when invalid. Negative space: a finite, non-NaN value passes.
fn run_parseOperands_finite(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    value: f64,
    str: []const u8,
) bool {
    if (std.math.isNan(value) or std.math.isInf(value)) {
        common.printErrorWithProgram(allocator, stderr_writer, "seq", invalid_float_msg, .{str});
        return false;
    }
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));
    return true;
}

/// Parse the 1-3 positional operands into FIRST/INCREMENT/LAST and reject
/// NaN/Inf. Returns null after emitting an error when a value is invalid
/// (parent then returns general_error). The increment==0 check stays in the
/// parent: it is a distinct error with its own message.
fn run_parseOperands(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    positionals: []const []const u8,
) ?Operands {
    std.debug.assert(positionals.len >= 1);
    std.debug.assert(positionals.len <= 3);

    var first: f64 = 1.0;
    var increment: f64 = 1.0;
    var last: f64 = undefined;
    var first_str: []const u8 = "1";
    var incr_str: []const u8 = "1";
    var last_str: []const u8 = undefined;

    switch (positionals.len) {
        1 => {
            last = run_parseOperands_value(positionals[0], allocator, stderr_writer) orelse
                return null;
            last_str = positionals[0];
        },
        2 => {
            first = run_parseOperands_value(positionals[0], allocator, stderr_writer) orelse
                return null;
            first_str = positionals[0];
            last = run_parseOperands_value(positionals[1], allocator, stderr_writer) orelse
                return null;
            last_str = positionals[1];
        },
        3 => {
            first = run_parseOperands_value(positionals[0], allocator, stderr_writer) orelse
                return null;
            first_str = positionals[0];
            increment = run_parseOperands_value(positionals[1], allocator, stderr_writer) orelse
                return null;
            incr_str = positionals[1];
            last = run_parseOperands_value(positionals[2], allocator, stderr_writer) orelse
                return null;
            last_str = positionals[2];
        },
        else => unreachable,
    }

    // Reject NaN and Inf values (GNU seq rejects these), first/increment/last.
    if (!run_parseOperands_finite(allocator, stderr_writer, first, first_str)) return null;
    if (!run_parseOperands_finite(allocator, stderr_writer, increment, incr_str)) return null;
    if (!run_parseOperands_finite(allocator, stderr_writer, last, last_str)) return null;

    return .{
        .first = first,
        .increment = increment,
        .last = last,
        .first_str = first_str,
        .incr_str = incr_str,
        .last_str = last_str,
    };
}

/// Emit the sequence FIRST..LAST stepping by INCREMENT, separated by
/// `separator`, with a trailing newline when anything is printed. The two
/// near-identical drift-bounded loops (ascending vs descending) live here so
/// they stay together out of `run`.
fn run_generateSequence(
    stdout_writer: *std.Io.Writer,
    first: f64,
    increment: f64,
    last: f64,
    separator: []const u8,
    all_integers: bool,
    precision: usize, // tiger:allow:usize-arch decimal precision feeds std.fmt
    pad_width: usize, // tiger:allow:usize-arch -w pad width feeds slice/std.fmt math
    use_format: ?[]const u8,
) !void {
    std.debug.assert(increment != 0.0);
    std.debug.assert(!std.math.isNan(increment));
    // Finite step: parse rejected Inf, and the drift-bound math needs it.
    std.debug.assert(!std.math.isInf(increment));

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
}

/// Derived formatting settings: integer vs decimal mode, precision, and the
/// -w pad width.
const FormatSettings = struct {
    all_integers: bool,
    precision: usize, // tiger:allow:usize-arch decimal precision feeds std.fmt
    pad_width: usize, // tiger:allow:usize-arch -w pad width feeds slice/std.fmt math
};

/// Compute integer/decimal mode, precision, and -w pad width from the parsed
/// operands. Straight-line derivation pulled out of `run`.
fn run_formatSettings(operands: Operands, equal_width: bool) FormatSettings {
    // Determine if we should use integer or decimal formatting
    const all_integers = isInteger(operands.first_str) and isInteger(operands.incr_str) and
        isInteger(operands.last_str);
    const precision = if (all_integers) @as(usize, 0) else @max( // tiger:allow:usize-arch std.fmt
        @max(decimalPlaces(operands.first_str), decimalPlaces(operands.incr_str)),
        decimalPlaces(operands.last_str),
    );

    // Positive space: integer mode implies zero precision.
    if (all_integers) std.debug.assert(precision == 0);

    // Compute width for -w flag
    var pad_width: usize = 0; // tiger:allow:usize-arch slice/std.fmt width math
    if (equal_width) {
        const first_width = numberWidth(operands.first, !all_integers, precision);
        const last_width = numberWidth(operands.last, !all_integers, precision);
        pad_width = @max(first_width, last_width);
    }

    // Negative space: without -w there is no padding.
    if (!equal_width) std.debug.assert(pad_width == 0);
    return .{ .all_integers = all_integers, .precision = precision, .pad_width = pad_width };
}

/// Outcome of resolving positionals: either ready operands or an exit code to
/// return immediately (after the error message was emitted).
const ResolvedOperands = union(enum) {
    operands: Operands,
    exit_code: u8,
};

/// Validate operand count, parse FIRST/INCREMENT/LAST, and reject a zero
/// increment. Emits the matching GNU error and yields an exit code on any
/// failure. Pulls the operand-validation branching out of `run`.
fn run_resolveOperands(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    positionals: []const []const u8,
) ResolvedOperands {
    if (positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "seq", "missing operand", .{});
        return .{ .exit_code = @intFromEnum(common.ExitCode.general_error) };
    }
    if (positionals.len > 3) {
        const m = "extra operand '{s}'";
        common.printErrorWithProgram(allocator, stderr_writer, "seq", m, .{positionals[3]});
        return .{ .exit_code = @intFromEnum(common.ExitCode.general_error) };
    }

    const operands = run_parseOperands(allocator, stderr_writer, positionals) orelse
        return .{ .exit_code = @intFromEnum(common.ExitCode.general_error) };

    if (operands.increment == 0.0) {
        const m = "invalid Zero increment value: '{s}'";
        common.printErrorWithProgram(allocator, stderr_writer, "seq", m, .{operands.incr_str});
        return .{ .exit_code = @intFromEnum(common.ExitCode.general_error) };
    }

    std.debug.assert(operands.increment != 0.0);
    std.debug.assert(positionals.len >= 1);
    return .{ .operands = operands };
}

/// Main entry point for the seq utility
fn run(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = io;
    // Pre-process args to handle negative numbers before argparse
    const processed_args = try preprocessArgs(allocator, args);
    // preprocessArgs only ever inserts a "--", never drops args.
    std.debug.assert(processed_args.len >= args.len);
    defer {
        // Only free if we allocated new args
        if (processed_args.ptr != args.ptr) {
            allocator.free(processed_args);
        }
    }

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        SeqArgs,
        allocator,
        processed_args,
        "seq",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
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

    // Validate count, parse FIRST/INCREMENT/LAST, reject zero increment.
    const positionals = parsed_args.positionals;
    const operands = switch (run_resolveOperands(allocator, stderr_writer, positionals)) {
        .exit_code => |code| return code,
        .operands => |ops| ops,
    };

    // Determine formatting mode
    const use_format = parsed_args.format;
    const separator = parsed_args.separator orelse "\n";
    const settings = run_formatSettings(operands, parsed_args.equal_width);

    // Generate the sequence
    try run_generateSequence(
        stdout_writer,
        operands.first,
        operands.increment,
        operands.last,
        separator,
        settings.all_integers,
        settings.precision,
        settings.pad_width,
        use_format,
    );

    return @intFromEnum(common.ExitCode.success);
}

/// Print a single number with the appropriate formatting
fn printNumber(
    writer: *std.Io.Writer,
    value: f64,
    all_integers: bool,
    precision: usize, // tiger:allow:usize-arch decimal precision feeds std.fmt
    pad_width: usize, // tiger:allow:usize-arch -w pad width feeds slice/std.fmt math
    format_str: ?[]const u8,
) !void {
    // value is the loop's finite `current`; the formatters @intFromFloat it.
    std.debug.assert(!std.math.isNan(value));
    var buf: [128]u8 = undefined;

    const formatted = if (format_str) |fmt|
        try formatWithSpec(&buf, value, fmt)
    else if (all_integers)
        try formatInteger(&buf, value)
    else
        try formatDecimal(&buf, value, precision);

    // Every formatter emits at least one char; the indexing below relies on it.
    std.debug.assert(formatted.len >= 1);

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

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, run);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
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
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("seq ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "seq basic: seq 5" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"5"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n2\n3\n4\n5\n", stdout_aw.writer.buffered());
}

test "seq basic: seq 3 5" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "3", "5" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3\n4\n5\n", stdout_aw.writer.buffered());
}

test "seq basic: seq 1 2 10" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "1", "2", "10" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n3\n5\n7\n9\n", stdout_aw.writer.buffered());
}

test "seq countdown: seq 5 -1 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "5", "--", "-1", "1" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n4\n3\n2\n1\n", stdout_aw.writer.buffered());
}

test "seq separator: seq -s ', ' 3" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", ", ", "3" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1, 2, 3\n", stdout_aw.writer.buffered());
}

test "seq equal width: seq -w 1 10" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-w", "1", "10" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(
        "01\n02\n03\n04\n05\n06\n07\n08\n09\n10\n",
        stdout_aw.writer.buffered(),
    );
}

test "seq empty output when direction wrong" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // seq 5 1 with default increment 1 should print nothing
    const args = [_][]const u8{ "5", "1" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "seq single number" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"1"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n", stdout_aw.writer.buffered());
}

test "seq float: seq 0.5 0.5 2.0" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "0.5", "0.5", "2.0" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.5\n1.0\n1.5\n2.0\n", stdout_aw.writer.buffered());
}

test "seq error: no args" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "seq error: too many args" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "1", "2", "3", "4" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "seq error: invalid number" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"abc"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "invalid floating point argument") != null,
    );
}

test "seq error: zero increment" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "1", "0", "5" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Zero increment") != null);
}

test "seq negative numbers" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "-3", "-1" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-3\n-2\n-1\n", stdout_aw.writer.buffered());
}

test "seq negative to positive" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "-2", "2" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-2\n-1\n0\n1\n2\n", stdout_aw.writer.buffered());
}

test "seq equal width with negative" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-w", "1", "100" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // First few should be zero-padded
    try testing.expect(std.mem.startsWith(u8, stdout_aw.writer.buffered(), "001\n002\n003\n"));
    // Last should not be padded
    try testing.expect(std.mem.endsWith(u8, stdout_aw.writer.buffered(), "099\n100\n"));
}

test "seq format %f" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "%f", "3" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.000000\n2.000000\n3.000000\n", stdout_aw.writer.buffered());
}

test "seq help" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: seq") != null);
}

test "seq version" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "seq") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.name) != null);
}

test "seq large step" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "0", "5", "20" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0\n5\n10\n15\n20\n", stdout_aw.writer.buffered());
}

test "seq decimal precision preserved" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "1.0", "0.1", "1.3" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1.0\n1.1\n1.2\n1.3\n", stdout_aw.writer.buffered());
}

test "seq separator with equal width" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-w", "-s", ":", "8", "10" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("08:09:10\n", stdout_aw.writer.buffered());
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // seq 5 -1 1 should count down without needing --
    const args = [_][]const u8{ "5", "-1", "1" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n4\n3\n2\n1\n", stdout_aw.writer.buffered());
}

// GNU seq with invalid input exits 1, and so do we.
test "audit: seq invalid number exits 1 not 2" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"abc"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // GNU uses exit code 1, not 2
    try testing.expectEqual(@as(u8, 1), result);
}

// IMPORTANT: seq with zero increment should exit 1 not 2
test "audit: seq zero increment exits 1 not 2" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "1", "0", "5" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // GNU uses exit code 1, not 2
    try testing.expectEqual(@as(u8, 1), result);
}

// IMPORTANT: seq with no args should exit 1 not 2
test "audit: seq no args exits 1 not 2" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // GNU uses exit code 1, not 2
    try testing.expectEqual(@as(u8, 1), result);
}

// IMPORTANT: nan input silently produces empty output instead of error
// GNU seq nan outputs error and exits 1.
test "audit: seq nan input produces error" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"nan"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // Must exit non-zero (GNU uses 1)
    try testing.expect(result != 0);
    // Must emit error on stderr
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

// nan as increment should also be rejected
test "audit: seq nan as increment produces error" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "1", "nan", "5" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expect(result != 0);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

// IMPORTANT: -f format prefix/suffix text dropped
// GNU seq -f 'val=%g!' 3 outputs "val=1!\nval=2!\nval=3!\n"
// Our implementation drops prefix "val=" and suffix "!"
test "audit: seq -f format preserves prefix and suffix" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "val=%g!", "3" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("val=1!\nval=2!\nval=3!\n", stdout_aw.writer.buffered());
}

// IMPORTANT: -f format width and precision ignored
// GNU seq -f '%05.1f' 3 outputs "001.0\n002.0\n003.0\n"
test "audit: seq -f format respects width and precision" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "%05.1f", "3" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("001.0\n002.0\n003.0\n", stdout_aw.writer.buffered());
}

// Test gap: float sequences
test "audit: seq float sequence 0.1 0.1 0.5" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "0.1", "0.1", "0.5" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0.1\n0.2\n0.3\n0.4\n0.5\n", stdout_aw.writer.buffered());
}

// Test gap: countdown (without -- workaround, using -- for now to
// verify the basic countdown logic works, independent of the
// argparse issue tested above)
test "audit: seq countdown with double-dash" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "10", "--", "-2", "1" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("10\n8\n6\n4\n2\n", stdout_aw.writer.buffered());
}

// ========== AUDIT G10: buffer overflow in formatWithSpec ==========

// formatWithSpec wrote into the caller-provided byte buffer without
// bounds checks. Each prefix byte (line 291), %% literal (line 191-194),
// width padding, formatted-digit @memcpy, and the suffix @memcpy could
// drive `pos` past `buf.len`. The fix is to return error.NoSpaceLeft
// when a write would overflow rather than corrupt memory.
//
// Methodology: call formatWithSpec with a buffer too small for the
// format string's literal text. The literal prefix alone forces pos
// past buf.len, so the function must return error.NoSpaceLeft instead
// of writing OOB.
test "audit G10: formatWithSpec rejects overflow from prefix text" {
    var buf: [16]u8 = undefined;
    // 20-byte prefix into a 16-byte buffer; no `%` so the loop walks the
    // entire spec writing one byte per iteration into buf[pos].
    const long_prefix = "AAAAAAAAAAAAAAAAAAAA";
    try testing.expectError(error.NoSpaceLeft, formatWithSpec(&buf, 1.0, long_prefix));
}

test "audit G10: formatWithSpec rejects overflow before format spec" {
    var buf: [16]u8 = undefined;
    // 20-byte prefix then %f; prefix copy alone overflows buf.
    const spec = "AAAAAAAAAAAAAAAAAAAA%f";
    try testing.expectError(error.NoSpaceLeft, formatWithSpec(&buf, 1.0, spec));
}

test "audit G10: formatWithSpec rejects overflow from suffix" {
    var buf: [16]u8 = undefined;
    // "%f" formats to "1.000000" (8 bytes) leaving 8 bytes; a 10-byte
    // suffix forces the suffix @memcpy past buf.len.
    const spec = "%fXXXXXXXXXX";
    try testing.expectError(error.NoSpaceLeft, formatWithSpec(&buf, 1.0, spec));
}

test "audit G10: formatWithSpec rejects overflow from %% literal" {
    var buf: [8]u8 = undefined;
    // Sixteen "%%" literals into an 8-byte buffer; each iteration writes
    // a single '%' byte without a bounds check.
    const spec = "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%";
    try testing.expectError(error.NoSpaceLeft, formatWithSpec(&buf, 1.0, spec));
}

test "audit G10: formatWithSpec rejects overflow from width padding" {
    var buf: [16]u8 = undefined;
    // Width 50 with %f forces 50 padding+digit bytes into a 16-byte
    // buffer.
    const spec = "%50f";
    try testing.expectError(error.NoSpaceLeft, formatWithSpec(&buf, 1.0, spec));
}

test "audit G10: formatWithSpec succeeds when buffer fits" {
    var buf: [32]u8 = undefined;
    // Sanity check: ordinary spec still works after the bounds-check fix.
    const result = try formatWithSpec(&buf, 1.0, "val=%f");
    try testing.expectEqualStrings("val=1.000000", result);
}
