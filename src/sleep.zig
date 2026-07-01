//! sleep - delay for a specified amount of time
//!
//! The sleep utility suspends execution for at least the specified amount of time.
//! Time can be specified as a plain number (seconds), or with a unit suffix.
//!
//! This implementation supports GNU-compatible time parsing with decimal values
//! and multiple time arguments that are summed together.
const std = @import("std");
const common = @import("common");
const time = common.time;
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

/// Errors that can arise while parsing the sleep duration arguments.
const SleepParseError = error{
    MissingTimeArgument,
    InvalidTimeFormat,
    NegativeTime,
    TimeOverflow,
};

/// Parse all time arguments and return total nanoseconds
fn parseTotalTime(args: []const []const u8) SleepParseError!u64 {
    if (args.len == 0) {
        return error.MissingTimeArgument;
    }

    var total_nanos: u64 = 0;

    for (args) |arg| {
        const nanos = try time.parseTimeString(arg);

        // Check for overflow when adding
        if (total_nanos > std.math.maxInt(u64) - nanos) {
            return error.TimeOverflow;
        }

        // The guard above proves the add stays within u64; assert it before
        // and verify no wrap occurred after.
        std.debug.assert(total_nanos <= std.math.maxInt(u64) - nanos);
        total_nanos += nanos;
        std.debug.assert(total_nanos >= nanos);
    }

    return total_nanos;
}

/// Find the first token that fails to parse as a valid time string.
/// Used to include the offending token in error messages (GNU behavior).
fn findBadToken(args: []const []const u8) ?[]const u8 {
    for (args) |arg| {
        _ = time.parseTimeString(arg) catch return arg;
    }
    return null;
}

/// Print help message
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: sleep NUMBER[SUFFIX]...
        \\  or:  sleep OPTION
        \\Pause for NUMBER seconds.  SUFFIX may be 's' for seconds (the default),
        \\'m' for minutes, 'h' for hours or 'd' for days.  NUMBER may be a
        \\floating-point value.  Given two or more arguments, pause for the amount
        \\of time specified by the sum of their values.
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
    );
}

/// Print version information
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("sleep ({s}) {s}\n", .{ common.name, common.version });
}

/// Print "invalid time interval" for a parse failure, including the offending
/// token when one can be identified (GNU includes it in the message).
fn printInvalidInterval(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    positionals: []const []const u8,
) void {
    const bad_token = findBadToken(positionals);
    if (bad_token) |token| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "sleep",
            "invalid time interval '{s}'",
            .{token},
        );
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "sleep",
            "invalid time interval",
            .{},
        );
    }
}

/// Report a parseTotalTime error to stderr and return the misuse exit code.
fn reportParseError(
    err: SleepParseError,
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    positionals: []const []const u8,
) u8 {
    switch (err) {
        error.MissingTimeArgument => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "sleep",
                "missing operand",
                .{},
            );
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "sleep",
                "Try 'sleep --help' for more information.",
                .{},
            );
        },
        error.InvalidTimeFormat, error.NegativeTime => {
            printInvalidInterval(allocator, stderr_writer, positionals);
        },
        error.TimeOverflow => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "sleep",
                "invalid time interval: value too large",
                .{},
            );
        },
    }
    return @intFromEnum(common.ExitCode.misuse);
}

pub fn runSleep(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const parsed_args = common.argparse.ArgParser.parseOrExit(
        SleepArgs,
        allocator,
        args,
        "sleep",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.misuse);
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

    // Parse time arguments, tracking which token failed for error reporting
    const total_nanos = parseTotalTime(parsed_args.positionals) catch |err| {
        return reportParseError(err, allocator, stderr_writer, parsed_args.positionals);
    };

    // Sleep for the specified duration
    if (total_nanos > 0) {
        const duration = std.Io.Duration.fromNanoseconds(@intCast(total_nanos));
        // u64 -> i96 is lossless, so the Duration preserves the source value
        // and stays strictly positive within this branch.
        std.debug.assert(duration.nanoseconds == @as(i96, total_nanos));
        std.debug.assert(duration.nanoseconds > 0);
        std.Io.sleep(io, duration, .awake) catch {};
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Standard main function
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runSleep);
}

// ============================================================================
// TESTS
// ============================================================================

test "parseTimeString - basic integer seconds" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try time.parseTimeString("5"));
    try testing.expectEqual(@as(u64, 0), try time.parseTimeString("0"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), try time.parseTimeString("1"));
    try testing.expectEqual(@as(u64, 123 * std.time.ns_per_s), try time.parseTimeString("123"));
}

test "parseTimeString - decimal seconds" {
    try testing.expectEqual(
        @as(u64, @intFromFloat(0.5 * std.time.ns_per_s)),
        try time.parseTimeString("0.5"),
    );
    try testing.expectEqual(
        @as(u64, @intFromFloat(1.5 * std.time.ns_per_s)),
        try time.parseTimeString("1.5"),
    );
    try testing.expectEqual(
        @as(u64, @intFromFloat(2.25 * std.time.ns_per_s)),
        try time.parseTimeString("2.25"),
    );
    try testing.expectEqual(
        @as(u64, @intFromFloat(0.1 * std.time.ns_per_s)),
        try time.parseTimeString("0.1"),
    );
}

test "parseTimeString - seconds with suffix" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try time.parseTimeString("5s"));
    try testing.expectEqual(
        @as(u64, @intFromFloat(2.5 * std.time.ns_per_s)),
        try time.parseTimeString("2.5s"),
    );
    try testing.expectEqual(@as(u64, 0), try time.parseTimeString("0s"));
}

test "parseTimeString - minutes" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_min), try time.parseTimeString("1m"));
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_min), try time.parseTimeString("5m"));
    try testing.expectEqual(
        @as(u64, @intFromFloat(2.5 * std.time.ns_per_min)),
        try time.parseTimeString("2.5m"),
    );
    try testing.expectEqual(
        @as(u64, @intFromFloat(0.5 * std.time.ns_per_min)),
        try time.parseTimeString("0.5m"),
    );
}

test "parseTimeString - hours" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_hour), try time.parseTimeString("1h"));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try time.parseTimeString("2h"));
    try testing.expectEqual(
        @as(u64, @intFromFloat(1.5 * std.time.ns_per_hour)),
        try time.parseTimeString("1.5h"),
    );
}

test "parseTimeString - days" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_day), try time.parseTimeString("1d"));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_day), try time.parseTimeString("2d"));
    try testing.expectEqual(
        @as(u64, @intFromFloat(0.5 * std.time.ns_per_day)),
        try time.parseTimeString("0.5d"),
    );
}

test "parseTimeString - invalid formats" {
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString(""));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("s"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("m"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("h"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("d"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("abc"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("5x"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("5."));
    // .5 is valid (GNU compatible, means 0.5 seconds)
    try testing.expectEqual(
        @as(u64, @intFromFloat(0.5 * std.time.ns_per_s)),
        try time.parseTimeString(".5"),
    );
}

test "parseTimeString - reject NaN and Inf (except GNU-compatible inf/infinity)" {
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("nan"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("NaN"));
    // GNU sleep accepts 'inf' and 'infinity' as meaning sleep forever
    try testing.expectEqual(std.math.maxInt(u64), try time.parseTimeString("inf"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("Inf"));
    try testing.expectEqual(std.math.maxInt(u64), try time.parseTimeString("infinity"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("nans"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("infm"));
}

test "parseTimeString - negative values" {
    try testing.expectError(error.NegativeTime, time.parseTimeString("-1"));
    try testing.expectError(error.NegativeTime, time.parseTimeString("-0.5"));
    try testing.expectError(error.NegativeTime, time.parseTimeString("-5s"));
    try testing.expectError(error.NegativeTime, time.parseTimeString("-1m"));
}

test "parseTotalTime - single arguments" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try parseTotalTime(&.{"5"}));
    try testing.expectEqual(
        @as(u64, @intFromFloat(2.5 * std.time.ns_per_s)),
        try parseTotalTime(&.{"2.5"}),
    );
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_min), try parseTotalTime(&.{"1m"}));
}

test "parseTotalTime - multiple arguments sum" {
    // 1 minute + 30 seconds = 90 seconds total
    const expected = 1 * std.time.ns_per_min + 30 * std.time.ns_per_s;
    try testing.expectEqual(expected, try parseTotalTime(&.{ "1m", "30s" }));

    // 1 hour + 30 minutes + 15 seconds
    const expected2 = 1 * std.time.ns_per_hour +
        30 * std.time.ns_per_min +
        15 * std.time.ns_per_s;
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{"--help"},
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(
        std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: sleep NUMBER[SUFFIX]") != null,
    );
}

test "runSleep - version option" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{"--version"},
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(
        std.mem.find(u8, stdout_aw.writer.buffered(), "sleep (vibeutils)") != null,
    );
}

test "runSleep - missing arguments" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runSleep(testing.allocator, io, &.{}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "runSleep - invalid time format" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{"invalid"},
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "invalid time interval") != null,
    );
}

test "runSleep - negative time (with separator)" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{ "--", "-1" },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "invalid time interval") != null,
    );
}

test "runSleep - negative flag treated as unknown argument" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{"-1"},
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") != null,
    );
}

test "runSleep - zero seconds (should succeed immediately)" {
    const io = testing.io;
    const result = try runSleep(
        testing.allocator,
        io,
        &.{"0"},
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
}

test "runSleep - very small sleep time" {
    // This should complete quickly - testing that small sleep times work
    const io = testing.io;
    const start_ts = std.Io.Timestamp.now(io, .awake);
    const result = try runSleep(
        testing.allocator,
        io,
        &.{"0.001"},
        common.null_writer,
        common.null_writer,
    );
    const end_ts = std.Io.Timestamp.now(io, .awake);
    const elapsed_ms = start_ts.durationTo(end_ts).toMilliseconds();

    try testing.expectEqual(@as(u8, 0), result);
    // Should complete in reasonable time (less than 100ms for a 1ms sleep)
    try testing.expect(elapsed_ms < 100);
}

test "runSleep - multiple time arguments" {
    // Test that multiple arguments are accepted and processed
    // We use very small times to keep tests fast
    const io = testing.io;
    const result = try runSleep(
        testing.allocator,
        io,
        &.{ "0.001", "0.001s" },
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
}

test "runSleep - zero sleep with captured output" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{"0"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "TimeUnit.toNanos - verify unit conversions" {
    try testing.expectEqual(std.time.ns_per_s, time.TimeUnit.seconds.toNanos());
    try testing.expectEqual(std.time.ns_per_min, time.TimeUnit.minutes.toNanos());
    try testing.expectEqual(std.time.ns_per_hour, time.TimeUnit.hours.toNanos());
    try testing.expectEqual(std.time.ns_per_day, time.TimeUnit.days.toNanos());
}

// ============================================================================
// Audit finding tests (IMPORTANT) — wave 5
// ============================================================================

test "parseTimeString accepts 'inf' (GNU compatible)" {
    const result = try time.parseTimeString("inf");
    try testing.expectEqual(std.math.maxInt(u64), result);
}

test "parseTimeString accepts 'infinity' (GNU compatible)" {
    const result = try time.parseTimeString("infinity");
    try testing.expectEqual(std.math.maxInt(u64), result);
}

test "runSleep error message includes the invalid token" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runSleep(
        testing.allocator,
        io,
        &.{"xyz"},
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), result);
    // The error message should include the invalid token 'xyz'
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "'xyz'") != null);
}
