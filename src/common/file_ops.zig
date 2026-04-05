const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");

/// Set file permissions using the most reliable method available
///
/// On macOS in CI environments, File.chmod() can cause SIGABRT errors under fakeroot.
/// On Linux under fakeroot, setting special permissions (setuid, setgid, sticky) can hang.
/// This function uses std.posix.fchmod() directly on the file descriptor and handles
/// platform-specific limitations gracefully.
///
/// # Why posix.fchmod instead of File.chmod?
/// File.chmod() can fail with EFAULT on macOS in certain environments (like GitHub Actions
/// CI with fakeroot). Using std.posix.fchmod() directly on the file descriptor avoids
/// this issue and provides more consistent behavior across platforms.
///
/// # Parameters
/// - handle: Either a std.fs.File or std.fs.Dir
/// - mode: The file mode (permissions) to set
/// - context: Optional context for error reporting (e.g., file path)
/// - program_name: Name of the calling program for error messages
/// - stderr_writer: Writer for warning messages
///
/// # Returns
/// Returns success (0) if the operation succeeds, or general_error (1) if it fails
/// after issuing warnings for platform-specific limitations.
pub fn setPermissions(allocator: std.mem.Allocator, handle: anytype, mode: std.fs.File.Mode, context: ?[]const u8, program_name: []const u8, stderr_writer: anytype) !u8 {
    const handle_type = @TypeOf(handle);

    // Get the file descriptor based on handle type
    const fd = if (handle_type == std.fs.File)
        handle.handle
    else if (handle_type == std.fs.Dir)
        handle.fd
    else
        @compileError("setPermissions expects std.fs.File or std.fs.Dir");

    // Check for special permissions (setuid, setgid, sticky bit)
    const has_special_bits = (mode & 0o7000) != 0;

    // On Linux under fakeroot, setting special permissions can cause hangs
    // Strip special bits and warn the user
    const effective_mode = if (isRunningUnderLinuxFakeroot() and has_special_bits) blk: {
        if (context) |ctx| {
            lib.printWarningWithProgram(allocator, stderr_writer, program_name, "Stripped special permissions on {s} (Linux fakeroot limitation)", .{ctx});
        } else {
            lib.printWarningWithProgram(allocator, stderr_writer, program_name, "Stripped special permissions (Linux fakeroot limitation)", .{});
        }
        break :blk mode & 0o0777; // Keep only regular permissions
    } else mode;

    std.posix.fchmod(fd, effective_mode) catch |err| {
        // On macOS, especially in CI environments with fakeroot, permission
        // operations may fail. We report this as a warning but don't fail
        // the operation since the file operation itself succeeded.
        if (builtin.os.tag == .macos) {
            if (context) |ctx| {
                lib.printWarningWithProgram(allocator, stderr_writer, program_name, "Failed to set permissions on {s} (macOS limitation): {s}", .{ ctx, lib.posixErrorString(err) });
            } else {
                lib.printWarningWithProgram(allocator, stderr_writer, program_name, "Failed to set permissions on macOS: {s}", .{lib.posixErrorString(err)});
            }
            return @intFromEnum(lib.ExitCode.success);
        }
        return @intFromEnum(lib.ExitCode.general_error);
    };

    return @intFromEnum(lib.ExitCode.success);
}

/// Check if running in a CI environment
///
/// Detects common CI environment variables to determine if the code is
/// running in a continuous integration system.
///
/// # Returns
/// true if running in a CI environment, false otherwise
pub fn isRunningInCI() bool {
    // Common CI environment variables to check
    const ci_vars = [_][]const u8{
        "CI", // Generic CI variable used by many systems
        "GITHUB_ACTIONS", // GitHub Actions
        "TRAVIS", // Travis CI
        "CIRCLECI", // CircleCI
        "JENKINS_URL", // Jenkins
        "GITLAB_CI", // GitLab CI
        "BUILDKITE", // Buildkite
    };

    for (ci_vars) |var_name| {
        if (std.posix.getenv(var_name)) |_| {
            return true;
        }
    }

    return false;
}

/// Check if running under fakeroot on Linux
///
/// Fakeroot sets the FAKEROOTKEY environment variable when active.
/// This is used to detect when special permission operations might hang.
///
/// # Returns
/// true if running under fakeroot on Linux, false otherwise
pub fn isRunningUnderLinuxFakeroot() bool {
    if (builtin.os.tag != .linux) return false;

    return std.posix.getenv("FAKEROOTKEY") != null;
}

/// Check if should skip privileged tests on macOS CI
///
/// Some privileged operations can cause SIGABRT on macOS in CI environments
/// when running under fakeroot. This function determines if we should skip
/// such tests.
///
/// # Returns
/// true if running on macOS in a CI environment, false otherwise
pub fn shouldSkipMacOSCITest() bool {
    return builtin.os.tag == .macos and isRunningInCI();
}

/// Check if two paths refer to the same file (compares both inode and device).
///
/// Opens both paths and compares their fstat results. Returns false
/// if either file cannot be opened or stat'd.
pub fn isSameFile(source: []const u8, dest: []const u8) bool {
    const source_file = std.fs.cwd().openFile(source, .{}) catch return false;
    defer source_file.close();
    const dest_file = std.fs.cwd().openFile(dest, .{}) catch return false;
    defer dest_file.close();
    const source_stat = std.posix.fstat(source_file.handle) catch return false;
    const dest_stat = std.posix.fstat(dest_file.handle) catch return false;
    return source_stat.ino == dest_stat.ino and source_stat.dev == dest_stat.dev;
}

/// Named constant for the copy buffer size (64 KB).
pub const COPY_BUFFER_SIZE = 64 * 1024;

/// Copy the contents of one open file to another using a fixed-size buffer.
///
/// Reads from source_file and writes to dest_file until EOF. Returns
/// an error if any read or write fails.
pub fn copyFileContents(source_file: std.fs.File, dest_file: std.fs.File) !void {
    var buffer: [COPY_BUFFER_SIZE]u8 = undefined;
    while (true) {
        const bytes_read = try source_file.read(&buffer);
        if (bytes_read == 0) break;
        try dest_file.writeAll(buffer[0..bytes_read]);
    }
}

test "isSameFile" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    file.close();

    // Same file via same path should match
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const path1 = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "test.txt" });
    defer std.testing.allocator.free(path1);

    try std.testing.expect(isSameFile(path1, path1));

    // Different files should not match
    const file2 = try tmp_dir.dir.createFile("other.txt", .{});
    file2.close();
    const path2 = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "other.txt" });
    defer std.testing.allocator.free(path2);
    try std.testing.expect(!isSameFile(path1, path2));

    // Non-existent file should return false
    try std.testing.expect(!isSameFile(path1, "/nonexistent_file_abc123"));
}

test "setPermissions with file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    defer file.close();

    // This should work on all platforms
    const result = try setPermissions(std.testing.allocator, file, 0o644, "test.txt", "test", lib.null_writer);
    try std.testing.expectEqual(@as(u8, 0), result);

    const stat = try file.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o644), stat.mode & 0o777);
}

test "setPermissions with directory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");
    var dir = try tmp_dir.dir.openDir("subdir", .{});
    defer dir.close();

    // This should work on all platforms
    const result = try setPermissions(std.testing.allocator, dir, 0o755, "subdir", "test", lib.null_writer);
    try std.testing.expectEqual(@as(u8, 0), result);

    const stat = try dir.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o755), stat.mode & 0o777);
}

test "CI detection" {
    // This test just verifies the function compiles and runs
    // Actual result depends on environment
    const in_ci = isRunningInCI();
    _ = in_ci;

    const should_skip = shouldSkipMacOSCITest();
    _ = should_skip;
}

test "Linux fakeroot detection" {
    // This test just verifies the function compiles and runs
    // Actual result depends on environment
    const under_fakeroot = isRunningUnderLinuxFakeroot();

    // On non-Linux platforms, should always return false
    if (builtin.os.tag != .linux) {
        try std.testing.expectEqual(false, under_fakeroot);
    }
    // On Linux platforms, the function should run without error regardless of result
}
