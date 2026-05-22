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
    conv_sparse: bool = false,
    conv_pareven: bool = false,
    conv_parnone: bool = false,
    conv_parodd: bool = false,
    conv_parset: bool = false,
    cbs: ?usize = null,
    fillchar: u8 = ' ',
    files: usize = 1,
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
            } else if (std.mem.eql(u8, key, "cbs")) {
                config.cbs = try parseByteSize(value);
            } else if (std.mem.eql(u8, key, "files")) {
                config.files = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "conv")) {
                try parseConversions(&config, value);
            } else if (std.mem.eql(u8, key, "iseek")) {
                // Alias for skip
                config.skip = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "oseek")) {
                // Alias for seek
                config.seek = std.fmt.parseInt(usize, value, 10) catch
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
                _ = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidValue;
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
        } else if (std.mem.eql(u8, conv, "sparse")) {
            config.conv_sparse = true;
        } else if (std.mem.eql(u8, conv, "pareven")) {
            config.conv_pareven = true;
        } else if (std.mem.eql(u8, conv, "parnone")) {
            config.conv_parnone = true;
        } else if (std.mem.eql(u8, conv, "parodd")) {
            config.conv_parodd = true;
        } else if (std.mem.eql(u8, conv, "parset")) {
            config.conv_parset = true;
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
        \\  files=N         copy and concatenate N input files (default: 1)
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

/// Execute the dd copy operation
pub fn runDd(allocator: Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!u8 {
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

    // lcase and ucase are mutually exclusive
    if (config.conv_lcase and config.conv_ucase) {
        common.printErrorWithProgram(allocator, stderr, "dd", "conv=lcase and conv=ucase are mutually exclusive", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // ascii, ebcdic, and ibm are mutually exclusive
    const charset_count = @as(u8, @intFromBool(config.conv_ascii)) +
        @as(u8, @intFromBool(config.conv_ebcdic)) +
        @as(u8, @intFromBool(config.conv_ibm));
    if (charset_count > 1) {
        common.printErrorWithProgram(allocator, stderr, "dd", "conv=ascii, conv=ebcdic, and conv=ibm are mutually exclusive", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // block and unblock are mutually exclusive
    if (config.conv_block and config.conv_unblock) {
        common.printErrorWithProgram(allocator, stderr, "dd", "conv=block and conv=unblock are mutually exclusive", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // block and unblock require cbs
    if ((config.conv_block or config.conv_unblock) and config.cbs == null) {
        common.printErrorWithProgram(allocator, stderr, "dd", "conv=block/unblock requires cbs operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Determine effective block sizes
    const ibs = if (config.bs) |bs| bs else config.ibs;
    const obs = if (config.bs) |bs| bs else config.obs;

    if (ibs == 0 or obs == 0) {
        common.printErrorWithProgram(allocator, stderr, "dd", "block size cannot be zero", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Allocate input and output buffers
    const in_buf = allocator.alloc(u8, ibs) catch {
        common.printErrorWithProgram(allocator, stderr, "dd", "failed to allocate input buffer", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(in_buf);

    const out_buf = allocator.alloc(u8, obs) catch {
        common.printErrorWithProgram(allocator, stderr, "dd", "failed to allocate output buffer", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(out_buf);

    // Open input
    const input_file: std.Io.File = if (config.input_file) |path| blk: {
        break :blk std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "{s}: {s}", .{ path, common.posixErrorString(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
    } else std.Io.File.stdin();
    defer if (config.input_file != null) input_file.close(io);

    // Open output
    const output_file: std.Io.File = if (config.output_file) |path| blk: {
        const flags: std.Io.File.CreateFlags = .{
            .truncate = !config.conv_notrunc,
        };
        break :blk std.Io.Dir.cwd().createFile(io, path, flags) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "{s}: {s}", .{ path, common.posixErrorString(err) });
            return @intFromEnum(common.ExitCode.general_error);
        };
    } else std.Io.File.stdout();
    defer if (config.output_file != null) output_file.close(io);

    // Skip input blocks
    if (config.skip > 0) {
        var skipped: usize = 0;
        while (skipped < config.skip) : (skipped += 1) {
            _ = input_file.readStreaming(io, &.{in_buf}) catch |err| switch (err) {
                error.EndOfStream => break, // EOF before all skips done
                else => {
                    common.printErrorWithProgram(allocator, stderr, "dd", "error skipping input: {s}", .{common.posixErrorString(err)});
                    return @intFromEnum(common.ExitCode.general_error);
                },
            };
        }
    }

    // Seek output blocks
    if (config.seek > 0) {
        const seek_bytes = config.seek * obs;
        io.vtable.fileSeekTo(io.userdata, output_file, seek_bytes) catch {
            // If seeking fails (e.g., stdout), try writing zeros
            var seeked: usize = 0;
            @memset(out_buf, 0);
            while (seeked < config.seek) : (seeked += 1) {
                output_file.writeStreamingAll(io, out_buf) catch |write_err| {
                    common.printErrorWithProgram(allocator, stderr, "dd", "error seeking output: {s}", .{common.posixErrorString(write_err)});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            }
        };
    }

    // Allocate block/unblock conversion buffer if needed
    const cbs = config.cbs orelse 0;
    var cbs_buf: ?[]u8 = null;
    var cbs_pos: usize = 0;
    if (config.conv_block) {
        cbs_buf = allocator.alloc(u8, cbs) catch {
            common.printErrorWithProgram(allocator, stderr, "dd", "failed to allocate cbs buffer", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
    }
    defer if (cbs_buf) |b| allocator.free(b);

    var stats = DdStats{
        .start_ns = std.Io.Timestamp.now(io, .real).nanoseconds,
    };

    // Use simple copy mode when bs= is set and no block/unblock conversion
    const simple_copy = config.bs != null and !config.conv_block and !config.conv_unblock;

    // Main copy loop
    var out_pos: usize = 0; // Current position in output buffer (for non-simple mode)
    var blocks_read: usize = 0;

    // Unblock position tracker: position within current cbs-sized record
    var unblock_pos: usize = 0;

    while (true) {
        // Check count limit
        if (config.count) |count| {
            if (blocks_read >= count) break;
        }

        // Read one input block
        const bytes_read = input_file.readStreaming(io, &.{in_buf}) catch |err| switch (err) {
            error.EndOfStream => break, // EOF
            else => {
                if (config.conv_noerror) {
                    // Continue after read errors
                    common.printErrorWithProgram(allocator, stderr, "dd", "read error: {s}", .{common.posixErrorString(err)});
                    if (config.conv_sync) {
                        // Fill with NULs when sync is specified
                        @memset(in_buf, 0);
                        // Count as a full block
                        stats.full_blocks_in += 1;
                        blocks_read += 1;
                        if (simple_copy) {
                            // Write the NUL-filled block
                            output_file.writeStreamingAll(io, in_buf) catch |werr| {
                                common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(werr)});
                                return @intFromEnum(common.ExitCode.general_error);
                            };
                            stats.full_blocks_out += 1;
                            stats.bytes_copied += ibs;
                        }
                    }
                    continue;
                }
                common.printErrorWithProgram(allocator, stderr, "dd", "read error: {s}", .{common.posixErrorString(err)});
                printStats(io, stderr, stats, config.status);
                return @intFromEnum(common.ExitCode.general_error);
            },
        };

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
        // GNU dd pads with spaces when conv=block or conv=unblock is active,
        // and with NUL bytes otherwise.
        if (config.conv_sync and bytes_read < ibs) {
            const pad_byte: u8 = if (config.conv_block or config.conv_unblock) ' ' else 0;
            @memset(in_buf[bytes_read..], pad_byte);
            data = in_buf[0..ibs];
        }

        // Apply conversions (swab, charset, case)
        applyConversions(data, config);

        // Handle conv=block: convert newline-terminated records to fixed-size
        if (config.conv_block) {
            const record_buf = cbs_buf.?;
            for (data) |byte| {
                if (byte == '\n') {
                    // End of record: pad with fill character to cbs and write
                    if (cbs_pos < cbs) {
                        @memset(record_buf[cbs_pos..], config.fillchar);
                    }
                    output_file.writeStreamingAll(io, record_buf[0..cbs]) catch |err| {
                        common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
                        printStats(io, stderr, stats, config.status);
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    stats.bytes_copied += cbs;
                    stats.full_blocks_out += 1;
                    cbs_pos = 0;
                } else {
                    // Accumulate byte into record (truncate if > cbs)
                    if (cbs_pos < cbs) {
                        record_buf[cbs_pos] = byte;
                        cbs_pos += 1;
                    }
                }
            }
            continue;
        }

        // Handle conv=unblock: convert fixed-size records to newline-terminated
        if (config.conv_unblock) {
            // Process data in cbs-sized chunks
            var data_pos: usize = 0;
            while (data_pos < data.len) {
                const remaining_in_record = cbs - unblock_pos;
                const remaining_in_data = data.len - data_pos;
                const to_consume = @min(remaining_in_record, remaining_in_data);

                // Copy bytes into output buffer temporarily
                @memcpy(out_buf[unblock_pos..][0..to_consume], data[data_pos..][0..to_consume]);
                unblock_pos += to_consume;
                data_pos += to_consume;

                if (unblock_pos == cbs) {
                    // Complete record: strip trailing spaces and add newline
                    var end: usize = cbs;
                    while (end > 0 and out_buf[end - 1] == ' ') : (end -= 1) {}
                    output_file.writeStreamingAll(io, out_buf[0..end]) catch |err| {
                        common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
                        printStats(io, stderr, stats, config.status);
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    output_file.writeStreamingAll(io, "\n") catch |err| {
                        common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
                        printStats(io, stderr, stats, config.status);
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    stats.bytes_copied += end + 1;
                    stats.full_blocks_out += 1;
                    unblock_pos = 0;
                }
            }
            continue;
        }

        if (simple_copy) {
            // Simple copy: write each input block directly as output
            if (config.conv_osync and data.len < obs) {
                // Pad partial block to obs size with NULs
                @memcpy(out_buf[0..data.len], data);
                @memset(out_buf[data.len..obs], 0);
                output_file.writeStreamingAll(io, out_buf[0..obs]) catch |err| {
                    common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
                    printStats(io, stderr, stats, config.status);
                    return @intFromEnum(common.ExitCode.general_error);
                };
                stats.bytes_copied += obs;
                stats.full_blocks_out += 1;
            } else {
                output_file.writeStreamingAll(io, data) catch |err| {
                    common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
                    printStats(io, stderr, stats, config.status);
                    return @intFromEnum(common.ExitCode.general_error);
                };
                stats.bytes_copied += data.len;
                if (data.len == obs) {
                    stats.full_blocks_out += 1;
                } else {
                    stats.partial_blocks_out += 1;
                }
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
                    output_file.writeStreamingAll(io, out_buf[0..obs]) catch |err| {
                        common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
                        printStats(io, stderr, stats, config.status);
                        return @intFromEnum(common.ExitCode.general_error);
                    };
                    stats.full_blocks_out += 1;
                    stats.bytes_copied += obs;
                    out_pos = 0;
                }
            }
        }
    }

    // Flush remaining record for conv=block (partial record without newline)
    if (config.conv_block and cbs_pos > 0) {
        const record_buf = cbs_buf.?;
        @memset(record_buf[cbs_pos..], config.fillchar);
        output_file.writeStreamingAll(io, record_buf[0..cbs]) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
            printStats(io, stderr, stats, config.status);
            return @intFromEnum(common.ExitCode.general_error);
        };
        stats.bytes_copied += cbs;
        stats.partial_blocks_out += 1;
    }

    // Flush remaining data for conv=unblock (partial record)
    if (config.conv_unblock and unblock_pos > 0) {
        var end: usize = unblock_pos;
        while (end > 0 and out_buf[end - 1] == ' ') : (end -= 1) {}
        output_file.writeStreamingAll(io, out_buf[0..end]) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
            printStats(io, stderr, stats, config.status);
            return @intFromEnum(common.ExitCode.general_error);
        };
        output_file.writeStreamingAll(io, "\n") catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
            printStats(io, stderr, stats, config.status);
            return @intFromEnum(common.ExitCode.general_error);
        };
        stats.bytes_copied += end + 1;
        stats.partial_blocks_out += 1;
    }

    // Flush remaining data in output buffer (non-simple mode, non-block/unblock)
    if (!simple_copy and !config.conv_block and !config.conv_unblock and out_pos > 0) {
        const write_len = if (config.conv_osync) blk: {
            // Pad the final block to obs size with NULs
            @memset(out_buf[out_pos..obs], 0);
            break :blk obs;
        } else out_pos;
        output_file.writeStreamingAll(io, out_buf[0..write_len]) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "write error: {s}", .{common.posixErrorString(err)});
            printStats(io, stderr, stats, config.status);
            return @intFromEnum(common.ExitCode.general_error);
        };
        if (config.conv_osync) {
            stats.full_blocks_out += 1;
            stats.bytes_copied += obs;
        } else {
            stats.partial_blocks_out += 1;
            stats.bytes_copied += out_pos;
        }
    }

    // fsync the output file if requested
    if (config.conv_fsync) {
        output_file.sync(io) catch |err| {
            common.printErrorWithProgram(allocator, stderr, "dd", "fsync error: {s}", .{common.posixErrorString(err)});
            return @intFromEnum(common.ExitCode.general_error);
        };
    }

    // Print statistics
    printStats(io, stderr, stats, config.status);

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
    try testing.expect(!config.conv_sparse);
    try testing.expect(!config.conv_pareven);
    try testing.expect(!config.conv_parnone);
    try testing.expect(!config.conv_parodd);
    try testing.expect(!config.conv_parset);
    try testing.expect(config.cbs == null);
    try testing.expectEqual(@as(u8, ' '), config.fillchar);
    try testing.expectEqual(@as(usize, 1), config.files);
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

test "parseOperands - files operand" {
    const args = [_][]const u8{"files=3"};
    const config = try parseOperands(&args);
    try testing.expectEqual(@as(usize, 3), config.files);
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

test "parseConversions - sparse accepted as no-op" {
    const args = [_][]const u8{"conv=sparse"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_sparse);
}

test "parseConversions - pareven accepted as no-op" {
    const args = [_][]const u8{"conv=pareven"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_pareven);
}

test "parseConversions - parnone accepted as no-op" {
    const args = [_][]const u8{"conv=parnone"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_parnone);
}

test "parseConversions - parodd accepted as no-op" {
    const args = [_][]const u8{"conv=parodd"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_parodd);
}

test "parseConversions - parset accepted as no-op" {
    const args = [_][]const u8{"conv=parset"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_parset);
}

test "parseConversions - multiple parity and sparse" {
    const args = [_][]const u8{"conv=sparse,pareven,lcase"};
    const config = try parseOperands(&args);
    try testing.expect(config.conv_sparse);
    try testing.expect(config.conv_pareven);
    try testing.expect(config.conv_lcase);
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
