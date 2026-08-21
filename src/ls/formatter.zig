const std = @import("std");
const common = @import("common");
const types = @import("types.zig");
const display = @import("display.zig");

const Entry = types.Entry;
const LsOptions = types.LsOptions;
const TimeStyle = types.TimeStyle;

/// Terminal tab stop interval. Both -C and -x round their column width up to
/// a multiple of this and pad with literal tabs, matching BSD ls.
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

/// Write `text` in a `width`-column field followed by the single space that
/// separates long-format columns. Callers invoke this from inside a color
/// region, exactly as writeDateColored pads inside its own: emitting the pad
/// outside the region would either count escape bytes as columns or strand
/// the filler in the neighbouring field's color.
fn writePaddedField(
    writer: anytype,
    text: []const u8,
    width: usize, // tiger:allow:usize-arch column width is usize
    right_align: bool,
) !void {
    // Every column renders at least "?" and the caller sized the field to the
    // widest text in the section, so the pad below cannot underflow.
    std.debug.assert(text.len > 0);
    std.debug.assert(width >= text.len);
    const pad = width - text.len;
    if (right_align) {
        for (0..pad) |_| try writer.writeByte(' ');
        try writer.writeAll(text);
    } else {
        try writer.writeAll(text);
        for (0..pad) |_| try writer.writeByte(' ');
    }
    try writer.writeByte(' ');
}

/// Write link count dimmed with bright_black, right-aligned in the field the
/// caller sized across the whole section.
fn writeNlinkColored(
    style: anytype,
    writer: anytype,
    nlink_str: []const u8,
    width: usize, // tiger:allow:usize-arch column width is usize
) !void {
    std.debug.assert(nlink_str.len > 0);
    std.debug.assert(width >= nlink_str.len);
    if (style.color_mode != .none) {
        if (style.color_mode == .truecolor) {
            try style.setRgb(100, 100, 115);
        } else {
            try style.setColor(.bright_black);
        }
    }
    // The permission string ends flush against this field, so the leading
    // space is this column's separator rather than the previous one's.
    try writer.writeByte(' ');
    // Link counts are numbers, and GNU right-aligns numeric columns.
    try writePaddedField(writer, nlink_str, width, true);
    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write a single owner/group column with color. GNU left-aligns a resolved
/// name and right-aligns a bare numeric id, so the direction travels with the
/// individual value rather than being fixed here or read off a flag.
fn writeOwnerColored(
    style: anytype,
    writer: anytype,
    name: []const u8,
    width: usize, // tiger:allow:usize-arch column width is usize
    right_align: bool,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(width >= name.len);
    if (style.color_mode != .none) {
        if (style.color_mode == .truecolor) {
            try style.setRgb(190, 165, 120);
        } else {
            try style.setColor(.yellow);
        }
    }
    try writePaddedField(writer, name, width, right_align);
    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write a single group column with color, aligned like the owner column.
fn writeGroupColored(
    style: anytype,
    writer: anytype,
    name: []const u8,
    width: usize, // tiger:allow:usize-arch column width is usize
    right_align: bool,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(width >= name.len);
    if (style.color_mode != .none) {
        if (style.color_mode == .truecolor) {
            try style.setRgb(150, 145, 185);
        } else {
            try style.setColor(.cyan);
        }
    }
    try writePaddedField(writer, name, width, right_align);
    if (style.color_mode != .none) {
        try style.reset();
    }
}

/// Write size with tiered color based on file size.
/// Truecolor: smooth RGB gradient from green (small) to red-orange (large).
/// 256-color: approximate palette indices.
/// 16-color: green (normal), bold green (human-readable).
/// The width is measured on the rendered string, so -h, -k and --thousands
/// each size this column to what they actually print.
fn writeSizeColored(
    style: anytype,
    writer: anytype,
    size_str: []const u8,
    size: u64,
    human_readable: bool,
    width: usize, // tiger:allow:usize-arch column width is usize
) !void {
    std.debug.assert(size_str.len > 0);
    std.debug.assert(width >= size_str.len);
    if (style.color_mode != .none) {
        if (human_readable and style.color_mode == .basic) try style.setBold();
        try common.colors.applySizeColor(style, size);
    }

    try writePaddedField(writer, size_str, width, true);

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

/// Width of every long-format column, sized to the widest value present in
/// one section the way GNU ls sizes them. A section is a single
/// printEntries_longFormat call, so these never carry across directories.
const LongFormatWidths = struct {
    block_prefix: usize, // tiger:allow:usize-arch matches blockCountWidth
    nlink: usize, // tiger:allow:usize-arch column width is usize
    owner: usize, // tiger:allow:usize-arch column width is usize
    group: usize, // tiger:allow:usize-arch column width is usize
    size: usize, // tiger:allow:usize-arch column width is usize
    time: usize, // tiger:allow:usize-arch slice .len is usize
    /// Whether any entry of this section carries an ACL. GNU sizes the mode
    /// field to eleven columns for the WHOLE section as soon as one does --
    /// `+` for that entry and a pad space for every other -- and leaves it at
    /// ten when none does, which makes it a section width like the rest
    /// rather than a per-entry decision. Defaults to the ten-column field so
    /// that a caller sizing only the columns it cares about gets the layout
    /// every ACL-free listing has; printLongFormatEntryAligned asserts that a
    /// marked entry is never rendered against a width that left it false.
    mode_marker: bool = false,
};

/// The link count exactly as it will be printed, or "?" when the entry could
/// not be stat'ed. The measure pass and the render pass both go through this
/// helper so a column can never be sized from a different string than the one
/// written into it.
fn nlinkString(entry: Entry, buf: []u8) []const u8 {
    // A u32 link count needs at most ten digits.
    std.debug.assert(buf.len >= 10);
    const stat = entry.stat orelse return "?";
    const rendered = std.fmt.bufPrint(buf, "{d}", .{stat.nlink}) catch "?";
    std.debug.assert(rendered.len > 0);
    return rendered;
}

/// Owner and group as one entry renders them, sharing the caller's buffers.
/// Each value also carries whether it is a bare numeric id rather than a
/// resolved name, because that -- not the -n flag -- is what decides its
/// alignment, and one column can hold both kinds at once.
const OwnerGroupStrings = struct {
    owner: []const u8,
    group: []const u8,
    owner_numeric: bool,
    group_numeric: bool,
};

/// Owner and group exactly as they will be printed, or "?" when the entry
/// could not be stat'ed. The name lookup falls back to the numeric id when
/// the id has no account, so both the rendered width and whether the value is
/// a name at all are only knowable by calling it.
fn ownerGroupStrings(
    entry: Entry,
    options: LsOptions,
    owner_buf: []u8,
    group_buf: []u8,
) !OwnerGroupStrings {
    std.debug.assert(owner_buf.len >= 16);
    std.debug.assert(group_buf.len >= 16);
    // An entry with no stat has no id to look up, so its "?" placeholder
    // follows the mode the listing asked for instead of a lookup result.
    const stat = entry.stat orelse return .{
        .owner = "?",
        .group = "?",
        .owner_numeric = options.numeric_ids,
        .group_numeric = options.numeric_ids,
    };
    if (options.numeric_ids) {
        return .{
            .owner = std.fmt.bufPrint(owner_buf, "{d}", .{stat.uid}) catch "?",
            .group = std.fmt.bufPrint(group_buf, "{d}", .{stat.gid}) catch "?",
            .owner_numeric = true,
            .group_numeric = true,
        };
    }
    // lookupUserName copies the name out of libc's static buffer before
    // lookupGroupName can reuse it, so the two calls cannot alias.
    const owner = try common.file.lookupUserName(stat.uid, owner_buf);
    const group = try common.file.lookupGroupName(stat.gid, group_buf);
    return .{
        .owner = owner.name,
        .group = group.name,
        .owner_numeric = !owner.resolved,
        .group_numeric = !group.resolved,
    };
}

/// The size exactly as it will be printed under the active size flags, or "?"
/// when the entry could not be stat'ed. Measuring the raw number instead
/// would size the column wrong for -h, -k and --thousands, all of which
/// render something other than the plain byte count.
fn sizeString(entry: Entry, options: LsOptions, buf: []u8) ![]const u8 {
    // Twenty digits hold any u64; the grouped form adds at most six commas.
    std.debug.assert(buf.len >= 26);
    const stat = entry.stat orelse return "?";
    const rendered = if (options.human_readable)
        try common.file.formatSizeHuman(stat.size, buf)
    else if (options.kilobytes)
        try common.file.formatSizeKilobytes(stat.size, buf)
    else if (options.thousands_grouping)
        formatWithThousands(stat.size, buf)
    else
        try common.file.formatSize(stat.size, buf);
    std.debug.assert(rendered.len > 0);
    return rendered;
}

/// Print a single entry in long format, every column padded to the section
/// widths the caller measured.
fn printLongFormatEntryAligned(
    allocator: std.mem.Allocator,
    entry: Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
    widths: LongFormatWidths,
) !void {
    std.debug.assert(options.long_format);
    std.debug.assert(widths.nlink >= 1);
    // These widths must be the ones measured over the section this entry
    // belongs to: a marked entry printed against another section's widths
    // would have nowhere to put its marker.
    std.debug.assert(!entry.has_acl or widths.mode_marker);
    // Per-entry block count if -s is active, right-aligned in the field the
    // caller sized across the whole section.
    if (options.show_blocks) {
        try writeBlockPrefix(entry, options, widths.block_prefix, writer);
    }

    // Permission string
    var perm_buf: [10]u8 = undefined;
    const perms = if (entry.stat) |stat|
        try common.file.formatPermissions(stat.mode, stat.kind, &perm_buf)
    else
        "----------";

    try writeColoredPermissions(style, writer, perms);

    // The eleventh mode column, present for every entry of a section that
    // holds a marked one. It is written as a plain byte outside the color
    // region because GNU never colors the mode field, marker included, and
    // the separator space that follows belongs to the link count below.
    if (widths.mode_marker) {
        try writer.writeByte(if (entry.has_acl) '+' else ' ');
    }

    // Number of links
    var nlink_buf: [16]u8 = undefined;
    try writeNlinkColored(style, writer, nlinkString(entry, &nlink_buf), widths.nlink);

    // User and group names/IDs
    try printLongFormatEntryAligned_ownerGroup(style, writer, entry, options, widths);

    // Size
    try printLongFormatEntryAligned_size(style, writer, entry, options, widths.size);

    // Date/time (padded to the section's time width for alignment)
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
        try writeDateColored(style, writer, time_str, time_field, widths.time);
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
    try printLongFormatAclDump(allocator, entry, writer, options);
}

/// After a long-format line, dump the POSIX ACL when `-e` is set.
fn printLongFormatAclDump(
    allocator: std.mem.Allocator,
    entry: Entry,
    writer: anytype,
    options: LsOptions,
) !void {
    std.debug.assert(options.long_format);
    if (!options.show_acls) return;
    if (!entry.has_acl) return;
    if (entry.acl_dump) |dump| {
        std.debug.assert(dump.len > 0);
        try writer.writeAll(dump);
        return;
    }
    const dump = common.file.allocAclDump(allocator, entry.name, true) orelse return;
    defer allocator.free(dump);
    std.debug.assert(dump.len > 0);
    try writer.writeAll(dump);
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

/// Write the user/group columns of a long-format entry, each padded to its
/// own section width. The "?" an unstattable entry renders goes through the
/// same padding as a real name so it lands in the same columns.
///
/// GNU's format_user_or_group picks each value's alignment from what it
/// printed rather than from -n: a resolved name left-aligns and a bare
/// numeric id right-aligns, so a column holding one of each -- an owner
/// whose account exists beside one whose does not -- justifies them in
/// opposite directions. Under -n every value is numeric, which is why the
/// flag looks like the rule until an id fails to resolve without it.
fn printLongFormatEntryAligned_ownerGroup(
    style: anytype,
    writer: anytype,
    entry: Entry,
    options: LsOptions,
    widths: LongFormatWidths,
) !void {
    std.debug.assert(widths.owner >= 1);
    std.debug.assert(widths.group >= 1);
    var owner_buf: [32]u8 = undefined;
    var group_buf: [32]u8 = undefined;
    const names = try ownerGroupStrings(entry, options, &owner_buf, &group_buf);
    std.debug.assert(names.owner.len > 0);
    std.debug.assert(names.group.len > 0);
    if (!options.omit_owner) {
        try writeOwnerColored(style, writer, names.owner, widths.owner, names.owner_numeric);
    }
    if (!options.omit_group) {
        try writeGroupColored(style, writer, names.group, widths.group, names.group_numeric);
    }
}

/// Write the size column of a long-format entry, right-aligned in the section
/// width. Falls back to a padded "?" when stat is unavailable.
fn printLongFormatEntryAligned_size(
    style: anytype,
    writer: anytype,
    entry: Entry,
    options: LsOptions,
    width: usize, // tiger:allow:usize-arch column width is usize
) !void {
    std.debug.assert(options.long_format);
    std.debug.assert(width >= 1);
    var size_buf: [32]u8 = undefined;
    const size_str = try sizeString(entry, options, &size_buf);
    // An entry with no stat has no byte count to pick a color tier from, so
    // the "?" takes the smallest-file color.
    const size: u64 = if (entry.stat) |stat| stat.size else 0;
    try writeSizeColored(style, writer, size_str, size, options.human_readable, width);
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
/// it passes 0 directly. Every output format sizes this field the same way,
/// so the columnar, one-per-line and long-format paths all come through here.
fn blockPrefixWidth(
    entries: []Entry,
    options: LsOptions,
) usize { // tiger:allow:usize-arch blockCountWidth returns usize
    // Called only with a non-empty slice; the reduction below must visit at
    // least one entry.
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

/// Widest cell for a -C column, sized the way BSD ls sizes it: the raw
/// maximum entry width with the -F/-p type indicator excluded, plus a flat
/// `+1` once whenever either flag is active.
///
///     colwidth = dp->maxlen;
///     if (f_type || f_typedir) colwidth += 1;
///
/// Taking the maximum over per-entry widths that already fold the indicator
/// in only widens the column when the LONGEST entry happens to carry one, so
/// a listing whose widest name is a plain file lays out one tab stop narrower
/// than /bin/ls (issue #121). Excluding the indicator here does not
/// under-size the column: every entry gains at most one column from it, which
/// is exactly the term added back.
fn printColumnar_bsdColumnWidth(
    entries: []Entry,
    options: LsOptions,
) usize { // tiger:allow:usize-arch getDisplayWidth returns usize
    // Called only from the columnar path, which early-returns on empty input.
    std.debug.assert(entries.len > 0);
    const show_icons = common.icons.shouldShowIcons(options.icon_mode, options.is_terminal);
    const indicators = options.file_type_indicators or options.append_slash_dirs;

    var max_width: usize = 0; // tiger:allow:usize-arch getDisplayWidth returns usize
    for (entries) |*entry| {
        // Deliberately not getDisplayWidth: the cache holds the real width,
        // indicator included, and every other caller needs that one.
        const width = entry.calculateDisplayWidth(
            false,
            false,
            show_icons,
            options.show_git_status,
        );
        max_width = @max(max_width, width);
    }

    const col_width = max_width + @intFromBool(indicators);
    // Without an indicator flag this is the plain maximum; with one it is
    // wider by exactly the flat term, never by more.
    std.debug.assert(col_width >= max_width);
    std.debug.assert(col_width <= max_width + 1);
    return col_width;
}

/// Write the right-aligned -s block-count prefix for one entry. Caller invokes
/// this only inside the options.show_blocks branch.
fn writeBlockPrefix(
    entry: Entry,
    options: LsOptions,
    block_prefix_width: usize, // tiger:allow:usize-arch matches blockCountWidth/width pattern
    writer: anytype,
) !void {
    // Only reached under show_blocks, where the prefix width was computed by
    // blockPrefixWidth and is therefore at least 2.
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

/// Which way a multi-column listing is filled. BSD gives -C and -x the very
/// same column geometry and differs only in this traversal order, so the two
/// share every width computation below.
const TraversalOrder = enum { down, across };

/// Layout parameters shared by every row of a multi-column listing.
const ColumnarLayout = struct {
    num_cols: usize, // tiger:allow:usize-arch slice index arithmetic
    num_rows: usize, // tiger:allow:usize-arch slice index arithmetic
    col_width: usize, // tiger:allow:usize-arch getDisplayWidth returns usize
    block_prefix_width: usize, // tiger:allow:usize-arch matches blockCountWidth
    order: TraversalOrder,
};

/// Size the BSD column grid for one section. The -s prefix enters the width
/// before the tab-stop rounding, because BSD rounds the whole cell.
fn printColumnar_layout(
    entries: []Entry,
    options: LsOptions,
    term_width: usize, // tiger:allow:usize-arch terminal width is usize
    order: TraversalOrder,
) ColumnarLayout {
    // Both callers early-return on empty input, and every width below is a
    // reduction that needs at least one entry. A zero term_width is legal --
    // `-w 0` reaches here -- and collapses to the single column @max enforces.
    std.debug.assert(entries.len > 0);
    std.debug.assert(entries.len <= std.math.maxInt(u32));

    const block_prefix_width = if (options.show_blocks)
        blockPrefixWidth(entries, options)
    else
        0;

    const max_width = printColumnar_bsdColumnWidth(entries, options);

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

    return .{
        .num_cols = num_cols,
        .num_rows = num_rows,
        .col_width = col_width,
        .block_prefix_width = block_prefix_width,
        .order = order,
    };
}

/// Map a grid cell to its entry index under the layout's traversal order.
/// The result may sit past the end of the slice, which the caller reads as an
/// empty cell; that is how a partially filled last row is detected.
fn printColumnar_cellIndex(
    layout: ColumnarLayout,
    row: usize, // tiger:allow:usize-arch slice index
    col: usize, // tiger:allow:usize-arch slice index
) usize { // tiger:allow:usize-arch slice index
    std.debug.assert(row < layout.num_rows);
    std.debug.assert(col < layout.num_cols);
    return switch (layout.order) {
        .down => col * layout.num_rows + row,
        .across => row * layout.num_cols + col,
    };
}

/// Print one row of a multi-column listing. Padding is written only between
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
        const idx = printColumnar_cellIndex(layout, row, col);
        if (idx >= entries.len) break;
        if (options.show_blocks) {
            try writeBlockPrefix(
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
        if (printColumnar_cellIndex(layout, row, col + 1) >= entries.len) break;
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

    // Print in column-major order (fill down the columns, like BSD ls)
    const layout = printColumnar_layout(entries, options, term_width, .down);
    std.debug.assert(layout.order == .down);
    for (0..layout.num_rows) |row| {
        try printColumnar_writeRow(entries, row, layout, options, writer, style);
    }
}

/// Blocks allocated to a file, in 512-byte units by default and in 1 KiB
/// units under -k. BSD and GNU both report st_blocks -- the space the file
/// occupies -- rather than a count derived from its size, which disagrees
/// whenever the size is not a whole allocation unit and disagrees wildly
/// for sparse files.
fn calculateDisplayBlocks(entry: Entry, options: LsOptions) u64 {
    if (entry.stat) |stat| {
        // -k rounds the 512-byte count up to whole kilobytes, matching
        // BSD's howmany(st_blocks, 2).
        if (options.kilobytes) {
            return @divFloor(stat.blocks + 1, 2);
        }
        return stat.blocks;
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
    // Past the early return the slice is non-empty; the layout math below
    // indexes entries and depends on it.
    std.debug.assert(entries.len > 0);

    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth(allocator) catch 80;

    // BSD gives -x the identical grid to -C, tabs and all, and only fills it
    // across rows instead of down columns.
    const layout = printColumnar_layout(entries, options, term_width, .across);
    std.debug.assert(layout.order == .across);
    for (0..layout.num_rows) |row| {
        try printColumnar_writeRow(entries, row, layout, options, writer, style);
    }
}

/// Whether this directory section reserves the 3-column git-status prefix.
/// The decision is made per section rather than per entry so a directory
/// where every tracked file is clean renders exactly like --git=never, while
/// a section holding at least one real status keeps the column on every
/// entry (clean ones included) and stays aligned.
fn sectionReservesGitColumn(entries: []const Entry, options: LsOptions) bool {
    std.debug.assert(entries.len <= std.math.maxInt(u32));
    // --git=never wins outright, whatever the entries' statuses are.
    if (!options.show_git_status) return false;

    for (entries) |entry| {
        const status = entry.git_status;
        // .clean and .not_in_repo both render as blank, so neither alone
        // justifies spending a column on the whole section.
        if (status != .clean and status != .not_in_repo) {
            // Every reserving status renders a 2-char indicator, which is
            // what the 3 columns of prefix width are sized for.
            std.debug.assert(status.getIndicator().len == 2);
            return true;
        }
    }
    return false;
}

/// Print a directory section: the "total" line where the format calls for
/// one, then the entries in the format the options select.
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

    try printSection(allocator, entries, writer, options, style, total_blocks, true);
    std.debug.assert(entries.len > 0 or total_blocks == 0);
    return total_blocks;
}

/// Print the group of non-directory operands as a single section, so it makes
/// the same layout and git-column decisions a directory section makes. The
/// "total" line is the one difference: it heads a directory listing only, and
/// neither BSD nor GNU emits it for operands (issue #119).
pub fn printOperandSection(
    allocator: std.mem.Allocator,
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    // Every caller partitions operands before reaching here, so an empty
    // group is never printed as a section.
    std.debug.assert(entries.len > 0);
    std.debug.assert(entries.len <= std.math.maxInt(u32));
    try printSection(allocator, entries, writer, options, style, 0, false);
}

/// Format one section's entries, after any "total" line the caller owns.
/// `print_total` reaches printEntries_longFormat, which prints its total
/// inline rather than ahead of the entries.
fn printSection(
    allocator: std.mem.Allocator,
    entries: []Entry,
    writer: anytype,
    options: LsOptions,
    style: anytype,
    total_blocks: u64,
    print_total: bool,
) !void {
    // A suppressed total has nothing to report, so the count must be unset.
    std.debug.assert(print_total or total_blocks == 0);

    // The git-status column is reserved per section, so every downstream
    // width and print call sees the section's own decision.
    var section_opts = options;
    section_opts.show_git_status = sectionReservesGitColumn(entries, options);

    if (options.one_per_line) {
        // Explicit -1 also suppresses icons and git status.
        var explicit_opts = section_opts;
        explicit_opts.icon_mode = .never;
        explicit_opts.show_git_status = false;
        try printEntries_onePerLine(entries, writer, explicit_opts, style);
    } else if (options.long_format) {
        try printEntries_longFormat(
            allocator,
            entries,
            writer,
            section_opts,
            style,
            total_blocks,
            print_total,
        );
    } else if (options.comma_format) {
        // Comma-separated format
        for (entries, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try display.printEntryName(entry, writer, style, section_opts);
        }
        if (entries.len > 0) try writer.writeByte('\n');
    } else if (options.columns_across) {
        // -x: multi-column sorted across rows
        try printColumnarAcross(allocator, entries, writer, section_opts, style);
    } else if (options.multi_column or options.is_terminal) {
        // Multi-column layout (sorted down columns): the default on a
        // terminal, and forced anywhere by an explicit -C.
        try printColumnar(allocator, entries, writer, section_opts, style);
    } else {
        // POSIX: "If the standard output is not a terminal, the default
        // format shall be the same as the -1 option." Icons and git status
        // keep whatever the user configured, because this is an implicit
        // default rather than an explicit -1.
        var default_opts = section_opts;
        default_opts.one_per_line = true;
        try printEntries_onePerLine(entries, writer, default_opts, style);
    }

    // The section decision is derived from this call's own entries and never
    // outlives it, so the caller's options are unchanged.
    std.debug.assert(section_opts.show_git_status == false or options.show_git_status);
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
    // BSD sizes the -s field to the widest count in the section rather than
    // to a fixed number of columns, so it is a section-wide property here
    // exactly as it is in the columnar path. blockPrefixWidth requires a
    // non-empty slice, which -s output implies but an empty listing does not.
    const block_prefix_width = if (options.show_blocks and entries.len > 0)
        blockPrefixWidth(entries, options)
    else
        0;
    for (entries) |entry| {
        // Print block count if -s
        if (options.show_blocks) {
            try writeBlockPrefix(entry, options, block_prefix_width, writer);
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
    print_total: bool,
) !void {
    std.debug.assert(options.long_format);
    std.debug.assert(print_total or total_blocks == 0);
    // A directory section is headed by its total; an operand group is not.
    if (print_total and entries.len > 0) {
        try writer.print("total {d}\n", .{total_blocks});
    }

    // Nothing else to print, and every column width below is a reduction that
    // needs at least one entry to reduce over.
    if (entries.len == 0) return;

    const widths = try measureLongFormatWidths(allocator, entries, options);

    // Print each entry in long format
    for (entries) |entry| {
        try printLongFormatEntryAligned(allocator, entry, writer, options, style, widths);
    }
}

/// Size every long-format column across one section in a single traversal.
/// blockPrefixWidth is deliberately not called here: it would walk the same
/// entries a second time, so the -s width is folded in below instead.
fn measureLongFormatWidths(
    allocator: std.mem.Allocator,
    entries: []Entry,
    options: LsOptions,
) !LongFormatWidths {
    std.debug.assert(entries.len > 0);
    std.debug.assert(options.long_format);

    var widths: LongFormatWidths = .{
        .block_prefix = 0,
        .nlink = 0,
        .owner = 0,
        .group = 0,
        .size = 0,
        .time = 0,
        .mode_marker = false,
    };
    var block_width_max: usize = 0; // tiger:allow:usize-arch matches blockCountWidth
    for (entries) |entry| {
        if (options.show_blocks) {
            const blocks = calculateDisplayBlocks(entry, options);
            block_width_max = @max(block_width_max, blockCountWidth(blocks));
        }
        try measureLongFormatWidths_entry(allocator, entry, options, &widths);
    }
    // blockCountWidth never returns 0, so the prefix is the count plus its
    // trailing space, matching what blockPrefixWidth yields elsewhere.
    if (options.show_blocks) widths.block_prefix = block_width_max + 1;

    // Every one of these columns renders at least "?" for an unstattable
    // entry, so none of them can come out of the fold empty. The time column
    // can: its fallback is a fixed literal that no width applies to.
    std.debug.assert(widths.nlink >= 1);
    std.debug.assert(widths.size >= 1);
    std.debug.assert(widths.owner >= 1);
    std.debug.assert(widths.group >= 1);
    // Without -s the field is absent, and with it the count carries a space.
    if (options.show_blocks) std.debug.assert(widths.block_prefix >= 2);
    if (!options.show_blocks) std.debug.assert(widths.block_prefix == 0);
    return widths;
}

/// Fold one entry's rendered columns into the running section maxima. Every
/// value is measured through the very helper that will later print it, so a
/// column can never be sized from a different string than it renders.
fn measureLongFormatWidths_entry(
    allocator: std.mem.Allocator,
    entry: Entry,
    options: LsOptions,
    widths: *LongFormatWidths,
) !void {
    std.debug.assert(options.long_format);
    std.debug.assert(entry.name.len > 0);
    // An entry that was never stat'ed was never probed either, so it cannot
    // be the reason a section widens.
    std.debug.assert(!entry.has_acl or entry.stat != null);

    // One marked entry is enough to give the whole section its eleventh mode
    // column, so this folds as an or rather than a max.
    widths.mode_marker = widths.mode_marker or entry.has_acl;

    var nlink_buf: [16]u8 = undefined;
    widths.nlink = @max(widths.nlink, nlinkString(entry, &nlink_buf).len);

    var owner_buf: [32]u8 = undefined;
    var group_buf: [32]u8 = undefined;
    const names = try ownerGroupStrings(entry, options, &owner_buf, &group_buf);
    widths.owner = @max(widths.owner, names.owner.len);
    widths.group = @max(widths.group, names.group.len);

    var size_buf: [32]u8 = undefined;
    const size_str = try sizeString(entry, options, &size_buf);
    widths.size = @max(widths.size, size_str.len);

    // An entry whose timestamp cannot be formatted contributes no time width
    // rather than aborting the listing; this is the last fold in the body, so
    // returning early skips nothing else.
    const stat = entry.stat orelse return;
    var time_buf: [128]u8 = undefined;
    const time_field = if (options.use_ctime)
        stat.ctime
    else if (options.use_atime)
        stat.atime
    else
        stat.mtime;
    const eff_ts = if (options.full_time) TimeStyle.full else options.time_style;
    const ts = formatTimeWithStyle(time_field, eff_ts, allocator, &time_buf) catch return;
    widths.time = @max(widths.time, ts.len);
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

    // A section whose only nlink is 3 sizes the column to width 1, so the
    // field is the separating space, the value, and the trailing space.
    try writeNlinkColored(style, &buf_aw.writer, "3", 1);
    try testing.expectEqualSlices(u8, " 3 ", buf_aw.writer.buffered());
}

test "writeNlinkColored - basic mode uses bright_black" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeNlinkColored(style, &buf_aw.writer, "1", 1);
    const output = buf_aw.writer.buffered();

    // Should contain bright_black (90) escape code
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[90m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1") != null);
    // Should end with reset
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
}

/// Issue #124 test helper: a stat'able entry whose only interesting fields
/// are the ids the owner/group columns render. Owner and group alignment is
/// a per-value property now, so these tests go through
/// printLongFormatEntryAligned_ownerGroup -- the function the render path
/// actually calls, and the one that reads -o/-g -- rather than a combined
/// writer that no product code drives.
fn ownerGroupTestEntry(uid: u32, gid: u32) Entry {
    return .{
        .name = "f",
        .kind = .file,
        .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = 0,
            .mtime = 0,
            .kind = .file,
            .inode = 1,
            .uid = uid,
            .gid = gid,
            .nlink = 1,
        },
    };
}

/// Issue #124 test helper: the name gid 0 resolves to, which is "root" on
/// Linux and "wheel" on macOS. Only uid 0's name ("root") is portable, so
/// the group expectations below resolve their name at test time instead of
/// hardcoding either spelling. Fails loudly if the lookup does not resolve,
/// because an unresolved id would right-align and change the expected bytes.
fn ownerGroupTestGroupName(gid: u32, buf: []u8) ![]const u8 {
    const lookup = try common.file.lookupGroupName(gid, buf);
    try testing.expect(lookup.resolved);
    try testing.expect(lookup.name.len > 0);
    return lookup.name;
}

/// Issue #124 test helper: column widths for an owner/group render. Only
/// the owner and group fields are read by the function under test; the rest
/// carry the smallest legal values so a change to them cannot affect it.
fn ownerGroupTestWidths(
    owner: usize, // tiger:allow:usize-arch column width is usize
    group: usize, // tiger:allow:usize-arch column width is usize
) LongFormatWidths {
    std.debug.assert(owner >= 1);
    std.debug.assert(group >= 1);
    return .{
        .block_prefix = 0,
        .nlink = 1,
        .owner = owner,
        .group = group,
        .size = 1,
        .time = 12,
    };
}

/// Issue #124 test helper: render just the owner/group columns of one entry
/// through the driver the long-format render path uses, returning the bytes
/// it wrote. Lets a single test assert several width/flag combinations.
fn renderOwnerGroup(
    color_mode: TestStyle.ColorMode,
    entry: Entry,
    options: LsOptions,
    widths: LongFormatWidths,
    out: *std.Io.Writer.Allocating,
) ![]const u8 {
    std.debug.assert(widths.owner >= 1);
    std.debug.assert(widths.group >= 1);
    const style = makeTestStyle(&out.writer, color_mode);
    try printLongFormatEntryAligned_ownerGroup(style, &out.writer, entry, options, widths);
    return out.writer.buffered();
}

test "printLongFormatEntryAligned_ownerGroup - no color writes plain" {
    var tight: std.Io.Writer.Allocating = .init(testing.allocator);
    defer tight.deinit();
    var padded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer padded.deinit();

    var group_buf: [32]u8 = undefined;
    const group = try ownerGroupTestGroupName(0, &group_buf);
    const entry = ownerGroupTestEntry(0, 0);
    const options = LsOptions{ .long_format = true };

    // Each column is sized to its own content, so "root" occupies 4 columns
    // and the group name its own, with exactly one space separating them.
    const tight_widths = ownerGroupTestWidths(4, group.len);
    const tight_want = try std.fmt.allocPrint(testing.allocator, "root {s} ", .{group});
    defer testing.allocator.free(tight_want);
    try testing.expectEqualSlices(
        u8,
        tight_want,
        try renderOwnerGroup(.none, entry, options, tight_widths, &tight),
    );

    // A resolved name left-aligns, so a section wider than this entry's
    // values pads on the right of each column, never on the left.
    const padded_widths = ownerGroupTestWidths(6, group.len + 2);
    const padded_want = try std.fmt.allocPrint(testing.allocator, "root   {s}   ", .{group});
    defer testing.allocator.free(padded_want);
    try testing.expectEqualSlices(
        u8,
        padded_want,
        try renderOwnerGroup(.none, entry, options, padded_widths, &padded),
    );
}

test "printLongFormatEntryAligned_ownerGroup - basic mode uses yellow user, cyan group" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();

    var group_buf: [32]u8 = undefined;
    const group = try ownerGroupTestGroupName(0, &group_buf);
    const options = LsOptions{ .long_format = true };
    const output = try renderOwnerGroup(
        .basic,
        ownerGroupTestEntry(0, 0),
        options,
        ownerGroupTestWidths(4, group.len),
        &buf_aw,
    );

    // Should contain yellow (33) for user and cyan (36) for group
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[33m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "root") != null);
    try testing.expect(std.mem.indexOf(u8, output, group) != null);
    // The user column is written first, so its color opens before the
    // group's -- a swap of the two writers would reverse this order.
    const yellow_at = std.mem.indexOf(u8, output, "\x1b[33m").?;
    const cyan_at = std.mem.indexOf(u8, output, "\x1b[36m").?;
    try testing.expect(yellow_at < cyan_at);
}

test "printLongFormatEntryAligned_ownerGroup - omit_owner hides user column" {
    var tight: std.Io.Writer.Allocating = .init(testing.allocator);
    defer tight.deinit();
    var padded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer padded.deinit();

    var group_buf: [32]u8 = undefined;
    const group = try ownerGroupTestGroupName(0, &group_buf);
    const entry = ownerGroupTestEntry(0, 0);
    const options = LsOptions{ .long_format = true, .omit_owner = true };

    // -g drops the owner field entirely; the surviving group column keeps
    // its own content width, with no owner padding left ahead of it.
    const tight_want = try std.fmt.allocPrint(testing.allocator, "{s} ", .{group});
    defer testing.allocator.free(tight_want);
    try testing.expectEqualSlices(
        u8,
        tight_want,
        try renderOwnerGroup(.none, entry, options, ownerGroupTestWidths(4, group.len), &tight),
    );

    // The survivor still pads to the section width, on the right.
    const padded_widths = ownerGroupTestWidths(4, group.len + 2);
    const padded_want = try std.fmt.allocPrint(testing.allocator, "{s}   ", .{group});
    defer testing.allocator.free(padded_want);
    try testing.expectEqualSlices(
        u8,
        padded_want,
        try renderOwnerGroup(.none, entry, options, padded_widths, &padded),
    );
}

test "printLongFormatEntryAligned_ownerGroup - omit_group hides group column" {
    var tight: std.Io.Writer.Allocating = .init(testing.allocator);
    defer tight.deinit();
    var padded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer padded.deinit();

    const entry = ownerGroupTestEntry(0, 0);
    const options = LsOptions{ .long_format = true, .omit_group = true };

    // -o drops the group field entirely; the surviving owner column keeps
    // its own content width of 4, then the single separator space.
    try testing.expectEqualSlices(
        u8,
        "root ",
        try renderOwnerGroup(.none, entry, options, ownerGroupTestWidths(4, 5), &tight),
    );

    // The survivor still pads to the section width, on the right.
    try testing.expectEqualSlices(
        u8,
        "root   ",
        try renderOwnerGroup(.none, entry, options, ownerGroupTestWidths(6, 5), &padded),
    );
}

test "writeSizeColored - no color writes plain" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    // A section whose only size renders as "4096" is 4 columns wide, so no
    // filler padding precedes the value.
    try writeSizeColored(style, &buf_aw.writer, "4096", 4096, false, 4);
    try testing.expectEqualSlices(u8, "4096 ", buf_aw.writer.buffered());
}

test "writeSizeColored - human readable format" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .none);

    // The width comes from the rendered human string, which is 4 columns
    // wide here — not from the fixed 5 the old hardcoded layout reserved.
    try writeSizeColored(style, &buf_aw.writer, "4.0K", 4096, true, 4);
    try testing.expectEqualSlices(u8, "4.0K ", buf_aw.writer.buffered());
}

test "writeSizeColored - truecolor small file uses green" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .truecolor);

    try writeSizeColored(style, &buf_aw.writer, "512", 512, false, 3);
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
    try writeSizeColored(style, &buf_aw.writer, "20971520", large_size, false, 8);
    const output = buf_aw.writer.buffered();

    // Large file: RGB (210, 115, 100)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;210;115;100m") != null);
}

test "writeSizeColored - 256 color mode" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .extended);

    // 50KB file should use index 149 (yellow-green)
    try writeSizeColored(style, &buf_aw.writer, "51200", 51200, false, 5);
    const output = buf_aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;5;149m") != null);
}

test "writeSizeColored - basic mode uses green" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeSizeColored(style, &buf_aw.writer, "100", 100, false, 3);
    const output = buf_aw.writer.buffered();

    // Basic mode: green (32)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[32m") != null);
}

test "writeSizeColored - basic mode bold for human readable" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();
    const style = makeTestStyle(&buf_aw.writer, .basic);

    try writeSizeColored(style, &buf_aw.writer, "4.0K", 4096, true, 4);
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
        try writeSizeColored(style, &buf_aw.writer, size_str, tier.size, false, size_str.len);

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
