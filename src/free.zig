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

const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_host.h");
    @cInclude("unistd.h");
});

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
pub fn getMemInfo() !MemInfo {
    return switch (@import("builtin").os.tag) {
        .macos => getMemInfoMacOS(),
        .linux => getMemInfoLinux(),
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

    // VM statistics via host_statistics64
    var vm_stat: c.vm_statistics64_data_t = undefined;
    var count: c.mach_msg_type_number_t = @intCast(@divExact(@sizeOf(c.vm_statistics64_data_t), @sizeOf(c.natural_t)));
    const host_ret = c.host_statistics64(
        c.mach_host_self(),
        c.HOST_VM_INFO64,
        @ptrCast(&vm_stat),
        &count,
    );
    if (host_ret != c.KERN_SUCCESS) return error.HostStatisticsFailed;

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

fn getMemInfoLinux() !MemInfo {
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch
        return error.ProcMeminfoNotFound;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return error.ReadFailed;
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
    const rest = std.mem.trimLeft(u8, line[prefix.len..], " ");
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
        .si = .{ .desc = "Use powers of 1000 instead of 1024" },
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
    const divisor: u64 = if (use_si) 1000 else 1024;
    const suffixes = if (use_si)
        [_][]const u8{ "B", "kB", "MB", "GB", "TB" }
    else
        [_][]const u8{ "B", "Ki", "Mi", "Gi", "Ti" };

    var value = bytes;
    var suffix_idx: usize = 0;

    while (value >= divisor and suffix_idx + 1 < suffixes.len) {
        value = @divTrunc(value, divisor);
        suffix_idx += 1;
    }

    const result = std.fmt.bufPrint(buf, "{d}{s}", .{ value, suffixes[suffix_idx] }) catch
        return "?";
    return result;
}

/// Column width for numeric values
const col_width = 12;

/// Print the header line
fn printHeader(writer: anytype, wide: bool) !void {
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
fn printValue(writer: anytype, bytes: u64, unit: Unit, use_si: bool) !void {
    if (unit == .human) {
        var buf: [32]u8 = undefined;
        const formatted = formatHumanReadable(&buf, bytes, use_si);
        try writer.print("{s:>12}", .{formatted});
    } else {
        try writer.print("{d:>12}", .{scaleValue(bytes, unit, use_si)});
    }
}

/// Print a memory row (Mem: or Swap: or Total:)
fn printMemRow(writer: anytype, label: []const u8, info: MemInfo, unit: Unit, use_si: bool, wide: bool, is_swap: bool) !void {
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
        // Split buff/cache into buffers and cache
        // On macOS we don't have a clean split, so use 0 and buff_cache
        try printValue(writer, 0, unit, use_si);
        try printValue(writer, info.buff_cache, unit, use_si);
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
fn printTotalRow(writer: anytype, info: MemInfo, unit: Unit, use_si: bool, wide: bool) !void {
    const total_total = info.total + info.swap_total;
    const total_used = info.used + info.swap_used;
    const total_free = info.free + info.swap_free;

    try writer.print("{s:<6}", .{"Total:"});

    if (wide) {
        try printValue(writer, total_total, unit, use_si);
        try printValue(writer, total_used, unit, use_si);
        try printValue(writer, total_free, unit, use_si);
        try printValue(writer, info.shared, unit, use_si);
        try printValue(writer, 0, unit, use_si);
        try printValue(writer, info.buff_cache, unit, use_si);
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
pub fn printReport(writer: anytype, info: MemInfo, unit: Unit, use_si: bool, show_total: bool, wide: bool) !void {
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

pub fn runFree(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) u8 {
    const parsed = common.argparse.ArgParser.parse(FreeArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "argument parsing error", .{});
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
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "extra operand '{s}'", .{parsed.positionals[0]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const unit = resolveUnit(parsed);
    const use_si = parsed.si;
    const show_total = parsed.total;
    const wide = parsed.wide;

    const repeat_count = parsed.count orelse 0;
    const interval = parsed.seconds orelse 0;

    // If -c is given without -s, treat as a single display
    if (interval == 0) {
        return displayOnce(stdout_writer, stderr_writer, allocator, unit, use_si, show_total, wide);
    }

    // Continuous mode
    var iterations: u32 = 0;
    while (repeat_count == 0 or iterations < repeat_count) {
        const result = displayOnce(stdout_writer, stderr_writer, allocator, unit, use_si, show_total, wide);
        if (result != 0) return result;
        if (comptime std.meta.hasMethod(@TypeOf(stdout_writer), "flush")) {
            stdout_writer.flush() catch {};
        }

        iterations += 1;
        if (repeat_count > 0 and iterations >= repeat_count) break;

        std.Thread.sleep(@as(u64, interval) * std.time.ns_per_s);

        // Print blank line between iterations
        stdout_writer.writeAll("\n") catch {};
    }

    return @intFromEnum(common.ExitCode.success);
}

fn displayOnce(stdout_writer: anytype, stderr_writer: anytype, allocator: Allocator, unit: Unit, use_si: bool, show_total: bool, wide: bool) u8 {
    const info = getMemInfo() catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "failed to read memory information", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };

    printReport(stdout_writer, info, unit, use_si, show_total, wide) catch {
        return @intFromEnum(common.ExitCode.general_error);
    };

    return @intFromEnum(common.ExitCode.success);
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

    const exit_code = runFree(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) std.process.exit(exit_code);
}

fn printHelp(allocator: Allocator, writer: anytype) void {
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

fn printVersion(writer: anytype) void {
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
    try testing.expectEqualStrings("0B", formatHumanReadable(&buf, 0, false));
}

test "formatHumanReadable kibi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 2048, false);
    try testing.expectEqualStrings("2Ki", result);
}

test "formatHumanReadable mebi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 8 * 1024 * 1024, false);
    try testing.expectEqualStrings("8Mi", result);
}

test "formatHumanReadable gibi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 4 * 1024 * 1024 * 1024, false);
    try testing.expectEqualStrings("4Gi", result);
}

test "formatHumanReadable si mode" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 5000, true);
    try testing.expectEqualStrings("5kB", result);
}

test "formatHumanReadable si mebi" {
    var buf: [32]u8 = undefined;
    const result = formatHumanReadable(&buf, 3 * 1000 * 1000, true);
    try testing.expectEqualStrings("3MB", result);
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
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

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

    try printReport(stdout_buf.writer(testing.allocator), info, .kibi, false, false, false);

    const output = stdout_buf.items;
    // Should contain header and two data lines
    try testing.expect(std.mem.indexOf(u8, output, "total") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Mem:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Swap:") != null);
}

test "printReport with total line" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

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

    try printReport(stdout_buf.writer(testing.allocator), info, .kibi, false, true, false);

    const output = stdout_buf.items;
    try testing.expect(std.mem.indexOf(u8, output, "Total:") != null);
}

test "printReport wide mode" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

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

    try printReport(stdout_buf.writer(testing.allocator), info, .kibi, false, false, true);

    const output = stdout_buf.items;
    try testing.expect(std.mem.indexOf(u8, output, "buffers") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache") != null);
}

test "printReport human readable" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

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

    try printReport(stdout_buf.writer(testing.allocator), info, .human, false, false, false);

    const output = stdout_buf.items;
    try testing.expect(std.mem.indexOf(u8, output, "Gi") != null);
}

test "runFree help flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage: free") != null);
    try testing.expectEqualStrings("", stderr_buf.items);
}

test "runFree version flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "free") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, common.name) != null);
    try testing.expectEqualStrings("", stderr_buf.items);
}

test "runFree unknown flag returns misuse" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_buf.items);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "free:") != null);
}

test "runFree extra arguments returns misuse" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"extra"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "extra operand") != null);
}

test "runFree default output" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Mem:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Swap:") != null);
    try testing.expectEqualStrings("", stderr_buf.items);
}

test "runFree bytes flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-b"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buf.items.len > 0);
}

test "runFree mebi flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-m"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buf.items.len > 0);
}

test "runFree gibi flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-g"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buf.items.len > 0);
}

test "runFree human flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-h"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buf.items.len > 0);
}

test "runFree total flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-t"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Total:") != null);
}

test "runFree wide flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-w"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "buffers") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "cache") != null);
}

test "runFree short version flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = runFree(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "free") != null);
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
    const info = getMemInfo() catch return;
    // Total memory should be positive
    try testing.expect(info.total > 0);
    // Used + free should not exceed total (approximately)
    try testing.expect(info.used <= info.total);
}
