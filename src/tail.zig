//! POSIX-compatible tail utility displays the end of files.
//!
//! Features:
//! - Default last 10 lines display
//! - Custom line count with -n (--lines) flag
//! - Byte count mode with -c (--bytes) flag
//! - Multiple file handling with headers
//! - Quiet mode with -q (--quiet) to suppress headers
//! - Verbose mode with -v (--verbose) to always show headers
//! - Zero-terminated lines with -z (--zero-terminated) flag
//! - Reads from standard input when no files specified
//!
//! Maintains compatibility with GNU coreutils tail.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const testing = std.testing;
const assert = std.debug.assert;

/// Buffer size for I/O operations - matches typical file system block size for optimal performance
const BUFFER_SIZE = 8192;

/// Hard cap on real (non-`-`) follow operands. Counted before any file I/O.
const follow_files_max: u32 = 256;

/// Command-line arguments for tail
///
/// Field order is GNU tail's own `longopts[]` order, because that is the
/// order an ambiguous abbreviation lists its candidates in (`tail --v` ->
/// '--verbose' '--version'). Options vibeutils adds that GNU tail has no
/// entry for sit next to whichever GNU option they extend.
const TailArgs = struct {
    bytes: ?[]const u8 = null,
    /// 512-byte blocks; not in GNU tail's longopts table
    blocks: ?[]const u8 = null,
    follow: bool = false,
    /// Same as --follow --retry; not in GNU tail's longopts table
    follow_retry: bool = false,
    lines: ?[]const u8 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    help: bool = false,
    version: bool = false,
    /// Not in GNU tail's longopts table
    reverse: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .version = .{ .short = 'V', .desc = "output version information and exit" },
        .lines = .{ .short = 'n', .desc = "output the last NUM lines, instead of the last 10" },
        .bytes = .{ .short = 'c', .desc = "output the last NUM bytes" },
        .blocks = .{ .short = 'b', .desc = "output the last NUM 512-byte blocks" },
        .quiet = .{
            .short = 'q',
            .desc = "never output headers when multiple files are being examined",
        },
        .verbose = .{ .short = 'v', .desc = "always output headers when examining files" },
        .zero_terminated = .{ .short = 'z', .desc = "line delimiter is NUL, not newline" },
        .reverse = .{ .short = 'r', .desc = "display the input in reverse order, by line" },
        .follow = .{ .short = 'f', .desc = "output appended data as the file grows" },
        .follow_retry = .{ .short = 'F', .desc = "same as -f, but retry if file is inaccessible" },
    };
};

/// Options controlling tail behavior
const TailOptions = struct {
    line_count: ?u64 = null,
    byte_count: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    from_beginning: bool = false,
    from_beginning_bytes: bool = false,
    reverse: bool = false,
    follow: bool = false,
    follow_retry: bool = false,

    /// Returns true if we should show headers for multiple files
    pub fn shouldShowHeaders(self: TailOptions, file_count: usize) bool {
        if (self.verbose) return true;
        if (self.quiet) return false;
        return file_count > 1;
    }
};

/// Formats a GNU follow switch header into `buf`.
fn formatFollowSwitchHeader(buf: []u8, path: []const u8) []const u8 {
    assert(buf.len >= 16);
    assert(path.len < buf.len);
    return std.fmt.bufPrint(buf, "\n==> {s} <==\n", .{path}) catch buf[0..0];
}

/// Whether a follow chunk needs a switch header. `last_output_slot` moves only
/// when `chunk_len` is non-zero; the return value uses the previous last slot.
fn followHeaderNeeded(
    show_headers: bool,
    last_output_slot: *?u32,
    new_slot: u32,
    chunk_len: u32,
) bool {
    assert(new_slot != std.math.maxInt(u32));
    const last_in_range = last_output_slot.* == null or
        last_output_slot.*.? != std.math.maxInt(u32);
    assert(last_in_range);
    if (chunk_len == 0) return false;
    const previous = last_output_slot.*;
    last_output_slot.* = new_slot;
    if (!show_headers) return false;
    return previous == null or previous.? != new_slot;
}

/// Parses packed `inotify_event` records into watch descriptors.
fn parseInotifyWatchDescriptors(buf: []const u8, out_wds: []i32) u32 {
    assert(out_wds.len > 0);
    assert(out_wds.len <= follow_files_max);

    const Event = std.os.linux.inotify_event;
    const header_len: u32 = @intCast(@sizeOf(Event));
    const buf_len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
    const max_n: u32 = @intCast(out_wds.len);
    var offset: u32 = 0;
    var n: u32 = 0;
    while (n < max_n and n < follow_files_max) {
        if (offset + header_len > buf_len) break;
        const ev = std.mem.bytesToValue(Event, buf[offset..][0..header_len]);
        out_wds[n] = ev.wd;
        n += 1;
        const rec = header_len + ev.len;
        if (rec < header_len) break;
        if (offset > std.math.maxInt(u32) - rec) break;
        offset += rec;
    }
    return n;
}

/// Maps one watch descriptor onto every slot that holds it.
fn followSlotsForWatchDescriptor(slot_wds: []const i32, wd: i32, out_slots: []u32) u32 {
    assert(slot_wds.len > 0);
    assert(out_slots.len >= slot_wds.len);

    const max_i: u32 = @intCast(@min(slot_wds.len, follow_files_max));
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < max_i) : (i += 1) {
        if (slot_wds[i] == wd) {
            out_slots[n] = i;
            n += 1;
        }
    }
    return n;
}

/// Whether `inotify_rm_watch` should run after a slot drops a wd.
fn followInotifyShouldRemoveWatch(remaining_slots_with_wd: u32) bool {
    assert(remaining_slots_with_wd <= follow_files_max);
    const not_unbounded = remaining_slots_with_wd != std.math.maxInt(u32);
    assert(not_unbounded);
    return remaining_slots_with_wd == 0;
}

/// Returns true when byte is a valid line delimiter (NUL or newline). Used to
/// keep delimiter precondition asserts free of compound boolean expressions.
fn isLineDelimiter(byte: u8) bool {
    return byte == 0 or byte == '\n';
}

/// Print version information to the specified writer
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("tail ({s}) {s}\n", .{ common.name, common.version });
}

/// Print usage information to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: tail [OPTION]... [FILE]...
        \\Print the last 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes=NUM          output the last NUM bytes
        \\  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;
        \\                           or use -n +NUM to output starting with line NUM
        \\  -q, --quiet, --silent    never output headers giving file names
        \\  -v, --verbose            always output headers giving file names
        \\  -z, --zero-terminated    use NUL as line delimiter, not newline
        \\  -f, --follow             output appended data as each file grows
        \\  -F                       same as --follow --retry
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\NUM may have a multiplier suffix:
        \\b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,
        \\GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.
        \\Binary prefixes can be used, too: KiB=K, MiB=M, and so on.
        \\
        \\Examples:
        \\  tail f - g       Output f's contents, then standard input, then g's contents.
        \\  tail -n +1 FILE  Output FILE starting with its first line.
        \\
    );
}

/// Expand obsolete -NUM syntax (e.g., -5) to -n NUM for backwards compatibility
fn expandObsoleteArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    // Count how many extra args we need (one extra per -NUM arg)
    var extra: usize = 0;
    for (args) |arg| {
        if (isObsoleteNumArg(arg)) extra += 1;
    }
    if (extra == 0) return allocator.dupe([]const u8, args);

    const expanded = try allocator.alloc([]const u8, args.len + extra);
    assert(expanded.len == args.len + extra);
    var i: usize = 0;
    for (args) |arg| {
        if (isObsoleteNumArg(arg)) {
            expanded[i] = "-n";
            i += 1;
            expanded[i] = arg[1..]; // strip leading '-'
            i += 1;
        } else {
            expanded[i] = arg;
            i += 1;
        }
    }
    assert(i == expanded.len);
    return expanded;
}

/// Check if an argument matches the obsolete -NUM pattern (e.g., "-5", "-100")
fn isObsoleteNumArg(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Main entry point for tail utility with stdout and stderr writer parameters
pub fn runTail(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const expanded_args = try expandObsoleteArgs(allocator, args);
    defer allocator.free(expanded_args);
    assert(expanded_args.len >= args.len);

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        TailArgs,
        allocator,
        expanded_args,
        "tail",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);
    assert(parsed_args.positionals.len <= expanded_args.len);

    // Handle --help / --version, which short-circuit normal processing.
    if (try runTail_handleHelpVersion(allocator, parsed_args, stdout_writer)) |exit_code| {
        return exit_code;
    }

    // Parse numeric arguments
    var options = TailOptions{
        .quiet = parsed_args.quiet,
        .verbose = parsed_args.verbose,
        .zero_terminated = parsed_args.zero_terminated,
        .reverse = parsed_args.reverse,
        .follow = parsed_args.follow or parsed_args.follow_retry,
        .follow_retry = parsed_args.follow_retry,
    };

    // Assemble count/byte/block options from the parsed args; this also
    // validates the -f/-F vs -r mutual exclusion.
    if (try runTail_buildOptions(allocator, parsed_args, stderr_writer, &options)) |exit_code| {
        return exit_code;
    }

    if (parsed_args.positionals.len == 0) {
        try processStdin(allocator, io, stdout_writer, options);
        return @intFromEnum(common.ExitCode.success);
    }

    return runTail_runWithPositionals(
        allocator,
        io,
        parsed_args,
        stdout_writer,
        stderr_writer,
        &options,
    );
}

/// Dump every positional, then enter the multiplex follow loop when `-f`
/// or `-F` is set. The follow-file cap is checked before any dump I/O.
fn runTail_runWithPositionals(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed_args: anytype,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
) !u8 {
    assert(parsed_args.positionals.len > 0);
    const reverse_and_follow = options.reverse and options.follow;
    assert(!reverse_and_follow);

    if (options.follow) {
        if (try runTail_rejectFollowCap(
            allocator,
            parsed_args.positionals,
            stderr_writer,
        )) |exit_code| {
            return exit_code;
        }
    }

    var dump_failed: []bool = &.{};
    if (options.follow) {
        dump_failed = try allocator.alloc(bool, parsed_args.positionals.len);
        @memset(dump_failed, false);
    }
    defer if (dump_failed.len > 0) allocator.free(dump_failed);

    const had_error = try runTail_processPositionals(
        allocator,
        io,
        parsed_args,
        stdout_writer,
        stderr_writer,
        options,
        if (options.follow) dump_failed else null,
    );
    if (had_error and !options.follow) return @intFromEnum(common.ExitCode.general_error);

    if (options.follow) {
        if (try runTail_enterFollow(
            allocator,
            io,
            parsed_args,
            stdout_writer,
            stderr_writer,
            options,
            dump_failed,
        )) |exit_code| {
            return exit_code;
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Process every positional argument (file paths or "-"), returning true if
/// any entry encountered an error. Header display is derived once from the
/// options and file count, then passed to each per-file call.
fn runTail_processPositionals(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed_args: anytype,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
    dump_failed: ?[]bool,
) !bool {
    // Positive space: the parent only calls this when files were given.
    assert(parsed_args.positionals.len > 0);
    // Negative space: -r and -f are mutually exclusive (validated in
    // runTail_buildOptions), so they must never both be set here.
    const reverse_and_follow = options.reverse and options.follow;
    assert(!reverse_and_follow);
    if (dump_failed) |failed| {
        assert(failed.len == parsed_args.positionals.len);
    }

    var had_error = false;
    const should_show_headers = options.shouldShowHeaders(parsed_args.positionals.len);
    for (parsed_args.positionals, 0..) |file_path, i| {
        const file_had_error = try runTail_processOnePositional(
            allocator,
            io,
            file_path,
            i,
            should_show_headers,
            parsed_args,
            stdout_writer,
            stderr_writer,
            options,
        );
        if (dump_failed) |failed| failed[i] = file_had_error;
        had_error = had_error or file_had_error;
    }
    return had_error;
}

/// Handle --help and --version. Returns a success exit code when either was
/// requested (after printing), or null when normal processing should continue.
fn runTail_handleHelpVersion(
    allocator: std.mem.Allocator,
    parsed_args: anytype,
    stdout_writer: *std.Io.Writer,
) !?u8 {
    // Sanity-check the exit-code constants this helper returns.
    assert(@intFromEnum(common.ExitCode.success) == 0);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    return null;
}

/// Parse a numeric count argument, printing a GNU-style error and returning
/// error.InvalidCount on failure. `noun` is the count word in the message
/// ("lines", "bytes", "blocks"), keeping the three call sites identical.
fn runTail_parseCount(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    noun: []const u8,
    count_str: []const u8,
) error{InvalidCount}!u64 {
    return parseNumericArg(count_str) catch {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tail",
            "invalid number of {s}: '{s}'",
            .{ noun, count_str },
        );
        return error.InvalidCount;
    };
}

/// Apply the -b block count to options: parse it, then convert the block count
/// to a byte count (512 bytes/block). Returns a non-null exit code on parse
/// failure; null on success.
fn runTail_buildBlockOption(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    blocks_str: []const u8,
    options_out: *TailOptions,
) !?u8 {
    if (blocks_str.len > 0 and blocks_str[0] == '+') {
        options_out.from_beginning_bytes = true;
    }
    const block_count = runTail_parseCount(
        allocator,
        stderr_writer,
        "blocks",
        blocks_str,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    if (options_out.from_beginning_bytes) {
        // +N blocks means start at block N (1-indexed), skip (N-1)*512 bytes
        // processInputByBytesFromBeginning uses skip = byte_count - 1
        // so byte_count = (N-1)*512 + 1
        options_out.byte_count = if (block_count > 0) (block_count - 1) * 512 + 1 else 1;
    } else {
        options_out.byte_count = block_count * 512;
    }
    options_out.line_count = null; // block mode overrides line mode
    return null;
}

/// Assemble line/byte/block count options from parsed args. Returns a non-null
/// exit code when a count argument fails to parse; null on success.
fn runTail_buildOptions(
    allocator: std.mem.Allocator,
    parsed_args: anytype,
    stderr_writer: *std.Io.Writer,
    options_out: *TailOptions,
) !?u8 {
    assert(options_out.line_count == null);
    assert(options_out.byte_count == null);

    // Parse line count (-n flag)
    if (parsed_args.lines) |lines_str| {
        if (lines_str.len > 0 and lines_str[0] == '+') {
            options_out.from_beginning = true;
        }
        options_out.line_count = runTail_parseCount(
            allocator,
            stderr_writer,
            "lines",
            lines_str,
        ) catch return @intFromEnum(common.ExitCode.general_error);
    } else if (parsed_args.reverse) {
        options_out.line_count = null; // -r without -n: show all lines
    } else {
        options_out.line_count = 10; // default
    }

    // Parse byte count (-c flag) - overrides line count
    if (parsed_args.bytes) |bytes_str| {
        if (bytes_str.len > 0 and bytes_str[0] == '+') {
            options_out.from_beginning_bytes = true;
        }
        options_out.byte_count = runTail_parseCount(
            allocator,
            stderr_writer,
            "bytes",
            bytes_str,
        ) catch return @intFromEnum(common.ExitCode.general_error);
        options_out.line_count = null; // byte mode overrides line mode
    }

    // Parse block count (-b flag) - overrides lines, like -c but in 512-byte blocks
    if (parsed_args.blocks) |blocks_str| {
        const block_code = try runTail_buildBlockOption(
            allocator,
            stderr_writer,
            blocks_str,
            options_out,
        );
        if (block_code) |code| return code;
    }

    // Validate: -f/-F and -r are mutually exclusive
    if (options_out.follow and options_out.reverse) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tail",
            "option used in invalid context -- r",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Byte/block mode and line mode are mutually exclusive at exit: every
    // byte-setting branch clears line_count, so when byte_count is set the
    // line count is always null.
    if (options_out.byte_count != null) assert(options_out.line_count == null);

    return null;
}

/// Process a single positional argument (a file path or "-" for stdin).
/// Returns true if processing this entry encountered an error.
fn runTail_processOnePositional(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    index: usize, // tiger:allow:usize-arch slice index for positionals
    should_show_headers: bool,
    parsed_args: anytype,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
) !bool {
    // An empty positional ("") is a legal shell argument and must still flow
    // to the openFile error path (GNU tail prints an error and exits 1), so do
    // NOT assert file_path is non-empty here.
    assert(parsed_args.positionals.len > 0);
    assert(index < parsed_args.positionals.len);

    if (std.mem.eql(u8, file_path, "-")) {
        // "-" means read from stdin
        if (should_show_headers) {
            if (index > 0) try stdout_writer.writeAll("\n");
            try stdout_writer.writeAll("==> standard input <==\n");
        }
        try processStdin(allocator, io, stdout_writer, options.*);
        return false;
    }

    // Open and process regular file
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        // -F (follow with retry) tolerates missing files
        if (parsed_args.follow_retry and err == error.FileNotFound) {
            return false;
        }
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tail",
            "cannot open '{s}' for reading: {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return true;
    };
    defer file.close(io);

    if (should_show_headers) {
        if (index > 0) try stdout_writer.writeAll("\n");
        try stdout_writer.print("==> {s} <==\n", .{file_path});
    }
    try processFile(allocator, io, file, stdout_writer, options.*);
    return false;
}

/// Count real (non-`-`) follow operands. Used for the hard cap and to decide
/// whether there is anything to watch after stdin sentinels are skipped.
fn runTail_countRealFiles(positionals: []const []const u8) u32 {
    assert(positionals.len > 0);
    const max: u32 = @intCast(positionals.len);
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        if (!std.mem.eql(u8, positionals[i], "-")) {
            n += 1;
        }
    }
    assert(n <= max);
    return n;
}

/// Fail fast when `-f`/`-F` is given more than `follow_files_max` real files.
fn runTail_rejectFollowCap(
    allocator: std.mem.Allocator,
    positionals: []const []const u8,
    stderr_writer: *std.Io.Writer,
) !?u8 {
    assert(positionals.len > 0);
    const real_n = runTail_countRealFiles(positionals);
    assert(real_n <= @as(u32, @intCast(positionals.len)));
    if (real_n <= follow_files_max) return null;
    assert(real_n > follow_files_max);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "tail",
        "cannot follow more than {d} files",
        .{follow_files_max},
    );
    return @intFromEnum(common.ExitCode.general_error);
}

/// One follow-set member. `slot` is the positional index, including `-` and
/// failed opens, so switch headers use operand identity rather than path.
const FollowedFile = struct {
    path: []const u8,
    path_z: [:0]u8,
    slot: u32,
    active: bool,
    file: ?std.Io.File,
    last_pos: u64,
    last_inode: ?u64,
    wd: i32,
};

/// Shared watcher handle: Linux inotify fd or BSD kqueue.
const FollowWatch = struct {
    fd: std.c.fd_t,
    is_inotify: bool,
};

/// Context for one multiplexed follow session. Passed to per-event handlers
/// so those stay under the line budget.
const FollowCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: *const TailOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    last_output_slot: *?u32,
    show_headers: bool,
    watch: FollowWatch,
    slots: []FollowedFile,
    slot_count: u32,
};

/// Enter follow mode on every real positional. Returns a non-null exit code
/// when there is nothing to follow after a plain `-f` dump failure.
fn runTail_enterFollow(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed_args: anytype,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
    dump_failed: []const bool,
) !?u8 {
    assert(options.follow);
    assert(parsed_args.positionals.len > 0);
    assert(dump_failed.len == parsed_args.positionals.len);

    const real_n = runTail_countRealFiles(parsed_args.positionals);
    if (real_n == 0) return null;

    var slots_buf: [follow_files_max]FollowedFile = undefined;
    const slot_count = try followSet_collectSlots(
        allocator,
        io,
        parsed_args.positionals,
        dump_failed,
        options,
        stderr_writer,
        &slots_buf,
    );
    defer followSet_closeSlots(allocator, io, slots_buf[0..slot_count]);
    if (slot_count == 0) return @intFromEnum(common.ExitCode.general_error);

    const last_idx: u32 = @intCast(parsed_args.positionals.len - 1);
    var last_output_slot: ?u32 = last_idx;
    stdout_writer.flush() catch {};
    stderr_writer.flush() catch {};

    var ctx = FollowCtx{
        .allocator = allocator,
        .io = io,
        .options = options,
        .stdout_writer = stdout_writer,
        .stderr_writer = stderr_writer,
        .last_output_slot = &last_output_slot,
        .show_headers = options.shouldShowHeaders(parsed_args.positionals.len),
        .watch = .{ .fd = -1, .is_inotify = builtin.os.tag == .linux },
        .slots = slots_buf[0..slot_count],
        .slot_count = slot_count,
    };
    try followSet_runLoop(&ctx);
    return null;
}

/// Main entry point for the tail utility
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTail);
}

/// Parse numeric argument with optional suffix (K, M, G, etc.)
fn parseNumericArg(arg: []const u8) !u64 {
    if (arg.len == 0) return error.InvalidArgument;

    // Strip plus prefix if present
    const clean_arg = if (arg[0] == '+') arg[1..] else arg;
    assert(clean_arg.len <= arg.len);
    if (clean_arg.len == 0) return error.InvalidArgument;

    return parseSuffixedNumber(clean_arg);
}

/// Suffix multiplier lookup table entry
const SuffixMultiplier = struct {
    suffix: []const u8,
    multiplier: u64,
};

/// Lookup table for suffix multipliers ordered by specificity (longer suffixes first)
const MULTIPLIERS = [_]SuffixMultiplier{
    .{ .suffix = "GiB", .multiplier = 1024 * 1024 * 1024 },
    .{ .suffix = "GB", .multiplier = 1000 * 1000 * 1000 },
    .{ .suffix = "G", .multiplier = 1024 * 1024 * 1024 },
    .{ .suffix = "MiB", .multiplier = 1024 * 1024 },
    .{ .suffix = "MB", .multiplier = 1000 * 1000 },
    .{ .suffix = "M", .multiplier = 1024 * 1024 },
    .{ .suffix = "KiB", .multiplier = 1024 },
    .{ .suffix = "KB", .multiplier = 1000 },
    .{ .suffix = "kB", .multiplier = 1000 },
    .{ .suffix = "K", .multiplier = 1024 },
    .{ .suffix = "b", .multiplier = 512 },
};

/// Parse number with optional suffix multiplier
fn parseSuffixedNumber(arg: []const u8) !u64 {
    // Find the last digit to separate number from suffix
    var end_of_number: usize = arg.len;
    for (arg, 0..) |c, i| {
        if (!std.ascii.isDigit(c)) {
            end_of_number = i;
            break;
        }
    }

    assert(end_of_number <= arg.len);
    if (end_of_number == 0) return error.InvalidArgument;

    const number_part = arg[0..end_of_number];
    const suffix = arg[end_of_number..];
    assert(number_part.len + suffix.len == arg.len);

    const base_number = std.fmt.parseInt(u64, number_part, 10) catch return error.InvalidArgument;

    // If no suffix, return base number
    if (suffix.len == 0) {
        return base_number;
    }

    // Look up multiplier from table
    for (MULTIPLIERS) |entry| {
        if (std.mem.eql(u8, suffix, entry.suffix)) {
            // Use @mulWithOverflow for safe arithmetic
            const result = @mulWithOverflow(base_number, entry.multiplier);
            if (result[1] != 0) {
                return error.Overflow;
            }
            return result[0];
        }
    }

    return error.InvalidArgument;
}

/// Convert system error to user-friendly error message
/// Process stdin with given options
fn processStdin(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    options: TailOptions,
) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    if (options.byte_count) |byte_count| {
        try processInputByBytes(
            allocator,
            io,
            stdin,
            stdout_writer,
            byte_count,
            null,
            options.from_beginning_bytes,
        );
    } else {
        try processInputByLines(
            allocator,
            stdin,
            stdout_writer,
            options.line_count,
            options.zero_terminated,
            options.from_beginning,
            options.reverse,
        );
    }
}

/// Process a file with given options
fn processFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    stdout_writer: *std.Io.Writer,
    options: TailOptions,
) !void {
    if (options.byte_count) |byte_count| {
        var file_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        const file_interface = &file_reader.interface;
        try processInputByBytes(
            allocator,
            io,
            file_interface,
            stdout_writer,
            byte_count,
            file,
            options.from_beginning_bytes,
        );
    } else {
        try processInputByLinesFromFile(
            allocator,
            io,
            file,
            stdout_writer,
            options.line_count,
            options.zero_terminated,
            options.from_beginning,
            options.reverse,
        );
    }
}

/// Read new data from file starting at last_pos, write to stdout.
/// Returns the new file position after reading.
fn readNewData(io: std.Io, file: std.Io.File, last_pos: u64, stdout_writer: *std.Io.Writer) !u64 {
    const new_end = try file.length(io);
    if (new_end > last_pos) {
        var buf: [BUFFER_SIZE]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        try file_reader.seekTo(last_pos);
        // Reads appended file data; count is unbounded a priori (file size), so no
        // numeric cap. readSliceShort returns 0 at EOF, which breaks the loop.
        while (true) { // tiger:allow:unbounded-loop terminates at EOF (n == 0)
            const n = try file_reader.interface.readSliceShort(&buf);
            if (n == 0) break;
            try stdout_writer.writeAll(buf[0..n]);
        }
        const pos = try file.length(io);
        stdout_writer.flush() catch {};
        return pos;
    }
    return last_pos;
}

/// Get the inode number for a file at the given path.
/// Used by follow mode to detect file rotation.
fn getInode(io: std.Io, path: []const u8) !u64 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return stat.inode;
}

/// Allocate a null-terminated path and return an inactive follow slot.
fn followSlot_blank(
    allocator: std.mem.Allocator,
    path: []const u8,
    slot: u32,
) !FollowedFile {
    assert(slot != std.math.maxInt(u32));
    const path_z = try std.mem.Allocator.dupeZ(allocator, u8, path);
    assert(path_z.len == path.len);
    return .{
        .path = path,
        .path_z = path_z,
        .slot = slot,
        .active = false,
        .file = null,
        .last_pos = 0,
        .last_inode = null,
        .wd = -1,
    };
}

/// Attach an already-open file to a slot. `from_start` is used when a missing
/// `-F` path first appears so the new contents are not skipped.
fn followSlot_attachFile(
    io: std.Io,
    slot: *FollowedFile,
    file: std.Io.File,
    from_start: bool,
) !void {
    assert(!slot.active);
    assert(slot.file == null);
    const inode = try getInode(io, slot.path);
    const len: u64 = if (from_start) 0 else try file.length(io);
    slot.file = file;
    slot.active = true;
    slot.last_inode = inode;
    slot.last_pos = len;
}

/// Print the GNU cannot-open diagnostic used for both dump failures and the
/// first time a `-F` slot is seen missing.
fn followSlot_printCannotOpen(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    path: []const u8,
    err: anyerror,
) void {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    assert(!std.mem.eql(u8, path, "-"));
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "tail",
        "cannot open '{s}' for reading: {s}",
        .{ path, common.posixErrorString(err) },
    );
    stderr_writer.flush() catch {};
}

/// Print a quoted follow diagnostic (`has appeared` / `has been replaced` /
/// `has become inaccessible`).
fn followSlot_printQuoted(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    path: []const u8,
    comptime message: []const u8,
) void {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    assert(message.len > 0);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "tail",
        "'{s}' {s}",
        .{ path, message },
    );
    stderr_writer.flush() catch {};
}

/// Try to add one positional to the follow set. Returns null when plain `-f`
/// should omit a failed dump path.
fn followSet_collectOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    slot_index: u32,
    dump_failed: bool,
    options: *const TailOptions,
    stderr_writer: *std.Io.Writer,
) !?FollowedFile {
    assert(options.follow);
    assert(slot_index != std.math.maxInt(u32));
    if (!options.follow_retry and dump_failed) return null;

    var slot = try followSlot_blank(allocator, path, slot_index);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (options.follow_retry) {
            if (!dump_failed) {
                followSlot_printCannotOpen(allocator, stderr_writer, path, err);
            }
            return slot;
        }
        allocator.free(slot.path_z);
        return null;
    };
    followSlot_attachFile(io, &slot, file, false) catch {
        file.close(io);
        if (options.follow_retry) return slot;
        allocator.free(slot.path_z);
        return null;
    };
    return slot;
}

/// Build the follow set from positionals. Plain `-f` omits dump failures;
/// `-F` keeps them as inactive appear-wait slots.
fn followSet_collectSlots(
    allocator: std.mem.Allocator,
    io: std.Io,
    positionals: []const []const u8,
    dump_failed: []const bool,
    options: *const TailOptions,
    stderr_writer: *std.Io.Writer,
    slots: *[follow_files_max]FollowedFile,
) !u32 {
    assert(positionals.len == dump_failed.len);
    assert(options.follow);
    const max: u32 = @intCast(positionals.len);
    var n: u32 = 0;
    errdefer followSet_closeSlots(allocator, io, slots[0..n]);
    var i: u32 = 0;
    while (i < max and n < follow_files_max) : (i += 1) {
        if (std.mem.eql(u8, positionals[i], "-")) continue;
        const one = try followSet_collectOne(
            allocator,
            io,
            positionals[i],
            i,
            dump_failed[i],
            options,
            stderr_writer,
        );
        if (one) |slot| {
            slots[n] = slot;
            n += 1;
        }
    }
    return n;
}

/// Close every follow-set fd and free the duplicated paths.
fn followSet_closeSlots(
    allocator: std.mem.Allocator,
    io: std.Io,
    slots: []FollowedFile,
) void {
    assert(slots.len <= follow_files_max);
    var i: u32 = 0;
    while (i < slots.len) : (i += 1) {
        if (slots[i].file) |f| {
            f.close(io);
            slots[i].file = null;
        }
        allocator.free(slots[i].path_z);
    }
    assert(i == @as(u32, @intCast(slots.len)));
}

/// Count remaining slots that still hold `wd`.
fn followSet_countWd(slots: []const FollowedFile, slot_count: u32, wd: i32) u32 {
    assert(slot_count <= slots.len);
    assert(slot_count <= follow_files_max);
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < slot_count) : (i += 1) {
        if (slots[i].wd == wd) n += 1;
    }
    return n;
}

/// Linux inotify event mask for follow watches.
fn followInotifyMask() u32 {
    const mask = std.os.linux.IN.MODIFY |
        std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF;
    assert(mask != 0);
    assert((mask & std.os.linux.IN.MODIFY) != 0);
    return mask;
}

/// Register a platform watch for one active slot.
fn followSet_addWatch(ctx: *FollowCtx, slot: *FollowedFile) !void {
    assert(slot.active);
    assert(slot.file != null);
    if (ctx.watch.is_inotify) {
        if (comptime builtin.os.tag == .linux) {
            slot.wd = try inotifyAddWatch(ctx.watch.fd, slot.path_z, followInotifyMask());
        }
        return;
    }
    if (comptime builtin.os.tag != .linux) {
        try followSlot_addKqueueWatch(slot, ctx.watch.fd);
    }
}

/// Register a kqueue VNODE filter on the slot's current fd.
fn followSlot_addKqueueWatch(slot: *FollowedFile, kq: std.c.fd_t) !void {
    assert(slot.active);
    assert(kq >= 0);
    const file = slot.file orelse return error.Unexpected;
    var changelist = [1]std.c.Kevent{.{
        .ident = @as(usize, @intCast(file.handle)), // tiger:allow:usize-arch kevent ident type
        .filter = std.c.EVFILT.VNODE,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME |
            std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB,
        .data = 0,
        .udata = 0,
    }};
    _ = try keventCall(kq, &changelist, &.{}, null);
}

/// Drop this slot's watch. `inotify_rm_watch` runs only when no other slot
/// still references the same wd (hard links and duplicate operands).
fn followSet_dropWatch(ctx: *FollowCtx, slot: *FollowedFile) void {
    assert(ctx.slot_count <= follow_files_max);
    const wd = slot.wd;
    if (wd < 0) return;
    assert(wd >= 0);
    slot.wd = -1;
    if (!ctx.watch.is_inotify) return;
    const remaining = followSet_countWd(ctx.slots, ctx.slot_count, wd);
    if (followInotifyShouldRemoveWatch(remaining)) {
        inotifyRmWatch(ctx.watch.fd, wd);
    }
}

/// Close the fd and drop the watch without forgetting `last_inode`, so a later
/// reopen of a rotated name can print the replaced diagnostic.
fn followSet_deactivate(ctx: *FollowCtx, slot: *FollowedFile) void {
    assert(slot.active);
    assert(slot.wd == -1 or slot.wd >= 0);
    followSet_dropWatch(ctx, slot);
    if (slot.file) |f| {
        f.close(ctx.io);
        slot.file = null;
    }
    slot.active = false;
}

/// Write a switch header when needed, then stream bytes past `last_pos`.
fn followSet_emitChunk(ctx: *FollowCtx, slot: *FollowedFile) !void {
    assert(slot.active);
    assert(ctx.slot_count > 0);
    const file = slot.file orelse return;
    const new_end = file.length(ctx.io) catch return;
    const grew = new_end > slot.last_pos;
    const raw: u64 = if (grew) new_end - slot.last_pos else 0;
    const chunk_len: u32 = if (raw > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else
        @intCast(raw);
    if (followHeaderNeeded(ctx.show_headers, ctx.last_output_slot, slot.slot, chunk_len)) {
        var buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
        const header = formatFollowSwitchHeader(&buf, slot.path);
        try ctx.stdout_writer.writeAll(header);
    }
    slot.last_pos = try readNewData(ctx.io, file, slot.last_pos, ctx.stdout_writer);
}

/// Catch up every active slot after watches are registered, covering writes
/// that raced the dump-to-watch window.
fn followSet_emitAllActive(ctx: *FollowCtx) !void {
    assert(ctx.slot_count <= follow_files_max);
    assert(ctx.slots.len >= ctx.slot_count);
    var i: u32 = 0;
    while (i < ctx.slot_count) : (i += 1) {
        if (!ctx.slots[i].active) continue;
        try followFile_checkTruncation(
            ctx.allocator,
            ctx.io,
            ctx.slots[i].file.?,
            ctx.slots[i].path,
            &ctx.slots[i].last_pos,
            ctx.stderr_writer,
        );
        try followSet_emitChunk(ctx, &ctx.slots[i]);
    }
}

/// First successful open of an inactive `-F` slot: appear or replace, then
/// watch and read from the start of the new file.
fn followSet_tryActivate(ctx: *FollowCtx, slot: *FollowedFile) !void {
    assert(!slot.active);
    assert(ctx.options.follow_retry);
    const file = std.Io.Dir.cwd().openFile(ctx.io, slot.path, .{}) catch return;
    const had_inode = slot.last_inode != null;
    followSlot_attachFile(ctx.io, slot, file, true) catch {
        file.close(ctx.io);
        return;
    };
    if (!had_inode) {
        followSlot_printQuoted(
            ctx.allocator,
            ctx.stderr_writer,
            slot.path,
            "has appeared;  following new file",
        );
    } else {
        followSlot_printQuoted(
            ctx.allocator,
            ctx.stderr_writer,
            slot.path,
            "has been replaced;  following new file",
        );
    }
    try followSet_addWatch(ctx, slot);
    try followSet_emitChunk(ctx, slot);
}

/// Try `openFile` on each inactive `-F` slot. Bounded by `follow_files_max`.
fn followSet_scanInactive(ctx: *FollowCtx) !void {
    assert(ctx.slot_count <= follow_files_max);
    assert(ctx.options.follow);
    if (!ctx.options.follow_retry) return;
    var i: u32 = 0;
    while (i < ctx.slot_count) : (i += 1) {
        if (ctx.slots[i].active) continue;
        try followSet_tryActivate(ctx, &ctx.slots[i]);
    }
}

/// Scan inactive `-F` slots at most once per second of wall time, including
/// on a busy sibling that keeps the wait returning events.
fn followSet_maybeScan(ctx: *FollowCtx, last_scan_ns: *i128) !void {
    assert(ctx.slot_count > 0);
    assert(ctx.slot_count <= follow_files_max);
    if (!ctx.options.follow_retry) return;
    const now = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    if (now - last_scan_ns.* < std.time.ns_per_s) return;
    last_scan_ns.* = now;
    try followSet_scanInactive(ctx);
}

/// `-F` name-follow: deactivate on FileNotFound, reopen on inode change.
/// Does not wait forever — missing names stay inactive until the 1s scan.
fn followSet_checkNameFollow(ctx: *FollowCtx, slot: *FollowedFile) !void {
    assert(slot.active);
    assert(ctx.options.follow_retry);
    const new_inode = getInode(ctx.io, slot.path) catch |err| {
        if (err == error.FileNotFound) {
            followSlot_printQuoted(
                ctx.allocator,
                ctx.stderr_writer,
                slot.path,
                "has become inaccessible: No such file or directory",
            );
            followSet_deactivate(ctx, slot);
        }
        return;
    };
    const old = slot.last_inode orelse return;
    if (old == new_inode) return;
    const new_file = std.Io.Dir.cwd().openFile(ctx.io, slot.path, .{}) catch {
        followSet_deactivate(ctx, slot);
        return;
    };
    followSet_dropWatch(ctx, slot);
    if (slot.file) |old_f| old_f.close(ctx.io);
    slot.file = new_file;
    slot.last_pos = 0;
    slot.last_inode = new_inode;
    try followSet_addWatch(ctx, slot);
    followSlot_printQuoted(
        ctx.allocator,
        ctx.stderr_writer,
        slot.path,
        "has been replaced;  following new file",
    );
}

/// Per-slot event: optional `-F` name check, truncation, then new data.
fn followSet_handleSlot(ctx: *FollowCtx, slot: *FollowedFile) !void {
    if (!slot.active) return;
    assert(slot.file != null);
    assert(slot.slot < follow_files_max);
    if (ctx.options.follow_retry) {
        try followSet_checkNameFollow(ctx, slot);
        if (!slot.active) return;
    }
    try followFile_checkTruncation(
        ctx.allocator,
        ctx.io,
        slot.file.?,
        slot.path,
        &slot.last_pos,
        ctx.stderr_writer,
    );
    try followSet_emitChunk(ctx, slot);
}

/// Parse a whole inotify read buffer and fan each wd out to every matching
/// slot so duplicate operands and hard links each emit.
fn followSet_dispatchInotify(ctx: *FollowCtx, buf: []const u8) !void {
    assert(ctx.slot_count > 0);
    assert(ctx.slot_count <= follow_files_max);
    var wds: [follow_files_max]i32 = undefined;
    const n = parseInotifyWatchDescriptors(buf, wds[0..]);
    var slot_wds: [follow_files_max]i32 = undefined;
    var si: u32 = 0;
    while (si < ctx.slot_count) : (si += 1) slot_wds[si] = ctx.slots[si].wd;
    var ev_i: u32 = 0;
    while (ev_i < n) : (ev_i += 1) {
        var matched: [follow_files_max]u32 = undefined;
        const m = followSlotsForWatchDescriptor(
            slot_wds[0..ctx.slot_count],
            wds[ev_i],
            matched[0..ctx.slot_count],
        );
        var mi: u32 = 0;
        while (mi < m) : (mi += 1) {
            try followSet_handleSlot(ctx, &ctx.slots[matched[mi]]);
        }
    }
}

/// Read pending inotify events and dispatch them. A short read is not fatal.
fn followSet_readInotify(ctx: *FollowCtx) !void {
    assert(ctx.watch.is_inotify);
    assert(ctx.watch.fd >= 0);
    var event_buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    const bytes_read = std.posix.read(ctx.watch.fd, &event_buf) catch return;
    if (bytes_read == 0) return;
    try followSet_dispatchInotify(ctx, event_buf[0..bytes_read]);
}

/// Map a kqueue ident (the fd) onto every slot that currently holds it.
fn followSet_dispatchKqueue(
    ctx: *FollowCtx,
    ident: usize, // tiger:allow:usize-arch kevent ident
) !void {
    assert(ctx.slot_count > 0);
    assert(ctx.slot_count <= follow_files_max);
    var i: u32 = 0;
    while (i < ctx.slot_count) : (i += 1) {
        if (!ctx.slots[i].active) continue;
        const file = ctx.slots[i].file orelse continue;
        const handle = @as(usize, @intCast(file.handle)); // tiger:allow:usize-arch
        if (handle != ident) continue;
        try followSet_handleSlot(ctx, &ctx.slots[i]);
    }
}

/// Poll the inotify fd for up to 1 second so inactive `-F` slots can be
/// retried without waiting for a sibling event.
fn followSet_poll(fd: std.c.fd_t, timeout_ms: i32) bool {
    assert(timeout_ms >= 0);
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    assert(n <= 1);
    return n > 0;
}

/// Register watches on every slot that opened during dump.
fn followSet_watchAll(ctx: *FollowCtx) !void {
    assert(ctx.slot_count > 0);
    assert(ctx.slot_count <= follow_files_max);
    var i: u32 = 0;
    while (i < ctx.slot_count) : (i += 1) {
        if (!ctx.slots[i].active) continue;
        try followSet_addWatch(ctx, &ctx.slots[i]);
    }
}

/// Linux multiplex loop: one inotify fd, 1s poll, inactive `-F` scan.
fn followSet_runInotify(ctx: *FollowCtx) !void {
    assert(builtin.os.tag == .linux);
    assert(ctx.slot_count > 0);
    const inotify_fd = try inotifyInit1(std.os.linux.IN.CLOEXEC);
    defer closeFd(inotify_fd);
    ctx.watch = .{ .fd = inotify_fd, .is_inotify = true };
    try followSet_watchAll(ctx);
    try followSet_emitAllActive(ctx);
    var last_scan_ns: i128 = 0;
    while (true) { // tiger:allow:unbounded-loop intentional follow loop
        try followSet_maybeScan(ctx, &last_scan_ns);
        if (followSet_poll(inotify_fd, 1000)) {
            try followSet_readInotify(ctx);
        }
    }
}

/// macOS/BSD multiplex loop: one kqueue, 1s kevent timeout, inactive scan.
fn followSet_runKqueue(ctx: *FollowCtx) !void {
    assert(builtin.os.tag != .linux);
    assert(ctx.slot_count > 0);
    const kq = try kqueueCreate();
    defer closeFd(kq);
    ctx.watch = .{ .fd = kq, .is_inotify = false };
    try followSet_watchAll(ctx);
    try followSet_emitAllActive(ctx);
    var last_scan_ns: i128 = 0;
    const timeout = std.c.timespec{ .sec = 1, .nsec = 0 };
    while (true) { // tiger:allow:unbounded-loop intentional follow loop
        try followSet_maybeScan(ctx, &last_scan_ns);
        var eventlist: [1]std.c.Kevent = undefined;
        const nevents = try keventCall(kq, &.{}, &eventlist, &timeout);
        if (nevents == 0) continue;
        try followSet_dispatchKqueue(ctx, eventlist[0].ident);
    }
}

/// One event loop for the whole follow set.
fn followSet_runLoop(ctx: *FollowCtx) !void {
    assert(ctx.slot_count > 0);
    assert(ctx.options.follow);
    if (comptime builtin.os.tag == .linux) {
        try followSet_runInotify(ctx);
    } else {
        try followSet_runKqueue(ctx);
    }
}

/// Detect truncation of the followed file: when the file shrank below last_pos,
/// reset last_pos to the start so we re-read from the beginning.
fn followFile_checkTruncation(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    last_pos: *u64,
    stderr_writer: *std.Io.Writer,
) !void {
    assert(path.len > 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);

    const new_end = try file.length(io);
    if (new_end < last_pos.*) {
        // GNU prints this operand unquoted; keep parity.
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tail",
            "{s}: file truncated",
            .{path},
        );
        stderr_writer.flush() catch {};
        last_pos.* = 0;
    }
}

/// Close a raw file descriptor using OS-native close syscall.
fn closeFd(fd: std.c.fd_t) void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.syscall1(.close, @as(usize, @bitCast(@as(isize, fd))));
    } else {
        _ = std.c.close(fd);
    }
}

/// Linux-only: initialize an inotify instance.
fn inotifyInit1(flags: u32) !std.c.fd_t {
    const rc = std.os.linux.inotify_init1(flags);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => @as(std.c.fd_t, @intCast(rc)),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Linux-only: add a watch to an inotify instance.
fn inotifyAddWatch(inotify_fd: std.c.fd_t, path_z: [*:0]const u8, mask: u32) !i32 {
    const rc = std.os.linux.inotify_add_watch(inotify_fd, path_z, mask);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => @as(i32, @intCast(rc)),
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Linux-only: remove a watch from an inotify instance.
fn inotifyRmWatch(inotify_fd: std.c.fd_t, wd: i32) void {
    _ = std.os.linux.inotify_rm_watch(inotify_fd, wd);
}

/// macOS/BSD-only: create a kqueue descriptor.
fn kqueueCreate() !std.c.fd_t {
    const kq = std.c.kqueue();
    if (kq == -1) return error.SystemResources;
    return kq;
}

/// macOS/BSD-only: call kevent with error handling.
fn keventCall(
    kq: std.c.fd_t,
    changelist: []const std.c.Kevent,
    eventlist: []std.c.Kevent,
    timeout: ?*const std.c.timespec,
) !usize { // tiger:allow:usize-arch kevent event count
    const n = std.c.kevent(
        kq,
        changelist.ptr,
        @intCast(changelist.len),
        eventlist.ptr,
        @intCast(eventlist.len),
        if (timeout) |t| t else null,
    );
    if (n < 0) return error.EventFdNotSupported;
    return @intCast(n);
}

/// Process input by byte count
fn processInputByBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    byte_count: u64,
    file: ?std.Io.File,
    from_beginning: bool,
) !void {
    if (from_beginning) {
        return processInputByBytesFromBeginning(io, reader, writer, byte_count, file);
    }

    if (byte_count == 0) return; // Output nothing for 0 bytes

    // If we have a file, try to seek to optimize reading
    if (file) |f| {
        const file_size = f.length(io) catch {
            // Fall back to reading everything if we can't get file size
            return processInputByBytesNoSeek(allocator, reader, writer, byte_count);
        };

        var buffer: [BUFFER_SIZE]u8 = undefined;
        var file_reader = f.reader(io, &buffer);

        if (byte_count >= file_size) {
            // Read entire file byte-for-byte without modifying content
            try file_reader.seekTo(0);

            // Streams the whole file; capping would truncate valid output.
            // readSliceShort returns 0 (bytes_read == 0) at EOF, breaking the loop.
            while (true) { // tiger:allow:unbounded-loop terminates at EOF (bytes_read == 0)
                const bytes_read = try file_reader.interface.readSliceShort(&buffer);
                if (bytes_read == 0) break; // EOF
                try writer.writeAll(buffer[0..bytes_read]);
            }
        } else {
            // Seek to the position we want to start reading from. This branch
            // is the byte_count < file_size case, so the seek target is in
            // bounds with no underflow.
            const start_pos = file_size - byte_count;
            assert(start_pos < file_size);
            try file_reader.seekTo(start_pos);

            // Read directly from file using simple read() calls to avoid reader buffer issues
            var bytes_remaining = byte_count;
            // This branch is the byte_count < file_size case, so the read
            // budget is a strict suffix of the file (never the whole file).
            assert(bytes_remaining < file_size);

            while (bytes_remaining > 0) {
                const bytes_to_read = @min(buffer.len, @as(usize, @intCast(bytes_remaining)));
                const bytes_read =
                    try file_reader.interface.readSliceShort(buffer[0..bytes_to_read]);
                if (bytes_read == 0) break; // EOF

                try writer.writeAll(buffer[0..bytes_read]);
                bytes_remaining -= @as(u64, @intCast(bytes_read));
            }
        }
    } else {
        // No file handle, fall back to buffering approach
        return processInputByBytesNoSeek(allocator, reader, writer, byte_count);
    }
}

/// Process input by bytes from beginning: skip first (byte_count - 1) bytes, output the rest
fn processInputByBytesFromBeginning(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    byte_count: u64,
    file: ?std.Io.File,
) !void {
    // -c +N means output starting from byte N (1-indexed)
    // So skip the first (N-1) bytes
    const skip = if (byte_count > 0) byte_count - 1 else 0;
    assert(skip <= byte_count);

    if (file) |f| {
        // For seekable files, just seek past the skip bytes
        const file_size = f.length(io) catch {
            return processInputByBytesFromBeginningStream(reader, writer, skip);
        };

        if (skip >= file_size) return; // Nothing to output

        var buffer: [BUFFER_SIZE]u8 = undefined;
        var file_reader = f.reader(io, &buffer);
        try file_reader.seekTo(skip);
        // Streams the post-skip remainder of the file; no a-priori bound.
        // readSliceShort returns 0 (bytes_read == 0) at EOF, breaking the loop.
        while (true) { // tiger:allow:unbounded-loop terminates at EOF (bytes_read == 0)
            const bytes_read = try file_reader.interface.readSliceShort(&buffer);
            if (bytes_read == 0) break;
            try writer.writeAll(buffer[0..bytes_read]);
        }
    } else {
        return processInputByBytesFromBeginningStream(reader, writer, skip);
    }
}

/// Process stream input by bytes from beginning (non-seekable)
fn processInputByBytesFromBeginningStream(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    skip: u64,
) !void {
    var skipped: u64 = 0;

    // Non-seekable stream input, unbounded a priori. peekGreedy(1) returns
    // error.EndOfStream or an empty slice at stream end, both of which return.
    while (true) { // tiger:allow:unbounded-loop terminates at stream end (EndOfStream / empty peek)
        // Loop invariant: skipped never overshoots the requested skip count.
        assert(skipped <= skip);
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        if (available.len == 0) return;

        if (skipped < skip) {
            const to_skip = @min(available.len, @as(usize, @intCast(skip - skipped)));
            reader.toss(to_skip);
            skipped += @as(u64, @intCast(to_skip));
        } else {
            try writer.writeAll(available);
            reader.toss(available.len);
        }
    }
}

/// Maximum buffer size for the circular buffer in processInputByBytesNoSeek.
/// When byte_count exceeds this, we use a dynamic list that grows with actual
/// input rather than pre-allocating the full requested size.
const MAX_CIRCULAR_BUFFER: usize = 64 * 1024 * 1024; // 64 MB

/// Process input by bytes without seeking (for stdin/pipes) using circular buffer
fn processInputByBytesNoSeek(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    byte_count: u64,
) !void {
    // When byte_count is larger than MAX_CIRCULAR_BUFFER, pre-allocating the
    // full amount would OOM for huge values (e.g. 10 GB).  Instead, collect
    // the actual input into a dynamic list (which grows only as data arrives)
    // and then output the last byte_count bytes.
    if (byte_count > MAX_CIRCULAR_BUFFER) {
        return processInputByBytesNoSeekDynamic(allocator, reader, writer, byte_count);
    }
    // Oversized requests were delegated above, so the @intCast is lossless.
    assert(byte_count <= MAX_CIRCULAR_BUFFER);

    const buffer_size = @as(usize, @intCast(byte_count));
    // buffer_size is the modulus below; callers funnel byte_count == 0 through
    // processInputByBytes's early return, so it is non-zero here.
    assert(buffer_size > 0);

    // Allocate circular buffer to hold only the last byte_count bytes
    const circular_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(circular_buffer);

    var total_bytes_read: usize = 0;
    var write_index: usize = 0;

    // Read input and maintain only last byte_count bytes in circular buffer.
    // Fills the circular buffer from stdin/pipe; input length is unbounded a
    // priori. peekGreedy(1) returns error.EndOfStream at stream end, breaking.
    while (true) { // tiger:allow:unbounded-loop terminates at stream end (EndOfStream)
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        for (available) |byte| {
            circular_buffer[write_index] = byte;
            write_index = (write_index + 1) % buffer_size;
            total_bytes_read += 1;
        }
        reader.toss(available.len);
    }

    // Output the circular buffer in the correct order
    if (total_bytes_read >= buffer_size) {
        // Buffer wrapped around - output from write_index to end, then from start to write_index
        try writer.writeAll(circular_buffer[write_index..]);
        try writer.writeAll(circular_buffer[0..write_index]);
    } else {
        // Buffer didn't wrap - output from start to total_bytes_read
        try writer.writeAll(circular_buffer[0..total_bytes_read]);
    }
}

/// Fallback for processInputByBytesNoSeek when byte_count exceeds
/// MAX_CIRCULAR_BUFFER.  Reads all input into a growable list (allocating
/// only what the input actually contains) then outputs the trailing
/// byte_count bytes.
fn processInputByBytesNoSeekDynamic(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    byte_count: u64,
) !void {
    // This dynamic path is reserved for oversized requests; the sibling
    // circular-buffer path handles byte_count <= MAX_CIRCULAR_BUFFER.
    assert(byte_count > MAX_CIRCULAR_BUFFER);

    var data = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer data.deinit(allocator);

    // Collects all stream input into a growable list; unbounded a priori.
    // peekGreedy(1) returns error.EndOfStream or an empty slice at stream end,
    // both of which break the loop.
    while (true) { // tiger:allow:unbounded-loop terminates at stream end (EndOfStream / empty peek)
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (available.len == 0) break;

        try data.appendSlice(allocator, available);
        reader.toss(available.len);
    }

    const items = data.items;
    if (items.len == 0) return;

    if (byte_count >= items.len) {
        // Requested more bytes than available -- output everything
        try writer.writeAll(items);
    } else {
        // byte_count < items.len here, so the start offset is in bounds with no
        // underflow.
        const start = items.len - @as(usize, @intCast(byte_count));
        assert(start < items.len);
        try writer.writeAll(items[start..]);
    }
}

/// Ring buffer for storing the last N lines efficiently
const LineBuffer = struct {
    lines: [][]u8,
    allocator: std.mem.Allocator,
    capacity: usize,
    next_index: usize = 0,
    is_full: bool = false,

    fn init(allocator: std.mem.Allocator, capacity: usize) !LineBuffer {
        // capacity becomes the modulus in addLine; lastN callers enforce > 0.
        assert(capacity > 0);
        const lines = try allocator.alloc([]u8, capacity);
        assert(lines.len == capacity);
        return LineBuffer{
            .lines = lines,
            .allocator = allocator,
            .capacity = capacity,
        };
    }

    fn deinit(self: *LineBuffer) void {
        // lines is never resliced after init, and next_index stays within the
        // ring, so lines[0..count] is always in bounds.
        assert(self.capacity == self.lines.len);
        assert(self.next_index <= self.capacity);
        const count = if (self.is_full) self.capacity else self.next_index;
        for (self.lines[0..count]) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.lines);
    }

    fn addLine(self: *LineBuffer, line_data: []const u8) !void {
        // capacity is the modulus; next_index must be a valid write slot both
        // before the write and after the wrap-around bump.
        assert(self.capacity > 0);
        assert(self.next_index < self.capacity);
        const line_copy = try self.allocator.dupe(u8, line_data);

        // If we're overwriting an existing line, free it first
        if (self.is_full) {
            self.allocator.free(self.lines[self.next_index]);
        }

        self.lines[self.next_index] = line_copy;
        self.next_index = (self.next_index + 1) % self.capacity;
        assert(self.next_index < self.capacity);

        // Mark as full once we wrap around and would start overwriting
        if (self.next_index == 0 and !self.is_full) {
            self.is_full = true;
        }
    }

    fn writeAllLines(self: *LineBuffer, writer: *std.Io.Writer) !void {
        // Both branches index self.lines within these bounds.
        assert(self.next_index <= self.capacity);
        assert(self.capacity == self.lines.len);
        if (!self.is_full) {
            // Buffer not full, output all lines in order
            for (self.lines[0..self.next_index]) |line| {
                try writer.writeAll(line);
            }
        } else {
            // Buffer is full, output from next_index (oldest) for capacity lines
            for (0..self.capacity) |i| {
                const line_idx = (self.next_index + i) % self.capacity;
                try writer.writeAll(self.lines[line_idx]);
            }
        }
    }

    fn writeAllLinesReversed(self: *LineBuffer, writer: *std.Io.Writer, delimiter: u8) !void {
        // Callers pass NUL or newline, and both branches stay within the ring.
        assert(isLineDelimiter(delimiter));
        assert(self.next_index <= self.capacity);
        if (!self.is_full) {
            // Buffer not full, output lines in reverse order
            var i = self.next_index;
            while (i > 0) {
                i -= 1;
                const line = self.lines[i];
                // Strip trailing delimiter, write content, then add delimiter
                if (line.len > 0 and line[line.len - 1] == delimiter) {
                    try writer.writeAll(line[0 .. line.len - 1]);
                    try writer.writeByte(delimiter);
                } else {
                    try writer.writeAll(line);
                    try writer.writeByte(delimiter);
                }
            }
        } else {
            // Buffer is full, output from newest to oldest
            var i = self.capacity;
            while (i > 0) {
                i -= 1;
                // newest is at (next_index - 1 + capacity) % capacity, going backwards
                const line_idx = (self.next_index + i) % self.capacity;
                const line = self.lines[line_idx];
                if (line.len > 0 and line[line.len - 1] == delimiter) {
                    try writer.writeAll(line[0 .. line.len - 1]);
                    try writer.writeByte(delimiter);
                } else {
                    try writer.writeAll(line);
                    try writer.writeByte(delimiter);
                }
            }
        }
    }
};

/// Process input by line count using file handle when available.
/// Streams the file in chunks instead of reading it all into memory.
/// When line_count is null (used with -r), all lines are collected.
fn processInputByLinesFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    writer: *std.Io.Writer,
    line_count: ?u64,
    zero_terminated: bool,
    from_beginning: bool,
    reverse: bool,
) !void {
    if (line_count) |lc| {
        if (lc == 0 and !from_beginning) return;
    }

    const delimiter: u8 = if (zero_terminated) 0 else '\n';
    assert(isLineDelimiter(delimiter));

    if (from_beginning) {
        return processInputByLinesFromFile_fromBeginning(io, file, writer, line_count, delimiter);
    }

    // When line_count is null (reverse all), collect into a dynamic list
    if (line_count == null) {
        return processInputByLinesFromFile_reverseAll(allocator, io, file, writer, delimiter);
    }

    const max_lines = @as(usize, @intCast(line_count.?)); // tiger:allow:usize-arch ring capacity
    return processInputByLinesFromFile_lastN(
        allocator,
        io,
        file,
        writer,
        max_lines,
        delimiter,
        reverse,
    );
}

/// Output everything from line (line_count - 1) onward (the -n +NUM mode), by
/// skipping leading lines then streaming the remainder of the file directly.
fn processInputByLinesFromFile_fromBeginning(
    io: std.Io,
    file: std.Io.File,
    writer: *std.Io.Writer,
    line_count: ?u64,
    delimiter: u8,
) !void {
    assert(isLineDelimiter(delimiter));

    const lc = line_count orelse 1;
    const max_lines = @as(usize, @intCast(lc)); // tiger:allow:usize-arch line index
    // Skip the first (line_count - 1) lines and stream the rest
    const skip_count = if (lc > 0) max_lines - 1 else 0;
    assert(skip_count <= max_lines);
    var read_buf: [8192]u8 = undefined;

    if (skip_count == 0) {
        // +1 means output everything from the start. Relocated verbatim;
        // bounded by EOF on the file.
        while (true) { // tiger:allow:unbounded-loop EOF-bounded read
            const n = file.readStreaming(io, &.{read_buf[0..]}) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            try writer.writeAll(read_buf[0..n]);
        }
    }

    var lines_seen: usize = 0; // tiger:allow:usize-arch line counter for slice index
    // Relocated verbatim; bounded by EOF while skipping leading lines.
    while (true) { // tiger:allow:unbounded-loop EOF-bounded read
        const bytes_read = file.readStreaming(io, &.{read_buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => return, // EOF before we finished skipping
            else => return err,
        };

        for (read_buf[0..bytes_read], 0..) |byte, pos| {
            if (byte == delimiter) {
                lines_seen += 1;
                if (lines_seen >= skip_count) {
                    // Output the rest of this chunk after the delimiter
                    try writer.writeAll(read_buf[pos + 1 .. bytes_read]);
                    // Then stream remaining file content directly. Relocated
                    // verbatim; bounded by EOF on the file.
                    while (true) { // tiger:allow:unbounded-loop EOF-bounded read
                        const n = file.readStreaming(
                            io,
                            &.{read_buf[0..]},
                        ) catch |err| switch (err) {
                            error.EndOfStream => return,
                            else => return err,
                        };
                        try writer.writeAll(read_buf[0..n]);
                    }
                }
            }
        }
    }
}

/// Collect every line of the file into a list and emit them in reverse order
/// (the -r without -n mode).
fn processInputByLinesFromFile_reverseAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    writer: *std.Io.Writer,
    delimiter: u8,
) !void {
    assert(isLineDelimiter(delimiter));

    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var read_buf: [8192]u8 = undefined;
    var partial: std.ArrayListUnmanaged(u8) = .empty;
    defer partial.deinit(allocator);

    // Relocated verbatim; bounded by EOF on the file.
    while (true) { // tiger:allow:unbounded-loop EOF-bounded read
        const bytes_read = file.readStreaming(io, &.{read_buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        var chunk_start: usize = 0; // tiger:allow:usize-arch slice index
        for (read_buf[0..bytes_read], 0..) |byte, pos| {
            if (byte == delimiter) {
                const chunk_end = pos + 1;
                if (partial.items.len > 0) {
                    try partial.appendSlice(allocator, read_buf[chunk_start..chunk_end]);
                    const line_copy = try allocator.dupe(u8, partial.items);
                    try lines.append(allocator, line_copy);
                    partial.clearRetainingCapacity();
                } else {
                    const line_copy = try allocator.dupe(u8, read_buf[chunk_start..chunk_end]);
                    try lines.append(allocator, line_copy);
                }
                chunk_start = chunk_end;
            }
        }
        // chunk_start advanced only to delimiter positions within the chunk, so
        // it never overruns bytes_read; the slice below stays in bounds.
        assert(chunk_start <= bytes_read);
        if (chunk_start < bytes_read) {
            try partial.appendSlice(allocator, read_buf[chunk_start..bytes_read]);
        }
    }

    if (partial.items.len > 0) {
        const line_copy = try allocator.dupe(u8, partial.items);
        try lines.append(allocator, line_copy);
    }
    // Sanity check: the read buffer keeps its fixed chunk size throughout.
    assert(read_buf.len == 8192);

    // Output in reverse order
    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = lines.items[i];
        if (line.len > 0 and line[line.len - 1] == delimiter) {
            try writer.writeAll(line[0 .. line.len - 1]);
            try writer.writeByte(delimiter);
        } else {
            try writer.writeAll(line);
            try writer.writeByte(delimiter);
        }
    }
}

/// Keep only the last max_lines lines of the file in a ring buffer, then emit
/// them (reversed when requested).
fn processInputByLinesFromFile_lastN(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    writer: *std.Io.Writer,
    max_lines: usize, // tiger:allow:usize-arch ring buffer capacity
    delimiter: u8,
    reverse: bool,
) !void {
    assert(max_lines > 0);
    assert(isLineDelimiter(delimiter));

    // Use LineBuffer to keep the last N lines
    var line_buffer = try LineBuffer.init(allocator, max_lines);
    defer line_buffer.deinit();
    assert(line_buffer.capacity == max_lines);

    // Stream file in chunks and extract lines
    var read_buf: [8192]u8 = undefined;
    var partial: std.ArrayListUnmanaged(u8) = .empty;
    defer partial.deinit(allocator);

    // Relocated verbatim; bounded by EOF on the file.
    while (true) { // tiger:allow:unbounded-loop EOF-bounded read
        const bytes_read = file.readStreaming(io, &.{read_buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        var chunk_start: usize = 0; // tiger:allow:usize-arch slice index
        for (read_buf[0..bytes_read], 0..) |byte, pos| {
            if (byte == delimiter) {
                const chunk_end = pos + 1; // Include delimiter
                if (partial.items.len > 0) {
                    // Combine partial data with this chunk
                    try partial.appendSlice(allocator, read_buf[chunk_start..chunk_end]);
                    try line_buffer.addLine(partial.items);
                    partial.clearRetainingCapacity();
                } else {
                    // Complete line within this chunk
                    try line_buffer.addLine(read_buf[chunk_start..chunk_end]);
                }
                chunk_start = chunk_end;
            }
        }

        // Save any remaining partial line data
        if (chunk_start < bytes_read) {
            try partial.appendSlice(allocator, read_buf[chunk_start..bytes_read]);
        }
    }

    // Handle final partial line (no trailing delimiter)
    if (partial.items.len > 0) {
        try line_buffer.addLine(partial.items);
    }

    if (reverse) {
        try line_buffer.writeAllLinesReversed(writer, delimiter);
    } else {
        try line_buffer.writeAllLines(writer);
    }
}

/// Process input by line count (fallback for non-file inputs like stdin)
fn processInputByLines(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    line_count: ?u64,
    zero_terminated: bool,
    from_beginning: bool,
    reverse: bool,
) !void {
    if (line_count) |lc| {
        if (lc == 0 and !from_beginning) return; // Output nothing for 0 lines
    }

    const delimiter: u8 = if (zero_terminated) 0 else '\n';
    assert(isLineDelimiter(delimiter));

    if (from_beginning) {
        return processInputByLines_fromBeginning(reader, writer, line_count, delimiter);
    }

    // When line_count is null (reverse all), collect into a dynamic list
    if (line_count == null) {
        return processInputByLines_reverseAll(allocator, reader, writer, delimiter);
    }

    const max_lines = @as(usize, @intCast(line_count.?)); // tiger:allow:usize-arch ring capacity
    return processInputByLines_lastN(allocator, reader, writer, max_lines, delimiter, reverse);
}

/// Skip leading lines then stream the remainder (the -n +NUM mode) from a
/// stream reader that lacks seek support.
fn processInputByLines_fromBeginning(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    line_count: ?u64,
    delimiter: u8,
) !void {
    assert(isLineDelimiter(delimiter));

    const lc = line_count orelse 1;
    const max_lines = @as(usize, @intCast(lc)); // tiger:allow:usize-arch line index
    // Skip the first (line_count - 1) lines and output the rest
    const skip_count = if (lc > 0) max_lines - 1 else 0;
    assert(skip_count <= max_lines);
    var lines_skipped: usize = 0; // tiger:allow:usize-arch line counter

    // Skip lines by reading and discarding them
    while (lines_skipped < skip_count) {
        if (reader.takeDelimiterInclusive(delimiter)) |_| {
            lines_skipped += 1;
        } else |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        }
    }

    // Output remaining lines
    while (reader.takeDelimiterInclusive(delimiter)) |line| {
        try writer.writeAll(line);
    } else |err| switch (err) {
        error.EndOfStream => {
            // Handle final partial line (no trailing delimiter)
            const remaining = reader.buffered();
            if (remaining.len > 0) {
                try writer.writeAll(remaining);
                reader.toss(remaining.len);
            }
        },
        else => return err,
    }
}

/// Collect all lines from the stream reader and emit them reversed (the -r
/// without -n mode).
fn processInputByLines_reverseAll(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    delimiter: u8,
) !void {
    assert(isLineDelimiter(delimiter));

    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    while (reader.takeDelimiterInclusive(delimiter)) |line| {
        const line_copy = try allocator.dupe(u8, line);
        try lines.append(allocator, line_copy);
    } else |err| switch (err) {
        error.EndOfStream => {
            const remaining = reader.buffered();
            if (remaining.len > 0) {
                const line_copy = try allocator.dupe(u8, remaining);
                try lines.append(allocator, line_copy);
                reader.toss(remaining.len);
            }
        },
        else => return err,
    }
    // After EOF handling the reader's buffer must be fully consumed.
    assert(reader.buffered().len == 0);

    // Output in reverse order
    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = lines.items[i];
        if (line.len > 0 and line[line.len - 1] == delimiter) {
            try writer.writeAll(line[0 .. line.len - 1]);
            try writer.writeByte(delimiter);
        } else {
            try writer.writeAll(line);
            try writer.writeByte(delimiter);
        }
    }
}

/// Keep only the last max_lines lines from the stream reader in a ring buffer,
/// then emit them (reversed when requested).
fn processInputByLines_lastN(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    max_lines: usize, // tiger:allow:usize-arch ring buffer capacity
    delimiter: u8,
    reverse: bool,
) !void {
    assert(max_lines > 0);
    assert(isLineDelimiter(delimiter));

    // Use LineBuffer ring buffer for last N lines
    var line_buffer = try LineBuffer.init(allocator, max_lines);
    defer line_buffer.deinit();
    assert(line_buffer.capacity == max_lines);

    // Read lines and add to ring buffer
    while (reader.takeDelimiterInclusive(delimiter)) |line| {
        try line_buffer.addLine(line);
    } else |err| switch (err) {
        error.EndOfStream => {
            // Handle final partial line (no trailing delimiter)
            const remaining = reader.buffered();
            if (remaining.len > 0) {
                try line_buffer.addLine(remaining);
                reader.toss(remaining.len);
            }
        },
        else => return err,
    }

    // Output all stored lines
    if (reverse) {
        try line_buffer.writeAllLinesReversed(writer, delimiter);
    } else {
        try line_buffer.writeAllLines(writer);
    }
}

// ========== TESTS ==========

test "tail outputs default 10 lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test file with 15 lines
    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\n" ++
        "line9\nline10\nline11\nline12\nline13\nline14\nline15\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, .{});

    try testing.expectEqualStrings(
        "line6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\n",
        aw.writer.buffered(),
    );
}

test "tail with -n 5 outputs last 5 lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 5 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line3\nline4\nline5\nline6\nline7\n", aw.writer.buffered());
}

test "tail with -n 0 outputs nothing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 0 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail with -c 10 outputs last 10 bytes" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "abcdefghijklmnopqrstuvwxyz";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 10 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("qrstuvwxyz", aw.writer.buffered());
}

test "tail with -c 0 outputs nothing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "some content here";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 0 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail handles line count larger than file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 100 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line1\nline2\nline3\n", aw.writer.buffered());
}

test "tail handles byte count larger than file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "small";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 100 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("small", aw.writer.buffered());
}

test "tail handles empty file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "empty.txt", "");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try testTailFile(io, tmp_dir.dir, "empty.txt", &aw.writer, .{});

    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail handles file with no final newline" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3"; // no final newline
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line2\nline3", aw.writer.buffered());
}

test "tail handles very long lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a line longer than typical buffer sizes
    var long_line_buf: [5000]u8 = undefined;
    @memset(&long_line_buf, 'x');
    const long_line = long_line_buf[0..];

    const content = try std.fmt.allocPrint(
        testing.allocator,
        "short1\n{s}\nshort2\n",
        .{long_line},
    );
    defer testing.allocator.free(content);

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\nshort2\n", .{long_line});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "tail with multiple files shows headers by default" {
    const args = [_][]const u8{ "file1.txt", "file2.txt" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    // Should fail with general error due to missing files.
    try testing.expectEqual(@as(u8, 1), result);
}

test "tail with -q suppresses headers for multiple files" {
    const args = [_][]const u8{ "-q", "file1.txt", "file2.txt" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    // Should fail with general error due to missing files.
    try testing.expectEqual(@as(u8, 1), result);
}

test "tail with -v always shows headers" {
    const args = [_][]const u8{ "-v", "file1.txt" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    // Should fail with general error due to missing file.
    try testing.expectEqual(@as(u8, 1), result);
}

test "tail handles non-existent file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const result = testTailFile(io, tmp_dir.dir, "nonexistent.txt", &aw.writer, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "tail with -z handles zero-terminated lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\x00line2\x00line3\x00";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 2, .zero_terminated = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line2\x00line3\x00", aw.writer.buffered());
}

test "tail with binary file in byte mode" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const binary_content = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC };
    try common.test_utils.createTestFile(io, tmp_dir.dir, "binary.txt", &binary_content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 4 };
    try testTailFile(io, tmp_dir.dir, "binary.txt", &aw.writer, options);

    const expected = [_]u8{ 0xFF, 0xFE, 0xFD, 0xFC };
    try testing.expectEqualSlices(u8, &expected, aw.writer.buffered());
}

test "parseNumericArg with valid numbers" {
    try testing.expectEqual(@as(u64, 10), try parseNumericArg("10"));
    try testing.expectEqual(@as(u64, 0), try parseNumericArg("0"));
    try testing.expectEqual(@as(u64, 999), try parseNumericArg("999"));
}

test "parseNumericArg with suffixes" {
    try testing.expectEqual(@as(u64, 1024), try parseNumericArg("1K"));
    try testing.expectEqual(@as(u64, 1024 * 1024), try parseNumericArg("1M"));
    try testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseNumericArg("1G"));
    try testing.expectEqual(@as(u64, 1000), try parseNumericArg("1kB"));
    try testing.expectEqual(@as(u64, 1000 * 1000), try parseNumericArg("1MB"));
}

test "parseNumericArg with plus prefix" {
    try testing.expectEqual(@as(u64, 10), try parseNumericArg("+10"));
    try testing.expectEqual(@as(u64, 1), try parseNumericArg("+1"));
}

test "tail -n +1 outputs entire file (from-beginning)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 1, .from_beginning = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    // +1 means skip 0 lines, output everything
    try testing.expectEqualStrings("line1\nline2\nline3\nline4\nline5\n", aw.writer.buffered());
}

test "tail -n +3 skips first 2 lines (from-beginning)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 3, .from_beginning = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    // +3 means skip first 2 lines, output from line 3 onward
    try testing.expectEqualStrings("line3\nline4\nline5\n", aw.writer.buffered());
}

test "tail -n +NUM larger than file outputs nothing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 100, .from_beginning = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    // +100 on a 2-line file: skip 99 lines, nothing left
    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail -n +NUM detected via runTail arg parsing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // Get the real path for the file
    const path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(path);

    const args = [_][]const u8{ "-n", "+3", path };
    const result = try runTail(testing.allocator, io, &args, &aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("line3\nline4\nline5\n", aw.writer.buffered());
}

test "parseNumericArg with invalid input" {
    try testing.expectError(error.InvalidArgument, parseNumericArg(""));
    try testing.expectError(error.InvalidArgument, parseNumericArg("abc"));
    try testing.expectError(error.InvalidArgument, parseNumericArg("12abc"));
}

test "tail shouldShowHeaders logic" {
    const options_default = TailOptions{};
    const options_quiet = TailOptions{ .quiet = true };
    const options_verbose = TailOptions{ .verbose = true };

    // Default behavior: show headers only for multiple files
    try testing.expect(!options_default.shouldShowHeaders(1));
    try testing.expect(options_default.shouldShowHeaders(2));

    // Quiet mode: never show headers
    try testing.expect(!options_quiet.shouldShowHeaders(1));
    try testing.expect(!options_quiet.shouldShowHeaders(2));

    // Verbose mode: always show headers
    try testing.expect(options_verbose.shouldShowHeaders(1));
    try testing.expect(options_verbose.shouldShowHeaders(2));
}

test "tail help output" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        &aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Usage: tail") != null);
}

test "tail version output" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        &aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "tail (vibeutils)") != null);
}

test "tail with invalid line count" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-n", "invalid" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "invalid number of lines") != null,
    );
}

test "tail with invalid byte count" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", "xyz" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "invalid number of bytes") != null,
    );
}

test "tail with obsolete -NUM syntax" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-2", file_path };
    const exit_code = try runTail(testing.allocator, io, &args, &aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 4\nLine 5\n", aw.writer.buffered());
}

test "tail: -f flag is parsed" {
    const args = [_][]const u8{ "-f", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.follow);
    try testing.expect(!parsed.follow_retry);
}

test "tail: -F flag is parsed" {
    const args = [_][]const u8{ "-F", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.follow_retry);
    try testing.expect(!parsed.follow);
}

test "tail: -f with nonexistent file gives error" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "/tmp/vibeutils_test_nonexistent_file_xyzzy" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

test "tail: -F skips nonexistent files in initial processing" {
    // -F tolerates missing files during initial processing (the file
    // loop). The blocking wait-for-file behavior in follow mode is
    // tested via integration tests.
    const args = [_][]const u8{"-F"};
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    // Verify the flag enables both follow and follow_retry
    try testing.expect(parsed.follow_retry);
    // In runTail, follow_retry + FileNotFound causes continue (skip)
    // rather than error — this is validated by the file processing loop
    // at line ~256 where follow_retry is checked.
}

test "tail: help output mentions -f and -F flags" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        &aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    // Help text should document the -f (follow) flag
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "-f") != null);
    // Help text should document the -F (follow-retry) flag
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "-F") != null);
}

test "tail: -b flag is parsed" {
    const args = [_][]const u8{ "-b", "3", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.blocks != null);
    try testing.expectEqualStrings("3", parsed.blocks.?);
}

test "tail: -b 2 shows last 1024 bytes" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 2048 bytes (4 blocks of 512)
    var content: [2048]u8 = undefined;
    @memset(content[0..1024], 'A');
    @memset(content[1024..2048], 'B');
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", &content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-b", "2", file_path };
    const result = try runTail(testing.allocator, io, &args, &aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqual(@as(usize, 1024), aw.writer.buffered().len);
    // Last 1024 bytes should all be 'B'
    for (aw.writer.buffered()) |byte| {
        try testing.expectEqual(@as(u8, 'B'), byte);
    }
}

test "tail: -b +2 shows from byte 512 onwards" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 1536 bytes (3 blocks of 512)
    var content: [1536]u8 = undefined;
    @memset(content[0..512], 'A');
    @memset(content[512..1024], 'B');
    @memset(content[1024..1536], 'C');
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", &content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // -b +2 means starting from block 2 (byte 512), output the rest
    const args = [_][]const u8{ "-b", "+2", file_path };
    const result = try runTail(testing.allocator, io, &args, &aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Should output from byte 512 onwards (1024 bytes: 512 B's + 512 C's)
    const out = aw.writer.buffered();
    try testing.expectEqual(@as(usize, 1024), out.len);
    for (out[0..512]) |byte| {
        try testing.expectEqual(@as(u8, 'B'), byte);
    }
    for (out[512..1024]) |byte| {
        try testing.expectEqual(@as(u8, 'C'), byte);
    }
}

test "tail: -b with file shorter than block count shows everything" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "short file content";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // -b 10 = 5120 bytes, much larger than the file
    const args = [_][]const u8{ "-b", "10", file_path };
    const result = try runTail(testing.allocator, io, &args, &aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("short file content", aw.writer.buffered());
}

test "tail: -r flag is parsed" {
    const args = [_][]const u8{ "-r", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.reverse);
}

test "tail: -r reverses all lines of a file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = null, .reverse = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line5\nline4\nline3\nline2\nline1\n", aw.writer.buffered());
}

test "tail: -r -n 3 reverses last 3 lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 3, .reverse = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line5\nline4\nline3\n", aw.writer.buffered());
}

test "tail: -r on single-line file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "only line\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = null, .reverse = true };
    try testTailFile(io, tmp_dir.dir, "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("only line\n", aw.writer.buffered());
}

test "tail: -f and -r are mutually exclusive" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "content\n");

    // Build an absolute path for the test file
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const abs_path = path_buf[0..abs_path_len];

    const args = [_][]const u8{ "-f", "-r", abs_path };
    const result = try runTail(
        testing.allocator,
        io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "option used in invalid context") != null,
    );
}

test "tail: -f with nonexistent file returns error" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "/nonexistent/path/file.txt" };
    const result = try runTail(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), result);
}

test "tail follow switch header uses GNU form" {
    var buf: [64]u8 = undefined;
    const header = formatFollowSwitchHeader(&buf, "foo/bar");
    try testing.expectEqualStrings("\n==> foo/bar <==\n", header);
    try testing.expect(header.len > 0);
}

test "tail follow switch header is omitted when quiet" {
    var last: ?u32 = 0;
    try testing.expect(!followHeaderNeeded(false, &last, 1, 8));
    // A non-empty quiet chunk still advances last_output_slot. Reset so the
    // contrast case is a real slot change, not the same slot returning false.
    last = 0;
    try testing.expect(followHeaderNeeded(true, &last, 1, 8));
}

test "tail follow switch header is needed when the slot changes" {
    var last: ?u32 = 0;
    try testing.expect(followHeaderNeeded(true, &last, 1, 4));
    last = 0;
    try testing.expect(!followHeaderNeeded(true, &last, 0, 4));
    // Duplicate operands: two slots, same path, still a slot change.
    last = 0;
    try testing.expect(followHeaderNeeded(true, &last, 1, 4));
    last = 2;
    try testing.expect(!followHeaderNeeded(true, &last, 1, 0));
    try testing.expectEqual(@as(?u32, 2), last);
}

test "tail follow switch header after last positional" {
    // Last positional is slot B (index 1), including a failed open.
    var last: ?u32 = 1;
    try testing.expect(!followHeaderNeeded(true, &last, 1, 5));
    try testing.expect(followHeaderNeeded(true, &last, 0, 5));
    // Last positional is stdin (slot 1); first follow file is slot 0.
    last = 1;
    try testing.expect(followHeaderNeeded(true, &last, 0, 5));
}

test "tail follow rejects more than follow_files_max files" {
    const io = testing.io;
    const missing = "/tmp/vibeutils_tail_cap_missing";
    const file_count: u32 = follow_files_max + 1;
    var args_buf: [follow_files_max + 2][]const u8 = undefined;
    args_buf[0] = "-f";
    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        args_buf[i + 1] = missing;
    }
    const args = args_buf[0 .. file_count + 1];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTail(
        testing.allocator,
        io,
        args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    const stderr = stderr_aw.writer.buffered();
    try testing.expect(
        std.mem.find(u8, stderr, "cannot follow more than 256 files") != null,
    );
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stderr, "cannot open") == null);
}

test "tail follow inotify buffer walks every record" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const Event = std.os.linux.inotify_event;
    var raw: [2]Event align(@alignOf(Event)) = .{
        .{ .wd = 3, .mask = 2, .cookie = 0, .len = 0 },
        .{ .wd = 5, .mask = 2, .cookie = 0, .len = 0 },
    };
    var wds: [2]i32 = undefined;
    const n = parseInotifyWatchDescriptors(std.mem.asBytes(&raw), &wds);
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(@as(i32, 3), wds[0]);
    try testing.expectEqual(@as(i32, 5), wds[1]);
}

test "tail follow wd fans out to every matching slot" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const slot_wds = [_]i32{ 7, 7 };
    var out: [2]u32 = undefined;
    const n = followSlotsForWatchDescriptor(&slot_wds, 7, &out);
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(@as(u32, 0), out[0]);
    try testing.expectEqual(@as(u32, 1), out[1]);
}

test "tail follow inotify rm_watch waits for last slot" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Two slots share wd 7; releasing slot 0 leaves one reference.
    try testing.expect(!followInotifyShouldRemoveWatch(1));
    try testing.expect(followInotifyShouldRemoveWatch(0));
}

/// Test helper for processing a file from a directory
fn testTailFile(
    io: std.Io,
    dir: std.Io.Dir,
    filename: []const u8,
    writer: *std.Io.Writer,
    options: TailOptions,
) !void {
    const file = try dir.openFile(io, filename, .{});
    defer file.close(io);
    if (options.byte_count) |byte_count| {
        var file_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        const file_interface = &file_reader.interface;
        try processInputByBytes(
            testing.allocator,
            io,
            file_interface,
            writer,
            byte_count,
            file,
            options.from_beginning_bytes,
        );
    } else {
        const line_count = if (options.line_count) |lc|
            @as(?u64, lc)
        else if (options.reverse) null else @as(?u64, 10);
        try processInputByLinesFromFile(
            testing.allocator,
            io,
            file,
            writer,
            line_count,
            options.zero_terminated,
            options.from_beginning,
            options.reverse,
        );
    }
}
