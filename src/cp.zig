//! Copy files and directories with POSIX-compatible behavior

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const privilege_test = common.privilege_test;
const TestDir = common.test_dir.TestDir;

// Copy buffer size - single 64KB buffer for all operations
const COPY_BUFFER_SIZE = 64 * 1024;

/// Command-line configuration and runtime options for cp
const CpConfig = struct {
    // Command-line only options
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},

    // Runtime operation options
    force: bool = false,
    interactive: bool = false,
    no_dereference: bool = false,
    preserve: bool = false,
    recursive: bool = false,

    /// Extract runtime-only configuration
    pub fn runtime(self: CpConfig) RuntimeOptions {
        return RuntimeOptions{
            .force = self.force,
            .interactive = self.interactive,
            .no_dereference = self.no_dereference,
            .preserve = self.preserve,
            .recursive = self.recursive,
        };
    }

    pub const meta = .{
        .force = .{ .short = 'f', .desc = "Force overwrite without prompting" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .interactive = .{ .short = 'i', .desc = "Prompt before overwrite" },
        .no_dereference = .{ .short = 'd', .desc = "Never follow symbolic links in SOURCE" },
        .preserve = .{ .short = 'p', .desc = "Preserve mode, ownership, timestamps" },
        .recursive = .{ .short = 'r', .desc = "Copy directories recursively" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Runtime options for copy operations
const RuntimeOptions = struct {
    force: bool = false,
    interactive: bool = false,
    no_dereference: bool = false,
    preserve: bool = false,
    recursive: bool = false,
};

/// File type enumeration for copy operations
const FileType = enum {
    directory,
    regular_file,
    special,
    symlink,
};

/// Copy operation statistics
const CopyStats = struct {
    errors_encountered: usize = 0,
};

/// Main entry point for the cp command
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runUtility(allocator, args[1..], stdout_writer, stderr_writer);
    std.process.exit(@intFromEnum(exit_code));
}

/// Run cp with provided writers for output
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !common.ExitCode {
    const prog_name = "cp";

    // Parse command line arguments
    const config = common.argparse.ArgParser.parse(CpConfig, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "unrecognized option\nTry '{s} --help' for more information.", .{prog_name});
                return common.ExitCode.misuse;
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument\nTry '{s} --help' for more information.", .{prog_name});
                return common.ExitCode.misuse;
            },
            else => return err,
        }
    };
    defer allocator.free(config.positionals);

    if (config.help) {
        try printHelp(stdout_writer);
        return common.ExitCode.success;
    }
    if (config.version) {
        try stdout_writer.print("cp ({s}) {s}\n", .{ common.name, common.version });
        return common.ExitCode.success;
    }

    // Validate argument count
    if (config.positionals.len < 2) {
        if (config.positionals.len == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing file operand", .{});
            return common.ExitCode.misuse;
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing destination file operand after '{s}'", .{config.positionals[0]});
            return common.ExitCode.misuse;
        }
    }

    // Execute copy operations
    var stats = CopyStats{};
    const success = try executeCopyOperations(allocator, stderr_writer, config.positionals, config.runtime(), &stats);

    return if (success) common.ExitCode.success else common.ExitCode.general_error;
}

/// Execute all copy operations
fn executeCopyOperations(allocator: Allocator, stderr_writer: anytype, args: []const []const u8, options: RuntimeOptions, stats: *CopyStats) !bool {
    const dest = args[args.len - 1];

    // If multiple sources, destination must be a directory
    if (args.len > 2) {
        const dest_type = getFileTypeAtomic(dest, false) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "target '{s}' is not a directory", .{dest});
            return false;
        };

        if (dest_type != .directory) {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "target '{s}' is not a directory", .{dest});
            return false;
        }
    }

    var success = true;

    // Process each source
    for (args[0 .. args.len - 1]) |source| {
        const result = copySingleFile(allocator, stderr_writer, source, dest, options, stats) catch false;
        if (!result) success = false;
    }

    return success;
}

/// Copy a single file or directory
fn copySingleFile(allocator: Allocator, stderr_writer: anytype, source: []const u8, dest: []const u8, options: RuntimeOptions, stats: *CopyStats) !bool {
    // Get source file type
    const source_type = getFileTypeAtomic(source, options.no_dereference) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}': {s}", .{ source, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return false;
    };

    // Resolve final destination path
    const final_dest_path = resolveFinalDestination(allocator, source, dest) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "error resolving destination: {s}", .{getStandardErrorName(err)});
        stats.errors_encountered += 1;
        return false;
    };
    defer allocator.free(final_dest_path);

    // Check for same file
    if (isSameFile(source, final_dest_path) catch false) {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}' and '{s}' are the same file", .{ source, final_dest_path });
        stats.errors_encountered += 1;
        return false;
    }

    // Check if destination exists
    const dest_exists = fileExists(final_dest_path);

    // Validate operation
    if (source_type == .directory and !options.recursive) {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}' is a directory (use -r to copy recursively)", .{source});
        stats.errors_encountered += 1;
        return false;
    }

    // Handle destination exists
    if (dest_exists and !options.force and !options.interactive) {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}' already exists", .{final_dest_path});
        stats.errors_encountered += 1;
        return false;
    }

    // Handle interactive mode
    if (options.interactive and dest_exists) {
        const should_proceed = shouldOverwrite(allocator, stderr_writer, final_dest_path) catch false;
        if (!should_proceed) {
            return true; // User cancelled, not an error
        }
    }

    // Execute the copy based on source type
    return switch (source_type) {
        .regular_file => copyRegularFile(allocator, stderr_writer, source, final_dest_path, options, stats),
        .symlink => if (options.no_dereference)
            copySymlink(allocator, stderr_writer, source, final_dest_path, options, stats)
        else
            copyRegularFile(allocator, stderr_writer, source, final_dest_path, options, stats),
        .directory => copyDirectory(allocator, stderr_writer, source, final_dest_path, options, stats),
        .special => blk: {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}': unsupported file type", .{source});
            stats.errors_encountered += 1;
            break :blk false;
        },
    };
}

/// Copy a regular file
fn copyRegularFile(allocator: Allocator, stderr_writer: anytype, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions, stats: *CopyStats) bool {
    // Get source file stats
    const source_stat = std.fs.cwd().statFile(source_path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}': {s}", .{ source_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return false;
    };

    // Handle force overwrite if needed
    if (fileExists(dest_path) and options.force) {
        handleForceOverwrite(dest_path) catch {};
    }

    if (options.preserve) {
        copyFileWithAttributes(allocator, stderr_writer, source_path, dest_path, source_stat, stats) catch {
            return false;
        };
    } else {
        std.fs.cwd().copyFile(source_path, std.fs.cwd(), dest_path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot copy '{s}' to '{s}': {s}", .{ source_path, dest_path, getStandardErrorName(err) });
            stats.errors_encountered += 1;
            return false;
        };
    }

    return true;
}

/// Copy a symbolic link
fn copySymlink(allocator: Allocator, stderr_writer: anytype, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions, stats: *CopyStats) bool {
    // Read the symlink target
    const target = getSymlinkTarget(allocator, source_path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot read link '{s}': {s}", .{ source_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return false;
    };
    defer allocator.free(target);

    // Handle force overwrite if needed
    if (fileExists(dest_path) and options.force) {
        handleForceOverwrite(dest_path) catch {};
    }

    // Create the symlink
    std.fs.cwd().symLink(target, dest_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create symlink '{s}': {s}", .{ dest_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return false;
    };

    return true;
}

/// Copy a directory recursively
fn copyDirectory(allocator: Allocator, stderr_writer: anytype, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions, stats: *CopyStats) bool {
    // Create destination directory
    std.fs.cwd().makeDir(dest_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Directory already exists, continue
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create directory '{s}': {s}", .{ dest_path, getStandardErrorName(err) });
            stats.errors_encountered += 1;
            return false;
        },
    };

    // Preserve directory permissions when preserve option is set
    if (options.preserve) {
        if (std.fs.cwd().statFile(source_path)) |source_stat| {
            if (std.fs.cwd().openDir(dest_path, .{})) |dest_dir_const| {
                var dest_dir = dest_dir_const;
                defer dest_dir.close();
                dest_dir.chmod(source_stat.mode) catch |err| {
                    common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot preserve permissions for '{s}': {s}", .{ dest_path, getStandardErrorName(err) });
                };
            } else |err| {
                common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}' for permission preservation: {s}", .{ dest_path, getStandardErrorName(err) });
            }
        } else |err| {
            common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}' for permission preservation: {s}", .{ source_path, getStandardErrorName(err) });
        }
    }

    // Open source directory for iteration
    var source_dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open directory '{s}': {s}", .{ source_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return false;
    };
    defer source_dir.close();

    var success = true;

    // Iterate through directory entries
    var iterator = source_dir.iterate();
    while (iterator.next() catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "error reading directory '{s}': {s}", .{ source_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return false;
    }) |entry| {
        // Skip . and .. entries
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        // Construct full paths
        const source_child_path = std.fs.path.join(allocator, &.{ source_path, entry.name }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot allocate memory for path: {s}", .{getStandardErrorName(err)});
            stats.errors_encountered += 1;
            success = false;
            continue;
        };
        defer allocator.free(source_child_path);

        const dest_child_path = std.fs.path.join(allocator, &.{ dest_path, entry.name }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot allocate memory for path: {s}", .{getStandardErrorName(err)});
            stats.errors_encountered += 1;
            success = false;
            continue;
        };
        defer allocator.free(dest_child_path);

        // Recursively copy child
        const result = copySingleFile(allocator, stderr_writer, source_child_path, dest_child_path, options, stats) catch false;
        if (!result) success = false;
    }

    return success;
}

/// Copy file with preserved attributes
fn copyFileWithAttributes(allocator: Allocator, stderr_writer: anytype, source_path: []const u8, dest_path: []const u8, source_stat: std.fs.File.Stat, stats: *CopyStats) !void {
    // Open source file
    const source_file = std.fs.cwd().openFile(source_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}': {s}", .{ source_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return error.SourceNotReadable;
    };
    defer source_file.close();

    // Create destination file with source mode
    const dest_file = std.fs.cwd().createFile(dest_path, .{ .mode = source_stat.mode }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create '{s}': {s}", .{ dest_path, getStandardErrorName(err) });
        stats.errors_encountered += 1;
        return error.DestinationNotWritable;
    };
    defer dest_file.close();

    // Copy file contents using fixed buffer size
    var buffer: [COPY_BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes_read = source_file.read(buffer[0..]) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "error reading '{s}': {s}", .{ source_path, getStandardErrorName(err) });
            stats.errors_encountered += 1;
            return error.SourceNotReadable;
        };

        if (bytes_read == 0) break;

        dest_file.writeAll(buffer[0..bytes_read]) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "error writing '{s}': {s}", .{ dest_path, getStandardErrorName(err) });
            stats.errors_encountered += 1;
            return error.DestinationNotWritable;
        };
    }

    // Preserve timestamps
    dest_file.updateTimes(source_stat.atime, source_stat.mtime) catch |err| {
        common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot preserve timestamps for '{s}': {s}", .{ dest_path, getStandardErrorName(err) });
    };
}

/// Get file type atomically to avoid race conditions
fn getFileTypeAtomic(path: []const u8, no_dereference: bool) !FileType {
    if (no_dereference) {
        // Check for symlinks first using readLink
        var link_buf: [1]u8 = undefined;
        if (std.fs.cwd().readLink(path, &link_buf)) |_| {
            return .symlink;
        } else |err| switch (err) {
            error.NotLink => {
                // Not a symlink, fall through to stat the actual file
            },
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        }
    }

    // Get file stats to determine type
    const file_stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };

    return switch (file_stat.kind) {
        .directory => .directory,
        .file => .regular_file,
        else => .special,
    };
}

/// Resolve the final destination path for a copy operation
fn resolveFinalDestination(allocator: Allocator, source: []const u8, dest: []const u8) ![]u8 {
    // Check if destination exists and is a directory
    const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
        error.FileNotFound => {
            // Destination doesn't exist, use as-is
            return try allocator.dupe(u8, dest);
        },
        else => return err,
    };

    if (dest_stat.kind == .directory) {
        // Destination is a directory, append source basename
        const source_basename = std.fs.path.basename(source);
        return try std.fs.path.join(allocator, &[_][]const u8{ dest, source_basename });
    } else {
        // Destination is a file, use as-is
        return try allocator.dupe(u8, dest);
    }
}

/// Check if a file exists at the given path
fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Get the target of a symbolic link
fn getSymlinkTarget(allocator: Allocator, path: []const u8) ![]u8 {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.cwd().readLink(path, &target_buf);
    return try allocator.dupe(u8, target);
}

/// Check if source and destination refer to the same file
fn isSameFile(source: []const u8, dest: []const u8) !bool {
    const source_stat = std.fs.cwd().statFile(source) catch return false;
    const dest_stat = std.fs.cwd().statFile(dest) catch return false;
    return source_stat.inode == dest_stat.inode;
}

/// Convert system error to user-friendly error message
fn getStandardErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied => "Permission denied",
        error.BadPathName => "Invalid file name",
        error.CrossDeviceLink => "Invalid cross-device link (try 'mv' for cross-filesystem moves)",
        error.DeviceBusy => "Device or resource busy",
        error.DiskQuota => "Disk quota exceeded",
        error.EmptyPath => "Empty path",
        error.FileBusy => "Text file busy",
        error.FileNotFound => "No such file or directory",
        error.FileTooBig => "File too large",
        error.InvalidHandle => "Invalid file handle",
        error.InvalidPath => "Invalid path",
        error.IsDir => "Is a directory",
        error.NameTooLong => "File name too long",
        error.NoSpaceLeft => "No space left on device",
        error.NotDir => "Not a directory",
        error.NotLink => "Not a symbolic link",
        error.OutOfMemory => "Cannot allocate memory",
        error.PathAlreadyExists => "File exists",
        error.PathTooLong => "File name too long",
        error.PermissionDenied => "Permission denied",
        error.ProcessFdQuotaExceeded => "Too many open files in system",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.SystemFdQuotaExceeded => "Too many open files",
        error.SystemResources => "Insufficient system resources",
        error.Unexpected => "Unexpected error",
        error.WouldBlock => "Resource temporarily unavailable",
        else => @errorName(err),
    };
}

/// Prompt user for overwrite confirmation
fn shouldOverwrite(allocator: Allocator, stderr_writer: anytype, dest_path: []const u8) !bool {
    if (builtin.is_test) return false;

    // Check for CI environments
    if (std.process.getEnvVarOwned(allocator, "CI")) |ci_val| {
        defer allocator.free(ci_val);
        return false;
    } else |_| {}

    try stderr_writer.print("cp: overwrite '{s}'? ", .{dest_path});
    return promptYesNo(allocator);
}

/// Prompt user with a yes/no question
fn promptYesNo(allocator: Allocator) !bool {
    if (builtin.is_test) return false;

    // Check environment variables before any file operations
    if (std.process.getEnvVarOwned(allocator, "CI")) |ci_val| {
        defer allocator.free(ci_val);
        return false;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "GITHUB_ACTIONS")) |ga_val| {
        defer allocator.free(ga_val);
        return false;
    } else |_| {}

    const stdin_file = std.io.getStdIn();
    if (!stdin_file.isTty()) return false;

    var buffer: [10]u8 = undefined;
    const stdin = stdin_file.reader();

    if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        if (line.len > 0) {
            const first_char = std.ascii.toLower(line[0]);
            return first_char == 'y';
        }
    }

    return false;
}

/// Handle force removal of destination file
fn handleForceOverwrite(dest_path: []const u8) !void {
    std.fs.cwd().deleteFile(dest_path) catch |err| switch (err) {
        error.FileNotFound => {}, // Already doesn't exist
        error.IsDir => return err, // Can't remove directory with deleteFile
        else => return err,
    };
}

/// Print help message for cp
fn printHelp(writer: anytype) !void {
    try writer.print(
        \\Usage: cp [OPTION]... [-T] SOURCE DEST
        \\   or: cp [OPTION]... SOURCE... DIRECTORY
        \\   or: cp [OPTION]... -t DIRECTORY SOURCE...
        \\Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.
        \\
        \\Options:
        \\  -d, --no-dereference     never follow symbolic links in SOURCE
        \\  -f, --force              force overwrite without prompting
        \\  -h, --help               display this help and exit
        \\  -i, --interactive        prompt before overwrite
        \\  -p, --preserve           preserve mode, ownership, timestamps
        \\  -r, -R, --recursive      copy directories recursively
        \\  -V, --version            output version information and exit
        \\
        \\Examples:
        \\  cp foo.txt bar.txt    Copy foo.txt to bar.txt
        \\  cp -r dir1 dir2       Copy dir1 and its contents to dir2
        \\  cp file1 file2 dir/   Copy multiple files into dir/
        \\
    , .{});
}

// Tests

test "cp: single file copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("source.txt", "Hello, World!", null);

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "source.txt", "dest.txt" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);
    try test_dir.expectFileContent("dest.txt", "Hello, World!");
}

test "cp: copy to existing directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("source.txt", "Test content", null);
    try test_dir.createDir("dest_dir");

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "source.txt", "dest_dir" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);
    try test_dir.expectFileContent("dest_dir/source.txt", "Test content");
}

test "cp: error on directory without recursive flag" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createDir("source_dir");

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "source_dir", "dest_dir" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.general_error, exit_code);
}

test "cp: recursive directory copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    // Create source directory structure
    try test_dir.createDir("source_dir");
    try test_dir.createDir("source_dir/subdir");
    try test_dir.createFile("source_dir/file1.txt", "File 1 content", null);
    try test_dir.createFile("source_dir/subdir/file2.txt", "File 2 content", null);

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-r", "source_dir", "dest_dir" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);
    try test_dir.expectFileContent("dest_dir/file1.txt", "File 1 content");
    try test_dir.expectFileContent("dest_dir/subdir/file2.txt", "File 2 content");
}

test "cp: preserve attributes" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("source.txt", "Test content", 0o644);

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-p", "source.txt", "dest.txt" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // Check user permissions (works without privileges)
    const source_user_perms = source_stat.mode & 0o700;
    const dest_user_perms = dest_stat.mode & 0o700;
    try testing.expectEqual(source_user_perms, dest_user_perms);
}

test "cp: symbolic link handling - follow by default" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("original.txt", "Original content", null);
    try test_dir.createSymlink("original.txt", "link.txt");

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "link.txt", "copied.txt" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);
    try test_dir.expectFileContent("copied.txt", "Original content");
    try testing.expect(!(try test_dir.isSymlink("copied.txt")));
}

test "cp: symbolic link handling - no dereference (-d)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("original.txt", "Original content", null);
    try test_dir.createSymlink("original.txt", "link.txt");

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-d", "link.txt", "copied_link.txt" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);
    try testing.expect(try test_dir.isSymlink("copied_link.txt"));
    const target = try test_dir.getSymlinkTarget("copied_link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("original.txt", target);
}

test "cp: multiple sources to directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    try test_dir.createFile("file1.txt", "Content 1", null);
    try test_dir.createFile("file2.txt", "Content 2", null);
    try test_dir.createDir("dest_dir");

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "file1.txt", "file2.txt", "dest_dir" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);
    try test_dir.expectFileContent("dest_dir/file1.txt", "Content 1");
    try test_dir.expectFileContent("dest_dir/file2.txt", "Content 2");
}

test "cp: large file copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    // Create a file larger than the copy buffer
    const large_size = COPY_BUFFER_SIZE + 1024;
    const content = try testing.allocator.alloc(u8, large_size);
    defer testing.allocator.free(content);

    // Fill with predictable pattern
    for (content, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    try test_dir.createFile("large_source.bin", content, null);

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "large_source.bin", "large_dest.bin" };
    const exit_code = try runUtility(testing.allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);

    // Verify the copied file has identical content
    const copied_content = try test_dir.readFileAlloc("large_dest.bin");
    defer testing.allocator.free(copied_content);

    try testing.expectEqual(large_size, copied_content.len);
    try testing.expectEqualSlices(u8, content, copied_content);
}

test "privileged: permission preservation with mode bits" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();
    try test_dir.setup();

    // Create source file with specific permissions
    try test_dir.createFile("source.txt", "Test content", 0o755);

    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{ "-p", "source.txt", "dest.txt" };
    const exit_code = try runUtility(allocator, &args, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(common.ExitCode.success, exit_code);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // With privilege, full mode bits should be preserved
    try testing.expectEqual(source_stat.mode & 0o777, dest_stat.mode & 0o777);
}

// Fuzzing

const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("cp");

test "cp fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testCpIntelligentWrapper, .{});
}

fn testCpIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    const CpIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(CpConfig, runUtility);
    try CpIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
