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

// libc's passwd and group records are declared exactly once in the tree, in
// common.user_group; these aliases keep the lookups below reading like the C
// API they wrap (issue #129).
const getpwnam = common.user_group.getpwnam;
const getgrnam = common.user_group.getgrnam;
const getpwuid = common.user_group.getpwuid;
const getgrgid = common.user_group.getgrgid;
const spanOrEmpty = common.user_group.spanOrEmpty;

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
        assert(multiplier >= 1);
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
    assert(s.len > 0);

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
    assert(num_str.len > 0);

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
    assert(s.len > 0);

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
    assert(s.len > 0);

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
    assert(str.len == 1);
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
    assert(path.len <= std.Io.Dir.max_path_bytes);
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
        return doStat_buildStatInfoLinux(stx);
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
        return doStat_buildStatInfoBsd(stat_buf);
    }
}

/// Build StatInfo from a Linux statx result.
fn doStat_buildStatInfoLinux(stx: std.os.linux.Statx) StatInfo {
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
}

/// Build StatInfo from a c.Stat result (macOS/BSD).
fn doStat_buildStatInfoBsd(stat_buf: c.Stat) StatInfo {
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
        .atim = .{
            .sec = @intCast(stat_buf.atimespec.sec),
            .nsec = @intCast(stat_buf.atimespec.nsec),
        },
        .mtim = .{
            .sec = @intCast(stat_buf.mtimespec.sec),
            .nsec = @intCast(stat_buf.mtimespec.nsec),
        },
        .ctim = .{
            .sec = @intCast(stat_buf.ctimespec.sec),
            .nsec = @intCast(stat_buf.ctimespec.nsec),
        },
        .birthtimespec = .{
            .sec = @intCast(stat_buf.birthtimespec.sec),
            .nsec = @intCast(stat_buf.birthtimespec.nsec),
        },
        .flags = if (@hasField(@TypeOf(stat_buf), "flags")) @intCast(stat_buf.flags) else 0,
    };
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
fn compileRegex(
    allocator: Allocator,
    pattern: []const u8,
    ignore_case: bool,
    extended: bool,
) ?*regex_h.regex_t {
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

/// Global flags collected from the leading-globals scan, before expression
/// args. Bundled into one struct so `parseArgs` stays small and the scan
/// helper takes few arguments (Tiger Style inverse-hourglass).
const GlobalFlags = struct {
    maxdepth: ?u32 = null,
    mindepth: u32 = 0,
    depth_first: bool = false,
    follow_symlinks: bool = false,
    follow_cmdline_symlinks: bool = false,
    xdev: bool = false,
    xargs_safe: bool = false,
    sorted: bool = false,
    extended_regex: bool = false,
};

/// Scan leading global options and starting paths before the expression.
/// Mutates `flags` and appends discovered paths to `start_paths`; returns the
/// index of the first expression arg (`expr_start`). Straight-line iteration
/// moved out of `parseArgs` (push fors down).
fn parseArgs_collectLeadingGlobals(
    allocator: Allocator,
    args: []const []const u8,
    flags: *GlobalFlags,
    start_paths: *std.ArrayListUnmanaged([]const u8),
) !usize { // tiger:allow:usize-arch returns slice index cursor; Zig indexing requires usize
    var expr_start: usize = 0; // tiger:allow:usize-arch slice index cursor
    var seen_end_of_options = false;
    while (expr_start < args.len) {
        const arg = args[expr_start];
        if (!seen_end_of_options and start_paths.items.len == 0 and std.mem.eql(u8, arg, "--")) {
            // `--` ends only the leading -H/-L/-P options, and only
            // before any start path. `find . --` is an unknown predicate.
            seen_end_of_options = true;
            expr_start += 1;
        } else if (!seen_end_of_options and
            (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "-follow")))
        {
            flags.follow_symlinks = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-H")) {
            flags.follow_cmdline_symlinks = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-P")) {
            // -P: never follow symlinks (default behavior); accept as no-op
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-E")) {
            flags.extended_regex = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-s")) {
            // -s: traverse in alphabetical (sorted) order
            flags.sorted = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-depth")) {
            // Check if followed by a number: -depth N is an expression primary
            if (expr_start + 1 < args.len) {
                if (std.fmt.parseInt(u32, args[expr_start + 1], 10)) |_| {
                    // -depth N: this is an expression, stop collecting globals
                    break;
                } else |_| {}
            }
            flags.depth_first = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-d")) {
            flags.depth_first = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-x")) {
            flags.xdev = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-X")) {
            flags.xargs_safe = true;
            expr_start += 1;
        } else if (!seen_end_of_options and std.mem.eql(u8, arg, "-f")) {
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
    assert(expr_start <= args.len);
    assert(start_paths.items.len <= args.len);
    return expr_start;
}

/// Pre-scan expression args for depth/xdev globals (-maxdepth/-mindepth/-depth/
/// -d/-xdev/-mount and the readdir-race no-ops), mutating `flags`. Keeps the
/// error-emitting branches identical to the original inline loop.
/// Parse the numeric argument to a depth flag (-maxdepth/-mindepth) at args[i].
/// The value lives at args[i + 1]; reports a missing/invalid argument error.
fn parseArgs_parseDepthArg(
    allocator: Allocator,
    args: []const []const u8,
    i: usize, // tiger:allow:usize-arch slice index cursor
    flag: []const u8,
    stderr: anytype,
) !u32 {
    assert(i < args.len);
    if (i + 1 >= args.len) {
        common.printErrorWithProgram(
            allocator,
            stderr,
            prog_name,
            "missing argument to '{s}'",
            .{flag},
        );
        return error.MissingArgument;
    }
    return std.fmt.parseInt(u32, args[i + 1], 10) catch {
        common.printErrorWithProgram(
            allocator,
            stderr,
            prog_name,
            "invalid argument '{s}' to '{s}'",
            .{ args[i + 1], flag },
        );
        return error.InvalidExpression;
    };
}

/// Predicates whose next argv token is an argument, not a predicate.
/// The depth prescan must skip that token so `-name --help` does not
/// look like predicate-position `--help`.
fn parseArgs_prescanTakesArg(arg: []const u8) bool {
    std.debug.assert(arg.len > 0);
    const one_arg = [_][]const u8{
        "-name",   "-iname",      "-path",   "-wholename",
        "-ipath",  "-iwholename", "-ilname", "-lname",
        "-type",   "-regex",      "-iregex", "-size",
        "-perm",   "-amin",       "-cmin",   "-mmin",
        "-atime",  "-ctime",      "-mtime",  "-user",
        "-group",  "-uid",        "-gid",    "-printf",
        "-fstype", "-links",      "-inum",   "-samefile",
        "-anewer", "-cnewer",     "-newer",  "-used",
    };
    for (one_arg) |key| {
        if (std.mem.eql(u8, arg, key)) return true;
    }
    std.debug.assert(!std.mem.eql(u8, arg, "-name"));
    return false;
}

fn parseArgs_prescanDepthGlobals(
    allocator: Allocator,
    args: []const []const u8,
    expr_start: usize, // tiger:allow:usize-arch slice index cursor; Zig indexing requires usize
    flags: *GlobalFlags,
    stderr: anytype,
) !void {
    assert(expr_start <= args.len);
    var i: usize = expr_start; // tiger:allow:usize-arch slice index cursor
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-maxdepth")) {
            flags.maxdepth = try parseArgs_parseDepthArg(allocator, args, i, "-maxdepth", stderr);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "-mindepth")) {
            flags.mindepth = try parseArgs_parseDepthArg(allocator, args, i, "-mindepth", stderr);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "-depth")) {
            // Check if next arg is numeric: -depth N (exact depth match, not depth-first)
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(u32, args[i + 1], 10)) |_| {
                    // -depth N: exact depth matching, skip (handled by parsePrimary)
                    i += 2;
                } else |_| {
                    // -depth without numeric arg: depth-first mode
                    flags.depth_first = true;
                    i += 1;
                }
            } else {
                flags.depth_first = true;
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-d")) {
            flags.depth_first = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-xdev") or std.mem.eql(u8, args[i], "-mount")) {
            flags.xdev = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-ignore_readdir_race") or
            std.mem.eql(u8, args[i], "-noignore_readdir_race") or
            std.mem.eql(u8, args[i], "-noleaf"))
        {
            // Accept as no-ops
            i += 1;
        } else if (parseArgs_prescanTakesArg(args[i])) {
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--help") or
            std.mem.eql(u8, args[i], "--version"))
        {
            // Sequential GNU parse: predicate-position --help/--version
            // must run before later -maxdepth validation. A `--help`
            // consumed as a primary argument is skipped above.
            break;
        } else {
            i += 1;
        }
    }
    assert(i <= args.len);
    assert(i >= expr_start);
}

/// Wrap an expression with an implicit -print action via an AND node, matching
/// find's default behavior when the expression contains no explicit action.
fn parseArgs_wrapImplicitPrint(allocator: Allocator, final_expr: *Expression) !*Expression {
    const print_expr = try allocExpr(allocator, .print, .{ .none = {} });
    return try allocExpr(
        allocator,
        .and_expr,
        .{ .binary = .{ .left = final_expr, .right = print_expr } },
    );
}

fn parseArgs(allocator: Allocator, args: []const []const u8, stderr: anytype) !FindConfig {
    var start_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer start_paths.deinit(allocator);

    var flags = GlobalFlags{};

    // Collect starting paths and global options before expressions.
    const expr_start = try parseArgs_collectLeadingGlobals(allocator, args, &flags, &start_paths);
    assert(expr_start <= args.len);

    if (start_paths.items.len == 0) {
        try start_paths.append(allocator, ".");
    }
    assert(start_paths.items.len >= 1);

    // Pre-scan for global options within expression args.
    try parseArgs_prescanDepthGlobals(allocator, args, expr_start, &flags, stderr);

    // Parse expression tree
    var pos: usize = expr_start;
    var has_action = false;
    var pctx = ParseContext{ .allocator = allocator, .extended_regex = flags.extended_regex };
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
        flags.depth_first = true;
    }

    // -follow in expression position also enables symlink following
    for (args[expr_start..]) |a| {
        if (std.mem.eql(u8, a, "-follow")) {
            flags.follow_symlinks = true;
            break;
        }
    }

    // If no action, wrap with implicit -print
    const result_expr = if (!has_action)
        try parseArgs_wrapImplicitPrint(allocator, final_expr)
    else
        final_expr;

    const paths_slice = try allocator.dupe([]const u8, start_paths.items);

    return FindConfig{
        .start_paths = paths_slice,
        .expr = result_expr,
        .maxdepth = flags.maxdepth,
        .mindepth = flags.mindepth,
        .depth_first = flags.depth_first,
        .follow_symlinks = flags.follow_symlinks,
        .follow_cmdline_symlinks = flags.follow_cmdline_symlinks,
        .has_action = has_action,
        .xdev = flags.xdev,
        .xargs_safe = flags.xargs_safe,
        .sorted = flags.sorted,
    };
}

/// Walk the expression tree with an explicit heap-backed stack (no recursion)
/// and report whether any node is a `.delete`. Preserves the original pre-order,
/// left-before-right visit order and short-circuits on the first `.delete`.
fn exprContainsDelete(expr: *const Expression) bool {
    // Bound the walk well above any practical tree size; a left-leaning
    // implicit-AND chain of N tokens yields N nodes (tests reach 200000).
    const max_nodes: usize = 1_000_000; // tiger:allow:usize-arch node visit cap
    var stack: std.ArrayListUnmanaged(*const Expression) = .empty;
    defer stack.deinit(std.heap.page_allocator);

    stack.append(std.heap.page_allocator, expr) catch return false;
    var visited: usize = 0; // tiger:allow:usize-arch counter against node cap

    while (stack.items.len > 0) {
        assert(stack.items.len > 0);
        visited += 1;
        assert(visited <= max_nodes);

        const node = stack.pop().?;
        switch (node.tag) {
            .delete => return true,
            .and_expr, .or_expr => {
                // Push right first so the left child is popped (visited) first.
                stack.append(std.heap.page_allocator, node.data.binary.right) catch return false;
                stack.append(std.heap.page_allocator, node.data.binary.left) catch return false;
            },
            .not_expr => {
                stack.append(std.heap.page_allocator, node.data.unary) catch return false;
            },
            else => {},
        }
    }

    assert(stack.items.len == 0);
    return false;
}

const ExprParseError = error{
    InvalidExpression,
    MissingArgument,
    UnmatchedParen,
    StatError,
    OutOfMemory,
    HelpRequested,
    VersionRequested,
};

/// Binary operators and the paren sentinel held on the shunting-yard operator
/// stack. AND binds tighter than OR; `.op_lparen` blocks reduction across a
/// group boundary.
const Operator = enum { op_or, op_and, op_lparen };

/// Mutable state threaded through the shunting-yard engine's token handlers.
/// Bundled into one struct so each helper stays small and takes few arguments
/// (Tiger Style inverse-hourglass) while sharing the two stacks.
const ParseState = struct {
    op_stack: std.ArrayListUnmanaged(Operator),
    val_stack: std.ArrayListUnmanaged(*Expression),
    // not_count carried with each `(` so a `-not (` wraps the whole group.
    paren_not_stack: std.ArrayListUnmanaged(usize), // tiger:allow:usize-arch -not per paren
    not_count: usize = 0, // tiger:allow:usize-arch pending -not before next operand
    expect_operand: bool = true, // true = operand position, false = operator position
};

/// One classified expression token. Mutually exclusive flags drive the engine's
/// branch selection without re-running `std.mem.eql` in every handler.
const TokenKind = struct {
    is_or: bool,
    is_and: bool,
    is_not: bool,
    is_lparen: bool,
    is_rparen: bool,
};

fn classifyToken(arg: []const u8) TokenKind {
    return .{
        .is_or = std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-or"),
        .is_and = std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-and"),
        .is_not = std.mem.eql(u8, arg, "!") or std.mem.eql(u8, arg, "-not"),
        .is_lparen = std.mem.eql(u8, arg, "("),
        .is_rparen = std.mem.eql(u8, arg, ")"),
    };
}

/// Pop one binary operator and its two operands, combine them into the matching
/// AND/OR node, and push the result. Left is popped second (deeper on the value
/// stack), so chains stay left-leaning: A op B op C => op(op(A,B),C).
fn parseReduceTop(allocator: Allocator, state: *ParseState) ExprParseError!void {
    assert(state.op_stack.items.len > 0);
    assert(state.val_stack.items.len >= 2);

    const op = state.op_stack.pop().?;
    assert(op != .op_lparen);
    const right = state.val_stack.pop().?;
    const left = state.val_stack.pop().?;
    const tag: ExprTag = if (op == .op_and) .and_expr else .or_expr;
    const node = try allocExpr(allocator, tag, .{ .binary = .{ .left = left, .right = right } });
    try state.val_stack.append(allocator, node);
}

/// Wrap `inner` in `count` `.not_expr` nodes (innermost first), reproducing the
/// right-associative `-not` chain the recursive parser built.
fn parseApplyNots(
    allocator: Allocator,
    inner: *Expression,
    count: usize, // tiger:allow:usize-arch -not depth count
) ExprParseError!*Expression {
    assert(count <= 1_000_000);
    var result = inner;
    var remaining = count; // tiger:allow:usize-arch loop counter mirroring count
    while (remaining > 0) : (remaining -= 1) {
        result = try allocExpr(allocator, .not_expr, .{ .unary = result });
    }
    assert(remaining == 0);
    if (count > 0) assert(result.tag == .not_expr);
    return result;
}

/// Reduce operators on the stack while the top has precedence >= `min_prec`,
/// stopping at a `.op_lparen` sentinel or an empty stack. AND outranks OR.
fn parseReduceWhile(
    allocator: Allocator,
    state: *ParseState,
    min_prec: u8,
) ExprParseError!void {
    assert(min_prec >= 1);
    assert(min_prec <= 2);
    while (state.op_stack.items.len > 0) {
        const top = state.op_stack.items[state.op_stack.items.len - 1];
        if (top == .op_lparen) break;
        const top_prec: u8 = if (top == .op_and) 2 else 1;
        if (top_prec < min_prec) break;
        try parseReduceTop(allocator, state);
    }
    assert(min_prec >= 1);
}

/// Full-expression parser, rewritten as an iterative shunting-yard engine so no
/// recursion (direct or mutual) remains. Drives the whole grammar
/// (OR < AND < NOT < primary|paren) and builds byte-identical trees to the old
/// recursive descent. Keeps the original name/signature: `parseArgs` calls only
/// this.
fn parseOr(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    has_action: *bool,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    var state = ParseState{ .op_stack = .empty, .val_stack = .empty, .paren_not_stack = .empty };
    defer state.op_stack.deinit(allocator);
    defer state.val_stack.deinit(allocator);
    defer state.paren_not_stack.deinit(allocator);

    // Each token drives a bounded amount of work; cap the loop accordingly.
    const max_iterations: usize = args.len * 4 + 4; // tiger:allow:usize-arch loop cap
    var iteration_count: usize = 0; // tiger:allow:usize-arch loop counter vs cap

    while (true) { // tiger:allow:unbounded-loop bounded by asserted iteration cap
        iteration_count += 1;
        assert(iteration_count <= max_iterations);
        if (pos.* >= args.len) break;

        const kind = classifyToken(args[pos.*]);
        if (state.expect_operand) {
            try parseStepOperand(allocator, args, pos, has_action, pctx, &state, kind);
        } else {
            const stop = try parseStepOperator(allocator, pos, &state, kind);
            if (stop) break; // top-level ')': stop token, left unconsumed
        }
    }

    // End of input in operand position needs a value; the recursive parser
    // returned true_expr here (and -not at end wrapped that true_expr).
    if (state.expect_operand) {
        const true_node = try allocExpr(allocator, .true_expr, .{ .none = {} });
        const wrapped = try parseApplyNots(allocator, true_node, state.not_count);
        state.not_count = 0;
        try state.val_stack.append(allocator, wrapped);
    }

    try parseDrain(allocator, &state, pctx);
    assert(state.val_stack.items.len == 1);
    assert(state.op_stack.items.len == 0);
    return state.val_stack.items[0];
}

/// Handle one token in operand position: accumulate `-not`, open a group, or
/// parse a primary (wrapping it in any pending `-not`s). A stray operator/`)`
/// flows to `parsePrimary`, preserving the old "unknown predicate" error.
fn parseStepOperand(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    has_action: *bool,
    pctx: *ParseContext,
    state: *ParseState,
    kind: TokenKind,
) ExprParseError!void {
    assert(state.expect_operand);
    if (kind.is_not) {
        state.not_count += 1;
        pos.* += 1;
    } else if (kind.is_lparen) {
        try state.paren_not_stack.append(allocator, state.not_count);
        state.not_count = 0;
        try state.op_stack.append(allocator, .op_lparen);
        pos.* += 1;
    } else {
        const primary = try parsePrimary(allocator, args, pos, has_action, pctx);
        const wrapped = try parseApplyNots(allocator, primary, state.not_count);
        state.not_count = 0;
        try state.val_stack.append(allocator, wrapped);
        state.expect_operand = false;
    }
}

/// Handle one token in operator position. Returns true when a top-level `)`
/// (no matching `(`) should stop the parse, left unconsumed for the caller.
/// Anything that is not an operator/`)` triggers an implicit AND and is then
/// reprocessed as an operand (no `pos` advance).
fn parseStepOperator(
    allocator: Allocator,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    state: *ParseState,
    kind: TokenKind,
) ExprParseError!bool {
    assert(!state.expect_operand);
    if (kind.is_or) {
        try parseReduceWhile(allocator, state, 1);
        try state.op_stack.append(allocator, .op_or);
        state.expect_operand = true;
        pos.* += 1;
    } else if (kind.is_and) {
        try parseReduceWhile(allocator, state, 2);
        try state.op_stack.append(allocator, .op_and);
        state.expect_operand = true;
        pos.* += 1;
    } else if (kind.is_rparen) {
        if (!parseHasLparen(state)) return true;
        try parseReduceWhile(allocator, state, 1);
        _ = state.op_stack.pop(); // discard the .op_lparen sentinel
        try parseCloseGroup(allocator, state);
        pos.* += 1;
    } else {
        try parseReduceWhile(allocator, state, 2);
        try state.op_stack.append(allocator, .op_and);
        state.expect_operand = true;
    }
    return false;
}

/// Drain the operator stack at end of input, combining every pending binary
/// operator. An `.op_lparen` here means a group was never closed.
fn parseDrain(allocator: Allocator, state: *ParseState, pctx: *ParseContext) ExprParseError!void {
    assert(state.val_stack.items.len >= 1);
    while (state.op_stack.items.len > 0) {
        const top = state.op_stack.items[state.op_stack.items.len - 1];
        if (top == .op_lparen) {
            pctx.setError("missing closing ')'", .{});
            return error.UnmatchedParen;
        }
        try parseReduceTop(allocator, state);
    }
    assert(state.op_stack.items.len == 0);
}

/// Whether any `.op_lparen` sentinel is currently on the operator stack. A `)`
/// with no matching `(` is a top-level stop token, left unconsumed.
fn parseHasLparen(state: *const ParseState) bool {
    var index: usize = 0; // tiger:allow:usize-arch slice index
    while (index < state.op_stack.items.len) : (index += 1) {
        if (state.op_stack.items[index] == .op_lparen) return true;
    }
    return false;
}

/// Apply the `-not` count captured at the matching `(` to the group's reduced
/// value, mirroring `-not ( ... )` wrapping the whole group in the old parser.
fn parseCloseGroup(allocator: Allocator, state: *ParseState) ExprParseError!void {
    assert(state.paren_not_stack.items.len > 0);
    assert(state.val_stack.items.len > 0);

    const group_nots = state.paren_not_stack.pop().?;
    const group_val = state.val_stack.pop().?;
    const wrapped = try parseApplyNots(allocator, group_val, group_nots);
    try state.val_stack.append(allocator, wrapped);
}

/// Consume exec-style argv after a `-exec`/`-ok`/`-execdir`/`-okdir` predicate
/// until a `;` terminator (or `+` when `plus_allowed`). Duplicates the argv on
/// success; sets the missing-arg error and returns null otherwise. Mirrors the
/// four near-identical inner loops the recursive parser repeated.
fn parsePrimary_collectExecArgs(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    plus_allowed: bool,
    is_batch_out: *bool,
    pctx: *ParseContext,
) ExprParseError!?[]const []const u8 {
    assert(pos.* <= args.len);
    assert(predicate.len > 0);
    is_batch_out.* = false;
    var exec_args = std.ArrayListUnmanaged([]const u8).empty;
    defer exec_args.deinit(allocator);

    while (pos.* < args.len) {
        if (std.mem.eql(u8, args[pos.*], ";")) {
            pos.* += 1;
            break;
        }
        if (plus_allowed and std.mem.eql(u8, args[pos.*], "+")) {
            // Batch mode: {} must be last arg before +
            is_batch_out.* = true;
            pos.* += 1;
            break;
        }
        try exec_args.append(allocator, args[pos.*]);
        pos.* += 1;
    } else {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }

    if (exec_args.items.len == 0) {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }
    assert(exec_args.items.len > 0);
    return try allocator.dupe([]const u8, exec_args.items);
}

/// Resolve the Y reference timestamp for a `-newerXY` predicate from `ref_path`.
/// 'B' uses birth time (falling back to mtime); otherwise the matching a/c/m
/// field. Sets the not-found error and returns null on a stat failure.
fn parsePrimary_newerXYRefTime(
    ref_path: []const u8,
    y_field: u8,
    pctx: *ParseContext,
) ExprParseError!?i64 {
    assert(y_field != 0);
    if (y_field == 'B') {
        return getBirthTime(ref_path) orelse blk: {
            const ref_stat = doStat(ref_path, false) catch {
                pctx.setError("'{s}': No such file or directory", .{ref_path});
                return error.InvalidExpression;
            };
            break :blk getMtime(ref_stat);
        };
    }
    const ref_stat = doStat(ref_path, false) catch {
        pctx.setError("'{s}': No such file or directory", .{ref_path});
        return error.InvalidExpression;
    };
    assert(y_field != 'B');
    return switch (y_field) {
        'a' => getAtime(ref_stat),
        'c' => getCtime(ref_stat),
        'm' => getMtime(ref_stat),
        else => getMtime(ref_stat),
    };
}

/// Handle global-option and accepted-no-op predicates: -maxdepth/-mindepth,
/// -depth, -d, -follow, -ignore_readdir_race, -noignore_readdir_race, -noleaf.
/// Returns null when `arg` is not one of these (fall through to next group).
fn parsePrimary_globalsAndNoops(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    const entry_pos = pos.*;
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
    if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-follow") or
        std.mem.eql(u8, arg, "-ignore_readdir_race") or
        std.mem.eql(u8, arg, "-noignore_readdir_race") or
        std.mem.eql(u8, arg, "-noleaf"))
    {
        // -follow in expression position (deprecated GNU/macOS form); the
        // others are accepted no-ops.
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }
    assert(pos.* == entry_pos);
    return null;
}

/// Handle name/path/type and pattern/regex/symlink predicates: -name, -iname,
/// -path/-wholename, -type, -ipath/-iwholename, -regex, -iregex, -ilname,
/// -lname. Returns null when `arg` is none of these.
fn parsePrimary_namePathType(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    if (std.mem.eql(u8, arg, "-name")) {
        return try parsePrimary_takePattern(allocator, args, pos, "-name", .name, pctx);
    }
    if (std.mem.eql(u8, arg, "-iname")) {
        return try parsePrimary_takePattern(allocator, args, pos, "-iname", .iname, pctx);
    }
    if (std.mem.eql(u8, arg, "-path") or std.mem.eql(u8, arg, "-wholename")) {
        return try parsePrimary_takePattern(allocator, args, pos, "-path", .path_match, pctx);
    }
    if (std.mem.eql(u8, arg, "-ipath") or std.mem.eql(u8, arg, "-iwholename")) {
        return try parsePrimary_takePattern(allocator, args, pos, "-ipath", .ipath, pctx);
    }
    if (std.mem.eql(u8, arg, "-ilname")) {
        return try parsePrimary_takePattern(allocator, args, pos, "-ilname", .ilname, pctx);
    }
    if (std.mem.eql(u8, arg, "-lname")) {
        return try parsePrimary_takePattern(allocator, args, pos, "-lname", .lname, pctx);
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
    if (std.mem.eql(u8, arg, "-regex")) {
        return try parsePrimary_takeRegex(
            allocator,
            args,
            pos,
            "-regex",
            false,
            .regex_match,
            pctx,
        );
    }
    if (std.mem.eql(u8, arg, "-iregex")) {
        return try parsePrimary_takeRegex(
            allocator,
            args,
            pos,
            "-iregex",
            true,
            .iregex_match,
            pctx,
        );
    }
    return null;
}

/// Consume the required pattern argument after a string-pattern predicate and
/// build the node with `tag`. Factors out the identical missing-arg + dupe-free
/// shape shared by -name/-iname/-path/-ipath/-ilname/-lname.
fn parsePrimary_takePattern(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    tag: ExprTag,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
    assert(predicate.len > 0);
    pos.* += 1;
    if (pos.* >= args.len) {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }
    const pattern = args[pos.*];
    pos.* += 1;
    return allocExpr(allocator, tag, .{ .pattern = pattern });
}

/// Consume the required pattern argument after -regex/-iregex, compile it, and
/// build the node with `tag`. Factors out the shared shape of both regex forms.
fn parsePrimary_takeRegex(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    ignore_case: bool,
    tag: ExprTag,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
    assert(predicate.len > 0);
    pos.* += 1;
    if (pos.* >= args.len) {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }
    const pattern = args[pos.*];
    pos.* += 1;
    const regex = compileRegex(allocator, pattern, ignore_case, pctx.extended_regex) orelse {
        pctx.setError("invalid regular expression '{s}'", .{pattern});
        return error.InvalidExpression;
    };
    return allocExpr(allocator, tag, .{ .regex_ptr = regex });
}

/// Consume the required time argument after a `parseMtime`-style predicate and
/// build a `.time` node with `tag`. Shared shape for -mtime/-atime/-ctime/
/// -links/-mmin/-inum/-amin/-cmin/-Bmin/-Btime.
fn parsePrimary_takeTime(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    tag: ExprTag,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
    assert(predicate.len > 0);
    pos.* += 1;
    if (pos.* >= args.len) {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }
    const te = parseMtime(args[pos.*]) catch {
        pctx.setError("invalid argument '{s}' to '{s}'", .{ args[pos.*], predicate });
        return error.InvalidExpression;
    };
    pos.* += 1;
    return allocExpr(allocator, tag, .{ .time = te });
}

/// Handle -size, -empty, and -perm. Returns null when `arg` is none of these.
fn parsePrimary_sizeEmptyPerm(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
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
    return null;
}

/// Handle the day/minute time-comparison predicates: -mtime, -atime, -ctime,
/// -links, -Btime, -mmin, -inum, -amin, -cmin, -Bmin. Returns null otherwise.
fn parsePrimary_timeCompare(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    if (std.mem.eql(u8, arg, "-mtime")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-mtime", .mtime, pctx);
    }
    if (std.mem.eql(u8, arg, "-atime")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-atime", .atime, pctx);
    }
    if (std.mem.eql(u8, arg, "-ctime")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-ctime", .ctime, pctx);
    }
    if (std.mem.eql(u8, arg, "-links")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-links", .links, pctx);
    }
    if (std.mem.eql(u8, arg, "-Btime")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-Btime", .btime_stub, pctx);
    }
    if (std.mem.eql(u8, arg, "-mmin")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-mmin", .mmin, pctx);
    }
    if (std.mem.eql(u8, arg, "-inum")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-inum", .inum, pctx);
    }
    if (std.mem.eql(u8, arg, "-amin")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-amin", .amin, pctx);
    }
    if (std.mem.eql(u8, arg, "-cmin")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-cmin", .cmin, pctx);
    }
    if (std.mem.eql(u8, arg, "-Bmin")) {
        return try parsePrimary_takeTime(allocator, args, pos, "-Bmin", .bmin_stub, pctx);
    }
    return null;
}

/// Consume the required name argument after a name-string predicate and build a
/// `.name_str` node with `tag`. Shared shape for -user/-group/-fstype/-flags.
fn parsePrimary_takeNameStr(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    tag: ExprTag,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
    assert(predicate.len > 0);
    pos.* += 1;
    if (pos.* >= args.len) {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }
    const name_str = args[pos.*];
    pos.* += 1;
    return allocExpr(allocator, tag, .{ .name_str = name_str });
}

/// Handle owner/ID predicates: -user, -group, -nouser, -nogroup, -gid, -uid,
/// -fstype, -flags. Returns null when `arg` is none of these.
fn parsePrimary_ownerAndIds(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    if (std.mem.eql(u8, arg, "-user")) {
        return try parsePrimary_takeNameStr(allocator, args, pos, "-user", .user, pctx);
    }
    if (std.mem.eql(u8, arg, "-group")) {
        return try parsePrimary_takeNameStr(allocator, args, pos, "-group", .group, pctx);
    }
    if (std.mem.eql(u8, arg, "-fstype")) {
        return try parsePrimary_takeNameStr(allocator, args, pos, "-fstype", .fstype, pctx);
    }
    if (std.mem.eql(u8, arg, "-flags")) {
        return try parsePrimary_takeNameStr(allocator, args, pos, "-flags", .flags, pctx);
    }
    if (std.mem.eql(u8, arg, "-nouser")) {
        pos.* += 1;
        return allocExpr(allocator, .nouser, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-nogroup")) {
        pos.* += 1;
        return allocExpr(allocator, .nogroup, .{ .none = {} });
    }
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
    return null;
}

/// Handle action predicates: -print, -print0, -delete, -ls, -quit, -printf,
/// -false, -true, -prune, -xdev/-mount. Returns null when `arg` is none.
fn parsePrimary_actions(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    has_action: *bool,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
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
    if (std.mem.eql(u8, arg, "-ls")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .ls_action, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-quit")) {
        pos.* += 1;
        has_action.* = true;
        return allocExpr(allocator, .quit_action, .{ .none = {} });
    }
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
    if (std.mem.eql(u8, arg, "-false")) {
        pos.* += 1;
        return allocExpr(allocator, .false_expr, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-true")) {
        pos.* += 1;
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-prune")) {
        pos.* += 1;
        return allocExpr(allocator, .prune, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-xdev") or std.mem.eql(u8, arg, "-mount")) {
        pos.* += 1;
        return allocExpr(allocator, .xdev, .{ .none = {} });
    }
    return null;
}

/// Collect exec-style argv for one exec-family predicate and build its node.
/// `plus_allowed` enables `{} +` batch mode; when a batch is collected the node
/// uses `batch_tag`, otherwise `single_tag` (equal for -ok/-okdir). Sets
/// `has_action` on success. Shared shape for all four exec-family predicates.
fn parsePrimary_takeExec(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    plus_allowed: bool,
    batch_tag: ExprTag,
    single_tag: ExprTag,
    has_action: *bool,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
    assert(predicate.len > 0);
    pos.* += 1;
    var is_batch = false;
    const argv = try parsePrimary_collectExecArgs(
        allocator,
        args,
        pos,
        predicate,
        plus_allowed,
        &is_batch,
        pctx,
    ) orelse unreachable;
    assert(argv.len > 0);
    has_action.* = true;
    if (is_batch) {
        return allocExpr(allocator, batch_tag, .{
            .exec_data = .{ .argv = argv, .batch = true },
        });
    }
    return allocExpr(allocator, single_tag, .{ .exec_data = .{ .argv = argv } });
}

/// Handle the exec family: -exec, -ok, -execdir, -okdir. The `+` batch
/// terminator is accepted only by -exec/-execdir. Returns null otherwise.
fn parsePrimary_execFamily(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    has_action: *bool,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    if (std.mem.eql(u8, arg, "-exec")) {
        return try parsePrimary_takeExec(
            allocator,
            args,
            pos,
            "-exec",
            true,
            .exec_batch,
            .exec_cmd,
            has_action,
            pctx,
        );
    }
    if (std.mem.eql(u8, arg, "-execdir")) {
        return try parsePrimary_takeExec(
            allocator,
            args,
            pos,
            "-execdir",
            true,
            .execdir_batch,
            .execdir,
            has_action,
            pctx,
        );
    }
    if (std.mem.eql(u8, arg, "-ok")) {
        return try parsePrimary_takeExec(
            allocator,
            args,
            pos,
            "-ok",
            false,
            .ok,
            .ok,
            has_action,
            pctx,
        );
    }
    if (std.mem.eql(u8, arg, "-okdir")) {
        return try parsePrimary_takeExec(
            allocator,
            args,
            pos,
            "-okdir",
            false,
            .okdir_stub,
            .okdir_stub,
            has_action,
            pctx,
        );
    }
    return null;
}

/// Consume the required reference path after a `-newer`/`-anewer`/`-cnewer`/
/// `-mnewer` predicate, stat it, and build a `.newer_mtime` node with `tag`.
fn parsePrimary_takeNewerRef(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    predicate: []const u8,
    tag: ExprTag,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
    assert(predicate.len > 0);
    pos.* += 1;
    if (pos.* >= args.len) {
        pctx.setError("missing argument to '{s}'", .{predicate});
        return error.MissingArgument;
    }
    const ref_path = args[pos.*];
    pos.* += 1;
    const ref_stat = doStat(ref_path, true) catch {
        pctx.setError("cannot stat '{s}'", .{ref_path});
        return error.StatError;
    };
    const ref_mtime = getMtime(ref_stat);
    return allocExpr(allocator, tag, .{ .newer_mtime = ref_mtime });
}

/// Consume the reference path after `-Bnewer`, resolve its birth time (falling
/// back to mtime), and build a `.bnewer_stub` node.
fn parsePrimary_takeBnewer(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
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

/// Consume the reference path after `-samefile`, stat it, and build a
/// `.samefile` node carrying its (inode, device) pair.
fn parsePrimary_takeSamefile(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    pctx: *ParseContext,
) ExprParseError!*Expression {
    assert(pos.* < args.len);
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

/// Consume the reference path after `-newerXY`, resolve the Y timestamp, and
/// build a `.newerxy_stub` node carrying the ref time and X field.
fn parsePrimary_takeNewerXY(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(arg.len == 8);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    const x_field = arg[6];
    const y_field = arg[7];
    pos.* += 1;
    if (pos.* >= args.len) {
        pctx.setError("missing argument to '{s}'", .{arg});
        return error.MissingArgument;
    }
    const ref_path = args[pos.*];
    pos.* += 1;
    const ref_time = try parsePrimary_newerXYRefTime(ref_path, y_field, pctx) orelse return null;
    return allocExpr(allocator, .newerxy_stub, .{ .newerxy_data = .{
        .ref_time = ref_time,
        .x_field = x_field,
    } });
}

/// Handle the reference-time family: -newer, -anewer, -cnewer, -mnewer,
/// -Bnewer, -newerXY, -samefile. Returns null when `arg` is none of these.
fn parsePrimary_newerFamily(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    if (std.mem.eql(u8, arg, "-newer")) {
        return try parsePrimary_takeNewerRef(allocator, args, pos, "-newer", .newer, pctx);
    }
    if (std.mem.eql(u8, arg, "-anewer")) {
        return try parsePrimary_takeNewerRef(allocator, args, pos, "-anewer", .anewer, pctx);
    }
    if (std.mem.eql(u8, arg, "-cnewer")) {
        return try parsePrimary_takeNewerRef(allocator, args, pos, "-cnewer", .cnewer, pctx);
    }
    if (std.mem.eql(u8, arg, "-mnewer")) {
        // -mnewer: alias for -newer (modification time newer than FILE)
        return try parsePrimary_takeNewerRef(allocator, args, pos, "-mnewer", .newer, pctx);
    }
    if (std.mem.eql(u8, arg, "-Bnewer")) {
        return try parsePrimary_takeBnewer(allocator, args, pos, pctx);
    }
    if (std.mem.eql(u8, arg, "-samefile")) {
        return try parsePrimary_takeSamefile(allocator, args, pos, pctx);
    }
    // -newerXY: compare timestamps. Matches -newerXY where X,Y are one of:
    // a, B, c, m, t (8 chars total).
    if (arg.len == 8 and std.mem.startsWith(u8, arg, "-newer")) {
        return try parsePrimary_takeNewerXY(allocator, args, pos, arg, pctx);
    }
    return null;
}

/// Handle the always-false/stub predicates: -acl, -sparse, -xattr, -xattrname.
/// Returns null when `arg` is none of these.
fn parsePrimary_stubs(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    arg: []const u8,
    pctx: *ParseContext,
) ExprParseError!?*Expression {
    assert(pos.* < args.len);
    assert(std.mem.eql(u8, arg, args[pos.*]));
    if (std.mem.eql(u8, arg, "-acl")) {
        pos.* += 1;
        return allocExpr(allocator, .acl_stub, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-sparse")) {
        pos.* += 1;
        return allocExpr(allocator, .sparse_stub, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-xattr")) {
        pos.* += 1;
        return allocExpr(allocator, .xattr_stub, .{ .none = {} });
    }
    if (std.mem.eql(u8, arg, "-xattrname")) {
        pos.* += 1;
        if (pos.* >= args.len) {
            pctx.setError("missing argument to '-xattrname'", .{});
            return error.MissingArgument;
        }
        pos.* += 1; // consume value
        return allocExpr(allocator, .xattrname_stub, .{ .none = {} });
    }
    return null;
}

fn parsePrimary(
    allocator: Allocator,
    args: []const []const u8,
    pos: *usize, // tiger:allow:usize-arch slice index cursor; Zig slice indexing requires usize
    has_action: *bool,
    pctx: *ParseContext,
) ExprParseError!*Expression {
    if (pos.* >= args.len) {
        return allocExpr(allocator, .true_expr, .{ .none = {} });
    }
    const arg = args[pos.*];
    assert(pos.* < args.len);

    // GNU treats `--help`/`--version` as options in predicate position,
    // not as unknown predicates. As a primary argument they are consumed
    // by that primary (`-name --help`) and never reach this check.
    if (std.mem.eql(u8, arg, "--help")) return error.HelpRequested;
    if (std.mem.eql(u8, arg, "--version")) return error.VersionRequested;

    if (try parsePrimary_globalsAndNoops(allocator, args, pos, arg)) |e| return e;
    if (try parsePrimary_namePathType(allocator, args, pos, arg, pctx)) |e| return e;
    if (try parsePrimary_sizeEmptyPerm(allocator, args, pos, arg, pctx)) |e| return e;
    if (try parsePrimary_timeCompare(allocator, args, pos, arg, pctx)) |e| return e;
    if (try parsePrimary_ownerAndIds(allocator, args, pos, arg, pctx)) |e| return e;
    if (try parsePrimary_actions(allocator, args, pos, arg, has_action, pctx)) |e| return e;
    if (try parsePrimary_execFamily(allocator, args, pos, arg, has_action, pctx)) |e| return e;
    if (try parsePrimary_newerFamily(allocator, args, pos, arg, pctx)) |e| return e;
    if (try parsePrimary_stubs(allocator, args, pos, arg, pctx)) |e| return e;

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

    fn flushExec(
        self: *BatchContext,
        io: std.Io,
        allocator: Allocator,
        stdout: anytype,
        stderr: anytype,
    ) bool {
        _ = stderr;
        if (self.exec_template == null or self.exec_paths.items.len == 0) return true;
        const template = self.exec_template.?;
        assert(self.exec_paths.items.len > 0);

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

    fn flushExecdir(
        self: *BatchContext,
        io: std.Io,
        allocator: Allocator,
        stdout: anytype,
        stderr: anytype,
    ) bool {
        _ = stderr;
        if (self.execdir_template == null or self.execdir_paths.items.len == 0) return true;
        const template = self.execdir_template.?;
        assert(self.execdir_paths.items.len > 0);

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

// Frame kinds for the explicit work stack that replaces evaluate()'s former
// call-stack recursion. Each variant mirrors a return address the recursive
// version relied on: `eval` visits a node, the others are continuations that
// consume a pending boolean result off the value stack.
const FrameKind = enum { eval, not_result, and_right, or_right };
const Frame = union(FrameKind) {
    // Visit this node: leaves produce a value, operators push continuations.
    eval: *const Expression,
    // Pop one value, invert it, push the result. -not never short-circuits.
    not_result: void,
    // Pop the left value; if false push false (right suppressed), else eval right.
    and_right: *const Expression,
    // Pop the left value; if true push true (right suppressed), else eval right.
    or_right: *const Expression,
};

// Evaluate the expression tree for one path using an explicit, heap-backed work
// stack instead of call-stack recursion, so deeply-nested expressions (e.g.
// 20000 implicitly-ANDed primaries) do not overflow the thread stack. Visit
// order, short-circuiting, side-effect order, and out-params stay identical to
// the former recursive evaluator; only the and/or/not arms became stack-driven.
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
    var work_stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer work_stack.deinit(allocator);
    var value_stack: std.ArrayListUnmanaged(bool) = .empty;
    defer value_stack.deinit(allocator);

    // On allocation failure we cannot finish evaluating; surface it via
    // had_error and report the node as non-matching, mirroring how the leaf
    // arms treat their own OOM. Callers only observe had_error and pruned.
    const ctx: EvalContext = .{
        .io = io,
        .path = path,
        .basename = basename,
        .stat_buf = stat_buf,
        .kind = kind,
        .now = now,
        .depth = depth,
        .allocator = allocator,
        .had_error = had_error,
        .pruned = pruned,
        .batch_ctx = batch_ctx,
    };
    evaluateLoop(&ctx, &work_stack, &value_stack, expr, stdout, stderr) catch {
        had_error.* = true;
        return false;
    };

    assert(work_stack.items.len == 0);
    assert(value_stack.items.len == 1);
    return value_stack.items[0];
}

// Bound the work stack so the loop is visibly finite per Tiger Style; (1<<20)
// frames comfortably cover any expression a user can construct.
const evaluate_work_bound: usize = 1 << 20;

// The per-path inputs shared by every frame, bundled so the stack driver stays
// under the 70-line limit and the boolean-operator handling reads as one loop.
const EvalContext = struct {
    io: std.Io,
    path: []const u8,
    basename: []const u8,
    stat_buf: StatInfo,
    kind: FileType,
    now: i64,
    depth: u32,
    allocator: Allocator,
    had_error: *bool,
    pruned: *bool,
    batch_ctx: ?*BatchContext,
};

// Drive the explicit work stack to completion. Returns error.OutOfMemory if a
// stack push fails; evaluate() maps that to had_error and a non-match.
fn evaluateLoop(
    ctx: *const EvalContext,
    work_stack: *std.ArrayListUnmanaged(Frame),
    value_stack: *std.ArrayListUnmanaged(bool),
    expr: *const Expression,
    stdout: anytype,
    stderr: anytype,
) error{OutOfMemory}!void {
    const allocator = ctx.allocator;
    try evaluatePush(work_stack, allocator, .{ .eval = expr });
    while (work_stack.items.len > 0) {
        // The while-condition guarantees a frame; state it so the invariant
        // the loop body relies on is explicit, not just implied.
        assert(work_stack.items.len > 0);
        switch (work_stack.pop().?) {
            .eval => |node| switch (node.tag) {
                .and_expr => {
                    const pair = node.data.binary;
                    try evaluatePush(work_stack, allocator, .{ .and_right = pair.right });
                    try evaluatePush(work_stack, allocator, .{ .eval = pair.left });
                },
                .or_expr => {
                    const pair = node.data.binary;
                    try evaluatePush(work_stack, allocator, .{ .or_right = pair.right });
                    try evaluatePush(work_stack, allocator, .{ .eval = pair.left });
                },
                .not_expr => {
                    try evaluatePush(work_stack, allocator, .{ .not_result = {} });
                    try evaluatePush(work_stack, allocator, .{ .eval = node.data.unary });
                },
                else => {
                    const result = evaluateLeafCtx(ctx, node, stdout, stderr);
                    try value_stack.append(allocator, result);
                },
            },
            // -not never short-circuits: invert the single child's result. The
            // child's eval frame always ran first, so a value must be pending.
            .not_result => {
                assert(value_stack.items.len > 0);
                try value_stack.append(allocator, !value_stack.pop().?);
            },
            // Short-circuit: a false left suppresses the right child's side
            // effects, so push false instead of scheduling eval(right). The
            // left operand's eval frame always ran first, so its value is here.
            .and_right => |right| {
                assert(value_stack.items.len > 0);
                if (value_stack.pop().?) {
                    try evaluatePush(work_stack, allocator, .{ .eval = right });
                } else {
                    try value_stack.append(allocator, false);
                }
            },
            // Short-circuit: a true left suppresses the right child's side
            // effects, so push true instead of scheduling eval(right). The left
            // operand's eval frame always ran first, so its value is here.
            .or_right => |right| {
                assert(value_stack.items.len > 0);
                if (value_stack.pop().?) {
                    try value_stack.append(allocator, true);
                } else {
                    try evaluatePush(work_stack, allocator, .{ .eval = right });
                }
            },
        }
    }
    // The driver leaves the work stack drained and exactly one result pending.
    assert(work_stack.items.len == 0);
    assert(value_stack.items.len >= 1);
}

// Append one frame to the work stack, asserting the Tiger Style bound first.
fn evaluatePush(
    work_stack: *std.ArrayListUnmanaged(Frame),
    allocator: Allocator,
    frame: Frame,
) error{OutOfMemory}!void {
    assert(work_stack.items.len < evaluate_work_bound);
    try work_stack.append(allocator, frame);
    assert(work_stack.items.len <= evaluate_work_bound);
}

// Unpack the bundled per-path context and evaluate one leaf node. Keeps the
// driver loop's call site within the 100-column limit while preserving the
// exact leaf semantics (side effects, had_error, pruned, batch_ctx).
fn evaluateLeafCtx(
    ctx: *const EvalContext,
    node: *const Expression,
    stdout: anytype,
    stderr: anytype,
) bool {
    assert(node.tag != .and_expr);
    assert(node.tag != .or_expr);
    return evaluateLeaf(
        ctx.io,
        node,
        ctx.path,
        ctx.basename,
        ctx.stat_buf,
        ctx.kind,
        ctx.now,
        ctx.depth,
        ctx.allocator,
        stdout,
        stderr,
        ctx.had_error,
        ctx.pruned,
        ctx.batch_ctx,
    );
}

/// Compare a file size against a `-size` predicate. Byte units compare raw
/// bytes; block-based units convert with ceiling division (matching GNU find).
fn evaluateLeaf_size(stat_buf: StatInfo, sz: SizeExpr) bool {
    const file_size: u64 = @intCast(@max(0, stat_buf.size));
    if (sz.unit == .bytes) {
        // For 'c' suffix, compare raw bytes directly
        const target_bytes = sz.value;
        return switch (sz.cmp) {
            .exactly => file_size == target_bytes,
            .greater_than => file_size > target_bytes,
            .less_than => file_size < target_bytes,
        };
    }
    // For block-based units, convert file size to unit count using ceiling
    // division, matching GNU find behavior.
    const unit_size: u64 = switch (sz.unit) {
        .bytes => unreachable,
        .words => 2,
        .blocks => 512,
        .kilobytes => 1024,
        .megabytes => 1048576,
        .gigabytes => 1073741824,
    };
    assert(sz.unit != .bytes);
    assert(unit_size != 0);
    const file_units = if (file_size == 0) 0 else (file_size + unit_size - 1) / unit_size;
    return switch (sz.cmp) {
        .exactly => file_units == sz.value,
        .greater_than => file_units > sz.value,
        .less_than => file_units < sz.value,
    };
}

/// Compare a timestamp's age in days against a `-mtime`/-atime/-ctime/-Btime
/// predicate. Ages at or before `now` are clamped to 0 (negative-age files).
fn evaluateLeaf_ageDays(now: i64, file_time: i64, te: TimeExpr) bool {
    const age_secs = now - file_time;
    const age_days: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 86400) else 0;
    // Negative space: non-positive ages clamp to 0. Positive space: age in days
    // never exceeds age in seconds.
    if (age_secs <= 0) assert(age_days == 0);
    if (age_secs > 0) assert(age_days <= @as(u64, @intCast(age_secs)));
    return switch (te.cmp) {
        .exactly => age_days == te.days,
        .greater_than => age_days > te.days,
        .less_than => age_days < te.days,
    };
}

/// Compare a timestamp's age in minutes against a `-mmin`/-amin/-cmin/-Bmin
/// predicate. Ages at or before `now` are clamped to 0 (negative-age files).
fn evaluateLeaf_ageMins(now: i64, file_time: i64, te: TimeExpr) bool {
    const age_secs = now - file_time;
    const age_mins: u64 = if (age_secs > 0) @divTrunc(@as(u64, @intCast(age_secs)), 60) else 0;
    // Negative space: non-positive ages clamp to 0. Positive space: age in
    // minutes never exceeds age in seconds.
    if (age_secs <= 0) assert(age_mins == 0);
    if (age_secs > 0) assert(age_mins <= @as(u64, @intCast(age_secs)));
    return switch (te.cmp) {
        .exactly => age_mins == te.days,
        .greater_than => age_mins > te.days,
        .less_than => age_mins < te.days,
    };
}

/// Compare a raw count (-links nlink, -inum inode) against a `te.days` value.
fn evaluateLeaf_countCompare(value: u64, te: TimeExpr) bool {
    const result = switch (te.cmp) {
        .exactly => value == te.days,
        .greater_than => value > te.days,
        .less_than => value < te.days,
    };
    // Positive/negative space: an exact match implies equality, and a less-than
    // match implies the value is strictly below the threshold.
    if (result) {
        if (te.cmp == .exactly) assert(value == te.days);
        if (te.cmp == .less_than) assert(value < te.days);
    }
    return result;
}

/// Match a file's permission bits against a `-perm` predicate (exact, at-least,
/// or any-of comparison over the low 12 mode bits).
fn evaluateLeaf_perm(stat_buf: StatInfo, pe: PermExpr) bool {
    const file_mode = @as(u32, @intCast(stat_buf.mode)) & 0o7777;
    assert(file_mode <= 0o7777);
    return switch (pe.cmp) {
        .exact => file_mode == pe.mode,
        .at_least => (file_mode & pe.mode) == pe.mode,
        .any_of => if (pe.mode == 0) file_mode == 0 else (file_mode & pe.mode) != 0,
    };
}

/// Run a compiled POSIX regex against the full path. Returns false on alloc
/// failure (preserving the original best-effort behavior).
fn evaluateLeaf_regex(allocator: Allocator, regex_ptr: *regex_h.regex_t, path: []const u8) bool {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    assert(path_z.len == path.len);
    return regex_h.regexec(regex_ptr, path_z.ptr, 0, null, 0) == 0;
}

/// Compare a file's birth time age in days against a `-Btime` predicate. Returns
/// false when birth time is unavailable (Linux, or unsupported filesystem).
fn evaluateLeaf_btime(now: i64, path: []const u8, te: TimeExpr) bool {
    assert(now >= 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);
    const btime = getBirthTime(path) orelse return false;
    return evaluateLeaf_ageDays(now, btime, te);
}

/// Compare a file's birth time age in minutes against a `-Bmin` predicate.
/// Returns false when birth time is unavailable.
fn evaluateLeaf_bmin(now: i64, path: []const u8, te: TimeExpr) bool {
    assert(now >= 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);
    const btime = getBirthTime(path) orelse return false;
    return evaluateLeaf_ageMins(now, btime, te);
}

/// Compare a file's X timestamp to a stored Y reference time for `-newerXY`.
/// 'B' uses birth time (false when unavailable); a/c/m use the matching field.
fn evaluateLeaf_newerxy(stat_buf: StatInfo, path: []const u8, data: NewerXYData) bool {
    assert(data.x_field != 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);
    const file_time: i64 = switch (data.x_field) {
        'a' => getAtime(stat_buf),
        'c' => getCtime(stat_buf),
        'm' => getMtime(stat_buf),
        'B' => getBirthTime(path) orelse return false,
        else => getMtime(stat_buf),
    };
    return file_time > data.ref_time;
}

/// Match a symlink's target against a glob pattern for `-lname`/-ilname. Returns
/// false for non-symlinks (only symlinks have a target to match).
fn evaluateLeaf_lname(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    kind: FileType,
    pattern: []const u8,
    insensitive: bool,
) bool {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    if (kind != .symlink) return false;
    assert(kind == .symlink);
    return matchSymlinkTarget(io, allocator, path, pattern, insensitive);
}

/// Match a file's (inode, device) pair against a `-samefile` reference.
fn evaluateLeaf_samefile(stat_buf: StatInfo, sf: SamefileData) bool {
    const file_ino: u64 = @intCast(stat_buf.ino);
    const file_dev: i64 = @intCast(stat_buf.dev);
    const result = file_ino == sf.ino and file_dev == sf.dev;
    // A match requires both identifiers to coincide (positive and negative).
    if (result) assert(file_ino == sf.ino);
    if (result) assert(file_dev == sf.dev);
    return result;
}

/// Record a path for a `-exec ... {} +` batch on the batch context. No-op when
/// no batch context is active. Returns false only on allocation failure.
fn evaluateLeaf_execBatch(
    allocator: Allocator,
    path: []const u8,
    exec_data: ExecExpr,
    batch_ctx: ?*BatchContext,
) bool {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    assert(exec_data.argv.len > 0);
    if (batch_ctx) |bc| {
        bc.exec_template = exec_data.argv;
        const path_copy = allocator.dupe(u8, path) catch return false;
        bc.exec_paths.append(allocator, path_copy) catch {
            allocator.free(path_copy);
            return false;
        };
    }
    return true;
}

/// Record a path for a `-execdir ... {} +` batch, capturing the directory on
/// first use. No-op without a batch context. Returns false on alloc failure.
fn evaluateLeaf_execdirBatch(
    allocator: Allocator,
    path: []const u8,
    exec_data: ExecExpr,
    batch_ctx: ?*BatchContext,
) bool {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    assert(exec_data.argv.len > 0);
    if (batch_ctx) |bc| {
        bc.execdir_template = exec_data.argv;
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
}

/// Print `path` followed by a newline for `-print`. Sets `had_error` on a write
/// failure, matching the original best-effort behavior.
fn evaluateLeaf_print(stdout: anytype, path: []const u8, had_error: *bool) bool {
    comptime assert(std.Io.Dir.max_path_bytes > 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);
    stdout.print("{s}\n", .{path}) catch {
        had_error.* = true;
    };
    return true;
}

/// Print `path` followed by a NUL byte for `-print0`. Sets `had_error` on any
/// write failure, matching the original best-effort behavior.
fn evaluateLeaf_print0(stdout: anytype, path: []const u8, had_error: *bool) bool {
    comptime assert(std.Io.Dir.max_path_bytes > 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);
    stdout.print("{s}", .{path}) catch {
        had_error.* = true;
    };
    stdout.writeByte(0) catch {
        had_error.* = true;
    };
    return true;
}

/// Handle one `%X` specifier in a `-printf` format string. Sets `had_error` on
/// any write failure. Unknown specifiers are emitted verbatim as `%X`.
fn evaluateLeaf_printf_percent(
    stdout: anytype,
    spec: u8,
    path: []const u8,
    basename: []const u8,
    stat_buf: StatInfo,
    had_error: *bool,
) void {
    assert(spec != 0);
    switch (spec) {
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
            stdout.writeByte(spec) catch {
                had_error.* = true;
            };
        },
    }
}

/// Handle one `\X` escape in a `-printf` format string. Sets `had_error` on any
/// write failure. Unknown escapes are emitted verbatim as `\X`.
fn evaluateLeaf_printf_escape(stdout: anytype, spec: u8, had_error: *bool) void {
    assert(spec != 0);
    switch (spec) {
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
            stdout.writeByte(spec) catch {
                had_error.* = true;
            };
        },
    }
}

/// Drive a `-printf` format string, dispatching `%X` specifiers and `\X`
/// escapes to their helpers and copying literal bytes. Sets `had_error` on any
/// write failure. The bounded loop advances by 1 or 2 each step.
fn evaluateLeaf_printf(
    stdout: anytype,
    fmt: []const u8,
    path: []const u8,
    basename: []const u8,
    stat_buf: StatInfo,
    had_error: *bool,
) bool {
    assert(path.len <= std.Io.Dir.max_path_bytes);
    var i: usize = 0; // tiger:allow:usize-arch slice index cursor
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            evaluateLeaf_printf_percent(stdout, fmt[i + 1], path, basename, stat_buf, had_error);
            i += 2;
        } else if (fmt[i] == '\\' and i + 1 < fmt.len) {
            evaluateLeaf_printf_escape(stdout, fmt[i + 1], had_error);
            i += 2;
        } else {
            stdout.writeByte(fmt[i]) catch {
                had_error.* = true;
            };
            i += 1;
        }
    }
    assert(i >= fmt.len);
    return true;
}

// Evaluate the side-effect-free matcher tags (tests, not actions). Returns the
// match result, or null when `expr.tag` is an action tag handled elsewhere.
// Split out of evaluateLeaf so each function stays within the 70-line limit;
// behavior per tag is byte-identical to the original switch.
fn evaluateLeaf_match(
    io: std.Io,
    expr: *const Expression,
    path: []const u8,
    basename: []const u8,
    stat_buf: StatInfo,
    kind: FileType,
    now: i64,
    depth: u32,
    allocator: Allocator,
) ?bool {
    assert(expr.tag != .and_expr);
    assert(expr.tag != .not_expr);
    switch (expr.tag) {
        .true_expr => return true,
        .name => return glob.globMatch(expr.data.pattern, basename),
        .iname => return glob.globMatchInsensitive(expr.data.pattern, basename),
        .path_match => return glob.globMatch(expr.data.pattern, path),
        .file_type => return kind == expr.data.file_type,
        .size => return evaluateLeaf_size(stat_buf, expr.data.size),
        .empty => {
            if (kind == .regular) return stat_buf.size == 0;
            if (kind == .directory) return isDirEmpty(io, path) catch false;
            return false;
        },
        .newer => return getMtime(stat_buf) > expr.data.newer_mtime,
        .mtime => return evaluateLeaf_ageDays(now, getMtime(stat_buf), expr.data.time),
        .perm => return evaluateLeaf_perm(stat_buf, expr.data.perm_expr),
        .user => return matchUser(expr.data.name_str, stat_buf.uid),
        .group => return matchGroup(expr.data.name_str, stat_buf.gid),
        .atime => return evaluateLeaf_ageDays(now, getAtime(stat_buf), expr.data.time),
        .ctime => return evaluateLeaf_ageDays(now, getCtime(stat_buf), expr.data.time),
        .links => return evaluateLeaf_countCompare(@intCast(stat_buf.nlink), expr.data.time),
        .mmin => return evaluateLeaf_ageMins(now, getMtime(stat_buf), expr.data.time),
        .inum => return evaluateLeaf_countCompare(@intCast(stat_buf.ino), expr.data.time),
        .amin => return evaluateLeaf_ageMins(now, getAtime(stat_buf), expr.data.time),
        .cmin => return evaluateLeaf_ageMins(now, getCtime(stat_buf), expr.data.time),
        .anewer => return getAtime(stat_buf) > expr.data.newer_mtime,
        .cnewer => return getCtime(stat_buf) > expr.data.newer_mtime,
        .fstype => return matchFstype(allocator, path, expr.data.name_str),
        .flags => return matchFlags(stat_buf, expr.data.name_str),
        .xdev => return true,
        .nouser => return getpwuid(stat_buf.uid) == null,
        .nogroup => return getgrgid(stat_buf.gid) == null,
        .false_expr => return false,
        .ipath => return glob.globMatchInsensitive(expr.data.pattern, path),
        .regex_match, .iregex_match => return evaluateLeaf_regex(
            allocator,
            expr.data.regex_ptr,
            path,
        ),
        .btime_stub => return evaluateLeaf_btime(now, path, expr.data.time),
        .bmin_stub => return evaluateLeaf_bmin(now, path, expr.data.time),
        .bnewer_stub => {
            // -Bnewer REF: file's birth time newer than REF's birth time
            const file_btime = getBirthTime(path) orelse return false;
            return file_btime > expr.data.newer_mtime;
        },
        .newerxy_stub => return evaluateLeaf_newerxy(stat_buf, path, expr.data.newerxy_data),
        .acl_stub, .sparse_stub, .xattr_stub, .xattrname_stub => return false,
        .depth_n => return depth == expr.data.depth_val,
        .gid_match => return stat_buf.gid == expr.data.gid_val,
        .uid_match => return stat_buf.uid == expr.data.uid_val,
        .lname => return evaluateLeaf_lname(io, allocator, path, kind, expr.data.pattern, false),
        .ilname => return evaluateLeaf_lname(io, allocator, path, kind, expr.data.pattern, true),
        .samefile => return evaluateLeaf_samefile(stat_buf, expr.data.samefile_data),
        else => return null,
    }
}

// Evaluate the action / side-effecting tags (-print, -exec, -delete, -prune,
// ...). Carries had_error / pruned / batch_ctx writes exactly as before. The
// boolean-operator tags are unreachable here (handled by evaluate()'s driver).
fn evaluateLeaf_action(
    io: std.Io,
    expr: *const Expression,
    path: []const u8,
    basename: []const u8,
    stat_buf: StatInfo,
    kind: FileType,
    allocator: Allocator,
    stdout: anytype,
    stderr: anytype,
    had_error: *bool,
    pruned: *bool,
    batch_ctx: ?*BatchContext,
) bool {
    switch (expr.tag) {
        .execdir => return doExecdir(io, allocator, path, basename, expr.data.exec_data),
        .ls_action => return doLs(allocator, path, stat_buf, kind, stdout, had_error),
        // -ok prompts user on /dev/tty; in non-interactive contexts
        // (pipes, tests) it defaults to deny (return false).
        .ok => return doOk(allocator, path, expr.data.exec_data, stderr),
        .print => return evaluateLeaf_print(stdout, path, had_error),
        .print0 => return evaluateLeaf_print0(stdout, path, had_error),
        .delete => return doDelete(io, allocator, path, kind, stderr, had_error),
        .exec_cmd => return doExec(io, allocator, path, expr.data.exec_data),
        .exec_batch => return evaluateLeaf_execBatch(
            allocator,
            path,
            expr.data.exec_data,
            batch_ctx,
        ),
        .execdir_batch => return evaluateLeaf_execdirBatch(
            allocator,
            path,
            expr.data.exec_data,
            batch_ctx,
        ),
        .prune => {
            pruned.* = true;
            return true;
        },
        .okdir_stub => {
            stderr.print("< ? ... > ", .{}) catch {};
            return false;
        },
        .quit_action => {
            // Signal that we should stop processing. In production this leads
            // to an immediate exit from main; process.exit matches GNU find.
            std.process.exit(0);
        },
        .printf_action => {
            return evaluateLeaf_printf(
                stdout,
                expr.data.pattern,
                path,
                basename,
                stat_buf,
                had_error,
            );
        },
        // Boolean operators are driven by evaluate()'s work stack, never here.
        .and_expr, .or_expr, .not_expr => unreachable,
        // All matcher tags are resolved by evaluateLeaf_match before we get here.
        else => unreachable,
    }
}

// Evaluate a single leaf (non and/or/not) node of the expression tree. Carries
// all the order-sensitive side effects (-print, -exec, -delete, -prune, ...)
// and writes through had_error / pruned / batch_ctx exactly as before; the
// driver in evaluate() never reaches the boolean-operator tags here.
fn evaluateLeaf(
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
    // Boolean operators are handled by the evaluate() driver, never here.
    assert(expr.tag != .and_expr);
    assert(expr.tag != .or_expr);
    assert(expr.tag != .not_expr);
    const matched = evaluateLeaf_match(
        io,
        expr,
        path,
        basename,
        stat_buf,
        kind,
        now,
        depth,
        allocator,
    );
    if (matched) |result| return result;
    return evaluateLeaf_action(
        io,
        expr,
        path,
        basename,
        stat_buf,
        kind,
        allocator,
        stdout,
        stderr,
        had_error,
        pruned,
        batch_ctx,
    );
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
    assert(name_str.len < buf.len);
    @memcpy(buf[0..name_str.len], name_str);
    buf[name_str.len] = 0;
    const c_name = buf[0..name_str.len :0];

    const pw = getpwnam(c_name);
    if (pw) |p| {
        return uid == p.uid;
    }
    return false;
}

fn matchGroup(name_str: []const u8, gid: c.gid_t) bool {
    if (std.fmt.parseInt(c.gid_t, name_str, 10)) |numeric_gid| {
        return gid == numeric_gid;
    } else |_| {}

    var buf: [256]u8 = undefined;
    if (name_str.len >= buf.len) return false;
    assert(name_str.len < buf.len);
    @memcpy(buf[0..name_str.len], name_str);
    buf[name_str.len] = 0;
    const c_name = buf[0..name_str.len :0];

    const gr = getgrnam(c_name);
    if (gr) |g| {
        return gid == g.gid;
    }
    return false;
}

fn matchSymlinkTarget(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
) bool {
    _ = allocator;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().readLink(io, path, &link_buf) catch return false;
    const target = link_buf[0..len];
    return if (case_insensitive)
        glob.globMatchInsensitive(pattern, target)
    else
        glob.globMatch(pattern, target);
}

fn doDelete(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    kind: FileType,
    stderr: anytype,
    had_error: *bool,
) bool {
    if (kind == .directory) {
        std.Io.Dir.cwd().deleteDir(io, path) catch |err| {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "cannot delete '{s}': {s}",
                .{ path, common.posixErrorString(err) },
            );
            had_error.* = true;
            return false;
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "cannot delete '{s}': {s}",
                .{ path, common.posixErrorString(err) },
            );
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

fn doExecdir(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    basename: []const u8,
    exec_data: ExecExpr,
) bool {
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

fn doLs(
    allocator: Allocator,
    path: []const u8,
    stat_buf: StatInfo,
    kind: FileType,
    stdout: anytype,
    had_error: *bool,
) bool {
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
        return .{ .name = spanOrEmpty(p.name), .allocated = false };
    }
    // Fall back to numeric
    const s = std.fmt.allocPrint(allocator, "{d}", .{uid}) catch
        return .{ .name = "?", .allocated = false };
    return .{ .name = s, .allocated = true };
}

fn getGroupName(allocator: Allocator, gid: c.gid_t) NameResult {
    const gr = getgrgid(gid);
    if (gr) |g| {
        return .{ .name = spanOrEmpty(g.name), .allocated = false };
    }
    const s = std.fmt.allocPrint(allocator, "{d}", .{gid}) catch
        return .{ .name = "?", .allocated = false };
    return .{ .name = s, .allocated = true };
}

fn formatPermissions(mode: u32, buf: *[10]u8) void {
    const m: u32 = mode;
    buf[0] = if (m & 0o400 != 0) 'r' else '-';
    buf[1] = if (m & 0o200 != 0) 'w' else '-';
    buf[2] = if (m & 0o4000 != 0)
        (if (m & 0o100 != 0) 's' else 'S')
    else
        (if (m & 0o100 != 0) 'x' else '-');
    buf[3] = if (m & 0o040 != 0) 'r' else '-';
    buf[4] = if (m & 0o020 != 0) 'w' else '-';
    buf[5] = if (m & 0o2000 != 0)
        (if (m & 0o010 != 0) 's' else 'S')
    else
        (if (m & 0o010 != 0) 'x' else '-');
    buf[6] = if (m & 0o004 != 0) 'r' else '-';
    buf[7] = if (m & 0o002 != 0) 'w' else '-';
    buf[8] = if (m & 0o1000 != 0)
        (if (m & 0o001 != 0) 't' else 'T')
    else
        (if (m & 0o001 != 0) 'x' else '-');
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
        return std.fmt.bufPrint(buf, "{s} {d: >2}  {d}", .{ month_name, dom, year }) catch
            "??? ?? ????";
    } else {
        // Recent: show time
        return std.fmt.bufPrint(
            buf,
            "{s} {d: >2} {d:0>2}:{d:0>2}",
            .{ month_name, dom, hours, mins },
        ) catch "??? ?? ??:??";
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
    assert(path.len <= std.fs.max_path_bytes);
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
    const failing = findUnreadableChildDir(state.allocator, state.io, parent_path) orelse
        parent_path;
    common.printErrorWithProgram(
        state.allocator,
        stderr,
        prog_name,
        "'{s}': {s}",
        .{ failing, common.posixErrorString(err) },
    );
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
fn findVisitEntry(
    state: *WalkState,
    raw_entry: common.walker.Entry,
    stdout: anytype,
    stderr: anytype,
) void {
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
/// Under -xargs_safe, warn and prune a directory whose name is unsafe for xargs.
/// Returns true when the directory was pruned so the caller can return early.
fn findVisitDirPre_pruneXargsUnsafe(
    state: *WalkState,
    basename: []const u8,
    effective_depth: u32,
    is_hop_root: bool,
    stderr: anytype,
) bool {
    if (is_hop_root or !state.config.xargs_safe or effective_depth == 0) return false;
    if (!isXargsUnsafe(basename)) return false;
    common.printErrorWithProgram(
        state.allocator,
        stderr,
        prog_name,
        "warning: file name '{s}' is not safe for use with xargs",
        .{basename},
    );
    state.walker.pruneCurrent();
    return true;
}

/// The walker opened this path as a directory, but find's own follow policy
/// resolved it to a non-directory. Evaluate it as a leaf (subject to mindepth
/// and hop-root rules) and prune the walker's descent.
fn findVisitDirPre_handleNonDir(
    state: *WalkState,
    path: []const u8,
    stat_buf: StatInfo,
    effective_depth: u32,
    is_hop_root: bool,
    stdout: anytype,
    stderr: anytype,
) void {
    if (!is_hop_root and effective_depth >= state.config.mindepth) {
        findEvaluatePath(
            state,
            path,
            stat_buf,
            getFileKind(stat_buf.mode),
            effective_depth,
            stdout,
            stderr,
        );
    }
    state.walker.pruneCurrent();
}

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
    if (findVisitDirPre_pruneXargsUnsafe(state, basename, effective_depth, is_hop_root, stderr)) {
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
        findVisitDirPre_handleNonDir(
            state,
            entry.path,
            stat_buf,
            effective_depth,
            is_hop_root,
            stdout,
            stderr,
        );
        return;
    }
    if (effective_depth == 0 and state.config.xdev) state.root_dev = @intCast(stat_buf.dev);
    if (findDirCrossesDevice(state, stat_buf, entry.path, effective_depth, stdout, stderr)) return;
    const dup_path = state.allocator.dupe(u8, entry.path) catch {
        state.had_error.* = true;
        state.walker.pruneCurrent();
        return;
    };
    state.last_dir = .{
        .path = dup_path,
        .stat = stat_buf,
        .kind = .directory,
        .effective_depth = effective_depth,
    };
    // Push onto the -L follow chain ONLY when this directory will actually be
    // descended (its .post will fire, balancing the pop). A directory pruned by
    // -prune or the -maxdepth boundary emits no .post, so pushing it here would
    // leak it and misalign the LIFO chain, tripping a false loop diagnostic on a
    // later sibling symlink. So decide the prunes first, then push.
    if (findDirPreEvaluate(
        state,
        dup_path,
        stat_buf,
        effective_depth,
        is_hop_root,
        stdout,
        stderr,
    )) return;
    if (findDirMaxdepthBoundary(
        state,
        dup_path,
        stat_buf,
        effective_depth,
        is_hop_root,
        stdout,
        stderr,
    )) return;
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
fn findVisitLeaf(
    state: *WalkState,
    path: []const u8,
    effective_depth: u32,
    stdout: anytype,
    stderr: anytype,
) void {
    assert(path.len > 0);
    const basename = std.fs.path.basename(path);
    if (state.config.xargs_safe and effective_depth > 0 and isXargsUnsafe(basename)) {
        common.printErrorWithProgram(
            state.allocator,
            stderr,
            prog_name,
            "warning: file name '{s}' is not safe for use with xargs",
            .{basename},
        );
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
    chain[state.ancestors.items.len] = .{
        .dev = target_dev,
        .inode = target_inode,
        .path = dup_path,
    };
    state.hops.append(state.allocator, .{
        .path = dup_path,
        .base_depth = effective_depth,
        .ancestors = chain,
    }) catch {
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
    state.ancestors.append(state.allocator, .{
        .dev = @intCast(stat_buf.dev),
        .inode = stat_buf.ino,
        .path = dup_path,
    }) catch {
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
        error.AccessDenied => common.printErrorWithProgram(
            state.allocator,
            stderr,
            prog_name,
            "'{s}': Permission denied",
            .{path},
        ),
        error.FileNotFound => common.printErrorWithProgram(
            state.allocator,
            stderr,
            prog_name,
            "'{s}': No such file or directory",
            .{path},
        ),
        error.SymLinkLoop => common.printErrorWithProgram(
            state.allocator,
            stderr,
            prog_name,
            "'{s}': Too many levels of symbolic links",
            .{path},
        ),
        else => common.printErrorWithProgram(
            state.allocator,
            stderr,
            prog_name,
            "'{s}': {s}",
            .{ path, common.posixErrorString(err) },
        ),
    }
    state.had_error.* = true;
}

/// Build the WalkConfig for find. Order is always .both so the driver controls
/// pre/post timing. -xdev and loop detection are driver-side, so the walker's
/// stay_on_filesystem and cycle_mode stay off (false / .none). -L uses
/// no_follow (NOT follow_all) so symlinks arrive as .sym_link and the driver
/// re-stats them.
fn walkerConfig(config: *const FindConfig) common.walker.WalkConfig {
    const symlinks: common.walker.SymlinkPolicy =
        if (config.follow_cmdline_symlinks and !config.follow_symlinks)
            .follow_cmdline
        else
            .no_follow;
    return .{
        .order = .both,
        .symlinks = symlinks,
        .sort_children = config.sorted,
        .stay_on_filesystem = false,
        .cycle_mode = .none,
        .max_depth = 1024,
    };
}

// ============================================================================
// Entry points
// ============================================================================

/// Map parseArgs failures: `--help`/`--version` in predicate position
/// print help/version on stdout (GNU sequential parse). Other errors
/// already wrote stderr inside parseArgs.
fn runFind_afterParseErr(
    allocator: Allocator,
    stdout: anytype,
    err: anyerror,
) u8 {
    if (err == error.HelpRequested) {
        printHelp(allocator, stdout);
        return @intFromEnum(common.ExitCode.success);
    }
    if (err == error.VersionRequested) {
        printVersion(stdout);
        return @intFromEnum(common.ExitCode.success);
    }
    std.debug.assert(err != error.HelpRequested);
    std.debug.assert(err != error.VersionRequested);
    return @intFromEnum(common.ExitCode.general_error);
}

pub fn runFind(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) anyerror!u8 {
    const config = parseArgs(allocator, args, stderr) catch |err| {
        return runFind_afterParseErr(allocator, stdout, err);
    };
    assert(config.start_paths.len > 0);

    const now = blk: {
        var _ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    };
    assert(now >= 0);
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

    return if (had_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runFindTyped);
}

/// Typed wrapper for utilityMain compatibility
fn runFindTyped(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) anyerror!u8 {
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{"--help"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{"--version"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-type", "f" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "file.txt") != null);
    }

    // Find only directories
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-type", "d" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-empty" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-maxdepth", "1" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-not", "-name", "*.log", "-type", "f" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "*.txt", "-o", "-name", "*.md" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "(", "-name", "*.txt", "-o", "-name", "*.md", ")" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "file.txt", "-print0" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{"/tmp/nonexistent_vibeutils_test_path_99999"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ ".", "-bogus" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-mindepth", "2" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "deleteme.txt", "-delete" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-iname", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-size", "+1000c" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const f1 = try tmp.dir.createFile(testing.io, "rw.txt", .{
        .permissions = @enumFromInt(0o644),
    });
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "rwx.txt", .{
        .permissions = @enumFromInt(0o755),
    });
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-perm", "755" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-path", "*/subdir/*" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-depth" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-path", "*/nonexistent/*" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-atime", "+9999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-ctime", "+9999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-links", "99" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-nouser" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-xdev", "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-d" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-f", dir_path, "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-x", "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-X", "-type", "f" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-mmin", "-5" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-mmin", "+9999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-inum", ino_str },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-inum", "0" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-amin", "-5" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-amin", "+9999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-cmin", "-5" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-cmin", "+9999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-anewer", ref_abs_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-cnewer", ref_abs_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "/tmp", "-maxdepth", "0", "-ok", "echo", "{}", ";" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-execdir", "echo", "{}", ";" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "listed.txt", "-ls" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-fstype", "apfs" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-flags", "uchg" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-P", dir_path, "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-E", dir_path, "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-s", dir_path, "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-ipath", "*/subdir/*" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-iwholename", "*test*" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-regex", ".*\\.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-iregex", ".*\\.TXT" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-Bmin", "-5" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-Bnewer", file_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-Btime", "-1" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-acl" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-depth", "1" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-depth", "2" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-gid", gid_str },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-gid", "99999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-uid", uid_str },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-uid", "99999" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-ignore_readdir_race", "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-noignore_readdir_race", "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-noleaf", "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-lname", "target*" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-ilname", "target*" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-mnewer", ref_abs_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-mount", "-name", "*.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-newermm", file_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "/tmp", "-maxdepth", "0", "-okdir", "echo", "{}", ";" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "/tmp", "-maxdepth", "0", "-false", "-quit" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-samefile", orig_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-sparse" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-xattr" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-xattrname", "com.apple.metadata" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "file.txt", "-printf", "%p\\n" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-false" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-true" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "(", "-false", "-o", "-true", ")" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-regex", "^impossible_pattern_that_matches_nothing$" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-iregex", "^impossible_pattern_that_matches_nothing$" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-size", "1" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-size", "2" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-size", "-2" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-type", "f", "-exec", "/usr/bin/true", "{}", ";", "-print" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
        try testing.expectEqual(@as(u8, 0), exit_code);
        try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "target.txt") != null);
    }

    // Test 2: -exec /usr/bin/false {} ; -print => nothing printed
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{
                dir_path,
                "-type",
                "f",
                "-exec",
                "/usr/bin/false",
                "{}",
                ";",
                "-print",
            },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

    // Get the UID of the test file, then look up the username. The lookup runs
    // through common.user_group so this test does not reach into a find-local
    // libc binding -- issue #129 deletes those.
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "myfile.txt" });
    const stat_buf = try doStat(file_path, false);
    const user_info = try common.user_group.getUserById(@intCast(stat_buf.uid), allocator);
    try testing.expect(user_info.name.len > 0);
    const username = user_info.name;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-user", username },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    // Get the GID of the test file, then look up the group name. Same reason
    // as -user above: the shared module owns the libc binding, not find.
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "grpfile.txt" });
    const stat_buf = try doStat(file_path, false);
    const group_info = try common.user_group.getGroupById(@intCast(stat_buf.gid), allocator);
    try testing.expect(group_info.name.len > 0);
    const groupname = group_info.name;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-group", groupname },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-nogroup" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "normalfile.txt") == null);
}

// ================================================================
// Issue #129: find must not hand-roll libc's passwd/group ABI
// ================================================================

test "find: passwd and group lookups use std's platform structs" {
    // find used to inline four anonymous `extern struct`s into its extern fn
    // return types. Two were glibc-shaped, which reads the wrong offsets on
    // macOS, and one was silently truncated after pw_gid. Whichever way the
    // lookups are reached after the consolidation -- re-exported here under
    // the same names or taken straight from common.user_group -- the pointee
    // has to be std's platform struct.
    const ug = common.user_group;
    const pwnam = if (@hasDecl(@This(), "getpwnam")) getpwnam else ug.getpwnam;
    const pwuid = if (@hasDecl(@This(), "getpwuid")) getpwuid else ug.getpwuid;
    const grnam = if (@hasDecl(@This(), "getgrnam")) getgrnam else ug.getgrnam;
    const grgid = if (@hasDecl(@This(), "getgrgid")) getgrgid else ug.getgrgid;
    const pwnam_ret = @typeInfo(@TypeOf(pwnam)).@"fn".return_type.?;
    const pwuid_ret = @typeInfo(@TypeOf(pwuid)).@"fn".return_type.?;
    const grnam_ret = @typeInfo(@TypeOf(grnam)).@"fn".return_type.?;
    const grgid_ret = @typeInfo(@TypeOf(grgid)).@"fn".return_type.?;
    try testing.expect(pwnam_ret == ?*std.c.passwd);
    try testing.expect(pwuid_ret == ?*std.c.passwd);
    try testing.expect(grnam_ret == ?*std.c.group);
    try testing.expect(grgid_ret == ?*std.c.group);
    // Negative space: a group lookup must never hand back a passwd record --
    // that is the std.c.getgrnam typo the shared module routes around.
    try testing.expect(grnam_ret != ?*std.c.passwd);
    try testing.expect(grgid_ret != ?*std.c.passwd);
}

test "find: -user resolves a name to its uid, not to its gid" {
    // Root is required to chown the fixture onto an account whose uid and gid
    // differ; on an account where they match, reading pw_gid instead of
    // pw_uid is invisible, so the check would have no teeth.
    if (std.c.geteuid() != 0) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(testing.io, "foreign.txt", .{});
    f.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "foreign.txt" });

    // Bounded scan of the system account range for a uid/gid mismatch.
    const uid_scan_max: u32 = 256;
    var picked_uid: c.uid_t = 0;
    var picked_gid: c.gid_t = 0;
    var picked_name: []const u8 = "";
    var scan: u32 = 0;
    while (scan < uid_scan_max) : (scan += 1) {
        const entry = std.c.getpwuid(@intCast(scan)) orelse continue;
        if (entry.uid == entry.gid) continue;
        picked_uid = entry.uid;
        picked_gid = entry.gid;
        picked_name = try allocator.dupe(u8, std.mem.span(entry.name.?));
        break;
    }
    if (picked_name.len == 0) return error.SkipZigTest;
    try testing.expect(picked_uid != picked_gid);

    const path_z = try allocator.dupeZ(u8, file_path);
    const rc = std.c.fchownat(std.c.AT.FDCWD, path_z.ptr, picked_uid, picked_gid, 0);
    try testing.expectEqual(@as(c_int, 0), rc);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-user", picked_name },
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "foreign.txt") != null);
}

test "find: -group resolves a name to its gid, not to zero" {
    // Root is required to move the fixture onto a non-zero group; with the
    // fixture in group 0 a lookup that always yields 0 would still "match".
    if (std.c.geteuid() != 0) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(testing.io, "foreigngrp.txt", .{});
    f.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "foreigngrp.txt" });

    // Bounded scan of the system group range for any non-zero gid.
    const gid_scan_max: u32 = 256;
    var picked_gid: c.gid_t = 0;
    var picked_name: []const u8 = "";
    var scan: u32 = 1;
    while (scan < gid_scan_max) : (scan += 1) {
        const entry = std.c.getgrgid(@intCast(scan)) orelse continue;
        picked_gid = entry.gid;
        picked_name = try allocator.dupe(u8, std.mem.span(entry.name.?));
        break;
    }
    if (picked_name.len == 0) return error.SkipZigTest;
    try testing.expect(picked_gid != 0);

    const path_z = try allocator.dupeZ(u8, file_path);
    const rc = std.c.fchownat(std.c.AT.FDCWD, path_z.ptr, std.c.geteuid(), picked_gid, 0);
    try testing.expectEqual(@as(c_int, 0), rc);

    var match_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer match_aw.deinit();
    const match_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-group", picked_name },
        &match_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), match_code);
    try testing.expect(std.mem.find(u8, match_aw.writer.buffered(), "foreigngrp.txt") != null);

    // Negative space: the numeric form of a group the file is not in must not
    // match, so a match above cannot be an "everything matches" degeneracy.
    var miss_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer miss_aw.deinit();
    const miss_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-group", "0" },
        &miss_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), miss_code);
    try testing.expect(std.mem.find(u8, miss_aw.writer.buffered(), "foreigngrp.txt") == null);
}

test "find: getUserName and getGroupName return login names, not other fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The oracle is the shared module, so this pins find's long-listing name
    // columns to the same passwd/group fields the rest of the tree reads.
    const uid = common.user_group.getCurrentUserId();
    const user_info = try common.user_group.getUserById(uid, allocator);
    const user_result = getUserName(allocator, @intCast(uid));
    try testing.expectEqualStrings(user_info.name, user_result.name);
    // Negative space: a login name is not a path, so a slip onto pw_dir or
    // pw_shell shows up even if the expected value ever went stale.
    try testing.expect(std.mem.find(u8, user_result.name, "/") == null);

    const gid = common.user_group.getCurrentGroupId();
    const group_info = try common.user_group.getGroupById(gid, allocator);
    const group_result = getGroupName(allocator, @intCast(gid));
    try testing.expectEqualStrings(group_info.name, group_result.name);
    try testing.expect(std.mem.find(u8, group_result.name, "/") == null);
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-type", "f", "-newer", ref_abs_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-name", "deep.txt" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ "-L", dir_path, "-name", "deep.txt" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-H", link_path, "-name", "inner.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-maxdepth", "1", "-follow" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-name", "hello*", "-a", "-name", "*.txt" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ dir_path, "-name", "hello*", "-and", "-name", "*.txt" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{root_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ beta_path, alpha_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const beta_child_pos = std.mem.find(u8, out, "inside_beta.txt") orelse
        return error.MissingBetaChild;
    const alpha_child_pos = std.mem.find(u8, out, "inside_alpha.txt") orelse
        return error.MissingAlphaChild;
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ base, "-maxdepth", "0" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ root_path, "-depth", "-maxdepth", "1" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ root_path, "-depth", "-mindepth", "2" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ victim_path, "-delete" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{root_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Nonzero exit because one subtree could not be read.
    try testing.expectEqual(@as(u8, 1), exit_code);
    // The readable sibling is still processed despite the failed sibling.
    try testing.expect(
        std.mem.find(u8, stdout_aw.writer.buffered(), "readable_sibling.txt") != null,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ root_path, "-depth" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ root_path, "-name", "prune_me", "-prune" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-s", root_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    tmp.dir.symLink(testing.io, "target", "operand_link", .{ .is_directory = true }) catch
        return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const link_path = try std.fs.path.join(allocator, &.{ base, "operand_link" });

    // -P is the default; pass the symlink operand and list with -type l.
    {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_aw.deinit();

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ link_path, "-type", "l" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{link_path},
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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
    operand_target.symLink(
        testing.io,
        "../inner_target",
        "inner_link",
        .{ .is_directory = true },
    ) catch return error.SkipZigTest;

    // The operand itself is a symlink to operand_target.
    tmp.dir.symLink(testing.io, "operand_target", "operand_link", .{ .is_directory = true }) catch
        return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const operand_link = try std.fs.path.join(allocator, &.{ base, "operand_link" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-H", operand_link },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const exit2 = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-H", operand_link, "-type", "l" },
        &stdout2.writer,
        &stderr2.writer,
    );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ "-L", root_path, "-type", "f" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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

        const exit_code = try runFind(
            allocator,
            testing.io,
            &[_][]const u8{ "-L", root_path, "-type", "l" },
            &stdout_aw.writer,
            &stderr_aw.writer,
        );
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
    root.symLink(testing.io, "../shared", "link_a", .{ .is_directory = true }) catch
        return error.SkipZigTest;
    root.symLink(testing.io, "../shared", "link_b", .{ .is_directory = true }) catch
        return error.SkipZigTest;

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const root_path = try std.fs.path.join(allocator, &.{ base, "root" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-L", root_path, "-name", "found.txt" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ operand_path, "-X" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
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
    const junk_descent_path = try std.fs.path.join(
        allocator,
        &.{ base, "root", "sub", "up", "sub" },
    );

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-L", root_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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

// ============================================================================
// Parser-de-recursion characterization tests
//
// These lock in the EXACT grammar the iterative rewrite of parseOr/parseAnd/
// parseUnary (and exprContainsDelete) must preserve: AND binds tighter than
// OR, both operators are left-associative, -not negates only its immediate
// operand and chains, parentheses override precedence, the parse-error
// messages/exit codes are identical, and a -delete buried anywhere in the
// tree still forces depth-first. Every assertion below targets an outcome a
// WRONG precedence/associativity/error rewrite would flip. They are
// behavior-PRESERVING: they pass GREEN on the current recursive parser and
// must stay GREEN after the iterative rewrite. Teeth proven later by
// transient sabotage.
// ============================================================================

test "find: parser: AND binds tighter than OR (A -o B -a C = A OR (B AND C))" {
    // The single most important precedence invariant. With the correct
    // parse A OR (B AND C):
    //   - match_a.txt   matches A only            -> printed (A true)
    //   - match_bc.dat  matches B and C           -> printed (B AND C true)
    //   - match_b_only.txt matches B only         -> NOT printed
    // The WRONG parse (A OR B) AND C distributes C over everything, so
    // match_a.txt (not a .dat) would be DROPPED. Asserting match_a.txt is
    // PRESENT requires a non-default (truthy) outcome, so no default trap.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    (try tmp.dir.createFile(testing.io, "match_a.txt", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "match_bc.dat", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "match_b_only.txt", .{})).close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // A = -name match_a*, B = -name match_b*, C = -name *.dat
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "match_a*", "-o", "-name", "match_b*", "-a", "-name", "*.dat",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // A true -> printed. Only the correct OR-of-AND parse keeps this file.
    try testing.expect(std.mem.find(u8, out, "match_a.txt") != null);
    // B AND C true -> printed.
    try testing.expect(std.mem.find(u8, out, "match_bc.dat") != null);
    // B true but C false, and A false -> NOT printed.
    try testing.expect(std.mem.find(u8, out, "match_b_only.txt") == null);
}

test "find: parser: implicit AND binds tighter than OR (A -o B C = A OR (B AND C))" {
    // Same precedence law, but the AND between B and C is IMPLICIT (no -a
    // token). The implicit-AND path through parseAnd must layer under parseOr
    // identically to explicit -a. Same fixture/outcome as the explicit form.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    (try tmp.dir.createFile(testing.io, "match_a.txt", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "match_bc.dat", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "match_b_only.txt", .{})).close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // No -a: B and C are joined by implicit AND.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "match_a*", "-o", "-name", "match_b*", "-name", "*.dat",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "match_a.txt") != null);
    try testing.expect(std.mem.find(u8, out, "match_bc.dat") != null);
    try testing.expect(std.mem.find(u8, out, "match_b_only.txt") == null);
}

test "find: parser: all 3 operands of an -o chain contribute; none dropped (A -o B -o C)" {
    // A -o B -o C builds or(or(A,B),C). Associativity does not change the SET an
    // OR-chain matches, so a behavioral test through runFind cannot distinguish
    // left- from right-leaning trees; what it CAN pin is operand-completeness:
    // each of the three distinct predicates contributes its file, and a decoy
    // matching none stays absent. A rewrite that drops an operand (mis-builds
    // the chain and loses the first or last term) would lose one of these
    // files. All three present and decoy absent => the full chain is intact.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    (try tmp.dir.createFile(testing.io, "term_one.aaa", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "term_two.bbb", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "term_three.ccc", .{})).close(testing.io);
    // A decoy that matches NONE of the three predicates: must never appear.
    (try tmp.dir.createFile(testing.io, "decoy.zzz", .{})).close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "*.aaa", "-o", "-name", "*.bbb", "-o", "-name", "*.ccc",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // Every operand of the 3-way OR contributes; none is dropped.
    try testing.expect(std.mem.find(u8, out, "term_one.aaa") != null);
    try testing.expect(std.mem.find(u8, out, "term_two.bbb") != null);
    try testing.expect(std.mem.find(u8, out, "term_three.ccc") != null);
    // The decoy matches no predicate and must be excluded.
    try testing.expect(std.mem.find(u8, out, "decoy.zzz") == null);
}

test "find: parser: all 3 conjuncts of an implicit-AND chain apply; none dropped (A B C)" {
    // A B C builds and(and(A,B),C). Associativity is invariant for conjunction
    // membership, so a behavioral test cannot pin literal tree shape; what it
    // pins is conjunct-completeness: the chain matches ONLY the file satisfying
    // ALL three predicates. A rewrite that drops a term would over-match (let a
    // 2-of-3 file through). The fixture has one full match and a near-miss that
    // satisfies exactly two of the three.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // all_three: starts "abc", contains "mid", ends ".dat" -> all three true.
    (try tmp.dir.createFile(testing.io, "abc_mid_yes.dat", .{})).close(testing.io);
    // near_miss: starts "abc", contains "mid", but ends ".txt" -> C false.
    (try tmp.dir.createFile(testing.io, "abc_mid_no.txt", .{})).close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // A = -name abc*, B = -name *mid*, C = -name *.dat (implicit AND between).
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "abc*", "-name", "*mid*", "-name", "*.dat",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // Satisfies all three conjuncts -> printed.
    try testing.expect(std.mem.find(u8, out, "abc_mid_yes.dat") != null);
    // Fails the third conjunct -> excluded. Proves C is still ANDed in.
    try testing.expect(std.mem.find(u8, out, "abc_mid_no.txt") == null);
}

test "find: parser: -not negates only its operand then implicit-ANDs the rest" {
    // -not -name X -type f = and(not(name X), type f). The negation must bind
    // ONLY to -name X, then implicit-AND the following -type f. Fixture:
    //   - keep_me.txt   : name != skip*, is a file -> not(false)=true AND file
    //                     true -> printed.
    //   - skip_me.txt   : name == skip*           -> not(true)=false -> dropped.
    //   - a subdirectory: name != skip*, but NOT a file -> type f false ->
    //                     dropped. This proves -type f is still ANDed, i.e. the
    //                     -not did not swallow it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    (try tmp.dir.createFile(testing.io, "keep_me.txt", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "skip_me.txt", .{})).close(testing.io);
    try tmp.dir.createDir(testing.io, "keep_dir", .default_dir);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-not", "-name", "skip*", "-type", "f",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // not(name)=true AND type f true -> printed.
    try testing.expect(std.mem.find(u8, out, "keep_me.txt") != null);
    // not(name)=false -> dropped.
    try testing.expect(std.mem.find(u8, out, "skip_me.txt") == null);
    // not(name)=true but type f false -> dropped, proving -type f is still
    // conjoined and was NOT absorbed into the -not operand.
    try testing.expect(std.mem.find(u8, out, "keep_dir") == null);
}

test "find: parser: -not -not P double-negates back to P" {
    // -not -not -name X = not(not(name X)) = name X. The -not chain must apply
    // twice and cancel. Fixture: one matching file (must survive both
    // negations and print) and one non-matching file (must NOT print). A
    // rewrite that handles only a single -not (or applies an extra/odd count)
    // would flip both outcomes.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    (try tmp.dir.createFile(testing.io, "target_xyz.txt", .{})).close(testing.io);
    (try tmp.dir.createFile(testing.io, "other_qqq.txt", .{})).close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-not", "-not", "-name", "target_xyz*",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    // Double negation cancels -> behaves like -name target_xyz*.
    try testing.expect(std.mem.find(u8, out, "target_xyz.txt") != null);
    try testing.expect(std.mem.find(u8, out, "other_qqq.txt") == null);
}

test "find: parser: parentheses override AND-over-OR precedence" {
    // ( A -o B ) -type f forces the OR to evaluate FIRST, then ANDs -type f.
    // Without the parens, A -o B -type f parses as A OR (B AND type f), where
    // the -type f binds only to B. The two parses differ observably:
    //   - file_a.txt is a directory? No -- we make A match a DIRECTORY so that
    //     grouping changes its fate.
    // Fixture:
    //   - grp_a (a directory): matches A=name grp_a*. Not a file.
    //   - grp_b.txt (a file) : matches B=name grp_b*. Is a file.
    // Grouped ( A -o B ) -type f:
    //   - grp_a: (A or B)=true, but -type f false -> NOT printed.
    //   - grp_b.txt: (A or B)=true, -type f true -> printed.
    // Ungrouped A -o B -type f = A OR (B AND type f):
    //   - grp_a: A true -> printed (this is the DIFFERENCE).
    // We pin the GROUPED form: grp_a (the directory) must be ABSENT, which can
    // only happen when the parens forced -type f to apply to the whole OR.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "grp_a_dir", .default_dir);
    (try tmp.dir.createFile(testing.io, "grp_b_file.txt", .{})).close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    // Grouped form: ( name grp_a* -o name grp_b* ) -type f.
    var grouped_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer grouped_out.deinit();
    var grouped_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer grouped_err.deinit();

    const grouped_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "(", "-name", "grp_a*", "-o", "-name", "grp_b*", ")", "-type", "f",
    }, &grouped_out.writer, &grouped_err.writer);
    try testing.expectEqual(@as(u8, 0), grouped_code);

    const g = grouped_out.writer.buffered();
    // The OR ran first, then -type f filtered the whole group: the directory
    // is excluded, the file survives.
    try testing.expect(std.mem.find(u8, g, "grp_a_dir") == null);
    try testing.expect(std.mem.find(u8, g, "grp_b_file.txt") != null);

    // Ungrouped form differs: A OR (B AND type f) keeps the directory because
    // A (-name grp_a*) is true regardless of -type. Pin the contrast so a
    // rewrite that ignores parens (treats both alike) fails one of the two.
    var plain_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer plain_out.deinit();
    var plain_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer plain_err.deinit();

    const plain_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "grp_a*", "-o", "-name", "grp_b*", "-type", "f",
    }, &plain_out.writer, &plain_err.writer);
    try testing.expectEqual(@as(u8, 0), plain_code);

    const p = plain_out.writer.buffered();
    // Without parens the directory IS printed (A binds standalone in the OR).
    try testing.expect(std.mem.find(u8, p, "grp_a_dir") != null);
}

test "find: parser: trailing '(' with no ')' reports missing closing and exits 1" {
    // UnmatchedParen path: parseUnary consumes '(', enters parseOr, returns at
    // end-of-input with no ')'. The exact message "missing closing ')'" and
    // exit 1 are an external contract the iterative rewrite must reproduce
    // byte-for-byte. A rewrite that forgets the close_paren check would either
    // succeed (wrong exit) or emit a different message.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile(testing.io, "anything.txt", .{})).close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "(", "-name", "*.txt",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing closing") != null);
}

test "find: parser: stray ')' in operand position errors with unknown predicate, exit 1" {
    // A ')' that lands in OPERAND position (e.g. right after -o, where the
    // grammar demands a fresh operand) is not a valid stop-token there: it
    // flows down parseOr -> parseAnd -> parseUnary -> parsePrimary and hits
    // the catch-all as an unknown predicate. The contract: exit 1 and stderr
    // names ")" as unknown. The iterative rewrite must route an operand-
    // position ')' to the same parsePrimary catch-all, never silently accept
    // it. (A trailing ')' AFTER a complete expression is, by contrast, a stop
    // token the current parser leaves unconsumed -- so we force the operand
    // position with a preceding -o.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile(testing.io, "anything.txt", .{})).close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        dir_path, "-name", "*.txt", "-o", ")",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "unknown predicate") != null);
}

test "find: exprContainsDelete: -delete under -not still forces depth-first" {
    // The .not_expr arm of exprContainsDelete (the only recursive arm not
    // otherwise covered: and_expr by test ~4014, or_expr by the -o test below)
    // must descend into its single child so a -delete wrapped in -not still
    // flips depth_first on. The parse is not_expr(delete): a real not_expr node
    // sits above the .delete leaf, so the walk MUST recurse through .not_expr to
    // find it. (Contrast a bare `( -delete )`, which adds no AST node -- the
    // group's inner expr is returned directly, leaving a bare .delete root that
    // would not exercise any descent.)
    //
    // -not evaluates its operand first (firing -delete's side effect) then
    // negates the boolean, so the deletion still happens; only the returned
    // truth value is inverted. Behavioral proof: a populated directory is fully
    // removed. If exprContainsDelete dropped the .not_expr arm, depth_first
    // would stay off, the dir would be visited pre-order, and rmdir on a still-
    // populated directory would fail (the directory would survive).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "notvictim", .default_dir);
    var notvictim = try tmp.dir.openDir(testing.io, "notvictim", .{});
    (try notvictim.createFile(testing.io, "x.txt", .{})).close(testing.io);
    (try notvictim.createFile(testing.io, "y.txt", .{})).close(testing.io);
    notvictim.close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const victim_path = try std.fs.path.join(allocator, &.{ base, "notvictim" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -not -delete : the tree is not_expr(delete). The walk must descend the
    // .not_expr arm to reach the .delete and force depth-first.
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        victim_path, "-not", "-delete",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Whole populated directory gone -> depth-first was forced through the
    // .not_expr arm, so children were deleted before the dir.
    const victim_stat = tmp.dir.statFile(testing.io, "notvictim", .{});
    try testing.expect(victim_stat == error.FileNotFound);
}

test "find: exprContainsDelete: -delete behind -o still forces depth-first" {
    // The or_expr arm of exprContainsDelete must visit BOTH children. Here
    // -delete sits on the right of -o, behind a left operand. The walk must
    // reach it so depth_first turns on. Proof: a populated directory whose
    // entries match the left predicate is fully removed via the right -delete.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "orvictim", .default_dir);
    var orvictim = try tmp.dir.openDir(testing.io, "orvictim", .{});
    (try orvictim.createFile(testing.io, "p.dat", .{})).close(testing.io);
    (try orvictim.createFile(testing.io, "q.dat", .{})).close(testing.io);
    orvictim.close(testing.io);

    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    const victim_path = try std.fs.path.join(allocator, &.{ base, "orvictim" });

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -name nomatch* -o -delete : left never matches, so -delete fires on
    // every entry (post-order, because exprContainsDelete saw the right arm).
    const exit_code = try runFind(allocator, testing.io, &[_][]const u8{
        victim_path, "-name", "nomatch*", "-o", "-delete",
    }, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const victim_stat = tmp.dir.statFile(testing.io, "orvictim", .{});
    try testing.expect(victim_stat == error.FileNotFound);
}

// Issue #159: `--` is the POSIX end-of-options delimiter for the
// leading -H/-L/-P options. Pinned against GNU findutils 4.9.0
// (`/usr/bin/find`, LC_ALL=C). Current vibeutils treats `--` as an
// unknown predicate. A dash-named start path must be written
// `./-name`: GNU find still classifies a bare `-name` as an expression.

test "find #159: -- before path lists the tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "--", dir_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "keep.txt") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "find #159: -- after -P lists the tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "after.txt", .{});
    f1.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "-P", "--", dir_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "after.txt") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "find #159: doubled -- is an unknown predicate" {
    // GNU findutils 4.9: the first `--` ends -H/-L/-P option parsing;
    // a second `--` is an expression token and is rejected. Pin that
    // so a naive "skip every --" fix does not treat `--` as a path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "--", "--" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "unknown predicate") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "--") != null);
}

test "find #159: -- then ./dash-dir lists the dash-named tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "-dashdir", .default_dir);
    var dash = try tmp.dir.openDir(testing.io, "-dashdir", .{});
    const inner = try dash.createFile(testing.io, "inside.txt", .{});
    inner.close(testing.io);
    dash.close(testing.io);

    const dash_path = try tmp.dir.realPathFileAlloc(testing.io, "-dashdir", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "--", dash_path },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "inside.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-dashdir") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "find #159: -- path -name matches a dash-named file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "-dashfile", .{});
    f1.close(testing.io);
    const f2 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f2.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ "--", dir_path, "-name", "-dashfile" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-dashfile") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "keep.txt") == null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "find #177: path then -- is an unknown predicate" {
    // GNU findutils 4.9: `--` is a delimiter only in the leading
    // -H/-L/-P prefix, before any start path. `find . --` therefore
    // treats `--` as an expression. Current code still skips `--`
    // after a path has been collected.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "--" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    const err = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err, "unknown predicate") != null);
    try testing.expect(std.mem.find(u8, err, "--") != null);
}

test "find #178: path then -- --help is unknown predicate" {
    // GNU findutils 4.9: `find . -- --help` does not print help.
    // `--` after a path is an unknown predicate; `--help` is never
    // reached. Current runFind scans all argv for --help first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "--", "--help" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    const err = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err, "unknown predicate") != null);
    try testing.expect(std.mem.find(u8, err, "--") != null);
}

// GNU findutils 4.9: `--` is a -name pattern, then `--help` prints help.
test "find #179: -name -- --help prints help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "--", "--help" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.startsWith(u8, stdout_aw.writer.buffered(), "Usage"));
}

// GNU findutils 4.9: `--` after -true is an unknown predicate.
test "find #179: -true -- --help is unknown predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-true", "--", "--help" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    const err = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err, "unknown predicate") != null);
    try testing.expect(std.mem.find(u8, err, "--") != null);
}

// GNU findutils 4.9: `--help` before an invalid `-maxdepth` still
// prints help. Sequential parse must not pre-validate later globals.
test "find #180: --help before invalid -maxdepth prints help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "--help", "-maxdepth", "foo" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.startsWith(u8, stdout_aw.writer.buffered(), "Usage"));
}

// GNU findutils 4.9: invalid `-maxdepth` before `--help` stays an
// error; `--help` is never reached.
test "find #180: invalid -maxdepth before --help is not help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try tmp.dir.createFile(testing.io, "keep.txt", .{});
    f1.close(testing.io);
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-maxdepth", "foo", "--help" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    const err = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err, "-maxdepth") != null);
    try testing.expect(std.mem.find(u8, err, "foo") != null);
}

// GNU findutils 4.9: `--help` as a `-name` pattern is not a help
// option. The later `-maxdepth 1` still applies, so a file named
// `--help` under `sub/deep` is not listed.
test "find #181: -name --help -maxdepth 1 stays at depth 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_help = try tmp.dir.createFile(testing.io, "--help", .{});
    root_help.close(testing.io);
    try tmp.dir.createDir(testing.io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(testing.io, "sub", .{});
    try sub.createDir(testing.io, "deep", .default_dir);
    var deep = try sub.openDir(testing.io, "deep", .{});
    const deep_help = try deep.createFile(testing.io, "--help", .{});
    deep_help.close(testing.io);
    deep.close(testing.io);
    sub.close(testing.io);

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try runFind(
        allocator,
        testing.io,
        &[_][]const u8{ dir_path, "-name", "--help", "-maxdepth", "1" },
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "--help") != null);
    try testing.expect(std.mem.find(u8, out, "deep") == null);
}
