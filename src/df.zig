//! df - report file system disk space usage
//!
//! The df utility displays the amount of disk space available on the
//! file system containing each file argument. With no arguments, disk
//! space is shown for all currently mounted file systems.
//!
//! This implementation follows GNU coreutils df behavior and supports
//! macOS (darwin) and Linux platforms.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = std.c;

const prog_name = "df";

// ============================================================================
// Platform-specific C interop
// ============================================================================

const MNT_LOCAL: u32 = 0x00001000;

const is_darwin = builtin.os.tag == .macos or builtin.os.tag.isDarwin();
const is_linux = builtin.os.tag == .linux;

// macOS statfs structure (matches sys/mount.h)
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

const MNT_NOWAIT: c_int = 2;

// Platform-specific C interop (wrapped to avoid linker errors on wrong platform)
const darwin_c = if (is_darwin) struct {
    extern "c" fn getfsstat(buf: ?[*]StatFs, bufsize: c_int, mode: c_int) c_int;
    extern "c" fn statfs(path: [*:0]const u8, buf: *StatFs) c_int;
} else struct {};

const linux_c = if (is_linux) struct {
    const Statvfs = extern struct {
        f_bsize: c_ulong,
        f_frsize: c_ulong,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_favail: u64,
        f_fsid: c_ulong,
        f_flag: c_ulong,
        f_namemax: c_ulong,
        __f_spare: [6]c_int = .{ 0, 0, 0, 0, 0, 0 },
    };
    extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;
} else struct {};

// ============================================================================
// Options
// ============================================================================

const BlockSize = enum {
    bytes_1k,
    si_1k,
    custom,
};

const DfOptions = struct {
    all: bool = false,
    human_readable: bool = true,
    display: common.display_config.DisplayConfig = .{ .color = .off, .icons = .off, .highlight = .off, .theme = .none },
    si: bool = false,
    inodes: bool = false,
    block_1k: bool = false,
    local: bool = false,
    no_sync: bool = false,
    portability: bool = false,
    print_type: bool = false,
    total: bool = false,
    help: bool = false,
    version: bool = false,
    block_size: ?u64 = null,
    include_type: ?[]const u8 = null,
    exclude_type: ?[]const u8 = null,
    output_fields: ?[]const u8 = null,
    thousands_grouping: bool = false,
    positionals: []const []const u8 = &.{},
};

// ============================================================================
// Filesystem info
// ============================================================================

const FsInfo = struct {
    source: []const u8,
    fstype: []const u8,
    mount_point: []const u8,
    total_blocks: u64,
    used_blocks: u64,
    avail_blocks: u64,
    block_size: u64,
    total_inodes: u64,
    used_inodes: u64,
    avail_inodes: u64,
    flags: u32,
};

// ============================================================================
// Argument parsing (manual, for complex options)
// ============================================================================

fn parseArgs(allocator: Allocator, args: []const []const u8) struct { opts: DfOptions, err: ?[]const u8 } {
    var opts = DfOptions{};
    opts.display = common.display_config.DisplayConfig.resolve(allocator);
    var err_msg: ?[]const u8 = null;
    var positionals = std.ArrayListUnmanaged([]const u8){};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0) continue;

        if (arg[0] != '-') {
            positionals.append(allocator, arg) catch {
                err_msg = "memory allocation failed";
                break;
            };
            continue;
        }

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
            } else if (std.mem.eql(u8, arg, "--all")) {
                opts.all = true;
            } else if (std.mem.eql(u8, arg, "--human-readable")) {
                opts.human_readable = true;
            } else if (std.mem.eql(u8, arg, "--si")) {
                opts.si = true;
            } else if (std.mem.eql(u8, arg, "--inodes")) {
                opts.inodes = true;
            } else if (std.mem.eql(u8, arg, "--local")) {
                opts.local = true;
            } else if (std.mem.eql(u8, arg, "--portability")) {
                opts.portability = true;
                opts.human_readable = false;
                opts.display.color = .off;
                opts.display.icons = .off;
                opts.display.highlight = .off;
                opts.display.theme = .none;
            } else if (std.mem.eql(u8, arg, "--print-type")) {
                opts.print_type = true;
            } else if (std.mem.eql(u8, arg, "--total")) {
                opts.total = true;
            } else if (std.mem.startsWith(u8, arg, "--block-size=")) {
                const val = arg["--block-size=".len..];
                opts.block_size = parseBlockSize(val) orelse {
                    err_msg = "invalid --block-size argument";
                    break;
                };
                opts.human_readable = false;
            } else if (std.mem.eql(u8, arg, "--block-size")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.block_size = parseBlockSize(args[i]) orelse {
                        err_msg = "invalid --block-size argument";
                        break;
                    };
                    opts.human_readable = false;
                } else {
                    err_msg = "option '--block-size' requires an argument";
                    break;
                }
            } else if (std.mem.startsWith(u8, arg, "--type=")) {
                opts.include_type = arg["--type=".len..];
            } else if (std.mem.eql(u8, arg, "--type")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.include_type = args[i];
                } else {
                    err_msg = "option '--type' requires an argument";
                    break;
                }
            } else if (std.mem.startsWith(u8, arg, "--exclude-type=")) {
                opts.exclude_type = arg["--exclude-type=".len..];
            } else if (std.mem.eql(u8, arg, "--exclude-type")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.exclude_type = args[i];
                } else {
                    err_msg = "option '--exclude-type' requires an argument";
                    break;
                }
            } else if (std.mem.startsWith(u8, arg, "--output=")) {
                opts.output_fields = arg["--output=".len..];
            } else if (std.mem.eql(u8, arg, "--output")) {
                // --output without = uses default field list
                opts.output_fields = "source,fstype,size,used,avail,pcent,target";
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
                'a' => opts.all = true,
                'h' => opts.human_readable = true,
                'H' => opts.si = true,
                'i' => opts.inodes = true,
                'k' => {
                    opts.block_1k = true;
                    opts.human_readable = false;
                },
                'l' => opts.local = true,
                'n' => {
                    if (comptime is_linux) {
                        err_msg = "unrecognized option";
                        break;
                    }
                    opts.no_sync = true;
                },
                'P' => {
                    opts.portability = true;
                    opts.human_readable = false;
                    opts.display.color = .off;
                    opts.display.icons = .off;
                    opts.display.highlight = .off;
                    opts.display.theme = .none;
                },
                'T' => opts.print_type = true,
                't' => {
                    if (j + 1 < arg.len) {
                        opts.include_type = arg[j + 1 ..];
                        j = arg.len;
                        break;
                    } else if (i + 1 < args.len) {
                        i += 1;
                        opts.include_type = args[i];
                    } else {
                        err_msg = "option '-t' requires an argument";
                    }
                    j = arg.len;
                    break;
                },
                'x' => {
                    if (j + 1 < arg.len) {
                        opts.exclude_type = arg[j + 1 ..];
                        j = arg.len;
                        break;
                    } else if (i + 1 < args.len) {
                        i += 1;
                        opts.exclude_type = args[i];
                    } else {
                        err_msg = "option '-x' requires an argument";
                    }
                    j = arg.len;
                    break;
                },
                'b' => {
                    opts.block_size = 512;
                    opts.human_readable = false;
                },
                'c' => opts.total = true,
                'g' => {
                    opts.block_size = 1024 * 1024 * 1024;
                    opts.human_readable = false;
                },
                'I' => {
                    if (j + 1 < arg.len) {
                        opts.exclude_type = arg[j + 1 ..];
                        j = arg.len;
                        break;
                    } else if (i + 1 < args.len) {
                        i += 1;
                        opts.exclude_type = args[i];
                    } else {
                        err_msg = "option '-I' requires an argument";
                    }
                    j = arg.len;
                    break;
                },
                'm' => {
                    opts.block_size = 1024 * 1024;
                    opts.human_readable = false;
                },
                'Y' => {}, // no-op: don't resolve NFS paths
                ',' => opts.thousands_grouping = true,
                else => {
                    err_msg = "unrecognized option";
                    break;
                },
            }
        }
        if (err_msg != null) break;
    }

    opts.positionals = positionals.toOwnedSlice(allocator) catch {
        err_msg = "memory allocation failed";
        positionals.deinit(allocator);
        return .{ .opts = opts, .err = err_msg };
    };

    return .{ .opts = opts, .err = err_msg };
}

/// Parse a block size string like "1K", "1M", "1G", or a plain number
fn parseBlockSize(s: []const u8) ?u64 {
    return common.format.parseBlockSize(s);
}

// ============================================================================
// Filesystem enumeration (platform-specific)
// ============================================================================

fn getMountedFilesystems(allocator: Allocator) ![]FsInfo {
    if (comptime is_darwin) {
        return getMountedFilesystemsDarwin(allocator);
    } else if (comptime is_linux) {
        return getMountedFilesystemsLinux(allocator);
    } else {
        @compileError("df: unsupported platform");
    }
}

fn getMountedFilesystemsDarwin(allocator: Allocator) ![]FsInfo {
    // First call to get count
    const count = darwin_c.getfsstat(null, 0, MNT_NOWAIT);
    if (count < 0) return error.SystemResources;
    if (count == 0) return allocator.alloc(FsInfo, 0);

    const ucount: usize = @intCast(count);
    const buf = try allocator.alloc(StatFs, ucount);
    defer allocator.free(buf);

    const bufsize: c_int = @intCast(ucount * @sizeOf(StatFs));
    const actual = darwin_c.getfsstat(buf.ptr, bufsize, MNT_NOWAIT);
    if (actual < 0) return error.SystemResources;

    const actual_count: usize = @intCast(actual);
    var result = std.ArrayListUnmanaged(FsInfo){};

    for (buf[0..actual_count]) |*fs| {
        // Dupe strings so they outlive the getfsstat buffer
        const source = try allocator.dupe(u8, extractCString(&fs.f_mntfromname));
        const mount_point = try allocator.dupe(u8, extractCString(&fs.f_mntonname));
        const fstype = try allocator.dupe(u8, extractCString(&fs.f_fstypename));

        try result.append(allocator, FsInfo{
            .source = source,
            .fstype = fstype,
            .mount_point = mount_point,
            .total_blocks = fs.f_blocks,
            .used_blocks = fs.f_blocks -| fs.f_bfree,
            .avail_blocks = fs.f_bavail,
            .block_size = fs.f_bsize,
            .total_inodes = fs.f_files,
            .used_inodes = fs.f_files -| fs.f_ffree,
            .avail_inodes = fs.f_ffree,
            .flags = fs.f_flags,
        });
    }

    return result.toOwnedSlice(allocator);
}

fn getFilesystemForPath(allocator: Allocator, path: []const u8) !FsInfo {
    if (comptime is_darwin) {
        return getFilesystemForPathDarwin(allocator, path);
    } else if (comptime is_linux) {
        return getFilesystemForPathLinux(allocator, path);
    } else {
        @compileError("df: unsupported platform");
    }
}

fn getFilesystemForPathDarwin(allocator: Allocator, path: []const u8) !FsInfo {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    var sfs: StatFs = undefined;
    const ret = darwin_c.statfs(c_path, &sfs);
    if (ret != 0) {
        return switch (std.posix.errno(ret)) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            else => error.SystemResources,
        };
    }

    // Dupe strings so they outlive the stack-local StatFs
    return FsInfo{
        .source = try allocator.dupe(u8, extractCString(&sfs.f_mntfromname)),
        .fstype = try allocator.dupe(u8, extractCString(&sfs.f_fstypename)),
        .mount_point = try allocator.dupe(u8, extractCString(&sfs.f_mntonname)),
        .total_blocks = sfs.f_blocks,
        .used_blocks = sfs.f_blocks -| sfs.f_bfree,
        .avail_blocks = sfs.f_bavail,
        .block_size = sfs.f_bsize,
        .total_inodes = sfs.f_files,
        .used_inodes = sfs.f_files -| sfs.f_ffree,
        .avail_inodes = sfs.f_ffree,
        .flags = sfs.f_flags,
    };
}

fn freeFsInfo(allocator: Allocator, fs: FsInfo) void {
    allocator.free(fs.source);
    allocator.free(fs.fstype);
    allocator.free(fs.mount_point);
}

fn freeFsInfoSlice(allocator: Allocator, infos: []const FsInfo) void {
    for (infos) |fs| {
        freeFsInfo(allocator, fs);
    }
    allocator.free(infos);
}

fn extractCString(buf: []const u8) []const u8 {
    for (buf, 0..) |byte, idx| {
        if (byte == 0) return buf[0..idx];
    }
    return buf;
}

// ============================================================================
// Linux filesystem enumeration
// ============================================================================

fn getMountedFilesystemsLinux(allocator: Allocator) ![]FsInfo {
    const file = std.fs.cwd().openFile("/proc/mounts", .{}) catch {
        return error.SystemResources;
    };
    defer file.close();

    var buf: [32768]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return error.SystemResources;
    const content = buf[0..bytes_read];

    var result = std.ArrayListUnmanaged(FsInfo){};

    // /proc/mounts format: device mountpoint fstype options dump pass
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        var iter = std.mem.splitScalar(u8, line, ' ');
        const source_raw = iter.next() orelse continue;
        const mount_point_raw = iter.next() orelse continue;
        const fstype_raw = iter.next() orelse continue;

        // statvfs the mount point
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (mount_point_raw.len > std.fs.max_path_bytes) continue;
        @memcpy(path_buf[0..mount_point_raw.len], mount_point_raw);
        path_buf[mount_point_raw.len] = 0;
        const c_path = path_buf[0..mount_point_raw.len :0];

        var svfs: linux_c.Statvfs = undefined;
        const ret = linux_c.statvfs(c_path, &svfs);
        if (ret != 0) continue; // skip mount points we can't stat

        const source = allocator.dupe(u8, source_raw) catch return error.OutOfMemory;
        const mount_point = allocator.dupe(u8, mount_point_raw) catch return error.OutOfMemory;
        const fstype = allocator.dupe(u8, fstype_raw) catch return error.OutOfMemory;

        try result.append(allocator, FsInfo{
            .source = source,
            .fstype = fstype,
            .mount_point = mount_point,
            .total_blocks = svfs.f_blocks,
            .used_blocks = svfs.f_blocks -| svfs.f_bfree,
            .avail_blocks = svfs.f_bavail,
            .block_size = svfs.f_frsize,
            .total_inodes = svfs.f_files,
            .used_inodes = svfs.f_files -| svfs.f_ffree,
            .avail_inodes = svfs.f_ffree,
            .flags = 0,
        });
    }

    return result.toOwnedSlice(allocator);
}

fn getFilesystemForPathLinux(allocator: Allocator, path: []const u8) !FsInfo {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    var svfs: linux_c.Statvfs = undefined;
    const ret = linux_c.statvfs(c_path, &svfs);
    if (ret != 0) {
        return error.SystemResources;
    }

    // Find the source device and fstype by reading /proc/mounts and
    // matching the longest mount point prefix of the path.
    var best_source: []const u8 = "unknown";
    var best_mount: []const u8 = path;
    var best_fstype: []const u8 = "unknown";
    var best_len: usize = 0;

    const file = std.fs.cwd().openFile("/proc/mounts", .{}) catch {
        // Can't read mounts, return with what we have from statvfs
        return FsInfo{
            .source = try allocator.dupe(u8, "unknown"),
            .fstype = try allocator.dupe(u8, "unknown"),
            .mount_point = try allocator.dupe(u8, path),
            .total_blocks = svfs.f_blocks,
            .used_blocks = svfs.f_blocks -| svfs.f_bfree,
            .avail_blocks = svfs.f_bavail,
            .block_size = svfs.f_frsize,
            .total_inodes = svfs.f_files,
            .used_inodes = svfs.f_files -| svfs.f_ffree,
            .avail_inodes = svfs.f_ffree,
            .flags = 0,
        };
    };
    defer file.close();

    var buf: [32768]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch 0;
    const content = buf[0..bytes_read];

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        var iter = std.mem.splitScalar(u8, line, ' ');
        const src = iter.next() orelse continue;
        const mnt = iter.next() orelse continue;
        const fst = iter.next() orelse continue;

        // Find longest matching mount point prefix
        if (std.mem.startsWith(u8, path, mnt) and mnt.len > best_len) {
            best_source = src;
            best_mount = mnt;
            best_fstype = fst;
            best_len = mnt.len;
        }
    }

    return FsInfo{
        .source = try allocator.dupe(u8, best_source),
        .fstype = try allocator.dupe(u8, best_fstype),
        .mount_point = try allocator.dupe(u8, best_mount),
        .total_blocks = svfs.f_blocks,
        .used_blocks = svfs.f_blocks -| svfs.f_bfree,
        .avail_blocks = svfs.f_bavail,
        .block_size = svfs.f_frsize,
        .total_inodes = svfs.f_files,
        .used_inodes = svfs.f_files -| svfs.f_ffree,
        .avail_inodes = svfs.f_ffree,
        .flags = 0,
    };
}

// ============================================================================
// Filtering
// ============================================================================

fn shouldIncludeFs(fs: FsInfo, opts: DfOptions) bool {
    // Skip pseudo filesystems unless -a
    if (!opts.all) {
        if (fs.total_blocks == 0) return false;
        // Skip common pseudo fs types
        if (isPseudoFs(fs.fstype)) return false;
    }

    // -l: local only
    if (opts.local) {
        if (comptime is_darwin) {
            if (fs.flags & MNT_LOCAL == 0) return false;
        } else {
            // On Linux, check fstype for network filesystems
            if (isNetworkFs(fs.fstype)) return false;
        }
    }

    // -t TYPE: include only this type
    if (opts.include_type) |t| {
        if (!std.mem.eql(u8, fs.fstype, t)) return false;
    }

    // -x TYPE: exclude this type
    if (opts.exclude_type) |t| {
        if (std.mem.eql(u8, fs.fstype, t)) return false;
    }

    return true;
}

fn isPseudoFs(fstype: []const u8) bool {
    const pseudo_types = [_][]const u8{
        "devfs",    "autofs",    "devpts",      "proc",
        "sysfs",    "tmpfs",     "debugfs",     "securityfs",
        "cgroup",   "cgroup2",   "pstore",      "bpf",
        "tracefs",  "hugetlbfs", "mqueue",      "fusectl",
        "configfs", "efivarfs",  "binfmt_misc",
    };
    for (pseudo_types) |pt| {
        if (std.mem.eql(u8, fstype, pt)) return true;
    }
    return false;
}

fn isNetworkFs(fstype: []const u8) bool {
    const network_types = [_][]const u8{
        "nfs", "nfs4", "cifs", "smbfs", "ncpfs", "afs", "coda", "gfs", "gfs2",
    };
    for (network_types) |nt| {
        if (std.mem.eql(u8, fstype, nt)) return true;
    }
    return false;
}

// ============================================================================
// Filesystem classification
// ============================================================================

const FsClass = enum {
    local,
    network,
    cloud,
    virtual,
    backup,
    snapshot,
};

fn classifyFs(source: []const u8, fstype: []const u8, mount_point: []const u8) FsClass {
    // Time Machine checks first — snapshots and backups may sit on
    // network or local filesystems, but the TM role takes priority.
    if (isTimeMachineSnapshot(source)) return .snapshot;
    if (isTimeMachineBackup(source, mount_point)) return .backup;
    if (isNetworkFs(fstype)) return .network;
    if (isCloudFs(source, fstype)) return .cloud;
    if (isPseudoFs(fstype)) return .virtual;
    return .local;
}

fn isTimeMachineSnapshot(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "com.apple.TimeMachine");
}

fn isTimeMachineBackup(source: []const u8, mount_point: []const u8) bool {
    // Check mount point for backup-related patterns
    if (containsCaseInsensitive(mount_point, "Backups")) return true;
    if (containsCaseInsensitive(mount_point, "Time Machine")) return true;
    if (containsCaseInsensitive(mount_point, "timemachine")) return true;
    // Check source for TM-related patterns
    if (containsCaseInsensitive(source, "Time")) {
        if (containsCaseInsensitive(source, "Machine")) return true;
    }
    return false;
}

/// Case-insensitive substring search (ASCII only).
fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const h = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const n = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (h != n) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn isCloudFs(source: []const u8, fstype: []const u8) bool {
    // FUSE-based cloud mounts
    if (std.mem.startsWith(u8, fstype, "fuse.")) return true;
    // OrbStack/VM filesystems
    const cloud_types = [_][]const u8{ "virtiofs", "9p" };
    for (cloud_types) |ct| {
        if (std.mem.eql(u8, fstype, ct)) return true;
    }
    // Source-name patterns for cloud/VM mounts
    const cloud_sources = [_][]const u8{ "OrbStack", "rclone", "sshfs" };
    for (cloud_sources) |cs| {
        if (std.mem.startsWith(u8, source, cs)) return true;
    }
    return false;
}

// ============================================================================
// Darwin volume grouping
// ============================================================================

/// Extract the device prefix from a source path (e.g., "/dev/disk3s1" -> "/dev/disk3").
/// Returns the input unchanged if no partition suffix is found.
fn extractDevicePrefix(source: []const u8) []const u8 {
    // Look for pattern like "diskNsM" and strip the "sM" part
    if (std.mem.indexOf(u8, source, "disk")) |disk_start| {
        var i = disk_start + 4; // skip "disk"
        // Skip disk number digits
        while (i < source.len and source[i] >= '0' and source[i] <= '9') : (i += 1) {}
        // If we hit 's' followed by digits, that's a partition suffix
        if (i < source.len and source[i] == 's') {
            return source[0..i];
        }
    }
    return source;
}

/// Group macOS volumes that share the same device and size, keeping the most
/// relevant mount point (preferring "/" or shortest path).
fn groupDarwinVolumes(allocator: Allocator, filesystems: []const FsInfo) ![]FsInfo {
    // Key: "device_prefix:total_bytes" -> best entry index in result
    var groups = std.StringHashMapUnmanaged(usize){};
    defer {
        var it = groups.keyIterator();
        while (it.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        groups.deinit(allocator);
    }

    var result = std.ArrayListUnmanaged(FsInfo){};
    errdefer result.deinit(allocator);

    for (filesystems) |fs| {
        const prefix = extractDevicePrefix(fs.source);
        const total_bytes = fs.total_blocks * fs.block_size;

        // Create compound key: "prefix:total_bytes"
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ prefix, total_bytes }) catch {
            try result.append(allocator, fs);
            continue;
        };
        const key_owned = try allocator.dupe(u8, key);

        if (groups.get(key_owned)) |existing_idx| {
            allocator.free(key_owned);
            // Check if current entry is better (shorter mount path or exactly "/")
            const existing = result.items[existing_idx];
            if (std.mem.eql(u8, fs.mount_point, "/") or
                (!std.mem.eql(u8, existing.mount_point, "/") and
                    fs.mount_point.len < existing.mount_point.len))
            {
                result.items[existing_idx] = fs;
            }
        } else {
            const new_idx = result.items.len;
            try groups.put(allocator, key_owned, new_idx);
            try result.append(allocator, fs);
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Human-readable formatting
// ============================================================================

fn formatHumanReadable(buf: []u8, bytes: u64, use_si: bool) []const u8 {
    return common.format.formatHumanReadable(buf, bytes, .{ .si = use_si });
}

/// Format a u64 with thousands grouping (commas): 1234567 -> "1,234,567"
fn formatWithCommas(buf: []u8, value: u64) []const u8 {
    // First format the number without commas into a temp buffer
    var num_buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return "?";

    if (digits.len <= 3) {
        @memcpy(buf[0..digits.len], digits);
        return buf[0..digits.len];
    }

    // Calculate output length: digits + number of commas
    const num_commas = @divTrunc(digits.len - 1, 3);
    const out_len = digits.len + num_commas;
    if (out_len > buf.len) return "?";

    // Fill from right to left
    var src: usize = digits.len;
    var dst: usize = out_len;
    var count: usize = 0;

    while (src > 0) {
        src -= 1;
        dst -= 1;
        buf[dst] = digits[src];
        count += 1;
        if (count == 3 and src > 0) {
            dst -= 1;
            buf[dst] = ',';
            count = 0;
        }
    }

    return buf[0..out_len];
}

fn formatSize(buf: []u8, blocks: u64, fs_block_size: u64, opts: DfOptions) []const u8 {
    const bytes = blocks * fs_block_size;

    if (opts.human_readable) {
        return formatHumanReadable(buf, bytes, false);
    }
    if (opts.si) {
        return formatHumanReadable(buf, bytes, true);
    }

    // Display in block_size units
    const display_block: u64 = if (opts.block_size) |bs|
        bs
    else if (opts.block_1k)
        1024
    else
        1024;

    const value = @divTrunc(bytes + display_block - 1, display_block);

    if (opts.thousands_grouping) {
        return formatWithCommas(buf, value);
    }

    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

/// Calculate usage percentage as 0-100 with ceiling (matching GNU df).
fn calcUsagePercent(used: u64, total: u64) u8 {
    if (total == 0) return 0;
    const pct = @divTrunc(used * 100 + total - 1, total);
    return @intCast(@min(pct, 100));
}

fn formatPercent(buf: []u8, used: u64, total: u64) []const u8 {
    if (total == 0) return "-";
    const pct = calcUsagePercent(used, total);
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "?";
}

/// Format a usage bar like [████████░░] 84%
fn formatUsageBar(buf: []u8, percent: u8) []const u8 {
    const bar_width: u8 = 10;
    const filled: u8 = @intCast(@divTrunc(@as(u16, percent) * bar_width + 99, 100));
    const empty: u8 = bar_width - filled;

    var pos: usize = 0;

    // Opening bracket
    buf[pos] = '[';
    pos += 1;

    // Filled blocks (█ = 0xe2 0x96 0x88)
    for (0..filled) |_| {
        buf[pos] = 0xe2;
        buf[pos + 1] = 0x96;
        buf[pos + 2] = 0x88;
        pos += 3;
    }

    // Empty blocks (░ = 0xe2 0x96 0x91)
    for (0..empty) |_| {
        buf[pos] = 0xe2;
        buf[pos + 1] = 0x96;
        buf[pos + 2] = 0x91;
        pos += 3;
    }

    // Closing bracket + space + percent
    buf[pos] = ']';
    pos += 1;
    buf[pos] = ' ';
    pos += 1;

    // Format percent number
    const pct_str = std.fmt.bufPrint(buf[pos..], "{d:>3}%", .{percent}) catch return buf[0..pos];
    pos += pct_str.len;

    return buf[0..pos];
}

/// Apply color based on usage percentage threshold.
/// Green (0-69%), Yellow (70-89%), Red (90%+).
fn applyUsageColor(s: anytype, percent: u8) !void {
    switch (s.color_mode) {
        .truecolor => {
            if (percent < 70) {
                try s.setRgb(115, 195, 120);
            } else if (percent < 90) {
                try s.setRgb(210, 185, 90);
            } else {
                try s.setRgb(210, 95, 90);
            }
        },
        .extended => {
            if (percent < 70) {
                try s.set256(114);
            } else if (percent < 90) {
                try s.set256(220);
            } else {
                try s.set256(196);
            }
        },
        .basic => {
            if (percent < 70) {
                try s.setColor(.green);
            } else if (percent < 90) {
                try s.setColor(.yellow);
            } else {
                try s.setColor(.red);
            }
        },
        .none => {},
    }
}

/// Truncate long mount paths with "..." prefix.
/// Short paths pass through unchanged. Long paths become "...tail".
fn truncatePath(buf: []u8, path: []const u8, max_width: usize) []const u8 {
    if (path.len <= max_width) return path;
    if (max_width <= 3) return path[path.len - max_width ..];

    const tail_len = max_width - 3; // room for "..."
    const start = path.len - tail_len;
    buf[0] = '.';
    buf[1] = '.';
    buf[2] = '.';
    @memcpy(buf[3..][0..tail_len], path[start..]);
    return buf[0..max_width];
}

// ============================================================================
// Smart name formatting
// ============================================================================

/// Smart format for filesystem source names.
/// If it fits, return unchanged. For Time Machine paths like
/// "com.apple.TimeMachine@/dev/disk5s1", extract the device.
/// Otherwise keep tail with "~" prefix.
fn smartFormatSource(buf: []u8, source: []const u8, max_width: usize) []const u8 {
    const effective_max = @min(max_width, buf.len);
    if (source.len <= effective_max) return source;
    if (effective_max <= 1) return source[source.len - effective_max ..];

    // Time Machine: extract device from "prefix@/dev/..."
    if (std.mem.indexOf(u8, source, "@/dev/")) |at_pos| {
        const device = source[at_pos + 1 ..]; // "/dev/..."
        if (device.len <= effective_max) return device;
    }

    // Generic: keep tail with ~ prefix
    const tail_len = effective_max - 1; // room for "~"
    const start = source.len - tail_len;
    buf[0] = '~';
    @memcpy(buf[1..][0..tail_len], source[start..]);
    return buf[0..effective_max];
}

/// Smart format for mount points.
/// If it fits, return unchanged. Walk backwards keeping last
/// path components. Prefix with "~" instead of "...".
fn smartFormatMount(buf: []u8, mount: []const u8, max_width: usize) []const u8 {
    const effective_max = @min(max_width, buf.len);
    if (mount.len <= effective_max) return mount;
    if (effective_max <= 1) return mount[mount.len - effective_max ..];

    // Walk backwards keeping last path components
    var last_slash = mount.len;
    while (last_slash > 0) {
        last_slash -= 1;
        if (mount[last_slash] == '/') {
            const tail = mount[last_slash..];
            if (tail.len + 1 <= effective_max) {
                buf[0] = '~';
                @memcpy(buf[1..][0..tail.len], tail);
                return buf[0 .. tail.len + 1];
            }
        }
    }

    // Fallback: just keep tail with ~ prefix
    const tail_len = effective_max - 1;
    const start = mount.len - tail_len;
    buf[0] = '~';
    @memcpy(buf[1..][0..tail_len], mount[start..]);
    return buf[0..effective_max];
}

// ============================================================================
// Dynamic column widths
// ============================================================================

const ColumnWidths = struct {
    filesystem: usize = 10, // "Filesystem" header
    fs_type: usize = 4, // "Type" header
    size: usize = 4, // "Size" header
    used: usize = 4, // "Used" header
    avail: usize = 5, // "Avail" header
    use_pct: usize = 4, // "Use%" header
    usage_bar: usize = 12, // "[████████░░]" fixed
    mount: usize = 10, // "Mounted on" header
};

fn computeColumnWidths(filesystems: []const FsInfo, opts: DfOptions) ColumnWidths {
    var widths = ColumnWidths{};

    for (filesystems) |fs| {
        widths.filesystem = @max(widths.filesystem, fs.source.len);
        widths.mount = @max(widths.mount, fs.mount_point.len);
        if (opts.print_type) {
            widths.fs_type = @max(widths.fs_type, fs.fstype.len);
        }
        // Size columns: format and measure
        var size_buf: [32]u8 = undefined;
        widths.size = @max(widths.size, formatSize(&size_buf, fs.total_blocks, fs.block_size, opts).len);
        var used_buf: [32]u8 = undefined;
        widths.used = @max(widths.used, formatSize(&used_buf, fs.used_blocks, fs.block_size, opts).len);
        var avail_buf: [32]u8 = undefined;
        widths.avail = @max(widths.avail, formatSize(&avail_buf, fs.avail_blocks, fs.block_size, opts).len);
    }
    return widths;
}

fn capWidthsToTerminal(allocator: Allocator, widths: *ColumnWidths, opts: DfOptions) void {
    // In portability mode, never truncate paths
    if (opts.portability) return;

    // Only cap when stdout is a real terminal
    if (!std.fs.File.stdout().isTty()) return;

    const term_width: usize = @intCast(common.terminal.getWidth(allocator) catch 80);

    // Calculate total line width
    var total: usize = widths.filesystem + 2 + widths.size + 2 + widths.used + 2 + widths.avail + 2 + widths.use_pct + 2 + widths.mount;
    if (opts.print_type) total += widths.fs_type + 2;
    if (opts.display.icons == .on) total += 2 + widths.usage_bar + 2; // icon spacer + bar

    if (total <= term_width) return;

    const excess = total - term_width;
    // Shrink filesystem and mount proportionally
    const shrinkable = widths.filesystem + widths.mount;
    if (shrinkable <= 20) return; // Don't shrink below minimums

    const fs_share = @divTrunc(excess * widths.filesystem, shrinkable);
    const mnt_share = excess -| fs_share;

    widths.filesystem = @max(10, widths.filesystem -| fs_share);
    widths.mount = @max(10, widths.mount -| mnt_share);
}

/// Write a string right-padded to the given width.
fn padRight(writer: anytype, str: []const u8, width: usize) !void {
    try writer.writeAll(str);
    const display_w = common.unicode.displayWidth(str);
    if (display_w < width) {
        for (0..width - display_w) |_| try writer.writeAll(" ");
    }
}

/// Write a string left-padded (right-aligned) to the given width.
fn padLeft(writer: anytype, str: []const u8, width: usize) !void {
    const display_w = common.unicode.displayWidth(str);
    if (display_w < width) {
        for (0..width - display_w) |_| try writer.writeAll(" ");
    }
    try writer.writeAll(str);
}

// ============================================================================
// Gradient usage bar
// ============================================================================

/// RGB color for gradient interpolation.
const Rgb = struct { r: u8, g: u8, b: u8 };

/// Clamp a float to u8 range (0-255) for safe RGB conversion.
fn clampU8(val: f32) u8 {
    if (val <= 0.0) return 0;
    if (val >= 255.0) return 255;
    return @intFromFloat(val);
}

/// Interpolate usage bar gradient color.
/// 0-70%: green (100,200,100) -> yellow (220,200,60)
/// 70-85%: yellow -> orange (230,150,50)
/// 85-100%: orange -> red (220,60,60)
fn usageGradientRgb(pct: u8) Rgb {
    if (pct <= 70) {
        const t: f32 = @as(f32, @floatFromInt(pct)) / 70.0;
        return .{
            .r = clampU8(100.0 + t * 120.0),
            .g = 200,
            .b = clampU8(100.0 - t * 40.0),
        };
    } else if (pct <= 85) {
        const t: f32 = @as(f32, @floatFromInt(pct - 70)) / 15.0;
        return .{
            .r = clampU8(220.0 + t * 10.0),
            .g = clampU8(200.0 - t * 50.0),
            .b = clampU8(60.0 - t * 10.0),
        };
    } else {
        const t: f32 = @as(f32, @floatFromInt(pct - 85)) / 15.0;
        return .{
            .r = clampU8(230.0 - t * 10.0),
            .g = clampU8(150.0 - t * 90.0),
            .b = clampU8(50.0 + t * 10.0),
        };
    }
}

/// Write a colored usage bar directly to the writer.
/// Each filled block gets individually colored via gradient.
/// Empty blocks are dim gray.
fn writeColoredUsageBar(writer: anytype, s: anytype, percent: u8) !void {
    const bar_width: u8 = 10;
    const filled: u8 = @intCast(@divTrunc(@as(u16, percent) * bar_width + 99, 100));
    const empty: u8 = bar_width - filled;

    try writer.writeAll("[");

    // Filled blocks with gradient coloring
    for (0..filled) |i| {
        // Calculate the percentage this block represents
        const block_pct: u8 = @intCast(@min(@divTrunc((@as(u16, @intCast(i)) + 1) * 100, bar_width), 100));
        const rgb = usageGradientRgb(block_pct);

        switch (s.color_mode) {
            .truecolor => try s.setRgb(rgb.r, rgb.g, rgb.b),
            .extended => {
                // 3-tier for 256 color
                if (block_pct < 70) {
                    try s.set256(114); // green
                } else if (block_pct < 90) {
                    try s.set256(220); // yellow
                } else {
                    try s.set256(196); // red
                }
            },
            .basic => {
                if (block_pct < 70) {
                    try s.setColor(.green);
                } else if (block_pct < 90) {
                    try s.setColor(.yellow);
                } else {
                    try s.setColor(.red);
                }
            },
            .none => {},
        }
        // U+2588 FULL BLOCK
        try writer.writeAll("\xe2\x96\x88");
    }

    if (filled > 0) try s.reset();

    // Empty blocks in dim gray
    if (empty > 0) {
        switch (s.color_mode) {
            .truecolor => try s.setRgb(80, 80, 80),
            .extended => try s.set256(240),
            .basic => try s.setColor(.bright_black),
            .none => {},
        }
        for (0..empty) |_| {
            // U+2591 LIGHT SHADE
            try writer.writeAll("\xe2\x96\x91");
        }
        try s.reset();
    }

    try writer.writeAll("]");
}

// ============================================================================
// Colored output helpers
// ============================================================================

/// Get icon for filesystem class.
fn getFsIcon(fs_class: FsClass) []const u8 {
    const theme = common.icons.IconTheme{};
    return switch (fs_class) {
        .local => theme.disk,
        .network => theme.network_fs,
        .cloud => theme.cloud,
        .virtual => theme.virtual_fs,
        .backup => theme.backup,
        .snapshot => theme.snapshot,
    };
}

/// Apply source name color based on FsClass.
fn applySourceColor(s: anytype, fs_class: FsClass) !void {
    switch (s.color_mode) {
        .truecolor => switch (fs_class) {
            .local => try s.setRgb(180, 200, 220),
            .network => try s.setRgb(180, 130, 210),
            .cloud => try s.setRgb(120, 180, 220),
            .virtual => try s.setRgb(120, 120, 120),
            .backup => try s.setRgb(200, 170, 80),
            .snapshot => try s.setRgb(160, 145, 110),
        },
        .extended => switch (fs_class) {
            .local => try s.set256(152),
            .network => try s.set256(140),
            .cloud => try s.set256(117),
            .virtual => try s.set256(245),
            .backup => try s.set256(178),
            .snapshot => try s.set256(144),
        },
        .basic => switch (fs_class) {
            .local => try s.setColor(.bright_white),
            .network => try s.setColor(.bright_magenta),
            .cloud => try s.setColor(.bright_cyan),
            .virtual => try s.setColor(.bright_black),
            .backup => try s.setColor(.yellow),
            .snapshot => try s.setColor(.yellow),
        },
        .none => {},
    }
}

/// Apply mount point color based on FsClass.
fn applyMountColor(s: anytype, fs_class: FsClass) !void {
    switch (s.color_mode) {
        .truecolor => switch (fs_class) {
            .local => try s.setRgb(110, 160, 220),
            .network => try s.setRgb(180, 130, 210),
            .cloud => try s.setRgb(120, 180, 220),
            .virtual => try s.setRgb(120, 120, 120),
            .backup => try s.setRgb(180, 150, 70),
            .snapshot => try s.setRgb(145, 130, 100),
        },
        .extended => switch (fs_class) {
            .local => try s.set256(110),
            .network => try s.set256(140),
            .cloud => try s.set256(117),
            .virtual => try s.set256(245),
            .backup => try s.set256(178),
            .snapshot => try s.set256(137),
        },
        .basic => switch (fs_class) {
            .local => try s.setColor(.bright_blue),
            .network => try s.setColor(.bright_magenta),
            .cloud => try s.setColor(.bright_cyan),
            .virtual => try s.setColor(.bright_black),
            .backup => try s.setColor(.yellow),
            .snapshot => try s.setColor(.yellow),
        },
        .none => {},
    }
}

/// Apply dim gray color for type column.
fn applyTypeColor(s: anytype) !void {
    switch (s.color_mode) {
        .truecolor => try s.setRgb(120, 120, 120),
        .extended => try s.set256(245),
        .basic => try s.setColor(.bright_black),
        .none => {},
    }
}

// ============================================================================
// Output formatting
// ============================================================================

fn printHeader(stdout: anytype, opts: DfOptions) !void {
    if (opts.inodes) {
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                "Filesystem",
                "Type",
                "Inodes",
                "IUsed",
                "IFree",
                "IUse%",
                "Mounted on",
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                "Filesystem",
                "Inodes",
                "IUsed",
                "IFree",
                "IUse%",
                "Mounted on",
            });
        }
        return;
    }

    var size_label_buf: [32]u8 = undefined;
    const size_label: []const u8 = blk: {
        if (opts.human_readable or opts.si) {
            break :blk "Size";
        }
        if (opts.block_size) |bs| {
            if (bs == 512) break :blk "512B-blocks";
            if (bs == 1024) break :blk "1K-blocks";
            if (bs == 1024 * 1024) break :blk "1M-blocks";
            if (bs == 1024 * 1024 * 1024) break :blk "1G-blocks";
            break :blk std.fmt.bufPrint(&size_label_buf, "{d}B-blocks", .{bs}) catch "blocks";
        }
        if (opts.portability) break :blk "1024-blocks";
        break :blk "1K-blocks";
    };
    const pct_label: []const u8 = if (opts.portability) "Capacity" else "Use%";

    if (opts.display.icons == .on) {
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s:>17} {s}\n", .{
                "Filesystem",
                "Type",
                size_label,
                "Used",
                "Available",
                pct_label,
                "Usage",
                "Mounted on",
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s:>17} {s}\n", .{
                "Filesystem",
                size_label,
                "Used",
                "Available",
                pct_label,
                "Usage",
                "Mounted on",
            });
        }
    } else {
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                "Filesystem",
                "Type",
                size_label,
                "Used",
                "Available",
                pct_label,
                "Mounted on",
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                "Filesystem",
                size_label,
                "Used",
                "Available",
                pct_label,
                "Mounted on",
            });
        }
    }
}

fn printFsRow(stdout: anytype, fs: FsInfo, opts: DfOptions, color_mode_int: u8) !void {
    if (opts.inodes) {
        var pct_buf: [16]u8 = undefined;
        const pct = formatPercent(&pct_buf, fs.used_inodes, fs.total_inodes);
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {d:>10} {d:>10} {d:>10} {s:>5} {s}\n", .{
                fs.source,
                fs.fstype,
                fs.total_inodes,
                fs.used_inodes,
                fs.avail_inodes,
                pct,
                fs.mount_point,
            });
        } else {
            try stdout.print("{s:<15} {d:>10} {d:>10} {d:>10} {s:>5} {s}\n", .{
                fs.source,
                fs.total_inodes,
                fs.used_inodes,
                fs.avail_inodes,
                pct,
                fs.mount_point,
            });
        }
        return;
    }

    var total_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var avail_buf: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;

    const total_str = formatSize(&total_buf, fs.total_blocks, fs.block_size, opts);
    const used_str = formatSize(&used_buf, fs.used_blocks, fs.block_size, opts);
    const avail_str = formatSize(&avail_buf, fs.avail_blocks, fs.block_size, opts);
    // Use% is based on used / (used + avail) to match GNU df
    const use_total = fs.used_blocks + fs.avail_blocks;
    const pct_str = formatPercent(&pct_buf, fs.used_blocks, use_total);

    if (opts.display.color == .off) {
        // Plain mode: no color, no bar
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                fs.source, fs.fstype, total_str, used_str, avail_str, pct_str, fs.mount_point,
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                fs.source, total_str, used_str, avail_str, pct_str, fs.mount_point,
            });
        }
        return;
    }

    // Color and full modes: apply color to percent
    const percent = calcUsagePercent(fs.used_blocks, use_total);
    const S = common.style.Style(@TypeOf(stdout));
    const s = S{ .color_mode = @enumFromInt(color_mode_int), .writer = stdout };

    if (opts.display.icons == .on) {
        // Full mode: color + bar + truncated path
        var bar_buf: [48]u8 = undefined;
        const bar_str = formatUsageBar(&bar_buf, percent);
        var path_buf: [64]u8 = undefined;
        const mount_str = truncatePath(&path_buf, fs.mount_point, 20);

        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} ", .{
                fs.source, fs.fstype, total_str, used_str, avail_str,
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} ", .{
                fs.source, total_str, used_str, avail_str,
            });
        }
        try applyUsageColor(s, percent);
        try stdout.print("{s:>5}", .{pct_str});
        try s.reset();
        try stdout.print(" {s:>17} {s}\n", .{ bar_str, mount_str });
    } else {
        // Color mode: color on percent, no bar, no path truncation
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} ", .{
                fs.source, fs.fstype, total_str, used_str, avail_str,
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} ", .{
                fs.source, total_str, used_str, avail_str,
            });
        }
        try applyUsageColor(s, percent);
        try stdout.print("{s:>5}", .{pct_str});
        try s.reset();
        try stdout.print(" {s}\n", .{fs.mount_point});
    }
}

fn printTotal(stdout: anytype, filesystems: []const FsInfo, opts: DfOptions, color_mode_int: u8) !void {
    if (opts.inodes) {
        var sum_total: u64 = 0;
        var sum_used: u64 = 0;
        var sum_avail: u64 = 0;
        for (filesystems) |fs| {
            sum_total += fs.total_inodes;
            sum_used += fs.used_inodes;
            sum_avail += fs.avail_inodes;
        }
        var pct_buf: [16]u8 = undefined;
        const pct = formatPercent(&pct_buf, sum_used, sum_total);
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {d:>10} {d:>10} {d:>10} {s:>5} {s}\n", .{
                "total", "-", sum_total, sum_used, sum_avail, pct, "-",
            });
        } else {
            try stdout.print("{s:<15} {d:>10} {d:>10} {d:>10} {s:>5} {s}\n", .{
                "total", sum_total, sum_used, sum_avail, pct, "-",
            });
        }
        return;
    }

    // Sum bytes across all filesystems
    var sum_total_bytes: u64 = 0;
    var sum_used_bytes: u64 = 0;
    var sum_avail_bytes: u64 = 0;
    for (filesystems) |fs| {
        sum_total_bytes += fs.total_blocks * fs.block_size;
        sum_used_bytes += fs.used_blocks * fs.block_size;
        sum_avail_bytes += fs.avail_blocks * fs.block_size;
    }

    // Convert sums back to display blocks
    const display_block: u64 = if (opts.block_size) |bs| bs else 1024;

    var total_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var avail_buf: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;

    const total_str = blk: {
        if (opts.human_readable) {
            break :blk formatHumanReadable(&total_buf, sum_total_bytes, false);
        } else if (opts.si) {
            break :blk formatHumanReadable(&total_buf, sum_total_bytes, true);
        }
        const val = @divTrunc(sum_total_bytes + display_block - 1, display_block);
        if (opts.thousands_grouping) break :blk formatWithCommas(&total_buf, val);
        break :blk std.fmt.bufPrint(&total_buf, "{d}", .{val}) catch "?";
    };
    const used_str = blk: {
        if (opts.human_readable) {
            break :blk formatHumanReadable(&used_buf, sum_used_bytes, false);
        } else if (opts.si) {
            break :blk formatHumanReadable(&used_buf, sum_used_bytes, true);
        }
        const val = @divTrunc(sum_used_bytes + display_block - 1, display_block);
        if (opts.thousands_grouping) break :blk formatWithCommas(&used_buf, val);
        break :blk std.fmt.bufPrint(&used_buf, "{d}", .{val}) catch "?";
    };
    const avail_str = blk: {
        if (opts.human_readable) {
            break :blk formatHumanReadable(&avail_buf, sum_avail_bytes, false);
        } else if (opts.si) {
            break :blk formatHumanReadable(&avail_buf, sum_avail_bytes, true);
        }
        const val = @divTrunc(sum_avail_bytes + display_block - 1, display_block);
        if (opts.thousands_grouping) break :blk formatWithCommas(&avail_buf, val);
        break :blk std.fmt.bufPrint(&avail_buf, "{d}", .{val}) catch "?";
    };
    const sum_use_total = sum_used_bytes + sum_avail_bytes;
    const pct_str = if (sum_use_total == 0)
        "-"
    else blk: {
        const pct = @divTrunc(sum_used_bytes * 100 + sum_use_total - 1, sum_use_total);
        break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "?";
    };

    if (opts.display.color == .off) {
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                "total", "-", total_str, used_str, avail_str, pct_str, "-",
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
                "total", total_str, used_str, avail_str, pct_str, "-",
            });
        }
        return;
    }

    // Color and full modes: apply color to percent
    const percent: u8 = if (sum_use_total == 0)
        0
    else
        @intCast(@min(@divTrunc(sum_used_bytes * 100 + sum_use_total - 1, sum_use_total), 100));

    const S = common.style.Style(@TypeOf(stdout));
    const s = S{ .color_mode = @enumFromInt(color_mode_int), .writer = stdout };

    if (opts.display.icons == .on) {
        var bar_buf: [48]u8 = undefined;
        const bar_str = formatUsageBar(&bar_buf, percent);

        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} ", .{
                "total", "-", total_str, used_str, avail_str,
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} ", .{
                "total", total_str, used_str, avail_str,
            });
        }
        try applyUsageColor(s, percent);
        try stdout.print("{s:>5}", .{pct_str});
        try s.reset();
        try stdout.print(" {s:>17} {s}\n", .{ bar_str, "-" });
    } else {
        // Color mode
        if (opts.print_type) {
            try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} ", .{
                "total", "-", total_str, used_str, avail_str,
            });
        } else {
            try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} ", .{
                "total", total_str, used_str, avail_str,
            });
        }
        try applyUsageColor(s, percent);
        try stdout.print("{s:>5}", .{pct_str});
        try s.reset();
        try stdout.print(" {s}\n", .{"-"});
    }
}

// ============================================================================
// Dynamic-width output formatting
// ============================================================================

fn printHeaderDynamic(stdout: anytype, opts: DfOptions, widths: ColumnWidths, s: anytype) !void {
    var size_label_buf: [32]u8 = undefined;
    const size_label: []const u8 = blk: {
        if (opts.human_readable or opts.si) break :blk "Size";
        if (opts.block_size) |bs| {
            if (bs == 512) break :blk "512B-blocks";
            if (bs == 1024) break :blk "1K-blocks";
            if (bs == 1024 * 1024) break :blk "1M-blocks";
            if (bs == 1024 * 1024 * 1024) break :blk "1G-blocks";
            break :blk std.fmt.bufPrint(&size_label_buf, "{d}B-blocks", .{bs}) catch "blocks";
        }
        if (opts.portability) break :blk "1024-blocks";
        break :blk "1K-blocks";
    };
    const pct_label: []const u8 = if (opts.portability) "Capacity" else "Use%";

    // Icon column spacer (2 chars for icon + space)
    if (opts.display.icons == .on) {
        try stdout.writeAll("  ");
    }

    // Bold headers when color is on
    if (s.color_mode != .none) try s.setBold();

    try padRight(stdout, "Filesystem", widths.filesystem);
    try stdout.writeAll("  ");

    if (opts.print_type) {
        try padRight(stdout, "Type", widths.fs_type);
        try stdout.writeAll("  ");
    }

    try padLeft(stdout, size_label, widths.size);
    try stdout.writeAll("  ");
    try padLeft(stdout, "Used", widths.used);
    try stdout.writeAll("  ");
    try padLeft(stdout, "Avail", widths.avail);
    try stdout.writeAll("  ");
    try padLeft(stdout, pct_label, widths.use_pct);

    if (opts.display.icons == .on) {
        try stdout.writeAll("  ");
        try padRight(stdout, "Usage", widths.usage_bar);
    }

    try stdout.writeAll("  ");
    try stdout.writeAll("Mounted on");

    if (s.color_mode != .none) try s.reset();
    try stdout.writeAll("\n");
}

fn printFsRowDynamic(stdout: anytype, fs: FsInfo, opts: DfOptions, widths: ColumnWidths, s: anytype) !void {
    const fs_class = classifyFs(fs.source, fs.fstype, fs.mount_point);

    var total_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var avail_buf: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;

    const total_str = formatSize(&total_buf, fs.total_blocks, fs.block_size, opts);
    const used_str = formatSize(&used_buf, fs.used_blocks, fs.block_size, opts);
    const avail_str = formatSize(&avail_buf, fs.avail_blocks, fs.block_size, opts);
    const use_total = fs.used_blocks + fs.avail_blocks;
    const pct_str = formatPercent(&pct_buf, fs.used_blocks, use_total);
    const percent = calcUsagePercent(fs.used_blocks, use_total);

    // Smart-format source and mount
    var src_fmt_buf: [128]u8 = undefined;
    const source_str = smartFormatSource(&src_fmt_buf, fs.source, widths.filesystem);
    var mnt_fmt_buf: [128]u8 = undefined;
    const mount_str = smartFormatMount(&mnt_fmt_buf, fs.mount_point, widths.mount);

    if (s.color_mode == .none) {
        // Plain mode
        if (opts.display.icons == .on) {
            const icon = getFsIcon(fs_class);
            try stdout.writeAll(icon);
            try stdout.writeAll(" ");
        }
        try padRight(stdout, source_str, widths.filesystem);
        try stdout.writeAll("  ");
        if (opts.print_type) {
            try padRight(stdout, fs.fstype, widths.fs_type);
            try stdout.writeAll("  ");
        }
        try padLeft(stdout, total_str, widths.size);
        try stdout.writeAll("  ");
        try padLeft(stdout, used_str, widths.used);
        try stdout.writeAll("  ");
        try padLeft(stdout, avail_str, widths.avail);
        try stdout.writeAll("  ");
        try padLeft(stdout, pct_str, widths.use_pct);
        if (opts.display.icons == .on) {
            try stdout.writeAll("  ");
            var bar_buf: [48]u8 = undefined;
            const bar_str = formatUsageBar(&bar_buf, percent);
            try padRight(stdout, bar_str, widths.usage_bar);
        }
        try stdout.writeAll("  ");
        try stdout.writeAll(mount_str);
        try stdout.writeAll("\n");
        return;
    }

    // Color mode
    // Icon
    if (opts.display.icons == .on) {
        const icon = getFsIcon(fs_class);
        const icon_color = common.icons.getIconColorInfo(icon);
        if (icon_color) |ic| {
            switch (s.color_mode) {
                .truecolor => try s.setRgb(ic.r, ic.g, ic.b),
                .extended => try s.set256(ic.c256),
                .basic => try s.setColor(ic.basic),
                .none => {},
            }
        }
        try stdout.writeAll(icon);
        try s.reset();
        try stdout.writeAll(" ");
    }

    // Source name (colored by FsClass)
    try applySourceColor(s, fs_class);
    try padRight(stdout, source_str, widths.filesystem);
    try s.reset();
    try stdout.writeAll("  ");

    // Type (dim gray)
    if (opts.print_type) {
        try applyTypeColor(s);
        try padRight(stdout, fs.fstype, widths.fs_type);
        try s.reset();
        try stdout.writeAll("  ");
    }

    // Size columns (no special color)
    try padLeft(stdout, total_str, widths.size);
    try stdout.writeAll("  ");
    try padLeft(stdout, used_str, widths.used);
    try stdout.writeAll("  ");
    try padLeft(stdout, avail_str, widths.avail);
    try stdout.writeAll("  ");

    // Use% (colored by threshold)
    try applyUsageColor(s, percent);
    try padLeft(stdout, pct_str, widths.use_pct);
    try s.reset();

    // Usage bar (gradient)
    if (opts.display.icons == .on) {
        try stdout.writeAll("  ");
        try writeColoredUsageBar(stdout, s, percent);
    }

    // Mount point (colored by FsClass)
    try stdout.writeAll("  ");
    try applyMountColor(s, fs_class);
    try stdout.writeAll(mount_str);
    try s.reset();
    try stdout.writeAll("\n");
}

fn printTotalDynamic(stdout: anytype, filesystems: []const FsInfo, opts: DfOptions, widths: ColumnWidths, s: anytype) !void {
    // Sum bytes across all filesystems
    var sum_total_bytes: u64 = 0;
    var sum_used_bytes: u64 = 0;
    var sum_avail_bytes: u64 = 0;
    for (filesystems) |fs| {
        sum_total_bytes += fs.total_blocks * fs.block_size;
        sum_used_bytes += fs.used_blocks * fs.block_size;
        sum_avail_bytes += fs.avail_blocks * fs.block_size;
    }

    const display_block: u64 = if (opts.block_size) |bs| bs else 1024;

    var total_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var avail_buf: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;

    const total_str = blk: {
        if (opts.human_readable) break :blk formatHumanReadable(&total_buf, sum_total_bytes, false);
        if (opts.si) break :blk formatHumanReadable(&total_buf, sum_total_bytes, true);
        const val = @divTrunc(sum_total_bytes + display_block - 1, display_block);
        if (opts.thousands_grouping) break :blk formatWithCommas(&total_buf, val);
        break :blk std.fmt.bufPrint(&total_buf, "{d}", .{val}) catch "?";
    };
    const used_str = blk: {
        if (opts.human_readable) break :blk formatHumanReadable(&used_buf, sum_used_bytes, false);
        if (opts.si) break :blk formatHumanReadable(&used_buf, sum_used_bytes, true);
        const val = @divTrunc(sum_used_bytes + display_block - 1, display_block);
        if (opts.thousands_grouping) break :blk formatWithCommas(&used_buf, val);
        break :blk std.fmt.bufPrint(&used_buf, "{d}", .{val}) catch "?";
    };
    const avail_str = blk: {
        if (opts.human_readable) break :blk formatHumanReadable(&avail_buf, sum_avail_bytes, false);
        if (opts.si) break :blk formatHumanReadable(&avail_buf, sum_avail_bytes, true);
        const val = @divTrunc(sum_avail_bytes + display_block - 1, display_block);
        if (opts.thousands_grouping) break :blk formatWithCommas(&avail_buf, val);
        break :blk std.fmt.bufPrint(&avail_buf, "{d}", .{val}) catch "?";
    };
    const sum_use_total = sum_used_bytes + sum_avail_bytes;
    const pct_str: []const u8 = if (sum_use_total == 0) "-" else blk: {
        const pct = @divTrunc(sum_used_bytes * 100 + sum_use_total - 1, sum_use_total);
        break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "?";
    };
    const percent: u8 = if (sum_use_total == 0) 0 else @intCast(@min(@divTrunc(sum_used_bytes * 100 + sum_use_total - 1, sum_use_total), 100));

    if (s.color_mode == .none) {
        if (opts.display.icons == .on) {
            try stdout.writeAll("  "); // icon spacer
        }
        try padRight(stdout, "total", widths.filesystem);
        try stdout.writeAll("  ");
        if (opts.print_type) {
            try padRight(stdout, "-", widths.fs_type);
            try stdout.writeAll("  ");
        }
        try padLeft(stdout, total_str, widths.size);
        try stdout.writeAll("  ");
        try padLeft(stdout, used_str, widths.used);
        try stdout.writeAll("  ");
        try padLeft(stdout, avail_str, widths.avail);
        try stdout.writeAll("  ");
        try padLeft(stdout, pct_str, widths.use_pct);
        if (opts.display.icons == .on) {
            try stdout.writeAll("  ");
            var bar_buf: [48]u8 = undefined;
            try padRight(stdout, formatUsageBar(&bar_buf, percent), widths.usage_bar);
        }
        try stdout.writeAll("  ");
        try stdout.writeAll("-");
        try stdout.writeAll("\n");
        return;
    }

    // Color mode
    if (opts.display.icons == .on) {
        try stdout.writeAll("  "); // icon spacer (no icon for total)
    }

    try applySourceColor(s, .local);
    try padRight(stdout, "total", widths.filesystem);
    try s.reset();
    try stdout.writeAll("  ");

    if (opts.print_type) {
        try applyTypeColor(s);
        try padRight(stdout, "-", widths.fs_type);
        try s.reset();
        try stdout.writeAll("  ");
    }

    try padLeft(stdout, total_str, widths.size);
    try stdout.writeAll("  ");
    try padLeft(stdout, used_str, widths.used);
    try stdout.writeAll("  ");
    try padLeft(stdout, avail_str, widths.avail);
    try stdout.writeAll("  ");

    try applyUsageColor(s, percent);
    try padLeft(stdout, pct_str, widths.use_pct);
    try s.reset();

    if (opts.display.icons == .on) {
        try stdout.writeAll("  ");
        try writeColoredUsageBar(stdout, s, percent);
    }

    try stdout.writeAll("  ");
    try stdout.writeAll("-");
    try stdout.writeAll("\n");
}

// ============================================================================
// Main logic
// ============================================================================

pub fn runDf(allocator: Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) u8 {
    const parsed = parseArgs(allocator, args);
    const opts = parsed.opts;

    if (parsed.err) |msg| {
        common.printErrorWithProgram(allocator, stderr, prog_name, "{s}", .{msg});
        return @intFromEnum(common.ExitCode.misuse);
    }
    defer allocator.free(opts.positionals);

    if (opts.help) {
        printHelp(allocator, stdout) catch {};
        return @intFromEnum(common.ExitCode.success);
    }

    if (opts.version) {
        printVersion(stdout) catch {};
        return @intFromEnum(common.ExitCode.success);
    }

    // Detect terminal color capability level. When display.color is on,
    // the TTY/NO_COLOR/TERM checks have already passed, so we fall back
    // to basic (16-color) if capability detection fails rather than
    // disabling color entirely.
    const color_mode_int: u8 = if (opts.display.color == .off) 0 else blk: {
        const CM = common.style.Style(@TypeOf(stdout)).ColorMode;
        const detected = CM.detect(allocator) catch break :blk @intFromEnum(CM.basic);
        break :blk if (detected == .none) @intFromEnum(CM.basic) else @intFromEnum(detected);
    };

    const S = common.style.Style(@TypeOf(stdout));
    const s = S{ .color_mode = @enumFromInt(color_mode_int), .writer = stdout };

    var exit_code: u8 = @intFromEnum(common.ExitCode.success);

    // Collect visible filesystems into a list for two-pass rendering.
    // owns_fs_strings tracks whether visible owns the FsInfo string
    // allocations (positional path) or they're owned by all_fs_storage.
    var visible = std.ArrayListUnmanaged(FsInfo){};
    defer visible.deinit(allocator);
    var owns_fs_strings = false;

    // Storage for mounted filesystems (no-positionals path).
    // Must outlive visible since visible borrows string pointers.
    var all_fs_storage: ?[]FsInfo = null;
    var display_fs_storage: ?[]FsInfo = null;
    defer {
        if (display_fs_storage) |dfs| {
            if (all_fs_storage) |afs| {
                if (dfs.ptr != afs.ptr) allocator.free(dfs);
            }
        }
        if (all_fs_storage) |afs| freeFsInfoSlice(allocator, afs);
        if (owns_fs_strings) {
            for (visible.items) |fs| freeFsInfo(allocator, fs);
        }
    }

    if (opts.positionals.len > 0) {
        owns_fs_strings = true;
        for (opts.positionals) |path| {
            const fs = getFilesystemForPath(allocator, path) catch {
                common.printErrorWithProgram(allocator, stderr, prog_name, "cannot access '{s}': No such file or directory", .{path});
                exit_code = @intFromEnum(common.ExitCode.general_error);
                continue;
            };
            if (shouldIncludeFs(fs, opts)) {
                visible.append(allocator, fs) catch {};
            } else {
                freeFsInfo(allocator, fs);
            }
        }
    } else {
        const all_fs = getMountedFilesystems(allocator) catch {
            common.printErrorWithProgram(allocator, stderr, prog_name, "cannot read table of mounted file systems", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
        all_fs_storage = all_fs;

        // Smart volume grouping on macOS (non-plain mode)
        const display_fs = blk: {
            if (comptime is_darwin) {
                if (opts.display.color == .on) {
                    break :blk groupDarwinVolumes(allocator, all_fs) catch all_fs;
                }
            }
            break :blk all_fs;
        };
        display_fs_storage = display_fs;

        for (display_fs) |fs| {
            if (shouldIncludeFs(fs, opts)) {
                visible.append(allocator, fs) catch {};
            }
        }
    }

    if (visible.items.len == 0 and exit_code == 0) {
        return exit_code;
    }

    // Inodes mode uses the old fixed-width rendering
    if (opts.inodes) {
        printHeader(stdout, opts) catch return @intFromEnum(common.ExitCode.general_error);
        for (visible.items) |fs| {
            printFsRow(stdout, fs, opts, color_mode_int) catch {};
        }
        if (opts.total and visible.items.len > 0) {
            printTotal(stdout, visible.items, opts, color_mode_int) catch {};
        }
        return exit_code;
    }

    // Two-pass rendering: compute column widths, then print
    var widths = computeColumnWidths(visible.items, opts);

    // Include "total" row in width computation if needed
    if (opts.total and visible.items.len > 0) {
        widths.filesystem = @max(widths.filesystem, 5); // "total"
    }

    // Cap to terminal width
    capWidthsToTerminal(allocator, &widths, opts);

    printHeaderDynamic(stdout, opts, widths, s) catch return @intFromEnum(common.ExitCode.general_error);
    for (visible.items) |fs| {
        printFsRowDynamic(stdout, fs, opts, widths, s) catch {};
    }
    if (opts.total and visible.items.len > 0) {
        printTotalDynamic(stdout, visible.items, opts, widths, s) catch {};
    }

    return exit_code;
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

    const exit_code = runDf(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) std.process.exit(exit_code);
}

// ============================================================================
// Help and version
// ============================================================================

fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: df [OPTION]... [FILE]...
        \\Show information about the file system on which each FILE resides,
        \\or all file systems by default.
        \\
        \\Displays human-readable sizes by default with colored output and
        \\usage bars. Use -P for POSIX-compatible plain output.
        \\
        \\  -a, --all             include pseudo, duplicate, inaccessible file systems
        \\  -b                    display free space in 512-byte blocks
        \\  -c                    display a grand total (same as --total)
        \\  -g                    display in 1-gigabyte blocks
        \\  -h, --human-readable  print sizes in powers of 1024 (default)
        \\  -H, --si              print sizes in powers of 1000 (e.g., 1.1G)
        \\  -i, --inodes          list inode information instead of block usage
        \\  -I TYPE               exclude file systems of type TYPE
        \\  -k                    like --block-size=1K (disables human-readable)
        \\  -l, --local           limit listing to local file systems
        \\  -m                    display in 1-megabyte blocks
        \\  -P, --portability     use the POSIX output format (no colors or bars)
        \\  -T, --print-type      print file system type
        \\  -t, --type=TYPE       limit listing to file systems of type TYPE
        \\  -x, --exclude-type=TYPE  limit listing to file systems not of type TYPE
        \\  -Y                    do not resolve NFS paths (no-op)
        \\  -,                    format numbers with thousands grouping (commas)
        \\      --block-size=SIZE  scale sizes by SIZE before printing them
        \\      --total            produce a grand total
        \\      --output[=FIELD_LIST]  use the output format defined by FIELD_LIST
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\VIBEUTILS_STYLE controls visual enhancements:
        \\  full    colored output with usage bars (default)
        \\  color   colored percentage only, no bars
        \\  plain   no colors or visual enhancements
        \\
        \\Per-feature overrides (auto/always/never):
        \\  VIBEUTILS_COLOR      enable/disable colored output
        \\  VIBEUTILS_ICONS      enable/disable usage bars
        \\  VIBEUTILS_HIGHLIGHT  enable/disable syntax highlighting
        \\  VIBEUTILS_THEME      theme selection (default/none)
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("df ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "parseBlockSize - plain numbers" {
    try testing.expectEqual(@as(?u64, 512), parseBlockSize("512"));
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("1024"));
    try testing.expectEqual(@as(?u64, null), parseBlockSize("0"));
    try testing.expectEqual(@as(?u64, 1), parseBlockSize("1"));
}

test "parseBlockSize - suffixes" {
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("1K"));
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("1k"));
    try testing.expectEqual(@as(?u64, 1048576), parseBlockSize("1M"));
    try testing.expectEqual(@as(?u64, 1073741824), parseBlockSize("1G"));
    try testing.expectEqual(@as(?u64, 2048), parseBlockSize("2K"));
}

test "parseBlockSize - bare suffixes" {
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("K"));
    try testing.expectEqual(@as(?u64, 1048576), parseBlockSize("M"));
    try testing.expectEqual(@as(?u64, 1073741824), parseBlockSize("G"));
}

test "parseBlockSize - invalid" {
    try testing.expectEqual(@as(?u64, null), parseBlockSize(""));
    try testing.expectEqual(@as(?u64, null), parseBlockSize("Q"));
    try testing.expectEqual(@as(?u64, null), parseBlockSize("1Z"));
}

test "formatHumanReadable - small values" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", formatHumanReadable(&buf, 0, false));
    try testing.expectEqualStrings("1", formatHumanReadable(&buf, 1, false));
    try testing.expectEqualStrings("512", formatHumanReadable(&buf, 512, false));
    try testing.expectEqualStrings("1023", formatHumanReadable(&buf, 1023, false));
}

test "formatHumanReadable - kilo values" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 1024, false);
    try testing.expectEqualStrings("1.0K", result);
}

test "formatHumanReadable - larger values" {
    var buf: [32]u8 = undefined;
    const result_10k = formatHumanReadable(&buf, 10 * 1024, false);
    try testing.expectEqualStrings("10K", result_10k);
}

test "formatHumanReadable - SI mode" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 1000, true);
    try testing.expectEqualStrings("1.0k", result);
}

test "formatPercent - normal" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("50%", formatPercent(&buf, 50, 100));
    try testing.expectEqualStrings("100%", formatPercent(&buf, 100, 100));
    try testing.expectEqualStrings("1%", formatPercent(&buf, 1, 100));
}

test "formatPercent - edge cases" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("-", formatPercent(&buf, 0, 0));
    try testing.expectEqualStrings("1%", formatPercent(&buf, 1, 1000));
}

test "isPseudoFs - known types" {
    try testing.expect(isPseudoFs("devfs"));
    try testing.expect(isPseudoFs("proc"));
    try testing.expect(isPseudoFs("sysfs"));
    try testing.expect(isPseudoFs("tmpfs"));
    try testing.expect(!isPseudoFs("apfs"));
    try testing.expect(!isPseudoFs("ext4"));
    try testing.expect(!isPseudoFs("xfs"));
}

test "extractCString - null terminated" {
    const buf = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0, 'x', 'y' };
    try testing.expectEqualStrings("hello", extractCString(&buf));
}

test "extractCString - no null" {
    const buf = [_]u8{ 'a', 'b', 'c' };
    try testing.expectEqualStrings("abc", extractCString(&buf));
}

test "parseArgs - no args" {
    const args = [_][]const u8{};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(!parsed.opts.all);
    try testing.expect(parsed.opts.human_readable);
    try testing.expectEqual(@as(usize, 0), parsed.opts.positionals.len);
}

test "parseArgs - help" {
    const args = [_][]const u8{"--help"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.help);
}

test "parseArgs - short flags" {
    const args = [_][]const u8{"-ahiTlP"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.all);
    // -P comes after -h and disables human_readable
    try testing.expect(!parsed.opts.human_readable);
    try testing.expect(parsed.opts.inodes);
    try testing.expect(parsed.opts.print_type);
    try testing.expect(parsed.opts.local);
    try testing.expect(parsed.opts.portability);
    try testing.expectEqual(common.display_config.ResolvedMode.off, parsed.opts.display.color);
}

test "parseArgs - long flags" {
    const args = [_][]const u8{ "--all", "--human-readable", "--inodes", "--print-type" };
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.all);
    try testing.expect(parsed.opts.human_readable);
    try testing.expect(parsed.opts.inodes);
    try testing.expect(parsed.opts.print_type);
}

test "parseArgs - type filter" {
    const args = [_][]const u8{ "-t", "apfs" };
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("apfs", parsed.opts.include_type.?);
}

test "parseArgs - exclude type" {
    const args = [_][]const u8{"--exclude-type=tmpfs"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("tmpfs", parsed.opts.exclude_type.?);
}

test "parseArgs - block-size" {
    const args = [_][]const u8{"--block-size=1M"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqual(@as(?u64, 1048576), parsed.opts.block_size);
}

test "parseArgs - positionals" {
    const args = [_][]const u8{ "/", "/tmp" };
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqual(@as(usize, 2), parsed.opts.positionals.len);
    try testing.expectEqualStrings("/", parsed.opts.positionals[0]);
    try testing.expectEqualStrings("/tmp", parsed.opts.positionals[1]);
}

test "parseArgs - unrecognized option" {
    const args = [_][]const u8{"--bogus"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err != null);
    try testing.expectEqualStrings("unrecognized option", parsed.err.?);
}

test "parseArgs - unrecognized short option" {
    const args = [_][]const u8{"-Z"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err != null);
}

test "parseArgs - type missing argument" {
    const args = [_][]const u8{"-t"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err != null);
}

test "parseArgs - version" {
    const args = [_][]const u8{"--version"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.version);
}

test "parseArgs - SI flag" {
    const args = [_][]const u8{"-H"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.si);
}

test "parseArgs - total flag" {
    const args = [_][]const u8{"--total"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.total);
}

test "parseArgs - output flag no args" {
    const args = [_][]const u8{"--output"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.output_fields != null);
}

test "parseArgs - output flag with fields" {
    const args = [_][]const u8{"--output=source,target"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("source,target", parsed.opts.output_fields.?);
}

test "parseArgs - double dash separator" {
    const args = [_][]const u8{ "--", "-h", "/tmp" };
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    // -h after -- is a positional, not a flag; human_readable keeps its default (true)
    try testing.expect(parsed.opts.human_readable);
    try testing.expectEqual(@as(usize, 2), parsed.opts.positionals.len);
    try testing.expectEqualStrings("-h", parsed.opts.positionals[0]);
}

test "shouldIncludeFs - basic filtering" {
    const fs = FsInfo{
        .source = "/dev/disk1",
        .fstype = "apfs",
        .mount_point = "/",
        .total_blocks = 1000,
        .used_blocks = 500,
        .avail_blocks = 500,
        .block_size = 4096,
        .total_inodes = 1000,
        .used_inodes = 100,
        .avail_inodes = 900,
        .flags = MNT_LOCAL,
    };

    const default_opts = DfOptions{};
    try testing.expect(shouldIncludeFs(fs, default_opts));
}

test "shouldIncludeFs - pseudo fs excluded by default" {
    const fs = FsInfo{
        .source = "devfs",
        .fstype = "devfs",
        .mount_point = "/dev",
        .total_blocks = 0,
        .used_blocks = 0,
        .avail_blocks = 0,
        .block_size = 0,
        .total_inodes = 0,
        .used_inodes = 0,
        .avail_inodes = 0,
        .flags = 0,
    };

    const default_opts = DfOptions{};
    try testing.expect(!shouldIncludeFs(fs, default_opts));
}

test "shouldIncludeFs - pseudo fs included with -a" {
    const fs = FsInfo{
        .source = "devfs",
        .fstype = "devfs",
        .mount_point = "/dev",
        .total_blocks = 0,
        .used_blocks = 0,
        .avail_blocks = 0,
        .block_size = 0,
        .total_inodes = 0,
        .used_inodes = 0,
        .avail_inodes = 0,
        .flags = 0,
    };

    const opts = DfOptions{ .all = true };
    try testing.expect(shouldIncludeFs(fs, opts));
}

test "shouldIncludeFs - type filter" {
    const fs = FsInfo{
        .source = "/dev/disk1",
        .fstype = "apfs",
        .mount_point = "/",
        .total_blocks = 1000,
        .used_blocks = 500,
        .avail_blocks = 500,
        .block_size = 4096,
        .total_inodes = 1000,
        .used_inodes = 100,
        .avail_inodes = 900,
        .flags = MNT_LOCAL,
    };

    var opts = DfOptions{};
    opts.include_type = "ext4";
    try testing.expect(!shouldIncludeFs(fs, opts));

    opts.include_type = "apfs";
    try testing.expect(shouldIncludeFs(fs, opts));
}

test "shouldIncludeFs - exclude type" {
    const fs = FsInfo{
        .source = "/dev/disk1",
        .fstype = "apfs",
        .mount_point = "/",
        .total_blocks = 1000,
        .used_blocks = 500,
        .avail_blocks = 500,
        .block_size = 4096,
        .total_inodes = 1000,
        .used_inodes = 100,
        .avail_inodes = 900,
        .flags = MNT_LOCAL,
    };

    var opts = DfOptions{};
    opts.exclude_type = "apfs";
    try testing.expect(!shouldIncludeFs(fs, opts));

    opts.exclude_type = "ext4";
    try testing.expect(shouldIncludeFs(fs, opts));
}

test "shouldIncludeFs - local only" {
    const local_fs = FsInfo{
        .source = "/dev/disk1",
        .fstype = "apfs",
        .mount_point = "/",
        .total_blocks = 1000,
        .used_blocks = 500,
        .avail_blocks = 500,
        .block_size = 4096,
        .total_inodes = 1000,
        .used_inodes = 100,
        .avail_inodes = 900,
        .flags = MNT_LOCAL,
    };

    const remote_fs = FsInfo{
        .source = "server:/share",
        .fstype = "nfs",
        .mount_point = "/mnt",
        .total_blocks = 1000,
        .used_blocks = 500,
        .avail_blocks = 500,
        .block_size = 4096,
        .total_inodes = 1000,
        .used_inodes = 100,
        .avail_inodes = 900,
        .flags = 0,
    };

    const opts = DfOptions{ .local = true };
    try testing.expect(shouldIncludeFs(local_fs, opts));
    try testing.expect(!shouldIncludeFs(remote_fs, opts));
}

test "runDf - help flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage: df") != null);
    try testing.expectEqualStrings("", stderr_buf.items);
}

test "runDf - version flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "df") != null);
}

test "runDf - unknown flag returns misuse" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "df:") != null);
}

test "runDf - nonexistent path returns error" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"/nonexistent/path/that/does/not/exist"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "df:") != null);
}

test "runDf - no args shows filesystems" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    // Should have a header line
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Filesystem") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Mounted on") != null);
}

test "runDf - specific path" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"/"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Filesystem") != null);
    try testing.expect(stdout_buf.items.len > 50); // Has meaningful output
}

test "runDf - human readable flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-h", "/" };
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Size") != null);
}

test "runDf - print type flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-T", "/" };
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Type") != null);
}

test "runDf - inodes flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-i", "/" };
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Inodes") != null);
}

test "formatSize - 1K-blocks" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    // 1000 blocks * 4096 block_size = 4096000 bytes = 4000 1K-blocks
    const result = formatSize(&buf, 1000, 4096, opts);
    try testing.expectEqualStrings("4000", result);
}

test "formatSize - human readable" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = true;
    // 1000 blocks * 4096 = 4096000 bytes = ~3.9M
    const result = formatSize(&buf, 1000, 4096, opts);
    try testing.expectEqualStrings("3.9M", result);
}

test "parseArgs - human readable is default" {
    const args = [_][]const u8{};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.opts.human_readable);
}

test "parseArgs - k flag disables human readable" {
    const args = [_][]const u8{"-k"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(!parsed.opts.human_readable);
}

test "parseArgs - P flag disables human readable and sets plain" {
    const args = [_][]const u8{"-P"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(!parsed.opts.human_readable);
    try testing.expectEqual(common.display_config.ResolvedMode.off, parsed.opts.display.color);
}

test "parseArgs - block-size disables human readable" {
    const args = [_][]const u8{"--block-size=4K"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(!parsed.opts.human_readable);
}

test "calcUsagePercent - normal cases" {
    try testing.expectEqual(@as(u8, 50), calcUsagePercent(50, 100));
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(100, 100));
    try testing.expectEqual(@as(u8, 0), calcUsagePercent(0, 100));
}

test "calcUsagePercent - zero total returns 0" {
    try testing.expectEqual(@as(u8, 0), calcUsagePercent(0, 0));
    try testing.expectEqual(@as(u8, 0), calcUsagePercent(50, 0));
}

test "calcUsagePercent - ceiling rounding" {
    // 1/1000 should round up to 1%, not 0%
    try testing.expectEqual(@as(u8, 1), calcUsagePercent(1, 1000));
    // 1/100 is exactly 1%
    try testing.expectEqual(@as(u8, 1), calcUsagePercent(1, 100));
}

test "formatUsageBar - 0 percent" {
    var buf: [48]u8 = undefined;
    const result = formatUsageBar(&buf, 0);
    try testing.expectEqualStrings("[░░░░░░░░░░]   0%", result);
}

test "formatUsageBar - 50 percent" {
    var buf: [48]u8 = undefined;
    const result = formatUsageBar(&buf, 50);
    try testing.expectEqualStrings("[█████░░░░░]  50%", result);
}

test "formatUsageBar - 84 percent" {
    var buf: [48]u8 = undefined;
    const result = formatUsageBar(&buf, 84);
    // 84% of 10 = 8.4, ceiling = 9 filled, 1 empty
    try testing.expectEqualStrings("[█████████░]  84%", result);
}

test "formatUsageBar - 100 percent" {
    var buf: [48]u8 = undefined;
    const result = formatUsageBar(&buf, 100);
    try testing.expectEqualStrings("[██████████] 100%", result);
}

test "formatUsageBar - 1 percent" {
    var buf: [48]u8 = undefined;
    const result = formatUsageBar(&buf, 1);
    // 1% of 10 = 0.1, ceiling = 1 filled, 9 empty
    try testing.expectEqualStrings("[█░░░░░░░░░]   1%", result);
}

test "applyUsageColor - truecolor green" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 50);
    try testing.expectEqualSlices(u8, "\x1b[38;2;115;195;120m", buffer.items);
}

test "applyUsageColor - truecolor yellow" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 75);
    try testing.expectEqualSlices(u8, "\x1b[38;2;210;185;90m", buffer.items);
}

test "applyUsageColor - truecolor red" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 95);
    try testing.expectEqualSlices(u8, "\x1b[38;2;210;95;90m", buffer.items);
}

test "applyUsageColor - basic green" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 30);
    try testing.expectEqualSlices(u8, "\x1b[32m", buffer.items);
}

test "applyUsageColor - basic yellow" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 80);
    try testing.expectEqualSlices(u8, "\x1b[33m", buffer.items);
}

test "applyUsageColor - basic red" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 90);
    try testing.expectEqualSlices(u8, "\x1b[31m", buffer.items);
}

test "applyUsageColor - none writes nothing" {
    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const s = TestStyle{ .color_mode = .none, .writer = buffer.writer(testing.allocator) };
    try applyUsageColor(s, 50);
    try testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "truncatePath - short unchanged" {
    var buf: [64]u8 = undefined;
    const result = truncatePath(&buf, "/mnt", 20);
    try testing.expectEqualStrings("/mnt", result);
}

test "truncatePath - exact fit" {
    var buf: [64]u8 = undefined;
    const result = truncatePath(&buf, "/mnt/data", 9);
    try testing.expectEqualStrings("/mnt/data", result);
}

test "truncatePath - long truncated" {
    var buf: [64]u8 = undefined;
    const result = truncatePath(&buf, "/System/Volumes/Data/home", 15);
    try testing.expectEqualStrings("...es/Data/home", result);
}

test "truncatePath - root unchanged" {
    var buf: [64]u8 = undefined;
    const result = truncatePath(&buf, "/", 20);
    try testing.expectEqualStrings("/", result);
}

fn makeFsInfo(source: []const u8, mount_point: []const u8, total_blocks: u64, block_size: u64) FsInfo {
    return FsInfo{
        .source = source,
        .fstype = "apfs",
        .mount_point = mount_point,
        .total_blocks = total_blocks,
        .used_blocks = @divTrunc(total_blocks, 2),
        .avail_blocks = @divTrunc(total_blocks, 2),
        .block_size = block_size,
        .total_inodes = 1000,
        .used_inodes = 100,
        .avail_inodes = 900,
        .flags = MNT_LOCAL,
    };
}

test "extractDevicePrefix - disk with partition" {
    try testing.expectEqualStrings("/dev/disk3", extractDevicePrefix("/dev/disk3s1"));
    try testing.expectEqualStrings("/dev/disk3", extractDevicePrefix("/dev/disk3s5"));
    try testing.expectEqualStrings("/dev/disk1", extractDevicePrefix("/dev/disk1s1"));
}

test "extractDevicePrefix - no partition suffix" {
    try testing.expectEqualStrings("/dev/sda1", extractDevicePrefix("/dev/sda1"));
    try testing.expectEqualStrings("tmpfs", extractDevicePrefix("tmpfs"));
}

test "groupDarwinVolumes - no duplicates unchanged" {
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk2s1", "/home", 2000, 4096);
    const input = [_]FsInfo{ fs1, fs2 };
    const result = try groupDarwinVolumes(testing.allocator, &input);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "groupDarwinVolumes - same device and size collapses" {
    const fs1 = makeFsInfo("/dev/disk3s1", "/", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk3s2", "/System/Volumes/Data", 1000, 4096);
    const fs3 = makeFsInfo("/dev/disk3s5", "/System/Volumes/VM", 1000, 4096);
    const input = [_]FsInfo{ fs1, fs2, fs3 };
    const result = try groupDarwinVolumes(testing.allocator, &input);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("/", result[0].mount_point);
}

test "groupDarwinVolumes - different sizes stay separate" {
    const fs1 = makeFsInfo("/dev/disk3s1", "/", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk3s2", "/data", 2000, 4096);
    const input = [_]FsInfo{ fs1, fs2 };
    const result = try groupDarwinVolumes(testing.allocator, &input);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "groupDarwinVolumes - preserves root entry data" {
    const fs1 = makeFsInfo("/dev/disk3s5", "/System/Volumes/VM", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk3s1", "/", 1000, 4096);
    const input = [_]FsInfo{ fs1, fs2 };
    const result = try groupDarwinVolumes(testing.allocator, &input);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("/", result[0].mount_point);
    try testing.expectEqualStrings("/dev/disk3s1", result[0].source);
}

test "groupDarwinVolumes - mixed devices" {
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk1s2", "/System/Volumes/Data", 1000, 4096);
    const fs3 = makeFsInfo("/dev/disk2s1", "/external", 5000, 4096);
    const input = [_]FsInfo{ fs1, fs2, fs3 };
    const result = try groupDarwinVolumes(testing.allocator, &input);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "printFsRow - plain mode has no ANSI" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    const fs = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    var opts = DfOptions{};
    opts.display.color = .off;
    opts.display.icons = .off;
    try printFsRow(buf.writer(testing.allocator), fs, opts, 0);
    // No ANSI escape sequences in plain mode
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[") == null);
}

test "printFsRow - color mode applies ANSI" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    const fs = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .off;
    // Use basic color mode (1) so ANSI codes are emitted
    try printFsRow(buf.writer(testing.allocator), fs, opts, 1);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[") != null);
    // No bar in color mode
    try testing.expect(std.mem.indexOf(u8, buf.items, "[") == null or
        std.mem.indexOf(u8, buf.items, "\xe2\x96\x88") == null);
}

test "printFsRow - full mode includes bar" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    const fs = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .on;
    try printFsRow(buf.writer(testing.allocator), fs, opts, 0);
    // Full mode with color_mode_int=0 (none) still shows the bar
    try testing.expect(std.mem.indexOf(u8, buf.items, "\xe2\x96\x88") != null or
        std.mem.indexOf(u8, buf.items, "\xe2\x96\x91") != null);
}

test "printHeader - full mode shows Usage column" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .on;
    try printHeader(buf.writer(testing.allocator), opts);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Usage") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Size") != null);
}

test "printHeader - plain mode no Usage column" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    var opts = DfOptions{};
    opts.display.icons = .off;
    try printHeader(buf.writer(testing.allocator), opts);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Usage") == null);
}

test "printHeader - color mode no Usage column" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    var opts = DfOptions{};
    opts.display.icons = .off;
    try printHeader(buf.writer(testing.allocator), opts);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Usage") == null);
}

test "printTotal - plain mode has no ANSI" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk2s1", "/home", 2000, 4096);
    const items = [_]FsInfo{ fs1, fs2 };
    var opts = DfOptions{};
    opts.display.color = .off;
    opts.display.icons = .off;
    try printTotal(buf.writer(testing.allocator), &items, opts, 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "total") != null);
}

test "printTotal - full mode includes bar" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    const items = [_]FsInfo{fs1};
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .on;
    try printTotal(buf.writer(testing.allocator), &items, opts, 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\xe2\x96\x88") != null or
        std.mem.indexOf(u8, buf.items, "\xe2\x96\x91") != null);
}

test "runDf - help mentions VIBEUTILS_STYLE" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "VIBEUTILS_STYLE") != null);
}

// C library functions for environment manipulation in tests
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

test "runDf - non-tty output should not contain ANSI escapes" {
    // Save original environment values
    const orig_term = std.posix.getenv("TERM");
    const orig_no_color = std.posix.getenv("NO_COLOR");
    const orig_style = std.posix.getenv("VIBEUTILS_STYLE");

    // Set TERM so ColorMode.detect returns a non-none color mode.
    // Remove NO_COLOR and VIBEUTILS_STYLE so they don't suppress colors.
    _ = setenv("TERM", "xterm-256color", 1);
    _ = unsetenv("NO_COLOR");
    _ = unsetenv("VIBEUTILS_STYLE");

    defer {
        // Restore original environment
        if (orig_term) |t| {
            _ = setenv("TERM", t.ptr, 1);
        } else {
            _ = unsetenv("TERM");
        }
        if (orig_no_color) |nc| {
            _ = setenv("NO_COLOR", nc.ptr, 1);
        } else {
            _ = unsetenv("NO_COLOR");
        }
        if (orig_style) |vs| {
            _ = setenv("VIBEUTILS_STYLE", vs.ptr, 1);
        } else {
            _ = unsetenv("VIBEUTILS_STYLE");
        }
    }

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    // Run df on "/" which always exists. The output goes to an ArrayList
    // buffer, not a terminal. No ANSI escapes should appear because
    // the output destination is not a tty.
    const args = [_][]const u8{"/"};
    const result = runDf(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);

    // The isTty() gate on color_mode_int ensures ANSI codes do not
    // leak into non-tty output even when TERM indicates color support.
    try testing.expect(stdout_buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\x1b[") == null);
}

// ============================================================================
// Tests for visual redesign (Steps 2-7)
// ============================================================================

test "usageGradientRgb - key points" {
    // 0%: should be green-ish
    const at_0 = usageGradientRgb(0);
    try testing.expectEqual(@as(u8, 100), at_0.r);
    try testing.expectEqual(@as(u8, 200), at_0.g);
    try testing.expectEqual(@as(u8, 100), at_0.b);

    // 100%: should be red-ish
    const at_100 = usageGradientRgb(100);
    try testing.expectEqual(@as(u8, 220), at_100.r);
    try testing.expect(at_100.g < 70); // should be around 60
    try testing.expect(at_100.b > 50); // should be around 60

    // 70%: transition from green-yellow to yellow-orange
    const at_70 = usageGradientRgb(70);
    try testing.expectEqual(@as(u8, 220), at_70.r);
    try testing.expectEqual(@as(u8, 200), at_70.g);
}

test "smartFormatSource - fits" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/dev/disk3s1", smartFormatSource(&buf, "/dev/disk3s1", 20));
}

test "smartFormatSource - TimeMachine extraction" {
    var buf: [128]u8 = undefined;
    const result = smartFormatSource(&buf, "com.apple.TimeMachine@/dev/disk5s1", 20);
    try testing.expectEqualStrings("/dev/disk5s1", result);
}

test "smartFormatSource - generic truncation" {
    var buf: [128]u8 = undefined;
    const result = smartFormatSource(&buf, "very-long-source-name-here", 10);
    try testing.expectEqual(@as(usize, 10), result.len);
    try testing.expectEqual(@as(u8, '~'), result[0]);
}

test "smartFormatMount - fits" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/", smartFormatMount(&buf, "/", 20));
    try testing.expectEqualStrings("/System/Volumes", smartFormatMount(&buf, "/System/Volumes", 20));
}

test "smartFormatMount - needs abbreviation" {
    var buf: [128]u8 = undefined;
    const result = smartFormatMount(&buf, "/System/Volumes/Data/Users/someone/Library", 15);
    try testing.expect(result.len <= 15);
    try testing.expectEqual(@as(u8, '~'), result[0]);
}

test "classifyFs - local" {
    try testing.expectEqual(FsClass.local, classifyFs("/dev/disk1", "apfs", "/"));
    try testing.expectEqual(FsClass.local, classifyFs("/dev/sda1", "ext4", "/home"));
}

test "classifyFs - network" {
    try testing.expectEqual(FsClass.network, classifyFs("server:/share", "nfs", "/mnt"));
    try testing.expectEqual(FsClass.network, classifyFs("//server/share", "cifs", "/mnt"));
}

test "classifyFs - cloud" {
    try testing.expectEqual(FsClass.cloud, classifyFs("OrbStack:/data", "virtiofs", "/OrbStack"));
    try testing.expectEqual(FsClass.cloud, classifyFs("rclone:remote", "fuse.rclone", "/mnt"));
}

test "classifyFs - virtual" {
    try testing.expectEqual(FsClass.virtual, classifyFs("tmpfs", "tmpfs", "/tmp"));
    try testing.expectEqual(FsClass.virtual, classifyFs("proc", "proc", "/proc"));
}

test "classifyFs - backup" {
    try testing.expectEqual(FsClass.backup, classifyFs("/dev/disk9s1", "apfs", "/Volumes/Backups of tcole-mbpro"));
    try testing.expectEqual(FsClass.backup, classifyFs("//user@nas/share", "smbfs", "/Volumes/Time Machine Backups"));
}

test "classifyFs - snapshot" {
    try testing.expectEqual(FsClass.snapshot, classifyFs("com.apple.TimeMachine.2026-03-11-203149.local@/dev/disk3s5", "apfs", "/Volumes/.timemachine/data"));
}

test "isTimeMachineSnapshot - detection" {
    try testing.expect(isTimeMachineSnapshot("com.apple.TimeMachine.2026-03-11-203149.local@/dev/disk3s5"));
    try testing.expect(isTimeMachineSnapshot("com.apple.TimeMachine.2026-03-06-214229.backup@/dev/disk9s1"));
    try testing.expect(!isTimeMachineSnapshot("/dev/disk1s1"));
    try testing.expect(!isTimeMachineSnapshot("OrbStack:/data"));
}

test "isTimeMachineBackup - detection" {
    try testing.expect(isTimeMachineBackup("/dev/disk9s1", "/Volumes/Backups of tcole-mbpro"));
    try testing.expect(isTimeMachineBackup("//user@nas/share", "/Volumes/Time Machine Backups"));
    try testing.expect(!isTimeMachineBackup("/dev/disk1s1", "/"));
    try testing.expect(!isTimeMachineBackup("/dev/disk1s1", "/System/Volumes/Data"));
}

test "computeColumnWidths - minimum widths" {
    const widths = computeColumnWidths(&.{}, .{});
    try testing.expect(widths.filesystem >= 10);
    try testing.expect(widths.size >= 4);
}

test "padLeft - basic" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const writer = buffer.writer(testing.allocator);
    try padLeft(writer, "hi", 5);
    try testing.expectEqualStrings("   hi", buffer.items);
}

test "padRight - basic" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);
    const writer = buffer.writer(testing.allocator);
    try padRight(writer, "hi", 5);
    try testing.expectEqualStrings("hi   ", buffer.items);
}

test "getFsIcon - returns correct icons" {
    const theme = common.icons.IconTheme{};
    try testing.expectEqualStrings(theme.disk, getFsIcon(.local));
    try testing.expectEqualStrings(theme.network_fs, getFsIcon(.network));
    try testing.expectEqualStrings(theme.cloud, getFsIcon(.cloud));
    try testing.expectEqualStrings(theme.virtual_fs, getFsIcon(.virtual));
    try testing.expectEqualStrings(theme.backup, getFsIcon(.backup));
    try testing.expectEqualStrings(theme.snapshot, getFsIcon(.snapshot));
}

test "isCloudFs - FUSE types" {
    try testing.expect(isCloudFs("anything", "fuse.rclone"));
    try testing.expect(isCloudFs("anything", "fuse.sshfs"));
    try testing.expect(!isCloudFs("anything", "apfs"));
}

test "isCloudFs - VM types" {
    try testing.expect(isCloudFs("anything", "virtiofs"));
    try testing.expect(isCloudFs("anything", "9p"));
}

test "isCloudFs - source patterns" {
    try testing.expect(isCloudFs("OrbStack:/data", "ext4"));
    try testing.expect(isCloudFs("rclone:remote", "ext4"));
    try testing.expect(isCloudFs("sshfs#host:/path", "ext4"));
    try testing.expect(!isCloudFs("/dev/sda1", "ext4"));
}

test "parseArgs - n flag accepted as no-op" {
    if (comptime is_linux) return error.SkipZigTest;
    const args = [_][]const u8{"-n"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.no_sync);
}

test "parseArgs - n combined with other flags" {
    if (comptime is_linux) return error.SkipZigTest;
    const args = [_][]const u8{"-an"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.all);
    try testing.expect(parsed.opts.no_sync);
}

test "runDf - n flag accepted" {
    if (comptime is_linux) return error.SkipZigTest;
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-n"};
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
}

// ============================================================================
// Tests for new macOS-compatible flags
// ============================================================================

test "parseArgs - b flag sets 512 block size" {
    const args = [_][]const u8{"-b"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqual(@as(?u64, 512), parsed.opts.block_size);
    try testing.expect(!parsed.opts.human_readable);
}

test "parseArgs - c flag sets total" {
    const args = [_][]const u8{"-c"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.total);
}

test "parseArgs - g flag sets 1G block size" {
    const args = [_][]const u8{"-g"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqual(@as(?u64, 1073741824), parsed.opts.block_size);
    try testing.expect(!parsed.opts.human_readable);
}

test "parseArgs - I flag sets exclude type" {
    const args = [_][]const u8{ "-I", "tmpfs" };
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("tmpfs", parsed.opts.exclude_type.?);
}

test "parseArgs - I flag inline value" {
    const args = [_][]const u8{"-Itmpfs"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("tmpfs", parsed.opts.exclude_type.?);
}

test "parseArgs - I flag missing argument" {
    const args = [_][]const u8{"-I"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err != null);
}

test "parseArgs - m flag sets 1M block size" {
    const args = [_][]const u8{"-m"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqual(@as(?u64, 1048576), parsed.opts.block_size);
    try testing.expect(!parsed.opts.human_readable);
}

test "parseArgs - Y flag accepted as no-op" {
    const args = [_][]const u8{"-Y"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
}

test "parseArgs - comma flag sets thousands grouping" {
    const args = [_][]const u8{"-,"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.thousands_grouping);
}

test "parseArgs - combined new flags" {
    const args = [_][]const u8{"-bgm"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    // -m is last, so block_size should be 1M
    try testing.expectEqual(@as(?u64, 1048576), parsed.opts.block_size);
    try testing.expect(!parsed.opts.human_readable);
}

test "formatWithCommas - small numbers" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", formatWithCommas(&buf, 0));
    try testing.expectEqualStrings("1", formatWithCommas(&buf, 1));
    try testing.expectEqualStrings("999", formatWithCommas(&buf, 999));
}

test "formatWithCommas - thousands" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1,000", formatWithCommas(&buf, 1000));
    try testing.expectEqualStrings("1,234", formatWithCommas(&buf, 1234));
    try testing.expectEqualStrings("12,345", formatWithCommas(&buf, 12345));
    try testing.expectEqualStrings("123,456", formatWithCommas(&buf, 123456));
}

test "formatWithCommas - millions" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1,000,000", formatWithCommas(&buf, 1000000));
    try testing.expectEqualStrings("1,234,567", formatWithCommas(&buf, 1234567));
}

test "formatWithCommas - large numbers" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1,000,000,000", formatWithCommas(&buf, 1000000000));
}

test "formatSize - 512 byte blocks with comma" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = 512;
    opts.thousands_grouping = true;
    // 1000 blocks * 4096 = 4096000 bytes / 512 = 8000 blocks
    const result = formatSize(&buf, 1000, 4096, opts);
    try testing.expectEqualStrings("8,000", result);
}

test "formatSize - 1G blocks" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = 1024 * 1024 * 1024;
    // 1000000 blocks * 4096 = 4096000000 bytes / 1G = ~3.8 -> rounds to 4
    const result = formatSize(&buf, 1000000, 4096, opts);
    try testing.expectEqualStrings("4", result);
}

test "formatSize - 1M blocks" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = 1024 * 1024;
    // 1000 blocks * 4096 = 4096000 bytes / 1M = ~3.9 -> rounds to 4
    const result = formatSize(&buf, 1000, 4096, opts);
    try testing.expectEqualStrings("4", result);
}

test "runDf - b flag accepted" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-b", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "512B-blocks") != null);
}

test "runDf - c flag shows total" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "total") != null);
}

test "runDf - g flag accepted" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-g", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "1G-blocks") != null);
}

test "runDf - m flag accepted" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "1M-blocks") != null);
}

test "runDf - Y flag accepted" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-Y"};
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
}

test "runDf - comma flag accepted" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-,", "-k", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
}

test "runDf - help mentions new flags" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "-b") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "-g") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "-m") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "-Y") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "-,") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "-I") != null);
}

// ============================================================================
// F19: df -I has wrong semantics (macOS-only boolean flag)
// On macOS, -I means "suppress inode counts" and takes no argument.
// The current implementation wrongly treats -I as an exclude-type filter
// requiring an argument on all platforms.
// ============================================================================

test "parseArgs - I flag without argument accepted on macOS" {
    // On macOS, -I is a boolean flag meaning "suppress inode counts".
    // It should parse without error when given no argument.
    if (comptime !is_darwin) return error.SkipZigTest;
    const args = [_][]const u8{"-I"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    // On macOS, -I alone should NOT be an error
    try testing.expect(parsed.err == null);
}

test "runDf - I flag without argument succeeds on macOS" {
    // On macOS, `df -I /` should succeed (suppress inode counts).
    if (comptime !is_darwin) return error.SkipZigTest;
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-I", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    // Should succeed, not treat "/" as the argument to -I
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Filesystem") != null);
}

// ============================================================================
// F20: df -P uses wrong POSIX column headers
// POSIX requires: "1024-blocks", "Available", "Capacity"
// Current code emits: "1K-blocks", "Available", "Use%"
// ============================================================================

test "printHeader - POSIX mode uses 1024-blocks not 1K-blocks" {
    // POSIX (df -P) requires the header column to read "1024-blocks",
    // not "1K-blocks". See IEEE Std 1003.1-2017 df specification.
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    var opts = DfOptions{};
    opts.portability = true;
    opts.human_readable = false;
    opts.display.color = .off;
    opts.display.icons = .off;
    try printHeader(buf.writer(testing.allocator), opts);
    // POSIX mandates "1024-blocks"
    try testing.expect(std.mem.indexOf(u8, buf.items, "1024-blocks") != null);
}

test "printHeader - POSIX mode uses Capacity not Use%" {
    // POSIX requires the percentage column to be labeled "Capacity",
    // not "Use%". See IEEE Std 1003.1-2017 df specification.
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);
    var opts = DfOptions{};
    opts.portability = true;
    opts.human_readable = false;
    opts.display.color = .off;
    opts.display.icons = .off;
    try printHeader(buf.writer(testing.allocator), opts);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Capacity") != null);
}

test "runDf - P flag output has POSIX-compliant headers" {
    // Full integration: df -P / should produce POSIX headers.
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-P", "/" };
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    // POSIX requires "1024-blocks", not "1K-blocks"
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "1024-blocks") != null);
    // POSIX requires "Capacity", not "Use%"
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Capacity") != null);
}

// ============================================================================
// F21: df -n is a stub (should be rejected on Linux)
// GNU df does not have -n. On Linux, it should be rejected as an
// unrecognized option (exit code 2), not silently accepted.
// ============================================================================

test "parseArgs - n flag rejected on Linux" {
    // GNU df does not support -n. On Linux, this should be an
    // unrecognized option, not silently accepted as a no-op.
    if (comptime !is_linux) return error.SkipZigTest;
    const args = [_][]const u8{"-n"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err != null);
}

test "runDf - n flag returns misuse on Linux" {
    // On Linux, -n is not a valid GNU df flag and should exit with
    // misuse (exit code 2).
    if (comptime !is_linux) return error.SkipZigTest;
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-n"};
    const result = runDf(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}
