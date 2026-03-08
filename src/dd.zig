//! dd - convert and copy a file
//!
//! Copy a file, converting and formatting according to the operands.
//! Supports block size specification, input/output skipping, case
//! conversion, and transfer statistics.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// dd operand configuration parsed from command-line arguments
const DdConfig = struct {
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    ibs: usize = 512,
    obs: usize = 512,
    bs: ?usize = null,
    count: ?usize = null,
    skip: usize = 0,
    seek: usize = 0,
    conv_lcase: bool = false,
    conv_ucase: bool = false,
    conv_notrunc: bool = false,
    conv_noerror: bool = false,
    conv_sync: bool = false,
    status: StatusLevel = .default,
    help: bool = false,
    version: bool = false,
};

const StatusLevel = enum {
    default,
    none,
    noxfer,
    progress,
};

/// Statistics tracked during the copy operation
const DdStats = struct {
    full_blocks_in: usize = 0,
    partial_blocks_in: usize = 0,
    full_blocks_out: usize = 0,
    partial_blocks_out: usize = 0,
    bytes_copied: usize = 0,
    start_ns: i128 = 0,
};

/// Parse a byte size value with optional suffix.
/// Supports: c=1, w=2, b=512, k/K=1024, M=1048576, G=1073741824
/// Also supports multiplication with 'x' (e.g., "1024x1024").
fn parseByteSize(s: []const u8) !usize {
    if (s.len == 0) return error.InvalidValue;

    // Handle multiplication: split on 'x' and multiply parts
    var result: usize = 1;
    var iter = std.mem.splitScalar(u8, s, 'x');
    var has_parts = false;
    while (iter.next()) |part| {
        if (part.len == 0) return error.InvalidValue;
        has_parts = true;
        const val = parseSingleSize(part) catch return error.InvalidValue;
        result = std.math.mul(usize, result, val) catch return error.InvalidValue;
    }
    if (!has_parts) return error.InvalidValue;
    return result;
}

/// Parse a single size token (number with optional suffix)
fn parseSingleSize(s: []const u8) !usize {
    if (s.len == 0) return error.InvalidValue;

    // Find where the numeric part ends
    var num_end: usize = 0;
    while (num_end < s.len and s[num_end] >= '0' and s[num_end] <= '9') : (num_end += 1) {}

    if (num_end == 0) return error.InvalidValue;

    const num = std.fmt.parseInt(usize, s[0..num_end], 10) catch return error.InvalidValue;
    const suffix = s[num_end..];

    if (suffix.len == 0) return num;

    const multiplier: usize = switch (suffix[0]) {
        'c' => 1,
        'w' => 2,
        'b' => 512,
        'k', 'K' => 1024,
        'M' => 1048576,
        'G' => 1073741824,
        else => return error.InvalidValue,
    };

    if (suffix.len > 1) return error.InvalidValue;

    return std.math.mul(usize, num, multiplier) catch return error.InvalidValue;
}

/// Parse dd operands from command-line arguments.
/// dd uses operand=value syntax instead of flags.
fn parseOperands(args: []const []const u8) !DdConfig {
    var config = DdConfig{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            config.help = true;
            return config;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            config.version = true;
            return config;
        }

        // Parse operand=value
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const key = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "if")) {
                config.input_file = value;
            } else if (std.mem.eql(u8, key, "of")) {
                config.output_file = value;
            } else if (std.mem.eql(u8, key, "bs")) {
                config.bs = try parseByteSize(value);
            } else if (std.mem.eql(u8, key, "ibs")) {
                config.ibs = try parseByteSize(value);
            } else if (std.mem.eql(u8, key, "obs")) {
                config.obs = try parseByteSize(value);
            } else if (std.mem.eql(u8, key, "count")) {
                config.count = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "skip")) {
                config.skip = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "seek")) {
                config.seek = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "conv")) {
                try parseConversions(&config, value);
            } else if (std.mem.eql(u8, key, "status")) {
                if (std.mem.eql(u8, value, "none")) {
                    config.status = .none;
                } else if (std.mem.eql(u8, value, "noxfer")) {
                    config.status = .noxfer;
                } else if (std.mem.eql(u8, value, "progress")) {
                    config.status = .progress;
                } else {
                    return error.InvalidValue;
                }
            } else {
                return error.UnknownOperand;
            }
        } else {
            return error.UnknownOperand;
        }
    }

    return config;
}

/// Parse comma-separated conversion options
fn parseConversions(config: *DdConfig, value: []const u8) !void {
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |conv| {
        if (conv.len == 0) continue;
        if (std.mem.eql(u8, conv, "lcase")) {
            config.conv_lcase = true;
        } else if (std.mem.eql(u8, conv, "ucase")) {
            config.conv_ucase = true;
        } else if (std.mem.eql(u8, conv, "notrunc")) {
            config.conv_notrunc = true;
        } else if (std.mem.eql(u8, conv, "noerror")) {
            config.conv_noerror = true;
        } else if (std.mem.eql(u8, conv, "sync")) {
            config.conv_sync = true;
        } else {
            return error.InvalidValue;
        }
    }
}

/// Apply case conversion to a buffer in-place
fn applyConversions(buf: []u8, config: DdConfig) void {
    if (config.conv_lcase) {
        for (buf) |*c| {
            if (c.* >= 'A' and c.* <= 'Z') {
                c.* = c.* - 'A' + 'a';
            }
        }
    } else if (config.conv_ucase) {
        for (buf) |*c| {
            if (c.* >= 'a' and c.* <= 'z') {
                c.* = c.* - 'a' + 'A';
            }
        }
    }
}

/// Format a byte count as a human-readable string (e.g., "1.5 MB, 1.4 MiB")
fn formatByteCount(buf: []u8, bytes: usize) []const u8 {
    const fb: f64 = @floatFromInt(bytes);
    if (bytes >= 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1} GB, {d:.1} GiB", .{
            fb / 1_000_000_000.0,
            fb / 1_073_741_824.0,
        }) catch "?";
    } else if (bytes >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1} MB, {d:.1} MiB", .{
            fb / 1_000_000.0,
            fb / 1_048_576.0,
        }) catch "?";
    } else if (bytes >= 1000) {
        return std.fmt.bufPrint(buf, "{d:.1} kB, {d:.1} KiB", .{
            fb / 1000.0,
            fb / 1024.0,
        }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "?";
    }
}

/// Print transfer statistics to stderr
fn printStats(stderr: anytype, stats: DdStats, status: StatusLevel) void {
    if (status == .none) return;

    stderr.print("{d}+{d} records in\n", .{
        stats.full_blocks_in,
        stats.partial_blocks_in,
    }) catch {};
    stderr.print("{d}+{d} records out\n", .{
        stats.full_blocks_out,
        stats.partial_blocks_out,
    }) catch {};

    if (status == .noxfer) return;

    const elapsed_ns = std.time.nanoTimestamp() - stats.start_ns;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const elapsed_display = if (elapsed_s < 0.0001) 0.0001 else elapsed_s;

    var size_buf: [128]u8 = undefined;
    const size_str = formatByteCount(&size_buf, stats.bytes_copied);

    const fb: f64 = @floatFromInt(stats.bytes_copied);
    const rate = fb / elapsed_display;

    var rate_buf: [64]u8 = undefined;
    const rate_str = if (rate >= 1_000_000_000.0)
        std.fmt.bufPrint(&rate_buf, "{d:.1} GB/s", .{rate / 1_000_000_000.0}) catch "?"
    else if (rate >= 1_000_000.0)
        std.fmt.bufPrint(&rate_buf, "{d:.1} MB/s", .{rate / 1_000_000.0}) catch "?"
    else if (rate >= 1000.0)
        std.fmt.bufPrint(&rate_buf, "{d:.1} kB/s", .{rate / 1000.0}) catch "?"
    else
        std.fmt.bufPrint(&rate_buf, "{d:.0} bytes/s", .{rate}) catch "?";

    stderr.print("{d} bytes ({s}) copied, {d:.4} s, {s}\n", .{
        stats.bytes_copied,
        size_str,
        elapsed_display,
        rate_str,
    }) catch {};
}

fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: dd [OPERAND]...
        \\  or:  dd --help
        \\  or:  dd --version
        \\
        \\Copy a file, converting and formatting according to the operands.
        \\
        \\  if=FILE         read from FILE instead of stdin
        \\  of=FILE         write to FILE instead of stdout
        \\  bs=BYTES        read and write up to BYTES bytes at a time
        \\  ibs=BYTES       read up to BYTES bytes at a time (default: 512)
        \\  obs=BYTES       write BYTES bytes at a time (default: 512)
        \\  count=N         copy only N input blocks
        \\  skip=N          skip N ibs-sized blocks at start of input
        \\  seek=N          skip N obs-sized blocks at start of output
        \\  conv=CONVS      convert the file as per the comma-separated list
        \\  status=LEVEL    transfer information to print to stderr;
        \\                  LEVEL is one of: none, noxfer, progress
        \\      --help      display this help and exit
        \\      --version   output version information and exit
        \\
        \\BYTES may be followed by a suffix:
        \\  c=1, w=2, b=512, k=K=1024, M=1048576, G=1073741824
        \\Sizes may also use 'x' for multiplication (e.g., 1024x1024).
        \\
        \\CONVS is a comma-separated list of:
        \\  lcase     convert uppercase to lowercase
        \\  ucase     convert lowercase to uppercase
        \\  notrunc   do not truncate the output file
        \\  noerror   continue after read errors
        \\  sync      pad input blocks with NULs to ibs size
        \\
        \\Examples:
        \\  dd if=input.bin of=output.bin bs=1M
        \\  dd if=/dev/zero of=file.img bs=1024 count=1024
        \\  dd if=file.txt conv=ucase
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("dd ({s}) {s}\n", .{ common.name, common.version });
}

/// Execute the dd copy operation
pub fn runDd(allocator: Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) u8 {
    const config = parseOperands(args) catch |err| {
        switch (err) {
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "invalid operand value", .{});
            },
            error.UnknownOperand => {
                common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "unrecognized operand", .{});
            },
        }
        return @intFromEnum(common.ExitCode.misuse);
    };

    if (config.help) {
        printHelp(allocator, stdout) catch {};
        return @intFromEnum(common.ExitCode.success);
    }

    if (config.version) {
        printVersion(stdout) catch {};
        return @intFromEnum(common.ExitCode.success);
    }

    // lcase and ucase are mutually exclusive
    if (config.conv_lcase and config.conv_ucase) {
        common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "conv=lcase and conv=ucase are mutually exclusive", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Determine effective block sizes
    const ibs = if (config.bs) |bs| bs else config.ibs;
    const obs = if (config.bs) |bs| bs else config.obs;

    if (ibs == 0 or obs == 0) {
        common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "block size cannot be zero", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Allocate input and output buffers
    const in_buf = allocator.alloc(u8, ibs) catch {
        common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "failed to allocate input buffer", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(in_buf);

    const out_buf = allocator.alloc(u8, obs) catch {
        common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "failed to allocate output buffer", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(out_buf);

    // Open input
    const input_file: std.fs.File = if (config.input_file) |path| blk: {
        break :blk std.fs.cwd().openFile(path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "{s}: {s}", .{ path, @errorName(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
    } else std.fs.File.stdin();
    defer if (config.input_file != null) input_file.close();

    // Open output
    const output_file: std.fs.File = if (config.output_file) |path| blk: {
        const flags: std.fs.File.CreateFlags = .{
            .truncate = !config.conv_notrunc,
        };
        break :blk std.fs.cwd().createFile(path, flags) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "{s}: {s}", .{ path, @errorName(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
    } else std.fs.File.stdout();
    defer if (config.output_file != null) output_file.close();

    // Skip input blocks
    if (config.skip > 0) {
        var skipped: usize = 0;
        while (skipped < config.skip) : (skipped += 1) {
            const bytes_read = input_file.read(in_buf) catch |err| {
                common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "error skipping input: {s}", .{@errorName(err)});
                return @intFromEnum(common.ExitCode.general_error);
            };
            if (bytes_read == 0) break; // EOF before all skips done
        }
    }

    // Seek output blocks
    if (config.seek > 0) {
        const seek_bytes = config.seek * obs;
        output_file.seekTo(seek_bytes) catch {
            // If seeking fails (e.g., stdout), try writing zeros
            var seeked: usize = 0;
            @memset(out_buf, 0);
            while (seeked < config.seek) : (seeked += 1) {
                output_file.writeAll(out_buf) catch |write_err| {
                    common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "error seeking output: {s}", .{@errorName(write_err)});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            }
        };
    }

    var stats = DdStats{
        .start_ns = std.time.nanoTimestamp(),
    };

    // Use simple copy mode when bs= is set (no ibs/obs buffering difference)
    const simple_copy = config.bs != null;

    // Main copy loop
    var out_pos: usize = 0; // Current position in output buffer (for non-simple mode)
    var blocks_read: usize = 0;

    while (true) {
        // Check count limit
        if (config.count) |count| {
            if (blocks_read >= count) break;
        }

        // Read one input block
        const bytes_read = input_file.read(in_buf) catch |err| {
            if (config.conv_noerror) {
                // Continue after read errors
                common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "read error: {s}", .{@errorName(err)});
                if (config.conv_sync) {
                    // Fill with NULs when sync is specified
                    @memset(in_buf, 0);
                    // Count as a full block
                    stats.full_blocks_in += 1;
                    blocks_read += 1;
                    if (simple_copy) {
                        // Write the NUL-filled block
                        output_file.writeAll(in_buf) catch |werr| {
                            common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "write error: {s}", .{@errorName(werr)});
                            return @intFromEnum(common.ExitCode.general_error);
                        };
                        stats.full_blocks_out += 1;
                        stats.bytes_copied += ibs;
                    }
                }
                continue;
            }
            common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "read error: {s}", .{@errorName(err)});
            printStats(stderr, stats, config.status);
            return @intFromEnum(common.ExitCode.general_error);
        };

        if (bytes_read == 0) break; // EOF

        blocks_read += 1;

        // Track input block statistics
        if (bytes_read == ibs) {
            stats.full_blocks_in += 1;
        } else {
            stats.partial_blocks_in += 1;
        }

        // Get the data to process
        var data = in_buf[0..bytes_read];

        // Apply sync padding if needed
        if (config.conv_sync and bytes_read < ibs) {
            @memset(in_buf[bytes_read..], 0);
            data = in_buf[0..ibs];
        }

        // Apply conversions
        applyConversions(data, config);

        if (simple_copy) {
            // Simple copy: write each input block directly as output
            output_file.writeAll(data) catch |err| {
                common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "write error: {s}", .{@errorName(err)});
                printStats(stderr, stats, config.status);
                return @intFromEnum(common.ExitCode.general_error);
            };
            stats.bytes_copied += data.len;
            if (data.len == obs) {
                stats.full_blocks_out += 1;
            } else {
                stats.partial_blocks_out += 1;
            }
        } else {
            // Buffered copy: accumulate data in output buffer, write when full
            var data_pos: usize = 0;
            while (data_pos < data.len) {
                const space_in_out = obs - out_pos;
                const to_copy = @min(space_in_out, data.len - data_pos);
                @memcpy(out_buf[out_pos..][0..to_copy], data[data_pos..][0..to_copy]);
                out_pos += to_copy;
                data_pos += to_copy;

                if (out_pos == obs) {
                    // Output buffer is full, write it
                    output_file.writeAll(out_buf[0..obs]) catch |err| {
                        common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "write error: {s}", .{@errorName(err)});
                        printStats(stderr, stats, config.status);
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    stats.full_blocks_out += 1;
                    stats.bytes_copied += obs;
                    out_pos = 0;
                }
            }
        }
    }

    // Flush remaining data in output buffer (non-simple mode)
    if (!simple_copy and out_pos > 0) {
        output_file.writeAll(out_buf[0..out_pos]) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", std.fs.File.stderr().isTty(), "write error: {s}", .{@errorName(err)});
            printStats(stderr, stats, config.status);
            return @intFromEnum(common.ExitCode.general_error);
        };
        stats.partial_blocks_out += 1;
        stats.bytes_copied += out_pos;
    }

    // Print statistics
    printStats(stderr, stats, config.status);

    return @intFromEnum(common.ExitCode.success);
}

/// Process files or stdin with dd operands
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

    const exit_code = runDd(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};
    if (exit_code != 0) std.process.exit(exit_code);
}

// ============================================================================
//                              UNIT TESTS
// ============================================================================

test "parseByteSize - plain numbers" {
    try testing.expectEqual(@as(usize, 512), try parseByteSize("512"));
    try testing.expectEqual(@as(usize, 1), try parseByteSize("1"));
    try testing.expectEqual(@as(usize, 0), try parseByteSize("0"));
    try testing.expectEqual(@as(usize, 1000000), try parseByteSize("1000000"));
}

test "parseByteSize - with suffixes" {
    try testing.expectEqual(@as(usize, 1), try parseByteSize("1c"));
    try testing.expectEqual(@as(usize, 2), try parseByteSize("1w"));
    try testing.expectEqual(@as(usize, 512), try parseByteSize("1b"));
    try testing.expectEqual(@as(usize, 1024), try parseByteSize("1k"));
    try testing.expectEqual(@as(usize, 1024), try parseByteSize("1K"));
    try testing.expectEqual(@as(usize, 1048576), try parseByteSize("1M"));
    try testing.expectEqual(@as(usize, 1073741824), try parseByteSize("1G"));
    try testing.expectEqual(@as(usize, 4096), try parseByteSize("4K"));
    try testing.expectEqual(@as(usize, 5120), try parseByteSize("10b"));
}

test "parseByteSize - multiplication with x" {
    try testing.expectEqual(@as(usize, 1048576), try parseByteSize("1024x1024"));
    try testing.expectEqual(@as(usize, 6), try parseByteSize("2x3"));
    try testing.expectEqual(@as(usize, 2048), try parseByteSize("2Kx1"));
    try testing.expectEqual(@as(usize, 2048), try parseByteSize("2x1K"));
}

test "parseByteSize - errors" {
    try testing.expectError(error.InvalidValue, parseByteSize(""));
    try testing.expectError(error.InvalidValue, parseByteSize("abc"));
    try testing.expectError(error.InvalidValue, parseByteSize("1Z"));
    try testing.expectError(error.InvalidValue, parseByteSize("x1"));
}

test "parseOperands - basic operands" {
    const args = [_][]const u8{ "if=input.txt", "of=output.txt", "bs=1024" };
    const config = try parseOperands(&args);
    try testing.expectEqualStrings("input.txt", config.input_file.?);
    try testing.expectEqualStrings("output.txt", config.output_file.?);
    try testing.expectEqual(@as(?usize, 1024), config.bs);
}

test "parseOperands - ibs and obs" {
    const args = [_][]const u8{ "ibs=512", "obs=4096" };
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(usize, 512), config.ibs);
    try testing.expectEqual(@as(usize, 4096), config.obs);
    try testing.expect(config.bs == null);
}

test "parseOperands - count skip seek" {
    const args = [_][]const u8{ "count=10", "skip=5", "seek=3" };
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(?usize, 10), config.count);
    try testing.expectEqual(@as(usize, 5), config.skip);
    try testing.expectEqual(@as(usize, 3), config.seek);
}

test "parseOperands - conversions" {
    const args = [_][]const u8{"conv=lcase,notrunc,sync"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_lcase);
    try testing.expect(!config.conv_ucase);
    try testing.expect(config.conv_notrunc);
    try testing.expect(!config.conv_noerror);
    try testing.expect(config.conv_sync);
}

test "parseOperands - status levels" {
    {
        const args = [_][]const u8{"status=none"};
        const config = try parseOperands(&args);
        try testing.expectEqual(StatusLevel.none, config.status);
    }
    {
        const args = [_][]const u8{"status=noxfer"};
        const config = try parseOperands(&args);
        try testing.expectEqual(StatusLevel.noxfer, config.status);
    }
    {
        const args = [_][]const u8{"status=progress"};
        const config = try parseOperands(&args);
        try testing.expectEqual(StatusLevel.progress, config.status);
    }
}

test "parseOperands - help and version" {
    {
        const args = [_][]const u8{"--help"};
        const config = try parseOperands(&args);
        try testing.expect(config.help);
    }
    {
        const args = [_][]const u8{"--version"};
        const config = try parseOperands(&args);
        try testing.expect(config.version);
    }
}

test "parseOperands - errors" {
    {
        const args = [_][]const u8{"unknown=value"};
        try testing.expectError(error.UnknownOperand, parseOperands(&args));
    }
    {
        const args = [_][]const u8{"status=invalid"};
        try testing.expectError(error.InvalidValue, parseOperands(&args));
    }
    {
        const args = [_][]const u8{"notanoperand"};
        try testing.expectError(error.UnknownOperand, parseOperands(&args));
    }
    {
        const args = [_][]const u8{"conv=invalid"};
        try testing.expectError(error.InvalidValue, parseOperands(&args));
    }
}

test "parseOperands - defaults" {
    const args = [_][]const u8{};
    const config = try parseOperands(&args);
    try testing.expect(config.input_file == null);
    try testing.expect(config.output_file == null);
    try testing.expectEqual(@as(usize, 512), config.ibs);
    try testing.expectEqual(@as(usize, 512), config.obs);
    try testing.expect(config.bs == null);
    try testing.expect(config.count == null);
    try testing.expectEqual(@as(usize, 0), config.skip);
    try testing.expectEqual(@as(usize, 0), config.seek);
    try testing.expect(!config.conv_lcase);
    try testing.expect(!config.conv_ucase);
    try testing.expect(!config.conv_notrunc);
    try testing.expect(!config.conv_noerror);
    try testing.expect(!config.conv_sync);
    try testing.expectEqual(StatusLevel.default, config.status);
}

test "applyConversions - lcase" {
    var buf = "HELLO WORLD 123".*;
    applyConversions(&buf, .{ .conv_lcase = true });
    try testing.expectEqualStrings("hello world 123", &buf);
}

test "applyConversions - ucase" {
    var buf = "hello world 123".*;
    applyConversions(&buf, .{ .conv_ucase = true });
    try testing.expectEqualStrings("HELLO WORLD 123", &buf);
}

test "applyConversions - no conversion" {
    var buf = "Hello World".*;
    applyConversions(&buf, .{});
    try testing.expectEqualStrings("Hello World", &buf);
}

test "formatByteCount - various sizes" {
    var buf: [128]u8 = undefined;
    {
        const result = formatByteCount(&buf, 500);
        try testing.expectEqualStrings("500 bytes", result);
    }
    {
        const result = formatByteCount(&buf, 1500);
        try testing.expectEqualStrings("1.5 kB, 1.5 KiB", result);
    }
    {
        const result = formatByteCount(&buf, 1500000);
        try testing.expectEqualStrings("1.5 MB, 1.4 MiB", result);
    }
    {
        const result = formatByteCount(&buf, 1500000000);
        try testing.expectEqualStrings("1.5 GB, 1.4 GiB", result);
    }
}

test "runDd - help flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const exit_code = runDd(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage: dd") != null);
}

test "runDd - version flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const exit_code = runDd(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "dd (vibeutils)") != null);
}

test "runDd - basic file copy" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "Hello, dd!\n");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);

    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ if_arg, of_arg, "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify output file contents
    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Hello, dd!\n", content);
}

test "runDd - copy with count" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with multiple 512-byte blocks worth of data
    const data = "ABCDEFGHIJ" ** 52; // 520 bytes > 1 block
    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", data);

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // Copy 1 block of 10 bytes
    const args = [_][]const u8{ if_arg, of_arg, "bs=10", "count=1", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 10), content.len);
    try testing.expectEqualStrings("ABCDEFGHIJ", content);
}

test "runDd - copy with conv=ucase" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "hello world");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=ucase", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("HELLO WORLD", content);
}

test "runDd - copy with conv=lcase" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "HELLO WORLD");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=lcase", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "runDd - skip blocks" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "AAAABBBB");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // Skip 1 block of 4 bytes, should get "BBBB"
    const args = [_][]const u8{ if_arg, of_arg, "bs=4", "skip=1", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("BBBB", content);
}

test "runDd - statistics output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "test data");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ if_arg, of_arg };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should contain records in/out
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "records in") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "records out") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "bytes") != null);
}

test "runDd - status=none suppresses output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "test data");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ if_arg, of_arg, "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "runDd - status=noxfer omits transfer line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "test data");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ if_arg, of_arg, "status=noxfer" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should have records but not bytes line
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "records in") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "records out") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "bytes") == null);
}

test "runDd - mutually exclusive lcase and ucase" {
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"conv=lcase,ucase"};
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - nonexistent input file" {
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "if=/nonexistent/path/to/file.txt", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(stderr_buf.items.len > 0);
}

test "runDd - invalid operand" {
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"invalid=operand"};
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - zero block size" {
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"bs=0"};
    const exit_code = runDd(testing.allocator, &args, common.null_writer, stderr_buf.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - different ibs and obs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "ABCDEFGHIJKLMNOP");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // Read 4 bytes at a time, write 8 bytes at a time
    const args = [_][]const u8{ if_arg, of_arg, "ibs=4", "obs=8", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", content);
}

test "runDd - count=0 copies nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "input.txt", "some data");

    const input_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "input.txt");
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "count=0", "status=none" };
    const exit_code = runDd(testing.allocator, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 0), content.len);
}
