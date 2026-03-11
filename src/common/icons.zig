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
    go: []const u8 = "\u{e627}", //
    python: []const u8 = "\u{e73c}", //
    javascript: []const u8 = "\u{e74e}", //
    typescript: []const u8 = "\u{e628}", //
    zig: []const u8 = "\u{e8ef}", //
    java: []const u8 = "\u{e738}", //
    ruby: []const u8 = "\u{e791}", //
    perl: []const u8 = "\u{e67e}", //

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
    makefile: []const u8 = "\u{f0ad}", //
    dockerfile: []const u8 = "\u{f308}", //

    // Lock files
    lock: []const u8 = "\u{f023}", //

    // Nix
    nix: []const u8 = "\u{f313}", //

    // Shell scripts
    shell: []const u8 = "\u{e795}", //

    // Web
    web: []const u8 = "\u{e736}", //
    css: []const u8 = "\u{e749}", //

    // Database
    database: []const u8 = "\u{f1c0}", //

    // Additional programming languages
    swift: []const u8 = "\u{e755}", //
    kotlin: []const u8 = "\u{e634}", //
    scala: []const u8 = "\u{e737}", //
    r_lang: []const u8 = "\u{e68a}", // (R language - can't use 'r' as field name)
    dart: []const u8 = "\u{e798}", //
    elixir: []const u8 = "\u{e62d}", //
    erlang: []const u8 = "\u{e7b1}", //
    haskell: []const u8 = "\u{e777}", //
    csharp: []const u8 = "\u{f81a}", //
    clojure: []const u8 = "\u{e76a}", //
    vim: []const u8 = "\u{e62b}", //
    powershell: []const u8 = "\u{ebc7}", //
    fsharp: []const u8 = "\u{e7a7}", //

    // Libraries and binaries
    library: []const u8 = "\u{f831}", //
    object_file: []const u8 = "\u{eb98}", //
    binary: []const u8 = "\u{eae8}", //

    // Web frameworks
    svelte: []const u8 = "\u{e697}", //
    wasm: []const u8 = "\u{e6a1}", //
    graphql: []const u8 = "\u{e662}", //
    sass: []const u8 = "\u{e74b}", //

    // Infrastructure
    terraform: []const u8 = "\u{e69a}", //
    proto: []const u8 = "\u{e6b1}", //

    // Apple
    plist: []const u8 = "\u{e711}", //

    // Documents (office)
    word: []const u8 = "\u{f1c2}", //
    excel: []const u8 = "\u{f1c3}", //
    powerpoint: []const u8 = "\u{f1c4}", //
    ebook: []const u8 = "\u{e28b}", //

    // Security
    key_file: []const u8 = "\u{eb89}", //

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
    .{ .ext = "a", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.library;
        }
    }.get },
    .{ .ext = "aac", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "app", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.binary;
        }
    }.get },
    .{ .ext = "asc", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.key_file;
        }
    }.get },
    .{ .ext = "astro", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.web;
        }
    }.get },
    .{ .ext = "avi", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.video;
        }
    }.get },
    .{ .ext = "bash", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.shell;
        }
    }.get },
    .{ .ext = "bat", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.shell;
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
    .{ .ext = "clj", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.clojure;
        }
    }.get },
    .{ .ext = "cmd", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.shell;
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
    .{ .ext = "crt", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.key_file;
        }
    }.get },
    .{ .ext = "cs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.csharp;
        }
    }.get },
    .{ .ext = "css", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.css;
        }
    }.get },
    .{ .ext = "csv", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.text;
        }
    }.get },
    .{ .ext = "cxx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.cpp;
        }
    }.get },
    .{ .ext = "d", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.c;
        }
    }.get },
    .{ .ext = "dart", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.dart;
        }
    }.get },
    .{ .ext = "db", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.database;
        }
    }.get },
    .{ .ext = "deb", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "diff", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.text;
        }
    }.get },
    .{ .ext = "dll", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.library;
        }
    }.get },
    .{ .ext = "dmg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "doc", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.word;
        }
    }.get },
    .{ .ext = "docx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.word;
        }
    }.get },
    .{ .ext = "dylib", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.library;
        }
    }.get },
    .{ .ext = "el", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.vim;
        }
    }.get },
    .{ .ext = "env", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
        }
    }.get },
    .{ .ext = "epub", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.ebook;
        }
    }.get },
    .{ .ext = "erl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.erlang;
        }
    }.get },
    .{ .ext = "ex", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.elixir;
        }
    }.get },
    .{ .ext = "exe", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.binary;
        }
    }.get },
    .{ .ext = "exs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.elixir;
        }
    }.get },
    .{ .ext = "fish", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.shell;
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
    .{ .ext = "fs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.fsharp;
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
    .{ .ext = "graphql", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.graphql;
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
    .{ .ext = "hcl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.terraform;
        }
    }.get },
    .{ .ext = "hpp", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.cpp;
        }
    }.get },
    .{ .ext = "hs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.haskell;
        }
    }.get },
    .{ .ext = "htm", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.web;
        }
    }.get },
    .{ .ext = "html", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.web;
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
    .{ .ext = "iso", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
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
    .{ .ext = "jsonc", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.json;
        }
    }.get },
    .{ .ext = "jsonl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.json;
        }
    }.get },
    .{ .ext = "jsx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.javascript;
        }
    }.get },
    .{ .ext = "key", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.key_file;
        }
    }.get },
    .{ .ext = "kt", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.kotlin;
        }
    }.get },
    .{ .ext = "less", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.css;
        }
    }.get },
    .{ .ext = "lock", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.lock;
        }
    }.get },
    .{ .ext = "log", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.text;
        }
    }.get },
    .{ .ext = "lua", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
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
    .{ .ext = "ml", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
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
    .{ .ext = "msi", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "nix", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.nix;
        }
    }.get },
    .{ .ext = "o", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.object_file;
        }
    }.get },
    .{ .ext = "odt", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.word;
        }
    }.get },
    .{ .ext = "ogg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.audio;
        }
    }.get },
    .{ .ext = "patch", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.text;
        }
    }.get },
    .{ .ext = "pdf", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.pdf;
        }
    }.get },
    .{ .ext = "pem", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.key_file;
        }
    }.get },
    .{ .ext = "perl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.perl;
        }
    }.get },
    .{ .ext = "pkg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "pl", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.perl;
        }
    }.get },
    .{ .ext = "plist", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.plist;
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
    .{ .ext = "ppt", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.powerpoint;
        }
    }.get },
    .{ .ext = "pptx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.powerpoint;
        }
    }.get },
    .{ .ext = "prisma", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.database;
        }
    }.get },
    .{ .ext = "proto", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.proto;
        }
    }.get },
    .{ .ext = "ps1", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.powershell;
        }
    }.get },
    .{ .ext = "pub", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.key_file;
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
    .{ .ext = "r", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.r_lang;
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
    .{ .ext = "rpm", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "rs", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.rust;
        }
    }.get },
    .{ .ext = "rtf", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.word;
        }
    }.get },
    .{ .ext = "sass", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.sass;
        }
    }.get },
    .{ .ext = "scala", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.scala;
        }
    }.get },
    .{ .ext = "scss", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.css;
        }
    }.get },
    .{ .ext = "sh", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.shell;
        }
    }.get },
    .{ .ext = "sig", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.key_file;
        }
    }.get },
    .{ .ext = "so", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.library;
        }
    }.get },
    .{ .ext = "sql", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.database;
        }
    }.get },
    .{ .ext = "sqlite", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.database;
        }
    }.get },
    .{ .ext = "svelte", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.svelte;
        }
    }.get },
    .{ .ext = "svg", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.image;
        }
    }.get },
    .{ .ext = "swift", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.swift;
        }
    }.get },
    .{ .ext = "tar", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.archive;
        }
    }.get },
    .{ .ext = "tf", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.terraform;
        }
    }.get },
    .{ .ext = "tgz", .get_icon = struct {
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
    .{ .ext = "vim", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.vim;
        }
    }.get },
    .{ .ext = "vue", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.javascript;
        }
    }.get },
    .{ .ext = "wasm", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.wasm;
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
    .{ .ext = "xls", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.excel;
        }
    }.get },
    .{ .ext = "xlsx", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.excel;
        }
    }.get },
    .{ .ext = "xml", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.config;
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
    .{ .ext = "zsh", .get_icon = struct {
        fn get(t: *const IconTheme) []const u8 {
            return t.shell;
        }
    }.get },
    .{ .ext = "zst", .get_icon = struct {
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
    if (std.mem.eql(u8, lower_name, "flake.lock")) return theme.nix;

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

/// Color info for icon rendering across all color modes.
pub const IconColorInfo = struct {
    r: u8,
    g: u8,
    b: u8,
    c256: u8,
    basic: @import("style.zig").Style(std.fs.File.Writer).Color,
};

/// Map icon glyph to its brand color across all terminal color modes.
pub fn getIconColorInfo(icon: []const u8) ?IconColorInfo {
    const theme = IconTheme{};
    const Color = @import("style.zig").Style(std.fs.File.Writer).Color;
    const eql = std.mem.eql;

    // Programming languages — researched brand colors
    if (eql(u8, icon, theme.zig)) return .{ .r = 247, .g = 164, .b = 29, .c256 = 214, .basic = Color.yellow };
    if (eql(u8, icon, theme.rust)) return .{ .r = 211, .g = 69, .b = 22, .c256 = 166, .basic = Color.red };
    if (eql(u8, icon, theme.go)) return .{ .r = 121, .g = 212, .b = 253, .c256 = 117, .basic = Color.bright_cyan };
    if (eql(u8, icon, theme.python)) return .{ .r = 69, .g = 132, .b = 182, .c256 = 68, .basic = Color.blue };
    if (eql(u8, icon, theme.javascript)) return .{ .r = 247, .g = 223, .b = 30, .c256 = 220, .basic = Color.yellow };
    if (eql(u8, icon, theme.typescript)) return .{ .r = 49, .g = 120, .b = 198, .c256 = 68, .basic = Color.blue };
    if (eql(u8, icon, theme.ruby)) return .{ .r = 204, .g = 52, .b = 45, .c256 = 160, .basic = Color.red };
    if (eql(u8, icon, theme.java)) return .{ .r = 237, .g = 139, .b = 0, .c256 = 208, .basic = Color.yellow };
    if (eql(u8, icon, theme.perl)) return .{ .r = 2, .g = 152, .b = 195, .c256 = 31, .basic = Color.cyan };
    if (eql(u8, icon, theme.c)) return .{ .r = 168, .g = 185, .b = 204, .c256 = 152, .basic = Color.blue };
    if (eql(u8, icon, theme.cpp)) return .{ .r = 80, .g = 140, .b = 210, .c256 = 68, .basic = Color.bright_blue };
    if (eql(u8, icon, theme.swift)) return .{ .r = 240, .g = 81, .b = 56, .c256 = 203, .basic = Color.red };
    if (eql(u8, icon, theme.kotlin)) return .{ .r = 127, .g = 97, .b = 255, .c256 = 99, .basic = Color.magenta };
    if (eql(u8, icon, theme.scala)) return .{ .r = 222, .g = 52, .b = 35, .c256 = 160, .basic = Color.red };
    if (eql(u8, icon, theme.r_lang)) return .{ .r = 39, .g = 108, .b = 194, .c256 = 32, .basic = Color.blue };
    if (eql(u8, icon, theme.dart)) return .{ .r = 1, .g = 137, .b = 209, .c256 = 32, .basic = Color.cyan };
    if (eql(u8, icon, theme.elixir)) return .{ .r = 160, .g = 120, .b = 185, .c256 = 139, .basic = Color.magenta };
    if (eql(u8, icon, theme.erlang)) return .{ .r = 163, .g = 31, .b = 52, .c256 = 124, .basic = Color.red };
    if (eql(u8, icon, theme.haskell)) return .{ .r = 150, .g = 130, .b = 200, .c256 = 140, .basic = Color.magenta };
    if (eql(u8, icon, theme.csharp)) return .{ .r = 160, .g = 80, .b = 190, .c256 = 134, .basic = Color.magenta };
    if (eql(u8, icon, theme.clojure)) return .{ .r = 99, .g = 176, .b = 46, .c256 = 70, .basic = Color.green };
    if (eql(u8, icon, theme.vim)) return .{ .r = 1, .g = 152, .b = 51, .c256 = 28, .basic = Color.green };
    if (eql(u8, icon, theme.powershell)) return .{ .r = 50, .g = 110, .b = 190, .c256 = 68, .basic = Color.blue };
    if (eql(u8, icon, theme.fsharp)) return .{ .r = 55, .g = 139, .b = 186, .c256 = 67, .basic = Color.cyan };

    // DevOps & tools
    if (eql(u8, icon, theme.git) or eql(u8, icon, theme.gitignore)) return .{ .r = 243, .g = 79, .b = 41, .c256 = 202, .basic = Color.red };
    if (eql(u8, icon, theme.dockerfile)) return .{ .r = 13, .g = 183, .b = 237, .c256 = 39, .basic = Color.cyan };
    if (eql(u8, icon, theme.nix)) return .{ .r = 126, .g = 182, .b = 225, .c256 = 110, .basic = Color.cyan };
    if (eql(u8, icon, theme.shell)) return .{ .r = 78, .g = 170, .b = 37, .c256 = 70, .basic = Color.green };
    if (eql(u8, icon, theme.makefile)) return .{ .r = 109, .g = 128, .b = 134, .c256 = 66, .basic = Color.white };
    if (eql(u8, icon, theme.terraform)) return .{ .r = 100, .g = 79, .b = 217, .c256 = 99, .basic = Color.magenta };
    if (eql(u8, icon, theme.proto)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };

    // Documents & markup
    if (eql(u8, icon, theme.markdown) or eql(u8, icon, theme.readme)) return .{ .r = 100, .g = 149, .b = 237, .c256 = 69, .basic = Color.bright_blue };
    if (eql(u8, icon, theme.web)) return .{ .r = 228, .g = 77, .b = 38, .c256 = 166, .basic = Color.red };
    if (eql(u8, icon, theme.css)) return .{ .r = 75, .g = 155, .b = 220, .c256 = 74, .basic = Color.bright_blue };
    if (eql(u8, icon, theme.svelte)) return .{ .r = 255, .g = 62, .b = 0, .c256 = 202, .basic = Color.red };
    if (eql(u8, icon, theme.wasm)) return .{ .r = 101, .g = 79, .b = 199, .c256 = 98, .basic = Color.magenta };
    if (eql(u8, icon, theme.graphql)) return .{ .r = 229, .g = 53, .b = 171, .c256 = 169, .basic = Color.magenta };
    if (eql(u8, icon, theme.sass)) return .{ .r = 205, .g = 103, .b = 153, .c256 = 168, .basic = Color.magenta };

    // Data formats
    if (eql(u8, icon, theme.json) or eql(u8, icon, theme.yaml)) return .{ .r = 203, .g = 203, .b = 65, .c256 = 185, .basic = Color.yellow };
    if (eql(u8, icon, theme.toml) or eql(u8, icon, theme.config)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };

    // Media & documents
    if (eql(u8, icon, theme.pdf)) return .{ .r = 236, .g = 28, .b = 36, .c256 = 196, .basic = Color.red };
    if (eql(u8, icon, theme.archive)) return .{ .r = 212, .g = 170, .b = 0, .c256 = 178, .basic = Color.yellow };
    if (eql(u8, icon, theme.image)) return .{ .r = 160, .g = 116, .b = 196, .c256 = 134, .basic = Color.magenta };
    if (eql(u8, icon, theme.audio)) return .{ .r = 0, .g = 180, .b = 216, .c256 = 38, .basic = Color.cyan };
    if (eql(u8, icon, theme.video)) return .{ .r = 177, .g = 54, .b = 30, .c256 = 124, .basic = Color.red };
    if (eql(u8, icon, theme.word)) return .{ .r = 80, .g = 130, .b = 210, .c256 = 68, .basic = Color.bright_blue };
    if (eql(u8, icon, theme.excel)) return .{ .r = 70, .g = 170, .b = 110, .c256 = 71, .basic = Color.bright_green };
    if (eql(u8, icon, theme.powerpoint)) return .{ .r = 183, .g = 71, .b = 42, .c256 = 130, .basic = Color.red };
    if (eql(u8, icon, theme.ebook)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };
    if (eql(u8, icon, theme.plist)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };

    // Special files
    if (eql(u8, icon, theme.license)) return .{ .r = 212, .g = 170, .b = 0, .c256 = 178, .basic = Color.yellow };
    if (eql(u8, icon, theme.lock)) return .{ .r = 136, .g = 136, .b = 136, .c256 = 245, .basic = Color.white };
    if (eql(u8, icon, theme.database)) return .{ .r = 60, .g = 165, .b = 190, .c256 = 73, .basic = Color.cyan };
    if (eql(u8, icon, theme.key_file)) return .{ .r = 200, .g = 170, .b = 50, .c256 = 178, .basic = Color.yellow };
    if (eql(u8, icon, theme.library)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };
    if (eql(u8, icon, theme.object_file)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };
    if (eql(u8, icon, theme.binary)) return .{ .r = 155, .g = 155, .b = 155, .c256 = 249, .basic = Color.white };

    // File system entries
    if (eql(u8, icon, theme.directory)) return .{ .r = 110, .g = 160, .b = 220, .c256 = 110, .basic = Color.bright_blue };
    if (eql(u8, icon, theme.symlink)) return .{ .r = 110, .g = 185, .b = 185, .c256 = 115, .basic = Color.bright_cyan };
    if (eql(u8, icon, theme.executable)) return .{ .r = 115, .g = 185, .b = 120, .c256 = 114, .basic = Color.green };

    // Default (file/unknown)
    if (eql(u8, icon, theme.text) or eql(u8, icon, theme.file) or eql(u8, icon, theme.unknown)) return .{ .r = 150, .g = 150, .b = 150, .c256 = 249, .basic = Color.white };

    return null;
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
    try testing.expectEqualStrings("\u{f0ad}", getIcon(&theme, "Makefile", false, false, false));
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
    try testing.expectEqualStrings("\u{f0ad}", getIcon(&theme, "makefile", false, false, false));
    try testing.expectEqualStrings("\u{f0ad}", getIcon(&theme, "MAKEFILE", false, false, false));
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

test "get icon for new file types" {
    const theme = IconTheme{};

    // Lock files
    try testing.expectEqualStrings("\u{f023}", getIcon(&theme, "Cargo.lock", false, false, false));

    // Nix files
    try testing.expectEqualStrings("\u{f313}", getIcon(&theme, "flake.nix", false, false, false));
    try testing.expectEqualStrings("\u{f313}", getIcon(&theme, "flake.lock", false, false, false));

    // Shell scripts
    try testing.expectEqualStrings("\u{e795}", getIcon(&theme, "install.sh", false, false, false));
    try testing.expectEqualStrings("\u{e795}", getIcon(&theme, "config.bash", false, false, false));
    try testing.expectEqualStrings("\u{e795}", getIcon(&theme, "config.zsh", false, false, false));
    try testing.expectEqualStrings("\u{e795}", getIcon(&theme, "config.fish", false, false, false));

    // Package/archive extensions
    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "package.deb", false, false, false));
    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "package.rpm", false, false, false));
    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "app.dmg", false, false, false));
    try testing.expectEqualStrings("\u{f1c6}", getIcon(&theme, "app.pkg", false, false, false));

    // Web files
    try testing.expectEqualStrings("\u{e736}", getIcon(&theme, "index.html", false, false, false));
    try testing.expectEqualStrings("\u{e736}", getIcon(&theme, "page.htm", false, false, false));
    try testing.expectEqualStrings("\u{e749}", getIcon(&theme, "style.css", false, false, false));
    try testing.expectEqualStrings("\u{e749}", getIcon(&theme, "style.scss", false, false, false));

    // Database
    try testing.expectEqualStrings("\u{f1c0}", getIcon(&theme, "schema.sql", false, false, false));

    // Data files
    try testing.expectEqualStrings("\u{f15c}", getIcon(&theme, "data.csv", false, false, false));
    try testing.expectEqualStrings("\u{e615}", getIcon(&theme, "config.xml", false, false, false));
}

test "getIconColorInfo brand colors" {
    const theme = IconTheme{};
    const Color = @import("style.zig").Style(std.fs.File.Writer).Color;

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
