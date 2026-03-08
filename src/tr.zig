//! tr - translate, squeeze, or delete characters
//!
//! Reads from standard input, translates characters according to
//! SET1 and SET2, and writes to standard output. Supports POSIX
//! character classes, ranges, escape sequences, and repetition.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

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
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .complement = .{ .short = 'c', .desc = "Use the complement of SET1" },
        .complement_c = .{ .short = 'C', .desc = "Use the complement of SET1" },
        .delete = .{ .short = 'd', .desc = "delete characters in SET1 without translating" },
        .squeeze_repeats = .{ .short = 's', .desc = "Replace each sequence of a repeated character that is listed in the last specified SET, with a single occurrence of that character" },
        .truncate_set1 = .{ .short = 't', .desc = "First truncate SET1 to length of SET2" },
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
    var result = std.ArrayListUnmanaged(u8){};
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
    var result = std.ArrayListUnmanaged(u8){};
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

    return result.toOwnedSlice(allocator);
}

/// Parse an equivalence class [=c=]. Returns the character.
fn parseEquivClass(str: []const u8, i: *usize) SetError!u8 {
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

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var c: u16 = 0;
    while (c < 256) : (c += 1) {
        if (!in_set[@intCast(c)]) {
            try result.append(allocator, @intCast(c));
        }
    }

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
        const s2_idx = if (idx < set2.len) idx else set2.len - 1;
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

    const exit_code = try runTr(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Run the tr utility with given arguments.
/// Public API that reads from stdin.
pub fn runTr(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parse(TrArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "unrecognized option\nTry 'tr --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "missing operand\nTry 'tr --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -d without -s requires only SET1
    // -d with -s requires SET1 and SET2
    // translate mode requires SET1 and SET2
    // -s alone requires at least SET1
    if (!parsed.delete and !parsed.squeeze_repeats and parsed.positionals.len < 2) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "missing operand after '{s}'\nTwo strings must be given when translating.", .{parsed.positionals[0]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    if (parsed.delete and parsed.squeeze_repeats and parsed.positionals.len < 2) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "missing operand after '{s}'\nTwo strings must be given when both deleting and squeezing.", .{parsed.positionals[0]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const stdin_file = std.fs.File.stdin();
    return runTrWithInput(allocator, parsed, stdin_file, stdout_writer, stderr_writer);
}

/// Internal function for running tr with a specific input file.
/// Allows testing with mock input streams.
fn runTrWithInput(
    allocator: Allocator,
    args: TrArgs,
    input_file: std.fs.File,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // Parse SET1
    const raw_set1 = parseSet(allocator, args.positionals[0]) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid SET1", .{});
        return @intFromEnum(common.ExitCode.misuse);
    };
    defer allocator.free(raw_set1);

    // Apply complement if requested
    var set1: []u8 = raw_set1;
    var comp_set1: ?[]u8 = null;
    if (args.isComplement()) {
        comp_set1 = complementSet(allocator, raw_set1) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "out of memory", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
        set1 = comp_set1.?;
    }
    defer if (comp_set1) |cs| allocator.free(cs);

    // Parse SET2 if provided
    var set2: []u8 = &.{};
    var set2_allocated = false;
    if (args.positionals.len > 1) {
        set2 = parseSet(allocator, args.positionals[1]) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid SET2", .{});
            return @intFromEnum(common.ExitCode.misuse);
        };
        set2_allocated = true;

        // Handle [c*] repetition: expand to match SET1 length
        // This was handled during parsing with count=0 sentinel.
        // We re-expand set2 if needed.
    }
    defer if (set2_allocated) allocator.free(set2);

    // Truncate set1 to length of set2 if -t is specified (translate mode)
    if (args.truncate_set1 and !args.delete and set2.len < set1.len) {
        set1 = set1[0..set2.len];
    }

    // Choose operation mode
    if (args.delete and args.squeeze_repeats) {
        // Delete SET1, then squeeze SET2
        return processDeleteSqueeze(input_file, stdout_writer, set1, set2);
    } else if (args.delete) {
        // Delete SET1
        return processDelete(input_file, stdout_writer, set1);
    } else if (args.squeeze_repeats and args.positionals.len < 2) {
        // Squeeze SET1 only (no translation)
        return processSqueeze(input_file, stdout_writer, set1);
    } else if (args.squeeze_repeats) {
        // Translate SET1->SET2 then squeeze SET2
        return processTranslateSqueeze(input_file, stdout_writer, set1, set2);
    } else {
        // Translate SET1->SET2
        return processTranslate(input_file, stdout_writer, set1, set2);
    }
}

/// Process: translate SET1 characters to SET2 characters.
fn processTranslate(
    input_file: std.fs.File,
    writer: anytype,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    const table = buildTranslationTable(set1, set2);
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = input_file.read(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
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
    input_file: std.fs.File,
    writer: anytype,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    const table = buildTranslationTable(set1, set2);
    const squeeze_set = buildSetMembership(set2);
    var buffer: [8192]u8 = undefined;
    var last_byte: ?u8 = null;

    while (true) {
        const bytes_read = input_file.read(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
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
    input_file: std.fs.File,
    writer: anytype,
    set1: []const u8,
) !u8 {
    const delete_set = buildSetMembership(set1);
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = input_file.read(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
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
    input_file: std.fs.File,
    writer: anytype,
    set1: []const u8,
    set2: []const u8,
) !u8 {
    const delete_set = buildSetMembership(set1);
    const squeeze_set = buildSetMembership(set2);
    var buffer: [8192]u8 = undefined;
    var last_byte: ?u8 = null;

    while (true) {
        const bytes_read = input_file.read(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
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
    input_file: std.fs.File,
    writer: anytype,
    set1: []const u8,
) !u8 {
    const squeeze_set = buildSetMembership(set1);
    var buffer: [8192]u8 = undefined;
    var last_byte: ?u8 = null;

    while (true) {
        const bytes_read = input_file.read(&buffer) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
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
fn printHelp(allocator: Allocator, writer: anytype) !void {
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
fn printVersion(writer: anytype) !void {
    try writer.print("tr ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "tr --help shows help message" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runTr(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: tr") != null);
}

test "tr --version shows version information" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runTr(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "tr") != null);
}

test "tr with no arguments returns misuse" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runTr(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "tr translate missing SET2 returns misuse" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"abc"};
    const result = try runTr(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "tr unknown flag returns misuse" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runTr(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create input file
    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("hello world");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .positionals = &.{ "aeiou", "AEIOU" },
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hEllO wOrld", stdout_buffer.items);
}

test "tr delete with mock input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("hello world");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .delete = true,
        .positionals = &.{"aeiou"},
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hll wrld", stdout_buffer.items);
}

test "tr squeeze with mock input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aabbccdd");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .squeeze_repeats = true,
        .positionals = &.{"abcd"},
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("abcd", stdout_buffer.items);
}

test "tr translate and squeeze with mock input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aabbbcc");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .squeeze_repeats = true,
        .positionals = &.{ "abc", "xyz" },
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("xyz", stdout_buffer.items);
}

test "tr delete and squeeze with mock input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("aabbbXXYcc");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .delete = true,
        .squeeze_repeats = true,
        .positionals = &.{ "abc", "XY" },
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("XY", stdout_buffer.items);
}

test "tr complement delete with mock input" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("hello123world");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .complement = true,
        .delete = true,
        .positionals = &.{"0-9"},
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("123", stdout_buffer.items);
}

test "tr case conversion upper to lower" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("HELLO WORLD");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .positionals = &.{ "[:upper:]", "[:lower:]" },
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world", stdout_buffer.items);
}

test "tr empty input produces empty output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("");
    try input_file.seekTo(0);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed = TrArgs{
        .positionals = &.{ "abc", "xyz" },
    };

    const result = try runTrWithInput(
        testing.allocator,
        parsed,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stdout_buffer.items);
}
