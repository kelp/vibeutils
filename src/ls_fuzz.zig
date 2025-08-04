//! Streamlined fuzz tests for ls utility
//!
//! Ls lists directory contents with various formatting and filtering options.
//! Tests verify the utility handles various inputs and edge cases gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const ls_util = @import("ls/main.zig");

// Create standardized fuzz tests using the unified builder
const LsFuzzTests = common.fuzz.createUtilityFuzzTests(ls_util.runUtility);

test "ls fuzz basic" {
    try std.testing.fuzz(testing.allocator, LsFuzzTests.testBasic, .{});
}

test "ls fuzz paths" {
    try std.testing.fuzz(testing.allocator, LsFuzzTests.testPaths, .{});
}

test "ls fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, LsFuzzTests.testDeterministic, .{});
}

test "ls fuzz format options" {
    try std.testing.fuzz(testing.allocator, testLsFormatOptions, .{});
}

fn testLsFormatOptions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate different format flag combinations
    const format_flags = [_][]const []const u8{
        &.{"-l"}, // Long format
        &.{"-1"}, // One per line
        &.{"-a"}, // All files
        &.{"-A"}, // Almost all
        &.{"-d"}, // Directory entries
        &.{"-F"}, // Classify
        &.{"-h"}, // Human readable
        &.{"-la"}, // Long format + all files
        &.{"-lh"}, // Long + human readable
        &.{"--color=auto"}, // Color output
    };

    const flags = format_flags[input[0] % format_flags.len];

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    for (flags) |flag| {
        try args.append(flag);
    }

    // Add a test path if there's remaining input
    if (input.len > 1) {
        const path = try common.fuzz.generatePath(allocator, input[1..]);
        defer allocator.free(path);
        try args.append(path);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ls_util.runUtility(allocator, args.items, stdout_buf.writer(), common.null_writer) catch {
        // Path errors and permission issues are expected
        return;
    };
}

test "ls fuzz sort options" {
    try std.testing.fuzz(testing.allocator, testLsSortOptions, .{});
}

fn testLsSortOptions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate different sort flag combinations
    const sort_flags = [_][]const []const u8{
        &.{"-t"}, // Sort by time
        &.{"-S"}, // Sort by size
        &.{"-X"}, // Sort by extension
        &.{"-r"}, // Reverse
        &.{"-rt"}, // Reverse time
        &.{"-rS"}, // Reverse size
        &.{"--sort=time"},
        &.{"--sort=size"},
    };

    const flags = sort_flags[input[0] % sort_flags.len];

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    for (flags) |flag| {
        try args.append(flag);
    }

    // Add a test path if there's remaining input
    if (input.len > 1) {
        const path = try common.fuzz.generatePath(allocator, input[1..]);
        defer allocator.free(path);
        try args.append(path);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ls_util.runUtility(allocator, args.items, stdout_buf.writer(), common.null_writer) catch {
        // Errors are expected for non-existent paths
        return;
    };
}
