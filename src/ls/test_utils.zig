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
        entries.deinit();
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
    var entries = std.ArrayList(types.Entry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            freeTestEntry(entry, allocator);
        }
        entries.deinit();
    }

    try entries.append(try createTestEntry(allocator, "file1.txt", .file));
    try entries.append(try createTestEntry(allocator, "directory", .directory));
    try entries.append(try createTestEntry(allocator, "symlink", .sym_link));

    return entries.toOwnedSlice();
}

/// Free test entries array and all contained entry data.
/// Calls freeTestEntry() for each entry before freeing the array itself.
pub fn freeTestEntries(entries: []types.Entry, allocator: std.mem.Allocator) void {
    for (entries) |entry| {
        freeTestEntry(entry, allocator);
    }
    allocator.free(entries);
}

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
