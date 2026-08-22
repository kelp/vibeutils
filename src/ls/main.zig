//! Main entry point for the ls command with file listing functionality
const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
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
        .show_acls = .{
            .short = 'e',
            .desc = "Display ACL information after each long-format line",
        },
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
        return @intFromEnum(common.ExitCode.serious_error);
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
    var options = lsMain_buildOptions(io, stderr_writer, args, allocator, display_config);

    var ls_colors_table: ?common.ls_colors.Table = null;
    defer if (ls_colors_table) |*table| table.deinit(allocator);
    try lsMain_loadLsColors(allocator, stderr_writer, &options, &ls_colors_table);

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

/// True when this invocation would emit color (so LS_COLORS is worth parsing).
fn lsMain_colorWillEmit(color_mode: ColorMode) bool {
    std.debug.assert(@intFromEnum(color_mode) <= @intFromEnum(ColorMode.never));
    if (color_mode == .never) return false;
    if (common.env.getEnv("NO_COLOR") != null) return false;
    if (color_mode == .auto) {
        if (std.c.isatty(std.Io.File.stdout().handle) == 0) return false;
        if (common.env.getEnv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) return false;
        }
    }
    std.debug.assert(color_mode != .never);
    return true;
}

fn lsMain_reportLsColorsError(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    report: common.ls_colors.ParseReport,
) void {
    std.debug.assert(@intFromPtr(stderr_writer) != 0);
    std.debug.assert(@intFromPtr(allocator.ptr) != 0);
    if (report.unrecognized_prefix) |prefix| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "unrecognized prefix: {s}",
            .{&prefix},
        );
    }
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "ls",
        "unparsable value for LS_COLORS environment variable",
        .{},
    );
}

/// Parse LS_COLORS when color is on. Invalid values disable color for this run.
fn lsMain_loadLsColors(
    allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
    options: *LsOptions,
    table_slot: *?common.ls_colors.Table,
) !void {
    std.debug.assert(table_slot.* == null);
    std.debug.assert(options.ls_colors == null);
    if (!lsMain_colorWillEmit(options.color_mode)) return;
    const text = common.env.getEnv("LS_COLORS") orelse return;
    if (text.len == 0) return;
    var report = common.ls_colors.ParseReport{};
    const parsed = common.ls_colors.parseWithReport(allocator, text, &report) catch |err| {
        switch (err) {
            error.Unparsable => {
                lsMain_reportLsColorsError(allocator, stderr_writer, report);
                options.color_mode = .never;
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    };
    table_slot.* = parsed;
    if (table_slot.*) |*table| {
        options.ls_colors = table;
    }
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
        .long_format = args.long_format or args.omit_owner or args.omit_group or
            args.numeric_ids or args.show_acls,
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
        .show_acls = args.show_acls,
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
    defer {
        for (files.items) |*entry| entry.freeAclDump(allocator);
        files.deinit(allocator);
    }
    var dirs: std.ArrayList(Entry) = .empty;
    defer {
        for (dirs.items) |*entry| entry.freeAclDump(allocator);
        dirs.deinit(allocator);
    }
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

    // File operands: no headers, and one section rather than one listing per
    // operand, so the group columnates and reserves the git column together
    // (issue #119). Deciding per operand would misalign the column the same
    // way deciding per entry misaligns a directory section.
    if (files.items.len > 0) {
        lsMain_printFileOperands(
            io,
            files.items,
            dirs.items,
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

/// Print the whole non-directory operand group as one section.
fn lsMain_printFileOperands(
    io: std.Io,
    files: []Entry,
    dirs: []const Entry,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: LsOptions,
    allocator: std.mem.Allocator,
    git_context: ?*types.GitContext,
) !void {
    // The caller guards the empty case, since an empty group must print
    // nothing at all rather than an empty section.
    std.debug.assert(files.len > 0);

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

    // GNU sizes -l columns from every operand, then extracts directories
    // (#166). Directory listings still measure only their own contents.
    const column_peers = try lsMain_concatOperandPeers(allocator, files, dirs);
    defer allocator.free(column_peers);

    lsMain_resolveOperandGitStatus(io, files, options, git_context);
    try formatter.printOperandSection(allocator, files, writer, options, style, column_peers);
}

/// Files, then directories, in that order: the same grouping GNU measures
/// before it prints the file-operand section. The slice is a copy, so later
/// directory listings can still own the original dir entries.
fn lsMain_concatOperandPeers(
    allocator: std.mem.Allocator,
    files: []const Entry,
    dirs: []const Entry,
) ![]Entry {
    std.debug.assert(files.len > 0);
    const n = files.len + dirs.len;
    std.debug.assert(n >= files.len);
    const peers = try allocator.alloc(Entry, n);
    @memcpy(peers[0..files.len], files);
    if (dirs.len > 0) {
        @memcpy(peers[files.len..], dirs);
    }
    std.debug.assert(peers.len == n);
    return peers;
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
            // The stat above follows symlinks, so the probe follows too and
            // the mode and the marker describe the same file. Outside -l
            // there is no mode field to mark, and GNU probes nothing either.
            .has_acl = options.long_format and
                common.file.hasExtendedAcl(path, stat.kind, true),
        };
        // -d lists a directory operand as an ordinary entry, so it sorts and
        // prints with the files and never gets a "dir:" header. Only that
        // file group is a long-format row, so only it needs the dump.
        if (stat.kind == .directory and !options.directory) {
            try dirs.append(allocator, entry);
        } else {
            try files.append(allocator, entry);
            core.entryAttachAclDump(
                allocator,
                &files.items[files.items.len - 1],
                path,
                true,
                options,
            );
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
        \\  -e                         display ACL information after each long-format line
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

    // A non-directory operand, and a directory operand under -d, both name one
    // entry to print rather than a directory to walk, so both take the
    // operand-section path and make the decisions that seam owns.
    if (stat.kind != .directory or options.directory) {
        try listSingleFileEntry(io, path, writer, options, allocator, git_context, style, stat);
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

/// Print a single non-directory operand as a one-entry operand section.
///
/// Printing it directly instead would bypass formatter.printOperandSection,
/// and with it every decision that seam owns -- the per-section git-column
/// reservation above all, which made the same clean tracked file indent as an
/// operand and list flush left as a section entry (issue #119).
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
    std.debug.assert(path.len > 0);
    std.debug.assert(stat.kind != .directory or options.directory);
    // GNU echoes a non-directory operand exactly as written, so the operand
    // keeps its directory component here instead of being reduced to a
    // basename.
    var entries = [_]Entry{.{
        .name = path,
        .kind = stat.kind,
        .stat = stat,
        .symlink_target = null,
        // Same follow-ness as the stat the caller took, and skipped entirely
        // outside -l where no mode field is printed to mark.
        .has_acl = options.long_format and
            common.file.hasExtendedAcl(path, stat.kind, true),
    }};
    defer entries[0].freeAclDump(allocator);
    core.entryAttachAclDump(allocator, &entries[0], path, true, options);

    lsMain_resolveOperandGitStatus(io, &entries, options, git_context);
    try formatter.printOperandSection(allocator, &entries, writer, options, style, &entries);
}

/// Look up the git status of each operand in a group, leaving every entry at
/// .not_in_repo when git status is off or unavailable.
fn lsMain_resolveOperandGitStatus(
    io: std.Io,
    entries: []Entry,
    options: LsOptions,
    git_context: ?*types.GitContext,
) void {
    std.debug.assert(entries.len <= std.math.maxInt(u32));
    if (!options.show_git_status) return;
    const ctx = git_context orelse return;
    for (entries) |*entry| {
        std.debug.assert(entry.name.len > 0);
        entry.git_status = ctx.getFileStatus(io, entry.name) orelse .not_in_repo;
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

fn testLsColorsEnv(ls_colors: ?[]const u8) [7]common.env.Override {
    std.debug.assert(test_env_overrides.len == 6);
    std.debug.assert(test_env_overrides[5].value == null);
    return .{
        .{ .key = "VIBEUTILS_STYLE", .value = null },
        .{ .key = "VIBEUTILS_COLOR", .value = null },
        .{ .key = "VIBEUTILS_ICONS", .value = null },
        .{ .key = "LS_ICONS", .value = null },
        .{ .key = "NO_COLOR", .value = null },
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "LS_COLORS", .value = ls_colors },
    };
}

test "ls overlays LS_COLORS directory SGR onto the compiled palette" {
    const staged = testLsColorsEnv("di=01;34");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "blue_dir");
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-1", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, output, "01;34") != null);
    try testing.expect(std.mem.indexOf(u8, output, "blue_dir") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
}

test "ls color never suppresses LS_COLORS escape sequences" {
    const staged = testLsColorsEnv("di=01;34");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "plain_dir");
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=never", "-1", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    try testing.expect(std.mem.indexOf(u8, output, "plain_dir") != null);
}

test "ls without LS_COLORS keeps the compiled directory color" {
    const staged = testLsColorsEnv(null);
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "default_dir");
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-1", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[94m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "01;34") == null);
}

test "ls invalid LS_COLORS diagnoses and disables name coloring" {
    const staged = testLsColorsEnv("zz=01");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "invalid_dir");
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-1", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const stderr_output = stderr_aw.writer.buffered();
    const diagnosed =
        std.mem.indexOf(u8, stderr_output, "unparsable value for LS_COLORS") != null or
        std.mem.indexOf(u8, stderr_output, "unrecognized prefix") != null;

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(diagnosed);
    try testing.expect(std.mem.indexOf(u8, stdout_aw.writer.buffered(), "\x1b[") == null);
}

test "ls long symlink target uses LS_COLORS regular file SGR" {
    const staged = testLsColorsEnv("fi=01;33");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const file = try tmp_dir.dir.createFile(io, "target.txt", .{});
        file.close(io);
    }
    try tmp_dir.dir.symLink(io, "target.txt", "link.txt", .{});
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-l", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();
    const arrow_pos = std.mem.indexOf(u8, output, "->");

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(arrow_pos != null);
    try testing.expect(std.mem.indexOf(u8, output[arrow_pos.? + 2 ..], "01;33") != null);
}

test "ls directory type LS_COLORS beats a matching suffix" {
    const staged = testLsColorsEnv("*.zip=01;31:di=01;34");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "foo.zip");
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-1", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, output, "01;34") != null);
    try testing.expect(std.mem.indexOf(u8, output, "01;31") == null);
    try testing.expect(std.mem.indexOf(u8, output, "foo.zip") != null);
}

test "ls omits LS_COLORS end sequence when di=0 leaves the name uncolored" {
    // GNU emits ec/CSI-reset only after a color start. di=0 is a hit
    // with no start sequence; a custom ec must not still fire after the
    // name, or it can leave the terminal in the wrong state.
    const staged = testLsColorsEnv("di=0:ec=WRONGRESET");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "plain_dir");
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-1", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, output, "plain_dir") != null);
    try testing.expect(std.mem.indexOf(u8, output, "WRONGRESET") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
}

test "ls long symlink omits end sequence when ln=0 and fi=0 leave names uncolored" {
    // Same rule on the long-format symlink-target path: an uncolored
    // fi=0 target must not still print ec after the target text.
    const staged = testLsColorsEnv("ln=0:fi=0:ec=WRONGRESET");
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    common.env.test_overrides = &staged;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const file = try tmp_dir.dir.createFile(io, "target.txt", .{});
        file.close(io);
    }
    try tmp_dir.dir.symLink(io, "target.txt", "link.txt", .{});
    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "--color=always", "-l", "." };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    const output = stdout_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, output, "link.txt ->") != null);
    try testing.expect(std.mem.indexOf(u8, output, "target.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "WRONGRESET") == null);
}

test "ls prints a subdirectory operand exactly as given, not its basename (short format)" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDirPath(io, "subdir");
    {
        const file = try tmp_dir.dir().createFile(io, "subdir/file.txt", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDirPath(io, "subdir");
    {
        const file = try tmp_dir.dir().createFile(io, "subdir/file.txt", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const old_ns: i128 = 1_000_000_000 * 1_000_000_000; // 2001-09-09T01:46:40Z
    const new_ns: i128 = old_ns + 100 * std.time.ns_per_s;

    // Names are chosen so name order ("a_older" < "z_newer") DISAGREES with
    // time order (z_newer is the newer file). A fix that collects operands
    // but always falls back to the name comparator -- ignoring
    // options.sort_by_time entirely -- would still pass an f_old/f_new
    // style fixture (name order there happens to match time order); it
    // must fail this one.
    {
        const file = try tmp_dir.dir().createFile(io, "a_older", .{});
        defer file.close(io);
        try file.setTimestamps(io, .{
            .access_timestamp = .{ .new = .{ .nanoseconds = old_ns } },
            .modify_timestamp = .{ .new = .{ .nanoseconds = old_ns } },
        });
    }
    {
        const file = try tmp_dir.dir().createFile(io, "z_newer", .{});
        defer file.close(io);
        try file.setTimestamps(io, .{
            .access_timestamp = .{ .new = .{ .nanoseconds = new_ns } },
            .modify_timestamp = .{ .new = .{ .nanoseconds = new_ns } },
        });
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Names are chosen so name order ("a_small" < "z_big") DISAGREES with
    // size order (z_big is the bigger file). A fix that collects operands
    // but always falls back to the name comparator -- ignoring
    // options.sort_by_size entirely -- would still pass an f_small/f_big
    // style fixture (name order there happens to match size order); it
    // must fail this one.
    {
        const file = try tmp_dir.dir().createFile(io, "a_small", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "a");
    }
    {
        const file = try tmp_dir.dir().createFile(io, "z_big", .{});
        defer file.close(io);
        const data = [_]u8{'X'} ** 1000;
        try file.writeStreamingAll(io, &data);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    {
        const file = try tmp_dir.dir().createFile(io, "z_file", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir().createFile(io, "a_file", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    {
        const file = try tmp_dir.dir().createFile(io, "z_file", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir().createFile(io, "a_file", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    {
        const file = try tmp_dir.dir().createFile(io, "big", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir().createFile(io, "small", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDirPath(io, "b_dir");
    try tmp_dir.dir().createDirPath(io, "a_dir");
    {
        const file = try tmp_dir.dir().createFile(io, "a_dir/x", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir().createFile(io, "b_dir/y", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    try tmp_dir.dir().createDirPath(io, "a_dir");
    {
        const file = try tmp_dir.dir().createFile(io, "a_dir/x", .{});
        file.close(io);
    }
    {
        const file = try tmp_dir.dir().createFile(io, "z_file", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

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

// ============================================================
// Issue #119: non-directory operands are printed one at a time rather
// than as one section, so they never reach the formatter.printEntries
// seam. Everything that seam decides is therefore missing on the
// operand path: the per-section git-column reservation (the filed
// symptom), the multi-column layout, and the -s block prefix.
//
// The git-column half needs a real repository and lives in
// tests/utilities/ls_test.sh; the two cases below pin the same routing
// with no git dependency.
// ============================================================

test "ls -C lays out multiple file operands in columns, not one per line" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    for ([_][]const u8{ "big", "small" }) |name| {
        const file = try tmp_dir.dir().createFile(io, name, .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Widest operand is 5 chars, so colwidth = (5 + 8) & ~7 = 8 and the
    // gap after "big" (cursor column 3) is a single tab. Pinned against
    // macOS /bin/ls -C big small, which prints one tab-separated row.
    const args = [_][]const u8{ "-C", "-w", "80", "big", "small" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("big\tsmall\n", stdout_aw.writer.buffered());
}

test "ls -s prints the block prefix for file operands and no total line" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();
    // One byte each, so both occupy a single 4 KiB allocation unit: eight
    // 512-byte blocks, verified against `stat` on APFS and on ext4.
    for ([_][]const u8{ "aa", "bb" }) |name| {
        const file = try tmp_dir.dir().createFile(io, name, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "x");
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // BSD and GNU both prefix each file operand with its block count and
    // both omit the "total" line, which only heads a directory section.
    // The field is sized to the widest count in the section, so two
    // single-digit counts give a one-column field: pinned against macOS
    // /bin/ls -s -1 aa bb, which prints "8 aa" and not "   8 aa". GNU
    // `gls -s -1 aa bb` agrees on the width and differs only in the unit.
    const args = [_][]const u8{ "-s", "-1", "aa", "bb" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("8 aa\n8 bb\n", stdout_aw.writer.buffered());
}

test "ls -s sizes the operand block field across all operands, not per operand" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // The equal-width fixture above cannot tell a section-wide field from a
    // per-entry one, because both render identically when every count is the
    // same. Mixed widths separate them: one byte occupies a single 4 KiB
    // allocation unit (8 blocks) and 8 KiB occupies 16, both verified with
    // stat(1) on APFS and on ext4.
    {
        const file = try tmp_dir.dir().createFile(io, "aa", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "x");
    }
    {
        const file = try tmp_dir.dir().createFile(io, "bb", .{});
        defer file.close(io);
        const data: [8192]u8 = @splat('z');
        try file.writeStreamingAll(io, &data);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Operands reach the formatter as ONE section (issue #119), so the
    // widest count in that section sizes the field for every operand and
    // the narrow one is right-aligned into it. Computing the width per
    // operand instead would print "8 aa" / "16 bb" and lose the alignment.
    // Pinned against macOS /bin/ls -s -1 aa bb, which prints " 8 aa" and
    // "16 bb", still with no "total" line.
    const args = [_][]const u8{ "-s", "-1", "aa", "bb" };
    const exit_code = try runLs(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings(" 8 aa\n16 bb\n", stdout_aw.writer.buffered());
}

// ============================================================
// Issue #147: `ls -l` never marks an entry that carries an extended ACL.
//
// GNU's print_long_format sizes the mode field per SECTION: ten columns,
// plus an ELEVENTH as soon as any entry in that section carries a marker.
// The marked entry gets '+' in that column and every other entry of the
// same section gets a pad space; then comes the usual single separator
// space before nlink. A section with no marked entry keeps the ten-column
// field and its single space, byte-identical to what we print today --
// which is what makes the all-plain case a regression guard rather than
// a red.
//
// The fixtures below are built here with lsetxattr instead of read off a
// system path. Asserting against something like /var/log/journal is what
// made this divergence invisible in a dev container while failing on CI
// during #124, and a fixture the test creates is the same on every host.
//
// Running as root changes none of it: these assertions are about display,
// not denial, and ACL visibility is not a DAC decision -- so unlike the
// permission tests in walker.zig/file_ops.zig they need no
// `geteuid() == 0` guard. Verified by hand: setfacl and lsetxattr both
// behave identically as root and as an unprivileged owner.
//
// POSIX ACLs are a Linux facility; the whole group skips elsewhere and
// CI's macOS runner covers the acl_get_link_np arm.
// ============================================================

const TestAclEntry = struct { tag: u16, perm: u16, id: u32 };

// posix_acl_xattr tag and permission constants, from the kernel's
// <linux/posix_acl_xattr.h> / <linux/posix_acl.h>.
const acl_tag_user_obj: u16 = 0x01;
const acl_tag_user: u16 = 0x02;
const acl_tag_group_obj: u16 = 0x04;
const acl_tag_mask: u16 = 0x10;
const acl_tag_other: u16 = 0x20;
const acl_perm_read: u16 = 4;
const acl_perm_write: u16 = 2;
const acl_undefined_id: u32 = 0xFFFF_FFFF;
const acl_access_xattr: [:0]const u8 = "system.posix_acl_access";
const acl_default_xattr: [:0]const u8 = "system.posix_acl_default";

/// Serialize `entries` into the kernel's posix_acl_xattr blob: a
/// little-endian u32 version followed by one <u16 tag, u16 perm, u32 id>
/// record per entry. Comptime, because every fixture here is fixed-size.
fn testAclBlob(comptime entries: []const TestAclEntry) [4 + entries.len * 8]u8 {
    comptime {
        // A POSIX ACL is only well formed with at least the three entries
        // that mirror the mode bits; the kernel rejects anything shorter.
        std.debug.assert(entries.len >= 3);
        var blob: [4 + entries.len * 8]u8 = undefined;
        std.mem.writeInt(u32, blob[0..4], 2, .little); // POSIX_ACL_XATTR_VERSION
        var off: u32 = 4;
        for (entries) |entry| {
            std.mem.writeInt(u16, blob[off..][0..2], entry.tag, .little);
            std.mem.writeInt(u16, blob[off + 2 ..][0..2], entry.perm, .little);
            std.mem.writeInt(u32, blob[off + 4 ..][0..4], entry.id, .little);
            off += 8;
        }
        // A short write would leave undefined bytes the kernel reads as a
        // malformed record and rejects, which would silently skip tests.
        std.debug.assert(off == blob.len);
        return blob;
    }
}

/// An access ACL carrying a NAMED user, which is what makes it extended:
/// the VFS drops an ACL the mode bits already express (see
/// `test_acl_trivial`) instead of storing it, so only the named entry
/// survives as a real xattr. Applied to a 0o644 file the kernel rewrites
/// the mode to 0o664 ("-rw-rw-r--"), exactly as `setfacl -m u:1000:rw`
/// does -- pinned against GNU ls 9.4 on ext4.
const test_acl_extended = testAclBlob(&.{
    .{ .tag = acl_tag_user_obj, .perm = acl_perm_read | acl_perm_write, .id = acl_undefined_id },
    .{ .tag = acl_tag_user, .perm = acl_perm_read | acl_perm_write, .id = 1000 },
    .{ .tag = acl_tag_group_obj, .perm = acl_perm_read, .id = acl_undefined_id },
    .{ .tag = acl_tag_mask, .perm = acl_perm_read | acl_perm_write, .id = acl_undefined_id },
    .{ .tag = acl_tag_other, .perm = acl_perm_read, .id = acl_undefined_id },
});

/// A TRIVIAL ACL: exactly the three entries 0o644 already encodes. The
/// kernel stores no xattr for it, so GNU prints no marker.
const test_acl_trivial = testAclBlob(&.{
    .{ .tag = acl_tag_user_obj, .perm = acl_perm_read | acl_perm_write, .id = acl_undefined_id },
    .{ .tag = acl_tag_group_obj, .perm = acl_perm_read, .id = acl_undefined_id },
    .{ .tag = acl_tag_other, .perm = acl_perm_read, .id = acl_undefined_id },
});

/// Attach `blob` to `rel_path` (resolved against the process cwd, which
/// AclFixture has already moved into the temp dir) and report how many
/// bytes the kernel kept -- 0 when it discarded the ACL as mode
/// equivalent. Skips the test where POSIX ACLs are unavailable: another
/// OS, or a filesystem mounted noacl.
fn testAttachAcl(rel_path: [:0]const u8, xattr: [:0]const u8, blob: []const u8) !u32 {
    if (comptime @import("builtin").os.tag != .linux) {
        return error.SkipZigTest;
    } else {
        std.debug.assert(rel_path.len > 0);
        std.debug.assert(blob.len >= 4 + 3 * 8);
        const set_rc: isize = @bitCast(std.os.linux.lsetxattr(
            rel_path.ptr,
            xattr.ptr,
            blob.ptr,
            blob.len,
            0,
        ));
        if (set_rc != 0) return error.SkipZigTest;
        // A size query (value = null, size = 0) is the cheapest way to ask
        // whether the name survived; the value itself is of no interest.
        var probe: [1]u8 = undefined;
        const get_rc: isize = @bitCast(std.os.linux.lgetxattr(
            rel_path.ptr,
            xattr.ptr,
            &probe,
            0,
        ));
        return if (get_rc < 0) 0 else @intCast(get_rc);
    }
}

/// One ACL-marker test's world: a private temp dir that is ALSO the
/// process cwd, the display env pinned the way the #103 tests pin it, and
/// captured writers. The cwd move is load-bearing twice over -- lsetxattr
/// takes a path rather than a dirfd, and ls resolves its operands against
/// the process cwd -- so both have to agree on where the fixture lives.
const AclFixture = struct {
    tmp: TestDir,
    saved_cwd: std.Io.Dir,
    saved_env: []const common.env.Override,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn init() !AclFixture {
        if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
        const saved_env = testStageDisplayEnvOverrides();
        errdefer common.env.test_overrides = saved_env;
        var tmp = TestDir.init(testing.allocator);
        errdefer tmp.deinit();
        const saved_cwd = try tmp.chdirToBase();
        std.debug.assert(saved_cwd.handle >= 0);
        std.debug.assert(saved_cwd.handle != std.posix.AT.FDCWD);
        return .{
            .tmp = tmp,
            .saved_cwd = saved_cwd,
            .saved_env = saved_env,
            .out = .init(testing.allocator),
            .err = .init(testing.allocator),
        };
    }

    fn deinit(self: *AclFixture) void {
        // Nothing between init and here may swap the overlay out from
        // under us; if it did, the listings above ran with unpinned color
        // and icon settings and their exact-prefix assertions meant
        // something other than what they claim.
        std.debug.assert(common.env.test_overrides.len == test_env_overrides.len);
        self.out.deinit();
        self.err.deinit();
        TestDir.restoreCwd(&self.saved_cwd);
        self.tmp.deinit();
        common.env.test_overrides = self.saved_env;
    }

    /// Create `name` with exactly `mode`, so the rendered permission
    /// letters never depend on the runner's umask.
    fn addFile(self: *AclFixture, name: [:0]const u8, mode: std.c.mode_t) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(mode <= 0o777);
        const file = try self.tmp.dir().createFile(testing.io, name, .{});
        file.close(testing.io);
        const rc = std.c.fchmodat(self.tmp.dir().handle, name, mode, 0);
        std.debug.assert(rc == 0);
    }

    fn addDir(self: *AclFixture, name: [:0]const u8, mode: std.c.mode_t) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(mode <= 0o777);
        try self.tmp.dir().createDir(testing.io, name, .default_dir);
        const rc = std.c.fchmodat(self.tmp.dir().handle, name, mode, 0);
        std.debug.assert(rc == 0);
    }

    fn addSymlink(self: *AclFixture, target: []const u8, link_name: []const u8) !void {
        std.debug.assert(target.len > 0);
        std.debug.assert(link_name.len > 0);
        try self.tmp.dir().symLink(testing.io, target, link_name, .{});
    }

    /// Run the real ls entry point over the fixture and return its exit
    /// code, discarding any previous run's output.
    fn run(self: *AclFixture, args: []const []const u8) !u8 {
        std.debug.assert(args.len > 0);
        self.out.writer.end = 0;
        self.err.writer.end = 0;
        const code = try runLs(
            testing.allocator,
            testing.io,
            args,
            &self.out.writer,
            &self.err.writer,
        );
        // Every fixture here lists at least one entry, so empty output
        // means the listing failed and the assertions below would pass
        // vacuously against a missing line rather than a wrong one.
        std.debug.assert(self.out.writer.buffered().len > 0);
        return code;
    }

    fn stdout(self: *AclFixture) []const u8 {
        return self.out.writer.buffered();
    }
};

/// The first output line containing `name`. Returns an error rather than
/// null so a fixture that stopped producing the line fails loudly instead
/// of skipping the assertion it was carrying.
fn testLineWith(output: []const u8, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(output.len >= name.len);
    // No fixture in this group lists more than a handful of entries; the
    // bound only exists so the scan cannot run away on unexpected input.
    const line_max: u32 = 256;
    var seen: u32 = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| : (seen += 1) {
        if (seen >= line_max) break;
        if (std.mem.find(u8, line, name) != null) return line;
    }
    std.debug.print("no line containing '{s}' in:\n{s}\n", .{ name, output });
    return error.LineNotFound;
}

/// Assert that the long-format line for `name` begins with `prefix` --
/// the mode field, its marker-or-pad column, the separator space and the
/// link count, which is the whole region issue #147 is about.
fn expectLinePrefix(output: []const u8, name: []const u8, prefix: []const u8) !void {
    std.debug.assert(name.len > 0);
    // Ten mode columns plus the eleventh is the shortest prefix worth
    // asserting; anything shorter would not reach the marker column.
    std.debug.assert(prefix.len >= 11);
    const line = try testLineWith(output, name);
    if (line.len < prefix.len) {
        std.debug.print("line for '{s}' is shorter than the expected prefix: '{s}'\n", .{
            name,
            line,
        });
        return error.LineTooShort;
    }
    try testing.expectEqualStrings(prefix, line[0..prefix.len]);
}

/// Copy `raw` into `buf` with every CSI SGR escape ("\x1b[" ... "m")
/// removed, so a color-mode listing can be compared column for column.
fn testStripAnsi(buf: []u8, raw: []const u8) []const u8 {
    std.debug.assert(buf.len >= raw.len);
    std.debug.assert(raw.len > 0);
    var written: u32 = 0;
    var i: u32 = 0;
    while (i < raw.len) {
        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '[') {
            i += 2;
            while (i < raw.len and raw[i] != 'm') : (i += 1) {}
            i += 1;
            continue;
        }
        buf[written] = raw[i];
        written += 1;
        i += 1;
    }
    return buf[0..written];
}

test "ls #147: -l marks the ACL entry with + and pads the rest of its section" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    // A mode-equivalent ACL is discarded by the VFS, and a fixture the
    // kernel threw away would make every assertion below meaningless.
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{"-l"});
    try testing.expectEqual(@as(u8, 0), exit_code);

    // GNU 9.4 on ext4: "-rw-rw-r--+ 1 ..." for the marked entry (the ACL
    // rewrote 0o644 to 0o664) and "-rw-r--r--  1 ..." -- TWO spaces --
    // for the unmarked one, because the section is now eleven wide.
    try expectLinePrefix(fx.stdout(), "acl.txt", "-rw-rw-r--+ 1 ");
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r--  1 ");
}

test "ls #147: a section with no ACL keeps the ten-column mode field" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("one.txt", 0o644);
    try fx.addFile("two.txt", 0o600);

    const exit_code = try fx.run(&.{"-l"});
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Ten columns and ONE separator space, byte for byte what we print
    // today. Almost every real listing has this shape, so an
    // implementation that widens whenever the feature exists -- rather
    // than only when the section actually holds a marker -- regresses
    // all of them, and this is the assertion that catches it.
    try expectLinePrefix(fx.stdout(), "one.txt", "-rw-r--r-- 1 ");
    try expectLinePrefix(fx.stdout(), "two.txt", "-rw------- 1 ");
}

test "ls #147: -l on a lone ACL file operand leaves one space after the marker" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-l", "acl.txt" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // The marker takes the eleventh column, not a column of its own on
    // top of the separator: GNU prints "-rw-rw-r--+ 1", never
    // "-rw-rw-r--+  1".
    try expectLinePrefix(fx.stdout(), "acl.txt", "-rw-rw-r--+ 1 ");
}

test "ls #147: -ln keeps the marker in column 11, ahead of the numeric uid" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{"-ln"});
    try testing.expectEqual(@as(u8, 0), exit_code);

    // The marker's position is fixed relative to the mode field, so
    // swapping owner names for numeric ids must not move it.
    try expectLinePrefix(fx.stdout(), "acl.txt", "-rw-rw-r--+ 1 ");
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r--  1 ");
}

test "ls #147: -ls keeps the block prefix before the mode and the marker after it" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-ls", "acl.txt", "plain.txt" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Both files are empty, so each occupies zero blocks and the block
    // field is one column wide. GNU prints "0 -rw-rw-r--+ 1 ...": the
    // marker belongs to the mode field, not to the head of the line.
    try expectLinePrefix(fx.stdout(), "acl.txt", "0 -rw-rw-r--+ 1 ");
    try expectLinePrefix(fx.stdout(), "plain.txt", "0 -rw-r--r--  1 ");
}

test "ls #147: the eleventh column is sized per section, not once per run" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addDir("dir_a", 0o755);
    try fx.addDir("dir_b", 0o755);
    try fx.addFile("dir_a/plain.txt", 0o644);
    try fx.addFile("dir_b/acl.txt", 0o644);
    const kept = try testAttachAcl("dir_b/acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-l", "dir_a", "dir_b" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // dir_a holds no marked entry, so its section stays ten wide even
    // though dir_b's section -- printed by the same process, moments
    // later -- widens to eleven. A width decided once for the whole run
    // pads dir_a too and fails here; this is the assertion that
    // separates a per-section flag from a global one.
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r-- 1 ");
    try expectLinePrefix(fx.stdout(), "acl.txt", "-rw-rw-r--+ 1 ");
}

test "ls #147: a section printed after a marked one keeps the ten-column field" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addDir("aaa", 0o755);
    try fx.addDir("zzz", 0o755);
    try fx.addFile("aaa/marked.txt", 0o644);
    try fx.addFile("zzz/bare.txt", 0o644);
    const kept = try testAttachAcl("aaa/marked.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-l", "aaa", "zzz" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // The mirror image of the test above, and the only operand order that
    // can catch a width latched once for the whole run. With the marked
    // section second, a global flag is still false while the plain section
    // is measured, so it prints ten columns and looks correct by accident.
    // Marked first, the flag is already set when zzz is measured, and a
    // global implementation pads zzz to eleven. Operands are sorted, so the
    // names are what put the marked section first.
    try expectLinePrefix(fx.stdout(), "marked.txt", "-rw-rw-r--+ 1 ");
    try expectLinePrefix(fx.stdout(), "bare.txt", "-rw-r--r-- 1 ");
}

test "ls #147: --color=always emits the marker as a plain byte" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-l", "--color=always", "acl.txt" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // GNU never colors the mode field, marker included.
    // writeColoredPermissions resets after every permission character, so
    // a marker written outside the color region follows that reset
    // directly; a marker wrapped in its own SGR pair pushes an escape
    // sequence in between and fails this.
    const raw = fx.stdout();
    try testing.expect(std.mem.find(u8, raw, "\x1b[0m+") != null);

    var plain_buf: [4096]u8 = undefined;
    const plain = testStripAnsi(&plain_buf, raw);
    try expectLinePrefix(plain, "acl.txt", "-rw-rw-r--+ 1 ");
}

test "ls #147: an unstattable entry occupies the section's widened mode field" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addSymlink("nowhere", "zdangle");
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    // -L makes the dangling link unstattable, which is the only way to
    // reach the `entry.stat == null` branch from a real filesystem. Its
    // exit code is a separate question (GNU reports 2, we report 0) and
    // is deliberately not asserted here.
    _ = try fx.run(&.{"-lL"});

    const out = fx.stdout();
    const acl_line = try testLineWith(out, "acl.txt");
    const dangle_line = try testLineWith(out, "zdangle");
    try testing.expect(dangle_line.len > 12);
    try testing.expect(acl_line.len > 12);

    // We render an unstattable entry's mode as ten dashes. In a section
    // that carries a marker it still has to occupy eleven columns, so the
    // link count starts at the same index as the marked entry's -- and
    // an entry we could not even stat must never be given the marker.
    try testing.expectEqualStrings("----------", dangle_line[0..10]);
    try testing.expect(dangle_line[10] != '+');
    try testing.expectEqual(@as(u8, '?'), dangle_line[12]);
    try testing.expectEqual(@as(u8, '1'), acl_line[12]);
}

test "ls #147: a directory carrying only a default ACL is marked" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addDir("defaultdir", 0o755);
    const kept = try testAttachAcl("defaultdir", acl_default_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-ld", "defaultdir" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // A default ACL leaves the mode bits alone, so the marker is the only
    // thing that distinguishes this directory from a plain 0o755 one --
    // and GNU marks it. Probing system.posix_acl_access alone misses it,
    // which is exactly the mistake this pins.
    try expectLinePrefix(fx.stdout(), "defaultdir", "drwxr-xr-x+ 2 ");
}

test "ls #147: a trivial ACL produces no marker" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("min.txt", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl("min.txt", acl_access_xattr, &test_acl_trivial);
    // The VFS stores nothing for an ACL the mode bits already express, so
    // there is no xattr to find and GNU prints no marker. Pinning the
    // zero keeps the fixture honest: if a kernel ever starts persisting
    // it, this test stops silently testing an ordinary plain file.
    try testing.expectEqual(@as(u32, 0), kept);

    const exit_code = try fx.run(&.{"-l"});
    try testing.expectEqual(@as(u8, 0), exit_code);

    try expectLinePrefix(fx.stdout(), "min.txt", "-rw-r--r-- 1 ");
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r-- 1 ");
}

test "ls #147: a symlink is unmarked without -L and marked with it" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addSymlink("acl.txt", "zlink");
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    var exit_code = try fx.run(&.{"-l"});
    try testing.expectEqual(@as(u8, 0), exit_code);
    // GNU short-circuits on S_ISLNK and never probes the link itself, so
    // the link gets the section's pad space rather than its target's
    // marker.
    try expectLinePrefix(fx.stdout(), "zlink", "lrwxrwxrwx  1 ");
    try expectLinePrefix(fx.stdout(), "acl.txt", "-rw-rw-r--+ 1 ");

    exit_code = try fx.run(&.{"-lL"});
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Under -L the stat follows the link, and the probe has to follow it
    // the same way or the mode and the marker disagree about which file
    // the line describes.
    try expectLinePrefix(fx.stdout(), "zlink", "-rw-rw-r--+ 1 ");
}

test "ls #147: --time-style=long-iso does not move the marker" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{ "-l", "--time-style=long-iso" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // The time column is far to the right of the mode field; widening it
    // must not disturb the marker, and vice versa.
    try expectLinePrefix(fx.stdout(), "acl.txt", "-rw-rw-r--+ 1 ");
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r--  1 ");
}

test "ls #147: the marker is a long-format detail and never appears without -l" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl("acl.txt", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    const exit_code = try fx.run(&.{"-1"});
    try testing.expectEqual(@as(u8, 0), exit_code);

    // GNU issues no xattr syscall at all outside -l, and prints nothing
    // but the names. A marker appended in short format would be visible
    // here as "acl.txt+".
    try testing.expectEqualStrings("acl.txt\nplain.txt\n", fx.stdout());
}

test "ls #147: an ACL entry the section does not list cannot widen it" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile(".hidden_acl", 0o644);
    try fx.addFile("plain.txt", 0o644);
    const kept = try testAttachAcl(".hidden_acl", acl_access_xattr, &test_acl_extended);
    try testing.expect(kept > 0);

    var exit_code = try fx.run(&.{"-l"});
    try testing.expectEqual(@as(u8, 0), exit_code);
    // The hidden entry is not part of this section, so its ACL is none of
    // the section's business: the width follows what was LISTED, not what
    // is on disk.
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r-- 1 ");

    // -A pulls it in (and, unlike -a, leaves "." and ".." out, whose link
    // counts would otherwise resize the nlink column), and now the whole
    // section widens.
    exit_code = try fx.run(&.{"-lA"});
    try testing.expectEqual(@as(u8, 0), exit_code);
    try expectLinePrefix(fx.stdout(), ".hidden_acl", "-rw-rw-r--+ 1 ");
    try expectLinePrefix(fx.stdout(), "plain.txt", "-rw-r--r--  1 ");
}

// ============================================================
// Issue #147 leftover: BSD/macOS `ls -e` ACL dump.
//
// The GNU `+` marker on `ls -l` is already implemented above. What
// remains is `-e`: Darwin's man page says "Print the Access Control
// List (ACL) associated with the file, if present, in long (-l)
// output." After each long-format line, numbered ACE lines follow.
// `show_acls` is parsed from `-e` and never read, so these tests are
// expected RED until the dump exists. Do not mark the flag WONT.
//
// Linux has no NFSv4 ACE list; the dump is the POSIX ACL already
// stored as `system.posix_acl_access` (the same xattr the `+` marker
// probes). Fixtures are created here and `setfacl`'d -- never a
// system path. Missing setfacl, or a filesystem that stores no ACL,
// skips rather than asserting against a file that never had one.
// =====================================================}

/// Grant a named-user ACE on `rel_path` via setfacl(1). Skips when the
/// tool is absent, the call fails, or the kernel kept no xattr.
fn testSetfacl(rel_path: [:0]const u8) !void {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    std.debug.assert(rel_path.len > 0);
    const allocator = testing.allocator;
    const result = std.process.run(allocator, testing.io, .{
        .argv = &.{ "setfacl", "-m", "u:1000:rw", rel_path },
    }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
    // A noacl mount can accept setfacl and still store nothing; the
    // size-0 lgetxattr probe is the same check the marker tests use.
    var probe: [1]u8 = undefined;
    const get_rc: isize = @bitCast(std.os.linux.lgetxattr(
        rel_path.ptr,
        acl_access_xattr.ptr,
        &probe,
        0,
    ));
    if (get_rc <= 0) return error.SkipZigTest;
    std.debug.assert(get_rc > 0);
}

/// Bytes after the first output line containing `name`. Empty when that
/// line is the last thing printed (the current -e no-op on a lone file).
fn testAfterNamedLine(output: []const u8, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(output.len >= name.len);
    const line_max: u32 = 256;
    var seen: u32 = 0;
    var start: u32 = 0;
    while (seen < line_max) : (seen += 1) {
        if (start >= output.len) break;
        const rest = output[start..];
        const nl_off = std.mem.indexOfScalar(u8, rest, '\n');
        const line_len: u32 = if (nl_off) |off| @intCast(off) else @intCast(rest.len);
        const line = rest[0..line_len];
        const step: u32 = if (nl_off != null) 1 else 0;
        const after_start: u32 = start + line_len + step;
        if (std.mem.find(u8, line, name) != null) {
            if (after_start >= output.len) return output[output.len..];
            return output[after_start..];
        }
        start = after_start;
    }
    std.debug.print("no line containing '{s}' in:\n{s}\n", .{ name, output });
    return error.LineNotFound;
}

/// Fail with AclDumpMissing when `-e` printed only the long line.
fn testExpectAclDump(output: []const u8, name: []const u8) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(output.len > 0);
    const extra = try testAfterNamedLine(output, name);
    const extra_trim = std.mem.trim(u8, extra, " \t\n");
    if (extra_trim.len == 0) {
        std.debug.print(
            "ACL dump is missing after the long line for '{s}':\n{s}\n",
            .{ name, output },
        );
        return error.AclDumpMissing;
    }
    // POSIX getfacl writes "user::rw-" / "user:name:rw-"; a BSD-style
    // numbered dump still carries a "user:" token for the named ACE.
    if (std.mem.find(u8, extra, "user:") == null) {
        std.debug.print(
            "ACL dump after '{s}' is missing POSIX ACL text (user:):\n{s}\n",
            .{ name, extra },
        );
        return error.AclDumpMissing;
    }
}

/// A file with no ACL must not grow a fake dump after its long line.
fn testExpectNoAclDump(output: []const u8, name: []const u8) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(output.len > 0);
    const extra = try testAfterNamedLine(output, name);
    const extra_trim = std.mem.trim(u8, extra, " \t\n");
    if (extra_trim.len != 0) {
        std.debug.print(
            "unexpected ACL dump for '{s}' which has no ACL:\n{s}\n",
            .{ name, extra },
        );
        return error.UnexpectedAclDump;
    }
}

test "ls #147: -le dumps BSD ACL text after the long line" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try testSetfacl("acl.txt");

    const exit_code = try fx.run(&.{ "-le", "acl.txt" });
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testExpectAclDump(fx.stdout(), "acl.txt");
}

test "ls #147: -e is not a silent no-op; an ACL file produces extra output vs -l" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try testSetfacl("acl.txt");

    const l_code = try fx.run(&.{ "-l", "acl.txt" });
    try testing.expectEqual(@as(u8, 0), l_code);
    const l_out = try testing.allocator.dupe(u8, fx.stdout());
    defer testing.allocator.free(l_out);

    const le_code = try fx.run(&.{ "-le", "acl.txt" });
    try testing.expectEqual(@as(u8, 0), le_code);
    const le_out = fx.stdout();

    if (le_out.len <= l_out.len) {
        std.debug.print(
            "ACL dump is missing: ls -le is a silent no-op vs ls -l\n-l:\n{s}\n-le:\n{s}\n",
            .{ l_out, le_out },
        );
        return error.AclDumpMissing;
    }
    try testExpectAclDump(le_out, "acl.txt");
}

test "ls #147: -le on a file without an ACL prints no dump" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("plain.txt", 0o644);

    const l_code = try fx.run(&.{ "-l", "plain.txt" });
    try testing.expectEqual(@as(u8, 0), l_code);
    const l_out = try testing.allocator.dupe(u8, fx.stdout());
    defer testing.allocator.free(l_out);

    const le_code = try fx.run(&.{ "-le", "plain.txt" });
    try testing.expectEqual(@as(u8, 0), le_code);

    try testing.expectEqualStrings(l_out, fx.stdout());
    try testExpectNoAclDump(fx.stdout(), "plain.txt");
}

test "ls #147: -e FILE implies long format and dumps the ACL" {
    var fx = try AclFixture.init();
    defer fx.deinit();
    try fx.addFile("acl.txt", 0o644);
    try testSetfacl("acl.txt");

    const exit_code = try fx.run(&.{ "-e", "acl.txt" });
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Darwin's man page documents -e as a long-format dump. `-g`/`-n`/`-o`
    // already imply -l here; -e does the same so a bare `-e FILE` is not
    // a name-only listing (the current silent no-op).
    const line = try testLineWith(fx.stdout(), "acl.txt");
    if (line.len < 10 or line[0] != '-') {
        std.debug.print(
            "ACL dump is missing: -e did not imply long format\n{s}\n",
            .{fx.stdout()},
        );
        return error.AclDumpMissing;
    }
    try testExpectAclDump(fx.stdout(), "acl.txt");
}

// Issue #166: `ls -l` sizes the file-operand section after
// partitioning directories out. GNU measures every operand first
// (gobble_file), then extract_dirs_from_files removes directories
// from the listing -- so a directory's nlink/owner/group/size (and
// ACL marker) still size the surviving file lines.
//
// A 0-byte file plus a directory is enough for the size column
// (typical st_size 4096, four digits). Eight subdirectories push
// the directory's nlink to 10 so the nlink column widens too; a
// fix that only pads size would still fail here. Owner and group
// are the same id on both operands under -n, so they do not widen,
// but they sit in the asserted prefix and a column that drifted
// would still fail.
//
// No ACL is attached: #166 is not ACL-specific, and the marker
// column is covered as the ten-column mode field with no eleventh.
// ============================================================

/// Decimal digit count of `n`. Zero is one digit, matching how GNU
/// renders a 0-byte size.
fn testDecimalDigits(n: u64) u32 {
    var digits: u32 = 1;
    var x = n;
    while (x >= 10) {
        x = @divFloor(x, 10);
        digits += 1;
        std.debug.assert(digits <= 20);
    }
    return digits;
}

/// Right-align the decimal form of `value` into `buf` to `width`
/// columns, the way GNU right-aligns nlink/uid/gid/size.
fn testRightAlignU64(buf: []u8, value: u64, width: u32) ![]const u8 {
    std.debug.assert(width >= 1);
    std.debug.assert(buf.len >= width);
    var txt_buf: [20]u8 = undefined;
    const txt = try std.fmt.bufPrint(&txt_buf, "{d}", .{value});
    std.debug.assert(txt.len > 0);
    std.debug.assert(txt.len <= width);
    const pad = width - @as(u32, @intCast(txt.len));
    var i: u32 = 0;
    while (i < pad) : (i += 1) {
        buf[i] = ' ';
    }
    @memcpy(buf[pad..][0..txt.len], txt);
    return buf[0..width];
}

test "ls #166: -ln sizes the file-operand section from every operand, including directories" {
    const saved_env = testStageDisplayEnvOverrides();
    defer common.env.test_overrides = saved_env;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        const file = try tmp_dir.dir.createFile(io, "f_plain", .{});
        file.close(io);
        const rc = std.c.fchmodat(tmp_dir.dir.handle, "f_plain", 0o644, 0);
        std.debug.assert(rc == 0);
    }
    try tmp_dir.dir.createDir(io, "d_wide", .default_dir);
    {
        const rc = std.c.fchmodat(tmp_dir.dir.handle, "d_wide", 0o755, 0);
        std.debug.assert(rc == 0);
    }
    // Eight children → nlink 10 (2 + 8). An empty directory's nlink is
    // 2, still one digit, and would not catch a nlink-width miss.
    const subdirs = [_][]const u8{
        "d_wide/s0", "d_wide/s1", "d_wide/s2", "d_wide/s3",
        "d_wide/s4", "d_wide/s5", "d_wide/s6", "d_wide/s7",
    };
    for (subdirs) |path| {
        try tmp_dir.dir.createDirPath(io, path);
    }

    var saved_cwd = try testChdirToTmp(io, &tmp_dir);
    defer testRestoreCwd(io, &saved_cwd);

    const file_info = try common.file.FileInfo.lstat("f_plain");
    const dir_info = try common.file.FileInfo.lstat("d_wide");
    std.debug.assert(file_info.kind == .file);
    std.debug.assert(dir_info.kind == .directory);

    const nlink_width = @max(
        testDecimalDigits(file_info.nlink),
        testDecimalDigits(dir_info.nlink),
    );
    const owner_width = @max(
        testDecimalDigits(file_info.uid),
        testDecimalDigits(dir_info.uid),
    );
    const group_width = @max(
        testDecimalDigits(file_info.gid),
        testDecimalDigits(dir_info.gid),
    );
    const size_width = @max(
        testDecimalDigits(file_info.size),
        testDecimalDigits(dir_info.size),
    );
    // The fixture must actually widen nlink and size versus a file-only
    // measurement, or the prefix below would match today's (wrong) output.
    try testing.expect(nlink_width > testDecimalDigits(file_info.nlink));
    try testing.expect(size_width > testDecimalDigits(file_info.size));

    var nlink_buf: [20]u8 = undefined;
    var owner_buf: [20]u8 = undefined;
    var group_buf: [20]u8 = undefined;
    var size_buf: [20]u8 = undefined;
    const nlink_field = try testRightAlignU64(&nlink_buf, file_info.nlink, nlink_width);
    const owner_field = try testRightAlignU64(&owner_buf, file_info.uid, owner_width);
    const group_field = try testRightAlignU64(&group_buf, file_info.gid, group_width);
    const size_field = try testRightAlignU64(&size_buf, file_info.size, size_width);

    var prefix_buf: [128]u8 = undefined;
    const expected_prefix = try std.fmt.bufPrint(
        &prefix_buf,
        "-rw-r--r-- {s} {s} {s} {s} ",
        .{ nlink_field, owner_field, group_field, size_field },
    );

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-ln", "--color=never", "f_plain", "d_wide" };
    const exit_code = try runLs(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);

    const output = stdout_aw.writer.buffered();
    const line = try testLineWith(output, "f_plain");
    // Mode (no eleventh marker column), nlink, owner, group, and size
    // together -- not one column in isolation. A fix that moves only
    // one of those widths still fails this prefix.
    try expectLinePrefix(output, "f_plain", expected_prefix);
    try testing.expect(std.mem.endsWith(u8, line, "f_plain"));
}
