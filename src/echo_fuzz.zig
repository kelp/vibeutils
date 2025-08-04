//! Actual fuzz tests for echo utility using std.testing.fuzz()
//!
//! These tests use Zig's native fuzzing API to test echo with random inputs.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const echo = @import("echo.zig");

test "echo fuzz arguments" {
    // Use std.testing.fuzz to test with random inputs
    try std.testing.fuzz(testing.allocator, testEchoWithFuzzedArgs, .{});
}

fn testEchoWithFuzzedArgs(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate random arguments from fuzz input
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Test that echo handles all arguments gracefully
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = echo.runEcho(allocator, args, stdout_buf.writer(), common.null_writer) catch {
        // Any error is acceptable, panics are not
        return;
    };
}

test "echo fuzz escape sequences" {
    try std.testing.fuzz(testing.allocator, testEchoWithEscapeSequences, .{});
}

fn testEchoWithEscapeSequences(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate escape sequences
    const escape_seq = try common.fuzz.generateEscapeSequence(allocator, input);
    defer allocator.free(escape_seq);

    // Test with -e flag to enable escape processing
    const args = [_][]const u8{ "-e", escape_seq };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = echo.runEcho(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable
        return;
    };
}

test "echo fuzz path arguments" {
    try std.testing.fuzz(testing.allocator, testEchoWithPaths, .{});
}

fn testEchoWithPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate path-like strings that might trigger edge cases
    const path = try common.fuzz.generatePath(allocator, input);
    defer allocator.free(path);

    const args = [_][]const u8{path};

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = echo.runEcho(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Errors are acceptable
        return;
    };
}

test "echo fuzz deterministic property" {
    try std.testing.fuzz(testing.allocator, testEchoDeterministic, .{});
}

fn testEchoDeterministic(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate args once
    const args = try common.fuzz.generateArgs(allocator, input);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Run echo twice with same input
    var buffer1 = std.ArrayList(u8).init(allocator);
    defer buffer1.deinit();
    var buffer2 = std.ArrayList(u8).init(allocator);
    defer buffer2.deinit();

    const result1 = echo.runEcho(allocator, args, buffer1.writer(), common.null_writer) catch |err| {
        // If first fails, second should also fail
        const result2 = echo.runEcho(allocator, args, buffer2.writer(), common.null_writer) catch {
            return; // Both failed, that's consistent
        };
        _ = result2;
        return err; // First failed but second succeeded - inconsistent!
    };

    const result2 = echo.runEcho(allocator, args, buffer2.writer(), common.null_writer) catch {
        return error.InconsistentBehavior; // First succeeded but second failed
    };

    // Property: same input produces same output
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}
