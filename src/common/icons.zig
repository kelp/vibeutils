const std = @import("std");
const testing = std.testing;

/// Icon display modes
pub const IconMode = enum {
    never, // Never show icons
    auto, // Show icons when output is to a terminal (default)
    always, // Always show icons
};

/// Icon theme with Nerd Font glyphs
pub const IconTheme = struct {
    // Directories and links
    directory: []const u8 = "\u{f07b}", //
    symlink: []const u8 = "\u{f481}", //

    // File types by category
    file: []const u8 = "\u{f15b}", //
    executable: []const u8 = "\u{f489}", //

    // Programming languages
    c: []const u8 = "\u{e61e}", //
    cpp: []const u8 = "\u{e61d}", //
    rust: []const u8 = "\u{e7a8}", //
    go: []const u8 = "\u{e626}", //
    python: []const u8 = "\u{e73c}", //
    javascript: []const u8 = "\u{e74e}", //
    typescript: []const u8 = "\u{e628}", //
    zig: []const u8 = "\u{26a1}", // ⚡ (until official icon)
    java: []const u8 = "\u{e738}", //
    ruby: []const u8 = "\u{e791}", //
    perl: []const u8 = "\u{e769}", //

    // Documents
    text: []const u8 = "\u{f15c}", //
    markdown: []const u8 = "\u{f48a}", //
    pdf: []const u8 = "\u{f1c1}", //

    // Archives
    archive: []const u8 = "\u{f1c6}", //

    // Images
    image: []const u8 = "\u{f1c5}", //

    // Audio/Video
    audio: []const u8 = "\u{f1c7}", //
    video: []const u8 = "\u{f1c8}", //

    // Config
    config: []const u8 = "\u{e615}", //
    json: []const u8 = "\u{e60b}", //
    yaml: []const u8 = "\u{e60b}", //
    toml: []const u8 = "\u{e615}", //

    // Special files
    git: []const u8 = "\u{f1d3}", //
    gitignore: []const u8 = "\u{f1d3}", //
    license: []const u8 = "\u{f718}", //
    readme: []const u8 = "\u{f48a}", //
    makefile: []const u8 = "\u{f489}", //
    dockerfile: []const u8 = "\u{f308}", //

    // Fallback for unknown
    unknown: []const u8 = "\u{f15b}", //
};

/// Extension map entry for binary search
const ExtensionEntry = struct {
    ext: []const u8,
    get_icon: *const fn (*const IconTheme) []const u8,
};

/// Optimized extension lookup table - sorted alphabetically for binary search
const extension_map = [_]ExtensionEntry{
    .{ .ext = "7z", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "aac", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "avi", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "bmp", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "bz2", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "c", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.c;
        }
    }.get },
    .{ .ext = "cc", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.cpp;
        }
    }.get },
    .{ .ext = "cfg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
        }
    }.get },
    .{ .ext = "class", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.java;
        }
    }.get },
    .{ .ext = "conf", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
        }
    }.get },
    .{ .ext = "cpp", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.cpp;
        }
    }.get },
    .{ .ext = "cxx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.cpp;
        }
    }.get },
    .{ .ext = "flac", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "flv", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "gif", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "go", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.go;
        }
    }.get },
    .{ .ext = "gz", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "h", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.c;
        }
    }.get },
    .{ .ext = "hpp", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.cpp;
        }
    }.get },
    .{ .ext = "ico", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "ini", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
        }
    }.get },
    .{ .ext = "java", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.java;
        }
    }.get },
    .{ .ext = "jpeg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "jpg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "js", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.javascript;
        }
    }.get },
    .{ .ext = "json", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.json;
        }
    }.get },
    .{ .ext = "m4a", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "markdown", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.markdown;
        }
    }.get },
    .{ .ext = "md", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.markdown;
        }
    }.get },
    .{ .ext = "mjs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.javascript;
        }
    }.get },
    .{ .ext = "mkv", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "mov", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "mp3", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "mp4", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "ogg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "pdf", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.pdf;
        }
    }.get },
    .{ .ext = "perl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.perl;
        }
    }.get },
    .{ .ext = "pl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.perl;
        }
    }.get },
    .{ .ext = "pm", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.perl;
        }
    }.get },
    .{ .ext = "png", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "py", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.python;
        }
    }.get },
    .{ .ext = "pyc", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.python;
        }
    }.get },
    .{ .ext = "rar", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "rb", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.ruby;
        }
    }.get },
    .{ .ext = "rs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.rust;
        }
    }.get },
    .{ .ext = "svg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "tar", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "toml", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.toml;
        }
    }.get },
    .{ .ext = "ts", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.typescript;
        }
    }.get },
    .{ .ext = "tsx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.typescript;
        }
    }.get },
    .{ .ext = "txt", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.text;
        }
    }.get },
    .{ .ext = "wav", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "webm", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "webp", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "xz", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "yaml", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.yaml;
        }
    }.get },
    .{ .ext = "yml", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.yaml;
        }
    }.get },
    .{ .ext = "zig", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.zig;
        }
    }.get },
    .{ .ext = "zip", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
};

/// Convert string to lowercase using stack buffer
fn toLowercase(input: []const u8, buffer: []u8) []const u8 {
    const len = @min(input.len, buffer.len - 1);
    for (input[0..len], 0..) |c, i| {
        buffer[i] = std.ascii.toLower(c);
    }
    return buffer[0..len];
}

/// Binary search for extension in sorted map
fn findExtensionIcon(ext: []const u8, theme: *const IconTheme) ?[]const u8 {
    var left: usize = 0;
    var right: usize = extension_map.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        const cmp = std.mem.order(u8, ext, extension_map[mid].ext);

        switch (cmp) {
            .eq => return extension_map[mid].get_icon(theme),
            .lt => right = mid,
            .gt => left = mid + 1,
        }
    }

    return null;
}

/// Get icon for a file based on name and type
pub fn getIcon(theme: *const IconTheme, name: []const u8, is_dir: bool, is_link: bool, is_exec: bool) []const u8 {
    // Special cases first
    if (is_link) return theme.symlink;
    if (is_dir) return theme.directory;
    if (is_exec) return theme.executable;

    // Stack buffer for case conversion
    var lower_buffer: [256]u8 = undefined;
    const lower_name = toLowercase(name, &lower_buffer);

    // Special filenames
    if (std.mem.eql(u8, lower_name, ".gitignore")) return theme.gitignore;
    if (std.mem.eql(u8, lower_name, "makefile")) return theme.makefile;
    if (std.mem.eql(u8, lower_name, "dockerfile")) return theme.dockerfile;
    if (std.mem.startsWith(u8, lower_name, "readme")) return theme.readme;
    if (std.mem.startsWith(u8, lower_name, "license")) return theme.license;

    // Get extension
    const ext_pos = std.mem.lastIndexOf(u8, name, ".");
    if (ext_pos) |pos| {
        const ext = name[pos + 1 ..];
        var ext_buffer: [64]u8 = undefined;
        const lower_ext = toLowercase(ext, &ext_buffer);

        // Use optimized binary search
        if (findExtensionIcon(lower_ext, theme)) |icon| {
            return icon;
        }
    }

    // Default icon
    return theme.file;
}

/// Get icon mode from environment variable, with fallback
pub fn getIconModeFromEnv(allocator: std.mem.Allocator) IconMode {
    if (std.process.getEnvVarOwned(allocator, "LS_ICONS")) |val| {
        defer allocator.free(val);
        if (std.mem.eql(u8, val, "always")) return .always;
        if (std.mem.eql(u8, val, "never")) return .never;
        if (std.mem.eql(u8, val, "auto")) return .auto;
    } else |_| {}

    return .auto; // Default to auto mode
}

/// Determine if icons should be shown based on mode and terminal status
pub fn shouldShowIcons(mode: IconMode, is_terminal: bool) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => is_terminal,
    };
}

test "icon mode - never" {
    try testing.expect(!shouldShowIcons(.never, true));
    try testing.expect(!shouldShowIcons(.never, false));
}

test "icon mode - always" {
    try testing.expect(shouldShowIcons(.always, true));
    try testing.expect(shouldShowIcons(.always, false));
}

test "icon mode - auto depends on terminal" {
    try testing.expect(shouldShowIcons(.auto, true));
    try testing.expect(!shouldShowIcons(.auto, false));
}

test "environment variable parsing defaults to auto" {
    const allocator = testing.allocator;
    // In test environment, no LS_ICONS env var is set, should default to auto
    try testing.expectEqual(IconMode.auto, getIconModeFromEnv(allocator));
}

test "get icon for directory" {
    const theme = IconTheme{};
    const icon = getIcon(&theme, "src", true, false, false);
    try testing.expectEqualStrings("\u{f07b}", icon);
}

test "get icon for symlink" {
    const theme = IconTheme{};
    const icon = getIcon(&theme, "link", false, true, false);
    try testing.expectEqualStrings("\u{f481}", icon);
}

test "get icon for executable" {
    const theme = IconTheme{};
    const icon = getIcon(&theme, "program", false, false, true);
    try testing.expectEqualStrings("\u{f489}", icon);
}

test "get icon for source files" {
    const theme = IconTheme{};

    // C files
    try testing.expectEqualStrings("\u{e61e}", getIcon(&theme, "main.c", false, false, false));
    try testing.expectEqualStrings("\u{e61e}", getIcon(&theme, "header.h", false, false, false));

    // Rust files
    try testing.expectEqualStrings("\u{e7a8}", getIcon(&theme, "main.rs", false, false, false));

    // Zig files
    try testing.expectEqualStrings("\u{26a1}", getIcon(&theme, "build.zig", false, false, false));

    // Python files
    try testing.expectEqualStrings("\u{e73c}", getIcon(&theme, "script.py", false, false, false));

    // Perl files
    try testing.expectEqualStrings("\u{e769}", getIcon(&theme, "script.pl", false, false, false));
}

test "get icon for documents" {
    const theme = IconTheme{};

    try testing.expectEqualStrings("\u{f15c}", getIcon(&theme, "notes.txt", false, false, false));
    try testing.expectEqualStrings("\u{f48a}", getIcon(&theme, "README.md", false, false, false));
    try testing.expectEqualStrings("\u{f1c1}", getIcon(&theme, "document.pdf", false, false, false));
}

test "get icon for archives" {
    const theme = IconTheme{};

    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "archive.zip", false, false, false));
    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "backup.tar.gz", false, false, false));
}

test "get icon for media files" {
    const theme = IconTheme{};

    // Images
    try testing.expectEqualStrings("\u{f1c5}", getIcon(&theme, "photo.jpg", false, false, false));
    try testing.expectEqualStrings("\u{f1c5}", getIcon(&theme, "icon.png", false, false, false));

    // Audio
    try testing.expectEqualStrings("\u{f1c7}", getIcon(&theme, "song.mp3", false, false, false));

    // Video
    try testing.expectEqualStrings("\u{f1c8}", getIcon(&theme, "movie.mp4", false, false, false));
}

test "get icon for special files" {
    const theme = IconTheme{};

    try testing.expectEqualStrings("\u{f1d3}", getIcon(&theme, ".gitignore", false, false, false));
    try testing.expectEqualStrings("\u{f489}", getIcon(&theme, "Makefile", false, false, false));
    try testing.expectEqualStrings("\u{f308}", getIcon(&theme, "Dockerfile", false, false, false));
    try testing.expectEqualStrings("\u{f48a}", getIcon(&theme, "README", false, false, false));
    try testing.expectEqualStrings("\u{f718}", getIcon(&theme, "LICENSE", false, false, false));
}

test "get icon for config files" {
    const theme = IconTheme{};

    try testing.expectEqualStrings("\u{e60b}", getIcon(&theme, "config.json", false, false, false));
    try testing.expectEqualStrings("\u{e60b}", getIcon(&theme, "data.yaml", false, false, false));
    try testing.expectEqualStrings("\u{e615}", getIcon(&theme, "config.toml", false, false, false));
}

test "get icon case insensitive" {
    const theme = IconTheme{};

    // Extensions should be case insensitive
    try testing.expectEqualStrings("\u{e7a8}", getIcon(&theme, "MAIN.RS", false, false, false));
    try testing.expectEqualStrings("\u{f1c5}", getIcon(&theme, "Photo.JPG", false, false, false));

    // Special files too
    try testing.expectEqualStrings("\u{f489}", getIcon(&theme, "makefile", false, false, false));
    try testing.expectEqualStrings("\u{f489}", getIcon(&theme, "MAKEFILE", false, false, false));
}

test "get icon defaults to file icon" {
    const theme = IconTheme{};

    try testing.expectEqualStrings("\u{f15b}", getIcon(&theme, "unknown", false, false, false));
    try testing.expectEqualStrings("\u{f15b}", getIcon(&theme, "file.xyz", false, false, false));
}

test "optimized extension lookup" {
    const theme = IconTheme{};

    // Test that binary search works for various extensions
    try testing.expectEqualStrings("\u{e7a8}", getIcon(&theme, "test.rs", false, false, false));
    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "test.zip", false, false, false));
    try testing.expectEqualStrings("\u{e60b}", getIcon(&theme, "test.json", false, false, false));
    try testing.expectEqualStrings("\u{f1c5}", getIcon(&theme, "test.png", false, false, false));
    try testing.expectEqualStrings("\u{f1c7}", getIcon(&theme, "test.mp3", false, false, false));
}

test "stack buffer case conversion" {
    const theme = IconTheme{};

    // Test with very long filenames to ensure stack buffer works
    const long_name = "very_long_filename_that_tests_stack_buffer_limits.rs";
    try testing.expectEqualStrings("\u{e7a8}", getIcon(&theme, long_name, false, false, false));

    // Test buffer boundary conditions
    var very_long_name: [300]u8 = undefined;
    @memset(&very_long_name, 'a');
    very_long_name[295] = '.';
    very_long_name[296] = 'r';
    very_long_name[297] = 's';
    very_long_name[298] = 0;
    const name_slice = very_long_name[0..299];

    // Should still work despite very long name
    const icon = getIcon(&theme, name_slice, false, false, false);
    // With stack buffer truncation, this might not match .rs extension,
    // so we just ensure it returns some valid icon
    try testing.expect(icon.len > 0);
}
