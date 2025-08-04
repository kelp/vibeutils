//! Streamlined fuzz tests for test utility
//!
//! Test evaluates conditional expressions and returns appropriate exit codes.
//! Tests verify the utility handles various condition formats gracefully.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const test_util = @import("test.zig");

// Create standardized fuzz tests using the unified builder
const TestFuzzTests = common.fuzz.createUtilityFuzzTests(test_util.runUtility);

test "test fuzz basic" {
    try std.testing.fuzz(testing.allocator, TestFuzzTests.testBasic, .{});
}

test "test fuzz paths" {
    try std.testing.fuzz(testing.allocator, TestFuzzTests.testPaths, .{});
}

test "test fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, TestFuzzTests.testDeterministic, .{});
}

test "test fuzz file conditions" {
    try std.testing.fuzz(testing.allocator, testFileConditions, .{});
}

fn testFileConditions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Generate file test conditions
    const file_tests = [_][]const u8{
        "-e", "-f", "-d", "-r", "-w", "-x", "-s", "-L", "-S", "-p", "-b", "-c",
    };

    const test_flag = file_tests[input[0] % file_tests.len];

    // Generate a test file path
    const file_path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(file_path);

    const args = [_][]const u8{ test_flag, file_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = test_util.runUtility(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // All file test results are acceptable
        return;
    };
}

test "test fuzz string conditions" {
    try std.testing.fuzz(testing.allocator, testStringConditions, .{});
}

fn testStringConditions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate string test conditions
    const string_tests = [_][]const []const u8{
        &.{ "-z", "str" }, // Empty string
        &.{ "-n", "str" }, // Non-empty string
        &.{ "str1", "=", "str2" }, // String equality
        &.{ "str1", "!=", "str2" }, // String inequality
        &.{ "str1", "<", "str2" }, // String less than
        &.{ "str1", ">", "str2" }, // String greater than
    };

    const test_args = string_tests[input[0] % string_tests.len];

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = test_util.runUtility(allocator, test_args, stdout_buf.writer(), common.null_writer) catch {
        // All string test results are acceptable
        return;
    };
}

test "test fuzz numeric conditions" {
    try std.testing.fuzz(testing.allocator, testNumericConditions, .{});
}

fn testNumericConditions(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate numeric test conditions
    const numeric_tests = [_][]const []const u8{
        &.{ "5", "-eq", "5" }, // Equal
        &.{ "5", "-ne", "3" }, // Not equal
        &.{ "5", "-lt", "10" }, // Less than
        &.{ "5", "-le", "5" }, // Less than or equal
        &.{ "5", "-gt", "3" }, // Greater than
        &.{ "5", "-ge", "5" }, // Greater than or equal
    };

    const test_args = numeric_tests[input[0] % numeric_tests.len];

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = test_util.runUtility(allocator, test_args, stdout_buf.writer(), common.null_writer) catch {
        // All numeric test results are acceptable
        return;
    };
}
