//! Print current working directory with logical and physical path resolution

const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
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
        .logical = .{
            .short = 'L',
            .desc = "Use PWD from environment, even if it contains symlinks (default)",
        },
        .physical = .{ .short = 'P', .desc = "Resolve all symbolic links" },
    };
};

/// Main entry point for pwd utility
pub fn runPwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const parsed_args = common.argparse.ArgParser.parse(PwdArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "pwd",
                    "unrecognized option",
                    .{},
                );
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.MissingValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "pwd",
                    "option requires an argument",
                    .{},
                );
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "pwd",
                    "invalid option value",
                    .{},
                );
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try stdout_writer.print("pwd ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    const cwd = getWorkingDirectory(allocator, io, parsed_args) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "pwd",
            "failed to get current directory: {s}",
            .{common.posixErrorString(err)},
        );
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(cwd);

    try stdout_writer.print("{s}\n", .{cwd});
    return @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runPwd);
}

/// Print help message to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: pwd [OPTION]...
        \\Print the full filename of the current working directory.
        \\
        \\  -L, --logical   use PWD from environment, even if it contains symlinks
        \\  -P, --physical  resolve all symbolic links
        \\  -h, --help      display this help and exit
        \\  -V, --version   output version information and exit
        \\
        \\NOTE: your shell may have its own version of pwd, which usually supersedes
        \\the version described here. Please refer to your shell's documentation
        \\for details about the options it supports.
        \\
        \\Examples:
        \\  pwd             Print current directory (honoring $PWD when valid)
        \\  pwd -P          Explicitly resolve all symlinks
        \\
    );
}

/// Get current working directory string. Returns an allocated []u8 (no sentinel).
fn getCwdAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    std.debug.assert(n <= buf.len);
    std.debug.assert(n >= 1);
    return allocator.dupe(u8, buf[0..n]);
}

/// Get current working directory according to command line arguments
/// Logical is the default per POSIX (pwd behaves as if -L were given when
/// neither option is specified). -P forces physical resolution and wins
/// when both flags are present.
pub fn getWorkingDirectory(allocator: std.mem.Allocator, io: std.Io, args: PwdArgs) ![]const u8 {
    const use_logical = !args.physical;

    if (use_logical) {
        // Try to use PWD environment variable in logical mode
        const pwd_env = common.env.getEnv("PWD") orelse {
            // PWD not set, fall back to physical mode
            return getCwdAlloc(allocator, io);
        };

        // Get physical path for validation
        const physical_cwd = getCwdAlloc(allocator, io) catch {
            // Can't get physical path, use PWD as-is (rare edge case)
            return allocator.dupe(u8, pwd_env);
        };
        defer allocator.free(physical_cwd);

        // Validate PWD refers to current directory
        if (isValidPwd(io, pwd_env, physical_cwd)) {
            return allocator.dupe(u8, pwd_env);
        }
        // PWD invalid, fall back to physical path we already have
        return allocator.dupe(u8, physical_cwd);
    }

    // Physical mode (default): resolve all symlinks
    return getCwdAlloc(allocator, io);
}

/// Validate PWD environment variable refers to current directory
///
/// This function fails closed on errors - if any filesystem operation fails,
/// the PWD is considered invalid for security reasons.
fn isValidPwd(io: std.Io, pwd_env: []const u8, physical_cwd: []const u8) bool {
    // PWD must be an absolute path (start with '/')
    if (pwd_env.len == 0 or pwd_env[0] != '/') {
        return false;
    }
    std.debug.assert(pwd_env.len > 0);
    std.debug.assert(pwd_env[0] == '/');

    const pwd_info = common.file.FileInfo.stat(io, pwd_env) catch return false;
    const cwd_info = common.file.FileInfo.stat(io, physical_cwd) catch return false;

    if (pwd_info.kind != .directory) {
        return false;
    }
    std.debug.assert(pwd_info.kind == .directory);

    return samePathByInodeAndDev(pwd_info, cwd_info);
}

/// Return true if two FileInfo records point at the same filesystem object,
/// using BOTH inode and device ID. Inode numbers are only unique within a
/// single filesystem, so a stale `$PWD` on another mount can have a colliding
/// inode with the real cwd. Comparing (inode, dev) is the standard way to
/// detect "same file" across mounts (see coreutils sys-stat.h SAME_INODE).
pub fn samePathByInodeAndDev(a: common.file.FileInfo, b: common.file.FileInfo) bool {
    return a.inode == b.inode and a.dev == b.dev;
}

// ============================================================================
// TESTS
// ============================================================================

test "getWorkingDirectory physical mode" {
    const io = testing.io;
    const args = PwdArgs{ .physical = true, .logical = false };
    const cwd = try getWorkingDirectory(testing.allocator, io, args);
    defer testing.allocator.free(cwd);

    // Should return an absolute path
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "getWorkingDirectory logical mode without PWD" {
    // When PWD is not set, logical mode should fall back to physical
    const io = testing.io;
    const args = PwdArgs{ .logical = true, .physical = false };

    const cwd = try getWorkingDirectory(testing.allocator, io, args);
    defer testing.allocator.free(cwd);

    // Should return an absolute path even without PWD
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "getWorkingDirectory logical mode with valid PWD" {
    const io = testing.io;
    // Create a temp directory to avoid accessing protected locations
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Get the temp directory path
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temp_len = try tmp_dir.realPathFile(".", &path_buf);
    const temp_path = path_buf[0..temp_len];

    // Test the validation function directly
    try testing.expect(isValidPwd(io, temp_path, temp_path));

    // Test with invalid PWD values
    try testing.expect(!isValidPwd(io, "", temp_path));
    try testing.expect(!isValidPwd(io, "relative/path", temp_path));
    try testing.expect(!isValidPwd(io, "/nonexistent/path", temp_path));

    // Test logical mode fallback when PWD is not set
    const args = PwdArgs{ .logical = true, .physical = false };
    const cwd = try getWorkingDirectory(testing.allocator, io, args);
    defer testing.allocator.free(cwd);

    // Should return an absolute path
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "samePathByInodeAndDev compares inode AND device for same path" {
    // Audit G2 regression: PWD validation must compare BOTH inode and device,
    // not inode alone. Two different filesystems can share inode numbers, so
    // a stale $PWD pointing at another mount can pass an inode-only check.
    //
    // Method: stat the same path twice — both records must compare equal
    // across (inode, dev). A stub that ignores dev (or returns a constant)
    // will fail this assertion.
    const io = testing.io;
    const a = try common.file.FileInfo.stat(io, ".");
    const b = try common.file.FileInfo.stat(io, ".");
    try testing.expect(samePathByInodeAndDev(a, b));

    // Negative space: a record with a deliberately altered dev must compare
    // unequal even when the inode matches. This catches an inode-only impl
    // that ignores the dev field entirely.
    var b_other_dev = b;
    b_other_dev.dev = a.dev +% 1;
    try testing.expect(!samePathByInodeAndDev(a, b_other_dev));
}

test "isValidPwd security validation" {
    const io = testing.io;
    // Get the current directory for testing
    const current_dir = try getCwdAlloc(testing.allocator, io);
    defer testing.allocator.free(current_dir);

    // Valid: same directory should validate
    try testing.expect(isValidPwd(io, current_dir, current_dir));

    // Invalid: empty or relative paths
    try testing.expect(!isValidPwd(io, "", current_dir));
    try testing.expect(!isValidPwd(io, "relative/path", current_dir));

    // Invalid: absolute path that doesn't exist
    try testing.expect(!isValidPwd(io, "/nonexistent/directory", current_dir));
}

test "PwdArgs defaults" {
    const args = PwdArgs{};
    try testing.expect(!args.logical);
    try testing.expect(!args.physical);
    try testing.expect(!args.help);
    try testing.expect(!args.version);
}

test "runPwd with help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print help to stdout
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: pwd") != null);

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runPwd with version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should return success exit code
    try testing.expectEqual(@as(u8, 0), result);

    // Should print version to stdout
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "pwd") != null);

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runPwd with short help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: pwd") != null);
}

test "runPwd with short version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "pwd") != null);
}

test "runPwd with no arguments" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);

    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(out[0] == '/');
    try testing.expect(out[out.len - 1] == '\n');

    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runPwd with -L flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-L"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);

    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(out[0] == '/');
    try testing.expect(out[out.len - 1] == '\n');

    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runPwd with -P flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-P"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);

    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(out[0] == '/');
    try testing.expect(out[out.len - 1] == '\n');

    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runPwd with invalid flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runPwd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());

    const err_out = stderr_aw.writer.buffered();
    try testing.expect(err_out.len > 0);
    try testing.expect(std.mem.find(u8, err_out, "pwd:") != null);
    try testing.expect(std.mem.find(u8, err_out, "unrecognized option") != null);
}
