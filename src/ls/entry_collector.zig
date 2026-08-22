const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const glob = common.glob;
const types = @import("types.zig");

const Entry = types.Entry;
const LsOptions = types.LsOptions;

/// Collect directory entries with filtering
pub fn collectFilteredEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    options: LsOptions,
) anyerror!std.ArrayList(Entry) {
    var entries = try std.ArrayList(Entry).initCapacity(allocator, 0);
    errdefer {
        // Clean up any entries allocated so far
        for (entries.items) |entry| {
            allocator.free(entry.name);
            if (entry.symlink_target) |target| {
                allocator.free(target);
            }
        }
        entries.deinit(allocator);
    }

    // Create filter based on options
    const filter = common.directory.EntryFilter{
        .show_hidden = options.all or options.almost_all,
        .show_all = options.all,
        .skip_dots = options.almost_all,
    };

    // When -a (show_all) is set and -A (almost_all) is not,
    // GNU ls includes "." and ".." as the first two entries.
    // The directory iterator doesn't yield these, so add them manually.
    if (options.all and !options.almost_all) {
        try collectFilteredEntries_appendDotEntries(allocator, &entries);
    }

    // Collect entries
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (collectFilteredEntries_shouldSkip(filter, options, entry.name)) {
            continue;
        }

        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);

        const e = Entry{
            .name = name_copy,
            .kind = entry.kind,
        };

        try entries.append(allocator, e);
    }

    return entries;
}

/// Append the "." and ".." directory entries (for -a without -A).
fn collectFilteredEntries_appendDotEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
) !void {
    std.debug.assert(entries.items.len == 0);
    const dot = try allocator.dupe(u8, ".");
    errdefer allocator.free(dot);
    try entries.append(allocator, Entry{
        .name = dot,
        .kind = .directory,
    });

    const dotdot = try allocator.dupe(u8, "..");
    errdefer allocator.free(dotdot);
    try entries.append(allocator, Entry{
        .name = dotdot,
        .kind = .directory,
    });
}

/// Decide whether a directory entry should be skipped during collection.
/// Replicates the original short-circuit order: include filter, then -B
/// backup suffix, then -I glob pattern.
fn collectFilteredEntries_shouldSkip(
    filter: common.directory.EntryFilter,
    options: LsOptions,
    name: []const u8,
) bool {
    std.debug.assert(name.len > 0);
    // Apply filtering
    if (!filter.shouldInclude(name)) return true;

    // -B: skip backup files ending with ~
    if (options.hide_backups and name.len > 0 and name[name.len - 1] == '~') return true;

    // -I PATTERN: skip entries matching glob pattern
    if (options.ignore_pattern) |pattern| {
        if (glob.globMatch(pattern, name)) return true;
    }

    return false;
}

/// Check if entries need metadata enhancement
pub fn needsMetadata(options: LsOptions) bool {
    return options.long_format or options.sort_by_time or options.sort_by_size or
        options.file_type_indicators or options.show_inodes or
        options.show_git_status or options.show_blocks or options.use_atime or
        options.ls_colors != null;
}

/// Simplified symlink reading that trusts OS readLink syscall completely
fn readSymlinkSafely(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    stderr_writer: anytype,
) !?[]u8 {
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const target_len = dir.readLink(io, name, &target_buf) catch |err| switch (err) {
        error.NotLink => return null,
        // For all other errors, use OS error message directly - no custom categories
        else => {
            // GNU ls quotes the operand here (file_failure + quoteaf,
            // "cannot read symbolic link 'x': reason"); match placement.
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "ls",
                "symlink '{s}': {s}",
                .{ name, common.posixErrorString(err) },
            );
            return null; // Continue processing other entries rather than failing completely
        },
    };

    // Trust OS completely - no post-readLink validation needed
    return try allocator.dupe(u8, target_buf[0..target_len]);
}

/// Enhance entries with stat info, symlink targets, and git status
pub fn enhanceEntriesWithMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: []Entry,
    dir: std.Io.Dir,
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
        options.file_type_indicators or options.show_inodes or
        options.show_blocks or options.use_atime or options.ls_colors != null;
    const needs_symlink = options.long_format and !options.follow_all_symlinks;
    const needs_git = options.show_git_status and git_context != null;

    // Create batches of entries by operation type
    var stat_indices = try std.ArrayList(usize).initCapacity(temp_allocator, 0);
    var symlink_indices = try std.ArrayList(usize).initCapacity(temp_allocator, 0);
    var git_indices = try std.ArrayList(usize).initCapacity(temp_allocator, 0);

    // Group entries by required operations
    for (entries, 0..) |entry, i| {
        if (needs_stat) {
            try stat_indices.append(temp_allocator, i);
        }
        if (needs_symlink and entry.kind == .sym_link) {
            try symlink_indices.append(temp_allocator, i);
        }
        if (needs_git) {
            try git_indices.append(temp_allocator, i);
        }
    }

    // Batch process stat operations
    if (stat_indices.items.len > 0) {
        applyStatMetadata(allocator, entries, dir, stat_indices.items, options);
    }

    // Batch process symlink operations
    if (symlink_indices.items.len > 0) {
        for (symlink_indices.items) |i| {
            entries[i].symlink_target = readSymlinkSafely(
                io,
                allocator,
                dir,
                entries[i].name,
                stderr_writer,
            ) catch null;
        }
    }

    // Batch process git operations
    if (needs_git and git_context != null) {
        for (git_indices.items) |i| {
            entries[i].git_status =
                git_context.?.getFileStatus(io, entries[i].name) orelse .not_in_repo;
        }
    }
}

/// Populate stat metadata for the given entry indices.
fn applyStatMetadata(
    allocator: std.mem.Allocator,
    entries: []Entry,
    dir: std.Io.Dir,
    stat_indices: []const usize, // tiger:allow:usize-arch slice indices are usize
    options: LsOptions,
) void {
    for (stat_indices) |i| {
        if (options.follow_all_symlinks) {
            // -L: follow symlinks, show target file info
            entries[i].stat = common.file.FileInfo.statDir(
                allocator,
                dir,
                entries[i].name,
            ) catch null;
            // Update entry kind to match the stat result
            if (entries[i].stat) |stat| {
                entries[i].kind = stat.kind;
            }
        } else {
            entries[i].stat = common.file.FileInfo.lstatDir(
                allocator,
                dir,
                entries[i].name,
            ) catch null;
        }
    }
}

/// Process subdirectories recursively
pub fn processSubdirectoriesRecursively(
    io: std.Io,
    entries: []const Entry,
    dir: std.Io.Dir,
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
        subdirs.deinit(allocator);
    }

    // Create cycle detector
    var cycle_detector = common.directory.CycleDetector.init(visited_fs_ids);

    // Recurse into subdirectories
    for (subdirs.items) |subdir| {
        // Print blank-line separator between directory listings.
        // The header itself ({path}:\n) is emitted by printDirectoryListing
        // in core.zig, so printing it here too would produce duplicates
        // (audit finding G13).
        writer.writeAll("\n") catch |err| {
            if (err == error.BrokenPipe) return; // Exit gracefully on pipe close
            return err;
        };

        // Open the subdirectory and check for cycles; null means skip it.
        var sub_dir = openSubdirChecked(
            io,
            dir,
            subdir,
            &cycle_detector,
            allocator,
            stderr_writer,
        ) orelse continue;
        defer sub_dir.close(io);

        // Recurse using the recursive module implementation
        const recursive = @import("recursive.zig");
        try recursive.recurseIntoSubdirectory(
            io,
            sub_dir,
            subdir.path,
            writer,
            stderr_writer,
            options,
            allocator,
            style,
            visited_fs_ids,
            git_context,
        );
    }
}

/// Open a subdirectory and verify it is not a symlink cycle.
/// Returns the open directory, or null (after printing an error) when the
/// caller should skip this entry. The caller owns closing the result.
fn openSubdirChecked(
    io: std.Io,
    dir: std.Io.Dir,
    subdir: common.directory.SubdirEntry,
    cycle_detector: *common.directory.CycleDetector,
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
) ?std.Io.Dir {
    // Open the subdirectory relative to the current directory.
    // GNU ls quotes the operand here (file_failure + quoteaf,
    // "cannot open directory 'x': reason"); match placement.
    var sub_dir = dir.openDir(io, subdir.name, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "'{s}': {}",
            .{ subdir.path, err },
        );
        return null;
    };

    // Atomically check for cycles and mark as visited (TOCTOU-safe).
    // GNU ls quotes the operand here too (file_failure + quoteaf,
    // "cannot determine device and inode of 'x': reason").
    const is_cycle = cycle_detector.checkAndMarkVisited(sub_dir) catch |err| {
        sub_dir.close(io);
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "'{s}': unable to check for cycles: {}",
            .{ subdir.path, err },
        );
        return null;
    };

    if (is_cycle) {
        sub_dir.close(io);
        // GNU ls prints this operand unquoted here (error(0,0,...) with
        // quotef, not quoteaf — "not listing already-listed directory");
        // keep parity.
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "ls",
            "{s}: not following symlink cycle",
            .{subdir.path},
        );
        return null;
    }

    return sub_dir;
}

/// Free allocated memory for entries
pub fn freeEntries(entries: []Entry, allocator: std.mem.Allocator) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        if (entry.symlink_target) |target| {
            allocator.free(target);
        }
        if (entry.acl_dump) |dump| {
            allocator.free(dump);
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

    // Color mode alone no longer needs metadata (fast by default)
    const color_options = LsOptions{ .color_mode = .always };
    try testing.expect(!needsMetadata(color_options));

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

    // Block display needs metadata
    const blocks_options = LsOptions{ .show_blocks = true };
    try testing.expect(needsMetadata(blocks_options));

    // Access time needs metadata
    const atime_options = LsOptions{ .use_atime = true };
    try testing.expect(needsMetadata(atime_options));
}

test "entry_collector - collectFilteredEntries basic" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create test files
    const file1 = try tmp_dir.dir().createFile(testing.io, "visible.txt", .{});
    file1.close(testing.io);
    const file2 = try tmp_dir.dir().createFile(testing.io, ".hidden", .{});
    file2.close(testing.io);

    // Test without showing hidden files
    var test_dir = try tmp_dir.dir().openDir(testing.io, ".", .{ .iterate = true });
    defer test_dir.close(testing.io);

    var entries = try collectFilteredEntries(testing.io, testing.allocator, test_dir, LsOptions{});
    defer {
        freeEntries(entries.items, testing.allocator);
        entries.deinit(testing.allocator);
    }

    // Should only contain visible file
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("visible.txt", entries.items[0].name);
}

test "entry_collector - collectFilteredEntries with all option" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    // Create test files
    const file1 = try tmp_dir.dir().createFile(testing.io, "visible.txt", .{});
    file1.close(testing.io);
    const file2 = try tmp_dir.dir().createFile(testing.io, ".hidden", .{});
    file2.close(testing.io);

    // Test with showing all files
    var test_dir = try tmp_dir.dir().openDir(testing.io, ".", .{ .iterate = true });
    defer test_dir.close(testing.io);

    var entries = try collectFilteredEntries(
        testing.io,
        testing.allocator,
        test_dir,
        LsOptions{ .all = true },
    );
    defer {
        freeEntries(entries.items, testing.allocator);
        entries.deinit(testing.allocator);
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

test "entry_collector - hide_backups filters tilde files" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const f1 = try tmp_dir.dir().createFile(testing.io, "file.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp_dir.dir().createFile(testing.io, "file.txt~", .{});
    f2.close(testing.io);
    const f3 = try tmp_dir.dir().createFile(testing.io, "backup~", .{});
    f3.close(testing.io);

    var test_dir = try tmp_dir.dir().openDir(testing.io, ".", .{ .iterate = true });
    defer test_dir.close(testing.io);

    var entries = try collectFilteredEntries(
        testing.io,
        testing.allocator,
        test_dir,
        LsOptions{ .hide_backups = true },
    );
    defer {
        freeEntries(entries.items, testing.allocator);
        entries.deinit(testing.allocator);
    }

    // Should only contain file.txt, not the ~ files
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("file.txt", entries.items[0].name);
}

test "entry_collector - ignore_pattern filters matching files" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const f1 = try tmp_dir.dir().createFile(testing.io, "readme.md", .{});
    f1.close(testing.io);
    const f2 = try tmp_dir.dir().createFile(testing.io, "main.c", .{});
    f2.close(testing.io);
    const f3 = try tmp_dir.dir().createFile(testing.io, "test.c", .{});
    f3.close(testing.io);
    const f4 = try tmp_dir.dir().createFile(testing.io, "notes.txt", .{});
    f4.close(testing.io);

    var test_dir = try tmp_dir.dir().openDir(testing.io, ".", .{ .iterate = true });
    defer test_dir.close(testing.io);

    var entries = try collectFilteredEntries(
        testing.io,
        testing.allocator,
        test_dir,
        LsOptions{ .ignore_pattern = "*.c" },
    );
    defer {
        freeEntries(entries.items, testing.allocator);
        entries.deinit(testing.allocator);
    }

    // Should not contain .c files
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    for (entries.items) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".c"));
    }
}
