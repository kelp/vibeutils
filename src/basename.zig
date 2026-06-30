//! basename - strip directory and suffix from filenames
//!
//! The basename utility strips the directory components from one or more pathnames,
//! and also optionally strips a trailing suffix. This is useful for extracting
//! the final component of a pathname, the "basename".
//!
//! This implementation follows OpenBSD and GNU basename specifications, with
//! GNU extensions for multiple files and zero delimiters.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Write output with appropriate delimiter (newline or null)
fn writeOutput(writer: anytype, content: []const u8, zero: bool) !void {
    try writer.writeAll(content);
    if (zero) {
        try writer.writeByte(0);
    } else {
        try writer.writeByte('\n');
    }
}

/// Command-line arguments for the basename utility
const BasenameArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Support multiple arguments (GNU extension)
    multiple: bool = false,
    /// Use zero byte as separator instead of newline (GNU extension)
    zero: bool = false,
    /// Suffix to remove from filenames
    suffix: ?[]const u8 = null,
    /// File paths to process
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .multiple = .{ .short = 'a', .desc = "Support multiple arguments" },
        .zero = .{ .short = 'z', .desc = "Use null byte as separator" },
        .suffix = .{ .short = 's', .desc = "Remove trailing suffix", .value_name = "SUFFIX" },
    };
};

/// Main entry point for the basename utility
pub fn runBasename(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = io;
    // Parse command-line arguments
    const parsed_args = common.argparse.ArgParser.parse(BasenameArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "basename",
                    "unrecognized option",
                    .{},
                );
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "basename",
                    "option missing required argument",
                    .{},
                );
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "basename",
                    "invalid option value",
                    .{},
                );
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate arguments
    if (parsed_args.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "basename", "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }
    // The length-0 case returned above, so at least one operand is guaranteed
    // here; this is the precondition for the positionals[0]/[2] indexing below.
    std.debug.assert(parsed_args.positionals.len >= 1);

    return runBasenameProcess(allocator, parsed_args, stdout_writer, stderr_writer);
}

/// Emit basenames for the parsed operands, honoring -a/-s/-z modes.
fn runBasenameProcess(
    allocator: Allocator,
    parsed_args: BasenameArgs,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Process files - -s flag implies -a (multiple) according to GNU basename behavior
    if (parsed_args.multiple or parsed_args.suffix != null) {
        // Multiple file mode (GNU extension)
        for (parsed_args.positionals) |path| {
            const result = computeBasename(path, parsed_args.suffix);
            try writeOutput(stdout_writer, result, parsed_args.zero);
        }
    } else {
        // Standard POSIX mode (single file with optional suffix)
        if (parsed_args.positionals.len > 2) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "basename",
                "extra operand '{s}'",
                .{parsed_args.positionals[2]},
            );
            return @intFromEnum(common.ExitCode.misuse);
        }
        // The len > 2 case returned above; combined with len >= 1 this puts the
        // count in {1,2}, justifying positionals[0] and the guarded [1] access.
        std.debug.assert(parsed_args.positionals.len <= 2);

        const path = parsed_args.positionals[0];
        const maybe_suffix =
            if (parsed_args.positionals.len > 1) parsed_args.positionals[1] else null;

        const result = computeBasename(path, maybe_suffix);
        try writeOutput(stdout_writer, result, parsed_args.zero);
    }

    return @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runBasename);
}

/// Print help message to the specified writer
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: basename NAME [SUFFIX]
        \\   or: basename OPTION... NAME...
        \\Print NAME with any leading directory components removed.
        \\If specified, also remove a trailing SUFFIX.
        \\
        \\  -a, --multiple     support multiple arguments and treat each as a NAME
        \\  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a
        \\  -z, --zero         end each output line with NUL, not newline
        \\  -h, --help         display this help and exit
        \\  -V, --version      output version information and exit
        \\
        \\Examples:
        \\  basename /usr/bin/sort          Output "sort".
        \\  basename include/stdio.h .h     Output "stdio".
        \\  basename -s .h include/stdio.h  Output "stdio".
        \\  basename -a any/str1 any/str2   Output "str1", then "str2".
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("basename ({s}) {s}\n", .{ common.name, common.version });
}

/// Computes the basename of a path, optionally removing a suffix
/// Handles edge cases like / and // according to POSIX specifications
fn computeBasename(path: []const u8, maybe_suffix: ?[]const u8) []const u8 {
    if (path.len == 0) {
        return "";
    }
    // The empty case returned above, so every path below indexes a non-empty
    // slice (path[end - 1], path[0]) and forms path[0..end].
    std.debug.assert(path.len >= 1);

    // Handle special case for root directory
    if (std.mem.eql(u8, path, "/")) {
        return "/";
    }

    // Remove trailing slashes, except if the entire path is just slashes
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }
    // The loop only decrements while end > 1, and end starts at path.len (>= 1),
    // so end stays in [1, path.len]; this bounds the path[0..end] slice below.
    std.debug.assert(end >= 1);
    std.debug.assert(end <= path.len);

    // If we removed all characters except slashes, return /
    if (end == 1 and path[0] == '/') {
        return "/";
    }

    const trimmed_path = path[0..end];

    // Find the last slash to get the basename
    const basename_start = if (std.mem.findScalarLast(u8, trimmed_path, '/')) |last_slash|
        last_slash + 1
    else
        0;
    // basename_start is 0 or last_slash + 1 where last_slash indexes into
    // trimmed_path, so the trimmed_path[basename_start..] slice is in bounds.
    std.debug.assert(basename_start <= trimmed_path.len);

    var result = trimmed_path[basename_start..];

    // Remove suffix if present and valid
    if (maybe_suffix) |suffix| {
        if (suffix.len > 0 and
            std.mem.endsWith(u8, result, suffix) and
            !std.mem.eql(u8, result, suffix))
        {
            // endsWith being true means suffix is a trailing substring of
            // result, so result[0 .. result.len - suffix.len] never underflows.
            std.debug.assert(suffix.len <= result.len);
            result = result[0 .. result.len - suffix.len];
        }
    }

    return result;
}

// ============================================================================
// TESTS (TDD - Written First)
// ============================================================================

test "basename basic functionality" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Basic case: strip directory
    const args1 = [_][]const u8{"/usr/bin/tail"};
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("tail\n", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);
    stderr_aw.deinit();
    stderr_aw = .init(testing.allocator);

    // With suffix removal
    const args2 = [_][]const u8{ "file.txt", ".txt" };
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("file\n", stdout_aw.writer.buffered());
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "basename edge cases" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Root directory
    const args1 = [_][]const u8{"/"};
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Double slash (should return /)
    const args2 = [_][]const u8{"//"};
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("/\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // No slash (relative path)
    const args3 = [_][]const u8{"filename"};
    const result3 = try runBasename(
        testing.allocator,
        io,
        &args3,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result3);
    try testing.expectEqualStrings("filename\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Trailing slashes
    const args4 = [_][]const u8{"/usr/bin/"};
    const result4 = try runBasename(
        testing.allocator,
        io,
        &args4,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result4);
    try testing.expectEqualStrings("bin\n", stdout_aw.writer.buffered());
}

test "basename suffix removal" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Remove .txt suffix
    const args1 = [_][]const u8{ "document.txt", ".txt" };
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("document\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Suffix doesn't match - no removal
    const args2 = [_][]const u8{ "document.pdf", ".txt" };
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("document.pdf\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Suffix is entire basename - no removal (GNU behavior)
    const args3 = [_][]const u8{ ".txt", ".txt" };
    const result3 = try runBasename(
        testing.allocator,
        io,
        &args3,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result3);
    try testing.expectEqualStrings(".txt\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Empty suffix - no removal
    const args4 = [_][]const u8{ "file.txt", "" };
    const result4 = try runBasename(
        testing.allocator,
        io,
        &args4,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result4);
    try testing.expectEqualStrings("file.txt\n", stdout_aw.writer.buffered());
}

test "basename multiple files (-a flag)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Multiple files without suffix
    const args1 = [_][]const u8{ "-a", "/usr/bin/ls", "/home/user/file.txt", "simple" };
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("ls\nfile.txt\nsimple\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Multiple files with suffix removal
    const args2 = [_][]const u8{ "-a", "-s", ".txt", "file1.txt", "file2.txt", "file3.pdf" };
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("file1\nfile2\nfile3.pdf\n", stdout_aw.writer.buffered());
}

test "basename zero delimiter (-z flag)" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // Single file with zero delimiter
    const args1 = [_][]const u8{ "-z", "/usr/bin/test" };
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &buffer.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqual(@as(usize, 5), buffer.writer.buffered().len);
    try testing.expectEqualStrings("test", buffer.writer.buffered()[0..4]);
    try testing.expectEqual(@as(u8, 0), buffer.writer.buffered()[4]);

    buffer.deinit();
    buffer = .init(testing.allocator);

    // Multiple files with zero delimiter
    const args2 = [_][]const u8{ "-az", "file1", "file2" };
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &buffer.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqual(@as(usize, 12), buffer.writer.buffered().len);
    try testing.expectEqualStrings("file1", buffer.writer.buffered()[0..5]);
    try testing.expectEqual(@as(u8, 0), buffer.writer.buffered()[5]);
    try testing.expectEqualStrings("file2", buffer.writer.buffered()[6..11]);
    try testing.expectEqual(@as(u8, 0), buffer.writer.buffered()[11]);
}

test "basename error handling" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // No arguments provided
    const args1 = [_][]const u8{};
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 2), result1);
    try testing.expect(std.mem.indexOf(u8, stderr_aw.writer.buffered(), "missing operand") != null);

    stderr_aw.deinit();
    stderr_aw = .init(testing.allocator);
    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Too many arguments in standard mode
    const args2 = [_][]const u8{ "path1", "suffix", "extra" };
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 2), result2);
    try testing.expect(std.mem.indexOf(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "basename help and version" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // Test help
    const args1 = [_][]const u8{"--help"};
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &buffer.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expect(std.mem.find(u8, buffer.writer.buffered(), "Usage: basename") != null);
    try testing.expect(std.mem.find(u8, buffer.writer.buffered(), "--multiple") != null);

    buffer.deinit();
    buffer = .init(testing.allocator);

    // Test version
    const args2 = [_][]const u8{"--version"};
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &buffer.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expect(std.mem.find(u8, buffer.writer.buffered(), "basename") != null);
    try testing.expect(std.mem.find(u8, buffer.writer.buffered(), common.name) != null);
}

test "computeBasename function directly" {
    // Test the core logic directly
    try testing.expectEqualStrings("tail", computeBasename("/usr/bin/tail", null));
    try testing.expectEqualStrings("file", computeBasename("file.txt", ".txt"));
    try testing.expectEqualStrings("/", computeBasename("/", null));
    try testing.expectEqualStrings("/", computeBasename("//", null));
    try testing.expectEqualStrings("usr", computeBasename("/usr/", null));
    try testing.expectEqualStrings("basename", computeBasename("basename", null));
    // GNU basename "" outputs an empty line (bare newline), not "."
    try testing.expectEqualStrings("", computeBasename("", null));

    // Test suffix edge cases
    // Don't remove if entire name
    try testing.expectEqualStrings(".txt", computeBasename(".txt", ".txt"));
    try testing.expectEqualStrings("file.txt", computeBasename("file.txt", "")); // Empty suffix
    // Suffix doesn't match
    try testing.expectEqualStrings("file.pdf", computeBasename("file.pdf", ".txt"));

    // GNU: empty string with suffix still returns empty, not "."
    try testing.expectEqualStrings("", computeBasename("", ".txt"));
}

test "basename empty string with -a flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // GNU: basename -a "" "" outputs two empty lines (\n\n), not ".\n.\n"
    const args = [_][]const u8{ "-a", "", "" };
    const result = try runBasename(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n\n", stdout_aw.writer.buffered());
}

test "basename complex path cases" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Multiple trailing slashes
    const args1 = [_][]const u8{"/usr/bin///"};
    const result1 = try runBasename(
        testing.allocator,
        io,
        &args1,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("bin\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Complex path with many components
    const args2 = [_][]const u8{"/very/long/path/to/some/file.extension"};
    const result2 = try runBasename(
        testing.allocator,
        io,
        &args2,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("file.extension\n", stdout_aw.writer.buffered());

    stdout_aw.deinit();
    stdout_aw = .init(testing.allocator);

    // Path with dots but not at end
    const args3 = [_][]const u8{ "/path/to/file.name.ext", ".ext" };
    const result3 = try runBasename(
        testing.allocator,
        io,
        &args3,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result3);
    try testing.expectEqualStrings("file.name\n", stdout_aw.writer.buffered());
}

test "basename with -s flag (GNU extension)" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Using -s flag (should imply -a)
    const args = [_][]const u8{ "-s", ".c", "hello.c", "world.c", "test.h" };
    const result = try runBasename(
        testing.allocator,
        io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\ntest.h\n", stdout_aw.writer.buffered());
}
