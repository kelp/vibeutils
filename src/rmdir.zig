/// POSIX rmdir utility for removing empty directories.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Command-line arguments for rmdir.
const RmdirArgs = struct {
    help: bool = false,
    version: bool = false,
    parents: bool = false,
    verbose: bool = false,
    ignore_fail_on_non_empty: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .parents = .{ .short = 'p', .desc = "Remove DIRECTORY and its ancestors; e.g., 'rmdir -p a/b/c' is similar to 'rmdir a/b/c a/b a'" },
        .verbose = .{ .short = 'v', .desc = "Output a diagnostic for every directory processed" },
        .ignore_fail_on_non_empty = .{ .short = 0, .desc = "Ignore each failure that is solely because a directory is non-empty" },
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
        return .{
            .allocator = allocator,
            .original = duped,
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

        self.current = parent;
        return parent;
    }
};

/// Map OS errors to friendly messages.
fn formatError(err: anyerror) []const u8 {
    return switch (err) {
        error.DirNotEmpty => "Directory not empty",
        error.NotDir => "Not a directory",
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        error.NameTooLong => "Path too long",
        else => @errorName(err),
    };
}

/// Main entry point for rmdir utility.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runRmdir(allocator, args[1..], stdout_writer, stderr_writer);
    std.process.exit(exit_code);
}

/// Run rmdir with provided writers for output
pub fn runRmdir(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const prog_name = "rmdir";

    const parsed_args = common.argparse.ArgParser.parse(RmdirArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(stdout_writer);
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

    const exit_code = try removeDirectories(allocator, directories, stdout_writer, stderr_writer, options);
    return @intFromEnum(exit_code);
}

/// Print help information to provided writer.
fn printHelp(writer: anytype) !void {
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
    try writer.writeAll(help_text);
}

/// Print version information to provided writer.
fn printVersion(writer: anytype) !void {
    try writer.print("rmdir ({s}) {s}\n", .{ common.name, common.version });
}

/// Remove directories with proper error handling.
fn removeDirectories(allocator: std.mem.Allocator, directories: []const []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmdirOptions) !common.ExitCode {
    var had_error = false;

    for (directories) |dir| {
        if (options.parents) {
            if (removeDirectoryWithParents(allocator, dir, stdout_writer, stderr_writer, options)) |_| {
                // Success
            } else |err| {
                had_error = true;
                try handleError(allocator, err, dir, stderr_writer, options);
            }
        } else {
            if (removeSingleDirectory(dir, stdout_writer, stderr_writer, options)) |_| {
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
fn removeSingleDirectory(path: []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmdirOptions) !void {
    _ = stderr_writer;

    std.fs.cwd().deleteDir(path) catch |err| {
        return switch (err) {
            error.DirNotEmpty => if (options.ignore_fail_on_non_empty) return else err,
            else => err,
        };
    };

    if (options.verbose) {
        try stdout_writer.print("rmdir: removing directory, '{s}'\n", .{path});
    }
}

/// Remove directory with its parent directories.
fn removeDirectoryWithParents(allocator: std.mem.Allocator, path: []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmdirOptions) !void {
    // First remove the directory itself
    try removeSingleDirectory(path, stdout_writer, stderr_writer, options);

    // Remove parent directories
    var iter = try ParentIterator.init(allocator, path);
    defer iter.deinit();

    while (iter.next()) |parent| {
        removeSingleDirectory(parent, stdout_writer, stderr_writer, options) catch |err| {
            // Stop on first error when removing parents
            if (options.ignore_fail_on_non_empty and err == error.DirNotEmpty) {
                return;
            }
            return err;
        };
    }
}

/// Handle errors with friendly messages.
fn handleError(allocator: std.mem.Allocator, err: anyerror, path: []const u8, stderr_writer: anytype, options: RmdirOptions) !void {
    if (options.ignore_fail_on_non_empty and err == error.DirNotEmpty) {
        return;
    }

    const msg = formatError(err);
    common.printErrorWithProgram(allocator, stderr_writer, "rmdir", "failed to remove '{s}': {s}", .{ path, msg });
}

// ===== TESTS =====

test "rmdir: remove empty directory" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const test_dir = "test_rmdir_empty";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = std.fs.cwd().statFile(test_dir);
    try testing.expectError(error.FileNotFound, stat);
}

test "rmdir: fail on non-empty directory" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const test_dir = "test_rmdir_nonempty";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const test_file = try std.fs.path.join(allocator, &.{ test_dir, "file.txt" });
    defer allocator.free(test_file);

    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.general_error, exit_code);

    const stat = try std.fs.cwd().statFile(test_dir);
    try testing.expect(stat.kind == .directory);
}

test "rmdir: ignore fail on non-empty with flag" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const test_dir = "test_rmdir_ignore_nonempty";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const test_file = try std.fs.path.join(allocator, &.{ test_dir, "file.txt" });
    defer allocator.free(test_file);

    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{
        .ignore_fail_on_non_empty = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = try std.fs.cwd().statFile(test_dir);
    try testing.expect(stat.kind == .directory);
}

test "rmdir: verbose output" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const test_dir = "test_rmdir_verbose";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_rmdir_verbose") != null);
}

test "rmdir: remove with parents" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const base_dir = "test_rmdir_parents";
    const deep_dir = "test_rmdir_parents/sub/deep";

    try std.fs.cwd().makePath(deep_dir);
    defer std.fs.cwd().deleteTree(base_dir) catch {};

    const dirs = [_][]const u8{deep_dir};
    const options = RmdirOptions{
        .parents = true,
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = std.fs.cwd().statFile(base_dir);
    try testing.expectError(error.FileNotFound, stat);

    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_rmdir_parents/sub/deep") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_rmdir_parents/sub") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_rmdir_parents") != null);
}

test "rmdir: multiple directories" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const dir1 = "test_rmdir_multi1";
    const dir2 = "test_rmdir_multi2";
    const dir3 = "test_rmdir_multi3";

    try std.fs.cwd().makeDir(dir1);
    defer std.fs.cwd().deleteDir(dir1) catch {};
    try std.fs.cwd().makeDir(dir2);
    defer std.fs.cwd().deleteDir(dir2) catch {};
    try std.fs.cwd().makeDir(dir3);
    defer std.fs.cwd().deleteDir(dir3) catch {};

    const dirs = [_][]const u8{ dir1, dir2, dir3 };
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(dir1));
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(dir2));
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(dir3));
}

test "rmdir: error on non-existent directory" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const dirs = [_][]const u8{"nonexistent_directory"};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.general_error, exit_code);
}

test "rmdir: error on file instead of directory" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const test_file = "test_rmdir_file.txt";
    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const dirs = [_][]const u8{test_file};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.general_error, exit_code);

    const stat = try std.fs.cwd().statFile(test_file);
    try testing.expect(stat.kind == .file);
}

test "rmdir: parents stops on error" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const base_dir = "test_rmdir_parents_stop";
    const sub_dir = "test_rmdir_parents_stop/sub";
    const deep_dir = "test_rmdir_parents_stop/sub/deep";

    try std.fs.cwd().makePath(deep_dir);
    defer std.fs.cwd().deleteTree(base_dir) catch {};

    const blocking_file = try std.fs.path.join(allocator, &.{ sub_dir, "blocker.txt" });
    defer allocator.free(blocking_file);

    const file = try std.fs.cwd().createFile(blocking_file, .{});
    file.close();

    const dirs = [_][]const u8{deep_dir};
    const options = RmdirOptions{
        .parents = true,
        .verbose = true,
    };

    _ = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);

    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(deep_dir));
    const sub_stat = try std.fs.cwd().statFile(sub_dir);
    try testing.expect(sub_stat.kind == .directory);
    const base_stat = try std.fs.cwd().statFile(base_dir);
    try testing.expect(base_stat.kind == .directory);
}

test "rmdir: unicode path handling" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const test_dir = "test_rmdir_unicode_🎯";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    const stat = std.fs.cwd().statFile(test_dir);
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
    try testing.expectEqualStrings("Directory not empty", formatError(error.DirNotEmpty));
    try testing.expectEqualStrings("Not a directory", formatError(error.NotDir));
    try testing.expectEqualStrings("Permission denied", formatError(error.AccessDenied));
    try testing.expectEqualStrings("No such file or directory", formatError(error.FileNotFound));
}
