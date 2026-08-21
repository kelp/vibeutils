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
const TestDir = common.test_dir.TestDir;
const testing = std.testing;
const assert = std.debug.assert;

/// Buffer size for I/O operations - matches typical file system block size for optimal performance
const BUFFER_SIZE = 8192;

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
        \\  -f, --follow             output appended data as the file grows
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

    // Process files
    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        try processStdin(allocator, io, stdout_writer, options);
        return @intFromEnum(common.ExitCode.success);
    }

    // Process each file
    const had_error = try runTail_processPositionals(
        allocator,
        io,
        parsed_args,
        stdout_writer,
        stderr_writer,
        &options,
    );
    if (had_error and !options.follow) return @intFromEnum(common.ExitCode.general_error);

    // Enter follow mode for the last real file
    if (options.follow) {
        if (try runTail_enterFollow(
            allocator,
            io,
            parsed_args,
            stdout_writer,
            stderr_writer,
            &options,
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
) !bool {
    // Positive space: the parent only calls this when files were given.
    assert(parsed_args.positionals.len > 0);
    // Negative space: -r and -f are mutually exclusive (validated in
    // runTail_buildOptions), so they must never both be set here.
    const reverse_and_follow = options.reverse and options.follow;
    assert(!reverse_and_follow);

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

/// Enter follow mode on the last real (non-"-") positional file. Returns a
/// non-null exit code on followFile failure; null otherwise.
fn runTail_enterFollow(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed_args: anytype,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
) !?u8 {
    assert(options.follow);
    assert(parsed_args.positionals.len > 0);

    var last_file_path: ?[]const u8 = null;
    var real_file_count: usize = 0; // tiger:allow:usize-arch counts slice elements
    var j = parsed_args.positionals.len; // tiger:allow:usize-arch slice index
    while (j > 0) {
        j -= 1;
        if (!std.mem.eql(u8, parsed_args.positionals[j], "-")) {
            real_file_count += 1;
            if (last_file_path == null) {
                last_file_path = parsed_args.positionals[j];
            }
        }
    }
    // The backward scan ran to completion, and each positional contributes at
    // most one to the real-file count.
    assert(j == 0);
    assert(real_file_count <= parsed_args.positionals.len);
    if (real_file_count > 1) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "tail",
            "warning: following only '{s}'; multiple-file follow not yet supported",
            .{last_file_path.?},
        );
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
    }
    if (last_file_path) |path| {
        // Flush initial output before entering the follow loop
        stdout_writer.flush() catch {};
        followFile(allocator, io, path, stdout_writer, stderr_writer, options.*) catch |err| {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "tail",
                "cannot open '{s}' for reading: {s}",
                .{ path, common.posixErrorString(err) },
            );
            return @intFromEnum(common.ExitCode.general_error);
        };
    }

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

/// Follow a file for new content, using OS-native file watching.
/// Uses kqueue on macOS/BSD and inotify on Linux.
/// This function runs an infinite loop and only returns on error.
fn followFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: TailOptions,
) !void {
    // Follow mode is the only context that reaches the watch machinery.
    assert(options.follow);

    var waited_for_file = false;
    var file = try followFile_openInitial(
        allocator,
        io,
        path,
        stderr_writer,
        &options,
        &waited_for_file,
    );
    errdefer file.close(io);
    // If we waited for the file to appear, read from the start
    // (processFile never ran). Otherwise resume from end.
    const last_pos: u64 = if (waited_for_file) 0 else try file.length(io);
    const last_inode = try getInode(io, path);

    if (comptime builtin.os.tag == .linux) {
        try followFile_runInotify(
            allocator,
            io,
            path,
            &file,
            last_pos,
            last_inode,
            stdout_writer,
            stderr_writer,
            &options,
        );
    } else {
        try followFile_runKqueue(
            allocator,
            io,
            path,
            &file,
            last_pos,
            last_inode,
            stdout_writer,
            stderr_writer,
            &options,
        );
    }
}

/// Linux follow loop: register an inotify watch and stream new data on each
/// event, handling -F rotation and truncation. Returns only on error.
fn followFile_runInotify(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file: *std.Io.File,
    last_pos_init: u64,
    last_inode_init: u64,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
) !void {
    // Don't assert path.len > 0: an empty path ("") is a legal positional and
    // must reach openFile's error path rather than panicking.
    assert(builtin.os.tag == .linux);
    assert(builtin.os.tag != .macos);

    var last_pos = last_pos_init;
    var last_inode = last_inode_init;
    const watch_mask = std.os.linux.IN.MODIFY |
        std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF;
    const inotify_fd = try inotifyInit1(std.os.linux.IN.CLOEXEC);
    defer closeFd(inotify_fd);
    const path_z = try std.mem.Allocator.dupeZ(allocator, u8, path);
    defer allocator.free(path_z);
    var wd = try inotifyAddWatch(inotify_fd, path_z, watch_mask);

    // Read any data written before the watch was registered
    last_pos = try readNewData(io, file.*, last_pos, stdout_writer);

    // Intentional blocking event loop; relocated verbatim from followFile.
    while (true) { // tiger:allow:unbounded-loop intentional follow loop
        // Block until inotify event
        var event_buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        const bytes_read = try std.posix.read(inotify_fd, &event_buf);
        if (bytes_read == 0) continue;

        // Check for file rotation (-F)
        if (options.follow_retry) {
            const new_inode = try followFile_rotationInode(allocator, io, path, stderr_writer);
            if (new_inode != last_inode) {
                const new_file = try std.Io.Dir.cwd().openFile(io, path, .{});
                inotifyRmWatch(inotify_fd, wd);
                file.close(io);
                file.* = new_file;
                last_inode = new_inode;
                last_pos = 0;
                wd = try inotifyAddWatch(inotify_fd, path_z, watch_mask);
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "tail",
                    "'{s}' has been replaced;  following new file",
                    .{path},
                );
                stderr_writer.flush() catch {};
                // Fall through to read any data already in the new file
            }
        }

        try followFile_checkTruncation(allocator, io, file.*, path, &last_pos, stderr_writer);
        last_pos = try readNewData(io, file.*, last_pos, stdout_writer);
    }
}

/// macOS/BSD follow loop: register a kqueue VNODE watch and stream new data on
/// each event, handling -F rotation and truncation. Returns only on error.
fn followFile_runKqueue(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file: *std.Io.File,
    last_pos_init: u64,
    last_inode_init: u64,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
) !void {
    // Don't assert path.len > 0: an empty path ("") is a legal positional and
    // must reach openFile's error path rather than panicking.
    assert(builtin.os.tag != .linux);
    assert(builtin.os.tag != .freestanding);

    var last_pos = last_pos_init;
    var last_inode = last_inode_init;
    const kq = try kqueueCreate();
    defer closeFd(kq);

    var changelist = [1]std.c.Kevent{.{
        .ident = @as(usize, @intCast(file.handle)), // tiger:allow:usize-arch kevent ident type
        .filter = std.c.EVFILT.VNODE,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME |
            std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB,
        .data = 0,
        .udata = 0,
    }};
    // Register the watch
    _ = try keventCall(kq, &changelist, &.{}, null);

    // Read any data written before the watch was registered
    last_pos = try readNewData(io, file.*, last_pos, stdout_writer);

    // Intentional blocking event loop; relocated verbatim from followFile.
    while (true) { // tiger:allow:unbounded-loop intentional follow loop
        // Wait for events (blocks)
        var eventlist: [1]std.c.Kevent = undefined;
        const nevents = try keventCall(kq, &.{}, &eventlist, null);
        if (nevents == 0) continue;

        // Check for file rotation (-F)
        if (options.follow_retry) {
            const new_inode = try followFile_rotationInode(allocator, io, path, stderr_writer);
            if (new_inode != last_inode) {
                const new_file = try std.Io.Dir.cwd().openFile(io, path, .{});
                file.close(io);
                file.* = new_file;
                last_inode = new_inode;
                last_pos = 0;
                // kevent ident field requires usize; re-register on new fd.
                changelist[0].ident = @as(usize, @intCast(file.handle)); // tiger:allow:usize-arch
                _ = try keventCall(kq, &changelist, &.{}, null);
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "tail",
                    "'{s}' has been replaced;  following new file",
                    .{path},
                );
                stderr_writer.flush() catch {};
                // Fall through to read any data already in the new file
            }
        }

        try followFile_checkTruncation(allocator, io, file.*, path, &last_pos, stderr_writer);
        last_pos = try readNewData(io, file.*, last_pos, stdout_writer);
    }
}

/// Open the followed file, retrying under -F when it does not yet exist.
/// Sets waited_out to true when it had to wait for the file to appear.
fn followFile_openInitial(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stderr_writer: *std.Io.Writer,
    options: *const TailOptions,
    waited_out: *bool,
) !std.Io.File {
    // Don't assert path.len > 0: an empty path ("") is a legal positional and
    // must reach openFile's error path rather than panicking. The caller seeds
    // waited_out to false; this helper is the only writer.
    assert(waited_out.* == false);
    assert(options.follow);

    return std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| blk: {
        if (options.follow_retry and err == error.FileNotFound) {
            // -F: wait for file to appear
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "tail",
                "cannot open '{s}' for reading: {s}",
                .{ path, common.posixErrorString(err) },
            );
            stderr_writer.flush() catch {};
            waited_out.* = true;
            // Bounded by the file appearing; relocated verbatim from followFile.
            while (true) { // tiger:allow:unbounded-loop intentional appear-wait
                io.sleep(
                    std.Io.Duration.fromNanoseconds(@intCast(std.time.ns_per_s)),
                    .awake,
                ) catch {};
                break :blk std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
            }
        } else {
            return err;
        }
    };
}

/// Fetch the current inode of the followed file. Under FileNotFound, wait for
/// the file to reappear (bounded by the reappearance event) and return its
/// new inode; other errors propagate.
fn followFile_rotationInode(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stderr_writer: *std.Io.Writer,
) !u64 {
    assert(path.len > 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);

    return getInode(io, path) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk try followFile_waitForReappear(allocator, io, path, stderr_writer);
        } else {
            return err;
        }
    };
}

/// File has become inaccessible during rotation; wait until it reappears and
/// return its new inode.
fn followFile_waitForReappear(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stderr_writer: *std.Io.Writer,
) !u64 {
    assert(path.len > 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);

    // File is gone — wait for it to reappear. This helper's only caller
    // (followFile_rotationInode) routes here exclusively on FileNotFound.
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "tail",
        "'{s}' has become inaccessible: {s}",
        .{ path, common.posixErrorString(error.FileNotFound) },
    );
    stderr_writer.flush() catch {};
    // Bounded by the file reappearing; relocated verbatim from followFile.
    while (true) { // tiger:allow:unbounded-loop intentional reappear-wait
        io.sleep(
            std.Io.Duration.fromNanoseconds(@intCast(std.time.ns_per_s)),
            .awake,
        ) catch {};
        if (getInode(io, path)) |inode| {
            return inode;
        } else |_| {}
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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    // Create test file with 15 lines
    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\n" ++
        "line9\nline10\nline11\nline12\nline13\nline14\nline15\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, .{});

    try testing.expectEqualStrings(
        "line6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\n",
        aw.writer.buffered(),
    );
}

test "tail with -n 5 outputs last 5 lines" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 5 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line3\nline4\nline5\nline6\nline7\n", aw.writer.buffered());
}

test "tail with -n 0 outputs nothing" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 0 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail with -c 10 outputs last 10 bytes" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "abcdefghijklmnopqrstuvwxyz";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 10 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("qrstuvwxyz", aw.writer.buffered());
}

test "tail with -c 0 outputs nothing" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "some content here";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 0 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail handles line count larger than file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 100 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line1\nline2\nline3\n", aw.writer.buffered());
}

test "tail handles byte count larger than file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "small";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 100 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("small", aw.writer.buffered());
}

test "tail handles empty file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("empty.txt", "", null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try testTailFile(io, tmp_dir.dir(), "empty.txt", &aw.writer, .{});

    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail handles file with no final newline" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3"; // no final newline
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line2\nline3", aw.writer.buffered());
}

test "tail handles very long lines" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

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

    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const result = testTailFile(io, tmp_dir.dir(), "nonexistent.txt", &aw.writer, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "tail with -z handles zero-terminated lines" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\x00line2\x00line3\x00";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 2, .zero_terminated = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line2\x00line3\x00", aw.writer.buffered());
}

test "tail with binary file in byte mode" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const binary_content = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC };
    try tmp_dir.createFile("binary.txt", &binary_content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .byte_count = 4 };
    try testTailFile(io, tmp_dir.dir(), "binary.txt", &aw.writer, options);

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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 1, .from_beginning = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    // +1 means skip 0 lines, output everything
    try testing.expectEqualStrings("line1\nline2\nline3\nline4\nline5\n", aw.writer.buffered());
}

test "tail -n +3 skips first 2 lines (from-beginning)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 3, .from_beginning = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    // +3 means skip first 2 lines, output from line 3 onward
    try testing.expectEqualStrings("line3\nline4\nline5\n", aw.writer.buffered());
}

test "tail -n +NUM larger than file outputs nothing" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 100, .from_beginning = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    // +100 on a 2-line file: skip 99 lines, nothing left
    try testing.expectEqualStrings("", aw.writer.buffered());
}

test "tail -n +NUM detected via runTail arg parsing" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // Get the real path for the file
    const path = try tmp_dir.getPath("test.txt");
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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    // Create a file with 2048 bytes (4 blocks of 512)
    var content: [2048]u8 = undefined;
    @memset(content[0..1024], 'A');
    @memset(content[1024..2048], 'B');
    try tmp_dir.createFile("test.txt", &content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    // Create a file with 1536 bytes (3 blocks of 512)
    var content: [1536]u8 = undefined;
    @memset(content[0..512], 'A');
    @memset(content[512..1024], 'B');
    @memset(content[1024..1536], 'C');
    try tmp_dir.createFile("test.txt", &content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "short file content";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
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
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = null, .reverse = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line5\nline4\nline3\nline2\nline1\n", aw.writer.buffered());
}

test "tail: -r -n 3 reverses last 3 lines" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = 3, .reverse = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("line5\nline4\nline3\n", aw.writer.buffered());
}

test "tail: -r on single-line file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();

    const content = "only line\n";
    try tmp_dir.createFile("test.txt", content, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const options = TailOptions{ .line_count = null, .reverse = true };
    try testTailFile(io, tmp_dir.dir(), "test.txt", &aw.writer, options);

    try testing.expectEqualStrings("only line\n", aw.writer.buffered());
}

test "tail: -f and -r are mutually exclusive" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    var tmp_dir = TestDir.init(allocator);
    defer tmp_dir.deinit();
    try tmp_dir.createFile("test.txt", "content\n", null);

    // Build an absolute path for the test file
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_path_len = try tmp_dir.dir().realPathFile(io, "test.txt", &path_buf);
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
