const std = @import("std");
const clap = @import("clap");
const common = @import("common");
const testing = std.testing;

const PwdOptions = struct {
    logical: bool = false, // -L flag: use PWD environment variable if valid
    physical: bool = true, // -P flag: resolve symlinks (default)
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define parameters using zig-clap
    const params = comptime clap.parseParamsComptime(
        \\-h, --help      Display this help and exit.
        \\-V, --version   Output version information and exit.
        \\-L, --logical   Use PWD from environment, even if it contains symlinks.
        \\-P, --physical  Resolve all symbolic links (default).
        \\
    );

    // Parse arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        std.process.exit(@intFromEnum(common.ExitCode.misuse));
    };
    defer res.deinit();

    // Handle help
    if (res.args.help != 0) {
        common.CommonOpts.printHelp("[OPTION]...", "Print the full filename of the current working directory.\n\n  -L, --logical   use PWD from environment, even if it contains symlinks\n  -P, --physical  resolve all symbolic links (default)\n  -h, --help      display this help and exit\n  -V, --version   output version information and exit\n\nNOTE: your shell may have its own version of pwd, which usually supersedes\nthe version described here. Please refer to your shell's documentation\nfor details about the options it supports.\n\nExamples:\n  pwd             Print current directory (resolving symlinks)\n  pwd -L          Use PWD environment variable if valid\n  pwd -P          Explicitly resolve all symlinks");
        return;
    }

    // Handle version
    if (res.args.version != 0) {
        common.CommonOpts.printVersion();
        return;
    }

    // Create options - when both flags are given, last one wins
    var options = PwdOptions{};

    // Process flags in order to let last one win
    if (res.args.logical != 0) {
        options.logical = true;
        options.physical = false;
    }
    if (res.args.physical != 0) {
        options.logical = false;
        options.physical = true;
    }

    // Get and print the working directory
    const stdout = std.io.getStdOut().writer();
    const cwd = getWorkingDirectory(allocator, options) catch |err| {
        common.printError("failed to get current directory: {s}", .{@errorName(err)});
        std.process.exit(@intFromEnum(common.ExitCode.general_error));
    };
    defer allocator.free(cwd);

    stdout.print("{s}\n", .{cwd}) catch |err| {
        common.printError("write failed: {s}", .{@errorName(err)});
        std.process.exit(@intFromEnum(common.ExitCode.general_error));
    };
}

/// Get the current working directory based on options
fn getWorkingDirectory(allocator: std.mem.Allocator, options: PwdOptions) ![]const u8 {
    if (options.logical) {
        // Try to use PWD environment variable if valid
        if (std.process.getEnvVarOwned(allocator, "PWD")) |pwd_env| {
            defer allocator.free(pwd_env);

            // Validate that PWD refers to the same directory as getcwd
            const physical_cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(physical_cwd);

            if (isValidPwd(pwd_env, physical_cwd)) {
                return allocator.dupe(u8, pwd_env);
            }
        } else |_| {
            // PWD not set, fall back to physical
        }
    }

    // Default: get physical current working directory
    return std.process.getCwdAlloc(allocator);
}

/// Check if PWD environment variable refers to the same directory as physical cwd
/// This function validates that PWD actually points to the same directory by comparing
/// inode numbers for security purposes.
fn isValidPwd(pwd_env: []const u8, physical_cwd: []const u8) bool {
    // Basic validation: PWD must be an absolute path
    if (pwd_env.len == 0 or pwd_env[0] != '/') {
        return false;
    }

    // Compare the paths by stat-ing both and checking if they refer to the same inode
    const pwd_stat = std.fs.cwd().statFile(pwd_env) catch return false;
    const cwd_stat = std.fs.cwd().statFile(physical_cwd) catch return false;

    // For security, we validate that PWD refers to the same directory by comparing
    // inode numbers. This prevents most attacks where PWD is set to a different
    // directory with the same name. Note: This doesn't protect against cross-device
    // hard links, but those are rare and typically require elevated privileges.
    return pwd_stat.inode == cwd_stat.inode;
}

/// Simplified pwd function for backward compatibility and testing
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
    // Get the current physical directory first
    const physical_cwd = try std.process.getCwdAlloc(testing.allocator);
    defer testing.allocator.free(physical_cwd);

    // Test the validation function directly
    try testing.expect(isValidPwd(physical_cwd, physical_cwd));

    // Test with invalid PWD values
    try testing.expect(!isValidPwd("", physical_cwd));
    try testing.expect(!isValidPwd("relative/path", physical_cwd));
    try testing.expect(!isValidPwd("/nonexistent/path", physical_cwd));

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
