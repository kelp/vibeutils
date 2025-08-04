//! Streamlined fuzz tests for false utility
//!
//! False is the simplest failing utility - it always fails and produces no output.
//! These tests verify it handles any input gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const false_util = @import("false.zig");

test "false fuzz basic" {
    try std.testing.fuzz(testing.allocator, testFalseBasic, .{});
}

fn testFalseBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(false_util.runUtility, allocator, input);
}

test "false fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testFalseDeterministic, .{});
}

fn testFalseDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(false_util.runUtility, allocator, input);
}

test "false fuzz invariant properties" {
    try std.testing.fuzz(testing.allocator, testFalseInvariants, .{});
}

fn testFalseInvariants(allocator: std.mem.Allocator, input: []const u8) !void {
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    const result = try false_util.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer());

    // Invariant properties of false:
    try testing.expectEqual(@as(u8, 1), result); // Always returns 1
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len); // Never writes to stdout
    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len); // Never writes to stderr
}
