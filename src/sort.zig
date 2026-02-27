//! sort - sort lines of text files
//!
//! Reads lines from files or stdin, sorts them, and writes
//! the result to stdout or a file. Supports numeric, dictionary,
//! case-insensitive, human-numeric, and key-based sorting.
//! POSIX-compliant with GNU extensions.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const prog_name = "sort";

/// Sort order options that can apply globally or per-key
const SortFlags = struct {
    ignore_leading_blanks: bool = false,
    dictionary_order: bool = false,
    ignore_case: bool = false,
    general_numeric_sort: bool = false,
    ignore_nonprinting: bool = false,
    numeric_sort: bool = false,
    reverse: bool = false,
    human_numeric_sort: bool = false,
};

/// A KEYDEF specifying a field range and per-key sort options
const KeyDef = struct {
    /// Start field (1-based)
    start_field: usize,
    /// Start character within field (1-based, 0 means whole field)
    start_char: usize = 0,
    /// End field (1-based, 0 means end of line)
    end_field: usize = 0,
    /// End character within field (1-based, 0 means end of field)
    end_char: usize = 0,
    /// Per-key sort flags (override global)
    flags: SortFlags = .{},
    /// Whether any flags were explicitly set on this key
    has_flags: bool = false,
};

/// Check mode
const CheckMode = enum {
    none,
    diagnose_first,
    quiet,
};

/// Parsed command-line options for sort
const SortOptions = struct {
    global_flags: SortFlags = .{},
    keys: std.ArrayListUnmanaged(KeyDef) = .{},
    field_separator: ?u8 = null,
    unique: bool = false,
    stable: bool = false,
    check: CheckMode = .none,
    output_file: ?[]const u8 = null,
    zero_terminated: bool = false,
    help: bool = false,
    version: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *SortOptions, allocator: Allocator) void {
        self.keys.deinit(allocator);
        self.files.deinit(allocator);
    }
};

/// Parse sort-specific command-line arguments
/// The standard argparse doesn't support repeated -k options or
/// --check=quiet syntax, so we do manual parsing here.
fn parseArgs(allocator: Allocator, args: []const []const u8, stderr_writer: anytype) !?SortOptions {
    var opts = SortOptions{};
    errdefer opts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is a file
            i += 1;
            while (i < args.len) : (i += 1) {
                try opts.files.append(allocator, args[i]);
            }
            break;
        }

        if (arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
            // Long option
            const flag = arg[2..];

            if (std.mem.eql(u8, flag, "help")) {
                opts.help = true;
            } else if (std.mem.eql(u8, flag, "version")) {
                opts.version = true;
            } else if (std.mem.eql(u8, flag, "ignore-leading-blanks")) {
                opts.global_flags.ignore_leading_blanks = true;
            } else if (std.mem.eql(u8, flag, "dictionary-order")) {
                opts.global_flags.dictionary_order = true;
            } else if (std.mem.eql(u8, flag, "ignore-case")) {
                opts.global_flags.ignore_case = true;
            } else if (std.mem.eql(u8, flag, "general-numeric-sort")) {
                opts.global_flags.general_numeric_sort = true;
            } else if (std.mem.eql(u8, flag, "ignore-nonprinting")) {
                opts.global_flags.ignore_nonprinting = true;
            } else if (std.mem.eql(u8, flag, "numeric-sort")) {
                opts.global_flags.numeric_sort = true;
            } else if (std.mem.eql(u8, flag, "reverse")) {
                opts.global_flags.reverse = true;
            } else if (std.mem.eql(u8, flag, "human-numeric-sort")) {
                opts.global_flags.human_numeric_sort = true;
            } else if (std.mem.eql(u8, flag, "unique")) {
                opts.unique = true;
            } else if (std.mem.eql(u8, flag, "stable")) {
                opts.stable = true;
            } else if (std.mem.eql(u8, flag, "zero-terminated")) {
                opts.zero_terminated = true;
            } else if (std.mem.eql(u8, flag, "check") or std.mem.eql(u8, flag, "check=diagnose-first")) {
                opts.check = .diagnose_first;
            } else if (std.mem.eql(u8, flag, "check=quiet") or std.mem.eql(u8, flag, "check=silent")) {
                opts.check = .quiet;
            } else if (std.mem.startsWith(u8, flag, "key=")) {
                const keydef_str = flag[4..];
                const key = parseKeyDef(keydef_str) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid key definition: '{s}'", .{keydef_str});
                    return null;
                };
                try opts.keys.append(allocator, key);
            } else if (std.mem.startsWith(u8, flag, "field-separator=")) {
                const sep_str = flag["field-separator=".len..];
                if (sep_str.len != 1) {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "multi-character field separator", .{});
                    return null;
                }
                opts.field_separator = sep_str[0];
            } else if (std.mem.startsWith(u8, flag, "output=")) {
                opts.output_file = flag["output=".len..];
            } else {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "unrecognized option '--{s}'\nTry 'sort --help' for more information.", .{flag});
                return null;
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            // Short options
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                switch (c) {
                    'b' => opts.global_flags.ignore_leading_blanks = true,
                    'd' => opts.global_flags.dictionary_order = true,
                    'f' => opts.global_flags.ignore_case = true,
                    'g' => opts.global_flags.general_numeric_sort = true,
                    'i' => opts.global_flags.ignore_nonprinting = true,
                    'n' => opts.global_flags.numeric_sort = true,
                    'r' => opts.global_flags.reverse = true,
                    'h' => opts.global_flags.human_numeric_sort = true,
                    'u' => opts.unique = true,
                    's' => opts.stable = true,
                    'c' => opts.check = .diagnose_first,
                    'C' => opts.check = .quiet,
                    'z' => opts.zero_terminated = true,
                    'V' => opts.version = true,
                    'k' => {
                        // -k takes a value: rest of this arg or next arg
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'k'", .{});
                            return null;
                        };
                        const key = parseKeyDef(value) catch {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid key definition: '{s}'", .{value});
                            return null;
                        };
                        try opts.keys.append(allocator, key);
                        break; // consumed rest of arg
                    },
                    't' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 't'", .{});
                            return null;
                        };
                        if (value.len != 1) {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "multi-character tab '{s}'", .{value});
                            return null;
                        }
                        opts.field_separator = value[0];
                        break;
                    },
                    'o' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'o'", .{});
                            return null;
                        };
                        opts.output_file = value;
                        break;
                    },
                    else => {
                        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid option -- '{c}'\nTry 'sort --help' for more information.", .{c});
                        return null;
                    },
                }
            }
        } else {
            // Positional argument (file)
            try opts.files.append(allocator, arg);
        }
    }

    return opts;
}

/// Parse a KEYDEF string: F[.C][OPTS][,F[.C][OPTS]]
fn parseKeyDef(keydef: []const u8) !KeyDef {
    var key = KeyDef{ .start_field = 0 };

    // Split on comma to get start and end parts
    const comma_pos = std.mem.indexOfScalar(u8, keydef, ',');
    const start_part = if (comma_pos) |pos| keydef[0..pos] else keydef;
    const end_part = if (comma_pos) |pos| keydef[pos + 1 ..] else null;

    // Parse start part: F[.C][OPTS]
    const start_result = parseFieldSpec(start_part) catch return error.InvalidKeyDef;
    key.start_field = start_result.field;
    key.start_char = start_result.char_pos;
    applyKeyFlags(&key.flags, start_result.opts);
    if (start_result.opts.len > 0) key.has_flags = true;

    if (key.start_field == 0) return error.InvalidKeyDef;

    // Parse end part if present
    if (end_part) |ep| {
        if (ep.len == 0) return error.InvalidKeyDef;
        const end_result = parseFieldSpec(ep) catch return error.InvalidKeyDef;
        key.end_field = end_result.field;
        key.end_char = end_result.char_pos;
        applyKeyFlags(&key.flags, end_result.opts);
        if (end_result.opts.len > 0) key.has_flags = true;
    }

    return key;
}

const FieldSpec = struct {
    field: usize,
    char_pos: usize,
    opts: []const u8,
};

/// Parse F[.C][OPTS] returning field, char position, and option chars
fn parseFieldSpec(spec: []const u8) !FieldSpec {
    var pos: usize = 0;

    // Parse field number
    const field_start = pos;
    while (pos < spec.len and std.ascii.isDigit(spec[pos])) : (pos += 1) {}
    if (pos == field_start) return error.InvalidFieldSpec;
    const field = std.fmt.parseInt(usize, spec[field_start..pos], 10) catch return error.InvalidFieldSpec;

    // Parse optional .C
    var char_pos: usize = 0;
    if (pos < spec.len and spec[pos] == '.') {
        pos += 1;
        const char_start = pos;
        while (pos < spec.len and std.ascii.isDigit(spec[pos])) : (pos += 1) {}
        if (pos == char_start) return error.InvalidFieldSpec;
        char_pos = std.fmt.parseInt(usize, spec[char_start..pos], 10) catch return error.InvalidFieldSpec;
    }

    // Rest is options
    const opts = spec[pos..];
    // Validate option chars
    for (opts) |c| {
        switch (c) {
            'b', 'd', 'f', 'i', 'n', 'r', 'h', 'g' => {},
            else => return error.InvalidFieldSpec,
        }
    }

    return FieldSpec{
        .field = field,
        .char_pos = char_pos,
        .opts = opts,
    };
}

/// Apply single-char options to SortFlags
fn applyKeyFlags(flags: *SortFlags, opts: []const u8) void {
    for (opts) |c| {
        switch (c) {
            'b' => flags.ignore_leading_blanks = true,
            'd' => flags.dictionary_order = true,
            'f' => flags.ignore_case = true,
            'g' => flags.general_numeric_sort = true,
            'i' => flags.ignore_nonprinting = true,
            'n' => flags.numeric_sort = true,
            'r' => flags.reverse = true,
            'h' => flags.human_numeric_sort = true,
            else => {},
        }
    }
}

/// Main entry point
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runSort(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Public entry point for the sort utility
pub fn runSort(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    var opts = (try parseArgs(allocator, args, stderr_writer)) orelse
        return @intFromEnum(common.ExitCode.misuse);
    defer opts.deinit(allocator);

    if (opts.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Read all lines from files or stdin
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    const delimiter: u8 = if (opts.zero_terminated) 0 else '\n';

    if (opts.files.items.len == 0) {
        // Read from stdin
        const stdin_file = std.fs.File.stdin();
        try readLines(allocator, stdin_file, &lines, delimiter);
    } else {
        for (opts.files.items) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                const stdin_file = std.fs.File.stdin();
                try readLines(allocator, stdin_file, &lines, delimiter);
            } else {
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot read: {s}: {s}", .{ file_path, @errorName(err) });
                    return @intFromEnum(common.ExitCode.misuse);
                };
                defer file.close();
                try readLines(allocator, file, &lines, delimiter);
            }
        }
    }

    // Check mode: verify if input is already sorted
    if (opts.check != .none) {
        return checkSorted(allocator, lines.items, &opts, stdout_writer, stderr_writer);
    }

    // Sort the lines
    const sort_ctx = SortContext{
        .opts = &opts,
        .allocator = allocator,
    };
    std.mem.sort([]const u8, lines.items, sort_ctx, compareLinesWrapper);

    // Determine output target
    if (opts.output_file) |out_path| {
        const out_file = std.fs.cwd().createFile(out_path, .{ .truncate = true }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "open failed: {s}: {s}", .{ out_path, @errorName(err) });
            return @intFromEnum(common.ExitCode.misuse);
        };
        defer out_file.close();
        var out_buffer: [8192]u8 = undefined;
        var file_writer = out_file.writer(&out_buffer);
        const out_writer = &file_writer.interface;
        try writeLines(out_writer, lines.items, &opts, delimiter);
        out_writer.flush() catch {};
    } else {
        try writeLines(stdout_writer, lines.items, &opts, delimiter);
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Read lines from a file into the lines list
fn readLines(allocator: Allocator, file: std.fs.File, lines: *std.ArrayListUnmanaged([]const u8), delimiter: u8) !void {
    const content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    if (content.len == 0) return;

    // Split by delimiter
    var start: usize = 0;
    for (content, 0..) |c, idx| {
        if (c == delimiter) {
            try lines.append(allocator, content[start..idx]);
            start = idx + 1;
        }
    }
    // Handle trailing content without final delimiter
    if (start < content.len) {
        try lines.append(allocator, content[start..]);
    }
}

/// Context passed to the sort comparator
const SortContext = struct {
    opts: *const SortOptions,
    allocator: Allocator,
};

/// Wrapper for std.mem.sort that matches expected signature
fn compareLinesWrapper(ctx: SortContext, a: []const u8, b: []const u8) bool {
    return compareLines(ctx, a, b);
}

/// Compare two lines according to sort options
fn compareLines(ctx: SortContext, a: []const u8, b: []const u8) bool {
    const opts = ctx.opts;

    if (opts.keys.items.len > 0) {
        // Compare using key definitions
        for (opts.keys.items) |key| {
            const flags = if (key.has_flags) key.flags else opts.global_flags;
            const a_key = extractKey(a, key, opts.field_separator);
            const b_key = extractKey(b, key, opts.field_separator);
            const result = compareWithFlags(a_key, b_key, flags);
            if (result != .eq) {
                const is_less = result == .lt;
                return if (flags.reverse) !is_less else is_less;
            }
        }
        // All keys equal - fall through to equal
        return false;
    } else {
        // Compare whole lines with global flags
        const result = compareWithFlags(a, b, opts.global_flags);
        if (result != .eq) {
            const is_less = result == .lt;
            return if (opts.global_flags.reverse) !is_less else is_less;
        }
        return false;
    }
}

/// Extract the key portion of a line based on a KeyDef
fn extractKey(line: []const u8, key: KeyDef, separator: ?u8) []const u8 {
    const fields = splitFields(line, separator);

    // Get start position
    if (key.start_field == 0 or key.start_field > fields.len) return "";
    const start_field_content = fields[key.start_field - 1];

    if (key.end_field == 0 and key.start_char == 0) {
        // Simple case: just one field, no character offsets, to end of line
        if (key.start_field <= fields.len) {
            // From start_field to end of line
            const start_offset = fieldOffset(line, fields, key.start_field - 1);
            return line[start_offset..];
        }
        return "";
    }

    // Calculate start byte offset
    var start_byte: usize = fieldOffset(line, fields, key.start_field - 1);
    if (key.start_char > 0) {
        const char_offset = @min(key.start_char - 1, start_field_content.len);
        start_byte += char_offset;
    }

    // Calculate end byte offset
    var end_byte: usize = line.len;
    if (key.end_field > 0 and key.end_field <= fields.len) {
        const end_field_content = fields[key.end_field - 1];
        end_byte = fieldOffset(line, fields, key.end_field - 1);
        if (key.end_char > 0) {
            end_byte += @min(key.end_char, end_field_content.len);
        } else {
            end_byte += end_field_content.len;
        }
    }

    if (start_byte >= line.len) return "";
    end_byte = @min(end_byte, line.len);
    if (start_byte >= end_byte) return "";

    return line[start_byte..end_byte];
}

/// Temporary field storage to avoid allocations in hot path.
/// Max 256 fields per line should be sufficient.
const MAX_FIELDS = 256;

/// Split a line into fields, returning slices into the original line.
/// Uses a static buffer to avoid allocation.
fn splitFields(line: []const u8, separator: ?u8) []const []const u8 {
    const S = struct {
        threadlocal var fields: [MAX_FIELDS][]const u8 = undefined;
    };
    var count: usize = 0;

    if (separator) |sep| {
        // Explicit separator: fields are between separators
        var start: usize = 0;
        for (line, 0..) |c, idx| {
            if (c == sep) {
                if (count < MAX_FIELDS) {
                    S.fields[count] = line[start..idx];
                    count += 1;
                }
                start = idx + 1;
            }
        }
        if (count < MAX_FIELDS) {
            S.fields[count] = line[start..];
            count += 1;
        }
    } else {
        // Default: fields separated by runs of blanks
        var in_field = false;
        var start: usize = 0;
        for (line, 0..) |c, idx| {
            const is_blank = (c == ' ' or c == '\t');
            if (!is_blank and !in_field) {
                start = idx;
                in_field = true;
            } else if (is_blank and in_field) {
                if (count < MAX_FIELDS) {
                    S.fields[count] = line[start..idx];
                    count += 1;
                }
                in_field = false;
            }
        }
        if (in_field and count < MAX_FIELDS) {
            S.fields[count] = line[start..];
            count += 1;
        }
    }

    return S.fields[0..count];
}

/// Get byte offset of the start of field N in line
fn fieldOffset(line: []const u8, fields: []const []const u8, field_idx: usize) usize {
    if (field_idx >= fields.len) return line.len;
    const field_ptr = fields[field_idx].ptr;
    const line_ptr = line.ptr;
    return @intFromPtr(field_ptr) - @intFromPtr(line_ptr);
}

/// Compare two strings according to sort flags, returning ordering
fn compareWithFlags(a: []const u8, b: []const u8, flags: SortFlags) std.math.Order {
    // Numeric sort modes
    if (flags.human_numeric_sort) {
        return compareHumanNumeric(a, b);
    }
    if (flags.general_numeric_sort) {
        return compareGeneralNumeric(a, b);
    }
    if (flags.numeric_sort) {
        return compareNumeric(a, b);
    }

    // Text comparison modes
    var a_str = a;
    var b_str = b;

    if (flags.ignore_leading_blanks) {
        a_str = stripLeadingBlanks(a_str);
        b_str = stripLeadingBlanks(b_str);
    }

    if (flags.dictionary_order) {
        return compareDictionary(a_str, b_str, flags.ignore_case);
    }

    if (flags.ignore_nonprinting) {
        return comparePrintable(a_str, b_str, flags.ignore_case);
    }

    if (flags.ignore_case) {
        return compareCaseInsensitive(a_str, b_str);
    }

    // Default: byte-by-byte comparison
    return std.mem.order(u8, a_str, b_str);
}

fn stripLeadingBlanks(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

/// Case-insensitive comparison
fn compareCaseInsensitive(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ac, bc| {
        const al = std.ascii.toLower(ac);
        const bl = std.ascii.toLower(bc);
        if (al < bl) return .lt;
        if (al > bl) return .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Dictionary order: compare only blanks and alphanumeric characters
fn compareDictionary(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;

    while (true) {
        // Skip non-dict chars in a
        while (ai < a.len and !isDictChar(a[ai])) : (ai += 1) {}
        // Skip non-dict chars in b
        while (bi < b.len and !isDictChar(b[bi])) : (bi += 1) {}

        if (ai >= a.len or bi >= b.len) break;

        var ac = a[ai];
        var bc = b[bi];
        if (ignore_case) {
            ac = std.ascii.toLower(ac);
            bc = std.ascii.toLower(bc);
        }
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
        ai += 1;
        bi += 1;
    }

    // One or both exhausted
    const a_remaining = countDictChars(a[ai..]);
    const b_remaining = countDictChars(b[bi..]);
    return std.math.order(a_remaining, b_remaining);
}

fn isDictChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ' ' or c == '\t';
}

fn countDictChars(s: []const u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (isDictChar(c)) count += 1;
    }
    return count;
}

/// Compare considering only printable characters
fn comparePrintable(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;

    while (true) {
        while (ai < a.len and !std.ascii.isPrint(a[ai])) : (ai += 1) {}
        while (bi < b.len and !std.ascii.isPrint(b[bi])) : (bi += 1) {}

        if (ai >= a.len or bi >= b.len) break;

        var ac = a[ai];
        var bc = b[bi];
        if (ignore_case) {
            ac = std.ascii.toLower(ac);
            bc = std.ascii.toLower(bc);
        }
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
        ai += 1;
        bi += 1;
    }

    const a_remaining = countPrintChars(a[ai..]);
    const b_remaining = countPrintChars(b[bi..]);
    return std.math.order(a_remaining, b_remaining);
}

fn countPrintChars(s: []const u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (std.ascii.isPrint(c)) count += 1;
    }
    return count;
}

/// Numeric sort: compare leading numeric values
fn compareNumeric(a: []const u8, b: []const u8) std.math.Order {
    const a_val = parseLeadingNumber(a);
    const b_val = parseLeadingNumber(b);
    if (a_val < b_val) return .lt;
    if (a_val > b_val) return .gt;
    return .eq;
}

/// Parse a leading number from a string (handles sign, leading whitespace)
fn parseLeadingNumber(s: []const u8) f64 {
    var i: usize = 0;
    // Skip leading whitespace
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return 0;

    var negative = false;
    if (s[i] == '-') {
        negative = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }

    // Skip leading zeros
    var result: f64 = 0;
    var has_digits = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        result = result * 10 + @as(f64, @floatFromInt(s[i] - '0'));
        has_digits = true;
    }

    // Decimal part
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            result += @as(f64, @floatFromInt(s[i] - '0')) * frac;
            frac *= 0.1;
            has_digits = true;
        }
    }

    if (!has_digits) return 0;
    return if (negative) -result else result;
}

/// General numeric sort: parse as float (handles scientific notation)
fn compareGeneralNumeric(a: []const u8, b: []const u8) std.math.Order {
    const a_val = parseGeneralNumber(a);
    const b_val = parseGeneralNumber(b);
    // NaN handling: NaN sorts before everything
    const a_nan = std.math.isNan(a_val);
    const b_nan = std.math.isNan(b_val);
    if (a_nan and b_nan) return .eq;
    if (a_nan) return .lt;
    if (b_nan) return .gt;
    if (a_val < b_val) return .lt;
    if (a_val > b_val) return .gt;
    return .eq;
}

fn parseGeneralNumber(s: []const u8) f64 {
    // Trim leading whitespace
    var trimmed = s;
    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
    trimmed = trimmed[i..];
    if (trimmed.len == 0) return std.math.nan(f64);

    // Find end of number (digits, sign, dot, e/E)
    var end: usize = 0;
    if (end < trimmed.len and (trimmed[end] == '-' or trimmed[end] == '+')) end += 1;
    while (end < trimmed.len and (std.ascii.isDigit(trimmed[end]) or trimmed[end] == '.')) : (end += 1) {}
    if (end < trimmed.len and (trimmed[end] == 'e' or trimmed[end] == 'E')) {
        end += 1;
        if (end < trimmed.len and (trimmed[end] == '-' or trimmed[end] == '+')) end += 1;
        while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
    }

    if (end == 0) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, trimmed[0..end]) catch std.math.nan(f64);
}

/// Human-numeric sort: compare numbers with SI suffixes (K, M, G, T, etc.)
fn compareHumanNumeric(a: []const u8, b: []const u8) std.math.Order {
    const a_val = parseHumanNumber(a);
    const b_val = parseHumanNumber(b);
    if (a_val < b_val) return .lt;
    if (a_val > b_val) return .gt;
    return .eq;
}

fn parseHumanNumber(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return 0;

    var negative = false;
    if (s[i] == '-') {
        negative = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }

    var result: f64 = 0;
    var has_digits = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        result = result * 10 + @as(f64, @floatFromInt(s[i] - '0'));
        has_digits = true;
    }

    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            result += @as(f64, @floatFromInt(s[i] - '0')) * frac;
            frac *= 0.1;
            has_digits = true;
        }
    }

    if (!has_digits) return 0;

    // Check for SI suffix
    if (i < s.len) {
        const multiplier: f64 = switch (s[i]) {
            'K', 'k' => 1024,
            'M' => 1024 * 1024,
            'G' => 1024 * 1024 * 1024,
            'T' => 1024.0 * 1024.0 * 1024.0 * 1024.0,
            'P' => 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0,
            'E' => 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0,
            else => 1,
        };
        result *= multiplier;
    }

    return if (negative) -result else result;
}

/// Check if input is already sorted
fn checkSorted(allocator: Allocator, lines: []const []const u8, opts: *const SortOptions, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = stdout_writer;
    if (lines.len <= 1) return @intFromEnum(common.ExitCode.success);

    const ctx = SortContext{
        .opts = opts,
        .allocator = allocator,
    };

    var prev = lines[0];
    for (lines[1..], 0..) |line, idx| {
        const wrong_order = compareLines(ctx, line, prev);
        const is_dup = std.mem.eql(u8, line, prev);

        if (wrong_order or (opts.unique and is_dup)) {
            if (opts.check == .diagnose_first) {
                // Get the first file name for the message
                const file_name = if (opts.files.items.len > 0) opts.files.items[0] else "-";
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}:{d}: disorder: {s}", .{ file_name, idx + 2, line });
            }
            return @intFromEnum(common.ExitCode.general_error);
        }
        prev = line;
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Write sorted lines to output, handling unique filtering
fn writeLines(writer: anytype, lines: []const []const u8, opts: *const SortOptions, delimiter: u8) !void {
    const delim_slice: [1]u8 = .{delimiter};

    if (opts.unique) {
        var prev: ?[]const u8 = null;
        for (lines) |line| {
            const is_dup = if (prev) |p| linesEqual(p, line, opts) else false;
            if (!is_dup) {
                try writer.writeAll(line);
                try writer.writeAll(&delim_slice);
                prev = line;
            }
        }
    } else {
        for (lines) |line| {
            try writer.writeAll(line);
            try writer.writeAll(&delim_slice);
        }
    }
}

/// Check if two lines are equal for -u purposes (using sort key comparison)
fn linesEqual(a: []const u8, b: []const u8, opts: *const SortOptions) bool {
    const ctx = SortContext{
        .opts = opts,
        .allocator = undefined,
    };
    // If neither a < b nor b < a, they are equal
    return !compareLines(ctx, a, b) and !compareLines(ctx, b, a);
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: sort [OPTION]... [FILE]...
        \\Write sorted concatenation of all FILE(s) to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Ordering options:
        \\  -b, --ignore-leading-blanks  ignore leading blanks
        \\  -d, --dictionary-order       consider only blanks and alphanumeric characters
        \\  -f, --ignore-case            fold lower case to upper case characters
        \\  -g, --general-numeric-sort   compare according to general numeric value
        \\  -i, --ignore-nonprinting     consider only printable characters
        \\  -n, --numeric-sort           compare according to string numerical value
        \\  -r, --reverse                reverse the result of comparisons
        \\  -h, --human-numeric-sort     compare human readable numbers (e.g., 2K 1G)
        \\
        \\Other options:
        \\  -k KEYDEF, --key=KEYDEF      sort via a key; KEYDEF gives location and type
        \\  -t CHAR, --field-separator=CHAR  use CHAR as the field separator
        \\  -u, --unique                 with -c, check for strict ordering;
        \\                                 without -c, output only the first of an equal run
        \\  -s, --stable                 stabilize sort by disabling last-resort comparison
        \\  -c, --check, --check=diagnose-first  check for sorted input; do not sort
        \\  -C, --check=quiet, --check=silent  like -c, but do not report first bad line
        \\  -o FILE, --output=FILE       write result to FILE instead of standard output
        \\  -z, --zero-terminated        line delimiter is NUL, not newline
        \\      --help                   display this help and exit
        \\  -V, --version                output version information and exit
        \\
        \\KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a
        \\field number and C a character position (numbered from 1); both are origin 1.
        \\OPTS is one or more single-letter ordering options [bdfginrh], which override
        \\global ordering options for that key.
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("sort ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "sort --help shows help message" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runSort(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: sort") != null);
}

test "sort --version shows version" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runSort(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "sort") != null);
}

test "sort -V shows version" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = try runSort(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "sort") != null);
}

test "sort unknown flag returns misuse" {
    var stderr_buf = std.ArrayListUnmanaged(u8){};
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runSort(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "sort invalid short flag returns misuse" {
    var stderr_buf = std.ArrayListUnmanaged(u8){};
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-x"};
    const result = try runSort(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "sort with no args blocks on stdin (skip)" {
    // Filter utility: would block on stdin
    return error.SkipZigTest;
}

test "parseKeyDef simple field" {
    const key = try parseKeyDef("2");
    try testing.expectEqual(@as(usize, 2), key.start_field);
    try testing.expectEqual(@as(usize, 0), key.start_char);
    try testing.expectEqual(@as(usize, 0), key.end_field);
}

test "parseKeyDef field with char offset" {
    const key = try parseKeyDef("2.3");
    try testing.expectEqual(@as(usize, 2), key.start_field);
    try testing.expectEqual(@as(usize, 3), key.start_char);
}

test "parseKeyDef field range" {
    const key = try parseKeyDef("1,3");
    try testing.expectEqual(@as(usize, 1), key.start_field);
    try testing.expectEqual(@as(usize, 3), key.end_field);
}

test "parseKeyDef field range with chars" {
    const key = try parseKeyDef("1.2,3.4");
    try testing.expectEqual(@as(usize, 1), key.start_field);
    try testing.expectEqual(@as(usize, 2), key.start_char);
    try testing.expectEqual(@as(usize, 3), key.end_field);
    try testing.expectEqual(@as(usize, 4), key.end_char);
}

test "parseKeyDef with options" {
    const key = try parseKeyDef("2,2nr");
    try testing.expectEqual(@as(usize, 2), key.start_field);
    try testing.expectEqual(@as(usize, 2), key.end_field);
    try testing.expect(key.flags.numeric_sort);
    try testing.expect(key.flags.reverse);
    try testing.expect(key.has_flags);
}

test "parseKeyDef invalid" {
    try testing.expectError(error.InvalidKeyDef, parseKeyDef(""));
    try testing.expectError(error.InvalidKeyDef, parseKeyDef("0"));
    try testing.expectError(error.InvalidKeyDef, parseKeyDef("abc"));
}

test "parseLeadingNumber basic" {
    try testing.expectEqual(@as(f64, 42), parseLeadingNumber("42"));
    try testing.expectEqual(@as(f64, -5), parseLeadingNumber("-5"));
    try testing.expectEqual(@as(f64, 3.14), parseLeadingNumber("3.14"));
    try testing.expectEqual(@as(f64, 0), parseLeadingNumber("abc"));
    try testing.expectEqual(@as(f64, 10), parseLeadingNumber("  10"));
}

test "parseHumanNumber with suffixes" {
    try testing.expectEqual(@as(f64, 1024), parseHumanNumber("1K"));
    try testing.expectEqual(@as(f64, 1024 * 1024), parseHumanNumber("1M"));
    try testing.expectEqual(@as(f64, 2 * 1024), parseHumanNumber("2K"));
    try testing.expectEqual(@as(f64, 100), parseHumanNumber("100"));
}

test "compareCaseInsensitive" {
    try testing.expectEqual(std.math.Order.eq, compareCaseInsensitive("abc", "ABC"));
    try testing.expectEqual(std.math.Order.lt, compareCaseInsensitive("abc", "def"));
    try testing.expectEqual(std.math.Order.gt, compareCaseInsensitive("def", "abc"));
}

test "compareDictionary" {
    // Dictionary order ignores non-alphanumeric/non-blank chars
    try testing.expectEqual(std.math.Order.eq, compareDictionary("a-b", "ab", false));
    try testing.expectEqual(std.math.Order.lt, compareDictionary("abc", "def", false));
}

test "stripLeadingBlanks" {
    try testing.expectEqualStrings("hello", stripLeadingBlanks("  hello"));
    try testing.expectEqualStrings("world", stripLeadingBlanks("\tworld"));
    try testing.expectEqualStrings("test", stripLeadingBlanks("test"));
}

test "splitFields with separator" {
    const fields = splitFields("a:b:c", ':');
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqualStrings("a", fields[0]);
    try testing.expectEqualStrings("b", fields[1]);
    try testing.expectEqualStrings("c", fields[2]);
}

test "splitFields with blanks (default)" {
    const fields = splitFields("  hello  world  test", null);
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqualStrings("hello", fields[0]);
    try testing.expectEqualStrings("world", fields[1]);
    try testing.expectEqualStrings("test", fields[2]);
}

test "parseArgs basic flags" {
    const args = [_][]const u8{ "-n", "-r", "-u" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.global_flags.numeric_sort);
    try testing.expect(opts.global_flags.reverse);
    try testing.expect(opts.unique);
}

test "parseArgs combined flags" {
    const args = [_][]const u8{"-nru"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.global_flags.numeric_sort);
    try testing.expect(opts.global_flags.reverse);
    try testing.expect(opts.unique);
}

test "parseArgs -k with value" {
    const args = [_][]const u8{ "-k", "2,2n" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.keys.items.len);
    try testing.expectEqual(@as(usize, 2), opts.keys.items[0].start_field);
}

test "parseArgs -t with value" {
    const args = [_][]const u8{ "-t", ":" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, ':'), opts.field_separator.?);
}

test "parseArgs -o with value" {
    const args = [_][]const u8{ "-o", "output.txt" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqualStrings("output.txt", opts.output_file.?);
}

test "parseArgs --check variants" {
    {
        const args = [_][]const u8{"-c"};
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(CheckMode.diagnose_first, opts.check);
    }
    {
        const args = [_][]const u8{"-C"};
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(CheckMode.quiet, opts.check);
    }
    {
        const args = [_][]const u8{"--check=quiet"};
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(CheckMode.quiet, opts.check);
    }
}

test "parseArgs files and --" {
    const args = [_][]const u8{ "file1.txt", "--", "-file2.txt" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.files.items.len);
    try testing.expectEqualStrings("file1.txt", opts.files.items[0]);
    try testing.expectEqualStrings("-file2.txt", opts.files.items[1]);
}

test "compareGeneralNumeric with scientific notation" {
    try testing.expectEqual(std.math.Order.lt, compareGeneralNumeric("1e2", "1e3"));
    try testing.expectEqual(std.math.Order.gt, compareGeneralNumeric("1e3", "1e2"));
    try testing.expectEqual(std.math.Order.eq, compareGeneralNumeric("100", "1e2"));
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("sort");

test "sort fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testSortFuzzWrapper, .{});
}

fn testSortFuzzWrapper(allocator: Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    if (!common.fuzz.shouldFuzzUtilityRuntime("sort")) return;
    // Skip actual execution for stdin-dependent utility
}
