//! POSIX rmdir utility for removing empty directories.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Command-line arguments for rmdir.
///
/// Field order is GNU rmdir's own `longopts[]` order, because that is the
/// order an ambiguous abbreviation lists its candidates in (`rmdir --v` ->
/// '--verbose' '--version').
const RmdirArgs = struct {
    ignore_fail_on_non_empty: bool = false,
    parents: bool = false,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .parents = .{ .short = 'p', .desc = "Remove DIRECTORY and its ancestors; " ++
            "e.g., 'rmdir -p a/b/c' is similar to 'rmdir a/b/c a/b a'" },
        .verbose = .{ .short = 'v', .desc = "Output a diagnostic for every directory processed" },
        .ignore_fail_on_non_empty = .{ .short = 0, .desc = "Ignore each failure that is " ++
            "solely because a directory is non-empty" },
    };
};

/// Options for rmdir command.
const RmdirOptions = struct {
    parents: bool = false,
    verbose: bool = false,
    ignore_fail_on_non_empty: bool = false,
};

/// Simple iterator for parent directories.
const ParentIterator = struct {
    allocator: std.mem.Allocator,
    original: []u8,
    current: []const u8,

    /// Initialize iterator with a path.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !ParentIterator {
        const duped = try allocator.dupe(u8, path);
        // dupe returns a slice of identical length, so the iterator starts at the full path.
        std.debug.assert(duped.len == path.len);
        return .{
            .allocator = allocator,
            .original = duped,
            // current and original share the same backing slice at init.
            .current = duped,
        };
    }

    /// Clean up allocated memory.
    pub fn deinit(self: *ParentIterator) void {
        self.allocator.free(self.original);
    }

    /// Get the next parent directory in the hierarchy.
    pub fn next(self: *ParentIterator) ?[]const u8 {
        const parent = std.fs.path.dirname(self.current) orelse return null;

        // Don't return root or current directory
        if (std.mem.eql(u8, parent, "/") or std.mem.eql(u8, parent, ".")) {
            return null;
        }

        // dirname returns a strictly shorter leading subslice, guaranteeing the walk terminates.
        std.debug.assert(parent.len < self.current.len);
        // current only ever shrinks from the original, so the parent stays within it.
        std.debug.assert(parent.len < self.original.len);
        self.current = parent;
        return parent;
    }
};

/// Main entry point for rmdir utility.
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, run);
}

/// Run rmdir with provided writers for output
fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const prog_name = "rmdir";

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        RmdirArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const directories = parsed_args.positionals;
    if (directories.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    const options = RmdirOptions{
        .parents = parsed_args.parents,
        .verbose = parsed_args.verbose,
        .ignore_fail_on_non_empty = parsed_args.ignore_fail_on_non_empty,
    };

    // The missing-operand guard above returned for the empty case, so we have at least one.
    std.debug.assert(directories.len > 0);
    const exit_code = try removeDirectories(
        allocator,
        io,
        directories,
        stdout_writer,
        stderr_writer,
        options,
    );
    return @intFromEnum(exit_code);
}

/// Print help information to provided writer.
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const help_text =
        \\Usage: rmdir [OPTION]... DIRECTORY...
        \\Remove the DIRECTORY(ies), if they are empty.
        \\
        \\      --ignore-fail-on-non-empty
        \\                  ignore each failure that is solely because a directory
        \\                    is non-empty
        \\  -p, --parents   remove DIRECTORY and its ancestors; e.g., 'rmdir -p a/b/c' is
        \\                    similar to 'rmdir a/b/c a/b a'
        \\  -v, --verbose   output a diagnostic for every directory processed
        \\      --help      display this help and exit
        \\      --version   output version information and exit
        \\
    ;
    try common.help.printColorized(allocator, writer, help_text);
}

/// Print version information to provided writer.
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("rmdir ({s}) {s}\n", .{ common.name, common.version });
}

/// Remove directories with proper error handling.
fn removeDirectories(
    allocator: std.mem.Allocator,
    io: std.Io,
    directories: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmdirOptions,
) !common.ExitCode {
    // Callers only invoke this after the missing-operand guard, so there is always work to do.
    std.debug.assert(directories.len > 0);
    var had_error = false;

    for (directories) |dir| {
        // Refuse to remove "." or ".." to avoid EINVAL crash and match GNU behavior
        const base = std.fs.path.basename(dir);
        // basename returns the final component, always a subslice no longer than dir.
        std.debug.assert(base.len <= dir.len);
        if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rmdir",
                "refusing to remove '.' or '..' component from '{s}'",
                .{dir},
            );
            had_error = true;
            continue;
        }

        if (options.parents) {
            if (removeDirectoryWithParents(
                allocator,
                io,
                dir,
                stdout_writer,
                stderr_writer,
                options,
            )) |_| {
                // Success
            } else |err| {
                had_error = true;
                try handleError(allocator, err, dir, stderr_writer, options);
            }
        } else {
            if (removeSingleDirectory(io, dir, stdout_writer, stderr_writer, options)) |_| {
                // Success
            } else |err| {
                had_error = true;
                try handleError(allocator, err, dir, stderr_writer, options);
            }
        }
    }

    return if (had_error) .general_error else .success;
}

/// Remove a single directory.
fn removeSingleDirectory(
    io: std.Io,
    path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmdirOptions,
) !void {
    // stderr_writer unused here, errors handled by caller
    _ = stderr_writer;

    // Print verbose message before attempting removal (GNU behavior:
    // the message indicates the attempt, not success).
    if (options.verbose) {
        try stdout_writer.print("rmdir: removing directory, '{s}'\n", .{path});
    }

    std.Io.Dir.cwd().deleteDir(io, path) catch |err| {
        return switch (err) {
            error.DirNotEmpty => if (options.ignore_fail_on_non_empty) return else err,
            else => err,
        };
    };
}

/// Remove directory with its parent directories.
fn removeDirectoryWithParents(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmdirOptions,
) !void {
    // First remove the directory itself
    try removeSingleDirectory(io, path, stdout_writer, stderr_writer, options);

    // Remove parent directories
    var iter = try ParentIterator.init(allocator, path);
    defer iter.deinit();
    // Before any next() advances it, the iterator points at the full path.
    std.debug.assert(iter.current.len == path.len);
    // init keeps the immutable original snapshot at the full path length too.
    std.debug.assert(iter.original.len == path.len);

    while (iter.next()) |parent| {
        removeSingleDirectory(io, parent, stdout_writer, stderr_writer, options) catch |err| {
            // Stop on first error when removing parents
            if (options.ignore_fail_on_non_empty and err == error.DirNotEmpty) {
                return;
            }
            return err;
        };
    }
}

/// Handle errors with friendly messages.
fn handleError(
    allocator: std.mem.Allocator,
    err: anyerror,
    path: []const u8,
    stderr_writer: *std.Io.Writer,
    options: RmdirOptions,
) !void {
    if (options.ignore_fail_on_non_empty and err == error.DirNotEmpty) {
        return;
    }

    const suffix = switch (err) {
        error.DirNotEmpty => common.maybeHint(err, path, .write) orelse "",
        else => "",
    };
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "rmdir",
        "failed to remove '{s}': {s}{s}",
        .{ path, common.posixErrorString(err), suffix },
    );
}

// ===== TESTS =====

const TestDir = common.test_dir.TestDir;

test "rmdir: remove empty directory" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDir("empty");
    const dest = try td.getPath("empty");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = std.Io.Dir.cwd().statFile(io, dest, .{});
    try testing.expectError(error.FileNotFound, stat);
}

test "rmdir: fail on non-empty directory" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDir("nonempty");
    try td.createFile("nonempty/file.txt", "x", null);
    const dest = try td.getPath("nonempty");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.general_error, exit_code);

    const stat = try std.Io.Dir.cwd().statFile(io, dest, .{});
    try testing.expect(stat.kind == .directory);
}

test "rmdir: ignore fail on non-empty with flag" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDir("ignore_nonempty");
    try td.createFile("ignore_nonempty/file.txt", "x", null);
    const dest = try td.getPath("ignore_nonempty");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{
        .ignore_fail_on_non_empty = true,
    };

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = try std.Io.Dir.cwd().statFile(io, dest, .{});
    try testing.expect(stat.kind == .directory);
}

test "rmdir: verbose output" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDir("verbose");
    const dest = try td.getPath("verbose");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.success, exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), dest) != null);
}

test "rmdir: remove with parents" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDirPath("parents/sub/deep");

    var saved = try td.chdirToBase();
    defer TestDir.restoreCwd(&saved);

    const dirs = [_][]const u8{"parents/sub/deep"};
    const options = RmdirOptions{
        .parents = true,
        .verbose = true,
    };

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = std.Io.Dir.cwd().statFile(io, "parents", .{});
    try testing.expectError(error.FileNotFound, stat);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "parents/sub/deep") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "parents/sub") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "parents") != null);
}

test "rmdir: multiple directories" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDir("multi1");
    try td.createDir("multi2");
    try td.createDir("multi3");
    const d1 = try td.getPath("multi1");
    defer allocator.free(d1);
    const d2 = try td.getPath("multi2");
    defer allocator.free(d2);
    const d3 = try td.getPath("multi3");
    defer allocator.free(d3);

    const dirs = [_][]const u8{ d1, d2, d3 };
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.success, exit_code);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, d1, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, d2, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, d3, .{}));
}

test "rmdir: error on non-existent directory" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    const dest = try td.join("nonexistent_directory");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.general_error, exit_code);
}

test "rmdir: error on file instead of directory" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createFile("file.txt", "x", null);
    const dest = try td.getPath("file.txt");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.general_error, exit_code);

    const stat = try std.Io.Dir.cwd().statFile(io, dest, .{});
    try testing.expect(stat.kind == .file);
}

test "rmdir: parents stops on error" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDirPath("stop/sub/deep");
    try td.createFile("stop/sub/blocker.txt", "x", null);
    const deep = try td.getPath("stop/sub/deep");
    defer allocator.free(deep);
    const sub = try td.getPath("stop/sub");
    defer allocator.free(sub);
    const base = try td.getPath("stop");
    defer allocator.free(base);

    const dirs = [_][]const u8{deep};
    const options = RmdirOptions{
        .parents = true,
        .verbose = true,
    };

    _ = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, deep, .{}));
    const sub_stat = try std.Io.Dir.cwd().statFile(io, sub, .{});
    try testing.expect(sub_stat.kind == .directory);
    const base_stat = try std.Io.Dir.cwd().statFile(io, base, .{});
    try testing.expect(base_stat.kind == .directory);
}

test "rmdir: unicode path handling" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    var td = TestDir.init(allocator);
    defer td.deinit();
    try td.createDir("unicode_\xf0\x9f\x8e\xaf");
    const dest = try td.getPath("unicode_\xf0\x9f\x8e\xaf");
    defer allocator.free(dest);

    const dirs = [_][]const u8{dest};
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(
        allocator,
        io,
        &dirs,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = std.Io.Dir.cwd().statFile(io, dest, .{});
    try testing.expectError(error.FileNotFound, stat);
}

test "rmdir: parent iterator memory management" {
    const allocator = testing.allocator;

    const path = "a/b/c/d/e";
    var iter = try ParentIterator.init(allocator, path);
    defer iter.deinit();

    const parent1 = iter.next();
    try testing.expect(parent1 != null);
    try testing.expectEqualStrings("a/b/c/d", parent1.?);

    const parent2 = iter.next();
    try testing.expect(parent2 != null);
    try testing.expectEqualStrings("a/b/c", parent2.?);

    const parent3 = iter.next();
    try testing.expect(parent3 != null);
    try testing.expectEqualStrings("a/b", parent3.?);

    const parent4 = iter.next();
    try testing.expect(parent4 != null);
    try testing.expectEqualStrings("a", parent4.?);

    const parent5 = iter.next();
    try testing.expect(parent5 == null);
}

test "rmdir: error message consistency" {
    try testing.expectEqualStrings(
        "Directory not empty",
        common.posixErrorString(error.DirNotEmpty),
    );
    try testing.expectEqualStrings("Not a directory", common.posixErrorString(error.NotDir));
    try testing.expectEqualStrings(
        "Permission denied",
        common.posixErrorString(error.AccessDenied),
    );
    try testing.expectEqualStrings(
        "No such file or directory",
        common.posixErrorString(error.FileNotFound),
    );
}

test "rmdir: -p dotdot should fail with refusing message" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-p", ".." };
    const exit_code = try run(allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with non-zero exit code
    try testing.expect(exit_code != 0);

    // Should print an error about refusing to remove '.' or '..'
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove") != null);
}

test "rmdir: -p dot should fail with refusing message" {
    const io = testing.io;
    const allocator = testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-p", "." };
    const exit_code = try run(allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with non-zero exit code
    try testing.expect(exit_code != 0);

    // Should print an error about refusing to remove '.' or '..'
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove") != null);
}

test "rmdir: non-empty directory omits hint by default" {
    const saved_hints = common.env.test_stderr_hints;
    defer common.env.test_stderr_hints = saved_hints;
    common.env.test_stderr_hints = null;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "nonempty", .default_dir);
    const file = try tmp.dir.createFile(testing.io, "nonempty/file.txt", .{});
    file.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(
        testing.io,
        "nonempty",
        testing.allocator,
    );
    defer testing.allocator.free(dir_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{dir_path};
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "rmdir: failed to remove '{s}': Directory not empty\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expectEqualStrings(expected, stderr_aw.writer.buffered());
}

test "rmdir: non-empty directory appends recursive-removal hint" {
    const saved_hints = common.env.test_stderr_hints;
    defer common.env.test_stderr_hints = saved_hints;
    common.env.test_stderr_hints = true;
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{.{ .key = "NO_COLOR", .value = "1" }};
    common.env.test_overrides = &staged;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "nonempty", .default_dir);
    const file = try tmp.dir.createFile(testing.io, "nonempty/file.txt", .{});
    file.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(
        testing.io,
        "nonempty",
        testing.allocator,
    );
    defer testing.allocator.free(dir_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{dir_path};
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "rmdir: failed to remove '{s}': Directory not empty" ++
            " (use rm -r to remove recursively)\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expectEqualStrings(expected, stderr_aw.writer.buffered());
}
