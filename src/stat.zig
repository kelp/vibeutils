//! stat - display file status
//!
//! The stat utility displays detailed information about files:
//!
//!     stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]
//!
//! This implementation follows the BSD interface described by the
//! vendored NetBSD/macOS man page in docs/specs/stat-macos.txt, which
//! docs/specs/stat-openbsd.txt confirms OpenBSD matches. The GNU long
//! options --format=FMT, --printf=FMT, --file-system, --terse and
//! --dereference survive alongside it, together with the GNU -c FORMAT,
//! because none of them collide with a BSD short flag. The two directive
//! languages are selected by the flag that introduced the string: -f
//! evaluates the BSD grammar, -c and --printf the GNU one.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = std.c;
const time = common.time;
extern "c" fn statfs(path: [*:0]const u8, buf: *StatFs) c_int;

// Platform-specific statfs structure
const StatFs = if (builtin.os.tag == .linux) extern struct {
    f_type: c_long,
    f_bsize: c_long,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: extern struct { val: [2]i32 },
    f_namelen: c_long,
    f_frsize: c_long,
    f_flags: c_long,
    f_spare: [4]c_long,
} else extern struct {
    // macOS statfs structure
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: extern struct { val: [2]i32 },
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

const prog_name = "stat";

// ============================================================================
// Parsed options
// ============================================================================

/// The output mode selected by the mutually exclusive -f/-l/-r/-s/-x group
/// of the SYNOPSIS (stat-macos.txt:7). `.default` means none was given.
const StatMode = enum { default, bsd_format, ls, raw, shell, verbose };

const StatOptions = struct {
    dereference: bool = false,
    file_system: bool = false,
    format: ?[]const u8 = null,
    printf_fmt: ?[]const u8 = null,
    terse: bool = false,
    /// -f FORMAT: the BSD format string.
    bsd_format: ?[]const u8 = null,
    /// -t TIMEFMT: the strftime(3) format used by the S form of a/m/c/B.
    timefmt: ?[]const u8 = null,
    mode: StatMode = .default,
    /// -F: append the ls(1) type suffix. Implies -l.
    type_suffix: bool = false,
    /// -n: do not force a newline after each piece of output.
    no_newline: bool = false,
    /// -q: suppress stat(2)/lstat(2) failure messages.
    quiet: bool = false,
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},
};

// ============================================================================
// Argument parsing (manual, like date.zig, for --format=FMT and --printf=FMT)
// ============================================================================

/// Result of handling one option argument: an error message (if any) and
/// whether the parent dispatch loop must stop processing further arguments.
const ParseStep = struct { err: ?[]const u8, stop: bool };

fn parseArgs(
    allocator: Allocator,
    args: []const []const u8,
) struct { opts: StatOptions, err: ?[]const u8 } {
    var opts = StatOptions{};
    var err_msg: ?[]const u8 = null;
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        // Loop invariant: the dispatch index stays within argv. i starts at 0
        // and every advance (the step, the "--" inner loop, option helpers) is
        // bounded by args.len, so args[i] below is always in range.
        std.debug.assert(i <= args.len);
        const arg = args[i];
        if (arg.len == 0) continue;

        // Not a flag
        if (arg[0] != '-') {
            positionals.append(allocator, arg) catch {
                err_msg = "memory allocation failed";
                break;
            };
            continue;
        }

        // End of flags
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                positionals.append(allocator, args[i]) catch {
                    err_msg = "memory allocation failed";
                    break;
                };
            }
            break;
        }

        // Long options
        if (arg.len > 1 and arg[1] == '-') {
            const step = parseArgs_longOption(&opts, args, &i);
            err_msg = step.err;
            if (step.stop) break;
            continue;
        }

        // Short options
        const step = parseArgs_shortOption(&opts, args, &i, arg);
        err_msg = step.err;
        if (err_msg != null) break;
    }

    // Always convert to owned slice so caller can always free
    opts.positionals = positionals.toOwnedSlice(allocator) catch {
        err_msg = "memory allocation failed";
        positionals.deinit(allocator);
        return .{ .opts = opts, .err = err_msg };
    };

    return .{ .opts = opts, .err = err_msg };
}

/// Handle one long option (arg starting with "--"). May advance `i` to
/// consume a space-separated value. Returns whether the outer loop stops.
fn parseArgs_longOption(
    opts: *StatOptions,
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch slice index into args
) ParseStep {
    std.debug.assert(i.* < args.len);
    const arg = args[i.*];
    std.debug.assert(arg.len > 1);
    std.debug.assert(arg[1] == '-');

    if (std.mem.eql(u8, arg, "--help")) {
        opts.help = true;
        return .{ .err = null, .stop = true };
    } else if (std.mem.eql(u8, arg, "--version")) {
        opts.version = true;
        return .{ .err = null, .stop = true };
    } else if (std.mem.eql(u8, arg, "--dereference")) {
        opts.dereference = true;
    } else if (std.mem.eql(u8, arg, "--file-system")) {
        opts.file_system = true;
    } else if (std.mem.eql(u8, arg, "--terse")) {
        opts.terse = true;
    } else if (std.mem.startsWith(u8, arg, "--format=")) {
        opts.format = arg["--format=".len..];
    } else if (std.mem.eql(u8, arg, "--format")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.format = args[i.*];
        } else {
            return .{ .err = "option '--format' requires an argument", .stop = true };
        }
    } else if (std.mem.startsWith(u8, arg, "--printf=")) {
        opts.printf_fmt = arg["--printf=".len..];
    } else if (std.mem.eql(u8, arg, "--printf")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.printf_fmt = args[i.*];
        } else {
            return .{ .err = "option '--printf' requires an argument", .stop = true };
        }
    } else {
        return .{ .err = "unrecognized option", .stop = true };
    }
    return .{ .err = null, .stop = false };
}

/// Handle one clustered short-option argument (e.g. "-Ln"). May advance `i`
/// to consume a space-separated value for `-c`, `-f` or `-t`. Returns any
/// error message; `-h`/`-V` set opts without an error (caller continues to
/// the next arg).
fn parseArgs_shortOption(
    opts: *StatOptions,
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch slice index into args
    arg: []const u8,
) ParseStep {
    std.debug.assert(arg.len >= 1);
    std.debug.assert(arg[0] == '-');

    var j: usize = 1; // tiger:allow:usize-arch slice index into arg
    while (j < arg.len) : (j += 1) {
        // Cluster scanning begins past the leading '-' and never rewinds, and
        // the guard keeps j addressing a real byte before indexing arg[j].
        std.debug.assert(j >= 1);
        std.debug.assert(j < arg.len);
        const ch = arg[j];
        if (ch == 'h') {
            opts.help = true;
            break;
        }
        if (ch == 'V') {
            opts.version = true;
            break;
        }
        if (parseArgs_takesValue(ch)) {
            // The value is the rest of the cluster, so nothing follows it.
            return parseArgs_shortValueOption(opts, args, i, arg, j, ch);
        }
        const step = parseArgs_shortFlag(opts, ch);
        if (step.err != null) return step;
    }
    return .{ .err = null, .stop = false };
}

/// Whether a short option consumes a value, either as the rest of its
/// cluster or as the following argv element.
fn parseArgs_takesValue(ch: u8) bool {
    return switch (ch) {
        'c', 'f', 't' => true,
        else => false,
    };
}

/// Handle one valueless short option. Unknown letters are reported so the
/// caller can fail with a usage error.
fn parseArgs_shortFlag(opts: *StatOptions, ch: u8) ParseStep {
    // The caller resolves -h, -V and the value-taking letters before
    // delegating here, so none of them can reach this switch.
    std.debug.assert(!parseArgs_takesValue(ch));
    std.debug.assert(ch != 'h');
    switch (ch) {
        'L' => opts.dereference = true,
        'n' => opts.no_newline = true,
        'q' => opts.quiet = true,
        'F' => {
            // stat-macos.txt:39: "The use of -F implies -l".
            opts.type_suffix = true;
            if (parseArgs_selectMode(opts, .ls)) |err| return .{ .err = err, .stop = true };
        },
        'l' => if (parseArgs_selectMode(opts, .ls)) |err| return .{ .err = err, .stop = true },
        'r' => if (parseArgs_selectMode(opts, .raw)) |err| return .{ .err = err, .stop = true },
        's' => if (parseArgs_selectMode(opts, .shell)) |err| return .{ .err = err, .stop = true },
        'x' => if (parseArgs_selectMode(opts, .verbose)) |err| return .{ .err = err, .stop = true },
        else => return .{ .err = "unrecognized option", .stop = true },
    }
    return .{ .err = null, .stop = false };
}

/// Handle one short option that consumes a value: -c FORMAT (GNU), -f FORMAT
/// (BSD) or -t TIMEFMT.
fn parseArgs_shortValueOption(
    opts: *StatOptions,
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch slice index into args
    arg: []const u8,
    j: usize, // tiger:allow:usize-arch slice index into arg
    ch: u8,
) ParseStep {
    std.debug.assert(parseArgs_takesValue(ch));
    std.debug.assert(j < arg.len);
    const value = parseArgs_shortValue(args, i, arg, j) orelse
        return .{ .err = parseArgs_missingValue(ch), .stop = true };

    switch (ch) {
        'c' => opts.format = value,
        't' => opts.timefmt = value,
        else => {
            opts.bsd_format = value;
            if (parseArgs_selectMode(opts, .bsd_format)) |err| {
                return .{ .err = err, .stop = true };
            }
        },
    }
    return .{ .err = null, .stop = false };
}

/// The value for a short option: the rest of its cluster, or the next argv
/// element. Null when neither is available.
fn parseArgs_shortValue(
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch slice index into args
    arg: []const u8,
    j: usize, // tiger:allow:usize-arch slice index into arg
) ?[]const u8 {
    std.debug.assert(j < arg.len);
    std.debug.assert(i.* < args.len);
    if (j + 1 < arg.len) return arg[j + 1 ..];
    if (i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

/// The usage message for a value-taking short option given without a value.
fn parseArgs_missingValue(ch: u8) []const u8 {
    std.debug.assert(parseArgs_takesValue(ch));
    std.debug.assert(ch != 'V');
    return switch (ch) {
        'c' => "option '-c' requires an argument",
        'f' => "option '-f' requires an argument",
        else => "option '-t' requires an argument",
    };
}

/// Select the single output mode from the -f/-l/-r/-s/-x group. The SYNOPSIS
/// (stat-macos.txt:7) presents them as alternatives, so a second selection is
/// a usage error rather than a silent override.
fn parseArgs_selectMode(opts: *StatOptions, mode: StatMode) ?[]const u8 {
    std.debug.assert(mode != .default);
    if (opts.mode != .default) {
        return "the -f, -l, -r, -s and -x options are mutually exclusive";
    }
    opts.mode = mode;
    std.debug.assert(opts.mode != .default);
    return null;
}

// ============================================================================
// Low-level stat wrapper
// ============================================================================

/// Cross-platform stat result. Populated from linux.statx on Linux,
/// or c.Stat via fstatat on macOS/BSD.
const StatResult = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u64,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atim: struct { sec: i64, nsec: i64 },
    mtim: struct { sec: i64, nsec: i64 },
    ctim: struct { sec: i64, nsec: i64 },
    btim: struct { sec: i64, nsec: i64 }, // birth time (0 on Linux)
    /// macOS/BSD st_flags (chflags). Always zero on Linux, which has no
    /// per-file flags field.
    flags: u32,
    /// macOS/BSD st_gen (inode generation). Always zero on Linux.
    gen: u32,
};

/// Perform stat or lstat on a path, returning a cross-platform StatResult.
fn doStat(path: []const u8, follow_symlinks: bool) !StatResult {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    // Past the length guard, the copy and sentinel write stay in bounds.
    std.debug.assert(path.len <= std.fs.max_path_bytes);
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    std.debug.assert(buf[path.len] == 0);
    const c_path = buf[0..path.len :0];

    if (builtin.os.tag == .linux) {
        return doStat_linux(c_path, follow_symlinks);
    } else {
        return doStat_darwin(c_path, follow_symlinks);
    }
}

/// Linux statx-backed stat. Maps errno to errors and composes dev/rdev ids.
fn doStat_linux(c_path: [*:0]const u8, follow_symlinks: bool) !StatResult {
    const linux = std.os.linux;
    const at_flags: u32 = if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
    // The only two flag values this helper ever issues; assert positive and
    // negative space so a future caller cannot smuggle in an unexpected bit.
    std.debug.assert(follow_symlinks == (at_flags == 0));
    std.debug.assert((!follow_symlinks) == (at_flags == linux.AT.SYMLINK_NOFOLLOW));

    return doStat_linuxAt(c.AT.FDCWD, c_path, at_flags);
}

/// Linux statx-backed stat relative to `dirfd`. The fd and path forms differ
/// only in the arguments they pass, so both share this body.
fn doStat_linuxAt(dirfd: i32, c_path: [*:0]const u8, at_flags: u32) !StatResult {
    const linux = std.os.linux;
    // Only the three lookup flags this file issues are valid here, and the
    // only negative descriptor that is meaningful is AT_FDCWD.
    std.debug.assert(at_flags <= linux.AT.EMPTY_PATH);
    std.debug.assert(dirfd >= c.AT.FDCWD);

    var stx: linux.Statx = undefined;
    const statx_mask: linux.STATX = @bitCast(@as(u32, 0xfff)); // BASIC_STATS | BTIME
    const rc = linux.statx(dirfd, c_path, at_flags, statx_mask, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .ACCES => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .LOOP => return error.SymLinkLoop,
        else => return error.SystemResources,
    }
    const dev_id = (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
    const rdev_id = (@as(u64, stx.rdev_major) << 32) | stx.rdev_minor;
    return StatResult{
        .dev = dev_id,
        .ino = stx.ino,
        .mode = stx.mode,
        .nlink = stx.nlink,
        .uid = stx.uid,
        .gid = stx.gid,
        .rdev = rdev_id,
        .size = @intCast(stx.size),
        .blksize = @intCast(stx.blksize),
        .blocks = @intCast(stx.blocks),
        .atim = .{ .sec = stx.atime.sec, .nsec = @intCast(stx.atime.nsec) },
        .mtim = .{ .sec = stx.mtime.sec, .nsec = @intCast(stx.mtime.nsec) },
        .ctim = .{ .sec = stx.ctime.sec, .nsec = @intCast(stx.ctime.nsec) },
        .btim = .{ .sec = stx.btime.sec, .nsec = @intCast(stx.btime.nsec) },
        // Linux has no st_flags or st_gen; the BSD %f and %v datums report 0.
        .flags = 0,
        .gen = 0,
    };
}

/// macOS/BSD fstatat-backed stat. Maps errno to errors.
fn doStat_darwin(c_path: [*:0]const u8, follow_symlinks: bool) !StatResult {
    var stat_buf: c.Stat = undefined;
    const flags: u32 = if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW;
    // The only two flag values this helper ever issues; assert positive and
    // negative space so a future caller cannot smuggle in an unexpected bit.
    std.debug.assert(follow_symlinks == (flags == 0));
    std.debug.assert((!follow_symlinks) == (flags == c.AT.SYMLINK_NOFOLLOW));

    const result = c.fstatat(c.AT.FDCWD, c_path, &stat_buf, flags);
    if (result != 0) return doStat_darwinError(result);
    return doStat_fromDarwinStat(stat_buf);
}

/// The errors doStat reports, named after the errno values stat(2) sets.
const StatError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    SymLinkLoop,
    SystemResources,
};

/// Map a failed fstat/fstatat return value to this module's error set.
fn doStat_darwinError(result: c_int) StatError {
    std.debug.assert(result != 0);
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

/// Build a StatResult from a macOS/BSD struct stat.
fn doStat_fromDarwinStat(stat_buf: c.Stat) StatResult {
    return StatResult{
        .dev = @intCast(stat_buf.dev),
        .ino = @intCast(stat_buf.ino),
        .mode = @intCast(stat_buf.mode),
        .nlink = @intCast(stat_buf.nlink),
        .uid = @intCast(stat_buf.uid),
        .gid = @intCast(stat_buf.gid),
        .rdev = @intCast(stat_buf.rdev),
        .size = @intCast(stat_buf.size),
        .blksize = @intCast(stat_buf.blksize),
        .blocks = @intCast(stat_buf.blocks),
        .atim = .{ .sec = stat_buf.atimespec.sec, .nsec = stat_buf.atimespec.nsec },
        .mtim = .{ .sec = stat_buf.mtimespec.sec, .nsec = stat_buf.mtimespec.nsec },
        .ctim = .{ .sec = stat_buf.ctimespec.sec, .nsec = stat_buf.ctimespec.nsec },
        .btim = .{ .sec = stat_buf.birthtimespec.sec, .nsec = stat_buf.birthtimespec.nsec },
        .flags = if (@hasField(@TypeOf(stat_buf), "flags")) @intCast(stat_buf.flags) else 0,
        .gen = if (@hasField(@TypeOf(stat_buf), "gen")) @intCast(stat_buf.gen) else 0,
    };
}

/// Perform fstat(2) on an already-open descriptor. With no file operand stat
/// reports on standard input's descriptor (stat-macos.txt:14-15).
fn doStatFd(fd: i32) !StatResult {
    std.debug.assert(fd >= 0);
    std.debug.assert(fd != -1);
    if (builtin.os.tag == .linux) {
        // AT_EMPTY_PATH turns statx into fstat for an empty path.
        return doStat_linuxAt(fd, "", std.os.linux.AT.EMPTY_PATH);
    } else {
        var stat_buf: c.Stat = undefined;
        const result = c.fstat(fd, &stat_buf);
        if (result != 0) return doStat_darwinError(result);
        return doStat_fromDarwinStat(stat_buf);
    }
}

// ============================================================================
// Time formatting helpers
// ============================================================================

fn getTimespecSec(stat_buf: StatResult, comptime which: enum { atime, mtime, ctime, btime }) i64 {
    return switch (which) {
        .atime => stat_buf.atim.sec,
        .mtime => stat_buf.mtim.sec,
        .ctime => stat_buf.ctim.sec,
        .btime => stat_buf.btim.sec,
    };
}

fn getTimespecNsec(stat_buf: StatResult, comptime which: enum { atime, mtime, ctime, btime }) i64 {
    return switch (which) {
        .atime => stat_buf.atim.nsec,
        .mtime => stat_buf.mtim.nsec,
        .ctime => stat_buf.ctim.nsec,
        .btime => stat_buf.btim.nsec,
    };
}

/// Format a timestamp as "YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ"
fn formatTimestamp(sec: i64, nsec: i64, fmt_buf: []u8) ![]const u8 {
    // The fixed-width template needs at least 35 bytes ("YYYY-MM-DD
    // HH:MM:SS.NNNNNNNNN +ZZZZ"); all callers pass a [64]u8 buffer.
    std.debug.assert(fmt_buf.len >= 35);
    const time_val: c.time_t = @intCast(sec);
    var tm: time.c_tm = undefined;
    if (time.localtime_r(&time_val, &tm) == null) {
        return error.TimeConversion;
    }

    const year: u32 = @intCast(@as(i32, tm.tm_year) + 1900);
    const mon = @as(u32, @intCast(tm.tm_mon)) + 1;
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const min: u32 = @intCast(tm.tm_min);
    const s: u32 = @intCast(tm.tm_sec);
    const ns: u64 = @intCast(if (nsec < 0) 0 else nsec);

    // Timezone offset
    const gmtoff = tm.tm_gmtoff;
    const sign: u8 = if (gmtoff < 0) '-' else '+';
    const abs_off: u64 = if (gmtoff < 0) @intCast(-gmtoff) else @intCast(gmtoff);
    const tz_hours = @divTrunc(abs_off, 3600);
    const tz_mins = @divTrunc(@rem(abs_off, 3600), 60);

    return std.fmt.bufPrint(
        fmt_buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9} {c}{d:0>2}{d:0>2}",
        .{ year, mon, day, hour, min, s, ns, sign, tz_hours, tz_mins },
    );
}

// ============================================================================
// File type string
// ============================================================================

fn fileTypeString(mode: u32) []const u8 {
    return switch (mode & c.S.IFMT) {
        c.S.IFREG => "regular file",
        c.S.IFDIR => "directory",
        c.S.IFLNK => "symbolic link",
        c.S.IFCHR => "character special file",
        c.S.IFBLK => "block special file",
        c.S.IFIFO => "fifo",
        c.S.IFSOCK => "socket",
        else => "unknown",
    };
}

// ============================================================================
// Permission string (like ls -l): -rwxr-xr-x
// ============================================================================

fn formatPermissions(mode: u32, perm_buf: *[10]u8) []const u8 {
    // File type character
    perm_buf[0] = switch (mode & c.S.IFMT) {
        c.S.IFDIR => 'd',
        c.S.IFCHR => 'c',
        c.S.IFBLK => 'b',
        c.S.IFIFO => 'p',
        c.S.IFLNK => 'l',
        c.S.IFSOCK => 's',
        c.S.IFREG => '-',
        else => '?',
    };

    // Owner
    perm_buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    perm_buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    perm_buf[3] = if (mode & 0o100 != 0) 'x' else '-';

    // Group
    perm_buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    perm_buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    perm_buf[6] = if (mode & 0o010 != 0) 'x' else '-';

    // Other
    perm_buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    perm_buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    perm_buf[9] = if (mode & 0o001 != 0) 'x' else '-';

    // Setuid/setgid/sticky
    if (mode & 0o4000 != 0) {
        perm_buf[3] = if (perm_buf[3] == 'x') 's' else 'S';
    }
    if (mode & 0o2000 != 0) {
        perm_buf[6] = if (perm_buf[6] == 'x') 's' else 'S';
    }
    if (mode & 0o1000 != 0) {
        perm_buf[9] = if (perm_buf[9] == 'x') 't' else 'T';
    }

    // Postconditions: slot 0 always holds a printable type char (never the
    // undefined sentinel), and the owner-execute slot holds one of its four
    // possible glyphs. Pairs the "every slot was written" property across two
    // code paths.
    std.debug.assert(perm_buf[0] != 0);
    const owner_exec_valid = switch (perm_buf[3]) {
        'x', '-', 's', 'S' => true,
        else => false,
    };
    std.debug.assert(owner_exec_valid);

    return perm_buf[0..10];
}

// ============================================================================
// Format directive expansion
// ============================================================================

fn expandFormatDirective(
    allocator: Allocator,
    directive: u8,
    stat_buf: StatResult,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    // Each directive maps to one emit step; the per-directive meaning matches
    // the format table in printHelp (e.g. %a = access rights in octal).
    switch (directive) {
        'a' => try writer.print("{o}", .{mode & 0o7777}),
        'A' => try expandFormatDirective_permString(mode, writer),
        'b' => try writer.print("{d}", .{stat_buf.blocks}),
        'B' => try writer.print("512", .{}),
        'd' => try writer.print("{d}", .{stat_buf.dev}),
        'D' => try writer.print("{x}", .{stat_buf.dev}),
        'f' => try writer.print("{x}", .{mode}),
        'F' => try expandFormatDirective_fileType(stat_buf, mode, writer),
        'g' => try writer.print("{d}", .{stat_buf.gid}),
        'G' => try expandFormatDirective_groupName(allocator, stat_buf, writer),
        'h' => try writer.print("{d}", .{stat_buf.nlink}),
        'i' => try writer.print("{d}", .{stat_buf.ino}),
        'm' => try expandFormatDirective_mountPoint(path, writer),
        'n' => try writer.writeAll(path),
        'N' => try expandFormatDirective_quotedName(stat_buf, path, follow_symlinks, writer),
        'o' => try writer.print("{d}", .{stat_buf.blksize}),
        's' => try writer.print("{d}", .{stat_buf.size}),
        't' => try expandFormatDirective_deviceType(stat_buf, .major, writer),
        'T' => try expandFormatDirective_deviceType(stat_buf, .minor, writer),
        'u' => try writer.print("{d}", .{stat_buf.uid}),
        'U' => try expandFormatDirective_userName(allocator, stat_buf, writer),
        'w' => try expandFormatDirective_birthTime(stat_buf, writer),
        'W' => try expandFormatDirective_birthEpoch(stat_buf, writer),
        'x' => try expandFormatDirective_humanTime(stat_buf, .atime, writer),
        'X' => try writer.print("{d}", .{getTimespecSec(stat_buf, .atime)}),
        'y' => try expandFormatDirective_humanTime(stat_buf, .mtime, writer),
        'Y' => try writer.print("{d}", .{getTimespecSec(stat_buf, .mtime)}),
        'z' => try expandFormatDirective_humanTime(stat_buf, .ctime, writer),
        'Z' => try writer.print("{d}", .{getTimespecSec(stat_buf, .ctime)}),
        else => {
            // Unknown directive, print literal.
            try writer.writeByte('%');
            try writer.writeByte(directive);
        },
    }
}

/// %A: access rights in the human-readable "-rwxr-xr-x" form.
fn expandFormatDirective_permString(mode: u32, writer: anytype) !void {
    std.debug.assert(mode != 0);
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);
    try writer.writeAll(perms);
}

/// %F: the file type, reporting "regular empty file" for a zero-length file.
fn expandFormatDirective_fileType(stat_buf: StatResult, mode: u32, writer: anytype) !void {
    std.debug.assert((mode & c.S.IFMT) != 0);
    std.debug.assert(mode != 0);
    const size: i64 = @intCast(stat_buf.size);
    if ((mode & c.S.IFMT) == c.S.IFREG and size == 0) {
        try writer.writeAll("regular empty file");
    } else {
        try writer.writeAll(fileTypeString(mode));
    }
}

/// %G: the group name, falling back to the numeric gid on lookup failure.
fn expandFormatDirective_groupName(
    allocator: Allocator,
    stat_buf: StatResult,
    writer: anytype,
) !void {
    const gid: u32 = @intCast(stat_buf.gid);
    const group_info = common.user_group.getGroupById(gid, allocator) catch {
        try writer.print("{d}", .{gid});
        return;
    };
    defer allocator.free(group_info.name);
    try writer.writeAll(group_info.name);
}

/// %U: the user name, falling back to the numeric uid on lookup failure.
fn expandFormatDirective_userName(
    allocator: Allocator,
    stat_buf: StatResult,
    writer: anytype,
) !void {
    const uid: u32 = @intCast(stat_buf.uid);
    const user_info = common.user_group.getUserById(uid, allocator) catch {
        try writer.print("{d}", .{uid});
        return;
    };
    defer allocator.free(user_info.name);
    try writer.writeAll(user_info.name);
}

/// %W: the birth time as seconds since the epoch, "0" when unknown.
fn expandFormatDirective_birthEpoch(stat_buf: StatResult, writer: anytype) !void {
    const btime_sec = getTimespecSec(stat_buf, .btime);
    if (btime_sec == 0) {
        try writer.writeAll("0");
    } else {
        try writer.print("{d}", .{btime_sec});
    }
}

/// %m: emit the mount point for `path` (Linux: /proc/self/mountinfo;
/// macOS: statfs f_mntonname), or "?" when it cannot be determined.
fn expandFormatDirective_mountPoint(path: []const u8, writer: anytype) !void {
    std.debug.assert(path.len > 0);
    if (builtin.os.tag == .linux) {
        var mount_buf: [1024]u8 = undefined;
        var dev_buf: [1024]u8 = undefined;
        const info = lookupMountInfo(path, &mount_buf, &dev_buf);
        try writer.writeAll(info.mount);
    } else {
        var path_buf2: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len > std.fs.max_path_bytes) {
            try writer.writeAll("?");
            return;
        }
        @memcpy(path_buf2[0..path.len], path);
        path_buf2[path.len] = 0;
        const c_path2 = path_buf2[0..path.len :0];

        var fs_buf2: StatFs = undefined;
        if (statfs(c_path2, &fs_buf2) == 0) {
            const mntonname = std.mem.sliceTo(&fs_buf2.f_mntonname, 0);
            try writer.writeAll(mntonname);
        } else {
            try writer.writeAll("?");
        }
    }
}

/// Read the target of the symbolic link at `path` into `buf`. Returns null
/// when the path is too long for the kernel interface or readlink(2) fails,
/// which callers treat as "no target to show".
fn readLinkTarget(path: []const u8, buf: []u8) ?[]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(buf.len >= 64);
    if (path.len > std.fs.max_path_bytes) return null;
    var path_zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_zbuf[0..path.len], path);
    path_zbuf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_zbuf);

    const n = c.readlink(path_z, buf.ptr, buf.len);
    if (n <= 0) return null;
    // readlink(2) never reports more than the buffer size it was given, so
    // the cast below stays in bounds.
    std.debug.assert(n <= @as(isize, @intCast(buf.len)));
    const length: usize = @intCast(n); // tiger:allow:usize-arch slice length
    return buf[0..length];
}

/// %N: emit the quoted file name, appending " -> 'TARGET'" for an
/// unfollowed symbolic link.
fn expandFormatDirective_quotedName(
    stat_buf: StatResult,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    std.debug.assert(stat_buf.mode != 0);
    std.debug.assert((mode & c.S.IFMT) != 0);
    if ((mode & c.S.IFMT) != c.S.IFLNK) {
        try writer.print("'{s}'", .{path});
        return;
    }
    if (follow_symlinks) {
        try writer.print("'{s}'", .{path});
        return;
    }
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = readLinkTarget(path, &link_buf) orelse {
        try writer.print("'{s}'", .{path});
        return;
    };
    try writer.print("'{s}' -> '{s}'", .{ path, target });
}

/// %t / %T: emit the major or minor device number of rdev in hex, using
/// the platform's documented bit layout.
fn expandFormatDirective_deviceType(
    stat_buf: StatResult,
    comptime part: enum { major, minor },
    writer: anytype,
) !void {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        const rdev: u32 = @intCast(stat_buf.rdev);
        const val = switch (part) {
            .major => (rdev >> 24) & 0xff,
            .minor => rdev & 0xffffff,
        };
        try writer.print("{x}", .{val});
    } else {
        const rdev: u64 = @intCast(stat_buf.rdev);
        const val = switch (part) {
            .major => (rdev >> 8) & 0xfff,
            .minor => rdev & 0xff,
        };
        try writer.print("{x}", .{val});
    }
}

/// %w: emit the birth time in human-readable form, or "-" when unknown
/// (sec == 0) or formatting fails.
fn expandFormatDirective_birthTime(stat_buf: StatResult, writer: anytype) !void {
    const btime_sec = getTimespecSec(stat_buf, .btime);
    if (btime_sec == 0) {
        try writer.writeAll("-");
    } else {
        var fmt_buf: [64]u8 = undefined;
        const btime_nsec = getTimespecNsec(stat_buf, .btime);
        const formatted = formatTimestamp(btime_sec, btime_nsec, &fmt_buf) catch {
            try writer.writeAll("-");
            return;
        };
        try writer.writeAll(formatted);
    }
}

/// %x / %y / %z: emit the selected timestamp in human-readable form,
/// falling back to "-" when formatting fails.
fn expandFormatDirective_humanTime(
    stat_buf: StatResult,
    comptime which: enum { atime, mtime, ctime },
    writer: anytype,
) !void {
    const field = comptime switch (which) {
        .atime => .atime,
        .mtime => .mtime,
        .ctime => .ctime,
    };
    const sec = getTimespecSec(stat_buf, field);
    const nsec = getTimespecNsec(stat_buf, field);
    var fmt_buf: [64]u8 = undefined;
    const formatted = formatTimestamp(sec, nsec, &fmt_buf) catch {
        try writer.writeAll("-");
        return;
    };
    try writer.writeAll(formatted);
}

// ============================================================================
// Format string processing
// ============================================================================

fn processFormatString(
    allocator: Allocator,
    format: []const u8,
    stat_buf: StatResult,
    path: []const u8,
    follow_symlinks: bool,
    interpret_escapes: bool,
    writer: anytype,
) !void {
    var i: usize = 0;
    while (i < format.len) {
        // Loop invariant: i never overruns the format string. Every branch
        // advances i by 1 or 2 (the latter only under i + 1 < format.len), and
        // the octal-escape inner loop is itself guarded by i < format.len.
        std.debug.assert(i <= format.len);
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;
            try expandFormatDirective(
                allocator,
                format[i],
                stat_buf,
                path,
                follow_symlinks,
                writer,
            );
            i += 1;
        } else if (interpret_escapes and format[i] == '\\' and i + 1 < format.len) {
            i += 1;
            switch (format[i]) {
                'n' => try writer.writeByte('\n'),
                't' => try writer.writeByte('\t'),
                'r' => try writer.writeByte('\r'),
                '\\' => try writer.writeByte('\\'),
                'a' => try writer.writeByte(0x07),
                'b' => try writer.writeByte(0x08),
                'f' => try writer.writeByte(0x0C),
                'v' => try writer.writeByte(0x0B),
                '0' => {
                    // Octal escape
                    var val: u8 = 0;
                    var count: usize = 0;
                    i += 1;
                    while (i < format.len and count < 3 and format[i] >= '0' and format[i] <= '7') {
                        val = val * 8 + (format[i] - '0');
                        count += 1;
                        i += 1;
                    }
                    try writer.writeByte(val);
                    continue; // Already advanced i
                },
                else => {
                    try writer.writeByte('\\');
                    try writer.writeByte(format[i]);
                },
            }
            i += 1;
        } else {
            try writer.writeByte(format[i]);
            i += 1;
        }
    }
}

// ============================================================================
// BSD format engine (stat-macos.txt:74-211)
//
// A directive is %[flags][size][.prec][fmt][sub]datum. Parsing produces a
// BsdDirective; rendering turns the selected datum into a number, a string or
// a timestamp, and a single padding helper applies width and alignment so
// every datum obeys the same rules.
// ============================================================================

/// The output form selected by the optional `fmt` field: signed decimal,
/// octal, unsigned decimal, hexadecimal, floating point, string.
const BsdFmt = enum { signed, octal, unsigned, hex, float, string };

/// The optional sub-field specifier (stat-macos.txt:142-160).
const BsdSub = enum { none, high, middle, low };

/// One parsed directive.
const BsdDirective = struct {
    alt: bool = false,
    plus: bool = false,
    left: bool = false,
    zero: bool = false,
    space: bool = false,
    width: u32 = 0,
    precision: ?u32 = null,
    fmt: ?BsdFmt = null,
    sub: BsdSub = .none,
    datum: u8 = 0,
    /// Bytes consumed from the spec, which starts just after the '%'.
    len: u32 = 0,
};

/// A timestamp datum, kept as a named type so it can be passed on.
const BsdTimestamp = struct { sec: i64, nsec: i64 };

/// What a datum expands to before the output form is applied.
const BsdValue = union(enum) {
    number: i64,
    text: []const u8,
    timestamp: BsdTimestamp,
};

/// Everything a directive may need beyond the directive itself.
const BsdContext = struct {
    allocator: Allocator,
    stat_buf: StatResult,
    path: []const u8,
    timefmt: []const u8,
};

/// Field widths and precisions above this are clamped, which bounds the
/// padding loop without changing any realistic output.
const bsd_field_max: u32 = 4096;

/// Scratch space one directive may use. Large enough for any path, since
/// %N, %R and %Y all render one.
const bsd_scratch_len = std.fs.max_path_bytes + 64;

/// The default output format (stat-macos.txt:218-222).
const bsd_default_format =
    "%d %i %Sp %l %Su %Sg %r %z \"%Sa\" \"%Sm\" \"%Sc\" \"%SB\" %k %b %#Xf %N";

/// -r: every struct stat field as a raw number (stat-macos.txt:60-62).
const bsd_raw_format = "%d %i %#p %l %u %g %r %z %a %m %c %B %k %b %#Xf %N";

/// -l: ls -lT format (stat-macos.txt:51, example at :231).
const bsd_ls_format = "%Sp %l %Su %Sg %Z %Sm %N%SY";

/// -F: ls -lT format plus the ls(1) type suffix (example at :228).
const bsd_ls_suffix_format = "%Sp %l %Su %Sg %Z %Sm %N%T%SY";

/// -s: shell variable assignments (stat-macos.txt:64-65). The field names are
/// the struct stat member names, as macOS emits them.
const bsd_shell_format = "st_dev=%d st_ino=%i st_mode=%#p st_nlink=%l " ++
    "st_uid=%u st_gid=%g st_rdev=%r st_size=%z " ++
    "st_atime=%a st_mtime=%m st_ctime=%c st_birthtime=%B " ++
    "st_blksize=%k st_blocks=%b st_flags=%f";

/// -x: the verbose multi-line block (stat-macos.txt:71-72).
const bsd_verbose_format = "  File: \"%N\"%n" ++
    "  Size: %-11z" ++
    "FileType: %HT%n" ++
    "  Mode: (%Mp%03Lp/%.10Sp)" ++
    "         Uid: (%5u/%8Su)" ++
    "  Gid: (%5g/%8Sg)%n" ++
    "Device: %Hd,%Ld" ++
    "   Inode: %i" ++
    "   Links: %l%n" ++
    "Access: %Sa%n" ++
    "Modify: %Sm%n" ++
    "Change: %Sc%n" ++
    " Birth: %SB";

/// The strftime(3) format the S form of a time datum uses without -t.
const bsd_default_timefmt = "%b %e %H:%M:%S %Y";

/// The output form character, if `ch` is one (stat-macos.txt:113-118).
fn bsdFmtFromChar(ch: u8) ?BsdFmt {
    return switch (ch) {
        'D' => .signed,
        'O' => .octal,
        'U' => .unsigned,
        'X' => .hex,
        'F' => .float,
        'S' => .string,
        else => null,
    };
}

/// The sub-field specifier, if `ch` is one (stat-macos.txt:142-160).
fn bsdSubFromChar(ch: u8) ?BsdSub {
    return switch (ch) {
        'H' => .high,
        'M' => .middle,
        'L' => .low,
        else => null,
    };
}

/// Whether `ch` selects a field (stat-macos.txt:162-207). None of these
/// letters is also an output form or sub-field letter, so the grammar parses
/// without lookahead.
fn isBsdDatum(ch: u8) bool {
    const datums = "dipluagrmcBzbkfvNRTYZ";
    for (datums) |candidate| {
        if (candidate == ch) return true;
    }
    return false;
}

/// The output form actually used: the explicit one, or the datum's documented
/// default (stat-macos.txt:209-211).
fn effectiveBsdFmt(d: BsdDirective) BsdFmt {
    if (d.fmt) |explicit| return explicit;
    return switch (d.datum) {
        'p' => .octal,
        'a', 'm', 'c' => .signed,
        'N', 'R', 'T', 'Y' => .string,
        else => .unsigned,
    };
}

/// Parse one directive from `spec`, which starts just after the '%'. Returns
/// null when the spec does not end in a known datum; the caller then emits the
/// '%' literally.
fn parseBsdDirective(spec: []const u8) ?BsdDirective {
    std.debug.assert(spec.len > 0);
    var d: BsdDirective = .{};

    var i = parseBsdDirective_flags(spec, &d);
    i = parseBsdDirective_width(spec, i, &d);
    i = parseBsdDirective_precision(spec, i, &d);

    if (i < spec.len) {
        if (bsdFmtFromChar(spec[i])) |form| {
            d.fmt = form;
            i += 1;
        }
    }
    if (i < spec.len) {
        if (bsdSubFromChar(spec[i])) |sub| {
            d.sub = sub;
            i += 1;
        }
    }
    if (i >= spec.len) return null;
    if (!isBsdDatum(spec[i])) return null;

    d.datum = spec[i];
    d.len = i + 1;
    std.debug.assert(d.len >= 1);
    std.debug.assert(d.len <= spec.len);
    return d;
}

/// Consume the leading flag characters (stat-macos.txt:83-100), returning the
/// new cursor.
fn parseBsdDirective_flags(spec: []const u8, d: *BsdDirective) u32 {
    std.debug.assert(spec.len > 0);
    var i: u32 = 0;
    while (i < spec.len) : (i += 1) {
        switch (spec[i]) {
            '#' => d.alt = true,
            '+' => d.plus = true,
            '-' => d.left = true,
            '0' => d.zero = true,
            ' ' => d.space = true,
            else => break,
        }
    }
    std.debug.assert(i <= spec.len);
    return i;
}

/// Consume the optional minimum field width (stat-macos.txt:104-105).
fn parseBsdDirective_width(spec: []const u8, start: u32, d: *BsdDirective) u32 {
    std.debug.assert(start <= spec.len);
    var i = start;
    while (i < spec.len) : (i += 1) {
        if (spec[i] < '0') break;
        if (spec[i] > '9') break;
        // The clamp keeps the running value far below the u32 range, so the
        // accumulation below cannot overflow.
        const digit: u32 = spec[i] - '0';
        d.width = @min(d.width * 10 + digit, bsd_field_max);
    }
    std.debug.assert(i >= start);
    std.debug.assert(d.width <= bsd_field_max);
    return i;
}

/// Consume the optional precision (stat-macos.txt:107-111).
fn parseBsdDirective_precision(spec: []const u8, start: u32, d: *BsdDirective) u32 {
    std.debug.assert(start <= spec.len);
    if (start >= spec.len) return start;
    if (spec[start] != '.') return start;

    var i = start + 1;
    var value: u32 = 0;
    while (i < spec.len) : (i += 1) {
        if (spec[i] < '0') break;
        if (spec[i] > '9') break;
        // Clamped every step, so the accumulation stays inside u32.
        const digit: u32 = spec[i] - '0';
        value = @min(value * 10 + digit, bsd_field_max);
    }
    d.precision = value;
    std.debug.assert(i > start);
    std.debug.assert(value <= bsd_field_max);
    return i;
}

/// Render `format` with the BSD directive grammar.
fn processBsdFormat(
    format: []const u8,
    ctx: BsdContext,
    file_number: u32,
    writer: anytype,
) !void {
    std.debug.assert(file_number >= 1);
    std.debug.assert(ctx.path.len <= std.fs.max_path_bytes);
    var i: u32 = 0;
    while (i < format.len) {
        // Every branch advances the cursor by at least one byte, so the scan
        // is bounded by the length of the format string.
        std.debug.assert(i < format.len);
        if (format[i] != '%') {
            try writer.writeByte(format[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= format.len) {
            try writer.writeByte('%');
            i += 1;
            continue;
        }
        const spec = format[i + 1 ..];
        const consumed = try processBsdFormat_directive(spec, ctx, file_number, writer);
        i += 1 + consumed;
    }
}

/// Emit one directive from `spec` (the bytes just after the '%'), returning
/// how many of them were consumed. An unparseable spec consumes nothing and
/// emits a literal '%'.
fn processBsdFormat_directive(
    spec: []const u8,
    ctx: BsdContext,
    file_number: u32,
    writer: anytype,
) !u32 {
    std.debug.assert(spec.len > 0);
    std.debug.assert(file_number >= 1);
    // stat-macos.txt:78-80: n, t, % and @ are recognised immediately after
    // the '%', before any flag can appear.
    switch (spec[0]) {
        'n' => {
            try writer.writeByte('\n');
            return 1;
        },
        't' => {
            try writer.writeByte('\t');
            return 1;
        },
        '%' => {
            try writer.writeByte('%');
            return 1;
        },
        '@' => {
            try writer.print("{d}", .{file_number});
            return 1;
        },
        else => {},
    }
    const directive = parseBsdDirective(spec) orelse {
        try writer.writeByte('%');
        return 0;
    };
    try emitBsdDirective(directive, ctx, writer);
    return directive.len;
}

/// Expand one parsed directive.
fn emitBsdDirective(d: BsdDirective, ctx: BsdContext, writer: anytype) !void {
    std.debug.assert(d.datum != 0);
    std.debug.assert(d.len >= 1);
    var scratch: [bsd_scratch_len]u8 = undefined;
    switch (bsdDatumValue(d, ctx, &scratch)) {
        .number => |value| try writeBsdNumber(d, value, writer),
        .text => |text| try writeBsdText(d, text, writer),
        .timestamp => |ts| try writeBsdTimestamp(d, ts, ctx.timefmt, writer),
    }
}

/// Expand the directive's datum to a value (stat-macos.txt:162-207).
fn bsdDatumValue(d: BsdDirective, ctx: BsdContext, scratch: []u8) BsdValue {
    std.debug.assert(d.datum != 0);
    std.debug.assert(scratch.len >= 256);
    const st = ctx.stat_buf;
    return switch (d.datum) {
        'd' => bsdDeviceValue(d, st.dev, scratch),
        'r' => bsdDeviceValue(d, st.rdev, scratch),
        'i' => .{ .number = @as(i64, @bitCast(st.ino)) },
        'p' => bsdModeValue(d, st.mode, scratch),
        'l' => .{ .number = @as(i64, @bitCast(st.nlink)) },
        'u' => bsdUserValue(d, ctx, scratch),
        'g' => bsdGroupValue(d, ctx, scratch),
        'a' => .{ .timestamp = .{ .sec = st.atim.sec, .nsec = st.atim.nsec } },
        'm' => .{ .timestamp = .{ .sec = st.mtim.sec, .nsec = st.mtim.nsec } },
        'c' => .{ .timestamp = .{ .sec = st.ctim.sec, .nsec = st.ctim.nsec } },
        'B' => .{ .timestamp = .{ .sec = st.btim.sec, .nsec = st.btim.nsec } },
        'z' => .{ .number = st.size },
        'b' => .{ .number = st.blocks },
        'k' => .{ .number = st.blksize },
        'f' => bsdFlagsValue(d, st.flags, scratch),
        'v' => .{ .number = st.gen },
        'N' => .{ .text = ctx.path },
        'R' => .{ .text = bsdRealPathText(ctx.path, scratch) },
        'T' => .{ .text = bsdFileTypeText(d.sub, st.mode) },
        'Y' => bsdSymlinkValue(d, ctx, scratch),
        'Z' => bsdSizeRdevValue(d, st, scratch),
        else => .{ .text = "" },
    };
}

/// %d and %r. The H and L sub-fields select the major and minor numbers. BSD
/// renders the string form with devname(3), which Linux has no equivalent
/// for, so the numeric identity is rendered on both platforms instead.
fn bsdDeviceValue(d: BsdDirective, dev: u64, scratch: []u8) BsdValue {
    std.debug.assert(isBsdDatum(d.datum));
    std.debug.assert(scratch.len >= 32);
    const piece: u64 = switch (d.sub) {
        .high => devMajor(dev),
        .low => devMinor(dev),
        .none, .middle => dev,
    };
    if (effectiveBsdFmt(d) == .string) {
        const text = std.fmt.bufPrint(scratch, "{d}", .{piece}) catch return .{ .text = "?" };
        return .{ .text = text };
    }
    return .{ .number = @as(i64, @bitCast(piece)) };
}

/// The major number encoded in a StatResult device id. The layout matches how
/// doStat composes the id on each platform, not the kernel's own encoding.
fn devMajor(dev: u64) u64 {
    if (builtin.os.tag == .linux) return dev >> 32;
    return (dev >> 24) & 0xff;
}

/// The minor number encoded in a StatResult device id.
fn devMinor(dev: u64) u64 {
    if (builtin.os.tag == .linux) return dev & 0xffffffff;
    return dev & 0xffffff;
}

/// %p. The string form is the ls -lTd mode string, sliced by the sub-field
/// into the user, group or other triplet; the numeric forms report the type,
/// setuid/setgid/sticky, or permission bits (stat-macos.txt:146-160).
fn bsdModeValue(d: BsdDirective, mode: u32, scratch: []u8) BsdValue {
    std.debug.assert(d.datum == 'p');
    std.debug.assert(scratch.len >= 16);
    if (effectiveBsdFmt(d) == .string) {
        var perm_buf: [10]u8 = undefined;
        const perms = formatPermissions(mode, &perm_buf);
        const piece: []const u8 = switch (d.sub) {
            .none => perms[0..10],
            .high => perms[1..4],
            .middle => perms[4..7],
            .low => perms[7..10],
        };
        // perms points at a local buffer, so the piece is copied out.
        @memcpy(scratch[0..piece.len], piece);
        return .{ .text = scratch[0..piece.len] };
    }
    const numeric: u32 = switch (d.sub) {
        .none => mode,
        .high => mode >> 12,
        .middle => (mode >> 9) & 0o7,
        .low => mode & 0o777,
    };
    return .{ .number = numeric };
}

/// %u: the numeric uid, or the login name for the string form.
fn bsdUserValue(d: BsdDirective, ctx: BsdContext, scratch: []u8) BsdValue {
    std.debug.assert(d.datum == 'u');
    std.debug.assert(scratch.len >= 256);
    const uid: u32 = ctx.stat_buf.uid;
    if (effectiveBsdFmt(d) != .string) return .{ .number = uid };
    const user_info = common.user_group.getUserById(uid, ctx.allocator) catch {
        const text = std.fmt.bufPrint(scratch, "{d}", .{uid}) catch return .{ .text = "?" };
        return .{ .text = text };
    };
    defer ctx.allocator.free(user_info.name);
    if (user_info.name.len > scratch.len) return .{ .text = "?" };
    @memcpy(scratch[0..user_info.name.len], user_info.name);
    return .{ .text = scratch[0..user_info.name.len] };
}

/// %g: the numeric gid, or the group name for the string form.
fn bsdGroupValue(d: BsdDirective, ctx: BsdContext, scratch: []u8) BsdValue {
    std.debug.assert(d.datum == 'g');
    std.debug.assert(scratch.len >= 256);
    const gid: u32 = ctx.stat_buf.gid;
    if (effectiveBsdFmt(d) != .string) return .{ .number = gid };
    const group_info = common.user_group.getGroupById(gid, ctx.allocator) catch {
        const text = std.fmt.bufPrint(scratch, "{d}", .{gid}) catch return .{ .text = "?" };
        return .{ .text = text };
    };
    defer ctx.allocator.free(group_info.name);
    if (group_info.name.len > scratch.len) return .{ .text = "?" };
    @memcpy(scratch[0..group_info.name.len], group_info.name);
    return .{ .text = scratch[0..group_info.name.len] };
}

/// %f: the user defined flags. Linux has no st_flags, so it always reports 0.
fn bsdFlagsValue(d: BsdDirective, flags: u32, scratch: []u8) BsdValue {
    std.debug.assert(d.datum == 'f');
    std.debug.assert(scratch.len >= 128);
    if (effectiveBsdFmt(d) != .string) return .{ .number = flags };
    return .{ .text = bsdFlagsText(flags, scratch) };
}

/// Render st_flags as the comma-separated names ls -lTdo prints, or "-" when
/// no flag is set. The table is the inverse of find.zig's name-to-mask one.
fn bsdFlagsText(flags: u32, scratch: []u8) []const u8 {
    std.debug.assert(scratch.len >= 128);
    const table = [_]struct { mask: u32, name: []const u8 }{
        .{ .mask = 0x00000001, .name = "nodump" },
        .{ .mask = 0x00000002, .name = "uchg" },
        .{ .mask = 0x00000004, .name = "uappnd" },
        .{ .mask = 0x00000008, .name = "opaque" },
        .{ .mask = 0x00008000, .name = "hidden" },
        .{ .mask = 0x00010000, .name = "arch" },
        .{ .mask = 0x00020000, .name = "schg" },
        .{ .mask = 0x00040000, .name = "sappnd" },
    };
    var len: u32 = 0;
    for (table) |entry| {
        if (flags & entry.mask == 0) continue;
        if (len > 0) {
            if (len >= scratch.len) break;
            scratch[len] = ',';
            len += 1;
        }
        if (len + entry.name.len > scratch.len) break;
        @memcpy(scratch[len..][0..entry.name.len], entry.name);
        len += @intCast(entry.name.len);
    }
    std.debug.assert(len <= scratch.len);
    if (len == 0) return "-";
    return scratch[0..len];
}

/// %R: the absolute pathname, falling back to the given path when realpath(3)
/// cannot resolve it.
fn bsdRealPathText(path: []const u8, scratch: []u8) []const u8 {
    std.debug.assert(scratch.len >= std.fs.max_path_bytes);
    if (path.len > std.fs.max_path_bytes) return path;
    var path_zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_zbuf[0..path.len], path);
    path_zbuf[path.len] = 0;
    std.debug.assert(path_zbuf[path.len] == 0);
    const path_z: [*:0]const u8 = @ptrCast(&path_zbuf);
    const resolved = c.realpath(path_z, scratch.ptr) orelse return path;
    return std.mem.sliceTo(resolved, 0);
}

/// %T: the ls -F suffix character, or the long name for the H sub-field
/// (stat-macos.txt:149-156, 200-201).
fn bsdFileTypeText(sub: BsdSub, mode: u32) []const u8 {
    if (sub == .high) return bsdFileTypeLong(mode);
    return bsdFileTypeSuffix(mode);
}

/// The descriptive file type name %HT reports.
fn bsdFileTypeLong(mode: u32) []const u8 {
    return switch (mode & c.S.IFMT) {
        c.S.IFIFO => "Fifo File",
        c.S.IFCHR => "Character Device",
        c.S.IFDIR => "Directory",
        c.S.IFBLK => "Block Device",
        c.S.IFREG => "Regular File",
        c.S.IFLNK => "Symbolic Link",
        c.S.IFSOCK => "Socket",
        else => "???",
    };
}

/// The ls -F style suffix character %T reports.
fn bsdFileTypeSuffix(mode: u32) []const u8 {
    return switch (mode & c.S.IFMT) {
        c.S.IFIFO => "|",
        c.S.IFDIR => "/",
        c.S.IFLNK => "@",
        c.S.IFSOCK => "=",
        c.S.IFREG => if (mode & 0o111 != 0) "*" else "",
        else => "",
    };
}

/// %Y: the target of a symbolic link. Requesting the string form explicitly
/// prepends " -> " (stat-macos.txt:138-140).
fn bsdSymlinkValue(d: BsdDirective, ctx: BsdContext, scratch: []u8) BsdValue {
    std.debug.assert(d.datum == 'Y');
    std.debug.assert(scratch.len >= 128);
    if (ctx.stat_buf.mode & c.S.IFMT != c.S.IFLNK) return .{ .text = "" };

    const arrow_len: u32 = 4;
    scratch[0] = ' ';
    scratch[1] = '-';
    scratch[2] = '>';
    scratch[3] = ' ';
    const target = readLinkTarget(ctx.path, scratch[arrow_len..]) orelse
        return .{ .text = "" };
    const total = arrow_len + target.len;
    std.debug.assert(total <= scratch.len);

    const explicit_string = if (d.fmt) |form| form == .string else false;
    if (explicit_string) return .{ .text = scratch[0..total] };
    return .{ .text = scratch[arrow_len..total] };
}

/// %Z: "major,minor" for character and block devices, the size otherwise
/// (stat-macos.txt:205-207).
fn bsdSizeRdevValue(d: BsdDirective, st: StatResult, scratch: []u8) BsdValue {
    std.debug.assert(d.datum == 'Z');
    std.debug.assert(scratch.len >= 64);
    const kind = st.mode & c.S.IFMT;
    if (kind == c.S.IFCHR) return bsdRdevPairValue(st.rdev, scratch);
    if (kind == c.S.IFBLK) return bsdRdevPairValue(st.rdev, scratch);
    return .{ .number = st.size };
}

/// The "major,minor" pair %Z reports for a device node.
fn bsdRdevPairValue(rdev: u64, scratch: []u8) BsdValue {
    std.debug.assert(scratch.len >= 64);
    const major = devMajor(rdev);
    const minor = devMinor(rdev);
    const args = .{ major, minor };
    const text = std.fmt.bufPrint(scratch, "{d},{d}", args) catch return .{ .text = "?" };
    return .{ .text = text };
}

/// Emit string output: the precision truncates, the width pads
/// (stat-macos.txt:93-111).
fn writeBsdText(d: BsdDirective, text: []const u8, writer: anytype) !void {
    std.debug.assert(d.datum != 0);
    std.debug.assert(d.width <= bsd_field_max);
    var body = text;
    if (d.precision) |limit| {
        if (body.len > limit) body = body[0..limit];
    }
    std.debug.assert(body.len <= text.len);
    try writePaddedField(writer, "", body, d.width, d.left, ' ');
}

/// The prefix and digits of a rendered number, kept apart so zero fill can go
/// between them the way printf(3) places it.
const BsdNumberText = struct { prefix: []const u8, body: []const u8 };

/// Emit numeric output in the directive's base.
fn writeBsdNumber(d: BsdDirective, value: i64, writer: anytype) !void {
    std.debug.assert(d.datum != 0);
    std.debug.assert(d.width <= bsd_field_max);
    var body_buf: [160]u8 = undefined;
    var prefix_buf: [2]u8 = undefined;
    const rendered = renderBsdNumber(d, value, &body_buf, &prefix_buf);
    const fill = bsdFillChar(d);
    try writePaddedField(writer, rendered.prefix, rendered.body, d.width, d.left, fill);
}

/// The left-padding character: '0' only when the 0 flag is set and the field
/// is not left aligned, since left alignment pads on the right instead
/// (stat-macos.txt:93-97).
fn bsdFillChar(d: BsdDirective) u8 {
    if (!d.zero) return ' ';
    if (d.left) return ' ';
    return '0';
}

/// Render `value` in the directive's base, applying the minimum-digit
/// precision, the alternate form and the sign flags.
fn renderBsdNumber(
    d: BsdDirective,
    value: i64,
    body_buf: *[160]u8,
    prefix_buf: *[2]u8,
) BsdNumberText {
    const form = effectiveBsdFmt(d);
    std.debug.assert(form != .string);
    std.debug.assert(form != .float);

    // Signed output carries its own sign; the other forms reinterpret the
    // 64-bit pattern, exactly as the C conversions %o, %u and %x do.
    const negative = if (form == .signed) value < 0 else false;
    const magnitude: u64 = bsdMagnitude(form, value);

    // A u64 needs at most 22 octal digits, so the buffer can never overflow.
    var digits_buf: [96]u8 = undefined;
    const digits = switch (form) {
        .octal => std.fmt.bufPrint(&digits_buf, "{o}", .{magnitude}) catch unreachable,
        .hex => std.fmt.bufPrint(&digits_buf, "{x}", .{magnitude}) catch unreachable,
        else => std.fmt.bufPrint(&digits_buf, "{d}", .{magnitude}) catch unreachable,
    };
    std.debug.assert(digits.len > 0);

    const min_digits = bsdMinDigits(d, form, digits);
    const body = bsdPadDigits(digits, min_digits, body_buf);
    const prefix = bsdNumberPrefix(d, form, negative, magnitude, prefix_buf);
    return .{ .prefix = prefix, .body = body };
}

/// The magnitude to render: the absolute value for signed output, the raw bit
/// pattern for the octal, unsigned and hexadecimal forms.
fn bsdMagnitude(form: BsdFmt, value: i64) u64 {
    std.debug.assert(form != .string);
    std.debug.assert(form != .float);
    if (form != .signed) return @bitCast(value);
    if (value >= 0) return @intCast(value);
    // Negating through -(value + 1) + 1 keeps the most negative i64 in range.
    return @as(u64, @intCast(-(value + 1))) + 1;
}

/// The minimum digit count: the precision, raised when the alternate octal
/// form has to force a leading zero (stat-macos.txt:85-87).
fn bsdMinDigits(d: BsdDirective, form: BsdFmt, digits: []const u8) u32 {
    std.debug.assert(digits.len > 0);
    std.debug.assert(digits.len <= 96);
    var min_digits: u32 = 1;
    if (d.precision) |precision| min_digits = @max(precision, 1);
    if (!d.alt) return min_digits;
    if (form != .octal) return min_digits;
    if (digits[0] == '0') return min_digits;
    const forced: u32 = @intCast(digits.len + 1);
    return @max(min_digits, forced);
}

/// Left-pad `digits` with zeroes to `min_digits`, into `body_buf`.
fn bsdPadDigits(digits: []const u8, min_digits: u32, body_buf: *[160]u8) []const u8 {
    std.debug.assert(digits.len > 0);
    std.debug.assert(min_digits <= bsd_field_max);
    const digits_len: u32 = @intCast(digits.len);
    const zeros: u32 = if (min_digits > digits_len) min_digits - digits_len else 0;

    var written: u32 = 0;
    while (written < zeros) : (written += 1) {
        if (written >= body_buf.len) break;
        body_buf[written] = '0';
    }
    std.debug.assert(written <= body_buf.len);

    const room: u32 = @intCast(body_buf.len - written);
    const copy_len = @min(digits_len, room);
    @memcpy(body_buf[written..][0..copy_len], digits[0..copy_len]);
    const total = written + copy_len;
    std.debug.assert(total <= body_buf.len);
    return body_buf[0..total];
}

/// The sign or alternate-form prefix that precedes the digits.
fn bsdNumberPrefix(
    d: BsdDirective,
    form: BsdFmt,
    negative: bool,
    magnitude: u64,
    prefix_buf: *[2]u8,
) []const u8 {
    std.debug.assert(form != .string);
    std.debug.assert(form != .float);
    if (negative) {
        prefix_buf[0] = '-';
        return prefix_buf[0..1];
    }
    if (form == .signed) {
        // stat-macos.txt:99-100: '+' overrides a reserved space column.
        if (d.plus) {
            prefix_buf[0] = '+';
            return prefix_buf[0..1];
        }
        if (d.space) {
            prefix_buf[0] = ' ';
            return prefix_buf[0..1];
        }
        return prefix_buf[0..0];
    }
    if (d.alt and form == .hex and magnitude != 0) {
        prefix_buf[0] = '0';
        prefix_buf[1] = 'x';
        return prefix_buf[0..2];
    }
    return prefix_buf[0..0];
}

/// %a, %m, %c and %B. The string form runs the -t strftime(3) format, the
/// float form prints seconds with a fraction, and every other form prints the
/// epoch second count.
fn writeBsdTimestamp(
    d: BsdDirective,
    ts: BsdTimestamp,
    timefmt: []const u8,
    writer: anytype,
) !void {
    std.debug.assert(d.datum != 0);
    std.debug.assert(d.width <= bsd_field_max);
    const form = effectiveBsdFmt(d);
    if (form == .string) {
        var text_buf: [512]u8 = undefined;
        const text = bsdStrftime(ts.sec, timefmt, &text_buf);
        try writeBsdText(d, text, writer);
        return;
    }
    if (form == .float) {
        var float_buf: [64]u8 = undefined;
        const text = bsdFloatSeconds(d, ts, &float_buf);
        try writePaddedField(writer, "", text, d.width, d.left, bsdFillChar(d));
        return;
    }
    try writeBsdNumber(d, ts.sec, writer);
}

/// Render `sec` in local time with strftime(3), as -t asks for.
fn bsdStrftime(sec: i64, fmt: []const u8, buf: *[512]u8) []const u8 {
    std.debug.assert(buf.len >= 64);
    if (fmt.len == 0) return "";
    if (fmt.len >= 256) return "";

    var fmt_zbuf: [256]u8 = undefined;
    @memcpy(fmt_zbuf[0..fmt.len], fmt);
    fmt_zbuf[fmt.len] = 0;
    std.debug.assert(fmt_zbuf[fmt.len] == 0);
    const fmt_z: [*:0]const u8 = @ptrCast(&fmt_zbuf);

    const time_val: c.time_t = @intCast(sec);
    var tm: time.c_tm = undefined;
    if (time.localtime_r(&time_val, &tm) == null) return "";
    const len = time.strftime(buf, buf.len, fmt_z, &tm);
    return buf[0..len];
}

/// The F form of a time datum: seconds with a fractional part whose digit
/// count comes from the precision (printf(3) defaults to six).
fn bsdFloatSeconds(d: BsdDirective, ts: BsdTimestamp, buf: *[64]u8) []const u8 {
    std.debug.assert(buf.len >= 32);
    const digits: u32 = @min(d.precision orelse 6, 9);
    const raw_nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    // Clamping keeps the fraction exactly nine digits even if the kernel
    // reports a nanosecond field outside its documented range.
    const nsec: u64 = @min(raw_nsec, 999_999_999);
    // A seconds count plus a nine-digit fraction never exceeds 32 bytes.
    if (digits == 0) return std.fmt.bufPrint(buf, "{d}", .{ts.sec}) catch unreachable;

    var frac_buf: [16]u8 = undefined;
    const frac = std.fmt.bufPrint(&frac_buf, "{d:0>9}", .{nsec}) catch unreachable;
    std.debug.assert(frac.len == 9);
    const args = .{ ts.sec, frac[0..digits] };
    return std.fmt.bufPrint(buf, "{d}.{s}", args) catch unreachable;
}

/// Write `prefix` then `body`, padded to `width` with `fill`. This is the one
/// place field width and alignment are applied, so every datum obeys them.
fn writePaddedField(
    writer: anytype,
    prefix: []const u8,
    body: []const u8,
    width: u32,
    left: bool,
    fill: u8,
) !void {
    std.debug.assert(prefix.len <= 2);
    std.debug.assert(width <= bsd_field_max);
    const used = prefix.len + body.len;
    const pad: u32 = if (width > used) width - @as(u32, @intCast(used)) else 0;
    std.debug.assert(pad <= bsd_field_max);

    if (left) {
        try writer.writeAll(prefix);
        try writer.writeAll(body);
        try writeBsdFill(writer, ' ', pad);
        return;
    }
    if (fill == '0') {
        try writer.writeAll(prefix);
        try writeBsdFill(writer, '0', pad);
        try writer.writeAll(body);
        return;
    }
    try writeBsdFill(writer, ' ', pad);
    try writer.writeAll(prefix);
    try writer.writeAll(body);
}

/// Emit `count` copies of the fill character.
fn writeBsdFill(writer: anytype, ch: u8, count: u32) !void {
    std.debug.assert(count <= bsd_field_max);
    std.debug.assert(ch != 0);
    var written: u32 = 0;
    while (written < count) : (written += 1) {
        try writer.writeByte(ch);
    }
}

// ============================================================================
// Terse output format
// ============================================================================

fn printTerseFormat(stat_buf: StatResult, path: []const u8, writer: anytype) !void {
    const mode: u32 = stat_buf.mode;
    const dev: u64 = stat_buf.dev;

    // Device major/minor from rdev
    const rdev_major: u64 = blk: {
        if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
            const rdev: u32 = @intCast(stat_buf.rdev);
            break :blk (rdev >> 24) & 0xff;
        } else {
            const rdev: u64 = @intCast(stat_buf.rdev);
            break :blk (rdev >> 8) & 0xfff;
        }
    };
    const rdev_minor: u64 = blk: {
        if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
            const rdev: u32 = @intCast(stat_buf.rdev);
            break :blk rdev & 0xffffff;
        } else {
            const rdev: u64 = @intCast(stat_buf.rdev);
            break :blk rdev & 0xff;
        }
    };

    const btime_sec = getTimespecSec(stat_buf, .btime);

    // GNU terse: 16 fields
    // name size blocks mode uid gid dev inode nlinks major minor atime mtime ctime btime blksize
    try writer.print("{s} {d} {d} {x} {d} {d} {x} {d} {d} {x} {x} {d} {d} {d} {d} {d}\n", .{
        path,
        stat_buf.size,
        stat_buf.blocks,
        mode,
        stat_buf.uid,
        stat_buf.gid,
        dev,
        stat_buf.ino,
        stat_buf.nlink,
        rdev_major,
        rdev_minor,
        getTimespecSec(stat_buf, .atime),
        getTimespecSec(stat_buf, .mtime),
        getTimespecSec(stat_buf, .ctime),
        btime_sec,
        stat_buf.blksize,
    });
}

// ============================================================================
// File system stat (statfs) output
// ============================================================================

/// Look up the filesystem type name from the magic number (Linux only).
fn fsTypeName(f_type: c_long) []const u8 {
    return switch (@as(u64, @bitCast(f_type))) {
        0xEF53 => "ext2/ext3",
        0x9123683E => "btrfs",
        0x58465342 => "xfs",
        0x3153464A => "jfs",
        0x52654973 => "reiserfs",
        0x01021994 => "tmpfs",
        0x28cd3d45 => "cramfs",
        0x73717368 => "squashfs",
        0x9fa0 => "proc",
        0x62656572 => "sysfs",
        0x64626720 => "debugfs",
        0xcafe4a11 => "bpf_fs",
        0x63677270 => "cgroup2",
        0x27e0eb => "cgroup",
        0x1cd1 => "devpts",
        0x2011bab0 => "autofs",
        0x6969 => "nfs",
        0xFF534D42 => "cifs",
        0x137F => "minix",
        0x4d44 => "msdos",
        0x4006 => "fat",
        0x65735546 => "fuse",
        0x794c7630 => "overlayfs",
        0xadf5 => "adfs",
        0x00011954 => "ufs",
        0x9fa2 => "usbdevice",
        0x62646576 => "devtmpfs",
        0x50495045 => "pipefs",
        0x6e736673 => "nsfs",
        else => "unknown",
    };
}

/// Read mount point and device for a given path from /proc/self/mountinfo (Linux).
/// Uses longest-prefix matching on mount points.
fn lookupMountInfo(
    path: []const u8,
    mount_buf: *[1024]u8,
    dev_buf: *[1024]u8,
) struct { mount: []const u8, dev: []const u8 } {
    // Use raw POSIX syscalls to avoid needing std.Io here.
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        "/proc/self/mountinfo",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    ) catch
        return .{ .mount = "?", .dev = "?" };
    defer _ = std.c.close(fd);

    var abs_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var path_z_buf2: [std.fs.max_path_bytes + 1]u8 = undefined;
    const abs_path = lookupMountInfo_resolvePath(path, &abs_buf, &path_z_buf2);

    var content_buf: [32768]u8 = undefined;
    const content = lookupMountInfo_readContent(fd, &content_buf);

    var best_mount: []const u8 = "/";
    var best_dev: []const u8 = "?";
    var best_len: usize = 0; // tiger:allow:usize-arch compared against slice .len

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        // mountinfo format: id parent major:minor root mount_point ...
        var fields: [10][]const u8 = undefined;
        const count = lookupMountInfo_splitFields(line, &fields);
        if (count < 5) continue;

        const mount_point = fields[4];
        // Match: mount_point is a prefix of abs_path (with boundary check)
        const is_match = if (std.mem.eql(u8, mount_point, "/"))
            true
        else if (std.mem.startsWith(u8, abs_path, mount_point))
            (abs_path.len == mount_point.len or abs_path[mount_point.len] == '/')
        else
            false;

        if (is_match and mount_point.len > best_len) {
            best_len = mount_point.len;
            if (mount_point.len <= mount_buf.len) {
                @memcpy(mount_buf[0..mount_point.len], mount_point);
                best_mount = mount_buf[0..mount_point.len];
            }
            best_dev = lookupMountInfo_copyDevice(line, dev_buf, best_dev);
        }
    }
    // best_len is only set from a matched prefix length, never longer than the
    // (non-empty) path it is a prefix of; best_mount is "/" or a slice copied
    // under the mount_buf.len guard, so it never exceeds the buffer.
    std.debug.assert(best_len <= abs_path.len);
    std.debug.assert(best_mount.len <= mount_buf.len);
    return .{ .mount = best_mount, .dev = best_dev };
}

/// Resolve `path` to an absolute path for prefix matching, falling back to
/// the original path when realpath fails or the path is too long.
fn lookupMountInfo_resolvePath(
    path: []const u8,
    abs_buf: *[std.fs.max_path_bytes + 1]u8,
    path_z_buf: *[std.fs.max_path_bytes + 1]u8,
) []const u8 {
    std.debug.assert(@intFromPtr(abs_buf) != 0);
    std.debug.assert(@intFromPtr(path_z_buf) != 0);
    if (path.len <= std.fs.max_path_bytes) {
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_z_buf);
        if (c.realpath(path_z, abs_buf)) |resolved| {
            return std.mem.sliceTo(resolved, 0);
        }
    }
    return path;
}

/// Drain `fd` into `content_buf` with a bounded read loop, returning the
/// filled slice. Stops at EOF, a read error, or a full buffer.
fn lookupMountInfo_readContent(fd: std.posix.fd_t, content_buf: *[32768]u8) []const u8 {
    var total: usize = 0; // tiger:allow:usize-arch slice indexing requires usize
    while (total < content_buf.len) {
        const n = std.posix.read(fd, content_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    std.debug.assert(total <= content_buf.len);
    const result = content_buf[0..total];
    std.debug.assert(result.len == total);
    return result;
}

/// Split a mountinfo line on spaces into at most 10 fields, returning the
/// field count.
fn lookupMountInfo_splitFields(line: []const u8, fields: *[10][]const u8) u32 {
    std.debug.assert(@intFromPtr(fields) != 0);
    var count: u32 = 0;
    var iter = std.mem.splitScalar(u8, line, ' ');
    while (iter.next()) |field| {
        if (count < 10) {
            fields[count] = field;
            count += 1;
        }
    }
    std.debug.assert(count <= 10);
    return count;
}

/// Extract the device name (the field after " - " then fstype) from a
/// mountinfo line into `dev_buf`, returning it; otherwise return `prior`.
fn lookupMountInfo_copyDevice(line: []const u8, dev_buf: *[1024]u8, prior: []const u8) []const u8 {
    std.debug.assert(@intFromPtr(dev_buf) != 0);
    std.debug.assert(prior.len <= dev_buf.len);
    // Find device name after the " - " separator.
    if (std.mem.find(u8, line, " - ")) |sep_pos| {
        const after_sep = line[sep_pos + 3 ..];
        // Format: fstype device options
        var dev_iter = std.mem.splitScalar(u8, after_sep, ' ');
        _ = dev_iter.next(); // fstype
        if (dev_iter.next()) |device| {
            if (device.len <= dev_buf.len) {
                @memcpy(dev_buf[0..device.len], device);
                std.debug.assert(device.len <= dev_buf.len);
                return dev_buf[0..device.len];
            }
        }
    }
    return prior;
}

fn printFileSystemInfo(
    path: []const u8,
    writer: anytype,
) !void {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    // Past the length guard, the copy and sentinel write stay in bounds.
    std.debug.assert(path.len <= std.fs.max_path_bytes);
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    std.debug.assert(path_buf[path.len] == 0);
    const c_path = path_buf[0..path.len :0];

    var fs_buf: StatFs = undefined;
    if (statfs(c_path, &fs_buf) != 0) {
        return error.StatFsFailed;
    }

    try writer.print("  File: \"{s}\"\n", .{path});

    if (builtin.os.tag == .linux) {
        const namelen: u64 = @intCast(fs_buf.f_namelen);
        const fstype = fsTypeName(fs_buf.f_type);
        try writer.print("    ID: {x}{x} Namelen: {d}     Type: {s}\n", .{
            @as(u32, @bitCast(fs_buf.f_fsid.val[0])),
            @as(u32, @bitCast(fs_buf.f_fsid.val[1])),
            namelen,
            fstype,
        });
        const bsize: u64 = @intCast(fs_buf.f_bsize);
        const frsize: u64 = @intCast(fs_buf.f_frsize);
        try writer.print("Block size: {d}       Fundamental block size: {d}\n", .{
            bsize,
            frsize,
        });
    } else {
        const fstype = std.mem.sliceTo(&fs_buf.f_fstypename, 0);
        try writer.print("    ID: {x}{x} Namelen: {d}     Type: {s}\n", .{
            @as(u32, @bitCast(fs_buf.f_fsid.val[0])),
            @as(u32, @bitCast(fs_buf.f_fsid.val[1])),
            @as(u32, 255), // macOS doesn't expose namelen in statfs
            fstype,
        });
        try writer.print("Block size: {d}       Fundamental block size: {d}\n", .{
            fs_buf.f_bsize,
            fs_buf.f_bsize,
        });
    }

    try writer.print("Blocks: Total: {d: <11}Free: {d: <11}Available: {d}\n", .{
        fs_buf.f_blocks,
        fs_buf.f_bfree,
        fs_buf.f_bavail,
    });
    try writer.print("Inodes: Total: {d: <11}Free: {d}\n", .{
        fs_buf.f_files,
        fs_buf.f_ffree,
    });

    if (builtin.os.tag == .linux) {
        var mount_buf: [1024]u8 = undefined;
        var dev_buf: [1024]u8 = undefined;
        const info = lookupMountInfo(path, &mount_buf, &dev_buf);
        try writer.print(" Mount: {s}\n", .{info.mount});
        try writer.print("  From: {s}\n", .{info.dev});
    } else {
        const mntonname = std.mem.sliceTo(&fs_buf.f_mntonname, 0);
        const mntfromname = std.mem.sliceTo(&fs_buf.f_mntfromname, 0);
        try writer.print(" Mount: {s}\n", .{mntonname});
        try writer.print("  From: {s}\n", .{mntfromname});
    }
}

// ============================================================================
// Main utility function
// ============================================================================

pub fn runStat(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = io;
    const parsed = parseArgs(allocator, args);
    const opts = parsed.opts;
    defer allocator.free(opts.positionals);

    if (parsed.err) |err_msg| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "{s}\nTry 'stat --help' for more information.",
            .{err_msg},
        );
        return @intFromEnum(common.ExitCode.misuse);
    }

    if (opts.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // stat-macos.txt:14-15: with no operand, report on standard input's
    // descriptor rather than failing with a usage error.
    if (opts.positionals.len == 0) {
        const stdin_failed = try processStandardInput(
            allocator,
            &opts,
            stdout_writer,
            stderr_writer,
        );
        return if (stdin_failed)
            @intFromEnum(common.ExitCode.general_error)
        else
            @intFromEnum(common.ExitCode.success);
    }

    var has_error = false;
    var file_number: u32 = 0;

    // The empty-positionals case returned above, so the loop has work to do.
    std.debug.assert(opts.positionals.len > 0);
    for (opts.positionals) |path| {
        file_number += 1;
        const failed = try processOnePath(
            allocator,
            &opts,
            path,
            file_number,
            stdout_writer,
            stderr_writer,
        );
        if (failed) {
            has_error = true;
        }
    }
    std.debug.assert(file_number >= 1);

    return if (has_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
}

/// Report on standard input's descriptor, which is what stat does when no
/// file operand is given (stat-macos.txt:14-15). Returns true on failure.
fn processStandardInput(
    allocator: Allocator,
    opts: *const StatOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !bool {
    const stat_buf = doStatFd(0) catch {
        if (!opts.quiet) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot stat standard input",
                .{},
            );
        }
        return true;
    };
    try emitStatOutput(allocator, opts, stat_buf, "(stdin)", 1, stdout_writer);
    return false;
}

/// Emit stat output for a single path. Returns true when the path could
/// not be statted (or statfs'd), so the caller can flag overall failure.
fn processOnePath(
    allocator: Allocator,
    opts: *const StatOptions,
    path: []const u8,
    file_number: u32,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !bool {
    std.debug.assert(file_number >= 1);
    const gnu_format_given = opts.format != null or opts.printf_fmt != null;
    if (opts.mode == .default and opts.file_system and !gnu_format_given) {
        printFileSystemInfo(path, stdout_writer) catch {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot statfs '{s}': No such file or directory",
                .{path},
            );
            return true;
        };
        return false;
    }

    const stat_buf = statPath(opts, path) catch |err| {
        // stat-macos.txt:56-58: -q silences the message, but the exit status
        // still reports the failure.
        if (!opts.quiet) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot stat '{s}': {s}",
                .{ path, statErrorMessage(err) },
            );
        }
        return true;
    };

    try emitStatOutput(allocator, opts, stat_buf, path, file_number, stdout_writer);
    return false;
}

/// stat(2) or lstat(2) per -L. When -L is given and the target does not
/// exist, fall back on lstat(2) and report the link (stat-macos.txt:41-45).
fn statPath(opts: *const StatOptions, path: []const u8) !StatResult {
    if (doStat(path, opts.dereference)) |result| {
        std.debug.assert(result.mode != 0);
        return result;
    } else |err| {
        if (!opts.dereference) return err;
        const link = doStat(path, false) catch return err;
        std.debug.assert(link.mode != 0);
        return link;
    }
}

/// The human-readable reason a stat(2) call failed.
fn statErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => "Cannot access",
    };
}

/// The format string the selected output mode uses.
fn selectedFormat(opts: *const StatOptions) []const u8 {
    return switch (opts.mode) {
        .bsd_format => opts.bsd_format orelse bsd_default_format,
        .ls => if (opts.type_suffix) bsd_ls_suffix_format else bsd_ls_format,
        .raw => bsd_raw_format,
        .shell => bsd_shell_format,
        .verbose => bsd_verbose_format,
        .default => bsd_default_format,
    };
}

/// Emit one file's output in whichever mode the flags selected. The BSD
/// mode flags win; otherwise the surviving GNU options are honoured, and
/// with none of them the BSD default format is used.
fn emitStatOutput(
    allocator: Allocator,
    opts: *const StatOptions,
    stat_buf: StatResult,
    path: []const u8,
    file_number: u32,
    writer: *std.Io.Writer,
) !void {
    std.debug.assert(file_number >= 1);
    std.debug.assert(stat_buf.mode != 0);
    if (opts.mode == .default) {
        if (opts.printf_fmt) |format| {
            // GNU --printf never appends a newline of its own.
            const follow = opts.dereference;
            try processFormatString(allocator, format, stat_buf, path, follow, true, writer);
            return;
        }
        if (opts.format) |format| {
            const follow = opts.dereference;
            try processFormatString(allocator, format, stat_buf, path, follow, false, writer);
            try emitTrailingNewline(opts, writer);
            return;
        }
        if (opts.terse) {
            try printTerseFormat(stat_buf, path, writer);
            return;
        }
    }

    const ctx = BsdContext{
        .allocator = allocator,
        .stat_buf = stat_buf,
        .path = path,
        .timefmt = opts.timefmt orelse bsd_default_timefmt,
    };
    try processBsdFormat(selectedFormat(opts), ctx, file_number, writer);
    try emitTrailingNewline(opts, writer);
}

/// Terminate one piece of output, unless -n asked for no newline
/// (stat-macos.txt:53-54).
fn emitTrailingNewline(opts: *const StatOptions, writer: *std.Io.Writer) !void {
    std.debug.assert(@intFromPtr(opts) != 0);
    if (opts.no_newline) return;
    try writer.writeByte('\n');
}

// ============================================================================
// Entry point
// ============================================================================

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runStat);
}

// ============================================================================
// Help and version
// ============================================================================

fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]
        \\Display file status. With no file operand, report on standard input.
        \\
        \\  -F                    append an ls-style type suffix; implies -l
        \\  -L                    use stat(2), falling back to lstat(2) for a
        \\                          broken link
        \\  -f FORMAT             display information using the BSD FORMAT
        \\  -l                    display output in ls -lT format
        \\  -n                    do not force a newline after each piece of output
        \\  -q                    suppress stat(2) and lstat(2) failure messages
        \\  -r                    display raw, numerical information
        \\  -s                    display information in shell output format
        \\  -t TIMEFMT            display timestamps using the strftime(3) TIMEFMT
        \\  -x                    display information in a more verbose way
        \\  -h, --help            display this help and exit
        \\  -V, --version         output version information and exit
        \\
        \\GNU compatibility options, which use the GNU directive language:
        \\      --dereference     same as -L
        \\      --file-system     display file system status instead of file status
        \\  -c, --format=FORMAT   use the specified GNU FORMAT instead of the
        \\                          default; output a newline after each use
        \\      --printf=FORMAT   like --format, but interpret backslash escapes,
        \\                          and do not output a mandatory trailing newline
        \\      --terse           print the information in terse form
        \\
        \\The BSD -f format is %[flags][size][.prec][fmt][sub]datum, where flags
        \\are #+-0 and space, fmt is one of DOUXFS, and sub is one of HML:
        \\  %d %i %p %l %u %g %r  device, inode, mode, links, uid, gid, rdev
        \\  %a %m %c %B           access, modify, change and birth times
        \\  %z %b %k %f %v        size, blocks, block size, flags, generation
        \\  %N %R %T %Y %Z        name, real path, file type, link target, size
        \\  %n %t %% %@           newline, tab, percent, current file number
        \\
        \\The valid GNU format sequences for files (used by -c and --printf):
        \\  %a   access rights in octal
        \\  %A   access rights in human readable form
        \\  %b   number of blocks allocated (see %B)
        \\  %B   the size in bytes of each block reported by %b
        \\  %d   device number in decimal
        \\  %D   device number in hex
        \\  %f   raw mode in hex
        \\  %F   file type
        \\  %g   group ID of owner
        \\  %G   group name of owner
        \\  %h   number of hard links
        \\  %i   inode number
        \\  %m   mount point
        \\  %n   file name
        \\  %N   quoted file name with dereference if symbolic link
        \\  %o   optimal I/O transfer size hint
        \\  %s   total size, in bytes
        \\  %t   major device type in hex, for character/block device special files
        \\  %T   minor device type in hex, for character/block device special files
        \\  %u   user ID of owner
        \\  %U   user name of owner
        \\  %w   time of file birth, human-readable; - if unknown
        \\  %W   time of file birth, seconds since Epoch; 0 if unknown
        \\  %x   time of last access, human-readable
        \\  %X   time of last access, seconds since Epoch
        \\  %y   time of last data modification, human-readable
        \\  %Y   time of last data modification, seconds since Epoch
        \\  %z   time of last status change, human-readable
        \\  %Z   time of last status change, seconds since Epoch
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("stat ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "stat --help shows usage" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: stat") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--format") != null);
}

test "stat -h shows usage" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: stat") != null);
}

test "stat --version shows version" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "stat") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.version) != null);
}

test "stat -V shows version" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "stat") != null);
}

test "stat unknown flag returns misuse" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") != null,
    );
}

test "stat nonexistent file returns error" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent/file/path"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "cannot stat") != null);
}

test "stat -c format: file name" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%n", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Output should be the path + newline
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: size" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
}

test "stat -c format: file type" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "subdir", std.Io.File.Permissions.fromMode(0o755));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "subdir", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%F", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("directory\n", stdout_aw.writer.buffered());
}

test "stat -c format: inode number" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%i", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Should be a valid number followed by newline
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    const inode = try std.fmt.parseInt(u64, trimmed, 10);
    try testing.expect(inode > 0);
}

test "stat -c format: permissions octal" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(
        testing.io,
        "test.txt",
        .{ .permissions = @enumFromInt(0o644) },
    );
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%a", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // Must be 3-4 characters (e.g. "644", "0644")
    try testing.expect(trimmed.len >= 3);
    try testing.expect(trimmed.len <= 4);
    // Every character must be a valid octal digit (0-7)
    for (trimmed) |ch| {
        try testing.expect(ch >= '0' and ch <= '7');
    }
    // Verify the octal value matches actual file permissions
    const stat_info = try tmp_dir.dir.statFile(testing.io, "test.txt", .{});
    const actual_mode: u32 = @intCast(stat_info.permissions.toMode() & 0o7777);
    const reported_mode = try std.fmt.parseInt(u32, trimmed, 8);
    try testing.expectEqual(actual_mode, reported_mode);
}

test "stat -c format: permissions human readable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(
        testing.io,
        "test.txt",
        .{ .permissions = @enumFromInt(0o644) },
    );
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%A", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Should start with '-' for regular file
    try testing.expect(stdout_aw.writer.buffered().len >= 10);
    try testing.expectEqual(@as(u8, '-'), stdout_aw.writer.buffered()[0]);
}

test "stat -c format: user and group IDs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%u %g", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Should be two numbers separated by space
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const uid_str = it.next() orelse return error.TestFailed;
    const gid_str = it.next() orelse return error.TestFailed;
    _ = try std.fmt.parseInt(u32, uid_str, 10);
    _ = try std.fmt.parseInt(u32, gid_str, 10);
}

test "stat -c format: user and group names" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%U", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // Verify the reported username matches the current user
    const current_uid = common.user_group.getCurrentUserId();
    const user_info = try common.user_group.getUserById(current_uid, testing.allocator);
    defer testing.allocator.free(user_info.name);
    try testing.expectEqualStrings(user_info.name, trimmed);
}

test "stat -c format: timestamps" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Test epoch seconds format
    const args = [_][]const u8{ "-c", "%X %Y %Z", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // Output should be three space-separated epoch timestamps
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const atime_str = it.next() orelse return error.TestFailed;
    const mtime_str = it.next() orelse return error.TestFailed;
    const ctime_str = it.next() orelse return error.TestFailed;
    // Each must parse as a valid integer
    const atime_val = try std.fmt.parseInt(i64, atime_str, 10);
    const mtime_val = try std.fmt.parseInt(i64, mtime_str, 10);
    const ctime_val = try std.fmt.parseInt(i64, ctime_str, 10);
    // Timestamps must be recent (after 2020-01-01 = 1577836800)
    try testing.expect(atime_val > 1577836800);
    try testing.expect(mtime_val > 1577836800);
    try testing.expect(ctime_val > 1577836800);
    // Verify mtime matches the actual file's mtime (stat.mtime is in nanoseconds)
    const stat_info = try tmp_dir.dir.statFile(testing.io, "test.txt", .{});
    const actual_mtime: i64 = @intCast(@divTrunc(stat_info.mtime.nanoseconds, std.time.ns_per_s));
    try testing.expectEqual(actual_mtime, mtime_val);
}

test "stat --printf interprets escapes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "data");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--printf=%s\\n", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("4\n", stdout_aw.writer.buffered());
}

test "stat --format=FMT syntax" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--format=%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
}

test "stat empty file shows regular empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "empty.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "empty.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%F", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("regular empty file\n", stdout_aw.writer.buffered());
}

test "stat directory type" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "subdir", std.Io.File.Permissions.fromMode(0o755));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "subdir", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%F", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("directory\n", stdout_aw.writer.buffered());
}

test "stat symlink without dereference" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "target.txt", .{});
    try test_file.writeStreamingAll(testing.io, "content");
    test_file.close(testing.io);

    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path_len = try tmp_dir.dir.realPathFile(testing.io, "link.txt", &path_buf);
    const link_path = path_buf[0..link_path_len];

    // Without -L: should show "symbolic link"
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Note: realpath resolves symlinks, so we need to construct the path manually
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(symlink_path);

    // We need the symlink to exist at a known path. Since realpath follows
    // symlinks, use the directory path + link name
    _ = link_path;

    const args = [_][]const u8{ "-c", "%F", symlink_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("symbolic link\n", stdout_aw.writer.buffered());
}

test "stat symlink with dereference" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "target.txt", .{});
    try test_file.writeStreamingAll(testing.io, "content");
    test_file.close(testing.io);

    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(symlink_path);

    // With -L: should show "regular file" (follows the link)
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-L", "-c", "%F", symlink_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("regular file\n", stdout_aw.writer.buffered());
}

test "stat multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file1 = try tmp_dir.dir.createFile(testing.io, "a.txt", .{});
    try file1.writeStreamingAll(testing.io, "aaa");
    file1.close(testing.io);

    const file2 = try tmp_dir.dir.createFile(testing.io, "b.txt", .{});
    try file2.writeStreamingAll(testing.io, "bbbbb");
    file2.close(testing.io);

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    const path1_len = try tmp_dir.dir.realPathFile(testing.io, "a.txt", &path_buf1);
    const path1 = path_buf1[0..path1_len];
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2_len = try tmp_dir.dir.realPathFile(testing.io, "b.txt", &path_buf2);
    const path2 = path_buf2[0..path2_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%s", path1, path2 };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3\n5\n", stdout_aw.writer.buffered());
}

test "stat -c format: hard links" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%h", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n", stdout_aw.writer.buffered());
}

test "stat -c format: device number" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%d", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    _ = try std.fmt.parseInt(u64, trimmed, 10);
}

test "stat -c format: multiple directives" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "size=%s type=%F", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("size=5 type=regular file\n", stdout_aw.writer.buffered());
}

test "stat partial failure with multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "exists.txt", .{});
    try test_file.writeStreamingAll(testing.io, "data");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "exists.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", "%s", "/nonexistent", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should return error (1) because one file failed
    try testing.expectEqual(@as(u8, 1), result);
    // But should still output the successful file
    try testing.expectEqualStrings("4\n", stdout_aw.writer.buffered());
    // And report the error
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "cannot stat") != null);
}

test "formatPermissions basic" {
    var buf: [10]u8 = undefined;

    // Regular file 0644
    const result = formatPermissions(c.S.IFREG | 0o644, &buf);
    try testing.expectEqualStrings("-rw-r--r--", result);
}

test "formatPermissions directory" {
    var buf: [10]u8 = undefined;

    const result = formatPermissions(c.S.IFDIR | 0o755, &buf);
    try testing.expectEqualStrings("drwxr-xr-x", result);
}

test "formatPermissions symlink" {
    var buf: [10]u8 = undefined;

    const result = formatPermissions(c.S.IFLNK | 0o777, &buf);
    try testing.expectEqualStrings("lrwxrwxrwx", result);
}

test "formatPermissions setuid" {
    var buf: [10]u8 = undefined;

    const result = formatPermissions(c.S.IFREG | 0o4755, &buf);
    try testing.expectEqualStrings("-rwsr-xr-x", result);
}

test "formatPermissions setgid" {
    var buf: [10]u8 = undefined;

    const result = formatPermissions(c.S.IFREG | 0o2755, &buf);
    try testing.expectEqualStrings("-rwxr-sr-x", result);
}

test "formatPermissions sticky" {
    var buf: [10]u8 = undefined;

    const result = formatPermissions(c.S.IFDIR | 0o1755, &buf);
    try testing.expectEqualStrings("drwxr-xr-t", result);
}

test "fileTypeString" {
    try testing.expectEqualStrings("regular file", fileTypeString(c.S.IFREG));
    try testing.expectEqualStrings("directory", fileTypeString(c.S.IFDIR));
    try testing.expectEqualStrings("symbolic link", fileTypeString(c.S.IFLNK));
    try testing.expectEqualStrings("character special file", fileTypeString(c.S.IFCHR));
    try testing.expectEqualStrings("block special file", fileTypeString(c.S.IFBLK));
    try testing.expectEqualStrings("fifo", fileTypeString(c.S.IFIFO));
    try testing.expectEqualStrings("socket", fileTypeString(c.S.IFSOCK));
}

test "fileTypeString unknown mode" {
    // Mode with zeroed type bits does not match any known file type.
    try testing.expectEqualStrings("unknown", fileTypeString(0));
    // Mode with only permission bits (no type bits set) is also unknown.
    try testing.expectEqualStrings("unknown", fileTypeString(0o777));
}

test "stat -- separator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%s", "--", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
}

test "stat nonexistent file error message says No such file" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/no/such/path/at/all"};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    // Error message should contain the filename
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "/no/such/path/at/all") != null,
    );
    // Error message should say "No such file or directory" for ENOENT
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

test "stat permission denied error message is not No such file" {
    // Skip if running as root (root bypasses permission checks)
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory with a file inside
    try tmp_dir.dir.createDir(testing.io, "noaccess", std.Io.File.Permissions.fromMode(0o755));
    const inner_file = try tmp_dir.dir.createFile(testing.io, "noaccess/secret.txt", .{});
    inner_file.close(testing.io);

    // Get the full path to the file inside
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const inner_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/noaccess/secret.txt",
        .{dir_path},
    );
    defer testing.allocator.free(inner_path);

    // Remove execute permission from the directory, making the file inaccessible
    const noaccess_path = try std.fmt.allocPrint(testing.allocator, "{s}/noaccess", .{dir_path});
    defer testing.allocator.free(noaccess_path);
    const noaccess_z = std.posix.toPosixPath(noaccess_path) catch return;
    _ = std.c.chmod(&noaccess_z, 0o000);

    // Ensure we restore permissions for cleanup
    defer _ = std.c.chmod(&noaccess_z, 0o755);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{inner_path};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should fail
    try testing.expectEqual(@as(u8, 1), result);
    // Error message should contain the filename
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "noaccess/secret.txt") != null,
    );
    // BUG: The error message should NOT say "No such file or directory"
    // for an AccessDenied error. It should say "Permission denied".
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Permission denied") != null);
}

// Audit: %b (blocks allocated) has no unit test.
test "stat -c format: blocks allocated %b" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%b", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // %b must be a non-negative integer
    const blocks = try std.fmt.parseInt(i64, trimmed, 10);
    try testing.expect(blocks >= 0);
    // The value should be a reasonable number for a 5-byte file
    // (typically 8 blocks of 512 bytes each)
    try testing.expect(blocks <= 1024);
}

// Audit: %G (group name) has no unit test. Verify it outputs the
// group name matching the file's GID, not a numeric fallback.
test "stat -c format: group name %G" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%G", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // Group name should not be empty
    try testing.expect(trimmed.len > 0);
    // Group name should not be purely numeric (that would mean the
    // name lookup failed and fell back to printing the GID)
    const is_numeric = for (trimmed) |ch| {
        if (ch < '0' or ch > '9') break false;
    } else true;
    try testing.expect(!is_numeric);
}

// Audit: %N (quoted file name with symlink arrow) has no unit test.
// For a regular file, %N should output '<path>' (single-quoted).
// For a symlink, %N should output '<link>' -> '<target>'.
test "stat -c format: %N regular file is quoted" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%N", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try std.fmt.allocPrint(testing.allocator, "'{s}'\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N symlink shows arrow" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "target.txt", .{});
    try test_file.writeStreamingAll(testing.io, "content");
    test_file.close(testing.io);

    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(symlink_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%N", symlink_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // GNU stat -c '%N' on a symlink: 'link' -> 'target'
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}' -> 'target.txt'\n",
        .{symlink_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// Audit: %x, %y, %z (human-readable timestamps) have no unit tests.
// Verify %y output is a human-readable timestamp, not an epoch number.
// GNU format: "YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ"
test "stat -c format: %y mtime human-readable timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%y", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // Must be non-empty
    try testing.expect(trimmed.len > 0);
    // A human-readable timestamp contains dashes and colons
    // An epoch-seconds value would contain only digits
    try testing.expect(std.mem.find(u8, trimmed, "-") != null);
    try testing.expect(std.mem.find(u8, trimmed, ":") != null);
    // Must contain a dot separating seconds from nanoseconds
    try testing.expect(std.mem.find(u8, trimmed, ".") != null);
}

// Audit: --printf no-trailing-newline not tested. The key behavioral
// difference from -c/--format is that --printf does NOT add a trailing
// newline when the format string has none.
test "stat --printf does not add trailing newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // --printf=%s without \n should produce "5" with no trailing newline
    const args = [_][]const u8{ "--printf=%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Must be exactly "5" with no newline
    try testing.expectEqualStrings("5", stdout_aw.writer.buffered());
}

// ============================================================================
// F72: stat becomes the BSD utility
//
//   stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]
//
// Every expectation below is derived from the vendored NetBSD/macOS man page
// docs/specs/stat-macos.txt (OpenBSD matches, see stat-openbsd.txt):
//   :7        SYNOPSIS, including the -f/-l/-r/-s/-x mutual exclusion group
//   :14-15    no file operand means "stat standard input's descriptor"
//   :34-45    -F (implies -l) and -L (lstat fallback on a broken link)
//   :47-72    -f format, -l, -n, -q, -r, -s, -t timefmt, -x
//   :74-211   the FORMAT grammar: %[flags][size][.prec][fmt][sub]datum
//   :218-222  the default format string and a worked example
//   :233-243  the -s "shell output" example
//   :273-274  the %SHp / %SMp / %SLp sub-field example
//   :284-297  the %m vs %Sm vs "%Sm with -t" trio
//
// GNU long options survive because they do not collide with the BSD short
// options: --format=FMT, --printf=FMT, --file-system, --terse, --dereference,
// and -c FORMAT keep GNU directive semantics. The two directive languages are
// selected by the flag that introduced the string.
// ============================================================================

// F72: -f now takes a FORMAT argument and evaluates it with the BSD grammar.
// %z is st_size (stat-macos.txt:182).
test "F72: stat -f '%z' prints the file size" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%z", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
}

// F72: BSD %N is the *unquoted* name of the file (stat-macos.txt:196), unlike
// the GNU %N which single-quotes it. The default-format example at :222 ends
// with a bare "/tmp/bar".
test "F72: stat -f '%N' prints the unquoted file name" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%N", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// F72: %Sp is "the mode of file as in ls -lTd" (stat-macos.txt:132). The file
// is chmod'd explicitly so the expectation does not depend on the umask.
test "F72: stat -f '%Sp' prints an ls-style mode string" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o644) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%Sp", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-rw-r--r--\n", stdout_aw.writer.buffered());
}

// F72: sub-field specifiers H/M/L split the string form of p into the user,
// group, and other bits. Shape taken verbatim from stat-macos.txt:273-274.
test "F72: stat -f sub-fields %SHp %SMp %SLp split the permission bits" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o644) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const sub_fmt = "%Sp -> owner=%SHp group=%SMp other=%SLp";
    const args = [_][]const u8{ "-f", sub_fmt, test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(
        "-rw-r--r-- -> owner=rw- group=r-- other=r--\n",
        stdout_aw.writer.buffered(),
    );
}

// F72: "If the % is immediately followed by one of n, t, %, or @, then a
// newline character, a tab character, a percent character, or the current file
// number is printed" (stat-macos.txt:78-80).
test "F72: stat -f immediate specials %t and %n emit a tab and a newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "a%tb%nc", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // The trailing newline is the one -n suppresses (stat-macos.txt:53-54).
    try testing.expectEqualStrings("a\tb\nc\n", stdout_aw.writer.buffered());
}

// F72: %% prints a literal percent character (stat-macos.txt:78-80).
test "F72: stat -f '%%' emits a literal percent" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "x%%y", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("x%y\n", stdout_aw.writer.buffered());
}

// F72: the "-" flag aligns output to the left of the field and "size" is the
// minimum field width (stat-macos.txt:93-105).
test "F72: stat -f '%-10z|' left-aligns within the field width" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%-10z|", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // "5" padded on the right to a width of 10, then the literal '|'.
    try testing.expectEqualStrings("5         |\n", stdout_aw.writer.buffered());
}

// F72: the same left-alignment applied to string output, which the flag
// description at stat-macos.txt:93-94 names explicitly.
test "F72: stat -f '%-12Sp|' left-aligns string output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o644) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%-12Sp|", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // The 10-character mode string padded on the right to a width of 12.
    try testing.expectEqualStrings("-rw-r--r--  |\n", stdout_aw.writer.buffered());
}

// F72: the "0" flag sets the left-padding fill character (stat-macos.txt:96-97).
test "F72: stat -f '%08z' zero-pads to the field width" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%08z", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("00000005\n", stdout_aw.writer.buffered());
}

// F72: the "#" flag selects the alternate form, so "non-zero octal output will
// have a leading zero" (stat-macos.txt:85-87). st_mode of a 0644 regular file
// is 0100644 octal.
test "F72: stat -f '%#Op' uses the alternate octal form" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o644) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%#Op", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("0100644\n", stdout_aw.writer.buffered());
}

// F72: %#Xf is the flags field in the alternate hexadecimal form; the default
// format uses exactly this directive and the worked example at
// stat-macos.txt:222 shows it printing "0" for a file with no flags set.
test "F72: stat -f '%#Xf' uses the alternate hex form for st_flags" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%#Xf", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    try testing.expect(trimmed.len > 0);
    // Zero prints bare ("0"); a non-zero value carries the alternate prefix.
    const alt_hex_ok = std.mem.eql(u8, trimmed, "0") or
        std.mem.startsWith(u8, trimmed, "0x") or
        std.mem.startsWith(u8, trimmed, "0X");
    try testing.expect(alt_hex_ok);
}

// F72: "Most field specifiers default to U as an output form, with the
// exception of p which defaults to O" (stat-macos.txt:209-211). st_mode of a
// 0644 regular file is 0100644 octal == 33188 decimal.
test "F72: stat -f '%p' defaults to octal and '%Dp' is decimal" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o644) == 0);

    var octal_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer octal_aw.deinit();

    const octal_args = [_][]const u8{ "-f", "%p", test_path };
    const octal_result = try runStat(
        testing.allocator,
        testing.io,
        &octal_args,
        &octal_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), octal_result);
    try testing.expectEqualStrings("100644\n", octal_aw.writer.buffered());

    var decimal_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer decimal_aw.deinit();

    const decimal_args = [_][]const u8{ "-f", "%Dp", test_path };
    const decimal_result = try runStat(
        testing.allocator,
        testing.io,
        &decimal_args,
        &decimal_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), decimal_result);
    try testing.expectEqualStrings("33188\n", decimal_aw.writer.buffered());
}

// F72: "a, m, and c ... default to D" (stat-macos.txt:211), so %m is the raw
// epoch second count, while %Sm is a strftime rendering. The man page shows
// exactly this pair at :284-292.
test "F72: stat -f '%m' is a raw epoch number and '%Sm' is formatted" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const stat_info = try tmp_dir.dir.statFile(testing.io, "test.txt", .{});
    const actual_mtime: i64 = @intCast(@divTrunc(stat_info.mtime.nanoseconds, std.time.ns_per_s));

    var raw_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer raw_aw.deinit();

    const raw_args = [_][]const u8{ "-f", "%m", test_path };
    const raw_result = try runStat(
        testing.allocator,
        testing.io,
        &raw_args,
        &raw_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), raw_result);
    const expected_raw = try std.fmt.allocPrint(testing.allocator, "{d}\n", .{actual_mtime});
    defer testing.allocator.free(expected_raw);
    try testing.expectEqualStrings(expected_raw, raw_aw.writer.buffered());

    var human_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer human_aw.deinit();

    const human_args = [_][]const u8{ "-f", "%Sm", test_path };
    const human_result = try runStat(
        testing.allocator,
        testing.io,
        &human_args,
        &human_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), human_result);
    const human = std.mem.trimEnd(u8, human_aw.writer.buffered(), "\n");
    // The man page example is "Apr 27 11:15:33 2007": a month name plus a
    // colon-separated clock time, never a bare epoch count.
    try testing.expect(human.len > 0);
    try testing.expect(std.mem.find(u8, human, ":") != null);
    var has_alpha = false;
    for (human) |ch| {
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) has_alpha = true;
    }
    try testing.expect(has_alpha);
}

// F72: -t sets the strftime format used by the S form of a/m/c
// (stat-macos.txt:67-69, worked example at :294-297 producing 14 digits).
test "F72: stat -t sets the time format used by '%Sm'" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%Sm", "-t", "%Y%m%d%H%M%S", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    // "20070427111533" — exactly 14 digits, no separators.
    try testing.expectEqual(@as(usize, 14), trimmed.len);
    for (trimmed) |ch| {
        try testing.expect(ch >= '0' and ch <= '9');
    }
}

// F72: with no flags the output is the single BSD line built from
//   "%d %i %Sp %l %Su %Sg %r %z \"%Sa\" \"%Sm\" \"%Sc\" \"%SB\" %k %b %#Xf %N"
// (stat-macos.txt:218-222). The shape is asserted, never the volatile values.
// This also carries forward the old F15 guard: no spurious '+' signs.
test "F72: stat default output is the BSD single line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o644) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{test_path};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();

    // Exactly one line, terminated by the newline the -n flag suppresses.
    var newline_count: usize = 0;
    var quote_count: usize = 0;
    for (output) |ch| {
        if (ch == '\n') newline_count += 1;
        if (ch == '"') quote_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), newline_count);
    try testing.expect(std.mem.endsWith(u8, output, "\n"));

    // %d, the device number, opens the line.
    try testing.expect(output.len > 0);
    try testing.expect(output[0] >= '0' and output[0] <= '9');

    // The four quoted time fields (%Sa, %Sm, %Sc, %SB) contribute 8 quotes.
    try testing.expectEqual(@as(usize, 8), quote_count);

    // %Sp renders the ls-style mode string.
    try testing.expect(std.mem.find(u8, output, "-rw-r--r--") != null);

    // %N closes the line with the bare file name.
    const trimmed = std.mem.trimEnd(u8, output, "\n");
    try testing.expect(std.mem.endsWith(u8, trimmed, test_path));

    // Regression guard carried over from F15: no signed-format '+' leaks.
    try testing.expect(std.mem.find(u8, output, "+") == null);
}

// F72: "If no argument is given, stat displays information about the file
// descriptor for standard input" (stat-macos.txt:14-15). The old GNU
// "missing operand" misuse error is gone. The assertion is about the error
// being gone, not about what stdin happens to be in the test harness.
test "F72: stat with no operand is not a missing-operand misuse error" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") == null);
    try testing.expect(result != @intFromEnum(common.ExitCode.misuse));
}

// F72: the SYNOPSIS groups -f/-l/-r/-s/-x as alternatives
// (stat-macos.txt:7), so combining two of them is a usage error. The
// "unrecognized option" assertion also pins that -l is a known flag now.
test "F72: stat -f with -l is a usage error" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "%z", "-l", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@intFromEnum(common.ExitCode.misuse), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") == null,
    );
}

// F72: the same mutual exclusion for a second pair from the SYNOPSIS group.
test "F72: stat -r with -x is a usage error" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-x", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@intFromEnum(common.ExitCode.misuse), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") == null,
    );
}

// F72: -l displays output "in ls -lT format" (stat-macos.txt:51); the example
// at :231 is "drwxr-xr-x 16 root wheel 512 Apr 19 10:57:54 2002 /tmp/foo/".
test "F72: stat -l prints an ls -lT style line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "subdir", std.Io.File.Permissions.fromMode(0o755));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "subdir", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o755) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-l", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    // The ls -lT line opens with the mode string, not with the default
    // format's numeric device id.
    try testing.expect(std.mem.startsWith(u8, output, "drwxr-xr-x "));
    const trimmed = std.mem.trimEnd(u8, output, "\n");
    try testing.expect(std.mem.endsWith(u8, trimmed, test_path));
    var newline_count: usize = 0;
    for (output) |ch| {
        if (ch == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), newline_count);
}

// F72: -F appends the ls(1) type suffix — a slash after a directory — and
// "The use of -F implies -l" (stat-macos.txt:34-39, example at :227-231).
test "F72: stat -F implies -l and appends the directory suffix" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "subdir", std.Io.File.Permissions.fromMode(0o755));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "subdir", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const path_z = try std.posix.toPosixPath(test_path);
    try testing.expect(std.c.chmod(&path_z, 0o755) == 0);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-F", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    // -l is implied, so the line is in ls -lT format ...
    try testing.expect(std.mem.startsWith(u8, output, "drwxr-xr-x "));
    // ... and the pathname carries the ls-style '/' suffix.
    const expected_tail = try std.fmt.allocPrint(testing.allocator, "{s}/\n", .{test_path});
    defer testing.allocator.free(expected_tail);
    try testing.expect(std.mem.endsWith(u8, output, expected_tail));
}

// F72: -n does "not force a newline to appear at the end of each piece of
// output" (stat-macos.txt:53-54).
test "F72: stat -n suppresses the trailing newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var with_nl_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer with_nl_aw.deinit();

    const with_nl_args = [_][]const u8{ "-f", "%z", test_path };
    const with_nl_result = try runStat(
        testing.allocator,
        testing.io,
        &with_nl_args,
        &with_nl_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), with_nl_result);
    try testing.expectEqualStrings("5\n", with_nl_aw.writer.buffered());

    var no_nl_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer no_nl_aw.deinit();

    const no_nl_args = [_][]const u8{ "-n", "-f", "%z", test_path };
    const no_nl_result = try runStat(
        testing.allocator,
        testing.io,
        &no_nl_args,
        &no_nl_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), no_nl_result);
    try testing.expectEqualStrings("5", no_nl_aw.writer.buffered());
}

// F72: -q suppresses "failure messages if calls to stat(2) or lstat(2) fail"
// (stat-macos.txt:56-58). The exit status still reports the failure, since
// stat "exit[s] 0 on success, and >0 if an error occurs" (:213-215).
test "F72: stat -q suppresses the failure message but not the exit status" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-q", "/nonexistent/file/path" };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expect(result != 0);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

// F72: -r displays "the raw, numerical value (for example, times in seconds
// since the epoch, etc.)" for all struct stat fields (stat-macos.txt:60-62).
test "F72: stat -r prints raw numeric fields" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const stat_info = try tmp_dir.dir.statFile(testing.io, "test.txt", .{});
    const actual_mtime: i64 = @intCast(@divTrunc(stat_info.mtime.nanoseconds, std.time.ns_per_s));

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-r", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    // Raw output is a single line ending in the file name.
    var newline_count: usize = 0;
    for (output) |ch| {
        if (ch == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), newline_count);
    const trimmed = std.mem.trimEnd(u8, output, "\n");
    try testing.expect(std.mem.endsWith(u8, trimmed, test_path));

    // The times are epoch seconds, so the mtime appears verbatim ...
    const mtime_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{actual_mtime});
    defer testing.allocator.free(mtime_str);
    try testing.expect(std.mem.find(u8, trimmed, mtime_str) != null);

    // ... and none of the default format's quoted, formatted times survive.
    try testing.expect(std.mem.find(u8, trimmed, "\"") == null);
}

// F72: -s displays "information in 'shell output' format, suitable for
// initializing variables" (stat-macos.txt:64-65); the worked example at
// :233-243 reads back $st_size.
test "F72: stat -s prints shell variable assignments" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    // A single line of NAME=VALUE pairs, one per struct stat field.
    var newline_count: usize = 0;
    var assign_count: usize = 0;
    for (output) |ch| {
        if (ch == '\n') newline_count += 1;
        if (ch == '=') assign_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), newline_count);
    try testing.expect(assign_count >= 8);
    // st_size is the field the man page example reads back.
    try testing.expect(std.mem.find(u8, output, "st_size=5") != null);
}

// F72: -x displays "information in a more verbose way as known from some
// Linux distributions" (stat-macos.txt:71-72) — a multi-line block rather
// than the single default line.
test "F72: stat -x prints a multi-line verbose block" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-x", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    var newline_count: usize = 0;
    for (output) |ch| {
        if (ch == '\n') newline_count += 1;
    }
    try testing.expect(newline_count >= 4);
    try testing.expect(std.mem.find(u8, output, "File:") != null);
    try testing.expect(std.mem.find(u8, output, "Size:") != null);
    try testing.expect(std.mem.find(u8, output, test_path) != null);
}

// F72: -L still uses stat(2), but "If the link is broken or the target does
// not exist, fall back on lstat(2) and report information about the link"
// (stat-macos.txt:41-45).
test "F72: stat -L falls back to lstat on a broken link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(testing.io, "missing-target.txt", "broken.txt", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/broken.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-L", "-f", "%Sp", link_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const output = stdout_aw.writer.buffered();
    // The reported mode is the link's own, so the type character is 'l'.
    try testing.expect(output.len > 0);
    try testing.expectEqual(@as(u8, 'l'), output[0]);
}

// F72: -f is NOT an alias for --file-system any more. The BSD format string
// wins, and no filesystem block is printed.
test "F72: stat -f does not alias --file-system" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "%z", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Block size:") == null);
}

// F72: -t is NOT an alias for --terse any more. It consumes "%Y" as its
// timefmt argument, so "%Y" never becomes a path operand and no terse line
// is emitted.
test "F72: stat -t does not alias --terse" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-t", "%Y", "-f", "%N", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// F72: the GNU long option --file-system survives the BSD conversion because
// it does not collide with any BSD short flag.
test "F72: stat --file-system still prints file system status" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--file-system", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "File:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Block") != null);
}

// F72: ported from the old F16 guard, now reached through --file-system:
// the statfs struct must match the platform, so the reported block size
// stays in a sane range instead of being garbage from wrong field offsets.
test "F72: stat --file-system produces a sane block size" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--file-system", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    const block_pos = std.mem.find(u8, output, "Block size:") orelse
        return error.TestExpectedEqual;
    const after_label = output[block_pos + "Block size:".len ..];
    var start: usize = 0;
    while (start < after_label.len and after_label[start] == ' ') : (start += 1) {}
    var end: usize = start;
    while (end < after_label.len and
        after_label[end] >= '0' and
        after_label[end] <= '9') : (end += 1)
    {}
    const block_size_str = after_label[start..end];
    const block_size = std.fmt.parseInt(u64, block_size_str, 10) catch
        return error.TestExpectedEqual;

    try testing.expect(block_size >= 512);
    try testing.expect(block_size <= 1048576);
}

// F72: ported from the old F17 guard: --file-system combined with a GNU
// -c FORMAT must honor the format string rather than printing the block.
test "F72: stat --file-system with -c honors the GNU format string" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--file-system", "-c", "%n", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// F72: the GNU long option --terse survives too, and keeps GNU's 16-field
// terse line (ported from the old F18 guard).
test "F72: stat --terse still prints the GNU 16-field terse line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--terse", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    try testing.expect(std.mem.startsWith(u8, trimmed, test_path));

    var field_count: usize = 0;
    var in_field = false;
    for (trimmed) |ch| {
        if (ch == ' ') {
            if (in_field) {
                field_count += 1;
                in_field = false;
            }
        } else {
            in_field = true;
        }
    }
    if (in_field) field_count += 1;

    try testing.expectEqual(@as(usize, 16), field_count);
}

// F72: -c keeps GNU directive semantics; GNU %s is the total size in bytes,
// which is a different directive language from the BSD %z used by -f.
test "F72: stat -c '%s' still uses GNU directives" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
}
