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
        .human_readable = .{
            .short = 'h',
            .desc = "With -l, print sizes in human readable format",
        },
        .kilobytes = .{ .short = 'k', .desc = "With -l, print sizes in kilobytes" },
        .one_per_line = .{ .short = '1', .desc = "List one file per line" },
        .directory = .{ .short = 'd', .desc = "List directories themselves, not their contents" },
        .file_type_indicators = .{
            .short = 'F',
            .desc = "Append indicator (one of */=>@|) to entries",
        },
        .append_slash_dirs = .{
            .short = 'p',
            .desc = "Write a slash (/) after each directory name",
        },
        .non_printable_as_question = .{
            .short = 'q',
            .desc = "Force non-printable characters to be written as '?'",
        },
        .omit_owner = .{ .short = 'g', .desc = "Like -l, but do not print the owner" },
        .omit_group = .{ .short = 'o', .desc = "Like -l, but do not print the group" },
        .show_inodes = .{ .short = 'i', .desc = "Print the index number of each file" },
        .comma_format = .{
            .short = 'm',
            .desc = "Fill width with a comma separated list of entries",
        },
        .numeric_ids = .{ .short = 'n', .desc = "With -l, show numeric user and group IDs" },
        .recursive = .{ .short = 'R', .desc = "List subdirectories recursively" },
        .sort_by_time = .{ .short = 't', .desc = "Sort by modification time, newest first" },
        .sort_by_size = .{ .short = 'S', .desc = "Sort by file size, largest first" },
        .reverse_sort = .{ .short = 'r', .desc = "Reverse order while sorting" },
        .no_sort = .{
            .short = 'f',
            .desc = "Do not sort; list entries in directory order (implies -a)",
        },
        .show_blocks = .{ .short = 's', .desc = "Display number of filesystem blocks" },
        .use_atime = .{ .short = 'u', .desc = "Use access time instead of modification time" },
        .use_ctime = .{
            .short = 'c',
            .desc = "Use status change time instead of modification time",
        },
        .multi_column = .{ .short = 'C', .desc = "Force multi-column output sorted down columns" },
        .columns_across = .{ .short = 'x', .desc = "Multi-column output sorted across rows" },
        .full_time = .{ .short = 'T', .desc = "With -l, show complete time including seconds" },
        .follow_all_symlinks = .{ .short = 'L', .desc = "Follow all symbolic links" },
        .follow_cmdline_symlinks = .{
            .short = 'H',
            .desc = "Follow symbolic links on the command line",
        },
        .escape_non_printable = .{
            .short = 'b',
            .desc = "Print C-style escape sequences for non-printable characters",
        },
        .hide_backups = .{ .short = 'B', .desc = "Do not list entries ending with ~" },
        .dired = .{ .short = 'D', .desc = "Generate output suitable for Emacs dired mode" },
        .show_acls = .{ .short = 'e', .desc = "Display ACL information in long format" },
        .colorize = .{ .short = 'G', .desc = "Enable colorized output" },
        .ignore_pattern = .{
            .short = 'I',
            .desc = "Do not list entries matching shell PATTERN",
            .value_name = "PATTERN",
        },
        .show_file_flags = .{ .short = 'O', .desc = "Display file flags in long format" },
        .no_follow_symlinks = .{ .short = 'P', .desc = "Do not follow symbolic links" },
        .unsorted = .{ .short = 'U', .desc = "Do not sort; list entries in directory order" },
        .version_sort = .{ .short = 'v', .desc = "Natural sort of version numbers within text" },
        .output_width = .{
            .short = 'w',
            .desc = "Set output width to COLS columns",
            .value_name = "COLS",
        },
        .show_whiteouts = .{ .short = 'W', .desc = "Display whiteout entries" },
        .sort_by_extension = .{ .short = 'X', .desc = "Sort alphabetically by entry extension" },
        .sort_by_name = .{ .short = 'y', .desc = "Sort by name (default behavior)" },
        .show_xattrs = .{ .short = '@', .desc = "Display extended attribute keys and sizes" },
        .show_sip = .{ .short = '%', .desc = "Display SIP protection information" },
        .thousands_grouping = .{
            .short = ',',
            .desc = "Format file sizes with thousands grouping",
        },
        .color = .{
            .short = 0,
            .desc = "When to use colors (valid: always, auto, never)",
            .value_name = "WHEN",
        },
        .group_directories_first = .{ .short = 0, .desc = "Group directories before files" },
        .icons = .{
            .short = 0,
            .desc = "When to show icons (valid: always, auto, never)",
            .value_name = "WHEN",
        },
        .test_icons = .{ .short = 0, .desc = "Show sample icons to test Nerd Font support" },
        .time_style = .{
            .short = 0,
            .desc = "Time/date format (valid: default, relative, iso, long-iso)",
            .value_name = "STYLE",
        },
        .git = .{
            .short = 0,
            .desc = "when to show git status (valid: always, auto, never)",
            .value_name = "WHEN",
        },
    };
};

/// CLI entry point — delegates to utilityMain for arena, arg, writer setup.
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runLs);
}

/// Core ls run function matching the utilityMain contract.
/// Parses args internally, performs ls work, returns exit code.
pub fn runLs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = common.argparse.ArgParser.parse(LsArgs, allocator, args) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr,
            "ls",
            "argument parsing failed: {s}",
            .{common.posixErrorString(err)},
        );
        return @intFromEnum(common.ExitCode.misuse);
    };
    defer allocator.free(parsed.positionals);

    return lsMain(io, stdout, stderr, parsed, allocator);
}

/// Resolved color, icon, and time-style modes derived from args + env.
const ResolvedModes = struct {
    color_mode: ColorMode,
    icon_mode: common.icons.IconMode,
    time_style: TimeStyle,
};

/// Core ls functionality.
/// Returns exit code: 0 for success, 2 for serious errors (e.g. nonexistent path)
fn lsMain(
    io: std.Io,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    args: LsArgs,
    allocator: std.mem.Allocator,
) !u8 {
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

    // Build the consolidated options struct from args + resolved config.
    const options = lsMain_buildOptions(io, stderr_writer, args, allocator, display_config);

    // Initialize GitContext once if git status is requested
    const git_explicit_always = args.git != null and std.mem.eql(u8, args.git.?, "always");
    var git_context: ?types.GitContext = null;
    if (options.show_git_status) {
        git_context = types.GitContext.init(allocator, io, ".");
        if (git_context) |*ctx| {
            ctx.reportInitializationIssues(allocator, stderr_writer, "ls", git_explicit_always);
        }
    }
    defer if (git_context) |*ctx| ctx.deinit();

    const had_error = try lsMain_listOperands(
        io,
        args.positionals,
        writer,
        stderr_writer,
        options,
        allocator,
        if (git_context) |*ctx| ctx else null,
    );

    return if (had_error) 2 else 0;
}

/// Resolve ls-specific color/icon modes and time style from args + config.
fn lsMain_buildOptions_resolveModes(
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    args: LsArgs,
    display_config: common.display_config.DisplayConfig,
    allocator: std.mem.Allocator,
) ResolvedModes {
    std.debug.assert(args.help == false);
    std.debug.assert(args.version == false);
    // Map resolved display config to ls-specific color/icon modes.
    var color_mode: ColorMode = if (display_config.color == .on) .always else .never;
    var icon_mode: common.icons.IconMode = blk: {
        const env_mode = common.icons.getIconModeFromEnv(allocator);
        if (env_mode != .auto) break :blk env_mode;
        break :blk if (display_config.icons == .on) .always else .never;
    };

    // Explicit CLI flags override everything
    if (args.color) |color_arg| {
        const parsed = types.parseColorMode(color_arg) catch {
            common.fatalWithWriter(
                io,
                stderr_writer,
                "ls",
                "invalid argument '{s}' for '--color'\n" ++
                    "Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'",
                .{color_arg},
            );
        };
        color_mode = parsed;
    }
    // -G: macOS-style enable colorized output (equivalent to --color=auto)
    if (args.colorize) {
        color_mode = .auto;
    }
    if (args.icons) |icons_arg| {
        icon_mode = std.meta.stringToEnum(common.icons.IconMode, icons_arg) orelse {
            common.fatalWithWriter(
                io,
                stderr_writer,
                "ls",
                "invalid argument '{s}' for '--icons'\n" ++
                    "Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'",
                .{icons_arg},
            );
        };
    }

    lsMain_buildOptions_validateGit(io, stderr_writer, args);

    const time_style = lsMain_buildOptions_resolveTimeStyle(io, stderr_writer, args);

    return ResolvedModes{
        .color_mode = color_mode,
        .icon_mode = icon_mode,
        .time_style = time_style,
    };
}

/// Validate the --git argument, exiting fatally on an invalid value.
fn lsMain_buildOptions_validateGit(io: std.Io, stderr_writer: *std.Io.Writer, args: LsArgs) void {
    std.debug.assert(args.help == false);
    std.debug.assert(args.version == false);
    if (args.git) |git_arg| {
        if (!std.mem.eql(u8, git_arg, "always") and
            !std.mem.eql(u8, git_arg, "auto") and
            !std.mem.eql(u8, git_arg, "never"))
        {
            common.fatalWithWriter(
                io,
                stderr_writer,
                "ls",
                "invalid argument '{s}' for '--git'\n" ++
                    "Valid arguments are:\n  - 'always'\n  - 'auto'\n  - 'never'",
                .{git_arg},
            );
        }
    }
}

/// Resolve the time style from --time-style, -h, and -T, exiting on error.
fn lsMain_buildOptions_resolveTimeStyle(
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    args: LsArgs,
) TimeStyle {
    std.debug.assert(args.help == false);
    std.debug.assert(args.version == false);
    // Parse time style
    var time_style = TimeStyle.default;
    if (args.time_style) |time_style_arg| {
        time_style = types.parseTimeStyle(time_style_arg) catch {
            common.fatalWithWriter(
                io,
                stderr_writer,
                "ls",
                "invalid argument '{s}' for '--time-style'\n" ++
                    "Valid arguments are:\n  - 'default'\n  - 'relative'\n" ++
                    "  - 'iso'\n  - 'long-iso'",
                .{time_style_arg},
            );
        };
    } else if (args.human_readable) {
        time_style = .relative;
    }

    // -T overrides time style to full (seconds + year)
    if (args.full_time) {
        time_style = .full;
    }

    return time_style;
}

/// Build the consolidated LsOptions from parsed args + resolved config.
fn lsMain_buildOptions(
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    args: LsArgs,
    allocator: std.mem.Allocator,
    display_config: common.display_config.DisplayConfig,
) LsOptions {
    const modes = lsMain_buildOptions_resolveModes(
        io,
        stderr_writer,
        args,
        display_config,
        allocator,
    );

    // Detect terminal status for icons and colors
    const is_terminal = std.c.isatty(std.Io.File.stdout().handle) != 0;

    // Create options struct by consolidating all parsed arguments
    return LsOptions{
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
        .color_mode = modes.color_mode,
        .group_directories_first = args.group_directories_first,
        .show_inodes = args.show_inodes,
        .numeric_ids = args.numeric_ids,
        .comma_format = args.comma_format,
        .icon_mode = modes.icon_mode,
        .time_style = modes.time_style,
        .show_git_status = resolveGitMode(io, args.git, display_config),
        .is_terminal = is_terminal,
        .no_sort = args.no_sort or args.unsorted,
        .show_blocks = args.show_blocks,
        .use_atime = args.use_atime,
        .use_ctime = args.use_ctime,
        .multi_column = args.multi_column,
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
}

/// List all path operands, returning whether any listing error occurred.
/// Mirrors GNU separation: file operands first (no headers), then
/// directory operands with "dir:" headers.
fn lsMain_listOperands(
    io: std.Io,
    paths: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: LsOptions,
    allocator: std.mem.Allocator,
    git_context: ?*types.GitContext,
) !bool {
    var had_error = false;

    if (paths.len == 0) {
        // No paths specified, list current directory
        try listDirectory(io, ".", writer, stderr_writer, options, allocator, git_context);
        return had_error;
    } else if (paths.len == 1) {
        // Single path: no headers needed
        listDirectory(io, paths[0], writer, stderr_writer, options, allocator, git_context) catch {
            had_error = true;
        };
        return had_error;
    }

    std.debug.assert(paths.len > 1);
    std.debug.assert(!had_error);
    return lsMain_listOperandGroups(
        io,
        paths,
        writer,
        stderr_writer,
        options,
        allocator,
        git_context,
    );
}

/// List two or more operands with GNU's grouping:
/// 1. Operands that cannot be stat'd get a diagnostic and nothing else.
/// 2. Non-directory operands print without headers.
/// 3. Directory operands print with "dir:" headers.
/// Each listing group sorts on its own with the same criteria the directory
/// listing uses, so -t/-S/-r/-U apply to the operands themselves.
fn lsMain_listOperandGroups(
    io: std.Io,
    paths: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: LsOptions,
    allocator: std.mem.Allocator,
    git_context: ?*types.GitContext,
) !bool {
    std.debug.assert(paths.len > 1);

    var files: std.ArrayList(Entry) = .empty;
    defer files.deinit(allocator);
    var dirs: std.ArrayList(Entry) = .empty;
    defer dirs.deinit(allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(allocator);

    try lsMain_partitionOperands(io, paths, options, allocator, &files, &dirs, &failed);
    std.debug.assert(files.items.len + dirs.items.len + failed.items.len == paths.len);
    lsMain_sortOperands(files.items, options);
    lsMain_sortOperands(dirs.items, options);

    var had_error = false;

    // GNU reports an operand it cannot stat and then drops it from every
    // listing section, so nothing about it reaches stdout. listDirectory
    // re-stats the path, which keeps the diagnostic in one place and only
    // costs a syscall on this error path.
    for (failed.items) |path| {
        listDirectory(io, path, writer, stderr_writer, options, allocator, git_context) catch {
            had_error = true;
        };
    }

    // File operands: no headers.
    for (files.items) |entry| {
        listDirectory(
            io,
            entry.name,
            writer,
            stderr_writer,
            options,
            allocator,
            git_context,
        ) catch {
            had_error = true;
        };
    }

    if (try lsMain_emitDirectoryOperands(
        io,
        dirs.items,
        files.items.len > 0,
        writer,
        stderr_writer,
        options,
        allocator,
        git_context,
    )) {
        had_error = true;
    }

    return had_error;
}

/// Sort one operand group the way directory contents are sorted, except that
/// -r reverses the sorted slice instead of negating the comparator.
///
/// sorter.compareEntries implements -r as `!result`, so two entries with
/// equal sort keys compare less-than in BOTH directions. A directory cannot
/// hold two entries with the same name, but an operand list can repeat one
/// (`ls -r f f`), and std.sort asserts on that inconsistency in debug builds.
/// Reversing the stably-sorted slice keeps every ordering the comparator
/// defines and is well-defined for duplicates.
fn lsMain_sortOperands(entries: []Entry, options: LsOptions) void {
    // -f/-U keep argv order, which means -r has nothing to reverse either.
    if (options.no_sort) return;
    std.debug.assert(!options.no_sort);

    var ascending = options;
    ascending.reverse_sort = false;
    core.sortEntriesFromOptions(entries, ascending);
    if (options.reverse_sort) std.mem.reverse(Entry, entries);
}

/// Emit each directory operand with its "dir:" header, blank-line separated.
/// `files_printed` says whether a file-operand section already went out, which
/// decides if the first directory section needs a leading blank line.
/// Returns whether any directory failed to list.
fn lsMain_emitDirectoryOperands(
    io: std.Io,
    dirs: []const Entry,
    files_printed: bool,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: LsOptions,
    allocator: std.mem.Allocator,
    git_context: ?*types.GitContext,
) !bool {
    var had_error = false;

    for (dirs, 0..) |entry, dir_idx| {
        // Only operands that stat'd as directories reach this group: an
        // operand that failed to stat is diagnosed by the caller, and with -d
        // a directory operand is listed as an ordinary entry instead.
        std.debug.assert(entry.kind == .directory);
        std.debug.assert(entry.stat != null);
        if (files_printed or dir_idx > 0) try writer.writeAll("\n");
        try writer.print("{s}:\n", .{entry.name});
        listDirectory(
            io,
            entry.name,
            writer,
            stderr_writer,
            options,
            allocator,
            git_context,
        ) catch {
            had_error = true;
        };
    }

    return had_error;
}

/// Split operands into a non-directory group, a directory group, and the
/// operands that cannot be stat'd at all, keeping argv order within each so
/// the caller can sort the two listing groups.
fn lsMain_partitionOperands(
    io: std.Io,
    paths: []const []const u8,
    options: LsOptions,
    allocator: std.mem.Allocator,
    files: *std.ArrayList(Entry),
    dirs: *std.ArrayList(Entry),
    failed: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(paths.len > 1);
    std.debug.assert(files.items.len == 0);
    std.debug.assert(dirs.items.len == 0);
    std.debug.assert(failed.items.len == 0);

    for (paths) |path| {
        // A missing or inaccessible operand belongs in neither listing group:
        // GNU prints only the diagnostic for it, so treating it as a directory
        // here would emit a bogus "path:" header on stdout first.
        const stat = common.file.FileInfo.stat(io, path) catch {
            try failed.append(allocator, path);
            continue;
        };
        const entry = Entry{
            .name = path,
            .kind = stat.kind,
            .stat = stat,
            .symlink_target = null,
        };
        // -d lists a directory operand as an ordinary entry, so it sorts and
        // prints with the files and never gets a "dir:" header.
        if (stat.kind == .directory and !options.directory) {
            try dirs.append(allocator, entry);
        } else {
            try files.append(allocator, entry);
        }
    }

    // Every operand lands in exactly one group.
    std.debug.assert(files.items.len + dirs.items.len + failed.items.len == paths.len);
    std.debug.assert(failed.items.len <= paths.len);
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

    try writer.writeAll(
        "If you can see the following icons correctly, your terminal supports Nerd Fonts:\n\n",
    );

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
    try writer.writeAll(
        "  ls --icons=auto                      " ++
            "# Show icons in terminal, hide in pipes (default)\n",
    );
    try writer.writeAll("  ls --icons=always                    # Always show icons\n");
    try writer.writeAll("  ls --icons=never                     # Never show icons\n");
    try writer.writeAll("  export LS_ICONS=auto                 # Set default mode\n");
    try writer.writeAll("  echo 'export LS_ICONS=auto' >> ~/.zshrc  # Permanent setting\n");
    try writer.writeAll("\nIf icons appear as boxes or question marks, you need to:\n");
    try writer.writeAll("  1. Install a Nerd Font (https://www.nerdfonts.com/)\n");
    try writer.writeAll("  2. Configure your terminal to use the Nerd Font\n");
    try writer.writeAll("  3. Restart your terminal\n");
}

/// List a directory or file, handling both files and directories appropriately.
/// Errors are printed but don't stop execution except for BrokenPipe.
fn listDirectory(
    io: std.Io,
    path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    git_context: ?*types.GitContext,
) anyerror!void {
    // Initialize style based on color mode
    const style = display.initStyle(allocator, writer, options.color_mode) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "failed to initialize styling: {s}",
            .{common.posixErrorString(err)},
        );
        return err;
    };

    // Get stat info to determine if it's a file or directory.
    // GNU ls quotes the operand here (file_failure + quoteaf,
    // "cannot access 'x': reason"); match placement.
    const stat = common.file.FileInfo.stat(io, path) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "'{s}': {s}",
            .{ path, common.posixErrorString(err) },
        );
        return err;
    };

    // If it's a file (not a directory), just print the file entry
    if (stat.kind != .directory) {
        try listSingleFileEntry(io, path, writer, options, allocator, git_context, style, stat);
        return;
    }

    // If -d is specified, just list the directory itself
    if (options.directory) {
        try listDirectoryItself(path, writer, options, allocator, style, stat);
        return;
    }

    // GNU ls quotes the operand here (file_failure + quoteaf,
    // "cannot open directory 'x': reason"); match placement.
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "'{s}': {s}",
            .{ path, common.posixErrorString(err) },
        );
        return err;
    };
    defer dir.close(io);

    // Call the shared implementation
    try listDirectoryImpl(
        io,
        dir,
        path,
        writer,
        stderr_writer,
        options,
        allocator,
        style,
        git_context,
    );
}

/// Print a single non-directory operand as one entry, with optional git status.
fn listSingleFileEntry(
    io: std.Io,
    path: []const u8,
    writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    git_context: ?*types.GitContext,
    style: anytype,
    stat: common.file.FileInfo,
) anyerror!void {
    // GNU echoes a non-directory operand exactly as written, so the operand
    // keeps its directory component here instead of being reduced to a
    // basename.
    var entry = Entry{
        .name = path,
        .kind = stat.kind,
        .stat = stat,
        .symlink_target = null,
    };

    // Get Git status for the file if requested
    if (options.show_git_status and git_context != null) {
        entry.git_status = git_context.?.getFileStatus(io, entry.name) orelse .not_in_repo;
    }

    if (options.long_format) {
        try formatter.printLongFormatEntry(allocator, entry, writer, options, style);
    } else {
        try display.printEntryName(entry, writer, style, options);
    }
    try writer.writeAll("\n");
}

/// Print just the directory operand itself (the -d case), not its contents.
fn listDirectoryItself(
    path: []const u8,
    writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    stat: common.file.FileInfo,
) anyerror!void {
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
}

/// Set up visited filesystem ID tracking for secure cycle detection in recursive mode
fn listDirectoryImpl(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    git_context: ?*types.GitContext,
) anyerror!void {
    var visited_fs_ids = common.directory.FileSystemIdSet.initContext(
        allocator,
        common.directory.FileSystemId.Context{},
    );
    defer visited_fs_ids.deinit();

    try core.listDirectoryImplWithVisited(
        io,
        dir,
        path,
        writer,
        stderr_writer,
        options,
        allocator,
        style,
        &visited_fs_ids,
        git_context,
    );
}

/// Determine whether to show git status indicators.
fn resolveGitMode(
    io: std.Io,
    git_arg: ?[]const u8,
    disp: common.display_config.DisplayConfig,
) bool {
    if (git_arg) |value| {
        if (std.mem.eql(u8, value, "always")) return true;
        if (std.mem.eql(u8, value, "never")) return false;
        // "auto" falls through to auto-detect
    }

    // No flag or --git=auto: git status is a visual enhancement,
    // disabled when icons are off
    if (disp.icons == .off) return false;

    // Auto-detect: enable if we're inside a git repo
    return isInGitRepo(io);
}

/// Check if the current directory is inside a git repository
/// by walking up looking for a .git directory or file.
fn isInGitRepo(io: std.Io) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &buf) catch return false;
    var path: []const u8 = buf[0..cwd_len];
    // Bounded by the absolute path's component count: each iteration strips one
    // component (path = parent), and dirname's root fixed-point (parent == path)
    // returns false, so the loop always terminates at the filesystem root.
    while (true) { // tiger:allow:unbounded-loop terminates at filesystem root
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
        defer dir.close(io);
        if (dir.statFile(io, ".git", .{})) |_| {
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
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = LsArgs{
        .help = true,
        .positionals = &.{},
    };

    _ = try lsMain(testing.io, &stdout_aw.writer, &stderr_aw.writer, args, testing.allocator);

    // Should contain help text
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: ls") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--help") != null);
    // stderr should be empty for help
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "lsMain version works with different writers" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = LsArgs{
        .version = true,
        .positionals = &.{},
    };

    _ = try lsMain(testing.io, &stdout_aw.writer, &stderr_aw.writer, args, testing.allocator);

    // Should contain version info
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "ls (") != null);
    // stderr should be empty for version
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "runLs function works with separate writers" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    _ = try runLs(testing.allocator, testing.io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should contain help text in stdout
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: ls") != null);
    // stderr should be empty for help
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "initStyle with auto color mode disables colors when stdout is not a TTY" {
    // When --color=auto is passed and stdout is not a TTY (as in tests and
    // pipes), the style's color_mode must be .none so ANSI codes don't leak.
    //
    // The environment is staged through the test-only overlay in
    // common.env; libc unsetenv would compact `environ` in place and
    // corrupt the view Zig 0.16 captures at startup, which deadlocks the
    // test runner's failure path (issue #95).
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "NO_COLOR", .value = null },
    };
    common.env.test_overrides = &staged;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const style = try display.initStyle(testing.allocator, &stdout_aw.writer, .auto);

    // In a test runner, stdout is never a TTY. Correct behavior: .auto
    // should resolve to .none so no escape codes are emitted.
    try testing.expectEqual(
        common.style.Style(*std.Io.Writer).ColorMode.none,
        style.color_mode,
    );
}

// ============================================================
// Issue #103: non-directory operands are mishandled two ways:
// (a) printed as basename instead of the operand exactly as given
//     (listSingleFileEntry), and (b) never sorted -- -t/-S/-r and the
// default name sort are ignored for the operand LIST itself
// (lsMain_listOperands), even though directory CONTENTS sort fine.
//
// The exact-stdout assertions below rely on the test process's REAL
// stdout not being a TTY: display_config.resolve keys color off
// env.isTty(std.Io.File.stdout().handle), and icons off
// options.is_terminal -- neither looks at the Allocating writer passed
// to runLs here. This holds under `zig build test` (the build runner
// pipes the test binary's stdout) and matches the existing test above;
// it will only surface as color/icon noise if this binary is ever run
// directly from an interactive terminal.
// ============================================================

/// Change the process cwd to `tmp_dir` for the duration of a test and
/// return a handle to the original cwd. lsMain resolves relative operands
/// against the process cwd (std.Io.Dir.cwd()), not an injectable directory,
/// so these operand-echo/operand-sort tests must actually chdir -- there is
/// no way to drive that code path with a relative operand otherwise.
fn testChdirToTmp(io: std.Io, tmp_dir: *std.testing.TmpDir) !std.Io.Dir {
    var saved_cwd_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    errdefer saved_cwd_dir.close(io);

    const tmp_abs = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);
    std.debug.assert(tmp_abs.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(tmp_abs));
    try std.Io.Threaded.chdir(tmp_abs);

    return saved_cwd_dir;
}

/// Restore the process cwd saved by `testChdirToTmp` and close the handle.
/// Uses fchdir (via setCurrentDir on an open handle) rather than getcwd, so
/// it keeps working in sandboxes where getcwd is unavailable.
fn testRestoreCwd(io: std.Io, saved_cwd_dir: *std.Io.Dir) void {
    std.debug.assert(saved_cwd_dir.handle >= 0);
    std.debug.assert(saved_cwd_dir.handle != std.posix.AT.FDCWD);
    // A silent failure here leaves every later test in this binary running
    // with cwd inside a temp dir that TmpDir.cleanup then deletes out from
    // under it, producing cascading failures misattributed to unrelated
    // tests. setCurrentDir on a still-open fd should not fail in practice,
    // so make a failure loud instead of absorbing it.
    std.process.setCurrentDir(io, saved_cwd_dir.*) catch @panic("failed to restore test cwd");
    saved_cwd_dir.close(io);
}

/// Overlay pinning every env var that DisplayConfig.resolve or
/// getIconModeFromEnv consult, unset for the duration of a test.
///
/// The header comment above only documented the non-TTY-stdout assumption,
/// but display_config.zig also honors VIBEUTILS_STYLE/VIBEUTILS_COLOR/
/// VIBEUTILS_ICONS, and icons.zig separately honors LS_ICONS -- and
/// common.env.getEnv falls through to the REAL process environment outside
/// this overlay. A developer running with e.g. VIBEUTILS_STYLE=always (or
/// LS_ICONS=always) exported would flip icons on, which makes
/// resolveGitMode fall through to isInGitRepo -- true, because
/// testing.tmpDir nests under .zig-cache/tmp INSIDE this git worktree --
/// and every exact-stdout assertion below would then fail on icon/git
/// noise, misread as "the bug doesn't reproduce." NO_COLOR and TERM are
/// pinned too so color detection is deterministic regardless of the
/// ambient shell.
const test_env_overrides = [_]common.env.Override{
    .{ .key = "VIBEUTILS_STYLE", .value = null },
    .{ .key = "VIBEUTILS_COLOR", .value = null },
    .{ .key = "VIBEUTILS_ICONS", .value = null },
    .{ .key = "LS_ICONS", .value = null },
    .{ .key = "NO_COLOR", .value = null },
    .{ .key = "TERM", .value = null },
};

/// Stage `test_env_overrides` and return the previous overlay so the
/// caller can `defer common.env.test_overrides = saved` to restore it.
fn testStageDisplayEnvOverrides() []const common.env.Override {
    const saved = common.env.test_overrides;
    common.env.test_overrides = &test_env_overrides;
    return saved;
}

test "ls prints a subdirectory operand exactly as given, not its basename (short format)" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "subdir");
    {
        const file = try tmp_dir.dir.createFile(io, "subdir/file.txt", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"subdir/file.txt"};
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // GNU echoes the operand verbatim ("subdir/file.txt"), not the
    // basename ("file.txt"). basename() throwing away the directory
    // component is exactly the bug this guards.
    try testing.expectEqualStrings("subdir/file.txt\n", stdout_aw.writer.buffered());
}

test "ls -l ends a subdirectory operand's line with the full operand path" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "subdir");
    {
        const file = try tmp_dir.dir.createFile(io, "subdir/file.txt", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-l", "subdir/file.txt" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    const output = stdout_aw.writer.buffered();
    // The name field of a long-format line is the LAST field GNU emits, so
    // the whole line must end with the full operand, not just "file.txt".
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, output, "\n"), "subdir/file.txt"));
    try testing.expect(!std.mem.endsWith(u8, std.mem.trimEnd(u8, output, "\n"), " file.txt"));
}

test "ls -1t sorts distinct-mtime file operands newest first, ignoring argv order" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const old_ns: i128 = 1_000_000_000 * 1_000_000_000; // 2001-09-09T01:46:40Z
    const new_ns: i128 = old_ns + 100 * std.time.ns_per_s;

    // Names are chosen so name order ("a_older" < "z_newer") DISAGREES with
    // time order (z_newer is the newer file). A fix that collects operands
    // but always falls back to the name comparator -- ignoring
    // options.sort_by_time entirely -- would still pass an f_old/f_new
    // style fixture (name order there happens to match time order); it
    // must fail this one.
    {
        const file = try tmp_dir.dir.createFile(io, "a_older", .{});
        defer file.close(io);
        try file.setTimestamps(io, .{
            .access_timestamp = .{ .new = .{ .nanoseconds = old_ns } },
            .modify_timestamp = .{ .new = .{ .nanoseconds = old_ns } },
        });
    }
    {
        const file = try tmp_dir.dir.createFile(io, "z_newer", .{});
        defer file.close(io);
        try file.setTimestamps(io, .{
            .access_timestamp = .{ .new = .{ .nanoseconds = new_ns } },
            .modify_timestamp = .{ .new = .{ .nanoseconds = new_ns } },
        });
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // argv order is older, newer -- GNU still puts the newer file first
    // with -t, even though that disagrees with both argv AND name order.
    const args = [_][]const u8{ "-1", "-t", "a_older", "z_newer" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("z_newer\na_older\n", stdout_aw.writer.buffered());
}

test "ls -1S sorts distinct-size file operands largest first, ignoring argv order" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Names are chosen so name order ("a_small" < "z_big") DISAGREES with
    // size order (z_big is the bigger file). A fix that collects operands
    // but always falls back to the name comparator -- ignoring
    // options.sort_by_size entirely -- would still pass an f_small/f_big
    // style fixture (name order there happens to match size order); it
    // must fail this one.
    {
        const file = try tmp_dir.dir.createFile(io, "a_small", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "a");
    }
    {
        const file = try tmp_dir.dir.createFile(io, "z_big", .{});
        defer file.close(io);
        const data = [_]u8{'X'} ** 1000;
        try file.writeStreamingAll(io, &data);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // argv order is small, big -- GNU still puts the bigger file first
    // with -S, even though that disagrees with both argv AND name order.
    const args = [_][]const u8{ "-1", "-S", "a_small", "z_big" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("z_big\na_small\n", stdout_aw.writer.buffered());
}

test "ls -1 sorts file operands by name by default, ignoring argv order" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const file = try tmp_dir.dir.createFile(io, "z_file", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "a_file", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // argv order is z_file, a_file -- POSIX default is name order.
    const args = [_][]const u8{ "-1", "z_file", "a_file" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("a_file\nz_file\n", stdout_aw.writer.buffered());
}

// NOTE for the RED-gate check: unlike the other tests in this block, this
// one is EXPECTED TO PASS on today's (buggy) code -- the current bug is
// "operands are never sorted at all," which happens to already match -U's
// correct behavior (preserve argv order). It stays green through the fix
// too; it exists to catch a fix that over-sorts and sweeps -U in with -t/
// -S/default, not to pin the bug itself.
test "ls -1U preserves argv order for file operands (guards against over-sorting)" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const file = try tmp_dir.dir.createFile(io, "z_file", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "a_file", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -U disables sorting entirely, so argv order (z_file, a_file) must
    // survive even though it disagrees with the default name sort.
    const args = [_][]const u8{ "-1", "-U", "z_file", "a_file" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("z_file\na_file\n", stdout_aw.writer.buffered());
}

test "ls -1r reverses the default name sort for file operands" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const file = try tmp_dir.dir.createFile(io, "big", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "small", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Default name order is big, small ('b' < 's'); -r must reverse THAT
    // sorted order, not just the (coincidentally identical) argv order.
    const args = [_][]const u8{ "-1", "-r", "big", "small" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("small\nbig\n", stdout_aw.writer.buffered());
}

test "ls sorts directory operands by name too, so a_dir's header comes before b_dir's" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "b_dir");
    try tmp_dir.dir.createDirPath(io, "a_dir");
    {
        const file = try tmp_dir.dir.createFile(io, "a_dir/x", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "b_dir/y", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // argv order is b_dir, a_dir -- GNU still headers a_dir first.
    const args = [_][]const u8{ "b_dir", "a_dir" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("a_dir:\nx\n\nb_dir:\ny\n", stdout_aw.writer.buffered());
}

// Mixed operand case: at least one file operand AND at least one directory
// operand together. The Bug B fix restructures lsMain_listOperands, and
// file_count (which drives the blank-line separator between the file
// section and the directory section) has to be re-derived from the new
// file group. None of the tests above exercise that: the directory-only
// test above has zero file operands, so the `file_count > 0` branch of
// the separator condition is never taken. This pins the full exact output
// of a mixed invocation so a separator regression (dropped or duplicated
// blank line) or an operand-ordering regression (directory section ahead
// of the file section) fails here even if every single-group test passes.
//
// NOTE for the RED-gate check: like the -1U test above, this one is
// EXPECTED TO PASS on today's (buggy) code -- with exactly one file
// operand and one directory operand, Bug A/B have nothing to reorder
// (a single-element "sort" is a no-op either way), so the existing
// two-pass file_count/dir_idx separator logic already happens to match
// GNU here. It exists purely to catch the Bug B restructure regressing
// that separator, not to pin the bug itself.
test "ls mixed operands: files first, one blank line before the dir section" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "a_dir");
    {
        const file = try tmp_dir.dir.createFile(io, "a_dir/x", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir.createFile(io, "z_file", .{});
        file.close(io);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // argv order is z_file, a_dir -- GNU lists file operands first (no
    // header), then a single blank line, then the directory section.
    const args = [_][]const u8{ "-1", "z_file", "a_dir" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("z_file\n\na_dir:\nx\n", stdout_aw.writer.buffered());
}
