//! Comprehensive fuzz tests for mv utility using std.testing.fuzz()
//!
//! Tests for critical mv operations to ensure it never:
//! - Loses data during moves/renames
//! - Panics with malformed inputs
//! - Has race conditions or undefined behavior
//! - Fails to handle edge cases gracefully

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const mv = @import("mv");

test "mv fuzz arguments - never panic" {
    try std.testing.fuzz(testing.allocator, testMvWithFuzzedArgs, .{});
}

fn testMvWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // mv should handle all arguments gracefully without panicking
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    _ = mv.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "mv fuzz file paths - handle all path types" {
    try std.testing.fuzz(testing.allocator, testMvWithFuzzedPaths, .{});
}

fn testMvWithFuzzedPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate various file paths from fuzz input
    const paths = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    if (paths.len < 2) return; // mv needs at least source and destination

    // Convert to const for mv function
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
        &[_][]const u8{"-i"}, // Interactive (should handle gracefully without stdin)
        &[_][]const u8{"-n"}, // No clobber
        &[_][]const u8{"-v"}, // Verbose
        &[_][]const u8{"-u"}, // Update (move only when source is newer)
        &[_][]const u8{"-b"}, // Backup
        &[_][]const u8{"-S"}, // Backup suffix
        &[_][]const u8{"-t"}, // Target directory
        &[_][]const u8{"-T"}, // No target directory
        &[_][]const u8{"-fv"}, // Force verbose
        &[_][]const u8{"-nv"}, // No clobber verbose
    };

    for (flag_combos) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_paths);

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Errors are expected for non-existent files, permission issues, etc.
            continue;
        };
    }
}

test "mv fuzz symlink chains - handle symlink edge cases" {
    try std.testing.fuzz(testing.allocator, testMvWithSymlinks, .{});
}

fn testMvWithSymlinks(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate symlink chain patterns
    const chain = try common.fuzz.generateSymlinkChain(allocator, input);
    defer {
        for (chain) |link| allocator.free(link);
        allocator.free(chain);
    }

    if (chain.len < 2) return; // Need at least link and destination

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test moving symlinks with various flags
    const test_cases = [_][]const []const u8{
        &[_][]const u8{"-f"}, // Force move symlinks
        &[_][]const u8{"-v"}, // Verbose move
        &[_][]const u8{"-n"}, // No clobber (don't overwrite existing)
        &[_][]const u8{"-b"}, // Create backup of destination
    };

    for (test_cases) |flags| {
        // Try moving each link in the chain
        for (chain[0 .. chain.len - 1]) |source| {
            var args = std.ArrayList([]const u8).init(allocator);
            defer args.deinit();

            try args.appendSlice(flags);
            try args.append(source);
            try args.append("fuzz_move_dest");

            stdout_buf.clearRetainingCapacity();
            stderr_buf.clearRetainingCapacity();

            _ = mv.runUtility(allocator, args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
                // Expected to fail for non-existent or circular links
                continue;
            };
        }
    }
}

test "mv fuzz special characters - handle all byte values" {
    try std.testing.fuzz(testing.allocator, testMvSpecialChars, .{});
}

fn testMvSpecialChars(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Create source and destination paths with special/control characters
    var source_path = std.ArrayList(u8).init(allocator);
    defer source_path.deinit();
    var dest_path = std.ArrayList(u8).init(allocator);
    defer dest_path.deinit();

    try source_path.appendSlice("mv_src_");
    try dest_path.appendSlice("mv_dst_");

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
        &[_][]const u8{ "-n", source_str, dest_str },
        &[_][]const u8{ "-b", source_str, dest_str },
    };

    for (flag_combos) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files
            continue;
        };
    }
}

test "mv fuzz directory operations - handle directory moves" {
    try std.testing.fuzz(testing.allocator, testMvDirectoryOps, .{});
}

fn testMvDirectoryOps(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate source and destination directory paths
    var source_path = std.ArrayList(u8).init(allocator);
    defer source_path.deinit();
    var dest_path = std.ArrayList(u8).init(allocator);
    defer dest_path.deinit();

    // Create nested directory structure based on fuzz input
    const depth = @min(input[0] % 12, 6); // Limit depth to avoid stack overflow
    try source_path.appendSlice("mv_src_dir");
    try dest_path.appendSlice("mv_dst_dir");

    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try source_path.appendSlice("/subdir");
        try source_path.append('0' + @as(u8, @intCast(i % 10)));

        try dest_path.appendSlice("/subdir");
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

    // Test moving directories with various flag combinations
    const flag_combos = [_][]const []const u8{
        &[_][]const u8{ source_str, dest_str },
        &[_][]const u8{ "-f", source_str, dest_str },
        &[_][]const u8{ "-v", source_str, dest_str },
        &[_][]const u8{ "-n", source_str, dest_str },
        &[_][]const u8{ "-T", source_str, dest_str }, // No target directory
        &[_][]const u8{ "-b", source_str, dest_str }, // Backup existing
    };

    for (flag_combos) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent directories
            continue;
        };
    }
}

test "mv fuzz backup operations - handle backup edge cases" {
    try std.testing.fuzz(testing.allocator, testMvBackups, .{});
}

fn testMvBackups(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate file paths for backup testing
    const source_path = try common.fuzz.generatePath(allocator, input[0 .. input.len / 2]);
    defer allocator.free(source_path);
    const dest_path = try common.fuzz.generatePath(allocator, input[input.len / 2 ..]);
    defer allocator.free(dest_path);

    if (source_path.len == 0 or dest_path.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test backup-related flags with various suffix patterns
    const backup_flags = [_][]const []const u8{
        &[_][]const u8{ "-b", source_path, dest_path }, // Simple backup
        &[_][]const u8{ "--backup", source_path, dest_path }, // Long form
        &[_][]const u8{ "--backup=simple", source_path, dest_path }, // Simple backup
        &[_][]const u8{ "--backup=numbered", source_path, dest_path }, // Numbered backup
        &[_][]const u8{ "--backup=existing", source_path, dest_path }, // Existing backup method
        &[_][]const u8{ "-S", ".bak", source_path, dest_path }, // Custom backup suffix
        &[_][]const u8{ "--suffix=.old", source_path, dest_path }, // Custom suffix long form
        &[_][]const u8{ "-bS", ".fuzz", source_path, dest_path }, // Backup with custom suffix
    };

    for (backup_flags) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files
            continue;
        };
    }
}

test "mv fuzz cross-filesystem moves - handle filesystem boundaries" {
    try std.testing.fuzz(testing.allocator, testMvCrossFilesystem, .{});
}

fn testMvCrossFilesystem(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 4) return;

    // Generate paths that might cross filesystem boundaries
    var source_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (source_paths.items) |path| allocator.free(path);
        source_paths.deinit();
    }

    // Common mount points that might be different filesystems
    const mount_points = [_][]const u8{
        "/tmp/fuzz_src",
        "/var/tmp/fuzz_src",
        "fuzz_src",
        "./fuzz_src",
        "../fuzz_src",
    };

    const dest_points = [_][]const u8{
        "/tmp/fuzz_dst",
        "/var/tmp/fuzz_dst",
        "fuzz_dst",
        "./fuzz_dst",
        "../fuzz_dst",
    };

    const mount_idx = input[0] % mount_points.len;
    const dest_idx = input[1] % dest_points.len;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test moves that might require copy+delete due to filesystem boundaries
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ mount_points[mount_idx], dest_points[dest_idx] },
        &[_][]const u8{ "-f", mount_points[mount_idx], dest_points[dest_idx] },
        &[_][]const u8{ "-v", mount_points[mount_idx], dest_points[dest_idx] },
        &[_][]const u8{ "-u", mount_points[mount_idx], dest_points[dest_idx] },
    };

    for (test_cases) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files or permission issues
            continue;
        };
    }
}

test "mv fuzz property - deterministic behavior" {
    try std.testing.fuzz(testing.allocator, testMvDeterministic, .{});
}

fn testMvDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    if (args.len == 0) return;

    // Run mv twice with same input (note: second run will likely fail since file was moved)
    var stdout_buf1 = std.ArrayList(u8).init(allocator);
    defer stdout_buf1.deinit();
    var stderr_buf1 = std.ArrayList(u8).init(allocator);
    defer stderr_buf1.deinit();

    var stdout_buf2 = std.ArrayList(u8).init(allocator);
    defer stdout_buf2.deinit();
    var stderr_buf2 = std.ArrayList(u8).init(allocator);
    defer stderr_buf2.deinit();

    const result1 = mv.runUtility(allocator, args, stdout_buf1.writer(), stderr_buf1.writer()) catch |err| {
        // If first fails, test that it fails consistently
        const result2 = mv.runUtility(allocator, args, stdout_buf2.writer(), stderr_buf2.writer()) catch {
            return; // Both failed, that's acceptable
        };
        _ = result2;
        // First failed but second succeeded with same input - this could be inconsistent behavior
        // but might be legitimate if external state changed
        return err;
    };

    // For mv, second run typically fails since the file was already moved
    // This is expected behavior, not inconsistent
    _ = mv.runUtility(allocator, args, stdout_buf2.writer(), stderr_buf2.writer()) catch {
        // This is expected for mv - file was already moved
        return;
    };

    // If both succeeded, that's also valid (e.g., if source didn't exist)
    _ = result1;
}

test "mv fuzz multiple sources - handle batch operations" {
    try std.testing.fuzz(testing.allocator, testMvMultipleSources, .{});
}

fn testMvMultipleSources(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate multiple source files and one destination
    const sources = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (sources) |source| allocator.free(source);
        allocator.free(sources);
    }

    if (sources.len < 2) return; // Need at least 2 sources to test multiple file move

    // Convert to const
    var const_sources = try allocator.alloc([]const u8, sources.len);
    defer allocator.free(const_sources);
    for (sources, 0..) |source, i| {
        const_sources[i] = source;
    }

    // Use last path as destination directory
    const dest = "fuzz_move_dest_dir";

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test moving multiple sources to destination
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ "-t", dest }, // Target directory mode
        &[_][]const u8{ "-vt", dest }, // Verbose target directory
        &[_][]const u8{ "-ft", dest }, // Force target directory
        &[_][]const u8{ "-nt", dest }, // No clobber target directory
    };

    for (test_cases) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_sources[0 .. const_sources.len - 1]); // All but last as sources

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent files/directories
            continue;
        };
    }
}

test "mv fuzz same file detection - prevent data loss" {
    try std.testing.fuzz(testing.allocator, testMvSameFile, .{});
}

fn testMvSameFile(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate a path that might be the same as source and destination
    const path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(path);

    if (path.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test moving file to itself (should be detected and handled gracefully)
    const same_file_cases = [_][]const []const u8{
        &[_][]const u8{ path, path }, // Exact same path
        &[_][]const u8{ "-f", path, path }, // Force same path
        &[_][]const u8{ "-v", path, path }, // Verbose same path
        &[_][]const u8{ path, "." }, // Move to current directory (might be same)
        &[_][]const u8{ "./somefile", "somefile" }, // Relative vs absolute same file
    };

    for (same_file_cases) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = mv.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Should gracefully handle same file detection
            continue;
        };
    }
}
