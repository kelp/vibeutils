//! Streamlined fuzz tests for dirname utility
//!
//! Dirname extracts the directory portion from pathnames.
//! It should handle various path formats gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const dirname_util = @import("dirname.zig");

test "dirname fuzz basic" {
    try std.testing.fuzz(testing.allocator, testDirnameBasic, .{});
}

fn testDirnameBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(dirname_util.runUtility, allocator, input);
}

test "dirname fuzz paths" {
    try std.testing.fuzz(testing.allocator, testDirnamePaths, .{});
}

fn testDirnamePaths(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityPaths(dirname_util.runUtility, allocator, input);
}

test "dirname fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testDirnameDeterministic, .{});
}

fn testDirnameDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(dirname_util.runUtility, allocator, input);
}
