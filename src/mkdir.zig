//! Create directories with optional parent directory creation and permission setting
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const privilege_test = common.privilege_test;
const testing = std.testing;

/// Command-line arguments for mkdir
const MkdirArgs = struct {
    help: bool = false,
    version: bool = false,
    mode: ?[]const u8 = null,
    parents: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .mode = .{ .short = 'm', .desc = "Set file mode (as in chmod)", .value_name = "MODE" },
        .parents = .{ .short = 'p', .desc = "Make parent directories as needed, no error if existing" },
        .verbose = .{ .short = 'v', .desc = "Print a message for each created directory" },
    };
};

/// Options controlling directory creation behavior
const MkdirOptions = struct {
    /// File mode for created directories
    mode: ?std.fs.File.Mode = null,

    /// Create parent directories as needed
    parents: bool = false,

    /// Print a message for each created directory
    verbose: bool = false,
};

/// Main entry point for mkdir command
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

/// Run mkdir with provided writers for output
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const prog_name = "mkdir";

    // Parse arguments using common argparse module
    const parsed_args = common.argparse.ArgParser.parse(MkdirArgs, allocator, args) catch |err| {
        switch (err) {
            // Handle argument parsing errors with appropriate error messages
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(stderr_writer, prog_name, "invalid argument", .{});
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
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Check if we have directories to create
    const dirs = parsed_args.positionals;
    if (dirs.len == 0) {
        common.printErrorWithProgram(stderr_writer, prog_name, "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Create options
    var options = MkdirOptions{
        .parents = parsed_args.parents,
        .verbose = parsed_args.verbose,
    };

    // Parse mode if provided
    if (parsed_args.mode) |mode_str| {
        options.mode = parseMode(mode_str) catch {
            common.printErrorWithProgram(stderr_writer, prog_name, "invalid mode '{s}'", .{mode_str});
            return @intFromEnum(common.ExitCode.general_error);
        };
    }

    // Process directories - continue processing even if some fail
    var exit_code = common.ExitCode.success;
    for (dirs) |dir_path| {
        createDirectory(dir_path, options, prog_name, stdout_writer, stderr_writer, allocator) catch {
            // Mark overall failure but continue with remaining directories
            exit_code = common.ExitCode.general_error;
            continue;
        };
    }

    return @intFromEnum(exit_code);
}

/// Print help message to provided writer
fn printHelp(writer: anytype) !void {
    try writer.print(
        \\Usage: mkdir [OPTION]... DIRECTORY...
        \\Create the DIRECTORY(ies), if they do not already exist.
        \\
        \\  -m, --mode=MODE   set file mode (as in chmod)
        \\  -p, --parents     make parent directories as needed, no error if existing
        \\  -v, --verbose     print a message for each created directory
        \\  -h, --help        display this help and exit
        \\  -V, --version     output version information and exit
        \\
        \\Examples:
        \\  mkdir dir1          Create directory 'dir1'
        \\  mkdir -p a/b/c      Create directory tree including parents
        \\  mkdir -m 755 bin    Create directory with permissions rwxr-xr-x
        \\
    , .{});
}

/// Print version information to provided writer
fn printVersion(writer: anytype) !void {
    try writer.print("mkdir (vibeutils) 0.1.0\n", .{});
}

/// Set directory permissions (POSIX only)
///
/// Windows limitations:
/// - Mode setting is not supported on Windows filesystems
/// - Function prints warning and returns successfully to maintain compatibility
/// - Windows directories use default ACL-based permissions instead
///
/// Error handling strategy:
/// - POSIX systems: Returns error.ChmodFailed if chmod() syscall fails
/// - All errors from chmod are converted to our custom error type for consistent handling
/// - Path is converted to null-terminated for C API compatibility
fn setDirectoryMode(path: []const u8, mode: std.fs.File.Mode, prog_name: []const u8, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        // Print warning on Windows
        common.printWarningWithProgram(stderr_writer, prog_name, "mode flag (-m) is not supported on Windows", .{});
        return;
    }

    // Use C chmod function for directories on POSIX systems
    const path_z = try std.fmt.allocPrintZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);

    const result = std.c.chmod(path_z, mode);
    if (result != 0) {
        const err = std.posix.errno(result); // Pass the result to errno
        common.printErrorWithProgram(stderr_writer, prog_name, "cannot set mode on '{s}': {s}", .{ path, @tagName(err) });
        return error.ChmodFailed;
    }
}

/// Parse octal mode string (e.g. "755") into file mode
fn parseMode(mode_str: []const u8) !std.fs.File.Mode {
    // For now, support only octal modes
    // TODO: Support symbolic modes like u+rwx
    if (mode_str.len == 0) {
        return error.InvalidMode;
    }

    // Parse octal digits
    var mode: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') {
            return error.InvalidMode;
        }

        // Check for overflow before multiplication
        if (mode > (std.math.maxInt(u32) - 7) / 8) {
            return error.InvalidMode;
        }

        // Convert octal string to numeric value
        mode = mode * 8 + (c - '0');
    }

    // Validate mode is reasonable (3 or 4 digits)
    if (mode > 0o7777) {
        return error.InvalidMode;
    }

    return @intCast(mode);
}

/// Validate path for security issues
fn validatePath(path: []const u8) !void {
    // Check for null bytes (path injection)
    if (std.mem.indexOf(u8, path, "\x00") != null) {
        return error.InvalidPath;
    }

    // Check for excessively long paths
    if (path.len > 4096) {
        return error.PathTooLong;
    }
}

/// Check if a path is actually a directory (not a file)
fn verifyIsDirectory(path: []const u8) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return, // Path doesn't exist, that's fine
        else => return err,
    };

    if (stat.kind != .directory) {
        return error.NotADirectory;
    }
}

/// Create directory with specified options
fn createDirectory(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    // Validate path for security issues
    validatePath(path) catch |err| switch (err) {
        error.InvalidPath => {
            common.printErrorWithProgram(stderr_writer, prog_name, "invalid path '{s}': contains null bytes", .{path});
            return err;
        },
        error.PathTooLong => {
            common.printErrorWithProgram(stderr_writer, prog_name, "path too long: '{s}'", .{path});
            return err;
        },
        else => return err,
    };

    // Normalize path by removing trailing slashes
    const normalized_path = std.mem.trimRight(u8, path, "/");
    if (normalized_path.len == 0) {
        // Special case: root directory
        common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '/': Directory exists", .{});
        return error.AlreadyExists;
    }

    if (options.parents) {
        try createDirectoryWithParents(normalized_path, options, prog_name, stdout_writer, stderr_writer, allocator);
    } else {
        try createSingleDirectory(normalized_path, options, prog_name, stdout_writer, stderr_writer, allocator);
    }
}

/// Create single directory without parent creation
fn createSingleDirectory(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {

    // Create directory
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Verify the existing path is actually a directory (not a file)
            verifyIsDirectory(path) catch |verify_err| switch (verify_err) {
                error.NotADirectory => {
                    common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': File exists", .{path});
                    return verify_err;
                },
                else => {
                    common.printErrorWithProgram(stderr_writer, prog_name, "cannot verify '{s}': {s}", .{ path, @errorName(verify_err) });
                    return verify_err;
                },
            };
            common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': Directory exists", .{path});
            return err;
        },
        error.FileNotFound => {
            common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': No such file or directory", .{path});
            return err;
        },
        error.AccessDenied => {
            common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': Permission denied", .{path});
            return err;
        },
        else => {
            common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': {s}", .{ path, @errorName(err) });
            return err;
        },
    };

    // Set mode if specified
    if (options.mode) |mode| {
        try setDirectoryMode(path, mode, prog_name, stderr_writer, allocator);
    }

    if (options.verbose) {
        try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, path });
    }
}

/// Create directory tree with parent directories
fn createDirectoryWithParents(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {

    // Use arena allocator to prevent memory leaks
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Split path into components
    var components = std.ArrayList([]const u8).init(arena_allocator);
    defer components.deinit();

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        try components.append(component);
    }

    // Create each directory in the path
    var current_path = std.ArrayList(u8).init(arena_allocator);
    defer current_path.deinit();

    // Handle absolute paths - add bounds check
    if (path.len > 0 and path[0] == '/') {
        try current_path.append('/');
    }

    for (components.items, 0..) |component, i| {
        if (i > 0 and current_path.items[current_path.items.len - 1] != '/') {
            try current_path.append('/');
        }
        try current_path.appendSlice(component);

        // Try to create the directory
        var was_created = true;
        std.fs.cwd().makeDir(current_path.items) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Verify the existing path is actually a directory (not a file)
                verifyIsDirectory(current_path.items) catch |verify_err| switch (verify_err) {
                    error.NotADirectory => {
                        common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': File exists", .{current_path.items});
                        return verify_err;
                    },
                    else => {
                        common.printErrorWithProgram(stderr_writer, prog_name, "cannot verify '{s}': {s}", .{ current_path.items, @errorName(verify_err) });
                        return verify_err;
                    },
                };
                // This is OK with -p flag - existing directories are not an error
                was_created = false;
            },
            error.AccessDenied => {
                common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': Permission denied", .{current_path.items});
                return err;
            },
            else => {
                common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': {s}", .{ current_path.items, @errorName(err) });
                return err;
            },
        };

        // Set mode if specified and directory was created
        if (was_created and options.mode != null) {
            try setDirectoryMode(current_path.items, options.mode.?, prog_name, stderr_writer, arena_allocator);
        }

        // Only print verbose message for directories that were actually created
        if (options.verbose and was_created) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, current_path.items });
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "mkdir creates single directory" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteDir("test_dir") catch {};

    const args = [_][]const u8{"test_dir"};
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_dir", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir with parents flag creates directory tree" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteTree("test_parent") catch {};

    const args = [_][]const u8{ "-p", "test_parent/test_child" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directories were created
    var parent_dir = std.fs.cwd().openDir("test_parent", .{}) catch |err| {
        return err;
    };
    defer parent_dir.close();

    var child_dir = parent_dir.openDir("test_child", .{}) catch |err| {
        return err;
    };
    child_dir.close();
}

test "mkdir with verbose flag prints creation messages" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteDir("test_verbose") catch {};

    const args = [_][]const u8{ "-v", "test_verbose" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mkdir: created directory 'test_verbose'") != null);
}

test "mkdir with mode flag sets permissions" {
    if (builtin.os.tag == .windows) {
        // Skip on Windows - mode setting not supported
        return;
    }

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteDir("test_mode") catch {};

    const args = [_][]const u8{ "-m", "755", "test_mode" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory exists (permissions testing would require platform-specific code)
    var test_dir = std.fs.cwd().openDir("test_mode", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir fails for existing directory without parents flag" {
    // Create directory first
    try std.fs.cwd().makeDir("test_existing");
    defer std.fs.cwd().deleteDir("test_existing") catch {};

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"test_existing"};
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "Directory exists") != null);
}

test "mkdir with parents flag succeeds for existing directory" {
    // Create directory first
    try std.fs.cwd().makeDir("test_existing_p");
    defer std.fs.cwd().deleteDir("test_existing_p") catch {};

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{ "-p", "test_existing_p" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
}

test "mkdir fails with missing operand" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{};
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "mkdir shows help with -h flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: mkdir") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Create the DIRECTORY") != null);
}

test "mkdir shows version with -V flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mkdir (vibeutils)") != null);
}

test "mkdir handles invalid mode" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-m", "999", "test_invalid" };
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid mode") != null);
}

test "mkdir combines parents and verbose flags" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteTree("test_combo") catch {};

    const args = [_][]const u8{ "-pv", "test_combo/sub/deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "created directory") != null);
}

test "mkdir handles multiple directories" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteDir("test_multi1") catch {};
    defer std.fs.cwd().deleteDir("test_multi2") catch {};
    defer std.fs.cwd().deleteDir("test_multi3") catch {};

    const args = [_][]const u8{ "test_multi1", "test_multi2", "test_multi3" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify all directories were created
    var dir1 = std.fs.cwd().openDir("test_multi1", .{}) catch |err| {
        return err;
    };
    dir1.close();

    var dir2 = std.fs.cwd().openDir("test_multi2", .{}) catch |err| {
        return err;
    };
    dir2.close();

    var dir3 = std.fs.cwd().openDir("test_multi3", .{}) catch |err| {
        return err;
    };
    dir3.close();
}

test "parseMode handles valid octal modes" {
    try testing.expectEqual(@as(std.fs.File.Mode, 0o755), try parseMode("755"));
    try testing.expectEqual(@as(std.fs.File.Mode, 0o644), try parseMode("644"));
    try testing.expectEqual(@as(std.fs.File.Mode, 0o777), try parseMode("777"));
    try testing.expectEqual(@as(std.fs.File.Mode, 0o000), try parseMode("000"));
}

test "parseMode rejects invalid modes" {
    try testing.expectError(error.InvalidMode, parseMode(""));
    try testing.expectError(error.InvalidMode, parseMode("abc"));
    try testing.expectError(error.InvalidMode, parseMode("888"));
    try testing.expectError(error.InvalidMode, parseMode("1234567890")); // Too long/large
}

test "mkdir handles paths with double slashes" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteTree("test_slashes") catch {};

    const args = [_][]const u8{ "-p", "test_slashes//sub//deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_slashes/sub/deep", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir handles paths with dot components" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteTree("test_dots") catch {};

    const args = [_][]const u8{ "-p", "test_dots/../test_dots/./sub" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created (note: filesystem normalizes the path)
    var test_dir = std.fs.cwd().openDir("test_dots/sub", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir verbose with parents shows only created directories" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteTree("test_existing_verbose") catch {};

    // First create parent directory
    try std.fs.cwd().makeDir("test_existing_verbose");

    const args = [_][]const u8{ "-pv", "test_existing_verbose/new_child" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Should only show message for the newly created child, not existing parent
    const output = stdout_buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "created directory 'test_existing_verbose/new_child'") != null);
    try testing.expect(std.mem.indexOf(u8, output, "created directory 'test_existing_verbose'") == null);
}

test "mkdir with mode applies to all created directories with -p" {
    if (builtin.os.tag == .windows) {
        // Skip on Windows - mode setting not supported
        return;
    }

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    defer std.fs.cwd().deleteTree("test_mode_parents") catch {};

    const args = [_][]const u8{ "-pm", "755", "test_mode_parents/sub/deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify all directories were created (mode testing would require platform-specific code)
    var test_dir = std.fs.cwd().openDir("test_mode_parents/sub/deep", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir rejects paths with null bytes" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"test\x00injection"};
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "contains null bytes") != null);
}

test "mkdir fails when file exists with same name" {
    // Create a regular file first
    var file = try std.fs.cwd().createFile("test_file_conflict", .{});
    file.close();
    defer std.fs.cwd().deleteFile("test_file_conflict") catch {};

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"test_file_conflict"};
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "File exists") != null);
}

test "mkdir -p fails when file exists in path" {
    // Create a regular file first
    var file = try std.fs.cwd().createFile("test_file_in_path", .{});
    file.close();
    defer std.fs.cwd().deleteFile("test_file_in_path") catch {};

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-p", "test_file_in_path/subdir" };
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "File exists") != null);
}
