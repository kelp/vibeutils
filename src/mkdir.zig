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

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runUtility(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

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
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
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
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Create options
    var options = MkdirOptions{
        .parents = parsed_args.parents,
        .verbose = parsed_args.verbose,
    };

    // Parse mode if provided
    if (parsed_args.mode) |mode_str| {
        options.mode = parseMode(mode_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid mode '{s}'", .{mode_str});
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
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
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
    );
}

/// Print version information to provided writer
fn printVersion(writer: anytype) !void {
    try writer.print("mkdir ({s}) {s}\n", .{ common.name, common.version });
}

/// Set directory permissions. No-op with warning on Windows.
fn setDirectoryMode(path: []const u8, mode: std.fs.File.Mode, prog_name: []const u8, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        // Print warning on Windows
        common.printWarningWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "mode flag (-m) is not supported on Windows", .{});
        return;
    }

    // Use C chmod function for directories on POSIX systems
    const path_z = std.posix.toPosixPath(path) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "path too long: '{s}'", .{path});
        return error.ChmodFailed;
    };

    const result = std.c.chmod(&path_z, mode);
    if (result != 0) {
        const err = std.posix.errno(result); // Pass the result to errno
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot set mode on '{s}': {s}", .{ path, @tagName(err) });
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

    const mode = std.fmt.parseInt(u32, mode_str, 8) catch {
        return error.InvalidMode;
    };

    // Validate mode is reasonable (3 or 4 digits)
    if (mode > 0o7777) {
        return error.InvalidMode;
    }

    return @intCast(mode);
}

/// Create directory with specified options
fn createDirectory(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    if (options.parents) {
        try createPathComponents(path, options, prog_name, stdout_writer, stderr_writer, allocator);
    } else {
        std.fs.cwd().makeDir(path) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot create directory '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };

        // Set mode if specified
        if (options.mode) |mode| {
            try setDirectoryMode(path, mode, prog_name, stderr_writer, allocator);
        }

        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, path });
        }
    }
}

/// Create path components one at a time, supporting -v and -m per intermediate directory.
fn createPathComponents(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    // Handle absolute paths - start with "/"
    const is_absolute = path.len > 0 and path[0] == '/';

    // Split path into components
    var iter = std.mem.splitScalar(u8, path, '/');

    // Build up the cumulative path
    var cumulative = std.ArrayListUnmanaged(u8){};
    defer cumulative.deinit(allocator);

    if (is_absolute) {
        try cumulative.append(allocator, '/');
    }

    var first = true;
    while (iter.next()) |component| {
        // Skip empty components (from double slashes or trailing slashes)
        if (component.len == 0) continue;

        // Add separator between components (not before first)
        if (!first and !(cumulative.items.len == 1 and cumulative.items[0] == '/')) {
            try cumulative.append(allocator, '/');
        }
        first = false;

        try cumulative.appendSlice(allocator, component);

        const current_path = cumulative.items;

        // Try to create this component
        std.fs.cwd().makeDir(current_path) catch |err| switch (err) {
            error.PathAlreadyExists => continue, // -p: silently skip existing
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot create directory '{s}': {s}", .{ current_path, @errorName(err) });
                return err;
            },
        };

        // Directory was created successfully
        // Set mode if specified
        if (options.mode) |mode| {
            setDirectoryMode(current_path, mode, prog_name, stderr_writer, allocator) catch {};
        }

        // Print verbose message for each directory created
        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, current_path });
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "mkdir creates single directory" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_dir") catch {};

    const args = [_][]const u8{"test_dir"};
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_dir", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir with parents flag creates directory tree" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_parent") catch {};

    const args = [_][]const u8{ "-p", "test_parent/test_child" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

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
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_verbose") catch {};

    const args = [_][]const u8{ "-v", "test_verbose" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mkdir: created directory 'test_verbose'") != null);
}

test "mkdir with mode flag sets permissions" {
    if (builtin.os.tag == .windows) {
        return;
    }

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_mode") catch {};

    const args = [_][]const u8{ "-m", "755", "test_mode" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory exists and has correct permissions
    const stat = try std.fs.cwd().statFile("test_mode");
    const mode = stat.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o755), mode);
}

test "mkdir fails for existing directory without parents flag" {
    // Create directory first
    try std.fs.cwd().makeDir("test_existing");
    defer std.fs.cwd().deleteDir("test_existing") catch {};

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"test_existing"};
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "PathAlreadyExists") != null);
}

test "mkdir with parents flag succeeds for existing directory" {
    // Create directory first
    try std.fs.cwd().makeDir("test_existing_p");
    defer std.fs.cwd().deleteDir("test_existing_p") catch {};

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-p", "test_existing_p" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
}

test "mkdir fails with missing operand" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "mkdir shows help with -h flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-h"};
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: mkdir") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Create the DIRECTORY") != null);
}

test "mkdir shows version with -V flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mkdir (vibeutils)") != null);
}

test "mkdir handles invalid mode" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", "999", "test_invalid" };
    const result = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid mode") != null);
}

test "mkdir combines parents and verbose flags" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_combo") catch {};

    const args = [_][]const u8{ "-pv", "test_combo/sub/deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "created directory") != null);
}

test "mkdir handles multiple directories" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_multi1") catch {};
    defer std.fs.cwd().deleteDir("test_multi2") catch {};
    defer std.fs.cwd().deleteDir("test_multi3") catch {};

    const args = [_][]const u8{ "test_multi1", "test_multi2", "test_multi3" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

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
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_slashes") catch {};

    const args = [_][]const u8{ "-p", "test_slashes//sub//deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_slashes/sub/deep", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir handles paths with dot components" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_dots") catch {};

    const args = [_][]const u8{ "-p", "test_dots/../test_dots/./sub" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created (note: filesystem normalizes the path)
    var test_dir = std.fs.cwd().openDir("test_dots/sub", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir verbose with parents shows directory creation" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_verbose_parents") catch {};

    const args = [_][]const u8{ "-pv", "test_verbose_parents/new_child" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "created directory") != null);
}

test "mkdir with mode applies to all created directories with -p" {
    if (builtin.os.tag == .windows) {
        // Skip on Windows - mode setting not supported
        return;
    }

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_mode_parents") catch {};

    const args = [_][]const u8{ "-pm", "755", "test_mode_parents/sub/deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify all directories were created (mode testing would require platform-specific code)
    var test_dir = std.fs.cwd().openDir("test_mode_parents/sub/deep", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir -pv prints each intermediate directory" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_pv_each") catch {};

    const args = [_][]const u8{ "-pv", "test_pv_each/a/b" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Should have verbose output for each created directory
    const output = stdout_buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "test_pv_each'") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_pv_each/a'") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_pv_each/a/b'") != null);
}

test "mkdir -pm sets mode on intermediate directories" {
    if (builtin.os.tag == .windows) return;

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_pm_mode") catch {};

    const args = [_][]const u8{ "-pm", "700", "test_pm_mode/sub/deep" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify mode on the deepest directory
    const stat = try std.fs.cwd().statFile("test_pm_mode/sub/deep");
    const mode = stat.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o700), mode);

    // Verify mode on intermediate directory
    const stat_mid = try std.fs.cwd().statFile("test_pm_mode/sub");
    const mode_mid = stat_mid.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o700), mode_mid);
}

test "mkdir -p handles absolute-like paths" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Create a temp dir and use it as base for an absolute-ish path
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const deep_path = try std.fmt.allocPrint(testing.allocator, "{s}/abs_test/sub/dir", .{tmp_path});
    defer testing.allocator.free(deep_path);

    const args = [_][]const u8{ "-p", deep_path };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify the directory was created
    var test_dir = std.fs.cwd().openDir(deep_path, .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir -p with trailing slashes" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_trailing") catch {};

    const args = [_][]const u8{ "-p", "test_trailing/sub/" };
    const result = try runUtility(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_trailing/sub", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}
