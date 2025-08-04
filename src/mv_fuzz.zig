//! Streamlined fuzz tests for mv utility
//!
//! Mv moves/renames files and directories with various flag combinations.
//! Tests verify the utility handles move scenarios without panicking.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const mv_util = @import("mv");

// Create standardized fuzz tests using the unified builder
const MvFuzzTests = common.fuzz.createUtilityFuzzTests(mv_util.runUtility);

test "mv fuzz basic" {
    try std.testing.fuzz(testing.allocator, MvFuzzTests.testBasic, .{});
}

test "mv fuzz paths" {
    try std.testing.fuzz(testing.allocator, MvFuzzTests.testPaths, .{});
}

test "mv fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, MvFuzzTests.testDeterministic, .{});
}

test "mv fuzz flag combinations" {
    try std.testing.fuzz(testing.allocator, testMvFlagCombinations, .{});
}

fn testMvFlagCombinations(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Split input for source and destination
    const mid = input.len / 2;
    const source_path = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(source_path);

    const dest_path = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(dest_path);

    // Test various flag combinations
    const flag_combos = [_][]const []const u8{
        &[_][]const u8{}, // No flags
        &[_][]const u8{"-f"}, // Force
        &[_][]const u8{"-i"}, // Interactive
        &[_][]const u8{"-n"}, // No clobber
        &[_][]const u8{"-v"}, // Verbose
        &[_][]const u8{"-fv"}, // Force verbose
        &[_][]const u8{"--backup"}, // Backup
    };

    for (flag_combos) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.append(source_path);
        try all_args.append(dest_path);

        var stdout_buf = std.ArrayList(u8).init(allocator);
        defer stdout_buf.deinit();
        var stderr_buf = std.ArrayList(u8).init(allocator);
        defer stderr_buf.deinit();

        _ = mv_util.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Errors are expected for non-existent files, permission issues, etc.
            continue;
        };
    }
}

test "mv fuzz multiple sources" {
    try std.testing.fuzz(testing.allocator, testMvMultipleSources, .{});
}

fn testMvMultipleSources(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate multiple source files and one destination
    const sources = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (sources) |source| allocator.free(source);
        allocator.free(sources);
    }

    if (sources.len < 2) return; // Need at least 2 paths to test multiple file move

    // Convert to const
    var const_sources = try allocator.alloc([]const u8, sources.len);
    defer allocator.free(const_sources);
    for (sources, 0..) |source, i| {
        const_sources[i] = source;
    }

    // Use last path as destination directory
    const dest = "fuzz_dest_dir";

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test moving multiple sources to destination
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ "-t", dest }, // Target directory mode
        &[_][]const u8{ "-vt", dest }, // Verbose target directory
    };

    for (test_cases) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_sources[0 .. const_sources.len - 1]); // All but last as sources

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv_util.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files/directories
            continue;
        };
    }
}
