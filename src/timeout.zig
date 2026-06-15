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
const time = common.time;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const prog_name = "timeout";

// C library bindings for process management
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;
extern "c" fn waitpid(pid: std.c.pid_t, stat_loc: ?*c_int, options: c_int) std.c.pid_t;
const WNOHANG: c_int = 1;

/// Signal name to number mapping
const SignalEntry = struct {
    name: []const u8,
    number: u8,
};

/// Supported signal names (POSIX subset)
/// Signal numbers come from std.posix.SIG to ensure platform-correct
/// values (e.g., USR1 is 30 on macOS but 10 on Linux).
const signal_table = [_]SignalEntry{
    .{ .name = "HUP", .number = @intFromEnum(std.posix.SIG.HUP) },
    .{ .name = "INT", .number = @intFromEnum(std.posix.SIG.INT) },
    .{ .name = "QUIT", .number = @intFromEnum(std.posix.SIG.QUIT) },
    .{ .name = "ABRT", .number = @intFromEnum(std.posix.SIG.ABRT) },
    .{ .name = "KILL", .number = @intFromEnum(std.posix.SIG.KILL) },
    .{ .name = "ALRM", .number = @intFromEnum(std.posix.SIG.ALRM) },
    .{ .name = "TERM", .number = @intFromEnum(std.posix.SIG.TERM) },
    .{ .name = "USR1", .number = @intFromEnum(std.posix.SIG.USR1) },
    .{ .name = "USR2", .number = @intFromEnum(std.posix.SIG.USR2) },
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

/// Map a spawn/exec error to the appropriate exit code (127, 126, or 125).
fn handleSpawnError(allocator: Allocator, stderr_writer: *std.Io.Writer, cmd: []const u8, err: std.process.SpawnError) u8 {
    switch (err) {
        error.FileNotFound => {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to run command '{s}': No such file or directory", .{cmd});
            return 127;
        },
        error.AccessDenied => {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to run command '{s}': Permission denied", .{cmd});
            return 126;
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to run command '{s}': {s}", .{ cmd, common.posixErrorString(err) });
            return 125;
        },
    }
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

/// Preprocess args for timeout: insert "--" before the COMMAND positional
/// so that the command's own flags (like bash -c) are not parsed by timeout.
/// Returns a new args slice with "--" inserted after DURATION.
fn preprocessArgs(allocator: Allocator, args: []const []const u8) ![]const []const u8 {
    var new_args = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer new_args.deinit(allocator);

    var positional_count: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // If we already hit --, pass everything through
        if (std.mem.eql(u8, arg, "--")) {
            // Already has a separator; pass rest through as-is
            while (i < args.len) : (i += 1) {
                try new_args.append(allocator, args[i]);
            }
            break;
        }

        if (arg.len > 1 and arg[0] == '-') {
            // Flag-like argument
            try new_args.append(allocator, arg);

            // Check if this flag takes a value (next arg consumed)
            if (arg.len > 2 and arg[1] == '-') {
                // Long flag: check for = separator (value is inline)
                if (std.mem.findScalar(u8, arg, '=') == null) {
                    // Long flags that take a value: --signal, --kill-after
                    if (std.mem.eql(u8, arg, "--signal") or std.mem.eql(u8, arg, "--kill-after")) {
                        i += 1;
                        if (i < args.len) try new_args.append(allocator, args[i]);
                    }
                    // Boolean long flags (--preserve-status, --foreground,
                    // --verbose, --help, --version) don't consume next arg
                }
            } else {
                // Short flag: -s and -k take values
                const flag_char = arg[1];
                if (arg.len == 2 and (flag_char == 's' or flag_char == 'k')) {
                    // Value is next arg
                    i += 1;
                    if (i < args.len) try new_args.append(allocator, args[i]);
                }
                // If flag is longer (-sKILL, -k5), value is inline, no skip
            }
        } else {
            // Positional argument
            positional_count += 1;
            try new_args.append(allocator, arg);

            if (positional_count == 1) {
                // This was DURATION; insert "--" so COMMAND and its
                // args don't get parsed as timeout flags
                try new_args.append(allocator, "--");
                // Append all remaining args as-is
                i += 1;
                while (i < args.len) : (i += 1) {
                    try new_args.append(allocator, args[i]);
                }
                break;
            }
        }
    }

    return new_args.toOwnedSlice(allocator);
}

/// Run the timeout utility with given arguments
pub fn runTimeout(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    const processed_args = try preprocessArgs(allocator, args);
    defer allocator.free(processed_args);

    const parsed = common.argparse.ArgParser.parseOrExit(TimeoutArgs, allocator, processed_args, prog_name, stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
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
    const timeout_nanos = time.parseTimeString(parsed.positionals[0]) catch {
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
        time.parseTimeString(ka_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid time interval '{s}'", .{ka_str});
            return 125;
        }
    else
        null;

    // Build argv for child process and run the child under the timeout.
    const cmd_args = parsed.positionals[1..];
    return runTimeout_spawnAndWait(allocator, io, stderr_writer, cmd_args, .{
        .timeout_nanos = timeout_nanos,
        .kill_after_nanos = kill_after_nanos,
        .timeout_signal = timeout_signal,
        .foreground = parsed.foreground,
        .verbose = parsed.verbose,
        .preserve_status = parsed.@"preserve-status",
    });
}

/// Timeout run options resolved from parsed arguments. Grouped into a
/// struct so the three booleans and the durations cannot be transposed
/// at the call site (Tiger Style named-argument guidance).
const RunOptions = struct {
    timeout_nanos: u64,
    kill_after_nanos: ?u64,
    timeout_signal: u8,
    foreground: bool,
    verbose: bool,
    preserve_status: bool,
};

/// Spawn the child command and wait for it under the timeout policy.
/// Returns the resolved exit code (the child's own code, 124 on timeout,
/// 125/126/127 on spawn failure, or 137 when killed by SIGKILL).
fn runTimeout_spawnAndWait(
    allocator: Allocator,
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    cmd_args: []const []const u8,
    options: RunOptions,
) u8 {
    std.debug.assert(cmd_args.len > 0);
    std.debug.assert(options.timeout_signal > 0);
    std.debug.assert(options.timeout_signal < 64);

    // Spawn child process
    const child = std.process.spawn(io, .{
        .argv = cmd_args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        // Set pgid=0 to put child in its own process group (for group kill)
        .pgid = if (options.foreground) null else @as(?std.posix.pid_t, 0),
    }) catch |err| {
        return handleSpawnError(allocator, stderr_writer, cmd_args[0], err);
    };

    const child_pid = child.id orelse return 125;

    // If timeout is 0, just wait for the command (no timeout)
    if (options.timeout_nanos == 0) {
        return waitChild(child_pid);
    }

    // Wait with timeout using polling approach
    // Poll at intervals until either the child exits or timeout expires
    const poll_interval_ns: u64 = 10 * std.time.ns_per_ms; // 10ms

    if (runTimeout_pollUntilTimeout(
        child_pid,
        options.timeout_nanos,
        poll_interval_ns,
        io,
    )) |exit_code| {
        return exit_code;
    }

    // Timeout expired - send the signal
    if (options.verbose) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "sending signal {d} to command '{s}'",
            .{ options.timeout_signal, cmd_args[0] },
        );
    }

    sendSignal(child_pid, @intCast(options.timeout_signal), !options.foreground);

    // If --kill-after is set, wait for that duration then send KILL
    if (options.kill_after_nanos) |ka_nanos| {
        if (ka_nanos > 0) {
            return runTimeout_spawnAndWait_killAfter(
                allocator,
                io,
                stderr_writer,
                cmd_args,
                child_pid,
                ka_nanos,
                poll_interval_ns,
                options,
            );
        }
    }

    // Wait for child to actually finish after signal
    const final_exit = waitChild(child_pid);

    return runTimeout_resolveExitCode(final_exit, options.preserve_status, options.timeout_signal);
}

/// Handle the --kill-after window after the timeout signal was sent.
/// Polls for early exit, otherwise sends SIGKILL and waits. Returns the
/// resolved exit code. Single caller: runTimeout_spawnAndWait.
fn runTimeout_spawnAndWait_killAfter(
    allocator: Allocator,
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    cmd_args: []const []const u8,
    child_pid: std.c.pid_t,
    kill_after_nanos: u64,
    poll_interval_ns: u64,
    options: RunOptions,
) u8 {
    std.debug.assert(cmd_args.len > 0);
    std.debug.assert(kill_after_nanos > 0);
    std.debug.assert(poll_interval_ns > 0);

    if (runTimeout_pollKillAfter(
        child_pid,
        kill_after_nanos,
        poll_interval_ns,
        options.preserve_status,
        io,
    )) |exit_code| {
        return exit_code;
    }

    // Still running - send KILL
    if (options.verbose) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "sending signal KILL to command '{s}'",
            .{cmd_args[0]},
        );
    }

    sendSignal(child_pid, 9, !options.foreground); // SIGKILL

    // SIGKILL was sent; wait for child and return its exit code
    // (typically 137 = 128+9). GNU timeout does this too,
    // regardless of --preserve-status.
    return waitChild(child_pid);
}

/// Poll the child until it exits or the timeout window elapses.
/// Returns the child's exit code if it exits within the window, or null
/// if the timeout expired while the child was still running.
fn runTimeout_pollUntilTimeout(
    child_pid: std.c.pid_t,
    timeout_nanos: u64,
    poll_interval_ns: u64,
    io: std.Io,
) ?u8 {
    std.debug.assert(timeout_nanos > 0);
    std.debug.assert(poll_interval_ns > 0);

    var elapsed_ns: u64 = 0;
    while (elapsed_ns < timeout_nanos) {
        // Try to collect the child status without blocking
        if (tryWaitChild(child_pid)) |exit_code| {
            return exit_code;
        }

        // Sleep for the poll interval, but don't overshoot the timeout
        const remaining = timeout_nanos - elapsed_ns;
        const sleep_time = @min(poll_interval_ns, remaining);
        io.sleep(std.Io.Duration.fromNanoseconds(@intCast(sleep_time)), .awake) catch {};
        elapsed_ns += sleep_time;
    }
    return null;
}

/// Poll the child during the --kill-after window after the timeout signal.
/// Returns an exit code if the child exits within the window (the child's
/// own code when preserve_status is set, otherwise 124), or null if the
/// child is still running after the window so the caller must send KILL.
fn runTimeout_pollKillAfter(
    child_pid: std.c.pid_t,
    kill_after_nanos: u64,
    poll_interval_ns: u64,
    preserve_status: bool,
    io: std.Io,
) ?u8 {
    std.debug.assert(kill_after_nanos > 0);
    std.debug.assert(poll_interval_ns > 0);

    var ka_elapsed: u64 = 0;
    while (ka_elapsed < kill_after_nanos) {
        if (tryWaitChild(child_pid)) |exit_code| {
            if (preserve_status) {
                return exit_code;
            }
            return 124;
        }

        const remaining = kill_after_nanos - ka_elapsed;
        const sleep_time = @min(poll_interval_ns, remaining);
        io.sleep(std.Io.Duration.fromNanoseconds(@intCast(sleep_time)), .awake) catch {};
        ka_elapsed += sleep_time;
    }
    return null;
}

/// Resolve the final exit code after the child finishes following a signal.
/// With preserve_status the child's own code is returned. SIGKILL (9)
/// cannot be caught, so the child always dies via signal and GNU timeout
/// returns the signal exit code (137 = 128+9) rather than 124.
fn runTimeout_resolveExitCode(final_exit: u8, preserve_status: bool, timeout_signal: u8) u8 {
    std.debug.assert(timeout_signal > 0);
    std.debug.assert(timeout_signal < 64);

    if (preserve_status) {
        return final_exit;
    }
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

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTimeout);
}

// ============================================================================
// TESTS
// ============================================================================

test "parseTimeString - basic integer seconds" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try time.parseTimeString("5"));
    try testing.expectEqual(@as(u64, 0), try time.parseTimeString("0"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), try time.parseTimeString("1"));
    try testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), try time.parseTimeString("10"));
}

test "parseTimeString - decimal seconds" {
    try testing.expectEqual(@as(u64, @intFromFloat(0.5 * std.time.ns_per_s)), try time.parseTimeString("0.5"));
    try testing.expectEqual(@as(u64, @intFromFloat(1.5 * std.time.ns_per_s)), try time.parseTimeString("1.5"));
    try testing.expectEqual(@as(u64, @intFromFloat(2.25 * std.time.ns_per_s)), try time.parseTimeString("2.25"));
}

test "parseTimeString - suffixes" {
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), try time.parseTimeString("5s"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_min), try time.parseTimeString("1m"));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try time.parseTimeString("2h"));
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_day), try time.parseTimeString("1d"));
}

test "parseTimeString - invalid formats" {
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString(""));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("s"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("abc"));
    try testing.expectError(error.InvalidTimeFormat, time.parseTimeString("5."));
}

test "parseTimeString - negative values" {
    try testing.expectError(error.NegativeTime, time.parseTimeString("-1"));
    try testing.expectError(error.NegativeTime, time.parseTimeString("-5s"));
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
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{"--help"}, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: timeout") != null);
}

test "runTimeout - version option" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{"--version"}, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "timeout") != null);
}

test "runTimeout - missing operand" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "runTimeout - missing command" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{"5"}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "runTimeout - invalid duration" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{ "abc", "true" }, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid time interval") != null);
}

test "runTimeout - invalid signal" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{ "-s", "INVALID", "5", "true" }, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid signal") != null);
}

test "runTimeout - command not found" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{ "1", "this_command_surely_does_not_exist_xyz123" }, common.null_writer, &stderr_aw.writer);

    // Should exit non-zero; exact code depends on how the OS reports exec failure.
    // On Linux, spawn() returns FileNotFound -> 127.
    // On macOS, posix_spawn may succeed and child exits with 1.
    try testing.expect(result != 0);
}

test "runTimeout - command completes before timeout" {
    const result = try runTimeout(testing.allocator, testing.io, &.{ "10", "true" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runTimeout - command fails before timeout" {
    const result = try runTimeout(testing.allocator, testing.io, &.{ "10", "false" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "runTimeout - zero timeout disables timeout" {
    const result = try runTimeout(testing.allocator, testing.io, &.{ "0", "true" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runTimeout - command times out" {
    const result = try runTimeout(testing.allocator, testing.io, &.{ "1", "sleep", "100" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 124), result);
}

test "runTimeout - preserve-status on timeout" {
    // Skip on Linux: process group signal delivery is unreliable
    // in the Zig test runner's IPC mode (--listen=-), causing the
    // child to exit 0 instead of being killed by SIGTERM.
    // This hangs indefinitely on Linux, blocking the test suite.
    if (comptime builtin.os.tag == .linux) return error.SkipZigTest;

    const result = try runTimeout(testing.allocator, testing.io, &.{ "--preserve-status", "1", "sleep", "100" }, common.null_writer, common.null_writer);
    // With preserve-status, exit code is 128 + signal (15 for TERM = 143)
    try testing.expectEqual(@as(u8, 143), result);
}

test "signal_table - USR1 matches platform signal number" {
    // The signal_table must use platform-correct values, not hardcoded
    // BSD/macOS numbers. On Linux SIGUSR1=10, on macOS SIGUSR1=30.
    // Compare against std.posix.SIG which provides OS-correct constants.
    const expected: u8 = @intFromEnum(std.posix.SIG.USR1);
    var found = false;
    for (signal_table) |entry| {
        if (std.mem.eql(u8, entry.name, "USR1")) {
            try testing.expectEqual(expected, entry.number);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "signal_table - USR2 matches platform signal number" {
    // On Linux SIGUSR2=12, on macOS SIGUSR2=31.
    const expected: u8 = @intFromEnum(std.posix.SIG.USR2);
    var found = false;
    for (signal_table) |entry| {
        if (std.mem.eql(u8, entry.name, "USR2")) {
            try testing.expectEqual(expected, entry.number);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "parseSignal - USR1 returns platform-correct value" {
    // parseSignal must return the OS-defined signal number, not a
    // hardcoded constant. This catches the bug where USR1=30 (macOS)
    // is returned on Linux where USR1 should be 10.
    const expected: u8 = @intFromEnum(std.posix.SIG.USR1);
    try testing.expectEqual(@as(?u8, expected), parseSignal("USR1"));
    try testing.expectEqual(@as(?u8, expected), parseSignal("SIGUSR1"));
    try testing.expectEqual(@as(?u8, expected), parseSignal("usr1"));
    try testing.expectEqual(@as(?u8, expected), parseSignal("sigusr1"));
}

test "parseSignal - USR2 returns platform-correct value" {
    const expected: u8 = @intFromEnum(std.posix.SIG.USR2);
    try testing.expectEqual(@as(?u8, expected), parseSignal("USR2"));
    try testing.expectEqual(@as(?u8, expected), parseSignal("SIGUSR2"));
    try testing.expectEqual(@as(?u8, expected), parseSignal("usr2"));
    try testing.expectEqual(@as(?u8, expected), parseSignal("sigusr2"));
}

test "runTimeout - no arguments returns 125" {
    // GNU timeout returns exit 125 for missing operands.
    // Exit 2 is for invalid flags only.
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
}

test "runTimeout - unknown flag returns misuse exit code" {
    // Arg parse errors (invalid flags) should return exit 2, not 125.
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{"--invalid-flag"}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.misuse)), result);
}

test "runTimeout - missing command after duration returns 125" {
    // Only providing a duration without a command returns exit 125.
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{"5"}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
}

// ============================================================================
// Audit finding tests (IMPORTANT) — wave 5
// ============================================================================

test "runTimeout - --kill-after with quick command exits 0" {
    // Verify --kill-after is accepted and does not interfere when
    // the command completes before the timeout.
    const result = try runTimeout(testing.allocator, testing.io, &.{ "-k", "5", "10", "true" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runTimeout - --kill-after invalid duration exits 125" {
    // Invalid --kill-after duration should exit 125 with an error message.
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{ "--kill-after", "abc", "10", "true" }, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 125), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid time interval") != null);
}

test "runTimeout - --verbose emits signal diagnostic on timeout" {
    // --verbose should print a diagnostic to stderr when a signal is sent.
    // Skip on Linux: process group signal delivery is unreliable in the
    // Zig test runner's IPC mode.
    if (comptime builtin.os.tag == .linux) return error.SkipZigTest;

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTimeout(testing.allocator, testing.io, &.{ "--verbose", "1", "sleep", "100" }, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 124), result);
    // --verbose should produce a diagnostic mentioning "sending signal"
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "sending signal") != null);
}

test "runTimeout - --foreground with quick command exits 0" {
    // Verify --foreground is accepted and does not interfere when
    // the command completes before the timeout.
    const result = try runTimeout(testing.allocator, testing.io, &.{ "--foreground", "10", "true" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
}
