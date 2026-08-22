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
const time = common.time;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const TimestampResult = struct { secs: i64, ns: i64, err: ?[]const u8 };

const c = std.c;

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
    no_set_date: bool = false,
    input_fmt: ?[]const u8 = null,
    output_zone: ?[]const u8 = null,
    v_adjust: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
    extra_operand: ?[]const u8 = null,
    /// First positional operand (`+FORMAT` or a date string). A second
    /// positional is extra_operand. Applied after the option scan.
    positional: ?[]const u8 = null,
    /// True when date_string came from a positional, not `--date`/`-d`.
    /// GNU obsolete set-date does not use parse_datetime (`date -- @0`
    /// is invalid, while `date -d @0` is epoch).
    positional_date: bool = false,
};

/// Parse command-line arguments manually (date has unusual flag semantics)
fn parseArgs(args: []const []const u8) struct { opts: DateOptions, err: ?[]const u8 } {
    var opts = DateOptions{};
    var err_msg: ?[]const u8 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len == 0 or arg[0] != '-') {
            err_msg = parseArgs_takePositional(&opts, arg);
            if (err_msg != null) break;
            continue;
        }

        // Long options
        if (arg.len > 1 and arg[1] == '-') {
            // Help/version short-circuit parseArgs entirely; keep them here.
            if (std.mem.eql(u8, arg, "--help")) {
                opts.help = true;
                return .{ .opts = opts, .err = null };
            } else if (std.mem.eql(u8, arg, "--version")) {
                opts.version = true;
                return .{ .opts = opts, .err = null };
            }
            if (std.mem.eql(u8, arg, "--")) {
                err_msg = parseArgs_afterDashDash(args, &i, &opts);
                break;
            }
            if (parseArgs_longOption(arg, args, &i, &opts)) |msg| {
                err_msg = msg;
                break;
            }
            continue;
        }

        // Short options
        const flags = arg[1..];
        if (parseArgs_shortOption(flags, args, &i, &opts)) |msg| {
            err_msg = msg;
            break;
        }
        // -h/-V short-circuit parseArgs entirely; the helper signals via opts.
        if (opts.help or opts.version) {
            return .{ .opts = opts, .err = null };
        }
    }

    if (err_msg == null) err_msg = parseArgs_applyPositional(&opts);
    return .{ .opts = opts, .err = err_msg };
}

/// Record the first positional, or tag a second one as GNU extra operand.
fn parseArgs_takePositional(opts: *DateOptions, tok: []const u8) ?[]const u8 {
    std.debug.assert(opts.extra_operand == null);
    if (opts.positional != null) return parseArgs_setExtraOperand(opts, tok);
    opts.positional = tok;
    std.debug.assert(opts.positional != null);
    return null;
}

/// Map the first positional onto format (`+…`) or date_string. A leftover
/// non-`+` token after `--date`/`-r` is GNU "lacks a leading '+'".
fn parseArgs_applyPositional(opts: *DateOptions) ?[]const u8 {
    std.debug.assert(opts.extra_operand == null);
    const tok = opts.positional orelse return null;
    if (tok.len > 0 and tok[0] == '+') {
        opts.format = tok[1..];
        return null;
    }
    if (opts.date_string != null or opts.reference_file != null) {
        opts.extra_operand = tok;
        std.debug.assert(opts.extra_operand != null);
        return "lacks plus";
    }
    opts.date_string = tok;
    opts.positional_date = true;
    std.debug.assert(opts.positional_date);
    return null;
}

/// Record `operand` as GNU's extra-operand token and return the err tag
/// parseArgs / runDate use to select the quoted diagnostic.
fn parseArgs_setExtraOperand(opts: *DateOptions, operand: []const u8) []const u8 {
    std.debug.assert(opts.extra_operand == null);
    opts.extra_operand = operand;
    std.debug.assert(opts.extra_operand != null);
    return "extra operand";
}

/// Drain argv after a POSIX `--`. Every remaining token is a positional
/// operand, including empty strings and dash-tokens (`date -- -1`).
fn parseArgs_afterDashDash(
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch cursor indexes args slice
    opts: *DateOptions,
) ?[]const u8 {
    std.debug.assert(i.* < args.len);
    std.debug.assert(std.mem.eql(u8, args[i.*], "--"));
    i.* += 1;
    while (i.* < args.len) : (i.* += 1) {
        if (parseArgs_takePositional(opts, args[i.*])) |msg| return msg;
    }
    return null;
}

/// Parse a single long option (`--`-prefixed), excluding `--help`/`--version`
/// which short-circuit parseArgs. Mutates opts, advances the cursor for
/// next-arg cases, and returns an error string or null.
fn parseArgs_longOption(
    arg: []const u8,
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch cursor indexes args slice (usize required)
    opts: *DateOptions,
) ?[]const u8 {
    std.debug.assert(arg.len > 1);
    std.debug.assert(arg[0] == '-');
    std.debug.assert(arg[1] == '-');
    std.debug.assert(i.* < args.len);
    std.debug.assert(args.len > 0);

    if (std.mem.eql(u8, arg, "--utc") or std.mem.eql(u8, arg, "--universal")) {
        opts.utc = true;
    } else if (std.mem.startsWith(u8, arg, "--rfc-3339=")) {
        opts.rfc_3339 = arg["--rfc-3339=".len..];
    } else if (std.mem.eql(u8, arg, "--rfc-3339")) {
        // Needs a value as the next argument
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.rfc_3339 = args[i.*];
        } else {
            return "option '--rfc-3339' requires an argument";
        }
    } else if (std.mem.eql(u8, arg, "--rfc-email")) {
        opts.rfc_email = true;
    } else if (std.mem.startsWith(u8, arg, "--date=")) {
        opts.date_string = arg["--date=".len..];
    } else if (std.mem.eql(u8, arg, "--date")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.date_string = args[i.*];
        } else {
            return "option '--date' requires an argument";
        }
    } else if (std.mem.startsWith(u8, arg, "--reference=")) {
        opts.reference_file = arg["--reference=".len..];
    } else if (std.mem.eql(u8, arg, "--reference")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            opts.reference_file = args[i.*];
        } else {
            return "option '--reference' requires an argument";
        }
    } else if (std.mem.startsWith(u8, arg, "--iso-8601")) {
        if (std.mem.startsWith(u8, arg, "--iso-8601=")) {
            opts.iso_8601 = arg["--iso-8601=".len..];
        } else {
            opts.iso_8601 = "date";
        }
    } else {
        return "unrecognized option";
    }
    return null;
}

/// Parse a run of short option flags (the chars after a single `-`). Mutates
/// opts, advances the arg cursor for next-arg cases, and returns an error
/// string or null. Help/version are signalled via opts.help/opts.version so
/// the parent can reproduce the immediate exit.
fn parseArgs_shortOption(
    flags: []const u8,
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch cursor indexes args slice (usize required)
    opts: *DateOptions,
) ?[]const u8 {
    // NOTE: flags may be empty (the bare `-` arg yields arg[1..] == ""), which
    // the original parseArgs handled by falling through the never-running loop;
    // do NOT assert flags.len > 0 here (it would change behavior to a panic).
    std.debug.assert(i.* < args.len);
    std.debug.assert(args.len > 0);

    var j: usize = 0; // tiger:allow:usize-arch index into flags slice (usize required)
    while (j < flags.len) : (j += 1) {
        switch (flags[j]) {
            'u' => opts.utc = true,
            'R' => opts.rfc_email = true,
            'h' => {
                opts.help = true;
                return null;
            },
            'V' => {
                opts.version = true;
                return null;
            },
            'd' => {
                // -d takes the rest of this arg or next arg
                if (!parseArgs_takeValue(flags, args, i, &j, &opts.date_string)) {
                    return "option '-d' requires an argument";
                }
            },
            'r' => {
                // -r takes the rest of this arg or next arg
                if (!parseArgs_takeValue(flags, args, i, &j, &opts.reference_file)) {
                    return "option '-r' requires an argument";
                }
            },
            'j' => opts.no_set_date = true,
            'f' => {
                // -f takes the rest of this arg or next arg
                if (!parseArgs_takeValue(flags, args, i, &j, &opts.input_fmt)) {
                    return "option '-f' requires an argument";
                }
            },
            'z' => {
                // -z takes the rest of this arg or next arg
                if (!parseArgs_takeValue(flags, args, i, &j, &opts.output_zone)) {
                    return "option '-z' requires an argument";
                }
            },
            'n' => {
                // -n: do not set the system time (no-op, we never set time)
            },
            'v' => {
                // -v: adjust date/time component (stub)
                if (!parseArgs_takeValue(flags, args, i, &j, &opts.v_adjust)) {
                    return "option '-v' requires an argument";
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
                return "unrecognized option";
            },
        }
    }
    return null;
}

/// Resolve the argument value for a short option that consumes one (`-d`/`-r`/
/// `-f`/`-z`/`-v`): the rest of the current flag run, else the next arg. Writes
/// it to dest, advances j (to consume the rest) or i (to the next arg), and
/// returns true on success, false when no argument is available.
fn parseArgs_takeValue(
    flags: []const u8,
    args: []const []const u8,
    i: *usize, // tiger:allow:usize-arch cursor indexes args slice (usize required)
    j: *usize, // tiger:allow:usize-arch cursor indexes flags slice (usize required)
    dest: *?[]const u8,
) bool {
    std.debug.assert(flags.len > 0);
    std.debug.assert(j.* < flags.len);

    if (j.* + 1 < flags.len) {
        dest.* = flags[j.* + 1 ..];
        j.* = flags.len; // consume rest
        return true;
    } else if (i.* + 1 < args.len) {
        i.* += 1;
        dest.* = args[i.*];
        return true;
    }
    return false;
}

/// Resolve the timestamp to use based on options
fn resolveTimestamp(io: std.Io, opts: DateOptions) TimestampResult {
    if (opts.date_string) |ds| {
        // Positional dates are GNU obsolete set-date, not `--date`.
        // `@0` is epoch only with `-d`; a leftover positional is invalid.
        if (opts.positional_date) {
            std.debug.assert(opts.date_string != null);
            return .{ .secs = 0, .ns = 0, .err = "invalid date" };
        }
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
                std.debug.assert(ns >= 0);
                std.debug.assert(ns < std.time.ns_per_s);
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
        // Try interpreting as a numeric epoch timestamp first
        if (std.fmt.parseInt(i64, ref, 10)) |epoch_secs| {
            return .{ .secs = epoch_secs, .ns = 0, .err = null };
        } else |_| {}
        // Fall back to stat-ing as a file path
        const stat = std.Io.Dir.cwd().statFile(io, ref, .{}) catch {
            return .{ .secs = 0, .ns = 0, .err = "cannot stat reference file" };
        };
        const mtime_ns = stat.mtime.nanoseconds;
        const secs: i64 = @intCast(@divTrunc(mtime_ns, std.time.ns_per_s));
        const ns: i64 = @intCast(@mod(mtime_ns, std.time.ns_per_s));
        return .{ .secs = secs, .ns = ns, .err = null };
    }

    // Current time
    const now_ts = std.Io.Timestamp.now(io, .real);
    const now_ns = now_ts.nanoseconds;
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
    std.debug.assert(month >= 1);
    std.debug.assert(month <= 12);
    std.debug.assert(day >= 1);
    std.debug.assert(day <= 31);

    var hour: i32 = 0;
    var minute: i32 = 0;
    var second: i32 = 0;

    // Timezone offset in seconds (0 if unspecified, parsed from Z or +/-HH:MM)
    var tz_offset_secs: i64 = 0;
    var has_tz: bool = false;

    // Parse optional time component
    if (ds.len > 10) {
        if (!parseIso8601_parseTime(ds, &hour, &minute, &second, &tz_offset_secs, &has_tz)) {
            return err_result;
        }
    }

    // Convert to epoch
    var tm = time.c_tm{
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

    if (has_tz) {
        // Use timegm to interpret as UTC, then subtract the timezone offset
        const result = time.timegm(&tm);
        if (result == -1) return err_result;
        return .{ .secs = @as(i64, @intCast(result)) - tz_offset_secs, .ns = 0, .err = null };
    } else {
        // No timezone info: use mktime (local time interpretation)
        const result = time.mktime(&tm);
        if (result == -1) return err_result;
        return .{ .secs = @intCast(result), .ns = 0, .err = null };
    }
}

/// Parse the time + timezone component of an ISO 8601 string (everything after
/// the `YYYY-MM-DD` date part). Writes parsed values through the out-params and
/// returns true on success, false on the "invalid date" error so the parent
/// can map it to err_result. Called only when ds.len > 10.
fn parseIso8601_parseTime(
    ds: []const u8,
    hour: *i32,
    minute: *i32,
    second: *i32,
    tz_offset_secs: *i64,
    has_tz: *bool,
) bool {
    std.debug.assert(ds.len > 10);
    std.debug.assert(hour.* == 0);
    std.debug.assert(minute.* == 0);
    std.debug.assert(second.* == 0);

    if (ds[10] != 'T' and ds[10] != ' ') return false;
    const time_str = ds[11..];
    if (time_str.len < 5) return false;
    if (time_str[2] != ':') return false;

    hour.* = std.fmt.parseInt(i32, time_str[0..2], 10) catch return false;
    minute.* = std.fmt.parseInt(i32, time_str[3..5], 10) catch return false;

    if (time_str.len >= 8 and time_str[5] == ':') {
        second.* = std.fmt.parseInt(i32, time_str[6..8], 10) catch return false;
    }

    // Parse timezone suffix after the time component
    // Look for Z, +HH:MM, or -HH:MM
    const seconds_end: usize = // tiger:allow:usize-arch index into time_str slice
        if (time_str.len >= 8 and time_str[5] == ':') 8 else 5;
    if (time_str.len > seconds_end) {
        const tz_str = time_str[seconds_end..];
        if (tz_str.len == 1 and tz_str[0] == 'Z') {
            has_tz.* = true;
            tz_offset_secs.* = 0;
        } else if (tz_str.len == 6 and
            (tz_str[0] == '+' or tz_str[0] == '-') and tz_str[3] == ':')
        {
            const tz_hours = std.fmt.parseInt(i32, tz_str[1..3], 10) catch return false;
            const tz_mins = std.fmt.parseInt(i32, tz_str[4..6], 10) catch return false;
            tz_offset_secs.* = @as(i64, tz_hours) * 3600 + @as(i64, tz_mins) * 60;
            if (tz_str[0] == '-') {
                tz_offset_secs.* = -tz_offset_secs.*;
            }
            has_tz.* = true;
        }
    }
    return true;
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
fn formatTzOffset(buf: []u8, tm: *const time.c_tm) []const u8 {
    std.debug.assert(buf.len >= 6);
    // tm_gmtoff is environment-derived (localtime_r/gmtime_r); any value is valid.

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
    tm: *const time.c_tm,
    epoch_secs: i64,
    ns: i64,
) ![]const u8 {
    // These nanosecond bounds are the documented range maintained by callers
    // (resolveTimestamp), asserted here as real domain invariants.
    std.debug.assert(ns >= -std.time.ns_per_s);
    std.debug.assert(ns < std.time.ns_per_s);

    // Pre-process format string to replace custom specifiers
    // We handle: %N (nanoseconds), %s (epoch seconds), %:z (timezone +HH:MM),
    //            %% (literal %), %n (newline), %t (tab)
    var processed = try std.ArrayList(u8).initCapacity(allocator, format.len);
    defer processed.deinit(allocator);
    std.debug.assert(format.len <= processed.capacity);

    var fi: usize = 0;
    while (fi < format.len) {
        if (format[fi] == '%' and fi + 1 < format.len) {
            fi = try formatDate_appendSpecifier(
                allocator,
                &processed,
                format,
                fi,
                tm,
                epoch_secs,
                ns,
            );
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
    const len = time.strftime(&output_buf, output_buf.len, fmt_z, tm);

    if (len == 0 and processed.items.len > 1) {
        // strftime returned 0, could mean error or empty output
        // If format was non-empty, this is likely an error
        return allocator.dupe(u8, "");
    }

    return allocator.dupe(u8, output_buf[0..len]);
}

/// Handle one `%`-led specifier at format[fi] (parent guarantees a following
/// char). Appends the expansion to processed and returns the new fi cursor
/// (number of consumed chars advanced). Custom specifiers (%s/%N/%z/%:z) are
/// expanded here; everything else is passed through to strftime verbatim.
fn formatDate_appendSpecifier(
    allocator: Allocator,
    processed: *std.ArrayList(u8),
    format: []const u8,
    fi: usize, // tiger:allow:usize-arch cursor indexes format slice (usize required)
    tm: *const time.c_tm,
    epoch_secs: i64,
    ns: i64,
) !usize { // tiger:allow:usize-arch returns the format-slice cursor (usize required)
    std.debug.assert(fi < format.len);
    std.debug.assert(format[fi] == '%');
    std.debug.assert(fi + 1 < format.len);

    var tz_buf: [8]u8 = undefined;
    const next = format[fi + 1];
    switch (next) {
        's' => {
            // Epoch seconds - format directly
            var secs_buf: [24]u8 = undefined;
            const secs_str = std.fmt.bufPrint(&secs_buf, "{d}", .{epoch_secs}) catch "0";
            try processed.appendSlice(allocator, secs_str);
            return fi + 2;
        },
        'N' => {
            // Nanoseconds - 9-digit zero-padded
            var ns_buf: [16]u8 = undefined;
            const abs_ns: u64 = if (ns < 0) @intCast(-ns) else @intCast(ns);
            const ns_str = std.fmt.bufPrint(&ns_buf, "{d:0>9}", .{abs_ns}) catch "000000000";
            try processed.appendSlice(allocator, ns_str);
            return fi + 2;
        },
        'z' => {
            // Numeric timezone offset without colon (+HHMM)
            // Handle directly to ensure tm_gmtoff is respected (macOS strftime bug)
            const tz_str = formatDate_appendSpecifier_tzNumeric(&tz_buf, tm);
            try processed.appendSlice(allocator, tz_str);
            return fi + 2;
        },
        ':' => {
            // Check for %:z (timezone with colon)
            if (fi + 2 < format.len and format[fi + 2] == 'z') {
                const tz_str = formatTzOffset(&tz_buf, tm);
                try processed.appendSlice(allocator, tz_str);
                return fi + 3;
            } else {
                // Pass through unknown %: sequences
                try processed.append(allocator, '%');
                return fi + 1;
            }
        },
        '%' => {
            // Literal % - pass through to strftime which handles %%
            try processed.appendSlice(allocator, "%%");
            return fi + 2;
        },
        'n' => {
            try processed.append(allocator, '\n');
            return fi + 2;
        },
        't' => {
            try processed.append(allocator, '\t');
            return fi + 2;
        },
        else => {
            // Pass through to strftime
            try processed.append(allocator, '%');
            try processed.append(allocator, next);
            return fi + 2;
        },
    }
}

/// Format tm's UTC offset as +HHMM (no colon) into buf for the `%z` specifier.
/// Handled directly rather than via strftime so tm_gmtoff is respected (macOS
/// strftime bug). Returns the formatted slice (or "+0000" on bufPrint failure).
fn formatDate_appendSpecifier_tzNumeric(buf: []u8, tm: *const time.c_tm) []const u8 {
    std.debug.assert(buf.len >= 5);
    // tm_gmtoff is environment-derived (localtime_r/gmtime_r); any value is valid.

    const offset_secs = tm.tm_gmtoff;
    const abs_offset: u64 = if (offset_secs < 0) @intCast(-offset_secs) else @intCast(offset_secs);
    const sign: u8 = if (offset_secs < 0) '-' else '+';
    const hours = @divTrunc(abs_offset, 3600);
    const minutes = @divTrunc(@mod(abs_offset, 3600), 60);
    const tz_str = std.fmt.bufPrint(buf, "{c}{d:0>2}{d:0>2}", .{
        sign,
        hours,
        minutes,
    }) catch "+0000";
    return tz_str;
}

/// Convert epoch seconds to broken-down time. Returns true on success,
/// false if the conversion failed (out-of-range time_t).
fn runDate_brokenDownTime(secs: i64, utc: bool, tm: *time.c_tm) bool {
    const time_secs: c.time_t = @intCast(secs);
    if (utc) {
        return time.gmtime_r(&time_secs, tm) != null;
    }
    return time.localtime_r(&time_secs, tm) != null;
}

/// GNU quotes the extra operand: `date: extra operand '+%m'`.
fn runDate_printParseErr(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    opts: DateOptions,
    err_msg: []const u8,
) void {
    std.debug.assert(err_msg.len > 0);
    if (std.mem.eql(u8, err_msg, "extra operand")) {
        std.debug.assert(opts.extra_operand != null);
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "extra operand '{s}'",
            .{opts.extra_operand.?},
        );
        return;
    }
    if (std.mem.eql(u8, err_msg, "lacks plus")) {
        std.debug.assert(opts.extra_operand != null);
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "the argument '{s}' lacks a leading '+';\n" ++
                "when using an option to specify date(s), any non-option\n" ++
                "argument must be a format string beginning with '+'",
            .{opts.extra_operand.?},
        );
        return;
    }
    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}", .{err_msg});
}

/// GNU quotes the date string: `date: invalid date '-1'`.
fn runDate_printTsErr(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    opts: DateOptions,
    err_msg: []const u8,
) void {
    std.debug.assert(err_msg.len > 0);
    if (std.mem.eql(u8, err_msg, "invalid date")) {
        if (opts.date_string) |ds| {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "invalid date '{s}'",
                .{ds},
            );
            return;
        }
    }
    common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}", .{err_msg});
}

/// Main date utility logic
pub fn runDate(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Parse arguments
    const parsed = parseArgs(args);
    if (parsed.err) |err_msg| {
        runDate_printParseErr(allocator, stderr_writer, parsed.opts, err_msg);
        return @intFromEnum(common.ExitCode.general_error);
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
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "{s}", .{err_msg});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Handle -v stub: not yet implemented, exit with error
    if (opts.v_adjust != null) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "-v adjustment not yet implemented",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Resolve the timestamp to format
    const ts = resolveTimestamp(io, opts);
    if (ts.err) |err_msg| {
        runDate_printTsErr(allocator, stderr_writer, opts, err_msg);
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Convert to broken-down time
    var tm: time.c_tm = undefined;
    if (!runDate_brokenDownTime(ts.secs, opts.utc, &tm)) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "cannot convert time",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
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
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runDate);
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
        \\  -f input_fmt            use input_fmt to parse date string (with -j)
        \\  -j                      do not try to set the date
        \\  -n                      do not set the system time (no-op)
        \\  -v val                  adjust date/time component (stub)
        \\  -z output_zone          set timezone for output display
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
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    // Should contain current year (20xx)
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "20") != null);
}

test "date +%Y outputs 4-digit year" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_aw.writer.buffered());
}

test "date +%Y-%m-%d outputs ISO date" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
}

test "date +%H:%M:%S outputs time" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%H:%M:%S" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("00:00:00\n", stdout_aw.writer.buffered());
}

test "date -u outputs UTC" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%Z" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Accept either UTC or GMT timezone abbreviation (Linux systems vary)
    const stdout = stdout_aw.writer.buffered();
    try testing.expect(std.mem.eql(u8, stdout, "UTC\n") or std.mem.eql(u8, stdout, "GMT\n"));
}

test "date +%s outputs epoch seconds" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@86400", "+%s" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("86400\n", stdout_aw.writer.buffered());
}

test "date -R outputs RFC 5322 format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "-R" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 +0000\n",
        stdout_aw.writer.buffered(),
    );
}

test "date +%% outputs literal percent" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%%" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("%\n", stdout_aw.writer.buffered());
}

test "date +%n outputs newline" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%n" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n\n", stdout_aw.writer.buffered());
}

test "date +%t outputs tab" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%t" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\n", stdout_aw.writer.buffered());
}

test "date -d @0 -u outputs epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "@0", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
}

test "date -d @86400 -u outputs next day" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "@86400", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-02\n", stdout_aw.writer.buffered());
}

test "date --help works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: date") != null);
}

test "date --version works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "date") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.name) != null);
}

test "date invalid flag returns exit code 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -d @EPOCH with full default format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Accept either UTC or GMT timezone abbreviation (Linux systems vary)
    const stdout = stdout_aw.writer.buffered();
    try testing.expect(std.mem.eql(u8, stdout, "Thu Jan  1 00:00:00 UTC 1970\n") or
        std.mem.eql(u8, stdout, "Thu Jan  1 00:00:00 GMT 1970\n"));
}

test "date --rfc-3339=date with epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "--rfc-3339=date" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
}

test "date --rfc-3339=seconds with epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "--rfc-3339=seconds" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01 00:00:00+00:00\n", stdout_aw.writer.buffered());
}

test "date --rfc-3339=ns with epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "--rfc-3339=ns" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000000000+00:00\n",
        stdout_aw.writer.buffered(),
    );
}

test "date --rfc-3339 invalid precision" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--rfc-3339=invalid"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -I outputs ISO date" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "-I" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
}

test "date -Iseconds outputs ISO with seconds" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "-Iseconds" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00\n", stdout_aw.writer.buffered());
}

test "date -Ihours outputs ISO with hours" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "-Ihours" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00+00:00\n", stdout_aw.writer.buffered());
}

test "date -Iminutes outputs ISO with minutes" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "-Iminutes" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00+00:00\n", stdout_aw.writer.buffered());
}

test "date -Ins outputs ISO with nanoseconds" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "-Ins" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00,000000000+00:00\n",
        stdout_aw.writer.buffered(),
    );
}

test "date -d with invalid epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "@notanumber" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -d missing argument" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-d"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -r missing argument" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-r"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date +%N outputs nanoseconds" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "+%N" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("000000000\n", stdout_aw.writer.buffered());
}

test "date -d @EPOCH with specific time" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // 2000-01-01 00:00:00 UTC = 946684800
    const args = [_][]const u8{ "-u", "-d", "@946684800", "+%Y-%m-%d %H:%M:%S" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("2000-01-01 00:00:00\n", stdout_aw.writer.buffered());
}

test "date short flags -h" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: date") != null);
}

test "date short flags -V" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "date") != null);
}

test "date combined short flags -uR" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-uR", "-d", "@0" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 +0000\n",
        stdout_aw.writer.buffered(),
    );
}

test "date --date= form" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "--date=@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_aw.writer.buffered());
}

test "date --iso-8601 with no value" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "--iso-8601" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
}

test "date --iso-8601=seconds" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "--iso-8601=seconds" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00\n", stdout_aw.writer.buffered());
}

test "date -r with reference file" {
    // Create a temp file to use as reference
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write a file so it exists
    const file = try tmp_dir.dir.createFile(io, "testfile", .{});
    file.close(io);

    // Get the path
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try common.test_dir.tmpDirRealPathFile(tmp_dir, "testfile", &path_buf);
    const full_path = path_buf[0..path_len];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", full_path, "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Should output a valid 4-digit year
    try testing.expect(stdout_aw.writer.buffered().len >= 4);
    const first_year_digit = stdout_aw.writer.buffered()[0];
    try testing.expect(first_year_digit >= '1' and first_year_digit <= '9');
}

test "date -r with nonexistent file" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "/tmp/nonexistent_file_date_test_xyz" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -j flag is accepted (no-op)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-j", "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_aw.writer.buffered());
}

test "date -f flag accepts input format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -f requires an argument; accept it without error
    const args = [_][]const u8{ "-j", "-f", "%Y-%m-%d", "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_aw.writer.buffered());
}

test "date -f missing argument returns exit code 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-f"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -z flag accepts output timezone" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -z takes a timezone argument; accept it without error
    const args = [_][]const u8{ "-z", "UTC", "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_aw.writer.buffered());
}

test "date -z missing argument returns exit code 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-z"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date parseArgs -j sets no_set_date" {
    const args = [_][]const u8{"-j"};
    const parsed = parseArgs(&args);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.opts.no_set_date);
}

test "date parseArgs -f stores input_fmt" {
    const args = [_][]const u8{ "-f", "%Y-%m-%d" };
    const parsed = parseArgs(&args);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("%Y-%m-%d", parsed.opts.input_fmt.?);
}

test "date parseArgs -z stores output_zone" {
    const args = [_][]const u8{ "-z", "America/New_York" };
    const parsed = parseArgs(&args);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("America/New_York", parsed.opts.output_zone.?);
}

test "date -n flag is accepted silently (no-op)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-n", "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970\n", stdout_aw.writer.buffered());
    // -n should not produce any stderr output
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "date parseArgs -n is silently accepted" {
    const args = [_][]const u8{"-n"};
    const parsed = parseArgs(&args);
    try testing.expect(parsed.err == null);
}

test "date -v flag accepts value and prints diagnostic" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", "+1d", "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    // -v is unimplemented so no stdout output is produced
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    // Should print diagnostic to stderr
    const found_v_msg = std.mem.find(
        u8,
        stderr_aw.writer.buffered(),
        "-v adjustment not yet implemented",
    );
    try testing.expect(found_v_msg != null);
}

test "date parseArgs -v stores v_adjust" {
    const args = [_][]const u8{ "-v", "+2H" };
    const parsed = parseArgs(&args);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("+2H", parsed.opts.v_adjust.?);
}

test "date parseArgs -v with inline value" {
    const args = [_][]const u8{"-v+1d"};
    const parsed = parseArgs(&args);
    try testing.expect(parsed.err == null);
    try testing.expectEqualStrings("+1d", parsed.opts.v_adjust.?);
}

test "date -v missing argument returns exit code 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-v"};
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
}

test "date -v should exit with non-zero code" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", "+1d", "-u", "-d", "@0", "+%Y" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // -v is not yet implemented, so it should return a non-zero exit code
    // rather than silently producing today's date as if -v was ignored
    try testing.expect(result != 0);
}

test "date -v should not produce stdout output" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", "+1d", "-u", "-d", "@0", "+%Y" };
    _ = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // When -v is unimplemented, no date output should appear on stdout
    // because it would be misleading (showing unadjusted date)
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "date -v stderr should contain error message" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", "+1d", "-u", "-d", "@0", "+%Y" };
    _ = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    // stderr should contain a message about -v not being implemented
    const found_not_impl = std.mem.find(
        u8,
        stderr_aw.writer.buffered(),
        "not yet implemented",
    );
    try testing.expect(found_not_impl != null);
}

// ============================================================================
// F62: date -r with numeric timestamp should parse as epoch seconds
// ============================================================================
// On macOS/BSD, -r accepts both filenames and numeric epoch seconds.
// Our implementation always calls statFile(), so -r 0 fails with
// "cannot stat reference file" instead of displaying epoch time.

test "date -r 0 -u should display epoch (numeric timestamp)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "0", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
}

test "date -r 86400 -u should display 1970-01-02" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "86400", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-02\n", stdout_aw.writer.buffered());
}

test "date -r with negative epoch (pre-1970)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -86400 = 1969-12-31 00:00:00 UTC
    const args = [_][]const u8{ "-r", "-86400", "-u", "+%Y-%m-%d" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1969-12-31\n", stdout_aw.writer.buffered());
}

test "date -r numeric should output epoch seconds with +%s" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "1000000", "-u", "+%s" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1000000\n", stdout_aw.writer.buffered());
}

// ============================================================================
// F63: date -d should respect timezone offset in ISO 8601
// ============================================================================
// parseIso8601 discards the Z suffix and +HH:MM offset, then uses mktime
// which interprets the time as local time. The timezone information is lost.

test "date -d ISO 8601 with Z suffix should treat as UTC" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // 2024-01-15T00:00:00Z in UTC = epoch 1705276800
    const args = [_][]const u8{ "-d", "2024-01-15T00:00:00Z", "-u", "+%s" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1705276800\n", stdout_aw.writer.buffered());
}

test "date -d ISO 8601 with +05:30 offset should adjust epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // 2024-01-15T00:00:00+05:30 = UTC 2024-01-14T18:30:00 = epoch 1705257000
    const args = [_][]const u8{ "-d", "2024-01-15T00:00:00+05:30", "-u", "+%s" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1705257000\n", stdout_aw.writer.buffered());
}

test "date -d ISO 8601 with -05:00 offset should adjust epoch" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // 2024-01-15T00:00:00-05:00 = UTC 2024-01-15T05:00:00 = epoch 1705294800
    const args = [_][]const u8{ "-d", "2024-01-15T00:00:00-05:00", "-u", "+%s" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1705294800\n", stdout_aw.writer.buffered());
}

test "date -d ISO 8601 with +00:00 offset is same as Z" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // 2024-01-15T00:00:00+00:00 = UTC midnight = epoch 1705276800
    const args = [_][]const u8{ "-d", "2024-01-15T00:00:00+00:00", "-u", "+%s" };
    const result = try runDate(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1705276800\n", stdout_aw.writer.buffered());
}

// Issue #159: `--` is the POSIX end-of-options delimiter.
// Pinned against GNU coreutils 9.4 (`/usr/bin/date`, LC_ALL=C).
// Current vibeutils reports `unrecognized option` for a bare `--`.

test "date #159: -- before format prints the format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Motivating case from issue #159: `date -- +%Y`. Year is
    // environment-dependent, so pin shape (four digits + newline).
    const args = [_][]const u8{ "--", "+%Y" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expectEqual(@as(usize, 5), out.len);
    try testing.expect(out[0] >= '0' and out[0] <= '9');
    try testing.expect(out[1] >= '0' and out[1] <= '9');
    try testing.expect(out[2] >= '0' and out[2] <= '9');
    try testing.expect(out[3] >= '0' and out[3] <= '9');
    try testing.expectEqual(@as(u8, '\n'), out[4]);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "date #159: -- after options then format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-d", "@0", "--", "+%Y-%m-%d" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("1970-01-01\n", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "date #159: -- alone prints the current date" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--"};
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.endsWith(u8, stdout_aw.writer.buffered(), "\n"));
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "date #159: doubled -- is an invalid date" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "--" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expectEqualStrings(
        "date: invalid date '--'\n",
        stderr_aw.writer.buffered(),
    );
}

test "date #159: -- then dash operand is an invalid date" {
    // The reason `--` exists: `date -- -1` must treat `-1` as a date
    // string, not as an option. GNU date 9.4 rejects it as invalid.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "-1" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expectEqualStrings(
        "date: invalid date '-1'\n",
        stderr_aw.writer.buffered(),
    );
}

test "date #177: -- then two formats is extra operand" {
    // GNU date 9.4: `date -- +%Y +%m` reports extra operand '+%m'.
    // Current post-`--` parser overwrites format and prints the month.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "+%Y", "+%m" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "extra operand '+%m'",
    ) != null);
}

test "date #177: two formats without -- is extra operand" {
    // Same GNU rule without `--`: `date +%Y +%m` is extra operand '+%m'.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "+%Y", "+%m" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "extra operand '+%m'",
    ) != null);
}

test "date #178: -- format then bare operand is extra" {
    // GNU: any second positional is extra. `date -- +%Y foo` is
    // extra operand 'foo', not an invalid date.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "+%Y", "foo" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "extra operand 'foo'",
    ) != null);
}

test "date #178: -- date string then format is extra" {
    // GNU: `date -- foo +%Y` names the second token, '+%Y'.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "foo", "+%Y" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "extra operand '+%Y'",
    ) != null);
}

test "date #178: two bare operands names the second" {
    // GNU: `date foo bar` treats foo as the date string and names bar.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "foo", "bar" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "extra operand 'bar'",
    ) != null);
}

test "date #178: single bare operand is invalid date" {
    // GNU: one non-+ positional is a date string. `date foo` is
    // invalid date 'foo', not extra operand 'foo'.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"foo"};
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "invalid date 'foo'",
    ) != null);
}

test "date #178: -- format then empty operand is extra" {
    // GNU: `date -- +%Y ''` reports extra operand ''.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "+%Y", "" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "extra operand ''",
    ) != null);
}

test "date #179: -d then leftover bare operand lacks a leading +" {
    // GNU date 9.4: once -d/--date set the date, a leftover non-+
    // positional is not a date string. `date -d @0 foo` must error.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "@0", "foo" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "the argument 'foo' lacks a leading '+'",
    ) != null);
}

test "date #179: --date= then -- leftover bare operand lacks a leading +" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--date=@0", "--", "foo" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "the argument 'foo' lacks a leading '+'",
    ) != null);
}

// GNU date 9.4: a positional `@0` is a date string, not `--date`
// syntax. `date @0` / `date -- @0` are invalid date '@0'. `-d @0`
// remains valid and is covered by existing tests.
test "date #180: positional @0 is an invalid date" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"@0"};
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "invalid date '@0'",
    ) != null);
}

test "date #180: -- then positional @0 is an invalid date" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--", "@0" };
    const result = try runDate(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.indexOf(
        u8,
        stderr_aw.writer.buffered(),
        "invalid date '@0'",
    ) != null);
}
