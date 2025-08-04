//! Streamlined fuzz tests for cat utility
//!
//! Cat concatenates files and prints them to stdout.
//! Tests verify the utility handles various file scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const cat_util = @import("cat.zig");

// Create standardized fuzz tests using the unified builder
const CatFuzzTests = common.fuzz.createUtilityFuzzTests(cat_util.runUtility);

test "cat fuzz basic" {
    try std.testing.fuzz(testing.allocator, CatFuzzTests.testBasic, .{});
}

test "cat fuzz paths" {
    try std.testing.fuzz(testing.allocator, CatFuzzTests.testPaths, .{});
}

test "cat fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, CatFuzzTests.testDeterministic, .{});
}

test "cat fuzz file lists" {
    try std.testing.fuzz(testing.allocator, testCatFileLists, .{});
}

fn testCatFileLists(allocator: std.mem.Allocator, input: []const u8) !void {
    const files = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = cat_util.runUtility(allocator, files, stdout_buf.writer(), common.null_writer) catch {
        // File not found errors are expected
        return;
    };
}
