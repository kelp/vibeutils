//! Streamlined fuzz tests for dirname utility
//!
//! Dirname extracts the directory portion from pathnames.
//! It should handle various path formats gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const dirname_util = @import("dirname.zig");

// Create standardized fuzz tests using the unified builder
const DirnameFuzzTests = common.fuzz.createUtilityFuzzTests(dirname_util.runUtility);

test "dirname fuzz basic" {
    try std.testing.fuzz(testing.allocator, DirnameFuzzTests.testBasic, .{});
}

test "dirname fuzz paths" {
    try std.testing.fuzz(testing.allocator, DirnameFuzzTests.testPaths, .{});
}

test "dirname fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, DirnameFuzzTests.testDeterministic, .{});
}
