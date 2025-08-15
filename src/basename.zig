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

/// Write output with appropriate delimiter (newline or null)
fn writeOutput(writer: anytype, content: []const u8, useZero: bool) !void {
    try writer.writeAll(content);
    if (useZero) {
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

    // Process files - -s flag implies -a (multiple) according to GNU basename behavior
    if (parsedArgs.multiple or parsedArgs.suffix != null) {
        // Multiple file mode (GNU extension)
        for (parsedArgs.positionals) |path| {
            const result = computeBasename(path, parsedArgs.suffix);
            try writeOutput(stdoutWriter, result, parsedArgs.zero);
        }
    } else {
        // Standard POSIX mode (single file with optional suffix)
        if (parsedArgs.positionals.len > 2) {
            common.printErrorWithProgram(allocator, stderrWriter, "basename", "extra operand '{s}'", .{parsedArgs.positionals[2]});
            return @intFromEnum(common.ExitCode.general_error);
        }

        const path = parsedArgs.positionals[0];
        const suffix = if (parsedArgs.positionals.len > 1) parsedArgs.positionals[1] else null;

        const result = computeBasename(path, suffix);
        try writeOutput(stdoutWriter, result, parsedArgs.zero);
    }

    return @intFromEnum(common.ExitCode.success);
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

/// Computes the basename of a path, optionally removing a suffix
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

    // Remove suffix if present and valid
    if (maybeSuffix) |suffix| {
        if (suffix.len > 0 and std.mem.endsWith(u8, result, suffix) and !std.mem.eql(u8, result, suffix)) {
            result = result[0 .. result.len - suffix.len];
        }
    }

    return result;
}

// ============================================================================
// TESTS (TDD - Written First)
// ============================================================================

/// Test helper for managing stdout/stderr buffers
const TestBuffers = struct {
    stdout: std.ArrayList(u8),
    stderr: std.ArrayList(u8),

    fn init() TestBuffers {
        return TestBuffers{
            .stdout = std.ArrayList(u8).init(testing.allocator),
            .stderr = std.ArrayList(u8).init(testing.allocator),
        };
    }

    fn deinit(self: *TestBuffers) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    fn clear(self: *TestBuffers) void {
        self.stdout.clearRetainingCapacity();
        self.stderr.clearRetainingCapacity();
    }

    fn stdoutWriter(self: *TestBuffers) @TypeOf(self.stdout.writer()) {
        return self.stdout.writer();
    }

    fn stderrWriter(self: *TestBuffers) @TypeOf(self.stderr.writer()) {
        return self.stderr.writer();
    }

    fn expectStdout(self: *TestBuffers, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.stdout.items);
    }

    fn expectStderr(self: *TestBuffers, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.stderr.items);
    }
};

test "basename basic functionality" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Basic case: strip directory
    const args1 = [_][]const u8{"/usr/bin/tail"};
    const result1 = try runBasename(testing.allocator, &args1, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("tail\n", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    // With suffix removal
    const args2 = [_][]const u8{ "file.txt", ".txt" };
    const result2 = try runBasename(testing.allocator, &args2, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("file\n", stdout_buffer.items);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "basename edge cases" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Root directory
    const args1 = [_][]const u8{"/"};
    const result1 = try runBasename(testing.allocator, &args1, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("/\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Double slash (should return /)
    const args2 = [_][]const u8{"//"};
    const result2 = try runBasename(testing.allocator, &args2, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("/\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // No slash (relative path)
    const args3 = [_][]const u8{"filename"};
    const result3 = try runBasename(testing.allocator, &args3, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result3);
    try testing.expectEqualStrings("filename\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Trailing slashes
    const args4 = [_][]const u8{"/usr/bin/"};
    const result4 = try runBasename(testing.allocator, &args4, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result4);
    try testing.expectEqualStrings("bin\n", stdout_buffer.items);
}

test "basename suffix removal" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Remove .txt suffix
    const args1 = [_][]const u8{ "document.txt", ".txt" };
    const result1 = try runBasename(testing.allocator, &args1, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("document\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Suffix doesn't match - no removal
    const args2 = [_][]const u8{ "document.pdf", ".txt" };
    const result2 = try runBasename(testing.allocator, &args2, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("document.pdf\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Suffix is entire basename - no removal (GNU behavior)
    const args3 = [_][]const u8{ ".txt", ".txt" };
    const result3 = try runBasename(testing.allocator, &args3, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result3);
    try testing.expectEqualStrings(".txt\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Empty suffix - no removal
    const args4 = [_][]const u8{ "file.txt", "" };
    const result4 = try runBasename(testing.allocator, &args4, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result4);
    try testing.expectEqualStrings("file.txt\n", stdout_buffer.items);
}

test "basename multiple files (-a flag)" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Multiple files without suffix
    const args1 = [_][]const u8{ "-a", "/usr/bin/ls", "/home/user/file.txt", "simple" };
    const result1 = try runBasename(testing.allocator, &args1, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("ls\nfile.txt\nsimple\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Multiple files with suffix removal
    const args2 = [_][]const u8{ "-a", "-s", ".txt", "file1.txt", "file2.txt", "file3.pdf" };
    const result2 = try runBasename(testing.allocator, &args2, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("file1\nfile2\nfile3.pdf\n", stdout_buffer.items);
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
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Multiple trailing slashes
    const args1 = [_][]const u8{"/usr/bin///"};
    const result1 = try runBasename(testing.allocator, &args1, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result1);
    try testing.expectEqualStrings("bin\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Complex path with many components
    const args2 = [_][]const u8{"/very/long/path/to/some/file.extension"};
    const result2 = try runBasename(testing.allocator, &args2, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result2);
    try testing.expectEqualStrings("file.extension\n", stdout_buffer.items);

    stdout_buffer.clearRetainingCapacity();

    // Path with dots but not at end
    const args3 = [_][]const u8{ "/path/to/file.name.ext", ".ext" };
    const result3 = try runBasename(testing.allocator, &args3, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result3);
    try testing.expectEqualStrings("file.name\n", stdout_buffer.items);
}

test "basename with -s flag (GNU extension)" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Using -s flag (should imply -a)
    const args = [_][]const u8{ "-s", ".c", "hello.c", "world.c", "test.h" };
    const result = try runBasename(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\ntest.h\n", stdout_buffer.items);
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
