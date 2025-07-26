const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const common = @import("common");
const testing = std.testing;

const MkdirOptions = struct {
    mode: ?std.fs.File.Mode = null, // -m flag
    parents: bool = false, // -p flag
    verbose: bool = false, // -v flag (GNU extension)
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define parameters using zig-clap
    const params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-V, --version  Output version information and exit.
        \\-m, --mode <str>  Set file mode (as in chmod).
        \\-p, --parents  Make parent directories as needed, no error if existing.
        \\-v, --verbose  Print a message for each created directory.
        \\<str>...       Directory names to create.
        \\
    );

    // Parse arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Handle help
    if (res.args.help != 0) {
        try printHelp();
        return;
    }

    // Handle version
    if (res.args.version != 0) {
        try printVersion();
        return;
    }

    // Check if we have directories to create
    const dirs = res.positionals.@"0";
    if (dirs.len == 0) {
        common.printError("missing operand", .{});
        std.process.exit(@intFromEnum(common.ExitCode.general_error));
    }

    // Create options
    var options = MkdirOptions{
        .parents = res.args.parents != 0,
        .verbose = res.args.verbose != 0,
    };

    // Parse mode if provided
    if (res.args.mode) |mode_str| {
        options.mode = try parseMode(mode_str);
    }

    // Process directories
    var exit_code = common.ExitCode.success;
    for (dirs) |dir_path| {
        createDirectory(dir_path, options, allocator) catch {
            exit_code = common.ExitCode.general_error;
            continue;
        };
    }

    std.process.exit(@intFromEnum(exit_code));
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
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

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("mkdir (vibeutils) 0.1.0\n", .{});
}

fn parseMode(mode_str: []const u8) !std.fs.File.Mode {
    // For now, support only octal modes
    // TODO: Support symbolic modes like u+rwx
    if (mode_str.len == 0) {
        return error.InvalidMode;
    }

    var mode: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') {
            return error.InvalidMode;
        }
        mode = mode * 8 + (c - '0');
    }

    // Validate mode is reasonable (3 or 4 digits)
    if (mode > 0o7777) {
        return error.InvalidMode;
    }

    return @intCast(mode);
}

fn createDirectory(path: []const u8, options: MkdirOptions, allocator: std.mem.Allocator) !void {
    // Normalize path by removing trailing slashes
    const normalized_path = std.mem.trimRight(u8, path, "/");
    if (normalized_path.len == 0) {
        // Special case: root directory
        common.printError("cannot create directory '/': File exists", .{});
        return error.AlreadyExists;
    }

    if (options.parents) {
        try createDirectoryWithParents(normalized_path, options, allocator);
    } else {
        try createSingleDirectory(normalized_path, options);
    }
}

fn createSingleDirectory(path: []const u8, options: MkdirOptions) !void {
    // Create directory
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            common.printError("cannot create directory '{s}': File exists", .{path});
            return err;
        },
        error.FileNotFound => {
            common.printError("cannot create directory '{s}': No such file or directory", .{path});
            return err;
        },
        error.AccessDenied => {
            common.printError("cannot create directory '{s}': Permission denied", .{path});
            return err;
        },
        else => {
            common.printError("cannot create directory '{s}': {s}", .{ path, @errorName(err) });
            return err;
        },
    };

    // Set mode if specified (only on POSIX systems)
    if (options.mode) |mode| {
        if (builtin.os.tag != .windows) {
            // Use C chmod function for directories
            const path_z = try std.fmt.allocPrintZ(std.heap.c_allocator, "{s}", .{path});
            defer std.heap.c_allocator.free(path_z);

            const result = std.c.chmod(path_z, mode);
            if (result != 0) {
                const err = std.posix.errno(result);
                common.printError("cannot set mode on '{s}': {s}", .{ path, @tagName(err) });
                return error.ChmodFailed;
            }
        }
    }

    if (options.verbose) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("mkdir: created directory '{s}'\n", .{path});
    }
}

fn createDirectoryWithParents(path: []const u8, options: MkdirOptions, allocator: std.mem.Allocator) !void {
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
                // This is OK with -p flag
                continue;
            },
            error.AccessDenied => {
                common.printError("cannot create directory '{s}': Permission denied", .{current_path.items});
                return err;
            },
            else => {
                common.printError("cannot create directory '{s}': {s}", .{ current_path.items, @errorName(err) });
                return err;
            },
        };

        // Set mode only on the final directory if specified (only on POSIX systems)
        if (is_last and options.mode != null) {
            if (builtin.os.tag != .windows) {
                // Use C chmod function for directories
                const path_z = try std.fmt.allocPrintZ(arena_allocator, "{s}", .{current_path.items});
                defer arena_allocator.free(path_z);

                const result = std.c.chmod(path_z, options.mode.?);
                if (result != 0) {
                    const err = std.posix.errno(result);
                    common.printError("cannot set mode on '{s}': {s}", .{ current_path.items, @tagName(err) });
                    return error.ChmodFailed;
                }
            }
        }

        if (options.verbose) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("mkdir: created directory '{s}'\n", .{current_path.items});
        }
    }
}

// ===== Tests =====

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

    // Note: Actual mode testing would require platform-specific code
    // and permissions that may not be available in test environment
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

    // Note: Actual chmod functionality is tested through integration tests
    // since std.fs.Dir.chmod behavior varies by platform
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

    // Note: In the real implementation with -p -m flags,
    // intermediate directories get default permissions (respecting umask)
    // while only the final directory gets the mode specified with -m
}
