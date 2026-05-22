//! Simple POSIX-compatible rm command.

const std = @import("std");
const common = @import("common");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Command-line arguments for rm.
const RmArgs = struct {
    help: bool = false,
    version: bool = false,
    force: bool = false,
    interactive: bool = false,
    interactive_once: bool = false,
    recursive: bool = false,
    R: bool = false,
    remove_empty_dirs: bool = false,
    P: bool = false,
    verbose: bool = false,
    preserve_root: bool = false,
    no_preserve_root: bool = false,
    no_cross_device: bool = false,
    undelete: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .force = .{ .short = 'f', .desc = "Ignore nonexistent files and arguments, never prompt" },
        .interactive = .{ .short = 'i', .desc = "Prompt before every removal" },
        .interactive_once = .{ .short = 'I', .desc = "Prompt once before removing more than three files, or when removing recursively" },
        .recursive = .{ .short = 'r', .desc = "Remove directories and their contents recursively" },
        .R = .{ .short = 'R', .desc = "Remove directories and their contents recursively (same as -r)" },
        .remove_empty_dirs = .{ .short = 'd', .desc = "Remove empty directories" },
        .P = .{ .short = 'P', .desc = "Overwrite before deletion (no-op, BSD compatibility)" },
        .verbose = .{ .short = 'v', .desc = "Explain what is being done" },
        .preserve_root = .{ .short = 0, .desc = "Do not remove '/' (default)" },
        .no_preserve_root = .{ .short = 0, .desc = "Do not treat '/' specially" },
        .no_cross_device = .{ .short = 'x', .desc = "Don't cross mount points during recursive removal" },
        .undelete = .{ .short = 'W', .desc = "Attempt to undelete (not supported, stub)" },
    };
};

/// Options controlling rm behavior.
const RmOptions = struct {
    force: bool,
    interactive: bool,
    interactive_once: bool,
    recursive: bool,
    remove_empty_dirs: bool = false,
    verbose: bool,
    preserve_root: bool,
    no_cross_device: bool = false,
};

/// Main entry point
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runRm);
}

/// Main entry point for the rm command with writer-based interface.
pub fn runRm(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parseOrExit(RmArgs, allocator, args, "rm", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed_args.positionals);

    // Handle help flag
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const files = parsed_args.positionals;
    if (files.len == 0) {
        if (parsed_args.force) return @intFromEnum(common.ExitCode.success);
        common.printErrorWithProgram(allocator, stderr_writer, "rm", "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -W: undelete is not supported on Linux. Print error and
    // return without deleting anything — deleting a file when
    // asked to recover it would be dangerous data loss.
    if (parsed_args.undelete) {
        try stderr_writer.writeAll("rm: -W (undelete) not supported on this platform\n");
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Create options structure - merge -i/-I and -r/-R flags
    // --preserve-root is default true; --no-preserve-root disables it
    const options = RmOptions{
        .force = parsed_args.force,
        .interactive = parsed_args.interactive,
        .interactive_once = parsed_args.interactive_once,
        .recursive = parsed_args.recursive or parsed_args.R,
        .remove_empty_dirs = parsed_args.remove_empty_dirs,
        .verbose = parsed_args.verbose,
        .preserve_root = !parsed_args.no_preserve_root,
        .no_cross_device = parsed_args.no_cross_device,
    };

    const success = try removeFiles(allocator, io, files, stdout_writer, stderr_writer, options);
    return if (success) @intFromEnum(common.ExitCode.success) else @intFromEnum(common.ExitCode.general_error);
}

/// Prints help information to the specified writer.
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    const help_text =
        \\Usage: rm [OPTION]... [FILE]...
        \\Remove (unlink) the FILE(s).
        \\
        \\  -d, --remove-empty-dirs  remove empty directories
        \\  -f, --force           ignore nonexistent files and arguments, never prompt
        \\  -i                    prompt before every removal
        \\  -I                    prompt once before removing more than three files,
        \\                          or when removing recursively
        \\  -r, -R, --recursive   remove directories and their contents recursively
        \\  -v, --verbose         explain what is being done
        \\  -x                    do not cross mount points during recursive removal
        \\  -W                    attempt to undelete (not supported, stub)
        \\      --preserve-root   do not remove '/' (default)
        \\      --no-preserve-root  do not treat '/' specially
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\By default, rm does not remove directories. Use the --recursive (-r or -R)
        \\option to remove each listed directory, too, along with all of its contents.
        \\
    ;
    try common.help.printColorized(allocator, writer, help_text);
}

/// Prints version information to the specified writer.
fn printVersion(writer: *std.Io.Writer) !void {
    const build_options = @import("build_options");
    try writer.print("rm (vibeutils) {s}\n", .{build_options.version});
}

/// Main file removal function that processes a list of files/directories.
fn removeFiles(allocator: Allocator, io: std.Io, files: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, options: RmOptions) !bool {
    // Handle interactive once mode (-I flag) - but force overrides
    if (!options.force and options.interactive_once and (files.len > 3 or options.recursive)) {
        if (!try common.prompt.promptYesNo(io, stderr_writer, "rm: remove {d} arguments? ", .{files.len})) {
            return true; // User said no, but no error occurred
        }
    }

    var any_errors = false;

    for (files) |file| {
        // Check preserve-root protection before anything else
        if (options.preserve_root and isRootPath(file)) {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "refusing to remove '/'; use --no-preserve-root to override", .{});
            any_errors = true;
            continue;
        }

        // Enhanced path validation using OpenBSD-style basename checking
        if (!isPathSafeToRemove(file)) {
            if (file.len == 0) {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '': No such file or directory", .{});
            } else if (std.mem.eql(u8, file, "/")) {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "it is dangerous to operate recursively on '/'", .{});
            } else {
                // Must be a "." or ".." pattern (including complex paths like "/path/to/.")
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "\".\" and \"..\" may not be removed", .{});
            }
            any_errors = true;
            continue;
        }

        // Try to remove the file/directory
        removeItem(allocator, io, file, stdout_writer, stderr_writer, options) catch |err| switch (err) {
            error.FileNotFound => {
                if (!options.force) {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': No such file or directory", .{file});
                    any_errors = true;
                }
            },
            error.AccessDenied => {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Permission denied", .{file});
                any_errors = true;
            },
            error.IsDir => {
                if (options.recursive) {
                    removeDirectory(allocator, io, file, stdout_writer, stderr_writer, options) catch |dir_err| {
                        switch (dir_err) {
                            error.InteractiveUserCancelled => {}, // User said no in interactive mode, continue
                            else => {
                                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ file, common.posixErrorString(dir_err) });
                                any_errors = true;
                            },
                        }
                    };
                } else if (options.remove_empty_dirs) {
                    // -d flag: attempt to remove empty directory (like rmdir)
                    std.Io.Dir.cwd().deleteDir(io, file) catch |dir_err| {
                        switch (dir_err) {
                            error.DirNotEmpty => {
                                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Directory not empty", .{file});
                                any_errors = true;
                            },
                            error.AccessDenied => {
                                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Permission denied", .{file});
                                any_errors = true;
                            },
                            else => {
                                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ file, common.posixErrorString(dir_err) });
                                any_errors = true;
                            },
                        }
                    };
                    if (!any_errors and options.verbose) {
                        try stdout_writer.print("removed directory '{s}'\n", .{file});
                    }
                } else {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Is a directory", .{file});
                    any_errors = true;
                }
            },
            error.InteractiveUserCancelled => {
                // User declined in interactive mode - this is normal behavior, not an error
            },
            error.UserCancelled => {
                // User declined write-protected file prompt - this is an error
                any_errors = true;
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ file, common.posixErrorString(err) });
                any_errors = true;
            },
        };
    }

    return !any_errors;
}

/// Remove a single file or symlink.
fn removeItem(_: Allocator, io: std.Io, file_path: []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, options: RmOptions) !void {
    // Use lstat so symlinks are examined directly (not their targets).
    // statFile follows symlinks, which misclassifies symlinks-to-directories
    // as directories and incorrectly requires -r.
    const stat_result = common.file.FileInfo.lstat(file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };

    // Check if it's a directory
    if (stat_result.kind == .directory) {
        return error.IsDir;
    }

    // POSIX compliance: Force flag suppresses ALL prompts
    if (options.force) {
        // Force mode: no prompts, proceed with removal
    } else if (options.interactive) {
        // Interactive mode: always prompt
        if (!try common.prompt.promptYesNo(io, stderr_writer, "rm: remove regular file '{s}'? ", .{file_path})) {
            return error.InteractiveUserCancelled;
        }
    } else {
        // Default mode: prompt only for write-protected files
        const mode = stat_result.mode;
        const user_write = (mode & 0o200) != 0;
        if (!user_write) {
            if (!try common.prompt.promptYesNo(io, stderr_writer, "rm: remove write-protected regular file '{s}'? ", .{file_path})) {
                return error.UserCancelled;
            }
        }
    }

    // Remove the file
    std.Io.Dir.cwd().deleteFile(io, file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };

    // Print verbose output
    if (options.verbose) {
        try stdout_writer.print("removed '{s}'\n", .{file_path});
    }
}

/// Entry type for collected directory entries
const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

/// Remove a directory recursively with per-entry verbose/interactive support.
fn removeDirectory(allocator: Allocator, io: std.Io, dir_path: []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, options: RmOptions) !void {
    // For non-verbose, non-interactive mode with force and no -x, use deleteTree as fast path
    if (!options.verbose and !options.interactive and options.force and !options.no_cross_device) {
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            else => return err,
        };
        return;
    }

    // Determine root device ID for -x (don't cross mount points)
    const root_dev: ?u64 = if (options.no_cross_device)
        getDeviceId(io, dir_path) catch null
    else
        null;

    // Manual depth-first recursive traversal
    try removeDirectoryRecursive(allocator, io, dir_path, stdout_writer, stderr_writer, options, root_dev);
}

/// Get the device ID for a path. Uses the cross-platform
/// common.file.FileInfo.stat which handles Linux (statx) and
/// macOS/BSD (fstat via the file descriptor) uniformly.
fn getDeviceId(io: std.Io, path: []const u8) !u64 {
    const info = common.file.FileInfo.stat(io, path) catch return error.StatFailed;
    return info.dev;
}

/// Depth-first recursive directory removal with per-entry verbose/interactive support.
fn removeDirectoryRecursive(allocator: Allocator, io: std.Io, dir_path: []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, options: RmOptions, root_dev: ?u64) anyerror!void {
    // -x: skip directories on different filesystems
    if (options.no_cross_device) {
        if (root_dev) |rd| {
            const dev = getDeviceId(io, dir_path) catch 0;
            if (dev != rd) return;
        }
    }

    // Open directory for iteration
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };

    var had_errors = false;

    // Collect entries first to avoid iterator invalidation during deletion
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    {
        var iterator = dir.iterate();
        while (iterator.next(io) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot read directory '{s}': {s}", .{ dir_path, common.posixErrorString(err) });
            dir.close(io);
            return err;
        }) |entry| {
            const name_copy = try allocator.dupe(u8, entry.name);
            try entries.append(allocator, .{ .name = name_copy, .kind = entry.kind });
        }
    }

    // Close directory handle before modifying contents
    dir.close(io);

    // Process entries depth-first
    for (entries.items) |entry| {
        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot construct path: {s}", .{common.posixErrorString(err)});
            had_errors = true;
            continue;
        };
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            // Recurse into subdirectory first (depth-first)
            if (removeDirectoryRecursive(allocator, io, full_path, stdout_writer, stderr_writer, options, root_dev)) {
                // Success - continue
            } else |err| switch (err) {
                error.InteractiveUserCancelled => {},
                else => had_errors = true,
            }
        } else {
            // Remove file entry with interactive/verbose support
            removeItem(allocator, io, full_path, stdout_writer, stderr_writer, options) catch |err| switch (err) {
                error.InteractiveUserCancelled => continue,
                error.UserCancelled => {
                    had_errors = true;
                    continue;
                },
                error.FileNotFound => {
                    if (!options.force) {
                        common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': No such file or directory", .{full_path});
                        had_errors = true;
                    }
                    continue;
                },
                error.AccessDenied => {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Permission denied", .{full_path});
                    had_errors = true;
                    continue;
                },
                else => {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ full_path, common.posixErrorString(err) });
                    had_errors = true;
                    continue;
                },
            };
        }
    }

    // Now remove the (should-be-empty) directory itself
    // Prompt if interactive
    if (!options.force and options.interactive) {
        if (!try common.prompt.promptYesNo(io, stderr_writer, "rm: remove directory '{s}'? ", .{dir_path})) {
            return error.InteractiveUserCancelled;
        }
    }

    std.Io.Dir.cwd().deleteDir(io, dir_path) catch |err| switch (err) {
        error.DirNotEmpty => {
            // Some entries may have been skipped (interactive cancel, errors)
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Directory not empty", .{dir_path});
            had_errors = true;
        },
        error.AccessDenied => {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Permission denied", .{dir_path});
            had_errors = true;
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ dir_path, common.posixErrorString(err) });
            had_errors = true;
        },
    };

    if (!had_errors) {
        if (options.verbose) {
            try stdout_writer.print("removed directory '{s}'\n", .{dir_path});
        }
    }

    if (had_errors) {
        return error.AccessDenied; // Generic error to signal failure
    }
}

/// Check if a basename is "." or ".." (OpenBSD ISDOT macro equivalent).
fn isDotOrDotDot(basename: []const u8) bool {
    return std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..");
}

/// Extract basename from path, handling trailing slashes like OpenBSD basename().
/// Returns the final component of the path, stripping trailing slashes.
fn extractBasename(path: []const u8) []const u8 {
    if (path.len == 0) return path;

    // Strip trailing slashes
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }

    // Handle root directory case "/"
    if (end == 1 and path[0] == '/') {
        return "/";
    }

    // Find the last slash before the basename
    var start: usize = 0;
    for (0..end) |i| {
        if (path[i] == '/') {
            start = i + 1;
        }
    }

    return path[start..end];
}

/// Check if a path normalizes to the root directory "/".
/// Catches "/", "///", "/.", etc. but NOT "/tmp" or "/usr".
fn isRootPath(path: []const u8) bool {
    if (path.len == 0) return false;

    // Must start with /
    if (path[0] != '/') return false;

    // Strip trailing slashes and dots to normalize
    var i: usize = path.len;
    while (i > 1) {
        const c = path[i - 1];
        if (c == '/') {
            i -= 1;
        } else if (c == '.' and i >= 2 and path[i - 2] == '/') {
            // Strip trailing "/." component
            i -= 2;
        } else {
            break;
        }
    }

    // If we stripped everything down to just "/", it's root
    return i <= 1;
}

/// Enhanced path validation that combines all OpenBSD-style safety checks.
/// Checks for empty paths, root directory, and dot/dotdot patterns.
fn isPathSafeToRemove(path: []const u8) bool {
    // Check for empty path
    if (path.len == 0) return false;

    // Check for root directory
    if (std.mem.eql(u8, path, "/")) return false;

    // Extract basename and check if it's "." or ".."
    const basename = extractBasename(path);
    if (isDotOrDotDot(basename)) return false;

    return true;
}

// Tests

test "rm: basic functionality test" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with non-existent file and force mode
    const args = [_][]const u8{ "-f", "definitely_nonexistent_file_12345.txt" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (exit code 0) with -f flag for non-existent file
    try testing.expect(exit_code == 0);
}

test "rm: root directory protection" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test removing root directory
    const args = [_][]const u8{ "-rf", "/" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail (non-zero exit code)
    try testing.expect(exit_code != 0);
    // Should have preserve-root error message
    try testing.expect(stderr_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove '/'") != null);
}

test "rm: empty path handling" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test empty path
    const args = [_][]const u8{""};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with error
    try testing.expect(exit_code != 0);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: missing operand" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with no arguments
    const args = [_][]const u8{};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with missing operand error
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "rm: help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test help flag
    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed and show help
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage:") != null);
}

test "rm: version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test version flag
    const args = [_][]const u8{"--version"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed and show version
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "vibeutils") != null);
}

test "isDotOrDotDot: basic dot detection" {
    try testing.expect(isDotOrDotDot("."));
    try testing.expect(isDotOrDotDot(".."));
    try testing.expect(!isDotOrDotDot("file.txt"));
    try testing.expect(!isDotOrDotDot("..."));
    try testing.expect(!isDotOrDotDot(""));
    try testing.expect(!isDotOrDotDot(".hidden"));
    try testing.expect(!isDotOrDotDot("..test"));
}

test "extractBasename: path handling" {
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("file.txt"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("./file.txt"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("/path/to/file.txt"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("/path/to/file.txt/"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("/path/to/file.txt///"));
    try testing.expectEqualSlices(u8, ".", extractBasename("."));
    try testing.expectEqualSlices(u8, "..", extractBasename(".."));
    try testing.expectEqualSlices(u8, ".", extractBasename("./"));
    try testing.expectEqualSlices(u8, "..", extractBasename("../"));
    try testing.expectEqualSlices(u8, ".", extractBasename("/path/to/."));
    try testing.expectEqualSlices(u8, "..", extractBasename("/path/to/.."));
    try testing.expectEqualSlices(u8, ".", extractBasename("/path/to/./"));
    try testing.expectEqualSlices(u8, "..", extractBasename("/path/to/../"));
}

test "isPathSafeToRemove: comprehensive validation" {
    // Test empty path (should be unsafe)
    try testing.expect(!isPathSafeToRemove(""));

    // Test root directory (should be unsafe)
    try testing.expect(!isPathSafeToRemove("/"));

    // Test current directory patterns (should be unsafe)
    try testing.expect(!isPathSafeToRemove("."));
    try testing.expect(!isPathSafeToRemove("./"));
    try testing.expect(!isPathSafeToRemove("/path/to/."));
    try testing.expect(!isPathSafeToRemove("/path/to/./"));

    // Test parent directory patterns (should be unsafe)
    try testing.expect(!isPathSafeToRemove(".."));
    try testing.expect(!isPathSafeToRemove("../"));
    try testing.expect(!isPathSafeToRemove("/path/to/.."));
    try testing.expect(!isPathSafeToRemove("/path/to/../"));

    // Test safe paths (should be safe)
    try testing.expect(isPathSafeToRemove("file.txt"));
    try testing.expect(isPathSafeToRemove("./file.txt"));
    try testing.expect(isPathSafeToRemove("/path/to/file.txt"));
    try testing.expect(isPathSafeToRemove(".hidden"));
    try testing.expect(isPathSafeToRemove("..hidden"));
    try testing.expect(isPathSafeToRemove("..."));
    try testing.expect(isPathSafeToRemove("test."));
    try testing.expect(isPathSafeToRemove("test.."));
    try testing.expect(isPathSafeToRemove("/usr/local/bin"));
}

test "rm: verbose recursive removal" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a directory tree
    try tmp.dir.createDir(io, "testdir", std.Io.File.Permissions.fromMode(0o755));
    var subdir = try tmp.dir.openDir(io, "testdir", .{});
    const file1 = try subdir.createFile(io, "file1.txt", .{});
    file1.close(io);
    const file2 = try subdir.createFile(io, "file2.txt", .{});
    file2.close(io);
    subdir.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, "testdir", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(testing.allocator, io, &[_][]const u8{dir_path}, &stdout_aw.writer, &stderr_aw.writer, options);

    try testing.expect(success);
    // Verbose output should mention individual files
    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, "removed '") != null or std.mem.find(u8, output, "removed directory '") != null);
}

test "rm: recursive removal with nested directories" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create nested directory tree
    try tmp.dir.createDirPath(io, "deep/nested/dir");
    var deep_dir = try tmp.dir.openDir(io, "deep/nested/dir", .{});
    const file = try deep_dir.createFile(io, "leaf.txt", .{});
    file.close(io);
    deep_dir.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, "deep", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(testing.allocator, io, &[_][]const u8{dir_path}, &stdout_aw.writer, &stderr_aw.writer, options);

    try testing.expect(success);

    // Verify directory is gone
    const stat = std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expect(stat == error.FileNotFound);
}

test "isRootPath: detects root and normalized root paths" {
    // Exact root
    try testing.expect(isRootPath("/"));

    // Multiple slashes normalize to root
    try testing.expect(isRootPath("///"));
    try testing.expect(isRootPath("//"));

    // Trailing dot normalizes to root
    try testing.expect(isRootPath("/."));
    try testing.expect(isRootPath("/./"));

    // Non-root paths should NOT match
    try testing.expect(!isRootPath("/tmp"));
    try testing.expect(!isRootPath("/usr/local/bin"));
    try testing.expect(!isRootPath("/tmp/"));
    try testing.expect(!isRootPath("tmp"));
    try testing.expect(!isRootPath(""));
    try testing.expect(!isRootPath("."));
    try testing.expect(!isRootPath(".."));
    try testing.expect(!isRootPath("./"));
}

test "rm: triple-slash root protection" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test removing "///" which normalizes to "/"
    const args = [_][]const u8{ "-rf", "///" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with preserve-root error
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove '/'") != null);
}

test "rm: no-preserve-root flag is parsed" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test that --no-preserve-root is recognized as a valid flag
    // Use a non-existent file with -f to avoid actual filesystem operations
    const args = [_][]const u8{ "--no-preserve-root", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (exit code 0) because -f ignores nonexistent files
    try testing.expect(exit_code == 0);
}

test "rm: non-root path does not trigger preserve-root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test that /tmp/nonexistent does NOT trigger preserve-root
    const args = [_][]const u8{ "-f", "/tmp/nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (-f ignores nonexistent) and NOT show preserve-root error
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove '/'") == null);
}

test "rm: preserve-root flag is accepted" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test that --preserve-root is recognized (it's the default, but should be accepted)
    const args = [_][]const u8{ "--preserve-root", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed since -f ignores nonexistent files
    try testing.expect(exit_code == 0);
}

test "rm: help text includes preserve-root flags" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--preserve-root") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--no-preserve-root") != null);
}

// ============================================================
// Tests for rm -d (remove empty directories)
// ============================================================

test "rm: -d flag is accepted by argument parser" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: -d removes an empty directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "emptydir", std.Io.File.Permissions.fromMode(0o755));

    const dir_path = try tmp.dir.realPathFileAlloc(io, "emptydir", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    const stat = tmp.dir.statFile(io, "emptydir", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: -d fails on non-empty directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "nonemptydir", std.Io.File.Permissions.fromMode(0o755));
    var subdir = try tmp.dir.openDir(io, "nonemptydir", .{});
    const file = try subdir.createFile(io, "somefile.txt", .{});
    file.close(io);
    subdir.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, "nonemptydir", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code != 0);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: -d still removes regular files" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "regularfile.txt", .{});
    file.close(io);

    const file_path = try tmp.dir.realPathFileAlloc(io, "regularfile.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    const stat = tmp.dir.statFile(io, "regularfile.txt", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: without -d or -r refuses to remove directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "somedir", std.Io.File.Permissions.fromMode(0o755));

    const dir_path = try tmp.dir.realPathFileAlloc(io, "somedir", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{dir_path};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Is a directory") != null);
}

// ============================================================
// Tests for rm -P (BSD compatibility no-op flag)
// ============================================================

test "rm: -P flag is accepted by argument parser" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: -P removes a file just like normal rm" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "securefile.txt", .{});
    file.close(io);

    const file_path = try tmp.dir.realPathFileAlloc(io, "securefile.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    const stat = tmp.dir.statFile(io, "securefile.txt", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: -P combined with -f works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
    try testing.expect(stderr_aw.writer.buffered().len == 0);
}

// ============================================================
// Tests for rm -x (don't cross mount points)
// ============================================================

test "rm: -x flag is accepted by argument parser" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-x", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: -x recursive removal stays on same device" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a directory tree on the same device
    try tmp.dir.createDirPath(io, "xdir/subdir");
    var subdir = try tmp.dir.openDir(io, "xdir/subdir", .{});
    const file = try subdir.createFile(io, "file.txt", .{});
    file.close(io);
    subdir.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, "xdir", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -x -r should remove everything since it's all on the same device
    const args = [_][]const u8{ "-x", "-r", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    // Verify directory is gone
    const stat = std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: -x combined with -rf works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-x", "-rf", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: help text includes -x flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-x") != null);
}

// ============================================================
// Tests for rm -W (undelete stub)
// ============================================================

test "rm: -W flag is accepted and prints warning" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // -W (undelete) is not supported on Linux; should exit non-zero
    try testing.expect(exit_code != 0);
    // Should print warning/error to stderr
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: -W does not delete existing file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "undelete_test.txt", .{});
    file.close(io);

    const file_path = try tmp.dir.realPathFileAlloc(io, "undelete_test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // -W must NOT delete the file — that would be data loss
    try testing.expect(exit_code != 0);
    // Warning should appear
    try testing.expect(stderr_aw.writer.buffered().len > 0);
    // File must still exist
    const stat = tmp.dir.statFile(io, "undelete_test.txt", .{});
    try testing.expect(stat != error.FileNotFound);
}

test "rm: -W must not delete existing file" {
    // F67: rm -W is supposed to attempt recovery (undelete), not deletion.
    // On Linux where undelete is unsupported, it should error and leave
    // the file intact. Deleting a file when asked to recover it is
    // dangerous data loss.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "preserve_me.txt", .{});
    file.close(io);

    const file_path = try tmp.dir.realPathFileAlloc(io, "preserve_me.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // File MUST still exist -- -W should never delete
    const stat = tmp.dir.statFile(io, "preserve_me.txt", .{});
    try testing.expect(stat != error.FileNotFound);

    // Exit code must be non-zero since undelete is not supported
    try testing.expect(exit_code != 0);
}

test "rm: -W on nonexistent file returns error" {
    // Attempting to undelete a file that doesn't exist should error.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", "/tmp/nonexistent_rm_W_test_99999" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with non-zero exit
    try testing.expect(exit_code != 0);
    // Stderr should contain an error message
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: -W on directory returns error without removing it" {
    // -W on a directory should also not remove it.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "keep_this_dir", std.Io.File.Permissions.fromMode(0o755));

    const dir_path = try tmp.dir.realPathFileAlloc(io, "keep_this_dir", testing.allocator);
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Directory MUST still exist
    const stat = tmp.dir.statFile(io, "keep_this_dir", .{});
    try testing.expect(stat != error.FileNotFound);

    // Exit code must be non-zero
    try testing.expect(exit_code != 0);
}

// ============================================================
// Tests for rm on symlinks to directories (POSIX compliance)
// ============================================================

test "rm: symlink to directory removed without -r" {
    // POSIX requires `rm symlink-to-dir` to unlink the symlink itself,
    // not require -r just because the target is a directory.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a real directory
    try tmp.dir.createDir(io, "target_dir", std.Io.File.Permissions.fromMode(0o755));

    // Create a symlink pointing to the directory
    tmp.dir.symLink(io, "target_dir", "link_to_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return; // skip on platforms that disallow symlinks
        return err;
    };

    // Build absolute path to the symlink WITHOUT resolving it.
    // realPathFileAlloc would follow the symlink and return the target path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &path_buf);
    const base_path = path_buf[0..base_len];
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_to_dir", .{base_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // rm (without -r) on a symlink to a directory should succeed
    const args = [_][]const u8{link_path};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // The symlink should be gone
    const link_stat = tmp.dir.statFile(io, "link_to_dir", .{});
    try testing.expect(link_stat == error.FileNotFound);

    // The target directory should still exist
    const target_stat = try tmp.dir.statFile(io, "target_dir", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, target_stat.kind);
}

test "rm: getDeviceId returns consistent results" {
    // "/" always exists on all systems
    const dev1 = try getDeviceId(testing.io, "/");
    const dev2 = try getDeviceId(testing.io, "/");
    try testing.expectEqual(dev1, dev2);
    try testing.expect(dev1 > 0);
}
