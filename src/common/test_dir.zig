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
//! - Absolute path resolution via getPath/getBasePath/join (parallel-test safe)

const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");

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

    /// The sandbox directory handle. Callers that need iterate/openFile/access
    /// reach through this rather than wrapping every Dir method.
    pub fn dir(self: *TestDir) std.Io.Dir {
        const handle = self.tmp_dir.dir.handle;
        std.debug.assert(handle >= 0);
        std.debug.assert(handle != std.posix.AT.FDCWD);
        return self.tmp_dir.dir;
    }

    /// Get the absolute path of a file in the temp directory.
    /// `"."` is the sandbox root itself (same as `getBasePath`).
    pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, ".")) {
            return self.getBasePath();
        }
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

    /// Join a relative name onto the sandbox without requiring it to exist.
    /// `getPath` realpaths and fails for a dest that has not been created yet.
    pub fn join(self: *TestDir, rel: []const u8) ![]u8 {
        std.debug.assert(rel.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(rel));
        const base = try self.getBasePath();
        defer self.allocator.free(base);
        return try std.fs.path.join(self.allocator, &.{ base, rel });
    }

    /// Create a file with specified content and optional mode
    pub fn createFile(
        self: *TestDir,
        name: []const u8,
        content: []const u8,
        mode: ?std.posix.mode_t,
    ) !void {
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

    /// Create nested directories; parents that do not exist are created too.
    pub fn createDirPath(self: *TestDir, name: []const u8) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(name));
        try self.tmp_dir.dir.createDirPath(testing.io, name);
    }

    /// Create a uniquely named file and return the allocated basename.
    pub fn createUniqueFile(self: *TestDir, base: []const u8, content: []const u8) ![]u8 {
        std.debug.assert(base.len > 0);
        std.debug.assert(std.mem.indexOfScalar(u8, base, '/') == null);
        return try test_utils.createUniqueTestFile(
            testing.io,
            self.tmp_dir.dir,
            self.allocator,
            base,
            content,
        );
    }

    /// Change process cwd to the sandbox. Returns a handle to the prior cwd.
    /// Allowlisted cwd-behavior tests only; restore with `restoreCwd`.
    pub fn chdirToBase(self: *TestDir) !std.Io.Dir {
        const io = testing.io;
        var saved = try std.Io.Dir.cwd().openDir(io, ".", .{});
        errdefer saved.close(io);

        const tmp_abs = try self.getBasePath();
        defer self.allocator.free(tmp_abs);
        std.debug.assert(tmp_abs.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(tmp_abs));
        try std.Io.Threaded.chdir(tmp_abs);

        return saved;
    }

    /// Restore process cwd from a handle returned by `chdirToBase`, then close
    /// it. Panics on failure so a later test cannot run in a deleted sandbox.
    pub fn restoreCwd(saved: *std.Io.Dir) void {
        const io = testing.io;
        std.debug.assert(saved.handle >= 0);
        std.debug.assert(saved.handle != std.posix.AT.FDCWD);
        std.process.setCurrentDir(io, saved.*) catch
            @panic("failed to restore test cwd");
        saved.close(io);
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
    const user_perms: u32 = @intCast(stat.permissions.toMode() & 0o700);
    try testing.expectEqual(@as(u32, 0o600), user_perms);
}

test "TestDir: dir() is a real sandbox fd" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const sandbox = test_dir.dir();
    try testing.expect(sandbox.handle >= 0);
    try testing.expect(sandbox.handle != std.posix.AT.FDCWD);
}

test "TestDir: createDirPath makes nested parents" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDirPath("a/b/c");
    try testing.expect(test_dir.fileExists("a/b/c"));
    try testing.expect(!test_dir.fileExists("a/b/missing"));
}

test "TestDir: createUniqueFile returns a distinct basename" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const name = try test_dir.createUniqueFile("base", "unique-body");
    defer testing.allocator.free(name);
    try testing.expect(name.len > 0);
    try testing.expect(!std.mem.eql(u8, name, "base"));
    try test_dir.expectFileContent(name, "unique-body");
}

test "TestDir: join builds an absolute dest that need not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const dest = try test_dir.join("missing/child");
    defer testing.allocator.free(dest);
    try testing.expect(std.fs.path.isAbsolute(dest));
    try testing.expect(std.mem.endsWith(u8, dest, "missing/child"));
    try testing.expect(!test_dir.fileExists("missing/child"));
}

test "TestDir: getPath(\".\") is the sandbox root" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const via_dot = try test_dir.getPath(".");
    defer testing.allocator.free(via_dot);
    const via_base = try test_dir.getBasePath();
    defer testing.allocator.free(via_base);
    try testing.expect(std.fs.path.isAbsolute(via_dot));
    try testing.expectEqualStrings(via_base, via_dot);
}

test "TestDir: chdirToBase moves cwd and restoreCwd returns" {
    const io = testing.io;
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("marker.txt", "cwd-marker", null);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, "marker.txt", .{}),
    );

    var saved = try test_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved);

    try std.Io.Dir.cwd().access(io, "marker.txt", .{});
}
