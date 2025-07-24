const std = @import("std");
const testing = std.testing;

/// Icon display modes
pub const IconMode = enum {
    never,  // Never show icons (default)
    always, // Always show icons
};

/// Icon theme with Nerd Font glyphs
pub const IconTheme = struct {
    // Directories and links
    directory: []const u8 = "\u{f07b}",       // 
    directory_open: []const u8 = "\u{f07c}",  // 
    symlink: []const u8 = "\u{f481}",         // 
    
    // File types by category
    file: []const u8 = "\u{f15b}",            // 
    executable: []const u8 = "\u{f489}",      // 
    
    // Programming languages
    c: []const u8 = "\u{e61e}",               // 
    cpp: []const u8 = "\u{e61d}",             // 
    rust: []const u8 = "\u{e7a8}",            // 
    go: []const u8 = "\u{e626}",              // 
    python: []const u8 = "\u{e73c}",          // 
    javascript: []const u8 = "\u{e74e}",      // 
    typescript: []const u8 = "\u{e628}",      // 
    zig: []const u8 = "\u{26a1}",             // ⚡ (until official icon)
    java: []const u8 = "\u{e738}",            // 
    ruby: []const u8 = "\u{e791}",            // 
    perl: []const u8 = "\u{e769}",            // 
    
    // Documents
    text: []const u8 = "\u{f15c}",            // 
    markdown: []const u8 = "\u{f48a}",        // 
    pdf: []const u8 = "\u{f1c1}",             // 
    
    // Archives
    archive: []const u8 = "\u{f1c6}",         // 
    
    // Images
    image: []const u8 = "\u{f1c5}",           // 
    
    // Audio/Video
    audio: []const u8 = "\u{f1c7}",           // 
    video: []const u8 = "\u{f1c8}",           // 
    
    // Config
    config: []const u8 = "\u{e615}",          // 
    json: []const u8 = "\u{e60b}",            // 
    yaml: []const u8 = "\u{e60b}",            // 
    toml: []const u8 = "\u{e615}",            // 
    
    // Special files
    git: []const u8 = "\u{f1d3}",             // 
    gitignore: []const u8 = "\u{f1d3}",       // 
    license: []const u8 = "\u{f718}",         // 
    readme: []const u8 = "\u{f48a}",          // 
    makefile: []const u8 = "\u{f489}",        // 
    dockerfile: []const u8 = "\u{f308}",      // 
    
    // Fallback for unknown
    unknown: []const u8 = "\u{f15b}",         // 
};

/// Get icon for a file based on name and type
pub fn getIcon(theme: *const IconTheme, name: []const u8, is_dir: bool, is_link: bool, is_exec: bool) []const u8 {
    // Special cases first
    if (is_link) return theme.symlink;
    if (is_dir) return theme.directory;
    if (is_exec) return theme.executable;
    
    // Check full filename for special files
    const lower_name = std.ascii.allocLowerString(std.heap.page_allocator, name) catch name;
    defer if (lower_name.ptr != name.ptr) std.heap.page_allocator.free(lower_name);
    
    // Special filenames
    if (std.mem.eql(u8, lower_name, ".gitignore")) return theme.gitignore;
    if (std.mem.eql(u8, lower_name, "makefile")) return theme.makefile;
    if (std.mem.eql(u8, lower_name, "dockerfile")) return theme.dockerfile;
    if (std.mem.startsWith(u8, lower_name, "readme")) return theme.readme;
    if (std.mem.startsWith(u8, lower_name, "license")) return theme.license;
    
    // Get extension
    const ext_pos = std.mem.lastIndexOf(u8, name, ".");
    if (ext_pos) |pos| {
        const ext = name[pos + 1..];
        const lower_ext = std.ascii.allocLowerString(std.heap.page_allocator, ext) catch ext;
        defer if (lower_ext.ptr != ext.ptr) std.heap.page_allocator.free(lower_ext);
        
        // Programming languages
        if (std.mem.eql(u8, lower_ext, "c") or std.mem.eql(u8, lower_ext, "h")) return theme.c;
        if (std.mem.eql(u8, lower_ext, "cpp") or std.mem.eql(u8, lower_ext, "cc") or 
            std.mem.eql(u8, lower_ext, "cxx") or std.mem.eql(u8, lower_ext, "hpp")) return theme.cpp;
        if (std.mem.eql(u8, lower_ext, "rs")) return theme.rust;
        if (std.mem.eql(u8, lower_ext, "go")) return theme.go;
        if (std.mem.eql(u8, lower_ext, "py") or std.mem.eql(u8, lower_ext, "pyc")) return theme.python;
        if (std.mem.eql(u8, lower_ext, "js") or std.mem.eql(u8, lower_ext, "mjs")) return theme.javascript;
        if (std.mem.eql(u8, lower_ext, "ts") or std.mem.eql(u8, lower_ext, "tsx")) return theme.typescript;
        if (std.mem.eql(u8, lower_ext, "zig")) return theme.zig;
        if (std.mem.eql(u8, lower_ext, "java") or std.mem.eql(u8, lower_ext, "class")) return theme.java;
        if (std.mem.eql(u8, lower_ext, "rb")) return theme.ruby;
        if (std.mem.eql(u8, lower_ext, "pl") or std.mem.eql(u8, lower_ext, "pm") or std.mem.eql(u8, lower_ext, "perl")) return theme.perl;
        
        // Documents
        if (std.mem.eql(u8, lower_ext, "txt")) return theme.text;
        if (std.mem.eql(u8, lower_ext, "md") or std.mem.eql(u8, lower_ext, "markdown")) return theme.markdown;
        if (std.mem.eql(u8, lower_ext, "pdf")) return theme.pdf;
        
        // Archives
        if (std.mem.eql(u8, lower_ext, "zip") or std.mem.eql(u8, lower_ext, "tar") or
            std.mem.eql(u8, lower_ext, "gz") or std.mem.eql(u8, lower_ext, "bz2") or
            std.mem.eql(u8, lower_ext, "xz") or std.mem.eql(u8, lower_ext, "7z") or
            std.mem.eql(u8, lower_ext, "rar")) return theme.archive;
        
        // Images
        if (std.mem.eql(u8, lower_ext, "png") or std.mem.eql(u8, lower_ext, "jpg") or
            std.mem.eql(u8, lower_ext, "jpeg") or std.mem.eql(u8, lower_ext, "gif") or
            std.mem.eql(u8, lower_ext, "svg") or std.mem.eql(u8, lower_ext, "ico") or
            std.mem.eql(u8, lower_ext, "bmp") or std.mem.eql(u8, lower_ext, "webp")) return theme.image;
        
        // Audio
        if (std.mem.eql(u8, lower_ext, "mp3") or std.mem.eql(u8, lower_ext, "wav") or
            std.mem.eql(u8, lower_ext, "flac") or std.mem.eql(u8, lower_ext, "ogg") or
            std.mem.eql(u8, lower_ext, "m4a") or std.mem.eql(u8, lower_ext, "aac")) return theme.audio;
        
        // Video
        if (std.mem.eql(u8, lower_ext, "mp4") or std.mem.eql(u8, lower_ext, "avi") or
            std.mem.eql(u8, lower_ext, "mkv") or std.mem.eql(u8, lower_ext, "mov") or
            std.mem.eql(u8, lower_ext, "webm") or std.mem.eql(u8, lower_ext, "flv")) return theme.video;
        
        // Config
        if (std.mem.eql(u8, lower_ext, "json")) return theme.json;
        if (std.mem.eql(u8, lower_ext, "yaml") or std.mem.eql(u8, lower_ext, "yml")) return theme.yaml;
        if (std.mem.eql(u8, lower_ext, "toml")) return theme.toml;
        if (std.mem.eql(u8, lower_ext, "conf") or std.mem.eql(u8, lower_ext, "cfg") or
            std.mem.eql(u8, lower_ext, "ini")) return theme.config;
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
    } else |_| {}
    
    return .never; // Safe default
}

/// Determine if icons should be shown based on mode
pub fn shouldShowIcons(mode: IconMode) bool {
    return switch (mode) {
        .always => true,
        .never => false,
    };
}

test "icon mode - never" {
    try testing.expect(!shouldShowIcons(.never));
}

test "icon mode - always" {
    try testing.expect(shouldShowIcons(.always));
}

test "environment variable parsing defaults to never" {
    const allocator = testing.allocator;
    // In test environment, no LS_ICONS env var is set
    try testing.expectEqual(IconMode.never, getIconModeFromEnv(allocator));
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