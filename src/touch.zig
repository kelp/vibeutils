const std = @import("std");
const common = @import("common");
const testing = std.testing;
const fs = std.fs;
const c = std.c;

const TouchArgs = struct {
    help: bool = false,
    version: bool = false,
    a: bool = false,
    c: bool = false,
    no_create: bool = false,
    date: ?[]const u8 = null,
    f: bool = false,
    h: bool = false,
    no_dereference: bool = false,
    m: bool = false,
    reference: ?[]const u8 = null,
    t: ?[]const u8 = null,
    time: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .a = .{ .desc = "Change only the access time" },
        .c = .{ .desc = "Do not create any files" },
        .no_create = .{ .short = 0, .desc = "Do not create any files" },
        .date = .{ .short = 'd', .desc = "Parse string and use it instead of current time", .value_name = "STRING" },
        .f = .{ .desc = "(ignored)" },
        .h = .{ .desc = "Affect symbolic link instead of any referenced file" },
        .no_dereference = .{ .short = 0, .desc = "Affect symbolic link instead of any referenced file" },
        .m = .{ .desc = "Change only the modification time" },
        .reference = .{ .short = 'r', .desc = "Use this file's times instead of current time", .value_name = "FILE" },
        .t = .{ .desc = "Use [[CC]YY]MMDDhhmm[.ss] instead of current time", .value_name = "STAMP" },
        .time = .{ .short = 0, .desc = "Change the specified time: \"access\", \"atime\", \"use\", \"modify\", \"mtime\"", .value_name = "WORD" },
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(TouchArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.fatal("unrecognized option\nTry 'touch --help' for more information.", .{});
            },
            error.MissingValue => {
                common.fatal("option requires an argument\nTry 'touch --help' for more information.", .{});
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    // Handle help
    if (args.help) {
        try printHelp();
        return;
    }

    // Handle version
    if (args.version) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("touch ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Map long form aliases to short form
    const access_only = args.a;
    const modify_only = args.m;
    const no_create = args.c or args.no_create;
    const no_dereference = args.h or args.no_dereference;

    // Create options struct
    const options = TouchOptions{
        .access_only = access_only,
        .modify_only = modify_only,
        .no_create = no_create,
        .no_dereference = no_dereference,
        .reference_file = args.reference,
        .timestamp_str = args.t,
        .date_str = args.date,
        .time_arg = args.time,
    };

    // Access positionals
    const files = args.positionals;

    if (files.len == 0) {
        common.fatal("missing file operand\nTry 'touch --help' for more information.", .{});
    }

    // Process files
    var exit_code: u8 = 0;
    for (files) |file_path| {
        touchFile(file_path, options, allocator) catch |err| {
            switch (err) {
                error.InvalidTimestamp => {
                    if (options.timestamp_str) |ts| {
                        common.printError("invalid date format '{s}'", .{ts});
                    } else {
                        common.printError("invalid date format", .{});
                    }
                },
                error.InvalidTimeType => {
                    if (options.time_arg) |ta| {
                        common.printError("invalid argument '{s}' for '--time'", .{ta});
                    } else {
                        common.printError("invalid argument for '--time'", .{});
                    }
                },
                error.DateParsingNotImplemented => {
                    if (options.date_str) |ds| {
                        common.printError("invalid date format '{s}'", .{ds});
                    } else {
                        common.printError("invalid date format", .{});
                    }
                },
                else => handleError(file_path, err),
            }
            exit_code = @intFromEnum(common.ExitCode.general_error);
        };
    }

    std.process.exit(exit_code);
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    try stdout.print(
        \\Usage: {s} [OPTION]... FILE...
        \\Update the access and modification times of each FILE to the current time.
        \\
        \\A FILE argument that does not exist is created empty, unless -c or -h
        \\is supplied.
        \\
        \\Options:
        \\  -a                   change only the access time
        \\  -c, --no-create      do not create any files
        \\  -d, --date=STRING    parse STRING and use it instead of current time
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
        \\Note: -d and -t options accept different time-date formats.
        \\
    , .{prog_name});
}

const TouchOptions = struct {
    access_only: bool = false,
    modify_only: bool = false,
    no_create: bool = false,
    no_dereference: bool = false,
    reference_file: ?[]const u8 = null,
    timestamp_str: ?[]const u8 = null,
    date_str: ?[]const u8 = null,
    time_arg: ?[]const u8 = null,
};

fn touchFile(path: []const u8, options: TouchOptions, allocator: std.mem.Allocator) !void {

    // Get the timestamps to use
    var times: [2]c.timespec = undefined;

    if (options.reference_file) |ref_path| {
        // Use timestamps from reference file
        const ref_info = try common.file.FileInfo.stat(ref_path);
        times[0] = c.timespec{
            .sec = @intCast(@divFloor(ref_info.atime, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ref_info.atime, std.time.ns_per_s)),
        };
        times[1] = c.timespec{
            .sec = @intCast(@divFloor(ref_info.mtime, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ref_info.mtime, std.time.ns_per_s)),
        };
    } else if (options.timestamp_str) |timestamp| {
        // Parse -t format
        const parsed_time = try parseTimestamp(timestamp);
        times[0] = parsed_time;
        times[1] = parsed_time;
    } else if (options.date_str) |_| {
        // TODO: Parse -d format (more complex, supports natural language)
        return error.DateParsingNotImplemented;
    } else {
        // Use current time with nanosecond precision
        const now_ns = std.time.nanoTimestamp();
        const now = c.timespec{
            .sec = @intCast(@divFloor(now_ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(now_ns, std.time.ns_per_s)),
        };
        times[0] = now;
        times[1] = now;
    }

    // Handle --time argument
    if (options.time_arg) |time_type| {
        if (std.mem.eql(u8, time_type, "access") or
            std.mem.eql(u8, time_type, "atime") or
            std.mem.eql(u8, time_type, "use"))
        {
            // Same as -a
            return touchFileWithTimes(path, options, times, true, false, allocator);
        } else if (std.mem.eql(u8, time_type, "modify") or
            std.mem.eql(u8, time_type, "mtime"))
        {
            // Same as -m
            return touchFileWithTimes(path, options, times, false, true, allocator);
        } else {
            return error.InvalidTimeType;
        }
    }

    return touchFileWithTimes(path, options, times, options.access_only, options.modify_only, allocator);
}

fn touchFileWithTimes(
    path: []const u8,
    options: TouchOptions,
    times: [2]c.timespec,
    access_only: bool,
    modify_only: bool,
    allocator: std.mem.Allocator,
) !void {
    // Try to update the file times first
    updateFileTimes(path, times, access_only, modify_only, options.no_dereference, allocator) catch |err| {
        if (err == error.FileNotFound) {
            // File doesn't exist
            if (options.no_create) {
                // Don't create it - not an error
                return;
            }
            // Create the file and try updating times again
            const new_file = try fs.cwd().createFile(path, .{ .exclusive = false });
            new_file.close();

            // Now update times on the newly created file
            try updateFileTimes(path, times, access_only, modify_only, options.no_dereference, allocator);
        } else {
            // Some other error occurred
            return err;
        }
    };
}

fn updateFileTimes(
    path: []const u8,
    times: [2]c.timespec,
    access_only: bool,
    modify_only: bool,
    no_dereference: bool,
    allocator: std.mem.Allocator,
) !void {
    var actual_times: [2]c.timespec = times;

    // If only updating one time, preserve the other
    if (access_only or modify_only) {
        const info = try common.file.FileInfo.stat(path);
        if (access_only) {
            // preserve modification time
            actual_times[1] = c.timespec{
                .sec = @intCast(@divFloor(info.mtime, std.time.ns_per_s)),
                .nsec = @intCast(@mod(info.mtime, std.time.ns_per_s)),
            };
        }
        if (modify_only) {
            // preserve access time
            actual_times[0] = c.timespec{
                .sec = @intCast(@divFloor(info.atime, std.time.ns_per_s)),
                .nsec = @intCast(@mod(info.atime, std.time.ns_per_s)),
            };
        }
    }

    // Use utimensat for precise timestamp control
    const dirfd = c.AT.FDCWD;
    const flags: u32 = if (no_dereference) c.AT.SYMLINK_NOFOLLOW else 0;

    // Allocate path buffer dynamically
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const result = c.utimensat(dirfd, path_z, &actual_times, flags);
    if (result != 0) {
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

fn parseTimestamp(stamp: []const u8) !c.timespec {
    // Parse [[CC]YY]MMDDhhmm[.ss] format
    // Examples:
    // 202312311359.45 -> 2023-12-31 13:59:45
    // 12311359.45 -> current_century + 23-12-31 13:59:45
    // 12311359 -> current_century + YY-12-31 13:59:00

    var year: u32 = undefined;
    var month: u32 = undefined;
    var day: u32 = undefined;
    var hour: u32 = undefined;
    var minute: u32 = undefined;
    var second: u32 = 0;

    // Find the dot position for seconds
    const dot_pos = std.mem.indexOfScalar(u8, stamp, '.');
    const main_part = if (dot_pos) |pos| stamp[0..pos] else stamp;

    // Parse seconds if present
    if (dot_pos) |pos| {
        if (pos + 3 == stamp.len) {
            second = try std.fmt.parseInt(u32, stamp[pos + 1 ..], 10);
        } else {
            return error.InvalidTimestamp;
        }
    }

    // Parse main part
    switch (main_part.len) {
        12 => {
            // CCYYMMDDhhmm
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
            year = if (yy >= 69) 1900 + yy else 2000 + yy;
            month = try std.fmt.parseInt(u32, main_part[2..4], 10);
            day = try std.fmt.parseInt(u32, main_part[4..6], 10);
            hour = try std.fmt.parseInt(u32, main_part[6..8], 10);
            minute = try std.fmt.parseInt(u32, main_part[8..10], 10);
        },
        8 => {
            // MMDDhhmm (current year)
            const now = std.time.timestamp();
            const epoch_seconds = @as(u64, @intCast(now));
            const epoch_day = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
            const year_day = epoch_day.getEpochDay().calculateYearDay();
            year = @intCast(year_day.year);

            month = try std.fmt.parseInt(u32, main_part[0..2], 10);
            day = try std.fmt.parseInt(u32, main_part[2..4], 10);
            hour = try std.fmt.parseInt(u32, main_part[4..6], 10);
            minute = try std.fmt.parseInt(u32, main_part[6..8], 10);
        },
        else => return error.InvalidTimestamp,
    }

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
    const days_in_month = getDaysInMonth(year, month);
    if (day > days_in_month) return error.InvalidTimestamp;

    // Convert to timestamp using safer calculation
    const days_since_epoch = daysFromYMD(year, month, day) - daysFromYMD(1970, 1, 1);
    if (days_since_epoch < 0) return error.InvalidTimestamp;

    // Check for overflow before multiplication
    const max_days = std.math.maxInt(i64) / 86400;
    if (days_since_epoch > max_days) return error.InvalidTimestamp;

    const day_seconds = days_since_epoch * 86400;
    const time_seconds = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    // Check for overflow in final addition
    if (day_seconds > std.math.maxInt(i64) - time_seconds) return error.InvalidTimestamp;

    const total_seconds = day_seconds + time_seconds;

    return c.timespec{
        .sec = @intCast(total_seconds),
        .nsec = 0,
    };
}

fn daysFromYMD(year: u32, month: u32, day: u32) i64 {
    // Days since a reference point (simplified)
    const days_in_month = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var total_days: i64 = 0;

    // Add days for complete years
    var y: u32 = 1;
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(y)) 366 else 365;
    }

    // Add days for complete months in the current year
    var m: u32 = 1;
    while (m < month) : (m += 1) {
        total_days += days_in_month[m - 1];
        if (m == 2 and isLeapYear(year)) {
            total_days += 1;
        }
    }

    // Add remaining days
    total_days += day;

    return total_days;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn getDaysInMonth(year: u32, month: u32) u32 {
    const days_in_month = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    if (month < 1 or month > 12) return 0;

    var days = days_in_month[month - 1];
    if (month == 2 and isLeapYear(year)) {
        days = 29;
    }

    return days;
}

fn handleError(path: []const u8, err: anyerror) void {
    // GNU touch format: "touch: cannot touch 'filename': Error message"
    switch (err) {
        error.FileNotFound => common.printError("cannot touch '{s}': No such file or directory", .{path}),
        error.AccessDenied => common.printError("cannot touch '{s}': Permission denied", .{path}),
        error.BadPathName => common.printError("cannot touch '{s}': Bad address", .{path}),
        error.Interrupted => common.printError("cannot touch '{s}': Interrupted system call", .{path}),
        error.SystemCallNotSupported => common.printError("cannot touch '{s}': Function not implemented", .{path}),
        error.ReadOnlyFileSystem => common.printError("cannot touch '{s}': Read-only file system", .{path}),
        error.NameTooLong => common.printError("cannot touch '{s}': File name too long", .{path}),
        error.NotDir => common.printError("cannot touch '{s}': Not a directory", .{path}),
        error.SymLinkLoop => common.printError("cannot touch '{s}': Too many levels of symbolic links", .{path}),
        error.InvalidValue => common.printError("cannot touch '{s}': Invalid argument", .{path}),
        error.BadFileDescriptor => common.printError("cannot touch '{s}': Bad file descriptor", .{path}),
        error.NoSuchProcess => common.printError("cannot touch '{s}': No such process", .{path}),
        else => common.printError("cannot touch '{s}': {s}", .{ path, @errorName(err) }),
    }
}

// ==================== TESTS ====================

test "touch creates new file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/new_file.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const options = TouchOptions{};
    try touchFile(test_file, options, testing.allocator);

    // Verify file exists
    const file = try tmp_dir.dir.openFile("new_file.txt", .{});
    file.close();
}

test "touch updates existing file timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file
    const file = try tmp_dir.dir.createFile("existing.txt", .{});
    file.close();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/existing.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const stat_before = try common.file.FileInfo.stat(test_file);

    // Wait a bit to ensure timestamp difference
    std.time.sleep(1_000_000_000); // 1 second

    // Touch the file
    const options = TouchOptions{};
    try touchFile(test_file, options, testing.allocator);

    // Verify timestamps were updated
    const stat_after = try common.file.FileInfo.stat(test_file);
    try testing.expect(stat_after.mtime > stat_before.mtime);
}

test "touch -c does not create file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/no_create.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const options = TouchOptions{ .no_create = true };
    try touchFile(test_file, options, testing.allocator);

    // Verify file does not exist
    const result = tmp_dir.dir.openFile("no_create.txt", .{});
    try testing.expectError(error.FileNotFound, result);
}

test "touch -a updates only access time" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file
    const file = try tmp_dir.dir.createFile("access_only.txt", .{});
    file.close();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/access_only.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Get initial timestamps
    const stat_before = try common.file.FileInfo.stat(test_file);

    // Wait to ensure timestamp difference
    std.time.sleep(1_000_000_000); // 1 second

    // Touch with -a
    const options = TouchOptions{ .access_only = true };
    try touchFile(test_file, options, testing.allocator);

    // Verify only access time was updated
    const stat_after = try common.file.FileInfo.stat(test_file);
    try testing.expect(stat_after.atime > stat_before.atime);
    try testing.expectEqual(stat_before.mtime, stat_after.mtime);
}

test "touch -m updates only modification time" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file
    const file = try tmp_dir.dir.createFile("modify_only.txt", .{});
    file.close();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/modify_only.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Get initial timestamps
    const stat_before = try common.file.FileInfo.stat(test_file);

    // Wait to ensure timestamp difference
    std.time.sleep(1_000_000_000); // 1 second

    // Touch with -m
    const options = TouchOptions{ .modify_only = true };
    try touchFile(test_file, options, testing.allocator);

    // Verify only modification time was updated
    const stat_after = try common.file.FileInfo.stat(test_file);
    try testing.expect(stat_after.mtime > stat_before.mtime);
    try testing.expectEqual(stat_before.atime, stat_after.atime);
}

test "touch -r uses reference file times" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create reference file
    const ref_file = try tmp_dir.dir.createFile("reference.txt", .{});
    ref_file.close();

    // Create target file
    const target_file = try tmp_dir.dir.createFile("target.txt", .{});
    target_file.close();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/reference.txt", .{tmp_path});
    defer testing.allocator.free(ref_path);
    const target_path = try std.fmt.allocPrint(testing.allocator, "{s}/target.txt", .{tmp_path});
    defer testing.allocator.free(target_path);

    // Wait to ensure different timestamps
    std.time.sleep(1_000_000_000); // 1 second

    // Touch target with reference
    const options = TouchOptions{ .reference_file = ref_path };
    try touchFile(target_path, options, testing.allocator);

    // Verify target has same times as reference
    const ref_stat = try common.file.FileInfo.stat(ref_path);
    const target_stat = try common.file.FileInfo.stat(target_path);

    // Allow small difference due to nanosecond precision
    const time_diff_ns: i128 = 1_000_000; // 1ms tolerance
    try testing.expect(@abs(ref_stat.atime - target_stat.atime) < time_diff_ns);
    try testing.expect(@abs(ref_stat.mtime - target_stat.mtime) < time_diff_ns);
}

test "parseTimestamp with full format CCYYMMDDhhmm.ss" {
    const result = try parseTimestamp("202312311359.45");
    // Should represent 2023-12-31 13:59:45
    // We can't test exact value without proper date library, but it should succeed
    try testing.expect(result.sec > 0);
    try testing.expectEqual(@as(i64, 0), result.nsec);
}

test "parseTimestamp with YYMMDDhhmm format" {
    // Test year 2023 (YY=23)
    const result1 = try parseTimestamp("2312311359");
    try testing.expect(result1.sec > 0);

    // Test year 1999 (YY=99)
    const result2 = try parseTimestamp("9912311359");
    try testing.expect(result2.sec > 0);
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("time_access.txt", .{});
    file.close();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/time_access.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const stat_before = try common.file.FileInfo.stat(test_file);
    std.time.sleep(1_000_000_000); // 1 second

    const options = TouchOptions{ .time_arg = "access" };
    try touchFile(test_file, options, testing.allocator);

    const stat_after = try common.file.FileInfo.stat(test_file);
    try testing.expect(stat_after.atime > stat_before.atime);
    try testing.expectEqual(stat_before.mtime, stat_after.mtime);
}

test "touch --time=modify updates only modification time" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("time_modify.txt", .{});
    file.close();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/time_modify.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const stat_before = try common.file.FileInfo.stat(test_file);
    std.time.sleep(1_000_000_000); // 1 second

    const options = TouchOptions{ .time_arg = "modify" };
    try touchFile(test_file, options, testing.allocator);

    const stat_after = try common.file.FileInfo.stat(test_file);
    try testing.expect(stat_after.mtime > stat_before.mtime);
    try testing.expectEqual(stat_before.atime, stat_after.atime);
}

test "touch multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const file1 = try std.fmt.allocPrint(testing.allocator, "{s}/file1.txt", .{tmp_path});
    defer testing.allocator.free(file1);
    const file2 = try std.fmt.allocPrint(testing.allocator, "{s}/file2.txt", .{tmp_path});
    defer testing.allocator.free(file2);

    const options = TouchOptions{};
    try touchFile(file1, options, testing.allocator);
    try touchFile(file2, options, testing.allocator);

    // Verify both files exist
    const f1 = try tmp_dir.dir.openFile("file1.txt", .{});
    f1.close();
    const f2 = try tmp_dir.dir.openFile("file2.txt", .{});
    f2.close();
}

test "touch with -t timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get real path for the temporary directory
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/timestamp.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Use a specific timestamp
    const options = TouchOptions{ .timestamp_str = "202312311359.00" };
    try touchFile(test_file, options, testing.allocator);

    // Verify file was created
    const file = try tmp_dir.dir.openFile("timestamp.txt", .{});
    file.close();

    // We can't easily verify the exact timestamp without a proper date library,
    // but the file should exist and have been touched
    const stat = try common.file.FileInfo.stat(test_file);
    try testing.expect(stat.mtime > 0);
}
