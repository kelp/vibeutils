//! Move (rename) files and directories with atomic rename and cross-filesystem support

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const test_utils = common.test_utils;

/// Command line arguments for mv utility
const MvArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Display version and exit
    version: bool = false,
    /// Prompt before overwrite
    interactive: bool = false,
    /// Force overwrite without prompting
    force: bool = false,
    /// Explain what is being done
    verbose: bool = false,
    /// Do not overwrite existing files
    no_clobber: bool = false,
    /// Do not follow symlinks at target
    no_follow_symlink: bool = false,
    /// Make backup of each destination file
    backup: bool = false,
    /// Source files and destination
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .interactive = .{ .short = 'i', .desc = "Prompt before overwrite" },
        .force = .{ .short = 'f', .desc = "overwrite without prompting" },
        .verbose = .{ .short = 'v', .desc = "print each action" },
        .no_clobber = .{ .short = 'n', .desc = "never overwrite an existing file" },
        .no_follow_symlink = .{ .short = 'h', .desc = "do not follow symlinks at target" },
        .backup = .{ .short = 'b', .desc = "make backup of each destination file" },
    };
};

/// Options controlling move operation behavior
const MoveOptions = struct {
    /// Prompt before overwrite
    interactive: bool = false,
    /// Force overwrite without prompting
    force: bool = false,
    /// Print verbose output
    verbose: bool = false,
    /// Do not overwrite existing files
    no_clobber: bool = false,
    /// Do not follow symlinks at target
    no_follow_symlink: bool = false,
    /// Make backup of each destination file
    backup: bool = false,
};

// Test helpers — thin wrapper around common.test_dir.TestDir

const TestDir = struct {
    inner: common.test_dir.TestDir,

    pub fn init(allocator: std.mem.Allocator) TestDir {
        return .{ .inner = common.test_dir.TestDir.init(allocator) };
    }

    pub fn deinit(self: *TestDir) void {
        self.inner.deinit();
    }

    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8) !void {
        try self.inner.createFile(name, content, null);
    }

    pub fn createUniqueFile(self: *TestDir, base_name: []const u8, content: []const u8) ![]u8 {
        return try test_utils.createUniqueTestFile(testing.io, self.inner.tmp_dir.dir, self.inner.allocator, base_name, content);
    }

    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        return self.inner.fileExists(name);
    }

    pub fn readFile(self: *TestDir, name: []const u8) ![]u8 {
        return try self.inner.readFileAlloc(name);
    }

    pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, ".")) {
            return try self.inner.getBasePath();
        }
        return try self.inner.getPath(name);
    }

    pub fn dir(self: *TestDir) std.Io.Dir {
        return self.inner.tmp_dir.dir;
    }
};

test "mv: basic test" {
    // Simple test to verify the module compiles and basic types work
    const options = MoveOptions{};
    try testing.expect(!options.interactive);
    try testing.expect(!options.force);
    try testing.expect(!options.verbose);
    try testing.expect(!options.no_clobber);
}

test "mv: file rename in same directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source file with unique name
    const old_name = try test_dir.createUniqueFile("old", "Hello, World!");
    defer testing.allocator.free(old_name);

    const new_name = try test_utils.uniqueTestName(testing.allocator, "new");
    defer testing.allocator.free(new_name);

    // Get full paths to source and destination
    const old_path = try test_dir.getPath(old_name);
    defer testing.allocator.free(old_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const new_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, new_name });
    defer testing.allocator.free(new_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, old_path, new_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify old file is gone
    try testing.expect(!test_dir.fileExists(old_name));

    // Verify new file exists with same content
    try testing.expect(test_dir.fileExists(new_name));
    const content = try test_dir.readFile(new_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Hello, World!", content);
}

test "mv: move to different directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source file and destination directory with unique names
    const source_name = try test_dir.createUniqueFile("source", "Move me!");
    defer testing.allocator.free(source_name);

    const subdir_name = try test_utils.uniqueTestName(testing.allocator, "subdir");
    defer testing.allocator.free(subdir_name);
    try test_dir.inner.createDir(subdir_name);

    // Get paths
    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(subdir_name);
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, source_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify original is gone
    try testing.expect(!test_dir.fileExists(source_name));

    // Verify file exists in new location
    const moved_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ subdir_name, source_name });
    defer testing.allocator.free(moved_path);
    const moved_file = try test_dir.inner.tmp_dir.dir.openFile(testing.io, moved_path, .{});
    moved_file.close(testing.io);

    // Verify content is preserved
    const content = try test_dir.inner.tmp_dir.dir.readFileAlloc(testing.io, moved_path, testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Move me!", content);
}

test "mv: directory move" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with a file inside
    try test_dir.inner.createDir("source_dir");
    try test_dir.inner.createFile("source_dir/file.txt", "Inside directory", null);

    // Get paths
    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify original directory is gone
    test_dir.inner.tmp_dir.dir.access(testing.io, "source_dir", .{}) catch |err| {
        try testing.expect(err == error.FileNotFound);
    };

    // Verify new directory exists with file intact
    const moved_file = try test_dir.inner.tmp_dir.dir.openFile(testing.io, "dest_dir/file.txt", .{});
    defer moved_file.close(testing.io);

    // Verify content is preserved
    const content = try test_dir.inner.tmp_dir.dir.readFileAlloc(testing.io, "dest_dir/file.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Inside directory", content);
}

test "mv: force mode overwrites existing file" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source and existing destination with unique names
    const source_name = try test_dir.createUniqueFile("source", "New content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "Existing content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    // With force mode, should overwrite without error
    const options = MoveOptions{ .force = true };
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, options, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify source is gone and dest has new content
    try testing.expect(!test_dir.fileExists(source_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("New content", content);
}

test "mv: no-clobber mode preserves existing file" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source and existing destination with unique names
    const source_name = try test_dir.createUniqueFile("source", "New content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "Existing content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    // Verify both files exist before the operation
    try testing.expect(test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));

    // With no-clobber mode, should not overwrite
    const options = MoveOptions{ .no_clobber = true };
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, options, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify source still exists and dest is unchanged
    try testing.expect(test_dir.fileExists(source_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Existing content", content);
}

test "mv: files with spaces in names" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create files with spaces in names
    const source_name = try test_dir.createUniqueFile("file with spaces", "Space content");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "dest with spaces");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Space content", content);
}

test "mv: files with unicode characters" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create files with unicode characters
    const source_name = try test_dir.createUniqueFile("файл", "Unicode content");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "目标文件");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Unicode content", content);
}

test "mv: files with special characters" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create files with special characters (avoiding ones that are invalid in filenames)
    const source_name = try test_dir.createUniqueFile("file@#$%", "Special content");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "dest!&()");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Special content", content);
}

test "mv: empty file" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create an empty file
    const source_name = try test_dir.createUniqueFile("empty", "");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "moved_empty");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("", content);
}

/// Move across filesystems using copy-then-delete
fn crossFilesystemMove(allocator: std.mem.Allocator, io: std.Io, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stdout_writer.print("mv: moving '{s}' to '{s}' (cross-filesystem)\n", .{ source, dest });
    }

    // Get source stat to determine if it's a directory
    const source_info = common.file.FileInfo.stat(io, source) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat '{s}': {}", .{ source, err });
        return err;
    };

    errdefer {
        if (source_info.kind == .directory) {
            std.Io.Dir.cwd().deleteTree(io, dest) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(io, dest) catch {};
        }
    }

    if (source_info.kind == .directory) {
        // Handle directory recursively
        try copyDirectoryRecursive(allocator, io, source, dest, options, stdout_writer, stderr_writer);
    } else {
        // Handle regular file
        try copyFileCross(allocator, io, source, dest, source_info, options, stdout_writer, stderr_writer);
    }

    // If copy succeeded, remove the source
    if (options.verbose) {
        try stdout_writer.print("mv: removing source '{s}'\n", .{source});
    }

    if (source_info.kind == .directory) {
        std.Io.Dir.cwd().deleteTree(io, source) catch |del_err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "failed to remove source directory '{s}': {}", .{ source, del_err });
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "copy completed successfully but source directory remains - please remove manually", .{});
            return del_err;
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, source) catch |del_err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "failed to remove source file '{s}': {}", .{ source, del_err });
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "copy completed successfully but source file remains - please remove manually", .{});
            return del_err;
        };
    }

    if (options.verbose) {
        try stdout_writer.print("mv: completed cross-filesystem move\n", .{});
    }
}

/// Copy a single file across filesystems with attribute preservation
fn copyFileCross(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, dest_path: []const u8, source_info: common.file.FileInfo, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stdout_writer.print("mv: copying file '{s}' to '{s}'\n", .{ source_path, dest_path });
    }

    // Open source file
    const source_file = std.Io.Dir.cwd().openFile(io, source_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot open source file '{s}': {}", .{ source_path, err });
        return err;
    };
    defer source_file.close(io);

    // Create destination file with same permissions as source
    const dest_file = std.Io.Dir.cwd().createFile(io, dest_path, .{
        .permissions = std.Io.File.Permissions.fromMode(source_info.mode),
    }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create destination file '{s}': {}", .{ dest_path, err });
        return err;
    };
    defer dest_file.close(io);

    // Copy file contents
    common.file_ops.copyFileContents(io, source_file, dest_file) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "error copying '{s}' to '{s}': {}", .{ source_path, dest_path, err });
        return err;
    };

    // Preserve timestamps if possible
    dest_file.setTimestamps(io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(source_info.atime) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(source_info.mtime) } },
    }) catch |err| {
        // Non-critical error - log but continue
        if (options.verbose) {
            try stdout_writer.print("mv: warning: could not preserve timestamps for '{s}': {}\n", .{ dest_path, err });
        }
    };
}

/// Recursively copy directory across filesystems
fn copyDirectoryRecursive(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, dest_path: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stdout_writer.print("mv: copying directory '{s}' to '{s}'\n", .{ source_path, dest_path });
    }

    // Get source directory stat for permissions
    const source_info = common.file.FileInfo.stat(io, source_path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat source directory '{s}': {}", .{ source_path, err });
        return err;
    };

    // Create destination directory with same permissions
    std.Io.Dir.cwd().createDir(io, dest_path, std.Io.File.Permissions.fromMode(source_info.mode)) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Directory already exists, check if it's actually a directory
            const dest_info = common.file.FileInfo.stat(io, dest_path) catch |stat_err| {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat existing destination '{s}': {}", .{ dest_path, stat_err });
                return stat_err;
            };
            if (dest_info.kind != .directory) {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "destination '{s}' exists but is not a directory", .{dest_path});
                return error.NotDir;
            }
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create destination directory '{s}': {}", .{ dest_path, err });
            return err;
        },
    };

    // Open source directory for iteration
    var source_dir = std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot open source directory '{s}': {}", .{ source_path, err });
        return err;
    };
    defer source_dir.close(io);

    // Iterate through directory entries
    var iterator = source_dir.iterate();
    while (iterator.next(io) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "error reading directory '{s}': {}", .{ source_path, err });
        return err;
    }) |entry| {
        // Build full paths for source and destination
        const entry_source = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_path, entry.name });
        defer allocator.free(entry_source);
        const entry_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_path, entry.name });
        defer allocator.free(entry_dest);

        switch (entry.kind) {
            .file => {
                const entry_info = common.file.FileInfo.stat(io, entry_source) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat file '{s}': {}", .{ entry_source, err });
                    return err;
                };
                try copyFileCross(allocator, io, entry_source, entry_dest, entry_info, options, stdout_writer, stderr_writer);
            },
            .directory => {
                try copyDirectoryRecursive(allocator, io, entry_source, entry_dest, options, stdout_writer, stderr_writer);
            },
            .sym_link => {
                // Copy symlink by reading target and creating new symlink
                var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const target_len = std.Io.Dir.cwd().readLink(io, entry_source, &target_buf) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot read symlink '{s}': {}", .{ entry_source, err });
                    return err;
                };
                const target = target_buf[0..target_len];

                std.Io.Dir.cwd().symLink(io, target, entry_dest, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create symlink '{s}': {}", .{ entry_dest, err });
                    return err;
                };
            },
            else => {
                // Skip other file types (block devices, character devices, etc.)
                if (options.verbose) {
                    try stdout_writer.print("mv: skipping special file '{s}'\n", .{entry_source});
                }
            },
        }
    }

    // Preserve directory timestamps if possible
    // Note: On some systems, directory timestamp preservation may not be supported
    if (options.verbose) {
        try stdout_writer.print("mv: note: directory timestamp preservation not implemented for cross-filesystem moves\n", .{});
    }
}

/// Rename wrapper that handles EINVAL instead of panicking.
///
/// Zig's std.posix.rename maps EINVAL to `unreachable`, which causes a panic
/// when the kernel returns EINVAL (e.g., moving a directory into its own
/// subdirectory). This wrapper calls the C rename directly and maps EINVAL
/// to error.InvalidArgument so callers can handle it gracefully.
const SafeRenameError = std.Io.Dir.RenameError || error{ InvalidArgument, CrossDevice, PathAlreadyExists };

fn safeRename(old_path: []const u8, new_path: []const u8) SafeRenameError!void {
    const old_c = try std.posix.toPosixPath(old_path);
    const new_c = try std.posix.toPosixPath(new_path);
    const rc = std.c.rename(&old_c, &new_c);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY => return error.FileBusy,
        .DQUOT => return error.DiskQuota,
        .FAULT => unreachable,
        .INVAL => return error.InvalidArgument,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .EXIST => return error.PathAlreadyExists,
        .NOTEMPTY => return error.PathAlreadyExists,
        .ROFS => return error.ReadOnlyFileSystem,
        .XDEV => return error.CrossDevice,
        else => return error.Unexpected,
    }
}

/// Check if path is a directory, respecting the no_follow_symlink option.
/// When no_follow_symlink is true, a symlink to a directory is NOT treated
/// as a directory (the symlink itself is treated as a file target).
fn isDestDirectory(io: std.Io, path: []const u8, no_follow_symlink: bool) !bool {
    if (no_follow_symlink) {
        // Use lstat to check without following symlinks
        const info = common.file.FileInfo.lstat(path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        // If it's a symlink, treat it as a file even if it points to a directory
        if (info.kind == .sym_link) return false;
        return info.kind == .directory;
    }
    // Default: use stat which follows symlinks
    const info = common.file.FileInfo.stat(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    return info.kind == .directory;
}

/// Move file or directory with atomic rename or cross-filesystem copy
fn moveFile(allocator: std.mem.Allocator, io: std.Io, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype, hinted_overwrite: *bool) !void {
    // Check for same file using fstat to compare both inode and device.
    // If source and dest are hardlinks (same inode, different paths),
    // just unlink the source and succeed.
    if (common.file_ops.isSameFile(io, source, dest)) {
        if (std.mem.eql(u8, source, dest)) {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "'{s}' and '{s}' are the same file", .{ source, dest });
            return error.SameFile;
        }
        // Different names for the same inode (hardlink): remove the source link.
        std.Io.Dir.cwd().deleteFile(io, source) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot remove '{s}': {}", .{ source, err });
            return error.SameFile;
        };
        return;
    }

    // For no-clobber mode, check if destination exists first
    // Note: This has a small TOCTOU window, but it's the standard approach used by GNU mv
    // The alternative would require filesystem-specific atomic operations not available in POSIX
    if (options.no_clobber) {
        if (std.Io.Dir.cwd().access(io, dest, .{})) |_| {
            // Destination exists, skip the move
            if (options.verbose) {
                try stdout_writer.print("mv: not overwriting '{s}' (no-clobber mode)\n", .{dest});
            }
            return; // Silently skip as per GNU mv behavior
        } else |err| switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, proceed with normal move
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "error checking destination '{s}': {}", .{ dest, err });
                return err;
            },
        }
    }

    // Check if destination exists for interactive prompt, overwrite hint, and backup.
    // On Linux, rename() atomically overwrites without returning EEXIST, so we must
    // check before calling rename to give -i a chance to prompt (F36).
    const dest_exists = if (std.Io.Dir.cwd().access(io, dest, .{})) |_| true else |_| false;

    if (dest_exists and options.interactive) {
        // Only prompt if stdin is a terminal; otherwise default to
        // "no" (skip the move). Matches GNU mv behavior and prevents
        // hangs when stdin is not interactive (pipes, tests, etc.).
        if (std.c.isatty(std.Io.File.stdin().handle) == 0) {
            return; // Non-interactive stdin: default to no
        }
        if (!try common.prompt.promptYesNo(io, stderr_writer, "mv: overwrite '{s}'? ", .{dest})) {
            return; // User chose not to overwrite
        }
    }

    // Print one-time overwrite hint when destination exists with -f (overwrite succeeds, hint suggests -i)
    if (options.force and !options.interactive and !options.no_clobber and !hinted_overwrite.*) {
        if (dest_exists) {
            common.printHintWithProgram(allocator, stderr_writer, "mv", "use -i for interactive prompts before overwriting", .{});
            hinted_overwrite.* = true;
        }
    }

    // Create backup of destination if it exists and backup mode is enabled
    if (options.backup and dest_exists) {
        const backup_name = try std.fmt.allocPrint(allocator, "{s}~", .{dest});
        defer allocator.free(backup_name);
        safeRename(dest, backup_name) catch |backup_err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create backup '{s}': {}", .{ backup_name, backup_err });
            return backup_err;
        };
        if (options.verbose) {
            try stdout_writer.print("mv: created backup '{s}'\n", .{backup_name});
        }
    }

    // Try atomic rename first (using safeRename to handle EINVAL gracefully)
    safeRename(source, dest) catch |err| switch (err) {
        error.CrossDevice => {
            // Fall back to copy + remove
            return crossFilesystemMove(allocator, io, source, dest, options, stdout_writer, stderr_writer);
        },
        error.PathAlreadyExists => {
            // Destination exists but rename didn't overwrite (some filesystems)
            if (!options.force) {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot overwrite '{s}': File exists (use -f to force or -i for interactive)", .{dest});
                return error.PathAlreadyExists;
            }

            // Remove destination and retry rename (same-filesystem overwrite)
            std.Io.Dir.cwd().deleteFile(io, dest) catch {
                // If delete fails, fall back to cross-filesystem move
                return crossFilesystemMove(allocator, io, source, dest, options, stdout_writer, stderr_writer);
            };
            safeRename(source, dest) catch |retry_err| {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot rename '{s}' to '{s}': {}", .{ source, dest, retry_err });
                return retry_err;
            };
        },
        error.InvalidArgument => {
            // EINVAL: typically means moving a directory into a subdirectory of itself
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot move '{s}' to a subdirectory of itself, '{s}'", .{ source, dest });
            return error.InvalidArgument;
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot rename '{s}' to '{s}': {}", .{ source, dest, err });
            return err;
        },
    };
}

/// Print help message
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: mv [OPTION]... SOURCE DEST
        \\  or:  mv [OPTION]... SOURCE... DIRECTORY
        \\Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.
        \\
        \\  -b, --backup               make backup of each destination file
        \\  -f, --force                overwrite without prompting
        \\  -h                         do not follow symlinks at target
        \\  -i, --interactive          prompt before overwrite
        \\  -n, --no-clobber           never overwrite an existing file
        \\  -v, --verbose              print each action
        \\      --help                 display this help and exit
        \\  -V, --version              output version information and exit
        \\
    );
}

/// Main entry point for mv utility
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, run);
}

/// Run mv with provided writers for output
fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    const prog_name = "mv";

    const parsed_args = common.argparse.ArgParser.parseOrExit(MvArgs, allocator, args, prog_name, stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try stdout_writer.print("mv ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    const files = parsed_args.positionals;
    if (files.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing file operand\nTry '{s} --help' for more information.", .{prog_name});
        return @intFromEnum(common.ExitCode.misuse);
    }
    if (files.len == 1) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing destination file operand after '{s}'\nTry '{s} --help' for more information.", .{ files[0], prog_name });
        return @intFromEnum(common.ExitCode.misuse);
    }

    // GNU mv uses last-flag-wins for mutually exclusive -f, -i, -n.
    // Scan raw args to determine which appeared last (F38).
    const LastOverwriteFlag = enum { none, force, interactive, no_clobber };
    var last_overwrite_flag = LastOverwriteFlag.none;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-' and (arg.len < 3 or arg[1] != '-')) {
            // Short flag(s): -f, -i, -n, or combined like -fi
            for (arg[1..]) |ch| {
                switch (ch) {
                    'f' => last_overwrite_flag = .force,
                    'i' => last_overwrite_flag = .interactive,
                    'n' => last_overwrite_flag = .no_clobber,
                    else => {},
                }
            }
        } else if (std.mem.eql(u8, arg, "--force")) {
            last_overwrite_flag = .force;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            last_overwrite_flag = .interactive;
        } else if (std.mem.eql(u8, arg, "--no-clobber")) {
            last_overwrite_flag = .no_clobber;
        } else if (std.mem.eql(u8, arg, "--")) {
            break; // Stop scanning at -- separator
        }
    }

    const options = MoveOptions{
        .interactive = last_overwrite_flag == .interactive,
        .force = last_overwrite_flag == .force,
        .verbose = parsed_args.verbose,
        .no_clobber = last_overwrite_flag == .no_clobber,
        .no_follow_symlink = parsed_args.no_follow_symlink,
        .backup = parsed_args.backup,
    };

    var hinted_overwrite = false;

    // Handle multiple sources case
    if (files.len > 2) {
        // Multiple sources - destination must be a directory
        const dest = files[files.len - 1];
        const dest_is_dir = isDestDirectory(io, dest, options.no_follow_symlink) catch |err| switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "target '{s}' is not a directory", .{dest});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        };

        if (!dest_is_dir) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "target '{s}' is not a directory", .{dest});
            return @intFromEnum(common.ExitCode.general_error);
        }

        // Move each source to destination directory
        var exit_code = common.ExitCode.success;
        for (files[0 .. files.len - 1]) |source| {
            const basename = std.fs.path.basename(source);
            const full_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
            defer allocator.free(full_dest);

            moveFile(allocator, io, source, full_dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
                exit_code = common.ExitCode.general_error;
                continue;
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        }
        return @intFromEnum(exit_code);
    } else {
        // Single source case: simple rename or move
        const source = files[0];
        const dest = files[1];

        // Check if destination is a directory (respecting -h flag for symlinks)
        const dest_is_dir = isDestDirectory(io, dest, options.no_follow_symlink) catch |err| switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, proceed with normal rename
                moveFile(allocator, io, source, dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
                    return @intFromEnum(common.ExitCode.general_error);
                };

                if (options.verbose) {
                    try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, dest });
                }
                return @intFromEnum(common.ExitCode.success);
            },
            else => return err,
        };

        // If destination is a directory, move source into it
        if (dest_is_dir) {
            const base_name = std.fs.path.basename(source);
            const full_dest = try std.fs.path.join(allocator, &.{ dest, base_name });
            defer allocator.free(full_dest);

            moveFile(allocator, io, source, full_dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        } else {
            // Destination is a file, proceed with normal move/overwrite logic
            moveFile(allocator, io, source, dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, dest });
            }
        }
        return @intFromEnum(common.ExitCode.success);
    }
}

test "mv: force overwrite existing file on same filesystem" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "New content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "Old content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Force overwrite via moveFile (exercises PathAlreadyExists handler)
    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{ .force = true }, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Source should be gone, dest should have new content
    try testing.expect(!test_dir.fileExists(source_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("New content", content);
}

test "mv: large file copy preserves content integrity" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a file larger than the 64KB copy buffer to exercise
    // the incremental read loop in crossFilesystemMove/copyFileCross
    const large_size = 128 * 1024;
    const content = try testing.allocator.alloc(u8, large_size);
    defer testing.allocator.free(content);

    for (content, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    const source_name = try test_utils.uniqueTestName(testing.allocator, "large_src");
    defer testing.allocator.free(source_name);
    {
        const file = try test_dir.inner.tmp_dir.dir.createFile(testing.io, source_name, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, content);
    }

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "large_dst");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Source should be gone
    try testing.expect(!test_dir.fileExists(source_name));

    // Verify content integrity of destination
    const moved_content = try test_dir.inner.tmp_dir.dir.readFileAlloc(testing.io, dest_name, testing.allocator, .limited(large_size + 1));
    defer testing.allocator.free(moved_content);
    try testing.expectEqual(large_size, moved_content.len);
    try testing.expectEqualSlices(u8, content, moved_content);
}

test "mv: overwrite hint printed when destination exists with -f" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "new content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "old content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{ .force = true }, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Hint should have been shown (force succeeds, hint advises about -i)
    try testing.expect(hinted);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint: use -i") != null);
}

test "mv: overwrite hint NOT printed with -i flag" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "new content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "old content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    // With interactive flag, the hint should not appear
    // (moveFile will try to prompt and may error on PathAlreadyExists, but hint should not show)
    moveFile(testing.allocator, testing.io, source_path, dest_path, .{ .interactive = true }, &stdout_aw.writer, &stderr_aw.writer, &hinted) catch {};

    try testing.expect(!hinted);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "mv: overwrite hint NOT printed with -f and -i flags" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "new content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "old content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    // With both force and interactive, -i suppresses the hint
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{ .force = true, .interactive = true }, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    try testing.expect(!hinted);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "mv: overwrite hint NOT printed when destination does not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "content");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "dest");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{}, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    try testing.expect(!hinted);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "mv: -b flag creates backup of destination" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "New content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dest", "Old content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{ .force = true, .backup = true }, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Destination should have new content
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("New content", content);

    // Backup file (dest~) should exist with old content
    const backup_name = try std.fmt.allocPrint(testing.allocator, "{s}~", .{dest_name});
    defer testing.allocator.free(backup_name);
    const backup_content = try test_dir.readFile(backup_name);
    defer testing.allocator.free(backup_content);
    try testing.expectEqualStrings("Old content", backup_content);
}

test "mv: -b flag does nothing when dest does not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("source", "Content");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "dest");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(testing.allocator, testing.io, source_path, dest_path, .{ .backup = true }, &stdout_aw.writer, &stderr_aw.writer, &hinted);

    // Dest should have the content
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Content", content);

    // No backup file should exist
    const backup_name = try std.fmt.allocPrint(testing.allocator, "{s}~", .{dest_name});
    defer testing.allocator.free(backup_name);
    try testing.expect(!test_dir.fileExists(backup_name));
}

test "mv: -h flag prevents following symlink to directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a real directory and a symlink pointing to it
    try test_dir.inner.createDir("real_dir");
    try test_dir.inner.tmp_dir.dir.symLink(testing.io, "real_dir", "symlink_to_dir", .{ .is_directory = true });

    // Create a source file
    try test_dir.createFile("source.txt", "test content");

    // Get base path and construct symlink path manually (getBasePath doesn't follow symlinks)
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/symlink_to_dir", .{base_path});
    defer testing.allocator.free(symlink_path);

    // Without -h, isDestDirectory should detect symlink_to_dir as a directory
    const is_dir_normal = try isDestDirectory(testing.io, symlink_path, false);
    try testing.expect(is_dir_normal);

    // With -h, isDestDirectory should NOT detect symlink_to_dir as a directory
    const is_dir_no_follow = try isDestDirectory(testing.io, symlink_path, true);
    try testing.expect(!is_dir_no_follow);
}

test "mv: -h flag still follows real directories" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a real directory
    try test_dir.inner.createDir("real_dir");

    const dir_path = try test_dir.getPath("real_dir");
    defer testing.allocator.free(dir_path);

    // With -h, a real directory is still treated as a directory
    const is_dir = try isDestDirectory(testing.io, dir_path, true);
    try testing.expect(is_dir);
}

test "mv: -b flag is parsed" {
    const args = [_][]const u8{"-b"};
    const parsed = try common.argparse.ArgParser.parse(MvArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.backup);
}

test "mv: --backup flag is parsed" {
    const args = [_][]const u8{"--backup"};
    const parsed = try common.argparse.ArgParser.parse(MvArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.backup);
}

test "mv: -h flag is parsed as no_follow_symlink" {
    const args = [_][]const u8{"-h"};
    const parsed = try common.argparse.ArgParser.parse(MvArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.no_follow_symlink);
    try testing.expect(!parsed.help);
}

test "mv: --help still works as long-only flag" {
    const args = [_][]const u8{"--help"};
    const parsed = try common.argparse.ArgParser.parse(MvArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.help);
    try testing.expect(!parsed.no_follow_symlink);
}

test "mv: verbose move prints arrow to stdout" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("vsrc", "verbose test");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "vdst");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verbose arrow message should appear in stdout
    try testing.expect(std.mem.find(u8, stdout_aw.written(), "->") != null);
    // Verify source and dest appear in the stdout message
    try testing.expect(std.mem.find(u8, stdout_aw.written(), source_path) != null);
    try testing.expect(std.mem.find(u8, stdout_aw.written(), dest_path) != null);
}

test "mv: verbose move does not print arrow to stderr" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("esrc", "stderr test");
    defer testing.allocator.free(source_name);

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "edst");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // stderr should NOT contain the verbose arrow message
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "->") == null);
}

test "mv: moving directory into its own subdirectory returns error not panic" {
    // F37: mv parent parent/child triggers EINVAL from rename(),
    // which Zig maps to unreachable (panic). The code should handle
    // this gracefully and return exit code 1 with a clean error message.
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create parent/child directory structure
    try test_dir.inner.tmp_dir.dir.createDirPath(testing.io, "parent/child");

    const parent_path = try test_dir.getPath("parent");
    defer testing.allocator.free(parent_path);
    const child_path = try test_dir.getPath("parent/child");
    defer testing.allocator.free(child_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run via run so we get an exit code instead of a crash
    const args = [_][]const u8{ parent_path, child_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should exit with error (1), not panic/crash
    try testing.expectEqual(@as(u8, 1), exit_code);

    // stderr should contain a clean error message, not a stack trace
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "mv:") != null);
    // Must NOT contain panic indicators
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "panic") == null);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "unreachable") == null);
}

test "mv: -n -f flag combination should let force win (last flag)" {
    // F38: GNU mv uses last-flag-wins semantics.
    // -n -f means force wins: destination should be overwritten.
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("src_nf", "New content from source");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dst_nf", "Original destination content");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Simulate -n -f: last flag is force, should overwrite
    const args = [_][]const u8{ "-n", "-f", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // With last-flag-wins, force should override no-clobber:
    // destination should have the new content
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("New content from source", content);

    // Source should be gone (it was moved)
    try testing.expect(!test_dir.fileExists(source_name));
}

test "mv: -f -n flag combination should let no-clobber win (last flag)" {
    // F38: GNU mv uses last-flag-wins semantics.
    // -f -n means no-clobber wins: destination should be preserved.
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const source_name = try test_dir.createUniqueFile("src_fn", "New content");
    defer testing.allocator.free(source_name);
    const dest_name = try test_dir.createUniqueFile("dst_fn", "Original content preserved");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath(dest_name);
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Simulate -f -n: last flag is no-clobber, should preserve destination
    const args = [_][]const u8{ "-f", "-n", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // With last-flag-wins, no-clobber should override force:
    // destination should still have original content
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Original content preserved", content);

    // Source should still exist (move was skipped)
    try testing.expect(test_dir.fileExists(source_name));
}
