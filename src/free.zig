//! free - display amount of free and used memory
//!
//! The free utility displays the total amount of free and used physical
//! and swap memory on the system. It supports multiple output units
//! including human-readable format, and can poll continuously.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const prog_name = "free";

// ============================================================================
// Platform-specific memory information
// ============================================================================

// sysctl and getpagesize come from clean libc headers. The mach headers
// (mach/mach.h, mach/mach_host.h) are deliberately NOT imported here: Zig
// 0.16's translate-c cannot size the mach_msg_*_descriptor_t bitfield/union
// types in the macOS 26 SDK, marking them "uninstantiable" and failing the
// @cImport with "struct changed size unexpectedly" (issue #40). We only need
// a handful of mach calls, so we hand-write extern declarations below. These
// are stable kernel ABI and portable across SDK churn.
const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
});

// Hand-written mach bindings. See the comment on the @cImport above for why
// these are not pulled from the mach headers via translate-c. Type mapping
// matches <mach/arm/vm_types.h>, <mach/port.h>, and <mach/kern_return.h>:
//   natural_t   = unsigned int (u32)
//   integer_t   = int (c_int)
//   mach_port_t = mach_port_name_t = natural_t (u32)
//   kern_return_t = int (c_int)
const mach = struct {
    const natural_t = u32;
    const integer_t = c_int;
    const kern_return_t = c_int;
    const host_t = u32;
    const host_flavor_t = integer_t;
    const mach_msg_type_number_t = natural_t;

    /// HOST_VM_INFO64 from <mach/host_info.h>: 64-bit virtual memory stats.
    const HOST_VM_INFO64: host_flavor_t = 4;
    /// KERN_SUCCESS from <mach/kern_return.h>.
    const KERN_SUCCESS: kern_return_t = 0;

    /// Mirrors `struct vm_statistics64` from <mach/vm_statistics.h>. Field
    /// order and types must match the kernel ABI exactly; all fields are
    /// naturally aligned so no explicit padding is required.
    const vm_statistics64_data_t = extern struct {
        free_count: natural_t,
        active_count: natural_t,
        inactive_count: natural_t,
        wire_count: natural_t,
        zero_fill_count: u64,
        reactivations: u64,
        pageins: u64,
        pageouts: u64,
        faults: u64,
        cow_faults: u64,
        lookups: u64,
        hits: u64,
        purges: u64,
        purgeable_count: natural_t,
        speculative_count: natural_t,
        decompressions: u64,
        compressions: u64,
        swapins: u64,
        swapouts: u64,
        compressor_page_count: natural_t,
        throttled_count: natural_t,
        external_page_count: natural_t,
        internal_page_count: natural_t,
        total_uncompressed_pages_in_compressor: u64,
        swapped_count: u64,
    };

    extern fn mach_host_self() host_t;
    extern fn host_statistics64(
        host_priv: host_t,
        flavor: host_flavor_t,
        host_info64_out: [*]integer_t,
        host_info64_outCnt: *mach_msg_type_number_t,
    ) kern_return_t;
};

/// Memory information gathered from the system
pub const MemInfo = struct {
    /// Total physical memory in bytes
    total: u64,
    /// Used memory in bytes
    used: u64,
    /// Free memory in bytes
    free: u64,
    /// Shared memory in bytes (purgeable on macOS)
    shared: u64,
    /// Buffer/cache memory in bytes
    buff_cache: u64,
    /// Available memory in bytes
    available: u64,
    /// Total swap in bytes
    swap_total: u64,
    /// Used swap in bytes
    swap_used: u64,
    /// Free swap in bytes
    swap_free: u64,
};

/// Query memory information from the operating system
pub fn getMemInfo(io: std.Io) !MemInfo {
    return switch (@import("builtin").os.tag) {
        .macos => getMemInfoMacOS(),
        .linux => getMemInfoLinux(io),
        .freebsd, .openbsd, .netbsd => getMemInfoBsd(),
        else => error.UnsupportedPlatform,
    };
}

/// CTL_VM is 2 on OpenBSD and NetBSD (`sys/sysctl.h`).
const bsd_ctl_vm: c_int = 2;
/// OpenBSD `VM_UVMEXP` (`uvm/uvmexp.h`).
const openbsd_vm_uvmexp: c_int = 4;
/// NetBSD `VM_UVMEXP2` (`uvm/uvm_param.h`).
const netbsd_vm_uvmexp2: c_int = 5;

/// OpenBSD `struct uvmexp` (86 `int`s). Named through swap; tail is ABI pad.
const UvmexpOpenbsd = extern struct {
    pagesize: c_int,
    pagemask: c_int,
    pageshift: c_int,
    npages: c_int,
    free: c_int,
    active: c_int,
    inactive: c_int,
    paging: c_int,
    wired: c_int,
    zeropages: c_int,
    reserve_pagedaemon: c_int,
    reserve_kernel: c_int,
    percpucaches: c_int,
    vnodepages: c_int,
    vtextpages: c_int,
    freemin: c_int,
    freetarg: c_int,
    inactarg: c_int,
    wiredmax: c_int,
    anonmin: c_int,
    vtextmin: c_int,
    vnodemin: c_int,
    anonminpct: c_int,
    vtextminpct: c_int,
    vnodeminpct: c_int,
    nswapdev: c_int,
    swpages: c_int,
    swpginuse: c_int,
    _tail: [58]c_int,
};

/// NetBSD `struct uvmexp_sysctl` (89 `int64_t`s). Named through swap.
const UvmexpSysctlNetbsd = extern struct {
    pagesize: i64,
    pagemask: i64,
    pageshift: i64,
    npages: i64,
    free: i64,
    active: i64,
    inactive: i64,
    paging: i64,
    wired: i64,
    zeropages: i64,
    reserve_pagedaemon: i64,
    reserve_kernel: i64,
    freemin: i64,
    freetarg: i64,
    inactarg: i64,
    wiredmax: i64,
    nswapdev: i64,
    swpages: i64,
    swpginuse: i64,
    _tail: [70]i64,
};

comptime {
    std.debug.assert(@sizeOf(UvmexpOpenbsd) == 86 * @sizeOf(c_int));
    std.debug.assert(@sizeOf(UvmexpSysctlNetbsd) == 89 * @sizeOf(i64));
}

fn nonNegU64(n: anytype) u64 {
    std.debug.assert(n >= 0);
    const v: u64 = @intCast(n);
    std.debug.assert(v == @as(u64, @intCast(n)));
    return v;
}

fn memInfoFromPages(
    total: u64,
    page: u64,
    free_pages: u64,
    inactive_pages: u64,
    cache_pages: u64,
    swap_pages: u64,
    swap_used_pages: u64,
) MemInfo {
    std.debug.assert(page > 0);
    std.debug.assert(total > 0);
    const free = free_pages * page;
    const buff_cache = (inactive_pages + cache_pages) * page;
    const available = free + buff_cache;
    const used = total -| available;
    const swap_total = swap_pages * page;
    const swap_used = swap_used_pages * page;
    return MemInfo{
        .total = total,
        .used = used,
        .free = free,
        .shared = 0,
        .buff_cache = buff_cache,
        .available = available,
        .swap_total = swap_total,
        .swap_used = swap_used,
        .swap_free = swap_total -| swap_used,
    };
}

/// Numeric sysctl(3). OpenBSD has no sysctlbyname; NetBSD page
/// counts live in `uvmexp_sysctl`, not FreeBSD `vm.stats.vm.*`.
fn sysctlMib(comptime T: type, mib: []const c_int) !T {
    if (comptime (@import("builtin").os.tag == .openbsd or
        @import("builtin").os.tag == .netbsd))
    {
        std.debug.assert(mib.len >= 2);
        std.debug.assert(mib.len <= 4);
        var value: T = undefined;
        var len: usize = @sizeOf(T);
        std.posix.sysctl(mib, &value, &len, null, 0) catch return error.SysctlFailed;
        std.debug.assert(len > 0);
        std.debug.assert(len <= @sizeOf(T));
        return value;
    }
    return error.SysctlFailed;
}

/// sysctlbyname exists in FreeBSD libc. OpenBSD has only numeric
/// sysctl(3); calling sysctlbyname there fails at link time.
fn sysctlByName(comptime T: type, name: [:0]const u8) !T {
    if (comptime (@import("builtin").os.tag == .freebsd)) {
        var value: T = 0;
        var len: usize = @sizeOf(T);
        if (std.c.sysctlbyname(name, &value, &len, null, 0) != 0) {
            return error.SysctlFailed;
        }
        std.debug.assert(len > 0);
        std.debug.assert(len <= @sizeOf(T));
        return value;
    }
    return error.SysctlFailed;
}

fn sysctlFirstU64(names: []const [:0]const u8) !u64 {
    const names_max: u32 = 8;
    std.debug.assert(names.len > 0);
    std.debug.assert(names.len <= names_max);
    var i: u32 = 0;
    while (i < names.len) : (i += 1) {
        std.debug.assert(i < names_max);
        const name = names[i];
        if (sysctlByName(u64, name)) |v| return v else |_| {}
        if (sysctlByName(u32, name)) |v| return @as(u64, v) else |_| {}
    }
    return error.SysctlFailed;
}

fn getMemInfoFreebsd(total: u64) !MemInfo {
    std.debug.assert(total > 0);
    const page_size = try sysctlFirstU64(&.{ "vm.stats.vm.v_page_size", "hw.pagesize" });
    std.debug.assert(page_size > 0);
    const free_pages = try sysctlFirstU64(&.{"vm.stats.vm.v_free_count"});
    const inactive_pages = sysctlFirstU64(&.{"vm.stats.vm.v_inactive_count"}) catch 0;
    const cache_pages = sysctlFirstU64(&.{"vm.stats.vm.v_cache_count"}) catch 0;
    const swap_pages_bytes = sysctlFirstU64(&.{ "vm.swap_total", "vm.swap_size" }) catch 0;
    const swap_used_bytes = sysctlFirstU64(&.{"vm.swap_reserved"}) catch 0;
    var info = memInfoFromPages(
        total,
        page_size,
        free_pages,
        inactive_pages,
        cache_pages,
        0,
        0,
    );
    info.swap_total = swap_pages_bytes;
    info.swap_used = swap_used_bytes;
    info.swap_free = swap_pages_bytes -| swap_used_bytes;
    std.debug.assert(info.used <= info.total);
    return info;
}

fn getMemInfoOpenbsd(hw_total: u64) !MemInfo {
    std.debug.assert(hw_total > 0);
    const uvm = try sysctlMib(UvmexpOpenbsd, &.{ bsd_ctl_vm, openbsd_vm_uvmexp });
    const page = nonNegU64(uvm.pagesize);
    std.debug.assert(page > 0);
    const managed = nonNegU64(uvm.npages) * page;
    const total = if (managed > 0) managed else hw_total;
    std.debug.assert(total > 0);
    return memInfoFromPages(
        total,
        page,
        nonNegU64(uvm.free),
        nonNegU64(uvm.inactive),
        0,
        nonNegU64(uvm.swpages),
        nonNegU64(uvm.swpginuse),
    );
}

fn getMemInfoNetbsd(hw_total: u64) !MemInfo {
    std.debug.assert(hw_total > 0);
    const uvm = try sysctlMib(UvmexpSysctlNetbsd, &.{ bsd_ctl_vm, netbsd_vm_uvmexp2 });
    const page = nonNegU64(uvm.pagesize);
    std.debug.assert(page > 0);
    const managed = nonNegU64(uvm.npages) * page;
    const total = if (managed > 0) managed else hw_total;
    std.debug.assert(total > 0);
    return memInfoFromPages(
        total,
        page,
        nonNegU64(uvm.free),
        nonNegU64(uvm.inactive),
        0,
        nonNegU64(uvm.swpages),
        nonNegU64(uvm.swpginuse),
    );
}

/// Physical memory via `totalSystemMemory`, then OS-true page
/// counts: FreeBSD `sysctlbyname`, OpenBSD `CTL_VM`/`VM_UVMEXP`,
/// NetBSD `CTL_VM`/`VM_UVMEXP2`. Breakdowns are not fabricated.
fn getMemInfoBsd() !MemInfo {
    const builtin = @import("builtin");
    const total = std.process.totalSystemMemory() catch return error.SysctlFailed;
    std.debug.assert(total > 0);

    const info = switch (comptime builtin.os.tag) {
        .freebsd => try getMemInfoFreebsd(total),
        .openbsd => try getMemInfoOpenbsd(total),
        .netbsd => try getMemInfoNetbsd(total),
        else => unreachable,
    };
    std.debug.assert(info.total > 0);
    std.debug.assert(info.used <= info.total);
    return info;
}

fn getMemInfoMacOS() !MemInfo {
    // Total physical memory via sysctl
    var mem_size: u64 = 0;
    var size: usize = @sizeOf(u64);
    var mib = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    const sysctl_ret = c.sysctl(&mib, 2, &mem_size, &size, null, 0);
    if (sysctl_ret != 0) return error.SysctlFailed;
    // On success, the kernel reports it wrote exactly a u64 for HW_MEMSIZE.
    std.debug.assert(size == @sizeOf(u64));

    // VM statistics via host_statistics64. The count is the buffer size in
    // units of integer_t (natural_t), matching the HOST_VM_INFO64_COUNT macro.
    var vm_stat: mach.vm_statistics64_data_t = undefined;
    var count: mach.mach_msg_type_number_t =
        @intCast(@divExact(@sizeOf(mach.vm_statistics64_data_t), @sizeOf(mach.natural_t)));
    const host_ret = mach.host_statistics64(
        mach.mach_host_self(),
        mach.HOST_VM_INFO64,
        @ptrCast(&vm_stat),
        &count,
    );
    if (host_ret != mach.KERN_SUCCESS) return error.HostStatisticsFailed;

    const page_size: u64 = @intCast(c.getpagesize());
    // getpagesize() is a strictly positive power of two; the byte-size
    // products below are meaningless if it were zero.
    std.debug.assert(page_size != 0);
    const free_pages: u64 = @intCast(vm_stat.free_count);
    const active_pages: u64 = @intCast(vm_stat.active_count);
    const inactive_pages: u64 = @intCast(vm_stat.inactive_count);
    const speculative_pages: u64 = @intCast(vm_stat.speculative_count);
    const wired_pages: u64 = @intCast(vm_stat.wire_count);
    const compressor_pages: u64 = @intCast(vm_stat.compressor_page_count);
    const purgeable_pages: u64 = @intCast(vm_stat.purgeable_count);

    const free_mem = free_pages * page_size;
    const shared_mem = purgeable_pages * page_size;
    const buff_cache = (inactive_pages + speculative_pages + compressor_pages) * page_size;
    const used_mem = (active_pages + wired_pages + compressor_pages) * page_size;
    const available_mem = free_mem + (purgeable_pages + inactive_pages) * page_size;

    // Swap info via sysctl
    var swap: c.struct_xsw_usage = undefined;
    var swap_size: usize = @sizeOf(@TypeOf(swap));
    var swap_mib = [_]c_int{ c.CTL_VM, c.VM_SWAPUSAGE };
    var swap_total: u64 = 0;
    var swap_used: u64 = 0;
    var swap_free: u64 = 0;
    if (c.sysctl(&swap_mib, 2, &swap, &swap_size, null, 0) == 0) {
        swap_total = swap.xsu_total;
        swap_used = swap.xsu_used;
        swap_free = swap.xsu_avail;
    }

    return MemInfo{
        .total = mem_size,
        .used = used_mem,
        .free = free_mem,
        .shared = shared_mem,
        .buff_cache = buff_cache,
        .available = available_mem,
        .swap_total = swap_total,
        .swap_used = swap_used,
        .swap_free = swap_free,
    };
}

fn getMemInfoLinux(io: std.Io) !MemInfo {
    const file = std.Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{}) catch
        return error.ProcMeminfoNotFound;
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);
    const bytes_read = file_reader.interface.readSliceShort(&buf) catch return error.ReadFailed;
    // readSliceShort cannot report more bytes than the destination buffer.
    std.debug.assert(bytes_read <= buf.len);
    const content = buf[0..bytes_read];

    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;
    var shmem: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;
    var sreclaimable: u64 = 0;

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (parseMemInfoLine(line, "MemTotal:")) |v| {
            total = v * 1024;
        } else if (parseMemInfoLine(line, "MemFree:")) |v| {
            free = v * 1024;
        } else if (parseMemInfoLine(line, "MemAvailable:")) |v| {
            available = v * 1024;
        } else if (parseMemInfoLine(line, "Buffers:")) |v| {
            buffers = v * 1024;
        } else if (parseMemInfoLine(line, "Cached:")) |v| {
            cached = v * 1024;
        } else if (parseMemInfoLine(line, "Shmem:")) |v| {
            shmem = v * 1024;
        } else if (parseMemInfoLine(line, "SwapTotal:")) |v| {
            swap_total = v * 1024;
        } else if (parseMemInfoLine(line, "SwapFree:")) |v| {
            swap_free = v * 1024;
        } else if (parseMemInfoLine(line, "SReclaimable:")) |v| {
            sreclaimable = v * 1024;
        }
    }

    const buff_cache = buffers + cached + sreclaimable;
    const used = total -| free -| buff_cache;

    return MemInfo{
        .total = total,
        .used = used,
        .free = free,
        .shared = shmem,
        .buff_cache = buff_cache,
        .available = available,
        .swap_total = swap_total,
        .swap_used = swap_total -| swap_free,
        .swap_free = swap_free,
    };
}

fn parseMemInfoLine(line: []const u8, prefix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trimStart(u8, line[prefix.len..], " ");
    // Parse the number (value is in kB)
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
    // The loop advances end only while end < rest.len, so it never exceeds it.
    std.debug.assert(end <= rest.len);
    if (end == 0) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

// ============================================================================
// Output formatting
// ============================================================================

/// Unit for displaying memory values
const Unit = enum {
    bytes,
    kibi,
    mebi,
    gibi,
    human,
};

/// Parsed command-line options
const FreeArgs = struct {
    /// Display output in bytes
    bytes: bool = false,
    /// Display output in kibibytes (default)
    kibi: bool = false,
    /// Display output in mebibytes
    mebi: bool = false,
    /// Display output in gibibytes
    gibi: bool = false,
    /// Show human-readable output
    human: bool = false,
    /// Use powers of 1000 instead of 1024
    si: bool = false,
    /// Display total line
    total: bool = false,
    /// Wide output (don't merge buffers/cache)
    wide: bool = false,
    /// Continuous display interval in seconds
    seconds: ?u32 = null,
    /// Number of times to display (with -s)
    count: ?u32 = null,
    /// Display help
    help: bool = false,
    /// Display version
    version: bool = false,
    /// Color the used column: always, auto, never
    color: ?[]const u8 = null,
    /// Draw a usage bar: always, auto, never
    bar: ?[]const u8 = null,
    /// Positional arguments (none expected)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .bytes = .{ .short = 'b', .desc = "Display output in bytes" },
        .kibi = .{ .short = 'k', .desc = "Display output in kibibytes (default)" },
        .mebi = .{ .short = 'm', .desc = "Display output in mebibytes" },
        .gibi = .{ .short = 'g', .desc = "Display output in gibibytes" },
        .human = .{ .short = 'h', .desc = "Show human-readable output" },
        .si = .{ .short = 0, .desc = "Use powers of 1000 instead of 1024" },
        .total = .{ .short = 't', .desc = "Display a line showing column totals" },
        .wide = .{ .short = 'w', .desc = "Wide output" },
        .seconds = .{
            .short = 's',
            .desc = "Continuous display every N seconds",
            .value_name = "N",
        },
        .count = .{ .short = 'c', .desc = "Repeat printing N times, then exit", .value_name = "N" },
        .help = .{ .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .color = .{
            .short = 0,
            .desc = "Color the used column; WHEN is always, auto, or never",
            .value_name = "WHEN",
        },
        .bar = .{
            .short = 0,
            .desc = "Show a 10-cell usage bar; WHEN is always, auto, or never",
            .value_name = "WHEN",
        },
    };
};

/// Determine the output unit from parsed arguments
fn resolveUnit(args: FreeArgs) Unit {
    if (args.human) return .human;
    if (args.gibi) return .gibi;
    if (args.mebi) return .mebi;
    if (args.bytes) return .bytes;
    // Default
    return .kibi;
}

/// Scale a byte value to the selected unit
pub fn scaleValue(bytes: u64, unit: Unit, use_si: bool) u64 {
    const divisor: u64 = if (use_si) 1000 else 1024;
    // divisor is exactly 1000 (SI) or 1024; the @divTrunc calls below need
    // it nonzero, and both selections sit at or above the SI base.
    std.debug.assert(divisor != 0);
    std.debug.assert(divisor >= 1000);
    return switch (unit) {
        .bytes => bytes,
        .kibi => @divTrunc(bytes, divisor),
        .mebi => @divTrunc(bytes, divisor * divisor),
        .gibi => @divTrunc(bytes, divisor * divisor * divisor),
        .human => bytes, // handled separately
    };
}

/// Format a human-readable value with appropriate unit suffix
pub fn formatHumanReadable(buf: []u8, bytes: u64, use_si: bool) []const u8 {
    // Callers pass a fixed buffer; it must hold at least the shortest output.
    std.debug.assert(buf.len != 0);
    const format = common.format;
    return format.formatHumanReadable(buf, bytes, .{ .si = use_si, .suffix = .iec });
}

/// Column width for numeric values
const col_width = 12;

/// Print the header line
fn printHeader(writer: *std.Io.Writer, wide: bool) !void {
    if (wide) {
        try writer.print("{s:>15}{s:>12}{s:>12}{s:>12}{s:>12}{s:>12}{s:>12}\n", .{
            "total", "used", "free", "shared", "buffers", "cache", "available",
        });
    } else {
        try writer.print("{s:>15}{s:>12}{s:>12}{s:>12}{s:>12}{s:>12}\n", .{
            "total", "used", "free", "shared", "buff/cache", "available",
        });
    }
}

/// Format and print a single value, handling human-readable
fn printValue(writer: *std.Io.Writer, bytes: u64, unit: Unit, use_si: bool) !void {
    if (unit == .human) {
        var buf: [32]u8 = undefined;
        const formatted = formatHumanReadable(&buf, bytes, use_si);
        try writer.print("{s:>12}", .{formatted});
    } else {
        try writer.print("{d:>12}", .{scaleValue(bytes, unit, use_si)});
    }
}

/// df `calcUsagePercent`: u128 ceiling divide, 0 when total is 0.
fn calcUsagePercent(used: u64, total: u64) u8 {
    if (total == 0) {
        std.debug.assert(total == 0);
        return 0;
    }
    std.debug.assert(total != 0);
    const scaled: u128 = @as(u128, used) * 100;
    const denominator: u128 = total;
    const pct = @divTrunc(scaled, denominator) +
        @intFromBool(@rem(scaled, denominator) != 0);
    const result: u8 = @intCast(@min(pct, 100));
    std.debug.assert(result <= 100);
    return result;
}

/// Basic-band SGR for a usage percent: green <70, yellow <90, red else.
fn writeUsageSgr(writer: *std.Io.Writer, percent: u8) !void {
    std.debug.assert(percent <= 100);
    const code: u8 = if (percent < 70) 32 else if (percent < 90) 33 else 31;
    if (percent < 70) {
        std.debug.assert(code == 32);
    } else if (percent < 90) {
        std.debug.assert(code == 33);
    } else {
        std.debug.assert(code == 31);
    }
    try writer.print("\x1b[{d}m", .{code});
}

fn printValueMaybeColored(
    writer: *std.Io.Writer,
    bytes: u64,
    unit: Unit,
    use_si: bool,
    color: bool,
    percent: u8,
) !void {
    std.debug.assert(percent <= 100);
    std.debug.assert(@intFromEnum(unit) <= 4);
    if (color) try writeUsageSgr(writer, percent);
    try printValue(writer, bytes, unit, use_si);
    if (color) try writer.writeAll("\x1b[0m");
}

/// 10-cell df widget: `[████████░░]  84%`. percent is already clamped.
fn formatUsageBar(buf: []u8, percent: u8) []const u8 {
    std.debug.assert(percent <= 100);
    std.debug.assert(buf.len >= 40);
    const bar_width: u8 = 10;
    const filled: u8 = @intCast(@divTrunc(@as(u16, percent) * bar_width + 99, 100));
    std.debug.assert(filled <= bar_width);
    const empty: u8 = bar_width - filled;

    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    for (0..filled) |_| {
        buf[pos] = 0xe2;
        buf[pos + 1] = 0x96;
        buf[pos + 2] = 0x88;
        pos += 3;
    }
    for (0..empty) |_| {
        buf[pos] = 0xe2;
        buf[pos + 1] = 0x96;
        buf[pos + 2] = 0x91;
        pos += 3;
    }
    buf[pos] = ']';
    pos += 1;
    buf[pos] = ' ';
    pos += 1;
    const pct_str = std.fmt.bufPrint(buf[pos..], "{d:>3}%", .{percent}) catch
        return buf[0..pos];
    pos += pct_str.len;
    return buf[0..pos];
}

fn barIsOn(opts: RenderOptions) bool {
    const on = switch (opts.bar) {
        .always => true,
        .never => false,
        .auto => opts.icons == .on,
    };
    std.debug.assert(opts.bar != .never or !on);
    std.debug.assert(opts.bar != .always or on);
    return on;
}

fn writeUsageBar(writer: *std.Io.Writer, percent: u8, color: bool) !void {
    std.debug.assert(percent <= 100);
    var buf: [48]u8 = undefined;
    const bar = formatUsageBar(&buf, percent);
    std.debug.assert(bar.len != 0);
    try writer.writeAll(" ");
    if (color) try writeUsageSgr(writer, percent);
    try writer.writeAll(bar);
    if (color) try writer.writeAll("\x1b[0m");
}

/// Print a memory row (Mem: or Swap: or Total:)
fn printMemRow(
    writer: *std.Io.Writer,
    label: []const u8,
    info: MemInfo,
    unit: Unit,
    use_si: bool,
    wide: bool,
    is_swap: bool,
    render: RenderOptions,
) !void {
    // Every row carries a non-empty label for the left-padded label column.
    std.debug.assert(label.len != 0);
    const used_b = if (is_swap) info.swap_used else info.used;
    const total_b = if (is_swap) info.swap_total else info.total;
    const percent = calcUsagePercent(used_b, total_b);
    std.debug.assert(percent <= 100);
    try writer.print("{s:<6}", .{label});

    if (is_swap) {
        try printValue(writer, info.swap_total, unit, use_si);
        try printValueMaybeColored(writer, info.swap_used, unit, use_si, render.color, percent);
        try printValue(writer, info.swap_free, unit, use_si);
    } else if (wide) {
        try printValue(writer, info.total, unit, use_si);
        try printValueMaybeColored(writer, info.used, unit, use_si, render.color, percent);
        try printValue(writer, info.free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        // Split buff/cache into buffers and cache.
        // MemInfo merges these; show buff_cache as buffers, 0 as cache.
        try printValue(writer, info.buff_cache, unit, use_si);
        try printValue(writer, 0, unit, use_si);
        try printValue(writer, info.available, unit, use_si);
    } else {
        try printValue(writer, info.total, unit, use_si);
        try printValueMaybeColored(writer, info.used, unit, use_si, render.color, percent);
        try printValue(writer, info.free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        try printValue(writer, info.buff_cache, unit, use_si);
        try printValue(writer, info.available, unit, use_si);
    }
    if (barIsOn(render)) {
        try writeUsageBar(writer, percent, render.color);
    }
    try writer.writeAll("\n");
}

/// Print the total row
fn printTotalRow(
    writer: *std.Io.Writer,
    info: MemInfo,
    unit: Unit,
    use_si: bool,
    wide: bool,
) !void {
    const total_total = info.total + info.swap_total;
    const total_used = info.used + info.swap_used;
    const total_free = info.free + info.swap_free;

    try writer.print("{s:<6}", .{"Total:"});

    if (wide) {
        try printValue(writer, total_total, unit, use_si);
        try printValue(writer, total_used, unit, use_si);
        try printValue(writer, total_free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        try printValue(writer, info.buff_cache, unit, use_si);
        try printValue(writer, 0, unit, use_si);
        try printValue(writer, info.available, unit, use_si);
        try writer.writeAll("\n");
    } else {
        try printValue(writer, total_total, unit, use_si);
        try printValue(writer, total_used, unit, use_si);
        try printValue(writer, total_free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        try printValue(writer, info.buff_cache, unit, use_si);
        try printValue(writer, info.available, unit, use_si);
        try writer.writeAll("\n");
    }
}

/// `--color`/`--bar` WHEN. `bar == .auto` follows resolved `icons`.
const RenderWhen = enum { always, auto, never };

/// Injected render config so tests do not need a real TTY. Color is already
/// resolved on/off; `bar` may be `.auto` so `--bar=auto` can follow `icons`.
const RenderOptions = struct {
    color: bool = false,
    bar: RenderWhen = .never,
    icons: common.display_config.ResolvedMode = .off,
};

const RenderResolveError = error{ InvalidColor, InvalidBar };

/// Parse a required-value WHEN. Null means the caller should use `.auto`.
fn parseRenderWhen(value: []const u8) ?RenderWhen {
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "never")) return .never;
    std.debug.assert(!std.mem.eql(u8, value, "always"));
    std.debug.assert(!std.mem.eql(u8, value, "never"));
    return null;
}

/// ls-style kill switch: NO_COLOR and TERM=dumb beat `--color=always`.
fn colorKillSwitchOn() bool {
    const no_color = common.env.getEnv("NO_COLOR") != null;
    const dumb_term = if (common.env.getEnv("TERM")) |term|
        std.mem.eql(u8, term, "dumb")
    else
        false;
    const killed = no_color or dumb_term;
    std.debug.assert(!no_color or killed);
    std.debug.assert(!dumb_term or killed);
    return killed;
}

fn resolveRenderOptions(allocator: Allocator, parsed: FreeArgs) RenderResolveError!RenderOptions {
    const color_when = parseRenderWhen(parsed.color orelse "auto") orelse
        return error.InvalidColor;
    const bar_when = parseRenderWhen(parsed.bar orelse "auto") orelse
        return error.InvalidBar;
    const display = common.display_config.DisplayConfig.resolve(allocator);
    const killed = colorKillSwitchOn();
    // `--color=auto` follows the real stdout TTY, not DisplayConfig.color.
    // VIBEUTILS_COLOR=always / VIBEUTILS_STYLE=always would otherwise leak
    // ANSI into pipes (CLAUDE.md isatty guard). Kill switches still apply.
    const stdout_tty = common.env.isTty(std.Io.File.stdout().handle);
    const color = switch (color_when) {
        .never => false,
        .always => !killed,
        .auto => stdout_tty and !killed,
    };
    if (killed) std.debug.assert(!color);
    if (color_when == .never) std.debug.assert(!color);
    return .{
        .color = color,
        .bar = bar_when,
        .icons = display.icons,
    };
}

/// Print a complete memory report for the given MemInfo
pub fn printReport(
    writer: *std.Io.Writer,
    info: MemInfo,
    unit: Unit,
    use_si: bool,
    show_total: bool,
    wide: bool,
    render: RenderOptions,
) !void {
    std.debug.assert(prog_name.len != 0);
    std.debug.assert(@intFromEnum(render.bar) <= 2);
    try printHeader(writer, wide);
    try printMemRow(writer, "Mem:", info, unit, use_si, wide, false, render);
    try printMemRow(writer, "Swap:", info, unit, use_si, wide, true, render);
    if (show_total) {
        try printTotalRow(writer, info, unit, use_si, wide);
    }
}

// ============================================================================
// Main entry point
// ============================================================================

/// Result of argument parsing: on success `parsed` holds the FreeArgs and
/// `code` is unused; on failure `parsed` is null and `code` is the exit code.
const ParseResult = struct {
    parsed: ?FreeArgs,
    code: u8,
};

/// Parse free's arguments, mapping parse errors to exit codes verbatim.
/// Ownership of `parsed.positionals` is returned to the caller; the helper
/// frees nothing, matching the original inline error arms.
fn runFree_parseArgs(
    allocator: Allocator,
    args: []const []const u8,
    stderr_writer: *std.Io.Writer,
) !ParseResult {
    // Sanity on the exit-code constants this helper maps onto.
    std.debug.assert(@intFromEnum(common.ExitCode.general_error) !=
        @intFromEnum(common.ExitCode.success));
    std.debug.assert(prog_name.len != 0);

    const parsed = common.argparse.ArgParser.parse(FreeArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "unrecognized option",
                    .{},
                );
                return ParseResult{
                    .parsed = null,
                    .code = @intFromEnum(common.ExitCode.general_error),
                };
            },
            error.MissingValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "option requires an argument",
                    .{},
                );
                return ParseResult{
                    .parsed = null,
                    .code = @intFromEnum(common.ExitCode.general_error),
                };
            },
            error.InvalidValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "invalid option value",
                    .{},
                );
                return ParseResult{
                    .parsed = null,
                    .code = @intFromEnum(common.ExitCode.general_error),
                };
            },
            else => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "argument parsing error",
                    .{},
                );
                return ParseResult{
                    .parsed = null,
                    .code = @intFromEnum(common.ExitCode.general_error),
                };
            },
        }
    };
    return ParseResult{ .parsed = parsed, .code = @intFromEnum(common.ExitCode.success) };
}

/// Drive the continuous-display loop. The parent only calls this when an
/// interval was requested, so the interval is guaranteed positive.
fn runFree_displayContinuous(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    allocator: Allocator,
    unit: Unit,
    use_si: bool,
    show_total: bool,
    wide: bool,
    render: RenderOptions,
    interval: u32,
    repeat_count: u32,
) u8 {
    std.debug.assert(interval != 0);

    var iterations: u32 = 0;
    while (repeat_count == 0 or iterations < repeat_count) {
        // Bounded-loop invariant: in counted mode the body only runs while
        // iterations is below the cap; unbounded mode (repeat_count == 0)
        // admits any iteration count, so the bound is asserted only then.
        if (repeat_count != 0) {
            std.debug.assert(iterations <= repeat_count);
        }
        const result = displayOnce(
            io,
            stdout_writer,
            stderr_writer,
            allocator,
            unit,
            use_si,
            show_total,
            wide,
            render,
        );
        if (result != 0) return result;
        stdout_writer.flush() catch {};

        iterations += 1;
        if (repeat_count > 0 and iterations >= repeat_count) break;

        io.sleep(.fromSeconds(interval), .awake) catch {};

        // Print blank line between iterations
        stdout_writer.writeAll("\n") catch {};
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Handle the early-exit flags (help, version) and the extra-operand error.
/// Returns the exit code to propagate, or null when normal display proceeds.
fn runFree_handleEarlyExit(
    allocator: Allocator,
    parsed: FreeArgs,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    std.debug.assert(prog_name.len > 0);
    std.debug.assert(@intFromEnum(common.ExitCode.success) == 0);

    if (parsed.help) {
        printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.positionals.len > 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "extra operand '{s}'",
            .{parsed.positionals[0]},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    return null;
}

fn reportInvalidWhen(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    err: RenderResolveError,
    parsed: FreeArgs,
) u8 {
    std.debug.assert(err == error.InvalidColor or err == error.InvalidBar);
    const flag: []const u8 = switch (err) {
        error.InvalidColor => "--color",
        error.InvalidBar => "--bar",
    };
    const value: []const u8 = switch (err) {
        error.InvalidColor => parsed.color.?,
        error.InvalidBar => parsed.bar.?,
    };
    // Empty `--color=` / `--bar=` is valid argparse and still an invalid WHEN.
    // Do not assert on argv length; print the same diagnostic as bogus WHEN.
    switch (err) {
        error.InvalidColor => std.debug.assert(parsed.color != null),
        error.InvalidBar => std.debug.assert(parsed.bar != null),
    }
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "invalid argument '{s}' for '{s}'",
        .{ value, flag },
    );
    return @intFromEnum(common.ExitCode.general_error);
}

fn runFree_rejectZeroCount(
    allocator: Allocator,
    parsed: FreeArgs,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    std.debug.assert(@intFromEnum(common.ExitCode.general_error) != 0);
    const count = parsed.count orelse return null;
    if (count != 0) {
        std.debug.assert(count != 0);
        return null;
    }
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "failed to parse count argument: '0': Numerical result out of range",
        .{},
    );
    return @intFromEnum(common.ExitCode.general_error);
}

pub fn runFree(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    std.debug.assert(prog_name.len > 0);
    std.debug.assert(@intFromEnum(common.ExitCode.success) == 0);

    const parse_result = try runFree_parseArgs(allocator, args, stderr_writer);
    if (parse_result.parsed == null) return parse_result.code;
    const parsed = parse_result.parsed.?;
    defer allocator.free(parsed.positionals);

    if (runFree_handleEarlyExit(allocator, parsed, stdout_writer, stderr_writer)) |code| {
        return code;
    }

    const render = resolveRenderOptions(allocator, parsed) catch |err| {
        return reportInvalidWhen(allocator, stderr_writer, err, parsed);
    };

    const unit = resolveUnit(parsed);
    const use_si = parsed.si;
    const show_total = parsed.total;
    const wide = parsed.wide;

    if (runFree_rejectZeroCount(allocator, parsed, stderr_writer)) |code| {
        return code;
    }

    const repeat_count = parsed.count orelse 0;
    // procps accepts a bare -c: the count carries an implied one-second
    // interval, paid only between reports, so -c 1 returns immediately.
    const interval = parsed.seconds orelse
        if (parsed.count != null) @as(u32, 1) else 0;

    if (interval == 0) {
        return displayOnce(
            io,
            stdout_writer,
            stderr_writer,
            allocator,
            unit,
            use_si,
            show_total,
            wide,
            render,
        );
    }

    return runFree_displayContinuous(
        io,
        stdout_writer,
        stderr_writer,
        allocator,
        unit,
        use_si,
        show_total,
        wide,
        render,
        interval,
        repeat_count,
    );
}

fn displayOnce(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    allocator: Allocator,
    unit: Unit,
    use_si: bool,
    show_total: bool,
    wide: bool,
    render: RenderOptions,
) u8 {
    std.debug.assert(prog_name.len != 0);
    std.debug.assert(@intFromEnum(common.ExitCode.success) == 0);
    const info = getMemInfo(io) catch {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "failed to read memory information",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    };

    printReport(stdout_writer, info, unit, use_si, show_total, wide, render) catch {
        return @intFromEnum(common.ExitCode.general_error);
    };

    return @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runFree);
}

fn printHelp(allocator: Allocator, writer: *std.Io.Writer) void {
    common.help.printColorized(allocator, writer,
        \\Usage: free [OPTION]...
        \\Display the amount of free and used memory in the system.
        \\
        \\  -b, --bytes     display output in bytes
        \\  -k, --kibi      display output in kibibytes (default)
        \\  -m, --mebi      display output in mebibytes
        \\  -g, --gibi      display output in gibibytes
        \\  -h, --human     show human-readable output
        \\      --si        use powers of 1000 instead of 1024
        \\  -t, --total     display a line showing column totals
        \\  -w, --wide      wide output
        \\      --color=WHEN  color the used column; WHEN is always, auto, never
        \\      --bar=WHEN    show a 10-cell usage bar; WHEN is always, auto, never
        \\  -s N, --seconds=N   continuously display every N seconds
        \\  -c N, --count=N     repeat printing N times, then exit
        \\      --help      display this help and exit
        \\  -V, --version   output version information and exit
        \\
    ) catch {};
}

fn printVersion(writer: *std.Io.Writer) void {
    writer.print("free ({s}) {s}\n", .{ common.name, common.version }) catch {};
}

// ============================================================================
// TESTS
// ============================================================================

test "scaleValue bytes" {
    try testing.expectEqual(@as(u64, 1024), scaleValue(1024, .bytes, false));
    try testing.expectEqual(@as(u64, 0), scaleValue(0, .bytes, false));
}

test "scaleValue kibi" {
    try testing.expectEqual(@as(u64, 1), scaleValue(1024, .kibi, false));
    try testing.expectEqual(@as(u64, 1024), scaleValue(1024 * 1024, .kibi, false));
    try testing.expectEqual(@as(u64, 0), scaleValue(512, .kibi, false));
}

test "scaleValue mebi" {
    try testing.expectEqual(@as(u64, 1), scaleValue(1024 * 1024, .mebi, false));
    try testing.expectEqual(@as(u64, 0), scaleValue(1024, .mebi, false));
}

test "scaleValue gibi" {
    try testing.expectEqual(@as(u64, 1), scaleValue(1024 * 1024 * 1024, .gibi, false));
    try testing.expectEqual(@as(u64, 0), scaleValue(1024 * 1024, .gibi, false));
}

test "scaleValue si mode" {
    try testing.expectEqual(@as(u64, 1), scaleValue(1000, .kibi, true));
    try testing.expectEqual(@as(u64, 1), scaleValue(1000 * 1000, .mebi, true));
    try testing.expectEqual(@as(u64, 1), scaleValue(1000 * 1000 * 1000, .gibi, true));
}

test "formatHumanReadable small values" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", formatHumanReadable(&buf, 0, false));
}

test "formatHumanReadable kibi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 2048, false);
    try testing.expectEqualStrings("2.0Ki", result);
}

test "formatHumanReadable mebi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 8 * 1024 * 1024, false);
    try testing.expectEqualStrings("8.0Mi", result);
}

test "formatHumanReadable gibi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 4 * 1024 * 1024 * 1024, false);
    try testing.expectEqualStrings("4.0Gi", result);
}

test "formatHumanReadable si mode" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 5000, true);
    try testing.expectEqualStrings("5.0kB", result);
}

test "formatHumanReadable si mebi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 3 * 1000 * 1000, true);
    try testing.expectEqualStrings("3.0MB", result);
}

test "resolveUnit defaults to kibi" {
    const args = FreeArgs{};
    try testing.expectEqual(Unit.kibi, resolveUnit(args));
}

test "resolveUnit bytes flag" {
    var args = FreeArgs{};
    args.bytes = true;
    try testing.expectEqual(Unit.bytes, resolveUnit(args));
}

test "resolveUnit human flag" {
    var args = FreeArgs{};
    args.human = true;
    try testing.expectEqual(Unit.human, resolveUnit(args));
}

test "resolveUnit gibi flag" {
    var args = FreeArgs{};
    args.gibi = true;
    try testing.expectEqual(Unit.gibi, resolveUnit(args));
}

test "resolveUnit mebi flag" {
    var args = FreeArgs{};
    args.mebi = true;
    try testing.expectEqual(Unit.mebi, resolveUnit(args));
}

test "resolveUnit human takes priority" {
    var args = FreeArgs{};
    args.human = true;
    args.bytes = true;
    args.mebi = true;
    try testing.expectEqual(Unit.human, resolveUnit(args));
}

test "printReport with mock data" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const info = MemInfo{
        .total = 16 * 1024 * 1024 * 1024,
        .used = 8 * 1024 * 1024 * 1024,
        .free = 4 * 1024 * 1024 * 1024,
        .shared = 512 * 1024 * 1024,
        .buff_cache = 4 * 1024 * 1024 * 1024,
        .available = 12 * 1024 * 1024 * 1024,
        .swap_total = 2 * 1024 * 1024 * 1024,
        .swap_used = 128 * 1024 * 1024,
        .swap_free = 2 * 1024 * 1024 * 1024 - 128 * 1024 * 1024,
    };

    try printReport(&stdout_aw.writer, info, .kibi, false, false, false, .{});

    const output = stdout_aw.writer.buffered();
    // Should contain header and two data lines
    try testing.expect(std.mem.find(u8, output, "total") != null);
    try testing.expect(std.mem.find(u8, output, "Mem:") != null);
    try testing.expect(std.mem.find(u8, output, "Swap:") != null);
}

test "printReport with total line" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const info = MemInfo{
        .total = 8 * 1024 * 1024 * 1024,
        .used = 4 * 1024 * 1024 * 1024,
        .free = 2 * 1024 * 1024 * 1024,
        .shared = 0,
        .buff_cache = 2 * 1024 * 1024 * 1024,
        .available = 6 * 1024 * 1024 * 1024,
        .swap_total = 1024 * 1024 * 1024,
        .swap_used = 0,
        .swap_free = 1024 * 1024 * 1024,
    };

    try printReport(&stdout_aw.writer, info, .kibi, false, true, false, .{});

    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, "Total:") != null);
}

test "printReport wide mode" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const info = MemInfo{
        .total = 16 * 1024 * 1024 * 1024,
        .used = 8 * 1024 * 1024 * 1024,
        .free = 4 * 1024 * 1024 * 1024,
        .shared = 0,
        .buff_cache = 4 * 1024 * 1024 * 1024,
        .available = 12 * 1024 * 1024 * 1024,
        .swap_total = 0,
        .swap_used = 0,
        .swap_free = 0,
    };

    try printReport(&stdout_aw.writer, info, .kibi, false, false, true, .{});

    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, "buffers") != null);
    try testing.expect(std.mem.find(u8, output, "cache") != null);
}

test "printReport human readable" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const info = MemInfo{
        .total = 16 * 1024 * 1024 * 1024,
        .used = 8 * 1024 * 1024 * 1024,
        .free = 4 * 1024 * 1024 * 1024,
        .shared = 512 * 1024 * 1024,
        .buff_cache = 4 * 1024 * 1024 * 1024,
        .available = 12 * 1024 * 1024 * 1024,
        .swap_total = 2 * 1024 * 1024 * 1024,
        .swap_used = 128 * 1024 * 1024,
        .swap_free = 2 * 1024 * 1024 * 1024 - 128 * 1024 * 1024,
    };

    try printReport(&stdout_aw.writer, info, .human, false, false, false, .{});

    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, "Gi") != null);
}

test "runFree help flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: free") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runFree version flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "free") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.name) != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runFree unknown flag returns exit code 1" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "free:") != null);
}

test "runFree extra arguments returns exit code 1" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"extra"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "runFree default output" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Mem:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Swap:") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "runFree bytes flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-b"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "runFree mebi flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-m"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "runFree gibi flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-g"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "runFree human flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "runFree total flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-t"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Total:") != null);
}

test "runFree wide flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-w"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "buffers") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "cache") != null);
}

test "runFree short version flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "free") != null);
}

test "parseMemInfoLine valid" {
    const result = parseMemInfoLine("MemTotal:       16384000 kB", "MemTotal:");
    try testing.expectEqual(@as(?u64, 16384000), result);
}

test "parseMemInfoLine no match" {
    const result = parseMemInfoLine("MemFree:       8192000 kB", "MemTotal:");
    try testing.expectEqual(@as(?u64, null), result);
}

test "parseMemInfoLine empty value" {
    const result = parseMemInfoLine("MemTotal:       ", "MemTotal:");
    try testing.expectEqual(@as(?u64, null), result);
}

test "getMemInfo returns valid data" {
    const info = getMemInfo(testing.io) catch return;
    // Total memory should be positive
    try testing.expect(info.total > 0);
    // Used + free should not exceed total (approximately)
    try testing.expect(info.used <= info.total);
}

// Regression guard for issue #40: the hand-written mach.vm_statistics64_data_t
// replaces a translate-c @cImport that broke on the macOS 26 SDK. translate-c
// emitted @sizeOf assertions to verify the struct against the C ABI; we lost
// those when we dropped the import, so re-create them here. A wrong field
// order or type would make host_statistics64 fill the struct with values at
// the wrong offsets, so free would silently report garbage memory numbers.
// Offsets are derived from struct vm_statistics64 in <mach/vm_statistics.h>;
// every field is naturally aligned, giving a 160-byte struct with no padding.
test "mach.vm_statistics64_data_t matches the C ABI layout" {
    const T = mach.vm_statistics64_data_t;
    // Total size and field count, mirroring the dropped translate-c assertion.
    try testing.expectEqual(@as(usize, 160), @sizeOf(T));
    try testing.expectEqual(@as(usize, 40), @divExact(@sizeOf(T), @sizeOf(mach.natural_t)));

    // Offsets of the fields getMemInfoMacOS actually reads.
    try testing.expectEqual(@as(usize, 0), @offsetOf(T, "free_count"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(T, "active_count"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(T, "inactive_count"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(T, "wire_count"));
    try testing.expectEqual(@as(usize, 88), @offsetOf(T, "purgeable_count"));
    try testing.expectEqual(@as(usize, 92), @offsetOf(T, "speculative_count"));
    try testing.expectEqual(@as(usize, 128), @offsetOf(T, "compressor_page_count"));
    // Last field must end exactly at the struct boundary.
    try testing.expectEqual(@as(usize, 152), @offsetOf(T, "swapped_count"));
}

// Cross-check the mach path against an independent source: total physical
// memory from host_statistics64's caller must agree with sysctl hw.memsize.
// If the struct layout regressed, getMemInfoMacOS would still read memsize
// correctly (separate sysctl call) but the page counts would be nonsense —
// so we also assert free/used stay within the physical total.
test "getMemInfoMacOS agrees with sysctl on macOS" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const info = try getMemInfoMacOS();

    var memsize: u64 = 0;
    var len: usize = @sizeOf(u64);
    var mib = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    try testing.expectEqual(@as(c_int, 0), c.sysctl(&mib, 2, &memsize, &len, null, 0));

    try testing.expect(memsize > 0);
    try testing.expectEqual(memsize, info.total);
    try testing.expect(info.free <= info.total);
    try testing.expect(info.used <= info.total);
}

// ========== AUDIT WAVE 4: free IMPORTANT findings ==========

// IMPORTANT: -w wide mode always shows 0 for the buffers column
// GNU free -w shows the actual kernel buffer allocation in the buffers
// column. Our implementation hardcodes 0 for buffers regardless of
// platform, because MemInfo.buff_cache merges buffers + cached and
// the individual buffers value is lost.
// Currently: printReport wide mode shows 0 for buffers even when
// buff_cache is nonzero. Expected: nonzero buffers value.
test "audit: free -w wide mode should show nonzero buffers" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Mock data with nonzero buff_cache — buffers should be part of it
    const info = MemInfo{
        .total = 16 * 1024 * 1024 * 1024,
        .used = 8 * 1024 * 1024 * 1024,
        .free = 4 * 1024 * 1024 * 1024,
        .shared = 512 * 1024 * 1024,
        .buff_cache = 4 * 1024 * 1024 * 1024, // 4 GiB combined
        .available = 12 * 1024 * 1024 * 1024,
        .swap_total = 0,
        .swap_used = 0,
        .swap_free = 0,
    };

    try printReport(&stdout_aw.writer, info, .kibi, false, false, true, .{});

    const output = stdout_aw.writer.buffered();
    // In wide mode, the Mem: row has 7 numeric columns:
    // total, used, free, shared, buffers, cache, available
    // Find the Mem: line
    const mem_line_start = std.mem.find(u8, output, "Mem:") orelse
        return error.TestExpectedEqual;
    const mem_line_end = std.mem.findScalarPos(u8, output, mem_line_start, '\n') orelse output.len;
    const mem_line = output[mem_line_start..mem_line_end];

    // Parse numeric values from the Mem: line
    // Skip "Mem:" label, then extract whitespace-separated numbers
    var values: [7]u64 = undefined;
    var val_count: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, mem_line, ' ');
    _ = iter.next(); // skip "Mem:"
    while (iter.next()) |token| {
        if (val_count < 7) {
            values[val_count] = std.fmt.parseInt(u64, token, 10) catch continue;
            val_count += 1;
        }
    }

    // We should have 7 values
    try testing.expectEqual(@as(usize, 7), val_count);

    // values[4] is the buffers column — should be nonzero when
    // buff_cache is nonzero, since buffers is a component of it
    // Currently fails because buffers is hardcoded to 0
    try testing.expect(values[4] > 0);
}

// procps `free -c N` does NOT require -s: it repeats N times with an
// implied one-second interval. Verified on Ubuntu with procps-ng 4.0.4,
// `LC_ALL=C /usr/bin/free -c 3`: three reports separated by a blank line,
// exit 0, two seconds of wall clock (N-1 sleeps).
test "free -c N without -s repeats N times with an implied 1s interval" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Two repeats costs one second of sleep; three would cost two.
    const args = [_][]const u8{ "-c", "2" };
    const start = std.Io.Timestamp.now(io, .awake);
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    const elapsed_ns = start.untilNow(io, .awake).nanoseconds;

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());

    const output = stdout_aw.writer.buffered();
    // Exactly two reports, each with its own Mem: and Swap: row.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "Mem:"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "Swap:"));
    // procps separates reports with one blank line and emits no trailing one.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\n\n"));
    try testing.expect(!std.mem.endsWith(u8, output, "\n\n"));
    try testing.expect(std.mem.endsWith(u8, output, "\n"));
    // The implied interval is one second, so two reports must span at
    // least one sleep. Without it the whole run takes microseconds.
    try testing.expect(elapsed_ns >= 900 * std.time.ns_per_ms);
}

// procps prints the single report immediately for -c 1 and exits without
// sleeping: `time /usr/bin/free -c 1` measured 0.001s real, versus 1.001s
// for -c 2. The interval is only paid BETWEEN reports.
test "free -c 1 prints one report and exits without sleeping" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", "1" };
    const start = std.Io.Timestamp.now(io, .awake);
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    const elapsed_ns = start.untilNow(io, .awake).nanoseconds;

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());

    const output = stdout_aw.writer.buffered();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "Mem:"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "\n\n"));
    // A trailing sleep would push this past a second; allow generous slack
    // for a loaded CI runner but stay far below the one-second interval.
    try testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
}

// The help text must not repeat the retired "-c requires -s" constraint.
// procps documents the flag as " -c N, --count N  repeat printing N times,
// then exit" with no mention of -s.
test "free --help does not tie -c to -s" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const help = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, help, "--count") != null);
    try testing.expect(std.mem.find(u8, help, "used with -s") == null);
    try testing.expect(std.mem.find(u8, help, "requires -s") == null);
}

// IMPORTANT: -s short flag is hijacked by the si bool field
// The argparse getShortFlag maps "si" -> 's' (first char), so -s
// sets si=true instead of being parsed as --seconds. This means
// `free -s 1` sets SI mode and treats "1" as a positional (error).
// Expected: -s 1 should set seconds=1 for continuous display.
test "audit: free -s should set seconds not si" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // free -s 1 -c 1 should run continuous mode (1 second, 1 count)
    // and succeed. With the bug, -s sets si=true, "1" becomes a
    // positional, and we get "extra operand '1'" (exit 1).
    const args = [_][]const u8{ "-s", "1", "-c", "1" };
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (exit 0) — continuous mode with 1-second interval, 1 count
    try testing.expectEqual(@as(u8, 0), result);
    // Should produce output (at least one display)
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Mem:") != null);
}

// ========== Color bands and usage bar (RED until implemented) ==========

const sgr_green = "\x1b[32m";
const sgr_yellow = "\x1b[33m";
const sgr_red = "\x1b[31m";
const sgr_reset = "\x1b[0m";
const bar_filled = "\xe2\x96\x88";
const bar_empty = "\xe2\x96\x91";

fn memInfoBytes(used: u64, total: u64, swap_used: u64, swap_total: u64) MemInfo {
    std.debug.assert(used <= total);
    std.debug.assert(swap_used <= swap_total);
    return .{
        .total = total,
        .used = used,
        .free = total - used,
        .shared = 0,
        .buff_cache = 0,
        .available = total - used,
        .swap_total = swap_total,
        .swap_used = swap_used,
        .swap_free = swap_total - swap_used,
    };
}

fn linePrefixed(output: []const u8, prefix: []const u8) []const u8 {
    const start = std.mem.find(u8, output, prefix) orelse return &.{};
    const end = std.mem.findScalarPos(u8, output, start, '\n') orelse output.len;
    return output[start..end];
}

fn writeBytesReport(
    writer: *std.Io.Writer,
    used: u64,
    total: u64,
    swap_used: u64,
    swap_total: u64,
    render: RenderOptions,
) !void {
    std.debug.assert(used <= total);
    std.debug.assert(swap_used <= swap_total);
    try printReport(
        writer,
        memInfoBytes(used, total, swap_used, swap_total),
        .bytes,
        false,
        false,
        false,
        render,
    );
}

fn expectUsedBand(used: u64, total: u64, sgr: []const u8) !void {
    std.debug.assert(sgr.len != 0);
    std.debug.assert(total != 0);
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    try writeBytesReport(&stdout_aw.writer, used, total, 0, 0, .{ .color = true });
    const output = stdout_aw.writer.buffered();
    const mem_line = linePrefixed(output, "Mem:");
    try testing.expect(std.mem.find(u8, mem_line, sgr) != null);
    try testing.expect(std.mem.find(u8, mem_line, sgr_reset) != null);

    var total_buf: [32]u8 = undefined;
    const total_s = std.fmt.bufPrint(&total_buf, "{d}", .{total}) catch unreachable;
    const total_at = std.mem.find(u8, mem_line, total_s) orelse return error.TestExpectedEqual;
    const csi_at = std.mem.find(u8, mem_line, sgr) orelse return error.TestExpectedEqual;
    try testing.expect(total_at < csi_at);

    const header_end = std.mem.find(u8, output, "\n") orelse output.len;
    try testing.expect(std.mem.find(u8, output[0..header_end], "\x1b") == null);
}

fn stageXtermNoColorUnset() [3]common.env.Override {
    return .{
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "TERM", .value = "xterm" },
        .{ .key = "COLORTERM", .value = null },
    };
}

test "free colors used-percent green below 70" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    try expectUsedBand(50, 100, sgr_green);
    try expectUsedBand(69, 100, sgr_green);
}

test "free colors used-percent yellow from 70" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    try expectUsedBand(70, 100, sgr_yellow);
    try expectUsedBand(89, 100, sgr_yellow);
}

test "free colors used-percent red at 90" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    try expectUsedBand(90, 100, sgr_red);
    try expectUsedBand(100, 100, sgr_red);
}

test "free auto emits no color when render.color is off" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "COLORTERM", .value = null },
    };
    common.env.test_overrides = &staged;

    var off_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer off_aw.deinit();
    try writeBytesReport(&off_aw.writer, 50, 100, 0, 0, .{});
    const off_out = off_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, off_out, "\x1b") == null);
    try testing.expect(std.mem.find(u8, off_out, "Mem:") != null);

    var on_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer on_aw.deinit();
    try writeBytesReport(&on_aw.writer, 50, 100, 0, 0, .{ .color = true });
    const on_out = on_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, on_out, "\x1b") != null);
    try testing.expect(std.mem.find(u8, on_out, "Mem:") != null);
}

test "free auto emits color when render.color is on" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    try writeBytesReport(&stdout_aw.writer, 50, 100, 0, 0, .{ .color = true });
    const mem_line = linePrefixed(stdout_aw.writer.buffered(), "Mem:");
    try testing.expect(std.mem.find(u8, mem_line, sgr_green) != null);
    const total_at = std.mem.find(u8, mem_line, "100") orelse return error.TestExpectedEqual;
    const csi_at = std.mem.find(u8, mem_line, sgr_green) orelse return error.TestExpectedEqual;
    try testing.expect(total_at < csi_at);
}

test "free emits no color when NO_COLOR is set even with --color=always" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "NO_COLOR", .value = "1" },
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "COLORTERM", .value = null },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--color=always"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "\x1b") == null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Mem:") != null);
}

test "free emits no color when TERM is dumb even with --color=always" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "TERM", .value = "dumb" },
        .{ .key = "COLORTERM", .value = null },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--color=always"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "\x1b") == null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Mem:") != null);
}

test "free --color=never emits no color" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--color=never"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "\x1b") == null);
}

test "free --color=bogus exits 1" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--color=bogus"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid") != null);
}

test "free --bar=bogus exits 1" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--bar=bogus"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid") != null);
}

test "free --color= empty WHEN exits 1" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--color="},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid") != null);
}

test "free --bar= empty WHEN exits 1" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--bar="},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid") != null);
}

test "free --bar=always prints a 10-cell usage bar and percent" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    const Case = struct {
        used: u64,
        total: u64,
        filled: usize,
        empty: usize,
        pct: []const u8,
    };
    const cases = [_]Case{
        .{ .used = 0, .total = 100, .filled = 0, .empty = 10, .pct = "0%" },
        .{ .used = 1, .total = 200, .filled = 1, .empty = 9, .pct = "1%" },
        .{ .used = 50, .total = 100, .filled = 5, .empty = 5, .pct = "50%" },
        .{ .used = 100, .total = 100, .filled = 10, .empty = 0, .pct = "100%" },
    };
    for (cases) |tc| {
        var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_aw.deinit();
        try writeBytesReport(
            &stdout_aw.writer,
            tc.used,
            tc.total,
            0,
            0,
            .{ .bar = .always },
        );
        const mem_line = linePrefixed(stdout_aw.writer.buffered(), "Mem:");
        try testing.expectEqual(tc.filled, std.mem.count(u8, mem_line, bar_filled));
        try testing.expectEqual(tc.empty, std.mem.count(u8, mem_line, bar_empty));
        try testing.expect(std.mem.find(u8, mem_line, tc.pct) != null);
        try testing.expectEqual(@as(usize, 10), tc.filled + tc.empty);
    }

    // used=1,total=200 ceilings to 1%, not a floored 0%.
    var ceil_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer ceil_aw.deinit();
    try writeBytesReport(&ceil_aw.writer, 1, 200, 0, 0, .{ .bar = .always });
    const ceil_mem = linePrefixed(ceil_aw.writer.buffered(), "Mem:");
    try testing.expect(std.mem.find(u8, ceil_mem, "1%") != null);
    try testing.expect(std.mem.find(u8, ceil_mem, "0%") == null);

    var color_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer color_aw.deinit();
    try writeBytesReport(
        &color_aw.writer,
        50,
        100,
        0,
        0,
        .{ .color = true, .bar = .always },
    );
    const color_mem = linePrefixed(color_aw.writer.buffered(), "Mem:");
    const glyph_at = std.mem.find(u8, color_mem, bar_filled) orelse return error.TestExpectedEqual;
    const csi_at = std.mem.find(u8, color_mem, sgr_green) orelse return error.TestExpectedEqual;
    try testing.expect(csi_at < glyph_at);
    try testing.expect(std.mem.find(u8, color_mem[glyph_at..], sgr_reset) != null);
}

test "free --bar=never omits bar glyphs" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--bar=never"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, bar_filled) == null);
    try testing.expect(std.mem.find(u8, output, bar_empty) == null);
}

test "free --bar=auto with icons off omits the bar" {
    var off_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer off_aw.deinit();
    try writeBytesReport(
        &off_aw.writer,
        50,
        100,
        0,
        0,
        .{ .bar = .auto, .icons = .off },
    );
    const off_out = off_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, off_out, bar_filled) == null);
    try testing.expect(std.mem.find(u8, off_out, bar_empty) == null);

    var on_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer on_aw.deinit();
    try writeBytesReport(
        &on_aw.writer,
        50,
        100,
        0,
        0,
        .{ .bar = .auto, .icons = .on },
    );
    const on_mem = linePrefixed(on_aw.writer.buffered(), "Mem:");
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, on_mem, bar_filled));
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, on_mem, bar_empty));
}

test "free swap row uses swap_used/swap_total and zero swap is 0 percent" {
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = stageXtermNoColorUnset();
    common.env.test_overrides = &staged;

    var zero_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer zero_aw.deinit();
    try writeBytesReport(
        &zero_aw.writer,
        50,
        100,
        0,
        0,
        .{ .color = true, .bar = .always },
    );
    const zero_swap = linePrefixed(zero_aw.writer.buffered(), "Swap:");
    try testing.expect(std.mem.find(u8, zero_swap, "Swap:") != null);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, zero_swap, bar_filled));
    try testing.expectEqual(@as(usize, 10), std.mem.count(u8, zero_swap, bar_empty));
    try testing.expect(std.mem.find(u8, zero_swap, "0%") != null);
    try testing.expect(std.mem.find(u8, zero_swap, sgr_green) != null);

    var red_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer red_aw.deinit();
    try writeBytesReport(
        &red_aw.writer,
        50,
        100,
        90,
        100,
        .{ .color = true, .bar = .always },
    );
    const red_mem = linePrefixed(red_aw.writer.buffered(), "Mem:");
    const red_swap = linePrefixed(red_aw.writer.buffered(), "Swap:");
    try testing.expect(std.mem.find(u8, red_mem, sgr_green) != null);
    try testing.expect(std.mem.find(u8, red_swap, sgr_red) != null);
    try testing.expectEqual(@as(usize, 9), std.mem.count(u8, red_swap, bar_filled));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, red_swap, bar_empty));
}

test "free --help lists --color=WHEN and --bar=WHEN" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const result = try runFree(
        testing.allocator,
        testing.io,
        &.{"--help"},
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    const help = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, help, "--color=WHEN") != null);
    try testing.expect(std.mem.find(u8, help, "--bar=WHEN") != null);
}
