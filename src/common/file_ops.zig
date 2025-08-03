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
                lib.printWarningWithProgram(allocator, stderr_writer, program_name, "Failed to set permissions on {s} (macOS limitation): {s}", .{ ctx, @errorName(err) });
            } else {
                lib.printWarningWithProgram(allocator, stderr_writer, program_name, "Failed to set permissions on macOS: {s}", .{@errorName(err)});
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

test "setPermissions with file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    defer file.close();

    // This should work on all platforms
    const result = try setPermissions(file, 0o644, "test.txt", "test", lib.null_writer);
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
    const result = try setPermissions(dir, 0o755, "subdir", "test", lib.null_writer);
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
