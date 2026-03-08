//! timeout - run a command with a time limit
//!
//! The timeout utility runs a command with a time limit. If the command
//! does not finish within the specified duration, it is sent a signal.
//! By default SIGTERM is sent. If the command is still running after
//! a --kill-after duration, SIGKILL is sent.
//!
//! This implementation follows GNU coreutils timeout behavior.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const prog_name = "timeout";

// C library bindings for process management
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;
extern "c" fn setpgid(pid: std.c.pid_t, pgid: std.c.pid_t) c_int;
extern "c" fn waitpid(pid: std.c.pid_t, stat_loc: ?*c_int, options: c_int) std.c.pid_t;
const WNOHANG: c_int = 1;

/// Signal name to number mapping
const SignalEntry = struct {
    name: []const u8,
    number: u8,
};

/// Supported signal names (POSIX subset)
const signal_table = [_]SignalEntry{
    .{ .name = "HUP", .number = 1 },
    .{ .name = "INT", .number = 2 },
    .{ .name = "QUIT", .number = 3 },
    .{ .name = "ABRT", .number = 6 },
    .{ .name = "KILL", .number = 9 },
    .{ .name = "ALRM", .number = 14 },
    .{ .name = "TERM", .number = 15 },
    .{ .name = "USR1", .number = 30 },
    .{ .name = "USR2", .number = 31 },
};

/// Command-line arguments for the timeout utility
const TimeoutArgs = struct {
    /// Signal to send on timeout (default: TERM)
    signal: ?[]const u8 = null,
    /// Send KILL signal after DURATION if still running
    @"kill-after": ?[]const u8 = null,
    /// Exit with same status as the command
    @"preserve-status": bool = false,
    /// Don't create a new process group
    foreground: bool = false,
    /// Diagnose signals sent to stderr
    verbose: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Positional arguments: DURATION COMMAND [ARG]...
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .signal = .{ .short = 's', .desc = "Signal to send on timeout", .value_name = "SIGNAL" },
        .@"kill-after" = .{ .short = 'k', .desc = "Send KILL after DURATION if still running", .value_name = "DURATION" },
        .@"preserve-status" = .{ .desc = "Exit with same status as COMMAND" },
        .foreground = .{ .desc = "run in the foreground process group" },
        .verbose = .{ .short = 'v', .desc = "Diagnose to stderr any signal sent" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Time unit multipliers in nanoseconds
const TimeUnit = enum {
    seconds,
    minutes,
    hours,
    days,

    pub fn toNanos(self: TimeUnit) u64 {
        return switch (self) {
            .seconds => std.time.ns_per_s,
            .minutes => std.time.ns_per_min,
            .hours => std.time.ns_per_hour,
            .days => std.time.ns_per_day,
        };
    }
};

/// Parse a time string into nanoseconds
/// Supports: plain numbers (5), unit suffixes (5s, 2.5m, 1h, 3d)
fn parseTimeString(time_str: []const u8) !u64 {
    if (time_str.len == 0) {
        return error.InvalidTimeFormat;
    }

    var number_part = time_str;
    var unit = TimeUnit.seconds;

    const last_char = time_str[time_str.len - 1];
    switch (last_char) {
        's' => {
            unit = .seconds;
            number_part = time_str[0 .. time_str.len - 1];
        },
        'm' => {
            unit = .minutes;
            number_part = time_str[0 .. time_str.len - 1];
        },
        'h' => {
            unit = .hours;
            number_part = time_str[0 .. time_str.len - 1];
        },
        'd' => {
            unit = .days;
            number_part = time_str[0 .. time_str.len - 1];
        },
        else => {
            number_part = time_str;
            unit = .seconds;
        },
    }

    if (number_part.len == 0) {
        return error.InvalidTimeFormat;
    }

    if (std.mem.endsWith(u8, number_part, ".")) {
        return error.InvalidTimeFormat;
    }

    const parsed_value = std.fmt.parseFloat(f64, number_part) catch {
        return error.InvalidTimeFormat;
    };

    if (std.math.isNan(parsed_value) or std.math.isInf(parsed_value)) {
        return error.InvalidTimeFormat;
    }

    if (parsed_value < 0) {
        return error.NegativeTime;
    }

    const nanos_per_unit = @as(f64, @floatFromInt(unit.toNanos()));
    const total_nanos = parsed_value * nanos_per_unit;

    if (total_nanos > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return error.TimeOverflow;
    }

    return @as(u64, @intFromFloat(total_nanos));
}

/// Parse signal name or number to signal number
/// Accepts: "TERM", "SIGTERM", "15", "9", "KILL", etc.
fn parseSignal(signal_str: []const u8) ?u8 {
    // Try parsing as a number first
    if (std.fmt.parseInt(u8, signal_str, 10)) |num| {
        if (num > 0 and num < 64) return num;
        return null;
    } else |_| {}

    // Strip optional "SIG" prefix (case-insensitive)
    const name = if (signal_str.len >= 3 and
        asciiEqlIgnoreCase(signal_str[0..3], "SIG"))
        signal_str[3..]
    else
        signal_str;

    // Look up in signal table (case-insensitive)
    for (signal_table) |entry| {
        if (asciiEqlIgnoreCase(name, entry.name)) {
            return entry.number;
        }
    }

    return null;
}

/// Extract exit code from waitpid status
/// Returns null if child has not exited yet (for WNOHANG)
fn extractExitCode(pid: std.c.pid_t, status: c_int) ?u8 {
    _ = pid;
    // WIFEXITED: (status & 0x7f) == 0
    if ((status & 0x7f) == 0) {
        // WEXITSTATUS: (status >> 8) & 0xff
        return @intCast((status >> 8) & 0xff);
    }
    // WIFSIGNALED: ((status & 0x7f) + 1) >> 1 > 0
    const sig_val = status & 0x7f;
    if (((sig_val + 1) >> 1) > 0) {
        return @intCast(sig_val + 128);
    }
    // WIFSTOPPED: (status & 0xff) == 0x7f
    if ((status & 0xff) == 0x7f) {
        const stop_sig: u8 = @intCast((status >> 8) & 0xff);
        return stop_sig + 128;
    }
    return 0;
}

/// Non-blocking wait for a child process
/// Returns the exit code if the child has exited, or null if still running
fn tryWaitChild(pid: std.c.pid_t) ?u8 {
    var status: c_int = 0;
    const result = waitpid(pid, &status, WNOHANG);
    if (result > 0) {
        return extractExitCode(pid, status);
    }
    return null;
}

/// Blocking wait for a child process
fn waitChild(pid: std.c.pid_t) u8 {
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    return extractExitCode(pid, status) orelse 125;
}

/// Case-insensitive ASCII comparison
fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: timeout [OPTION] DURATION COMMAND [ARG]...
        \\  or:  timeout [OPTION]
        \\Start COMMAND, and kill it if still running after DURATION.
        \\
        \\DURATION is a number with an optional suffix: 's' for seconds (default),
        \\'m' for minutes, 'h' for hours, 'd' for days. A duration of 0 disables
        \\the timeout.
        \\
        \\  -s, --signal=SIGNAL      send this signal on timeout (default: TERM)
        \\  -k, --kill-after=DURATION
        \\                           send KILL signal if COMMAND still running
        \\                           after DURATION
        \\      --preserve-status    exit with the same status as COMMAND, even
        \\                           when the command times out
        \\      --foreground         run in the foreground process group
        \\  -v, --verbose            diagnose to stderr any signal sent
        \\  -h, --help               display this help and exit
        \\  -V, --version            output version information and exit
        \\
        \\If COMMAND is timed out and --preserve-status is not set, exit with
        \\status 124.  Otherwise, exit with the status of COMMAND.  If no signal
        \\is specified, send the TERM signal upon timeout.  The TERM signal kills
        \\any process that does not block or catch that signal.  It may be necessary
        \\to use the KILL (9) signal, since this signal cannot be caught.
        \\
        \\EXIT STATUS:
        \\  124  if COMMAND times out, and --preserve-status is not set
        \\  125  if the timeout command itself fails
        \\  126  if COMMAND is found but cannot be invoked
        \\  127  if COMMAND cannot be found
        \\  137  if COMMAND is sent the KILL (9) signal (128+9)
        \\    -  the exit status of COMMAND otherwise
        \\
        \\Examples:
        \\  timeout 10 sleep 60     # Limit sleep to 10 seconds
        \\  timeout 5m ./build.sh   # Limit script to 5 minutes
        \\  timeout -s KILL 30 cmd  # Send KILL instead of TERM
        \\  timeout -k 5 30 cmd     # TERM at 30s, KILL at 35s
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("timeout ({s}) {s}\n", .{ common.name, common.version });
}

/// Run the timeout utility with given arguments
pub fn runTimeout(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const parsed = common.argparse.ArgParser.parse(TimeoutArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid argument\nTry 'timeout --help' for more information.", .{});
                return 125;
            },
            else => return err,
        }
    };
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return 0;
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return 0;
    }

    // Need at least DURATION and COMMAND
    if (parsed.positionals.len < 2) {
        if (parsed.positionals.len == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing operand", .{});
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing operand after '{s}'", .{parsed.positionals[0]});
        }
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "Try 'timeout --help' for more information.", .{});
        return 125;
    }

    // Parse timeout duration
    const timeout_nanos = parseTimeString(parsed.positionals[0]) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid time interval '{s}'", .{parsed.positionals[0]});
        return 125;
    };

    // Parse signal
    const timeout_signal: u8 = if (parsed.signal) |sig_str|
        parseSignal(sig_str) orelse {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid signal '{s}'", .{sig_str});
            return 125;
        }
    else
        15; // SIGTERM

    // Parse kill-after duration
    const kill_after_nanos: ?u64 = if (parsed.@"kill-after") |ka_str|
        parseTimeString(ka_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid time interval '{s}'", .{ka_str});
            return 125;
        }
    else
        null;

    // Build argv for child process
    const cmd_args = parsed.positionals[1..];

    // Spawn child process
    var child = std.process.Child.init(cmd_args, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| {
        switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to run command '{s}': No such file or directory", .{cmd_args[0]});
                return 127;
            },
            error.AccessDenied => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to run command '{s}': Permission denied", .{cmd_args[0]});
                return 126;
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to run command '{s}': {s}", .{ cmd_args[0], @errorName(err) });
                return 125;
            },
        }
    };

    const child_pid = child.id;

    // Set up process group if not in foreground mode
    if (!parsed.foreground) {
        _ = setpgid(child_pid, child_pid);
    }

    // If timeout is 0, just wait for the command (no timeout)
    if (timeout_nanos == 0) {
        return waitChild(child_pid);
    }

    // Wait with timeout using polling approach
    // Poll at intervals until either the child exits or timeout expires
    const poll_interval_ns: u64 = 10 * std.time.ns_per_ms; // 10ms
    var elapsed_ns: u64 = 0;

    while (elapsed_ns < timeout_nanos) {
        // Try to collect the child status without blocking
        if (tryWaitChild(child_pid)) |exit_code| {
            return exit_code;
        }

        // Sleep for the poll interval, but don't overshoot the timeout
        const remaining = timeout_nanos - elapsed_ns;
        const sleep_time = @min(poll_interval_ns, remaining);
        std.Thread.sleep(sleep_time);
        elapsed_ns += sleep_time;
    }

    // Timeout expired - send the signal
    if (parsed.verbose) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "sending signal {d} to command '{s}'", .{ timeout_signal, cmd_args[0] });
    }

    sendSignal(child_pid, @intCast(timeout_signal), !parsed.foreground);

    // If --kill-after is set, wait for that duration then send KILL
    if (kill_after_nanos) |ka_nanos| {
        if (ka_nanos > 0) {
            var ka_elapsed: u64 = 0;
            while (ka_elapsed < ka_nanos) {
                if (tryWaitChild(child_pid)) |exit_code| {
                    if (parsed.@"preserve-status") {
                        return exit_code;
                    }
                    return 124;
                }

                const remaining = ka_nanos - ka_elapsed;
                const sleep_time = @min(poll_interval_ns, remaining);
                std.Thread.sleep(sleep_time);
                ka_elapsed += sleep_time;
            }

            // Still running - send KILL
            if (parsed.verbose) {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "sending signal KILL to command '{s}'", .{cmd_args[0]});
            }

            sendSignal(child_pid, 9, !parsed.foreground); // SIGKILL
        }
    }

    // Wait for child to actually finish after signal
    const final_exit = waitChild(child_pid);

    if (parsed.@"preserve-status") {
        return final_exit;
    }

    // SIGKILL (9) cannot be caught, so the child always dies via signal.
    // GNU timeout returns the signal exit code (137 = 128+9) in this case
    // rather than the generic timeout code (124).
    if (timeout_signal == 9) {
        return final_exit;
    }

    return 124;
}

/// Send a signal to a process or process group
fn sendSignal(pid: std.c.pid_t, sig: c_int, use_process_group: bool) void {
    if (use_process_group) {
        _ = kill(-pid, sig);
    } else {
        _ = kill(pid, sig);
    }
}

/// Standard main function
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runTimeout(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

// ============================================================================
// TESTS
// ============================================================================

test "parseTimeString - basic integer seconds" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try parseTimeString("5"));
    try testing.expectEqual(@as(u64, 0), try parseTimeString("0"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), try parseTimeString("1"));
    try testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), try parseTimeString("10"));
}

test "parseTimeString - decimal seconds" {
    try testing.expectEqual(@as(u64, @intFromFloat(0.5 * std.time.ns_per_s)), try parseTimeString("0.5"));
    try testing.expectEqual(@as(u64, @intFromFloat(1.5 * std.time.ns_per_s)), try parseTimeString("1.5"));
    try testing.expectEqual(@as(u64, @intFromFloat(2.25 * std.time.ns_per_s)), try parseTimeString("2.25"));
}

test "parseTimeString - suffixes" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try parseTimeString("5s"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_min), try parseTimeString("1m"));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try parseTimeString("2h"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_day), try parseTimeString("1d"));
}

test "parseTimeString - invalid formats" {
    try testing.expectError(error.InvalidTimeFormat, parseTimeString(""));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("s"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("abc"));
    try testing.expectError(error.InvalidTimeFormat, parseTimeString("5."));
}

test "parseTimeString - negative values" {
    try testing.expectError(error.NegativeTime, parseTimeString("-1"));
    try testing.expectError(error.NegativeTime, parseTimeString("-5s"));
}

test "parseSignal - numeric signals" {
    try testing.expectEqual(@as(?u8, 15), parseSignal("15"));
    try testing.expectEqual(@as(?u8, 9), parseSignal("9"));
    try testing.expectEqual(@as(?u8, 1), parseSignal("1"));
    try testing.expectEqual(@as(?u8, null), parseSignal("0"));
    try testing.expectEqual(@as(?u8, null), parseSignal("64"));
}

test "parseSignal - named signals" {
    try testing.expectEqual(@as(?u8, 15), parseSignal("TERM"));
    try testing.expectEqual(@as(?u8, 9), parseSignal("KILL"));
    try testing.expectEqual(@as(?u8, 1), parseSignal("HUP"));
    try testing.expectEqual(@as(?u8, 2), parseSignal("INT"));
    try testing.expectEqual(@as(?u8, 6), parseSignal("ABRT"));
    try testing.expectEqual(@as(?u8, 14), parseSignal("ALRM"));
}

test "parseSignal - SIG prefix" {
    try testing.expectEqual(@as(?u8, 15), parseSignal("SIGTERM"));
    try testing.expectEqual(@as(?u8, 9), parseSignal("SIGKILL"));
    try testing.expectEqual(@as(?u8, 1), parseSignal("SIGHUP"));
}

test "parseSignal - case insensitive" {
    try testing.expectEqual(@as(?u8, 15), parseSignal("term"));
    try testing.expectEqual(@as(?u8, 9), parseSignal("kill"));
    try testing.expectEqual(@as(?u8, 15), parseSignal("sigterm"));
}

test "parseSignal - invalid signals" {
    try testing.expectEqual(@as(?u8, null), parseSignal("INVALID"));
    try testing.expectEqual(@as(?u8, null), parseSignal(""));
    try testing.expectEqual(@as(?u8, null), parseSignal("SIGFOO"));
}

test "asciiEqlIgnoreCase" {
    try testing.expect(asciiEqlIgnoreCase("TERM", "TERM"));
    try testing.expect(asciiEqlIgnoreCase("term", "TERM"));
    try testing.expect(asciiEqlIgnoreCase("Term", "TERM"));
    try testing.expect(!asciiEqlIgnoreCase("TERM", "KILL"));
    try testing.expect(!asciiEqlIgnoreCase("TERM", "TERMA"));
}

test "runTimeout - help option" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{"--help"}, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: timeout") != null);
}

test "runTimeout - version option" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{"--version"}, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "timeout") != null);
}

test "runTimeout - missing operand" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{}, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "runTimeout - missing command" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{"5"}, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "runTimeout - invalid duration" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{ "abc", "true" }, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid time interval") != null);
}

test "runTimeout - invalid signal" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{ "-s", "INVALID", "5", "true" }, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid signal") != null);
}

test "runTimeout - command not found" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runTimeout(testing.allocator, &.{ "1", "this_command_surely_does_not_exist_xyz123" }, common.null_writer, stderr_buffer.writer(testing.allocator));

    // Should exit non-zero; exact code depends on how the OS reports exec failure.
    // On Linux, spawn() returns FileNotFound -> 127.
    // On macOS, posix_spawn may succeed and child exits with 1.
    try testing.expect(result != 0);
}

test "runTimeout - command completes before timeout" {
    const result = try runTimeout(testing.allocator, &.{ "10", "true" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runTimeout - command fails before timeout" {
    const result = try runTimeout(testing.allocator, &.{ "10", "false" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "runTimeout - zero timeout disables timeout" {
    const result = try runTimeout(testing.allocator, &.{ "0", "true" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runTimeout - command times out" {
    const result = try runTimeout(testing.allocator, &.{ "1", "sleep", "100" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 124), result);
}

test "runTimeout - preserve-status on timeout" {
    // Skip on Linux CI: process group signal delivery is unreliable
    // in the Zig test runner's IPC mode (--listen=-), causing the
    // child to exit 0 instead of being killed by SIGTERM.
    if (comptime builtin.os.tag == .linux) {
        if (std.process.getEnvVarOwned(testing.allocator, "CI")) |ci_val| {
            testing.allocator.free(ci_val);
            return error.SkipZigTest;
        } else |_| {}
    }

    const result = try runTimeout(testing.allocator, &.{ "--preserve-status", "1", "sleep", "100" }, common.null_writer, common.null_writer);
    // With preserve-status, exit code is 128 + signal (15 for TERM = 143)
    try testing.expectEqual(@as(u8, 143), result);
}
