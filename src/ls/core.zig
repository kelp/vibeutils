//! Core directory listing functionality - shared between main and recursive modules

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const types = @import("types.zig");
const entry_collector = @import("entry_collector.zig");
const sorter = @import("sorter.zig");
const formatter = @import("formatter.zig");

const LsOptions = types.LsOptions;
const Entry = types.Entry;

/// Core directory listing logic with cycle detection
/// Collects, sorts, and prints directory entries
pub fn listDirectoryImplWithVisited(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_fs_ids: *common.directory.FileSystemIdSet,
    git_context: ?*types.GitContext,
) anyerror!void {
    // Every caller supplies a real directory path: ".", a CLI operand, or a
    // base_path + entry.name join from the recursive walk. Never empty.
    std.debug.assert(path.len > 0);
    // Collect and prepare entries
    var entries = try collectAndPrepareEntries(
        io,
        allocator,
        dir,
        options,
        git_context,
        stderr_writer,
    );
    defer entries.deinit(allocator);
    defer entry_collector.freeEntries(entries.items, allocator);

    // The ACL probe takes a path rather than a dirfd, and this frame is the
    // innermost one that still knows the directory's path.
    applyAclMarkers(allocator, entries.items, path, options);

    // Sort entries based on options
    sortEntriesFromOptions(entries.items, options);

    // Print directory listing
    try printDirectoryListing(allocator, entries.items, path, writer, options, style);

    // Process recursive directories
    try processRecursiveDirectories(
        io,
        entries.items,
        dir,
        path,
        writer,
        stderr_writer,
        options,
        allocator,
        style,
        visited_fs_ids,
        git_context,
    );
}

/// Collect and prepare directory entries with metadata
pub fn collectAndPrepareEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    options: LsOptions,
    git_context: ?*types.GitContext,
    stderr_writer: anytype,
) !std.ArrayList(Entry) {
    // Collect and filter entries based on options
    var entries = try entry_collector.collectFilteredEntries(io, allocator, dir, options);
    errdefer entries.deinit(allocator);
    errdefer entry_collector.freeEntries(entries.items, allocator);

    // Enhance with metadata if needed for sorting or display
    if (entry_collector.needsMetadata(options)) {
        try entry_collector.enhanceEntriesWithMetadata(
            io,
            allocator,
            entries.items,
            dir,
            options,
            git_context,
            stderr_writer,
        );
    }

    return entries;
}

/// Mark the entries of one directory listing that carry an ACL, so the
/// formatter can size the section's mode field the way GNU does.
///
/// Skipped outside -l: GNU issues no xattr syscall at all in any other
/// format, and a bare `ls` over a large tree would otherwise pay one probe
/// per entry for a column it never prints.
fn applyAclMarkers(
    allocator: std.mem.Allocator,
    entries: []Entry,
    dir_path: []const u8,
    options: LsOptions,
) void {
    std.debug.assert(dir_path.len > 0);
    std.debug.assert(entries.len <= std.math.maxInt(u32));
    if (!options.long_format) return;

    // The join below supplies its own separator, so "/" must reduce to the
    // empty string rather than pick up a second slash: "//name" is the one
    // form POSIX reserves for an implementation-defined meaning.
    const parent = std.mem.trimEnd(u8, dir_path, "/");

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (entries) |*entry| {
        // An entry we could not stat renders as ten dashes rather than a
        // permission string, so it has no mode field to mark.
        const stat = entry.stat orelse continue;
        // A path too long to join is a path we cannot probe; leaving the
        // entry unmarked loses a column, whereas guessing would invent one.
        const full = std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}",
            .{ parent, entry.name },
        ) catch continue;
        // The stat kind, not the dirent kind: a filesystem that does not fill
        // d_type reports every entry as .unknown, and the probe only looks for
        // a default ACL on a directory, so such a directory would never be
        // marked. This is also the kind the permission string on the same line
        // is rendered from, and the kind the operand path already probes with.
        //
        // -L is what made that stat follow the link, so the probe has to
        // follow it too or the mode and the marker describe different files.
        entry.has_acl = common.file.hasExtendedAcl(
            full,
            stat.kind,
            options.follow_all_symlinks,
        );
        entryAttachAclDump(
            allocator,
            entry,
            full,
            options.follow_all_symlinks,
            options,
        );
    }
}

/// Attach a textual access-ACL dump captured against `path`.
/// `path` is the inode path passed to getxattr — the operand or the
/// parent/name join — never a listing basename that could collide with cwd.
pub fn entryAttachAclDump(
    allocator: std.mem.Allocator,
    entry: *Entry,
    path: []const u8,
    follow: bool,
    options: LsOptions,
) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(entry.acl_dump == null);
    if (!options.show_acls) return;
    if (!entry.has_acl) return;
    entry.acl_dump = common.file.allocAclDump(allocator, path, follow);
}

/// Sort entries according to the provided options
pub fn sortEntriesFromOptions(entries: []Entry, options: LsOptions) void {
    // -f: no sorting at all
    if (options.no_sort) return;

    const sort_config = types.SortConfig{
        .by_time = options.sort_by_time,
        .by_size = options.sort_by_size,
        .dirs_first = options.group_directories_first,
        .reverse = options.reverse_sort,
        .use_atime = options.use_atime,
        .use_ctime = options.use_ctime,
        .by_extension = options.sort_by_extension,
        .version_sort = options.version_sort,
    };
    sorter.sortEntries(entries, sort_config);
}

/// Print directory listing with header if needed
pub fn printDirectoryListing(
    allocator: std.mem.Allocator,
    entries: []Entry,
    path: []const u8,
    writer: anytype,
    options: LsOptions,
    style: anytype,
) !void {
    // Same path invariant as the caller: the recursive header needs a real
    // path, and an empty one is never produced upstream.
    std.debug.assert(path.len > 0);
    // Print directory header for recursive mode
    if (options.recursive) {
        try writer.print("{s}:\n", .{path});
    }

    // Print entries using the appropriate formatter
    _ = try formatter.printEntries(allocator, entries, writer, options, style);
}

/// Process recursive subdirectories
pub fn processRecursiveDirectories(
    io: std.Io,
    entries: []const Entry,
    dir: std.Io.Dir,
    path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_fs_ids: *common.directory.FileSystemIdSet,
    git_context: ?*types.GitContext,
) !void {
    if (options.recursive) {
        try entry_collector.processSubdirectoriesRecursively(
            io,
            entries,
            dir,
            path,
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

/// A POSIX ACL as the Linux VFS stores it: a little-endian u32 version word
/// followed by `{u16 tag, u16 perm, u32 id}` entries. These three -- USER_OBJ
/// rwx, GROUP_OBJ r-x, OTHER r-x -- are the fewest the kernel accepts, and
/// they mirror mode 0o755 exactly, so a directory carrying this as its
/// *default* ACL still renders an unchanged permission string. The `+` is then
/// the only thing telling it apart from a plain directory, which is what makes
/// it the fixture the test below needs.
const minimal_default_acl = [_]u8{
    0x02, 0x00, 0x00, 0x00, // version 2
    0x01, 0x00, 0x07, 0x00, 0xff, 0xff, 0xff, 0xff, // ACL_USER_OBJ  rwx
    0x04, 0x00, 0x05, 0x00, 0xff, 0xff, 0xff, 0xff, // ACL_GROUP_OBJ r-x
    0x20, 0x00, 0x05, 0x00, 0xff, 0xff, 0xff, 0xff, // ACL_OTHER     r-x
};

test "ls: a default ACL is marked when the dirent kind is unknown" {
    // A dirent reports DT_UNKNOWN on a filesystem that does not fill d_type
    // (ext4 built without the filetype feature, various network filesystems).
    // Asking the probe with that kind suppresses the default-ACL lookup, so a
    // directory whose only ACL is a default one never receives its `+`.
    //
    // Linux-only: POSIX ACLs are an xattr here, while Darwin's probe ignores
    // the kind altogether, so there is nothing for this to catch there.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "defaultacl", .default_dir);
    try tmp.dir.createDir(io, "plain", .default_dir);

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir_path = dir_buf[0..dir_len];

    var acl_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const acl_path = try std.fmt.bufPrintZ(&acl_buf, "{s}/defaultacl", .{dir_path});

    // A temp dir on a filesystem mounted without ACL support answers
    // EOPNOTSUPP. Skip with the fixture unbuilt rather than assert against a
    // marker the kernel was never asked to store -- the same way the shell
    // suite probes setfacl before trusting it.
    const set_rc: isize = @bitCast(std.os.linux.setxattr(
        acl_path.ptr,
        "system.posix_acl_default",
        &minimal_default_acl,
        minimal_default_acl.len,
        0,
    ));
    if (set_rc != 0) return error.SkipZigTest;

    // Exactly the shape entry_collector leaves behind on such a filesystem:
    // the dirent kind is unknown, the stat standing behind it is not. The
    // permission string is rendered from that stat, so the marker must be too.
    const alloc = std.testing.allocator;
    var entries = [_]Entry{
        .{
            .name = "defaultacl",
            .kind = .unknown,
            .stat = try common.file.FileInfo.lstatDir(alloc, tmp.dir, "defaultacl"),
        },
        .{
            .name = "plain",
            .kind = .unknown,
            .stat = try common.file.FileInfo.lstatDir(alloc, tmp.dir, "plain"),
        },
    };

    applyAclMarkers(alloc, &entries, dir_path, .{ .long_format = true });

    try std.testing.expect(entries[0].has_acl);
    // Negative space: the marker has to come from the probe answering yes,
    // not from an entry merely having been visited.
    try std.testing.expect(!entries[1].has_acl);
}
