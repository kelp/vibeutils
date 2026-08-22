const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// The group lookup goes through the shared module so that libc's `struct
// group` is declared exactly once in the tree (issue #129).
const user_group = @import("user_group.zig");
const getgrgid = user_group.getgrgid;

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
        .blocks = @intCast(stat_buf.blocks),
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
            .blocks = sx.blocks,
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
    // Allocated 512-byte blocks (st_blocks). This is what the file
    // occupies, which a size-derived count gets wrong in both directions:
    // a file smaller than the allocation unit under-reports, and a sparse
    // file over-reports.
    blocks: u64 = 0,

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
                .blocks = sx.blocks,
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

/// Names the Linux VFS stores a POSIX ACL under. The kernel discards an ACL
/// that the mode bits already express rather than storing it, so the mere
/// presence of either name is the same verdict GNU ls reaches by scanning the
/// xattr list, without ever reading the value.
const acl_access_xattr: [:0]const u8 = "system.posix_acl_access";
const acl_default_xattr: [:0]const u8 = "system.posix_acl_default";

/// Darwin's <sys/acl.h>: ACL_TYPE_EXTENDED is the only type its getters
/// accept, and ACL_FIRST_ENTRY starts a walk of the entry list.
const acl_type_extended: c_int = 0x0000_0100;
const acl_first_entry: c_int = 0;

// libSystem on Darwin. Referenced only from the Darwin arm below, so nothing
// links against them on a platform that reads xattrs instead.
extern "c" fn acl_get_file(path: [*:0]const u8, acl_type: c_int) ?*anyopaque;
extern "c" fn acl_get_link_np(path: [*:0]const u8, acl_type: c_int) ?*anyopaque;
extern "c" fn acl_get_entry(acl: *anyopaque, entry_id: c_int, entry_p: *?*anyopaque) c_int;
extern "c" fn acl_free(obj: *anyopaque) c_int;

/// Whether `path` carries an ACL beyond the one its mode bits express — the
/// condition GNU ls reports as `+` in an eleventh mode column under -l.
///
/// `follow` must match the follow-ness of the stat whose mode is printed on
/// the same line, or the marker and the permission string end up describing
/// different files. A symlink being described in its own right is never
/// probed at all, which is what GNU's S_ISLNK short-circuit does.
///
/// The operand path in `src/ls/main.zig` passes `follow = true` unconditionally
/// because `ls -l <symlink>` there already stats the target rather than the
/// link -- a pre-existing divergence from GNU, which describes the link. The
/// two are consistent only because both follow. Whoever fixes that stat must
/// fix this call in the same change, or the mode and the marker will start
/// describing different files, which is exactly what the paragraph above
/// forbids.
///
/// Every failure answers false. A marker we fail to print misaligns nothing,
/// while a marker we invent widens every row of the section it lands in.
pub fn hasExtendedAcl(path: []const u8, kind: std.Io.File.Kind, follow: bool) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= std.Io.Dir.max_path_bytes);
    if (kind == .sym_link and !follow) return false;

    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    if (comptime builtin.os.tag == .linux) {
        if (aclXattrPresent(path_z, acl_access_xattr, follow)) return true;
        // A default ACL exists only on a directory and leaves the mode bits
        // alone, so nothing in the permission string hints at it; GNU marks
        // such a directory all the same, and probing the access name by
        // itself would miss every one of them.
        if (kind != .directory) return false;
        return aclXattrPresent(path_z, acl_default_xattr, follow);
    }
    if (comptime builtin.os.tag == .macos) return darwinHasExtendedAcl(path_z, follow);
    return false;
}

/// Whether the extended attribute `name` exists on `path`, asked as a size
/// query: the value itself is never read, only whether the kernel has one.
fn aclXattrPresent(path_z: [*:0]const u8, name: [:0]const u8, follow: bool) bool {
    // The syscall wrapper takes a value pointer even for a size query; a zero
    // size means the kernel never writes through it.
    var unused: [1]u8 = undefined;
    const rc: isize = @bitCast(if (follow)
        std.os.linux.getxattr(path_z, name.ptr, &unused, 0)
    else
        std.os.linux.lgetxattr(path_z, name.ptr, &unused, 0));
    // A raw syscall returns a length or a negative errno no smaller than
    // -4095; anything below that would mean a length was misread as an error.
    std.debug.assert(rc >= -4095);
    // ENODATA (no such attribute), EOPNOTSUPP (filesystem without ACLs) and
    // ENOENT (a dangling link followed) all mean no marker. A stored POSIX
    // ACL is never zero length: it carries a version header and at least the
    // three entries that mirror the mode bits.
    return rc > 0;
}

/// Darwin has no POSIX ACL xattrs — an extended ACL is an NFSv4-style entry
/// list reached through libSystem, and a file without one yields a null acl_t.
///
/// A non-null handle is not by itself the answer: the entry list it carries
/// can be empty, and the probe below is what separates the two. GNU reaches
/// the same verdict the same way, through gnulib's `acl_entries (acl) > 0`.
fn darwinHasExtendedAcl(path_z: [*:0]const u8, follow: bool) bool {
    const acl = if (follow)
        acl_get_file(path_z, acl_type_extended)
    else
        acl_get_link_np(path_z, acl_type_extended);
    const handle = acl orelse return false;
    defer _ = acl_free(handle);

    var first: ?*anyopaque = null;
    // Apple's acl_get_entry answers 0 for an entry and -1 both at the end of
    // the list and on error — the inverse of the 1-then-0 that libacl and
    // FreeBSD use, so this comparison cannot be shared with the Linux arm.
    const rc = acl_get_entry(handle, acl_first_entry, &first);
    // Those two values are the whole documented range. A third would mean we
    // linked a libacl-shaped acl_get_entry, whose 1-for-success reads here as
    // an empty list and would drop every marker on the platform in silence.
    std.debug.assert(rc == 0 or rc == -1);
    // A reported entry must have been written through the out-parameter; a
    // null one alongside success would mean we read the wrong ABI.
    std.debug.assert(rc != 0 or first != null);
    return rc == 0;
}

const posix_acl_dump_entries_max: u32 = 1024;
const posix_acl_xattr_version: u32 = 2;
const posix_acl_tag_user_obj: u16 = 0x01;
const posix_acl_tag_user: u16 = 0x02;
const posix_acl_tag_group_obj: u16 = 0x04;
const posix_acl_tag_group: u16 = 0x08;
const posix_acl_tag_mask: u16 = 0x10;
const posix_acl_tag_other: u16 = 0x20;

/// Allocate a getfacl-style dump of the POSIX access ACL on `path`.
/// Null when none is stored or the platform has no POSIX ACL xattrs.
/// Caller frees. Used by `ls -e`.
pub fn allocAclDump(allocator: std.mem.Allocator, path: []const u8, follow: bool) ?[]u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= std.Io.Dir.max_path_bytes);
    if (comptime builtin.os.tag != .linux) return null;
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    return allocPosixAclDump(allocator, path_z, follow);
}

fn allocPosixAclDump(allocator: std.mem.Allocator, path_z: [*:0]const u8, follow: bool) ?[]u8 {
    var unused: [1]u8 = undefined;
    const size_rc: isize = @bitCast(if (follow)
        std.os.linux.getxattr(path_z, acl_access_xattr.ptr, &unused, 0)
    else
        std.os.linux.lgetxattr(path_z, acl_access_xattr.ptr, &unused, 0));
    if (size_rc < 4) return null;
    const size: u32 = @intCast(size_rc);
    const size_max: u32 = 4 + posix_acl_dump_entries_max * 8;
    std.debug.assert(size >= 4);
    if (size > size_max) return null;
    const blob = allocator.alloc(u8, size) catch return null;
    defer allocator.free(blob);
    const rc: isize = @bitCast(if (follow)
        std.os.linux.getxattr(path_z, acl_access_xattr.ptr, blob.ptr, blob.len)
    else
        std.os.linux.lgetxattr(path_z, acl_access_xattr.ptr, blob.ptr, blob.len));
    if (rc != size_rc) return null;
    std.debug.assert(rc >= 4);
    return formatPosixAclBlob(allocator, blob);
}

fn posixAclPermChars(perm: u16) [3]u8 {
    return .{
        if (perm & 4 != 0) @as(u8, 'r') else '-',
        if (perm & 2 != 0) @as(u8, 'w') else '-',
        if (perm & 1 != 0) @as(u8, 'x') else '-',
    };
}

fn posixAclIdName(id: u32, buf: *[256]u8, group: bool) []const u8 {
    if (group) {
        const gr = user_group.getgrgid(@intCast(id)) orelse
            return std.fmt.bufPrint(buf, "{d}", .{id}) catch "0";
        const src = user_group.spanOrEmpty(gr.name);
        const n = @min(src.len, buf.len);
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }
    const pw = user_group.getpwuid(@intCast(id)) orelse
        return std.fmt.bufPrint(buf, "{d}", .{id}) catch "0";
    const src = user_group.spanOrEmpty(pw.name);
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

fn appendPosixAclLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tag: u16,
    perm: u16,
    id: u32,
) !void {
    const perms = posixAclPermChars(perm);
    var name_buf: [256]u8 = undefined;
    const line = switch (tag) {
        posix_acl_tag_user_obj => try std.fmt.allocPrint(
            allocator,
            "user::{c}{c}{c}\n",
            .{ perms[0], perms[1], perms[2] },
        ),
        posix_acl_tag_user => blk: {
            const name = posixAclIdName(id, &name_buf, false);
            break :blk try std.fmt.allocPrint(
                allocator,
                "user:{s}:{c}{c}{c}\n",
                .{ name, perms[0], perms[1], perms[2] },
            );
        },
        posix_acl_tag_group_obj => try std.fmt.allocPrint(
            allocator,
            "group::{c}{c}{c}\n",
            .{ perms[0], perms[1], perms[2] },
        ),
        posix_acl_tag_group => blk: {
            const name = posixAclIdName(id, &name_buf, true);
            break :blk try std.fmt.allocPrint(
                allocator,
                "group:{s}:{c}{c}{c}\n",
                .{ name, perms[0], perms[1], perms[2] },
            );
        },
        posix_acl_tag_mask => try std.fmt.allocPrint(
            allocator,
            "mask::{c}{c}{c}\n",
            .{ perms[0], perms[1], perms[2] },
        ),
        posix_acl_tag_other => try std.fmt.allocPrint(
            allocator,
            "other::{c}{c}{c}\n",
            .{ perms[0], perms[1], perms[2] },
        ),
        else => return,
    };
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn formatPosixAclBlob(allocator: std.mem.Allocator, blob: []const u8) ?[]u8 {
    std.debug.assert(blob.len >= 4);
    const version = std.mem.readInt(u32, blob[0..4], .little);
    if (version != posix_acl_xattr_version) return null;
    const rest = blob[4..];
    if (rest.len % 8 != 0) return null;
    const count = rest.len / 8;
    if (count == 0 or count > posix_acl_dump_entries_max) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const rec = rest[i * 8 ..][0..8];
        const tag = std.mem.readInt(u16, rec[0..2], .little);
        const perm = std.mem.readInt(u16, rec[2..4], .little);
        const id = std.mem.readInt(u32, rec[4..8], .little);
        appendPosixAclLine(allocator, &out, tag, perm, id) catch {
            out.deinit(allocator);
            return null;
        };
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        return null;
    };
}

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

/// The text a uid or gid renders as, plus whether it came from the name
/// database. Callers that align the value need that distinction and cannot
/// recover it from `name`: the numeric fallback and an account genuinely
/// named "12345" produce byte-identical strings, so only the lookup itself
/// knows which of the two it returned. Both forms live in the caller's
/// buffer.
pub const NameLookup = struct {
    name: []const u8,
    resolved: bool,
};

/// Look up a username, falling back to the uid's own digits. `resolved` is
/// false for that fallback, which is also taken when a real name is too long
/// for `buf` — a truncated name would be a wrong name, but the digits are
/// always correct.
pub fn lookupUserName(uid: u32, buf: []u8) !NameLookup {
    // A u32 needs ten digits, and the fallback below must always fit.
    std.debug.assert(buf.len >= 10);
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const c_uid = @as(std.c.uid_t, @intCast(uid));
        const pw_ptr = std.c.getpwuid(c_uid);
        if (pw_ptr) |pw| {
            // The name field is optional, check if it exists
            if (pw.name) |name_ptr| {
                const name = std.mem.span(name_ptr);
                if (name.len < buf.len) {
                    @memcpy(buf[0..name.len], name);
                    return .{ .name = buf[0..name.len], .resolved = true };
                }
            }
        }
    }
    // Fallback to uid as string
    const digits = try std.fmt.bufPrint(buf, "{d}", .{uid});
    std.debug.assert(digits.len > 0);
    return .{ .name = digits, .resolved = false };
}

/// Look up a group name, falling back to the gid's own digits, exactly as
/// lookupUserName does for a uid.
pub fn lookupGroupName(gid: u32, buf: []u8) !NameLookup {
    std.debug.assert(buf.len >= 10);
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const c_gid = @as(std.c.gid_t, @intCast(gid));
        const gr_ptr = getgrgid(c_gid);
        if (gr_ptr) |gr| {
            // The name field is optional, check if it exists
            if (gr.name) |name_ptr| {
                const name = std.mem.span(name_ptr);
                if (name.len < buf.len) {
                    @memcpy(buf[0..name.len], name);
                    return .{ .name = buf[0..name.len], .resolved = true };
                }
            }
        }
    }
    // Fallback to gid as string
    const digits = try std.fmt.bufPrint(buf, "{d}", .{gid});
    std.debug.assert(digits.len > 0);
    return .{ .name = digits, .resolved = false };
}

/// Get username from uid (returns uid as string if lookup fails). Callers
/// that must tell those two cases apart want lookupUserName instead.
pub fn getUserName(uid: u32, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len >= 10);
    const lookup = try lookupUserName(uid, buf);
    std.debug.assert(lookup.name.len > 0);
    std.debug.assert(lookup.name.len <= buf.len);
    return lookup.name;
}

/// Get group name from gid (returns gid as string if lookup fails). Callers
/// that must tell those two cases apart want lookupGroupName instead.
pub fn getGroupName(gid: u32, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len >= 10);
    const lookup = try lookupGroupName(gid, buf);
    std.debug.assert(lookup.name.len > 0);
    std.debug.assert(lookup.name.len <= buf.len);
    return lookup.name;
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

// ================================================================
// Issue #129: this file must not hand-roll libc's group ABI
// ================================================================

test "file: the group lookup uses std's platform group struct" {
    // getUserName already goes through std.c.getpwuid; the group side kept a
    // file-local `extern struct group` with a differently-optional `mem`
    // field. Pin the prototype to std's type, whether it is re-exported here
    // or reached through the shared user_group module.
    const ug = @import("user_group.zig");
    const grgid = if (@hasDecl(@This(), "getgrgid")) getgrgid else ug.getgrgid;
    const grgid_ret = @typeInfo(@TypeOf(grgid)).@"fn".return_type.?;
    try testing.expect(grgid_ret == ?*std.c.group);
    // Negative space: a group lookup must never yield a passwd record, which
    // is what std.c.getgrnam's upstream typo would do.
    try testing.expect(grgid_ret != ?*std.c.passwd);
}

test "file: getUserName and getGroupName mirror the passwd and group entries" {
    const ug = @import("user_group.zig");
    const uid = ug.getCurrentUserId();
    const gid = ug.getCurrentGroupId();

    const user_info = try ug.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);
    var user_buf: [256]u8 = undefined;
    const user_name = try getUserName(@intCast(uid), &user_buf);
    try testing.expectEqualStrings(user_info.name, user_name);

    const group_info = try ug.getGroupById(gid, testing.allocator);
    defer testing.allocator.free(group_info.name);
    var group_buf: [256]u8 = undefined;
    const group_name = try getGroupName(@intCast(gid), &group_buf);
    try testing.expectEqualStrings(group_info.name, group_name);

    // Negative space: the numeric fallback is still reachable, so the two
    // equalities above prove a real lookup rather than a stubbed-out path.
    const absent_gid: u32 = 4_000_000_000;
    if (std.c.getgrgid(@intCast(absent_gid)) == null) {
        var absent_buf: [64]u8 = undefined;
        const absent = try getGroupName(absent_gid, &absent_buf);
        try testing.expectEqualStrings("4000000000", absent);
    }
}
