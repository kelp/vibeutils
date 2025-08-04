//! Streamlined fuzz tests for rm utility
//!
//! Rm removes files and directories with various options.
//! These tests verify it handles complex scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const rm_util = @import("rm.zig");

test "rm fuzz basic" {
    try std.testing.fuzz(testing.allocator, testRmBasic, .{});
}

fn testRmBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(rm_util.runUtility, allocator, input);
}

test "rm fuzz paths" {
    try std.testing.fuzz(testing.allocator, testRmPaths, .{});
}

fn testRmPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityPaths(rm_util.runUtility, allocator, input);
}

test "rm fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, testRmDeterministic, .{});
}

fn testRmDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityDeterministic(rm_util.runUtility, allocator, input);
}

test "rm fuzz file lists" {
    try std.testing.fuzz(testing.allocator, testRmFileLists, .{});
}

fn testRmFileLists(allocator: std.mem.Allocator, input: []const u8) !void {
    const files = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = rm_util.runUtility(allocator, files, stdout_buf.writer(), common.null_writer) catch {
        // File not found and permission errors are expected
        return;
    };
}

test "rm fuzz flag combinations" {
    try std.testing.fuzz(testing.allocator, testRmFlags, .{});
}

fn testRmFlags(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Test different flag combinations
    const flag_combinations = [_][]const []const u8{
        &.{"-f"},
        &.{"-r"},
        &.{"-v"},
        &.{ "-f", "-r" },
        &.{ "-f", "-v" },
        &.{ "-r", "-v" },
        &.{ "-f", "-r", "-v" },
    };

    const flags = flag_combinations[input[0] % flag_combinations.len];
    const test_file = "/tmp/nonexistent_file";

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    for (flags) |flag| {
        try args.append(flag);
    }
    try args.append(test_file);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = rm_util.runUtility(allocator, args.items, stdout_buf.writer(), common.null_writer) catch {
        // File not found is expected for nonexistent files
        return;
    };
}

test "rm fuzz symlinks" {
    try std.testing.fuzz(testing.allocator, testRmSymlinks, .{});
}

fn testRmSymlinks(allocator: std.mem.Allocator, input: []const u8) !void {
    const symlink_chain = try common.fuzz.generateSymlinkChain(allocator, input);
    defer {
        for (symlink_chain) |link| allocator.free(link);
        allocator.free(symlink_chain);
    }

    if (symlink_chain.len == 0) return;

    // Try to remove the first link in the chain
    const args = [_][]const u8{symlink_chain[0]};

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = rm_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Symlink errors are expected
        return;
    };
}
