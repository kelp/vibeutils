//! Streamlined fuzz tests for ln utility
//!
//! Ln creates links between files and should handle various link scenarios gracefully.
//! Tests verify the utility processes link operations correctly without panicking.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const ln_util = @import("ln.zig");

// Create standardized fuzz tests using the unified builder
const LnFuzzTests = common.fuzz.createUtilityFuzzTests(ln_util.runLn);

test "ln fuzz basic" {
    try std.testing.fuzz(testing.allocator, LnFuzzTests.testBasic, .{});
}

test "ln fuzz paths" {
    try std.testing.fuzz(testing.allocator, LnFuzzTests.testPaths, .{});
}

test "ln fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, LnFuzzTests.testDeterministic, .{});
}

test "ln fuzz symbolic links" {
    try std.testing.fuzz(testing.allocator, testLnSymbolicLinks, .{});
}

fn testLnSymbolicLinks(allocator: std.mem.Allocator, input: []const u8) !void {
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

    _ = ln_util.runLn(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Permission denied, file exists, etc. are acceptable
        return;
    };
}

test "ln fuzz force flag" {
    try std.testing.fuzz(testing.allocator, testLnForceFlag, .{});
}

fn testLnForceFlag(allocator: std.mem.Allocator, input: []const u8) !void {
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
        _ = ln_util.runLn(allocator, args, common.null_writer, common.null_writer) catch {
            // All errors are acceptable
            continue;
        };
    }
}

test "ln fuzz multiple targets" {
    try std.testing.fuzz(testing.allocator, testLnMultipleTargets, .{});
}

fn testLnMultipleTargets(allocator: std.mem.Allocator, input: []const u8) !void {
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

    _ = ln_util.runLn(allocator, all_args.items, stdout_buf.writer(), common.null_writer) catch {
        // Directory not found, files not found, etc. are acceptable
        return;
    };
}
