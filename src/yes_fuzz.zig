//! Streamlined fuzz tests for yes utility
//!
//! Yes outputs specified strings repeatedly until interrupted.
//! These tests use limited output to avoid infinite loops.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const yes_util = @import("yes.zig");

/// Limited writer to prevent infinite output during fuzzing
const LimitedWriter = struct {
    buffer: *std.ArrayList(u8),
    limit: usize,
    written: usize = 0,

    pub fn write(self: *@This(), bytes: []const u8) !usize {
        if (self.written >= self.limit) {
            return error.BrokenPipe; // Simulate SIGPIPE
        }
        const to_write = @min(bytes.len, self.limit - self.written);
        try self.buffer.appendSlice(bytes[0..to_write]);
        self.written += to_write;
        if (self.written >= self.limit) {
            return error.BrokenPipe;
        }
        return to_write;
    }

    pub fn writer(self: *@This()) std.io.Writer(*@This(), error{ BrokenPipe, OutOfMemory }, write) {
        return .{ .context = self };
    }
};

// Create standardized fuzz tests using the unified builder
const YesFuzzTests = common.fuzz.createUtilityFuzzTests(yes_util.runUtility);

test "yes fuzz basic" {
    try std.testing.fuzz(testing.allocator, testYesBasicLimited, .{});
}

fn testYesBasicLimited(allocator: std.mem.Allocator, input: []const u8) !void {
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var limited_writer = LimitedWriter{ .buffer = &stdout_buf, .limit = 1000 };

    _ = yes_util.runUtility(allocator, args, limited_writer.writer(), common.null_writer) catch |err| {
        // BrokenPipe and other errors are expected
        _ = err;
        return;
    };
}

test "yes fuzz paths" {
    try std.testing.fuzz(testing.allocator, YesFuzzTests.testPaths, .{});
}

test "yes fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testYesDeterministicLimited, .{});
}

fn testYesDeterministicLimited(allocator: std.mem.Allocator, input: []const u8) !void {
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var stdout_buf1 = std.ArrayList(u8).init(allocator);
    defer stdout_buf1.deinit();
    var stdout_buf2 = std.ArrayList(u8).init(allocator);
    defer stdout_buf2.deinit();

    var limited_writer1 = LimitedWriter{ .buffer = &stdout_buf1, .limit = 200 };
    var limited_writer2 = LimitedWriter{ .buffer = &stdout_buf2, .limit = 200 };

    const result1 = yes_util.runUtility(allocator, args, limited_writer1.writer(), common.null_writer) catch |err| switch (err) {
        error.BrokenPipe => @as(u8, 0), // Expected result
        else => return err,
    };

    const result2 = yes_util.runUtility(allocator, args, limited_writer2.writer(), common.null_writer) catch |err| switch (err) {
        error.BrokenPipe => @as(u8, 0), // Expected result
        else => return err,
    };

    // Results should be identical for same input
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(stdout_buf1.items, stdout_buf2.items);
}

test "yes fuzz output patterns" {
    try std.testing.fuzz(testing.allocator, testYesOutputPatterns, .{});
}

fn testYesOutputPatterns(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Test various output patterns
    const patterns = [_][]const []const u8{
        &.{}, // Default 'y'
        &.{"hello"},
        &.{ "a", "b", "c" },
        &.{""},
        &.{ "hello", "world" },
    };

    const args = patterns[input[0] % patterns.len];

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var limited_writer = LimitedWriter{ .buffer = &stdout_buf, .limit = 500 };

    _ = yes_util.runUtility(allocator, args, limited_writer.writer(), common.null_writer) catch |err| {
        // BrokenPipe is expected
        _ = err;
        return;
    };
}
