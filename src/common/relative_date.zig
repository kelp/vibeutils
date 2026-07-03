const std = @import("std");
const testing = std.testing;

/// Time constants for relative date calculations
const TimeConstants = struct {
    // Base time units in seconds
    const seconds_per_minute: i128 = 60;
    const seconds_per_hour: i128 = 60 * 60; // 3600
    const seconds_per_day: i128 = 24 * 60 * 60; // 86400

    // Derived time units
    const seconds_per_two_days: i128 = 2 * seconds_per_day; // 172800
    const seconds_per_week: i128 = 7 * seconds_per_day; // 604800
    const seconds_per_two_weeks: i128 = 2 * seconds_per_week; // 1209600

    // Approximate calendar units (using astronomical averages)
    const seconds_per_month: i128 = 2629746; // 30.44 days average
    const seconds_per_two_months: i128 = 2 * seconds_per_month; // 5259492
    const seconds_per_year: i128 = 31556952; // 365.24 days average

    // Threshold for "just now" formatting
    const just_now_threshold: i128 = seconds_per_minute;
};

/// String constants for relative date formatting
const Strings = struct {
    const just_now = "just now";
    const yesterday = "yesterday";
    const last_week = "last week";
    const last_month = "last month";

    const one_minute_ago = "1 minute ago";
    const one_hour_ago = "1 hour ago";
    const one_day_ago = "1 day ago";
    const one_week_ago = "1 week ago";
    const one_month_ago = "1 month ago";
    const one_year_ago = "1 year ago";

    // Plural output is "{count} {unit} ago"; the parent ladder previously held
    // one full format string per unit (e.g. "{} minutes ago"). Storing just the
    // unit word lets formatRelativeDate_formatCount keep a single comptime
    // format string while producing byte-identical output.
    const plural_unit_fmt = "{} {s} ago";
    const minutes_unit = "minutes";
    const hours_unit = "hours";
    const days_unit = "days";
    const weeks_unit = "weeks";
    const months_unit = "months";
    const years_unit = "years";

    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const same_year_fmt = "{s} {d} {d:0>2}:{d:0>2}";
    const different_year_fmt = "{s} {d} {d}";
};

/// One magnitude bucket of relative-date formatting: the divisor that converts
/// diff_seconds to a whole-unit count, the exact string for a count of 1, and
/// the plural unit word. Bundling these lets each ladder branch in
/// formatRelativeDate pass a single value, keeping the call within the column
/// limit; the values themselves are copied verbatim from the original branches.
const Magnitude = struct {
    divisor: i128,
    singular: []const u8,
    plural_unit: []const u8,
};

/// Per-unit magnitude buckets, named to match the threshold ladder branches in
/// formatRelativeDate. Each is the exact (divisor, singular, plural_unit) triple
/// that branch previously inlined.
const Magnitudes = struct {
    const minute = Magnitude{
        .divisor = TimeConstants.seconds_per_minute,
        .singular = Strings.one_minute_ago,
        .plural_unit = Strings.minutes_unit,
    };
    const hour = Magnitude{
        .divisor = TimeConstants.seconds_per_hour,
        .singular = Strings.one_hour_ago,
        .plural_unit = Strings.hours_unit,
    };
    const day = Magnitude{
        .divisor = TimeConstants.seconds_per_day,
        .singular = Strings.one_day_ago,
        .plural_unit = Strings.days_unit,
    };
    const week = Magnitude{
        .divisor = TimeConstants.seconds_per_week,
        .singular = Strings.one_week_ago,
        .plural_unit = Strings.weeks_unit,
    };
    const month = Magnitude{
        .divisor = TimeConstants.seconds_per_month,
        .singular = Strings.one_month_ago,
        .plural_unit = Strings.months_unit,
    };
    const year = Magnitude{
        .divisor = TimeConstants.seconds_per_year,
        .singular = Strings.one_year_ago,
        .plural_unit = Strings.years_unit,
    };
};

/// Configuration for relative date formatting
pub const RelativeDateConfig = struct {
    /// Current time reference point (nanoseconds since epoch)
    current_time_ns: i128,
    /// Maximum age for relative formatting (older dates show absolute)
    max_relative_age_days: u32 = 365,
    /// Use "yesterday" for 1 day ago
    use_yesterday: bool = true,
    /// Use "last week"/"last month" for recent periods
    use_last_period: bool = true,
};

/// Format a timestamp as a relative date string.
/// Returns a human-readable string describing how long ago the timestamp was,
/// or an absolute date for very old/future timestamps.
pub fn formatRelativeDate(
    timestamp_ns: i128,
    config: RelativeDateConfig,
    allocator: std.mem.Allocator,
) ![]u8 {
    const diff_ns = config.current_time_ns - timestamp_ns;

    // If it's in the future, show absolute date
    if (diff_ns < 0) {
        return formatAbsoluteDate(timestamp_ns, allocator);
    }

    // Convert to seconds for easier calculations
    const diff_seconds = @divTrunc(diff_ns, std.time.ns_per_s);
    // The diff_ns < 0 guard above establishes diff_ns >= 0; dividing a
    // non-negative dividend by a positive divisor stays non-negative.
    std.debug.assert(diff_seconds >= 0);

    // Check if it's too old for relative formatting
    const max_age_seconds = config.max_relative_age_days * TimeConstants.seconds_per_day;
    // u32 days (>= 0) times the positive seconds_per_day constant is non-negative.
    std.debug.assert(max_age_seconds >= 0);
    if (diff_seconds > max_age_seconds) {
        return formatAbsoluteDate(timestamp_ns, allocator);
    }

    // Format based on time difference. The threshold ladder stays here (push
    // ifs up); each magnitude branch defers its identical count-formatting tail
    // (assert quotient >= 1, then singular vs plural) to the helper below.
    if (diff_seconds < TimeConstants.just_now_threshold) {
        return try allocator.dupe(u8, Strings.just_now);
    } else if (diff_seconds < TimeConstants.seconds_per_hour) {
        return try formatRelativeDate_formatCount(allocator, diff_seconds, &Magnitudes.minute);
    } else if (diff_seconds < TimeConstants.seconds_per_day) {
        return try formatRelativeDate_formatCount(allocator, diff_seconds, &Magnitudes.hour);
    } else if (diff_seconds < TimeConstants.seconds_per_two_days and config.use_yesterday) {
        return try allocator.dupe(u8, Strings.yesterday);
    } else if (diff_seconds < TimeConstants.seconds_per_week) {
        return try formatRelativeDate_formatCount(allocator, diff_seconds, &Magnitudes.day);
    } else if (diff_seconds < TimeConstants.seconds_per_two_weeks and config.use_last_period) {
        return try allocator.dupe(u8, Strings.last_week);
    } else if (diff_seconds < TimeConstants.seconds_per_month) {
        return try formatRelativeDate_formatCount(allocator, diff_seconds, &Magnitudes.week);
    } else if (diff_seconds < TimeConstants.seconds_per_two_months and config.use_last_period) {
        return try allocator.dupe(u8, Strings.last_month);
    } else if (diff_seconds < TimeConstants.seconds_per_year) {
        return try formatRelativeDate_formatCount(allocator, diff_seconds, &Magnitudes.month);
    } else {
        return try formatRelativeDate_formatCount(allocator, diff_seconds, &Magnitudes.year);
    }
}

/// Format the count tail shared by every magnitude branch of
/// formatRelativeDate: divide diff_seconds by the magnitude's divisor, then
/// return the singular string for a count of 1 or the formatted plural
/// otherwise. Logic is copied verbatim from the per-branch tails; only
/// relocated, so behavior is identical. Magnitude is 48 bytes (> 16), so it is
/// passed by const pointer per Tiger Style.
fn formatRelativeDate_formatCount(
    allocator: std.mem.Allocator,
    diff_seconds: i128,
    magnitude: *const Magnitude,
) ![]u8 {
    // Negative space: every caller is gated by a threshold ladder that only
    // reaches this branch once diff_seconds is at least one whole unit, and the
    // divisor is always a positive TimeConstants value, so count is never < 1.
    std.debug.assert(magnitude.divisor > 0);
    std.debug.assert(diff_seconds >= magnitude.divisor);
    const count = @divTrunc(diff_seconds, magnitude.divisor);
    std.debug.assert(count >= 1);
    if (count == 1) {
        return try allocator.dupe(u8, magnitude.singular);
    } else {
        const args = .{ count, magnitude.plural_unit };
        return try std.fmt.allocPrint(allocator, Strings.plural_unit_fmt, args);
    }
}

/// Format an absolute date (fallback for very old or future dates).
/// Returns either "Jan 15 15:30" for dates in the current year,
/// or "Jan 15 2024" for dates in different years.
pub fn formatAbsoluteDate(timestamp_ns: i128, allocator: std.mem.Allocator) ![]u8 {
    const timestamp_s = @divTrunc(timestamp_ns, std.time.ns_per_s);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp_s) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Format as "Jan 15 2024" or "Jan 15 15:30" for current year
    const current_year = blk: {
        const file = @import("file.zig");
        const now_s = @divTrunc(file.currentTimestampNanoseconds(), std.time.ns_per_s);
        const now_epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(now_s) };
        const now_year_day = now_epoch.getEpochDay().calculateYearDay();
        break :blk now_year_day.year;
    };

    // Month enum is 1-based (jan=1..dec=12), so numeric() - 1 is a valid index
    // into the 12-entry month_names table; guard both bounds before indexing.
    std.debug.assert(month_day.month.numeric() >= 1);
    std.debug.assert(month_day.month.numeric() <= Strings.month_names.len);
    const month_name = Strings.month_names[month_day.month.numeric() - 1];

    if (year_day.year == current_year) {
        // Same year: show "Jan 15 15:30"
        const hour = day_seconds.getHoursIntoDay();
        const minute = day_seconds.getMinutesIntoHour();
        return try std.fmt.allocPrint(
            allocator,
            Strings.same_year_fmt,
            .{ month_name, month_day.day_index + 1, hour, minute },
        );
    } else {
        // Different year: show "Jan 15 2024"
        return try std.fmt.allocPrint(
            allocator,
            Strings.different_year_fmt,
            .{ month_name, month_day.day_index + 1, year_day.year },
        );
    }
}

/// Get current timestamp in nanoseconds since Unix epoch.
/// This is the primary time unit used throughout the relative date system.
pub fn nowNanoseconds() i128 {
    const file = @import("file.zig");
    return file.currentTimestampNanoseconds();
}

/// Create a default configuration using current time as reference point.
/// Uses standard settings: 1 year max age, yesterday/last period enabled.
pub fn defaultConfig() RelativeDateConfig {
    return RelativeDateConfig{
        .current_time_ns = nowNanoseconds(),
    };
}

// Tests
test "relative dates - just now" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 30 seconds ago
    const timestamp = current - (30 * std.time.ns_per_s);
    const result = try formatRelativeDate(timestamp, config, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("just now", result);
}

test "relative dates - minutes ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 minute ago
    const one_min = current - (1 * TimeConstants.seconds_per_minute * std.time.ns_per_s);
    const result1 = try formatRelativeDate(one_min, config, allocator);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 minute ago", result1);

    // 5 minutes ago
    const five_min = current - (5 * TimeConstants.seconds_per_minute * std.time.ns_per_s);
    const result2 = try formatRelativeDate(five_min, config, allocator);
    defer allocator.free(result2);
    try testing.expectEqualStrings("5 minutes ago", result2);
}

test "relative dates - hours ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 hour ago
    const one_hour = current - (1 * TimeConstants.seconds_per_hour * std.time.ns_per_s);
    const result1 = try formatRelativeDate(one_hour, config, allocator);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 hour ago", result1);

    // 3 hours ago
    const three_hours = current - (3 * TimeConstants.seconds_per_hour * std.time.ns_per_s);
    const result2 = try formatRelativeDate(three_hours, config, allocator);
    defer allocator.free(result2);
    try testing.expectEqualStrings("3 hours ago", result2);
}

test "relative dates - yesterday" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 day ago (within yesterday range)
    // 30 hours ago
    const yesterday = current - (30 * TimeConstants.seconds_per_hour * std.time.ns_per_s);
    const result = try formatRelativeDate(yesterday, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("yesterday", result);
}

test "relative dates - days ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 3 days ago
    const three_days = current - (3 * TimeConstants.seconds_per_day * std.time.ns_per_s);
    const result = try formatRelativeDate(three_days, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("3 days ago", result);
}

test "relative dates - last week" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 10 days ago (should be "last week")
    const last_week = current - (10 * TimeConstants.seconds_per_day * std.time.ns_per_s);
    const result = try formatRelativeDate(last_week, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("last week", result);
}

test "relative dates - weeks ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 3 weeks ago
    const three_weeks = current - (3 * TimeConstants.seconds_per_week * std.time.ns_per_s);
    const result = try formatRelativeDate(three_weeks, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("3 weeks ago", result);
}

test "relative dates - last month" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 6 weeks ago (should be "last month")
    const last_month = current - (6 * TimeConstants.seconds_per_week * std.time.ns_per_s);
    const result = try formatRelativeDate(last_month, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("last month", result);
}

test "relative dates - months ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 3 months ago (use the same calculation as the function)
    const three_months = current - (3 * TimeConstants.seconds_per_month * std.time.ns_per_s);
    const result = try formatRelativeDate(three_months, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("3 months ago", result);
}

test "relative dates - future dates show absolute" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 hour in the future
    const future = current + (TimeConstants.seconds_per_hour * std.time.ns_per_s);
    const result = try formatRelativeDate(future, config, allocator);
    defer allocator.free(result);

    // Should be an absolute date format (we don't test exact string since it
    // depends on current date)
    try testing.expect(result.len > 0);
    try testing.expect(!std.mem.startsWith(u8, result, "ago"));
}

test "relative dates - very old dates show absolute" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{
        .current_time_ns = current,
        .max_relative_age_days = 365, // 1 year max
    };

    // 2 years ago
    const two_years = current - (2 * 365 * TimeConstants.seconds_per_day * std.time.ns_per_s);
    const result = try formatRelativeDate(two_years, config, allocator);
    defer allocator.free(result);

    // Should be an absolute date format
    try testing.expect(result.len > 0);
    try testing.expect(!std.mem.endsWith(u8, result, "ago"));
}

test "absolute date formatting" {
    const allocator = testing.allocator;

    // Test with a known timestamp (January 15, 2024, 15:30 UTC)
    // Note: This is approximate since we're working with epoch calculations
    const jan_15_2024 = std.time.nanoTimestamp(); // Use current time as baseline
    const result = try formatAbsoluteDate(jan_15_2024, allocator);
    defer allocator.free(result);

    // Should contain month name and day
    try testing.expect(result.len > 5);
    // Basic format validation - should have letters and numbers
    var has_letter = false;
    var has_digit = false;
    for (result) |c| {
        if (std.ascii.isAlphabetic(c)) has_letter = true;
        if (std.ascii.isDigit(c)) has_digit = true;
    }
    try testing.expect(has_letter);
    try testing.expect(has_digit);
}
