//! Integration tests for the privilege testing framework.
//!
//! These tests verify that the privilege simulation infrastructure works
//! correctly: platform detection, tool availability, and environment
//! handling.
//!
//! Prerequisites:
//! - fakeroot or unshare available for privilege simulation on Linux
//! - Tests gracefully skip on platforms without privilege simulation

const std = @import("std");
const testing = std.testing;
const privilege_test = @import("privilege_test.zig");
const builtin = @import("builtin");
const fs = std.fs;
const process = std.process;
const common = @import("lib.zig");
const env = @import("env.zig");

// Import shared test utilities.
const TestUtils = @import("test_utils_privilege.zig").TestUtils;

// Platform detection tests.
test "platform detection is consistent" {
    const platform = privilege_test.Platform.detect();

    // Verify platform matches build target.
    switch (builtin.os.tag) {
        .linux => try testing.expect(platform == .linux),
        .macos => try testing.expect(platform == .macos),
        .freebsd, .openbsd, .netbsd => try testing.expect(platform == .bsd),
        else => try testing.expect(platform == .other),
    }
}

test "tool detection finds expected tools on platform" {
    const allocator = testing.allocator;
    const io = testing.io;
    var utils = TestUtils.init(allocator, io);
    defer utils.deinit();

    const platform = privilege_test.Platform.detect();

    // Check for fakeroot availability.
    const has_fakeroot = blk: {
        const result = utils.runCommand(&[_][]const u8{ "which", "fakeroot" }) catch {
            break :blk false;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        break :blk result.term.exited == 0;
    };

    // On Linux, we expect at least one tool to be available.
    if (platform == .linux) {
        const has_unshare = blk: {
            const result = utils.runCommand(&[_][]const u8{ "which", "unshare" }) catch {
                break :blk false;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            break :blk result.term.exited == 0;
        };

        // At least one should be available on Linux.
        try testing.expect(has_fakeroot or has_unshare);
    }
}

test "fakeroot environment detection" {
    const is_under_fakeroot = privilege_test.FakerootContext.isUnderFakeroot();

    // If FAKEROOTKEY is set, we should detect it.
    if (env.getEnv("FAKEROOTKEY") != null) {
        try testing.expect(is_under_fakeroot);
    } else {
        // No FAKEROOTKEY means we're not under fakeroot.
        try testing.expect(!is_under_fakeroot);
    }
}

test "privilege requirement detection" {
    const io = testing.io;

    // This test verifies requiresPrivilege() behavior in different environments.
    const is_under_fakeroot = privilege_test.FakerootContext.isUnderFakeroot();

    // Get a context to check if tools are available.
    const ctx = try privilege_test.FakerootContext.init(testing.allocator, io);

    // Try to call requiresPrivilege.
    privilege_test.requiresPrivilege(io) catch |err| {
        // If it returns an error, we should not be under fakeroot and no
        // tools available.
        try testing.expect(err == error.SkipZigTest);
        try testing.expect(!is_under_fakeroot);
        try testing.expect(!ctx.available);
        return;
    };

    // If requiresPrivilege succeeded, we should either:
    // 1. Be under fakeroot, OR
    // 2. Have privilege simulation tools available.
    try testing.expect(is_under_fakeroot or ctx.available);
}

test "fakeroot context creation and cleanup" {
    const allocator = testing.allocator;
    const io = testing.io;

    // Skip if not on a supported platform.
    const platform = privilege_test.Platform.detect();
    if (platform == .other) return error.SkipZigTest;

    // Try to create a fakeroot context.
    const context = privilege_test.FakerootContext.init(allocator, io) catch |err| {
        // If fakeroot is not available, that's expected.
        if (err == error.FakerootNotAvailable) return error.SkipZigTest;
        return err;
    };

    // Verify context was created successfully.
    try testing.expect(context.platform == privilege_test.Platform.detect());

    // If we're under fakeroot, the context should detect it.
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        try testing.expect(context.available);
    }
}

test "nested fakeroot contexts" {
    const allocator = testing.allocator;
    const io = testing.io;

    // Skip if already under fakeroot (can't nest).
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        return error.SkipZigTest;
    }

    // Try to create first context.
    const context1 = privilege_test.FakerootContext.init(allocator, io) catch |err| {
        if (err == error.FakerootNotAvailable) return error.SkipZigTest;
        return err;
    };

    // Creating a second context should succeed — it just detects available
    // tools. The actual nesting protection happens when trying to execute
    // under fakeroot.
    const context2 = try privilege_test.FakerootContext.init(allocator, io);

    // Both contexts should have the same configuration.
    try testing.expect(context1.platform == context2.platform);
    try testing.expect(context1.method == context2.method);
    try testing.expect(context1.available == context2.available);
}

test "privileged: environment variable propagation" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;

    try privilege_test.requiresPrivilege(io);

    var utils = TestUtils.init(allocator, io);
    defer utils.deinit();

    // Create environment map seeded with the parent environment, then add
    // the variable we want to read inside the child.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("TEST_PRIVILEGE_VAR", "test_value");

    // Run a child process with the env var set.
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "sh", "-c", "echo $TEST_PRIVILEGE_VAR" },
        .environ_map = &env_map,
    });

    try testing.expect(result.term.exited == 0);
    try testing.expect(std.mem.find(u8, result.stdout, "test_value") != null);
}

test "privileged: file permission operations" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;

    try privilege_test.requiresPrivilege(io);

    var utils = TestUtils.init(allocator, io);
    defer utils.deinit();

    const temp_dir = try utils.getTempDir();
    const temp_dir_handle = temp_dir.dir;

    // Create a test file.
    const test_file = try temp_dir_handle.createFile(io, "test_perms.txt", .{});
    test_file.close(io);

    // We don't have a Zig-native chmod on Io.File in 0.16; shell out for
    // the actual permission change. Build the absolute path via realPath.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try temp_dir_handle.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const file_path = try std.fmt.allocPrint(allocator, "{s}/test_perms.txt", .{dir_path});

    // Change permissions to 0600.
    {
        const result = try utils.runCommand(&[_][]const u8{ "chmod", "600", file_path });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(result.term.exited == 0);
    }

    // Verify permissions.
    const stat = try temp_dir_handle.statFile(io, "test_perms.txt", .{});
    const mode = stat.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), mode);

    // Change to 0755.
    {
        const result = try utils.runCommand(&[_][]const u8{ "chmod", "755", file_path });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(result.term.exited == 0);
    }

    // Verify new permissions.
    const stat2 = try temp_dir_handle.statFile(io, "test_perms.txt", .{});
    const mode2 = stat2.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), mode2);
}

test "privileged: directory permission operations" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;

    try privilege_test.requiresPrivilege(io);

    var utils = TestUtils.init(allocator, io);
    defer utils.deinit();

    const temp_dir = try utils.getTempDir();
    const temp_dir_handle = temp_dir.dir;

    // Create a test directory.
    try temp_dir_handle.createDir(io, "test_dir", .default_dir);

    // Use the external chmod command for directories.
    const temp_path = try temp_dir_handle.realPathFileAlloc(io, ".", allocator);
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/test_dir", .{temp_path});

    const chmod_result = try utils.runCommand(&[_][]const u8{
        "chmod", "700", dir_path,
    });
    defer allocator.free(chmod_result.stdout);
    defer allocator.free(chmod_result.stderr);
    try testing.expect(chmod_result.term.exited == 0);

    // Verify permissions.
    const stat = try temp_dir_handle.statFile(io, "test_dir", .{});
    const mode = stat.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), mode);

    // Change to 0755.
    const chmod_result2 = try utils.runCommand(&[_][]const u8{
        "chmod", "755", dir_path,
    });
    defer allocator.free(chmod_result2.stdout);
    defer allocator.free(chmod_result2.stderr);
    try testing.expect(chmod_result2.term.exited == 0);

    // Verify new permissions.
    const stat2 = try temp_dir_handle.statFile(io, "test_dir", .{});
    const mode2 = stat2.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), mode2);
}
