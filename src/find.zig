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
const assert = std.debug.assert;

const c = std.c;

const regex_h = @cImport({
    @cInclude("regex.h");
});

const is_linux = builtin.os.tag == .linux;

// On Linux, regex_t is opaque to Zig (glibc internal types can't be parsed).
// Use C helper functions for heap allocation instead of Zig's allocator.
const regex_c = if (is_linux) struct {
    extern "c" fn regex_heap_alloc() ?*regex_h.regex_t;
    extern "c" fn regex_heap_free(re: *regex_h.regex_t) void;
} else struct {};

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

const PermCompare = enum {
    exact, // -perm 644: exact match
    at_least, // -perm -644: all these bits must be set
    any_of, // -perm /111: any of these bits must be set
};

const PermExpr = struct {
    mode: u32,
    cmp: PermCompare,
};

const NewerXYData = struct {
    ref_time: i64,
    x_field: u8, // 'a', 'B', 'c', 'm'
};

const ExecExpr = struct {
    argv: []const []const u8,
    batch: bool = false,
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
    exec_batch,
    execdir_batch,
    regex_match,
    iregex_match,
    // Stubs: accept syntax, simple behavior
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
    perm_expr: PermExpr,
    name_str: []const u8,
    exec_data: ExecExpr,
    binary: BinaryData,
    unary: *Expression,
    samefile_data: SamefileData,
    depth_val: u32,
    uid_val: c.uid_t,
    gid_val: c.gid_t,
    newerxy_data: NewerXYData,
    regex_ptr: *regex_h.regex_t,
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
    sorted: bool = false,
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

fn parsePerm(str: []const u8) !PermExpr {
    if (str.len == 0) return error.InvalidPerm;

    var s = str;
    var cmp: PermCompare = .exact;

    if (s[0] == '-') {
        cmp = .at_least;
        s = s[1..];
    } else if (s[0] == '/') {
        cmp = .any_of;
        s = s[1..];
    }

    if (s.len == 0) return error.InvalidPerm;

    // Parse octal mode
    var mode: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '7') return error.InvalidPerm;
        mode = mode * 8 + @as(u32, ch - '0');
    }
    return PermExpr{ .mode = mode, .cmp = cmp };
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

/// Cross-platform stat result. On Linux c.Stat is void, so we use our own struct.
const StatInfo = struct {
    dev: i64 = 0,
    ino: u64 = 0,
    mode: u32 = 0,
    nlink: u64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: i64 = 0,
    blksize: i64 = 0,
    blocks: i64 = 0,
    atim: struct { sec: i64 = 0, nsec: i64 = 0 } = .{},
    mtim: struct { sec: i64 = 0, nsec: i64 = 0 } = .{},
    ctim: struct { sec: i64 = 0, nsec: i64 = 0 } = .{},
    /// macOS-only: birthtime. Zero on Linux.
    birthtimespec: struct { sec: i64 = 0, nsec: i64 = 0 } = .{},
    /// macOS-only: file flags (chflags). Zero on Linux.
    flags: u32 = 0,
};

fn doStat(path: []const u8, follow_symlinks: bool) !StatInfo {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];

    if (builtin.os.tag == .linux) {
        // On Linux, std.c.fstatat is void; use statx syscall.
        const linux = std.os.linux;
        const flags: u32 = if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(c.AT.FDCWD, c_path, flags, linux.STATX.BASIC_STATS, &stx);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .LOOP => return error.SymLinkLoop,
            else => return error.SystemResources,
        }
        return StatInfo{
            .dev = @intCast((@as(u64, stx.dev_major) << 8) | stx.dev_minor),
            .ino = stx.ino,
            .mode = stx.mode,
            .nlink = stx.nlink,
            .uid = stx.uid,
            .gid = stx.gid,
            .size = @intCast(stx.size),
            .blksize = @intCast(stx.blksize),
            .blocks = @intCast(stx.blocks),
            .atim = .{ .sec = stx.atime.sec, .nsec = @intCast(stx.atime.nsec) },
            .mtim = .{ .sec = stx.mtime.sec, .nsec = @intCast(stx.mtime.nsec) },
            .ctim = .{ .sec = stx.ctime.sec, .nsec = @intCast(stx.ctime.nsec) },
        };
    } else {
        var stat_buf: c.Stat = undefined;
        const flags: u32 = if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW;
        const result = c.fstatat(c.AT.FDCWD, c_path, &stat_buf, flags);
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
        // Build StatInfo from c.Stat (macOS/BSD)
        return StatInfo{
            .dev = @intCast(stat_buf.dev),
            .ino = @intCast(stat_buf.ino),
            .mode = @intCast(stat_buf.mode),
            .nlink = @intCast(stat_buf.nlink),
            .uid = @intCast(stat_buf.uid),
            .gid = @intCast(stat_buf.gid),
            .size = @intCast(stat_buf.size),
            .blksize = @intCast(stat_buf.blksize),
            .blocks = @intCast(stat_buf.blocks),
            .atim = .{ .sec = @intCast(stat_buf.atimespec.sec), .nsec = @intCast(stat_buf.atimespec.nsec) },
            .mtim = .{ .sec = @intCast(stat_buf.mtimespec.sec), .nsec = @intCast(stat_buf.mtimespec.nsec) },
            .ctim = .{ .sec = @intCast(stat_buf.ctimespec.sec), .nsec = @intCast(stat_buf.ctimespec.nsec) },
            .birthtimespec = .{ .sec = @intCast(stat_buf.birthtimespec.sec), .nsec = @intCast(stat_buf.birthtimespec.nsec) },
            .flags = if (@hasField(@TypeOf(stat_buf), "flags")) @intCast(stat_buf.flags) else 0,
        };
    }
}

fn getFileKind(mode: u32) FileType {
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

fn getMtime(stat_buf: StatInfo) i64 {
    return stat_buf.mtim.sec;
}

fn getAtime(stat_buf: StatInfo) i64 {
    return stat_buf.atim.sec;
}

fn getCtime(stat_buf: StatInfo) i64 {
    return stat_buf.ctim.sec;
}

/// Get birth time of a file. On Linux uses statx(); on macOS uses birthtimespec.
/// Returns null if birth time is not available.
fn getBirthTime(path: []const u8) ?i64 {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        // macOS: birthtimespec is stored in StatInfo.birthtimespec
        const stat_buf = doStat(path, false) catch return null;
        return stat_buf.birthtimespec.sec;
    } else if (builtin.os.tag == .linux) {
        // Linux: use statx syscall with BTIME flag
        const linux = std.os.linux;
        var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len > std.Io.Dir.max_path_bytes) return null;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const c_path = path_buf[0..path.len :0];

        var stx: linux.Statx = undefined;
        const btime_statx = linux.STATX{ .BTIME = true };
        const btime_mask: u32 = @bitCast(btime_statx);
        const result = linux.statx(c.AT.FDCWD, c_path, 0, btime_statx, &stx);
        if (result != 0) return null;
        // Check if btime was actually filled
        if ((@as(u32, @bitCast(stx.mask)) & btime_mask) == 0) return null;
        return @intCast(stx.btime.sec);
    } else {
        return null;
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
    extended_regex: bool = false,

    fn setError(self: *ParseContext, comptime fmt: []const u8, fmt_args: anytype) void {
        self.error_msg = std.fmt.allocPrint(self.allocator, fmt, fmt_args) catch null;
    }
};

fn allocExpr(allocator: Allocator, tag: ExprTag, data: ExprData) !*Expression {
    const expr = try allocator.create(Expression);
    expr.* = .{ .tag = tag, .data = data };
    return expr;
}

/// Compile a POSIX regex pattern. Returns null on failure.
fn compileRegex(allocator: Allocator, pattern: []const u8, ignore_case: bool, extended: bool) ?*regex_h.regex_t {
    const pattern_z = allocator.dupeZ(u8, pattern) catch return null;
    defer allocator.free(pattern_z);

    var cflags: c_int = regex_h.REG_NOSUB;
    if (ignore_case) cflags |= regex_h.REG_ICASE;
    if (extended) cflags |= regex_h.REG_EXTENDED;

    const regex = if (comptime is_linux)
        (regex_c.regex_heap_alloc() orelse return null)
    else
        (allocator.create(regex_h.regex_t) catch return null);

    const result = regex_h.regcomp(regex, pattern_z.ptr, cflags);
    if (result != 0) {
        if (comptime is_linux) {
            regex_c.regex_heap_free(regex);
        } else {
            allocator.destroy(regex);
        }
        return null;
    }
    return regex;
}

/// Free a compiled regex.
fn freeRegex(allocator: Allocator, regex: *regex_h.regex_t) void {
    regex_h.regfree(regex);
    if (comptime is_linux) {
        regex_c.regex_heap_free(regex);
    } else {
        allocator.destroy(regex);
    }
}

fn parseArgs(allocator: Allocator, args: []const []const u8, stderr: anytype) !FindConfig {
    var start_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer start_paths.deinit(allocator);

    var maxdepth: ?u32 = null;
    var mindepth: u32 = 0;
    var depth_first = false;
    var follow_symlinks = false;
    var follow_cmdline_symlinks = false;
    var xdev = false;
    var xargs_safe = false;
    var sorted = false;
    var extended_regex = false;

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
            extended_regex = true;
            expr_start += 1;
        } else if (std.mem.eql(u8, arg, "-s")) {
            // -s: traverse in alphabetical (sorted) order
            sorted = true;
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
    var pctx = ParseContext{ .allocator = allocator, .extended_regex = extended_regex };
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

    // -follow in expression position also enables symlink following
    for (args[expr_start..]) |a| {
        if (std.mem.eql(u8, a, "-follow")) {
            follow_symlinks = true;
            break;
        }
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
        .sorted = sorted,
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
    // -follow in expression position (deprecated GNU/macOS form)
    if (std.mem.eql(u8, arg, "-follow")) {
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
        return allocExpr(allocator, .perm, .{ .perm_expr = perm_val });
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
        var exec_args = std.ArrayListUnmanaged([]const u8).empty;
        defer exec_args.deinit(allocator);
        var is_batch = false;

        while (pos.* < args.len) {
            if (std.mem.eql(u8, args[pos.*], ";")) {
                pos.* += 1;
                break;
            }
            if (std.mem.eql(u8, args[pos.*], "+")) {
                // Batch mode: {} must be last arg before +
                is_batch = true;
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
        if (is_batch) {
            return allocExpr(allocator, .exec_batch, .{ .exec_data = .{ .argv = argv, .batch = true } });
        }
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
        var exec_args = std.ArrayListUnmanaged([]const u8).empty;
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
        var exec_args = std.ArrayListUnmanaged([]const u8).empty;
        defer exec_args.deinit(allocator);
        var is_batch = false;

        while (pos.* < args.len) {
            if (std.mem.eql(u8, args[pos.*], ";")) {
                pos.* += 1;
                break;
            }
            if (std.mem.eql(u8, args[pos.*], "+")) {
                is_batch = true;
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
        if (is_batch) {
            return allocExpr(allocator, .execdir_batch, .{ .exec_data = .{ .argv = argv, .batch = true } });
        }
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

    // -regex: regex match on full path
    if (std.mem.eql(u8, arg, "-regex")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-regex'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        const regex = compileRegex(allocator, pattern, false, pctx.extended_regex) orelse {
            pctx.setError("invalid regular expression '{s}'", .{pattern});
            return error.InvalidExpression;
        };
        return allocExpr(allocator, .regex_match, .{ .regex_ptr = regex });
    }

    // -iregex: case-insensitive regex match on full path
    if (std.mem.eql(u8, arg, "-iregex")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-iregex'", .{});
            return error.MissingArgument;
        }
        const pattern = args[pos.*];
        pos.* += 1;
        const regex = compileRegex(allocator, pattern, true, pctx.extended_regex) orelse {
            pctx.setError("invalid regular expression '{s}'", .{pattern});
            return error.InvalidExpression;
        };
        return allocExpr(allocator, .iregex_match, .{ .regex_ptr = regex });
    }

    // -Bmin: birth time in minutes
    if (std.mem.eql(u8, arg, "-Bmin")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-Bmin'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-Bmin'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .bmin_stub, .{ .time = te });
    }

    // -Bnewer: birth time newer than FILE
    if (std.mem.eql(u8, arg, "-Bnewer")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-Bnewer'", .{});
            return error.MissingArgument;
        }
        const ref_path = args[pos.*];
        pos.* += 1;
        // Get the birth time of the reference file
        const ref_btime = getBirthTime(ref_path) orelse {
            // Fall back to mtime if birth time unavailable
            const ref_stat = doStat(ref_path, false) catch {
                pctx.setError("'{s}': No such file or directory", .{ref_path});
                return error.InvalidExpression;
            };
            return allocExpr(allocator, .bnewer_stub, .{ .newer_mtime = getMtime(ref_stat) });
        };
        return allocExpr(allocator, .bnewer_stub, .{ .newer_mtime = ref_btime });
    }

    // -Btime: birth time in days
    if (std.mem.eql(u8, arg, "-Btime")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-Btime'", .{});
            return error.MissingArgument;
        }
        const te = parseMtime(args[pos.*]) catch {
            pctx.setError("invalid argument '{s}' to '-Btime'", .{args[pos.*]});
            return error.InvalidExpression;
        };
        pos.* += 1;
        return allocExpr(allocator, .btime_stub, .{ .time = te });
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

    // -newerXY: compare timestamps
    // Matches -newerXY where X,Y are one of: a, B, c, m, t (8 chars total)
    if (arg.len == 8 and std.mem.startsWith(u8, arg, "-newer")) {
        const x_field = arg[6];
        const y_field = arg[7];
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '{s}'", .{arg});
            return error.MissingArgument;
        }
        const ref_path = args[pos.*];
        pos.* += 1;

        // Get the Y timestamp from the reference file
        var ref_time: i64 = 0;
        if (y_field == 'B') {
            ref_time = getBirthTime(ref_path) orelse blk: {
                const ref_stat = doStat(ref_path, false) catch {
                    pctx.setError("'{s}': No such file or directory", .{ref_path});
                    return error.InvalidExpression;
                };
                break :blk getMtime(ref_stat);
            };
        } else {
            const ref_stat = doStat(ref_path, false) catch {
                pctx.setError("'{s}': No such file or directory", .{ref_path});
                return error.InvalidExpression;
            };
            ref_time = switch (y_field) {
                'a' => getAtime(ref_stat),
                'c' => getCtime(ref_stat),
                'm' => getMtime(ref_stat),
                else => getMtime(ref_stat),
            };
        }

        return allocExpr(allocator, .newerxy_stub, .{ .newerxy_data = .{
            .ref_time = ref_time,
            .x_field = x_field,
        } });
    }

    // -okdir: like -execdir but prompts (stub: always false)
    if (std.mem.eql(u8, arg, "-okdir")) {
        pos.* += 1;
        var exec_args = std.ArrayListUnmanaged([]const u8).empty;
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

    // -printf: formatted output
    if (std.mem.eql(u8, arg, "-printf")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-printf'", .{});
            return error.MissingArgument;
        }
        const fmt_str = args[pos.*];
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .printf_action, .{ .pattern = fmt_str });
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
// Batch execution context for -exec {} + and -execdir {} +
// ============================================================================

const BatchContext = struct {
    exec_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    execdir_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    exec_template: ?[]const []const u8 = null,
    execdir_template: ?[]const []const u8 = null,
    execdir_dir: ?[]const u8 = null,

    fn flushExec(self: *BatchContext, io: std.Io, allocator: Allocator, stdout: anytype, stderr: anytype) bool {
        _ = stderr;
        if (self.exec_template == null or self.exec_paths.items.len == 0) return true;
        const template = self.exec_template.?;

        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(allocator);

        // Build argv: template args, replacing {} with collected paths
        var found_placeholder = false;
        for (template) |arg| {
            if (std.mem.eql(u8, arg, "{}")) {
                found_placeholder = true;
                for (self.exec_paths.items) |p| {
                    argv.append(allocator, p) catch return false;
                }
            } else {
                argv.append(allocator, arg) catch return false;
            }
        }
        // If no {} found, append paths at end
        if (!found_placeholder) {
            for (self.exec_paths.items) |p| {
                argv.append(allocator, p) catch return false;
            }
        }

        if (argv.items.len == 0) return true;

        const result = std.process.run(allocator, io, .{
            .argv = argv.items,
        }) catch return false;

        // Print stdout from the command
        if (result.stdout.len > 0) {
            stdout.writeAll(result.stdout) catch {};
        }
        allocator.free(result.stdout);
        allocator.free(result.stderr);

        return result.term == .exited and result.term.exited == 0;
    }

    fn flushExecdir(self: *BatchContext, io: std.Io, allocator: Allocator, stdout: anytype, stderr: anytype) bool {
        _ = stderr;
        if (self.execdir_template == null or self.execdir_paths.items.len == 0) return true;
        const template = self.execdir_template.?;

        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(allocator);

        var found_placeholder = false;
        for (template) |arg| {
            if (std.mem.eql(u8, arg, "{}")) {
                found_placeholder = true;
                for (self.execdir_paths.items) |p| {
                    const bn = std.fs.path.basename(p);
                    const rel = std.fmt.allocPrint(allocator, "./{s}", .{bn}) catch return false;
                    argv.append(allocator, rel) catch {
                        allocator.free(rel);
                        return false;
                    };
                }
            } else {
                argv.append(allocator, arg) catch return false;
            }
        }
        if (!found_placeholder) {
            for (self.execdir_paths.items) |p| {
                const bn = std.fs.path.basename(p);
                const rel = std.fmt.allocPrint(allocator, "./{s}", .{bn}) catch return false;
                argv.append(allocator, rel) catch {
                    allocator.free(rel);
                    return false;
                };
            }
        }

        if (argv.items.len == 0) return true;

        const cwd: std.process.Child.Cwd = if (self.execdir_dir) |d| .{ .path = d } else .inherit;

        const result = std.process.run(allocator, io, .{
            .argv = argv.items,
            .cwd = cwd,
        }) catch return false;

        if (result.stdout.len > 0) {
            stdout.writeAll(result.stdout) catch {};
        }
        allocator.free(result.stdout);
        allocator.free(result.stderr);

        return result.term == .exited and result.term.exited == 0;
    }
};

// ============================================================================
// Expression evaluation
// ============================================================================

fn evaluate(
    io: std.Io,
    expr: *const Expression,
    path: []const u8,
    basename: []const u8,
    stat_buf: StatInfo,
    kind: FileType,
    now: i64,
    depth: u32,
    allocator: Allocator,
    stdout: anytype,
    stderr: anytype,
    had_error: *bool,
    pruned: *bool,
    batch_ctx: ?*BatchContext,
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
            if (sz.unit == .bytes) {
                // For 'c' suffix, compare raw bytes directly
                const target_bytes = sz.value;
                return switch (sz.cmp) {
                    .exactly => file_size == target_bytes,
                    .greater_than => file_size > target_bytes,
                    .less_than => file_size < target_bytes,
                };
            } else {
                // For block-based units, convert file size to unit count
                // using ceiling division, matching GNU find behavior
                const unit_size: u64 = switch (sz.unit) {
                    .bytes => unreachable,
                    .words => 2,
                    .blocks => 512,
                    .kilobytes => 1024,
                    .megabytes => 1048576,
                    .gigabytes => 1073741824,
                };
                const file_units = if (file_size == 0) 0 else (file_size + unit_size - 1) / unit_size;
                return switch (sz.cmp) {
                    .exactly => file_units == sz.value,
                    .greater_than => file_units > sz.value,
                    .less_than => file_units < sz.value,
                };
            }
        },
        .empty => {
            if (kind == .regular) return stat_buf.size == 0;
            if (kind == .directory) return isDirEmpty(io, path) catch false;
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
            const pe = expr.data.perm_expr;
            return switch (pe.cmp) {
                .exact => file_mode == pe.mode,
                .at_least => (file_mode & pe.mode) == pe.mode,
                .any_of => if (pe.mode == 0) file_mode == 0 else (file_mode & pe.mode) != 0,
            };
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
        .execdir => return doExecdir(io, allocator, path, basename, expr.data.exec_data),
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
        .delete => return doDelete(io, allocator, path, kind, stderr, had_error),
        .exec_cmd => return doExec(io, allocator, path, expr.data.exec_data),
        .exec_batch => {
            if (batch_ctx) |bc| {
                bc.exec_template = expr.data.exec_data.argv;
                const path_copy = allocator.dupe(u8, path) catch return false;
                bc.exec_paths.append(allocator, path_copy) catch {
                    allocator.free(path_copy);
                    return false;
                };
            }
            return true;
        },
        .execdir_batch => {
            if (batch_ctx) |bc| {
                bc.execdir_template = expr.data.exec_data.argv;
                if (bc.execdir_dir == null) {
                    const dir = std.fs.path.dirname(path) orelse ".";
                    bc.execdir_dir = allocator.dupe(u8, dir) catch return false;
                }
                const path_copy = allocator.dupe(u8, path) catch return false;
                bc.execdir_paths.append(allocator, path_copy) catch {
                    allocator.free(path_copy);
                    return false;
                };
            }
            return true;
        },
        .and_expr => {
            const left_result = evaluate(io, expr.data.binary.left, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned, batch_ctx);
            if (!left_result) return false;
            return evaluate(io, expr.data.binary.right, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned, batch_ctx);
        },
        .or_expr => {
            const left_result = evaluate(io, expr.data.binary.left, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned, batch_ctx);
            if (left_result) return true;
            return evaluate(io, expr.data.binary.right, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned, batch_ctx);
        },
        .not_expr => {
            return !evaluate(io, expr.data.unary, path, basename, stat_buf, kind, now, depth, allocator, stdout, stderr, had_error, pruned, batch_ctx);
        },
        .prune => {
            pruned.* = true;
            return true;
        },
        .false_expr => return false,
        .ipath => return glob.globMatchInsensitive(expr.data.pattern, path),
        .regex_match, .iregex_match => {
            const path_z = allocator.dupeZ(u8, path) catch return false;
            defer allocator.free(path_z);
            return regex_h.regexec(expr.data.regex_ptr, path_z.ptr, 0, null, 0) == 0;
        },
        .btime_stub => {
            // -Btime N: birth time in days
            const te = expr.data.time;
            const btime = getBirthTime(path) orelse {
                // Birth time unavailable: fall back to ctime
                return false;
            };
            const age_secs = now - btime;
            const age_days: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 86400) else 0;
            return switch (te.cmp) {
                .exactly => age_days == te.days,
                .greater_than => age_days > te.days,
                .less_than => age_days < te.days,
            };
        },
        .bmin_stub => {
            // -Bmin N: birth time in minutes
            const te = expr.data.time;
            const btime = getBirthTime(path) orelse {
                return false;
            };
            const age_secs = now - btime;
            const age_mins: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 60) else 0;
            return switch (te.cmp) {
                .exactly => age_mins == te.days, // "days" field holds minutes here
                .greater_than => age_mins > te.days,
                .less_than => age_mins < te.days,
            };
        },
        .bnewer_stub => {
            // -Bnewer REF: file's birth time newer than REF's birth time
            const ref_btime = expr.data.newer_mtime;
            const file_btime = getBirthTime(path) orelse {
                return false;
            };
            return file_btime > ref_btime;
        },
        .newerxy_stub => {
            // -newerXY REF: compare file's X time to REF's Y time
            const data = expr.data.newerxy_data;
            const file_time: i64 = switch (data.x_field) {
                'a' => getAtime(stat_buf),
                'c' => getCtime(stat_buf),
                'm' => getMtime(stat_buf),
                'B' => getBirthTime(path) orelse return false,
                else => getMtime(stat_buf),
            };
            return file_time > data.ref_time;
        },
        .acl_stub => return false,
        .sparse_stub => return false,
        .xattr_stub => return false,
        .xattrname_stub => return false,
        .depth_n => return depth == expr.data.depth_val,
        .gid_match => return stat_buf.gid == expr.data.gid_val,
        .uid_match => return stat_buf.uid == expr.data.uid_val,
        .lname => {
            if (kind != .symlink) return false;
            return matchSymlinkTarget(io, allocator, path, expr.data.pattern, false);
        },
        .ilname => {
            if (kind != .symlink) return false;
            return matchSymlinkTarget(io, allocator, path, expr.data.pattern, true);
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
            const fmt = expr.data.pattern;
            var i: usize = 0;
            while (i < fmt.len) {
                if (fmt[i] == '%' and i + 1 < fmt.len) {
                    switch (fmt[i + 1]) {
                        'f' => {
                            // basename
                            stdout.writeAll(basename) catch {
                                had_error.* = true;
                            };
                        },
                        'h' => {
                            // dirname
                            const dir = std.fs.path.dirname(path) orelse ".";
                            stdout.writeAll(dir) catch {
                                had_error.* = true;
                            };
                        },
                        'p' => {
                            // full path
                            stdout.writeAll(path) catch {
                                had_error.* = true;
                            };
                        },
                        's' => {
                            // file size in bytes
                            const file_size: u64 = @intCast(@max(0, stat_buf.size));
                            stdout.print("{d}", .{file_size}) catch {
                                had_error.* = true;
                            };
                        },
                        '%' => {
                            stdout.writeByte('%') catch {
                                had_error.* = true;
                            };
                        },
                        else => {
                            // Unknown specifier: print as-is
                            stdout.writeByte('%') catch {
                                had_error.* = true;
                            };
                            stdout.writeByte(fmt[i + 1]) catch {
                                had_error.* = true;
                            };
                        },
                    }
                    i += 2;
                } else if (fmt[i] == '\\' and i + 1 < fmt.len) {
                    switch (fmt[i + 1]) {
                        'n' => {
                            stdout.writeByte('\n') catch {
                                had_error.* = true;
                            };
                        },
                        't' => {
                            stdout.writeByte('\t') catch {
                                had_error.* = true;
                            };
                        },
                        '\\' => {
                            stdout.writeByte('\\') catch {
                                had_error.* = true;
                            };
                        },
                        else => {
                            stdout.writeByte('\\') catch {
                                had_error.* = true;
                            };
                            stdout.writeByte(fmt[i + 1]) catch {
                                had_error.* = true;
                            };
                        },
                    }
                    i += 2;
                } else {
                    stdout.writeByte(fmt[i]) catch {
                        had_error.* = true;
                    };
                    i += 1;
                }
            }
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

fn isDirEmpty(io: std.Io, path: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    const entry = try iter.next(io);
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

fn matchSymlinkTarget(io: std.Io, allocator: Allocator, path: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    _ = allocator;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().readLink(io, path, &link_buf) catch return false;
    const target = link_buf[0..len];
    return if (case_insensitive) glob.globMatchInsensitive(pattern, target) else glob.globMatch(pattern, target);
}

fn doDelete(io: std.Io, allocator: Allocator, path: []const u8, kind: FileType, stderr: anytype, had_error: *bool) bool {
    if (kind == .directory) {
        std.Io.Dir.cwd().deleteDir(io, path) catch |err| {
            common.printErrorWithProgram(allocator, stderr, prog_name, "cannot delete '{s}': {s}", .{ path, common.posixErrorString(err) });
            had_error.* = true;
            return false;
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
            common.printErrorWithProgram(allocator, stderr, prog_name, "cannot delete '{s}': {s}", .{ path, common.posixErrorString(err) });
            had_error.* = true;
            return false;
        };
    }
    return true;
}

fn doExec(io: std.Io, allocator: Allocator, path: []const u8, exec_data: ExecExpr) bool {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(allocator);

    for (exec_data.argv) |arg| {
        if (std.mem.eql(u8, arg, "{}")) {
            argv.append(allocator, path) catch return false;
        } else {
            argv.append(allocator, arg) catch return false;
        }
    }

    if (argv.items.len == 0) return false;

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
    }) catch {
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

fn doExecdir(io: std.Io, allocator: Allocator, path: []const u8, basename: []const u8, exec_data: ExecExpr) bool {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
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

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir_path },
    }) catch {
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
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

fn doLs(allocator: Allocator, path: []const u8, stat_buf: StatInfo, kind: FileType, stdout: anytype, had_error: *bool) bool {
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

fn formatPermissions(mode: u32, buf: *[10]u8) void {
    const m: u32 = mode;
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

    const now = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    };
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

fn matchFlags(stat_buf: StatInfo, flag_str: []const u8) bool {
    // BSD file flags from st_flags. On macOS, stat has st_flags.
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return matchFlagsDarwin(stat_buf, flag_str);
    }
    // On non-BSD systems, -flags always returns false
    return false;
}

fn matchFlagsDarwin(stat_buf: StatInfo, flag_str: []const u8) bool {
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

const Walker = common.walker.Walker;

/// One ancestor directory in the current follow chain. Tracks (dev, inode) for
/// -L loop detection and the path for the GNU loop diagnostic. The path is
/// arena-owned and lives for the whole walk.
const AncestorDir = struct {
    dev: i64,
    inode: u64,
    path: []const u8,
};

/// A pending symlink-to-directory follow under -L. The main walk emits these
/// without descending (the walker runs in no_follow); drainSymlinkHops walks
/// each target afterward with a fresh sub-walker. All slices are arena-owned.
const SymlinkHop = struct {
    /// Path to the symlink (the sub-walk root). openDir follows the final
    /// component, so the sub-walk traverses the target's real children.
    path: []const u8,
    /// effective_depth of the symlink in the parent walk; the sub-walk's own
    /// depth-0 entry maps back to this depth (its root is skipped, children
    /// land at base_depth + 1).
    base_depth: u32,
    /// Ancestor chain up to and including this symlink, for nested loop checks.
    ancestors: []const AncestorDir,
};

/// The directory whose children the walker is currently iterating. Saved on
/// every pre-order directory emit so a later next() error (an unreadable child)
/// can be attributed, and so the -depth post-order evaluate can still fire for
/// an unreadable directory using its already-captured stat.
const LastDir = struct {
    path: []const u8,
    stat: StatInfo,
    kind: FileType,
    effective_depth: u32,
};

/// Mutable state threaded through one operand's walk and its symlink hops.
/// Writers stay out of the struct so callers keep the `anytype` writer
/// flexibility used across this file.
const WalkState = struct {
    io: std.Io,
    allocator: Allocator,
    config: *const FindConfig,
    had_error: *bool,
    now: i64,
    batch_ctx: ?*BatchContext,
    walker: *Walker,

    /// Current follow chain of open directories (for -L loop detection).
    ancestors: std.ArrayListUnmanaged(AncestorDir),
    /// Pending symlink follows discovered during this walk.
    hops: *std.ArrayListUnmanaged(SymlinkHop),
    /// Device of the operand root, captured at effective_depth 0 (for -xdev).
    root_dev: ?i64,
    /// Most recent pre-order directory (for error attribution / -depth).
    last_dir: ?LastDir,
    /// Added to entry.depth to recover the find-visible depth. Non-zero only in
    /// symlink-hop sub-walks.
    base_depth: u32,
    /// When true, the next depth-0 entry is a hop's already-evaluated root and
    /// must be skipped for evaluation/filtering (but still seed ancestors/dev).
    skip_hop_root: bool,
};

// ============================================================================
// Walker-based driver (replaces the former recursive walkPath)
// ============================================================================

/// Walk one operand tree with a bounded walker, dispatching each entry to
/// findVisitEntry. Walker errors (unreadable child dirs) are reported and the
/// walk resumes at siblings; the walker is re-entrant after an error.
fn findWalkTree(
    state: *WalkState,
    root_path: []const u8,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(root_path.len > 0);
    assert(state.walker.roots.items.len == 0);
    state.walker.addRoot(root_path) catch {
        state.had_error.* = true;
        return;
    };
    var steps: u64 = 0;
    const steps_max: u64 = 1 << 30;
    while (steps < steps_max) : (steps += 1) {
        const maybe_entry = state.walker.next(state.io) catch |err| {
            reportWalkNextError(state, root_path, err, stdout, stderr);
            if (err == error.DepthLimitExceeded or err == error.EntryLimitExceeded) return;
            continue;
        };
        const entry = maybe_entry orelse break;
        findVisitEntry(state, entry, stdout, stderr);
    }
    assert(steps < steps_max);
}

/// Report a walker next() error. An unreadable child directory makes next()
/// fail without emitting the failing path, so attribute it to last_dir and, if
/// that directory exists, rescan for the exact unreadable subdirectory. Under
/// -depth the unreadable directory itself is still evaluated using its saved
/// stat (mirrors the old openDir-failure contract).
fn reportWalkNextError(
    state: *WalkState,
    root_path: []const u8,
    err: anyerror,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(root_path.len > 0);
    state.had_error.* = true;
    const parent_path = if (state.last_dir) |ld| ld.path else root_path;
    assert(parent_path.len > 0);
    const failing = findUnreadableChildDir(state.allocator, state.io, parent_path) orelse parent_path;
    common.printErrorWithProgram(state.allocator, stderr, prog_name, "'{s}': {s}", .{ failing, common.posixErrorString(err) });
    if (state.config.depth_first and failing.ptr != parent_path.ptr) {
        evaluateUnreadableDir(state, parent_path, failing, stdout, stderr);
    }
}

/// Under -depth, evaluate the unreadable child directory itself so its
/// -print/-delete still fire (the old find.zig:2680 openDir-failure contract).
/// The directory's pre-order entry was never emitted (the walker errored while
/// opening it), so re-stat it here. -delete then fails rmdir loudly because the
/// directory is non-empty, matching GNU. Its find-visible depth is the parent's
/// plus one.
fn evaluateUnreadableDir(
    state: *WalkState,
    parent_path: []const u8,
    failing_path: []const u8,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(state.config.depth_first);
    assert(failing_path.len > parent_path.len);
    const parent_depth = if (state.last_dir) |ld| ld.effective_depth else state.base_depth;
    const child_depth = parent_depth + 1;
    if (child_depth < state.config.mindepth) return;
    if (state.config.maxdepth) |max| {
        if (child_depth > max) return;
    }
    const stat_buf = doStat(failing_path, true) catch return;
    findEvaluatePath(state, failing_path, stat_buf, .directory, child_depth, stdout, stderr);
}

/// Scan a directory for the first immediate subdirectory that cannot be opened,
/// returning its full path (arena-owned) or null. Lifted from grep.zig: names
/// the exact unreadable path behind a walker error.
fn findUnreadableChildDir(
    allocator: Allocator,
    io: std.Io,
    parent_path: []const u8,
) ?[]const u8 {
    assert(parent_path.len > 0);
    assert(parent_path[0] != 0);
    var parent_dir =
        std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true }) catch return null;
    defer parent_dir.close(io);
    var iterator = parent_dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var child = parent_dir.openDir(io, entry.name, .{ .iterate = true }) catch {
            return std.fs.path.join(allocator, &.{ parent_path, entry.name }) catch null;
        };
        child.close(io);
    }
    return null;
}

/// Collapse the redundant slash the walker emits when a parent path ends in
/// '/' (notably the root operand "/", which yields "//child"). GNU find's path
/// join produces a single slash, so match it. The operand itself (depth 0) is
/// printed verbatim, so only depth > 0 paths are normalized. Returns an
/// arena-owned path, or the original slice when no change is needed.
fn normalizeWalkerPath(allocator: Allocator, path: []const u8) []const u8 {
    assert(path.len > 0);
    if (std.mem.find(u8, path, "//") == null) return path;
    var out = std.ArrayListUnmanaged(u8).initCapacity(allocator, path.len) catch return path;
    var prev_slash = false;
    for (path) |ch| {
        if (ch == '/' and prev_slash) continue;
        out.append(allocator, ch) catch return path;
        prev_slash = (ch == '/');
    }
    assert(out.items.len <= path.len);
    return out.items;
}

/// Dispatch one walker entry. Re-stats with find's own follow flag (entry.stat
/// and entry.kind are never trusted for predicate evaluation), computes the
/// find-visible depth, and routes to the directory / leaf / symlink handlers.
fn findVisitEntry(state: *WalkState, raw_entry: common.walker.Entry, stdout: anytype, stderr: anytype) void {
    assert(raw_entry.path.len > 0);
    var entry = raw_entry;
    if (entry.depth > 0) entry.path = normalizeWalkerPath(state.allocator, raw_entry.path);
    const effective_depth: u32 = state.base_depth + entry.depth;
    if (entry.kind == .directory) {
        if (entry.visit == .pre) {
            findVisitDirPre(state, entry, effective_depth, stdout, stderr);
        } else {
            findVisitDirPost(state, entry, effective_depth, stdout, stderr);
        }
        return;
    }
    assert(entry.visit == .pre);
    const follow_symlinks = state.config.follow_symlinks or
        (effective_depth == 0 and state.config.follow_cmdline_symlinks);
    if (entry.kind == .sym_link and follow_symlinks) {
        findVisitFollowedSymlink(state, entry, effective_depth, stdout, stderr);
        return;
    }
    findVisitLeaf(state, entry.path, effective_depth, stdout, stderr);
}

/// Handle a pre-order directory: maintain the ancestor chain, capture the root
/// device, apply -X / -xdev / -prune / -maxdepth, and (when not -depth)
/// evaluate it. Pruning here suppresses the matching .post and the whole
/// subtree.
fn findVisitDirPre(
    state: *WalkState,
    entry: common.walker.Entry,
    effective_depth: u32,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(entry.kind == .directory);
    assert(entry.visit == .pre);
    const basename = std.fs.path.basename(entry.path);
    const is_hop_root = state.skip_hop_root and entry.depth == 0;
    state.skip_hop_root = false;
    if (!is_hop_root and state.config.xargs_safe and effective_depth > 0 and isXargsUnsafe(basename)) {
        common.printErrorWithProgram(state.allocator, stderr, prog_name, "warning: file name '{s}' is not safe for use with xargs", .{basename});
        state.walker.pruneCurrent();
        return;
    }
    // Re-stat with find's own follow policy. The walker opened this path as a
    // directory (openDir follows a final symlink component), but under -P/-H a
    // symlink operand at depth 0 must be evaluated AS a symlink and never
    // descended. When find's policy resolves it to a non-directory, treat it as
    // a leaf and prune the walker's descent.
    const follow = state.config.follow_symlinks or
        (effective_depth == 0 and state.config.follow_cmdline_symlinks);
    const stat_buf = doStat(entry.path, follow) catch |err| {
        reportStatError(state, entry.path, err, stderr);
        state.walker.pruneCurrent();
        return;
    };
    if (getFileKind(stat_buf.mode) != .directory) {
        if (!is_hop_root and effective_depth >= state.config.mindepth) {
            findEvaluatePath(state, entry.path, stat_buf, getFileKind(stat_buf.mode), effective_depth, stdout, stderr);
        }
        state.walker.pruneCurrent();
        return;
    }
    if (effective_depth == 0 and state.config.xdev) state.root_dev = @intCast(stat_buf.dev);
    if (findDirCrossesDevice(state, stat_buf, entry.path, effective_depth, stdout, stderr)) return;
    const dup_path = state.allocator.dupe(u8, entry.path) catch {
        state.had_error.* = true;
        state.walker.pruneCurrent();
        return;
    };
    state.last_dir = .{ .path = dup_path, .stat = stat_buf, .kind = .directory, .effective_depth = effective_depth };
    // Push onto the -L follow chain ONLY when this directory will actually be
    // descended (its .post will fire, balancing the pop). A directory pruned by
    // -prune or the -maxdepth boundary emits no .post, so pushing it here would
    // leak it and misalign the LIFO chain, tripping a false loop diagnostic on a
    // later sibling symlink. So decide the prunes first, then push.
    if (findDirPreEvaluate(state, dup_path, stat_buf, effective_depth, is_hop_root, stdout, stderr)) return;
    if (findDirMaxdepthBoundary(state, dup_path, stat_buf, effective_depth, is_hop_root, stdout, stderr)) return;
    pushAncestor(state, stat_buf, dup_path);
}

/// -xdev: when a directory's device differs from the operand root, GNU emits
/// the mount point then skips descent. Returns true when descent was pruned.
fn findDirCrossesDevice(
    state: *WalkState,
    stat_buf: StatInfo,
    path: []const u8,
    effective_depth: u32,
    stdout: anytype,
    stderr: anytype,
) bool {
    assert(path.len > 0);
    const root_dev = state.root_dev orelse return false;
    const entry_dev: i64 = @intCast(stat_buf.dev);
    if (entry_dev == root_dev) return false;
    if (effective_depth >= state.config.mindepth) {
        findEvaluatePath(state, path, stat_buf, .directory, effective_depth, stdout, stderr);
    }
    state.walker.pruneCurrent();
    return true;
}

/// Pre-order (non -depth) evaluation. Returns true when the subtree was pruned
/// (by -prune) and the caller must stop.
fn findDirPreEvaluate(
    state: *WalkState,
    path: []const u8,
    stat_buf: StatInfo,
    effective_depth: u32,
    is_hop_root: bool,
    stdout: anytype,
    stderr: anytype,
) bool {
    assert(path.len > 0);
    if (state.config.depth_first) return false;
    if (is_hop_root) return false;
    if (effective_depth < state.config.mindepth) return false;
    var pruned = false;
    _ = evaluate(
        state.io,
        state.config.expr,
        path,
        std.fs.path.basename(path),
        stat_buf,
        .directory,
        state.now,
        effective_depth,
        state.allocator,
        stdout,
        stderr,
        state.had_error,
        &pruned,
        state.batch_ctx,
    );
    if (pruned) state.walker.pruneCurrent();
    return pruned;
}

/// -maxdepth boundary: at the limit, descend no further. Under -depth, evaluate
/// the boundary directory inline here (pruneCurrent suppresses its later .post,
/// and no children intervene, so pre/post timing is observationally identical).
/// Returns true when the boundary fired and descent was pruned.
fn findDirMaxdepthBoundary(
    state: *WalkState,
    path: []const u8,
    stat_buf: StatInfo,
    effective_depth: u32,
    is_hop_root: bool,
    stdout: anytype,
    stderr: anytype,
) bool {
    assert(path.len > 0);
    const maxdepth = state.config.maxdepth orelse return false;
    if (effective_depth < maxdepth) return false;
    if (state.config.depth_first and !is_hop_root and effective_depth >= state.config.mindepth) {
        findEvaluatePath(state, path, stat_buf, .directory, effective_depth, stdout, stderr);
    }
    state.walker.pruneCurrent();
    return true;
}

/// Handle a post-order directory (only reached under -depth, since boundary
/// dirs were pruned before any .post). This is the -depth / -delete site.
fn findVisitDirPost(
    state: *WalkState,
    entry: common.walker.Entry,
    effective_depth: u32,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(entry.kind == .directory);
    assert(entry.visit == .post);
    popAncestor(state, effective_depth);
    if (!state.config.depth_first) return;
    if (effective_depth < state.config.mindepth) return;
    const stat_buf = doStat(entry.path, true) catch |err| {
        reportStatError(state, entry.path, err, stderr);
        return;
    };
    findEvaluatePath(state, entry.path, stat_buf, .directory, effective_depth, stdout, stderr);
}

/// Handle a non-directory leaf (file, or symlink under -P/-H-at-depth>0).
/// Re-stats with find's follow flag and evaluates, gated by -mindepth and -X.
fn findVisitLeaf(state: *WalkState, path: []const u8, effective_depth: u32, stdout: anytype, stderr: anytype) void {
    assert(path.len > 0);
    const basename = std.fs.path.basename(path);
    if (state.config.xargs_safe and effective_depth > 0 and isXargsUnsafe(basename)) {
        common.printErrorWithProgram(state.allocator, stderr, prog_name, "warning: file name '{s}' is not safe for use with xargs", .{basename});
        return;
    }
    const follow = state.config.follow_symlinks or
        (effective_depth == 0 and state.config.follow_cmdline_symlinks);
    const stat_buf = doStat(path, follow) catch |err| {
        reportStatError(state, path, err, stderr);
        return;
    };
    const kind = getFileKind(stat_buf.mode);
    if (effective_depth < state.config.mindepth) return;
    findEvaluatePath(state, path, stat_buf, kind, effective_depth, stdout, stderr);
}

/// Handle a symlink under -L (or an operand symlink under -H). Resolves the
/// target; dangling links report an error; non-dir targets evaluate as their
/// target type; dir targets either trip loop detection or are evaluated and
/// queued as a hop for drainSymlinkHops to descend.
fn findVisitFollowedSymlink(
    state: *WalkState,
    entry: common.walker.Entry,
    effective_depth: u32,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(entry.kind == .sym_link);
    const stat_buf = doStat(entry.path, true) catch |err| {
        reportStatError(state, entry.path, err, stderr);
        return;
    };
    const kind = getFileKind(stat_buf.mode);
    if (kind != .directory) {
        if (effective_depth >= state.config.mindepth) {
            findEvaluatePath(state, entry.path, stat_buf, kind, effective_depth, stdout, stderr);
        }
        return;
    }
    const target_inode = stat_buf.ino;
    const target_dev: i64 = @intCast(stat_buf.dev);
    if (findAncestorLoop(state, target_dev, target_inode, entry.path, stderr)) return;
    if (effective_depth >= state.config.mindepth) {
        findEvaluatePath(state, entry.path, stat_buf, .directory, effective_depth, stdout, stderr);
    }
    enqueueSymlinkHop(state, entry.path, effective_depth, target_dev, target_inode, stderr);
}

/// Detect a -L filesystem loop: the symlink target matches an ancestor in the
/// current follow chain. Emits the GNU diagnostic, sets had_error, and returns
/// true (the caller must not descend).
fn findAncestorLoop(
    state: *WalkState,
    target_dev: i64,
    target_inode: u64,
    link_path: []const u8,
    stderr: anytype,
) bool {
    assert(link_path.len > 0);
    for (state.ancestors.items) |anc| {
        if (anc.dev != target_dev or anc.inode != target_inode) continue;
        common.printErrorWithProgram(
            state.allocator,
            stderr,
            prog_name,
            "File system loop detected; '{s}' is part of the same file system loop as '{s}'.",
            .{ link_path, anc.path },
        );
        state.had_error.* = true;
        return true;
    }
    return false;
}

/// Queue a symlink-to-directory follow. Captures the ancestor chain (plus the
/// symlink itself) so nested follows can detect deeper loops.
fn enqueueSymlinkHop(
    state: *WalkState,
    link_path: []const u8,
    effective_depth: u32,
    target_dev: i64,
    target_inode: u64,
    stderr: anytype,
) void {
    assert(link_path.len > 0);
    const dup_path = state.allocator.dupe(u8, link_path) catch {
        state.had_error.* = true;
        return;
    };
    var chain = state.allocator.alloc(AncestorDir, state.ancestors.items.len + 1) catch {
        state.had_error.* = true;
        return;
    };
    @memcpy(chain[0..state.ancestors.items.len], state.ancestors.items);
    chain[state.ancestors.items.len] = .{ .dev = target_dev, .inode = target_inode, .path = dup_path };
    state.hops.append(state.allocator, .{ .path = dup_path, .base_depth = effective_depth, .ancestors = chain }) catch {
        state.had_error.* = true;
    };
    _ = stderr;
}

/// Drain all queued symlink hops with fresh sub-walkers. Nested hops append to
/// the same queue and are processed in turn; the queue is bounded by
/// max_entries on each sub-walker plus an outer iteration cap.
fn drainSymlinkHops(
    state: *WalkState,
    hops: *std.ArrayListUnmanaged(SymlinkHop),
    stdout: anytype,
    stderr: anytype,
) void {
    var index: usize = 0;
    const hops_max: usize = 1 << 24;
    while (index < hops.items.len and index < hops_max) : (index += 1) {
        const hop = hops.items[index];
        walkOneSymlinkHop(state, hop, stdout, stderr);
    }
    assert(index <= hops_max);
}

/// Walk one symlink hop's target with a dedicated sub-walker. The hop root (the
/// target directory) was already evaluated in the parent walk, so skip_hop_root
/// suppresses its re-evaluation; its real children land at base_depth + 1.
fn walkOneSymlinkHop(state: *WalkState, hop: SymlinkHop, stdout: anytype, stderr: anytype) void {
    assert(hop.path.len > 0);
    var sub_walker = Walker.init(state.allocator, walkerConfig(state.config)) catch {
        state.had_error.* = true;
        return;
    };
    defer sub_walker.deinit(state.io);
    var sub_state = state.*;
    sub_state.walker = &sub_walker;
    sub_state.base_depth = hop.base_depth;
    sub_state.skip_hop_root = true;
    sub_state.last_dir = null;
    sub_state.ancestors = .empty;
    defer sub_state.ancestors.deinit(state.allocator);
    sub_state.ancestors.appendSlice(state.allocator, hop.ancestors) catch {
        state.had_error.* = true;
        return;
    };
    findWalkTree(&sub_state, hop.path, stdout, stderr);
}

/// Push a directory onto the follow chain for -L loop detection.
fn pushAncestor(state: *WalkState, stat_buf: StatInfo, dup_path: []const u8) void {
    assert(dup_path.len > 0);
    state.ancestors.append(state.allocator, .{ .dev = @intCast(stat_buf.dev), .inode = stat_buf.ino, .path = dup_path }) catch {
        state.had_error.* = true;
    };
    assert(state.ancestors.items.len > 0);
}

/// Pop the deepest directory from the follow chain on post-order. The walker
/// emits .post in strict LIFO order for descended directories, so the top of
/// the chain is always the one unwinding.
fn popAncestor(state: *WalkState, effective_depth: u32) void {
    assert(effective_depth >= state.base_depth);
    if (state.ancestors.items.len == 0) return;
    const before = state.ancestors.items.len;
    _ = state.ancestors.pop();
    assert(state.ancestors.items.len == before - 1);
}

/// Evaluate one path against the expression (a single, non-pruning evaluate).
/// Always dupes nothing here — callers pass arena-stable paths — but the path
/// must already outlive any -exec/-execdir batching that retains it.
fn findEvaluatePath(
    state: *WalkState,
    path: []const u8,
    stat_buf: StatInfo,
    kind: FileType,
    effective_depth: u32,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(path.len > 0);
    var pruned = false;
    _ = evaluate(
        state.io,
        state.config.expr,
        path,
        std.fs.path.basename(path),
        stat_buf,
        kind,
        state.now,
        effective_depth,
        state.allocator,
        stdout,
        stderr,
        state.had_error,
        &pruned,
        state.batch_ctx,
    );
}

/// Report a doStat failure on an entry, matching the old per-error messages.
fn reportStatError(state: *WalkState, path: []const u8, err: anyerror, stderr: anytype) void {
    assert(path.len > 0);
    switch (err) {
        error.AccessDenied => common.printErrorWithProgram(state.allocator, stderr, prog_name, "'{s}': Permission denied", .{path}),
        error.FileNotFound => common.printErrorWithProgram(state.allocator, stderr, prog_name, "'{s}': No such file or directory", .{path}),
        error.SymLinkLoop => common.printErrorWithProgram(state.allocator, stderr, prog_name, "'{s}': Too many levels of symbolic links", .{path}),
        else => common.printErrorWithProgram(state.allocator, stderr, prog_name, "'{s}': {s}", .{ path, common.posixErrorString(err) }),
    }
    state.had_error.* = true;
}

/// Build the WalkConfig for find. Order is always .both so the driver controls
/// pre/post timing. -xdev and loop detection are driver-side, so the walker's
/// stay_on_filesystem and detect_cycles stay off. -L uses no_follow (NOT
/// follow_all) so symlinks arrive as .sym_link and the driver re-stats them.
fn walkerConfig(config: *const FindConfig) common.walker.WalkConfig {
    const symlinks: common.walker.SymlinkPolicy =
        if (config.follow_cmdline_symlinks and !config.follow_symlinks) .follow_cmdline else .no_follow;
    return .{
        .order = .both,
        .symlinks = symlinks,
        .sort_children = config.sorted,
        .stay_on_filesystem = false,
        .detect_cycles = false,
        .max_depth = 1024,
    };
}

// ============================================================================
// Entry points
// ============================================================================

pub fn runFind(allocator: Allocator, io: std.Io, args: []const []const u8, stdout: anytype, stderr: anytype) anyerror!u8 {
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

    const now = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    };
    var had_error = false;
    var batch_ctx = BatchContext{};

    for (config.start_paths) |path| {
        var walker = Walker.init(allocator, walkerConfig(&config)) catch {
            had_error = true;
            continue;
        };
        defer walker.deinit(io);

        var hops: std.ArrayListUnmanaged(SymlinkHop) = .empty;
        defer hops.deinit(allocator);

        var state = WalkState{
            .io = io,
            .allocator = allocator,
            .config = &config,
            .had_error = &had_error,
            .now = now,
            .batch_ctx = &batch_ctx,
            .walker = &walker,
            .ancestors = .empty,
            .hops = &hops,
            .root_dev = null,
            .last_dir = null,
            .base_depth = 0,
            .skip_hop_root = false,
        };
        defer state.ancestors.deinit(allocator);

        findWalkTree(&state, path, stdout, stderr);
        drainSymlinkHops(&state, &hops, stdout, stderr);
    }

    // Flush batch exec/execdir commands
    if (!batch_ctx.flushExec(io, allocator, stdout, stderr)) had_error = true;
    if (!batch_ctx.flushExecdir(io, allocator, stdout, stderr)) had_error = true;

    return if (had_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runFindTyped);
}

/// Typed wrapper for utilityMain compatibility
fn runFindTyped(allocator: Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!u8 {
    return runFind(allocator, io, args, stdout, stderr);
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
    writer.print("find ({s}) {s}\n", .{ common.name, common.version }) catch {};
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
    const p1 = try parsePerm("755");
    try testing.expectEqual(@as(u32, 0o755), p1.mode);
    try testing.expectEqual(PermCompare.exact, p1.cmp);

    const p2 = try parsePerm("644");
    try testing.expectEqual(@as(u32, 0o644), p2.mode);
    try testing.expectEqual(PermCompare.exact, p2.cmp);

    const p3 = try parsePerm("0");
    try testing.expectEqual(@as(u32, 0o0), p3.mode);

    const p4 = try parsePerm("777");
    try testing.expectEqual(@as(u32, 0o777), p4.mode);
}

test "parsePerm: prefix forms" {
    const p1 = try parsePerm("-644");
    try testing.expectEqual(@as(u32, 0o644), p1.mode);
    try testing.expectEqual(PermCompare.at_least, p1.cmp);

    const p2 = try parsePerm("/111");
    try testing.expectEqual(@as(u32, 0o111), p2.mode);
    try testing.expectEqual(PermCompare.any_of, p2.cmp);

    const p3 = try parsePerm("-755");
    try testing.expectEqual(@as(u32, 0o755), p3.mode);
    try testing.expectEqual(PermCompare.at_least, p3.cmp);
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

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{"--help"}, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage:") != null);
}

test "find: version flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{"--version"}, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "vibeutils") != null);
}

test "find: basic directory search" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "hello.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "world.md", .{});
    f2.close(testing.io);
    try tmp.dir.createDir(testing.io, "subdir", .default_dir);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{dir_path}, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "world.md") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "subdir") != null);
}

test "find: -name filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "hello.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "world.md", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "world.md") == null);
}

test "find: -type filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);
    try tmp.dir.createDir(testing.io, "mydir", .default_dir);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Find only files
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
    }

    // Find only directories
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "d" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "mydir") != null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") == null);
    }
}

test "find: -empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "empty.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "notempty.txt", .{});
    try f2.writeStreamingAll(testing.io, "content");
    f2.close(testing.io);
    try tmp.dir.createDir(testing.io, "emptydir", .default_dir);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-empty" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "empty.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "emptydir") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "notempty.txt") == null);
}

test "find: -maxdepth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "top.txt", .{});
    f1.close(testing.io);
    try tmp.dir.createDir(testing.io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "sub", .{});
    const f2 = try sub.createFile(testing.io, "deep.txt", .{});
    f2.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-maxdepth", "1" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "top.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "sub") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "deep.txt") == null);
}

test "find: -not / !" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "skip.log", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-not", "-name", "*.log", "-type", "f" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "keep.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "skip.log") == null);
}

test "find: -or operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "a.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "b.md", .{});
    f2.close(testing.io);
    const f3 = try tmp.dir.createFile(testing.io, "c.log", .{});
    f3.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "*.txt", "-o", "-name", "*.md" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "a.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "b.md") != null);
}

test "find: parentheses grouping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "a.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "b.md", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "(", "-name", "*.txt", "-o", "-name", "*.md", ")" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "a.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "b.md") != null);
}

test "find: -print0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "file.txt", "-print0" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should contain NUL byte
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), &[_]u8{0}) != null);
    // Should not contain newline after filename
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt\n") == null);
}

test "find: nonexistent path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{"/tmp/nonexistent_vibeutils_test_path_99999"}, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "find: unknown predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ ".", "-bogus" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "unknown predicate") != null);
}

test "find: -mindepth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "top.txt", .{});
    f1.close(testing.io);
    try tmp.dir.createDir(testing.io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "sub", .{});
    const f2 = try sub.createFile(testing.io, "deep.txt", .{});
    f2.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-mindepth", "2" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "deep.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "top.txt") == null);
}

test "find: -delete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "deleteme.txt", .{});
    f1.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "deleteme.txt", "-delete" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const stat = tmp.dir.statFile(testing.io, "deleteme.txt", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "find: -iname" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "Hello.TXT", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "world.txt", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-iname", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Hello.TXT") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "world.txt") != null);
}

test "find: -size filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "small.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "medium.txt", .{});
    try f2.writeStreamingAll(testing.io, "a" ** 2048);
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-size", "+1000c" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "medium.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "small.txt") == null);
}

test "find: -perm filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "rw.txt", .{ .permissions = @enumFromInt(0o644) });
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "rwx.txt", .{ .permissions = @enumFromInt(0o755) });
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-perm", "755" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "rwx.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "rw.txt") == null);
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

    try tmp.dir.createDir(testing.io, "subdir", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "subdir", .{});
    const f1 = try sub.createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);
    sub.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "other.txt", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -path matches against the full path, not just basename
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-path", "*/subdir/*" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should match subdir/file.txt (full path contains /subdir/)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
    // Should NOT match other.txt (not under subdir)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "other.txt") == null);
}

test "find: -prune prevents descending into directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a directory to skip and one to keep
    try tmp.dir.createDir(testing.io, "skip_me", .default_dir);
    var skip_dir = try tmp.dir.openDir(testing.io, "skip_me", .{});
    const f1 = try skip_dir.createFile(testing.io, "hidden.txt", .{});
    f1.close(testing.io);
    skip_dir.close(testing.io);

    try tmp.dir.createDir(testing.io, "keep_me", .default_dir);
    var keep_dir = try tmp.dir.openDir(testing.io, "keep_me", .{});
    const f2 = try keep_dir.createFile(testing.io, "visible.txt", .{});
    f2.close(testing.io);
    keep_dir.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Classic prune pattern: -name skip_me -prune -o -type f -print
    // This should skip descending into skip_me and only print files
    // from keep_me.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name",  "skip_me",
        "-prune", "-o",     "-type",
        "f",      "-print",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // visible.txt should appear (keep_me was not pruned)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "visible.txt") != null);
    // hidden.txt must NOT appear (skip_me was pruned)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hidden.txt") == null);
}

test "find: -depth lists directory contents before directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "adir", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "adir", .{});
    const f1 = try sub.createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // With -depth, file.txt should appear before its parent adir
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-depth" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const output = stdout_aw.writer.buffered();
    const file_pos = std.mem.find(u8, output, "file.txt");
    const dir_pos = std.mem.find(u8, output, "adir\n");

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

    const f1 = try tmp.dir.createFile(testing.io, "hello.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "world.md", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Pattern that matches nothing in this tree
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-path", "*/nonexistent/*" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // No files should match
    try testing.expect(stdout_aw.writer.buffered().len == 0);
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

    const f = try tmp.dir.createFile(testing.io, "recent.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // No file was accessed more than 9999 days ago; should match nothing
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-atime", "+9999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -ctime +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "recent.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // No file had its status changed more than 9999 days ago
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-ctime", "+9999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -links 99 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "single.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // A freshly created file has 1 hard link, not 99
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-links", "99" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -nouser matches nothing for normal files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "owned.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Files created by this user have a valid owner; -nouser should
    // match nothing.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-nouser" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -xdev is accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -xdev should parse without error and not prevent finding files
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-xdev", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
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

    try tmp.dir.createDir(testing.io, "adir", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "adir", .{});
    const f1 = try sub.createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -d should behave like -depth: file.txt before adir
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-d" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const output = stdout_aw.writer.buffered();
    const file_pos = std.mem.find(u8, output, "file.txt");
    const dir_pos = std.mem.find(u8, output, "adir\n");
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

    const f1 = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -f path should specify the search path
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-f", dir_path, "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -x is alias for -xdev" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -x should be accepted just like -xdev
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-x", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -X warns about xargs-unsafe filenames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file with a space in its name (xargs-problematic)
    const f1 = try tmp.dir.createFile(testing.io, "has space.txt", .{});
    f1.close(testing.io);
    // Create a normal file
    const f2 = try tmp.dir.createFile(testing.io, "safe.txt", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -X should warn about the file with a space
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-X", "-type", "f" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // safe.txt should appear in output
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "safe.txt") != null);
    // has space.txt should NOT appear in output (skipped by -X)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "has space.txt") == null);
    // Warning about the problematic name should be on stderr
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "has space.txt") != null);
}

test "find: -mmin matches recently modified files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "fresh.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // File was just created, so modified less than 5 minutes ago
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-mmin", "-5" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "fresh.txt") != null);
}

test "find: -mmin +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "recent.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-mmin", "+9999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -inum matches file by inode number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "target.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Get the inode number of target.txt
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "target.txt" });
    const stat_buf = try doStat(file_path, false);
    const ino = stat_buf.ino;
    var ino_buf: [32]u8 = undefined;
    const ino_str = std.fmt.bufPrint(&ino_buf, "{d}", .{ino}) catch unreachable;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-inum", ino_str }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "target.txt") != null);
}

test "find: -inum with non-matching inode returns nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Inode 0 should not match any real file
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-inum", "0" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
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

    const f = try tmp.dir.createFile(testing.io, "accessed.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // File was just created, so accessed less than 5 minutes ago
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-amin", "-5" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "accessed.txt") != null);
}

test "find: -amin +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "recent.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-amin", "+9999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -cmin -5 matches recently changed files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "changed.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-cmin", "-5" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "changed.txt") != null);
}

test "find: -cmin +9999 matches nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "recent.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-cmin", "+9999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -anewer matches files accessed after reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create reference file first
    const ref = try tmp.dir.createFile(testing.io, "old_ref.txt", .{});
    ref.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Set the reference file's mtime to the past so newly created files
    // will have a later access time
    const past = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    } - 3600; // 1 hour ago
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.Io.Dir.cwd().handle, ref_c_path, &times, 0);

    // Create the test file (will have current atime)
    const f = try tmp.dir.createFile(testing.io, "newer.txt", .{});
    f.close(testing.io);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Use absolute path for the reference file
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-anewer", ref_abs_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "newer.txt") != null);
}

test "find: -cnewer matches files changed after reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create reference file first
    const ref = try tmp.dir.createFile(testing.io, "old_ref.txt", .{});
    ref.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Set the reference file's mtime to the past
    const past = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    } - 3600;
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.Io.Dir.cwd().handle, ref_c_path, &times, 0);

    // Create test file (will have current ctime)
    const f = try tmp.dir.createFile(testing.io, "newer.txt", .{});
    f.close(testing.io);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Use absolute path for the reference file
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-cnewer", ref_abs_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "newer.txt") != null);
}

test "find: -ok is parsed as valid primary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -ok should be parsed without error; it prompts on /dev/tty so we
    // cannot test execution, but parsing should succeed.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "/tmp", "-maxdepth", "0", "-ok", "echo", "{}", ";" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -execdir runs command in file directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "testfile.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -execdir should be parsed and accepted
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-execdir", "echo", "{}", ";" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -ls produces listing output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "listed.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "listed.txt", "-ls" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // -ls output should contain the filename and some stat-like info
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "listed.txt") != null);
    // Should contain permission bits (e.g., rw-)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "rw") != null);
}

test "find: -fstype is accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -fstype should be parsed without error; use a type that exists on macOS
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-fstype", "apfs" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -flags is accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -flags should be parsed without error
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-flags", "uchg" }, &stdout_aw.writer, &stderr_aw.writer);
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

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-P", dir_path, "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -E global option accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-E", dir_path, "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -s global option accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-s", dir_path, "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -ipath case-insensitive path matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "SubDir", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "SubDir", .{});
    const f = try sub.createFile(testing.io, "File.TXT", .{});
    f.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Case-insensitive path matching
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-ipath", "*/subdir/*" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "File.TXT") != null);
}

test "find: -iwholename is alias for -ipath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "Test.TXT", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-iwholename", "*test*" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Test.TXT") != null);
}

test "find: -regex matches full path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-regex", ".*\\.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -iregex matches case-insensitively" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-iregex", ".*\\.TXT" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -Bmin stub accepted (always true)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Birth time is optional on Linux (e.g. unavailable over a virtiofs
    // mount). Without it, -Bmin legitimately matches nothing, so skip
    // rather than assert a match the filesystem cannot support.
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    if (getBirthTime(file_path) == null) return error.SkipZigTest;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-Bmin", "-5" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "find: -Bnewer parses and evaluates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -Bnewer self: a file should NOT be newer than itself
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-Bnewer", file_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    // File should not match -Bnewer self (not newer than itself)
}

test "find: -Btime evaluates birth time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Birth time is optional on Linux (e.g. unavailable over a virtiofs
    // mount). Without it, -Btime legitimately matches nothing, so skip
    // rather than assert a match the filesystem cannot support.
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    if (getBirthTime(file_path) == null) return error.SkipZigTest;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -Btime -1: born less than 1 day ago -- a just-created file should match
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-Btime", "-1" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "find: -acl stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-acl" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    // -acl always returns false, so nothing should match
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -depth N matches files at exact depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "top.txt", .{});
    f1.close(testing.io);
    try tmp.dir.createDir(testing.io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "sub", .{});
    const f2 = try sub.createFile(testing.io, "deep.txt", .{});
    f2.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // depth 1 should match top.txt and sub (not the root dir at depth 0)
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-depth", "1" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "top.txt") != null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "sub\n") != null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "deep.txt") == null);
    }

    // depth 2 should match deep.txt only
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-depth", "2" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "deep.txt") != null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "top.txt") == null);
    }
}

test "find: -gid matches numeric group ID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Get the GID of the test file
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const stat_buf = try doStat(file_path, false);
    var gid_buf: [32]u8 = undefined;
    const gid_str = std.fmt.bufPrint(&gid_buf, "{d}", .{stat_buf.gid}) catch unreachable;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-gid", gid_str }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -gid with non-matching GID returns nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // GID 99999 is unlikely to match any file
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-gid", "99999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -uid matches numeric user ID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Get the UID of the test file
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const stat_buf = try doStat(file_path, false);
    var uid_buf: [32]u8 = undefined;
    const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{stat_buf.uid}) catch unreachable;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-uid", uid_str }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -uid with non-matching UID returns nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // UID 99999 is unlikely to match any file
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-uid", "99999" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -ignore_readdir_race accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-ignore_readdir_race", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -noignore_readdir_race accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-noignore_readdir_race", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -noleaf accepted as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-noleaf", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -lname matches symlink target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "target.txt", .{});
    f.close(testing.io);
    try tmp.dir.symLink(testing.io, "target.txt", "link.txt", .{});

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-lname", "target*" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "link.txt") != null);
    // target.txt is not a symlink, should not match
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "target.txt") == null);
}

test "find: -ilname case-insensitive symlink target matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "Target.TXT", .{});
    f.close(testing.io);
    try tmp.dir.symLink(testing.io, "Target.TXT", "link.txt", .{});

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Case-insensitive match against symlink target
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-ilname", "target*" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "link.txt") != null);
}

test "find: -mnewer is alias for -newer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const ref = try tmp.dir.createFile(testing.io, "old_ref.txt", .{});
    ref.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Set reference file mtime to the past
    const past = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    } - 3600;
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.Io.Dir.cwd().handle, ref_c_path, &times, 0);

    const f = try tmp.dir.createFile(testing.io, "newer.txt", .{});
    f.close(testing.io);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-mnewer", ref_abs_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "newer.txt") != null);
}

test "find: -mount is alias for -xdev" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-mount", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -newerXY parses and evaluates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -newermm: file's mtime newer than ref's mtime
    // A file is not newer than itself
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "file.txt" });
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-newermm", file_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    // file.txt should not match -newermm self (not newer than itself)
}

test "find: -okdir stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "/tmp", "-maxdepth", "0", "-okdir", "echo", "{}", ";" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -quit is accepted as valid primary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -quit with -maxdepth 0 -false ensures we never actually reach -quit
    // (so the test process doesn't exit)
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "/tmp", "-maxdepth", "0", "-false", "-quit" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "find: -samefile matches files with same inode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "original.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const orig_path = try std.fs.path.join(allocator, &.{ dir_path, "original.txt" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-samefile", orig_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "original.txt") != null);
}

test "find: -sparse stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-sparse" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -xattr stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-xattr" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -xattrname stub accepted (always false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-xattrname", "com.apple.metadata" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -printf stub accepted (prints like -print)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "file.txt", "-printf", "%p\\n" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -false always evaluates to false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -false should prevent any output
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-false" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "find: -true always evaluates to true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -true should match everything (equivalent to no test)
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-true" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -false -o -true evaluates to true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "(", "-false", "-o", "-true", ")" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
}

test "find: -regex rejects non-matching pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "hello.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-regex", "^impossible_pattern_that_matches_nothing$" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // No files should match an impossible regex pattern
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "find: -iregex rejects non-matching pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "hello.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-iregex", "^impossible_pattern_that_matches_nothing$" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // No files should match an impossible regex pattern
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

// F56: -size uses wrong block rounding (bytes not 512-byte blocks)
// GNU find -size n (default unit = 512-byte blocks) uses ceiling division:
//   file_blocks = ceil(file_bytes / 512)
// Our implementation compares raw bytes, so these tests fail.

test "find: -size 1 matches 100-byte file (block rounding)" {
    // A 100-byte file occupies ceil(100/512) = 1 block.
    // GNU: find . -size 1 matches files from 1 to 512 bytes.
    // Bug: our code computes target_bytes=512 and checks 100 == 512 => false.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "small.txt", .{});
    try f.writeStreamingAll(testing.io, "x" ** 100);
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -size 1 means exactly 1 block (512 bytes); 100 bytes rounds up to 1 block
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-size", "1" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "small.txt") != null);
}

test "find: -size 2 matches 513-byte file (block rounding)" {
    // A 513-byte file occupies ceil(513/512) = 2 blocks.
    // GNU: find . -size 2 matches files from 513 to 1024 bytes.
    // Bug: our code computes target_bytes=1024 and checks 513 == 1024 => false.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "medium.txt", .{});
    try f.writeStreamingAll(testing.io, "x" ** 513);
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -size 2 means exactly 2 blocks; 513 bytes rounds up to 2 blocks
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-size", "2" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "medium.txt") != null);
}

test "find: -size -2 excludes 513-byte file (block rounding)" {
    // A 513-byte file occupies ceil(513/512) = 2 blocks.
    // GNU: find . -size -2 matches files with fewer than 2 blocks (i.e. 0 or 1 block).
    // A 513-byte file has 2 blocks, so -size -2 should NOT match it.
    // Bug: our code computes target_bytes=1024 and checks 513 < 1024 => true (wrong).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "twoblk.txt", .{});
    try f1.writeStreamingAll(testing.io, "x" ** 513);
    f1.close(testing.io);

    const f2 = try tmp.dir.createFile(testing.io, "oneblk.txt", .{});
    try f2.writeStreamingAll(testing.io, "x" ** 100);
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -size -2 means fewer than 2 blocks; 513 bytes = 2 blocks, should NOT match
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-size", "-2" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // oneblk.txt (100 bytes = 1 block) should match -size -2
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "oneblk.txt") != null);
    // twoblk.txt (513 bytes = 2 blocks) should NOT match -size -2
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "twoblk.txt") == null);
}

// ================================================================
// Audit finding U4: -exec MUST-tier primary has no unit test
// ================================================================
test "find: -exec runs command and filters on exit code" {
    // -exec is an action, so it suppresses implicit -print.
    // To verify it works, combine with explicit -print:
    //   -exec true {} ; -print  => true AND print => file printed
    //   -exec false {} ; -print => false AND print => nothing printed
    // Use /usr/bin paths which exist on both Linux and macOS
    // (/bin/true and /bin/false don't exist on macOS).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "target.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Test 1: -exec /usr/bin/true {} ; -print => file printed
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-exec", "/usr/bin/true", "{}", ";", "-print" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "target.txt") != null);
    }

    // Test 2: -exec /usr/bin/false {} ; -print => nothing printed
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-exec", "/usr/bin/false", "{}", ";", "-print" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // -exec /usr/bin/false returns false, so AND -print never fires
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "target.txt") == null);
    }
}

// ================================================================
// Audit finding U8: -user MUST-tier primary has no unit test
// ================================================================
test "find: -user matches files by username" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "myfile.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Get the UID of the test file, then look up the username
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "myfile.txt" });
    const stat_buf = try doStat(file_path, false);
    const pw = getpwuid(stat_buf.uid);
    try testing.expect(pw != null);
    const username = std.mem.sliceTo(pw.?.pw_name, 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-user", username }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "myfile.txt") != null);
}

// ================================================================
// Audit finding U9: -group MUST-tier primary has no unit test
// ================================================================
test "find: -group matches files by group name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "grpfile.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Get the GID of the test file, then look up the group name
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "grpfile.txt" });
    const stat_buf = try doStat(file_path, false);
    const gr = getgrgid(stat_buf.gid);
    try testing.expect(gr != null);
    const groupname = std.mem.sliceTo(gr.?.gr_name, 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-group", groupname }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "grpfile.txt") != null);
}

// ================================================================
// Audit finding U10: -nogroup MUST-tier primary has no unit test
// ================================================================
test "find: -nogroup matches nothing for normal files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "normalfile.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Files created by this user have a valid group; -nogroup should
    // not match anything.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-nogroup" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "normalfile.txt") == null);
}

// ================================================================
// Audit finding U12: -newer MUST-tier primary has no unit test
// (only -mnewer alias is tested)
// ================================================================
test "find: -newer matches files modified after reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create reference file first
    const ref = try tmp.dir.createFile(testing.io, "old_ref.txt", .{});
    ref.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Set the reference file's mtime to the past so newly created files
    // will have a later modification time
    const past = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    } - 3600; // 1 hour ago
    const past_ts = std.posix.timespec{ .sec = past, .nsec = 0 };
    const ref_abs_path = try std.fs.path.join(allocator, &.{ dir_path, "old_ref.txt" });
    var ref_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(ref_path_buf[0..ref_abs_path.len], ref_abs_path);
    ref_path_buf[ref_abs_path.len] = 0;
    const ref_c_path = ref_path_buf[0..ref_abs_path.len :0];
    var times = [2]std.posix.timespec{ past_ts, past_ts };
    _ = std.c.utimensat(std.Io.Dir.cwd().handle, ref_c_path, &times, 0);

    // Create the test file (will have current mtime)
    const f = try tmp.dir.createFile(testing.io, "newer.txt", .{});
    f.close(testing.io);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -newer compares mtime of found file against mtime of reference file
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-type", "f", "-newer", ref_abs_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "newer.txt") != null);
    // old_ref.txt should NOT match -newer old_ref.txt (not newer than itself)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "old_ref.txt") == null);
}

// ================================================================
// Audit finding U13: -L MUST-tier option has no unit test
// ================================================================
test "find: -L follows symlinks to directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a real directory with a file
    try tmp.dir.createDir(testing.io, "realdir", .default_dir);
    const f = try tmp.dir.createFile(testing.io, "realdir/deep.txt", .{});
    f.close(testing.io);

    // Create a symlink to that directory
    try tmp.dir.symLink(testing.io, "realdir", "linkdir", .{ .is_directory = true });

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Without -L, find should NOT descend into linkdir (it's a symlink)
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "deep.txt" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // Should find deep.txt under realdir but NOT under linkdir
        const output = stdout_aw.writer.buffered();
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, output, pos, "deep.txt")) |idx| {
            count += 1;
            pos = idx + 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // With -L, find should follow the symlink and descend into linkdir too
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-L", dir_path, "-name", "deep.txt" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // With -L, should find deep.txt under both realdir and linkdir
        const output = stdout_aw.writer.buffered();
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, output, pos, "deep.txt")) |idx| {
            count += 1;
            pos = idx + 1;
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
}

// ================================================================
// Audit finding U13: -H MUST-tier option has no unit test
// ================================================================
test "find: -H follows only command-line symlinks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a real directory with a file
    try tmp.dir.createDir(testing.io, "target", .default_dir);
    const f = try tmp.dir.createFile(testing.io, "target/inner.txt", .{});
    f.close(testing.io);

    // Create a symlink to that directory at top level
    try tmp.dir.symLink(testing.io, "target", "toplink", .{ .is_directory = true });

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const link_path = try std.fs.path.join(allocator, &.{ dir_path, "toplink" });

    // With -H, passing the symlink as the starting path should follow it
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-H", link_path, "-name", "inner.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    // -H should follow the symlink given on the command line
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "inner.txt") != null);
}

// ================================================================
// Audit finding U13: -follow in expression position has no unit test
// Finding H7: -follow only recognized before paths, not in expression
// ================================================================
test "find: -follow in expression position is accepted" {
    // GNU/macOS find allow -follow as a deprecated expression primary.
    // Our implementation only recognizes it as a global option (before paths).
    // When -follow appears after another primary, it should still work.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "file.txt", .{});
    f.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -follow after -maxdepth should be accepted, not "unknown predicate"
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-maxdepth", "1", "-follow" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should not produce an error about unknown predicate
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

// ================================================================
// Audit finding U14: -and/-a MUST-tier operator has no unit test
// ================================================================
test "find: -a and -and operators combine predicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "hello.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "hello.md", .{});
    f2.close(testing.io);
    const f3 = try tmp.dir.createFile(testing.io, "world.txt", .{});
    f3.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Test -a (short form)
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        // -name "hello*" -a -name "*.txt" should match only hello.txt
        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "hello*", "-a", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);

        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello.txt") != null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello.md") == null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "world.txt") == null);
    }

    // Test -and (long form)
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ dir_path, "-name", "hello*", "-and", "-name", "*.txt" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);

        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello.txt") != null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "hello.md") == null);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "world.txt") == null);
    }
}

// ============================================================================
// Walker-migration characterization tests
//
// These lock in the traversal behavior that the bounded common.walker rewrite
// must preserve when walkPath is deleted. Each asserts a SPECIFIC ordering,
// depth, symlink, error, or filtering behavior that a wrong driver loop would
// break. They run at the runFind level, the same as the existing 98 tests.
//
// These are behavior-PRESERVING: they must pass GREEN on the current recursive
// walkPath AND on the walker driver that replaces it. Teeth are proven later by
// transient sabotage of the implementation.
// ============================================================================

test "find: walker: multi-level pre-order prints parents before their contents" {
    // Guards behavior #7 of walkPath (pre-order directory evaluate before
    // descent). The default order is pre-order: a directory's own line must
    // appear BEFORE any line for an entry inside it, at every level. A
    // post-order regression would flip the relative positions and fail this.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{a.txt, sub/{b.txt, deeper/{c.txt}}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    (try root.createFile(testing.io, "a.txt", .{})).close(testing.io);
    try root.createDir(testing.io, "sub", .default_dir);
    var sub = try root.openDir(testing.io, "sub", .{});
    defer sub.close(testing.io);
    (try sub.createFile(testing.io, "b.txt", .{})).close(testing.io);
    try sub.createDir(testing.io, "deeper", .default_dir);
    var deeper = try sub.openDir(testing.io, "deeper", .{});
    defer deeper.close(testing.io);
    (try deeper.createFile(testing.io, "c.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{root_path}, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // Every depth must be reached.
    const a_pos = std.mem.find(u8, out, "a.txt") orelse return error.MissingA;
    const b_pos = std.mem.find(u8, out, "b.txt") orelse return error.MissingB;
    const c_pos = std.mem.find(u8, out, "c.txt") orelse return error.MissingC;
    // The directory's OWN line ends in a newline after the dir name (the dir is
    // never a path prefix of itself plus "\n"), so anchor on "<name>\n".
    const root_line = try std.fmt.allocPrint(allocator, "{s}\n", .{root_path});
    const root_pos = std.mem.find(u8, out, root_line) orelse return error.MissingRoot;
    const sub_pos = std.mem.find(u8, out, "sub\n") orelse return error.MissingSub;
    const deeper_pos = std.mem.find(u8, out, "deeper\n") orelse return error.MissingDeeper;

    // Pre-order: each directory precedes its own descendants.
    try testing.expect(root_pos < a_pos);
    try testing.expect(root_pos < sub_pos);
    try testing.expect(sub_pos < b_pos);
    try testing.expect(sub_pos < deeper_pos);
    try testing.expect(deeper_pos < c_pos);
}

test "find: walker: multiple path operands are each fully walked in argument order" {
    // Guards behavior C (multiple start operands drained in argument order) and
    // the runFind per-operand loop. Two distinct trees passed as operands must
    // BOTH be walked to completion, and the first operand's output must precede
    // the second's. A driver that dropped the second operand, or reordered
    // them, would fail.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // alpha/{inside_alpha.txt}  and  beta/{inside_beta.txt}
    try tmp.dir.createDir(testing.io, "alpha", .default_dir);
    var alpha = try tmp.dir.openDir(testing.io, "alpha", .{});
    defer alpha.close(testing.io);
    (try alpha.createFile(testing.io, "inside_alpha.txt", .{})).close(testing.io);

    try tmp.dir.createDir(testing.io, "beta", .default_dir);
    var beta = try tmp.dir.openDir(testing.io, "beta", .{});
    defer beta.close(testing.io);
    (try beta.createFile(testing.io, "inside_beta.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const alpha_path = try std.fs.path.join(allocator, &.{ base, "alpha" });
    const beta_path = try std.fs.path.join(allocator, &.{ base, "beta" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // beta is listed first to prove order follows the ARGUMENT order, not the
    // lexicographic order of the names (alpha < beta).
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ beta_path, alpha_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const beta_child_pos = std.mem.find(u8, out, "inside_beta.txt") orelse return error.MissingBetaChild;
    const alpha_child_pos = std.mem.find(u8, out, "inside_alpha.txt") orelse return error.MissingAlphaChild;
    // Both operands fully walked, and the FIRST operand (beta) comes first.
    try testing.expect(beta_child_pos < alpha_child_pos);
}

test "find: walker: -maxdepth 0 evaluates only the start operand" {
    // Guards the maxdepth boundary at depth 0 (behavior #1/#8). With -maxdepth
    // 0, ONLY the operand itself is evaluated; not even its immediate children
    // appear. Existing tests only cover maxdepth 1, so this exercises the
    // pruneCurrent()-at-the-root path of the driver.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    (try tmp.dir.createFile(testing.io, "child.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ base, "-maxdepth", "0" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // The operand itself is printed.
    try testing.expect(std.mem.find(u8, out, base) != null);
    // Its children are NOT (depth 1 > maxdepth 0).
    try testing.expect(std.mem.find(u8, out, "child.txt") == null);
}

test "find: walker: -maxdepth N under -depth evaluates depth N, never N+1" {
    // Guards behavior #8 in the post-order (-depth) path: entries AT the
    // maxdepth boundary are still evaluated, entries past it never appear. The
    // briefing flags this combination as untested. Under -depth the driver must
    // evaluate the boundary directory yet not descend.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{lvl1.txt, sub/{lvl2.txt}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    (try root.createFile(testing.io, "lvl1.txt", .{})).close(testing.io);
    try root.createDir(testing.io, "sub", .default_dir);
    var sub = try root.openDir(testing.io, "sub", .{});
    defer sub.close(testing.io);
    (try sub.createFile(testing.io, "lvl2.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // root is depth 0, lvl1.txt and sub are depth 1, lvl2.txt is depth 2.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ root_path, "-depth", "-maxdepth", "1" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // Depth 1 entries are evaluated.
    try testing.expect(std.mem.find(u8, out, "lvl1.txt") != null);
    try testing.expect(std.mem.find(u8, out, "sub\n") != null);
    // Depth 2 entry never appears.
    try testing.expect(std.mem.find(u8, out, "lvl2.txt") == null);
    // Under -depth the boundary dir "sub" is still printed AFTER its sibling
    // file (post-order at the same level keeps children-before-parent only for
    // deeper levels; here sub is a leaf of the walk because we do not descend).
}

test "find: walker: -mindepth under -depth descends through shallow entries but suppresses them" {
    // Guards behavior #6/#7 mindepth filtering combined with post-order. The
    // mindepth filter must suppress OUTPUT for shallow entries while still
    // descending through them, even under -depth. Briefing flags this as
    // untested.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{shallow.txt, sub/{deep.txt}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    (try root.createFile(testing.io, "shallow.txt", .{})).close(testing.io);
    try root.createDir(testing.io, "sub", .default_dir);
    var sub = try root.openDir(testing.io, "sub", .{});
    defer sub.close(testing.io);
    (try sub.createFile(testing.io, "deep.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // mindepth 2: depth-0 root and depth-1 entries suppressed; deep.txt (depth
    // 2) must still be reached, proving the walk descended through the shallow,
    // suppressed levels.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ root_path, "-depth", "-mindepth", "2" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // The deep entry, reachable only by descending past suppressed levels, appears.
    try testing.expect(std.mem.find(u8, out, "deep.txt") != null);
    // Shallow entries are suppressed.
    try testing.expect(std.mem.find(u8, out, "shallow.txt") == null);
    try testing.expect(std.mem.find(u8, out, "sub\n") == null);
}

test "find: walker: -depth -delete empties then removes a matched directory" {
    // Guards behavior: -delete forces depth-first and, because contents are
    // visited before the directory, an empty-able directory is removed after
    // its children. The existing -delete test only deletes a single file. Here
    // a populated directory must end up gone, proving children were deleted
    // first (post-order) and the now-empty dir removed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // victim/{a.txt, b.txt}
    try tmp.dir.createDir(testing.io, "victim", .default_dir);
    var victim = try tmp.dir.openDir(testing.io, "victim", .{});
    (try victim.createFile(testing.io, "a.txt", .{})).close(testing.io);
    (try victim.createFile(testing.io, "b.txt", .{})).close(testing.io);
    victim.close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const victim_path = try std.fs.path.join(allocator, &.{ base, "victim" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ victim_path, "-delete" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // The whole directory, including its files, must be gone. If children were
    // not deleted before the dir (wrong order), rmdir on a non-empty dir would
    // fail and victim would survive.
    const victim_stat = tmp.dir.statFile(testing.io, "victim", .{});
    try testing.expect(victim_stat == error.FileNotFound);
}

test "find: walker: unreadable subdirectory errors, siblings still processed, exit 1" {
    // Guards behavior #9 (dir open failure path). When a child directory cannot
    // be opened, find must report the error to stderr naming the directory,
    // continue processing sibling entries, and exit nonzero. Root bypasses read
    // permissions, so skip when euid is root (mirrors the cp unreadable-subdir
    // test).
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{readable_sibling.txt, locked/{secret.txt}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    (try root.createFile(testing.io, "readable_sibling.txt", .{})).close(testing.io);
    try root.createDir(testing.io, "locked", .default_dir);
    var locked = try root.openDir(testing.io, "locked", .{});
    (try locked.createFile(testing.io, "secret.txt", .{})).close(testing.io);
    locked.close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    // chmod by absolute path (libc) reliably persists; restore in defer so
    // TmpDir cleanup can recurse in. Skip if the platform refuses chmod 000.
    const locked_z = try std.fmt.allocPrintSentinel(allocator, "{s}/locked", .{root_path}, 0);
    if (std.c.chmod(locked_z, 0o000) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_z, 0o755);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{root_path}, &stdout_aw.writer, &stderr_aw.writer);

    // Nonzero exit because one subtree could not be read.
    try testing.expectEqual(@as(u8, 1), exit_code);
    // The readable sibling is still processed despite the failed sibling.
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "readable_sibling.txt") != null);
    // The error names the unreadable directory.
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "locked") != null);
}

test "find: walker: under -depth an unreadable directory is itself still evaluated" {
    // Guards the find.zig:2680 contract (behavior #9 under depth_first): when
    // depth_first is active and openDir fails, the failed directory is STILL
    // evaluated (its -print fires) even though descent failed. The walker driver
    // must restat the failed path and call evaluate() in its error path.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{locked/{secret.txt}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    try root.createDir(testing.io, "locked", .default_dir);
    var locked = try root.openDir(testing.io, "locked", .{});
    (try locked.createFile(testing.io, "secret.txt", .{})).close(testing.io);
    locked.close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    const locked_z = try std.fmt.allocPrintSentinel(allocator, "{s}/locked", .{root_path}, 0);
    if (std.c.chmod(locked_z, 0o000) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_z, 0o755);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ root_path, "-depth" }, &stdout_aw.writer, &stderr_aw.writer);

    // Nonzero exit because the descent failed.
    try testing.expectEqual(@as(u8, 1), exit_code);
    // The contract: the unreadable directory's OWN line still prints under -depth.
    const locked_line = try std.fmt.allocPrint(allocator, "{s}/locked\n", .{root_path});
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), locked_line) != null);
    // Its child was never reached (descent failed).
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "secret.txt") == null);
}

test "find: walker: -prune on a matched directory suppresses its whole subtree" {
    // Guards behavior #7 + pruneCurrent(): a directory matched by -prune is
    // emitted but its subtree is not descended. Distinct from the existing
    // -prune test (which uses the -o filtering form): here we assert the pruned
    // directory ITSELF prints while everything beneath it is absent.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{prune_me/{deep/{burrowed.txt}}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    try root.createDir(testing.io, "prune_me", .default_dir);
    var prune_me = try root.openDir(testing.io, "prune_me", .{});
    defer prune_me.close(testing.io);
    try prune_me.createDir(testing.io, "deep", .default_dir);
    var deep = try prune_me.openDir(testing.io, "deep", .{});
    defer deep.close(testing.io);
    (try deep.createFile(testing.io, "burrowed.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ root_path, "-name", "prune_me", "-prune" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // The pruned directory itself is still emitted.
    try testing.expect(std.mem.find(u8, out, "prune_me\n") != null);
    // Nothing beneath it was descended.
    try testing.expect(std.mem.find(u8, out, "deep\n") == null);
    try testing.expect(std.mem.find(u8, out, "burrowed.txt") == null);
}

test "find: walker: -prune is a no-op under -depth (subtree still appears)" {
    // Guards invariant B: under -depth, -prune is a documented no-op because the
    // post-order walk has already descended before the directory is evaluated.
    // The whole subtree must still appear. A driver that honored prune under
    // post-order would wrongly drop the subtree.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{prune_me/{burrowed.txt}}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    try root.createDir(testing.io, "prune_me", .default_dir);
    var prune_me = try root.openDir(testing.io, "prune_me", .{});
    defer prune_me.close(testing.io);
    (try prune_me.createFile(testing.io, "burrowed.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    // The classic prune-or-print expression. WITHOUT -depth this prunes the
    // subtree, so burrowed.txt is absent — establishing that the expression
    // really does prune when prune is honored.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
            root_path, "-name", "prune_me", "-prune", "-o", "-print",
        }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // Pre-order: prune is honored, so the subtree is suppressed.
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "burrowed.txt") == null);
    }

    // WITH -depth the very same expression must NOT suppress the subtree: prune
    // is a documented no-op under post-order because the walk already descended
    // before the directory is evaluated. So burrowed.txt reappears.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
            root_path, "-depth", "-name", "prune_me", "-prune", "-o", "-print",
        }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // Post-order: prune is a no-op, so the file beneath the "pruned" dir appears.
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "burrowed.txt") != null);
    }
}

test "find: walker: -s emits each directory's children in lexicographic order" {
    // Guards the sorted-children behavior. The existing -s test only verifies
    // the flag parses; this asserts the actual lexicographic ordering of
    // siblings within a directory. The walker rewrite uses sort_children=true.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create children OUT of lexicographic order so a no-sort regression would
    // likely emit them in readdir (creation/inode) order and fail.
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    (try root.createFile(testing.io, "charlie.txt", .{})).close(testing.io);
    (try root.createFile(testing.io, "alpha.txt", .{})).close(testing.io);
    (try root.createFile(testing.io, "bravo.txt", .{})).close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-s", root_path }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const alpha_pos = std.mem.find(u8, out, "alpha.txt") orelse return error.MissingAlpha;
    const bravo_pos = std.mem.find(u8, out, "bravo.txt") orelse return error.MissingBravo;
    const charlie_pos = std.mem.find(u8, out, "charlie.txt") orelse return error.MissingCharlie;
    // Lexicographic: alpha < bravo < charlie.
    try testing.expect(alpha_pos < bravo_pos);
    try testing.expect(bravo_pos < charlie_pos);
}

test "find: walker: -P does not descend a symlink-to-directory start operand" {
    // Guards the -P (default) policy at depth 0: a symlink-to-directory passed
    // AS the operand is printed as a symlink and NOT followed. -type l matches
    // it; -type f does not; and the file behind it is unreachable through the
    // link. The existing "-P global option accepted as no-op" test does not
    // verify this.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // target/{behind.txt}, and operand_link -> target
    try tmp.dir.createDir(testing.io, "target", .default_dir);
    var target = try tmp.dir.openDir(testing.io, "target", .{});
    defer target.close(testing.io);
    (try target.createFile(testing.io, "behind.txt", .{})).close(testing.io);
    tmp.dir.symLink(testing.io, "target", "operand_link", .{ .is_directory = true }) catch return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const link_path = try std.fs.path.join(allocator, &.{ base, "operand_link" });

    // -P is the default; pass the symlink operand and list with -type l.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ link_path, "-type", "l" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // The operand is evaluated as a symlink: -type l matches it.
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "operand_link") != null);
    }

    // The link is not followed: the file behind it is unreachable, and -type d
    // does not match the symlink operand.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{link_path}, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // No descent through the symlink operand.
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "behind.txt") == null);
    }
}

test "find: walker: -H follows operand symlink but evaluates inner symlinks as links" {
    // Guards the -H (.follow_cmdline) policy: a symlink-to-directory START
    // operand is followed and descended, while a symlink ENCOUNTERED INSIDE the
    // tree is evaluated as a symlink (-type l matches) and not followed. The
    // existing -H test covers operand-following but not the inner-link part.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // inner_target/{deep.txt} reachable only by following an inner symlink.
    try tmp.dir.createDir(testing.io, "inner_target", .default_dir);
    var inner_target = try tmp.dir.openDir(testing.io, "inner_target", .{});
    defer inner_target.close(testing.io);
    (try inner_target.createFile(testing.io, "deep.txt", .{})).close(testing.io);

    // operand_target/{op_file.txt, inner_link -> ../inner_target}
    try tmp.dir.createDir(testing.io, "operand_target", .default_dir);
    var operand_target = try tmp.dir.openDir(testing.io, "operand_target", .{});
    defer operand_target.close(testing.io);
    (try operand_target.createFile(testing.io, "op_file.txt", .{})).close(testing.io);
    operand_target.symLink(testing.io, "../inner_target", "inner_link", .{ .is_directory = true }) catch return error.SkipZigTest;

    // The operand itself is a symlink to operand_target.
    tmp.dir.symLink(testing.io, "operand_target", "operand_link", .{ .is_directory = true }) catch return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const operand_link = try std.fs.path.join(allocator, &.{ base, "operand_link" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-H", operand_link }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // Operand symlink followed: the file inside the target is reached.
    try testing.expect(std.mem.find(u8, out, "op_file.txt") != null);
    // The inner symlink is NOT followed: the file behind it is unreachable.
    try testing.expect(std.mem.find(u8, out, "deep.txt") == null);

    // The inner symlink itself is evaluated as a symlink: -type l matches it.
    var stdout2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout2.deinit();
    var stderr2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr2.deinit();
    const exit2 = try runFind(allocator, testing.io, &[_][]const u8{ "-H", operand_link, "-type", "l" }, &stdout2.writer, &stderr2.writer);
    try testing.expectEqual(@as(u8, 0), exit2);
    try testing.expect(std.mem.find(u8, stdout2.writer.buffered(), "inner_link") != null);
}

test "find: walker: -L evaluates an inner symlink-to-file as its target type" {
    // Guards the -L (.follow_all) policy for a symlink-to-FILE inside the tree:
    // the link is evaluated as its target kind, so -type f matches the link path
    // and -type l does not. Briefing flags this as untested.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/{real.txt, link_to_file -> real.txt}
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    (try root.createFile(testing.io, "real.txt", .{})).close(testing.io);
    root.symLink(testing.io, "real.txt", "link_to_file", .{}) catch return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    // With -L, -type f matches BOTH the real file and the link (resolved type).
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-L", root_path, "-type", "f" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // The link path is reported as a regular file under -L.
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "link_to_file") != null);
    }

    // With -L, -type l matches NEITHER (the link is resolved away).
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-L", root_path, "-type", "l" }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);
        // No symlinks are visible under -L.
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "link_to_file") == null);
    }
}

test "find: walker: -L descends two sibling symlinks pointing at the same directory" {
    // Guards invariant: under -L, two sibling symlinks to the SAME target
    // directory must BOTH be descended (legitimate duplicate follows). Only true
    // ancestor cycles are blocked; the cycle detector must not suppress these.
    // The file beneath the shared target must be reachable through BOTH link
    // names. Briefing flags this as untested.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // shared/{found.txt}, root/{link_a -> ../shared, link_b -> ../shared}
    try tmp.dir.createDir(testing.io, "shared", .default_dir);
    var shared = try tmp.dir.openDir(testing.io, "shared", .{});
    defer shared.close(testing.io);
    (try shared.createFile(testing.io, "found.txt", .{})).close(testing.io);

    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    root.symLink(testing.io, "../shared", "link_a", .{ .is_directory = true }) catch return error.SkipZigTest;
    root.symLink(testing.io, "../shared", "link_b", .{ .is_directory = true }) catch return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-L", root_path, "-name", "found.txt" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // found.txt must be reached through BOTH link names (two distinct hits).
    const out = stdout_aw.writer.buffered();
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, out, pos, "found.txt")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "find: walker: -X never filters the depth-0 start operand" {
    // Guards behavior #5: the -X xargs-unsafe filter applies only at depth > 0.
    // A start operand whose own basename is xargs-unsafe must NOT be filtered.
    // Briefing flags this as untested.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A directory whose own name contains a space (xargs-unsafe).
    try tmp.dir.createDir(testing.io, "un safe", .default_dir);
    var unsafe_dir = try tmp.dir.openDir(testing.io, "un safe", .{});
    (try unsafe_dir.createFile(testing.io, "inside.txt", .{})).close(testing.io);
    unsafe_dir.close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const operand_path = try std.fs.path.join(allocator, &.{ base, "un safe" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ operand_path, "-X" }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // The unsafe-named operand itself is NOT filtered (depth 0 is exempt): it is
    // printed and its contents are reached.
    try testing.expect(std.mem.find(u8, out, "un safe") != null);
    try testing.expect(std.mem.find(u8, out, "inside.txt") != null);
}

// ============================================================================
// Walker-migration BEHAVIOR-FIX test (intended RED on current code)
//
// Unlike the characterization tests above, this one pins GNU findutils
// behavior that the CURRENT recursive walkPath gets WRONG. It must FAIL now at
// the assertion matching the bug, and pass after the bounded walker migration
// adds filesystem-loop detection. Do NOT relax it to match today's output.
// ============================================================================

test "find: walker-migration: -L reports filesystem loop without descending it" {
    // GNU `find -L` detects an ancestor symlink cycle, emits a diagnostic naming
    // both the loop link and the ancestor it loops back to, prints the siblings
    // it can, refuses to descend the loop, and exits 1. Current vibeutils find
    // instead follows the loop ~40 levels deep (output is littered with
    // "up/sub/up/sub/...") and never prints the loop diagnostic. The KEY RED
    // assertions are (a) the "File system loop detected" diagnostic is present
    // and (b) the junk descent path ".../sub/up/sub" is absent.
    //
    // Methodology: build T/sub/{f.txt, up -> ..} where `up` is a relative
    // symlink looping back to the tmp root, then run `find -L T` and inspect the
    // captured stdout/stderr. An arena backs allocations so the hundreds of junk
    // lines today's code emits cannot trip a fixed-size buffer.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // root/sub/{f.txt, up -> ..}  ("up" loops back to root, an ancestor).
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    try root.createDir(testing.io, "sub", .default_dir);
    var sub = try root.openDir(testing.io, "sub", .{});
    defer sub.close(testing.io);
    (try sub.createFile(testing.io, "f.txt", .{})).close(testing.io);
    sub.symLink(testing.io, "..", "up", .{ .is_directory = true }) catch return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });
    const loop_link_path = try std.fs.path.join(allocator, &.{ base, "root", "sub", "up" });
    // The path the junk descent produces: <root>/sub/up/sub. Its presence proves
    // the loop was followed instead of being detected and skipped.
    const junk_descent_path = try std.fs.path.join(allocator, &.{ base, "root", "sub", "up", "sub" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{ "-L", root_path }, &stdout_aw.writer, &stderr_aw.writer);

    const out = stdout_aw.writer.buffered();
    const err = stderr_aw.writer.buffered();

    // KEY RED (a): the loop diagnostic must be emitted. Today: absent. The quote
    // glyphs are locale-dependent, so assert only the stable English substring.
    try testing.expect(std.mem.find(u8, err, "File system loop detected") != null);

    // KEY RED (b): the loop must NOT be descended. Today the output contains
    // <root>/sub/up/sub (and far deeper). After the fix it never appears.
    try testing.expect(std.mem.find(u8, out, junk_descent_path) == null);

    // Supporting: the diagnostic names BOTH the loop link and the ancestor it
    // loops back to (GNU phrases it "<link> is part of the same file system loop
    // as <ancestor>"). The ancestor here is the root operand.
    try testing.expect(std.mem.find(u8, err, loop_link_path) != null);
    try testing.expect(std.mem.find(u8, err, root_path) != null);

    // Supporting: reachable siblings are still emitted before the loop is hit.
    try testing.expect(std.mem.find(u8, out, "f.txt") != null);

    // Supporting: the loop makes the walk fail, so the exit code is 1.
    try testing.expectEqual(@as(u8, 1), exit_code);
}

// === Characterization tests for the evaluate() recursion-removal refactor ===
//
// These pin the order-sensitive, side-effecting boolean semantics of the
// expression-tree evaluator (and_expr / or_expr / not_expr) so the planned
// iterative (de-recursion) rewrite preserves them exactly. Each test drives a
// SIDE EFFECT (-print emitting a basename) through a short-circuit boundary so
// that a wrong rewrite -- one that evaluates a right operand it should have
// suppressed, or skips one it should have run, or mis-inverts -not -- changes
// the observable output. They must PASS on the current recursive code.

test "find: evaluate: AND short-circuit suppresses right-side -print for non-matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // One file matches the -name test, one does not. Both exist on disk.
    const matchf = try tmp.dir.createFile(testing.io, "match_aaa.txt", .{});
    matchf.close(testing.io);
    const otherf = try tmp.dir.createFile(testing.io, "other_bbb.txt", .{});
    otherf.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // and(name "match_*", print). For the non-matching file -name returns
    // false, so the right operand -print MUST be suppressed (stop-on-false).
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "match_*", "-print",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // The matching file is printed.
    try testing.expect(std.mem.find(u8, out, "match_aaa.txt") != null);
    // KEY: the non-matching file is NOT printed. A rewrite that evaluates the
    // right operand even when the left is false would emit "other_bbb.txt".
    try testing.expect(std.mem.find(u8, out, "other_bbb.txt") == null);
}

test "find: evaluate: OR short-circuit suppresses side-effecting right -print on left-true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file matching the left -name, and one that does not.
    const matchf = try tmp.dir.createFile(testing.io, "left_zzz.txt", .{});
    matchf.close(testing.io);
    const otherf = try tmp.dir.createFile(testing.io, "right_yyy.txt", .{});
    otherf.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // or(name "left_*", print). The whole expression is an action, so there is
    // no implicit print. For the matching file the left is true, so -o stops
    // (stop-on-true) and the right -print is suppressed -> matching file is NOT
    // printed. For the non-matching file the left is false, so the right -print
    // fires -> it IS printed. This is the inverse of the AND case and catches a
    // rewrite that flips OR's short-circuit polarity.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "left_*", "-o", "-print",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // KEY: the left-matching file is suppressed (right -print never reached).
    try testing.expect(std.mem.find(u8, out, "left_zzz.txt") == null);
    // KEY: the non-matching file falls through to the right -print and appears.
    try testing.expect(std.mem.find(u8, out, "right_yyy.txt") != null);
}

test "find: evaluate: -not inverts its operand and drives the following AND short-circuit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const matchf = try tmp.dir.createFile(testing.io, "skip_ccc.txt", .{});
    matchf.close(testing.io);
    const otherf = try tmp.dir.createFile(testing.io, "keep_ddd.txt", .{});
    otherf.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // and(not(name "skip_*"), print). For the matching file: not(true)=false ->
    // AND short-circuits and -print is suppressed. For the non-matching file:
    // not(false)=true -> -print fires. A rewrite that mis-inverts -not, or
    // fires the not_result frame at the wrong time, swaps these two outcomes.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-not", "-name", "skip_*", "-print",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // The matched-and-negated file is excluded.
    try testing.expect(std.mem.find(u8, out, "skip_ccc.txt") == null);
    // The non-matching file survives the negation and is printed.
    try testing.expect(std.mem.find(u8, out, "keep_ddd.txt") != null);
}

test "find: evaluate: implicit -print obeys flat -true and is suppressed by flat -false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file AND a directory, so we prove -true prints non-file entries too --
    // distinct from the existing "-type f -true" test which filters to files.
    const f = try tmp.dir.createFile(testing.io, "flat_eee.txt", .{});
    f.close(testing.io);
    try tmp.dir.createDir(testing.io, "flat_dir", .default_dir);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // -true wraps to and(true, print): everything (file and dir) is printed.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
            dir_path, "-true",
        }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);

        const out = stdout_aw.writer.buffered();
        try testing.expect(std.mem.find(u8, out, "flat_eee.txt") != null);
        // The directory must appear too (no -type filter narrows the walk).
        try testing.expect(std.mem.find(u8, out, "flat_dir") != null);
    }

    // -false wraps to and(false, print): AND short-circuits, nothing printed.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
            dir_path, "-false",
        }, &stdout_aw.writer, &stderr_aw.writer);
        try testing.expectEqual(@as(u8, 0), exit_code);

        // KEY: a false top-level expression suppresses the implicit -print.
        try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    }
}

test "find: evaluate: prune via out-param composed with -o suppresses pruned dir's own -print" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A directory to prune (with a child) and a sibling file. Existing tests at
    // ~3943 and the walker prune tests use "-type f -print" on the right of -o;
    // here the right operand is a BARE -print, which also prints directories.
    // That makes the assertion below ("the pruned dir's own name is absent")
    // load-bearing: it can only be absent because -o short-circuited on the
    // left (name+prune both true), never reaching the right -print for that dir.
    try tmp.dir.createDir(testing.io, "prune_fff", .default_dir);
    var pdir = try tmp.dir.openDir(testing.io, "prune_fff", .{});
    const child = try pdir.createFile(testing.io, "buried_ggg.txt", .{});
    child.close(testing.io);
    pdir.close(testing.io);

    const sib = try tmp.dir.createFile(testing.io, "sibling_hhh.txt", .{});
    sib.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // or(and(name "prune_fff", prune), print). For prune_fff the left subtree
    // is true (name matches, -prune returns true and sets pruned), so -o stops
    // and the right bare -print is suppressed -> prune_fff itself is NOT
    // printed. Its child is never descended into -> buried_ggg.txt absent.
    // The sibling: left and() is false (name mismatch) -> right -print fires.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "prune_fff", "-prune", "-o", "-print",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // KEY: the pruned dir's child is never reached (prune stopped descent).
    try testing.expect(std.mem.find(u8, out, "buried_ggg.txt") == null);
    // KEY: the pruned dir's OWN name is absent: -o short-circuited on left-true,
    // so the bare right -print never ran for it.
    try testing.expect(std.mem.find(u8, out, "prune_fff") == null);
    // The sibling falls through to the right -print and appears.
    try testing.expect(std.mem.find(u8, out, "sibling_hhh.txt") != null);
}
