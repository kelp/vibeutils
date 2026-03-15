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
    /// Dereference all symbolic links
    dereference: bool = false,
    /// Dereference only command-line symlink arguments
    dereference_args: bool = false,
    /// Do not follow any symbolic links (default)
    no_dereference: bool = false,
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
        .dereference = .{ .short = 'L', .desc = "Dereference all symbolic links" },
        .dereference_args = .{ .short = 'H', .desc = "Dereference only command-line symlink arguments" },
        .no_dereference = .{ .short = 'P', .desc = "Do not follow symbolic links (default)" },
        .report_errors = .{ .short = 'r', .desc = "Report errors (default behavior, XPG4 compatibility)" },
        .summarize = .{ .short = 's', .desc = "Display only a total for each argument" },
        .separate_dirs = .{ .short = 'S', .desc = "For directories do not include size of subdirectories" },
        .one_file_system = .{ .short = 'x', .desc = "Skip directories on different file systems" },
        .apparent_size = .{ .short = 0, .desc = "Print apparent sizes rather than disk usage" },
        .block_size = .{ .short = 0, .desc = "Scale sizes by SIZE before printing", .value_name = "SIZE" },
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
            // Short flags: scan each char for P/H/L
            for (arg[1..]) |ch| {
                switch (ch) {
                    'L' => mode = .all,
                    'H' => mode = .args_only,
                    'P' => mode = .none,
                    else => {},
                }
            }
        }
    }
    return mode;
}

fn resolveConfig(opts: DuOptions, deref_mode: DereferenceMode) !DuConfig {
    const display = common.display_config.DisplayConfig.resolve(std.heap.c_allocator);
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
        .show_icons = display.icons == .on,
        .display = display,
    };

    // -b implies --apparent-size --block-size=1
    if (opts.bytes) {
        config.apparent_size = true;
        config.block_size = 1;
    }

    // -k implies --block-size=1K
    if (opts.kilobytes) {
        config.block_size = 1024;
    }

    // --block-size=SIZE overrides -k and -b
    if (opts.block_size) |bs_str| {
        config.block_size = parseBlockSize(bs_str) orelse return error.InvalidBlockSize;
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
// Block size parsing
// ============================================================================

fn parseBlockSize(str: []const u8) ?u64 {
    if (str.len == 0) return null;

    // Try pure numeric
    if (std.fmt.parseInt(u64, str, 10)) |val| {
        return if (val == 0) null else val;
    } else |_| {}

    // Try numeric with suffix
    var num_end: usize = 0;
    while (num_end < str.len and (std.ascii.isDigit(str[num_end]) or str[num_end] == '.')) : (num_end += 1) {}

    const base_val: u64 = if (num_end == 0)
        1
    else
        std.fmt.parseInt(u64, str[0..num_end], 10) catch return null;

    if (num_end >= str.len) return null;

    const suffix = str[num_end..];
    const multiplier: u64 = if (std.mem.eql(u8, suffix, "K") or std.mem.eql(u8, suffix, "k"))
        1024
    else if (std.mem.eql(u8, suffix, "M") or std.mem.eql(u8, suffix, "m"))
        1024 * 1024
    else if (std.mem.eql(u8, suffix, "G") or std.mem.eql(u8, suffix, "g"))
        1024 * 1024 * 1024
    else if (std.mem.eql(u8, suffix, "T") or std.mem.eql(u8, suffix, "t"))
        1024 * 1024 * 1024 * 1024
    else if (std.mem.eql(u8, suffix, "KB"))
        1000
    else if (std.mem.eql(u8, suffix, "MB"))
        1000 * 1000
    else if (std.mem.eql(u8, suffix, "GB"))
        1000 * 1000 * 1000
    else if (std.mem.eql(u8, suffix, "TB"))
        1000 * 1000 * 1000 * 1000
    else
        return null;

    return base_val * multiplier;
}

// ============================================================================
// Human-readable formatting
// ============================================================================

fn formatHumanReadable(buf: []u8, size_bytes: u64) []const u8 {
    const units = [_][]const u8{ "", "K", "M", "G", "T", "P", "E" };
    var value: f64 = @floatFromInt(size_bytes);
    var unit_idx: usize = 0;

    while (value >= 1024.0 and unit_idx + 1 < units.len) {
        value /= 1024.0;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        // Plain bytes - no decimal
        return std.fmt.bufPrint(buf, "{d}", .{size_bytes}) catch "?";
    } else if (value < 10.0) {
        // One decimal place for values < 10
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, units[unit_idx] }) catch "?";
    } else {
        // No decimal for values >= 10
        const rounded: u64 = @intFromFloat(@round(value));
        return std.fmt.bufPrint(buf, "{d}{s}", .{ rounded, units[unit_idx] }) catch "?";
    }
}

// ============================================================================
// Low-level stat wrapper
// ============================================================================

fn doStat(path: []const u8, follow_symlinks: bool) !c.Stat {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];

    var stat_buf: c.Stat = undefined;
    const flags: u32 = if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW;
    const result = c.fstatat(std.fs.cwd().fd, c_path, &stat_buf, flags);
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
    return stat_buf;
}

/// Get the size contribution of a file (disk usage or apparent size)
fn getFileSize(stat_buf: c.Stat, apparent_size: bool) u64 {
    if (apparent_size) {
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
    path: []const u8,
    config: DuConfig,
    depth: u64,
    root_dev: ?u64,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: anytype,
    style: anytype,
    stderr: anytype,
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

    const mode = stat_buf.mode;
    const is_dir = (mode & c.S.IFMT) == c.S.IFDIR;
    const is_symlink = (mode & c.S.IFMT) == c.S.IFLNK;

    // Skip symlinks when not following them during recursive traversal
    if (is_symlink and !follow_symlinks and depth > 0) {
        // Report symlink itself if -a
        const link_size = getFileSize(stat_buf, config.apparent_size);
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

    // Track inodes to avoid counting hardlinks twice
    const ino: u64 = stat_buf.ino;
    const nlink: u64 = @intCast(stat_buf.nlink);
    if (nlink > 1 and !is_dir) {
        // Combine dev and ino into a u128 key for uniqueness
        const key: u128 = (@as(u128, dev) << 64) | @as(u128, ino);
        if (seen_inodes.contains(key)) {
            return 0;
        }
        seen_inodes.put(key, {}) catch {};
    }

    if (!is_dir) {
        const file_size = getFileSize(stat_buf, config.apparent_size);
        // Always print top-level arguments (depth == 0); print children only with -a
        if ((depth == 0 or config.all) and shouldPrintAtDepth(depth, config)) {
            printEntry(stdout, style, file_size, config, path, false, false);
        }
        return file_size;
    }

    // Directory: recurse into it
    const effective_root_dev = root_dev orelse dev;

    const dir_own_size = getFileSize(stat_buf, config.apparent_size);
    var subtree_size: u64 = 0;

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        printDirError(allocator, stderr, path, err);
        has_error.* = true;
        // Still report the directory entry size itself
        if (shouldPrintAtDepth(depth, config)) {
            printEntry(stdout, style, dir_own_size, config, path, true, false);
        }
        return dir_own_size;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next() catch |err| {
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
    }

    const total_size = if (config.separate_dirs) dir_own_size else dir_own_size + subtree_size;

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

fn printEntry(writer: anytype, style: anytype, size_bytes: u64, config: DuConfig, path: []const u8, is_dir: bool, is_link: bool) void {
    if (config.human_readable) {
        var hr_buf: [32]u8 = undefined;
        const formatted = formatHumanReadable(&hr_buf, size_bytes);
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

fn printStatError(allocator: Allocator, stderr: anytype, path: []const u8, err: anyerror) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => "Cannot access",
    };
    common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "cannot access '{s}': {s}", .{ path, msg });
}

fn printDirError(allocator: Allocator, stderr: anytype, path: []const u8, err: anyerror) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        else => "Cannot read directory",
    };
    common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "cannot read directory '{s}': {s}", .{ path, msg });
}

fn printIterError(allocator: Allocator, stderr: anytype, path: []const u8, err: anyerror) void {
    common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "cannot read directory '{s}': {s}", .{ path, @errorName(err) });
}

// ============================================================================
// Main entry point and runDu
// ============================================================================

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = runDu(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runDu(allocator: Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) u8 {
    const opts = common.argparse.ArgParser.parse(DuOptions, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "invalid option\nTry 'du --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "option requires an argument\nTry 'du --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "invalid argument value\nTry 'du --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "argument parsing error", .{});
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
        common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "cannot both summarize and show each directory's size", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const deref_mode = resolveDerefMode(args);
    const config = resolveConfig(opts, deref_mode) catch |err| {
        switch (err) {
            error.InvalidBlockSize => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "invalid --block-size argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidMaxDepth => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "invalid maximum depth '{s}'", .{opts.max_depth orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidColorMode => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "invalid argument '{s}' for '--color'\nValid arguments are: 'always', 'auto', 'never'", .{opts.color orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidIconMode => {
                common.printErrorWithProgram(allocator, stderr, prog_name, std.fs.File.stderr().isTty(), "invalid argument '{s}' for '--icons'\nValid arguments are: 'always', 'auto', 'never'", .{opts.icons orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
        }
    };

    // Initialize styling based on resolved display config
    const StyleType = common.style.Style(@TypeOf(stdout));
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

fn printHelp(allocator: Allocator, writer: anytype) void {
    common.help.printColorized(allocator, writer,
        \\Usage: du [OPTION]... [FILE]...
        \\Summarize disk usage of the set of FILEs, recursively for directories.
        \\
        \\  -a, --all             write counts for all files, not just directories
        \\  -b, --bytes           equivalent to --apparent-size --block-size=1
        \\      --block-size=SIZE scale sizes by SIZE before printing them
        \\  -c, --total           produce a grand total
        \\  -d, --max-depth=N     print the total for a directory only if it is N
        \\                          or fewer levels below the command line argument
        \\  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)
        \\  -H, --dereference-args  dereference only command-line symlink arguments
        \\  -k                    like --block-size=1K
        \\  -L, --dereference     dereference all symbolic links
        \\  -P, --no-dereference  do not follow symbolic links (default)
        \\  -r                    report errors (default behavior, XPG4 compatibility)
        \\  -s, --summarize       display only a total for each argument
        \\  -S, --separate-dirs   for directories do not include size of subdirectories
        \\  -x, --one-file-system skip directories on different file systems
        \\      --apparent-size   print apparent sizes rather than disk usage
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

fn printVersion(writer: anytype) void {
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
    try testing.expectEqualStrings("0", formatHumanReadable(&buf, 0));
    try testing.expectEqualStrings("1", formatHumanReadable(&buf, 1));
    try testing.expectEqualStrings("512", formatHumanReadable(&buf, 512));
    try testing.expectEqualStrings("1023", formatHumanReadable(&buf, 1023));
}

test "formatHumanReadable - kilobytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0K", formatHumanReadable(&buf, 1024));
    try testing.expectEqualStrings("1.5K", formatHumanReadable(&buf, 1536));
    try testing.expectEqualStrings("10K", formatHumanReadable(&buf, 10240));
}

test "formatHumanReadable - megabytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0M", formatHumanReadable(&buf, 1048576));
    try testing.expectEqualStrings("100M", formatHumanReadable(&buf, 104857600));
}

test "formatHumanReadable - gigabytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0G", formatHumanReadable(&buf, 1073741824));
}

test "resolveConfig - defaults" {
    const opts = DuOptions{};
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(@as(u64, 1024), config.block_size);
    try testing.expect(!config.apparent_size);
    try testing.expect(!config.human_readable);
    try testing.expect(!config.summarize);
    try testing.expectEqual(@as(?u64, null), config.max_depth);
}

test "resolveConfig - bytes flag" {
    var opts = DuOptions{};
    opts.bytes = true;
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(@as(u64, 1), config.block_size);
    try testing.expect(config.apparent_size);
}

test "resolveConfig - kilobytes flag" {
    var opts = DuOptions{};
    opts.kilobytes = true;
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(@as(u64, 1024), config.block_size);
}

test "resolveConfig - summarize implies max-depth=0" {
    var opts = DuOptions{};
    opts.summarize = true;
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(@as(?u64, 0), config.max_depth);
}

test "resolveConfig - max-depth" {
    var opts = DuOptions{};
    opts.max_depth = "3";
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(@as(?u64, 3), config.max_depth);
}

test "resolveConfig - invalid max-depth" {
    var opts = DuOptions{};
    opts.max_depth = "abc";
    try testing.expectError(error.InvalidMaxDepth, resolveConfig(opts, .none));
}

test "resolveConfig - block-size option" {
    var opts = DuOptions{};
    opts.block_size = "1M";
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(@as(u64, 1048576), config.block_size);
}

test "resolveConfig - invalid block-size" {
    var opts = DuOptions{};
    opts.block_size = "invalid";
    try testing.expectError(error.InvalidBlockSize, resolveConfig(opts, .none));
}

test "du --help shows usage" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--help"};
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: du") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--human-readable") != null);
}

test "du --version shows version" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--version"};
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "du") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
}

test "du invalid flag exits with code 2" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--invalid-flag"};
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "du nonexistent path exits with code 1" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"/nonexistent/path/xyz"};
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "No such file or directory") != null);
}

test "du -s and -d conflict exits with code 2" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-s", "-d", "1" };
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "du on a file reports its size" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file with known content
    const test_file = try tmp_dir.dir.createFile("testfile.txt", .{});
    try test_file.writeAll("Hello, world!\n");
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("testfile.txt", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Use -b for apparent size in bytes
    const args = &[_][]const u8{ "-b", test_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // The output should contain "14" (length of "Hello, world!\n")
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "14\t") != null);
}

test "du on a directory reports size" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");
    const f = try tmp_dir.dir.createFile("subdir/file.txt", .{});
    try f.writeAll("some data here\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-b", dir_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should have output lines for subdir and the top dir
    try testing.expect(stdout_buffer.items.len > 0);
    // Output should contain the directory path
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, dir_path) != null);
}

test "du -s shows only total for argument" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir");
    const f = try tmp_dir.dir.createFile("subdir/file.txt", .{});
    try f.writeAll("test data\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-s", "-b", dir_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // With -s, should only have one line of output (the summary)
    var line_count: usize = 0;
    for (stdout_buffer.items) |byte| {
        if (byte == '\n') line_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), line_count);
}

test "du -c shows grand total" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("file.txt", .{});
    try f.writeAll("data\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-c", "-b", dir_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should contain "total" line
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "total") != null);
}

test "du -a shows all files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f1 = try tmp_dir.dir.createFile("file1.txt", .{});
    try f1.writeAll("one\n");
    f1.close();
    const f2 = try tmp_dir.dir.createFile("file2.txt", .{});
    try f2.writeAll("two\n");
    f2.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-a", "-b", dir_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // With -a, output should contain individual file names
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "file2.txt") != null);
}

test "du -h formats human-readable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("file.txt", .{});
    try f.writeAll("data\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-h", dir_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Output should exist and contain the path
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, dir_path) != null);
}

test "du defaults to current directory" {
    // Use a temp directory to avoid depending on the test runner's cwd
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("testfile", .{});
    try f.writeAll("hello");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-s", dir_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(stdout_buffer.items.len > 0);
}

test "du -d 0 is like -s" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("sub");
    const f = try tmp_dir.dir.createFile("sub/file.txt", .{});
    try f.writeAll("test\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    var stdout_d0 = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_d0.deinit(testing.allocator);
    var stdout_s = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_s.deinit(testing.allocator);

    const args_d0 = &[_][]const u8{ "-d", "0", "-b", dir_path };
    _ = runDu(testing.allocator, args_d0, stdout_d0.writer(testing.allocator), common.null_writer);

    const args_s = &[_][]const u8{ "-s", "-b", dir_path };
    _ = runDu(testing.allocator, args_s, stdout_s.writer(testing.allocator), common.null_writer);

    // Both should produce identical output
    try testing.expectEqualStrings(stdout_d0.items, stdout_s.items);
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
    // Create a temp file and stat it
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("test.bin", .{});
    // Write exactly 100 bytes
    const data = [_]u8{0xAA} ** 100;
    try f.writeAll(&data);
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test.bin", &path_buf);

    const stat_buf = try doStat(test_path, false);

    // Apparent size should be exactly 100
    const apparent = getFileSize(stat_buf, true);
    try testing.expectEqual(@as(u64, 100), apparent);

    // Disk usage should be >= 100 (rounded to block boundaries)
    const disk = getFileSize(stat_buf, false);
    try testing.expect(disk >= 100);
}

test "resolveConfig - color mode always" {
    var opts = DuOptions{};
    opts.color = "always";
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(common.display_config.ResolvedMode.on, config.display.color);
}

test "resolveConfig - color mode never" {
    var opts = DuOptions{};
    opts.color = "never";
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(common.display_config.ResolvedMode.off, config.display.color);
}

test "resolveConfig - color mode default" {
    const opts = DuOptions{};
    const config = try resolveConfig(opts, .none);
    try testing.expectEqual(common.display_config.ResolvedMode.off, config.display.color);
}

test "resolveConfig - invalid color mode" {
    var opts = DuOptions{};
    opts.color = "invalid";
    try testing.expectError(error.InvalidColorMode, resolveConfig(opts, .none));
}

test "du --color=invalid exits with code 2" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--color=invalid"};
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid argument") != null);
}

// C library functions for environment manipulation in tests
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

test "resolveConfig - show_icons defaults to false" {
    // Save and clear env vars that affect icon resolution
    const saved_style = std.posix.getenv("VIBEUTILS_STYLE");
    const saved_icons = std.posix.getenv("VIBEUTILS_ICONS");
    _ = unsetenv("VIBEUTILS_STYLE");
    _ = unsetenv("VIBEUTILS_ICONS");
    defer {
        if (saved_style) |v| _ = setenv("VIBEUTILS_STYLE", v.ptr, 1);
        if (saved_icons) |v| _ = setenv("VIBEUTILS_ICONS", v.ptr, 1);
    }

    const opts = DuOptions{};
    const config = try resolveConfig(opts, .none);
    // With no env overrides and no TTY, display.icons resolves to .off
    try testing.expect(!config.show_icons);
}

test "resolveConfig - icons=always enables show_icons" {
    var opts = DuOptions{};
    opts.icons = "always";
    const config = try resolveConfig(opts, .none);
    try testing.expect(config.show_icons);
}

test "resolveConfig - icons=never disables show_icons" {
    var opts = DuOptions{};
    opts.icons = "never";
    const config = try resolveConfig(opts, .none);
    try testing.expect(!config.show_icons);
}

test "resolveConfig - invalid icon mode" {
    var opts = DuOptions{};
    opts.icons = "invalid";
    try testing.expectError(error.InvalidIconMode, resolveConfig(opts, .none));
}

test "printEntry without icons shows clean output" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const style = TestStyle{ .color_mode = .none, .writer = buffer.writer(testing.allocator) };

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
        .show_icons = false,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .off, .highlight = .off, .theme = .none },
    };

    printEntry(buffer.writer(testing.allocator), style, 1024, config, "/tmp/test.txt", false, false);

    // Should be "1024\t/tmp/test.txt\n" with no icon
    try testing.expectEqualStrings("1024\t/tmp/test.txt\n", buffer.items);
}

test "printEntry with icons shows icon glyph" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const style = TestStyle{ .color_mode = .none, .writer = buffer.writer(testing.allocator) };

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
        .show_icons = true,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .on, .highlight = .off, .theme = .none },
    };

    printEntry(buffer.writer(testing.allocator), style, 1024, config, "/tmp/test.txt", false, false);

    // Should contain the text file icon followed by a space and the path
    const theme = common.icons.IconTheme{};
    const expected_icon = common.icons.getIcon(&theme, "test.txt", false, false, false);
    try testing.expect(std.mem.indexOf(u8, buffer.items, expected_icon) != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "/tmp/test.txt") != null);
}

test "printEntry with directory icon" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const TestStyle = common.style.Style(std.ArrayList(u8).Writer);
    const style = TestStyle{ .color_mode = .none, .writer = buffer.writer(testing.allocator) };

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
        .show_icons = true,
        .display = common.display_config.DisplayConfig{ .color = .off, .icons = .on, .highlight = .off, .theme = .none },
    };

    printEntry(buffer.writer(testing.allocator), style, 4096, config, "/tmp/mydir", true, false);

    // Should contain the directory icon
    const theme = common.icons.IconTheme{};
    try testing.expect(std.mem.indexOf(u8, buffer.items, theme.directory) != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "/tmp/mydir") != null);
}

test "du --help shows icons option" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--help"};
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--icons") != null);
}

// ============================================================================
// Tests for du -r (report errors — no-op compatibility flag)
// ============================================================================

test "du -r flag is accepted by argparse" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"-r"};
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -r produces same output as du" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("file.txt", .{});
    try f.writeAll("test data\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    // Run without -r
    var stdout_without_r = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_without_r.deinit(testing.allocator);

    const args_no_r = &[_][]const u8{ "-b", dir_path };
    const exit_no_r = runDu(testing.allocator, args_no_r, stdout_without_r.writer(testing.allocator), common.null_writer);

    // Run with -r
    var stdout_with_r = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_with_r.deinit(testing.allocator);

    const args_with_r = &[_][]const u8{ "-r", "-b", dir_path };
    const exit_with_r = runDu(testing.allocator, args_with_r, stdout_with_r.writer(testing.allocator), common.null_writer);

    // Both should succeed and produce identical output
    try testing.expectEqual(@as(u8, 0), exit_no_r);
    try testing.expectEqual(@as(u8, 0), exit_with_r);
    try testing.expectEqualStrings(stdout_without_r.items, stdout_with_r.items);
}

// ============================================================================
// Tests for du -H (dereference command-line symlink arguments only)
// ============================================================================

test "du -H flag is accepted by argparse" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"-H"};
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -H follows symlinks given as command-line arguments" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a directory with a file inside
    try tmp_dir.dir.makeDir("target_dir");
    const f = try tmp_dir.dir.createFile("target_dir/content.txt", .{});
    try f.writeAll("hello world data\n");
    f.close();

    // Create a symlink to the directory
    tmp_dir.dir.symLink("target_dir", "link_to_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = try tmp_dir.dir.realpath(".", &path_buf);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_to_dir", .{base_path});
    defer testing.allocator.free(link_path);

    // du -H on symlink_to_dir: should follow it (command-line arg)
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-H", "-a", "-b", link_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // The output should include content.txt path (proves we traversed into the dir)
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "content.txt") != null);
}

test "du -H does not follow symlinks found during traversal" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("parent_dir");
    try tmp_dir.dir.makeDir("parent_dir/real_subdir");
    const f = try tmp_dir.dir.createFile("parent_dir/real_subdir/data.txt", .{});
    try f.writeAll("some data content\n");
    f.close();

    // Create a symlink inside parent_dir that points to real_subdir
    tmp_dir.dir.symLink("real_subdir", "parent_dir/symlink_subdir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_path = try tmp_dir.dir.realpath("parent_dir", &path_buf);

    // du -H on parent_dir: should NOT follow symlink_subdir during traversal
    var stdout_h = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_h.deinit(testing.allocator);

    const args_h = &[_][]const u8{ "-H", "-a", "-b", parent_path };
    const exit_h = runDu(testing.allocator, args_h, stdout_h.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_h);

    // du -L on parent_dir: should follow symlink_subdir (follows all symlinks)
    var stdout_l = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_l.deinit(testing.allocator);

    const args_l = &[_][]const u8{ "-L", "-a", "-b", parent_path };
    const exit_l = runDu(testing.allocator, args_l, stdout_l.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_l);

    // Count occurrences of "data.txt" — -H should have fewer than -L
    var h_count: usize = 0;
    var h_pos: usize = 0;
    while (std.mem.indexOfPos(u8, stdout_h.items, h_pos, "data.txt")) |idx| {
        h_count += 1;
        h_pos = idx + 1;
    }

    var l_count: usize = 0;
    var l_pos: usize = 0;
    while (std.mem.indexOfPos(u8, stdout_l.items, l_pos, "data.txt")) |idx| {
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
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"-P"};
    const exit_code = runDu(testing.allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    // Should not return misuse (2) — flag should be accepted
    try testing.expect(exit_code != 2);
}

test "du -P does not follow symlinks" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("real_dir");
    const f = try tmp_dir.dir.createFile("real_dir/file.txt", .{});
    try f.writeAll("data\n");
    f.close();

    tmp_dir.dir.symLink("real_dir", "link_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    // Use parent realpath + symlink name (realpath would resolve the symlink)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = try tmp_dir.dir.realpath(".", &path_buf);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_dir", .{base_path});
    defer testing.allocator.free(link_path);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-P", "-a", "-b", link_path };
    const exit_code = runDu(testing.allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // -P should NOT follow the symlink, so file.txt should not appear
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "file.txt") == null);
}

test "du -P overrides -L when specified last" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("target");
    const f = try tmp_dir.dir.createFile("target/marker.txt", .{});
    try f.writeAll("marker\n");
    f.close();

    tmp_dir.dir.symLink("target", "sym", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    // Use parent realpath + symlink name (realpath would resolve the symlink)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = try tmp_dir.dir.realpath(".", &path_buf);
    const sym_path = try std.fmt.allocPrint(testing.allocator, "{s}/sym", .{base_path});
    defer testing.allocator.free(sym_path);

    // -L -P: last is -P, should NOT follow
    var stdout_lp = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_lp.deinit(testing.allocator);

    const args_lp = &[_][]const u8{ "-L", "-P", "-a", "-b", sym_path };
    const exit_lp = runDu(testing.allocator, args_lp, stdout_lp.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_lp);
    try testing.expect(std.mem.indexOf(u8, stdout_lp.items, "marker.txt") == null);

    // -P -L: last is -L, should follow
    var stdout_pl = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_pl.deinit(testing.allocator);

    const args_pl = &[_][]const u8{ "-P", "-L", "-a", "-b", sym_path };
    const exit_pl = runDu(testing.allocator, args_pl, stdout_pl.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_pl);
    try testing.expect(std.mem.indexOf(u8, stdout_pl.items, "marker.txt") != null);
}
