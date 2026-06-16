//! realpath - resolve canonical file names
//!
//! Resolves each pathname argument to an absolute pathname with no `.`, `..`,
//! or symbolic link components. Follows GNU coreutils behavior with support
//! for missing path components and relative output.

const std = @import("std");
const common = @import("common");
const path_utils = common.path;
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Resolve an absolute path to its canonical form, returning a heap-allocated
/// `[]u8` (not sentinel-terminated). Using a stack buffer + `allocator.dupe`
/// avoids the debug-allocator size mismatch from `realPathFileAbsoluteAlloc`
/// returning `[:0]u8` which when freed as `[]u8` reports the wrong size.
fn realPathAbsoluteDupe(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.realPathFileAbsolute(io, path, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

/// Command-line arguments for the realpath utility
const RealpathArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// All components must exist (default)
    canonicalize_existing: bool = false,
    /// No components need exist
    canonicalize_missing: bool = false,
    /// Don't resolve symlinks, just canonicalize . and ..
    no_symlinks: bool = false,
    /// Use NUL delimiter instead of newline
    zero: bool = false,
    /// Suppress error messages
    quiet: bool = false,
    /// Print path relative to DIR
    relative_to: ?[]const u8 = null,
    /// Print path relative to DIR if under it
    relative_base: ?[]const u8 = null,
    /// Positional arguments (pathnames)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .canonicalize_existing = .{ .short = 'e', .desc = "All components must exist (default)" },
        .canonicalize_missing = .{ .short = 'm', .desc = "No components need exist" },
        .no_symlinks = .{ .short = 's', .desc = "Don't resolve symlinks, just canonicalize" },
        .zero = .{ .short = 'z', .desc = "End each output line with NUL, not newline" },
        .quiet = .{ .short = 'q', .desc = "Suppress most error messages" },
        .relative_to = .{ .short = 0, .desc = "Print path relative to DIR", .value_name = "DIR" },
        .relative_base = .{ .short = 0, .desc = "Print relative if path is under DIR", .value_name = "DIR" },
    };
};

/// Resolve a path without following symlinks, just cleaning . and .. components.
/// Makes the path absolute and removes redundant separators and dot components.
fn resolveLogical(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Get absolute path by prepending cwd if relative
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch return error.FileNotFound;
        break :blk try std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], path });
    };
    defer allocator.free(abs_path);
    // abs_path is always a non-empty absolute path: the isAbsolute branch dups
    // an already-absolute path, the else branch joins onto an absolute cwd.
    std.debug.assert(abs_path.len > 0);
    std.debug.assert(abs_path[0] == '/');

    // Split into components and resolve . and ..
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    defer components.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, abs_path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".")) {
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
            }
        } else {
            try components.append(allocator, component);
        }
    }

    // Build result path
    if (components.items.len == 0) {
        return try allocator.dupe(u8, "/");
    }

    // Calculate total length: leading / + each component + separators
    var total_len: usize = 0;
    for (components.items) |comp| {
        total_len += 1 + comp.len; // '/' + component
    }

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (components.items) |comp| {
        result[pos] = '/';
        pos += 1;
        @memcpy(result[pos .. pos + comp.len], comp);
        pos += comp.len;
    }
    // The build loop writes exactly total_len bytes, so pos lands on total_len.
    std.debug.assert(pos == total_len);

    return result;
}

/// Print a "name: message" resolution error with the program prefix. Shared by
/// the resolve helpers, which all format the identical "{s}: {s}" diagnostic.
fn printResolveError(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    name: []const u8,
    err: anyerror,
) void {
    // posixErrorString never yields an empty string for a real error.
    const message = common.posixErrorString(err);
    std.debug.assert(message.len > 0);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "realpath",
        "{s}: {s}",
        .{ name, message },
    );
}

/// Resolve the target path according to the active canonicalization mode.
/// Returns the owned resolved slice, or null when an error was already
/// reported (the caller then returns false). `opts` passed `*const` (>16 bytes).
fn processPath_resolveTarget(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    opts: *const RealpathArgs,
    stderr_writer: *std.Io.Writer,
) !?[]u8 {
    if (opts.no_symlinks) {
        return resolveLogical(allocator, io, path) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, path, err);
            }
            return null;
        };
    } else if (opts.canonicalize_missing) {
        return path_utils.canonicalizeMissing(allocator, io, path) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, path, err);
            }
            return null;
        };
    } else if (opts.canonicalize_existing) {
        // -e: all components must exist
        return realPathAbsoluteDupe(allocator, io, path) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, path, err);
            }
            return null;
        };
    } else {
        // Default (-E semantics): all but last component must exist.
        return path_utils.canonicalizeParentMustExist(allocator, io, path) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, path, err);
            }
            return null;
        };
    }
}

/// Resolve the relative base directory. Distinct from `processPath_resolveTarget`:
/// the default branch uses `realPathAbsoluteDupe` (no parent-must-exist mode).
/// Returns the owned resolved slice, or null when an error was already reported.
fn processPath_resolveBase(
    allocator: Allocator,
    io: std.Io,
    base_dir: []const u8,
    opts: *const RealpathArgs,
    stderr_writer: *std.Io.Writer,
) !?[]u8 {
    if (opts.no_symlinks) {
        return resolveLogical(allocator, io, base_dir) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, base_dir, err);
            }
            return null;
        };
    } else if (opts.canonicalize_missing) {
        return path_utils.canonicalizeMissing(allocator, io, base_dir) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, base_dir, err);
            }
            return null;
        };
    } else {
        return realPathAbsoluteDupe(allocator, io, base_dir) catch |err| {
            if (!opts.quiet) {
                printResolveError(allocator, stderr_writer, base_dir, err);
            }
            return null;
        };
    }
}

/// Compute the relative-output form of `resolved` against `resolved_base`.
/// When `relative_base_only` is true (--relative-base without --relative-to),
/// only print relative if `resolved` is under `resolved_base`; otherwise always
/// print relative. Returns an owned slice (the caller frees it).
fn processPath_makeRelative(
    allocator: Allocator,
    resolved: []const u8,
    resolved_base: []const u8,
    relative_base_only: bool,
) ![]u8 {
    std.debug.assert(resolved.len > 0);
    std.debug.assert(resolved_base.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(resolved));

    if (relative_base_only) {
        // --relative-base only: print relative if under base, absolute otherwise
        if (std.mem.startsWith(u8, resolved, resolved_base) and
            (resolved.len == resolved_base.len or resolved[resolved_base.len] == '/'))
        {
            const rel = std.fs.path.relative(allocator, "/", null, resolved_base, resolved) catch {
                return try allocator.dupe(u8, resolved);
            };
            // Empty relative path means same directory
            if (rel.len == 0) {
                allocator.free(rel);
                return try allocator.dupe(u8, ".");
            }
            return rel;
        } else {
            return try allocator.dupe(u8, resolved);
        }
    } else {
        // --relative-to: always print relative
        const rel = std.fs.path.relative(allocator, "/", null, resolved_base, resolved) catch {
            return try allocator.dupe(u8, resolved);
        };
        // Empty relative path means same directory
        if (rel.len == 0) {
            allocator.free(rel);
            return try allocator.dupe(u8, ".");
        }
        return rel;
    }
}

/// Write the resolved output followed by the line delimiter (NUL or newline).
fn processPath_writeOutput(stdout_writer: *std.Io.Writer, output: []const u8, zero: bool) !void {
    std.debug.assert(output.len > 0);

    try stdout_writer.writeAll(output);
    if (zero) {
        try stdout_writer.writeByte(0);
    } else {
        try stdout_writer.writeByte('\n');
    }
}

/// Process a single path and write the result
fn processPath(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    opts: RealpathArgs,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !bool {
    const resolved =
        (try processPath_resolveTarget(allocator, io, path, &opts, stderr_writer)) orelse
        return false;
    defer allocator.free(resolved);
    // Every resolver branch returns an absolute path; null was excluded above.
    std.debug.assert(std.fs.path.isAbsolute(resolved));

    // Handle --relative-to and --relative-base
    const output = if (opts.relative_to != null or opts.relative_base != null) blk: {
        const base_dir = opts.relative_to orelse opts.relative_base.?;

        const resolved_base =
            (try processPath_resolveBase(allocator, io, base_dir, &opts, stderr_writer)) orelse
            return false;
        defer allocator.free(resolved_base);

        const relative_base_only = opts.relative_base != null and opts.relative_to == null;
        break :blk try processPath_makeRelative(
            allocator,
            resolved,
            resolved_base,
            relative_base_only,
        );
    } else blk: {
        break :blk try allocator.dupe(u8, resolved);
    };
    defer allocator.free(output);

    try processPath_writeOutput(stdout_writer, output, opts.zero);

    return true;
}

/// Main entry point for the realpath utility
pub fn runRealpath(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    // Pre-process args to handle --strip alias for --no-symlinks
    var processed_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer processed_args.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--strip")) {
            try processed_args.append(allocator, "--no-symlinks");
        } else {
            try processed_args.append(allocator, arg);
        }
    }

    const parsed_args = common.argparse.ArgParser.parseOrExit(RealpathArgs, allocator, processed_args.items, "realpath", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "realpath", "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // The missing-operand guard above returns before reaching this loop, so at
    // least one positional remains (it may be empty, but the count is nonzero).
    std.debug.assert(parsed_args.positionals.len > 0);

    var has_error = false;
    for (parsed_args.positionals) |path| {
        const ok = try processPath(allocator, io, path, parsed_args, stdout_writer, stderr_writer);
        if (!ok) has_error = true;
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: realpath [OPTION]... FILE...
        \\Print the resolved absolute file name; all but the last component must exist.
        \\
        \\  -e, --canonicalize-existing  all components must exist (default)
        \\  -m, --canonicalize-missing   no components need exist
        \\  -s, --no-symlinks, --strip   do not resolve symlinks
        \\  -z, --zero                   end each output line with NUL, not newline
        \\  -q, --quiet                  suppress most error messages
        \\      --relative-to=DIR        print path relative to DIR
        \\      --relative-base=DIR      print path relative to DIR if under it,
        \\                               otherwise print absolute path
        \\  -h, --help                   display this help and exit
        \\  -V, --version                output version information and exit
        \\
        \\Examples:
        \\  realpath /usr/bin/../lib      Output "/usr/lib".
        \\  realpath -m /tmp/new/path     Resolve even if path does not exist.
        \\  realpath -s ./file            Resolve without following symlinks.
        \\
    );
}

/// Print version information
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("realpath ({s}) {s}\n", .{ common.name, common.version });
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runRealpath);
}

// ============================================================================
// TESTS
// ============================================================================

test "realpath: help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "Usage: realpath") != null);
    try testing.expect(std.mem.find(u8, out, "--no-symlinks") != null);
}

test "realpath: version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "realpath") != null);
    try testing.expect(std.mem.find(u8, out, common.version) != null);
}

test "realpath: missing operand" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runRealpath(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "realpath: unknown flag" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runRealpath(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
}

test "realpath: existing path" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/tmp"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 1);
    try testing.expectEqual(@as(u8, '/'), out[0]);
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
}

test "realpath: nonexistent path fails by default when parent missing" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/nonexistent/path/that/does/not/exist"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 1), result);
}

test "realpath: nonexistent last component succeeds by default" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/nonexistent_vibeutils_last_component"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "nonexistent_vibeutils_last_component") != null);
}

test "realpath: canonicalize-missing accepts nonexistent paths" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/tmp/nonexistent_vibeutils_test_path" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.find(u8, out, "nonexistent_vibeutils_test_path") != null);
}

test "realpath: no-symlinks resolves . and .." {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "/usr/bin/../lib" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/lib\n", stdout_aw.writer.buffered());
}

test "realpath: strip alias works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--strip", "/usr/bin/../lib" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/lib\n", stdout_aw.writer.buffered());
}

test "realpath: zero delimiter" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-z", "-s", "/usr/bin" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/bin\x00", stdout_aw.writer.buffered());
}

test "realpath: quiet suppresses errors" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-q", "-e", "/nonexistent/path" };
    const result = try runRealpath(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "realpath: multiple paths" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "/usr/bin", "/usr/lib" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/bin\n/usr/lib\n", stdout_aw.writer.buffered());
}

test "realpath: multiple paths with some failing" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "/usr/bin", "/nonexistent_vibeutils_xyz" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    _ = result;
}

test "realpath: default mode allows nonexistent last component" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent_vibeutils_test"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/nonexistent_vibeutils_test\n", stdout_aw.writer.buffered());
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "realpath: resolveLogical basic" {
    const io = testing.io;
    const result1 = try resolveLogical(testing.allocator, io, "/usr/bin/../lib");
    defer testing.allocator.free(result1);
    try testing.expectEqualStrings("/usr/lib", result1);

    const result2 = try resolveLogical(testing.allocator, io, "/usr/./bin");
    defer testing.allocator.free(result2);
    try testing.expectEqualStrings("/usr/bin", result2);

    const result3 = try resolveLogical(testing.allocator, io, "/a/b/c/../../d");
    defer testing.allocator.free(result3);
    try testing.expectEqualStrings("/a/d", result3);
}

test "realpath: resolveLogical root" {
    const io = testing.io;
    const result = try resolveLogical(testing.allocator, io, "/");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "realpath: resolveLogical redundant slashes" {
    const io = testing.io;
    const result = try resolveLogical(testing.allocator, io, "/usr///bin///ls");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/usr/bin/ls", result);
}

test "realpath: resolveLogical .. past root" {
    const io = testing.io;
    const result = try resolveLogical(testing.allocator, io, "/../../..");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "realpath: existing path with symlink resolution" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "real_file.txt", .{});
    file.close(io);

    tmp_dir.dir.symLink(io, "real_file.txt", "link_to_file.txt", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    // Both paths resolve to the same absolute path
    var path_buf1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = try tmp_dir.dir.realPathFile(io, "link_to_file.txt", &path_buf1);
    const real_len = try tmp_dir.dir.realPathFile(io, "real_file.txt", &path_buf2);

    try testing.expectEqualStrings(path_buf2[0..real_len], path_buf1[0..link_len]);
}

test "realpath: relative-to with no-symlinks" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-to=/usr", "/usr/bin/ls" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin/ls\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base under base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr/bin/ls" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin/ls\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base not under base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/etc/hosts" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/etc/hosts\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base path correctly under base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr/bin" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base prefix false positive" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr2/bin" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr2/bin\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base path equals base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(".\n", stdout_aw.writer.buffered());
}

test "realpath: canonicalize-missing .. past root returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/usr/nonexistent_vibeutils_test/../.." };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "realpath: canonicalize-missing multiple .. past root returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/usr/nonexistent_vibeutils_test/../../.." };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "realpath: canonicalize-missing deeper path .. past root returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/usr/bin/nonexistent_vibeutils_test/../../.." };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "realpath: default mode allows missing last component (GNU -E semantics)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/tmp/nonexistent_vibeutils_test_xyz"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "nonexistent_vibeutils_test_xyz") != null);
}

test "realpath: default mode fails when intermediate component missing" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent_vibeutils_dir/somefile"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "realpath: -e flag fails when last component missing (stricter than default)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-e", "/tmp/nonexistent_vibeutils_test_xyz" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "realpath: error message uses POSIX string not Zig @errorName" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-e", "/nonexistent_vibeutils_xyz" };
    const result = try runRealpath(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    const err_out = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err_out, "No such file or directory") != null);
    try testing.expect(std.mem.find(u8, err_out, "FileNotFound") == null);
}

test "realpath: -e on existing path outputs resolved path" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-e", "/tmp" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    const trimmed = std.mem.trimEnd(u8, out, "\n");
    try testing.expect(std.fs.path.isAbsolute(trimmed));
    try testing.expect(std.mem.endsWith(u8, trimmed, "tmp"));
}

test "realpath: --relative-to without -s resolves existing paths" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--relative-to=/usr", "/usr/bin" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin\n", stdout_aw.writer.buffered());
}

// ============================================================================
// E7: Behavioral tests — all-but-last-exist semantics (GNU default mode)
// ============================================================================

test "realpath: default mode resolves canonical path when last component missing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);

    const nonexistent = try std.fmt.allocPrint(testing.allocator, "{s}/e7_ghost.txt", .{dir_path});
    defer testing.allocator.free(nonexistent);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/e7_ghost.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{nonexistent};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "realpath: default mode uses canonicalizeMissing (result is canonical not raw input)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/tmp/e7_vibeutils_realpath_test"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expectEqual(@as(u8, '/'), out[0]);
    try testing.expect(std.mem.endsWith(u8, out, "e7_vibeutils_realpath_test\n"));
    try testing.expect(std.mem.find(u8, out, "..") == null);
}

test "realpath: default mode dotdot past root is clamped" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const real_tmp = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try std.Io.Dir.realPathFileAbsolute(io, "/tmp", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(real_tmp);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{real_tmp});
    defer testing.allocator.free(expected);

    const args = [_][]const u8{"/../../tmp"};
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "realpath: -m dotdot past root is clamped" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const real_tmp = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try std.Io.Dir.realPathFileAbsolute(io, "/tmp", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(real_tmp);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/e7_nonexistent\n", .{real_tmp});
    defer testing.allocator.free(expected);

    const args = [_][]const u8{ "-m", "/../../tmp/e7_nonexistent" };
    const result = try runRealpath(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}
