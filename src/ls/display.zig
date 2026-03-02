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

const IconColorInfo = struct {
    r: u8,
    g: u8,
    b: u8,
    c256: u8,
    basic: common.style.Style(std.fs.File.Writer).Color,
};

fn getIconColorInfo(icon: []const u8) ?IconColorInfo {
    const theme = common.icons.IconTheme{};
    const Color = common.style.Style(std.fs.File.Writer).Color;
    const eql = std.mem.eql;

    // Programming languages — researched brand colors
    if (eql(u8, icon, theme.zig)) return .{ .r = 247, .g = 164, .b = 29, .c256 = 214, .basic = Color.yellow };
    if (eql(u8, icon, theme.rust)) return .{ .r = 211, .g = 69, .b = 22, .c256 = 166, .basic = Color.red };
    if (eql(u8, icon, theme.go)) return .{ .r = 0, .g = 173, .b = 216, .c256 = 38, .basic = Color.cyan };
    if (eql(u8, icon, theme.python)) return .{ .r = 69, .g = 132, .b = 182, .c256 = 68, .basic = Color.blue };
    if (eql(u8, icon, theme.javascript)) return .{ .r = 247, .g = 223, .b = 30, .c256 = 220, .basic = Color.yellow };
    if (eql(u8, icon, theme.typescript)) return .{ .r = 49, .g = 120, .b = 198, .c256 = 68, .basic = Color.blue };
    if (eql(u8, icon, theme.ruby)) return .{ .r = 204, .g = 52, .b = 45, .c256 = 160, .basic = Color.red };
    if (eql(u8, icon, theme.java)) return .{ .r = 237, .g = 139, .b = 0, .c256 = 208, .basic = Color.yellow };
    if (eql(u8, icon, theme.perl)) return .{ .r = 2, .g = 152, .b = 195, .c256 = 31, .basic = Color.cyan };
    if (eql(u8, icon, theme.c)) return .{ .r = 168, .g = 185, .b = 204, .c256 = 152, .basic = Color.blue };
    if (eql(u8, icon, theme.cpp)) return .{ .r = 0, .g = 89, .b = 156, .c256 = 25, .basic = Color.blue };

    // DevOps & tools
    if (eql(u8, icon, theme.git) or eql(u8, icon, theme.gitignore)) return .{ .r = 243, .g = 79, .b = 41, .c256 = 202, .basic = Color.red };
    if (eql(u8, icon, theme.dockerfile)) return .{ .r = 13, .g = 183, .b = 237, .c256 = 39, .basic = Color.cyan };
    if (eql(u8, icon, theme.nix)) return .{ .r = 126, .g = 182, .b = 225, .c256 = 110, .basic = Color.cyan };
    if (eql(u8, icon, theme.shell)) return .{ .r = 78, .g = 170, .b = 37, .c256 = 70, .basic = Color.green };
    if (eql(u8, icon, theme.makefile)) return .{ .r = 109, .g = 128, .b = 134, .c256 = 66, .basic = Color.white };

    // Documents & markup
    if (eql(u8, icon, theme.markdown) or eql(u8, icon, theme.readme)) return .{ .r = 8, .g = 63, .b = 161, .c256 = 25, .basic = Color.blue };
    if (eql(u8, icon, theme.web)) return .{ .r = 228, .g = 77, .b = 38, .c256 = 166, .basic = Color.red };
    if (eql(u8, icon, theme.css)) return .{ .r = 21, .g = 114, .b = 182, .c256 = 32, .basic = Color.blue };

    // Data formats
    if (eql(u8, icon, theme.json) or eql(u8, icon, theme.yaml)) return .{ .r = 203, .g = 203, .b = 65, .c256 = 185, .basic = Color.yellow };
    if (eql(u8, icon, theme.toml) or eql(u8, icon, theme.config)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };

    // Media & documents
    if (eql(u8, icon, theme.pdf)) return .{ .r = 236, .g = 28, .b = 36, .c256 = 196, .basic = Color.red };
    if (eql(u8, icon, theme.archive)) return .{ .r = 212, .g = 170, .b = 0, .c256 = 178, .basic = Color.yellow };
    if (eql(u8, icon, theme.image)) return .{ .r = 160, .g = 116, .b = 196, .c256 = 134, .basic = Color.magenta };
    if (eql(u8, icon, theme.audio)) return .{ .r = 0, .g = 180, .b = 216, .c256 = 38, .basic = Color.cyan };
    if (eql(u8, icon, theme.video)) return .{ .r = 177, .g = 54, .b = 30, .c256 = 124, .basic = Color.red };

    // Special files
    if (eql(u8, icon, theme.license)) return .{ .r = 212, .g = 170, .b = 0, .c256 = 178, .basic = Color.yellow };
    if (eql(u8, icon, theme.lock)) return .{ .r = 136, .g = 136, .b = 136, .c256 = 245, .basic = Color.white };
    if (eql(u8, icon, theme.database)) return .{ .r = 0, .g = 117, .b = 143, .c256 = 30, .basic = Color.cyan };

    // File system entries
    if (eql(u8, icon, theme.directory)) return .{ .r = 110, .g = 160, .b = 220, .c256 = 110, .basic = Color.bright_blue };
    if (eql(u8, icon, theme.symlink)) return .{ .r = 110, .g = 185, .b = 185, .c256 = 115, .basic = Color.bright_cyan };
    if (eql(u8, icon, theme.executable)) return .{ .r = 115, .g = 185, .b = 120, .c256 = 114, .basic = Color.green };

    // Default (file/unknown)
    if (eql(u8, icon, theme.text) or eql(u8, icon, theme.file) or eql(u8, icon, theme.unknown)) return .{ .r = 150, .g = 150, .b = 150, .c256 = 249, .basic = Color.white };

    return null;
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
        const icon_color = getIconColorInfo(icon);
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

test "display - getIconColorInfo brand colors" {
    const theme = common.icons.IconTheme{};
    const Color = common.style.Style(std.fs.File.Writer).Color;

    // Zig icon returns yellow/orange brand color
    const zig_color = getIconColorInfo(theme.zig).?;
    try testing.expectEqual(Color.yellow, zig_color.basic);
    try testing.expectEqual(@as(u8, 247), zig_color.r);

    // Executable and makefile have distinct glyphs and colors
    const exec_color = getIconColorInfo(theme.executable).?;
    try testing.expectEqual(Color.green, exec_color.basic);
    const make_color = getIconColorInfo(theme.makefile).?;
    try testing.expectEqual(Color.white, make_color.basic);
    try testing.expect(!std.mem.eql(u8, theme.executable, theme.makefile));

    // Unknown string returns null
    try testing.expectEqual(@as(?IconColorInfo, null), getIconColorInfo("not-an-icon"));
}
