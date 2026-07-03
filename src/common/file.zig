const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Group struct definition
const group = extern struct {
    name: ?[*:0]const u8,
    passwd: ?[*:0]const u8,
    gid: std.c.gid_t,
    mem: ?[*:null]?[*:0]const u8,
};

// Extern function declaration for getgrgid
extern "c" fn getgrgid(gid: std.c.gid_t) ?*group;

/// Convert stat buffer to FileInfo
fn statToFileInfo(stat_buf: std.c.Stat) FileInfo {
    // Convert C stat to our FileInfo
    const kind: std.Io.File.Kind = switch (stat_buf.mode & std.c.S.IFMT) {
        std.c.S.IFREG => .file,
        std.c.S.IFDIR => .directory,
        std.c.S.IFCHR => .character_device,
        std.c.S.IFBLK => .block_device,
        std.c.S.IFIFO => .named_pipe,
        std.c.S.IFLNK => .sym_link,
        std.c.S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };

    // Handle platform differences in timespec field names
    const atime_ns = if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
        stat_buf.atimespec.sec * std.time.ns_per_s + stat_buf.atimespec.nsec
    else
        stat_buf.atim.sec * std.time.ns_per_s + stat_buf.atim.nsec;

    const mtime_ns = if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
        stat_buf.mtimespec.sec * std.time.ns_per_s + stat_buf.mtimespec.nsec
    else
        stat_buf.mtim.sec * std.time.ns_per_s + stat_buf.mtim.nsec;

    const ctime_ns = if (builtin.os.tag == .macos or builtin.os.tag.isDarwin())
        stat_buf.ctimespec.sec * std.time.ns_per_s + stat_buf.ctimespec.nsec
    else
        stat_buf.ctim.sec * std.time.ns_per_s + stat_buf.ctim.nsec;

    return FileInfo{
        .size = @intCast(stat_buf.size),
        .mode = @intCast(stat_buf.mode),
        .atime = atime_ns,
        .mtime = mtime_ns,
        .ctime = ctime_ns,
        .kind = kind,
        .inode = stat_buf.ino,
        // `st_dev` is a signed i32 on macOS; devfs and friends report ids
        // with the high bit set. Reinterpret the bits rather than range
        // checking, since a negative i32 would not fit in the u64 field.
        .dev = @as(u32, @bitCast(stat_buf.dev)),
        .uid = @intCast(stat_buf.uid),
        .gid = @intCast(stat_buf.gid),
        .nlink = @intCast(stat_buf.nlink),
    };
}

/// Stat a path by file descriptor + relative path using fstatat (or statx on Linux).
/// follow = .follow means follow symlinks (like stat); .no_follow means like lstat.
const StatFollow = enum { follow, no_follow };

fn fstatatToFileInfo(dirfd: std.posix.fd_t, path_z: [*:0]const u8, follow: StatFollow) !FileInfo {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const flags: u32 = if (follow == .no_follow) linux.AT.SYMLINK_NOFOLLOW else 0;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(dirfd, path_z, flags, linux.STATX.BASIC_STATS, &sx);
        if (linux.errno(rc) != .SUCCESS) {
            return switch (linux.errno(rc)) {
                .SUCCESS => unreachable,
                .ACCES => error.AccessDenied,
                .BADF => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                else => error.SystemResources,
            };
        }

        const atime_ns: i128 = @as(i128, sx.atime.sec) * std.time.ns_per_s + sx.atime.nsec;
        const mtime_ns: i128 = @as(i128, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec;
        const ctime_ns: i128 = @as(i128, sx.ctime.sec) * std.time.ns_per_s + sx.ctime.nsec;

        const kind: std.Io.File.Kind = switch (sx.mode & std.c.S.IFMT) {
            std.c.S.IFREG => .file,
            std.c.S.IFDIR => .directory,
            std.c.S.IFCHR => .character_device,
            std.c.S.IFBLK => .block_device,
            std.c.S.IFIFO => .named_pipe,
            std.c.S.IFLNK => .sym_link,
            std.c.S.IFSOCK => .unix_domain_socket,
            else => .unknown,
        };

        return FileInfo{
            .size = sx.size,
            .mode = @intCast(sx.mode),
            .atime = atime_ns,
            .mtime = mtime_ns,
            .ctime = ctime_ns,
            .kind = kind,
            .inode = sx.ino,
            .dev = (@as(u64, sx.dev_major) << 8) | @as(u64, sx.dev_minor),
            .uid = sx.uid,
            .gid = sx.gid,
            .nlink = @intCast(sx.nlink),
        };
    } else {
        // macOS and other platforms support std.c.fstatat.
        const flags: u32 = if (follow == .no_follow) std.c.AT.SYMLINK_NOFOLLOW else 0;
        var stat_buf: std.c.Stat = undefined;
        const result = std.c.fstatat(dirfd, path_z, &stat_buf, flags);
        if (result != 0) {
            return switch (std.posix.errno(result)) {
                .SUCCESS => unreachable,
                .ACCES => error.AccessDenied,
                .BADF => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                else => error.SystemResources,
            };
        }
        return statToFileInfo(stat_buf);
    }
}

/// File stat information wrapper
pub const FileInfo = struct {
    size: u64,
    mode: std.posix.mode_t,
    atime: i128, // nanoseconds since epoch
    mtime: i128, // nanoseconds since epoch
    ctime: i128 = 0, // nanoseconds since epoch (inode change time)
    kind: std.Io.File.Kind,
    inode: std.Io.File.INode,
    dev: u64 = 0, // device ID
    uid: u32,
    gid: u32,
    nlink: u32,

    pub fn stat(io: std.Io, path: []const u8) !FileInfo {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        return try statFile(file);
    }

    /// Get file info without following symlinks (like lstat)
    pub fn lstat(path: []const u8) !FileInfo {
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
        std.debug.assert(path.len <= std.Io.Dir.max_path_bytes);
        std.debug.assert(path.len < buf.len);
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const c_path = buf[0..path.len :0];

        return fstatatToFileInfo(std.Io.Dir.cwd().handle, c_path, .no_follow);
    }

    pub fn statFile(file: std.Io.File) !FileInfo {
        const fd = file.handle;
        if (builtin.os.tag == .linux) {
            // On Linux, std.c.fstat is void; use statx via the Linux syscall.
            const linux = std.os.linux;
            var sx: linux.Statx = undefined;
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &sx);
            if (linux.errno(rc) != .SUCCESS) return error.StatFailed;

            const atime_ns: i128 = @as(i128, sx.atime.sec) * std.time.ns_per_s + sx.atime.nsec;
            const mtime_ns: i128 = @as(i128, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec;
            const ctime_ns: i128 = @as(i128, sx.ctime.sec) * std.time.ns_per_s + sx.ctime.nsec;

            const kind: std.Io.File.Kind = switch (sx.mode & std.c.S.IFMT) {
                std.c.S.IFREG => .file,
                std.c.S.IFDIR => .directory,
                std.c.S.IFCHR => .character_device,
                std.c.S.IFBLK => .block_device,
                std.c.S.IFIFO => .named_pipe,
                std.c.S.IFLNK => .sym_link,
                std.c.S.IFSOCK => .unix_domain_socket,
                else => .unknown,
            };

            return FileInfo{
                .size = sx.size,
                .mode = @intCast(sx.mode),
                .atime = atime_ns,
                .mtime = mtime_ns,
                .ctime = ctime_ns,
                .kind = kind,
                .inode = sx.ino,
                .dev = (@as(u64, sx.dev_major) << 8) | @as(u64, sx.dev_minor),
                .uid = sx.uid,
                .gid = sx.gid,
                .nlink = @intCast(sx.nlink),
            };
        } else {
            // macOS and other platforms support std.c.fstat.
            var stat_buf: std.c.Stat = undefined;
            const result = std.c.fstat(fd, &stat_buf);
            if (result != 0) return error.StatFailed;
            return statToFileInfo(stat_buf);
        }
    }

    pub fn lstatDir(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !FileInfo {
        // Use lstat to get info about the link itself, not the target
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        return fstatatToFileInfo(dir.handle, name_z, .no_follow);
    }

    /// Get file info following symlinks, relative to a directory (like stat)
    pub fn statDir(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !FileInfo {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        return fstatatToFileInfo(dir.handle, name_z, .follow);
    }
};

/// Format file permissions as a string (e.g., -rw-r--r--)
pub fn formatPermissions(mode: std.posix.mode_t, kind: std.Io.File.Kind, buf: []u8) ![]const u8 {
    if (buf.len < 10) return error.BufferTooSmall;
    std.debug.assert(buf.len >= 10);

    // File type
    buf[0] = switch (kind) {
        .directory => 'd',
        .character_device => 'c',
        .block_device => 'b',
        .named_pipe => 'p',
        .sym_link => 'l',
        .unix_domain_socket => 's',
        .file => '-',
        else => '?',
    };

    // Owner permissions
    buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    buf[3] = if (mode & 0o100 != 0) 'x' else '-';

    // Group permissions
    buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    buf[6] = if (mode & 0o010 != 0) 'x' else '-';

    // Other permissions
    buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    buf[9] = if (mode & 0o001 != 0) 'x' else '-';

    // Handle setuid, setgid, and sticky bits
    const constants = @import("constants.zig");
    // The execute slots were assigned exactly 'x' or '-' above; the bit
    // transforms below depend on that to choose between 's'/'S' and 't'/'T'.
    const owner_exec_valid = buf[3] == 'x' or buf[3] == '-';
    const group_exec_valid = buf[6] == 'x' or buf[6] == '-';
    const other_exec_valid = buf[9] == 'x' or buf[9] == '-';
    std.debug.assert(owner_exec_valid);
    std.debug.assert(group_exec_valid);
    std.debug.assert(other_exec_valid);
    if (mode & constants.SETUID_BIT != 0) { // setuid
        buf[3] = if (buf[3] == 'x') 's' else 'S';
    }
    if (mode & constants.SETGID_BIT != 0) { // setgid
        buf[6] = if (buf[6] == 'x') 's' else 'S';
    }
    if (mode & constants.STICKY_BIT != 0) { // sticky
        buf[9] = if (buf[9] == 'x') 't' else 'T';
    }

    return buf[0..10];
}

/// Format file size in bytes
pub fn formatSize(size: u64, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{size});
}

/// Format file size in human readable format (K, M, G, T)
pub fn formatSizeHuman(size: u64, buf: []u8) ![]const u8 {
    const format = @import("format.zig");
    return format.formatHumanReadable(buf, size, .{});
}

/// Format file size in kilobytes (1K blocks)
pub fn formatSizeKilobytes(size: u64, buf: []u8) ![]const u8 {
    const kb = (size + 1023) / 1024; // Round up
    return std.fmt.bufPrint(buf, "{d}", .{kb});
}

/// Return current Unix timestamp in seconds via C clock_gettime.
/// Returns 0 (epoch) if clock_gettime fails, so callers see a harmless
/// "1970" sentinel rather than reading uninitialized stack memory.
fn currentTimestampSeconds() i64 {
    var ts: std.c.timespec = std.mem.zeroes(std.c.timespec);
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

/// Return current Unix timestamp in nanoseconds via C clock_gettime.
/// Returns 0 (epoch) if clock_gettime fails, so callers see a harmless
/// "1970" sentinel rather than reading uninitialized stack memory.
pub fn currentTimestampNanoseconds() i128 {
    var ts: std.c.timespec = std.mem.zeroes(std.c.timespec);
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    // POSIX guarantees a successful clock_gettime fills tv_nsec in [0, 1e9).
    std.debug.assert(ts.nsec >= 0);
    std.debug.assert(ts.nsec < std.time.ns_per_s);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Format modification time for ls -l output
/// Shows "MMM DD HH:MM" for recent files (< 6 months)
/// Shows "MMM DD  YYYY" for older files
pub fn formatTime(mtime_ns: i128, buf: []u8) ![]const u8 {
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const now_s = currentTimestampSeconds();
    const six_months_s = @import("constants.zig").SIX_MONTHS_SECONDS;

    // Convert to broken-down time
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_s) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    // Month enum is Jan=1..Dec=12; bound the index into the 12-element array.
    std.debug.assert(@intFromEnum(month_day.month) >= 1);
    std.debug.assert(@intFromEnum(month_day.month) <= 12);
    const month = months[@intFromEnum(month_day.month) - 1];
    const day = month_day.day_index + 1;
    const year = year_day.year;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();

    // Format based on age
    if (now_s - mtime_s < six_months_s) {
        // Recent: "MMM DD HH:MM"
        return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}", .{ month, day, hour, minute });
    } else {
        // Old: "MMM DD  YYYY"
        return std.fmt.bufPrint(buf, "{s} {d: >2}  {d}", .{ month, day, year });
    }
}

/// Get username from uid (returns uid as string if lookup fails)
pub fn getUserName(uid: u32, buf: []u8) ![]const u8 {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const c_uid = @as(std.c.uid_t, @intCast(uid));
        const pw_ptr = std.c.getpwuid(c_uid);
        if (pw_ptr) |pw| {
            // The name field is optional, check if it exists
            if (pw.name) |name_ptr| {
                const name = std.mem.span(name_ptr);
                if (name.len < buf.len) {
                    @memcpy(buf[0..name.len], name);
                    return buf[0..name.len];
                }
            }
        }
    }
    // Fallback to uid as string
    return std.fmt.bufPrint(buf, "{d}", .{uid});
}

/// Get group name from gid (returns gid as string if lookup fails)
pub fn getGroupName(gid: u32, buf: []u8) ![]const u8 {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const c_gid = @as(std.c.gid_t, @intCast(gid));
        const gr_ptr = getgrgid(c_gid);
        if (gr_ptr) |gr| {
            // The name field is optional, check if it exists
            if (gr.name) |name_ptr| {
                const name = std.mem.span(name_ptr);
                if (name.len < buf.len) {
                    @memcpy(buf[0..name.len], name);
                    return buf[0..name.len];
                }
            }
        }
    }
    // Fallback to gid as string
    return std.fmt.bufPrint(buf, "{d}", .{gid});
}

// Tests

test "formatPermissions regular file" {
    var buf: [10]u8 = undefined;

    // Regular file, mode 0644 (-rw-r--r--)
    const result = try formatPermissions(0o644, .file, &buf);
    try testing.expectEqualStrings("-rw-r--r--", result);
}

test "formatPermissions directory" {
    var buf: [10]u8 = undefined;

    // Directory, mode 0755 (drwxr-xr-x)
    const result = try formatPermissions(0o755, .directory, &buf);
    try testing.expectEqualStrings("drwxr-xr-x", result);
}

test "formatPermissions symlink" {
    var buf: [10]u8 = undefined;

    // Symlink, mode 0777 (lrwxrwxrwx)
    const result = try formatPermissions(0o777, .sym_link, &buf);
    try testing.expectEqualStrings("lrwxrwxrwx", result);
}

test "formatPermissions executable" {
    var buf: [10]u8 = undefined;

    // Executable file, mode 0755 (-rwxr-xr-x)
    const result = try formatPermissions(0o755, .file, &buf);
    try testing.expectEqualStrings("-rwxr-xr-x", result);
}

test "formatPermissions setuid setgid sticky" {
    var buf: [10]u8 = undefined;

    // File with setuid bit (4755)
    var result = try formatPermissions(0o4755, .file, &buf);
    try testing.expectEqualStrings("-rwsr-xr-x", result);

    // Directory with setgid bit (2755)
    result = try formatPermissions(0o2755, .directory, &buf);
    try testing.expectEqualStrings("drwxr-sr-x", result);

    // Directory with sticky bit (1755)
    result = try formatPermissions(0o1755, .directory, &buf);
    try testing.expectEqualStrings("drwxr-xr-t", result);
}

test "formatSize basic" {
    var buf: [32]u8 = undefined;

    var result = try formatSize(0, &buf);
    try testing.expectEqualStrings("0", result);

    result = try formatSize(1234, &buf);
    try testing.expectEqualStrings("1234", result);

    result = try formatSize(1234567890, &buf);
    try testing.expectEqualStrings("1234567890", result);
}

test "formatSizeHuman basic" {
    var buf: [32]u8 = undefined;

    // Bytes
    var result = try formatSizeHuman(0, &buf);
    try testing.expectEqualStrings("0", result);

    result = try formatSizeHuman(1023, &buf);
    try testing.expectEqualStrings("1023", result);

    // Kilobytes
    result = try formatSizeHuman(1024, &buf);
    try testing.expectEqualStrings("1.0K", result);

    result = try formatSizeHuman(1536, &buf);
    try testing.expectEqualStrings("1.5K", result);

    result = try formatSizeHuman(10240, &buf);
    try testing.expectEqualStrings("10K", result);

    // Megabytes
    result = try formatSizeHuman(1048576, &buf);
    try testing.expectEqualStrings("1.0M", result);

    result = try formatSizeHuman(5242880, &buf);
    try testing.expectEqualStrings("5.0M", result);

    // Gigabytes
    result = try formatSizeHuman(1073741824, &buf);
    try testing.expectEqualStrings("1.0G", result);
}

test "formatSizeKilobytes basic" {
    var buf: [32]u8 = undefined;

    var result = try formatSizeKilobytes(0, &buf);
    try testing.expectEqualStrings("0", result);

    result = try formatSizeKilobytes(1, &buf);
    try testing.expectEqualStrings("1", result); // Rounds up

    result = try formatSizeKilobytes(1024, &buf);
    try testing.expectEqualStrings("1", result);

    result = try formatSizeKilobytes(2048, &buf);
    try testing.expectEqualStrings("2", result);

    result = try formatSizeKilobytes(1536, &buf);
    try testing.expectEqualStrings("2", result); // Rounds up
}

test "FileInfo.stat basic" {
    const io = testing.io;
    // Create a temporary file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "Hello, World!");
    file.close(io);

    // Get the path
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..path_len];
    const path = try std.fmt.bufPrint(path_buf[path_len..], "{s}/test.txt", .{dir_path});

    // Stat the file
    const info = try FileInfo.stat(io, path);

    // Check basic properties
    try testing.expectEqual(@as(u64, 13), info.size); // "Hello, World!" is 13 bytes
    try testing.expectEqual(std.Io.File.Kind.file, info.kind);
    try testing.expect(info.mtime > 0);
    try testing.expect(info.ctime > 0);
}

test "FileInfo.stat handles device id with high bit set" {
    // Regression: on macOS `st_dev` is a signed i32. Filesystems such as
    // devfs (/dev) report a dev id with the high bit set, which reads as a
    // negative i32. `@intCast`ing that negative value into the u64 `dev`
    // field panics with "integer does not fit in destination type", which
    // crashed `ls /`. The conversion must reinterpret the bits, not range
    // check. /dev exists on both macOS (devfs) and Linux (devtmpfs), so this
    // exercises the conversion on both platforms.
    const io = testing.io;

    const info = try FileInfo.stat(io, "/dev");

    try testing.expectEqual(std.Io.File.Kind.directory, info.kind);
    // A populated device id, proving the conversion ran without trapping.
    try testing.expect(info.dev != 0);
}

test "formatTime recent file" {
    var buf: [64]u8 = undefined;

    // Current time in nanoseconds
    const now_ns = currentTimestampNanoseconds();

    // Test with current time (recent file)
    const result = try formatTime(now_ns, &buf);

    // Should contain current month and time format HH:MM
    // Can't test exact output due to current time, but check format
    try testing.expect(result.len >= 12); // "MMM DD HH:MM" is at least 12 chars
    try testing.expect(std.mem.find(u8, result, ":") != null); // Should have time
}

test "formatTime old file" {
    var buf: [64]u8 = undefined;

    // Time from 2020 (old file)
    const old_time_s: i64 = 1577836800; // Jan 1, 2020
    const old_time_ns = old_time_s * std.time.ns_per_s;

    const result = try formatTime(old_time_ns, &buf);

    // Should show year instead of time
    try testing.expect(std.mem.find(u8, result, "2020") != null);
    try testing.expect(std.mem.find(u8, result, ":") == null); // Should not have time
}
