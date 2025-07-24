const std = @import("std");
const testing = std.testing;

pub const FileType = enum {
    regular_file,
    directory,
    symlink,
    special,
};

pub const PathResolver = struct {
    /// Determine the type of a file at the given path
    pub fn getFileType(path: []const u8) !FileType {
        // First check if it's a symlink (before stat which follows symlinks)
        if (isSymlink(path)) {
            return .symlink;
        }
        
        // Get file stats to determine type
        const file_stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        
        return switch (file_stat.kind) {
            .file => .regular_file,
            .directory => .directory,
            else => .special,
        };
    }
    
    /// Check if a path is a symbolic link
    pub fn isSymlink(path: []const u8) bool {
        var link_buf: [1]u8 = undefined;
        const link_result = std.fs.cwd().readLink(path, &link_buf);
        return if (link_result) |_| true else |_| false;
    }
    
    /// Resolve the final destination path for a copy operation
    /// If dest is a directory, returns dest/basename(source)
    /// Otherwise returns dest unchanged
    pub fn resolveFinalDestination(
        allocator: std.mem.Allocator,
        source: []const u8,
        dest: []const u8
    ) ![]u8 {
        // Check if destination exists and is a directory
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, use as-is
                return try allocator.dupe(u8, dest);
            },
            else => return err,
        };
        
        if (dest_stat.kind == .directory) {
            // Destination is a directory, append source basename
            const source_basename = std.fs.path.basename(source);
            return try std.fs.path.join(allocator, &[_][]const u8{ dest, source_basename });
        } else {
            // Destination is a file, use as-is
            return try allocator.dupe(u8, dest);
        }
    }
    
    /// Check if a file exists at the given path
    pub fn exists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
    
    /// Get the target of a symbolic link
    pub fn getSymlinkTarget(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = try std.fs.cwd().readLink(path, &target_buf);
        return try allocator.dupe(u8, target);
    }
    
    /// Make path absolute if it's relative
    pub fn makeAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) {
            return try allocator.dupe(u8, path);
        }
        
        return try std.fs.cwd().realpathAlloc(allocator, path);
    }
    
    /// Split a path into directory and filename components
    pub fn splitPath(path: []const u8) struct { dir: []const u8, name: []const u8 } {
        const dirname = std.fs.path.dirname(path) orelse ".";
        const basename = std.fs.path.basename(path);
        return .{ .dir = dirname, .name = basename };
    }
    
    /// Check if source and destination refer to the same file
    pub fn isSameFile(source: []const u8, dest: []const u8) !bool {
        const source_stat = std.fs.cwd().statFile(source) catch return false;
        const dest_stat = std.fs.cwd().statFile(dest) catch return false;
        
        // Compare device and inode
        return source_stat.inode == dest_stat.inode;
    }
    
    /// Validate that a path is safe for copying operations
    pub fn validatePath(path: []const u8) !void {
        if (path.len == 0) {
            return error.EmptyPath;
        }
        
        if (path.len > std.fs.max_path_bytes) {
            return error.PathTooLong;
        }
        
        // Check for null bytes
        if (std.mem.indexOf(u8, path, "\x00") != null) {
            return error.InvalidPath;
        }
    }
};

// =============================================================================
// TESTS
// =============================================================================

const TestUtils = @import("test_utils.zig").TestUtils;

test "PathResolver: getFileType" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    // Create test files
    try test_dir.createFile("regular.txt", "content");
    try test_dir.createDir("testdir");
    try test_dir.createSymlink("regular.txt", "link.txt");
    
    // Get paths - use joinPath for symlinks to avoid resolution
    const regular_path = try test_dir.getPath("regular.txt");
    defer testing.allocator.free(regular_path);
    const dir_path = try test_dir.getPath("testdir");
    defer testing.allocator.free(dir_path);
    const link_path = try test_dir.joinPath("link.txt");
    defer testing.allocator.free(link_path);
    
    // Test file type detection
    try testing.expectEqual(FileType.regular_file, try PathResolver.getFileType(regular_path));
    try testing.expectEqual(FileType.directory, try PathResolver.getFileType(dir_path));
    try testing.expectEqual(FileType.symlink, try PathResolver.getFileType(link_path));
}

test "PathResolver: isSymlink" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("regular.txt", "content");
    try test_dir.createSymlink("regular.txt", "link.txt");
    
    const regular_path = try test_dir.getPath("regular.txt");
    defer testing.allocator.free(regular_path);
    // Use joinPath instead of getPath to avoid resolving symlinks
    const link_path = try test_dir.joinPath("link.txt");
    defer testing.allocator.free(link_path);
    
    try testing.expect(!PathResolver.isSymlink(regular_path));
    try testing.expect(PathResolver.isSymlink(link_path));
}

test "PathResolver: resolveFinalDestination" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("source.txt", "content");
    try test_dir.createDir("dest_dir");
    
    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dir_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dir_path);
    
    // Test copying to directory
    const resolved_to_dir = try PathResolver.resolveFinalDestination(
        testing.allocator, 
        source_path, 
        dir_path
    );
    defer testing.allocator.free(resolved_to_dir);
    try testing.expect(std.mem.endsWith(u8, resolved_to_dir, "dest_dir/source.txt"));
    
    // Test copying to non-existent file
    const nonexistent_path = try test_dir.joinPath("nonexistent.txt");
    defer testing.allocator.free(nonexistent_path);
    const resolved_to_file = try PathResolver.resolveFinalDestination(
        testing.allocator,
        source_path,
        nonexistent_path
    );
    defer testing.allocator.free(resolved_to_file);
    try testing.expectEqualStrings(nonexistent_path, resolved_to_file);
}

test "PathResolver: exists" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("exists.txt", "content");
    
    const existing_path = try test_dir.getPath("exists.txt");
    defer testing.allocator.free(existing_path);
    const nonexistent_path = try test_dir.joinPath("nonexistent.txt");
    defer testing.allocator.free(nonexistent_path);
    
    try testing.expect(PathResolver.exists(existing_path));
    try testing.expect(!PathResolver.exists(nonexistent_path));
}

test "PathResolver: getSymlinkTarget" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("target.txt", "content");
    try test_dir.createSymlink("target.txt", "link.txt");
    
    const link_path = try test_dir.joinPath("link.txt");
    defer testing.allocator.free(link_path);
    
    const target = try PathResolver.getSymlinkTarget(testing.allocator, link_path);
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("target.txt", target);
}

test "PathResolver: splitPath" {
    const result1 = PathResolver.splitPath("/path/to/file.txt");
    try testing.expectEqualStrings("/path/to", result1.dir);
    try testing.expectEqualStrings("file.txt", result1.name);
    
    const result2 = PathResolver.splitPath("file.txt");
    try testing.expectEqualStrings(".", result2.dir);
    try testing.expectEqualStrings("file.txt", result2.name);
}

test "PathResolver: validatePath" {
    // Valid paths should pass
    try PathResolver.validatePath("/valid/path");
    try PathResolver.validatePath("relative/path");
    try PathResolver.validatePath("file.txt");
    
    // Invalid paths should fail
    try testing.expectError(error.EmptyPath, PathResolver.validatePath(""));
    try testing.expectError(error.InvalidPath, PathResolver.validatePath("path\x00with\x00nulls"));
}