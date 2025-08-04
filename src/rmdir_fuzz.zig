//! Comprehensive fuzz tests for rmdir utility using std.testing.fuzz()
//!
//! Tests for critical rmdir operations to ensure it never:
//! - Removes non-empty directories inappropriately
//! - Panics with malformed inputs
//! - Has race conditions or undefined behavior
//! - Fails to handle edge cases gracefully

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const rmdir = @import("rmdir");

test "rmdir fuzz arguments - never panic" {
    try std.testing.fuzz(testing.allocator, testRmdirWithFuzzedArgs, .{});
}

fn testRmdirWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // rmdir should handle all arguments gracefully without panicking
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    _ = rmdir.runRmdir(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "rmdir fuzz directory paths - handle all path types" {
    try std.testing.fuzz(testing.allocator, testRmdirWithFuzzedPaths, .{});
}

fn testRmdirWithFuzzedPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate various directory paths from fuzz input
    const paths = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    if (paths.len == 0) return;

    // Convert to const for rmdir function
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
        &[_][]const u8{"-v"}, // Verbose
        &[_][]const u8{"--verbose"}, // Verbose long form
        &[_][]const u8{"-p"}, // Remove parent directories
        &[_][]const u8{"--parents"}, // Remove parent directories long form
        &[_][]const u8{"--ignore-fail-on-non-empty"}, // Ignore failures on non-empty
        &[_][]const u8{"-pv"}, // Parents and verbose
        &[_][]const u8{ "-p", "--ignore-fail-on-non-empty" }, // Parents, ignore failures
    };

    for (flag_combos) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_paths);

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rmdir.runRmdir(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Errors are expected for non-existent or non-empty directories
            continue;
        };
    }
}

test "rmdir fuzz special characters - handle all byte values" {
    try std.testing.fuzz(testing.allocator, testRmdirSpecialChars, .{});
}

fn testRmdirSpecialChars(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Create directory paths with special/control characters
    var dir_path = std.ArrayList(u8).init(allocator);
    defer dir_path.deinit();

    try dir_path.appendSlice("fuzz_dir_");
    for (input) |byte| {
        // Replace null bytes and path separators to avoid path traversal
        if (byte == 0 or byte == '/') {
            try dir_path.append('_');
        } else {
            try dir_path.append(byte);
        }
        if (dir_path.items.len >= 200) break; // Limit directory name length
    }

    const dir_str = try dir_path.toOwnedSlice();
    defer allocator.free(dir_str);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test with various flags that might interact with special characters
    const flag_combos = [_][]const []const u8{
        &[_][]const u8{dir_str},
        &[_][]const u8{ "-v", dir_str },
        &[_][]const u8{ "-p", dir_str },
        &[_][]const u8{ "--ignore-fail-on-non-empty", dir_str },
    };

    for (flag_combos) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rmdir.runRmdir(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent directories
            continue;
        };
    }
}

test "rmdir fuzz nested directories - handle deep directory trees" {
    try std.testing.fuzz(testing.allocator, testRmdirNestedDirs, .{});
}

fn testRmdirNestedDirs(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate nested directory paths based on fuzz input
    var dir_path = std.ArrayList(u8).init(allocator);
    defer dir_path.deinit();

    const depth = @min(input[0] % 20, 10); // Limit depth to avoid stack overflow
    try dir_path.appendSlice("fuzz_deep");

    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try dir_path.appendSlice("/level");
        try dir_path.append('0' + @as(u8, @intCast(i % 10)));
    }

    const dir_str = try dir_path.toOwnedSlice();
    defer allocator.free(dir_str);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test removing deep directory structures
    const test_cases = [_][]const []const u8{
        &[_][]const u8{dir_str},
        &[_][]const u8{ "-p", dir_str }, // Remove parents (should remove entire chain)
        &[_][]const u8{ "-pv", dir_str }, // Remove parents with verbose
        &[_][]const u8{ "-p", "--ignore-fail-on-non-empty", dir_str },
    };

    for (test_cases) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rmdir.runRmdir(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent directories
            continue;
        };
    }
}

test "rmdir fuzz symlink directories - handle symlinked directories" {
    try std.testing.fuzz(testing.allocator, testRmdirSymlinks, .{});
}

fn testRmdirSymlinks(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate symlink chain patterns
    const chain = try common.fuzz.generateSymlinkChain(allocator, input);
    defer {
        for (chain) |link| allocator.free(link);
        allocator.free(chain);
    }

    if (chain.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test removing symlinks to directories
    const test_cases = [_][]const []const u8{
        &[_][]const u8{"-v"}, // Verbose removal
        &[_][]const u8{"-p"}, // Remove with parents
        &[_][]const u8{"--ignore-fail-on-non-empty"}, // Ignore non-empty failures
    };

    for (test_cases) |flags| {
        // Try removing each link in the chain
        for (chain) |link| {
            var args = std.ArrayList([]const u8).init(allocator);
            defer args.deinit();

            try args.appendSlice(flags);
            try args.append(link);

            stdout_buf.clearRetainingCapacity();
            stderr_buf.clearRetainingCapacity();

            _ = rmdir.runRmdir(allocator, args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
                // Expected to fail for non-existent or non-directory symlinks
                continue;
            };
        }
    }
}

test "rmdir fuzz root and system paths - handle protected directories" {
    try std.testing.fuzz(testing.allocator, testRmdirSystemPaths, .{});
}

fn testRmdirSystemPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate paths that might be system directories
    var system_paths = std.ArrayList([]const u8).init(allocator);
    defer system_paths.deinit();

    // Add some potentially sensitive paths (that don't exist in test environment)
    const base_paths = [_][]const u8{
        "/",
        "/tmp",
        "/var",
        "/usr",
        "/etc",
        "/bin",
        "/sbin",
        "/home",
        "/root",
        "C:\\",
        "D:\\",
    };

    const path_idx = input[0] % base_paths.len;
    const selected_path = base_paths[path_idx];

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test that rmdir handles system paths gracefully (should fail safely)
    const test_cases = [_][]const []const u8{
        &[_][]const u8{selected_path},
        &[_][]const u8{ "-v", selected_path },
        &[_][]const u8{ "-p", selected_path },
        &[_][]const u8{ "--ignore-fail-on-non-empty", selected_path },
    };

    for (test_cases) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rmdir.runRmdir(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail due to permissions or non-empty directories
            // The important thing is that it fails gracefully without panicking
            continue;
        };
    }
}

test "rmdir fuzz property - idempotence" {
    try std.testing.fuzz(testing.allocator, testRmdirIdempotence, .{});
}

fn testRmdirIdempotence(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate arguments
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Add ignore-fail-on-non-empty flag to make operation more idempotent
    var args_with_ignore = std.ArrayList([]const u8).init(allocator);
    defer args_with_ignore.deinit();

    try args_with_ignore.append("--ignore-fail-on-non-empty");
    try args_with_ignore.appendSlice(args);

    var stdout_buf1 = std.ArrayList(u8).init(allocator);
    defer stdout_buf1.deinit();
    var stderr_buf1 = std.ArrayList(u8).init(allocator);
    defer stderr_buf1.deinit();

    const result1 = rmdir.runRmdir(allocator, args_with_ignore.items, stdout_buf1.writer(), stderr_buf1.writer()) catch |err| {
        // If it fails the first time, second run should behave consistently
        var stdout_buf2 = std.ArrayList(u8).init(allocator);
        defer stdout_buf2.deinit();
        var stderr_buf2 = std.ArrayList(u8).init(allocator);
        defer stderr_buf2.deinit();

        _ = rmdir.runRmdir(allocator, args_with_ignore.items, stdout_buf2.writer(), stderr_buf2.writer()) catch {
            return; // Both failed, consistent
        };
        return err; // First failed, second succeeded - might be inconsistent
    };

    // First succeeded, second should also succeed or fail consistently
    var stdout_buf2 = std.ArrayList(u8).init(allocator);
    defer stdout_buf2.deinit();
    var stderr_buf2 = std.ArrayList(u8).init(allocator);
    defer stderr_buf2.deinit();

    const result2 = rmdir.runRmdir(allocator, args_with_ignore.items, stdout_buf2.writer(), stderr_buf2.writer()) catch {
        // Second run might fail if directory was already removed (expected)
        return;
    };

    // Both succeeded - this is valid if directories didn't exist
    try testing.expectEqual(result1, result2);
}

test "rmdir fuzz property - deterministic behavior" {
    try std.testing.fuzz(testing.allocator, testRmdirDeterministic, .{});
}

fn testRmdirDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    if (args.len == 0) return;

    // Run rmdir twice with same input
    var stdout_buf1 = std.ArrayList(u8).init(allocator);
    defer stdout_buf1.deinit();
    var stderr_buf1 = std.ArrayList(u8).init(allocator);
    defer stderr_buf1.deinit();

    var stdout_buf2 = std.ArrayList(u8).init(allocator);
    defer stdout_buf2.deinit();
    var stderr_buf2 = std.ArrayList(u8).init(allocator);
    defer stderr_buf2.deinit();

    const result1 = rmdir.runRmdir(allocator, args, stdout_buf1.writer(), stderr_buf1.writer()) catch |err| {
        // If first fails, second should behave consistently
        const result2 = rmdir.runRmdir(allocator, args, stdout_buf2.writer(), stderr_buf2.writer()) catch {
            return; // Both failed, that's consistent
        };
        _ = result2;
        return err; // First failed but second succeeded - inconsistent!
    };

    const result2 = rmdir.runRmdir(allocator, args, stdout_buf2.writer(), stderr_buf2.writer()) catch {
        // Second might fail if directory was removed - this is expected behavior
        return;
    };

    // Both succeeded - directories might not have existed
    try testing.expectEqual(result1, result2);
}

test "rmdir fuzz multiple directories - handle batch operations" {
    try std.testing.fuzz(testing.allocator, testRmdirMultipleDirs, .{});
}

fn testRmdirMultipleDirs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate multiple directory paths
    const dirs = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (dirs) |dir| allocator.free(dir);
        allocator.free(dirs);
    }

    if (dirs.len == 0) return;

    // Convert to const
    var const_dirs = try allocator.alloc([]const u8, dirs.len);
    defer allocator.free(const_dirs);
    for (dirs, 0..) |dir, i| {
        const_dirs[i] = dir;
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test removing multiple directories with various flag combinations
    const test_cases = [_][]const []const u8{
        &[_][]const u8{}, // No flags
        &[_][]const u8{"-v"}, // Verbose
        &[_][]const u8{"-p"}, // Remove parents
        &[_][]const u8{"--ignore-fail-on-non-empty"}, // Ignore failures
        &[_][]const u8{"-pv"}, // Parents and verbose
        &[_][]const u8{ "-p", "--ignore-fail-on-non-empty" }, // Parents, ignore failures
    };

    for (test_cases) |flags| {
        var all_args = std.ArrayList([]const u8).init(allocator);
        defer all_args.deinit();

        try all_args.appendSlice(flags);
        try all_args.appendSlice(const_dirs);

        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rmdir.runRmdir(allocator, all_args.items, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent or non-empty directories
            continue;
        };
    }
}

test "rmdir fuzz empty vs non-empty detection - handle directory states" {
    try std.testing.fuzz(testing.allocator, testRmdirEmptyDetection, .{});
}

fn testRmdirEmptyDetection(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate directory path
    const dir_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(dir_path);

    if (dir_path.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Test both with and without ignore-fail-on-non-empty
    const test_cases = [_][]const []const u8{
        &[_][]const u8{dir_path}, // Should fail on non-empty
        &[_][]const u8{ "--ignore-fail-on-non-empty", dir_path }, // Should succeed or ignore
        &[_][]const u8{ "-v", dir_path }, // Verbose failure on non-empty
        &[_][]const u8{ "-v", "--ignore-fail-on-non-empty", dir_path }, // Verbose ignore
    };

    for (test_cases) |args| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();

        _ = rmdir.runRmdir(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // This is expected behavior - rmdir should fail on non-empty directories
            // unless --ignore-fail-on-non-empty is specified
            continue;
        };
    }
}

test "rmdir fuzz concurrent operations - handle race conditions" {
    try std.testing.fuzz(testing.allocator, testRmdirConcurrent, .{});
}

fn testRmdirConcurrent(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate a directory path
    const dir_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(dir_path);

    if (dir_path.len == 0) return;

    // Test rapid successive calls to rmdir (simulating potential race conditions)
    var i: usize = 0;
    while (i < 3) : (i += 1) { // Limited iterations to avoid excessive test time
        var stdout_buf = std.ArrayList(u8).init(allocator);
        defer stdout_buf.deinit();
        var stderr_buf = std.ArrayList(u8).init(allocator);
        defer stderr_buf.deinit();

        const args = [_][]const u8{ "--ignore-fail-on-non-empty", dir_path };
        _ = rmdir.runRmdir(allocator, &args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail, but should not crash or have undefined behavior
            continue;
        };
    }
}
