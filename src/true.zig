//! true - return a successful exit status
//!
//! The true utility always exits with status 0 (success) and produces no output.
//! According to POSIX.1-2017, it ignores all command-line arguments.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Main entry point for the true utility
/// Always returns success (0) regardless of arguments, following POSIX specification
pub fn runTrue(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = allocator;
    _ = args;
    _ = stdout_writer;
    _ = stderr_writer;

    return @intFromEnum(common.ExitCode.success);
}

/// Standard main function - minimal since true never outputs
pub fn main() !void {
    std.process.exit(0);
}

// ============================================================================
// TESTS
// ============================================================================

test "true always returns 0 and ignores all arguments" {
    // Test various argument patterns - true should always return 0
    const test_cases = [_][]const []const u8{
        &.{},
        &.{"--help"},
        &.{"--version"},
        &.{ "some", "random", "arguments" },
        &.{ "-h", "-v", "--anything" },
        &.{ "arg1", "arg2", "arg3", "--flag", "-f", "value", "--another=flag" },
    };

    for (test_cases) |args| {
        const result = try runTrue(testing.allocator, args, common.null_writer, common.null_writer);
        try testing.expectEqual(@as(u8, 0), result);
    }
}

test "true produces no output" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test with no arguments
    _ = try runTrue(testing.allocator, &.{}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);

    // Clear buffers and test with arguments
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    _ = try runTrue(testing.allocator, &.{ "--help", "--version", "test" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);
}
