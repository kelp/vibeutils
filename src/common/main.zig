//! Main entry point wrapper for vibeutils utilities
//!
//! This module provides `utilityMain`, a composite wrapper that standardizes:
//! - Arena allocator setup
//! - Process argument parsing with argsAlloc
//! - 8KB buffered stdout/stderr writers
//! - Calling the run function
//! - Flushing buffers
//! - Exiting with the returned code
//!
//! This eliminates ~30 lines of boilerplate from each utility's main() function.

const std = @import("std");
const testing = std.testing;

/// Composite wrapper for utility main functions.
///
/// Sets up arena allocator, parses process arguments, creates buffered writers,
/// calls the run function, flushes buffers, and exits with the returned code.
///
/// The run function signature must be:
///   fn(std.mem.Allocator, []const []const u8, anytype, anytype) anyerror!u8
///
/// Where the parameters are: allocator, args (without program name), stdout_writer, stderr_writer
///
/// Example:
/// ```zig
/// pub fn main() !void {
///     common.utilityMain(runCat);
/// }
/// ```
pub fn utilityMain(comptime runFn: fn (std.mem.Allocator, []const []const u8, anytype, anytype) anyerror!u8) noreturn {
    // Set up arena allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = std.process.argsAlloc(allocator) catch |err| {
        // Cannot allocate args - print error to stderr and exit
        var stderr_buf: [256]u8 = undefined;
        var stderr_w = std.fs.File.stderr().writerStreaming(&stderr_buf);
        const stderr = &stderr_w.interface;
        stderr.print("error: failed to allocate arguments: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, args);

    // Set up 8KB buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Call the run function (skip program name: args[1..])
    const exit_code = runFn(allocator, args[1..], stdout, stderr) catch |err| {
        // Uncaught error from run function - print and exit with error code
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    // Exit with the returned code
    std.process.exit(exit_code);
}

/// Testable inner loop: same logic as `utilityMain` but accepts an explicit
/// allocator, pre-built arg slice (including program name at index 0), and
/// caller-supplied writers.  Does NOT call `std.process.exit`; returns the
/// exit code instead.
///
/// Use this in unit tests to exercise the core dispatch logic:
/// ```zig
/// var stdout_buf: [256]u8 = undefined;
/// var stdout_w = std.io.fixedBufferStream(&stdout_buf);
/// const code = runWithBufferedIO(myRunFn, alloc, argv, stdout_w.writer(), common.null_writer);
/// try testing.expectEqual(@as(u8, 0), code);
/// ```
pub fn runWithBufferedIO(
    comptime runFn: fn (std.mem.Allocator, []const []const u8, anytype, anytype) anyerror!u8,
    allocator: std.mem.Allocator,
    args: []const []const u8, // args[0] is the program name and is stripped
    stdout_writer: anytype,
    stderr_writer: anytype,
) u8 {
    // Skip program name (mirrors utilityMain's args[1..] call)
    const exit_code = runFn(allocator, args[1..], stdout_writer, stderr_writer) catch |err| {
        stderr_writer.print("error: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    return exit_code;
}

// ============================================================================
// TESTS
// ============================================================================

// ---------------------------------------------------------------------------
// Helpers used by the tests below
// ---------------------------------------------------------------------------

/// A minimal run function that echoes its args to stdout, one per line.
fn runEchoArgs(
    _: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    _: anytype,
) anyerror!u8 {
    for (args) |arg| {
        try stdout.print("{s}\n", .{arg});
    }
    return 0;
}

/// A run function that allocates memory and writes its size to stdout.
fn runUseAllocator(
    allocator: std.mem.Allocator,
    _: []const []const u8,
    stdout: anytype,
    _: anytype,
) anyerror!u8 {
    // Allocate a small buffer to prove the allocator works
    const buf = try allocator.alloc(u8, 64);
    @memset(buf, 'x');
    try stdout.print("allocated:{d}\n", .{buf.len});
    return 0;
}

/// A run function that always returns an error.
fn runAlwaysErrors(
    _: std.mem.Allocator,
    _: []const []const u8,
    _: anytype,
    _: anytype,
) anyerror!u8 {
    return error.SomeError;
}

/// A run function that writes to both stdout and stderr.
fn runWritesBoth(
    _: std.mem.Allocator,
    _: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) anyerror!u8 {
    try stdout.print("stdout-line\n", .{});
    try stderr.print("stderr-line\n", .{});
    return 42;
}

/// A run function that returns a specific exit code.
fn runExitCode7(
    _: std.mem.Allocator,
    _: []const []const u8,
    _: anytype,
    _: anytype,
) anyerror!u8 {
    return 7;
}

// ---------------------------------------------------------------------------
// Behavioral tests for runWithBufferedIO (testable core of utilityMain)
// ---------------------------------------------------------------------------

test "runWithBufferedIO: program name is stripped from args" {
    // args[0] is the program name and must NOT be passed to the run function.
    var stdout_buf: [256]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [256]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const argv = [_][]const u8{ "/usr/bin/myprog", "arg1", "arg2" };
    _ = runWithBufferedIO(runEchoArgs, testing.allocator, &argv, stdout_stream.writer(), stderr_stream.writer());

    const out = stdout_stream.getWritten();
    // Program name must not appear; only arg1 and arg2 should be echoed.
    try testing.expect(std.mem.indexOf(u8, out, "myprog") == null);
    try testing.expect(std.mem.indexOf(u8, out, "arg1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "arg2") != null);
}

test "runWithBufferedIO: allocator is functional (arena allocation works)" {
    // Use an arena like utilityMain does: the run function doesn't free
    // individual allocations; the arena cleans up all at once.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var stdout_buf: [256]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runUseAllocator,
        arena.allocator(),
        &argv,
        stdout_stream.writer(),
        std.io.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), code);
    const out = stdout_stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, out, "allocated:64") != null);
}

test "runWithBufferedIO: uncaught run error prints to stderr and returns 1" {
    var stdout_buf: [256]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [256]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runAlwaysErrors,
        testing.allocator,
        &argv,
        stdout_stream.writer(),
        stderr_stream.writer(),
    );
    try testing.expectEqual(@as(u8, 1), code);
    // Error name must appear in stderr
    const err_out = stderr_stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, err_out, "SomeError") != null);
    // Nothing written to stdout
    try testing.expectEqual(@as(usize, 0), stdout_stream.getWritten().len);
}

test "runWithBufferedIO: exit code from run function is returned" {
    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runExitCode7,
        testing.allocator,
        &argv,
        std.io.null_writer,
        std.io.null_writer,
    );
    try testing.expectEqual(@as(u8, 7), code);
}

test "runWithBufferedIO: stdout and stderr writers receive correct data" {
    var stdout_buf: [256]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [256]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runWritesBoth,
        testing.allocator,
        &argv,
        stdout_stream.writer(),
        stderr_stream.writer(),
    );
    try testing.expectEqual(@as(u8, 42), code);
    try testing.expectEqualStrings("stdout-line\n", stdout_stream.getWritten());
    try testing.expectEqualStrings("stderr-line\n", stderr_stream.getWritten());
}

test "runWithBufferedIO: empty args slice (program name only) passes empty slice to run" {
    var stdout_buf: [256]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);

    // Only program name in argv; run function should see zero args.
    const argv = [_][]const u8{"prog"};
    _ = runWithBufferedIO(
        runEchoArgs,
        testing.allocator,
        &argv,
        stdout_stream.writer(),
        std.io.null_writer,
    );
    // Nothing echoed because args slice was empty
    try testing.expectEqual(@as(usize, 0), stdout_stream.getWritten().len);
}
