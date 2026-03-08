//! date - print or set the system date and time
//!
//! The date utility displays the current date and time, formatted according to
//! the specified format string. It supports UTC output, reference file timestamps,
//! and parsing date strings including epoch seconds.
//!
//! This implementation follows GNU coreutils date behavior with support for
//! RFC 5322, RFC 3339, and ISO 8601 output formats.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const TimestampResult = struct { secs: i64, ns: i64, err: ?[]const u8 };

// ============================================================================
// Libc bindings for time functions
// ============================================================================

const c = std.c;

const c_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

extern "c" fn localtime_r(timer: *const c.time_t, result: *c_tm) ?*c_tm;
extern "c" fn gmtime_r(timer: *const c.time_t, result: *c_tm) ?*c_tm;
extern "c" fn strftime(s: [*]u8, maxsize: usize, format: [*:0]const u8, tp: *const c_tm) usize;
extern "c" fn mktime(tp: *c_tm) c.time_t;

// ============================================================================
// Date utility implementation
// ============================================================================

const prog_name = "date";

/// Parsed command-line options for the date utility
const DateOptions = struct {
    utc: bool = false,
    rfc_email: bool = false,
    rfc_3339: ?[]const u8 = null,
    iso_8601: ?[]const u8 = null,
    date_string: ?[]const u8 = null,
    reference_file: ?[]const u8 = null,
    format: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
};

/// Parse command-line arguments manually (date has unusual flag semantics)
fn parseArgs(args: []const []const u8) struct { opts: DateOptions, err: ?[]const u8 } {
    var opts = DateOptions{};
    var err_msg: ?[]const u8 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len == 0) continue;

        // Format string starts with +
        if (arg[0] == '+') {
            opts.format = arg[1..];
            continue;
        }

        // Not a flag
        if (arg[0] != '-') {
            err_msg = "extra operand";
            break;
        }

        // Long options
        if (arg.len > 1 and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                opts.help = true;
                return .{ .opts = opts, .err = null };
            } else if (std.mem.eql(u8, arg, "--version")) {
                opts.version = true;
                return .{ .opts = opts, .err = null };
            } else if (std.mem.eql(u8, arg, "--utc") or std.mem.eql(u8, arg, "--universal")) {
                opts.utc = true;
            } else if (std.mem.startsWith(u8, arg, "--rfc-3339=")) {
                opts.rfc_3339 = arg["--rfc-3339=".len..];
            } else if (std.mem.eql(u8, arg, "--rfc-3339")) {
                // Needs a value as the next argument
                if (i + 1 < args.len) {
                    i += 1;
                    opts.rfc_3339 = args[i];
                } else {
                    err_msg = "option '--rfc-3339' requires an argument";
                    break;
                }
            } else if (std.mem.eql(u8, arg, "--rfc-email")) {
                opts.rfc_email = true;
            } else if (std.mem.startsWith(u8, arg, "--date=")) {
                opts.date_string = arg["--date=".len..];
            } else if (std.mem.eql(u8, arg, "--date")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.date_string = args[i];
                } else {
                    err_msg = "option '--date' requires an argument";
                    break;
                }
            } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                opts.reference_file = arg["--reference=".len..];
            } else if (std.mem.eql(u8, arg, "--reference")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.reference_file = args[i];
                } else {
                    err_msg = "option '--reference' requires an argument";
                    break;
                }
            } else if (std.mem.startsWith(u8, arg, "--iso-8601")) {
                if (std.mem.startsWith(u8, arg, "--iso-8601=")) {
                    opts.iso_8601 = arg["--iso-8601=".len..];
                } else {
                    opts.iso_8601 = "date";
                }
            } else {
                err_msg = "unrecognized option";
                break;
            }
            continue;
        }

        // Short options
        const flags = arg[1..];
        var j: usize = 0;
        while (j < flags.len) : (j += 1) {
            switch (flags[j]) {
                'u' => opts.utc = true,
                'R' => opts.rfc_email = true,
                'h' => {
                    opts.help = true;
                    return .{ .opts = opts, .err = null };
                },
                'V' => {
                    opts.version = true;
                    return .{ .opts = opts, .err = null };
                },
                'd' => {
                    // -d takes the rest of this arg or next arg
                    if (j + 1 < flags.len) {
                        opts.date_string = flags[j + 1 ..];
                        j = flags.len; // consume rest
                    } else if (i + 1 < args.len) {
                        i += 1;
                        opts.date_string = args[i];
                    } else {
                        err_msg = "option '-d' requires an argument";
                        return .{ .opts = opts, .err = err_msg };
                    }
                },
                'r' => {
                    // -r takes the rest of this arg or next arg
                    if (j + 1 < flags.len) {
                        opts.reference_file = flags[j + 1 ..];
                        j = flags.len; // consume rest
                    } else if (i + 1 < args.len) {
                        i += 1;
                        opts.reference_file = args[i];
                    } else {
                        err_msg = "option '-r' requires an argument";
                        return .{ .opts = opts, .err = err_msg };
                    }
                },
                'I' => {
                    // -I with optional attached value: -Iseconds, -Idate, etc.
                    if (j + 1 < flags.len) {
                        opts.iso_8601 = flags[j + 1 ..];
                        j = flags.len; // consume rest
                    } else {
                        opts.iso_8601 = "date";
                    }
                },
                else => {
                    err_msg = "unrecognized option";
                    return .{ .opts = opts, .err = err_msg };
                },
            }
        }
    }

    return .{ .opts = opts, .err = err_msg };
}

/// Resolve the timestamp to use based on options
fn resolveTimestamp(opts: DateOptions) TimestampResult {
    if (opts.date_string) |ds| {
        // Parse @EPOCH format
        if (ds.len > 0 and ds[0] == '@') {
            const epoch_str = ds[1..];
            // Check for fractional seconds
            if (std.mem.indexOfScalar(u8, epoch_str, '.')) |dot_pos| {
                const secs_str = epoch_str[0..dot_pos];
                const frac_str = epoch_str[dot_pos + 1 ..];
                const secs = std.fmt.parseInt(i64, secs_str, 10) catch {
                    return .{ .secs = 0, .ns = 0, .err = "invalid date" };
                };
                // Parse fractional part as nanoseconds
                var ns: i64 = 0;
                var multiplier: i64 = 100_000_000; // start at 10^8
                for (frac_str) |ch| {
                    if (ch < '0' or ch > '9') break;
                    ns += @as(i64, ch - '0') * multiplier;
                    multiplier = @divTrunc(multiplier, 10);
                    if (multiplier == 0) break;
                }
                return .{ .secs = secs, .ns = ns, .err = null };
            } else {
                const secs = std.fmt.parseInt(i64, epoch_str, 10) catch {
                    return .{ .secs = 0, .ns = 0, .err = "invalid date" };
                };
                return .{ .secs = secs, .ns = 0, .err = null };
            }
        }
        // Try ISO 8601 format: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS
        return parseIso8601(ds);
    }

    if (opts.reference_file) |ref| {
        const stat = std.fs.cwd().statFile(ref) catch {
            return .{ .secs = 0, .ns = 0, .err = "cannot stat reference file" };
        };
        const mtime_ns = stat.mtime;
        const secs: i64 = @intCast(@divTrunc(mtime_ns, std.time.ns_per_s));
        const ns: i64 = @intCast(@mod(mtime_ns, std.time.ns_per_s));
        return .{ .secs = secs, .ns = ns, .err = null };
    }

    // Current time
    const now_ns = std.time.nanoTimestamp();
    const secs: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
    const ns: i64 = @intCast(@mod(now_ns, std.time.ns_per_s));
    return .{ .secs = secs, .ns = ns, .err = null };
}

/// Parse a simple ISO 8601 date string into epoch seconds
fn parseIso8601(ds: []const u8) TimestampResult {
    const err_result: TimestampResult = .{ .secs = 0, .ns = 0, .err = "invalid date" };

    // Minimum: YYYY-MM-DD (10 chars)
    if (ds.len < 10) return err_result;

    // Validate separators
    if (ds[4] != '-' or ds[7] != '-') return err_result;

    const year = std.fmt.parseInt(i32, ds[0..4], 10) catch return err_result;
    const month = std.fmt.parseInt(i32, ds[5..7], 10) catch return err_result;
    const day = std.fmt.parseInt(i32, ds[8..10], 10) catch return err_result;

    if (month < 1 or month > 12) return err_result;
    if (day < 1 or day > 31) return err_result;

    var hour: i32 = 0;
    var minute: i32 = 0;
    var second: i32 = 0;

    // Parse optional time component
    if (ds.len > 10) {
        if (ds[10] != 'T' and ds[10] != ' ') return err_result;
        const time_str = ds[11..];
        if (time_str.len < 5) return err_result;
        if (time_str[2] != ':') return err_result;

        hour = std.fmt.parseInt(i32, time_str[0..2], 10) catch return err_result;
        minute = std.fmt.parseInt(i32, time_str[3..5], 10) catch return err_result;

        if (time_str.len >= 8 and time_str[5] == ':') {
            second = std.fmt.parseInt(i32, time_str[6..8], 10) catch return err_result;
        }
    }

    // Convert to epoch via mktime
    var tm = c_tm{
        .tm_sec = @intCast(second),
        .tm_min = @intCast(minute),
        .tm_hour = @intCast(hour),
        .tm_mday = @intCast(day),
        .tm_mon = @intCast(month - 1),
        .tm_year = @intCast(year - 1900),
        .tm_wday = 0,
        .tm_yday = 0,
        .tm_isdst = -1,
        .tm_gmtoff = 0,
        .tm_zone = "UTC",
    };

    const result = mktime(&tm);
    if (result == -1) return err_result;

    return .{ .secs = @intCast(result), .ns = 0, .err = null };
}

/// Determine the format string based on options
fn getFormatString(opts: DateOptions) []const u8 {
    if (opts.format) |fmt| {
        return fmt;
    }
    if (opts.rfc_email) {
        return "%a, %d %b %Y %H:%M:%S %z";
    }
    if (opts.rfc_3339) |precision| {
        if (std.mem.eql(u8, precision, "date")) {
            return "%Y-%m-%d";
        } else if (std.mem.eql(u8, precision, "seconds")) {
            return "%Y-%m-%d %H:%M:%S%:z";
        } else if (std.mem.eql(u8, precision, "ns")) {
            return "%Y-%m-%d %H:%M:%S.%N%:z";
        }
        // Invalid precision will be caught in validation
        return "%Y-%m-%d";
    }
    if (opts.iso_8601) |precision| {
        if (std.mem.eql(u8, precision, "date")) {
            return "%Y-%m-%d";
        } else if (std.mem.eql(u8, precision, "hours")) {
            return "%Y-%m-%dT%H%:z";
        } else if (std.mem.eql(u8, precision, "minutes")) {
            return "%Y-%m-%dT%H:%M%:z";
        } else if (std.mem.eql(u8, precision, "seconds")) {
            return "%Y-%m-%dT%H:%M:%S%:z";
        } else if (std.mem.eql(u8, precision, "ns")) {
            return "%Y-%m-%dT%H:%M:%S,%N%:z";
        }
        // Default for -I with no argument
        return "%Y-%m-%d";
    }
    // Default format
    return "%a %b %e %H:%M:%S %Z %Y";
}

/// Validate rfc-3339 and iso-8601 precision values
fn validatePrecision(opts: DateOptions) ?[]const u8 {
    if (opts.rfc_3339) |precision| {
        if (!std.mem.eql(u8, precision, "date") and
            !std.mem.eql(u8, precision, "seconds") and
            !std.mem.eql(u8, precision, "ns"))
        {
            return "invalid argument for '--rfc-3339'";
        }
    }
    if (opts.iso_8601) |precision| {
        if (!std.mem.eql(u8, precision, "date") and
            !std.mem.eql(u8, precision, "hours") and
            !std.mem.eql(u8, precision, "minutes") and
            !std.mem.eql(u8, precision, "seconds") and
            !std.mem.eql(u8, precision, "ns"))
        {
            return "invalid argument for '--iso-8601'";
        }
    }
    return null;
}

/// Format a timezone offset as +HH:MM (colon-separated)
fn formatTzOffset(buf: []u8, tm: *const c_tm) []const u8 {
    const offset_secs = tm.tm_gmtoff;
    const abs_offset: u64 = if (offset_secs < 0) @intCast(-offset_secs) else @intCast(offset_secs);
    const sign: u8 = if (offset_secs < 0) '-' else '+';
    const hours = @divTrunc(abs_offset, 3600);
    const minutes = @divTrunc(@mod(abs_offset, 3600), 60);

    const len = std.fmt.bufPrint(buf, "{c}{d:0>2}:{d:0>2}", .{
        sign,
        hours,
        minutes,
    }) catch return "+00:00";
    return len;
}

/// Format the time using strftime and handle custom specifiers (%N, %s, %:z)
fn formatDate(
    allocator: Allocator,
    format: []const u8,
    tm: *const c_tm,
    epoch_secs: i64,
    ns: i64,
) ![]const u8 {
    // Pre-process format string to replace custom specifiers
    // We handle: %N (nanoseconds), %s (epoch seconds), %:z (timezone +HH:MM),
    //            %% (literal %), %n (newline), %t (tab)
    var processed = try std.ArrayList(u8).initCapacity(allocator, format.len);
    defer processed.deinit(allocator);

    var tz_buf: [8]u8 = undefined;

    var fi: usize = 0;
    while (fi < format.len) {
        if (format[fi] == '%' and fi + 1 < format.len) {
            const next = format[fi + 1];
            switch (next) {
                's' => {
                    // Epoch seconds - format directly
                    var secs_buf: [24]u8 = undefined;
                    const secs_str = std.fmt.bufPrint(&secs_buf, "{d}", .{epoch_secs}) catch "0";
                    try processed.appendSlice(allocator, secs_str);
                    fi += 2;
                },
                'N' => {
                    // Nanoseconds - 9-digit zero-padded
                    var ns_buf: [16]u8 = undefined;
                    const abs_ns: u64 = if (ns < 0) @intCast(-ns) else @intCast(ns);
                    const ns_str = std.fmt.bufPrint(&ns_buf, "{d:0>9}", .{abs_ns}) catch "000000000";
                    try processed.appendSlice(allocator, ns_str);
                    fi += 2;
                },
                'z' => {
                    // Numeric timezone offset without colon (+HHMM)
                    // Handle directly to ensure tm_gmtoff is respected (macOS strftime bug)
                    const offset_secs = tm.tm_gmtoff;
                    const abs_offset: u64 = if (offset_secs < 0) @intCast(-offset_secs) else @intCast(offset_secs);
                    const sign: u8 = if (offset_secs < 0) '-' else '+';
                    const hours = @divTrunc(abs_offset, 3600);
                    const minutes = @divTrunc(@mod(abs_offset, 3600), 60);
                    const tz_str = std.fmt.bufPrint(&tz_buf, "{c}{d:0>2}{d:0>2}", .{
                        sign,
                        hours,
                        minutes,
                    }) catch "+0000";
                    try processed.appendSlice(allocator, tz_str);
                    fi += 2;
                },
                ':' => {
                    // Check for %:z (timezone with colon)
                    if (fi + 2 < format.len and format[fi + 2] == 'z') {
                        const tz_str = formatTzOffset(&tz_buf, tm);
                        try processed.appendSlice(allocator, tz_str);
                        fi += 3;
                    } else {
                        // Pass through unknown %: sequences
                        try processed.append(allocator, '%');
                        fi += 1;
                    }
                },
                '%' => {
                    // Literal % - pass through to strftime which handles %%
                    try processed.appendSlice(allocator, "%%");
                    fi += 2;
                },
                'n' => {
                    try processed.append(allocator, '\n');
                    fi += 2;
                },
                't' => {
                    try processed.append(allocator, '\t');
                    fi += 2;
                },
                else => {
                    // Pass through to strftime
                    try processed.append(allocator, '%');
                    try processed.append(allocator, next);
                    fi += 2;
                },
            }
        } else {
            try processed.append(allocator, format[fi]);
            fi += 1;
        }
    }

    // Null-terminate for strftime
    try processed.append(allocator, 0);
    const fmt_z: [*:0]const u8 = @ptrCast(processed.items.ptr);

    // Call strftime
    var output_buf: [8192]u8 = undefined;
    const len = strftime(&output_buf, output_buf.len, fmt_z, tm);

    if (len == 0 and processed.items.len > 1) {
        // strftime returned 0, could mean error or empty output
        // If format was non-empty, this is likely an error
        return allocator.dupe(u8, "");
    }

    return allocator.dupe(u8, output_buf[0..len]);
}

/// Main date utility logic
pub fn runDate(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed = parseArgs(args);
    if (parsed.err) |err_msg| {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "{s}", .{err_msg});
        return @intFromEnum(common.ExitCode.misuse);
    }
    const opts = parsed.opts;

    // Handle help
    if (opts.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (opts.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate precision arguments
    if (validatePrecision(opts)) |err_msg| {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "{s}", .{err_msg});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Resolve the timestamp to format
    const ts = resolveTimestamp(opts);
    if (ts.err) |err_msg| {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "{s}", .{err_msg});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Convert to broken-down time
    const time_secs: c.time_t = @intCast(ts.secs);
    var tm: c_tm = undefined;
    if (opts.utc) {
        if (gmtime_r(&time_secs, &tm) == null) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot convert time", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
    } else {
        if (localtime_r(&time_secs, &tm) == null) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot convert time", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
    }

    // Get format string
    const format = getFormatString(opts);

    // Format and output
    const output = try formatDate(allocator, format, &tm, ts.secs, ts.ns);
    defer allocator.free(output);

    try stdout_writer.writeAll(output);
    try stdout_writer.writeByte('\n');

    return @intFromEnum(common.ExitCode.success);
}

/// CLI entry point
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runDate(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: date [OPTION]... [+FORMAT]
        \\Display the current time in the given FORMAT, or set the system date.
        \\
        \\  -d, --date=STRING       display time described by STRING, not 'now'
        \\  -r, --reference=FILE    display the last modification time of FILE
        \\  -R, --rfc-email         output date and time in RFC 5322 format
        \\      --rfc-3339=FMT      output date/time in RFC 3339 format
        \\                           FMT='date', 'seconds', or 'ns'
        \\  -I[FMT], --iso-8601[=FMT]  output date/time in ISO 8601 format
        \\                           FMT='date','hours','minutes','seconds','ns'
        \\                           (default: 'date')
        \\  -u, --utc, --universal  print or set Coordinated Universal Time (UTC)
        \\  -h, --help              display this help and exit
        \\  -V, --version           output version information and exit
        \\
        \\FORMAT controls the output, with interpreted sequences:
        \\  %%   a literal %              %n   a newline
        \\  %t   a tab                    %s   seconds since 1970-01-01 00:00:00 UTC
        \\  %N   nanoseconds (000000000..999999999)
        \\  %Y   year                     %m   month (01..12)
        \\  %d   day of month (01..31)    %H   hour (00..23)
        \\  %M   minute (00..59)          %S   second (00..60)
        \\  %Z   timezone abbreviation    %z   +hhmm numeric timezone
        \\  %a   abbreviated weekday      %b   abbreviated month
        \\  %e   day of month, space padded
        \\
        \\Examples:
        \\  date                     Display current date and time
        \\  date -u                  Display current UTC date and time
        \\  date '+%Y-%m-%d'         Display date in YYYY-MM-DD format
        \\  date -d @0 -u            Display the epoch (1970-01-01)
        \\  date -R                  Display in RFC 5322 format
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("date ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS (using -u -d @EPOCH for deterministic results)
// ============================================================================

test "date default output is non-empty" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buffer.items.len > 0);
    // Should contain current year (20xx)
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "20") != null);
}

test "date +%Y outputs 4-digit year" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_buffer.items);
}

test "date +%Y-%m-%d outputs ISO date" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_buffer.items);
}

test "date +%H:%M:%S outputs time" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%H:%M:%S" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("00:00:00\n", stdout_buffer.items);
}

test "date -u outputs UTC" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%Z" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    // Accept either UTC or GMT timezone abbreviation (Linux systems vary)
    const stdout = stdout_buffer.items;
    try testing.expect(std.mem.eql(u8, stdout, "UTC\n") or std.mem.eql(u8, stdout, "GMT\n"));
}

test "date +%s outputs epoch seconds" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@86400", "+%s" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("86400\n", stdout_buffer.items);
}

test "date -R outputs RFC 5322 format" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "-R" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 +0000\n", stdout_buffer.items);
}

test "date +%% outputs literal percent" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%%" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("%\n", stdout_buffer.items);
}

test "date +%n outputs newline" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%n" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n\n", stdout_buffer.items);
}

test "date +%t outputs tab" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%t" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\n", stdout_buffer.items);
}

test "date -d @0 -u outputs epoch" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-d", "@0", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_buffer.items);
}

test "date -d @86400 -u outputs next day" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-d", "@86400", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-02\n", stdout_buffer.items);
}

test "date --help works" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: date") != null);
}

test "date --version works" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "date") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.name) != null);
}

test "date invalid flag returns exit code 2" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "date -d @EPOCH with full default format" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    // Accept either UTC or GMT timezone abbreviation (Linux systems vary)
    const stdout = stdout_buffer.items;
    try testing.expect(std.mem.eql(u8, stdout, "Thu Jan  1 00:00:00 UTC 1970\n") or
        std.mem.eql(u8, stdout, "Thu Jan  1 00:00:00 GMT 1970\n"));
}

test "date --rfc-3339=date with epoch" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "--rfc-3339=date" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_buffer.items);
}

test "date --rfc-3339=seconds with epoch" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "--rfc-3339=seconds" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01 00:00:00+00:00\n", stdout_buffer.items);
}

test "date --rfc-3339=ns with epoch" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "--rfc-3339=ns" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01 00:00:00.000000000+00:00\n", stdout_buffer.items);
}

test "date --rfc-3339 invalid precision" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--rfc-3339=invalid"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "date -I outputs ISO date" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "-I" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_buffer.items);
}

test "date -Iseconds outputs ISO with seconds" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "-Iseconds" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00\n", stdout_buffer.items);
}

test "date -Ihours outputs ISO with hours" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "-Ihours" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00+00:00\n", stdout_buffer.items);
}

test "date -Iminutes outputs ISO with minutes" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "-Iminutes" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00+00:00\n", stdout_buffer.items);
}

test "date -Ins outputs ISO with nanoseconds" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "-Ins" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00:00,000000000+00:00\n", stdout_buffer.items);
}

test "date -d with invalid epoch" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-d", "@notanumber" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -d missing argument" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-d"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "date -r missing argument" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-r"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
}

test "date +%N outputs nanoseconds" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "+%N" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("000000000\n", stdout_buffer.items);
}

test "date -d @EPOCH with specific time" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // 2000-01-01 00:00:00 UTC = 946684800
    const args = [_][]const u8{ "-u", "-d", "@946684800", "+%Y-%m-%d %H:%M:%S" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("2000-01-01 00:00:00\n", stdout_buffer.items);
}

test "date short flags -h" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-h"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: date") != null);
}

test "date short flags -V" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "date") != null);
}

test "date combined short flags -uR" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-uR", "-d", "@0" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 +0000\n", stdout_buffer.items);
}

test "date --date= form" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "--date=@0", "+%Y" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_buffer.items);
}

test "date --iso-8601 with no value" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "--iso-8601" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_buffer.items);
}

test "date --iso-8601=seconds" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-d", "@0", "--iso-8601=seconds" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00\n", stdout_buffer.items);
}

test "date -r with reference file" {
    // Create a temp file to use as reference
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write a file so it exists
    const file = try tmp_dir.dir.createFile("testfile", .{});
    file.close();

    // Get the path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/testfile", .{dir_path});
    defer testing.allocator.free(full_path);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-r", full_path, "+%Y" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    // Should output a valid 4-digit year
    try testing.expect(stdout_buffer.items.len >= 4);
    try testing.expect(stdout_buffer.items[0] >= '1' and stdout_buffer.items[0] <= '9');
}

test "date -r with nonexistent file" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-r", "/tmp/nonexistent_file_date_test_xyz" };
    const result = try runDate(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
}
