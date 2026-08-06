//! tr - translate, squeeze, or delete characters
//!
//! Reads from standard input, translates characters according to
//! SET1 and SET2, and writes to standard output. Supports POSIX
//! character classes, ranges, escape sequences, and repetition.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const prog_name = "tr";

/// Command-line arguments for tr
const TrArgs = struct {
    help: bool = false,
    version: bool = false,
    complement: bool = false,
    complement_c: bool = false,
    delete: bool = false,
    squeeze_repeats: bool = false,
    truncate_set1: bool = false,
    ignored_u: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .complement = .{ .short = 'c', .desc = "Use the complement of SET1" },
        .complement_c = .{ .short = 'C', .desc = "Use the complement of SET1" },
        .delete = .{ .short = 'd', .desc = "delete characters in SET1 without translating" },
        .squeeze_repeats = .{
            .short = 's',
            .desc = "Replace each sequence of a repeated character that is listed in the last " ++
                "specified SET, with a single occurrence of that character",
        },
        .truncate_set1 = .{ .short = 't', .desc = "First truncate SET1 to length of SET2" },
        .ignored_u = .{ .short = 'u', .desc = "Unbuffered output (no effect; for compatibility)" },
    };

    /// Returns true if either -c or -C was specified
    pub fn isComplement(self: TrArgs) bool {
        return self.complement or self.complement_c;
    }
};

/// Error types for set parsing
const SetError = error{
    InvalidRange,
    InvalidClass,
    InvalidEscape,
    InvalidRepeat,
    OutOfMemory,
};

/// Parse a character set string into a byte array.
/// Supports: literal chars, ranges (a-z), POSIX classes ([:alpha:]),
/// equivalence classes ([=c=]), repetitions ([c*n]), and escape sequences.
fn parseSet(allocator: Allocator, set_str: []const u8) SetError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < set_str.len) {
        // Check for backslash escape
        if (set_str[i] == '\\' and i + 1 < set_str.len) {
            const escaped = parseEscape(set_str, &i) catch |err| switch (err) {
                error.InvalidEscape => {
                    // Treat as literal backslash
                    try result.append(allocator, '\\');
                    i += 1;
                    continue;
                },
                else => return err,
            };
            try result.append(allocator, escaped);
            continue;
        }

        // Check for character class, equivalence class, or repetition: [...]
        if (set_str[i] == '[' and i + 1 < set_str.len) {
            if (set_str[i + 1] == ':') {
                // POSIX character class [:class:]
                const class_bytes = try parseCharClass(allocator, set_str, &i);
                defer allocator.free(class_bytes);
                try result.appendSlice(allocator, class_bytes);
                continue;
            } else if (set_str[i + 1] == '=') {
                // Equivalence class [=c=]
                const equiv_byte = try parseEquivClass(set_str, &i);
                try result.append(allocator, equiv_byte);
                continue;
            } else if (i + 3 < set_str.len) {
                // Check for repetition [c*n]
                if (parseRepeat(set_str, &i)) |repeat_result| {
                    for (0..repeat_result.count) |_| {
                        try result.append(allocator, repeat_result.char);
                    }
                    continue;
                }
            }
        }

        // Check for range: c-c
        if (i + 2 < set_str.len and set_str[i + 1] == '-') {
            const start = set_str[i];
            const end = set_str[i + 2];
            if (start <= end) {
                var c: u16 = start;
                while (c <= end) : (c += 1) {
                    try result.append(allocator, @intCast(c));
                }
                i += 3;
                continue;
            } else {
                return error.InvalidRange;
            }
        }

        // Literal character
        try result.append(allocator, set_str[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Parse a backslash escape sequence. Advances i past the escape.
fn parseEscape(str: []const u8, i: *usize) SetError!u8 {
    // Precondition: every reachable caller reads str[i.*] before any bound
    // check, so i.* must index within str.
    assert(i.* < str.len);
    if (str[i.*] != '\\' or i.* + 1 >= str.len) return error.InvalidEscape;

    const next = str[i.* + 1];
    const result: u8 = switch (next) {
        'a' => 0x07, // bell
        'b' => 0x08, // backspace
        'f' => 0x0C, // form feed
        'n' => 0x0A, // newline
        'r' => 0x0D, // carriage return
        't' => 0x09, // tab
        'v' => 0x0B, // vertical tab
        '\\' => '\\',
        '0'...'7' => blk: {
            // Octal escape: \NNN (1-3 octal digits)
            var val: u16 = 0;
            var count: usize = 0;
            var j = i.* + 1;
            while (j < str.len and count < 3) : (j += 1) {
                if (str[j] >= '0' and str[j] <= '7') {
                    val = val * 8 + (str[j] - '0');
                    count += 1;
                } else {
                    break;
                }
            }
            if (val > 255) return error.InvalidEscape;
            i.* = j;
            break :blk @intCast(val);
        },
        else => return error.InvalidEscape,
    };

    // For non-octal escapes, advance past the two characters
    if (next < '0' or next > '7') {
        i.* += 2;
    }

    return result;
}

/// Parse a POSIX character class like [:alpha:].
/// Returns an allocated slice of matching bytes.
fn parseCharClass(allocator: Allocator, str: []const u8, i: *usize) SetError![]u8 {
    // Precondition: the sole caller guards i + 1 < len before calling, so the
    // str[i.*] read in the next check is always in bounds.
    assert(i.* < str.len);
    // Must start with [:
    if (i.* + 2 >= str.len or str[i.*] != '[' or str[i.* + 1] != ':')
        return error.InvalidClass;

    // Find closing :]
    const start = i.* + 2;
    var end: usize = start;
    while (end + 1 < str.len) : (end += 1) {
        if (str[end] == ':' and str[end + 1] == ']') break;
    }
    if (end + 1 >= str.len or str[end] != ':' or str[end + 1] != ']')
        return error.InvalidClass;

    const class_name = str[start..end];
    i.* = end + 2; // past :]

    return expandClass(allocator, class_name);
}

/// Expand a named character class to all matching byte values.
fn expandClass(allocator: Allocator, class_name: []const u8) SetError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    if (std.mem.eql(u8, class_name, "upper")) {
        var c: u8 = 'A';
        while (c <= 'Z') : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "lower")) {
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "digit")) {
        var c: u8 = '0';
        while (c <= '9') : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "xdigit")) {
        var c: u8 = '0';
        while (c <= '9') : (c += 1) try result.append(allocator, c);
        c = 'A';
        while (c <= 'F') : (c += 1) try result.append(allocator, c);
        c = 'a';
        while (c <= 'f') : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "alpha")) {
        var c: u8 = 'A';
        while (c <= 'Z') : (c += 1) try result.append(allocator, c);
        c = 'a';
        while (c <= 'z') : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "alnum")) {
        var c: u8 = '0';
        while (c <= '9') : (c += 1) try result.append(allocator, c);
        c = 'A';
        while (c <= 'Z') : (c += 1) try result.append(allocator, c);
        c = 'a';
        while (c <= 'z') : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "space")) {
        for ([_]u8{ ' ', '\t', '\n', '\r', 0x0B, 0x0C }) |c| {
            try result.append(allocator, c);
        }
    } else if (std.mem.eql(u8, class_name, "blank")) {
        try result.append(allocator, ' ');
        try result.append(allocator, '\t');
    } else if (std.mem.eql(u8, class_name, "cntrl")) {
        var c: u16 = 0;
        while (c <= 31) : (c += 1) try result.append(allocator, @intCast(c));
        try result.append(allocator, 127);
    } else if (std.mem.eql(u8, class_name, "print")) {
        var c: u8 = 32;
        while (c <= 126) : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "graph")) {
        var c: u8 = 33;
        while (c <= 126) : (c += 1) try result.append(allocator, c);
    } else if (std.mem.eql(u8, class_name, "punct")) {
        var c: u16 = 33;
        while (c <= 126) : (c += 1) {
            const byte: u8 = @intCast(c);
            if (!std.ascii.isAlphanumeric(byte)) {
                try result.append(allocator, byte);
            }
        }
    } else {
        return error.InvalidClass;
    }

    // Postcondition: an unrecognized name returns error.InvalidClass above, so
    // reaching here means a matched branch appended at least one byte.
    assert(result.items.len > 0);
    return result.toOwnedSlice(allocator);
}

/// Parse an equivalence class [=c=]. Returns the character.
fn parseEquivClass(str: []const u8, i: *usize) SetError!u8 {
    // Precondition: the sole caller guards i + 1 < len before calling, so the
    // str[i.*] read after the length guard is always in bounds.
    assert(i.* < str.len);
    // Format: [=c=]
    if (i.* + 4 >= str.len) return error.InvalidClass;
    if (str[i.*] != '[' or str[i.* + 1] != '=') return error.InvalidClass;

    const ch = str[i.* + 2];

    if (str[i.* + 3] != '=' or str[i.* + 4] != ']') return error.InvalidClass;

    i.* += 5;
    return ch;
}

const RepeatResult = struct {
    char: u8,
    count: usize,
};

/// Try to parse a repetition [c*n]. Returns null if not a valid repetition.
fn parseRepeat(str: []const u8, i: *usize) ?RepeatResult {
    // Precondition: the sole caller guards i + 1 < len before calling, so the
    // str[i.*] read after the length guard is always in bounds.
    assert(i.* < str.len);
    // Format: [c*n] or [c*]
    if (i.* + 3 >= str.len) return null;
    if (str[i.*] != '[') return null;

    const ch = str[i.* + 1];
    if (str[i.* + 2] != '*') return null;

    // Find closing ]
    var j = i.* + 3;
    while (j < str.len and str[j] != ']') : (j += 1) {}
    if (j >= str.len) return null;

    // Parse count
    const count_str = str[i.* + 3 .. j];
    var count: usize = 0;
    if (count_str.len == 0) {
        // [c*] means fill to match SET1 length - use 0 as sentinel
        count = 0;
    } else if (count_str.len > 0 and count_str[0] == '0') {
        // Octal
        for (count_str) |c| {
            if (c < '0' or c > '7') return null;
            count = count * 8 + (c - '0');
        }
    } else {
        // Decimal
        for (count_str) |c| {
            if (c < '0' or c > '9') return null;
            count = count * 10 + (c - '0');
        }
    }

    i.* = j + 1;
    return .{ .char = ch, .count = count };
}

/// Build a complement of the given set: all byte values NOT in the set,
/// ordered by byte value.
fn complementSet(allocator: Allocator, set: []const u8) ![]u8 {
    var in_set = [_]bool{false} ** 256;
    for (set) |b| {
        in_set[b] = true;
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var c: u16 = 0;
    while (c < 256) : (c += 1) {
        if (!in_set[@intCast(c)]) {
            try result.append(allocator, @intCast(c));
        }
    }

    // Postcondition: the complement is a subset of the 256-value byte space, so
    // it can never exceed 256 entries (domain bound, not a type-width bound).
    assert(result.items.len <= 256);
    return result.toOwnedSlice(allocator);
}

/// Build a 256-byte translation table from set1 to set2.
/// Each index maps an input byte to its output byte.
fn buildTranslationTable(set1: []const u8, set2: []const u8) [256]u8 {
    var table: [256]u8 = undefined;
    // Initialize to identity mapping
    for (0..256) |c| {
        table[c] = @intCast(c);
    }

    if (set2.len == 0) return table;

    // Map each byte in set1 to corresponding byte in set2.
    // If set2 is shorter, the last character of set2 is used for
    // remaining set1 characters (GNU behavior).
    for (set1, 0..) |s1, idx| {
        // The set2.len == 0 early return above guarantees a non-empty set2
        // here, so the set2.len - 1 fallback below cannot underflow.
        assert(set2.len > 0);
        const s2_idx = if (idx < set2.len) idx else set2.len - 1;
        // s2_idx is either idx (< set2.len) or set2.len - 1 (< set2.len since
        // set2.len >= 1), so the set2[s2_idx] index is always valid.
        assert(s2_idx < set2.len);
        table[s1] = set2[s2_idx];
    }

    return table;
}

/// Build a boolean table for which bytes are in a set.
fn buildSetMembership(set: []const u8) [256]bool {
    var table = [_]bool{false} ** 256;
    for (set) |b| {
        table[b] = true;
    }
    return table;
}

/// Main entry point for tr utility
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTr);
}

/// Run the tr utility with given arguments.
/// Public API that reads from stdin.
pub fn runTr(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parseOrExit(
        TrArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate operand count
    if (parsed.positionals.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing operand\nTry 'tr --help' for more information.",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    // -d without -s requires only SET1
    // -d with -s requires SET1 and SET2
    // translate mode requires SET1 and SET2
    // -s alone requires at least SET1
    // The len == 0 block above returns, so any operand check below safely
    // indexes positionals[0].
    assert(parsed.positionals.len > 0);
    if (!parsed.delete and !parsed.squeeze_repeats and parsed.positionals.len < 2) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing operand after '{s}'\nTwo strings must be given when translating.",
            .{parsed.positionals[0]},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    if (parsed.delete and parsed.squeeze_repeats and parsed.positionals.len < 2) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing operand after '{s}'\nTwo strings must be given when both " ++
                "deleting and squeezing.",
            .{parsed.positionals[0]},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    return runTrWithInput(allocator, parsed, &stdin_reader.interface, stdout_writer, stderr_writer);
}

/// Scan a raw SET2 string for a fill repeat ([c*] or [c*0]).
/// Returns the fill character if found, or null if no fill repeat is present.
fn findFillChar(set_str: []const u8) ?u8 {
    var i: usize = 0;
    while (i < set_str.len) {
        // Skip backslash escapes
        if (set_str[i] == '\\' and i + 1 < set_str.len) {
            // Skip past the escape (simple: just advance 2)
            if (set_str[i + 1] >= '0' and set_str[i + 1] <= '7') {
                i += 2;
                while (i < set_str.len and set_str[i] >= '0' and set_str[i] <= '7') : (i += 1) {}
            } else {
                i += 2;
            }
            continue;
        }

        // Check for [c*] or [c*0] pattern
        if (set_str[i] == '[' and i + 3 < set_str.len and set_str[i + 2] == '*') {
            // Find closing ]
            var j = i + 3;
            while (j < set_str.len and set_str[j] != ']') : (j += 1) {}
            if (j < set_str.len) {
                const count_str = set_str[i + 3 .. j];
                // [c*] (empty count) or [c*0] (zero count) are fill markers
                if (count_str.len == 0) {
                    return set_str[i + 1];
                }
                // Check if count is zero (could be "0", "00", etc.)
                var is_zero = true;
                for (count_str) |c| {
                    if (c != '0') {
                        is_zero = false;
                        break;
                    }
                }
                if (is_zero) {
                    return set_str[i + 1];
                }
                // Non-zero repeat count, skip past it
                i = j + 1;
                continue;
            }
        }

        i += 1;
    }
    return null;
}

/// Result of building SET1: relocated from runTrWithInput so the parent keeps
/// ownership of both defers (free raw, free comp) and maps variants to exit
/// codes. On error the helper prints the identical message and returns the
/// variant; behavior is byte-for-byte the same as the inline original.
const RunTrWithInputBuildSet1Result = union(enum) {
    ok: struct { set1: []u8, raw: []u8, comp: ?[]u8 },
    set1_invalid,
    oom,
};

/// Parse SET1 and, when complementing, build its complement. Straight-line
/// relocation of the SET1 phase; the single isComplement() check is a
/// build-this-or-that selection, not control-flow dispatch, so it stays here.
fn runTrWithInput_buildSet1(
    allocator: Allocator,
    set1_str: []const u8,
    complement: bool,
    stderr_writer: *std.Io.Writer,
) RunTrWithInputBuildSet1Result {
    assert(prog_name.len > 0);

    const raw_set1 = parseSet(allocator, set1_str) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid SET1", .{});
        return .set1_invalid;
    };

    var set1: []u8 = raw_set1;
    var comp_set1: ?[]u8 = null;
    if (complement) {
        comp_set1 = complementSet(allocator, raw_set1) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "out of memory", .{});
            allocator.free(raw_set1);
            return .oom;
        };
        set1 = comp_set1.?;
    }

    // Positive space: complement path yields a comp slice; non-complement uses raw.
    // Negative space (else): a non-complement run never produces a comp slice.
    if (complement) {
        assert(comp_set1 != null);
        assert(set1.ptr == comp_set1.?.ptr);
    } else {
        assert(comp_set1 == null);
        assert(set1.ptr == raw_set1.ptr);
    }

    return .{ .ok = .{ .set1 = set1, .raw = raw_set1, .comp = comp_set1 } };
}

/// Result of the SET2 fill expansion: relocated so the parent keeps the single
/// `set2_allocated` defer covering the freed-and-replaced slice identically.
const RunTrWithInputExpandSet2FillResult = union(enum) {
    ok: []u8,
    oom,
};

/// Expand SET2 to SET1's length when a [c*] / [c*0] fill repeat is present.
/// Straight-line relocation of the fill block; returns set2 unchanged when no
/// fill char applies, or a fresh slice padded with the fill char otherwise.
fn runTrWithInput_expandSet2Fill(
    allocator: Allocator,
    set2: []u8,
    raw_set2: []const u8,
    set1_len: usize, // tiger:allow:usize-arch derived from set1.len (slice length is usize)
    stderr_writer: *std.Io.Writer,
) RunTrWithInputExpandSet2FillResult {
    assert(prog_name.len > 0);

    if (findFillChar(raw_set2)) |fill_ch| {
        if (set2.len < set1_len) {
            const needed = set1_len - set2.len;
            // Positive space: the fill path only runs when there is room to pad.
            assert(needed > 0);
            assert(set2.len < set1_len);
            const new_set2 = allocator.alloc(u8, set1_len) catch {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "out of memory",
                    .{},
                );
                return .oom;
            };
            @memcpy(new_set2[0..set2.len], set2);
            @memset(new_set2[set2.len .. set2.len + needed], fill_ch);
            allocator.free(set2);
            // Negative space: the result is never shorter than requested.
            assert(new_set2.len == set1_len);
            return .{ .ok = new_set2 };
        }
    }
    // No fill expansion: SET2 is returned unchanged. If a fill char was present
    // we only reach here when SET2 is already at least SET1's length.
    if (findFillChar(raw_set2) != null) {
        assert(set2.len >= set1_len);
    }
    return .{ .ok = set2 };
}

/// Result of acquiring SET2: parse the operand, then expand a [c*] / [c*0]
/// fill repeat to SET1's length. Relocated so the parent keeps the single
/// `set2_allocated` defer covering the freed-and-replaced slice identically.
const RunTrWithInputAcquireSet2Result = union(enum) {
    ok: []u8,
    set2_invalid,
    oom,
};

/// Acquire SET2: parse the operand into a set, then apply [c*] fill expansion
/// to match SET1's length. Straight-line relocation of the SET2 phase; the
/// branchy operation-mode dispatch stays in the parent (push ifs up).
fn runTrWithInput_acquireSet2(
    allocator: Allocator,
    set2_str: []const u8,
    raw_set2: []const u8,
    set1_len: usize, // tiger:allow:usize-arch derived from set1.len (slice length is usize)
    stderr_writer: *std.Io.Writer,
) RunTrWithInputAcquireSet2Result {
    // Positive space: the two views are the same operand (positionals[1]); the
    // dedup of parse vs fill-scan relies on this invariant.
    assert(set2_str.ptr == raw_set2.ptr);
    // Negative space: this helper never runs with an empty program name.
    assert(prog_name.len > 0);

    const parsed_set2 = parseSet(allocator, set2_str) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid SET2", .{});
        return .set2_invalid;
    };

    // Handle [c*] / [c*0] fill repetition: expand SET2 to match SET1 length.
    // On the fill-OOM path expandSet2Fill leaves parsed_set2 unfreed, so we own
    // it here and must free it before propagating .oom. This matches the
    // original, where the parent's set2_allocated defer (set true before the
    // fill call) freed exactly this buffer once. Freeing here keeps that single
    // free intact.
    const expanded = switch (runTrWithInput_expandSet2Fill(
        allocator,
        parsed_set2,
        raw_set2,
        set1_len,
        stderr_writer,
    )) {
        .ok => |e| e,
        .oom => {
            allocator.free(parsed_set2);
            return .oom;
        },
    };

    return .{ .ok = expanded };
}

/// Internal function for running tr with a specific input reader.
/// Allows testing with mock input streams.
fn runTrWithInput(
    allocator: Allocator,
    args: TrArgs,
    reader: *std.Io.Reader,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Precondition: callers guard len == 0, and the function unconditionally
    // reads positionals[0] below, so at least one operand is required.
    assert(args.positionals.len >= 1);

    // Check for extra operands
    const max_positionals: usize = if (args.delete and !args.squeeze_repeats) 1 else 2;
    if (args.positionals.len > max_positionals) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "extra operand '{s}'",
            .{args.positionals[max_positionals]},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }
    // Past the extra-operand guard, surplus operands have been rejected.
    assert(args.positionals.len <= max_positionals);

    // Parse SET1 (and its complement when requested).
    const set1_built = switch (runTrWithInput_buildSet1(
        allocator,
        args.positionals[0],
        args.isComplement(),
        stderr_writer,
    )) {
        .ok => |built| built,
        .set1_invalid => return @intFromEnum(common.ExitCode.general_error),
        .oom => return @intFromEnum(common.ExitCode.general_error),
    };
    var set1: []u8 = set1_built.set1;
    defer allocator.free(set1_built.raw);
    defer if (set1_built.comp) |cs| allocator.free(cs);

    // Parse SET2 if provided
    var set2: []u8 = &.{};
    var set2_allocated = false;
    if (args.positionals.len > 1) {
        set2 = switch (runTrWithInput_acquireSet2(
            allocator,
            args.positionals[1],
            args.positionals[1],
            set1.len,
            stderr_writer,
        )) {
            .ok => |s| s,
            .set2_invalid => return @intFromEnum(common.ExitCode.general_error),
            .oom => return @intFromEnum(common.ExitCode.general_error),
        };
        set2_allocated = true;
    }
    defer if (set2_allocated) allocator.free(set2);

    // Truncate set1 to length of set2 if -t is specified (translate mode)
    if (args.truncate_set1 and !args.delete and set2.len < set1.len) {
        set1 = set1[0..set2.len];
    }

    return runTrWithInput_dispatch(args, reader, stdout_writer, set1, set2);
}

/// Choose the operation mode and run it: delete, squeeze, translate, or the
/// combined delete+squeeze / translate+squeeze paths. Split from
/// runTrWithInput to keep that function within the 70-line limit.
fn runTrWithInput_dispatch(
    args: TrArgs,
    reader: *std.Io.Reader,
    stdout_writer: *std.Io.Writer,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    // Precondition: SET1 is always parsed before dispatch, so it is non-empty
    // unless the input set was empty; SET2 may be empty (delete/squeeze modes).
    assert(args.positionals.len >= 1);

    if (args.delete and args.squeeze_repeats) {
        // Delete SET1, then squeeze SET2
        return processDeleteSqueeze(reader, stdout_writer, set1, set2);
    } else if (args.delete) {
        // Delete SET1
        return processDelete(reader, stdout_writer, set1);
    } else if (args.squeeze_repeats and args.positionals.len < 2) {
        // Squeeze SET1 only (no translation)
        return processSqueeze(reader, stdout_writer, set1);
    } else if (args.squeeze_repeats) {
        // Translate SET1->SET2 then squeeze SET2
        return processTranslateSqueeze(reader, stdout_writer, set1, set2);
    } else {
        // Translate SET1->SET2
        return processTranslate(reader, stdout_writer, set1, set2);
    }
}

/// Process: translate SET1 characters to SET2 characters.
fn processTranslate(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    const table = buildTranslationTable(set1, set2);
    var buffer: [8192]u8 = undefined;

    while (true) { // tiger:allow:unbounded-loop reads until readSliceShort returns 0 (EOF)
        const bytes_read = reader.readSliceShort(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        // readSliceShort never returns more than the destination length, so the
        // buffer[0..bytes_read] slice below is always in bounds.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read]) |b| {
            writer.writeByte(table[b]) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Process: translate SET1->SET2 then squeeze repeated SET2 characters.
fn processTranslateSqueeze(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    const table = buildTranslationTable(set1, set2);
    const squeeze_set = buildSetMembership(set2);
    var buffer: [8192]u8 = undefined;
    var last_byte: ?u8 = null;

    while (true) { // tiger:allow:unbounded-loop reads until readSliceShort returns 0 (EOF)
        const bytes_read = reader.readSliceShort(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        // readSliceShort never returns more than the destination length, so the
        // buffer[0..bytes_read] slice below is always in bounds.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read]) |b| {
            const translated = table[b];
            // Squeeze: if this byte is in SET2 and same as previous, skip
            if (squeeze_set[translated] and last_byte != null and last_byte.? == translated) {
                continue;
            }
            writer.writeByte(translated) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };
            last_byte = translated;
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Process: delete characters in SET1.
fn processDelete(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    set1: []const u8,
) !u8 {
    const delete_set = buildSetMembership(set1);
    var buffer: [8192]u8 = undefined;

    while (true) { // tiger:allow:unbounded-loop reads until readSliceShort returns 0 (EOF)
        const bytes_read = reader.readSliceShort(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        // readSliceShort never returns more than the destination length, so the
        // buffer[0..bytes_read] slice below is always in bounds.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read]) |b| {
            if (!delete_set[b]) {
                writer.writeByte(b) catch {
                    return @intFromEnum(common.ExitCode.general_error);
                };
            }
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Process: delete SET1 then squeeze SET2.
fn processDeleteSqueeze(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    const delete_set = buildSetMembership(set1);
    const squeeze_set = buildSetMembership(set2);
    var buffer: [8192]u8 = undefined;
    var last_byte: ?u8 = null;

    while (true) { // tiger:allow:unbounded-loop reads until readSliceShort returns 0 (EOF)
        const bytes_read = reader.readSliceShort(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        // readSliceShort never returns more than the destination length, so the
        // buffer[0..bytes_read] slice below is always in bounds.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read]) |b| {
            // First: delete if in SET1
            if (delete_set[b]) continue;

            // Then: squeeze if in SET2 and same as last output
            if (squeeze_set[b] and last_byte != null and last_byte.? == b) {
                continue;
            }

            writer.writeByte(b) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };
            last_byte = b;
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Process: squeeze repeated characters in SET1 (no translation).
fn processSqueeze(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    set1: []const u8,
) !u8 {
    const squeeze_set = buildSetMembership(set1);
    var buffer: [8192]u8 = undefined;
    var last_byte: ?u8 = null;

    while (true) { // tiger:allow:unbounded-loop reads until readSliceShort returns 0 (EOF)
        const bytes_read = reader.readSliceShort(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        // readSliceShort never returns more than the destination length, so the
        // buffer[0..bytes_read] slice below is always in bounds.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read]) |b| {
            if (squeeze_set[b] and last_byte != null and last_byte.? == b) {
                continue;
            }
            writer.writeByte(b) catch {
                return @intFromEnum(common.ExitCode.general_error);
            };
            last_byte = b;
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: tr [OPTION]... SET1 [SET2]
        \\Translate, squeeze, or delete characters from standard input,
        \\writing to standard output.
        \\
        \\  -c, -C, --complement    use the complement of SET1
        \\  -d, --delete            delete characters in SET1 without translating
        \\  -s, --squeeze-repeats   replace each sequence of a repeated character
        \\                          that is listed in the last specified SET,
        \\                          with a single occurrence of that character
        \\  -t, --truncate-set1     first truncate SET1 to length of SET2
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\SETs are specified as strings of characters. Most represent themselves.
        \\Interpreted sequences:
        \\  \\NNN    character with octal value NNN (1 to 3 octal digits)
        \\  \\\\      backslash
        \\  \\a      audible BEL
        \\  \\b      backspace
        \\  \\f      form feed
        \\  \\n      new line
        \\  \\r      return
        \\  \\t      horizontal tab
        \\  \\v      vertical tab
        \\  CHAR1-CHAR2  all characters from CHAR1 to CHAR2 in ascending order
        \\  [:alnum:]    all letters and digits
        \\  [:alpha:]    all letters
        \\  [:blank:]    all horizontal whitespace
        \\  [:cntrl:]    all control characters
        \\  [:digit:]    all digits
        \\  [:graph:]    all printable characters, not including space
        \\  [:lower:]    all lower case letters
        \\  [:print:]    all printable characters, including space
        \\  [:punct:]    all punctuation characters
        \\  [:space:]    all horizontal or vertical whitespace
        \\  [:upper:]    all upper case letters
        \\  [:xdigit:]   all hexadecimal digits
        \\  [=CHAR=]     all characters which are equivalent to CHAR
        \\  [CHAR*]      in SET2, copies of CHAR until length of SET1
        \\  [CHAR*REPEAT]  REPEAT copies of CHAR, REPEAT octal if starting with 0
        \\
    );
}

/// Print version information
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("tr ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "tr --help shows help message" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runTr(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: tr") != null);
}

test "tr --version shows version information" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runTr(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "tr") != null);
}

test "tr with no arguments returns exit code 1" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runTr(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "tr translate missing SET2 returns exit code 1" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"abc"};
    const result = try runTr(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
}

test "tr -u flag is accepted and ignored" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .ignored_u = true,
        .positionals = &.{ "aeiou", "AEIOU" },
    };

    var reader: std.Io.Reader = .fixed("hello");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hEllO", stdout_aw.writer.buffered());
}

test "tr unknown flag returns exit code 1" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runTr(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
}

test "tr parseSet literal characters" {
    const set = try parseSet(testing.allocator, "abc");
    defer testing.allocator.free(set);
    try testing.expectEqualStrings("abc", set);
}

test "tr parseSet range" {
    const set = try parseSet(testing.allocator, "a-e");
    defer testing.allocator.free(set);
    try testing.expectEqualStrings("abcde", set);
}

test "tr parseSet digit range" {
    const set = try parseSet(testing.allocator, "0-9");
    defer testing.allocator.free(set);
    try testing.expectEqualStrings("0123456789", set);
}

test "tr parseSet escape sequences" {
    const set = try parseSet(testing.allocator, "\\n\\t\\\\");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 3), set.len);
    try testing.expectEqual(@as(u8, '\n'), set[0]);
    try testing.expectEqual(@as(u8, '\t'), set[1]);
    try testing.expectEqual(@as(u8, '\\'), set[2]);
}

test "tr parseSet octal escape" {
    const set = try parseSet(testing.allocator, "\\101");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 1), set.len);
    try testing.expectEqual(@as(u8, 'A'), set[0]); // 0o101 = 65 = 'A'
}

test "tr parseSet character class upper" {
    const set = try parseSet(testing.allocator, "[:upper:]");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 26), set.len);
    try testing.expectEqual(@as(u8, 'A'), set[0]);
    try testing.expectEqual(@as(u8, 'Z'), set[25]);
}

test "tr parseSet character class lower" {
    const set = try parseSet(testing.allocator, "[:lower:]");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 26), set.len);
    try testing.expectEqual(@as(u8, 'a'), set[0]);
    try testing.expectEqual(@as(u8, 'z'), set[25]);
}

test "tr parseSet character class digit" {
    const set = try parseSet(testing.allocator, "[:digit:]");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 10), set.len);
    try testing.expectEqualStrings("0123456789", set);
}

test "tr parseSet equivalence class" {
    const set = try parseSet(testing.allocator, "[=a=]");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 1), set.len);
    try testing.expectEqual(@as(u8, 'a'), set[0]);
}

test "tr parseSet repetition" {
    const set = try parseSet(testing.allocator, "[x*3]");
    defer testing.allocator.free(set);
    try testing.expectEqual(@as(usize, 3), set.len);
    try testing.expectEqualStrings("xxx", set);
}

test "tr parseSet mixed" {
    const set = try parseSet(testing.allocator, "a-cXY");
    defer testing.allocator.free(set);
    try testing.expectEqualStrings("abcXY", set);
}

test "tr parseSet invalid range returns error" {
    const result = parseSet(testing.allocator, "z-a");
    try testing.expectError(error.InvalidRange, result);
}

test "tr buildTranslationTable basic" {
    const table = buildTranslationTable("abc", "xyz");
    try testing.expectEqual(@as(u8, 'x'), table['a']);
    try testing.expectEqual(@as(u8, 'y'), table['b']);
    try testing.expectEqual(@as(u8, 'z'), table['c']);
    // Unmapped characters should be identity
    try testing.expectEqual(@as(u8, 'd'), table['d']);
}

test "tr buildTranslationTable set2 shorter extends last char" {
    const table = buildTranslationTable("abcd", "xy");
    try testing.expectEqual(@as(u8, 'x'), table['a']);
    try testing.expectEqual(@as(u8, 'y'), table['b']);
    try testing.expectEqual(@as(u8, 'y'), table['c']); // extends last
    try testing.expectEqual(@as(u8, 'y'), table['d']); // extends last
}

test "tr complementSet" {
    const set = try complementSet(testing.allocator, "ab");
    defer testing.allocator.free(set);
    // Should contain 254 bytes (256 - 2)
    try testing.expectEqual(@as(usize, 254), set.len);
    // Should not contain 'a' or 'b'
    for (set) |b| {
        try testing.expect(b != 'a');
        try testing.expect(b != 'b');
    }
}

test "tr buildSetMembership" {
    const membership = buildSetMembership("abc");
    try testing.expect(membership['a']);
    try testing.expect(membership['b']);
    try testing.expect(membership['c']);
    try testing.expect(!membership['d']);
    try testing.expect(!membership['z']);
}

test "tr translate with mock input" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "aeiou", "AEIOU" },
    };

    var reader: std.Io.Reader = .fixed("hello world");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hEllO wOrld", stdout_aw.writer.buffered());
}

test "tr delete with mock input" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .delete = true,
        .positionals = &.{"aeiou"},
    };

    var reader: std.Io.Reader = .fixed("hello world");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hll wrld", stdout_aw.writer.buffered());
}

test "tr squeeze with mock input" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .squeeze_repeats = true,
        .positionals = &.{"abcd"},
    };

    var reader: std.Io.Reader = .fixed("aabbccdd");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abcd", stdout_aw.writer.buffered());
}

test "tr translate and squeeze with mock input" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .squeeze_repeats = true,
        .positionals = &.{ "abc", "xyz" },
    };

    var reader: std.Io.Reader = .fixed("aabbbcc");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("xyz", stdout_aw.writer.buffered());
}

test "tr delete and squeeze with mock input" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .delete = true,
        .squeeze_repeats = true,
        .positionals = &.{ "abc", "XY" },
    };

    var reader: std.Io.Reader = .fixed("aabbbXXYcc");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("XY", stdout_aw.writer.buffered());
}

test "tr complement delete with mock input" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .complement = true,
        .delete = true,
        .positionals = &.{"0-9"},
    };

    var reader: std.Io.Reader = .fixed("hello123world");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("123", stdout_aw.writer.buffered());
}

test "tr case conversion upper to lower" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "[:upper:]", "[:lower:]" },
    };

    var reader: std.Io.Reader = .fixed("HELLO WORLD");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world", stdout_aw.writer.buffered());
}

test "tr empty input produces empty output" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "abc", "xyz" },
    };

    var reader: std.Io.Reader = .fixed("");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "tr [c*] fill-to-SET1-length translates all chars" {
    // GNU: printf 'abc' | tr 'abc' '[x*]' -> "xxx"
    // [x*] should expand to repeat 'x' to match the length of SET1
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "abc", "[x*]" },
    };

    var reader: std.Io.Reader = .fixed("abc");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("xxx", stdout_aw.writer.buffered());
}

test "tr [c*0] fill-to-SET1-length POSIX synonym" {
    // GNU: printf 'abc' | tr 'abc' '[x*0]' -> "xxx"
    // [x*0] is the POSIX synonym for [x*] (fill to match SET1 length)
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "abc", "[x*0]" },
    };

    var reader: std.Io.Reader = .fixed("abc");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("xxx", stdout_aw.writer.buffered());
}

test "tr [c*] fill with character class in SET1" {
    // GNU: printf 'HELLO' | tr '[:upper:]' '[x*]' -> "xxxxx"
    // [x*] should expand to match the full expanded length of [:upper:] (26 chars)
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "[:upper:]", "[x*]" },
    };

    var reader: std.Io.Reader = .fixed("HELLO");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("xxxxx", stdout_aw.writer.buffered());
}

test "tr [c*] fill with other chars before repeat in SET2" {
    // GNU: printf 'abcd' | tr 'abcd' 'y[x*]' -> "yxxx"
    // 'y' maps to 'a', then [x*] fills the remaining 3 positions
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "abcd", "y[x*]" },
    };

    var reader: std.Io.Reader = .fixed("abcd");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("yxxx", stdout_aw.writer.buffered());
}

test "tr extra operand returns exit code 1" {
    // GNU: tr a b c -> "tr: extra operand 'c'" on stderr, exit 1
    // Use runTrWithInput to avoid stdin hang (filter utility)
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "a", "b", "c" },
    };

    var reader: std.Io.Reader = .fixed("x");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        common.null_writer,
        &stderr_aw.writer,
    );

    // Must NOT be 0 — extra operands are an error
    try testing.expect(result != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "tr multiple extra operands returns exit code 1" {
    // tr a b c d -> should error on 'c' (the first extra operand)
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const parsed = TrArgs{
        .positionals = &.{ "a", "b", "c", "d" },
    };

    var reader: std.Io.Reader = .fixed("x");
    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        &reader,
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expect(result != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}
