//! Streamlined fuzz tests for rm utility
//!
//! Rm removes files and directories with various flag combinations.
//! Tests verify the utility handles removal scenarios without panicking.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const rm_util = @import("rm.zig");

// Create standardized fuzz tests using the unified builder
const RmFuzzTests = common.fuzz.createUtilityFuzzTests(rm_util.runUtility);

test "rm fuzz basic" {
    try std.testing.fuzz(testing.allocator, RmFuzzTests.testBasic, .{});
}

test "rm fuzz paths" {
    try std.testing.fuzz(testing.allocator, RmFuzzTests.testPaths, .{});
}

test "rm fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, RmFuzzTests.testDeterministic, .{});
}

test "rm fuzz flag combinations" {
    try std.testing.fuzz(testing.allocator, testRmFlagCombinations, .{});
}

fn testRmFlagCombinations(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate file paths from fuzz input
    const paths = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    if (paths.len == 0) return;

    // Convert to const for rm function
    var const_paths = try allocator.alloc([]const u8, paths.len);
    defer allocator.free(const_paths);
    for (paths, 0..) |path, i| {
        const_paths[i] = path;
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test various flag combinations with the paths
    const flag_combos = [_][]const []const u8{
        &[_][]const u8{}, // No flags
        &[_][]const u8{"-f"}, // Force
        &[_][]const u8{"-r"}, // Recursive
        &[_][]const u8{"-v"}, // Verbose
        &[_][]const u8{"-i"}, // Interactive
        &[_][]const u8{"-rf"}, // Force recursive
        &[_][]const u8{"-rv"}, // Recursive verbose
        &[_][]const u8{"-d"}, // Remove empty directories
    };

    for (flag_combos) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_paths);

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rm_util.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Errors are expected for non-existent files, permission issues, etc.
            continue;
        };
    }
}

test "rm fuzz directory operations" {
    try std.testing.fuzz(testing.allocator, testRmDirectoryOps, .{});
}

fn testRmDirectoryOps(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate directory paths from fuzz input
    const dirs = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (dirs) |dir| allocator.free(dir);
        allocator.free(dirs);
    }

    if (dirs.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test recursive directory removal flags
    const test_cases = [_][]const []const u8{
        &[_][]const u8{"-r"},
        &[_][]const u8{"-rf"},
        &[_][]const u8{"-rv"},
        &[_][]const u8{"--recursive"},
        &[_][]const u8{ "--recursive", "--force" },
    };

    for (test_cases) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        for (dirs) |dir| {
            try all_args.append(dir);
        }

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rm_util.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent directories
            continue;
        };
    }
}
