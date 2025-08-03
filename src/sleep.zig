//! sleep - delay for a specified amount of time
//!
//! The sleep utility suspends execution for at least the specified amount of time.
//! Time can be specified as a plain number (seconds), or with a unit suffix.
//!
//! This implementation supports GNU-compatible time parsing with decimal values
//! and multiple time arguments that are summed together.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Command-line arguments for the sleep utility
const SleepArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Time arguments (numbers with optional unit suffixes)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Time unit multipliers in nanoseconds
const TimeUnit = enum {
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
fn parseTimeString(time_str: []const u8) !u64 {
    if (time_str.len == 0) {
        return error.InvalidTimeFormat;
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
    // First check for invalid formats like "5." or ".5"
    if (number_part.len == 0 or
        std.mem.endsWith(u8, number_part, ".") or
        std.mem.startsWith(u8, number_part, "."))
    {
        return error.InvalidTimeFormat;
    }

    const parsed_value = std.fmt.parseFloat(f64, number_part) catch {
        return error.InvalidTimeFormat;
    };

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

/// Parse all time arguments and return total nanoseconds
fn parseTotalTime(args: []const []const u8) !u64 {
    if (args.len == 0) {
        return error.MissingTimeArgument;
    }

    var total_nanos: u64 = 0;

    for (args) |arg| {
        const nanos = try parseTimeString(arg);

        // Check for overflow when adding
        if (total_nanos > std.math.maxInt(u64) - nanos) {
            return error.TimeOverflow;
        }

        total_nanos += nanos;
    }

    return total_nanos;
}

/// Sleep for the specified duration in nanoseconds
/// Uses high-precision nanosleep where available
fn sleepNanos(nanos: u64) void {
    if (nanos == 0) return;

    std.time.sleep(nanos);
}

/// Print help message
fn printHelp(writer: anytype) !void {
    try writer.print(
        \\Usage: sleep NUMBER[SUFFIX]...
        \\  or:  sleep OPTION
        \\Pause for NUMBER seconds.  SUFFIX may be 's' for seconds (the default),
        \\'m' for minutes, 'h' for hours or 'd' for days.  Unlike most implementations
        \\that require NUMBER be an integer, here NUMBER may be an arbitrary floating
        \\point number.  Given two or more arguments, pause for the amount of time
        \\specified by the sum of their values.
        \\
        \\  -h, --help     display this help and exit
        \\  -V, --version  output version information and exit
        \\
        \\Examples:
        \\  sleep 0.5      # Pause for half a second
        \\  sleep 2.5m     # Pause for 2 minutes and 30 seconds
        \\  sleep 1h 30m   # Pause for 1 hour and 30 minutes
        \\  sleep 1d       # Pause for 1 day
        \\
        \\Report bugs to: kelp@plek.org
        \\Home page: <https://tcole.net>
        \\
    , .{});
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("sleep (vibeutils) 1.0.0\n", .{});
}

/// Main entry point for the sleep utility
pub fn runSleep(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed_args = common.argparse.ArgParser.parse(SleepArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "sleep", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Parse time arguments
    const total_nanos = parseTotalTime(parsed_args.positionals) catch |err| {
        switch (err) {
            error.MissingTimeArgument => {
                common.printErrorWithProgram(allocator, stderr_writer, "sleep", "missing operand", .{});
                common.printErrorWithProgram(allocator, stderr_writer, "sleep", "Try 'sleep --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.InvalidTimeFormat => {
                common.printErrorWithProgram(allocator, stderr_writer, "sleep", "invalid time interval", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.NegativeTime => {
                common.printErrorWithProgram(allocator, stderr_writer, "sleep", "invalid time interval", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.TimeOverflow => {
                common.printErrorWithProgram(allocator, stderr_writer, "sleep", "invalid time interval: value too large", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
        }
    };

    // Sleep for the specified duration
    sleepNanos(total_nanos);

    return @intFromEnum(common.ExitCode.success);
}

/// Standard main function
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runSleep(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
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
    try testing.expectError(error.InvalidTimeFormat, parseTimeString(".5"));
}

test "parseTimeString - negative values" {
    try testing.expectError(error.NegativeTime, parseTimeString("-1"));
    try testing.expectError(error.NegativeTime, parseTimeString("-0.5"));
    try testing.expectError(error.NegativeTime, parseTimeString("-5s"));
    try testing.expectError(error.NegativeTime, parseTimeString("-1m"));
}

test "parseTotalTime - single arguments" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try parseTotalTime(&.{"5"}));
    try testing.expectEqual(@as(u64, @intFromFloat(2.5 * std.time.ns_per_s)), try parseTotalTime(&.{"2.5"}));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_min), try parseTotalTime(&.{"1m"}));
}

test "parseTotalTime - multiple arguments sum" {
    // 1 minute + 30 seconds = 90 seconds total
    const expected = 1 * std.time.ns_per_min + 30 * std.time.ns_per_s;
    try testing.expectEqual(expected, try parseTotalTime(&.{ "1m", "30s" }));

    // 1 hour + 30 minutes + 15 seconds
    const expected2 = 1 * std.time.ns_per_hour + 30 * std.time.ns_per_min + 15 * std.time.ns_per_s;
    try testing.expectEqual(expected2, try parseTotalTime(&.{ "1h", "30m", "15s" }));

    // Mix of different formats
    const expected3 = 2 * std.time.ns_per_s + @as(u64, @intFromFloat(0.5 * std.time.ns_per_s));
    try testing.expectEqual(expected3, try parseTotalTime(&.{ "2", "0.5s" }));
}

test "parseTotalTime - no arguments" {
    try testing.expectError(error.MissingTimeArgument, parseTotalTime(&.{}));
}

test "parseTotalTime - invalid arguments" {
    try testing.expectError(error.InvalidTimeFormat, parseTotalTime(&.{"invalid"}));
    try testing.expectError(error.NegativeTime, parseTotalTime(&.{"-1"}));
    try testing.expectError(error.InvalidTimeFormat, parseTotalTime(&.{ "1", "invalid" }));
}

test "runSleep - help option" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const result = try runSleep(testing.allocator, &.{"--help"}, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: sleep NUMBER[SUFFIX]") != null);
}

test "runSleep - version option" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const result = try runSleep(testing.allocator, &.{"--version"}, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "sleep (vibeutils)") != null);
}

test "runSleep - missing arguments" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runSleep(testing.allocator, &.{}, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "runSleep - invalid time format" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runSleep(testing.allocator, &.{"invalid"}, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid time interval") != null);
}

test "runSleep - negative time (with separator)" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runSleep(testing.allocator, &.{ "--", "-1" }, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid time interval") != null);
}

test "runSleep - negative flag treated as unknown argument" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runSleep(testing.allocator, &.{"-1"}, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid argument") != null);
}

test "runSleep - zero seconds (should succeed immediately)" {
    const result = try runSleep(testing.allocator, &.{"0"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runSleep - very small sleep time" {
    // This should complete quickly - testing that small sleep times work
    const start_time = std.time.milliTimestamp();
    const result = try runSleep(testing.allocator, &.{"0.001"}, common.null_writer, common.null_writer);
    const end_time = std.time.milliTimestamp();

    try testing.expectEqual(@as(u8, 0), result);
    // Should complete in reasonable time (less than 100ms for a 1ms sleep)
    try testing.expect(end_time - start_time < 100);
}

test "runSleep - multiple time arguments" {
    // Test that multiple arguments are accepted and processed
    // We use very small times to keep tests fast
    const result = try runSleep(testing.allocator, &.{ "0.001", "0.001s" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "TimeUnit.toNanos - verify unit conversions" {
    try testing.expectEqual(std.time.ns_per_s, TimeUnit.seconds.toNanos());
    try testing.expectEqual(std.time.ns_per_min, TimeUnit.minutes.toNanos());
    try testing.expectEqual(std.time.ns_per_hour, TimeUnit.hours.toNanos());
    try testing.expectEqual(std.time.ns_per_day, TimeUnit.days.toNanos());
}

test "sleepNanos - zero duration" {
    // Should return immediately without sleeping
    const start_time = std.time.milliTimestamp();
    sleepNanos(0);
    const end_time = std.time.milliTimestamp();

    // Should complete almost immediately (allow for small measurement variance)
    try testing.expect(end_time - start_time < 10);
}
