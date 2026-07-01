//! Move (rename) files and directories with atomic rename and cross-filesystem support

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const test_utils = common.test_utils;
const assert = std.debug.assert;

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
        return try test_utils.createUniqueTestFile(
            testing.io,
            self.inner.tmp_dir.dir,
            self.inner.allocator,
            base_name,
            content,
        );
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
    try moveFile(
        testing.allocator,
        testing.io,
        old_path,
        new_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, source_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

    // Verify original is gone
    try testing.expect(!test_dir.fileExists(source_name));

    // Verify file exists in new location
    const moved_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ subdir_name, source_name });
    defer testing.allocator.free(moved_path);
    const moved_file = try test_dir.inner.tmp_dir.dir.openFile(testing.io, moved_path, .{});
    moved_file.close(testing.io);

    // Verify content is preserved
    const content = try test_dir.inner.tmp_dir.dir.readFileAlloc(
        testing.io,
        moved_path,
        testing.allocator,
        .limited(1024),
    );
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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

    // Verify original directory is gone
    test_dir.inner.tmp_dir.dir.access(testing.io, "source_dir", .{}) catch |err| {
        try testing.expect(err == error.FileNotFound);
    };

    // Verify new directory exists with file intact
    const moved_file =
        try test_dir.inner.tmp_dir.dir.openFile(testing.io, "dest_dir/file.txt", .{});
    defer moved_file.close(testing.io);

    // Verify content is preserved
    const content = try test_dir.inner.tmp_dir.dir.readFileAlloc(
        testing.io,
        "dest_dir/file.txt",
        testing.allocator,
        .limited(1024),
    );
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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    // Run mv
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

    // Verify move worked
    try testing.expect(!test_dir.fileExists(source_name));
    try testing.expect(test_dir.fileExists(dest_name));
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("", content);
}

/// Move across filesystems using copy-then-delete.
///
/// The copy stage uses the bounded common.walker (no recursion). The source is
/// only deleted when EVERY entry copied cleanly; on any failure we report all
/// errors, keep BOTH dest and source intact (data safety), and return an error.
fn crossFilesystemMove(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    assert(source.len > 0);
    assert(dest.len > 0);

    if (options.verbose) {
        try stdout_writer.print(
            "mv: moving '{s}' to '{s}' (cross-filesystem)\n",
            .{ source, dest },
        );
    }

    // Determine if the source is a directory; this selects the copy strategy.
    const source_info = common.file.FileInfo.stat(io, source) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot stat '{s}': {}",
            .{ source, err },
        );
        return err;
    };
    const is_directory = (source_info.kind == .directory);

    // Copy stage. On a SINGLE-file copy failure the dest is incomplete, so we
    // wipe the partial dest before returning (errdefer below). For a directory
    // tree we must NOT blanket-wipe: the partial dest is kept for data safety
    // and the removal stage is skipped, so no errdefer covers the tree branch.
    if (is_directory) {
        try copyDirectoryTree(
            allocator,
            io,
            source,
            dest,
            options,
            stdout_writer,
            stderr_writer,
        );
    } else {
        errdefer std.Io.Dir.cwd().deleteFile(io, dest) catch {};
        try common.file_ops.copyFileWithAttributes(
            allocator,
            io,
            stderr_writer,
            "mv",
            source,
            dest,
            source_info,
        );
    }

    // Copy succeeded for every entry. Remove the source (copy-then-delete).
    // No errdefer that wipes dest is in scope here: a removal-stage failure
    // leaves the completed dest in place and surfaces an error.
    if (options.verbose) {
        try stdout_writer.print("mv: removing source '{s}'\n", .{source});
    }
    try removeSourceAfterCopy(allocator, io, source, is_directory, stderr_writer);

    if (options.verbose) {
        try stdout_writer.print("mv: completed cross-filesystem move\n", .{});
    }
}

/// Remove the source after a successful copy. A failure here leaves the source
/// in place (e.g. a read-only source directory blocks unlink) and reports it;
/// the dest is already complete, so it is never touched.
fn removeSourceAfterCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_directory: bool,
    stderr_writer: anytype,
) !void {
    assert(source.len > 0);

    if (is_directory) {
        std.Io.Dir.cwd().deleteTree(io, source) catch |del_err| {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "failed to remove source directory '{s}': {}",
                .{ source, del_err },
            );
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "copy completed successfully but source directory remains - please remove manually",
                .{},
            );
            return del_err;
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, source) catch |del_err| {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "failed to remove source file '{s}': {}",
                .{ source, del_err },
            );
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "copy completed successfully but source file remains - please remove manually",
                .{},
            );
            return del_err;
        };
    }
}

/// Copy a directory tree across filesystems using the bounded common.walker.
///
/// Order is `.both`: a directory is materialized on its pre-order visit (with a
/// WRITABLE mode so children can be written) and has its real mode + timestamps
/// applied on its post-order visit (after children are written, which would
/// otherwise bump the parent mtime). Per-entry errors are reported and the walk
/// CONTINUES with siblings (GNU semantics); any failure means the source tree is
/// kept and an error is returned.
fn copyDirectoryTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    assert(source.len > 0);
    assert(dest.len > 0);

    const walk_config = common.walker.WalkConfig{
        .order = .both,
        .symlinks = .no_follow,
        .detect_cycles = true,
    };
    var dir_walker = try common.walker.Walker.init(allocator, walk_config);
    defer dir_walker.deinit(io);
    try dir_walker.addRoot(source);

    var had_copy_error = false;
    // The bounded walker drives termination: next() yields null when the
    // traversal is exhausted (the `orelse break` below), and a per-entry error
    // drives `continue`, so only exhaustion ends this loop. No numeric cap: the
    // tree depth/breadth is unbounded a priori and a cap would truncate it.
    while (true) { // tiger:allow:unbounded-loop terminates when walker.next() returns null
        const maybe_entry = dir_walker.next(io) catch |err| {
            // A per-entry error (e.g. opening an unreadable subdir) is reported
            // and the walk continues with siblings. The walker discards the
            // failing child path on error, so recover it from the parent.
            recoverDescendError(allocator, io, &dir_walker, source, dest, stderr_writer, err);
            had_copy_error = true;
            continue;
        };
        const entry = maybe_entry orelse break;
        handleWalkEntry(
            allocator,
            io,
            entry,
            source,
            dest,
            options,
            stdout_writer,
            stderr_writer,
        ) catch {
            had_copy_error = true;
        };
    }

    // Keep dest AND source on any failure; the caller skips source removal.
    if (had_copy_error) return error.SomeCopyFailed;
}

/// Map a source entry path onto its destination path by replacing the source
/// root prefix with the dest root prefix. Caller owns the returned buffer.
fn destPathFor(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    dest_root: []const u8,
    entry_path: []const u8,
) ![]u8 {
    assert(source_root.len > 0);
    assert(dest_root.len > 0);
    assert(entry_path.len >= source_root.len);
    assert(std.mem.startsWith(u8, entry_path, source_root));
    const suffix = entry_path[source_root.len..];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ dest_root, suffix });
}

/// Dispatch a single walker entry to the matching copy action. Errors are
/// surfaced to the driver loop, which records them and continues with siblings.
fn handleWalkEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry: common.walker.Entry,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    assert(source.len > 0);
    assert(dest.len > 0);
    assert(std.mem.startsWith(u8, entry.path, source));

    const dest_path = try destPathFor(allocator, source, dest, entry.path);
    defer allocator.free(dest_path);

    switch (entry.kind) {
        .directory => switch (entry.visit) {
            .pre => try materializeDestDir(allocator, io, dest_path, stderr_writer),
            .post => try preserveCopiedDir(
                allocator,
                io,
                entry.path,
                dest_path,
                options,
                stdout_writer,
                stderr_writer,
            ),
        },
        .file => try copyTreeFile(
            allocator,
            io,
            entry.path,
            dest_path,
            options,
            stdout_writer,
            stderr_writer,
        ),
        .sym_link => try recreateSymlink(allocator, io, entry.path, dest_path, stderr_writer),
        // Skip block/char/pipe/socket nodes, matching the prior behavior.
        else => {
            if (options.verbose) {
                try stdout_writer.print("mv: skipping special file '{s}'\n", .{entry.path});
            }
        },
    }
}

/// Create the destination directory with a WRITABLE mode (0o755) so child
/// entries can be written even when the source directory is read-only. The real
/// source mode is reapplied post-order by preserveCopiedDir.
fn materializeDestDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest_path: []const u8,
    stderr_writer: anytype,
) !void {
    assert(dest_path.len > 0);
    const writable_mode = std.Io.File.Permissions.fromMode(0o755);
    std.Io.Dir.cwd().createDir(io, dest_path, writable_mode) catch |err| switch (err) {
        // An existing directory is fine (re-running into a prepared dest).
        error.PathAlreadyExists => return,
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "cannot create directory '{s}': {}",
                .{ dest_path, err },
            );
            return err;
        },
    };
}

/// Apply the source directory's mode and timestamps to the destination on its
/// post-order visit (after children are written). Also prints the verbose line.
fn preserveCopiedDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    dest_path: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    assert(source_path.len > 0);
    assert(dest_path.len > 0);

    const source_info = common.file.FileInfo.stat(io, source_path) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot stat directory '{s}': {}",
            .{ source_path, err },
        );
        return err;
    };
    _ = common.file_ops.preserveDirAttributes(
        allocator,
        io,
        stderr_writer,
        "mv",
        dest_path,
        source_info.mode,
        source_info.atime,
        source_info.mtime,
    );

    if (options.verbose) {
        try stdout_writer.print("'{s}' -> '{s}'\n", .{ source_path, dest_path });
    }
}

/// Copy a single regular file with attribute preservation, then print the
/// verbose line. Stat first so copyFileWithAttributes carries mode/mtime/owner.
fn copyTreeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    dest_path: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    assert(source_path.len > 0);
    assert(dest_path.len > 0);

    const source_info = common.file.FileInfo.stat(io, source_path) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot stat file '{s}': {}",
            .{ source_path, err },
        );
        return err;
    };
    try common.file_ops.copyFileWithAttributes(
        allocator,
        io,
        stderr_writer,
        "mv",
        source_path,
        dest_path,
        source_info,
    );

    if (options.verbose) {
        try stdout_writer.print("'{s}' -> '{s}'\n", .{ source_path, dest_path });
    }
}

/// Recreate a symlink verbatim: read its target and create the same link at the
/// destination. The link is never followed (no_follow policy).
fn recreateSymlink(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    dest_path: []const u8,
    stderr_writer: anytype,
) !void {
    assert(source_path.len > 0);
    assert(dest_path.len > 0);

    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = std.Io.Dir.cwd().readLink(io, source_path, &target_buf) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot read symlink '{s}': {}",
            .{ source_path, err },
        );
        return err;
    };
    const target = target_buf[0..target_len];
    std.Io.Dir.cwd().symLink(io, target, dest_path, .{}) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot create symlink '{s}': {}",
            .{ dest_path, err },
        );
        return err;
    };
}

/// Recover the failing child after a walker descend error. The walker resets its
/// path buffer to the PARENT on a descend failure, so the failing child name is
/// lost. We re-scan the parent for a directory child whose dest does not yet
/// exist and that cannot be opened: that child is the culprit. We materialize
/// its (empty) dest directory and report it, matching GNU's continue-past-an-
/// unreadable-subdir behavior. Diagnostics only; never returns an error.
fn recoverDescendError(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_walker: *common.walker.Walker,
    source: []const u8,
    dest: []const u8,
    stderr_writer: anytype,
    walk_err: anyerror,
) void {
    assert(source.len > 0);
    assert(dest.len > 0);

    const parent_path = dir_walker.path_buf.items;
    if (parent_path.len < source.len) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot access '{s}': {}",
            .{ source, walk_err },
        );
        return;
    }
    var parent_dir = std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true }) catch {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot access '{s}': {}",
            .{ parent_path, walk_err },
        );
        return;
    };
    defer parent_dir.close(io);

    var iterator = parent_dir.iterate();
    while (iterator.next(io) catch null) |child| {
        if (child.kind != .directory) continue;
        recoverChild(allocator, io, parent_path, child.name, source, dest, stderr_writer, walk_err);
    }
}

/// Inspect one parent child during descend-error recovery. If its dest is
/// missing and it cannot be opened, it is the unreadable culprit: materialize
/// the empty dest dir and report it.
fn recoverChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_path: []const u8,
    child_name: []const u8,
    source: []const u8,
    dest: []const u8,
    stderr_writer: anytype,
    walk_err: anyerror,
) void {
    assert(parent_path.len > 0);
    assert(child_name.len > 0);
    assert(source.len > 0);
    assert(dest.len > 0);

    const child_source =
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, child_name }) catch return;
    defer allocator.free(child_source);
    const child_dest = destPathFor(allocator, source, dest, child_source) catch return;
    defer allocator.free(child_dest);

    // A child whose dest already exists was (or will be) handled by the walker.
    if (std.Io.Dir.cwd().access(io, child_dest, .{})) |_| return else |_| {}

    // A readable child is not the culprit; the walker reaches it normally.
    if (std.Io.Dir.cwd().openDir(io, child_source, .{ .iterate = true })) |opened| {
        var d = opened;
        d.close(io);
        return;
    } else |_| {}

    // Unreadable child: materialize its empty dest dir and report it.
    std.Io.Dir.cwd().createDir(io, child_dest, std.Io.File.Permissions.fromMode(0o755)) catch {};
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "mv",
        "cannot access '{s}': {}",
        .{ child_source, walk_err },
    );
}

/// Rename wrapper that handles EINVAL instead of panicking.
///
/// Zig's std.posix.rename maps EINVAL to `unreachable`, which causes a panic
/// when the kernel returns EINVAL (e.g., moving a directory into its own
/// subdirectory). This wrapper calls the C rename directly and maps EINVAL
/// to error.InvalidArgument so callers can handle it gracefully.
const SafeRenameError = std.Io.Dir.RenameError ||
    error{ InvalidArgument, CrossDevice, PathAlreadyExists };

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
fn moveFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
    hinted_overwrite: *bool,
) !void {
    // NOTE: source may be "" here. `mv -n "" srcB dst` / `mv -i "" srcB dst`
    // (non-tty) are valid argv (argparse keeps "" as a positional) and are
    // handled gracefully below (no-clobber skip / interactive default-no early
    // return) without ever renaming. So no `assert(source.len > 0)` here; it
    // would panic a previously-tolerated input. dest may likewise be "" (e.g.
    // `mv a ""`): isDestDirectory returns FileNotFound for it, so we reach here
    // and the empty path surfaces a normal FileNotFound rename error below.

    // Check for same file using fstat to compare both inode and device.
    // If source and dest are hardlinks (same inode, different paths),
    // just unlink the source and succeed.
    if (common.file_ops.isSameFile(io, source, dest)) {
        return moveFile_handleSameFile(allocator, io, source, dest, stderr_writer);
    }

    // For no-clobber mode, check if destination exists first
    // Note: This has a small TOCTOU window, but it's the standard approach used by GNU mv
    // The alternative would require filesystem-specific atomic operations not available in POSIX
    if (options.no_clobber) {
        const skip = try moveFile_checkNoClobber(
            allocator,
            io,
            dest,
            options,
            stdout_writer,
            stderr_writer,
        );
        if (skip) {
            return; // Destination exists, skip the move
        }
    }

    // Check if destination exists for interactive prompt, overwrite hint, and backup.
    // On Linux, rename() atomically overwrites without returning EEXIST, so we must
    // check before calling rename to give -i a chance to prompt (F36).
    const dest_exists = if (std.Io.Dir.cwd().access(io, dest, .{})) |_| true else |_| false;

    if (dest_exists and options.interactive) {
        if (!try moveFile_confirmInteractive(io, dest, stderr_writer)) {
            return; // Non-interactive stdin or user declined: skip the move
        }
    }

    // Print one-time overwrite hint when destination exists with -f (overwrite
    // succeeds, hint suggests -i).
    if (options.force and !options.interactive and !options.no_clobber and
        !hinted_overwrite.* and dest_exists)
    {
        moveFile_emitOverwriteHint(allocator, dest, stderr_writer, hinted_overwrite);
    }

    // Create backup of destination if it exists and backup mode is enabled
    if (options.backup and dest_exists) {
        try moveFile_createBackup(allocator, dest, options, stdout_writer, stderr_writer);
    }

    // Try atomic rename first (using safeRename to handle EINVAL gracefully)
    try moveFile_renameOrFallback(
        allocator,
        io,
        source,
        dest,
        options,
        stdout_writer,
        stderr_writer,
    );
}

/// Decide whether an interactive overwrite should proceed. Returns true to
/// proceed, false to skip. Only prompt if stdin is a terminal; otherwise
/// default to "no" (skip). Matches GNU mv behavior and prevents hangs when
/// stdin is not interactive (pipes, tests, etc.).
fn moveFile_confirmInteractive(io: std.Io, dest: []const u8, stderr_writer: anytype) !bool {
    std.debug.assert(dest.len > 0);
    // Positive space: an isatty decision is being made on the stdin handle.
    std.debug.assert(std.Io.File.stdin().handle >= 0);

    if (std.c.isatty(std.Io.File.stdin().handle) == 0) {
        return false; // Non-interactive stdin: default to no
    }
    return common.prompt.promptYesNo(io, stderr_writer, "mv: overwrite '{s}'? ", .{dest});
}

/// Emit the one-time "-f overwrote a destination" hint and mark it emitted.
/// Caller guards on the not-yet-hinted condition; this helper performs only the
/// straight-line print and flag set.
fn moveFile_emitOverwriteHint(
    allocator: std.mem.Allocator,
    dest: []const u8,
    stderr_writer: anytype,
    hinted_overwrite: *bool,
) void {
    std.debug.assert(dest.len > 0);
    // Negative space: must not be called once the hint has already fired.
    std.debug.assert(!hinted_overwrite.*);

    common.printHintWithProgram(
        allocator,
        stderr_writer,
        "mv",
        "use -i for interactive prompts before overwriting",
        .{},
    );
    hinted_overwrite.* = true;
}

/// Handle the same-file case detected by isSameFile: error on identical paths,
/// or unlink the source for hardlinks (same inode, different paths).
fn moveFile_handleSameFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    stderr_writer: anytype,
) !void {
    std.debug.assert(source.len > 0);
    std.debug.assert(dest.len > 0);

    if (std.mem.eql(u8, source, dest)) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "'{s}' and '{s}' are the same file",
            .{ source, dest },
        );
        return error.SameFile;
    }
    // Different names for the same inode (hardlink): remove the source link.
    std.Io.Dir.cwd().deleteFile(io, source) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot remove '{s}': {}",
            .{ source, err },
        );
        return error.SameFile;
    };
}

/// In no-clobber mode, check whether the destination exists. Returns true when
/// the move should be skipped (destination present), false to proceed.
fn moveFile_checkNoClobber(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !bool {
    std.debug.assert(dest.len > 0);
    std.debug.assert(options.no_clobber);

    if (std.Io.Dir.cwd().access(io, dest, .{})) |_| {
        // Destination exists, skip the move
        if (options.verbose) {
            try stdout_writer.print("mv: not overwriting '{s}' (no-clobber mode)\n", .{dest});
        }
        return true; // Silently skip as per GNU mv behavior
    } else |err| switch (err) {
        error.FileNotFound => {
            // Destination doesn't exist, proceed with normal move
            return false;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "error checking destination '{s}': {}",
                .{ dest, err },
            );
            return err;
        },
    }
}

/// Rename the existing destination to a "~"-suffixed backup before overwriting.
fn moveFile_createBackup(
    allocator: std.mem.Allocator,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    std.debug.assert(dest.len > 0);
    std.debug.assert(options.backup);

    const backup_name = try std.fmt.allocPrint(allocator, "{s}~", .{dest});
    defer allocator.free(backup_name);
    safeRename(dest, backup_name) catch |backup_err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot create backup '{s}': {}",
            .{ backup_name, backup_err },
        );
        return backup_err;
    };
    if (options.verbose) {
        try stdout_writer.print("mv: created backup '{s}'\n", .{backup_name});
    }
}

/// Handle a rename that returned PathAlreadyExists: without -f this is an error;
/// with -f, delete the destination and retry (falling back to a cross-filesystem
/// move if the delete fails).
fn moveFile_handlePathExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    // Destination exists but rename didn't overwrite (some filesystems)
    if (!options.force) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot overwrite '{s}': File exists (use -f to force or -i for interactive)",
            .{dest},
        );
        return error.PathAlreadyExists;
    }

    // Remove destination and retry rename (same-filesystem overwrite)
    std.Io.Dir.cwd().deleteFile(io, dest) catch {
        // If delete fails, fall back to cross-filesystem move
        return crossFilesystemMove(
            allocator,
            io,
            source,
            dest,
            options,
            stdout_writer,
            stderr_writer,
        );
    };
    safeRename(source, dest) catch |retry_err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "mv",
            "cannot rename '{s}' to '{s}': {}",
            .{ source, dest, retry_err },
        );
        return retry_err;
    };
}

/// Attempt an atomic rename, falling back to cross-filesystem copy or
/// force-overwrite retry depending on the error returned by rename(2).
fn moveFile_renameOrFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    // Try atomic rename first (using safeRename to handle EINVAL gracefully)
    safeRename(source, dest) catch |err| switch (err) {
        error.CrossDevice => {
            // Fall back to copy + remove
            return crossFilesystemMove(
                allocator,
                io,
                source,
                dest,
                options,
                stdout_writer,
                stderr_writer,
            );
        },
        error.PathAlreadyExists => {
            return moveFile_handlePathExists(
                allocator,
                io,
                source,
                dest,
                options,
                stdout_writer,
                stderr_writer,
            );
        },
        error.InvalidArgument => {
            // EINVAL: typically means moving a directory into a subdirectory of itself
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "cannot move '{s}' to a subdirectory of itself, '{s}'",
                .{ source, dest },
            );
            return error.InvalidArgument;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "mv",
                "cannot rename '{s}' to '{s}': {}",
                .{ source, dest, err },
            );
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

/// Validate the operand count. Returns the misuse exit code (after printing the
/// matching diagnostic) when fewer than two operands are given, or null to let
/// the caller proceed with at least a source and destination.
fn run_validateOperandCount(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    prog_name: []const u8,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    if (files.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing file operand\nTry '{s} --help' for more information.",
            .{prog_name},
        );
        return @intFromEnum(common.ExitCode.misuse);
    }
    if (files.len == 1) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing destination file operand after '{s}'\nTry '{s} --help' for more information.",
            .{ files[0], prog_name },
        );
        return @intFromEnum(common.ExitCode.misuse);
    }
    return null;
}

/// Run mv with provided writers for output
fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const prog_name = "mv";

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        MvArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.misuse);
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
    if (run_validateOperandCount(allocator, files, prog_name, stderr_writer)) |code| {
        return code;
    }
    assert(files.len >= 2);

    // GNU mv uses last-flag-wins for mutually exclusive -f, -i, -n.
    // Scan raw args to determine which appeared last (F38).
    const last_overwrite_flag = run_scanLastOverwriteFlag(args);

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
        return run_moveMultipleSources(
            allocator,
            io,
            files,
            options,
            stdout_writer,
            stderr_writer,
            &hinted_overwrite,
        );
    } else {
        return run_moveSingleSource(
            allocator,
            io,
            files[0],
            files[1],
            options,
            stdout_writer,
            stderr_writer,
            &hinted_overwrite,
        );
    }
}

/// Last-flag-wins overwrite flag, mirroring GNU mv's handling of the mutually
/// exclusive -f, -i, -n options.
const LastOverwriteFlag = enum { none, force, interactive, no_clobber };

/// Scan raw args for the last-appearing overwrite flag (-f/-i/-n and their long
/// forms), stopping at the "--" separator. GNU mv uses last-flag-wins (F38).
fn run_scanLastOverwriteFlag(args: []const []const u8) LastOverwriteFlag {
    std.debug.assert(args.len > 0);

    var last_overwrite_flag = LastOverwriteFlag.none;
    var scanned_count: u32 = 0;
    for (args) |arg| {
        scanned_count += 1;
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
    std.debug.assert(scanned_count <= args.len);
    return last_overwrite_flag;
}

/// Move every source operand into the destination directory. Continues past
/// per-source failures, returning general_error if any move failed.
fn run_moveMultipleSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
    hinted_overwrite: *bool,
) !u8 {
    const prog_name = "mv";
    std.debug.assert(files.len > 2);

    // Multiple sources - destination must be a directory
    const dest = files[files.len - 1];

    const dest_is_dir =
        isDestDirectory(io, dest, options.no_follow_symlink) catch |err| switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "target '{s}' is not a directory",
                    .{dest},
                );
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        };

    if (!dest_is_dir) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "target '{s}' is not a directory",
            .{dest},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Move each source to destination directory
    var exit_code = common.ExitCode.success;
    for (files[0 .. files.len - 1]) |source| {
        const basename = std.fs.path.basename(source);
        const full_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
        defer allocator.free(full_dest);

        moveFile(
            allocator,
            io,
            source,
            full_dest,
            options,
            stdout_writer,
            stderr_writer,
            hinted_overwrite,
        ) catch {
            exit_code = common.ExitCode.general_error;
            continue;
        };

        if (options.verbose) {
            try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, full_dest });
        }
    }
    return @intFromEnum(exit_code);
}

/// Move a single source to its destination: simple rename, move-into-directory,
/// or overwrite a file, depending on what the destination is.
fn run_moveSingleSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
    hinted_overwrite: *bool,
) !u8 {
    // Check if destination is a directory (respecting -h flag for symlinks)
    const dest_is_dir =
        isDestDirectory(io, dest, options.no_follow_symlink) catch |err| switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, proceed with normal rename
                return run_moveSingleSource_attempt(
                    allocator,
                    io,
                    source,
                    dest,
                    options,
                    stdout_writer,
                    stderr_writer,
                    hinted_overwrite,
                );
            },
            else => return err,
        };

    // If destination is a directory, move source into it
    if (dest_is_dir) {
        const base_name = std.fs.path.basename(source);
        const full_dest = try std.fs.path.join(allocator, &.{ dest, base_name });
        defer allocator.free(full_dest);

        return run_moveSingleSource_attempt(
            allocator,
            io,
            source,
            full_dest,
            options,
            stdout_writer,
            stderr_writer,
            hinted_overwrite,
        );
    } else {
        // Destination is a file, proceed with normal move/overwrite logic
        return run_moveSingleSource_attempt(
            allocator,
            io,
            source,
            dest,
            options,
            stdout_writer,
            stderr_writer,
            hinted_overwrite,
        );
    }
}

/// Perform one move attempt for the single-source case: run moveFile, map a
/// failure to general_error, print the verbose arrow on success.
fn run_moveSingleSource_attempt(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    dest: []const u8,
    options: MoveOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
    hinted_overwrite: *bool,
) !u8 {
    moveFile(
        allocator,
        io,
        source,
        dest,
        options,
        stdout_writer,
        stderr_writer,
        hinted_overwrite,
    ) catch {
        return @intFromEnum(common.ExitCode.general_error);
    };

    if (options.verbose) {
        try stdout_writer.print("'{s}' -> '{s}'\n", .{ source, dest });
    }
    return @intFromEnum(common.ExitCode.success);
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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .force = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

    // Source should be gone
    try testing.expect(!test_dir.fileExists(source_name));

    // Verify content integrity of destination
    const moved_content = try test_dir.inner.tmp_dir.dir.readFileAlloc(
        testing.io,
        dest_name,
        testing.allocator,
        .limited(large_size + 1),
    );
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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .force = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .interactive = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    ) catch {};

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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .force = true, .interactive = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .force = true, .backup = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var hinted = false;
    try moveFile(
        testing.allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .backup = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
        &hinted,
    );

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
    try test_dir.inner.tmp_dir.dir.symLink(
        testing.io,
        "real_dir",
        "symlink_to_dir",
        .{ .is_directory = true },
    );

    // Create a source file
    try test_dir.createFile("source.txt", "test content");

    // Get base path and construct symlink path manually (getBasePath doesn't follow symlinks)
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const symlink_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/symlink_to_dir", .{base_path});
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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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
    const dest_path =
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base_path, dest_name });
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // With last-flag-wins, no-clobber should override force:
    // destination should still have original content
    const content = try test_dir.readFile(dest_name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Original content preserved", content);

    // Source should still exist (move was skipped)
    try testing.expect(test_dir.fileExists(source_name));
}

// ===========================================================================
// Characterization tests for the cross-filesystem copy fallback.
//
// These lock in the behavior that the walker migration must preserve when it
// deletes copyDirectoryRecursive. They call crossFilesystemMove DIRECTLY: that
// signature is the stable unit boundary and survives the migration. No real
// EXDEV is needed because rename never fails cross-device inside one tmpDir;
// driving the fallback by hand exercises the exact copy-then-delete logic.
//
// These tests must PASS on the current (recursive) code and STAY GREEN after
// the walker rewrite. They are privileged (fakeroot) because they create and
// chmod directory trees; under fakeroot we get stable mode/timestamp behavior.
// ===========================================================================

const privilege_test = common.privilege_test;

test "privileged: crossFilesystemMove copies a multi-level tree then deletes source" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // Build a tree with files at depth 1, 2, and 3 plus an empty subdirectory.
    // A correct copy must reproduce every file at every depth and create the
    // empty directory; a wrong walk (e.g. dropping leaves or empty dirs) breaks
    // at least one of the assertions below.
    try test_dir.inner.createDir("src");
    try test_dir.inner.createFile("src/top.txt", "depth1", null);
    try test_dir.inner.createDir("src/sub");
    try test_dir.inner.createFile("src/sub/mid.txt", "depth2", null);
    try test_dir.inner.createDir("src/sub/deep");
    try test_dir.inner.createFile("src/sub/deep/leaf.txt", "depth3", null);
    try test_dir.inner.createDir("src/empty");

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    // Every file at every depth must be present in the destination with content
    // intact. expectFileContent fails loudly on a missing or corrupted copy.
    try test_dir.inner.expectFileContent("dst/top.txt", "depth1");
    try test_dir.inner.expectFileContent("dst/sub/mid.txt", "depth2");
    try test_dir.inner.expectFileContent("dst/sub/deep/leaf.txt", "depth3");

    // The empty subdirectory must be reproduced as a directory.
    const empty_info = try common.file.FileInfo.stat(
        testing.io,
        try std.fmt.allocPrint(allocator, "{s}/dst/empty", .{base_path}),
    );
    try testing.expectEqual(std.Io.File.Kind.directory, empty_info.kind);

    // The source tree must be gone after a successful move.
    try testing.expect(!test_dir.fileExists("src"));
}

test "privileged: fallback preserves regular file mode and mtime" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // A file with a distinctive non-default mode (0o741) so a copy that drops
    // permissions (e.g. createFile with default 0o644) fails the mode check.
    try test_dir.inner.createDir("src");
    try test_dir.inner.createFile("src/file.txt", "preserve me", 0o741);

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    // Capture source mtime before the move so we can compare it on the dest.
    const src_file_path = try std.fmt.allocPrint(allocator, "{s}/src/file.txt", .{base_path});
    const source_info = try common.file.FileInfo.stat(testing.io, src_file_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    const dest_file_path = try std.fmt.allocPrint(allocator, "{s}/dst/file.txt", .{base_path});
    const dest_info = try common.file.FileInfo.stat(testing.io, dest_file_path);

    // The source's permission bits must carry over to the destination file.
    try testing.expectEqual(@as(std.posix.mode_t, 0o741), dest_info.mode & 0o777);

    // The modification timestamp must be preserved (copyFileCross calls
    // setTimestamps). Compare to second resolution to tolerate filesystem
    // timestamp granularity while still catching a "now()" or zero mtime.
    const source_mtime_s = @divFloor(source_info.mtime, std.time.ns_per_s);
    const dest_mtime_s = @divFloor(dest_info.mtime, std.time.ns_per_s);
    try testing.expectEqual(source_mtime_s, dest_mtime_s);
}

test "privileged: fallback recreates inner symlinks verbatim without following" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // src/link points at "real_target" (a relative, possibly-dangling target).
    // The fallback must recreate the link with the SAME target string and must
    // NOT dereference it (no target content copied, the dest entry is a link).
    try test_dir.inner.createDir("src");
    try test_dir.inner.createFile("src/real_target", "target body", null);
    try test_dir.inner.tmp_dir.dir.symLink(testing.io, "real_target", "src/link", .{});

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    // The destination entry must itself be a symlink (lstat does not follow),
    // proving the link was recreated rather than dereferenced into a regular
    // file copy of the target body.
    const dest_link_path = try std.fmt.allocPrint(allocator, "{s}/dst/link", .{base_path});
    const link_info = try common.file.FileInfo.lstat(dest_link_path);
    try testing.expectEqual(std.Io.File.Kind.sym_link, link_info.kind);

    // The recreated link must carry the identical target string, verbatim.
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = try std.Io.Dir.cwd().readLink(testing.io, dest_link_path, &target_buf);
    try testing.expectEqualStrings("real_target", target_buf[0..target_len]);
}

test "privileged: fallback preserves writable directory mode" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // A writable subdirectory with a distinctive mode (0o750). The copy must
    // reproduce that mode on the destination directory. This must stay green
    // when the green phase moves mode application to post-order via
    // preserveDirAttributes. 0o750 is writable by the owner, so populating
    // children works regardless of pre- vs post-order timing.
    try test_dir.inner.createDir("src");
    try test_dir.inner.createDir("src/sub");
    try test_dir.inner.createFile("src/sub/child.txt", "child", null);
    // Set the distinctive mode via libc so it reliably persists to the inode.
    const sub_path_z = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/src/sub",
        .{try test_dir.inner.getBasePath()},
        0,
    );
    if (std.c.chmod(sub_path_z, 0o750) != 0) return error.SkipZigTest;

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    const dest_sub_path = try std.fmt.allocPrint(allocator, "{s}/dst/sub", .{base_path});
    const dest_info = try common.file.FileInfo.stat(testing.io, dest_sub_path);
    try testing.expectEqual(@as(std.posix.mode_t, 0o750), dest_info.mode & 0o777);

    // The child must still be copied so we know the mode did not block writes.
    try test_dir.inner.expectFileContent("dst/sub/child.txt", "child");
}

test "privileged: verbose fallback prints source and dest for each copied item" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    try test_dir.inner.createDir("src");
    try test_dir.inner.createFile("src/alpha.txt", "a", null);
    try test_dir.inner.createDir("src/sub");
    try test_dir.inner.createFile("src/sub/beta.txt", "b", null);

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{ .verbose = true },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Loose pin: verbose output must mention both copied files by name and emit
    // a per-item dest path for each, without pinning exact phrasing. A silent
    // (or stdout-empty) copy fails these. We assert the full per-file DEST
    // paths (not just the dest root prefix, which the unconditional header line
    // already prints) so a regression that drops per-file verbose lines but
    // keeps the header is caught here too.
    const out = stdout_aw.written();
    const dest_alpha = try std.fmt.allocPrint(allocator, "{s}/alpha.txt", .{dest_path});
    const dest_beta = try std.fmt.allocPrint(allocator, "{s}/sub/beta.txt", .{dest_path});
    try testing.expect(std.mem.find(u8, out, "alpha.txt") != null);
    try testing.expect(std.mem.find(u8, out, "beta.txt") != null);
    try testing.expect(std.mem.find(u8, out, source_path) != null);
    try testing.expect(std.mem.find(u8, out, dest_alpha) != null);
    try testing.expect(std.mem.find(u8, out, dest_beta) != null);
}

test "privileged: fallback copies a single regular file and removes the source" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // Drive the non-directory branch of crossFilesystemMove directly. The file
    // must arrive at the destination with its content and mode, and the source
    // must be removed (copy-then-delete).
    try test_dir.inner.createFile("only.txt", "single file body", 0o640);

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/only.txt", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/moved.txt", .{base_path});

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    try test_dir.inner.expectFileContent("moved.txt", "single file body");

    const dest_info = try common.file.FileInfo.stat(testing.io, dest_path);
    try testing.expectEqual(@as(std.posix.mode_t, 0o640), dest_info.mode & 0o777);

    // The source file must be gone.
    try testing.expect(!test_dir.fileExists("only.txt"));
}

test "privileged: failed copy leaves source tree intact and reports an error" {
    // Root bypasses read permissions, so a chmod-000 subdir would still open
    // and the failure path never triggers. Skip when effective uid is root
    // (mirrors cp's root-skip pattern; fakeroot reports root euid).
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // One readable file plus an unreadable subdirectory. Opening the locked
    // directory for iteration fails, forcing the copy to error out somewhere.
    try test_dir.inner.createDir("src");
    try test_dir.inner.createFile("src/readable.txt", "i am readable", null);
    try test_dir.inner.createDir("src/locked");
    try test_dir.inner.createFile("src/locked/secret.txt", "blocked", null);

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    // chmod 000 by absolute path via libc so it reliably persists to the inode;
    // restore in defer so TmpDir cleanup can recurse in. Skip if the platform
    // refuses to make it unreadable (some CI sandboxes ignore chmod).
    const locked_path_z =
        try std.fmt.allocPrintSentinel(allocator, "{s}/src/locked", .{base_path}, 0);
    if (std.c.chmod(locked_path_z, 0o000) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_path_z, 0o755);

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    const result = crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    // An error must be reported: crossFilesystemMove returns SOME error AND
    // writes a diagnostic to stderr. We assert ONLY the error-reported and
    // source-intact invariants. We deliberately do NOT pin the error variant
    // (the green phase's GNU-style continue-with-siblings driver, mirroring
    // cp, catches per-entry walker errors and returns an aggregate/sentinel
    // rather than propagating AccessDenied verbatim), nor that dest is absent
    // or that the copy aborted at the first failure. This test must stay green
    // across that change. On current recursive code the only possible error in
    // this tree is AccessDenied from openDir, so "any error" keeps full teeth.
    try testing.expect(std.meta.isError(result));
    try testing.expect(stderr_aw.written().len > 0);

    // DATA SAFETY: the entire source tree must remain intact. A move that
    // deleted any source on a failed copy would lose data. Restore the locked
    // directory's permissions first so this test can read back its contents;
    // the bytes-on-disk are what we verify, not the chmod we imposed.
    _ = std.c.chmod(locked_path_z, 0o755);
    try test_dir.inner.expectFileContent("src/readable.txt", "i am readable");
    try test_dir.inner.expectFileContent("src/locked/secret.txt", "blocked");
}

// ===========================================================================
// Intended-RED behavior-fix tests for the cross-filesystem copy fallback.
//
// These pin GNU mv semantics that the CURRENT recursive fallback gets WRONG;
// the walker rewrite fixes them. Unlike the characterization tests above
// (which stay green throughout), each of these is expected to FAIL on today's
// code at a specific KEY assertion and go GREEN after the migration. They
// follow the same boundary (crossFilesystemMove called directly) and the same
// root-skip idiom as the privileged characterization tests.
//
// Backdated mtime sentinel: 2020-01-02 00:00:00 UTC. A "now()" or zeroed dest
// mtime differs from this by years, so a second-granularity compare has teeth.
// ===========================================================================

const backdated_mtime_s: i128 = 1577923200; // 2020-01-02 00:00:00 UTC
const backdated_mtime_ns: i128 = backdated_mtime_s * std.time.ns_per_s;

test "walker-migration: cross-device fallback completes copy of read-only source subdir" {
    // Root bypasses the read-only-directory write block, so the GNU-vs-current
    // divergence on the removal side never triggers. Skip when euid is root
    // (mirrors the characterization tests; fakeroot reports root euid).
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // src/sub holds f.txt and carries a backdated mtime and a read-only (0o555)
    // mode. GNU mv COMPLETES the copy (dest/sub = 0o555, f.txt present, mtime
    // carried) and only then fails on the REMOVAL side (unlink inside a
    // read-only source dir needs write perm). Current code instead applies
    // 0o555 to dest/sub PRE-order, so createFile inside it fails AccessDenied
    // and the errdefer wipes the partial dest.
    try test_dir.inner.createDir("src");
    try test_dir.inner.createDir("src/sub");
    try test_dir.inner.createFile("src/sub/f.txt", "read only body", null);

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    // Backdate src/sub's mtime so we can verify dest/sub carries it forward.
    const sub_src_path = try std.fmt.allocPrint(allocator, "{s}/src/sub", .{base_path});
    std.Io.Dir.cwd().setTimestamps(testing.io, sub_src_path, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(backdated_mtime_ns) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(backdated_mtime_ns) } },
    }) catch return error.SkipZigTest;

    // Make src/sub read-only via libc so the bits persist; restore u+w in defer
    // so TmpDir cleanup can recurse in and unlink f.txt. Skip if the sandbox
    // refuses to honor the chmod.
    const sub_src_z = try std.fmt.allocPrintSentinel(allocator, "{s}/src/sub", .{base_path}, 0);
    if (std.c.chmod(sub_src_z, 0o555) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(sub_src_z, 0o755);

    // The move preserves 0o555 onto dst/sub, leaving a read-only dest dir with
    // f.txt inside. Restore u+w in defer so TmpDir cleanup can unlink the child;
    // otherwise the leak lands in .zig-cache/tmp and fails CI's cache-purge
    // (setup-zig post step) with EACCES. Registered before the move so it runs
    // at scope exit (after the assertions), when dst/sub exists at 0o555.
    const dest_sub_z = try std.fmt.allocPrintSentinel(allocator, "{s}/dst/sub", .{base_path}, 0);
    defer _ = std.c.chmod(dest_sub_z, 0o755);

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    const result = crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    // Post-fix the copy completes and the REMOVAL side fails (read-only source
    // dir): GNU exits nonzero, so an error return is expected. Today the COPY
    // side fails, which is ALSO an error return — so the error itself is NOT
    // the discriminating signal. The dest-side assertions below are.
    try testing.expect(std.meta.isError(result));

    // KEY RED ASSERTIONS (dest-side). Today the errdefer wipes the partial dest
    // after the copy aborts, so each of these fails. Post-fix the copy is
    // complete: dest/sub is a 0o555 directory, f.txt has its content, and
    // dest/sub carries the backdated mtime.
    const dest_sub_path = try std.fmt.allocPrint(allocator, "{s}/dst/sub", .{base_path});
    const dest_sub_info = try common.file.FileInfo.stat(testing.io, dest_sub_path);
    try testing.expectEqual(std.Io.File.Kind.directory, dest_sub_info.kind);
    try testing.expectEqual(@as(std.posix.mode_t, 0o555), dest_sub_info.mode & 0o777);

    try test_dir.inner.expectFileContent("dst/sub/f.txt", "read only body");

    const dest_sub_mtime_s = @divFloor(dest_sub_info.mtime, std.time.ns_per_s);
    try testing.expectEqual(backdated_mtime_s, dest_sub_mtime_s);

    // DATA SAFETY (green today, must stay green): the source must never be lost.
    // The removal side fails on a read-only source dir, so src/sub survives.
    try testing.expect(test_dir.fileExists("src/sub/f.txt"));
}

test "walker-migration: cross-device fallback preserves directory mtime" {
    // Fully writable, no chmod/ownership: this runs as a normal user under the
    // standard test step, so testing.allocator catches leaks. No root-skip and
    // no fakeroot needed — the divergence is mtime preservation, not perms.
    const allocator = testing.allocator;

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // A fully writable tree so the copy succeeds end to end. src/sub carries a
    // backdated mtime; GNU mv's dest/sub carries it forward, current code stamps
    // now-time (mv prints "directory timestamp preservation not implemented").
    try test_dir.inner.createDir("src");
    try test_dir.inner.createDir("src/sub");
    try test_dir.inner.createFile("src/sub/f.txt", "writable body", null);

    const base_path = try test_dir.inner.getBasePath();
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    defer allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});
    defer allocator.free(dest_path);

    // Backdate src/sub's mtime AFTER writing the child, since writing a child
    // bumps the parent's mtime.
    const sub_src_path = try std.fmt.allocPrint(allocator, "{s}/src/sub", .{base_path});
    defer allocator.free(sub_src_path);
    std.Io.Dir.cwd().setTimestamps(testing.io, sub_src_path, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(backdated_mtime_ns) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(backdated_mtime_ns) } },
    }) catch return error.SkipZigTest;

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    // Fully writable tree: the move must SUCCEED (no error).
    try crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    // KEY RED ASSERTION: dest/sub must carry the source dir's backdated mtime.
    // Today the dest dir is stamped now-time, so this fails by years.
    const dest_sub_path = try std.fmt.allocPrint(allocator, "{s}/dst/sub", .{base_path});
    defer allocator.free(dest_sub_path);
    const dest_sub_info = try common.file.FileInfo.stat(testing.io, dest_sub_path);
    const dest_sub_mtime_s = @divFloor(dest_sub_info.mtime, std.time.ns_per_s);
    try testing.expectEqual(backdated_mtime_s, dest_sub_mtime_s);

    // Green today: the success path deletes the source after copying.
    try testing.expect(!test_dir.fileExists("src"));
}

test "walker-migration: cross-device fallback continues past unreadable subdir (GNU semantics)" {
    // Root bypasses read permissions, so a chmod-000 subdir would still open and
    // the continue-past-error divergence never triggers. Skip when euid is root.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // src/locked (chmod 000) is unreadable; src/open/f.txt is a readable sibling.
    // GNU mv reports "cannot access .../locked", CONTINUES, materializes
    // dest/locked as an empty dir and dest/open/f.txt, exits 1, source retained.
    // Current code aborts at the first error and the errdefer wipes dest
    // entirely (dest absent afterward).
    try test_dir.inner.createDir("src");
    try test_dir.inner.createDir("src/locked");
    try test_dir.inner.createDir("src/open");
    try test_dir.inner.createFile("src/open/f.txt", "open body", null);

    const base_path = try test_dir.inner.getBasePath();
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src", .{base_path});
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dst", .{base_path});

    // chmod 000 src/locked via libc so the bits persist; restore in defer so
    // TmpDir cleanup can recurse in. Skip if the sandbox ignores the chmod.
    const locked_path_z =
        try std.fmt.allocPrintSentinel(allocator, "{s}/src/locked", .{base_path}, 0);
    if (std.c.chmod(locked_path_z, 0o000) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_path_z, 0o755);

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    const result = crossFilesystemMove(
        allocator,
        testing.io,
        source_path,
        dest_path,
        .{},
        common.null_writer,
        &stderr_aw.writer,
    );

    // An error return is expected BOTH today and post-fix (GNU exits 1). So the
    // error itself is not the discriminating signal; the dest-side assertions
    // below are.
    try testing.expect(std.meta.isError(result));

    // KEY RED ASSERTIONS (dest-side). Today the errdefer wipes dest entirely, so
    // both fail. Post-fix the walker continues past the unreadable subdir:
    // dest/open/f.txt is materialized with content and dest/locked exists as a
    // directory (mode unspecified, so not pinned).
    try test_dir.inner.expectFileContent("dst/open/f.txt", "open body");

    const dest_locked_path = try std.fmt.allocPrint(allocator, "{s}/dst/locked", .{base_path});
    const dest_locked_info = try common.file.FileInfo.stat(testing.io, dest_locked_path);
    try testing.expectEqual(std.Io.File.Kind.directory, dest_locked_info.kind);

    // Green today, stays green: a diagnostic mentioning the locked entry, and
    // the full source tree intact (no data loss on partial failure). Restore
    // locked's perms first so we can read its contents back.
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "locked") != null);
    _ = std.c.chmod(locked_path_z, 0o755);
    try testing.expect(test_dir.fileExists("src/locked"));
    try test_dir.inner.expectFileContent("src/open/f.txt", "open body");
}
