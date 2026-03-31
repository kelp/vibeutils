//! Main entry point for the ls command with file listing functionality
const std = @import("std");
const common = @import("common");
const testing = std.testing;

// Import our modules
const types = @import("types.zig");
const display = @import("display.zig");
const entry_collector = @import("entry_collector.zig");
const sorter = @import("sorter.zig");
const formatter = @import("formatter.zig");
const recursive = @import("recursive.zig");
const core = @import("core.zig");

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
    append_slash_dirs: bool = false,
    non_printable_as_question: bool = false,
    omit_owner: bool = false,
    omit_group: bool = false,
    show_inodes: bool = false,
    comma_format: bool = false,
    numeric_ids: bool = false,
    recursive: bool = false,
    sort_by_time: bool = false,
    sort_by_size: bool = false,
    reverse_sort: bool = false,
    no_sort: bool = false,
    show_blocks: bool = false,
    use_atime: bool = false,
    use_ctime: bool = false,
    multi_column: bool = false,
    columns_across: bool = false,
    full_time: bool = false,
    follow_all_symlinks: bool = false,
    follow_cmdline_symlinks: bool = false,
    escape_non_printable: bool = false,
    hide_backups: bool = false,
    dired: bool = false,
    show_acls: bool = false,
    colorize: bool = false,
    ignore_pattern: ?[]const u8 = null,
    show_file_flags: bool = false,
    no_follow_symlinks: bool = false,
    unsorted: bool = false,
    version_sort: bool = false,
    output_width: ?u16 = null,
    show_whiteouts: bool = false,
    sort_by_extension: bool = false,
    sort_by_name: bool = false,
    show_xattrs: bool = false,
    show_sip: bool = false,
    thousands_grouping: bool = false,
    color: ?[]const u8 = null,
    group_directories_first: bool = false,
    icons: ?[]const u8 = null,
    test_icons: bool = false,
    time_style: ?[]const u8 = null,
    git: ?[]const u8 = null,
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
        .append_slash_dirs = .{ .short = 'p', .desc = "Write a slash (/) after each directory name" },
        .non_printable_as_question = .{ .short = 'q', .desc = "Force non-printable characters to be written as '?'" },
        .omit_owner = .{ .short = 'g', .desc = "Like -l, but do not print the owner" },
        .omit_group = .{ .short = 'o', .desc = "Like -l, but do not print the group" },
        .show_inodes = .{ .short = 'i', .desc = "Print the index number of each file" },
        .comma_format = .{ .short = 'm', .desc = "Fill width with a comma separated list of entries" },
        .numeric_ids = .{ .short = 'n', .desc = "With -l, show numeric user and group IDs" },
        .recursive = .{ .short = 'R', .desc = "List subdirectories recursively" },
        .sort_by_time = .{ .short = 't', .desc = "Sort by modification time, newest first" },
        .sort_by_size = .{ .short = 'S', .desc = "Sort by file size, largest first" },
        .reverse_sort = .{ .short = 'r', .desc = "Reverse order while sorting" },
        .no_sort = .{ .short = 'f', .desc = "Do not sort; list entries in directory order (implies -a)" },
        .show_blocks = .{ .short = 's', .desc = "Display number of filesystem blocks" },
        .use_atime = .{ .short = 'u', .desc = "Use access time instead of modification time" },
        .use_ctime = .{ .short = 'c', .desc = "Use status change time instead of modification time" },
        .multi_column = .{ .short = 'C', .desc = "Force multi-column output sorted down columns" },
        .columns_across = .{ .short = 'x', .desc = "Multi-column output sorted across rows" },
        .full_time = .{ .short = 'T', .desc = "With -l, show complete time including seconds" },
        .follow_all_symlinks = .{ .short = 'L', .desc = "Follow all symbolic links" },
        .follow_cmdline_symlinks = .{ .short = 'H', .desc = "Follow symbolic links on the command line" },
        .escape_non_printable = .{ .short = 'b', .desc = "Print C-style escape sequences for non-printable characters" },
        .hide_backups = .{ .short = 'B', .desc = "Do not list entries ending with ~" },
        .dired = .{ .short = 'D', .desc = "Generate output suitable for Emacs dired mode" },
        .show_acls = .{ .short = 'e', .desc = "Display ACL information in long format" },
        .colorize = .{ .short = 'G', .desc = "Enable colorized output" },
        .ignore_pattern = .{ .short = 'I', .desc = "Do not list entries matching shell PATTERN", .value_name = "PATTERN" },
        .show_file_flags = .{ .short = 'O', .desc = "Display file flags in long format" },
        .no_follow_symlinks = .{ .short = 'P', .desc = "Do not follow symbolic links" },
        .unsorted = .{ .short = 'U', .desc = "Do not sort; list entries in directory order" },
        .version_sort = .{ .short = 'v', .desc = "Natural sort of version numbers within text" },
        .output_width = .{ .short = 'w', .desc = "Set output width to COLS columns", .value_name = "COLS" },
        .show_whiteouts = .{ .short = 'W', .desc = "Display whiteout entries" },
        .sort_by_extension = .{ .short = 'X', .desc = "Sort alphabetically by entry extension" },
        .sort_by_name = .{ .short = 'y', .desc = "Sort by name (default behavior)" },
        .show_xattrs = .{ .short = '@', .desc = "Display extended attribute keys and sizes" },
        .show_sip = .{ .short = '%', .desc = "Display SIP protection information" },
        .thousands_grouping = .{ .short = ',', .desc = "Format file sizes with thousands grouping" },
        .color = .{ .short = 0, .desc = "When to use colors (valid: always, auto, never)", .value_name = "WHEN" },
        .group_directories_first = .{ .short = 0, .desc = "Group directories before files" },
        .icons = .{ .short = 0, .desc = "When to show icons (valid: always, auto, never)", .value_name = "WHEN" },
        .test_icons = .{ .short = 0, .desc = "Show sample icons to test Nerd Font support" },
        .time_style = .{ .short = 0, .desc = "Time/date format (valid: default, relative, iso, long-iso)", .value_name = "STYLE" },
        .git = .{ .short = 0, .desc = "when to show git status (valid: always, auto, never)", .value_name = "WHEN" },
    };
};

/// Main entry point for the ls command
/// Parses arguments and delegates to runLs
pub fn main() !void {
    // Use Arena allocator for better resource management in CLI tools
    // Keep GPA only for debug builds to detect memory leaks
    if (std.debug.runtime_safety) {
        // Debug build: use GPA to detect memory leaks
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        return mainWithAllocator(allocator);
    } else {
        // Release build: use Arena allocator for better performance
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        return mainWithAllocator(allocator);
    }
}

/// Main implementation that accepts an allocator
fn mainWithAllocator(allocator: std.mem.Allocator) !void {

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(LsArgs, allocator) catch |err| {
        // Use specific error information instead of generic "invalid argument"
        var stderr_buffer: [8192]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        common.fatalWithWriter(stderr, "argument parsing failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(args.positionals);

    // Create stdout and stderr writers and pass them through
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runLs(allocator, args, stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

/// Wrapper function for consistent fuzz testing interface
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser (same as mainWithAllocator)
    const parsed_args = common.argparse.ArgParser.parse(LsArgs, allocator, args) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "ls", "argument parsing failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(parsed_args.positionals);

    // Call the main ls implementation which returns an exit code
    return runLs(allocator, parsed_args, stdout_writer, stderr_writer) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "ls", "execution failed: {s}", .{@errorName(err)});
        return 1;
    };
}

/// Core ls functionality that accepts separate stdout and stderr writers
/// This allows for testing and different output targets
/// Returns exit code: 0 for success, 2 for serious errors (e.g. nonexistent path)
pub fn runLs(allocator: std.mem.Allocator, args: LsArgs, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    return try lsMain(stdout_writer, stderr_writer, args, allocator);
}

/// Core ls functionality that accepts a writer parameter
/// This allows for testing and different output targets
/// Returns exit code: 0 for success, 2 for serious errors
fn lsMain(writer: anytype, stderr_writer: anytype, args: LsArgs, allocator: std.mem.Allocator) !u8 {
    // Handle help
    if (args.help) {
        try printHelp(allocator, writer);
        return 0;
    }

    // Handle version
    if (args.version) {
        try writer.print("ls ({s}) {s}\n", .{ common.name, common.version });
        return 0;
    }

    // Handle test-icons
    if (args.test_icons) {
        try printIconTest(writer);
        return 0;
    }

    // Resolve display config from environment and terminal state
    const display_config = common.display_config.DisplayConfig.resolve(allocator);

    // Map resolved display config to ls-specific color/icon modes.
    // DisplayConfig already handled VIBEUTILS_STYLE, individual env
    // vars, NO_COLOR, and TTY detection.
    var color_mode: ColorMode = if (display_config.color == .on) .always else .never;
    var icon_mode: common.icons.IconMode = blk: {
        // LS_ICONS env var can override if set
        const env_mode = common.icons.getIconModeFromEnv(allocator);
        if (env_mode != .auto) break :blk env_mode;
        break :blk if (display_config.icons == .on) .always else .never;
    };

    // Explicit CLI flags override everything
    if (args.color) |color_arg| {
        const parsed = types.parseColorMode(color_arg) catch {
            common.fatalWithWriter(stderr_writer, "invalid argument '{s}' for '--color'\nValid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'", .{color_arg});
        };
        color_mode = parsed;
    }
    // -G: macOS-style enable colorized output (equivalent to --color=auto)
    if (args.colorize) {
        color_mode = .auto;
    }
    if (args.icons) |icons_arg| {
        icon_mode = std.meta.stringToEnum(common.icons.IconMode, icons_arg) orelse {
            common.fatalWithWriter(stderr_writer, "invalid argument '{s}' for '--icons'\nValid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'", .{icons_arg});
        };
    }

    if (args.git) |git_arg| {
        if (!std.mem.eql(u8, git_arg, "always") and
            !std.mem.eql(u8, git_arg, "auto") and
            !std.mem.eql(u8, git_arg, "never"))
        {
            common.fatalWithWriter(stderr_writer, "invalid argument '{s}' for '--git'\nValid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'", .{git_arg});
        }
    }

    // Parse time style
    // Default to traditional format; -h implies relative unless explicit --time-style
    var time_style = TimeStyle.default;
    if (args.time_style) |time_style_arg| {
        time_style = types.parseTimeStyle(time_style_arg) catch {
            common.fatalWithWriter(stderr_writer, "invalid argument '{s}' for '--time-style'\nValid arguments are:\n  - 'default'\n  - 'relative'\n  - 'iso'\n  - 'long-iso'", .{time_style_arg});
        };
    } else if (args.human_readable) {
        time_style = .relative;
    }

    // -T overrides time style to full (seconds + year)
    if (args.full_time) {
        time_style = .full;
    }

    // Detect terminal status for icons and colors
    const stdout_file = std.fs.File.stdout();
    const is_terminal = stdout_file.isTty();

    // Create options struct by consolidating all parsed arguments
    // -g and -o imply long format
    // -f implies -a (show all entries)
    const options = LsOptions{
        .all = args.all or args.no_sort,
        .almost_all = args.almost_all,
        .long_format = args.long_format or args.omit_owner or args.omit_group or args.numeric_ids,
        .human_readable = args.human_readable,
        .kilobytes = args.kilobytes,
        .one_per_line = args.one_per_line,
        .directory = args.directory,
        .recursive = args.recursive,
        .sort_by_time = args.sort_by_time,
        .sort_by_size = args.sort_by_size,
        .reverse_sort = args.reverse_sort,
        .file_type_indicators = args.file_type_indicators,
        .append_slash_dirs = args.append_slash_dirs,
        .non_printable_as_question = args.non_printable_as_question,
        .omit_owner = args.omit_owner,
        .omit_group = args.omit_group,
        .color_mode = color_mode,
        .group_directories_first = args.group_directories_first,
        .show_inodes = args.show_inodes,
        .numeric_ids = args.numeric_ids,
        .comma_format = args.comma_format,
        .icon_mode = icon_mode,
        .time_style = time_style,
        .show_git_status = resolveGitMode(args.git, display_config),
        .is_terminal = is_terminal,
        .no_sort = args.no_sort or args.unsorted,
        .show_blocks = args.show_blocks,
        .use_atime = args.use_atime,
        .use_ctime = args.use_ctime,
        .columns_across = args.columns_across,
        .full_time = args.full_time,
        .follow_all_symlinks = args.follow_all_symlinks,
        .follow_cmdline_symlinks = args.follow_cmdline_symlinks,
        .escape_non_printable = args.escape_non_printable,
        .hide_backups = args.hide_backups,
        .ignore_pattern = args.ignore_pattern,
        .no_follow_symlinks = args.no_follow_symlinks,
        .unsorted = args.unsorted,
        .version_sort = args.version_sort,
        .sort_by_extension = args.sort_by_extension,
        .thousands_grouping = args.thousands_grouping,
        .terminal_width = args.output_width,
    };

    // Initialize GitContext once if git status is requested
    var git_context: ?types.GitContext = null;
    if (options.show_git_status) {
        git_context = types.GitContext.init(allocator, ".");
        // Report any git initialization issues only when git features were explicitly requested
        if (git_context) |*ctx| {
            ctx.reportInitializationIssues(allocator, stderr_writer, "ls", options.show_git_status);
        }
    }
    defer if (git_context) |*ctx| ctx.deinit();

    // Access positionals (the paths to list)
    const paths = args.positionals;
    var had_error = false;

    if (paths.len == 0) {
        // No paths specified, list current directory
        try listDirectory(".", writer, stderr_writer, options, allocator, if (git_context) |*ctx| ctx else null);
    } else if (paths.len == 1) {
        // Single path: no headers needed
        listDirectory(paths[0], writer, stderr_writer, options, allocator, if (git_context) |*ctx| ctx else null) catch {
            had_error = true;
        };
    } else {
        // Multiple operands: GNU-style separation.
        // 1. List file operands first (no headers).
        // 2. List directory operands with "dir:" headers.
        var file_count: usize = 0;
        var dir_count: usize = 0;

        for (paths) |path| {
            const stat = common.file.FileInfo.stat(path) catch {
                // Errors are handled later during listDirectory
                dir_count += 1; // count as dir so it gets its own section
                continue;
            };
            if (stat.kind == .directory) {
                dir_count += 1;
            } else {
                file_count += 1;
            }
        }

        // First pass: list file operands (no headers)
        for (paths) |path| {
            const stat = common.file.FileInfo.stat(path) catch continue;
            if (stat.kind != .directory) {
                listDirectory(path, writer, stderr_writer, options, allocator, if (git_context) |*ctx| ctx else null) catch {
                    had_error = true;
                };
            }
        }

        // Second pass: list directory operands with headers
        var dir_idx: usize = 0;
        for (paths) |path| {
            const is_dir = blk: {
                const stat = common.file.FileInfo.stat(path) catch break :blk true;
                break :blk stat.kind == .directory;
            };
            if (!is_dir) continue;

            // Blank line separator between sections
            if (file_count > 0 or dir_idx > 0) try writer.writeAll("\n");
            try writer.print("{s}:\n", .{path});
            listDirectory(path, writer, stderr_writer, options, allocator, if (git_context) |*ctx| ctx else null) catch {
                had_error = true;
            };
            dir_idx += 1;
        }
    }

    return if (had_error) 2 else 0;
}

/// Print help message with usage examples
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: ls [OPTION]... [FILE]...
        \\List information about the FILEs (the current directory by default).
        \\Sort entries alphabetically by default.
        \\
        \\  -a, --all                  do not ignore entries starting with .
        \\  -A, --almost-all           do not list implied . and ..
        \\  -b, --escape-non-printable print C-style escapes for non-printable characters
        \\  -B, --hide-backups         do not list entries ending with ~
        \\  -c, --use-ctime            use status change time instead of modification time
        \\  -C, --multi-column         force multi-column output sorted down columns
        \\      --color=WHEN           when to use colors (valid: always, auto, never)
        \\  -,                         format file sizes with thousands grouping
        \\  -D                         generate output for Emacs dired mode (no-op)
        \\  -e                         display ACL information (no-op)
        \\  -m, --comma-format         fill width with a comma separated list of entries
        \\  -d, --directory            list directories themselves, not their contents
        \\  -f, --no-sort              do not sort; list in directory order (implies -a)
        \\  -F, --file-type-indicators append indicator (one of */=>@|) to entries
        \\  -g, --omit-owner           like -l, but do not print the owner
        \\  -G                         enable colorized output
        \\  -H, --follow-cmdline-symlinks  follow symlinks on the command line
        \\  -I PATTERN                 do not list entries matching shell PATTERN
        \\  -L, --follow-all-symlinks  follow all symbolic links
        \\      --git=WHEN             when to show git status (valid: always, auto, never)
        \\      --group-directories-first  group directories before files
        \\  -h, --human-readable       with -l, print sizes in human readable format
        \\      --icons=WHEN           when to show icons (valid: always, auto, never)
        \\  -k, --kilobytes            with -l, print sizes in kilobytes
        \\  -l, --long-format          use a long listing format
        \\  -n, --numeric-ids          with -l, show numeric user and group IDs
        \\  -O                         display file flags (no-op)
        \\  -P                         do not follow symbolic links
        \\  -q, --non-printable-as-question  force non-printable characters as '?'
        \\  -o, --omit-group           like -l, but do not print the group
        \\  -1, --one-per-line         list one file per line
        \\  -p, --append-slash-dirs    write a slash (/) after each directory name
        \\  -R, --recursive            list subdirectories recursively
        \\  -r, --reverse-sort         reverse order while sorting
        \\  -s, --show-blocks          display number of filesystem blocks
        \\  -i, --show-inodes          print the index number of each file
        \\  -S, --sort-by-size         sort by file size, largest first
        \\  -t, --sort-by-time         sort by modification time, newest first
        \\  -T, --full-time            with -l, show complete time with seconds
        \\      --test-icons           test Nerd Font icon rendering
        \\      --time-style=STYLE     time/date format (valid: default, relative, iso, long-iso)
        \\  -u, --use-atime            use access time instead of modification time
        \\  -U                         do not sort; list entries in directory order
        \\  -v                         natural sort of version numbers within text
        \\  -V, --version              output version information and exit
        \\  -w COLS                    set output width to COLS columns
        \\  -W                         display whiteout entries (no-op)
        \\  -x, --columns-across       multi-column output sorted across rows
        \\  -X                         sort alphabetically by entry extension
        \\  -y                         sort by name (default behavior)
        \\  -@                         display extended attributes (no-op)
        \\  -%                         display SIP protection (no-op)
        \\      --help                 display this help and exit
        \\
        \\Examples:
        \\  ls           List files in the current directory
        \\  ls -la       List all files in long format
        \\  ls -lh       List files with human-readable sizes
        \\  ls -t        List files sorted by modification time
        \\  ls --icons=always --color=always  List with colors and icons
        \\  ls --git=never  List without git status indicators
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

/// Convert a Zig error to a POSIX-style error string.
fn posixErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.InputOutput => "Input/output error",
        else => @errorName(err),
    };
}

/// List a directory or file, handling both files and directories appropriately
/// Errors are printed but don't stop execution except for BrokenPipe
fn listDirectory(path: []const u8, writer: anytype, stderr_writer: anytype, options: LsOptions, allocator: std.mem.Allocator, git_context: ?*types.GitContext) anyerror!void {
    // Initialize style based on color mode
    const style = display.initStyle(allocator, writer, options.color_mode) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "ls", "failed to initialize styling: {s}", .{posixErrorName(err)});
        return err;
    };

    // Get stat info to determine if it's a file or directory
    const stat = common.file.FileInfo.stat(path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "ls", "{s}: {s}", .{ path, posixErrorName(err) });
        return err;
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
        if (options.show_git_status and git_context != null) {
            entry.git_status = git_context.?.getFileStatus(entry.name) orelse .not_in_repo;
        }

        if (options.long_format) {
            try formatter.printLongFormatEntry(allocator, entry, writer, options, style);
        } else {
            try display.printEntryName(entry, writer, style, options);
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

            try formatter.printLongFormatEntry(allocator, entry, writer, options, style);
        } else {
            try writer.print("{s}\n", .{path});
        }
        return;
    }

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "ls", "{s}: {s}", .{ path, posixErrorName(err) });
        return err;
    };
    defer dir.close();

    // Call the shared implementation
    try listDirectoryImpl(dir, path, writer, stderr_writer, options, allocator, style, git_context);
}

/// Set up visited filesystem ID tracking for secure cycle detection in recursive mode
fn listDirectoryImpl(dir: std.fs.Dir, path: []const u8, writer: anytype, stderr_writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype, git_context: ?*types.GitContext) anyerror!void {
    // For recursive listing with symlinks, we need to track visited (device, inode) pairs for security
    var visited_fs_ids = common.directory.FileSystemIdSet.initContext(allocator, common.directory.FileSystemId.Context{});
    defer visited_fs_ids.deinit();

    try core.listDirectoryImplWithVisited(dir, path, writer, stderr_writer, options, allocator, style, &visited_fs_ids, git_context);
}

/// Determine whether to show git status indicators.
/// Priority: explicit --git=WHEN > DisplayConfig > auto-detect .git dir
fn resolveGitMode(git_arg: ?[]const u8, disp: common.display_config.DisplayConfig) bool {
    if (git_arg) |value| {
        if (std.mem.eql(u8, value, "always")) return true;
        if (std.mem.eql(u8, value, "never")) return false;
        // "auto" falls through to auto-detect
    }

    // No flag or --git=auto: git status is a visual enhancement,
    // disabled when icons are off
    if (disp.icons == .off) return false;

    // Auto-detect: enable if we're inside a git repo
    return isInGitRepo();
}

/// Check if the current directory is inside a git repository
/// by walking up looking for a .git directory or file.
fn isInGitRepo() bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&buf) catch return false;
    var path: []const u8 = cwd;
    while (true) {
        // Check for .git (directory or file for worktrees)
        var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
        defer dir.close();
        if (dir.statFile(".git")) |_| {
            return true;
        } else |_| {}

        // Move to parent
        const parent = std.fs.path.dirname(path) orelse return false;
        if (std.mem.eql(u8, parent, path)) return false;
        path = parent;
    }
}

// Include security tests
test {
    _ = @import("security_test.zig");
}

// Import all module tests for comprehensive test coverage
test {
    _ = @import("display.zig");
    _ = @import("entry_collector.zig");
    _ = @import("formatter.zig");
    _ = @import("sorter.zig");
    _ = @import("test_utils.zig");
    _ = @import("types.zig");
    _ = @import("integration_test.zig");
}

// Test the refactored lsMain function with writer parameter
test "lsMain help works with different writers" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = LsArgs{
        .help = true,
        .positionals = &.{},
    };

    _ = try lsMain(stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator), args, testing.allocator);

    // Should contain help text
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: ls") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--help") != null);
    // stderr should be empty for help
    try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "lsMain version works with different writers" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = LsArgs{
        .version = true,
        .positionals = &.{},
    };

    _ = try lsMain(stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator), args, testing.allocator);

    // Should contain version info
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "ls (") != null);
    // stderr should be empty for version
    try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "runLs function works with separate writers" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = LsArgs{
        .help = true,
        .positionals = &.{},
    };

    _ = try runLs(testing.allocator, args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should contain help text in stdout
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: ls") != null);
    // stderr should be empty for help
    try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

// C library functions for environment manipulation in tests
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

test "initStyle with auto color mode disables colors when stdout is not a TTY" {
    // When --color=auto is passed and stdout is not a TTY (as in tests and
    // pipes), the style's color_mode must be .none so ANSI codes don't leak.
    // This test exercises the production code path through display.initStyle.

    // Save original env state and ensure TERM is set so ColorMode.detect()
    // returns a non-.none value.  Without this, detect() may return .none
    // if TERM happens to be unset, masking the bug.
    const saved_term = std.posix.getenv("TERM");
    const saved_no_color = std.posix.getenv("NO_COLOR");
    _ = setenv("TERM", "xterm-256color", 1);
    _ = unsetenv("NO_COLOR");
    defer {
        if (saved_term) |v| {
            _ = setenv("TERM", v.ptr, 1);
        } else {
            _ = unsetenv("TERM");
        }
        if (saved_no_color) |v| {
            _ = setenv("NO_COLOR", v.ptr, 1);
        }
    }

    var buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buf.deinit(testing.allocator);

    const style = try display.initStyle(testing.allocator, buf.writer(testing.allocator), .auto);

    // In a test runner, stdout is never a TTY.  Correct behavior: .auto
    // should resolve to .none so no escape codes are emitted.
    try testing.expectEqual(
        common.style.Style(std.ArrayList(u8).Writer).ColorMode.none,
        style.color_mode,
    );
}
