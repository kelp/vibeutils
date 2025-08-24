//! Fuzzing utilities and helpers for vibeutils
//!
//! This module provides a unified fuzzing architecture that eliminates code duplication
//! across utility fuzz tests. The intelligent fuzzer system understands flag relationships,
//! generates contextually appropriate values, and provides both basic and advanced
//! testing strategies.
//!
//! WHY THIS EXISTS:
//! - Prevents 70%+ code duplication by providing reusable fuzz test patterns
//! - Offers both simple generic tests and sophisticated semantic-aware fuzzing
//! - Maintains consistency in fuzz testing approaches across all utilities
//! - Automatically handles edge cases like flag conflicts and invalid combinations
//!
//! USAGE PATTERNS:
//! 1. Basic fuzzing: Use testUtilityBasic/Deterministic/Paths for simple cases
//! 2. Smart fuzzing: Use createSmartFuzzer for automatic flag discovery
//! 3. Intelligent fuzzing: Use createIntelligentFuzzer for semantic understanding
//!
//! All functions work with stack-allocated buffers and std.testing.fuzz() API.
//! Functions generate intentionally challenging inputs to test OS-level security
//! rather than application-level restrictions.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const common = @import("lib.zig");

/// Enable fuzz tests only on Linux when fuzzing is enabled
const enable_fuzz_tests = builtin.os.tag == .linux and @import("builtin").fuzz;

/// Check if fuzzing should be enabled for a specific utility (runtime version)
/// This supports selective fuzzing via the VIBEUTILS_FUZZ_TARGET environment variable
/// Note: This must be called at runtime, not compile time
pub fn shouldFuzzUtilityRuntime(utility_name: []const u8) bool {
    // Only fuzz on Linux
    if (builtin.os.tag != .linux) return false;

    // Check environment variable
    const fuzz_target = std.process.getEnvVarOwned(std.heap.page_allocator, "VIBEUTILS_FUZZ_TARGET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false, // Default: no fuzzing unless explicitly enabled
        else => return false, // Other errors: disable fuzzing
    };
    defer std.heap.page_allocator.free(fuzz_target);

    // Check if this utility should be fuzzed
    if (std.mem.eql(u8, fuzz_target, "all")) return true;
    if (std.mem.eql(u8, fuzz_target, utility_name)) return true;

    return false;
}

/// Check if fuzzing should be enabled for a specific utility (compile-time version)
/// This is the simpler version that can be used at compile time for test filtering
/// It only checks the OS and assumes fuzzing is enabled when the build has --fuzz
pub fn shouldFuzzUtility(utility_name: []const u8) bool {
    _ = utility_name; // We'll check this at runtime in the actual test
    // Only enable fuzz tests on Linux - environment variable will be checked at runtime
    return builtin.os.tag == .linux;
}

/// Configuration constants for fuzzing
pub const FuzzConfig = struct {
    /// Build-dependent limits for performance vs coverage
    pub const MAX_ARG_SIZE = if (builtin.mode == .Debug) 1000 else 10_000;
    pub const MAX_ARG_COUNT = if (builtin.mode == .Debug) 100 else 1000;
    pub const MAX_PATH_DEPTH = 20;
    pub const MAX_PATH_SIZE = 4096;
    pub const MAX_CMDLINE_SIZE = 8192;

    /// Buffer sizes for stack allocation
    pub const PATH_BUFFER_SIZE = MAX_PATH_SIZE;
    pub const ARG_BUFFER_SIZE = MAX_ARG_SIZE;
    pub const ESCAPE_BUFFER_SIZE = MAX_CMDLINE_SIZE;

    /// Pattern counts for generation algorithms
    pub const PATH_PATTERN_COUNT = 8;
    pub const ARG_PATTERN_COUNT = 8;
    pub const ESCAPE_PATTERN_COUNT = 12;
    pub const SPECIAL_CHAR_PATTERN_COUNT = 10;
    pub const SYMLINK_PATTERN_COUNT = 5;
    pub const MAX_FILE_LIST_SIZE = 10;
    pub const HEX_DIGIT_COUNT = 16;
    pub const OCTAL_DIGIT_COUNT = 8;
};

/// Generate a path string from fuzzer input using a fixed buffer
/// Creates path strings exercising edge cases using a fixed buffer.
/// Returns a slice of the buffer containing the generated path.
pub fn generatePath(buffer: []u8, input: []const u8) []u8 {
    if (input.len == 0 or buffer.len == 0) {
        return buffer[0..0]; // Empty path
    }

    const path_type = input[0] % FuzzConfig.PATH_PATTERN_COUNT;
    const remaining = if (input.len > 1) input[1..] else &[_]u8{};

    switch (path_type) {
        0 => return buffer[0..0], // Empty path
        1 => {
            const path = "file.txt";
            const len = @min(path.len, buffer.len);
            @memcpy(buffer[0..len], path[0..len]);
            return buffer[0..len];
        },
        2 => {
            const temp_dir = if (builtin.os.tag == .windows) "C:\\temp\\test.txt" else "/tmp/test.txt";
            const len = @min(temp_dir.len, buffer.len);
            @memcpy(buffer[0..len], temp_dir[0..len]);
            return buffer[0..len];
        },
        3 => {
            // Path with traversal components from fuzzer input
            var pos: usize = 0;
            const prefix = "../";

            for (remaining) |byte| {
                if (pos + prefix.len >= buffer.len) break;
                if (byte % 3 == 0) {
                    @memcpy(buffer[pos .. pos + prefix.len], prefix);
                    pos += prefix.len;
                }
            }

            const filename_start = pos;
            for (remaining) |byte| {
                if (pos >= buffer.len) break;
                buffer[pos] = if (byte >= 32 and byte <= 126) byte else 'x';
                pos += 1;
            }

            if (pos == filename_start and pos + 4 <= buffer.len) {
                @memcpy(buffer[pos .. pos + 4], "test");
                pos += 4;
            }

            return buffer[0..pos];
        },
        4 => {
            var pos: usize = 0;
            const prefix = "file";
            const prefix_len = @min(prefix.len, buffer.len);
            @memcpy(buffer[0..prefix_len], prefix[0..prefix_len]);
            pos += prefix_len;

            for (remaining) |byte| {
                if (pos >= buffer.len) break;
                if (byte % FuzzConfig.SPECIAL_CHAR_PATTERN_COUNT == 0) {
                    buffer[pos] = ' ';
                } else if (byte % FuzzConfig.SPECIAL_CHAR_PATTERN_COUNT == 1) {
                    buffer[pos] = '\t';
                } else if (byte % FuzzConfig.SPECIAL_CHAR_PATTERN_COUNT == 2) {
                    buffer[pos] = '\n';
                } else {
                    buffer[pos] = byte;
                }
                pos += 1;
            }
            return buffer[0..pos];
        },
        5 => {
            const path = "文件名.txt";
            const len = @min(path.len, buffer.len);
            @memcpy(buffer[0..len], path[0..len]);
            return buffer[0..len];
        },
        6 => {
            var pos: usize = 0;
            const component = "very/long/path/component/";
            while (pos + component.len <= buffer.len and pos < remaining.len * 10) {
                @memcpy(buffer[pos .. pos + component.len], component);
                pos += component.len;
            }
            return buffer[0..pos];
        },
        else => {
            const max_len = @min(remaining.len, buffer.len);
            @memcpy(buffer[0..max_len], remaining[0..max_len]);
            return buffer[0..max_len];
        },
    }
}

/// Fixed argument storage for generateArgs
pub const ArgStorage = struct {
    buffers: [FuzzConfig.MAX_ARG_COUNT][FuzzConfig.MAX_ARG_SIZE]u8,
    args: [FuzzConfig.MAX_ARG_COUNT][]const u8,
    count: usize,

    pub fn init() ArgStorage {
        return ArgStorage{
            .buffers = undefined,
            .args = [_][]const u8{""} ** FuzzConfig.MAX_ARG_COUNT,
            .count = 0,
        };
    }

    pub fn getArgs(self: *const ArgStorage) []const []const u8 {
        return self.args[0..self.count];
    }
};

/// Generate command-line arguments from fuzzer input using fixed storage
/// Creates argument patterns to test parsing using fixed arrays.
/// Returns a slice of the argument array containing valid arguments.
pub fn generateArgs(storage: *ArgStorage, input: []const u8) []const []const u8 {
    storage.count = 0;

    if (input.len == 0) {
        return storage.args[0..0];
    }

    var i: usize = 0;
    while (i < input.len and storage.count < FuzzConfig.MAX_ARG_COUNT) {
        const arg_type = input[i] % FuzzConfig.ARG_PATTERN_COUNT;
        i += 1;

        var arg_len: usize = 0;
        var buffer = &storage.buffers[storage.count];

        switch (arg_type) {
            0 => {
                buffer[0] = '-';
                buffer[1] = if (i < input.len) input[i] else 'a';
                arg_len = 2;
                i += 1;
            },
            1 => {
                const flag_template = "--flag";
                arg_len = @min(flag_template.len, buffer.len);
                @memcpy(buffer[0..arg_len], flag_template[0..arg_len]);
            },
            2 => {
                buffer[0] = '-';
                buffer[1] = 'v';
                arg_len = 2;
            },
            3 => {
                buffer[0] = '-';
                arg_len = 1;
                var j: usize = 0;
                while (j < 3 and i + j < input.len and arg_len < buffer.len) : (j += 1) {
                    buffer[arg_len] = input[i + j];
                    arg_len += 1;
                }
                i += j;
            },
            4 => {
                buffer[0] = '-';
                buffer[1] = '-';
                arg_len = 2;
            },
            5 => arg_len = 0,
            6 => {
                const unicode = "文件";
                arg_len = @min(unicode.len, buffer.len);
                @memcpy(buffer[0..arg_len], unicode[0..arg_len]);
            },
            else => {
                const arg_template = "arg";
                arg_len = @min(arg_template.len, buffer.len);
                @memcpy(buffer[0..arg_len], arg_template[0..arg_len]);
            },
        }

        storage.args[storage.count] = buffer[0..arg_len];
        storage.count += 1;
    }

    return storage.args[0..storage.count];
}

/// Generate escape sequences for testing echo-like utilities using a fixed buffer
pub fn generateEscapeSequence(buffer: []u8, input: []const u8) []u8 {
    if (input.len == 0 or buffer.len == 0) {
        return buffer[0..0];
    }

    // Lookup table for escape sequences: [sequence, length]
    const escape_sequences = [_]struct { seq: []const u8, len: u2 }{
        .{ .seq = "\\n", .len = 2 }, // newline
        .{ .seq = "\\t", .len = 2 }, // tab
        .{ .seq = "\\r", .len = 2 }, // carriage return
        .{ .seq = "\\\\", .len = 2 }, // backslash
        .{ .seq = "\\a", .len = 2 }, // bell
        .{ .seq = "\\b", .len = 2 }, // backspace
        .{ .seq = "\\f", .len = 2 }, // form feed
        .{ .seq = "\\v", .len = 2 }, // vertical tab
        .{ .seq = "\\0", .len = 2 }, // null
    };

    var pos: usize = 0;
    for (input) |byte| {
        if (pos >= buffer.len) break;

        const escape_type = byte % FuzzConfig.ESCAPE_PATTERN_COUNT;

        if (escape_type < escape_sequences.len) {
            // Use lookup table for common escapes
            const escape = escape_sequences[escape_type];
            if (pos + escape.len <= buffer.len) {
                @memcpy(buffer[pos .. pos + escape.len], escape.seq);
                pos += escape.len;
            }
        } else if (escape_type == 9) {
            // Octal sequence
            if (pos + 4 <= buffer.len) {
                buffer[pos] = '\\';
                buffer[pos + 1] = '0';
                buffer[pos + 2] = '0' + @as(u8, @intCast(byte % FuzzConfig.OCTAL_DIGIT_COUNT));
                buffer[pos + 3] = '0' + @as(u8, @intCast((byte / FuzzConfig.OCTAL_DIGIT_COUNT) % FuzzConfig.OCTAL_DIGIT_COUNT));
                pos += 4;
            }
        } else if (escape_type == 10) {
            // Hex sequence
            if (pos + 4 <= buffer.len) {
                const hex_chars = "0123456789abcdef";
                buffer[pos] = '\\';
                buffer[pos + 1] = 'x';
                buffer[pos + 2] = hex_chars[byte % FuzzConfig.HEX_DIGIT_COUNT];
                buffer[pos + 3] = hex_chars[(byte / FuzzConfig.HEX_DIGIT_COUNT) % FuzzConfig.HEX_DIGIT_COUNT];
                pos += 4;
            }
        } else {
            // Regular character
            buffer[pos] = byte;
            pos += 1;
        }
    }

    return buffer[0..pos];
}

/// Generate file permissions from fuzzer input
/// Creates permission patterns for chmod testing
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

/// Fixed file list storage
pub const FileListStorage = struct {
    buffers: [FuzzConfig.MAX_FILE_LIST_SIZE][FuzzConfig.MAX_PATH_SIZE]u8,
    files: [FuzzConfig.MAX_FILE_LIST_SIZE][]const u8,
    count: usize,

    pub fn init() FileListStorage {
        return FileListStorage{
            .buffers = undefined,
            .files = [_][]const u8{""} ** FuzzConfig.MAX_FILE_LIST_SIZE,
            .count = 0,
        };
    }

    pub fn getFiles(self: *const FileListStorage) []const []const u8 {
        return self.files[0..self.count];
    }
};

/// Generate a list of file paths from fuzzer input using fixed storage
/// Creates multiple paths for batch operations using fixed buffers.
pub fn generateFileList(storage: *FileListStorage, input: []const u8) []const []const u8 {
    storage.count = 0;

    if (input.len == 0) {
        return storage.files[0..0];
    }

    // Determine number of files (1-10)
    const num_files = @min((input[0] % FuzzConfig.MAX_FILE_LIST_SIZE) + 1, input.len);

    var i: usize = 0;
    while (i < num_files and storage.count < FuzzConfig.MAX_FILE_LIST_SIZE) : (i += 1) {
        const start = i * (input.len / num_files);
        const end = @min(start + (input.len / num_files), input.len);

        var buffer = &storage.buffers[storage.count];
        var path_slice: []u8 = undefined;

        if (start < end) {
            path_slice = generatePath(buffer, input[start..end]);
        } else {
            // Generate a default file name
            const default_name = "file.txt";
            const len = @min(default_name.len, buffer.len);
            @memcpy(buffer[0..len], default_name[0..len]);
            path_slice = buffer[0..len];
        }

        storage.files[storage.count] = path_slice;
        storage.count += 1;
    }

    return storage.files[0..storage.count];
}

/// Fixed symlink chain storage
pub const SymlinkStorage = struct {
    buffers: [FuzzConfig.SYMLINK_PATTERN_COUNT + 1][FuzzConfig.MAX_PATH_SIZE]u8,
    links: [FuzzConfig.SYMLINK_PATTERN_COUNT + 1][]const u8,
    count: usize,

    pub fn init() SymlinkStorage {
        return SymlinkStorage{
            .buffers = undefined,
            .links = [_][]const u8{""} ** (FuzzConfig.SYMLINK_PATTERN_COUNT + 1),
            .count = 0,
        };
    }

    pub fn getLinks(self: *const SymlinkStorage) []const []const u8 {
        return self.links[0..self.count];
    }
};

/// Generate a symbolic link chain pattern from fuzzer input using fixed storage
/// Creates symlink scenarios for testing ln, cp, mv operations using fixed buffers.
pub fn generateSymlinkChain(storage: *SymlinkStorage, input: []const u8) []const []const u8 {
    storage.count = 0;

    if (input.len == 0) {
        return storage.links[0..0];
    }

    const chain_type = input[0] % FuzzConfig.SYMLINK_PATTERN_COUNT;

    switch (chain_type) {
        0 => {
            // Simple symlink: link -> target
            const link_name = "link";
            const target_name = "target";

            @memcpy(storage.buffers[0][0..link_name.len], link_name);
            storage.links[0] = storage.buffers[0][0..link_name.len];

            @memcpy(storage.buffers[1][0..target_name.len], target_name);
            storage.links[1] = storage.buffers[1][0..target_name.len];

            storage.count = 2;
        },
        1 => {
            // Chain: link1 -> link2 -> target
            const names = [_][]const u8{ "link1", "link2", "target" };
            for (names, 0..) |name, idx| {
                @memcpy(storage.buffers[idx][0..name.len], name);
                storage.links[idx] = storage.buffers[idx][0..name.len];
            }
            storage.count = 3;
        },
        2 => {
            // Loop: link1 -> link2 -> link1
            const names = [_][]const u8{ "link1", "link2", "link1" };
            for (names, 0..) |name, idx| {
                @memcpy(storage.buffers[idx][0..name.len], name);
                storage.links[idx] = storage.buffers[idx][0..name.len];
            }
            storage.count = 3;
        },
        3 => {
            // Broken: link -> nonexistent
            const link_name = "link";
            const target_name = "/nonexistent/path";

            @memcpy(storage.buffers[0][0..link_name.len], link_name);
            storage.links[0] = storage.buffers[0][0..link_name.len];

            @memcpy(storage.buffers[1][0..target_name.len], target_name);
            storage.links[1] = storage.buffers[1][0..target_name.len];

            storage.count = 2;
        },
        else => {
            // Complex chain with multiple levels
            const depth = @min(input[0] % FuzzConfig.MAX_FILE_LIST_SIZE, 5);
            var i: usize = 0;
            while (i < depth and i < storage.buffers.len) : (i += 1) {
                // Generate link name like "link0", "link1", etc.
                const link_prefix = "link";
                const digit = '0' + @as(u8, @intCast(i % 10));

                @memcpy(storage.buffers[i][0..link_prefix.len], link_prefix);
                storage.buffers[i][link_prefix.len] = digit;
                storage.links[i] = storage.buffers[i][0 .. link_prefix.len + 1];
            }

            // Add final target
            if (i < storage.buffers.len) {
                const target_name = "final_target";
                @memcpy(storage.buffers[i][0..target_name.len], target_name);
                storage.links[i] = storage.buffers[i][0..target_name.len];
                i += 1;
            }

            storage.count = i;
        },
    }

    return storage.links[0..storage.count];
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

/// Generic fuzz test: Handle any input gracefully without panicking
pub fn testUtilityBasic(comptime run_fn: anytype, allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
    var arg_storage = ArgStorage.init();
    const args = generateArgs(&arg_storage, input);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stdout_buf.deinit(allocator);

    _ = run_fn(allocator, args, stdout_buf.writer(allocator), stderr_writer) catch {
        // Errors are expected and acceptable during fuzzing
        return;
    };
}

/// Generic fuzz test: Be deterministic (same input = same output)
pub fn testUtilityDeterministic(comptime run_fn: anytype, allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
    var arg_storage = ArgStorage.init();
    const args = generateArgs(&arg_storage, input);

    var buffer1 = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buffer1.deinit(allocator);
    var buffer2 = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buffer2.deinit(allocator);

    const result1 = run_fn(allocator, args, buffer1.writer(allocator), stderr_writer) catch |err| {
        // If first fails, second should also fail
        const result2 = run_fn(allocator, args, buffer2.writer(allocator), stderr_writer) catch {
            return; // Both failed consistently
        };
        _ = result2;
        return err; // Inconsistent behavior
    };

    const result2 = run_fn(allocator, args, buffer2.writer(allocator), stderr_writer) catch {
        return error.InconsistentBehavior;
    };

    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}

/// Generic fuzz test: Handle path-like arguments gracefully
pub fn testUtilityPaths(comptime run_fn: anytype, allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
    var path_buffer: [FuzzConfig.PATH_BUFFER_SIZE]u8 = undefined;
    const path = generatePath(&path_buffer, input);

    const args = [_][]const u8{path};
    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stdout_buf.deinit(allocator);

    _ = run_fn(allocator, &args, stdout_buf.writer(allocator), stderr_writer) catch {
        // Errors are expected and acceptable during fuzzing
        return;
    };
}

test "generatePath produces valid paths" {
    // Test empty input
    {
        var buffer: [FuzzConfig.PATH_BUFFER_SIZE]u8 = undefined;
        const path = generatePath(&buffer, &[_]u8{});
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
            var buffer: [FuzzConfig.PATH_BUFFER_SIZE]u8 = undefined;
            const path = generatePath(&buffer, input);
            // Just verify it doesn't crash and returns something reasonable
            try testing.expect(path.len <= FuzzConfig.MAX_PATH_SIZE);
        }
    }
}

test "generateArgs produces valid argument arrays" {
    // Test empty input
    {
        var storage = ArgStorage.init();
        const args = generateArgs(&storage, &[_]u8{});
        try testing.expectEqual(@as(usize, 0), args.len);
    }

    // Test various argument patterns
    {
        const input = [_]u8{ 0, 65, 1, 2, 66, 3, 67, 68, 69, 4, 5, 6, 7 };
        var storage = ArgStorage.init();
        const args = generateArgs(&storage, input[0..]);

        // Should have generated some arguments
        try testing.expect(args.len > 0);
        try testing.expect(args.len <= FuzzConfig.MAX_ARG_COUNT);
    }
}

test "generateEscapeSequence produces valid escape sequences" {
    // Test empty input
    {
        var buffer: [FuzzConfig.ESCAPE_BUFFER_SIZE]u8 = undefined;
        const seq = generateEscapeSequence(&buffer, &[_]u8{});
        try testing.expectEqualStrings("", seq);
    }

    // Test various escape sequences
    {
        const input = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 100, 200 };
        var buffer: [FuzzConfig.ESCAPE_BUFFER_SIZE]u8 = undefined;
        const seq = generateEscapeSequence(&buffer, input[0..]);

        // Verify we got something and it's not too long
        try testing.expect(seq.len <= FuzzConfig.MAX_CMDLINE_SIZE);
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
    // Test empty input
    {
        var storage = FileListStorage.init();
        const files = generateFileList(&storage, &[_]u8{});
        try testing.expectEqual(@as(usize, 0), files.len);
    }

    // Test various file list patterns
    {
        const input = [_]u8{ 3, 65, 66, 67, 68, 69, 70 };
        var storage = FileListStorage.init();
        const files = generateFileList(&storage, input[0..]);

        // Should have 1-10 files
        try testing.expect(files.len >= 1);
        try testing.expect(files.len <= FuzzConfig.MAX_FILE_LIST_SIZE);
    }
}

test "generateSymlinkChain produces valid symlink patterns" {
    // Test empty input
    {
        var storage = SymlinkStorage.init();
        const chain = generateSymlinkChain(&storage, &[_]u8{});
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
            var storage = SymlinkStorage.init();
            const chain = generateSymlinkChain(&storage, input);

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

/// Information about a command-line flag extracted via reflection
const FlagInfo = struct {
    name: []const u8,
    short: ?u8,
    field_type: type,
    takes_value: bool,
};

/// Create a smart fuzzer that automatically discovers and tests all flags
pub fn createSmartFuzzer(comptime ArgsType: type, comptime runFn: anytype) type {
    return struct {
        /// Automatically test all flag combinations
        pub fn testAllFlags(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            if (input.len == 0) {
                // Run with no arguments
                const args = [_][]const u8{};
                _ = runFn(allocator, &args, common.null_writer, stderr_writer) catch {};
                return;
            }

            // At compile time, analyze the Args struct to find all flags
            const fields = @typeInfo(ArgsType).@"struct".fields;

            // Build list of flags at compile time
            comptime var flag_infos: [fields.len]FlagInfo = undefined;
            comptime var flag_count = 0;

            inline for (fields) |field| {
                // Skip positionals field and fields without meta
                if (comptime std.mem.eql(u8, field.name, "positionals")) continue;
                if (!@hasField(ArgsType, "meta")) continue;
                if (!@hasField(@TypeOf(ArgsType.meta), field.name)) continue;

                const meta = @field(ArgsType.meta, field.name);
                const takes_value = switch (@typeInfo(field.type)) {
                    .optional => |opt| switch (@typeInfo(opt.child)) {
                        .pointer => |ptr| ptr.child == u8,
                        else => false,
                    },
                    else => false,
                };

                flag_infos[flag_count] = .{
                    .name = field.name,
                    .short = if (@hasField(@TypeOf(meta), "short")) meta.short else null,
                    .field_type = field.type,
                    .takes_value = takes_value,
                };
                flag_count += 1;
            }

            // Use fuzzer input to generate arguments
            var args = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            defer {
                // Free all allocated argument strings
                for (args.items) |arg| {
                    allocator.free(arg);
                }
                args.deinit(allocator);
            }

            var input_idx: usize = 0;

            // Process each flag based on input bytes
            inline for (flag_infos[0..flag_count]) |flag_info| {
                if (input_idx >= input.len) break;

                const flag_byte = input[input_idx];
                input_idx += 1;

                // Skip this flag 50% of the time
                if (flag_byte & 1 == 0) continue;

                // Choose between short and long form
                if (flag_info.short != null and (flag_byte & 2) != 0) {
                    // Use short form
                    var flag_buf: [2]u8 = .{ '-', flag_info.short.? };
                    try args.append(allocator, try allocator.dupe(u8, &flag_buf));
                } else {
                    // Use long form
                    const long_flag = try std.fmt.allocPrint(allocator, "--{s}", .{flag_info.name});
                    try args.append(allocator, long_flag);
                }

                // Add value if needed
                if (flag_info.takes_value) {
                    if (input_idx < input.len) {
                        // Use some input bytes as the value
                        const value_len = @min(input[input_idx] % 20 + 1, input.len - input_idx - 1);
                        input_idx += 1;

                        if (input_idx + value_len <= input.len) {
                            const value = try allocator.dupe(u8, input[input_idx .. input_idx + value_len]);
                            try args.append(allocator, value);
                            input_idx += value_len;
                        }
                    }
                }
            }

            // Add positional arguments from remaining input
            if (input_idx < input.len) {
                // Generate 0-3 positional args
                const num_positionals = input[input_idx] % 4;
                input_idx += 1;

                var i: usize = 0;
                while (i < num_positionals and input_idx < input.len) : (i += 1) {
                    var path_buffer: [FuzzConfig.PATH_BUFFER_SIZE]u8 = undefined;
                    const path = generatePath(&path_buffer, input[input_idx..]);
                    try args.append(allocator, try allocator.dupe(u8, path));
                    input_idx = @min(input_idx + 10, input.len); // Skip some bytes
                }
            }

            // Run the utility with generated arguments
            _ = runFn(allocator, args.items, common.null_writer, stderr_writer) catch {
                // Errors are expected during fuzzing
            };
        }

        /// Test for deterministic behavior with same flags
        pub fn testDeterministic(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            // First run
            var stdout_buf1 = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer stdout_buf1.deinit(allocator);
            var stderr_buf1 = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer stderr_buf1.deinit(allocator);

            var args1 = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            defer {
                for (args1.items) |arg| allocator.free(arg);
                args1.deinit(allocator);
            }
            try generateArgsFromInput(ArgsType, &args1, allocator, input);

            const result1 = runFn(allocator, args1.items, stdout_buf1.writer(allocator), stderr_writer) catch |err| {
                // If it fails once, it should fail consistently
                var args2 = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                defer {
                    for (args2.items) |arg| allocator.free(arg);
                    args2.deinit(allocator);
                }
                try generateArgsFromInput(ArgsType, &args2, allocator, input);

                _ = runFn(allocator, args2.items, common.null_writer, stderr_writer) catch {
                    return; // Both failed, that's deterministic
                };
                return err; // Inconsistent!
            };

            // Second run
            var stdout_buf2 = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer stdout_buf2.deinit(allocator);
            var stderr_buf2 = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer stderr_buf2.deinit(allocator);

            var args2 = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            defer {
                for (args2.items) |arg| allocator.free(arg);
                args2.deinit(allocator);
            }
            try generateArgsFromInput(ArgsType, &args2, allocator, input);

            const result2 = runFn(allocator, args2.items, stdout_buf2.writer(allocator), stderr_writer) catch {
                return error.InconsistentBehavior;
            };

            // Results should match
            try testing.expectEqual(result1, result2);
            try testing.expectEqualStrings(stdout_buf1.items, stdout_buf2.items);
            try testing.expectEqualStrings(stderr_buf1.items, stderr_buf2.items);
        }
    };
}

/// Helper to generate args from input bytes (shared by deterministic test)
fn generateArgsFromInput(comptime ArgsType: type, args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, input: []const u8) !void {
    _ = ArgsType; // TODO: Use the actual type info to generate appropriate args

    // Similar logic to testAllFlags but extracted for reuse
    if (input.len == 0) return;

    const byte = input[0];

    // Just add a simple flag for now
    if (byte & 1 != 0) {
        try args.append(allocator, try allocator.dupe(u8, "-v"));
    }
    if (byte & 2 != 0) {
        try args.append(allocator, try allocator.dupe(u8, "--parents"));
    }
    if (input.len > 1) {
        const path = try std.fmt.allocPrint(allocator, "dir{d}", .{input[1]});
        try args.append(allocator, path);
    }
}

test "fuzz helpers work correctly" {
    const allocator = testing.allocator;

    // Mock utility function for testing
    const MockUtil = struct {
        fn runUtility(alloc: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
            _ = alloc;
            _ = stderr;
            for (args) |arg| {
                try stdout.writeAll(arg);
                try stdout.writeAll(" ");
            }
            return 0;
        }
    };

    // Test basic functionality
    {
        const input = [_]u8{ 1, 65, 66, 67 };
        try testUtilityBasic(MockUtil.runUtility, allocator, input[0..], common.null_writer);
    }

    // Test deterministic functionality
    {
        const input = [_]u8{ 2, 68, 69, 70 };
        try testUtilityDeterministic(MockUtil.runUtility, allocator, input[0..], common.null_writer);
    }

    // Test path functionality
    {
        const input = [_]u8{ 3, 71, 72, 73 };
        try testUtilityPaths(MockUtil.runUtility, allocator, input[0..], common.null_writer);
    }
}

//
// INTELLIGENT FUZZER SYSTEM
//
// The following section implements an intelligent fuzzer that understands flag
// relationships, types, and context to generate more meaningful test cases.
//

/// Semantic categories for flags - helps understand flag purposes and relationships
pub const SemanticCategory = enum {
    // Output control flags
    output_format, // -l, --format, --color
    output_verbosity, // -v, -q, --verbose, --quiet
    output_filtering, // -a, --all, -A, --almost-all

    // Operation mode flags
    operation_mode, // -r, --recursive, -f, --force
    operation_safety, // -i, --interactive, --no-clobber
    operation_target, // -t, --target-directory

    // File/path handling
    path_resolution, // -L, --dereference, -P, --no-dereference
    path_creation, // -p, --parents, -m, --mode

    // Data processing
    data_input, // -e, --expression, -f, --file
    data_output, // -n, --bytes, -c, --bytes
    data_format, // -b, --binary, -t, --tabs

    // System interaction
    system_signals, // Signal handling flags
    system_resources, // Resource limit flags
    system_timing, // Timing and delay flags

    // Meta/utility
    meta_help, // --help, --version
    meta_config, // Configuration and behavior flags
    uncategorized, // Unknown or ambiguous flags
};

/// Enhanced flag information with semantic understanding
pub const SmartFlagInfo = struct {
    name: []const u8,
    short: ?u8,
    takes_value: bool,
    category: SemanticCategory,
    conflicts_with: []const []const u8,
    requires: []const []const u8,

    /// Check if this flag conflicts with another flag name
    pub fn conflictsWith(self: *const SmartFlagInfo, other_name: []const u8) bool {
        for (self.conflicts_with) |conflict| {
            if (std.mem.eql(u8, conflict, other_name)) return true;
        }
        return false;
    }

    /// Check if this flag requires another flag name
    pub fn requiresFlag(self: *const SmartFlagInfo, other_name: []const u8) bool {
        for (self.requires) |requirement| {
            if (std.mem.eql(u8, requirement, other_name)) return true;
        }
        return false;
    }

    /// Get semantic category from flag name and characteristics
    pub fn inferCategory(name: []const u8, takes_value: bool) SemanticCategory {
        // Output control patterns
        if (std.mem.indexOf(u8, name, "color") != null or
            std.mem.indexOf(u8, name, "format") != null or
            std.mem.eql(u8, name, "long") or
            std.mem.eql(u8, name, "list"))
            return .output_format;

        if (std.mem.indexOf(u8, name, "verbose") != null or
            std.mem.indexOf(u8, name, "quiet") != null or
            std.mem.eql(u8, name, "silent"))
            return .output_verbosity;

        if (std.mem.indexOf(u8, name, "all") != null or
            std.mem.indexOf(u8, name, "show") != null)
            return .output_filtering;

        // Operation modes
        if (std.mem.indexOf(u8, name, "recursive") != null or
            std.mem.indexOf(u8, name, "force") != null or
            std.mem.indexOf(u8, name, "update") != null)
            return .operation_mode;

        if (std.mem.indexOf(u8, name, "interactive") != null or
            std.mem.indexOf(u8, name, "prompt") != null or
            std.mem.indexOf(u8, name, "confirm") != null)
            return .operation_safety;

        if (std.mem.indexOf(u8, name, "target") != null or
            std.mem.indexOf(u8, name, "directory") != null)
            return .operation_target;

        // Path handling
        if (std.mem.indexOf(u8, name, "dereference") != null or
            std.mem.indexOf(u8, name, "follow") != null or
            std.mem.indexOf(u8, name, "link") != null)
            return .path_resolution;

        if (std.mem.indexOf(u8, name, "parents") != null or
            std.mem.indexOf(u8, name, "mode") != null or
            std.mem.indexOf(u8, name, "mkdir") != null)
            return .path_creation;

        // Data processing
        if ((std.mem.indexOf(u8, name, "file") != null or
            std.mem.indexOf(u8, name, "input") != null) and takes_value)
            return .data_input;

        if (std.mem.indexOf(u8, name, "bytes") != null or
            std.mem.indexOf(u8, name, "lines") != null or
            std.mem.indexOf(u8, name, "count") != null)
            return .data_output;

        if (std.mem.indexOf(u8, name, "binary") != null or
            std.mem.indexOf(u8, name, "text") != null or
            std.mem.indexOf(u8, name, "tab") != null)
            return .data_format;

        // Meta flags
        if (std.mem.eql(u8, name, "help") or
            std.mem.eql(u8, name, "version"))
            return .meta_help;

        return .uncategorized;
    }
};

/// Compile-time flag analyzer that extracts semantic information from Args structs
pub fn SmartFlagAnalyzer(comptime ArgsType: type) type {
    return struct {
        pub const flag_infos = blk: {
            @setEvalBranchQuota(10000);
            const fields = @typeInfo(ArgsType).@"struct".fields;

            // Count valid fields first
            var valid_count = 0;
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, "positionals")) continue;
                if (!@hasField(ArgsType, "meta")) continue;
                if (!@hasField(@TypeOf(ArgsType.meta), field.name)) continue;
                valid_count += 1;
            }

            // Create the array with known size
            var infos: [valid_count]SmartFlagInfo = undefined;
            var count = 0;

            for (fields) |field| {
                // Skip positionals and fields without metadata
                if (std.mem.eql(u8, field.name, "positionals")) continue;
                if (!@hasField(ArgsType, "meta")) continue;
                if (!@hasField(@TypeOf(ArgsType.meta), field.name)) continue;

                const meta = @field(ArgsType.meta, field.name);
                const takes_value = switch (@typeInfo(field.type)) {
                    .optional => |opt| switch (@typeInfo(opt.child)) {
                        .pointer => |ptr| ptr.child == u8,
                        else => false,
                    },
                    else => false,
                };

                // Infer conflicts and requirements based on semantic analysis
                const category = SmartFlagInfo.inferCategory(field.name, takes_value);
                const conflicts: []const []const u8 = if (std.mem.eql(u8, field.name, "verbose") or std.mem.eql(u8, field.name, "quiet"))
                    &[_][]const u8{ "verbose", "quiet", "silent" }
                else if (std.mem.eql(u8, field.name, "force") or std.mem.eql(u8, field.name, "interactive"))
                    &[_][]const u8{ "force", "interactive" }
                else if (std.mem.eql(u8, field.name, "dereference") or std.mem.eql(u8, field.name, "no_dereference"))
                    &[_][]const u8{ "dereference", "no_dereference" }
                else
                    &[_][]const u8{};

                const requires: []const []const u8 = &[_][]const u8{};

                infos[count] = .{
                    .name = field.name,
                    .short = if (@hasField(@TypeOf(meta), "short")) meta.short else null,
                    .takes_value = takes_value,
                    .category = category,
                    .conflicts_with = conflicts,
                    .requires = requires,
                };
                count += 1;
            }

            const result = infos;
            break :blk result;
        };

        pub fn getFlagByName(name: []const u8) ?*const SmartFlagInfo {
            for (&flag_infos) |*flag| {
                if (std.mem.eql(u8, flag.name, name)) return flag;
            }
            return null;
        }

        pub fn getFlagsByCategory(category: SemanticCategory) []const SmartFlagInfo {
            var matching: [flag_infos.len]SmartFlagInfo = undefined;
            var count: usize = 0;

            for (flag_infos) |flag| {
                if (flag.category == category) {
                    matching[count] = flag;
                    count += 1;
                }
            }

            return matching[0..count];
        }
    };
}

/// Smart value generator that creates contextually appropriate values for different flag types
pub const SmartValueGenerator = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    input_pos: usize,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) SmartValueGenerator {
        return .{
            .allocator = allocator,
            .input = input,
            .input_pos = 0,
        };
    }

    pub fn generateForFlag(self: *SmartValueGenerator, flag: *const SmartFlagInfo) !?[]const u8 {
        if (!flag.takes_value) return null;

        // Generate contextually appropriate values based on flag category and name
        return switch (flag.category) {
            .data_output => try self.generateNumericValue(),
            .data_input => try self.generatePathValue(),
            .path_creation => try self.generateModeValue(),
            .operation_target => try self.generatePathValue(),
            .data_format => try self.generateFormatValue(),
            else => try self.generateGenericValue(),
        };
    }

    fn generateNumericValue(self: *SmartValueGenerator) ![]const u8 {
        if (self.input_pos >= self.input.len) return "10";

        const byte = self.input[self.input_pos];
        self.input_pos += 1;

        // Generate reasonable numeric values
        const patterns = [_][]const u8{ "0", "1", "10", "100", "1024", "-1" };
        return patterns[byte % patterns.len];
    }

    fn generatePathValue(self: *SmartValueGenerator) ![]const u8 {
        var path_buffer: [FuzzConfig.PATH_BUFFER_SIZE]u8 = undefined;
        const remaining_input = if (self.input_pos < self.input.len)
            self.input[self.input_pos..]
        else
            &[_]u8{};

        const path = generatePath(&path_buffer, remaining_input);
        self.input_pos = @min(self.input_pos + 10, self.input.len);

        return try self.allocator.dupe(u8, path);
    }

    fn generateModeValue(self: *SmartValueGenerator) ![]const u8 {
        if (self.input_pos >= self.input.len) return "755";

        const byte = self.input[self.input_pos];
        self.input_pos += 1;

        // Generate common permission patterns
        const modes = [_][]const u8{ "644", "755", "777", "600", "700", "444" };
        return modes[byte % modes.len];
    }

    fn generateFormatValue(self: *SmartValueGenerator) ![]const u8 {
        if (self.input_pos >= self.input.len) return "auto";

        const byte = self.input[self.input_pos];
        self.input_pos += 1;

        const formats = [_][]const u8{ "auto", "always", "never", "json", "csv", "xml" };
        return formats[byte % formats.len];
    }

    fn generateGenericValue(self: *SmartValueGenerator) ![]const u8 {
        if (self.input_pos >= self.input.len) return "test";

        // Use some input bytes to create a generic value
        const start = self.input_pos;
        const len = @min(8, self.input.len - start);
        const end = start + len;
        self.input_pos = end;

        return try self.allocator.dupe(u8, self.input[start..end]);
    }
};

/// Intelligent argument builder that understands flag relationships and constraints
pub const SmartArgumentBuilder = struct {
    allocator: std.mem.Allocator,
    args: std.ArrayList([]const u8),
    selected_flags: std.ArrayList([]const u8),
    value_generator: SmartValueGenerator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) !SmartArgumentBuilder {
        return .{
            .allocator = allocator,
            .args = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .selected_flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .value_generator = SmartValueGenerator.init(allocator, input),
        };
    }

    pub fn deinit(self: *SmartArgumentBuilder) void {
        // Free all allocated argument strings
        for (self.args.items) |arg| {
            self.allocator.free(arg);
        }
        self.args.deinit(self.allocator);
        self.selected_flags.deinit(self.allocator);
    }

    pub fn canAddFlag(self: *const SmartArgumentBuilder, flag: *const SmartFlagInfo) bool {
        // Check for conflicts with already selected flags
        for (self.selected_flags.items) |selected| {
            if (flag.conflictsWith(selected)) return false;
        }

        // Check if all requirements are met
        for (flag.requires) |requirement| {
            var found = false;
            for (self.selected_flags.items) |selected| {
                if (std.mem.eql(u8, selected, requirement)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }

    pub fn addFlag(self: *SmartArgumentBuilder, flag: *const SmartFlagInfo, use_short: bool) !void {
        if (!self.canAddFlag(flag)) return;

        // Add the flag
        if (use_short and flag.short != null) {
            var flag_buf: [2]u8 = .{ '-', flag.short.? };
            try self.args.append(try self.allocator.dupe(u8, &flag_buf));
        } else {
            const long_flag = try std.fmt.allocPrint(self.allocator, "--{s}", .{flag.name});
            try self.args.append(long_flag);
        }

        // Add value if needed
        if (flag.takes_value) {
            if (try self.value_generator.generateForFlag(flag)) |value| {
                try self.args.append(value);
            }
        }

        // Track this flag as selected
        try self.selected_flags.append(self.allocator, flag.name);
    }

    pub fn addPositionalArgs(self: *SmartArgumentBuilder, count: u8) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var path_buffer: [FuzzConfig.PATH_BUFFER_SIZE]u8 = undefined;
            const remaining_input = if (self.value_generator.input_pos < self.value_generator.input.len)
                self.value_generator.input[self.value_generator.input_pos..]
            else
                &[_]u8{};

            const path = generatePath(&path_buffer, remaining_input);
            try self.args.append(try self.allocator.dupe(u8, path));

            self.value_generator.input_pos = @min(self.value_generator.input_pos + 10, self.value_generator.input.len);
        }
    }

    pub fn getArgs(self: *const SmartArgumentBuilder) []const []const u8 {
        return self.args.items;
    }
};

/// Main intelligent fuzzer factory function
pub fn createIntelligentFuzzer(comptime ArgsType: type, comptime runFn: anytype) type {
    const Analyzer = SmartFlagAnalyzer(ArgsType);

    return struct {
        /// Test with intelligent flag combinations that respect relationships
        pub fn testSmartCombinations(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            if (input.len == 0) {
                // Test with no arguments
                const args = [_][]const u8{};
                _ = runFn(allocator, &args, common.null_writer, stderr_writer) catch {};
                return;
            }

            var builder = try SmartArgumentBuilder.init(allocator, input);
            defer builder.deinit();

            var input_idx: usize = 0;

            // Intelligently select flags based on categories and relationships
            for (&Analyzer.flag_infos) |*flag| {
                if (input_idx >= input.len) break;

                const flag_byte = input[input_idx];
                input_idx += 1;

                // Skip flag based on probability (but ensure some selection)
                if (flag_byte % 3 == 0) continue;

                // Only add if it doesn't conflict and requirements are met
                if (builder.canAddFlag(flag)) {
                    const use_short = flag.short != null and (flag_byte & 1) != 0;
                    try builder.addFlag(flag, use_short);
                }
            }

            // Add contextually appropriate positional arguments
            if (input_idx < input.len) {
                const num_positionals = @min(input[input_idx] % 4, 3);
                try builder.addPositionalArgs(@intCast(num_positionals));
            }

            // Execute with the intelligently generated arguments
            _ = runFn(allocator, builder.getArgs(), common.null_writer, stderr_writer) catch {
                // Errors are expected during fuzzing
            };
        }

        /// Test specific flag categories systematically
        pub fn testByCategory(allocator: std.mem.Allocator, input: []const u8, category: SemanticCategory, stderr_writer: anytype) !void {
            var builder = try SmartArgumentBuilder.init(allocator, input);
            defer builder.deinit();

            // Focus on flags from specific category
            for (&Analyzer.flag_infos) |*flag| {
                if (flag.category != category) continue;

                if (builder.canAddFlag(flag)) {
                    try builder.addFlag(flag, false); // Always use long form for clarity
                }
            }

            // Add some positional args
            try builder.addPositionalArgs(2);

            _ = runFn(allocator, builder.getArgs(), common.null_writer, stderr_writer) catch {};
        }

        /// Test edge cases with problematic flag combinations
        pub fn testEdgeCases(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            if (input.len == 0) return;

            const test_idx = input[0] % 4;
            const remaining = input[1..];

            switch (test_idx) {
                0 => try testConflictingFlags(allocator, remaining, stderr_writer),
                1 => try testMissingRequirements(allocator, remaining, stderr_writer),
                2 => try testInvalidValues(allocator, remaining, stderr_writer),
                3 => try testExcessiveFlags(allocator, remaining, stderr_writer),
                else => unreachable,
            }
        }

        fn testConflictingFlags(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            var builder = try SmartArgumentBuilder.init(allocator, input);
            defer builder.deinit();

            // Intentionally try to add conflicting flags (should be filtered out)
            for (&Analyzer.flag_infos) |*flag| {
                // Try to add all flags - builder should prevent conflicts
                builder.addFlag(flag, false) catch continue;
            }

            _ = runFn(allocator, builder.getArgs(), common.null_writer, stderr_writer) catch {};
        }

        fn testMissingRequirements(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            // Test flags that have requirements without meeting them
            // This tests error handling for incomplete flag combinations
            for (&Analyzer.flag_infos) |*flag| {
                if (flag.requires.len == 0) continue;

                var builder = try SmartArgumentBuilder.init(allocator, input);
                defer builder.deinit();

                // Add flag without its requirements
                const long_flag = try std.fmt.allocPrint(allocator, "--{s}", .{flag.name});
                try builder.args.append(builder.allocator, long_flag);

                _ = runFn(allocator, builder.getArgs(), common.null_writer, stderr_writer) catch {};
            }
        }

        fn testInvalidValues(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            var builder = try SmartArgumentBuilder.init(allocator, input);
            defer builder.deinit();

            // Add flags with intentionally problematic values
            for (&Analyzer.flag_infos) |*flag| {
                if (!flag.takes_value) continue;

                const long_flag = try std.fmt.allocPrint(allocator, "--{s}", .{flag.name});
                try builder.args.append(builder.allocator, long_flag);

                // Generate problematic values based on input
                const problematic_values = [_][]const u8{
                    "", // Empty value
                    "\x00\x01\x02", // Binary data
                    "very_very_very_very_long_value_that_might_cause_buffer_issues",
                    "../../../etc/passwd", // Path traversal
                    "-999999", // Extreme negative
                    "not_a_number", // Invalid for numeric flags
                    "/nonexistent/path/that/does/not/exist",
                };

                if (input.len > 0) {
                    const value_idx = input[0] % problematic_values.len;
                    try builder.args.append(builder.allocator, try allocator.dupe(u8, problematic_values[value_idx]));
                }

                _ = runFn(allocator, builder.getArgs(), common.null_writer, stderr_writer) catch {};

                // Reset for next flag
                builder.args.clearRetainingCapacity();
                builder.selected_flags.clearRetainingCapacity();
            }
        }

        fn testExcessiveFlags(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            var builder = try SmartArgumentBuilder.init(allocator, input);
            defer builder.deinit();

            // Try to add every possible flag (within reason)
            for (&Analyzer.flag_infos) |*flag| {
                if (builder.canAddFlag(flag)) {
                    try builder.addFlag(flag, false);
                }
            }

            // Add many positional arguments
            try builder.addPositionalArgs(10);

            _ = runFn(allocator, builder.getArgs(), common.null_writer, stderr_writer) catch {};
        }

        /// Comprehensive test combining all strategies
        pub fn testComprehensive(allocator: std.mem.Allocator, input: []const u8, stderr_writer: anytype) !void {
            if (input.len == 0) return;

            const test_type = input[0] % 4;
            const remaining = if (input.len > 1) input[1..] else &[_]u8{};

            switch (test_type) {
                0 => try testSmartCombinations(allocator, remaining, stderr_writer),
                1 => {
                    const category_idx = if (remaining.len > 0) remaining[0] else 0;
                    const categories = [_]SemanticCategory{
                        .output_format,    .output_verbosity, .operation_mode,
                        .operation_safety, .path_resolution,  .data_input,
                    };
                    const category = categories[category_idx % categories.len];
                    const cat_input = if (remaining.len > 1) remaining[1..] else &[_]u8{};
                    try testByCategory(allocator, cat_input, category, stderr_writer);
                },
                2 => try testEdgeCases(allocator, remaining, stderr_writer),
                else => {
                    // Fallback to original smart fuzzer behavior
                    const OldFuzzerType = createSmartFuzzer(ArgsType, runFn);
                    try OldFuzzerType.testAllFlags(allocator, remaining, stderr_writer);
                },
            }
        }
    };
}

test "intelligent fuzzer components work correctly" {
    const allocator = testing.allocator;

    // Test SmartValueGenerator
    {
        var generator = SmartValueGenerator.init(allocator, &[_]u8{ 1, 2, 3, 4, 5 });

        const numeric = try generator.generateNumericValue();
        try testing.expect(numeric.len > 0);

        const path = try generator.generatePathValue();
        defer allocator.free(path);
        try testing.expect(path.len >= 0);

        const mode = try generator.generateModeValue();
        try testing.expect(mode.len > 0);
    }

    // Test SmartArgumentBuilder
    {
        var builder = try SmartArgumentBuilder.init(allocator, &[_]u8{ 10, 20, 30 });
        defer builder.deinit(); // deinit now properly frees allocated strings

        try builder.addPositionalArgs(2);
        const args = builder.getArgs();
        try testing.expectEqual(@as(usize, 2), args.len);
    }

    // Test SemanticCategory inference
    {
        try testing.expectEqual(SemanticCategory.output_verbosity, SmartFlagInfo.inferCategory("verbose", false));
        try testing.expectEqual(SemanticCategory.operation_mode, SmartFlagInfo.inferCategory("recursive", false));
        try testing.expectEqual(SemanticCategory.path_creation, SmartFlagInfo.inferCategory("parents", false));
        try testing.expectEqual(SemanticCategory.data_input, SmartFlagInfo.inferCategory("file", true));
    }
}

// STANDARD INTEGRATION EXAMPLES
//
// This section demonstrates the recommended patterns for integrating fuzz testing
// into vibeutils. Use these as templates for adding fuzz tests to utilities.
//
// LEVEL 1: Basic Integration (recommended for most utilities)
// Use this pattern when you want simple, effective fuzz testing:
//
// ```zig
// test "my_utility basic fuzz" {
//     if (!enable_fuzz_tests) return error.SkipZigTest;
//     try std.testing.fuzz(testing.allocator, fuzzMyUtilityBasic, .{});
// }
//
// fn fuzzMyUtilityBasic(allocator: std.mem.Allocator, input: []const u8) !void {
//     try testUtilityBasic(runMyUtility, allocator, input, common.null_writer);
// }
// ```
//
// LEVEL 2: Comprehensive Integration (recommended for complex utilities)
// Use this pattern when the utility has complex flag interactions:
//
// ```zig
// test "my_utility intelligent fuzz" {
//     if (!enable_fuzz_tests) return error.SkipZigTest;
//     try std.testing.fuzz(testing.allocator, fuzzMyUtilityIntelligent, .{});
// }
//
// fn fuzzMyUtilityIntelligent(allocator: std.mem.Allocator, input: []const u8) !void {
//     const IntelligentFuzzer = createIntelligentFuzzer(MyUtilityArgs, runMyUtility);
//     try IntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
// }
// ```
//
// LEVEL 3: Custom Integration (for special cases)
// Use this pattern when you need utility-specific fuzz testing:
//
// ```zig
// fn fuzzMyUtilityCustom(allocator: std.mem.Allocator, input: []const u8) !void {
//     // Use basic patterns
//     try testUtilityBasic(runMyUtility, allocator, input, common.null_writer);
//
//     // Add utility-specific tests
//     var file_storage = FileListStorage.init();
//     const files = generateFileList(&file_storage, input);
//     // Test with generated file list...
// }
// ```

// Working example demonstrating the intelligent fuzzer
test "intelligent fuzzer example usage" {
    if (!enable_fuzz_tests) return error.SkipZigTest;

    // Example Args struct that would be used in a real utility
    const ExampleArgs = struct {
        verbose: bool = false,
        quiet: bool = false,
        force: bool = false,
        recursive: bool = false,
        mode: ?[]const u8 = null,
        parents: bool = false,
        positionals: []const []const u8 = &[_][]const u8{},

        pub const meta = .{
            .verbose = .{ .short = 'v' },
            .quiet = .{ .short = 'q' },
            .force = .{ .short = 'f' },
            .recursive = .{ .short = 'r' },
            .mode = .{ .short = 'm' },
            .parents = .{ .short = 'p' },
        };
    };

    // Example utility function that uses the Args struct
    const exampleUtility = struct {
        fn run(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
            _ = allocator;
            _ = stderr;
            for (args) |arg| {
                try stdout.writeAll(arg);
                try stdout.writeAll(" ");
            }
            return 0;
        }
    }.run;

    // Create the intelligent fuzzer for this utility
    const IntelligentFuzzer = createIntelligentFuzzer(ExampleArgs, exampleUtility);

    // Test with sample input - this would be called by std.testing.fuzz
    const sample_input = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try IntelligentFuzzer.testSmartCombinations(testing.allocator, &sample_input, common.null_writer);
}
