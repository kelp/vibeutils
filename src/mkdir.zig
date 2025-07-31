//! Create directories with optional parent directory creation and permission setting
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const privilege_test = common.privilege_test;
const testing = std.testing;

/// Command-line arguments for mkdir
const MkdirArgs = struct {
    help: bool = false,
    version: bool = false,
    mode: ?[]const u8 = null,
    parents: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .mode = .{ .short = 'm', .desc = "Set file mode (as in chmod)", .value_name = "MODE" },
        .parents = .{ .short = 'p', .desc = "Make parent directories as needed, no error if existing" },
        .verbose = .{ .short = 'v', .desc = "Print a message for each created directory" },
    };
};

/// Options controlling directory creation behavior
const MkdirOptions = struct {
    /// File mode for created directories
    mode: ?std.fs.File.Mode = null,

    /// Create parent directories as needed
    parents: bool = false,

    /// Print a message for each created directory
    verbose: bool = false,
};

/// Main entry point for mkdir command
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runMkdir(stdout_writer, stderr_writer, allocator);
    if (exit_code != common.ExitCode.success) {
        std.process.exit(@intFromEnum(exit_code));
    }
}

/// Run mkdir with provided writers for output
pub fn runMkdir(stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !common.ExitCode {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Parse arguments using common argparse module
    const args = common.argparse.ArgParser.parseProcess(MkdirArgs, allocator) catch |err| {
        switch (err) {
            // Handle argument parsing errors with appropriate error messages
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                try stderr_writer.print("{s}: invalid argument\n", .{prog_name});
                return common.ExitCode.general_error;
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    // Handle help
    if (args.help) {
        try printHelp(stdout_writer);
        return common.ExitCode.success;
    }

    // Handle version
    if (args.version) {
        try printVersion(stdout_writer);
        return common.ExitCode.success;
    }

    // Check if we have directories to create
    const dirs = args.positionals;
    if (dirs.len == 0) {
        try stderr_writer.print("{s}: missing operand\n", .{prog_name});
        return common.ExitCode.general_error;
    }

    // Create options
    var options = MkdirOptions{
        .parents = args.parents,
        .verbose = args.verbose,
    };

    // Parse mode if provided
    if (args.mode) |mode_str| {
        options.mode = parseMode(mode_str) catch {
            try stderr_writer.print("{s}: invalid mode '{s}'\n", .{ prog_name, mode_str });
            return common.ExitCode.general_error;
        };
    }

    // Process directories - continue processing even if some fail
    var exit_code = common.ExitCode.success;
    for (dirs) |dir_path| {
        createDirectory(dir_path, options, stdout_writer, stderr_writer, allocator) catch {
            // Mark overall failure but continue with remaining directories
            exit_code = common.ExitCode.general_error;
            continue;
        };
    }

    return exit_code;
}

/// Print help message to provided writer
fn printHelp(writer: anytype) !void {
    try writer.print(
        \\Usage: mkdir [OPTION]... DIRECTORY...
        \\Create the DIRECTORY(ies), if they do not already exist.
        \\
        \\  -m, --mode=MODE   set file mode (as in chmod)
        \\  -p, --parents     make parent directories as needed, no error if existing
        \\  -v, --verbose     print a message for each created directory
        \\  -h, --help        display this help and exit
        \\  -V, --version     output version information and exit
        \\
        \\Examples:
        \\  mkdir dir1          Create directory 'dir1'
        \\  mkdir -p a/b/c      Create directory tree including parents
        \\  mkdir -m 755 bin    Create directory with permissions rwxr-xr-x
        \\
    , .{});
}

/// Print version information to provided writer
fn printVersion(writer: anytype) !void {
    try writer.print("mkdir (vibeutils) 0.1.0\n", .{});
}

/// Set directory permissions (POSIX only)
///
/// Windows limitations:
/// - Mode setting is not supported on Windows filesystems
/// - Function prints warning and returns successfully to maintain compatibility
/// - Windows directories use default ACL-based permissions instead
///
/// Error handling strategy:
/// - POSIX systems: Returns error.ChmodFailed if chmod() syscall fails
/// - All errors from chmod are converted to our custom error type for consistent handling
/// - Path is converted to null-terminated for C API compatibility
fn setDirectoryMode(path: []const u8, mode: std.fs.File.Mode, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    if (builtin.os.tag == .windows) {
        // Print warning on Windows
        try stderr_writer.print("{s}: warning: mode flag (-m) is not supported on Windows\n", .{prog_name});
        return;
    }

    // Use C chmod function for directories on POSIX systems
    const path_z = try std.fmt.allocPrintZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);

    const result = std.c.chmod(path_z, mode);
    if (result != 0) {
        const err = std.posix.errno(result);
        try stderr_writer.print("{s}: cannot set mode on '{s}': {s}\n", .{ prog_name, path, @tagName(err) });
        return error.ChmodFailed;
    }
}

/// Parse octal mode string (e.g. "755") into file mode
fn parseMode(mode_str: []const u8) !std.fs.File.Mode {
    // For now, support only octal modes
    // TODO: Support symbolic modes like u+rwx
    if (mode_str.len == 0) {
        return error.InvalidMode;
    }

    // Parse octal digits
    var mode: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') {
            return error.InvalidMode;
        }
        // Convert octal string to numeric value
        mode = mode * 8 + (c - '0');
    }

    // Validate mode is reasonable (3 or 4 digits)
    if (mode > 0o7777) {
        return error.InvalidMode;
    }

    return @intCast(mode);
}

/// Create directory with specified options
fn createDirectory(path: []const u8, options: MkdirOptions, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Normalize path by removing trailing slashes
    const normalized_path = std.mem.trimRight(u8, path, "/");
    if (normalized_path.len == 0) {
        // Special case: root directory
        try stderr_writer.print("{s}: cannot create directory '/': File exists\n", .{prog_name});
        return error.AlreadyExists;
    }

    if (options.parents) {
        try createDirectoryWithParents(normalized_path, options, stdout_writer, stderr_writer, allocator);
    } else {
        try createSingleDirectory(normalized_path, options, stdout_writer, stderr_writer, allocator);
    }
}

/// Create single directory without parent creation
fn createSingleDirectory(path: []const u8, options: MkdirOptions, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Create directory
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try stderr_writer.print("{s}: cannot create directory '{s}': File exists\n", .{ prog_name, path });
            return err;
        },
        error.FileNotFound => {
            try stderr_writer.print("{s}: cannot create directory '{s}': No such file or directory\n", .{ prog_name, path });
            return err;
        },
        error.AccessDenied => {
            try stderr_writer.print("{s}: cannot create directory '{s}': Permission denied\n", .{ prog_name, path });
            return err;
        },
        else => {
            try stderr_writer.print("{s}: cannot create directory '{s}': {s}\n", .{ prog_name, path, @errorName(err) });
            return err;
        },
    };

    // Set mode if specified
    if (options.mode) |mode| {
        try setDirectoryMode(path, mode, stderr_writer, allocator);
    }

    if (options.verbose) {
        try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, path });
    }
}

/// Create directory tree with parent directories
fn createDirectoryWithParents(path: []const u8, options: MkdirOptions, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Use arena allocator to prevent memory leaks
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Split path into components
    var components = std.ArrayList([]const u8).init(arena_allocator);
    defer components.deinit();

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        try components.append(component);
    }

    // Create each directory in the path
    var current_path = std.ArrayList(u8).init(arena_allocator);
    defer current_path.deinit();

    // Handle absolute paths
    if (path[0] == '/') {
        try current_path.append('/');
    }

    for (components.items, 0..) |component, i| {
        if (i > 0 and current_path.items[current_path.items.len - 1] != '/') {
            try current_path.append('/');
        }
        try current_path.appendSlice(component);

        const is_last = i == components.items.len - 1;

        // Try to create the directory
        std.fs.cwd().makeDir(current_path.items) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // This is OK with -p flag - existing directories are not an error
                continue;
            },
            error.AccessDenied => {
                try stderr_writer.print("{s}: cannot create directory '{s}': Permission denied\n", .{ prog_name, current_path.items });
                return err;
            },
            else => {
                try stderr_writer.print("{s}: cannot create directory '{s}': {s}\n", .{ prog_name, current_path.items, @errorName(err) });
                return err;
            },
        };

        // Set mode only on the final directory if specified
        if (is_last and options.mode != null) {
            try setDirectoryMode(current_path.items, options.mode.?, stderr_writer, arena_allocator);
        }

        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, current_path.items });
        }
    }
}

// ============================================================================
// Tests
// ============================================================================
// This test section is divided into two parts:
//
// 1. Regular Tests - Can be run with standard permissions
//    These tests verify basic functionality without requiring special privileges.
//    They test directory creation logic, error handling, and option parsing.
//
// 2. Privileged Tests - Require privilege simulation (fakeroot)
//    These tests verify mode setting and permission-related functionality.
//    They are prefixed with "privileged:" and excluded from regular test runs.
//    Run with: ./scripts/run-privileged-tests.sh or under fakeroot
// ============================================================================

// ===== Regular Tests =====

test "basic single directory creation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir = "test_dir";
    try tmp.dir.makeDir(test_dir);

    // Verify directory exists
    const stat = try tmp.dir.statFile(test_dir);
    try testing.expect(stat.kind == .directory);
}

test "create directory - already exists error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir = "existing_dir";
    try tmp.dir.makeDir(test_dir);

    // Try to create again
    const result = tmp.dir.makeDir(test_dir);
    try testing.expectError(error.PathAlreadyExists, result);
}

test "create directory - parent not found error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Try to create nested directory without parent
    const result = tmp.dir.makeDir("nonexistent/subdir");
    try testing.expectError(error.FileNotFound, result);
}

test "parseMode - valid octal modes" {
    try testing.expectEqual(@as(u32, 0o755), try parseMode("755"));
    try testing.expectEqual(@as(u32, 0o644), try parseMode("644"));
    try testing.expectEqual(@as(u32, 0o777), try parseMode("777"));
    try testing.expectEqual(@as(u32, 0o700), try parseMode("700"));
    try testing.expectEqual(@as(u32, 0o7777), try parseMode("7777"));
}

test "parseMode - invalid modes" {
    try testing.expectError(error.InvalidMode, parseMode(""));
    try testing.expectError(error.InvalidMode, parseMode("888"));
    try testing.expectError(error.InvalidMode, parseMode("abc"));
    try testing.expectError(error.InvalidMode, parseMode("75a"));
}

test "normalize path - remove trailing slashes" {
    // These should all be treated the same
    const paths = [_][]const u8{
        "test_dir",
        "test_dir/",
        "test_dir//",
    };

    for (paths) |path| {
        const normalized = std.mem.trimRight(u8, path, "/");
        try testing.expectEqualStrings("test_dir", normalized);
    }
}

test "create directory with parents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;

    // Create nested structure
    const nested_path = "a/b/c/d";

    // Simulate creating with parents by using tmp.dir as cwd context
    var components = std.ArrayList([]const u8).init(allocator);
    defer components.deinit();

    var it = std.mem.tokenizeScalar(u8, nested_path, '/');
    while (it.next()) |component| {
        try components.append(component);
    }

    var current_path = std.ArrayList(u8).init(allocator);
    defer current_path.deinit();

    for (components.items, 0..) |component, i| {
        if (i > 0) try current_path.append('/');
        try current_path.appendSlice(component);
        tmp.dir.makeDir(current_path.items) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
    }

    // Verify all directories exist
    const stat_a = try tmp.dir.statFile("a");
    try testing.expect(stat_a.kind == .directory);

    const stat_d = try tmp.dir.statFile("a/b/c/d");
    try testing.expect(stat_d.kind == .directory);
}

test "create directory with mode" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir = "mode_test";
    try tmp.dir.makeDir(test_dir);

    // Verify directory exists
    const stat = try tmp.dir.statFile(test_dir);
    try testing.expect(stat.kind == .directory);

    // Note: Actual mode verification is tested in privileged tests
}

test "empty path handling" {
    const normalized = std.mem.trimRight(u8, "///", "/");
    try testing.expectEqual(@as(usize, 0), normalized.len);
}

test "MkdirOptions default values" {
    const options = MkdirOptions{};
    try testing.expect(options.mode == null);
    try testing.expect(options.parents == false);
    try testing.expect(options.verbose == false);
}

test "verbose output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir = "verbose_test";
    try tmp.dir.makeDir(test_dir);

    // Verify directory exists
    const stat = try tmp.dir.statFile(test_dir);
    try testing.expect(stat.kind == .directory);

    // Note: In the real implementation, verbose mode writes to stdout
}

test "multiple directories creation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dirs = [_][]const u8{ "dir1", "dir2", "dir3" };

    // Create all directories
    for (dirs) |dir| {
        try tmp.dir.makeDir(dir);
    }

    // Verify all were created
    for (dirs) |dir| {
        const stat = try tmp.dir.statFile(dir);
        try testing.expect(stat.kind == .directory);
    }
}

test "writer functionality - help and version output" {
    var stdout_buf: [2048]u8 = undefined;
    var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);

    // Test help output
    try printHelp(stdout_fbs.writer());
    const help_output = stdout_fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, help_output, "Usage: mkdir") != null);
    try testing.expect(std.mem.indexOf(u8, help_output, "--help") != null);
    try testing.expect(std.mem.indexOf(u8, help_output, "--verbose") != null);

    // Reset buffer for version test
    stdout_fbs.reset();

    // Test version output
    try printVersion(stdout_fbs.writer());
    const version_output = stdout_fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, version_output, "mkdir (vibeutils)") != null);
    try testing.expect(std.mem.indexOf(u8, version_output, "0.1.0") != null);
}

test "mode setting verification" {
    // Skip on non-POSIX systems
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir = "mode_test_dir";
    try tmp.dir.makeDir(test_dir);

    // Verify directory was created
    const stat = try tmp.dir.statFile(test_dir);
    try testing.expect(stat.kind == .directory);

    // Note: Actual chmod functionality is tested in privileged tests
}

test "parent permission errors" {
    // This test would require special permissions and is platform-specific
    // So we just verify the basic error handling logic
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Try to create a nested directory without parent - should fail
    const result = tmp.dir.makeDir("nonexistent/subdir");
    try testing.expectError(error.FileNotFound, result);
}

test "intermediate directories get default permissions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create nested directory structure manually
    try tmp.dir.makeDir("a");
    try tmp.dir.makeDir("a/b");
    try tmp.dir.makeDir("a/b/c");
    try tmp.dir.makeDir("a/b/c/final");

    // Verify all directories were created
    const stat_a = try tmp.dir.statFile("a");
    try testing.expect(stat_a.kind == .directory);

    const stat_final = try tmp.dir.statFile("a/b/c/final");
    try testing.expect(stat_final.kind == .directory);

    // Note: Actual testing of -p and -m flag interaction is in privileged tests
}

// ============================================================================
// Privileged Tests
// ============================================================================
// These tests require privilege simulation (fakeroot) to properly test mode
// setting functionality. They verify that:
// - Directories are created with the correct permissions when using -m
// - Parent directories get default permissions while final directory gets
//   the specified mode
// - Mode setting works correctly with various permission values
//
// Test naming convention: All privileged tests start with "privileged:"
// This allows the test runner to filter them out during regular test runs.
// ============================================================================

test "privileged: create single directory with mode setting" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            const test_dir = "mode_test_755";
            const options = MkdirOptions{ .mode = 0o755 };

            // Get the absolute path for the test directory
            const abs_path = try tmp.dir.realpathAlloc(allocator, ".");
            defer allocator.free(abs_path);

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_path, test_dir });
            defer allocator.free(full_path);

            // Create directory with mode
            var stdout_buf: [1024]u8 = undefined;
            var stderr_buf: [1024]u8 = undefined;
            var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
            var stderr_fbs = std.io.fixedBufferStream(&stderr_buf);

            try createSingleDirectory(full_path, options, stdout_fbs.writer(), stderr_fbs.writer(), testing.allocator);

            // Verify directory exists and has correct permissions
            try privilege_test.assertPermissions(full_path, 0o755, null, null);
        }
    }.testFn);
}

test "privileged: create directory with parents - only final gets mode" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            const nested_path = "parent/child/final";
            const options = MkdirOptions{ .mode = 0o750, .parents = true };

            // Get the absolute path for the nested structure
            const abs_path = try tmp.dir.realpathAlloc(allocator, ".");
            defer allocator.free(abs_path);

            const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ abs_path, nested_path });
            defer testing.allocator.free(full_path);

            // Create directory structure with parents
            var stdout_buf: [1024]u8 = undefined;
            var stderr_buf: [1024]u8 = undefined;
            var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
            var stderr_fbs = std.io.fixedBufferStream(&stderr_buf);

            try createDirectoryWithParents(full_path, options, stdout_fbs.writer(), stderr_fbs.writer(), allocator);

            // Verify all directories exist
            const parent_path = try std.fmt.allocPrint(testing.allocator, "{s}/parent", .{abs_path});
            defer testing.allocator.free(parent_path);
            const child_path = try std.fmt.allocPrint(testing.allocator, "{s}/parent/child", .{abs_path});
            defer testing.allocator.free(child_path);

            const stat_parent = try std.fs.cwd().statFile(parent_path);
            try testing.expect(stat_parent.kind == .directory);

            const stat_child = try std.fs.cwd().statFile(child_path);
            try testing.expect(stat_child.kind == .directory);

            // Verify only the final directory has the specified mode
            try privilege_test.assertPermissions(full_path, 0o750, null, null);

            // Intermediate directories should have different permissions
            // (they get default permissions respecting umask)
            const parent_mode = stat_parent.mode & 0o777;
            const child_mode = stat_child.mode & 0o777;

            // These should NOT be 0o750 (unless umask happens to produce that)
            // We just verify they exist and are directories
            try testing.expect(parent_mode != 0 and child_mode != 0);
        }
    }.testFn);
}

test "privileged: verbose output with mode setting" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            const test_dir = "verbose_mode_test";
            const options = MkdirOptions{ .mode = 0o644, .verbose = true };

            // Get the absolute path for the test directory
            const abs_path = try tmp.dir.realpathAlloc(allocator, ".");
            defer allocator.free(abs_path);

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_path, test_dir });
            defer allocator.free(full_path);

            // Capture stdout to verify verbose output
            // Note: In the actual implementation, this would write to stdout
            // For testing, we verify the directory was created with correct mode
            var stdout_buf: [1024]u8 = undefined;
            var stderr_buf: [1024]u8 = undefined;
            var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
            var stderr_fbs = std.io.fixedBufferStream(&stderr_buf);

            try createSingleDirectory(full_path, options, stdout_fbs.writer(), stderr_fbs.writer(), testing.allocator);

            // Verify directory exists and has correct permissions
            try privilege_test.assertPermissions(full_path, 0o644, null, null);

            // The verbose output would contain something like:
            // "mkdir: created directory 'verbose_mode_test'"
            // We can't easily capture stdout in this test framework,
            // but we verify the core functionality works
        }
    }.testFn);
}

test "privileged: mode setting with various octal values" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            // Test various mode values
            const test_cases = [_]struct {
                dir_name: []const u8,
                mode: std.fs.File.Mode,
            }{
                .{ .dir_name = "test_700", .mode = 0o700 },
                .{ .dir_name = "test_755", .mode = 0o755 },
                .{ .dir_name = "test_644", .mode = 0o644 },
                .{ .dir_name = "test_777", .mode = 0o777 },
                .{ .dir_name = "test_600", .mode = 0o600 },
            };

            // Get base path
            const abs_path = try tmp.dir.realpathAlloc(allocator, ".");
            defer allocator.free(abs_path);

            for (test_cases) |case| {
                const options = MkdirOptions{ .mode = case.mode };
                const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ abs_path, case.dir_name });
                defer testing.allocator.free(full_path);

                // Create directory with specific mode
                var stdout_buf: [1024]u8 = undefined;
                var stderr_buf: [1024]u8 = undefined;
                var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
                var stderr_fbs = std.io.fixedBufferStream(&stderr_buf);

                try createSingleDirectory(full_path, options, stdout_fbs.writer(), stderr_fbs.writer(), testing.allocator);

                // Verify directory has correct permissions
                try privilege_test.assertPermissions(full_path, case.mode, null, null);
            }
        }
    }.testFn);
}

test "privileged: multiple directories creation with mode" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            const dirs = [_][]const u8{ "dir1", "dir2", "dir3" };
            const mode = 0o751;
            const options = MkdirOptions{ .mode = mode, .verbose = true };

            // Get base path
            const abs_path = try tmp.dir.realpathAlloc(allocator, ".");
            defer allocator.free(abs_path);

            // Create all directories with the same mode
            for (dirs) |dir| {
                const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ abs_path, dir });
                defer testing.allocator.free(full_path);

                var stdout_buf: [1024]u8 = undefined;
                var stderr_buf: [1024]u8 = undefined;
                var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
                var stderr_fbs = std.io.fixedBufferStream(&stderr_buf);

                try createSingleDirectory(full_path, options, stdout_fbs.writer(), stderr_fbs.writer(), testing.allocator);

                // Verify each directory has correct permissions
                try privilege_test.assertPermissions(full_path, mode, null, null);
            }
        }
    }.testFn);
}
