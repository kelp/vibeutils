// Integration test framework for vibeutils
// Run with: zig test src/integration_tests.zig

const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const process = std.process;

const TestCase = struct {
    name: []const u8,
    utility: []const u8,
    args: []const []const u8,
    stdin: ?[]const u8 = null,
    expected_stdout: []const u8,
    expected_stderr: []const u8 = "",
    expected_exit_code: u8 = 0,
};

fn runUtilityTest(allocator: std.mem.Allocator, test_case: TestCase) !void {
    const bin_path = try std.fmt.allocPrint(allocator, "zig-out/bin/{s}", .{test_case.utility});
    defer allocator.free(bin_path);

    // Build arguments
    var args = try std.ArrayList([]const u8).initCapacity(allocator, test_case.args.len + 1);
    defer args.deinit(allocator);
    try args.append(allocator, bin_path);
    for (test_case.args) |arg| {
        try args.append(allocator, arg);
    }

    // Run the utility
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .stdin = if (test_case.stdin) |input| .{ .bytes = input } else null,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check results
    try testing.expectEqualStrings(test_case.expected_stdout, result.stdout);
    try testing.expectEqualStrings(test_case.expected_stderr, result.stderr);
    try testing.expectEqual(test_case.expected_exit_code, result.term.Exited);
}

test "echo: basic output" {
    try runUtilityTest(testing.allocator, .{
        .name = "echo basic",
        .utility = "echo",
        .args = &.{ "hello", "world" },
        .expected_stdout = "hello world\n",
    });
}

test "echo: no newline flag" {
    try runUtilityTest(testing.allocator, .{
        .name = "echo -n",
        .utility = "echo",
        .args = &.{ "-n", "test" },
        .expected_stdout = "test",
    });
}

test "true: returns 0" {
    try runUtilityTest(testing.allocator, .{
        .name = "true",
        .utility = "true",
        .args = &.{},
        .expected_stdout = "",
        .expected_exit_code = 0,
    });
}

test "false: returns 1" {
    try runUtilityTest(testing.allocator, .{
        .name = "false",
        .utility = "false",
        .args = &.{},
        .expected_stdout = "",
        .expected_exit_code = 1,
    });
}

test "basename: basic path" {
    try runUtilityTest(testing.allocator, .{
        .name = "basename",
        .utility = "basename",
        .args = &.{"/usr/bin/test"},
        .expected_stdout = "test\n",
    });
}

test "dirname: basic path" {
    try runUtilityTest(testing.allocator, .{
        .name = "dirname",
        .utility = "dirname",
        .args = &.{"/usr/bin/test"},
        .expected_stdout = "/usr/bin\n",
    });
}

test "cat: with stdin" {
    try runUtilityTest(testing.allocator, .{
        .name = "cat stdin",
        .utility = "cat",
        .args = &.{},
        .stdin = "line1\nline2\nline3\n",
        .expected_stdout = "line1\nline2\nline3\n",
    });
}

test "head: first 2 lines from stdin" {
    try runUtilityTest(testing.allocator, .{
        .name = "head -n 2",
        .utility = "head",
        .args = &.{ "-n", "2" },
        .stdin = "line1\nline2\nline3\nline4\nline5\n",
        .expected_stdout = "line1\nline2\n",
    });
}

test "tail: last 2 lines from stdin" {
    try runUtilityTest(testing.allocator, .{
        .name = "tail -n 2",
        .utility = "tail",
        .args = &.{ "-n", "2" },
        .stdin = "line1\nline2\nline3\nline4\nline5\n",
        .expected_stdout = "line4\nline5\n",
    });
}

test "tail: last 10 bytes from stdin" {
    try runUtilityTest(testing.allocator, .{
        .name = "tail -c 10",
        .utility = "tail",
        .args = &.{ "-c", "10" },
        .stdin = "abcdefghijklmnopqrstuvwxyz",
        .expected_stdout = "qrstuvwxyz",
    });
}

// Test framework for file-based utilities
fn withTempFile(allocator: std.mem.Allocator, content: []const u8, comptime testFn: fn (allocator: std.mem.Allocator, path: []const u8) anyerror!void) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_path = try fs.path.join(allocator, &.{ "zig-cache", "tmp", tmp_dir.sub_path, "test_file.txt" });
    defer allocator.free(file_path);

    const file = try tmp_dir.dir.createFile("test_file.txt", .{});
    defer file.close();
    try file.writeAll(content);

    try testFn(allocator, file_path);
}

test "cp: basic file copy" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file
    const src_file = try tmp_dir.dir.createFile("source.txt", .{});
    try src_file.writeAll("test content");
    src_file.close();

    const src_path = try fs.path.join(testing.allocator, &.{ "zig-cache", "tmp", tmp_dir.sub_path, "source.txt" });
    defer testing.allocator.free(src_path);
    const dst_path = try fs.path.join(testing.allocator, &.{ "zig-cache", "tmp", tmp_dir.sub_path, "dest.txt" });
    defer testing.allocator.free(dst_path);

    // Run cp
    try runUtilityTest(testing.allocator, .{
        .name = "cp",
        .utility = "cp",
        .args = &.{ src_path, dst_path },
        .expected_stdout = "",
    });

    // Verify destination file exists and has correct content
    const dst_file = try tmp_dir.dir.openFile("dest.txt", .{});
    defer dst_file.close();
    var buffer: [100]u8 = undefined;
    const bytes_read = try dst_file.read(&buffer);
    try testing.expectEqualStrings("test content", buffer[0..bytes_read]);
}

test "mkdir: create directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try fs.path.join(testing.allocator, &.{ "zig-cache", "tmp", tmp_dir.sub_path, "new_dir" });
    defer testing.allocator.free(dir_path);

    try runUtilityTest(testing.allocator, .{
        .name = "mkdir",
        .utility = "mkdir",
        .args = &.{dir_path},
        .expected_stdout = "",
    });

    // Verify directory exists
    var dir = try tmp_dir.dir.openDir("new_dir", .{});
    dir.close();
}

test "touch: create file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_path = try fs.path.join(testing.allocator, &.{ "zig-cache", "tmp", tmp_dir.sub_path, "new_file.txt" });
    defer testing.allocator.free(file_path);

    try runUtilityTest(testing.allocator, .{
        .name = "touch",
        .utility = "touch",
        .args = &.{file_path},
        .expected_stdout = "",
    });

    // Verify file exists
    var file = try tmp_dir.dir.openFile("new_file.txt", .{});
    file.close();
}

// Performance benchmarks
const BenchmarkResult = struct {
    utility: []const u8,
    operation: []const u8,
    iterations: usize,
    total_ns: u64,
    avg_ns: u64,
};

fn benchmarkUtility(allocator: std.mem.Allocator, utility: []const u8, args: []const []const u8, iterations: usize) !BenchmarkResult {
    const bin_path = try std.fmt.allocPrint(allocator, "zig-out/bin/{s}", .{utility});
    defer allocator.free(bin_path);

    var all_args = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer all_args.deinit(allocator);
    try all_args.append(allocator, bin_path);
    for (args) |arg| {
        try all_args.append(allocator, arg);
    }

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = all_args.items,
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const end = std.time.nanoTimestamp();

    const total_ns = @as(u64, @intCast(end - start));
    return BenchmarkResult{
        .utility = utility,
        .operation = "basic",
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = total_ns / iterations,
    };
}

test "benchmark: echo performance" {
    if (std.os.getenv("RUN_BENCHMARKS") == null) {
        return error.SkipZigTest;
    }

    const result = try benchmarkUtility(testing.allocator, "echo", &.{"test"}, 100);
    std.debug.print("\nBenchmark: {s} - {d} iterations in {d}ms (avg {d}µs)\n", .{
        result.utility,
        result.iterations,
        result.total_ns / 1_000_000,
        result.avg_ns / 1_000,
    });
}
