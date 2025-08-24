//! Core directory listing functionality - shared between main and recursive modules

const std = @import("std");
const common = @import("common");
const types = @import("types.zig");
const entry_collector = @import("entry_collector.zig");
const sorter = @import("sorter.zig");
const formatter = @import("formatter.zig");

const LsOptions = types.LsOptions;
const Entry = types.Entry;

/// Core directory listing logic with cycle detection
/// Collects, sorts, and prints directory entries
pub fn listDirectoryImplWithVisited(dir: std.fs.Dir, path: []const u8, writer: anytype, stderr_writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype, visited_fs_ids: *common.directory.FileSystemIdSet, git_context: ?*types.GitContext) anyerror!void {
    // Collect and prepare entries
    var entries = try collectAndPrepareEntries(allocator, dir, options, git_context, stderr_writer);
    defer entries.deinit(allocator);
    defer entry_collector.freeEntries(entries.items, allocator);

    // Sort entries based on options
    sortEntriesFromOptions(entries.items, options);

    // Print directory listing
    try printDirectoryListing(allocator, entries.items, path, writer, options, style);

    // Process recursive directories
    try processRecursiveDirectories(entries.items, dir, path, writer, stderr_writer, options, allocator, style, visited_fs_ids, git_context);
}

/// Collect and prepare directory entries with metadata
pub fn collectAndPrepareEntries(allocator: std.mem.Allocator, dir: std.fs.Dir, options: LsOptions, git_context: ?*types.GitContext, stderr_writer: anytype) !std.ArrayList(Entry) {
    // Collect and filter entries based on options
    var entries = try entry_collector.collectFilteredEntries(allocator, dir, options);
    errdefer entries.deinit(allocator);
    errdefer entry_collector.freeEntries(entries.items, allocator);

    // Enhance with metadata if needed for sorting or display
    if (entry_collector.needsMetadata(options)) {
        try entry_collector.enhanceEntriesWithMetadata(allocator, entries.items, dir, options, git_context, stderr_writer);
    }

    return entries;
}

/// Sort entries according to the provided options
pub fn sortEntriesFromOptions(entries: []Entry, options: LsOptions) void {
    const sort_config = types.SortConfig{
        .by_time = options.sort_by_time,
        .by_size = options.sort_by_size,
        .dirs_first = options.group_directories_first,
        .reverse = options.reverse_sort,
    };
    sorter.sortEntries(entries, sort_config);
}

/// Print directory listing with header if needed
pub fn printDirectoryListing(allocator: std.mem.Allocator, entries: []Entry, path: []const u8, writer: anytype, options: LsOptions, style: anytype) !void {
    // Print directory header for recursive mode
    if (options.recursive) {
        try writer.print("{s}:\n", .{path});
    }

    // Print entries using the appropriate formatter
    _ = try formatter.printEntries(allocator, entries, writer, options, style);
}

/// Process recursive subdirectories
pub fn processRecursiveDirectories(entries: []const Entry, dir: std.fs.Dir, path: []const u8, writer: anytype, stderr_writer: anytype, options: LsOptions, allocator: std.mem.Allocator, style: anytype, visited_fs_ids: *common.directory.FileSystemIdSet, git_context: ?*types.GitContext) !void {
    if (options.recursive) {
        try entry_collector.processSubdirectoriesRecursively(entries, dir, path, writer, stderr_writer, options, allocator, style, visited_fs_ids, git_context);
    }
}
