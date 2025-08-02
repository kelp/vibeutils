/// POSIX rmdir utility for removing empty directories.
const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const posix = std.posix;

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

/// Enhanced error types for rmdir operations.
pub const RmdirError = error{
    DirectoryNotEmpty,
    NotADirectory,
    PermissionDenied,
    PathTraversalAttempt,
    SystemPathProtected,
    InvalidPath,
    SymbolicLinkDetected,
    TooManySymbolicLinks,
    PathTooLong,
    FileSystemError,
    FileNotFound,
};

/// Centralized error messages for rmdir operations.
const ErrorMessages = struct {
    const directory_not_empty = "Directory not empty";
    const not_a_directory = "Not a directory";
    const permission_denied = "Permission denied";
    const no_such_file = "No such file or directory";
    const path_traversal = "Path traversal attempt detected";
    const system_path = "Cannot remove system directory";
    const invalid_path = "Invalid path";
    const symbolic_link = "Cannot remove symbolic link (use rm instead)";
    const path_too_long = "Path too long";

    /// Format an error into a human-readable message.
    pub fn format(err: anyerror, path: []const u8) []const u8 {
        _ = path;
        return switch (err) {
            error.DirNotEmpty => directory_not_empty,
            error.DirectoryNotEmpty => directory_not_empty,
            error.NotDir => not_a_directory,
            error.NotADirectory => not_a_directory,
            error.AccessDenied => permission_denied,
            error.PermissionDenied => permission_denied,
            error.FileNotFound => no_such_file,
            error.PathTraversalAttempt => path_traversal,
            error.SystemPathProtected => system_path,
            error.InvalidPath => invalid_path,
            error.SymbolicLinkDetected => symbolic_link,
            error.PathTooLong => path_too_long,
            error.NameTooLong => path_too_long,
            else => @errorName(err),
        };
    }
};

/// Path validator to prevent security issues.
const PathValidator = struct {
    allocator: std.mem.Allocator,

    /// System paths that should never be removed - cross-platform critical directories.
    const protected_paths = [_][]const u8{
        // Unix/Linux root and essential directories
        "/",
        "/bin",
        "/boot",
        "/dev",
        "/etc",
        "/home",
        "/lib",
        "/lib32",
        "/lib64",
        "/libx32",
        "/media",
        "/mnt",
        "/opt",
        "/proc",
        "/root",
        "/run",
        "/sbin",
        "/srv",
        "/sys",
        "/tmp",
        "/usr",
        "/var",

        // macOS specific critical paths
        "/Applications",
        "/Library",
        "/System",
        "/Users",
        "/Volumes",
        "/private",
        "/cores",

        // Additional Unix variants (BSD, Solaris, etc.)
        "/kernel",
        "/platform",
        "/devices",
        "/export",

        // Common single character paths that are often critical
        ".",
        "..",

        // Windows drive roots (in case of cross-compilation or WSL)
        "C:\\",
        "D:\\",
        "E:\\",
        "F:\\",
        "G:\\",
        "H:\\",
        "I:\\",
        "J:\\",
        "K:\\",
        "L:\\",
        "M:\\",
        "N:\\",
        "O:\\",
        "P:\\",
        "Q:\\",
        "R:\\",
        "S:\\",
        "T:\\",
        "U:\\",
        "V:\\",
        "W:\\",
        "X:\\",
        "Y:\\",
        "Z:\\",
    };

    /// Initialize a new PathValidator with the given allocator.
    pub fn init(allocator: std.mem.Allocator) PathValidator {
        return .{ .allocator = allocator };
    }

    /// Validate a path for safe removal.
    pub fn validate(self: PathValidator, path: []const u8) !void {
        // Check for empty path
        if (path.len == 0) {
            return error.InvalidPath;
        }

        // Check for path traversal attempts - comprehensive protection
        if (std.mem.indexOf(u8, path, "../") != null or
            std.mem.indexOf(u8, path, "..\\") != null or // Windows path separator
            std.mem.eql(u8, path, "..") or
            std.mem.startsWith(u8, path, "../") or
            std.mem.startsWith(u8, path, "..\\") or
            std.mem.endsWith(u8, path, "/..") or
            std.mem.endsWith(u8, path, "\\..") or
            std.mem.indexOf(u8, path, "/.../") != null or // triple dots
            std.mem.indexOf(u8, path, "\\.../") != null or
            std.mem.indexOf(u8, path, "/./") != null or // current dir references
            std.mem.indexOf(u8, path, "\\.\\") != null)
        {
            return error.PathTraversalAttempt;
        }

        // Get absolute path
        // This resolves relative paths and symlinks to their real paths
        const abs_path = std.fs.cwd().realpathAlloc(self.allocator, path) catch |err| {
            // Map filesystem errors to our custom error types
            return switch (err) {
                error.FileNotFound => RmdirError.FileNotFound,
                error.NameTooLong => RmdirError.PathTooLong,
                error.SymLinkLoop => RmdirError.TooManySymbolicLinks,
                else => RmdirError.InvalidPath,
            };
        };
        defer self.allocator.free(abs_path);

        // Check against protected system paths
        // These critical directories must never be removed
        for (protected_paths) |protected| {
            if (std.mem.eql(u8, abs_path, protected)) {
                return error.SystemPathProtected;
            }
        }

        // Check if path is a symbolic link using fstatat with AT.SYMLINK_NOFOLLOW
        // This flag ensures we stat the link itself, not what it points to
        const path_c = try std.posix.toPosixPath(path);
        const stat_buf = std.posix.fstatatZ(std.fs.cwd().fd, &path_c, posix.AT.SYMLINK_NOFOLLOW) catch {
            return; // Will be caught by actual removal
        };

        // Check if it's a symlink
        // rmdir should not remove symlinks - that's rm's job
        if (std.posix.S.ISLNK(stat_buf.mode)) {
            return error.SymbolicLinkDetected;
        }
    }
};

/// Options for rmdir command.
const RmdirOptions = struct {
    parents: bool = false,
    verbose: bool = false,
    ignore_fail_on_non_empty: bool = false,
};

/// Generic progress indicator for bulk operations.
fn ProgressIndicator(comptime Writer: type) type {
    return struct {
        writer: Writer,
        total: usize,
        current: usize,
        style: common.style.Style(Writer),

        const Self = @This();

        /// Initialize a new progress indicator.
        pub fn init(writer: Writer, total: usize) Self {
            return .{
                .writer = writer,
                .total = total,
                .current = 0,
                .style = common.style.Style(Writer).init(writer),
            };
        }

        /// Update progress display with current path being processed.
        pub fn update(self: *Self, path: []const u8) !void {
            self.current += 1;
            // Only show progress for multiple directories to avoid clutter
            if (self.total > 1) {
                try self.style.setColor(.cyan);
                try self.writer.print("[{d}/{d}] ", .{ self.current, self.total });
                try self.style.reset();
                try self.writer.print("Removing: {s}\n", .{path});
            }
        }
    };
}

/// Iterator for parent directories to avoid allocations.
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

/// Main entry point for rmdir utility.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runUtility(allocator, args[1..], stdout_writer, stderr_writer);
    std.process.exit(exit_code);
}

/// Run rmdir with provided writers for output
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const prog_name = "rmdir";

    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(RmdirArgs, allocator, args) catch |err| {
        // Handle parsing errors gracefully
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(stderr_writer, prog_name, "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    // Only defer after successful parsing to avoid leaking on parsing errors
    defer allocator.free(parsed_args.positionals);

    // Handle help request
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version request
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate that at least one directory was specified
    const directories = parsed_args.positionals;
    if (directories.len == 0) {
        common.printErrorWithProgram(stderr_writer, prog_name, "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Create options structure from parsed arguments
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

/// Main function to remove directories.
fn removeDirectories(allocator: std.mem.Allocator, directories: []const []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmdirOptions) !common.ExitCode {
    var had_error = false;

    // Initialize progress indicator for bulk operations
    var progress = ProgressIndicator(@TypeOf(stdout_writer)).init(stdout_writer, directories.len);

    // Initialize path validator
    const validator = PathValidator.init(allocator);

    for (directories) |dir| {
        // Show progress for multiple directories
        if (options.verbose and directories.len > 1) {
            try progress.update(dir);
        }

        if (options.parents) {
            // Remove directory and its parents
            if (removeDirectoryWithParents(allocator, dir, stdout_writer, options, validator)) |e| {
                had_error = true;
                handleError(e, dir, stderr_writer, options) catch |write_err| {
                    // If we can't write to stderr, return the write error
                    return write_err;
                };
            }
        } else {
            // Remove single directory
            if (removeSingleDirectory(dir, stdout_writer, options, validator)) |e| {
                had_error = true;
                handleError(e, dir, stderr_writer, options) catch |write_err| {
                    // If we can't write to stderr, return the write error
                    return write_err;
                };
            }
        }
    }

    return if (had_error) .general_error else .success;
}

/// Remove a single directory using atomic operation.
fn removeSingleDirectory(path: []const u8, writer: anytype, options: RmdirOptions, validator: PathValidator) ?anyerror {
    // Validate path first
    validator.validate(path) catch |err| {
        return err;
    };

    // Use atomic unlinkat for race condition prevention
    // AT.REMOVEDIR ensures only directories are removed
    const dir_fd = std.fs.cwd().fd;
    posix.unlinkat(dir_fd, path, posix.AT.REMOVEDIR) catch |err| {
        // Map POSIX errors to our custom error types
        return switch (err) {
            error.DirNotEmpty => if (options.ignore_fail_on_non_empty) null else error.DirectoryNotEmpty,
            error.NotDir => error.NotADirectory,
            error.AccessDenied => error.PermissionDenied,
            error.FileNotFound => err,
            else => err,
        };
    };

    if (options.verbose) {
        // Use styled output for better readability, but don't fail on styling errors
        const style = common.style.Style(@TypeOf(writer)).init(writer);
        style.setColor(.green) catch {};
        writer.print("rmdir: ", .{}) catch |err| return err;
        style.reset() catch {};
        writer.print("removing directory, '{s}'\n", .{path}) catch |err| return err;
    }

    return null;
}

/// Remove directory with its parent directories.
fn removeDirectoryWithParents(allocator: std.mem.Allocator, path: []const u8, writer: anytype, options: RmdirOptions, validator: PathValidator) ?anyerror {
    // First remove the directory itself
    if (removeSingleDirectory(path, writer, options, validator)) |err| {
        return err;
    }

    // Initialize parent iterator
    var iter = ParentIterator.init(allocator, path) catch |err| {
        return err;
    };
    defer iter.deinit();

    // Remove parent directories
    // Iterate up the directory tree, removing each empty parent
    while (iter.next()) |parent| {
        if (removeSingleDirectory(parent, writer, options, validator)) |err| {
            // Stop on first error when removing parents
            // Exception: continue if error is non-empty and we're ignoring those
            return if (options.ignore_fail_on_non_empty and err == error.DirectoryNotEmpty) null else err;
        }
    }

    return null;
}

/// Centralized error handling function.
fn handleError(err: anyerror, path: []const u8, stderr_writer: anytype, options: RmdirOptions) !void {
    // Some errors should be ignored with the flag
    if (options.ignore_fail_on_non_empty and err == error.DirectoryNotEmpty) {
        return;
    }

    const prog_name = "rmdir";
    const msg = ErrorMessages.format(err, path);
    common.printErrorWithProgram(stderr_writer, prog_name, "failed to remove '{s}': {s}", .{ path, msg });
}

// ===== TESTS =====

test "rmdir: remove empty directory" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create a test directory
    const test_dir = "test_rmdir_empty";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    // Verify directory was removed
    const stat = std.fs.cwd().statFile(test_dir);
    try testing.expectError(error.FileNotFound, stat);
}

test "rmdir: fail on non-empty directory" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create a test directory with a file
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

    // Verify directory still exists
    const stat = try std.fs.cwd().statFile(test_dir);
    try testing.expect(stat.kind == .directory);
}

test "rmdir: ignore fail on non-empty with flag" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create a test directory with a file
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

    // Directory should still exist
    const stat = try std.fs.cwd().statFile(test_dir);
    try testing.expect(stat.kind == .directory);
}

test "rmdir: verbose output" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create a test directory
    const test_dir = "test_rmdir_verbose";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    // Check verbose output contains the directory name
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_rmdir_verbose") != null);
}

test "rmdir: remove with parents" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create nested directories
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

    // All directories should be removed
    const stat = std.fs.cwd().statFile(base_dir);
    try testing.expectError(error.FileNotFound, stat);

    // Check verbose output shows all removals
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

    // Create multiple test directories
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

    // All directories should be removed
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

    // Create a test file
    const test_file = "test_rmdir_file.txt";
    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const dirs = [_][]const u8{test_file};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.general_error, exit_code);

    // File should still exist
    const stat = try std.fs.cwd().statFile(test_file);
    try testing.expect(stat.kind == .file);
}

test "rmdir: parents stops on error" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create nested directories with a file in the middle one
    const base_dir = "test_rmdir_parents_stop";
    const sub_dir = "test_rmdir_parents_stop/sub";
    const deep_dir = "test_rmdir_parents_stop/sub/deep";

    try std.fs.cwd().makePath(deep_dir);
    defer std.fs.cwd().deleteTree(base_dir) catch {};

    // Add a file to the middle directory
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

    // Should have removed deep_dir but not sub_dir or base_dir
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(deep_dir));
    const sub_stat = try std.fs.cwd().statFile(sub_dir);
    try testing.expect(sub_stat.kind == .directory);
    const base_stat = try std.fs.cwd().statFile(base_dir);
    try testing.expect(base_stat.kind == .directory);
}

// New tests for enhanced functionality

test "rmdir: path traversal protection" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const dirs = [_][]const u8{"../../../etc"};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.general_error, exit_code);
}

test "rmdir: symbolic link detection" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create a directory and a symlink to it
    const test_dir = "test_rmdir_symlink_target";
    const test_link = "test_rmdir_symlink";

    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    try std.posix.symlink(test_dir, test_link);
    defer std.fs.cwd().deleteFile(test_link) catch {};

    const dirs = [_][]const u8{test_link};
    const options = RmdirOptions{};

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.general_error, exit_code);

    // Both should still exist
    const stat = try std.fs.cwd().statFile(test_dir);
    try testing.expect(stat.kind == .directory);
    // Symlink should still exist since rmdir shouldn't remove symlinks
    const path_c = try std.posix.toPosixPath(test_link);
    const stat_buf = try std.posix.fstatatZ(std.fs.cwd().fd, &path_c, posix.AT.SYMLINK_NOFOLLOW);
    try testing.expect(std.posix.S.ISLNK(stat_buf.mode));
}

test "rmdir: unicode path handling" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create directory with unicode name
    const test_dir = "test_rmdir_unicode_🎯";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteDir(test_dir) catch {};

    const dirs = [_][]const u8{test_dir};
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    // Verify directory was removed
    const stat = std.fs.cwd().statFile(test_dir);
    try testing.expectError(error.FileNotFound, stat);
}

test "rmdir: progress indicator for bulk operations" {
    const allocator = testing.allocator;
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Create multiple directories
    var dirs: [5][]u8 = undefined;
    var allocated_count: usize = 0;
    defer {
        for (0..allocated_count) |i| {
            allocator.free(dirs[i]);
        }
    }

    for (0..5) |i| {
        const dir_name = try std.fmt.allocPrint(allocator, "test_rmdir_bulk_{d}", .{i});
        errdefer allocator.free(dir_name);

        try std.fs.cwd().makeDir(dir_name);
        dirs[i] = dir_name;
        allocated_count += 1;
    }

    // Clean up directories after test
    defer {
        for (0..5) |i| {
            var cleanup_buf: [32]u8 = undefined;
            const dir_name = std.fmt.bufPrint(&cleanup_buf, "test_rmdir_bulk_{d}", .{i}) catch continue;
            std.fs.cwd().deleteDir(dir_name) catch {};
        }
    }

    const const_dirs = [_][]const u8{ dirs[0], dirs[1], dirs[2], dirs[3], dirs[4] };
    const options = RmdirOptions{
        .verbose = true,
    };

    const exit_code = try removeDirectories(allocator, &const_dirs, stdout_buffer.writer(), stderr_buffer.writer(), options);
    try testing.expectEqual(common.ExitCode.success, exit_code);

    // Should show progress indicators
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "[1/5]") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "[5/5]") != null);
}

test "rmdir: parent iterator memory management" {
    const allocator = testing.allocator;

    const path = "a/b/c/d/e";
    var iter = try ParentIterator.init(allocator, path);
    defer iter.deinit();

    // Test iteration
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

    // Test various error messages
    try testing.expectEqualStrings("Directory not empty", ErrorMessages.format(error.DirectoryNotEmpty, "test"));
    try testing.expectEqualStrings("Not a directory", ErrorMessages.format(error.NotADirectory, "test"));
    try testing.expectEqualStrings("Permission denied", ErrorMessages.format(error.PermissionDenied, "test"));
    try testing.expectEqualStrings("Path traversal attempt detected", ErrorMessages.format(error.PathTraversalAttempt, "test"));
}
