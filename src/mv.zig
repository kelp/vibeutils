const std = @import("std");
const testing = std.testing;
const clap = @import("clap");
const common = @import("common/lib.zig");
const test_utils = @import("common/test_utils.zig");

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-V, --version           Output version information and exit.
    \\-i, --interactive       Prompt before overwrite.
    \\-f, --force             Force overwrite without prompting.
    \\-v, --verbose           Explain what is being done.
    \\-n, --no-clobber       Do not overwrite an existing file.
    \\<str>...                Source and destination paths.
    \\
);

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
    try moveFile(testing.allocator, old_path, new_path, .{});

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
    try moveFile(testing.allocator, source_path, dest_path, .{});

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
    try moveFile(testing.allocator, source_path, dest_path, .{});

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
    try moveFile(testing.allocator, source_path, dest_path, options);

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
    try moveFile(testing.allocator, source_path, dest_path, options);

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
    try moveFile(testing.allocator, source_path, dest_path, .{});

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
    try moveFile(testing.allocator, source_path, dest_path, .{});

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
    try moveFile(testing.allocator, source_path, dest_path, .{});

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
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{base_path, dest_name});
    defer testing.allocator.free(dest_path);

    // Run mv
    try moveFile(testing.allocator, source_path, dest_path, .{});

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("", content);
}

/// Cross-filesystem move helper using cp functionality.
///
/// This function is called when std.posix.rename fails with RenameAcrossMountPoints,
/// indicating that the source and destination are on different filesystems.
/// It performs a copy-then-delete operation to achieve the move.
///
/// @param allocator Memory allocator for temporary allocations
/// @param source Path to the source file or directory
/// @param dest Path to the destination
/// @param options Move options controlling verbose output, force mode, etc.
///
/// Returns error.OutOfMemory if allocation fails.
/// Returns filesystem errors from copy or delete operations.
fn crossFilesystemMove(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions) !void {
    // Import cp modules for cross-filesystem copy
    const cp_types = @import("cp/types.zig");
    const cp_engine = @import("cp/copy_engine.zig");
    const user_interaction = @import("cp/user_interaction.zig");

    if (options.verbose) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("mv: moving '{s}' to '{s}' (cross-filesystem)\n", .{ source, dest });
    }

    // Create cp options from mv options
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
    const source_basename = std.fs.path.basename(source);
    try user_interaction.UserInteraction.showProgress(0, 2, source_basename);

    // Execute copy with proper error handling
    engine.executeCopy(operation) catch |err| {
        // Clear progress on error
        user_interaction.UserInteraction.clearProgress() catch {};
        return err;
    };

    // Update progress after copy
    try user_interaction.UserInteraction.showProgress(1, 2, source_basename);

    // If copy succeeded, remove the source
    const source_stat = try std.fs.cwd().statFile(source);
    if (source_stat.kind == .directory) {
        try std.fs.cwd().deleteTree(source);
    } else {
        try std.fs.cwd().deleteFile(source);
    }

    // Complete progress
    try user_interaction.UserInteraction.showProgress(2, 2, source_basename);
}

/// Helper function to remove a destination file or directory.
/// 
/// Tries to remove as a file first, then as a directory tree if that fails.
/// This handles the case where we don't know if the destination is a file or directory.
/// 
/// @param dest Path to destination to remove
fn removeDestination(dest: []const u8) !void {
    std.fs.cwd().deleteFile(dest) catch |del_err| {
        // Might be a directory
        std.fs.cwd().deleteTree(dest) catch {
            return del_err;
        };
    };
}

/// Check if user wants to proceed with overwrite.
///
/// Prompts the user with a y/n question about overwriting the destination file.
/// Only the first character of the response is checked, case-insensitive.
///
/// @param dest Path to destination file being overwritten
/// @return true if user confirms (y/Y), false otherwise
fn promptOverwrite(dest: []const u8) !bool {
    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();

    try stderr.print("mv: overwrite '{s}'? ", .{dest});

    var buf: [16]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
    }
    return false;
}

/// Main move function that handles all mv operations.
///
/// This function attempts an atomic rename first, which is fast and preserves
/// all file attributes. If that fails due to cross-filesystem boundaries,
/// it falls back to a copy-then-delete operation.
///
/// The function handles various cases:
/// - no-clobber mode: skips if destination exists (check before operation for safe semantics)
/// - interactive mode: prompts user before overwriting
/// - force mode: removes destination and retries
/// - cross-filesystem moves: uses copy engine
///
/// @param allocator Memory allocator for temporary operations
/// @param source Path to source file or directory
/// @param dest Path to destination
/// @param options Move options (interactive, force, verbose, no_clobber)
///
/// Returns error.PathAlreadyExists if destination exists and no force/interactive
/// Returns error.FileNotFound if source doesn't exist
/// Returns error.PermissionDenied if lacking permissions
/// Returns other filesystem errors as appropriate
fn moveFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions) !void {
    // For no-clobber mode, check if destination exists first (acceptable TOCTOU for this use case)
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
            try crossFilesystemMove(allocator, source, dest, options);
        },
        error.PathAlreadyExists => {
            // Destination exists - handle based on options
            if (options.interactive and !options.force) {
                if (!try promptOverwrite(dest)) {
                    return; // User chose not to overwrite
                }
                // User approved, remove destination and retry
                try removeDestination(dest);
                // Retry the rename
                std.posix.rename(source, dest) catch |rename_err| switch (rename_err) {
                    error.RenameAcrossMountPoints => {
                        try crossFilesystemMove(allocator, source, dest, options);
                    },
                    else => return rename_err,
                };
            } else if (options.force) {
                // Force mode - remove destination and retry
                try removeDestination(dest);
                // Retry the rename
                std.posix.rename(source, dest) catch |rename_err| switch (rename_err) {
                    error.RenameAcrossMountPoints => {
                        try crossFilesystemMove(allocator, source, dest, options);
                    },
                    else => return rename_err,
                };
            } else {
                // No force, no interactive - fail
                return error.PathAlreadyExists;
            }
        },
        else => return err,
    };
}

const MoveOptions = struct {
    interactive: bool = false,
    force: bool = false,
    verbose: bool = false,
    no_clobber: bool = false,
};

/// Main entry point for the mv utility.
///
/// Parses command line arguments and performs move operations according to
/// GNU mv compatibility standards. Supports both single file moves and
/// multiple source files to a directory.
///
/// Command line options:
/// -i, --interactive: Prompt before overwrite
/// -f, --force: Force overwrite without prompting
/// -v, --verbose: Explain what is being done
/// -n, --no-clobber: Do not overwrite existing files
///
/// Examples:
///   mv file1.txt file2.txt     # Rename file1.txt to file2.txt
///   mv file1.txt dir/          # Move file1.txt into dir/
///   mv file*.txt backup/       # Move all matching files to backup/
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsers = comptime .{
        .str = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| switch (err) {
        error.InvalidArgument => {
            diag.report(std.io.getStdErr().writer(), err) catch {};
            std.process.exit(@intFromEnum(common.ExitCode.misuse));
        },
        else => return err,
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }
    if (res.args.version != 0) {
        common.CommonOpts.printVersion();
        return;
    }

    const args = res.positionals.@"0";
    if (args.len < 2) {
        common.printError("missing file operand", .{});
        common.printError("Try 'mv --help' for more information.", .{});
        std.process.exit(@intFromEnum(common.ExitCode.misuse));
    }

    const options = MoveOptions{
        .interactive = res.args.interactive != 0,
        .force = res.args.force != 0,
        .verbose = res.args.verbose != 0,
        .no_clobber = res.args.@"no-clobber" != 0,
    };

    // Handle multiple sources case
    if (args.len > 2) {
        // Multiple sources - destination must be a directory
        const dest = args[args.len - 1];
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => {
                common.printError("target '{s}' is not a directory", .{dest});
                std.process.exit(@intFromEnum(common.ExitCode.general_error));
            },
            else => return err,
        };

        if (dest_stat.kind != .directory) {
            common.printError("target '{s}' is not a directory", .{dest});
            std.process.exit(@intFromEnum(common.ExitCode.general_error));
        }

        // Move each source to destination directory
        // TODO: Consider parallel processing for multiple independent file moves
        // This could be implemented using a thread pool for better performance
        // when moving many files, but would require careful error handling
        for (args[0 .. args.len - 1]) |source| {
            const basename = std.fs.path.basename(source);
            const full_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
            defer allocator.free(full_dest);

            moveFile(allocator, source, full_dest, options) catch |err| {
                common.printError("cannot move '{s}' to '{s}': {}", .{ source, full_dest, err });
                std.process.exit(@intFromEnum(common.ExitCode.general_error));
            };

            if (options.verbose) {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        }
    } else {
        // Single source
        const source = args[0];
        const dest = args[1];

        moveFile(allocator, source, dest, options) catch |err| {
            common.printError("cannot move '{s}' to '{s}': {}", .{ source, dest, err });
            std.process.exit(@intFromEnum(common.ExitCode.general_error));
        };

        if (options.verbose) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("'{s}' -> '{s}'\n", .{ source, dest });
        }
    }
}
