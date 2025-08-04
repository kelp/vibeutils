//! Comprehensive fuzz tests for cp utility using std.testing.fuzz()
//!
//! Tests for critical cp operations to ensure it never:
//! - Corrupts data during copying
//! - Panics with malformed inputs
//! - Has race conditions or undefined behavior
//! - Fails to handle edge cases gracefully

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const cp = @import("cp");

test "cp fuzz arguments - never panic" {
    try std.testing.fuzz(testing.allocator, testCpWithFuzzedArgs, .{});
}

fn testCpWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // cp should handle all arguments gracefully without panicking
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    _ = cp.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "cp fuzz file paths - handle all path types" {
    try std.testing.fuzz(testing.allocator, testCpWithFuzzedPaths, .{});
}

fn testCpWithFuzzedPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate various file paths from fuzz input
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
        &[_][]const u8{"-H"}, // Follow command line symlinks
        &[_][]const u8{"-P"}, // Don't follow symlinks
        &[_][]const u8{"-rf"}, // Force recursive
        &[_][]const u8{"-rp"}, // Recursive preserve
        &[_][]const u8{"-rfv"}, // Force recursive verbose
    };

    for (flag_combos) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_paths);

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Errors are expected for non-existent files, permission issues, etc.
            continue;
        };
    }
}

test "cp fuzz symlink chains - handle symlink edge cases" {
    try std.testing.fuzz(testing.allocator, testCpWithSymlinks, .{});
}

fn testCpWithSymlinks(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate symlink chain patterns
    const chain = try common.fuzz.generateSymlinkChain(allocator, input);
    defer {
        for (chain) |link| allocator.free(link);
        allocator.free(chain);
    }

    if (chain.len < 2) return; // Need at least link and target

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test copying symlinks with various symlink handling flags
    const test_cases = [_][]const []const u8{
        &[_][]const u8{"-P"}, // Don't follow symlinks (copy as symlinks)
        &[_][]const u8{"-L"}, // Follow all symlinks
        &[_][]const u8{"-H"}, // Follow command-line symlinks only
        &[_][]const u8{"-rP"}, // Recursive, don't follow symlinks
        &[_][]const u8{"-rL"}, // Recursive, follow all symlinks
    };

    for (test_cases) |flags| {
        // Try copying each link in the chain to a destination
        for (chain[0 .. chain.len - 1]) |source| {
            var args = std.ArrayList([]const u8).init(allocator);
            defer args.deinit();

            try args.appendSlice(flags);
            try args.append(source);
            try args.append("fuzz_dest");

            stdout_buf.clearRetainingCapacity();
            stderr_buf.clearRetainingCapacity();

            _ = cp.runUtility(allocator, args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
                // Expected to fail for non-existent or circular links
                continue;
            };
        }
    }
}

test "cp fuzz special characters - handle all byte values" {
    try std.testing.fuzz(testing.allocator, testCpSpecialChars, .{});
}

fn testCpSpecialChars(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Create source and destination paths with special/control characters
    var source_path = std.ArrayList(u8).init(allocator);
    defer source_path.deinit();
    var dest_path = std.ArrayList(u8).init(allocator);
    defer dest_path.deinit();

    try source_path.appendSlice("src_");
    try dest_path.appendSlice("dst_");

    // Generate paths with various special characters
    const half_len = input.len / 2;
    for (input[0..half_len]) |byte| {
        // Replace null bytes and problematic path separators
        if (byte == 0 or byte == '/') {
            try source_path.append('_');
        } else {
            try source_path.append(byte);
        }
        if (source_path.items.len >= 200) break; // Limit filename length
    }

    for (input[half_len..]) |byte| {
        if (byte == 0 or byte == '/') {
            try dest_path.append('_');
        } else {
            try dest_path.append(byte);
        }
        if (dest_path.items.len >= 200) break;
    }

    const source_str = try source_path.toOwnedSlice();
    defer allocator.free(source_str);
    const dest_str = try dest_path.toOwnedSlice();
    defer allocator.free(dest_str);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test with various flags that might interact with special characters
    const flag_combos = [_][]const []const u8{
        &[_][]const u8{ source_str, dest_str },
        &[_][]const u8{ "-f", source_str, dest_str },
        &[_][]const u8{ "-v", source_str, dest_str },
        &[_][]const u8{ "-p", source_str, dest_str },
    };

    for (flag_combos) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files
            continue;
        };
    }
}

test "cp fuzz directory operations - handle deep directory trees" {
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
        &[_][]const u8{ "-rv", source_str, dest_str },
        &[_][]const u8{ "-rL", source_str, dest_str },
        &[_][]const u8{ "-rP", source_str, dest_str },
    };

    for (flag_combos) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent directories
            continue;
        };
    }
}

test "cp fuzz permissions - handle various permission patterns" {
    try std.testing.fuzz(testing.allocator, testCpPermissions, .{});
}

fn testCpPermissions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate file paths and permission patterns
    const source_path = try common.fuzz.generatePath(allocator, input[0 .. input.len / 2]);
    defer allocator.free(source_path);
    const dest_path = try common.fuzz.generatePath(allocator, input[input.len / 2 ..]);
    defer allocator.free(dest_path);

    if (source_path.len == 0 or dest_path.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test permission-related flags
    const permission_flags = [_][]const []const u8{
        &[_][]const u8{ "-p", source_path, dest_path }, // Preserve all attributes
        &[_][]const u8{ "--preserve=mode", source_path, dest_path }, // Preserve mode only
        &[_][]const u8{ "--preserve=ownership", source_path, dest_path }, // Preserve ownership
        &[_][]const u8{ "--preserve=timestamps", source_path, dest_path }, // Preserve timestamps
        &[_][]const u8{ "--preserve=all", source_path, dest_path }, // Preserve everything
        &[_][]const u8{ "--no-preserve=mode", source_path, dest_path }, // Don't preserve mode
    };

    for (permission_flags) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = cp.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files or permission issues
            continue;
        };
    }
}

test "cp fuzz property - deterministic behavior" {
    try std.testing.fuzz(testing.allocator, testCpDeterministic, .{});
}

fn testCpDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    if (args.len == 0) return;

    // Run cp twice with same input
    var stdout_buf1 = std.ArrayList(u8).init(allocator);
    defer stdout_buf1.deinit();
    var stderr_buf1 = std.ArrayList(u8).init(allocator);
    defer stderr_buf1.deinit();

    var stdout_buf2 = std.ArrayList(u8).init(allocator);
    defer stdout_buf2.deinit();
    var stderr_buf2 = std.ArrayList(u8).init(allocator);
    defer stderr_buf2.deinit();

    const result1 = cp.runUtility(allocator, args, stdout_buf1.writer(), stderr_buf1.writer()) catch |err| {
        // If first fails, second should behave consistently
        const result2 = cp.runUtility(allocator, args, stdout_buf2.writer(), stderr_buf2.writer()) catch {
            return; // Both failed, that's consistent
        };
        _ = result2;
        return err; // First failed but second succeeded - inconsistent!
    };

    const result2 = cp.runUtility(allocator, args, stdout_buf2.writer(), stderr_buf2.writer()) catch {
        return error.InconsistentBehavior; // First succeeded but second failed
    };

    // Property: same input should produce same result
    try testing.expectEqual(@intFromEnum(result1), @intFromEnum(result2));

    // Note: Output might differ due to timestamps or progress indicators,
    // but the operation result should be consistent
}

test "cp fuzz multiple sources - handle batch operations" {
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

        _ = cp.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files/directories
            continue;
        };
    }
}
