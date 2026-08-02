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

/// Terminal tab stop interval. -C rounds its column width up to a multiple of
/// this and pads with literal tabs, matching BSD ls; -x keeps space padding.
const TAB_WIDTH: usize = 8; // tiger:allow:usize-arch mixes with getDisplayWidth

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
fn writeUserGroupColored(
    style: anytype,
    writer: anytype,
    user_name: []const u8,
    group_name: []const u8,
    omit_owner: bool,
    omit_group: bool,
) !void {
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
fn writeSizeColored(
    style: anytype,
    writer: anytype,
    size_str: []const u8,
    size: u64,
    human_readable: bool,
) !void {
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
fn writeDateColored(
    style: anytype,
    writer: anytype,
    time_str: []const u8,
    mtime_ns: i128,
    max_time_width: usize, // tiger:allow:usize-arch column width is usize
) !void {
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
pub fn formatTimeWithStyle(
    mtime_ns: i128,
    time_style: TimeStyle,
    allocator: std.mem.Allocator,
    buf: []u8,
) ![]const u8 {
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

/// Calendar and clock fields for one instant, resolved in the timezone the
/// process is running in, plus that zone's offset from UTC at that instant.
const LocalTime = struct {
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    gmtoff_s: i64,
};

const month_names_abbrev = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// Resolve epoch nanoseconds into local calendar fields through libc.
/// Zig's std.time.epoch carries no timezone database and can only yield UTC,
/// and the offset must be resolved per timestamp because a zone's offset
/// changes across DST transitions.
fn localTimeFromNanos(mtime_ns: i128) !LocalTime {
    const mtime_s = @divFloor(mtime_ns, std.time.ns_per_s);
    const seconds = std.math.cast(i64, mtime_s) orelse return error.InvalidTimestamp;
    const time_val: std.c.time_t = @intCast(seconds);
    var tm: common.time.c_tm = undefined;
    if (common.time.localtime_r(&time_val, &tm) == null) return error.InvalidTimestamp;

    // localtime_r fills a normalized struct tm, so months land in 0..=11 and
    // days in 1..=31; the casts and the month_names_abbrev index below rely
    // on that.
    std.debug.assert(tm.tm_mon >= 0);
    std.debug.assert(tm.tm_mon <= 11);
    std.debug.assert(tm.tm_mday >= 1);
    std.debug.assert(tm.tm_mday <= 31);

    return .{
        .year = @as(i32, tm.tm_year) + 1900,
        .month = @as(u32, @intCast(tm.tm_mon)) + 1,
        .day = @intCast(tm.tm_mday),
        .hour = @intCast(tm.tm_hour),
        .minute = @intCast(tm.tm_min),
        .second = @intCast(tm.tm_sec),
        .gmtoff_s = tm.tm_gmtoff,
    };
}

/// Traditional ls format: "Mar  1 14:30" or "Jan 15  2024".
fn formatTimeWithStyle_default(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    const local = try localTimeFromNanos(mtime_ns);
    std.debug.assert(local.month >= 1);
    std.debug.assert(local.month <= month_names_abbrev.len);
    const month_name = month_names_abbrev[local.month - 1];

    // The recency test compares two absolute instants, so it needs no
    // timezone correction; only the rendered fields do.
    const now_ns = common.file.currentTimestampNanoseconds();
    const age_ns = now_ns - mtime_ns;

    if (age_ns >= NS_PER_6MONTHS) {
        // Old file: "Jan 15  2024"
        return std.fmt.bufPrint(buf, "{s} {d: >2}  {d}", .{ month_name, local.day, local.year });
    } else {
        // Recent file: "Mar  1 14:30"
        return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}", .{
            month_name,
            local.day,
            local.hour,
            local.minute,
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
    const local = try localTimeFromNanos(mtime_ns);
    std.debug.assert(local.month >= 1);
    std.debug.assert(local.month <= 12);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        local.year,
        local.month,
        local.day,
        local.hour,
        local.minute,
    });
}

/// Long ISO format: 2024-01-15 15:30:45.123456789 -0800.
fn formatTimeWithStyle_longIso(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    const nano_remainder = @mod(mtime_ns, std.time.ns_per_s);
    // @mod with a positive divisor yields [0, ns_per_s), so the value passed
    // to the 9-digit fractional formatter always fits.
    std.debug.assert(@abs(nano_remainder) < std.time.ns_per_s);
    const local = try localTimeFromNanos(mtime_ns);
    std.debug.assert(local.month >= 1);

    // GNU prints the zone offset that applies at this instant, so it is read
    // back from the resolved fields rather than assumed to be UTC.
    const sign: u8 = if (local.gmtoff_s < 0) '-' else '+';
    const abs_off: u64 = @intCast(if (local.gmtoff_s < 0) -local.gmtoff_s else local.gmtoff_s);
    const tz_hours = @divTrunc(abs_off, 3600);
    const tz_mins = @divTrunc(@rem(abs_off, 3600), 60);

    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9} {c}{d:0>2}{d:0>2}",
        .{
            local.year,
            local.month,
            local.day,
            local.hour,
            local.minute,
            local.second,
            @abs(nano_remainder),
            sign,
            tz_hours,
            tz_mins,
        },
    );
}

/// Full time: "Mar  1 14:30:45 2024" (always shows seconds and year).
fn formatTimeWithStyle_full(mtime_ns: i128, buf: []u8) ![]const u8 {
    std.debug.assert(buf.len > 0);
    const local = try localTimeFromNanos(mtime_ns);
    std.debug.assert(local.month >= 1);
    std.debug.assert(local.month <= month_names_abbrev.len);
    const month_name = month_names_abbrev[local.month - 1];

    return std.fmt.bufPrint(buf, "{s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        month_name,
        local.day,
        local.hour,
        local.minute,
        local.second,
        local.year,
    });
}

/// Print a single entry in long format (public API, no time alignment)
pub fn printLongFormatEntry(
    allocator: std.mem.Allocator,
    entry: Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    return printLongFormatEntryAligned(allocator, entry, writer, options, style, 0);
}

/// Print a single entry in long format with time column alignment
fn printLongFormatEntryAligned(
    allocator: std.mem.Allocator,
    entry: Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
    max_time_width: usize, // tiger:allow:usize-arch column width is usize
) !void {
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
    // Formatting any u64 (including 0) yields at least one digit; guards the
    // later (num_str.len - 1) / 3 from underflow.
    std.debug.assert(num_str.len >= 1);

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
    // Postcondition: the loop only runs when total_len <= buf.len and writes
    // exactly total_len bytes, so out never overruns the output buffer.
    std.debug.assert(out <= buf.len);
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
    // Postcondition: blocks == 0 returned 1 above; otherwise the loop ran at
    // least once, so every return value is at least 1.
    std.debug.assert(width >= 1);
    return width;
}

/// Compute the -s block-count prefix width (max block-count width plus a
/// trailing space). Caller guards this behind options.show_blocks; otherwise
/// it passes 0 directly.
fn printColumnar_blockPrefixWidth(
    entries: []Entry,
    options: LsOptions,
) usize { // tiger:allow:usize-arch blockCountWidth returns usize
    // Called only with a non-empty slice from the columnar path; the
    // reduction below must visit at least one entry.
    std.debug.assert(entries.len > 0);
    var max_block_width: usize = 0; // tiger:allow:usize-arch matches std width/index pattern
    for (entries) |entry| {
        const block_width = blockCountWidth(calculateDisplayBlocks(entry, options));
        max_block_width = @max(max_block_width, block_width);
    }
    const block_prefix_width = max_block_width + 1; // block count + space
    // blockCountWidth never returns 0, so max_block_width >= 1 and the result
    // is at least 2: the count plus its trailing space.
    std.debug.assert(block_prefix_width >= 2);
    return block_prefix_width;
}

/// Find the widest entry display width across all entries in a single pass,
/// caching each entry's width as a side effect of getDisplayWidth.
fn printColumnar_maxEntryWidth(
    entries: []Entry,
    options: LsOptions,
) usize { // tiger:allow:usize-arch getDisplayWidth returns usize
    // The columnar path early-returns on empty input, so the maximum is taken
    // over at least one width.
    std.debug.assert(entries.len > 0);
    var max_width: usize = 0; // tiger:allow:usize-arch getDisplayWidth returns usize
    for (entries) |*entry| {
        const width = entry.getDisplayWidth(
            options.file_type_indicators,
            options.append_slash_dirs,
            common.icons.shouldShowIcons(options.icon_mode, options.is_terminal),
            options.show_git_status,
        );
        max_width = @max(max_width, width);
    }
    // At least one entry contributed, so the maximum is no smaller than that
    // entry's own width; it cannot exceed the prefix arithmetic that follows.
    std.debug.assert(max_width >= 0);
    return max_width;
}

/// Write the right-aligned -s block-count prefix for one entry. Caller invokes
/// this only inside the options.show_blocks branch.
fn printColumnar_writeBlockPrefix(
    entry: Entry,
    options: LsOptions,
    block_prefix_width: usize, // tiger:allow:usize-arch matches blockCountWidth/width pattern
    writer: anytype,
) !void {
    // Only reached under show_blocks, where the prefix width was computed by
    // printColumnar_blockPrefixWidth and is therefore at least 2.
    std.debug.assert(block_prefix_width > 0);
    const blocks = calculateDisplayBlocks(entry, options);
    // Right-align block count to max_block_width
    const bw = blockCountWidth(blocks);
    // blockCountWidth never yields 0, so the pad math below cannot underflow.
    std.debug.assert(bw >= 1);
    const pad_count = if (block_prefix_width > bw + 1) block_prefix_width - bw - 1 else 0;
    for (0..pad_count) |_| {
        try writer.writeByte(' ');
    }
    try writer.print("{d} ", .{blocks});
}

/// Pad the current column to max_width plus the column padding with spaces,
/// using the width cached during the pre-calculation pass. Only -x
/// (printColumnarAcross) uses this; -C pads with tabs instead. Caller guards
/// this so the entry is neither the last column nor the last entry.
fn printColumnar_writePadding(
    entries: []Entry,
    idx: usize, // tiger:allow:usize-arch slice index
    max_width: usize, // tiger:allow:usize-arch getDisplayWidth returns usize
    options: LsOptions,
    writer: anytype,
) !void {
    // Caller only reaches this for an in-bounds, non-final entry.
    std.debug.assert(idx < entries.len);
    // This uses cached width from the pre-calculation pass above
    const width = entries[idx].getDisplayWidth(
        options.file_type_indicators,
        options.append_slash_dirs,
        common.icons.shouldShowIcons(options.icon_mode, options.is_terminal),
        options.show_git_status,
    );
    // max_width is the maximum over all entry widths, so the padding count
    // below stays non-negative.
    std.debug.assert(width <= max_width);
    const padding = max_width + COLUMN_PADDING - width;
    for (0..padding) |_| {
        try writer.writeByte(' ');
    }
}

/// Advance the cursor from `chcnt` to the start of the next column by writing
/// literal tab characters, exactly like BSD ls printcol(): keep hopping to the
/// next 8-column tab stop while that stop still lands at or before `endcol`.
/// Returns the resulting cursor column.
fn printColumnar_writeTabs(
    chcnt: usize, // tiger:allow:usize-arch getDisplayWidth returns usize
    endcol: usize, // tiger:allow:usize-arch derived from column widths
    writer: anytype,
) !usize { // tiger:allow:usize-arch mirrors the cursor column type
    // endcol is a positive multiple of the column width and the cursor never
    // runs past the column it is currently filling.
    std.debug.assert(endcol >= TAB_WIDTH);
    std.debug.assert(chcnt < endcol);
    var cursor = chcnt;
    // Each iteration advances the cursor by a full tab stop, so this many
    // iterations always reaches endcol and the loop stays bounded.
    for (0..@divFloor(endcol, TAB_WIDTH) + 1) |_| {
        const next = (cursor + TAB_WIDTH) & ~(TAB_WIDTH - 1);
        if (next > endcol) break;
        try writer.writeByte('\t');
        cursor = next;
    }
    // Tabs only ever move the cursor forward, and never past the column end.
    std.debug.assert(cursor >= chcnt);
    std.debug.assert(cursor <= endcol);
    return cursor;
}

/// Column-major layout parameters shared by every row of a -C listing.
const ColumnarLayout = struct {
    num_cols: usize, // tiger:allow:usize-arch slice index arithmetic
    num_rows: usize, // tiger:allow:usize-arch slice index arithmetic
    col_width: usize, // tiger:allow:usize-arch getDisplayWidth returns usize
    block_prefix_width: usize, // tiger:allow:usize-arch matches blockCountWidth
};

/// Print one fill-down row of a -C listing. Padding is written only between
/// two printed cells, so a row whose remaining columns are empty (a partially
/// filled last row) never ends in whitespace.
fn printColumnar_writeRow(
    entries: []Entry,
    row: usize, // tiger:allow:usize-arch slice index
    layout: ColumnarLayout,
    options: LsOptions,
    writer: anytype,
    style: anytype,
) !void {
    // The caller derives the layout from a non-empty slice, so every row has
    // at least one cell and at least one column to place it in.
    std.debug.assert(entries.len > 0);
    std.debug.assert(row < layout.num_rows);
    var chcnt: usize = 0; // tiger:allow:usize-arch cursor column
    var endcol = layout.col_width;
    for (0..layout.num_cols) |col| {
        const idx = col * layout.num_rows + row;
        if (idx >= entries.len) break;
        if (options.show_blocks) {
            try printColumnar_writeBlockPrefix(
                entries[idx],
                options,
                layout.block_prefix_width,
                writer,
            );
            chcnt += layout.block_prefix_width;
        }
        try display.printEntryName(entries[idx], writer, style, options);
        chcnt += entries[idx].getDisplayWidth(
            options.file_type_indicators,
            options.append_slash_dirs,
            common.icons.shouldShowIcons(options.icon_mode, options.is_terminal),
            options.show_git_status,
        );
        // Stop before padding when no further cell follows on this row.
        if (col + 1 >= layout.num_cols) break;
        if ((col + 1) * layout.num_rows + row >= entries.len) break;
        chcnt = try printColumnar_writeTabs(chcnt, endcol, writer);
        endcol += layout.col_width;
    }
    try writer.writeByte('\n');
}

/// Print entries in columnar format
pub fn printColumnar(
    allocator: std.mem.Allocator,
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    if (entries.len == 0) return;
    // The only way past the early return is a non-empty slice; the column
    // math below indexes entries and depends on this.
    std.debug.assert(entries.len > 0);

    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth(allocator) catch 80;

    // Calculate block width prefix if -s is enabled
    const block_prefix_width = if (options.show_blocks)
        printColumnar_blockPrefixWidth(entries, options)
    else
        0;

    // Pre-calculate display widths for all entries in a single pass
    // This ensures all widths are cached and finds the maximum width
    const max_width = printColumnar_maxEntryWidth(entries, options);

    // BSD ls rounds the widest cell (name plus any -s/-i prefix) UP to the
    // next tab stop, so a width already sitting on a stop gains a whole one:
    // 8 becomes 16, not 8. That rounding replaces additive column padding.
    const col_width = (block_prefix_width + max_width + TAB_WIDTH) & ~(TAB_WIDTH - 1);
    // Rounding up always leaves room for the widest cell plus a separator.
    std.debug.assert(col_width > block_prefix_width + max_width);

    // Calculate number of columns that fit
    const num_cols = @max(1, term_width / col_width);
    // @max(1, ...) guarantees at least one column, so num_rows below cannot
    // divide by zero.
    std.debug.assert(num_cols >= 1);

    // Calculate number of rows needed
    const num_rows = (entries.len + num_cols - 1) / num_cols;
    // With entries.len >= 1 and num_cols >= 1 the ceiling division yields at
    // least one row, bounding the outer row loop.
    std.debug.assert(num_rows >= 1);

    const layout = ColumnarLayout{
        .num_cols = num_cols,
        .num_rows = num_rows,
        .col_width = col_width,
        .block_prefix_width = block_prefix_width,
    };

    // Print in column-major order (fill down the columns, like BSD ls)
    for (0..num_rows) |row| {
        try printColumnar_writeRow(entries, row, layout, options, writer, style);
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
pub fn printColumnarAcross(
    allocator: std.mem.Allocator,
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    if (entries.len == 0) return;
    // Past the early return the slice is non-empty; the entries.len - 1 logic
    // below depends on it.
    std.debug.assert(entries.len > 0);

    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth(allocator) catch 80;

    // Calculate block width prefix if -s is enabled
    const block_prefix_width = if (options.show_blocks)
        printColumnar_blockPrefixWidth(entries, options)
    else
        0;

    // Pre-calculate display widths for all entries in a single pass
    // This ensures all widths are cached and finds the maximum width
    const max_width = printColumnar_maxEntryWidth(entries, options);

    // Add padding between columns, including block prefix
    const col_width = block_prefix_width + max_width + COLUMN_PADDING;

    // Calculate number of columns that fit
    const num_cols = @max(1, term_width / col_width);
    // @max(1, ...) guarantees at least one column; the idx % num_cols below
    // would be a modulo-by-zero hazard otherwise.
    std.debug.assert(num_cols >= 1);

    // Print in row-major order (across rows, like -x)
    for (entries, 0..) |entry, idx| {
        // Print block count prefix if -s
        if (options.show_blocks) {
            try printColumnar_writeBlockPrefix(entry, options, block_prefix_width, writer);
        }

        try display.printEntryName(entry, writer, style, options);

        // Check if this is the last entry on the row or the last entry overall
        const col = idx % num_cols;
        if (col == num_cols - 1 or idx == entries.len - 1) {
            try writer.writeByte('\n');
        } else {
            // Pad to column width
            try printColumnar_writePadding(entries, idx, max_width, options, writer);
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

    // Totals are only accumulated for the two formats that display them.
    std.debug.assert(total_blocks == 0 or options.show_blocks or options.long_format);

    if (options.one_per_line) {
        // Explicit -1 also suppresses icons and git status.
        var explicit_opts = options;
        explicit_opts.icon_mode = .never;
        explicit_opts.show_git_status = false;
        try printEntries_onePerLine(entries, writer, explicit_opts, style);
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
    } else if (options.multi_column or options.is_terminal) {
        // Multi-column layout (sorted down columns): the default on a
        // terminal, and forced anywhere by an explicit -C.
        try printColumnar(allocator, entries, writer, options, style);
    } else {
        // POSIX: "If the standard output is not a terminal, the default
        // format shall be the same as the -1 option." Icons and git status
        // keep whatever the user configured, because this is an implicit
        // default rather than an explicit -1.
        var default_opts = options;
        default_opts.one_per_line = true;
        try printEntries_onePerLine(entries, writer, default_opts, style);
    }

    std.debug.assert(entries.len > 0 or total_blocks == 0);
    return total_blocks;
}

/// Print entries one per line, one entry per call to printEntryName. Callers
/// pass options already resolved for one-per-line output.
fn printEntries_onePerLine(
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    std.debug.assert(options.one_per_line);
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
        try display.printEntryName(entry, writer, style, options);
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
        const expected = std.fmt.bufPrint(
            &expected_buf,
            "\x1b[38;2;{d};{d};{d}m",
            .{ tier.r, tier.g, tier.b },
        ) catch unreachable;
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
        const expected = std.fmt.bufPrint(
            &expected_buf,
            "\x1b[38;2;{d};{d};{d}m",
            .{ tier.r, tier.g, tier.b },
        ) catch unreachable;
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
