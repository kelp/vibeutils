//! Simple POSIX-compatible rm command.

const std = @import("std");
const common = @import("common");
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
    verbose: bool = false,
    preserve_root: bool = false,
    no_preserve_root: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .force = .{ .short = 'f', .desc = "Ignore nonexistent files and arguments, never prompt" },
        .interactive = .{ .short = 'i', .desc = "Prompt before every removal" },
        .interactive_once = .{ .short = 'I', .desc = "Prompt once before removing more than three files, or when removing recursively" },
        .recursive = .{ .short = 'r', .desc = "Remove directories and their contents recursively" },
        .R = .{ .short = 'R', .desc = "Remove directories and their contents recursively (same as -r)" },
        .verbose = .{ .short = 'v', .desc = "Explain what is being done" },
        .preserve_root = .{ .short = 0, .desc = "Do not remove '/' (default)" },
        .no_preserve_root = .{ .short = 0, .desc = "Do not treat '/' specially" },
    };
};

/// Options controlling rm behavior.
const RmOptions = struct {
    force: bool,
    interactive: bool,
    interactive_once: bool,
    recursive: bool,
    verbose: bool,
    preserve_root: bool,
};

/// Main entry point for the rm command with writer-based interface.
pub fn runRm(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parse(RmArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "invalid argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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
        common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Create options structure - merge -i/-I and -r/-R flags
    // --preserve-root is default true; --no-preserve-root disables it
    const options = RmOptions{
        .force = parsed_args.force,
        .interactive = parsed_args.interactive,
        .interactive_once = parsed_args.interactive_once,
        .recursive = parsed_args.recursive or parsed_args.R,
        .verbose = parsed_args.verbose,
        .preserve_root = !parsed_args.no_preserve_root,
    };

    const success = try removeFiles(allocator, files, stdout_writer, stderr_writer, options);
    return if (success) @intFromEnum(common.ExitCode.success) else @intFromEnum(common.ExitCode.general_error);
}

/// Main entry point for the rm command.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runRm(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Prints help information to the specified writer.
fn printHelp(allocator: Allocator, writer: anytype) !void {
    const help_text =
        \\Usage: rm [OPTION]... [FILE]...
        \\Remove (unlink) the FILE(s).
        \\
        \\  -f, --force           ignore nonexistent files and arguments, never prompt
        \\  -i                    prompt before every removal
        \\  -I                    prompt once before removing more than three files,
        \\                          or when removing recursively
        \\  -r, -R, --recursive   remove directories and their contents recursively
        \\  -v, --verbose         explain what is being done
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
fn printVersion(writer: anytype) !void {
    const build_options = @import("build_options");
    try writer.print("rm (vibeutils) {s}\n", .{build_options.version});
}

/// Simple user interaction for prompts.
fn promptUser(prompt: []const u8, stderr_writer: anytype) !bool {
    try stderr_writer.print("{s}", .{prompt});

    // Flush stderr to ensure prompt is visible before reading stdin
    const WriterType = @TypeOf(stderr_writer);
    const ActualType = if (@typeInfo(WriterType) == .pointer) std.meta.Child(WriterType) else WriterType;
    if (comptime @hasDecl(ActualType, "flush")) {
        stderr_writer.flush() catch {};
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };

    if (line.len > 0) {
        return std.ascii.toLower(line[0]) == 'y';
    }

    return false;
}

/// Main file removal function that processes a list of files/directories.
fn removeFiles(allocator: Allocator, files: []const []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmOptions) !bool {
    // Handle interactive once mode (-I flag) - but force overrides
    if (!options.force and options.interactive_once and (files.len > 3 or options.recursive)) {
        const prompt = try std.fmt.allocPrint(allocator, "rm: remove {d} arguments? ", .{files.len});
        defer allocator.free(prompt);

        if (!try promptUser(prompt, stderr_writer)) {
            return true; // User said no, but no error occurred
        }
    }

    var any_errors = false;

    for (files) |file| {
        // Check preserve-root protection before anything else
        if (options.preserve_root and isRootPath(file)) {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "refusing to remove '/'; use --no-preserve-root to override", .{});
            any_errors = true;
            continue;
        }

        // Enhanced path validation using OpenBSD-style basename checking
        if (!isPathSafeToRemove(file)) {
            if (file.len == 0) {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '': No such file or directory", .{});
            } else if (std.mem.eql(u8, file, "/")) {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "it is dangerous to operate recursively on '/'", .{});
            } else {
                // Must be a "." or ".." pattern (including complex paths like "/path/to/.")
                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "\".\" and \"..\" may not be removed", .{});
            }
            any_errors = true;
            continue;
        }

        // Try to remove the file/directory
        removeItem(allocator, file, stdout_writer, stderr_writer, options) catch |err| switch (err) {
            error.FileNotFound => {
                if (!options.force) {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': No such file or directory", .{file});
                    any_errors = true;
                }
            },
            error.AccessDenied => {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': Permission denied", .{file});
                any_errors = true;
            },
            error.IsDir => {
                if (options.recursive) {
                    removeDirectory(allocator, file, stdout_writer, stderr_writer, options) catch |dir_err| {
                        switch (dir_err) {
                            error.InteractiveUserCancelled => {}, // User said no in interactive mode, continue
                            else => {
                                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': {s}", .{ file, @errorName(dir_err) });
                                any_errors = true;
                            },
                        }
                    };
                } else {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': Is a directory", .{file});
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
                common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': {s}", .{ file, @errorName(err) });
                any_errors = true;
            },
        };
    }

    return !any_errors;
}

/// Remove a single file or symlink.
fn removeItem(allocator: Allocator, file_path: []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmOptions) !void {
    // Get file info to check if we need to prompt
    const stat_result = std.fs.cwd().statFile(file_path) catch |err| switch (err) {
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
        const prompt = try std.fmt.allocPrint(allocator, "rm: remove regular file '{s}'? ", .{file_path});
        defer allocator.free(prompt);

        if (!try promptUser(prompt, stderr_writer)) {
            return error.InteractiveUserCancelled;
        }
    } else {
        // Default mode: prompt only for write-protected files
        const mode = stat_result.mode;
        const user_write = (mode & 0o200) != 0;
        if (!user_write) {
            const prompt = try std.fmt.allocPrint(allocator, "rm: remove write-protected regular file '{s}'? ", .{file_path});
            defer allocator.free(prompt);

            if (!try promptUser(prompt, stderr_writer)) {
                return error.UserCancelled;
            }
        }
    }

    // Remove the file
    std.fs.cwd().deleteFile(file_path) catch |err| switch (err) {
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
    kind: std.fs.Dir.Entry.Kind,
};

/// Remove a directory recursively with per-entry verbose/interactive support.
fn removeDirectory(allocator: Allocator, dir_path: []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmOptions) !void {
    // For non-verbose, non-interactive mode with force, use deleteTree as fast path
    if (!options.verbose and !options.interactive and options.force) {
        std.fs.cwd().deleteTree(dir_path) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            else => return err,
        };
        return;
    }

    // Manual depth-first recursive traversal
    try removeDirectoryRecursive(allocator, dir_path, stdout_writer, stderr_writer, options);
}

/// Depth-first recursive directory removal with per-entry verbose/interactive support.
fn removeDirectoryRecursive(allocator: Allocator, dir_path: []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmOptions) anyerror!void {
    // Open directory for iteration
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };

    var had_errors = false;

    // Collect entries first to avoid iterator invalidation during deletion
    var entries = std.ArrayListUnmanaged(Entry){};
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    {
        var iterator = dir.iterate();
        while (iterator.next() catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot read directory '{s}': {s}", .{ dir_path, @errorName(err) });
            dir.close();
            return err;
        }) |entry| {
            const name_copy = try allocator.dupe(u8, entry.name);
            try entries.append(allocator, .{ .name = name_copy, .kind = entry.kind });
        }
    }

    // Close directory handle before modifying contents
    dir.close();

    // Process entries depth-first
    for (entries.items) |entry| {
        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot construct path: {s}", .{@errorName(err)});
            had_errors = true;
            continue;
        };
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            // Recurse into subdirectory first (depth-first)
            if (removeDirectoryRecursive(allocator, full_path, stdout_writer, stderr_writer, options)) {
                // Success - continue
            } else |err| switch (err) {
                error.InteractiveUserCancelled => {},
                else => had_errors = true,
            }
        } else {
            // Remove file entry with interactive/verbose support
            removeItem(allocator, full_path, stdout_writer, stderr_writer, options) catch |err| switch (err) {
                error.InteractiveUserCancelled => continue,
                error.UserCancelled => {
                    had_errors = true;
                    continue;
                },
                error.FileNotFound => {
                    if (!options.force) {
                        common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': No such file or directory", .{full_path});
                        had_errors = true;
                    }
                    continue;
                },
                error.AccessDenied => {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': Permission denied", .{full_path});
                    had_errors = true;
                    continue;
                },
                else => {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': {s}", .{ full_path, @errorName(err) });
                    had_errors = true;
                    continue;
                },
            };
        }
    }

    // Now remove the (should-be-empty) directory itself
    // Prompt if interactive
    if (!options.force and options.interactive) {
        const prompt = try std.fmt.allocPrint(allocator, "rm: remove directory '{s}'? ", .{dir_path});
        defer allocator.free(prompt);

        if (!try promptUser(prompt, stderr_writer)) {
            return error.InteractiveUserCancelled;
        }
    }

    std.fs.cwd().deleteDir(dir_path) catch |err| switch (err) {
        error.DirNotEmpty => {
            // Some entries may have been skipped (interactive cancel, errors)
            common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': Directory not empty", .{dir_path});
            had_errors = true;
        },
        error.AccessDenied => {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': Permission denied", .{dir_path});
            had_errors = true;
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", std.fs.File.stderr().isTty(), "cannot remove '{s}': {s}", .{ dir_path, @errorName(err) });
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
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test with non-existent file and force mode
    const args = [_][]const u8{ "-f", "definitely_nonexistent_file_12345.txt" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should succeed (exit code 0) with -f flag for non-existent file
    try testing.expect(exit_code == 0);
}

test "rm: root directory protection" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test removing root directory
    const args = [_][]const u8{ "-rf", "/" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should fail (non-zero exit code)
    try testing.expect(exit_code != 0);
    // Should have preserve-root error message
    try testing.expect(stderr_buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "refusing to remove '/'") != null);
}

test "rm: empty path handling" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test empty path
    const args = [_][]const u8{""};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should fail with error
    try testing.expect(exit_code != 0);
    try testing.expect(stderr_buffer.items.len > 0);
}

test "rm: missing operand" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test with no arguments
    const args = [_][]const u8{};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should fail with missing operand error
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "rm: help flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test help flag
    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should succeed and show help
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage:") != null);
}

test "rm: version flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test version flag
    const args = [_][]const u8{"--version"};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should succeed and show version
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "vibeutils") != null);
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a directory tree
    try tmp.dir.makeDir("testdir");
    var subdir = try tmp.dir.openDir("testdir", .{});
    const file1 = try subdir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try subdir.createFile("file2.txt", .{});
    file2.close();
    subdir.close();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, "testdir");
    defer testing.allocator.free(dir_path);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(testing.allocator, &[_][]const u8{dir_path}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator), options);

    try testing.expect(success);
    // Verbose output should mention individual files
    const output = stdout_buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "removed '") != null or std.mem.indexOf(u8, output, "removed directory '") != null);
}

test "rm: recursive removal with nested directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create nested directory tree
    try tmp.dir.makePath("deep/nested/dir");
    var deep_dir = try tmp.dir.openDir("deep/nested/dir", .{});
    const file = try deep_dir.createFile("leaf.txt", .{});
    file.close();
    deep_dir.close();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, "deep");
    defer testing.allocator.free(dir_path);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(testing.allocator, &[_][]const u8{dir_path}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator), options);

    try testing.expect(success);

    // Verify directory is gone
    const stat = std.fs.cwd().statFile(dir_path);
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
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test removing "///" which normalizes to "/"
    const args = [_][]const u8{ "-rf", "///" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should fail with preserve-root error
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "refusing to remove '/'") != null);
}

test "rm: no-preserve-root flag is parsed" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test that --no-preserve-root is recognized as a valid flag
    // Use a non-existent file with -f to avoid actual filesystem operations
    const args = [_][]const u8{ "--no-preserve-root", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should succeed (exit code 0) because -f ignores nonexistent files
    // This proves the flag is recognized and doesn't cause a parse error
    try testing.expect(exit_code == 0);
}

test "rm: non-root path does not trigger preserve-root" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test that /tmp/nonexistent does NOT trigger preserve-root
    const args = [_][]const u8{ "-f", "/tmp/nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should succeed (-f ignores nonexistent) and NOT show preserve-root error
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "refusing to remove '/'") == null);
}

test "rm: preserve-root flag is accepted" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test that --preserve-root is recognized (it's the default, but should be accepted)
    const args = [_][]const u8{ "--preserve-root", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should succeed since -f ignores nonexistent files
    try testing.expect(exit_code == 0);
}

test "rm: help text includes preserve-root flags" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--preserve-root") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--no-preserve-root") != null);
}
