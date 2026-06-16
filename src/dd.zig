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
    conv_fsync: bool = false,
    conv_osync: bool = false,
    conv_swab: bool = false,
    conv_ascii: bool = false,
    conv_ebcdic: bool = false,
    conv_ibm: bool = false,
    conv_block: bool = false,
    conv_unblock: bool = false,
    cbs: ?usize = null,
    fillchar: u8 = ' ',
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
    // Loop condition bounds num_end at s.len; the slices below are in range.
    std.debug.assert(num_end <= s.len);

    if (num_end == 0) return error.InvalidValue;
    // The early return above guarantees at least one digit was consumed.
    std.debug.assert(num_end > 0);

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
            // indexOfScalar returns an index strictly inside arg, so the
            // value slice arg[eq_pos + 1 ..] stays in bounds.
            std.debug.assert(eq_pos < arg.len);
            const key = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];
            std.debug.assert(key.len <= arg.len);
            try parseOperands_applyKeyValue(&config, key, value);
        } else {
            return error.UnknownOperand;
        }
    }

    return config;
}

/// Apply a single parsed operand `key=value` to `config` in place.
/// Straight-line dispatch over the supported operand keys; mirrors the
/// behavior of the original inline if/else-if chain exactly.
fn parseOperands_applyKeyValue(config: *DdConfig, key: []const u8, value: []const u8) !void {
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
        config.count = std.fmt.parseInt(usize, value, 10) catch // tiger:allow:usize-arch byte-count
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "skip")) {
        config.skip = std.fmt.parseInt(usize, value, 10) catch // tiger:allow:usize-arch byte-count
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "seek")) {
        config.seek = std.fmt.parseInt(usize, value, 10) catch // tiger:allow:usize-arch byte-count
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "cbs")) {
        config.cbs = try parseByteSize(value);
    } else if (std.mem.eql(u8, key, "conv")) {
        try parseConversions(config, value);
    } else if (std.mem.eql(u8, key, "iseek")) {
        // Alias for skip
        config.skip = std.fmt.parseInt(usize, value, 10) catch // tiger:allow:usize-arch byte-count
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "oseek")) {
        // Alias for seek
        config.seek = std.fmt.parseInt(usize, value, 10) catch // tiger:allow:usize-arch byte-count
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "fillchar")) {
        if (value.len != 1) return error.InvalidValue;
        config.fillchar = value[0];
    } else if (std.mem.eql(u8, key, "iflag")) {
        // Stub: accept comma-separated input flags, silently ignore
    } else if (std.mem.eql(u8, key, "oflag")) {
        // Stub: accept comma-separated output flags, silently ignore
    } else if (std.mem.eql(u8, key, "speed")) {
        // Stub: accept speed limit, silently ignore
        _ = std.fmt.parseInt(usize, value, 10) catch // tiger:allow:usize-arch byte-count
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "status")) {
        try parseOperands_applyKeyValue_status(config, value);
    } else {
        return error.UnknownOperand;
    }
}

/// Apply a `status=LEVEL` operand to `config`. Split out of
/// parseOperands_applyKeyValue so both helpers stay well within the
/// line budget; behavior is identical to the original inline block.
fn parseOperands_applyKeyValue_status(config: *DdConfig, value: []const u8) !void {
    if (std.mem.eql(u8, value, "none")) {
        config.status = .none;
    } else if (std.mem.eql(u8, value, "noxfer")) {
        config.status = .noxfer;
    } else if (std.mem.eql(u8, value, "progress")) {
        config.status = .progress;
    } else {
        return error.InvalidValue;
    }
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
        } else if (std.mem.eql(u8, conv, "fsync")) {
            config.conv_fsync = true;
        } else if (std.mem.eql(u8, conv, "osync")) {
            config.conv_osync = true;
        } else if (std.mem.eql(u8, conv, "swab")) {
            config.conv_swab = true;
        } else if (std.mem.eql(u8, conv, "ascii")) {
            config.conv_ascii = true;
        } else if (std.mem.eql(u8, conv, "ebcdic")) {
            config.conv_ebcdic = true;
        } else if (std.mem.eql(u8, conv, "ibm")) {
            config.conv_ibm = true;
        } else if (std.mem.eql(u8, conv, "block")) {
            config.conv_block = true;
        } else if (std.mem.eql(u8, conv, "unblock")) {
            config.conv_unblock = true;
        } else if (std.mem.eql(u8, conv, "oldascii")) {
            config.conv_ascii = true;
        } else if (std.mem.eql(u8, conv, "oldebcdic")) {
            config.conv_ebcdic = true;
        } else if (std.mem.eql(u8, conv, "oldibm")) {
            config.conv_ibm = true;
        } else {
            return error.InvalidValue;
        }
    }
}

/// Standard ASCII to EBCDIC conversion table
const ascii_to_ebcdic = [256]u8{
    // GNU coreutils EBCDIC conversion table
    0x00, 0x01, 0x02, 0x03, 0x37, 0x2D, 0x2E, 0x2F, 0x16, 0x05, 0x25, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x13, 0x3C, 0x3D, 0x32, 0x26, 0x18, 0x19, 0x3F, 0x27, 0x1C, 0x1D, 0x1E, 0x1F,
    0x40, 0x5A, 0x7F, 0x7B, 0x5B, 0x6C, 0x50, 0x7D, 0x4D, 0x5D, 0x5C, 0x4E, 0x6B, 0x60, 0x4B, 0x61,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0x7A, 0x5E, 0x4C, 0x7E, 0x6E, 0x6F,
    0x7C, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6,
    0xD7, 0xD8, 0xD9, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xAD, 0xE0, 0xBD, 0x9A, 0x6D,
    0x79, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xC0, 0x4F, 0xD0, 0x5F, 0x07,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x15, 0x06, 0x17, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x09, 0x0A, 0x1B,
    0x30, 0x31, 0x1A, 0x33, 0x34, 0x35, 0x36, 0x08, 0x38, 0x39, 0x3A, 0x3B, 0x04, 0x14, 0x3E, 0xE1,
    0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
    0x58, 0x59, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x80, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x6A, 0x9B, 0x9C, 0x9D, 0x9E,
    0x9F, 0xA0, 0xAA, 0xAB, 0xAC, 0x4A, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
    0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xA1, 0xBE, 0xBF, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xDA, 0xDB,
    0xDC, 0xDD, 0xDE, 0xDF, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
};

/// EBCDIC to ASCII conversion table (computed inverse of ascii_to_ebcdic)
const ebcdic_to_ascii = invertTable(ascii_to_ebcdic);

fn invertTable(forward: [256]u8) [256]u8 {
    @setEvalBranchQuota(1000);
    var table: [256]u8 = [_]u8{0} ** 256;
    for (0..256) |i| {
        table[forward[i]] = @intCast(i);
    }
    return table;
}

/// ASCII to IBM EBCDIC variant conversion table
/// Differs from standard EBCDIC in some special characters
const ascii_to_ibm = [256]u8{
    // GNU coreutils IBM EBCDIC conversion table
    0x00, 0x01, 0x02, 0x03, 0x37, 0x2D, 0x2E, 0x2F, 0x16, 0x05, 0x25, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x13, 0x3C, 0x3D, 0x32, 0x26, 0x18, 0x19, 0x3F, 0x27, 0x1C, 0x1D, 0x1E, 0x1F,
    0x40, 0x5A, 0x7F, 0x7B, 0x5B, 0x6C, 0x50, 0x7D, 0x4D, 0x5D, 0x5C, 0x4E, 0x6B, 0x60, 0x4B, 0x61,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0x7A, 0x5E, 0x4C, 0x7E, 0x6E, 0x6F,
    0x7C, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6,
    0xD7, 0xD8, 0xD9, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xAD, 0xE0, 0xBD, 0x5F, 0x6D,
    0x79, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xC0, 0x4F, 0xD0, 0xA1, 0x07,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x15, 0x06, 0x17, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x09, 0x0A, 0x1B,
    0x30, 0x31, 0x1A, 0x33, 0x34, 0x35, 0x36, 0x08, 0x38, 0x39, 0x3A, 0x3B, 0x04, 0x14, 0x3E, 0xE1,
    0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
    0x58, 0x59, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x80, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E,
    0x9F, 0xA0, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
    0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xDA, 0xDB,
    0xDC, 0xDD, 0xDE, 0xDF, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
};

/// Apply conversions to a buffer in-place.
/// Handles swab, character set (ascii/ebcdic/ibm), and case conversions.
fn applyConversions(buf: []u8, config: DdConfig) void {
    // Swap bytes (swab) - done before other conversions
    if (config.conv_swab) {
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 2) {
            const tmp = buf[i];
            buf[i] = buf[i + 1];
            buf[i + 1] = tmp;
        }
        // Odd last byte: preserved unchanged (GNU dd behavior)
    }

    // Character set conversions
    if (config.conv_ascii) {
        for (buf) |*c| {
            c.* = ebcdic_to_ascii[c.*];
        }
    } else if (config.conv_ebcdic) {
        for (buf) |*c| {
            c.* = ascii_to_ebcdic[c.*];
        }
    } else if (config.conv_ibm) {
        for (buf) |*c| {
            c.* = ascii_to_ibm[c.*];
        }
    }

    // Case conversions
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
fn printStats(io: std.Io, stderr: *std.Io.Writer, stats: DdStats, status: StatusLevel) void {
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

    const elapsed_ns = std.Io.Timestamp.now(io, .real).nanoseconds - stats.start_ns;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const elapsed_display = if (elapsed_s < 0.0001) 0.0001 else elapsed_s;
    // Clamped to >= 0.0001 above (covers clock skew), so the rate
    // division by elapsed_display below can never divide by zero.
    std.debug.assert(elapsed_display > 0.0);

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
        \\  cbs=BYTES       conversion block size (for block/unblock)
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
        \\  ascii     convert EBCDIC to ASCII
        \\  ebcdic    convert ASCII to EBCDIC
        \\  ibm       convert ASCII to IBM EBCDIC
        \\  block     pad newline-terminated records to cbs-size
        \\  unblock   replace trailing spaces in cbs-sized records
        \\  lcase     convert uppercase to lowercase
        \\  ucase     convert lowercase to uppercase
        \\  swab      swap every pair of input bytes
        \\  notrunc   do not truncate the output file
        \\  noerror   continue after read errors
        \\  sync      pad input blocks with NULs to ibs size
        \\  fsync     fsync output file before closing
        \\  osync     pad final output block with NULs to obs size
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

/// Scan args for operands that are parsed but not implemented.
/// Returns the operand name if an unsupported operand is found, null otherwise.
fn findUnsupportedOperand(args: []const []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            // indexOfScalar found '=' inside arg, so the value slice
            // arg[eq_pos + 1 ..] is in bounds.
            std.debug.assert(eq_pos < arg.len);
            const key = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];
            if (std.mem.eql(u8, key, "files")) {
                return "files";
            }
            if (std.mem.eql(u8, key, "conv")) {
                var iter = std.mem.splitScalar(u8, value, ',');
                while (iter.next()) |conv| {
                    if (std.mem.eql(u8, conv, "sparse")) return "sparse";
                    if (std.mem.eql(u8, conv, "pareven")) return "pareven";
                    if (std.mem.eql(u8, conv, "parnone")) return "parnone";
                    if (std.mem.eql(u8, conv, "parodd")) return "parodd";
                    if (std.mem.eql(u8, conv, "parset")) return "parset";
                }
            }
        }
    }
    return null;
}

/// Outcome of handling a read error inside the main copy loop.
/// `continue_loop` resumes the loop; `fatal` carries the exit code the
/// caller must return immediately (stats already printed where the
/// original inline code printed them).
const ReadErrorOutcome = union(enum) {
    continue_loop,
    fatal: u8,
};

/// The pair of files dd copies between, returned by runDd_openFiles.
const DdFiles = struct {
    input_file: std.Io.File,
    output_file: std.Io.File,
};

/// Result of opening the dd input/output files: either both files or
/// an exit code to return. Lets runDd keep the branching while the
/// straight-line open logic lives in the helper.
const DdOpenResult = union(enum) {
    files: DdFiles,
    fatal: u8,
};

/// Invariant context shared by every per-block write helper. Bundling
/// these together keeps the helper signatures and the copy-loop call
/// sites short; `stats` is a mutable pointer so increments persist.
const DdWriteCtx = struct {
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    output_file: std.Io.File,
    status: StatusLevel,
    stats: *DdStats,
};

/// The input and output working buffers dd always needs. The caller
/// owns freeing them.
const DdBuffers = struct {
    in_buf: []u8,
    out_buf: []u8,
};

/// Result of allocating the dd working buffers: the buffers or a fatal
/// exit code after printing the allocation-failure message.
const DdBuffersResult = union(enum) {
    buffers: DdBuffers,
    fatal: u8,
};

/// Result of allocating the optional conv=block conversion buffer: the
/// optional buffer (null when not needed) or a fatal exit code.
const DdCbsResult = union(enum) {
    buffer: ?[]u8,
    fatal: u8,
};

/// Immutable per-run parameters of the copy: the open input file, the
/// working buffers, the effective block sizes, and the chosen copy
/// mode. Bundling these keeps the copy-loop and finish call sites short.
const DdPlan = struct {
    input_file: std.Io.File,
    in_buf: []u8,
    out_buf: []u8,
    cbs_buf: ?[]u8,
    ibs: usize, // tiger:allow:usize-arch byte count uses slice index type
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
    cbs: usize, // tiger:allow:usize-arch byte count uses slice index type
    simple_copy: bool,
};

/// Mutable position state carried across copy-loop iterations and into
/// the tail-flush phase: the output buffer fill level, the conv=block
/// record position, and the conv=unblock record position.
const DdPositions = struct {
    out_pos: usize = 0, // tiger:allow:usize-arch byte position uses slice index type
    cbs_pos: usize = 0, // tiger:allow:usize-arch byte position uses slice index type
    unblock_pos: usize = 0, // tiger:allow:usize-arch byte position uses slice index type
};

/// Validate mutually-exclusive conversion combinations and the cbs
/// requirement for block/unblock. Returns 0 when the config is valid,
/// or a misuse exit code after printing the matching error message.
fn runDd_validateConfig(allocator: Allocator, stderr: *std.Io.Writer, config: *const DdConfig) u8 {
    // lcase and ucase are mutually exclusive
    if (config.conv_lcase and config.conv_ucase) {
        const message = "conv=lcase and conv=ucase are mutually exclusive";
        common.printErrorWithProgram(allocator, stderr, "dd", "{s}", .{message});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // ascii, ebcdic, and ibm are mutually exclusive
    const charset_count = @as(u8, @intFromBool(config.conv_ascii)) +
        @as(u8, @intFromBool(config.conv_ebcdic)) +
        @as(u8, @intFromBool(config.conv_ibm));
    // Sum of three booleans, so it stays within 0..3 inclusive.
    std.debug.assert(charset_count <= 3);
    if (charset_count > 1) {
        const message = "conv=ascii, conv=ebcdic, and conv=ibm are mutually exclusive";
        common.printErrorWithProgram(allocator, stderr, "dd", "{s}", .{message});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // block and unblock are mutually exclusive
    if (config.conv_block and config.conv_unblock) {
        const message = "conv=block and conv=unblock are mutually exclusive";
        common.printErrorWithProgram(allocator, stderr, "dd", "{s}", .{message});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // block and unblock require cbs
    if ((config.conv_block or config.conv_unblock) and config.cbs == null) {
        const message = "conv=block/unblock requires cbs operand";
        common.printErrorWithProgram(allocator, stderr, "dd", "{s}", .{message});
        return @intFromEnum(common.ExitCode.misuse);
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Allocate the input and output working buffers. Returns the buffers
/// or a fatal exit code after printing the allocation-failure message.
/// The caller registers the free defers.
fn runDd_allocBuffers(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    ibs: usize, // tiger:allow:usize-arch byte count uses slice index type
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
) DdBuffersResult {
    std.debug.assert(ibs > 0);
    std.debug.assert(obs > 0);

    const in_buf = allocator.alloc(u8, ibs) catch {
        common.printErrorWithProgram(allocator, stderr, "dd", "failed to allocate input buffer", .{});
        return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
    };
    const out_buf = allocator.alloc(u8, obs) catch {
        allocator.free(in_buf);
        common.printErrorWithProgram(allocator, stderr, "dd", "failed to allocate output buffer", .{});
        return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
    };
    // Postcondition: a successful alloc returns a slice of exactly the
    // requested length, so the buffers match the requested block sizes.
    std.debug.assert(in_buf.len == ibs);
    std.debug.assert(out_buf.len == obs);
    return .{ .buffers = .{ .in_buf = in_buf, .out_buf = out_buf } };
}

/// Open the input and output files per the config. Returns the opened
/// pair or a fatal exit code (after printing the OS error). The caller
/// owns closing the files when paths were supplied.
fn runDd_openFiles(
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    config: *const DdConfig,
) DdOpenResult {
    // Open input
    const input_file: std.Io.File = if (config.input_file) |path| blk: {
        break :blk std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            const message = common.posixErrorString(err);
            common.printErrorWithProgram(allocator, stderr, "dd", "{s}: {s}", .{ path, message });
            return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
        };
    } else std.Io.File.stdin();

    // Open output
    const output_file: std.Io.File = if (config.output_file) |path| blk: {
        const flags: std.Io.File.CreateFlags = .{
            .truncate = !config.conv_notrunc,
        };
        break :blk std.Io.Dir.cwd().createFile(io, path, flags) catch |err| {
            // Close the already-opened input file on output failure to
            // match the original runDd defer cleanup order.
            if (config.input_file != null) input_file.close(io);
            const message = common.posixErrorString(err);
            common.printErrorWithProgram(allocator, stderr, "dd", "{s}: {s}", .{ path, message });
            return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
        };
    } else std.Io.File.stdout();

    return .{ .files = .{ .input_file = input_file, .output_file = output_file } };
}

/// Skip `skip_blocks` ibs-sized blocks at the start of the input by
/// reading and discarding them. Returns 0 on success (including early
/// EOF), or a fatal exit code. Skip errors do NOT print stats.
fn runDd_skipInput(
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    input_file: std.Io.File,
    in_buf: []u8,
    skip_blocks: usize, // tiger:allow:usize-arch block count uses slice index type
) u8 {
    std.debug.assert(skip_blocks > 0);
    std.debug.assert(in_buf.len > 0);

    var skipped: usize = 0; // tiger:allow:usize-arch block counter uses slice index type
    while (skipped < skip_blocks) : (skipped += 1) {
        _ = input_file.readStreaming(io, &.{in_buf}) catch |err| switch (err) {
            error.EndOfStream => break, // EOF before all skips done
            else => {
                const message = common.posixErrorString(err);
                common.printErrorWithProgram(
                    allocator,
                    stderr,
                    "dd",
                    "error skipping input: {s}",
                    .{message},
                );
                return @intFromEnum(common.ExitCode.general_error);
            },
        };
    }
    // The loop stops at skipped == skip_blocks, or breaks earlier on EOF.
    std.debug.assert(skipped <= skip_blocks);
    return @intFromEnum(common.ExitCode.success);
}

/// Seek the output forward by `seek_blocks` obs-sized blocks. Falls
/// back to writing zero blocks when the file cannot seek (e.g. stdout).
/// Returns 0 on success, or a fatal exit code. Seek errors do NOT
/// print stats.
fn runDd_seekOutput(
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    output_file: std.Io.File,
    out_buf: []u8,
    seek_blocks: usize, // tiger:allow:usize-arch block count uses slice index type
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
) u8 {
    std.debug.assert(seek_blocks > 0);
    std.debug.assert(obs > 0);

    const seek_bytes = seek_blocks * obs;
    io.vtable.fileSeekTo(io.userdata, output_file, seek_bytes) catch {
        // If seeking fails (e.g., stdout), try writing zeros
        var seeked: usize = 0; // tiger:allow:usize-arch block counter uses slice index type
        @memset(out_buf, 0);
        while (seeked < seek_blocks) : (seeked += 1) {
            output_file.writeStreamingAll(io, out_buf) catch |write_err| {
                const message = common.posixErrorString(write_err);
                common.printErrorWithProgram(
                    allocator,
                    stderr,
                    "dd",
                    "error seeking output: {s}",
                    .{message},
                );
                return @intFromEnum(common.ExitCode.general_error);
            };
        }
        // The fallback loop stops at seeked == seek_blocks (or returned
        // early on write error), so it never overshoots the request.
        std.debug.assert(seeked <= seek_blocks);
    };
    return @intFromEnum(common.ExitCode.success);
}

/// Apply the skip= and seek= operands, in that order, by delegating to
/// the skip and seek helpers. Returns 0 when both succeed (or are not
/// requested), or the first fatal exit code encountered.
fn runDd_skipAndSeek(
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    files: DdFiles,
    bufs: DdBuffers,
    config: *const DdConfig,
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
) u8 {
    std.debug.assert(bufs.in_buf.len > 0);
    std.debug.assert(bufs.out_buf.len == obs);

    if (config.skip > 0) {
        const input = files.input_file;
        const code = runDd_skipInput(allocator, io, stderr, input, bufs.in_buf, config.skip);
        if (code != @intFromEnum(common.ExitCode.success)) return code;
    }
    if (config.seek > 0) {
        const output = files.output_file;
        const out_buf = bufs.out_buf;
        const code = runDd_seekOutput(allocator, io, stderr, output, out_buf, config.seek, obs);
        if (code != @intFromEnum(common.ExitCode.success)) return code;
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Allocate the conv=block conversion buffer when conv=block is active.
/// Returns the optional buffer (null when not needed) or a fatal exit
/// code after printing the allocation-failure message.
fn runDd_allocCbs(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    need_cbs: bool,
    cbs: usize, // tiger:allow:usize-arch byte count uses slice index type
) DdCbsResult {
    std.debug.assert(@intFromEnum(common.ExitCode.general_error) == 1);

    if (!need_cbs) return .{ .buffer = null };
    const cbs_buf = allocator.alloc(u8, cbs) catch {
        common.printErrorWithProgram(allocator, stderr, "dd", "failed to allocate cbs buffer", .{});
        return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
    };
    // Postcondition: a successful alloc returns exactly cbs bytes.
    std.debug.assert(cbs_buf.len == cbs);
    return .{ .buffer = cbs_buf };
}

/// Handle a non-EOF read error in the main copy loop. With conv=noerror
/// this prints the error, optionally NUL-fills/accounts a synced block
/// (writing it in simple-copy mode), and asks the caller to continue.
/// Otherwise it prints the error and stats and returns a fatal code.
fn runDd_handleReadError(
    ctx: *const DdWriteCtx,
    config: *const DdConfig,
    in_buf: []u8,
    ibs: usize, // tiger:allow:usize-arch byte count uses slice index type
    simple_copy: bool,
    blocks_read: *usize, // tiger:allow:usize-arch block counter uses slice index type
    err: anyerror,
) ReadErrorOutcome {
    std.debug.assert(in_buf.len > 0);
    std.debug.assert(ibs > 0);

    if (config.conv_noerror) {
        // Continue after read errors
        const read_message = common.posixErrorString(err);
        common.printErrorWithProgram(
            ctx.allocator,
            ctx.stderr,
            "dd",
            "read error: {s}",
            .{read_message},
        );
        if (config.conv_sync) {
            // Fill with NULs when sync is specified
            @memset(in_buf, 0);
            // Count as a full block
            ctx.stats.full_blocks_in += 1;
            blocks_read.* += 1;
            if (simple_copy) {
                // Write the NUL-filled block
                ctx.output_file.writeStreamingAll(ctx.io, in_buf) catch |werr| {
                    const write_message = common.posixErrorString(werr);
                    common.printErrorWithProgram(
                        ctx.allocator,
                        ctx.stderr,
                        "dd",
                        "write error: {s}",
                        .{write_message},
                    );
                    return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
                };
                ctx.stats.full_blocks_out += 1;
                ctx.stats.bytes_copied += ibs;
            }
        }
        return .continue_loop;
    }
    const read_message = common.posixErrorString(err);
    common.printErrorWithProgram(
        ctx.allocator,
        ctx.stderr,
        "dd",
        "read error: {s}",
        .{read_message},
    );
    printStats(ctx.io, ctx.stderr, ctx.stats.*, ctx.status);
    return .{ .fatal = @intFromEnum(common.ExitCode.general_error) };
}

/// Report a write failure the way every copy-loop and flush write does:
/// print the OS error, emit transfer stats, and yield the general-error
/// exit code. Centralizes the repeated catch arm without changing it.
fn runDd_writeError(ctx: *const DdWriteCtx, err: anyerror) u8 {
    std.debug.assert(@intFromEnum(common.ExitCode.general_error) == 1);

    const message = common.posixErrorString(err);
    common.printErrorWithProgram(ctx.allocator, ctx.stderr, "dd", "write error: {s}", .{message});
    printStats(ctx.io, ctx.stderr, ctx.stats.*, ctx.status);
    return @intFromEnum(common.ExitCode.general_error);
}

/// Process one converted data block under conv=block: emit cbs-sized,
/// fill-padded records on each newline and truncate overlong records.
/// `cbs_pos` tracks the position within the in-progress record across
/// blocks. Returns 0 to continue, or a fatal code (stats printed).
fn runDd_writeBlockRecord(
    ctx: *const DdWriteCtx,
    record_buf: []u8,
    cbs: usize, // tiger:allow:usize-arch byte count uses slice index type
    fillchar: u8,
    data: []const u8,
    cbs_pos: *usize, // tiger:allow:usize-arch byte position uses slice index type
) u8 {
    std.debug.assert(record_buf.len == cbs);
    std.debug.assert(cbs_pos.* <= cbs);

    for (data) |byte| {
        if (byte == '\n') {
            // End of record: pad with fill character to cbs and write
            if (cbs_pos.* < cbs) {
                @memset(record_buf[cbs_pos.*..], fillchar);
            }
            ctx.output_file.writeStreamingAll(ctx.io, record_buf[0..cbs]) catch |err| {
                return runDd_writeError(ctx, err);
            };
            ctx.stats.bytes_copied += cbs;
            ctx.stats.full_blocks_out += 1;
            cbs_pos.* = 0;
        } else {
            // Accumulate byte into record (truncate if > cbs)
            if (cbs_pos.* < cbs) {
                record_buf[cbs_pos.*] = byte;
                cbs_pos.* += 1;
            }
        }
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Process one converted data block under conv=unblock: split it into
/// cbs-sized records, strip trailing spaces, and emit each with a
/// newline. `unblock_pos` tracks the partial record across blocks.
/// Returns 0 to continue, or a fatal code (stats printed).
fn runDd_writeUnblockRecords(
    ctx: *const DdWriteCtx,
    out_buf: []u8,
    cbs: usize, // tiger:allow:usize-arch byte count uses slice index type
    data: []const u8,
    unblock_pos: *usize, // tiger:allow:usize-arch byte position uses slice index type
) u8 {
    std.debug.assert(unblock_pos.* <= cbs);

    // Process data in cbs-sized chunks
    var data_pos: usize = 0; // tiger:allow:usize-arch byte position uses slice index type
    while (data_pos < data.len) {
        const remaining_in_record = cbs - unblock_pos.*;
        const remaining_in_data = data.len - data_pos;
        const to_consume = @min(remaining_in_record, remaining_in_data);

        // Copy bytes into output buffer temporarily
        @memcpy(out_buf[unblock_pos.*..][0..to_consume], data[data_pos..][0..to_consume]);
        unblock_pos.* += to_consume;
        data_pos += to_consume;

        if (unblock_pos.* == cbs) {
            // Complete record: strip trailing spaces and add newline
            var end: usize = cbs; // tiger:allow:usize-arch byte position uses slice index type
            while (end > 0 and out_buf[end - 1] == ' ') : (end -= 1) {}
            ctx.output_file.writeStreamingAll(ctx.io, out_buf[0..end]) catch |err| {
                return runDd_writeError(ctx, err);
            };
            ctx.output_file.writeStreamingAll(ctx.io, "\n") catch |err| {
                return runDd_writeError(ctx, err);
            };
            ctx.stats.bytes_copied += end + 1;
            ctx.stats.full_blocks_out += 1;
            unblock_pos.* = 0;
        }
    }
    // Loop invariant: each step advances data_pos by at most the bytes
    // remaining, so it never runs past the end of the data slice.
    std.debug.assert(data_pos <= data.len);
    return @intFromEnum(common.ExitCode.success);
}

/// Write one converted block in simple-copy mode: each input block is
/// written directly, with conv=osync padding a partial final block to
/// obs with NULs. Updates stats. Returns 0 to continue, or a fatal
/// code (stats printed).
fn runDd_writeSimpleBlock(
    ctx: *const DdWriteCtx,
    out_buf: []u8,
    data: []const u8,
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
    conv_osync: bool,
) u8 {
    std.debug.assert(obs != 0);
    std.debug.assert(out_buf.len == obs);
    // simple_copy is chosen only when bs= forces ibs == obs, so an input
    // block never exceeds the output buffer it is copied into.
    std.debug.assert(data.len <= out_buf.len);

    if (conv_osync and data.len < obs) {
        // Pad partial block to obs size with NULs
        @memcpy(out_buf[0..data.len], data);
        @memset(out_buf[data.len..obs], 0);
        ctx.output_file.writeStreamingAll(ctx.io, out_buf[0..obs]) catch |err| {
            return runDd_writeError(ctx, err);
        };
        ctx.stats.bytes_copied += obs;
        ctx.stats.full_blocks_out += 1;
    } else {
        ctx.output_file.writeStreamingAll(ctx.io, data) catch |err| {
            return runDd_writeError(ctx, err);
        };
        ctx.stats.bytes_copied += data.len;
        if (data.len == obs) {
            ctx.stats.full_blocks_out += 1;
        } else {
            ctx.stats.partial_blocks_out += 1;
        }
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Write one converted block in buffered mode: accumulate into out_buf
/// and flush whenever it fills to obs. `out_pos` carries the buffer
/// fill level across blocks. Returns 0 to continue, or a fatal code
/// (stats printed).
fn runDd_writeBufferedBlock(
    ctx: *const DdWriteCtx,
    out_buf: []u8,
    data: []const u8,
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
    out_pos: *usize, // tiger:allow:usize-arch byte position uses slice index type
) u8 {
    std.debug.assert(obs != 0);
    std.debug.assert(out_pos.* < obs);

    var data_pos: usize = 0; // tiger:allow:usize-arch byte position uses slice index type
    while (data_pos < data.len) {
        const space_in_out = obs - out_pos.*;
        const to_copy = @min(space_in_out, data.len - data_pos);
        @memcpy(out_buf[out_pos.*..][0..to_copy], data[data_pos..][0..to_copy]);
        out_pos.* += to_copy;
        data_pos += to_copy;

        if (out_pos.* == obs) {
            // Output buffer is full, write it
            ctx.output_file.writeStreamingAll(ctx.io, out_buf[0..obs]) catch |err| {
                return runDd_writeError(ctx, err);
            };
            ctx.stats.full_blocks_out += 1;
            ctx.stats.bytes_copied += obs;
            out_pos.* = 0;
        }
    }
    // Loop invariant: data_pos advances by at most the bytes remaining,
    // so it never runs past the end of the data slice.
    std.debug.assert(data_pos <= data.len);
    return @intFromEnum(common.ExitCode.success);
}

/// Flush the conv=block tail: a partial record left without a trailing
/// newline is fill-padded to cbs and written. Returns 0, or a fatal
/// code (stats printed). Caller guards with conv_block and cbs_pos > 0.
fn runDd_flushTails_block(
    ctx: *const DdWriteCtx,
    record_buf: []u8,
    cbs: usize, // tiger:allow:usize-arch byte count uses slice index type
    cbs_pos: usize, // tiger:allow:usize-arch byte position uses slice index type
    fillchar: u8,
) u8 {
    std.debug.assert(record_buf.len == cbs);
    std.debug.assert(cbs_pos > 0);
    // writeBlockRecord only ever leaves cbs_pos in 0..cbs, so padding the
    // tail with record_buf[cbs_pos..] stays in bounds.
    std.debug.assert(cbs_pos <= cbs);

    @memset(record_buf[cbs_pos..], fillchar);
    ctx.output_file.writeStreamingAll(ctx.io, record_buf[0..cbs]) catch |err| {
        return runDd_writeError(ctx, err);
    };
    ctx.stats.bytes_copied += cbs;
    ctx.stats.partial_blocks_out += 1;
    return @intFromEnum(common.ExitCode.success);
}

/// Flush the conv=unblock tail: the partial record is space-stripped
/// and written with a trailing newline. Returns 0, or a fatal code
/// (stats printed). Caller guards with conv_unblock and unblock_pos > 0.
fn runDd_flushTails_unblock(
    ctx: *const DdWriteCtx,
    out_buf: []u8,
    unblock_pos: usize, // tiger:allow:usize-arch byte position uses slice index type
) u8 {
    std.debug.assert(unblock_pos > 0);
    std.debug.assert(unblock_pos <= out_buf.len);

    var end: usize = unblock_pos; // tiger:allow:usize-arch byte position uses slice index type
    while (end > 0 and out_buf[end - 1] == ' ') : (end -= 1) {}
    ctx.output_file.writeStreamingAll(ctx.io, out_buf[0..end]) catch |err| {
        return runDd_writeError(ctx, err);
    };
    ctx.output_file.writeStreamingAll(ctx.io, "\n") catch |err| {
        return runDd_writeError(ctx, err);
    };
    ctx.stats.bytes_copied += end + 1;
    ctx.stats.partial_blocks_out += 1;
    return @intFromEnum(common.ExitCode.success);
}

/// Flush the generic output buffer tail (non-simple, non-block,
/// non-unblock): conv=osync pads the final block to obs. Returns 0, or
/// a fatal code (stats printed). Caller guards with out_pos > 0.
fn runDd_flushTails_buffer(
    ctx: *const DdWriteCtx,
    out_buf: []u8,
    obs: usize, // tiger:allow:usize-arch byte count uses slice index type
    out_pos: usize, // tiger:allow:usize-arch byte position uses slice index type
    conv_osync: bool,
) u8 {
    std.debug.assert(out_pos > 0);
    std.debug.assert(out_pos <= obs);
    // out_buf is the obs-sized output buffer, so padding to obs and the
    // out_buf[0..write_len] write (write_len <= obs) both stay in bounds.
    std.debug.assert(obs <= out_buf.len);

    const write_len = if (conv_osync) blk: {
        // Pad the final block to obs size with NULs
        @memset(out_buf[out_pos..obs], 0);
        break :blk obs;
    } else out_pos;
    ctx.output_file.writeStreamingAll(ctx.io, out_buf[0..write_len]) catch |err| {
        return runDd_writeError(ctx, err);
    };
    if (conv_osync) {
        ctx.stats.full_blocks_out += 1;
        ctx.stats.bytes_copied += obs;
    } else {
        ctx.stats.partial_blocks_out += 1;
        ctx.stats.bytes_copied += out_pos;
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Execute the dd copy operation. Handles the argument-level outcomes
/// (unsupported operand, parse errors, --help, --version) here and
/// delegates the actual copy to runDd_copy once the config is valid.
pub fn runDd(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) anyerror!u8 {
    if (findUnsupportedOperand(args)) |name| {
        const message = "unsupported operand '{s}' (not implemented)";
        common.printErrorWithProgram(allocator, stderr, "dd", message, .{name});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const config = parseOperands(args) catch |err| {
        switch (err) {
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr, "dd", "invalid operand value", .{});
            },
            error.UnknownOperand => {
                common.printErrorWithProgram(allocator, stderr, "dd", "unrecognized operand", .{});
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

    return runDd_copy(allocator, io, stderr, &config);
}

/// Set up the copy (validate, size, allocate, open, skip, seek), then
/// run the copy loop and flush the tails. Owns every buffer/file defer
/// so the lifecycle stays in one scope; returns the final exit code.
fn runDd_copy(
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    config: *const DdConfig,
) u8 {
    const validate_code = runDd_validateConfig(allocator, stderr, config);
    if (validate_code != @intFromEnum(common.ExitCode.success)) return validate_code;

    // Determine effective block sizes
    const ibs = if (config.bs) |bs| bs else config.ibs;
    const obs = if (config.bs) |bs| bs else config.obs;
    if (ibs == 0 or obs == 0) {
        common.printErrorWithProgram(allocator, stderr, "dd", "block size cannot be zero", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }
    // The guard above rejected zero block sizes, so both are positive
    // before the buffers are allocated against them.
    std.debug.assert(ibs > 0);
    std.debug.assert(obs > 0);

    const bufs = switch (runDd_allocBuffers(allocator, stderr, ibs, obs)) {
        .fatal => |code| return code,
        .buffers => |b| b,
    };
    defer allocator.free(bufs.in_buf);
    defer allocator.free(bufs.out_buf);

    const files = switch (runDd_openFiles(allocator, io, stderr, config)) {
        .fatal => |code| return code,
        .files => |f| f,
    };
    defer if (config.input_file != null) files.input_file.close(io);
    defer if (config.output_file != null) files.output_file.close(io);

    const ss_code = runDd_skipAndSeek(allocator, io, stderr, files, bufs, config, obs);
    if (ss_code != @intFromEnum(common.ExitCode.success)) return ss_code;

    const cbs = config.cbs orelse 0;
    const cbs_buf = switch (runDd_allocCbs(allocator, stderr, config.conv_block, cbs)) {
        .fatal => |code| return code,
        .buffer => |b| b,
    };
    defer if (cbs_buf) |b| allocator.free(b);

    var stats = DdStats{ .start_ns = std.Io.Timestamp.now(io, .real).nanoseconds };
    const ctx = DdWriteCtx{
        .allocator = allocator,
        .io = io,
        .stderr = stderr,
        .output_file = files.output_file,
        .status = config.status,
        .stats = &stats,
    };
    const plan = DdPlan{
        .input_file = files.input_file,
        .in_buf = bufs.in_buf,
        .out_buf = bufs.out_buf,
        .cbs_buf = cbs_buf,
        .ibs = ibs,
        .obs = obs,
        .cbs = cbs,
        // Use simple copy when bs= is set and no block/unblock conversion.
        .simple_copy = config.bs != null and !config.conv_block and !config.conv_unblock,
    };
    var positions = DdPositions{};

    const loop_code = runDd_copyLoop(&ctx, config, &plan, &positions);
    if (loop_code != @intFromEnum(common.ExitCode.success)) return loop_code;

    return runDd_finish(&ctx, config, &plan, &positions);
}

/// The main dd copy loop: read a block, account it, sync-pad, convert,
/// and dispatch to the matching per-mode write helper. Position state
/// is carried via pointers so the tail-flush phase can finish records.
/// Returns 0 when the loop completes, or a fatal exit code.
fn runDd_copyLoop(
    ctx: *const DdWriteCtx,
    config: *const DdConfig,
    plan: *const DdPlan,
    positions: *DdPositions,
) u8 {
    std.debug.assert(plan.in_buf.len == plan.ibs);
    std.debug.assert(plan.out_buf.len == plan.obs);
    // runDd_copy gates ibs > 0 before building the plan, so every read
    // presents a nonempty buffer and the loop makes forward progress.
    std.debug.assert(plan.ibs > 0);

    const in_buf = plan.in_buf;
    const input_file = plan.input_file;
    var blocks_read: usize = 0; // tiger:allow:usize-arch block counter uses slice index type
    while (true) {
        // Check count limit
        if (config.count) |count| {
            if (blocks_read >= count) break;
        }

        // Read one input block
        const bytes_read = input_file.readStreaming(ctx.io, &.{in_buf}) catch |err| switch (err) {
            error.EndOfStream => break, // EOF
            else => switch (runDd_handleReadError(
                ctx,
                config,
                in_buf,
                plan.ibs,
                plan.simple_copy,
                &blocks_read,
                err,
            )) {
                .continue_loop => continue,
                .fatal => |code| return code,
            },
        };

        blocks_read += 1;

        // Track input block statistics
        if (bytes_read == plan.ibs) {
            ctx.stats.full_blocks_in += 1;
        } else {
            ctx.stats.partial_blocks_in += 1;
        }

        // Get the data to process
        var data = in_buf[0..bytes_read];

        // Apply sync padding if needed. GNU dd pads with spaces when
        // conv=block or conv=unblock is active, and with NUL otherwise.
        if (config.conv_sync and bytes_read < plan.ibs) {
            const pad_byte: u8 = if (config.conv_block or config.conv_unblock) ' ' else 0;
            @memset(in_buf[bytes_read..], pad_byte);
            data = in_buf[0..plan.ibs];
        }

        // Apply conversions (swab, charset, case)
        applyConversions(data, config.*);

        const code = runDd_copyLoop_dispatch(ctx, config, plan, data, positions);
        if (code != @intFromEnum(common.ExitCode.success)) return code;
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Dispatch one converted block to the matching write mode, mutating
/// the carried position state. Returns 0 to continue the loop, or a
/// fatal exit code. Branch order matches the original inline dispatch.
fn runDd_copyLoop_dispatch(
    ctx: *const DdWriteCtx,
    config: *const DdConfig,
    plan: *const DdPlan,
    data: []u8,
    positions: *DdPositions,
) u8 {
    std.debug.assert(plan.out_buf.len == plan.obs);
    std.debug.assert(data.len <= plan.in_buf.len);

    if (config.conv_block) {
        return runDd_writeBlockRecord(
            ctx,
            plan.cbs_buf.?,
            plan.cbs,
            config.fillchar,
            data,
            &positions.cbs_pos,
        );
    }
    if (config.conv_unblock) {
        return runDd_writeUnblockRecords(ctx, plan.out_buf, plan.cbs, data, &positions.unblock_pos);
    }
    if (plan.simple_copy) {
        return runDd_writeSimpleBlock(ctx, plan.out_buf, data, plan.obs, config.conv_osync);
    }
    return runDd_writeBufferedBlock(ctx, plan.out_buf, data, plan.obs, &positions.out_pos);
}

/// Flush the conversion tails left after the copy loop, fsync the
/// output when requested, and print final transfer statistics. Returns
/// success, or a fatal exit code if a tail write or fsync fails.
fn runDd_finish(
    ctx: *const DdWriteCtx,
    config: *const DdConfig,
    plan: *const DdPlan,
    positions: *const DdPositions,
) u8 {
    std.debug.assert(plan.out_buf.len == plan.obs);

    // Flush remaining record for conv=block (partial record without newline)
    if (config.conv_block and positions.cbs_pos > 0) {
        const code = runDd_flushTails_block(
            ctx,
            plan.cbs_buf.?,
            plan.cbs,
            positions.cbs_pos,
            config.fillchar,
        );
        if (code != @intFromEnum(common.ExitCode.success)) return code;
    }

    // Flush remaining data for conv=unblock (partial record)
    if (config.conv_unblock and positions.unblock_pos > 0) {
        const code = runDd_flushTails_unblock(ctx, plan.out_buf, positions.unblock_pos);
        if (code != @intFromEnum(common.ExitCode.success)) return code;
    }

    // Flush remaining data in output buffer (non-simple mode, non-block/unblock)
    const buffered_mode = !plan.simple_copy and !config.conv_block and !config.conv_unblock;
    if (buffered_mode and positions.out_pos > 0) {
        const code = runDd_flushTails_buffer(
            ctx,
            plan.out_buf,
            plan.obs,
            positions.out_pos,
            config.conv_osync,
        );
        if (code != @intFromEnum(common.ExitCode.success)) return code;
    }

    // fsync the output file if requested
    if (config.conv_fsync) {
        ctx.output_file.sync(ctx.io) catch |err| {
            const message = common.posixErrorString(err);
            common.printErrorWithProgram(
                ctx.allocator,
                ctx.stderr,
                "dd",
                "fsync error: {s}",
                .{message},
            );
            return @intFromEnum(common.ExitCode.general_error);
        };
    }

    // Print statistics
    printStats(ctx.io, ctx.stderr, ctx.stats.*, config.status);
    return @intFromEnum(common.ExitCode.success);
}

/// Process files or stdin with dd operands
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runDd);
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
    try testing.expect(!config.conv_fsync);
    try testing.expect(!config.conv_osync);
    try testing.expect(!config.conv_swab);
    try testing.expect(!config.conv_ascii);
    try testing.expect(!config.conv_ebcdic);
    try testing.expect(!config.conv_ibm);
    try testing.expect(!config.conv_block);
    try testing.expect(!config.conv_unblock);
    try testing.expect(config.cbs == null);
    try testing.expectEqual(@as(u8, ' '), config.fillchar);
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const exit_code = try runDd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: dd") != null);
}

test "runDd - version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const exit_code = try runDd(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "dd (vibeutils)") != null);
}

test "runDd - basic file copy" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "Hello, dd!\n");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);

    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ if_arg, of_arg, "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify output file contents
    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Hello, dd!\n", content);
}

test "runDd - copy with count" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with multiple 512-byte blocks worth of data
    const data = "ABCDEFGHIJ" ** 52; // 520 bytes > 1 block
    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", data);

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // Copy 1 block of 10 bytes
    const args = [_][]const u8{ if_arg, of_arg, "bs=10", "count=1", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 10), content.len);
    try testing.expectEqualStrings("ABCDEFGHIJ", content);
}

test "runDd - copy with conv=ucase" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "hello world");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=ucase", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("HELLO WORLD", content);
}

test "runDd - copy with conv=lcase" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "HELLO WORLD");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=lcase", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "runDd - skip blocks" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "AAAABBBB");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // Skip 1 block of 4 bytes, should get "BBBB"
    const args = [_][]const u8{ if_arg, of_arg, "bs=4", "skip=1", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("BBBB", content);
}

test "runDd - statistics output" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "test data");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ if_arg, of_arg };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should contain records in/out
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "records in") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "records out") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "bytes") != null);
}

test "runDd - status=none suppresses output" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "test data");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ if_arg, of_arg, "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "runDd - status=noxfer omits transfer line" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "test data");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ if_arg, of_arg, "status=noxfer" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should have records but not bytes line
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "records in") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "records out") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "bytes") == null);
}

test "runDd - mutually exclusive lcase and ucase" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"conv=lcase,ucase"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - nonexistent input file" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "if=/nonexistent/path/to/file.txt", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "runDd - invalid operand" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"invalid=operand"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - zero block size" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"bs=0"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - different ibs and obs" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "ABCDEFGHIJKLMNOP");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // Read 4 bytes at a time, write 8 bytes at a time
    const args = [_][]const u8{ if_arg, of_arg, "ibs=4", "obs=8", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", content);
}

test "runDd - count=0 copies nothing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "some data");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "count=0", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 0), content.len);
}

test "parseOperands - cbs operand" {
    const args = [_][]const u8{"cbs=80"};
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(?usize, 80), config.cbs);
}

test "parseOperands - cbs default is null" {
    const args = [_][]const u8{};
    const config = try parseOperands(&args);
    try testing.expect(config.cbs == null);
}

test "parseConversions - fsync" {
    const args = [_][]const u8{"conv=fsync"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_fsync);
}

test "parseConversions - osync" {
    const args = [_][]const u8{"conv=osync"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_osync);
}

test "parseConversions - swab" {
    const args = [_][]const u8{"conv=swab"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_swab);
}

test "parseConversions - noxfer is rejected in conv" {
    const args = [_][]const u8{"conv=noxfer"};
    try testing.expectError(error.InvalidValue, parseOperands(&args));
}

test "parseConversions - ascii" {
    const args = [_][]const u8{"conv=ascii"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_ascii);
}

test "parseConversions - ebcdic" {
    const args = [_][]const u8{"conv=ebcdic"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_ebcdic);
}

test "parseConversions - ibm" {
    const args = [_][]const u8{"conv=ibm"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_ibm);
}

test "parseConversions - block" {
    const args = [_][]const u8{"conv=block"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_block);
}

test "parseConversions - unblock" {
    const args = [_][]const u8{"conv=unblock"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_unblock);
}

test "parseConversions - multiple new conversions" {
    const args = [_][]const u8{"conv=swab,fsync"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_swab);
    try testing.expect(config.conv_fsync);
}

test "applyConversions - swab even length" {
    var buf = "ABCD".*;
    applyConversions(&buf, .{ .conv_swab = true });
    try testing.expectEqualStrings("BADC", &buf);
}

test "applyConversions - swab odd length" {
    // With odd length, last byte is preserved unchanged (GNU dd behavior)
    var buf = [_]u8{ 'A', 'B', 'C' };
    applyConversions(&buf, .{ .conv_swab = true });
    try testing.expectEqual(@as(u8, 'B'), buf[0]);
    try testing.expectEqual(@as(u8, 'A'), buf[1]);
    // Last byte: preserved unchanged
    try testing.expectEqual(@as(u8, 'C'), buf[2]);
}

test "applyConversions - ebcdic conversion" {
    // 'A' (0x41) in ASCII -> 0xC1 in EBCDIC
    var buf = [_]u8{'A'};
    applyConversions(&buf, .{ .conv_ebcdic = true });
    try testing.expectEqual(@as(u8, 0xC1), buf[0]);
}

test "applyConversions - ascii conversion" {
    // 0xC1 in EBCDIC -> 'A' (0x41) in ASCII
    var buf = [_]u8{0xC1};
    applyConversions(&buf, .{ .conv_ascii = true });
    try testing.expectEqual(@as(u8, 'A'), buf[0]);
}

test "applyConversions - ibm conversion" {
    // 'A' (0x41) in ASCII -> 0xC1 in IBM EBCDIC
    var buf = [_]u8{'A'};
    applyConversions(&buf, .{ .conv_ibm = true });
    try testing.expectEqual(@as(u8, 0xC1), buf[0]);
}

test "runDd - conv=swab swaps byte pairs" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.bin", "ABCD");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.bin", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=swab", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("BADC", content);
}

test "runDd - conv=ebcdic converts ASCII to EBCDIC" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "A");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=ebcdic", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(u8, 0xC1), content[0]);
}

test "runDd - conv=ascii converts EBCDIC to ASCII" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write raw EBCDIC byte 0xC1 which should convert to ASCII 'A'
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "input.bin", .data = &[_]u8{0xC1} });

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.bin", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "conv=ascii", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("A", content);
}

test "runDd - conv=osync pads final block" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write 3 bytes with obs=8, final block should be padded to 8
    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "ABC");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "obs=8", "conv=osync", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    // Should be padded to 8 bytes
    try testing.expectEqual(@as(usize, 8), content.len);
    try testing.expectEqualStrings("ABC", content[0..3]);
    // Remaining should be NUL
    try testing.expectEqual(@as(u8, 0), content[3]);
    try testing.expectEqual(@as(u8, 0), content[7]);
}

test "runDd - conv=block pads records to cbs size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Input: two newline-terminated records
    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "ab\ncd\n");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // cbs=5: each record padded to 5 bytes with spaces
    const args = [_][]const u8{ if_arg, of_arg, "cbs=5", "conv=block", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    // "ab" padded to 5 = "ab   ", "cd" padded to 5 = "cd   "
    try testing.expectEqual(@as(usize, 10), content.len);
    try testing.expectEqualStrings("ab   cd   ", content);
}

test "runDd - conv=unblock replaces trailing spaces with newline" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Input: two 5-byte fixed records with trailing spaces
    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "ab   cd   ");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // cbs=5: each 5-byte record, trailing spaces replaced with newline
    const args = [_][]const u8{ if_arg, of_arg, "cbs=5", "conv=unblock", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("ab\ncd\n", content);
}

test "runDd - conv=noxfer is rejected" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"conv=noxfer"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    // conv=noxfer should be rejected; noxfer is only valid as status=noxfer
    try testing.expect(exit_code != 0);
}

test "runDd - mutually exclusive ascii and ebcdic" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"conv=ascii,ebcdic"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - mutually exclusive block and unblock" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"conv=block,unblock"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - block requires cbs" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"conv=block"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "runDd - unblock requires cbs" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"conv=unblock"};
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "EBCDIC round-trip: ASCII->EBCDIC->ASCII for printable chars" {
    // Verify the conversion tables are inverses for printable ASCII
    for (0..128) |i| {
        const ebcdic_val = ascii_to_ebcdic[i];
        const round_trip = ebcdic_to_ascii[ebcdic_val];
        try testing.expectEqual(@as(u8, @intCast(i)), round_trip);
    }
}

test "parseOperands - iseek maps to skip" {
    const args = [_][]const u8{"iseek=7"};
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(usize, 7), config.skip);
}

test "parseOperands - oseek maps to seek" {
    const args = [_][]const u8{"oseek=4"};
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(usize, 4), config.seek);
}

test "parseOperands - fillchar single character" {
    const args = [_][]const u8{"fillchar=X"};
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(u8, 'X'), config.fillchar);
}

test "parseOperands - fillchar rejects multi-char" {
    const args = [_][]const u8{"fillchar=AB"};
    try testing.expectError(error.InvalidValue, parseOperands(&args));
}

test "parseOperands - fillchar rejects empty" {
    const args = [_][]const u8{"fillchar="};
    try testing.expectError(error.InvalidValue, parseOperands(&args));
}

test "parseOperands - iflag accepted and ignored" {
    const args = [_][]const u8{"iflag=fullblock,direct"};
    const config = try parseOperands(&args);
    // Should parse without error; flags are silently ignored
    try testing.expect(config.input_file == null);
}

test "parseOperands - oflag accepted and ignored" {
    const args = [_][]const u8{"oflag=dsync,noatime"};
    const config = try parseOperands(&args);
    // Should parse without error; flags are silently ignored
    try testing.expect(config.output_file == null);
}

test "parseOperands - speed accepted and ignored" {
    const args = [_][]const u8{"speed=1000000"};
    const config = try parseOperands(&args);
    try testing.expect(config.input_file == null);
}

test "parseOperands - speed rejects non-numeric" {
    const args = [_][]const u8{"speed=fast"};
    try testing.expectError(error.InvalidValue, parseOperands(&args));
}

test "parseConversions - oldascii maps to ascii" {
    const args = [_][]const u8{"conv=oldascii"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_ascii);
}

test "parseConversions - oldebcdic maps to ebcdic" {
    const args = [_][]const u8{"conv=oldebcdic"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_ebcdic);
}

test "parseConversions - oldibm maps to ibm" {
    const args = [_][]const u8{"conv=oldibm"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_ibm);
}

test "runDd - conv=block with fillchar" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "ab\n");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // cbs=5, fillchar=X: record "ab" padded to "abXXX"
    const args = [_][]const u8{ if_arg, of_arg, "cbs=5", "conv=block", "fillchar=X", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 5), content.len);
    try testing.expectEqualStrings("abXXX", content);
}

test "runDd - iseek skips input blocks" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "AAAABBBB");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // iseek=1 with bs=4 should skip first 4 bytes, get "BBBB"
    const args = [_][]const u8{ if_arg, of_arg, "bs=4", "iseek=1", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("BBBB", content);
}

test "runDd - multi-block copy with bs and count" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // 5 blocks of 4 bytes each = 20 bytes; copy only first 3 blocks
    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "AAAABBBBCCCCddddeeee");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    const args = [_][]const u8{ if_arg, of_arg, "bs=4", "count=3", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 12), content.len);
    try testing.expectEqualStrings("AAAABBBBCCCC", content);
}

// ============================================================================
//          AUDIT WAVE 4: FAILING TESTS FOR IMPORTANT FINDINGS
// ============================================================================

test "audit: conv=swab odd-length input preserves last byte" {
    // Audit finding: conv=swab with odd-length input zeroes last byte instead
    // of preserving it. GNU dd preserves the unpaired last byte unchanged.
    // Location: src/dd.zig:318-321
    var buf = [_]u8{ 'A', 'B', 'C' };
    applyConversions(&buf, .{ .conv_swab = true });
    // First pair swapped: B, A
    try testing.expectEqual(@as(u8, 'B'), buf[0]);
    try testing.expectEqual(@as(u8, 'A'), buf[1]);
    // Last byte must be preserved as 'C', not zeroed
    try testing.expectEqual(@as(u8, 'C'), buf[2]);
}

test "audit: conv=swab odd-length 5-byte input preserves last byte" {
    // Same bug, verified with 5 bytes: "ABCDE" -> "BADCE"
    var buf = [_]u8{ 'A', 'B', 'C', 'D', 'E' };
    applyConversions(&buf, .{ .conv_swab = true });
    try testing.expectEqual(@as(u8, 'B'), buf[0]);
    try testing.expectEqual(@as(u8, 'A'), buf[1]);
    try testing.expectEqual(@as(u8, 'D'), buf[2]);
    try testing.expectEqual(@as(u8, 'C'), buf[3]);
    // Last byte must be preserved as 'E', not zeroed
    try testing.expectEqual(@as(u8, 'E'), buf[4]);
}

test "audit: conv=sync pads with spaces when conv=block is active" {
    const io = testing.io;
    // Audit finding: conv=sync always pads with NUL; should use spaces when
    // block-oriented conversion (block/unblock) is specified.
    // Location: src/dd.zig:674-677
    //
    // This test creates a 2-byte input "X\n" with ibs=6, conv=sync,block, cbs=6.
    // The sync should pad "X\n" to 6 bytes with spaces (not NUL) because
    // conv=block is active. Then conv=block processes the 6-byte record:
    // "X\n" triggers a record end at the newline. The record "X" gets padded
    // to cbs=6 with fillchar (space). The remaining 4 space-padded bytes
    // form a record of all spaces -> padded to cbs=6.
    // If sync pads with NUL, those NUL bytes leak into the block output.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "X\n");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    // ibs=6, conv=sync,block, cbs=6: sync pads input to 6 bytes,
    // then block processes newline-terminated records.
    // With correct space padding: "X\n    " -> record "X" padded to "X     ",
    // then 4 trailing spaces form another record "    " padded to "      ".
    // Output = "X     " (6 bytes) + "      " (6 bytes) = 12 bytes, no NUL.
    const args = [_][]const u8{ if_arg, of_arg, "ibs=6", "obs=6", "cbs=6", "conv=sync,block", "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const content = try tmp_dir.dir.readFileAlloc(io, "output.bin", testing.allocator, .unlimited);
    defer testing.allocator.free(content);

    // The output should contain NO NUL bytes - all padding should be spaces
    for (content) |byte| {
        try testing.expect(byte != 0);
    }
}

test "audit: conv=ibm produces different output than conv=ebcdic for caret" {
    // Audit finding: conv=ibm EBCDIC variant table not distinct from conv=ebcdic.
    // GNU dd produces different output for '^' (0x5E):
    //   conv=ebcdic: '^' -> 0x9A
    //   conv=ibm:    '^' -> 0x5F
    // Our implementation has the tables present but they may not match GNU.
    // This test verifies against GNU's expected mapping.

    // Test ebcdic mapping for '^'
    var ebcdic_buf = [_]u8{'^'};
    applyConversions(&ebcdic_buf, .{ .conv_ebcdic = true });

    // Test ibm mapping for '^'
    var ibm_buf = [_]u8{'^'};
    applyConversions(&ibm_buf, .{ .conv_ibm = true });

    // The two conversions must produce DIFFERENT results for '^'
    // GNU dd: ebcdic maps '^' to 0x9A, ibm maps '^' to 0x5F
    try testing.expect(ebcdic_buf[0] != ibm_buf[0]);
    try testing.expectEqual(@as(u8, 0x9A), ebcdic_buf[0]);
    try testing.expectEqual(@as(u8, 0x5F), ibm_buf[0]);
}

// Audit G5: dd parses conv=sparse, conv=par{even,none,odd,set}, and
// the files=N operand but never applies them. The audit calls for
// rejecting these at parse time so users are not silently misled.
// These tests assert each operand is rejected at parse time with a
// non-zero exit status and a diagnostic on stderr that names the
// offending operand. We always provide if=/of= so the bug-path copy
// loop has a controlled, finite stdin replacement (no hang on real
// stdin if the parser silently accepts the operand).

/// Run dd with a single unsupported operand against a real tmp input file
/// and assert misuse exit (2) with `expected_needle` in stderr.
fn expectDdRejectsOperand(operand: []const u8, expected_needle: []const u8) !void {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(io, tmp_dir.dir, "input.txt", "hello");

    const input_path = try tmp_dir.dir.realPathFileAlloc(io, "input.txt", testing.allocator);
    defer testing.allocator.free(input_path);
    const base_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.bin", .{base_path});
    defer testing.allocator.free(output_path);

    const if_arg = try std.fmt.allocPrint(testing.allocator, "if={s}", .{input_path});
    defer testing.allocator.free(if_arg);
    const of_arg = try std.fmt.allocPrint(testing.allocator, "of={s}", .{output_path});
    defer testing.allocator.free(of_arg);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ if_arg, of_arg, operand, "status=none" };
    const exit_code = try runDd(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), expected_needle) != null);
}

test "audit G5: runDd rejects conv=sparse with diagnostic" {
    try expectDdRejectsOperand("conv=sparse", "sparse");
}

test "audit G5: runDd rejects conv=pareven with diagnostic" {
    try expectDdRejectsOperand("conv=pareven", "pareven");
}

test "audit G5: runDd rejects conv=parnone with diagnostic" {
    try expectDdRejectsOperand("conv=parnone", "parnone");
}

test "audit G5: runDd rejects conv=parodd with diagnostic" {
    try expectDdRejectsOperand("conv=parodd", "parodd");
}

test "audit G5: runDd rejects conv=parset with diagnostic" {
    try expectDdRejectsOperand("conv=parset", "parset");
}

test "audit G5: runDd rejects files= operand with diagnostic" {
    try expectDdRejectsOperand("files=3", "files");
}
