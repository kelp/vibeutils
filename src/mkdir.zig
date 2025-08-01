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
        createDirectory(dir_path, options, stdout_writer, stderr_writer, allocator) catch {
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
fn setDirectoryMode(path: []const u8, mode: std.fs.File.Mode, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

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
        const err = std.posix.errno(result);
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
        // Convert octal string to numeric value
        mode = mode * 8 + (c - '0');
    }

    // Validate mode is reasonable (3 or 4 digits)
    if (mode > 0o7777) {
        return error.InvalidMode;
    }

    return @intCast(mode);
}

/// Create directory with specified options
fn createDirectory(path: []const u8, options: MkdirOptions, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Normalize path by removing trailing slashes
    const normalized_path = std.mem.trimRight(u8, path, "/");
    if (normalized_path.len == 0) {
        // Special case: root directory
        common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '/': File exists", .{});
        return error.AlreadyExists;
    }

    if (options.parents) {
        try createDirectoryWithParents(normalized_path, options, stdout_writer, stderr_writer, allocator);
    } else {
        try createSingleDirectory(normalized_path, options, stdout_writer, stderr_writer, allocator);
    }
}

/// Create single directory without parent creation
fn createSingleDirectory(path: []const u8, options: MkdirOptions, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Create directory
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            common.printErrorWithProgram(stderr_writer, prog_name, "cannot create directory '{s}': File exists", .{path});
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
        try setDirectoryMode(path, mode, stderr_writer, allocator);
    }

    if (options.verbose) {
        try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, path });
    }
}

/// Create directory tree with parent directories
fn createDirectoryWithParents(path: []const u8, options: MkdirOptions, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

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

    // Handle absolute paths
    if (path[0] == '/') {
        try current_path.append('/');
    }

    for (components.items, 0..) |component, i| {
        if (i > 0 and current_path.items[current_path.items.len - 1] != '/') {
            try current_path.append('/');
        }
        try current_path.appendSlice(component);

        const is_last = i == components.items.len - 1;

        // Try to create the directory
        std.fs.cwd().makeDir(current_path.items) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // This is OK with -p flag - existing directories are not an error
                continue;
            },
            error.AccessDenied => {
                try stderr_writer.print("{s}: cannot create directory '{s}': Permission denied\n", .{ prog_name, current_path.items });
                return err;
            },
            else => {
                try stderr_writer.print("{s}: cannot create directory '{s}': {s}\n", .{ prog_name, current_path.items, @errorName(err) });
                return err;
            },
        };

        // Set mode only on the final directory if specified
        if (is_last and options.mode != null) {
            try setDirectoryMode(current_path.items, options.mode.?, stderr_writer, arena_allocator);
        }

        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, current_path.items });
        }
    }
}
