const std = @import("std");
const testing = std.testing;

/// Test utilities for cp module tests
pub const TestUtils = struct {
    /// Configuration options for file creation
    pub const FileOptions = struct {
        mode: ?std.fs.File.Mode = null,
        content: []const u8 = "",
    };

    /// Captures stdout/stderr output for testing writer-based utilities
    pub const TestCapture = struct {
        stdout_buffer: std.ArrayList(u8),
        stderr_buffer: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) TestCapture {
            return TestCapture{
                .stdout_buffer = std.ArrayList(u8).init(allocator),
                .stderr_buffer = std.ArrayList(u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *TestCapture) void {
            self.stdout_buffer.deinit();
            self.stderr_buffer.deinit();
        }

        pub fn stdoutWriter(self: *TestCapture) std.ArrayList(u8).Writer {
            return self.stdout_buffer.writer();
        }

        pub fn stderrWriter(self: *TestCapture) std.ArrayList(u8).Writer {
            return self.stderr_buffer.writer();
        }

        pub fn stdout(self: *const TestCapture) []const u8 {
            return self.stdout_buffer.items;
        }

        pub fn stderr(self: *const TestCapture) []const u8 {
            return self.stderr_buffer.items;
        }

        pub fn clear(self: *TestCapture) void {
            self.stdout_buffer.clearRetainingCapacity();
            self.stderr_buffer.clearRetainingCapacity();
        }
    };

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

        /// Create a test file with optional mode and content
        pub fn createFile(self: *TestDir, name: []const u8, options: FileOptions) !void {
            const file_options = if (options.mode) |mode|
                std.fs.File.CreateFlags{ .mode = mode }
            else
                std.fs.File.CreateFlags{};

            const file = try self.tmp_dir.dir.createFile(name, file_options);
            defer file.close();
            try file.writeAll(options.content);
        }

        /// Create a test directory
        pub fn createDir(self: *TestDir, name: []const u8) !void {
            try self.tmp_dir.dir.makeDir(name);
        }

        /// Create a symlink
        pub fn createSymlink(self: *TestDir, target: []const u8, link_name: []const u8) !void {
            try self.tmp_dir.dir.symLink(target, link_name, .{});
        }

        /// Get absolute path for a file in the test directory (caller owns memory)
        pub fn getPathAlloc(self: *TestDir, name: []const u8) ![]u8 {
            return try self.tmp_dir.dir.realpathAlloc(self.allocator, name);
        }

        /// Get absolute path for the test directory itself (caller owns memory)
        pub fn getBasePathAlloc(self: *TestDir) ![]u8 {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const base_path = try self.tmp_dir.dir.realpath(".", &path_buf);
            return try self.allocator.dupe(u8, base_path);
        }

        /// Join path within test directory (caller owns memory)
        pub fn joinPathAlloc(self: *TestDir, name: []const u8) ![]u8 {
            const base_path = try self.getBasePathAlloc();
            defer self.allocator.free(base_path);
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, name });
        }

        /// Read file content and verify it matches expected (handles any file size)
        pub fn expectFileContent(self: *TestDir, name: []const u8, expected: []const u8) !void {
            const actual = try self.readFileAlloc(name);
            defer self.allocator.free(actual);
            try testing.expectEqualStrings(expected, actual);
        }

        /// Read entire file content into allocated memory (caller owns memory)
        pub fn readFileAlloc(self: *TestDir, name: []const u8) ![]u8 {
            const file = try self.tmp_dir.dir.openFile(name, .{});
            defer file.close();

            const file_size = try file.getEndPos();
            const contents = try self.allocator.alloc(u8, file_size);
            _ = try file.readAll(contents);
            return contents;
        }

        /// Check if a file is a symlink (proper error handling)
        pub fn isSymlink(self: *TestDir, name: []const u8) !bool {
            var test_buf: [1]u8 = undefined;
            _ = self.tmp_dir.dir.readLink(name, &test_buf) catch |err| switch (err) {
                error.NotLink => return false,
                else => return err,
            };
            return true;
        }

        /// Get symlink target (caller owns memory)
        pub fn getSymlinkTargetAlloc(self: *TestDir, name: []const u8) ![]u8 {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try self.tmp_dir.dir.readLink(name, &target_buf);
            return try self.allocator.dupe(u8, target);
        }

        /// Get file stat
        pub fn getFileStat(self: *TestDir, name: []const u8) !std.fs.File.Stat {
            return try self.tmp_dir.dir.statFile(name);
        }
    };
};

// Tests for test utilities themselves
test "TestUtils: basic file operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Test file creation and reading
    try test_dir.createFile("test.txt", .{ .content = "test content" });
    try test_dir.expectFileContent("test.txt", "test content");

    // Test file creation with mode
    try test_dir.createFile("readonly.txt", .{ .content = "readonly", .mode = 0o444 });
    try test_dir.expectFileContent("readonly.txt", "readonly");

    // Test directory creation
    try test_dir.createDir("testdir");
    const stat = try test_dir.getFileStat("testdir");
    try testing.expect(stat.kind == .directory);
}

test "TestUtils: symlink operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create target and symlink
    try test_dir.createFile("target.txt", .{ .content = "target content" });
    try test_dir.createSymlink("target.txt", "link.txt");

    // Test symlink detection
    try testing.expect(try test_dir.isSymlink("link.txt"));
    try testing.expect(!(try test_dir.isSymlink("target.txt")));

    // Test symlink target reading
    const target = try test_dir.getSymlinkTargetAlloc("link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("target.txt", target);
}

test "TestUtils: path operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("test.txt", .{ .content = "content" });

    // Test path generation
    const path = try test_dir.getPathAlloc("test.txt");
    defer testing.allocator.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "test.txt"));

    const joined_path = try test_dir.joinPathAlloc("test.txt");
    defer testing.allocator.free(joined_path);
    try testing.expect(std.mem.endsWith(u8, joined_path, "test.txt"));
}

test "TestUtils: TestCapture functionality" {
    var capture = TestUtils.TestCapture.init(testing.allocator);
    defer capture.deinit();

    // Test writing to captured streams
    try capture.stdoutWriter().print("stdout message\n", .{});
    try capture.stderrWriter().print("stderr message\n", .{});

    // Test reading captured content
    try testing.expectEqualStrings("stdout message\n", capture.stdout());
    try testing.expectEqualStrings("stderr message\n", capture.stderr());

    // Test clearing
    capture.clear();
    try testing.expectEqualStrings("", capture.stdout());
    try testing.expectEqualStrings("", capture.stderr());
}

test "TestUtils: large file content handling" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a file larger than the old 1024-byte buffer
    const large_content = "x" ** 2048;
    try test_dir.createFile("large.txt", .{ .content = large_content });
    try test_dir.expectFileContent("large.txt", large_content);

    // Test reading with allocation
    const content = try test_dir.readFileAlloc("large.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(large_content, content);
}
