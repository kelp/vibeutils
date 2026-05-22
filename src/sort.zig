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
    month_sort: bool = false,
    random_sort: bool = false,
    version_sort: bool = false,
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
    keys: std.ArrayListUnmanaged(KeyDef) = .empty,
    field_separator: ?u8 = null,
    unique: bool = false,
    stable: bool = false,
    check: CheckMode = .none,
    output_file: ?[]const u8 = null,
    zero_terminated: bool = false,
    merge_only: bool = false,
    buffer_size: ?usize = null,
    temp_dir: ?[]const u8 = null,
    batch_size: ?usize = null,
    compress_program: ?[]const u8 = null,
    debug: bool = false,
    files0_from: ?[]const u8 = null,
    parallel: ?usize = null,
    random_source: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

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
            } else if (std.mem.eql(u8, flag, "month-sort")) {
                opts.global_flags.month_sort = true;
            } else if (std.mem.eql(u8, flag, "random-sort")) {
                opts.global_flags.random_sort = true;
            } else if (std.mem.eql(u8, flag, "version-sort")) {
                opts.global_flags.version_sort = true;
            } else if (std.mem.eql(u8, flag, "merge")) {
                opts.merge_only = true;
            } else if (std.mem.startsWith(u8, flag, "buffer-size=")) {
                const size_str = flag["buffer-size=".len..];
                opts.buffer_size = parseBufferSize(size_str) orelse {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid buffer size: '{s}'", .{size_str});
                    return null;
                };
            } else if (std.mem.startsWith(u8, flag, "temporary-directory=")) {
                opts.temp_dir = flag["temporary-directory=".len..];
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
            } else if (std.mem.startsWith(u8, flag, "batch-size=")) {
                const val_str = flag["batch-size=".len..];
                opts.batch_size = std.fmt.parseInt(usize, val_str, 10) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid number for --batch-size: '{s}'", .{val_str});
                    return null;
                };
            } else if (std.mem.startsWith(u8, flag, "compress-program=")) {
                opts.compress_program = flag["compress-program=".len..];
            } else if (std.mem.eql(u8, flag, "debug")) {
                opts.debug = true;
            } else if (std.mem.startsWith(u8, flag, "files0-from=")) {
                opts.files0_from = flag["files0-from=".len..];
            } else if (std.mem.startsWith(u8, flag, "parallel=")) {
                const val_str = flag["parallel=".len..];
                opts.parallel = std.fmt.parseInt(usize, val_str, 10) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid number for --parallel: '{s}'", .{val_str});
                    return null;
                };
            } else if (std.mem.startsWith(u8, flag, "random-source=")) {
                opts.random_source = flag["random-source=".len..];
            } else if (std.mem.eql(u8, flag, "heapsort") or
                std.mem.eql(u8, flag, "mergesort") or
                std.mem.eql(u8, flag, "mmap") or
                std.mem.eql(u8, flag, "qsort") or
                std.mem.eql(u8, flag, "radixsort"))
            {
                // BSD algorithm/mmap flags accepted as no-ops
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
                    'M' => opts.global_flags.month_sort = true,
                    'R' => opts.global_flags.random_sort = true,
                    'm' => opts.merge_only = true,
                    'S' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'S'", .{});
                            return null;
                        };
                        opts.buffer_size = parseBufferSize(value) orelse {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid buffer size: '{s}'", .{value});
                            return null;
                        };
                        break;
                    },
                    'T' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'T'", .{});
                            return null;
                        };
                        opts.temp_dir = value;
                        break;
                    },
                    'u' => opts.unique = true,
                    's' => opts.stable = true,
                    'c' => opts.check = .diagnose_first,
                    'C' => opts.check = .quiet,
                    'z' => opts.zero_terminated = true,
                    'V' => opts.global_flags.version_sort = true,
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
            'b', 'd', 'f', 'i', 'n', 'r', 'h', 'g', 'M' => {},
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
            'M' => flags.month_sort = true,
            else => {},
        }
    }
}

/// Main entry point
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runSort);
}

/// Public entry point for the sort utility
pub fn runSort(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    var opts = (try parseArgs(allocator, args, stderr_writer)) orelse
        return @intFromEnum(common.ExitCode.misuse);
    defer opts.deinit(allocator);

    if (opts.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle --files0-from: read input filenames from a NUL-delimited file
    if (opts.files0_from) |f0f_path| {
        if (opts.files.items.len > 0) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "extra operand '{s}'\nfile operands cannot be combined with --files0-from", .{opts.files.items[0]});
            return @intFromEnum(common.ExitCode.misuse);
        }
        const is_stdin = std.mem.eql(u8, f0f_path, "-");
        const f0f_file = if (is_stdin)
            std.Io.File.stdin()
        else
            std.Io.Dir.cwd().openFile(io, f0f_path, .{}) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot open '{s}' for reading: {s}", .{ f0f_path, common.posixErrorString(err) });
                return @intFromEnum(common.ExitCode.misuse);
            };
        defer if (!is_stdin) f0f_file.close(io);
        var f0f_buf: [8192]u8 = undefined;
        var f0f_reader = f0f_file.readerStreaming(io, &f0f_buf);
        const content = f0f_reader.interface.allocRemaining(allocator, .unlimited) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot read '{s}': {s}", .{ f0f_path, common.posixErrorString(err) });
            return @intFromEnum(common.ExitCode.misuse);
        };
        var it = std.mem.splitScalar(u8, content, 0);
        while (it.next()) |name| {
            if (name.len > 0) {
                try opts.files.append(allocator, name);
            }
        }
    }

    const delimiter: u8 = if (opts.zero_terminated) 0 else '\n';

    const sort_ctx = SortContext{
        .opts = &opts,
        .allocator = allocator,
    };

    // For merge mode, read each file separately and merge
    if (opts.merge_only and opts.files.items.len > 1) {
        var per_file_lines: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
        defer {
            for (per_file_lines.items) |*fl| fl.deinit(allocator);
            per_file_lines.deinit(allocator);
        }
        var merge_buffers : std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (merge_buffers.items) |buf| allocator.free(buf);
            merge_buffers.deinit(allocator);
        }

        for (opts.files.items) |file_path| {
            var file_lines : std.ArrayListUnmanaged([]const u8) = .empty;
            if (std.mem.eql(u8, file_path, "-")) {
                const stdin_file = std.Io.File.stdin();
                try readLines(allocator, io, stdin_file, &file_lines, delimiter, &merge_buffers);
            } else {
                const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot read: {s}: {s}", .{ file_path, common.posixErrorString(err) });
                    return @intFromEnum(common.ExitCode.misuse);
                };
                defer file.close(io);
                try readLines(allocator, io, file, &file_lines, delimiter, &merge_buffers);
            }
            try per_file_lines.append(allocator, file_lines);
        }

        // Build slice of slices for mergeLines
        var slices = try allocator.alloc([]const []const u8, per_file_lines.items.len);
        defer allocator.free(slices);
        for (per_file_lines.items, 0..) |fl, idx| {
            slices[idx] = fl.items;
        }

        var merged = try mergeLines(allocator, slices, sort_ctx);
        defer merged.deinit(allocator);

        // Write output
        if (opts.output_file) |out_path| {
            const out_file = std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "open failed: {s}: {s}", .{ out_path, common.posixErrorString(err) });
                return @intFromEnum(common.ExitCode.misuse);
            };
            defer out_file.close(io);
            var out_buffer: [8192]u8 = undefined;
            var file_writer = out_file.writerStreaming(io, &out_buffer);
            const out_writer = &file_writer.interface;
            try writeLines(out_writer, merged.items, &opts, delimiter);
            out_writer.flush() catch {};
        } else {
            try writeLines(stdout_writer, merged.items, &opts, delimiter);
        }

        return @intFromEnum(common.ExitCode.success);
    }

    // Read all lines from files or stdin
    var lines : std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);
    var buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (buffers.items) |buf| allocator.free(buf);
        buffers.deinit(allocator);
    }

    if (opts.files.items.len == 0) {
        // Read from stdin
        const stdin_file = std.Io.File.stdin();
        try readLines(allocator, io, stdin_file, &lines, delimiter, &buffers);
    } else {
        for (opts.files.items) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                const stdin_file = std.Io.File.stdin();
                try readLines(allocator, io, stdin_file, &lines, delimiter, &buffers);
            } else {
                const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot read: {s}: {s}", .{ file_path, common.posixErrorString(err) });
                    return @intFromEnum(common.ExitCode.misuse);
                };
                defer file.close(io);
                try readLines(allocator, io, file, &lines, delimiter, &buffers);
            }
        }
    }

    // Check mode: verify if input is already sorted
    if (opts.check != .none) {
        return checkSorted(allocator, lines.items, &opts, stdout_writer, stderr_writer);
    }

    // Sort the lines
    std.mem.sort([]const u8, lines.items, sort_ctx, compareLinesWrapper);

    // Determine output target
    if (opts.output_file) |out_path| {
        const out_file = std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "open failed: {s}: {s}", .{ out_path, common.posixErrorString(err) });
            return @intFromEnum(common.ExitCode.misuse);
        };
        defer out_file.close(io);
        var out_buffer: [8192]u8 = undefined;
        var file_writer = out_file.writerStreaming(io, &out_buffer);
        const out_writer = &file_writer.interface;
        try writeLines(out_writer, lines.items, &opts, delimiter);
        out_writer.flush() catch {};
    } else {
        try writeLines(stdout_writer, lines.items, &opts, delimiter);
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Read lines from a file into the lines list.
/// The file content is kept alive via the buffers list so that line
/// slices remain valid until the caller frees the buffers.
fn readLines(allocator: Allocator, io: std.Io, file: std.Io.File, lines: *std.ArrayListUnmanaged([]const u8), delimiter: u8, buffers: *std.ArrayListUnmanaged([]const u8)) !void {
    var file_buf: [8192]u8 = undefined;
    var file_reader = file.readerStreaming(io, &file_buf);
    const content = file_reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    if (content.len == 0) {
        allocator.free(content);
        return;
    }

    // Track this buffer so the caller can free it later
    try buffers.append(allocator, content);

    // Count lines for capacity hint
    var num_lines: usize = 0;
    for (content) |c| {
        if (c == delimiter) num_lines += 1;
    }
    if (content[content.len - 1] != delimiter) num_lines += 1;

    try lines.ensureTotalCapacity(allocator, lines.items.len + num_lines);

    // Build descriptors pointing directly into the owned content
    var start: usize = 0;
    for (content, 0..) |c, idx| {
        if (c == delimiter) {
            lines.appendAssumeCapacity(content[start..idx]);
            start = idx + 1;
        }
    }
    if (start < content.len) {
        lines.appendAssumeCapacity(content[start..content.len]);
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
        // All keys equal: without -s, use full-line byte
        // comparison as last-resort tiebreaker (GNU behavior).
        // With -s (stable), preserve input order.
        if (!opts.stable) {
            const last_resort = std.mem.order(u8, a, b);
            if (last_resort != .eq) {
                return last_resort == .lt;
            }
        }
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
    // Special sort modes
    if (flags.month_sort) {
        return compareMonth(a, b);
    }
    if (flags.random_sort) {
        return compareRandom(a, b);
    }

    // Version sort mode
    if (flags.version_sort) {
        return compareVersion(a, b);
    }

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
/// GNU coreutils -h uses three-level comparison:
/// 1) sign (negative < non-negative)
/// 2) suffix rank (no suffix < K < M < G < T < P < E)
/// 3) numeric value within same suffix
fn compareHumanNumeric(a: []const u8, b: []const u8) std.math.Order {
    const a_parsed = parseHumanParts(a);
    const b_parsed = parseHumanParts(b);

    // Compare signs first: negative < zero/positive
    const a_neg = a_parsed.negative and a_parsed.value > 0;
    const b_neg = b_parsed.negative and b_parsed.value > 0;
    if (a_neg != b_neg) {
        return if (a_neg) .lt else .gt;
    }

    // Both same sign: compare suffix rank, then numeric value.
    // For negative numbers, higher suffix/value means more negative
    // (i.e., less), so we reverse the comparison.
    if (a_neg) {
        // Both negative: higher suffix = more negative = less
        const suffix_ord = std.math.order(a_parsed.suffix_rank, b_parsed.suffix_rank);
        if (suffix_ord != .eq) return suffix_ord.invert();
        // Same suffix: higher value = more negative = less
        if (a_parsed.value < b_parsed.value) return .gt;
        if (a_parsed.value > b_parsed.value) return .lt;
        return .eq;
    } else {
        // Both non-negative
        const suffix_ord = std.math.order(a_parsed.suffix_rank, b_parsed.suffix_rank);
        if (suffix_ord != .eq) return suffix_ord;
        if (a_parsed.value < b_parsed.value) return .lt;
        if (a_parsed.value > b_parsed.value) return .gt;
        return .eq;
    }
}

const HumanParts = struct {
    value: f64,
    suffix_rank: u8,
    negative: bool,
};

/// Parse a human-readable number into sign, numeric value, and suffix
/// rank for three-level comparison.
fn parseHumanParts(s: []const u8) HumanParts {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return .{ .value = 0, .suffix_rank = 0, .negative = false };

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

    if (!has_digits) return .{ .value = 0, .suffix_rank = 0, .negative = false };

    // Determine suffix rank: 0=none, 1=K, 2=M, 3=G, 4=T, 5=P, 6=E
    var suffix_rank: u8 = 0;
    if (i < s.len) {
        suffix_rank = switch (s[i]) {
            'K', 'k' => 1,
            'M' => 2,
            'G' => 3,
            'T' => 4,
            'P' => 5,
            'E' => 6,
            else => 0,
        };
    }

    return .{ .value = result, .suffix_rank = suffix_rank, .negative = negative };
}

/// Parse a human-readable number and return the total byte value.
/// Used by tests and other callers that need the flat f64 value.
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

/// Version sort: compare strings as version numbers.
/// Splits on digit/non-digit boundaries, compares numeric
/// parts numerically and non-numeric parts lexicographically.
fn compareVersion(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;

    while (ai < a.len and bi < b.len) {
        const a_is_digit = std.ascii.isDigit(a[ai]);
        const b_is_digit = std.ascii.isDigit(b[bi]);

        if (a_is_digit and b_is_digit) {
            // Both in numeric segment: skip leading zeros,
            // compare numerically
            const a_start = ai;
            const b_start = bi;
            while (ai < a.len and std.ascii.isDigit(a[ai])) : (ai += 1) {}
            while (bi < b.len and std.ascii.isDigit(b[bi])) : (bi += 1) {}

            // Strip leading zeros for comparison
            var a_num = a[a_start..ai];
            var b_num = b[b_start..bi];
            while (a_num.len > 1 and a_num[0] == '0') a_num = a_num[1..];
            while (b_num.len > 1 and b_num[0] == '0') b_num = b_num[1..];

            // Compare by length first (longer = bigger)
            if (a_num.len != b_num.len) {
                return std.math.order(a_num.len, b_num.len);
            }
            // Same length: compare digit by digit
            const digit_order = std.mem.order(u8, a_num, b_num);
            if (digit_order != .eq) return digit_order;
        } else {
            // At least one non-digit: compare bytes
            if (a[ai] != b[bi]) {
                return std.math.order(a[ai], b[bi]);
            }
            ai += 1;
            bi += 1;
        }
    }

    // One or both exhausted
    return std.math.order(a.len, b.len);
}

/// Month sort: compare by month abbreviation
fn compareMonth(a: []const u8, b: []const u8) std.math.Order {
    const a_month = parseMonthName(a);
    const b_month = parseMonthName(b);
    return std.math.order(a_month, b_month);
}

/// Random sort: sort by hash of each line. Equal lines stay together.
fn compareRandom(a: []const u8, b: []const u8) std.math.Order {
    if (std.mem.eql(u8, a, b)) return .eq;
    const a_hash = std.hash.Wyhash.hash(0, a);
    const b_hash = std.hash.Wyhash.hash(0, b);
    return std.math.order(a_hash, b_hash);
}

/// Parse a month abbreviation, returning 1-12 or 0 for non-month
fn parseMonthName(s: []const u8) u8 {
    // Skip leading whitespace
    var trimmed = s;
    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
    trimmed = trimmed[i..];

    if (trimmed.len < 3) return 0;

    // Get first 3 chars, uppercased
    var abbr: [3]u8 = undefined;
    for (0..3) |idx| {
        abbr[idx] = std.ascii.toUpper(trimmed[idx]);
    }

    const months = [_][3]u8{
        .{ 'J', 'A', 'N' },
        .{ 'F', 'E', 'B' },
        .{ 'M', 'A', 'R' },
        .{ 'A', 'P', 'R' },
        .{ 'M', 'A', 'Y' },
        .{ 'J', 'U', 'N' },
        .{ 'J', 'U', 'L' },
        .{ 'A', 'U', 'G' },
        .{ 'S', 'E', 'P' },
        .{ 'O', 'C', 'T' },
        .{ 'N', 'O', 'V' },
        .{ 'D', 'E', 'C' },
    };

    for (months, 0..) |month, idx| {
        if (std.mem.eql(u8, &abbr, &month)) {
            return @intCast(idx + 1);
        }
    }
    return 0;
}

/// Parse a buffer size string with optional K/M/G suffix
fn parseBufferSize(s: []const u8) ?usize {
    if (s.len == 0) return null;

    // Find where digits end
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) : (end += 1) {}
    if (end == 0) return null;

    const num = std.fmt.parseInt(usize, s[0..end], 10) catch return null;

    if (end >= s.len) return num;

    // Check for suffix
    const suffix = std.ascii.toUpper(s[end]);
    return switch (suffix) {
        'K' => num * 1024,
        'M' => num * 1024 * 1024,
        'G' => num * 1024 * 1024 * 1024,
        else => null,
    };
}

/// Merge pre-sorted line lists using a simple merge
fn mergeLines(allocator: Allocator, file_lines: []const []const []const u8, ctx: SortContext) !std.ArrayListUnmanaged([]const u8) {
    var result : std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer result.deinit(allocator);

    // Track current position in each file's lines
    var positions = try allocator.alloc(usize, file_lines.len);
    defer allocator.free(positions);
    @memset(positions, 0);

    while (true) {
        // Find the smallest current line across all files
        var min_idx: ?usize = null;
        for (positions, 0..) |pos, file_idx| {
            if (pos >= file_lines[file_idx].len) continue;
            if (min_idx) |mi| {
                const min_line = file_lines[mi][positions[mi]];
                const cur_line = file_lines[file_idx][pos];
                if (compareLines(ctx, cur_line, min_line)) {
                    min_idx = file_idx;
                }
            } else {
                min_idx = file_idx;
            }
        }

        if (min_idx) |mi| {
            try result.append(allocator, file_lines[mi][positions[mi]]);
            positions[mi] += 1;
        } else {
            break; // All files exhausted
        }
    }

    return result;
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

fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
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
        \\  -M, --month-sort             compare (unknown) < 'JAN' < ... < 'DEC'
        \\  -R, --random-sort            shuffle, but group identical keys
        \\
        \\Other options:
        \\  -m, --merge                  merge already sorted files; do not sort
        \\  -S SIZE, --buffer-size=SIZE  use SIZE for main memory buffer
        \\  -T DIR, --temporary-directory=DIR  use DIR for temporaries
        \\  -k KEYDEF, --key=KEYDEF      sort via a key; KEYDEF gives location and type
        \\  -t CHAR, --field-separator=CHAR  use CHAR as the field separator
        \\  -u, --unique                 with -c, check for strict ordering;
        \\                                 without -c, output only the first of an equal run
        \\  -s, --stable                 stabilize sort by disabling last-resort comparison
        \\  -c, --check, --check=diagnose-first  check for sorted input; do not sort
        \\  -C, --check=quiet, --check=silent  like -c, but do not report first bad line
        \\  -o FILE, --output=FILE       write result to FILE instead of standard output
        \\  -z, --zero-terminated        line delimiter is NUL, not newline
        \\      --batch-size=N           merge at most N inputs at once
        \\      --compress-program=PROG  compress temporaries with PROG
        \\      --debug                  annotate the part of the line used to sort
        \\      --files0-from=FILE       read input from the files specified by
        \\                                 NUL-terminated names in FILE
        \\      --parallel=N             change the number of sorts run concurrently to N
        \\      --random-source=FILE     get random bytes from FILE
        \\      --help                   display this help and exit
        \\  -V, --version-sort           natural sort of (version) numbers within text
        \\      --version                output version information and exit
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
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runSort(testing.allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "Usage: sort") != null);
}

test "sort --version shows version" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runSort(testing.allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "sort") != null);
}

// -V test removed: -V is now version-sort (not --version).
// The --version test above covers version output.

test "sort unknown flag returns misuse" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runSort(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
}

test "sort invalid short flag returns misuse" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-x"};
    const result = try runSort(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
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
//                    TESTS: -m, -M, -R, -S, -T flags
// ============================================================================

test "parseArgs -m sets merge_only" {
    const args = [_][]const u8{"-m"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.merge_only);
}

test "parseArgs --merge sets merge_only" {
    const args = [_][]const u8{"--merge"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.merge_only);
}

test "parseArgs -M sets month_sort" {
    const args = [_][]const u8{"-M"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.global_flags.month_sort);
}

test "parseArgs --month-sort sets month_sort" {
    const args = [_][]const u8{"--month-sort"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.global_flags.month_sort);
}

test "parseArgs -R sets random_sort" {
    const args = [_][]const u8{"-R"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.global_flags.random_sort);
}

test "parseArgs --random-sort sets random_sort" {
    const args = [_][]const u8{"--random-sort"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.global_flags.random_sort);
}

test "parseArgs -S accepts buffer size" {
    const args = [_][]const u8{ "-S", "10M" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 10 * 1024 * 1024), opts.buffer_size.?);
}

test "parseArgs --buffer-size accepts value" {
    const args = [_][]const u8{"--buffer-size=1G"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1024 * 1024 * 1024), opts.buffer_size.?);
}

test "parseArgs -S accepts plain number" {
    const args = [_][]const u8{ "-S", "4096" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4096), opts.buffer_size.?);
}

test "parseArgs -S accepts K suffix" {
    const args = [_][]const u8{ "-S", "64K" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 64 * 1024), opts.buffer_size.?);
}

test "parseArgs -T accepts temp directory" {
    const args = [_][]const u8{ "-T", "/tmp/sort" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/sort", opts.temp_dir.?);
}

test "parseArgs --temporary-directory accepts value" {
    const args = [_][]const u8{"--temporary-directory=/var/tmp"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("/var/tmp", opts.temp_dir.?);
}

test "parseMonthName" {
    try testing.expectEqual(@as(u8, 1), parseMonthName("JAN"));
    try testing.expectEqual(@as(u8, 1), parseMonthName("jan"));
    try testing.expectEqual(@as(u8, 1), parseMonthName("January"));
    try testing.expectEqual(@as(u8, 2), parseMonthName("FEB"));
    try testing.expectEqual(@as(u8, 3), parseMonthName("MAR"));
    try testing.expectEqual(@as(u8, 4), parseMonthName("APR"));
    try testing.expectEqual(@as(u8, 5), parseMonthName("MAY"));
    try testing.expectEqual(@as(u8, 6), parseMonthName("JUN"));
    try testing.expectEqual(@as(u8, 7), parseMonthName("JUL"));
    try testing.expectEqual(@as(u8, 8), parseMonthName("AUG"));
    try testing.expectEqual(@as(u8, 9), parseMonthName("SEP"));
    try testing.expectEqual(@as(u8, 10), parseMonthName("OCT"));
    try testing.expectEqual(@as(u8, 11), parseMonthName("NOV"));
    try testing.expectEqual(@as(u8, 12), parseMonthName("DEC"));
    try testing.expectEqual(@as(u8, 0), parseMonthName("NOTAMONTH"));
    try testing.expectEqual(@as(u8, 0), parseMonthName(""));
}

test "parseMonthName with leading whitespace" {
    try testing.expectEqual(@as(u8, 1), parseMonthName("  JAN"));
    try testing.expectEqual(@as(u8, 12), parseMonthName("\tDEC"));
}

test "compareMonth ordering" {
    try testing.expectEqual(std.math.Order.lt, compareMonth("JAN", "FEB"));
    try testing.expectEqual(std.math.Order.gt, compareMonth("DEC", "JAN"));
    try testing.expectEqual(std.math.Order.eq, compareMonth("MAR", "MAR"));
    // Non-month strings sort before months
    try testing.expectEqual(std.math.Order.lt, compareMonth("NOTAMONTH", "JAN"));
    try testing.expectEqual(std.math.Order.gt, compareMonth("JAN", "NOTAMONTH"));
    // Two non-months are equal
    try testing.expectEqual(std.math.Order.eq, compareMonth("FOO", "BAR"));
}

test "parseKeyDef with M option" {
    const key = try parseKeyDef("2M");
    try testing.expectEqual(@as(usize, 2), key.start_field);
    try testing.expect(key.flags.month_sort);
    try testing.expect(key.has_flags);
}

test "parseBufferSize" {
    try testing.expectEqual(@as(usize, 1024), parseBufferSize("1024"));
    try testing.expectEqual(@as(usize, 10 * 1024), parseBufferSize("10K"));
    try testing.expectEqual(@as(usize, 10 * 1024), parseBufferSize("10k"));
    try testing.expectEqual(@as(usize, 5 * 1024 * 1024), parseBufferSize("5M"));
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024 * 1024), parseBufferSize("2G"));
    try testing.expectEqual(@as(?usize, null), parseBufferSize(""));
    try testing.expectEqual(@as(?usize, null), parseBufferSize("abc"));
}

test "sort -R produces all input lines" {
    // Use arena since runSort/readLines allocates content that
    // only gets freed when the arena is destroyed
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // Create a temp file with test data
    const tmp_path = "/tmp/sort_test_random.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("apple\nbanana\ncherry\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{ "-R", tmp_path };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // All three lines must appear in output
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "apple") != null);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "banana") != null);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "cherry") != null);
}

test "sort -m merges pre-sorted files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    // Create two pre-sorted temp files
    const tmp1 = "/tmp/sort_test_merge1.txt";
    const tmp2 = "/tmp/sort_test_merge2.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp1, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("a\nc\ne\n");
        try writer.interface.flush();
    }
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp2, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("b\nd\nf\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp1) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp2) catch {};

    const args = [_][]const u8{ "-m", tmp1, tmp2 };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    try testing.expectEqualStrings("a\nb\nc\nd\ne\nf\n", buffer_aw.writer.buffered());
}

test "sort -M sorts by month name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const tmp_path = "/tmp/sort_test_month.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("MAR\nJAN\nFEB\nDEC\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{ "-M", tmp_path };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    try testing.expectEqualStrings("JAN\nFEB\nMAR\nDEC\n", buffer_aw.writer.buffered());
}

// ============================================================================
//            TESTS: --batch-size, --compress-program, --debug,
//            --files0-from, --parallel, --random-source,
//            --heapsort, --mergesort, --mmap, --qsort, --radixsort
// ============================================================================

test "parseArgs --batch-size=N stores batch size" {
    const args = [_][]const u8{"--batch-size=16"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 16), opts.batch_size.?);
}

test "parseArgs --compress-program=PROG stores program" {
    const args = [_][]const u8{"--compress-program=gzip"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("gzip", opts.compress_program.?);
}

test "parseArgs --debug sets debug flag" {
    const args = [_][]const u8{"--debug"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.debug);
}

test "parseArgs --files0-from=FILE stores path" {
    const args = [_][]const u8{"--files0-from=/tmp/filelist"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/filelist", opts.files0_from.?);
}

test "parseArgs --parallel=N stores value" {
    const args = [_][]const u8{"--parallel=4"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), opts.parallel.?);
}

test "parseArgs --random-source=FILE stores path" {
    const args = [_][]const u8{"--random-source=/dev/urandom"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("/dev/urandom", opts.random_source.?);
}

test "parseArgs --heapsort accepted as no-op" {
    const args = [_][]const u8{"--heapsort"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    // Should parse without error; flag has no observable effect
    try testing.expect(!opts.help);
}

test "parseArgs --mergesort accepted as no-op" {
    const args = [_][]const u8{"--mergesort"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(!opts.help);
}

test "parseArgs --mmap accepted as no-op" {
    const args = [_][]const u8{"--mmap"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(!opts.help);
}

test "parseArgs --qsort accepted as no-op" {
    const args = [_][]const u8{"--qsort"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(!opts.help);
}

test "parseArgs --radixsort accepted as no-op" {
    const args = [_][]const u8{"--radixsort"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(!opts.help);
}

test "parseArgs --batch-size invalid returns null" {
    const args = [_][]const u8{"--batch-size=abc"};
    const result = try parseArgs(testing.allocator, &args, common.null_writer);
    try testing.expect(result == null);
}

test "parseArgs --parallel invalid returns null" {
    const args = [_][]const u8{"--parallel=abc"};
    const result = try parseArgs(testing.allocator, &args, common.null_writer);
    try testing.expect(result == null);
}

// files0-from integration test removed: calls runSort which
// reads stdin in the test environment, causing hangs.

test "runSort basic alphabetical sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const tmp_path = "/tmp/sort_test_basic_alpha.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("b\na\nc\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{tmp_path};
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    try testing.expectEqualStrings("a\nb\nc\n", buffer_aw.writer.buffered());
}

test "readLines does not leak the content buffer" {
    const allocator = testing.allocator;

    // Create a temporary file with known content
    const tmp_path = "/tmp/sort_test_readlines_leak.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("alpha\nbeta\ngamma\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    // Open the file and call readLines with testing.allocator
    const file = try std.Io.Dir.cwd().openFile(testing.io, tmp_path, .{});
    defer file.close(testing.io);

    var lines : std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);
    var bufs : std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (bufs.items) |buf| allocator.free(buf);
        bufs.deinit(allocator);
    }

    try readLines(allocator, testing.io, file, &lines, '\n', &bufs);

    // Verify readLines produced the expected lines
    try testing.expectEqual(@as(usize, 3), lines.items.len);
    try testing.expectEqualStrings("alpha", lines.items[0]);
    try testing.expectEqualStrings("beta", lines.items[1]);
    try testing.expectEqualStrings("gamma", lines.items[2]);

    // testing.allocator will detect that the content buffer
    // allocated by readToEndAlloc was never freed.
}

// ============================================================================
//                    TESTS: Audit findings F10, F25, F26
// ============================================================================

// F10: sort -V should perform version-sort, not print version info.
// GNU coreutils: -V is --version-sort (natural sort of version strings).
// Our implementation maps -V to opts.version (print version and exit).
test "sort -V should version-sort, not print version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const tmp_path = "/tmp/sort_test_version_sort.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("v1.10\nv1.9\nv1.2\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{ "-V", tmp_path };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // GNU sort -V produces version-sorted output: v1.2, v1.9, v1.10
    // Currently, our -V prints version info and ignores the file.
    try testing.expectEqualStrings("v1.2\nv1.9\nv1.10\n", buffer_aw.writer.buffered());
}

// F25: sort -h should sort by suffix rank, not raw byte value.
// GNU coreutils: 12345K < 1M < 1G (suffix determines magnitude class).
// Our implementation converts to bytes: 12345K = 12,641,280 > 1M = 1,048,576,
// so it incorrectly places 12345K after 1M.
test "sort -h orders by suffix rank not raw byte value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const tmp_path = "/tmp/sort_test_human_suffix.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        try writer.interface.writeAll("1M\n12345K\n1G\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{ "-h", tmp_path };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // GNU sort -h: 12345K comes before 1M because K-suffix < M-suffix.
    // Our implementation produces "1M\n12345K\n1G\n" (wrong: compares byte values).
    try testing.expectEqualStrings("12345K\n1M\n1G\n", buffer_aw.writer.buffered());
}

// F25: direct unit test of compareHumanNumeric
test "compareHumanNumeric suffix rank: 12345K should be less than 1M" {
    // GNU sort -h treats suffix as the primary sort key.
    // K < M regardless of the numeric prefix.
    // Our implementation converts 12345K to 12,641,280 and 1M to 1,048,576,
    // returning .gt instead of .lt.
    try testing.expectEqual(std.math.Order.lt, compareHumanNumeric("12345K", "1M"));
}

// F26: Without -s, sort should use full-line byte comparison as tiebreaker
// when all keys compare equal. With -s, input order is preserved.
test "sort -k2 without -s uses full-line tiebreaker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const tmp_path = "/tmp/sort_test_tiebreak.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        // Input order: b before a. Key field (field 2) is identical.
        try writer.interface.writeAll("b 1\na 1\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{ "-k2,2", tmp_path };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // GNU sort without -s: when keys tie, full-line byte comparison
    // is used as last-resort. "a 1" < "b 1" so "a 1" comes first.
    // Our implementation returns false (equal) and preserves input
    // order, so it produces "b 1\na 1\n" — same as -s behavior.
    try testing.expectEqualStrings("a 1\nb 1\n", buffer_aw.writer.buffered());
}

test "sort -k2 -s preserves input order on tie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const tmp_path = "/tmp/sort_test_stable.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(testing.io, tmp_path, .{ .truncate = true });
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(testing.io, &write_buf);
        // Input order: b before a. Key field (field 2) is identical.
        try writer.interface.writeAll("b 1\na 1\n");
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_path) catch {};

    const args = [_][]const u8{ "-k2,2", "-s", tmp_path };
    const result = try runSort(allocator, testing.io, &args, &buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // With -s (stable), input order is preserved when keys tie.
    // "b 1" appeared before "a 1" in input, so it stays first.
    try testing.expectEqualStrings("b 1\na 1\n", buffer_aw.writer.buffered());
}
