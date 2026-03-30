//! Shared time types and functions for vibeutils.
//!
//! Provides C library time bindings (c_tm, localtime_r, etc.) and
//! duration-string parsing (TimeUnit, parseTimeString) used by
//! date, stat, sleep, and timeout utilities.

const std = @import("std");
const c = std.c;
const testing = std.testing;

// ============================================================================
// C library time bindings
// ============================================================================

/// C library tm struct for time conversion functions.
pub const c_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

pub extern "c" fn localtime_r(timer: *const c.time_t, result: *c_tm) ?*c_tm;
pub extern "c" fn gmtime_r(timer: *const c.time_t, result: *c_tm) ?*c_tm;
pub extern "c" fn strftime(s: [*]u8, maxsize: usize, format: [*:0]const u8, tp: *const c_tm) usize;
pub extern "c" fn mktime(tp: *c_tm) c.time_t;
pub extern "c" fn timegm(tp: *c_tm) c.time_t;

// ============================================================================
// Duration string parsing
// ============================================================================

/// Time unit multipliers in nanoseconds
pub const TimeUnit = enum {
    seconds,
    minutes,
    hours,
    days,

    pub fn toNanos(self: TimeUnit) u64 {
        return switch (self) {
            .seconds => std.time.ns_per_s,
            .minutes => std.time.ns_per_min,
            .hours => std.time.ns_per_hour,
            .days => std.time.ns_per_day,
        };
    }
};

/// Parse a time string into nanoseconds
/// Supports: plain numbers (5), unit suffixes (5s, 2.5m, 1h, 3d)
/// Decimal values are supported (0.5, 1.25, etc.)
pub fn parseTimeString(time_str: []const u8) !u64 {
    if (time_str.len == 0) {
        return error.InvalidTimeFormat;
    }

    // GNU sleep accepts 'inf' and 'infinity' to mean sleep forever.
    if (std.mem.eql(u8, time_str, "inf") or std.mem.eql(u8, time_str, "infinity")) {
        return std.math.maxInt(u64);
    }

    // Find the unit suffix (if any)
    var number_part = time_str;
    var unit = TimeUnit.seconds; // default unit

    const last_char = time_str[time_str.len - 1];
    switch (last_char) {
        's' => {
            unit = .seconds;
            number_part = time_str[0 .. time_str.len - 1];
        },
        'm' => {
            unit = .minutes;
            number_part = time_str[0 .. time_str.len - 1];
        },
        'h' => {
            unit = .hours;
            number_part = time_str[0 .. time_str.len - 1];
        },
        'd' => {
            unit = .days;
            number_part = time_str[0 .. time_str.len - 1];
        },
        else => {
            // No unit suffix, treat as seconds
            number_part = time_str;
            unit = .seconds;
        },
    }

    if (number_part.len == 0) {
        return error.InvalidTimeFormat;
    }

    // Parse the number part (support decimal values)
    // Check for invalid formats like "5." but allow ".5" (GNU compatible)
    if (std.mem.endsWith(u8, number_part, ".")) {
        return error.InvalidTimeFormat;
    }

    const parsed_value = std.fmt.parseFloat(f64, number_part) catch {
        return error.InvalidTimeFormat;
    };

    // Reject NaN and Inf values
    if (std.math.isNan(parsed_value) or std.math.isInf(parsed_value)) {
        return error.InvalidTimeFormat;
    }

    if (parsed_value < 0) {
        return error.NegativeTime;
    }

    // Convert to nanoseconds
    const nanos_per_unit = @as(f64, @floatFromInt(unit.toNanos()));
    const total_nanos = parsed_value * nanos_per_unit;

    // Check for overflow
    if (total_nanos > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return error.TimeOverflow;
    }

    return @as(u64, @intFromFloat(total_nanos));
}

// ============================================================================
// TESTS
// ============================================================================

test "parseTimeString - basic integer seconds" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try parseTimeString("5"));
    try testing.expectEqual(@as(u64, 0), try parseTimeString("0"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), try parseTimeString("1"));
    try testing.expectEqual(@as(u64, 123 * std.time.ns_per_s), try parseTimeString("123"));
}

test "parseTimeString - decimal seconds" {
    try testing.expectEqual(@as(u64, @intFromFloat(0.5 * std.time.ns_per_s)), try parseTimeString("0.5"));
    try testing.expectEqual(@as(u64, @intFromFloat(1.5 * std.time.ns_per_s)), try parseTimeString("1.5"));
    try testing.expectEqual(@as(u64, @intFromFloat(2.25 * std.time.ns_per_s)), try parseTimeString("2.25"));
    try testing.expectEqual(@as(u64, @intFromFloat(0.1 * std.time.ns_per_s)), try parseTimeString("0.1"));
}

test "parseTimeString - seconds with suffix" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try parseTimeString("5s"));
    try testing.expectEqual(@as(u64, @intFromFloat(2.5 * std.time.ns_per_s)), try parseTimeString("2.5s"));
    try testing.expectEqual(@as(u64, 0), try parseTimeString("0s"));
}

test "parseTimeString - minutes" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_min), try parseTimeString("1m"));
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_min), try parseTimeString("5m"));
    try testing.expectEqual(@as(u64, @intFromFloat(2.5 * std.time.ns_per_min)), try parseTimeString("2.5m"));
    try testing.expectEqual(@as(u64, @intFromFloat(0.5 * std.time.ns_per_min)), try parseTimeString("0.5m"));
}

test "parseTimeString - hours" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_hour), try parseTimeString("1h"));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try parseTimeString("2h"));
    try testing.expectEqual(@as(u64, @intFromFloat(1.5 * std.time.ns_per_hour)), try parseTimeString("1.5h"));
}

test "parseTimeString - days" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_day), try parseTimeString("1d"));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_day), try parseTimeString("2d"));
    try testing.expectEqual(@as(u64, @intFromFloat(0.5 * std.time.ns_per_day)), try parseTimeString("0.5d"));
}

test "parseTimeString - invalid formats" {
    try testing.expectError(error.InvalidTimeFormat, parseTimeString(""));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("s"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("m"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("h"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("d"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("abc"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("5x"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("5."));
    // .5 is valid (GNU compatible, means 0.5 seconds)
    try testing.expectEqual(@as(u64, @intFromFloat(0.5 * std.time.ns_per_s)), try parseTimeString(".5"));
}

test "parseTimeString - reject NaN and Inf (except GNU-compatible inf/infinity)" {
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("nan"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("NaN"));
    // GNU sleep accepts 'inf' and 'infinity' as meaning sleep forever
    try testing.expectEqual(std.math.maxInt(u64), try parseTimeString("inf"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("Inf"));
    try testing.expectEqual(std.math.maxInt(u64), try parseTimeString("infinity"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("nans"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("infm"));
}

test "parseTimeString - negative values" {
    try testing.expectError(error.NegativeTime, parseTimeString("-1"));
    try testing.expectError(error.NegativeTime, parseTimeString("-0.5"));
    try testing.expectError(error.NegativeTime, parseTimeString("-5s"));
    try testing.expectError(error.NegativeTime, parseTimeString("-1m"));
}

test "TimeUnit.toNanos - verify unit conversions" {
    try testing.expectEqual(std.time.ns_per_s, TimeUnit.seconds.toNanos());
    try testing.expectEqual(std.time.ns_per_min, TimeUnit.minutes.toNanos());
    try testing.expectEqual(std.time.ns_per_hour, TimeUnit.hours.toNanos());
    try testing.expectEqual(std.time.ns_per_day, TimeUnit.days.toNanos());
}
