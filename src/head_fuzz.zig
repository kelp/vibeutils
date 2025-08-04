//! Streamlined fuzz tests for head utility
//!
//! Head outputs the first part of files with line/byte count options.
//! Tests verify the utility handles various inputs and edge cases gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const head_util = @import("head.zig");

// Create standardized fuzz tests using the unified builder
const HeadFuzzTests = common.fuzz.createUtilityFuzzTests(head_util.runUtility);

test "head fuzz basic" {
    try std.testing.fuzz(testing.allocator, HeadFuzzTests.testBasic, .{});
}

test "head fuzz paths" {
    try std.testing.fuzz(testing.allocator, HeadFuzzTests.testPaths, .{});
}

test "head fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, HeadFuzzTests.testDeterministic, .{});
}

test "head fuzz line/byte counts" {
    try std.testing.fuzz(testing.allocator, testHeadCounts, .{});
}

fn testHeadCounts(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate different count combinations
    const count_flags = [_][]const []const u8{
        &.{ "-n", "5" },
        &.{ "-c", "10" },
        &.{ "-n", "0" },
        &.{ "-c", "0" },
        &.{ "--lines", "100" },
        &.{ "--bytes", "50" },
    };

    const flags = count_flags[input[0] % count_flags.len];

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    for (flags) |flag| {
        try args.append(flag);
    }

    // Add a test file path if there's remaining input
    if (input.len > 1) {
        const path = try common.fuzz.generatePath(allocator, input[1..]);
        defer allocator.free(path);
        try args.append(path);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = head_util.runUtility(allocator, args.items, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable in fuzz testing
        return;
    };
}

test "head fuzz header options" {
    try std.testing.fuzz(testing.allocator, testHeadHeaders, .{});
}

fn testHeadHeaders(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate different header flag combinations
    const header_flags = [_][]const []const u8{
        &.{"-q"},
        &.{"-v"},
        &.{"--quiet"},
        &.{"--verbose"},
        &.{ "-q", "-n", "3" },
        &.{ "-v", "-c", "20" },
    };

    const flags = header_flags[input[0] % header_flags.len];

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    for (flags) |flag| {
        try args.append(flag);
    }

    // Add multiple files to test header behavior
    if (input.len > 1) {
        const files = try common.fuzz.generateFileList(allocator, input[1..]);
        defer {
            for (files) |file| allocator.free(file);
            allocator.free(files);
        }

        for (files) |file| {
            try args.append(file);
        }
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = head_util.runUtility(allocator, args.items, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable
        return;
    };
}
