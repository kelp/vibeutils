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

/// Sanitize a filename by replacing non-printable characters with '?'.
/// Non-printable means characters with values < 0x20 or == 0x7F (DEL).
fn sanitizeName(name: []const u8, buf: []u8) []const u8 {
    if (name.len > buf.len) return name;
    var needs_sanitize = false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7F) {
            needs_sanitize = true;
            break;
        }
    }
    if (!needs_sanitize) return name;
    for (name, 0..) |c, i| {
        buf[i] = if (c < 0x20 or c == 0x7F) '?' else c;
    }
    return buf[0..name.len];
}

/// Escape non-printable characters using C-style escape sequences.
/// Produces sequences like \n, \t, \0, \a, \b, \f, \r, \v, or \ooo for others.
fn escapeName(name: []const u8, buf: []u8) []const u8 {
    var needs_escape = false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7F or c == '\\') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return name;

    var out: usize = 0;
    for (name) |c| {
        if (out + 4 > buf.len) break; // ensure room for worst case \ooo
        if (c == '\\') {
            buf[out] = '\\';
            buf[out + 1] = '\\';
            out += 2;
        } else if (c < 0x20 or c == 0x7F) {
            buf[out] = '\\';
            out += 1;
            switch (c) {
                0x00 => {
                    buf[out] = '0';
                    out += 1;
                },
                0x07 => {
                    buf[out] = 'a';
                    out += 1;
                },
                0x08 => {
                    buf[out] = 'b';
                    out += 1;
                },
                0x09 => {
                    buf[out] = 't';
                    out += 1;
                },
                0x0A => {
                    buf[out] = 'n';
                    out += 1;
                },
                0x0B => {
                    buf[out] = 'v';
                    out += 1;
                },
                0x0C => {
                    buf[out] = 'f';
                    out += 1;
                },
                0x0D => {
                    buf[out] = 'r';
                    out += 1;
                },
                else => {
                    // Octal escape \ooo
                    buf[out] = '0' + (c >> 6);
                    buf[out + 1] = '0' + ((c >> 3) & 0o7);
                    buf[out + 2] = '0' + (c & 0o7);
                    out += 3;
                },
            }
        } else {
            buf[out] = c;
            out += 1;
        }
    }
    return buf[0..out];
}

/// Print entry name with optional icon, color and file type indicator
pub fn printEntryName(entry: Entry, writer: anytype, style: anytype, options: LsOptions) !void {
    const show_icons = common.icons.shouldShowIcons(options.icon_mode, options.is_terminal);
    const show_git_status = options.show_git_status;

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

    // Apply -b: C-style escape sequences for non-printable characters
    // Apply -q: replace non-printable characters with '?'
    if (options.escape_non_printable) {
        var name_buf: [std.fs.max_path_bytes * 4]u8 = undefined;
        const display_name = escapeName(entry.name, &name_buf);
        try writer.print("{s}", .{display_name});
    } else if (options.non_printable_as_question) {
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const display_name = sanitizeName(entry.name, &name_buf);
        try writer.print("{s}", .{display_name});
    } else {
        try writer.print("{s}", .{entry.name});
    }

    if (style.color_mode != .none) {
        try style.reset();
    }

    // -F: full file type indicators (/ * @ | =)
    if (options.file_type_indicators) {
        const indicator = getFileTypeIndicator(entry);
        if (indicator != 0) {
            try writer.writeByte(indicator);
        }
    } else if (options.append_slash_dirs) {
        // -p: only append / for directories
        if (entry.kind == .directory) {
            try writer.writeByte('/');
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

test "display - escapeName basic" {
    var buf: [256]u8 = undefined;

    // Normal string passes through unchanged
    const normal = escapeName("hello.txt", &buf);
    try testing.expectEqualStrings("hello.txt", normal);

    // Newline -> \n
    const with_nl = escapeName("hello\nworld", &buf);
    try testing.expectEqualStrings("hello\\nworld", with_nl);

    // Tab -> \t
    const with_tab = escapeName("hello\tworld", &buf);
    try testing.expectEqualStrings("hello\\tworld", with_tab);

    // Null -> \0
    const with_null = escapeName("hello\x00world", &buf);
    try testing.expectEqualStrings("hello\\0world", with_null);

    // Backslash -> \\
    const with_bs = escapeName("hello\\world", &buf);
    try testing.expectEqualStrings("hello\\\\world", with_bs);
}

test "display - escapeName special chars" {
    var buf: [256]u8 = undefined;

    // Bell -> \a
    const with_bell = escapeName("hello\x07world", &buf);
    try testing.expectEqualStrings("hello\\aworld", with_bell);

    // Carriage return -> \r
    const with_cr = escapeName("hello\rworld", &buf);
    try testing.expectEqualStrings("hello\\rworld", with_cr);

    // Form feed -> \f
    const with_ff = escapeName("hello\x0Cworld", &buf);
    try testing.expectEqualStrings("hello\\fworld", with_ff);

    // Vertical tab -> \v
    const with_vt = escapeName("hello\x0Bworld", &buf);
    try testing.expectEqualStrings("hello\\vworld", with_vt);
}

test "display - sanitizeName" {
    var buf: [256]u8 = undefined;

    // Normal string passes through unchanged
    const normal = sanitizeName("hello.txt", &buf);
    try testing.expectEqualStrings("hello.txt", normal);

    // Non-printable -> ?
    const with_ctrl = sanitizeName("hello\x01world", &buf);
    try testing.expectEqualStrings("hello?world", with_ctrl);

    // DEL -> ?
    const with_del = sanitizeName("hello\x7Fworld", &buf);
    try testing.expectEqualStrings("hello?world", with_del);
}
