//! Streamlined fuzz tests for echo utility
//!
//! Echo outputs text with optional escape sequence processing.
//! These tests verify it handles various inputs and escape sequences gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const echo_util = @import("echo.zig");

test "echo fuzz basic" {
    try std.testing.fuzz(testing.allocator, testEchoBasic, .{});
}

fn testEchoBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(echo_util.runUtility, allocator, input);
}

test "echo fuzz escape sequences" {
    try std.testing.fuzz(testing.allocator, testEchoEscapeSequences, .{});
}

fn testEchoEscapeSequences(allocator: std.mem.Allocator, input: []const u8) !void {
    const escape_seq = try common.fuzz.generateEscapeSequence(allocator, input);
    defer allocator.free(escape_seq);

    const args = [_][]const u8{ "-e", escape_seq };
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = echo_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable in fuzz testing
        return;
    };
}

test "echo fuzz paths" {
    try std.testing.fuzz(testing.allocator, testEchoPaths, .{});
}

fn testEchoPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityPaths(echo_util.runUtility, allocator, input);
}

test "echo fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testEchoDeterministic, .{});
}

fn testEchoDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(echo_util.runUtility, allocator, input);
}

test "echo fuzz flag combinations" {
    try std.testing.fuzz(testing.allocator, testEchoFlagCombinations, .{});
}

fn testEchoFlagCombinations(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate different flag combinations
    const flag_combinations = [_][]const []const u8{
        &.{"-n"},
        &.{"-e"},
        &.{"-E"},
        &.{ "-n", "-e" },
        &.{ "-n", "-E" },
        &.{ "-e", "-E" },
        &.{ "-n", "-e", "-E" },
    };

    const flags = flag_combinations[input[0] % flag_combinations.len];
    const text = if (input.len > 1) input[1..] else "test";

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    for (flags) |flag| {
        try args.append(flag);
    }
    try args.append(text);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = echo_util.runUtility(allocator, args.items, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable
        return;
    };
}
