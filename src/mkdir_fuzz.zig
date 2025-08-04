//! Streamlined fuzz tests for mkdir utility
//!
//! Mkdir creates directories with various options.
//! Tests verify the utility handles path and permission scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const mkdir_util = @import("mkdir.zig");

// Create standardized fuzz tests using the unified builder
const MkdirFuzzTests = common.fuzz.createUtilityFuzzTests(mkdir_util.runUtility);

test "mkdir fuzz basic" {
    try std.testing.fuzz(testing.allocator, MkdirFuzzTests.testBasic, .{});
}

test "mkdir fuzz paths" {
    try std.testing.fuzz(testing.allocator, MkdirFuzzTests.testPaths, .{});
}

test "mkdir fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, MkdirFuzzTests.testDeterministic, .{});
}

test "mkdir fuzz parent creation" {
    try std.testing.fuzz(testing.allocator, testMkdirParents, .{});
}

fn testMkdirParents(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate nested directory path
    const nested_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(nested_path);

    // Test with -p flag for parent creation
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ "-p", nested_path },
        &[_][]const u8{ "--parents", nested_path },
        &[_][]const u8{ "-pv", nested_path }, // With verbose
    };

    for (test_cases) |args| {
        var stdout_buf = std.ArrayList(u8).init(allocator);
        defer stdout_buf.deinit();

        _ = mkdir_util.runUtility(allocator, args, stdout_buf.writer(), common.null_writer) catch {
            // Expected to fail for invalid paths
            continue;
        };
    }
}
