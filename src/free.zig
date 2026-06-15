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
        else => error.UnsupportedPlatform,
    };
}

fn getMemInfoMacOS() !MemInfo {
    // Total physical memory via sysctl
    var mem_size: u64 = 0;
    var size: usize = @sizeOf(u64);
    var mib = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    const sysctl_ret = c.sysctl(&mib, 2, &mem_size, &size, null, 0);
    if (sysctl_ret != 0) return error.SysctlFailed;

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
        .seconds = .{ .short = 's', .desc = "Continuous display every N seconds", .value_name = "N" },
        .count = .{ .short = 'c', .desc = "Display N times (used with -s)", .value_name = "N" },
        .help = .{ .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
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

/// Print a memory row (Mem: or Swap: or Total:)
fn printMemRow(writer: *std.Io.Writer, label: []const u8, info: MemInfo, unit: Unit, use_si: bool, wide: bool, is_swap: bool) !void {
    try writer.print("{s:<6}", .{label});

    if (is_swap) {
        try printValue(writer, info.swap_total, unit, use_si);
        try printValue(writer, info.swap_used, unit, use_si);
        try printValue(writer, info.swap_free, unit, use_si);
        try writer.writeAll("\n");
    } else if (wide) {
        try printValue(writer, info.total, unit, use_si);
        try printValue(writer, info.used, unit, use_si);
        try printValue(writer, info.free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        // Split buff/cache into buffers and cache.
        // MemInfo merges these; show buff_cache as buffers, 0 as cache.
        try printValue(writer, info.buff_cache, unit, use_si);
        try printValue(writer, 0, unit, use_si);
        try printValue(writer, info.available, unit, use_si);
        try writer.writeAll("\n");
    } else {
        try printValue(writer, info.total, unit, use_si);
        try printValue(writer, info.used, unit, use_si);
        try printValue(writer, info.free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        try printValue(writer, info.buff_cache, unit, use_si);
        try printValue(writer, info.available, unit, use_si);
        try writer.writeAll("\n");
    }
}

/// Print the total row
fn printTotalRow(writer: *std.Io.Writer, info: MemInfo, unit: Unit, use_si: bool, wide: bool) !void {
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

/// Print a complete memory report for the given MemInfo
pub fn printReport(writer: *std.Io.Writer, info: MemInfo, unit: Unit, use_si: bool, show_total: bool, wide: bool) !void {
    try printHeader(writer, wide);
    try printMemRow(writer, "Mem:", info, unit, use_si, wide, false);
    try printMemRow(writer, "Swap:", info, unit, use_si, wide, true);
    if (show_total) {
        try printTotalRow(writer, info, unit, use_si, wide);
    }
}

// ============================================================================
// Main entry point
// ============================================================================

pub fn runFree(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    const parsed = common.argparse.ArgParser.parse(FreeArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "argument parsing error", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
        }
    };
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.positionals.len > 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "extra operand '{s}'", .{parsed.positionals[0]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const unit = resolveUnit(parsed);
    const use_si = parsed.si;
    const show_total = parsed.total;
    const wide = parsed.wide;

    const repeat_count = parsed.count orelse 0;
    const interval = parsed.seconds orelse 0;

    // Per GNU free: -c requires -s
    if (parsed.count != null and parsed.seconds == null) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "-c requires -s option", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // No continuous mode requested, display once
    if (interval == 0) {
        return displayOnce(io, stdout_writer, stderr_writer, allocator, unit, use_si, show_total, wide);
    }

    // Continuous mode
    var iterations: u32 = 0;
    while (repeat_count == 0 or iterations < repeat_count) {
        const result = displayOnce(io, stdout_writer, stderr_writer, allocator, unit, use_si, show_total, wide);
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

fn displayOnce(io: std.Io, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, allocator: Allocator, unit: Unit, use_si: bool, show_total: bool, wide: bool) u8 {
    const info = getMemInfo(io) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to read memory information", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };

    printReport(stdout_writer, info, unit, use_si, show_total, wide) catch {
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
        \\  -s N, --seconds=N   continuously display every N seconds
        \\  -c N, --count=N     display N times (used with -s)
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

    try printReport(&stdout_aw.writer, info, .kibi, false, false, false);

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

    try printReport(&stdout_aw.writer, info, .kibi, false, true, false);

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

    try printReport(&stdout_aw.writer, info, .kibi, false, false, true);

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

    try printReport(&stdout_aw.writer, info, .human, false, false, false);

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

test "runFree unknown flag returns misuse" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "free:") != null);
}

test "runFree extra arguments returns misuse" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"extra"};
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
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

    try printReport(&stdout_aw.writer, info, .kibi, false, false, true);

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

// IMPORTANT: -c without -s should error (GNU rejects it)
// GNU free: "free: -c requires -s option"
// Currently: -c without -s silently displays once.
// Expected: error exit code 2 with message about -s requirement.
test "audit: free -c without -s should error" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", "3" };
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // GNU exits 2 (misuse) when -c is given without -s
    try testing.expectEqual(@as(u8, 2), result);
    // stderr should mention -s requirement
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "-s") != null);
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
    // positional, and we get "extra operand '1'" (exit 2).
    const args = [_][]const u8{ "-s", "1", "-c", "1" };
    const result = try runFree(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (exit 0) — continuous mode with 1-second interval, 1 count
    try testing.expectEqual(@as(u8, 0), result);
    // Should produce output (at least one display)
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Mem:") != null);
}
