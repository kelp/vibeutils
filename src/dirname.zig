//! Extract directory portion of pathname

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

/// Main entry point for dirname utility
pub fn runDirname(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parse(DirnameArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "dirname", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "dirname", "option missing required argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "dirname", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help flag
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag
    if (parsed_args.version) {
        try stdout_writer.print("dirname ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    // Check for missing operands
    if (parsed_args.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "dirname", "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Process each path
    const separator: u8 = if (parsed_args.zero) '\x00' else '\n';

    for (parsed_args.positionals) |path| {
        const dirname = try extractDirname(path, allocator);
        try stdout_writer.print("{s}{c}", .{ dirname, separator });
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Extract directory portion from pathname according to POSIX dirname specification
///
/// POSIX dirname behavior:
/// - "/path/to/file" → "/path/to" (remove last component)
/// - "file.txt" → "." (no slash means current directory)
/// - "/" → "/" (root stays root)
/// - "/usr/" → "/" (trailing slash stripped, then processed)
/// - "" → "." (empty path means current directory)
///
/// The algorithm strips trailing slashes first (except when the entire path is root),
/// then finds the last slash to determine the directory portion.
fn extractDirname(path: []const u8, allocator: Allocator) ![]u8 {
    // 1. Handle empty → "."
    if (path.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    // 2. Strip trailing slashes (keep root)
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }

    // 3. Find last slash in stripped path
    const last_slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/');

    // 4. No slash → "."
    if (last_slash == null) {
        return try allocator.dupe(u8, ".");
    }

    // 5. Slash at 0 → "/"
    if (last_slash.? == 0) {
        return try allocator.dupe(u8, "/");
    }

    // 6. Strip trailing slashes from dirname and return
    var dirname_end = last_slash.?;
    while (dirname_end > 1 and path[dirname_end - 1] == '/') {
        dirname_end -= 1;
    }

    return try allocator.dupe(u8, path[0..dirname_end]);
}

/// Print help message
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
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

/// Main entry point
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runDirname(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
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
        const result = try extractDirname(case.input, testing.allocator);
        defer testing.allocator.free(result);
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
        const result = try extractDirname(case.input, testing.allocator);
        defer testing.allocator.free(result);
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
        const result = try extractDirname(case.input, testing.allocator);
        defer testing.allocator.free(result);
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
        const result = try extractDirname(case.input, testing.allocator);
        defer testing.allocator.free(result);
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
        const result = try extractDirname(case.input, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "dirname: multiple paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{ "/usr/bin", "file.txt", "dir/subdir/" };
    const result = try runDirname(allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr\n.\ndir\n", stdout_buffer.items);
}

test "dirname: zero flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{ "-z", "/usr/bin", "file.txt", "/" };
    const result = try runDirname(allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("/usr\x00.\x00/\x00", stdout_buffer.items);
}

test "dirname: long zero flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{ "--zero", "path/to/file" };
    const result = try runDirname(allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("path/to\x00", stdout_buffer.items);
}

test "dirname: missing operand error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const result = try runDirname(allocator, &.{}, common.null_writer, stderr_buffer.writer());

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "dirname: help flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runDirname(allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: dirname") != null);
}

test "dirname: version flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runDirname(allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "dirname") != null);
}

test "dirname: combined flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    // Test that -z and paths work together
    const args = [_][]const u8{ "-z", "a/b", "c/d", "e" };
    const result = try runDirname(allocator, &args, stdout_buffer.writer(), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("a\x00c\x00.\x00", stdout_buffer.items);
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("dirname");

test "dirname fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testDirnameIntelligentWrapper, .{});
}

fn testDirnameIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("dirname")) return;

    const DirnameIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(DirnameArgs, runDirname);
    try DirnameIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
