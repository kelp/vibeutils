//! Fuzz tests for chown utility using std.testing.fuzz()
//!
//! These tests use Zig's native fuzzing API to test chown with random inputs.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const chown = @import("chown.zig");

test "chown fuzz arguments" {
    try std.testing.fuzz(testing.allocator, testChownWithFuzzedArgs, .{});
}

fn testChownWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Test that chown handles all arguments gracefully
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown.runChown(allocator, args, stdout_buf.writer(), common.null_writer) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "chown fuzz owner specifications" {
    try std.testing.fuzz(testing.allocator, testChownWithOwnerSpecs, .{});
}

fn testChownWithOwnerSpecs(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate various owner:group specifications
    const owner_specs = [_][]const u8{
        "root",       "nobody",     "daemon",           "www-data",
        "1000",       "0",          "65534",            "999999",
        "user:group", "root:wheel", "nobody:nogroup",   ":group",
        ":wheel",     ":1000",      "user:",            "root:",
        "1000:",      "1000:1000",  "0:0",              "65534:65534",
        "",           ":",          "user:group:extra", "invalid_user",
    };

    const owner_spec = owner_specs[input[0] % owner_specs.len];

    // Generate a target file path
    const file_path = try common.fuzz.generatePath(allocator, input[1..]);
    defer allocator.free(file_path);

    const args = [_][]const u8{ owner_spec, file_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown.runChown(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // File not found, invalid user/group, permission denied, etc. are acceptable
        return;
    };
}

test "chown fuzz multiple files" {
    try std.testing.fuzz(testing.allocator, testChownWithMultipleFiles, .{});
}

fn testChownWithMultipleFiles(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate owner specification
    const owner_specs = [_][]const u8{ "root", "nobody", "1000", "user:group" };
    const owner_spec = owner_specs[input[0] % owner_specs.len];

    // Generate multiple file paths
    const files = try common.fuzz.generateFileList(allocator, input[1..]);
    defer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    if (files.len == 0) return;

    // Combine owner spec with file paths
    var all_args = std.ArrayList([]const u8).init(allocator);
    defer all_args.deinit();

    try all_args.append(owner_spec);
    for (files) |file| {
        try all_args.append(file);
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown.runChown(allocator, all_args.items, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable when files don't exist or permission denied
        return;
    };
}

test "chown fuzz recursive flag" {
    try std.testing.fuzz(testing.allocator, testChownWithRecursiveFlag, .{});
}

fn testChownWithRecursiveFlag(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate owner specification
    const owner_specs = [_][]const u8{ "root", "nobody", "1000:1000" };
    const owner_spec = owner_specs[input[0] % owner_specs.len];

    // Generate a directory path
    const dir_path = try common.fuzz.generatePath(allocator, input[1..]);
    defer allocator.free(dir_path);

    const args = [_][]const u8{ "-R", owner_spec, dir_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown.runChown(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Directory not found, permission errors, etc. are acceptable
        return;
    };
}

test "chown fuzz reference file" {
    try std.testing.fuzz(testing.allocator, testChownWithReferenceFile, .{});
}

fn testChownWithReferenceFile(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 4) return;

    // Split input for reference file and target file
    const mid = input.len / 2;
    const ref_file = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(ref_file);

    const target_file = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(target_file);

    const args = [_][]const u8{ "--reference", ref_file, target_file };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown.runChown(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Reference file not found, target not found, etc. are acceptable
        return;
    };
}

test "chown fuzz symbolic links" {
    try std.testing.fuzz(testing.allocator, testChownWithSymbolicLinks, .{});
}

fn testChownWithSymbolicLinks(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate symlink chain
    const symlink_chain = try common.fuzz.generateSymlinkChain(allocator, input);
    defer {
        for (symlink_chain) |link| allocator.free(link);
        allocator.free(symlink_chain);
    }

    if (symlink_chain.len == 0) return;

    const owner_specs = [_][]const u8{ "root", "nobody", "1000:1000" };
    const owner_spec = owner_specs[input[0] % owner_specs.len];

    // Test both following and not following symlinks
    const test_cases = [_]struct { flags: []const []const u8, link: []const u8 }{
        .{ .flags = &[_][]const u8{}, .link = symlink_chain[0] }, // Default behavior
        .{ .flags = &[_][]const u8{"-h"}, .link = symlink_chain[0] }, // Don't follow symlinks
        .{ .flags = &[_][]const u8{"-H"}, .link = symlink_chain[0] }, // Follow command line symlinks
        .{ .flags = &[_][]const u8{"-L"}, .link = symlink_chain[0] }, // Follow all symlinks
        .{ .flags = &[_][]const u8{"-P"}, .link = symlink_chain[0] }, // Never follow symlinks
    };

    for (test_cases) |test_case| {
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        for (test_case.flags) |flag| {
            try args.append(flag);
        }
        try args.append(owner_spec);
        try args.append(test_case.link);

        _ = chown.runChown(allocator, args.items, common.null_writer, common.null_writer) catch {
            // All errors are acceptable in fuzzing
            continue;
        };
    }
}

test "chown fuzz edge cases" {
    try std.testing.fuzz(testing.allocator, testChownEdgeCases, .{});
}

fn testChownEdgeCases(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Test various edge cases based on input
    const edge_case = input[0] % 10;
    const remaining = if (input.len > 1) input[1..] else &[_]u8{};

    switch (edge_case) {
        0 => {
            // No arguments
            const args = [_][]const u8{};
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        1 => {
            // Only owner spec, no file
            const args = [_][]const u8{"root"};
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        2 => {
            // Empty owner spec
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ "", file_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        3 => {
            // Invalid numeric IDs
            const invalid_ids = [_][]const u8{ "-1", "999999999999", "abc", "1a2b", ":" };
            const invalid_id = invalid_ids[if (remaining.len > 0) remaining[0] % invalid_ids.len else 0];
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ invalid_id, file_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        4 => {
            // Special file paths
            const special_paths = [_][]const u8{ "/", "/dev/null", "/tmp", ".", "..", "~", "/proc/self" };
            const special_path = special_paths[if (remaining.len > 0) remaining[0] % special_paths.len else 0];
            const args = [_][]const u8{ "root", special_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        5 => {
            // Very long owner specification
            var long_owner = std.ArrayList(u8).init(allocator);
            defer long_owner.deinit();
            for (0..1000) |i| {
                try long_owner.append('a' + @as(u8, @intCast(i % 26)));
            }
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ long_owner.items, file_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        6 => {
            // Unicode in owner names
            const unicode_owners = [_][]const u8{ "用户", "ユーザー", "пользователь", "مستخدم" };
            const unicode_owner = unicode_owners[if (remaining.len > 0) remaining[0] % unicode_owners.len else 0];
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ unicode_owner, file_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        7 => {
            // Multiple colons in owner spec
            const multi_colon_specs = [_][]const u8{ "a:b:c", ":::", "user:group:extra:data" };
            const spec = multi_colon_specs[if (remaining.len > 0) remaining[0] % multi_colon_specs.len else 0];
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ spec, file_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        8 => {
            // Conflicting flags
            const file_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(file_path);
            const args = [_][]const u8{ "-H", "-L", "-P", "root", file_path };
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        else => {
            // Help flag
            const args = [_][]const u8{"--help"};
            _ = chown.runChown(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
    }
}

test "chown fuzz deterministic property" {
    try std.testing.fuzz(testing.allocator, testChownDeterministic, .{});
}

fn testChownDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Run chown twice with same input
    var buffer1 = std.ArrayList(u8).init(allocator);
    defer buffer1.deinit();
    var buffer2 = std.ArrayList(u8).init(allocator);
    defer buffer2.deinit();

    const result1 = chown.runChown(allocator, args, buffer1.writer(), common.null_writer) catch |err| {
        // If first fails, second should also fail
        const result2 = chown.runChown(allocator, args, buffer2.writer(), common.null_writer) catch {
            return; // Both failed, that's consistent
        };
        _ = result2;
        return err; // First failed but second succeeded - inconsistent!
    };

    const result2 = chown.runChown(allocator, args, buffer2.writer(), common.null_writer) catch {
        return error.InconsistentBehavior; // First succeeded but second failed
    };

    // Property: same input produces same output and exit code
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}
