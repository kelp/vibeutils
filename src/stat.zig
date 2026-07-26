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
    };
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
                try writer.print("'{s}' -> '{s}'", .{ path, target });
            } else {
                try writer.print("'{s}'", .{path});
            }
        } else {
            try writer.print("'{s}'", .{path});
        }
    } else {
        try writer.print("'{s}'", .{path});
    }
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
    try printDefaultFormat_deviceLine(stat_buf, writer);
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

/// Line 2: "  Size: ... Blocks: ... IO Block: ... <file type>".
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
    try writer.print("  Size: {d: <10}Blocks: {d: <11}IO Block: {d: <7}{s}\n", .{
        size_u,
        blocks_u,
        blksize_u,
        file_type,
    });
}

/// Line 3: "Device: MAJ,MIN\tInode: ...\tLinks: ..." (GNU decimal major,minor).
fn printDefaultFormat_deviceLine(stat_buf: StatResult, writer: anytype) !void {
    const dev: u64 = @intCast(stat_buf.dev);
    const dev_major: u64 = if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
        (dev >> 24) & 0xff
    else
        (dev >> 8) & 0xfff;
    const dev_minor: u64 = if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
        dev & 0xffffff
    else
        dev & 0xff;
    try writer.print("Device: {d},{d}\tInode: {d: <12}Links: {d}\n", .{
        dev_major,
        dev_minor,
        stat_buf.ino,
        stat_buf.nlink,
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

    // Line 8: Birth time
    {
        const btime_sec = getTimespecSec(stat_buf, .btime);
        if (btime_sec == 0) {
            try writer.print(" Birth: -", .{});
        } else {
            var fmt_buf: [64]u8 = undefined;
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

    if (opts.positionals.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing operand\nTry 'stat --help' for more information.",
            .{},
        );
        return @intFromEnum(common.ExitCode.misuse);
    }

    var has_error = false;

    // The empty-positionals case returned above, so the loop has work to do.
    std.debug.assert(opts.positionals.len > 0);
    for (opts.positionals) |path| {
        const failed = try processOnePath(
            allocator,
            &opts,
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

    if (opts.format) |format| {
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

test "stat missing operand returns misuse" {
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

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
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

test "stat default output on regular file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello world");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
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

test "stat -t terse output" {
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

test "stat -f file system info" {
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

// F15: Default output must not show spurious '+' before numeric fields.
// The {d: <N} format on signed i64 produces a leading '+' sign, e.g.
// "Size: +4096" instead of "Size: 4096".
test "stat default output has no spurious plus on numeric fields" {
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try test_file.writeStreamingAll(testing.io, "hello world");
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    test_file.close(testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(testing.io, "test.txt", &path_buf);
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

    try testing.expectEqual(@as(u8, 2), missing_value_result);
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

    try testing.expectEqual(@as(u8, 2), unknown_result);
    try testing.expect(
        std.mem.find(u8, unknown_stderr_aw.writer.buffered(), "unrecognized option") != null,
    );
}

test "stat -q does not change a successful stat" {
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
