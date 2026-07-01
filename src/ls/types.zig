const std = @import("std");
const common = @import("common");

/// Color mode configuration for output
pub const ColorMode = enum {
    always,
    auto,
    never,
};

/// Time formatting style for -l output
pub const TimeStyle = enum {
    default, // Traditional: "Mar  1 14:30" or "Jan 15  2024"
    relative, // Smart relative dates like "2 hours ago"
    iso, // ISO format: 2024-01-15 15:30
    @"long-iso", // Long ISO: 2024-01-15 15:30:45.123456789 +0000
    full, // Full time with seconds and year: "Mar  1 14:30:45 2024"
};

/// Configuration options for ls command
pub const LsOptions = struct {
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
    append_slash_dirs: bool = false,
    non_printable_as_question: bool = false,
    omit_owner: bool = false,
    omit_group: bool = false,
    color_mode: ColorMode = .auto,
    terminal_width: ?u16 = null, // null means auto-detect
    group_directories_first: bool = false,
    show_inodes: bool = false,
    numeric_ids: bool = false,
    comma_format: bool = false,
    icon_mode: common.icons.IconMode = .auto,
    time_style: TimeStyle = .default,
    show_git_status: bool = false,
    is_terminal: bool = false, // Terminal status for icon display
    no_sort: bool = false, // -f: list entries in directory order
    show_blocks: bool = false, // -s: show filesystem blocks
    use_atime: bool = false, // -u: use access time instead of mtime
    use_ctime: bool = false, // -c: use status change time instead of mtime
    columns_across: bool = false, // -x: sort across rows instead of down columns
    full_time: bool = false, // -T: show full time with seconds and year
    follow_all_symlinks: bool = false, // -L: follow all symlinks
    follow_cmdline_symlinks: bool = false, // -H: follow symlinks on command line
    escape_non_printable: bool = false, // -b: C-style escape sequences for non-printable chars
    hide_backups: bool = false, // -B: hide entries ending with ~
    ignore_pattern: ?[]const u8 = null, // -I PATTERN: ignore entries matching glob pattern
    no_follow_symlinks: bool = false, // -P: don't follow symlinks (show link info)
    unsorted: bool = false, // -U: no sort, directory order (without implying -a)
    version_sort: bool = false, // -v: natural version sort
    sort_by_extension: bool = false, // -X: sort by file extension
    thousands_grouping: bool = false, // -,: format sizes with comma grouping
};

/// Represents a directory entry with metadata
pub const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    stat: ?common.file.FileInfo = null,
    symlink_target: ?[]const u8 = null,
    git_status: common.git.GitStatus = .not_in_repo,
    display_width: ?usize = null, // Cached display width for performance
    file_type_indicator: ?u8 = null, // Cached file type indicator for performance

    /// Calculate the display width of this entry without caching
    pub fn calculateDisplayWidth(
        self: *const Entry,
        file_type_indicators: bool,
        append_slash_dirs: bool,
        show_icons: bool,
        show_git_status: bool,
    ) usize { // tiger:allow:usize-arch displayWidth returns usize
        // Calculate display width based on entry properties
        var width: usize = 0;

        // Add icon width if enabled (varies by icon glyph)
        if (show_icons) {
            const theme = common.icons.IconTheme{};
            const icon = common.icons.getIcon(
                &theme,
                self.name,
                self.kind == .directory,
                self.kind == .sym_link,
                computeIsExecutable(self),
            );
            width += common.unicode.displayWidth(icon) + 1; // icon glyph + space
        }

        // Add Git status indicator width if enabled
        if (show_git_status and self.git_status != .not_in_repo) {
            width += 3; // 2-char status indicator + space
        }

        // Add filename width (using actual display width for Unicode)
        width += common.unicode.displayWidth(self.name);

        // Add file type indicator if enabled
        if (file_type_indicators) {
            const indicator = computeFileTypeIndicator(self);
            if (indicator != 0) {
                width += 1;
            }
        } else if (append_slash_dirs and self.kind == .directory) {
            width += 1; // -p: slash after directory names
        }

        return width;
    }

    /// Get the display width of this entry, caching the result for future calls
    pub fn getDisplayWidth(
        self: *Entry,
        file_type_indicators: bool,
        append_slash_dirs: bool,
        show_icons: bool,
        show_git_status: bool,
    ) usize { // tiger:allow:usize-arch displayWidth returns usize
        if (self.display_width) |cached_width| {
            return cached_width;
        }

        const width = self.calculateDisplayWidth(
            file_type_indicators,
            append_slash_dirs,
            show_icons,
            show_git_status,
        );

        // Cache the calculated width
        self.display_width = width;
        return width;
    }

    /// Get cached file type indicator, calculating and caching if needed
    pub fn getFileTypeIndicator(self: *Entry) u8 {
        if (self.file_type_indicator) |cached_indicator| {
            return cached_indicator;
        }

        const indicator = computeFileTypeIndicator(self);

        // Cache the calculated indicator
        self.file_type_indicator = indicator;
        return indicator;
    }

    fn computeIsExecutable(self: *const Entry) bool {
        if (self.kind != .file) return false;
        if (self.stat) |stat| return (stat.mode & common.constants.EXECUTE_BIT) != 0;
        return false;
    }

    /// Compute file type indicator without mutation (safe for const access)
    fn computeFileTypeIndicator(self: *const Entry) u8 {
        return switch (self.kind) {
            .directory => '/',
            .sym_link => '@',
            .named_pipe => '|',
            .unix_domain_socket => '=',
            .file => if (self.stat) |stat|
                if ((stat.mode & common.constants.EXECUTE_BIT) != 0) '*' else 0
            else
                0,
            else => 0,
        };
    }

    /// Reset cached values (call when entry properties change)
    pub fn resetCache(self: *Entry) void {
        self.display_width = null;
        self.file_type_indicator = null;
    }
};

/// Configuration for sorting directory entries
pub const SortConfig = struct {
    by_time: bool = false,
    by_size: bool = false,
    dirs_first: bool = false,
    reverse: bool = false,
    use_atime: bool = false, // -u: sort by access time instead of mtime
    use_ctime: bool = false, // -c: sort by status change time instead of mtime
    by_extension: bool = false, // -X: sort by file extension
    version_sort: bool = false, // -v: natural version sort
};

/// Parse color mode from string argument
pub fn parseColorMode(arg: []const u8) !ColorMode {
    return std.meta.stringToEnum(ColorMode, arg) orelse error.InvalidColorMode;
}

/// Parse time style from string argument
pub fn parseTimeStyle(arg: []const u8) !TimeStyle {
    return std.meta.stringToEnum(TimeStyle, arg) orelse error.InvalidTimeStyle;
}

/// Git initialization errors for better error reporting.
///
/// A missing repository is signalled by `findGitRoot` returning null, not an
/// error, so `GitContext.init` leaves `init_error` null in that case. The only
/// surfaced errors are unexpected I/O failures (e.g. OOM), hence the single
/// variant. The message is the detail appended after "git status unavailable:".
pub const GitInitError = enum {
    unknown_error,

    /// Get a user-friendly error message
    pub fn getMessage(self: GitInitError) []const u8 {
        return switch (self) {
            .unknown_error => "unexpected error",
        };
    }
};

/// Git context for managing a single git repository instance
pub const GitContext = struct {
    repo: ?common.git.GitRepo,
    allocator: std.mem.Allocator,
    init_error: ?GitInitError = null,

    /// Initialize GitContext for the given path
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) GitContext {
        const repo = common.git.GitRepo.init(allocator, io, path) catch |err| {
            const git_error = mapGitError(err);
            return GitContext{
                .repo = null,
                .allocator = allocator,
                .init_error = git_error,
            };
        };
        return GitContext{
            .repo = repo,
            .allocator = allocator,
            .init_error = null,
        };
    }

    /// Clean up GitContext resources
    pub fn deinit(self: *GitContext) void {
        if (self.repo) |*repo| {
            repo.deinit();
        }
    }

    /// Get git status for a specific file
    pub fn getFileStatus(
        self: *GitContext,
        io: std.Io,
        filename: []const u8,
    ) ?common.git.GitStatus {
        if (self.repo) |*repo| {
            return repo.getFileStatus(io, filename);
        }
        return null;
    }

    /// Check if git operations are available
    pub fn isAvailable(self: *const GitContext) bool {
        return self.repo != null;
    }

    /// Report initialization issues if git operations were requested but unavailable
    pub fn reportInitializationIssues(
        self: *const GitContext,
        allocator: std.mem.Allocator,
        stderr_writer: anytype,
        prog_name: []const u8,
        warn_when_unavailable: bool,
    ) void {
        if (warn_when_unavailable and self.init_error != null) {
            if (self.init_error) |err| {
                common.printWarningWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "git status unavailable: {s}",
                    .{err.getMessage()},
                );
            }
        }
    }
};

/// Map system errors to GitInitError
fn mapGitError(_: anyerror) GitInitError {
    // findGitRoot returns null (not an error) for a missing repo; a surfaced
    // error is always an unexpected I/O failure (e.g. OOM).
    return GitInitError.unknown_error;
}

const testing = std.testing;

test "reportInitializationIssues stays silent in auto mode" {
    // Auto mode must not surface git warnings even when init failed, so a
    // user who has not opted in never sees spurious noise on stderr.
    var ctx = GitContext{
        .repo = null,
        .allocator = testing.allocator,
        .init_error = .unknown_error,
    };

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ctx.reportInitializationIssues(testing.allocator, &w, "ls", false);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);

    // Explicit --git=always (warn_when_unavailable = true) must surface the
    // truthful message and must never claim the git command is missing.
    w = .fixed(&buf);
    ctx.reportInitializationIssues(testing.allocator, &w, "ls", true);
    const output = w.buffered();
    try testing.expect(std.mem.find(u8, output, "git status unavailable") != null);
    try testing.expect(std.mem.find(u8, output, "command not found") == null);
}

test "GitContext.init in a non-repo yields no init_error" {
    // A genuine non-repository directory must initialize cleanly: findGitRoot
    // returns null (not an error), so no false init_error is recorded. The
    // test directory must live OUTSIDE any git repository, so we anchor it
    // under the system temp dir rather than testing.tmpDir (which nests under
    // the project tree and would be found by the upward .git walk).
    const io = testing.io;
    var tmp_root = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp_root.close(io);

    const dir_name = "vibeutils_ls_nonrepo_test";
    tmp_root.deleteTree(io, dir_name) catch {};
    try tmp_root.createDirPath(io, dir_name);
    defer tmp_root.deleteTree(io, dir_name) catch {};

    const abs = "/tmp/" ++ dir_name;
    var ctx = GitContext.init(testing.allocator, io, abs);
    defer ctx.deinit();
    try testing.expect(ctx.repo == null);
    try testing.expect(ctx.init_error == null);
}
