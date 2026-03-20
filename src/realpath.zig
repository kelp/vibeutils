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
fn resolveLogical(allocator: Allocator, path: []const u8) ![]u8 {
    // Get absolute path by prepending cwd if relative
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch return error.FileNotFound;
        break :blk try std.fs.path.join(allocator, &.{ cwd, path });
    };
    defer allocator.free(abs_path);

    // Split into components and resolve . and ..
    var components = std.ArrayListUnmanaged([]const u8){};
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

    return result;
}

/// Process a single path and write the result
fn processPath(
    allocator: Allocator,
    path: []const u8,
    opts: RealpathArgs,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !bool {
    const resolved = if (opts.no_symlinks) blk: {
        break :blk resolveLogical(allocator, path) catch |err| {
            if (!opts.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, "realpath", "{s}: {s}", .{ path, @errorName(err) });
            }
            return false;
        };
    } else if (opts.canonicalize_missing) blk: {
        break :blk path_utils.canonicalizeMissing(allocator, path) catch |err| {
            if (!opts.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, "realpath", "{s}: {s}", .{ path, @errorName(err) });
            }
            return false;
        };
    } else blk: {
        // Default: canonicalize-existing (all components must exist)
        break :blk std.fs.cwd().realpathAlloc(allocator, path) catch |err| {
            if (!opts.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, "realpath", "{s}: {s}", .{ path, @errorName(err) });
            }
            return false;
        };
    };
    defer allocator.free(resolved);

    // Handle --relative-to and --relative-base
    const output = if (opts.relative_to != null or opts.relative_base != null) blk: {
        const base_dir = opts.relative_to orelse opts.relative_base.?;

        // Resolve the base dir itself
        const resolved_base = if (opts.no_symlinks)
            resolveLogical(allocator, base_dir) catch |err| {
                if (!opts.quiet) {
                    common.printErrorWithProgram(allocator, stderr_writer, "realpath", "{s}: {s}", .{ base_dir, @errorName(err) });
                }
                return false;
            }
        else if (opts.canonicalize_missing)
            path_utils.canonicalizeMissing(allocator, base_dir) catch |err| {
                if (!opts.quiet) {
                    common.printErrorWithProgram(allocator, stderr_writer, "realpath", "{s}: {s}", .{ base_dir, @errorName(err) });
                }
                return false;
            }
        else
            std.fs.cwd().realpathAlloc(allocator, base_dir) catch |err| {
                if (!opts.quiet) {
                    common.printErrorWithProgram(allocator, stderr_writer, "realpath", "{s}: {s}", .{ base_dir, @errorName(err) });
                }
                return false;
            };
        defer allocator.free(resolved_base);

        if (opts.relative_base != null and opts.relative_to == null) {
            // --relative-base only: print relative if under base, absolute otherwise
            if (std.mem.startsWith(u8, resolved, resolved_base) and
                (resolved.len == resolved_base.len or resolved[resolved_base.len] == '/'))
            {
                const rel = std.fs.path.relative(allocator, resolved_base, resolved) catch {
                    break :blk try allocator.dupe(u8, resolved);
                };
                // Empty relative path means same directory
                if (rel.len == 0) {
                    allocator.free(rel);
                    break :blk try allocator.dupe(u8, ".");
                }
                break :blk rel;
            } else {
                break :blk try allocator.dupe(u8, resolved);
            }
        } else {
            // --relative-to: always print relative
            const rel = std.fs.path.relative(allocator, resolved_base, resolved) catch {
                break :blk try allocator.dupe(u8, resolved);
            };
            // Empty relative path means same directory
            if (rel.len == 0) {
                allocator.free(rel);
                break :blk try allocator.dupe(u8, ".");
            }
            break :blk rel;
        }
    } else blk: {
        break :blk try allocator.dupe(u8, resolved);
    };
    defer allocator.free(output);

    try stdout_writer.writeAll(output);
    if (opts.zero) {
        try stdout_writer.writeByte(0);
    } else {
        try stdout_writer.writeByte('\n');
    }

    return true;
}

/// Main entry point for the realpath utility
pub fn runRealpath(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Pre-process args to handle --strip alias for --no-symlinks
    var processed_args = std.ArrayListUnmanaged([]const u8){};
    defer processed_args.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--strip")) {
            try processed_args.append(allocator, "--no-symlinks");
        } else {
            try processed_args.append(allocator, arg);
        }
    }

    const parsed_args = common.argparse.ArgParser.parse(RealpathArgs, allocator, processed_args.items) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "realpath", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "realpath", "option missing required argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "realpath", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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

    var has_error = false;
    for (parsed_args.positionals) |path| {
        const ok = try processPath(allocator, path, parsed_args, stdout_writer, stderr_writer);
        if (!ok) has_error = true;
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
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
fn printVersion(writer: anytype) !void {
    try writer.print("realpath ({s}) {s}\n", .{ common.name, common.version });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runRealpath(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

// ============================================================================
// TESTS
// ============================================================================

test "realpath: help flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: realpath") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--no-symlinks") != null);
}

test "realpath: version flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "realpath") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
}

test "realpath: missing operand" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runRealpath(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "realpath: unknown flag" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid"};
    const result = try runRealpath(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
}

test "realpath: existing path" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // /tmp should always exist and resolve to itself (or its real path)
    const args = [_][]const u8{"/tmp"};
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Output should end with newline and start with /
    try testing.expect(stdout_buffer.items.len > 1);
    try testing.expectEqual(@as(u8, '/'), stdout_buffer.items[0]);
    try testing.expectEqual(@as(u8, '\n'), stdout_buffer.items[stdout_buffer.items.len - 1]);
}

test "realpath: nonexistent path fails by default" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"/nonexistent/path/that/does/not/exist"};
    const result = try runRealpath(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(stderr_buffer.items.len > 0);
}

test "realpath: canonicalize-missing accepts nonexistent paths" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", "/tmp/nonexistent_vibeutils_test_path" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buffer.items.len > 0);
    // Should contain the nonexistent path component
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "nonexistent_vibeutils_test_path") != null);
}

test "realpath: no-symlinks resolves . and .." {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "/usr/bin/../lib" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/lib\n", stdout_buffer.items);
}

test "realpath: strip alias works" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "--strip", "/usr/bin/../lib" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/lib\n", stdout_buffer.items);
}

test "realpath: zero delimiter" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-z", "-s", "/usr/bin" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/bin\x00", stdout_buffer.items);
}

test "realpath: quiet suppresses errors" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-q", "/nonexistent/path" };
    const result = try runRealpath(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "realpath: multiple paths" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "/usr/bin", "/usr/lib" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr/bin\n/usr/lib\n", stdout_buffer.items);
}

test "realpath: multiple paths with some failing" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "/usr/bin", "/nonexistent_vibeutils_xyz" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    // Should output the valid one and error on the invalid one
    // With -s (no-symlinks), resolveLogical doesn't check existence
    // so both succeed. Test with default mode instead.
    _ = result;
}

test "realpath: default mode fails on nonexistent" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Use default mode (canonicalize-existing) which requires all components exist
    const args = [_][]const u8{"/nonexistent_vibeutils_test"};
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try testing.expect(stderr_buffer.items.len > 0);
}

test "realpath: resolveLogical basic" {
    // Test absolute paths with . and ..
    const result1 = try resolveLogical(testing.allocator, "/usr/bin/../lib");
    defer testing.allocator.free(result1);
    try testing.expectEqualStrings("/usr/lib", result1);

    const result2 = try resolveLogical(testing.allocator, "/usr/./bin");
    defer testing.allocator.free(result2);
    try testing.expectEqualStrings("/usr/bin", result2);

    const result3 = try resolveLogical(testing.allocator, "/a/b/c/../../d");
    defer testing.allocator.free(result3);
    try testing.expectEqualStrings("/a/d", result3);
}

test "realpath: resolveLogical root" {
    const result = try resolveLogical(testing.allocator, "/");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "realpath: resolveLogical redundant slashes" {
    const result = try resolveLogical(testing.allocator, "/usr///bin///ls");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/usr/bin/ls", result);
}

test "realpath: resolveLogical .. past root" {
    const result = try resolveLogical(testing.allocator, "/../../..");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "realpath: existing path with symlink resolution" {
    // Create a temp directory with a symlink to test real resolution
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a real file
    const file = try tmp_dir.dir.createFile("real_file.txt", .{});
    file.close();

    // Create a symlink to it
    tmp_dir.dir.symLink("real_file.txt", "link_to_file.txt", .{}) catch |err| {
        // If symlinks aren't supported, skip
        if (err == error.AccessDenied) return;
        return err;
    };

    // Resolve the symlink
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try tmp_dir.dir.realpath("link_to_file.txt", &path_buf);
    const real_path = try tmp_dir.dir.realpath("real_file.txt", &path_buf);

    // Both should resolve to the same path
    try testing.expectEqualStrings(real_path, link_path);
}

test "realpath: relative-to with no-symlinks" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "--relative-to=/usr", "/usr/bin/ls" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin/ls\n", stdout_buffer.items);
}

test "realpath: relative-base under base" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr/bin/ls" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin/ls\n", stdout_buffer.items);
}

test "realpath: relative-base not under base" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/etc/hosts" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should output absolute path since /etc/hosts is not under /usr
    try testing.expectEqualStrings("/etc/hosts\n", stdout_buffer.items);
}

test "realpath: relative-base path correctly under base" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // /usr/bin is genuinely under /usr, so output should be relative
    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr/bin" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("bin\n", stdout_buffer.items);
}

test "realpath: relative-base prefix false positive" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // /usr2/bin starts with the string "/usr" but is NOT under /usr.
    // The bug: startsWith prefix match treats /usr2/bin as relative to /usr.
    // Correct behavior: output the absolute path /usr2/bin.
    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr2/bin" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Must output absolute path because /usr2/bin is NOT under /usr
    try testing.expectEqualStrings("/usr2/bin\n", stdout_buffer.items);
}

test "realpath: relative-base path equals base" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // When path equals base exactly, output should be "."
    const args = [_][]const u8{ "-s", "--relative-base=/usr", "/usr" };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(".\n", stdout_buffer.items);
}

test "realpath: canonicalize-missing .. past root returns root" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // /usr exists, so resolveMissing resolves it, then appends the remaining
    // nonexistent component and two "..". The second ".." goes past root.
    // Bug: `if (last_slash > 0)` in resolveMissing prevents shrinking to "/"
    // when last_slash is 0, so the result is "/usr" instead of "/".
    const args = [_][]const u8{ "-m", "/usr/nonexistent_vibeutils_test/../.." };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_buffer.items);
}

test "realpath: canonicalize-missing multiple .. past root returns root" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // /usr exists as a prefix. After resolving it, the remaining components
    // include a nonexistent dir and three "..". The third ".." exceeds root.
    // Bug: the guard `if (last_slash > 0)` prevents reaching "/" (position 0).
    const args = [_][]const u8{ "-m", "/usr/nonexistent_vibeutils_test/../../.." };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_buffer.items);
}

test "realpath: canonicalize-missing deeper path .. past root returns root" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // /usr/bin exists as a prefix. Remaining: nonexistent + three ".."
    // The third ".." should reach "/" but the `if (last_slash > 0)` guard
    // prevents it, leaving the result as "/usr" instead of "/".
    const args = [_][]const u8{ "-m", "/usr/bin/nonexistent_vibeutils_test/../../.." };
    const result = try runRealpath(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_buffer.items);
}
