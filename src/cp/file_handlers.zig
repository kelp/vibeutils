const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const errors = @import("errors.zig");
const path_resolver = @import("path_resolver.zig");
const user_interaction = @import("user_interaction.zig");

pub const FileHandlers = struct {
    /// Copy a regular file
    pub fn copyRegularFile(ctx: types.CopyContext, operation: types.CopyOperation, stats: *types.CopyStats) anyerror!void {
        // Get source file stats for size and attributes
        const source_stat = std.fs.cwd().statFile(operation.source) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "stat source file",
                .source_path = operation.source,
            };
            errors.ErrorHandler.reportError(context, copy_err);
            stats.addError();
            return copy_err;
        };

        // Handle force overwrite if needed
        if (operation.dest_exists and ctx.options.force) {
            try user_interaction.UserInteraction.handleForceOverwrite(operation.final_dest_path);
        }

        // Copy the file
        std.fs.cwd().copyFile(operation.source, std.fs.cwd(), operation.final_dest_path, .{}) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "copy file",
                .source_path = operation.source,
                .dest_path = operation.final_dest_path,
            };
            errors.ErrorHandler.reportError(context, copy_err);
            stats.addError();
            return copy_err;
        };

        // Preserve attributes if requested
        if (ctx.options.preserve) {
            try preserveFileAttributes(operation.source, operation.final_dest_path, source_stat);
        }

        stats.addFile(@intCast(source_stat.size));
    }

    /// Copy a symbolic link
    pub fn copySymlink(ctx: types.CopyContext, operation: types.CopyOperation, stats: *types.CopyStats) anyerror!void {
        // Get symlink target
        const target = path_resolver.PathResolver.getSymlinkTarget(ctx.allocator, operation.source) catch |err| {
            const copy_err = errors.ErrorHandler.mapSystemError(err);
            const context = errors.ErrorContext{
                .operation = "read symlink",
                .source_path = operation.source,
            };
            errors.ErrorHandler.reportError(context, copy_err);
            stats.addError();
            return copy_err;
        };
        defer ctx.allocator.free(target);

        // Handle destination conflicts
        if (operation.dest_exists) {
            if (ctx.options.force) {
                try user_interaction.UserInteraction.handleForceOverwrite(operation.final_dest_path);
            } else {
                const copy_err = errors.destinationExists(operation.final_dest_path);
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
            errors.ErrorHandler.reportError(context, copy_err);
            stats.addError();
            return copy_err;
        };

        stats.addSymlink();
    }

    /// Copy a directory recursively
    pub fn copyDirectory(ctx: types.CopyContext, operation: types.CopyOperation, stats: *types.CopyStats) anyerror!void {
        if (!ctx.options.recursive) {
            const copy_err = errors.recursionNotAllowed(operation.source);
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
                    errors.ErrorHandler.reportError(context, copy_err);
                    stats.addError();
                    return copy_err;
                };

                if (dest_stat.kind != .directory) {
                    const context = errors.ErrorContext{
                        .operation = "create directory",
                        .source_path = operation.source,
                        .dest_path = operation.final_dest_path,
                    };
                    errors.ErrorHandler.reportError(context, errors.CopyError.DestinationIsNotDirectory);
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
                errors.ErrorHandler.reportError(context, copy_err);
                stats.addError();
                return copy_err;
            },
        };

        // Copy directory contents
        try copyDirectoryContents(ctx, operation.source, operation.final_dest_path, stats);

        // Preserve directory attributes if requested
        if (ctx.options.preserve) {
            const source_stat = std.fs.cwd().statFile(operation.source) catch |err| {
                const copy_err = errors.ErrorHandler.mapSystemError(err);
                const context = errors.ErrorContext{
                    .operation = "stat source directory",
                    .source_path = operation.source,
                };
                errors.ErrorHandler.reportError(context, copy_err);
                stats.addError();
                return copy_err;
            };

            try preserveFileAttributes(operation.source, operation.final_dest_path, source_stat);
        }

        stats.addDirectory();
    }
};

/// Copy contents of a directory recursively
fn copyDirectoryContents(ctx: types.CopyContext, source_dir: []const u8, dest_dir: []const u8, stats: *types.CopyStats) anyerror!void {
    var source = std.fs.cwd().openDir(source_dir, .{ .iterate = true }) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "open source directory",
            .source_path = source_dir,
        };
        errors.ErrorHandler.reportError(context, copy_err);
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
            errors.ErrorHandler.reportError(context, copy_err);
            stats.addError();
            continue; // Skip this entry but continue with others
        };
        defer entry_operation.deinit(ctx.allocator);

        // Execute copy based on entry type
        switch (entry_operation.source_type) {
            .regular_file => FileHandlers.copyRegularFile(ctx, entry_operation, stats) catch {
                // Error already reported in copyRegularFile
                continue;
            },
            .symlink => {
                if (ctx.options.no_dereference) {
                    FileHandlers.copySymlink(ctx, entry_operation, stats) catch {
                        // Error already reported in copySymlink
                        continue;
                    };
                } else {
                    // Follow the symlink and copy the target
                    FileHandlers.copyRegularFile(ctx, entry_operation, stats) catch {
                        // Error already reported in copyRegularFile
                        continue;
                    };
                }
            },
            .directory => {
                FileHandlers.copyDirectory(ctx, entry_operation, stats) catch {
                    // Error already reported in copyDirectory, continue with next entry
                };
            },
            .special => {
                const context = errors.ErrorContext{
                    .operation = "copy special file",
                    .source_path = source_path,
                };
                errors.ErrorHandler.reportError(context, errors.CopyError.UnsupportedFileType);
                stats.addError();
                continue;
            },
        }
    }
}

/// Preserve file attributes (mode, timestamps)
fn preserveFileAttributes(source_path: []const u8, dest_path: []const u8, source_stat: std.fs.File.Stat) !void {
    // Open destination file to set attributes
    const dest_file = std.fs.cwd().openFile(dest_path, .{}) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "open destination for attribute preservation",
            .dest_path = dest_path,
        };
        errors.ErrorHandler.reportError(context, copy_err);
        return copy_err;
    };
    defer dest_file.close();

    // Copy mode/permissions
    dest_file.chmod(source_stat.mode) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "preserve file mode",
            .source_path = source_path,
            .dest_path = dest_path,
        };
        errors.ErrorHandler.reportError(context, copy_err);
        return copy_err;
    };

    // Copy timestamps
    dest_file.updateTimes(source_stat.atime, source_stat.mtime) catch |err| {
        const copy_err = errors.ErrorHandler.mapSystemError(err);
        const context = errors.ErrorContext{
            .operation = "preserve file timestamps",
            .source_path = source_path,
            .dest_path = dest_path,
        };
        errors.ErrorHandler.reportError(context, copy_err);
        return copy_err;
    };
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

    var stats = types.CopyStats{};
    try FileHandlers.copyRegularFile(context, operation, &stats);

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

    var stats = types.CopyStats{};
    try FileHandlers.copySymlink(context, operation, &stats);

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

    var stats = types.CopyStats{};
    try FileHandlers.copyDirectory(context, operation, &stats);

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

    var stats = types.CopyStats{};
    try FileHandlers.copyRegularFile(context, operation, &stats);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");
    try testing.expectEqual(source_stat.mode, dest_stat.mode);
}
