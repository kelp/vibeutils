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
    relative, // Smart relative dates like "2 hours ago"
    iso, // ISO format: 2024-01-15 15:30
    @"long-iso", // Long ISO: 2024-01-15 15:30:45.123456789 +0000
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
    color_mode: ColorMode = .auto,
    terminal_width: ?u16 = null, // null means auto-detect
    group_directories_first: bool = false,
    show_inodes: bool = false,
    numeric_ids: bool = false,
    comma_format: bool = false,
    icon_mode: common.icons.IconMode = .auto,
    time_style: TimeStyle = .relative,
    show_git_status: bool = false,
};

/// Represents a directory entry with metadata
pub const Entry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    stat: ?common.file.FileInfo = null,
    symlink_target: ?[]const u8 = null,
    git_status: common.git.GitStatus = .not_in_repo,
    display_width: ?usize = null, // Cached display width for performance

    /// Get the display width of this entry, caching the result for future calls
    pub fn getDisplayWidth(self: *Entry, file_type_indicators: bool, show_icons: bool, show_git_status: bool) usize {
        if (self.display_width) |cached_width| {
            return cached_width;
        }

        // Calculate display width based on entry properties
        var width: usize = 0;

        // Add icon width if enabled
        if (show_icons) {
            width += 2; // Icon + space
        }

        // Add Git status indicator width if enabled
        if (show_git_status and self.git_status != .not_in_repo) {
            width += 2; // Status indicator + space
        }

        // Add filename width (using actual display width for Unicode)
        width += self.name.len;

        // Add file type indicator if enabled
        if (file_type_indicators) {
            switch (self.kind) {
                .directory => width += 1, // '/'
                .sym_link => width += 1, // '@'
                .file => {
                    // Check if executable from stat info
                    if (self.stat) |stat| {
                        if ((stat.mode & common.constants.EXECUTE_BIT) != 0) {
                            width += 1; // '*'
                        }
                    }
                },
                else => {},
            }
        }

        // Cache the calculated width
        self.display_width = width;
        return width;
    }

    /// Reset cached display width (call when entry properties change)
    pub fn resetDisplayWidth(self: *Entry) void {
        self.display_width = null;
    }
};

/// Configuration for sorting directory entries
pub const SortConfig = struct {
    by_time: bool = false,
    by_size: bool = false,
    dirs_first: bool = false,
    reverse: bool = false,
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
    pub fn getFileStatus(self: *const GitContext, filename: []const u8) ?common.git.GitStatus {
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
    pub fn reportInitializationIssues(self: *const GitContext, stderr_writer: anytype, prog_name: []const u8) void {
        if (self.init_error) |err| {
            common.printWarningWithProgram(stderr_writer, prog_name, "git status unavailable: {s}", .{err.getMessage()});
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
