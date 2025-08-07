//! Integration tests for the privilege testing framework
//! These tests verify that the privilege simulation infrastructure works correctly
//!
//! This module tests the core infrastructure of the privilege simulation
//! framework, ensuring platform detection, tool availability, and environment
//! handling work correctly together.
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

// Import shared test utilities
const TestUtils = @import("test_utils_privilege.zig").TestUtils;

// Platform detection tests
test "platform detection is consistent" {
    const platform = privilege_test.Platform.detect();

    // Verify platform matches build target
    switch (builtin.os.tag) {
        .linux => try testing.expect(platform == .linux),
        .macos => try testing.expect(platform == .macos),
        .freebsd, .openbsd, .netbsd => try testing.expect(platform == .bsd),
        else => try testing.expect(platform == .other),
    }
}

test "tool detection finds expected tools on platform" {
    const allocator = testing.allocator;
    var utils = TestUtils.init(allocator);
    defer utils.deinit();

    const platform = privilege_test.Platform.detect();

    // Check for fakeroot availability
    const has_fakeroot = blk: {
        const result = utils.runCommand(&[_][]const u8{ "which", "fakeroot" }, common.null_writer, common.null_writer) catch {
            break :blk false;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        break :blk result.term.Exited == 0;
    };

    // On Linux, we expect at least one tool to be available
    if (platform == .linux) {
        const has_unshare = blk: {
            const result = utils.runCommand(&[_][]const u8{ "which", "unshare" }, common.null_writer, common.null_writer) catch {
                break :blk false;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            break :blk result.term.Exited == 0;
        };

        // At least one should be available on Linux
        try testing.expect(has_fakeroot or has_unshare);
    }
}

test "fakeroot environment detection" {
    const is_under_fakeroot = privilege_test.FakerootContext.isUnderFakeroot();

    // If FAKEROOTKEY is set, we should detect it
    if (std.process.getEnvVarOwned(testing.allocator, "FAKEROOTKEY")) |key| {
        defer testing.allocator.free(key);
        try testing.expect(is_under_fakeroot);
    } else |_| {
        // No FAKEROOTKEY means we're not under fakeroot
        try testing.expect(!is_under_fakeroot);
    }
}

test "privilege requirement detection" {
    // This test verifies requiresPrivilege() behavior in different environments
    const is_under_fakeroot = privilege_test.FakerootContext.isUnderFakeroot();

    // Get a context to check if tools are available
    const ctx = try privilege_test.FakerootContext.init(testing.allocator);

    // Try to call requiresPrivilege
    privilege_test.requiresPrivilege() catch |err| {
        // If it returns an error, we should not be under fakeroot and no tools available
        try testing.expect(err == error.SkipZigTest);
        try testing.expect(!is_under_fakeroot);
        try testing.expect(!ctx.available);
        return;
    };

    // If requiresPrivilege succeeded, we should either:
    // 1. Be under fakeroot, OR
    // 2. Have privilege simulation tools available
    try testing.expect(is_under_fakeroot or ctx.available);
}

test "fakeroot context creation and cleanup" {
    const allocator = testing.allocator;

    // Skip if not on a supported platform
    const platform = privilege_test.Platform.detect();
    if (platform == .other) return error.SkipZigTest;

    // Try to create a fakeroot context
    const context = privilege_test.FakerootContext.init(allocator) catch |err| {
        // If fakeroot is not available, that's expected
        if (err == error.FakerootNotAvailable) return error.SkipZigTest;
        return err;
    };

    // Verify context was created successfully
    try testing.expect(context.platform == privilege_test.Platform.detect());

    // If we're under fakeroot, the context should detect it
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        try testing.expect(context.available);
    }
}

test "nested fakeroot contexts" {
    const allocator = testing.allocator;

    // Skip if already under fakeroot (can't nest)
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        return error.SkipZigTest;
    }

    // Try to create first context
    const context1 = privilege_test.FakerootContext.init(allocator) catch |err| {
        if (err == error.FakerootNotAvailable) return error.SkipZigTest;
        return err;
    };

    // Creating a second context should succeed - it just detects available tools
    // The actual nesting protection happens when trying to execute under fakeroot
    const context2 = try privilege_test.FakerootContext.init(allocator);

    // Both contexts should have the same configuration
    try testing.expect(context1.platform == context2.platform);
    try testing.expect(context1.method == context2.method);
    try testing.expect(context1.available == context2.available);
}

test "privileged: environment variable propagation" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    var utils = TestUtils.init(allocator);
    defer utils.deinit();

    // Create environment map
    var env_map = try process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("TEST_PRIVILEGE_VAR", "test_value");

    // Run a child process with an environment variable
    const result = try process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", "echo $TEST_PRIVILEGE_VAR" },
        .env_map = &env_map,
    });

    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "test_value") != null);
}

test "privileged: file permission operations" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    var utils = TestUtils.init(allocator);
    defer utils.deinit();

    const temp_dir = try utils.getTempDir();
    const temp_dir_handle = temp_dir.dir;

    // Create a test file
    const test_file = try temp_dir_handle.createFile("test_perms.txt", .{});
    test_file.close();

    // Change permissions to 0600
    const file_handle = try temp_dir_handle.openFile("test_perms.txt", .{});
    defer file_handle.close();
    try file_handle.chmod(0o600);

    // Verify permissions
    const stat = try temp_dir_handle.statFile("test_perms.txt");
    const mode = stat.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o600), mode);

    // Change to 0755
    try file_handle.chmod(0o755);

    // Verify new permissions
    const stat2 = try temp_dir_handle.statFile("test_perms.txt");
    const mode2 = stat2.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o755), mode2);
}

test "privileged: directory permission operations" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    var utils = TestUtils.init(allocator);
    defer utils.deinit();

    const temp_dir = try utils.getTempDir();
    const temp_dir_handle = temp_dir.dir;

    // Create a test directory
    try temp_dir_handle.makeDir("test_dir");

    // Change permissions to 0700
    // Note: We need to use external chmod command for directories
    const temp_path = try temp_dir_handle.realpathAlloc(allocator, ".");
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/test_dir", .{temp_path});

    const chmod_result = try utils.runCommand(&[_][]const u8{
        "chmod", "700", dir_path,
    }, common.null_writer, common.null_writer);

    // Verify permissions
    const stat = try temp_dir_handle.statFile("test_dir");
    const mode = stat.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o700), mode);

    // Change to 0755
    const chmod_result2 = try utils.runCommand(&[_][]const u8{
        "chmod", "755", dir_path,
    }, common.null_writer, common.null_writer);

    // Verify new permissions
    const stat2 = try temp_dir_handle.statFile("test_dir");
    const mode2 = stat2.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o755), mode2);
}

// Test helper for cross-utility tests
pub fn testCrossUtilityWorkflow(allocator: std.mem.Allocator, stdout_writer: anytype, stderr_writer: anytype) !void {
    var utils = TestUtils.init(allocator);
    defer utils.deinit();

    const temp_dir = try utils.getTempDir();
    const temp_dir_handle = temp_dir.dir;
    const temp_path = try temp_dir_handle.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);

    // Create a directory with mkdir
    const mkdir_path = try TestUtils.getBinaryPath(allocator, "mkdir");
    defer allocator.free(mkdir_path);
    const secure_dir_path = try std.fmt.allocPrint(allocator, "{s}/secure_dir", .{temp_path});
    defer allocator.free(secure_dir_path);

    const mkdir_result = try utils.runCommand(&[_][]const u8{
        mkdir_path,
        "-m",
        "700",
        secure_dir_path,
    }, stdout_writer, stderr_writer);
    defer allocator.free(mkdir_result.stdout);
    defer allocator.free(mkdir_result.stderr);

    try testing.expect(mkdir_result.term.Exited == 0);

    // Verify with ls
    const ls_path = try TestUtils.getBinaryPath(allocator, "ls");
    defer allocator.free(ls_path);

    const ls_result = try utils.runCommand(&[_][]const u8{
        ls_path,
        "-la",
        temp_path,
    }, stdout_writer, stderr_writer);
    defer allocator.free(ls_result.stdout);
    defer allocator.free(ls_result.stderr);

    try testing.expect(ls_result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, ls_result.stdout, "secure_dir") != null);
}
