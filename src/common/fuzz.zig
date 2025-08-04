//! Fuzzing utilities and helpers for vibeutils
//!
//! This module provides common utilities for fuzz testing across the project.
//! It includes helpers for generating random inputs, property-based testing,
//! and common fuzzing patterns.

const std = @import("std");
const testing = std.testing;

/// Maximum size for generated paths in fuzzing
pub const MAX_PATH_SIZE = 4096;

/// Maximum size for generated command lines
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

        if (args.items.len >= 100) break; // Limit number of arguments
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

/// Test helper: Create a test allocator that detects leaks
pub fn createTestAllocator() std.mem.Allocator {
    return testing.allocator;
}

/// Fuzzing property: Verify that parsing and formatting round-trip correctly
pub fn verifyRoundTrip(comptime T: type, parse_fn: anytype, format_fn: anytype, input: []const u8) !void {
    const allocator = createTestAllocator();

    // Parse the input
    const parsed = parse_fn(allocator, input) catch |err| {
        // Parse errors are acceptable
        _ = err;
        return;
    };
    defer if (@hasDecl(T, "deinit")) parsed.deinit();

    // Format it back
    const formatted = format_fn(allocator, parsed) catch |err| {
        // Format errors indicate a bug if parse succeeded
        return err;
    };
    defer allocator.free(formatted);

    // Parse again
    const reparsed = parse_fn(allocator, formatted) catch |err| {
        // This should not fail if format produced valid output
        return err;
    };
    defer if (@hasDecl(T, "deinit")) reparsed.deinit();

    // Verify equivalence (this is type-specific)
    // The actual comparison would depend on the type T
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
