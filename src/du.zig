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
const assert = std.debug.assert;

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
        .max_depth = .{
            .short = 'd',
            .desc = "Print total for directory only if N or fewer levels below",
            .value_name = "N",
        },
        .human_readable = .{
            .short = 'h',
            .desc = "Print sizes in human readable format (1K, 234M, 2G)",
        },
        .kilobytes = .{ .short = 'k', .desc = "Like --block-size=1K" },
        .gigabytes = .{ .short = 'g', .desc = "Like --block-size=1G" },
        .megabytes = .{ .short = 'm', .desc = "Like --block-size=1M" },
        .dereference = .{ .short = 'L', .desc = "Dereference all symbolic links" },
        .dereference_args = .{
            .short = 'H',
            .desc = "Dereference only command-line symlink arguments",
        },
        .no_dereference = .{ .short = 'P', .desc = "Do not follow symbolic links (default)" },
        .no_follow = .{ .short = 'n', .desc = "Don't follow symbolic links (alias for -P)" },
        .report_errors = .{
            .short = 'r',
            .desc = "Report errors (default behavior, XPG4 compatibility)",
        },
        .summarize = .{ .short = 's', .desc = "Display only a total for each argument" },
        .separate_dirs = .{
            .short = 'S',
            .desc = "For directories do not include size of subdirectories",
        },
        .one_file_system = .{ .short = 'x', .desc = "Skip directories on different file systems" },
        .apparent_size = .{ .short = 'A', .desc = "Print apparent sizes rather than disk usage" },
        .block_size = .{
            .short = 'B',
            .desc = "Scale sizes by SIZE before printing",
            .value_name = "SIZE",
        },
        .count_links = .{ .short = 'l', .desc = "Count sizes many times if hard linked" },
        .ignore_pattern = .{
            .short = 'I',
            .desc = "Exclude files matching PATTERN (stub)",
            .value_name = "PATTERN",
        },
        .threshold = .{
            .short = 't',
            .desc = "Exclude entries smaller than SIZE, or larger if negative",
            .value_name = "SIZE",
        },
        .si = .{ .short = 0, .desc = "Like -h, but use powers of 1000 not 1024" },
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .color = .{
            .short = 0,
            .desc = "Colorize the output; WHEN can be 'always', 'auto', or 'never'",
            .value_name = "WHEN",
        },
        .icons = .{
            .short = 0,
            .desc = "When to show file type icons (valid: always, auto, never)",
            .value_name = "WHEN",
        },
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
    // val_str is always a suffix of str (equal, or one byte shorter after
    // stripping a leading sign), so its length never exceeds str.len.
    assert(val_str.len <= str.len);

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

    // Derive block_size from -b/-k/-m/-g and the --block-size override.
    try resolveConfig_applyBlockSize(opts, &config);

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
    if (opts.color) |when| try resolveConfig_applyColorMode(when, &config.display);

    // Parse explicit --icons mode (overrides DisplayConfig)
    if (opts.icons) |when| try resolveConfig_applyIconMode(when, &config.show_icons);

    return config;
}

/// Derive `config.block_size` (and `apparent_size` for -b) from the size
/// flags, applying the same precedence as before: -b/-k/-m/-g set defaults
/// in order, then --block-size overrides them all.
fn resolveConfig_applyBlockSize(opts: DuOptions, config: *DuConfig) error{InvalidBlockSize}!void {
    assert(config.block_size != 0);

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
}

/// Apply an explicit --color WHEN value to the display config, overriding the
/// TTY-resolved default. Leaves "auto" untouched; rejects unknown values.
fn resolveConfig_applyColorMode(
    when: []const u8,
    display: *common.display_config.DisplayConfig,
) error{InvalidColorMode}!void {
    if (std.mem.eql(u8, when, "always")) {
        display.color = .on;
    } else if (std.mem.eql(u8, when, "auto")) {
        // Keep resolved value (TTY-dependent)
    } else if (std.mem.eql(u8, when, "never")) {
        display.color = .off;
    } else {
        return error.InvalidColorMode;
    }
}

/// Apply an explicit --icons WHEN value to `show_icons`, overriding the
/// TTY-resolved default. Leaves "auto" untouched; rejects unknown values.
fn resolveConfig_applyIconMode(
    when: []const u8,
    show_icons: *bool,
) error{InvalidIconMode}!void {
    if (std.mem.eql(u8, when, "always")) {
        show_icons.* = true;
    } else if (std.mem.eql(u8, when, "auto")) {
        // Keep resolved value (TTY-dependent)
    } else if (std.mem.eql(u8, when, "never")) {
        show_icons.* = false;
    } else {
        return error.InvalidIconMode;
    }
}

// ============================================================================
// Block size parsing and human-readable formatting (delegated to common.format)
// ============================================================================

const format = common.format;

fn parseBlockSize(str: []const u8) ?u64 {
    return format.parseBlockSize(str);
}

fn formatHumanReadable(buf: []u8, size_bytes: u64, si: bool) []const u8 {
    // Every caller passes a [32]u8; 32 bytes is the established minimum that
    // holds the longest formatted size (e.g. "1023.9P") plus its suffix.
    assert(buf.len >= 32);
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
    // The early return above eliminated any over-length path, so the @memcpy
    // into path_buf is within bounds for every path that reaches here.
    assert(path.len <= std.Io.Dir.max_path_bytes);
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path = path_buf[0..path.len :0];

    return if (builtin.os.tag == .linux)
        doStat_linux(c_path, follow_symlinks)
    else
        doStat_posix(c_path, follow_symlinks);
}

/// Linux `statx` path of doStat: stat `c_path` and decode it into StatResult.
fn doStat_linux(c_path: [:0]const u8, follow_symlinks: bool) !StatResult {
    assert(c_path.len <= std.Io.Dir.max_path_bytes);

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
}

/// POSIX `fstatat` path of doStat: stat `c_path` and decode it into StatResult.
fn doStat_posix(c_path: [:0]const u8, follow_symlinks: bool) !StatResult {
    assert(c_path.len <= std.Io.Dir.max_path_bytes);

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

/// Safety cap on traversal depth, shared with the walker's max_depth. The
/// parallel accumulation stacks are sized one larger so they can be indexed by
/// any depth the walker can emit (0..max_walk_depth inclusive). This is a hard
/// recursion-free bound, NOT du's user-facing --max-depth display filter.
const max_walk_depth: u16 = 1024;
const accumulation_stack_len: usize = @as(usize, max_walk_depth) + 1;

comptime {
    // The accumulation stacks must hold every depth the walker can emit, which
    // is 0..max_walk_depth inclusive; assert the sizing relationship up front.
    assert(accumulation_stack_len == @as(usize, max_walk_depth) + 1);
    assert(max_walk_depth > 0);
}

/// Map du's resolved dereference mode onto the walker's symlink policy.
/// -P/none never follow; -H/args_only follow only command-line operands;
/// -L/all follow every symlink (subject to the depth/path safety bounds).
fn symlinkPolicyFromMode(mode: DereferenceMode) common.walker.SymlinkPolicy {
    return switch (mode) {
        .none => .no_follow,
        .args_only => .follow_cmdline,
        .all => .follow_all,
    };
}

/// Per-entry follow decision for du's own stat call, independent of the walker.
/// -L follows all; -H follows only the operand (depth 0); -P never follows.
fn shouldFollowAtDepth(mode: DereferenceMode, depth: u16) bool {
    return switch (mode) {
        .all => true,
        .args_only => depth == 0,
        .none => false,
    };
}

/// Mutable state threaded through the walker driver loop. Holds the explicit,
/// depth-indexed accumulation stacks that replace the recursion's call stack.
/// All storage is fixed-size and stack-allocated; nothing is allocated per
/// entry, satisfying Tiger Style's static-memory rule for the hot loop.
const WalkState = struct {
    /// Running subtree total (own size + all descendants) for the directory at
    /// each active depth. Initialized on a directory's pre-order visit and
    /// rolled into the parent on its post-order visit.
    subtree_sizes: [accumulation_stack_len]u64,
    /// Sum of the DIRECT file children of the directory at each depth. Used only
    /// for -S, where a directory reports its direct files but excludes
    /// subdirectory subtrees. Subtree roll-up still uses subtree_sizes.
    direct_file_sizes: [accumulation_stack_len]u64,
};

/// Compute disk usage for a single operand, printing as it goes and returning
/// the operand's total subtree size for grand-total accumulation. Non-directory
/// operands (plain files, or symlinks not followed under the active policy) are
/// handled directly as leaves; directories are driven through the bounded
/// walker so no recursion remains.
fn processOperand(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    config: DuConfig,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: *std.Io.Writer,
    style: anytype,
    stderr: *std.Io.Writer,
    has_error: *bool,
) u64 {
    // Resolve the operand itself with the operand-level follow policy so a -P
    // symlink stays a leaf and an -H/-L symlink resolves to its target.
    const follow_operand = shouldFollowAtDepth(config.dereference_mode, 0);
    const stat_buf = doStat(path, follow_operand) catch |err| {
        printStatError(allocator, stderr, path, err);
        has_error.* = true;
        return 0;
    };
    // A symlink can only persist as a leaf here when the policy does not follow
    // it; under a follow policy doStat resolved through it to the target. The
    // conjunction is hoisted into a single boolean so the assertion stays a
    // lone condition (the forbidden state is "symlink AND followed", which is a
    // NAND, not two independent invariants).
    const symlink_followed = stat_buf.is_symlink and follow_operand;
    assert(!symlink_followed);

    if (!stat_buf.is_dir) {
        // Leaf operand: always printed (depth 0) regardless of -a; the operand
        // is never deduped because it is the explicit argument.
        const leaf_size = getFileSize(stat_buf, config.apparent_size, false);
        if (shouldPrintAtDepth(0, config)) {
            printEntry(stdout, style, leaf_size, config, path, false, stat_buf.is_symlink);
        }
        return leaf_size;
    }

    return walkDirectoryOperand(
        allocator,
        io,
        path,
        config,
        seen_inodes,
        stdout,
        style,
        stderr,
        has_error,
    );
}

/// Drive the bounded walker over a directory operand, accumulating sizes via the
/// depth-indexed stacks and printing each entry per du's display rules. Returns
/// the operand's full subtree size (subtree_sizes[0] after the root post-order
/// emit). One walker instance per operand keeps cycle/state isolated per tree.
fn walkDirectoryOperand(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    config: DuConfig,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: *std.Io.Writer,
    style: anytype,
    stderr: *std.Io.Writer,
    has_error: *bool,
) u64 {
    assert(path.len > 0);
    const walk_config = common.walker.WalkConfig{
        .order = .both,
        .symlinks = symlinkPolicyFromMode(config.dereference_mode),
        .stay_on_filesystem = config.one_file_system,
        // Ancestor-only cycle detection: du still counts a file reached via
        // two distinct directory paths (e.g. -L through both real/ and a
        // sibling symlink to it) once per path — no global visited set means
        // sibling aliases are re-walked. Ancestor loops (a symlink resolving to
        // one of its own ancestors) are pruned via the bounded stack scan,
        // surfacing error.DirectoryCycle instead of running to the depth bound.
        .cycle_mode = .ancestors,
        .max_depth = max_walk_depth,
        .max_entries = 1 << 24,
    };
    var dir_walker = common.walker.Walker.init(allocator, walk_config) catch {
        has_error.* = true;
        return 0;
    };
    defer dir_walker.deinit(io);
    dir_walker.addRoot(path) catch {
        has_error.* = true;
        return 0;
    };

    var state = WalkState{
        .subtree_sizes = [_]u64{0} ** accumulation_stack_len,
        .direct_file_sizes = [_]u64{0} ** accumulation_stack_len,
    };

    // The walker now classifies every entry's kind before descending: under a
    // follow policy it stats each symlink's target (resolveKind), so a symlink
    // to a non-directory is emitted as a leaf and never openDir'd. The only way
    // next() can still surface error.NotDir is a TOCTOU race, where an entry
    // classified as a directory (a real subdir, or a symlink whose target stat'd
    // as one) is replaced by a non-directory before openDir. Under a follow
    // policy the raced target is typically still reachable by another path and
    // deduped to zero, so a transient race is suppressed rather than failing the
    // walk; under -P it is surfaced like any other iteration error.
    const follow_any = config.dereference_mode != .none;

    return walkDirectoryOperand_drainLoop(
        allocator,
        io,
        path,
        config,
        follow_any,
        &dir_walker,
        &state,
        seen_inodes,
        stdout,
        style,
        stderr,
        has_error,
    );
}

/// Consume all entries from dir_walker and accumulate sizes into state,
/// returning the root subtree total. Extracted from walkDirectoryOperand to
/// keep the outer function within the 70-line limit.
fn walkDirectoryOperand_drainLoop(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    config: DuConfig,
    follow_any: bool,
    dir_walker: *common.walker.Walker,
    state: *WalkState,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: *std.Io.Writer,
    style: anytype,
    stderr: *std.Io.Writer,
    has_error: *bool,
) u64 {
    assert(path.len > 0);
    assert(state.subtree_sizes[0] == 0);

    var root_total: u64 = 0;
    // Drains the bounded walker: each iteration consumes one entry. The walker
    // is internally bounded (max_depth, max_entries) and self-terminating, so a
    // numeric cap here would only risk truncating valid output on large trees;
    // see the annotation below for the exact termination conditions.
    while (true) { // tiger:allow:unbounded-loop (termination: see comment above)
        const maybe_entry = dir_walker.next(io) catch |err| switch (err) {
            error.DepthLimitExceeded, error.EntryLimitExceeded => {
                printDirError(allocator, stderr, path, err);
                has_error.* = true;
                break;
            },
            error.DirectoryCycle => {
                // An ancestor symlink loop was pruned. GNU du is silent here;
                // vibeutils reports it as a diagnosable error (has_error, rc=1)
                // and keeps walking the remaining entries.
                printCycleError(allocator, stderr, dir_walker.cyclePath());
                has_error.* = true;
                continue;
            },
            error.NotDir => {
                if (!follow_any) {
                    printIterError(allocator, stderr, path, err);
                    has_error.* = true;
                }
                continue;
            },
            else => {
                printIterError(allocator, stderr, path, err);
                has_error.* = true;
                continue;
            },
        };
        const entry = maybe_entry orelse break;
        assert(entry.depth < accumulation_stack_len);
        // A depth-0 non-directory entry means the operand stat'd as a directory
        // but the walker could not open it as one: either the directory lacks its
        // own read bit (stat needs only parent +x), or a TOCTOU race replaced it
        // with a non-directory. The walker emits it as a leaf at depth 0, where
        // handleLeafEntry's parent-depth (depth - 1) would underflow. Report it
        // like GNU (cannot read directory ...: <reason>), print 0, and skip the
        // leaf accounting.
        if (entry.depth == 0 and entry.kind != .directory) {
            printDirError(allocator, stderr, path, error.AccessDenied);
            has_error.* = true;
            if (shouldPrintAtDepth(0, config)) {
                printEntry(stdout, style, 0, config, path, true, false);
            }
            continue;
        }
        processWalkEntry(
            allocator,
            entry,
            config,
            state,
            seen_inodes,
            stdout,
            style,
            stderr,
            has_error,
        );
        if (entry.depth == 0 and entry.visit == .post) {
            root_total = state.subtree_sizes[0];
        }
    }

    return root_total;
}

/// Process one walker entry: maintain the accumulation stacks and print per du's
/// rules. Directories are handled on both their pre (initialize) and post
/// (print + roll up) visits; everything else is a leaf accounted into its
/// parent. Centralizes the branching so the helpers stay branch-light.
fn processWalkEntry(
    allocator: Allocator,
    entry: common.walker.Entry,
    config: DuConfig,
    state: *WalkState,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: *std.Io.Writer,
    style: anytype,
    stderr: *std.Io.Writer,
    has_error: *bool,
) void {
    const depth = entry.depth;
    assert(depth < accumulation_stack_len);
    if (entry.kind == .directory) {
        if (entry.visit == .pre) {
            handleDirPre(entry, config, state, has_error);
        } else {
            handleDirPost(entry, config, state, stdout, style);
        }
        return;
    }
    handleLeafEntry(allocator, entry, config, state, seen_inodes, stdout, style, stderr, has_error);
}

/// Pre-order directory visit: reset this depth's accumulators and seed the
/// subtree with the directory's own size (0 in apparent-size mode, matching GNU
/// du's treatment of directory metadata). A failed stat is reported but does not
/// abort the walk, mirroring the recursion's per-entry error handling.
fn handleDirPre(
    entry: common.walker.Entry,
    config: DuConfig,
    state: *WalkState,
    has_error: *bool,
) void {
    const depth = entry.depth;
    assert(entry.kind == .directory);
    assert(depth < accumulation_stack_len);
    state.subtree_sizes[depth] = 0;
    state.direct_file_sizes[depth] = 0;
    const follow = shouldFollowAtDepth(config.dereference_mode, depth);
    const stat_buf = doStat(entry.path, follow) catch {
        has_error.* = true;
        return;
    };
    const dir_own_size = getFileSize(stat_buf, config.apparent_size, true);
    state.subtree_sizes[depth] = dir_own_size;
    // Seed the direct-file tally with the directory's own size so the -S printed
    // value includes its inode block allocation (GNU du -S counts the directory's
    // own blocks plus its direct file children, excluding subdirectory subtrees).
    // In apparent-size mode dir_own_size is 0, so this is a no-op there.
    state.direct_file_sizes[depth] = dir_own_size;
}

/// Post-order directory visit: print this directory (subject to the -d display
/// filter and -S adjustment) and roll its FULL subtree into the parent. The
/// roll-up always uses the full subtree even under -S, so ancestor totals stay
/// complete while the printed value reflects only direct files.
fn handleDirPost(
    entry: common.walker.Entry,
    config: DuConfig,
    state: *WalkState,
    stdout: *std.Io.Writer,
    style: anytype,
) void {
    const depth = entry.depth;
    assert(entry.kind == .directory);
    assert(depth < accumulation_stack_len);
    const full_subtree = state.subtree_sizes[depth];
    const printed_size = if (config.separate_dirs)
        state.direct_file_sizes[depth]
    else
        full_subtree;
    if (shouldPrintAtDepth(depth, config)) {
        printEntry(stdout, style, printed_size, config, entry.path, true, false);
    }
    if (depth > 0) {
        // Propagate the full subtree (never the -S-adjusted value) upward.
        state.subtree_sizes[depth - 1] += full_subtree;
    }
}

/// Leaf visit (regular file, symlink not followed, or other non-directory):
/// stat it, apply hard-link/inode dedup, account its size into the parent
/// directory's subtree, and print it when -a selects files. Reaches here only at
/// depth >= 1: a depth-0 non-directory operand is intercepted in
/// walkDirectoryOperand (unreadable/raced directory) before dispatch.
fn handleLeafEntry(
    allocator: Allocator,
    entry: common.walker.Entry,
    config: DuConfig,
    state: *WalkState,
    seen_inodes: *std.AutoHashMap(u128, void),
    stdout: *std.Io.Writer,
    style: anytype,
    stderr: *std.Io.Writer,
    has_error: *bool,
) void {
    const depth = entry.depth;
    assert(depth < accumulation_stack_len);
    assert(entry.path.len > 0);
    const follow = shouldFollowAtDepth(config.dereference_mode, depth);
    const stat_buf = doStat(entry.path, follow) catch |err| {
        // Under a follow policy the walker resolves each symlink by statting its
        // target; a link whose target cannot be resolved (dangling ENOENT or an
        // ELOOP chain) surfaces here as a .sym_link leaf. GNU du reports such a
        // link ("cannot access '<path>': <reason>") and exits 1 rather than
        // dropping it silently. -P/-H leaves (follow == false) keep the prior
        // silent-skip behavior: their lstat only fails on a rare TOCTOU race.
        if (follow and entry.kind == .sym_link) {
            printStatError(allocator, stderr, entry.path, err);
            has_error.* = true;
        }
        return;
    };

    const is_duplicate = checkAndRecordInode(stat_buf, config, seen_inodes);
    const file_size = if (is_duplicate)
        0
    else
        getFileSize(stat_buf, config.apparent_size, false);

    // Account into the parent directory's running subtree and, for -S, into the
    // parent's direct-file tally.
    const parent_depth = depth - 1;
    state.subtree_sizes[parent_depth] += file_size;
    if (config.separate_dirs) {
        state.direct_file_sizes[parent_depth] += file_size;
    }

    const is_link = entry.kind == .sym_link;
    if (config.all and shouldPrintAtDepth(depth, config)) {
        printEntry(stdout, style, file_size, config, entry.path, false, is_link);
    }
}

/// Hard-link dedup: returns true when this (dev,inode) was already counted, so
/// the caller charges it zero bytes. Mirrors the recursion: only non-directories
/// are deduped, -l disables dedup entirely, and -L tracks unconditionally
/// because a symlink and its target share an inode even at nlink == 1.
fn checkAndRecordInode(
    stat_buf: StatResult,
    config: DuConfig,
    seen_inodes: *std.AutoHashMap(u128, void),
) bool {
    const should_dedup = !stat_buf.is_dir and !config.count_links and
        (stat_buf.nlink > 1 or config.dereference_mode == .all);
    if (!should_dedup) return false;
    // Directories are never deduped; reaching here means a non-directory leaf.
    assert(!stat_buf.is_dir);
    assert(!config.count_links);
    const key: u128 = (@as(u128, stat_buf.dev) << 64) | @as(u128, stat_buf.ino);
    if (seen_inodes.contains(key)) {
        return true;
    }
    seen_inodes.put(key, {}) catch {};
    return false;
}

fn shouldPrintAtDepth(depth: u64, config: DuConfig) bool {
    if (config.max_depth) |max_d| {
        return depth <= max_d;
    }
    return true;
}

fn printEntry(
    writer: *std.Io.Writer,
    style: anytype,
    size_bytes: u64,
    config: DuConfig,
    path: []const u8,
    is_dir: bool,
    is_link: bool,
) void {
    // Every call site passes a non-empty path (an operand, a walker entry path,
    // or the literal "total"); basename/eql below rely on it.
    assert(path.len > 0);
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

fn printStatError(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    path: []const u8,
    err: anyerror,
) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => "Cannot access",
    };
    common.printErrorWithProgram(
        allocator,
        stderr,
        prog_name,
        "cannot access '{s}': {s}",
        .{ path, msg },
    );
}

fn printDirError(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    path: []const u8,
    err: anyerror,
) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        else => "Cannot read directory",
    };
    common.printErrorWithProgram(
        allocator,
        stderr,
        prog_name,
        "cannot read directory '{s}': {s}",
        .{ path, msg },
    );
}

fn printIterError(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    path: []const u8,
    err: anyerror,
) void {
    common.printErrorWithProgram(
        allocator,
        stderr,
        prog_name,
        "cannot read directory '{s}': {s}",
        .{ path, common.posixErrorString(err) },
    );
}

/// Report a pruned ancestor symlink loop. GNU du prints nothing here; vibeutils
/// makes the cycle diagnosable. `cycle_path` names the offending symlink; it may
/// be empty if the walker could not record it (OOM), in which case the operand
/// path is not available here and the message still identifies the condition.
fn printCycleError(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    cycle_path: []const u8,
) void {
    common.printErrorWithProgram(
        allocator,
        stderr,
        prog_name,
        "cannot process '{s}': directory cycle detected",
        .{cycle_path},
    );
}

// ============================================================================
// Main entry point and runDu
// ============================================================================

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runDu);
}

pub fn runDu(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) anyerror!u8 {
    const opts = common.argparse.ArgParser.parse(DuOptions, allocator, args) catch |err|
        return runDu_parseArgsError(allocator, stderr, err);
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
        common.printErrorWithProgram(
            allocator,
            stderr,
            prog_name,
            "cannot both summarize and show each directory's size",
            .{},
        );
        return @intFromEnum(common.ExitCode.misuse);
    }

    const deref_mode = resolveDerefMode(args);
    const config = resolveConfig(allocator, opts, deref_mode) catch |err|
        return runDu_resolveConfigError(allocator, stderr, opts, err);

    // Initialize styling based on resolved display config
    const style = runDu_initStyle(allocator, stdout, config);

    const paths = if (opts.positionals.len == 0)
        &[_][]const u8{"."}
    else
        opts.positionals;
    // paths is the one-element "." fallback when no operand is given, otherwise
    // the non-empty positionals; the operand loop always runs at least once.
    assert(paths.len >= 1);

    var has_error = false;
    var grand_total: u64 = 0;

    var seen_inodes = std.AutoHashMap(u128, void).init(allocator);
    defer seen_inodes.deinit();

    for (paths) |path| {
        const size = processOperand(
            allocator,
            io,
            path,
            config,
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

/// Map an argparse error to a user-facing message + exit code for runDu.
/// Kept separate so runDu's `catch` stays a single line.
fn runDu_parseArgsError(allocator: Allocator, stderr: *std.Io.Writer, err: anyerror) u8 {
    assert(err != error.Success);
    // prog_name is a fixed module constant we embed in every message.
    assert(prog_name.len > 0);

    switch (err) {
        error.UnknownFlag => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid option\nTry 'du --help' for more information.",
                .{},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        error.MissingValue => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "option requires an argument\nTry 'du --help' for more information.",
                .{},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        error.InvalidValue => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid argument value\nTry 'du --help' for more information.",
                .{},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "argument parsing error",
                .{},
            );
            return @intFromEnum(common.ExitCode.general_error);
        },
    }
}

/// Map a resolveConfig error to a user-facing message + exit code for runDu.
/// Needs `opts` to echo the offending value strings. Kept separate so runDu's
/// `catch` stays a single line.
fn runDu_resolveConfigError(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    opts: DuOptions,
    err: anyerror,
) u8 {
    assert(err != error.Success);
    // prog_name is a fixed module constant we embed in every message.
    assert(prog_name.len > 0);

    switch (err) {
        error.InvalidBlockSize => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid --block-size argument",
                .{},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        error.InvalidMaxDepth => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid maximum depth '{s}'",
                .{opts.max_depth orelse ""},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        error.InvalidColorMode => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid argument '{s}' for '--color'\n" ++
                    "Valid arguments are: 'always', 'auto', 'never'",
                .{opts.color orelse ""},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        error.InvalidIconMode => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid argument '{s}' for '--icons'\n" ++
                    "Valid arguments are: 'always', 'auto', 'never'",
                .{opts.icons orelse ""},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        error.InvalidThreshold => {
            common.printErrorWithProgram(
                allocator,
                stderr,
                prog_name,
                "invalid --threshold argument '{s}'",
                .{opts.threshold orelse ""},
            );
            return @intFromEnum(common.ExitCode.misuse);
        },
        else => unreachable,
    }
}

/// Build the output Style from the resolved display config, detecting the
/// terminal color depth only when color is enabled.
fn runDu_initStyle(
    allocator: Allocator,
    stdout: *std.Io.Writer,
    config: DuConfig,
) common.style.Style(*std.Io.Writer) {
    const StyleType = common.style.Style(*std.Io.Writer);

    var style = StyleType{ .color_mode = .none, .writer = stdout };
    if (config.display.color == .on) {
        const detected = StyleType.ColorMode.detect(allocator) catch .basic;
        style.color_mode = if (detected == .none) .basic else detected;
        assert(style.color_mode != .none);
    }
    return style;
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "Usage: du") != null);
    try testing.expect(std.mem.find(
        u8,
        stdout_buffer_aw.writer.buffered(),
        "--human-readable",
    ) != null);
}

test "du --version shows version" {
    const io = testing.io;
    var stdout_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_buffer_aw.deinit();

    const args = &[_][]const u8{"--version"};
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_buffer_aw.writer.buffered(), "du") != null);
    try testing.expect(std.mem.find(
        u8,
        stdout_buffer_aw.writer.buffered(),
        common.version,
    ) != null);
}

test "du invalid flag exits with code 2" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"--invalid-flag"};
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "du nonexistent path exits with code 1" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"/nonexistent/path/xyz"};
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(
        u8,
        stderr_buffer_aw.writer.buffered(),
        "No such file or directory",
    ) != null);
}

test "du -s and -d conflict exits with code 2" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{ "-s", "-d", "1" };
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
        .display = common.display_config.DisplayConfig{
            .color = .off,
            .icons = .off,
            .highlight = .off,
            .theme = .none,
        },
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.find(
        u8,
        stderr_buffer_aw.writer.buffered(),
        "invalid argument",
    ) != null);
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
        .display = common.display_config.DisplayConfig{
            .color = .off,
            .icons = .off,
            .highlight = .off,
            .theme = .none,
        },
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
        .display = common.display_config.DisplayConfig{
            .color = .off,
            .icons = .on,
            .highlight = .off,
            .theme = .none,
        },
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
        .display = common.display_config.DisplayConfig{
            .color = .off,
            .icons = .on,
            .highlight = .off,
            .theme = .none,
        },
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

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
    const exit_no_r = runDu(
        testing.allocator,
        io,
        args_no_r,
        &stdout_without_r_aw.writer,
        common.null_writer,
    );

    // Run with -r
    var stdout_with_r_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_with_r_aw.deinit();

    const args_with_r = &[_][]const u8{ "-r", "-b", dir_path };
    const exit_with_r = runDu(
        testing.allocator,
        io,
        args_with_r,
        &stdout_with_r_aw.writer,
        common.null_writer,
    );

    // Both should succeed and produce identical output
    try testing.expectEqual(@as(u8, 0), exit_no_r);
    try testing.expectEqual(@as(u8, 0), exit_with_r);
    try testing.expectEqualStrings(
        stdout_without_r_aw.writer.buffered(),
        stdout_with_r_aw.writer.buffered(),
    );
}

// ============================================================================
// Tests for du -H (dereference command-line symlink arguments only)
// ============================================================================

test "du -H flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-H"};
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit1 = runDu(
        testing.allocator,
        io,
        &[_][]const u8{ "-b", dir_path },
        &stdout_without_aw.writer,
        common.null_writer,
    );

    // With -I (stub, should produce same output)
    var stdout_with_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_with_aw.deinit();
    const exit2 = runDu(
        testing.allocator,
        io,
        &[_][]const u8{ "-I", "*.o", "-b", dir_path },
        &stdout_with_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit1);
    try testing.expectEqual(@as(u8, 0), exit2);
    try testing.expectEqualStrings(
        stdout_without_aw.writer.buffered(),
        stdout_with_aw.writer.buffered(),
    );
}

// ============================================================================
// Tests for -l (count hard links multiple times)
// ============================================================================

test "du -l flag is accepted by argparse" {
    const io = testing.io;
    var stderr_buffer_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_buffer_aw.deinit();

    const args = &[_][]const u8{"-l"};
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        common.null_writer,
        &stderr_buffer_aw.writer,
    );
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(
        u8,
        stdout_buffer_aw.writer.buffered(),
        "--apparent-size",
    ) != null);
    try testing.expect(std.mem.find(
        u8,
        stdout_buffer_aw.writer.buffered(),
        "--block-size",
    ) != null);
    try testing.expect(std.mem.find(
        u8,
        stdout_buffer_aw.writer.buffered(),
        "--count-links",
    ) != null);
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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

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
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_buffer_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Extract the size reported for the subdirectory
    const sub_size = extractSizeForPath(stdout_buffer_aw.writer.buffered(), sub_path) orelse {
        return error.TestUnexpectedResult;
    };

    // GNU du -S -b: sub shows 10 (just subfile.txt).
    // Our implementation reports dir_own_size for subdirectory too.
    try testing.expectEqual(@as(u64, 10), sub_size);
}

// ============================================================================
// CHARACTERIZATION TESTS for the calculateDu -> bounded-walker migration.
//
// These lock in the externally observable behavior the walker rewrite must
// preserve. They run against the CURRENT recursive implementation and must
// PASS today; a later sabotage step proves each can go RED.
//
// All sizes are exercised with `-b` (apparent-size, block-size=1) so the
// reported numbers are exact file content lengths, independent of the
// filesystem's block size. Directory metadata contributes 0 in apparent-size
// mode (see F23), so a directory's reported total is purely the sum of the
// file bytes it contains (recursively, unless -S).
// ============================================================================

/// Parse the size for the line whose path field equals `path` EXACTLY.
/// du prints "<size>\t<path>\n"; matching the whole path (tab before, newline
/// after) avoids the prefix-collision bug where a parent path is a substring of
/// a child's path (e.g. "/root" matches the "/root/sub" line printed earlier in
/// post-order). Returns null when no exact-path line is found.
fn extractSizeForExactPath(output: []const u8, path: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const tab_pos = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[tab_pos + 1 ..], path)) continue;
        return std.fmt.parseInt(u64, line[0..tab_pos], 10) catch null;
    }
    return null;
}

/// Count the number of output lines that mention the given path substring.
/// Used to assert that a path is emitted exactly once (dedup) or N times
/// (e.g. -L following a symlink to an already-seen subtree).
fn countLinesWithPath(output: []const u8, path: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.find(u8, line, path) != null) count += 1;
    }
    return count;
}

test "du subtree size accumulates onto the post-order unwind (parent = own + children)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Two files directly under the root, exactly 10 + 25 = 35 bytes.
    const f1 = try tmp_dir.dir.createFile(io, "a.txt", .{});
    try f1.writeStreamingAll(io, "AAAAAAAAAA"); // 10 bytes
    f1.close(io);
    const f2 = try tmp_dir.dir.createFile(io, "b.txt", .{});
    try f2.writeStreamingAll(io, "BBBBBBBBBBBBBBBBBBBBBBBBB"); // 25 bytes
    f2.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &path_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-b", "-s", dir_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    // In apparent-size mode the directory metadata is 0, so the total must be
    // exactly the sum of the two files. A wrong accumulation (drop a child,
    // double-count, etc.) would not yield 35.
    const total = extractLastLineSize(
        out.writer.buffered(),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 35), total);
}

test "du multi-level tree rolls descendant sizes into every ancestor" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // root/top.txt (3) + root/mid/m.txt (5) + root/mid/deep/d.txt (7)
    const ft = try tmp_dir.dir.createFile(io, "top.txt", .{});
    try ft.writeStreamingAll(io, "TTT"); // 3
    ft.close(io);
    try tmp_dir.dir.createDir(io, "mid", .default_dir);
    const fm = try tmp_dir.dir.createFile(io, "mid/m.txt", .{});
    try fm.writeStreamingAll(io, "MMMMM"); // 5
    fm.close(io);
    try tmp_dir.dir.createDir(io, "mid/deep", .default_dir);
    const fd = try tmp_dir.dir.createFile(io, "mid/deep/d.txt", .{});
    try fd.writeStreamingAll(io, "DDDDDDD"); // 7
    fd.close(io);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];
    var mid_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mid_path = mid_buf[0..(try tmp_dir.dir.realPathFile(io, "mid", &mid_buf))];
    var deep_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deep_path = deep_buf[0..(try tmp_dir.dir.realPathFile(io, "mid/deep", &deep_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-b", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // deep = 7; mid = 5 + 7 = 12; root = 3 + 12 = 15.
    try testing.expectEqual(@as(?u64, 7), extractSizeForExactPath(buf, deep_path));
    try testing.expectEqual(@as(?u64, 12), extractSizeForExactPath(buf, mid_path));
    try testing.expectEqual(@as(?u64, 15), extractSizeForExactPath(buf, root_path));
}

test "du -c grand total equals sum across multiple operands" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "one", .default_dir);
    const f1 = try tmp_dir.dir.createFile(io, "one/x.txt", .{});
    try f1.writeStreamingAll(io, "XXXXXXXXXXXX"); // 12
    f1.close(io);
    try tmp_dir.dir.createDir(io, "two", .default_dir);
    const f2 = try tmp_dir.dir.createFile(io, "two/y.txt", .{});
    try f2.writeStreamingAll(io, "YYYYYYYY"); // 8
    f2.close(io);

    var one_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const one_path = one_buf[0..(try tmp_dir.dir.realPathFile(io, "one", &one_buf))];
    var two_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const two_path = two_buf[0..(try tmp_dir.dir.realPathFile(io, "two", &two_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-c", "-b", one_path, two_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // The "total" line is the last line and must equal 12 + 8 = 20.
    const grand_total = extractLastLineSize(buf) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, buf, "total") != null);
    try testing.expectEqual(@as(u64, 20), grand_total);
}

test "du counts a hard-linked file once across the whole walk" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A 40-byte file plus a hard link to it in the same directory.
    const f = try tmp_dir.dir.createFile(io, "original.txt", .{});
    const data = [_]u8{'Z'} ** 40;
    try f.writeStreamingAll(io, &data);
    f.close(io);

    var orig_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_abs = orig_buf[0..(try tmp_dir.dir.realPathFile(io, "original.txt", &orig_buf))];
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_abs = dir_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &dir_buf))];

    const link_abs = try std.fmt.allocPrint(testing.allocator, "{s}/hardlink.txt", .{dir_abs});
    defer testing.allocator.free(link_abs);
    std.Io.Dir.hardLink(
        std.Io.Dir.cwd(),
        orig_abs,
        std.Io.Dir.cwd(),
        link_abs,
        io,
        .{},
    ) catch |err| {
        if (err == error.AccessDenied) return; // skip where hard links are unsupported
        return err;
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-b", "-s", dir_abs };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    // Dedup by (dev,ino): the 40 bytes are counted once, not twice.
    const total = extractLastLineSize(
        out.writer.buffered(),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 40), total);
}

test "du -l counts a hard-linked file every time it is encountered" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(io, "original.txt", .{});
    const data = [_]u8{'Z'} ** 40;
    try f.writeStreamingAll(io, &data);
    f.close(io);

    var orig_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_abs = orig_buf[0..(try tmp_dir.dir.realPathFile(io, "original.txt", &orig_buf))];
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_abs = dir_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &dir_buf))];

    const link_abs = try std.fmt.allocPrint(testing.allocator, "{s}/hardlink.txt", .{dir_abs});
    defer testing.allocator.free(link_abs);
    std.Io.Dir.hardLink(
        std.Io.Dir.cwd(),
        orig_abs,
        std.Io.Dir.cwd(),
        link_abs,
        io,
        .{},
    ) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // -l disables dedup: both links count, total = 40 + 40 = 80.
    const args = &[_][]const u8{ "-l", "-b", "-s", dir_abs };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const total = extractLastLineSize(
        out.writer.buffered(),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 80), total);
}

test "du -S directory total excludes subdirectory subtrees but root total still rolls up" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // root has one direct file (11 bytes) and a subdir holding a 30-byte file.
    const ft = try tmp_dir.dir.createFile(io, "direct.txt", .{});
    try ft.writeStreamingAll(io, "DDDDDDDDDDD"); // 11
    ft.close(io);
    try tmp_dir.dir.createDir(io, "sub", .default_dir);
    const fs = try tmp_dir.dir.createFile(io, "sub/inner.txt", .{});
    const data = [_]u8{'I'} ** 30;
    try fs.writeStreamingAll(io, &data); // 30
    fs.close(io);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];
    var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sub_path = sub_buf[0..(try tmp_dir.dir.realPathFile(io, "sub", &sub_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-S", "-b", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // With -S the root counts only its direct file (11), NOT the 30-byte
    // subtree; the sub directory counts its own direct file (30).
    try testing.expectEqual(@as(?u64, 11), extractSizeForExactPath(buf, root_path));
    try testing.expectEqual(@as(?u64, 30), extractSizeForExactPath(buf, sub_path));
}

test "du -S in disk-usage mode includes the directory's own block allocation" {
    // Regression: under -S the printed value must include the directory's OWN
    // block allocation plus its direct files, not just the direct files. Every
    // other -S test uses -b (apparent size), where a directory's own size is 0
    // and so masks a dropped dir_own_size. Here we run disk-usage mode with
    // -B 1 (byte-exact, no rounding) and assert the printed value equals
    // dir_own_blocks*512 + direct_file_blocks*512 computed straight from stat.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ft = try tmp_dir.dir.createFile(io, "direct.txt", .{});
    const data = [_]u8{'D'} ** 4096;
    try ft.writeStreamingAll(io, &data); // big enough to occupy real blocks
    ft.close(io);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];
    var file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file_path = file_buf[0..(try tmp_dir.dir.realPathFile(io, "direct.txt", &file_buf))];

    // Compute the expected disk-usage -S value directly from stat: the
    // directory's own blocks plus its single direct file's blocks.
    const dir_stat = try doStat(root_path, true);
    const file_stat = try doStat(file_path, true);
    const dir_own_bytes: u64 = @as(u64, @intCast(@max(0, dir_stat.blocks))) * 512;
    const file_bytes: u64 = @as(u64, @intCast(@max(0, file_stat.blocks))) * 512;
    const expected = dir_own_bytes + file_bytes;

    // Some filesystems (notably macOS APFS/HFS+) store small directories in
    // b-tree metadata and report st_blocks == 0 for them. On those, the
    // directory has no own block allocation to include, so this regression
    // cannot be exercised; skip rather than fail. On Linux (ext4/tmpfs) a
    // directory always occupies at least one block, so the teeth below hold.
    if (dir_own_bytes == 0) return error.SkipZigTest;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // -S separate-dirs, -B 1 byte-exact, disk-usage mode (NO -b).
    const args = &[_][]const u8{ "-S", "-B", "1", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const printed = extractSizeForExactPath(out.writer.buffered(), root_path) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, expected), printed);
    // The directory's own block allocation must be non-zero in disk-usage mode,
    // so this assertion has teeth: dropping dir_own_size would make printed
    // equal file_bytes only, which is strictly less than expected.
    try testing.expect(dir_own_bytes > 0);
}

test "du -d 1 hides deep entries but still accumulates their sizes upward" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // root/mid/deep/d.txt = 50 bytes; nothing else.
    try tmp_dir.dir.createDir(io, "mid", .default_dir);
    try tmp_dir.dir.createDir(io, "mid/deep", .default_dir);
    const fd = try tmp_dir.dir.createFile(io, "mid/deep/d.txt", .{});
    const data = [_]u8{'X'} ** 50;
    try fd.writeStreamingAll(io, &data);
    fd.close(io);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];
    var mid_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mid_path = mid_buf[0..(try tmp_dir.dir.realPathFile(io, "mid", &mid_buf))];
    var deep_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deep_path = deep_buf[0..(try tmp_dir.dir.realPathFile(io, "mid/deep", &deep_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // --max-depth=1: print root (depth 0) and mid (depth 1); hide deep (depth 2).
    const args = &[_][]const u8{ "-d", "1", "-b", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // deep is a DISPLAY filter only: its line is suppressed...
    try testing.expectEqual(@as(usize, 0), countLinesWithPath(buf, deep_path));
    // ...but its 50 bytes still roll up into mid (depth 1) and root (depth 0).
    try testing.expectEqual(@as(?u64, 50), extractSizeForExactPath(buf, mid_path));
    try testing.expectEqual(@as(?u64, 50), extractSizeForExactPath(buf, root_path));
}

test "du -a prints every file while default prints only directories" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f1 = try tmp_dir.dir.createFile(io, "leaf_one.txt", .{});
    try f1.writeStreamingAll(io, "one\n");
    f1.close(io);
    const f2 = try tmp_dir.dir.createFile(io, "leaf_two.txt", .{});
    try f2.writeStreamingAll(io, "two\n");
    f2.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &path_buf))];

    // Default (no -a): individual files are NOT printed.
    var out_default: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_default.deinit();
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        &[_][]const u8{ "-b", dir_path },
        &out_default.writer,
        common.null_writer,
    ));
    try testing.expect(std.mem.find(u8, out_default.writer.buffered(), "leaf_one.txt") == null);
    try testing.expect(std.mem.find(u8, out_default.writer.buffered(), "leaf_two.txt") == null);

    // -a: every file IS printed.
    var out_all: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_all.deinit();
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        &[_][]const u8{ "-a", "-b", dir_path },
        &out_all.writer,
        common.null_writer,
    ));
    try testing.expect(std.mem.find(u8, out_all.writer.buffered(), "leaf_one.txt") != null);
    try testing.expect(std.mem.find(u8, out_all.writer.buffered(), "leaf_two.txt") != null);
}

test "du default (-P) reports symlink size, not its target's subtree" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A real dir with a 1000-byte file, plus a symlink to it inside root.
    try tmp_dir.dir.createDir(io, "real", .default_dir);
    const fr = try tmp_dir.dir.createFile(io, "real/big.txt", .{});
    const data = [_]u8{'R'} ** 1000;
    try fr.writeStreamingAll(io, &data);
    fr.close(io);
    tmp_dir.dir.symLink(io, "real", "alias", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // Default policy (-P): do not follow symlinks. The 1000-byte file is
    // counted exactly once (via real/), never a second time via alias/.
    const args = &[_][]const u8{ "-a", "-b", "-P", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // The target file appears once (under real/), proving alias was not traversed.
    try testing.expectEqual(@as(usize, 1), countLinesWithPath(buf, "big.txt"));
    // Root total = the file (1000) + the symlink's own tiny size; it must be
    // far below 2000, which would indicate the target subtree was followed.
    try testing.expect((extractSizeForExactPath(buf, root_path) orelse 0) < 2000);
}

test "du -L follows symlinked directory and counts the target subtree" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "real", .default_dir);
    const fr = try tmp_dir.dir.createFile(io, "real/inside.txt", .{});
    try fr.writeStreamingAll(io, "INSIDE-DATA\n");
    fr.close(io);
    tmp_dir.dir.symLink(io, "real", "alias", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // -L follows all symlinks, so inside.txt is reachable via BOTH real/ and
    // alias/ and thus appears twice (the dir target itself has nlink>1 only
    // for dirs; the file is not deduped because it is reached through two
    // distinct directory paths).
    const args = &[_][]const u8{ "-a", "-b", "-L", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    try testing.expectEqual(@as(usize, 2), countLinesWithPath(buf, "inside.txt"));
}

test "du -aL reports a dangling symlink and exits 1 (issue #47)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A readable regular file plus a dangling symlink (points at a name that
    // does not exist). Under -L du must dereference "broken", fail to stat its
    // target, emit a diagnostic, and exit 1 -- while still tallying real.txt.
    // GNU coreutils 9.7: "du: cannot access '<dir>/broken'" + exit 1.
    const fr = try tmp_dir.dir.createFile(io, "real.txt", .{});
    try fr.writeStreamingAll(io, "hello\n");
    fr.close(io);
    tmp_dir.dir.symLink(io, "does_not_exist", "broken", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();

    const args = &[_][]const u8{ "-a", "-b", "-L", root_path };
    const exit_code = try runDu(testing.allocator, io, args, &out.writer, &err_out.writer);

    // The unstattable symlink must not be silently dropped: diagnostic naming
    // the path, nonzero exit, and the walk still completes for real.txt.
    try testing.expect(std.mem.find(u8, err_out.writer.buffered(), "cannot access") != null);
    try testing.expect(std.mem.find(u8, err_out.writer.buffered(), "broken") != null);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, out.writer.buffered(), "real.txt") != null);
}

test "du -L reports a symlink loop (ELOOP) and exits 1 (issue #47)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A mutually-referential symlink pair: loop_a -> loop_b -> loop_a. Under -L
    // du dereferences each and the OS returns ELOOP; du must report it and exit
    // 1, not silently skip. GNU coreutils 9.7:
    // "du: cannot access '<dir>/loop_a': Too many levels of symbolic links" + 1.
    const fr = try tmp_dir.dir.createFile(io, "real.txt", .{});
    try fr.writeStreamingAll(io, "hi\n");
    fr.close(io);
    tmp_dir.dir.symLink(io, "loop_b", "loop_a", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };
    tmp_dir.dir.symLink(io, "loop_a", "loop_b", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();

    const args = &[_][]const u8{ "-a", "-b", "-L", root_path };
    const exit_code = try runDu(testing.allocator, io, args, &out.writer, &err_out.writer);

    // The ELOOP entry must surface a diagnostic and a nonzero exit; the walk
    // still finishes and tallies the readable file.
    try testing.expect(std.mem.find(u8, err_out.writer.buffered(), "cannot access") != null);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, out.writer.buffered(), "real.txt") != null);
}

test "du -H follows an operand symlink but not symlinks discovered during the walk" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // operand_link -> realtop; realtop/inner -> realtop/sub (an internal link).
    try tmp_dir.dir.createDir(io, "realtop", .default_dir);
    try tmp_dir.dir.createDir(io, "realtop/sub", .default_dir);
    const fr = try tmp_dir.dir.createFile(io, "realtop/sub/leaf.txt", .{});
    try fr.writeStreamingAll(io, "LEAFDATA\n");
    fr.close(io);
    tmp_dir.dir.symLink(io, "realtop", "operand_link", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };
    tmp_dir.dir.symLink(io, "sub", "realtop/inner", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path = base_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &base_buf))];
    const operand = try std.fmt.allocPrint(testing.allocator, "{s}/operand_link", .{base_path});
    defer testing.allocator.free(operand);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // -H follows the operand symlink (so we descend into realtop) but does NOT
    // follow the internal "inner" symlink, so leaf.txt appears exactly once.
    const args = &[_][]const u8{ "-a", "-b", "-H", operand };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // Operand was followed: we reached leaf.txt at all.
    try testing.expect(std.mem.find(u8, buf, "leaf.txt") != null);
    // Internal symlink was NOT followed: leaf.txt counted once, not twice.
    try testing.expectEqual(@as(usize, 1), countLinesWithPath(buf, "leaf.txt"));
}

test "du -b apparent size differs from default disk usage for a sub-block file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A 1-byte file: apparent size is 1; disk usage rounds up to a block.
    const f = try tmp_dir.dir.createFile(io, "one_byte", .{});
    try f.writeStreamingAll(io, "Z");
    f.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file_path = path_buf[0..(try tmp_dir.dir.realPathFile(io, "one_byte", &path_buf))];

    // Apparent size in bytes: exactly 1.
    var out_apparent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_apparent.deinit();
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        &[_][]const u8{ "-b", file_path },
        &out_apparent.writer,
        common.null_writer,
    ));
    try testing.expectEqual(@as(?u64, 1), extractLastLineSize(out_apparent.writer.buffered()));

    // Disk usage with --block-size=1: allocated bytes, rounded to >= 512.
    var out_disk: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_disk.deinit();
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        &[_][]const u8{ "-B", "1", file_path },
        &out_disk.writer,
        common.null_writer,
    ));
    const disk = extractLastLineSize(
        out_disk.writer.buffered(),
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(disk >= 512);
}

test "du survives a symlink cycle without infinite recursion (-L)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // dir_a/loop -> dir_a (a self-referential cycle). Under -L a naive walker
    // would recurse forever; du must terminate (the walker's cycle detection /
    // depth bound, or the dedup on the directory inode, must stop it).
    try tmp_dir.dir.createDir(io, "dir_a", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "dir_a/file.txt", .{});
    try f.writeStreamingAll(io, "CYCLE\n");
    f.close(io);
    tmp_dir.dir.symLink(io, ".", "dir_a/loop", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..(try tmp_dir.dir.realPathFile(io, "dir_a", &path_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // Must not hang. Exit code may be 0 or 1 (it may report the loop), but it
    // must terminate and produce output for the directory operand.
    const args = &[_][]const u8{ "-b", "-L", dir_path };
    const exit_code = try runDu(testing.allocator, io, args, &out.writer, common.null_writer);
    _ = exit_code;
    try testing.expect(std.mem.find(u8, out.writer.buffered(), dir_path) != null);
}

test "du -L prunes an ancestor symlink loop and reports it as a cycle (issue #61)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // cyc/inner/up -> ".." resolves back to cyc, an ANCESTOR of inner (not a
    // self-loop). Reference: GNU du 9.5 prunes this silently (rc=0, empty
    // stderr, one line per real directory -- see docs/specs scouting for
    // this issue). vibeutils intentionally diverges here as a documented
    // enhancement: the cycle_mode=.ancestors redesign makes the cycle
    // diagnosable (a printed diagnostic mentioning the cycle/loop, has_error
    // set, exit code 1) while still pruning promptly -- exactly two
    // directory lines (inner, cyc), never re-descending through
    // ".../cyc/inner/up/inner/up/...".
    try tmp_dir.dir.createDir(io, "cyc", .default_dir);
    try tmp_dir.dir.createDir(io, "cyc/inner", .default_dir);
    tmp_dir.dir.symLink(io, "..", "cyc/inner/up", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..(try tmp_dir.dir.realPathFile(io, "cyc", &path_buf))];

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = &[_][]const u8{ "-L", dir_path };
    const exit_code = try runDu(
        testing.allocator,
        io,
        args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    const stdout = stdout_aw.writer.buffered();
    const stderr = stderr_aw.writer.buffered();

    try testing.expectEqual(@as(u8, 1), exit_code);

    // Exactly two directory lines: "cyc/inner" and "cyc". A runaway walker
    // would keep emitting deepening "up/inner/up/inner/..." lines instead.
    var line_count: u32 = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try testing.expectEqual(@as(u32, 2), line_count);
    try testing.expect(std.mem.find(u8, stdout, "/up/inner") == null);

    // The diagnostic wording is not pinned to GNU (GNU prints nothing here);
    // accept any of the plausible words a "this is a cycle" message would
    // use so the test doesn't lock the implementer into one exact string.
    const mentions_cycle = std.ascii.findIgnoreCase(stderr, "cycle") != null or
        std.ascii.findIgnoreCase(stderr, "loop") != null or
        std.ascii.findIgnoreCase(stderr, "circular") != null;
    try testing.expect(mentions_cycle);
}

test "du emits directory operand in post-order: children printed before their parent" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // root/child/leaf.txt — verify the child line precedes the root line, the
    // hallmark of post-order accumulation the walker must preserve.
    try tmp_dir.dir.createDir(io, "child", .default_dir);
    const f = try tmp_dir.dir.createFile(io, "child/leaf.txt", .{});
    try f.writeStreamingAll(io, "LEAF\n");
    f.close(io);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];
    var child_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const child_path = child_buf[0..(try tmp_dir.dir.realPathFile(io, "child", &child_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-b", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // The child directory's line: "<size>\t<child_path>\n".
    const child_idx = std.mem.find(u8, buf, child_path) orelse return error.TestUnexpectedResult;
    // The root's own line ends with "\t<root_path>\n". Because root_path is a
    // prefix of child_path, match the exact "<tab><root_path><newline>" marker
    // so we find the root's line and not the child line.
    const root_marker = try std.fmt.allocPrint(testing.allocator, "\t{s}\n", .{root_path});
    defer testing.allocator.free(root_marker);
    const root_idx = std.mem.find(u8, buf, root_marker) orelse return error.TestUnexpectedResult;
    // child appears strictly before the root's line: post-order accumulation.
    try testing.expect(child_idx < root_idx);
}

test "du -x stays on one filesystem and fully traverses the single-device tree" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A multi-level tree that lives entirely on one filesystem (testing.tmpDir
    // does not span a mount boundary). With -x active, every descendant shares
    // the root's device, so all of them MUST still be traversed and rolled up.
    //
    // Teeth: the walker migration replaces the old `dev != root_dev` check with
    // the walker's stay_on_filesystem device tracking. A regression that prunes
    // descent for same-device children (e.g. an inverted comparison, a stale
    // root device, or descending only the root) would drop the deep file's
    // bytes and the total would fall below the full sum. We assert the EXACT
    // full sum in apparent-size mode, where directory metadata contributes 0,
    // so the total equals precisely the sum of the file bytes.
    //
    // True CROSS-device pruning requires a real mount and is covered by
    // integration tests; this locks in that -x does not break the common
    // single-filesystem case (matches the chown -x privileged-test pattern).
    const top = try tmp_dir.dir.createFile(io, "top.txt", .{});
    try top.writeStreamingAll(io, "TTTT"); // 4
    top.close(io);
    try tmp_dir.dir.createDir(io, "sub", .default_dir);
    const mid = try tmp_dir.dir.createFile(io, "sub/mid.txt", .{});
    try mid.writeStreamingAll(io, "MMMMMM"); // 6
    mid.close(io);
    try tmp_dir.dir.createDir(io, "sub/deep", .default_dir);
    const deep = try tmp_dir.dir.createFile(io, "sub/deep/d.txt", .{});
    try deep.writeStreamingAll(io, "DDDDDDDD"); // 8
    deep.close(io);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..(try tmp_dir.dir.realPathFile(io, ".", &root_buf))];
    var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sub_path = sub_buf[0..(try tmp_dir.dir.realPathFile(io, "sub", &sub_buf))];

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const args = &[_][]const u8{ "-x", "-b", root_path };
    try testing.expectEqual(@as(u8, 0), try runDu(
        testing.allocator,
        io,
        args,
        &out.writer,
        common.null_writer,
    ));

    const buf = out.writer.buffered();
    // sub = 6 + 8 = 14 (deep descendant rolled up despite -x).
    try testing.expectEqual(@as(?u64, 14), extractSizeForExactPath(buf, sub_path));
    // root = 4 + 14 = 18 (whole single-device tree accounted for).
    try testing.expectEqual(@as(?u64, 18), extractSizeForExactPath(buf, root_path));
}
