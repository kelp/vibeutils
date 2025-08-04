//! Fuzzing utilities and helpers for vibeutils
//!
//! This module provides common utilities for fuzz testing across the project.
//! It includes helpers for generating random inputs, property-based testing,
//! and common fuzzing patterns.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const common = @import("lib.zig");

/// Configuration constants for fuzzing
pub const FuzzConfig = struct {
    /// Maximum argument size varies by build mode for performance
    pub const MAX_ARG_SIZE = if (builtin.mode == .Debug) 1000 else 10_000;
    /// Maximum argument count varies by build mode
    pub const MAX_ARG_COUNT = if (builtin.mode == .Debug) 100 else 1000;
    /// Maximum path depth to prevent infinite recursion
    pub const MAX_PATH_DEPTH = 20;
};

/// Legacy constants for backward compatibility
pub const MAX_PATH_SIZE = 4096;
pub const MAX_CMDLINE_SIZE = 8192;

/// Generate a random path-like string from fuzzer input
/// This creates path strings that exercise edge cases like:
/// - Empty paths
/// - Paths with special characters
/// - Unicode paths
/// - Path traversal attempts
/// - Very long paths
pub fn generatePath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) {
        return allocator.dupe(u8, "");
    }

    // Use first byte to determine path type
    const path_type = input[0] % 8;
    const remaining = if (input.len > 1) input[1..] else &[_]u8{};

    switch (path_type) {
        0 => {
            // Empty path
            return allocator.dupe(u8, "");
        },
        1 => {
            // Simple relative path
            return allocator.dupe(u8, "file.txt");
        },
        2 => {
            // Absolute path
            return allocator.dupe(u8, "/tmp/test.txt");
        },
        3 => {
            // Path with traversal
            return allocator.dupe(u8, "../../../etc/passwd");
        },
        4 => {
            // Path with special characters
            var path = std.ArrayList(u8).init(allocator);
            defer path.deinit();
            try path.appendSlice("file");
            for (remaining) |byte| {
                if (byte % 10 == 0) {
                    try path.append(' ');
                } else if (byte % 10 == 1) {
                    try path.append('\t');
                } else if (byte % 10 == 2) {
                    try path.append('\n');
                } else {
                    try path.append(byte);
                }
                if (path.items.len >= MAX_PATH_SIZE) break;
            }
            return path.toOwnedSlice();
        },
        5 => {
            // Unicode path
            return allocator.dupe(u8, "文件名.txt");
        },
        6 => {
            // Very long path
            var path = std.ArrayList(u8).init(allocator);
            defer path.deinit();
            while (path.items.len < MAX_PATH_SIZE and path.items.len < remaining.len * 10) {
                try path.appendSlice("very/long/path/component/");
            }
            return path.toOwnedSlice();
        },
        else => {
            // Raw fuzzer input as path
            const max_len = @min(remaining.len, MAX_PATH_SIZE);
            return allocator.dupe(u8, remaining[0..max_len]);
        },
    }
}

/// Generate command-line arguments from fuzzer input
/// Creates various argument patterns to test argument parsing
pub fn generateArgs(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    if (input.len == 0) {
        return &[_][]const u8{};
    }

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    var i: usize = 0;
    while (i < input.len) {
        const arg_type = input[i] % 8;
        i += 1;

        switch (arg_type) {
            0 => {
                // Short flag
                const flag = try allocator.alloc(u8, 2);
                flag[0] = '-';
                flag[1] = if (i < input.len) input[i] else 'a';
                try args.append(flag);
                i += 1;
            },
            1 => {
                // Long flag
                const flag = try std.fmt.allocPrint(allocator, "--flag{}", .{i});
                try args.append(flag);
            },
            2 => {
                // Flag with value
                const flag = try allocator.dupe(u8, "-v");
                try args.append(flag);
                const value = try std.fmt.allocPrint(allocator, "value{}", .{i});
                try args.append(value);
            },
            3 => {
                // Multiple short flags combined
                var flag = std.ArrayList(u8).init(allocator);
                defer flag.deinit();
                try flag.append('-');
                var j: usize = 0;
                while (j < 3 and i + j < input.len) : (j += 1) {
                    try flag.append(input[i + j]);
                }
                try args.append(try flag.toOwnedSlice());
                i += j;
            },
            4 => {
                // Double dash
                try args.append(try allocator.dupe(u8, "--"));
            },
            5 => {
                // Empty string
                try args.append(try allocator.dupe(u8, ""));
            },
            6 => {
                // Unicode argument
                try args.append(try allocator.dupe(u8, "文件"));
            },
            else => {
                // Regular positional argument
                const arg = try std.fmt.allocPrint(allocator, "arg{}", .{i});
                try args.append(arg);
            },
        }

        if (args.items.len >= FuzzConfig.MAX_ARG_COUNT) break;
    }

    return args.toOwnedSlice();
}

/// Property: Function should never panic, only return errors
/// This is a helper to verify that a function handles all inputs gracefully
pub fn expectNoGrac(comptime func: anytype, input: anytype) !void {
    _ = func(input) catch |err| {
        // Any error is fine, as long as we don't panic
        _ = err;
        return;
    };
    // Success is also fine
}

/// Generate escape sequences for testing echo-like utilities
pub fn generateEscapeSequence(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) {
        return allocator.dupe(u8, "");
    }

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (input) |byte| {
        const escape_type = byte % 12;
        switch (escape_type) {
            0 => try result.appendSlice("\\n"),
            1 => try result.appendSlice("\\t"),
            2 => try result.appendSlice("\\r"),
            3 => try result.appendSlice("\\\\"),
            4 => try result.appendSlice("\\a"),
            5 => try result.appendSlice("\\b"),
            6 => try result.appendSlice("\\f"),
            7 => try result.appendSlice("\\v"),
            8 => try result.appendSlice("\\0"),
            9 => {
                // Octal sequence
                try result.appendSlice("\\0");
                try result.append('0' + (byte % 8));
                try result.append('0' + ((byte / 8) % 8));
            },
            10 => {
                // Hex sequence
                try result.appendSlice("\\x");
                const hex_chars = "0123456789abcdef";
                try result.append(hex_chars[byte % 16]);
                try result.append(hex_chars[(byte / 16) % 16]);
            },
            else => {
                // Regular character
                try result.append(byte);
            },
        }

        if (result.items.len >= MAX_CMDLINE_SIZE) break;
    }

    return result.toOwnedSlice();
}

/// Generate file permissions from fuzzer input
/// Creates various permission patterns for chmod testing
pub fn generateFilePermissions(input: []const u8) u9 {
    if (input.len == 0) {
        return 0o644; // Default permissions
    }

    // Use fuzzer input to create permission bits
    var perm: u9 = 0;
    const byte = input[0];

    // Owner permissions
    if (byte & 0x01 != 0) perm |= 0o400; // Read
    if (byte & 0x02 != 0) perm |= 0o200; // Write
    if (byte & 0x04 != 0) perm |= 0o100; // Execute

    // Group permissions
    if (byte & 0x08 != 0) perm |= 0o040; // Read
    if (byte & 0x10 != 0) perm |= 0o020; // Write
    if (byte & 0x20 != 0) perm |= 0o010; // Execute

    // Other permissions
    if (byte & 0x40 != 0) perm |= 0o004; // Read
    if (byte & 0x80 != 0) perm |= 0o002; // Write
    if (input.len > 1 and input[1] & 0x01 != 0) perm |= 0o001; // Execute

    return perm;
}

/// Generate a list of file paths from fuzzer input
/// Creates multiple paths for testing batch operations
pub fn generateFileList(allocator: std.mem.Allocator, input: []const u8) ![][]u8 {
    if (input.len == 0) {
        return &[_][]u8{};
    }

    var files = std.ArrayList([]u8).init(allocator);
    defer files.deinit();

    // Determine number of files (1-10)
    const num_files = @min((input[0] % 10) + 1, input.len);

    var i: usize = 0;
    while (i < num_files) : (i += 1) {
        const start = i * (input.len / num_files);
        const end = @min(start + (input.len / num_files), input.len);

        if (start < end) {
            const file_path = try generatePath(allocator, input[start..end]);
            try files.append(file_path);
        } else {
            // Generate a default file name
            const file_path = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
            try files.append(file_path);
        }
    }

    return files.toOwnedSlice();
}

/// Generate a symbolic link chain pattern from fuzzer input
/// Creates various symlink scenarios for testing ln, cp, mv operations
pub fn generateSymlinkChain(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    if (input.len == 0) {
        return &[_][]const u8{};
    }

    var chain = std.ArrayList([]const u8).init(allocator);
    defer chain.deinit();

    const chain_type = input[0] % 5;

    switch (chain_type) {
        0 => {
            // Simple symlink: link -> target
            try chain.append(try allocator.dupe(u8, "link"));
            try chain.append(try allocator.dupe(u8, "target"));
        },
        1 => {
            // Chain: link1 -> link2 -> target
            try chain.append(try allocator.dupe(u8, "link1"));
            try chain.append(try allocator.dupe(u8, "link2"));
            try chain.append(try allocator.dupe(u8, "target"));
        },
        2 => {
            // Loop: link1 -> link2 -> link1
            try chain.append(try allocator.dupe(u8, "link1"));
            try chain.append(try allocator.dupe(u8, "link2"));
            try chain.append(try allocator.dupe(u8, "link1"));
        },
        3 => {
            // Broken: link -> nonexistent
            try chain.append(try allocator.dupe(u8, "link"));
            try chain.append(try allocator.dupe(u8, "/nonexistent/path"));
        },
        else => {
            // Complex chain with multiple levels
            const depth = @min(input[0] % 10, 5);
            var i: usize = 0;
            while (i < depth) : (i += 1) {
                const link_name = try std.fmt.allocPrint(allocator, "link{}", .{i});
                try chain.append(link_name);
            }
            try chain.append(try allocator.dupe(u8, "final_target"));
        },
    }

    return chain.toOwnedSlice();
}

/// Generate signal number from fuzzer input
/// Used for testing signal handling in utilities like sleep, yes
pub fn generateSignal(input: []const u8) u8 {
    if (input.len == 0) {
        return 15; // SIGTERM
    }

    // Common signals to test
    const signals = [_]u8{
        1, // SIGHUP
        2, // SIGINT
        3, // SIGQUIT
        9, // SIGKILL
        15, // SIGTERM
        17, // SIGSTOP
        18, // SIGTSTP
        19, // SIGCONT
    };

    return signals[input[0] % signals.len];
}

/// Test helper: Create a test allocator that detects leaks
pub fn createTestAllocator() std.mem.Allocator {
    return testing.allocator;
}

/// Generic fuzz test: Utility should handle any input gracefully without panicking
pub fn testUtilityBasic(comptime run_fn: anytype, allocator: std.mem.Allocator, input: []const u8) !void {
    const args = generateArgs(allocator, input) catch return;
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = run_fn(allocator, args, stdout_buf.writer(), common.null_writer) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("Fuzz error (expected): {}\n", .{err});
        }
        return;
    };
}

/// Generic fuzz test: Utility should be deterministic (same input = same output)
pub fn testUtilityDeterministic(comptime run_fn: anytype, allocator: std.mem.Allocator, input: []const u8) !void {
    const args = generateArgs(allocator, input) catch return;
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var buffer1 = std.ArrayList(u8).init(allocator);
    defer buffer1.deinit();
    var buffer2 = std.ArrayList(u8).init(allocator);
    defer buffer2.deinit();

    const result1 = run_fn(allocator, args, buffer1.writer(), common.null_writer) catch |err| {
        // If first fails, second should also fail
        const result2 = run_fn(allocator, args, buffer2.writer(), common.null_writer) catch {
            return; // Both failed consistently
        };
        _ = result2;
        return err; // Inconsistent behavior
    };

    const result2 = run_fn(allocator, args, buffer2.writer(), common.null_writer) catch {
        return error.InconsistentBehavior;
    };

    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}

/// Generic fuzz test: Utility should handle path-like arguments gracefully
pub fn testUtilityPaths(comptime run_fn: anytype, allocator: std.mem.Allocator, input: []const u8) !void {
    const path = generatePath(allocator, input) catch return;
    defer allocator.free(path);

    const args = [_][]const u8{path};
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = run_fn(allocator, &args, stdout_buf.writer(), common.null_writer) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("Path fuzz error (expected): {}\n", .{err});
        }
        return;
    };
}

test "generatePath produces valid paths" {
    const allocator = testing.allocator;

    // Test empty input
    {
        const path = try generatePath(allocator, &[_]u8{});
        defer allocator.free(path);
        try testing.expectEqualStrings("", path);
    }

    // Test various path types
    {
        const inputs = [_][]const u8{
            &[_]u8{0}, // Empty path
            &[_]u8{1}, // Simple relative
            &[_]u8{2}, // Absolute
            &[_]u8{3}, // Traversal
            &[_]u8{ 4, 65, 66, 67 }, // Special chars
            &[_]u8{5}, // Unicode
            &[_]u8{ 6, 1, 2, 3 }, // Long path
            &[_]u8{ 7, 65, 66 }, // Raw input
        };

        for (inputs) |input| {
            const path = try generatePath(allocator, input);
            defer allocator.free(path);
            // Just verify it doesn't crash and returns something
            try testing.expect(path.len <= MAX_PATH_SIZE);
        }
    }
}

test "generateArgs produces valid argument arrays" {
    const allocator = testing.allocator;

    // Test empty input
    {
        const args = try generateArgs(allocator, &[_]u8{});
        defer allocator.free(args);
        try testing.expectEqual(@as(usize, 0), args.len);
    }

    // Test various argument patterns
    {
        const input = [_]u8{ 0, 65, 1, 2, 66, 3, 67, 68, 69, 4, 5, 6, 7 };
        const args = try generateArgs(allocator, input[0..]);
        defer {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }

        // Verify we got some arguments
        try testing.expect(args.len > 0);
        try testing.expect(args.len <= 100);
    }
}

test "generateEscapeSequence produces valid escape sequences" {
    const allocator = testing.allocator;

    // Test empty input
    {
        const seq = try generateEscapeSequence(allocator, &[_]u8{});
        defer allocator.free(seq);
        try testing.expectEqualStrings("", seq);
    }

    // Test various escape sequences
    {
        const input = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 100, 200 };
        const seq = try generateEscapeSequence(allocator, input[0..]);
        defer allocator.free(seq);

        // Verify we got something and it's not too long
        try testing.expect(seq.len > 0);
        try testing.expect(seq.len <= MAX_CMDLINE_SIZE);
    }
}

test "generateFilePermissions produces valid permissions" {
    // Test empty input
    {
        const perm = generateFilePermissions(&[_]u8{});
        try testing.expectEqual(@as(u9, 0o644), perm);
    }

    // Test various permission patterns
    {
        const perm1 = generateFilePermissions(&[_]u8{0xFF}); // All bits set
        try testing.expect(perm1 <= 0o777);

        const perm2 = generateFilePermissions(&[_]u8{0x00}); // No bits set
        try testing.expectEqual(@as(u9, 0), perm2);

        const perm3 = generateFilePermissions(&[_]u8{0x07}); // Owner rwx
        try testing.expectEqual(@as(u9, 0o700), perm3);
    }
}

test "generateFileList produces valid file lists" {
    const allocator = testing.allocator;

    // Test empty input
    {
        const files = try generateFileList(allocator, &[_]u8{});
        defer allocator.free(files);
        try testing.expectEqual(@as(usize, 0), files.len);
    }

    // Test various file list patterns
    {
        const input = [_]u8{ 3, 65, 66, 67, 68, 69, 70 };
        const files = try generateFileList(allocator, input[0..]);
        defer {
            for (files) |file| allocator.free(file);
            allocator.free(files);
        }

        // Should have 1-10 files
        try testing.expect(files.len >= 1);
        try testing.expect(files.len <= 10);
    }
}

test "generateSymlinkChain produces valid symlink patterns" {
    const allocator = testing.allocator;

    // Test empty input
    {
        const chain = try generateSymlinkChain(allocator, &[_]u8{});
        defer allocator.free(chain);
        try testing.expectEqual(@as(usize, 0), chain.len);
    }

    // Test various chain types
    {
        const inputs = [_][]const u8{
            &[_]u8{0}, // Simple symlink
            &[_]u8{1}, // Chain
            &[_]u8{2}, // Loop
            &[_]u8{3}, // Broken
            &[_]u8{4}, // Complex
        };

        for (inputs) |input| {
            const chain = try generateSymlinkChain(allocator, input);
            defer {
                for (chain) |link| allocator.free(link);
                allocator.free(chain);
            }

            // Should have at least 2 items (link and target)
            try testing.expect(chain.len >= 2);
        }
    }
}

test "generateSignal produces valid signal numbers" {
    // Test empty input
    {
        const sig = generateSignal(&[_]u8{});
        try testing.expectEqual(@as(u8, 15), sig); // SIGTERM
    }

    // Test various inputs
    {
        const inputs = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 255 };
        for (inputs) |input| {
            const sig = generateSignal(&[_]u8{input});
            // Should be one of the common signals
            try testing.expect(sig == 1 or sig == 2 or sig == 3 or sig == 9 or
                sig == 15 or sig == 17 or sig == 18 or sig == 19);
        }
    }
}
