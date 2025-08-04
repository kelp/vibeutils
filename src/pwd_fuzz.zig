//! Streamlined fuzz tests for pwd utility
//!
//! Pwd prints the current working directory. It should handle flags gracefully
//! and always produce the same output.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const pwd_util = @import("pwd.zig");

test "pwd fuzz basic" {
    try std.testing.fuzz(testing.allocator, testPwdBasic, .{});
}

fn testPwdBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(pwd_util.runUtility, allocator, input);
}

test "pwd fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testPwdDeterministic, .{});
}

fn testPwdDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(pwd_util.runUtility, allocator, input);
}
