//! false - do nothing, unsuccessfully
//!
//! The false utility always exits with status 1, produces no output, and ignores all arguments.
//! This is the simplest possible system utility - it literally does nothing except fail.
//!
//! POSIX-compliant implementation compatible with GNU coreutils.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Main entry point for the false utility
pub fn runFalse(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = allocator; // unused
    _ = args; // false ignores all arguments
    _ = stdout_writer; // false produces no output
    _ = stderr_writer; // false produces no output

    // Always return 1 (failure)
    return @intFromEnum(common.ExitCode.general_error);
}

/// Standard main function
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runFalse(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

// ============================================================================
// TESTS
// ============================================================================

test "false always returns 1 and ignores all arguments" {
    // Test various argument patterns - false should always return 1
    const test_cases = [_][]const []const u8{
        &.{}, // no arguments
        &.{"--help"},
        &.{"--version"},
        &.{ "some", "random", "arguments" },
        &.{ "-h", "-v", "--anything" },
        &.{ "arg1", "arg2", "arg3", "--flag", "-f", "value", "--another=flag" },
    };

    for (test_cases) |args| {
        const result = try runFalse(testing.allocator, args, common.null_writer, common.null_writer);
        try testing.expectEqual(@as(u8, 1), result);
    }
}

test "false produces no output" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Test with no arguments
    _ = try runFalse(testing.allocator, &.{}, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);

    // Clear buffers and test with arguments
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    _ = try runFalse(testing.allocator, &.{ "--help", "--version", "test" }, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("false");

test "false fuzz basic" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testFalseBasic, .{});
}

fn testFalseBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("false")) return;

    try common.fuzz.testUtilityBasic(runFalse, allocator, input, common.null_writer);
}

test "false fuzz deterministic" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testFalseDeterministic, .{});
}

fn testFalseDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("false")) return;

    try common.fuzz.testUtilityDeterministic(runFalse, allocator, input, common.null_writer);
}

test "false fuzz invariant properties" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testFalseInvariants, .{});
}

fn testFalseInvariants(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("false")) return;

    var arg_storage = common.fuzz.ArgStorage.init();
    const args = common.fuzz.generateArgs(&arg_storage, input);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    const result = try runFalse(allocator, args, stdout_buf.writer(), stderr_buf.writer());

    // Invariant properties of false:
    try testing.expectEqual(@as(u8, 1), result); // Always returns 1
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len); // Never writes to stdout
    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len); // Never writes to stderr
}
