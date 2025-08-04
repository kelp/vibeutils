//! Streamlined fuzz tests for basename utility
//!
//! Basename extracts the final component from pathnames.
//! It should handle various path formats gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const basename_util = @import("basename.zig");

test "basename fuzz basic" {
    try std.testing.fuzz(testing.allocator, testBasenameBasic, .{});
}

fn testBasenameBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(basename_util.runUtility, allocator, input);
}

test "basename fuzz paths" {
    try std.testing.fuzz(testing.allocator, testBasenamePaths, .{});
}

fn testBasenamePaths(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityPaths(basename_util.runUtility, allocator, input);
}

test "basename fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testBasenameDeterministic, .{});
}

fn testBasenameDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(basename_util.runUtility, allocator, input);
}
