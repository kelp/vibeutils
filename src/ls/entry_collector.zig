const std = @import("std");
const common = @import("common");
const types = @import("types.zig");

const Entry = types.Entry;
const LsOptions = types.LsOptions;

/// Collect directory entries with filtering
pub fn collectFilteredEntries(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    options: LsOptions,
) anyerror!std.ArrayList(Entry) {
    var entries = std.ArrayList(Entry).init(allocator);
    errdefer {
        // Clean up any entries allocated so far
        for (entries.items) |entry| {
            allocator.free(entry.name);
            if (entry.symlink_target) |target| {
                allocator.free(target);
            }
        }
        entries.deinit();
    }

    // Create filter based on options
    const filter = common.directory.EntryFilter{
        .show_hidden = options.all or options.almost_all,
        .show_all = options.all,
        .skip_dots = options.almost_all,
    };

    // Collect entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Apply filtering
        if (!filter.shouldInclude(entry.name)) {
            continue;
        }

        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);

        const e = Entry{
            .name = name_copy,
            .kind = entry.kind,
        };

        try entries.append(e);
    }

    return entries;
}

/// Check if entries need metadata enhancement
pub fn needsMetadata(options: LsOptions) bool {
    return options.long_format or options.sort_by_time or options.sort_by_size or
        options.file_type_indicators or options.color_mode != .never or options.show_inodes or
        options.show_git_status;
}

/// Simplified symlink reading that trusts OS readLink syscall completely
fn readSymlinkSafely(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, stderr_writer: anytype) !?[]u8 {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    const target = dir.readLink(name, &target_buf) catch |err| switch (err) {
        error.NotLink => return null,
        // For all other errors, use OS error message directly - no custom categories
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "ls", "symlink {s}: {s}", .{ name, @errorName(err) });
            return null; // Continue processing other entries rather than failing completely
        },
    };

    // Trust OS completely - no post-readLink validation needed
    return try allocator.dupe(u8, target);
}

/// Batch metadata processing for improved performance
pub fn enhanceEntriesWithMetadataBatch(
    allocator: std.mem.Allocator,
    entries: []Entry,
    dir: std.fs.Dir,
    options: LsOptions,
    git_context: ?*types.GitContext,
    stderr_writer: anytype,
) anyerror!void {
    if (entries.len == 0) return;

    // Use temporary arena for intermediate operations
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_allocator = temp_arena.allocator();

    // Determine what metadata we need
    const needs_stat = options.long_format or options.sort_by_time or options.sort_by_size or
        (options.file_type_indicators) or options.color_mode != .never or options.show_inodes;
    const needs_symlink = options.long_format;
    const needs_git = options.show_git_status and git_context != null;

    // Create batches of entries by operation type
    var stat_indices = std.ArrayList(usize).init(temp_allocator);
    var symlink_indices = std.ArrayList(usize).init(temp_allocator);
    var git_indices = std.ArrayList(usize).init(temp_allocator);

    // Group entries by required operations
    for (entries, 0..) |entry, i| {
        if (needs_stat) {
            try stat_indices.append(i);
        }
        if (needs_symlink and entry.kind == .sym_link) {
            try symlink_indices.append(i);
        }
        if (needs_git) {
            try git_indices.append(i);
        }
    }

    // Batch process stat operations
    if (stat_indices.items.len > 0) {
        for (stat_indices.items) |i| {
            entries[i].stat = common.file.FileInfo.lstatDir(allocator, dir, entries[i].name) catch null;
        }
    }

    // Batch process symlink operations
    if (symlink_indices.items.len > 0) {
        for (symlink_indices.items) |i| {
            entries[i].symlink_target = readSymlinkSafely(allocator, dir, entries[i].name, stderr_writer) catch null;
        }
    }

    // Batch process git operations
    if (needs_git and git_context != null) {
        for (git_indices.items) |i| {
            entries[i].git_status = git_context.?.getFileStatus(entries[i].name) orelse .not_in_repo;
        }
    }
}

/// Enhance entries with stat info and symlink targets (legacy function for compatibility)
pub fn enhanceEntriesWithMetadata(
    allocator: std.mem.Allocator,
    entries: []Entry,
    dir: std.fs.Dir,
    options: LsOptions,
    git_context: ?*types.GitContext,
    stderr_writer: anytype,
) anyerror!void {
    // Delegate to the more efficient batch implementation
    return enhanceEntriesWithMetadataBatch(allocator, entries, dir, options, git_context, stderr_writer);
}

/// Process subdirectories recursively
pub fn processSubdirectoriesRecursively(
    entries: []const Entry,
    dir: std.fs.Dir,
    base_path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_fs_ids: *common.directory.FileSystemIdSet,
    git_context: ?*types.GitContext,
) anyerror!void {
    // Collect subdirectories using the common utility
    var subdirs = try common.directory.collectSubdirectories(Entry, entries, base_path, allocator);
    defer {
        common.directory.freeSubdirectoryPaths(subdirs.items, allocator);
        subdirs.deinit();
    }

    // Create cycle detector
    var cycle_detector = common.directory.CycleDetector.init(visited_fs_ids);

    // Recurse into subdirectories
    for (subdirs.items) |subdir| {
        // Print separator and header
        writer.writeAll("\n") catch |err| {
            if (err == error.BrokenPipe) return; // Exit gracefully on pipe close
            return err;
        };
        writer.print("{s}:\n", .{subdir.path}) catch |err| {
            if (err == error.BrokenPipe) return; // Exit gracefully on pipe close
            return err;
        };

        // Open the subdirectory relative to the current directory
        var sub_dir = dir.openDir(subdir.name, .{ .iterate = true }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "ls", "{s}: {}", .{ subdir.path, err });
            continue;
        };
        defer sub_dir.close();

        // Atomically check for cycles and mark as visited (TOCTOU-safe)
        const is_cycle = cycle_detector.checkAndMarkVisited(sub_dir) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "ls", "{s}: unable to check for cycles: {}", .{ subdir.path, err });
            continue;
        };

        if (is_cycle) {
            common.printErrorWithProgram(allocator, stderr_writer, "ls", "{s}: not following symlink cycle", .{subdir.path});
            continue;
        }

        // Recurse using the recursive module implementation
        const recursive = @import("recursive.zig");
        try recursive.recurseIntoSubdirectory(sub_dir, subdir.path, writer, stderr_writer, options, allocator, style, visited_fs_ids, git_context);
    }
}

/// Free allocated memory for entries
pub fn freeEntries(entries: []Entry, allocator: std.mem.Allocator) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        if (entry.symlink_target) |target| {
            allocator.free(target);
        }
    }
}

// Tests
const testing = std.testing;

test "entry_collector - needsMetadata" {
    // Basic options with color_mode=never should not need metadata
    const basic_options = LsOptions{ .color_mode = .never };
    try testing.expect(!needsMetadata(basic_options));

    // Long format needs metadata
    const long_options = LsOptions{ .long_format = true };
    try testing.expect(needsMetadata(long_options));

    // Color mode needs metadata
    const color_options = LsOptions{ .color_mode = .always };
    try testing.expect(needsMetadata(color_options));

    // Time sorting needs metadata
    const time_options = LsOptions{ .sort_by_time = true };
    try testing.expect(needsMetadata(time_options));

    // Size sorting needs metadata
    const size_options = LsOptions{ .sort_by_size = true };
    try testing.expect(needsMetadata(size_options));

    // Inodes need metadata
    const inode_options = LsOptions{ .show_inodes = true };
    try testing.expect(needsMetadata(inode_options));

    // Git status needs metadata
    const git_options = LsOptions{ .show_git_status = true };
    try testing.expect(needsMetadata(git_options));
}

test "entry_collector - collectFilteredEntries basic" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("visible.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile(".hidden", .{});
    file2.close();

    // Test without showing hidden files
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    var entries = try collectFilteredEntries(testing.allocator, test_dir, LsOptions{});
    defer {
        freeEntries(entries.items, testing.allocator);
        entries.deinit();
    }

    // Should only contain visible file
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("visible.txt", entries.items[0].name);
}

test "entry_collector - collectFilteredEntries with all option" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("visible.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile(".hidden", .{});
    file2.close();

    // Test with showing all files
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    var entries = try collectFilteredEntries(testing.allocator, test_dir, LsOptions{ .all = true });
    defer {
        freeEntries(entries.items, testing.allocator);
        entries.deinit();
    }

    // Should contain both files (note: . and .. might also be included depending on filesystem)
    try testing.expect(entries.items.len >= 2);

    // Check that both files are present
    var found_visible = false;
    var found_hidden = false;
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, "visible.txt")) found_visible = true;
        if (std.mem.eql(u8, entry.name, ".hidden")) found_hidden = true;
    }
    try testing.expect(found_visible);
    try testing.expect(found_hidden);
}
