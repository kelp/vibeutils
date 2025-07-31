const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const types = @import("types.zig");
const errors = @import("errors.zig");
const path_resolver = @import("path_resolver.zig");
const user_interaction = @import("user_interaction.zig");
const common = @import("common");

pub const FileHandlers = struct {
    /// Copy a regular file
    pub fn copyRegularFile(stderr_writer: anytype, ctx: types.CopyContext, operation: types.CopyOperation, stats: *types.CopyStats) anyerror!void {
        // Get source file stats for size and attributes
        const source_stat = std.fs.cwd().statFile(operation.source) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "stat source file",
                .source_path = operation.source,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            stats.addError();
            return copy_err;
        };

        // Handle force overwrite if needed
        if (operation.dest_exists and ctx.options.force) {
            try user_interaction.UserInteraction.handleForceOverwrite(operation.final_dest_path);
        }

        // Copy the file with correct permissions
        if (ctx.options.preserve) {
            // When preserving attributes, create the file with the source's mode directly
            try copyFileWithMode(stderr_writer, operation.source, operation.final_dest_path, source_stat.mode, source_stat);
        } else {
            // Use standard copy when not preserving attributes
            std.fs.cwd().copyFile(operation.source, std.fs.cwd(), operation.final_dest_path, .{}) catch |err| {
                const copy_err = errors.ErrorHandler.mapSystemError(err);
                const context = errors.ErrorContext{
                    .operation = "copy file",
                    .source_path = operation.source,
                    .dest_path = operation.final_dest_path,
                };
                errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
                stats.addError();
                return copy_err;
            };
        }

        stats.addFile(@intCast(source_stat.size));
    }

    /// Copy a symbolic link
    pub fn copySymlink(stderr_writer: anytype, ctx: types.CopyContext, operation: types.CopyOperation, stats: *types.CopyStats) anyerror!void {
        // Get symlink target
        const target = path_resolver.PathResolver.getSymlinkTarget(ctx.allocator, operation.source) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "read symlink",
                .source_path = operation.source,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            stats.addError();
            return copy_err;
        };
        defer ctx.allocator.free(target);

        // Handle destination conflicts
        if (operation.dest_exists) {
            if (ctx.options.force) {
                try user_interaction.UserInteraction.handleForceOverwrite(operation.final_dest_path);
            } else {
                const copy_err = errors.destinationExists(stderr_writer, operation.final_dest_path);
                stats.addError();
                return copy_err;
            }
        }

        // Create the symlink
        std.fs.cwd().symLink(target, operation.final_dest_path, .{}) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "create symlink",
                .source_path = operation.source,
                .dest_path = operation.final_dest_path,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            stats.addError();
            return copy_err;
        };

        stats.addSymlink();
    }

    /// Copy a directory recursively
    pub fn copyDirectory(stderr_writer: anytype, ctx: types.CopyContext, operation: types.CopyOperation, stats: *types.CopyStats) anyerror!void {
        if (!ctx.options.recursive) {
            const copy_err = errors.recursionNotAllowed(stderr_writer, operation.source);
            stats.addError();
            return copy_err;
        }

        // Create destination directory
        std.fs.cwd().makeDir(operation.final_dest_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Check if existing path is a directory
                const dest_stat = std.fs.cwd().statFile(operation.final_dest_path) catch |stat_err| {
                    const copy_err = errors.ErrorHandler.mapSystemError(stat_err);
                    const context = errors.ErrorContext{
                        .operation = "stat destination",
                        .dest_path = operation.final_dest_path,
                    };
                    errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
                    stats.addError();
                    return copy_err;
                };

                if (dest_stat.kind != .directory) {
                    const context = errors.ErrorContext{
                        .operation = "create directory",
                        .source_path = operation.source,
                        .dest_path = operation.final_dest_path,
                    };
                    errors.ErrorHandler.reportError(stderr_writer, context, errors.CopyError.DestinationIsNotDirectory);
                    stats.addError();
                    return errors.CopyError.DestinationIsNotDirectory;
                }
            },
            else => {
                const copy_err = errors.ErrorHandler.mapSystemError(err);
                const context = errors.ErrorContext{
                    .operation = "create directory",
                    .source_path = operation.source,
                    .dest_path = operation.final_dest_path,
                };
                errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
                stats.addError();
                return copy_err;
            },
        };

        // Copy directory contents
        try copyDirectoryContents(stderr_writer, ctx, operation.source, operation.final_dest_path, stats);

        // Preserve directory attributes if requested
        if (ctx.options.preserve) {
            const source_stat = std.fs.cwd().statFile(operation.source) catch |err| {
                const copy_err = errors.ErrorHandler.mapSystemError(err);
                const context = errors.ErrorContext{
                    .operation = "stat source directory",
                    .source_path = operation.source,
                };
                errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
                stats.addError();
                return copy_err;
            };

            try preserveFileAttributes(stderr_writer, operation.source, operation.final_dest_path, source_stat);
        }

        stats.addDirectory();
    }
};

/// Copy contents of a directory recursively
fn copyDirectoryContents(stderr_writer: anytype, ctx: types.CopyContext, source_dir: []const u8, dest_dir: []const u8, stats: *types.CopyStats) anyerror!void {
    var source = std.fs.cwd().openDir(source_dir, .{ .iterate = true }) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "open source directory",
            .source_path = source_dir,
        };
        errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
        stats.addError();
        return copy_err;
    };
    defer source.close();

    var iterator = source.iterate();
    while (try iterator.next()) |entry| {
        const source_path = try std.fs.path.join(ctx.allocator, &[_][]const u8{ source_dir, entry.name });
        defer ctx.allocator.free(source_path);

        const dest_path = try std.fs.path.join(ctx.allocator, &[_][]const u8{ dest_dir, entry.name });
        defer ctx.allocator.free(dest_path);

        // Plan and execute copy operation for this entry
        var entry_operation = ctx.planOperation(source_path, dest_path) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "plan directory entry copy",
                .source_path = source_path,
                .dest_path = dest_path,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            stats.addError();
            continue; // Skip this entry but continue with others
        };
        defer entry_operation.deinit(ctx.allocator);

        // Execute copy based on entry type
        switch (entry_operation.source_type) {
            .regular_file => FileHandlers.copyRegularFile(stderr_writer, ctx, entry_operation, stats) catch {
                // Error already reported in copyRegularFile
                continue;
            },
            .symlink => {
                if (ctx.options.no_dereference) {
                    FileHandlers.copySymlink(stderr_writer, ctx, entry_operation, stats) catch {
                        // Error already reported in copySymlink
                        continue;
                    };
                } else {
                    // Follow the symlink and copy the target
                    FileHandlers.copyRegularFile(stderr_writer, ctx, entry_operation, stats) catch {
                        // Error already reported in copyRegularFile
                        continue;
                    };
                }
            },
            .directory => {
                FileHandlers.copyDirectory(stderr_writer, ctx, entry_operation, stats) catch {
                    // Error already reported in copyDirectory, continue with next entry
                };
            },
            .special => {
                const context = errors.ErrorContext{
                    .operation = "copy special file",
                    .source_path = source_path,
                };
                errors.ErrorHandler.reportError(stderr_writer, context, errors.CopyError.UnsupportedFileType);
                stats.addError();
                continue;
            },
        }
    }
}

/// Copy a file with specific mode (permissions) set atomically
fn copyFileWithMode(stderr_writer: anytype, source_path: []const u8, dest_path: []const u8, mode: std.fs.File.Mode, source_stat: std.fs.File.Stat) !void {
    // Open source file
    const source_file = std.fs.cwd().openFile(source_path, .{}) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "open source file",
            .source_path = source_path,
        };
        errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
        return copy_err;
    };
    defer source_file.close();

    // Create destination file with the correct mode
    const dest_file = std.fs.cwd().createFile(dest_path, .{ .mode = mode }) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "create destination file",
            .dest_path = dest_path,
        };
        errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
        return copy_err;
    };
    defer dest_file.close();

    // Copy the file contents
    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try source_file.read(&buffer);
        if (bytes_read == 0) break;
        try dest_file.writeAll(buffer[0..bytes_read]);
    }

    // Explicitly set the mode after creation to ensure it's correct
    // This is necessary because createFile's mode parameter can be affected by umask,
    // particularly under fakeroot where the umask behavior may differ
    try common.file_ops.setPermissions(dest_file, mode, dest_path);

    // Copy timestamps
    dest_file.updateTimes(source_stat.atime, source_stat.mtime) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "preserve file timestamps",
            .source_path = source_path,
            .dest_path = dest_path,
        };
        errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
        return copy_err;
    };
}

/// Preserve file attributes (mode, timestamps)
fn preserveFileAttributes(stderr_writer: anytype, source_path: []const u8, dest_path: []const u8, source_stat: std.fs.File.Stat) !void {
    // For directories, open as a directory
    if (source_stat.kind == .directory) {
        var dest_dir = std.fs.cwd().openDir(dest_path, .{}) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "open destination directory for attribute preservation",
                .dest_path = dest_path,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            return copy_err;
        };
        defer dest_dir.close();

        // Copy mode/permissions
        try common.file_ops.setPermissions(dest_dir, source_stat.mode, dest_path);

        // Copy timestamps
        // For directories, we need to use futimens/utimensat through posix API
        // since Dir doesn't expose updateTimes directly
        const handle = dest_dir.fd;
        const times = [2]std.posix.timespec{
            std.posix.timespec{
                .sec = @intCast(@divFloor(source_stat.atime, std.time.ns_per_s)),
                .nsec = @intCast(@mod(source_stat.atime, std.time.ns_per_s)),
            },
            std.posix.timespec{
                .sec = @intCast(@divFloor(source_stat.mtime, std.time.ns_per_s)),
                .nsec = @intCast(@mod(source_stat.mtime, std.time.ns_per_s)),
            },
        };
        std.posix.futimens(handle, &times) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "preserve directory timestamps",
                .source_path = source_path,
                .dest_path = dest_path,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            return copy_err;
        };
    } else {
        // For files, open as a file
        const dest_file = std.fs.cwd().openFile(dest_path, .{}) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "open destination file for attribute preservation",
                .dest_path = dest_path,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            return copy_err;
        };
        defer dest_file.close();

        // Copy mode/permissions
        try common.file_ops.setPermissions(dest_file, source_stat.mode, dest_path);

        // Copy timestamps
        dest_file.updateTimes(source_stat.atime, source_stat.mtime) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "preserve file timestamps",
                .source_path = source_path,
                .dest_path = dest_path,
            };
            errors.ErrorHandler.reportError(stderr_writer, context, copy_err);
            return copy_err;
        };
    }
}

// =============================================================================
// TESTS
// =============================================================================

const TestUtils = @import("test_utils.zig").TestUtils;

test "FileHandlers: copy regular file" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "Hello, World!");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{};
    var context = types.CopyContext.create(testing.allocator, options);
    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    var stats = types.CopyStats{};
    try FileHandlers.copyRegularFile(stderr_writer, context, operation, &stats);

    try test_dir.expectFileContent("dest.txt", "Hello, World!");
    try testing.expectEqual(@as(usize, 1), stats.files_copied);
}

test "FileHandlers: copy symlink" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("target.txt", "target content");
    try test_dir.createSymlink("target.txt", "link.txt");

    const link_path = try test_dir.joinPath("link.txt");
    defer testing.allocator.free(link_path);
    const dest_path = try test_dir.joinPath("copied_link.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .no_dereference = true };
    var context = types.CopyContext.create(testing.allocator, options);
    var operation = try context.planOperation(link_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    var stats = types.CopyStats{};
    try FileHandlers.copySymlink(stderr_writer, context, operation, &stats);

    try testing.expect(test_dir.isSymlink("copied_link.txt"));
    const target = try test_dir.getSymlinkTarget("copied_link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("target.txt", target);
    try testing.expectEqual(@as(usize, 1), stats.symlinks_copied);
}

test "FileHandlers: copy directory" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with content
    try test_dir.createDir("source_dir");
    try test_dir.createFile("source_dir/file1.txt", "File 1");
    try test_dir.createDir("source_dir/subdir");
    try test_dir.createFile("source_dir/subdir/file2.txt", "File 2");

    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest_dir");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .recursive = true };
    var context = types.CopyContext.create(testing.allocator, options);
    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    var stats = types.CopyStats{};
    try FileHandlers.copyDirectory(stderr_writer, context, operation, &stats);

    try test_dir.expectFileContent("dest_dir/file1.txt", "File 1");
    try test_dir.expectFileContent("dest_dir/subdir/file2.txt", "File 2");
    try testing.expectEqual(@as(usize, 2), stats.files_copied);
    try testing.expectEqual(@as(usize, 2), stats.directories_copied); // source_dir + subdir
}

test "FileHandlers: preserve attributes" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFileWithMode("source.txt", "content", 0o755);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .preserve = true };
    var context = types.CopyContext.create(testing.allocator, options);
    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    var stats = types.CopyStats{};
    try FileHandlers.copyRegularFile(stderr_writer, context, operation, &stats);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");
    try testing.expectEqual(source_stat.mode, dest_stat.mode);
}
