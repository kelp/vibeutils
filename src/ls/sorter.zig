const std = @import("std");
const types = @import("types.zig");

const Entry = types.Entry;
const SortConfig = types.SortConfig;

/// Unified comparison function for directory entries
/// Handles all sorting modes: alphabetical, time, size, with directory grouping and reverse
pub fn compareEntries(config: SortConfig, a: Entry, b: Entry) bool {
    // Handle directory grouping first
    if (config.dirs_first) {
        const a_is_dir = a.kind == .directory;
        const b_is_dir = b.kind == .directory;
        if (a_is_dir != b_is_dir) {
            return a_is_dir; // Directories always come first
        }
    }

    // Primary sort criteria
    const result: bool = if (config.by_time) blk: {
        // Sort by modification time
        if (a.stat != null and b.stat != null and a.stat.?.mtime != b.stat.?.mtime) {
            break :blk a.stat.?.mtime > b.stat.?.mtime; // Newest first by default
        } else {
            // Fall back to name sort
            break :blk std.mem.order(u8, a.name, b.name) == .lt;
        }
    } else if (config.by_size) blk: {
        // Sort by size
        if (a.stat != null and b.stat != null and a.stat.?.size != b.stat.?.size) {
            break :blk a.stat.?.size > b.stat.?.size; // Largest first by default
        } else {
            // Fall back to name sort
            break :blk std.mem.order(u8, a.name, b.name) == .lt;
        }
    } else blk: {
        // Default: sort by name
        break :blk std.mem.order(u8, a.name, b.name) == .lt;
    };

    // Apply reverse if needed
    return if (config.reverse) !result else result;
}

/// Sort entries in place according to the provided configuration
pub fn sortEntries(entries: []Entry, config: SortConfig) void {
    std.mem.sort(Entry, entries, config, compareEntries);
}

// Tests
const testing = std.testing;

test "sorter - alphabetical sorting" {
    var entries = [_]Entry{
        .{ .name = "zebra", .kind = .file },
        .{ .name = "apple", .kind = .file },
        .{ .name = "banana", .kind = .file },
    };

    const config = SortConfig{};
    sortEntries(&entries, config);

    try testing.expectEqualStrings("apple", entries[0].name);
    try testing.expectEqualStrings("banana", entries[1].name);
    try testing.expectEqualStrings("zebra", entries[2].name);
}

test "sorter - reverse alphabetical sorting" {
    var entries = [_]Entry{
        .{ .name = "apple", .kind = .file },
        .{ .name = "banana", .kind = .file },
        .{ .name = "zebra", .kind = .file },
    };

    const config = SortConfig{ .reverse = true };
    sortEntries(&entries, config);

    try testing.expectEqualStrings("zebra", entries[0].name);
    try testing.expectEqualStrings("banana", entries[1].name);
    try testing.expectEqualStrings("apple", entries[2].name);
}

test "sorter - directories first" {
    var entries = [_]Entry{
        .{ .name = "file.txt", .kind = .file },
        .{ .name = "dir", .kind = .directory },
        .{ .name = "another_file", .kind = .file },
    };

    const config = SortConfig{ .dirs_first = true };
    sortEntries(&entries, config);

    // Directory should come first
    try testing.expectEqualStrings("dir", entries[0].name);
    try testing.expect(entries[0].kind == .directory);

    // Files should follow, sorted alphabetically
    try testing.expectEqualStrings("another_file", entries[1].name);
    try testing.expectEqualStrings("file.txt", entries[2].name);
}

test "sorter - size sorting" {
    const common = @import("common");

    var entries = [_]Entry{
        .{ .name = "small.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 0, .mode = 0, .kind = .file, .inode = 1, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "large.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 1000, .atime = 0, .mtime = 0, .mode = 0, .kind = .file, .inode = 2, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "medium.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 500, .atime = 0, .mtime = 0, .mode = 0, .kind = .file, .inode = 3, .nlink = 1, .uid = 1000, .gid = 1000 } },
    };

    const config = SortConfig{ .by_size = true };
    sortEntries(&entries, config);

    // Should be sorted by size, largest first
    try testing.expectEqualStrings("large.txt", entries[0].name);
    try testing.expectEqualStrings("medium.txt", entries[1].name);
    try testing.expectEqualStrings("small.txt", entries[2].name);
}

test "sorter - time sorting" {
    const common = @import("common");

    var entries = [_]Entry{
        .{ .name = "old.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 1000, .mode = 0, .kind = .file, .inode = 1, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "new.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 3000, .mode = 0, .kind = .file, .inode = 2, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "medium.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 2000, .mode = 0, .kind = .file, .inode = 3, .nlink = 1, .uid = 1000, .gid = 1000 } },
    };

    const config = SortConfig{ .by_time = true };
    sortEntries(&entries, config);

    // Should be sorted by time, newest first
    try testing.expectEqualStrings("new.txt", entries[0].name);
    try testing.expectEqualStrings("medium.txt", entries[1].name);
    try testing.expectEqualStrings("old.txt", entries[2].name);
}
