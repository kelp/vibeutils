//! Streamlined fuzz tests for chmod utility
//!
//! Chmod changes file permissions and should handle all permission formats gracefully.
//! Tests verify the utility processes permissions correctly without panicking.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const chmod_util = @import("chmod.zig");

// Create standardized fuzz tests using the unified builder
const ChmodFuzzTests = common.fuzz.createUtilityFuzzTests(chmod_util.runUtility);

test "chmod fuzz basic" {
    try std.testing.fuzz(testing.allocator, ChmodFuzzTests.testBasic, .{});
}

test "chmod fuzz paths" {
    try std.testing.fuzz(testing.allocator, ChmodFuzzTests.testPaths, .{});
}

test "chmod fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, ChmodFuzzTests.testDeterministic, .{});
}

test "chmod fuzz symbolic permissions" {
    try std.testing.fuzz(testing.allocator, testChmodSymbolicPermissions, .{});
}

fn testChmodSymbolicPermissions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate symbolic permission strings like "u+rwx", "go-w", "a=r"
    const symbolic_perms = [_][]const u8{
        "u+rwx",  "g+rx",        "o+r",        "a+x",
        "u-w",    "g-x",         "o-rwx",      "a-w",
        "u=rwx",  "g=rx",        "o=r",        "a=",
        "+rwx",   "-w",          "=rx",        "u+r,g+w,o+x",
        "a+rw-x", "u=rwx,go=rx", "a-rwx,u+rw",
    };

    const perm_str = symbolic_perms[input[0] % symbolic_perms.len];

    // Generate a target file path
    const file_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(file_path);

    const args = [_][]const u8{ perm_str, file_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chmod_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // File not found, invalid permissions, etc. are acceptable
        return;
    };
}

test "chmod fuzz octal permissions" {
    try std.testing.fuzz(testing.allocator, testChmodOctalPermissions, .{});
}

fn testChmodOctalPermissions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate a file permission from fuzz input
    const perm = common.fuzz.generateFilePermissions(input);
    const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{perm});
    defer allocator.free(perm_str);

    // Generate a target file path
    const file_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(file_path);

    const args = [_][]const u8{ perm_str, file_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chmod_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // File not found, invalid permissions, etc. are acceptable
        return;
    };
}

test "chmod fuzz recursive flag" {
    try std.testing.fuzz(testing.allocator, testChmodRecursive, .{});
}

fn testChmodRecursive(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate permission
    const perm = common.fuzz.generateFilePermissions(input[0..1]);
    const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{perm});
    defer allocator.free(perm_str);

    // Generate a directory path
    const dir_path = try common.fuzz.generatePath(allocator, input[1..]);
    defer allocator.free(dir_path);

    const args = [_][]const u8{ "-R", perm_str, dir_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chmod_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Directory not found, permission errors, etc. are acceptable
        return;
    };
}
