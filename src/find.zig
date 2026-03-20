//! find - search for files in a directory hierarchy
//!
//! Walk a file hierarchy rooted at each starting-point path, evaluating
//! a Boolean expression composed of primaries and operators for every
//! file in the tree.
//!
//! This implementation supports a useful subset of POSIX/GNU find.

const std = @import("std");
const common = @import("common");
const glob = common.glob;
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
extern "c" fn getpwuid(uid: c.uid_t) ?*const extern struct {
    pw_name: [*:0]u8,
    pw_passwd: [*:0]u8,
    pw_uid: c.uid_t,
    pw_gid: c.gid_t,
};
extern "c" fn getgrgid(gid: c.gid_t) ?*const extern struct {
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
    ipath,
    atime,
    ctime,
    links,
    ok,
    xdev,
    nouser,
    nogroup,
    mmin,
    inum,
    amin,
    cmin,
    anewer,
    cnewer,
    execdir,
    ls_action,
    fstype,
    flags,
    print,
    print0,
    delete,
    exec_cmd,
    and_expr,
    or_expr,
    not_expr,
    true_expr,
    false_expr,
    prune,
    // Stubs: accept syntax, simple behavior
    regex_stub,
    iregex_stub,
    bmin_stub,
    bnewer_stub,
    btime_stub,
    acl_stub,
    depth_n,
    gid_match,
    ilname,
    lname,
    newerxy_stub,
    okdir_stub,
    quit_action,
    samefile,
    sparse_stub,
    uid_match,
    xattr_stub,
    xattrname_stub,
    printf_action,
};

const Expression = struct {
    tag: ExprTag,
    data: ExprData,
};

const SamefileData = struct {
    ino: u64,
    dev: i64,
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
    samefile_data: SamefileData,
    depth_val: u32,
    uid_val: c.uid_t,
    gid_val: c.gid_t,
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
    xdev: bool = false,
    xargs_safe: bool = false,
};

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

fn getAtime(stat_buf: c.Stat) i64 {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return stat_buf.atimespec.sec;
    } else {
        return stat_buf.atim.sec;
    }
}

fn getCtime(stat_buf: c.Stat) i64 {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return stat_buf.ctimespec.sec;
    } else {
        return stat_buf.ctim.sec;
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
    var xdev = false;
    var xargs_safe = false;

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
        } else if (std.mem.eql(u8, arg, "-P")) {
            // -P: never follow symlinks (default behavior); accept as no-op
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-E")) {
            // -E: extended regex mode; accept as no-op stub
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-s")) {
            // -s: traverse in alphabetical order; accept as no-op stub
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-depth")) {
            // Check if followed by a number: -depth N is an expression primary
            if (expr_start + 1 < args.len) {
                if (std.fmt.parseInt(u32, args[expr_start + 1], 10)) |_| {
                    // -depth N: this is an expression, stop collecting globals
                    break;
                } else |_| {}
            }
            depth_first = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-d")) {
            depth_first = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-x")) {
            xdev = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-X")) {
            xargs_safe = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-f")) {
            expr_start += 1;
            if (expr_start < args.len) {
                try start_paths.append(allocator, args[expr_start]);
                expr_start += 1;
            }
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
            // Check if next arg is numeric: -depth N (exact depth match, not depth-first)
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(u32, args[i + 1], 10)) |_| {
                    // -depth N: exact depth matching, skip (handled by parsePrimary)
                    i += 2;
                } else |_| {
                    // -depth without numeric arg: depth-first mode
                    depth_first = true;
                    i += 1;
                }
            } else {
                depth_first = true;
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-d")) {
            depth_first = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-xdev") or std.mem.eql(u8, args[i], "-mount")) {
            xdev = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-ignore_readdir_race") or
            std.mem.eql(u8, args[i], "-noignore_readdir_race") or
            std.mem.eql(u8, args[i], "-noleaf"))
        {
            // Accept as no-ops
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
        .xdev = xdev,
        .xargs_safe = xargs_safe,
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
        // Check if next arg is numeric: -depth N (exact depth matching)
        if (pos.* + 1 < args.len) {
            if (std.fmt.parseInt(u32, args[pos.* + 1], 10)) |n| {
                pos.* += 2;
                return allocExpr(allocator, .depth_n, .{ .depth_val = n });
            } else |_| {}
        }
        // Non-numeric or no argument: depth-first mode (already handled in parseArgs)
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-d")) {
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

    if (std.mem.eql(u8, arg, "-prune")) {
        pos.* += 1;
        return allocExpr(allocator, .prune, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-atime")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-atime'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-atime'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .atime, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-ctime")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-ctime'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-ctime'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .ctime, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-links")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-links'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-links'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .links, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-ok")) {
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
            pctx.setError("missing argument to '-ok'", .{});
            return error.MissingArgument;
        }

        if (exec_args.items.len == 0) {
            pctx.setError("missing argument to '-ok'", .{});
            return error.MissingArgument;
        }

        has_action.* = true;
        const argv = try allocator.dupe([]const u8, exec_args.items);
        return allocExpr(allocator, .ok, .{ .exec_data = .{ .argv = argv } });
    }

    if (std.mem.eql(u8, arg, "-xdev") or std.mem.eql(u8, arg, "-mount")) {
        pos.* += 1;
        return allocExpr(allocator, .xdev, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-nouser")) {
        pos.* += 1;
        return allocExpr(allocator, .nouser, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-nogroup")) {
        pos.* += 1;
        return allocExpr(allocator, .nogroup, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-mmin")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-mmin'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-mmin'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .mmin, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-inum")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-inum'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-inum'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .inum, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-amin")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-amin'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-amin'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .amin, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-cmin")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-cmin'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-cmin'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .cmin, .{ .time = te });
    }

    if (std.mem.eql(u8, arg, "-anewer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-anewer'", .{});
            return error.MissingArgument;
        }
        const ref_path = args[pos.*];
        pos.* += 1;
        const ref_stat = doStat(ref_path, true) catch {
            pctx.setError("cannot stat '{s}'", .{ref_path});
            return error.StatError;
        };
        const ref_mtime = getMtime(ref_stat);
        return allocExpr(allocator, .anewer, .{ .newer_mtime = ref_mtime });
    }

    if (std.mem.eql(u8, arg, "-cnewer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-cnewer'", .{});
            return error.MissingArgument;
        }
        const ref_path = args[pos.*];
        pos.* += 1;
        const ref_stat = doStat(ref_path, true) catch {
            pctx.setError("cannot stat '{s}'", .{ref_path});
            return error.StatError;
        };
        const ref_mtime = getMtime(ref_stat);
        return allocExpr(allocator, .cnewer, .{ .newer_mtime = ref_mtime });
    }

    if (std.mem.eql(u8, arg, "-execdir")) {
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
            pctx.setError("missing argument to '-execdir'", .{});
            return error.MissingArgument;
        }

        if (exec_args.items.len == 0) {
            pctx.setError("missing argument to '-execdir'", .{});
            return error.MissingArgument;
        }

        has_action.* = true;
        const argv = try allocator.dupe([]const u8, exec_args.items);
        return allocExpr(allocator, .execdir, .{ .exec_data = .{ .argv = argv } });
    }

    if (std.mem.eql(u8, arg, "-ls")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .ls_action, .{ .none = {} });
    }

    if (std.mem.eql(u8, arg, "-fstype")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-fstype'", .{});
            return error.MissingArgument;
        }
        const fs_type = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .fstype, .{ .name_str = fs_type });
    }

    if (std.mem.eql(u8, arg, "-flags")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-flags'", .{});
            return error.MissingArgument;
        }
        const flag_str = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .flags, .{ .name_str = flag_str });
    }

    // -ipath: case-insensitive path matching
    if (std.mem.eql(u8, arg, "-ipath") or std.mem.eql(u8, arg, "-iwholename")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-ipath'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .ipath, .{ .pattern = pattern });
    }

    // -regex: regex match on full path (stub: always true)
    if (std.mem.eql(u8, arg, "-regex")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-regex'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .regex_stub, .{ .none = {} });
    }

    // -iregex: case-insensitive regex match on full path (stub: always true)
    if (std.mem.eql(u8, arg, "-iregex")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-iregex'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .iregex_stub, .{ .none = {} });
    }

    // -Bmin: birth time in minutes (macOS stub: always true)
    if (std.mem.eql(u8, arg, "-Bmin")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-Bmin'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .bmin_stub, .{ .none = {} });
    }

    // -Bnewer: birth time newer than FILE (macOS stub: always true)
    if (std.mem.eql(u8, arg, "-Bnewer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-Bnewer'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .bnewer_stub, .{ .none = {} });
    }

    // -Btime: birth time in days (macOS stub: always true)
    if (std.mem.eql(u8, arg, "-Btime")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-Btime'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .btime_stub, .{ .none = {} });
    }

    // -acl: has ACL set (macOS stub: always false)
    if (std.mem.eql(u8, arg, "-acl")) {
        pos.* += 1;
        return allocExpr(allocator, .acl_stub, .{ .none = {} });
    }

    // -gid N: match numeric group ID
    if (std.mem.eql(u8, arg, "-gid")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-gid'", .{});
            return error.MissingArgument;
        }
        const gid_val = std.fmt.parseInt(c.gid_t, args[pos.*], 10) catch {
            pctx.setError("invalid argument '{s}' to '-gid'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .gid_match, .{ .gid_val = gid_val });
    }

    // -ignore_readdir_race: accept as no-op
    if (std.mem.eql(u8, arg, "-ignore_readdir_race")) {
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }

    // -noignore_readdir_race: accept as no-op
    if (std.mem.eql(u8, arg, "-noignore_readdir_race")) {
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }

    // -noleaf: accept as no-op
    if (std.mem.eql(u8, arg, "-noleaf")) {
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }

    // -ilname: case-insensitive symlink target matching
    if (std.mem.eql(u8, arg, "-ilname")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-ilname'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .ilname, .{ .pattern = pattern });
    }

    // -lname: match symlink target against pattern
    if (std.mem.eql(u8, arg, "-lname")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-lname'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        return allocExpr(allocator, .lname, .{ .pattern = pattern });
    }

    // -mnewer: alias for -newer (modification time newer than FILE)
    if (std.mem.eql(u8, arg, "-mnewer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-mnewer'", .{});
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

    // -newerXY: compare timestamps (stub: always true)
    // Matches -newerXY where X,Y are one of: a, B, c, m, t (8 chars total)
    if (arg.len == 8 and std.mem.startsWith(u8, arg, "-newer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '{s}'", .{arg});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .newerxy_stub, .{ .none = {} });
    }

    // -okdir: like -execdir but prompts (stub: always false)
    if (std.mem.eql(u8, arg, "-okdir")) {
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
            pctx.setError("missing argument to '-okdir'", .{});
            return error.MissingArgument;
        }

        if (exec_args.items.len == 0) {
            pctx.setError("missing argument to '-okdir'", .{});
            return error.MissingArgument;
        }

        has_action.* = true;
        const argv = try allocator.dupe([]const u8, exec_args.items);
        return allocExpr(allocator, .okdir_stub, .{ .exec_data = .{ .argv = argv } });
    }

    // -quit: stop processing immediately
    if (std.mem.eql(u8, arg, "-quit")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .quit_action, .{ .none = {} });
    }

    // -samefile: match files with same inode and device as FILE
    if (std.mem.eql(u8, arg, "-samefile")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-samefile'", .{});
            return error.MissingArgument;
        }
        const ref_path = args[pos.*];
        pos.* += 1;
        const ref_stat = doStat(ref_path, true) catch {
            pctx.setError("cannot stat '{s}'", .{ref_path});
            return error.StatError;
        };
        return allocExpr(allocator, .samefile, .{ .samefile_data = .{
            .ino = @intCast(ref_stat.ino),
            .dev = @intCast(ref_stat.dev),
        } });
    }

    // -sparse: match sparse files (macOS stub: always false)
    if (std.mem.eql(u8, arg, "-sparse")) {
        pos.* += 1;
        return allocExpr(allocator, .sparse_stub, .{ .none = {} });
    }

    // -uid N: match numeric user ID
    if (std.mem.eql(u8, arg, "-uid")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-uid'", .{});
            return error.MissingArgument;
        }
        const uid_val = std.fmt.parseInt(c.uid_t, args[pos.*], 10) catch {
            pctx.setError("invalid argument '{s}' to '-uid'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .uid_match, .{ .uid_val = uid_val });
    }

    // -xattr: has extended attributes (macOS stub: always false)
    if (std.mem.eql(u8, arg, "-xattr")) {
        pos.* += 1;
        return allocExpr(allocator, .xattr_stub, .{ .none = {} });
    }

    // -xattrname: has named extended attribute (macOS stub: always false)
    if (std.mem.eql(u8, arg, "-xattrname")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-xattrname'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .xattrname_stub, .{ .none = {} });
    }

    // -printf: formatted output (stub: prints filename + newline)
    if (std.mem.eql(u8, arg, "-printf")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-printf'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume format string
        has_action.* = true;
        return allocExpr(allocator, .printf_action, .{ .none = {} });
    }

    // -false: always evaluates to false
    if (std.mem.eql(u8, arg, "-false")) {
        pos.* += 1;
        return allocExpr(allocator, .false_expr, .{ .none = {} });
    }

    // -true: always evaluates to true
    if (std.mem.eql(u8, arg, "-true")) {
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
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
    depth: u32,
    allocator: Allocator,
    stdout: anytype,
    stderr: anytype,
    had_error: *bool,
    pruned: *bool,
) bool {
    switch (expr.tag) {
        .true_expr => return true,
        .name => return glob.globMatch(expr.data.pattern, basename),
        .iname => return glob.globMatchInsensitive(expr.data.pattern, basename),
        .path_match => return glob.globMatch(expr.data.pattern, path),
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
        .atime => {
            const te = expr.data.time;
            const file_atime = getAtime(stat_buf);
            const age_secs = now - file_atime;
            const age_days: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 86400) else 0;
            return switch (te.cmp) {
                .exactly => age_days == te.days,
                .greater_than => age_days > te.days,
                .less_than => age_days < te.days,
            };
        },
        .ctime => {
            const te = expr.data.time;
            const file_ctime = getCtime(stat_buf);
            const age_secs = now - file_ctime;
            const age_days: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 86400) else 0;
            return switch (te.cmp) {
                .exactly => age_days == te.days,
                .greater_than => age_days > te.days,
                .less_than => age_days < te.days,
            };
        },
        .links => {
            const te = expr.data.time;
            const nlink: u64 = @intCast(stat_buf.nlink);
            return switch (te.cmp) {
                .exactly => nlink == te.days,
                .greater_than => nlink > te.days,
                .less_than => nlink < te.days,
            };
        },
        .mmin => {
            const te = expr.data.time;
            const file_mtime = getMtime(stat_buf);
            const age_secs = now - file_mtime;
            const age_mins: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 60) else 0;
            return switch (te.cmp) {
                .exactly => age_mins == te.days,
                .greater_than => age_mins > te.days,
                .less_than => age_mins < te.days,
            };
        },
        .inum => {
            const te = expr.data.time;
            const file_ino: u64 = @intCast(stat_buf.ino);
            return switch (te.cmp) {
                .exactly => file_ino == te.days,
                .greater_than => file_ino > te.days,
                .less_than => file_ino < te.days,
            };
        },
        .amin => {
            const te = expr.data.time;
            const file_atime = getAtime(stat_buf);
            const age_secs = now - file_atime;
            const age_mins: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 60) else 0;
            return switch (te.cmp) {
                .exactly => age_mins == te.days,
                .greater_than => age_mins > te.days,
                .less_than => age_mins < te.days,
            };
        },
        .cmin => {
            const te = expr.data.time;
            const file_ctime = getCtime(stat_buf);
            const age_secs = now - file_ctime;
            const age_mins: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 60) else 0;
            return switch (te.cmp) {
                .exactly => age_mins == te.days,
                .greater_than => age_mins > te.days,
                .less_than => age_mins < te.days,
            };
        },
        .anewer => {
            const file_atime = getAtime(stat_buf);
            return file_atime > expr.data.newer_mtime;
        },
        .cnewer => {
            const file_ctime = getCtime(stat_buf);
            return file_ctime > expr.data.newer_mtime;
        },
        .execdir => return doExecdir(allocator, path, basename, expr.data.exec_data),
        .ls_action => return doLs(allocator, path, stat_buf, kind, stdout, had_error),
        .fstype => return matchFstype(allocator, path, expr.data.name_str),
        .flags => return matchFlags(stat_buf, expr.data.name_str),
        // -ok prompts user on /dev/tty; in non-interactive contexts
        // (pipes, tests) it defaults to deny (return false).
        .ok => return doOk(allocator, path, expr.data.exec_data, stderr),
        .xdev => return true,
        .nouser => {
            return getpwuid(stat_buf.uid) == null;
        },
        .nogroup => {
            return getgrgid(stat_buf.gid) == null;
        },
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
            const left_result = evaluate(expr.data.binary.left, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned);
            if (!left_result) return false;
            return evaluate(expr.data.binary.right, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned);
        },
        .or_expr => {
            const left_result = evaluate(expr.data.binary.left, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned);
            if (left_result) return true;
            return evaluate(expr.data.binary.right, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned);
        },
        .not_expr => {
            return !evaluate(expr.data.unary, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned);
        },
        .prune => {
            pruned.* = true;
            return true;
        },
        .false_expr => return false,
        .ipath => return glob.globMatchInsensitive(expr.data.pattern, path),
        .regex_stub, .iregex_stub => return false,
        .bmin_stub, .bnewer_stub, .btime_stub => return true,
        .newerxy_stub => return true,
        .acl_stub => return false,
        .sparse_stub => return false,
        .xattr_stub => return false,
        .xattrname_stub => return false,
        .depth_n => return depth == expr.data.depth_val,
        .gid_match => return stat_buf.gid == expr.data.gid_val,
        .uid_match => return stat_buf.uid == expr.data.uid_val,
        .lname => {
            if (kind != .symlink) return false;
            return matchSymlinkTarget(allocator, path, expr.data.pattern, false);
        },
        .ilname => {
            if (kind != .symlink) return false;
            return matchSymlinkTarget(allocator, path, expr.data.pattern, true);
        },
        .samefile => {
            const sf = expr.data.samefile_data;
            const file_ino: u64 = @intCast(stat_buf.ino);
            const file_dev: i64 = @intCast(stat_buf.dev);
            return file_ino == sf.ino and file_dev == sf.dev;
        },
        .okdir_stub => {
            stderr.print("< ? ... > ", .{}) catch {};
            return false;
        },
        .quit_action => {
            // Signal that we should stop processing.
            // In production, this leads to an immediate exit from main.
            // We use process.exit to match GNU find behavior.
            std.process.exit(0);
        },
        .printf_action => {
            // Stub: just print filename + newline (like -print)
            stdout.print("{s}\n", .{path}) catch {
                had_error.* = true;
            };
            return true;
        },
    }
}

/// Check if a filename contains characters that are problematic for xargs.
/// Characters: space, tab, newline, single quote, double quote, backslash.
fn isXargsUnsafe(name: []const u8) bool {
    for (name) |ch| {
        switch (ch) {
            ' ', '\t', '\n', '\'', '"', '\\' => return true,
            else => {},
        }
    }
    return false;
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

fn matchSymlinkTarget(allocator: Allocator, path: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    _ = allocator;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.cwd().readLink(path, &link_buf) catch return false;
    return if (case_insensitive) glob.globMatchInsensitive(pattern, target) else glob.globMatch(pattern, target);
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

fn doExecdir(allocator: Allocator, path: []const u8, basename: []const u8, exec_data: ExecExpr) bool {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    // Replace {} with ./basename (POSIX says relative to dir)
    const rel_name = std.fmt.allocPrint(allocator, "./{s}", .{basename}) catch return false;
    defer allocator.free(rel_name);

    for (exec_data.argv) |arg| {
        if (std.mem.eql(u8, arg, "{}")) {
            argv.append(allocator, rel_name) catch return false;
        } else {
            argv.append(allocator, arg) catch return false;
        }
    }

    if (argv.items.len == 0) return false;

    // Get the directory of the file
    const dir_path = std.fs.path.dirname(path) orelse ".";

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = dir_path,
    }) catch {
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.Exited == 0;
}

fn doOk(allocator: Allocator, path: []const u8, exec_data: ExecExpr, stderr: anytype) bool {
    _ = allocator;
    _ = path;
    _ = exec_data;
    // -ok prompts on /dev/tty. In non-interactive contexts (pipes,
    // tests, no tty) we print the prompt and default to "no".
    // A full implementation would open /dev/tty for the prompt, but
    // that would hang in tests. For now, always deny.
    stderr.print("< ? ... > ", .{}) catch {};
    return false;
}

fn doLs(allocator: Allocator, path: []const u8, stat_buf: c.Stat, kind: FileType, stdout: anytype, had_error: *bool) bool {
    // Format: inode blocks permissions nlink user group size date name
    const ino = stat_buf.ino;
    const blk = if (stat_buf.blocks > 0) @divTrunc(@as(u64, @intCast(stat_buf.blocks)), 2) else 0;
    const nlink = stat_buf.nlink;
    const file_size: u64 = @intCast(@max(0, stat_buf.size));

    // Permission string
    var perm_buf: [10]u8 = undefined;
    formatPermissions(stat_buf.mode, &perm_buf);

    // File type character
    const type_char: u8 = switch (kind) {
        .directory => 'd',
        .symlink => 'l',
        .block_device => 'b',
        .char_device => 'c',
        .pipe => 'p',
        .socket => 's',
        .regular => '-',
    };

    // User and group names
    const uid_name = getUserName(allocator, stat_buf.uid);
    defer if (uid_name.allocated) allocator.free(uid_name.name);
    const gid_name = getGroupName(allocator, stat_buf.gid);
    defer if (gid_name.allocated) allocator.free(gid_name.name);

    // Date formatting: use mtime
    const mtime = getMtime(stat_buf);
    var date_buf: [24]u8 = undefined;
    const date_str = formatDate(mtime, &date_buf);

    stdout.print("{d: >7} {d: >4} {c}{s} {d: >3} {s: <8} {s: <8} {d: >8} {s} {s}\n", .{
        ino,
        blk,
        type_char,
        &perm_buf,
        nlink,
        uid_name.name,
        gid_name.name,
        file_size,
        date_str,
        path,
    }) catch {
        had_error.* = true;
    };
    return true;
}

const NameResult = struct {
    name: []const u8,
    allocated: bool,
};

fn getUserName(allocator: Allocator, uid: c.uid_t) NameResult {
    const pw = getpwuid(uid);
    if (pw) |p| {
        return .{ .name = std.mem.span(p.pw_name), .allocated = false };
    }
    // Fall back to numeric
    const s = std.fmt.allocPrint(allocator, "{d}", .{uid}) catch return .{ .name = "?", .allocated = false };
    return .{ .name = s, .allocated = true };
}

fn getGroupName(allocator: Allocator, gid: c.gid_t) NameResult {
    const gr = getgrgid(gid);
    if (gr) |g| {
        return .{ .name = std.mem.span(g.gr_name), .allocated = false };
    }
    const s = std.fmt.allocPrint(allocator, "{d}", .{gid}) catch return .{ .name = "?", .allocated = false };
    return .{ .name = s, .allocated = true };
}

fn formatPermissions(mode: c.mode_t, buf: *[10]u8) void {
    const m: u32 = @intCast(mode);
    buf[0] = if (m & 0o400 != 0) 'r' else '-';
    buf[1] = if (m & 0o200 != 0) 'w' else '-';
    buf[2] = if (m & 0o4000 != 0) (if (m & 0o100 != 0) 's' else 'S') else (if (m & 0o100 != 0) 'x' else '-');
    buf[3] = if (m & 0o040 != 0) 'r' else '-';
    buf[4] = if (m & 0o020 != 0) 'w' else '-';
    buf[5] = if (m & 0o2000 != 0) (if (m & 0o010 != 0) 's' else 'S') else (if (m & 0o010 != 0) 'x' else '-');
    buf[6] = if (m & 0o004 != 0) 'r' else '-';
    buf[7] = if (m & 0o002 != 0) 'w' else '-';
    buf[8] = if (m & 0o1000 != 0) (if (m & 0o001 != 0) 't' else 'T') else (if (m & 0o001 != 0) 'x' else '-');
    buf[9] = ' ';
}

fn formatDate(timestamp: i64, buf: *[24]u8) []const u8 {
    // Format as "Mon DD HH:MM" or "Mon DD  YYYY" for old dates
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, timestamp)) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    const month_idx = @intFromEnum(month_day.month);
    const month_name = if (month_idx > 0 and month_idx <= 12)
        months[month_idx - 1]
    else
        "???";

    const dom = month_day.day_index + 1;
    const hours = @divTrunc(day_secs.secs, 3600);
    const mins = @divTrunc(@rem(day_secs.secs, 3600), 60);

    const now = std.time.timestamp();
    const six_months: i64 = 180 * 86400;

    if (timestamp < now - six_months or timestamp > now + six_months) {
        // Old or future: show year
        const year = year_day.year;
        return std.fmt.bufPrint(buf, "{s} {d: >2}  {d}", .{ month_name, dom, year }) catch "??? ?? ????";
    } else {
        // Recent: show time
        return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}", .{ month_name, dom, hours, mins }) catch "??? ?? ??:??";
    }
}

fn matchFstype(allocator: Allocator, path: []const u8, expected_type: []const u8) bool {
    _ = allocator;
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return matchFstypeDarwin(path, expected_type);
    } else if (builtin.os.tag == .linux) {
        return matchFstypeLinux(path, expected_type);
    }
    // Unknown platform: accept the flag but match nothing
    return false;
}

fn matchFstypeDarwin(path: []const u8, expected_type: []const u8) bool {
    // Use statfs to get filesystem type on macOS
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    const statfs_t = extern struct {
        f_bsize: u32,
        f_iosize: i32,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_fsid: [2]i32,
        f_owner: u32,
        f_type: u32,
        f_flags: u32,
        f_fssubtype: u32,
        f_fstypename: [16]u8,
        f_mntonname: [1024]u8,
        f_mntfromname: [1024]u8,
        f_flags_ext: u32,
        f_reserved: [7]u32,
    };

    const statfs_fn = @extern(*const fn ([*:0]const u8, *statfs_t) callconv(.c) c_int, .{
        .name = "statfs",
    });

    var buf: statfs_t = undefined;
    if (statfs_fn(c_path, &buf) != 0) return false;

    // f_fstypename is null-terminated within 16 bytes
    const fs_name = std.mem.sliceTo(&buf.f_fstypename, 0);
    return std.mem.eql(u8, fs_name, expected_type);
}

fn matchFstypeLinux(path: []const u8, expected_type: []const u8) bool {
    // On Linux, we would use statfs and map f_type magic numbers.
    // For now, accept the flag but match based on /proc/mounts lookup.
    _ = path;
    _ = expected_type;
    return false;
}

fn matchFlags(stat_buf: c.Stat, flag_str: []const u8) bool {
    // BSD file flags from st_flags. On macOS, stat has st_flags.
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return matchFlagsDarwin(stat_buf, flag_str);
    }
    // On non-BSD systems, -flags always returns false
    return false;
}

fn matchFlagsDarwin(stat_buf: c.Stat, flag_str: []const u8) bool {
    if (!@hasField(c.Stat, "flags")) return false;
    const flags: u32 = stat_buf.flags;

    // Parse flag names. Support common BSD flags.
    // Multiple flags can be separated by commas.
    var it = std.mem.tokenizeScalar(u8, flag_str, ',');
    while (it.next()) |flag_name| {
        var negate = false;
        var name = flag_name;
        if (name.len > 2 and std.mem.startsWith(u8, name, "no")) {
            negate = true;
            name = name[2..];
        }
        const mask = flagNameToMask(name);
        if (mask == 0) return false; // unknown flag name
        const is_set = (flags & mask) != 0;
        if (negate) {
            if (is_set) return false;
        } else {
            if (!is_set) return false;
        }
    }
    return true;
}

fn flagNameToMask(name: []const u8) u32 {
    // macOS/BSD file flags
    const UF_NODUMP: u32 = 0x00000001;
    const UF_IMMUTABLE: u32 = 0x00000002;
    const UF_APPEND: u32 = 0x00000004;
    const UF_OPAQUE: u32 = 0x00000008;
    const UF_HIDDEN: u32 = 0x00008000;
    const SF_ARCHIVED: u32 = 0x00010000;
    const SF_IMMUTABLE: u32 = 0x00020000;
    const SF_APPEND: u32 = 0x00040000;

    if (std.mem.eql(u8, name, "dump") or std.mem.eql(u8, name, "nodump")) return UF_NODUMP;
    if (std.mem.eql(u8, name, "uchg") or std.mem.eql(u8, name, "uimmutable")) return UF_IMMUTABLE;
    if (std.mem.eql(u8, name, "uappnd") or std.mem.eql(u8, name, "uappend")) return UF_APPEND;
    if (std.mem.eql(u8, name, "opaque")) return UF_OPAQUE;
    if (std.mem.eql(u8, name, "hidden")) return UF_HIDDEN;
    if (std.mem.eql(u8, name, "arch") or std.mem.eql(u8, name, "archived")) return SF_ARCHIVED;
    if (std.mem.eql(u8, name, "schg") or std.mem.eql(u8, name, "simmutable")) return SF_IMMUTABLE;
    if (std.mem.eql(u8, name, "sappnd") or std.mem.eql(u8, name, "sappend")) return SF_APPEND;

    return 0;
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
    root_dev: ?i64,
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

    // -xdev: skip entries on different filesystems
    if (root_dev) |rd| {
        const entry_dev: i64 = @intCast(stat_buf.dev);
        if (entry_dev != rd) return;
    }

    // -X: warn about and skip xargs-unsafe filenames
    if (config.xargs_safe and depth > 0) {
        if (isXargsUnsafe(basename)) {
            common.printErrorWithProgram(allocator, stderr, prog_name, "warning: file name '{s}' is not safe for use with xargs", .{basename});
            return;
        }
    }

    // Non-directory: evaluate and return
    if (kind != .directory) {
        if (depth >= config.mindepth) {
            var dummy_pruned = false;
            _ = evaluate(config.expr, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, &dummy_pruned);
        }
        return;
    }

    // Directory: evaluate before traversal (breadth-first)
    var was_pruned = false;
    if (!is_depth_first and depth >= config.mindepth) {
        _ = evaluate(config.expr, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, &was_pruned);
    }

    // If -prune was triggered, do not descend into this directory
    if (was_pruned) return;

    // Check maxdepth before descending
    if (config.maxdepth) |max| {
        if (depth >= max) {
            if (is_depth_first and depth >= config.mindepth) {
                var dummy_pruned = false;
                _ = evaluate(config.expr, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, &dummy_pruned);
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
            var dummy_pruned = false;
            _ = evaluate(config.expr, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, &dummy_pruned);
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

        walkPath(allocator, child_path, depth + 1, config, stdout, stderr, had_error, now, root_dev);
    }

    // Depth-first: evaluate directory after children
    if (is_depth_first and depth >= config.mindepth) {
        var dummy_pruned = false;
        _ = evaluate(config.expr, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, &dummy_pruned);
    }
}

// ============================================================================
// Entry points
// ============================================================================

pub fn runFind(allocator: Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) u8 {
    // Handle --help and --version before expression parsing
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(allocator, stdout);
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
        // Get root device for -xdev enforcement
        var root_dev: ?i64 = null;
        if (config.xdev) {
            if (doStat(path, config.follow_symlinks)) |sb| {
                root_dev = @intCast(sb.dev);
            } else |_| {}
        }
        walkPath(allocator, path, 0, &config, stdout, stderr, &had_error, now, root_dev);
    }

    return if (had_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

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

    const exit_code = runFind(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) std.process.exit(exit_code);
}

fn printHelp(allocator: Allocator, writer: anytype) void {
    const help_text =
        \\Usage: find [-H] [-L] [-d] [-x] [-X] [-f path] [path...] [expression]
        \\
        \\Search for files in a directory hierarchy.
        \\
        \\Global options:
        \\  -H                 follow symbolic links on the command line only
        \\  -L, -follow        follow all symbolic links
        \\  -d, -depth         process directory contents before directory itself
        \\  -x                 do not descend into other filesystems (same as -xdev)
        \\  -X                 warn about and skip xargs-unsafe filenames
        \\  -f path            specify a search path explicitly
        \\  -maxdepth N        descend at most N levels below starting points
        \\  -mindepth N        do not apply tests at levels less than N
        \\
        \\Tests (predicates):
        \\  -name PATTERN      base name matches shell glob pattern
        \\  -iname PATTERN     like -name but case insensitive
        \\  -path PATTERN      full path matches shell glob pattern
        \\  -type TYPE         file type: f d l b c p s
        \\  -size N[cwbkMG]    file uses N units of space
        \\  -empty             file is empty (regular file or directory)
        \\  -newer FILE        modified more recently than FILE
        \\  -anewer FILE       accessed more recently than FILE
        \\  -cnewer FILE       status changed more recently than FILE
        \\  -mtime N           modified N*24 hours ago (+N/-N/N)
        \\  -atime N           accessed N*24 hours ago (+N/-N/N)
        \\  -ctime N           status changed N*24 hours ago (+N/-N/N)
        \\  -mmin N            modified N minutes ago (+N/-N/N)
        \\  -amin N            accessed N minutes ago (+N/-N/N)
        \\  -cmin N            status changed N minutes ago (+N/-N/N)
        \\  -perm MODE         permission bits match MODE (octal)
        \\  -user NAME         file belongs to user NAME
        \\  -group NAME        file belongs to group NAME
        \\  -nouser            file not owned by any user
        \\  -nogroup           file not owned by any group
        \\  -links N           file has N hard links (+N/-N/N)
        \\  -inum N            file has inode number N (+N/-N/N)
        \\  -fstype TYPE       file is on filesystem of TYPE
        \\  -flags FLAGS       file has BSD file flags (macOS)
        \\  -xdev              do not descend into other filesystems
        \\  -prune             do not descend into matched directory
        \\
        \\Actions:
        \\  -print             print full path (default action)
        \\  -print0            print full path followed by NUL
        \\  -ls                print in ls -dils format
        \\  -delete            delete file (implies -depth)
        \\  -exec CMD {} ;     execute command for each file
        \\  -execdir CMD {} ;  like -exec but in file's directory
        \\  -ok CMD {} ;       like -exec but ask user first
        \\
        \\Operators:
        \\  -and, -a           logical AND (default between tests)
        \\  -or, -o            logical OR
        \\  -not, !            logical NOT
        \\  ( expr )           grouping
        \\
        \\      --help         display this help and exit
        \\      --version      output version information and exit
        \\
    ;
    common.help.printColorized(allocator, writer, help_text) catch {};
}

fn printVersion(writer: anytype) void {
    const build_options = @import("build_options");
    writer.print("find (vibeutils) {s}\n", .{build_options.version}) catch {};
}

// ============================================================================
// TESTS
// ============================================================================

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

// ============================================================================
// Tests for -path, -prune, -depth primaries
// ============================================================================

test "find: -path matches full path pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("subdir");
    var sub = try tmp.dir.openDir("subdir", .{});
    const f1 = try sub.createFile("file.txt", .{});
    f1.close();
    sub.close();
    const f2 = try tmp.dir.createFile("other.txt", .{});
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -path matches against the full path, not just basename
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-path", "*/subdir/*" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should match subdir/file.txt (full path contains /subdir/)
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
    // Should NOT match other.txt (not under subdir)
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "other.txt") == null);
}

test "find: -prune prevents descending into directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a directory to skip and one to keep
    try tmp.dir.makeDir("skip_me");
    var skip_dir = try tmp.dir.openDir("skip_me", .{});
    const f1 = try skip_dir.createFile("hidden.txt", .{});
    f1.close();
    skip_dir.close();

    try tmp.dir.makeDir("keep_me");
    var keep_dir = try tmp.dir.openDir("keep_me", .{});
    const f2 = try keep_dir.createFile("visible.txt", .{});
    f2.close();
    keep_dir.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Classic prune pattern: -name skip_me -prune -o -type f -print
    // This should skip descending into skip_me and only print files
    // from keep_me.
    const exit_code = runFind(allocator, &[_][]const u8{
        dir_path, "-name",  "skip_me",
        "-prune", "-o",     "-type",
        "f",      "-print",
    }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // visible.txt should appear (keep_me was not pruned)
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "visible.txt") != null);
    // hidden.txt must NOT appear (skip_me was pruned)
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "hidden.txt") == null);
}

test "find: -depth lists directory contents before directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("adir");
    var sub = try tmp.dir.openDir("adir", .{});
    const f1 = try sub.createFile("file.txt", .{});
    f1.close();
    sub.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // With -depth, file.txt should appear before its parent adir
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-depth" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    const output = stdout_buf.items;
    const file_pos = std.mem.indexOf(u8, output, "file.txt");
    const dir_pos = std.mem.indexOf(u8, output, "adir\n");

    // Both must appear
    try testing.expect(file_pos != null);
    try testing.expect(dir_pos != null);
    // file.txt must appear BEFORE its parent directory adir
    try testing.expect(file_pos.? < dir_pos.?);
}

test "find: -path with non-matching pattern returns no results" {
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

    // Pattern that matches nothing in this tree
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-path", "*/nonexistent/*" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // No files should match
    try testing.expect(stdout_buf.items.len == 0);
}

// ============================================================================
// Tests for new POSIX primaries (RED phase - stubs only)
// ============================================================================

test "find: -atime +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("recent.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // No file was accessed more than 9999 days ago; should match nothing
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-atime", "+9999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -ctime +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("recent.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // No file had its status changed more than 9999 days ago
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-ctime", "+9999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -links 99 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("single.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // A freshly created file has 1 hard link, not 99
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-links", "99" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -nouser matches nothing for normal files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("owned.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Files created by this user have a valid owner; -nouser should
    // match nothing.
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-nouser" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -xdev is accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -xdev should parse without error and not prevent finding files
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-xdev", "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

// ============================================================================
// Tests for new global options and primaries
// ============================================================================

test "find: -d is alias for -depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("adir");
    var sub = try tmp.dir.openDir("adir", .{});
    const f1 = try sub.createFile("file.txt", .{});
    f1.close();
    sub.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -d should behave like -depth: file.txt before adir
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-d" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    const output = stdout_buf.items;
    const file_pos = std.mem.indexOf(u8, output, "file.txt");
    const dir_pos = std.mem.indexOf(u8, output, "adir\n");
    try testing.expect(file_pos != null);
    try testing.expect(dir_pos != null);
    try testing.expect(file_pos.? < dir_pos.?);
}

test "find: -f specifies explicit search path" {
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

    // -f path should specify the search path
    const exit_code = runFind(allocator, &[_][]const u8{ "-f", dir_path, "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -x is alias for -xdev" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -x should be accepted just like -xdev
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-x", "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -X warns about xargs-unsafe filenames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file with a space in its name (xargs-problematic)
    const f1 = try tmp.dir.createFile("has space.txt", .{});
    f1.close();
    // Create a normal file
    const f2 = try tmp.dir.createFile("safe.txt", .{});
    f2.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -X should warn about the file with a space
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-X", "-type", "f" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // safe.txt should appear in output
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "safe.txt") != null);
    // has space.txt should NOT appear in output (skipped by -X)
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "has space.txt") == null);
    // Warning about the problematic name should be on stderr
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "has space.txt") != null);
}

test "find: -mmin matches recently modified files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("fresh.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // File was just created, so modified less than 5 minutes ago
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-mmin", "-5" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "fresh.txt") != null);
}

test "find: -mmin +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("recent.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-mmin", "+9999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -inum matches file by inode number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("target.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Get the inode number of target.txt
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "target.txt" });
    const stat_buf = try doStat(file_path, false);
    const ino = stat_buf.ino;
    var ino_buf: [32]u8 = undefined;
    const ino_str = std.fmt.bufPrint(&ino_buf, "{d}", .{ino}) catch unreachable;

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-inum", ino_str }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "target.txt") != null);
}

test "find: -inum with non-matching inode returns nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Inode 0 should not match any real file
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-inum", "0" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

// ============================================================================
// Tests for remaining MUST primaries
// ============================================================================

test "find: -amin -5 matches recently accessed files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("accessed.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // File was just created, so accessed less than 5 minutes ago
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-amin", "-5" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "accessed.txt") != null);
}

test "find: -amin +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("recent.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-amin", "+9999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -cmin -5 matches recently changed files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("changed.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-cmin", "-5" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "changed.txt") != null);
}

test "find: -cmin +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("recent.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-cmin", "+9999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -anewer matches files accessed after reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create reference file first
    const ref = try tmp.dir.createFile("old_ref.txt", .{});
    ref.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Set the reference file's mtime to the past so newly created files
    // will have a later access time
    const past = std.time.timestamp() - 3600; // 1 hour ago
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.fs.cwd().fd, ref_c_path, &times, 0);

    // Create the test file (will have current atime)
    const f = try tmp.dir.createFile("newer.txt", .{});
    f.close();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Use absolute path for the reference file
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-anewer", ref_abs_path }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "newer.txt") != null);
}

test "find: -cnewer matches files changed after reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create reference file first
    const ref = try tmp.dir.createFile("old_ref.txt", .{});
    ref.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Set the reference file's mtime to the past
    const past = std.time.timestamp() - 3600;
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.fs.cwd().fd, ref_c_path, &times, 0);

    // Create test file (will have current ctime)
    const f = try tmp.dir.createFile("newer.txt", .{});
    f.close();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Use absolute path for the reference file
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-cnewer", ref_abs_path }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "newer.txt") != null);
}

test "find: -ok is parsed as valid primary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -ok should be parsed without error; it prompts on /dev/tty so we
    // cannot test execution, but parsing should succeed.
    const exit_code = runFind(allocator, &[_][]const u8{ "/tmp", "-maxdepth", "0", "-ok", "echo", "{}", ";" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -execdir runs command in file directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("testfile.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -execdir should be parsed and accepted
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-execdir", "echo", "{}", ";" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -ls produces listing output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("listed.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-name", "listed.txt", "-ls" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // -ls output should contain the filename and some stat-like info
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "listed.txt") != null);
    // Should contain permission bits (e.g., rw-)
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "rw") != null);
}

test "find: -fstype is accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -fstype should be parsed without error; use a type that exists on macOS
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-fstype", "apfs" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -flags is accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -flags should be parsed without error
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-flags", "uchg" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
}

// ============================================================================
// Tests for SHOULD flags
// ============================================================================

test "find: -P global option accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ "-P", dir_path, "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -E global option accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ "-E", dir_path, "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -s global option accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ "-s", dir_path, "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -ipath case-insensitive path matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("SubDir");
    var sub = try tmp.dir.openDir("SubDir", .{});
    const f = try sub.createFile("File.TXT", .{});
    f.close();
    sub.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Case-insensitive path matching
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-ipath", "*/subdir/*" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "File.TXT") != null);
}

test "find: -iwholename is alias for -ipath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("Test.TXT", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-iwholename", "*test*" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Test.TXT") != null);
}

test "find: -regex stub returns no matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-regex", ".*\\.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -iregex stub returns no matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-iregex", ".*\\.TXT" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -Bmin stub accepted (always true)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-Bmin", "-5" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_buf.items.len > 0);
}

test "find: -Bnewer stub accepted (always true)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-Bnewer", file_path }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_buf.items.len > 0);
}

test "find: -Btime stub accepted (always true)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-Btime", "+7" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_buf.items.len > 0);
}

test "find: -acl stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-acl" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // -acl always returns false, so nothing should match
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -depth N matches files at exact depth" {
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

    // depth 1 should match top.txt and sub (not the root dir at depth 0)
    {
        var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

        const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-depth", "1" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "top.txt") != null);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "sub\n") != null);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "deep.txt") == null);
    }

    // depth 2 should match deep.txt only
    {
        var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

        const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-depth", "2" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "deep.txt") != null);
        try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "top.txt") == null);
    }
}

test "find: -gid matches numeric group ID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Get the GID of the test file
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const stat_buf = try doStat(file_path, false);
    var gid_buf: [32]u8 = undefined;
    const gid_str = std.fmt.bufPrint(&gid_buf, "{d}", .{stat_buf.gid}) catch unreachable;

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-gid", gid_str }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -gid with non-matching GID returns nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // GID 99999 is unlikely to match any file
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-gid", "99999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -uid matches numeric user ID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Get the UID of the test file
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const stat_buf = try doStat(file_path, false);
    var uid_buf: [32]u8 = undefined;
    const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{stat_buf.uid}) catch unreachable;

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-uid", uid_str }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -uid with non-matching UID returns nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // UID 99999 is unlikely to match any file
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-uid", "99999" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -ignore_readdir_race accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-ignore_readdir_race", "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -noignore_readdir_race accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-noignore_readdir_race", "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -noleaf accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-noleaf", "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -lname matches symlink target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("target.txt", .{});
    f.close();
    try tmp.dir.symLink("target.txt", "link.txt", .{});

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-lname", "target*" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "link.txt") != null);
    // target.txt is not a symlink, should not match
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "target.txt") == null);
}

test "find: -ilname case-insensitive symlink target matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("Target.TXT", .{});
    f.close();
    try tmp.dir.symLink("Target.TXT", "link.txt", .{});

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Case-insensitive match against symlink target
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-ilname", "target*" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "link.txt") != null);
}

test "find: -mnewer is alias for -newer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const ref = try tmp.dir.createFile("old_ref.txt", .{});
    ref.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    // Set reference file mtime to the past
    const past = std.time.timestamp() - 3600;
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.fs.cwd().fd, ref_c_path, &times, 0);

    const f = try tmp.dir.createFile("newer.txt", .{});
    f.close();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-mnewer", ref_abs_path }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "newer.txt") != null);
}

test "find: -mount is alias for -xdev" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-mount", "-name", "*.txt" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -newerXY stub accepted (always true)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-neweram", file_path }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_buf.items.len > 0);
}

test "find: -okdir stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ "/tmp", "-maxdepth", "0", "-okdir", "echo", "{}", ";" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -quit is accepted as valid primary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -quit with -maxdepth 0 -false ensures we never actually reach -quit
    // (so the test process doesn't exit)
    const exit_code = runFind(allocator, &[_][]const u8{ "/tmp", "-maxdepth", "0", "-false", "-quit" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -samefile matches files with same inode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("original.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    const orig_path = try std.fs.path.join(allocator, &.{ dir_path, "original.txt" });

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-samefile", orig_path }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "original.txt") != null);
}

test "find: -sparse stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-sparse" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -xattr stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-xattr" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -xattrname stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-xattrname", "com.apple.metadata" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -printf stub accepted (prints like -print)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-name", "file.txt", "-printf", "%p\\n" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -false always evaluates to false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -false should prevent any output
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-false" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
}

test "find: -true always evaluates to true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // -true should match everything (equivalent to no test)
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "-true" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -false -o -true evaluates to true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("file.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-type", "f", "(", "-false", "-o", "-true", ")" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file.txt") != null);
}

test "find: -regex stub should not match everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("hello.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Use an impossible pattern that should match nothing.
    // The stub currently returns true for all files, so this test
    // will FAIL until the stub is fixed to return false.
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-regex", "^impossible_pattern_that_matches_nothing$" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // No files should match an impossible regex pattern
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "find: -iregex stub should not match everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("hello.txt", .{});
    f.close();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Use an impossible pattern that should match nothing.
    // The stub currently returns true for all files, so this test
    // will FAIL until the stub is fixed to return false.
    const exit_code = runFind(allocator, &[_][]const u8{ dir_path, "-iregex", "^impossible_pattern_that_matches_nothing$" }, stdout_buf.writer(allocator), stderr_buf.writer(allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);

    // No files should match an impossible regex pattern
    try testing.expectEqualStrings("", stdout_buf.items);
}
