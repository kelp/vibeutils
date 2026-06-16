const std = @import("std");

/// Options for human-readable size formatting.
pub const FormatOptions = struct {
    /// Use SI base (1000) instead of binary base (1024).
    si: bool = false,
    /// Suffix style for unit labels.
    suffix: SuffixStyle = .short,
};

pub const SuffixStyle = enum {
    /// Short suffixes: K, M, G, T, P, E (binary) or k, M, G, T, P, E (SI)
    short,
    /// IEC/SI-with-unit suffixes: Ki, Mi, Gi, Ti (binary) or kB, MB, GB, TB (SI)
    iec,
};

/// Format a byte count as a human-readable string (e.g., "1.5K", "23Mi").
///
/// Uses floating-point division with one decimal place for values under 10
/// and no decimals for values at or above 10 in the chosen unit. Values
/// below the base (under 1024 or 1000) are shown as plain integers.
pub fn formatHumanReadable(buf: []u8, bytes: u64, opts: FormatOptions) []const u8 {
    const base: f64 = if (opts.si) 1000.0 else 1024.0;
    // base is a controlled constant (1000.0 or 1024.0), never user input; base > 1
    // is what guarantees the division loop below terminates.
    std.debug.assert(base >= 1000.0);

    // Choose suffix table based on style and SI mode
    const suffixes: []const []const u8 = getSuffixes(opts);
    // getSuffixes always returns a hardcoded 7-element table; the loop bound and
    // the array accesses below rely on it being non-empty.
    std.debug.assert(suffixes.len > 0);

    var value: f64 = @floatFromInt(bytes);
    // value starts non-negative (bytes is u64) and only ever gets divided by a
    // positive base, so it can never go negative or NaN.
    std.debug.assert(value >= 0.0);
    var unit_idx: usize = 0;

    while (value >= base and unit_idx + 1 < suffixes.len) {
        value /= base;
        unit_idx += 1;
    }
    // unit_idx only advances while unit_idx + 1 < suffixes.len, so it can never
    // reach suffixes.len; this guards the suffixes[unit_idx] accesses below.
    std.debug.assert(unit_idx < suffixes.len);

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "?";
    } else if (value >= 10.0) {
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ value, suffixes[unit_idx] }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, suffixes[unit_idx] }) catch "?";
    }
}

fn getSuffixes(opts: FormatOptions) []const []const u8 {
    return switch (opts.suffix) {
        .short => if (opts.si)
            &[_][]const u8{ "", "k", "M", "G", "T", "P", "E" }
        else
            &[_][]const u8{ "", "K", "M", "G", "T", "P", "E" },
        .iec => if (opts.si)
            &[_][]const u8{ "", "kB", "MB", "GB", "TB", "PB", "EB" }
        else
            &[_][]const u8{ "", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei" },
    };
}

/// Parse a block size string like "1K", "4M", "512", "KB", "MB".
///
/// Supports single-char suffixes (K/M/G/T) for binary (1024-based) sizes
/// and double-char suffixes (KB/MB/GB/TB) for SI (1000-based) sizes.
/// A bare suffix without a number (e.g., "K") is treated as 1 * multiplier.
pub fn parseBlockSize(str: []const u8) ?u64 {
    if (str.len == 0) return null;

    // Try pure numeric
    if (std.fmt.parseInt(u64, str, 10)) |val| {
        return if (val == 0) null else val;
    } else |_| {}

    // Try numeric with suffix
    var num_end: usize = 0;
    while (num_end < str.len and (std.ascii.isDigit(str[num_end]) or str[num_end] == '.')) : (num_end += 1) {}
    // The scan only advances while num_end < str.len, so on exit num_end is at
    // most str.len; this bounds the str[0..num_end] and str[num_end..] slices.
    std.debug.assert(num_end <= str.len);

    const base_val: u64 = if (num_end == 0)
        1
    else
        std.fmt.parseInt(u64, str[0..num_end], 10) catch return null;

    if (num_end >= str.len) return null;

    const suffix = str[num_end..];
    // Reached only after the num_end >= str.len guard above returned, so
    // num_end < str.len here and the remaining slice is non-empty.
    std.debug.assert(suffix.len > 0);
    const multiplier: u64 = if (std.mem.eql(u8, suffix, "K") or std.mem.eql(u8, suffix, "k"))
        1024
    else if (std.mem.eql(u8, suffix, "M") or std.mem.eql(u8, suffix, "m"))
        1024 * 1024
    else if (std.mem.eql(u8, suffix, "G") or std.mem.eql(u8, suffix, "g"))
        1024 * 1024 * 1024
    else if (std.mem.eql(u8, suffix, "T") or std.mem.eql(u8, suffix, "t"))
        1024 * 1024 * 1024 * 1024
    else if (std.mem.eql(u8, suffix, "KB"))
        1000
    else if (std.mem.eql(u8, suffix, "MB"))
        1000 * 1000
    else if (std.mem.eql(u8, suffix, "GB"))
        1000 * 1000 * 1000
    else if (std.mem.eql(u8, suffix, "TB"))
        1000 * 1000 * 1000 * 1000
    else
        return null;

    // Every branch reaching here assigned multiplier to a hardcoded constant
    // (1024..1024^4 or 1000..1000^4); the fall-through else returned null. Do
    // NOT assert base_val >= 1: "0K"/"00K" yield base_val == 0 and are valid.
    std.debug.assert(multiplier >= 1000);
    return base_val * multiplier;
}

// Tests

test "formatHumanReadable - binary short" {
    var buf: [32]u8 = undefined;
    const opts = FormatOptions{};

    try std.testing.expectEqualStrings("0", formatHumanReadable(&buf, 0, opts));
    try std.testing.expectEqualStrings("100", formatHumanReadable(&buf, 100, opts));
    try std.testing.expectEqualStrings("1.0K", formatHumanReadable(&buf, 1024, opts));
    try std.testing.expectEqualStrings("1.0M", formatHumanReadable(&buf, 1048576, opts));
    try std.testing.expectEqualStrings("10G", formatHumanReadable(&buf, 10 * 1024 * 1024 * 1024, opts));
}

test "formatHumanReadable - SI short" {
    var buf: [32]u8 = undefined;
    const opts = FormatOptions{ .si = true };

    try std.testing.expectEqualStrings("1.0k", formatHumanReadable(&buf, 1000, opts));
    try std.testing.expectEqualStrings("10k", formatHumanReadable(&buf, 10000, opts));
    try std.testing.expectEqualStrings("1.0M", formatHumanReadable(&buf, 1000000, opts));
}

test "formatHumanReadable - IEC binary" {
    var buf: [32]u8 = undefined;
    const opts = FormatOptions{ .suffix = .iec };

    try std.testing.expectEqualStrings("1.0Ki", formatHumanReadable(&buf, 1024, opts));
    try std.testing.expectEqualStrings("1.0Mi", formatHumanReadable(&buf, 1048576, opts));
}

test "formatHumanReadable - SI with unit" {
    var buf: [32]u8 = undefined;
    const opts = FormatOptions{ .si = true, .suffix = .iec };

    try std.testing.expectEqualStrings("1.0kB", formatHumanReadable(&buf, 1000, opts));
    try std.testing.expectEqualStrings("1.0MB", formatHumanReadable(&buf, 1000000, opts));
}

test "parseBlockSize" {
    try std.testing.expectEqual(@as(?u64, 512), parseBlockSize("512"));
    try std.testing.expectEqual(@as(?u64, 1024), parseBlockSize("K"));
    try std.testing.expectEqual(@as(?u64, 1024), parseBlockSize("1K"));
    try std.testing.expectEqual(@as(?u64, 4096), parseBlockSize("4K"));
    try std.testing.expectEqual(@as(?u64, 1048576), parseBlockSize("1M"));
    try std.testing.expectEqual(@as(?u64, 1000), parseBlockSize("KB"));
    try std.testing.expectEqual(@as(?u64, 1000000), parseBlockSize("MB"));
    try std.testing.expectEqual(@as(?u64, null), parseBlockSize(""));
    try std.testing.expectEqual(@as(?u64, null), parseBlockSize("0"));
    try std.testing.expectEqual(@as(?u64, null), parseBlockSize("XY"));
}
