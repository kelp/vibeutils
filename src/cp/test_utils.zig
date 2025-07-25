const std = @import("std");
const testing = std.testing;

/// Test utilities for cp module tests
pub const TestUtils = struct {
    pub const TestDir = struct {
        tmp_dir: testing.TmpDir,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) TestDir {
            return TestDir{
                .tmp_dir = testing.tmpDir(.{}),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *TestDir) void {
            self.tmp_dir.cleanup();
        }

        /// Create a test file with given content
        pub fn createFile(self: *TestDir, name: []const u8, content: []const u8) !void {
            const file = try self.tmp_dir.dir.createFile(name, .{});
            defer file.close();
            try file.writeAll(content);
        }

        /// Create a test file with specific permissions
        pub fn createFileWithMode(self: *TestDir, name: []const u8, content: []const u8, mode: std.fs.File.Mode) !void {
            const file = try self.tmp_dir.dir.createFile(name, .{ .mode = mode });
            defer file.close();
            try file.writeAll(content);
        }

        /// Create a test directory
        pub fn createDir(self: *TestDir, name: []const u8) !void {
            try self.tmp_dir.dir.makeDir(name);
        }

        /// Create a symlink
        pub fn createSymlink(self: *TestDir, target: []const u8, link_name: []const u8) !void {
            try self.tmp_dir.dir.symLink(target, link_name, .{});
        }

        /// Get absolute path for a file in the test directory
        pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
            return try self.tmp_dir.dir.realpathAlloc(self.allocator, name);
        }

        /// Get absolute path for the test directory itself
        pub fn getBasePath(self: *TestDir) ![]u8 {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const base_path = try self.tmp_dir.dir.realpath(".", &path_buf);
            return try self.allocator.dupe(u8, base_path);
        }

        /// Join path within test directory
        pub fn joinPath(self: *TestDir, name: []const u8) ![]u8 {
            const base_path = try self.getBasePath();
            defer self.allocator.free(base_path);
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, name });
        }

        /// Read file content and verify it matches expected
        pub fn expectFileContent(self: *TestDir, name: []const u8, expected: []const u8) !void {
            const file = try self.tmp_dir.dir.openFile(name, .{});
            defer file.close();

            var buffer: [1024]u8 = undefined;
            const bytes_read = try file.read(&buffer);
            try testing.expectEqualStrings(expected, buffer[0..bytes_read]);
        }

        /// Check if a file is a symlink
        pub fn isSymlink(self: *TestDir, name: []const u8) bool {
            var test_buf: [1]u8 = undefined;
            return if (self.tmp_dir.dir.readLink(name, &test_buf)) |_| true else |_| false;
        }

        /// Get symlink target
        pub fn getSymlinkTarget(self: *TestDir, name: []const u8) ![]u8 {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try self.tmp_dir.dir.readLink(name, &target_buf);
            return try self.allocator.dupe(u8, target);
        }

        /// Get file stat
        pub fn getFileStat(self: *TestDir, name: []const u8) !std.fs.File.Stat {
            return try self.tmp_dir.dir.statFile(name);
        }
    };

    /// Create a standard test setup with common files
    pub fn createStandardTestSetup(allocator: std.mem.Allocator) !TestDir {
        var test_dir = TestDir.init(allocator);

        // Create some standard test files
        try test_dir.createFile("source.txt", "Hello, World!");
        try test_dir.createFile("executable.sh", "#!/bin/bash\necho hello");
        try test_dir.createFileWithMode("readonly.txt", "Read-only content", 0o444);

        // Create a directory with content
        try test_dir.createDir("source_dir");
        try test_dir.createFile("source_dir/file1.txt", "File 1 content");
        try test_dir.createDir("source_dir/subdir");
        try test_dir.createFile("source_dir/subdir/file2.txt", "File 2 content");

        // Create symlinks
        try test_dir.createSymlink("source.txt", "link_to_source.txt");
        try test_dir.createSymlink("nonexistent.txt", "broken_link.txt");

        return test_dir;
    }
};

// Tests for test utilities themselves
test "TestUtils: basic file operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Test file creation and reading
    try test_dir.createFile("test.txt", "test content");
    try test_dir.expectFileContent("test.txt", "test content");

    // Test directory creation
    try test_dir.createDir("testdir");
    const stat = try test_dir.getFileStat("testdir");
    try testing.expect(stat.kind == .directory);
}

test "TestUtils: symlink operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create target and symlink
    try test_dir.createFile("target.txt", "target content");
    try test_dir.createSymlink("target.txt", "link.txt");

    // Test symlink detection
    try testing.expect(test_dir.isSymlink("link.txt"));
    try testing.expect(!test_dir.isSymlink("target.txt"));

    // Test symlink target reading
    const target = try test_dir.getSymlinkTarget("link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("target.txt", target);
}

test "TestUtils: path operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("test.txt", "content");

    // Test path generation
    const path = try test_dir.getPath("test.txt");
    defer testing.allocator.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "test.txt"));

    const joined_path = try test_dir.joinPath("test.txt");
    defer testing.allocator.free(joined_path);
    try testing.expect(std.mem.endsWith(u8, joined_path, "test.txt"));
}
