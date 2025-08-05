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

/// Processing mode for basename operation
const ProcessingMode = enum {
    /// Standard POSIX mode (single file with optional suffix)
    posix,
    /// Multiple file mode (GNU extension)
    multiple,
};

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

/// Determine the processing mode based on parsed arguments
fn getProcessingMode(parsedArgs: BasenameArgs) ProcessingMode {
    // -s flag implies -a (multiple) according to GNU basename behavior
    return if (parsedArgs.multiple or parsedArgs.suffix != null) .multiple else .posix;
}

/// Write basename result with appropriate delimiter
fn writeBasenameResult(writer: anytype, result: []const u8, useZeroDelimiter: bool) !void {
    try writer.writeAll(result);
    if (useZeroDelimiter) {
        try writer.writeByte(0);
    } else {
        try writer.writeByte('\n');
    }
}

/// Process multiple files in GNU multiple mode
fn processMultipleFiles(positionals: []const []const u8, suffix: ?[]const u8, stdoutWriter: anytype, useZeroDelimiter: bool) !void {
    for (positionals) |path| {
        const result = computeBasename(path, suffix);
        try writeBasenameResult(stdoutWriter, result, useZeroDelimiter);
    }
}

/// Process single file in POSIX mode
fn processSingleFile(allocator: std.mem.Allocator, positionals: []const []const u8, stderrWriter: anytype, stdoutWriter: anytype, useZeroDelimiter: bool) !u8 {
    if (positionals.len > 2) {
        common.printErrorWithProgram(allocator, stderrWriter, "basename", "extra operand '{s}'", .{positionals[2]});
        return @intFromEnum(common.ExitCode.general_error);
    }

    const path = positionals[0];
    const suffix = if (positionals.len > 1) positionals[1] else null;

    const result = computeBasename(path, suffix);
    try writeBasenameResult(stdoutWriter, result, useZeroDelimiter);
    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for the basename utility
pub fn runBasename(allocator: std.mem.Allocator, args: []const []const u8, stdoutWriter: anytype, stderrWriter: anytype) !u8 {
    // Parse arguments using new parser
    const parsedArgs = common.argparse.ArgParser.parse(BasenameArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderrWriter, "basename", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsedArgs.positionals);

    // Handle help
    if (parsedArgs.help) {
        try printHelp(stdoutWriter);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsedArgs.version) {
        try printVersion(stdoutWriter);
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate arguments
    if (parsedArgs.positionals.len == 0) {
        common.printErrorWithProgram(allocator, stderrWriter, "basename", "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Process based on mode
    const mode = getProcessingMode(parsedArgs);
    switch (mode) {
        .multiple => {
            try processMultipleFiles(parsedArgs.positionals, parsedArgs.suffix, stdoutWriter, parsedArgs.zero);
            return @intFromEnum(common.ExitCode.success);
        },
        .posix => {
            return try processSingleFile(allocator, parsedArgs.positionals, stderrWriter, stdoutWriter, parsedArgs.zero);
        },
    }
}

/// Main entry point for the basename utility
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runBasename(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Print help message to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: basename NAME [SUFFIX]
        \\   or: basename OPTION... NAME...
        \\Print NAME with any leading directory components removed.
        \\If specified, also remove a trailing SUFFIX.
        \\
        \\  -a, --multiple     support multiple arguments and treat each as a NAME
        \\  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a
        \\  -z, --zero         end each output line with NUL, not newline
        \\      --help         display this help and exit
        \\      --version      output version information and exit
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

/// Compute the basename of a path, optionally removing a suffix
/// Handles edge cases like / and // according to POSIX specifications
fn computeBasename(path: []const u8, maybeSuffix: ?[]const u8) []const u8 {
    if (path.len == 0) {
        return ".";
    }

    // Handle special cases for root directories
    if (std.mem.eql(u8, path, "/")) {
        return "/";
    }
    if (std.mem.eql(u8, path, "//")) {
        return "/";
    }

    // Remove trailing slashes, except if the entire path is just slashes
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }

    // If we removed all characters except slashes, return /
    if (end == 1 and path[0] == '/') {
        return "/";
    }

    const trimmedPath = path[0..end];

    // Find the last slash to get the basename
    const basenameStart = if (std.mem.lastIndexOfScalar(u8, trimmedPath, '/')) |lastSlash|
        lastSlash + 1
    else
        0;

    var result = trimmedPath[basenameStart..];

    // Remove suffix if specified and it matches
    if (maybeSuffix) |suffix| {
        if (suffix.len > 0 and result.len > suffix.len and
            std.mem.endsWith(u8, result, suffix) and
            !std.mem.eql(u8, result, suffix))
        {
            result = result[0 .. result.len - suffix.len];
        }
    }

    return result;
}

// ============================================================================
// TESTS (TDD - Written First)
// ============================================================================

/// Test helper to run basename with arguments and return output
fn testBasename(args: []const []const u8) !struct { exitCode: u8, stdout: []u8, stderr: []u8 } {
    var stdoutBuffer = std.ArrayList(u8).init(testing.allocator);
    var stderrBuffer = std.ArrayList(u8).init(testing.allocator);

    const exitCode = try runBasename(testing.allocator, args, stdoutBuffer.writer(), stderrBuffer.writer());

    return .{
        .exitCode = exitCode,
        .stdout = try stdoutBuffer.toOwnedSlice(),
        .stderr = try stderrBuffer.toOwnedSlice(),
    };
}

/// Test helper to expect specific basename output
fn expectBasenameOutput(args: []const []const u8, expectedOutput: []const u8) !void {
    const result = try testBasename(args);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.exitCode);
    try testing.expectEqualStrings(expectedOutput, result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "basename basic functionality" {
    // Basic case: strip directory
    try expectBasenameOutput(&.{"/usr/bin/tail"}, "tail\n");

    // With suffix removal
    try expectBasenameOutput(&.{ "file.txt", ".txt" }, "file\n");
}

test "basename edge cases" {
    // Root directory
    try expectBasenameOutput(&.{"/"}, "/\n");

    // Double slash (should return /)
    try expectBasenameOutput(&.{"//"}, "/\n");

    // No slash (relative path)
    try expectBasenameOutput(&.{"filename"}, "filename\n");

    // Trailing slashes
    try expectBasenameOutput(&.{"/usr/bin/"}, "bin\n");
}

test "basename suffix removal" {
    // Remove .txt suffix
    try expectBasenameOutput(&.{ "document.txt", ".txt" }, "document\n");

    // Suffix doesn't match - no removal
    try expectBasenameOutput(&.{ "document.pdf", ".txt" }, "document.pdf\n");

    // Suffix is entire basename - no removal (GNU behavior)
    try expectBasenameOutput(&.{ ".txt", ".txt" }, ".txt\n");

    // Empty suffix - no removal
    try expectBasenameOutput(&.{ "file.txt", "" }, "file.txt\n");
}

test "basename multiple files (-a flag)" {
    // Multiple files without suffix
    try expectBasenameOutput(&.{ "-a", "/usr/bin/ls", "/home/user/file.txt", "simple" }, "ls\nfile.txt\nsimple\n");

    // Multiple files with suffix removal
    try expectBasenameOutput(&.{ "-a", "-s", ".txt", "file1.txt", "file2.txt", "file3.pdf" }, "file1\nfile2\nfile3.pdf\n");
}

test "basename zero delimiter (-z flag)" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Single file with zero delimiter
    const args1 = [_][]const u8{ "-z", "/usr/bin/test" };
    const result1 = try runBasename(testing.allocator, &args1, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqual(@as(usize, 5), buffer.items.len);
    try testing.expectEqualStrings("test", buffer.items[0..4]);
    try testing.expectEqual(@as(u8, 0), buffer.items[4]);

    buffer.clearRetainingCapacity();

    // Multiple files with zero delimiter
    const args2 = [_][]const u8{ "-az", "file1", "file2" };
    const result2 = try runBasename(testing.allocator, &args2, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqual(@as(usize, 12), buffer.items.len);
    try testing.expectEqualStrings("file1", buffer.items[0..5]);
    try testing.expectEqual(@as(u8, 0), buffer.items[5]);
    try testing.expectEqualStrings("file2", buffer.items[6..11]);
    try testing.expectEqual(@as(u8, 0), buffer.items[11]);
}

test "basename error handling" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    // No arguments provided
    const args1 = [_][]const u8{};
    const result1 = try runBasename(testing.allocator, &args1, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 1), result1);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);

    stderr_buffer.clearRetainingCapacity();
    stdout_buffer.clearRetainingCapacity();

    // Too many arguments in standard mode
    const args2 = [_][]const u8{ "path1", "suffix", "extra" };
    const result2 = try runBasename(testing.allocator, &args2, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 1), result2);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "extra operand") != null);
}

test "basename help and version" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Test help
    const args1 = [_][]const u8{"--help"};
    const result1 = try runBasename(testing.allocator, &args1, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: basename") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "--multiple") != null);

    buffer.clearRetainingCapacity();

    // Test version
    const args2 = [_][]const u8{"--version"};
    const result2 = try runBasename(testing.allocator, &args2, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "basename") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, common.name) != null);
}

test "computeBasename function directly" {
    // Test the core logic directly
    try testing.expectEqualStrings("tail", computeBasename("/usr/bin/tail", null));
    try testing.expectEqualStrings("file", computeBasename("file.txt", ".txt"));
    try testing.expectEqualStrings("/", computeBasename("/", null));
    try testing.expectEqualStrings("/", computeBasename("//", null));
    try testing.expectEqualStrings("usr", computeBasename("/usr/", null));
    try testing.expectEqualStrings("basename", computeBasename("basename", null));
    try testing.expectEqualStrings(".", computeBasename("", null));

    // Test suffix edge cases
    try testing.expectEqualStrings(".txt", computeBasename(".txt", ".txt")); // Don't remove if entire name
    try testing.expectEqualStrings("file.txt", computeBasename("file.txt", "")); // Empty suffix
    try testing.expectEqualStrings("file.pdf", computeBasename("file.pdf", ".txt")); // Suffix doesn't match
}

test "basename complex path cases" {
    // Multiple trailing slashes
    try expectBasenameOutput(&.{"/usr/bin///"}, "bin\n");

    // Complex path with many components
    try expectBasenameOutput(&.{"/very/long/path/to/some/file.extension"}, "file.extension\n");

    // Path with dots but not at end
    try expectBasenameOutput(&.{ "/path/to/file.name.ext", ".ext" }, "file.name\n");
}

test "basename with -s flag (GNU extension)" {
    // Using -s flag (should imply -a)
    try expectBasenameOutput(&.{ "-s", ".c", "hello.c", "world.c", "test.h" }, "hello\nworld\ntest.h\n");
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("basename");

test "basename fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testBasenameIntelligentWrapper, .{});
}

fn testBasenameIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("basename")) return;

    const BasenameIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(BasenameArgs, runBasename);
    try BasenameIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
