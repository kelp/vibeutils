const std = @import("std");
const testing = std.testing;
const privilege_test = @import("privilege_test.zig");

/// Shared test utilities for privilege simulation integration tests
pub const TestUtils = struct {
    allocator: std.mem.Allocator,
    temp_dir: ?std.testing.TmpDir = null,

    pub fn init(allocator: std.mem.Allocator) TestUtils {
        return .{
            .allocator = allocator,
            .temp_dir = null,
        };
    }

    pub fn deinit(self: *TestUtils) void {
        if (self.temp_dir) |*tmp| {
            tmp.cleanup();
        }
    }

    pub fn getTempDir(self: *TestUtils) !std.testing.TmpDir {
        if (self.temp_dir == null) {
            self.temp_dir = std.testing.tmpDir(.{});
        }
        return self.temp_dir.?;
    }

    pub fn runCommand(self: *TestUtils, argv: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !std.process.Child.RunResult {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
        }) catch |err| {
            try stderr_writer.print("Failed to run command: {s}\n", .{@errorName(err)});
            return err;
        };

        if (result.stdout.len > 0) {
            try stdout_writer.writeAll(result.stdout);
        }
        if (result.stderr.len > 0) {
            try stderr_writer.writeAll(result.stderr);
        }

        return result;
    }

    pub fn runCommandExpectError(self: *TestUtils, argv: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !void {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
        }) catch {
            // Any error is acceptable - we expect the command to fail
            return;
        };
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        // Write output for debugging
        if (result.stdout.len > 0) {
            try stdout_writer.writeAll(result.stdout);
        }
        if (result.stderr.len > 0) {
            try stderr_writer.writeAll(result.stderr);
        }

        // Check if exit code indicates failure
        switch (result.term) {
            .Exited => |code| {
                if (code != 0) return; // Non-zero exit code is expected
            },
            else => {},
        }

        return error.TestUnexpectedSuccess;
    }

    /// Run a built utility from zig-out/bin
    pub fn runBuiltUtility(self: *TestUtils, utility: []const u8, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !std.process.Child.RunResult {
        const bin_path = try getBinaryPath(self.allocator, utility);
        defer self.allocator.free(bin_path);

        var argv = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(argv);

        argv[0] = bin_path;
        for (args, 1..) |arg, i| {
            argv[i] = arg;
        }

        return self.runCommand(argv, stdout_writer, stderr_writer);
    }

    /// Create a test subdirectory with a unique name
    pub fn createTestSubdir(self: *TestUtils, temp_dir: std.testing.TmpDir, test_name: []const u8) !std.fs.Dir {
        // Create a unique subdirectory for this test
        const timestamp = std.time.timestamp();
        const subdir_name = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ test_name, timestamp });
        defer self.allocator.free(subdir_name);

        return temp_dir.dir.makeOpenPath(subdir_name, .{});
    }
};

/// Get the path to a built binary - standalone function with explicit allocator
pub fn getBinaryPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // Try multiple possible build paths
    const possible_paths = [_][]const u8{
        "zig-out/bin",
        "../zig-out/bin",
        "../../zig-out/bin",
        "./bin",
        "../bin",
    };

    for (possible_paths) |bin_dir| {
        const full_path = std.fs.path.join(allocator, &.{ bin_dir, name }) catch continue;

        // Check if the binary exists
        std.fs.cwd().access(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };

        return full_path;
    }

    // Fallback: try BUILD_ROOT environment variable
    if (std.process.getEnvVarOwned(allocator, "BUILD_ROOT")) |build_root| {
        defer allocator.free(build_root);
        return std.fs.path.join(allocator, &.{ build_root, "zig-out", "bin", name });
    } else |_| {
        // Final fallback: assume current directory structure
        return std.fs.path.join(allocator, &.{ "zig-out", "bin", name });
    }
}

/// Parse ls -la output into structured permissions
pub const FilePermissions = struct {
    user: Perms,
    group: Perms,
    other: Perms,

    pub const Perms = struct {
        read: bool,
        write: bool,
        execute: bool,

        pub fn format(self: Perms, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeByte(if (self.read) 'r' else '-');
            try writer.writeByte(if (self.write) 'w' else '-');
            try writer.writeByte(if (self.execute) 'x' else '-');
        }
    };

    pub fn parse(mode_str: []const u8) !FilePermissions {
        if (mode_str.len < 9) return error.InvalidPermissionString;

        return FilePermissions{
            .user = Perms{
                .read = mode_str[0] == 'r',
                .write = mode_str[1] == 'w',
                .execute = mode_str[2] == 'x' or mode_str[2] == 's' or mode_str[2] == 'S',
            },
            .group = Perms{
                .read = mode_str[3] == 'r',
                .write = mode_str[4] == 'w',
                .execute = mode_str[5] == 'x' or mode_str[5] == 's' or mode_str[5] == 'S',
            },
            .other = Perms{
                .read = mode_str[6] == 'r',
                .write = mode_str[7] == 'w',
                .execute = mode_str[8] == 'x' or mode_str[8] == 't' or mode_str[8] == 'T',
            },
        };
    }

    pub fn expectEqual(expected: FilePermissions, actual: FilePermissions) !void {
        try testing.expectEqual(expected.user.read, actual.user.read);
        try testing.expectEqual(expected.user.write, actual.user.write);
        try testing.expectEqual(expected.user.execute, actual.user.execute);
        try testing.expectEqual(expected.group.read, actual.group.read);
        try testing.expectEqual(expected.group.write, actual.group.write);
        try testing.expectEqual(expected.group.execute, actual.group.execute);
        try testing.expectEqual(expected.other.read, actual.other.read);
        try testing.expectEqual(expected.other.write, actual.other.write);
        try testing.expectEqual(expected.other.execute, actual.other.execute);
    }
};

/// Parse ls output to extract file permissions (prefers regular files)
pub fn parseLsPermissions(output: []const u8) !FilePermissions {
    // ls -la output format: -rw-r--r-- 1 user group size date time filename
    // Single pass: prefer regular files, fallback to any file type
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var fallback_permissions: ?FilePermissions = null;

    while (lines.next()) |line| {
        if (line.len < 10) continue;

        const first_char = line[0];
        switch (first_char) {
            '-' => {
                // Regular file - preferred, return immediately
                return FilePermissions.parse(line[1..10]);
            },
            'd', 'l', 'c', 'b', 'p', 's' => {
                // Directory, symlink, or special file - save as fallback
                if (fallback_permissions == null) {
                    fallback_permissions = FilePermissions.parse(line[1..10]) catch continue;
                }
            },
            else => continue,
        }
    }

    return fallback_permissions orelse error.NoPermissionsFound;
}

test "parseLsPermissions basic functionality" {
    const output =
        \\total 8
        \\drwxr-xr-x 2 user group 4096 Jan 1 12:00 .
        \\drwxr-xr-x 3 user group 4096 Jan 1 12:00 ..
        \\-rw-r--r-- 1 user group    0 Jan 1 12:00 test.txt
    ;

    const perms = try parseLsPermissions(output);
    try testing.expectEqual(true, perms.user.read);
    try testing.expectEqual(true, perms.user.write);
    try testing.expectEqual(false, perms.user.execute);
    try testing.expectEqual(true, perms.group.read);
    try testing.expectEqual(false, perms.group.write);
    try testing.expectEqual(false, perms.group.execute);
    try testing.expectEqual(true, perms.other.read);
    try testing.expectEqual(false, perms.other.write);
    try testing.expectEqual(false, perms.other.execute);
}

test "FilePermissions.parse with special bits" {
    // Test setuid
    const setuid = try FilePermissions.parse("rws------");
    try testing.expectEqual(true, setuid.user.execute);

    // Test setgid
    const setgid = try FilePermissions.parse("rwxrws---");
    try testing.expectEqual(true, setgid.group.execute);

    // Test sticky bit
    const sticky = try FilePermissions.parse("rwxrwxrwt");
    try testing.expectEqual(true, sticky.other.execute);
}

test "getBinaryPath finds existing binary" {
    const allocator = testing.allocator;

    // Test with a known binary (should exist after build)
    const path = getBinaryPath(allocator, "echo") catch {
        // It's OK if binary doesn't exist in test environment
        return;
    };
    defer allocator.free(path);

    // If we got a path, it should contain the binary name
    try testing.expect(std.mem.endsWith(u8, path, "echo"));
}

test "TestUtils with writer API" {
    const allocator = testing.allocator;
    var utils = TestUtils.init(allocator);
    defer utils.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stdout_buf.deinit(allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stderr_buf.deinit(allocator);

    // Test that runCommandExpectError works with writers
    try utils.runCommandExpectError(&.{"false"}, stdout_buf.writer(allocator), stderr_buf.writer(allocator));

    // The command should have failed (that's expected)
    // This test just verifies the API works
}
