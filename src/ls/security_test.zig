//! Security tests for the ls utility
//! Tests for cycle detection and TOCTOU prevention

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const entry_collector = @import("entry_collector.zig");
const types = @import("types.zig");

test "FileSystemId - cross-filesystem uniqueness" {
    // Create two FileSystemId instances with different devices
    const fs_id1 = common.directory.FileSystemId{
        .device = 1,
        .inode = 100,
    };

    const fs_id2 = common.directory.FileSystemId{
        .device = 2, // Different device
        .inode = 100, // Same inode
    };

    // They should not be equal even with same inode
    const ctx = common.directory.FileSystemId.Context{};
    try testing.expect(!ctx.eql(fs_id1, fs_id2));

    // They should have different hashes
    try testing.expect(ctx.hash(fs_id1) != ctx.hash(fs_id2));
}

// Test that FileSystemId correctly handles same device, same inode
test "FileSystemId - same filesystem same inode" {
    const fs_id1 = common.directory.FileSystemId{
        .device = 1,
        .inode = 100,
    };

    const fs_id2 = common.directory.FileSystemId{
        .device = 1, // Same device
        .inode = 100, // Same inode
    };

    // They should be equal
    const ctx = common.directory.FileSystemId.Context{};
    try testing.expect(ctx.eql(fs_id1, fs_id2));

    // They should have the same hash
    try testing.expectEqual(ctx.hash(fs_id1), ctx.hash(fs_id2));
}

// Test CycleDetector with FileSystemIdSet
test "CycleDetector - TOCTOU-safe cycle detection" {
    // Create a HashMap for tracking visited filesystem IDs
    var visited = common.directory.FileSystemIdSet.initContext(testing.allocator, common.directory.FileSystemId.Context{});
    defer visited.deinit();

    var detector = common.directory.CycleDetector.init(&visited);

    // Create a temporary directory to test with
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var test_dir = try tmp_dir.dir.openDir(".", .{});
    defer test_dir.close();

    // First visit should return false (not a cycle)
    const first_visit = try detector.checkAndMarkVisited(test_dir);
    try testing.expect(!first_visit);

    // Second visit should return true (cycle detected)
    const second_visit = try detector.checkAndMarkVisited(test_dir);
    try testing.expect(second_visit);
}

// Test that symlink processing handles errors gracefully through the public API
test "Symlink processing - error handling via metadata enhancement" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var test_dir = try tmp_dir.dir.openDir(".", .{});
    defer test_dir.close();

    // Create an entry that appears to be a symlink but doesn't exist as a target
    var entries = [_]types.Entry{
        types.Entry{
            .name = try testing.allocator.dupe(u8, "fake_symlink"),
            .kind = .sym_link,
        },
    };
    defer testing.allocator.free(entries[0].name);

    var error_buffer = std.ArrayList(u8).init(testing.allocator);
    defer error_buffer.deinit();

    // This should handle the error gracefully and not crash
    try entry_collector.enhanceEntriesWithMetadata(testing.allocator, &entries, test_dir, types.LsOptions{ .long_format = true }, // Request symlink target reading
        null, // No git context
        error_buffer.writer());

    // Should complete without crashing (symlink_target will be null)
    try testing.expect(entries[0].symlink_target == null);
}

// Performance test - verify that security fixes don't significantly impact performance
test "Security fixes - performance impact" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a moderate number of files
    for (0..100) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i}) catch unreachable;
        const file = try tmp_dir.dir.createFile(name, .{});
        file.close();
    }

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    // Time the entry collection (should be fast)
    const start = std.time.nanoTimestamp();

    var entries = try entry_collector.collectFilteredEntries(testing.allocator, test_dir, types.LsOptions{});
    defer {
        entry_collector.freeEntries(entries.items, testing.allocator);
        entries.deinit();
    }

    const end = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    // Should complete within reasonable time (100ms for 100 files is generous)
    try testing.expect(duration_ms < 100.0);
    try testing.expect(entries.items.len >= 100);
}
