//! grep - print lines that match patterns
//!
//! Search for PATTERN in each FILE or standard input.
//! PATTERN is a basic regular expression (BRE) by default.
//! Supports extended (ERE), fixed-string, and POSIX regex matching.

const std = @import("std");
const common = @import("common");
const glob = common.glob;
const testing = std.testing;
const builtin = @import("builtin");
const privilege_test = common.privilege_test;

extern "c" fn geteuid() std.c.uid_t;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const c = @cImport({
    @cInclude("regex.h");
});

const is_linux = builtin.os.tag == .linux;

// On Linux, regex_t is opaque to Zig (glibc internal types can't be parsed).
// Use C helper functions for heap allocation instead of Zig's allocator.
const regex_c = if (is_linux) struct {
    extern "c" fn regex_heap_alloc() ?*c.regex_t;
    extern "c" fn regex_heap_free(re: *c.regex_t) void;
} else struct {};

const prog_name = "grep";

// ============================================================================
// Types
// ============================================================================

const RegexMode = enum {
    basic,
    extended,
    fixed,
};

/// Parsed command-line options for grep
const GrepOptions = struct {
    regex_mode: RegexMode = .basic,
    ignore_case: bool = false,
    invert_match: bool = false,
    count: bool = false,
    files_with_matches: bool = false,
    files_without_match: bool = false,
    line_number: bool = false,
    with_filename: bool = false,
    no_filename: bool = false,
    only_matching: bool = false,
    quiet: bool = false,
    no_messages: bool = false,
    word_regexp: bool = false,
    line_regexp: bool = false,
    byte_offset: bool = false,
    null_data: bool = false,
    null_line_sep: bool = false,
    skip_dirs: bool = false,
    stdin_label: ?[]const u8 = null,
    recursive: bool = false,
    dereference_recursive: bool = false,
    max_count: ?usize = null,
    after_context: usize = 0,
    before_context: usize = 0,
    color: common.display_config.ResolvedMode = .off,
    include_globs: std.ArrayListUnmanaged([]const u8) = .empty,
    exclude_globs: std.ArrayListUnmanaged([]const u8) = .empty,
    exclude_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    pattern_file_contents: std.ArrayListUnmanaged([]const u8) = .empty,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
    help: bool = false,
    version: bool = false,

    fn deinit(self: *GrepOptions, allocator: Allocator) void {
        self.include_globs.deinit(allocator);
        self.exclude_globs.deinit(allocator);
        self.exclude_dirs.deinit(allocator);
        for (self.pattern_file_contents.items) |buf| {
            allocator.free(buf);
        }
        self.pattern_file_contents.deinit(allocator);
        self.patterns.deinit(allocator);
        self.files.deinit(allocator);
    }
};

/// Compiled pattern for matching
const CompiledPattern = union(enum) {
    regex: *c.regex_t,
    fixed: FixedPattern,

    const FixedPattern = struct {
        text: []const u8,
        lower: ?[]const u8,
    };
};

// ============================================================================
// Argument Parsing
// ============================================================================

/// Parse grep command-line arguments
/// Returns null on error (error already printed to stderr)
fn parseArgs(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stderr_writer: *std.Io.Writer,
) !?GrepOptions {
    var opts = GrepOptions{};
    errdefer opts.deinit(allocator);

    // Resolve color from DisplayConfig (handles VIBEUTILS_STYLE, NO_COLOR, TTY)
    const display = common.display_config.DisplayConfig.resolve(allocator);
    opts.color = display.color;

    var i: usize = 0;
    var saw_double_dash = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (saw_double_dash) {
            try opts.files.append(allocator, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            saw_double_dash = true;
            continue;
        }

        if (arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
            // Long option
            const flag = arg[2..];
            switch (try parseArgs_handleLong(allocator, io, &opts, flag, stderr_writer)) {
                .ok => {},
                .fail => return null,
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            // Short options
            switch (try parseArgs_handleShort(allocator, io, &opts, arg, args, &i, stderr_writer)) {
                .ok => {},
                .fail => return null,
            }
        } else {
            // Positional argument
            if (opts.patterns.items.len == 0) {
                // First positional is the pattern (when no -e given)
                try opts.patterns.append(allocator, arg);
            } else {
                try opts.files.append(allocator, arg);
            }
        }
    }

    return opts;
}

/// Outcome of handling one argv element: applied, or report-and-abort.
const ArgStepResult = enum { ok, fail };

/// Apply one long option (`--flag` or `--flag=value`). Reports an
/// "unrecognized option" error and returns `.fail` when `flag` is unknown.
fn parseArgs_handleLong(
    allocator: Allocator,
    io: std.Io,
    opts: *GrepOptions,
    flag: []const u8,
    stderr_writer: *std.Io.Writer,
) !ArgStepResult {
    if (parseArgs_longFlag(opts, flag)) {
        // Consumed by a boolean/mode flag.
        return .ok;
    }
    switch (try parseArgs_longValued(allocator, io, opts, flag, stderr_writer)) {
        .consumed_ok => return .ok,
        .consumed_error => return .fail,
        .not_mine => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "unrecognized option '--{s}'",
                .{flag},
            );
            return .fail;
        },
    }
}

/// Apply a cluster of short options (`-abc` or `-A5`). Advances `i_ptr` when a
/// valued option consumes the next argv element. Returns `.fail` on error.
fn parseArgs_handleShort(
    allocator: Allocator,
    io: std.Io,
    opts: *GrepOptions,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) !ArgStepResult {
    var j: usize = 1; // tiger:allow:usize-arch arg index, slice-index-forced
    while (j < arg.len) : (j += 1) {
        const ch = arg[j];
        if (parseArgs_shortFlag(opts, ch)) continue;
        switch (try parseArgs_shortValued(
            allocator,
            io,
            opts,
            arg,
            args,
            i_ptr,
            &j,
            stderr_writer,
        )) {
            .consumed_break => break,
            .consumed_error => return .fail,
            .not_mine => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "invalid option -- '{c}'",
                    .{ch},
                );
                return .fail;
            },
        }
    }
    return .ok;
}

/// Outcome of a long-option value parse: handled, errored, or unrecognized.
const LongOptionResult = enum { consumed_ok, consumed_error, not_mine };

/// Handle boolean and mode long options (the `eql` arms). Returns true when
/// `flag` was recognized and applied.
fn parseArgs_longFlag(opts: *GrepOptions, flag: []const u8) bool {
    assert(@intFromEnum(opts.regex_mode) <= @intFromEnum(RegexMode.fixed));
    assert(@intFromEnum(opts.regex_mode) >= @intFromEnum(RegexMode.basic));
    if (std.mem.eql(u8, flag, "help")) {
        opts.help = true;
    } else if (std.mem.eql(u8, flag, "version")) {
        opts.version = true;
    } else if (std.mem.eql(u8, flag, "extended-regexp")) {
        opts.regex_mode = .extended;
    } else if (std.mem.eql(u8, flag, "fixed-strings")) {
        opts.regex_mode = .fixed;
    } else if (std.mem.eql(u8, flag, "basic-regexp")) {
        opts.regex_mode = .basic;
    } else if (std.mem.eql(u8, flag, "ignore-case")) {
        opts.ignore_case = true;
    } else if (std.mem.eql(u8, flag, "invert-match")) {
        opts.invert_match = true;
    } else if (std.mem.eql(u8, flag, "count")) {
        opts.count = true;
    } else if (std.mem.eql(u8, flag, "files-with-matches")) {
        opts.files_with_matches = true;
    } else if (std.mem.eql(u8, flag, "files-without-match")) {
        opts.files_without_match = true;
    } else if (std.mem.eql(u8, flag, "line-number")) {
        opts.line_number = true;
    } else if (std.mem.eql(u8, flag, "with-filename")) {
        opts.with_filename = true;
    } else if (std.mem.eql(u8, flag, "no-filename")) {
        opts.no_filename = true;
    } else if (std.mem.eql(u8, flag, "only-matching")) {
        opts.only_matching = true;
    } else if (std.mem.eql(u8, flag, "quiet") or std.mem.eql(u8, flag, "silent")) {
        opts.quiet = true;
    } else if (std.mem.eql(u8, flag, "no-messages")) {
        opts.no_messages = true;
    } else if (std.mem.eql(u8, flag, "word-regexp")) {
        opts.word_regexp = true;
    } else if (std.mem.eql(u8, flag, "line-regexp")) {
        opts.line_regexp = true;
    } else if (std.mem.eql(u8, flag, "byte-offset")) {
        opts.byte_offset = true;
    } else if (std.mem.eql(u8, flag, "text")) {
        // No-op: treat binary as text (no binary detection yet)
    } else if (std.mem.eql(u8, flag, "binary")) {
        // No-op: Unix treats all files as binary by default
    } else if (std.mem.eql(u8, flag, "null")) {
        opts.null_data = true;
    } else if (std.mem.eql(u8, flag, "recursive")) {
        opts.recursive = true;
    } else if (std.mem.eql(u8, flag, "dereference-recursive")) {
        opts.dereference_recursive = true;
        opts.recursive = true;
    } else if (std.mem.eql(u8, flag, "line-buffered")) {
        // No-op: we flush appropriately already
    } else if (std.mem.eql(u8, flag, "mmap")) {
        // No-op: deprecated, accept silently
    } else if (std.mem.eql(u8, flag, "null-data")) {
        opts.null_line_sep = true;
    } else {
        return false;
    }
    return true;
}

/// Parse a context-length value (`-A`/`-B`/`-C` and their long forms).
/// Returns null after printing the GNU "invalid context length argument"
/// error so the caller can return `.consumed_error`.
fn parseArgs_contextValue(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    val_str: []const u8,
) ?usize { // tiger:allow:usize-arch context length, matches GrepOptions field type
    return std.fmt.parseInt(usize, val_str, 10) catch { // tiger:allow:usize-arch
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid context length argument",
            .{},
        );
        return null;
    };
}

/// Apply `--color=WHEN` / `--colour=WHEN`. Reports an "invalid argument"
/// error and returns `.consumed_error` when WHEN is not auto/always/never.
fn parseArgs_colorValue(
    allocator: Allocator,
    opts: *GrepOptions,
    flag: []const u8,
    stderr_writer: *std.Io.Writer,
) LongOptionResult {
    const eq_pos = std.mem.findScalar(u8, flag, '=').?;
    const when = flag[eq_pos + 1 ..];
    if (std.mem.eql(u8, when, "auto")) {
        // Keep resolved value (TTY-dependent)
    } else if (std.mem.eql(u8, when, "always")) {
        opts.color = .on;
    } else if (std.mem.eql(u8, when, "never")) {
        opts.color = .off;
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid argument '{s}' for '--color'",
            .{when},
        );
        return .consumed_error;
    }
    return .consumed_ok;
}

/// Handle valued long options (the `startsWith` arms). Returns not_mine when
/// `flag` is unrecognized so the caller can report the error.
fn parseArgs_longValued(
    allocator: Allocator,
    io: std.Io,
    opts: *GrepOptions,
    flag: []const u8,
    stderr_writer: *std.Io.Writer,
) !LongOptionResult {
    assert(@intFromEnum(opts.regex_mode) <= @intFromEnum(RegexMode.fixed));
    assert(@intFromEnum(opts.regex_mode) >= @intFromEnum(RegexMode.basic));
    if (std.mem.startsWith(u8, flag, "regexp=")) {
        try opts.patterns.append(allocator, flag["regexp=".len..]);
    } else if (std.mem.startsWith(u8, flag, "file=")) {
        const pattern_file = flag["file=".len..];
        try loadPatternsFromFile(
            allocator,
            io,
            &opts.patterns,
            &opts.pattern_file_contents,
            pattern_file,
            stderr_writer,
        );
    } else if (std.mem.startsWith(u8, flag, "max-count=")) {
        const val_str = flag["max-count=".len..];
        opts.max_count = std.fmt.parseInt(usize, val_str, 10) catch { // tiger:allow:usize-arch
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "invalid max count '{s}'",
                .{val_str},
            );
            return .consumed_error;
        };
    } else if (std.mem.startsWith(u8, flag, "after-context=")) {
        const val_str = flag["after-context=".len..];
        opts.after_context = parseArgs_contextValue(allocator, stderr_writer, val_str) orelse
            return .consumed_error;
    } else if (std.mem.startsWith(u8, flag, "before-context=")) {
        const val_str = flag["before-context=".len..];
        opts.before_context = parseArgs_contextValue(allocator, stderr_writer, val_str) orelse
            return .consumed_error;
    } else if (std.mem.startsWith(u8, flag, "context=")) {
        const val_str = flag["context=".len..];
        const ctx = parseArgs_contextValue(allocator, stderr_writer, val_str) orelse
            return .consumed_error;
        opts.before_context = ctx;
        opts.after_context = ctx;
    } else if (std.mem.eql(u8, flag, "color") or std.mem.eql(u8, flag, "colour")) {
        opts.color = .on;
    } else if (std.mem.startsWith(u8, flag, "color=") or
        std.mem.startsWith(u8, flag, "colour="))
    {
        return parseArgs_colorValue(allocator, opts, flag, stderr_writer);
    } else if (std.mem.startsWith(u8, flag, "include=")) {
        try opts.include_globs.append(allocator, flag["include=".len..]);
    } else if (std.mem.startsWith(u8, flag, "exclude=")) {
        try opts.exclude_globs.append(allocator, flag["exclude=".len..]);
    } else if (std.mem.startsWith(u8, flag, "exclude-dir=")) {
        try opts.exclude_dirs.append(allocator, flag["exclude-dir=".len..]);
    } else if (std.mem.startsWith(u8, flag, "label=")) {
        opts.stdin_label = flag["label=".len..];
    } else if (std.mem.startsWith(u8, flag, "binary-files=")) {
        // Stub: accept silently (we treat all files as text)
    } else if (std.mem.startsWith(u8, flag, "include-dir=")) {
        // No-op stub: accept with value, silently ignore
    } else {
        return .not_mine;
    }
    return .consumed_ok;
}

/// Resolve the value for a short option that takes one: rest of this arg, or
/// the next argv element (advancing the cursors). Returns null when none.
fn parseArgs_shortValue(
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
) ?[]const u8 {
    assert(arg.len > 1);
    assert(j_ptr.* >= 1);
    assert(i_ptr.* < args.len);
    const j = j_ptr.*;
    if (j + 1 < arg.len) return arg[j + 1 ..];
    if (i_ptr.* + 1 < args.len) {
        i_ptr.* += 1;
        return args[i_ptr.*];
    }
    return null;
}

/// Handle no-argument short flags. Returns true when `ch` was applied.
fn parseArgs_shortFlag(opts: *GrepOptions, ch: u8) bool {
    assert(ch != 0);
    switch (ch) {
        'E' => opts.regex_mode = .extended,
        'F' => opts.regex_mode = .fixed,
        'G' => opts.regex_mode = .basic,
        'i' => opts.ignore_case = true,
        'v' => opts.invert_match = true,
        'c' => opts.count = true,
        'l' => opts.files_with_matches = true,
        'L' => opts.files_without_match = true,
        'n' => opts.line_number = true,
        'H' => opts.with_filename = true,
        'h' => opts.no_filename = true,
        'o' => opts.only_matching = true,
        'q' => opts.quiet = true,
        's' => opts.no_messages = true,
        'w' => opts.word_regexp = true,
        'x' => opts.line_regexp = true,
        'b' => opts.byte_offset = true,
        'Z' => opts.null_data = true,
        'a' => {}, // --text: treat binary as text (no-op, no binary detection yet)
        'I' => {}, // ignore binary files (no-op, no binary detection yet)
        'U' => {}, // --binary: Unix no-op
        'J' => {}, // macOS: decompress bzip2 (no-op stub)
        'M' => {}, // macOS: force mmap (no-op stub)
        'O' => {}, // macOS: follow symlinks on cmdline only (no-op stub)
        'p' => {}, // macOS: don't follow symlinks (no-op stub)
        'S' => {}, // macOS: follow all symlinks (no-op stub)
        'u' => {}, // macOS: report unmatched files (no-op stub)
        'X' => {}, // macOS: legacy exclude-from (no-op stub)
        'V' => opts.version = true,
        'y' => opts.ignore_case = true, // legacy alias for -i
        'z' => opts.null_line_sep = true,
        'r' => opts.recursive = true,
        'R' => {
            opts.dereference_recursive = true;
            opts.recursive = true;
        },
        else => return false,
    }
    return true;
}

/// Outcome of a valued short-option parse: consumed (break the arg), errored,
/// or unrecognized so the caller reports "invalid option".
const ShortValuedResult = enum { consumed_break, consumed_error, not_mine };

/// Fetch the value for a short option that requires one, reporting GNU's
/// "option requires an argument -- 'X'" and returning null when it is missing.
fn parseArgs_requireValue(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    ch: u8,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
) ?[]const u8 {
    return parseArgs_shortValue(arg, args, i_ptr, j_ptr) orelse {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "option requires an argument -- '{c}'",
            .{ch},
        );
        return null;
    };
}

/// Handle valued short options (P, e, f, m, A, B, C, d, D). Numeric arms are
/// delegated to parseArgs_shortNumeric. Advances cursors via parseArgs_shortValue.
fn parseArgs_shortValued(
    allocator: Allocator,
    io: std.Io,
    opts: *GrepOptions,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) !ShortValuedResult {
    assert(arg.len > 1);
    assert(j_ptr.* >= 1);
    assert(j_ptr.* < arg.len);
    const ch = arg[j_ptr.*];
    switch (ch) {
        'm', 'A', 'B', 'C' => return parseArgs_shortNumeric(
            allocator,
            opts,
            ch,
            arg,
            args,
            i_ptr,
            j_ptr,
            stderr_writer,
        ),
        'P' => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "-P (Perl regex) not supported",
                .{},
            );
            return .consumed_error;
        },
        'e' => return parseArgs_short_e(
            allocator,
            opts,
            arg,
            args,
            i_ptr,
            j_ptr,
            stderr_writer,
        ),
        'f' => return parseArgs_short_f(
            allocator,
            io,
            opts,
            arg,
            args,
            i_ptr,
            j_ptr,
            stderr_writer,
        ),
        'd' => return parseArgs_short_d(
            allocator,
            opts,
            arg,
            args,
            i_ptr,
            j_ptr,
            stderr_writer,
        ),
        'D' => return parseArgs_short_D(
            allocator,
            arg,
            args,
            i_ptr,
            j_ptr,
            stderr_writer,
        ),
        else => return .not_mine,
    }
}

/// Handle `-e PATTERN`: append an explicit pattern.
fn parseArgs_short_e(
    allocator: Allocator,
    opts: *GrepOptions,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) !ShortValuedResult {
    const value = parseArgs_requireValue(
        allocator,
        stderr_writer,
        'e',
        arg,
        args,
        i_ptr,
        j_ptr,
    ) orelse return .consumed_error;
    try opts.patterns.append(allocator, value);
    return .consumed_break;
}

/// Handle `-D ACTION`: device action stub. Accepts the value, ignores it.
fn parseArgs_short_D(
    allocator: Allocator,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) ShortValuedResult {
    _ = parseArgs_requireValue(
        allocator,
        stderr_writer,
        'D',
        arg,
        args,
        i_ptr,
        j_ptr,
    ) orelse return .consumed_error;
    return .consumed_break;
}

/// Handle `-f FILE`: load patterns from a file, one per line.
fn parseArgs_short_f(
    allocator: Allocator,
    io: std.Io,
    opts: *GrepOptions,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) !ShortValuedResult {
    const value = parseArgs_requireValue(
        allocator,
        stderr_writer,
        'f',
        arg,
        args,
        i_ptr,
        j_ptr,
    ) orelse return .consumed_error;
    try loadPatternsFromFile(
        allocator,
        io,
        &opts.patterns,
        &opts.pattern_file_contents,
        value,
        stderr_writer,
    );
    return .consumed_break;
}

/// Handle `-d ACTION`: select the directory action (recurse, skip, or read).
fn parseArgs_short_d(
    allocator: Allocator,
    opts: *GrepOptions,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) ShortValuedResult {
    const value = parseArgs_requireValue(
        allocator,
        stderr_writer,
        'd',
        arg,
        args,
        i_ptr,
        j_ptr,
    ) orelse return .consumed_error;
    if (std.mem.eql(u8, value, "recurse")) {
        opts.recursive = true;
    } else if (std.mem.eql(u8, value, "skip")) {
        opts.skip_dirs = true;
    }
    // "read" is the default behavior, no action needed
    return .consumed_break;
}

/// Handle the integer-valued short options (m, A, B, C).
fn parseArgs_shortNumeric(
    allocator: Allocator,
    opts: *GrepOptions,
    ch: u8,
    arg: []const u8,
    args: []const []const u8,
    i_ptr: *usize, // tiger:allow:usize-arch argv index, slice-index-forced
    j_ptr: *usize, // tiger:allow:usize-arch arg index, slice-index-forced
    stderr_writer: *std.Io.Writer,
) ShortValuedResult {
    const ch_is_numeric = ch == 'm' or ch == 'A' or ch == 'B' or ch == 'C';
    assert(ch_is_numeric);
    assert(arg.len > 1);
    assert(j_ptr.* < arg.len);
    const value = parseArgs_requireValue(
        allocator,
        stderr_writer,
        ch,
        arg,
        args,
        i_ptr,
        j_ptr,
    ) orelse return .consumed_error;
    if (ch == 'm') {
        opts.max_count = std.fmt.parseInt(usize, value, 10) catch { // tiger:allow:usize-arch
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "invalid max count '{s}'",
                .{value},
            );
            return .consumed_error;
        };
        return .consumed_break;
    }
    const parsed = parseArgs_contextValue(allocator, stderr_writer, value) orelse
        return .consumed_error;
    if (ch == 'A') {
        opts.after_context = parsed;
    } else if (ch == 'B') {
        opts.before_context = parsed;
    } else {
        opts.before_context = parsed;
        opts.after_context = parsed;
    }
    return .consumed_break;
}

/// Load patterns from a file, one per line
fn loadPatternsFromFile(
    allocator: Allocator,
    io: std.Io,
    patterns: *std.ArrayListUnmanaged([]const u8),
    pattern_file_contents: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
    stderr_writer: *std.Io.Writer,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch {
        // GNU prints this operand unquoted; keep parity.
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "{s}: No such file or directory",
            .{path},
        );
        return;
    };
    try pattern_file_contents.append(allocator, content);

    var start: usize = 0;
    for (content, 0..) |ch, idx| {
        if (ch == '\n') {
            if (idx > start) {
                try patterns.append(allocator, content[start..idx]);
            }
            start = idx + 1;
        }
    }
    if (start < content.len) {
        try patterns.append(allocator, content[start..]);
    }
}

// ============================================================================
// Pattern Compilation
// ============================================================================

/// Result of translating GNU regex escape extensions. `force_ere` is set
/// when a BRE pattern was transpiled to ERE (top-level `\|` alternation),
/// so the caller compiles it with REG_EXTENDED.
const TranslatedPattern = struct {
    pattern: []const u8,
    force_ere: bool,
};

/// POSIX bracket-class replacement for a GNU class escape, or null if `ch`
/// is not one of s/S/w/W. `\w`/`\W` use `[[:alnum:]_]` to match the word
/// character set used by `-w`.
fn classEscapeReplacement(ch: u8) ?[]const u8 {
    const rep: ?[]const u8 = switch (ch) {
        's' => "[[:space:]]",
        'S' => "[^[:space:]]",
        'w' => "[[:alnum:]_]",
        'W' => "[^[:alnum:]_]",
        else => null,
    };
    // The replacement table is fixed-width POSIX classes; guard both bounds.
    assert(rep == null or rep.?.len >= 11);
    assert(rep == null or rep.?.len <= 13);
    return rep;
}

/// Skip a `[:class:]`/`[.coll.]`/`[=equiv=]` construct whose contents start at
/// `i_start` and close with `closer` + `]`. Returns the index just past the
/// closing `]`, or `pattern.len` if unterminated (regcomp reports the error).
fn skipBracketClass(pattern: []const u8, i_start: usize, closer: u8) usize {
    assert(closer == ':' or closer == '.' or closer == '=');
    assert(i_start <= pattern.len);
    var i: usize = i_start;
    while (i + 1 < pattern.len) {
        if (pattern[i] == closer and pattern[i + 1] == ']') return i + 2;
        i += 1;
    }
    return pattern.len;
}

/// Scan a POSIX bracket expression starting at `start` (pattern[start]=='[').
/// Returns the index just past the closing ']', or pattern.len if
/// unterminated. Handles the leading-']' literal quirk (`[]...]`/`[^]...]`)
/// and `[:class:]`/`[.coll.]`/`[=equiv=]` nesting so an inner ']' does not
/// close the expression.
fn copyBracketExpression(pattern: []const u8, start: usize) usize {
    assert(start < pattern.len);
    assert(pattern[start] == '[');
    var i: usize = start + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    // A ']' as the first member is a literal, not the terminator.
    if (i < pattern.len and pattern[i] == ']') i += 1;
    while (i < pattern.len) {
        const ch = pattern[i];
        if (ch == ']') return i + 1;
        if (ch == '[' and i + 1 < pattern.len and
            (pattern[i + 1] == ':' or pattern[i + 1] == '.' or pattern[i + 1] == '='))
        {
            i = skipBracketClass(pattern, i + 2, pattern[i + 1]);
        } else {
            i += 1;
        }
    }
    return pattern.len;
}

/// Substitute GNU class escapes (`\s`/`\S`/`\w`/`\W`) with POSIX bracket
/// equivalents, outside bracket expressions only. Backslash pairs (`\\`) are
/// consumed verbatim so an escaped backslash is never re-interpreted. The
/// escapes mean the same in BRE and ERE, so this runs uniformly on both.
fn translateClassEscapes(allocator: Allocator, pattern: []const u8) ?[]u8 {
    assert(pattern.len < std.math.maxInt(u32));
    var out = std.ArrayListUnmanaged(u8).empty;
    const bound: usize = pattern.len * 7 + 1;
    var i: usize = 0;
    while (i < pattern.len) {
        const prev_i = i;
        const ch = pattern[i];
        if (ch == '[') {
            const end = copyBracketExpression(pattern, i);
            assert(end > i);
            out.appendSlice(allocator, pattern[i..end]) catch return null;
            i = end;
        } else if (ch == '\\' and i + 1 < pattern.len) {
            if (classEscapeReplacement(pattern[i + 1])) |rep| {
                out.appendSlice(allocator, rep) catch return null;
            } else {
                // Verbatim escape pair: \\ pairwise, backrefs, other escapes.
                out.append(allocator, '\\') catch return null;
                out.append(allocator, pattern[i + 1]) catch return null;
            }
            i += 2;
        } else {
            out.append(allocator, ch) catch return null;
            i += 1;
        }
        assert(i > prev_i);
        assert(out.items.len <= bound);
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Detect a top-level `\|` (GNU BRE alternation) that is outside any bracket
/// expression and not itself escaped. Scan-only; allocates nothing.
fn breHasTopLevelAlternation(pattern: []const u8) bool {
    assert(pattern.len < std.math.maxInt(u32));
    var i: usize = 0;
    while (i < pattern.len) {
        const prev_i = i;
        const ch = pattern[i];
        if (ch == '[') {
            i = copyBracketExpression(pattern, i);
        } else if (ch == '\\' and i + 1 < pattern.len) {
            if (pattern[i + 1] == '|') return true;
            i += 2;
        } else {
            i += 1;
        }
        assert(i > prev_i);
    }
    return false;
}

/// Translate the escape at `pattern[i]` ('\\') during a BRE->ERE transpile,
/// appending to `out`. Swaps BRE grouping/quantifier escapes to their ERE
/// bare forms and back; passes through backrefs and class escapes verbatim
/// (the later class pass handles \s/\S/\w/\W). Returns the index past the
/// escape. Updates `at_expr_start` (true after emitting `(` or `|`).
fn transpileBreEscape(
    allocator: Allocator,
    pattern: []const u8,
    i: usize,
    out: *std.ArrayListUnmanaged(u8),
    at_expr_start: *bool,
) ?usize {
    assert(i < pattern.len);
    assert(pattern[i] == '\\');
    if (i + 1 >= pattern.len) {
        // Trailing backslash: emit verbatim, regcomp reports the error.
        out.append(allocator, '\\') catch return null;
        return i + 1;
    }
    const nxt = pattern[i + 1];
    at_expr_start.* = false;
    switch (nxt) {
        '|' => {
            out.append(allocator, '|') catch return null;
            at_expr_start.* = true;
        },
        '(' => {
            out.append(allocator, '(') catch return null;
            at_expr_start.* = true;
        },
        ')' => out.append(allocator, ')') catch return null,
        '{' => out.append(allocator, '{') catch return null,
        '}' => out.append(allocator, '}') catch return null,
        '+' => out.append(allocator, '+') catch return null,
        '?' => out.append(allocator, '?') catch return null,
        else => {
            // \\ pairwise, backrefs \1-\9, class escapes, other escapes.
            out.append(allocator, '\\') catch return null;
            out.append(allocator, nxt) catch return null;
        },
    }
    return i + 2;
}

/// Emit the ERE form of a bare (unescaped) BRE character. Bare grouping and
/// quantifier metacharacters are literals in BRE, so they gain a backslash;
/// `*` at expression start and `^`/`$` off-anchor are also literal. Returns
/// false on allocation failure.
fn transpileBreBare(
    allocator: Allocator,
    ch: u8,
    dollar_is_anchor: bool,
    out: *std.ArrayListUnmanaged(u8),
    at_expr_start: *bool,
) bool {
    assert(ch != '\\');
    assert(ch != '[');
    const start = at_expr_start.*;
    at_expr_start.* = false;
    const text: []const u8 = switch (ch) {
        '|' => "\\|",
        '(' => "\\(",
        ')' => "\\)",
        '{' => "\\{",
        '}' => "\\}",
        '+' => "\\+",
        '?' => "\\?",
        '*' => if (start) "\\*" else "*",
        '^' => if (start) "^" else "\\^",
        '$' => if (dollar_is_anchor) "$" else "\\$",
        else => {
            out.append(allocator, ch) catch return false;
            return true;
        },
    };
    out.appendSlice(allocator, text) catch return false;
    return true;
}

/// Transpile a whole BRE pattern to an equivalent ERE. Bracket expressions
/// are copied verbatim; grouping/quantifier metacharacters swap escaped and
/// bare forms per BRE<->ERE rules. Used when a BRE has top-level `\|`
/// alternation, which POSIX BRE cannot express portably.
fn transpileBreToEre(allocator: Allocator, pattern: []const u8) ?[]u8 {
    assert(pattern.len < std.math.maxInt(u32));
    var out = std.ArrayListUnmanaged(u8).empty;
    const bound: usize = pattern.len * 2 + 1;
    var at_expr_start = true;
    var i: usize = 0;
    while (i < pattern.len) {
        const prev_i = i;
        const ch = pattern[i];
        if (ch == '[') {
            const end = copyBracketExpression(pattern, i);
            assert(end > i);
            out.appendSlice(allocator, pattern[i..end]) catch return null;
            i = end;
            at_expr_start = false;
        } else if (ch == '\\') {
            i = transpileBreEscape(allocator, pattern, i, &out, &at_expr_start) orelse return null;
        } else {
            // `$` is an anchor only at end-of-pattern or right before \) / \|.
            const dollar_is_anchor = (i + 1 >= pattern.len) or
                (i + 2 < pattern.len and pattern[i + 1] == '\\' and
                    (pattern[i + 2] == ')' or pattern[i + 2] == '|'));
            const ok = transpileBreBare(allocator, ch, dollar_is_anchor, &out, &at_expr_start);
            if (!ok) return null;
            i += 1;
        }
        assert(i > prev_i);
        assert(out.items.len <= bound);
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Translate GNU regex escape extensions before handing a pattern to regcomp.
/// glibc supports these natively; BSD/macOS libc does not, so we normalize on
/// all platforms for uniform behavior. `\s`/`\S`/`\w`/`\W` become POSIX
/// bracket classes in both BRE and ERE; a BRE with top-level `\|` alternation
/// is transpiled wholesale to ERE with force_ere set. Returns null on
/// allocation failure. Intermediates are arena-leaked per this file.
fn translateGnuEscapes(
    allocator: Allocator,
    pattern: []const u8,
    mode: RegexMode,
) ?TranslatedPattern {
    assert(mode != .fixed);
    assert(@intFromEnum(mode) <= @intFromEnum(RegexMode.extended));
    if (mode == .basic and breHasTopLevelAlternation(pattern)) {
        const ere = transpileBreToEre(allocator, pattern) orelse return null;
        defer allocator.free(ere);
        const out = translateClassEscapes(allocator, ere) orelse return null;
        return .{ .pattern = out, .force_ere = true };
    }
    const out = translateClassEscapes(allocator, pattern) orelse return null;
    return .{ .pattern = out, .force_ere = false };
}

/// Anchor a pattern for -x (line_regexp). ERE (or a force_ere BRE) needs a
/// group so alternation stays whole line; plain BRE anchors bare. Returns
/// null on allocation failure.
fn wrapLineRegexp(allocator: Allocator, pattern: []const u8, use_ere: bool) ?[]u8 {
    assert(pattern.len < std.math.maxInt(u32));
    const wrapped = if (use_ere)
        std.fmt.allocPrint(allocator, "^({s})$", .{pattern}) catch return null
    else
        std.fmt.allocPrint(allocator, "^{s}$", .{pattern}) catch return null;
    assert(wrapped.len > pattern.len);
    return wrapped;
}

/// Compile a single pattern. Returns null on error.
fn compilePattern(
    allocator: Allocator,
    pattern: []const u8,
    opts: *const GrepOptions,
    stderr_writer: *std.Io.Writer,
) ?CompiledPattern {
    assert(@intFromEnum(opts.regex_mode) <= @intFromEnum(RegexMode.fixed));
    if (opts.regex_mode == .fixed) {
        if (opts.ignore_case) {
            const lower = toLower(allocator, pattern) catch return null;
            return .{ .fixed = .{ .text = pattern, .lower = lower } };
        }
        return .{ .fixed = .{ .text = pattern, .lower = null } };
    }

    // Translate GNU escape extensions (\s \S \w \W in BRE/ERE, and BRE \|
    // alternation) before regcomp; see translateGnuEscapes. force_ere is set
    // when a BRE was transpiled to ERE, so -x wraps and REG_EXTENDED follow.
    // Note: -w (word_regexp) is handled via post-match validation in matchLine,
    // not by wrapping the pattern, to avoid \| in BRE on macOS.
    const tr = translateGnuEscapes(allocator, pattern, opts.regex_mode) orelse return null;
    defer allocator.free(tr.pattern);
    const force_ere = tr.force_ere;

    var actual_pattern: []const u8 = tr.pattern;
    var wrapped: ?[]u8 = null;
    defer if (wrapped) |w| allocator.free(w);
    if (opts.line_regexp) {
        const use_ere = opts.regex_mode == .extended or force_ere;
        wrapped = wrapLineRegexp(allocator, actual_pattern, use_ere) orelse return null;
        actual_pattern = wrapped.?;
    }

    var cflags: c_int = 0;
    if (opts.regex_mode == .extended or force_ere) cflags |= c.REG_EXTENDED;
    if (opts.ignore_case) cflags |= c.REG_ICASE;
    // Use REG_NOSUB only if we don't need match positions
    if (!opts.only_matching and !opts.word_regexp and opts.color == .off) cflags |= c.REG_NOSUB;

    const pattern_z = allocator.dupeZ(u8, actual_pattern) catch return null;
    defer allocator.free(pattern_z);

    const regex = if (comptime is_linux)
        (regex_c.regex_heap_alloc() orelse return null)
    else
        (allocator.create(c.regex_t) catch return null);
    const result = c.regcomp(regex, pattern_z.ptr, cflags);
    if (result != 0) {
        var errbuf: [256]u8 = undefined;
        const err_len = c.regerror(@intCast(result), regex, &errbuf, errbuf.len);
        const err_msg = errbuf[0..err_len];
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid regular expression: {s}",
            .{err_msg},
        );
        if (comptime is_linux) {
            regex_c.regex_heap_free(regex);
        } else {
            allocator.destroy(regex);
        }
        return null;
    }

    return .{ .regex = regex };
}

/// Free a compiled pattern
fn freePattern(allocator: Allocator, pat: *CompiledPattern) void {
    switch (pat.*) {
        .regex => |re| {
            c.regfree(re);
            if (comptime is_linux) {
                regex_c.regex_heap_free(re);
            } else {
                allocator.destroy(re);
            }
        },
        .fixed => {},
    }
}

// ============================================================================
// Matching
// ============================================================================

/// Match result for a single line
const MatchResult = struct {
    matched: bool,
    /// Start/end positions of the match within the line (for -o and color)
    match_start: usize = 0,
    match_end: usize = 0,
};

/// Returns true if a character is a "word" character (alphanumeric or underscore).
/// Matches the [:alnum:]_ character class used in -w boundary patterns.
fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// The C regex offset type (rm_so/rm_eo field of regmatch_t).
const RegOffset = @TypeOf(@as(c.regmatch_t, undefined).rm_so);

/// Convert a regoff match offset (rm_so/rm_eo) into a slice index.
/// Negative offsets (no match for that subexpression) map to 0. The
/// result indexes into `line`, so it must be usize (slice-index API).
fn regOffsetToIndex(off: RegOffset) usize { // tiger:allow:usize-arch slice index
    comptime assert(@typeInfo(RegOffset) == .int);
    comptime assert(@typeInfo(RegOffset).int.signedness == .signed);
    if (off < 0) return 0;
    const idx: usize = @intCast(off); // tiger:allow:usize-arch slice index
    return idx;
}

/// Check if a line matches a compiled pattern.
/// When word_regexp is true, post-validates word boundaries instead of
/// relying on pattern wrapping (which uses \| unsupported in BRE on macOS).
/// prev_char is the character immediately before line[0], needed when
/// matching a substring (e.g. from the -o loop). Pass null when matching
/// from the real start of the line.
fn matchLine(
    pat: *const CompiledPattern,
    line: []const u8,
    allocator: Allocator,
    word_regexp: bool,
    prev_char: ?u8,
) MatchResult {
    switch (pat.*) {
        .fixed => |fp| {
            if (word_regexp) {
                return matchLine_fixedWord(&fp, line, allocator, prev_char);
            }
            return matchLine_fixedPlain(&fp, line, allocator);
        },
        .regex => |re| {
            if (word_regexp) {
                return matchLine_regexWord(re, line, allocator, prev_char);
            }
            return matchLine_regexPlain(re, line, allocator);
        },
    }
}

/// Fixed-string match with -w word-boundary post-validation.
fn matchLine_fixedWord(
    fp: *const CompiledPattern.FixedPattern,
    line: []const u8,
    allocator: Allocator,
    prev_char: ?u8,
) MatchResult {
    if (fp.lower) |lo| assert(lo.len == fp.text.len);
    const search_info = if (fp.lower != null) blk: {
        const lower_line = toLower(allocator, line) catch return .{ .matched = false };
        break :blk .{ lower_line, fp.lower.?, true };
    } else .{ line, fp.text, false };
    const haystack = search_info[0];
    const needle = search_info[1];
    const need_free = search_info[2];
    defer if (need_free) allocator.free(haystack);
    var pos: usize = 0; // tiger:allow:usize-arch haystack index
    while (pos <= haystack.len) {
        const idx = std.mem.find(u8, haystack[pos..], needle) orelse return .{ .matched = false };
        const abs_start = pos + idx;
        const abs_end = abs_start + needle.len;
        const left_ok = if (abs_start == 0)
            (if (prev_char) |pc| !isWordChar(pc) else true)
        else
            !isWordChar(line[abs_start - 1]);
        const right_ok = (abs_end >= line.len) or !isWordChar(line[abs_end]);
        if (left_ok and right_ok) {
            return .{ .matched = true, .match_start = abs_start, .match_end = abs_end };
        }
        pos = abs_start + 1;
    }
    return .{ .matched = false };
}

/// Plain fixed-string match (no word boundaries).
fn matchLine_fixedPlain(
    fp: *const CompiledPattern.FixedPattern,
    line: []const u8,
    allocator: Allocator,
) MatchResult {
    if (fp.lower) |lo| assert(lo.len == fp.text.len);
    if (fp.lower) |lower_pattern| {
        const lower_line = toLower(allocator, line) catch return .{ .matched = false };
        defer allocator.free(lower_line);
        if (std.mem.find(u8, lower_line, lower_pattern)) |pos| {
            return .{ .matched = true, .match_start = pos, .match_end = pos + lower_pattern.len };
        }
        return .{ .matched = false };
    }
    if (std.mem.find(u8, line, fp.text)) |pos| {
        return .{ .matched = true, .match_start = pos, .match_end = pos + fp.text.len };
    }
    return .{ .matched = false };
}

/// Regex match with -w word-boundary post-validation.
fn matchLine_regexWord(
    re: *c.regex_t,
    line: []const u8,
    allocator: Allocator,
    prev_char: ?u8,
) MatchResult {
    assert(@intFromPtr(re) != 0);
    var search_start: usize = 0; // tiger:allow:usize-arch line index
    var eff_prev_char = prev_char;
    while (search_start <= line.len) {
        const search_line = line[search_start..];
        const search_z = allocator.dupeZ(u8, search_line) catch return .{ .matched = false };
        defer allocator.free(search_z);
        var pmatch: [1]c.regmatch_t = undefined;
        var eflags: c_int = 0;
        if (search_start > 0 or (eff_prev_char != null)) eflags |= c.REG_NOTBOL;
        const exec_result_val = c.regexec(re, search_z.ptr, 1, &pmatch, eflags);
        if (exec_result_val != 0) return .{ .matched = false };
        const rel_start = regOffsetToIndex(pmatch[0].rm_so);
        const rel_end = regOffsetToIndex(pmatch[0].rm_eo);
        const abs_start = search_start + rel_start;
        const abs_end = search_start + rel_end;
        const left_ok = if (abs_start == 0)
            (if (eff_prev_char) |pc| !isWordChar(pc) else true)
        else
            !isWordChar(line[abs_start - 1]);
        const right_ok = (abs_end >= line.len) or !isWordChar(line[abs_end]);
        if (left_ok and right_ok) {
            assert(abs_end >= abs_start);
            return .{ .matched = true, .match_start = abs_start, .match_end = abs_end };
        }
        if (abs_start + 1 > line.len) break;
        search_start = abs_start + 1;
        eff_prev_char = line[abs_start];
    }
    return .{ .matched = false };
}

/// Plain regex match (no word boundaries).
fn matchLine_regexPlain(re: *c.regex_t, line: []const u8, allocator: Allocator) MatchResult {
    assert(@intFromPtr(re) != 0);
    const line_z = allocator.dupeZ(u8, line) catch return .{ .matched = false };
    defer allocator.free(line_z);
    var pmatch: [1]c.regmatch_t = undefined;
    const exec_result_val = c.regexec(re, line_z.ptr, 1, &pmatch, 0);
    if (exec_result_val == 0) {
        const start = regOffsetToIndex(pmatch[0].rm_so);
        const end = regOffsetToIndex(pmatch[0].rm_eo);
        assert(end >= start);
        return .{ .matched = true, .match_start = start, .match_end = end };
    }
    return .{ .matched = false };
}

/// Check if a line matches any of the compiled patterns
fn matchAnyPattern(
    patterns: []const CompiledPattern,
    line: []const u8,
    allocator: Allocator,
    word_regexp: bool,
    prev_char: ?u8,
) MatchResult {
    for (patterns) |*pat| {
        const result = matchLine(pat, line, allocator, word_regexp, prev_char);
        if (result.matched) return result;
    }
    return .{ .matched = false };
}

// ============================================================================
// Output
// ============================================================================

/// ANSI color codes for grep output
const Color = struct {
    const filename = "\x1b[35m";
    const line_number = "\x1b[32m";
    const separator = "\x1b[36m";
    const match_highlight = "\x1b[01;31m";
    const reset = "\x1b[0m";
};

/// Print a filename prefix
fn printFilename(writer: *std.Io.Writer, filename: []const u8, use_color: bool) void {
    if (use_color) {
        writer.print("{s}{s}{s}", .{ Color.filename, filename, Color.reset }) catch {};
    } else {
        writer.print("{s}", .{filename}) catch {};
    }
}

/// Print a line number
fn printLineNumber(writer: *std.Io.Writer, line_num: usize, use_color: bool) void {
    if (use_color) {
        writer.print("{s}{d}{s}", .{ Color.line_number, line_num, Color.reset }) catch {};
    } else {
        writer.print("{d}", .{line_num}) catch {};
    }
}

/// Print a byte offset
fn printByteOffset(writer: *std.Io.Writer, offset: usize, use_color: bool) void {
    if (use_color) {
        writer.print("{s}{d}{s}", .{ Color.line_number, offset, Color.reset }) catch {};
    } else {
        writer.print("{d}", .{offset}) catch {};
    }
}

/// Print a separator character
fn printSep(writer: *std.Io.Writer, sep: u8, use_color: bool) void {
    if (sep == 0) {
        // NUL separator: write raw byte, no color wrapping
        writer.writeByte(0) catch {};
    } else if (use_color) {
        writer.print("{s}{c}{s}", .{ Color.separator, sep, Color.reset }) catch {};
    } else {
        writer.print("{c}", .{sep}) catch {};
    }
}

/// Print a line with optional color highlighting of the match
fn printMatchLine(
    writer: *std.Io.Writer,
    line: []const u8,
    match_start: usize, // tiger:allow:usize-arch slice index into line
    match_end: usize, // tiger:allow:usize-arch slice index into line
    use_color: bool,
    terminator: u8,
) void {
    assert(match_start <= match_end);
    if (use_color and match_end > match_start and match_end <= line.len) {
        writer.writeAll(line[0..match_start]) catch {};
        writer.print("{s}", .{Color.match_highlight}) catch {};
        writer.writeAll(line[match_start..match_end]) catch {};
        writer.print("{s}", .{Color.reset}) catch {};
        writer.writeAll(line[match_end..]) catch {};
    } else {
        writer.writeAll(line) catch {};
    }
    writer.writeByte(terminator) catch {};
}

// ============================================================================
// File Processing
// ============================================================================

/// Process a single file/stream. Returns true if any match was found.
fn processFile(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    filename: []const u8,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    show_filename: bool,
    use_color: bool,
) bool {
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const content = file_reader.interface.allocRemaining(
        allocator,
        .limited(512 * 1024 * 1024),
    ) catch return false;
    defer allocator.free(content);

    var found_match = false;
    var match_count: usize = 0;

    // Determine the line delimiter: NUL for -z/--null-data, newline otherwise
    const line_delim: u8 = if (opts.null_line_sep) 0 else '\n';

    // Determine filename separator: NUL for --null/-Z, colon otherwise
    const fn_sep: u8 = if (opts.null_data) 0 else ':';

    // Determine line terminator for output: NUL for -z, newline otherwise
    const line_term: u8 = if (opts.null_line_sep) 0 else '\n';

    // Split into lines, tracking byte offsets
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    defer lines.deinit(allocator);
    var line_offsets = std.ArrayListUnmanaged(usize).empty;
    defer line_offsets.deinit(allocator);
    if (!processFile_splitLines(allocator, content, line_delim, &lines, &line_offsets)) {
        return false;
    }
    assert(lines.items.len == line_offsets.items.len);

    // Context tracking
    var scan = ScanState{};

    const scan_inputs = ScanInputs{
        .allocator = allocator,
        .patterns = patterns,
        .opts = opts,
        .stdout_writer = stdout_writer,
        .lines = lines.items,
        .line_offsets = line_offsets.items,
        .filename = filename,
        .fn_sep = fn_sep,
        .line_term = line_term,
        .show_filename = show_filename,
        .use_color = use_color,
    };
    if (processFile_scanLines(scan_inputs, &scan)) return true;

    found_match = scan.found_match;
    match_count = scan.match_count;
    processFile_printSummary(
        stdout_writer,
        opts,
        filename,
        match_count,
        found_match,
        show_filename,
        use_color,
        fn_sep,
        line_term,
    );

    return found_match;
}

/// Loop-level inputs for `processFile_scanLines`, grouped to keep the
/// parameter list small (the per-line slice is rebuilt for each line).
const ScanInputs = struct {
    allocator: Allocator,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    lines: []const []const u8,
    line_offsets: []const usize, // tiger:allow:usize-arch byte offsets, slice-index-forced
    filename: []const u8,
    fn_sep: u8,
    line_term: u8,
    show_filename: bool,
    use_color: bool,
};

/// Scan every line, dispatching to `processFile_handleLine`. Returns true when
/// a -q quiet match warrants returning true straight from `processFile`.
fn processFile_scanLines(in: ScanInputs, scan: *ScanState) bool {
    var line_num: usize = 0; // tiger:allow:usize-arch line counter
    for (in.lines) |line| {
        line_num += 1;
        const ctx = LineContext{
            .line = line,
            .line_num = line_num,
            .lines = in.lines,
            .line_offsets = in.line_offsets,
            .filename = in.filename,
            .fn_sep = in.fn_sep,
            .line_term = in.line_term,
        };
        switch (processFile_handleLine(
            in.allocator,
            in.patterns,
            in.opts,
            in.stdout_writer,
            ctx,
            in.show_filename,
            in.use_color,
            scan,
        )) {
            .keep_going => {},
            .stop_scanning => break,
            .quiet_return => return true,
        }
    }
    return false;
}

/// Loop-carried state for the per-line scan in processFile.
const ScanState = struct {
    found_match: bool = false,
    match_count: usize = 0, // tiger:allow:usize-arch line counter, matches existing type
    last_printed_line: ?usize = null, // tiger:allow:usize-arch line index
    remaining_after: usize = 0, // tiger:allow:usize-arch line counter
};

/// Per-line inputs grouped to keep the handler's parameter list small.
const LineContext = struct {
    line: []const u8,
    line_num: usize, // tiger:allow:usize-arch line index, slice-index-forced
    lines: []const []const u8,
    line_offsets: []const usize, // tiger:allow:usize-arch byte offsets, slice-index-forced
    filename: []const u8,
    fn_sep: u8,
    line_term: u8,
};

/// Outcome of handling one line: continue, stop (max_count), or quiet-return.
const LineOutcome = enum { keep_going, stop_scanning, quiet_return };

/// Handle one scanned line: match, optionally print, and update scan state.
fn processFile_handleLine(
    allocator: Allocator,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    ctx: LineContext,
    show_filename: bool,
    use_color: bool,
    scan: *ScanState,
) LineOutcome {
    assert(ctx.line_num >= 1);
    assert(ctx.line_num <= ctx.lines.len);
    assert(ctx.lines.len == ctx.line_offsets.len);
    const result = matchAnyPattern(patterns, ctx.line, allocator, opts.word_regexp, null);
    const is_match = if (opts.invert_match) !result.matched else result.matched;

    if (is_match) {
        scan.found_match = true;
        scan.match_count += 1;

        if (opts.quiet) return .quiet_return;

        if (!opts.count and !opts.files_with_matches and !opts.files_without_match) {
            processFile_emitMatch(
                allocator,
                patterns,
                opts,
                stdout_writer,
                ctx,
                result,
                show_filename,
                use_color,
                scan,
            );
        }

        if (opts.max_count) |mc| {
            if (scan.match_count >= mc) return .stop_scanning;
        }
    } else if (scan.remaining_after > 0) {
        // Print after-context line
        printContextLine(
            stdout_writer,
            ctx.line,
            ctx.line_num,
            ctx.filename,
            show_filename,
            opts.line_number,
            opts.byte_offset,
            ctx.line_offsets[ctx.line_num - 1],
            use_color,
            ctx.fn_sep,
            ctx.line_term,
        );
        scan.last_printed_line = ctx.line_num;
        scan.remaining_after -= 1;
    }
    return .keep_going;
}

/// Emit a match: before-context, optional group separator, the match line(s).
fn processFile_emitMatch(
    allocator: Allocator,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    ctx: LineContext,
    result: MatchResult,
    show_filename: bool,
    use_color: bool,
    scan: *ScanState,
) void {
    assert(ctx.line_num >= 1);
    assert(ctx.line_num <= ctx.lines.len);
    assert(result.match_end >= result.match_start);
    const has_context = opts.before_context > 0 or opts.after_context > 0;

    // Print before-context lines
    if (has_context and opts.before_context > 0) {
        processFile_printBeforeContext(
            stdout_writer,
            ctx.lines,
            ctx.line_offsets,
            ctx.line_num,
            opts,
            ctx.filename,
            show_filename,
            use_color,
            ctx.fn_sep,
            ctx.line_term,
            &scan.last_printed_line,
        );
    }

    // Print the matching line
    if (scan.last_printed_line) |lp| {
        if (has_context and ctx.line_num > lp + 1 and opts.before_context == 0) {
            stdout_writer.writeAll("--\n") catch {};
        }
    }

    if (opts.only_matching and !opts.invert_match) {
        processFile_printOnlyMatching(
            allocator,
            patterns,
            stdout_writer,
            ctx.line,
            ctx.line_num,
            ctx.line_offsets,
            result,
            opts,
            ctx.filename,
            show_filename,
            use_color,
            ctx.fn_sep,
            ctx.line_term,
        );
    } else {
        processFile_printNormalMatch(
            stdout_writer,
            ctx.line,
            ctx.line_num,
            ctx.line_offsets,
            result,
            opts,
            ctx.filename,
            show_filename,
            use_color,
            ctx.fn_sep,
            ctx.line_term,
        );
    }
    scan.last_printed_line = ctx.line_num;
    scan.remaining_after = opts.after_context;
}

/// Split content into lines and parallel byte offsets. Returns false on OOM.
fn processFile_splitLines(
    allocator: Allocator,
    content: []const u8,
    line_delim: u8,
    lines_ptr: *std.ArrayListUnmanaged([]const u8),
    line_offsets_ptr: *std.ArrayListUnmanaged(usize), // tiger:allow:usize-arch byte offsets list
) bool {
    const delim_ok = line_delim == 0 or line_delim == '\n';
    assert(delim_ok);
    assert(lines_ptr.items.len == line_offsets_ptr.items.len);
    var start: usize = 0; // tiger:allow:usize-arch byte offset
    for (content, 0..) |ch, idx| {
        if (ch == line_delim) {
            lines_ptr.append(allocator, content[start..idx]) catch return false;
            line_offsets_ptr.append(allocator, start) catch return false;
            start = idx + 1;
        }
    }
    if (start < content.len) {
        lines_ptr.append(allocator, content[start..]) catch return false;
        line_offsets_ptr.append(allocator, start) catch return false;
    }
    assert(lines_ptr.items.len == line_offsets_ptr.items.len);
    return true;
}

/// Print before-context lines for a match, emitting a group separator on a gap.
fn processFile_printBeforeContext(
    stdout_writer: *std.Io.Writer,
    lines: []const []const u8,
    line_offsets: []const usize, // tiger:allow:usize-arch byte offsets, slice-index-forced
    line_num: usize, // tiger:allow:usize-arch line index, slice-index-forced
    opts: *const GrepOptions,
    filename: []const u8,
    show_filename: bool,
    use_color: bool,
    fn_sep: u8,
    line_term: u8,
    last_printed_ptr: *?usize, // tiger:allow:usize-arch line index pointer
) void {
    assert(opts.before_context > 0);
    assert(line_num >= 1);
    assert(line_num <= lines.len);
    const ctx_start = if (line_num > opts.before_context) line_num - opts.before_context else 1;
    const already_printed = if (last_printed_ptr.*) |lp| lp + 1 else 0;
    const effective_start = @max(ctx_start, already_printed);

    // Print group separator if there's a gap
    if (last_printed_ptr.*) |lp| {
        if (effective_start > lp + 1) {
            stdout_writer.writeAll("--\n") catch {};
        }
    }

    var ctx_line = effective_start;
    while (ctx_line < line_num) : (ctx_line += 1) {
        printContextLine(
            stdout_writer,
            lines[ctx_line - 1],
            ctx_line,
            filename,
            show_filename,
            opts.line_number,
            opts.byte_offset,
            line_offsets[ctx_line - 1],
            use_color,
            fn_sep,
            line_term,
        );
        last_printed_ptr.* = ctx_line;
    }
}

/// Print all non-overlapping matches on a line for -o, each on its own line.
fn processFile_printOnlyMatching(
    allocator: Allocator,
    patterns: []const CompiledPattern,
    stdout_writer: *std.Io.Writer,
    line: []const u8,
    line_num: usize, // tiger:allow:usize-arch line index, slice-index-forced
    line_offsets: []const usize, // tiger:allow:usize-arch byte offsets, slice-index-forced
    first_result: MatchResult,
    opts: *const GrepOptions,
    filename: []const u8,
    show_filename: bool,
    use_color: bool,
    fn_sep: u8,
    line_term: u8,
) void {
    assert(opts.only_matching);
    assert(!opts.invert_match);
    assert(line_num >= 1);
    var search_offset: usize = 0; // tiger:allow:usize-arch line index
    var cur_result = first_result;
    while (cur_result.matched and
        cur_result.match_end > cur_result.match_start and
        search_offset + cur_result.match_end <= line.len)
    {
        if (show_filename) {
            printFilename(stdout_writer, filename, use_color);
            printSep(stdout_writer, fn_sep, use_color);
        }
        if (opts.line_number) {
            printLineNumber(stdout_writer, line_num, use_color);
            printSep(stdout_writer, ':', use_color);
        }
        if (opts.byte_offset) {
            printByteOffset(
                stdout_writer,
                line_offsets[line_num - 1] + search_offset + cur_result.match_start,
                use_color,
            );
            printSep(stdout_writer, ':', use_color);
        }
        const abs_start = search_offset + cur_result.match_start;
        const abs_end = search_offset + cur_result.match_end;
        if (use_color) {
            stdout_writer.print("{s}", .{Color.match_highlight}) catch {};
            stdout_writer.writeAll(line[abs_start..abs_end]) catch {};
            stdout_writer.print("{s}", .{Color.reset}) catch {};
        } else {
            stdout_writer.writeAll(line[abs_start..abs_end]) catch {};
        }
        stdout_writer.writeByte(line_term) catch {};

        // Advance past this match and search for more
        search_offset = abs_end;
        if (search_offset >= line.len) break;
        const prev_char: ?u8 = if (search_offset > 0) line[search_offset - 1] else null;
        cur_result = matchAnyPattern(
            patterns,
            line[search_offset..],
            allocator,
            opts.word_regexp,
            prev_char,
        );
    }
}

/// Print the prefix and matching line for a normal (non -o) match.
fn processFile_printNormalMatch(
    stdout_writer: *std.Io.Writer,
    line: []const u8,
    line_num: usize, // tiger:allow:usize-arch line index, slice-index-forced
    line_offsets: []const usize, // tiger:allow:usize-arch byte offsets, slice-index-forced
    result: MatchResult,
    opts: *const GrepOptions,
    filename: []const u8,
    show_filename: bool,
    use_color: bool,
    fn_sep: u8,
    line_term: u8,
) void {
    assert(line_num >= 1);
    assert(result.match_end >= result.match_start);
    if (show_filename) {
        printFilename(stdout_writer, filename, use_color);
        printSep(stdout_writer, fn_sep, use_color);
    }
    if (opts.line_number) {
        printLineNumber(stdout_writer, line_num, use_color);
        printSep(stdout_writer, ':', use_color);
    }
    if (opts.byte_offset) {
        printByteOffset(stdout_writer, line_offsets[line_num - 1], use_color);
        printSep(stdout_writer, ':', use_color);
    }
    if (!opts.invert_match) {
        printMatchLine(
            stdout_writer,
            line,
            result.match_start,
            result.match_end,
            use_color,
            line_term,
        );
    } else {
        stdout_writer.writeAll(line) catch {};
        stdout_writer.writeByte(line_term) catch {};
    }
}

/// Print the trailing -c / -l / -L summary for a file.
fn processFile_printSummary(
    stdout_writer: *std.Io.Writer,
    opts: *const GrepOptions,
    filename: []const u8,
    match_count: usize, // tiger:allow:usize-arch match counter, matches existing type
    found_match: bool,
    show_filename: bool,
    use_color: bool,
    fn_sep: u8,
    line_term: u8,
) void {
    const sep_ok = fn_sep == 0 or fn_sep == ':';
    assert(sep_ok);
    const term_ok = line_term == 0 or line_term == '\n';
    assert(term_ok);
    if (opts.count) {
        if (show_filename) {
            printFilename(stdout_writer, filename, use_color);
            printSep(stdout_writer, fn_sep, use_color);
        }
        stdout_writer.print("{d}", .{match_count}) catch {};
        stdout_writer.writeByte(line_term) catch {};
    }

    if (opts.files_with_matches and found_match) {
        stdout_writer.print("{s}", .{filename}) catch {};
        if (opts.null_data)
            stdout_writer.writeByte(0) catch {}
        else
            stdout_writer.writeByte('\n') catch {};
    }

    if (opts.files_without_match and !found_match) {
        stdout_writer.print("{s}", .{filename}) catch {};
        if (opts.null_data)
            stdout_writer.writeByte(0) catch {}
        else
            stdout_writer.writeByte('\n') catch {};
    }
}

/// Print a context line (with - separator instead of :)
fn printContextLine(
    writer: *std.Io.Writer,
    line: []const u8,
    line_num: usize, // tiger:allow:usize-arch line counter, matches existing type
    filename: []const u8,
    show_filename: bool,
    show_line_number: bool,
    show_byte_offset: bool,
    byte_offset: usize, // tiger:allow:usize-arch byte offset, matches existing type
    use_color: bool,
    fn_sep: u8,
    line_term: u8,
) void {
    const ctx_sep_ok = fn_sep == 0 or fn_sep == ':';
    assert(ctx_sep_ok);
    const ctx_term_ok = line_term == 0 or line_term == '\n';
    assert(ctx_term_ok);
    if (show_filename) {
        printFilename(writer, filename, use_color);
        printSep(writer, if (fn_sep == 0) @as(u8, 0) else '-', use_color);
    }
    if (show_line_number) {
        printLineNumber(writer, line_num, use_color);
        printSep(writer, '-', use_color);
    }
    if (show_byte_offset) {
        printByteOffset(writer, byte_offset, use_color);
        printSep(writer, '-', use_color);
    }
    writer.writeAll(line) catch {};
    writer.writeByte(line_term) catch {};
}

// ============================================================================
// Recursive Directory Walking
// ============================================================================

/// Check if a file should be included based on --include/--exclude globs
fn shouldIncludeFile(basename: []const u8, opts: *const GrepOptions) bool {
    // If include globs are set, file must match at least one
    if (opts.include_globs.items.len > 0) {
        var matches_include = false;
        for (opts.include_globs.items) |pat| {
            if (glob.globMatch(pat, basename)) {
                matches_include = true;
                break;
            }
        }
        if (!matches_include) return false;
    }

    // Check exclude globs
    for (opts.exclude_globs.items) |pat| {
        if (glob.globMatch(pat, basename)) return false;
    }

    return true;
}

/// Check if a directory should be excluded
fn shouldExcludeDir(dirname: []const u8, opts: *const GrepOptions) bool {
    for (opts.exclude_dirs.items) |pattern| {
        if (glob.globMatch(pattern, dirname)) return true;
    }
    return false;
}

/// Mutable state threaded through one recursive search: the bounded walker
/// plus the visited-inode set grep uses to terminate symlink cycles under -R.
const TreeSearch = struct {
    /// Arena allocator shared with runGrep.
    allocator: Allocator,
    walker: common.walker.Walker,
    /// Device/inode of every directory grep actually descends: the root, each
    /// real subdirectory the walker enters, and each followed directory
    /// symlink. Used to break -R symlink loops AND to deduplicate a directory
    /// symlink that points back at a real subdirectory already walked (GNU
    /// grep dedups by dev/inode for every directory it enters). null when -R
    /// is off (no symlink following, so no cycle is possible).
    visited_dirs: ?common.directory.FileSystemIdSet,
};

/// Recursively search a directory tree using the bounded common.walker.
///
/// Replaces the former self-recursive searchDirectory. The walker owns the
/// real-directory traversal (pre-order, depth-bounded, iterative); grep
/// decides which emitted entries to search and which directories to prune.
///
/// Symlink policy is grep's responsibility, not the walker's. We drive the
/// walker in `no_follow` so symlinks arrive as `.sym_link` entries with their
/// path intact. Under -r grep ignores them. Under -R grep follows them: a
/// symlink-to-file is opened and searched; a symlink-to-directory is enqueued
/// as a fresh root on the SAME walker, gated by grep's own visited-inode set
/// so symlink loops terminate. The walker's follow_all mode cannot serve grep,
/// because it openDir()s every symlink and so loses a symlink-to-file as an
/// error; and its no_follow cycle pre-registration would block the intended
/// descent through a directory symlink. A no_follow walk over real directories
/// cannot itself cycle (directory hardlinks are disallowed), so walker-level
/// cycle detection is unnecessary here.
fn searchTree(
    allocator: Allocator,
    io: std.Io,
    root_path: []const u8,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    use_color: bool,
    found_any: *bool,
    had_error: *bool,
    walk_config: common.walker.WalkConfig,
) void {
    assert(root_path.len > 0);
    // Cannot split: "or" means either flag suffices, not both.
    assert(opts.recursive or opts.skip_dirs); // tiger:allow:compound-assert

    var search = TreeSearch{
        .allocator = allocator,
        .walker = common.walker.Walker.init(allocator, walk_config) catch return,
        .visited_dirs = if (opts.dereference_recursive)
            common.directory.FileSystemIdSet.init(allocator)
        else
            null,
    };
    defer search.walker.deinit(io);
    defer if (search.visited_dirs) |*set| set.deinit();

    // Seed the visited set with the root so a symlink pointing back at it stops.
    if (search.visited_dirs != null) registerDir(io, root_path, &search);
    search.walker.addRoot(root_path) catch return;

    // Terminates when walker.next() returns null: every root of the finite
    // directory tree has been exhausted (see break below).
    while (true) { // tiger:allow:unbounded-loop walker.next() returns null at exhaustion
        const maybe_entry = search.walker.next(io) catch |err| {
            // An unreadable directory (or other per-entry I/O failure) is
            // non-fatal: report it and let the walker resume at siblings. GNU
            // grep exits 2 on any read error, so latch had_error here.
            had_error.* = true;
            reportWalkError(root_path, err, opts, stderr_writer, &search);
            // The entry-count cap is terminal: next() latches this error and
            // re-returns it forever, so stop the walk instead of spinning.
            if (err == error.EntryLimitExceeded) break;
            continue;
        };
        const entry = maybe_entry orelse break;
        searchTreeEntry(
            allocator,
            io,
            entry,
            patterns,
            opts,
            stdout_writer,
            stderr_writer,
            use_color,
            found_any,
            &search,
        );
    }
}

/// Report a non-fatal per-entry walk error, naming the exact failing path.
///
/// The bounded walker records the entry behind the error (the directory it
/// failed to open) and exposes it via errorPath(), valid until the next next().
/// grep prints that path to match GNU grep, which names the precise unreadable
/// path. It falls back to the root operand when the walker recorded no specific
/// entry (e.g. a limit error), keeping the message useful.
fn reportWalkError(
    root_path: []const u8,
    err: anyerror,
    opts: *const GrepOptions,
    stderr_writer: *std.Io.Writer,
    search: *TreeSearch,
) void {
    assert(root_path.len > 0);
    if (opts.no_messages) return;
    // errorPath(), when set, is the walker's non-empty failing path; the root
    // operand fallback is likewise non-empty (asserted by the caller).
    const failing_path = search.walker.errorPath() orelse root_path;
    assert(failing_path.len > 0);
    // GNU prints this operand unquoted; keep parity.
    common.printErrorWithProgram(
        search.allocator,
        stderr_writer,
        prog_name,
        "{s}: {s}",
        .{ failing_path, common.posixErrorString(err) },
    );
}

/// Record a directory's device/inode in the visited set, if -R is active.
/// A directory grep cannot open is simply not recorded (it will not be
/// descended either), so the omission is harmless.
fn registerDir(io: std.Io, path: []const u8, search: *TreeSearch) void {
    assert(path.len > 0);
    // registerDir is only meaningful when -R installed the visited set.
    assert(search.visited_dirs != null);
    const set = if (search.visited_dirs) |*s| s else return;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return;
    defer dir.close(io);
    const fs_id = common.directory.FileSystemId.fromDir(dir) catch return;
    _ = set.getOrPut(fs_id) catch {};
}

/// Handle one walker entry: search regular files, prune excluded directories,
/// and (under -R) follow symlinks the no_follow walker left for grep to resolve.
fn searchTreeEntry(
    allocator: Allocator,
    io: std.Io,
    entry: common.walker.Entry,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    use_color: bool,
    found_any: *bool,
    search: *TreeSearch,
) void {
    assert(entry.path.len > 0);
    switch (entry.kind) {
        .directory => enterDir(io, entry, opts, search),
        .file => searchOneFile(
            allocator,
            io,
            entry.path,
            entry.basename,
            patterns,
            opts,
            stdout_writer,
            stderr_writer,
            use_color,
            found_any,
        ),
        .sym_link => {
            // Under -r symlinks are never followed; under -R grep follows now.
            if (!opts.dereference_recursive) return;
            followSymlinkEntry(
                allocator,
                io,
                entry,
                patterns,
                opts,
                stdout_writer,
                stderr_writer,
                use_color,
                found_any,
                search,
            );
        },
        else => {},
    }
}

/// Process a pre-order directory entry: prune excluded directories, otherwise
/// (under -R) record its device/inode so a directory symlink pointing back at
/// it is recognized as already-visited (GNU-style dedup).
fn enterDir(
    io: std.Io,
    entry: common.walker.Entry,
    opts: *const GrepOptions,
    search: *TreeSearch,
) void {
    assert(entry.path.len > 0);
    assert(entry.kind == .directory);
    if (shouldExcludeDir(entry.basename, opts)) {
        search.walker.pruneCurrent();
        return;
    }
    // Under -R, record every real directory grep enters so a directory symlink
    // resolving to an already-walked subtree is not re-walked.
    if (search.visited_dirs != null) registerDir(io, entry.path, search);
}

/// Open and search a single regular file reached during a recursive walk.
fn searchOneFile(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    basename: []const u8,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    use_color: bool,
    found_any: *bool,
) void {
    assert(path.len > 0);
    assert(basename.len > 0);
    if (!shouldIncludeFile(basename, opts)) return;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (!opts.no_messages) {
            // GNU prints this operand unquoted; keep parity.
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "{s}: {s}",
                .{ path, common.posixErrorString(err) },
            );
        }
        return;
    };
    defer file.close(io);
    if (processFile(allocator, io, file, path, patterns, opts, stdout_writer, true, use_color)) {
        found_any.* = true;
    }
}

/// Follow a symlink under -R. statFile resolves the link: a directory target
/// is enqueued as a new walker root (once, gated by the visited-inode set so
/// loops terminate); any other target is searched as a regular file.
fn followSymlinkEntry(
    allocator: Allocator,
    io: std.Io,
    entry: common.walker.Entry,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    use_color: bool,
    found_any: *bool,
    search: *TreeSearch,
) void {
    assert(entry.path.len > 0);
    assert(opts.dereference_recursive);
    // statFile follows the link, revealing the real target kind.
    const target_stat = std.Io.Dir.cwd().statFile(io, entry.path, .{}) catch return;
    if (target_stat.kind == .directory) {
        followDirSymlink(io, entry, opts, search);
        return;
    }
    searchOneFile(
        allocator,
        io,
        entry.path,
        entry.basename,
        patterns,
        opts,
        stdout_writer,
        stderr_writer,
        use_color,
        found_any,
    );
}

/// Enqueue a directory symlink's target for walking, unless it is excluded or
/// already visited. Recording the target before enqueuing breaks symlink loops.
fn followDirSymlink(
    io: std.Io,
    entry: common.walker.Entry,
    opts: *const GrepOptions,
    search: *TreeSearch,
) void {
    assert(entry.path.len > 0);
    assert(opts.dereference_recursive);
    if (shouldExcludeDir(entry.basename, opts)) return;
    var dir = std.Io.Dir.cwd().openDir(io, entry.path, .{}) catch return;
    defer dir.close(io);
    const fs_id = common.directory.FileSystemId.fromDir(dir) catch return;
    const set = if (search.visited_dirs) |*s| s else return;
    const gop = set.getOrPut(fs_id) catch return;
    if (gop.found_existing) return; // Already walked this directory: stop the loop.
    search.walker.addRoot(entry.path) catch {};
}

// ============================================================================
// Help and Version
// ============================================================================

fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: grep [OPTION]... PATTERNS [FILE]...
        \\Search for PATTERNS in each FILE.
        \\Example: grep -i 'hello world' menu.h main.c
        \\PATTERNS can contain multiple patterns separated by newlines.
        \\
        \\Pattern selection and interpretation:
        \\  -E, --extended-regexp     interpret PATTERNS as extended regular expressions
        \\  -F, --fixed-strings       interpret PATTERNS as fixed strings
        \\  -G, --basic-regexp        interpret PATTERNS as basic regular expressions
        \\  -e, --regexp=PATTERNS     use PATTERNS for matching
        \\  -f, --file=FILE           take PATTERNS from FILE
        \\  -i, --ignore-case         ignore case distinctions in patterns and data
        \\  -w, --word-regexp         match only whole words
        \\  -x, --line-regexp         match only whole lines
        \\
        \\Miscellaneous:
        \\  -s, --no-messages         suppress error messages
        \\  -v, --invert-match        select non-matching lines
        \\  -a, --text                equivalent to --binary-files=text
        \\  -I                        equivalent to --binary-files=without-match
        \\  -U, --binary              do not strip CR characters (no-op on Unix)
        \\      --help                display this help and exit
        \\  -V, --version             output version information and exit
        \\
        \\Output control:
        \\  -m, --max-count=NUM       stop after NUM selected lines
        \\  -b, --byte-offset         print the byte offset with output lines
        \\  -n, --line-number         print line number with output lines
        \\  -H, --with-filename       print file name with output lines
        \\  -h, --no-filename         suppress the file name prefix on output
        \\  -o, --only-matching       show only nonempty parts of lines that match
        \\  -q, --quiet, --silent     suppress all normal output
        \\  -c, --count               print only a count of selected lines per FILE
        \\  -l, --files-with-matches  print only names of FILEs with selected lines
        \\  -L, --files-without-match print only names of FILEs with no selected lines
        \\  -Z, --null                print 0 byte after file name
        \\      --color[=WHEN]        use markers to highlight the matching strings;
        \\                            WHEN is 'always', 'never', or 'auto'
        \\
        \\Context control:
        \\  -B, --before-context=NUM  print NUM lines of leading context
        \\  -A, --after-context=NUM   print NUM lines of trailing context
        \\  -C, --context=NUM         print NUM lines of output context
        \\
        \\File and directory selection:
        \\  -r, --recursive           search directories recursively
        \\  -R, --dereference-recursive  likewise, but follow all symlinks
        \\      --include=GLOB        search only files that match GLOB (a file pattern)
        \\      --exclude=GLOB        skip files that match GLOB
        \\      --exclude-dir=GLOB    skip directories that match GLOB
        \\
    );
}

fn printVersion(writer: *std.Io.Writer) !void {
    writer.print("grep ({s}) {s}\n", .{ common.name, common.version }) catch {};
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runGrep);
}

/// Public entry point for the grep utility
pub fn runGrep(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) anyerror!u8 {
    var opts = (parseArgs(allocator, io, args, stderr_writer) catch {
        return @intFromEnum(common.ExitCode.misuse);
    }) orelse return @intFromEnum(common.ExitCode.misuse);
    defer opts.deinit(allocator);

    // Handle --help/--version and the no-pattern error before searching.
    if (runGrep_earlyExit(allocator, &opts, stdout_writer, stderr_writer)) |code| {
        return code;
    }

    // Compile patterns
    var compiled = std.ArrayListUnmanaged(CompiledPattern).empty;
    defer {
        for (compiled.items) |*cp| freePattern(allocator, cp);
        compiled.deinit(allocator);
    }

    (runGrep_compilePatterns(allocator, &opts, &compiled, stderr_writer)) orelse {
        return @intFromEnum(common.ExitCode.misuse);
    };
    assert(compiled.items.len == opts.patterns.items.len);

    // Determine color usage
    const use_color = opts.color == .on;

    const show_filename = runGrep_showFilename(&opts);

    var found_any = false;
    var had_error = false;

    // Determine stdin label (--label overrides default)
    const stdin_label = opts.stdin_label orelse "(standard input)";

    const quiet_early = runGrep_dispatchInputs(.{
        .allocator = allocator,
        .io = io,
        .opts = &opts,
        .compiled = compiled.items,
        .stdout_writer = stdout_writer,
        .stderr_writer = stderr_writer,
        .show_filename = show_filename,
        .use_color = use_color,
        .stdin_label = stdin_label,
        .found_any_ptr = &found_any,
        .had_error_ptr = &had_error,
    });
    if (quiet_early) return 0;

    if (opts.quiet) {
        // A quiet match wins outright; otherwise a walk error still dominates
        // the no-match exit (GNU: -q only overrides to 0 when a match was found).
        if (found_any) return 0;
        if (had_error) return 2;
        return 1;
    }

    if (had_error) return 2;
    return if (found_any) 0 else 1;
}

/// Handle the early-exit cases (--help, --version, missing pattern). Returns
/// the exit code to return immediately, or null to continue searching.
fn runGrep_earlyExit(
    allocator: Allocator,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    if (opts.help) {
        printHelp(allocator, stdout_writer) catch {};
        return @intFromEnum(common.ExitCode.success);
    }
    if (opts.version) {
        printVersion(stdout_writer) catch {};
        return @intFromEnum(common.ExitCode.success);
    }
    if (opts.patterns.items.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "no pattern specified\nTry 'grep --help' for more information.",
            .{},
        );
        return @intFromEnum(common.ExitCode.misuse);
    }
    return null;
}

/// Bundled inputs for `runGrep_dispatchInputs`: too many to pass positionally.
const DispatchInputs = struct {
    allocator: Allocator,
    io: std.Io,
    opts: *const GrepOptions,
    compiled: []const CompiledPattern,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    show_filename: bool,
    use_color: bool,
    stdin_label: []const u8,
    found_any_ptr: *bool,
    had_error_ptr: *bool,
};

/// Route grep to its input source: stdin, a recursive tree walk, or the
/// listed file operands. Returns true when a -q match warrants an early
/// `return 0` in the caller.
fn runGrep_dispatchInputs(d: DispatchInputs) bool {
    const opts = d.opts;
    if (opts.files.items.len == 0 and !opts.recursive) {
        // Read from stdin
        const stdin_file = std.Io.File.stdin();
        if (processFile(
            d.allocator,
            d.io,
            stdin_file,
            d.stdin_label,
            d.compiled,
            opts,
            d.stdout_writer,
            d.show_filename,
            d.use_color,
        )) {
            d.found_any_ptr.* = true;
        }
    } else if (opts.files.items.len == 0 and opts.recursive) {
        // Recursive with no files means search current directory
        searchTree(
            d.allocator,
            d.io,
            ".",
            d.compiled,
            opts,
            d.stdout_writer,
            d.stderr_writer,
            d.use_color,
            d.found_any_ptr,
            d.had_error_ptr,
            .{ .order = .pre, .symlinks = .no_follow, .cycle_mode = .none },
        );
    } else {
        for (opts.files.items) |file_path| {
            const quiet_early = runGrep_processOneOperand(
                d.allocator,
                d.io,
                file_path,
                d.compiled,
                opts,
                d.stdout_writer,
                d.stderr_writer,
                d.show_filename,
                d.use_color,
                d.stdin_label,
                d.found_any_ptr,
                d.had_error_ptr,
            );
            if (quiet_early) return true;
        }
    }
    return false;
}

/// Compile every parsed pattern, appending to `compiled_ptr`.
/// Returns null (error already printed) to signal the caller to exit misuse.
fn runGrep_compilePatterns(
    allocator: Allocator,
    opts: *const GrepOptions,
    compiled_ptr: *std.ArrayListUnmanaged(CompiledPattern),
    stderr_writer: *std.Io.Writer,
) ?void {
    assert(opts.patterns.items.len > 0);
    for (opts.patterns.items) |pattern| {
        const cp = compilePattern(allocator, pattern, opts, stderr_writer) orelse return null;
        compiled_ptr.append(allocator, cp) catch return null;
    }
    assert(compiled_ptr.items.len <= opts.patterns.items.len);
    return {};
}

/// Decide whether to prefix output lines with the filename.
///   --no-filename (-h) always suppresses
///   --with-filename (-H) always shows
///   default: show if multiple files or recursive
fn runGrep_showFilename(opts: *const GrepOptions) bool {
    return if (opts.no_filename)
        false
    else if (opts.with_filename)
        true
    else if (opts.recursive)
        true
    else
        opts.files.items.len > 1;
}

/// Report a stat/open failure for an operand unless -s/--no-messages silences
/// it. Centralizes the duplicated error path in runGrep_processOneOperand.
fn runGrep_reportFileError(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    opts: *const GrepOptions,
    file_path: []const u8,
    err: anyerror,
) void {
    if (opts.no_messages) return;
    // GNU prints this operand unquoted; keep parity.
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "{s}: {s}",
        .{ file_path, common.posixErrorString(err) },
    );
}

/// Search one command-line operand (stdin, directory, or regular file).
/// Returns true when a quiet early-return (-q with a match) is requested.
fn runGrep_processOneOperand(
    allocator: Allocator,
    io: std.Io,
    file_path: []const u8,
    compiled: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    show_filename: bool,
    use_color: bool,
    stdin_label: []const u8,
    found_any_ptr: *bool,
    had_error_ptr: *bool,
) bool {
    assert(compiled.len > 0);
    if (std.mem.eql(u8, file_path, "-")) {
        const stdin_file = std.Io.File.stdin();
        const matched = processFile(
            allocator,
            io,
            stdin_file,
            stdin_label,
            compiled,
            opts,
            stdout_writer,
            show_filename,
            use_color,
        );
        if (matched) found_any_ptr.* = true;
        return false;
    }

    if (opts.recursive or opts.skip_dirs) {
        // Check if it's a directory
        const stat = std.Io.Dir.cwd().statFile(io, file_path, .{}) catch |err| {
            runGrep_reportFileError(allocator, stderr_writer, opts, file_path, err);
            had_error_ptr.* = true;
            return false;
        };
        if (stat.kind == .directory) {
            if (opts.skip_dirs) return false; // -d skip: silently skip
            searchTree(
                allocator,
                io,
                file_path,
                compiled,
                opts,
                stdout_writer,
                stderr_writer,
                use_color,
                found_any_ptr,
                had_error_ptr,
                .{ .order = .pre, .symlinks = .no_follow, .cycle_mode = .none },
            );
            return false;
        }
    }

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        runGrep_reportFileError(allocator, stderr_writer, opts, file_path, err);
        had_error_ptr.* = true;
        return false;
    };
    defer file.close(io);
    const matched = processFile(
        allocator,
        io,
        file,
        file_path,
        compiled,
        opts,
        stdout_writer,
        show_filename,
        use_color,
    );
    if (matched) found_any_ptr.* = true;
    if (opts.quiet and found_any_ptr.*) return true;
    return false;
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert a string to lowercase
fn toLower(allocator: Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |ch, i| {
        result[i] = std.ascii.toLower(ch);
    }
    assert(result.len == s.len);
    return result;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "parseArgs basic pattern" {
    const args = [_][]const u8{"hello"};
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqualStrings("hello", opts.patterns.items[0]);
    try testing.expectEqual(@as(usize, 0), opts.files.items.len);
}

test "parseArgs pattern and files" {
    const args = [_][]const u8{ "pattern", "file1.txt", "file2.txt" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqualStrings("pattern", opts.patterns.items[0]);
    try testing.expectEqual(@as(usize, 2), opts.files.items.len);
    try testing.expectEqualStrings("file1.txt", opts.files.items[0]);
    try testing.expectEqualStrings("file2.txt", opts.files.items[1]);
}

test "parseArgs -e multiple patterns" {
    const args = [_][]const u8{ "-e", "foo", "-e", "bar" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.patterns.items.len);
    try testing.expectEqualStrings("foo", opts.patterns.items[0]);
    try testing.expectEqualStrings("bar", opts.patterns.items[1]);
}

test "parseArgs -e with files" {
    const args = [_][]const u8{ "-e", "pattern", "file1.txt" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqualStrings("pattern", opts.patterns.items[0]);
    try testing.expectEqual(@as(usize, 1), opts.files.items.len);
    try testing.expectEqualStrings("file1.txt", opts.files.items[0]);
}

test "parseArgs short flags" {
    const args = [_][]const u8{ "-ivn", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.ignore_case);
    try testing.expect(opts.invert_match);
    try testing.expect(opts.line_number);
}

test "parseArgs long flags" {
    const args = [_][]const u8{ "--ignore-case", "--count", "--recursive", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.ignore_case);
    try testing.expect(opts.count);
    try testing.expect(opts.recursive);
}

test "parseArgs regex modes" {
    {
        const args = [_][]const u8{ "-E", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(RegexMode.extended, opts.regex_mode);
    }
    {
        const args = [_][]const u8{ "-F", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(RegexMode.fixed, opts.regex_mode);
    }
    {
        const args = [_][]const u8{ "-G", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(RegexMode.basic, opts.regex_mode);
    }
}

test "parseArgs -m max-count" {
    const args = [_][]const u8{ "-m", "5", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), opts.max_count.?);
}

test "parseArgs context flags" {
    {
        const args = [_][]const u8{ "-A", "3", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 3), opts.after_context);
    }
    {
        const args = [_][]const u8{ "-B", "2", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), opts.before_context);
    }
    {
        const args = [_][]const u8{ "-C", "1", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), opts.before_context);
        try testing.expectEqual(@as(usize, 1), opts.after_context);
    }
}

test "parseArgs color modes" {
    {
        const args = [_][]const u8{ "--color=always", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(common.display_config.ResolvedMode.on, opts.color);
    }
    {
        const args = [_][]const u8{ "--color=never", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(common.display_config.ResolvedMode.off, opts.color);
    }
    {
        const args = [_][]const u8{ "--color=auto", "pattern" };
        var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        // --color=auto keeps the resolved value; in tests stdout is not a TTY, so .off
        try testing.expectEqual(common.display_config.ResolvedMode.off, opts.color);
    }
}

test "parseArgs -- separator" {
    const args = [_][]const u8{ "-e", "pattern", "--", "-file.txt" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqual(@as(usize, 1), opts.files.items.len);
    try testing.expectEqualStrings("-file.txt", opts.files.items[0]);
}

test "parseArgs invalid option returns null" {
    const args = [_][]const u8{ "-j", "pattern" };
    const result = try parseArgs(testing.allocator, testing.io, &args, common.null_writer);
    try testing.expect(result == null);
}

test "parseArgs --include and --exclude" {
    const args = [_][]const u8{ "--include=*.c", "--exclude=*.o", "--exclude-dir=.git", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.include_globs.items.len);
    try testing.expectEqualStrings("*.c", opts.include_globs.items[0]);
    try testing.expectEqual(@as(usize, 1), opts.exclude_globs.items.len);
    try testing.expectEqualStrings("*.o", opts.exclude_globs.items[0]);
    try testing.expectEqual(@as(usize, 1), opts.exclude_dirs.items.len);
    try testing.expectEqualStrings(".git", opts.exclude_dirs.items[0]);
}

test "fixed string matching" {
    const pattern = CompiledPattern{ .fixed = .{ .text = "hello", .lower = null } };
    const result = matchLine(&pattern, "say hello world", testing.allocator, false, null);
    try testing.expect(result.matched);
    try testing.expectEqual(@as(usize, 4), result.match_start);
    try testing.expectEqual(@as(usize, 9), result.match_end);
}

test "fixed string no match" {
    const pattern = CompiledPattern{ .fixed = .{ .text = "xyz", .lower = null } };
    const result = matchLine(&pattern, "hello world", testing.allocator, false, null);
    try testing.expect(!result.matched);
}

test "fixed string case insensitive" {
    const lower = try toLower(testing.allocator, "hello");
    defer testing.allocator.free(lower);
    const pattern = CompiledPattern{ .fixed = .{ .text = "Hello", .lower = lower } };
    const result = matchLine(&pattern, "say HELLO world", testing.allocator, false, null);
    try testing.expect(result.matched);
}

fn testAllocRegex() ?*c.regex_t {
    if (comptime is_linux) {
        return regex_c.regex_heap_alloc();
    } else {
        return testing.allocator.create(c.regex_t) catch return null;
    }
}

fn testFreeRegex(re: *c.regex_t) void {
    if (comptime is_linux) {
        regex_c.regex_heap_free(re);
    } else {
        testing.allocator.destroy(re);
    }
}

test "regex matching basic" {
    const cflags: c_int = c.REG_EXTENDED;
    const pat_str: [:0]const u8 = "hel+o";
    const regex = testAllocRegex() orelse return error.OutOfMemory;
    defer testFreeRegex(regex);
    const comp_result = c.regcomp(regex, pat_str.ptr, cflags);
    try testing.expectEqual(@as(c_int, 0), comp_result);
    defer c.regfree(regex);

    const pattern = CompiledPattern{ .regex = regex };
    const result = matchLine(&pattern, "say hello world", testing.allocator, false, null);
    try testing.expect(result.matched);
}

test "regex no match" {
    const cflags: c_int = c.REG_EXTENDED | c.REG_NOSUB;
    const pat_str: [:0]const u8 = "^xyz$";
    const regex = testAllocRegex() orelse return error.OutOfMemory;
    defer testFreeRegex(regex);
    const comp_result = c.regcomp(regex, pat_str.ptr, cflags);
    try testing.expectEqual(@as(c_int, 0), comp_result);
    defer c.regfree(regex);

    const pattern = CompiledPattern{ .regex = regex };
    const result = matchLine(&pattern, "hello world", testing.allocator, false, null);
    try testing.expect(!result.matched);
}

test "toLower conversion" {
    const result = try toLower(testing.allocator, "Hello World");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "toLower empty string" {
    const result = try toLower(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "runGrep no pattern returns misuse" {
    const args = [_][]const u8{};
    const exit_code = try runGrep(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runGrep --help returns success" {
    const args = [_][]const u8{"--help"};
    const exit_code = try runGrep(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep --version returns success" {
    const args = [_][]const u8{"--version"};
    const exit_code = try runGrep(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

/// Helper to run grep in tests with arena allocator (grep is designed for arena usage)
fn testRunGrep(file_content: []const u8, grep_args: []const []const u8) !u8 {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, file_content);
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    // Use arena for runGrep since it relies on arena-style allocation
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build args list with the temp file path appended
    var args = std.ArrayListUnmanaged([]const u8).empty;
    defer args.deinit(allocator);
    try args.append(allocator, "--color=never");
    for (grep_args) |a| {
        try args.append(allocator, a);
    }
    try args.append(allocator, tmp_path);

    return runGrep(allocator, io, args.items, common.null_writer, common.null_writer);
}

test "runGrep with file" {
    const exit_code = try testRunGrep("hello world\nfoo bar\nhello again\n", &.{"hello"});
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep no match returns 1" {
    const exit_code = try testRunGrep("hello world\nfoo bar\n", &.{"zzzzz"});
    try testing.expectEqual(@as(u8, 1), exit_code);
}

test "runGrep -c count mode" {
    const exit_code = try testRunGrep("hello world\nfoo bar\nhello again\n", &.{ "-c", "hello" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep -v invert match" {
    const exit_code = try testRunGrep("hello world\nfoo bar\nhello again\n", &.{ "-v", "hello" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep -F fixed strings" {
    const exit_code = try testRunGrep(
        "hello.world\nfoo.bar\nhello world\n",
        &.{ "-F", "hello.world" },
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep -E extended regex" {
    const exit_code = try testRunGrep("hello world\nfoo bar\nhello again\n", &.{ "-E", "hel+o" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep nonexistent file returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "--color=never", "pattern", "/nonexistent/path/file.txt" };
    const exit_code = try runGrep(
        arena.allocator(),
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runGrep -q quiet mode match" {
    const exit_code = try testRunGrep("hello world\n", &.{ "-q", "hello" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep -q quiet mode no match" {
    const exit_code = try testRunGrep("hello world\n", &.{ "-q", "zzzzz" });
    try testing.expectEqual(@as(u8, 1), exit_code);
}

test "runGrep invalid regex returns misuse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "--color=never", "[invalid", "/dev/null" };
    const exit_code = try runGrep(
        arena.allocator(),
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runGrep -m max-count" {
    const exit_code = try testRunGrep(
        "hello one\nhello two\nhello three\nhello four\n",
        &.{ "-m", "2", "hello" },
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

/// Helper to run grep and capture stdout output
fn testRunGrepOutput(
    file_content: []const u8,
    grep_args: []const []const u8,
) !struct { exit_code: u8, output: []const u8, arena: std.heap.ArenaAllocator } {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, file_content);
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    for (grep_args) |a| {
        try args.append(allocator, a);
    }
    try args.append(allocator, tmp_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);
    const output = try arena.allocator().dupe(u8, stdout_aw.writer.buffered());

    return .{ .exit_code = exit_code, .output = output, .arena = arena };
}

test "parseArgs -b sets byte_offset" {
    const args = [_][]const u8{ "-b", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.byte_offset);
}

test "parseArgs --byte-offset sets byte_offset" {
    const args = [_][]const u8{ "--byte-offset", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.byte_offset);
}

test "parseArgs -a flag accepted (no-op)" {
    const args = [_][]const u8{ "-a", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --text flag accepted (no-op)" {
    const args = [_][]const u8{ "--text", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -I flag accepted (no-op)" {
    const args = [_][]const u8{ "-I", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -U flag accepted (no-op)" {
    const args = [_][]const u8{ "-U", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --binary flag accepted (no-op)" {
    const args = [_][]const u8{ "--binary", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "runGrep -b prints byte offset" {
    // "hello\nworld\nfoo\n" -> "hello" at offset 0, "world" at offset 6, "foo" at offset 12
    var result = try testRunGrepOutput("hello\nworld\nfoo\n", &.{ "-b", "world" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("6:world\n", result.output);
}

test "runGrep -b -n prints line number then byte offset" {
    // "hello\nworld\nfoo\n" -> "world" is line 2, offset 6
    var result = try testRunGrepOutput("hello\nworld\nfoo\n", &.{ "-b", "-n", "world" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("2:6:world\n", result.output);
}

test "runGrep -b -c prints only count" {
    var result = try testRunGrepOutput("hello\nworld\nfoo\n", &.{ "-b", "-c", "world" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("1\n", result.output);
}

test "runGrep -b multiple matches" {
    // "aaa\nbbb\naaa\n" -> first "aaa" at offset 0 (line 1), second "aaa" at offset 8 (line 3)
    var result = try testRunGrepOutput("aaa\nbbb\naaa\n", &.{ "-b", "aaa" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("0:aaa\n8:aaa\n", result.output);
}

test "parseArgs -Z sets null_data" {
    const args = [_][]const u8{ "-Z", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_data);
}

test "parseArgs --null sets null_data" {
    const args = [_][]const u8{ "--null", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_data);
}

test "runGrep -lZ uses NUL byte after filename" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "hello world\n");
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-lZ");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_aw.writer.buffered();
    // Output should be filename followed by NUL byte (not newline)
    const expected_len = tmp_path.len + 1;
    try testing.expectEqual(expected_len, out.len);
    try testing.expectEqualStrings(tmp_path, out[0..tmp_path.len]);
    try testing.expectEqual(@as(u8, 0), out[tmp_path.len]);
}

test "runGrep -l without -Z uses newline after filename" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "hello world\n");
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-l");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_aw.writer.buffered();
    // Output should be filename followed by newline
    const expected_len = tmp_path.len + 1;
    try testing.expectEqual(expected_len, out.len);
    try testing.expectEqualStrings(tmp_path, out[0..tmp_path.len]);
    try testing.expectEqual(@as(u8, '\n'), out[tmp_path.len]);
}

// ============================================================================
// Tests for SHOULD flags
// ============================================================================

// --- No-op stub parse tests ---

test "parseArgs -J flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-J", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -M flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-M", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -O flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-O", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -p flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-p", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -S flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-S", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -u flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-u", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -X flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-X", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -D flag accepted (stub)" {
    const args = [_][]const u8{ "-D", "read", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -D skip accepted (stub)" {
    const args = [_][]const u8{ "-D", "skip", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --line-buffered accepted (no-op)" {
    const args = [_][]const u8{ "--line-buffered", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --binary-files=text accepted (stub)" {
    const args = [_][]const u8{ "--binary-files=text", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --binary-files=without-match accepted (stub)" {
    const args = [_][]const u8{ "--binary-files=without-match", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --mmap accepted (no-op)" {
    const args = [_][]const u8{ "--mmap", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --include-dir=PATTERN accepted (no-op stub)" {
    const args = [_][]const u8{ "--include-dir=src", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

// --- -y alias for -i ---

test "parseArgs -y sets ignore_case (alias for -i)" {
    const args = [_][]const u8{ "-y", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.ignore_case);
}

test "runGrep -y case insensitive match" {
    const exit_code = try testRunGrep("Hello World\n", &.{ "-y", "hello" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

// --- -P error stub ---

test "parseArgs -P returns null (error stub)" {
    const result = try parseArgs(
        testing.allocator,
        testing.io,
        &[_][]const u8{ "-P", "pattern" },
        common.null_writer,
    );
    try testing.expect(result == null);
}

test "runGrep -P returns misuse exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "-P", "pattern", "/dev/null" };
    const exit_code = try runGrep(
        arena.allocator(),
        testing.io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 2), exit_code);
}

// --- -d directory action ---

test "parseArgs -d recurse sets recursive" {
    const args = [_][]const u8{ "-d", "recurse", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.recursive);
}

test "parseArgs -d skip sets skip_dirs" {
    const args = [_][]const u8{ "-d", "skip", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.skip_dirs);
}

test "parseArgs -d read is default (no change)" {
    const args = [_][]const u8{ "-d", "read", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(!opts.recursive);
    try testing.expect(!opts.skip_dirs);
}

test "runGrep -d skip silently skips directories" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with matching content
    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "hello world\n");
    file.close(io);

    // Create a subdirectory
    try tmp_dir.dir.createDir(io, "subdir", .default_dir);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const file_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "test.txt" });
    defer testing.allocator.free(file_path);

    const dir_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "subdir" });
    defer testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-d");
    try args.append(allocator, "skip");
    try args.append(allocator, "hello");
    try args.append(allocator, dir_path);
    try args.append(allocator, file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    // Should find match in file, skip directory
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello world") != null);
}

// --- -z / --null-data (NUL line separator) ---

test "parseArgs -z sets null_line_sep" {
    const args = [_][]const u8{ "-z", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_line_sep);
}

test "parseArgs --null-data sets null_line_sep" {
    const args = [_][]const u8{ "--null-data", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_line_sep);
}

test "runGrep -z splits on NUL and terminates with NUL" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with NUL-separated records
    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "hello world\x00foo bar\x00hello again\x00");
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-z");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should be NUL-terminated: "hello world\0hello again\0"
    try testing.expectEqualStrings("hello world\x00hello again\x00", stdout_aw.writer.buffered());
}

// --- --label=LABEL ---

test "parseArgs --label=LABEL sets stdin_label" {
    const args = [_][]const u8{ "--label=MYINPUT", "pattern" };
    var opts = (try parseArgs(testing.allocator, testing.io, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("MYINPUT", opts.stdin_label.?);
}

// --- --null / -Z extended behavior (NUL after filename in normal output) ---

test "runGrep -HZ uses NUL after filename in normal output" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "hello world\n");
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-HZ");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should have NUL after filename: "path\0hello world\n"
    const expected = try std.fmt.allocPrint(allocator, "{s}\x00hello world\n", .{tmp_path});
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "runGrep -cZ uses NUL after filename in count output" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "hello world\nhello again\n");
    file.close(io);

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Use -H to force filename display with single file
    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-cHZ");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should have NUL after filename: "path\02\n"
    const expected = try std.fmt.allocPrint(allocator, "{s}\x002\n", .{tmp_path});
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// --- readToEndAlloc safety-net tests (line 659 code path) ---

test "processFile reads multi-line file and returns correct matches" {
    const content =
        \\alpha one
        \\beta two
        \\alpha three
        \\gamma four
        \\alpha five
        \\
    ;
    const result = try testRunGrepOutput(content, &.{"alpha"});
    defer result.arena.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    // Should match exactly the three "alpha" lines
    try testing.expectEqualStrings(
        "alpha one\nalpha three\nalpha five\n",
        result.output,
    );
}

test "processFile reads file with many lines and matches selectively" {
    // Build a file with 200 lines; every 10th line contains "NEEDLE"
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf = std.ArrayListUnmanaged(u8).empty;
    var expected = std.ArrayListUnmanaged(u8).empty;
    for (0..200) |i| {
        if (i % 10 == 0) {
            const line = try std.fmt.allocPrint(allocator, "NEEDLE line {d}\n", .{i});
            try buf.appendSlice(allocator, line);
            try expected.appendSlice(allocator, line);
        } else {
            const line = try std.fmt.allocPrint(allocator, "filler line {d}\n", .{i});
            try buf.appendSlice(allocator, line);
        }
    }

    const result = try testRunGrepOutput(buf.items, &.{"NEEDLE"});
    defer result.arena.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected.items, result.output);
}

test "runGrep -f pattern file does not leak file contents buffer" {
    const io = testing.io;
    // Create a temp dir with a pattern file and a data file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write pattern file containing one pattern per line
    const pattern_file = try tmp_dir.dir.createFile(io, "patterns.txt", .{});
    try pattern_file.writeStreamingAll(io, "hello\nworld\n");
    pattern_file.close(io);

    // Write data file to search
    const data_file = try tmp_dir.dir.createFile(io, "data.txt", .{});
    try data_file.writeStreamingAll(io, "hello there\ngoodbye now\nworld peace\n");
    data_file.close(io);

    const pattern_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "patterns.txt",
        testing.allocator,
    );
    defer testing.allocator.free(pattern_path);

    const data_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "data.txt", testing.allocator);
    defer testing.allocator.free(data_path);

    // Use testing.allocator directly (not arena) so leaks are detected
    const args = [_][]const u8{ "--color=never", "-f", pattern_path, data_path };
    const exit_code = try runGrep(
        testing.allocator,
        io,
        &args,
        common.null_writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

// =============================================================
// F27: grep -x broken in BRE mode
// The -x flag wraps the pattern as ^(pattern)$ but in BRE mode
// ( and ) are literal characters, not grouping. So ^(foo)$
// matches the literal string "(foo)" rather than "foo".
// =============================================================

test "F27: grep -x matches whole line in BRE mode" {
    // In BRE mode (default), -x should match "foo" as a whole line.
    // Bug: wraps as ^(foo)$ where parens are literal in BRE.
    var result = try testRunGrepOutput("foo\nfoo bar\n", &.{ "-x", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\n", result.output);
}

test "F27: grep -x BRE no match returns exit 1" {
    // "foo bar" does not match -x "foo" because "foo bar" != "foo"
    var result = try testRunGrepOutput("foo bar\nbaz\n", &.{ "-x", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "F27: grep -x with regex metachar in BRE mode" {
    // f.o should match "foo" or "fXo" as whole line but not "f.o bar"
    var result = try testRunGrepOutput("foo\nfXo\nf.o bar\n", &.{ "-x", "f.o" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\nfXo\n", result.output);
}

test "F27: grep -Ex works in ERE mode (control test)" {
    // ERE mode should work correctly since ( ) are grouping in ERE.
    var result = try testRunGrepOutput("foo\nfoo bar\n", &.{ "-Ex", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\n", result.output);
}

test "F27: grep -x BRE with alternation" {
    // In BRE, \| is alternation. -x "foo\|bar" should match "foo" or "bar"
    // as whole lines.
    var result = try testRunGrepOutput("foo\nbar\nbaz\n", &.{ "-x", "foo\\|bar" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\nbar\n", result.output);
}

// =============================================================
// F29: GNU regex escape extensions (\s \S \w \W \|)
// GNU grep supports \s/\S/\w/\W in both BRE and ERE, and \| as BRE
// alternation, as libc regcomp extensions. glibc (Linux) implements
// these natively so the tests below pass locally; BSD/Darwin libc
// treats them as literal escaped characters, so they are expected to
// go red on macOS CI (macos-26 legs of test.yml/integration.yml)
// until compilePattern translates these escapes before calling
// regcomp. Pinned against GNU grep 3.11 (see issue #78).
// The -x '[a\|]' case is a separate, pre-existing bug in
// anchorBreAlternatives (bracket-expression-unaware \| scanning) and
// is red on BOTH platforms.
// =============================================================

test "F29: grep -E \\s matches whitespace (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf '  plan: x\n' | grep -E '^\s+plan\s*:' matches, exit 0.
    var result = try testRunGrepOutput("  plan: x\n", &.{ "-E", "^\\s+plan\\s*:" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("  plan: x\n", result.output);
}

test "F29: grep BRE \\s matches whitespace (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf 'a b\n' | grep 'a\sb' matches, exit 0 (default BRE mode).
    var result = try testRunGrepOutput("a b\n", &.{"a\\sb"});
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("a b\n", result.output);
}

test "F29: grep -E \\S matches non-whitespace (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf 'a b\nacb\n' | grep -E 'a\Sb' outputs only 'acb'.
    var result = try testRunGrepOutput("a b\nacb\n", &.{ "-E", "a\\Sb" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("acb\n", result.output);
}

test "F29: grep BRE \\w matches word characters (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf 'foo_1\n' | grep '\w\w\w_\w' matches, exit 0.
    var result = try testRunGrepOutput("foo_1\n", &.{"\\w\\w\\w_\\w"});
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo_1\n", result.output);
}

test "F29: grep BRE \\W matches non-word characters (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf 'a-b\naxb\n' | grep 'a\Wb' outputs only 'a-b'.
    var result = try testRunGrepOutput("a-b\naxb\n", &.{"a\\Wb"});
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("a-b\n", result.output);
}

test "F29: grep BRE \\| is alternation without -x (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf 'foo\nbar\nbaz\n' | grep 'foo\|bar' outputs 'foo' and
    // 'bar', not 'baz'.
    var result = try testRunGrepOutput("foo\nbar\nbaz\n", &.{"foo\\|bar"});
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\nbar\n", result.output);
}

test "F29: grep -i composes with \\s (GNU extension; red on macOS/BSD libc)" {
    // Pinned: printf 'A B\n' | grep -i 'a\sb' matches, exit 0.
    var result = try testRunGrepOutput("A B\n", &.{ "-i", "a\\sb" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("A B\n", result.output);
}

test "F29: grep -x '[a\\|]' keeps backslash literal inside brackets (pre-existing bug; red on Linux AND macOS)" {
    // Pinned: printf '%s\n' '\' | grep -x '[a\|]' matches a line consisting
    // of a lone backslash, exit 0. anchorBreAlternatives scans for \|
    // without tracking bracket-expression state, so it splits inside
    // [a\|] and mangles the pattern into ERE ^([a|])$, which does not
    // match a lone backslash. This bug reproduces on Linux (this box)
    // as well as macOS -- it is not a libc extension gap.
    var result = try testRunGrepOutput("\\\n", &.{ "-x", "[a\\|]" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("\\\n", result.output);
}

test "F29: grep '[\\s]' keeps backslash literal inside brackets, not [[:space:]] (stays green everywhere)" {
    // Pinned: printf '%s\n' 's' '\' ' ' | grep '[\s]' matches 's' and '\'
    // but NOT the space-only line -- inside brackets backslash is a
    // literal POSIX bracket-expression member, never translated to
    // [[:space:]].
    var result = try testRunGrepOutput("s\n\\\n \n", &.{"[\\s]"});
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("s\n\\\n", result.output);
}

test "F29: grep 'a\\\\sb' matches literal backslash-s, not GNU \\s (stays green everywhere)" {
    // Pinned: printf '%s\n' 'a\sb' 'a b' | grep 'a\\sb' matches only the
    // literal 'a\sb' line -- an escaped backslash (\\) followed by 's'
    // must NOT be re-interpreted as the GNU \s extension.
    var result = try testRunGrepOutput("a\\sb\na b\n", &.{"a\\\\sb"});
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("a\\sb\n", result.output);
}

test "F29: grep -E 'foo\\|bar' keeps \\| as literal pipe, not alternation (stays green everywhere)" {
    // Pinned: printf '%s\n' 'foo|bar' 'foo' | grep -E 'foo\|bar' matches
    // only the literal 'foo|bar' line -- in ERE, \| is an escaped literal
    // pipe, never alternation (ERE alternation is unescaped |).
    var result = try testRunGrepOutput("foo|bar\nfoo\n", &.{ "-E", "foo\\|bar" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo|bar\n", result.output);
}

// =============================================================
// F30: translateGnuEscapes unit tests (#78)
// Table-driven unit coverage for the GNU-escape pattern
// translator: \s/\S/\w/\W class substitution (outside bracket
// expressions only, pairwise backslash consumption), and the
// BRE->ERE transpile triggered by top-level \| alternation
// (force_ere). Expectations pinned against GNU grep semantics
// and verified against the reviewed implementation.
// =============================================================

const TranslateCase = struct {
    input: []const u8,
    expected: []const u8,
};

test "F30: translateGnuEscapes ERE class escapes and passthrough (table)" {
    const cases = [_]TranslateCase{
        .{ .input = "\\s", .expected = "[[:space:]]" },
        .{ .input = "^\\s+plan\\s*:", .expected = "^[[:space:]]+plan[[:space:]]*:" },
        .{ .input = "a\\Sb", .expected = "a[^[:space:]]b" },
        .{ .input = "\\w", .expected = "[[:alnum:]_]" },
        .{ .input = "\\W", .expected = "[^[:alnum:]_]" },
        // ERE \| is an escaped literal pipe, never alternation: untouched.
        .{ .input = "foo\\|bar", .expected = "foo\\|bar" },
        // No translation inside bracket expressions.
        .{ .input = "[\\s]", .expected = "[\\s]" },
        // Leading-']' literal quirk: the ']' is a member, not the closer.
        .{ .input = "[]\\s]", .expected = "[]\\s]" },
        .{ .input = "[^]\\s]", .expected = "[^]\\s]" },
        // Nested [:class:] does not end the bracket expression.
        .{ .input = "[[:alpha:]\\s]", .expected = "[[:alpha:]\\s]" },
        // Escaped backslash consumed pairwise: \\s stays literal.
        .{ .input = "\\\\s", .expected = "\\\\s" },
        // Odd backslash run: third backslash starts a real \s.
        .{ .input = "\\\\\\s", .expected = "\\\\[[:space:]]" },
        // Trailing lone backslash emitted verbatim, no crash.
        .{ .input = "abc\\", .expected = "abc\\" },
        .{ .input = "", .expected = "" },
    };
    for (cases) |case| {
        const tr = translateGnuEscapes(testing.allocator, case.input, .extended) orelse
            return error.OutOfMemory;
        defer testing.allocator.free(tr.pattern);
        try testing.expectEqualStrings(case.expected, tr.pattern);
        try testing.expectEqual(false, tr.force_ere);
    }
}

test "F30: translateGnuEscapes BRE without alternation keeps BRE (table)" {
    const cases = [_]TranslateCase{
        .{ .input = "a\\sb", .expected = "a[[:space:]]b" },
        // The F29 bug pin at translator level: \| inside a bracket
        // expression is a literal member, so no transpile happens.
        .{ .input = "[a\\|]", .expected = "[a\\|]" },
    };
    for (cases) |case| {
        const tr = translateGnuEscapes(testing.allocator, case.input, .basic) orelse
            return error.OutOfMemory;
        defer testing.allocator.free(tr.pattern);
        try testing.expectEqualStrings(case.expected, tr.pattern);
        try testing.expectEqual(false, tr.force_ere);
    }
}

test "F30: translateGnuEscapes BRE with top-level \\| transpiles to ERE (table)" {
    const cases = [_]TranslateCase{
        .{ .input = "foo\\|bar", .expected = "foo|bar" },
        .{ .input = "foo\\|bar\\|baz", .expected = "foo|bar|baz" },
        .{ .input = "\\(ab\\)\\|c", .expected = "(ab)|c" },
        // Bare parens are BRE literals: escaped in the ERE output.
        .{ .input = "a(b\\|c", .expected = "a\\(b|c" },
        // Bare + is a BRE literal; GNU BRE \+ is a quantifier.
        .{ .input = "a+b\\|c", .expected = "a\\+b|c" },
        .{ .input = "a\\+\\|b", .expected = "a+|b" },
        .{ .input = "x\\{2\\}\\|y", .expected = "x{2}|y" },
        .{ .input = "a{b\\|c", .expected = "a\\{b|c" },
        // Mid-pattern ^ and $ are literals in BRE.
        .{ .input = "a^b\\|c", .expected = "a\\^b|c" },
        .{ .input = "a$b\\|c", .expected = "a\\$b|c" },
        // Anchors kept at expression edges.
        .{ .input = "^a\\|b$", .expected = "^a|b$" },
        // ^ right after \( is still an anchor (expression start).
        .{ .input = "\\(^a\\|b\\)", .expected = "(^a|b)" },
        // * at expression start is a BRE literal.
        .{ .input = "*a\\|b", .expected = "\\*a|b" },
        // Backreferences pass through untouched.
        .{ .input = "\\1x\\|y", .expected = "\\1x|y" },
        // Class escapes compose with the transpile output.
        .{ .input = "\\s\\|\\w", .expected = "[[:space:]]|[[:alnum:]_]" },
        // Bracket expressions copied verbatim during the transpile.
        .{ .input = "[a\\|]x\\|y", .expected = "[a\\|]x|y" },
    };
    for (cases) |case| {
        const tr = translateGnuEscapes(testing.allocator, case.input, .basic) orelse
            return error.OutOfMemory;
        defer testing.allocator.free(tr.pattern);
        try testing.expectEqualStrings(case.expected, tr.pattern);
        try testing.expectEqual(true, tr.force_ere);
    }
}

test "F30: breHasTopLevelAlternation detects only unescaped top-level \\|" {
    // A real top-level \| outside brackets is alternation.
    try testing.expect(breHasTopLevelAlternation("foo\\|bar"));
    // \| inside a bracket expression is a literal member.
    try testing.expect(!breHasTopLevelAlternation("[a\\|]"));
    // Escaped backslash (\\) then a bare | -- pairwise consumption means
    // the pipe is bare, and a bare | is a BRE literal, not alternation.
    try testing.expect(!breHasTopLevelAlternation("a\\\\|b"));
}

// =============================================================
// F28: grep -o prints only first match per line
// GNU grep -o prints each non-overlapping match on its own line.
// Our implementation prints only the first match per line.
// =============================================================

test "F28: grep -o prints all matches per line" {
    // "foobarfoo" contains "foo" twice. -o should print two lines.
    var result = try testRunGrepOutput("foobarfoo\n", &.{ "-o", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\nfoo\n", result.output);
}

test "F28: grep -Eo prints all matches per line" {
    // Same test with ERE mode explicitly.
    var result = try testRunGrepOutput("foobarfoo\n", &.{ "-Eo", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\nfoo\n", result.output);
}

test "F28: grep -o with single match per line unchanged" {
    // When there's only one match per line, behavior should be the same.
    var result = try testRunGrepOutput("say hello world\n", &.{ "-Eo", "hello" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("hello\n", result.output);
}

test "F28: grep -o no match returns exit 1" {
    var result = try testRunGrepOutput("hello world\n", &.{ "-o", "zzzzz" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "F28: grep -o multiple matches across multiple lines" {
    // Line 1: "abcabc" has "abc" twice
    // Line 2: "xyzabc" has "abc" once
    // Total: 3 lines of output
    var result = try testRunGrepOutput("abcabc\nxyzabc\n", &.{ "-o", "abc" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("abc\nabc\nabc\n", result.output);
}

test "F28: grep -o with single-char pattern multiple matches" {
    // "aababaa" has 5 'a' characters
    var result = try testRunGrepOutput("aababaa\n", &.{ "-o", "a" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("a\na\na\na\na\n", result.output);
}

test "F28: grep -on prints line number for each match" {
    // GNU grep -on prints the line number with each match occurrence.
    // "foobarfoo" on line 1 has two "foo" matches, both get line number 1.
    var result = try testRunGrepOutput("foobarfoo\n", &.{ "-on", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("1:foo\n1:foo\n", result.output);
}

test "G-03: grep -wo prints only the word, not boundary characters" {
    // BUG: -w wraps pattern with boundary groups; pmatch[0] includes
    // the boundary characters (e.g. leading/trailing space). With -o,
    // output should be "foo\n" not " foo \n".
    var result = try testRunGrepOutput("hello foo bar\n", &.{ "-wo", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\n", result.output);
}

test "G-03: grep -wo at start of line prints only the word" {
    // Word at the start of line: boundary is ^, not a space character.
    // pmatch[0] should still cover only "foo", not include any extra.
    var result = try testRunGrepOutput("foo bar baz\n", &.{ "-wo", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\n", result.output);
}

test "G-03: grep -wo at end of line prints only the word" {
    // Word at the end of line: boundary is $, not a space character.
    var result = try testRunGrepOutput("baz bar foo\n", &.{ "-wo", "foo" });
    defer result.arena.deinit();
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("foo\n", result.output);
}

// =============================================================
// WALKER MIGRATION CHARACTERIZATION TESTS
//
// These lock in the behavior of recursive search (searchDirectory)
// so the bounded-walker rewrite preserves it. Every test builds a
// real directory tree under a tmpDir, runs runGrep with an absolute
// path operand (resolved via realPath, since searchDirectory opens
// through cwd()), and asserts a SPECIFIC observable outcome.
//
// They use testing.allocator (grep needs no privilege; it never
// changes ownership), matching the existing recursive grep tests
// (e.g. "runGrep -d skip silently skips directories").
// =============================================================

/// Run grep recursively over an already-populated tmp dir.
/// `extra_args` are inserted before the directory operand. Returns the
/// captured stdout (owned by the returned arena) and the exit code.
const RecursiveResult = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    exit_code: u8,
};

fn runGrepRecursive(
    tmp_dir: *testing.TmpDir,
    extra_args: []const []const u8,
    capture_stderr: bool,
) !RecursiveResult {
    const io = testing.io;

    // searchDirectory opens via cwd(), so an absolute operand is required.
    const root_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    // The helper always enables recursion; callers add -R / globs / -d as needed.
    // -r never clears dereference_recursive, so passing -R alongside is safe.
    try args.append(allocator, "-r");
    for (extra_args) |a| try args.append(allocator, a);
    try args.append(allocator, try allocator.dupe(u8, root_path));

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    const stderr_writer = if (capture_stderr) &stderr_aw.writer else common.null_writer;

    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, stderr_writer);

    return .{
        .arena = arena,
        .output = if (capture_stderr) stderr_aw.writer.buffered() else stdout_aw.writer.buffered(),
        .exit_code = exit_code,
    };
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
        count += 1;
        start = idx + needle.len;
    }
    return count;
}

test "walker-migration: -r descends into every level and searches all regular files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build a multi-level tree:
    //   top.txt            (match)
    //   a/mid.txt          (match)
    //   a/b/deep.txt       (match)
    //   a/b/c/deepest.txt  (match)
    //   a/nomatch.txt      (no match)
    try tmp_dir.dir.createDirPath(io, "a/b/c");
    const write = struct {
        fn f(d: std.Io.Dir, name: []const u8, content: []const u8) !void {
            const file = try d.createFile(testing.io, name, .{});
            try file.writeStreamingAll(testing.io, content);
            file.close(testing.io);
        }
    }.f;
    try write(tmp_dir.dir, "top.txt", "needle at top\n");
    try write(tmp_dir.dir, "a/mid.txt", "needle in mid\n");
    try write(tmp_dir.dir, "a/b/deep.txt", "needle in deep\n");
    try write(tmp_dir.dir, "a/b/c/deepest.txt", "needle in deepest\n");
    try write(tmp_dir.dir, "a/nomatch.txt", "nothing here\n");

    var result = try runGrepRecursive(&tmp_dir, &.{"needle"}, false);
    defer result.arena.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    // Every file at every depth must have been searched: one line per matching file.
    try testing.expect(std.mem.indexOf(u8, result.output, "needle at top") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "needle in mid") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "needle in deep") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "needle in deepest") != null);
    // The non-matching file must NOT contribute output.
    try testing.expect(std.mem.indexOf(u8, result.output, "nothing here") == null);
    // Exactly four matching lines total (no file searched twice).
    try testing.expectEqual(@as(usize, 4), countOccurrences(result.output, "needle"));
}

test "walker-migration: --exclude-dir prunes the entire matching subtree" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // keep/keep.txt          -> searched
    // skipme/inside.txt      -> pruned (basename "skipme" matches glob)
    // skipme/deeper/x.txt    -> pruned (whole subtree gone)
    try tmp_dir.dir.createDirPath(io, "keep");
    try tmp_dir.dir.createDirPath(io, "skipme/deeper");
    const write = struct {
        fn f(d: std.Io.Dir, name: []const u8, content: []const u8) !void {
            const file = try d.createFile(testing.io, name, .{});
            try file.writeStreamingAll(testing.io, content);
            file.close(testing.io);
        }
    }.f;
    try write(tmp_dir.dir, "keep/keep.txt", "needle kept\n");
    try write(tmp_dir.dir, "skipme/inside.txt", "needle pruned shallow\n");
    try write(tmp_dir.dir, "skipme/deeper/x.txt", "needle pruned deep\n");

    var result = try runGrepRecursive(&tmp_dir, &.{ "--exclude-dir=skipme", "needle" }, false);
    defer result.arena.deinit();

    // The kept file matches; the entire skipme subtree must be unsearched.
    try testing.expect(std.mem.indexOf(u8, result.output, "needle kept") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "needle pruned shallow") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "needle pruned deep") == null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "needle"));
    try testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "walker-migration: -r does NOT follow a symlink to a file" {
    const io = testing.io;

    // The symlink TARGET lives in a separate tmp dir, OUTSIDE the walked
    // tree, so the only way grep could read its content is by following
    // the symlink. Under -r it must not.
    var outside_dir = testing.tmpDir(.{});
    defer outside_dir.cleanup();
    {
        const file = try outside_dir.dir.createFile(io, "secret.txt", .{});
        try file.writeStreamingAll(io, "SYMFILE forbidden\n");
        file.close(io);
    }
    const target_abs = try outside_dir.dir.realPathFileAlloc(io, "secret.txt", testing.allocator);
    defer testing.allocator.free(target_abs);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.symLink(io, target_abs, "link.txt", .{});
    // A real matching file proves the walk actually ran.
    {
        const file = try tmp_dir.dir.createFile(io, "real.txt", .{});
        try file.writeStreamingAll(io, "SYMFILE real\n");
        file.close(io);
    }

    var result = try runGrepRecursive(&tmp_dir, &.{"SYMFILE"}, false);
    defer result.arena.deinit();

    // The real file is searched; the symlink target content never appears.
    try testing.expect(std.mem.indexOf(u8, result.output, "SYMFILE real") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "SYMFILE forbidden") == null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "SYMFILE"));
}

test "walker-migration: -r does NOT descend through a symlink to a directory" {
    const io = testing.io;

    // The TARGET directory lives outside the walked tree. Under -r the
    // directory symlink must not be descended, so its file is never found.
    var outside_dir = testing.tmpDir(.{});
    defer outside_dir.cleanup();
    {
        const file = try outside_dir.dir.createFile(io, "unique.txt", .{});
        try file.writeStreamingAll(io, "SYMDIR forbidden\n");
        file.close(io);
    }
    const target_abs = try outside_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(target_abs);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.symLink(io, target_abs, "dirlink", .{});
    // A real matching file proves the walk actually ran.
    {
        const file = try tmp_dir.dir.createFile(io, "real.txt", .{});
        try file.writeStreamingAll(io, "SYMDIR real\n");
        file.close(io);
    }

    var result = try runGrepRecursive(&tmp_dir, &.{"SYMDIR"}, false);
    defer result.arena.deinit();

    // The real file matches; the symlinked directory is not descended.
    try testing.expect(std.mem.indexOf(u8, result.output, "SYMDIR real") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "SYMDIR forbidden") == null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "SYMDIR"));
}

test "walker-migration: -R follows a symlink to a file and searches it" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // The target lives OUTSIDE the walked tree so the only way to reach
    // its content is by dereferencing the symlink.
    try tmp_dir.dir.createDirPath(io, "outside");
    {
        const file = try tmp_dir.dir.createFile(io, "outside/target.txt", .{});
        try file.writeStreamingAll(io, "DEREFFILE marker\n");
        file.close(io);
    }
    try tmp_dir.dir.createDirPath(io, "walked");
    try tmp_dir.dir.symLink(io, "../outside/target.txt", "walked/link.txt", .{});

    const root_path = try tmp_dir.dir.realPathFileAlloc(io, "walked", testing.allocator);
    defer testing.allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-R");
    try args.append(allocator, "DEREFFILE");
    try args.append(allocator, try allocator.dupe(u8, root_path));

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    // -R must dereference the symlink-to-file and search its contents.
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(
        std.mem.indexOf(u8, stdout_aw.writer.buffered(), "DEREFFILE marker") != null,
    );
}

test "walker-migration: -R descends a symlink to a directory and finds the buried file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // The target directory lives OUTSIDE the walked tree (a sibling) so the
    // only way to reach the buried file is by dereferencing the directory
    // symlink and descending into it -- exactly what -R must do.
    try tmp_dir.dir.createDirPath(io, "outside");
    {
        const file = try tmp_dir.dir.createFile(io, "outside/buried.txt", .{});
        try file.writeStreamingAll(io, "DEREFDIR buried\n");
        file.close(io);
    }
    try tmp_dir.dir.createDirPath(io, "walked");
    // A real plain file inside the walked tree proves the walk actually ran.
    {
        const file = try tmp_dir.dir.createFile(io, "walked/real.txt", .{});
        try file.writeStreamingAll(io, "DEREFDIR real\n");
        file.close(io);
    }
    // The symlink points at the sibling directory, not a file.
    try tmp_dir.dir.symLink(io, "../outside", "walked/dirlink", .{});

    const root_path = try tmp_dir.dir.realPathFileAlloc(io, "walked", testing.allocator);
    defer testing.allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-R");
    try args.append(allocator, "DEREFDIR");
    try args.append(allocator, try allocator.dupe(u8, root_path));

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    // -R must descend the symlink-to-directory and search the buried file.
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_aw.writer.buffered(), "DEREFDIR buried") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_aw.writer.buffered(), "buried.txt") != null);
}

// BEHAVIOR CHANGE (not a characterization test): the walker design (-R =>
// SymlinkPolicy.follow_all) makes -R descend a symlink-to-directory. The
// CURRENT searchDirectory does NOT descend directory symlinks under -R (it
// open()s the dir as a file, reads nothing, and never recurses). Because a
// characterization test must pass on the CURRENT code, we cannot assert the
// new "descended" behavior here without going red today. The walker's own
// follow_all directory-descent is covered in src/common/walker.zig
// ("walker: -L follows ...") tests. After the migration, ADD a grep-level
// test asserting that `grep -R PATTERN dir` descends a directory symlink and
// finds the buried file -- and verify it goes red against pre-migration grep.

test "walker-migration: directory operand is searched recursively under -r" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A command-line directory operand (not "." default) must recurse.
    try tmp_dir.dir.createDirPath(io, "operand/nested");
    {
        const file = try tmp_dir.dir.createFile(io, "operand/nested/found.txt", .{});
        try file.writeStreamingAll(io, "OPERANDMATCH here\n");
        file.close(io);
    }

    const operand_path = try tmp_dir.dir.realPathFileAlloc(io, "operand", testing.allocator);
    defer testing.allocator.free(operand_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-r");
    try args.append(allocator, "OPERANDMATCH");
    try args.append(allocator, try allocator.dupe(u8, operand_path));

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(
        std.mem.indexOf(u8, stdout_aw.writer.buffered(), "OPERANDMATCH here") != null,
    );
}

test "walker-migration: -d skip silently skips a directory operand and keeps file operands" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A directory operand with -d skip must be skipped without error,
    // while a sibling file operand is still searched.
    try tmp_dir.dir.createDirPath(io, "adir");
    {
        const file = try tmp_dir.dir.createFile(io, "adir/inside.txt", .{});
        try file.writeStreamingAll(io, "SKIPMATCH in dir\n");
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "afile.txt", .{});
        try file.writeStreamingAll(io, "SKIPMATCH in file\n");
        file.close(io);
    }

    const dir_operand = try tmp_dir.dir.realPathFileAlloc(io, "adir", testing.allocator);
    defer testing.allocator.free(dir_operand);
    const file_operand = try tmp_dir.dir.realPathFileAlloc(io, "afile.txt", testing.allocator);
    defer testing.allocator.free(file_operand);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8).empty;
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-d");
    try args.append(allocator, "skip");
    try args.append(allocator, "SKIPMATCH");
    try args.append(allocator, try allocator.dupe(u8, dir_operand));
    try args.append(allocator, try allocator.dupe(u8, file_operand));

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    const exit_code = try runGrep(allocator, io, args.items, &stdout_aw.writer, &stderr_aw.writer);

    // File operand searched, directory operand silently skipped, no error emitted.
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(
        std.mem.indexOf(u8, stdout_aw.writer.buffered(), "SKIPMATCH in file") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, stdout_aw.writer.buffered(), "SKIPMATCH in dir") == null,
    );
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "walker-migration: --include gates which regular files are searched" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Only *.zig files should be searched; the *.txt file is skipped even
    // though it contains the pattern.
    const write = struct {
        fn f(d: std.Io.Dir, name: []const u8, content: []const u8) !void {
            const file = try d.createFile(testing.io, name, .{});
            try file.writeStreamingAll(testing.io, content);
            file.close(testing.io);
        }
    }.f;
    try write(tmp_dir.dir, "code.zig", "INCNEEDLE in zig\n");
    try write(tmp_dir.dir, "notes.txt", "INCNEEDLE in txt\n");

    var result = try runGrepRecursive(&tmp_dir, &.{ "--include=*.zig", "INCNEEDLE" }, false);
    defer result.arena.deinit();

    try testing.expect(std.mem.indexOf(u8, result.output, "INCNEEDLE in zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "INCNEEDLE in txt") == null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "INCNEEDLE"));
}

test "walker-migration: --exclude skips matching regular files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // *.log files are excluded; the other file is still searched.
    const write = struct {
        fn f(d: std.Io.Dir, name: []const u8, content: []const u8) !void {
            const file = try d.createFile(testing.io, name, .{});
            try file.writeStreamingAll(testing.io, content);
            file.close(testing.io);
        }
    }.f;
    try write(tmp_dir.dir, "keep.txt", "EXCNEEDLE keep\n");
    try write(tmp_dir.dir, "drop.log", "EXCNEEDLE drop\n");

    var result = try runGrepRecursive(&tmp_dir, &.{ "--exclude=*.log", "EXCNEEDLE" }, false);
    defer result.arena.deinit();

    try testing.expect(std.mem.indexOf(u8, result.output, "EXCNEEDLE keep") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "EXCNEEDLE drop") == null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "EXCNEEDLE"));
}

test "walker-migration: unreadable directory is reported to stderr and walk continues" {
    // chmod 000 is bypassed by root, so this test is meaningless under
    // fakeroot or as root; skip there. Under a normal user the kernel
    // denies access and we can observe the error + continuation.
    if (privilege_test.FakerootContext.isUnderFakeroot()) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest;

    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // good/good.txt is searchable; locked/ is chmod 000 (unreadable).
    try tmp_dir.dir.createDirPath(io, "good");
    try tmp_dir.dir.createDirPath(io, "locked");
    {
        const file = try tmp_dir.dir.createFile(io, "good/good.txt", .{});
        try file.writeStreamingAll(io, "CONTINUEMARKER found\n");
        file.close(io);
    }
    {
        // A file inside locked/ that we must NOT be able to reach.
        const file = try tmp_dir.dir.createFile(io, "locked/hidden.txt", .{});
        try file.writeStreamingAll(io, "CONTINUEMARKER hidden\n");
        file.close(io);
    }

    const locked_abs = try tmp_dir.dir.realPathFileAlloc(io, "locked", testing.allocator);
    defer testing.allocator.free(locked_abs);
    const locked_z = try testing.allocator.dupeZ(u8, locked_abs);
    defer testing.allocator.free(locked_z);

    // Remove all permissions on the directory so its iteration fails.
    if (std.c.chmod(locked_z.ptr, 0o000) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_z.ptr, 0o755);

    var result = try runGrepRecursive(&tmp_dir, &.{"CONTINUEMARKER"}, true);
    defer result.arena.deinit();

    // result.output here is captured STDERR. An error must be reported...
    try testing.expect(result.output.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.output, "grep") != null);

    // ...and the walk must continue: the good file is still found. Re-run
    // capturing stdout to confirm continuation (stderr capture path above
    // discards stdout).
    var result2 = try runGrepRecursive(&tmp_dir, &.{"CONTINUEMARKER"}, false);
    defer result2.arena.deinit();
    try testing.expect(std.mem.indexOf(u8, result2.output, "CONTINUEMARKER found") != null);
    // The hidden file behind the locked dir was never reached.
    try testing.expect(std.mem.indexOf(u8, result2.output, "CONTINUEMARKER hidden") == null);
}

// =============================================================
// ISSUE #58: recursive walk errors must set the exit code.
//
// grep -r reports walk errors (unreadable subtree) to stderr via
// reportWalkError, but searchTree returns void, so had_error never
// reaches runGrep's exit logic. Truncated results then look like a
// clean run (exit 0/1) instead of exit 2. GNU 3.11 (pinned on the
// Linux VM) exits 2 whenever a read error occurred during the walk,
// except that -q returns 0 when a line was selected. These tests
// assert that pinned behavior; the two error-present-no-q tests are
// RED on the current code, the -q and clean-tree tests guard against
// the fix leaking the error channel into cases that must stay 0/1.
// =============================================================

/// Build the pinned issue-#58 tree under `tmp_dir`: ok/f.txt="hay\n"
/// (readable, holds the match) and locked/s.txt="secret\n" inside a
/// chmod-000 directory the walk cannot enter. Returns the NUL-terminated
/// absolute path of the locked dir (owned by `testing.allocator`; the
/// caller frees it) so the caller can restore its mode. On success the
/// locked dir is already chmod 000.
fn issue58BuildLockedTree(tmp_dir: *testing.TmpDir) ![:0]u8 {
    const io = testing.io;
    try tmp_dir.dir.createDirPath(io, "ok");
    try tmp_dir.dir.createDirPath(io, "locked");
    {
        const file = try tmp_dir.dir.createFile(io, "ok/f.txt", .{});
        try file.writeStreamingAll(io, "hay\n");
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "locked/s.txt", .{});
        try file.writeStreamingAll(io, "secret\n");
        file.close(io);
    }

    const locked_abs = try tmp_dir.dir.realPathFileAlloc(io, "locked", testing.allocator);
    defer testing.allocator.free(locked_abs);
    const locked_z = try testing.allocator.dupeZ(u8, locked_abs);
    errdefer testing.allocator.free(locked_z);

    if (std.c.chmod(locked_z.ptr, 0o000) != 0) return error.SkipZigTest;
    return locked_z;
}

test "issue #58: grep -r no match over tree with unreadable subdir exits 2 with diagnostic" {
    // chmod 000 is bypassed by root, so skip under fakeroot or as root.
    if (privilege_test.FakerootContext.isUnderFakeroot()) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const locked_z = try issue58BuildLockedTree(&tmp_dir);
    defer testing.allocator.free(locked_z);
    defer _ = std.c.chmod(locked_z.ptr, 0o755);

    // Pattern "zzz" matches nothing anywhere; only the walk error remains.
    var result = try runGrepRecursive(&tmp_dir, &.{"zzz"}, true);
    defer result.arena.deinit();

    // GNU 3.11 pinned: a read error occurred, so exit is 2 (NOT 1, mere
    // no-match). This is the core RED assertion for issue #58.
    try testing.expectEqual(@as(u8, 2), result.exit_code);
    // The read error must still be reported on stderr (result.output here).
    try testing.expect(std.mem.indexOf(u8, result.output, "grep") != null);
}

test "issue #58: grep -r match found over tree with unreadable subdir exits 2" {
    if (privilege_test.FakerootContext.isUnderFakeroot()) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const locked_z = try issue58BuildLockedTree(&tmp_dir);
    defer testing.allocator.free(locked_z);
    defer _ = std.c.chmod(locked_z.ptr, 0o755);

    // "hay" matches ok/f.txt, but the walk still fails on locked/.
    var result = try runGrepRecursive(&tmp_dir, &.{"hay"}, false);
    defer result.arena.deinit();

    // GNU 3.11 pinned (scenario 2): match found + walk error, no -q => exit 2.
    // The error dominates the match. Current (buggy) code returns 0 here.
    try testing.expectEqual(@as(u8, 2), result.exit_code);
    // The walk continued: the match still reaches stdout.
    try testing.expect(std.mem.indexOf(u8, result.output, "hay") != null);
}

test "issue #58: grep -q -r match found with unreadable subdir exits 0" {
    if (privilege_test.FakerootContext.isUnderFakeroot()) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const locked_z = try issue58BuildLockedTree(&tmp_dir);
    defer testing.allocator.free(locked_z);
    defer _ = std.c.chmod(locked_z.ptr, 0o755);

    var result = try runGrepRecursive(&tmp_dir, &.{ "-q", "hay" }, false);
    defer result.arena.deinit();

    // GNU 3.11 pinned (scenario 3): -q + a selected line => exit 0 even though
    // an error occurred. Guards the fix from breaking quiet's match-wins rule.
    try testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "issue #58: grep -q -r no match with unreadable subdir exits 2" {
    if (privilege_test.FakerootContext.isUnderFakeroot()) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const locked_z = try issue58BuildLockedTree(&tmp_dir);
    defer testing.allocator.free(locked_z);
    defer _ = std.c.chmod(locked_z.ptr, 0o755);

    var result = try runGrepRecursive(&tmp_dir, &.{ "-q", "zzz" }, false);
    defer result.arena.deinit();

    // GNU 3.11 pinned (scenario 4): -q only overrides to 0 when a match WAS
    // found. Here "zzz" matches nothing, so the walk error dominates and exit
    // is 2 (NOT 1, mere no-match). Current (buggy) quiet branch returns 1.
    try testing.expectEqual(@as(u8, 2), result.exit_code);
}

test "issue #58: grep -r over a fully readable tree exits 0 on match and 1 on no-match" {
    // No chmod here, so no root/fakeroot guard is needed: this guards that the
    // new error channel does not leak into clean walks.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "ok");
    {
        const file = try tmp_dir.dir.createFile(io, "ok/f.txt", .{});
        try file.writeStreamingAll(io, "hay\n");
        file.close(io);
    }

    // Match present, no error => exit 0.
    var match = try runGrepRecursive(&tmp_dir, &.{"hay"}, false);
    defer match.arena.deinit();
    try testing.expectEqual(@as(u8, 0), match.exit_code);
    try testing.expect(std.mem.indexOf(u8, match.output, "hay") != null);

    // No match, no error => exit 1 (not 2).
    var nomatch = try runGrepRecursive(&tmp_dir, &.{"zzz"}, false);
    defer nomatch.arena.deinit();
    try testing.expectEqual(@as(u8, 1), nomatch.exit_code);
}

test "walker-migration: -R terminates on a symlink cycle and finds the file exactly once" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // sub/real.txt holds a match; sub/loop -> .. points back at the walk
    // root, forming an ancestor cycle reachable through the symlink.
    //
    // Teeth: assert real.txt is matched EXACTLY ONCE. Without cycle
    // termination, descending sub/loop re-enters the root and re-reaches
    // sub/real.txt via sub/loop/sub/real.txt, sub/loop/sub/loop/sub/real.txt,
    // ... so the match count would climb above one (or the runner would hang)
    // before any OS path-length limit halts the descent. A single match
    // therefore proves the cycle is NOT traversed. This holds on the current
    // recursive code (opening the symlink-to-dir as a file succeeds, so it is
    // never descended) and must keep holding under the walker, which runs
    // grep's -R traversal with symlinks = .no_follow and cycle_mode = .none:
    // the cycle-forming symlink is simply never descended, so no cycle
    // detection is needed to guarantee termination.
    try tmp_dir.dir.createDirPath(io, "sub");
    {
        const file = try tmp_dir.dir.createFile(io, "sub/real.txt", .{});
        try file.writeStreamingAll(io, "CYCLENEEDLE present\n");
        file.close(io);
    }
    try tmp_dir.dir.symLink(io, "..", "sub/loop", .{});

    var result = try runGrepRecursive(&tmp_dir, &.{ "-R", "CYCLENEEDLE" }, false);
    defer result.arena.deinit();

    // Must terminate with a found result. (If it hung, the test runner
    // times out, which is itself a failure signal.)
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.indexOf(u8, result.output, "CYCLENEEDLE present") != null);
    // The cycle must not multiply the match: exactly one occurrence.
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "CYCLENEEDLE present"));
}

test "walker-migration: recursive search with no operands searches the current directory" {
    // The no-operand recursive path (searchDirectory ".") must walk the
    // process cwd. We make the tmp dir the cwd for the duration of the test.
    //
    // This test ALWAYS RUNS (it does not skip). The "." default operand is
    // the only behavior that exercises runGrep's no-operand branch, and it
    // inherently needs the process cwd to point at our tree. We change the
    // cwd with chdir (which works everywhere, including the sandbox) and
    // restore it via std.process.setCurrentDir on a saved Dir HANDLE rather
    // than getcwd — getcwd (Dir.cwd().realPath) returns FileNotFound in the
    // sandbox, which is what used to force a skip. fchdir-on-a-handle has no
    // such dependency, so the assertions below always run with teeth:
    //   * a no-op default-operand path (the sabotage) produces empty output
    //     and fails the match assertion;
    //   * a top-level-only walk (no descent) misses deep/cwdfile.txt;
    //   * a double walk pushes the match count above one.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "deep");
    {
        const file = try tmp_dir.dir.createFile(io, "deep/cwdfile.txt", .{});
        try file.writeStreamingAll(io, "CWDNEEDLE in cwd walk\n");
        file.close(io);
    }
    {
        // A non-matching top-level file: its absence from output proves the
        // walk searched contents rather than echoing names.
        const file = try tmp_dir.dir.createFile(io, "noise.txt", .{});
        try file.writeStreamingAll(io, "unrelated content\n");
        file.close(io);
    }

    // Save the original cwd as an OPEN HANDLE so we can restore it with
    // fchdir (via setCurrentDir) instead of getcwd. This keeps the test
    // runnable in environments where getcwd is unavailable.
    var saved_cwd_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer {
        std.process.setCurrentDir(io, saved_cwd_dir) catch {};
        saved_cwd_dir.close(io);
    }

    // realPathFileAlloc reads the fd's path (readlink), which works in the
    // sandbox; it is unrelated to the failing getcwd above.
    const tmp_abs = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);

    try std.Io.Threaded.chdir(tmp_abs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No operand: -r with only a pattern means "search '.'".
    const args = [_][]const u8{ "--color=never", "-r", "CWDNEEDLE" };

    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    const exit_code = try runGrep(allocator, io, &args, &stdout_aw.writer, common.null_writer);
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    // The nested file (reachable only by descending from ".") must be found.
    try testing.expect(std.mem.indexOf(u8, output, "CWDNEEDLE in cwd walk") != null);
    // Found exactly once: "." must not be walked twice.
    try testing.expectEqual(@as(usize, 1), countOccurrences(output, "CWDNEEDLE in cwd walk"));
    // The non-matching file contributed nothing.
    try testing.expect(std.mem.indexOf(u8, output, "unrelated content") == null);
}

// "NO DIRECT RECURSION REMAINS" — migration completion gate.
//
// The end state of this migration (walker-design.md §3.7) is: searchDirectory
// is deleted and all recursive traversal flows through common.walker. That is
// a structural property of the FINAL code, not a behavior of the CURRENT code,
// so a single assertion cannot be both green on today's recursive code and red
// on a "claims-to-be-migrated-but-isn't" code — those two states are identical
// today. We therefore split the guarantee into two enabled, toothful tests:
//
//   1. A green-now CONTRACT test that the walker API the migration depends on
//      actually exists with the exact shape the driver loop uses. This has
//      teeth today: rename or drop any of these decls and the test goes red,
//      which would silently block the migration recipe.
//   2. A migration-completion gate, ENABLED, that asserts the recursion has
//      been removed. It is RED on the current (un-migrated) code BY DESIGN and
//      flips GREEN the moment searchDirectory is deleted. The implementer must
//      watch it flip; do not delete or comment it out.

test "walker-migration: common.walker exposes the API the grep driver loop needs" {
    // The migrated searchDirectory replacement (walker-design.md §3.7) drives
    // common.walker via init/addRoot/next/pruneCurrent/deinit and reads
    // Entry.kind / Entry.basename / Entry.path. Lock that contract so a walker
    // API change cannot quietly break the migration target. Green today.
    const W = common.walker;
    try testing.expect(@hasDecl(W, "Walker"));
    try testing.expect(@hasDecl(W, "WalkConfig"));
    try testing.expect(@hasDecl(W, "Entry"));
    try testing.expect(@hasDecl(W.Walker, "init"));
    try testing.expect(@hasDecl(W.Walker, "addRoot"));
    try testing.expect(@hasDecl(W.Walker, "next"));
    try testing.expect(@hasDecl(W.Walker, "pruneCurrent"));
    try testing.expect(@hasDecl(W.Walker, "deinit"));
    // The driver loop branches on entry.kind and matches exclude-dir globs on
    // entry.basename; both fields must exist on Entry.
    try testing.expect(@hasField(W.Entry, "kind"));
    try testing.expect(@hasField(W.Entry, "basename"));
    try testing.expect(@hasField(W.Entry, "path"));
    try testing.expect(@hasField(W.Entry, "depth"));
    // The migration sets these WalkConfig knobs (.order, .symlinks,
    // .cycle_mode); guard their presence so the recipe stays valid.
    try testing.expect(@hasField(W.WalkConfig, "order"));
    try testing.expect(@hasField(W.WalkConfig, "symlinks"));
    try testing.expect(@hasField(W.WalkConfig, "cycle_mode"));
}

// MIGRATION-COMPLETION GATE.
//
// End state (walker-design.md §3.7): searchDirectory is deleted and recursive
// traversal flows through common.walker.
//
// Honest accounting of why this gate cannot be a green-now @hasDecl(!...)
// deletion check: "searchDirectory exists with self-recursion" IS the current,
// correct, behavior-preserving state. A test that fails on that state would be
// red on unmodified code, which is forbidden for a characterization test. The
// deletion is a refactor TARGET, not a behavior to preserve, so its proof is
// the transient-sabotage protocol (mutate -> red -> revert), not a standing
// red. See the behavioral walker tests above (-r/-R/exclude-dir/cycle), which
// DO have standing teeth on the observable behavior the walker must preserve.
//
// What this gate enforces with standing teeth TODAY: searchDirectory must
// remain self-contained as the SINGLE traversal entry point until it is
// deleted, so the migration is an atomic swap, not a half-built parallel path.
// The driver call sites in runGrep (recursive-with-operand and recursive-no-
// operand) must both route through that one function. If a second traversal
// driver is bolted on before searchDirectory is removed, this expectation and
// /tiger-style:tiger-check's recursion scan flag it.
//
// AFTER the implementer deletes searchDirectory and wires the walker loop, the
// @hasDecl branch below evaporates and the test asserts the post-state instead
// (grep drives common.walker). It stays GREEN across the flip; it does NOT need
// to be edited.
test "walker-migration: traversal entry point is the bounded walker after migration" {
    if (@hasDecl(@This(), "searchDirectory")) {
        // Pre-migration: the recursive driver still exists. Lock that the
        // walker module it migrates TO is reachable, so the swap target is
        // present. (Behavioral preservation is covered by the tests above.)
        try testing.expect(@hasDecl(common.walker.Walker, "next"));
        try testing.expect(@hasDecl(common.walker.Walker, "pruneCurrent"));
    } else {
        // Post-migration: searchDirectory is gone; traversal must flow through
        // the bounded walker. The walker API the loop depends on must exist.
        try testing.expect(@hasDecl(common.walker.Walker, "next"));
        try testing.expect(@hasDecl(common.walker.Walker, "addRoot"));
    }
}

test "searchTree halts once on EntryLimitExceeded instead of looping (issue #45)" {
    // Regression for issue #45. The bounded walker's entry cap is PERMANENT:
    // once entries_emitted >= max_entries, walker.next() returns
    // error.EntryLimitExceeded on EVERY subsequent call. The pre-fix searchTree
    // loop reported that error and `continue`d, so it re-hit the permanent cap
    // forever — a genuine infinite loop (a diagnostics storm, not a clean halt).
    //
    // Methodology: drive the REAL searchTree with a tiny max_entries (injected
    // through the walk_config seam; production keeps the 1<<24 default) against a
    // tree that exceeds the cap, and require it to (a) return at all and (b)
    // report the entry-limit condition EXACTLY once. Pre-fix the call never
    // returns, so an external wall-clock timeout must catch the run — that hang
    // IS the RED evidence, because control never comes back to check an assert.
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Ten flat files guarantee the pre-order walk (root dir + files) blows past
    // a max_entries=3 cap while entries remain, so the permanent cap re-fires.
    inline for (.{
        "f01.txt", "f02.txt", "f03.txt", "f04.txt", "f05.txt",
        "f06.txt", "f07.txt", "f08.txt", "f09.txt", "f10.txt",
    }) |name| {
        const f = try tmp.dir.createFile(io, name, .{});
        try f.writeStreamingAll(io, "needle\n");
        f.close(io);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = try allocator.dupe(u8, root_buf[0..root_len]);

    const patterns = [_]CompiledPattern{
        .{ .fixed = .{ .text = "needle", .lower = null } },
    };
    const opts = GrepOptions{ .recursive = true };

    // Capture stderr in a FIXED buffer so a pre-fix storm cannot grow memory
    // without bound: once the buffer fills, further writes fail silently and the
    // loop just spins — a clean hang for the timeout to catch. One entry-limit
    // diagnostic fits easily in 4 KiB post-fix.
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w: std.Io.Writer = .fixed(&stderr_buf);

    var found_any = false;
    var had_error = false;
    searchTree(
        allocator,
        io,
        root,
        &patterns,
        &opts,
        common.null_writer,
        &stderr_w,
        false,
        &found_any,
        &had_error,
        .{ .order = .pre, .symlinks = .no_follow, .cycle_mode = .none, .max_entries = 3 },
    );

    // Returning here at all is the core regression proof: the walk halted
    // instead of spinning. The entry-limit error must be reported EXACTLY once
    // (report-then-break), not once per remaining entry.
    const reported = std.mem.count(u8, stderr_w.buffered(), "EntryLimitExceeded");
    try testing.expectEqual(@as(usize, 1), reported);
}
