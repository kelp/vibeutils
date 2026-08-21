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
    display: common.display_config.DisplayConfig = .{
        .color = .off,
        .icons = .off,
        .highlight = .off,
        .theme = .none,
    },
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
    suppress_inodes: bool = false,
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
    /// The operand this entry was resolved from, verbatim, for the
    /// --output=file column. Null when the entry came from the mount
    /// table rather than a command-line path.
    file: ?[]const u8 = null,
};

// ============================================================================
// --output field selection
// ============================================================================

/// The twelve GNU df --output fields. The declaration order is GNU's
/// canonical order, which bare --output expands to; an explicit list is
/// rendered in the order the user wrote it instead.
const OutputField = enum {
    source,
    fstype,
    itotal,
    iused,
    iavail,
    ipcent,
    size,
    used,
    avail,
    pcent,
    file,
    target,
};

const output_field_max: u32 = 12;

/// Bare --output selects every field in canonical order.
const output_all_fields = "source,fstype,itotal,iused,iavail,ipcent," ++
    "size,used,avail,pcent,file,target";

/// A parsed --output list: the selected fields in the user's order.
/// Duplicates are rejected, so at most output_field_max entries fit.
const OutputSelection = struct {
    fields: [output_field_max]OutputField = undefined,
    len: u32 = 0,

    fn slice(self: *const OutputSelection) []const OutputField {
        std.debug.assert(self.len <= output_field_max);
        std.debug.assert(self.fields.len == output_field_max);
        return self.fields[0..self.len];
    }

    fn has(self: *const OutputSelection, field: OutputField) bool {
        std.debug.assert(self.len <= output_field_max);
        std.debug.assert(self.fields.len == output_field_max);
        for (self.fields[0..self.len]) |selected| {
            if (selected == field) return true;
        }
        return false;
    }
};

/// Why a --output list was rejected, carrying the offending field name so
/// the caller can render GNU's message text.
const OutputFieldError = struct {
    kind: enum { unknown, duplicate },
    name: []const u8,
};

/// Split a comma-separated --output list into `sel`. Returns null on
/// success. An empty list yields the unknown-field error with an empty
/// name, matching GNU, which has no special case for it.
fn parseOutputFields(list: []const u8, sel: *OutputSelection) ?OutputFieldError {
    std.debug.assert(sel.len == 0);
    std.debug.assert(sel.fields.len == output_field_max);
    var it = std.mem.splitScalar(u8, list, ',');
    // Bounded by output_field_max + 1: names are distinct past the
    // duplicate check, so the next repeat or unknown name returns.
    while (it.next()) |name| {
        const field = std.meta.stringToEnum(OutputField, name) orelse
            return .{ .kind = .unknown, .name = name };
        if (sel.has(field)) return .{ .kind = .duplicate, .name = name };
        std.debug.assert(sel.len < output_field_max);
        sel.fields[sel.len] = field;
        sel.len += 1;
    }
    return null;
}

/// Numeric fields are right-aligned; name and path fields are not.
fn outputFieldIsLeftAligned(field: OutputField) bool {
    std.debug.assert(@intFromEnum(field) >= 0);
    std.debug.assert(@intFromEnum(field) < output_field_max);
    return switch (field) {
        .source, .fstype, .file, .target => true,
        else => false,
    };
}

// ============================================================================
// Argument parsing (manual, for complex options)
// ============================================================================

fn parseArgs(
    allocator: Allocator,
    args: []const []const u8,
) struct { opts: DfOptions, err: ?[]const u8 } {
    var opts = DfOptions{};
    // Freshly constructed: positionals defaults to empty and is only assigned
    // its final value at the end via toOwnedSlice from the local list.
    std.debug.assert(opts.positionals.len == 0);
    opts.display = common.display_config.DisplayConfig.resolve(allocator);
    var err_msg: ?[]const u8 = null;
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
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
            const err = parseArgs_longOption(args, &i, arg, &opts);
            if (err != null or opts.help or opts.version) {
                err_msg = err;
                break;
            }
            continue;
        }

        // Short options
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            if (parseArgs_shortOption(args, &i, arg, &j, &opts)) |msg| {
                err_msg = msg;
                break;
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

// Dispatch one long option (arg starts with "--"). Mutates opts and the
// argv cursor i for value consumption. Returns an error string or null.
fn parseArgs_longOption(
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch indexes args slice
    arg: []const u8,
    opts: *DfOptions,
) ?[]const u8 {
    std.debug.assert(arg.len > 1);
    std.debug.assert(arg[0] == '-');
    if (parseArgs_longOptionBool(arg, opts)) {
        return null;
    }
    const result = parseArgs_longOptionValued(args, i, arg, opts);
    if (result.matched) {
        return result.err;
    }
    return "unrecognized option";
}

// Handle the boolean/portability long options. Returns true if arg matched.
fn parseArgs_longOptionBool(arg: []const u8, opts: *DfOptions) bool {
    std.debug.assert(arg.len > 1);
    std.debug.assert(arg[1] == '-');
    if (std.mem.eql(u8, arg, "--help")) {
        opts.help = true;
    } else if (std.mem.eql(u8, arg, "--version")) {
        opts.version = true;
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
        // See the 'P' short-option arm for why this clears human_readable.
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
    } else {
        return false;
    }
    return true;
}

// Handle the value-consuming long options. `matched` is false when arg is
// not one of these options; otherwise err carries any parse error.
fn parseArgs_longOptionValued(
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch indexes args slice
    arg: []const u8,
    opts: *DfOptions,
) struct { matched: bool, err: ?[]const u8 } {
    std.debug.assert(arg.len > 1);
    std.debug.assert(arg[0] == '-');
    std.debug.assert(i.* < args.len);
    if (std.mem.startsWith(u8, arg, "--block-size=")) {
        const val = arg["--block-size=".len..];
        opts.block_size = parseBlockSize(val) orelse
            return .{ .matched = true, .err = "invalid --block-size argument" };
        opts.human_readable = false;
    } else if (std.mem.eql(u8, arg, "--block-size")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.block_size = parseBlockSize(args[i.*]) orelse
                return .{ .matched = true, .err = "invalid --block-size argument" };
            opts.human_readable = false;
        } else {
            return .{ .matched = true, .err = "option '--block-size' requires an argument" };
        }
    } else if (std.mem.startsWith(u8, arg, "--type=")) {
        opts.include_type = arg["--type=".len..];
    } else if (std.mem.eql(u8, arg, "--type")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.include_type = args[i.*];
        } else {
            return .{ .matched = true, .err = "option '--type' requires an argument" };
        }
    } else if (std.mem.startsWith(u8, arg, "--exclude-type=")) {
        opts.exclude_type = arg["--exclude-type=".len..];
    } else if (std.mem.eql(u8, arg, "--exclude-type")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.exclude_type = args[i.*];
        } else {
            return .{ .matched = true, .err = "option '--exclude-type' requires an argument" };
        }
    } else if (std.mem.startsWith(u8, arg, "--output=")) {
        opts.output_fields = arg["--output=".len..];
    } else if (std.mem.eql(u8, arg, "--output")) {
        // Bare --output means every field, not a curated subset.
        opts.output_fields = output_all_fields;
    } else {
        return .{ .matched = false, .err = null };
    }
    return .{ .matched = true, .err = null };
}

// Dispatch one short-option character arg[j.*]. Mutates the argv cursor i,
// the inner cursor j, and opts. Returns an error string or null.
fn parseArgs_shortOption(
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch indexes args slice
    arg: []const u8,
    j: *usize, // tiger:allow:usize-arch indexes arg slice
    opts: *DfOptions,
) ?[]const u8 {
    std.debug.assert(arg.len > 0);
    std.debug.assert(j.* < arg.len);
    if (parseArgs_shortOptionSimple(arg, j.*, opts)) |result| {
        return result.err;
    }
    return parseArgs_shortOptionValued(args, i, arg, j, opts);
}

// Handle single-character boolean/block-size short options. Returns null
// when c is a value-consuming option (handled elsewhere); otherwise the
// result's err is set for unrecognized options.
fn parseArgs_shortOptionSimple(
    arg: []const u8,
    j: usize, // tiger:allow:usize-arch indexes arg slice
    opts: *DfOptions,
) ?struct { err: ?[]const u8 } {
    std.debug.assert(arg.len > 0);
    std.debug.assert(j < arg.len);
    switch (arg[j]) {
        'a' => opts.all = true,
        'h' => opts.human_readable = true,
        'H' => opts.si = true,
        'i' => {
            opts.inodes = true;
            // BSD resolves -i/-I last-flag-wins, so a later -i undoes -I.
            opts.suppress_inodes = false;
        },
        'k' => {
            opts.block_1k = true;
            opts.human_readable = false;
        },
        'l' => opts.local = true,
        'n' => {
            if (comptime is_linux) {
                return .{ .err = "unrecognized option" };
            }
            opts.no_sync = true;
        },
        // Clearing human_readable here is a deliberate divergence from GNU,
        // not an oversight. GNU never lets -P turn human mode off, but GNU
        // defaults to block mode, so its bare `df -P` is POSIX anyway. We
        // default human_readable = true, so if -P left it set, bare `df -P`
        // would print human-readable sizes and be useless to the POSIX
        // consumers the flag exists for. The consequence is last-wins:
        // `-h -P` yields block+POSIX (correct for us), while `-P -h` puts
        // us back in human mode and must then use the DEFAULT header set,
        // not the POSIX one. Do not "fix" the `-h -P` ordering toward GNU.
        'P' => {
            opts.portability = true;
            opts.human_readable = false;
            opts.display.color = .off;
            opts.display.icons = .off;
            opts.display.highlight = .off;
            opts.display.theme = .none;
        },
        'T' => opts.print_type = true,
        'b' => {
            opts.block_size = 512;
            opts.human_readable = false;
        },
        'c' => opts.total = true,
        'g' => {
            opts.block_size = 1024 * 1024 * 1024;
            opts.human_readable = false;
        },
        'm' => {
            opts.block_size = 1024 * 1024;
            opts.human_readable = false;
        },
        'Y' => {}, // no-op: don't resolve NFS paths
        ',' => opts.thousands_grouping = true,
        else => return null,
    }
    return .{ .err = null };
}

// Handle value-consuming short options (t, x, and Linux -I). Each arm sets
// j to arg.len so the parent's inner loop terminates after consuming the
// value. Returns an error string or null.
fn parseArgs_shortOptionValued(
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch indexes args slice
    arg: []const u8,
    j: *usize, // tiger:allow:usize-arch indexes arg slice
    opts: *DfOptions,
) ?[]const u8 {
    std.debug.assert(arg.len > 0);
    std.debug.assert(j.* < arg.len);
    // The parent only enters the short-option loop with a valid current arg
    // at index i.*; value-consuming arms advance i.* only after a bounds check.
    std.debug.assert(i.* < args.len);
    switch (arg[j.*]) {
        't' => {
            var err: ?[]const u8 = null;
            if (j.* + 1 < arg.len) {
                opts.include_type = arg[j.* + 1 ..];
            } else if (i.* + 1 < args.len) {
                i.* += 1;
                opts.include_type = args[i.*];
            } else {
                err = "option '-t' requires an argument";
            }
            j.* = arg.len;
            return err;
        },
        'x' => {
            var err: ?[]const u8 = null;
            if (j.* + 1 < arg.len) {
                opts.exclude_type = arg[j.* + 1 ..];
            } else if (i.* + 1 < args.len) {
                i.* += 1;
                opts.exclude_type = args[i.*];
            } else {
                err = "option '-x' requires an argument";
            }
            j.* = arg.len;
            return err;
        },
        'I' => {
            if (comptime is_darwin) {
                // macOS: -I is a boolean flag meaning "suppress inode
                // counts". BSD resolves -i/-I last-flag-wins, so it
                // cancels any preceding -i outright.
                opts.suppress_inodes = true;
                opts.inodes = false;
                return null;
            }
            // Linux/GNU: -I is an exclude-type filter requiring an argument
            var err: ?[]const u8 = null;
            if (j.* + 1 < arg.len) {
                opts.exclude_type = arg[j.* + 1 ..];
            } else if (i.* + 1 < args.len) {
                i.* += 1;
                opts.exclude_type = args[i.*];
            } else {
                err = "option '-I' requires an argument";
            }
            j.* = arg.len;
            return err;
        },
        else => {
            // Reached only for the unrecognized-option case routed here from
            // parseArgs_shortOption when the simple dispatcher returned null.
            return "unrecognized option";
        },
    }
}

/// Parse a block size string like "1K", "1M", "1G", or a plain number.
/// Reject a zero result (e.g. "0K") so callers never divide by a zero
/// display block; "0" is already rejected by the shared parser.
fn parseBlockSize(s: []const u8) ?u64 {
    const value = common.format.parseBlockSize(s) orelse return null;
    if (value == 0) return null;
    return value;
}

// ============================================================================
// Filesystem enumeration (platform-specific)
// ============================================================================

fn getMountedFilesystems(io: std.Io, allocator: Allocator) ![]FsInfo {
    if (comptime is_darwin) {
        return getMountedFilesystemsDarwin(allocator);
    } else if (comptime is_linux) {
        return getMountedFilesystemsLinux(io, allocator);
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
    // The buffer holds ucount entries; the second getfsstat cannot report more
    // than fit, so slicing buf[0..actual_count] stays within the allocation.
    std.debug.assert(actual_count <= ucount);
    var result: std.ArrayListUnmanaged(FsInfo) = .empty;

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

fn getFilesystemForPath(io: std.Io, allocator: Allocator, path: []const u8) !FsInfo {
    if (comptime is_darwin) {
        return getFilesystemForPathDarwin(allocator, path);
    } else if (comptime is_linux) {
        return getFilesystemForPathLinux(io, allocator, path);
    } else {
        @compileError("df: unsupported platform");
    }
}

fn getFilesystemForPathDarwin(allocator: Allocator, path: []const u8) !FsInfo {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
    // Past the guard: path fits, and path_buf has room for the bytes plus NUL.
    std.debug.assert(path.len <= std.Io.Dir.max_path_bytes);
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    var sfs: StatFs = undefined;
    const ret = darwin_c.statfs(c_path, &sfs);
    if (ret != 0) {
        return switch (std.c.errno(ret)) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            else => error.SystemResources,
        };
    }

    // Dupe strings so they outlive the stack-local StatFs. Bind each
    // dupe to a local with an errdefer so a later dupe failure unwinds
    // the earlier allocations (audit G2).
    const source = try allocator.dupe(u8, extractCString(&sfs.f_mntfromname));
    errdefer allocator.free(source);
    const fstype = try allocator.dupe(u8, extractCString(&sfs.f_fstypename));
    errdefer allocator.free(fstype);
    const mount_point = try allocator.dupe(u8, extractCString(&sfs.f_mntonname));
    errdefer allocator.free(mount_point);

    return FsInfo{
        .source = source,
        .fstype = fstype,
        .mount_point = mount_point,
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

fn getMountedFilesystemsLinux(io: std.Io, allocator: Allocator) ![]FsInfo {
    var buf: [32768]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, "/proc/mounts", &buf) catch {
        return error.SystemResources;
    };

    var result: std.ArrayListUnmanaged(FsInfo) = .empty;

    // /proc/mounts format: device mountpoint fstype options dump pass
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        var iter = std.mem.splitScalar(u8, line, ' ');
        const source_raw = iter.next() orelse continue;
        const mount_point_raw = iter.next() orelse continue;
        const fstype_raw = iter.next() orelse continue;

        // statvfs the mount point
        var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (mount_point_raw.len > std.Io.Dir.max_path_bytes) continue;
        // Past the guard: the mount point fits, so the copy and the NUL write
        // at path_buf[mount_point_raw.len] stay in bounds.
        std.debug.assert(mount_point_raw.len <= std.Io.Dir.max_path_bytes);
        @memcpy(path_buf[0..mount_point_raw.len], mount_point_raw);
        path_buf[mount_point_raw.len] = 0;
        const c_path = path_buf[0..mount_point_raw.len :0];

        var svfs: linux_c.Statvfs = undefined;
        const ret = linux_c.statvfs(c_path, &svfs);
        if (ret != 0) continue; // skip mount points we can't stat

        const source = allocator.dupe(u8, source_raw) catch return error.OutOfMemory;
        errdefer allocator.free(source);
        const mount_point = allocator.dupe(u8, mount_point_raw) catch return error.OutOfMemory;
        errdefer allocator.free(mount_point);
        const fstype = allocator.dupe(u8, fstype_raw) catch return error.OutOfMemory;
        errdefer allocator.free(fstype);

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

fn getFilesystemForPathLinux(io: std.Io, allocator: Allocator, path: []const u8) !FsInfo {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const c_path = try getFilesystemForPathLinux_resolveCPath(path, &path_buf);

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

    var mounts_buf: [32768]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, "/proc/mounts", &mounts_buf) catch {
        // Can't read mounts, return with what we have from statvfs
        return getFilesystemForPathLinux_makeInfo(allocator, svfs, "unknown", "unknown", path);
    };

    getFilesystemForPathLinux_matchMount(content, path, &best_source, &best_mount, &best_fstype);

    return getFilesystemForPathLinux_makeInfo(
        allocator,
        svfs,
        best_source,
        best_fstype,
        best_mount,
    );
}

fn getFilesystemForPathLinux_resolveCPath(path: []const u8, path_buf: []u8) ![:0]const u8 {
    comptime std.debug.assert(std.Io.Dir.max_path_bytes > 0);
    if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
    // Past the guard: the path fits and the caller's buffer is sized to hold
    // the bytes plus a null terminator.
    std.debug.assert(path.len <= std.Io.Dir.max_path_bytes);
    std.debug.assert(path_buf.len > path.len);
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return path_buf[0..path.len :0];
}

fn getFilesystemForPathLinux_matchMount(
    content: []const u8,
    path: []const u8,
    best_source: *[]const u8,
    best_mount: *[]const u8,
    best_fstype: *[]const u8,
) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(best_mount.*.len <= path.len);
    var best_len: usize = 0; // tiger:allow:usize-arch tracks a slice length
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        var iter = std.mem.splitScalar(u8, line, ' ');
        const src = iter.next() orelse continue;
        const mnt = iter.next() orelse continue;
        const fst = iter.next() orelse continue;

        // Find longest matching mount point prefix
        if (std.mem.startsWith(u8, path, mnt) and mnt.len > best_len) {
            best_source.* = src;
            best_mount.* = mnt;
            best_fstype.* = fst;
            best_len = mnt.len;
        }
    }
    // best_len only ever takes a matched mnt.len, and startsWith requires
    // mnt.len <= path.len, so the running best length never exceeds path.len.
    std.debug.assert(best_len <= path.len);
    std.debug.assert(best_mount.*.len <= path.len);
}

fn getFilesystemForPathLinux_makeInfo(
    allocator: Allocator,
    svfs: linux_c.Statvfs,
    src: []const u8,
    fst: []const u8,
    mnt: []const u8,
) !FsInfo {
    std.debug.assert(src.len > 0);
    std.debug.assert(fst.len > 0);
    // Bind each dupe to a local with an errdefer so a later dupe
    // failure unwinds the earlier allocations (audit G2).
    const source = try allocator.dupe(u8, src);
    errdefer allocator.free(source);
    const fstype = try allocator.dupe(u8, fst);
    errdefer allocator.free(fstype);
    const mount_point = try allocator.dupe(u8, mnt);
    errdefer allocator.free(mount_point);

    return FsInfo{
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
        // Loop guard holds on entry, so the inner read haystack[i + j] for
        // j in 0..needle.len is always within bounds.
        std.debug.assert(i + needle.len <= haystack.len);
        var match = true;
        for (0..needle.len) |j| {
            const h = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z')
                haystack[i + j] + 32
            else
                haystack[i + j];
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
    if (std.mem.find(u8, source, "disk")) |disk_start| {
        var i = disk_start + 4; // skip "disk"
        // Skip disk number digits
        while (i < source.len and source[i] >= '0' and source[i] <= '9') : (i += 1) {}
        // The "disk" match guarantees disk_start + 4 <= source.len, and the
        // loop only advances while i < source.len, so i never exceeds it.
        std.debug.assert(i <= source.len);
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

    var result: std.ArrayListUnmanaged(FsInfo) = .empty;
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
            // Stored indices always point at a live result element (entries are
            // appended, never removed), so the index is in bounds.
            std.debug.assert(existing_idx < result.items.len);
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

    // Past the <= 3 early return, so the comma path always has > 3 digits.
    std.debug.assert(digits.len > 3);
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

    // The fill consumes exactly out_len positions (digits.len digits plus
    // num_commas commas), so the right-to-left cursor lands precisely at 0.
    std.debug.assert(dst == 0);
    return buf[0..out_len];
}

/// Round `numerator` up to the next multiple of `denominator` without
/// overflowing. The naive `(n + d - 1) / d` wraps whenever n is within d of
/// u64max, which df reaches for any --block-size near the top of the range
/// (issue #138). Saturating that addition is wrong in the other direction:
/// it clamps silently and reports one block short, so the remainder is
/// inspected instead of widening or clamping.
fn ceilDiv(numerator: u64, denominator: u64) u64 {
    // Every caller's divisor is a display block size, and parseBlockSize
    // rejects zero at parse time, so a zero divisor cannot reach here.
    std.debug.assert(denominator > 0);
    const quotient = @divTrunc(numerator, denominator);
    const result = quotient + @intFromBool(@rem(numerator, denominator) != 0);
    // Rounding up can only yield zero for an empty numerator: any nonzero
    // byte count occupies at least one block, however large the block is.
    std.debug.assert((result == 0) == (numerator == 0));
    return result;
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

    const value = ceilDiv(bytes, display_block);

    if (opts.thousands_grouping) {
        return formatWithCommas(buf, value);
    }

    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

/// Calculate usage percentage as 0-100 with ceiling, matching GNU df's integer
/// path in coreutils src/df.c: `u100 / nonroot_total + (u100 % nonroot_total
/// != 0)`. `used * 100` overflows u64 above 184467440737095516 (~164 PiB), and
/// the old `+ total - 1` term wrapped earlier still. GNU guards that same bound
/// and degrades to double, so u128 is not merely a simpler way to reach GNU's
/// answer: above 164 PiB it is a deliberately better one. Sampling both across
/// the range, GNU's double path prints 101% for a filesystem that is exactly
/// full, and floors a fraction it cannot represent, in either direction by at
/// most one. We are exact everywhere, so our digit can differ from GNU's above
/// that bound (issue #144).
fn calcUsagePercent(used: u64, total: u64) u8 {
    if (total == 0) return 0;
    const scaled: u128 = @as(u128, used) * 100;
    const denominator: u128 = total;
    const pct = @divTrunc(scaled, denominator) +
        @intFromBool(@rem(scaled, denominator) != 0);
    // Callers pass used = f_blocks - f_bfree and total = used + avail, so used
    // cannot exceed total and the clamp is dead weight for them. It is kept
    // because the exported contract is a percentage, and a caller that does
    // pass used > total -- a summed total that wrapped, say -- must get 100
    // rather than a value @intCast cannot hold.
    const result: u8 = @intCast(@min(pct, 100));
    // Rounding up means any nonzero usage occupies at least one percent;
    // a @divTrunc regression would report 0% for a nearly-empty filesystem.
    std.debug.assert((result == 0) == (used == 0));
    return result;
}

fn formatPercent(buf: []u8, used: u64, total: u64) []const u8 {
    if (total == 0) return "-";
    const pct = calcUsagePercent(used, total);
    // calcUsagePercent clamps to 100, so the value formatted here is bounded.
    std.debug.assert(pct <= 100);
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "?";
}

/// Format a usage bar like [████████░░] 84%
fn formatUsageBar(buf: []u8, percent: u8) []const u8 {
    // Every caller passes a calcUsagePercent/@min-clamped value, keeping the
    // empty = bar_width - filled subtraction below from underflowing.
    std.debug.assert(percent <= 100);
    const bar_width: u8 = 10;
    const filled: u8 = @intCast(@divTrunc(@as(u16, percent) * bar_width + 99, 100));
    // percent <= 100 and bar_width == 10 bound filled at 10, so empty does not
    // underflow.
    std.debug.assert(filled <= bar_width);
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
    // On the truncating path the output is buf[0..max_width], so the caller's
    // buffer must be at least max_width bytes to hold the "..." + tail write.
    std.debug.assert(max_width <= buf.len);
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
    // @min keeps the working width within the buffer, bounding every write.
    std.debug.assert(effective_max <= buf.len);
    if (source.len <= effective_max) return source;
    if (effective_max <= 1) return source[source.len - effective_max ..];

    // Time Machine: extract device from "prefix@/dev/..."
    if (std.mem.find(u8, source, "@/dev/")) |at_pos| {
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
    // @min keeps the working width within the buffer, bounding every write.
    std.debug.assert(effective_max <= buf.len);
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
    // The struct defaults size the columns for the default header set, so
    // the labels that vary with block mode ("Available", "1048576-blocks")
    // have to widen them or the header row shifts out of alignment.
    var label_buf: [32]u8 = undefined;
    const labels = headerLabels(&label_buf, opts);
    widths.size = @max(widths.size, labels.size.len);
    widths.avail = @max(widths.avail, labels.avail.len);
    widths.use_pct = @max(widths.use_pct, labels.pct.len);

    for (filesystems) |fs| {
        widths.filesystem = @max(widths.filesystem, fs.source.len);
        widths.mount = @max(widths.mount, fs.mount_point.len);
        if (opts.print_type) {
            widths.fs_type = @max(widths.fs_type, fs.fstype.len);
        }
        // Size columns: format and measure
        var size_buf: [32]u8 = undefined;
        widths.size = @max(
            widths.size,
            formatSize(&size_buf, fs.total_blocks, fs.block_size, opts).len,
        );
        var used_buf: [32]u8 = undefined;
        widths.used = @max(
            widths.used,
            formatSize(&used_buf, fs.used_blocks, fs.block_size, opts).len,
        );
        var avail_buf: [32]u8 = undefined;
        widths.avail = @max(
            widths.avail,
            formatSize(&avail_buf, fs.avail_blocks, fs.block_size, opts).len,
        );
    }
    // Both default to the 10-char header width and only grow via @max, so the
    // minimum-width floor is preserved as a postcondition.
    std.debug.assert(widths.filesystem >= 10);
    std.debug.assert(widths.mount >= 10);
    return widths;
}

fn capWidthsToTerminal(allocator: Allocator, widths: *ColumnWidths, opts: DfOptions) void {
    // In portability mode, never truncate paths
    if (opts.portability) return;

    // Only cap when stdout is a real terminal
    if (std.c.isatty(std.Io.File.stdout().handle) == 0) return;

    const term_width: usize = @intCast(common.terminal.getWidth(allocator) catch 80);

    // Calculate total line width
    var total: usize = widths.filesystem + 2 + widths.size + 2 + // tiger:allow:usize-arch
        widths.used + 2 + widths.avail + 2 + widths.use_pct + 2 + widths.mount;
    if (opts.print_type) total += widths.fs_type + 2;
    if (opts.display.icons == .on) total += 2 + widths.usage_bar + 2; // icon spacer + bar

    if (total <= term_width) return;

    // Past the early return, so the subtraction below cannot underflow.
    std.debug.assert(total > term_width);
    const excess = total - term_width;
    // Shrink filesystem and mount proportionally
    const shrinkable = widths.filesystem + widths.mount;
    if (shrinkable <= 20) return; // Don't shrink below minimums

    // Past the guard, so the proportional division below has a nonzero divisor.
    std.debug.assert(shrinkable > 20);
    const fs_share = @divTrunc(excess * widths.filesystem, shrinkable);
    const mnt_share = excess -| fs_share;

    widths.filesystem = @max(10, widths.filesystem -| fs_share);
    widths.mount = @max(10, widths.mount -| mnt_share);
}

/// Write a string right-padded to the given width.
fn padRight(writer: *std.Io.Writer, str: []const u8, width: usize) !void {
    try writer.writeAll(str);
    const display_w = common.unicode.displayWidth(str);
    if (display_w < width) {
        for (0..width - display_w) |_| try writer.writeAll(" ");
    }
}

/// Write a string left-padded (right-aligned) to the given width.
fn padLeft(writer: *std.Io.Writer, str: []const u8, width: usize) !void {
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
    // The sole caller clamps block_pct to 100; pct names a usage percentage.
    std.debug.assert(pct <= 100);
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
fn writeColoredUsageBar(writer: *std.Io.Writer, s: anytype, percent: u8) !void {
    // Callers pass a calcUsagePercent/@min-clamped value, keeping the
    // empty = bar_width - filled subtraction below from underflowing.
    std.debug.assert(percent <= 100);
    const bar_width: u8 = 10;
    const filled: u8 = @intCast(@divTrunc(@as(u16, percent) * bar_width + 99, 100));
    // percent <= 100 and bar_width == 10 bound filled at 10, so empty does not
    // underflow.
    std.debug.assert(filled <= bar_width);
    const empty: u8 = bar_width - filled;

    try writer.writeAll("[");

    // Filled blocks with gradient coloring
    for (0..filled) |i| {
        // Calculate the percentage this block represents
        const block_pct: u8 = @intCast(
            @min(@divTrunc((@as(u16, @intCast(i)) + 1) * 100, bar_width), 100),
        );
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

/// The three header labels that vary with the resolved block-size mode.
const HeaderLabels = struct {
    size: []const u8,
    avail: []const u8,
    pct: []const u8,
};

/// Resolve the size, available and percent header labels. GNU keys all
/// three on the RESOLVED display mode, not on the flags that requested
/// it: "Avail"/"Size"/"Use%" belong to human mode, "Available" and the
/// POSIX "Capacity"/"NNNN-blocks" spellings to block mode. Because -P
/// only clears human mode (see the 'P' arm of the parser), a later -h
/// or -H puts us back in human mode and must take the default set.
fn headerLabels(buf: []u8, opts: DfOptions) HeaderLabels {
    std.debug.assert(buf.len >= 32);
    std.debug.assert(!opts.inodes);
    const human = opts.human_readable or opts.si;
    const size: []const u8 = blk: {
        if (human) break :blk "Size";
        // POSIX mode never abbreviates: it names the raw byte count.
        if (opts.portability) {
            const bs = opts.block_size orelse 1024;
            break :blk std.fmt.bufPrint(buf, "{d}-blocks", .{bs}) catch "blocks";
        }
        if (opts.block_size) |bs| break :blk blockSizeLabel(buf, bs);
        break :blk "1K-blocks";
    };
    // Every branch yields a non-empty label (literal or bufPrint result).
    std.debug.assert(size.len > 0);
    const posix_pct = opts.portability and !human;
    return .{
        .size = size,
        .avail = if (human) "Avail" else "Available",
        .pct = if (posix_pct) "Capacity" else "Use%",
    };
}

/// Pick the base GNU would abbreviate a block size in. It is decided by a
/// race between the two divisibility chains, not by asking whether the
/// count is a power of 1024: divide by 1000 and by 1024 in lockstep for as
/// long as both divide evenly, and whichever chain survives the extra
/// division wins. A tie goes to 1000, which is why 1024000 -- exactly
/// 1000K -- is labelled 1.1MB rather than 1000K.
fn chooseBase(n: u64) u64 {
    std.debug.assert(n > 0);
    var q1000 = n;
    var q1024 = n;
    var divisible_by_1000 = false;
    var divisible_by_1024 = false;
    var decided = false;
    // Continuing k rounds needs n divisible by both 1000^k and 1024^k, and
    // their lcm passes u64 at k = 4, so the race is always settled well
    // inside this bound. GNU's do/while is unbounded and would spin once
    // both chains reach zero; Tiger Style forbids that.
    for (0..8) |_| {
        divisible_by_1000 = q1000 % 1000 == 0;
        q1000 /= 1000;
        divisible_by_1024 = q1024 % 1024 == 0;
        q1024 /= 1024;
        if (!divisible_by_1000 or !divisible_by_1024) {
            decided = true;
            break;
        }
    }
    std.debug.assert(decided);
    const base: u64 = if (divisible_by_1024 and !divisible_by_1000) 1024 else 1000;
    std.debug.assert(base == 1000 or base == 1024);
    return base;
}

/// Render a non-POSIX block-size header label, e.g. "2kB-blocks". The
/// mantissa is always rounded UP, never to nearest, so 1023 bytes is
/// 1.1kB and not 1.0kB. Returns a slice of buf.
fn blockSizeLabel(buf: []u8, bs: u64) []const u8 {
    std.debug.assert(bs > 0);
    std.debug.assert(buf.len >= 32);
    const base = chooseBase(bs);
    var scale: u128 = 1;
    var exponent: u32 = 0;
    while (bs / scale >= base and exponent < 6) {
        scale *= base;
        exponent += 1;
    }
    var whole: u64 = 0;
    var frac: u64 = 0;
    if (bs / scale < 10) {
        // One decimal digit while the mantissa is small. u128 keeps the
        // ceiling arithmetic clear of the u64 edge: bs * 10 reaches 1.8e20.
        const tenths: u64 = @intCast((@as(u128, bs) * 10 + scale - 1) / scale);
        whole = tenths / 10;
        frac = tenths % 10;
    } else {
        whole = @intCast((@as(u128, bs) + scale - 1) / scale);
        // Rounding up can carry a mantissa into the next unit: 999999999
        // ceilings to 1000 mega-units, which GNU prints as 1GB.
        if (whole == base and exponent < 6) {
            exponent += 1;
            whole = 1;
        }
    }
    std.debug.assert(exponent <= 6);
    const units = "KMGTPE";
    const unit: []const u8 = if (exponent == 0)
        ""
    else if (base == 1000 and exponent == 1)
        "k"
    else
        units[exponent - 1 .. exponent];
    // Base-1000 units carry the SI byte marker; base-1024 ones do not.
    const marker: []const u8 = if (base == 1000) "B" else "";
    const out = if (frac == 0)
        std.fmt.bufPrint(buf, "{d}{s}{s}-blocks", .{ whole, unit, marker }) catch "blocks"
    else
        std.fmt.bufPrint(
            buf,
            "{d}.{d}{s}{s}-blocks",
            .{ whole, frac, unit, marker },
        ) catch "blocks";
    std.debug.assert(out.len > 0);
    std.debug.assert(out.len <= 12);
    return out;
}

fn printHeader(stdout: *std.Io.Writer, opts: DfOptions) !void {
    // Live only through runDf_renderInodes, which gates on opts.inodes.
    std.debug.assert(opts.inodes);
    std.debug.assert(!opts.help);
    return printHeader_inodes(stdout, opts);
}

fn printHeader_inodes(stdout: *std.Io.Writer, opts: DfOptions) !void {
    std.debug.assert(opts.inodes);
    std.debug.assert(!opts.help);
    std.debug.assert(!opts.version);
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
}

fn printFsRow(stdout: *std.Io.Writer, fs: FsInfo, opts: DfOptions) !void {
    // Live only through runDf_renderInodes, which gates on opts.inodes.
    std.debug.assert(opts.inodes);
    std.debug.assert(fs.source.len > 0);
    return printFsRow_inodes(stdout, &fs, opts);
}

fn printFsRow_inodes(stdout: *std.Io.Writer, fs: *const FsInfo, opts: DfOptions) !void {
    std.debug.assert(opts.inodes);
    std.debug.assert(fs.source.len > 0);
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
}

// Multiply-accumulate block totals into byte sums (shared by printTotal and
// printTotalDynamic). Push fors down: the parent keeps no loop of its own.
fn printTotal_sumBytes(
    filesystems: []const FsInfo,
    sum_total: *u64,
    sum_used: *u64,
    sum_avail: *u64,
) void {
    std.debug.assert(sum_total.* == 0);
    std.debug.assert(sum_used.* == 0);
    for (filesystems) |fs| {
        sum_total.* += fs.total_blocks * fs.block_size;
        sum_used.* += fs.used_blocks * fs.block_size;
        sum_avail.* += fs.avail_blocks * fs.block_size;
    }
}

// Format one byte total into a display field (human/si/divTrunc/commas),
// shared by printTotal and printTotalDynamic. Returns a slice into buf.
fn printTotal_formatField(buf: []u8, bytes: u64, display_block: u64, opts: DfOptions) []const u8 {
    std.debug.assert(buf.len >= 16);
    if (opts.human_readable) return formatHumanReadable(buf, bytes, false);
    if (opts.si) return formatHumanReadable(buf, bytes, true);
    const val = ceilDiv(bytes, display_block);
    if (opts.thousands_grouping) return formatWithCommas(buf, val);
    return std.fmt.bufPrint(buf, "{d}", .{val}) catch "?";
}

fn printTotal(
    stdout: *std.Io.Writer,
    filesystems: []const FsInfo,
    opts: DfOptions,
) !void {
    // Live only through runDf_renderInodes, which gates on opts.inodes.
    std.debug.assert(opts.inodes);
    std.debug.assert(filesystems.len > 0);
    return printTotal_inodes(stdout, filesystems, opts);
}

fn printTotal_inodes(stdout: *std.Io.Writer, filesystems: []const FsInfo, opts: DfOptions) !void {
    std.debug.assert(opts.inodes);
    std.debug.assert(!opts.help);
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
}

// ============================================================================
// Dynamic-width output formatting
// ============================================================================

fn printHeaderDynamic(
    stdout: *std.Io.Writer,
    opts: DfOptions,
    widths: ColumnWidths,
    s: anytype,
) !void {
    var size_label_buf: [32]u8 = undefined;
    const labels = headerLabels(&size_label_buf, opts);
    // headerLabels asserts its own non-empty postcondition on the size
    // label; the other two are always literals.
    std.debug.assert(labels.avail.len > 0);
    std.debug.assert(labels.pct.len > 0);

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

    try padLeft(stdout, labels.size, widths.size);
    try stdout.writeAll("  ");
    try padLeft(stdout, "Used", widths.used);
    try stdout.writeAll("  ");
    try padLeft(stdout, labels.avail, widths.avail);
    try stdout.writeAll("  ");
    try padLeft(stdout, labels.pct, widths.use_pct);

    if (opts.display.icons == .on) {
        try stdout.writeAll("  ");
        try padRight(stdout, "Usage", widths.usage_bar);
    }

    try stdout.writeAll("  ");
    try stdout.writeAll("Mounted on");

    if (s.color_mode != .none) try s.reset();
    try stdout.writeAll("\n");
}

fn printFsRowDynamic(
    stdout: *std.Io.Writer,
    fs: FsInfo,
    opts: DfOptions,
    widths: ColumnWidths,
    s: anytype,
) !void {
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
    // calcUsagePercent clamps to 100; both emit helpers assert the same bound.
    std.debug.assert(percent <= 100);

    // Smart-format source and mount
    var src_fmt_buf: [128]u8 = undefined;
    const source_str = smartFormatSource(&src_fmt_buf, fs.source, widths.filesystem);
    var mnt_fmt_buf: [128]u8 = undefined;
    const mount_str = smartFormatMount(&mnt_fmt_buf, fs.mount_point, widths.mount);

    if (s.color_mode == .none) {
        return printFsRowDynamic_emitPlain(
            stdout,
            &fs,
            opts,
            widths,
            fs_class,
            source_str,
            mount_str,
            total_str,
            used_str,
            avail_str,
            pct_str,
            percent,
        );
    }

    // Icon
    if (opts.display.icons == .on) {
        try printFsRowDynamic_emitIcon(stdout, s, fs_class);
    }
    try printFsRowDynamic_emitColored(
        stdout,
        s,
        &fs,
        opts,
        widths,
        fs_class,
        source_str,
        mount_str,
        total_str,
        used_str,
        avail_str,
        pct_str,
        percent,
    );
}

fn printFsRowDynamic_emitPlain(
    stdout: *std.Io.Writer,
    fs: *const FsInfo,
    opts: DfOptions,
    widths: ColumnWidths,
    fs_class: FsClass,
    source_str: []const u8,
    mount_str: []const u8,
    total_str: []const u8,
    used_str: []const u8,
    avail_str: []const u8,
    pct_str: []const u8,
    percent: u8,
) !void {
    std.debug.assert(percent <= 100);
    std.debug.assert(widths.filesystem > 0);
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
}

fn printFsRowDynamic_emitIcon(stdout: *std.Io.Writer, s: anytype, fs_class: FsClass) !void {
    std.debug.assert(s.color_mode != .none);
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

fn printFsRowDynamic_emitColored(
    stdout: *std.Io.Writer,
    s: anytype,
    fs: *const FsInfo,
    opts: DfOptions,
    widths: ColumnWidths,
    fs_class: FsClass,
    source_str: []const u8,
    mount_str: []const u8,
    total_str: []const u8,
    used_str: []const u8,
    avail_str: []const u8,
    pct_str: []const u8,
    percent: u8,
) !void {
    std.debug.assert(s.color_mode != .none);
    std.debug.assert(percent <= 100);
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

fn printTotalDynamic(
    stdout: *std.Io.Writer,
    filesystems: []const FsInfo,
    opts: DfOptions,
    widths: ColumnWidths,
    s: anytype,
) !void {
    // Sum bytes across all filesystems
    var sum_total_bytes: u64 = 0;
    var sum_used_bytes: u64 = 0;
    var sum_avail_bytes: u64 = 0;
    printTotal_sumBytes(filesystems, &sum_total_bytes, &sum_used_bytes, &sum_avail_bytes);

    const display_block: u64 = if (opts.block_size) |bs| bs else 1024;

    var total_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var avail_buf: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;

    const total_str = printTotal_formatField(&total_buf, sum_total_bytes, display_block, opts);
    const used_str = printTotal_formatField(&used_buf, sum_used_bytes, display_block, opts);
    const avail_str = printTotal_formatField(&avail_buf, sum_avail_bytes, display_block, opts);
    const sum_use_total = sum_used_bytes + sum_avail_bytes;
    // The percentage is shared with the per-filesystem rows rather than
    // recomputed here, so the overflow-safe arithmetic lives in one place.
    const percent = calcUsagePercent(sum_used_bytes, sum_use_total);
    const pct_str = formatPercent(&pct_buf, sum_used_bytes, sum_use_total);
    // Asserted here rather than left to the emit helpers: the colored total
    // path only re-checks this when it actually draws a usage bar, so in
    // colored non-bar mode nothing downstream would catch a bad value.
    std.debug.assert(percent <= 100);
    std.debug.assert((pct_str.len == 1) == (sum_use_total == 0));

    if (s.color_mode == .none) {
        return printTotalDynamic_emitPlain(
            stdout,
            opts,
            widths,
            total_str,
            used_str,
            avail_str,
            pct_str,
            percent,
        );
    }

    try printTotalDynamic_emitColored(
        stdout,
        s,
        opts,
        widths,
        total_str,
        used_str,
        avail_str,
        pct_str,
        percent,
    );
}

fn printTotalDynamic_emitPlain(
    stdout: *std.Io.Writer,
    opts: DfOptions,
    widths: ColumnWidths,
    total_str: []const u8,
    used_str: []const u8,
    avail_str: []const u8,
    pct_str: []const u8,
    percent: u8,
) !void {
    std.debug.assert(percent <= 100);
    std.debug.assert(widths.size > 0);
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
}

fn printTotalDynamic_emitColored(
    stdout: *std.Io.Writer,
    s: anytype,
    opts: DfOptions,
    widths: ColumnWidths,
    total_str: []const u8,
    used_str: []const u8,
    avail_str: []const u8,
    pct_str: []const u8,
    percent: u8,
) !void {
    std.debug.assert(s.color_mode != .none);
    std.debug.assert(pct_str.len > 0);
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

pub fn runDf(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) anyerror!u8 {
    const parsed = parseArgs(allocator, args);
    const opts = parsed.opts;

    if (parsed.err) |msg| {
        common.printErrorWithProgram(allocator, stderr, prog_name, "{s}", .{msg});
        return @intFromEnum(common.ExitCode.general_error);
    }
    defer allocator.free(opts.positionals);

    if (runDf_handleHelpVersion(allocator, opts, stdout)) |code| {
        return code;
    }

    var output_sel: OutputSelection = .{};
    if (runDf_resolveOutput(allocator, opts, stderr, &output_sel)) |code| {
        return code;
    }

    const color_mode_int = runDf_resolveColorMode(allocator, opts, stdout);
    // resolveColorMode asserts and only returns ColorMode tags (true max 3),
    // so the @enumFromInt below has a valid tag.
    std.debug.assert(color_mode_int <= 4);

    const S = common.style.Style(@TypeOf(stdout));
    const s = S{ .color_mode = @enumFromInt(color_mode_int), .writer = stdout };

    var exit_code: u8 = @intFromEnum(common.ExitCode.success);

    // Collect visible filesystems into a list for two-pass rendering.
    // owns_fs_strings tracks whether visible owns the FsInfo string
    // allocations (positional path) or they're owned by all_fs_storage.
    var visible: std.ArrayListUnmanaged(FsInfo) = .empty;
    defer visible.deinit(allocator);
    var owns_fs_strings = false;

    // Storage for mounted filesystems (no-positionals path).
    // Must outlive visible since visible borrows string pointers.
    var all_fs_storage: ?[]FsInfo = null;
    var display_fs_storage: ?[]FsInfo = null;
    defer runDf_cleanup(allocator, &visible, owns_fs_strings, all_fs_storage, display_fs_storage);

    const ctx = CollectContext{
        .visible = &visible,
        .owns_fs_strings = &owns_fs_strings,
        .all_fs_storage = &all_fs_storage,
        .display_fs_storage = &display_fs_storage,
        .exit_code = &exit_code,
    };
    if (!runDf_collect(allocator, io, opts, stderr, ctx)) {
        return @intFromEnum(common.ExitCode.general_error);
    }

    if (visible.items.len == 0 and exit_code == 0) {
        return exit_code;
    }

    if (runDf_render(allocator, stdout, opts, output_sel, s, visible.items)) |override_code| {
        return override_code;
    }

    return exit_code;
}

// Dispatch to the renderer for the resolved layout: fixed-width inode
// columns, the user-selected --output columns, or the default
// dynamic-width table. Returns an override exit code on a header write
// failure, otherwise null so the caller keeps its collected exit code.
fn runDf_render(
    allocator: Allocator,
    stdout: *std.Io.Writer,
    opts: DfOptions,
    sel: OutputSelection,
    s: anytype,
    visible_items: []const FsInfo,
) ?u8 {
    std.debug.assert(!opts.help);
    std.debug.assert(!opts.version);
    // Inodes mode uses the old fixed-width rendering.
    if (opts.inodes) return runDf_renderInodes(stdout, opts, visible_items);
    if (opts.output_fields != null) {
        return runDf_renderOutput(stdout, opts, sel, s, visible_items);
    }
    return runDf_renderDynamic(allocator, stdout, opts, s, visible_items);
}

// Validate --output and fill `sel` with the requested fields. Returns an
// exit code when the option conflicts with -i/-P/-T or names a bad field,
// otherwise null. Doing this in runDf rather than parseArgs keeps the
// formatted message off the parser's static-string error channel.
fn runDf_resolveOutput(
    allocator: Allocator,
    opts: DfOptions,
    stderr: *std.Io.Writer,
    sel: *OutputSelection,
) ?u8 {
    std.debug.assert(sel.len == 0);
    std.debug.assert(!opts.help);
    const list = opts.output_fields orelse return null;
    // GNU rejects --output alongside the flags that pick a fixed layout.
    const conflict: ?[]const u8 = blk: {
        if (opts.inodes) break :blk "-i";
        if (opts.portability) break :blk "-P";
        if (opts.print_type) break :blk "-T";
        break :blk null;
    };
    if (conflict) |flag| {
        common.printErrorWithProgram(
            allocator,
            stderr,
            prog_name,
            "options {s} and --output are mutually exclusive",
            .{flag},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }
    if (parseOutputFields(list, sel)) |bad| {
        const reason: []const u8 = switch (bad.kind) {
            .unknown => "unknown",
            .duplicate => "used more than once",
        };
        common.printErrorWithProgram(
            allocator,
            stderr,
            prog_name,
            "option --output: field '{s}' {s}",
            .{ bad.name, reason },
        );
        return @intFromEnum(common.ExitCode.general_error);
    }
    return null;
}

// Print help or version output when requested. Returns the success exit
// code in that case, otherwise null so the caller proceeds with rendering.
fn runDf_handleHelpVersion(allocator: Allocator, opts: DfOptions, stdout: *std.Io.Writer) ?u8 {
    // parseArgs breaks on the first of --help/--version, so at most one is
    // set; assert the exclusion without a compound boolean in the assert.
    const both_set = opts.help and opts.version;
    std.debug.assert(!both_set);
    std.debug.assert(@intFromEnum(common.ExitCode.success) == 0);
    if (opts.help) {
        printHelp(allocator, stdout) catch {};
        return @intFromEnum(common.ExitCode.success);
    }
    if (opts.version) {
        printVersion(stdout) catch {};
        return @intFromEnum(common.ExitCode.success);
    }
    return null;
}

// Fixed-width inodes-mode rendering: header, each row, and an optional total.
// Returns an override exit code when the header write fails, otherwise null.
fn runDf_renderInodes(
    stdout: *std.Io.Writer,
    opts: DfOptions,
    visible_items: []const FsInfo,
) ?u8 {
    std.debug.assert(opts.inodes);
    std.debug.assert(!opts.help);
    printHeader(stdout, opts) catch return @intFromEnum(common.ExitCode.general_error);
    for (visible_items) |fs| {
        printFsRow(stdout, fs, opts) catch {};
    }
    if (opts.total and visible_items.len > 0) {
        printTotal(stdout, visible_items, opts) catch {};
    }
    return null;
}

// Detect terminal color capability level. When display.color is on, the
// TTY/NO_COLOR/TERM checks have already passed, so we fall back to basic
// (16-color) if capability detection fails rather than disabling color.
fn runDf_resolveColorMode(allocator: Allocator, opts: DfOptions, stdout: *std.Io.Writer) u8 {
    const CM = common.style.Style(@TypeOf(stdout)).ColorMode;
    comptime std.debug.assert(@intFromEnum(CM.basic) <= 4);
    const result: u8 = if (opts.display.color == .off) 0 else blk: {
        const detected = CM.detect(allocator) catch break :blk @intFromEnum(CM.basic);
        break :blk if (detected == .none) @intFromEnum(CM.basic) else @intFromEnum(detected);
    };
    std.debug.assert(result <= 4);
    return result;
}

// Free the filesystem storage owned by runDf. display_fs_storage is freed
// only when it is a distinct allocation from all_fs_storage; visible's own
// FsInfo strings are freed only on the positional path (owns_fs_strings).
fn runDf_cleanup(
    allocator: Allocator,
    visible: *std.ArrayListUnmanaged(FsInfo),
    owns_fs_strings: bool,
    all_fs_storage: ?[]FsInfo,
    display_fs_storage: ?[]FsInfo,
) void {
    // The positional path owns visible's strings and never reads the mount
    // table, so owns_fs_strings and all_fs_storage are mutually exclusive.
    const owns_and_has_table = owns_fs_strings and all_fs_storage != null;
    std.debug.assert(!owns_and_has_table);
    // A display slice without a backing mount table would be unowned memory.
    const display_without_table = display_fs_storage != null and all_fs_storage == null;
    std.debug.assert(!display_without_table);
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

// Mutable state threaded through collection so the dispatcher signature
// stays small. The parent owns every referent and its defer cleanup.
const CollectContext = struct {
    visible: *std.ArrayListUnmanaged(FsInfo),
    owns_fs_strings: *bool,
    all_fs_storage: *?[]FsInfo,
    display_fs_storage: *?[]FsInfo,
    exit_code: *u8,
};

// Dispatch collection: positional paths versus the mounted-filesystem table.
// Returns false only when the mount table cannot be read.
fn runDf_collect(
    allocator: Allocator,
    io: std.Io,
    opts: DfOptions,
    stderr: *std.Io.Writer,
    ctx: CollectContext,
) bool {
    std.debug.assert(ctx.all_fs_storage.* == null);
    std.debug.assert(!ctx.owns_fs_strings.*);
    if (opts.positionals.len > 0) {
        ctx.owns_fs_strings.* = true;
        runDf_collectFromPositionals(allocator, io, opts, stderr, ctx.visible, ctx.exit_code);
        return true;
    }
    return runDf_collectFromMounts(
        allocator,
        io,
        opts,
        stderr,
        ctx.visible,
        ctx.all_fs_storage,
        ctx.display_fs_storage,
    );
}

// Resolve each positional path to a filesystem and append the visible ones.
// Sets exit_code to general_error for paths that cannot be accessed.
fn runDf_collectFromPositionals(
    allocator: Allocator,
    io: std.Io,
    opts: DfOptions,
    stderr: *std.Io.Writer,
    visible: *std.ArrayListUnmanaged(FsInfo),
    exit_code: *u8,
) void {
    std.debug.assert(opts.positionals.len > 0);
    std.debug.assert(exit_code.* == @intFromEnum(common.ExitCode.success));
    for (opts.positionals) |path| {
        var fs = getFilesystemForPath(io, allocator, path) catch {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "cannot access '{s}': No such file or directory",
                .{path},
            );
            exit_code.* = @intFromEnum(common.ExitCode.general_error);
            continue;
        };
        // --output=file reports the operand verbatim, not the resolved
        // mount point, so keep it with the entry it produced.
        fs.file = path;
        if (shouldIncludeFs(fs, opts)) {
            visible.append(allocator, fs) catch {};
        } else {
            freeFsInfo(allocator, fs);
        }
    }
}

// Enumerate mounted filesystems and append the visible ones. Returns false
// when the mount table cannot be read so the caller emits general_error.
fn runDf_collectFromMounts(
    allocator: Allocator,
    io: std.Io,
    opts: DfOptions,
    stderr: *std.Io.Writer,
    visible: *std.ArrayListUnmanaged(FsInfo),
    all_fs_storage: *?[]FsInfo,
    display_fs_storage: *?[]FsInfo,
) bool {
    std.debug.assert(opts.positionals.len == 0);
    std.debug.assert(all_fs_storage.* == null);
    // Fresh state on entry: the display slice is only assigned later in this
    // same function, mirroring the all_fs_storage precondition above.
    std.debug.assert(display_fs_storage.* == null);
    const all_fs = getMountedFilesystems(io, allocator) catch {
        common.printErrorWithProgram(
            allocator,
            stderr,
            prog_name,
            "cannot read table of mounted file systems",
            .{},
        );
        return false;
    };
    all_fs_storage.* = all_fs;

    // Smart volume grouping on macOS (non-plain mode)
    const display_fs = blk: {
        if (comptime is_darwin) {
            if (opts.display.color == .on) {
                break :blk groupDarwinVolumes(allocator, all_fs) catch all_fs;
            }
        }
        break :blk all_fs;
    };
    display_fs_storage.* = display_fs;

    for (display_fs) |fs| {
        if (shouldIncludeFs(fs, opts)) {
            visible.append(allocator, fs) catch {};
        }
    }
    return true;
}

// Two-pass dynamic-width rendering: compute column widths, cap to terminal,
// then print header, each row, and an optional total. Returns an override
// exit code when the header write fails, otherwise null.
fn runDf_renderDynamic(
    allocator: Allocator,
    stdout: *std.Io.Writer,
    opts: DfOptions,
    s: anytype,
    visible_items: []const FsInfo,
) ?u8 {
    std.debug.assert(!opts.inodes);
    std.debug.assert(!opts.help);
    var widths = computeColumnWidths(visible_items, opts);

    // Include "total" row in width computation if needed
    if (opts.total and visible_items.len > 0) {
        widths.filesystem = @max(widths.filesystem, 5); // "total"
    }

    // Cap to terminal width
    capWidthsToTerminal(allocator, &widths, opts);

    printHeaderDynamic(stdout, opts, widths, s) catch
        return @intFromEnum(common.ExitCode.general_error);
    for (visible_items) |fs| {
        printFsRowDynamic(stdout, fs, opts, widths, s) catch {};
    }
    if (opts.total and visible_items.len > 0) {
        printTotalDynamic(stdout, visible_items, opts, widths, s) catch {};
    }
    return null;
}

// ============================================================================
// --output rendering
// ============================================================================

/// Per-column display widths, indexed by position in the selection.
const OutputWidths = [output_field_max]u32;

/// Byte and inode sums backing the --total row under --output.
const OutputTotals = struct {
    size_bytes: u64 = 0,
    used_bytes: u64 = 0,
    avail_bytes: u64 = 0,
    itotal: u64 = 0,
    iused: u64 = 0,
    iavail: u64 = 0,
};

fn outputSumTotals(filesystems: []const FsInfo) OutputTotals {
    std.debug.assert(filesystems.len > 0);
    var totals = OutputTotals{};
    std.debug.assert(totals.itotal == 0);
    printTotal_sumBytes(
        filesystems,
        &totals.size_bytes,
        &totals.used_bytes,
        &totals.avail_bytes,
    );
    for (filesystems) |fs| {
        totals.itotal += fs.total_inodes;
        totals.iused += fs.used_inodes;
        totals.iavail += fs.avail_inodes;
    }
    return totals;
}

/// The header label for one field. The size, available and percent labels
/// follow the resolved block-size mode, exactly as the default layout.
fn outputHeaderText(field: OutputField, labels: HeaderLabels) []const u8 {
    std.debug.assert(labels.size.len > 0);
    std.debug.assert(labels.avail.len > 0);
    return switch (field) {
        .source => "Filesystem",
        .fstype => "Type",
        .itotal => "Inodes",
        .iused => "IUsed",
        .iavail => "IFree",
        .ipcent => "IUse%",
        .size => labels.size,
        .used => "Used",
        .avail => labels.avail,
        .pcent => labels.pct,
        .file => "File",
        .target => "Mounted on",
    };
}

/// One cell of a filesystem row. Numeric cells are formatted into buf;
/// name and path cells borrow from fs.
fn outputCellText(
    buf: []u8,
    field: OutputField,
    fs: *const FsInfo,
    opts: DfOptions,
) []const u8 {
    std.debug.assert(buf.len >= 32);
    std.debug.assert(!opts.inodes);
    return switch (field) {
        .source => fs.source,
        .fstype => fs.fstype,
        .itotal => std.fmt.bufPrint(buf, "{d}", .{fs.total_inodes}) catch "?",
        .iused => std.fmt.bufPrint(buf, "{d}", .{fs.used_inodes}) catch "?",
        .iavail => std.fmt.bufPrint(buf, "{d}", .{fs.avail_inodes}) catch "?",
        .ipcent => formatPercent(buf, fs.used_inodes, fs.total_inodes),
        .size => formatSize(buf, fs.total_blocks, fs.block_size, opts),
        .used => formatSize(buf, fs.used_blocks, fs.block_size, opts),
        .avail => formatSize(buf, fs.avail_blocks, fs.block_size, opts),
        .pcent => formatPercent(buf, fs.used_blocks, fs.used_blocks + fs.avail_blocks),
        // No operand means the entry came from the mount table.
        .file => fs.file orelse "-",
        .target => fs.mount_point,
    };
}

/// One cell of the --total row. Fields with no aggregate meaning print a
/// dash, matching the default layout's total row.
fn outputTotalCellText(
    buf: []u8,
    field: OutputField,
    totals: OutputTotals,
    opts: DfOptions,
) []const u8 {
    std.debug.assert(buf.len >= 32);
    std.debug.assert(!opts.inodes);
    const display_block: u64 = opts.block_size orelse 1024;
    return switch (field) {
        .source => "total",
        .fstype, .file, .target => "-",
        .itotal => std.fmt.bufPrint(buf, "{d}", .{totals.itotal}) catch "?",
        .iused => std.fmt.bufPrint(buf, "{d}", .{totals.iused}) catch "?",
        .iavail => std.fmt.bufPrint(buf, "{d}", .{totals.iavail}) catch "?",
        .ipcent => formatPercent(buf, totals.iused, totals.itotal),
        .size => printTotal_formatField(buf, totals.size_bytes, display_block, opts),
        .used => printTotal_formatField(buf, totals.used_bytes, display_block, opts),
        .avail => printTotal_formatField(buf, totals.avail_bytes, display_block, opts),
        .pcent => formatPercent(
            buf,
            totals.used_bytes,
            totals.used_bytes + totals.avail_bytes,
        ),
    };
}

/// Widen every selected column to fit its header, every row cell, and the
/// total row when one is printed.
fn outputWidths(
    opts: DfOptions,
    sel: OutputSelection,
    labels: HeaderLabels,
    filesystems: []const FsInfo,
    totals: ?OutputTotals,
) OutputWidths {
    std.debug.assert(sel.len > 0);
    std.debug.assert(sel.len <= output_field_max);
    var widths = [_]u32{0} ** output_field_max;
    var buf: [64]u8 = undefined;
    for (sel.slice(), 0..) |field, idx| {
        widths[idx] = @intCast(outputHeaderText(field, labels).len);
    }
    for (filesystems) |*fs| {
        for (sel.slice(), 0..) |field, idx| {
            const cell: u32 = @intCast(outputCellText(&buf, field, fs, opts).len);
            widths[idx] = @max(widths[idx], cell);
        }
    }
    if (totals) |sums| {
        for (sel.slice(), 0..) |field, idx| {
            const cell: u32 = @intCast(outputTotalCellText(&buf, field, sums, opts).len);
            widths[idx] = @max(widths[idx], cell);
        }
    }
    return widths;
}

/// Write one cell. The trailing column of a left-aligned field is written
/// unpadded so no line carries trailing whitespace.
fn outputEmitCell(
    stdout: *std.Io.Writer,
    text: []const u8,
    width: u32,
    field: OutputField,
    last: bool,
) !void {
    std.debug.assert(width > 0);
    std.debug.assert(width <= 4096);
    if (!outputFieldIsLeftAligned(field)) {
        return padLeft(stdout, text, width);
    }
    if (last) return stdout.writeAll(text);
    return padRight(stdout, text, width);
}

/// Prefix the source column with the filesystem icon when icons are on.
/// No other column gains a decoration: the user enumerated the fields.
fn outputEmitIcon(
    stdout: *std.Io.Writer,
    s: anytype,
    opts: DfOptions,
    fs_class: FsClass,
) !void {
    std.debug.assert(!opts.inodes);
    std.debug.assert(!opts.portability);
    if (opts.display.icons != .on) return;
    if (s.color_mode != .none) return printFsRowDynamic_emitIcon(stdout, s, fs_class);
    try stdout.writeAll(getFsIcon(fs_class));
    try stdout.writeAll(" ");
}

/// Set the color for one cell. Returns false for fields that carry no
/// color of their own, so the caller can skip the matching reset rather
/// than emit a bare one.
fn outputApplyColor(
    s: anytype,
    field: OutputField,
    fs: *const FsInfo,
    fs_class: FsClass,
) !bool {
    std.debug.assert(s.color_mode != .none);
    std.debug.assert(fs.source.len > 0);
    switch (field) {
        .source => try applySourceColor(s, fs_class),
        .fstype => try applyTypeColor(s),
        .target => try applyMountColor(s, fs_class),
        .pcent => try applyUsageColor(
            s,
            calcUsagePercent(fs.used_blocks, fs.used_blocks + fs.avail_blocks),
        ),
        .ipcent => try applyUsageColor(s, calcUsagePercent(fs.used_inodes, fs.total_inodes)),
        else => return false,
    }
    return true;
}

fn outputEmitHeader(
    stdout: *std.Io.Writer,
    s: anytype,
    opts: DfOptions,
    sel: OutputSelection,
    widths: OutputWidths,
    labels: HeaderLabels,
) !void {
    std.debug.assert(sel.len > 0);
    std.debug.assert(labels.size.len > 0);
    const fields = sel.slice();
    if (s.color_mode != .none) try s.setBold();
    for (fields, 0..) |field, idx| {
        if (idx > 0) try stdout.writeAll("  ");
        // Reserve the icon column so the header lines up with the rows.
        if (field == .source and opts.display.icons == .on) try stdout.writeAll("  ");
        const text = outputHeaderText(field, labels);
        try outputEmitCell(stdout, text, widths[idx], field, idx + 1 == fields.len);
    }
    if (s.color_mode != .none) try s.reset();
    try stdout.writeAll("\n");
}

fn outputEmitRow(
    stdout: *std.Io.Writer,
    s: anytype,
    opts: DfOptions,
    sel: OutputSelection,
    widths: OutputWidths,
    fs: *const FsInfo,
) !void {
    std.debug.assert(sel.len > 0);
    std.debug.assert(fs.source.len > 0);
    const fields = sel.slice();
    const fs_class = classifyFs(fs.source, fs.fstype, fs.mount_point);
    const colored = s.color_mode != .none;
    for (fields, 0..) |field, idx| {
        if (idx > 0) try stdout.writeAll("  ");
        if (field == .source) try outputEmitIcon(stdout, s, opts, fs_class);
        var buf: [64]u8 = undefined;
        const text = outputCellText(&buf, field, fs, opts);
        const painted = colored and try outputApplyColor(s, field, fs, fs_class);
        try outputEmitCell(stdout, text, widths[idx], field, idx + 1 == fields.len);
        if (painted) try s.reset();
    }
    try stdout.writeAll("\n");
}

fn outputEmitTotal(
    stdout: *std.Io.Writer,
    s: anytype,
    opts: DfOptions,
    sel: OutputSelection,
    widths: OutputWidths,
    totals: OutputTotals,
) !void {
    std.debug.assert(sel.len > 0);
    std.debug.assert(!opts.inodes);
    const fields = sel.slice();
    const color_source = s.color_mode != .none;
    for (fields, 0..) |field, idx| {
        if (idx > 0) try stdout.writeAll("  ");
        // The total row belongs to no filesystem, so it takes the icon
        // spacer rather than an icon.
        if (field == .source and opts.display.icons == .on) try stdout.writeAll("  ");
        var buf: [64]u8 = undefined;
        const text = outputTotalCellText(&buf, field, totals, opts);
        const paint = color_source and field == .source;
        if (paint) try applySourceColor(s, .local);
        try outputEmitCell(stdout, text, widths[idx], field, idx + 1 == fields.len);
        if (paint) try s.reset();
    }
    try stdout.writeAll("\n");
}

// Render the user-selected --output columns in the user's order.
// --output controls WHICH columns appear; the style system still controls
// HOW they render, so color and icons apply to the selected columns, but
// no Usage column or bar is injected into a list the user enumerated.
// Returns an override exit code when the header write fails.
fn runDf_renderOutput(
    stdout: *std.Io.Writer,
    opts: DfOptions,
    sel: OutputSelection,
    s: anytype,
    visible_items: []const FsInfo,
) ?u8 {
    std.debug.assert(!opts.inodes);
    std.debug.assert(sel.len > 0);
    var label_buf: [32]u8 = undefined;
    const labels = headerLabels(&label_buf, opts);
    const want_total = opts.total and visible_items.len > 0;
    const totals: ?OutputTotals = if (want_total) outputSumTotals(visible_items) else null;
    const widths = outputWidths(opts, sel, labels, visible_items, totals);

    outputEmitHeader(stdout, s, opts, sel, widths, labels) catch
        return @intFromEnum(common.ExitCode.general_error);
    for (visible_items) |*fs| {
        outputEmitRow(stdout, s, opts, sel, widths, fs) catch {};
    }
    if (totals) |sums| {
        outputEmitTotal(stdout, s, opts, sel, widths, sums) catch {};
    }
    return null;
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runDf);
}

// ============================================================================
// Help and version
// ============================================================================

/// -I is a different option on each platform (see the parser): a boolean
/// "suppress inode counts" on macOS, an exclude-type filter taking an
/// argument elsewhere. The help must describe the one that is compiled in.
const help_exclude_line = if (is_darwin)
    "  -I                    suppress inode counts (cancels an earlier -i)\n"
else
    "  -I TYPE               exclude file systems of type TYPE\n";

fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
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
        \\
    ++ help_exclude_line ++
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

fn printVersion(writer: *std.Io.Writer) !void {
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: df") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runDf - version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "df") != null);
}

test "runDf - unknown flag returns exit code 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "df:") != null);
}

test "runDf - nonexistent path returns error" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent/path/that/does/not/exist"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "df:") != null);
}

test "runDf - no args shows filesystems" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Should have a header line
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Filesystem") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Mounted on") != null);
}

test "runDf - specific path" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Filesystem") != null);
    try testing.expect(stdout_aw.writer.buffered().len > 50); // Has meaningful output
}

test "runDf - human readable flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-h", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Size") != null);
}

test "runDf - print type flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-T", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Type") != null);
}

test "runDf - inodes flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-i", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Inodes") != null);
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

// Issue #138: `bytes + display_block - 1` overflows u64 when
// display_block is near u64::MAX (e.g. --block-size=18446744073709551615,
// which is u64::MAX itself). Any nonzero byte count then traps instead of
// ceiling to 1 block. GNU df never panics here -- pinned against GNU
// coreutils 9.4, LC_ALL=C: `df --block-size=18446744073709551615 /`
// prints size/used/avail columns of exactly 1.
test "formatSize - huge block-size ceils to 1 without overflow (issue #138)" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = std.math.maxInt(u64);
    // 1000 blocks * 4096 fs_block_size = 4096000 bytes, far smaller than
    // display_block: must ceil to 1, not trap on the addition overflow.
    const result = formatSize(&buf, 1000, 4096, opts);
    try testing.expectEqualStrings("1", result);
}

// Same overflow, but with bytes itself pushed up near u64::MAX (not just
// display_block), matching the briefing's "both near u64max" case: blocks=1,
// fs_block_size=u64max gives bytes == display_block exactly, dividing
// evenly to a ceiling of 1.
test "formatSize - bytes and display_block both near u64max (issue #138)" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = std.math.maxInt(u64);
    const result = formatSize(&buf, 1, std.math.maxInt(u64), opts);
    try testing.expectEqualStrings("1", result);
}

// Pinned second GNU repro: --block-size=9223372036854775807 (2^63-1).
// This is a boundary regression guard, not a red-today test: overflowing
// `bytes + display_block - 1` at this display_block would require
// bytes > 2^63, far above any real filesystem's byte count (~4096000
// here), so this case already passes on the unfixed code. It stays in
// the suite to pin GNU's ceiling-to-1 behavior at this exact boundary
// value and must remain green after the fix.
test "formatSize - block-size 2^63-1 does not overflow (issue #138)" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = std.math.maxInt(u64) / 2; // 9223372036854775807
    const result = formatSize(&buf, 1000, 4096, opts);
    try testing.expectEqualStrings("1", result);
}

// Discriminates a saturating-add "fix" (`bytes +| display_block - 1`)
// from a correct one. Every other case here has display_block >= bytes,
// where saturation happens to land on the right quotient by accident.
// Here bytes = u64::MAX and display_block = 1024 (an ordinary size): the
// correct ceiling is u64::MAX / 1024 rounded up = 2^54 exactly
// (18014398509481983 remainder 1023), i.e. "18014398509481984". A
// saturating implementation clamps the addition to u64::MAX before
// dividing and returns "18014398509481983" instead -- one short.
test "formatSize - u64max bytes with ordinary block size rejects saturating fix (issue #138)" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = 1024;
    const result = formatSize(&buf, 1, std.math.maxInt(u64), opts);
    try testing.expectEqualStrings("18014398509481984", result);
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

// Issue #144: `used * 100` overflows u64 above 184467440737095516 (~164 PiB),
// and the `+ total - 1` term wraps earlier still, so a Debug or ReleaseSafe
// build aborts rather than printing a percentage. Every vector below is either
// exact or a half-integer fraction, so its ceiling follows from the arithmetic
// alone and does not depend on GNU's unpinnable double-precision fallback.
test "calcUsagePercent - above the u64 multiply threshold (issue #144)" {
    // 2e17 of 4e17 bytes: the product alone is 2e19, well past u64max.
    try testing.expectEqual(@as(u8, 50), calcUsagePercent(
        200_000_000_000_000_000,
        400_000_000_000_000_000,
    ));
    // A completely full filesystem at the widest operands u64 can express.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(
        std.math.maxInt(u64),
        std.math.maxInt(u64),
    ));
    // Just under half of u64max, i.e. 49.99...%, which ceils to 50.
    try testing.expectEqual(@as(u8, 50), calcUsagePercent(
        9_223_372_036_854_775_807,
        std.math.maxInt(u64),
    ));
}

test "calcUsagePercent - ceiling survives the widened multiply (issue #144)" {
    // 202e15 of 400e15 is exactly 50.5%. A floor implementation answers 50, as
    // does `used / (total / 100)`, so this one vector rejects both rewrites.
    try testing.expectEqual(@as(u8, 51), calcUsagePercent(
        202_000_000_000_000_000,
        400_000_000_000_000_000,
    ));
    // One byte of 2e17 is still in use, so the ceiling must report 1%, not 0%.
    try testing.expectEqual(@as(u8, 1), calcUsagePercent(1, 200_000_000_000_000_000));
}

test "calcUsagePercent - the exact u64 overflow boundary (issue #144)" {
    // At used == total this is the largest value the naive expression survives.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(
        182_641_030_432_767_837,
        182_641_030_432_767_837,
    ));
    // One more wraps `used * 100 + total - 1`: the first value that panics.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(
        182_641_030_432_767_838,
        182_641_030_432_767_838,
    ));
    // u64max / 100, the nominal multiply bound GNU guards. The product fits
    // here, yet `+ total - 1` overflows anyway, so the bound is not the whole
    // story and a fix that only widens the product is still wrong.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(
        184_467_440_737_095_516,
        184_467_440_737_095_516,
    ));
}

test "calcUsagePercent - ordinary operands keep ceiling semantics (issue #144)" {
    // These pass today and must survive the widening. They are exactly what a
    // `used / (total / 100)` restructure breaks: it answers 0, 99 and 33.
    try testing.expectEqual(@as(u8, 1), calcUsagePercent(1, 1000));
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(199, 200));
    try testing.expectEqual(@as(u8, 34), calcUsagePercent(1_000_000_000, 3_000_000_000));
}

// `df` proper cannot reach used > total: callers pass used = f_blocks -|
// f_bfree and total = used + avail, so the clamp is unreachable from the
// utility. It is still part of the helper's exported contract -- the return
// type promises a percentage -- so pin it directly. Vectors stay well clear of
// the separate aggregate-overflow case tracked as issue #158.
test "calcUsagePercent - clamps to 100 when used exceeds total" {
    // Twice the total is 200%, which fits u8, so an unclamped implementation
    // silently returns 200 instead of trapping.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(200, 100));
    // One block past full: the smallest overshoot a wrapped total can produce.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(101, 100));
    // Exactly u8max unclamped -- the last overshoot that still fits the return
    // type, and so the last one an unclamped @intCast would let through.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(255, 100));
}

test "calcUsagePercent - clamps values that do not fit the u8 return" {
    // Ten times the total is 1000%, which no u8 can hold; without the clamp the
    // narrowing @intCast is illegal behavior rather than a wrong number.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(1_000, 100));
    // The widest overshoot u64 operands can express: ~1.8e16 percent.
    try testing.expectEqual(@as(u8, 100), calcUsagePercent(std.math.maxInt(u64), 1_000));
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
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .truecolor, .writer = &aw.writer };
    try applyUsageColor(s, 50);
    try testing.expectEqualSlices(u8, "\x1b[38;2;115;195;120m", aw.writer.buffered());
}

test "applyUsageColor - truecolor yellow" {
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .truecolor, .writer = &aw.writer };
    try applyUsageColor(s, 75);
    try testing.expectEqualSlices(u8, "\x1b[38;2;210;185;90m", aw.writer.buffered());
}

test "applyUsageColor - truecolor red" {
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .truecolor, .writer = &aw.writer };
    try applyUsageColor(s, 95);
    try testing.expectEqualSlices(u8, "\x1b[38;2;210;95;90m", aw.writer.buffered());
}

test "applyUsageColor - basic green" {
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .basic, .writer = &aw.writer };
    try applyUsageColor(s, 30);
    try testing.expectEqualSlices(u8, "\x1b[32m", aw.writer.buffered());
}

test "applyUsageColor - basic yellow" {
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .basic, .writer = &aw.writer };
    try applyUsageColor(s, 80);
    try testing.expectEqualSlices(u8, "\x1b[33m", aw.writer.buffered());
}

test "applyUsageColor - basic red" {
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .basic, .writer = &aw.writer };
    try applyUsageColor(s, 90);
    try testing.expectEqualSlices(u8, "\x1b[31m", aw.writer.buffered());
}

test "applyUsageColor - none writes nothing" {
    const TestStyle = common.style.Style(*std.Io.Writer);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const s = TestStyle{ .color_mode = .none, .writer = &aw.writer };
    try applyUsageColor(s, 50);
    try testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
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

fn makeFsInfo(
    source: []const u8,
    mount_point: []const u8,
    total_blocks: u64,
    block_size: u64,
) FsInfo {
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

// The block-mode renderers reached by production are the *Dynamic family:
// runDf only calls printHeader/printFsRow/printTotal from
// runDf_renderInodes, which asserts opts.inodes. These tests therefore
// exercise the dynamic printers for block mode and the fixed-width
// printers only in inode mode.

/// Build a Style bound to a test writer, mirroring runDf's construction.
fn testStyle(
    writer: *std.Io.Writer,
    mode: common.style.Style(*std.Io.Writer).ColorMode,
) common.style.Style(*std.Io.Writer) {
    return .{ .color_mode = mode, .writer = writer };
}

test "printFsRowDynamic - plain mode has no ANSI" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const fs = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    var opts = DfOptions{};
    opts.display.color = .off;
    opts.display.icons = .off;
    const items = [_]FsInfo{fs};
    const widths = computeColumnWidths(&items, opts);
    try printFsRowDynamic(&aw.writer, fs, opts, widths, testStyle(&aw.writer, .none));
    // No ANSI escape sequences in plain mode
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\x1b[") == null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "/dev/disk1s1") != null);
}

test "printFsRowDynamic - color mode applies ANSI" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const fs = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .off;
    const items = [_]FsInfo{fs};
    const widths = computeColumnWidths(&items, opts);
    try printFsRowDynamic(&aw.writer, fs, opts, widths, testStyle(&aw.writer, .basic));
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\x1b[") != null);
    // No usage bar without icons
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\xe2\x96\x88") == null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\xe2\x96\x91") == null);
}

test "printFsRowDynamic - full mode includes bar" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const fs = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .on;
    const items = [_]FsInfo{fs};
    const widths = computeColumnWidths(&items, opts);
    try printFsRowDynamic(&aw.writer, fs, opts, widths, testStyle(&aw.writer, .none));
    // Icons on with color_mode none still shows the bar
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\xe2\x96\x88") != null or
        std.mem.find(u8, aw.writer.buffered(), "\xe2\x96\x91") != null);
}

// Issue #144: the --total row computes its own use percentage inline instead of
// calling calcUsagePercent, so it overflows independently. A fix applied only
// to the shared helper leaves these two tests red.
test "printTotalDynamic - percent above the overflow threshold (issue #144)" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // 97656250000000 blocks x 4096 = 4e17 bytes, and makeFsInfo halves used and
    // avail, so the summed row is 2e17 used of a 4e17 use-total. That clears
    // the multiply bound while leaving the byte sums far below u64max, so a
    // panic here can only come from the percentage, not from the summation.
    const fs = makeFsInfo("/dev/disk1s1", "/", 97_656_250_000_000, 4096);
    var opts = DfOptions{};
    opts.total = true;
    opts.display.color = .off;
    opts.display.icons = .off;
    const items = [_]FsInfo{fs};
    const widths = computeColumnWidths(&items, opts);
    try printTotalDynamic(&aw.writer, &items, opts, widths, testStyle(&aw.writer, .none));
    const row = aw.writer.buffered();
    try testing.expect(std.mem.find(u8, row, "total") != null);
    // The percent column holds the only "%" in the row, so the token is exact.
    try testing.expect(std.mem.find(u8, row, "50%") != null);
}

test "printTotalDynamic - percent ceils above the threshold (issue #144)" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var fs = makeFsInfo("/dev/disk1s1", "/", 97_656_250_000_000, 4096);
    // 202e15 used of a 400e15 use-total is exactly 50.5%, so the ceiling is 51
    // and both a floor rewrite and an unfixed inline expression give 50.
    fs.used_blocks = 49_316_406_250_000;
    fs.avail_blocks = 48_339_843_750_000;
    var opts = DfOptions{};
    opts.total = true;
    opts.display.color = .off;
    opts.display.icons = .off;
    const items = [_]FsInfo{fs};
    const widths = computeColumnWidths(&items, opts);
    try printTotalDynamic(&aw.writer, &items, opts, widths, testStyle(&aw.writer, .none));
    const row = aw.writer.buffered();
    try testing.expect(std.mem.find(u8, row, "51%") != null);
    try testing.expect(std.mem.find(u8, row, "50%") == null);
}

// Issue #158: `df --total` accumulates byte counts in u64. Two filesystems of
// 1e19 bytes sum to 2e19, past u64max (16 EiB). Distinct from #144, whose
// vectors stay at 4e17 bytes so a failure there is the percentage multiply,
// not the sums. makeFsInfo halves used/avail, so used+avail overflows here
// too; the next test isolates that add so a Size-only fix still goes red.
test "printTotalDynamic - size sum past 16 EiB (issue #158)" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // Products fit in u64; only the SUM wraps. `-B 1` with human off keeps
    // the printed Size equal to the byte total, so the assertion is 2e19
    // rather than a wrapped 1K-block count.
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 10_000_000_000_000_000_000, 1);
    const fs2 = makeFsInfo("/dev/disk2s1", "/home", 10_000_000_000_000_000_000, 1);
    var opts = DfOptions{};
    opts.total = true;
    opts.human_readable = false;
    opts.block_size = 1;
    opts.display.color = .off;
    opts.display.icons = .off;
    const items = [_]FsInfo{ fs1, fs2 };
    const widths = computeColumnWidths(&items, opts);
    try printTotalDynamic(&aw.writer, &items, opts, widths, testStyle(&aw.writer, .none));
    const row = aw.writer.buffered();
    // The true sum is 2e19; wrapping u64 yields 1553255926290458384.
    try testing.expect(std.mem.find(u8, row, "20000000000000000000") != null);
    try testing.expect(std.mem.find(u8, row, "1553255926290458384") == null);
}

test "printTotalDynamic - used plus avail past 16 EiB (issue #158)" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // Size stays at 200 bytes so printTotal_sumBytes does not wrap. Each
    // used/avail is 9e18, so the column sums fit and only
    // `sum_used + sum_avail` (3.6e19) overflows. Equal used and avail make
    // the true percentage 50%; wrapping the add prints "-" and feeding Size
    // to the percent (a Size-only fix) clamps to 100%.
    var fs1 = makeFsInfo("/dev/disk1s1", "/", 100, 1);
    fs1.used_blocks = 9_000_000_000_000_000_000;
    fs1.avail_blocks = 9_000_000_000_000_000_000;
    var fs2 = makeFsInfo("/dev/disk2s1", "/home", 100, 1);
    fs2.used_blocks = 9_000_000_000_000_000_000;
    fs2.avail_blocks = 9_000_000_000_000_000_000;
    var opts = DfOptions{};
    opts.total = true;
    opts.human_readable = false;
    opts.block_size = 1;
    opts.display.color = .off;
    opts.display.icons = .off;
    const items = [_]FsInfo{ fs1, fs2 };
    const widths = computeColumnWidths(&items, opts);
    try printTotalDynamic(&aw.writer, &items, opts, widths, testStyle(&aw.writer, .none));
    const row = aw.writer.buffered();
    try testExpectTokens(&.{
        "total",
        "200",
        "18000000000000000000",
        "18000000000000000000",
        "50%",
        "-",
    }, testFirstLine(row));
    try testing.expect(std.mem.find(u8, row, "100%") == null);
}

test "printHeaderDynamic - full mode shows Usage column" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .on;
    try printHeaderDynamic(&aw.writer, opts, .{}, testStyle(&aw.writer, .none));
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Usage") != null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Size") != null);
}

test "printHeaderDynamic - plain mode no Usage column" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var opts = DfOptions{};
    opts.display.icons = .off;
    try printHeaderDynamic(&aw.writer, opts, .{}, testStyle(&aw.writer, .none));
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Usage") == null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Mounted on") != null);
}

test "printHeader - inode mode column labels" {
    // printHeader is live only through runDf_renderInodes, so cover the
    // inode branch here rather than the block branch.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var opts = DfOptions{};
    opts.inodes = true;
    try printHeader(&aw.writer, opts);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "Inodes") != null);
    try testing.expect(std.mem.find(u8, out, "IUsed") != null);
    try testing.expect(std.mem.find(u8, out, "IFree") != null);
    try testing.expect(std.mem.find(u8, out, "IUse%") != null);
    // Block-mode labels must not appear in inode mode.
    try testing.expect(std.mem.find(u8, out, "1K-blocks") == null);
    try testing.expect(std.mem.find(u8, out, "Avail ") == null);
}

test "printTotalDynamic - plain mode has no ANSI" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    const fs2 = makeFsInfo("/dev/disk2s1", "/home", 2000, 4096);
    const items = [_]FsInfo{ fs1, fs2 };
    var opts = DfOptions{};
    opts.display.color = .off;
    opts.display.icons = .off;
    const widths = computeColumnWidths(&items, opts);
    try printTotalDynamic(&aw.writer, &items, opts, widths, testStyle(&aw.writer, .none));
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\x1b[") == null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "total") != null);
}

test "printTotalDynamic - full mode includes bar" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 1000, 4096);
    const items = [_]FsInfo{fs1};
    var opts = DfOptions{};
    opts.display.color = .on;
    opts.display.icons = .on;
    const widths = computeColumnWidths(&items, opts);
    try printTotalDynamic(&aw.writer, &items, opts, widths, testStyle(&aw.writer, .none));
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "\xe2\x96\x88") != null or
        std.mem.find(u8, aw.writer.buffered(), "\xe2\x96\x91") != null);
}

test "runDf - help mentions VIBEUTILS_STYLE" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "VIBEUTILS_STYLE") != null);
}

test "runDf - non-tty output should not contain ANSI escapes" {
    const io = testing.io;
    // Set TERM so ColorMode.detect returns a non-none color mode, and
    // stage NO_COLOR and VIBEUTILS_STYLE as unset so they don't suppress
    // colors. This goes through the test-only overlay in common.env
    // rather than libc setenv/unsetenv: unsetenv compacts `environ` in
    // place and corrupts the view Zig 0.16 captures at startup, which
    // deadlocks the test runner's failure path (issue #95).
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "VIBEUTILS_STYLE", .value = null },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run df on "/" which always exists. The output goes to an Allocating
    // writer, not a terminal. No ANSI escapes should appear because
    // the output destination is not a tty.
    const args = [_][]const u8{"/"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);

    // The isTty() gate on color_mode_int ensures ANSI codes do not
    // leak into non-tty output even when TERM indicates color support.
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "\x1b[") == null);
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
    try testing.expectEqualStrings(
        "/System/Volumes",
        smartFormatMount(&buf, "/System/Volumes", 20),
    );
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
    try testing.expectEqual(
        FsClass.backup,
        classifyFs("/dev/disk9s1", "apfs", "/Volumes/Backups of tcole-mbpro"),
    );
    try testing.expectEqual(
        FsClass.backup,
        classifyFs("//user@nas/share", "smbfs", "/Volumes/Time Machine Backups"),
    );
}

test "classifyFs - snapshot" {
    try testing.expectEqual(FsClass.snapshot, classifyFs(
        "com.apple.TimeMachine.2026-03-11-203149.local@/dev/disk3s5",
        "apfs",
        "/Volumes/.timemachine/data",
    ));
}

test "isTimeMachineSnapshot - detection" {
    try testing.expect(
        isTimeMachineSnapshot("com.apple.TimeMachine.2026-03-11-203149.local@/dev/disk3s5"),
    );
    try testing.expect(
        isTimeMachineSnapshot("com.apple.TimeMachine.2026-03-06-214229.backup@/dev/disk9s1"),
    );
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
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try padLeft(&aw.writer, "hi", 5);
    try testing.expectEqualStrings("   hi", aw.writer.buffered());
}

test "padRight - basic" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try padRight(&aw.writer, "hi", 5);
    try testing.expectEqualStrings("hi   ", aw.writer.buffered());
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-n"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
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
    if (comptime is_darwin) return error.SkipZigTest;
    const args = [_][]const u8{ "-I", "tmpfs" };
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("tmpfs", parsed.opts.exclude_type.?);
}

test "parseArgs - I flag inline value" {
    if (comptime is_darwin) return error.SkipZigTest;
    const args = [_][]const u8{"-Itmpfs"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("tmpfs", parsed.opts.exclude_type.?);
}

test "parseArgs - I flag missing argument" {
    if (comptime is_darwin) return error.SkipZigTest;
    const args = [_][]const u8{"-I"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err != null);
}

test "parseArgs - I flag sets suppress_inodes on macOS" {
    if (comptime !is_darwin) return error.SkipZigTest;
    const args = [_][]const u8{"-I"};
    const parsed = parseArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.opts.positionals);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.suppress_inodes);
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

// Issue #138, site 2: printTotal_formatField has the identical
// `bytes + display_block - 1` overflow as formatSize, but is a completely
// separate code path reached only through the --total render path. A fix
// applied only to formatSize must still trap this test.
test "printTotal_formatField - huge block-size ceils to 1 without overflow (issue #138)" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    const result = printTotal_formatField(&buf, 4096000, std.math.maxInt(u64), opts);
    try testing.expectEqualStrings("1", result);
}

// Same saturating-add discriminator as formatSize's, applied to site 2:
// bytes = u64::MAX, display_block = 1024 (ordinary size) must ceil to
// exactly 2^54 ("18014398509481984"), not the saturated
// "18014398509481983" a `+|` fix would produce.
test "printTotal_formatField - u64max bytes rejects a saturating fix (issue #138)" {
    var buf: [32]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    const result = printTotal_formatField(&buf, std.math.maxInt(u64), 1024, opts);
    try testing.expectEqualStrings("18014398509481984", result);
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "512B-blocks") != null);
}

test "runDf - c flag shows total" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "total") != null);
}

test "runDf - g flag accepted" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-g", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "1G-blocks") != null);
}

test "runDf - m flag accepted" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "1M-blocks") != null);
}

test "runDf - Y flag accepted" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-Y"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runDf - comma flag accepted" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-,", "-k", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
}

test "runDf - help mentions new flags" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-b") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-g") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-m") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-Y") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-,") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-I") != null);
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

test "runDf - I flag does not consume the next operand on macOS" {
    // On macOS, -I is a boolean (suppress inode counts), not a
    // type-filter requiring an argument, so it must not swallow "/".
    // Two operands are passed; both must be reported.
    if (comptime !is_darwin) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-I", "/", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // A header plus one row per operand. Asserting only exit 0 would pass
    // even when -I ate the first "/", which is the bug this guards.
    const out = stdout_aw.writer.buffered();
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.find(u8, out, "Inodes") == null);
}

// ============================================================================
// F20: df -P uses wrong POSIX column headers
// POSIX requires: "1024-blocks", "Available", "Capacity"
// Current code emits: "1K-blocks", "Available", "Use%"
// ============================================================================

test "printHeaderDynamic - POSIX mode uses 1024-blocks not 1K-blocks" {
    // POSIX (df -P) requires the header column to read "1024-blocks",
    // not "1K-blocks". See IEEE Std 1003.1-2017 df specification.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var opts = DfOptions{};
    opts.portability = true;
    opts.human_readable = false;
    opts.display.color = .off;
    opts.display.icons = .off;
    try printHeaderDynamic(&aw.writer, opts, .{}, testStyle(&aw.writer, .none));
    // POSIX mandates "1024-blocks"
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "1024-blocks") != null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "1K-blocks") == null);
}

test "printHeaderDynamic - POSIX mode uses Capacity not Use%" {
    // POSIX requires the percentage column to be labeled "Capacity",
    // not "Use%". See IEEE Std 1003.1-2017 df specification.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var opts = DfOptions{};
    opts.portability = true;
    opts.human_readable = false;
    opts.display.color = .off;
    opts.display.icons = .off;
    try printHeaderDynamic(&aw.writer, opts, .{}, testStyle(&aw.writer, .none));
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Capacity") != null);
    try testing.expect(std.mem.find(u8, aw.writer.buffered(), "Use%") == null);
}

test "runDf - P flag output has POSIX-compliant headers" {
    // Pin the WHOLE POSIX header set, not two of its five labels. The
    // narrower version of this test passed while the live renderer emitted
    // "Avail" for the third column, because "Available" was only ever
    // produced by the unreachable printHeader_emitPlain.
    //
    // Verified against GNU df 9.5 (LC_ALL=C, Ubuntu):
    //   df -P /              -> Filesystem 1024-blocks Used Available Capacity Mounted on
    //   df --block-size=1M / -> Filesystem 1M-blocks Used Available Use% Mounted on
    //   df -k -h /           -> Filesystem Size Used Avail Use% Mounted on
    // Note the real GNU rule for this column: "Avail" belongs to HUMAN
    // mode and "Available" to every BLOCK mode, POSIX or not. It is not
    // keyed on portability, so the fix is `if (human_readable or si)
    // "Avail" else "Available"`, not `if (portability)`.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // "Available" contains "Avail", so a substring search cannot tell the
    // two apart; compare the header token by token.
    try testExpectTokens(&.{
        "Filesystem", "1024-blocks", "Used", "Available", "Capacity", "Mounted", "on",
    }, testFirstLine(stdout_aw.writer.buffered()));
}

/// Run df with `args` and return the header line written to `out`.
fn testHeaderFor(out: *std.Io.Writer.Allocating, args: []const []const u8) ![]const u8 {
    std.debug.assert(args.len > 0);
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const code = try runDf(testing.allocator, testing.io, args, &out.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), code);
    return testFirstLine(out.writer.buffered());
}

test "runDf - Available label in non-POSIX block modes" {
    // The third column is "Available" in every BLOCK mode and "Avail" only
    // in HUMAN mode. It is NOT keyed on portability: a fix written as
    // `if (opts.portability)` passes the -P test above and still leaves
    // these two cases diverging. The only conditional that satisfies both
    // this test and the human-mode one below is
    // `if (opts.human_readable or opts.si) "Avail" else "Available"`.
    // Verified against GNU df 9.5 (LC_ALL=C, Ubuntu):
    //   df -k /              -> Filesystem 1K-blocks Used Available Use% ...
    //   df --block-size=1M / -> Filesystem 1M-blocks Used Available Use% ...
    //   df /       (GNU dflt)-> Filesystem 1K-blocks Used Available Use% ...
    // "Available" contains "Avail", so these must be token comparisons.
    var k_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer k_aw.deinit();
    try testExpectTokens(&.{
        "Filesystem", "1K-blocks", "Used", "Available", "Use%", "Mounted", "on",
    }, try testHeaderFor(&k_aw, &.{ "-k", "/" }));

    var bs_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer bs_aw.deinit();
    try testExpectTokens(&.{
        "Filesystem", "1M-blocks", "Used", "Available", "Use%", "Mounted", "on",
    }, try testHeaderFor(&bs_aw, &.{ "--block-size=1M", "/" }));
}

test "runDf - Avail label in human modes" {
    // The other half of the conditional described above, so an inverted
    // fix cannot go green. Verified against GNU df 9.5 (LC_ALL=C):
    //   df -h /    -> Filesystem Size Used Avail Use% Mounted on
    //   df -k -h / -> Filesystem Size Used Avail Use% Mounted on
    // The -k -h ordering matters: human mode wins last-flag-wins, so the
    // label must follow the resolved mode, not the presence of -k.
    var h_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer h_aw.deinit();
    try testExpectTokens(&.{
        "Filesystem", "Size", "Used", "Avail", "Use%", "Mounted", "on",
    }, try testHeaderFor(&h_aw, &.{ "-h", "/" }));

    var kh_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer kh_aw.deinit();
    try testExpectTokens(&.{
        "Filesystem", "Size", "Used", "Avail", "Use%", "Mounted", "on",
    }, try testHeaderFor(&kh_aw, &.{ "-k", "-h", "/" }));
}

test "runDf - P with block-size uses the raw byte count label" {
    // POSIX mode never abbreviates the block size. Verified against GNU
    // df 9.5 (LC_ALL=C, Ubuntu):
    //   df -P --block-size=512 /  -> 512-blocks
    //   df -P --block-size=1K /   -> 1024-blocks
    //   df -P --block-size=1M /   -> 1048576-blocks
    //   df -P --block-size=1G /   -> 1073741824-blocks
    //   df -P --block-size=2000 / -> 2000-blocks
    // Outside POSIX mode GNU does abbreviate: 1M-blocks, 512B-blocks,
    // 2kB-blocks. Ours applies the abbreviating map in both.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "--block-size=1M", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testExpectTokens(&.{
        "Filesystem", "1048576-blocks", "Used", "Available", "Capacity", "Mounted", "on",
    }, testFirstLine(stdout_aw.writer.buffered()));
}

// ============================================================================
// Issue #132: non-POSIX --block-size labels must follow GNU's
// divisibility-race abbreviation, not a hardcoded 512/1024/1M/1G literal
// map with a "{d}B-blocks" fallback.
//
// GNU picks the base (1000 vs 1024) by racing repeated division: whichever
// base keeps dividing the byte count evenly longer wins; a tie goes to
// 1000. It then scales by that base, rounding UP (never nearest), with a
// single decimal digit while the scaled mantissa is below 10.
//
// Every row below was verified against real GNU coreutils 9.4
// (LC_ALL=C, native Linux host):
//   for n in 512 999 1000 1023 1024 1500 1536 2000 2048 9950 10001 \
//            65536 123456 1000000 1024000 1025024 1048576 \
//            1048576000 1073741824 1 999999999 1099511627776 \
//            1152921504606846976; do
//     LC_ALL=C /usr/bin/df --block-size=$n / | head -1
//   done
// ============================================================================

test "headerLabels - GNU divisibility-race block-size abbreviations" {
    const Case = struct { bs: u64, want: []const u8 };
    const cases = [_]Case{
        // Regression guards: literal cases the old hardcoded map already
        // rendered correctly. Must keep passing after the fix.
        .{ .bs = 512, .want = "512B-blocks" },
        .{ .bs = 999, .want = "999B-blocks" },
        .{ .bs = 1024, .want = "1K-blocks" },
        .{ .bs = 1024 * 1024, .want = "1M-blocks" },
        .{ .bs = 1024 * 1024 * 1024, .want = "1G-blocks" },
        // New cases the buggy fallback got wrong (rendered "NB-blocks"
        // on the raw byte count instead of abbreviating).
        .{ .bs = 1000, .want = "1kB-blocks" },
        .{ .bs = 2000, .want = "2kB-blocks" },
        .{ .bs = 2048, .want = "2K-blocks" },
        .{ .bs = 65536, .want = "64K-blocks" },
        .{ .bs = 1500, .want = "1.5kB-blocks" },
        .{ .bs = 1023, .want = "1.1kB-blocks" }, // ceiling, not nearest (1.0 would be wrong)
        .{ .bs = 1536, .want = "1.6kB-blocks" }, // ceiling, not nearest (1.5 would be wrong)
        .{ .bs = 9950, .want = "10kB-blocks" }, // tenths carry into the integer part
        .{ .bs = 10001, .want = "11kB-blocks" }, // Q>=10: integer ceiling, no decimal
        .{ .bs = 123456, .want = "124kB-blocks" },
        .{ .bs = 1000000, .want = "1MB-blocks" },
        // TIE CASE: exactly 1000K. The divisibility race ties (both bases
        // divide out evenly the same number of times), and a tie goes to
        // base 1000 -- so this is 1.1MB, NOT 1000K. A naive "is it a
        // multiple of 1024" rule gets this backwards.
        .{ .bs = 1024000, .want = "1.1MB-blocks" },
        // ANTI-TIE: exactly 1000M, but base 1024 wins outright here, and
        // a 4-digit base-1024 mantissa (1000) is legal.
        .{ .bs = 1048576000, .want = "1000M-blocks" },
        .{ .bs = 1025024, .want = "1001K-blocks" }, // 4-digit base-1024 mantissa
        .{ .bs = 999999999, .want = "1GB-blocks" }, // integer ceiling carries into next exponent
        .{ .bs = 1099511627776, .want = "1T-blocks" },
        .{ .bs = 1152921504606846976, .want = "1E-blocks" }, // max base-1024 unit
        .{ .bs = 1, .want = "1B-blocks" },
    };
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.portability = false;
    for (cases) |case| {
        opts.block_size = case.bs;
        var buf: [32]u8 = undefined;
        const labels = headerLabels(&buf, opts);
        testing.expectEqualStrings(case.want, labels.size) catch |err| {
            std.debug.print(
                "block_size={d}: expected '{s}', got '{s}'\n",
                .{ case.bs, case.want, labels.size },
            );
            return err;
        };
    }
}

test "runDf - block-size tie and anti-tie cases against GNU's divisibility race" {
    // Both of these pin the direction of GNU's base-selection race at the
    // CLI level, not just against the headerLabels helper.
    //   df --block-size=1024000 /    -> 1.1MB-blocks (tie -> base 1000 wins)
    //   df --block-size=1048576000 / -> 1000M-blocks  (base 1024 wins outright)
    var tie_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer tie_aw.deinit();
    try testExpectTokens(&.{
        "Filesystem", "1.1MB-blocks", "Used", "Available", "Use%", "Mounted", "on",
    }, try testHeaderFor(&tie_aw, &.{ "--block-size=1024000", "/" }));

    var anti_tie_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer anti_tie_aw.deinit();
    try testExpectTokens(&.{
        "Filesystem", "1000M-blocks", "Used", "Available", "Use%", "Mounted", "on",
    }, try testHeaderFor(&anti_tie_aw, &.{ "--block-size=1048576000", "/" }));
}

test "runDf - block-size=0 is rejected with exit code 1" {
    // Consistency with PR #134: an invalid --block-size must reject at
    // parse time with a nonzero exit and the fixed error text, not fall
    // through to headerLabels formatting.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--block-size=0", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "invalid --block-size argument") != null,
    );
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

test "runDf - n flag returns exit code 1 on Linux" {
    // On Linux, -n is not a valid GNU df flag and should exit with
    // a usage error (exit code 1).
    if (comptime !is_linux) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-n"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

// ============================================================================
// Test support for output-shape assertions
// ============================================================================

/// Return the first line of `out` (the header row), without the newline.
fn testFirstLine(out: []const u8) []const u8 {
    const nl = std.mem.find(u8, out, "\n") orelse out.len;
    return out[0..nl];
}

/// Return line `index` of `out` (0-based), without the newline.
fn testLine(out: []const u8, index: u32) []const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    var seen: u32 = 0;
    while (it.next()) |line| : (seen += 1) {
        if (seen == index) return line;
        std.debug.assert(seen < 4096);
    }
    return "";
}

/// Assert that `line` splits on spaces into exactly `expected`. Column
/// padding varies with the data, so compare tokens rather than bytes.
fn testExpectTokens(expected: []const []const u8, line: []const u8) !void {
    std.debug.assert(expected.len > 0);
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    for (expected) |want| {
        const got = it.next() orelse {
            std.debug.print("missing token '{s}' in line '{s}'\n", .{ want, line });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(want, got);
    }
    if (it.next()) |extra| {
        std.debug.print("unexpected extra token '{s}' in line '{s}'\n", .{ extra, line });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// F1: macOS -I must suppress the inode columns
//
// BSD df on macOS resolves -i/-I last-flag-wins. Verified against
// /bin/df on macOS 25.5.0 with LC_ALL=C:
//   df -i -I /  ->  Filesystem 512-blocks Used Available Capacity Mounted on
//   df -I -i /  ->  ... Capacity iused ifree %iused  Mounted on
// Our layout is GNU-flavored (-i replaces the block columns), so -I
// cancels a preceding -i and a following -i re-enables inode mode.
// ============================================================================

test "runDf - i then I omits the inode columns on macOS" {
    if (comptime !is_darwin) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-i", "-I", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    // -I wins: no inode columns at all.
    try testing.expect(std.mem.find(u8, header, "Inodes") == null);
    try testing.expect(std.mem.find(u8, header, "IUsed") == null);
    try testing.expect(std.mem.find(u8, header, "IFree") == null);
    try testing.expect(std.mem.find(u8, header, "IUse%") == null);
    // The normal block layout is rendered instead.
    try testing.expect(std.mem.find(u8, header, "Filesystem") != null);
    try testing.expect(std.mem.find(u8, header, "Mounted on") != null);
    try testing.expect(std.mem.find(u8, header, "Used") != null);
}

test "runDf - I then i keeps the inode columns on macOS" {
    if (comptime !is_darwin) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-I", "-i", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    // -i is last, so it wins.
    try testing.expect(std.mem.find(u8, header, "Inodes") != null);
    try testing.expect(std.mem.find(u8, header, "IUsed") != null);
    try testing.expect(std.mem.find(u8, header, "IFree") != null);
    try testing.expect(std.mem.find(u8, header, "IUse%") != null);
}

test "runDf - I alone renders block columns on macOS" {
    if (comptime !is_darwin) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -I is boolean on macOS: it must not swallow the "/" operand.
    const args = [_][]const u8{ "-I", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "Inodes") == null);
    try testing.expect(std.mem.find(u8, out, "Mounted on") != null);
    // Exactly one operand was given, so exactly one data row is printed.
    // Had -I swallowed "/", df would fall back to the whole mount table.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    const row = testLine(out, 1);
    try testing.expectEqualStrings("/", row[row.len - 1 ..]);
}

// ============================================================================
// F3: -h must override an earlier block-size flag
//
// human_readable defaults to true, so a bare `-h` assertion cannot tell a
// working -h from a no-op. These orderings force -h to do real work.
// Verified against GNU df 9.5 (LC_ALL=C, Ubuntu):
//   df -k -h /              -> Filesystem Size Used Avail Use% Mounted on
//   df -h -k /              -> Filesystem 1K-blocks Used Available Use% ...
//   df -P -h /              -> Filesystem Size Used Avail Use% Mounted on
//   df --block-size=1M -h / -> Filesystem Size Used Avail Use% Mounted on
// ============================================================================

test "runDf - h overrides an earlier -k" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-k", "-h", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, header, "Size") != null);
    try testing.expect(std.mem.find(u8, header, "1K-blocks") == null);
}

test "runDf - k overrides an earlier -h" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-h", "-k", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, header, "1K-blocks") != null);
    try testing.expect(std.mem.find(u8, header, "Size") == null);
}

test "runDf - h overrides an earlier -P block size" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-h", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, header, "Size") != null);
    try testing.expect(std.mem.find(u8, header, "1024-blocks") == null);
}

test "runDf - h overrides an earlier --block-size" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--block-size=1M", "-h", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, header, "Size") != null);
    try testing.expect(std.mem.find(u8, header, "1M-blocks") == null);
}

test "runDf - h renders sizes with a unit suffix" {
    // Beyond the header label: the data row must carry human-readable
    // magnitudes, not raw 1K block counts.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-k", "-h", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const row = testLine(stdout_aw.writer.buffered(), 1);
    var it = std.mem.tokenizeScalar(u8, row, ' ');
    _ = it.next() orelse return error.TestUnexpectedResult; // Filesystem
    const size = it.next() orelse return error.TestUnexpectedResult;
    // Human-readable sizes end in a unit letter (or are a bare "0").
    const last = size[size.len - 1];
    const is_unit = last == 'K' or last == 'M' or last == 'G' or
        last == 'T' or last == 'P' or last == 'B';
    try testing.expect(is_unit);
}

// ============================================================================
// F2: --output=FIELD_LIST must select and order the columns
//
// Reference behavior captured from GNU coreutils df 9.5 on Ubuntu with
// LC_ALL=C (see the report accompanying this change). Highlights:
//   df --output /                -> all twelve fields, fixed order:
//        Filesystem Type Inodes IUsed IFree IUse% 1K-blocks Used Avail
//        Use% File Mounted on
//   df --output=source,size /    -> Filesystem 1K-blocks
//   df --output=target,pcent,source / -> Mounted on Use% Filesystem
//   df --output=bogus /          -> "field 'bogus' unknown", exit failure
//   df --output=source,source /  -> "field 'source' used more than once"
//   df --output= /               -> "field '' unknown"
//   df -i/-P/-T with --output    -> "mutually exclusive", exit failure
//   df --output=file,target /tmp -> the File column shows the operand;
//                                   with no operand it shows "-"
// GNU exits 1 on these errors and vibeutils df matches it, so these tests
// pin 1.
//
// The size/used/avail columns render through the same block-size logic as
// the default layout, so the size header follows -h/-k/--block-size.
// ============================================================================

test "runDf - output selects only the requested columns" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=source,size", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    // Default is human-readable, so the size label is "Size".
    try testExpectTokens(&.{ "Filesystem", "Size" }, header);
}

test "runDf - output honors the requested field order" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=target,pcent,source", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testExpectTokens(&.{ "Mounted", "on", "Use%", "Filesystem" }, header);
}

test "runDf - bare output prints all twelve fields" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testExpectTokens(&.{
        "Filesystem", "Type", "Inodes", "IUsed", "IFree", "IUse%",
        "Size",       "Used", "Avail",  "Use%",  "File",  "Mounted",
        "on",
    }, header);
}

test "runDf - output inode field labels" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=itotal,iused,iavail,ipcent", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testExpectTokens(&.{ "Inodes", "IUsed", "IFree", "IUse%" }, header);
}

test "runDf - output size label follows -k" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-k", "--output=size", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testExpectTokens(&.{"1K-blocks"}, testFirstLine(stdout_aw.writer.buffered()));
}

test "runDf - output size label follows --block-size" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--block-size=1M", "--output=size,used", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testExpectTokens(&.{ "1M-blocks", "Used" }, testFirstLine(stdout_aw.writer.buffered()));
}

test "runDf - output file column shows the operand" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=file,target", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testExpectTokens(&.{ "File", "Mounted", "on" }, testFirstLine(out));
    try testExpectTokens(&.{ "/", "/" }, testLine(out, 1));
}

test "runDf - output file column is a dash without an operand" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--output=file"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testExpectTokens(&.{"File"}, testFirstLine(out));
    try testExpectTokens(&.{"-"}, testLine(out, 1));
}

test "runDf - output with --total appends a total row" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=source,size,used", "--total", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testExpectTokens(&.{ "Filesystem", "Size", "Used" }, testFirstLine(out));
    // Header, one filesystem, then the total row.
    const total_row = testLine(out, 2);
    var it = std.mem.tokenizeScalar(u8, total_row, ' ');
    try testing.expectEqualStrings("total", it.next() orelse "");
}

// Issue #144: --output=pcent --total is the third byte-magnitude entry point
// into the percentage arithmetic, reached via formatPercent.
test "outputTotalCellText - pcent above the overflow threshold (issue #144)" {
    var buf: [64]u8 = undefined;
    const opts = DfOptions{};
    // 2e17 used of a 4e17 use-total: past the multiply bound, exactly 50%.
    const half = OutputTotals{
        .used_bytes = 200_000_000_000_000_000,
        .avail_bytes = 200_000_000_000_000_000,
    };
    try testing.expectEqualStrings("50%", outputTotalCellText(&buf, .pcent, half, opts));
    // 50.5% of the same use-total, so the ceiling is 51 and a floor gives 50.
    const ceils = OutputTotals{
        .used_bytes = 202_000_000_000_000_000,
        .avail_bytes = 198_000_000_000_000_000,
    };
    try testing.expectEqualStrings("51%", outputTotalCellText(&buf, .pcent, ceils, opts));
}

// Issue #158: --output --total stores the same byte sums in OutputTotals, so
// a printTotalDynamic-only widen still wraps here. `-B 1` makes Size the
// byte total; wrapping u64 prints 1553255926290458384 instead of 2e19.
test "outputSumTotals - size sum past 16 EiB (issue #158)" {
    const fs1 = makeFsInfo("/dev/disk1s1", "/", 10_000_000_000_000_000_000, 1);
    const fs2 = makeFsInfo("/dev/disk2s1", "/home", 10_000_000_000_000_000_000, 1);
    const items = [_]FsInfo{ fs1, fs2 };
    const totals = outputSumTotals(&items);
    var size_buf: [64]u8 = undefined;
    var used_buf: [64]u8 = undefined;
    var opts = DfOptions{};
    opts.total = true;
    opts.human_readable = false;
    opts.block_size = 1;
    try testing.expectEqualStrings(
        "20000000000000000000",
        outputTotalCellText(&size_buf, .size, totals, opts),
    );
    try testing.expectEqualStrings(
        "10000000000000000000",
        outputTotalCellText(&used_buf, .used, totals, opts),
    );
}

test "outputTotalCellText - pcent used plus avail past 16 EiB (issue #158)" {
    var buf: [64]u8 = undefined;
    var opts = DfOptions{};
    opts.human_readable = false;
    opts.block_size = 1;
    // Size stays in range so only the pcent add overflows. Equal used and
    // avail make the true percentage 50%; wrapping the add yields "-" and
    // saturating it to u64max yields ~55%.
    const totals = OutputTotals{
        .size_bytes = 200,
        .used_bytes = 10_000_000_000_000_000_000,
        .avail_bytes = 10_000_000_000_000_000_000,
    };
    try testing.expectEqualStrings("50%", outputTotalCellText(&buf, .pcent, totals, opts));
    try testing.expectEqualStrings("200", outputTotalCellText(&buf, .size, totals, opts));
}

test "runDf - output rejects an unknown field" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=bogus", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const err = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err, "option --output: field 'bogus' unknown") != null);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
}

test "runDf - output rejects a repeated field" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=source,source", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const err = stderr_aw.writer.buffered();
    const want = "option --output: field 'source' used more than once";
    try testing.expect(std.mem.find(u8, err, want) != null);
}

test "runDf - output rejects an empty field list" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const err = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err, "option --output: field '' unknown") != null);
}

test "runDf - output is mutually exclusive with -i" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-i", "--output=source", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const err = stderr_aw.writer.buffered();
    const want = "options -i and --output are mutually exclusive";
    try testing.expect(std.mem.find(u8, err, want) != null);
}

test "runDf - output is mutually exclusive with -P" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "--output=source", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const err = stderr_aw.writer.buffered();
    const want = "options -P and --output are mutually exclusive";
    try testing.expect(std.mem.find(u8, err, want) != null);
}

test "runDf - output is mutually exclusive with -T" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-T", "--output=source", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    const err = stderr_aw.writer.buffered();
    const want = "options -T and --output are mutually exclusive";
    try testing.expect(std.mem.find(u8, err, want) != null);
}

// ============================================================================
// --output controls WHICH columns appear; the style system controls HOW
// they render. No Usage/bar column is injected into a user-enumerated
// field list, but color and icons still apply to the selected columns,
// gated on isTty() as everywhere else.
// ============================================================================

test "runDf - output injects no Usage column in icons mode" {
    const io = testing.io;
    // Force icons on through a pipe so the full/bar decoration would
    // appear if --output did not suppress the extra column.
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "VIBEUTILS_STYLE", .value = null },
        .{ .key = "VIBEUTILS_ICONS", .value = "always" },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=source,size", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    // Exactly the two requested columns: no uninvited thirteenth column.
    try testing.expect(std.mem.find(u8, out, "Usage") == null);
    // And no usage bar glyphs anywhere in the rows.
    try testing.expect(std.mem.find(u8, out, "\xe2\x96\x88") == null);
    try testing.expect(std.mem.find(u8, out, "\xe2\x96\x91") == null);
    try testing.expect(std.mem.find(u8, out, "Mounted on") == null);
}

test "runDf - output keeps color on the selected columns" {
    const io = testing.io;
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "VIBEUTILS_STYLE", .value = null },
        .{ .key = "VIBEUTILS_COLOR", .value = "always" },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=source,size", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    // Styling still applies to what was selected...
    try testing.expect(std.mem.find(u8, out, "\x1b[") != null);
    // ...but the column set is still exactly the requested one.
    try testing.expect(std.mem.find(u8, out, "Mounted on") == null);
    try testing.expect(std.mem.find(u8, out, "Use%") == null);
}

test "runDf - output emits no ANSI without a tty" {
    const io = testing.io;
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    // TERM advertises color, but stdout is an Allocating writer, so the
    // isTty() gate must keep escapes out of the field-selected output.
    const staged = [_]common.env.Override{
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "VIBEUTILS_STYLE", .value = null },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--output=source,size", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.find(u8, out, "\x1b[") == null);
}

// ============================================================================
// -P selects the POSIX header set only while output is in block mode.
// Verified against GNU df 9.5 (LC_ALL=C, Ubuntu):
//   df -P /               -> Filesystem 1024-blocks Used Available Capacity
//   df -P -h /            -> Filesystem Size Used Avail Use% Mounted on
//   df -P -H /            -> Filesystem Size Used Avail Use% Mounted on
//   df -P -k /            -> Filesystem 1024-blocks Used Available Capacity
// When a human-readable mode is active the whole default header set is
// used; ours keeps the POSIX percent label because printHeaderDynamic
// takes it from opts.portability independently of the block-size mode.
// ============================================================================

test "runDf - P then h uses the default header set" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-h", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, header, "Size") != null);
    try testing.expect(std.mem.find(u8, header, "Use%") != null);
    // POSIX labels belong to block mode only.
    try testing.expect(std.mem.find(u8, header, "Capacity") == null);
    try testing.expect(std.mem.find(u8, header, "1024-blocks") == null);
}

test "runDf - P then H uses the default header set" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-H", "/" };
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const header = testFirstLine(stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, header, "Size") != null);
    try testing.expect(std.mem.find(u8, header, "Capacity") == null);
}

// ============================================================================
// The help text must describe -I as the running platform implements it:
// a boolean "suppress inode counts" on macOS (src/df.zig parseArgs), an
// exclude-type filter taking an argument on Linux.
// ============================================================================

/// Return the help line whose first non-space token is `opt`, or "".
fn testHelpLineFor(help: []const u8, opt: []const u8) []const u8 {
    std.debug.assert(opt.len > 0);
    std.debug.assert(help.len > 0);
    var it = std.mem.splitScalar(u8, help, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, opt)) continue;
        if (trimmed.len == opt.len) return line;
        if (trimmed[opt.len] == ' ') return line;
    }
    return "";
}

test "runDf - help documents I as a boolean on macOS" {
    if (comptime !is_darwin) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const line = testHelpLineFor(stdout_aw.writer.buffered(), "-I");
    try testing.expect(line.len > 0);
    // On macOS -I takes no argument, so the help must not advertise one.
    try testing.expect(std.mem.find(u8, line, "TYPE") == null);
    // It suppresses inode counts.
    try testing.expect(std.mem.find(u8, line, "inode") != null);
}

test "runDf - help documents I as a type filter on Linux" {
    if (comptime !is_linux) return error.SkipZigTest;
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDf(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    const line = testHelpLineFor(stdout_aw.writer.buffered(), "-I");
    try testing.expect(line.len > 0);
    // On Linux -I requires a TYPE argument.
    try testing.expect(std.mem.find(u8, line, "TYPE") != null);
}
