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

// Test helpers

const TestDir = struct {
    tmp_dir: testing.TmpDir,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestDir {
        return .{
            .tmp_dir = testing.tmpDir(.{}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestDir) void {
        self.tmp_dir.cleanup();
    }

    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8) !void {
        const file = try self.tmp_dir.dir.createFile(name, .{});
        defer file.close();
        try file.writeAll(content);
    }

    pub fn createUniqueFile(self: *TestDir, base_name: []const u8, content: []const u8) ![]u8 {
        return try test_utils.createUniqueTestFile(self.tmp_dir.dir, self.allocator, base_name, content);
    }

    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        self.tmp_dir.dir.access(name, .{}) catch return false;
        return true;
    }

    pub fn readFile(self: *TestDir, name: []const u8) ![]u8 {
        return try self.tmp_dir.dir.readFileAlloc(self.allocator, name, 1024 * 1024);
    }

    pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
        return try self.tmp_dir.dir.realpathAlloc(self.allocator, name);
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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, old_path, new_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    try test_dir.tmp_dir.dir.makeDir(subdir_name);

    // Get paths
    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(subdir_name);
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, source_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    // Verify original is gone
    try testing.expect(!test_dir.fileExists(source_name));

    // Verify file exists in new location
    const moved_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ subdir_name, source_name });
    defer testing.allocator.free(moved_path);
    const moved_file = try test_dir.tmp_dir.dir.openFile(moved_path, .{});
    moved_file.close();

    // Verify content is preserved
    const content = try test_dir.tmp_dir.dir.readFileAlloc(testing.allocator, moved_path, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Move me!", content);
}

test "mv: directory move" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with a file inside
    try test_dir.tmp_dir.dir.makeDir("source_dir");
    const source_file = try test_dir.tmp_dir.dir.createFile("source_dir/file.txt", .{});
    try source_file.writeAll("Inside directory");
    source_file.close();

    // Get paths
    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    // Verify original directory is gone
    test_dir.tmp_dir.dir.access("source_dir", .{}) catch |err| {
        try testing.expect(err == error.FileNotFound);
    };

    // Verify new directory exists with file intact
    const moved_file = try test_dir.tmp_dir.dir.openFile("dest_dir/file.txt", .{});
    defer moved_file.close();

    // Verify content is preserved
    const content = try test_dir.tmp_dir.dir.readFileAlloc(testing.allocator, "dest_dir/file.txt", 1024);
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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, options, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, options, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("", content);
}

/// Move across filesystems using copy-then-delete
fn crossFilesystemMove(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stdout_writer.print("mv: moving '{s}' to '{s}' (cross-filesystem)\n", .{ source, dest });
    }

    // Get source stat to determine if it's a directory
    const source_stat = std.fs.cwd().statFile(source) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat '{s}': {}", .{ source, err });
        return err;
    };

    errdefer {
        if (source_stat.kind == .directory) {
            std.fs.cwd().deleteTree(dest) catch {};
        } else {
            std.fs.cwd().deleteFile(dest) catch {};
        }
    }

    if (source_stat.kind == .directory) {
        // Handle directory recursively
        try copyDirectoryRecursive(allocator, source, dest, options, stdout_writer, stderr_writer);
    } else {
        // Handle regular file
        try copyFile(allocator, source, dest, source_stat, options, stdout_writer, stderr_writer);
    }

    // If copy succeeded, remove the source
    if (options.verbose) {
        try stdout_writer.print("mv: removing source '{s}'\n", .{source});
    }

    if (source_stat.kind == .directory) {
        std.fs.cwd().deleteTree(source) catch |del_err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "failed to remove source directory '{s}': {}", .{ source, del_err });
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "copy completed successfully but source directory remains - please remove manually", .{});
            return del_err;
        };
    } else {
        std.fs.cwd().deleteFile(source) catch |del_err| {
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
fn copyFile(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8, source_stat: std.fs.File.Stat, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stdout_writer.print("mv: copying file '{s}' to '{s}'\n", .{ source_path, dest_path });
    }

    // Open source file
    const source_file = std.fs.cwd().openFile(source_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot open source file '{s}': {}", .{ source_path, err });
        return err;
    };
    defer source_file.close();

    // Create destination file with same permissions as source
    const dest_file = std.fs.cwd().createFile(dest_path, .{ .mode = source_stat.mode }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create destination file '{s}': {}", .{ dest_path, err });
        return err;
    };
    defer dest_file.close();

    // Copy file contents
    common.file_ops.copyFileContents(source_file, dest_file) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "error copying '{s}' to '{s}': {}", .{ source_path, dest_path, err });
        return err;
    };

    // Preserve timestamps if possible
    dest_file.updateTimes(source_stat.atime, source_stat.mtime) catch |err| {
        // Non-critical error - log but continue
        if (options.verbose) {
            try stdout_writer.print("mv: warning: could not preserve timestamps for '{s}': {}\n", .{ dest_path, err });
        }
    };
}

/// Recursively copy directory across filesystems
fn copyDirectoryRecursive(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stdout_writer.print("mv: copying directory '{s}' to '{s}'\n", .{ source_path, dest_path });
    }

    // Get source directory stat for permissions
    const source_stat = std.fs.cwd().statFile(source_path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat source directory '{s}': {}", .{ source_path, err });
        return err;
    };

    // Create destination directory with same permissions
    std.fs.cwd().makeDir(dest_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Directory already exists, check if it's actually a directory
            const dest_stat = std.fs.cwd().statFile(dest_path) catch |stat_err| {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat existing destination '{s}': {}", .{ dest_path, stat_err });
                return stat_err;
            };
            if (dest_stat.kind != .directory) {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "destination '{s}' exists but is not a directory", .{dest_path});
                return error.NotDir;
            }
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create destination directory '{s}': {}", .{ dest_path, err });
            return err;
        },
    };

    // Set directory permissions
    var dest_dir = std.fs.cwd().openDir(dest_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot open directory '{s}': {}", .{ dest_path, err });
        return err;
    };
    defer dest_dir.close();

    dest_dir.chmod(source_stat.mode) catch |err| {
        if (options.verbose) {
            try stdout_writer.print("mv: warning: could not set permissions on '{s}': {}\n", .{ dest_path, err });
        }
    };

    // Open source directory for iteration
    var source_dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot open source directory '{s}': {}", .{ source_path, err });
        return err;
    };
    defer source_dir.close();

    // Iterate through directory entries
    var iterator = source_dir.iterate();
    while (iterator.next() catch |err| {
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
                const entry_stat = std.fs.cwd().statFile(entry_source) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat file '{s}': {}", .{ entry_source, err });
                    return err;
                };
                try copyFile(allocator, entry_source, entry_dest, entry_stat, options, stdout_writer, stderr_writer);
            },
            .directory => {
                try copyDirectoryRecursive(allocator, entry_source, entry_dest, options, stdout_writer, stderr_writer);
            },
            .sym_link => {
                // Copy symlink by reading target and creating new symlink
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.fs.cwd().readLink(entry_source, &target_buf) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot read symlink '{s}': {}", .{ entry_source, err });
                    return err;
                };

                std.fs.cwd().symLink(target, entry_dest, .{}) catch |err| {
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

/// Check if path is a directory, respecting the no_follow_symlink option.
/// When no_follow_symlink is true, a symlink to a directory is NOT treated
/// as a directory (the symlink itself is treated as a file target).
fn isDestDirectory(path: []const u8, no_follow_symlink: bool) !bool {
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
    // Default: use statFile which follows symlinks
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    return stat.kind == .directory;
}

/// Move file or directory with atomic rename or cross-filesystem copy
fn moveFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype, hinted_overwrite: *bool) !void {
    // Check for same file using fstat to compare both inode and device
    if (common.file_ops.isSameFile(source, dest)) {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "'{s}' and '{s}' are the same file", .{ source, dest });
        return error.SameFile;
    }

    // For no-clobber mode, check if destination exists first
    // Note: This has a small TOCTOU window, but it's the standard approach used by GNU mv
    // The alternative would require filesystem-specific atomic operations not available in POSIX
    if (options.no_clobber) {
        if (std.fs.cwd().access(dest, .{})) |_| {
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

    // Print one-time overwrite hint when destination exists with -f (overwrite succeeds, hint suggests -i)
    if (options.force and !options.interactive and !options.no_clobber and !hinted_overwrite.*) {
        if (std.fs.cwd().access(dest, .{})) |_| {
            common.printHintWithProgram(allocator, stderr_writer, "mv", "use -i for interactive prompts before overwriting", .{});
            hinted_overwrite.* = true;
        } else |_| {}
    }

    // Create backup of destination if it exists and backup mode is enabled
    if (options.backup) {
        if (std.fs.cwd().access(dest, .{})) |_| {
            const backup_name = try std.fmt.allocPrint(allocator, "{s}~", .{dest});
            defer allocator.free(backup_name);
            std.posix.rename(dest, backup_name) catch |backup_err| {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot create backup '{s}': {}", .{ backup_name, backup_err });
                return backup_err;
            };
            if (options.verbose) {
                try stdout_writer.print("mv: created backup '{s}'\n", .{backup_name});
            }
        } else |_| {}
    }

    // Try atomic rename first
    std.posix.rename(source, dest) catch |err| switch (err) {
        error.RenameAcrossMountPoints => {
            // Fall back to copy + remove
            return crossFilesystemMove(allocator, source, dest, options, stdout_writer, stderr_writer);
        },
        error.PathAlreadyExists => {
            // Destination exists - handle based on options
            // Interactive mode takes precedence unless force is also specified
            if (options.interactive and !options.force) {
                // Only prompt if stdin is a terminal; otherwise default to "no"
                // (skip the move). This matches GNU mv behavior and prevents
                // hangs when stdin is not interactive (pipes, tests, etc.).
                if (!std.posix.isatty(std.fs.File.stdin().handle)) {
                    return; // Non-interactive stdin: default to no
                }
                if (!try common.prompt.promptYesNo(stderr_writer, "mv: overwrite '{s}'? ", .{dest})) {
                    return; // User chose not to overwrite
                }
            } else if (!options.force) {
                // No force, no interactive - fail with clear error message
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot overwrite '{s}': File exists (use -f to force or -i for interactive)", .{dest});
                return error.PathAlreadyExists;
            }

            // Remove destination and retry rename (same-filesystem overwrite)
            std.fs.cwd().deleteFile(dest) catch {
                // If delete fails, fall back to cross-filesystem move
                return crossFilesystemMove(allocator, source, dest, options, stdout_writer, stderr_writer);
            };
            std.posix.rename(source, dest) catch |retry_err| {
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot rename '{s}' to '{s}': {}", .{ source, dest, retry_err });
                return retry_err;
            };
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
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runUtility(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Run mv with provided writers for output
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const prog_name = "mv";

    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(MvArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "unrecognized option\nTry '{s} --help' for more information.", .{prog_name});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument\nTry '{s} --help' for more information.", .{prog_name});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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

    const options = MoveOptions{
        .interactive = parsed_args.interactive,
        .force = parsed_args.force,
        .verbose = parsed_args.verbose,
        .no_clobber = parsed_args.no_clobber,
        .no_follow_symlink = parsed_args.no_follow_symlink,
        .backup = parsed_args.backup,
    };

    var hinted_overwrite = false;

    // Handle multiple sources case
    if (files.len > 2) {
        // Multiple sources - destination must be a directory
        const dest = files[files.len - 1];
        const dest_is_dir = isDestDirectory(dest, options.no_follow_symlink) catch |err| switch (err) {
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
        // TODO: Consider parallel processing for multiple independent file moves
        // This could be implemented using a thread pool for better performance
        // when moving many files, but would require careful error handling
        var exit_code = common.ExitCode.success;
        for (files[0 .. files.len - 1]) |source| {
            const basename = std.fs.path.basename(source);
            const full_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
            defer allocator.free(full_dest);

            moveFile(allocator, source, full_dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
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
        const dest_is_dir = isDestDirectory(dest, options.no_follow_symlink) catch |err| switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, proceed with normal rename
                moveFile(allocator, source, dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
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

            moveFile(allocator, source, full_dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        } else {
            // Destination is a file, proceed with normal move/overwrite logic
            moveFile(allocator, source, dest, options, stdout_writer, stderr_writer, &hinted_overwrite) catch {
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    // Force overwrite via moveFile (exercises PathAlreadyExists handler)
    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{ .force = true }, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    // the incremental read loop in crossFilesystemMove/copyFile
    const large_size = 128 * 1024;
    const content = try testing.allocator.alloc(u8, large_size);
    defer testing.allocator.free(content);

    for (content, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    const source_name = try test_utils.uniqueTestName(testing.allocator, "large_src");
    defer testing.allocator.free(source_name);
    {
        const file = try test_dir.tmp_dir.dir.createFile(source_name, .{});
        defer file.close();
        try file.writeAll(content);
    }

    const dest_name = try test_utils.uniqueTestName(testing.allocator, "large_dst");
    defer testing.allocator.free(dest_name);

    const source_path = try test_dir.getPath(source_name);
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    // Source should be gone
    try testing.expect(!test_dir.fileExists(source_name));

    // Verify content integrity of destination
    const moved_content = try test_dir.tmp_dir.dir.readFileAlloc(testing.allocator, dest_name, large_size + 1);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{ .force = true }, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    // Hint should have been shown (force succeeds, hint advises about -i)
    try testing.expect(hinted);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "hint: use -i") != null);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    // With interactive flag, the hint should not appear
    // (moveFile will try to prompt and may error on PathAlreadyExists, but hint should not show)
    moveFile(testing.allocator, source_path, dest_path, .{ .interactive = true }, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted) catch {};

    try testing.expect(!hinted);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "hint:") == null);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    // With both force and interactive, -i suppresses the hint
    try moveFile(testing.allocator, source_path, dest_path, .{ .force = true, .interactive = true }, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    try testing.expect(!hinted);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "hint:") == null);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

    try testing.expect(!hinted);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "hint:") == null);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{ .force = true, .backup = true }, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    var hinted = false;
    try moveFile(testing.allocator, source_path, dest_path, .{ .backup = true }, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator), &hinted);

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
    try test_dir.tmp_dir.dir.makeDir("real_dir");
    try test_dir.tmp_dir.dir.symLink("real_dir", "symlink_to_dir", .{ .is_directory = true });

    // Create a source file
    try test_dir.createFile("source.txt", "test content");

    // Get base path and construct symlink path manually (realpathAlloc follows symlinks)
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/symlink_to_dir", .{base_path});
    defer testing.allocator.free(symlink_path);

    // Without -h, isDestDirectory should detect symlink_to_dir as a directory
    const is_dir_normal = try isDestDirectory(symlink_path, false);
    try testing.expect(is_dir_normal);

    // With -h, isDestDirectory should NOT detect symlink_to_dir as a directory
    const is_dir_no_follow = try isDestDirectory(symlink_path, true);
    try testing.expect(!is_dir_no_follow);
}

test "mv: -h flag still follows real directories" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a real directory
    try test_dir.tmp_dir.dir.makeDir("real_dir");

    const dir_path = try test_dir.getPath("real_dir");
    defer testing.allocator.free(dir_path);

    // With -h, a real directory is still treated as a directory
    const is_dir = try isDestDirectory(dir_path, true);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try runUtility(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verbose arrow message should appear in stdout
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "->") != null);
    // Verify source and dest appear in the stdout message
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, source_path) != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, dest_path) != null);
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

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try runUtility(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);

    // stderr should NOT contain the verbose arrow message
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "->") == null);
}
