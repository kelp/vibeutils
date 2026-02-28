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

// C library bindings for time conversion
const c_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

extern "c" fn localtime_r(timer: *const c.time_t, result: *c_tm) ?*c_tm;
extern "c" fn statfs(path: [*:0]const u8, buf: *StatFs) c_int;

// macOS statfs structure
const StatFs = extern struct {
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
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},
};

// ============================================================================
// Argument parsing (manual, like date.zig, for --format=FMT and --printf=FMT)
// ============================================================================

fn parseArgs(allocator: Allocator, args: []const []const u8) struct { opts: StatOptions, err: ?[]const u8 } {
    var opts = StatOptions{};
    var err_msg: ?[]const u8 = null;
    var positionals = std.ArrayListUnmanaged([]const u8){};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
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
            if (std.mem.eql(u8, arg, "--help")) {
                opts.help = true;
                break;
            } else if (std.mem.eql(u8, arg, "--version")) {
                opts.version = true;
                break;
            } else if (std.mem.eql(u8, arg, "--dereference")) {
                opts.dereference = true;
            } else if (std.mem.eql(u8, arg, "--file-system")) {
                opts.file_system = true;
            } else if (std.mem.eql(u8, arg, "--terse")) {
                opts.terse = true;
            } else if (std.mem.startsWith(u8, arg, "--format=")) {
                opts.format = arg["--format=".len..];
            } else if (std.mem.eql(u8, arg, "--format")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.format = args[i];
                } else {
                    err_msg = "option '--format' requires an argument";
                    break;
                }
            } else if (std.mem.startsWith(u8, arg, "--printf=")) {
                opts.printf_fmt = arg["--printf=".len..];
            } else if (std.mem.eql(u8, arg, "--printf")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.printf_fmt = args[i];
                } else {
                    err_msg = "option '--printf' requires an argument";
                    break;
                }
            } else {
                err_msg = "unrecognized option";
                break;
            }
            continue;
        }

        // Short options
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'L' => opts.dereference = true,
                'f' => opts.file_system = true,
                't' => opts.terse = true,
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
                    } else if (i + 1 < args.len) {
                        i += 1;
                        opts.format = args[i];
                    } else {
                        err_msg = "option '-c' requires an argument";
                    }
                    // Done with this arg either way
                    j = arg.len;
                    break;
                },
                else => {
                    err_msg = "unrecognized option";
                    break;
                },
            }
        }
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

// ============================================================================
// Low-level stat wrapper
// ============================================================================

/// Perform stat or lstat on a path, returning the raw C Stat struct
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

// ============================================================================
// Time formatting helpers
// ============================================================================

fn getTimespecSec(stat_buf: c.Stat, comptime which: enum { atime, mtime, ctime, btime }) i64 {
    return switch (which) {
        .atime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.atimespec.sec
        else
            stat_buf.atim.sec,
        .mtime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.mtimespec.sec
        else
            stat_buf.mtim.sec,
        .ctime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.ctimespec.sec
        else
            stat_buf.ctim.sec,
        .btime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.birthtimespec.sec
        else
            0,
    };
}

fn getTimespecNsec(stat_buf: c.Stat, comptime which: enum { atime, mtime, ctime, btime }) i64 {
    return switch (which) {
        .atime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.atimespec.nsec
        else
            stat_buf.atim.nsec,
        .mtime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.mtimespec.nsec
        else
            stat_buf.mtim.nsec,
        .ctime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.ctimespec.nsec
        else
            stat_buf.ctim.nsec,
        .btime => if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
            stat_buf.birthtimespec.nsec
        else
            0,
    };
}

/// Format a timestamp as "YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ"
fn formatTimestamp(sec: i64, nsec: i64, fmt_buf: []u8) ![]const u8 {
    const time_val: c.time_t = @intCast(sec);
    var tm: c_tm = undefined;
    if (localtime_r(&time_val, &tm) == null) {
        return error.TimeConversion;
    }

    const year = @as(i32, tm.tm_year) + 1900;
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

    return std.fmt.bufPrint(fmt_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9} {c}{d:0>2}{d:0>2}", .{
        year, mon, day, hour, min, s, ns, sign, tz_hours, tz_mins,
    });
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

fn fileTypeStringEmpty(mode: u32) []const u8 {
    const ft = fileTypeString(mode);
    if (std.mem.eql(u8, ft, "regular file")) {
        const size_check_mode = mode & c.S.IFMT;
        if (size_check_mode == c.S.IFREG) return "regular file";
    }
    return ft;
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

    return perm_buf[0..10];
}

// ============================================================================
// Format directive expansion
// ============================================================================

fn expandFormatDirective(
    allocator: Allocator,
    directive: u8,
    stat_buf: c.Stat,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = @intCast(stat_buf.mode);
    switch (directive) {
        'a' => {
            // Access rights in octal
            try writer.print("{o}", .{mode & 0o7777});
        },
        'A' => {
            // Access rights in human readable form
            var perm_buf: [10]u8 = undefined;
            const perms = formatPermissions(mode, &perm_buf);
            try writer.writeAll(perms);
        },
        'b' => {
            // Number of blocks allocated
            try writer.print("{d}", .{stat_buf.blocks});
        },
        'B' => {
            // Block size for allocation (always 512 on most systems)
            try writer.print("512", .{});
        },
        'd' => {
            // Device number in decimal
            try writer.print("{d}", .{stat_buf.dev});
        },
        'D' => {
            // Device number in hex
            try writer.print("{x}", .{stat_buf.dev});
        },
        'f' => {
            // Raw mode in hex
            try writer.print("{x}", .{mode});
        },
        'F' => {
            // File type
            const size: i64 = @intCast(stat_buf.size);
            if ((mode & c.S.IFMT) == c.S.IFREG and size == 0) {
                try writer.writeAll("regular empty file");
            } else {
                try writer.writeAll(fileTypeString(mode));
            }
        },
        'g' => {
            // Group ID
            try writer.print("{d}", .{stat_buf.gid});
        },
        'G' => {
            // Group name
            const gid: u32 = @intCast(stat_buf.gid);
            const group_info = common.user_group.getGroupById(gid, allocator) catch {
                try writer.print("{d}", .{gid});
                return;
            };
            defer allocator.free(group_info.name);
            try writer.writeAll(group_info.name);
        },
        'h' => {
            // Number of hard links
            try writer.print("{d}", .{stat_buf.nlink});
        },
        'i' => {
            // Inode number
            try writer.print("{d}", .{stat_buf.ino});
        },
        'm' => {
            // Mount point -- requires statfs
            var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            if (path.len > std.fs.max_path_bytes) {
                try writer.writeAll("?");
                return;
            }
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            const c_path = path_buf[0..path.len :0];

            var fs_buf: StatFs = undefined;
            if (statfs(c_path, &fs_buf) == 0) {
                const mntonname = std.mem.sliceTo(&fs_buf.f_mntonname, 0);
                try writer.writeAll(mntonname);
            } else {
                try writer.writeAll("?");
            }
        },
        'n' => {
            // File name
            try writer.writeAll(path);
        },
        'N' => {
            // Quoted file name with symlink target
            if ((mode & c.S.IFMT) == c.S.IFLNK and !follow_symlinks) {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.fs.cwd().readLink(path, &link_buf) catch {
                    try writer.print("'{s}'", .{path});
                    return;
                };
                try writer.print("'{s}' -> '{s}'", .{ path, target });
            } else {
                try writer.print("'{s}'", .{path});
            }
        },
        'o' => {
            // Optimal I/O transfer size
            if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
                try writer.print("{d}", .{stat_buf.blksize});
            } else {
                try writer.print("{d}", .{stat_buf.blksize});
            }
        },
        's' => {
            // Total size in bytes
            try writer.print("{d}", .{stat_buf.size});
        },
        't' => {
            // Major device type in hex (for device files)
            // On macOS, use the major() macro equivalent
            if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
                const rdev: u32 = @intCast(stat_buf.rdev);
                const major_val = (rdev >> 24) & 0xff;
                try writer.print("{x}", .{major_val});
            } else {
                const rdev: u64 = @intCast(stat_buf.rdev);
                const major_val = (rdev >> 8) & 0xfff;
                try writer.print("{x}", .{major_val});
            }
        },
        'T' => {
            // Minor device type in hex (for device files)
            if (builtin.os.tag == .macos or builtin.os.tag.isDarwin()) {
                const rdev: u32 = @intCast(stat_buf.rdev);
                const minor_val = rdev & 0xffffff;
                try writer.print("{x}", .{minor_val});
            } else {
                const rdev: u64 = @intCast(stat_buf.rdev);
                const minor_val = rdev & 0xff;
                try writer.print("{x}", .{minor_val});
            }
        },
        'u' => {
            // User ID
            try writer.print("{d}", .{stat_buf.uid});
        },
        'U' => {
            // User name
            const uid: u32 = @intCast(stat_buf.uid);
            const user_info = common.user_group.getUserById(uid, allocator) catch {
                try writer.print("{d}", .{uid});
                return;
            };
            defer allocator.free(user_info.name);
            try writer.writeAll(user_info.name);
        },
        'w' => {
            // Time of birth (- if unknown)
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
        },
        'W' => {
            // Time of birth as seconds since epoch
            const btime_sec = getTimespecSec(stat_buf, .btime);
            if (btime_sec == 0) {
                try writer.writeAll("0");
            } else {
                try writer.print("{d}", .{btime_sec});
            }
        },
        'x' => {
            // Time of last access
            const atime_sec = getTimespecSec(stat_buf, .atime);
            const atime_nsec = getTimespecNsec(stat_buf, .atime);
            var fmt_buf: [64]u8 = undefined;
            const formatted = formatTimestamp(atime_sec, atime_nsec, &fmt_buf) catch {
                try writer.writeAll("-");
                return;
            };
            try writer.writeAll(formatted);
        },
        'X' => {
            // Time of last access as seconds since epoch
            try writer.print("{d}", .{getTimespecSec(stat_buf, .atime)});
        },
        'y' => {
            // Time of last modification
            const mtime_sec = getTimespecSec(stat_buf, .mtime);
            const mtime_nsec = getTimespecNsec(stat_buf, .mtime);
            var fmt_buf: [64]u8 = undefined;
            const formatted = formatTimestamp(mtime_sec, mtime_nsec, &fmt_buf) catch {
                try writer.writeAll("-");
                return;
            };
            try writer.writeAll(formatted);
        },
        'Y' => {
            // Time of last modification as seconds since epoch
            try writer.print("{d}", .{getTimespecSec(stat_buf, .mtime)});
        },
        'z' => {
            // Time of last status change
            const ctime_sec = getTimespecSec(stat_buf, .ctime);
            const ctime_nsec = getTimespecNsec(stat_buf, .ctime);
            var fmt_buf: [64]u8 = undefined;
            const formatted = formatTimestamp(ctime_sec, ctime_nsec, &fmt_buf) catch {
                try writer.writeAll("-");
                return;
            };
            try writer.writeAll(formatted);
        },
        'Z' => {
            // Time of last status change as seconds since epoch
            try writer.print("{d}", .{getTimespecSec(stat_buf, .ctime)});
        },
        else => {
            // Unknown directive, print literal
            try writer.writeByte('%');
            try writer.writeByte(directive);
        },
    }
}

// ============================================================================
// Format string processing
// ============================================================================

fn processFormatString(
    allocator: Allocator,
    format: []const u8,
    stat_buf: c.Stat,
    path: []const u8,
    follow_symlinks: bool,
    interpret_escapes: bool,
    writer: anytype,
) !void {
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;
            try expandFormatDirective(allocator, format[i], stat_buf, path, follow_symlinks, writer);
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
    stat_buf: c.Stat,
    path: []const u8,
    follow_symlinks: bool,
    writer: anytype,
) !void {
    const mode: u32 = @intCast(stat_buf.mode);

    // Line 1: File name
    try writer.writeAll("  File: ");
    if ((mode & c.S.IFMT) == c.S.IFLNK and !follow_symlinks) {
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.cwd().readLink(path, &link_buf) catch {
            try writer.print("{s}\n", .{path});
            return;
        };
        try writer.print("{s} -> {s}\n", .{ path, target });
    } else {
        try writer.print("{s}\n", .{path});
    }

    // Line 2: Size, Blocks, IO Block, file type
    const size: i64 = @intCast(stat_buf.size);
    const file_type = if ((mode & c.S.IFMT) == c.S.IFREG and size == 0)
        "regular empty file"
    else
        fileTypeString(mode);
    try writer.print("  Size: {d: <10}Blocks: {d: <11}IO Block: {d: <7}{s}\n", .{
        stat_buf.size,
        stat_buf.blocks,
        stat_buf.blksize,
        file_type,
    });

    // Line 3: Device, Inode, Links
    const dev: u64 = @intCast(stat_buf.dev);
    try writer.print("Device: {x}h/{d}d\tInode: {d: <12}Links: {d}\n", .{
        dev,
        dev,
        stat_buf.ino,
        stat_buf.nlink,
    });

    // Line 4: Access permissions, Uid, Gid
    var perm_buf: [10]u8 = undefined;
    const perms = formatPermissions(mode, &perm_buf);
    const octal_mode = mode & 0o7777;

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

    try writer.print("Access: ({o:0>4}/{s})  Uid: ({d: >5}/{s: >8})   Gid: ({d: >5}/{s: >8})\n", .{
        octal_mode,
        perms,
        uid,
        user_name,
        gid,
        group_name,
    });

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
            try writer.print(" Birth: -\n", .{});
        } else {
            var fmt_buf: [64]u8 = undefined;
            const btime_nsec = getTimespecNsec(stat_buf, .btime);
            const formatted = formatTimestamp(btime_sec, btime_nsec, &fmt_buf) catch "-";
            try writer.print(" Birth: {s}\n", .{formatted});
        }
    }
}

// ============================================================================
// Terse output format
// ============================================================================

fn printTerseFormat(stat_buf: c.Stat, path: []const u8, writer: anytype) !void {
    const mode: u32 = @intCast(stat_buf.mode);
    const dev: u64 = @intCast(stat_buf.dev);
    try writer.print("{s} {d} {d} {x} {d} {d} {x} {d} {d} {d} {d} {d} {d} {d}\n", .{
        path,
        stat_buf.size,
        stat_buf.blocks,
        mode,
        stat_buf.uid,
        stat_buf.gid,
        dev,
        stat_buf.ino,
        stat_buf.nlink,
        getTimespecSec(stat_buf, .atime),
        getTimespecSec(stat_buf, .mtime),
        getTimespecSec(stat_buf, .ctime),
        stat_buf.blksize,
        stat_buf.blocks,
    });
}

// ============================================================================
// File system stat (statfs) output
// ============================================================================

fn printFileSystemInfo(
    path: []const u8,
    writer: anytype,
) !void {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    var fs_buf: StatFs = undefined;
    if (statfs(c_path, &fs_buf) != 0) {
        return error.StatFsFailed;
    }

    const fstype = std.mem.sliceTo(&fs_buf.f_fstypename, 0);
    const mntonname = std.mem.sliceTo(&fs_buf.f_mntonname, 0);
    const mntfromname = std.mem.sliceTo(&fs_buf.f_mntfromname, 0);

    try writer.print("  File: \"{s}\"\n", .{path});
    try writer.print("    ID: {x}{x} Namelen: {d}     Type: {s}\n", .{
        @as(u32, @bitCast(fs_buf.f_fsid.val[0])),
        @as(u32, @bitCast(fs_buf.f_fsid.val[1])),
        255, // macOS doesn't expose namelen in statfs
        fstype,
    });
    try writer.print("Block size: {d}       Fundamental block size: {d}\n", .{
        fs_buf.f_bsize,
        fs_buf.f_bsize,
    });
    try writer.print("Blocks: Total: {d: <11}Free: {d: <11}Available: {d}\n", .{
        fs_buf.f_blocks,
        fs_buf.f_bfree,
        fs_buf.f_bavail,
    });
    try writer.print("Inodes: Total: {d: <11}Free: {d}\n", .{
        fs_buf.f_files,
        fs_buf.f_ffree,
    });
    try writer.print(" Mount: {s}\n", .{mntonname});
    try writer.print("  From: {s}\n", .{mntfromname});
}

// ============================================================================
// Main utility function
// ============================================================================

pub fn runStat(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const parsed = parseArgs(allocator, args);
    const opts = parsed.opts;
    defer allocator.free(opts.positionals);

    if (parsed.err) |err_msg| {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}\nTry 'stat --help' for more information.", .{err_msg});
        return @intFromEnum(common.ExitCode.misuse);
    }

    if (opts.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing operand\nTry 'stat --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    var has_error = false;

    for (opts.positionals) |path| {
        if (opts.file_system) {
            printFileSystemInfo(path, stdout_writer) catch {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot statfs '{s}': No such file or directory", .{path});
                has_error = true;
                continue;
            };
            continue;
        }

        const stat_buf = doStat(path, opts.dereference) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot stat '{s}': No such file or directory", .{path});
            has_error = true;
            continue;
        };

        if (opts.format) |format| {
            try processFormatString(allocator, format, stat_buf, path, opts.dereference, false, stdout_writer);
            try stdout_writer.writeByte('\n');
        } else if (opts.printf_fmt) |format| {
            try processFormatString(allocator, format, stat_buf, path, opts.dereference, true, stdout_writer);
        } else if (opts.terse) {
            try printTerseFormat(stat_buf, path, stdout_writer);
        } else {
            try printDefaultFormat(allocator, stat_buf, path, opts.dereference, stdout_writer);
        }
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

// ============================================================================
// Entry point
// ============================================================================

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runStat(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

// ============================================================================
// Help and version
// ============================================================================

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
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
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("stat ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "stat --help shows usage" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: stat") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--format") != null);
}

test "stat -h shows usage" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-h"};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: stat") != null);
}

test "stat --version shows version" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "stat") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
}

test "stat -V shows version" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "stat") != null);
}

test "stat missing operand returns misuse" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "stat unknown flag returns misuse" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid"};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unrecognized option") != null);
}

test "stat nonexistent file returns error" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"/nonexistent/file/path"};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "cannot stat") != null);
}

test "stat default output on regular file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello world");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{test_path};
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Check key fields in default output
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "File:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Size:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Blocks:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Device:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Inode:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Access:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Modify:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Change:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "regular file") != null);
}

test "stat -c format: file name" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%n", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Output should be the path + newline
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{test_path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_buffer.items);
}

test "stat -c format: size" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%s", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_buffer.items);
}

test "stat -c format: file type" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("subdir", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%F", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("directory\n", stdout_buffer.items);
}

test "stat -c format: inode number" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%i", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should be a valid number followed by newline
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    const inode = try std.fmt.parseInt(u64, trimmed, 10);
    try testing.expect(inode > 0);
}

test "stat -c format: permissions octal" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .mode = 0o644 });
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%a", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should contain octal permissions (possibly affected by umask)
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    try testing.expect(trimmed.len > 0);
}

test "stat -c format: permissions human readable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{ .mode = 0o644 });
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%A", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should start with '-' for regular file
    try testing.expect(stdout_buffer.items.len >= 10);
    try testing.expectEqual(@as(u8, '-'), stdout_buffer.items[0]);
}

test "stat -c format: user and group IDs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%u %g", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should be two numbers separated by space
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const uid_str = it.next() orelse return error.TestFailed;
    const gid_str = it.next() orelse return error.TestFailed;
    _ = try std.fmt.parseInt(u32, uid_str, 10);
    _ = try std.fmt.parseInt(u32, gid_str, 10);
}

test "stat -c format: user and group names" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%U", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should be a non-empty name
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    try testing.expect(trimmed.len > 0);
}

test "stat -c format: timestamps" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Test epoch seconds format
    const args = [_][]const u8{ "-c", "%X %Y %Z", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should contain numbers
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    try testing.expect(trimmed.len > 0);
}

test "stat --printf interprets escapes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("data");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "--printf=%s\\n", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("4\n", stdout_buffer.items);
}

test "stat --format=FMT syntax" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "--format=%s", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_buffer.items);
}

test "stat -t terse output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-t", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Terse output is one line with space-separated fields
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    try testing.expect(trimmed.len > 0);
    // Should start with the path
    try testing.expect(std.mem.startsWith(u8, trimmed, test_path));
}

test "stat empty file shows regular empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("empty.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("empty.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%F", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("regular empty file\n", stdout_buffer.items);
}

test "stat directory type" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("subdir", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%F", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("directory\n", stdout_buffer.items);
}

test "stat symlink without dereference" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("target.txt", .{});
    try test_file.writeAll("content");
    test_file.close();

    try tmp_dir.dir.symLink("target.txt", "link.txt", .{});

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try tmp_dir.dir.realpath("link.txt", &path_buf);

    // Without -L: should show "symbolic link"
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Note: realpath resolves symlinks, so we need to construct the path manually
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &dir_path_buf);
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(symlink_path);

    // We need the symlink to exist at a known path. Since realpath follows
    // symlinks, use the directory path + link name
    _ = link_path;

    const args = [_][]const u8{ "-c", "%F", symlink_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("symbolic link\n", stdout_buffer.items);
}

test "stat symlink with dereference" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("target.txt", .{});
    try test_file.writeAll("content");
    test_file.close();

    try tmp_dir.dir.symLink("target.txt", "link.txt", .{});

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &dir_path_buf);
    const symlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(symlink_path);

    // With -L: should show "regular file" (follows the link)
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-L", "-c", "%F", symlink_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("regular file\n", stdout_buffer.items);
}

test "stat multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file1 = try tmp_dir.dir.createFile("a.txt", .{});
    try file1.writeAll("aaa");
    file1.close();

    const file2 = try tmp_dir.dir.createFile("b.txt", .{});
    try file2.writeAll("bbbbb");
    file2.close();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    const path1 = try tmp_dir.dir.realpath("a.txt", &path_buf1);
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = try tmp_dir.dir.realpath("b.txt", &path_buf2);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%s", path1, path2 };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("3\n5\n", stdout_buffer.items);
}

test "stat -f file system info" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Should contain file system info
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "File:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Block") != null);
}

test "stat -c format: hard links" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%h", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1\n", stdout_buffer.items);
}

test "stat -c format: device number" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%d", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    _ = try std.fmt.parseInt(u64, trimmed, 10);
}

test "stat -c format: multiple directives" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "size=%s type=%F", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("size=5 type=regular file\n", stdout_buffer.items);
}

test "stat partial failure with multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("exists.txt", .{});
    try test_file.writeAll("data");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("exists.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%s", "/nonexistent", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should return error (1) because one file failed
    try testing.expectEqual(@as(u8, 1), result);
    // But should still output the successful file
    try testing.expectEqualStrings("4\n", stdout_buffer.items);
    // And report the error
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "cannot stat") != null);
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

test "stat -- separator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("hello");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "%s", "--", test_path };
    const result = try runStat(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("5\n", stdout_buffer.items);
}
