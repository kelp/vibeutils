//! Fuzz tests for ln utility using std.testing.fuzz()
//!
//! These tests use Zig's native fuzzing API to test ln with random inputs.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const ln = @import("ln.zig");

test "ln fuzz arguments" {
    try std.testing.fuzz(testing.allocator, testLnWithFuzzedArgs, .{});
}

fn testLnWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Test that ln handles all arguments gracefully
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ln.runLn(allocator, args, stdout_buf.writer(), common.null_writer) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "ln fuzz hard links" {
    try std.testing.fuzz(testing.allocator, testLnWithHardLinks, .{});
}

fn testLnWithHardLinks(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Split input for source and target
    const mid = input.len / 2;
    const source_path = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(source_path);

    const target_path = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(target_path);

    // Test hard link creation
    const args = [_][]const u8{ source_path, target_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ln.runLn(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Source not found, cross-device link, permission denied, etc. are acceptable
        return;
    };
}

test "ln fuzz symbolic links" {
    try std.testing.fuzz(testing.allocator, testLnWithSymbolicLinks, .{});
}

fn testLnWithSymbolicLinks(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Split input for source and target
    const mid = input.len / 2;
    const source_path = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(source_path);

    const target_path = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(target_path);

    // Test symbolic link creation
    const args = [_][]const u8{ "-s", source_path, target_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ln.runLn(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Permission denied, file exists, etc. are acceptable
        return;
    };
}

test "ln fuzz symbolic link chains" {
    try std.testing.fuzz(testing.allocator, testLnWithSymlinkChains, .{});
}

fn testLnWithSymlinkChains(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate complex symlink patterns
    const symlink_chain = try common.fuzz.generateSymlinkChain(allocator, input);
    defer {
        for (symlink_chain) |link| allocator.free(link);
        allocator.free(symlink_chain);
    }

    if (symlink_chain.len < 2) return;

    // Create links to existing symlinks
    const source = symlink_chain[0];
    const target = symlink_chain[1];

    const args = [_][]const u8{ "-s", source, target };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ln.runLn(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Any error is acceptable (loops, broken links, etc.)
        return;
    };
}

test "ln fuzz multiple targets" {
    try std.testing.fuzz(testing.allocator, testLnWithMultipleTargets, .{});
}

fn testLnWithMultipleTargets(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 4) return;

    // Generate source file
    const source_input = input[0 .. input.len / 4];
    const source_path = try common.fuzz.generatePath(allocator, source_input);
    defer allocator.free(source_path);

    // Generate directory for target
    const dir_input = input[input.len / 4 .. input.len / 2];
    const target_dir = try common.fuzz.generatePath(allocator, dir_input);
    defer allocator.free(target_dir);

    // Generate multiple additional sources
    const files = try common.fuzz.generateFileList(allocator, input[input.len / 2 ..]);
    defer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    if (files.len == 0) return;

    // Combine all sources + target directory
    var all_args = std.ArrayList([]const u8).init(allocator);
    defer all_args.deinit();

    try all_args.append(source_path);
    for (files) |file| {
        try all_args.append(file);
    }
    try all_args.append(target_dir);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ln.runLn(allocator, all_args.items, stdout_buf.writer(), common.null_writer) catch {
        // Directory not found, files not found, etc. are acceptable
        return;
    };
}

test "ln fuzz force flag" {
    try std.testing.fuzz(testing.allocator, testLnWithForceFlag, .{});
}

fn testLnWithForceFlag(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Split input for source and target
    const mid = input.len / 2;
    const source_path = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(source_path);

    const target_path = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(target_path);

    // Test force flag with both hard and symbolic links
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ "-f", source_path, target_path },
        &[_][]const u8{ "-sf", source_path, target_path },
        &[_][]const u8{ "-fs", source_path, target_path },
        &[_][]const u8{ "--force", source_path, target_path },
        &[_][]const u8{ "-s", "--force", source_path, target_path },
    };

    for (test_cases) |args| {
        _ = ln.runLn(allocator, args, common.null_writer, common.null_writer) catch {
            // All errors are acceptable
            continue;
        };
    }
}

test "ln fuzz interactive flag" {
    try std.testing.fuzz(testing.allocator, testLnWithInteractiveFlag, .{});
}

fn testLnWithInteractiveFlag(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Split input for source and target
    const mid = input.len / 2;
    const source_path = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(source_path);

    const target_path = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(target_path);

    // Test interactive flag (should not hang in fuzzing)
    const args = [_][]const u8{ "-i", source_path, target_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = ln.runLn(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Interactive mode may fail in non-interactive environment
        return;
    };
}

test "ln fuzz edge cases" {
    try std.testing.fuzz(testing.allocator, testLnEdgeCases, .{});
}

fn testLnEdgeCases(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Test various edge cases based on input
    const edge_case = input[0] % 12;
    const remaining = if (input.len > 1) input[1..] else &[_]u8{};

    switch (edge_case) {
        0 => {
            // No arguments
            const args = [_][]const u8{};
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        1 => {
            // Only one argument
            const source_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(source_path);
            const args = [_][]const u8{source_path};
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        2 => {
            // Empty paths
            const args = [_][]const u8{ "", "" };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        3 => {
            // Same source and target
            const path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(path);
            const args = [_][]const u8{ path, path };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        4 => {
            // Special paths
            const special_paths = [_][2][]const u8{
                .{ "/", "/tmp/root_link" },
                .{ "/dev/null", "/tmp/null_link" },
                .{ ".", "/tmp/dot_link" },
                .{ "..", "/tmp/dotdot_link" },
                .{ "/proc/self", "/tmp/self_link" },
            };
            const special = special_paths[if (remaining.len > 0) remaining[0] % special_paths.len else 0];
            const args = [_][]const u8{ special[0], special[1] };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        5 => {
            // Very long paths
            var long_path = std.ArrayList(u8).init(allocator);
            defer long_path.deinit();
            for (0..4000) |i| {
                try long_path.append('a' + @as(u8, @intCast(i % 26)));
            }
            const target_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(target_path);
            const args = [_][]const u8{ long_path.items, target_path };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        6 => {
            // Unicode paths
            const unicode_paths = [_][2][]const u8{
                .{ "文件.txt", "链接.txt" },
                .{ "ファイル.txt", "リンク.txt" },
                .{ "файл.txt", "ссылка.txt" },
                .{ "ملف.txt", "رابط.txt" },
            };
            const unicode = unicode_paths[if (remaining.len > 0) remaining[0] % unicode_paths.len else 0];
            const args = [_][]const u8{ unicode[0], unicode[1] };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        7 => {
            // Paths with special characters
            const special_char_paths = [_][2][]const u8{
                .{ "file with spaces", "link with spaces" },
                .{ "file\nwith\nnewlines", "link\nwith\nnewlines" },
                .{ "file\twith\ttabs", "link\twith\ttabs" },
                .{ "file'with\"quotes", "link'with\"quotes" },
                .{ "file\\with\\backslashes", "link\\with\\backslashes" },
            };
            const special = special_char_paths[if (remaining.len > 0) remaining[0] % special_char_paths.len else 0];
            const args = [_][]const u8{ special[0], special[1] };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        8 => {
            // Directory linking
            const source_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(source_path);
            const args = [_][]const u8{ source_path, "/tmp/dir_link" };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        9 => {
            // Conflicting flags
            const source_path = try common.fuzz.generatePath(allocator, remaining);
            defer allocator.free(source_path);
            const target_path = try std.fmt.allocPrint(allocator, "{s}_target", .{source_path});
            defer allocator.free(target_path);
            const args = [_][]const u8{ "-f", "-i", "-s", source_path, target_path };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        10 => {
            // Absolute vs relative paths
            const abs_path = try std.fmt.allocPrint(allocator, "/tmp/abs_{}", .{remaining.len});
            defer allocator.free(abs_path);
            const rel_path = try std.fmt.allocPrint(allocator, "rel_{}", .{remaining.len});
            defer allocator.free(rel_path);
            const args = [_][]const u8{ "-s", abs_path, rel_path };
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
        else => {
            // Help flag
            const args = [_][]const u8{"--help"};
            _ = ln.runLn(allocator, &args, common.null_writer, common.null_writer) catch return;
        },
    }
}

test "ln fuzz deterministic property" {
    try std.testing.fuzz(testing.allocator, testLnDeterministic, .{});
}

fn testLnDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Run ln twice with same input
    var buffer1 = std.ArrayList(u8).init(allocator);
    defer buffer1.deinit();
    var buffer2 = std.ArrayList(u8).init(allocator);
    defer buffer2.deinit();

    const result1 = ln.runLn(allocator, args, buffer1.writer(), common.null_writer) catch |err| {
        // If first fails, second should also fail
        const result2 = ln.runLn(allocator, args, buffer2.writer(), common.null_writer) catch {
            return; // Both failed, that's consistent
        };
        _ = result2;
        return err; // First failed but second succeeded - inconsistent!
    };

    const result2 = ln.runLn(allocator, args, buffer2.writer(), common.null_writer) catch {
        return error.InconsistentBehavior; // First succeeded but second failed
    };

    // Property: same input produces same output and exit code
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}
