//! Main entry point for the ls command with file listing functionality
const std = @import("std");
const common = @import("common");

// Import our modules
const types = @import("types.zig");
const display = @import("display.zig");
const entry_collector = @import("entry_collector.zig");
const sorter = @import("sorter.zig");
const formatter = @import("formatter.zig");
const git_integration = @import("git_integration.zig");

const LsOptions = types.LsOptions;
const Entry = types.Entry;
const ColorMode = types.ColorMode;
const TimeStyle = types.TimeStyle;

/// Command-line argument structure parsed by ArgParser
const LsArgs = struct {
    help: bool = false,
    version: bool = false,
    all: bool = false,
    almost_all: bool = false,
    long_format: bool = false,
    human_readable: bool = false,
    kilobytes: bool = false,
    one_per_line: bool = false,
    directory: bool = false,
    file_type_indicators: bool = false,
    show_inodes: bool = false,
    comma_format: bool = false,
    numeric_ids: bool = false,
    recursive: bool = false,
    sort_by_time: bool = false,
    sort_by_size: bool = false,
    reverse_sort: bool = false,
    color: ?[]const u8 = null,
    group_directories_first: bool = false,
    icons: ?[]const u8 = null,
    test_icons: bool = false,
    time_style: ?[]const u8 = null,
    git: bool = false,
    positionals: []const []const u8 = &.{},

    /// Metadata for argument parser help generation
    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .all = .{ .short = 'a', .desc = "Do not ignore entries starting with ." },
        .almost_all = .{ .short = 'A', .desc = "Do not list implied . and .." },
        .long_format = .{ .short = 'l', .desc = "Use a long listing format" },
        .human_readable = .{ .short = 'h', .desc = "With -l, print sizes in human readable format" },
        .kilobytes = .{ .short = 'k', .desc = "With -l, print sizes in kilobytes" },
        .one_per_line = .{ .short = '1', .desc = "List one file per line" },
        .directory = .{ .short = 'd', .desc = "List directories themselves, not their contents" },
        .file_type_indicators = .{ .short = 'F', .desc = "Append indicator (one of */=>@|) to entries" },
        .show_inodes = .{ .short = 'i', .desc = "Print the index number of each file" },
        .comma_format = .{ .short = 'm', .desc = "Fill width with a comma separated list of entries" },
        .numeric_ids = .{ .short = 'n', .desc = "With -l, show numeric user and group IDs" },
        .recursive = .{ .short = 'R', .desc = "List subdirectories recursively" },
        .sort_by_time = .{ .short = 't', .desc = "Sort by modification time, newest first" },
        .sort_by_size = .{ .short = 'S', .desc = "Sort by file size, largest first" },
        .reverse_sort = .{ .short = 'r', .desc = "Reverse order while sorting" },
        .color = .{ .short = 0, .desc = "When to use colors (valid: always, auto, never)", .value_name = "WHEN" },
        .group_directories_first = .{ .short = 0, .desc = "Group directories before files" },
        .icons = .{ .short = 0, .desc = "When to show icons (valid: always, auto, never)", .value_name = "WHEN" },
        .test_icons = .{ .short = 0, .desc = "Show sample icons to test Nerd Font support" },
        .time_style = .{ .short = 0, .desc = "Time/date format (valid: relative, iso, long-iso)", .value_name = "STYLE" },
        .git = .{ .short = 0, .desc = "Show git status indicators for files" },
    };
};

/// Main entry point for the ls command
/// Parses arguments and delegates to lsMain
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(LsArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.fatal("invalid argument", .{});
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    // Create stdout writer once and pass it through
    const stdout = std.io.getStdOut().writer();

    try lsMain(stdout, args, allocator);
}

/// Core ls functionality that accepts a writer parameter
/// This allows for testing and different output targets
fn lsMain(writer: anytype, args: LsArgs, allocator: std.mem.Allocator) !void {
    // Handle help
    if (args.help) {
        try printHelp(writer);
        return;
    }

    // Handle version
    if (args.version) {
        try writer.print("ls ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Handle test-icons
    if (args.test_icons) {
        try printIconTest(writer);
        return;
    }

    // Parse color mode
    // Default to 'auto' which enables colors in terminal but not in pipes
    var color_mode = ColorMode.auto;
    if (args.color) |color_arg| {
        color_mode = types.parseColorMode(color_arg) catch {
            common.fatal("invalid argument '{s}' for '--color'\nValid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'", .{color_arg});
        };
    }

    // Parse icon mode
    // First check environment variable LS_ICONS, then command-line override
    var icon_mode = common.icons.getIconModeFromEnv(allocator);
    if (args.icons) |icons_arg| {
        icon_mode = std.meta.stringToEnum(common.icons.IconMode, icons_arg) orelse {
            common.fatal("invalid argument '{s}' for '--icons'\nValid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'", .{icons_arg});
        };
    }

    // Parse time style
    // Default to 'relative' for human-friendly time displays
    var time_style = TimeStyle.relative;
    if (args.time_style) |time_style_arg| {
        time_style = types.parseTimeStyle(time_style_arg) catch {
            common.fatal("invalid argument '{s}' for '--time-style'\nValid arguments are:\n  - 'relative'\n  - 'iso'\n  - 'long-iso'", .{time_style_arg});
        };
    }

    // Create options struct by consolidating all parsed arguments
    const options = LsOptions{
        .all = args.all,
        .almost_all = args.almost_all,
        .long_format = args.long_format,
        .human_readable = args.human_readable,
        .kilobytes = args.kilobytes,
        .one_per_line = args.one_per_line,
        .directory = args.directory,
        .recursive = args.recursive,
        .sort_by_time = args.sort_by_time,
        .sort_by_size = args.sort_by_size,
        .reverse_sort = args.reverse_sort,
        .file_type_indicators = args.file_type_indicators,
        .color_mode = color_mode,
        .group_directories_first = args.group_directories_first,
        .show_inodes = args.show_inodes,
        .numeric_ids = args.numeric_ids,
        .comma_format = args.comma_format,
        .icon_mode = icon_mode,
        .time_style = time_style,
        .show_git_status = args.git,
    };

    // Access positionals (the paths to list)
    const paths = args.positionals;

    if (paths.len == 0) {
        // No paths specified, list current directory
        try listDirectory(".", writer, options, allocator);
    } else {
        // List each specified path
        // When multiple paths are given, print headers between them
        for (paths, 0..) |path, i| {
            if (paths.len > 1) {
                if (i > 0) try writer.writeAll("\n");
                try writer.print("{s}:\n", .{path});
            }
            try listDirectory(path, writer, options, allocator);
        }
    }
}

/// Print help message with usage examples
fn printHelp(writer: anytype) !void {
    // Use auto-generated help from ArgParser
    try common.argparse.ArgParser.printHelp(LsArgs, "ls", writer);

    // Add custom examples section
    try writer.writeAll(
        \\
        \\List information about the FILEs (the current directory by default).
        \\Sort entries alphabetically by default.
        \\
        \\Examples:
        \\  ls           List files in the current directory
        \\  ls -la       List all files in long format
        \\  ls -lh       List files with human-readable sizes
        \\  ls -t        List files sorted by modification time
        \\  ls --icons=always --color=always  List with colors and icons
        \\  ls --git     Show git status for files
        \\
    );
}

/// Print comprehensive icon test to verify Nerd Font support
fn printIconTest(writer: anytype) !void {
    const theme = common.icons.IconTheme{};

    try writer.writeAll("Icon Test - Nerd Font Support Check\n");
    try writer.writeAll("====================================\n\n");

    try writer.writeAll("If you can see the following icons correctly, your terminal supports Nerd Fonts:\n\n");

    // Test common file type icons
    try writer.print("  {s}  Directory\n", .{theme.directory});
    try writer.print("  {s}  Regular file\n", .{theme.file});
    try writer.print("  {s}  Executable\n", .{theme.executable});
    try writer.print("  {s}  Symbolic link\n", .{theme.symlink});

    try writer.writeAll("\nProgramming language icons:\n");
    try writer.print("  {s}  C/C++ ({s})\n", .{ theme.c, theme.cpp });
    try writer.print("  {s}  Rust\n", .{theme.rust});
    try writer.print("  {s}  Go\n", .{theme.go});
    try writer.print("  {s}  Python\n", .{theme.python});
    try writer.print("  {s}  JavaScript\n", .{theme.javascript});
    try writer.print("  {s}  TypeScript\n", .{theme.typescript});
    try writer.print("  {s}  Zig\n", .{theme.zig});
    try writer.print("  {s}  Java\n", .{theme.java});
    try writer.print("  {s}  Ruby\n", .{theme.ruby});
    try writer.print("  {s}  Perl\n", .{theme.perl});

    try writer.writeAll("\nDocument and media icons:\n");
    try writer.print("  {s}  Text file\n", .{theme.text});
    try writer.print("  {s}  Markdown\n", .{theme.markdown});
    try writer.print("  {s}  PDF\n", .{theme.pdf});
    try writer.print("  {s}  Archive\n", .{theme.archive});
    try writer.print("  {s}  Image\n", .{theme.image});
    try writer.print("  {s}  Audio\n", .{theme.audio});
    try writer.print("  {s}  Video\n", .{theme.video});

    try writer.writeAll("\nSpecial files:\n");
    try writer.print("  {s}  Git files\n", .{theme.git});
    try writer.print("  {s}  Config files\n", .{theme.config});
    try writer.print("  {s}  JSON\n", .{theme.json});

    try writer.writeAll("\n");
    try writer.writeAll("To configure icons in ls:\n");
    try writer.writeAll("  ls --icons=auto                      # Show icons in terminal, hide in pipes (default)\n");
    try writer.writeAll("  ls --icons=always                    # Always show icons\n");
    try writer.writeAll("  ls --icons=never                     # Never show icons\n");
    try writer.writeAll("  export LS_ICONS=auto                 # Set default mode\n");
    try writer.writeAll("  echo 'export LS_ICONS=auto' >> ~/.zshrc  # Permanent setting\n");
    try writer.writeAll("\nIf icons appear as boxes or question marks, you need to:\n");
    try writer.writeAll("  1. Install a Nerd Font (https://www.nerdfonts.com/)\n");
    try writer.writeAll("  2. Configure your terminal to use the Nerd Font\n");
    try writer.writeAll("  3. Restart your terminal\n");
}

/// List a directory or file, handling both files and directories appropriately
/// Errors are printed but don't stop execution except for BrokenPipe
fn listDirectory(path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator) anyerror!void {
    // Initialize style based on color mode
    const style = display.initStyle(writer, options.color_mode);

    // Get stat info to determine if it's a file or directory
    const stat = common.file.FileInfo.stat(path) catch |err| {
        common.printError("{s}: {}", .{ path, err });
        return;
    };

    // If it's a file (not a directory), just print the file entry
    if (stat.kind != .directory) {
        var entry = Entry{
            .name = std.fs.path.basename(path),
            .kind = stat.kind,
            .stat = stat,
            .symlink_target = null,
        };

        // Get Git status for the file if requested
        // We initialize the git repo at the current directory and check the file's status
        if (options.show_git_status) {
            var git_repo = git_integration.initGitRepo(allocator, ".");
            defer if (git_repo) |*repo| repo.deinit();

            entry.git_status = git_integration.getFileGitStatus(if (git_repo) |*repo| repo else null, entry.name);
        }

        if (options.long_format) {
            try formatter.printLongFormatEntry(entry, writer, options, style);
        } else {
            try display.printEntryName(entry, writer, style, options.file_type_indicators, common.icons.shouldShowIcons(options.icon_mode), options.show_git_status);
        }
        try writer.writeAll("\n");
        return;
    }

    // If -d is specified, just list the directory itself
    if (options.directory) {
        if (options.long_format) {
            const entry = Entry{
                .name = path,
                .kind = .directory,
                .stat = stat,
                .symlink_target = null,
            };

            try formatter.printLongFormatEntry(entry, writer, options, style);
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

/// Set up visited inode tracking for cycle detection in recursive mode
fn listDirectoryImpl(dir: std.fs.Dir, path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype) anyerror!void {
    // For recursive listing with symlinks, we need to track visited inodes
    var visited_inodes = std.AutoHashMap(u64, void).init(allocator);
    defer visited_inodes.deinit();

    try listDirectoryImplWithVisited(dir, path, writer, options, allocator, style, &visited_inodes);
}

/// Core directory listing logic with cycle detection
/// Collects, sorts, and prints directory entries
fn listDirectoryImplWithVisited(dir: std.fs.Dir, path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype, visited_inodes: *std.AutoHashMap(u64, void)) anyerror!void {
    // Collect and filter entries based on options
    var entries = try entry_collector.collectFilteredEntries(dir, allocator, options);
    defer entries.deinit();
    defer {
        // Free any allocated memory within entries (e.g., symlink targets)
        entry_collector.freeEntries(entries.items, allocator);
    }

    // Enhance with metadata if needed for sorting or display
    if (entry_collector.needsMetadata(options)) {
        try entry_collector.enhanceEntriesWithMetadata(entries.items, dir, options, allocator);
    }

    // Sort entries based on options
    const sort_config = types.SortConfig{
        .by_time = options.sort_by_time,
        .by_size = options.sort_by_size,
        .dirs_first = options.group_directories_first,
        .reverse = options.reverse_sort,
    };

    sorter.sortEntries(entries.items, sort_config);

    // Print directory header for recursive mode
    if (options.recursive) {
        try writer.print("{s}:\n", .{path});
    }

    // Print entries using the appropriate formatter
    _ = try formatter.printEntries(entries.items, writer, options, style);

    // Handle recursive listing
    if (options.recursive) {
        try entry_collector.processSubdirectoriesRecursively(entries.items, dir, path, writer, options, allocator, style, visited_inodes);
    }
}

/// Recursively list a subdirectory with proper error handling
/// BrokenPipe errors are propagated, others are printed but don't stop processing
pub fn recurseIntoSubdirectory(
    sub_dir: std.fs.Dir,
    subdir_path: []const u8,
    writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_inodes: *std.AutoHashMap(u64, void),
) anyerror!void {
    listDirectoryImplWithVisited(sub_dir, subdir_path, writer, options, allocator, style, visited_inodes) catch |err| switch (err) {
        error.BrokenPipe => return err, // Propagate BrokenPipe for correct pipe behavior
        else => {
            common.printError("{s}: {}", .{ subdir_path, err });
            // Continue with other directories even if one fails
        },
    };
}

// Import all module tests for comprehensive test coverage
test {
    _ = @import("display.zig");
    _ = @import("entry_collector.zig");
    _ = @import("formatter.zig");
    _ = @import("git_integration.zig");
    _ = @import("sorter.zig");
    _ = @import("test_utils.zig");
    _ = @import("types.zig");
    _ = @import("integration_test.zig");
}

// Test the refactored lsMain function with writer parameter
test "lsMain help works with different writers" {
    const testing = std.testing;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = LsArgs{
        .help = true,
        .positionals = &.{},
    };

    try lsMain(buffer.writer(), args, testing.allocator);

    // Should contain help text
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: ls") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "--help") != null);
}

test "lsMain version works with different writers" {
    const testing = std.testing;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = LsArgs{
        .version = true,
        .positionals = &.{},
    };

    try lsMain(buffer.writer(), args, testing.allocator);

    // Should contain version info
    try testing.expect(std.mem.indexOf(u8, buffer.items, "ls (") != null);
}
