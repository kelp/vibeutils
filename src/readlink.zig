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
        .canonicalize = .{ .short = 'f', .desc = "canonicalize path; all but the last component must exist" },
        .@"canonicalize-existing" = .{ .short = 'e', .desc = "canonicalize path; all components must exist" },
        .@"canonicalize-missing" = .{ .short = 'm', .desc = "canonicalize path; components need not exist" },
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
pub fn runReadlink(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments
    const parsed = common.argparse.ArgParser.parse(ReadlinkArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "readlink", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "readlink", "option missing required argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "readlink", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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
        return @intFromEnum(common.ExitCode.misuse);
    }

    const canon_mode = getCanonicalizeMode(parsed);
    const quiet = parsed.quiet or parsed.silent;
    const verbose = parsed.verbose and !quiet;
    var has_error = false;

    for (parsed.positionals) |path| {
        const result = resolveLink(allocator, path, canon_mode);
        if (result) |resolved| {
            defer allocator.free(resolved);
            try stdout_writer.writeAll(resolved);
            if (parsed.zero) {
                try stdout_writer.writeByte(0);
            } else if (!parsed.@"no-newline") {
                try stdout_writer.writeByte('\n');
            }
        } else |err| {
            has_error = true;
            if (verbose) {
                const err_msg = switch (err) {
                    error.FileNotFound => "No such file or directory",
                    error.NotLink => "Invalid argument",
                    error.AccessDenied => "Permission denied",
                    error.NameTooLong => "File name too long",
                    error.NotDir => "Not a directory",
                    else => "cannot read link",
                };
                common.printErrorWithProgram(allocator, stderr_writer, "readlink", "{s}: {s}", .{ path, err_msg });
            }
        }
    }

    return if (has_error) @intFromEnum(common.ExitCode.general_error) else @intFromEnum(common.ExitCode.success);
}

/// Resolve a link target or canonicalize a path
fn resolveLink(allocator: Allocator, path: []const u8, mode: CanonicalizeMode) ![]u8 {
    switch (mode) {
        .none => {
            // Just read the symlink target, no canonicalization
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try std.fs.cwd().readLink(path, &buf);
            return try allocator.dupe(u8, target);
        },
        .canonical_missing_ok => {
            // GNU -f: all but the last component must exist.
            // Use the common function for parent-must-exist semantics.
            return resolveCanonicalMissingOk(allocator, path);
        },
        .strict => {
            // Canonicalize: resolve to absolute path, all components must exist
            const resolved = try std.fs.cwd().realpathAlloc(allocator, path);
            return resolved;
        },
        .missing => {
            // Canonicalize: components need not exist
            // Try realpath first; if it fails, build canonical path manually
            if (std.fs.cwd().realpathAlloc(allocator, path)) |resolved| {
                return resolved;
            } else |_| {
                return try path_utils.canonicalizeMissing(allocator, path);
            }
        },
    }
}

/// GNU -f resolution: the last component may be missing, but all
/// parent components must exist. For symlinks, read the link target
/// first and then resolve that target path.
fn resolveCanonicalMissingOk(allocator: Allocator, path: []const u8) ![]u8 {
    // Check if path is a symlink (even a dangling one)
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().readLink(path, &link_buf)) |link_target| {
        // It's a symlink. Resolve the target path.
        // If target is relative, make it relative to the symlink's directory.
        if (std.fs.path.isAbsolute(link_target)) {
            // Absolute target: resolve it directly with missing-ok logic
            return path_utils.canonicalizeParentMustExist(allocator, link_target);
        } else {
            // Relative target: resolve relative to the symlink's parent dir
            const dir = std.fs.path.dirname(path) orelse ".";
            const resolved_dir = try std.fs.cwd().realpathAlloc(allocator, dir);
            defer allocator.free(resolved_dir);
            const full_target = try std.fs.path.join(allocator, &.{ resolved_dir, link_target });
            defer allocator.free(full_target);
            // Try full realpath on the joined path first
            if (std.fs.cwd().realpathAlloc(allocator, full_target)) |resolved| {
                return resolved;
            } else |_| {
                return path_utils.canonicalizeParentMustExist(allocator, full_target);
            }
        }
    } else |_| {
        // Not a symlink (or doesn't exist at all).
        // Try to resolve the parent directory and append the basename.
        return path_utils.canonicalizeParentMustExist(allocator, path);
    }
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
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
fn printVersion(writer: anytype) !void {
    try writer.print("readlink ({s}) {s}\n", .{ common.name, common.version });
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

    const exit_code = try runReadlink(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

// ============================================================================
// TESTS
// ============================================================================

test "readlink basic symlink" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a target file and a symlink
    const target = try tmp_dir.dir.createFile("target.txt", .{});
    try target.writeAll("content");
    target.close();
    try tmp_dir.dir.symLink("target.txt", "link.txt", .{});

    // Get absolute path to the symlink
    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{link_path};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("target.txt\n", stdout_buf.items);
}

test "readlink not a symlink" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile("regular.txt", .{});
    target.close();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/regular.txt", .{dir_path});
    defer testing.allocator.free(file_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{file_path};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "readlink nonexistent file" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"/tmp/definitely_nonexistent_readlink_test"};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "readlink verbose error" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-v", "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "No such file or directory") != null);
}

test "readlink quiet suppresses errors" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-v", "-q", "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    // -q overrides -v, so no error output
    try testing.expectEqualStrings("", stderr_buf.items);
}

test "readlink canonicalize (-f)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile("real_file.txt", .{});
    target.close();
    try tmp_dir.dir.symLink("real_file.txt", "link.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    const expected_path = try std.fmt.allocPrint(testing.allocator, "{s}/real_file.txt\n", .{dir_path});
    defer testing.allocator.free(expected_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected_path, stdout_buf.items);
}

test "readlink canonicalize regular file (-f)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile("regular.txt", .{});
    target.close();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/regular.txt", .{dir_path});
    defer testing.allocator.free(file_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/regular.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", file_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "readlink canonicalize-existing (-e)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile("exists.txt", .{});
    target.close();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/exists.txt", .{dir_path});
    defer testing.allocator.free(file_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/exists.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", file_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "readlink canonicalize nonexistent succeeds with -f when parent exists (GNU compat)" {
    // GNU -f allows the last component to be missing, so
    // /tmp/nonexistent exits 0 because /tmp exists.
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), result);
}

test "readlink canonicalize-missing (-m) with nonexistent path" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const test_path = try std.fmt.allocPrint(testing.allocator, "{s}/nonexistent/file.txt", .{dir_path});
    defer testing.allocator.free(test_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", test_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Should contain the directory path and end with the filename
    try testing.expect(stdout_buf.items.len > 0);
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "nonexistent/file.txt\n"));
}

test "readlink no-newline (-n)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile("target.txt", .{});
    target.close();
    try tmp_dir.dir.symLink("target.txt", "link.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Should NOT end with newline
    try testing.expectEqualStrings("target.txt", stdout_buf.items);
}

test "readlink zero delimiter (-z)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile("target.txt", .{});
    target.close();
    try tmp_dir.dir.symLink("target.txt", "link.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-z", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqual(@as(usize, 11), stdout_buf.items.len);
    try testing.expectEqualStrings("target.txt", stdout_buf.items[0..10]);
    try testing.expectEqual(@as(u8, 0), stdout_buf.items[10]);
}

test "readlink multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const t1 = try tmp_dir.dir.createFile("t1.txt", .{});
    t1.close();
    const t2 = try tmp_dir.dir.createFile("t2.txt", .{});
    t2.close();
    try tmp_dir.dir.symLink("t1.txt", "l1.txt", .{});
    try tmp_dir.dir.symLink("t2.txt", "l2.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const l1_path = try std.fmt.allocPrint(testing.allocator, "{s}/l1.txt", .{dir_path});
    defer testing.allocator.free(l1_path);
    const l2_path = try std.fmt.allocPrint(testing.allocator, "{s}/l2.txt", .{dir_path});
    defer testing.allocator.free(l2_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ l1_path, l2_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("t1.txt\nt2.txt\n", stdout_buf.items);
}

test "readlink mixed success and failure" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const t1 = try tmp_dir.dir.createFile("t1.txt", .{});
    t1.close();
    try tmp_dir.dir.symLink("t1.txt", "l1.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const l1_path = try std.fmt.allocPrint(testing.allocator, "{s}/l1.txt", .{dir_path});
    defer testing.allocator.free(l1_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    // One valid symlink, one nonexistent
    const args = [_][]const u8{ l1_path, "/tmp/definitely_nonexistent_readlink_test" };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    // Should fail because one path failed
    try testing.expectEqual(@as(u8, 1), result);
    // But should still output the successful one
    try testing.expectEqualStrings("t1.txt\n", stdout_buf.items);
}

test "readlink missing operand" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "missing operand") != null);
}

test "readlink help" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Usage: readlink") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--canonicalize") != null);
}

test "readlink version" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "readlink") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, common.version) != null);
}

test "readlink unknown flag" {
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid-flag"};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), stderr_buf.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "unrecognized option") != null);
}

test "readlink dangling symlink" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a symlink to a nonexistent target
    try tmp_dir.dir.symLink("nonexistent_target", "dangling.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    // Without canonicalize, readlink should still return the target
    const args = [_][]const u8{link_path};
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("nonexistent_target\n", stdout_buf.items);
}

test "readlink dangling symlink with -f succeeds (GNU compat)" {
    // GNU -f: last component may be missing. A dangling symlink whose
    // target's parent directory exists should resolve successfully.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink("nonexistent_target", "dangling.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/nonexistent_target\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    // GNU -f exits 0 for dangling symlinks when parent exists
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "readlink canonicalize-missing with dangling symlink (-m)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.symLink("nonexistent_target", "dangling.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    // -m should succeed even for dangling symlinks
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buf.items.len > 0);
}

test "readlink -m dotdot past root returns root" {
    // Use a real tmp directory so the prefix resolves, then traverse past root.
    // e.g. /real/dir/nonexistent/../../../.. should eventually resolve to /
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    // Count the depth of the resolved directory so we can go past root.
    // e.g. "/private/tmp/zig-XXXX" has depth 3, so we need 4+ ".." after
    // the nonexistent component (which adds 1 to depth).
    var depth: usize = 0;
    for (dir_path) |c| {
        if (c == '/') depth += 1;
    }
    // Build: {dir_path}/nonexistent/../../..(depth+1 times)
    // nonexistent adds 1 level, so total ".." needed = depth + 1
    var path_buf = std.ArrayListUnmanaged(u8){};
    defer path_buf.deinit(testing.allocator);
    try path_buf.appendSlice(testing.allocator, dir_path);
    try path_buf.appendSlice(testing.allocator, "/nonexistent");
    for (0..depth + 1) |_| {
        try path_buf.appendSlice(testing.allocator, "/..");
    }

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", path_buf.items };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_buf.items);
}

test "readlink -m multi-level dotdot past root returns root" {
    // Test with two nonexistent components followed by enough ".." to pass root.
    // e.g. /real/dir/a/b/../../../../.. -> /
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    var depth: usize = 0;
    for (dir_path) |c| {
        if (c == '/') depth += 1;
    }
    // Two nonexistent components add 2 to depth, so we need depth + 2 + 1 ".."
    // to go one level past root (but root clamps to /).
    var path_buf = std.ArrayListUnmanaged(u8){};
    defer path_buf.deinit(testing.allocator);
    try path_buf.appendSlice(testing.allocator, dir_path);
    try path_buf.appendSlice(testing.allocator, "/a/b");
    for (0..depth + 3) |_| {
        try path_buf.appendSlice(testing.allocator, "/..");
    }

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", path_buf.items };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_buf.items);
}

test "readlink -m single component dotdot returns root" {
    // Test /nonexistent/.. -> /
    // Since /nonexistent doesn't exist, this goes through the "else" branch
    // of canonicalizeMissing (no resolved prefix). Verify it still works.
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", "/nonexistent_vibeutils_test/.." };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/\n", stdout_buf.items);
}

// ============================================================================
// F44/F45: GNU compatibility tests for -f vs -e
// These tests document correct GNU behavior. Currently FAILING because
// our -f behaves like -e (requires all components to exist).
// ============================================================================

test "readlink -f nonexistent last component exits 0 (GNU compat)" {
    // GNU: readlink -f /existing_dir/nonexistent_file -> prints path, exits 0
    // All components except the last must exist. The last may be missing.
    // Our implementation incorrectly exits 1 because -f maps to .strict
    // which uses realpathAlloc (requires everything to exist).
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const nonexistent_path = try std.fmt.allocPrint(testing.allocator, "{s}/no_such_file.txt", .{dir_path});
    defer testing.allocator.free(nonexistent_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/no_such_file.txt\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", nonexistent_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    // GNU exits 0 when parent exists but last component is missing
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "readlink -f dangling symlink exits 0 (GNU compat)" {
    // GNU: readlink -f <dangling_symlink> -> resolves parent, prints
    // canonical path to where target would be, exits 0.
    // Our implementation exits 1 because realpathAlloc fails on
    // dangling symlinks.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a dangling symlink with a relative target
    try tmp_dir.dir.symLink("nonexistent_target", "dangling.txt", .{});

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    // GNU resolves the symlink target relative to the symlink's directory
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/nonexistent_target\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    // GNU exits 0 for dangling symlinks with -f
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "readlink -f dangling symlink with absolute target exits 0 (GNU compat)" {
    // Dangling symlink pointing to absolute path where parent exists
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    // Symlink target is an absolute path to a nonexistent file in tmp_dir
    const abs_target = try std.fmt.allocPrint(testing.allocator, "{s}/abs_nonexistent", .{dir_path});
    defer testing.allocator.free(abs_target);
    try tmp_dir.dir.symLink(abs_target, "dangling_abs.txt", .{});

    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dangling_abs.txt", .{dir_path});
    defer testing.allocator.free(link_path);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/abs_nonexistent\n", .{dir_path});
    defer testing.allocator.free(expected);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", link_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings(expected, stdout_buf.items);
}

test "readlink -f intermediate missing should fail" {
    // When an intermediate directory does not exist, -f should fail
    // (same as GNU behavior). This is a boundary test.
    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "/tmp/no_such_dir_vibeutils/no_such_file" };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    // Both GNU and our implementation should fail here
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "readlink -e nonexistent last component should fail" {
    // -e requires ALL components to exist, including the last one.
    // This is the key difference from -f.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const nonexistent_path = try std.fmt.allocPrint(testing.allocator, "{s}/no_such_file.txt", .{dir_path});
    defer testing.allocator.free(nonexistent_path);

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", nonexistent_path };
    const result = try runReadlink(testing.allocator, &args, stdout_buf.writer(testing.allocator), common.null_writer);
    // -e should fail when last component is missing
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expectEqualStrings("", stdout_buf.items);
}

test "readlink -f vs -e diverge on missing last component" {
    // -f should succeed (exit 0) and -e should fail (exit 1) when
    // the parent directory exists but the last component does not.
    // This test demonstrates the semantic difference between the two flags.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const missing_path = try std.fmt.allocPrint(testing.allocator, "{s}/ghost_file", .{dir_path});
    defer testing.allocator.free(missing_path);

    // Test -f: should succeed
    var stdout_f = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_f.deinit(testing.allocator);
    const args_f = [_][]const u8{ "-f", missing_path };
    const result_f = try runReadlink(testing.allocator, &args_f, stdout_f.writer(testing.allocator), common.null_writer);

    // Test -e: should fail
    var stdout_e = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_e.deinit(testing.allocator);
    const args_e = [_][]const u8{ "-e", missing_path };
    const result_e = try runReadlink(testing.allocator, &args_e, stdout_e.writer(testing.allocator), common.null_writer);

    // -f exits 0, -e exits 1: they must diverge
    try testing.expectEqual(@as(u8, 0), result_f);
    try testing.expectEqual(@as(u8, 1), result_e);
}
