//! head - output the first part of files

const common = @import("common");
const std = @import("std");
const testing = std.testing;

/// Command-line arguments for the head utility
const HeadArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Number of lines to output (default: 10); accepts negative values like "-3"
    lines: ?[]const u8 = null,
    /// Number of bytes to output (overrides -n)
    bytes: ?u64 = null,
    /// Quiet flag - never print headers
    quiet: bool = false,
    /// Suppress headers (alias for --quiet)
    silent: bool = false,
    /// Verbose flag - always print headers
    verbose: bool = false,
    /// Use NUL as line delimiter instead of newline
    zero_terminated: bool = false,
    /// Files to process
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .bytes = .{ .short = 'c', .desc = "Print the first NUM bytes of each file" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .lines = .{ .short = 'n', .desc = "Print the first NUM lines instead of the first 10" },
        .quiet = .{ .short = 'q', .desc = "Never print headers giving file names" },
        .silent = .{
            .short = 0,
            .desc = "Never print headers giving file names (alias for --quiet)",
        },
        .verbose = .{ .short = 'v', .desc = "Always print headers giving file names" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .zero_terminated = .{ .short = 'z', .desc = "Line delimiter is NUL, not newline" },
    };
};

/// Expand obsolete -NUM syntax (e.g., -5) to -n NUM for backwards compatibility.
/// Does not expand -NUM when it follows -n or -c (where it is a value, not obsolete syntax).
fn expandObsoleteArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    // Count how many extra args we need (one extra per -NUM arg)
    var extra: usize = 0;
    var prev_expects_value = false;
    for (args) |arg| {
        if (prev_expects_value) {
            prev_expects_value = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--lines") or std.mem.eql(u8, arg, "--bytes"))
        {
            prev_expects_value = true;
            continue;
        }
        if (isObsoleteNumArg(arg)) extra += 1;
    }
    std.debug.assert(extra <= args.len); // At most one extra slot per arg.
    if (extra == 0) return allocator.dupe([]const u8, args);

    const expanded = try allocator.alloc([]const u8, args.len + extra);
    std.debug.assert(expanded.len == args.len + extra); // Buffer sized from count.
    var i: usize = 0;
    prev_expects_value = false;
    for (args) |arg| {
        if (prev_expects_value) {
            prev_expects_value = false;
            expanded[i] = arg;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--lines") or std.mem.eql(u8, arg, "--bytes"))
        {
            prev_expects_value = true;
            expanded[i] = arg;
            i += 1;
            continue;
        }
        if (isObsoleteNumArg(arg)) {
            std.debug.assert(arg.len >= 2); // isObsoleteNumArg guarantees -NUM form.
            expanded[i] = "-n";
            i += 1;
            expanded[i] = arg[1..]; // strip leading '-'
            i += 1;
        } else {
            expanded[i] = arg;
            i += 1;
        }
    }
    std.debug.assert(i == expanded.len); // Fill loop wrote every reserved slot.
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

/// Core head functionality accepting parsed arguments and writers.
/// Processes files or stdin according to the provided options.
pub fn runHead(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const expanded_args = try expandObsoleteArgs(allocator, args);
    defer allocator.free(expanded_args);
    std.debug.assert(expanded_args.len >= args.len); // expandObsoleteArgs never shrinks.

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        HeadArgs,
        allocator,
        expanded_args,
        "head",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

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

    // Parse line count, handling negative values (e.g., -n -3 means "all but last 3")
    const lc = try runHead_parseLineCount(allocator, parsed_args.lines, stderr_writer);
    if (!lc.ok) return @intFromEnum(common.ExitCode.general_error);
    const line_count = lc.line_count;
    const negative_count = lc.negative_count;

    const options = runHead_buildOptions(parsed_args, line_count, negative_count);

    return runHead_processInputs(
        allocator,
        io,
        parsed_args.positionals,
        options,
        stdout_writer,
        stderr_writer,
    );
}

/// Dispatch each positional (or stdin when none) through processInput, applying
/// GNU's inter-file blank-line and header rules. Returns the exit code: general
/// error if any file failed, success otherwise.
fn runHead_processInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    positionals: []const []const u8,
    options: HeadOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    if (positionals.len == 0) {
        // No files specified, read from stdin
        try processInput(stdin, stdout_writer, options, allocator);
        return @intFromEnum(common.ExitCode.success);
    }

    var had_error = false;
    // Process each file in order
    for (positionals, 0..) |file_path, i| {
        if (i > 0 and options.show_headers) {
            try stdout_writer.writeAll("\n");
        }

        if (std.mem.eql(u8, file_path, "-")) {
            // "-" means read from stdin
            if (options.show_headers) {
                try stdout_writer.writeAll("==> standard input <==\n");
            }
            try processInput(stdin, stdout_writer, options, allocator);
        } else {
            // Open and process regular file
            const file_failed = try runHead_processFile(
                allocator,
                io,
                file_path,
                stdout_writer,
                stderr_writer,
                &options,
            );
            if (file_failed) had_error = true;
        }
    }
    if (had_error) {
        return @intFromEnum(common.ExitCode.general_error);
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Result of parsing the -n/--lines argument.
/// When `ok` is false, the helper has already reported the error; the caller
/// must exit with the general_error code and must not read
/// line_count/negative_count.
const ParsedLineCount = struct {
    line_count: u64,
    negative_count: u64,
    ok: bool,
};

/// Parse the -n/--lines value, handling negative values (e.g., "-3" means
/// "all but last 3"). On parse failure reports the error via stderr_writer and
/// returns ok=false; defaults are preserved unchanged on the failure path.
fn runHead_parseLineCount(
    allocator: std.mem.Allocator,
    lines_opt: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) !ParsedLineCount {
    var line_count: u64 = DEFAULT_LINE_COUNT;
    var negative_count: u64 = 0;
    // Compile-time coupling: HeadOptions.line_count default literal must match.
    std.debug.assert(DEFAULT_LINE_COUNT == 10);
    if (lines_opt) |lines_str| {
        if (lines_str.len > 0 and lines_str[0] == '-') {
            // Negative: output all but last N lines
            negative_count = std.fmt.parseUnsigned(u64, lines_str[1..], 10) catch {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "head",
                    "invalid number of lines: '{s}'",
                    .{lines_str},
                );
                return .{ .line_count = line_count, .negative_count = negative_count, .ok = false };
            };
        } else {
            line_count = std.fmt.parseUnsigned(u64, lines_str, 10) catch {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "head",
                    "invalid number of lines: '{s}'",
                    .{lines_str},
                );
                return .{ .line_count = line_count, .negative_count = negative_count, .ok = false };
            };
        }
    }
    const result = ParsedLineCount{
        .line_count = line_count,
        .negative_count = negative_count,
        .ok = true,
    };
    // Positive space: negative and explicit-positive line counts are mutually exclusive.
    const counts_mutually_exclusive =
        result.negative_count == 0 or result.line_count == DEFAULT_LINE_COUNT;
    std.debug.assert(counts_mutually_exclusive);
    // Negative space: the paired form, a non-default explicit line count is only
    // reachable when the negative count was never touched.
    const counts_mutually_exclusive_paired =
        result.line_count == DEFAULT_LINE_COUNT or result.negative_count == 0;
    std.debug.assert(counts_mutually_exclusive_paired);
    return result;
}

/// Open and process a single regular file (never "-"/stdin, which the parent
/// handles inline). Returns true on any per-file error (after reporting it),
/// mirroring the original `had_error = true; continue;`; false on success.
fn runHead_processFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: *const HeadOptions,
) !bool {
    std.debug.assert(!std.mem.eql(u8, file_path, "-")); // Negative space: stdin handled by parent.
    const delimiter_is_newline_or_nul =
        options.line_delimiter == '\n' or options.line_delimiter == 0;
    std.debug.assert(delimiter_is_newline_or_nul); // Positive space: delimiter is newline or NUL.

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "head",
            "cannot open '{s}' for reading: {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return true;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "head",
            "error reading '{s}': {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return true;
    };
    if (stat.kind == .directory) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "head",
            "error reading '{s}': Is a directory",
            .{file_path},
        );
        return true;
    }

    if (options.show_headers) {
        try stdout_writer.print("==> {s} <==\n", .{file_path});
    }
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    try processInput(&file_reader.interface, stdout_writer, options.*, allocator);
    return false;
}

/// Build HeadOptions from the parsed flags and the already-parsed line counts.
/// Header visibility follows GNU precedence: --quiet wins, then --verbose, then
/// the implicit "more than one file" rule.
fn runHead_buildOptions(
    parsed_args: HeadArgs,
    line_count: u64,
    negative_count: u64,
) HeadOptions {
    const is_quiet = parsed_args.quiet or parsed_args.silent;
    const show_headers = if (is_quiet)
        false
    else if (parsed_args.verbose)
        true
    else
        parsed_args.positionals.len > 1;
    const options = HeadOptions{
        .line_count = line_count,
        .negative_count = negative_count,
        .byte_count = parsed_args.bytes,
        .show_headers = show_headers,
        .line_delimiter = if (parsed_args.zero_terminated) 0 else '\n',
    };
    const headers_suppressed_when_quiet = !(options.show_headers and is_quiet);
    std.debug.assert(headers_suppressed_when_quiet); // Quiet must suppress headers.
    const delimiter_is_newline_or_nul =
        options.line_delimiter == '\n' or options.line_delimiter == 0;
    std.debug.assert(delimiter_is_newline_or_nul); // Newline or NUL only.
    return options;
}

/// Entry point for the head binary.
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runHead);
}

/// Print help message to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: head [OPTION]... [FILE]...
        \\Print the first 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes=NUM          print the first NUM bytes of each file
        \\  -n, --lines=NUM          print the first NUM lines instead of the first 10
        \\  -q, --quiet, --silent    never print headers giving file names
        \\  -v, --verbose            always print headers giving file names
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("head ({s}) {s}\n", .{ common.name, common.version });
}

/// Options for head behavior
const HeadOptions = struct {
    /// Number of lines to output (ignored if byte_count is set or negative_count > 0)
    line_count: u64 = 10,
    /// When > 0, output all but the last N lines (from -n -N)
    negative_count: u64 = 0,
    /// Number of bytes to output (overrides line_count if set)
    byte_count: ?u64 = null,
    /// Whether to show file headers
    show_headers: bool = false,
    /// Line delimiter character (newline by default, NUL with -z)
    line_delimiter: u8 = '\n',
};

/// Process input from a reader and output first lines/bytes to writer.
/// Streams data without reading the entire input into memory (except for
/// negative line counts which require buffering the entire input).
pub fn processInput(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: HeadOptions,
    allocator: ?std.mem.Allocator,
) !void {
    const delim = options.line_delimiter;
    const delimiter_is_newline_or_nul = delim == '\n' or delim == 0;
    std.debug.assert(delimiter_is_newline_or_nul); // Newline or NUL only.

    if (options.negative_count > 0) {
        // Negative count: output all but the last N lines.
        // Must buffer the entire input to know where the last N lines start.
        const alloc = allocator orelse return;
        try processInput_outputAllButLast(
            reader,
            writer,
            options.line_delimiter,
            options.negative_count,
            alloc,
        );
        return;
    }
    if (options.byte_count) |byte_count| {
        try processInput_outputBytes(reader, writer, byte_count);
    } else {
        // Line mode: output first N lines
        const delimiter = options.line_delimiter;
        var lines_written: u64 = 0;
        while (lines_written < options.line_count) {
            const got_delim = streamOneLine(reader, writer, delimiter) catch |err| return err;
            if (got_delim) {
                lines_written += 1;
            } else {
                break; // EOF
            }
        }
    }
}

/// Buffer all input lines and emit all but the last `negative_count`.
/// Only called when negative-count mode is active, so the full input must be
/// retained before any output can begin.
fn processInput_outputAllButLast(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    delimiter: u8,
    negative_count: u64,
    alloc: std.mem.Allocator,
) !void {
    std.debug.assert(negative_count > 0); // Helper only used in negative mode.
    const delimiter_is_newline_or_nul = delimiter == '\n' or delimiter == 0;
    std.debug.assert(delimiter_is_newline_or_nul); // Newline or NUL only.

    var all_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (all_lines.items) |line| alloc.free(line);
        all_lines.deinit(alloc);
    }
    // Read all lines from the reader
    while (true) { // tiger:allow:unbounded-loop EOF-bounded read
        const line = reader.takeDelimiterInclusive(delimiter) catch |err| switch (err) {
            error.EndOfStream => {
                // Handle remaining partial line (no trailing delimiter)
                const remaining = reader.buffered();
                if (remaining.len > 0) {
                    const owned = alloc.dupe(u8, remaining) catch return;
                    all_lines.append(alloc, owned) catch {
                        alloc.free(owned);
                        return;
                    };
                    reader.toss(remaining.len);
                }
                break;
            },
            else => |e| return e,
        };
        const owned = alloc.dupe(u8, line) catch return;
        all_lines.append(alloc, owned) catch {
            alloc.free(owned);
            return;
        };
    }
    // Output all but the last N lines
    const total = all_lines.items.len;
    const to_output = if (total > negative_count) total - negative_count else 0;
    std.debug.assert(to_output <= all_lines.items.len); // Slice bound is in range.
    for (all_lines.items[0..to_output]) |line| {
        try writer.writeAll(line);
    }
}

/// Stream the first `byte_count` bytes from `reader` to `writer`.
/// Reads greedily in chunks and stops at EOF or once the count is reached.
fn processInput_outputBytes(reader: *std.Io.Reader, writer: *std.Io.Writer, byte_count: u64) !void {
    // Byte mode: read chunks and write until byte_count reached
    var remaining: u64 = byte_count;
    while (remaining > 0) {
        std.debug.assert(remaining <= byte_count); // remaining never exceeds the request.
        // peekGreedy(1) fills the buffer and returns all available bytes
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        const max: u64 = std.math.maxInt(usize); // tiger:allow:usize-arch
        const capped: usize = @intCast(@min(remaining, max)); // tiger:allow:usize-arch
        const to_write = @min(capped, available.len);
        std.debug.assert(to_write <= available.len); // Slice bound is in range.
        std.debug.assert(to_write <= remaining); // No unsigned underflow below.
        try writer.writeAll(available[0..to_write]);
        reader.toss(to_write);
        remaining -= to_write;
    }
}

/// Read one delimiter-terminated line from `reader` and write it to `writer`.
/// Returns true if a delimiter byte was consumed; false on EOF (no delimiter).
/// Handles lines longer than the reader's buffer by streaming through in
/// chunks rather than failing with `error.StreamTooLong`.
fn streamOneLine(reader: *std.Io.Reader, writer: *std.Io.Writer, delimiter: u8) !bool {
    const delimiter_is_newline_or_nul = delimiter == '\n' or delimiter == 0;
    std.debug.assert(delimiter_is_newline_or_nul); // Newline or NUL only.
    // Returns on delimiter found or EOF; StreamTooLong tosses buffered bytes
    // each pass, so it always advances toward EOF and cannot spin forever.
    while (true) { // tiger:allow:unbounded-loop terminates at delimiter or EOF
        const line = reader.takeDelimiterInclusive(delimiter) catch |err| switch (err) {
            error.EndOfStream => {
                const remaining = reader.buffered();
                if (remaining.len > 0) {
                    try writer.writeAll(remaining);
                    reader.toss(remaining.len);
                }
                return false;
            },
            error.StreamTooLong => {
                // Line longer than read buffer; flush the buffered prefix
                // and keep looking for the delimiter on the next refill.
                const chunk = reader.buffered();
                try writer.writeAll(chunk);
                reader.toss(chunk.len);
                continue;
            },
            else => |e| return e,
        };
        try writer.writeAll(line);
        return true;
    }
}

// ========== CONSTANTS ==========

/// Default number of lines to display when no -n option is provided
const DEFAULT_LINE_COUNT: u64 = 10;

// ========== ERROR HANDLING ==========

/// Convert error to user-friendly message
// ========== TEST CONSTANTS ==========

const TEST_NEGATIVE_VALUE: []const u8 = "-5";

// ========== TESTS ==========

test "head outputs first 10 lines by default" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 15 lines
    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n" ++
        "Line 6\nLine 7\nLine 8\nLine 9\nLine 10\n" ++
        "Line 11\nLine 12\nLine 13\nLine 14\nLine 15\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    const expected = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n" ++
        "Line 6\nLine 7\nLine 8\nLine 9\nLine 10\n";
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "head with -n 5 outputs first 5 lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "5", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings(
        "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n",
        stdout_aw.writer.buffered(),
    );
}

test "head with -c 10 outputs first 10 bytes" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(
        io,
        tmp_dir.dir,
        "test.txt",
        "Hello, World! This is a test.\n",
    );

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-c", "10", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Hello, Wor", stdout_aw.writer.buffered());
}

test "head handles fewer lines than requested" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // Request 10 lines (default) but file only has 2
    const args = [_][]const u8{file_path};
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\n", stdout_aw.writer.buffered());
}

test "head handles fewer bytes than requested" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "Short");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // Request 1000 bytes but file only has 5
    const args = [_][]const u8{ "-c", "1000", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Short", stdout_aw.writer.buffered());
}

test "head handles empty input" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "head with -n 0 outputs nothing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "0", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "head with -c 0 outputs nothing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "Hello, World!\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-c", "0", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "head handles lines longer than read buffer (regression: StreamTooLong)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build a file whose first line is 9000 bytes long (> default 8192
    // read buffer). takeDelimiterInclusive returns StreamTooLong when a
    // line doesn't fit in the buffer; head must chunk past that.
    const long_line_len: usize = 9000;
    const content = blk: {
        var buf = try testing.allocator.alloc(u8, long_line_len + 1 + 6);
        @memset(buf[0..long_line_len], 'A');
        buf[long_line_len] = '\n';
        @memcpy(buf[long_line_len + 1 ..][0..6], "next\n\n");
        break :blk buf;
    };
    defer testing.allocator.free(content);
    try common.test_utils.createTestFile(io, tmp_dir.dir, "long.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "long.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "1", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    try testing.expectEqual(long_line_len + 1, out.len);
    for (out[0..long_line_len]) |c| try testing.expectEqual(@as(u8, 'A'), c);
    try testing.expectEqual(@as(u8, '\n'), out[long_line_len]);
}

test "head processes lines efficiently" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with many lines, request only the first 3
    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n" ++
        "Line 6\nLine 7\nLine 8\nLine 9\nLine 10\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", "3", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\n", stdout_aw.writer.buffered());
}

test "head processes bytes efficiently" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "ABCDEFGHIJKLMNOP");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-c", "5", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("ABCDE", stdout_aw.writer.buffered());
}

test "head handles invalid line count" {
    const io = testing.io;

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -n -5 is now valid (means "all but last 5 lines"), so use
    // a truly invalid value instead
    const args = [_][]const u8{ "-n", "abc" };
    const result = try runHead(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
}

test "head help flag works" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runHead(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: head") != null);
}

test "head version flag works" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runHead(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "head") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.version) != null);
}

test "head with line count larger than available lines" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "Only one line\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // Request 100 lines but file only has 1
    const args = [_][]const u8{ "-n", "100", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Only one line\n", stdout_aw.writer.buffered());
}

test "head byte count takes precedence over line count" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // Use -c (bytes) which should override default line count
    const args = [_][]const u8{ "-c", "10", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLin", stdout_aw.writer.buffered());
}

test "head continues after file error and outputs remaining files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "valid.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const valid_path = try tmp_dir.dir.realPathFileAlloc(io, "valid.txt", testing.allocator);
    defer testing.allocator.free(valid_path);

    // First file is nonexistent, second is valid
    const args = [_][]const u8{ "/nonexistent/file.txt", valid_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should return error exit code
    try testing.expectEqual(@as(u8, 1), exit_code);

    // But valid file output should still appear
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Line 1") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Line 2") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Line 3") != null);

    // And stderr should report the error
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

test "head with multiple files shows headers" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "file1.txt", "Content A\n");
    try common.test_utils.createTestFile(io, tmp_dir.dir, "file2.txt", "Content B\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const path1 = try tmp_dir.dir.realPathFileAlloc(io, "file1.txt", testing.allocator);
    defer testing.allocator.free(path1);
    const path2 = try tmp_dir.dir.realPathFileAlloc(io, "file2.txt", testing.allocator);
    defer testing.allocator.free(path2);

    const args = [_][]const u8{ path1, path2 };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should contain file headers
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "==>") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "<==") != null);

    // Should contain both files' content
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Content A") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Content B") != null);
}

test "head with -z uses NUL as line delimiter" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with NUL-separated "lines"
    const content = "Line 1\x00Line 2\x00Line 3\x00Line 4\x00Line 5\x00";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-z", "-n", "3", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\x00Line 2\x00Line 3\x00", stdout_aw.writer.buffered());
}

test "head with -z and default line count" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 15 NUL-separated "lines"
    const content = "L1\x00L2\x00L3\x00L4\x00L5\x00L6\x00L7\x00L8\x00" ++
        "L9\x00L10\x00L11\x00L12\x00L13\x00L14\x00L15\x00";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-z", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Default is 10 lines
    const expected = "L1\x00L2\x00L3\x00L4\x00L5\x00L6\x00L7\x00L8\x00L9\x00L10\x00";
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "head with -z and fewer items than requested" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 2 NUL-separated "lines"
    const content = "Line A\x00Line B\x00";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-z", "-n", "10", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line A\x00Line B\x00", stdout_aw.writer.buffered());
}

test "head directory in line mode returns exit code 1 not crash" {
    const io = testing.io;
    // GNU head: head /tmp prints "head: error reading '/tmp': Is a directory" to stderr, exits 1
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/tmp"};
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Must exit 1 (general error), not crash/panic
    try testing.expectEqual(@as(u8, 1), exit_code);
    // Stderr must contain a diagnostic about the directory, not a stack trace
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Is a directory") != null);
}

test "head directory in byte mode returns exit code 1 not crash" {
    const io = testing.io;
    // GNU head: head -c 10 /tmp prints "head: error reading '/tmp': Is a
    // directory" to stderr, exits 1
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", "10", "/tmp" };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Is a directory") != null);
}

test "head directory does not produce stack trace on stderr" {
    const io = testing.io;
    // Verify stderr does not contain stack trace markers
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/tmp"};
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), exit_code);
    // Must not contain Zig panic/stack trace indicators
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "panicked") == null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "error.") == null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), ".zig") == null);
}

test "head directory continues processing remaining files" {
    const io = testing.io;
    // GNU head processes remaining files after a directory error
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "valid.txt", "hello\n");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const valid_path = try tmp_dir.dir.realPathFileAlloc(io, "valid.txt", testing.allocator);
    defer testing.allocator.free(valid_path);

    const args = [_][]const u8{ "/tmp", valid_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should return error exit code but still output valid file
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Is a directory") != null);
}

test "head with obsolete -NUM syntax" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-3", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\n", stdout_aw.writer.buffered());
}

test "head --silent is alias for --quiet" {
    const io = testing.io;
    // BUG: --silent is not recognized (exits 1). GNU coreutils accepts
    // --silent as a synonym for --quiet/-q to suppress file headers.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content1 = "File A line 1\nFile A line 2\n";
    const content2 = "File B line 1\nFile B line 2\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "a.txt", content1);
    try common.test_utils.createTestFile(io, tmp_dir.dir, "b.txt", content2);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const path_a = try tmp_dir.dir.realPathFileAlloc(io, "a.txt", testing.allocator);
    defer testing.allocator.free(path_a);
    const path_b = try tmp_dir.dir.realPathFileAlloc(io, "b.txt", testing.allocator);
    defer testing.allocator.free(path_b);

    const args = [_][]const u8{ "--silent", path_a, path_b };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    // Should succeed (exit 0) and suppress headers, just like --quiet
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should be raw content without "==> ... <==" headers
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "==>") == null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "File A line 1") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "File B line 1") != null);
}

test "head -n -3 outputs all but last 3 lines" {
    const io = testing.io;
    // BUG: -n -3 (negative count) is not implemented. GNU head treats
    // -n -NUM as "output all but the last NUM lines". Currently exits 1.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try common.test_utils.createTestFile(io, tmp_dir.dir, "test.txt", content);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.dir.realPathFileAlloc(io, "test.txt", testing.allocator);
    defer testing.allocator.free(file_path);

    // -n -3 means "all but the last 3 lines" = first 2 lines
    const args = [_][]const u8{ "-n", "-3", file_path };
    const exit_code = try runHead(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 1\nLine 2\n", stdout_aw.writer.buffered());
}
