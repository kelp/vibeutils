const std = @import("std");
const clap = @import("clap");
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
        \\    --time-style <str>          Time/date format (valid: relative, iso, long-iso).
        \\    --git                       Show git status indicators for files.
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
        color_mode = types.parseColorMode(color_arg) catch {
            try std.io.getStdErr().writer().print("ls: invalid argument '{s}' for '--color'\n", .{color_arg});
            try std.io.getStdErr().writer().writeAll("Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'\n");
            return;
        };
    }

    // Parse icon mode
    var icon_mode = common.icons.getIconModeFromEnv(allocator);
    if (res.args.icons) |icons_arg| {
        icon_mode = std.meta.stringToEnum(common.icons.IconMode, icons_arg) orelse {
            try std.io.getStdErr().writer().print("ls: invalid argument '{s}' for '--icons'\n", .{icons_arg});
            try std.io.getStdErr().writer().writeAll("Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'\n");
            return;
        };
    }

    // Parse time style
    var time_style = TimeStyle.relative; // Default to relative
    if (res.args.@"time-style") |time_style_arg| {
        time_style = types.parseTimeStyle(time_style_arg) catch {
            try std.io.getStdErr().writer().print("ls: invalid argument '{s}' for '--time-style'\n", .{time_style_arg});
            try std.io.getStdErr().writer().writeAll("Valid arguments are:\n  - 'relative'\n  - 'iso'\n  - 'long-iso'\n");
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
        .time_style = time_style,
        .show_git_status = res.args.git != 0,
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

// Shared implementation that works with an open directory handle
fn listDirectoryImpl(dir: std.fs.Dir, path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype) anyerror!void {
    // For recursive listing with symlinks, we need to track visited inodes
    var visited_inodes = std.AutoHashMap(u64, void).init(allocator);
    defer visited_inodes.deinit();

    try listDirectoryImplWithVisited(dir, path, writer, options, allocator, style, &visited_inodes);
}

// Internal implementation that tracks visited inodes
fn listDirectoryImplWithVisited(dir: std.fs.Dir, path: []const u8, writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype, visited_inodes: *std.AutoHashMap(u64, void)) anyerror!void {
    // Collect and filter entries
    var entries = try entry_collector.collectFilteredEntries(dir, allocator, options);
    defer entries.deinit();
    defer {
        entry_collector.freeEntries(entries.items, allocator);
    }

    // Enhance with metadata if needed
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

    // Print entries
    _ = try formatter.printEntries(entries.items, writer, options, style);

    // Handle recursive listing
    if (options.recursive) {
        try entry_collector.processSubdirectoriesRecursively(entries.items, dir, path, writer, options, allocator, style, visited_inodes);
    }
}

// Now we can fix the circular dependency by implementing the recursive function here
/// This is called from entry_collector.zig to complete the recursion
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
        error.BrokenPipe => return err, // Propagate BrokenPipe
        else => {
            common.printError("{s}: {}", .{ subdir_path, err });
            // Continue with other directories even if one fails
        },
    };
}

// Include all test files
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
