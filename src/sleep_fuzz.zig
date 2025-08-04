//! Streamlined fuzz tests for sleep utility
//!
//! Sleep delays execution for a specified time with various time formats.
//! Tests verify the utility handles time parsing gracefully without actually sleeping.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const sleep_util = @import("sleep.zig");

// Create standardized fuzz tests using the unified builder
const SleepFuzzTests = common.fuzz.createUtilityFuzzTests(sleep_util.runUtility);

test "sleep fuzz basic" {
    try std.testing.fuzz(testing.allocator, SleepFuzzTests.testBasic, .{});
}

test "sleep fuzz paths" {
    try std.testing.fuzz(testing.allocator, SleepFuzzTests.testPaths, .{});
}

test "sleep fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, SleepFuzzTests.testDeterministic, .{});
}

test "sleep fuzz time formats" {
    try std.testing.fuzz(testing.allocator, testSleepTimeFormats, .{});
}

fn testSleepTimeFormats(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate various time format patterns
    const formats = [_][]const u8{
        "0",    "0.1", "1",  "5",  "10",   "0.001",
        "1s",   "2m",  "1h", "1d", "1.5s", "2.25m",
        "0.1h",
    };

    const time_arg = formats[input[0] % formats.len];
    const args = [_][]const u8{time_arg};

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = sleep_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Time parsing errors are acceptable
        return;
    };
}

test "sleep fuzz multiple time args" {
    try std.testing.fuzz(testing.allocator, testSleepMultipleArgs, .{});
}

fn testSleepMultipleArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Test multiple time args that get summed
    const args = [_][]const u8{ "0.001", "0.001", "0.001" };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = sleep_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable
        return;
    };
}
