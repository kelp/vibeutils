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
    const lc = @cImport({
        @cInclude("sys/statvfs.h");
    });
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
    human_readable: bool = false,
    si: bool = false,
    inodes: bool = false,
    block_1k: bool = false,
    local: bool = false,
    portability: bool = false,
    print_type: bool = false,
    total: bool = false,
    help: bool = false,
    version: bool = false,
    block_size: ?u64 = null,
    include_type: ?[]const u8 = null,
    exclude_type: ?[]const u8 = null,
    output_fields: ?[]const u8 = null,
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
            } else if (std.mem.eql(u8, arg, "--block-size")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.block_size = parseBlockSize(args[i]) orelse {
                        err_msg = "invalid --block-size argument";
                        break;
                    };
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
                'k' => opts.block_1k = true,
                'l' => opts.local = true,
                'P' => opts.portability = true,
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
    if (s.len == 0) return null;

    var num_end: usize = 0;
    while (num_end < s.len and (s[num_end] >= '0' and s[num_end] <= '9')) {
        num_end += 1;
    }

    if (num_end == 0) {
        // No digits -- just a suffix like "K" means 1K
        return parseSuffix(s, 1);
    }

    const num = std.fmt.parseInt(u64, s[0..num_end], 10) catch return null;
    if (num_end == s.len) return num;

    return parseSuffix(s[num_end..], num);
}

fn parseSuffix(suffix: []const u8, base: u64) ?u64 {
    if (suffix.len == 0) return base;
    return switch (suffix[0]) {
        'K', 'k' => base * 1024,
        'M', 'm' => base * 1024 * 1024,
        'G', 'g' => base * 1024 * 1024 * 1024,
        'T', 't' => base * 1024 * 1024 * 1024 * 1024,
        else => null,
    };
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
            .used_blocks = fs.f_blocks - fs.f_bfree,
            .avail_blocks = fs.f_bavail,
            .block_size = fs.f_bsize,
            .total_inodes = fs.f_files,
            .used_inodes = fs.f_files - fs.f_ffree,
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
        .used_blocks = sfs.f_blocks - sfs.f_bfree,
        .avail_blocks = sfs.f_bavail,
        .block_size = sfs.f_bsize,
        .total_inodes = sfs.f_files,
        .used_inodes = sfs.f_files - sfs.f_ffree,
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

        var svfs: linux_c.lc.struct_statvfs = undefined;
        const ret = linux_c.lc.statvfs(c_path, &svfs);
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

    var svfs: linux_c.lc.struct_statvfs = undefined;
    const ret = linux_c.lc.statvfs(c_path, &svfs);
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
// Human-readable formatting
// ============================================================================

fn formatHumanReadable(buf: []u8, bytes: u64, use_si: bool) []const u8 {
    const base: u64 = if (use_si) 1000 else 1024;
    const suffixes = if (use_si)
        [_]u8{ 'B', 'k', 'M', 'G', 'T', 'P', 'E' }
    else
        [_]u8{ 'B', 'K', 'M', 'G', 'T', 'P', 'E' };

    if (bytes < base) {
        return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "?";
    }

    var value: f64 = @floatFromInt(bytes);
    var suffix_idx: usize = 0;

    while (value >= @as(f64, @floatFromInt(base)) and suffix_idx < suffixes.len - 1) {
        value /= @as(f64, @floatFromInt(base));
        suffix_idx += 1;
    }

    if (value >= 10.0) {
        return std.fmt.bufPrint(buf, "{d:.0}{c}", .{
            value, suffixes[suffix_idx],
        }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}{c}", .{
            value, suffixes[suffix_idx],
        }) catch "?";
    }
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
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

fn formatPercent(buf: []u8, used: u64, total: u64) []const u8 {
    if (total == 0) return "-";
    // GNU df uses ceiling for percentage: (used * 100 + total - 1) / total
    const pct = @divTrunc(used * 100 + total - 1, total);
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "?";
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
            if (bs == 1024) break :blk "1K-blocks";
            if (bs == 1024 * 1024) break :blk "1M-blocks";
            if (bs == 1024 * 1024 * 1024) break :blk "1G-blocks";
            break :blk std.fmt.bufPrint(&size_label_buf, "{d}B-blocks", .{bs}) catch "blocks";
        }
        break :blk "1K-blocks";
    };

    if (opts.print_type) {
        try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
            "Filesystem",
            "Type",
            size_label,
            "Used",
            "Available",
            "Use%",
            "Mounted on",
        });
    } else {
        try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
            "Filesystem",
            size_label,
            "Used",
            "Available",
            "Use%",
            "Mounted on",
        });
    }
}

fn printFsRow(stdout: anytype, fs: FsInfo, opts: DfOptions) !void {
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

    if (opts.print_type) {
        try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
            fs.source,
            fs.fstype,
            total_str,
            used_str,
            avail_str,
            pct_str,
            fs.mount_point,
        });
    } else {
        try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
            fs.source,
            total_str,
            used_str,
            avail_str,
            pct_str,
            fs.mount_point,
        });
    }
}

fn printTotal(stdout: anytype, filesystems: []const FsInfo, opts: DfOptions) !void {
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
        break :blk std.fmt.bufPrint(&total_buf, "{d}", .{val}) catch "?";
    };
    const used_str = blk: {
        if (opts.human_readable) {
            break :blk formatHumanReadable(&used_buf, sum_used_bytes, false);
        } else if (opts.si) {
            break :blk formatHumanReadable(&used_buf, sum_used_bytes, true);
        }
        const val = @divTrunc(sum_used_bytes + display_block - 1, display_block);
        break :blk std.fmt.bufPrint(&used_buf, "{d}", .{val}) catch "?";
    };
    const avail_str = blk: {
        if (opts.human_readable) {
            break :blk formatHumanReadable(&avail_buf, sum_avail_bytes, false);
        } else if (opts.si) {
            break :blk formatHumanReadable(&avail_buf, sum_avail_bytes, true);
        }
        const val = @divTrunc(sum_avail_bytes + display_block - 1, display_block);
        break :blk std.fmt.bufPrint(&avail_buf, "{d}", .{val}) catch "?";
    };
    const sum_use_total = sum_used_bytes + sum_avail_bytes;
    const pct_str = if (sum_use_total == 0)
        "-"
    else blk: {
        const pct = @divTrunc(sum_used_bytes * 100 + sum_use_total - 1, sum_use_total);
        break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "?";
    };

    if (opts.print_type) {
        try stdout.print("{s:<15} {s:<6} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
            "total", "-", total_str, used_str, avail_str, pct_str, "-",
        });
    } else {
        try stdout.print("{s:<15} {s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
            "total", total_str, used_str, avail_str, pct_str, "-",
        });
    }
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

    var exit_code: u8 = @intFromEnum(common.ExitCode.success);

    if (opts.positionals.len > 0) {
        // Show filesystems for specific paths
        printHeader(stdout, opts) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };

        var displayed = std.ArrayListUnmanaged(FsInfo){};
        defer {
            for (displayed.items) |fs| freeFsInfo(allocator, fs);
            displayed.deinit(allocator);
        }

        for (opts.positionals) |path| {
            const fs = getFilesystemForPath(allocator, path) catch {
                common.printErrorWithProgram(allocator, stderr, prog_name, "cannot access '{s}': No such file or directory", .{path});
                exit_code = @intFromEnum(common.ExitCode.general_error);
                continue;
            };
            if (shouldIncludeFs(fs, opts)) {
                printFsRow(stdout, fs, opts) catch {};
                displayed.append(allocator, fs) catch {};
            } else {
                freeFsInfo(allocator, fs);
            }
        }

        if (opts.total and displayed.items.len > 0) {
            printTotal(stdout, displayed.items, opts) catch {};
        }
    } else {
        // Show all mounted filesystems
        const all_fs = getMountedFilesystems(allocator) catch {
            common.printErrorWithProgram(allocator, stderr, prog_name, "cannot read table of mounted file systems", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer freeFsInfoSlice(allocator, all_fs);

        printHeader(stdout, opts) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };

        for (all_fs) |fs| {
            if (shouldIncludeFs(fs, opts)) {
                printFsRow(stdout, fs, opts) catch {};
            }
        }

        if (opts.total) {
            // Collect displayed items for the total line
            var displayed = std.ArrayListUnmanaged(FsInfo){};
            defer displayed.deinit(allocator);
            for (all_fs) |fs| {
                if (shouldIncludeFs(fs, opts)) {
                    displayed.append(allocator, fs) catch {};
                }
            }
            if (displayed.items.len > 0) {
                printTotal(stdout, displayed.items, opts) catch {};
            }
        }
    }

    return exit_code;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
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
        \\  -a, --all             include pseudo, duplicate, inaccessible file systems
        \\  -h, --human-readable  print sizes in powers of 1024 (e.g., 1023M)
        \\  -H, --si              print sizes in powers of 1000 (e.g., 1.1G)
        \\  -i, --inodes          list inode information instead of block usage
        \\  -k                    like --block-size=1K
        \\  -l, --local           limit listing to local file systems
        \\  -P, --portability     use the POSIX output format
        \\  -T, --print-type      print file system type
        \\  -t, --type=TYPE       limit listing to file systems of type TYPE
        \\  -x, --exclude-type=TYPE  limit listing to file systems not of type TYPE
        \\      --block-size=SIZE  scale sizes by SIZE before printing them
        \\      --total            produce a grand total
        \\      --output[=FIELD_LIST]  use the output format defined by FIELD_LIST
        \\      --help             display this help and exit
        \\      --version          output version information and exit
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
    try testing.expectEqual(@as(?u64, 0), parseBlockSize("0"));
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
    try testing.expect(!parsed.opts.human_readable);
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
    try testing.expect(parsed.opts.human_readable);
    try testing.expect(parsed.opts.inodes);
    try testing.expect(parsed.opts.print_type);
    try testing.expect(parsed.opts.local);
    try testing.expect(parsed.opts.portability);
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
    try testing.expect(!parsed.opts.human_readable);
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

test "formatSize - 1K-blocks default" {
    var buf: [32]u8 = undefined;
    const opts = DfOptions{};
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
