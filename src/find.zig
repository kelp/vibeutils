//! find - search for files in a directory hierarchy
//!
//! Walk a file hierarchy rooted at each starting-point path, evaluating
//! a Boolean expression composed of primaries and operators for every
//! file in the tree.
//!
//! This implementation supports a useful subset of POSIX/GNU find.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = std.c;

// C library bindings
extern "c" fn getpwnam(name: [*:0]const u8) ?*const extern struct {
    pw_name: [*:0]u8,
    pw_passwd: [*:0]u8,
    pw_uid: c.uid_t,
    pw_gid: c.gid_t,
    pw_gecos: [*:0]u8,
    pw_dir: [*:0]u8,
    pw_shell: [*:0]u8,
};
extern "c" fn getgrnam(name: [*:0]const u8) ?*const extern struct {
    gr_name: [*:0]u8,
    gr_passwd: [*:0]u8,
    gr_gid: c.gid_t,
    gr_mem: [*][*:0]u8,
};

const prog_name = "find";

// ============================================================================
// Types
// ============================================================================

const FileType = enum {
    regular,
    directory,
    symlink,
    block_device,
    char_device,
    pipe,
    socket,
};

const Comparison = enum {
    exactly,
    greater_than,
    less_than,
};

const SizeUnit = enum {
    bytes, // c
    words, // w (2 bytes)
    blocks, // b (512 bytes, default)
    kilobytes, // k (1024)
    megabytes, // M (1048576)
    gigabytes, // G (1073741824)
};

const SizeExpr = struct {
    cmp: Comparison,
    value: u64,
    unit: SizeUnit,

    fn toBytes(self: SizeExpr) u64 {
        const multiplier: u64 = switch (self.unit) {
            .bytes => 1,
            .words => 2,
            .blocks => 512,
            .kilobytes => 1024,
            .megabytes => 1048576,
            .gigabytes => 1073741824,
        };
        return self.value * multiplier;
    }
};

const TimeExpr = struct {
    cmp: Comparison,
    days: u64,
};

const ExecExpr = struct {
    argv: []const []const u8,
};

const ExprTag = enum {
    name,
    iname,
    file_type,
    size,
    empty,
    newer,
    mtime,
    perm,
    user,
    group,
    path_match,
    print,
    print0,
    delete,
    exec_cmd,
    and_expr,
    or_expr,
    not_expr,
    true_expr,
};

const Expression = struct {
    tag: ExprTag,
    data: ExprData,
};

const ExprData = union {
    pattern: []const u8,
    file_type: FileType,
    size: SizeExpr,
    newer_mtime: i64,
    time: TimeExpr,
    perm_val: u32,
    name_str: []const u8,
    exec_data: ExecExpr,
    binary: BinaryData,
    unary: *Expression,
    none: void,
};

const BinaryData = struct {
    left: *Expression,
    right: *Expression,
};

const FindConfig = struct {
    start_paths: []const []const u8,
    expr: *Expression,
    maxdepth: ?u32 = null,
    mindepth: u32 = 0,
    depth_first: bool = false,
    follow_symlinks: bool = false,
    follow_cmdline_symlinks: bool = false,
    has_action: bool = false,
};

// ============================================================================
// Glob matching
// ============================================================================

/// Match a string against a shell glob pattern.
/// Supports *, ?, [abc], [a-z], [!abc], and \ escaping.
fn globMatch(pattern: []const u8, string: []const u8) bool {
    return globMatchImpl(pattern, string, false);
}

/// Case-insensitive glob matching.
fn globMatchInsensitive(pattern: []const u8, string: []const u8) bool {
    return globMatchImpl(pattern, string, true);
}

fn globMatchImpl(pattern: []const u8, string: []const u8, case_insensitive: bool) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: ?usize = null;

    while (si < string.len or pi < pattern.len) {
        if (pi < pattern.len) {
            switch (pattern[pi]) {
                '*' => {
                    star_pi = pi;
                    star_si = si;
                    pi += 1;
                    continue;
                },
                '?' => {
                    if (si < string.len) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                },
                '[' => {
                    if (si < string.len) {
                        if (matchBracket(pattern, pi, string[si], case_insensitive)) |new_pi| {
                            pi = new_pi;
                            si += 1;
                            continue;
                        }
                    }
                },
                '\\' => {
                    if (pi + 1 < pattern.len) {
                        pi += 1;
                        if (si < string.len and charEq(pattern[pi], string[si], case_insensitive)) {
                            pi += 1;
                            si += 1;
                            continue;
                        }
                    }
                },
                else => {
                    if (si < string.len and charEq(pattern[pi], string[si], case_insensitive)) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                },
            }
        }

        // Backtrack to star
        if (star_pi) |sp| {
            pi = sp + 1;
            star_si = star_si.? + 1;
            si = star_si.?;
            if (si > string.len) return false;
            continue;
        }

        return false;
    }

    return true;
}

fn charEq(a: u8, b: u8, case_insensitive: bool) bool {
    if (case_insensitive) {
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }
    return a == b;
}

/// Match a bracket expression [abc], [a-z], [!abc].
/// Returns the new pattern index past ']' on match, null otherwise.
fn matchBracket(pattern: []const u8, start: usize, ch: u8, case_insensitive: bool) ?usize {
    var pi = start + 1; // skip '['
    if (pi >= pattern.len) return null;

    var negate = false;
    if (pattern[pi] == '!' or pattern[pi] == '^') {
        negate = true;
        pi += 1;
    }

    var matched = false;
    var first = true;

    while (pi < pattern.len and (first or pattern[pi] != ']')) {
        first = false;
        if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
            // Range
            const lo = if (case_insensitive) std.ascii.toLower(pattern[pi]) else pattern[pi];
            const hi = if (case_insensitive) std.ascii.toLower(pattern[pi + 2]) else pattern[pi + 2];
            const test_ch = if (case_insensitive) std.ascii.toLower(ch) else ch;
            if (test_ch >= lo and test_ch <= hi) {
                matched = true;
            }
            pi += 3;
        } else {
            if (charEq(pattern[pi], ch, case_insensitive)) {
                matched = true;
            }
            pi += 1;
        }
    }

    if (pi < pattern.len and pattern[pi] == ']') {
        pi += 1; // skip ']'
        if (negate) matched = !matched;
        if (matched) return pi;
    }

    return null;
}

// ============================================================================
// Size parsing
// ============================================================================

fn parseSize(str: []const u8) !SizeExpr {
    if (str.len == 0) return error.InvalidSize;

    var s = str;
    var cmp: Comparison = .exactly;

    if (s[0] == '+') {
        cmp = .greater_than;
        s = s[1..];
    } else if (s[0] == '-') {
        cmp = .less_than;
        s = s[1..];
    }

    if (s.len == 0) return error.InvalidSize;

    // Check for suffix
    var unit: SizeUnit = .blocks; // default
    var num_str = s;

    const last = s[s.len - 1];
    if (!std.ascii.isDigit(last)) {
        unit = switch (last) {
            'c' => .bytes,
            'w' => .words,
            'b' => .blocks,
            'k' => .kilobytes,
            'M' => .megabytes,
            'G' => .gigabytes,
            else => return error.InvalidSize,
        };
        num_str = s[0 .. s.len - 1];
    }

    if (num_str.len == 0) return error.InvalidSize;

    const value = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidSize;

    return SizeExpr{
        .cmp = cmp,
        .value = value,
        .unit = unit,
    };
}

// ============================================================================
// Time comparison
// ============================================================================

fn parseMtime(str: []const u8) !TimeExpr {
    if (str.len == 0) return error.InvalidTime;

    var s = str;
    var cmp: Comparison = .exactly;

    if (s[0] == '+') {
        cmp = .greater_than;
        s = s[1..];
    } else if (s[0] == '-') {
        cmp = .less_than;
        s = s[1..];
    }

    if (s.len == 0) return error.InvalidTime;

    const days = std.fmt.parseInt(u64, s, 10) catch return error.InvalidTime;

    return TimeExpr{
        .cmp = cmp,
        .days = days,
    };
}

// ============================================================================
// Permission parsing
// ============================================================================

fn parsePerm(str: []const u8) !u32 {
    if (str.len == 0) return error.InvalidPerm;

    // Parse octal mode
    var mode: u32 = 0;
    for (str) |ch| {
        if (ch < '0' or ch > '7') return error.InvalidPerm;
        mode = mode * 8 + @as(u32, ch - '0');
    }
    return mode;
}

// ============================================================================
// File type parsing
// ============================================================================

fn parseFileType(str: []const u8) !FileType {
    if (str.len != 1) return error.InvalidType;
    return switch (str[0]) {
        'f' => .regular,
        'd' => .directory,
        'l' => .symlink,
        'b' => .block_device,
        'c' => .char_device,
        'p' => .pipe,
        's' => .socket,
        else => error.InvalidType,
    };
}

// ============================================================================
// Stat helper
// ============================================================================

fn doStat(path: []const u8, follow_symlinks: bool) !c.Stat {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];

    var stat_buf: c.Stat = undefined;
    const flags: u32 = if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW;
    const result = c.fstatat(std.fs.cwd().fd, c_path, &stat_buf, flags);
    if (result != 0) {
        const errno = std.posix.errno(result);
        return switch (errno) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .NAMETOOLONG => error.NameTooLong,
            .LOOP => error.SymLinkLoop,
            else => error.SystemResources,
        };
    }
    return stat_buf;
}

fn getFileKind(mode: c.mode_t) FileType {
    const fmt = mode & c.S.IFMT;
    if (fmt == c.S.IFREG) return .regular;
    if (fmt == c.S.IFDIR) return .directory;
    if (fmt == c.S.IFLNK) return .symlink;
    if (fmt == c.S.IFBLK) return .block_device;
    if (fmt == c.S.IFCHR) return .char_device;
    if (fmt == c.S.IFIFO) return .pipe;
    if (fmt == c.S.IFSOCK) return .socket;
    return .regular;
}

fn getMtime(stat_buf: c.Stat) i64 {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return stat_buf.mtimespec.sec;
    } else {
        return stat_buf.mtim.sec;
    }
}

// ============================================================================
// Expression parsing
// ============================================================================

const ParseError = error{
    InvalidExpression,
    MissingArgument,
    UnmatchedParen,
    InvalidSize,
    InvalidTime,
    InvalidPerm,
    InvalidType,
    OutOfMemory,
    StatError,
};

const ParseContext = struct {
    allocator: Allocator,
    error_msg: ?[]const u8 = null,

    fn setError(self: *ParseContext, comptime fmt: []const u8, fmt_args: anytype) void {
        self.error_msg = std.fmt.allocPrint(self.allocator, fmt, fmt_args) catch null;
    }
};

fn allocExpr(allocator: Allocator, tag: ExprTag, data: ExprData) !*Expression {
    const expr = try allocator.create(Expression);
    expr.* = .{ .tag = tag, .data = data };
    return expr;
}

fn parseArgs(allocator: Allocator, args: []const []const u8, stderr: anytype) !FindConfig {
    var start_paths = std.ArrayListUnmanaged([]const u8){};
    defer start_paths.deinit(allocator);

    var maxdepth: ?u32 = null;
    var mindepth: u32 = 0;
    var depth_first = false;
    var follow_symlinks = false;
    var follow_cmdline_symlinks = false;

    // Collect starting paths and global options before expressions
    var expr_start: usize = 0;
    while (expr_start < args.len) {
        const arg = args[expr_start];
        if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "-follow")) {
            follow_symlinks = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-H")) {
            follow_cmdline_symlinks = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-depth")) {
            depth_first = true;
            expr_start += 1;
        } else if (arg.len > 0 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            break;
        } else if (std.mem.eql(u8, arg, "(") or std.mem.eql(u8, arg, "!")) {
            break;
        } else {
            try start_paths.append(allocator, arg);
            expr_start += 1;
        }
    }

    if (start_paths.items.len == 0) {
        try start_paths.append(allocator, ".");
    }

    // Pre-scan for global options within expression args
    var i: usize = expr_start;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-maxdepth")) {
            if (i + 1 >= args.len) {
                common.printErrorWithProgram(allocator, stderr, prog_name, "missing argument to '-maxdepth'", .{});
                return error.MissingArgument;
            }
            maxdepth = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid argument '{s}' to '-maxdepth'", .{args[i + 1]});
                return error.InvalidExpression;
            };
            i += 2;
        } else if (std.mem.eql(u8, args[i], "-mindepth")) {
            if (i + 1 >= args.len) {
                common.printErrorWithProgram(allocator, stderr, prog_name, "missing argument to '-mindepth'", .{});
                return error.MissingArgument;
            }
            mindepth = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid argument '{s}' to '-mindepth'", .{args[i + 1]});
                return error.InvalidExpression;
            };
            i += 2;
        } else if (std.mem.eql(u8, args[i], "-depth")) {
            depth_first = true;
            i += 1;
        } else {
            i += 1;
        }
    }

    // Parse expression tree
    var pos: usize = expr_start;
    var has_action = false;
    var pctx = ParseContext{ .allocator = allocator };
    const expr = parseOr(allocator, args, &pos, &has_action, &pctx) catch |err| {
        if (pctx.error_msg) |msg| {
            common.printErrorWithProgram(allocator, stderr, prog_name, "{s}", .{msg});
        }
        return err;
    };

    const final_expr = if (pos == expr_start)
        try allocExpr(allocator, .true_expr, .{ .none = {} })
    else
        expr;

    // If -delete is used, enable depth-first
    if (exprContainsDelete(final_expr)) {
        depth_first = true;
    }

    // If no action, wrap with implicit -print
    const result_expr = if (!has_action) blk: {
        const print_expr = try allocExpr(allocator, .print, .{ .none = {} });
        break :blk try allocExpr(allocator, .and_expr, .{ .binary = .{ .left = final_expr, .right = print_expr } });
    } else final_expr;

    const paths_slice = try allocator.dupe([]const u8, start_paths.items);

    return FindConfig{
        .start_paths = paths_slice,
        .expr = result_expr,
        .maxdepth = maxdepth,
        .mindepth = mindepth,
        .depth_first = depth_first,
        .follow_symlinks = follow_symlinks,
        .follow_cmdline_symlinks = follow_cmdline_symlinks,
        .has_action = has_action,
    };
}

fn exprContainsDelete(expr: *const Expression) bool {
    switch (expr.tag) {
        .delete => return true,
        .and_expr, .or_expr => {
            return exprContainsDelete(expr.data.binary.left) or exprContainsDelete(expr.data.binary.right);
        },
        .not_expr => return exprContainsDelete(expr.data.unary),
        else => return false,
    }
}

const ExprParseError = error{
    InvalidExpression,
    MissingArgument,
    UnmatchedParen,
    StatError,
    OutOfMemory,
};

fn parseOr(allocator: Allocator, args: []const []const u8, pos: *usize, has_action: *bool, pctx: *ParseContext) ExprParseError!*Expression {
    var left = try parseAnd(allocator, args, pos, has_action, pctx);

    while (pos.* < args.len) {
        const arg = args[pos.*];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-or")) {
            pos.* += 1;
            const right = try parseAnd(allocator, args, pos, has_action, pctx);
            left = try allocExpr(allocator, .or_expr, .{ .binary = .{ .left = left, .right = right } });
        } else {
            break;
        }
    }

    return left;
}

fn parseAnd(allocator: Allocator, args: []const []const u8, pos: *usize, has_action: *bool, pctx: *ParseContext) ExprParseError!*Expression {
    var left = try parseUnary(allocator, args, pos, has_action, pctx);

    while (pos.* < args.len) {
        const arg = args[pos.*];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-or") or std.mem.eql(u8, arg, ")")) {
            break;
        }

        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-and")) {
            pos.* += 1;
        }

        if (pos.* >= args.len) break;
        const next_arg = args[pos.*];
        if (std.mem.eql(u8, next_arg, "-o") or std.mem.eql(u8, next_arg, "-or") or std.mem.eql(u8, next_arg, ")")) {
            break;
        }

        const right = try parseUnary(allocator, args, pos, has_action, pctx);
        left = try allocExpr(allocator, .and_expr, .{ .binary = .{ .left = left, .right = right } });
    }

    return left;
}

fn parseUnary(allocator: Allocator, args: []const []const u8, pos: *usize, has_action: *bool, pctx: *ParseContext) ExprParseError!*Expression {
    if (pos.* >= args.len) {
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }

    const arg = args[pos.*];

    if (std.mem.eql(u8, arg, "!") or std.mem.eql(u8, arg, "-not")) {
        pos.* += 1;
        const operand = try parseUnary(allocator, args, pos, has_action, pctx);
        return allocExpr(allocator, .not_expr, .{ .unary = operand });
    }

    if (std.mem.eql(u8, arg, "(")) {
        pos.* += 1;
        const expr = try parseOr(allocator, args, pos, has_action, pctx);
        if (pos.* >= args.len or !std.mem.eql(u8, args[pos.*], ")")) {
            pctx.setError("missing closing ')'", .{});
            return error.UnmatchedParen;
        }
        pos.* += 1;
        return expr;
    }

    return parsePrimary(allocator, args, pos, has_action, pctx);
}

fn parsePrimary(allocator: Allocator, args: []const []const u8, pos: *usize, has_action: *bool, pctx: *ParseContext) ExprParseError!*Expression {
    if (pos.* >= args.len) {
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }

    const arg = args[pos.*];

    // Skip global options already handled
    if (std.mem.eql(u8, arg, "-maxdepth") or std.mem.eql(u8, arg, "-mindepth")) {
        pos.* += 2;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-depth")) {
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-name")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-name'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .name, .{ .pattern = pattern });
    }

    if (std.mem.eql(u8, arg, "-iname")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-iname'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .iname, .{ .pattern = pattern });
    }

    if (std.mem.eql(u8, arg, "-path") or std.mem.eql(u8, arg, "-wholename")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-path'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .path_match, .{ .pattern = pattern });
    }

    if (std.mem.eql(u8, arg, "-type")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-type'", .{});
            return error.MissingArgument;
        }
        const ft = parseFileType(args[pos.*]) catch {
            pctx.setError("unknown argument to -type: '{s}'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .file_type, .{ .file_type = ft });
    }

    if (std.mem.eql(u8, arg, "-size")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-size'", .{});
            return error.MissingArgument;
        }
        const sz = parseSize(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-size'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .size, .{ .size = sz });
    }

    if (std.mem.eql(u8, arg, "-empty")) {
        pos.* += 1;
        return allocExpr(allocator, .empty, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-newer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-newer'", .{});
            return error.MissingArgument;
        }
        const ref_path = args[pos.*];
        pos.* += 1;
        const ref_stat = doStat(ref_path, true) catch {
            pctx.setError("cannot stat '{s}'", .{ref_path});
            return error.StatError;
        };
        const ref_mtime = getMtime(ref_stat);
        return allocExpr(allocator, .newer, .{ .newer_mtime = ref_mtime });
    }

    if (std.mem.eql(u8, arg, "-mtime")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-mtime'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-mtime'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .mtime, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-perm")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-perm'", .{});
            return error.MissingArgument;
        }
        const perm_val = parsePerm(args[pos.*]) catch {
            pctx.setError("invalid mode '{s}'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .perm, .{ .perm_val = perm_val });
    }

    if (std.mem.eql(u8, arg, "-user")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-user'", .{});
            return error.MissingArgument;
        }
        const name_str = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .user, .{ .name_str = name_str });
    }

    if (std.mem.eql(u8, arg, "-group")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-group'", .{});
            return error.MissingArgument;
        }
        const name_str = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .group, .{ .name_str = name_str });
    }

    if (std.mem.eql(u8, arg, "-print")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .print, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-print0")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .print0, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-delete")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .delete, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-exec")) {
        pos.* += 1;
        var exec_args = std.ArrayListUnmanaged([]const u8){};
        defer exec_args.deinit(allocator);

        while (pos.* < args.len) {
            if (std.mem.eql(u8, args[pos.*], ";")) {
                pos.* += 1;
                break;
            }
            try exec_args.append(allocator, args[pos.*]);
            pos.* += 1;
        } else {
            pctx.setError("missing argument to '-exec'", .{});
            return error.MissingArgument;
        }

        if (exec_args.items.len == 0) {
            pctx.setError("missing argument to '-exec'", .{});
            return error.MissingArgument;
        }

        has_action.* = true;
        const argv = try allocator.dupe([]const u8, exec_args.items);
        return allocExpr(allocator, .exec_cmd, .{ .exec_data = .{ .argv = argv } });
    }

    pctx.setError("unknown predicate '{s}'", .{arg});
    return error.InvalidExpression;
}

// ============================================================================
// Expression evaluation
// ============================================================================

fn evaluate(
    expr: *const Expression,
    path: []const u8,
    basename: []const u8,
    stat_buf: c.Stat,
    kind: FileType,
    now: i64,
    allocator: Allocator,
    stdout: anytype,
    stderr: anytype,
    had_error: *bool,
) bool {
    switch (expr.tag) {
        .true_expr => return true,
        .name => return globMatch(expr.data.pattern, basename),
        .iname => return globMatchInsensitive(expr.data.pattern, basename),
        .path_match => return globMatch(expr.data.pattern, path),
        .file_type => return kind == expr.data.file_type,
        .size => {
            const sz = expr.data.size;
            const file_size: u64 = @intCast(@max(0, stat_buf.size));
            const target_bytes = sz.toBytes();
            return switch (sz.cmp) {
                .exactly => file_size == target_bytes,
                .greater_than => file_size > target_bytes,
                .less_than => file_size < target_bytes,
            };
        },
        .empty => {
            if (kind == .regular) return stat_buf.size == 0;
            if (kind == .directory) return isDirEmpty(path) catch false;
            return false;
        },
        .newer => {
            const file_mtime = getMtime(stat_buf);
            return file_mtime > expr.data.newer_mtime;
        },
        .mtime => {
            const te = expr.data.time;
            const file_mtime = getMtime(stat_buf);
            const age_secs = now - file_mtime;
            const age_days: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 86400) else 0;
            return switch (te.cmp) {
                .exactly => age_days == te.days,
                .greater_than => age_days > te.days,
                .less_than => age_days < te.days,
            };
        },
        .perm => {
            const file_mode = @as(u32, @intCast(stat_buf.mode)) & 0o7777;
            return file_mode == expr.data.perm_val;
        },
        .user => return matchUser(expr.data.name_str, stat_buf.uid),
        .group => return matchGroup(expr.data.name_str, stat_buf.gid),
        .print => {
            stdout.print("{s}\n", .{path}) catch {
                had_error.* = true;
            };
            return true;
        },
        .print0 => {
            stdout.print("{s}", .{path}) catch {
                had_error.* = true;
            };
            stdout.writeByte(0) catch {
                had_error.* = true;
            };
            return true;
        },
        .delete => return doDelete(allocator, path, kind, stderr, had_error),
        .exec_cmd => return doExec(allocator, path, expr.data.exec_data),
        .and_expr => {
            const left_result = evaluate(expr.data.binary.left, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
            if (!left_result) return false;
            return evaluate(expr.data.binary.right, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
        },
        .or_expr => {
            const left_result = evaluate(expr.data.binary.left, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
            if (left_result) return true;
            return evaluate(expr.data.binary.right, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
        },
        .not_expr => {
            return !evaluate(expr.data.unary, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
        },
    }
}

fn isDirEmpty(path: []const u8) !bool {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    const entry = try iter.next();
    return entry == null;
}

fn matchUser(name_str: []const u8, uid: c.uid_t) bool {
    if (std.fmt.parseInt(c.uid_t, name_str, 10)) |numeric_uid| {
        return uid == numeric_uid;
    } else |_| {}

    var buf: [256]u8 = undefined;
    if (name_str.len >= buf.len) return false;
    @memcpy(buf[0..name_str.len], name_str);
    buf[name_str.len] = 0;
    const c_name = buf[0..name_str.len :0];

    const pw = getpwnam(c_name);
    if (pw) |p| {
        return uid == p.pw_uid;
    }
    return false;
}

fn matchGroup(name_str: []const u8, gid: c.gid_t) bool {
    if (std.fmt.parseInt(c.gid_t, name_str, 10)) |numeric_gid| {
        return gid == numeric_gid;
    } else |_| {}

    var buf: [256]u8 = undefined;
    if (name_str.len >= buf.len) return false;
    @memcpy(buf[0..name_str.len], name_str);
    buf[name_str.len] = 0;
    const c_name = buf[0..name_str.len :0];

    const gr = getgrnam(c_name);
    if (gr) |g| {
        return gid == g.gr_gid;
    }
    return false;
}

fn doDelete(allocator: Allocator, path: []const u8, kind: FileType, stderr: anytype, had_error: *bool) bool {
    if (kind == .directory) {
        std.fs.cwd().deleteDir(path) catch |err| {
            common.printErrorWithProgram(allocator, stderr, prog_name, "cannot delete '{s}': {s}", .{ path, @errorName(err) });
            had_error.* = true;
            return false;
        };
    } else {
        std.fs.cwd().deleteFile(path) catch |err| {
            common.printErrorWithProgram(allocator, stderr, prog_name, "cannot delete '{s}': {s}", .{ path, @errorName(err) });
            had_error.* = true;
            return false;
        };
    }
    return true;
}

fn doExec(allocator: Allocator, path: []const u8, exec_data: ExecExpr) bool {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    for (exec_data.argv) |arg| {
        if (std.mem.eql(u8, arg, "{}")) {
            argv.append(allocator, path) catch return false;
        } else {
            argv.append(allocator, arg) catch return false;
        }
    }

    if (argv.items.len == 0) return false;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch {
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.Exited == 0;
}

// ============================================================================
// Directory walking
// ============================================================================

fn walkPath(
    allocator: Allocator,
    path: []const u8,
    depth: u32,
    config: *const FindConfig,
    stdout: anytype,
    stderr: anytype,
    had_error: *bool,
    now: i64,
) void {
    // Check maxdepth
    if (config.maxdepth) |max| {
        if (depth > max) return;
    }

    // Determine whether to follow symlinks
    const follow = config.follow_symlinks or (depth == 0 and config.follow_cmdline_symlinks);

    // Stat the entry
    const stat_buf = doStat(path, follow) catch |err| {
        switch (err) {
            error.AccessDenied => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': Permission denied", .{path});
            },
            error.FileNotFound => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': No such file or directory", .{path});
            },
            error.SymLinkLoop => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': Too many levels of symbolic links", .{path});
            },
            else => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': {s}", .{ path, @errorName(err) });
            },
        }
        had_error.* = true;
        return;
    };

    const kind = getFileKind(stat_buf.mode);
    const basename = std.fs.path.basename(path);
    const is_depth_first = config.depth_first;

    // Non-directory: evaluate and return
    if (kind != .directory) {
        if (depth >= config.mindepth) {
            _ = evaluate(config.expr, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
        }
        return;
    }

    // Directory: evaluate before traversal (breadth-first)
    if (!is_depth_first and depth >= config.mindepth) {
        _ = evaluate(config.expr, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
    }

    // Check maxdepth before descending
    if (config.maxdepth) |max| {
        if (depth >= max) {
            if (is_depth_first and depth >= config.mindepth) {
                _ = evaluate(config.expr, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
            }
            return;
        }
    }

    // Descend into directory
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.AccessDenied => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': Permission denied", .{path});
            },
            else => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': {s}", .{ path, @errorName(err) });
            },
        }
        had_error.* = true;
        if (is_depth_first and depth >= config.mindepth) {
            _ = evaluate(config.expr, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
        }
        return;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next() catch |err| {
            common.printErrorWithProgram(allocator, stderr, prog_name, "'{s}': {s}", .{ path, @errorName(err) });
            had_error.* = true;
            break;
        };
        const entry = maybe_entry orelse break;

        const child_path = std.fs.path.join(allocator, &.{ path, entry.name }) catch {
            had_error.* = true;
            continue;
        };
        defer allocator.free(child_path);

        walkPath(allocator, child_path, depth + 1, config, stdout, stderr, had_error, now);
    }

    // Depth-first: evaluate directory after children
    if (is_depth_first and depth >= config.mindepth) {
        _ = evaluate(config.expr, path, basename, stat_buf, kind, now, allocator, stdout, stderr, had_error);
    }
}

// ============================================================================
// Entry points
// ============================================================================

pub fn runFind(allocator: Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) u8 {
    // Handle --help and --version before expression parsing
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(stdout);
            return @intFromEnum(common.ExitCode.success);
        }
        if (std.mem.eql(u8, arg, "--version")) {
            printVersion(stdout);
            return @intFromEnum(common.ExitCode.success);
        }
    }

    const config = parseArgs(allocator, args, stderr) catch {
        return @intFromEnum(common.ExitCode.general_error);
    };

    const now = std.time.timestamp();
    var had_error = false;

    for (config.start_paths) |path| {
        walkPath(allocator, path, 0, &config, stdout, stderr, &had_error, now);
    }

    return if (had_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

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

    const exit_code = runFind(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) std.process.exit(exit_code);
}

fn printHelp(writer: anytype) void {
    const help_text =
        \\Usage: find [-H] [-L] [path...] [expression]
        \\
        \\Search for files in a directory hierarchy.
        \\
        \\Global options:
        \\  -H                 Follow symbolic links on the command line only
        \\  -L, -follow        Follow all symbolic links
        \\  -depth             Process directory contents before directory itself
        \\  -maxdepth N        Descend at most N levels below starting points
        \\  -mindepth N        Do not apply tests at levels less than N
        \\
        \\Tests (predicates):
        \\  -name PATTERN      Base name matches shell glob pattern
        \\  -iname PATTERN     Like -name but case insensitive
        \\  -path PATTERN      Full path matches shell glob pattern
        \\  -type TYPE         File type: f d l b c p s
        \\  -size N[cwbkMG]    File uses N units of space
        \\  -empty             File is empty (regular file or directory)
        \\  -newer FILE        Modified more recently than FILE
        \\  -mtime N           Modified N*24 hours ago (+N/-N/N)
        \\  -perm MODE         Permission bits match MODE (octal)
        \\  -user NAME         File belongs to user NAME
        \\  -group NAME        File belongs to group NAME
        \\
        \\Actions:
        \\  -print             Print full path (default action)
        \\  -print0            Print full path followed by NUL
        \\  -delete            Delete file (implies -depth)
        \\  -exec CMD {} ;     Execute command for each file
        \\
        \\Operators:
        \\  -and, -a           Logical AND (default between tests)
        \\  -or, -o            Logical OR
        \\  -not, !            Logical NOT
        \\  ( expr )           Grouping
        \\
        \\      --help         Display this help and exit
        \\      --version      Output version information and exit
        \\
    ;
    writer.print("{s}", .{help_text}) catch {};
}

fn printVersion(writer: anytype) void {
    const build_options = @import("build_options");
    writer.print("find (vibeutils) {s}\n", .{build_options.version}) catch {};
}

// ============================================================================
// TESTS
// ============================================================================

test "glob: basic star" {
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("*.txt", "hello.txt"));
    try testing.expect(!globMatch("*.txt", "hello.md"));
    try testing.expect(globMatch("hello*", "helloworld"));
    try testing.expect(globMatch("he*ld", "helloworld"));
    try testing.expect(!globMatch("he*ld", "helloworlds"));
}

test "glob: question mark" {
    try testing.expect(globMatch("?.txt", "a.txt"));
    try testing.expect(!globMatch("?.txt", "ab.txt"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "ac"));
}

test "glob: bracket expression" {
    try testing.expect(globMatch("[abc].txt", "a.txt"));
    try testing.expect(globMatch("[abc].txt", "b.txt"));
    try testing.expect(!globMatch("[abc].txt", "d.txt"));
    try testing.expect(globMatch("[a-z].txt", "m.txt"));
    try testing.expect(!globMatch("[a-z].txt", "M.txt"));
    try testing.expect(globMatch("[!abc].txt", "d.txt"));
    try testing.expect(!globMatch("[!abc].txt", "a.txt"));
}

test "glob: escape" {
    try testing.expect(globMatch("\\*.txt", "*.txt"));
    try testing.expect(!globMatch("\\*.txt", "a.txt"));
}

test "glob: empty pattern and string" {
    try testing.expect(globMatch("", ""));
    try testing.expect(!globMatch("", "a"));
    try testing.expect(!globMatch("a", ""));
    try testing.expect(globMatch("*", ""));
}

test "glob: case insensitive" {
    try testing.expect(globMatchInsensitive("*.TXT", "hello.txt"));
    try testing.expect(globMatchInsensitive("*.txt", "hello.TXT"));
    try testing.expect(globMatchInsensitive("Hello*", "helloworld"));
    try testing.expect(globMatchInsensitive("[A-Z]", "a"));
}

test "glob: complex patterns" {
    try testing.expect(globMatch("*.[ch]", "main.c"));
    try testing.expect(globMatch("*.[ch]", "main.h"));
    try testing.expect(!globMatch("*.[ch]", "main.o"));
    try testing.expect(globMatch("*.tar.gz", "archive.tar.gz"));
}

test "parseSize: basic sizes" {
    const s1 = try parseSize("100c");
    try testing.expectEqual(Comparison.exactly, s1.cmp);
    try testing.expectEqual(@as(u64, 100), s1.value);
    try testing.expectEqual(SizeUnit.bytes, s1.unit);

    const s2 = try parseSize("+10k");
    try testing.expectEqual(Comparison.greater_than, s2.cmp);
    try testing.expectEqual(@as(u64, 10), s2.value);
    try testing.expectEqual(SizeUnit.kilobytes, s2.unit);

    const s3 = try parseSize("-5M");
    try testing.expectEqual(Comparison.less_than, s3.cmp);
    try testing.expectEqual(@as(u64, 5), s3.value);
    try testing.expectEqual(SizeUnit.megabytes, s3.unit);

    // Default unit is blocks (512 bytes)
    const s4 = try parseSize("10");
    try testing.expectEqual(SizeUnit.blocks, s4.unit);
}

test "parseSize: toBytes" {
    const s = SizeExpr{ .cmp = .exactly, .value = 2, .unit = .kilobytes };
    try testing.expectEqual(@as(u64, 2048), s.toBytes());

    const s2 = SizeExpr{ .cmp = .exactly, .value = 1, .unit = .megabytes };
    try testing.expectEqual(@as(u64, 1048576), s2.toBytes());
}

test "parseSize: errors" {
    try testing.expectError(error.InvalidSize, parseSize(""));
    try testing.expectError(error.InvalidSize, parseSize("+"));
    try testing.expectError(error.InvalidSize, parseSize("abc"));
    try testing.expectError(error.InvalidSize, parseSize("10x"));
}

test "parseMtime: basic" {
    const t1 = try parseMtime("7");
    try testing.expectEqual(Comparison.exactly, t1.cmp);
    try testing.expectEqual(@as(u64, 7), t1.days);

    const t2 = try parseMtime("+30");
    try testing.expectEqual(Comparison.greater_than, t2.cmp);
    try testing.expectEqual(@as(u64, 30), t2.days);

    const t3 = try parseMtime("-1");
    try testing.expectEqual(Comparison.less_than, t3.cmp);
    try testing.expectEqual(@as(u64, 1), t3.days);
}

test "parseMtime: errors" {
    try testing.expectError(error.InvalidTime, parseMtime(""));
    try testing.expectError(error.InvalidTime, parseMtime("+"));
    try testing.expectError(error.InvalidTime, parseMtime("abc"));
}

test "parsePerm: basic" {
    try testing.expectEqual(@as(u32, 0o755), try parsePerm("755"));
    try testing.expectEqual(@as(u32, 0o644), try parsePerm("644"));
    try testing.expectEqual(@as(u32, 0o0), try parsePerm("0"));
    try testing.expectEqual(@as(u32, 0o777), try parsePerm("777"));
}

test "parsePerm: errors" {
    try testing.expectError(error.InvalidPerm, parsePerm(""));
    try testing.expectError(error.InvalidPerm, parsePerm("899"));
    try testing.expectError(error.InvalidPerm, parsePerm("abc"));
}

test "parseFileType: basic" {
    try testing.expectEqual(FileType.regular, try parseFileType("f"));
    try testing.expectEqual(FileType.directory, try parseFileType("d"));
    try testing.expectEqual(FileType.symlink, try parseFileType("l"));
    try testing.expectEqual(FileType.block_device, try parseFileType("b"));
    try testing.expectEqual(FileType.char_device, try parseFileType("c"));
    try testing.expectEqual(FileType.pipe, try parseFileType("p"));
    try testing.expectEqual(FileType.socket, try parseFileType("s"));
}

test "parseFileType: errors" {
    try testing.expectError(error.InvalidType, parseFileType(""));
    try testing.expectError(error.InvalidType, parseFileType("x"));
    try testing.expectError(error.InvalidType, parseFileType("ff"));
}

test "find: help flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{"--help"}, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage:") != null);
}

test "find: version flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{"--version"}, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "vibeutils") != null);
}

test "find: basic directory search" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("hello.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("world.md", .{});
    f2.close();
    try tmp.dir.makeDir("subdir");

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{dir_path}, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "hello.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "world.md") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "subdir") != null);
}

test "find: -name filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("hello.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("world.md", .{});
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "hello.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "world.md") == null);
}

test "find: -type filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("file.txt", .{});
    f1.close();
    try tmp.dir.makeDir("mydir");

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Find only files
    {
        var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

        const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
    }

    // Find only directories
    {
        var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

        const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "d" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "mydir") != null);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") == null);
    }
}

test "find: -empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("empty.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("notempty.txt", .{});
    try f2.writeAll("content");
    f2.close();
    try tmp.dir.makeDir("emptydir");

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-empty" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "empty.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "emptydir") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "notempty.txt") == null);
}

test "find: -maxdepth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("top.txt", .{});
    f1.close();
    try tmp.dir.makeDir("sub");
    var sub = try tmp.dir.openDir("sub", .{});
    const f2 = try sub.createFile("deep.txt", .{});
    f2.close();
    sub.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-maxdepth", "1" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "top.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "sub") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "deep.txt") == null);
}

test "find: -not / !" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("keep.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("skip.log", .{});
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-not", "-name", "*.log", "-type", "f" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "keep.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "skip.log") == null);
}

test "find: -or operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("a.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("b.md", .{});
    f2.close();
    const f3 = try tmp.dir.createFile("c.log", .{});
    f3.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-name", "*.txt", "-o", "-name", "*.md" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "b.md") != null);
}

test "find: parentheses grouping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("a.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("b.md", .{});
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "(", "-name", "*.txt", "-o", "-name", "*.md", ")" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "b.md") != null);
}

test "find: -print0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("file.txt", .{});
    f1.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-name", "file.txt", "-print0" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should contain NUL byte
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, &[_]u8{0}) != null);
    // Should not contain newline after filename
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt\n") == null);
}

test "find: nonexistent path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{"/tmp/nonexistent_vibeutils_test_path_99999"}, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(stderr_buf.items.len > 0);
}

test "find: unknown predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ ".", "-bogus" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "unknown predicate") != null);
}

test "find: -mindepth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("top.txt", .{});
    f1.close();
    try tmp.dir.makeDir("sub");
    var sub = try tmp.dir.openDir("sub", .{});
    const f2 = try sub.createFile("deep.txt", .{});
    f2.close();
    sub.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-mindepth", "2" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "deep.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "top.txt") == null);
}

test "find: -delete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("deleteme.txt", .{});
    f1.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-name", "deleteme.txt", "-delete" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    const stat = tmp.dir.statFile("deleteme.txt");
    try testing.expect(stat == error.FileNotFound);
}

test "find: -iname" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("Hello.TXT", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("world.txt", .{});
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-iname", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Hello.TXT") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "world.txt") != null);
}

test "find: -size filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("small.txt", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("medium.txt", .{});
    try f2.writeAll("a" ** 2048);
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-size", "+1000c" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "medium.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "small.txt") == null);
}

test "find: -perm filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile("rw.txt", .{ .mode = 0o644 });
    f1.close();
    const f2 = try tmp.dir.createFile("rwx.txt", .{ .mode = 0o755 });
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-perm", "755" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "rwx.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "rw.txt") == null);
}
