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
        .summarize = .{ .short = 's', .desc = "Display only a total for each argument" },
        .separate_dirs = .{ .short = 'S', .desc = "For directories do not include size of subdirectories" },
        .one_file_system = .{ .short = 'x', .desc = "Skip directories on different file systems" },
        .apparent_size = .{ .short = 0, .desc = "Print apparent sizes rather than disk usage" },
        .block_size = .{ .short = 0, .desc = "Scale sizes by SIZE before printing", .value_name = "SIZE" },
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

// ============================================================================
// Resolved configuration after processing option interactions
// ============================================================================

const DuConfig = struct {
    all: bool,
    total: bool,
    max_depth: ?u64,
    human_readable: bool,
    dereference: bool,
    summarize: bool,
    separate_dirs: bool,
    one_file_system: bool,
    apparent_size: bool,
    block_size: u64,
};

fn resolveConfig(opts: DuOptions) !DuConfig {
    var config = DuConfig{
        .all = opts.all,
        .total = opts.total,
        .max_depth = null,
        .human_readable = opts.human_readable,
        .dereference = opts.dereference,
        .summarize = opts.summarize,
        .separate_dirs = opts.separate_dirs,
        .one_file_system = opts.one_file_system,
        .apparent_size = opts.apparent_size,
        .block_size = 1024, // default
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
    stderr: anytype,
    has_error: *bool,
) u64 {
    const stat_buf = doStat(path, config.dereference) catch |err| {
        printStatError(allocator, stderr, path, err);
        has_error.* = true;
        return 0;
    };

    const mode = stat_buf.mode;
    const is_dir = (mode & c.S.IFMT) == c.S.IFDIR;
    const is_symlink = (mode & c.S.IFMT) == c.S.IFLNK;

    // Skip symlinks in non-dereference mode (for recursive traversal only,
    // not for top-level arguments)
    if (is_symlink and !config.dereference and depth > 0) {
        // Report symlink itself if -a
        const link_size = getFileSize(stat_buf, config.apparent_size);
        if (config.all and shouldPrintAtDepth(depth, config)) {
            printEntry(stdout, link_size, config, path);
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
            printEntry(stdout, file_size, config, path);
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
            printEntry(stdout, dir_own_size, config, path);
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
            stderr,
            has_error,
        );
        subtree_size += child_size;
    }

    const total_size = if (config.separate_dirs) dir_own_size else dir_own_size + subtree_size;

    if (shouldPrintAtDepth(depth, config)) {
        printEntry(stdout, total_size, config, path);
    }

    return dir_own_size + subtree_size;
}

fn shouldPrintAtDepth(depth: u64, config: DuConfig) bool {
    if (config.max_depth) |max_d| {
        return depth <= max_d;
    }
    return true;
}

fn printEntry(writer: anytype, size_bytes: u64, config: DuConfig, path: []const u8) void {
    if (config.human_readable) {
        var hr_buf: [32]u8 = undefined;
        const formatted = formatHumanReadable(&hr_buf, size_bytes);
        writer.print("{s}\t{s}\n", .{ formatted, path }) catch {};
    } else {
        // Scale by block_size
        const blocks = if (config.block_size <= 1)
            size_bytes
        else
            (size_bytes + config.block_size - 1) / config.block_size;
        writer.print("{d}\t{s}\n", .{ blocks, path }) catch {};
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
    common.printErrorWithProgram(allocator, stderr, prog_name, "cannot access '{s}': {s}", .{ path, msg });
}

fn printDirError(allocator: Allocator, stderr: anytype, path: []const u8, err: anyerror) void {
    const msg = switch (err) {
        error.AccessDenied => "Permission denied",
        error.FileNotFound => "No such file or directory",
        else => "Cannot read directory",
    };
    common.printErrorWithProgram(allocator, stderr, prog_name, "cannot read directory '{s}': {s}", .{ path, msg });
}

fn printIterError(allocator: Allocator, stderr: anytype, path: []const u8, err: anyerror) void {
    common.printErrorWithProgram(allocator, stderr, prog_name, "cannot read directory '{s}': {s}", .{ path, @errorName(err) });
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
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
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
        printHelp(stdout);
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

    const config = resolveConfig(opts) catch |err| {
        switch (err) {
            error.InvalidBlockSize => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid --block-size argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidMaxDepth => {
                common.printErrorWithProgram(allocator, stderr, prog_name, "invalid maximum depth '{s}'", .{opts.max_depth orelse ""});
                return @intFromEnum(common.ExitCode.misuse);
            },
        }
    };

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
            stderr,
            &has_error,
        );
        grand_total += size;
    }

    if (config.total) {
        printEntry(stdout, grand_total, config, "total");
    }

    return if (has_error) @as(u8, 1) else 0;
}

// ============================================================================
// Help and version
// ============================================================================

fn printHelp(writer: anytype) void {
    writer.writeAll(
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
        \\  -k                    like --block-size=1K
        \\  -L, --dereference     dereference all symbolic links
        \\  -s, --summarize       display only a total for each argument
        \\  -S, --separate-dirs   for directories do not include size of subdirectories
        \\  -x, --one-file-system skip directories on different file systems
        \\      --apparent-size   print apparent sizes rather than disk usage
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
    const config = try resolveConfig(opts);
    try testing.expectEqual(@as(u64, 1024), config.block_size);
    try testing.expect(!config.apparent_size);
    try testing.expect(!config.human_readable);
    try testing.expect(!config.summarize);
    try testing.expectEqual(@as(?u64, null), config.max_depth);
}

test "resolveConfig - bytes flag" {
    var opts = DuOptions{};
    opts.bytes = true;
    const config = try resolveConfig(opts);
    try testing.expectEqual(@as(u64, 1), config.block_size);
    try testing.expect(config.apparent_size);
}

test "resolveConfig - kilobytes flag" {
    var opts = DuOptions{};
    opts.kilobytes = true;
    const config = try resolveConfig(opts);
    try testing.expectEqual(@as(u64, 1024), config.block_size);
}

test "resolveConfig - summarize implies max-depth=0" {
    var opts = DuOptions{};
    opts.summarize = true;
    const config = try resolveConfig(opts);
    try testing.expectEqual(@as(?u64, 0), config.max_depth);
}

test "resolveConfig - max-depth" {
    var opts = DuOptions{};
    opts.max_depth = "3";
    const config = try resolveConfig(opts);
    try testing.expectEqual(@as(?u64, 3), config.max_depth);
}

test "resolveConfig - invalid max-depth" {
    var opts = DuOptions{};
    opts.max_depth = "abc";
    try testing.expectError(error.InvalidMaxDepth, resolveConfig(opts));
}

test "resolveConfig - block-size option" {
    var opts = DuOptions{};
    opts.block_size = "1M";
    const config = try resolveConfig(opts);
    try testing.expectEqual(@as(u64, 1048576), config.block_size);
}

test "resolveConfig - invalid block-size" {
    var opts = DuOptions{};
    opts.block_size = "invalid";
    try testing.expectError(error.InvalidBlockSize, resolveConfig(opts));
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
        .dereference = false,
        .summarize = false,
        .separate_dirs = false,
        .one_file_system = false,
        .apparent_size = false,
        .block_size = 1024,
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
