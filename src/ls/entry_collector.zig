const std = @import("std");
const common = @import("common");
const types = @import("types.zig");

const Entry = types.Entry;
const LsOptions = types.LsOptions;

/// Collect directory entries with filtering based on options
pub fn collectFilteredEntries(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
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

        const e = Entry{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        };
        errdefer allocator.free(e.name);

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

/// Enhance entries with stat info and symlink targets
pub fn enhanceEntriesWithMetadata(
    entries: []Entry,
    dir: std.fs.Dir,
    options: LsOptions,
    allocator: std.mem.Allocator,
) anyerror!void {
    // Initialize Git repository if Git status is requested
    var git_repo: ?common.git.GitRepo = null;
    if (options.show_git_status) {
        var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = dir.realpath(".", &dir_path_buf) catch ".";
        git_repo = common.git.GitRepo.init(allocator, dir_path) catch null;
    }
    defer if (git_repo) |*repo| repo.deinit();

    for (entries) |*entry| {
        // Get stat info if needed for long format, sorting, file type indicators, colors, or inodes
        if (options.long_format or options.sort_by_time or options.sort_by_size or
            (options.file_type_indicators and entry.kind == .file) or
            options.color_mode != .never or options.show_inodes)
        {
            entry.stat = common.file.FileInfo.lstatDir(dir, entry.name) catch null;
        }

        // Read symlink target if needed
        if (options.long_format and entry.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.readLink(entry.name, &target_buf)) |target| {
                entry.symlink_target = try allocator.dupe(u8, target);
            } else |_| {
                // Failed to read symlink, leave as null
            }
        }

        // Get Git status if requested
        if (options.show_git_status and git_repo != null) {
            entry.git_status = git_repo.?.getFileStatus(entry.name);
        }
    }
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
    visited_inodes: *std.AutoHashMap(u64, void),
) anyerror!void {
    // Collect subdirectories using the common utility
    var subdirs = try common.directory.collectSubdirectories(Entry, entries, base_path, allocator);
    defer {
        common.directory.freeSubdirectoryPaths(subdirs.items, allocator);
        subdirs.deinit();
    }

    // Create cycle detector
    var cycle_detector = common.directory.CycleDetector.init(visited_inodes);

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
            common.printErrorWithProgram(stderr_writer, "ls", "{s}: {}", .{ subdir.path, err });
            continue;
        };
        defer sub_dir.close();

        // Check for cycles
        if (cycle_detector.hasVisited(sub_dir)) {
            common.printErrorWithProgram(stderr_writer, "ls", "{s}: not following symlink cycle", .{subdir.path});
            continue;
        }
        try cycle_detector.markVisited(sub_dir);

        // Recurse using the shared implementation
        try recurseIntoSubdirectory(sub_dir, subdir.path, writer, stderr_writer, options, allocator, style, visited_inodes);
    }
}

/// Wrapper for recursive directory processing to avoid error set inference issues
pub fn recurseIntoSubdirectory(
    sub_dir: std.fs.Dir,
    subdir_path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_inodes: *std.AutoHashMap(u64, void),
) anyerror!void {
    // Forward to main module to avoid circular dependency
    const main = @import("main.zig");
    try main.recurseIntoSubdirectory(sub_dir, subdir_path, writer, stderr_writer, options, allocator, style, visited_inodes);
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

    var entries = try collectFilteredEntries(test_dir, testing.allocator, LsOptions{});
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

    var entries = try collectFilteredEntries(test_dir, testing.allocator, LsOptions{ .all = true });
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
