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
pub fn runFalse(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    _ = allocator;
    _ = io;
    _ = args;
    _ = stdout_writer;
    _ = stderr_writer;

    return @intFromEnum(common.ExitCode.general_error);
}

/// Standard main function - minimal since false never outputs
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runFalse);
}

// ============================================================================
// TESTS
// ============================================================================

test "false always returns 1 and ignores all arguments" {
    const io = testing.io;

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
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();
        const result = try runFalse(testing.allocator, io, args, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 1), result);
    }
}

test "false produces no output" {
    const io = testing.io;

    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        // Test with no arguments
        _ = try runFalse(testing.allocator, io, &.{}, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqualStrings("", stdout_aw.writer.buffered());
        try testing.expectEqualStrings("", stderr_aw.writer.buffered());
    }

    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        _ = try runFalse(testing.allocator, io, &.{ "--help", "--version", "test" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqualStrings("", stdout_aw.writer.buffered());
        try testing.expectEqualStrings("", stderr_aw.writer.buffered());
    }
}
