const std = @import("std");
const types = @import("types.zig");

const Entry = types.Entry;
const SortConfig = types.SortConfig;

/// Unified comparison function for directory entries
/// Handles all sorting modes: alphabetical, time, size, extension, version
/// with directory grouping and reverse
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
        // Sort by time (mtime by default, atime with -u, ctime with -c)
        if (a.stat != null and b.stat != null) {
            const a_time = if (config.use_ctime) a.stat.?.ctime else if (config.use_atime) a.stat.?.atime else a.stat.?.mtime;
            const b_time = if (config.use_ctime) b.stat.?.ctime else if (config.use_atime) b.stat.?.atime else b.stat.?.mtime;
            if (a_time != b_time) {
                break :blk a_time > b_time; // Newest first by default
            }
        }
        // Fall back to name sort
        break :blk std.mem.order(u8, a.name, b.name) == .lt;
    } else if (config.by_size) blk: {
        // Sort by size
        if (a.stat != null and b.stat != null and a.stat.?.size != b.stat.?.size) {
            break :blk a.stat.?.size > b.stat.?.size; // Largest first by default
        } else {
            // Fall back to name sort
            break :blk std.mem.order(u8, a.name, b.name) == .lt;
        }
    } else if (config.by_extension) blk: {
        // Sort by file extension, then by name
        const a_ext = getExtension(a.name);
        const b_ext = getExtension(b.name);
        const ext_cmp = std.mem.order(u8, a_ext, b_ext);
        if (ext_cmp != .eq) {
            break :blk ext_cmp == .lt;
        }
        // Same extension, fall back to name sort
        break :blk std.mem.order(u8, a.name, b.name) == .lt;
    } else if (config.version_sort) blk: {
        // Natural version sort
        break :blk versionCompare(a.name, b.name) == .lt;
    } else blk: {
        // Default: sort by name
        break :blk std.mem.order(u8, a.name, b.name) == .lt;
    };

    // Apply reverse if needed
    return if (config.reverse) !result else result;
}

/// Get file extension (part after last '.'), or empty string if none.
/// Files starting with '.' and having no other '.' return empty extension.
fn getExtension(name: []const u8) []const u8 {
    // Find last dot, excluding leading dot
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') {
            if (i == 0) return ""; // Hidden file with no extension
            return name[i + 1 ..];
        }
    }
    return ""; // No extension
}

/// Compare two strings using natural version sort order.
/// Numeric parts are compared as numbers (file2 < file10).
fn versionCompare(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;

    while (ai < a.len and bi < b.len) {
        const a_is_digit = std.ascii.isDigit(a[ai]);
        const b_is_digit = std.ascii.isDigit(b[bi]);

        if (a_is_digit and b_is_digit) {
            // Compare numeric parts as numbers
            // Skip leading zeros
            const a_start = ai;
            const b_start = bi;
            while (ai < a.len and a[ai] == '0') ai += 1;
            while (bi < b.len and b[bi] == '0') bi += 1;

            // Count digits
            const a_num_start = ai;
            const b_num_start = bi;
            while (ai < a.len and std.ascii.isDigit(a[ai])) ai += 1;
            while (bi < b.len and std.ascii.isDigit(b[bi])) bi += 1;
            // The leading-zero and digit-count loops only advance the indices,
            // so each cursor sits at or past where it began. This guards the
            // unsigned subtractions below (num_len and zeros) from underflow.
            std.debug.assert(ai >= a_num_start);
            std.debug.assert(bi >= b_num_start);
            std.debug.assert(a_num_start >= a_start);
            std.debug.assert(b_num_start >= b_start);
            const a_num_len = ai - a_num_start;
            const b_num_len = bi - b_num_start;

            // Different digit count means different magnitude
            if (a_num_len != b_num_len) {
                return if (a_num_len < b_num_len) .lt else .gt;
            }

            // Same number of digits - compare lexicographically
            if (a_num_len > 0) {
                const a_digits = a[a_num_start..ai];
                const b_digits = b[b_num_start..bi];
                const ord = std.mem.order(u8, a_digits, b_digits);
                if (ord != .eq) return ord;
            }

            // Equal numeric values - fewer leading zeros comes first
            const a_zeros = a_num_start - a_start;
            const b_zeros = b_num_start - b_start;
            if (a_zeros != b_zeros) {
                return if (a_zeros < b_zeros) .lt else .gt;
            }
        } else {
            // Compare non-numeric characters
            if (a[ai] != b[bi]) {
                return if (a[ai] < b[bi]) .lt else .gt;
            }
            ai += 1;
            bi += 1;
        }
    }

    // One or both strings exhausted
    if (ai < a.len) return .gt;
    if (bi < b.len) return .lt;
    return .eq;
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

test "sorter - atime sorting with use_atime" {
    const common = @import("common");

    // Files with different atime values (atime order differs from mtime order)
    var entries = [_]Entry{
        .{ .name = "old_access.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 1000, .mtime = 3000, .mode = 0, .kind = .file, .inode = 1, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "new_access.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 3000, .mtime = 1000, .mode = 0, .kind = .file, .inode = 2, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "mid_access.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 2000, .mtime = 2000, .mode = 0, .kind = .file, .inode = 3, .nlink = 1, .uid = 1000, .gid = 1000 } },
    };

    const config = SortConfig{ .by_time = true, .use_atime = true };
    sortEntries(&entries, config);

    // Should be sorted by atime, newest first
    try testing.expectEqualStrings("new_access.txt", entries[0].name);
    try testing.expectEqualStrings("mid_access.txt", entries[1].name);
    try testing.expectEqualStrings("old_access.txt", entries[2].name);
}

test "sorter - ctime sorting with use_ctime" {
    const common = @import("common");

    // Files with different ctime values (ctime order differs from mtime order)
    var entries = [_]Entry{
        .{ .name = "old_change.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 3000, .ctime = 1000, .mode = 0, .kind = .file, .inode = 1, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "new_change.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 1000, .ctime = 3000, .mode = 0, .kind = .file, .inode = 2, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "mid_change.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 0, .mtime = 2000, .ctime = 2000, .mode = 0, .kind = .file, .inode = 3, .nlink = 1, .uid = 1000, .gid = 1000 } },
    };

    const config = SortConfig{ .by_time = true, .use_ctime = true };
    sortEntries(&entries, config);

    // Should be sorted by ctime, newest first
    try testing.expectEqualStrings("new_change.txt", entries[0].name);
    try testing.expectEqualStrings("mid_change.txt", entries[1].name);
    try testing.expectEqualStrings("old_change.txt", entries[2].name);
}

test "sorter - ctime takes precedence over atime" {
    const common = @import("common");

    // When both use_ctime and use_atime are set, ctime should take precedence
    var entries = [_]Entry{
        .{ .name = "a.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 3000, .mtime = 0, .ctime = 1000, .mode = 0, .kind = .file, .inode = 1, .nlink = 1, .uid = 1000, .gid = 1000 } },
        .{ .name = "b.txt", .kind = .file, .stat = common.file.FileInfo{ .size = 100, .atime = 1000, .mtime = 0, .ctime = 3000, .mode = 0, .kind = .file, .inode = 2, .nlink = 1, .uid = 1000, .gid = 1000 } },
    };

    const config = SortConfig{ .by_time = true, .use_ctime = true, .use_atime = true };
    sortEntries(&entries, config);

    // ctime should take priority: b.txt (ctime=3000) before a.txt (ctime=1000)
    try testing.expectEqualStrings("b.txt", entries[0].name);
    try testing.expectEqualStrings("a.txt", entries[1].name);
}

test "sorter - extension sorting" {
    var entries = [_]Entry{
        .{ .name = "readme.md", .kind = .file },
        .{ .name = "main.c", .kind = .file },
        .{ .name = "util.c", .kind = .file },
        .{ .name = "build.zig", .kind = .file },
        .{ .name = "notes.txt", .kind = .file },
    };

    const config = SortConfig{ .by_extension = true };
    sortEntries(&entries, config);

    // Should be sorted by extension: .c, .md, .txt, .zig
    try testing.expectEqualStrings("main.c", entries[0].name);
    try testing.expectEqualStrings("util.c", entries[1].name);
    try testing.expectEqualStrings("readme.md", entries[2].name);
    try testing.expectEqualStrings("notes.txt", entries[3].name);
    try testing.expectEqualStrings("build.zig", entries[4].name);
}

test "sorter - extension sorting with no extension" {
    var entries = [_]Entry{
        .{ .name = "Makefile", .kind = .file },
        .{ .name = "readme.md", .kind = .file },
        .{ .name = "LICENSE", .kind = .file },
    };

    const config = SortConfig{ .by_extension = true };
    sortEntries(&entries, config);

    // Files without extensions sort before those with extensions
    // (empty string < "md")
    try testing.expectEqualStrings("LICENSE", entries[0].name);
    try testing.expectEqualStrings("Makefile", entries[1].name);
    try testing.expectEqualStrings("readme.md", entries[2].name);
}

test "sorter - version sort basic" {
    var entries = [_]Entry{
        .{ .name = "file10", .kind = .file },
        .{ .name = "file2", .kind = .file },
        .{ .name = "file1", .kind = .file },
        .{ .name = "file20", .kind = .file },
    };

    const config = SortConfig{ .version_sort = true };
    sortEntries(&entries, config);

    // Natural sort: file1, file2, file10, file20
    try testing.expectEqualStrings("file1", entries[0].name);
    try testing.expectEqualStrings("file2", entries[1].name);
    try testing.expectEqualStrings("file10", entries[2].name);
    try testing.expectEqualStrings("file20", entries[3].name);
}

test "sorter - version sort mixed" {
    var entries = [_]Entry{
        .{ .name = "v2.0", .kind = .file },
        .{ .name = "v1.10", .kind = .file },
        .{ .name = "v1.2", .kind = .file },
        .{ .name = "v1.1", .kind = .file },
    };

    const config = SortConfig{ .version_sort = true };
    sortEntries(&entries, config);

    // Natural sort: v1.1, v1.2, v1.10, v2.0
    try testing.expectEqualStrings("v1.1", entries[0].name);
    try testing.expectEqualStrings("v1.2", entries[1].name);
    try testing.expectEqualStrings("v1.10", entries[2].name);
    try testing.expectEqualStrings("v2.0", entries[3].name);
}

test "sorter - getExtension" {
    try testing.expectEqualStrings("txt", getExtension("file.txt"));
    try testing.expectEqualStrings("gz", getExtension("archive.tar.gz"));
    try testing.expectEqualStrings("", getExtension("Makefile"));
    try testing.expectEqualStrings("", getExtension(".hidden"));
    try testing.expectEqualStrings("conf", getExtension(".hidden.conf"));
}

test "sorter - versionCompare" {
    // Basic cases
    try testing.expectEqual(std.math.Order.lt, versionCompare("file1", "file2"));
    try testing.expectEqual(std.math.Order.lt, versionCompare("file2", "file10"));
    try testing.expectEqual(std.math.Order.eq, versionCompare("file1", "file1"));
    try testing.expectEqual(std.math.Order.gt, versionCompare("file10", "file2"));

    // Pure alphabetic
    try testing.expectEqual(std.math.Order.lt, versionCompare("abc", "def"));
    try testing.expectEqual(std.math.Order.gt, versionCompare("def", "abc"));
}
