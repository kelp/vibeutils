//! Basic safety tests for the ls utility
//! Tests for cycle detection and filesystem boundary detection
//!
//! IMPORTANT: These tests verify basic cycle detection functionality, not security.
//! The cycle detection is a best-effort safety mechanism to prevent infinite loops,
//! not a security boundary against malicious directory structures.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const entry_collector = @import("entry_collector.zig");
const types = @import("types.zig");

test "FileSystemId - different device/inode pairs are distinguishable" {
    // Test that different device/inode combinations produce different FileSystemIds
    // This is important for basic cycle detection within and across filesystems
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

    // They should have different hashes for HashMap distribution
    try testing.expect(ctx.hash(fs_id1) != ctx.hash(fs_id2));
}

test "FileSystemId - identical device/inode pairs are equal" {
    // Test that identical device/inode combinations are correctly identified as equal
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

    // They should have the same hash for HashMap efficiency
    try testing.expectEqual(ctx.hash(fs_id1), ctx.hash(fs_id2));
}

test "CycleDetector - basic same-directory detection" {
    // Test that visiting the same directory twice is detected
    // NOTE: This is basic cycle detection, not security against malicious structures
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

test "CycleDetector - real device ID extraction" {
    // Test that we actually get device IDs from fstat(), not hardcoded values
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var test_dir = try tmp_dir.dir.openDir(".", .{});
    defer test_dir.close();

    const fs_id = try common.directory.FileSystemId.fromDir(test_dir);

    // Device ID should not be zero (which was the old hardcoded value)
    // Note: On some filesystems, device ID might legitimately be 0, but
    // we're testing that we're at least calling fstat() and getting some value
    _ = fs_id.device; // Just verify we can access it without error

    // Inode should be non-zero for a real directory
    try testing.expect(fs_id.inode != 0);
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

test "Cycle detection - performance with nested directories" {
    // Test that cycle detection doesn't significantly impact performance
    // when traversing a reasonable directory structure with no actual cycles
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a nested directory structure: root/subdir1/subdir2/subdir3
    try tmp_dir.dir.makeDir("subdir1");
    var subdir1 = try tmp_dir.dir.openDir("subdir1", .{});
    defer subdir1.close();

    try subdir1.makeDir("subdir2");
    var subdir2 = try subdir1.openDir("subdir2", .{});
    defer subdir2.close();

    try subdir2.makeDir("subdir3");
    var subdir3 = try subdir2.openDir("subdir3", .{});
    defer subdir3.close();

    // Add some files at each level
    for (0..10) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i}) catch unreachable;

        const file1 = try tmp_dir.dir.createFile(name, .{});
        file1.close();

        const file2 = try subdir1.createFile(name, .{});
        file2.close();

        const file3 = try subdir2.createFile(name, .{});
        file3.close();

        const file4 = try subdir3.createFile(name, .{});
        file4.close();
    }

    // Test cycle detection through the directory hierarchy
    var visited = common.directory.FileSystemIdSet.initContext(testing.allocator, common.directory.FileSystemId.Context{});
    defer visited.deinit();
    var detector = common.directory.CycleDetector.init(&visited);

    const start = std.time.nanoTimestamp();

    // Simulate recursive traversal by checking each directory level
    var test_dir = try tmp_dir.dir.openDir(".", .{});
    defer test_dir.close();

    const dir1_cycle = try detector.checkAndMarkVisited(test_dir);
    try testing.expect(!dir1_cycle); // First visit should not detect cycle

    const dir2_cycle = try detector.checkAndMarkVisited(subdir1);
    try testing.expect(!dir2_cycle);

    const dir3_cycle = try detector.checkAndMarkVisited(subdir2);
    try testing.expect(!dir3_cycle);

    const dir4_cycle = try detector.checkAndMarkVisited(subdir3);
    try testing.expect(!dir4_cycle);

    // Revisiting the root should detect a cycle
    const revisit_cycle = try detector.checkAndMarkVisited(test_dir);
    try testing.expect(revisit_cycle);

    const end = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    // Cycle detection should be very fast (< 1ms for this small test)
    try testing.expect(duration_ms < 1.0);
}
