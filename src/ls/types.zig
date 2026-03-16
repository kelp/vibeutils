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
};

/// Represents a directory entry with metadata
pub const Entry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    stat: ?common.file.FileInfo = null,
    symlink_target: ?[]const u8 = null,
    git_status: common.git.GitStatus = .not_in_repo,
    display_width: ?usize = null, // Cached display width for performance
    file_type_indicator: ?u8 = null, // Cached file type indicator for performance

    /// Calculate the display width of this entry without caching
    pub fn calculateDisplayWidth(self: *const Entry, file_type_indicators: bool, append_slash_dirs: bool, show_icons: bool, show_git_status: bool) usize {
        // Calculate display width based on entry properties
        var width: usize = 0;

        // Add icon width if enabled (varies by icon glyph)
        if (show_icons) {
            const theme = common.icons.IconTheme{};
            const icon = common.icons.getIcon(&theme, self.name, self.kind == .directory, self.kind == .sym_link, computeIsExecutable(self));
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
    pub fn getDisplayWidth(self: *Entry, file_type_indicators: bool, append_slash_dirs: bool, show_icons: bool, show_git_status: bool) usize {
        if (self.display_width) |cached_width| {
            return cached_width;
        }

        const width = self.calculateDisplayWidth(file_type_indicators, append_slash_dirs, show_icons, show_git_status);

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
};

/// Parse color mode from string argument
pub fn parseColorMode(arg: []const u8) !ColorMode {
    return std.meta.stringToEnum(ColorMode, arg) orelse error.InvalidColorMode;
}

/// Parse time style from string argument
pub fn parseTimeStyle(arg: []const u8) !TimeStyle {
    return std.meta.stringToEnum(TimeStyle, arg) orelse error.InvalidTimeStyle;
}

/// Git initialization errors for better error reporting
pub const GitInitError = enum {
    not_a_repository,
    permission_denied,
    corrupted_repository,
    git_command_not_found,
    network_error,
    disk_full,
    unknown_error,

    /// Get a user-friendly error message
    pub fn getMessage(self: GitInitError) []const u8 {
        return switch (self) {
            .not_a_repository => "not a git repository (or any of the parent directories)",
            .permission_denied => "permission denied accessing git repository",
            .corrupted_repository => "git repository appears to be corrupted",
            .git_command_not_found => "git command not found in PATH",
            .network_error => "network error during git operation",
            .disk_full => "disk full during git operation",
            .unknown_error => "unknown git error",
        };
    }
};

/// Git context for managing a single git repository instance
pub const GitContext = struct {
    repo: ?common.git.GitRepo,
    allocator: std.mem.Allocator,
    init_error: ?GitInitError = null,

    /// Initialize GitContext for the given path
    pub fn init(allocator: std.mem.Allocator, path: []const u8) GitContext {
        const repo = common.git.GitRepo.init(allocator, path) catch |err| {
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
    pub fn getFileStatus(self: *GitContext, filename: []const u8) ?common.git.GitStatus {
        if (self.repo) |*repo| {
            return repo.getFileStatus(filename);
        }
        return null;
    }

    /// Check if git operations are available
    pub fn isAvailable(self: *const GitContext) bool {
        return self.repo != null;
    }

    /// Report initialization issues if git operations were requested but unavailable
    pub fn reportInitializationIssues(self: *const GitContext, allocator: std.mem.Allocator, stderr_writer: anytype, prog_name: []const u8, git_features_requested: bool) void {
        if (git_features_requested and self.init_error != null) {
            if (self.init_error) |err| {
                common.printWarningWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "git status unavailable: {s}", .{err.getMessage()});
            }
        }
    }
};

/// Map system errors to GitInitError
fn mapGitError(err: anyerror) GitInitError {
    return switch (err) {
        error.NotFound => GitInitError.not_a_repository,
        error.AccessDenied => GitInitError.permission_denied,
        error.InvalidFormat => GitInitError.corrupted_repository,
        error.FileNotFound => GitInitError.git_command_not_found,
        error.NetworkUnreachable => GitInitError.network_error,
        error.NoSpaceLeft => GitInitError.disk_full,
        else => GitInitError.unknown_error,
    };
}
