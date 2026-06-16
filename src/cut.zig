//! cut - remove sections from each line of files
//!
//! Supports byte (-b), character (-c), and field (-f) selection
//! with customizable delimiters. POSIX-compliant with GNU extensions.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// A single range (1-indexed, inclusive on both ends)
const Range = struct {
    start: usize, // 1-indexed
    end: usize, // 1-indexed, max_usize means "to end of line"

    const END: usize = std.math.maxInt(usize);
};

/// What kind of selection the user requested
const CutMode = enum {
    bytes,
    characters,
    fields,
};

/// Command-line arguments for cut
const CutArgs = struct {
    help: bool = false,
    version: bool = false,
    bytes: ?[]const u8 = null,
    characters: ?[]const u8 = null,
    delimiter: ?[]const u8 = null,
    fields: ?[]const u8 = null,
    only_delimited: bool = false,
    complement: bool = false,
    output_delimiter: ?[]const u8 = null,
    no_split: bool = false,
    zero_terminated: bool = false,
    whitespace_delim: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .bytes = .{ .short = 'b', .desc = "Select only these bytes", .value_name = "LIST" },
        .characters = .{ .short = 'c', .desc = "Select only these characters", .value_name = "LIST" },
        .delimiter = .{ .short = 'd', .desc = "Use DELIM instead of TAB", .value_name = "DELIM" },
        .fields = .{ .short = 'f', .desc = "Select only these fields", .value_name = "LIST" },
        .only_delimited = .{ .short = 's', .desc = "print only lines containing delimiters" },
        .complement = .{ .short = 0, .desc = "Complement the set of selected bytes/chars/fields" },
        .output_delimiter = .{ .short = 0, .desc = "Use STRING as output delimiter", .value_name = "STRING" },
        .no_split = .{ .short = 'n', .desc = "Do not split multi-byte characters (with -b)" },
        .whitespace_delim = .{ .short = 'w', .desc = "Use whitespace (spaces and tabs) as field delimiter" },
        .zero_terminated = .{ .short = 'z', .desc = "Line delimiter is NUL, not newline" },
    };
};

/// Parse a single non-empty, trimmed range token like "3", "5-7", "-3", or "5-".
/// Returns one Range; raises error.InvalidRange on malformed input.
fn parseRangeList_parseToken(token: []const u8) !Range {
    // Precondition: the caller skips empty tokens before calling this.
    assert(token.len > 0);

    if (std.mem.indexOfScalar(u8, token, '-')) |dash_pos| {
        const left = std.mem.trim(u8, token[0..dash_pos], " ");
        const right = std.mem.trim(u8, token[dash_pos + 1 ..], " ");

        if (left.len == 0 and right.len == 0) {
            // Just "-" alone is invalid
            return error.InvalidRange;
        }

        // Range.start/end are usize, so parseInt must use usize to match.
        const start: usize = if (left.len == 0) 1 else std.fmt.parseInt(usize, left, 10) catch return error.InvalidRange; // tiger:allow:usize-arch tiger:allow:long-line
        const end: usize = if (right.len == 0) Range.END else std.fmt.parseInt(usize, right, 10) catch return error.InvalidRange; // tiger:allow:usize-arch tiger:allow:long-line

        if (start == 0 or (end != Range.END and end == 0)) return error.InvalidRange;
        if (end != Range.END and start > end) return error.InvalidRange;

        // Postconditions: 1-indexed start; the guards above reject a 0 start
        // and any start > end, so a finite end is never below start.
        assert(start >= 1);
        if (end != Range.END) assert(start <= end);
        return .{ .start = start, .end = end };
    } else {
        // Range.start/end are usize, so parseInt must use usize to match.
        const val = std.fmt.parseInt(usize, token, 10) catch return error.InvalidRange; // tiger:allow:usize-arch tiger:allow:long-line
        if (val == 0) return error.InvalidRange;

        // Postcondition: single-value range is 1-indexed.
        assert(val >= 1);
        return .{ .start = val, .end = val };
    }
}

/// Merge a sorted slice of ranges, collapsing overlapping or adjacent ranges.
/// Caller owns the returned slice.
fn parseRangeList_mergeSorted(allocator: Allocator, sorted: []const Range) ![]Range {
    // Preconditions: non-empty input (needed for sorted[0]) and a 1-indexed
    // start (a 0 start should never reach merge -- parseToken rejected it).
    assert(sorted.len >= 1);
    assert(sorted[0].start >= 1);

    var merged = std.ArrayListUnmanaged(Range).empty;
    errdefer merged.deinit(allocator);

    try merged.append(allocator, sorted[0]);

    for (sorted[1..]) |r| {
        const last = &merged.items[merged.items.len - 1];
        // Check if r overlaps or is adjacent to last
        if (last.end == Range.END or (r.start <= last.end + 1)) {
            // Merge
            if (r.end == Range.END) {
                last.end = Range.END;
            } else if (last.end != Range.END and r.end > last.end) {
                last.end = r.end;
            }
        } else {
            try merged.append(allocator, r);
        }
    }

    // Postconditions on the merged list: positions are 1-indexed (start >= 1),
    // and every range is well-formed (start <= end). Merge raises only `end`
    // and never lowers a start, so these hold for every accepted input.
    assert(merged.items[0].start >= 1);
    const last_index = merged.items.len - 1;
    assert(merged.items[last_index].start <= merged.items[last_index].end);

    return merged.toOwnedSlice(allocator);
}

/// Parse a range list string like "1,3,5-7" or "-3" or "5-".
/// Returns a sorted, merged array of Range values.
/// Caller owns the returned slice.
fn parseRangeList(allocator: Allocator, list_str: []const u8) ![]Range {
    var ranges = std.ArrayListUnmanaged(Range).empty;
    defer ranges.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, list_str, ", ");
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " ");
        if (trimmed.len == 0) continue;
        try ranges.append(allocator, try parseRangeList_parseToken(trimmed));
    }

    if (ranges.items.len == 0) return error.InvalidRange;
    // Past the zero-range guard above, at least one range was parsed; this
    // documents the precondition for the unchecked `ranges.items[0]` index.
    assert(ranges.items.len >= 1);

    // Sort by start position
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.end < b.end;
        }
    }.lessThan);

    return parseRangeList_mergeSorted(allocator, ranges.items);
}

/// Check if a 1-indexed position is selected by the ranges
fn isSelected(ranges: []const Range, pos: usize, do_complement: bool) bool {
    // Positions are 1-indexed by contract; every production caller passes a
    // 1-based index (byte/char/field counters that start at 1).
    assert(pos >= 1);
    var selected = false;
    for (ranges) |r| {
        if (pos >= r.start and (r.end == Range.END or pos <= r.end)) {
            selected = true;
            break;
        }
        if (pos < r.start) break; // ranges are sorted
    }
    return if (do_complement) !selected else selected;
}

/// Return the number of bytes in the UTF-8 character starting at the given byte.
/// If the byte is a continuation byte or invalid, returns 1.
fn utf8CharLen(byte: u8) usize {
    if (byte < 0x80) return 1; // ASCII
    if (byte & 0xE0 == 0xC0) return 2; // 110xxxxx
    if (byte & 0xF0 == 0xE0) return 3; // 1110xxxx
    if (byte & 0xF8 == 0xF0) return 4; // 11110xxx
    return 1; // continuation byte or invalid
}

/// Cut bytes or characters from a line
fn cutBytesOrChars(
    line: []const u8,
    ranges: []const Range,
    do_complement: bool,
    no_split: bool,
    writer: anytype,
) !void {
    if (!no_split) {
        // Simple byte-by-byte selection
        var pos: usize = 1;
        for (line) |byte| {
            if (isSelected(ranges, pos, do_complement)) {
                try writer.writeAll(&.{byte});
            }
            pos += 1;
        }
        return;
    }

    // With -n: don't split multi-byte characters.
    // For each UTF-8 character, output it only if ALL its bytes are selected.
    var i: usize = 0;
    while (i < line.len) {
        const char_len = utf8CharLen(line[i]);
        // utf8CharLen's postcondition guarantees a length in 1..=4 for any byte.
        assert(char_len >= 1);
        // Clamp to remaining bytes
        const actual_len = @min(char_len, line.len - i);
        // The loop guard `i < line.len` makes `line.len - i >= 1`, and
        // char_len >= 1, so the clamp keeps the slice in bounds and the
        // step `i += actual_len` makes forward progress (never stalls).
        assert(i + actual_len <= line.len);
        assert(actual_len >= 1);

        // Check if all bytes of this character are selected
        var all_selected = true;
        for (0..actual_len) |offset| {
            const pos = i + offset + 1; // 1-indexed
            if (!isSelected(ranges, pos, do_complement)) {
                all_selected = false;
                break;
            }
        }

        if (all_selected) {
            try writer.writeAll(line[i .. i + actual_len]);
        }

        i += actual_len;
    }
}

/// Cut fields from a line
fn cutFields(
    line: []const u8,
    ranges: []const Range,
    do_complement: bool,
    delimiter: u8,
    output_delim: []const u8,
    only_delimited: bool,
    writer: anytype,
) !void {
    // Check if line contains delimiter
    if (std.mem.indexOfScalar(u8, line, delimiter) == null) {
        if (!only_delimited) {
            try writer.writeAll(line);
        }
        return;
    }

    var field_num: usize = 1;
    var first_output = true;
    var iter = std.mem.splitScalar(u8, line, delimiter);

    while (iter.next()) |field| {
        // field_num starts at 1 and only increments, so it is the 1-based
        // field index isSelected requires on every iteration.
        assert(field_num >= 1);
        if (isSelected(ranges, field_num, do_complement)) {
            if (!first_output) {
                try writer.writeAll(output_delim);
            }
            try writer.writeAll(field);
            first_output = false;
        }
        field_num += 1;
    }
}

/// Cut fields from a line using whitespace as delimiter.
/// Multiple consecutive whitespace characters count as a single delimiter.
/// Leading whitespace is skipped.
fn cutFieldsWhitespace(
    line: []const u8,
    ranges: []const Range,
    do_complement: bool,
    output_delim: []const u8,
    only_delimited: bool,
    writer: anytype,
) !void {
    // Check if line contains any whitespace
    var has_whitespace = false;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') {
            has_whitespace = true;
            break;
        }
    }

    if (!has_whitespace) {
        if (!only_delimited) {
            try writer.writeAll(line);
        }
        return;
    }

    // Tokenize by whitespace (spaces and tabs), which automatically
    // handles multiple consecutive delimiters and leading whitespace
    var field_num: usize = 1;
    var first_output = true;
    var iter = std.mem.tokenizeAny(u8, line, " \t");

    while (iter.next()) |field| {
        // field_num starts at 1 and only increments, so it is the 1-based
        // field index isSelected requires on every iteration.
        assert(field_num >= 1);
        if (isSelected(ranges, field_num, do_complement)) {
            if (!first_output) {
                try writer.writeAll(output_delim);
            }
            try writer.writeAll(field);
            first_output = false;
        }
        field_num += 1;
    }
}

/// Main entry point for cut utility
pub fn runCut(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parseOrExit(CutArgs, allocator, args, "cut", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return 0;
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return 0;
    }

    // Determine mode and validate mutual exclusivity
    const mode: CutMode = switch (runCut_resolveMode(allocator, stderr_writer, parsed)) {
        .exit => |code| return code,
        .mode => |m| m,
    };

    if (runCut_validateFlags(allocator, stderr_writer, parsed, mode)) |exit_code| {
        return exit_code;
    }

    // Parse the range list
    const list_str = parsed.bytes orelse parsed.characters orelse parsed.fields.?;
    const ranges = parseRangeList(allocator, list_str) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "invalid range: '{s}'", .{list_str}); // tiger:allow:long-line
        return @intFromEnum(common.ExitCode.misuse);
    };
    defer allocator.free(ranges);

    // Determine delimiters
    const delims = switch (runCut_resolveDelimiters(allocator, stderr_writer, parsed, mode)) {
        .exit => |code| return code,
        .delims => |d| d,
    };
    const delimiter = delims.delimiter;
    // Back the default output delimiter here so its slice does not dangle.
    const delim_storage = [1]u8{delimiter};
    const output_delim: []const u8 = delims.output_delim orelse delim_storage[0..];

    const line_terminator: u8 = if (parsed.zero_terminated) 0 else '\n';

    if (parsed.positionals.len == 0) {
        const stdin_file = std.Io.File.stdin();
        return runCut_processSource(allocator, io, stdin_file, ranges, mode, delimiter, output_delim, parsed.only_delimited, parsed.complement, parsed.no_split, parsed.whitespace_delim, line_terminator, stdout_writer, stderr_writer); // tiger:allow:long-line
    }

    var has_error = false;
    for (parsed.positionals) |file_path| {
        if (std.mem.eql(u8, file_path, "-")) {
            const stdin_file = std.Io.File.stdin();
            const result = runCut_processSource(allocator, io, stdin_file, ranges, mode, delimiter, output_delim, parsed.only_delimited, parsed.complement, parsed.no_split, parsed.whitespace_delim, line_terminator, stdout_writer, stderr_writer); // tiger:allow:long-line
            if (result > 0) has_error = true;
        } else {
            const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "{s}: {s}", .{ file_path, common.posixErrorString(err) }); // tiger:allow:long-line
                has_error = true;
                continue;
            };
            defer file.close(io);

            const result = runCut_processSource(allocator, io, file, ranges, mode, delimiter, output_delim, parsed.only_delimited, parsed.complement, parsed.no_split, parsed.whitespace_delim, line_terminator, stdout_writer, stderr_writer); // tiger:allow:long-line
            if (result > 0) has_error = true;
        }
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else 0;
}

/// Result of mode resolution: either an early-exit code or the resolved mode.
const RunCutModeResult = union(enum) {
    exit: u8,
    mode: CutMode,
};

/// Resolve the cut mode (bytes/characters/fields) and validate mutual
/// exclusivity. Single-caller helper for runCut; keeps branching in parent.
fn runCut_resolveMode(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    parsed: CutArgs,
) RunCutModeResult {
    var mode_count: u8 = 0;
    if (parsed.bytes != null) mode_count += 1;
    if (parsed.characters != null) mode_count += 1;
    if (parsed.fields != null) mode_count += 1;
    assert(mode_count <= 3);

    if (mode_count == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "you must specify a list of bytes, characters, or fields\nTry 'cut --help' for more information.", .{}); // tiger:allow:long-line
        return .{ .exit = @intFromEnum(common.ExitCode.misuse) };
    }

    if (mode_count > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "only one type of list may be specified\nTry 'cut --help' for more information.", .{}); // tiger:allow:long-line
        return .{ .exit = @intFromEnum(common.ExitCode.misuse) };
    }

    assert(mode_count == 1);
    const mode: CutMode = if (parsed.bytes != null)
        .bytes
    else if (parsed.characters != null)
        .characters
    else
        .fields;
    return .{ .mode = mode };
}

/// Validate flags that are only valid with field mode (-s, -d, -w) and the
/// -w/-d mutual exclusivity. Returns a misuse exit code, or null on success.
fn runCut_validateFlags(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    parsed: CutArgs,
    mode: CutMode,
) ?u8 {
    // mode is resolved upstream: exactly one of bytes/characters/fields is set.
    const mode_is_valid = mode == .bytes or mode == .characters or mode == .fields;
    assert(mode_is_valid);
    if (mode == .bytes) assert(parsed.characters == null);
    if (mode == .characters) assert(parsed.bytes == null);

    // -s is only valid with -f
    if (parsed.only_delimited and mode != .fields) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "suppressing non-delimited lines makes sense only when operating on fields\nTry 'cut --help' for more information.", .{}); // tiger:allow:long-line
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -d is only valid with -f
    if (parsed.delimiter != null and mode != .fields) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "an input delimiter may be specified only when operating on fields\nTry 'cut --help' for more information.", .{}); // tiger:allow:long-line
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -w is only valid with -f
    if (parsed.whitespace_delim and mode != .fields) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "-w may only be used with -f\nTry 'cut --help' for more information.", .{}); // tiger:allow:long-line
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -w and -d are mutually exclusive
    if (parsed.whitespace_delim and parsed.delimiter != null) {
        common.printErrorWithProgram(allocator, stderr_writer, "cut", "-w and -d may not both be specified\nTry 'cut --help' for more information.", .{}); // tiger:allow:long-line
        return @intFromEnum(common.ExitCode.misuse);
    }

    return null;
}

/// Resolved input/output delimiters for cut.
///
/// `output_delim` is null when the output delimiter defaults to the input
/// delimiter (field mode with no explicit -o/-w). The caller materializes the
/// single-char slice from `delimiter` in its OWN frame so the slice outlives
/// its use; building it here would dangle a pointer into this helper's stack.
const CutDelimiters = struct {
    delimiter: u8,
    output_delim: ?[]const u8,
};

/// Result of delimiter resolution: either an early-exit code or the delimiters.
const RunCutDelimitersResult = union(enum) {
    exit: u8,
    delims: CutDelimiters,
};

/// Determine the input delimiter (single-char validation) and the output
/// delimiter. Single-caller helper for runCut.
fn runCut_resolveDelimiters(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    parsed: CutArgs,
    mode: CutMode,
) RunCutDelimitersResult {
    // A custom delimiter is only valid in field mode; validated upstream.
    const mode_is_valid = mode == .bytes or mode == .characters or mode == .fields;
    assert(mode_is_valid);
    if (parsed.delimiter != null) assert(mode == .fields);

    // Determine delimiter
    const delimiter: u8 = if (parsed.delimiter) |d| blk: {
        if (d.len == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "cut", "the delimiter must be a single character", .{}); // tiger:allow:long-line
            return .{ .exit = @intFromEnum(common.ExitCode.misuse) };
        }
        if (d.len > 1) {
            common.printErrorWithProgram(allocator, stderr_writer, "cut", "the delimiter must be a single character", .{}); // tiger:allow:long-line
            return .{ .exit = @intFromEnum(common.ExitCode.misuse) };
        }
        break :blk d[0];
    } else '\t';

    // Determine output delimiter. null means "default to the input delimiter"
    // (field mode, no explicit -o/-w); the caller materializes that slice from
    // a stable frame to avoid returning a pointer into this helper's stack.
    const output_delim: ?[]const u8 = if (parsed.output_delimiter) |od|
        od
    else if (parsed.whitespace_delim)
        " "
    else switch (mode) {
        .fields => null,
        .bytes, .characters => "",
    };

    return .{ .delims = .{ .delimiter = delimiter, .output_delim = output_delim } };
}

/// Thin forwarder to processFile, used at each dispatch call site so runCut
/// stays within the function-length limit. Single-caller helper for runCut.
fn runCut_processSource(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    ranges: []const Range,
    mode: CutMode,
    delimiter: u8,
    output_delim: []const u8,
    only_delimited: bool,
    do_complement: bool,
    no_split: bool,
    whitespace_delim: bool,
    line_terminator: u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) u8 {
    const mode_is_valid = mode == .bytes or mode == .characters or mode == .fields;
    assert(mode_is_valid);
    const terminator_is_valid = line_terminator == '\n' or line_terminator == 0;
    assert(terminator_is_valid);
    return processFile(
        allocator,
        io,
        file,
        ranges,
        mode,
        delimiter,
        output_delim,
        only_delimited,
        do_complement,
        no_split,
        whitespace_delim,
        line_terminator,
        stdout_writer,
        stderr_writer,
    );
}

/// Process a single file/stream
fn processFile(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    ranges: []const Range,
    mode: CutMode,
    delimiter: u8,
    output_delim: []const u8,
    only_delimited: bool,
    do_complement: bool,
    no_split: bool,
    whitespace_delim: bool,
    line_terminator: u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) u8 {
    // mode is a CutMode resolved upstream to exactly one of three variants;
    // line_terminator is computed as exactly '\n' or 0 from the CLI.
    const mode_is_valid = mode == .bytes or mode == .characters or mode == .fields;
    assert(mode_is_valid);
    const terminator_is_valid = line_terminator == '\n' or line_terminator == 0;
    assert(terminator_is_valid);

    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    // Read line by line using the reader interface
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);

    while (true) {
        line_buf.clearRetainingCapacity();

        // Read until line terminator or EOF
        const eof = readLine(reader, &line_buf, allocator, line_terminator) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cut", "read error: {s}", .{common.posixErrorString(err)});
            return @intFromEnum(common.ExitCode.general_error);
        };

        if (eof and line_buf.items.len == 0) break;

        // Process the line; non-zero return propagates the error exit code.
        const rc = processFile_emitLine(
            allocator,
            line_buf.items,
            ranges,
            mode,
            delimiter,
            output_delim,
            only_delimited,
            do_complement,
            no_split,
            whitespace_delim,
            line_terminator,
            stdout_writer,
            stderr_writer,
        );
        if (rc != 0) return rc;

        if (eof) break;
    }

    return 0;
}

/// Emit a single processed line according to mode. Single-caller helper for
/// processFile. Returns 0 on success or ExitCode.general_error on a write
/// failure, matching the inline returns it replaces.
fn processFile_emitLine(
    allocator: Allocator,
    line: []const u8,
    ranges: []const Range,
    mode: CutMode,
    delimiter: u8,
    output_delim: []const u8,
    only_delimited: bool,
    do_complement: bool,
    no_split: bool,
    whitespace_delim: bool,
    line_terminator: u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) u8 {
    const mode_is_valid = mode == .bytes or mode == .characters or mode == .fields;
    assert(mode_is_valid);
    const terminator_is_valid = line_terminator == '\n' or line_terminator == 0;
    assert(terminator_is_valid);

    switch (mode) {
        .bytes, .characters => {
            cutBytesOrChars(line, ranges, do_complement, if (mode == .bytes) no_split else false, stdout_writer) catch |err| { // tiger:allow:long-line
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{common.posixErrorString(err)}); // tiger:allow:long-line
                return @intFromEnum(common.ExitCode.general_error);
            };
            stdout_writer.writeAll(&.{line_terminator}) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{common.posixErrorString(err)}); // tiger:allow:long-line
                return @intFromEnum(common.ExitCode.general_error);
            };
        },
        .fields => {
            if (whitespace_delim) {
                cutFieldsWhitespace(
                    line,
                    ranges,
                    do_complement,
                    output_delim,
                    only_delimited,
                    stdout_writer,
                ) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{common.posixErrorString(err)});
                    return @intFromEnum(common.ExitCode.general_error);
                };
                stdout_writer.writeAll(&.{line_terminator}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{common.posixErrorString(err)});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            } else {
                const line_has_delim = std.mem.indexOfScalar(u8, line, delimiter) != null;

                if (!line_has_delim and only_delimited) {
                    // Skip this line
                } else {
                    cutFields(
                        line,
                        ranges,
                        do_complement,
                        delimiter,
                        output_delim,
                        only_delimited,
                        stdout_writer,
                    ) catch |err| {
                        common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{common.posixErrorString(err)});
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    stdout_writer.writeAll(&.{line_terminator}) catch |err| {
                        common.printErrorWithProgram(allocator, stderr_writer, "cut", "write error: {s}", .{common.posixErrorString(err)});
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                }
            }
        },
    }

    return 0;
}

/// Read a line from reader into buffer, stopping at line_terminator.
/// Returns true if EOF was reached.
fn readLine(
    reader: anytype,
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    line_terminator: u8,
) !bool {
    // The only production caller is processFile, which passes exactly '\n' or 0.
    const terminator_is_valid = line_terminator == '\n' or line_terminator == 0;
    assert(terminator_is_valid);
    while (true) {
        const chunk = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return true,
            else => |e| return e,
        };

        if (chunk.len == 0) return true;

        // Look for line terminator in chunk
        if (std.mem.indexOfScalar(u8, chunk, line_terminator)) |pos| {
            // indexOfScalar returns an in-bounds index on a match, so the
            // `chunk[0..pos]` slice and `toss(pos + 1)` stay in bounds.
            assert(pos < chunk.len);
            // Append everything before the terminator
            try buf.appendSlice(allocator, chunk[0..pos]);
            reader.toss(pos + 1);
            return false;
        }

        // No terminator found, append entire chunk
        try buf.appendSlice(allocator, chunk);
        reader.toss(chunk.len);
    }
}

/// Main entry point for the cut command
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runCut);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: cut OPTION... [FILE]...
        \\Print selected parts of lines from each FILE to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --bytes=LIST        select only these bytes
        \\  -c, --characters=LIST   select only these characters
        \\  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter
        \\  -f, --fields=LIST       select only these fields; also print any line
        \\                            that contains no delimiter character, unless
        \\                            the -s option is specified
        \\  -s, --only-delimited    print only lines containing delimiters
        \\      --complement         complement the set of selected bytes, characters
        \\                            or fields
        \\      --output-delimiter=STRING  use STRING as the output delimiter;
        \\                            the default is to use the input delimiter
        \\  -z, --zero-terminated   line delimiter is NUL, not newline
        \\  -h, --help              display this help and exit
        \\  -V, --version           output version information and exit
        \\
        \\Use one, and only one, of -b, -c or -f.  Each LIST is made up of one
        \\range, or many ranges separated by commas.
        \\
        \\Each range is one of:
        \\  N     N'th byte, character or field, counted from 1
        \\  N-    from N'th byte, character or field, to end of line
        \\  N-M   from N'th to M'th byte, character or field
        \\  -M    from first to M'th byte, character or field
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("cut ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "cut --help shows help message" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: cut") != null);
}

test "cut --version shows version information" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "cut") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.version) != null);
}

test "cut no mode specified returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "you must specify") != null);
}

test "cut multiple modes returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", "1", "-f", "1" };
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "only one type") != null);
}

test "cut -s without -f returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", "1", "-s" };
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "suppressing") != null);
}

test "cut -d without -f returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", "1", "-d", ":" };
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "input delimiter") != null);
}

test "cut unknown flag returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") != null);
}

test "parseRangeList single value" {
    const ranges = try parseRangeList(testing.allocator, "3");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 3), ranges[0].start);
    try testing.expectEqual(@as(usize, 3), ranges[0].end);
}

test "parseRangeList multiple values" {
    const ranges = try parseRangeList(testing.allocator, "1,3,5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 3), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 3), ranges[1].start);
    try testing.expectEqual(@as(usize, 5), ranges[2].start);
}

test "parseRangeList range N-M" {
    const ranges = try parseRangeList(testing.allocator, "2-5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 2), ranges[0].start);
    try testing.expectEqual(@as(usize, 5), ranges[0].end);
}

test "parseRangeList range N-" {
    const ranges = try parseRangeList(testing.allocator, "3-");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 3), ranges[0].start);
    try testing.expectEqual(Range.END, ranges[0].end);
}

test "parseRangeList range -M" {
    const ranges = try parseRangeList(testing.allocator, "-5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 5), ranges[0].end);
}

test "parseRangeList complex list" {
    const ranges = try parseRangeList(testing.allocator, "1,3-5,7,10-");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 4), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 1), ranges[0].end);
    try testing.expectEqual(@as(usize, 3), ranges[1].start);
    try testing.expectEqual(@as(usize, 5), ranges[1].end);
    try testing.expectEqual(@as(usize, 7), ranges[2].start);
    try testing.expectEqual(@as(usize, 7), ranges[2].end);
    try testing.expectEqual(@as(usize, 10), ranges[3].start);
    try testing.expectEqual(Range.END, ranges[3].end);
}

test "parseRangeList overlapping ranges merge" {
    const ranges = try parseRangeList(testing.allocator, "1-3,2-5");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 5), ranges[0].end);
}

test "parseRangeList adjacent ranges merge" {
    const ranges = try parseRangeList(testing.allocator, "1-3,4-6");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 6), ranges[0].end);
}

test "parseRangeList unsorted ranges are sorted" {
    const ranges = try parseRangeList(testing.allocator, "5,1,3");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 3), ranges.len);
    try testing.expectEqual(@as(usize, 1), ranges[0].start);
    try testing.expectEqual(@as(usize, 3), ranges[1].start);
    try testing.expectEqual(@as(usize, 5), ranges[2].start);
}

test "parseRangeList zero value is invalid" {
    const result = parseRangeList(testing.allocator, "0");
    try testing.expectError(error.InvalidRange, result);
}

test "parseRangeList reversed range is invalid" {
    const result = parseRangeList(testing.allocator, "5-3");
    try testing.expectError(error.InvalidRange, result);
}

test "parseRangeList empty string is invalid" {
    const result = parseRangeList(testing.allocator, "");
    try testing.expectError(error.InvalidRange, result);
}

test "parseRangeList bare dash is invalid" {
    const result = parseRangeList(testing.allocator, "-");
    try testing.expectError(error.InvalidRange, result);
}

test "isSelected basic" {
    const ranges = try parseRangeList(testing.allocator, "1,3,5-7");
    defer testing.allocator.free(ranges);

    try testing.expect(isSelected(ranges, 1, false));
    try testing.expect(!isSelected(ranges, 2, false));
    try testing.expect(isSelected(ranges, 3, false));
    try testing.expect(!isSelected(ranges, 4, false));
    try testing.expect(isSelected(ranges, 5, false));
    try testing.expect(isSelected(ranges, 6, false));
    try testing.expect(isSelected(ranges, 7, false));
    try testing.expect(!isSelected(ranges, 8, false));
}

test "isSelected with complement" {
    const ranges = try parseRangeList(testing.allocator, "1,3");
    defer testing.allocator.free(ranges);

    try testing.expect(!isSelected(ranges, 1, true)); // complemented
    try testing.expect(isSelected(ranges, 2, true)); // complemented
    try testing.expect(!isSelected(ranges, 3, true)); // complemented
    try testing.expect(isSelected(ranges, 4, true)); // complemented
}

test "cutBytesOrChars single byte" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, false, false, &stdout_aw.writer);
    try testing.expectEqualStrings("a", stdout_aw.writer.buffered());
}

test "cutBytesOrChars range" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "2-4");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, false, false, &stdout_aw.writer);
    try testing.expectEqualStrings("bcd", stdout_aw.writer.buffered());
}

test "cutBytesOrChars multiple selections" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1,3,5");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, false, false, &stdout_aw.writer);
    try testing.expectEqualStrings("ace", stdout_aw.writer.buffered());
}

test "cutBytesOrChars complement" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "2,4");
    defer testing.allocator.free(ranges);

    try cutBytesOrChars("abcde", ranges, true, false, &stdout_aw.writer);
    try testing.expectEqualStrings("ace", stdout_aw.writer.buffered());
}

test "cutFields basic" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, false, '\t', "\t", false, &stdout_aw.writer);
    try testing.expectEqualStrings("one", stdout_aw.writer.buffered());
}

test "cutFields multiple fields" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1,3");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, false, '\t', "\t", false, &stdout_aw.writer);
    try testing.expectEqualStrings("one\tthree", stdout_aw.writer.buffered());
}

test "cutFields range" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "2-3");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree\tfour", ranges, false, '\t', "\t", false, &stdout_aw.writer);
    try testing.expectEqualStrings("two\tthree", stdout_aw.writer.buffered());
}

test "cutFields custom delimiter" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "2");
    defer testing.allocator.free(ranges);

    try cutFields("one:two:three", ranges, false, ':', ":", false, &stdout_aw.writer);
    try testing.expectEqualStrings("two", stdout_aw.writer.buffered());
}

test "cutFields no delimiter in line prints line" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFields("no delimiters here", ranges, false, '\t', "\t", false, &stdout_aw.writer);
    try testing.expectEqualStrings("no delimiters here", stdout_aw.writer.buffered());
}

test "cutFields no delimiter in line with -s suppresses output" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFields("no delimiters here", ranges, false, '\t', "\t", true, &stdout_aw.writer);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "cutFields complement" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "2");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, true, '\t', "\t", false, &stdout_aw.writer);
    try testing.expectEqualStrings("one\tthree", stdout_aw.writer.buffered());
}

test "cutFields output delimiter" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1,3");
    defer testing.allocator.free(ranges);

    try cutFields("one\ttwo\tthree", ranges, false, '\t', ",", false, &stdout_aw.writer);
    try testing.expectEqualStrings("one,three", stdout_aw.writer.buffered());
}

test "cut with file input bytes" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "abcde\nfghij\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-b", "1-3", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abc\nfgh\n", stdout_aw.writer.buffered());
}

test "cut with file input fields" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "one:two:three\nfour:five:six\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "2", "-d", ":", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("two\nfive\n", stdout_aw.writer.buffered());
}

test "cut nonexistent file returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", "1", "/nonexistent_test_file" };
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "nonexistent_test_file") != null);
}

// ============================================================================
//                          -n FLAG TESTS (RED PHASE)
// ============================================================================

test "cut: -n flag is accepted with -b" {
    // The -n flag should be accepted without error when used with -b.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "hello\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-b", "1-3", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hel\n", stdout_aw.writer.buffered());
}

test "cut: -n -b preserves multi-byte characters" {
    // Input "caf\xc3\xa9" is "cafe" with e-acute (2 bytes: 0xC3 0xA9).
    // "cafe" is 4 characters but 5 bytes.
    // With -b1-4 alone, bytes 1-4 are "caf\xc3" which splits the e-acute.
    // With -n -b1-4, the partial multi-byte character at byte 4 should be
    // excluded, producing "caf" (3 bytes).
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    // "cafe" with e-acute: c(0x63) a(0x61) f(0x66) e-acute(0xC3 0xA9)
    try test_file.writeStreamingAll(io, "caf\xc3\xa9\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-b", "1-4", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // With -n, partial multi-byte chars should be excluded.
    // Byte 4 is 0xC3 (first byte of 2-byte sequence), byte 5 is 0xA9.
    // Since only byte 4 is selected (not 5), the character is partial
    // and should be excluded entirely, giving "caf".
    try testing.expectEqualStrings("caf\n", stdout_aw.writer.buffered());
}

// ============================================================================
//                          -w FLAG TESTS
// ============================================================================

test "cut: -w splits on whitespace" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "one two three\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-w", "-f", "2", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("two\n", stdout_aw.writer.buffered());
}

test "cut: -w handles multiple consecutive spaces" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "one   two\t\tthree\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-w", "-f", "1,3", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("one three\n", stdout_aw.writer.buffered());
}

test "cut: -w skips leading whitespace" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "  leading space\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-w", "-f", "1", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("leading\n", stdout_aw.writer.buffered());
}

test "cut: -w with no whitespace prints whole line" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "nowhitespace\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-w", "-f", "1", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("nowhitespace\n", stdout_aw.writer.buffered());
}

test "cut: -w and -d are mutually exclusive" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-w", "-f", "1", "-d", ":" };
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "-w and -d") != null);
}

test "cut: -w without -f returns error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-w", "-b", "1" };
    const result = try runCut(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "-w may only be used with -f") != null);
}

test "cutFieldsWhitespace basic" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "2");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("one two three", ranges, false, " ", false, &stdout_aw.writer);
    try testing.expectEqualStrings("two", stdout_aw.writer.buffered());
}

test "cutFieldsWhitespace multiple spaces" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1-2");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("a    b    c", ranges, false, " ", false, &stdout_aw.writer);
    try testing.expectEqualStrings("a b", stdout_aw.writer.buffered());
}

test "cutFieldsWhitespace tabs and spaces" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "3");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("x\t y\t z", ranges, false, " ", false, &stdout_aw.writer);
    try testing.expectEqualStrings("z", stdout_aw.writer.buffered());
}

test "cutFieldsWhitespace no whitespace prints line" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("solid", ranges, false, " ", false, &stdout_aw.writer);
    try testing.expectEqualStrings("solid", stdout_aw.writer.buffered());
}

test "cutFieldsWhitespace no whitespace with -s suppresses" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    try cutFieldsWhitespace("solid", ranges, false, " ", true, &stdout_aw.writer);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "cut: -n without -b has no effect on field mode" {
    // -n only affects -b mode. When used with -f, it should have no
    // effect and the command should work normally.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try test_file.writeStreamingAll(io, "a,b,c\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const test_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-f", "1", "-d", ",", test_path };
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\n", stdout_aw.writer.buffered());
}

// ============================================================================
//                  processFile stderr diagnostic tests (RED)
// ============================================================================

test "cut --version output contains common.name" {
    // The version string must use common.name (not a hardcoded project name).
    // This ensures the output stays consistent if common.name ever changes.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runCut(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.name) != null);
}

test "cut: processFile reports read errors to stderr" {
    // Create a valid file, then close its handle so reads will fail.
    // processFile should write a diagnostic message to stderr.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile(io, "readable.txt", .{});
    try tmp_file.writeStreamingAll(io, "hello\n");
    // Close the handle to make subsequent reads fail
    tmp_file.close(io);

    // Create a File struct with the now-invalid handle
    const bad_file = std.Io.File{ .handle = tmp_file.handle, .flags = .{ .nonblocking = false } };

    const ranges = try parseRangeList(testing.allocator, "1");
    defer testing.allocator.free(ranges);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = processFile(
        testing.allocator,
        io,
        bad_file,
        ranges,
        .bytes,
        '\t',
        "\t",
        false,
        false,
        false,
        false,
        '\n',
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should return non-zero exit code
    try testing.expectEqual(@as(u8, 1), result);
    // Should have written a diagnostic message to stderr
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}
