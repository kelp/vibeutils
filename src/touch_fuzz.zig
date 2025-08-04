//! Streamlined fuzz tests for touch utility
//!
//! Touch creates files and updates timestamps.
//! Tests verify the utility handles various path and option scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const touch_util = @import("touch.zig");

// Create standardized fuzz tests using the unified builder
const TouchFuzzTests = common.fuzz.createUtilityFuzzTests(touch_util.runUtility);

test "touch fuzz basic" {
    try std.testing.fuzz(testing.allocator, TouchFuzzTests.testBasic, .{});
}

test "touch fuzz paths" {
    try std.testing.fuzz(testing.allocator, TouchFuzzTests.testPaths, .{});
}

test "touch fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, TouchFuzzTests.testDeterministic, .{});
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
