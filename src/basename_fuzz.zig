//! Fuzz tests for basename utility using unified pattern
//!
//! Basename extracts the final component from pathnames.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const basename = @import("basename.zig");

// Generate standard fuzz tests using unified builder
const fuzz_tests = common.fuzz.createUtilityFuzzTests(basename.runUtility, .{
    .test_basic = true,
    .test_paths = true,
    .test_deterministic = true,
});

test "basename fuzz basic" {
    try std.testing.fuzz(testing.allocator, fuzz_tests.testBasic, .{});
}

test "basename fuzz paths" {
    try std.testing.fuzz(testing.allocator, fuzz_tests.testPaths, .{});
}

test "basename fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, fuzz_tests.testDeterministic, .{});
}
