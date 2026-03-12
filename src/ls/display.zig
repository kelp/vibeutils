const std = @import("std");
const common = @import("common");
const types = @import("types.zig");

const Entry = types.Entry;
const LsOptions = types.LsOptions;
const ColorMode = types.ColorMode;

/// Initialize style based on color mode configuration
pub fn initStyle(allocator: std.mem.Allocator, writer: anytype, color_mode: ColorMode) !common.style.Style(@TypeOf(writer)) {
    var style = try common.style.Style(@TypeOf(writer)).init(allocator, writer);
    if (color_mode == .never) {
        style.color_mode = .none;
    } else if (color_mode == .always) {
        // Keep the detected mode but ensure it's at least basic
        if (style.color_mode == .none) {
            style.color_mode = .basic;
        }
    }
    // For .auto, disable colors when stdout is not a TTY
    if (color_mode == .auto and !std.posix.isatty(std.fs.File.stdout().handle)) {
        style.color_mode = .none;
    }
    return style;
}

/// Check if entry is executable
pub fn isExecutable(entry: Entry) bool {
    if (entry.kind != .file) return false;
    if (entry.stat) |stat| {
        return (stat.mode & common.constants.EXECUTE_BIT) != 0;
    }
    return false;
}

/// Get color for a file kind (without needing an Entry)
pub fn getColorForKind(kind: std.fs.File.Kind) common.style.Style(std.fs.File.Writer).Color {
    const Color = common.style.Style(std.fs.File.Writer).Color;
    return switch (kind) {
        .directory => Color.bright_blue,
        .sym_link => Color.bright_cyan,
        .block_device => Color.bright_yellow,
        .character_device => Color.bright_yellow,
        .named_pipe => Color.yellow,
        .unix_domain_socket => Color.magenta,
        else => Color.default,
    };
}

/// Get appropriate color for file type
pub fn getFileColor(entry: Entry) common.style.Style(std.fs.File.Writer).Color {
    const Color = common.style.Style(std.fs.File.Writer).Color;
    return switch (entry.kind) {
        .directory => Color.bright_blue,
        .sym_link => Color.bright_cyan,
        .block_device => Color.bright_yellow,
        .character_device => Color.bright_yellow,
        .named_pipe => Color.yellow,
        .unix_domain_socket => Color.magenta,
        .file => blk: {
            // Check if executable
            if (isExecutable(entry)) {
                break :blk Color.bright_green;
            }
            break :blk Color.default;
        },
        else => Color.default,
    };
}

/// Multi-mode color info for git status indicators.
const GitStatusColorInfo = struct {
    r: u8,
    g: u8,
    b: u8,
    c256: u8,
    basic: common.style.Style(std.fs.File.Writer).Color,
};

/// Get color info for git status across all color modes.
/// Returns null for statuses that should not be colored (.clean, .not_in_repo).
fn getGitStatusColorInfo(git_status: common.git.GitStatus) ?GitStatusColorInfo {
    const Color = common.style.Style(std.fs.File.Writer).Color;
    return switch (git_status) {
        .untracked => .{ .r = 220, .g = 90, .b = 80, .c256 = 167, .basic = Color.red },
        .modified => .{ .r = 220, .g = 190, .b = 80, .c256 = 179, .basic = Color.yellow },
        .added => .{ .r = 115, .g = 195, .b = 120, .c256 = 114, .basic = Color.green },
        .deleted => .{ .r = 210, .g = 80, .b = 70, .c256 = 160, .basic = Color.red },
        .renamed => .{ .r = 110, .g = 190, .b = 200, .c256 = 116, .basic = Color.cyan },
        .copied => .{ .r = 110, .g = 190, .b = 200, .c256 = 116, .basic = Color.cyan },
        .updated => .{ .r = 180, .g = 140, .b = 200, .c256 = 176, .basic = Color.magenta },
        .ignored => .{ .r = 160, .g = 160, .b = 170, .c256 = 248, .basic = Color.white },
        .clean, .not_in_repo => null,
    };
}

/// Get file type indicator character
pub fn getFileTypeIndicator(entry: Entry) u8 {
    // Get file type indicator based on file kind and permissions
    switch (entry.kind) {
        .directory => return '/',
        .sym_link => return '@',
        .named_pipe => return '|',
        .unix_domain_socket => return '=',
        .file => {
            // Check if executable
            if (isExecutable(entry)) {
                return '*';
            }
            return 0; // No indicator for regular files
        },
        else => return 0,
    }
}

/// Print entry name with optional icon, color and file type indicator
pub fn printEntryName(entry: Entry, writer: anytype, style: anytype, show_indicator: bool, show_icons: bool, show_git_status: bool) !void {
    // Print Git status indicator if enabled
    if (show_git_status and entry.git_status != .not_in_repo) {
        const git_indicator = entry.git_status.getIndicator();
        if (getGitStatusColorInfo(entry.git_status)) |gc| {
            switch (style.color_mode) {
                .truecolor => try style.setRgb(gc.r, gc.g, gc.b),
                .extended => try style.set256(gc.c256),
                .basic => try style.setColor(gc.basic),
                .none => {},
            }
            try writer.print("{s} ", .{git_indicator});
            if (style.color_mode != .none) try style.reset();
        } else {
            try writer.print("{s} ", .{git_indicator});
        }
    }

    // Print icon if enabled
    if (show_icons) {
        const theme = common.icons.IconTheme{};
        const icon = common.icons.getIcon(&theme, entry.name, entry.kind == .directory, entry.kind == .sym_link, isExecutable(entry));
        const icon_color = common.icons.getIconColorInfo(icon);
        if (icon_color) |c| {
            switch (style.color_mode) {
                .truecolor => try style.setRgb(c.r, c.g, c.b),
                .extended => try style.set256(c.c256),
                .basic => try style.setColor(c.basic),
                .none => {},
            }
        }
        try writer.print("{s} ", .{icon});
        if (icon_color != null and style.color_mode != .none) try style.reset();
    }

    const color = getFileColor(entry);
    if (style.color_mode != .none) {
        try style.setColor(color);
    }

    try writer.print("{s}", .{entry.name});

    if (style.color_mode != .none) {
        try style.reset();
    }

    if (show_indicator) {
        const indicator = getFileTypeIndicator(entry);
        if (indicator != 0) {
            try writer.writeByte(indicator);
        }
    }
}

// Tests
const testing = std.testing;

test "display - getFileTypeIndicator" {
    // Test directory indicator
    const dir_entry = Entry{ .name = "testdir", .kind = .directory };
    try testing.expectEqual(@as(u8, '/'), getFileTypeIndicator(dir_entry));

    // Test symlink indicator
    const link_entry = Entry{ .name = "testlink", .kind = .sym_link };
    try testing.expectEqual(@as(u8, '@'), getFileTypeIndicator(link_entry));

    // Test regular file (no indicator)
    const file_entry = Entry{ .name = "testfile", .kind = .file };
    try testing.expectEqual(@as(u8, 0), getFileTypeIndicator(file_entry));

    // Test executable file
    const exe_entry = Entry{
        .name = "testexe",
        .kind = .file,
        .stat = common.file.FileInfo{
            .size = 100,
            .atime = 0,
            .mtime = 0,
            .mode = 0o755, // Executable permissions
            .kind = .file,
            .inode = 1,
            .nlink = 1,
            .uid = 1000,
            .gid = 1000,
        },
    };
    try testing.expectEqual(@as(u8, '*'), getFileTypeIndicator(exe_entry));
}

test "display - isExecutable" {
    // Test non-executable file
    const file_entry = Entry{
        .name = "testfile",
        .kind = .file,
        .stat = common.file.FileInfo{
            .size = 100,
            .atime = 0,
            .mtime = 0,
            .mode = 0o644, // Not executable
            .kind = .file,
            .inode = 1,
            .nlink = 1,
            .uid = 1000,
            .gid = 1000,
        },
    };
    try testing.expect(!isExecutable(file_entry));

    // Test executable file
    const exe_entry = Entry{
        .name = "testexe",
        .kind = .file,
        .stat = common.file.FileInfo{
            .size = 100,
            .atime = 0,
            .mtime = 0,
            .mode = 0o755, // Executable permissions
            .kind = .file,
            .inode = 1,
            .nlink = 1,
            .uid = 1000,
            .gid = 1000,
        },
    };
    try testing.expect(isExecutable(exe_entry));

    // Test directory (not considered executable for our purposes)
    const dir_entry = Entry{ .name = "testdir", .kind = .directory };
    try testing.expect(!isExecutable(dir_entry));
}
