//! Fuzz tests for chmod utility using std.testing.fuzz()
//!
//! These tests use Zig's native fuzzing API to test chmod with random inputs.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const chmod = @import("chmod.zig");

test "chmod fuzz arguments" {
    try std.testing.fuzz(testing.allocator, testChmodWithFuzzedArgs, .{});
}

fn testChmodWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Test that chmod handles all arguments gracefully
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chmod.runChmod(allocator, args, stdout_buf.writer(), common.null_writer) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "chmod fuzz permissions" {
    try std.testing.fuzz(testing.allocator, testChmodWithPermissions, .{});
}

fn testChmodWithPermissions(allocator: std.mem.Allocator, input: []const u8) !void {
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

    _ = chmod.runChmod(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // File not found, invalid permissions, etc. are acceptable
        return;
    };
}

test "chmod fuzz symbolic permissions" {
    try std.testing.fuzz(testing.allocator, testChmodWithSymbolicPermissions, .{});
}

fn testChmodWithSymbolicPermissions(allocator: std.mem.Allocator, input: []const u8) !void {
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

    _ = chmod.runChmod(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // File not found, invalid permissions, etc. are acceptable
        return;
    };
}

test "chmod fuzz multiple files" {
    try std.testing.fuzz(testing.allocator, testChmodWithMultipleFiles, .{});
}

fn testChmodWithMultipleFiles(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate permission
    const perm = common.fuzz.generateFilePermissions(input[0..1]);
    const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{perm});
    defer allocator.free(perm_str);

    // Generate multiple file paths
    const files = try common.fuzz.generateFileList(allocator, input[1..]);
    defer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    if (files.len == 0) return;

    // Combine permission with file paths
    var all_args = std.ArrayList([]const u8).init(allocator);
    defer all_args.deinit();

    try all_args.append(perm_str);
    for (files) |file| {
        try all_args.append(file);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chmod.runChmod(allocator, all_args.items, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable when files don't exist
        return;
    };
}

test "chmod fuzz recursive flag" {
    try std.testing.fuzz(testing.allocator, testChmodWithRecursiveFlag, .{});
}

fn testChmodWithRecursiveFlag(allocator: std.mem.Allocator, input: []const u8) !void {
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

    _ = chmod.runChmod(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Directory not found, permission errors, etc. are acceptable
        return;
    };
}

test "chmod fuzz edge cases" {
    try std.testing.fuzz(testing.allocator, testChmodEdgeCases, .{});
}

fn testChmodEdgeCases(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Test various edge cases based on input
    const edge_case = input[0] % 8;

    const remaining = if (input.len > 1) input[1..] else &[_]u8{};

    switch (edge_case) {
        0 => {
            // No arguments
            const args = [_][]const u8{};
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        1 => {
            // Only permission, no file
            const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{common.fuzz.generateFilePermissions(remaining)});
            defer allocator.free(perm_str);
            const args = [_][]const u8{perm_str};
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        2 => {
            // Invalid permission format
            const invalid_perms = [_][]const u8{ "999", "rwxrwxrwx", "invalid", "777777", "++++", "====" };
            const perm_str = invalid_perms[if (remaining.len > 0) remaining[0] % invalid_perms.len else 0];
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ perm_str, file_path };
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        3 => {
            // Empty file path
            const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{common.fuzz.generateFilePermissions(remaining)});
            defer allocator.free(perm_str);
            const args = [_][]const u8{ perm_str, "" };
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        4 => {
            // Special file paths
            const special_paths = [_][]const u8{ "/", "/dev/null", "/tmp", ".", "..", "~", "\x00file" };
            const special_path = special_paths[if (remaining.len > 0) remaining[0] % special_paths.len else 0];
            const perm_str = try std.fmt.allocPrint(allocator, "{o}", .{common.fuzz.generateFilePermissions(remaining)});
            defer allocator.free(perm_str);
            const args = [_][]const u8{ perm_str, special_path };
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        5 => {
            // Mixed valid and invalid arguments
            const args = [_][]const u8{ "644", "nonexistent_file", "755", "another_missing_file" };
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        6 => {
            // Very long permission string
            var long_perm = std.ArrayList(u8).init(allocator);
            defer long_perm.deinit();
            for (0..1000) |i| {
                try long_perm.append('0' + @as(u8, @intCast(i % 8)));
            }
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ long_perm.items, file_path };
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        else => {
            // Help flag
            const args = [_][]const u8{"--help"};
            _ = chmod.runChmod(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
    }
}

test "chmod fuzz deterministic property" {
    try std.testing.fuzz(testing.allocator, testChmodDeterministic, .{});
}

fn testChmodDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Run chmod twice with same input
    var buffer1 = std.ArrayList(u8).init(allocator);
    defer buffer1.deinit();
    var buffer2 = std.ArrayList(u8).init(allocator);
    defer buffer2.deinit();

    const result1 = chmod.runChmod(allocator, args, buffer1.writer(), common.null_writer) catch |err| {
        // If first fails, second should also fail
        const result2 = chmod.runChmod(allocator, args, buffer2.writer(), common.null_writer) catch {
            return; // Both failed, that's consistent
        };
        _ = result2;
        return err; // First failed but second succeeded - inconsistent!
    };

    const result2 = chmod.runChmod(allocator, args, buffer2.writer(), common.null_writer) catch {
        return error.InconsistentBehavior; // First succeeded but second failed
    };

    // Property: same input produces same output and exit code
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}
