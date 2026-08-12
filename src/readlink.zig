//! readlink - print value of a symbolic link or canonical filename
//!
//! The readlink utility prints the target of a symbolic link. With
//! canonicalize options, it resolves the path to its canonical form.
//!
//! This implementation follows GNU coreutils readlink behavior.

const std = @import("std");
const common = @import("common");
const path_utils = common.path;
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Command-line arguments for the readlink utility
const ReadlinkArgs = struct {
    /// Canonicalize by following every symlink; all components must exist
    canonicalize: bool = false,
    /// Same as -f; all components must exist
    @"canonicalize-existing": bool = false,
    /// Canonicalize; components need not exist
    @"canonicalize-missing": bool = false,
    /// Do not output trailing newline
    @"no-newline": bool = false,
    /// End each output line with NUL, not newline
    zero: bool = false,
    /// Report error messages
    verbose: bool = false,
    /// Suppress most error messages
    quiet: bool = false,
    /// Suppress most error messages (alias for quiet)
    silent: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// File paths to process
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .canonicalize = .{
            .short = 'f',
            .desc = "canonicalize path; all but the last component must exist",
        },
        .@"canonicalize-existing" = .{
            .short = 'e',
            .desc = "canonicalize path; all components must exist",
        },
        .@"canonicalize-missing" = .{
            .short = 'm',
            .desc = "canonicalize path; components need not exist",
        },
        .@"no-newline" = .{ .short = 'n', .desc = "Do not output trailing newline" },
        .zero = .{ .short = 'z', .desc = "End each output line with NUL, not newline" },
        .verbose = .{ .short = 'v', .desc = "Report error messages" },
        .quiet = .{ .short = 'q', .desc = "Suppress most error messages" },
        .silent = .{ .short = 0, .desc = "Suppress most error messages (alias for --quiet)" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Determine the canonicalize mode from parsed args
const CanonicalizeMode = enum {
    none,
    /// -f: all but the last component must exist (GNU behavior)
    canonical_missing_ok,
    /// -e: all components must exist
    strict,
    /// -m: components need not exist
    missing,
};

fn getCanonicalizeMode(args: ReadlinkArgs) CanonicalizeMode {
    if (args.@"canonicalize-missing") return .missing;
    if (args.@"canonicalize-existing") return .strict;
    if (args.canonicalize) return .canonical_missing_ok;
    return .none;
}

/// Main entry point for the readlink utility
pub fn runReadlink(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Parse command-line arguments
    const parsed = common.argparse.ArgParser.parseOrExit(
        ReadlinkArgs,
        allocator,
        args,
        "readlink",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed.positionals);

    // Handle help
    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate: need at least one operand
    if (parsed.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "readlink", "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // The empty-operand case returned above, so the loop below always has work.
    std.debug.assert(parsed.positionals.len > 0);

    const canon_mode = getCanonicalizeMode(parsed);
    const quiet = parsed.quiet or parsed.silent;
    const verbose = parsed.verbose and !quiet;
    // verbose is `parsed.verbose and !quiet`, so quiet forces verbose off.
    if (quiet) std.debug.assert(!verbose);
    var has_error = false;

    for (parsed.positionals) |path| {
        const path_failed = try runReadlink_process_path(
            allocator,
            io,
            path,
            parsed,
            canon_mode,
            verbose,
            stdout_writer,
            stderr_writer,
        );
        if (path_failed) has_error = true;
    }

    if (has_error) {
        return @intFromEnum(common.ExitCode.general_error);
    }
    return @intFromEnum(common.ExitCode.success);
}

/// Resolve and emit one path for `runReadlink`. Returns `true` if the path
/// could not be resolved (so the caller can set its aggregate error flag),
/// emitting a verbose diagnostic when `verbose` is set.
fn runReadlink_process_path(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    parsed: ReadlinkArgs,
    canon_mode: CanonicalizeMode,
    verbose: bool,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !bool {
    const result = resolveLink(allocator, io, path, canon_mode);
    if (result) |resolved| {
        defer allocator.free(resolved);
        try stdout_writer.writeAll(resolved);
        if (parsed.zero) {
            try stdout_writer.writeByte(0);
        } else if (!parsed.@"no-newline") {
            try stdout_writer.writeByte('\n');
        }
        return false;
    } else |err| {
        if (verbose) {
            const err_msg = switch (err) {
                error.FileNotFound => "No such file or directory",
                error.NotLink => "Invalid argument",
                error.AccessDenied => "Permission denied",
                error.NameTooLong => "File name too long",
                error.NotDir => "Not a directory",
                else => "cannot read link",
            };
            // GNU readlink -v prints the operand bare for ordinary paths
            // (pinned on coreutils 9.5: `readlink: /tmp/nonexistent: No such
            // file or directory`) and only quotes it via quotearg's
            // shell-escape style when the operand contains characters that
            // need shell quoting (spaces, embedded quotes, control bytes).
            // We don't replicate that conditional escaping, so keep this
            // bare to match the common case.
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "readlink",
                "{s}: {s}",
                .{ path, err_msg },
            );
        }
        return true;
    }
}

/// Resolve an absolute path to its canonical form, returning a heap-allocated
/// `[]u8` (not sentinel-terminated). Using a stack buffer + `allocator.dupe`
/// avoids the debug-allocator size mismatch from `realPathFileAbsoluteAlloc`
/// returning `[:0]u8` which when freed as `[]u8` reports the wrong size.
fn realPathAbsoluteDupe(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.realPathFileAbsolute(io, path, &buf);
    // Bytes written into buf cannot exceed its capacity; guards buf[0..len] below.
    std.debug.assert(len <= buf.len);
    return allocator.dupe(u8, buf[0..len]);
}

/// Resolve a relative or absolute path to its canonical form via the cwd,
/// returning a heap-allocated `[]u8` (not sentinel-terminated).
fn realPathDupe(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buf);
    // Bytes written into buf cannot exceed its capacity; guards buf[0..len] below.
    std.debug.assert(len <= buf.len);
    return allocator.dupe(u8, buf[0..len]);
}

/// Resolve a link target or canonicalize a path
fn resolveLink(allocator: Allocator, io: std.Io, path: []const u8, mode: CanonicalizeMode) ![]u8 {
    switch (mode) {
        .none => {
            // Just read the symlink target, no canonicalization
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = try std.Io.Dir.cwd().readLink(io, path, &buf);
            // Bytes written into buf cannot exceed its capacity; guards buf[0..len].
            std.debug.assert(len <= buf.len);
            return try allocator.dupe(u8, buf[0..len]);
        },
        .canonical_missing_ok => {
            // GNU -f: all but the last component must exist.
            // Use the common function for parent-must-exist semantics.
            return resolveCanonicalMissingOk(allocator, io, path);
        },
        .strict => {
            // Canonicalize: resolve to absolute path, all components must exist
            return try realPathDupe(allocator, io, path);
        },
        .missing => {
            // Canonicalize: components need not exist
            // Try realpath first; if it fails, build canonical path manually
            if (realPathDupe(allocator, io, path)) |resolved| {
                return resolved;
            } else |_| {
                return try path_utils.canonicalizeMissing(allocator, io, path);
            }
        },
    }
}

/// GNU -f resolution: the last component may be missing, but all
/// parent components must exist. For symlinks, read the link target
/// first and then resolve that target path.
fn resolveCanonicalMissingOk(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Check if path is a symlink (even a dangling one)
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().readLink(io, path, &link_buf)) |link_len| {
        // Bytes written into link_buf cannot exceed its capacity; guards the slice.
        std.debug.assert(link_len <= link_buf.len);
        const link_target = link_buf[0..link_len];
        // It's a symlink. Resolve the target path.
        // If target is relative, make it relative to the symlink's directory.
        if (std.fs.path.isAbsolute(link_target)) {
            // Absolute target: resolve with parent-must-exist semantics
            return path_utils.canonicalizeParentMustExist(allocator, io, link_target);
        } else {
            // Relative target: resolve relative to the symlink's parent dir
            const dir = std.fs.path.dirname(path) orelse ".";
            const resolved_dir = try realPathDupe(allocator, io, dir);
            defer allocator.free(resolved_dir);
            const full_target = try std.fs.path.join(allocator, &.{ resolved_dir, link_target });
            defer allocator.free(full_target);
            return path_utils.canonicalizeParentMustExist(allocator, io, full_target);
        }
    } else |_| {
        // Not a symlink (or doesn't exist at all).
        // Require the parent directory to exist; last component may be missing.
        return path_utils.canonicalizeParentMustExist(allocator, io, path);
    }
}

/// Print help message
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: readlink [OPTION]... FILE...
        \\Print value of a symbolic link or canonical file name.
        \\
        \\  -f, --canonicalize           canonicalize path; all but the last component
        \\                               must exist
        \\  -e, --canonicalize-existing  canonicalize path; all components must exist
        \\  -m, --canonicalize-missing   canonicalize path; components need not exist
        \\  -n, --no-newline             do not output the trailing delimiter
        \\  -q, --quiet, --silent        suppress most error messages
        \\  -v, --verbose                report error messages
        \\  -z, --zero                   end each output line with NUL, not newline
        \\  -h, --help                   display this help and exit
        \\  -V, --version                output version information and exit
        \\
    );
}

/// Print version information
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("readlink ({s}) {s}\n", .{ common.name, common.version });
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runReadlink);
}

// ============================================================================
// TESTS
// ============================================================================

test "readlink basic symlink" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a target file and a symlink
    const target = try tmp_dir.dir.createFile(io, "target.txt", .{});
    try target.writeStreamingAll(io, "content");
    target.close(io);
    try tmp_dir.dir.symLink(io, "target.txt", "link.txt", .{});

    // Get absolute path to the symlink
    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{link_path};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("target.txt\n", stdout_aw.writer.buffered());
}

test "readlink not a symlink" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(io, "regular.txt", .{});
    target.close(io);

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/regular.txt", .{dir_path});
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{file_path};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "readlink nonexistent file" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"/tmp/definitely_nonexistent_readlink_test"};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "readlink verbose error" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(
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

test "readlink quiet suppresses errors" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-v", "-q", "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    // -q overrides -v, so no error output
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "readlink canonicalize (-f)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(io, "real_file.txt", .{});
    target.close(io);
    try tmp_dir.dir.symLink(io, "real_file.txt", "link.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    const expected_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/real_file.txt\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected_path, stdout_aw.writer.buffered());
}

test "readlink canonicalize regular file (-f)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(io, "regular.txt", .{});
    target.close(io);

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/regular.txt", .{dir_path});
    defer testing.allocator.free(file_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/regular.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", file_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink canonicalize-existing (-e)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(io, "exists.txt", .{});
    target.close(io);

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/exists.txt", .{dir_path});
    defer testing.allocator.free(file_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/exists.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-e", file_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink canonicalize nonexistent succeeds with -f when parent exists (GNU compat)" {
    // GNU -f allows the last component to be missing, so
    // /tmp/nonexistent exits 0 because /tmp exists.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
}

test "readlink canonicalize-missing (-m) with nonexistent path" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const test_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/nonexistent/file.txt",
        .{dir_path},
    );
    defer testing.allocator.free(test_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", test_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    // Should contain the directory path and end with the filename
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.endsWith(u8, out, "nonexistent/file.txt\n"));
}

// readlink -m shares canonicalizeMissing with realpath -m, so it inherits the
// #51 relative-path breakage: cwd().realPath (broken under 0.16 Threaded io,
// readlinks the AT_FDCWD pseudo-fd) fails with ENOENT for a relative operand.
// GNU resolves it against the cwd. We chdir into a tmp dir so "." is
// deterministic; the original cwd is restored via setCurrentDir on exit. This
// is the "other caller of canonicalizeMissing" the issue calls out.
test "readlink -m relative path with missing tail resolves via cwd (issue #51)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var saved_cwd_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer {
        std.process.setCurrentDir(io, saved_cwd_dir) catch {};
        saved_cwd_dir.close(io);
    }

    const tmp_abs = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);

    try std.Io.Threaded.chdir(tmp_abs);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/nosuch/child\n", .{tmp_abs});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "nosuch/child" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink no-newline (-n)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(io, "target.txt", .{});
    target.close(io);
    try tmp_dir.dir.symLink(io, "target.txt", "link.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-n", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    // Should NOT end with newline
    try testing.expectEqualStrings("target.txt", stdout_aw.writer.buffered());
}

test "readlink zero delimiter (-z)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(io, "target.txt", .{});
    target.close(io);
    try tmp_dir.dir.symLink(io, "target.txt", "link.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-z", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expectEqual(@as(usize, 11), out.len);
    try testing.expectEqualStrings("target.txt", out[0..10]);
    try testing.expectEqual(@as(u8, 0), out[10]);
}

test "readlink multiple files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const t1 = try tmp_dir.dir.createFile(io, "t1.txt", .{});
    t1.close(io);
    const t2 = try tmp_dir.dir.createFile(io, "t2.txt", .{});
    t2.close(io);
    try tmp_dir.dir.symLink(io, "t1.txt", "l1.txt", .{});
    try tmp_dir.dir.symLink(io, "t2.txt", "l2.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const l1_path = try std.fmt.allocPrint(testing.allocator, "{s}/l1.txt", .{dir_path});
    defer testing.allocator.free(l1_path);
    const l2_path = try std.fmt.allocPrint(testing.allocator, "{s}/l2.txt", .{dir_path});
    defer testing.allocator.free(l2_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ l1_path, l2_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("t1.txt\nt2.txt\n", stdout_aw.writer.buffered());
}

test "readlink mixed success and failure" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const t1 = try tmp_dir.dir.createFile(io, "t1.txt", .{});
    t1.close(io);
    try tmp_dir.dir.symLink(io, "t1.txt", "l1.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const l1_path = try std.fmt.allocPrint(testing.allocator, "{s}/l1.txt", .{dir_path});
    defer testing.allocator.free(l1_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // One valid symlink, one nonexistent
    const args = [_][]const u8{ l1_path, "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    // Should fail because one path failed
    try testing.expectEqual(@as(u8, 1), result);
    // But should still output the successful one
    try testing.expectEqualStrings("t1.txt\n", stdout_aw.writer.buffered());
}

test "readlink missing operand" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "readlink help" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "Usage: readlink") != null);
    try testing.expect(std.mem.find(u8, out, "--canonicalize") != null);
}

test "readlink version" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "readlink") != null);
    try testing.expect(std.mem.find(u8, out, common.version) != null);
}

test "readlink unknown flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid-flag"};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") != null,
    );
}

test "readlink dangling symlink" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a symlink to a nonexistent target
    try tmp_dir.dir.symLink(io, "nonexistent_target", "dangling.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Without canonicalize, readlink should still return the target
    const args = [_][]const u8{link_path};
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("nonexistent_target\n", stdout_aw.writer.buffered());
}

test "readlink dangling symlink with -f succeeds (GNU compat)" {
    // GNU -f: last component may be missing. A dangling symlink whose
    // target's parent directory exists should resolve successfully.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(io, "nonexistent_target", "dangling.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/nonexistent_target\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    // GNU -f exits 0 for dangling symlinks when parent exists
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink canonicalize-missing with dangling symlink (-m)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(io, "nonexistent_target", "dangling.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    // -m should succeed even for dangling symlinks
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "readlink -m dotdot past root returns root" {
    // Use a real tmp directory so the prefix resolves, then traverse past root.
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);

    var depth: usize = 0;
    for (dir_path) |c| {
        if (c == '/') depth += 1;
    }
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(testing.allocator);
    try path_buf.appendSlice(testing.allocator, dir_path);
    try path_buf.appendSlice(testing.allocator, "/nonexistent");
    for (0..depth + 1) |_| {
        try path_buf.appendSlice(testing.allocator, "/..");
    }

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", path_buf.items };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "readlink -m multi-level dotdot past root returns root" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);

    var depth: usize = 0;
    for (dir_path) |c| {
        if (c == '/') depth += 1;
    }
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(testing.allocator);
    try path_buf.appendSlice(testing.allocator, dir_path);
    try path_buf.appendSlice(testing.allocator, "/a/b");
    for (0..depth + 3) |_| {
        try path_buf.appendSlice(testing.allocator, "/..");
    }

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", path_buf.items };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

test "readlink -m single component dotdot returns root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-m", "/nonexistent_vibeutils_test/.." };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());
}

// ============================================================================
// F44/F45: GNU compatibility tests for -f vs -e
// ============================================================================

test "readlink -f nonexistent last component exits 0 (GNU compat)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const nonexistent_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/no_such_file.txt",
        .{dir_path},
    );
    defer testing.allocator.free(nonexistent_path);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/no_such_file.txt\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", nonexistent_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink -f dangling symlink exits 0 (GNU compat)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink(io, "nonexistent_target", "dangling.txt", .{});

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/nonexistent_target\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink -f dangling symlink with absolute target exits 0 (GNU compat)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);

    const abs_target = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/abs_nonexistent",
        .{dir_path},
    );
    defer testing.allocator.free(abs_target);
    try tmp_dir.dir.symLink(io, abs_target, "dangling_abs.txt", .{});

    const link_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/dangling_abs.txt",
        .{dir_path},
    );
    defer testing.allocator.free(link_path);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/abs_nonexistent\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink -f intermediate missing should fail" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "/tmp/no_such_dir_vibeutils/no_such_file" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "readlink -e nonexistent last component should fail" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const nonexistent_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/no_such_file.txt",
        .{dir_path},
    );
    defer testing.allocator.free(nonexistent_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-e", nonexistent_path };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
}

test "readlink -f vs -e diverge on missing last component" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);
    const missing_path = try std.fmt.allocPrint(testing.allocator, "{s}/ghost_file", .{dir_path});
    defer testing.allocator.free(missing_path);

    var stdout_f: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_f.deinit();
    const args_f = [_][]const u8{ "-f", missing_path };
    const result_f = try runReadlink(
        testing.allocator,
        io,
        &args_f,
        &stdout_f.writer,
        common.null_writer,
    );

    var stdout_e: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_e.deinit();
    const args_e = [_][]const u8{ "-e", missing_path };
    const result_e = try runReadlink(
        testing.allocator,
        io,
        &args_e,
        &stdout_e.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result_f);
    try testing.expectEqual(@as(u8, 1), result_e);
}

// ============================================================================
// E7: Behavioral tests — parent-exists / last-missing semantics
// ============================================================================

test "readlink -f resolves canonical path when parent exists and last component missing" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try tmp_dir.dir.realPathFile(io, ".", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(dir_path);

    const nonexistent = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/e7_missing.txt",
        .{dir_path},
    );
    defer testing.allocator.free(nonexistent);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/e7_missing.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", nonexistent };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "readlink -f uses canonicalizeMissing: result is canonical not raw input" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-f", "/tmp/e7_vibeutils_canonical_test" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    const out = stdout_aw.writer.buffered();
    try testing.expectEqual(@as(u8, '/'), out[0]);
    try testing.expect(std.mem.endsWith(u8, out, "e7_vibeutils_canonical_test\n"));
    try testing.expect(std.mem.find(u8, out, "..") == null);
}

test "readlink -f dotdot past root is clamped (security)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Get the canonical form of /tmp for comparison.
    const real_tmp = blk: {
        var _rp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const _rp_len = try std.Io.Dir.realPathFileAbsolute(io, "/tmp", &_rp_buf);
        break :blk try testing.allocator.dupe(u8, _rp_buf[0.._rp_len]);
    };
    defer testing.allocator.free(real_tmp);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{real_tmp});
    defer testing.allocator.free(expected);

    const args = [_][]const u8{ "-f", "/../../tmp" };
    const result = try runReadlink(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}
