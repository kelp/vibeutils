//! Streamlined fuzz tests for pwd utility
//!
//! Pwd prints the current working directory. It should handle flags gracefully
//! and always produce the same output.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const pwd_util = @import("pwd.zig");

// Create standardized fuzz tests using the unified builder
const PwdFuzzTests = common.fuzz.createUtilityFuzzTests(pwd_util.runUtility);

test "pwd fuzz basic" {
    try std.testing.fuzz(testing.allocator, PwdFuzzTests.testBasic, .{});
}

test "pwd fuzz paths" {
    try std.testing.fuzz(testing.allocator, PwdFuzzTests.testPaths, .{});
}

test "pwd fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, PwdFuzzTests.testDeterministic, .{});
}
