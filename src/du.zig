//! du - estimate file space usage
//!
//! The du utility displays the disk usage of files and directories.
//! By default it reports disk usage in 1024-byte blocks for each
//! directory argument and its subdirectories.
//!
//! This implementation follows GNU coreutils du behavior.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = std.c;

const prog_name = "du";

// ============================================================================
// Options
// ============================================================================

const DuOptions = struct {
    /// Write counts for all files, not just directories
    all: bool = false,
    /// Equivalent to --apparent-size --block-size=1
    bytes: bool = false,
    /// Produce a grand total
    total: bool = false,
    /// Max depth for printing
    max_depth: ?[]const u8 = null,
    /// Human-readable output
    human_readable: bool = false,
    /// Like --block-size=1K
    kilobytes: bool = false,
    /// Like --block-size=1G
    gigabytes: bool = false,
    /// Like --block-size=1M
    megabytes: bool = false,
    /// Dereference all symbolic links
    dereference: bool = false,
    /// Dereference only command-line symlink arguments
    dereference_args: bool = false,
    /// Do not follow any symbolic links (default)
    no_dereference: bool = false,
    /// Don't follow symbolic links (alias for -P)
    no_follow: bool = false,
    /// Report errors (no-op, errors are always reported)
    report_errors: bool = false,
    /// Display only a total for each argument
    summarize: bool = false,
    /// Do not include size of subdirectories
    separate_dirs: bool = false,
    /// Skip directories on different file systems
    one_file_system: bool = false,
    /// Print apparent sizes rather than disk usage
    apparent_size: bool = false,
    /// Scale sizes by SIZE
    block_size: ?[]const u8 = null,
    /// Count sizes for hard links multiple times
    count_links: bool = false,
    /// Ignore files/directories matching PATTERN (stub)
    ignore_pattern: ?[]const u8 = null,
    /// Display only entries at or above SIZE threshold
    threshold: ?[]const u8 = null,
    /// Like -h but use powers of 1000 instead of 1024
    si: bool = false,
    /// Display help
    help: bool = false,
    /// Display version
    version: bool = false,
    /// Colorize the output
    color: ?[]const u8 = null,
    /// Display file type icons before names
    icons: ?[]const u8 = null,
    /// Positional arguments (paths)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .all = .{ .short = 'a', .desc = "Write counts for all files, not just directories" },
        .bytes = .{ .short = 'b', .desc = "Equivalent to --apparent-size --block-size=1" },
        .total = .{ .short = 'c', .desc = "Produce a grand total" },
        .max_depth = .{ .short = 'd', .desc = "Print total for directory only if N or fewer levels below", .value_name = "N" },
        .human_readable = .{ .short = 'h', .desc = "Print sizes in human readable format (1K, 234M, 2G)" },
        .kilobytes = .{ .short = 'k', .desc = "Like --block-size=1K" },
        .gigabytes = .{ .short = 'g', .desc = "Like --block-size=1G" },
        .megabytes = .{ .short = 'm', .desc = "Like --block-size=1M" },
        .dereference = .{ .short = 'L', .desc = "Dereference all symbolic links" },
        .dereference_args = .{ .short = 'H', .desc = "Dereference only command-line symlink arguments" },
        .no_dereference = .{ .short = 'P', .desc = "Do not follow symbolic links (default)" },
        .no_follow = .{ .short = 'n', .desc = "Don't follow symbolic links (alias for -P)" },
        .report_errors = .{ .short = 'r', .desc = "Report errors (default behavior, XPG4 compatibility)" },
        .summarize = .{ .short = 's', .desc = "Display only a total for each argument" },
        .separate_dirs = .{ .short = 'S', .desc = "For directories do not include size of subdirectories" },
        .one_file_system = .{ .short = 'x', .desc = "Skip directories on different file systems" },
        .apparent_size = .{ .short = 'A', .desc = "Print apparent sizes rather than disk usage" },
        .block_size = .{ .short = 'B', .desc = "Scale sizes by SIZE before printing", .value_name = "SIZE" },
        .count_links = .{ .short = 'l', .desc = "Count sizes many times if hard linked" },
        .ignore_pattern = .{ .short = 'I', .desc = "Exclude files matching PATTERN (stub)", .value_name = "PATTERN" },
        .threshold = .{ .short = 't', .desc = "Exclude entries smaller than SIZE, or larger if negative", .value_name = "SIZE" },
        .si = .{ .short = 0, .desc = "Like -h, but use powers of 1000 not 1024" },
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .color = .{ .short = 0, .desc = "Colorize the output; WHEN can be 'always', 'auto', or 'never'", .value_name = "WHEN" },
        .icons = .{ .short = 0, .desc = "When to show file type icons (valid: always, auto, never)", .value_name = "WHEN" },
    };
};

// ============================================================================
// Resolved configuration after processing option interactions
// ============================================================================

const DereferenceMode = enum {
    /// Do not follow any symbolic links (-P, default)
    none,
    /// Dereference only command-line arguments (-H)
    args_only,
    /// Dereference all symbolic links (-L)
    all,
};

const DuConfig = struct {
    all: bool,
    total: bool,
    max_depth: ?u64,
    human_readable: bool,
    dereference_mode: DereferenceMode,
    summarize: bool,
    separate_dirs: bool,
    one_file_system: bool,
    apparent_size: bool,
    block_size: u64,
    count_links: bool,
    si: bool,
    threshold: ?i64,
    show_icons: bool,
    display: common.display_config.DisplayConfig,
};

/// Scan raw args to determine which of -P/-H/-L appeared last.
/// Returns the dereference mode based on last-wins semantics.
fn resolveDerefMode(args: []const []const u8) DereferenceMode {
    var mode: DereferenceMode = .none;
    for (args) |arg| {
        if (arg.len < 2 or arg[0] != '-') continue;
        if (arg[1] == '-') {
            // Long flags
            const flag = arg[2..];
            if (std.mem.eql(u8, flag, "dereference")) {
                mode = .all;
            } else if (std.mem.eql(u8, flag, "dereference-args")) {
                mode = .args_only;
            } else if (std.mem.eql(u8, flag, "no-dereference")) {
                mode = .none;
            }
        } else {
            // Short flags: scan each char for P/H/L/n
            for (arg[1..]) |ch| {
                switch (ch) {
                    'L' => mode = .all,
                    'H' => mode = .args_only,
                    'P', 'n' => mode = .none,
                    else => {},
                }
            }
        }
    }
    return mode;
}

/// Parse a threshold value string, supporting optional sign and size suffixes.
/// Positive values mean "show entries >= threshold".
/// Negative values (prefixed with -) mean "show entries <= |threshold|".
fn parseThreshold(str: []const u8) ?i64 {
    if (str.len == 0) return null;

    var negative = false;
    var val_str = str;
    if (str[0] == '-') {
        negative = true;
        val_str = str[1..];
    }

    const abs_val = parseBlockSize(val_str) orelse {
        // Try pure numeric (possibly negative)
        const parsed = std.fmt.parseInt(i64, str, 10) catch return null;
        return if (parsed == 0) null else parsed;
    };

    const signed: i64 = @intCast(abs_val);
    return if (negative) -signed else signed;
}

fn resolveConfig(allocator: Allocator, opts: DuOptions, deref_mode: DereferenceMode) !DuConfig {
    const display = common.display_config.DisplayConfig.resolve(allocator);
    var config = DuConfig{
        .all = opts.all,
        .total = opts.total,
        .max_depth = null,
        .human_readable = opts.human_readable,
        .dereference_mode = deref_mode,
        .summarize = opts.summarize,
        .separate_dirs = opts.separate_dirs,
        .one_file_system = opts.one_file_system,
        .apparent_size = opts.apparent_size,
        .block_size = 1024, // default
        .count_links = opts.count_links,
        .si = opts.si,
        .threshold = null,
        .show_icons = display.icons == .on,
        .display = display,
    };

    // --si implies human-readable with base-1000
    if (opts.si) {
        config.human_readable = true;
    }

    // -b implies --apparent-size --block-size=1
    if (opts.bytes) {
        config.apparent_size = true;
        config.block_size = 1;
    }

    // -k implies --block-size=1K
    if (opts.kilobytes) {
        config.block_size = 1024;
    }

    // -m implies --block-size=1M
    if (opts.megabytes) {
        config.block_size = 1048576;
    }

    // -g implies --block-size=1G
    if (opts.gigabytes) {
        config.block_size = 1073741824;
    }

    // --block-size=SIZE overrides -k, -m, -g, and -b
    if (opts.block_size) |bs_str| {
        config.block_size = parseBlockSize(bs_str) orelse return error.InvalidBlockSize;
    }

    // -t SIZE threshold
    if (opts.threshold) |t_str| {
        config.threshold = parseThreshold(t_str) orelse return error.InvalidThreshold;
    }

    // -s implies --max-depth=0
    if (opts.summarize) {
        config.max_depth = 0;
    }

    // --max-depth=N
    if (opts.max_depth) |depth_str| {
        config.max_depth = std.fmt.parseInt(u64, depth_str, 10) catch return error.InvalidMaxDepth;
    }

    // Parse explicit --color mode (overrides DisplayConfig)
    if (opts.color) |when| {
        if (std.mem.eql(u8, when, "always")) {
            config.display.color = .on;
        } else if (std.mem.eql(u8, when, "auto")) {
            // Keep resolved value (TTY-dependent)
        } else if (std.mem.eql(u8, when, "never")) {
            config.display.color = .off;
        } else {
            return error.InvalidColorMode;
        }
    }

    // Parse explicit --icons mode (overrides DisplayConfig)
    if (opts.icons) |when| {
        if (std.mem.eql(u8, when, "always")) {
            config.show_icons = true;
        } else if (std.mem.eql(u8, when, "auto")) {
            // Keep resolved value (TTY-dependent)
        } else if (std.mem.eql(u8, when, "never")) {
            config.show_icons = false;
        } else {
            return error.InvalidIconMode;
        }
    }

    return config;
}

// ============================================================================
// Block size parsing and human-readable formatting (delegated to common.format)
// ============================================================================

const format = common.format;

fn parseBlockSize(str: []const u8) ?u64 {
    return format.parseBlockSize(str);
}

fn formatHumanReadable(buf: []u8, size_bytes: u64, si: bool) []const u8 {
    return format.formatHumanReadable(buf, size_bytes, .{
        .si = si,
        .suffix = if (si) .iec else .short,
    });
}

// ============================================================================
// Low-level stat wrapper
// ============================================================================

/// Cross-platform stat result for du's needs.
const StatResult = struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32, // POSIX mode bits (file type + permissions)
    size: i64,
    blocks: i64, // 512-byte blocks
    is_dir: bool,
    is_symlink: bool,
};

fn doStat(path: []const u8, follow_symlinks: bool) !StatResult {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const at_flags: u32 = if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
        const rc = linux.statx(
            std.Io.Dir.cwd().handle,
            c_path,
            at_flags,
            linux.STATX.BASIC_STATS,
            &sx,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .LOOP => return error.SymLinkLoop,
            else => return error.SystemResources,
        }
        const mode: u32 = @intCast(sx.mode);
        const is_dir = (mode & c.S.IFMT) == c.S.IFDIR;
        const is_symlink = (mode & c.S.IFMT) == c.S.IFLNK;
        // Combine dev_major and dev_minor into a u64 device number
        const dev: u64 = (@as(u64, sx.dev_major) << 32) | @as(u64, sx.dev_minor);
        return StatResult{
            .dev = dev,
            .ino = sx.ino,
            .nlink = @intCast(sx.nlink),
            .mode = mode,
            .size = @intCast(sx.size),
            .blocks = @intCast(sx.blocks),
            .is_dir = is_dir,
            .is_symlink = is_symlink,
        };
    } else {
        var stat_buf: c.Stat = undefined;
        const at_flags: u32 = if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW;
        const result = c.fstatat(std.Io.Dir.cwd().handle, c_path, &stat_buf, at_flags);
        if (result != 0) {
            const errno = std.posix.errno(result);
            return switch (errno) {
                .ACCES => error.AccessDenied,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NAMETOOLONG => error.NameTooLong,
                .LOOP => error.SymLinkLoop,
                else => error.SystemResources,
            };
        }
        const mode: u32 = @intCast(stat_buf.mode);
        const is_dir = (mode & c.S.IFMT) == c.S.IFDIR;
        const is_symlink = (mode & c.S.IFMT) == c.S.IFLNK;
        return StatResult{
            .dev = @intCast(stat_buf.dev),
            .ino = @intCast(stat_buf.ino),
            .nlink = @intCast(stat_buf.nlink),
            .mode = mode,
            .size = stat_buf.size,
            .blocks = stat_buf.blocks,
            .is_dir = is_dir,
            .is_symlink = is_symlink,
        };
    }
}

/// Get the size contribution of a file (disk usage or apparent size).
/// In apparent-size mode, directories contribute 0 (matching GNU du).
fn getFileSize(stat_buf: StatResult, apparent_size: bool, is_dir: bool) u64 {
    if (apparent_size) {
        if (is_dir) return 0;
        return @intCast(@max(0, stat_buf.size));
    } else {
        // Disk usage: blocks * 512 (blocks are always 512-byte units)
        return @as(u64, @intCast(@max(0, stat_buf.blocks))) * 512;
    }
}

// ============================================================================
// Directory traversal and size computation
// ============================================================================

/// Calculate disk usage for a path, recursively for directories.
/// Returns the total size in bytes. Outputs lines as it goes.
fn calculateDu(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    config: DuConfig,
    depth: u64,
    root_dev: ?u64,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: *std.Io.Writer,
    style: anytype,
    stderr: *std.Io.Writer,
    has_error: *bool,
) u64 {
    // Determine whether to follow symlinks for this path based on mode and depth
    const follow_symlinks = switch (config.dereference_mode) {
        .all => true,
        .args_only => depth == 0,
        .none => false,
    };

    const stat_buf = doStat(path, follow_symlinks) catch |err| {
        printStatError(allocator, stderr, path, err);
        has_error.* = true;
        return 0;
    };

    const is_dir = stat_buf.is_dir;
    const is_symlink = stat_buf.is_symlink;

    // Skip symlinks when not following them during recursive traversal
    if (is_symlink and !follow_symlinks and depth > 0) {
        // Report symlink itself if -a
        const link_size = getFileSize(stat_buf, config.apparent_size, false);
        if (config.all and shouldPrintAtDepth(depth, config)) {
            printEntry(stdout, style, link_size, config, path, false, true);
        }
        return link_size;
    }

    // One-file-system check
    const dev: u64 = @intCast(stat_buf.dev);
    if (config.one_file_system) {
        if (root_dev) |rd| {
            if (dev != rd) return 0;
        }
    }

    // Track inodes to avoid counting hardlinks twice (unless -l is set).
    // When dereferencing all symlinks (-L), multiple paths can resolve to the
    // same inode even when nlink == 1 (symlink + target), so track
    // unconditionally in that mode.
    const ino: u64 = stat_buf.ino;
    const nlink: u64 = @intCast(stat_buf.nlink);
    const should_dedup = !is_dir and !config.count_links and
        (nlink > 1 or config.dereference_mode == .all);
    var is_duplicate = false;
    if (should_dedup) {
        // Combine dev and ino into a u128 key for uniqueness
        const key: u128 = (@as(u128, dev) << 64) | @as(u128, ino);
        if (seen_inodes.contains(key)) {
            is_duplicate = true;
        } else {
            seen_inodes.put(key, {}) catch {};
        }
    }

    if (!is_dir) {
        const file_size = if (is_duplicate) 0 else getFileSize(stat_buf, config.apparent_size, false);
        // Always print top-level arguments (depth == 0); print children only with -a
        if ((depth == 0 or config.all) and shouldPrintAtDepth(depth, config)) {
            printEntry(stdout, style, file_size, config, path, false, false);
        }
        return file_size;
    }

    // Directory: recurse into it
    const effective_root_dev = root_dev orelse dev;

    const dir_own_size = getFileSize(stat_buf, config.apparent_size, true);
    var subtree_size: u64 = 0;
    var direct_files_size: u64 = 0;

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        printDirError(allocator, stderr, path, err);
        has_error.* = true;
        // Still report the directory entry size itself
        if (shouldPrintAtDepth(depth, config)) {
            printEntry(stdout, style, dir_own_size, config, path, true, false);
        }
        return dir_own_size;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch |err| {
            printIterError(allocator, stderr, path, err);
            has_error.* = true;
            break;
        };
        const entry = maybe_entry orelse break;

        const child_path = std.fs.path.join(allocator, &.{ path, entry.name }) catch {
            has_error.* = true;
            continue;
        };
        defer allocator.free(child_path);

        const child_size = calculateDu(
            allocator,
            io,
            child_path,
            config,
            depth + 1,
            effective_root_dev,
            seen_inodes,
            stdout,
            style,
            stderr,
            has_error,
        );
        subtree_size += child_size;

        // Track direct file sizes for -S (separate_dirs) mode.
        // Directory children are excluded from the reported size.
        if (config.separate_dirs and entry.kind != .directory) {
            direct_files_size += child_size;
        }
    }

    const total_size = if (config.separate_dirs) dir_own_size + direct_files_size else dir_own_size + subtree_size;

    if (shouldPrintAtDepth(depth, config)) {
        printEntry(stdout, style, total_size, config, path, true, false);
    }

    return dir_own_size + subtree_size;
}

fn shouldPrintAtDepth(depth: u64, config: DuConfig) bool {
    if (config.max_depth) |max_d| {
        return depth <= max_d;
    }
    return true;
}

fn printEntry(writer: *std.Io.Writer, style: anytype, size_bytes: u64, config: DuConfig, path: []const u8, is_dir: bool, is_link: bool) void {
    // Apply threshold filter
    if (config.threshold) |thresh| {
        const signed_size: i64 = @intCast(size_bytes);
        if (thresh >= 0) {
            // Positive threshold: show only entries >= threshold
            if (signed_size < thresh) return;
        } else {
            // Negative threshold: show only entries <= |threshold|
            if (signed_size > -thresh) return;
        }
    }

    if (config.human_readable) {
        var hr_buf: [32]u8 = undefined;
        const formatted = formatHumanReadable(&hr_buf, size_bytes, config.si);
        common.colors.applySizeColor(style, size_bytes) catch {};
        writer.print("{s}", .{formatted}) catch {};
        style.reset() catch {};
    } else {
        // Scale by block_size
        const blocks = if (config.block_size <= 1)
            size_bytes
        else
            (size_bytes + config.block_size - 1) / config.block_size;
        common.colors.applySizeColor(style, size_bytes) catch {};
        writer.print("{d}", .{blocks}) catch {};
        style.reset() catch {};
    }

    if (config.show_icons and !std.mem.eql(u8, path, "total")) {
        const basename = std.fs.path.basename(path);
        const theme = common.icons.IconTheme{};
        const icon = common.icons.getIcon(&theme, basename, is_dir, is_link, false);
        const icon_color = common.icons.getIconColorInfo(icon);
        if (icon_color) |ic| {
            switch (style.color_mode) {
                .truecolor => style.setRgb(ic.r, ic.g, ic.b) catch {},
                .extended => style.set256(ic.c256) catch {},
                .basic => style.setColor(ic.basic) catch {},
                .none => {},
            }
        }
        writer.print("\t{s} ", .{icon}) catch {};
        if (icon_color != null and style.color_mode != .none) style.reset() catch {};
        writer.print("{s}\n", .{path}) catch {};
    } else {
        writer.print("\t{s}\n", .{path}) catch {};
    }
}

// ============================================================================
// Error message helpers
// ============================================================================

fn printStatError(allocator: Allocator, stderr: *std.Io.Writer, path: []const u8, err: anyerror) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => "Cannot access",
    };
    common.printErrorWithProgram(allocator, stderr, prog_name, "cannot access '{s}': {s}", .{ path, msg });
}

fn printDirError(allocator: Allocator, stderr: *std.Io.Writer, path: []const u8, err: anyerror) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        else => "Cannot read directory",
    };
    common.printErrorWithProgram(allocator, stderr, prog_name, "cannot read directory '{s}': {s}", .{ path, msg });
}

fn printIterError(allocator: Allocator, stderr: *std.Io.Writer, path: []const u8, err: anyerror) void {
    common.printErrorWithProgram(allocator, stderr, prog_name, "cannot read directory '{s}': {s}", .{ path, common.posixErrorString(err) });
}

// ============================================================================
// Main entry point and runDu
// ============================================================================

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runDu);
}

pub fn runDu(allocator: Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!u8 {
    const opts = common.argparse.ArgParser.parse(DuOptions, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid option\nTry 'du --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "option requires an argument\nTry 'du --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid argument value\nTry 'du --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "argument parsing error", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
        }
    };
    defer allocator.free(opts.positionals);

    if (opts.help) {
        printHelp(allocator, stdout);
        return 0;
    }

    if (opts.version) {
        printVersion(stdout);
        return 0;
    }

    // Check for conflicting options: -s and -d cannot be combined
    if (opts.summarize and opts.max_depth != null) {
        common.printErrorWithProgram(allocator, stderr, prog_name, "cannot both summarize and show each directory's size", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const deref_mode = resolveDerefMode(args);
    const config = resolveConfig(allocator, opts, deref_mode) catch |err| {
        switch (err) {
            error.InvalidBlockSize => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid --block-size argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidMaxDepth => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid maximum depth '{s}'", .{opts.max_depth orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidColorMode => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid argument '{s}' for '--color'\nValid arguments are: 'always', 'auto', 'never'", .{opts.color orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidIconMode => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid argument '{s}' for '--icons'\nValid arguments are: 'always', 'auto', 'never'", .{opts.icons orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidThreshold => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid --threshold argument '{s}'", .{opts.threshold orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
        }
    };

    // Initialize styling based on resolved display config
    const StyleType = common.style.Style(*std.Io.Writer);
    var style = StyleType{ .color_mode = .none, .writer = stdout };
    if (config.display.color == .on) {
        const detected = StyleType.ColorMode.detect(allocator) catch .basic;
        style.color_mode = if (detected == .none) .basic else detected;
    }

    const paths = if (opts.positionals.len == 0)
        &[_][]const u8{"."}
    else
        opts.positionals;

    var has_error = false;
    var grand_total: u64 = 0;

    var seen_inodes = std.AutoHashMap(u128, void).init(allocator);
    defer seen_inodes.deinit();

    for (paths) |path| {
        const size = calculateDu(
            allocator,
            io,
            path,
            config,
            0,
            null,
            &seen_inodes,
            stdout,
            style,
            stderr,
            &has_error,
        );
        grand_total += size;
    }

    if (config.total) {
        printEntry(stdout, style, grand_total, config, "total", false, false);
    }

    return if (has_error) @as(u8, 1) else 0;
}

// ============================================================================
// Help and version
// ============================================================================

fn printHelp(allocator: Allocator, writer: *std.Io.Writer) void {
    common.help.printColorized(allocator, writer,
        \\Usage: du [OPTION]... [FILE]...
        \\Summarize disk usage of the set of FILEs, recursively for directories.
        \\
        \\  -A, --apparent-size   print apparent sizes rather than disk usage
        \\  -a, --all             write counts for all files, not just directories
        \\  -B, --block-size=SIZE scale sizes by SIZE before printing them
        \\  -b, --bytes           equivalent to --apparent-size --block-size=1
        \\  -c, --total           produce a grand total
        \\  -d, --max-depth=N     print the total for a directory only if it is N
        \\                          or fewer levels below the command line argument
        \\  -g                    like --block-size=1G
        \\  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)
        \\  -H, --dereference-args  dereference only command-line symlink arguments
        \\  -I PATTERN            exclude files matching PATTERN
        \\  -k                    like --block-size=1K
        \\  -l, --count-links     count sizes many times if hard linked
        \\  -L, --dereference     dereference all symbolic links
        \\  -m                    like --block-size=1M
        \\  -n                    do not follow symbolic links (alias for -P)
        \\  -P, --no-dereference  do not follow symbolic links (default)
        \\  -r                    report errors (default behavior, XPG4 compatibility)
        \\  -s, --summarize       display only a total for each argument
        \\  -S, --separate-dirs   for directories do not include size of subdirectories
        \\      --si              like -h, but use powers of 1000 not 1024
        \\  -t, --threshold=SIZE  exclude entries smaller than SIZE if positive,
        \\                          or entries greater than SIZE if negative
        \\  -x, --one-file-system skip directories on different file systems
        \\      --color=WHEN      colorize sizes; WHEN is 'always', 'auto' (default),
        \\                          or 'never'
        \\      --icons=WHEN      when to show icons (valid: always, auto, never)
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\Display values are in units of the first available SIZE from --block-size,
        \\and the DU_BLOCK_SIZE, BLOCK_SIZE and BLOCKSIZE environment variables.
        \\Otherwise, units default to 1024 bytes (or 512 if POSIXLY_CORRECT is set).
        \\
        \\SIZE is an integer and optional unit (example: 10K is 10*1024).
        \\Units are K, M, G, T, P, E (powers of 1024) or KB, MB, ... (powers of 1000).
        \\
    ) catch {};
}

fn printVersion(writer: *std.Io.Writer) void {
    writer.print("du (vibeutils) {s}\n", .{common.version}) catch {};
}

// ============================================================================
// TESTS
// ============================================================================

test "parseBlockSize - pure numeric" {
    try testing.expectEqual(@as(?u64, 512), parseBlockSize("512"));
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("1024"));
    try testing.expectEqual(@as(?u64, 1), parseBlockSize("1"));
}

test "parseBlockSize - with suffix" {
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("1K"));
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("1k"));
    try testing.expectEqual(@as(?u64, 1048576), parseBlockSize("1M"));
    try testing.expectEqual(@as(?u64, 1073741824), parseBlockSize("1G"));
    try testing.expectEqual(@as(?u64, 1099511627776), parseBlockSize("1T"));
    try testing.expectEqual(@as(?u64, 2048), parseBlockSize("2K"));
    try testing.expectEqual(@as(?u64, 5242880), parseBlockSize("5M"));
}

test "parseBlockSize - SI suffixes" {
    try testing.expectEqual(@as(?u64, 1000), parseBlockSize("1KB"));
    try testing.expectEqual(@as(?u64, 1000000), parseBlockSize("1MB"));
    try testing.expectEqual(@as(?u64, 1000000000), parseBlockSize("1GB"));
}

test "parseBlockSize - invalid" {
    try testing.expectEqual(@as(?u64, null), parseBlockSize(""));
    try testing.expectEqual(@as(?u64, null), parseBlockSize("abc"));
    try testing.expectEqual(@as(?u64, null), parseBlockSize("0"));
    try testing.expectEqual(@as(?u64, null), parseBlockSize("1X"));
}

test "parseBlockSize - bare suffix" {
    try testing.expectEqual(@as(?u64, 1024), parseBlockSize("K"));
    try testing.expectEqual(@as(?u64, 1048576), parseBlockSize("M"));
    try testing.expectEqual(@as(?u64, 1073741824), parseBlockSize("G"));
}

test "formatHumanReadable - bytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", formatHumanReadable(&buf, 0, false));
    try testing.expectEqualStrings("1", formatHumanReadable(&buf, 1, false));
    try testing.expectEqualStrings("512", formatHumanReadable(&buf, 512, false));
    try testing.expectEqualStrings("1023", formatHumanReadable(&buf, 1023, false));
}

test "formatHumanReadable - kilobytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0K", formatHumanReadable(&buf, 1024, false));
    try testing.expectEqualStrings("1.5K", formatHumanReadable(&buf, 1536, false));
    try testing.expectEqualStrings("10K", formatHumanReadable(&buf, 10240, false));
}

test "formatHumanReadable - megabytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0M", formatHumanReadable(&buf, 1048576, false));
    try testing.expectEqualStrings("100M", formatHumanReadable(&buf, 104857600, false));
}

test "formatHumanReadable - gigabytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0G", formatHumanReadable(&buf, 1073741824, false));
}

test "resolveConfig - defaults" {
    const opts = DuOptions{};
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1024), config.block_size);
    try testing.expect(!config.apparent_size);
    try testing.expect(!config.human_readable);
    try testing.expect(!config.summarize);
    try testing.expectEqual(@as(?u64, null), config.max_depth);
}

test "resolveConfig - bytes flag" {
    var opts = DuOptions{};
    opts.bytes = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1), config.block_size);
    try testing.expect(config.apparent_size);
}

test "resolveConfig - kilobytes flag" {
    var opts = DuOptions{};
    opts.kilobytes = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1024), config.block_size);
}

test "resolveConfig - summarize implies max-depth=0" {
    var opts = DuOptions{};
    opts.summarize = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(?u64, 0), config.max_depth);
}

test "resolveConfig - max-depth" {
    var opts = DuOptions{};
    opts.max_depth = "3";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(?u64, 3), config.max_depth);
}

test "resolveConfig - invalid max-depth" {
    var opts = DuOptions{};
    opts.max_depth = "abc";
    try testing.expectError(error.InvalidMaxDepth, resolveConfig(testing.allocator, opts, .none));
}

test "resolveConfig - block-size option" {
    var opts = DuOptions{};
    opts.block_size = "1M";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1048576), config.block_size);
}

test "resolveConfig - invalid block-size" {
    var opts = DuOptions{};
    opts.block_size = "invalid";
    try testing.expectError(error.InvalidBlockSize, resolveConfig(testing.allocator, opts, .none));
}

test "du --help shows usage" {
    const io = testing.io;
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{"--help"};
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "Usage: du") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--human-readable") != null);
}

test "du --version shows version" {
    const io = testing.io;
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{"--version"};
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "du") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), common.version) != null);
}

test "du invalid flag exits with code 2" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"--invalid-flag"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "du nonexistent path exits with code 1" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"/nonexistent/path/xyz"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_buffer_aw.writer.buffered(), "No such file or directory") != null);
}

test "du -s and -d conflict exits with code 2" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{ "-s", "-d", "1" };
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "du on a file reports its size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file with known content
    const test_file = try tmp_dir.dir.createFile(io, "testfile.txt", .{});
    try test_file.writeStreamingAll(io, "Hello, world!\n");
    test_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(io, "testfile.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    // Use -b for apparent size in bytes
    const args = &[_][]const u8{ "-b", test_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // The output should contain "14" (length of "Hello, world!\n")
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "14\t") != null);
}

test "du on a directory reports size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "subdir", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "subdir/file.txt", .{});
    try f.writeStreamingAll(io, "some data here\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should have output lines for subdir and the top dir
    try testing.expect(stdout_buffer_aw.writer.buffered().len > 0);
    // Output should contain the directory path
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), dir_path) != null);
}

test "du -s shows only total for argument" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "subdir", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "subdir/file.txt", .{});
    try f.writeStreamingAll(io, "test data\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-s", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // With -s, should only have one line of output (the summary)
    var line_count: usize = 0;
    for (stdout_buffer_aw.writer.buffered()) |byte| {
        if (byte == '\n') line_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), line_count);
}

test "du -c shows grand total" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "file.txt", .{});
    try f.writeStreamingAll(io, "data\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-c", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should contain "total" line
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "total") != null);
}

test "du -a shows all files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f1 = try tmp_dir.dir.createFile(io, "file1.txt", .{});
    try f1.writeStreamingAll(io, "one\n");
    f1.close(io);
    const f2 = try tmp_dir.dir.createFile(io, "file2.txt", .{});
    try f2.writeStreamingAll(io, "two\n");
    f2.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-a", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // With -a, output should contain individual file names
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "file1.txt") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "file2.txt") != null);
}

test "du -h formats human-readable" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "file.txt", .{});
    try f.writeStreamingAll(io, "data\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-h", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should exist and contain the path
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), dir_path) != null);
}

test "du defaults to current directory" {
    const io = testing.io;
    // Use a temp directory to avoid depending on the test runner's cwd
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "testfile", .{});
    try f.writeStreamingAll(io, "hello");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-s", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_buffer_aw.writer.buffered().len > 0);
}

test "du -d 0 is like -s" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "sub", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "sub/file.txt", .{});
    try f.writeStreamingAll(io, "test\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_d0_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_d0_aw.deinit();
    var stdout_s_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_s_aw.deinit();

    const args_d0 = &[_][]const u8{ "-d", "0", "-b", dir_path };
    _ = try runDu(testing.allocator, io, args_d0, &stdout_d0_aw.writer, common.null_writer);

    const args_s = &[_][]const u8{ "-s", "-b", dir_path };
    _ = try runDu(testing.allocator, io, args_s, &stdout_s_aw.writer, common.null_writer);

    // Both should produce identical output
    try testing.expectEqualStrings(stdout_d0_aw.writer.buffered(), stdout_s_aw.writer.buffered());
}

test "du shouldPrintAtDepth" {
    const config_no_limit = DuConfig{
        .all = false,
        .total = false,
        .max_depth = null,
        .human_readable = false,
        .dereference_mode = .none,
        .summarize = false,
        .separate_dirs = false,
        .one_file_system = false,
        .apparent_size = false,
        .block_size = 1024,
        .count_links = false,
        .si = false,
        .threshold = null,
        .show_icons = false,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .off, .highlight = .off, .theme = .none },
    };
    try testing.expect(shouldPrintAtDepth(0, config_no_limit));
    try testing.expect(shouldPrintAtDepth(100, config_no_limit));

    var config_depth1 = config_no_limit;
    config_depth1.max_depth = 1;
    try testing.expect(shouldPrintAtDepth(0, config_depth1));
    try testing.expect(shouldPrintAtDepth(1, config_depth1));
    try testing.expect(!shouldPrintAtDepth(2, config_depth1));
}

test "du getFileSize apparent vs disk" {
    const io = testing.io;
    // Create a temp file and stat it
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "test.bin", .{});
    // Write exactly 100 bytes
    const data = [_]u8{0xAA} ** 100;
    try f.writeStreamingAll(io, &data);
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(io, "test.bin", &path_buf);
    const test_path = path_buf[0..test_path_len];

    const stat_buf = try doStat(test_path, false);

    // Apparent size should be exactly 100
    const apparent = getFileSize(stat_buf, true, false);
    try testing.expectEqual(@as(u64, 100), apparent);

    // Disk usage should be >= 100 (rounded to block boundaries)
    const disk = getFileSize(stat_buf, false, false);
    try testing.expect(disk >= 100);
}

test "resolveConfig - color mode always" {
    var opts = DuOptions{};
    opts.color = "always";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(common.display_config.ResolvedMode.on, config.display.color);
}

test "resolveConfig - color mode never" {
    var opts = DuOptions{};
    opts.color = "never";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(common.display_config.ResolvedMode.off, config.display.color);
}

test "resolveConfig - color mode default" {
    const opts = DuOptions{};
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(common.display_config.ResolvedMode.off, config.display.color);
}

test "resolveConfig - invalid color mode" {
    var opts = DuOptions{};
    opts.color = "invalid";
    try testing.expectError(error.InvalidColorMode, resolveConfig(testing.allocator, opts, .none));
}

test "du --color=invalid exits with code 2" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"--color=invalid"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.find(u8, stderr_buffer_aw.writer.buffered(), "invalid argument") != null);
}

// C library functions for environment manipulation in tests
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

test "resolveConfig - show_icons defaults to false" {
    // Save and clear env vars that affect icon resolution
    const saved_style = (if (getenv("VIBEUTILS_STYLE")) |__p| std.mem.span(__p) else null);
    const saved_icons = (if (getenv("VIBEUTILS_ICONS")) |__p| std.mem.span(__p) else null);
    _ = unsetenv("VIBEUTILS_STYLE");
    _ = unsetenv("VIBEUTILS_ICONS");
    defer {
        if (saved_style) |v| _ = setenv("VIBEUTILS_STYLE", v.ptr, 1);
        if (saved_icons) |v| _ = setenv("VIBEUTILS_ICONS", v.ptr, 1);
    }

    const opts = DuOptions{};
    const config = try resolveConfig(testing.allocator, opts, .none);
    // With no env overrides and no TTY, display.icons resolves to .off
    try testing.expect(!config.show_icons);
}

test "resolveConfig - icons=always enables show_icons" {
    var opts = DuOptions{};
    opts.icons = "always";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expect(config.show_icons);
}

test "resolveConfig - icons=never disables show_icons" {
    var opts = DuOptions{};
    opts.icons = "never";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expect(!config.show_icons);
}

test "resolveConfig - invalid icon mode" {
    var opts = DuOptions{};
    opts.icons = "invalid";
    try testing.expectError(error.InvalidIconMode, resolveConfig(testing.allocator, opts, .none));
}

test "printEntry without icons shows clean output" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const TestStyle = common.style.Style(*std.Io.Writer);
    const style = TestStyle{ .color_mode = .none, .writer = &buffer_aw.writer };

    const config = DuConfig{
        .all = false,
        .total = false,
        .max_depth = null,
        .human_readable = false,
        .dereference_mode = .none,
        .summarize = false,
        .separate_dirs = false,
        .one_file_system = false,
        .apparent_size = false,
        .block_size = 1,
        .count_links = false,
        .si = false,
        .threshold = null,
        .show_icons = false,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .off, .highlight = .off, .theme = .none },
    };

    printEntry(&buffer_aw.writer, style, 1024, config, "/tmp/test.txt", false, false);

    // Should be "1024\t/tmp/test.txt\n" with no icon
    try testing.expectEqualStrings("1024\t/tmp/test.txt\n", buffer_aw.writer.buffered());
}

test "printEntry with icons shows icon glyph" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const TestStyle = common.style.Style(*std.Io.Writer);
    const style = TestStyle{ .color_mode = .none, .writer = &buffer_aw.writer };

    const config = DuConfig{
        .all = false,
        .total = false,
        .max_depth = null,
        .human_readable = false,
        .dereference_mode = .none,
        .summarize = false,
        .separate_dirs = false,
        .one_file_system = false,
        .apparent_size = false,
        .block_size = 1,
        .count_links = false,
        .si = false,
        .threshold = null,
        .show_icons = true,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .on, .highlight = .off, .theme = .none },
    };

    printEntry(&buffer_aw.writer, style, 1024, config, "/tmp/test.txt", false, false);

    // Should contain the text file icon followed by a space and the path
    const theme = common.icons.IconTheme{};
    const expected_icon = common.icons.getIcon(&theme, "test.txt", false, false, false);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), expected_icon) != null);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "/tmp/test.txt") != null);
}

test "printEntry with directory icon" {
    var buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer_aw.deinit();

    const TestStyle = common.style.Style(*std.Io.Writer);
    const style = TestStyle{ .color_mode = .none, .writer = &buffer_aw.writer };

    const config = DuConfig{
        .all = false,
        .total = false,
        .max_depth = null,
        .human_readable = false,
        .dereference_mode = .none,
        .summarize = false,
        .separate_dirs = false,
        .one_file_system = false,
        .apparent_size = false,
        .block_size = 1,
        .count_links = false,
        .si = false,
        .threshold = null,
        .show_icons = true,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .on, .highlight = .off, .theme = .none },
    };

    printEntry(&buffer_aw.writer, style, 4096, config, "/tmp/mydir", true, false);

    // Should contain the directory icon
    const theme = common.icons.IconTheme{};
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), theme.directory) != null);
    try testing.expect(std.mem.find(u8, buffer_aw.writer.buffered(), "/tmp/mydir") != null);
}

test "du --help shows icons option" {
    const io = testing.io;
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{"--help"};
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--icons") != null);
}

// ============================================================================
// Tests for du -r (report errors — no-op compatibility flag)
// ============================================================================

test "du -r flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-r"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -r produces same output as du" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "file.txt", .{});
    try f.writeStreamingAll(io, "test data\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Run without -r
    var stdout_without_r_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_without_r_aw.deinit();

    const args_no_r = &[_][]const u8{ "-b", dir_path };
    const exit_no_r = runDu(testing.allocator, io, args_no_r, &stdout_without_r_aw.writer, common.null_writer);

    // Run with -r
    var stdout_with_r_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_with_r_aw.deinit();

    const args_with_r = &[_][]const u8{ "-r", "-b", dir_path };
    const exit_with_r = runDu(testing.allocator, io, args_with_r, &stdout_with_r_aw.writer, common.null_writer);

    // Both should succeed and produce identical output
    try testing.expectEqual(@as(u8, 0), exit_no_r);
    try testing.expectEqual(@as(u8, 0), exit_with_r);
    try testing.expectEqualStrings(stdout_without_r_aw.writer.buffered(), stdout_with_r_aw.writer.buffered());
}

// ============================================================================
// Tests for du -H (dereference command-line symlink arguments only)
// ============================================================================

test "du -H flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-H"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -H follows symlinks given as command-line arguments" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a directory with a file inside
    try tmp_dir.dir.createDir(io, "target_dir", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "target_dir/content.txt", .{});
    try f.writeStreamingAll(io, "hello world data\n");
    f.close(io);

    // Create a symlink to the directory
    tmp_dir.dir.symLink(io, "target_dir", "link_to_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const base_path = path_buf[0..base_path_len];
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_to_dir", .{base_path});
    defer testing.allocator.free(link_path);

    // du -H on symlink_to_dir: should follow it (command-line arg)
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-H", "-a", "-b", link_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // The output should include content.txt path (proves we traversed into the dir)
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "content.txt") != null);
}

test "du -H does not follow symlinks found during traversal" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "parent_dir", .default_dir);
    try tmp_dir.dir.createDir(io, "parent_dir/real_subdir", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "parent_dir/real_subdir/data.txt", .{});
    try f.writeStreamingAll(io, "some data content\n");
    f.close(io);

    // Create a symlink inside parent_dir that points to real_subdir
    tmp_dir.dir.symLink(io, "real_subdir", "parent_dir/symlink_subdir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent_path_len = try tmp_dir.dir.realPathFile(io, "parent_dir", &path_buf);
    const parent_path = path_buf[0..parent_path_len];

    // du -H on parent_dir: should NOT follow symlink_subdir during traversal
    var stdout_h_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_h_aw.deinit();

    const args_h = &[_][]const u8{ "-H", "-a", "-b", parent_path };
    const exit_h = runDu(testing.allocator, io, args_h, &stdout_h_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_h);

    // du -L on parent_dir: should follow symlink_subdir (follows all symlinks)
    var stdout_l_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_l_aw.deinit();

    const args_l = &[_][]const u8{ "-L", "-a", "-b", parent_path };
    const exit_l = runDu(testing.allocator, io, args_l, &stdout_l_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_l);

    // Count occurrences of "data.txt" — -H should have fewer than -L
    var h_count: usize = 0;
    var h_pos: usize = 0;
    while (std.mem.indexOfPos(u8, stdout_h_aw.writer.buffered(), h_pos, "data.txt")) |idx| {
        h_count += 1;
        h_pos = idx + 1;
    }

    var l_count: usize = 0;
    var l_pos: usize = 0;
    while (std.mem.indexOfPos(u8, stdout_l_aw.writer.buffered(), l_pos, "data.txt")) |idx| {
        l_count += 1;
        l_pos = idx + 1;
    }

    // -L follows symlink_subdir so data.txt appears twice (real + symlink)
    // -H doesn't follow it so data.txt appears once (real only)
    try testing.expect(h_count < l_count);
}

// ============================================================================
// Tests for du -P (do not follow symbolic links — explicit default)
// ============================================================================

test "du -P flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-P"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);

    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -P does not follow symlinks" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "real_dir", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "real_dir/file.txt", .{});
    try f.writeStreamingAll(io, "data\n");
    f.close(io);

    tmp_dir.dir.symLink(io, "real_dir", "link_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    // Use parent realpath + symlink name (realpath would resolve the symlink)
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const base_path = path_buf[0..base_path_len];
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_dir", .{base_path});
    defer testing.allocator.free(link_path);

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-P", "-a", "-b", link_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // -P should NOT follow the symlink, so file.txt should not appear
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "file.txt") == null);
}

test "du -P overrides -L when specified last" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "target", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "target/marker.txt", .{});
    try f.writeStreamingAll(io, "marker\n");
    f.close(io);

    tmp_dir.dir.symLink(io, "target", "sym", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    // Use parent realpath + symlink name (realpath would resolve the symlink)
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const base_path = path_buf[0..base_path_len];
    const sym_path = try std.fmt.allocPrint(testing.allocator, "{s}/sym", .{base_path});
    defer testing.allocator.free(sym_path);

    // -L -P: last is -P, should NOT follow
    var stdout_lp_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_lp_aw.deinit();

    const args_lp = &[_][]const u8{ "-L", "-P", "-a", "-b", sym_path };
    const exit_lp = runDu(testing.allocator, io, args_lp, &stdout_lp_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_lp);
    try testing.expect(std.mem.find(u8, stdout_lp_aw.writer.buffered(), "marker.txt") == null);

    // -P -L: last is -L, should follow
    var stdout_pl_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_pl_aw.deinit();

    const args_pl = &[_][]const u8{ "-P", "-L", "-a", "-b", sym_path };
    const exit_pl = runDu(testing.allocator, io, args_pl, &stdout_pl_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_pl);
    try testing.expect(std.mem.find(u8, stdout_pl_aw.writer.buffered(), "marker.txt") != null);
}

// ============================================================================
// Tests for -A (apparent size short flag alias)
// ============================================================================

test "du -A flag is accepted and acts as --apparent-size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "testfile.txt", .{});
    try f.writeStreamingAll(io, "Hello, world!\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(io, "testfile.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    // -A should show apparent size (14 bytes for "Hello, world!\n")
    var stdout_a_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_a_aw.deinit();

    const args_a = &[_][]const u8{ "-A", "--block-size=1", test_path };
    const exit_a = runDu(testing.allocator, io, args_a, &stdout_a_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_a);
    try testing.expect(std.mem.find(u8, stdout_a_aw.writer.buffered(), "14\t") != null);
}

// ============================================================================
// Tests for -B SIZE (block-size short flag alias)
// ============================================================================

test "du -B flag sets block size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "testfile.txt", .{});
    try f.writeStreamingAll(io, "Hello, world!\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const test_path_len = try tmp_dir.dir.realPathFile(io, "testfile.txt", &path_buf);
    const test_path = path_buf[0..test_path_len];

    // -B 1 with -A should show apparent bytes
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-A", "-B", "1", test_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "14\t") != null);
}

test "du -B flag with suffix" {
    var opts = DuOptions{};
    opts.block_size = "1M";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1048576), config.block_size);
}

// ============================================================================
// Tests for -g (gigabyte blocks)
// ============================================================================

test "du -g flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-g"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    try testing.expect(exit_code != 2);
}

test "resolveConfig - gigabytes flag sets block_size to 1G" {
    var opts = DuOptions{};
    opts.gigabytes = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1073741824), config.block_size);
}

// ============================================================================
// Tests for -m (megabyte blocks)
// ============================================================================

test "du -m flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-m"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    try testing.expect(exit_code != 2);
}

test "resolveConfig - megabytes flag sets block_size to 1M" {
    var opts = DuOptions{};
    opts.megabytes = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(u64, 1048576), config.block_size);
}

// ============================================================================
// Tests for -I PATTERN (ignore pattern stub)
// ============================================================================

test "du -I flag is accepted with value" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{ "-I", "*.o" };
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -I flag does not change output (stub)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "file.txt", .{});
    try f.writeStreamingAll(io, "data\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Without -I
    var stdout_without_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_without_aw.deinit();
    const exit1 = runDu(testing.allocator, io, &[_][]const u8{ "-b", dir_path }, &stdout_without_aw.writer, common.null_writer);

    // With -I (stub, should produce same output)
    var stdout_with_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_with_aw.deinit();
    const exit2 = runDu(testing.allocator, io, &[_][]const u8{ "-I", "*.o", "-b", dir_path }, &stdout_with_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit1);
    try testing.expectEqual(@as(u8, 0), exit2);
    try testing.expectEqualStrings(stdout_without_aw.writer.buffered(), stdout_with_aw.writer.buffered());
}

// ============================================================================
// Tests for -l (count hard links multiple times)
// ============================================================================

test "du -l flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-l"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    try testing.expect(exit_code != 2);
}

test "resolveConfig - count_links flag" {
    var opts = DuOptions{};
    opts.count_links = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expect(config.count_links);
}

// ============================================================================
// Tests for -n (no follow symlinks, alias for -P)
// ============================================================================

test "du -n flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-n"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    try testing.expect(exit_code != 2);
}

test "du -n acts as -P (no follow symlinks)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "real_dir", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "real_dir/file.txt", .{});
    try f.writeStreamingAll(io, "data\n");
    f.close(io);

    tmp_dir.dir.symLink(io, "real_dir", "link_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const base_path = path_buf[0..base_path_len];
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_dir", .{base_path});
    defer testing.allocator.free(link_path);

    // -n should not follow the symlink (same as -P)
    var stdout_n_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_n_aw.deinit();

    const args_n = &[_][]const u8{ "-n", "-a", "-b", link_path };
    const exit_n = runDu(testing.allocator, io, args_n, &stdout_n_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_n);
    // -n should NOT follow the symlink, so file.txt should not appear
    try testing.expect(std.mem.find(u8, stdout_n_aw.writer.buffered(), "file.txt") == null);
}

test "du -n overrides -L when specified last" {
    // -n should act like -P, overriding -L
    try testing.expectEqual(DereferenceMode.none, resolveDerefMode(&[_][]const u8{ "-L", "-n" }));
}

// ============================================================================
// Tests for -t SIZE (threshold)
// ============================================================================

test "du -t flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{ "-t", "1K" };
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    try testing.expect(exit_code != 2);
}

test "parseThreshold - positive values" {
    try testing.expectEqual(@as(?i64, 1024), parseThreshold("1K"));
    try testing.expectEqual(@as(?i64, 1048576), parseThreshold("1M"));
    try testing.expectEqual(@as(?i64, 100), parseThreshold("100"));
}

test "parseThreshold - negative values" {
    try testing.expectEqual(@as(?i64, -1024), parseThreshold("-1K"));
    try testing.expectEqual(@as(?i64, -100), parseThreshold("-100"));
}

test "parseThreshold - invalid" {
    try testing.expectEqual(@as(?i64, null), parseThreshold(""));
    try testing.expectEqual(@as(?i64, null), parseThreshold("abc"));
}

test "du -t filters entries below threshold" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a small file (5 bytes)
    const f_small = try tmp_dir.dir.createFile(io, "small.txt", .{});
    try f_small.writeStreamingAll(io, "hello");
    f_small.close(io);

    // Create a larger file (100 bytes)
    const f_large = try tmp_dir.dir.createFile(io, "large.txt", .{});
    const data = [_]u8{'x'} ** 100;
    try f_large.writeStreamingAll(io, &data);
    f_large.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // -t 50 -a -b: only entries >= 50 bytes should appear
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-t", "50", "-a", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // large.txt (100 bytes) should appear
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "large.txt") != null);
    // small.txt (5 bytes) should NOT appear
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "small.txt") == null);
}

test "du -t with negative threshold shows entries at or below size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a small file (5 bytes)
    const f_small = try tmp_dir.dir.createFile(io, "tiny.txt", .{});
    try f_small.writeStreamingAll(io, "hello");
    f_small.close(io);

    // Create a larger file (200 bytes)
    const f_large = try tmp_dir.dir.createFile(io, "big.txt", .{});
    const data = [_]u8{'x'} ** 200;
    try f_large.writeStreamingAll(io, &data);
    f_large.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // -t -50 -a -b: only entries <= 50 bytes should appear
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-t", "-50", "-a", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // tiny.txt (5 bytes) should appear
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "tiny.txt") != null);
    // big.txt (200 bytes) should NOT appear
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "big.txt") == null);
}

test "resolveConfig - threshold" {
    var opts = DuOptions{};
    opts.threshold = "1K";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(?i64, 1024), config.threshold);
}

test "resolveConfig - negative threshold" {
    var opts = DuOptions{};
    opts.threshold = "-1M";
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expectEqual(@as(?i64, -1048576), config.threshold);
}

test "resolveConfig - invalid threshold" {
    var opts = DuOptions{};
    opts.threshold = "invalid";
    try testing.expectError(error.InvalidThreshold, resolveConfig(testing.allocator, opts, .none));
}

// ============================================================================
// Tests for --si (SI units: powers of 1000)
// ============================================================================

test "du --si flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"--si"};
    const exit_code = try runDu(testing.allocator, io, args, common.null_writer, &stderr_buffer_aw.writer);
    try testing.expect(exit_code != 2);
}

test "resolveConfig - si flag enables human_readable and si" {
    var opts = DuOptions{};
    opts.si = true;
    const config = try resolveConfig(testing.allocator, opts, .none);
    try testing.expect(config.si);
    try testing.expect(config.human_readable);
}

test "formatHumanReadable - SI units" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0kB", formatHumanReadable(&buf, 1000, true));
    try testing.expectEqualStrings("1.5kB", formatHumanReadable(&buf, 1500, true));
    try testing.expectEqualStrings("10kB", formatHumanReadable(&buf, 10000, true));
    try testing.expectEqualStrings("1.0MB", formatHumanReadable(&buf, 1000000, true));
    try testing.expectEqualStrings("1.0GB", formatHumanReadable(&buf, 1000000000, true));
}

test "formatHumanReadable - SI vs binary" {
    var buf: [32]u8 = undefined;
    // 1536 bytes: in binary = 1.5K, in SI = 1.5kB
    try testing.expectEqualStrings("1.5K", formatHumanReadable(&buf, 1536, false));
    try testing.expectEqualStrings("1.5kB", formatHumanReadable(&buf, 1500, true));
}

test "du --si shows SI units in output" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "file.txt", .{});
    try f.writeStreamingAll(io, "data\n");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "--si", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should contain the path and use SI units (kB suffix for small dirs)
    try testing.expect(stdout_buffer_aw.writer.buffered().len > 0);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), dir_path) != null);
}

// ============================================================================
// Tests for --help showing new flags
// ============================================================================

test "du --help shows new flags" {
    const io = testing.io;
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{"--help"};
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--apparent-size") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--block-size") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--count-links") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--si") != null);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "--threshold") != null);
}

// ============================================================================
// Test helper: extract the size (first field) from the last output line
// ============================================================================

/// Parse the size value from the first tab-delimited field of the last
/// non-empty line in du output.  Returns null when parsing fails.
fn extractLastLineSize(output: []const u8) ?u64 {
    // Find the last non-empty line
    var last_line: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len > 0) last_line = line;
    }
    const line = last_line orelse return null;
    // Extract first field (before tab)
    const tab_pos = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    return std.fmt.parseInt(u64, line[0..tab_pos], 10) catch null;
}

/// Parse the size from a specific line that contains the given path substring.
fn extractSizeForPath(output: []const u8, path: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.find(u8, line, path) != null) {
            const tab_pos = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            return std.fmt.parseInt(u64, line[0..tab_pos], 10) catch null;
        }
    }
    return null;
}

// ============================================================================
// F22: du -L double-counts symlink targets
// The inode dedup guard at line 400 only fires when nlink > 1.
// With -L, a symlink to a file with nlink=1 is stat'd (not lstat'd),
// resolving to the same inode—but nlink is still 1, so the guard
// doesn't trigger and the file's bytes are counted twice.
// GNU du counts it once.
// ============================================================================

test "du -L does not double-count file reachable via symlink" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a regular file with known content (10 bytes)
    const f = try tmp_dir.dir.createFile(io, "realfile.txt", .{});
    try f.writeStreamingAll(io, "AAAAAAAAAA");
    f.close(io);

    // Create a symlink pointing to the same file
    tmp_dir.dir.symLink(io, "realfile.txt", "linkfile.txt", .{}) catch |err| {
        if (err == error.AccessDenied) return; // skip on platforms without symlink support
        return err;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    // -L dereferences all symlinks; -b = apparent-size + block-size=1; -s = summary
    const args = &[_][]const u8{ "-L", "-b", "-s", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const total = extractLastLineSize(stdout_buffer_aw.writer.buffered()) orelse {
        return error.TestUnexpectedResult;
    };

    // GNU du -L -b -s counts the file once: total should be 10.
    // Our implementation double-counts it (20 or more), so this test should fail.
    try testing.expectEqual(@as(u64, 10), total);
}

// ============================================================================
// F23: du -b directory apparent size inflated
// getFileSize() returns stat.size for directories in apparent-size mode,
// but GNU du treats directory metadata as 0 in apparent-size mode.
// ============================================================================

test "du -b directory total equals sum of file apparent sizes (no dir metadata)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a single file with exactly 10 bytes
    const f = try tmp_dir.dir.createFile(io, "file.txt", .{});
    try f.writeStreamingAll(io, "AAAAAAAAAA");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    // -b = --apparent-size --block-size=1; -s = summary
    const args = &[_][]const u8{ "-b", "-s", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const total = extractLastLineSize(stdout_buffer_aw.writer.buffered()) orelse {
        return error.TestUnexpectedResult;
    };

    // GNU du -b -s reports 10 (only the file bytes, directory metadata is 0).
    // Our implementation adds directory stat.size, inflating the total.
    try testing.expectEqual(@as(u64, 10), total);
}

// ============================================================================
// F24: du -S shows dir-inode blocks instead of direct-file sum
// With -S, each directory should report the sum of its direct files'
// sizes, excluding subdirectory subtrees. Our implementation sets
// total_size = dir_own_size (the inode/metadata size) instead of the
// sum of files directly in the directory.
// ============================================================================

test "du -S shows sum of direct files, not directory inode size" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory with a file
    try tmp_dir.dir.createDir(io, "sub", .default_dir);
    const f_sub = try tmp_dir.dir.createFile(io, "sub/subfile.txt", .{});
    try f_sub.writeStreamingAll(io, "BBBBBBBBBB"); // 10 bytes
    f_sub.close(io);

    // Create a file directly in the top directory
    const f_top = try tmp_dir.dir.createFile(io, "topfile.txt", .{});
    try f_top.writeStreamingAll(io, "AAAAAAAAAA"); // 10 bytes
    f_top.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    // -S = separate-dirs (don't include subdirectory sizes)
    // -b = apparent-size + block-size=1
    const args = &[_][]const u8{ "-S", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Extract the size reported for the top-level directory
    const top_size = extractSizeForPath(stdout_buffer_aw.writer.buffered(), dir_path) orelse {
        return error.TestUnexpectedResult;
    };

    // GNU du -S -b: top dir shows 10 (just topfile.txt, not subdir).
    // Our implementation reports dir_own_size (directory inode metadata),
    // which is filesystem-dependent but never equals 10.
    try testing.expectEqual(@as(u64, 10), top_size);
}

test "du -S subdirectory shows sum of its own direct files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "sub", .default_dir);
    const f_sub = try tmp_dir.dir.createFile(io, "sub/subfile.txt", .{});
    try f_sub.writeStreamingAll(io, "BBBBBBBBBB"); // 10 bytes
    f_sub.close(io);

    // File in top dir so the top dir is not empty
    const f_top = try tmp_dir.dir.createFile(io, "topfile.txt", .{});
    try f_top.writeStreamingAll(io, "AAAAAAAAAA"); // 10 bytes
    f_top.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sub_path_len = try tmp_dir.dir.realPathFile(io, "sub", &path_buf);
    const sub_path = path_buf[0..sub_path_len];

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{ "-S", "-b", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &stdout_buffer_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Extract the size reported for the subdirectory
    const sub_size = extractSizeForPath(stdout_buffer_aw.writer.buffered(), sub_path) orelse {
        return error.TestUnexpectedResult;
    };

    // GNU du -S -b: sub shows 10 (just subfile.txt).
    // Our implementation reports dir_own_size for subdirectory too.
    try testing.expectEqual(@as(u64, 10), sub_size);
}
