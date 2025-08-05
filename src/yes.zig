//! yes utility - Repeatedly output a line with all specified strings, or 'y'.
//!
//! This is a clean, efficient implementation of the yes command with modern
//! enhancements including arena-based memory management and comprehensive testing.
//!
//! The utility outputs specified strings (or 'y' by default) repeatedly until
//! the output pipe is broken (SIGPIPE), which it handles gracefully by exiting
//! with success status.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Arguments structure for the yes utility.
const YesArgs = struct {
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},
};

/// Limited writer that simulates BrokenPipe after writing a certain amount.
/// Used for testing to avoid infinite output loops.
const LimitedWriter = struct {
    buffer: *std.ArrayList(u8),
    limit: usize,
    written: usize = 0,

    pub fn write(self: *@This(), bytes: []const u8) !usize {
        if (self.written >= self.limit) {
            return error.BrokenPipe; // Simulate SIGPIPE
        }
        const to_write = @min(bytes.len, self.limit - self.written);
        try self.buffer.appendSlice(bytes[0..to_write]);
        self.written += to_write;
        if (self.written >= self.limit) {
            return error.BrokenPipe;
        }
        return to_write;
    }

    pub fn writer(self: *@This()) std.io.Writer(*@This(), error{ BrokenPipe, OutOfMemory }, write) {
        return .{ .context = self };
    }
};

/// Main function for the yes utility.
/// Repeatedly outputs a line with all specified strings, or 'y' if no arguments provided.
/// Uses arena allocator for memory management as per CLI tool best practices.
pub fn runYes(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // Use arena allocator for CLI tool memory management
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Parse arguments using common argparse
    const parsed_args = common.argparse.ArgParser.parse(YesArgs, arena_allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(arena_allocator, stderr_writer, "yes", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };

    // Handle help flag
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Build output string using std.mem.join for simplicity
    const output_str = blk: {
        if (parsed_args.positionals.len == 0) {
            break :blk "y\n";
        } else {
            // Join all arguments with space and add newline
            const joined = try std.mem.join(arena_allocator, " ", parsed_args.positionals);
            const with_newline = try std.fmt.allocPrint(arena_allocator, "{s}\n", .{joined});
            break :blk with_newline;
        }
    };

    // Create a larger buffer for efficient output
    const buffer_size = 8192;
    var buffer = try arena_allocator.alloc(u8, buffer_size);

    // Fill buffer with repeated string
    var pos: usize = 0;
    while (pos + output_str.len <= buffer_size) {
        @memcpy(buffer[pos..][0..output_str.len], output_str);
        pos += output_str.len;
    }

    // Output forever
    while (true) {
        stdout_writer.writeAll(buffer[0..pos]) catch {
            // Any write error (including BrokenPipe) is expected when piping to head, etc.
            // yes traditionally exits silently on write errors
            return @intFromEnum(common.ExitCode.success);
        };
    }
}

/// Prints help text for the yes utility.
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: yes [STRING]...
        \\   or: yes [OPTION]
        \\
        \\Repeatedly output a line with all specified STRING(s), or 'y'.
        \\
        \\Options:
        \\  -h, --help     Display this help and exit
        \\  -V, --version  Output version information and exit
        \\
        \\Examples:
        \\  yes              # Output 'y' repeatedly
        \\  yes hello        # Output 'hello' repeatedly
        \\  yes hello world  # Output 'hello world' repeatedly
        \\
    );
}

/// Prints version information for the yes utility.
fn printVersion(writer: anytype) !void {
    try writer.writeAll("yes (vibeutils) 0.1.0\n");
    try writer.writeAll("Copyright (C) 2024 vibeutils authors\n");
    try writer.writeAll("License: MIT\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runYes(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Helper function to create test buffers and run yes with limited output.
fn testYesWithLimit(args: []const []const u8, limit: usize) !struct {
    stdout: std.ArrayList(u8),
    stderr: std.ArrayList(u8),
    result: u8,
} {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);

    var limited = LimitedWriter{ .buffer = &stdout_buffer, .limit = limit };
    const result = try runYes(testing.allocator, args, limited.writer(), stderr_buffer.writer());

    return .{
        .stdout = stdout_buffer,
        .stderr = stderr_buffer,
        .result = result,
    };
}

// Tests

test "yes outputs 'y' repeatedly with no arguments" {
    var test_result = try testYesWithLimit(&.{}, 20);
    defer test_result.stdout.deinit();
    defer test_result.stderr.deinit();

    try testing.expectEqual(@as(u8, 0), test_result.result);
    try testing.expectEqualStrings("y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n", test_result.stdout.items);
}

test "yes outputs custom string with single argument" {
    var test_result = try testYesWithLimit(&.{"hello"}, 30);
    defer test_result.stdout.deinit();
    defer test_result.stderr.deinit();

    try testing.expectEqual(@as(u8, 0), test_result.result);
    try testing.expectEqualStrings("hello\nhello\nhello\nhello\nhello\n", test_result.stdout.items);
}

test "yes outputs multiple arguments joined with space" {
    var test_result = try testYesWithLimit(&.{ "hello", "world" }, 40);
    defer test_result.stdout.deinit();
    defer test_result.stderr.deinit();

    try testing.expectEqual(@as(u8, 0), test_result.result);
    // Buffer should contain at least 3 repetitions
    try testing.expect(test_result.stdout.items.len >= 36);
    try testing.expect(std.mem.startsWith(u8, test_result.stdout.items, "hello world\nhello world\nhello world\n"));
}

test "yes handles --help flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runYes(testing.allocator, &.{"--help"}, stdout_buffer.writer(), stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "yes") != null);
}

test "yes handles --version flag" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runYes(testing.allocator, &.{"--version"}, stdout_buffer.writer(), stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "yes") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "vibeutils") != null);
}

test "yes handles BrokenPipe gracefully" {
    const BrokenWriter = struct {
        pub fn write(_: *const @This(), _: []const u8) !usize {
            return error.BrokenPipe;
        }

        pub fn writer(self: *const @This()) std.io.Writer(*const @This(), error{BrokenPipe}, write) {
            return .{ .context = self };
        }
    };

    const broken = BrokenWriter{};
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runYes(testing.allocator, &.{}, broken.writer(), stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stderr_buffer.items); // No error messages for SIGPIPE
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("yes");

test "yes fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testYesIntelligentWrapper, .{});
}

fn testYesIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("yes")) return;

    const YesIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(YesArgs, runYes);
    try YesIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}

test "yes fuzz basic limited" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testYesBasicLimited, .{});
}

fn testYesBasicLimited(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("yes")) return;

    var arg_storage = common.fuzz.ArgStorage.init();
    const args = common.fuzz.generateArgs(&arg_storage, input);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var limited_writer = LimitedWriter{ .buffer = &stdout_buf, .limit = 1000 };

    _ = runYes(allocator, args, limited_writer.writer(), common.null_writer) catch {
        // BrokenPipe and other errors are expected
        return;
    };
}

test "yes fuzz deterministic limited" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testYesDeterministicLimited, .{});
}

fn testYesDeterministicLimited(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("yes")) return;

    var arg_storage = common.fuzz.ArgStorage.init();
    const args = common.fuzz.generateArgs(&arg_storage, input);

    var stdout_buf1 = std.ArrayList(u8).init(allocator);
    defer stdout_buf1.deinit();
    var stdout_buf2 = std.ArrayList(u8).init(allocator);
    defer stdout_buf2.deinit();

    var limited_writer1 = LimitedWriter{ .buffer = &stdout_buf1, .limit = 200 };
    var limited_writer2 = LimitedWriter{ .buffer = &stdout_buf2, .limit = 200 };

    const result1 = runYes(allocator, args, limited_writer1.writer(), common.null_writer) catch |err| switch (err) {
        error.BrokenPipe => @as(u8, 0), // Expected result
        else => return err,
    };

    const result2 = runYes(allocator, args, limited_writer2.writer(), common.null_writer) catch |err| switch (err) {
        error.BrokenPipe => @as(u8, 0), // Expected result
        else => return err,
    };

    // Results should be identical for same input
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(stdout_buf1.items, stdout_buf2.items);
}

test "yes fuzz output patterns" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testYesOutputPatterns, .{});
}

fn testYesOutputPatterns(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("yes")) return;

    if (input.len == 0) return;

    // Test various output patterns
    const patterns = [_][]const []const u8{
        &.{}, // Default 'y'
        &.{"hello"},
        &.{ "a", "b", "c" },
        &.{""},
        &.{ "hello", "world" },
    };

    const args = patterns[input[0] % patterns.len];

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var limited_writer = LimitedWriter{ .buffer = &stdout_buf, .limit = 500 };

    _ = runYes(allocator, args, limited_writer.writer(), common.null_writer) catch {
        // BrokenPipe is expected
        return;
    };
}
