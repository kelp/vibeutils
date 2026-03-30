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

const Allocator = std.mem.Allocator;

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
    include_globs: std.ArrayListUnmanaged([]const u8) = .{},
    exclude_globs: std.ArrayListUnmanaged([]const u8) = .{},
    exclude_dirs: std.ArrayListUnmanaged([]const u8) = .{},
    patterns: std.ArrayListUnmanaged([]const u8) = .{},
    pattern_file_contents: std.ArrayListUnmanaged([]const u8) = .{},
    files: std.ArrayListUnmanaged([]const u8) = .{},
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
fn parseArgs(allocator: Allocator, args: []const []const u8, stderr_writer: anytype) !?GrepOptions {
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
            } else if (std.mem.startsWith(u8, flag, "regexp=")) {
                try opts.patterns.append(allocator, flag["regexp=".len..]);
            } else if (std.mem.startsWith(u8, flag, "file=")) {
                const pattern_file = flag["file=".len..];
                try loadPatternsFromFile(allocator, &opts.patterns, &opts.pattern_file_contents, pattern_file, stderr_writer);
            } else if (std.mem.startsWith(u8, flag, "max-count=")) {
                const val_str = flag["max-count=".len..];
                opts.max_count = std.fmt.parseInt(usize, val_str, 10) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid max count '{s}'", .{val_str});
                    return null;
                };
            } else if (std.mem.startsWith(u8, flag, "after-context=")) {
                const val_str = flag["after-context=".len..];
                opts.after_context = std.fmt.parseInt(usize, val_str, 10) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid context length argument", .{});
                    return null;
                };
            } else if (std.mem.startsWith(u8, flag, "before-context=")) {
                const val_str = flag["before-context=".len..];
                opts.before_context = std.fmt.parseInt(usize, val_str, 10) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid context length argument", .{});
                    return null;
                };
            } else if (std.mem.startsWith(u8, flag, "context=")) {
                const val_str = flag["context=".len..];
                const ctx = std.fmt.parseInt(usize, val_str, 10) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid context length argument", .{});
                    return null;
                };
                opts.before_context = ctx;
                opts.after_context = ctx;
            } else if (std.mem.eql(u8, flag, "color") or std.mem.eql(u8, flag, "colour")) {
                opts.color = .on;
            } else if (std.mem.startsWith(u8, flag, "color=") or std.mem.startsWith(u8, flag, "colour=")) {
                const eq_pos = std.mem.indexOfScalar(u8, flag, '=').?;
                const when = flag[eq_pos + 1 ..];
                if (std.mem.eql(u8, when, "auto")) {
                    // Keep resolved value (TTY-dependent)
                } else if (std.mem.eql(u8, when, "always")) {
                    opts.color = .on;
                } else if (std.mem.eql(u8, when, "never")) {
                    opts.color = .off;
                } else {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid argument '{s}' for '--color'", .{when});
                    return null;
                }
            } else if (std.mem.startsWith(u8, flag, "include=")) {
                try opts.include_globs.append(allocator, flag["include=".len..]);
            } else if (std.mem.startsWith(u8, flag, "exclude=")) {
                try opts.exclude_globs.append(allocator, flag["exclude=".len..]);
            } else if (std.mem.startsWith(u8, flag, "exclude-dir=")) {
                try opts.exclude_dirs.append(allocator, flag["exclude-dir=".len..]);
            } else if (std.mem.startsWith(u8, flag, "label=")) {
                opts.stdin_label = flag["label=".len..];
            } else if (std.mem.eql(u8, flag, "line-buffered")) {
                // No-op: we flush appropriately already
            } else if (std.mem.startsWith(u8, flag, "binary-files=")) {
                // Stub: accept silently (we treat all files as text)
            } else if (std.mem.eql(u8, flag, "mmap")) {
                // No-op: deprecated, accept silently
            } else if (std.mem.startsWith(u8, flag, "include-dir=")) {
                // No-op stub: accept with value, silently ignore
            } else if (std.mem.eql(u8, flag, "null-data")) {
                opts.null_line_sep = true;
            } else {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "unrecognized option '--{s}'", .{flag});
                return null;
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            // Short options
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
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
                    'P' => {
                        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "-P (Perl regex) not supported", .{});
                        return null;
                    },
                    'r' => opts.recursive = true,
                    'R' => {
                        opts.dereference_recursive = true;
                        opts.recursive = true;
                    },
                    'e' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'e'", .{});
                            return null;
                        };
                        try opts.patterns.append(allocator, value);
                        break; // consumed rest of this arg
                    },
                    'f' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'f'", .{});
                            return null;
                        };
                        try loadPatternsFromFile(allocator, &opts.patterns, &opts.pattern_file_contents, value, stderr_writer);
                        break;
                    },
                    'm' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'm'", .{});
                            return null;
                        };
                        opts.max_count = std.fmt.parseInt(usize, value, 10) catch {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid max count '{s}'", .{value});
                            return null;
                        };
                        break;
                    },
                    'A' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'A'", .{});
                            return null;
                        };
                        opts.after_context = std.fmt.parseInt(usize, value, 10) catch {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid context length argument", .{});
                            return null;
                        };
                        break;
                    },
                    'B' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'B'", .{});
                            return null;
                        };
                        opts.before_context = std.fmt.parseInt(usize, value, 10) catch {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid context length argument", .{});
                            return null;
                        };
                        break;
                    },
                    'C' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'C'", .{});
                            return null;
                        };
                        const ctx = std.fmt.parseInt(usize, value, 10) catch {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid context length argument", .{});
                            return null;
                        };
                        opts.before_context = ctx;
                        opts.after_context = ctx;
                        break;
                    },
                    'd' => {
                        const value = if (j + 1 < arg.len)
                            arg[j + 1 ..]
                        else if (i + 1 < args.len) blk: {
                            i += 1;
                            break :blk args[i];
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'd'", .{});
                            return null;
                        };
                        if (std.mem.eql(u8, value, "recurse")) {
                            opts.recursive = true;
                        } else if (std.mem.eql(u8, value, "skip")) {
                            opts.skip_dirs = true;
                        }
                        // "read" is the default behavior, no action needed
                        break;
                    },
                    'D' => {
                        // Device action stub: accept value, silently ignore
                        if (j + 1 < arg.len) {
                            // Value is rest of this arg
                        } else if (i + 1 < args.len) {
                            i += 1;
                        } else {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument -- 'D'", .{});
                            return null;
                        }
                        break;
                    },
                    else => {
                        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid option -- '{c}'", .{ch});
                        return null;
                    },
                }
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

/// Load patterns from a file, one per line
fn loadPatternsFromFile(allocator: Allocator, patterns: *std.ArrayListUnmanaged([]const u8), pattern_file_contents: *std.ArrayListUnmanaged([]const u8), path: []const u8, stderr_writer: anytype) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}: No such file or directory", .{path});
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

/// Compile a single pattern. Returns null on error.
fn compilePattern(allocator: Allocator, pattern: []const u8, opts: *const GrepOptions, stderr_writer: anytype) ?CompiledPattern {
    if (opts.regex_mode == .fixed) {
        if (opts.ignore_case) {
            const lower = toLower(allocator, pattern) catch return null;
            return .{ .fixed = .{ .text = pattern, .lower = lower } };
        }
        return .{ .fixed = .{ .text = pattern, .lower = null } };
    }

    // Build the actual regex pattern, handling -w and -x wrapping
    var actual_pattern: []const u8 = pattern;

    if (opts.line_regexp) {
        if (opts.regex_mode == .extended) {
            actual_pattern = std.fmt.allocPrint(allocator, "^({s})$", .{pattern}) catch return null;
        } else {
            actual_pattern = std.fmt.allocPrint(allocator, "^\\({s}\\)$", .{pattern}) catch return null;
        }
    } else if (opts.word_regexp) {
        if (opts.regex_mode == .extended) {
            actual_pattern = std.fmt.allocPrint(allocator, "(^|[^[:alnum:]_])({s})([^[:alnum:]_]|$)", .{pattern}) catch return null;
        } else {
            actual_pattern = std.fmt.allocPrint(allocator, "\\(^\\|[^[:alnum:]_]\\)\\({s}\\)\\([^[:alnum:]_]\\|$\\)", .{pattern}) catch return null;
        }
    }

    var cflags: c_int = 0;
    if (opts.regex_mode == .extended) cflags |= c.REG_EXTENDED;
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
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid regular expression: {s}", .{err_msg});
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

/// Check if a line matches a compiled pattern.
/// When word_regexp is true and the pattern is a regex, the match positions
/// are taken from submatch group 2 (the actual word) rather than group 0
/// (which includes boundary characters added by the -w wrapping).
fn matchLine(pat: *const CompiledPattern, line: []const u8, allocator: Allocator, word_regexp: bool) MatchResult {
    switch (pat.*) {
        .fixed => |fp| {
            if (fp.lower) |lower_pattern| {
                const lower_line = toLower(allocator, line) catch return .{ .matched = false };
                defer allocator.free(lower_line);
                if (std.mem.indexOf(u8, lower_line, lower_pattern)) |pos| {
                    return .{ .matched = true, .match_start = pos, .match_end = pos + lower_pattern.len };
                }
                return .{ .matched = false };
            }
            if (std.mem.indexOf(u8, line, fp.text)) |pos| {
                return .{ .matched = true, .match_start = pos, .match_end = pos + fp.text.len };
            }
            return .{ .matched = false };
        },
        .regex => |re| {
            const line_z = allocator.dupeZ(u8, line) catch return .{ .matched = false };
            defer allocator.free(line_z);
            if (word_regexp) {
                // -w wraps pattern as (boundary)(word)(boundary) with 3 groups.
                // We need group 2 for the actual word match positions.
                var pmatch: [4]c.regmatch_t = undefined;
                const exec_result = c.regexec(re, line_z.ptr, 4, &pmatch, 0);
                if (exec_result == 0) {
                    // Use group 2 (the word itself) if available, fall back to group 0
                    const grp: usize = if (pmatch[2].rm_so >= 0) 2 else 0;
                    const start: usize = if (pmatch[grp].rm_so >= 0) @intCast(pmatch[grp].rm_so) else 0;
                    const end: usize = if (pmatch[grp].rm_eo >= 0) @intCast(pmatch[grp].rm_eo) else 0;
                    return .{ .matched = true, .match_start = start, .match_end = end };
                }
                return .{ .matched = false };
            } else {
                var pmatch: [1]c.regmatch_t = undefined;
                const exec_result = c.regexec(re, line_z.ptr, 1, &pmatch, 0);
                if (exec_result == 0) {
                    const start: usize = if (pmatch[0].rm_so >= 0) @intCast(pmatch[0].rm_so) else 0;
                    const end: usize = if (pmatch[0].rm_eo >= 0) @intCast(pmatch[0].rm_eo) else 0;
                    return .{ .matched = true, .match_start = start, .match_end = end };
                }
                return .{ .matched = false };
            }
        },
    }
}

/// Check if a line matches any of the compiled patterns
fn matchAnyPattern(patterns: []const CompiledPattern, line: []const u8, allocator: Allocator, word_regexp: bool) MatchResult {
    for (patterns) |*pat| {
        const result = matchLine(pat, line, allocator, word_regexp);
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
fn printFilename(writer: anytype, filename: []const u8, use_color: bool) void {
    if (use_color) {
        writer.print("{s}{s}{s}", .{ Color.filename, filename, Color.reset }) catch {};
    } else {
        writer.print("{s}", .{filename}) catch {};
    }
}

/// Print a line number
fn printLineNumber(writer: anytype, line_num: usize, use_color: bool) void {
    if (use_color) {
        writer.print("{s}{d}{s}", .{ Color.line_number, line_num, Color.reset }) catch {};
    } else {
        writer.print("{d}", .{line_num}) catch {};
    }
}

/// Print a byte offset
fn printByteOffset(writer: anytype, offset: usize, use_color: bool) void {
    if (use_color) {
        writer.print("{s}{d}{s}", .{ Color.line_number, offset, Color.reset }) catch {};
    } else {
        writer.print("{d}", .{offset}) catch {};
    }
}

/// Print a separator character
fn printSep(writer: anytype, sep: u8, use_color: bool) void {
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
fn printMatchLine(writer: anytype, line: []const u8, match_start: usize, match_end: usize, use_color: bool, terminator: u8) void {
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
    file: std.fs.File,
    filename: []const u8,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: anytype,
    show_filename: bool,
    use_color: bool,
) bool {
    const content = file.readToEndAlloc(allocator, 512 * 1024 * 1024) catch return false;
    defer allocator.free(content);

    var found_match = false;
    var match_count: usize = 0;
    var line_num: usize = 0;

    // Determine the line delimiter: NUL for -z/--null-data, newline otherwise
    const line_delim: u8 = if (opts.null_line_sep) 0 else '\n';

    // Determine filename separator: NUL for --null/-Z, colon otherwise
    const fn_sep: u8 = if (opts.null_data) 0 else ':';

    // Determine line terminator for output: NUL for -z, newline otherwise
    const line_term: u8 = if (opts.null_line_sep) 0 else '\n';

    // Split into lines, tracking byte offsets
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);
    var line_offsets = std.ArrayListUnmanaged(usize){};
    defer line_offsets.deinit(allocator);
    {
        var start: usize = 0;
        for (content, 0..) |ch, idx| {
            if (ch == line_delim) {
                lines.append(allocator, content[start..idx]) catch return false;
                line_offsets.append(allocator, start) catch return false;
                start = idx + 1;
            }
        }
        if (start < content.len) {
            lines.append(allocator, content[start..]) catch return false;
            line_offsets.append(allocator, start) catch return false;
        }
    }

    // Context tracking
    const has_context = opts.before_context > 0 or opts.after_context > 0;
    var last_printed_line: ?usize = null;
    var remaining_after: usize = 0;

    for (lines.items) |line| {
        line_num += 1;

        const result = matchAnyPattern(patterns, line, allocator, opts.word_regexp);
        const is_match = if (opts.invert_match) !result.matched else result.matched;

        if (is_match) {
            found_match = true;
            match_count += 1;

            if (opts.quiet) return true;

            if (!opts.count and !opts.files_with_matches and !opts.files_without_match) {
                // Print before-context lines
                if (has_context and opts.before_context > 0) {
                    const ctx_start = if (line_num > opts.before_context) line_num - opts.before_context else 1;
                    const already_printed = if (last_printed_line) |lp| lp + 1 else 0;
                    const effective_start = @max(ctx_start, already_printed);

                    // Print group separator if there's a gap
                    if (last_printed_line) |lp| {
                        if (effective_start > lp + 1) {
                            stdout_writer.writeAll("--\n") catch {};
                        }
                    }

                    var ctx_line = effective_start;
                    while (ctx_line < line_num) : (ctx_line += 1) {
                        printContextLine(stdout_writer, lines.items[ctx_line - 1], ctx_line, filename, show_filename, opts.line_number, opts.byte_offset, line_offsets.items[ctx_line - 1], use_color, fn_sep, line_term);
                        last_printed_line = ctx_line;
                    }
                }

                // Print the matching line
                if (last_printed_line) |lp| {
                    if (has_context and line_num > lp + 1 and opts.before_context == 0) {
                        stdout_writer.writeAll("--\n") catch {};
                    }
                }

                if (opts.only_matching and !opts.invert_match) {
                    // Print all non-overlapping matches on this line, each on its own output line.
                    var search_offset: usize = 0;
                    var cur_result = result;
                    while (cur_result.matched and cur_result.match_end > cur_result.match_start and search_offset + cur_result.match_end <= line.len) {
                        if (show_filename) {
                            printFilename(stdout_writer, filename, use_color);
                            printSep(stdout_writer, fn_sep, use_color);
                        }
                        if (opts.line_number) {
                            printLineNumber(stdout_writer, line_num, use_color);
                            printSep(stdout_writer, ':', use_color);
                        }
                        if (opts.byte_offset) {
                            printByteOffset(stdout_writer, line_offsets.items[line_num - 1] + search_offset + cur_result.match_start, use_color);
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
                        cur_result = matchAnyPattern(patterns, line[search_offset..], allocator, opts.word_regexp);
                    }
                } else {
                    if (show_filename) {
                        printFilename(stdout_writer, filename, use_color);
                        printSep(stdout_writer, fn_sep, use_color);
                    }
                    if (opts.line_number) {
                        printLineNumber(stdout_writer, line_num, use_color);
                        printSep(stdout_writer, ':', use_color);
                    }
                    if (opts.byte_offset) {
                        printByteOffset(stdout_writer, line_offsets.items[line_num - 1], use_color);
                        printSep(stdout_writer, ':', use_color);
                    }
                    if (!opts.invert_match) {
                        printMatchLine(stdout_writer, line, result.match_start, result.match_end, use_color, line_term);
                    } else {
                        stdout_writer.writeAll(line) catch {};
                        stdout_writer.writeByte(line_term) catch {};
                    }
                }
                last_printed_line = line_num;
                remaining_after = opts.after_context;
            }

            if (opts.max_count) |mc| {
                if (match_count >= mc) break;
            }
        } else if (remaining_after > 0) {
            // Print after-context line
            printContextLine(stdout_writer, line, line_num, filename, show_filename, opts.line_number, opts.byte_offset, line_offsets.items[line_num - 1], use_color, fn_sep, line_term);
            last_printed_line = line_num;
            remaining_after -= 1;
        }
    }

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

    return found_match;
}

/// Print a context line (with - separator instead of :)
fn printContextLine(writer: anytype, line: []const u8, line_num: usize, filename: []const u8, show_filename: bool, show_line_number: bool, show_byte_offset: bool, byte_offset: usize, use_color: bool, fn_sep: u8, line_term: u8) void {
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

/// Recursively search a directory
fn searchDirectory(
    allocator: Allocator,
    dir_path: []const u8,
    patterns: []const CompiledPattern,
    opts: *const GrepOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
    use_color: bool,
    found_any: *bool,
) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (!opts.no_messages) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}: {s}", .{ dir_path, @errorName(err) });
        }
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Build full path
        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => {
                if (!shouldExcludeDir(entry.name, opts)) {
                    searchDirectory(allocator, full_path, patterns, opts, stdout_writer, stderr_writer, use_color, found_any);
                }
            },
            .file => {
                if (shouldIncludeFile(entry.name, opts)) {
                    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
                        if (!opts.no_messages) {
                            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}: {s}", .{ full_path, @errorName(err) });
                        }
                        continue;
                    };
                    defer file.close();
                    if (processFile(allocator, file, full_path, patterns, opts, stdout_writer, true, use_color)) {
                        found_any.* = true;
                    }
                }
            },
            .sym_link => {
                if (opts.dereference_recursive) {
                    // Follow symlink - try as file first, then as directory
                    if (shouldIncludeFile(entry.name, opts)) {
                        const file = std.fs.cwd().openFile(full_path, .{}) catch {
                            // Might be a directory symlink
                            if (!shouldExcludeDir(entry.name, opts)) {
                                searchDirectory(allocator, full_path, patterns, opts, stdout_writer, stderr_writer, use_color, found_any);
                            }
                            continue;
                        };
                        defer file.close();
                        if (processFile(allocator, file, full_path, patterns, opts, stdout_writer, true, use_color)) {
                            found_any.* = true;
                        }
                    }
                }
            },
            else => {},
        }
    }
}

// ============================================================================
// Help and Version
// ============================================================================

fn printHelp(allocator: Allocator, writer: anytype) !void {
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

fn printVersion(writer: anytype) !void {
    writer.print("grep ({s}) {s}\n", .{ common.name, common.version }) catch {};
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = runGrep(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) std.process.exit(exit_code);
}

/// Public entry point for the grep utility
pub fn runGrep(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) u8 {
    var opts = (parseArgs(allocator, args, stderr_writer) catch {
        return @intFromEnum(common.ExitCode.misuse);
    }) orelse return @intFromEnum(common.ExitCode.misuse);
    defer opts.deinit(allocator);

    if (opts.help) {
        printHelp(allocator, stdout_writer) catch {};
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        printVersion(stdout_writer) catch {};
        return @intFromEnum(common.ExitCode.success);
    }

    // Must have at least one pattern
    if (opts.patterns.items.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "no pattern specified\nTry 'grep --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Compile patterns
    var compiled = std.ArrayListUnmanaged(CompiledPattern){};
    defer {
        for (compiled.items) |*cp| freePattern(allocator, cp);
        compiled.deinit(allocator);
    }

    for (opts.patterns.items) |pattern| {
        const cp = compilePattern(allocator, pattern, &opts, stderr_writer) orelse {
            return @intFromEnum(common.ExitCode.misuse);
        };
        compiled.append(allocator, cp) catch return @intFromEnum(common.ExitCode.misuse);
    }

    // Determine color usage
    const use_color = opts.color == .on;

    // Determine filename display:
    //   --no-filename (-h) always suppresses
    //   --with-filename (-H) always shows
    //   default: show if multiple files or recursive
    const show_filename = if (opts.no_filename)
        false
    else if (opts.with_filename)
        true
    else if (opts.recursive)
        true
    else
        opts.files.items.len > 1;

    var found_any = false;
    var had_error = false;

    // Determine stdin label (--label overrides default)
    const stdin_label = opts.stdin_label orelse "(standard input)";

    if (opts.files.items.len == 0 and !opts.recursive) {
        // Read from stdin
        const stdin_file = std.fs.File.stdin();
        if (processFile(allocator, stdin_file, stdin_label, compiled.items, &opts, stdout_writer, show_filename, use_color)) {
            found_any = true;
        }
    } else if (opts.files.items.len == 0 and opts.recursive) {
        // Recursive with no files means search current directory
        searchDirectory(allocator, ".", compiled.items, &opts, stdout_writer, stderr_writer, use_color, &found_any);
    } else {
        for (opts.files.items) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                const stdin_file = std.fs.File.stdin();
                if (processFile(allocator, stdin_file, stdin_label, compiled.items, &opts, stdout_writer, show_filename, use_color)) {
                    found_any = true;
                }
                continue;
            }

            if (opts.recursive or opts.skip_dirs) {
                // Check if it's a directory
                const stat = std.fs.cwd().statFile(file_path) catch |err| {
                    if (!opts.no_messages) {
                        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}: {s}", .{ file_path, @errorName(err) });
                    }
                    had_error = true;
                    continue;
                };
                if (stat.kind == .directory) {
                    if (opts.skip_dirs) continue; // -d skip: silently skip
                    searchDirectory(allocator, file_path, compiled.items, &opts, stdout_writer, stderr_writer, use_color, &found_any);
                    continue;
                }
            }

            const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                if (!opts.no_messages) {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}: {s}", .{ file_path, @errorName(err) });
                }
                had_error = true;
                continue;
            };
            defer file.close();
            if (processFile(allocator, file, file_path, compiled.items, &opts, stdout_writer, show_filename, use_color)) {
                found_any = true;
            }
            if (opts.quiet and found_any) return 0;
        }
    }

    if (opts.quiet) {
        return if (found_any) 0 else 1;
    }

    if (had_error) return 2;
    return if (found_any) 0 else 1;
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
    return result;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "parseArgs basic pattern" {
    const args = [_][]const u8{"hello"};
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqualStrings("hello", opts.patterns.items[0]);
    try testing.expectEqual(@as(usize, 0), opts.files.items.len);
}

test "parseArgs pattern and files" {
    const args = [_][]const u8{ "pattern", "file1.txt", "file2.txt" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqualStrings("pattern", opts.patterns.items[0]);
    try testing.expectEqual(@as(usize, 2), opts.files.items.len);
    try testing.expectEqualStrings("file1.txt", opts.files.items[0]);
    try testing.expectEqualStrings("file2.txt", opts.files.items[1]);
}

test "parseArgs -e multiple patterns" {
    const args = [_][]const u8{ "-e", "foo", "-e", "bar" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.patterns.items.len);
    try testing.expectEqualStrings("foo", opts.patterns.items[0]);
    try testing.expectEqualStrings("bar", opts.patterns.items[1]);
}

test "parseArgs -e with files" {
    const args = [_][]const u8{ "-e", "pattern", "file1.txt" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqualStrings("pattern", opts.patterns.items[0]);
    try testing.expectEqual(@as(usize, 1), opts.files.items.len);
    try testing.expectEqualStrings("file1.txt", opts.files.items[0]);
}

test "parseArgs short flags" {
    const args = [_][]const u8{ "-ivn", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.ignore_case);
    try testing.expect(opts.invert_match);
    try testing.expect(opts.line_number);
}

test "parseArgs long flags" {
    const args = [_][]const u8{ "--ignore-case", "--count", "--recursive", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.ignore_case);
    try testing.expect(opts.count);
    try testing.expect(opts.recursive);
}

test "parseArgs regex modes" {
    {
        const args = [_][]const u8{ "-E", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(RegexMode.extended, opts.regex_mode);
    }
    {
        const args = [_][]const u8{ "-F", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(RegexMode.fixed, opts.regex_mode);
    }
    {
        const args = [_][]const u8{ "-G", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(RegexMode.basic, opts.regex_mode);
    }
}

test "parseArgs -m max-count" {
    const args = [_][]const u8{ "-m", "5", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), opts.max_count.?);
}

test "parseArgs context flags" {
    {
        const args = [_][]const u8{ "-A", "3", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 3), opts.after_context);
    }
    {
        const args = [_][]const u8{ "-B", "2", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), opts.before_context);
    }
    {
        const args = [_][]const u8{ "-C", "1", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), opts.before_context);
        try testing.expectEqual(@as(usize, 1), opts.after_context);
    }
}

test "parseArgs color modes" {
    {
        const args = [_][]const u8{ "--color=always", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(common.display_config.ResolvedMode.on, opts.color);
    }
    {
        const args = [_][]const u8{ "--color=never", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(common.display_config.ResolvedMode.off, opts.color);
    }
    {
        const args = [_][]const u8{ "--color=auto", "pattern" };
        var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
        defer opts.deinit(testing.allocator);
        // --color=auto keeps the resolved value; in tests stdout is not a TTY, so .off
        try testing.expectEqual(common.display_config.ResolvedMode.off, opts.color);
    }
}

test "parseArgs -- separator" {
    const args = [_][]const u8{ "-e", "pattern", "--", "-file.txt" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
    try testing.expectEqual(@as(usize, 1), opts.files.items.len);
    try testing.expectEqualStrings("-file.txt", opts.files.items[0]);
}

test "parseArgs invalid option returns null" {
    const args = [_][]const u8{ "-j", "pattern" };
    const result = try parseArgs(testing.allocator, &args, common.null_writer);
    try testing.expect(result == null);
}

test "parseArgs --include and --exclude" {
    const args = [_][]const u8{ "--include=*.c", "--exclude=*.o", "--exclude-dir=.git", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
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
    const result = matchLine(&pattern, "say hello world", testing.allocator, false);
    try testing.expect(result.matched);
    try testing.expectEqual(@as(usize, 4), result.match_start);
    try testing.expectEqual(@as(usize, 9), result.match_end);
}

test "fixed string no match" {
    const pattern = CompiledPattern{ .fixed = .{ .text = "xyz", .lower = null } };
    const result = matchLine(&pattern, "hello world", testing.allocator, false);
    try testing.expect(!result.matched);
}

test "fixed string case insensitive" {
    const lower = try toLower(testing.allocator, "hello");
    defer testing.allocator.free(lower);
    const pattern = CompiledPattern{ .fixed = .{ .text = "Hello", .lower = lower } };
    const result = matchLine(&pattern, "say HELLO world", testing.allocator, false);
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
    const result = matchLine(&pattern, "say hello world", testing.allocator, false);
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
    const result = matchLine(&pattern, "hello world", testing.allocator, false);
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
    const exit_code = runGrep(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runGrep --help returns success" {
    const args = [_][]const u8{"--help"};
    const exit_code = runGrep(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runGrep --version returns success" {
    const args = [_][]const u8{"--version"};
    const exit_code = runGrep(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

/// Helper to run grep in tests with arena allocator (grep is designed for arena usage)
fn testRunGrep(file_content: []const u8, grep_args: []const []const u8) !u8 {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll(file_content);
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    // Use arena for runGrep since it relies on arena-style allocation
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build args list with the temp file path appended
    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);
    try args.append(allocator, "--color=never");
    for (grep_args) |a| {
        try args.append(allocator, a);
    }
    try args.append(allocator, tmp_path);

    return runGrep(allocator, args.items, common.null_writer, common.null_writer);
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
    const exit_code = try testRunGrep("hello.world\nfoo.bar\nhello world\n", &.{ "-F", "hello.world" });
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
    const exit_code = runGrep(arena.allocator(), &args, common.null_writer, common.null_writer);
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
    const exit_code = runGrep(arena.allocator(), &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runGrep -m max-count" {
    const exit_code = try testRunGrep("hello one\nhello two\nhello three\nhello four\n", &.{ "-m", "2", "hello" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

/// Helper to run grep and capture stdout output
fn testRunGrepOutput(file_content: []const u8, grep_args: []const []const u8) !struct { exit_code: u8, output: []const u8, arena: std.heap.ArenaAllocator } {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll(file_content);
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    for (grep_args) |a| {
        try args.append(allocator, a);
    }
    try args.append(allocator, tmp_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    return .{ .exit_code = exit_code, .output = stdout_buf.items, .arena = arena };
}

test "parseArgs -b sets byte_offset" {
    const args = [_][]const u8{ "-b", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.byte_offset);
}

test "parseArgs --byte-offset sets byte_offset" {
    const args = [_][]const u8{ "--byte-offset", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.byte_offset);
}

test "parseArgs -a flag accepted (no-op)" {
    const args = [_][]const u8{ "-a", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --text flag accepted (no-op)" {
    const args = [_][]const u8{ "--text", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -I flag accepted (no-op)" {
    const args = [_][]const u8{ "-I", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -U flag accepted (no-op)" {
    const args = [_][]const u8{ "-U", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --binary flag accepted (no-op)" {
    const args = [_][]const u8{ "--binary", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
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
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_data);
}

test "parseArgs --null sets null_data" {
    const args = [_][]const u8{ "--null", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_data);
}

test "runGrep -lZ uses NUL byte after filename" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world\n");
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-lZ");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should be filename followed by NUL byte (not newline)
    const expected_len = tmp_path.len + 1;
    try testing.expectEqual(expected_len, stdout_buf.items.len);
    try testing.expectEqualStrings(tmp_path, stdout_buf.items[0..tmp_path.len]);
    try testing.expectEqual(@as(u8, 0), stdout_buf.items[tmp_path.len]);
}

test "runGrep -l without -Z uses newline after filename" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world\n");
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-l");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should be filename followed by newline
    const expected_len = tmp_path.len + 1;
    try testing.expectEqual(expected_len, stdout_buf.items.len);
    try testing.expectEqualStrings(tmp_path, stdout_buf.items[0..tmp_path.len]);
    try testing.expectEqual(@as(u8, '\n'), stdout_buf.items[tmp_path.len]);
}

// ============================================================================
// Tests for SHOULD flags
// ============================================================================

// --- No-op stub parse tests ---

test "parseArgs -J flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-J", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -M flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-M", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -O flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-O", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -p flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-p", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -S flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-S", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -u flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-u", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -X flag accepted (no-op stub)" {
    const args = [_][]const u8{ "-X", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -D flag accepted (stub)" {
    const args = [_][]const u8{ "-D", "read", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs -D skip accepted (stub)" {
    const args = [_][]const u8{ "-D", "skip", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --line-buffered accepted (no-op)" {
    const args = [_][]const u8{ "--line-buffered", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --binary-files=text accepted (stub)" {
    const args = [_][]const u8{ "--binary-files=text", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --binary-files=without-match accepted (stub)" {
    const args = [_][]const u8{ "--binary-files=without-match", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --mmap accepted (no-op)" {
    const args = [_][]const u8{ "--mmap", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

test "parseArgs --include-dir=PATTERN accepted (no-op stub)" {
    const args = [_][]const u8{ "--include-dir=src", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.patterns.items.len);
}

// --- -y alias for -i ---

test "parseArgs -y sets ignore_case (alias for -i)" {
    const args = [_][]const u8{ "-y", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.ignore_case);
}

test "runGrep -y case insensitive match" {
    const exit_code = try testRunGrep("Hello World\n", &.{ "-y", "hello" });
    try testing.expectEqual(@as(u8, 0), exit_code);
}

// --- -P error stub ---

test "parseArgs -P returns null (error stub)" {
    const result = try parseArgs(testing.allocator, &[_][]const u8{ "-P", "pattern" }, common.null_writer);
    try testing.expect(result == null);
}

test "runGrep -P returns misuse exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "-P", "pattern", "/dev/null" };
    const exit_code = runGrep(arena.allocator(), &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 2), exit_code);
}

// --- -d directory action ---

test "parseArgs -d recurse sets recursive" {
    const args = [_][]const u8{ "-d", "recurse", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.recursive);
}

test "parseArgs -d skip sets skip_dirs" {
    const args = [_][]const u8{ "-d", "skip", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.skip_dirs);
}

test "parseArgs -d read is default (no change)" {
    const args = [_][]const u8{ "-d", "read", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(!opts.recursive);
    try testing.expect(!opts.skip_dirs);
}

test "runGrep -d skip silently skips directories" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with matching content
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world\n");
    file.close();

    // Create a subdirectory
    try tmp_dir.dir.makeDir("subdir");

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const file_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "test.txt" });
    defer testing.allocator.free(file_path);

    const dir_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "subdir" });
    defer testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-d");
    try args.append(allocator, "skip");
    try args.append(allocator, "hello");
    try args.append(allocator, dir_path);
    try args.append(allocator, file_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    // Should find match in file, skip directory
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "hello world") != null);
}

// --- -z / --null-data (NUL line separator) ---

test "parseArgs -z sets null_line_sep" {
    const args = [_][]const u8{ "-z", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_line_sep);
}

test "parseArgs --null-data sets null_line_sep" {
    const args = [_][]const u8{ "--null-data", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.null_line_sep);
}

test "runGrep -z splits on NUL and terminates with NUL" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with NUL-separated records
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world\x00foo bar\x00hello again\x00");
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-z");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should be NUL-terminated: "hello world\0hello again\0"
    try testing.expectEqualStrings("hello world\x00hello again\x00", stdout_buf.items);
}

// --- --label=LABEL ---

test "parseArgs --label=LABEL sets stdin_label" {
    const args = [_][]const u8{ "--label=MYINPUT", "pattern" };
    var opts = (try parseArgs(testing.allocator, &args, common.null_writer)).?;
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("MYINPUT", opts.stdin_label.?);
}

// --- --null / -Z extended behavior (NUL after filename in normal output) ---

test "runGrep -HZ uses NUL after filename in normal output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world\n");
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-HZ");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should have NUL after filename: "path\0hello world\n"
    const expected = try std.fmt.allocPrint(allocator, "{s}\x00hello world\n", .{tmp_path});
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "runGrep -cZ uses NUL after filename in count output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world\nhello again\n");
    file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(tmp_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Use -H to force filename display with single file
    var args = std.ArrayListUnmanaged([]const u8){};
    try args.append(allocator, "--color=never");
    try args.append(allocator, "-cHZ");
    try args.append(allocator, "hello");
    try args.append(allocator, tmp_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    const exit_code = runGrep(allocator, args.items, stdout_buf.writer(allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should have NUL after filename: "path\02\n"
    const expected = try std.fmt.allocPrint(allocator, "{s}\x002\n", .{tmp_path});
    try testing.expectEqualStrings(expected, stdout_buf.items);
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

    var buf = std.ArrayListUnmanaged(u8){};
    var expected = std.ArrayListUnmanaged(u8){};
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
    // Create a temp dir with a pattern file and a data file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write pattern file containing one pattern per line
    const pattern_file = try tmp_dir.dir.createFile("patterns.txt", .{});
    try pattern_file.writeAll("hello\nworld\n");
    pattern_file.close();

    // Write data file to search
    const data_file = try tmp_dir.dir.createFile("data.txt", .{});
    try data_file.writeAll("hello there\ngoodbye now\nworld peace\n");
    data_file.close();

    const pattern_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "patterns.txt");
    defer testing.allocator.free(pattern_path);

    const data_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "data.txt");
    defer testing.allocator.free(data_path);

    // Use testing.allocator directly (not arena) so leaks are detected
    const args = [_][]const u8{ "--color=never", "-f", pattern_path, data_path };
    const exit_code = runGrep(testing.allocator, &args, common.null_writer, common.null_writer);
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
