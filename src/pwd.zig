//! Print current working directory with logical and physical path resolution

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Command-line arguments for pwd utility
const PwdArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Display version and exit
    version: bool = false,
    /// Use PWD from environment
    logical: bool = false,
    /// Resolve all symbolic links
    physical: bool = false,
    /// Positional arguments
    positionals: []const []const u8 = &.{},

    /// Argument parser metadata
    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .logical = .{ .short = 'L', .desc = "Use PWD from environment, even if it contains symlinks" },
        .physical = .{ .short = 'P', .desc = "Resolve all symbolic links (default)" },
    };
};

/// Runtime options for pwd behavior
const PwdOptions = struct {
    /// Use PWD environment variable if valid
    logical: bool = false,
    /// Resolve all symbolic links
    physical: bool = true,
};

/// Main entry point for pwd utility
pub fn runPwd(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parse(PwdArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "pwd", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help flag - display usage information and exit
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag - display version and exit
    if (parsed_args.version) {
        try stdout_writer.print("pwd ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    // Process command line flags to determine operation mode
    const options = processModeFlags(parsed_args);

    // Retrieve the current working directory based on the selected mode
    const cwd = getWorkingDirectory(allocator, options) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "pwd", "failed to get current directory: {s}", .{@errorName(err)});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(cwd);

    // Print the directory path followed by a newline
    try stdout_writer.print("{s}\n", .{cwd});
    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for pwd utility
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runPwd(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Process command line flags and return appropriate options
/// When both -L and -P are given, the last one wins (POSIX behavior)
fn processModeFlags(parsed_args: PwdArgs) PwdOptions {
    var options = PwdOptions{};

    // Process mode flags - when both -L and -P are given, the last one wins
    // This behavior matches POSIX specifications
    if (parsed_args.logical) {
        options.logical = true;
        options.physical = false;
    }
    if (parsed_args.physical) {
        options.logical = false;
        options.physical = true;
    }

    return options;
}

/// Print help message to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: pwd [OPTION]...
        \\Print the full filename of the current working directory.
        \\
        \\  -L, --logical   use PWD from environment, even if it contains symlinks
        \\  -P, --physical  resolve all symbolic links (default)
        \\  -h, --help      display this help and exit
        \\  -V, --version   output version information and exit
        \\
        \\NOTE: your shell may have its own version of pwd, which usually supersedes
        \\the version described here. Please refer to your shell's documentation
        \\for details about the options it supports.
        \\
        \\Examples:
        \\  pwd             Print current directory (resolving symlinks)
        \\  pwd -L          Use PWD environment variable if valid
        \\  pwd -P          Explicitly resolve all symlinks
        \\
    );
}

/// Get current working directory according to options
pub fn getWorkingDirectory(allocator: std.mem.Allocator, options: PwdOptions) ![]const u8 {
    if (options.logical) {
        // Attempt to use PWD environment variable in logical mode
        if (std.process.getEnvVarOwned(allocator, "PWD")) |pwd_env| {
            defer allocator.free(pwd_env);

            // Get the physical path for validation
            const physical_cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(physical_cwd);

            // Validate that PWD actually refers to the current directory
            if (isValidPwd(pwd_env, physical_cwd)) {
                return allocator.dupe(u8, pwd_env);
            }
            // PWD is invalid, fall through to physical mode
        } else |_| {
            // PWD environment variable not set, fall through to physical mode
        }
    }

    // Physical mode or fallback: get the actual current directory with symlinks resolved
    return std.process.getCwdAlloc(allocator);
}

/// Validate PWD environment variable refers to current directory
///
/// This function fails closed on errors - if any filesystem operation fails,
/// the PWD is considered invalid for security reasons. This prevents accepting
/// a potentially malicious PWD when we cannot verify its correctness.
///
/// Returns false if:
/// - PWD is empty or not an absolute path
/// - stat() fails on either PWD or physical_cwd (filesystem errors, permissions, etc.)
/// - The inodes don't match (different directories)
fn isValidPwd(pwd_env: []const u8, physical_cwd: []const u8) bool {
    // PWD must be an absolute path (start with '/')
    if (pwd_env.len == 0 or pwd_env[0] != '/') {
        return false;
    }

    // Get file statistics for both paths
    // Fail closed: any error in stat operations invalidates PWD
    const pwd_stat = std.fs.cwd().statFile(pwd_env) catch return false;
    const cwd_stat = std.fs.cwd().statFile(physical_cwd) catch return false;

    // Validate by comparing inode numbers - if they match, both paths
    // refer to the same directory
    return pwd_stat.inode == cwd_stat.inode;
}

/// Simple pwd function for testing and backward compatibility
pub fn pwd(allocator: std.mem.Allocator, writer: anytype) !void {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    try writer.print("{s}\n", .{cwd});
}

// ============================================================================
// TESTS
// ============================================================================

test "pwd basic functionality" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try pwd(testing.allocator, buffer.writer());

    // Should have printed something ending with newline
    try testing.expect(buffer.items.len > 1);
    try testing.expect(buffer.items[buffer.items.len - 1] == '\n');

    // Should start with / (absolute path)
    try testing.expect(buffer.items[0] == '/');
}

test "getWorkingDirectory physical mode" {
    const options = PwdOptions{ .physical = true, .logical = false };
    const cwd = try getWorkingDirectory(testing.allocator, options);
    defer testing.allocator.free(cwd);

    // Should return an absolute path
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "getWorkingDirectory logical mode without PWD" {
    // When PWD is not set, logical mode should fall back to physical
    const options = PwdOptions{ .logical = true, .physical = false };

    const cwd = try getWorkingDirectory(testing.allocator, options);
    defer testing.allocator.free(cwd);

    // Should return an absolute path even without PWD
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "getWorkingDirectory logical mode with valid PWD" {
    // Create a temp directory to avoid accessing protected locations
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get the temp directory path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try tmp_dir.dir.realpath(".", &path_buf);

    // Test the validation function directly
    try testing.expect(isValidPwd(temp_path, temp_path));

    // Test with invalid PWD values
    try testing.expect(!isValidPwd("", temp_path));
    try testing.expect(!isValidPwd("relative/path", temp_path));
    try testing.expect(!isValidPwd("/nonexistent/path", temp_path));

    // Test logical mode fallback when PWD is not set
    const options = PwdOptions{ .logical = true, .physical = false };
    const cwd = try getWorkingDirectory(testing.allocator, options);
    defer testing.allocator.free(cwd);

    // Should return an absolute path
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "isValidPwd security validation" {
    // Get the current directory for testing
    const current_dir = try std.process.getCwdAlloc(testing.allocator);
    defer testing.allocator.free(current_dir);

    // Valid: same directory should validate
    try testing.expect(isValidPwd(current_dir, current_dir));

    // Invalid: empty or relative paths
    try testing.expect(!isValidPwd("", current_dir));
    try testing.expect(!isValidPwd("relative/path", current_dir));

    // Invalid: absolute path that doesn't exist
    try testing.expect(!isValidPwd("/nonexistent/directory", current_dir));
}

test "PwdOptions defaults" {
    const opts = PwdOptions{};
    try testing.expect(!opts.logical);
    try testing.expect(opts.physical);
}

test "pwd output format" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try pwd(testing.allocator, buffer.writer());
    const output = buffer.items;

    // Should end with exactly one newline
    try testing.expect(output[output.len - 1] == '\n');

    // Should not have any other newlines
    var newline_count: usize = 0;
    for (output) |c| {
        if (c == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), newline_count);
}

test "runPwd with help flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print help to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: pwd") != null);

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "runPwd with version flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print version to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "pwd") != null);

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "runPwd with short help flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print help to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: pwd") != null);
}

test "runPwd with short version flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print version to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "pwd") != null);
}

test "runPwd with no arguments" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print current directory to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(stdout_buffer.items[0] == '/'); // Should be absolute path
    try testing.expect(stdout_buffer.items[stdout_buffer.items.len - 1] == '\n'); // Should end with newline

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "runPwd with -L flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"-L"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print current directory to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(stdout_buffer.items[0] == '/'); // Should be absolute path
    try testing.expect(stdout_buffer.items[stdout_buffer.items.len - 1] == '\n'); // Should end with newline

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "runPwd with -P flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"-P"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print current directory to stdout
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(stdout_buffer.items[0] == '/'); // Should be absolute path
    try testing.expect(stdout_buffer.items[stdout_buffer.items.len - 1] == '\n'); // Should end with newline

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "runPwd with invalid flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runPwd(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

    // Should return error exit code
    try testing.expectEqual(@as(u8, 1), result);

    // Should not print anything to stdout
    try testing.expectEqualStrings("", stdout_buffer.items);

    // Should print error to stderr
    try testing.expect(stderr_buffer.items.len > 0);
    // Check for program name and error message separately to handle ANSI color codes
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "pwd:") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid argument") != null);
}
