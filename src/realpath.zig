//! realpath - resolve canonical file names
//!
//! Resolves each pathname argument to an absolute pathname with no `.`, `..`,
//! or symbolic link components. Follows GNU coreutils behavior with support
//! for missing path components and relative output.

const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const path_utils = common.path;
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Resolve a path to its canonical form, returning a heap-allocated `[]u8` (not
/// sentinel-terminated). Handles all three input classes: an empty path is
/// rejected as ENOENT (GNU parity), while relative and absolute paths both route
/// through `cwd().realPathFile`. Using a stack buffer + `allocator.dupe` avoids
/// the debug-allocator size mismatch from `realPathFileAbsoluteAlloc` returning
/// `[:0]u8` which when freed as `[]u8` reports the wrong size.
fn realPathDupe(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    // GNU realpath reports "No such file or directory" for an empty operand
    // rather than treating it as the cwd. Rejecting it here also keeps it away
    // from realPathFileAbsolute, whose isAbsolute assert would abort the process.
    if (path.len == 0) {
        return error.FileNotFound;
    }
    std.debug.assert(path.len > 0);

    // cwd().realPathFile resolves absolute paths (the dir handle is ignored) and
    // paths relative to the cwd, without asserting isAbsolute. Avoid
    // cwd().realPath (issue #51: broken under Threaded io; readlinks AT_FDCWD).
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try path_utils.realPathFromCwd(io, path, &buf);
    std.debug.assert(len > 0);
    std.debug.assert(len <= buf.len);
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
        .relative_base = .{
            .short = 0,
            .desc = "Print relative if path is under DIR",
            .value_name = "DIR",
        },
    };
};

/// Join collected path components into an absolute "/c0/c1/..." slice, or "/"
/// when empty. Caller owns the returned slice.
fn joinComponentsAbsolute(allocator: Allocator, components: []const []const u8) ![]u8 {
    if (components.len == 0) {
        return try allocator.dupe(u8, "/");
    }
    // Leading '/' plus one '/' separator and the bytes for each component.
    var total_len: usize = 0;
    for (components) |comp| {
        std.debug.assert(comp.len > 0);
        total_len += 1 + comp.len;
    }
    std.debug.assert(total_len >= components.len);

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (components) |comp| {
        result[pos] = '/';
        pos += 1;
        @memcpy(result[pos .. pos + comp.len], comp);
        pos += comp.len;
    }
    // The build loop writes exactly total_len bytes, so pos lands on total_len.
    std.debug.assert(pos == total_len);
    return result;
}

/// Stat the accumulated prefix that precedes a `..` and confirm it is a
/// directory (following symlinks, matching GNU realpath -s). Errors with
/// FileNotFound when the prefix is absent and NotDir when it resolves to a
/// non-directory. `components` are the path parts collected so far, all
/// non-empty and never `.`/`..`.
fn checkDotDotPrefix(
    allocator: Allocator,
    io: std.Io,
    components: []const []const u8,
) !void {
    std.debug.assert(components.len > 0);
    const prefix = try joinComponentsAbsolute(allocator, components);
    defer allocator.free(prefix);
    std.debug.assert(prefix.len > 0);
    const info = try std.Io.Dir.cwd().statFile(io, prefix, .{});
    if (info.kind != .directory) {
        return error.NotDir;
    }
}

/// Textual logical resolution: clean . and .. purely as text, no filesystem
/// check. Convenience wrapper used by the pure-algorithm unit tests.
fn resolveLogical(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return resolveLogicalWithMode(allocator, io, path, true);
}

/// Resolve a path without following symlinks, just cleaning . and .. components.
/// Makes the path absolute and removes redundant separators and dot components.
/// When `allow_missing` is false (plain -s), each `..` requires the component
/// it pops to exist and be a directory; -m -s passes true to skip that check.
fn resolveLogicalWithMode(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    allow_missing: bool,
) ![]u8 {
    // GNU realpath -s reports "No such file or directory" for an empty operand
    // rather than resolving it to the cwd. Reject it here so an empty
    // --relative-to= base routed through this path errors like GNU.
    if (path.len == 0) {
        return error.FileNotFound;
    }
    std.debug.assert(path.len > 0);

    // Get absolute path by prepending cwd if relative
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        // cwd().realPathFile(".", ...) resolves the cwd via a real dir handle.
        // Avoid cwd().realPath (issue #51: broken under Threaded io; it
        // readlinks the AT_FDCWD pseudo-fd and fails with ENOENT).
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = path_utils.realPathFromCwd(io, ".", &cwd_buf) catch
            return error.FileNotFound;
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
                // Under plain -s the popped prefix must exist as a directory.
                if (!allow_missing) {
                    try checkDotDotPrefix(allocator, io, components.items);
                }
                _ = components.pop();
            }
        } else {
            try components.append(allocator, component);
        }
    }

    // Build result path from the cleaned components.
    return try joinComponentsAbsolute(allocator, components.items);
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
    // GNU realpath prints the operand bare for ordinary paths (pinned on
    // coreutils 9.5: `realpath: nosuch/../x: No such file or directory`) and
    // only quotes it via quotearg's shell-escape style when the operand is
    // empty or contains characters that need shell quoting (spaces, embedded
    // quotes, control bytes). We don't replicate that conditional escaping,
    // so keep this bare to match the common case.
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
        return resolveLogicalWithMode(allocator, io, path, opts.canonicalize_missing) catch |err| {
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
        return realPathDupe(allocator, io, path) catch |err| {
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
/// the default branch uses `realPathDupe` (no parent-must-exist mode). An empty
/// base surfaces as ENOENT via `realPathDupe`, matching GNU realpath.
/// Returns the owned resolved slice, or null when an error was already reported.
fn processPath_resolveBase(
    allocator: Allocator,
    io: std.Io,
    base_dir: []const u8,
    opts: *const RealpathArgs,
    stderr_writer: *std.Io.Writer,
) !?[]u8 {
    if (opts.no_symlinks) {
        const allow_missing = opts.canonicalize_missing;
        return resolveLogicalWithMode(allocator, io, base_dir, allow_missing) catch |err| {
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
        return realPathDupe(allocator, io, base_dir) catch |err| {
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
pub fn runRealpath(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
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

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        RealpathArgs,
        allocator,
        processed_args.items,
        "realpath",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
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
        return @intFromEnum(common.ExitCode.general_error);
    }

    // The missing-operand guard above returns before reaching this loop, so at
    // least one positional remains (it may be empty, but the count is nonzero).
    std.debug.assert(parsed_args.positionals.len > 0);

    var has_error = false;
    for (parsed_args.positionals) |path| {
        const ok = try processPath(allocator, io, path, parsed_args, stdout_writer, stderr_writer);
        if (!ok) has_error = true;
    }

    return if (has_error)
        @intFromEnum(common.ExitCode.general_error)
    else
        @intFromEnum(common.ExitCode.success);
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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "realpath: unknown flag" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
}

test "realpath: existing path" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/tmp"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
}

test "realpath: nonexistent last component succeeds by default" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/nonexistent_vibeutils_last_component"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(
        u8,
        stdout_aw.writer.buffered(),
        "nonexistent_vibeutils_last_component",
    ) != null);
}

test "realpath: canonicalize-missing accepts nonexistent paths" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/tmp/nonexistent_vibeutils_test_path" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/lib\n", stdout_aw.writer.buffered());
}

test "realpath: strip alias works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--strip", "/usr/bin/../lib" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/lib\n", stdout_aw.writer.buffered());
}

test "realpath: zero delimiter" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-z", "-s", "/usr/bin" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/bin\x00", stdout_aw.writer.buffered());
}

test "realpath: quiet suppresses errors" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-q", "-e", "/nonexistent/path" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "realpath: multiple paths" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "/usr/bin", "/usr/lib" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    _ = result;
}

test "realpath: default mode allows nonexistent last component" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent_vibeutils_test"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file = try tmp_dir.dir().createFile(io, "real_file.txt", .{});
    file.close(io);

    tmp_dir.dir().symLink(io, "real_file.txt", "link_to_file.txt", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    // Both names canonicalize to the same target. TestDir.realPathFile does
    // not follow the last component (stat tests need the symlink path), so
    // this check uses libc realpath — the same fallback production uses when
    // Zig Dir.realPathFile is OperationUnsupported.
    const link_joined = try tmp_dir.getPath("link_to_file.txt");
    defer testing.allocator.free(link_joined);
    const real_joined = try tmp_dir.getPath("real_file.txt");
    defer testing.allocator.free(real_joined);
    var path_buf1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = try path_utils.realPathLibc(link_joined, &path_buf1);
    const real_len = try path_utils.realPathLibc(real_joined, &path_buf2);

    try testing.expectEqualStrings(path_buf2[0..real_len], path_buf1[0..link_len]);
}

test "realpath: relative-to with no-symlinks" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-to=/usr", "/usr/bin/ls" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin/ls\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base under base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr/bin/ls" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin/ls\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base not under base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/etc/hosts" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/etc/hosts\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base path correctly under base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr/bin" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base prefix false positive" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr2/bin" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr2/bin\n", stdout_aw.writer.buffered());
}

test "realpath: relative-base path equals base" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(".\n", stdout_aw.writer.buffered());
}

test "realpath: canonicalize-missing .. past root returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/usr/nonexistent_vibeutils_test/../.." };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "realpath: canonicalize-missing multiple .. past root returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/usr/nonexistent_vibeutils_test/../../.." };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "realpath: canonicalize-missing deeper path .. past root returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/usr/bin/nonexistent_vibeutils_test/../../.." };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(
        std.mem.find(u8, stdout_aw.writer.buffered(), "nonexistent_vibeutils_test_xyz") != null,
    );
}

test "realpath: default mode fails when intermediate component missing" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/nonexistent_vibeutils_dir/somefile"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "realpath: error message uses POSIX string not Zig @errorName" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-e", "/nonexistent_vibeutils_xyz" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin\n", stdout_aw.writer.buffered());
}

// ============================================================================
// Issue #46: empty --relative-to= / --relative-base= base must error, not panic
// ============================================================================

// An empty --relative-to= value must produce a clean error (exit 1) matching
// GNU realpath ("realpath: '': No such file or directory"), not an
// unreachable-code panic from realPathFileAbsolute asserting isAbsolute.
test "realpath: empty --relative-to= errors instead of panicking" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--relative-to=", "/tmp" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    const err_out = stderr_aw.writer.buffered();
    try testing.expect(err_out.len > 0);
    try testing.expect(std.mem.find(u8, err_out, "No such file or directory") != null);
}

// Same guard for the --relative-base= spelling: an empty base must not be
// forwarded to realPathFileAbsolute (which asserts an absolute path).
test "realpath: empty --relative-base= errors instead of panicking" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--relative-base=", "/tmp" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    const err_out = stderr_aw.writer.buffered();
    try testing.expect(err_out.len > 0);
    try testing.expect(std.mem.find(u8, err_out, "No such file or directory") != null);
}

// ============================================================================
// Issue #46 (round 2): non-absolute paths must be resolved, not forwarded raw
// to realPathFileAbsolute (which asserts isAbsolute and aborts the process).
// The round-1 fix only guarded the EMPTY base in processPath_resolveBase; these
// pin the still-uncovered cases: a relative (but non-empty) base, an empty
// target operand, and a relative target operand.
// ============================================================================

// A RELATIVE --relative-to base must be resolved against the cwd. Before the
// fix the default (symlink-following) base branch calls realPathAbsoluteDupe(".")
// -> realPathFileAbsolute, which asserts isAbsolute and aborts (SIGABRT / exit
// 134), killing the in-process test runner. GNU prints the target relative to
// the resolved base. We chdir into a tmp dir so "." is deterministic and does
// not depend on the repo cwd; the cwd handle is restored via fchdir on exit.
test "realpath: relative --relative-to=. resolves against cwd (issue #46)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDirPath(io, "sub");

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    // Absolute target under the resolved base; expected relative form is "sub".
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{tmp_abs});
    defer testing.allocator.free(target);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--relative-to=.", target };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("sub\n", stdout_aw.writer.buffered());
}

// A RELATIVE --relative-base value hits the same crashing default branch of
// processPath_resolveBase. GNU resolves the base against the cwd and, since the
// target is under it, prints the relative form ("child").
test "realpath: relative --relative-base=sub resolves against cwd (issue #46)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDirPath(io, "sub/child");

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/sub/child", .{tmp_abs});
    defer testing.allocator.free(target);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--relative-base=sub", target };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("child\n", stdout_aw.writer.buffered());
}

// An empty TARGET operand under -e reaches processPath_resolveTarget's
// canonicalize_existing branch, which the round-1 base guard does not cover.
// realPathAbsoluteDupe("") aborts on the isAbsolute assert; GNU reports ENOENT.
test "realpath: -e with empty operand errors instead of panicking (issue #46)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-e", "" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    const err_out = stderr_aw.writer.buffered();
    try testing.expect(err_out.len > 0);
    try testing.expect(std.mem.find(u8, err_out, "No such file or directory") != null);
}

// A RELATIVE existing TARGET under -e must be resolved to its absolute canonical
// path. Before the fix realPathAbsoluteDupe("existing.txt") aborts on the
// isAbsolute assert. GNU prints the absolute resolved path and exits 0.
test "realpath: -e resolves a relative existing file to an absolute path (issue #46)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    {
        const file = try tmp_dir.dir().createFile(io, "existing.txt", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/existing.txt\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-e", "existing.txt" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// ============================================================================
// Issue #51: -s / -m with relative paths must resolve against the cwd.
// cwd().realPath is broken under 0.16 Threaded io (it readlinks the AT_FDCWD
// pseudo-fd /proc/self/fd/-100), so resolveLogical (-s) and canonicalizeMissing
// (-m) fail with ENOENT for existing relative paths where GNU succeeds. We chdir
// into a tmp dir so "." is deterministic and independent of the repo cwd; the
// original cwd handle is restored via setCurrentDir on exit.
// ============================================================================

// -s on a relative existing path must resolve to its absolute form via the cwd.
// Before the fix resolveLogical's relative branch calls cwd().realPath and
// aborts with ENOENT; GNU prints the absolute path and exits 0.
test "realpath: -s relative existing path resolves via cwd (issue #51)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    {
        const file = try tmp_dir.dir().createFile(io, "motd", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/motd\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "./motd" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// -s on a relative path carrying "." and ".." exercises resolveLogical's
// relative-branch cleanup, not just a bare relative name. ./sub/./../sub must
// clean to <cwd>/sub.
test "realpath: -s relative path with dot components resolves via cwd (issue #51)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDirPath(io, "sub");

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/sub\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "./sub/./../sub" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// -m on a relative path with a missing tail must resolve the whole thing
// against the cwd. Before the fix canonicalizeMissing_absolutePath calls
// cwd().realPath and aborts with ENOENT; GNU prints <cwd>/nosuch/dir, exit 0.
test "realpath: -m relative path with missing tail resolves via cwd (issue #51)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/nosuch/dir\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "nosuch/dir" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// -m on a relative path whose components all exist must resolve to the
// canonical absolute path via the cwd.
test "realpath: -m relative path with existing components resolves via cwd (issue #51)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDirPath(io, "sub");

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/sub\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "sub" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// ----------------------------------------------------------------------------
// Issue #51 addendum: once cwd().realPath works, the empty-as-cwd special cases
// masked by the breakage must still reject a zero-length operand with ENOENT to
// match GNU (`realpath -s ''` / `-m ''` -> "No such file or directory", exit 1),
// rather than silently resolving to the cwd. These guard against a naive fix
// that drops the empty-path guards; they must stay green before AND after.
// ----------------------------------------------------------------------------

test "realpath: -s empty operand errors, not resolves to cwd (issue #51)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

test "realpath: -m empty operand errors, not resolves to cwd (issue #51)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

// -s with an empty --relative-to= routes the empty base through resolveLogical
// (processPath_resolveBase's no_symlinks branch); it must error, not resolve
// the base to the cwd.
test "realpath: -s empty --relative-to= errors (issue #51)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "--relative-to=", "/tmp" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

// -m with an empty --relative-base= routes the empty base through
// canonicalizeMissing (processPath_resolveBase's canonicalize_missing branch);
// it must error, not resolve the base to the cwd.
test "realpath: -m empty --relative-base= errors (issue #51)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "--relative-base=", "/tmp" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

// ============================================================================
// E7: Behavioral tests — all-but-last-exist semantics (GNU default mode)
// ============================================================================

test "realpath: default mode resolves canonical path when last component missing" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.realPathFile(".", &_rp_buf);
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
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "realpath: default mode uses canonicalizeMissing (result is canonical not raw input)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"/tmp/e7_vibeutils_realpath_test"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

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
        const _rp_len = try path_utils.realPathLibc("/tmp", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(real_tmp);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{real_tmp});
    defer testing.allocator.free(expected);

    const args = [_][]const u8{"/../../tmp"};
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "realpath: -m dotdot past root is clamped" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const real_tmp = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try path_utils.realPathLibc("/tmp", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(real_tmp);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/e7_nonexistent\n", .{real_tmp});
    defer testing.allocator.free(expected);

    const args = [_][]const u8{ "-m", "/../../tmp/e7_nonexistent" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// ============================================================================
// Issue #62: `-s` must verify the component preceding a `..` exists and is a
// directory before popping it, instead of popping purely textually. Pinned
// against GNU coreutils 9.5 on Linux. Under plain `-s`, a missing preceding
// component -> ENOENT rc=1; a non-directory preceding component (real file or
// symlink-to-file) -> ENOTDIR rc=1. Under `-m -s`, the check is skipped. The
// final component of the whole path need not exist under plain `-s`.
// ============================================================================

// `-s nosuch/../x`: the component before `..` does not exist, so GNU errors
// "No such file or directory" rc=1 instead of printing <cwd>/x rc=0. This is
// the primary red for the textual-pop bug.
test "realpath: -s pop of dotdot past missing component errors ENOENT (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "nosuch/../x" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

// `-s file.txt/../x`: the component before `..` exists but is a regular file,
// so GNU errors "Not a directory" rc=1 instead of printing <cwd>/x rc=0.
test "realpath: -s pop of dotdot past non-directory errors ENOTDIR (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    {
        const file = try tmp_dir.dir().createFile(io, "file.txt", .{});
        file.close(io);
    }

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "file.txt/../x" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "Not a directory") != null,
    );
}

// Absolute path variant: `<tmp>/nosuch/../x` with a missing prefix must fail
// the same way, proving the check applies to the isAbsolute branch too.
test "realpath: -s absolute dotdot past missing component errors ENOENT (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/nosuch/../x", .{tmp_abs});
    defer testing.allocator.free(path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", path };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "No such file or directory") != null,
    );
}

// `-m -s nosuch/../x`: `-m` (canonicalize_missing) permits missing components,
// so the per-component check is skipped and the textual result is printed.
// Guards against a fix that applies the check unconditionally under `-m -s`.
test "realpath: -m -s pop of dotdot past missing component succeeds (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/x\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "-s", "nosuch/../x" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// `-s sub/../nosuch_final` with `sub` an existing directory: the pop of `..`
// past `sub` is legal (sub is a directory), and the final component after
// cleanup need not exist. GNU prints <cwd>/nosuch_final rc=0. Guards against a
// fix that over-rejects the valid case or that checks the final component.
test "realpath: -s pop past existing dir with missing final component succeeds (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDirPath(io, "sub");

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/nosuch_final\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "sub/../nosuch_final" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// `-s slink/../file.txt` where `slink` is a symlink to a directory: GNU stat
// follows the symlink, sees a directory, and pops the `slink` name textually
// (logical mode never substitutes the target). Result <cwd>/file.txt rc=0.
test "realpath: -s pop past symlink-to-directory succeeds (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    try tmp_dir.dir().createDirPath(io, "sub");
    {
        const file = try tmp_dir.dir().createFile(io, "file.txt", .{});
        file.close(io);
    }
    tmp_dir.dir().symLink(io, "sub", "slink", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/file.txt\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "slink/../file.txt" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

// `-s flink/../file.txt` where `flink` is a symlink to a regular file: GNU stat
// follows the symlink, sees a non-directory, and errors "Not a directory" rc=1.
// The check follows the symlink (statFile, not lstat), so this is a red for the
// current textual pop. Guards that the fix uses a following stat.
test "realpath: -s pop past symlink-to-file errors ENOTDIR (issue #62)" {
    const io = testing.io;
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    {
        const file = try tmp_dir.dir().createFile(io, "file.txt", .{});
        file.close(io);
    }
    tmp_dir.dir().symLink(io, "file.txt", "flink", .{}) catch |err| {
        if (err == error.AccessDenied) return;
        return err;
    };

    var saved_cwd = try tmp_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved_cwd);

    const tmp_abs = try tmp_dir.getBasePath();
    defer testing.allocator.free(tmp_abs);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-s", "flink/../file.txt" };
    const result = try runRealpath(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "Not a directory") != null,
    );
}
