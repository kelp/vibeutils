const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");

/// Set file permissions using the most reliable method available
///
/// On macOS in CI environments, File.chmod() can cause SIGABRT errors under fakeroot.
/// This function uses std.posix.fchmod() directly on the file descriptor as a more
/// reliable approach. For directories, it accepts either a Dir or File handle.
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
///
/// # Returns
/// Returns an error if the operation fails on non-macOS platforms or if the
/// macOS fallback also fails.
pub fn setPermissions(handle: anytype, mode: std.fs.File.Mode, context: ?[]const u8) !void {
    const handle_type = @TypeOf(handle);

    // Get the file descriptor based on handle type
    const fd = if (handle_type == std.fs.File)
        handle.handle
    else if (handle_type == std.fs.Dir)
        handle.fd
    else
        @compileError("setPermissions expects std.fs.File or std.fs.Dir");

    std.posix.fchmod(fd, mode) catch |err| {
        // On macOS, especially in CI environments with fakeroot, permission
        // operations may fail. We report this as a warning but don't fail
        // the operation since the file operation itself succeeded.
        if (builtin.os.tag == .macos) {
            if (context) |ctx| {
                lib.printWarning("Failed to set permissions on {s} (macOS limitation): {s}", .{ ctx, @errorName(err) });
            } else {
                lib.printWarning("Failed to set permissions on macOS: {s}", .{@errorName(err)});
            }
            return;
        }
        return err;
    };
}

/// Check if running in a CI environment
///
/// Detects common CI environment variables to determine if the code is
/// running in a continuous integration system.
///
/// # Returns
/// true if running in a CI environment, false otherwise
pub fn isRunningInCI() bool {
    // Check for the most common CI environment variable
    // Use a temporary allocator for the check and free immediately
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
        if (std.process.getEnvVarOwned(allocator, var_name)) |_| {
            return true;
        } else |_| {}
    }

    return false;
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
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    defer file.close();

    // This should work on all platforms
    try setPermissions(file, 0o644, "test.txt");

    const stat = try file.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o644), stat.mode & 0o777);
}

test "setPermissions with directory" {
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");
    var dir = try tmp_dir.dir.openDir("subdir", .{});
    defer dir.close();

    // This should work on all platforms
    try setPermissions(dir, 0o755, "subdir");

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
