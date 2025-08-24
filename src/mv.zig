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
    /// Source files and destination
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .interactive = .{ .short = 'i', .desc = "Prompt before overwrite" },
        .force = .{ .short = 'f', .desc = "Force overwrite without prompting" },
        .verbose = .{ .short = 'v', .desc = "Explain what is being done" },
        .no_clobber = .{ .short = 'n', .desc = "Do not overwrite an existing file" },
    };
};

// Test helpers

/// Test helper for managing temporary directories
const TestDir = struct {
    /// Temporary directory
    tmp_dir: testing.TmpDir,
    /// Memory allocator
    allocator: std.mem.Allocator,

    /// Initialize test directory
    pub fn init(allocator: std.mem.Allocator) TestDir {
        return .{
            .tmp_dir = testing.tmpDir(.{}),
            .allocator = allocator,
        };
    }

    /// Clean up test directory
    pub fn deinit(self: *TestDir) void {
        self.tmp_dir.cleanup();
    }

    /// Create file with given name and content
    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8) !void {
        const file = try self.tmp_dir.dir.createFile(name, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Create file with unique name based on base name
    pub fn createUniqueFile(self: *TestDir, base_name: []const u8, content: []const u8) ![]u8 {
        return try test_utils.createUniqueTestFile(self.tmp_dir.dir, self.allocator, base_name, content);
    }

    /// Check if file exists in test directory
    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        self.tmp_dir.dir.access(name, .{}) catch return false;
        return true;
    }

    /// Read entire file contents
    pub fn readFile(self: *TestDir, name: []const u8) ![]u8 {
        return try self.tmp_dir.dir.readFileAlloc(self.allocator, name, 1024 * 1024);
    }

    /// Get absolute path for file in test directory
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
    try moveFile(testing.allocator, old_path, new_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, options, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, options, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

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
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("", content);
}

// Constants for buffer sizes
const PROMPT_BUFFER_SIZE = 256;

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

    if (source_stat.kind == .directory) {
        // Handle directory recursively
        try copyDirectoryRecursive(allocator, source, dest, options, stdout_writer, stderr_writer);
    } else {
        // Handle regular file
        try copyFile(allocator, source, dest, source_stat, options, stdout_writer, stderr_writer);
    }

    // If copy succeeded, remove the source
    if (options.verbose) {
        try stderr_writer.print("mv: removing source '{s}'\n", .{source});
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
        try stderr_writer.print("mv: completed cross-filesystem move\n", .{});
    }
}

/// Copy a single file across filesystems with attribute preservation
fn copyFile(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8, source_stat: std.fs.File.Stat, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    _ = stdout_writer;

    if (options.verbose) {
        try stderr_writer.print("mv: copying file '{s}' to '{s}'\n", .{ source_path, dest_path });
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

    // Copy data using 64KB buffer
    const buffer_size = 64 * 1024;
    var buffer: [buffer_size]u8 = undefined;

    while (true) {
        const bytes_read = source_file.readAll(&buffer) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "error reading from '{s}': {}", .{ source_path, err });
            return err;
        };

        if (bytes_read == 0) break;

        dest_file.writeAll(buffer[0..bytes_read]) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "error writing to '{s}': {}", .{ dest_path, err });
            return err;
        };
    }

    // Preserve timestamps if possible
    dest_file.updateTimes(source_stat.atime, source_stat.mtime) catch |err| {
        // Non-critical error - log but continue
        if (options.verbose) {
            try stderr_writer.print("mv: warning: could not preserve timestamps for '{s}': {}\n", .{ dest_path, err });
        }
    };
}

/// Recursively copy directory across filesystems
fn copyDirectoryRecursive(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    if (options.verbose) {
        try stderr_writer.print("mv: copying directory '{s}' to '{s}'\n", .{ source_path, dest_path });
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
        if (options.verbose) {
            try stderr_writer.print("mv: warning: could not open directory for permission setting '{s}': {}\n", .{ dest_path, err });
        }
        return;
    };
    defer dest_dir.close();

    dest_dir.chmod(source_stat.mode) catch |err| {
        if (options.verbose) {
            try stderr_writer.print("mv: warning: could not set permissions on '{s}': {}\n", .{ dest_path, err });
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
                    try stderr_writer.print("mv: skipping special file '{s}'\n", .{entry_source});
                }
            },
        }
    }

    // Preserve directory timestamps if possible
    // Note: On some systems, directory timestamp preservation may not be supported
    if (options.verbose) {
        try stderr_writer.print("mv: note: directory timestamp preservation not implemented for cross-filesystem moves\n", .{});
    }
}

/// Prompt user for overwrite confirmation
fn promptOverwrite(dest: []const u8, stderr_writer: anytype) !bool {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    try stderr_writer.print("mv: overwrite '{s}'? ", .{dest});

    const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };

    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}

/// Move file or directory with atomic rename or cross-filesystem copy
fn moveFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    // Check for same file using stat() to compare inodes
    const source_stat = std.fs.cwd().statFile(source) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat '{s}': {}", .{ source, err });
        return err;
    };

    if (std.fs.cwd().statFile(dest)) |dest_stat| {
        if (source_stat.inode == dest_stat.inode) {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "'{s}' and '{s}' are the same file", .{ source, dest });
            return error.SameFile;
        }
    } else |err| switch (err) {
        error.FileNotFound => {}, // Destination doesn't exist, that's fine
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot stat '{s}': {}", .{ dest, err });
            return err;
        },
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
                if (!try promptOverwrite(dest, stderr_writer)) {
                    return; // User chose not to overwrite
                }
            } else if (!options.force) {
                // No force, no interactive - fail with clear error message
                common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot overwrite '{s}': File exists (use -f to force or -i for interactive)", .{dest});
                return error.PathAlreadyExists;
            }

            // If we get here, we need to overwrite (either force mode or interactive approved)
            // Let rename() handle the atomic overwrite - don't manually remove destination
            // On most systems, rename() atomically replaces the destination
            return crossFilesystemMove(allocator, source, dest, options, stdout_writer, stderr_writer);
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "mv", "cannot rename '{s}' to '{s}': {}", .{ source, dest, err });
            return err;
        },
    };
}

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
};

/// Print help message
fn printHelp(writer: anytype) !void {
    try writer.print(
        \\Usage: mv [OPTION]... SOURCE DEST
        \\  or:  mv [OPTION]... SOURCE... DIRECTORY
        \\  or:  mv [OPTION]... -t DIRECTORY SOURCE...
        \\Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.
        \\
        \\Mandatory arguments to long options are mandatory for short options too.
        \\  -f, --force                do not prompt before overwriting
        \\  -i, --interactive          prompt before overwrite
        \\  -n, --no-clobber           do not overwrite an existing file
        \\  -v, --verbose              explain what is being done
        \\  -h, --help                 display this help and exit
        \\  -V, --version              output version information and exit
        \\
        \\The backup suffix is '~', unless set with --suffix or SIMPLE_BACKUP_SUFFIX.
        \\The version control method may be selected via the --backup option or through
        \\the VERSION_CONTROL environment variable.
        \\
    , .{});
}

/// Main entry point for mv utility
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
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
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument\nTry '{s} --help' for more information.", .{prog_name});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try stdout_writer.print("mv ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    const files = parsed_args.positionals;
    if (files.len < 2) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing file operand\nTry '{s} --help' for more information.", .{prog_name});
        return @intFromEnum(common.ExitCode.general_error);
    }

    const options = MoveOptions{
        .interactive = parsed_args.interactive,
        .force = parsed_args.force,
        .verbose = parsed_args.verbose,
        .no_clobber = parsed_args.no_clobber,
    };

    // Handle multiple sources case
    if (files.len > 2) {
        // Multiple sources - destination must be a directory
        const dest = files[files.len - 1];
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "target '{s}' is not a directory", .{dest});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        };

        if (dest_stat.kind != .directory) {
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

            moveFile(allocator, source, full_dest, options, stdout_writer, stderr_writer) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot move '{s}' to '{s}': {}", .{ source, full_dest, err });
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

        // Check if destination is a directory
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, proceed with normal rename
                moveFile(allocator, source, dest, options, stdout_writer, stderr_writer) catch |move_err| {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot move '{s}' to '{s}': {}", .{ source, dest, move_err });
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
        if (dest_stat.kind == .directory) {
            const base_name = std.fs.path.basename(source);
            const full_dest = try std.fs.path.join(allocator, &.{ dest, base_name });
            defer allocator.free(full_dest);

            moveFile(allocator, source, full_dest, options, stdout_writer, stderr_writer) catch |move_err| {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot move '{s}' to '{s}': {}", .{ source, full_dest, move_err });
                return @intFromEnum(common.ExitCode.general_error);
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        } else {
            // Destination is a file, proceed with normal move/overwrite logic
            moveFile(allocator, source, dest, options, stdout_writer, stderr_writer) catch |move_err| {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot move '{s}' to '{s}': {}", .{ source, dest, move_err });
                return @intFromEnum(common.ExitCode.general_error);
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, dest });
            }
        }
        return @intFromEnum(common.ExitCode.success);
    }
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("mv");

test "mv fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testMvIntelligentWrapper, .{});
}

fn testMvIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("mv")) return;

    const MvIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(MvArgs, runUtility);
    try MvIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
