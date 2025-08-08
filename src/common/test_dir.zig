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
//! try test_dir.setup();
//!
//! try test_dir.createFile("test.txt", "content", null);
//! try test_dir.expectFileContent("test.txt", "content");
//! ```
//!
//! # Features
//!
//! - Automatic temporary directory creation and cleanup
//! - File and directory creation with optional mode settings
//! - Symbolic link creation and target verification
//! - Content verification helpers
//! - Working directory management for tests

const std = @import("std");
const testing = std.testing;

/// Test directory helper for managing temporary file systems in tests
pub const TestDir = struct {
    tmp_dir: testing.TmpDir,
    allocator: std.mem.Allocator,
    original_cwd: ?std.fs.Dir,

    /// Initialize a test directory
    pub fn init(allocator: std.mem.Allocator) TestDir {
        return TestDir{
            .tmp_dir = testing.tmpDir(.{}),
            .allocator = allocator,
            .original_cwd = null,
        };
    }

    /// Clean up test directory and restore original working directory
    pub fn deinit(self: *TestDir) void {
        // Restore original directory
        if (self.original_cwd) |*cwd| {
            std.posix.fchdir(cwd.fd) catch {};
            cwd.close();
        }
        self.tmp_dir.cleanup();
    }

    /// Set up test directory as current working directory
    pub fn setup(self: *TestDir) !void {
        // Save current directory
        self.original_cwd = std.fs.cwd().openDir(".", .{}) catch null;
        // Change to test directory
        try std.posix.fchdir(self.tmp_dir.dir.fd);
    }

    /// Create a file with specified content and optional mode
    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8, mode: ?std.fs.File.Mode) !void {
        const file_options = if (mode) |m| std.fs.File.CreateFlags{ .mode = m } else std.fs.File.CreateFlags{};
        const file = try self.tmp_dir.dir.createFile(name, file_options);
        defer file.close();
        try file.writeAll(content);
    }

    /// Create a directory
    pub fn createDir(self: *TestDir, name: []const u8) !void {
        try self.tmp_dir.dir.makeDir(name);
    }

    /// Create a symbolic link
    pub fn createSymlink(self: *TestDir, target: []const u8, link_name: []const u8) !void {
        try self.tmp_dir.dir.symLink(target, link_name, .{});
    }

    /// Check if a file exists
    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        self.tmp_dir.dir.access(name, .{}) catch return false;
        return true;
    }

    /// Read entire file contents into allocated memory
    pub fn readFileAlloc(self: *TestDir, name: []const u8) ![]u8 {
        const file = try self.tmp_dir.dir.openFile(name, .{});
        defer file.close();
        const file_size = try file.getEndPos();
        const contents = try self.allocator.alloc(u8, file_size);
        _ = try file.readAll(contents);
        return contents;
    }

    /// Verify file content matches expected content
    pub fn expectFileContent(self: *TestDir, name: []const u8, expected: []const u8) !void {
        const actual = try self.readFileAlloc(name);
        defer self.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    /// Check if a path is a symbolic link
    pub fn isSymlink(self: *TestDir, name: []const u8) !bool {
        var test_buf: [1]u8 = undefined;
        _ = self.tmp_dir.dir.readLink(name, &test_buf) catch |err| switch (err) {
            error.NotLink => return false,
            else => return err,
        };
        return true;
    }

    /// Get the target of a symbolic link
    pub fn getSymlinkTarget(self: *TestDir, name: []const u8) ![]u8 {
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = try self.tmp_dir.dir.readLink(name, &target_buf);
        return try self.allocator.dupe(u8, target);
    }

    /// Get file statistics
    pub fn getFileStat(self: *TestDir, name: []const u8) !std.fs.File.Stat {
        return try self.tmp_dir.dir.statFile(name);
    }
};

// Tests for TestDir functionality

test "TestDir: basic file operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("test.txt", "Hello, World!", null);
    try testing.expect(test_dir.fileExists("test.txt"));
    try test_dir.expectFileContent("test.txt", "Hello, World!");
}

test "TestDir: directory operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createDir("test_dir");
    try testing.expect(test_dir.fileExists("test_dir"));

    const stat = try test_dir.getFileStat("test_dir");
    try testing.expectEqual(std.fs.File.Kind.directory, stat.kind);
}

test "TestDir: symbolic link operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

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
    try test_dir.setup();

    try test_dir.createFile("mode_test.txt", "Content", 0o644);
    const stat = try test_dir.getFileStat("mode_test.txt");

    // Check user permissions (works without privileges)
    const user_perms = stat.mode & 0o700;
    try testing.expectEqual(@as(u32, 0o600), user_perms);
}
