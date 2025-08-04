//! Streamlined fuzz tests for rmdir utility
//!
//! Rmdir removes empty directories with various flag combinations.
//! Tests verify the utility handles directory removal scenarios gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const rmdir_util = @import("rmdir.zig");

// Create standardized fuzz tests using the unified builder
const RmdirFuzzTests = common.fuzz.createUtilityFuzzTests(rmdir_util.runUtility);

test "rmdir fuzz basic" {
    try std.testing.fuzz(testing.allocator, RmdirFuzzTests.testBasic, .{});
}

test "rmdir fuzz paths" {
    try std.testing.fuzz(testing.allocator, RmdirFuzzTests.testPaths, .{});
}

test "rmdir fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, RmdirFuzzTests.testDeterministic, .{});
}

test "rmdir fuzz parent removal" {
    try std.testing.fuzz(testing.allocator, testRmdirParents, .{});
}

fn testRmdirParents(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate nested directory path
    const nested_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(nested_path);

    // Test with -p flag for parent removal
    const test_cases = [_][]const []const u8{
        &[_][]const u8{ "-p", nested_path },
        &[_][]const u8{ "--parents", nested_path },
        &[_][]const u8{ "-pv", nested_path }, // With verbose
        &[_][]const u8{ "--ignore-fail-on-non-empty", nested_path },
    };

    for (test_cases) |args| {
        var stdout_buf = std.ArrayList(u8).init(allocator);
        defer stdout_buf.deinit();
        var stderr_buf = std.ArrayList(u8).init(allocator);
        defer stderr_buf.deinit();

        _ = rmdir_util.runUtility(allocator, args, stdout_buf.writer(), stderr_buf.writer()) catch {
            // Expected to fail for non-existent or non-empty directories
            continue;
        };
    }
}

test "rmdir fuzz multiple directories" {
    try std.testing.fuzz(testing.allocator, testRmdirMultiple, .{});
}

fn testRmdirMultiple(allocator: std.mem.Allocator, input: []const u8) !void {
    const dirs = try common.fuzz.generateFileList(allocator, input);
    defer {
        for (dirs) |dir| allocator.free(dir);
        allocator.free(dirs);
    }

    if (dirs.len == 0) return;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    _ = rmdir_util.runUtility(allocator, dirs, stdout_buf.writer(), stderr_buf.writer()) catch {
        // Directory conflicts and permission issues are expected
        return;
    };
}
