//! true - return a successful exit status
//!
//! The true utility always exits with status 0 (success) and produces no output.
//! According to POSIX.1-2017, it ignores all command-line arguments.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Main entry point for the true utility
/// Always returns success (0) regardless of arguments, following POSIX specification
pub fn runTrue(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = allocator; // Unused
    _ = args; // All arguments ignored per POSIX
    _ = stdout_writer; // No output per POSIX
    _ = stderr_writer; // No output per POSIX

    // Always return success - this is the entire POSIX-specified behavior
    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for the true utility
pub fn main() !void {
    // Ultra-minimal implementation - just exit with success
    // No argument parsing, no output, no error handling needed
    std.process.exit(0);
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "true always returns success with no arguments" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runTrue(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items); // No output per POSIX
}

test "true returns success with single argument" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"ignored"};
    const result = try runTrue(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items); // No output per POSIX
}

test "true returns success with multiple arguments" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "foo", "bar", "baz", "with spaces" };
    const result = try runTrue(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items); // No output per POSIX
}

test "true ignores flag-like arguments" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-x", "--invalid", "-flag", "--help", "--version" };
    const result = try runTrue(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items); // No output per POSIX
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("true");

test "true fuzz basic" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testTrueBasic, .{});
}

fn testTrueBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("true")) return;

    try common.fuzz.testUtilityBasic(runTrue, allocator, input, common.null_writer);
}

test "true fuzz deterministic" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testTrueDeterministic, .{});
}

fn testTrueDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("true")) return;

    try common.fuzz.testUtilityDeterministic(runTrue, allocator, input, common.null_writer);
}

test "true fuzz invariant properties" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testTrueInvariants, .{});
}

fn testTrueInvariants(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("true")) return;

    var arg_storage = common.fuzz.ArgStorage.init();
    const args = common.fuzz.generateArgs(&arg_storage, input);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    const result = try runTrue(allocator, args, stdout_buf.writer(), stderr_buf.writer());

    // Invariant properties of true:
    try testing.expectEqual(@as(u8, 0), result); // Always returns 0
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len); // Never writes to stdout
    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len); // Never writes to stderr
}
