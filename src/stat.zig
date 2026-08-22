//! stat - display file or file system status
//!
//! The stat utility displays detailed information about files or file
//! systems. By default it shows file status; with -f it shows file
//! system status. Output format can be customized with -c/--format
//! or --printf.
//!
//! This implementation follows GNU coreutils stat behavior.

const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
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

/// The BSD whole-output display modes. They are mutually exclusive: each
/// replaces the entire record rendering rather than toggling a detail.
const BsdMode = enum { none, ls, raw, shell, verbose };

/// The flag letter FreeBSD names each display mode by in its diagnostics.
fn bsdModeChar(mode: BsdMode) u8 {
    return switch (mode) {
        .none => 0,
        .ls => 'l',
        .raw => 'r',
        .shell => 's',
        .verbose => 'x',
    };
}

/// Default time format for the BSD display modes ("%b %e %T %Y").
const bsd_timefmt: [*:0]const u8 = "%b %e %T %Y";

/// Time format the BSD -x mode uses instead of `bsd_timefmt`.
const bsd_verbose_timefmt: [*:0]const u8 = "%c";

const StatOptions = struct {
    dereference: bool = false,
    file_system: bool = false,
    format: ?[]const u8 = null,
    printf_fmt: ?[]const u8 = null,
    terse: bool = false,
    /// BSD -n: suppress the newline that terminates each file's record.
    no_newline: bool = false,
    /// BSD -q: suppress per-file access diagnostics without clearing the
    /// non-zero exit status they would otherwise accompany.
    quiet: bool = false,
    /// BSD -l/-r/-s/-x: the whole-output display mode in effect.
    bsd_mode: BsdMode = .none,
    /// BSD -F: append ls -F type suffixes to the -l rendering.
    type_suffix: bool = false,
    /// Set when a second display mode was given: the mode already in effect
    /// followed by the offending flag letter, in FreeBSD's diagnostic order.
    mode_conflict: ?[2]u8 = null,
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

/// Handle one clustered short-option argument (e.g. "-Lf"). May advance `i`
/// to consume a space-separated value for `-c`. Returns any error message;
/// `-h`/`-V` set opts without an error (caller continues to next arg).
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
        switch (arg[j]) {
            'L' => opts.dereference = true,
            'f' => opts.file_system = true,
            't' => opts.terse = true,
            'n' => opts.no_newline = true,
            'q' => opts.quiet = true,
            'l' => parseArgs_bsdMode(opts, .ls),
            'r' => parseArgs_bsdMode(opts, .raw),
            's' => parseArgs_bsdMode(opts, .shell),
            'x' => parseArgs_bsdMode(opts, .verbose),
            'F' => opts.type_suffix = true,
            'h' => {
                opts.help = true;
                break;
            },
            'V' => {
                opts.version = true;
                break;
            },
            'c' => {
                // -c FORMAT: value is the rest of this arg or next arg
                if (j + 1 < arg.len) {
                    opts.format = arg[j + 1 ..];
                } else if (i.* + 1 < args.len) {
                    i.* += 1;
                    opts.format = args[i.*];
                } else {
                    return .{ .err = "option '-c' requires an argument", .stop = true };
                }
                // Done with this arg either way
                break;
            },
            else => {
                return .{ .err = "unrecognized option", .stop = true };
            },
        }
    }
    return .{ .err = null, .stop = false };
}

/// Select a BSD display mode. A mode already in effect is not replaced:
/// FreeBSD rejects the second one outright, naming the first, so the pair is
/// recorded here and diagnosed once parsing is done.
fn parseArgs_bsdMode(opts: *StatOptions, mode: BsdMode) void {
    std.debug.assert(mode != .none);
    std.debug.assert(bsdModeChar(mode) != 0);
    if (opts.mode_conflict != null) return;
    if (opts.bsd_mode != .none) {
        opts.mode_conflict = .{ bsdModeChar(opts.bsd_mode), bsdModeChar(mode) };
        return;
    }
    opts.bsd_mode = mode;
}

// ============================================================================
// Low-level stat wrapper
// ============================================================================

const Timespec = struct {
    sec: i64,
    nsec: i64,
};

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
    atim: Timespec,
    mtim: Timespec,
    ctim: Timespec,
    btim: Timespec, // birth time; sec == 0 is a LEGAL value
    // Whether `btim` is actually available, per statx's STATX_BTIME mask bit
    // (Linux) or the unconditional guarantee of fstatat's birthtimespec
    // (macOS/BSD). NEVER derive this from `btim.sec == 0` -- a file born at
    // or near the epoch (e.g. devtmpfs during early boot, before the clock
    // is set) legitimately has sec == 0 with the mask bit SET (issue #102).
    btim_valid: bool,
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

/// Encode a (major, minor) pair the way the kernel does, matching glibc's
/// makedev(3). statx reports the two halves separately, but every consumer
/// (%d, %D, the Device: lines) expects the packed dev_t that stat(2) reports,
/// so the halves must be recombined with the real layout rather than spliced.
fn makeDev(major: u32, minor: u32) u64 {
    const maj: u64 = major;
    const min: u64 = minor;
    const dev = ((maj & 0xfffff000) << 32) | ((maj & 0xfff) << 8) |
        ((min & 0xffffff00) << 12) | (min & 0xff);
    // Postconditions on the two halves that every extraction site reads back:
    // the low byte carries the minor's low bits, and bits 8..19 the major's.
    std.debug.assert((dev & 0xff) == (min & 0xff));
    std.debug.assert(((dev >> 8) & 0xfff) == (maj & 0xfff));
    return dev;
}

/// Major number of a packed device id, using the platform's bit layout.
fn devMajor(dev: u64) u64 {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return (dev >> 24) & 0xff;
    }
    return ((dev >> 32) & 0xfffff000) | ((dev >> 8) & 0xfff);
}

/// Minor number of a packed device id, using the platform's bit layout.
fn devMinor(dev: u64) u64 {
    if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
        return dev & 0xffffff;
    }
    return ((dev >> 12) & 0xffffff00) | (dev & 0xff);
}

/// Linux statx-backed stat. Maps errno to errors and composes dev/rdev ids.
fn doStat_linux(c_path: [*:0]const u8, follow_symlinks: bool) !StatResult {
    const linux = std.os.linux;
    const at_flags: u32 = if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
    // The only two flag values this helper ever issues; assert positive and
    // negative space so a future caller cannot smuggle in an unexpected bit.
    std.debug.assert(follow_symlinks == (at_flags == 0));
    std.debug.assert((!follow_symlinks) == (at_flags == linux.AT.SYMLINK_NOFOLLOW));

    var stx: linux.Statx = undefined;
    const statx_mask: linux.STATX = @bitCast(@as(u32, 0xfff)); // BASIC_STATS | BTIME
    const rc = linux.statx(c.AT.FDCWD, c_path, at_flags, statx_mask, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .ACCES => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .LOOP => return error.SymLinkLoop,
        else => return error.SystemResources,
    }
    const dev_id = makeDev(stx.dev_major, stx.dev_minor);
    const rdev_id = makeDev(stx.rdev_major, stx.rdev_minor);
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
        // The kernel reports which fields it actually filled in; btime is
        // optional (procfs and older filesystems never set it), so only the
        // mask bit can say whether `btim` means anything (issue #102).
        .btim_valid = stx.mask.BTIME,
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
    if (result != 0) {
        const errno = std.posix.errno(result);
        return switch (errno) {
            .ACCES => error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .LOOP => return error.SymLinkLoop,
            else => return error.SystemResources,
        };
    }
    // Darwin/OpenBSD `dev_t` is a signed i32; FreeBSD/NetBSD use u64.
    // Reinterpret the bits and zero-extend (commit 6b97443, the `ls /` panic).
    const btim = timespecField(stat_buf, "birthtimespec", "birthtim");
    return StatResult{
        .dev = widenDev(stat_buf.dev),
        .ino = @intCast(stat_buf.ino),
        .mode = @intCast(stat_buf.mode),
        .nlink = @intCast(stat_buf.nlink),
        .uid = @intCast(stat_buf.uid),
        .gid = @intCast(stat_buf.gid),
        .rdev = widenDev(stat_buf.rdev),
        .size = @intCast(stat_buf.size),
        .blksize = @intCast(stat_buf.blksize),
        .blocks = @intCast(stat_buf.blocks),
        .atim = timespecField(stat_buf, "atimespec", "atim"),
        .mtim = timespecField(stat_buf, "mtimespec", "mtim"),
        .ctim = timespecField(stat_buf, "ctimespec", "ctim"),
        .btim = btim,
        // Linux has an explicit STATX_BTIME mask bit; BSD has none, so GNU
        // infers unavailability from the value itself. gnulib's
        // get_stat_birthtime treats a zero tv_sec, or an out-of-range tv_nsec,
        // as unavailable -- which is how `gstat -c %w /dev/null` prints "-"
        // for a devfs node. The asymmetry between the platforms is GNU's, not
        // ours (issue #102).
        .btim_valid = btim.sec != 0 and
            btim.nsec >= 0 and
            btim.nsec < 1_000_000_000,
    };
}

/// Widen a platform `st_dev`/`st_rdev` into `StatResult`'s u64 fields.
///
/// Darwin/OpenBSD `dev_t` is a signed i32; FreeBSD/NetBSD use u64.
/// `@bitCast` into a u32 is a compile error on the 64-bit type. Reinterpret
/// the bits and zero-extend.
fn widenDev(dev: anytype) u64 {
    const T = @TypeOf(dev);
    const bits = @bitSizeOf(T);
    std.debug.assert(bits == 32 or bits == 64);
    std.debug.assert(@typeInfo(T) == .int);
    const unsigned: @Int(.unsigned, bits) = @bitCast(dev);
    return @as(u64, unsigned);
}

/// Read a timespec by Darwin name (`atimespec`) or POSIX name (`atim`).
/// Missing both names (birth time on some BSDs) yields zeros.
fn timespecField(
    stat_buf: anytype,
    comptime darwin_name: []const u8,
    comptime posix_name: []const u8,
) Timespec {
    std.debug.assert(darwin_name.len > 0);
    std.debug.assert(posix_name.len > 0);
    std.debug.assert(!std.mem.eql(u8, darwin_name, posix_name));
    const T = @TypeOf(stat_buf);
    const has_darwin = @hasField(T, darwin_name);
    const has_posix = @hasField(T, posix_name);
    const both_names = has_darwin and has_posix;
    std.debug.assert(!both_names);
    if (has_darwin) {
        const ts = @field(stat_buf, darwin_name);
        return .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
    }
    if (has_posix) {
        const ts = @field(stat_buf, posix_name);
        return .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
    }
    return .{ .sec = 0, .nsec = 0 };
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

/// %W: the birth time as seconds since the epoch, "0" when unknown. Unlike
/// %w this is always numeric; GNU never renders a dash here (pinned against
/// procfs, which has no birth time: `stat -c '%w|%W'` prints "-|0").
fn expandFormatDirective_birthEpoch(stat_buf: StatResult, writer: anytype) !void {
    // A value the kernel did not vouch for must not leak through, so the mask
    // bit decides the output, never the value itself (issue #102).
    if (!stat_buf.btim_valid) {
        try writer.writeAll("0");
    } else {
        try writer.print("{d}", .{getTimespecSec(stat_buf, .btime)});
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

/// Quote `name` the way GNU's shell_escape_quoting_style does, so that the
/// result is exactly one shell token. Rules pinned against GNU coreutils 9.5:
///   1. no `'` in the name             -> single quotes, content verbatim.
///   2. `'` present, none of " \ $ `   -> double quotes, content verbatim.
///   3. `'` present, any of  " \ $ `   -> single quotes, each `'` spliced
///      as `'\''` (close the quote, escaped quote, reopen).
/// Double quotes are only safe when nothing inside would still need escaping
/// within them, which is why rule 3 exists (issue #105). Non-printable bytes
/// pass through verbatim; GNU's ANSI-C `$'\n'` splicing is a separate feature
/// and is deliberately not implemented here.
fn writeShellQuoted(name: []const u8, writer: anytype) !void {
    if (std.mem.findScalar(u8, name, '\'') == null) {
        try writer.print("'{s}'", .{name});
        return;
    }
    if (std.mem.findAny(u8, name, "\"\\$`") == null) {
        try writer.print("\"{s}\"", .{name});
        return;
    }
    try writer.writeByte('\'');
    for (name) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

/// %N: emit the quoted file name, appending " -> TARGET" for an
/// unfollowed symbolic link. The link name and the target pick their quote
/// style independently, exactly as GNU quotes each operand on its own.
fn expandFormatDirective_quotedName(
    stat_buf: StatResult,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    std.debug.assert(stat_buf.mode != 0);
    if ((mode & c.S.IFMT) == c.S.IFLNK and !follow_symlinks) {
        std.debug.assert(path.len > 0);
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var path_zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len <= std.fs.max_path_bytes) {
            @memcpy(path_zbuf[0..path.len], path);
            path_zbuf[path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(&path_zbuf);
            const n = c.readlink(path_z, &link_buf, link_buf.len);
            if (n > 0) {
                // readlink(2) never returns more than the buffer size, so the
                // @intCast slice below stays in bounds.
                std.debug.assert(n <= @as(isize, @intCast(link_buf.len)));
                const target = link_buf[0..@intCast(n)];
                try writeShellQuoted(path, writer);
                try writer.writeAll(" -> ");
                try writeShellQuoted(target, writer);
            } else {
                try writeShellQuoted(path, writer);
            }
        } else {
            try writeShellQuoted(path, writer);
        }
    } else {
        try writeShellQuoted(path, writer);
    }
}

/// %t / %T: emit the major or minor device number of rdev in hex, using
/// the platform's documented bit layout.
fn expandFormatDirective_deviceType(
    stat_buf: StatResult,
    comptime part: enum { major, minor },
    writer: anytype,
) !void {
    const major = devMajor(stat_buf.rdev);
    const minor = devMinor(stat_buf.rdev);
    if (builtin.os.tag == .linux) {
        // The two halves must round-trip through the kernel's encoding, or
        // %t/%T would disagree with the Device type line for the same file.
        std.debug.assert(makeDev(@intCast(major), @intCast(minor)) == stat_buf.rdev);
    }
    const val: u64 = switch (part) {
        .major => major,
        .minor => minor,
    };
    try writer.print("{x}", .{val});
}

/// %w: emit the birth time in human-readable form, or "-" when the kernel
/// reported no birth time or formatting fails.
fn expandFormatDirective_birthTime(stat_buf: StatResult, writer: anytype) !void {
    if (!stat_buf.btim_valid) {
        try writer.writeAll("-");
    } else {
        var fmt_buf: [64]u8 = undefined;
        const btime_sec = getTimespecSec(stat_buf, .btime);
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
// Default output format
// ============================================================================

fn printDefaultFormat(
    allocator: Allocator,
    stat_buf: StatResult,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    try printDefaultFormat_fileLine(stat_buf, path, follow_symlinks, writer);
    try printDefaultFormat_sizeLine(stat_buf, mode, writer);
    try printDefaultFormat_deviceLine(stat_buf, mode, writer);
    try printDefaultFormat_accessLine(allocator, stat_buf, mode, writer);
    try printDefaultFormat_timeLines(stat_buf, writer);
}

/// Line 1: "  File: NAME" with " -> TARGET" for unfollowed symlinks.
fn printDefaultFormat_fileLine(
    stat_buf: StatResult,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    std.debug.assert(mode != 0);
    try writer.writeAll("  File: ");
    if ((mode & c.S.IFMT) == c.S.IFLNK and !follow_symlinks) {
        std.debug.assert(path.len > 0);
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var path_buf2: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len <= std.fs.max_path_bytes) {
            @memcpy(path_buf2[0..path.len], path);
            path_buf2[path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(&path_buf2);
            const n = c.readlink(path_z, &link_buf, link_buf.len);
            if (n > 0) {
                // readlink(2) never returns more than the buffer size, so the
                // @intCast slice below stays in bounds.
                std.debug.assert(n <= @as(isize, @intCast(link_buf.len)));
                const target = link_buf[0..@intCast(n)];
                try writer.print("{s} -> {s}\n", .{ path, target });
            } else {
                try writer.print("{s}\n", .{path});
            }
        } else {
            try writer.print("{s}\n", .{path});
        }
    } else {
        try writer.print("{s}\n", .{path});
    }
}

/// Line 2: "  Size: ...\tBlocks: ... IO Block: ... <file type>". The pad
/// widths and the separators after them are GNU's, not stylistic: keeping
/// each separator literal is what makes it survive a value that overflows
/// its pad (a 10 GB file's 11-digit size, say).
fn printDefaultFormat_sizeLine(stat_buf: StatResult, mode: u32, writer: anytype) !void {
    const size: i64 = @intCast(stat_buf.size);
    const file_type = if ((mode & c.S.IFMT) == c.S.IFREG and size == 0)
        "regular empty file"
    else
        fileTypeString(mode);
    // stat(2) returns non-negative values on success; assert before casting
    // to u64 since @intCast panics on negative i64 sources.
    std.debug.assert(stat_buf.size >= 0);
    std.debug.assert(stat_buf.blocks >= 0);
    std.debug.assert(stat_buf.blksize >= 0);
    const size_u: u64 = @intCast(stat_buf.size);
    const blocks_u: u64 = @intCast(stat_buf.blocks);
    const blksize_u: u64 = @intCast(stat_buf.blksize);
    try writer.print("  Size: {d: <10}\tBlocks: {d: <10} IO Block: {d: <6} {s}\n", .{
        size_u,
        blocks_u,
        blksize_u,
        file_type,
    });
}

/// Line 3: "Device: MAJ,MIN\tInode: ...  Links: ..." (GNU decimal major,minor).
/// Character and block special files gain GNU's " Device type: MAJ,MIN"
/// suffix, which also widens the Links field to five columns; every other
/// file type keeps the unpadded form with no trailing whitespace.
fn printDefaultFormat_deviceLine(stat_buf: StatResult, mode: u32, writer: anytype) !void {
    std.debug.assert(mode != 0);
    std.debug.assert((mode & c.S.IFMT) != 0);
    const dev_major: u64 = devMajor(stat_buf.dev);
    const dev_minor: u64 = devMinor(stat_buf.dev);
    const file_type = mode & c.S.IFMT;
    const is_device = file_type == c.S.IFCHR or file_type == c.S.IFBLK;
    if (!is_device) {
        try writer.print("Device: {d},{d}\tInode: {d: <10}  Links: {d}\n", .{
            dev_major,
            dev_minor,
            stat_buf.ino,
            stat_buf.nlink,
        });
        return;
    }
    try writer.print("Device: {d},{d}\tInode: {d: <10}  Links: {d: <5} Device type: {d},{d}\n", .{
        dev_major,
        dev_minor,
        stat_buf.ino,
        stat_buf.nlink,
        devMajor(stat_buf.rdev),
        devMinor(stat_buf.rdev),
    });
}

/// Line 4: "Access: (MODE/PERMS)  Uid: (...)   Gid: (...)".
fn printDefaultFormat_accessLine(
    allocator: Allocator,
    stat_buf: StatResult,
    mode: u32,
    writer: anytype,
) !void {
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);
    const octal_mode = mode & 0o7777;
    std.debug.assert(perms.len == 10);
    std.debug.assert(octal_mode <= 0o7777);

    // User name
    const uid: u32 = @intCast(stat_buf.uid);
    var user_name_buf: [256]u8 = undefined;
    const user_name = blk: {
        const user_info = common.user_group.getUserById(uid, allocator) catch {
            const fallback = std.fmt.bufPrint(&user_name_buf, "{d}", .{uid}) catch break :blk "?";
            break :blk fallback;
        };
        defer allocator.free(user_info.name);
        @memcpy(user_name_buf[0..user_info.name.len], user_info.name);
        break :blk user_name_buf[0..user_info.name.len];
    };

    // Group name
    const gid: u32 = @intCast(stat_buf.gid);
    var group_name_buf: [256]u8 = undefined;
    const group_name = blk: {
        const group_info = common.user_group.getGroupById(gid, allocator) catch {
            const fallback = std.fmt.bufPrint(&group_name_buf, "{d}", .{gid}) catch break :blk "?";
            break :blk fallback;
        };
        defer allocator.free(group_info.name);
        @memcpy(group_name_buf[0..group_info.name.len], group_info.name);
        break :blk group_name_buf[0..group_info.name.len];
    };

    // Both names are either a short decimal-id fallback or a passwd/group name
    // copied into a 256-byte buffer, so neither slice exceeds its buffer.
    std.debug.assert(user_name.len <= user_name_buf.len);
    std.debug.assert(group_name.len <= group_name_buf.len);
    try writer.print("Access: ({o:0>4}/{s})  Uid: ({d: >5}/{s: >8})   Gid: ({d: >5}/{s: >8})\n", .{
        octal_mode,
        perms,
        uid,
        user_name,
        gid,
        group_name,
    });
}

/// Lines 5-8: Access, Modify, Change, and Birth timestamps. The Birth line
/// closes the record, so it carries no trailing newline: the record
/// terminator is appended by the caller so that -n can suppress it uniformly.
fn printDefaultFormat_timeLines(stat_buf: StatResult, writer: anytype) !void {
    // Line 5: Access time
    {
        var fmt_buf: [64]u8 = undefined;
        const atime_sec = getTimespecSec(stat_buf, .atime);
        const atime_nsec = getTimespecNsec(stat_buf, .atime);
        const formatted = formatTimestamp(atime_sec, atime_nsec, &fmt_buf) catch "-";
        try writer.print("Access: {s}\n", .{formatted});
    }

    // Line 6: Modify time
    {
        var fmt_buf: [64]u8 = undefined;
        const mtime_sec = getTimespecSec(stat_buf, .mtime);
        const mtime_nsec = getTimespecNsec(stat_buf, .mtime);
        const formatted = formatTimestamp(mtime_sec, mtime_nsec, &fmt_buf) catch "-";
        try writer.print("Modify: {s}\n", .{formatted});
    }

    // Line 7: Change time
    {
        var fmt_buf: [64]u8 = undefined;
        const ctime_sec = getTimespecSec(stat_buf, .ctime);
        const ctime_nsec = getTimespecNsec(stat_buf, .ctime);
        const formatted = formatTimestamp(ctime_sec, ctime_nsec, &fmt_buf) catch "-";
        try writer.print("Change: {s}\n", .{formatted});
    }

    // Line 8: Birth time. Availability comes from the kernel's mask bit, not
    // from the seconds value: a file born at the epoch is still born (#102).
    {
        if (!stat_buf.btim_valid) {
            try writer.print(" Birth: -", .{});
        } else {
            var fmt_buf: [64]u8 = undefined;
            const btime_sec = getTimespecSec(stat_buf, .btime);
            const btime_nsec = getTimespecNsec(stat_buf, .btime);
            const formatted = formatTimestamp(btime_sec, btime_nsec, &fmt_buf) catch "-";
            try writer.print(" Birth: {s}", .{formatted});
        }
    }
}

// ============================================================================
// Terse output format
// ============================================================================

/// Emit the single-line terse record without its terminating newline: the
/// record terminator is appended by the caller so that -n can suppress it
/// uniformly across every output mode.
fn printTerseFormat(stat_buf: StatResult, path: []const u8, writer: anytype) !void {
    const mode: u32 = stat_buf.mode;
    const dev: u64 = stat_buf.dev;

    // Device major/minor from rdev, in the platform's packed dev_t layout.
    const rdev_major: u64 = devMajor(stat_buf.rdev);
    const rdev_minor: u64 = devMinor(stat_buf.rdev);
    if (builtin.os.tag == .linux) {
        // The halves tile every bit of the kernel's encoding, so they must
        // reassemble into the same rdev the terse line reports elsewhere.
        std.debug.assert(makeDev(@intCast(rdev_major), @intCast(rdev_minor)) == stat_buf.rdev);
    }

    const btime_sec = getTimespecSec(stat_buf, .btime);

    // GNU terse: 16 fields
    // name size blocks mode uid gid dev inode nlinks major minor atime mtime ctime btime blksize
    try writer.print("{s} {d} {d} {x} {d} {d} {x} {d} {d} {x} {x} {d} {d} {d} {d} {d}", .{
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

/// Emit the multi-line statfs record without its terminating newline: the
/// record terminator is appended by the caller so that -n can suppress it
/// uniformly across every output mode. Interior newlines are unaffected.
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
        try writer.print("  From: {s}", .{info.dev});
    } else {
        const mntonname = std.mem.sliceTo(&fs_buf.f_mntonname, 0);
        const mntfromname = std.mem.sliceTo(&fs_buf.f_mntfromname, 0);
        try writer.print(" Mount: {s}\n", .{mntonname});
        try writer.print("  From: {s}", .{mntfromname});
    }
}

// ============================================================================
// BSD display modes
// ============================================================================

/// Copy the passwd name for `uid` into `buf`, falling back to the decimal id
/// when the lookup fails or the name does not fit. Returns a slice of `buf`.
fn bsdUserName(allocator: Allocator, uid: u32, buf: *[256]u8) []const u8 {
    const info = common.user_group.getUserById(uid, allocator) catch {
        return std.fmt.bufPrint(buf, "{d}", .{uid}) catch "?";
    };
    defer allocator.free(info.name);
    if (info.name.len > buf.len) return std.fmt.bufPrint(buf, "{d}", .{uid}) catch "?";
    @memcpy(buf[0..info.name.len], info.name);
    return buf[0..info.name.len];
}

/// Copy the group name for `gid` into `buf`, falling back to the decimal id
/// when the lookup fails or the name does not fit. Returns a slice of `buf`.
fn bsdGroupName(allocator: Allocator, gid: u32, buf: *[256]u8) []const u8 {
    const info = common.user_group.getGroupById(gid, allocator) catch {
        return std.fmt.bufPrint(buf, "{d}", .{gid}) catch "?";
    };
    defer allocator.free(info.name);
    if (info.name.len > buf.len) return std.fmt.bufPrint(buf, "{d}", .{gid}) catch "?";
    @memcpy(buf[0..info.name.len], info.name);
    return buf[0..info.name.len];
}

/// Render `sec` through strftime, yielding an empty string when the epoch
/// value cannot be converted. Returns a slice of `buf`.
fn bsdTimeString(sec: i64, fmt: [*:0]const u8, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 32);
    const when: c.time_t = @intCast(sec);
    var tm: time.c_tm = undefined;
    if (time.localtime_r(&when, &tm) == null) return "";
    const len = time.strftime(buf.ptr, buf.len, fmt, &tm);
    if (len == 0) return "";
    // strftime reports the bytes it wrote, never more than the buffer it was
    // handed, so the slice below stays inside `buf`.
    std.debug.assert(len <= buf.len);
    return buf[0..len];
}

/// %HT: the BSD type word naming the file's kind.
fn bsdTypeWord(mode: u32) []const u8 {
    return switch (mode & c.S.IFMT) {
        c.S.IFREG => "Regular File",
        c.S.IFDIR => "Directory",
        c.S.IFLNK => "Symbolic Link",
        c.S.IFCHR => "Character Device",
        c.S.IFBLK => "Block Device",
        c.S.IFIFO => "Fifo File",
        c.S.IFSOCK => "Socket",
        else => "",
    };
}

/// %T: the `ls -F` suffix for the file's kind, empty when it has none.
fn bsdTypeSuffix(mode: u32) []const u8 {
    return switch (mode & c.S.IFMT) {
        c.S.IFIFO => "|",
        c.S.IFDIR => "/",
        c.S.IFREG => if (mode & 0o111 != 0) "*" else "",
        c.S.IFLNK => "@",
        c.S.IFSOCK => "=",
        else => "",
    };
}

/// %SY: " -> TARGET" for a symbolic link, nothing for any other file. The
/// arrow belongs to the directive, so callers emit it unconditionally.
fn writeBsdLinkTarget(mode: u32, path: []const u8, writer: anytype) !void {
    std.debug.assert(path.len > 0);
    if ((mode & c.S.IFMT) != c.S.IFLNK) return;
    if (path.len > std.fs.max_path_bytes) return;

    var path_zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_zbuf[0..path.len], path);
    path_zbuf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_zbuf);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = c.readlink(path_z, &link_buf, link_buf.len);
    if (n <= 0) return;
    // readlink(2) never reports more than the buffer size it was given, so the
    // @intCast slice below stays in bounds.
    std.debug.assert(n <= @as(isize, @intCast(link_buf.len)));
    try writer.print(" -> {s}", .{link_buf[0..@intCast(n)]});
}

/// %Z: "major,minor" for a device node, the plain size for anything else.
fn writeSizeRdev(stat_buf: StatResult, writer: anytype) !void {
    const kind = stat_buf.mode & c.S.IFMT;
    std.debug.assert(kind != 0);
    if (kind == c.S.IFCHR or kind == c.S.IFBLK) {
        try writer.print("{d},{d}", .{ devMajor(stat_buf.rdev), devMinor(stat_buf.rdev) });
        return;
    }
    std.debug.assert(stat_buf.size >= 0);
    try writer.print("{d}", .{stat_buf.size});
}

/// -r RAW_FORMAT: "%d %i %#p %l %u %g %r %z %a %m %c %B %k %b %f %N". st_flags
/// is a BSD-only field with no Linux equivalent, so it always renders as 0.
fn printRawFormat(stat_buf: StatResult, path: []const u8, writer: anytype) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(stat_buf.mode != 0);
    try writer.print("{d} {d} 0{o} {d} {d} {d} {d} {d}", .{
        stat_buf.dev,
        stat_buf.ino,
        stat_buf.mode,
        stat_buf.nlink,
        stat_buf.uid,
        stat_buf.gid,
        stat_buf.rdev,
        stat_buf.size,
    });
    try writer.print(" {d} {d} {d} {d} {d} {d} 0 {s}", .{
        stat_buf.atim.sec,
        stat_buf.mtim.sec,
        stat_buf.ctim.sec,
        stat_buf.btim.sec,
        stat_buf.blksize,
        stat_buf.blocks,
        path,
    });
}

/// -s SHELL_FORMAT: fifteen eval-safe "st_NAME=VALUE" assignments. The record
/// carries no file name, matching BSD, so `eval $(stat -s FILE)` sets only the
/// stat fields.
fn printShellFormat(stat_buf: StatResult, writer: anytype) !void {
    std.debug.assert(stat_buf.mode != 0);
    std.debug.assert(stat_buf.size >= 0);
    try writer.print("st_dev={d} st_ino={d} st_mode=0{o} st_nlink={d}", .{
        stat_buf.dev,
        stat_buf.ino,
        stat_buf.mode,
        stat_buf.nlink,
    });
    try writer.print(" st_uid={d} st_gid={d} st_rdev={d} st_size={d}", .{
        stat_buf.uid,
        stat_buf.gid,
        stat_buf.rdev,
        stat_buf.size,
    });
    try writer.print(" st_atime={d} st_mtime={d} st_ctime={d} st_birthtime={d}", .{
        stat_buf.atim.sec,
        stat_buf.mtim.sec,
        stat_buf.ctim.sec,
        stat_buf.btim.sec,
    });
    try writer.print(" st_blksize={d} st_blocks={d} st_flags=0", .{
        stat_buf.blksize,
        stat_buf.blocks,
    });
}

/// -l LS_FORMAT ("%Sp %l %Su %Sg %Z %Sm %N%SY") and, when `type_suffix` is
/// set, -F LSF_FORMAT ("%Sp %l %Su %Sg %Z %Sm %N%T%SY"): the two presets
/// differ only by the %T suffix wedged between the name and the arrow.
fn printLsFormat(
    allocator: Allocator,
    stat_buf: StatResult,
    path: []const u8,
    type_suffix: bool,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    std.debug.assert(path.len > 0);
    std.debug.assert(mode != 0);

    var perm_buf: [10]u8 = undefined;
    var user_buf: [256]u8 = undefined;
    var group_buf: [256]u8 = undefined;
    var time_buf: [128]u8 = undefined;

    try writer.print("{s} {d} {s} {s} ", .{
        formatPermissions(mode, &perm_buf),
        stat_buf.nlink,
        bsdUserName(allocator, stat_buf.uid, &user_buf),
        bsdGroupName(allocator, stat_buf.gid, &group_buf),
    });
    try writeSizeRdev(stat_buf, writer);
    try writer.print(" {s} {s}", .{
        bsdTimeString(stat_buf.mtim.sec, bsd_timefmt, &time_buf),
        path,
    });
    if (type_suffix) try writer.writeAll(bsdTypeSuffix(mode));
    try writeBsdLinkTarget(mode, path, writer);
}

/// -x LINUX_FORMAT: eight labelled lines with BSD's literal spacing. The
/// closing Birth line carries no newline of its own; the record terminator is
/// appended by the caller so that -n can suppress it.
fn printVerboseFormat(
    allocator: Allocator,
    stat_buf: StatResult,
    path: []const u8,
    writer: anytype,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(stat_buf.mode != 0);
    try writer.print("  File: \"{s}\"\n", .{path});
    try printVerboseFormat_sizeLine(stat_buf, writer);
    try printVerboseFormat_modeLine(allocator, stat_buf, writer);
    try printVerboseFormat_deviceLine(stat_buf, writer);
    try printVerboseFormat_timeLines(stat_buf, writer);
}

/// "  Size: %-11z  FileType: %HT".
fn printVerboseFormat_sizeLine(stat_buf: StatResult, writer: anytype) !void {
    std.debug.assert(stat_buf.size >= 0);
    std.debug.assert((stat_buf.mode & c.S.IFMT) != 0);
    const size_u: u64 = @intCast(stat_buf.size);
    try writer.print("  Size: {d: <11}  FileType: {s}\n", .{
        size_u,
        bsdTypeWord(stat_buf.mode),
    });
}

/// "  Mode: (%OMp%03OLp/%.10Sp)         Uid: (%5u/%8Su)  Gid: (%5g/%8Sg)".
fn printVerboseFormat_modeLine(
    allocator: Allocator,
    stat_buf: StatResult,
    writer: anytype,
) !void {
    const mode: u32 = stat_buf.mode;
    std.debug.assert(mode != 0);
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);
    std.debug.assert(perms.len == 10);
    var user_buf: [256]u8 = undefined;
    var group_buf: [256]u8 = undefined;
    try writer.print(
        "  Mode: ({o}{o:0>3}/{s})         Uid: ({d: >5}/{s: >8})  Gid: ({d: >5}/{s: >8})\n",
        .{
            (mode >> 9) & 7,
            mode & 0o777,
            perms,
            stat_buf.uid,
            bsdUserName(allocator, stat_buf.uid, &user_buf),
            stat_buf.gid,
            bsdGroupName(allocator, stat_buf.gid, &group_buf),
        },
    );
}

/// "Device: %Hd,%Ld   Inode: %i    Links: %l".
fn printVerboseFormat_deviceLine(stat_buf: StatResult, writer: anytype) !void {
    std.debug.assert(stat_buf.mode != 0);
    const major = devMajor(stat_buf.dev);
    const minor = devMinor(stat_buf.dev);
    if (builtin.os.tag == .linux) {
        // The two halves must round-trip through the kernel's encoding, or the
        // Device line would disagree with %d for the very same file.
        std.debug.assert(makeDev(@intCast(major), @intCast(minor)) == stat_buf.dev);
    }
    try writer.print("Device: {d},{d}   Inode: {d}    Links: {d}\n", .{
        major,
        minor,
        stat_buf.ino,
        stat_buf.nlink,
    });
}

/// "Access:", "Modify:", "Change:" and " Birth:", rendered with the -x time
/// format. The Birth line closes the record, so it carries no newline.
fn printVerboseFormat_timeLines(stat_buf: StatResult, writer: anytype) !void {
    std.debug.assert(stat_buf.mode != 0);
    var buf: [128]u8 = undefined;
    const fmt = bsd_verbose_timefmt;
    try writer.print("Access: {s}\n", .{bsdTimeString(stat_buf.atim.sec, fmt, &buf)});
    try writer.print("Modify: {s}\n", .{bsdTimeString(stat_buf.mtim.sec, fmt, &buf)});
    try writer.print("Change: {s}\n", .{bsdTimeString(stat_buf.ctim.sec, fmt, &buf)});
    // -x is a fixed rendering of the FreeBSD preset, and BSD stat has no
    // concept of an unavailable birth time, so validity never reaches here:
    // `/usr/bin/stat -x /dev/null` prints the epoch date where GNU prints "-"
    // (issue #102).
    try writer.print(" Birth: {s}", .{bsdTimeString(stat_buf.btim.sec, fmt, &buf)});
}

/// Render one record in the selected BSD display mode.
fn printBsdFormat(
    allocator: Allocator,
    opts: *const StatOptions,
    stat_buf: StatResult,
    path: []const u8,
    writer: anytype,
) !void {
    std.debug.assert(opts.bsd_mode != .none);
    std.debug.assert(path.len > 0);
    switch (opts.bsd_mode) {
        .none => unreachable,
        .raw => try printRawFormat(stat_buf, path, writer),
        .shell => try printShellFormat(stat_buf, writer),
        .ls => try printLsFormat(allocator, stat_buf, path, opts.type_suffix, writer),
        .verbose => try printVerboseFormat(allocator, stat_buf, path, writer),
    }
}

/// Diagnose the display-mode combinations FreeBSD rejects and resolve a bare
/// -F into the ls rendering. Returns the exit status to stop with, or null
/// when the combination is legal.
fn checkBsdConflicts(
    allocator: Allocator,
    opts: *StatOptions,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    if (opts.mode_conflict) |pair| {
        // parseArgs_bsdMode only ever records real mode letters.
        std.debug.assert(pair[0] != 0);
        std.debug.assert(pair[1] != 0);
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "can't use format '{c}' with '{c}'",
            .{ pair[0], pair[1] },
        );
        return @intFromEnum(common.ExitCode.general_error);
    }
    if (opts.type_suffix) {
        if (opts.bsd_mode == .none) {
            opts.bsd_mode = .ls;
        } else if (opts.bsd_mode != .ls) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "can't use format '{c}' with -F",
                .{bsdModeChar(opts.bsd_mode)},
            );
            return @intFromEnum(common.ExitCode.general_error);
        }
    }
    return checkBsdConflicts_gnuSelector(allocator, opts, stderr_writer);
}

/// A BSD display mode and a GNU output selector each claim the whole record,
/// and no spec defines the combination, so refuse it outright rather than
/// silently picking one of the two.
fn checkBsdConflicts_gnuSelector(
    allocator: Allocator,
    opts: *const StatOptions,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    if (opts.bsd_mode == .none) return null;
    std.debug.assert(bsdModeChar(opts.bsd_mode) != 0);
    const selector: []const u8 = if (opts.format != null)
        "-c"
    else if (opts.printf_fmt != null)
        "--printf"
    else if (opts.terse)
        "-t"
    else if (opts.file_system)
        "-f"
    else
        return null;
    std.debug.assert(selector.len >= 2);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "can't use format '{c}' with {s}",
        .{ bsdModeChar(opts.bsd_mode), selector },
    );
    return @intFromEnum(common.ExitCode.general_error);
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
    var opts = parsed.opts;
    defer allocator.free(opts.positionals);

    if (parsed.err) |err_msg| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "{s}\nTry 'stat --help' for more information.",
            .{err_msg},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    if (opts.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // The display modes conflict with each other, with -F and with the GNU
    // output selectors; FreeBSD rejects those combinations during option
    // parsing, before it ever looks at the operands.
    if (checkBsdConflicts(allocator, &opts, stderr_writer)) |status| {
        return status;
    }

    if (opts.positionals.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing operand\nTry 'stat --help' for more information.",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    return runStat_operands(allocator, &opts, stdout_writer, stderr_writer);
}

/// Emit one record per operand and reduce the per-path outcomes to the
/// process exit status: any single failure makes the whole run fail.
fn runStat_operands(
    allocator: Allocator,
    opts: *const StatOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // The empty-positionals case is diagnosed by the caller, so the loop has
    // work to do, and the modes that produce no records returned before it.
    std.debug.assert(opts.positionals.len > 0);
    std.debug.assert(!opts.help);

    var has_error = false;
    for (opts.positionals) |path| {
        const failed = try processOnePath(
            allocator,
            opts,
            path,
            stdout_writer,
            stderr_writer,
        );
        if (failed) {
            has_error = true;
        }
    }

    return if (has_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
}

/// Emit stat output for a single path. Returns true when the path could
/// not be statted (or statfs'd), so the caller can flag overall failure.
fn processOnePath(
    allocator: Allocator,
    opts: *const StatOptions,
    path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !bool {
    // runStat resolves --help and --version before it walks the operands, so
    // a path only reaches here when there is real output to produce.
    std.debug.assert(!opts.help);
    std.debug.assert(!opts.version);

    if (opts.file_system and opts.format == null and opts.printf_fmt == null) {
        printFileSystemInfo(path, stdout_writer) catch {
            // BSD -q drops the diagnostic but still reports the failure, so
            // the caller's exit status stays non-zero either way.
            if (!opts.quiet) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "cannot statfs '{s}': No such file or directory",
                    .{path},
                );
            }
            return true;
        };
        try writeRecordTerminator(opts, stdout_writer);
        return false;
    }

    const stat_buf = doStat(path, opts.dereference) catch |err| {
        if (!opts.quiet) {
            reportStatFailure(allocator, path, err, stderr_writer);
        }
        return true;
    };

    try printOneRecord(allocator, opts, stat_buf, path, stdout_writer);
    return false;
}

/// Emit the "cannot stat" diagnostic for a failed doStat, translating the
/// error into the message the reference implementations print for it.
fn reportStatFailure(
    allocator: Allocator,
    path: []const u8,
    err: anyerror,
    stderr_writer: *std.Io.Writer,
) void {
    // parseArgs discards empty arguments, so every operand names something.
    std.debug.assert(path.len > 0);
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => "Cannot access",
    };
    std.debug.assert(msg.len > 0);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "cannot stat '{s}': {s}",
        .{ path, msg },
    );
}

/// Render one file's record in the selected output mode and terminate it.
/// The renderers deliberately omit their final newline so the terminator is
/// appended in exactly one place; --printf is the sole mode that appends no
/// terminator at all, matching GNU, so -n is a no-op there.
fn printOneRecord(
    allocator: Allocator,
    opts: *const StatOptions,
    stat_buf: StatResult,
    path: []const u8,
    stdout_writer: *std.Io.Writer,
) !void {
    std.debug.assert(path.len > 0);
    // A successful stat always reports a file type in the mode bits.
    std.debug.assert(stat_buf.mode != 0);

    if (opts.bsd_mode != .none) {
        try printBsdFormat(allocator, opts, stat_buf, path, stdout_writer);
    } else if (opts.format) |format| {
        try processFormatString(
            allocator,
            format,
            stat_buf,
            path,
            opts.dereference,
            false,
            stdout_writer,
        );
    } else if (opts.printf_fmt) |format| {
        try processFormatString(
            allocator,
            format,
            stat_buf,
            path,
            opts.dereference,
            true,
            stdout_writer,
        );
        return;
    } else if (opts.terse) {
        try printTerseFormat(stat_buf, path, stdout_writer);
    } else {
        try printDefaultFormat(allocator, stat_buf, path, opts.dereference, stdout_writer);
    }
    try writeRecordTerminator(opts, stdout_writer);
}

/// Append the newline that terminates one file's record, unless BSD -n asked
/// for it to be dropped. Centralizing the terminator here is what lets -n
/// suppress it in every output mode without touching interior newlines.
fn writeRecordTerminator(opts: *const StatOptions, writer: *std.Io.Writer) !void {
    // Only real operands produce records; the modes that short-circuit
    // runStat before the operand loop can never reach this point.
    std.debug.assert(!opts.help);
    std.debug.assert(!opts.version);
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
        \\Usage: stat [OPTION]... FILE...
        \\Display file or file system status.
        \\
        \\  -L, --dereference     follow links
        \\  -f, --file-system     display file system status instead of file status
        \\  -c, --format=FORMAT   use the specified FORMAT instead of the default;
        \\                          output a newline after each use of FORMAT
        \\      --printf=FORMAT   like --format, but interpret backslash escapes,
        \\                          and do not output a mandatory trailing newline
        \\  -t, --terse           print the information in terse form
        \\  -l                    display in ls -l style: mode, links, owner,
        \\                          group, size, time, name
        \\  -r                    display the raw numeric stat fields
        \\  -s                    display as shell "st_NAME=VALUE" assignments,
        \\                          suitable for eval
        \\  -x                    display in a verbose multi-line form
        \\  -F                    with -l, append an ls -F type suffix to the
        \\                          name (/ = @ * |)
        \\  -n                    do not output the trailing newline that
        \\                          terminates each file's information
        \\  -q                    suppress messages about files that cannot be
        \\                          accessed; the exit status still reports them
        \\  -h, --help            display this help and exit
        \\  -V, --version         output version information and exit
        \\
        \\The valid format sequences for files (without --file-system):
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
        \\NOTE: this stat follows the GNU interface, so -f and -t differ from
        \\BSD/macOS stat, where -f takes a format string and -t a time format:
        \\  BSD 'stat -f FORMAT'  ->  use 'stat -c FORMAT' here
        \\  BSD 'stat -t TIMEFMT' ->  no equivalent here
        \\Here -f is --file-system and -t is --terse. The BSD flags that do not
        \\collide with GNU (-F -l -n -q -r -s -x) keep their BSD meanings.
        \\-l, -r, -s and -x each select a whole output format, so at most one
        \\may be given; -F combines only with -l.
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

test "stat missing operand returns exit code 1" {
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

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "stat unknown flag returns exit code 1" {
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

    try testing.expectEqual(@as(u8, 1), result);
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

test "stat default output on regular file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello world");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{test_path};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Check key fields in default output
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "File:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Size:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Blocks:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Device:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Inode:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Access:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Modify:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Change:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "regular file") != null);
}

test "stat -c format: file name" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDir(testing.io, "subdir", std.Io.File.Permissions.fromMode(0o755));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "subdir", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(
        testing.io,
        "test.txt",
        .{ .permissions = @enumFromInt(0o644) },
    );
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    const stat_info = try tmp_dir.dir().statFile(testing.io, "test.txt", .{});
    const actual_mode: u32 = @intCast(stat_info.permissions.toMode() & 0o7777);
    const reported_mode = try std.fmt.parseInt(u32, trimmed, 8);
    try testing.expectEqual(actual_mode, reported_mode);
}

test "stat -c format: permissions human readable" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(
        testing.io,
        "test.txt",
        .{ .permissions = @enumFromInt(0o644) },
    );
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    const stat_info = try tmp_dir.dir().statFile(testing.io, "test.txt", .{});
    const actual_mtime: i64 = @intCast(@divTrunc(stat_info.mtime.nanoseconds, std.time.ns_per_s));
    try testing.expectEqual(actual_mtime, mtime_val);
}

test "stat --printf interprets escapes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "data");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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

test "stat -t terse output" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-t", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Terse output is one line with space-separated fields
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    try testing.expect(trimmed.len > 0);
    // Should start with the path
    try testing.expect(std.mem.startsWith(u8, trimmed, test_path));
}

test "stat empty file shows regular empty file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "empty.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "empty.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDir(testing.io, "subdir", std.Io.File.Permissions.fromMode(0o755));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "subdir", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try test_file.writeStreamingAll(testing.io, "content");
    test_file.close(testing.io);

    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path_len = try tmp_dir.dir().realPathFile(testing.io, "link.txt", &path_buf);
    const link_path = path_buf[0..link_path_len];

    // Without -L: should show "symbolic link"
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Note: realpath resolves symlinks, so we need to construct the path manually
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try test_file.writeStreamingAll(testing.io, "content");
    test_file.close(testing.io);

    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file1 = try tmp_dir.dir().createFile(testing.io, "a.txt", .{});
    try file1.writeStreamingAll(testing.io, "aaa");
    file1.close(testing.io);

    const file2 = try tmp_dir.dir().createFile(testing.io, "b.txt", .{});
    try file2.writeStreamingAll(testing.io, "bbbbb");
    file2.close(testing.io);

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    const path1_len = try tmp_dir.dir().realPathFile(testing.io, "a.txt", &path_buf1);
    const path1 = path_buf1[0..path1_len];
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2_len = try tmp_dir.dir().realPathFile(testing.io, "b.txt", &path_buf2);
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

test "stat -f file system info" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Should contain file system info
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "File:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Block") != null);
}

test "stat -c format: hard links" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "exists.txt", .{});
    try test_file.writeStreamingAll(testing.io, "data");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "exists.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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

    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a subdirectory with a file inside
    try tmp_dir.dir().createDir(testing.io, "noaccess", std.Io.File.Permissions.fromMode(0o755));
    const inner_file = try tmp_dir.dir().createFile(testing.io, "noaccess/secret.txt", .{});
    inner_file.close(testing.io);

    // Get the full path to the file inside
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
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

// F15: Default output must not show spurious '+' before numeric fields.
// The {d: <N} format on signed i64 produces a leading '+' sign, e.g.
// "Size: +4096" instead of "Size: 4096".
test "stat default output has no spurious plus on numeric fields" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

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

    // Find the "Size:" line and verify no '+' before the number
    const size_pos = std.mem.find(u8, output, "Size:") orelse
        return error.TestExpectedEqual;
    // Extract from "Size:" to end of that line
    const rest = output[size_pos..];
    const eol = std.mem.find(u8, rest, "\n") orelse rest.len;
    const size_line = rest[0..eol];

    // GNU stat outputs "  Size: 5         Blocks: 8          IO Block: 4096   regular file"
    // Our implementation incorrectly outputs
    // "  Size: +5        Blocks: +8         IO Block: +4096  regular file"
    // The '+' character should not appear anywhere on this line
    try testing.expect(std.mem.find(u8, size_line, "+") == null);
}

// F17: stat -f -c FORMAT should use the format string, not print
// the default filesystem block output. Currently the -f branch
// continues before checking opts.format.
test "stat -f -c format string is honored" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "-c", "%n", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    // -f -c '%n' should output just the file name, not the full filesystem block
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// F18: Terse output should have 16 space-separated fields matching GNU stat.
// GNU format: name size blocks mode uid gid dev inode nlinks major minor
//             atime mtime ctime btime blksize
// Our implementation outputs only 14 fields (missing major/minor device type,
// and has duplicate blocks instead of btime).
test "stat -t terse output has 16 fields like GNU" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-t", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    // Count space-separated fields
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
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

    // GNU stat -t outputs exactly 16 fields
    try testing.expectEqual(@as(usize, 16), field_count);
}

// F16: On Linux, stat -f uses a macOS StatFs struct with wrong field
// offsets, producing garbage values. Verify that -f output contains
// sane values (e.g., block size is a reasonable power of 2).
test "stat -f produces sane block size on this platform" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();

    // Find "Block size:" line and extract the number
    const block_pos = std.mem.find(u8, output, "Block size:") orelse
        return error.TestExpectedEqual;
    const after_label = output[block_pos + "Block size:".len ..];
    // Skip leading spaces
    var start: usize = 0;
    while (start < after_label.len and after_label[start] == ' ') : (start += 1) {}
    // Read digits
    var end: usize = start;
    while (end < after_label.len and
        after_label[end] >= '0' and
        after_label[end] <= '9') : (end += 1)
    {}
    const block_size_str = after_label[start..end];
    const block_size = std.fmt.parseInt(u64, block_size_str, 10) catch
        return error.TestExpectedEqual;

    // Block size should be a reasonable value: between 512 and 1048576 (1MB)
    // On Linux with the macOS struct, this produces garbage like 16914836
    try testing.expect(block_size >= 512);
    try testing.expect(block_size <= 1048576);
}

// Audit: Device line uses BSD format "1fh/31d" instead of GNU "major,minor"
// decimal. GNU stat outputs "Device: 0,31" (decimal major,minor with no
// letter suffixes). Our implementation outputs "Device: 1fh/31d".
test "stat default output Device line uses GNU major,minor format" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

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

    // Find the Device line
    const dev_pos = std.mem.find(u8, stdout_aw.writer.buffered(), "Device:") orelse
        return error.TestExpectedEqual;
    const rest = stdout_aw.writer.buffered()[dev_pos..];
    const eol = std.mem.find(u8, rest, "\n") orelse rest.len;
    const dev_line = rest[0..eol];

    // GNU format: "Device: <dec>,<dec>" — no 'h' or 'd' suffix
    // BSD format: "Device: <hex>h/<dec>d" — has letter suffixes
    // Must NOT contain the BSD letter suffixes
    try testing.expect(std.mem.find(u8, dev_line, "h/") == null);
    try testing.expect(std.mem.find(u8, dev_line, "d\t") == null);
}

// Audit: %b (blocks allocated) has no unit test.
test "stat -c format: blocks allocated %b" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try test_file.writeStreamingAll(testing.io, "content");
    test_file.close(testing.io);

    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
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

// GNU quotearg shell_escape_quoting_style rules for %N, pinned against
// GNU coreutils 9.5:
//   1. no single quote in name          -> single-quoted, verbatim.
//   2. single quote, and none of " \ $ ` -> double-quoted, verbatim.
//   3. single quote, and any of  " \ $ ` -> single-quoted with each `'`
//      spliced as `'\''` (close, escaped quote, reopen).
// Issue #105: vibeutils always emits rule 1's single quotes, which is
// wrong (and unsafe to paste into a shell) whenever the name itself
// contains a single quote.
//
// Rule 4 (out of scope for this fix): GNU additionally ANSI-C-splices
// non-printable bytes, e.g. a literal newline in the name becomes
// 'nl'$'\n''name'. vibeutils currently has no non-printable handling
// at all -- a raw non-printable byte is emitted verbatim inside
// whichever quote style rules 1-3 select. Matching GNU's splicing is
// a separate, larger feature (needs a byte-printability table plus
// $'...' splice-joining) and is not attempted here.

test "stat -c format: %N rule 2 lone apostrophe uses double quotes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's", &path_buf);
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
    // GNU: stat -c %N "it's"  =>  "it's"  (double quotes, no escaping)
    // Assumes the tmpDir path prefix itself contains none of ' " \ $ ` --
    // true for Zig's testing.tmpDir and a normal checkout path; if it
    // ever did, rule 3 would apply instead and this expectation would
    // need to flip to the splice form.
    const expected = try std.fmt.allocPrint(testing.allocator, "\"{s}\"\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 2 apostrophe with space uses double quotes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's space", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's space", &path_buf);
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
    // GNU: stat -c %N "it's space"  =>  "it's space"
    // Same tmpDir-prefix assumption as the previous rule 2 test: the
    // prefix has none of ' " \ $ `, so it never forces rule 3 here.
    const expected = try std.fmt.allocPrint(testing.allocator, "\"{s}\"\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 3 apostrophe with dollar splices single quotes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's and $var", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's and $var", &path_buf);
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
    // GNU: stat -c %N "it's and $var"  =>  'it'\''s and $var'
    // The path's directory prefix has no apostrophe, so only the
    // basename's "it's" splices; build the expected string by hand from
    // the known directory prefix instead of assuming where "'" falls.
    const dir_path = std.fs.path.dirname(test_path).?;
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}/it'\\''s and $var'\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 3 apostrophe with double quote splices single quotes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's\"dq", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's\"dq", &path_buf);
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
    // GNU: stat -c %N "it's\"dq"  =>  'it'\''s"dq'
    const dir_path = std.fs.path.dirname(test_path).?;
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}/it'\\''s\"dq'\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 3 apostrophe with backslash splices single quotes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's\\slash", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's\\slash", &path_buf);
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
    // GNU: stat -c %N "it's\slash"  =>  'it'\''s\slash'
    const dir_path = std.fs.path.dirname(test_path).?;
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}/it'\\''s\\slash'\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 3 apostrophe with backtick splices single quotes" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's `tick`", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's `tick`", &path_buf);
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
    // GNU: stat -c %N "it's \`tick\`"  =>  'it'\''s `tick`'
    const dir_path = std.fs.path.dirname(test_path).?;
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}/it'\\''s `tick`'\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 1 lone double quote stays single-quoted" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "dq\"name", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "dq\"name", &path_buf);
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
    // GNU: a bare double quote (no apostrophe) does NOT switch quote style.
    const expected = try std.fmt.allocPrint(testing.allocator, "'{s}'\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N rule 1 embedded space stays single-quoted" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "with space", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "with space", &path_buf);
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

// Characterization test for rule 4, which we deliberately do NOT implement.
// GNU 9.5 ANSI-C-splices non-printable bytes, so a name "nl\nname" prints as
// 'nl'$'\n''name'. vibeutils has no printability handling: rules 1-3 pick the
// quote style and every byte passes through verbatim. This pins that current
// behavior so a later, deliberate rule 4 feature has to update it, and so a
// half-implementation cannot land silently.
test "stat -c format: %N non-printable byte passes through verbatim (no ANSI-C splicing)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "nl\nname", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "nl\nname", &path_buf);
    const test_path = path_buf[0..test_path_len];
    // The fixture is only meaningful if the raw newline survived into the path.
    try testing.expect(std.mem.findScalar(u8, test_path, '\n') != null);
    try testing.expect(std.mem.findScalar(u8, test_path, '\'') == null);

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
    // Rule 1 selects single quotes (no apostrophe in the name) and the raw LF
    // is emitted as-is; GNU would print 'nl'$'\n''name' instead.
    const expected = try std.fmt.allocPrint(testing.allocator, "'{s}'\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N symlink quotes link name and target independently (rule 2 on target)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const target_file = try tmp_dir.dir().createFile(testing.io, "it's", .{});
    target_file.close(testing.io);

    try tmp_dir.dir().symLink(testing.io, "it's", "lnk2", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/lnk2", .{dir_path});
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
    // GNU: 'lnk2' -> "it's" -- link name (no apostrophe) is single-quoted
    // per rule 1; the target ("it's") is double-quoted per rule 2,
    // chosen independently of the link name's own quoting.
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}' -> \"it's\"\n",
        .{symlink_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N symlink quotes target independently (rule 3 splice on target)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const target_file = try tmp_dir.dir().createFile(testing.io, "it's and $var", .{});
    target_file.close(testing.io);

    try tmp_dir.dir().symLink(testing.io, "it's and $var", "lnk3", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/lnk3", .{dir_path});
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
    // GNU: 'lnk3' -> 'it'\''s and $var'
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "'{s}' -> 'it'\\''s and $var'\n",
        .{symlink_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N symlink quotes link name independently (rule 2 on link name)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const target_file = try tmp_dir.dir().createFile(testing.io, "plain", .{});
    target_file.close(testing.io);

    try tmp_dir.dir().symLink(testing.io, "plain", "it's_link", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const symlink_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/it's_link",
        .{dir_path},
    );
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
    // GNU: "<dir>/it's_link" -> 'plain' -- the link name itself
    // contains an apostrophe and nothing else from " \ $ `, so rule 2
    // (double quotes) applies to the link-name side of the arrow,
    // chosen independently of the target's rule-1 single quotes. This
    // guards against a partial fix that only routes the target operand
    // through the new quoting logic and leaves the link name hardcoded
    // to single quotes.
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "\"{s}\" -> 'plain'\n",
        .{symlink_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat -c format: %N embedded in a longer format string quotes identically" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-c", "name=%N size=%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // GNU: stat -c "name=%N size=%s" "it's"  =>  name="it's" size=0
    // Same tmpDir-prefix assumption as the rule 2 tests above.
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "name=\"{s}\" size=0\n",
        .{test_path},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "stat default record File: line stays unquoted for names needing %N quoting" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "it's", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "it's", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // No -c: the default multi-line record. GNU never quotes the
    // "  File: " line, even when %N would need quotes for this name.
    const args = [_][]const u8{test_path};
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const first_line_end = std.mem.indexOfScalar(u8, stdout_aw.writer.buffered(), '\n').?;
    const first_line = stdout_aw.writer.buffered()[0..first_line_end];
    const expected_first_line = try std.fmt.allocPrint(
        testing.allocator,
        "  File: {s}",
        .{test_path},
    );
    defer testing.allocator.free(expected_first_line);
    try testing.expectEqualStrings(expected_first_line, first_line);
}

// Audit: %x, %y, %z (human-readable timestamps) have no unit tests.
// Verify %y output is a human-readable timestamp, not an epoch number.
// GNU format: "YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ"
test "stat -c format: %y mtime human-readable timestamp" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
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
// BSD -n (no trailing newline) and -q (quiet) flags — issue #93
//
// FreeBSD usr.bin/stat/stat.c terminates each file's output record with a
// newline unless -n is given: `if (!nl && !nonl) fputc('\n', stdout)`. The
// suppression applies to the RECORD terminator only; newlines interior to a
// multi-line record are untouched. -q suppresses the per-file `warn()`
// diagnostic on a failed stat but still sets `errs`, so the exit status
// stays non-zero.
// ============================================================================

test "stat -n suppresses trailing newline with -c format" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-c", "%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    // -n must be an accepted flag, not a parse error.
    try testing.expectEqual(@as(u8, 0), result);
    // Without -n this is "5\n"; -n drops the record terminator.
    try testing.expectEqualStrings("5", stdout_aw.writer.buffered());
}

test "stat -n suppresses final newline of default output but keeps interior ones" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello world");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    // The record terminator is gone.
    try testing.expect(out[out.len - 1] != '\n');
    // Interior newlines of the multi-line record survive: the default format
    // is 8 lines, so at least 7 newlines remain after dropping the last.
    try testing.expect(std.mem.count(u8, out, "\n") >= 7);
    try testing.expect(std.mem.find(u8, out, "File:") != null);
    try testing.expect(std.mem.find(u8, out, "Modify:") != null);
}

test "stat -n suppresses trailing newline with -t terse output" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-t", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, test_path));
    // Terse output is a single record, so -n leaves no newline at all.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\n"));
}

test "stat -n suppresses trailing newline with -f file system output" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-f", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(out[out.len - 1] != '\n');
    // Interior newlines of the multi-line statfs record are preserved.
    try testing.expect(std.mem.count(u8, out, "\n") >= 4);
    try testing.expect(std.mem.find(u8, out, "Block size:") != null);
}

test "stat -n leaves --printf output unchanged" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // --printf already emits no mandatory record terminator, so -n is a no-op.
    const args = [_][]const u8{ "-n", "--printf=%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5", stdout_aw.writer.buffered());
}

test "stat -n drops the record terminator for every operand" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file1 = try tmp_dir.dir().createFile(testing.io, "a.txt", .{});
    try file1.writeStreamingAll(testing.io, "aaa");
    file1.close(testing.io);

    const file2 = try tmp_dir.dir().createFile(testing.io, "b.txt", .{});
    try file2.writeStreamingAll(testing.io, "bbbbb");
    file2.close(testing.io);

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    const path1_len = try tmp_dir.dir().realPathFile(testing.io, "a.txt", &path_buf1);
    const path1 = path_buf1[0..path1_len];
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2_len = try tmp_dir.dir().realPathFile(testing.io, "b.txt", &path_buf2);
    const path2 = path_buf2[0..path2_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", "-c", "%s", path1, path2 };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Without -n this is "3\n5\n"; every record loses its terminator, so the
    // records run together with no separator at all.
    try testing.expectEqualStrings("35", stdout_aw.writer.buffered());
}

test "stat -q suppresses cannot-stat diagnostic but keeps exit status 1" {
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

    // FreeBSD suppresses the warn() but still sets errs, so status is 1.
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "stat -q suppresses cannot-statfs diagnostic but keeps exit status 1" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-q", "-f", "/nonexistent/file/path" };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "stat -q does not suppress argument parsing errors" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -c with no value is a usage error; -q must not silence it.
    const missing_value_args = [_][]const u8{ "-q", "-c" };
    const missing_value_result = try runStat(
        testing.allocator,
        testing.io,
        &missing_value_args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), missing_value_result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "requires an argument") != null,
    );

    var unknown_stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer unknown_stdout_aw.deinit();
    var unknown_stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer unknown_stderr_aw.deinit();

    const unknown_args = [_][]const u8{ "-q", "--invalid" };
    const unknown_result = try runStat(
        testing.allocator,
        testing.io,
        &unknown_args,
        &unknown_stdout_aw.writer,
        &unknown_stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), unknown_result);
    try testing.expect(
        std.mem.find(u8, unknown_stderr_aw.writer.buffered(), "unrecognized option") != null,
    );
}

test "stat -q does not change a successful stat" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-q", "-c", "%s", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

// Regression pin for issue #79: `stat -f '%m' FILE` must NOT silently treat
// the format string as a format. -f takes no format argument, so '%m' is a
// file operand; statfs on it fails, which must produce a diagnostic naming
// '%m' and a non-zero exit, while FILE still gets its file-system status.
test "stat -f with a stray format operand still fails and reports it (issue 79)" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const test_file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir().realPathFile(testing.io, "test.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "%m", test_path };
    const result = try runStat(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "%m") != null);
    // The real operand still gets its file-system status printed.
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Block size:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), test_path) != null);
}

// ============================================================================
// TESTS: BSD display modes (-r, -s, -l, -F, -x)
// ============================================================================
//
// These pin the five FreeBSD fixed-format renderers, their mutual-exclusion
// rules, and the GNU-parity device number every one of them depends on.
// Expected values come from the kernel through statx -- which reports the
// device as a separate major/minor pair, so a test can check our encoding
// without reusing the encoder under test -- or from std's own stat.

/// Test-only: libc's fifo maker, used to exercise the `-F` "|" type suffix.
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// Test-only: run stat over `args`, capturing stdout and discarding stderr.
fn testStatOut(args: []const []const u8, out: *std.Io.Writer.Allocating) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(out.writer.buffered().len == 0);
    return runStat(testing.allocator, testing.io, args, &out.writer, common.null_writer);
}

/// Test-only: run stat over `args`, capturing both streams.
fn testStatBoth(
    args: []const []const u8,
    out: *std.Io.Writer.Allocating,
    err: *std.Io.Writer.Allocating,
) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(err.writer.buffered().len == 0);
    return runStat(testing.allocator, testing.io, args, &out.writer, &err.writer);
}

/// Test-only: absolute path of `name` inside `dir`. Caller frees the result.
fn testAbsPath(dir: std.Io.Dir, name: []const u8) ![]u8 {
    std.debug.assert(name.len > 0);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPathFile(testing.io, ".", &buf);
    std.debug.assert(len > 0);
    std.debug.assert(len <= buf.len);
    return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ buf[0..len], name });
}

/// Test-only: split `line` on runs of spaces into `dest`, returning the count.
fn testSplit(line: []const u8, dest: [][]const u8) u32 {
    std.debug.assert(dest.len > 0);
    std.debug.assert(dest.len < 64);
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    var n: u32 = 0;
    while (it.next()) |tok| {
        if (n >= dest.len) break;
        std.debug.assert(tok.len > 0);
        dest[n] = tok;
        n += 1;
    }
    return n;
}

/// Test-only: the `index`th line of `text`, or an empty slice when absent.
fn testLine(text: []const u8, index: u32) []const u8 {
    std.debug.assert(index < 64);
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (it.next()) |line| : (n += 1) {
        std.debug.assert(n < 64);
        if (n == index) return line;
    }
    return "";
}

/// Test-only: full st_mode (type bits included) as std reports it, so an
/// expectation never borrows the stat path it is meant to verify.
fn testMode(dir: std.Io.Dir, name: []const u8, follow: bool) !u32 {
    std.debug.assert(name.len > 0);
    const st = try dir.statFile(testing.io, name, .{ .follow_symlinks = follow });
    const type_bits: u32 = switch (st.kind) {
        .file => 0o100000,
        .directory => 0o040000,
        .sym_link => 0o120000,
        .named_pipe => 0o010000,
        else => 0,
    };
    std.debug.assert(type_bits != 0);
    const perm: u32 = @intCast(st.permissions.toMode() & 0o7777);
    return type_bits | perm;
}

/// Test-only: do these four tokens spell the default "%b %e %T %Y" stamp?
fn testIsLsTime(mon: []const u8, day: []const u8, tod: []const u8, year: []const u8) bool {
    std.debug.assert(mon.len > 0);
    std.debug.assert(year.len > 0);
    if (mon.len != 3 or !std.ascii.isUpper(mon[0])) return false;
    if (day.len < 1 or day.len > 2) return false;
    for (day) |ch| if (!std.ascii.isDigit(ch)) return false;
    if (tod.len != 8 or tod[2] != ':' or tod[5] != ':') return false;
    if (year.len != 4) return false;
    for (year) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Test-only: kernel ground truth for one path, gathered through an interface
/// that keeps the device major and minor apart.
const TestTruth = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,
    mode: u32,
    nlink: u64,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: u64,
    blksize: u32,
    blocks: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
    btime: i64,
};

/// Test-only: read `path`'s ground truth. Only Linux exposes an interface that
/// reports the device major and minor separately, so elsewhere callers skip.
fn testTruth(path: []const u8, follow: bool) !TestTruth {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= std.fs.max_path_bytes);
    if (builtin.os.tag == .linux) {
        return testTruth_linux(path, follow);
    } else {
        return error.SkipZigTest;
    }
}

/// Linux half of `testTruth`; statx is the kernel's own report of the file.
fn testTruth_linux(path: []const u8, follow: bool) !TestTruth {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= std.fs.max_path_bytes);
    const linux = std.os.linux;
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var stx: linux.Statx = undefined;
    const mask: linux.STATX = @bitCast(@as(u32, 0xfff));
    const at_flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(c.AT.FDCWD, buf[0..path.len :0], at_flags, mask, &stx);
    if (linux.errno(rc) != .SUCCESS) return error.TestTruthUnavailable;

    return .{
        .dev_major = stx.dev_major,
        .dev_minor = stx.dev_minor,
        .ino = stx.ino,
        .mode = stx.mode,
        .nlink = stx.nlink,
        .uid = stx.uid,
        .gid = stx.gid,
        .rdev = (@as(u64, stx.rdev_major) << 32) | stx.rdev_minor,
        .size = stx.size,
        .blksize = stx.blksize,
        .blocks = stx.blocks,
        .atime = stx.atime.sec,
        .mtime = stx.mtime.sec,
        .ctime = stx.ctime.sec,
        .btime = stx.btime.sec,
    };
}

// ---------------------------------------------------------------------------
// st_dev must match GNU. doStat_linux composes a synthetic
// ((major << 32) | minor) device id, so %d prints 1090921693184 where GNU
// prints 65024 and the default Device: line prints 0,0 where GNU prints 254,0.
// Both -r and -s print st_dev, so the modes below inherit the bug.
// ---------------------------------------------------------------------------

test "stat -c %d device number has GNU's dev_t width" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "d.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "d.txt");
    defer testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-c", "%d %D", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    var fields: [4][]const u8 = undefined;
    const n = testSplit(std.mem.trimEnd(u8, out.writer.buffered(), "\n"), &fields);
    try testing.expectEqual(@as(u32, 2), n);

    // A real dev_t fits in 32 bits on both platforms we target; the synthetic
    // composition needs 40, which is exactly how the bug shows up.
    const dev = try std.fmt.parseInt(u64, fields[0], 10);
    try testing.expect(dev < @as(u64, 1) << 32);

    // %D must be the same number, just in hex.
    var hex_buf: [32]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{x}", .{dev});
    try testing.expectEqualStrings(hex, fields[1]);
}

test "stat default Device line matches the kernel major,minor" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "d.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "d.txt");
    defer testing.allocator.free(path);

    const truth = try testTruth(path, true);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{path};
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\t",
        .{ truth.dev_major, truth.dev_minor },
    );
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.find(u8, out.writer.buffered(), expected) != null);
}

// ---------------------------------------------------------------------------
// -r RAW_FORMAT: "%d %i %#p %l %u %g %r %z %a %m %c %B %k %b %f %N"
// ---------------------------------------------------------------------------

test "stat -r renders sixteen raw fields ending in the file name" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "raw.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "raw.txt");
    defer testing.allocator.free(path);
    const mode = try testMode(tmp_dir.dir(), "raw.txt", false);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-r", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    // The record terminator is the trailing newline, and there is only one.
    try testing.expect(std.mem.endsWith(u8, out.writer.buffered(), "\n"));
    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    try testing.expect(std.mem.find(u8, line, "\n") == null);

    var fields: [20][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 16), testSplit(line, &fields));

    const expected_mode = try std.fmt.allocPrint(testing.allocator, "0{o}", .{mode});
    defer testing.allocator.free(expected_mode);
    try testing.expectEqualStrings(expected_mode, fields[2]);
    try testing.expectEqualStrings("1", fields[3]);
    try testing.expectEqualStrings("6", fields[7]);
    try testing.expectEqualStrings("0", fields[14]);
    try testing.expectEqualStrings(path, fields[15]);
}

test "stat -r raw fields match the kernel's own numbers" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "raw.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "raw.txt");
    defer testing.allocator.free(path);

    const truth = try testTruth(path, false);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-r", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    var fields: [20][]const u8 = undefined;
    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    try testing.expectEqual(@as(u32, 16), testSplit(line, &fields));

    // %d must be the encoded device, not the major/minor pair spliced together.
    const dev = try std.fmt.parseInt(u64, fields[0], 10);
    try testing.expect(dev < @as(u64, 1) << 32);
    try testing.expectEqual(truth.ino, try std.fmt.parseInt(u64, fields[1], 10));
    try testing.expectEqual(truth.nlink, try std.fmt.parseInt(u64, fields[3], 10));
    try testing.expectEqual(truth.uid, try std.fmt.parseInt(u32, fields[4], 10));
    try testing.expectEqual(truth.gid, try std.fmt.parseInt(u32, fields[5], 10));
    try testing.expectEqual(@as(u64, 0), try std.fmt.parseInt(u64, fields[6], 10));
    try testing.expectEqual(truth.size, try std.fmt.parseInt(u64, fields[7], 10));
    try testing.expectEqual(truth.atime, try std.fmt.parseInt(i64, fields[8], 10));
    try testing.expectEqual(truth.mtime, try std.fmt.parseInt(i64, fields[9], 10));
    try testing.expectEqual(truth.ctime, try std.fmt.parseInt(i64, fields[10], 10));
    try testing.expectEqual(truth.btime, try std.fmt.parseInt(i64, fields[11], 10));
    try testing.expectEqual(truth.blksize, try std.fmt.parseInt(u32, fields[12], 10));
    try testing.expectEqual(truth.blocks, try std.fmt.parseInt(u64, fields[13], 10));
}

test "stat -r on a directory reports the directory mode" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDir(testing.io, "sub", .default_dir);
    const path = try testAbsPath(tmp_dir.dir(), "sub");
    defer testing.allocator.free(path);
    const mode = try testMode(tmp_dir.dir(), "sub", false);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-r", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    var fields: [20][]const u8 = undefined;
    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    try testing.expectEqual(@as(u32, 16), testSplit(line, &fields));

    const expected_mode = try std.fmt.allocPrint(testing.allocator, "0{o}", .{mode});
    defer testing.allocator.free(expected_mode);
    try testing.expectEqualStrings(expected_mode, fields[2]);
    try testing.expectEqualStrings(path, fields[15]);
}

test "stat -r reports the symlink itself, and -L the target" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});
    const path = try testAbsPath(tmp_dir.dir(), "link.txt");
    defer testing.allocator.free(path);

    var link_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer link_out.deinit();
    const link_args = [_][]const u8{ "-r", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&link_args, &link_out));

    var link_fields: [20][]const u8 = undefined;
    const link_line = std.mem.trimEnd(u8, link_out.writer.buffered(), "\n");
    try testing.expectEqual(@as(u32, 16), testSplit(link_line, &link_fields));
    // S_IFLNK is 0120000, so the "%#p" octal starts with the link type bits.
    try testing.expect(std.mem.startsWith(u8, link_fields[2], "0120"));
    try testing.expectEqualStrings("10", link_fields[7]);

    var deref_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer deref_out.deinit();
    const deref_args = [_][]const u8{ "-L", "-r", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&deref_args, &deref_out));

    var deref_fields: [20][]const u8 = undefined;
    const deref_line = std.mem.trimEnd(u8, deref_out.writer.buffered(), "\n");
    try testing.expectEqual(@as(u32, 16), testSplit(deref_line, &deref_fields));
    try testing.expect(std.mem.startsWith(u8, deref_fields[2], "0100"));
    try testing.expectEqualStrings("6", deref_fields[7]);
    // The name field always echoes the operand, dereferenced or not.
    try testing.expectEqualStrings(path, deref_fields[15]);
}

// ---------------------------------------------------------------------------
// -s SHELL_FORMAT: fifteen "name=value" assignments, no file name field.
// ---------------------------------------------------------------------------

test "stat -s renders the fifteen shell assignments in order" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "sh.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "sh.txt");
    defer testing.allocator.free(path);
    const mode = try testMode(tmp_dir.dir(), "sh.txt", false);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-s", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    var fields: [20][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 15), testSplit(line, &fields));

    const names = [_][]const u8{
        "st_dev",   "st_ino",       "st_mode",    "st_nlink",  "st_uid",
        "st_gid",   "st_rdev",      "st_size",    "st_atime",  "st_mtime",
        "st_ctime", "st_birthtime", "st_blksize", "st_blocks", "st_flags",
    };
    for (names, 0..) |name, idx| {
        const prefix = try std.fmt.allocPrint(testing.allocator, "{s}=", .{name});
        defer testing.allocator.free(prefix);
        try testing.expect(std.mem.startsWith(u8, fields[idx], prefix));
    }

    const expected_mode = try std.fmt.allocPrint(testing.allocator, "st_mode=0{o}", .{mode});
    defer testing.allocator.free(expected_mode);
    try testing.expectEqualStrings(expected_mode, fields[2]);
    try testing.expectEqualStrings("st_nlink=1", fields[3]);
    try testing.expectEqualStrings("st_size=6", fields[7]);
    try testing.expectEqualStrings("st_flags=0", fields[14]);
    // SHELL_FORMAT carries no file name field at all.
    try testing.expect(std.mem.find(u8, line, path) == null);
}

test "stat -s values match the kernel's own numbers" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "sh.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "sh.txt");
    defer testing.allocator.free(path);

    const truth = try testTruth(path, false);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-s", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    var fields: [20][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 15), testSplit(line, &fields));

    // st_dev is the encoded device id, so it stays inside 32 bits.
    const dev_text = fields[0]["st_dev=".len..];
    try testing.expect(try std.fmt.parseInt(u64, dev_text, 10) < @as(u64, 1) << 32);

    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "st_ino={d} st_mode=0{o} st_nlink={d} st_uid={d} st_gid={d} " ++
            "st_rdev=0 st_size={d} st_atime={d} st_mtime={d}",
        .{
            truth.ino,  truth.mode,  truth.nlink, truth.uid, truth.gid,
            truth.size, truth.atime, truth.mtime,
        },
    );
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.find(u8, line, expected) != null);

    const tail = try std.fmt.allocPrint(
        testing.allocator,
        "st_ctime={d} st_birthtime={d} st_blksize={d} st_blocks={d} st_flags=0",
        .{ truth.ctime, truth.btime, truth.blksize, truth.blocks },
    );
    defer testing.allocator.free(tail);
    try testing.expect(std.mem.find(u8, line, tail) != null);
}

test "stat -s -L on a symlink reports the target size" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});
    const path = try testAbsPath(tmp_dir.dir(), "link.txt");
    defer testing.allocator.free(path);

    var link_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer link_out.deinit();
    const link_args = [_][]const u8{ "-s", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&link_args, &link_out));
    try testing.expect(std.mem.find(u8, link_out.writer.buffered(), "st_size=10 ") != null);

    var deref_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer deref_out.deinit();
    const deref_args = [_][]const u8{ "-L", "-s", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&deref_args, &deref_out));
    try testing.expect(std.mem.find(u8, deref_out.writer.buffered(), "st_size=6 ") != null);
}

// ---------------------------------------------------------------------------
// -l LS_FORMAT: "%Sp %l %Su %Sg %Z %Sm %N%SY"
// ---------------------------------------------------------------------------

test "stat -l renders the ls-style line for a regular file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "ls.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "ls.txt");
    defer testing.allocator.free(path);

    const mode = try testMode(tmp_dir.dir(), "ls.txt", false);
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-l", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    var fields: [16][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 10), testSplit(line, &fields));

    try testing.expectEqualStrings(perms, fields[0]);
    try testing.expectEqualStrings("1", fields[1]);
    try testing.expect(fields[2].len > 0);
    try testing.expect(fields[3].len > 0);
    // %Z renders st_size for anything that is not a device node.
    try testing.expectEqualStrings("6", fields[4]);
    try testing.expect(testIsLsTime(fields[5], fields[6], fields[7], fields[8]));
    try testing.expectEqualStrings(path, fields[9]);
    // %SY is empty for a non-symlink, so no arrow appears.
    try testing.expect(std.mem.find(u8, line, " -> ") == null);
}

test "stat -l on a directory shows the directory permissions" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDir(testing.io, "sub", .default_dir);
    const path = try testAbsPath(tmp_dir.dir(), "sub");
    defer testing.allocator.free(path);

    const mode = try testMode(tmp_dir.dir(), "sub", false);
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-l", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const line = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    var fields: [16][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 10), testSplit(line, &fields));
    try testing.expectEqualStrings(perms, fields[0]);
    try testing.expectEqual(@as(u8, 'd'), fields[0][0]);
    try testing.expectEqualStrings(path, fields[9]);
}

test "stat -l appends the arrow for a symlink and -L drops it" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});
    const path = try testAbsPath(tmp_dir.dir(), "link.txt");
    defer testing.allocator.free(path);

    var link_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer link_out.deinit();
    const link_args = [_][]const u8{ "-l", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&link_args, &link_out));

    const link_line = std.mem.trimEnd(u8, link_out.writer.buffered(), "\n");
    var link_fields: [16][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 12), testSplit(link_line, &link_fields));
    try testing.expectEqual(@as(u8, 'l'), link_fields[0][0]);
    try testing.expectEqualStrings(path, link_fields[9]);
    try testing.expectEqualStrings("->", link_fields[10]);
    try testing.expectEqualStrings("target.txt", link_fields[11]);

    var deref_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer deref_out.deinit();
    const deref_args = [_][]const u8{ "-L", "-l", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&deref_args, &deref_out));

    const deref_line = std.mem.trimEnd(u8, deref_out.writer.buffered(), "\n");
    var deref_fields: [16][]const u8 = undefined;
    try testing.expectEqual(@as(u32, 10), testSplit(deref_line, &deref_fields));
    try testing.expectEqual(@as(u8, '-'), deref_fields[0][0]);
    try testing.expectEqualStrings("6", deref_fields[4]);
    try testing.expect(std.mem.find(u8, deref_line, " -> ") == null);
}

// ---------------------------------------------------------------------------
// -F LSF_FORMAT: "%Sp %l %Su %Sg %Z %Sm %N%T%SY"
// ---------------------------------------------------------------------------

test "stat -F on a plain file renders exactly the -l line" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "plain.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "plain.txt");
    defer testing.allocator.free(path);

    var ls_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer ls_out.deinit();
    const ls_args = [_][]const u8{ "-l", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&ls_args, &ls_out));

    var lsf_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lsf_out.deinit();
    const lsf_args = [_][]const u8{ "-F", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&lsf_args, &lsf_out));

    // %T is empty for a regular file without an execute bit.
    try testing.expectEqualStrings(ls_out.writer.buffered(), lsf_out.writer.buffered());
    try testing.expect(std.mem.endsWith(u8, lsf_out.writer.buffered(), "\n"));
}

test "stat -F marks an executable file with an asterisk" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(
        testing.io,
        "run.sh",
        .{ .permissions = .executable_file },
    );
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "run.sh");
    defer testing.allocator.free(path);

    // Guard the premise: an umask that stripped every execute bit would make
    // the assertion below vacuous.
    const mode = try testMode(tmp_dir.dir(), "run.sh", false);
    try testing.expect(mode & 0o111 != 0);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-F", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const expected = try std.fmt.allocPrint(testing.allocator, " {s}*\n", .{path});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.endsWith(u8, out.writer.buffered(), expected));
}

test "stat -F marks a directory with a slash" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDir(testing.io, "sub", .default_dir);
    const path = try testAbsPath(tmp_dir.dir(), "sub");
    defer testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-F", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const expected = try std.fmt.allocPrint(testing.allocator, " {s}/\n", .{path});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.endsWith(u8, out.writer.buffered(), expected));
}

test "stat -F marks a symlink with an at sign before the arrow" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    file.close(testing.io);
    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});
    const path = try testAbsPath(tmp_dir.dir(), "link.txt");
    defer testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-F", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    // LSF_FORMAT is "%N%T%SY", so the suffix sits between name and arrow.
    const expected = try std.fmt.allocPrint(testing.allocator, " {s}@ -> target.txt\n", .{path});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.endsWith(u8, out.writer.buffered(), expected));
}

test "stat -F marks a fifo with a pipe" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const dir_path = try testAbsPath(tmp_dir.dir(), "pipe");
    defer testing.allocator.free(dir_path);

    const c_path = try testing.allocator.dupeZ(u8, dir_path);
    defer testing.allocator.free(c_path);
    try testing.expectEqual(@as(c_int, 0), mkfifo(c_path.ptr, 0o644));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-F", dir_path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const expected = try std.fmt.allocPrint(testing.allocator, " {s}|\n", .{dir_path});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.endsWith(u8, out.writer.buffered(), expected));
    try testing.expectEqual(@as(u8, 'p'), out.writer.buffered()[0]);
}

test "stat -F -l and -l -F both render the LSF format" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDir(testing.io, "sub", .default_dir);
    const path = try testAbsPath(tmp_dir.dir(), "sub");
    defer testing.allocator.free(path);

    var plain: std.Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    const plain_args = [_][]const u8{ "-F", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&plain_args, &plain));

    var fl: std.Io.Writer.Allocating = .init(testing.allocator);
    defer fl.deinit();
    const fl_args = [_][]const u8{ "-F", "-l", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&fl_args, &fl));

    var lf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lf.deinit();
    const lf_args = [_][]const u8{ "-l", "-F", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&lf_args, &lf));

    try testing.expectEqualStrings(plain.writer.buffered(), fl.writer.buffered());
    try testing.expectEqualStrings(plain.writer.buffered(), lf.writer.buffered());
    try testing.expect(std.mem.endsWith(u8, plain.writer.buffered(), "/\n"));
}

// ---------------------------------------------------------------------------
// -x LINUX_FORMAT: eight labelled lines with literal BSD spacing.
// ---------------------------------------------------------------------------

test "stat -x renders the eight labelled verbose lines" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "vx.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "vx.txt");
    defer testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-x", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const text = out.writer.buffered();
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    const body = std.mem.trimEnd(u8, text, "\n");
    var newlines: u32 = 0;
    for (body) |ch| {
        if (ch == '\n') newlines += 1;
    }
    try testing.expectEqual(@as(u32, 7), newlines);

    const file_line = try std.fmt.allocPrint(testing.allocator, "  File: \"{s}\"", .{path});
    defer testing.allocator.free(file_line);
    try testing.expectEqualStrings(file_line, testLine(body, 0));

    const prefixes = [_][]const u8{ "  Size: ", "  Mode: (", "Device: " };
    for (prefixes, 1..) |prefix, idx| {
        try testing.expect(std.mem.startsWith(u8, testLine(body, @intCast(idx)), prefix));
    }
    const labels = [_][]const u8{ "Access: ", "Modify: ", "Change: ", " Birth: " };
    for (labels, 4..) |label, idx| {
        try testing.expect(std.mem.startsWith(u8, testLine(body, @intCast(idx)), label));
    }
}

test "stat -x uses the literal BSD spacing on the Size, Mode and Device lines" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "vx.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "vx.txt");
    defer testing.allocator.free(path);

    const mode = try testMode(tmp_dir.dir(), "vx.txt", false);
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-x", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));
    const body = std.mem.trimEnd(u8, out.writer.buffered(), "\n");

    // "  Size: %-11z  FileType: %HT" -- 6 padded to 11 plus two literal spaces.
    try testing.expectEqualStrings(
        "  Size: 6            FileType: Regular File",
        testLine(body, 1),
    );

    // "  Mode: (%OMp%03OLp/%.10Sp)         Uid: (%5u/%8Su)  Gid: (%5g/%8Sg)"
    const mode_line = testLine(body, 2);
    const mode_head = try std.fmt.allocPrint(
        testing.allocator,
        "  Mode: ({o}{o:0>3}/{s})         Uid: (",
        .{ (mode >> 9) & 7, mode & 0o777, perms },
    );
    defer testing.allocator.free(mode_head);
    try testing.expect(std.mem.startsWith(u8, mode_line, mode_head));
    try testing.expect(std.mem.find(u8, mode_line, ")  Gid: (") != null);
    try testing.expect(std.mem.endsWith(u8, mode_line, ")"));

    // "Device: %Hd,%Ld   Inode: %i    Links: %l"
    const dev_line = testLine(body, 3);
    try testing.expect(std.mem.find(u8, dev_line, "   Inode: ") != null);
    try testing.expect(std.mem.find(u8, dev_line, "    Links: ") != null);
    try testing.expect(std.mem.endsWith(u8, dev_line, "Links: 1"));
}

test "stat -x Device line carries the kernel major and minor" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "vx.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "vx.txt");
    defer testing.allocator.free(path);

    const truth = try testTruth(path, false);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-x", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));

    const body = std.mem.trimEnd(u8, out.writer.buffered(), "\n");
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}   Inode: {d}    Links: {d}",
        .{ truth.dev_major, truth.dev_minor, truth.ino, truth.nlink },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, testLine(body, 3));
}

test "stat -x names the file type of a directory and a symlink" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDir(testing.io, "sub", .default_dir);
    const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    file.close(testing.io);
    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});

    const dir_path = try testAbsPath(tmp_dir.dir(), "sub");
    defer testing.allocator.free(dir_path);
    const link_path = try testAbsPath(tmp_dir.dir(), "link.txt");
    defer testing.allocator.free(link_path);

    var dir_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dir_out.deinit();
    const dir_args = [_][]const u8{ "-x", dir_path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&dir_args, &dir_out));
    try testing.expect(std.mem.find(u8, dir_out.writer.buffered(), "FileType: Directory") != null);

    var link_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer link_out.deinit();
    const link_args = [_][]const u8{ "-x", link_path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&link_args, &link_out));
    const link_text = link_out.writer.buffered();
    try testing.expect(std.mem.find(u8, link_text, "FileType: Symbolic Link") != null);

    var deref_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer deref_out.deinit();
    const deref_args = [_][]const u8{ "-L", "-x", link_path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&deref_args, &deref_out));
    const deref_text = deref_out.writer.buffered();
    try testing.expect(std.mem.find(u8, deref_text, "FileType: Regular File") != null);
}

/// Test-only: does `s` hold a run of four consecutive digits (a year)?
fn testHasYear(s: []const u8) bool {
    std.debug.assert(s.len < 4096);
    var run: u32 = 0;
    for (s) |ch| {
        run = if (std.ascii.isDigit(ch)) run + 1 else 0;
        if (run >= 4) return true;
    }
    std.debug.assert(run < 4);
    return false;
}

test "stat -x time lines carry a rendered timestamp, not an epoch" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "vx.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "vx.txt");
    defer testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const args = [_][]const u8{ "-x", path };
    try testing.expectEqual(@as(u8, 0), try testStatOut(&args, &out));
    const body = std.mem.trimEnd(u8, out.writer.buffered(), "\n");

    const labels = [_][]const u8{ "Access: ", "Modify: ", "Change: ", " Birth: " };
    for (labels, 4..) |label, idx| {
        const line = testLine(body, @intCast(idx));
        try testing.expect(line.len > label.len);
        const stamp = line[label.len..];
        // No Birth-line exception (issue #102): -x follows the BSD spec, which
        // has no unavailable birth time, so it formats the raw value even when
        // statx reports no STATX_BTIME for this filesystem -- a zeroed field
        // still renders as the epoch date, which is a wall clock, not a dash.
        // strftime "%c" output, so a wall-clock rendering rather than raw
        // seconds: it opens with a weekday name and carries a clock and a year.
        try testing.expect(stamp.len >= 19);
        try testing.expect(std.ascii.isAlphabetic(stamp[0]));
        try testing.expect(std.mem.find(u8, stamp, ":") != null);
        try testing.expect(testHasYear(stamp));
    }
}

// ---------------------------------------------------------------------------
// Mutual exclusion. FreeBSD errors with exit 1 and
// "can't use format '<first>' with '<offender>'".
// ---------------------------------------------------------------------------

test "stat rejects two BSD display modes with exit 1" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "x.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "x.txt");
    defer testing.allocator.free(path);

    const Case = struct { first: []const u8, second: []const u8, msg: []const u8 };
    const cases = [_]Case{
        .{ .first = "-l", .second = "-r", .msg = "can't use format 'l' with 'r'" },
        .{ .first = "-r", .second = "-s", .msg = "can't use format 'r' with 's'" },
        .{ .first = "-s", .second = "-x", .msg = "can't use format 's' with 'x'" },
        .{ .first = "-x", .second = "-l", .msg = "can't use format 'x' with 'l'" },
        .{ .first = "-r", .second = "-r", .msg = "can't use format 'r' with 'r'" },
    };

    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err.deinit();

        const args = [_][]const u8{ case.first, case.second, path };
        const status = try testStatBoth(&args, &out, &err);
        try testing.expectEqual(@as(u8, 1), status);
        try testing.expect(std.mem.find(u8, err.writer.buffered(), case.msg) != null);
        try testing.expectEqual(@as(usize, 0), out.writer.buffered().len);
    }
}

test "stat -F conflicts with every display mode except -l" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "x.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "x.txt");
    defer testing.allocator.free(path);

    const Case = struct { mode: []const u8, msg: []const u8 };
    const cases = [_]Case{
        .{ .mode = "-r", .msg = "can't use format 'r' with -F" },
        .{ .mode = "-s", .msg = "can't use format 's' with -F" },
        .{ .mode = "-x", .msg = "can't use format 'x' with -F" },
    };

    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err.deinit();

        const args = [_][]const u8{ "-F", case.mode, path };
        const status = try testStatBoth(&args, &out, &err);
        try testing.expectEqual(@as(u8, 1), status);
        try testing.expect(std.mem.find(u8, err.writer.buffered(), case.msg) != null);
    }
}

test "stat display modes accept -n, -q and -L without conflict" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
    try file.writeStreamingAll(testing.io, "hello\n");
    file.close(testing.io);
    try tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{});
    const path = try testAbsPath(tmp_dir.dir(), "link.txt");
    defer testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const args = [_][]const u8{ "-l", "-n", "-q", "-L", path };
    try testing.expectEqual(@as(u8, 0), try testStatBoth(&args, &out, &err));
    try testing.expectEqual(@as(usize, 0), err.writer.buffered().len);
    // -n drops the record terminator, so the line has no trailing newline.
    try testing.expect(!std.mem.endsWith(u8, out.writer.buffered(), "\n"));
    try testing.expect(std.mem.endsWith(u8, out.writer.buffered(), path));
}

// ---------------------------------------------------------------------------
// Cross-interface conflicts. Combining a BSD display mode with a GNU output
// selector is undefined by any spec, so vibeutils diagnoses it as a usage
// error (exit 1) rather than silently picking one of the two.
// ---------------------------------------------------------------------------

test "stat rejects a BSD display mode combined with -c or --printf" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "x.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "x.txt");
    defer testing.allocator.free(path);

    var c_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer c_out.deinit();
    var c_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer c_err.deinit();
    const c_args = [_][]const u8{ "-r", "-c", "%s", path };
    try testing.expectEqual(@as(u8, 1), try testStatBoth(&c_args, &c_out, &c_err));
    try testing.expect(
        std.mem.find(u8, c_err.writer.buffered(), "can't use format 'r' with -c") != null,
    );

    var p_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer p_out.deinit();
    var p_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer p_err.deinit();
    const p_args = [_][]const u8{ "-l", "--printf=%s", path };
    try testing.expectEqual(@as(u8, 1), try testStatBoth(&p_args, &p_out, &p_err));
    try testing.expect(
        std.mem.find(u8, p_err.writer.buffered(), "can't use format 'l' with --printf") != null,
    );
}

test "stat rejects a BSD display mode combined with -t or -f" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "x.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "x.txt");
    defer testing.allocator.free(path);

    var t_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer t_out.deinit();
    var t_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer t_err.deinit();
    const t_args = [_][]const u8{ "-s", "-t", path };
    try testing.expectEqual(@as(u8, 1), try testStatBoth(&t_args, &t_out, &t_err));
    try testing.expect(
        std.mem.find(u8, t_err.writer.buffered(), "can't use format 's' with -t") != null,
    );

    var f_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer f_out.deinit();
    var f_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer f_err.deinit();
    const f_args = [_][]const u8{ "-x", "-f", path };
    try testing.expectEqual(@as(u8, 1), try testStatBoth(&f_args, &f_out, &f_err));
    try testing.expect(
        std.mem.find(u8, f_err.writer.buffered(), "can't use format 'x' with -f") != null,
    );
}

// ============================================================================
// TESTS: device major/minor renderers (issue #92)
// ============================================================================
//
// The three renderers below (expandFormatDirective's %t/%T, the default
// Device: line, and -t terse output) each re-derive major/minor with an
// inline mask instead of calling devMajor/devMinor, and the Linux copy of
// that mask drops minor bits above 8. A synthetic StatResult exercises the
// renderers directly -- no real device node is required -- and pins both
// the truncation fix and the still-missing "Device type:" suffix GNU emits
// for character and block special files.

/// Test-only: a synthetic StatResult with the given mode/dev/rdev and every
/// other field at a small, deterministic value, for driving a renderer
/// without a real device node.
fn testSyntheticStat(mode: u32, dev: u64, rdev: u64) StatResult {
    std.debug.assert((mode & c.S.IFMT) != 0);
    std.debug.assert(mode & 0o777 != 0);
    const result = StatResult{
        .dev = dev,
        .ino = 162,
        .mode = mode,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .rdev = rdev,
        .size = 0,
        .blksize = 4096,
        .blocks = 0,
        .atim = .{ .sec = 0, .nsec = 0 },
        .mtim = .{ .sec = 0, .nsec = 0 },
        .ctim = .{ .sec = 0, .nsec = 0 },
        .btim = .{ .sec = 0, .nsec = 0 },
        // Defaults to a valid (mask-set) birth time -- matches the common
        // case of a real file. None of the pre-existing callers of this
        // helper read the birth time, so this default changes none of their
        // output; tests targeting issue #102 override both `.btim` and
        // `.btim_valid` explicitly.
        .btim_valid = true,
    };
    std.debug.assert(result.mode == mode);
    std.debug.assert(result.rdev == rdev);
    return result;
}

test "stat %T renders the full device minor above 255 on Linux (issue 92)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // /dev/binder on the pinned reference VM: major 10 (0xa), minor 260
    // (0x104). GNU renders "a 104"; the buggy `& 0xff` mask renders "a 4".
    const rdev = makeDev(10, 260);
    const stat_buf = testSyntheticStat(c.S.IFCHR | 0o600, 0, rdev);

    var major_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer major_out.deinit();
    try expandFormatDirective(testing.allocator, 't', stat_buf, "ignored", true, &major_out.writer);
    try testing.expectEqualStrings("a", major_out.writer.buffered());

    var minor_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer minor_out.deinit();
    try expandFormatDirective(testing.allocator, 'T', stat_buf, "ignored", true, &minor_out.writer);
    try testing.expectEqualStrings("104", minor_out.writer.buffered());
}

test "stat -t renders the full device minor above 255 on Linux (issue 92)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const rdev = makeDev(10, 260);
    const stat_buf = testSyntheticStat(c.S.IFCHR | 0o600, 0, rdev);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printTerseFormat(stat_buf, "ignored", &out.writer);

    var fields: [16][]const u8 = undefined;
    const n = testSplit(out.writer.buffered(), &fields);
    try testing.expectEqual(@as(u32, 16), n);
    // Fields: name size blocks mode uid gid dev inode nlinks major minor ...
    try testing.expectEqualStrings("a", fields[9]);
    try testing.expectEqualStrings("104", fields[10]);
}

test "stat default Device line renders the full decimal minor above 255 (issue 92)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Regular file, so no "Device type:" suffix -- isolates the minor
    // truncation fix (via printDefaultFormat, not the private helper
    // directly, so the test survives the helper's mode-parameter change).
    const dev = makeDev(253, 300);
    const stat_buf = testSyntheticStat(c.S.IFREG | 0o644, dev, 0);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <12}Links: {d}",
        .{ @as(u64, 253), @as(u64, 300), @as(u64, 162), @as(u64, 1) },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

test "stat default output appends GNU's Device type field for a character special file (issue 92)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Reproduces the pinned /dev/binder reference exactly: Device 0,7,
    // Inode 162, rdev major 10 minor 260.
    const dev = makeDev(0, 7);
    const rdev = makeDev(10, 260);
    const stat_buf = testSyntheticStat(c.S.IFCHR | 0o600, dev, rdev);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "/dev/binder", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <12}Links: {d: <5} Device type: {d},{d}",
        .{ @as(u64, 0), @as(u64, 7), @as(u64, 162), @as(u64, 1), @as(u64, 10), @as(u64, 260) },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

test "stat default output appends GNU's Device type field for a block special file (issue 92)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const dev = makeDev(0, 62);
    const rdev = makeDev(8, 16);
    const stat_buf = testSyntheticStat(c.S.IFBLK | 0o600, dev, rdev);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "/dev/sda2", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <12}Links: {d: <5} Device type: {d},{d}",
        .{ @as(u64, 0), @as(u64, 62), @as(u64, 162), @as(u64, 1), @as(u64, 8), @as(u64, 16) },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

test "stat default output has no Device type field for a regular file (issue 92)" {
    // Pinned reference: `stat /etc/hostname` -> "Device: 0,41\tInode: 470
    // Links: 1" with no trailing suffix or whitespace -- GNU only adds
    // "Device type:" for S_IFCHR/S_IFBLK. Guards the two-format-string
    // asymmetry against a careless unification with the device-node case.
    const dev = makeDev(0, 41);
    const stat_buf = testSyntheticStat(c.S.IFREG | 0o644, dev, 0);
    var stat_buf_mut = stat_buf;
    stat_buf_mut.ino = 470;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf_mut, "/etc/hostname", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <12}Links: {d}",
        .{ @as(u64, 0), @as(u64, 41), @as(u64, 470), @as(u64, 1) },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

test "stat %t/%T keep the BSD dev_t layout on Darwin (issue 92 no-op proof)" {
    if (!(builtin.os.tag == .macos or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    // Raw Darwin-layout rdev built by hand (not via makeDev, which only
    // implements the Linux packing): major 3 at bits 24..31, minor 2 in the
    // low 24 bits. Must render "3"/"2" both before and after the fix.
    const rdev: u64 = (@as(u64, 3) << 24) | 2;
    const stat_buf = testSyntheticStat(c.S.IFCHR | 0o600, 0, rdev);

    var major_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer major_out.deinit();
    try expandFormatDirective(testing.allocator, 't', stat_buf, "ignored", true, &major_out.writer);
    try testing.expectEqualStrings("3", major_out.writer.buffered());

    var minor_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer minor_out.deinit();
    try expandFormatDirective(testing.allocator, 'T', stat_buf, "ignored", true, &minor_out.writer);
    try testing.expectEqualStrings("2", minor_out.writer.buffered());
}

test "stat default output Device type suffix uses the BSD layout on Darwin (issue 92)" {
    if (!(builtin.os.tag == .macos or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    // Raw Darwin-layout rdev: major 3, minor 2 (same bits as the %t/%T
    // no-op proof above), but here exercised through the default-output
    // "Device type:" suffix rather than the %t/%T directives.
    const rdev: u64 = (@as(u64, 3) << 24) | 2;
    const stat_buf = testSyntheticStat(c.S.IFCHR | 0o600, 0, rdev);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <12}Links: {d: <5} Device type: {d},{d}",
        .{ @as(u64, 0), @as(u64, 0), @as(u64, 162), @as(u64, 1), @as(u64, 3), @as(u64, 2) },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

// ============================================================================
// Default-record separator parity with GNU (issue #98).
//
// GNU's default_format (src/stat.c) puts a literal tab after the Size field
// and literal spaces after the Blocks/IO Block/Inode fields -- the pad
// widths themselves are narrower than what this file used to hard-code
// (10/10/6/10, not 10/11/7/12). Folding the separator into the pad hides
// the bug for small values and only shows up once a field's rendered width
// reaches the folded width, so these tests deliberately include both a
// pinned everyday-sized reference and synthetic overflow values.
// ============================================================================

test "stat default Size line matches GNU byte-for-byte for a regular file (issue 98)" {
    // Not gated to Linux: the Size line has no platform-dependent inputs
    // (size/blocks/blksize/file-type only), so this must be provable RED on
    // both macOS and Linux CI runners.

    // Pinned reference: `stat /etc/passwd` on the GNU coreutils 9.5 VM ->
    // "  Size: 1383      \tBlocks: 8          IO Block: 4096   regular
    // file". Hardcoded literally (not built from the implementation's own
    // format DSL) so this is a true byte pin against GNU, independent of
    // any shared misunderstanding of Zig's `{d: <N}` fill semantics.
    // Today's code folds the literal tab and both literal spaces into the
    // pad widths, so this fails even for an everyday-sized file.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.size = 1383;
    stat_buf.blocks = 8;
    stat_buf.blksize = 4096;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const size_line = testLine(out.writer.buffered(), 1);
    const expected = "  Size: 1383      \tBlocks: 8          IO Block: 4096   regular file";
    try testing.expectEqualStrings(expected, size_line);
}

test "stat default Size line keeps the tab when size overflows the pad (issue 98)" {
    // Not gated to Linux: the Size line has no platform-dependent inputs.

    // 11-digit size (a 10GB sparse file) overflows the 10-wide pad. Today's
    // code has no literal separator at all after the pad, so the tab
    // vanishes and "Blocks:" runs directly into the digits, e.g.
    // "10737418240Blocks:".
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.size = 10737418240;
    stat_buf.blocks = 0;
    stat_buf.blksize = 4096;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const size_line = testLine(out.writer.buffered(), 1);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "  Size: {d: <10}\tBlocks: {d: <10} IO Block: {d: <6} {s}",
        .{ @as(u64, 10737418240), @as(u64, 0), @as(u64, 4096), "regular file" },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, size_line);
}

test "stat default Size line keeps single spaces when Blocks/IO Block overflow (issue 98)" {
    // Not gated to Linux: the Size line has no platform-dependent inputs.

    // An 18-digit block count and a 13-digit block size overflow both the
    // Blocks (10-wide) and IO Block (6-wide) pads by a wide margin -- far
    // enough that no plausible "just widen the pad" pseudo-fix (e.g. 12/8)
    // could still fold the literal separator away and pass by accident.
    // Today's code folds both separators into their pads, so both vanish
    // once the digit count reaches the pad width.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.size = 1;
    stat_buf.blocks = 923372036854775807;
    stat_buf.blksize = 1073741824000;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const size_line = testLine(out.writer.buffered(), 1);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "  Size: {d: <10}\tBlocks: {d: <10} IO Block: {d: <6} {s}",
        .{ @as(u64, 1), @as(u64, 923372036854775807), @as(u64, 1073741824000), "regular file" },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, size_line);
}

test "stat default Device line keeps two spaces before Links for an 11-digit inode (issue 98)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Regular file (no "Device type:" suffix), inode at the literal 11-digit
    // case named in the issue (12345678901) -- today's folded {d: <12} has
    // exactly one digit of headroom left for a 10-digit inode, so an
    // 11-digit inode collapses the separator from two spaces to one. Full
    // teeth against a "just widen the pad" pseudo-fix come from running
    // alongside the untouched issue-92 tests above, which pin a 3-digit
    // inode to the OLD 12-wide fold -- the two expectations are only
    // simultaneously satisfiable by a 10-wide pad plus two literal spaces,
    // not by any single wider pad width.
    const dev = makeDev(0, 41);
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, dev, 0);
    stat_buf.ino = 12345678901;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <10}  Links: {d}",
        .{ @as(u64, 0), @as(u64, 41), @as(u64, 12345678901), @as(u64, 1) },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

test "stat default Device line keeps two spaces and Device type for an 11-digit inode (issue 98)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Same 11-digit inode as the regular-file case above, but on a
    // character special file, so the "Device type: MAJ,MIN" suffix and the
    // Links padding it introduces must both survive untouched.
    const dev = makeDev(0, 7);
    const rdev = makeDev(10, 260);
    var stat_buf = testSyntheticStat(c.S.IFCHR | 0o600, dev, rdev);
    stat_buf.ino = 12345678901;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);

    const device_line = testLine(out.writer.buffered(), 2);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "Device: {d},{d}\tInode: {d: <10}  Links: {d: <5} Device type: {d},{d}",
        .{
            @as(u64, 0),
            @as(u64, 7),
            @as(u64, 12345678901),
            @as(u64, 1),
            @as(u64, 10),
            @as(u64, 260),
        },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, device_line);
}

// ============================================================================
// TESTS: birth-time validity comes from statx's STATX_BTIME mask bit, never
// from btim.sec == 0 (issue #102).
//
// GNU decides "does this file have a birth time?" from the kernel's mask
// bit, not the value. A file legitimately born at or near the epoch (e.g.
// devtmpfs's /dev/null 120ms after boot, before the clock was set -- the
// exact failure seen on the ubuntu-24.04-arm CI runner) has btim.sec == 0
// with the mask bit SET, and GNU renders the formatted timestamp, not "-".
// This is not reproducible against any real file on this host (nothing here
// has a sub-second-past-epoch birth time), so every case below drives a
// synthetic StatResult directly through the renderer, exactly reproducing
// sec=0, nsec=120000000 with validity forced true or false.
// ============================================================================

test "stat default Birth line renders epoch-boundary birth time when validity TRUE (issue 102)" {
    // Exact reproduction of the ubuntu-24.04-arm CI failure. Today's code
    // tests btim.sec == 0 and always falls to "-", regardless of validity.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    stat_buf.btim_valid = true;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);
    const birth_line = testLine(out.writer.buffered(), 7);

    // TZ-independent expected value: reuse the exact formatter the renderer
    // is supposed to reach for a valid birth time (formatTimestamp renders
    // in local time; on the pinned GNU reference VM, which runs UTC, this
    // is literally "1970-01-01 00:00:00.120000000 +0000"). What this test
    // pins is the *branch* -- that the renderer must reach formatTimestamp
    // at all for sec == 0 once validity is true -- not formatTimestamp's own
    // TZ handling, which is untouched by this fix and used by every other
    // timestamp line in this file already.
    var fmt_buf: [64]u8 = undefined;
    const formatted = try formatTimestamp(0, 120000000, &fmt_buf);
    const expected = try std.fmt.allocPrint(testing.allocator, " Birth: {s}", .{formatted});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, birth_line);

    // TZ-independent literal pin against the GNU reference string
    // "1970-01-01 00:00:00.120000000 +0000": the fractional part is fixed
    // regardless of host timezone, so assert it directly rather than only
    // against the implementation's own formatter.
    try testing.expect(std.mem.find(u8, birth_line, ".120000000") != null);

    // On a UTC host (CI and the pinned reference VM both run UTC), pin the
    // exact GNU reference string byte for byte rather than only the
    // fractional-second fragment above.
    if (std.mem.endsWith(u8, birth_line, "+0000")) {
        try testing.expectEqualStrings(
            " Birth: 1970-01-01 00:00:00.120000000 +0000",
            birth_line,
        );
    }
}

test "stat default record Birth line still renders '-' when statx validity is FALSE (issue 102)" {
    // Negative-space companion: an unavailable birth time (mask bit clear)
    // must render "-" both before and after the fix.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    stat_buf.btim_valid = false;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDefaultFormat(testing.allocator, stat_buf, "ignored", true, &out.writer);
    try testing.expectEqualStrings(" Birth: -", testLine(out.writer.buffered(), 7));
}

test "stat %w renders formatted time TRUE, dash FALSE, per statx validity (issue 102)" {
    var valid_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    valid_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    valid_buf.btim_valid = true;

    var valid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer valid_out.deinit();
    try expandFormatDirective(
        testing.allocator,
        'w',
        valid_buf,
        "ignored",
        true,
        &valid_out.writer,
    );

    var fmt_buf: [64]u8 = undefined;
    const formatted = try formatTimestamp(0, 120000000, &fmt_buf);
    try testing.expectEqualStrings(formatted, valid_out.writer.buffered());

    var invalid_buf = valid_buf;
    invalid_buf.btim_valid = false;

    var invalid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_out.deinit();
    try expandFormatDirective(
        testing.allocator,
        'w',
        invalid_buf,
        "ignored",
        true,
        &invalid_out.writer,
    );
    try testing.expectEqualStrings("-", invalid_out.writer.buffered());
}

test "stat %W renders raw seconds 0 regardless of statx validity, never a dash (issue 102)" {
    // GNU's own live behavior (pinned against procfs, which never sets
    // STATX_BTIME: `stat -c '%w|%W' /proc/self/status` -> "-|0") is that %W
    // is ALWAYS numeric, 0 when the birth time is unknown -- unlike %w, it
    // never renders "-". This guards against an over-eager fix that makes
    // %W dash out on invalid, which would NOT match GNU.
    var valid_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    valid_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    valid_buf.btim_valid = true;

    var valid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer valid_out.deinit();
    try expandFormatDirective(
        testing.allocator,
        'W',
        valid_buf,
        "ignored",
        true,
        &valid_out.writer,
    );
    try testing.expectEqualStrings("0", valid_out.writer.buffered());

    var invalid_buf = valid_buf;
    invalid_buf.btim_valid = false;

    var invalid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_out.deinit();
    try expandFormatDirective(
        testing.allocator,
        'W',
        invalid_buf,
        "ignored",
        true,
        &invalid_out.writer,
    );
    try testing.expectEqualStrings("0", invalid_out.writer.buffered());
}

test "stat %W renders raw seconds TRUE, 0 FALSE, for a nonzero btime (issue 102)" {
    // Non-degenerate companion to the sec==0 test above: with sec==0 for
    // both halves, "always print 0" (the exact bug) also satisfies that
    // test. Pin the pinned GNU reference value
    // (`stat -c '%W' /dev/null` -> "1784777610" on the reference VM) for the
    // valid half, and confirm the invalid half suppresses that same nonzero
    // value down to "0" rather than passing it through -- the rule that
    // actually states issue #102's contract for %W: the value must never
    // decide the output, only the mask bit does.
    var valid_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    valid_buf.btim = .{ .sec = 1784777610, .nsec = 0 };
    valid_buf.btim_valid = true;

    var valid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer valid_out.deinit();
    try expandFormatDirective(
        testing.allocator,
        'W',
        valid_buf,
        "ignored",
        true,
        &valid_out.writer,
    );
    try testing.expectEqualStrings("1784777610", valid_out.writer.buffered());

    var invalid_buf = valid_buf;
    invalid_buf.btim_valid = false;

    var invalid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_out.deinit();
    try expandFormatDirective(
        testing.allocator,
        'W',
        invalid_buf,
        "ignored",
        true,
        &invalid_out.writer,
    );
    try testing.expectEqualStrings("0", invalid_out.writer.buffered());
}

test "stat -t terse btime field is 0 when validity TRUE, never suppressed (issue 102)" {
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    stat_buf.btim_valid = true;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printTerseFormat(stat_buf, "ignored", &out.writer);

    var fields: [16][]const u8 = undefined;
    const n = testSplit(out.writer.buffered(), &fields);
    try testing.expectEqual(@as(u32, 16), n);
    // Fields: name size blocks mode uid gid dev inode nlinks major minor
    // atime mtime ctime btime blksize -- btime is field index 14.
    try testing.expectEqualStrings("0", fields[14]);
}

test "stat -t terse btime field stays 0 when validity FALSE, GNU terse always numeric (issue 102)" {
    // Mirrors the TRUE case above: GNU's terse record never suppresses or
    // dashes out btime (pinned live: `/usr/bin/stat -t /dev/null` prints a
    // numeric 15th field unconditionally, and procfs's %W is "0" even
    // though it has no STATX_BTIME support at all). This guards against an
    // over-eager fix that threads validity into -t as a dash/suppress,
    // which would diverge from GNU -- the same risk the %W test guards for
    // the format-directive path.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    stat_buf.btim_valid = false;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printTerseFormat(stat_buf, "ignored", &out.writer);

    var fields: [16][]const u8 = undefined;
    const n = testSplit(out.writer.buffered(), &fields);
    try testing.expectEqual(@as(u32, 16), n);
    try testing.expectEqualStrings("0", fields[14]);
}

test "stat -t terse btime field passes through a nonzero value when validity TRUE (issue 102)" {
    // Non-degenerate companion to the two sec==0 cases above: both of those
    // pass with a constant-0 terse btime, so pin the pinned GNU reference
    // value (`/usr/bin/stat -t /dev/null` -> 15th field "1784777610" on the
    // reference VM) to confirm the field really carries the seconds
    // through, not just "0" unconditionally.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 1784777610, .nsec = 0 };
    stat_buf.btim_valid = true;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printTerseFormat(stat_buf, "ignored", &out.writer);

    var fields: [16][]const u8 = undefined;
    const n = testSplit(out.writer.buffered(), &fields);
    try testing.expectEqual(@as(u32, 16), n);
    try testing.expectEqualStrings("1784777610", fields[14]);
}

test "stat -r raw btime field stays numeric when validity FALSE, never a dash (issue 102)" {
    // The issue text names "src/stat.zig:1511/:1540" as the "-x verbose
    // record", but those lines are actually -r (printRawFormat) and -s
    // (printShellFormat), neither of which branches on validity today --
    // both always print btim.sec as %d. GNU/BSD never dash these fields
    // (pinned live: terse's 15th field and %W are unconditionally numeric,
    // 0 when unknown). The pre-existing "-r raw fields match the kernel's
    // own numbers" test only parseInt's the btime field against a real
    // temp file's truth, so it only catches a dash on a host whose
    // filesystem happens to report no btime -- add a synthetic guard that
    // is host-independent, mirroring the %W and -t guards above.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 1784777610, .nsec = 0 };
    stat_buf.btim_valid = false;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printRawFormat(stat_buf, "ignored", &out.writer);

    var fields: [20][]const u8 = undefined;
    const n = testSplit(out.writer.buffered(), &fields);
    try testing.expectEqual(@as(u32, 16), n);
    // Fields: d i #p l u g r z a m c B k b f N -- B (btime) is index 11.
    try testing.expectEqualStrings("1784777610", fields[11]);
}

test "stat -s shell st_birthtime stays numeric when validity FALSE, never a dash (issue 102)" {
    // Same guard as the -r test above, for printShellFormat's
    // st_birthtime= assignment.
    var stat_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    stat_buf.btim = .{ .sec = 1784777610, .nsec = 0 };
    stat_buf.btim_valid = false;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printShellFormat(stat_buf, &out.writer);

    const line = out.writer.buffered();
    try testing.expect(std.mem.find(u8, line, "st_birthtime=1784777610") != null);
    try testing.expect(std.mem.find(u8, line, "st_birthtime=-") == null);
}

/// Test-only: the text after " Birth: " on a record's Birth line, or "" when
/// the record carries no Birth line. Located by label rather than by line
/// index, so a record whose shape varies with the file type (GNU's character
/// special files carry an extra "Device type:" field) still resolves.
fn testBirthStamp(record: []const u8) []const u8 {
    std.debug.assert(record.len > 0);
    var it = std.mem.splitScalar(u8, record, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, " Birth: ")) continue;
        const stamp = line[" Birth: ".len..];
        std.debug.assert(stamp.len < line.len);
        return stamp;
    }
    return "";
}

test "stat -x verbose Birth line formats the raw birth time regardless of validity (issue 102)" {
    // -x is a fixed rendering of the FreeBSD preset, and BSD stat has no
    // concept of an unavailable birth time: gnulib's rule (tv_sec != 0 with
    // tv_nsec in range on BSD, the STATX_BTIME mask bit on Linux) governs the
    // GNU-facing paths only. Measured on macOS 25.5 against /dev/null, whose
    // birthtimespec is all zeroes (`/usr/bin/stat -f '%B' /dev/null` -> 0):
    //   /usr/bin/stat -x /dev/null | tail -1 -> " Birth: Wed Dec 31 16:00:00 1969"
    //   gstat /dev/null | tail -1            -> " Birth: -"
    // Same file, two specs, both correct for their own spec. Per CLAUDE.md's
    // spec hierarchy, -x follows the BSD spec, so it must format the raw
    // value unconditionally or byte parity with /usr/bin/stat -x breaks.
    var valid_buf = testSyntheticStat(c.S.IFREG | 0o644, 0, 0);
    valid_buf.btim = .{ .sec = 0, .nsec = 120000000 };
    valid_buf.btim_valid = true;

    var valid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer valid_out.deinit();
    try printVerboseFormat(testing.allocator, valid_buf, "ignored", &valid_out.writer);
    const valid_stamp = testBirthStamp(valid_out.writer.buffered());

    var invalid_buf = valid_buf;
    invalid_buf.btim_valid = false;

    var invalid_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_out.deinit();
    try printVerboseFormat(testing.allocator, invalid_buf, "ignored", &invalid_out.writer);
    const invalid_stamp = testBirthStamp(invalid_out.writer.buffered());

    // Validity must not reach -x at all: the same raw value renders the same
    // bytes either way. A dash-out regression trips this equality first.
    try testing.expectEqualStrings(valid_stamp, invalid_stamp);

    // The shared rendering is BSD stat's strftime "%c" stamp for sec == 0,
    // at the strength of "stat -x time lines carry a rendered timestamp, not
    // an epoch": a weekday name, a clock and a year, never "-" and never the
    // empty string bsdTimeString returns on strftime failure.
    var fmt_buf: [128]u8 = undefined;
    const expected = bsdTimeString(0, bsd_verbose_timefmt, &fmt_buf);
    try testing.expectEqualStrings(expected, invalid_stamp);
    try testing.expect(invalid_stamp.len >= 19);
    try testing.expect(std.ascii.isAlphabetic(invalid_stamp[0]));
    try testing.expect(std.mem.find(u8, invalid_stamp, ":") != null);
    try testing.expect(testHasYear(invalid_stamp));
}

test "stat GNU Birth line and %w dash for macOS /dev/null's zero birthtimespec (issue 102)" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;

    // Drives the real doStat_darwin against a character device whose
    // birthtimespec is all zeroes -- the field state gnulib's
    // get_stat_birthtime reports as unavailable on BSD, where there is no
    // mask bit to consult. Measured on macOS 25.5:
    //   /usr/bin/stat -f '%B' /dev/null -> 0
    //   gstat -c '%w|%W' /dev/null      -> -|0
    const null_buf = try doStat("/dev/null", true);
    // Premise, not a skip: if this host reports a nonzero birth time for
    // /dev/null then the sec == 0 case is not being exercised and a green
    // result here would mean nothing, so state it as an assertion.
    try testing.expectEqual(@as(i64, 0), null_buf.btim.sec);

    var record: std.Io.Writer.Allocating = .init(testing.allocator);
    defer record.deinit();
    try printDefaultFormat(testing.allocator, null_buf, "/dev/null", true, &record.writer);
    try testing.expectEqualStrings("-", testBirthStamp(record.writer.buffered()));

    var w_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w_out.deinit();
    try expandFormatDirective(testing.allocator, 'w', null_buf, "/dev/null", true, &w_out.writer);
    try testing.expectEqualStrings("-", w_out.writer.buffered());

    // Negative space, so "dash on Darwin always" cannot satisfy the above: a
    // freshly created file has a nonzero birthtimespec and must still render
    // a real timestamp on both GNU-facing paths.
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    const file = try tmp_dir.dir().createFile(testing.io, "born.txt", .{});
    file.close(testing.io);
    const path = try testAbsPath(tmp_dir.dir(), "born.txt");
    defer testing.allocator.free(path);

    const file_buf = try doStat(path, true);
    try testing.expect(file_buf.btim.sec > 0);

    var file_record: std.Io.Writer.Allocating = .init(testing.allocator);
    defer file_record.deinit();
    try printDefaultFormat(testing.allocator, file_buf, path, true, &file_record.writer);
    const file_stamp = testBirthStamp(file_record.writer.buffered());
    try testing.expect(file_stamp.len >= 19);
    try testing.expect(testHasYear(file_stamp));
}
