//! false - do nothing, unsuccessfully
//!
//! The false utility always exits with status 1, produces no output,
//! and ignores all arguments.
//!
//! POSIX-compliant implementation compatible with GNU coreutils.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Main entry point for the false utility
pub fn runFalse(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = allocator;
    _ = args;
    _ = stdout_writer;
    _ = stderr_writer;

    return @intFromEnum(common.ExitCode.general_error);
}

/// Standard main function - minimal since false never outputs
pub fn main() !void {
    std.process.exit(1);
}

// ============================================================================
// TESTS
// ============================================================================

test "false always returns 1 and ignores all arguments" {
    // Test various argument patterns - false should always return 1
    const test_cases = [_][]const []const u8{
        &.{}, // no arguments
        &.{"--help"},
        &.{"--version"},
        &.{ "some", "random", "arguments" },
        &.{ "-h", "-v", "--anything" },
        &.{ "arg1", "arg2", "arg3", "--flag", "-f", "value", "--another=flag" },
    };

    for (test_cases) |args| {
        const result = try runFalse(testing.allocator, args, common.null_writer, common.null_writer);
        try testing.expectEqual(@as(u8, 1), result);
    }
}

test "false produces no output" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test with no arguments
    _ = try runFalse(testing.allocator, &.{}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);

    // Clear buffers and test with arguments
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    _ = try runFalse(testing.allocator, &.{ "--help", "--version", "test" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("false");

test "false fuzz basic" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testFalseBasic, .{});
}

fn testFalseBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    if (!common.fuzz.shouldFuzzUtilityRuntime("false")) return;
    try common.fuzz.testUtilityBasic(runFalse, allocator, input, common.null_writer);
}
