const std = @import("std");
const common = @import("common");
const types = @import("types.zig");
const display = @import("display.zig");

const Entry = types.Entry;
const LsOptions = types.LsOptions;
const TimeStyle = types.TimeStyle;

// Use common constants
const BLOCK_SIZE = common.constants.BLOCK_SIZE;
const BLOCK_ROUNDING = BLOCK_SIZE - 1;
const COLUMN_PADDING = common.constants.COLUMN_PADDING;

// Time constants for age-based coloring (in nanoseconds)
const NS_PER_MINUTE: i128 = 60 * std.time.ns_per_s;
const NS_PER_HOUR: i128 = 3600 * std.time.ns_per_s;
const NS_PER_DAY: i128 = 86400 * std.time.ns_per_s;
const NS_PER_WEEK: i128 = 7 * NS_PER_DAY;
const NS_PER_MONTH: i128 = 30 * NS_PER_DAY;
const NS_PER_6MONTHS: i128 = 180 * NS_PER_DAY;

/// Write permission string with per-character coloring.
/// Each permission character gets a distinct color based on its meaning.
fn writeColoredPermissions(style: anytype, writer: anytype, perms: []const u8) !void {
    if (style.color_mode == .none) {
        try writer.writeAll(perms);
        return;
    }
    for (perms) |ch| {
        switch (style.color_mode) {
            .truecolor => switch (ch) {
                'd' => {
                    try style.setBold();
                    try style.setRgb(110, 160, 220);
                },
                'l' => {
                    try style.setBold();
                    try style.setRgb(110, 185, 185);
                },
                'r' => try style.setRgb(195, 170, 110),
                'w' => try style.setRgb(195, 115, 110),
                'x', 's', 'S', 't', 'T' => try style.setRgb(115, 185, 120),
                '-' => try style.setRgb(100, 100, 115),
                else => {},
            },
            else => switch (ch) {
                'd' => {
                    try style.setBold();
                    try style.setColor(.blue);
                },
                'l' => {
                    try style.setBold();
                    try style.setColor(.cyan);
                },
                'r' => try style.setColor(.yellow),
                'w' => try style.setColor(.red),
                'x', 's', 'S', 't', 'T' => try style.setColor(.green),
                '-' => try style.setColor(.bright_black),
                else => {},
            },
        }
        try writer.writeByte(ch);
        try style.reset();
    }
}

/// Write link count dimmed with bright_black.
fn writeNlinkColored(style: anytype, writer: anytype, nlink: u32) !void {
    if (style.color_mode != .none) {
        if (style.color_mode == .truecolor) {
            try style.setRgb(100, 100, 115);
        } else {
            try style.setColor(.bright_black);
        }
    }
    try writer.print(" {d: >3} ", .{nlink});
    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write a single owner/group column with color.
fn writeOwnerColored(style: anytype, writer: anytype, name: []const u8) !void {
    if (style.color_mode != .none) {
        if (style.color_mode == .truecolor) {
            try style.setRgb(190, 165, 120);
        } else {
            try style.setColor(.yellow);
        }
    }
    try writer.print("{s: <8} ", .{name});
    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write a single group column with color.
fn writeGroupColored(style: anytype, writer: anytype, name: []const u8) !void {
    if (style.color_mode != .none) {
        if (style.color_mode == .truecolor) {
            try style.setRgb(150, 145, 185);
        } else {
            try style.setColor(.cyan);
        }
    }
    try writer.print("{s: <8} ", .{name});
    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write user and group names with distinct colors.
/// Truecolor: warm wheat for user, soft lavender for group.
/// 16-color: yellow for user, cyan for group.
fn writeUserGroupColored(style: anytype, writer: anytype, user_name: []const u8, group_name: []const u8, omit_owner: bool, omit_group: bool) !void {
    if (!omit_owner) {
        try writeOwnerColored(style, writer, user_name);
    }
    if (!omit_group) {
        try writeGroupColored(style, writer, group_name);
    }
}

/// Write size with tiered color based on file size.
/// Truecolor: smooth RGB gradient from green (small) to red-orange (large).
/// 256-color: approximate palette indices.
/// 16-color: green (normal), bold green (human-readable).
fn writeSizeColored(style: anytype, writer: anytype, size_str: []const u8, size: u64, human_readable: bool) !void {
    if (style.color_mode != .none) {
        if (human_readable and style.color_mode == .basic) try style.setBold();
        try common.colors.applySizeColor(style, size);
    }

    if (human_readable) {
        try writer.print("{s: >5} ", .{size_str});
    } else {
        try writer.print("{s: >8} ", .{size_str});
    }

    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write date/time with tiered color based on file age.
/// Recent files are bright green, aging through blue to dim gray.
fn writeDateColored(style: anytype, writer: anytype, time_str: []const u8, mtime_ns: i128, max_time_width: usize) !void {
    if (style.color_mode != .none) {
        const now_ns = common.file.currentTimestampNanoseconds();
        const age_ns = now_ns - mtime_ns;

        switch (style.color_mode) {
            .truecolor => {
                if (age_ns < NS_PER_MINUTE) {
                    try style.setRgb(115, 230, 120);
                } else if (age_ns < NS_PER_HOUR) {
                    try style.setRgb(100, 200, 170);
                } else if (age_ns < NS_PER_DAY) {
                    try style.setRgb(100, 180, 210);
                } else if (age_ns < 2 * NS_PER_DAY) {
                    try style.setRgb(115, 150, 220);
                } else if (age_ns < NS_PER_WEEK) {
                    try style.setRgb(130, 135, 210);
                } else if (age_ns < NS_PER_MONTH) {
                    try style.setRgb(150, 130, 190);
                } else if (age_ns < NS_PER_6MONTHS) {
                    try style.setRgb(160, 130, 170);
                } else {
                    try style.setRgb(140, 140, 155);
                }
            },
            .extended => {
                if (age_ns < NS_PER_MINUTE) {
                    try style.set256(119);
                } else if (age_ns < NS_PER_HOUR) {
                    try style.set256(115);
                } else if (age_ns < NS_PER_DAY) {
                    try style.set256(117);
                } else if (age_ns < 2 * NS_PER_DAY) {
                    try style.set256(111);
                } else if (age_ns < NS_PER_WEEK) {
                    try style.set256(105);
                } else if (age_ns < NS_PER_MONTH) {
                    try style.set256(140);
                } else if (age_ns < NS_PER_6MONTHS) {
                    try style.set256(139);
                } else {
                    try style.set256(249);
                }
            },
            .basic => try style.setColor(.blue),
            .none => {},
        }
    }

    try writer.print("{s}", .{time_str});
    // Pad to max_time_width
    if (time_str.len < max_time_width) {
        const pad = max_time_width - time_str.len;
        for (0..pad) |_| {
            try writer.writeByte(' ');
        }
    }
    try writer.writeByte(' ');

    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Format timestamp according to the specified time style
pub fn formatTimeWithStyle(mtime_ns: i128, time_style: TimeStyle, allocator: std.mem.Allocator, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(NS_PER_6MONTHS > NS_PER_MONTH);
    switch (time_style) {
        .default => return formatTimeWithStyle_default(mtime_ns, buf),
        .relative => return formatTimeWithStyle_relative(mtime_ns, allocator, buf),
        .iso => return formatTimeWithStyle_iso(mtime_ns, buf),
        .@"long-iso" => return formatTimeWithStyle_longIso(mtime_ns, buf),
        .full => return formatTimeWithStyle_full(mtime_ns, buf),
    }
}

/// Traditional ls format: "Mar  1 14:30" or "Jan 15  2024".
fn formatTimeWithStyle_default(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(NS_PER_6MONTHS > 0);
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const secs = std.math.cast(u64, mtime_s) orelse return error.InvalidTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const month_idx = @intFromEnum(month_day.month) - 1;
    const month_name = month_names[month_idx];
    const day = month_day.day_index + 1;

    // Determine if file is older than 6 months
    const now_ns = common.file.currentTimestampNanoseconds();
    const age_ns = now_ns - mtime_ns;

    if (age_ns >= NS_PER_6MONTHS) {
        // Old file: "Jan 15  2024"
        return std.fmt.bufPrint(buf, "{s} {d: >2}  {d}", .{ month_name, day, year_day.year });
    } else {
        // Recent file: "Mar  1 14:30"
        return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}", .{
            month_name,
            day,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
        });
    }
}

/// Relative date format like "2 hours ago", truncated with ellipsis.
fn formatTimeWithStyle_relative(
    mtime_ns: i128,
    allocator: std.mem.Allocator,
    buf: []u8,
) ![]const u8 {
    std.debug.assert(buf.len > 3);
    std.debug.assert(std.time.ns_per_s > 0);
    // Use relative date formatting
    const config = common.relative_date.defaultConfig();
    const relative_str = try common.relative_date.formatRelativeDate(mtime_ns, config, allocator);
    defer allocator.free(relative_str);

    // Truncation with ellipsis for very long strings - trust compile-time buffer sizing
    if (relative_str.len >= buf.len) {
        const truncate_len = buf.len - 3;
        @memcpy(buf[0..truncate_len], relative_str[0..truncate_len]);
        @memcpy(buf[truncate_len .. truncate_len + 3], "...");
        return buf[0..buf.len];
    }
    @memcpy(buf[0..relative_str.len], relative_str);
    return buf[0..relative_str.len];
}

/// ISO format: 2024-01-15 15:30.
fn formatTimeWithStyle_iso(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(std.time.ns_per_s > 0);
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const secs = std.math.cast(u64, mtime_s) orelse return error.InvalidTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
}

/// Long ISO format: 2024-01-15 15:30:45.123456789 +0000.
fn formatTimeWithStyle_longIso(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(std.time.ns_per_s > 0);
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const nano_remainder = @mod(mtime_ns, std.time.ns_per_s);
    const secs = std.math.cast(u64, mtime_s) orelse return error.InvalidTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9} +0000", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        @abs(nano_remainder),
    });
}

/// Full time: "Mar  1 14:30:45 2024" (always shows seconds and year).
fn formatTimeWithStyle_full(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(std.time.ns_per_s > 0);
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const secs = std.math.cast(u64, mtime_s) orelse return error.InvalidTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const month_idx = @intFromEnum(month_day.month) - 1;
    const month_name = month_names[month_idx];
    const day = month_day.day_index + 1;

    return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        month_name,
        day,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        year_day.year,
    });
}

/// Print a single entry in long format (public API, no time alignment)
pub fn printLongFormatEntry(allocator: std.mem.Allocator, entry: Entry, writer: anytype, options: LsOptions, style: anytype) !void {
    return printLongFormatEntryAligned(allocator, entry, writer, options, style, 0);
}

/// Print a single entry in long format with time column alignment
fn printLongFormatEntryAligned(allocator: std.mem.Allocator, entry: Entry, writer: anytype, options: LsOptions, style: anytype, max_time_width: usize) !void {
    // Per-entry block count if -s is active
    if (options.show_blocks) {
        const blocks = calculateDisplayBlocks(entry, options);
        try writer.print("{d: >4} ", .{blocks});
    }

    // Permission string
    var perm_buf: [10]u8 = undefined;
    const perms = if (entry.stat) |stat|
        try common.file.formatPermissions(stat.mode, stat.kind, &perm_buf)
    else
        "----------";

    try writeColoredPermissions(style, writer, perms);

    // Number of links
    if (entry.stat) |stat| {
        try writeNlinkColored(style, writer, stat.nlink);
    } else {
        try writer.writeAll("   ? ");
    }

    // User and group names/IDs
    try printLongFormatEntryAligned_ownerGroup(style, writer, entry, options);

    // Size
    try printLongFormatEntryAligned_size(style, writer, entry, options);

    // Date/time (padded to max_time_width for alignment)
    if (entry.stat) |stat| {
        var time_buf: [128]u8 = undefined;
        const time_field = if (options.use_ctime)
            stat.ctime
        else if (options.use_atime)
            stat.atime
        else
            stat.mtime;
        const effective_time_style = if (options.full_time) TimeStyle.full else options.time_style;
        const time_str = try formatTimeWithStyle(
            time_field,
            effective_time_style,
            allocator,
            &time_buf,
        );
        try writeDateColored(style, writer, time_str, time_field, max_time_width);
    } else {
        try writer.writeAll("??? ?? ??:?? ");
    }

    // Name with color and optional indicator
    try display.printEntryName(entry, writer, style, options);

    // Show symlink target if available, colored by target's file type
    if (entry.symlink_target) |target| {
        try printLongFormatEntryAligned_symlinkTarget(style, writer, target);
    }
    try writer.writeByte('\n');
}

/// Write " -> target" for a symlink, colored by the target's file type.
fn printLongFormatEntryAligned_symlinkTarget(
    style: anytype,
    writer: anytype,
    target: []const u8,
) !void {
    std.debug.assert(@TypeOf(target) == []const u8);
    std.debug.assert(target.len > 0);
    try writer.writeAll(" -> ");
    if (style.color_mode != .none) {
        // Stat the target (lstat — no io needed) to get its kind for coloring
        const target_kind = blk: {
            const stat = common.file.FileInfo.lstat(target) catch break :blk null;
            break :blk stat.kind;
        };
        if (target_kind) |kind| {
            try style.setColor(display.getColorForKind(kind));
        } else {
            // Dangling symlink — show in red
            try style.setColor(.red);
        }
        try writer.print("{s}", .{target});
        try style.reset();
    } else {
        try writer.print("{s}", .{target});
    }
}

/// Write the user/group column of a long-format entry.
/// Falls back to "?" placeholders when stat is unavailable.
fn printLongFormatEntryAligned_ownerGroup(
    style: anytype,
    writer: anytype,
    entry: Entry,
    options: LsOptions,
) !void {
    std.debug.assert(@TypeOf(options.omit_owner) == bool);
    std.debug.assert(@TypeOf(options.omit_group) == bool);
    if (entry.stat) |stat| {
        if (options.numeric_ids) {
            // Show numeric IDs (colored yellow)
            var uid_buf: [16]u8 = undefined;
            var gid_buf: [16]u8 = undefined;
            const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{stat.uid}) catch "?";
            const gid_str = std.fmt.bufPrint(&gid_buf, "{d}", .{stat.gid}) catch "?";
            try writeUserGroupColored(
                style,
                writer,
                uid_str,
                gid_str,
                options.omit_owner,
                options.omit_group,
            );
        } else {
            // Show names (default behavior)
            var user_buf: [32]u8 = undefined;
            var group_buf: [32]u8 = undefined;
            const user_name = try common.file.getUserName(stat.uid, &user_buf);
            const group_name = try common.file.getGroupName(stat.gid, &group_buf);
            try writeUserGroupColored(
                style,
                writer,
                user_name,
                group_name,
                options.omit_owner,
                options.omit_group,
            );
        }
    } else {
        if (!options.omit_owner) try writer.writeAll("?        ");
        if (!options.omit_group) try writer.writeAll("?        ");
    }
}

/// Write the size column of a long-format entry.
/// Falls back to "?" when stat is unavailable.
fn printLongFormatEntryAligned_size(
    style: anytype,
    writer: anytype,
    entry: Entry,
    options: LsOptions,
) !void {
    std.debug.assert(@TypeOf(options.human_readable) == bool);
    std.debug.assert(@TypeOf(options.kilobytes) == bool);
    if (entry.stat) |stat| {
        var size_buf: [32]u8 = undefined;
        const size_str = if (options.human_readable)
            try common.file.formatSizeHuman(stat.size, &size_buf)
        else if (options.kilobytes)
            try common.file.formatSizeKilobytes(stat.size, &size_buf)
        else if (options.thousands_grouping)
            formatWithThousands(stat.size, &size_buf)
        else
            try common.file.formatSize(stat.size, &size_buf);

        try writeSizeColored(style, writer, size_str, stat.size, options.human_readable);
    } else {
        try writer.writeAll("       ? ");
    }
}

/// Format a number with thousands grouping (commas).
/// Example: 1234567 -> "1,234,567"
fn formatWithThousands(size: u64, buf: []u8) []const u8 {
    // First format the plain number
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{size}) catch return "?";

    if (num_str.len <= 3) {
        @memcpy(buf[0..num_str.len], num_str);
        return buf[0..num_str.len];
    }

    // Calculate output length: digits + number of commas
    const num_commas = (num_str.len - 1) / 3;
    const total_len = num_str.len + num_commas;
    if (total_len > buf.len) return num_str;

    var out: usize = 0;
    for (num_str, 0..) |c, i| {
        if (i > 0 and (num_str.len - i) % 3 == 0) {
            buf[out] = ',';
            out += 1;
        }
        buf[out] = c;
        out += 1;
    }
    return buf[0..out];
}

/// Calculate the display width of a block count number
fn blockCountWidth(blocks: u64) usize {
    if (blocks == 0) return 1;
    var n = blocks;
    var width: usize = 0;
    while (n > 0) {
        n /= 10;
        width += 1;
    }
    return width;
}

/// Print entries in columnar format
pub fn printColumnar(allocator: std.mem.Allocator, entries: []Entry, writer: anytype, options: LsOptions, style: anytype) !void {
    if (entries.len == 0) return;

    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth(allocator) catch 80;

    // Calculate block width prefix if -s is enabled
    var block_prefix_width: usize = 0;
    if (options.show_blocks) {
        var max_block_width: usize = 0;
        for (entries) |entry| {
            max_block_width = @max(max_block_width, blockCountWidth(calculateDisplayBlocks(entry, options)));
        }
        block_prefix_width = max_block_width + 1; // block count + space
    }

    // Pre-calculate display widths for all entries in a single pass
    // This ensures all widths are cached and finds the maximum width
    var max_width: usize = 0;
    for (entries) |*entry| {
        const width = entry.getDisplayWidth(options.file_type_indicators, options.append_slash_dirs, common.icons.shouldShowIcons(options.icon_mode, options.is_terminal), options.show_git_status);
        max_width = @max(max_width, width);
    }

    // Add padding between columns, including block prefix
    const col_width = block_prefix_width + max_width + COLUMN_PADDING;

    // Calculate number of columns that fit
    const num_cols = @max(1, term_width / col_width);

    // Calculate number of rows needed
    const num_rows = (entries.len + num_cols - 1) / num_cols;

    // Print in column-major order (like GNU ls)
    for (0..num_rows) |row| {
        for (0..num_cols) |col| {
            const idx = col * num_rows + row;
            if (idx >= entries.len) break;

            const entry = entries[idx];

            // Print block count prefix if -s
            if (options.show_blocks) {
                const blocks = calculateDisplayBlocks(entry, options);
                // Right-align block count to max_block_width
                const bw = blockCountWidth(blocks);
                const pad_count = if (block_prefix_width > bw + 1) block_prefix_width - bw - 1 else 0;
                for (0..pad_count) |_| {
                    try writer.writeByte(' ');
                }
                try writer.print("{d} ", .{blocks});
            }

            // Print entry name with color and indicator
            try display.printEntryName(entry, writer, style, options);

            // Pad to column width (except for last column)
            if (col < num_cols - 1 and idx < entries.len - 1) {
                // This uses cached width from the pre-calculation pass above
                const width = entries[idx].getDisplayWidth(options.file_type_indicators, options.append_slash_dirs, common.icons.shouldShowIcons(options.icon_mode, options.is_terminal), options.show_git_status);
                const padding = max_width + COLUMN_PADDING - width;
                for (0..padding) |_| {
                    try writer.writeByte(' ');
                }
            }
        }
        try writer.writeByte('\n');
    }
}

/// Calculate filesystem blocks for a file (512-byte units)
fn calculateBlocks(entry: Entry) u64 {
    if (entry.stat) |stat| {
        return (stat.size + BLOCK_ROUNDING) / BLOCK_SIZE;
    }
    return 0;
}

/// Calculate display blocks, respecting -k (1024-byte units)
fn calculateDisplayBlocks(entry: Entry, options: LsOptions) u64 {
    if (entry.stat) |stat| {
        if (options.kilobytes) {
            return (stat.size + 1023) / 1024;
        }
        return (stat.size + BLOCK_ROUNDING) / BLOCK_SIZE;
    }
    return 0;
}

/// Print entries in columnar format sorted across rows (-x flag)
pub fn printColumnarAcross(allocator: std.mem.Allocator, entries: []Entry, writer: anytype, options: LsOptions, style: anytype) !void {
    if (entries.len == 0) return;

    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth(allocator) catch 80;

    // Calculate block width prefix if -s is enabled
    var block_prefix_width: usize = 0;
    if (options.show_blocks) {
        var max_block_width: usize = 0;
        for (entries) |entry| {
            max_block_width = @max(max_block_width, blockCountWidth(calculateDisplayBlocks(entry, options)));
        }
        block_prefix_width = max_block_width + 1; // block count + space
    }

    // Pre-calculate display widths for all entries in a single pass
    var max_width: usize = 0;
    for (entries) |*entry| {
        const width = entry.getDisplayWidth(options.file_type_indicators, options.append_slash_dirs, common.icons.shouldShowIcons(options.icon_mode, options.is_terminal), options.show_git_status);
        max_width = @max(max_width, width);
    }

    // Add padding between columns, including block prefix
    const col_width = block_prefix_width + max_width + COLUMN_PADDING;

    // Calculate number of columns that fit
    const num_cols = @max(1, term_width / col_width);

    // Print in row-major order (across rows, like -x)
    for (entries, 0..) |entry, idx| {
        // Print block count prefix if -s
        if (options.show_blocks) {
            const blocks = calculateDisplayBlocks(entry, options);
            const bw = blockCountWidth(blocks);
            const pad_count = if (block_prefix_width > bw + 1) block_prefix_width - bw - 1 else 0;
            for (0..pad_count) |_| {
                try writer.writeByte(' ');
            }
            try writer.print("{d} ", .{blocks});
        }

        try display.printEntryName(entry, writer, style, options);

        // Check if this is the last entry on the row or the last entry overall
        const col = idx % num_cols;
        if (col == num_cols - 1 or idx == entries.len - 1) {
            try writer.writeByte('\n');
        } else {
            // Pad to column width
            const width = entries[idx].getDisplayWidth(options.file_type_indicators, options.append_slash_dirs, common.icons.shouldShowIcons(options.icon_mode, options.is_terminal), options.show_git_status);
            const padding = max_width + COLUMN_PADDING - width;
            for (0..padding) |_| {
                try writer.writeByte(' ');
            }
        }
    }
}

/// Print entries in the appropriate format based on options
pub fn printEntries(
    allocator: std.mem.Allocator,
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !u64 {
    var total_blocks: u64 = 0;

    // Calculate total blocks for -s or -l
    if (options.show_blocks or options.long_format) {
        for (entries) |entry| {
            total_blocks += calculateDisplayBlocks(entry, options);
        }
    }

    // Print total blocks line for -s (in any format) or -l
    if (options.show_blocks and entries.len > 0 and !options.long_format) {
        try writer.print("total {d}\n", .{total_blocks});
    }

    if (options.one_per_line) {
        try printEntries_onePerLine(entries, writer, options, style);
    } else if (options.long_format) {
        try printEntries_longFormat(allocator, entries, writer, options, style, total_blocks);
    } else if (options.comma_format) {
        // Comma-separated format
        for (entries, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try display.printEntryName(entry, writer, style, options);
        }
        if (entries.len > 0) try writer.writeByte('\n');
    } else if (options.columns_across) {
        // -x: multi-column sorted across rows
        try printColumnarAcross(allocator, entries, writer, options, style);
    } else {
        // Default format: multi-column layout (sorted down columns)
        try printColumnar(allocator, entries, writer, options, style);
    }

    return total_blocks;
}

/// Print entries one per line (-1), disabling icons and git status.
fn printEntries_onePerLine(
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    std.debug.assert(options.one_per_line);
    std.debug.assert(@TypeOf(options.show_blocks) == bool);
    for (entries) |entry| {
        // Print block count if -s
        if (options.show_blocks) {
            try writer.print("{d: >4} ", .{calculateDisplayBlocks(entry, options)});
        }
        // Print inode number if requested
        if (options.show_inodes) {
            if (entry.stat) |stat| {
                try writer.print("{d} ", .{stat.inode});
            } else {
                try writer.print("? ", .{});
            }
        }
        // In one-per-line mode, disable icons and git status
        var one_opts = options;
        one_opts.icon_mode = .never;
        one_opts.show_git_status = false;
        try display.printEntryName(entry, writer, style, one_opts);
        try writer.writeByte('\n');
    }
}

/// Print entries in long format (-l), computing the time column width first.
fn printEntries_longFormat(
    allocator: std.mem.Allocator,
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
    total_blocks: u64,
) !void {
    std.debug.assert(options.long_format);
    std.debug.assert(@TypeOf(total_blocks) == u64);
    // Print total if we have entries
    if (entries.len > 0) {
        try writer.print("total {d}\n", .{total_blocks});
    }

    // Pre-calculate max time width for alignment
    var max_time_width: usize = 0; // tiger:allow:usize-arch slice .len is usize
    for (entries) |entry| {
        if (entry.stat) |stat| {
            var tbuf: [128]u8 = undefined;
            const time_field = if (options.use_ctime)
                stat.ctime
            else if (options.use_atime)
                stat.atime
            else
                stat.mtime;
            const eff_ts = if (options.full_time) TimeStyle.full else options.time_style;
            const ts = formatTimeWithStyle(time_field, eff_ts, allocator, &tbuf) catch continue;
            max_time_width = @max(max_time_width, ts.len);
        }
    }

    // Print each entry in long format
    for (entries) |entry| {
        try printLongFormatEntryAligned(
            allocator,
            entry,
            writer,
            options,
            style,
            max_time_width,
        );
    }
}

// Tests
const testing = std.testing;

test "formatter - formatTimeWithStyle relative" {
    const allocator = testing.allocator;
    var buf: [128]u8 = undefined;

    // Test recent time (should show relative format)
    const now_ns = common.file.currentTimestampNanoseconds();
    const one_hour_ago = now_ns - (3600 * std.time.ns_per_s);

    const result = try formatTimeWithStyle(one_hour_ago, .relative, allocator, &buf);

    // Should contain "ago" for past times
    try testing.expect(std.mem.indexOf(u8, result, "ago") != null);
}

test "formatter - formatTimeWithStyle default recent" {
    var buf: [128]u8 = undefined;

    // Test recent time (should show "Mon DD HH:MM" format)
    const now_ns = common.file.currentTimestampNanoseconds();
    const one_hour_ago = now_ns - (3600 * std.time.ns_per_s);

    const result = try formatTimeWithStyle(one_hour_ago, .default, testing.allocator, &buf);

    // Should contain a colon (HH:MM format for recent files)
    try testing.expect(std.mem.indexOf(u8, result, ":") != null);
    // Should be 12 characters: "Mon DD HH:MM"
    try testing.expectEqual(@as(usize, 12), result.len);
}

test "formatter - formatTimeWithStyle default old" {
    var buf: [128]u8 = undefined;

    // Test old time (> 6 months, should show "Mon DD  YYYY" format)
    const now_ns = common.file.currentTimestampNanoseconds();
    const one_year_ago = now_ns - (365 * 86400 * @as(i128, std.time.ns_per_s));

    const result = try formatTimeWithStyle(one_year_ago, .default, testing.allocator, &buf);

    // Should NOT contain a colon (year format for old files)
    try testing.expect(std.mem.indexOf(u8, result, ":") == null);
    // Should be 12 characters: "Mon DD  YYYY"
    try testing.expectEqual(@as(usize, 12), result.len);
}

test "formatter - formatTimeWithStyle full" {
    var buf: [128]u8 = undefined;

    // Test specific timestamp: 2024-01-15 15:30:45 UTC
    const test_time_ns: i128 = 1705332645 * std.time.ns_per_s;

    const result = try formatTimeWithStyle(test_time_ns, .full, testing.allocator, &buf);

    // Full format: "Mon DD HH:MM:SS YYYY" - should contain seconds and year
    try testing.expect(std.mem.indexOf(u8, result, "2024") != null);
    // Should have 2 colons (HH:MM:SS)
    var colon_count: usize = 0;
    for (result) |ch| {
        if (ch == ':') colon_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), colon_count);
    // Should contain month name
    try testing.expect(std.mem.indexOf(u8, result, "Jan") != null);
}

test "formatter - formatTimeWithStyle full always shows year" {
    var buf: [128]u8 = undefined;

    // Test recent timestamp (should still show year, unlike default)
    const now_ns = common.file.currentTimestampNanoseconds();
    const one_hour_ago = now_ns - (3600 * std.time.ns_per_s);

    const result = try formatTimeWithStyle(one_hour_ago, .full, testing.allocator, &buf);

    // Full format always shows year, even for recent files
    // Should have 2 colons (HH:MM:SS)
    var colon_count: usize = 0;
    for (result) |ch| {
        if (ch == ':') colon_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), colon_count);
}

test "formatter - formatTimeWithStyle iso" {
    var buf: [128]u8 = undefined;

    // Test specific timestamp: 2024-01-15 15:30:00 UTC
    // This is approximately 1705332600 seconds since epoch
    const test_time_ns: i128 = 1705332600 * std.time.ns_per_s;

    const result = try formatTimeWithStyle(test_time_ns, .iso, testing.allocator, &buf);

    // Should contain year and time format
    try testing.expect(std.mem.indexOf(u8, result, "2024") != null);
    try testing.expect(std.mem.indexOf(u8, result, ":") != null);
}

test "formatter - printColumnar basic" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();

    var entries = [_]Entry{
        .{ .name = "file1", .kind = .file },
        .{ .name = "file2", .kind = .file },
        .{ .name = "file3", .kind = .file },
    };

    const options = LsOptions{ .terminal_width = 40 };
    const style = try display.initStyle(testing.allocator, &buf_aw.writer, .never);

    try printColumnar(testing.allocator, &entries, &buf_aw.writer, options, style);

    const output = buf_aw.writer.buffered();

    // Should contain all files
    try testing.expect(std.mem.indexOf(u8, output, "file1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file3") != null);
}

// Helper to create a test style with a specific color mode
const TestStyle = common.style.Style(*std.Io.Writer);

fn makeTestStyle(writer: *std.Io.Writer, color_mode: TestStyle.ColorMode) TestStyle {
    return TestStyle{ .color_mode = color_mode, .writer = writer };
}

test "writeColoredPermissions - no color mode writes plain string" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeColoredPermissions(style, &buf_aw.writer, "drwxr-xr-x");
    try testing.expectEqualSlices(u8, "drwxr-xr-x", buf_aw.writer.buffered());
}

test "writeColoredPermissions - basic mode adds ANSI codes" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeColoredPermissions(style, &buf_aw.writer, "drwx------");
    const output = buf_aw.writer.buffered();

    // Output should contain ANSI escape sequences
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
    // Output should contain the actual permission characters
    try testing.expect(std.mem.indexOf(u8, output, "d") != null);
    try testing.expect(std.mem.indexOf(u8, output, "r") != null);
    try testing.expect(std.mem.indexOf(u8, output, "w") != null);
    try testing.expect(std.mem.indexOf(u8, output, "x") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-") != null);
}

test "writeColoredPermissions - symlink permissions" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeColoredPermissions(style, &buf_aw.writer, "lrwxrwxrwx");
    const output = buf_aw.writer.buffered();

    // Should contain cyan code for 'l' (36) and bold (1)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null);
}

test "writeNlinkColored - no color writes plain" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeNlinkColored(style, &buf_aw.writer, 3);
    try testing.expectEqualSlices(u8, "   3 ", buf_aw.writer.buffered());
}

test "writeNlinkColored - basic mode uses bright_black" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeNlinkColored(style, &buf_aw.writer, 1);
    const output = buf_aw.writer.buffered();

    // Should contain bright_black (90) escape code
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[90m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1") != null);
    // Should end with reset
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
}

test "writeUserGroupColored - no color writes plain" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeUserGroupColored(style, &buf_aw.writer, "root", "wheel", false, false);
    try testing.expectEqualSlices(u8, "root     wheel    ", buf_aw.writer.buffered());
}

test "writeUserGroupColored - basic mode uses yellow for user and cyan for group" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeUserGroupColored(style, &buf_aw.writer, "root", "wheel", false, false);
    const output = buf_aw.writer.buffered();

    // Should contain yellow (33) for user and cyan (36) for group
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[33m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "root") != null);
    try testing.expect(std.mem.indexOf(u8, output, "wheel") != null);
}

test "writeUserGroupColored - omit_owner hides user column" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeUserGroupColored(style, &buf_aw.writer, "root", "wheel", true, false);
    try testing.expectEqualSlices(u8, "wheel    ", buf_aw.writer.buffered());
}

test "writeUserGroupColored - omit_group hides group column" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeUserGroupColored(style, &buf_aw.writer, "root", "wheel", false, true);
    try testing.expectEqualSlices(u8, "root     ", buf_aw.writer.buffered());
}

test "writeSizeColored - no color writes plain" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeSizeColored(style, &buf_aw.writer, "4096", 4096, false);
    try testing.expectEqualSlices(u8, "    4096 ", buf_aw.writer.buffered());
}

test "writeSizeColored - human readable format" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    try writeSizeColored(style, &buf_aw.writer, "4.0K", 4096, true);
    try testing.expectEqualSlices(u8, " 4.0K ", buf_aw.writer.buffered());
}

test "writeSizeColored - truecolor small file uses green" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .truecolor);

    try writeSizeColored(style, &buf_aw.writer, "512", 512, false);
    const output = buf_aw.writer.buffered();

    // Small file: RGB (115, 195, 120)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;115;195;120m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
}

test "writeSizeColored - truecolor large file uses red-orange" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .truecolor);

    const large_size: u64 = 20 * 1024 * 1024; // 20MB
    try writeSizeColored(style, &buf_aw.writer, "20971520", large_size, false);
    const output = buf_aw.writer.buffered();

    // Large file: RGB (210, 115, 100)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;210;115;100m") != null);
}

test "writeSizeColored - 256 color mode" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .extended);

    // 50KB file should use index 149 (yellow-green)
    try writeSizeColored(style, &buf_aw.writer, "51200", 51200, false);
    const output = buf_aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;5;149m") != null);
}

test "writeSizeColored - basic mode uses green" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeSizeColored(style, &buf_aw.writer, "100", 100, false);
    const output = buf_aw.writer.buffered();

    // Basic mode: green (32)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[32m") != null);
}

test "writeSizeColored - basic mode bold for human readable" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeSizeColored(style, &buf_aw.writer, "4.0K", 4096, true);
    const output = buf_aw.writer.buffered();

    // Basic mode with human_readable: bold + green
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[32m") != null);
}

test "writeDateColored - no color writes plain" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    const now_ns = common.file.currentTimestampNanoseconds();
    try writeDateColored(style, &buf_aw.writer, "2024-01-15 15:30", now_ns, 16);
    try testing.expectEqualSlices(u8, "2024-01-15 15:30 ", buf_aw.writer.buffered());
}

test "writeDateColored - truecolor recent file uses bright green" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .truecolor);

    // File modified 30 seconds ago (< 1 minute)
    const now_ns = common.file.currentTimestampNanoseconds();
    const recent_ns = now_ns - (30 * std.time.ns_per_s);
    try writeDateColored(style, &buf_aw.writer, "just now", recent_ns, 8);
    const output = buf_aw.writer.buffered();

    // Recent: RGB (115, 230, 120)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;115;230;120m") != null);
}

test "writeDateColored - truecolor old file uses gray" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .truecolor);

    // File modified 1 year ago (> 6 months)
    const now_ns = common.file.currentTimestampNanoseconds();
    const old_ns = now_ns - (365 * 86400 * @as(i128, std.time.ns_per_s));
    try writeDateColored(style, &buf_aw.writer, "2023-01-15", old_ns, 10);
    const output = buf_aw.writer.buffered();

    // Old: RGB (140, 140, 155)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;140;140;155m") != null);
}

test "writeDateColored - 256 color mode recent" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .extended);

    const now_ns = common.file.currentTimestampNanoseconds();
    const recent_ns = now_ns - (30 * std.time.ns_per_s);
    try writeDateColored(style, &buf_aw.writer, "just now", recent_ns, 8);
    const output = buf_aw.writer.buffered();

    // Recent: index 119
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;5;119m") != null);
}

test "writeDateColored - basic mode uses blue" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    const now_ns = common.file.currentTimestampNanoseconds();
    try writeDateColored(style, &buf_aw.writer, "2024-01-15", now_ns, 10);
    const output = buf_aw.writer.buffered();

    // Basic mode: blue (34)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[34m") != null);
}

test "writeDateColored - pads to max width" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    const now_ns = common.file.currentTimestampNanoseconds();
    try writeDateColored(style, &buf_aw.writer, "short", now_ns, 10);

    // "short" is 5 chars, max_time_width is 10, so 5 spaces of padding + 1 trailing space
    try testing.expectEqualSlices(u8, "short      ", buf_aw.writer.buffered());
}

test "writeSizeColored - all truecolor tiers" {
    const tiers = .{
        .{ .size = 500, .r = 115, .g = 195, .b = 120 }, // < 1K
        .{ .size = 50_000, .r = 150, .g = 195, .b = 110 }, // < 100K
        .{ .size = 500_000, .r = 195, .g = 185, .b = 100 }, // < 1M
        .{ .size = 5_000_000, .r = 210, .g = 155, .b = 90 }, // < 10M
        .{ .size = 50_000_000, .r = 210, .g = 115, .b = 100 }, // > 10M
    };

    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();

    inline for (tiers) |tier| {
        buf_aw.writer.end = 0;
        const style = makeTestStyle(&buf_aw.writer, .truecolor);

        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{tier.size}) catch unreachable;
        try writeSizeColored(style, &buf_aw.writer, size_str, tier.size, false);

        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "\x1b[38;2;{d};{d};{d}m", .{ tier.r, tier.g, tier.b }) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, buf_aw.writer.buffered(), expected) != null);
    }
}

test "writeDateColored - all truecolor age tiers" {
    const now_ns = common.file.currentTimestampNanoseconds();
    const tiers = .{
        .{ .age = 30 * std.time.ns_per_s, .r = 115, .g = 230, .b = 120 }, // < 1 min
        .{ .age = 30 * NS_PER_MINUTE, .r = 100, .g = 200, .b = 170 }, // < 1 hour
        .{ .age = 12 * NS_PER_HOUR, .r = 100, .g = 180, .b = 210 }, // < 1 day
        .{ .age = 36 * NS_PER_HOUR, .r = 115, .g = 150, .b = 220 }, // < 2 days
        .{ .age = 4 * NS_PER_DAY, .r = 130, .g = 135, .b = 210 }, // < 1 week
        .{ .age = 15 * NS_PER_DAY, .r = 150, .g = 130, .b = 190 }, // < 1 month
        .{ .age = 90 * NS_PER_DAY, .r = 160, .g = 130, .b = 170 }, // < 6 months
        .{ .age = 365 * NS_PER_DAY, .r = 140, .g = 140, .b = 155 }, // >= 6 months
    };

    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();

    inline for (tiers) |tier| {
        buf_aw.writer.end = 0;
        const style = makeTestStyle(&buf_aw.writer, .truecolor);

        const mtime_ns = now_ns - tier.age;
        try writeDateColored(style, &buf_aw.writer, "test", mtime_ns, 4);

        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "\x1b[38;2;{d};{d};{d}m", .{ tier.r, tier.g, tier.b }) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, buf_aw.writer.buffered(), expected) != null);
    }
}

test "formatWithThousands - basic formatting" {
    var buf: [32]u8 = undefined;

    try testing.expectEqualStrings("0", formatWithThousands(0, &buf));
    try testing.expectEqualStrings("999", formatWithThousands(999, &buf));
    try testing.expectEqualStrings("1,000", formatWithThousands(1000, &buf));
    try testing.expectEqualStrings("1,234", formatWithThousands(1234, &buf));
    try testing.expectEqualStrings("12,345", formatWithThousands(12345, &buf));
    try testing.expectEqualStrings("123,456", formatWithThousands(123456, &buf));
    try testing.expectEqualStrings("1,234,567", formatWithThousands(1234567, &buf));
    try testing.expectEqualStrings("1,234,567,890", formatWithThousands(1234567890, &buf));
}
