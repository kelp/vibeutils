//! Streamlined fuzz tests for cp utility
//!
//! Cp copies files and directories with various flag combinations.
//! Tests verify the utility handles complex copy scenarios without panicking.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const cp_util = @import("cp");

// Create standardized fuzz tests using the unified builder
const CpFuzzTests = common.fuzz.createUtilityFuzzTests(cp_util.runUtility);

test "cp fuzz basic" {
    try std.testing.fuzz(testing.allocator, CpFuzzTests.testBasic, .{});
}

test "cp fuzz paths" {
    try std.testing.fuzz(testing.allocator, CpFuzzTests.testPaths, .{});
}

test "cp fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, CpFuzzTests.testDeterministic, .{});
}

test "cp fuzz flag combinations" {
    try std.testing.fuzz(testing.allocator, testCpFlagCombinations, .{});
}

fn testCpFlagCombinations(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate file paths from fuzz input
    const paths = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    if (paths.len < 2) return; // cp needs at least source and destination

    // Convert to const for cp function
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
        &[_][]const u8{"-p"}, // Preserve attributes
        &[_][]const u8{"-v"}, // Verbose
        &[_][]const u8{"-n"}, // No clobber
        &[_][]const u8{"-L"}, // Follow symlinks
        &[_][]const u8{"-P"}, // Don't follow symlinks
        &[_][]const u8{"-rf"}, // Force recursive
        &[_][]const u8{"-rp"}, // Recursive preserve
    };

    for (flag_combos) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_paths);

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp_util.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Errors are expected for non-existent files, permission issues, etc.
            continue;
        };
    }
}

test "cp fuzz directory operations" {
    try std.testing.fuzz(testing.allocator, testCpDirectoryOps, .{});
}

fn testCpDirectoryOps(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate source and destination directory paths
    var source_path = std.ArrayList(u8).init(allocator);
    defer source_path.deinit();
    var dest_path = std.ArrayList(u8).init(allocator);
    defer dest_path.deinit();

    // Create nested directory structure based on fuzz input
    const depth = @min(input[0] % 15, 8); // Limit depth to avoid stack overflow
    try source_path.appendSlice("fuzz_src");
    try dest_path.appendSlice("fuzz_dst");

    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try source_path.appendSlice("/dir");
        try source_path.append('0' + @as(u8, @intCast(i % 10)));

        try dest_path.appendSlice("/dir");
        try dest_path.append('0' + @as(u8, @intCast((i + 1) % 10)));
    }

    const source_str = try source_path.toOwnedSlice();
    defer allocator.free(source_str);
    const dest_str = try dest_path.toOwnedSlice();
    defer allocator.free(dest_str);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test recursive copying with various flag combinations
    const flag_combos = [_][]const []const u8{
        &[_][]const u8{ "-r", source_str, dest_str },
        &[_][]const u8{ "-rf", source_str, dest_str },
        &[_][]const u8{ "-rp", source_str, dest_str },
        &[_][]const u8{ "-rL", source_str, dest_str },
        &[_][]const u8{ "-rP", source_str, dest_str },
    };

    for (flag_combos) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp_util.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent directories
            continue;
        };
    }
}

test "cp fuzz multiple sources" {
    try std.testing.fuzz(testing.allocator, testCpMultipleSources, .{});
}

fn testCpMultipleSources(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate multiple source files and one destination
    const sources = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (sources) |source| allocator.free(source);
        allocator.free(sources);
    }

    if (sources.len < 2) return; // Need at least 2 sources to test multiple file copy

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

    // Test copying multiple sources to destination
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ "-t", dest }, // Target directory mode
        &[_][]const u8{ "-rt", dest }, // Recursive target directory
        &[_][]const u8{ "-vt", dest }, // Verbose target directory
    };

    for (test_cases) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_sources[0 .. const_sources.len - 1]); // All but last as sources

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp_util.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files/directories
            continue;
        };
    }
}
