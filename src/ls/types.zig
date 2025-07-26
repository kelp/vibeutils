const std = @import("std");
const common = @import("common");

/// Color mode configuration for output
pub const ColorMode = enum {
    always,
    auto,
    never,
};

/// Time formatting style for -l output
pub const TimeStyle = enum {
    relative, // Smart relative dates like "2 hours ago"
    iso, // ISO format: 2024-01-15 15:30
    @"long-iso", // Long ISO: 2024-01-15 15:30:45.123456789 +0000
};

/// Configuration options for ls command
pub const LsOptions = struct {
    all: bool = false,
    almost_all: bool = false,
    long_format: bool = false,
    human_readable: bool = false,
    kilobytes: bool = false,
    one_per_line: bool = false,
    directory: bool = false,
    recursive: bool = false,
    sort_by_time: bool = false,
    sort_by_size: bool = false,
    reverse_sort: bool = false,
    file_type_indicators: bool = false,
    color_mode: ColorMode = .auto,
    terminal_width: ?u16 = null, // null means auto-detect
    group_directories_first: bool = false,
    show_inodes: bool = false,
    numeric_ids: bool = false,
    comma_format: bool = false,
    icon_mode: common.icons.IconMode = .auto,
    time_style: TimeStyle = .relative,
    show_git_status: bool = false,
};

/// Represents a directory entry with metadata
pub const Entry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    stat: ?common.file.FileInfo = null,
    symlink_target: ?[]const u8 = null,
    git_status: common.git.GitStatus = .not_in_repo,
};

/// Configuration for sorting directory entries
pub const SortConfig = struct {
    by_time: bool = false,
    by_size: bool = false,
    dirs_first: bool = false,
    reverse: bool = false,
};

/// Parse color mode from string argument
pub fn parseColorMode(arg: []const u8) !ColorMode {
    return std.meta.stringToEnum(ColorMode, arg) orelse error.InvalidColorMode;
}

/// Parse time style from string argument
pub fn parseTimeStyle(arg: []const u8) !TimeStyle {
    return std.meta.stringToEnum(TimeStyle, arg) orelse error.InvalidTimeStyle;
}
