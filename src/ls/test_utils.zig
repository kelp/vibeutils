const std = @import("std");
const common = @import("common");
const types = @import("types.zig");
const display = @import("display.zig");
const entry_collector = @import("entry_collector.zig");
const sorter = @import("sorter.zig");
const formatter = @import("formatter.zig");

const LsOptions = types.LsOptions;

/// Test helper that lists directory contents with proper writer-based error handling.
/// This function replicates the core ls functionality for testing purposes while
/// following the project's writer-based architecture pattern.
///
/// Parameters:
/// - dir: Directory handle to list contents from
/// - base_path: Path string to use for recursive operations and error messages
/// - stdout_writer: Writer for normal output (file listings)
/// - stderr_writer: Writer for error messages and warnings
/// - options: ls command-line options to apply
/// - allocator: Memory allocator for temporary data structures
pub fn listDirectoryTest(
    dir: std.fs.Dir,
    base_path: []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
) !void {
    // Only disable colors if color_mode is auto (the default),
    // but respect explicit color settings in tests
    var test_options = options;
    if (test_options.color_mode == .auto) {
        test_options.color_mode = .never;
    }

    const style = try display.initStyle(allocator, stdout_writer, test_options.color_mode);

    // If -d is specified, just list the directory itself
    if (test_options.directory) {
        try stdout_writer.print("{s}\n", .{base_path});
        return;
    }

    // Collect and filter entries
    var entries = try entry_collector.collectFilteredEntries(allocator, dir, test_options);
    defer {
        entry_collector.freeEntries(entries.items, allocator);
        entries.deinit(allocator);
    }

    // Enhance with metadata if needed
    if (entry_collector.needsMetadata(test_options)) {
        try entry_collector.enhanceEntriesWithMetadata(allocator, entries.items, dir, test_options, null, stderr_writer);
    }

    // Sort entries based on options
    const sort_config = types.SortConfig{
        .by_time = test_options.sort_by_time,
        .by_size = test_options.sort_by_size,
        .dirs_first = test_options.group_directories_first,
        .reverse = test_options.reverse_sort,
    };

    sorter.sortEntries(entries.items, sort_config);

    // Print entries
    _ = try formatter.printEntries(allocator, entries.items, stdout_writer, test_options, style);

    // Handle recursive listing
    if (test_options.recursive) {
        // For test purposes, we'll implement a simple recursive handler
        var visited_fs_ids = common.directory.FileSystemIdSet.initContext(allocator, common.directory.FileSystemId.Context{});
        defer visited_fs_ids.deinit();

        try entry_collector.processSubdirectoriesRecursively(entries.items, dir, base_path, stdout_writer, stderr_writer, test_options, allocator, style, &visited_fs_ids, null);
    }
}

/// Create a test entry with the given properties.
/// Allocates memory for the entry name that must be freed with freeTestEntry().
pub fn createTestEntry(allocator: std.mem.Allocator, name: []const u8, kind: std.fs.File.Kind) !types.Entry {
    return types.Entry{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
    };
}

/// Free a test entry's allocated memory.
/// Handles both the entry name and optional symlink_target.
pub fn freeTestEntry(entry: types.Entry, allocator: std.mem.Allocator) void {
    allocator.free(entry.name);
    if (entry.symlink_target) |target| {
        allocator.free(target);
    }
}

/// Create test entries for common test scenarios.
/// Returns an owned slice containing file, directory, and symlink entries.
/// Memory must be freed with freeTestEntries().
pub fn createTestEntries(allocator: std.mem.Allocator) ![]types.Entry {
    var entries = try std.ArrayList(types.Entry).initCapacity(allocator, 0);
    errdefer {
        for (entries.items) |entry| {
            freeTestEntry(entry, allocator);
        }
        entries.deinit(allocator);
    }

    try entries.append(allocator, try createTestEntry(allocator, "file1.txt", .file));
    try entries.append(allocator, try createTestEntry(allocator, "directory", .directory));
    try entries.append(allocator, try createTestEntry(allocator, "symlink", .sym_link));

    return entries.toOwnedSlice(allocator);
}

/// Free test entries array and all contained entry data.
/// Calls freeTestEntry() for each entry before freeing the array itself.
pub fn freeTestEntries(entries: []types.Entry, allocator: std.mem.Allocator) void {
    for (entries) |entry| {
        freeTestEntry(entry, allocator);
    }
    allocator.free(entries);
}

// Test environment constants
pub const TEST_SIZE_2K = 2048;
pub const TEST_SIZE_1_5K = 1500;
pub const TEST_TERMINAL_WIDTH = 40;

/// Complete test environment for ls integration tests.
/// Manages temporary directory, buffers, and provides convenient helpers.
pub const LsTestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    test_dir: std.fs.Dir,
    stdout_buffer: std.ArrayList(u8),
    stderr_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// Initialize test environment with fresh temporary directory and buffers.
    pub fn init(allocator: std.mem.Allocator) !LsTestEnv {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
        errdefer test_dir.close();

        return LsTestEnv{
            .tmp_dir = tmp_dir,
            .test_dir = test_dir,
            .stdout_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .stderr_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    /// Clean up all resources including temporary directory and buffers.
    pub fn deinit(self: *LsTestEnv) void {
        self.stdout_buffer.deinit(self.allocator);
        self.stderr_buffer.deinit(self.allocator);
        self.test_dir.close();
        self.tmp_dir.cleanup();
    }

    /// Create a regular file with specified name and content.
    pub fn createFile(self: *LsTestEnv, name: []const u8, content: []const u8) !void {
        const file = try self.tmp_dir.dir.createFile(name, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Create a regular file with specified name and size (filled with repeating pattern).
    pub fn createFileWithSize(self: *LsTestEnv, name: []const u8, size: usize, fill_char: u8) !void {
        const file = try self.tmp_dir.dir.createFile(name, .{});
        defer file.close();

        const data = try self.allocator.alloc(u8, size);
        defer self.allocator.free(data);
        @memset(data, fill_char);
        try file.writeAll(data);
    }

    /// Create an executable file with specified permissions.
    pub fn createExecutableFile(self: *LsTestEnv, name: []const u8) !void {
        const file = try self.tmp_dir.dir.createFile(name, .{ .mode = 0o755 });
        file.close();
    }

    /// Create a directory with specified name.
    pub fn createDir(self: *LsTestEnv, name: []const u8) !void {
        try self.tmp_dir.dir.makeDir(name);
    }

    /// Create a symbolic link pointing to target.
    pub fn createSymlink(self: *LsTestEnv, target: []const u8, link_name: []const u8) !void {
        try self.tmp_dir.dir.symLink(target, link_name, .{});
    }

    /// Create a directory and return an opened handle for further operations.
    pub fn createDirAndOpen(self: *LsTestEnv, name: []const u8) !std.fs.Dir {
        self.tmp_dir.dir.makeDir(name) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Directory already exists, that's fine
            else => return err,
        };
        return try self.tmp_dir.dir.openDir(name, .{});
    }

    /// Run ls with specified options and capture output to buffers.
    pub fn runLs(self: *LsTestEnv, options: LsOptions) !void {
        // Clear buffers for fresh output
        self.stdout_buffer.clearRetainingCapacity();
        self.stderr_buffer.clearRetainingCapacity();

        try listDirectoryTest(
            self.test_dir,
            ".",
            self.stdout_buffer.writer(self.allocator),
            self.stderr_buffer.writer(self.allocator),
            options,
            self.allocator,
        );
    }

    /// Get stdout output as string.
    pub fn getStdout(self: *LsTestEnv) []const u8 {
        return self.stdout_buffer.items;
    }

    /// Get stderr output as string.
    pub fn getStderr(self: *LsTestEnv) []const u8 {
        return self.stderr_buffer.items;
    }
};

/// Collection of assertion helpers for ls test output validation.
pub const LsAssertions = struct {
    /// Assert that stdout contains the specified filename.
    pub fn expectContainsFile(stdout: []const u8, filename: []const u8) !void {
        if (std.mem.indexOf(u8, stdout, filename) == null) {
            std.debug.print("Expected to find '{s}' in output:\n{s}\n", .{ filename, stdout });
            return error.FileNotFound;
        }
    }

    /// Assert that stdout does not contain the specified filename.
    pub fn expectNotContainsFile(stdout: []const u8, filename: []const u8) !void {
        if (std.mem.indexOf(u8, stdout, filename) != null) {
            std.debug.print("Expected NOT to find '{s}' in output:\n{s}\n", .{ filename, stdout });
            return error.UnexpectedFileFound;
        }
    }

    /// Assert that stdout contains the specified permission string.
    pub fn expectContainsPermissions(stdout: []const u8, perms: []const u8) !void {
        if (std.mem.indexOf(u8, stdout, perms) == null) {
            std.debug.print("Expected to find permissions '{s}' in output:\n{s}\n", .{ perms, stdout });
            return error.PermissionsNotFound;
        }
    }

    /// Assert that output is in one-per-line format with expected order.
    pub fn expectOnePerLineOrder(stdout: []const u8, expected_lines: []const []const u8) !void {
        var lines = std.mem.splitScalar(u8, stdout, '\n');

        for (expected_lines) |expected_line| {
            const actual_line = lines.next() orelse {
                std.debug.print("Expected line '{s}' but reached end of output\n", .{expected_line});
                return error.MissingLine;
            };

            if (!std.mem.eql(u8, actual_line, expected_line)) {
                std.debug.print("Expected line '{s}' but got '{s}'\n", .{ expected_line, actual_line });
                return error.LineOrderMismatch;
            }
        }

        // Verify no extra lines (except possible empty final line)
        if (lines.next()) |extra_line| {
            if (extra_line.len > 0) {
                std.debug.print("Unexpected extra line: '{s}'\n", .{extra_line});
                return error.ExtraLine;
            }
        }
    }

    /// Assert that output is in comma-separated format.
    pub fn expectCommaFormat(stdout: []const u8, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, stdout);
    }

    /// Assert that output contains symlink target notation.
    pub fn expectSymlinkTarget(stdout: []const u8, link_name: []const u8, target: []const u8) !void {
        const expected_format = try std.fmt.allocPrint(std.testing.allocator, "{s} -> {s}", .{ link_name, target });
        defer std.testing.allocator.free(expected_format);

        if (std.mem.indexOf(u8, stdout, expected_format) == null) {
            std.debug.print("Expected symlink format '{s}' in output:\n{s}\n", .{ expected_format, stdout });
            return error.SymlinkFormatNotFound;
        }
    }

    /// Assert that output contains file type indicators.
    pub fn expectFileTypeIndicator(stdout: []const u8, name_with_indicator: []const u8) !void {
        if (std.mem.indexOf(u8, stdout, name_with_indicator) == null) {
            std.debug.print("Expected file type indicator '{s}' in output:\n{s}\n", .{ name_with_indicator, stdout });
            return error.FileTypeIndicatorNotFound;
        }
    }

    /// Assert that output contains directory headers for recursive listing.
    pub fn expectDirectoryHeader(stdout: []const u8, header: []const u8) !void {
        if (std.mem.indexOf(u8, stdout, header) == null) {
            std.debug.print("Expected directory header '{s}' in output:\n{s}\n", .{ header, stdout });
            return error.DirectoryHeaderNotFound;
        }
    }

    /// Assert that output has multi-column format (fewer lines than files).
    pub fn expectMultiColumnFormat(stdout: []const u8, file_count: usize) !void {
        var lines = std.mem.splitScalar(u8, stdout, '\n');
        var line_count: usize = 0;

        while (lines.next()) |line| {
            if (line.len > 0) line_count += 1;
        }

        if (line_count >= file_count) {
            std.debug.print("Expected multi-column format (lines < files), but got {} lines for {} files\n", .{ line_count, file_count });
            return error.NotMultiColumn;
        }
    }

    /// Assert that output contains numeric values (for testing -i inode or -n numeric IDs).
    pub fn expectContainsNumeric(stdout: []const u8, description: []const u8) !void {
        var has_numeric = false;
        var iter = std.mem.tokenizeAny(u8, stdout, " \n\t");

        while (iter.next()) |token| {
            if (std.fmt.parseInt(u64, token, 10)) |_| {
                has_numeric = true;
                break;
            } else |_| {
                // Continue checking other tokens
            }
        }

        if (!has_numeric) {
            std.debug.print("Expected to find numeric values for {s} in output:\n{s}\n", .{ description, stdout });
            return error.NumericValueNotFound;
        }
    }

    /// Assert that output contains a specific size format (like "2.0K" for human readable).
    pub fn expectHumanReadableSize(stdout: []const u8, expected_size: []const u8) !void {
        if (std.mem.indexOf(u8, stdout, expected_size) == null) {
            std.debug.print("Expected human readable size '{s}' in output:\n{s}\n", .{ expected_size, stdout });
            return error.HumanReadableSizeNotFound;
        }
    }

    /// Assert that output is exactly the expected string (for precise matching).
    pub fn expectExactOutput(stdout: []const u8, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, stdout);
    }
};

/// Platform compatibility helpers for tests that may behave differently across systems.
pub const PlatformHelpers = struct {
    /// Check if current platform supports certain features for conditional testing.
    pub fn supportsSymlinks() bool {
        // Most modern systems support symlinks, but we can extend this if needed
        return true;
    }

    /// Check if current platform supports executable bit testing.
    pub fn supportsExecutableBit() bool {
        return builtin.os.tag != .windows;
    }

    /// Get expected permission string prefix for current platform.
    pub fn getFilePermissionPrefix() []const u8 {
        return if (builtin.os.tag == .windows) "" else "-rw-";
    }
};

const builtin = @import("builtin");

// Tests for the test utilities themselves
const testing = std.testing;

test "test_utils - createTestEntry" {
    const entry = try createTestEntry(testing.allocator, "test.txt", .file);
    defer freeTestEntry(entry, testing.allocator);

    try testing.expectEqualStrings("test.txt", entry.name);
    try testing.expectEqual(std.fs.File.Kind.file, entry.kind);
}

test "test_utils - createTestEntries" {
    const entries = try createTestEntries(testing.allocator);
    defer freeTestEntries(entries, testing.allocator);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("file1.txt", entries[0].name);
    try testing.expectEqualStrings("directory", entries[1].name);
    try testing.expectEqualStrings("symlink", entries[2].name);
}

test "test_utils - LsTestEnv basic operations" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Test file creation
    try env.createFile("test.txt", "content");
    try env.createDir("testdir");

    // Test running ls
    try env.runLs(.{});

    // Test assertions
    try LsAssertions.expectContainsFile(env.getStdout(), "test.txt");
    try LsAssertions.expectContainsFile(env.getStdout(), "testdir");
}

test "test_utils - LsAssertions validation" {
    const sample_output = "file1.txt\nfile2.txt\n";

    // These should succeed
    try LsAssertions.expectContainsFile(sample_output, "file1.txt");
    try LsAssertions.expectContainsFile(sample_output, "file2.txt");

    // This should succeed (not contains)
    try LsAssertions.expectNotContainsFile(sample_output, "missing.txt");

    // Test one-per-line order
    try LsAssertions.expectOnePerLineOrder(sample_output, &.{ "file1.txt", "file2.txt" });
}
