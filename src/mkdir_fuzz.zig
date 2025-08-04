//! Streamlined fuzz tests for mkdir utility
//!
//! Mkdir creates directories with various options.
//! These tests verify it handles path and permission scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const mkdir_util = @import("mkdir.zig");

test "mkdir fuzz basic" {
    try std.testing.fuzz(testing.allocator, testMkdirBasic, .{});
}

fn testMkdirBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(mkdir_util.runUtility, allocator, input);
}

test "mkdir fuzz paths" {
    try std.testing.fuzz(testing.allocator, testMkdirPaths, .{});
}

fn testMkdirPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityPaths(mkdir_util.runUtility, allocator, input);
}

test "mkdir fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testMkdirDeterministic, .{});
}

fn testMkdirDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(mkdir_util.runUtility, allocator, input);
}

test "mkdir fuzz permissions" {
    try std.testing.fuzz(testing.allocator, testMkdirPermissions, .{});
}

fn testMkdirPermissions(allocator: std.mem.Allocator, input: []const u8) !void {
    const perm = common.fuzz.generateFilePermissions(input);
    const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{perm});
    defer allocator.free(perm_str);

    const args = [_][]const u8{ "-m", perm_str, "/tmp/fuzz_test_dir" };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = mkdir_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Permission and path errors are expected
        return;
    };
}
