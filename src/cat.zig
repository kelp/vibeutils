//! Concatenates and displays files with optional formatting.
//!
//! Supports line numbering (-n, -b), blank line squeezing (-s),
//! and special character visualization (-T, -E, -v, -A, -e, -t).
//! Maintains compatibility with GNU coreutils cat.
const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const testing = std.testing;

/// ASCII DEL character (0x7F) - represents the delete control character
/// that displays as '^?' when shown with -v flag
const ASCII_DEL = 127;

/// Command-line arguments for cat
const CatArgs = struct {
    help: bool = false,
    version: bool = false,
    show_all: bool = false,
    number_nonblank: bool = false,
    show_ends_and_nonprinting: bool = false,
    show_ends: bool = false,
    number: bool = false,
    squeeze_blank: bool = false,
    show_tabs_and_nonprinting: bool = false,
    show_tabs: bool = false,
    ignored_u: bool = false,
    ignored_l: bool = false,
    show_nonprinting: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .show_all = .{ .short = 'A', .desc = "Equivalent to -vET" },
        .number_nonblank = .{ .short = 'b', .desc = "Number non-empty output lines, overrides -n" },
        .show_ends_and_nonprinting = .{ .short = 'e', .desc = "Equivalent to -vE" },
        .show_ends = .{ .short = 'E', .desc = "Display $ at end of each line" },
        .number = .{ .short = 'n', .desc = "Number all output lines" },
        .squeeze_blank = .{ .short = 's', .desc = "Suppress repeated empty output lines" },
        .show_tabs_and_nonprinting = .{ .short = 't', .desc = "Equivalent to -vT" },
        .show_tabs = .{ .short = 'T', .desc = "Display TAB characters as ^I" },
        .ignored_u = .{ .short = 'u', .desc = "(no effect; for compatibility)" },
        .ignored_l = .{
            .short = 'l',
            .desc = "Set output to line buffered (no effect; for compatibility)",
        },
        .show_nonprinting = .{
            .short = 'v',
            .desc = "Use ^ and M- notation, except for LFD and TAB",
        },
    };
};

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("cat ({s}) {s}\n", .{ common.name, common.version });
}

/// Resolves GNU cat flag combinations into a unified options structure.
/// GNU cat defines several convenience flags that combine multiple behaviors:
/// - `-A` combines `-v`, `-E`, and `-T` (show all non-printing chars, ends, and tabs)
/// - `-e` combines `-v` and `-E` (show non-printing chars and line ends)
/// - `-t` combines `-v` and `-T` (show non-printing chars and tabs)
fn resolveFlagCombinations(parsed_args: CatArgs) CatOptions {
    return CatOptions{
        .number_lines = parsed_args.number,
        .number_nonblank = parsed_args.number_nonblank,
        .squeeze_blank = parsed_args.squeeze_blank,
        .show_ends = parsed_args.show_ends or parsed_args.show_all or
            parsed_args.show_ends_and_nonprinting,
        .show_tabs = parsed_args.show_tabs or parsed_args.show_all or
            parsed_args.show_tabs_and_nonprinting,
        .show_nonprinting = parsed_args.show_nonprinting or parsed_args.show_all or
            parsed_args.show_ends_and_nonprinting or parsed_args.show_tabs_and_nonprinting,
    };
}

pub fn runCat(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(CatArgs, allocator, args) catch |err|
        return runCat_mapParseError(allocator, stderr, err);
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout);
        return @intFromEnum(common.ExitCode.success);
    }

    // Resolve flag combinations following GNU cat conventions
    const options = resolveFlagCombinations(parsed_args);

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var line_state = LineNumberState{};
    // Postcondition of the literal init: line numbering starts at 1 (positive space).
    std.debug.assert(line_state.line_number == 1);
    // Postcondition of the literal init: squeeze tracking starts clean (negative space).
    std.debug.assert(!line_state.prev_blank);
    // Track errors to continue processing all files (POSIX requirement)
    var has_error = false;

    // No files specified, read from stdin; otherwise process each in order.
    if (parsed_args.positionals.len == 0) {
        const failed = runCat_processStdin(allocator, stdin, stdout, stderr, options, &line_state);
        if (failed) has_error = true;
    } else {
        for (parsed_args.positionals) |file_path| {
            // "-" means read from stdin; everything else is a regular file.
            const failed = if (std.mem.eql(u8, file_path, "-"))
                runCat_processStdin(allocator, stdin, stdout, stderr, options, &line_state)
            else
                runCat_processFile(allocator, io, file_path, stdout, stderr, options, &line_state);
            if (failed) has_error = true;
        }
    }

    return if (has_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
}

/// Maps an argparse error to the general_error exit code, printing the matching
/// GNU-style diagnostic. Unexpected errors propagate unchanged. Single-caller
/// helper for runCat.
fn runCat_mapParseError(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    err: anyerror,
) !u8 {
    // Compile-time sanity: failure and success are distinct exit codes
    // (positive space).
    std.debug.assert(@intFromEnum(common.ExitCode.general_error) !=
        @intFromEnum(common.ExitCode.success));
    // Negative space: the failure code is never the "no error" sentinel zero.
    std.debug.assert(@intFromEnum(common.ExitCode.general_error) != 0);
    switch (err) {
        error.UnknownFlag => {
            common.printErrorWithProgram(allocator, stderr, "cat", "unrecognized option", .{});
            return @intFromEnum(common.ExitCode.general_error);
        },
        error.MissingValue => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                "cat",
                "option requires an argument",
                .{},
            );
            return @intFromEnum(common.ExitCode.general_error);
        },
        error.InvalidValue => {
            common.printErrorWithProgram(allocator, stderr, "cat", "invalid option value", .{});
            return @intFromEnum(common.ExitCode.general_error);
        },
        else => return err,
    }
}

/// Streams stdin through processInput, reporting any error to stderr. Returns true
/// on error (the caller ORs this into has_error). Single-caller helper for runCat.
fn runCat_processStdin(
    allocator: std.mem.Allocator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CatOptions,
    state: *LineNumberState,
) bool {
    processInput(stdin, stdout, options, state) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr,
            "cat",
            "stdin: {s}",
            .{common.posixErrorString(err)},
        );
        return true;
    };
    return false;
}

/// Opens and streams a regular file through processInput, reporting any error to
/// stderr. Returns true on error (the caller ORs this into has_error). Single-caller
/// helper for runCat.
fn runCat_processFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CatOptions,
    state: *LineNumberState,
) bool {
    // Negative space: the stdin marker is dispatched elsewhere, never here.
    std.debug.assert(!std.mem.eql(u8, file_path, "-"));
    // GNU cat prints this operand unquoted ("cat: x: No such file or
    // directory"); keep parity.
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr,
            "cat",
            "{s}: {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return true;
    };
    defer file.close(io);

    // Zig 0.16's file_reader surfaces a generic error.ReadFailed when the
    // opened handle turns out to be a directory, so stat it up front and
    // report error.IsDir through the normal path instead of the raw name.
    const stat = file.stat(io) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr,
            "cat",
            "{s}: {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return true;
    };
    if (stat.kind == .directory) {
        // GNU cat prints this operand unquoted ("cat: x: Is a directory");
        // keep parity.
        common.printErrorWithProgram(
            allocator,
            stderr,
            "cat",
            "{s}: {s}",
            .{ file_path, common.posixErrorString(error.IsDir) },
        );
        return true;
    }
    // Negative space: directories were rejected above, so a regular read
    // attempt below can never legitimately hit error.IsDir again.
    std.debug.assert(stat.kind != .directory);

    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    // GNU cat prints this operand unquoted ("cat: x: Is a directory");
    // keep parity.
    processInput(&file_reader.interface, stdout, options, state) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr,
            "cat",
            "{s}: {s}",
            .{ file_path, common.posixErrorString(err) },
        );
        return true;
    };
    return false;
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runCat);
}

/// Print usage information to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: cat [OPTION]... [FILE]...
        \\Concatenate FILE(s) to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -A, --show-all           equivalent to -vET
        \\  -b, --number-nonblank    number nonempty output lines, overrides -n
        \\  -e                       equivalent to -vE
        \\  -E, --show-ends          display $ at end of each line
        \\  -n, --number             number all output lines
        \\  -s, --squeeze-blank      suppress repeated empty output lines
        \\  -t                       equivalent to -vT
        \\  -T, --show-tabs          display TAB characters as ^I
        \\  -u                       (no effect; for compatibility)
        \\  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Examples:
        \\  cat f - g  Output f's contents, then standard input, then g's contents.
        \\  cat        Copy standard input to standard output.
        \\
    );
}

/// Configuration options that control how cat formats and displays output.
/// These options determine line numbering, blank line handling, and special
/// character visualization.
const CatOptions = struct {
    /// Number all output lines when true (controlled by -n flag)
    number_lines: bool = false,
    /// Number only non-blank output lines when true (controlled by -b flag,
    /// overrides number_lines)
    number_nonblank: bool = false,
    /// Suppress consecutive empty output lines when true (controlled by -s flag)
    squeeze_blank: bool = false,
    /// Display '$' at the end of each line when true (controlled by -E flag)
    show_ends: bool = false,
    /// Display TAB characters as '^I' when true (controlled by -T flag)
    show_tabs: bool = false,
    /// Display non-printing characters using caret and M- notation when true
    /// (controlled by -v flag)
    show_nonprinting: bool = false,
};

/// Maintains line numbering and blank line tracking state across multiple input files.
/// This state persists between files to ensure continuous line numbering when processing
/// multiple files in a single cat invocation.
const LineNumberState = struct {
    /// Current line number for numbering output (starts at 1)
    line_number: usize = 1,
    /// Tracks whether the previous line was blank for squeeze_blank functionality
    prev_blank: bool = false,
};

/// Streams chunks directly from reader to writer with no heap allocation,
/// used when no formatting options are active. peekGreedy(1) fills the
/// internal buffer and returns all available bytes. Single-caller helper
/// for processInput.
fn processInput_streamRaw(reader: anytype, writer: anytype) !void {
    while (true) { // tiger:allow:unbounded-loop EOF-bounded (peekGreedy EndOfStream)
        const chunk = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try writer.writeAll(chunk);
        reader.toss(chunk.len);
    }
}

/// Format output according to the specified options.
/// Maintains line numbering state across multiple files.
/// Streams data directly from the reader without buffering entire
/// files into memory. The no-formatting path uses peekGreedy/toss
/// for zero-copy throughput; the formatting path reads line by line
/// with takeDelimiterInclusive and handles lines longer than buffer
/// by processing them in chunks (StreamTooLong error).
fn processInput(
    reader: anytype,
    writer: anytype,
    options: CatOptions,
    state: *LineNumberState,
) !void {

    // Check if we need any line-based processing (formatting options)
    const needs_line_processing = options.number_lines or options.number_nonblank or
        options.squeeze_blank or options.show_ends or
        options.show_tabs or options.show_nonprinting;

    if (!needs_line_processing) {
        return processInput_streamRaw(reader, writer);
    }

    // Formatting path: process one line at a time using the reader's
    // internal buffer. takeDelimiterInclusive returns line content
    // including the newline, advancing past it. When lines exceed the
    // buffer size, handle StreamTooLong by processing chunks until we
    // find the newline or reach EOF.
    var at_line_start = true; // Track if we're at the beginning of a line for numbering
    // Terminates at EOF: takeDelimiterInclusive returns EndOfStream when the
    // reader is exhausted, which breaks the loop; the StreamTooLong branch always
    // tosses partial.len > 0 bytes, so it makes forward progress and cannot spin.
    while (true) { // tiger:allow:unbounded-loop terminates at EOF (see comment above)
        const line_with_nl = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Line exceeds buffer size - process what we have as a partial line
                const partial = reader.buffered();
                if (partial.len > 0) {
                    try processFormattedLineChunk(
                        writer,
                        partial,
                        false,
                        options,
                        state,
                        &at_line_start,
                    );
                    reader.toss(partial.len);
                }
                continue; // Keep reading more of the same line
            },
            error.EndOfStream => {
                // Handle any remaining partial line (no trailing newline)
                const remaining = reader.buffered();
                if (remaining.len > 0) {
                    try processFormattedLineChunk(
                        writer,
                        remaining,
                        false,
                        options,
                        state,
                        &at_line_start,
                    );
                    reader.toss(remaining.len);
                }
                break;
            },
            else => |e| return e,
        };
        // takeDelimiterInclusive returns bytes up to and including '\n', so the
        // slice always contains the delimiter; guards the len - 1 below from underflow.
        std.debug.assert(line_with_nl.len >= 1);
        // Strip the trailing newline for processFormattedLineChunk (it adds it back)
        const line = line_with_nl[0 .. line_with_nl.len - 1];
        try processFormattedLineChunk(writer, line, true, options, state, &at_line_start);
        at_line_start = true; // After a complete line, we're at the start of the next
    }
}

/// Apply formatting to a line chunk and write it to the writer.
/// `has_newline` indicates whether this chunk ends with a newline.
/// `at_line_start` tracks whether we're at the beginning of a line (for line numbering).
/// When processing chunks of a long line, only the first chunk is at line start.
fn processFormattedLineChunk(
    writer: anytype,
    chunk: []const u8,
    has_newline: bool,
    options: CatOptions,
    state: *LineNumberState,
    at_line_start: *bool,
) !void {
    const is_blank = chunk.len == 0;

    // Only handle squeeze_blank and line numbering at the start of a line
    if (at_line_start.*) {
        // Handle squeeze blank: skip consecutive blank lines
        if (options.squeeze_blank and is_blank and state.prev_blank) {
            // Only update at_line_start if we actually have a newline
            if (has_newline) {
                at_line_start.* = true;
            }
            return;
        }
        if (has_newline) {
            state.prev_blank = is_blank;
        }

        // Handle line numbering (merged branches)
        const should_number = (options.number_nonblank and !is_blank) or
            (options.number_lines and !options.number_nonblank);
        if (should_number) {
            try writer.print("{d: >6}\t", .{state.line_number});
            state.line_number += 1;
        }

        at_line_start.* = false; // We've processed the line start
    }

    // Write the chunk content with optional special character handling.
    // When -E is active (without -v), a trailing \r before \n must be
    // rendered as "^M$" to match GNU cat behavior.
    const trailing_cr = has_newline and options.show_ends and
        !options.show_nonprinting and chunk.len > 0 and chunk[chunk.len - 1] == '\r';

    if (options.show_tabs or options.show_nonprinting) {
        try writeWithSpecialChars(writer, chunk, options);
    } else if (trailing_cr) {
        // trailing_cr requires chunk.len > 0 (a conjunct above), so the slice below
        // is in-bounds and chunk.len - 1 cannot underflow.
        std.debug.assert(chunk.len >= 1);
        try writer.writeAll(chunk[0 .. chunk.len - 1]);
        try writer.writeAll("^M");
    } else {
        try writer.writeAll(chunk);
    }

    // Write newline only if this chunk ends with one
    if (has_newline) {
        if (options.show_ends) {
            try writer.writeAll("$");
        }
        try writer.writeAll("\n");
    }
}

/// Write line with special characters shown in caret and M- notation
fn writeWithSpecialChars(writer: anytype, line: []const u8, options: CatOptions) !void {
    for (line) |ch| {
        if (ch == '\t' and options.show_tabs) {
            try writer.writeAll("^I");
        } else if (options.show_nonprinting and ch < 32 and ch != '\t') {
            // Control characters
            try writer.print("^{c}", .{ch + 64});
        } else if (options.show_nonprinting and ch == ASCII_DEL) {
            try writer.writeAll("^?");
        } else if (options.show_nonprinting and ch >= 128) {
            // High bit set - use M- notation
            try writer.writeAll("M-");
            const ch_low = ch & 0x7F; // Strip high bit
            if (ch_low < 32) {
                // Control character in high range
                try writer.print("^{c}", .{ch_low + 64});
            } else if (ch_low == ASCII_DEL) {
                // DEL character
                try writer.writeAll("^?");
            } else {
                // Regular printable character
                try writer.writeByte(ch_low);
            }
        } else {
            try writer.writeByte(ch);
        }
    }
}

test "cat reads single file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Hello, world!\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Hello, world!\n", stdout_aw.writer.buffered());
}

test "cat concatenates multiple files" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("file1.txt", "First file\n", null);
    try tmp_dir.createFile("file2.txt", "Second file\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const path1 = try tmp_dir.getPath("file1.txt");
    defer testing.allocator.free(path1);
    const path2 = try tmp_dir.getPath("file2.txt");
    defer testing.allocator.free(path2);

    const args = [_][]const u8{ path1, path2 };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("First file\nSecond file\n", stdout_aw.writer.buffered());
}

test "cat with -n numbers all lines" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line 1\nLine 2\nLine 3\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings(
        "     1\tLine 1\n     2\tLine 2\n     3\tLine 3\n",
        stdout_aw.writer.buffered(),
    );
}

test "cat with -b numbers non-blank lines" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line 1\n\nLine 3\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-b", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings(
        "     1\tLine 1\n\n     2\tLine 3\n",
        stdout_aw.writer.buffered(),
    );
}

test "cat with -s squeezes blank lines" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line 1\n\n\n\nLine 2\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-s", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1\n\nLine 2\n", stdout_aw.writer.buffered());
}

test "cat with -E shows ends" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line 1\nLine 2\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-E", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1$\nLine 2$\n", stdout_aw.writer.buffered());
}

test "cat with -T shows tabs" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "col1\tcol2\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-T", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("col1^Icol2\n", stdout_aw.writer.buffered());
}

test "cat handles non-existent file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const tmp_base_path = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_base_path);
    const nonexistent_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/nonexistent.txt",
        .{tmp_base_path},
    );
    defer testing.allocator.free(nonexistent_path);

    const args = [_][]const u8{nonexistent_path};
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "cat with -A shows all (equivalent to -vET)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line 1\t\nLine 2\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-A", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1^I$\nLine 2$\n", stdout_aw.writer.buffered());
}

test "cat with -e shows ends and non-printing (equivalent to -vE)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line 1\nLine 2\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-e", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line 1$\nLine 2$\n", stdout_aw.writer.buffered());
}

test "cat with -t shows tabs and non-printing (equivalent to -vT)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Line\twith\ttabs\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-t", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Line^Iwith^Itabs\n", stdout_aw.writer.buffered());
}

test "cat with -l flag is ignored" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Test content\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-l", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    // -l should be ignored, so output should be normal
    try testing.expectEqualStrings("Test content\n", stdout_aw.writer.buffered());
}

test "cat with -u flag is ignored" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("test.txt", "Test content\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-u", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    // -u should be ignored, so output should be normal
    try testing.expectEqualStrings("Test content\n", stdout_aw.writer.buffered());
}

test "cat with -A and control characters" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create file with control character (^A = \x01)
    try tmp_dir.createFile("test.txt", "Test\x01\tEnd\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-A", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("Test^A^IEnd$\n", stdout_aw.writer.buffered());
}

test "cat handles very long lines without truncation" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a line longer than the 8192-byte read buffer
    const long_line = "A" ** 8192 ++ "\n";
    try tmp_dir.createFile("test.txt", long_line, null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{file_path};
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings(long_line, stdout_aw.writer.buffered());
}

test "cat with -n handles very long lines correctly" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a line longer than the 8192-byte read buffer
    const long_line = "A" ** 8192 ++ "\n";
    try tmp_dir.createFile("test.txt", long_line, null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-n", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);

    // Verify line number appears only once at the beginning
    const expected = "     1\t" ++ "A" ** 8192 ++ "\n";
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "cat continues processing files after error" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create one good file
    try tmp_dir.createFile("good.txt", "Good content\n", null);

    // Get absolute paths for the test
    const good_path = try tmp_dir.getPath("good.txt");
    defer testing.allocator.free(good_path);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Create a non-existent file path in the temp directory
    const tmp_base_path = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_base_path);
    const nonexistent_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/definitely-nonexistent-file.txt",
        .{tmp_base_path},
    );
    defer testing.allocator.free(nonexistent_path);

    // Test with non-existent file followed by good file
    const args = [_][]const u8{ nonexistent_path, good_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should return error exit code due to nonexistent file
    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);

    // But should have processed the good file
    try testing.expectEqualStrings("Good content\n", stdout_aw.writer.buffered());

    // And should have error message for bad file
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "cat -E renders trailing CR as ^M$ on CRLF lines" {
    // BUG: GNU cat -E converts a trailing \r before \n into "^M$\n".
    // Our implementation outputs the raw \r byte followed by "$\n",
    // which on a terminal causes the cursor to return to column 0
    // and "$" overwrites the first character.
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // File content: "test\r\n" (CRLF line ending)
    try tmp_dir.createFile("crlf.txt", "test\r\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("crlf.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-E", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    // Expected: "test^M$\n" — the \r is shown as ^M before the $ end marker
    try testing.expectEqualStrings("test^M$\n", stdout_aw.writer.buffered());
}

test "cat -E preserves mid-line CR as raw byte" {
    // Mid-line \r is NOT converted to ^M — only trailing \r (before \n).
    // This matches GNU cat behavior.
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // File content: "ab\rcd\n" — \r is mid-line, not before \n
    try tmp_dir.createFile("midcr.txt", "ab\rcd\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("midcr.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-E", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    // Mid-line \r stays as raw \r, only the $ end marker is added
    try testing.expectEqualStrings("ab\rcd$\n", stdout_aw.writer.buffered());
}

test "cat -E with multiple CRLF lines" {
    // Each CRLF line should get ^M$ treatment.
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.createFile("multi.txt", "line1\r\nline2\r\nline3\n", null);

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const file_path = try tmp_dir.getPath("multi.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-E", file_path };
    const exit_code = try runCat(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.success)), exit_code);
    try testing.expectEqualStrings("line1^M$\nline2^M$\nline3$\n", stdout_aw.writer.buffered());
}
