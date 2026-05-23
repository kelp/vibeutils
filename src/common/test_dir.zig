//! Test directory utilities for managing temporary file systems in tests
//!
//! This module provides TestDir, a comprehensive helper for creating temporary
//! file systems in tests with automatic cleanup. It supports file creation,
//! directory creation, symlinks, and various file system operations needed
//! for testing file utilities.
//!
//! # Basic Usage
//!
//! ```zig
//! var test_dir = TestDir.init(testing.allocator);
//! defer test_dir.deinit();
//!
//! try test_dir.createFile("test.txt", "content", null);
//! try test_dir.expectFileContent("test.txt", "content");
//!
//! // Get absolute paths for passing to utilities under test
//! const path = try test_dir.getPath("test.txt");
//! defer testing.allocator.free(path);
//! ```
//!
//! # Features
//!
//! - Automatic temporary directory creation and cleanup
//! - File and directory creation with optional mode settings
//! - Symbolic link creation and target verification
//! - Content verification helpers
//! - Absolute path resolution via getPath/getBasePath (parallel-test safe)

const std = @import("std");
const testing = std.testing;

/// Test directory helper for managing temporary file systems in tests
pub const TestDir = struct {
    tmp_dir: testing.TmpDir,
    allocator: std.mem.Allocator,

    /// Initialize a test directory
    pub fn init(allocator: std.mem.Allocator) TestDir {
        return TestDir{
            .tmp_dir = testing.tmpDir(.{}),
            .allocator = allocator,
        };
    }

    /// Clean up test directory
    pub fn deinit(self: *TestDir) void {
        self.tmp_dir.cleanup();
    }

    /// Get the absolute path of a file in the temp directory
    pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
        const io = testing.io;
        // realPathFileAlloc returns [:0]u8 (sentinel-terminated); dupe strips the
        // sentinel so callers can free via allocator.free([]u8) without size mismatch.
        const sentinel_path = try self.tmp_dir.dir.realPathFileAlloc(io, name, self.allocator);
        defer self.allocator.free(sentinel_path);
        return try self.allocator.dupe(u8, sentinel_path[0..sentinel_path.len]);
    }

    /// Get the absolute path of the temp directory itself
    pub fn getBasePath(self: *TestDir) ![]u8 {
        const io = testing.io;
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp_dir.dir.realPath(io, &buf);
        return try self.allocator.dupe(u8, buf[0..len]);
    }

    /// Create a file with specified content and optional mode
    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8, mode: ?std.posix.mode_t) !void {
        const io = testing.io;
        const file_options: std.Io.Dir.CreateFileOptions = if (mode) |m|
            .{ .permissions = std.Io.File.Permissions.fromMode(m) }
        else
            .{};
        const file = try self.tmp_dir.dir.createFile(io, name, file_options);
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    /// Create a directory
    pub fn createDir(self: *TestDir, name: []const u8) !void {
        const io = testing.io;
        try self.tmp_dir.dir.createDir(io, name, .default_dir);
    }

    /// Create a symbolic link
    pub fn createSymlink(self: *TestDir, target: []const u8, link_name: []const u8) !void {
        const io = testing.io;
        try self.tmp_dir.dir.symLink(io, target, link_name, .{});
    }

    /// Check if a file exists
    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        const io = testing.io;
        self.tmp_dir.dir.access(io, name, .{}) catch return false;
        return true;
    }

    /// Read entire file contents into allocated memory
    pub fn readFileAlloc(self: *TestDir, name: []const u8) ![]u8 {
        const io = testing.io;
        return self.tmp_dir.dir.readFileAlloc(io, name, self.allocator, .unlimited);
    }

    /// Verify file content matches expected content
    pub fn expectFileContent(self: *TestDir, name: []const u8, expected: []const u8) !void {
        const actual = try self.readFileAlloc(name);
        defer self.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    /// Check if a path is a symbolic link
    pub fn isSymlink(self: *TestDir, name: []const u8) !bool {
        const io = testing.io;
        var test_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        _ = self.tmp_dir.dir.readLink(io, name, &test_buf) catch |err| switch (err) {
            error.NotLink => return false,
            else => return err,
        };
        return true;
    }

    /// Get the target of a symbolic link
    pub fn getSymlinkTarget(self: *TestDir, name: []const u8) ![]u8 {
        const io = testing.io;
        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp_dir.dir.readLink(io, name, &target_buf);
        return try self.allocator.dupe(u8, target_buf[0..len]);
    }

    /// Get file statistics
    pub fn getFileStat(self: *TestDir, name: []const u8) !std.Io.File.Stat {
        const io = testing.io;
        return try self.tmp_dir.dir.statFile(io, name, .{});
    }
};

// Tests for TestDir functionality

test "TestDir: basic file operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("test.txt", "Hello, World!", null);
    try testing.expect(test_dir.fileExists("test.txt"));
    try test_dir.expectFileContent("test.txt", "Hello, World!");
}

test "TestDir: directory operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("test_dir");
    try testing.expect(test_dir.fileExists("test_dir"));

    const stat = try test_dir.getFileStat("test_dir");
    try testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "TestDir: symbolic link operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("target.txt", "Target content", null);
    try test_dir.createSymlink("target.txt", "link.txt");

    try testing.expect(try test_dir.isSymlink("link.txt"));
    try testing.expect(!try test_dir.isSymlink("target.txt"));

    const target = try test_dir.getSymlinkTarget("link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("target.txt", target);
}

test "TestDir: file with mode" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("mode_test.txt", "Content", 0o644);
    const stat = try test_dir.getFileStat("mode_test.txt");

    // Check user permissions (works without privileges)
    const user_perms = stat.mode & 0o700;
    try testing.expectEqual(@as(u32, 0o600), user_perms);
}
