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

/// Format timestamp according to the specified time style
pub fn formatTimeWithStyle(mtime_ns: i128, time_style: TimeStyle, allocator: std.mem.Allocator, buf: []u8) ![]const u8 {
    switch (time_style) {
        .relative => {
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
        },
        .iso => {
            // ISO format: 2024-01-15 15:30
            const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = std.math.cast(u64, mtime_s) orelse return error.InvalidTimestamp };
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
        },
        .@"long-iso" => {
            // Long ISO format: 2024-01-15 15:30:45.123456789 +0000
            const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
            const nano_remainder = @mod(mtime_ns, std.time.ns_per_s);
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = std.math.cast(u64, mtime_s) orelse return error.InvalidTimestamp };
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
        },
    }
}

/// Print a single entry in long format
pub fn printLongFormatEntry(allocator: std.mem.Allocator, entry: Entry, writer: anytype, options: LsOptions, style: anytype) !void {
    // Permission string
    var perm_buf: [10]u8 = undefined;
    const perms = if (entry.stat) |stat|
        try common.file.formatPermissions(stat.mode, stat.kind, &perm_buf)
    else
        "----------";

    try writer.writeAll(perms);

    // Number of links
    if (entry.stat) |stat| {
        try writer.print(" {d: >3} ", .{stat.nlink});
    } else {
        try writer.writeAll("   ? ");
    }

    // User and group names/IDs
    if (entry.stat) |stat| {
        if (options.numeric_ids) {
            // Show numeric IDs
            try writer.print("{d: <8} {d: <8} ", .{ stat.uid, stat.gid });
        } else {
            // Show names (default behavior)
            var user_buf: [32]u8 = undefined;
            var group_buf: [32]u8 = undefined;
            const user_name = try common.file.getUserName(stat.uid, &user_buf);
            const group_name = try common.file.getGroupName(stat.gid, &group_buf);
            try writer.print("{s: <8} {s: <8} ", .{ user_name, group_name });
        }
    } else {
        try writer.writeAll("?        ?        ");
    }

    // Size
    if (entry.stat) |stat| {
        var size_buf: [32]u8 = undefined;
        const size_str = if (options.human_readable)
            try common.file.formatSizeHuman(stat.size, &size_buf)
        else if (options.kilobytes)
            try common.file.formatSizeKilobytes(stat.size, &size_buf)
        else
            try common.file.formatSize(stat.size, &size_buf);

        // Right-align size in 8 characters for regular, 5 for human
        if (options.human_readable) {
            try writer.print("{s: >5} ", .{size_str});
        } else {
            try writer.print("{s: >8} ", .{size_str});
        }
    } else {
        try writer.writeAll("       ? ");
    }

    // Date/time
    if (entry.stat) |stat| {
        var time_buf: [128]u8 = undefined; // Larger buffer for long-iso format
        const time_str = try formatTimeWithStyle(stat.mtime, options.time_style, allocator, &time_buf);
        try writer.print("{s} ", .{time_str});
    } else {
        try writer.writeAll("??? ?? ??:?? ");
    }

    // Name with color and optional indicator
    try display.printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);

    // Show symlink target if available
    if (entry.symlink_target) |target| {
        try writer.print(" -> {s}", .{target});
    }
    try writer.writeByte('\n');
}

/// Print entries in columnar format
pub fn printColumnar(entries: []Entry, writer: anytype, options: LsOptions, style: anytype) !void {
    if (entries.len == 0) return;

    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth() catch 80;

    // Pre-calculate display widths for all entries in a single pass
    // This ensures all widths are cached and finds the maximum width
    var max_width: usize = 0;
    for (entries) |*entry| {
        const width = entry.getDisplayWidth(options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);
        max_width = @max(max_width, width);
    }

    // Add padding between columns
    const col_width = max_width + COLUMN_PADDING;

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

            // Print entry name with color and indicator
            try display.printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);

            // Pad to column width (except for last column)
            if (col < num_cols - 1 and idx < entries.len - 1) {
                // This uses cached width from the pre-calculation pass above
                const width = entries[idx].getDisplayWidth(options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);
                const padding = col_width - width;
                for (0..padding) |_| {
                    try writer.writeByte(' ');
                }
            }
        }
        try writer.writeByte('\n');
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

    if (options.one_per_line) {
        for (entries) |entry| {
            // Print inode number if requested
            if (options.show_inodes) {
                if (entry.stat) |stat| {
                    try writer.print("{d} ", .{stat.inode});
                } else {
                    try writer.print("? ", .{});
                }
            }
            try display.printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);
            try writer.writeByte('\n');
        }
    } else if (options.long_format) {
        // Calculate total blocks
        for (entries) |entry| {
            if (entry.stat) |stat| {
                total_blocks += (stat.size + BLOCK_ROUNDING) / BLOCK_SIZE;
            }
        }

        // Print total if we have entries
        if (entries.len > 0) {
            try writer.print("total {d}\n", .{total_blocks});
        }

        // Print each entry in long format
        for (entries) |entry| {
            try printLongFormatEntry(allocator, entry, writer, options, style);
        }
    } else if (options.comma_format) {
        // Comma-separated format
        for (entries, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try display.printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);
        }
        if (entries.len > 0) try writer.writeByte('\n');
    } else {
        // Default format: multi-column layout
        try printColumnar(entries, writer, options, style);
    }

    return total_blocks;
}

// Tests
const testing = std.testing;

test "formatter - formatTimeWithStyle relative" {
    const allocator = testing.allocator;
    var buf: [128]u8 = undefined;

    // Test recent time (should show relative format)
    const now_ns = std.time.nanoTimestamp();
    const one_hour_ago = now_ns - (3600 * std.time.ns_per_s);

    const result = try formatTimeWithStyle(one_hour_ago, .relative, allocator, &buf);

    // Should contain "ago" for past times
    try testing.expect(std.mem.indexOf(u8, result, "ago") != null);
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
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var entries = [_]Entry{
        .{ .name = "file1", .kind = .file },
        .{ .name = "file2", .kind = .file },
        .{ .name = "file3", .kind = .file },
    };

    const options = LsOptions{ .terminal_width = 40 };
    const style = try display.initStyle(testing.allocator, buffer.writer(), .never);

    try printColumnar(&entries, buffer.writer(), options, style);

    const output = buffer.items;

    // Should contain all files
    try testing.expect(std.mem.indexOf(u8, output, "file1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file3") != null);
}
