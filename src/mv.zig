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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, old_path, new_path, .{}, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, options, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, options, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(), stderr_buf.writer());

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
    var stdout_buf = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buf.deinit();
    try moveFile(testing.allocator, source_path, dest_path, .{}, stdout_buf.writer(), stderr_buf.writer());

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("", content);
}

/// Move across filesystems using copy-then-delete
fn crossFilesystemMove(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    // Import cp modules for cross-filesystem copy
    const cp_types = @import("cp/types.zig");
    const cp_engine = @import("cp/copy_engine.zig");
    const user_interaction = @import("cp/user_interaction.zig");

    if (options.verbose) {
        try stdout_writer.print("mv: moving '{s}' to '{s}' (cross-filesystem)\n", .{ source, dest });
    }

    // Create cp options from mv options
    // We always use recursive mode for cross-filesystem moves to handle directories
    const cp_options = cp_types.CpOptions{
        .recursive = true, // Always recursive for directories
        .preserve = true, // Preserve attributes
        .force = options.force,
        .interactive = options.interactive,
    };

    // Use cp's copy engine
    const cp_context = cp_types.CopyContext.create(allocator, cp_options);
    var engine = cp_engine.CopyEngine.init(cp_context);

    // Plan and execute the copy
    var operation = try cp_context.planOperation(source, dest);
    defer operation.deinit(allocator);

    // Show progress for cross-filesystem moves
    // Step 1 of 2: Copying files
    const source_basename = std.fs.path.basename(source);
    user_interaction.UserInteraction.showProgress(stderr_writer, 0, 2, source_basename) catch |progress_err| {
        // Progress display is optional - continue if it fails
        if (options.verbose) {
            common.printWarningWithProgram(stderr_writer, "mv", "failed to display progress: {}", .{progress_err});
        }
    };

    // Execute copy with proper error handling
    engine.executeCopy(stderr_writer, operation) catch |err| {
        // Clear progress on error and provide error message
        user_interaction.UserInteraction.clearProgress(stderr_writer) catch |clear_err| {
            if (options.verbose) {
                common.printWarningWithProgram(stderr_writer, "mv", "failed to clear progress display: {}", .{clear_err});
            }
        };
        common.printErrorWithProgram(stderr_writer, "mv", "error copying '{s}' to '{s}': {}", .{ source, dest, err });
        return err;
    };

    // Update progress after copy
    // Step 2 of 2: Removing source
    user_interaction.UserInteraction.showProgress(stderr_writer, 1, 2, source_basename) catch |progress_err| {
        if (options.verbose) {
            common.printWarningWithProgram(stderr_writer, "mv", "failed to display progress: {}", .{progress_err});
        }
    };

    // If copy succeeded, remove the source
    // We need to check if it's a directory to use the appropriate delete method
    const source_stat = try std.fs.cwd().statFile(source);
    if (source_stat.kind == .directory) {
        try std.fs.cwd().deleteTree(source);
    } else {
        try std.fs.cwd().deleteFile(source);
    }

    // Complete progress
    user_interaction.UserInteraction.showProgress(stderr_writer, 2, 2, source_basename) catch |progress_err| {
        if (options.verbose) {
            common.printWarningWithProgram(stderr_writer, "mv", "failed to display progress: {}", .{progress_err});
        }
    };
}

/// Remove destination file or directory
fn removeDestination(dest: []const u8) !void {
    std.fs.cwd().deleteFile(dest) catch |del_err| {
        // If deleteFile fails, it might be a directory
        // Try deleteTree, but if that also fails, return the original error
        std.fs.cwd().deleteTree(dest) catch {
            return del_err;
        };
    };
}

/// Prompt user for overwrite confirmation
fn promptOverwrite(dest: []const u8, stderr_writer: anytype) !bool {
    const stdin = std.io.getStdIn().reader();

    try stderr_writer.print("mv: overwrite '{s}'? ", .{dest});

    var buf: [16]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
    }
    return false;
}

/// Move file or directory with atomic rename or cross-filesystem copy
fn moveFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    // For no-clobber mode, check if destination exists first
    // Note: There's a TOCTOU (time-of-check-time-of-use) race here, but this is
    // acceptable for no-clobber mode as it's a best-effort safety feature
    if (options.no_clobber) {
        std.fs.cwd().access(dest, .{}) catch |err| switch (err) {
            error.FileNotFound => {}, // Destination doesn't exist, proceed
            else => return err,
        };
        // If we get here without error, destination exists, so skip
        return;
    }

    // Try atomic rename first
    std.posix.rename(source, dest) catch |err| switch (err) {
        error.RenameAcrossMountPoints => {
            // Fall back to copy + remove
            try crossFilesystemMove(allocator, source, dest, options, stdout_writer, stderr_writer);
        },
        error.PathAlreadyExists => {
            // Destination exists - handle based on options
            // Interactive mode takes precedence unless force is also specified
            if (options.interactive and !options.force) {
                if (!try promptOverwrite(dest, stderr_writer)) {
                    return; // User chose not to overwrite
                }
                // User approved, remove destination and retry
                try removeDestination(dest);
                // Retry the rename after removing destination
                // We might still get RenameAcrossMountPoints if on different filesystems
                std.posix.rename(source, dest) catch |rename_err| switch (rename_err) {
                    error.RenameAcrossMountPoints => {
                        try crossFilesystemMove(allocator, source, dest, options, stdout_writer, stderr_writer);
                    },
                    else => return rename_err,
                };
            } else if (options.force) {
                // Force mode - remove destination without asking and retry
                try removeDestination(dest);
                // Retry the rename after removing destination
                std.posix.rename(source, dest) catch |rename_err| switch (rename_err) {
                    error.RenameAcrossMountPoints => {
                        try crossFilesystemMove(allocator, source, dest, options, stdout_writer, stderr_writer);
                    },
                    else => return rename_err,
                };
            } else {
                // No force, no interactive - fail with error
                // This preserves existing files by default
                return error.PathAlreadyExists;
            }
        },
        else => return err,
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

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runMv(stdout_writer, stderr_writer, allocator);
    if (exit_code != common.ExitCode.success) {
        std.process.exit(@intFromEnum(exit_code));
    }
}

/// Run mv with provided writers for output
pub fn runMv(stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !common.ExitCode {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(MvArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(stderr_writer, prog_name, "unrecognized option\nTry '{s} --help' for more information.", .{prog_name});
                return common.ExitCode.general_error;
            },
            error.MissingValue => {
                common.printErrorWithProgram(stderr_writer, prog_name, "option requires an argument\nTry '{s} --help' for more information.", .{prog_name});
                return common.ExitCode.general_error;
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    // Handle help
    if (args.help) {
        try printHelp(stdout_writer);
        return common.ExitCode.success;
    }

    // Handle version
    if (args.version) {
        try stdout_writer.print("mv ({s}) {s}\n", .{ common.name, common.version });
        return common.ExitCode.success;
    }

    const files = args.positionals;
    if (files.len < 2) {
        common.printErrorWithProgram(stderr_writer, prog_name, "missing file operand\nTry '{s} --help' for more information.", .{prog_name});
        return common.ExitCode.general_error;
    }

    const options = MoveOptions{
        .interactive = args.interactive,
        .force = args.force,
        .verbose = args.verbose,
        .no_clobber = args.no_clobber,
    };

    // Handle multiple sources case
    if (files.len > 2) {
        // Multiple sources - destination must be a directory
        const dest = files[files.len - 1];
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(stderr_writer, prog_name, "target '{s}' is not a directory", .{dest});
                return common.ExitCode.general_error;
            },
            else => return err,
        };

        if (dest_stat.kind != .directory) {
            common.printErrorWithProgram(stderr_writer, prog_name, "target '{s}' is not a directory", .{dest});
            return common.ExitCode.general_error;
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
                common.printErrorWithProgram(stderr_writer, prog_name, "cannot move '{s}' to '{s}': {}", .{ source, full_dest, err });
                exit_code = common.ExitCode.general_error;
                continue;
            };

            if (options.verbose) {
                try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        }
        return exit_code;
    } else {
        // Single source case: simple rename or move
        const source = files[0];
        const dest = files[1];

        moveFile(allocator, source, dest, options, stdout_writer, stderr_writer) catch |err| {
            common.printErrorWithProgram(stderr_writer, prog_name, "cannot move '{s}' to '{s}': {}", .{ source, dest, err });
            return common.ExitCode.general_error;
        };

        if (options.verbose) {
            try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, dest });
        }
        return common.ExitCode.success;
    }
}
