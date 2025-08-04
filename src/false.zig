//! false - do nothing, unsuccessfully
//!
//! The false utility always exits with status 1, produces no output, and ignores all arguments.
//! This is the simplest possible system utility - it literally does nothing except fail.
//!
//! POSIX-compliant implementation compatible with GNU coreutils.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Standardized entry point for the false utility
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = allocator; // unused
    _ = args; // false ignores all arguments
    _ = stdout_writer; // false produces no output
    _ = stderr_writer; // false produces no output

    // Always return 1 (failure)
    return @intFromEnum(common.ExitCode.general_error);
}

/// Legacy entry point - kept for backward compatibility during migration
pub fn runFalse(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    return runUtility(allocator, args, stdout_writer, stderr_writer);
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

    const exit_code = try runFalse(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
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
        const result = try runUtility(testing.allocator, args, common.null_writer, common.null_writer);
        try testing.expectEqual(@as(u8, 1), result);
    }
}

test "false produces no output" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test with no arguments
    _ = try runUtility(testing.allocator, &.{}, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);

    // Clear buffers and test with arguments
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    _ = try runUtility(testing.allocator, &.{ "--help", "--version", "test" }, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);
}
