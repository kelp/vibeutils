//! true - return a successful exit status
//!
//! The true utility always exits with status 0 (success) and produces no output.
//! According to POSIX.1-2017, it ignores all command-line arguments.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Main entry point for the true utility
/// Always returns success (0) regardless of arguments, following POSIX specification
pub fn runTrue(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = allocator;
    _ = io;
    _ = args;
    _ = stdout_writer;
    _ = stderr_writer;

    return @intFromEnum(common.ExitCode.success);
}

/// Standard main function - minimal since true never outputs
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTrue);
}

// ============================================================================
// TESTS
// ============================================================================

test "true always returns 0 and ignores all arguments" {
    const io = testing.io;
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
        const result = try runTrue(
            testing.allocator,
            io,
            args,
            common.null_writer,
            common.null_writer,
        );
        try testing.expectEqual(@as(u8, 0), result);
    }
}

test "true produces no output" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with no arguments
    _ = try runTrue(testing.allocator, io, &.{}, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());

    // Test with arguments
    _ = try runTrue(
        testing.allocator,
        io,
        &.{ "--help", "--version", "test" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}
