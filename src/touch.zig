/// touch - update file access and modification times
const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const testing = std.testing;
const c = std.c;

/// Command-line arguments for the touch utility.
const TouchArgs = struct {
    help: bool = false,
    version: bool = false,
    a: bool = false,
    c: bool = false,
    no_create: bool = false,
    f: bool = false,
    h: bool = false,
    no_dereference: bool = false,
    m: bool = false,
    reference: ?[]const u8 = null,
    date: ?[]const u8 = null,
    t: ?[]const u8 = null,
    time: ?[]const u8 = null,
    adjust: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .a = .{ .desc = "Change only the access time" },
        .adjust = .{
            .short = 'A',
            .desc = "Adjust access and modification times by value (not yet implemented)",
            .value_name = "ADJUST",
        },
        .c = .{ .desc = "Do not create any files" },
        .no_create = .{ .short = 0, .desc = "Do not create any files" },
        .f = .{ .desc = "(ignored)" },
        .h = .{ .desc = "Affect symbolic link instead of any referenced file" },
        .no_dereference = .{
            .short = 0,
            .desc = "Affect symbolic link instead of any referenced file",
        },
        .m = .{ .desc = "Change only the modification time" },
        .reference = .{
            .short = 'r',
            .desc = "Use this file's times instead of current time",
            .value_name = "FILE",
        },
        .date = .{
            .short = 'd',
            .desc = "parse DATE and use it instead of current time",
            .value_name = "DATE",
        },
        .t = .{
            .desc = "Use [[CC]YY]MMDDhhmm[.ss] instead of current time",
            .value_name = "STAMP",
        },
        .time = .{
            .short = 0,
            .desc = "Change the specified time: " ++
                "\"access\", \"atime\", \"use\", \"modify\", \"mtime\"",
            .value_name = "WORD",
        },
    };
};

/// Main entry point for the touch utility.
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, run);
}

/// Main implementation that accepts writers for output.
fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const prog_name = "touch";

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        TouchArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try stdout_writer.print("touch ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    // -A flag is a macOS-only feature (adjust timestamps by relative offset).
    // On Linux there is no equivalent. Accept silently and continue.
    // The flag is parsed but the adjustment value is ignored.

    const options = run_buildOptions(parsed_args);
    // prog_name is our 5-char constant "touch", never empty.
    std.debug.assert(prog_name.len > 0);
    // -h/--no-dereference always forces -c (no_create), so no_dereference
    // can never be set without no_create also being set.
    if (options.no_dereference) std.debug.assert(options.no_create);

    // Access positionals
    const files = parsed_args.positionals;

    if (files.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing file operand\nTry '{s} --help' for more information.",
            .{prog_name},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Process files - continue even if one fails (GNU touch behavior)
    var has_error = false;
    for (files) |file_path| {
        touchFile(file_path, options, allocator, io) catch |err| {
            run_reportTouchError(allocator, prog_name, file_path, err, &options, stderr_writer);
            has_error = true;
        };
    }

    return if (has_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
}

/// Builds the TouchOptions struct from parsed command-line arguments,
/// mapping long-form aliases onto their short-form equivalents.
fn run_buildOptions(parsed_args: TouchArgs) TouchOptions {
    // Map long form aliases to short form
    const access_only = parsed_args.a;
    const modify_only = parsed_args.m;
    const no_dereference = parsed_args.h or parsed_args.no_dereference;
    // -h/--no-dereference implies -c: creating a regular file when the
    // intent is to act on a symlink makes no sense (GNU behavior).
    const no_create = parsed_args.c or parsed_args.no_create or no_dereference;

    // Create options struct
    return TouchOptions{
        .access_only = access_only,
        .modify_only = modify_only,
        .no_create = no_create,
        .no_dereference = no_dereference,
        .date_str = parsed_args.date,
        .reference_file = parsed_args.reference,
        .timestamp_str = parsed_args.t,
        .time_arg = parsed_args.time,
    };
}

/// Maps a per-file touch error to a user-friendly message on stderr.
fn run_reportTouchError(
    allocator: std.mem.Allocator,
    prog_name: []const u8,
    file_path: []const u8,
    err: anyerror,
    options: *const TouchOptions,
    stderr_writer: *std.Io.Writer,
) void {
    // An empty file_path ("touch ''") is a legitimate invocation whose error
    // must be reported, not asserted away. Assert only the invariants we own:
    // prog_name is our constant and the options struct we built is intact.
    std.debug.assert(prog_name.len > 0);
    std.debug.assert(prog_name.len <= 16);
    // The options struct built in run() always subsumes no_dereference into
    // no_create; pairs the same invariant asserted in run() on this path.
    if (options.no_dereference) std.debug.assert(options.no_create);

    // Map specific errors to user-friendly messages
    switch (err) {
        error.InvalidTimestamp => run_reportTouchError_invalidTimestamp(
            allocator,
            prog_name,
            options.timestamp_str,
            stderr_writer,
        ),
        error.InvalidDateFormat => run_reportTouchError_invalidDateFormat(
            allocator,
            prog_name,
            options.date_str,
            stderr_writer,
        ),
        error.InvalidTimeType => run_reportTouchError_invalidTimeType(
            allocator,
            prog_name,
            options.time_arg,
            stderr_writer,
        ),
        else => handleError(allocator, prog_name, file_path, err, stderr_writer),
    }
}

/// Reports an InvalidTimestamp error, naming the timestamp if available.
fn run_reportTouchError_invalidTimestamp(
    allocator: std.mem.Allocator,
    prog_name: []const u8,
    timestamp_str: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) void {
    // prog_name is our constant; assert positive and negative space invariants.
    std.debug.assert(prog_name.len > 0);
    std.debug.assert(prog_name.len <= 16);
    if (timestamp_str) |ts| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid date format '{s}'",
            .{ts},
        );
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid date format",
            .{},
        );
    }
}

/// Reports an InvalidDateFormat error, naming the date string if available.
fn run_reportTouchError_invalidDateFormat(
    allocator: std.mem.Allocator,
    prog_name: []const u8,
    date_str: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) void {
    // prog_name is our constant; assert positive and negative space invariants.
    std.debug.assert(prog_name.len > 0);
    std.debug.assert(prog_name.len <= 16);
    if (date_str) |ds| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid date format '{s}'",
            .{ds},
        );
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid date format",
            .{},
        );
    }
}

/// Reports an InvalidTimeType error, naming the --time argument if available.
fn run_reportTouchError_invalidTimeType(
    allocator: std.mem.Allocator,
    prog_name: []const u8,
    time_arg: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) void {
    // prog_name is our constant; assert positive and negative space invariants.
    std.debug.assert(prog_name.len > 0);
    std.debug.assert(prog_name.len <= 16);
    if (time_arg) |ta| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid argument '{s}' for '--time'",
            .{ta},
        );
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "invalid argument for '--time'",
            .{},
        );
    }
}

/// Prints the help message using the provided writer.
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: touch [OPTION]... FILE...
        \\Update the access and modification times of each FILE to the current time.
        \\
        \\A FILE argument that does not exist is created empty, unless -c or -h
        \\is supplied.
        \\
        \\  -a                   change only the access time
        \\  -c, --no-create      do not create any files
        \\  -d, --date=DATE      parse DATE and use it instead of current time
        \\  -f                   (ignored)
        \\  -h, --no-dereference affect symbolic link instead of any referenced file
        \\  -m                   change only the modification time
        \\  -r, --reference=FILE use this file's times instead of current time
        \\  -t STAMP             use [[CC]YY]MMDDhhmm[.ss] instead of current time
        \\  --time=WORD          change the specified time:
        \\                         WORD is access, atime, use: equivalent to -a
        \\                         WORD is modify or mtime: equivalent to -m
        \\  --help               display this help and exit
        \\  -V, --version        output version information and exit
        \\
    );
}

/// Options structure for touch operations.
const TouchOptions = struct {
    access_only: bool = false,
    modify_only: bool = false,
    no_create: bool = false,
    no_dereference: bool = false,
    date_str: ?[]const u8 = null,
    reference_file: ?[]const u8 = null,
    timestamp_str: ?[]const u8 = null,
    time_arg: ?[]const u8 = null,
};

/// Touches a single file with the specified options.
fn touchFile(
    path: []const u8,
    options: TouchOptions,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    // Get the timestamps to use
    var times: [2]c.timespec = undefined;

    if (options.reference_file) |ref_path| {
        // Use timestamps from reference file
        const ref_info = try common.file.FileInfo.stat(io, ref_path);
        times[0] = nsToTimespec(ref_info.atime);
        times[1] = nsToTimespec(ref_info.mtime);
    } else if (options.date_str) |date| {
        // Parse -d format (ISO 8601)
        const parsed_time = try parseIso8601(date);
        times[0] = parsed_time;
        times[1] = parsed_time;
    } else if (options.timestamp_str) |timestamp| {
        // Parse -t format
        const parsed_time = try parseTimestamp(timestamp);
        times[0] = parsed_time;
        times[1] = parsed_time;
    } else {
        // Use current time with nanosecond precision via clock_gettime
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.REALTIME, &ts);
        times[0] = ts;
        times[1] = ts;
    }

    // Handle --time argument
    // This provides compatibility with GNU touch's --time option
    if (options.time_arg) |time_type| {
        // Access time aliases
        if (std.mem.eql(u8, time_type, "access") or
            std.mem.eql(u8, time_type, "atime") or
            std.mem.eql(u8, time_type, "use"))
        {
            // Same as -a
            return touchFileWithTimes(path, options, times, true, false, allocator, io);
        } else if (std.mem.eql(u8, time_type, "modify") or
            std.mem.eql(u8, time_type, "mtime"))
        {
            // Same as -m
            return touchFileWithTimes(path, options, times, false, true, allocator, io);
        } else {
            return error.InvalidTimeType;
        }
    }

    return touchFileWithTimes(
        path,
        options,
        times,
        options.access_only,
        options.modify_only,
        allocator,
        io,
    );
}

/// Touches a file with specific timestamps.
fn touchFileWithTimes(
    path: []const u8,
    options: TouchOptions,
    times: [2]c.timespec,
    access_only: bool,
    modify_only: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    // Try to update the file times first
    updateFileTimes(
        path,
        times,
        access_only,
        modify_only,
        options.no_dereference,
        allocator,
        io,
    ) catch |err| {
        if (err == error.FileNotFound) {
            // File doesn't exist
            if (options.no_create) {
                // Don't create it - not an error
                return;
            }
            // Create the file atomically
            createFileAtomic(path, io) catch |create_err| {
                // If creation fails due to race condition, try updating times anyway
                if (create_err == error.PathAlreadyExists) {
                    try updateFileTimes(
                        path,
                        times,
                        access_only,
                        modify_only,
                        options.no_dereference,
                        allocator,
                        io,
                    );
                    return;
                }
                return create_err;
            };

            // Now update times on the newly created file
            try updateFileTimes(
                path,
                times,
                access_only,
                modify_only,
                options.no_dereference,
                allocator,
                io,
            );
        } else {
            // Some other error occurred
            return err;
        }
    };
}

/// Updates file timestamps using the utimensat system call.
fn updateFileTimes(
    path: []const u8,
    times: [2]c.timespec,
    access_only: bool,
    modify_only: bool,
    no_dereference: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    var actual_times: [2]c.timespec = times;

    // If only updating one time, preserve the other
    if (access_only or modify_only) {
        const info = try common.file.FileInfo.stat(io, path);
        if (access_only) {
            // preserve modification time
            actual_times[1] = nsToTimespec(info.mtime);
        }
        if (modify_only) {
            // preserve access time
            actual_times[0] = nsToTimespec(info.atime);
        }
    }

    // Use utimensat for precise timestamp control
    // AT_FDCWD means "relative to current working directory"
    const dirfd = c.AT.FDCWD;
    // AT_SYMLINK_NOFOLLOW prevents following symbolic links
    const flags: u32 = if (no_dereference) c.AT.SYMLINK_NOFOLLOW else 0;
    // The no-follow bit is set only when no_dereference is requested.
    if (!no_dereference) std.debug.assert(flags == 0);

    // Allocate path buffer dynamically
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    // dupeZ copies path and appends a sentinel excluded from len, so the
    // duplicated slice length always equals the source length.
    std.debug.assert(path_z.len == path.len);
    const result = c.utimensat(dirfd, path_z, &actual_times, flags);
    if (result == -1) {
        const err = std.posix.errno(result);
        return switch (err) {
            .ACCES => error.AccessDenied,
            .BADF => error.BadFileDescriptor,
            .FAULT => error.BadPathName,
            .INTR => error.Interrupted,
            .INVAL => error.InvalidValue,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .PERM => error.AccessDenied,
            .ROFS => error.ReadOnlyFileSystem,
            .SRCH => error.NoSuchProcess,
            .NOSYS => error.SystemCallNotSupported,
            else => std.posix.unexpectedErrno(err),
        };
    }
}

/// Result of splitting a -t stamp into its main part and seconds field.
const ParsedSeconds = struct {
    main_part: []const u8,
    second: u32,
};

/// Splits a -t stamp on the optional dot and parses the seconds field.
fn parseTimestamp_parseSeconds(stamp: []const u8) !ParsedSeconds {
    // An empty -t stamp is valid user input: it must flow through to the
    // length switch and hit error.InvalidTimestamp, not panic. Bound only
    // what we genuinely rely on (slice indexing fits in u32).
    std.debug.assert(stamp.len < std.math.maxInt(u32));

    // Find the dot position for seconds
    const dot_pos = std.mem.findScalar(u8, stamp, '.');
    const main_part = if (dot_pos) |pos| stamp[0..pos] else stamp;

    var second: u32 = 0;
    // Parse seconds if present
    if (dot_pos) |pos| {
        if (pos + 3 == stamp.len) {
            second = try std.fmt.parseInt(u32, stamp[pos + 1 ..], 10);
        } else {
            return error.InvalidTimestamp;
        }
    }

    std.debug.assert(main_part.len <= stamp.len);
    // The seconds field is parsed from exactly two digits, so it never
    // exceeds 99 here; range validation against 59 happens later.
    std.debug.assert(second <= 99);
    return ParsedSeconds{ .main_part = main_part, .second = second };
}

/// Reads the current year from the realtime clock for the 8-digit -t format.
fn parseTimestamp_currentYear() u32 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    const now_ns: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    std.debug.assert(now_ns >= 0);
    const epoch_seconds = @as(u64, @intCast(@divFloor(now_ns, std.time.ns_per_s)));
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
    const year_day = epoch_day.getEpochDay().calculateYearDay();
    const year: u32 = @intCast(year_day.year);
    std.debug.assert(year >= 1970);
    return year;
}

/// Validates date/time fields and converts them to an epoch timespec.
fn parseTimestamp_validateAndConvert(
    year: u32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) !c.timespec {
    // Validate ranges
    if (month < 1 or month > 12) return error.InvalidTimestamp;
    if (day < 1 or day > 31) return error.InvalidTimestamp;
    if (hour > 23) return error.InvalidTimestamp;
    if (minute > 59) return error.InvalidTimestamp;
    if (second > 59) return error.InvalidTimestamp;

    // Validate year (GNU touch supports years 1970-2037 for 32-bit time_t)
    // For 64-bit systems, we can support a wider range
    if (year < 1970) return error.InvalidTimestamp;

    // More precise day validation based on month
    const max_days_in_month = getDaysInMonth(year, month);
    if (day > max_days_in_month) return error.InvalidTimestamp;

    // Convert to timestamp using safer calculation
    const days_since_epoch = daysFromYMD(year, month, day) - daysFromYMD(1970, 1, 1);
    if (days_since_epoch < 0) return error.InvalidTimestamp;

    // Check for overflow before multiplication
    // 86400 seconds per day (24 * 60 * 60)
    const max_days = std.math.maxInt(i64) / 86400;
    if (days_since_epoch > max_days) return error.InvalidTimestamp;

    const day_seconds = std.math.mul(i64, days_since_epoch, 86400) catch
        return error.InvalidTimestamp;
    // days_since_epoch is non-negative (checked above) so its product with
    // the positive seconds-per-day is non-negative.
    std.debug.assert(day_seconds >= 0);
    // Convert time components to seconds (3600 = 60 * 60 seconds per hour)
    const time_seconds = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    // Check for overflow in final addition
    if (day_seconds > std.math.maxInt(i64) - time_seconds) return error.InvalidTimestamp;

    const total_seconds = day_seconds + time_seconds;
    // Both addends are non-negative and the overflow guard above ensures the
    // sum did not wrap, so the epoch second count is non-negative.
    std.debug.assert(total_seconds >= 0);

    return c.timespec{
        .sec = @intCast(total_seconds),
        .nsec = 0,
    };
}

/// Parses a timestamp string in GNU touch -t format.
fn parseTimestamp(stamp: []const u8) !c.timespec {
    var year: u32 = undefined;
    var month: u32 = undefined;
    var day: u32 = undefined;
    var hour: u32 = undefined;
    var minute: u32 = undefined;

    const parsed_seconds = try parseTimestamp_parseSeconds(stamp);
    const main_part = parsed_seconds.main_part;
    const second = parsed_seconds.second;

    // Parse main part based on length
    switch (main_part.len) {
        12 => {
            // CCYYMMDDhhmm - full 4-digit year
            year = try std.fmt.parseInt(u32, main_part[0..4], 10);
            month = try std.fmt.parseInt(u32, main_part[4..6], 10);
            day = try std.fmt.parseInt(u32, main_part[6..8], 10);
            hour = try std.fmt.parseInt(u32, main_part[8..10], 10);
            minute = try std.fmt.parseInt(u32, main_part[10..12], 10);
        },
        10 => {
            // YYMMDDhhmm
            const yy = try std.fmt.parseInt(u32, main_part[0..2], 10);
            // Use POSIX rules: 69-99 -> 1969-1999, 00-68 -> 2000-2068
            // This handles the Y2K transition period
            year = if (yy >= 69) 1900 + yy else 2000 + yy;
            month = try std.fmt.parseInt(u32, main_part[2..4], 10);
            day = try std.fmt.parseInt(u32, main_part[4..6], 10);
            hour = try std.fmt.parseInt(u32, main_part[6..8], 10);
            minute = try std.fmt.parseInt(u32, main_part[8..10], 10);
        },
        8 => {
            // MMDDhhmm - use current year via clock_gettime
            year = parseTimestamp_currentYear();
            month = try std.fmt.parseInt(u32, main_part[0..2], 10);
            day = try std.fmt.parseInt(u32, main_part[2..4], 10);
            hour = try std.fmt.parseInt(u32, main_part[4..6], 10);
            minute = try std.fmt.parseInt(u32, main_part[6..8], 10);
        },
        else => return error.InvalidTimestamp,
    }

    return parseTimestamp_validateAndConvert(year, month, day, hour, minute, second);
}

/// Parse ISO 8601 date/datetime string to a timespec.
/// Supported formats:
///   YYYY-MM-DD
///   YYYY-MM-DDTHH:MM:SS
///   YYYY-MM-DD HH:MM:SS
fn parseIso8601(date_str: []const u8) !c.timespec {
    // Minimum valid: YYYY-MM-DD (10 chars)
    if (date_str.len < 10) return error.InvalidDateFormat;
    // Past the guard, the fixed-index slices and reads on [0..10] are safe.
    std.debug.assert(date_str.len >= 10);

    // Parse year, month, day
    if (date_str.len < 4) return error.InvalidDateFormat;
    const year = std.fmt.parseInt(u32, date_str[0..4], 10) catch return error.InvalidDateFormat;
    if (date_str[4] != '-') return error.InvalidDateFormat;
    if (date_str.len < 7) return error.InvalidDateFormat;
    const month = std.fmt.parseInt(u32, date_str[5..7], 10) catch return error.InvalidDateFormat;
    if (date_str[7] != '-') return error.InvalidDateFormat;
    if (date_str.len < 10) return error.InvalidDateFormat;
    const day = std.fmt.parseInt(u32, date_str[8..10], 10) catch return error.InvalidDateFormat;

    var hour: u32 = 0;
    var minute: u32 = 0;
    var second: u32 = 0;

    // Check for time component (T or space separator)
    if (date_str.len > 10) {
        if (date_str[10] != 'T' and date_str[10] != ' ') return error.InvalidDateFormat;
        // Expect HH:MM:SS (8 chars after separator)
        if (date_str.len < 19) return error.InvalidDateFormat;
        hour = std.fmt.parseInt(u32, date_str[11..13], 10) catch return error.InvalidDateFormat;
        if (date_str[13] != ':') return error.InvalidDateFormat;
        minute = std.fmt.parseInt(u32, date_str[14..16], 10) catch return error.InvalidDateFormat;
        if (date_str[16] != ':') return error.InvalidDateFormat;
        second = std.fmt.parseInt(u32, date_str[17..19], 10) catch return error.InvalidDateFormat;
    }

    // Validate ranges
    if (month < 1 or month > 12) return error.InvalidDateFormat;
    if (day < 1 or day > getDaysInMonth(year, month)) return error.InvalidDateFormat;
    if (hour > 23) return error.InvalidDateFormat;
    if (minute > 59) return error.InvalidDateFormat;
    if (second > 59) return error.InvalidDateFormat;
    if (year < 1970) return error.InvalidDateFormat;

    // Parse optional timezone suffix after datetime (position 19+)
    const tz_offset_seconds = try parseIso8601_tzOffset(date_str);

    // Convert to seconds since epoch
    const days_since_epoch = daysFromYMD(year, month, day) - daysFromYMD(1970, 1, 1);
    const day_seconds = @as(i64, days_since_epoch) * 86400;
    const time_seconds = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    const total_seconds = day_seconds + time_seconds + tz_offset_seconds;

    return c.timespec{
        .sec = @intCast(total_seconds),
        .nsec = 0,
    };
}

/// Parses the optional timezone suffix of an ISO 8601 string (position 19+)
/// and returns the seconds to add to local time to obtain UTC. A missing
/// suffix or a trailing 'Z' yields a zero offset.
fn parseIso8601_tzOffset(date_str: []const u8) !i64 {
    if (date_str.len <= 19) return 0;

    const suffix = date_str[19..];
    if (suffix.len == 1 and suffix[0] == 'Z') {
        // Z means UTC, offset is 0
        return 0;
    } else if ((suffix[0] == '+' or suffix[0] == '-') and
        suffix.len == 6 and suffix[3] == ':')
    {
        const tz_hours = std.fmt.parseInt(i64, suffix[1..3], 10) catch
            return error.InvalidDateFormat;
        const tz_minutes = std.fmt.parseInt(i64, suffix[4..6], 10) catch
            return error.InvalidDateFormat;
        const offset = tz_hours * 3600 + tz_minutes * 60;
        // Positive offset (+05:00) means ahead of UTC, so subtract to get UTC
        // Negative offset (-05:00) means behind UTC, so add to get UTC
        return if (suffix[0] == '+') -offset else offset;
    } else {
        return error.InvalidDateFormat;
    }
}

/// Creates a file atomically to avoid race conditions.
fn createFileAtomic(path: []const u8, io: std.Io) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true, // Fail if file already exists
        .truncate = false, // Don't truncate if it somehow exists
    });
    file.close(io);
}

/// Days in each month (non-leap year).
const days_in_month = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// Helper function to convert nanoseconds to timespec.
fn nsToTimespec(ns: i128) c.timespec {
    return c.timespec{
        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

/// Calculates days since epoch (January 1, 1970) for a given date using civil-day formula.
fn daysFromYMD(y: u32, m: u32, d: u32) i64 {
    const adj_y: i64 = @as(i64, @intCast(y)) - @as(i64, if (m <= 2) 1 else 0);
    const era: i64 = @divFloor(adj_y, 400);
    const yoe: i64 = adj_y - era * 400;
    const adj_m: i64 = @as(i64, @intCast(m)) + (if (m > 2) @as(i64, -3) else 9);
    const doy: i64 = @divFloor(153 * adj_m + 2, 5) + @as(i64, @intCast(d)) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Determines if a year is a leap year.
fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Returns the number of days in a given month.
fn getDaysInMonth(year: u32, month: u32) u32 {
    if (month < 1 or month > 12) return 0;
    // Past the guard, month indexes the 12-element table; month-1 cannot
    // underflow and stays within bounds.
    std.debug.assert(month >= 1);
    std.debug.assert(month <= 12);

    var days = days_in_month[month - 1];
    // February in leap years has 29 days
    if (month == 2 and isLeapYear(year)) {
        days = 29;
    }

    // Table values are 28-31; the leap adjustment only ever sets 29.
    std.debug.assert(days >= 28);
    std.debug.assert(days <= 31);
    return days;
}

/// Handles errors by printing appropriate error messages.
fn handleError(
    allocator: std.mem.Allocator,
    prog_name: []const u8,
    path: []const u8,
    err: anyerror,
    stderr_writer: *std.Io.Writer,
) void {
    // prog_name flows from run()'s constant "touch"; never empty. path is not
    // asserted because "touch ''" is a legitimate invocation to report.
    std.debug.assert(prog_name.len > 0);

    // GNU touch format: "touch: cannot touch 'filename': Error message".
    // The errno-to-message mapping lives in handleError_message; reporting is a
    // single call so wrapping the long format strings stays within the column
    // limit without changing behavior.
    const message = handleError_message(err);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        prog_name,
        "cannot touch '{s}': {s}",
        .{ path, message },
    );
}

/// Maps a touch error to its GNU-style message string. Errors not handled
/// explicitly fall back to posixErrorString, matching the prior switch's
/// else arm. The returned message contains no format specifiers, so the
/// single-call site reproduces the original per-arm output byte-for-byte.
fn handleError_message(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.BadPathName => "Bad address",
        error.Interrupted => "Interrupted system call",
        error.SystemCallNotSupported => "Function not implemented",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.NameTooLong => "File name too long",
        error.NotDir => "Not a directory",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.InvalidValue => "Invalid argument",
        error.BadFileDescriptor => "Bad file descriptor",
        error.NoSuchProcess => "No such process",
        else => common.posixErrorString(err),
    };
}

// ==================== TESTS ====================
// Comprehensive test suite for touch functionality

/// Helper function to compare timestamps with tolerance for cross-platform compatibility.
/// Linux file systems may truncate timestamps to seconds while macOS
/// preserves nanosecond precision.
/// We use a larger tolerance when comparing "preserved" timestamps since they may be rounded
/// when read back from the file system.
fn expectTimestampsEqual(expected: i128, actual: i128) !void {
    // Use 1 second tolerance to handle file systems that only store second precision
    const time_diff_ns: i128 = 1_000_000_000; // 1 second tolerance
    try testing.expect(@abs(expected - actual) < time_diff_ns);
}

test "touch creates new file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/new_file.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const options = TouchOptions{};
    try touchFile(test_file, options, testing.allocator, testing.io);

    // Verify file exists
    const file = try tmp_dir.dir().openFile(io, "new_file.txt", .{});
    file.close(io);
}

test "touch updates existing file timestamp" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a file
    const file = try tmp_dir.dir().createFile(io, "existing.txt", .{});
    file.close(io);

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/existing.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const stat_before = try common.file.FileInfo.stat(testing.io, test_file);

    // Wait a bit to ensure timestamp difference
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);

    // Touch the file
    const options = TouchOptions{};
    try touchFile(test_file, options, testing.allocator, testing.io);

    // Verify timestamps were updated
    const stat_after = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat_after.mtime > stat_before.mtime);
}

test "touch -c does not create file" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/no_create.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const options = TouchOptions{ .no_create = true };
    try touchFile(test_file, options, testing.allocator, testing.io);

    // Verify file does not exist
    const result = tmp_dir.dir().openFile(io, "no_create.txt", .{});
    try testing.expectError(error.FileNotFound, result);
}

test "touch -a updates only access time" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a file
    const file = try tmp_dir.dir().createFile(io, "access_only.txt", .{});
    file.close(io);

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/access_only.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Get initial timestamps
    const stat_before = try common.file.FileInfo.stat(testing.io, test_file);

    // Wait to ensure timestamp difference
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);

    // Touch with -a
    const options = TouchOptions{ .access_only = true };
    try touchFile(test_file, options, testing.allocator, testing.io);

    // Verify only access time was updated
    const stat_after = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat_after.atime > stat_before.atime);
    try expectTimestampsEqual(stat_before.mtime, stat_after.mtime);
}

test "touch -m updates only modification time" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a file
    const file = try tmp_dir.dir().createFile(io, "modify_only.txt", .{});
    file.close(io);

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/modify_only.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Get initial timestamps
    const stat_before = try common.file.FileInfo.stat(testing.io, test_file);

    // Wait to ensure timestamp difference
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);

    // Touch with -m
    const options = TouchOptions{ .modify_only = true };
    try touchFile(test_file, options, testing.allocator, testing.io);

    // Verify only modification time was updated
    const stat_after = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat_after.mtime > stat_before.mtime);
    try expectTimestampsEqual(stat_before.atime, stat_after.atime);
}

test "touch -r uses reference file times" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create reference file
    const ref_file = try tmp_dir.dir().createFile(io, "reference.txt", .{});
    ref_file.close(io);

    // Create target file
    const target_file = try tmp_dir.dir().createFile(io, "target.txt", .{});
    target_file.close(io);

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/reference.txt", .{tmp_path});
    defer testing.allocator.free(ref_path);
    const target_path = try std.fmt.allocPrint(testing.allocator, "{s}/target.txt", .{tmp_path});
    defer testing.allocator.free(target_path);

    // Wait to ensure different timestamps
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);

    // Touch target with reference
    const options = TouchOptions{ .reference_file = ref_path };
    try touchFile(target_path, options, testing.allocator, testing.io);

    // Verify target has same times as reference
    const ref_stat = try common.file.FileInfo.stat(testing.io, ref_path);
    const target_stat = try common.file.FileInfo.stat(testing.io, target_path);

    // Allow small difference due to nanosecond precision
    // Some file systems may not support full nanosecond precision
    try expectTimestampsEqual(ref_stat.atime, target_stat.atime);
    try expectTimestampsEqual(ref_stat.mtime, target_stat.mtime);
}

test "parseTimestamp with full format CCYYMMDDhhmm.ss" {
    const result = try parseTimestamp("202312311359.45");
    // 2023-12-31 13:59:45 UTC = 1704031185 epoch seconds
    try testing.expectEqual(@as(i64, 1704031185), result.sec);
    try testing.expectEqual(@as(i64, 0), result.nsec);
}

test "parseTimestamp with YYMMDDhhmm format" {
    // YY=23 -> year 2023, 2023-12-31 13:59:00 UTC = 1704031140
    const result1 = try parseTimestamp("2312311359");
    try testing.expectEqual(@as(i64, 1704031140), result1.sec);

    // YY=99 -> year 1999, 1999-12-31 13:59:00 UTC = 946648740
    const result2 = try parseTimestamp("9912311359");
    try testing.expectEqual(@as(i64, 946648740), result2.sec);
}

test "parseTimestamp with invalid format" {
    // Too short
    try testing.expectError(error.InvalidTimestamp, parseTimestamp("123"));

    // Invalid month
    try testing.expectError(error.InvalidTimestamp, parseTimestamp("202313011200"));

    // Invalid hour
    try testing.expectError(error.InvalidTimestamp, parseTimestamp("202312312400"));
}

test "touch --time=access updates only access time" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file = try tmp_dir.dir().createFile(io, "time_access.txt", .{});
    file.close(io);

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/time_access.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const stat_before = try common.file.FileInfo.stat(testing.io, test_file);
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);

    const options = TouchOptions{ .time_arg = "access" };
    try touchFile(test_file, options, testing.allocator, testing.io);

    const stat_after = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat_after.atime > stat_before.atime);
    try expectTimestampsEqual(stat_before.mtime, stat_after.mtime);
}

test "touch --time=modify updates only modification time" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file = try tmp_dir.dir().createFile(io, "time_modify.txt", .{});
    file.close(io);

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/time_modify.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const stat_before = try common.file.FileInfo.stat(testing.io, test_file);
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);

    const options = TouchOptions{ .time_arg = "modify" };
    try touchFile(test_file, options, testing.allocator, testing.io);

    const stat_after = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat_after.mtime > stat_before.mtime);
    try expectTimestampsEqual(stat_before.atime, stat_after.atime);
}

test "touch multiple files" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const file1 = try std.fmt.allocPrint(testing.allocator, "{s}/file1.txt", .{tmp_path});
    defer testing.allocator.free(file1);
    const file2 = try std.fmt.allocPrint(testing.allocator, "{s}/file2.txt", .{tmp_path});
    defer testing.allocator.free(file2);

    const options = TouchOptions{};
    try touchFile(file1, options, testing.allocator, testing.io);
    try touchFile(file2, options, testing.allocator, testing.io);

    // Verify both files exist
    const f1 = try tmp_dir.dir().openFile(io, "file1.txt", .{});
    f1.close(io);
    const f2 = try tmp_dir.dir().openFile(io, "file2.txt", .{});
    f2.close(io);
}

test "touch with -t timestamp" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Get real path for the temporary directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/timestamp.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Use a specific timestamp
    const options = TouchOptions{ .timestamp_str = "202312311359.00" };
    try touchFile(test_file, options, testing.allocator, testing.io);

    // Verify file was created
    const file = try tmp_dir.dir().openFile(io, "timestamp.txt", .{});
    file.close(io);

    // We can't easily verify the exact timestamp without a proper date library,
    // but the file should exist and have been touched
    const stat = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat.mtime > 0);
}

// ==================== -A (adjust time - silent no-op on Linux) tests ====================

test "touch: -A flag is accepted as silent no-op" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/adjust_test.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -A is a macOS-only feature; on Linux it should be a silent no-op exiting 0
    const args = [_][]const u8{ "-A", "0130", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

// ==================== -d (date string) tests ====================

test "touch: -d flag is parsed by argparser" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/parse_test.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -d should be accepted without error
    const args = [_][]const u8{ "-d", "2024-01-15", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "touch: -d with ISO date sets timestamp" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/dated.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "2024-01-15", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify the modification time is 2024-01-15 00:00:00 UTC
    const stat = try common.file.FileInfo.stat(testing.io, test_file);
    // 2024-01-15 00:00:00 UTC = 1705276800 seconds since epoch
    const expected_ns: i128 = 1705276800 * std.time.ns_per_s;
    try testing.expectEqual(expected_ns, stat.mtime);
}

test "touch: -d with date and time sets timestamp" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/datetime.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "2024-01-15T10:30:00", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify the modification time is 2024-01-15 10:30:00 UTC
    const stat = try common.file.FileInfo.stat(testing.io, test_file);
    // 2024-01-15 10:30:00 UTC = 1705314600 seconds since epoch
    const expected_ns: i128 = 1705314600 * std.time.ns_per_s;
    try testing.expectEqual(expected_ns, stat.mtime);
}

test "touch: -d with invalid date gives error" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/invalid_date.txt",
        .{tmp_path},
    );
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "not-a-date", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    // Should return error exit code for invalid date
    try testing.expectEqual(@as(u8, 1), exit_code);
}

test "touch: -d with space-separated datetime" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/space_datetime.txt",
        .{tmp_path},
    );
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Space-separated date and time (ISO 8601 allows space instead of T)
    const args = [_][]const u8{ "-d", "2024-06-15 14:30:00", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify the modification time is 2024-06-15 14:30:00 UTC
    const stat = try common.file.FileInfo.stat(testing.io, test_file);
    // 2024-06-15 14:30:00 UTC = 1718461800 seconds since epoch
    const expected_ns: i128 = 1718461800 * std.time.ns_per_s;
    try testing.expectEqual(expected_ns, stat.mtime);
}

// ==================== -A (adjust) is a silent no-op on Linux ====================

test "touch: -A flag with non-zero value exits zero" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/adjust_nonzero.txt",
        .{tmp_path},
    );
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-A", "0130", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );

    // -A is a silent no-op on Linux; should succeed
    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "touch: -A flag produces no stderr output" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/adjust_msg.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-A", "01", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Silent no-op should produce no stderr
    try testing.expectEqual(@as(usize, 0), stderr_aw.written().len);
}

// ==================== F53: -d timezone handling ====================

test "touch: parseIso8601 Z suffix should be treated as UTC" {
    // "2024-01-15T00:00:00Z" means UTC midnight
    // GNU touch produces epoch 1705276800 for this input
    const result = try parseIso8601("2024-01-15T00:00:00Z");
    // 2024-01-15 00:00:00 UTC = 1705276800
    try testing.expectEqual(@as(i64, 1705276800), result.sec);
}

test "touch: parseIso8601 positive timezone offset +05:00" {
    // "2024-01-15T00:00:00+05:00" means midnight in UTC+5
    // UTC equivalent = 2024-01-14T19:00:00Z = 1705276800 - 18000 = 1705258800
    const result = try parseIso8601("2024-01-15T00:00:00+05:00");
    try testing.expectEqual(@as(i64, 1705258800), result.sec);
}

test "touch: parseIso8601 negative timezone offset -05:00" {
    // "2024-01-15T00:00:00-05:00" means midnight in UTC-5
    // UTC equivalent = 2024-01-15T05:00:00Z = 1705276800 + 18000 = 1705294800
    const result = try parseIso8601("2024-01-15T00:00:00-05:00");
    try testing.expectEqual(@as(i64, 1705294800), result.sec);
}

test "touch: parseIso8601 half-hour timezone offset +05:30" {
    // "2024-01-15T00:00:00+05:30" means midnight in UTC+5:30
    // UTC equivalent = 2024-01-14T18:30:00Z = 1705276800 - 19800 = 1705257000
    const result = try parseIso8601("2024-01-15T00:00:00+05:30");
    try testing.expectEqual(@as(i64, 1705257000), result.sec);
}

test "touch: -d with Z suffix sets correct UTC timestamp on file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/utc_z.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "2024-01-15T00:00:00Z", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify mtime is 2024-01-15 00:00:00 UTC = 1705276800
    const stat = try common.file.FileInfo.stat(testing.io, test_file);
    const expected_ns: i128 = 1705276800 * std.time.ns_per_s;
    try testing.expectEqual(expected_ns, stat.mtime);
}

test "touch: -d with +05:00 offset sets correct UTC timestamp on file" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/tz_plus5.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // midnight at +05:00 = 2024-01-14T19:00:00 UTC = epoch 1705258800
    const args = [_][]const u8{ "-d", "2024-01-15T00:00:00+05:00", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    const stat = try common.file.FileInfo.stat(testing.io, test_file);
    const expected_ns: i128 = 1705258800 * std.time.ns_per_s;
    try testing.expectEqual(expected_ns, stat.mtime);
}

test "touch: -A flag still touches file timestamps (adjustment ignored)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create a file first so it has known timestamps
    const file = try tmp_dir.dir().createFile(io, "adjust_nomod.txt", .{});
    file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.realPath(&path_buf);
    const tmp_path = path_buf[0..n];

    const test_file = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/adjust_nomod.txt",
        .{tmp_path},
    );
    defer testing.allocator.free(test_file);

    // Record timestamps before the -A invocation
    const stat_before = try common.file.FileInfo.stat(testing.io, test_file);

    // Wait to ensure the modification is detectable
    _ = c.nanosleep(&.{ .sec = 1, .nsec = 100_000_000 }, null);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-A", "0130", test_file };
    const exit_code = try run(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), exit_code);

    // -A adjustment is ignored but touch still updates timestamps to now
    const stat_after = try common.file.FileInfo.stat(testing.io, test_file);
    try testing.expect(stat_after.mtime != stat_before.mtime);
}
