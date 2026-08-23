//! Main entry point wrapper for vibeutils utilities
//!
//! This module provides `utilityMain`, a composite wrapper that standardizes:
//! - Arena allocator setup
//! - Process argument parsing
//! - 8KB buffered stdout and unbuffered stderr writers
//! - Calling the run function
//! - Flushing buffers
//! - Exiting with the returned code
//!
//! This eliminates ~30 lines of boilerplate from each utility's main() function.

const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");

/// Restore the kernel's default SIGPIPE disposition. Zig's start code
/// installs an ignore handler so EPIPE surfaces as a writer error; GNU
/// utilities die silently by signal instead, which is what scripts
/// expect from `util | head` ($? == 141, no stderr noise).
fn installDefaultSigpipe() void {
    if (@import("builtin").os.tag == .windows) return;
    const posix = std.posix;
    const action = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    _ = posix.sigaction(posix.SIG.PIPE, &action, null);
}

/// Composite wrapper for utility main functions.
///
/// Parses process arguments, then delegates 8KB `writerStreaming` setup and
/// flush-before-return to `runWithStreamingFiles` on process stdout/stderr.
/// Exits with the returned code. Empty `argv[0]` is legal and must not trap.
///
/// The run function signature must be:
///   fn(std.mem.Allocator, std.Io, []const []const u8, *std.Io.Writer, *std.Io.Writer) anyerror!u8
///
/// Where the parameters are: allocator, io, args (without program name),
/// stdout_writer, stderr_writer
pub fn utilityMain(
    init: std.process.Init,
    comptime runFn: fn (
        std.mem.Allocator,
        std.Io,
        []const []const u8,
        *std.Io.Writer,
        *std.Io.Writer,
    ) anyerror!u8,
) noreturn {
    const io = init.io;
    const allocator = init.arena.allocator();

    // GNU parity: die by SIGPIPE like a default-disposition process when
    // stdout's reader closes early (`util | head` exits 141, silently).
    // Zig installs an ignore handler at startup; undo it. Utilities that
    // need to survive EPIPE (tee -p) re-ignore it after parsing.
    installDefaultSigpipe();

    // Parse process arguments
    const args = init.minimal.args.toSlice(allocator) catch |err| {
        var stderr_buffer: [0]u8 = .{};
        var stderr_w = lib.unbufferedStderr(io, &stderr_buffer);
        const stderr = &stderr_w.interface;
        stderr.print(
            "error: failed to allocate arguments: {s}\n",
            .{lib.posixErrorString(err)},
        ) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // Every OS-launched process supplies argv[0]; args[1..] depends on that.
    // Empty argv[0] is legal, so do not assert args[0].len > 0.
    std.debug.assert(args.len >= 1);

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    std.debug.assert(stdout_file.handle >= 0);
    std.debug.assert(stderr_file.handle >= 0);

    const exit_code = runWithStreamingFiles(
        runFn,
        allocator,
        io,
        args,
        stdout_file,
        stderr_file,
    );
    std.process.exit(exit_code);
}

/// File-backed writer setup: the path `runUtil` unit tests never see.
///
/// Same `runFn` contract as `utilityMain`. `args[0]` is the program name and
/// is stripped (`args[1..]`). Does not call `std.process.exit`.
///
/// On uncaught `runFn` error, flush stderr only — today's `utilityMain` `catch`
/// used to `process.exit(1)` before the success-path `stdout.flush()`.
pub fn runWithStreamingFiles(
    comptime runFn: fn (
        std.mem.Allocator,
        std.Io,
        []const []const u8,
        *std.Io.Writer,
        *std.Io.Writer,
    ) anyerror!u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_file: std.Io.File,
    stderr_file: std.Io.File,
) u8 {
    std.debug.assert(args.len >= 1);

    // Buffer stdout for throughput while keeping stderr immediately visible.
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Zero-length buffer keeps stderr immediately visible (POSIX I/O
    // suite) while still writing through the caller-supplied file so
    // runWithStreamingFiles tests can capture diagnostics.
    var stderr_buffer: [0]u8 = .{};
    var stderr_writer = stderr_file.writerStreaming(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    std.debug.assert(stdout_buffer.len == 8192);
    std.debug.assert(stderr_writer.interface.buffer.len == 0);

    const exit_code = runFn(allocator, io, args[1..], stdout, stderr) catch |err| {
        stderr.print("error: {s}\n", .{lib.posixErrorString(err)}) catch {};
        stderr.flush() catch {};
        return 1;
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
    return exit_code;
}

/// Testable inner loop: same logic as `utilityMain` but accepts an explicit
/// allocator, pre-built arg slice (including program name at index 0), and
/// caller-supplied writers.  Does NOT call `std.process.exit`; returns the
/// exit code instead.
pub fn runWithBufferedIO(
    comptime runFn: fn (
        std.mem.Allocator,
        std.Io,
        []const []const u8,
        *std.Io.Writer,
        *std.Io.Writer,
    ) anyerror!u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8, // args[0] is the program name and is stripped
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) u8 {
    // Documented contract: args[0] is the program name; the args[1..] slice
    // below requires at least that one element.
    std.debug.assert(args.len >= 1);

    // Skip program name (mirrors utilityMain's args[1..] call)
    const exit_code = runFn(allocator, io, args[1..], stdout_writer, stderr_writer) catch |err| {
        stderr_writer.print("error: {s}\n", .{lib.posixErrorString(err)}) catch {};
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
    _: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    for (args) |arg| {
        try stdout.print("{s}\n", .{arg});
    }
    return 0;
}

/// A run function that allocates memory and writes its size to stdout.
fn runUseAllocator(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    stdout: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    const buf = try allocator.alloc(u8, 64);
    @memset(buf, 'x');
    try stdout.print("allocated:{d}\n", .{buf.len});
    return 0;
}

/// A run function that always returns an error.
fn runAlwaysErrors(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    _: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    return error.SomeError;
}

/// A run function that writes to both stdout and stderr.
fn runWritesBoth(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) anyerror!u8 {
    try stdout.print("stdout-line\n", .{});
    try stderr.print("stderr-line\n", .{});
    return 42;
}

/// A run function that returns a specific exit code.
fn runExitCode7(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    _: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    return 7;
}

// ---------------------------------------------------------------------------
// Behavioral tests for runWithBufferedIO (testable core of utilityMain)
// ---------------------------------------------------------------------------

test "runWithBufferedIO: program name is stripped from args" {
    const io = std.testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const argv = [_][]const u8{ "/usr/bin/myprog", "arg1", "arg2" };
    _ = runWithBufferedIO(
        runEchoArgs,
        testing.allocator,
        io,
        &argv,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "myprog") == null);
    try testing.expect(std.mem.find(u8, out, "arg1") != null);
    try testing.expect(std.mem.find(u8, out, "arg2") != null);
}

test "runWithBufferedIO: allocator is functional (arena allocation works)" {
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runUseAllocator,
        arena.allocator(),
        io,
        &argv,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), code);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "allocated:64") != null);
}

test "runWithBufferedIO: uncaught run error prints to stderr and returns 1" {
    const io = std.testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runAlwaysErrors,
        testing.allocator,
        io,
        &argv,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), code);
    const err_out = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err_out, "SomeError") != null);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "runWithBufferedIO: exit code from run function is returned" {
    const io = std.testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runExitCode7,
        testing.allocator,
        io,
        &argv,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 7), code);
}

test "runWithBufferedIO: stdout and stderr writers receive correct data" {
    const io = std.testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const argv = [_][]const u8{"prog"};
    const code = runWithBufferedIO(
        runWritesBoth,
        testing.allocator,
        io,
        &argv,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 42), code);
    try testing.expectEqualStrings("stdout-line\n", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("stderr-line\n", stderr_aw.writer.buffered());
}

test "runWithBufferedIO: empty args slice (program name only) passes empty slice to run" {
    const io = std.testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const argv = [_][]const u8{"prog"};
    _ = runWithBufferedIO(
        runEchoArgs,
        testing.allocator,
        io,
        &argv,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

// ---------------------------------------------------------------------------
// File-backed tests for runWithStreamingFiles (writer setup + catch flush)
// ---------------------------------------------------------------------------

/// Short payload that stays in the 8KB buffer until the success-path flush.
fn runStreamingShort(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    stdout: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    try stdout.writeAll("short-payload\n");
    return 0;
}

/// 9000-byte write: first 8192 drain on buffer fill; the tail needs flush.
fn runStreamingLong(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    stdout: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    var payload: [9000]u8 = undefined;
    @memset(&payload, 'Z');
    try stdout.writeAll(&payload);
    return 0;
}

/// Pending short stdout write, then an uncaught error (catch-path probe).
fn runStreamingPendingThenError(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    stdout: *std.Io.Writer,
    _: *std.Io.Writer,
) anyerror!u8 {
    try stdout.writeAll("pending-short");
    return error.StreamingCatchProbe;
}

test "runWithStreamingFiles: short write flushes to stdout file" {
    const io = testing.io;
    var test_dir = lib.test_dir.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("stdout.txt", "", null);
    try test_dir.createFile("stderr.txt", "", null);
    const stdout_file = try test_dir.tmp_dir.dir.openFile(
        io,
        "stdout.txt",
        .{ .mode = .write_only },
    );
    const stderr_file = try test_dir.tmp_dir.dir.openFile(
        io,
        "stderr.txt",
        .{ .mode = .write_only },
    );

    const argv = [_][]const u8{"prog"};
    const code = runWithStreamingFiles(
        runStreamingShort,
        testing.allocator,
        io,
        &argv,
        stdout_file,
        stderr_file,
    );
    stdout_file.close(io);
    stderr_file.close(io);

    try testing.expectEqual(@as(u8, 0), code);
    try test_dir.expectFileContent("stdout.txt", "short-payload\n");
}

test "runWithStreamingFiles: write over 8192 persists full payload including tail" {
    const io = testing.io;
    var test_dir = lib.test_dir.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("stdout.txt", "", null);
    try test_dir.createFile("stderr.txt", "", null);
    const stdout_file = try test_dir.tmp_dir.dir.openFile(
        io,
        "stdout.txt",
        .{ .mode = .write_only },
    );
    const stderr_file = try test_dir.tmp_dir.dir.openFile(
        io,
        "stderr.txt",
        .{ .mode = .write_only },
    );

    const argv = [_][]const u8{"prog"};
    const code = runWithStreamingFiles(
        runStreamingLong,
        testing.allocator,
        io,
        &argv,
        stdout_file,
        stderr_file,
    );
    stdout_file.close(io);
    stderr_file.close(io);

    var expected: [9000]u8 = undefined;
    @memset(&expected, 'Z');
    try testing.expectEqual(@as(u8, 0), code);
    try test_dir.expectFileContent("stdout.txt", &expected);
}

test "runWithStreamingFiles: uncaught runFn error returns 1, flushes stderr, not stdout" {
    const io = testing.io;
    var test_dir = lib.test_dir.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("stdout.txt", "", null);
    try test_dir.createFile("stderr.txt", "", null);
    const stdout_file = try test_dir.tmp_dir.dir.openFile(
        io,
        "stdout.txt",
        .{ .mode = .write_only },
    );
    const stderr_file = try test_dir.tmp_dir.dir.openFile(
        io,
        "stderr.txt",
        .{ .mode = .write_only },
    );

    const argv = [_][]const u8{"prog"};
    const code = runWithStreamingFiles(
        runStreamingPendingThenError,
        testing.allocator,
        io,
        &argv,
        stdout_file,
        stderr_file,
    );
    stdout_file.close(io);
    stderr_file.close(io);

    const err_content = try test_dir.readFileAlloc("stderr.txt");
    defer testing.allocator.free(err_content);
    const out_content = try test_dir.readFileAlloc("stdout.txt");
    defer testing.allocator.free(out_content);

    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, err_content, "error: ") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        err_content,
        lib.posixErrorString(error.StreamingCatchProbe),
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out_content, "pending-short") == null);
}
