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
    };
};

/// Options controlling rm behavior.
const RmOptions = struct {
    force: bool,
    interactive: bool,
    interactive_once: bool,
    recursive: bool,
    verbose: bool,
};

/// Main entry point for the rm command with writer-based interface.
pub fn runRm(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parse(RmArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help flag
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const files = parsed_args.positionals;
    if (files.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "rm", "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Create options structure - merge -i/-I and -r/-R flags
    const options = RmOptions{
        .force = parsed_args.force,
        .interactive = parsed_args.interactive,
        .interactive_once = parsed_args.interactive_once,
        .recursive = parsed_args.recursive or parsed_args.R,
        .verbose = parsed_args.verbose,
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

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runRm(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Prints help information to the specified writer.
fn printHelp(writer: anytype) !void {
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
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\By default, rm does not remove directories. Use the --recursive (-r or -R)
        \\option to remove each listed directory, too, along with all of its contents.
        \\
    ;
    try writer.print("{s}", .{help_text});
}

/// Prints version information to the specified writer.
fn printVersion(writer: anytype) !void {
    const build_options = @import("build_options");
    try writer.print("rm (vibeutils) {s}\n", .{build_options.version});
}

/// Simple user interaction for prompts.
fn promptUser(prompt: []const u8, stderr_writer: anytype) !bool {
    try stderr_writer.print("{s}", .{prompt});

    var buffer: [10]u8 = undefined;
    const stdin = std.io.getStdIn().reader();

    if (stdin.readUntilDelimiterOrEof(&buffer, '\n')) |maybe_line| {
        if (maybe_line) |line| {
            if (line.len > 0) {
                return std.ascii.toLower(line[0]) == 'y';
            }
        }
    } else |_| {
        return false; // Default to no on error
    }

    return false;
}

/// Main file removal function that processes a list of files/directories.
fn removeFiles(allocator: Allocator, files: []const []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmOptions) !bool {
    // Handle interactive once mode (-I flag)
    if (options.interactive_once and files.len > 3) {
        const prompt = try std.fmt.allocPrint(allocator, "rm: remove {d} arguments? ", .{files.len});
        defer allocator.free(prompt);

        if (!try promptUser(prompt, stderr_writer)) {
            return true; // User said no, but no error occurred
        }
    }

    var any_errors = false;

    for (files) |file| {
        // Basic safety checks
        if (file.len == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '': No such file or directory", .{});
            any_errors = true;
            continue;
        }

        // Minimal root directory protection
        if (std.mem.eql(u8, file, "/")) {
            common.printErrorWithProgram(allocator, stderr_writer, "rm", "it is dangerous to operate recursively on '/'", .{});
            any_errors = true;
            continue;
        }

        // Try to remove the file/directory
        removeItem(allocator, file, stdout_writer, stderr_writer, options) catch |err| switch (err) {
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
                    removeDirectory(allocator, file, stdout_writer, stderr_writer, options) catch |dir_err| {
                        switch (dir_err) {
                            error.UserCancelled => {}, // User said no, continue
                            else => {
                                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ file, @errorName(dir_err) });
                                any_errors = true;
                            },
                        }
                    };
                } else {
                    common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': Is a directory", .{file});
                    any_errors = true;
                }
            },
            error.UserCancelled => {}, // User said no, continue
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, "rm", "cannot remove '{s}': {s}", .{ file, @errorName(err) });
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

    // Handle interactive prompts
    if (options.interactive) {
        const prompt = try std.fmt.allocPrint(allocator, "rm: remove regular file '{s}'? ", .{file_path});
        defer allocator.free(prompt);

        if (!try promptUser(prompt, stderr_writer)) {
            return error.UserCancelled;
        }
    } else if (!options.force) {
        // Check if file is write-protected
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

/// Remove a directory recursively.
fn removeDirectory(allocator: Allocator, dir_path: []const u8, stdout_writer: anytype, stderr_writer: anytype, options: RmOptions) !void {
    // Handle interactive prompts for directories
    if (options.interactive) {
        const prompt = try std.fmt.allocPrint(allocator, "rm: remove directory '{s}'? ", .{dir_path});
        defer allocator.free(prompt);

        if (!try promptUser(prompt, stderr_writer)) {
            return error.UserCancelled;
        }
    }

    // Simply use std.fs.cwd().deleteTree() - it handles everything
    std.fs.cwd().deleteTree(dir_path) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };

    // Print verbose output
    if (options.verbose) {
        try stdout_writer.print("removed directory '{s}'\n", .{dir_path});
    }
}

// Tests

test "rm: basic functionality test" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test with non-existent file and force mode
    const args = [_][]const u8{ "-f", "definitely_nonexistent_file_12345.txt" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should succeed (exit code 0) with -f flag for non-existent file
    try testing.expect(exit_code == 0);
}

test "rm: root directory protection" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test removing root directory
    const args = [_][]const u8{ "-rf", "/" };
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should fail (non-zero exit code)
    try testing.expect(exit_code != 0);
    // Should have error message
    try testing.expect(stderr_buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "dangerous") != null);
}

test "rm: empty path handling" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test empty path
    const args = [_][]const u8{""};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should fail with error
    try testing.expect(exit_code != 0);
    try testing.expect(stderr_buffer.items.len > 0);
}

test "rm: missing operand" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test with no arguments
    const args = [_][]const u8{};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should fail with missing operand error
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "rm: help flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test help flag
    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should succeed and show help
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage:") != null);
}

test "rm: version flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test version flag
    const args = [_][]const u8{"--version"};
    const exit_code = try runRm(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should succeed and show version
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "vibeutils") != null);
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("rm");

test "rm fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testRmIntelligentWrapper, .{});
}

fn testRmIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    const RmIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(RmArgs, runRm);
    try RmIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
