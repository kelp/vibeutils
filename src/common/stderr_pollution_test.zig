//! Test to verify that utilities don't pollute stderr during normal operation
//! This test ensures the two-writer pattern is working correctly

const std = @import("std");
const testing = std.testing;
const common = @import("lib.zig");

// Import utilities for testing
const echo = @import("../echo.zig");
const pwd = @import("../pwd.zig");

/// Buffer writer that tracks all writes
const BufferWriter = struct {
    buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.buffer.writer();
    }

    pub fn getWritten(self: *Self) []const u8 {
        return self.buffer.items;
    }

    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
    }
};

test "echo does not pollute stderr during normal operation" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Test echo with basic arguments
    const args = [_][]const u8{ "hello", "world" };
    const exit_code = try echo.runEcho(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should exit successfully
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should not write anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Should write expected output to stdout
    try testing.expectEqualStrings("hello world\n", stdout_buffer.getWritten());
}

test "echo help does not pollute stderr" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Test echo with help flag
    const args = [_][]const u8{"--help"};
    const exit_code = try echo.runEcho(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should exit successfully
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should not write anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Should write help text to stdout
    try testing.expect(stdout_buffer.getWritten().len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.getWritten(), "Usage:") != null);
}

test "pwd does not pollute stderr during normal operation" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Test pwd with no arguments
    const args = [_][]const u8{};
    const exit_code = try pwd.runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should exit successfully
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should not write anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Should write current directory to stdout
    const output = stdout_buffer.getWritten();
    try testing.expect(output.len > 1); // Should have path + newline
    try testing.expect(output[output.len - 1] == '\n'); // Should end with newline
    try testing.expect(output[0] == '/'); // Should be absolute path
}

test "pwd help does not pollute stderr" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Test pwd with help flag
    const args = [_][]const u8{"--help"};
    const exit_code = try pwd.runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should exit successfully
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should not write anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Should write help text to stdout
    try testing.expect(stdout_buffer.getWritten().len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.getWritten(), "Usage:") != null);
}

test "UtilityContext properly isolates writers" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Create a utility context with our test writers
    const ctx = common.UtilityContext.init(stdout_buffer.writer(), stderr_buffer.writer(), "test", testing.allocator);

    // Test stdout operations
    try ctx.printVersion();
    try testing.expect(stdout_buffer.getWritten().len > 0);
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Reset buffers
    stdout_buffer.reset();
    stderr_buffer.reset();

    // Test stderr operations
    ctx.printError("test error", .{});
    try testing.expect(stderr_buffer.getWritten().len > 0);
    try testing.expectEqualStrings("", stdout_buffer.getWritten());
}

test "echo with UtilityContext does not pollute stderr" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Create a utility context with our test writers
    const ctx = common.UtilityContext.init(stdout_buffer.writer(), stderr_buffer.writer(), "echo", testing.allocator);

    // Test echo with basic arguments using new context API
    const args = [_][]const u8{ "hello", "context" };
    const exit_code = try echo.runEchoWithContext(ctx, &args);

    // Should exit successfully
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should not write anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Should write expected output to stdout
    try testing.expectEqualStrings("hello context\n", stdout_buffer.getWritten());
}

test "pwd with UtilityContext does not pollute stderr" {
    var stderr_buffer = BufferWriter.init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = BufferWriter.init(testing.allocator);
    defer stdout_buffer.deinit();

    // Create a utility context with our test writers
    const ctx = common.UtilityContext.init(stdout_buffer.writer(), stderr_buffer.writer(), "pwd", testing.allocator);

    // Test pwd with no arguments using new context API
    const args = [_][]const u8{};
    const exit_code = try pwd.runPwdWithContext(ctx, &args);

    // Should exit successfully
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should not write anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.getWritten());

    // Should write current directory to stdout
    const output = stdout_buffer.getWritten();
    try testing.expect(output.len > 1); // Should have path + newline
    try testing.expect(output[output.len - 1] == '\n'); // Should end with newline
    try testing.expect(output[0] == '/'); // Should be absolute path
}
