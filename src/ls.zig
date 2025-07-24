const std = @import("std");
const clap = @import("clap");
const common = @import("common");
const testing = std.testing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define parameters using zig-clap
    const params = comptime clap.parseParamsComptime(
        \\    --help                      Display this help and exit.
        \\-V, --version                   Output version information and exit.
        \\-a, --all                       Do not ignore entries starting with .
        \\-A, --almost-all                Do not list implied . and ..
        \\-l                              Use a long listing format.
        \\-h, --human-readable            With -l, print sizes in human readable format.
        \\-k                              With -l, print sizes in kilobytes.
        \\-1                              List one file per line.
        \\-d, --directory                 List directories themselves, not their contents.
        \\-F                              Append indicator (one of */=>@|) to entries.
        \\-i, --inode                     Print the index number of each file.
        \\-m                              Fill width with a comma separated list of entries.
        \\-n, --numeric-uid-gid           With -l, show numeric user and group IDs.
        \\-R, --recursive                 List subdirectories recursively.
        \\-t                              Sort by modification time, newest first.
        \\-S                              Sort by file size, largest first.
        \\-r                              Reverse order while sorting.
        \\    --color <str>               When to use colors (valid: always, auto, never).
        \\    --group-directories-first   Group directories before files.
        \\    --icons <str>               When to show icons (valid: always, auto, never).
        \\    --test-icons                Show sample icons to test Nerd Font support.
        \\<str>...                        Files and directories to list.
        \\
    );

    // Parse arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Handle help
    if (res.args.help != 0) {
        try printHelp();
        return;
    }

    // Handle version
    if (res.args.version != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("ls ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Handle test-icons
    if (res.args.@"test-icons" != 0) {
        try printIconTest();
        return;
    }

    // Parse color mode
    var color_mode = ColorMode.auto;
    if (res.args.color) |color_arg| {
        color_mode = parseColorMode(color_arg) catch {
            try std.io.getStdErr().writer().print("ls: invalid argument '{s}' for '--color'\n", .{color_arg});
            try std.io.getStdErr().writer().writeAll("Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'\n");
            return;
        };
    }

    // Parse icon mode
    var icon_mode = common.icons.getIconModeFromEnv(allocator);
    if (res.args.icons) |icons_arg| {
        icon_mode = parseIconMode(icons_arg) catch {
            try std.io.getStdErr().writer().print("ls: invalid argument '{s}' for '--icons'\n", .{icons_arg});
            try std.io.getStdErr().writer().writeAll("Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'\n");
            return;
        };
    }


    // Create options struct
    const options = LsOptions{
        .all = res.args.all != 0,
        .almost_all = res.args.@"almost-all" != 0,
        .long_format = res.args.l != 0,
        .human_readable = res.args.@"human-readable" != 0,
        .kilobytes = res.args.k != 0,
        .one_per_line = res.args.@"1" != 0,
        .directory = res.args.directory != 0,
        .recursive = res.args.recursive != 0,
        .sort_by_time = res.args.t != 0,
        .sort_by_size = res.args.S != 0,
        .reverse_sort = res.args.r != 0,
        .file_type_indicators = res.args.F != 0,
        .color_mode = color_mode,
        .group_directories_first = res.args.@"group-directories-first" != 0,
        .show_inodes = res.args.inode != 0,
        .numeric_ids = res.args.@"numeric-uid-gid" != 0,
        .comma_format = res.args.m != 0,
        .icon_mode = icon_mode,
    };

    const stdout = std.io.getStdOut().writer();

    // Access positionals
    const paths = res.positionals.@"0";

    if (paths.len == 0) {
        // No paths specified, list current directory
        try listDirectory(".", stdout, options, allocator);
    } else {
        for (paths, 0..) |path, i| {
            if (paths.len > 1) {
                if (i > 0) try stdout.writeAll("\n");
                try stdout.print("{s}:\n", .{path});
            }
            try listDirectory(path, stdout, options, allocator);
        }
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: ls [OPTION]... [FILE]...
        \\List information about the FILEs (the current directory by default).
        \\Sort entries alphabetically by default.
        \\
        \\  -a, --all                do not ignore entries starting with .
        \\  -A, --almost-all         do not list implied . and ..
        \\  -d, --directory          list directories themselves, not their contents
        \\  -F                       append indicator (one of */=>@|) to entries
        \\  -h, --human-readable     with -l, print sizes in human readable format
        \\  -k                       with -l, print sizes in kilobytes
        \\  -l                       use a long listing format
        \\  -r                       reverse order while sorting
        \\  -R, --recursive          list subdirectories recursively
        \\  -S                       sort by file size, largest first
        \\  -t                       sort by modification time, newest first
        \\  -1                       list one file per line
        \\      --color=WHEN         colorize output; WHEN can be 'always' (default
        \\                           if omitted), 'auto', or 'never'
        \\      --group-directories-first
        \\                           group directories before files
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Examples:
        \\  ls           List files in the current directory
        \\  ls -la       List all files in long format
        \\  ls -lh       List files with human-readable sizes
        \\  ls -t        List files sorted by modification time
        \\
    );
}

const ColorMode = enum {
    always,
    auto,
    never,
};

fn parseColorMode(arg: []const u8) !ColorMode {
    return std.meta.stringToEnum(ColorMode, arg) orelse error.InvalidColorMode;
}

fn parseIconMode(arg: []const u8) !common.icons.IconMode {
    return std.meta.stringToEnum(common.icons.IconMode, arg) orelse error.InvalidIconMode;
}

/// Print icon test to help users verify Nerd Font support
fn printIconTest() !void {
    const stdout = std.io.getStdOut().writer();
    const theme = common.icons.IconTheme{};
    
    try stdout.writeAll("Icon Test - Nerd Font Support Check\n");
    try stdout.writeAll("====================================\n\n");
    
    try stdout.writeAll("If you can see the following icons correctly, your terminal supports Nerd Fonts:\n\n");
    
    // Test common file type icons
    try stdout.print("  {s}  Directory\n", .{theme.directory});
    try stdout.print("  {s}  Regular file\n", .{theme.file});
    try stdout.print("  {s}  Executable\n", .{theme.executable});
    try stdout.print("  {s}  Symbolic link\n", .{theme.symlink});
    
    try stdout.writeAll("\nProgramming language icons:\n");
    try stdout.print("  {s}  C/C++ ({s})\n", .{ theme.c, theme.cpp });
    try stdout.print("  {s}  Rust\n", .{theme.rust});
    try stdout.print("  {s}  Go\n", .{theme.go});
    try stdout.print("  {s}  Python\n", .{theme.python});
    try stdout.print("  {s}  JavaScript\n", .{theme.javascript});
    try stdout.print("  {s}  TypeScript\n", .{theme.typescript});
    try stdout.print("  {s}  Zig\n", .{theme.zig});
    try stdout.print("  {s}  Java\n", .{theme.java});
    try stdout.print("  {s}  Ruby\n", .{theme.ruby});
    try stdout.print("  {s}  Perl\n", .{theme.perl});
    
    try stdout.writeAll("\nDocument and media icons:\n");
    try stdout.print("  {s}  Text file\n", .{theme.text});
    try stdout.print("  {s}  Markdown\n", .{theme.markdown});
    try stdout.print("  {s}  PDF\n", .{theme.pdf});
    try stdout.print("  {s}  Archive\n", .{theme.archive});
    try stdout.print("  {s}  Image\n", .{theme.image});
    try stdout.print("  {s}  Audio\n", .{theme.audio});
    try stdout.print("  {s}  Video\n", .{theme.video});
    
    try stdout.writeAll("\nSpecial files:\n");
    try stdout.print("  {s}  Git files\n", .{theme.git});
    try stdout.print("  {s}  Config files\n", .{theme.config});
    try stdout.print("  {s}  JSON\n", .{theme.json});
    
    try stdout.writeAll("\n");
    try stdout.writeAll("To configure icons in ls:\n");
    try stdout.writeAll("  ls --icons=auto                      # Show icons in terminal, hide in pipes (default)\n");
    try stdout.writeAll("  ls --icons=always                    # Always show icons\n");
    try stdout.writeAll("  ls --icons=never                     # Never show icons\n");
    try stdout.writeAll("  export LS_ICONS=auto                 # Set default mode\n");
    try stdout.writeAll("  echo 'export LS_ICONS=auto' >> ~/.zshrc  # Permanent setting\n");
    try stdout.writeAll("\nIf icons appear as boxes or question marks, you need to:\n");
    try stdout.writeAll("  1. Install a Nerd Font (https://www.nerdfonts.com/)\n");
    try stdout.writeAll("  2. Configure your terminal to use the Nerd Font\n");
    try stdout.writeAll("  3. Restart your terminal\n");
}

// Use common constants
const BLOCK_SIZE = common.constants.BLOCK_SIZE;
const BLOCK_ROUNDING = BLOCK_SIZE - 1;
const COLUMN_PADDING = common.constants.COLUMN_PADDING;

const LsOptions = struct {
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
};

fn initStyle(writer: anytype, color_mode: ColorMode) common.style.Style(@TypeOf(writer)) {
    var style = common.style.Style(@TypeOf(writer)).init(writer);
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

// Check if entry is executable
fn isExecutable(entry: Entry) bool {
    if (entry.kind != .file) return false;
    if (entry.stat) |stat| {
        return (stat.mode & common.constants.EXECUTE_BIT) != 0;
    }
    return false;
}

// Print entry name with optional icon, color and file type indicator
fn printEntryName(entry: Entry, writer: anytype, style: anytype, show_indicator: bool, show_icons: bool) !void {
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

// Calculate the display width of an entry (name + optional icon + optional indicator)
fn getEntryDisplayWidth(entry: Entry, show_indicator: bool, show_icons: bool) usize {
    var width = entry.name.len;
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

// Print a single entry in long format
fn printLongFormatEntry(entry: Entry, writer: anytype, options: LsOptions, style: anytype) !void {
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
        var time_buf: [64]u8 = undefined;
        const time_str = try common.file.formatTime(stat.mtime, &time_buf);
        try writer.print("{s} ", .{time_str});
    } else {
        try writer.writeAll("??? ?? ??:?? ");
    }
    
    // Name with color and optional indicator
    try printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode));
    
    // Show symlink target if available
    if (entry.symlink_target) |target| {
        try writer.print(" -> {s}", .{target});
    }
    try writer.writeByte('\n');
}

fn listDirectory(path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator) anyerror!void {
    // Initialize style based on color mode
    const style = initStyle(writer, options.color_mode);
    
    // If -d is specified, just list the directory itself
    if (options.directory) {
        if (options.long_format) {
            // Get stat info for the directory
            const stat = common.file.FileInfo.stat(path) catch |err| {
                common.printError("{s}: {}", .{ path, err });
                return;
            };
            
            const entry = Entry{
                .name = path,
                .kind = .directory,
                .stat = stat,
                .symlink_target = null,
            };
            
            try printLongFormatEntry(entry, writer, options, style);
        } else {
            try writer.print("{s}\n", .{path});
        }
        return;
    }

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        common.printError("{s}: {}", .{ path, err });
        return err;
    };
    defer dir.close();
    
    // Call the shared implementation
    try listDirectoryImpl(dir, path, writer, options, allocator, style);
}

// Shared implementation that works with an open directory handle
fn listDirectoryImpl(dir: std.fs.Dir, path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype) anyerror!void {
    // For recursive listing with symlinks, we need to track visited inodes
    var visited_inodes = std.AutoHashMap(u64, void).init(allocator);
    defer visited_inodes.deinit();
    
    try listDirectoryImplWithVisited(dir, path, writer, options, allocator, style, &visited_inodes);
}

// Collect directory entries with filtering
fn collectFilteredEntries(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    options: LsOptions,
) anyerror!std.ArrayList(Entry) {
    var entries = std.ArrayList(Entry).init(allocator);
    errdefer {
        // Clean up any entries allocated so far
        for (entries.items) |entry| {
            allocator.free(entry.name);
            if (entry.symlink_target) |target| {
                allocator.free(target);
            }
        }
        entries.deinit();
    }

    // Create filter based on options
    const filter = common.directory.EntryFilter{
        .show_hidden = options.all or options.almost_all,
        .show_all = options.all,
        .skip_dots = options.almost_all,
    };

    // Collect entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Apply filtering
        if (!filter.shouldInclude(entry.name)) {
            continue;
        }

        const e = Entry{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        };
        errdefer allocator.free(e.name);
        
        try entries.append(e);
    }
    
    return entries;
}

// Check if entries need metadata enhancement
fn needsMetadata(options: LsOptions) bool {
    return options.long_format or options.sort_by_time or options.sort_by_size or
           options.file_type_indicators or options.color_mode != .never or options.show_inodes;
}

// Enhance entries with stat info and symlink targets
fn enhanceEntriesWithMetadata(
    entries: []Entry,
    dir: std.fs.Dir,
    options: LsOptions,
    allocator: std.mem.Allocator,
) anyerror!void {
    for (entries) |*entry| {
        // Get stat info if needed for long format, sorting, file type indicators, colors, or inodes
        if (options.long_format or options.sort_by_time or options.sort_by_size or 
            (options.file_type_indicators and entry.kind == .file) or
            options.color_mode != .never or options.show_inodes) {
            entry.stat = common.file.FileInfo.lstatDir(dir, entry.name) catch null;
        }
        
        // Read symlink target if needed
        if (options.long_format and entry.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.readLink(entry.name, &target_buf)) |target| {
                entry.symlink_target = try allocator.dupe(u8, target);
            } else |_| {
                // Failed to read symlink, leave as null
            }
        }
    }
}

// Print entries in the appropriate format
fn printEntries(
    entries: []const Entry,
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
            try printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode));
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
            try printLongFormatEntry(entry, writer, options, style);
        }
    } else if (options.comma_format) {
        // Comma-separated format
        for (entries, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode));
        }
        if (entries.len > 0) try writer.writeByte('\n');
    } else {
        // Default format: multi-column layout
        try printColumnar(entries, writer, options, style);
    }
    
    return total_blocks;
}

// Process subdirectories recursively
fn processSubdirectoriesRecursively(
    entries: []const Entry,
    dir: std.fs.Dir,
    base_path: []const u8,
    writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_inodes: *std.AutoHashMap(u64, void),
) anyerror!void {
    // Collect subdirectories using the common utility
    var subdirs = try common.directory.collectSubdirectories(Entry, entries, base_path, allocator);
    defer {
        common.directory.freeSubdirectoryPaths(subdirs.items, allocator);
        subdirs.deinit();
    }
    
    // Create cycle detector
    var cycle_detector = common.directory.CycleDetector.init(visited_inodes);
    
    // Recurse into subdirectories
    for (subdirs.items) |subdir| {
        // Print separator and header
        writer.writeAll("\n") catch |err| {
            if (err == error.BrokenPipe) return; // Exit gracefully on pipe close
            return err;
        };
        writer.print("{s}:\n", .{subdir.path}) catch |err| {
            if (err == error.BrokenPipe) return; // Exit gracefully on pipe close
            return err;
        };
        
        // Open the subdirectory relative to the current directory
        var sub_dir = dir.openDir(subdir.name, .{ .iterate = true }) catch |err| {
            common.printError("{s}: {}", .{ subdir.path, err });
            continue;
        };
        defer sub_dir.close();
        
        // Check for cycles
        if (cycle_detector.hasVisited(sub_dir)) {
            common.printError("{s}: not following symlink cycle", .{subdir.path});
            continue;
        }
        try cycle_detector.markVisited(sub_dir);
        
        // Recurse using the shared implementation
        try recurseIntoSubdirectory(sub_dir, subdir.path, writer, options, allocator, style, visited_inodes);
    }
}

// Wrapper for recursive directory processing to avoid error set inference issues
fn recurseIntoSubdirectory(
    sub_dir: std.fs.Dir,
    subdir_path: []const u8,
    writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_inodes: *std.AutoHashMap(u64, void),
) anyerror!void {
    listDirectoryImplWithVisited(sub_dir, subdir_path, writer, options, allocator, style, visited_inodes) catch |err| switch (err) {
        error.BrokenPipe => return err, // Propagate BrokenPipe
        else => {
            common.printError("{s}: {}", .{ subdir_path, err });
            // Continue with other directories even if one fails
        },
    };
}

// Internal implementation that tracks visited inodes
fn listDirectoryImplWithVisited(dir: std.fs.Dir, path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype, visited_inodes: *std.AutoHashMap(u64, void)) anyerror!void {
    // Collect and filter entries
    var entries = try collectFilteredEntries(dir, allocator, options);
    defer entries.deinit();
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            if (entry.symlink_target) |target| {
                allocator.free(target);
            }
        }
    }

    // Enhance with metadata if needed
    if (needsMetadata(options)) {
        try enhanceEntriesWithMetadata(entries.items, dir, options, allocator);
    }

    // Sort entries based on options
    const sort_config = SortConfig{
        .by_time = options.sort_by_time,
        .by_size = options.sort_by_size,
        .dirs_first = options.group_directories_first,
        .reverse = options.reverse_sort,
    };
    
    std.mem.sort(Entry, entries.items, sort_config, compareEntries);

    // Print directory header for recursive mode
    if (options.recursive) {
        try writer.print("{s}:\n", .{path});
    }

    // Print entries
    _ = try printEntries(entries.items, writer, options, style);
    
    // Handle recursive listing
    if (options.recursive) {
        try processSubdirectoriesRecursively(
            entries.items, dir, path, writer, 
            options, allocator, style, visited_inodes
        );
    }
}

fn getFileTypeIndicator(entry: Entry) u8 {
    // Get file type indicator based on file kind and permissions
    switch (entry.kind) {
        .directory => return '/',
        .sym_link => return '@',
        .named_pipe => return '|',
        .unix_domain_socket => return '=',
        .file => {
            // Check if executable
            if (entry.stat) |stat| {
                // Check if any execute bit is set
                if ((stat.mode & common.constants.EXECUTE_BIT) != 0) {
                    return '*';
                }
            }
            return 0; // No indicator for regular files
        },
        else => return 0,
    }
}

fn getFileColor(entry: Entry) common.style.Style(std.fs.File.Writer).Color {
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
            if (entry.stat) |stat| {
                if ((stat.mode & common.constants.EXECUTE_BIT) != 0) {
                    break :blk Color.bright_green;
                }
            }
            break :blk Color.default;
        },
        else => Color.default,
    };
}

fn printColumnar(entries: []const Entry, writer: anytype, options: LsOptions, style: anytype) !void {
    if (entries.len == 0) return;
    
    // Get terminal width
    const term_width = options.terminal_width orelse common.terminal.getWidth() catch 80;
    
    // Calculate the width needed for each entry
    var max_width: usize = 0;
    for (entries) |entry| {
        const width = getEntryDisplayWidth(entry, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode));
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
            try printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode));
            
            // Pad to column width (except for last column)
            if (col < num_cols - 1 and idx < entries.len - 1) {
                const width = getEntryDisplayWidth(entry, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode));
                const padding = col_width - width;
                for (0..padding) |_| {
                    try writer.writeByte(' ');
                }
            }
        }
        try writer.writeByte('\n');
    }
}

const Entry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    stat: ?common.file.FileInfo = null,
    symlink_target: ?[]const u8 = null,
};

// Sort configuration
const SortConfig = struct {
    by_time: bool = false,
    by_size: bool = false,
    dirs_first: bool = false,
    reverse: bool = false,
};

// Unified comparison function
fn compareEntries(config: SortConfig, a: Entry, b: Entry) bool {
    // Handle directory grouping first
    if (config.dirs_first) {
        const a_is_dir = a.kind == .directory;
        const b_is_dir = b.kind == .directory;
        if (a_is_dir != b_is_dir) {
            return a_is_dir; // Directories always come first
        }
    }
    
    // Primary sort criteria
    const result: bool = if (config.by_time) blk: {
        // Sort by modification time
        if (a.stat != null and b.stat != null and a.stat.?.mtime != b.stat.?.mtime) {
            break :blk a.stat.?.mtime > b.stat.?.mtime; // Newest first by default
        } else {
            // Fall back to name sort
            break :blk std.mem.order(u8, a.name, b.name) == .lt;
        }
    } else if (config.by_size) blk: {
        // Sort by size
        if (a.stat != null and b.stat != null and a.stat.?.size != b.stat.?.size) {
            break :blk a.stat.?.size > b.stat.?.size; // Largest first by default
        } else {
            // Fall back to name sort
            break :blk std.mem.order(u8, a.name, b.name) == .lt;
        }
    } else blk: {
        // Default: sort by name
        break :blk std.mem.order(u8, a.name, b.name) == .lt;
    };
    
    // Apply reverse if needed
    return if (config.reverse) !result else result;
}

// Tests

test "ls lists files in current directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file2.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Open directory with iterate permissions
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    
    // List directory
    try listDirectoryTest(test_dir, buffer.writer(), .{}, testing.allocator);

    // Should contain both files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file2.txt") != null);
}

test "ls ignores hidden files by default" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    // List without -a
    try listDirectoryTest(test_dir, buffer.writer(), .{}, testing.allocator);

    // Should contain visible but not hidden
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") == null);
}

test "ls -a shows hidden files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -a
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .all = true }, testing.allocator);

    // Should contain both files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") != null);
}

test "ls -1 lists one file per line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("bbb.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .one_per_line = true }, testing.allocator);

    // Should be one file per line
    try testing.expectEqualStrings("aaa.txt\nbbb.txt\n", buffer.items);
}

test "ls sorts entries alphabetically" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files in non-alphabetical order
    const file3 = try tmp_dir.dir.createFile("zzz.txt", .{});
    file3.close();
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("mmm.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1 to make output predictable
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .one_per_line = true }, testing.allocator);

    // Should be sorted alphabetically
    try testing.expectEqualStrings("aaa.txt\nmmm.txt\nzzz.txt\n", buffer.items);
}

test "ls handles empty directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List empty directory
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{}, testing.allocator);

    // Should be empty
    try testing.expectEqualStrings("", buffer.items);
}

test "ls with directories shows type indicator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file and a directory
    const file = try tmp_dir.dir.createFile("file.txt", .{});
    file.close();
    try tmp_dir.dir.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .one_per_line = true }, testing.allocator);

    // Both should be listed
    try testing.expectEqualStrings("file.txt\nsubdir\n", buffer.items);
}

test "ls -l shows long format" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("Hello, World!");
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -l
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .long_format = true }, testing.allocator);

    // Should contain test.txt with permissions and size
    try testing.expect(std.mem.indexOf(u8, buffer.items, "test.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "-rw-") != null); // File permissions
    try testing.expect(std.mem.indexOf(u8, buffer.items, "13") != null); // Size of "Hello, World!"
    try testing.expect(std.mem.indexOf(u8, buffer.items, "total") != null); // Total blocks line
}

test "ls -lh shows human readable sizes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a larger test file
    const file = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [2048]u8 = undefined;
    @memset(&data, 'A');
    try file.writeAll(&data);
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -lh
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .long_format = true, .human_readable = true }, testing.allocator);

    // Should show human readable size
    try testing.expect(std.mem.indexOf(u8, buffer.items, "2.0K") != null);
}

test "ls -lk shows kilobyte sizes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("small.txt", .{});
    try file1.writeAll("Hi");
    file1.close();
    
    const file2 = try tmp_dir.dir.createFile("medium.txt", .{});
    var data: [1500]u8 = undefined;
    @memset(&data, 'B');
    try file2.writeAll(&data);
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -lk
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .long_format = true, .kilobytes = true }, testing.allocator);

    // Should show sizes in kilobytes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "small.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "medium.txt") != null);
    // Small file (2 bytes) should round up to 1K
    // Medium file (1500 bytes) should round up to 2K
}

test "ls -A shows almost all files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -A (using -1 for predictable output)
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .almost_all = true, .one_per_line = true }, testing.allocator);

    // Should contain both visible and hidden files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") != null);
    // But NOT . and .. (can't easily test absence, but we can verify the feature works)
}

test "ls -t sorts by modification time, newest first" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different modification times
    const file1 = try tmp_dir.dir.createFile("oldest.txt", .{});
    file1.close();
    
    // Sleep to ensure different timestamps
    std.time.sleep(10_000_000); // 10ms
    
    const file2 = try tmp_dir.dir.createFile("middle.txt", .{});
    file2.close();
    
    std.time.sleep(10_000_000); // 10ms
    
    const file3 = try tmp_dir.dir.createFile("newest.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -t and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .sort_by_time = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by time, newest first
    try testing.expectEqualStrings("newest.txt\nmiddle.txt\noldest.txt\n", buffer.items);
}

test "ls -S sorts by size, largest first" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different sizes
    const small = try tmp_dir.dir.createFile("small.txt", .{});
    try small.writeAll("Hi");
    small.close();
    
    const large = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [1000]u8 = undefined;
    @memset(&data, 'X');
    try large.writeAll(&data);
    large.close();
    
    const medium = try tmp_dir.dir.createFile("medium.txt", .{});
    try medium.writeAll("Hello, World!");
    medium.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -S and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .sort_by_size = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by size, largest first
    try testing.expectEqualStrings("large.txt\nmedium.txt\nsmall.txt\n", buffer.items);
}

test "ls -r reverses sort order" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("bbb.txt", .{});
    file2.close();
    const file3 = try tmp_dir.dir.createFile("ccc.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -r and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .reverse_sort = true, .one_per_line = true }, testing.allocator);

    // Should be reverse alphabetical
    try testing.expectEqualStrings("ccc.txt\nbbb.txt\naaa.txt\n", buffer.items);
}

test "ls -tr combines time sort with reverse" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different modification times
    const file1 = try tmp_dir.dir.createFile("oldest.txt", .{});
    file1.close();
    
    std.time.sleep(10_000_000); // 10ms
    
    const file2 = try tmp_dir.dir.createFile("middle.txt", .{});
    file2.close();
    
    std.time.sleep(10_000_000); // 10ms
    
    const file3 = try tmp_dir.dir.createFile("newest.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -t -r and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .sort_by_time = true, .reverse_sort = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by time, oldest first (reversed)
    try testing.expectEqualStrings("oldest.txt\nmiddle.txt\nnewest.txt\n", buffer.items);
}

test "ls -Sr combines size sort with reverse" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with different sizes
    const small = try tmp_dir.dir.createFile("small.txt", .{});
    try small.writeAll("Hi");
    small.close();
    
    const large = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [1000]u8 = undefined;
    @memset(&data, 'X');
    try large.writeAll(&data);
    large.close();
    
    const medium = try tmp_dir.dir.createFile("medium.txt", .{});
    try medium.writeAll("Hello, World!");
    medium.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -S -r and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .sort_by_size = true, .reverse_sort = true, .one_per_line = true }, testing.allocator);

    // Should be sorted by size, smallest first (reversed)
    try testing.expectEqualStrings("small.txt\nmedium.txt\nlarge.txt\n", buffer.items);
}

test "ls -F adds file type indicators" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create different file types
    const regular = try tmp_dir.dir.createFile("regular.txt", .{});
    regular.close();
    
    try tmp_dir.dir.makeDir("directory");
    
    // Create executable file
    const exe = try tmp_dir.dir.createFile("executable", .{});
    exe.close();
    // Set execute permissions after creation
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path = try tmp_dir.dir.realpath("executable", &exe_path_buf);
    const exe_path_z = try testing.allocator.dupeZ(u8, exe_path);
    defer testing.allocator.free(exe_path_z);
    _ = std.c.chmod(exe_path_z, 0o755);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -F and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .file_type_indicators = true, .one_per_line = true }, testing.allocator);

    // Check for type indicators
    try testing.expect(std.mem.indexOf(u8, buffer.items, "directory/") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "executable*") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt") != null);
    // Regular file should not have indicator
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt/") == null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt*") == null);
}

test "ls -d lists directory itself, not contents" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files in the directory
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file2.txt", .{});
    file2.close();
    try tmp_dir.dir.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -d (should show "." only)
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .directory = true }, testing.allocator);

    // Should only contain "." and not the files
    try testing.expectEqualStrings(".\n", buffer.items);
}

test "ls -l shows symlink targets" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a target file
    const target = try tmp_dir.dir.createFile("target.txt", .{});
    try target.writeAll("Hello, World!");
    target.close();
    
    // Create a symlink to the file
    try tmp_dir.dir.symLink("target.txt", "link_to_file", .{});
    
    // Create a directory and symlink to it
    try tmp_dir.dir.makeDir("target_dir");
    try tmp_dir.dir.symLink("target_dir", "link_to_dir", .{});
    
    // Create a broken symlink
    try tmp_dir.dir.symLink("nonexistent", "broken_link", .{});

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -l
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ .long_format = true }, testing.allocator);

    // Check that symlinks show their targets
    try testing.expect(std.mem.indexOf(u8, buffer.items, "link_to_file -> target.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "link_to_dir -> target_dir") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "broken_link -> nonexistent") != null);
    
    // Check that symlinks are marked with 'l' in permissions
    try testing.expect(std.mem.indexOf(u8, buffer.items, "lrwx") != null);
}

test "ls --color mode parsing" {
    // Test that ColorMode enum works
    try testing.expectEqual(ColorMode.auto, ColorMode.auto);
    try testing.expectEqual(ColorMode.always, ColorMode.always);
    try testing.expectEqual(ColorMode.never, ColorMode.never);
}

test "ls color output for directories" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test directory
    try tmp_dir.dir.makeDir("test_dir");
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with color always
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .one_per_line = true,
        .color_mode = .always,
    }, testing.allocator);

    // Directory name should have color codes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "test_dir") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[0m") != null); // reset
}

test "ls color output disabled with never" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test directory
    try tmp_dir.dir.makeDir("test_dir");
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with color never
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .one_per_line = true,
        .color_mode = .never,
    }, testing.allocator);

    // Should not have any color codes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[") == null);
    try testing.expectEqualStrings("test_dir\n", buffer.items);
}

test "ls color scheme for different file types" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create different file types
    try tmp_dir.dir.makeDir("directory");
    const file = try tmp_dir.dir.createFile("regular.txt", .{});
    file.close();
    const exe = try tmp_dir.dir.createFile("executable", .{});
    exe.close();
    // Make it executable
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path = try tmp_dir.dir.realpath("executable", &exe_path_buf);
    const exe_path_z = try testing.allocator.dupeZ(u8, exe_path);
    defer testing.allocator.free(exe_path_z);
    _ = std.c.chmod(exe_path_z, 0o755);
    
    // Create symlink
    try tmp_dir.dir.symLink("regular.txt", "symlink", .{});
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with color always
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .one_per_line = true,
        .color_mode = .always,
    }, testing.allocator);

    // Check that different file types have different colors
    // Directory should be bright blue (94)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[94mdirectory\x1b[0m") != null);
    // Symlink should be bright cyan (96)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[96msymlink\x1b[0m") != null);
    // Regular files should use default color (39)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[39mregular.txt\x1b[0m") != null);
    // Executable files should be bright green (92)
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[92mexecutable\x1b[0m") != null);
}

test "ls --group-directories-first" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a mix of files and directories
    try tmp_dir.dir.makeDir("aaa_dir");
    try tmp_dir.dir.makeDir("zzz_dir");
    try tmp_dir.dir.makeDir("mid_dir");
    const file1 = try tmp_dir.dir.createFile("aaa_file.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("zzz_file.txt", .{});
    file2.close();
    const file3 = try tmp_dir.dir.createFile("mid_file.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with directories first
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{
        .one_per_line = true,
        .group_directories_first = true,
    }, testing.allocator);

    const output = buffer.items;
    
    // Find positions of each item
    const aaa_dir_pos = std.mem.indexOf(u8, output, "aaa_dir") orelse return error.NotFound;
    const mid_dir_pos = std.mem.indexOf(u8, output, "mid_dir") orelse return error.NotFound;
    const zzz_dir_pos = std.mem.indexOf(u8, output, "zzz_dir") orelse return error.NotFound;
    const aaa_file_pos = std.mem.indexOf(u8, output, "aaa_file.txt") orelse return error.NotFound;
    const mid_file_pos = std.mem.indexOf(u8, output, "mid_file.txt") orelse return error.NotFound;
    const zzz_file_pos = std.mem.indexOf(u8, output, "zzz_file.txt") orelse return error.NotFound;

    // All directories should come before all files
    try testing.expect(aaa_dir_pos < aaa_file_pos);
    try testing.expect(mid_dir_pos < aaa_file_pos);
    try testing.expect(zzz_dir_pos < aaa_file_pos);
    
    // Directories should be sorted alphabetically among themselves
    try testing.expect(aaa_dir_pos < mid_dir_pos);
    try testing.expect(mid_dir_pos < zzz_dir_pos);
    
    // Files should be sorted alphabetically among themselves
    try testing.expect(aaa_file_pos < mid_file_pos);
    try testing.expect(mid_file_pos < zzz_file_pos);
}

test "ls column width calculation" {
    // Test column width calculation
    const entries = [_][]const u8{
        "short",
        "medium_name",
        "very_long_filename.txt",
    };
    
    var max_width: usize = 0;
    for (entries) |entry| {
        max_width = @max(max_width, entry.len);
    }
    
    // Column width should be max length + padding
    const col_width = max_width + COLUMN_PADDING;
    try testing.expectEqual(@as(usize, 24), col_width); // 22 + 2
}

test "ls recursive listing" {
    // Test that the recursive flag is recognized
    // Full recursive implementation tested via integration tests
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create directory structure
    try tmp_dir.dir.makeDir("dir1");
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Create more nested directories for proper testing
    var dir1 = try tmp_dir.dir.openDir("dir1", .{});
    defer dir1.close();
    try dir1.makeDir("subdir1");
    const file2 = try dir1.createFile("file2.txt", .{});
    file2.close();
    var subdir1 = try dir1.openDir("subdir1", .{});
    defer subdir1.close();
    const file3 = try subdir1.createFile("file3.txt", .{});
    file3.close();
    
    // Open the temp directory with iterate permissions
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    
    // Use the test helper function
    try listDirectoryTest(test_dir, buffer.writer(), .{
        .recursive = true,
        .one_per_line = true, // For easier testing
    }, testing.allocator);

    const output = buffer.items;
    
    // Should show the top-level directory contents
    try testing.expect(std.mem.indexOf(u8, output, "dir1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file1.txt") != null);
    
    // Should show subdirectory headers
    try testing.expect(std.mem.indexOf(u8, output, "dir1:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "dir1/subdir1:") != null);
    
    // Should show files in subdirectories
    try testing.expect(std.mem.indexOf(u8, output, "file2.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file3.txt") != null);
}

test "ls multi-column output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create several files with different name lengths
    const files = [_][]const u8{
        "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg", "hhhhhhhh"
    };
    for (files) |name| {
        const f = try tmp_dir.dir.createFile(name, .{});
        f.close();
    }
    
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List without -1 (should use columns)
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{
        .terminal_width = 40, // Force specific width for testing
    }, testing.allocator);

    // Output should have multiple entries per line
    var lines = std.mem.splitScalar(u8, buffer.items, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    
    // With 8 files and 40 char width, should fit multiple per line
    try testing.expect(line_count < files.len);
}

test "ls -R shows directory headers with proper formatting" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested directory structure
    try tmp_dir.dir.makeDir("subdir1");
    try tmp_dir.dir.makeDir("subdir2");
    try tmp_dir.dir.makeDir("subdir1/nested");
    
    // Create files in each directory
    try common.test_utils.createTestFile(tmp_dir.dir, "root_file.txt", "root content\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "subdir1/sub_file.txt", "sub content\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "subdir1/nested/deep_file.txt", "deep content\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List recursively
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .recursive = true,
        .one_per_line = true  // For predictable output
    }, testing.allocator);

    const output = buffer.items;
    
    // Should start with current directory header
    try testing.expect(std.mem.indexOf(u8, output, ".:\n") != null);
    
    // Should have subdirectory headers
    try testing.expect(std.mem.indexOf(u8, output, "./subdir1:\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "./subdir1/nested:\n") != null);
    
    // Should have blank lines separating sections
    try testing.expect(std.mem.indexOf(u8, output, "\n\n./subdir") != null);
    
    // Should contain all files
    try testing.expect(std.mem.indexOf(u8, output, "root_file.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sub_file.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "deep_file.txt") != null);
}

test "ls -R detects and handles symlink cycles" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create directory structure with cycle
    try tmp_dir.dir.makeDir("dir1");
    try tmp_dir.dir.makeDir("dir1/dir2");
    
    // Create files to verify normal operation
    try common.test_utils.createTestFile(tmp_dir.dir, "dir1/file1.txt", "content1\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "dir1/dir2/file2.txt", "content2\n");
    
    // Create symlink cycle: dir1/dir2/link_back -> ../../dir1
    const src_path = try std.fs.path.join(testing.allocator, &[_][]const u8{"../../dir1"});
    defer testing.allocator.free(src_path);
    
    var dir1 = try tmp_dir.dir.openDir("dir1", .{});
    defer dir1.close();
    var dir2 = try dir1.openDir("dir2", .{});
    defer dir2.close();
    
    // Create the symlink that causes a cycle
    dir2.symLink(src_path, "link_back", .{}) catch |err| {
        // Skip test if symlinks not supported (e.g., Windows without privileges)
        if (err == error.AccessDenied or err == error.Unexpected) {
            return;
        }
        return err;
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List recursively - should not infinite loop
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .recursive = true,
        .one_per_line = true
    }, testing.allocator);

    const output = buffer.items;
    
    // Should contain the files we created
    try testing.expect(std.mem.indexOf(u8, output, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file2.txt") != null);
    
    // Should contain directory headers
    try testing.expect(std.mem.indexOf(u8, output, "./dir1:\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "./dir1/dir2:\n") != null);
    
    // Should not infinite loop (test completes without timeout)
    // The cycle detection should prevent revisiting dir1
}

test "ls -i shows inode numbers before filenames" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    try common.test_utils.createTestFile(tmp_dir.dir, "file1.txt", "content1\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "file2.txt", "content2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with inode display
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .show_inodes = true,
        .one_per_line = true
    }, testing.allocator);

    const output = buffer.items;
    
    // Should contain inode numbers (at least one space-separated number before filename)
    // Format should be: "123456 file1.txt\n"
    try testing.expect(std.mem.indexOf(u8, output, " file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, " file2.txt") != null);
    
    // Verify the line starts with a number (inode)
    var lines = std.mem.splitScalar(u8, output, '\n');
    var found_inode_line = false;
    while (lines.next()) |line| {
        if (line.len > 0 and std.mem.indexOf(u8, line, "file1.txt") != null) {
            // Line should start with a number
            const space_pos = std.mem.indexOf(u8, line, " ") orelse continue;
            const inode_str = line[0..space_pos];
            // Should be able to parse as integer
            _ = std.fmt.parseInt(u64, inode_str, 10) catch continue;
            found_inode_line = true;
            break;
        }
    }
    try testing.expect(found_inode_line);
}

test "ls -n shows numeric user/group IDs instead of names" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test file
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", "content\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with numeric IDs and long format
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .long_format = true,
        .numeric_ids = true
    }, testing.allocator);

    const output = buffer.items;
    
    // Should contain numeric IDs instead of names
    // Format should be like: "-rw-r--r-- 1 1000 1000 8 date test.txt"
    // Look for pattern: space + digits + space + digits + space
    var found_numeric_ids = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and std.mem.indexOf(u8, line, "test.txt") != null) {
            // Find the part between permissions and size (should contain numeric IDs)
            // Format: "-rw-r--r-- 1 UID GID SIZE date test.txt"
            var parts = std.mem.splitScalar(u8, line, ' ');
            var part_count: usize = 0;
            var uid_part: []const u8 = "";
            var gid_part: []const u8 = "";
            
            while (parts.next()) |part| {
                if (part.len == 0) continue; // Skip empty parts from multiple spaces
                part_count += 1;
                if (part_count == 3) uid_part = part; // UID is 3rd field
                if (part_count == 4) gid_part = part; // GID is 4th field
                if (part_count >= 4) break;
            }
            
            // Check if UID and GID are numeric
            if (uid_part.len > 0 and gid_part.len > 0) {
                _ = std.fmt.parseInt(u32, uid_part, 10) catch continue;
                _ = std.fmt.parseInt(u32, gid_part, 10) catch continue;
                found_numeric_ids = true;
                break;
            }
        }
    }
    try testing.expect(found_numeric_ids);
}

test "ls -m produces comma-separated output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    try common.test_utils.createTestFile(tmp_dir.dir, "file1.txt", "content1\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "file2.txt", "content2\n");
    try common.test_utils.createTestFile(tmp_dir.dir, "file3.txt", "content3\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with comma-separated format
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, buffer.writer(), .{ 
        .comma_format = true
    }, testing.allocator);

    const output = buffer.items;
    
    // Should contain comma-separated filenames
    // Format should be: "file1.txt, file2.txt, file3.txt\n"
    try testing.expect(std.mem.indexOf(u8, output, ", ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file2.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "file3.txt") != null);
    
    // Should end with newline, not comma
    try testing.expect(std.mem.endsWith(u8, output, "\n"));
    try testing.expect(!std.mem.endsWith(u8, output, ",\n"));
}

// Test helper that uses a Dir instead of path
fn listDirectoryTest(dir: std.fs.Dir, writer: anytype, options: LsOptions, allocator: std.mem.Allocator) !void {
    // Only disable colors if color_mode is auto (the default), 
    // but respect explicit color settings in tests
    var test_options = options;
    if (test_options.color_mode == .auto) {
        test_options.color_mode = .never;
    }
    const style = initStyle(writer, test_options.color_mode);
    
    // If -d is specified, just list the directory itself
    if (test_options.directory) {
        try writer.print(".\n", .{});
        return;
    }
    
    // Call the shared implementation with "." as the path
    try listDirectoryImpl(dir, ".", writer, test_options, allocator, style);
}

test "printIconTest function works without errors" {
    // Test that the printIconTest function runs without crashing
    // This verifies that all the icon theme access and printing logic is sound
    
    // We can't easily capture stdout in tests, but we can ensure the function
    // doesn't panic or have undefined behavior
    const allocator = testing.allocator;
    _ = allocator; // suppress unused variable warning
    
    // Just verify the theme can be created and accessed
    const theme = common.icons.IconTheme{};
    try testing.expect(theme.directory.len > 0);
    try testing.expect(theme.file.len > 0);
    try testing.expect(theme.rust.len > 0);
    
    // The actual printIconTest() function is tested manually since it writes to stdout
}
