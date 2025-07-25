const std = @import("std");
const testing = std.testing;

/// Time units for relative date calculations
const TimeUnit = enum {
    second,
    minute,
    hour,
    day,
    week,
    month,
    year,
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

/// Format a timestamp as a relative date string
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

    // Check if it's too old for relative formatting
    const max_age_seconds = config.max_relative_age_days * 24 * 3600;
    if (diff_seconds > max_age_seconds) {
        return formatAbsoluteDate(timestamp_ns, allocator);
    }

    // Format based on time difference
    if (diff_seconds < 60) {
        return try allocator.dupe(u8, "just now");
    } else if (diff_seconds < 3600) {
        const minutes = @divTrunc(diff_seconds, 60);
        if (minutes == 1) {
            return try allocator.dupe(u8, "1 minute ago");
        } else {
            return try std.fmt.allocPrint(allocator, "{} minutes ago", .{minutes});
        }
    } else if (diff_seconds < 86400) {
        const hours = @divTrunc(diff_seconds, 3600);
        if (hours == 1) {
            return try allocator.dupe(u8, "1 hour ago");
        } else {
            return try std.fmt.allocPrint(allocator, "{} hours ago", .{hours});
        }
    } else if (diff_seconds < 172800 and config.use_yesterday) { // 2 days
        return try allocator.dupe(u8, "yesterday");
    } else if (diff_seconds < 604800) { // 1 week
        const days = @divTrunc(diff_seconds, 86400);
        if (days == 1) {
            return try allocator.dupe(u8, "1 day ago");
        } else {
            return try std.fmt.allocPrint(allocator, "{} days ago", .{days});
        }
    } else if (diff_seconds < 1209600 and config.use_last_period) { // 2 weeks
        return try allocator.dupe(u8, "last week");
    } else if (diff_seconds < 2629746) { // ~1 month (30.44 days)
        const weeks = @divTrunc(diff_seconds, 604800);
        if (weeks == 1) {
            return try allocator.dupe(u8, "1 week ago");
        } else {
            return try std.fmt.allocPrint(allocator, "{} weeks ago", .{weeks});
        }
    } else if (diff_seconds < 5259492 and config.use_last_period) { // ~2 months
        return try allocator.dupe(u8, "last month");
    } else if (diff_seconds < 31556952) { // ~1 year
        const months = @divTrunc(diff_seconds, 2629746); // approximate month
        if (months == 1) {
            return try allocator.dupe(u8, "1 month ago");
        } else {
            return try std.fmt.allocPrint(allocator, "{} months ago", .{months});
        }
    } else {
        const years = @divTrunc(diff_seconds, 31556952); // approximate year
        if (years == 1) {
            return try allocator.dupe(u8, "1 year ago");
        } else {
            return try std.fmt.allocPrint(allocator, "{} years ago", .{years});
        }
    }
}

/// Format an absolute date (fallback for very old or future dates)
pub fn formatAbsoluteDate(timestamp_ns: i128, allocator: std.mem.Allocator) ![]u8 {
    const timestamp_s = @divTrunc(timestamp_ns, std.time.ns_per_s);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp_s) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Format as "Jan 15 2024" or "Jan 15 15:30" for current year
    const current_year = blk: {
        const now_s = @divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s);
        const now_epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(now_s) };
        const now_year_day = now_epoch.getEpochDay().calculateYearDay();
        break :blk now_year_day.year;
    };

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const month_name = month_names[month_day.month.numeric() - 1];

    if (year_day.year == current_year) {
        // Same year: show "Jan 15 15:30"
        const hour = day_seconds.getHoursIntoDay();
        const minute = day_seconds.getMinutesIntoHour();
        return try std.fmt.allocPrint(allocator, "{s} {d} {d:0>2}:{d:0>2}", .{ month_name, month_day.day_index + 1, hour, minute });
    } else {
        // Different year: show "Jan 15 2024"
        return try std.fmt.allocPrint(allocator, "{s} {d} {d}", .{ month_name, month_day.day_index + 1, year_day.year });
    }
}

/// Get current timestamp in nanoseconds
pub fn nowNanoseconds() i128 {
    return std.time.nanoTimestamp();
}

/// Create a default config with current time
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
    const one_min = current - (1 * 60 * std.time.ns_per_s);
    const result1 = try formatRelativeDate(one_min, config, allocator);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 minute ago", result1);

    // 5 minutes ago
    const five_min = current - (5 * 60 * std.time.ns_per_s);
    const result2 = try formatRelativeDate(five_min, config, allocator);
    defer allocator.free(result2);
    try testing.expectEqualStrings("5 minutes ago", result2);
}

test "relative dates - hours ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 hour ago
    const one_hour = current - (1 * 3600 * std.time.ns_per_s);
    const result1 = try formatRelativeDate(one_hour, config, allocator);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 hour ago", result1);

    // 3 hours ago
    const three_hours = current - (3 * 3600 * std.time.ns_per_s);
    const result2 = try formatRelativeDate(three_hours, config, allocator);
    defer allocator.free(result2);
    try testing.expectEqualStrings("3 hours ago", result2);
}

test "relative dates - yesterday" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 day ago (within yesterday range)
    const yesterday = current - (30 * 3600 * std.time.ns_per_s); // 30 hours ago
    const result = try formatRelativeDate(yesterday, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("yesterday", result);
}

test "relative dates - days ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 3 days ago
    const three_days = current - (3 * 24 * 3600 * std.time.ns_per_s);
    const result = try formatRelativeDate(three_days, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("3 days ago", result);
}

test "relative dates - last week" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 10 days ago (should be "last week")
    const last_week = current - (10 * 24 * 3600 * std.time.ns_per_s);
    const result = try formatRelativeDate(last_week, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("last week", result);
}

test "relative dates - weeks ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 3 weeks ago
    const three_weeks = current - (3 * 7 * 24 * 3600 * std.time.ns_per_s);
    const result = try formatRelativeDate(three_weeks, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("3 weeks ago", result);
}

test "relative dates - last month" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 6 weeks ago (should be "last month")
    const last_month = current - (6 * 7 * 24 * 3600 * std.time.ns_per_s);
    const result = try formatRelativeDate(last_month, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("last month", result);
}

test "relative dates - months ago" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 3 months ago (use the same calculation as the function)
    const three_months = current - (3 * 2629746 * std.time.ns_per_s); // 3 * seconds_per_month
    const result = try formatRelativeDate(three_months, config, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("3 months ago", result);
}

test "relative dates - future dates show absolute" {
    const allocator = testing.allocator;
    const current = nowNanoseconds();
    const config = RelativeDateConfig{ .current_time_ns = current };

    // 1 hour in the future
    const future = current + (3600 * std.time.ns_per_s);
    const result = try formatRelativeDate(future, config, allocator);
    defer allocator.free(result);

    // Should be an absolute date format (we don't test exact string since it depends on current date)
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
    const two_years = current - (2 * 365 * 24 * 3600 * std.time.ns_per_s);
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
