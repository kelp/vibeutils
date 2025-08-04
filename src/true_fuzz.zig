//! Streamlined fuzz tests for true utility
//!
//! True is the simplest utility - it always succeeds and produces no output.
//! These tests verify it handles any input gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const true_util = @import("true.zig");

test "true fuzz basic" {
    try std.testing.fuzz(testing.allocator, testTrueBasic, .{});
}

fn testTrueBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(true_util.runUtility, allocator, input);
}

test "true fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testTrueDeterministic, .{});
}

fn testTrueDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(true_util.runUtility, allocator, input);
}

test "true fuzz invariant properties" {
    try std.testing.fuzz(testing.allocator, testTrueInvariants, .{});
}

fn testTrueInvariants(allocator: std.mem.Allocator, input: []const u8) !void {
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    const result = try true_util.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer());

    // Invariant properties of true:
    try testing.expectEqual(@as(u8, 0), result); // Always returns 0
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len); // Never writes to stdout
    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len); // Never writes to stderr
}
