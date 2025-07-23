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

/// File stat information wrapper
pub const FileInfo = struct {
    size: u64,
    mode: std.fs.File.Mode,
    atime: i128, // nanoseconds since epoch
    mtime: i128, // nanoseconds since epoch
    kind: std.fs.File.Kind,
    inode: std.fs.File.INode,
    uid: u32,
    gid: u32,
    nlink: u32,

    pub fn stat(path: []const u8) !FileInfo {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return try statFile(file);
    }

    pub fn statFile(file: std.fs.File) !FileInfo {
        // Use fstat directly to get all information
        const fd = file.handle;
        var stat_buf: std.c.Stat = undefined;
        const result = std.c.fstat(fd, &stat_buf);
        if (result != 0) {
            return error.StatFailed;
        }
        
        // Convert C stat to our FileInfo
        const kind: std.fs.File.Kind = switch (stat_buf.mode & std.c.S.IFMT) {
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
            .size = @intCast(stat_buf.size),
            .mode = @intCast(stat_buf.mode),
            .atime = stat_buf.atim.sec * std.time.ns_per_s + stat_buf.atim.nsec,
            .mtime = stat_buf.mtim.sec * std.time.ns_per_s + stat_buf.mtim.nsec,
            .kind = kind,
            .inode = stat_buf.ino,
            .uid = @intCast(stat_buf.uid),
            .gid = @intCast(stat_buf.gid),
            .nlink = @intCast(stat_buf.nlink),
        };
    }
    
    pub fn statDir(dir: std.fs.Dir, name: []const u8) !FileInfo {
        const file = try dir.openFile(name, .{});
        defer file.close();
        return try statFile(file);
    }
    
    pub fn lstatDir(dir: std.fs.Dir, name: []const u8) !FileInfo {
        // Use lstat to get info about the link itself, not the target
        const allocator = std.heap.c_allocator;
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        
        var stat_buf: std.c.Stat = undefined;
        const result = std.c.fstatat(dir.fd, name_z, &stat_buf, std.c.AT.SYMLINK_NOFOLLOW);
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
        
        // Convert stat to FileInfo
        const kind = switch (stat_buf.mode & std.c.S.IFMT) {
            std.c.S.IFREG => std.fs.File.Kind.file,
            std.c.S.IFDIR => .directory,
            std.c.S.IFCHR => .character_device,
            std.c.S.IFBLK => .block_device,
            std.c.S.IFIFO => .named_pipe,
            std.c.S.IFLNK => .sym_link,
            std.c.S.IFSOCK => .unix_domain_socket,
            else => .unknown,
        };
        
        return FileInfo{
            .size = @intCast(stat_buf.size),
            .mode = @intCast(stat_buf.mode),
            .atime = stat_buf.atim.sec * std.time.ns_per_s + stat_buf.atim.nsec,
            .mtime = stat_buf.mtim.sec * std.time.ns_per_s + stat_buf.mtim.nsec,
            .kind = kind,
            .inode = stat_buf.ino,
            .uid = @intCast(stat_buf.uid),
            .gid = @intCast(stat_buf.gid),
            .nlink = @intCast(stat_buf.nlink),
        };
    }
};

/// Format file permissions as a string (e.g., -rw-r--r--)
pub fn formatPermissions(mode: std.fs.File.Mode, kind: std.fs.File.Kind, buf: []u8) ![]const u8 {
    if (buf.len < 10) return error.BufferTooSmall;

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
    if (mode & 0o4000 != 0) { // setuid
        buf[3] = if (buf[3] == 'x') 's' else 'S';
    }
    if (mode & 0o2000 != 0) { // setgid
        buf[6] = if (buf[6] == 'x') 's' else 'S';
    }
    if (mode & 0o1000 != 0) { // sticky
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
    const units = [_][]const u8{ "", "K", "M", "G", "T", "P" };
    var value = @as(f64, @floatFromInt(size));
    var unit_idx: usize = 0;

    while (value >= 1024.0 and unit_idx < units.len - 1) : (unit_idx += 1) {
        value /= 1024.0;
    }

    if (unit_idx == 0) {
        // Bytes - no decimal places
        return std.fmt.bufPrint(buf, "{d}", .{size});
    } else if (value >= 10.0) {
        // >= 10, show no decimal places
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ value, units[unit_idx] });
    } else {
        // < 10, show one decimal place
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, units[unit_idx] });
    }
}

/// Format file size in kilobytes (1K blocks)
pub fn formatSizeKilobytes(size: u64, buf: []u8) ![]const u8 {
    const kb = (size + 1023) / 1024; // Round up
    return std.fmt.bufPrint(buf, "{d}", .{kb});
}

/// Format modification time for ls -l output
/// Shows "MMM DD HH:MM" for recent files (< 6 months)
/// Shows "MMM DD  YYYY" for older files
pub fn formatTime(mtime_ns: i128, buf: []u8) ![]const u8 {
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const now_s = std.time.timestamp();
    const six_months_s = 6 * 30 * 24 * 60 * 60; // Approximate
    
    // Convert to broken-down time
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_s) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };
    
    const month = months[@intFromEnum(month_day.month) - 1];
    const day = month_day.day_index + 1;
    const year = year_day.year;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    
    // Format based on age
    if (now_s - mtime_s < six_months_s) {
        // Recent: "MMM DD HH:MM"
        return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}", .{
            month, day, hour, minute
        });
    } else {
        // Old: "MMM DD  YYYY"
        return std.fmt.bufPrint(buf, "{s} {d: >2}  {d}", .{
            month, day, year
        });
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
    // Create a temporary file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("Hello, World!");
    file.close();
    
    // Get the path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test.txt", &path_buf);
    
    // Stat the file
    const info = try FileInfo.stat(path);
    
    // Check basic properties
    try testing.expectEqual(@as(u64, 13), info.size); // "Hello, World!" is 13 bytes
    try testing.expectEqual(std.fs.File.Kind.file, info.kind);
    try testing.expect(info.mtime > 0);
}

test "formatTime recent file" {
    var buf: [64]u8 = undefined;
    
    // Current time in nanoseconds
    const now_ns = std.time.nanoTimestamp();
    
    // Test with current time (recent file)
    const result = try formatTime(now_ns, &buf);
    
    // Should contain current month and time format HH:MM
    // Can't test exact output due to current time, but check format
    try testing.expect(result.len >= 12); // "MMM DD HH:MM" is at least 12 chars
    try testing.expect(std.mem.indexOf(u8, result, ":") != null); // Should have time
}

test "formatTime old file" {
    var buf: [64]u8 = undefined;
    
    // Time from 2020 (old file)
    const old_time_s: i64 = 1577836800; // Jan 1, 2020
    const old_time_ns = old_time_s * std.time.ns_per_s;
    
    const result = try formatTime(old_time_ns, &buf);
    
    // Should show year instead of time
    try testing.expect(std.mem.indexOf(u8, result, "2020") != null);
    try testing.expect(std.mem.indexOf(u8, result, ":") == null); // Should not have time
}