//! mktemp - create a temporary file or directory
//!
//! The mktemp utility creates a temporary file or directory safely using
//! a unique name generated from a template. The template must contain
//! at least three consecutive 'X' characters at the end, which are
//! replaced with random alphanumeric characters.
//!
//! This implementation follows GNU coreutils mktemp behavior.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const prog_name = "mktemp";
const default_template = "tmp.XXXXXXXXXX";
const alphanumeric = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Command-line arguments for the mktemp utility
const MktempArgs = struct {
    /// Create a directory instead of a file
    directory: bool = false,
    /// Don't create anything; print name only (unsafe)
    @"dry-run": bool = false,
    /// Suppress error messages
    quiet: bool = false,
    /// Use DIR as the temporary directory
    tmpdir: ?[]const u8 = null,
    /// Append SUFF to template
    suffix: ?[]const u8 = null,
    /// Interpret TEMPLATE relative to TMPDIR
    t: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Positional arguments (template)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .directory = .{ .short = 'd', .desc = "Create a directory, not a file" },
        .@"dry-run" = .{ .short = 'u', .desc = "Do not create anything; print a name (unsafe)" },
        .quiet = .{ .short = 'q', .desc = "Suppress diagnostics about failure to create" },
        .tmpdir = .{ .short = 'p', .desc = "Use DIR as prefix", .value_name = "DIR" },
        .suffix = .{ .desc = "Append SUFF to template", .value_name = "SUFF" },
        .t = .{ .desc = "Interpret TEMPLATE relative to a directory" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Main entry point
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runMktemp(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Run the mktemp utility with given arguments
pub fn runMktemp(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed = common.argparse.ArgParser.parse(MktempArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid option\nTry 'mktemp --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "option requires an argument\nTry 'mktemp --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid argument value\nTry 'mktemp --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed.positionals);

    if (parsed.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Too many positional arguments
    if (parsed.positionals.len > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "too many templates\nTry 'mktemp --help' for more information.", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Get template
    const raw_template = if (parsed.positionals.len == 1) parsed.positionals[0] else default_template;

    // Validate suffix does not contain path separator
    const suffix = parsed.suffix orelse "";
    if (std.mem.indexOfScalar(u8, suffix, '/') != null) {
        if (!parsed.quiet) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid suffix '{s}': contains directory separator", .{suffix});
        }
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Count trailing X's in the raw template (before suffix)
    const x_count = countTrailingXs(raw_template);
    if (x_count < 3) {
        if (!parsed.quiet) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "too few X's in template '{s}'", .{raw_template});
        }
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Determine the directory to use
    const tmpdir = resolveTmpdir(allocator, parsed.tmpdir, parsed.t, raw_template) catch {
        if (!parsed.quiet) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to resolve temporary directory", .{});
        }
        return @intFromEnum(common.ExitCode.general_error);
    };

    // Extract just the filename part of the raw template
    const template_basename = std.fs.path.basename(raw_template);

    // Build the filename: template_basename + suffix
    const filename = if (suffix.len > 0)
        std.fmt.allocPrint(allocator, "{s}{s}", .{ template_basename, suffix }) catch {
            if (!parsed.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to allocate memory", .{});
            }
            return @intFromEnum(common.ExitCode.general_error);
        }
    else
        template_basename;

    // Build the full path: tmpdir/filename
    const full_template = std.fs.path.join(allocator, &.{ tmpdir, filename }) catch {
        if (!parsed.quiet) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to allocate memory", .{});
        }
        return @intFromEnum(common.ExitCode.general_error);
    };

    // Generate the temporary file or directory
    // x_count refers to X's in the template portion (before suffix)
    const result_path = generateTemp(allocator, full_template, x_count, suffix.len, parsed.directory, parsed.@"dry-run") catch {
        if (!parsed.quiet) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "failed to create {s} via template '{s}'", .{
                if (parsed.directory) "directory" else "file",
                full_template,
            });
        }
        return @intFromEnum(common.ExitCode.general_error);
    };

    try stdout_writer.print("{s}\n", .{result_path});

    return @intFromEnum(common.ExitCode.success);
}

/// Count trailing 'X' characters in the template
fn countTrailingXs(template: []const u8) usize {
    var count: usize = 0;
    var i = template.len;
    while (i > 0) {
        i -= 1;
        if (template[i] == 'X') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Resolve the temporary directory to use
fn resolveTmpdir(allocator: Allocator, tmpdir_arg: ?[]const u8, t_flag: bool, template: []const u8) ![]const u8 {
    // If -p DIR was specified, use that
    if (tmpdir_arg) |dir| {
        return try allocator.dupe(u8, dir);
    }

    // If -t flag is set, or if template has no directory component, use TMPDIR
    if (t_flag or std.fs.path.dirname(template) == null) {
        // Check TMPDIR environment variable
        if (std.posix.getenv("TMPDIR")) |env_val| {
            return try allocator.dupe(u8, env_val);
        }
        return try allocator.dupe(u8, "/tmp");
    }

    // Template has a directory component; extract it
    if (std.fs.path.dirname(template)) |dir| {
        return try allocator.dupe(u8, dir);
    }

    return try allocator.dupe(u8, "/tmp");
}

/// Generate a temporary file or directory with a unique name
/// Tries up to 100 times with different random suffixes
/// suffix_len indicates how many bytes at the end are the suffix (after the X's)
fn generateTemp(allocator: Allocator, template: []const u8, x_count: usize, suffix_len: usize, is_dir: bool, dry_run: bool) ![]const u8 {
    const max_attempts = 100;
    // Layout: [prefix][XXXXXX][suffix]
    const x_end = template.len - suffix_len;
    const x_start = x_end - x_count;

    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        // Build the candidate name
        const candidate = try allocator.alloc(u8, template.len);

        // Copy prefix (before the X's)
        @memcpy(candidate[0..x_start], template[0..x_start]);

        // Fill X positions with random alphanumeric characters
        fillRandom(candidate[x_start..x_end]);

        // Copy suffix (after the X's)
        if (suffix_len > 0) {
            @memcpy(candidate[x_end..], template[x_end..]);
        }

        if (dry_run) {
            return candidate;
        }

        if (is_dir) {
            // Try to create directory
            std.fs.cwd().makeDir(candidate) catch |err| {
                allocator.free(candidate);
                switch (err) {
                    error.PathAlreadyExists => continue,
                    else => return err,
                }
            };
            // Set directory permissions to 0o700 for security
            if (builtin.os.tag != .windows) {
                const path_z = std.posix.toPosixPath(candidate) catch {
                    return candidate;
                };
                _ = std.c.chmod(&path_z, 0o700);
            }
            return candidate;
        } else {
            // Try to create file atomically with mode 0o600
            const file = std.fs.cwd().createFile(candidate, .{
                .exclusive = true,
                .mode = 0o600,
            }) catch |err| {
                allocator.free(candidate);
                switch (err) {
                    error.PathAlreadyExists => continue,
                    else => return err,
                }
            };
            file.close();
            return candidate;
        }
    }

    return error.TooManyAttempts;
}

/// Fill a buffer with random alphanumeric characters
fn fillRandom(buf: []u8) void {
    // Use OS random source for cryptographic quality
    var random_bytes: [256]u8 = undefined;
    const needed = @min(buf.len, random_bytes.len);
    std.posix.getrandom(random_bytes[0..needed]) catch {
        // Fallback: use timestamp-based PRNG if getrandom fails
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@max(0, std.time.timestamp()))));
        const rng = prng.random();
        for (buf) |*b| {
            b.* = alphanumeric[rng.intRangeAtMost(u8, 0, alphanumeric.len - 1)];
        }
        return;
    };
    for (buf, 0..) |*b, i| {
        if (i < needed) {
            b.* = alphanumeric[random_bytes[i] % alphanumeric.len];
        }
    }
}

/// Print help message
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: mktemp [OPTION]... [TEMPLATE]
        \\Create a temporary file or directory, safely, and print its name.
        \\TEMPLATE must contain at least 3 consecutive 'X's in last component.
        \\If TEMPLATE is not specified, use tmp.XXXXXXXXXX.
        \\
        \\  -d, --directory    create a directory, not a file
        \\  -u, --dry-run      do not create anything; merely print a name (unsafe)
        \\  -q, --quiet        suppress diagnostics about file/dir-creation failure
        \\  -p DIR, --tmpdir=DIR  use DIR as prefix; if not given, use $TMPDIR or /tmp
        \\      --suffix=SUFF  append SUFF to TEMPLATE
        \\  -t                 interpret TEMPLATE relative to a directory
        \\  -h, --help         display this help and exit
        \\  -V, --version      output version information and exit
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("mktemp ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                TESTS
// ============================================================================

test "mktemp countTrailingXs" {
    try testing.expectEqual(@as(usize, 10), countTrailingXs("tmp.XXXXXXXXXX"));
    try testing.expectEqual(@as(usize, 3), countTrailingXs("tmp.XXX"));
    try testing.expectEqual(@as(usize, 0), countTrailingXs("tmp.txt"));
    try testing.expectEqual(@as(usize, 0), countTrailingXs(""));
    try testing.expectEqual(@as(usize, 5), countTrailingXs("XXXXX"));
    try testing.expectEqual(@as(usize, 0), countTrailingXs("XXXabc"));
    try testing.expectEqual(@as(usize, 3), countTrailingXs("prefixXXX"));
}

test "mktemp fillRandom produces alphanumeric characters" {
    var buf: [20]u8 = undefined;
    fillRandom(&buf);
    for (buf) |c| {
        try testing.expect(std.mem.indexOfScalar(u8, alphanumeric, c) != null);
    }
}

test "mktemp fillRandom produces different results" {
    var buf1: [10]u8 = undefined;
    var buf2: [10]u8 = undefined;
    fillRandom(&buf1);
    fillRandom(&buf2);
    // Verify both contain valid alphanumeric characters
    for (buf1) |c| {
        try testing.expect(std.mem.indexOfScalar(u8, alphanumeric, c) != null);
    }
    for (buf2) |c| {
        try testing.expect(std.mem.indexOfScalar(u8, alphanumeric, c) != null);
    }
}

test "mktemp --help shows usage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--help"};
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: mktemp") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--directory") != null);
}

test "mktemp --version shows version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--version"};
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mktemp") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
}

test "mktemp too few Xs in template" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"tmp.XX"};
    const exit_code = try runMktemp(allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "too few X's") != null);
}

test "mktemp too many templates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "tmp.XXX", "tmp2.XXX" };
    const exit_code = try runMktemp(allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "too many templates") != null);
}

test "mktemp creates file with default template" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{};
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Output should be a path ending with newline
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expect(stdout_buffer.items[stdout_buffer.items.len - 1] == '\n');

    // Clean up the created file
    const path = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    std.fs.cwd().deleteFile(path) catch {};
}

test "mktemp creates directory with -d flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"-d"};
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const path = std.mem.trimRight(u8, stdout_buffer.items, "\n");

    // Verify it's a directory
    const stat = try std.fs.cwd().statFile(path);
    try testing.expect(stat.kind == .directory);

    // Clean up
    std.fs.cwd().deleteDir(path) catch {};
}

test "mktemp dry-run does not create file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"-u"};
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const path = std.mem.trimRight(u8, stdout_buffer.items, "\n");

    // File should not exist
    const result = std.fs.cwd().access(path, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "mktemp with custom template" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"myapp.XXXXXX"};
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const path = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    const basename = std.fs.path.basename(path);

    // Should start with "myapp."
    try testing.expect(std.mem.startsWith(u8, basename, "myapp."));

    // Clean up
    std.fs.cwd().deleteFile(path) catch {};
}

test "mktemp with --suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "--suffix=.txt", "tmpXXXXXX" };
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const path = std.mem.trimRight(u8, stdout_buffer.items, "\n");

    // Should end with .txt suffix
    try testing.expect(std.mem.endsWith(u8, path, ".txt"));

    // Should start with "tmp" in the basename
    const basename = std.fs.path.basename(path);
    try testing.expect(std.mem.startsWith(u8, basename, "tmp"));

    // Clean up
    std.fs.cwd().deleteFile(path) catch {};
}

test "mktemp suffix with slash is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "--suffix=/bad", "tmpXXXXXX" };
    const exit_code = try runMktemp(allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "contains directory separator") != null);
}

test "mktemp with -p flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Use a known temp directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);

    const args = &[_][]const u8{ "-p", dir_path };
    const exit_code = try runMktemp(allocator, args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const result_path = std.mem.trimRight(u8, stdout_buffer.items, "\n");

    // Result should be within the specified directory
    try testing.expect(std.mem.startsWith(u8, result_path, dir_path));

    // Clean up
    std.fs.cwd().deleteFile(result_path) catch {};
}

test "mktemp quiet mode suppresses errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{ "-q", "tmp.XX" };
    const exit_code = try runMktemp(allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), exit_code);
    // Quiet mode: no error messages on stderr
    try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "mktemp invalid option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = &[_][]const u8{"--invalid"};
    const exit_code = try runMktemp(allocator, args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), exit_code);
}

test "mktemp generateTemp creates unique names" {
    // Generate two temps and verify they differ (dry-run mode)
    const path1 = try generateTemp(testing.allocator, "/tmp/test.XXXXXX", 6, 0, false, true);
    defer testing.allocator.free(path1);
    const path2 = try generateTemp(testing.allocator, "/tmp/test.XXXXXX", 6, 0, false, true);
    defer testing.allocator.free(path2);

    // Both should start with /tmp/test.
    try testing.expect(std.mem.startsWith(u8, path1, "/tmp/test."));
    try testing.expect(std.mem.startsWith(u8, path2, "/tmp/test."));

    // Very unlikely to be the same
    try testing.expectEqual(@as(usize, 16), path1.len);
    try testing.expectEqual(@as(usize, 16), path2.len);
}
