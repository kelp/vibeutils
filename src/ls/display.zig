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
    // For .auto, use the detected mode (which checks isatty)
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

/// Get appropriate color for git status
pub fn getGitStatusColor(git_status: common.git.GitStatus) common.style.Style(std.fs.File.Writer).Color {
    const Color = common.style.Style(std.fs.File.Writer).Color;
    return switch (git_status) {
        .untracked => Color.red,
        .modified => Color.yellow,
        .added => Color.green,
        .deleted => Color.red,
        .renamed => Color.cyan,
        .copied => Color.cyan,
        .updated => Color.magenta,
        .ignored => Color.bright_black,
        .clean => Color.default,
        .not_in_repo => Color.default,
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

/// Calculate the display width of an entry (name + optional icon + optional indicator + git status)
pub fn getEntryDisplayWidth(entry: Entry, show_indicator: bool, show_icons: bool, show_git_status: bool) usize {
    var width = entry.name.len;
    if (show_git_status and entry.git_status != .not_in_repo) {
        // Git status indicator + space = 3 characters
        width += 3;
    }
    if (show_icons) {
        // Icon + space = 2 characters (assuming single-width display)
        width += 2;
    }
    if (show_indicator) {
        const indicator = getFileTypeIndicator(entry);
        if (indicator != 0) width += 1;
    }
    return width;
}

/// Print entry name with optional icon, color and file type indicator
pub fn printEntryName(entry: Entry, writer: anytype, style: anytype, show_indicator: bool, show_icons: bool, show_git_status: bool) !void {
    // Print Git status indicator if enabled
    if (show_git_status and entry.git_status != .not_in_repo) {
        const git_indicator = entry.git_status.getIndicator();
        if (style.color_mode != .none and entry.git_status != .clean) {
            const git_color = getGitStatusColor(entry.git_status);
            try style.setColor(git_color);
            try writer.print("{s} ", .{git_indicator});
            try style.reset();
        } else {
            try writer.print("{s} ", .{git_indicator});
        }
    }

    // Print icon if enabled
    if (show_icons) {
        const theme = common.icons.IconTheme{};
        const icon = common.icons.getIcon(&theme, entry.name, entry.kind == .directory, entry.kind == .sym_link, isExecutable(entry));
        try writer.print("{s} ", .{icon});
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

test "display - getEntryDisplayWidth" {
    const entry = Entry{ .name = "test.txt", .kind = .file };

    // Just filename
    try testing.expectEqual(@as(usize, 8), getEntryDisplayWidth(entry, false, false, false));

    // With indicator
    try testing.expectEqual(@as(usize, 8), getEntryDisplayWidth(entry, true, false, false)); // No indicator for regular file

    // With icon
    try testing.expectEqual(@as(usize, 10), getEntryDisplayWidth(entry, false, true, false));

    // With git status
    var git_entry = entry;
    git_entry.git_status = .modified;
    try testing.expectEqual(@as(usize, 11), getEntryDisplayWidth(git_entry, false, false, true));

    // All options
    try testing.expectEqual(@as(usize, 13), getEntryDisplayWidth(git_entry, true, true, true));
}
