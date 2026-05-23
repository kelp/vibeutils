//! dirname - strip last component from file name
//!
//! Strips the last component from each pathname, outputting
//! the directory portion. Follows POSIX specifications.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Command-line arguments for dirname utility
const DirnameArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Display version and exit
    version: bool = false,
    /// End each output line with NUL, not newline
    zero: bool = false,
    /// Positional arguments (pathnames)
    positionals: []const []const u8 = &.{},

    /// Argument parser metadata
    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .zero = .{ .short = 'z', .desc = "End each output line with NUL, not newline" },
    };
};

/// Execute dirname utility with given arguments and writers
pub fn runDirname(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    _ = io;
    const parsed_args = common.argparse.ArgParser.parse(DirnameArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "dirname", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "dirname", "option missing required argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "dirname", "invalid option value", .{});
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
        try stdout_writer.print("dirname ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "dirname", "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const separator: u8 = if (parsed_args.zero) '\x00' else '\n';

    for (parsed_args.positionals) |path| {
        const dirname = extractDirname(path);
        try stdout_writer.print("{s}{c}", .{ dirname, separator });
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Extract directory portion from pathname according to POSIX dirname specification
///
/// Returns a slice into the input string or a string literal ("." or "/").
/// No allocation is performed - the caller must not attempt to free the result.
///
/// POSIX dirname behavior:
/// - "/path/to/file" → "/path/to" (remove last component)
/// - "file.txt" → "." (no slash means current directory)
/// - "/" → "/" (root stays root)
/// - "/usr/" → "/" (trailing slash stripped, then processed)
/// - "" → "." (empty path means current directory)
fn extractDirname(path: []const u8) []const u8 {
    if (path.len == 0) {
        return ".";
    }

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }

    const last_slash = std.mem.findScalarLast(u8, path[0..end], '/');

    if (last_slash == null) {
        return ".";
    }

    if (last_slash.? == 0) {
        return "/";
    }

    var dirname_end = last_slash.?;
    while (dirname_end > 1 and path[dirname_end - 1] == '/') {
        dirname_end -= 1;
    }

    return path[0..dirname_end];
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: dirname [OPTION] NAME...
        \\Output each NAME with its last non-slash component and trailing slashes
        \\removed; if NAME contains no /'s, output '.' (meaning the current directory).
        \\
        \\  -z, --zero     end each output line with NUL, not newline
        \\  -h, --help     display this help and exit
        \\  -V, --version  output version information and exit
        \\
        \\Examples:
        \\  dirname /usr/bin/         -> "/usr"
        \\  dirname dir1/str dir2/str -> "dir1" followed by "dir2"
        \\  dirname stdio.h           -> "."
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runDirname);
}

// ============================================================================
// Tests
// ============================================================================

test "dirname: basic cases" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "/usr/bin/ls", .expected = "/usr/bin" },
        .{ .input = "usr/bin", .expected = "usr" },
        .{ .input = "file.txt", .expected = "." },
        .{ .input = "dir/file.txt", .expected = "dir" },
        .{ .input = "a/b/c", .expected = "a/b" },
    };

    for (cases) |case| {
        const result = extractDirname(case.input);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "dirname: root paths" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "/", .expected = "/" },
        .{ .input = "//", .expected = "/" },
        .{ .input = "///", .expected = "/" },
        .{ .input = "/a", .expected = "/" },
        .{ .input = "////", .expected = "/" },
    };

    for (cases) |case| {
        const result = extractDirname(case.input);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "dirname: trailing slashes" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "/usr/bin/", .expected = "/usr" },
        .{ .input = "usr/bin/", .expected = "usr" },
        .{ .input = "/usr/", .expected = "/" },
        .{ .input = "usr/", .expected = "." },
        .{ .input = "usr//bin//", .expected = "usr" },
    };

    for (cases) |case| {
        const result = extractDirname(case.input);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "dirname: special cases" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "", .expected = "." },
        .{ .input = ".", .expected = "." },
        .{ .input = "..", .expected = "." },
        .{ .input = "./file", .expected = "." },
        .{ .input = "../file", .expected = ".." },
        .{ .input = "a", .expected = "." },
    };

    for (cases) |case| {
        const result = extractDirname(case.input);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "dirname: edge cases" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "./././", .expected = "./." },
        .{ .input = "../../../", .expected = "../.." },
        .{ .input = "path with spaces/file name.txt", .expected = "path with spaces" },
        .{ .input = "/home/user/documents/file.txt", .expected = "/home/user/documents" },
        .{ .input = "relative/path/to/resource", .expected = "relative/path/to" },
    };

    for (cases) |case| {
        const result = extractDirname(case.input);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "dirname: multiple paths" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "/usr/bin", "file.txt", "dir/subdir/" };
    const result = try runDirname(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr\n.\ndir\n", stdout_aw.writer.buffered());
}

test "dirname: zero flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-z", "/usr/bin", "file.txt", "/" };
    const result = try runDirname(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr\x00.\x00/\x00", stdout_aw.writer.buffered());
}

test "dirname: long zero flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "--zero", "path/to/file" };
    const result = try runDirname(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("path/to\x00", stdout_aw.writer.buffered());
}

test "dirname: missing operand error" {
    const io = testing.io;

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runDirname(testing.allocator, io, &.{}, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "dirname: help flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDirname(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: dirname") != null);
}

test "dirname: version flag" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runDirname(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "dirname") != null);
}

test "dirname: combined flags" {
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Test that -z and paths work together
    const args = [_][]const u8{ "-z", "a/b", "c/d", "e" };
    const result = try runDirname(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\x00c\x00.\x00", stdout_aw.writer.buffered());
}
