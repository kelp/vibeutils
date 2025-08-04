//! Streamlined fuzz tests for touch utility
//!
//! Touch creates files and updates timestamps.
//! These tests verify it handles various path and option scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const touch_util = @import("touch.zig");

test "touch fuzz basic" {
    try std.testing.fuzz(testing.allocator, testTouchBasic, .{});
}

fn testTouchBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(touch_util.runUtility, allocator, input);
}

test "touch fuzz paths" {
    try std.testing.fuzz(testing.allocator, testTouchPaths, .{});
}

fn testTouchPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityPaths(touch_util.runUtility, allocator, input);
}

test "touch fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testTouchDeterministic, .{});
}

fn testTouchDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(touch_util.runUtility, allocator, input);
}

test "touch fuzz file lists" {
    try std.testing.fuzz(testing.allocator, testTouchFileLists, .{});
}

fn testTouchFileLists(allocator: std.mem.Allocator, input: []const u8) !void {
    const files = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = touch_util.runUtility(allocator, files, stdout_buf.writer(), common.null_writer) catch {
        // Permission and path errors are expected
        return;
    };
}
