/// Bounded iterative directory walker for vibeutils.
///
/// Replaces direct recursion in cp, mv, chmod, chown, rm, du, grep, find.
/// Uses an explicit stack of directory frames so max_depth is assertable
/// at every push — Tiger Style "every loop must have a fixed upper bound."
///
/// Design contract: docs/tiger-style-review/walker-design.md
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const directory = @import("directory.zig");

// ============================================================================
// Public Types
// ============================================================================

/// How symlinks encountered during the walk are treated.
pub const SymlinkPolicy = enum {
    /// -P: never follow. Symlinks emitted as `.sym_link` entries; never descended.
    no_follow,
    /// -H: follow only at depth 0 (command-line operands).
    follow_cmdline,
    /// -L: follow all symlinks; cycle detector becomes mandatory.
    follow_all,
};

/// Which order entries are emitted in.
/// `both` emits a directory twice: once pre-order, once post-order.
pub const Order = enum { pre, post, both };

/// Configuration for a Walker instance.
pub const WalkConfig = struct {
    /// Hard upper bound on stack depth. When reached, next() returns
    /// error.DepthLimitExceeded. Default 1024 — POSIX PATH_MAX gives ~256
    /// components; real filesystems almost never exceed ~50.
    max_depth: u16 = 1024,

    /// Hard upper bound on total entries emitted before the walk forcibly
    /// halts. When reached, next() returns error.EntryLimitExceeded.
    /// Default 16 Mi.
    max_entries: u64 = 1 << 24,

    /// Symlink follow policy.
    symlinks: SymlinkPolicy = .no_follow,

    /// Emit each directory pre-order, post-order, or both.
    order: Order = .pre,

    /// When true, stop descending at filesystem boundaries (du -x,
    /// find -xdev, rm -x, chown -x). Root device is captured at init.
    stay_on_filesystem: bool = false,

    /// When true, sort each directory's children by name before emitting.
    /// Used by find with --sorted; comes at the cost of an allocation per
    /// directory. Default false.
    sort_children: bool = false,

    /// When true, install a CycleDetector. Mandatory when
    /// `symlinks == .follow_all`. Strongly recommended for any walk that
    /// could traverse a symlinked subtree.
    detect_cycles: bool = true,

    /// When true, skip "." and ".." entries (always true in practice;
    /// kept as flag because stdlib iterators differ on this).
    skip_dot_entries: bool = true,
};

/// Lightweight stat snapshot to avoid forcing every caller to redo work
/// the walker already did. Kept inline to avoid circular dep with common.file.
pub const Stat = struct {
    dev: u64,
    inode: u64,
    mode: u32,
    nlink: u64,
    size: i64,
    blocks: i64,
    uid: u32,
    gid: u32,
    atime: i128,
    mtime: i128,
    ctime: i128,
    kind: std.Io.File.Kind,
};

/// A single entry emitted by the walker during traversal.
pub const Entry = struct {
    /// Full path from the original root. Owned by the walker; valid until
    /// the next `next()` call. Callers must `dupe` if they need to retain.
    path: []const u8,

    /// Basename within the parent directory. Slice into `path`; same lifetime.
    basename: []const u8,

    /// File kind, resolved via lstat (no_follow) or stat (follow_*) per policy.
    kind: std.Io.File.Kind,

    /// Depth from the walk root. Root operand is depth 0.
    depth: u16,

    /// Pre- or post-order visit. For non-directories always .pre.
    /// For directories with order=.both, the walker emits .pre on descent
    /// and .post on unwind.
    visit: enum { pre, post },

    /// Cached stat result, populated when the walker had to stat the entry
    /// to decide whether to descend or to honor stay_on_filesystem.
    /// Callers should use this rather than re-stat'ing.
    stat: ?Stat,

    /// Handle to the parent directory, valid until the next `next()`.
    /// Enables openat-style operations (e.g. chmod via fd, du via fstatat).
    /// Null only at depth 0 (the root operands have no parent in the walk).
    parent_dir: ?std.Io.Dir,
};

// ============================================================================
// Private Types
// ============================================================================

/// A single in-progress directory frame on the traversal stack.
const Frame = struct {
    /// Owned: closed when popped.
    dir: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
    depth: u16,
    /// For trimming path_buf on pop.
    path_len_on_entry: usize,
    /// Emit this dir post-order on unwind?
    pending_post: bool,
    /// Which root this descended from.
    root_index: u32,
};

/// A root path queued for traversal.
const RootSpec = struct {
    /// Owned by allocator.
    path: []const u8,
    /// Resolved -H/-L command-line logic.
    follow_initial: bool,
};

// ============================================================================
// Walker
// ============================================================================

/// Iterative bounded directory walker.
///
/// Usage:
///   var w = try Walker.init(allocator, config);
///   defer w.deinit(io);
///   try w.addRoot("/some/path");
///   while (try w.next(io)) |entry| { ... }
pub const Walker = struct {
    allocator: std.mem.Allocator,
    config: WalkConfig,

    /// Explicit stack of in-progress directory frames. Never exceeds
    /// config.max_depth — error returned on every push attempt past the cap.
    stack: std.ArrayListUnmanaged(Frame),

    /// Cycle detector (dev, inode). Initialized iff config.detect_cycles.
    visited: ?directory.FileSystemIdSet,

    /// Root operand queue. The walker drains this before declaring done.
    roots: std.ArrayListUnmanaged(RootSpec),

    /// Device of the *current* root, for stay_on_filesystem. Re-captured per root.
    current_root_dev: ?u64,

    /// Scratch buffer for the path of the currently-emitted entry.
    /// Reused across calls to avoid allocator churn.
    path_buf: std.ArrayListUnmanaged(u8),

    /// Running total of entries emitted. Bounds-checked against
    /// config.max_entries on every `next()`.
    entries_emitted: u64,

    /// When pruneCurrent() is called, the walker sets this flag so the
    /// next next() call knows not to descend into the last emitted dir.
    prune_current: bool,

    // -----------------------------------------------------------------------
    // Public lifecycle methods
    // -----------------------------------------------------------------------

    /// Initialize an empty walker. Add roots with `addRoot`, then drive
    /// with `next`. Must be paired with `deinit`.
    pub fn init(
        allocator: std.mem.Allocator,
        config: WalkConfig,
    ) error{OutOfMemory}!Walker {
        _ = config;
        return Walker{
            .allocator = allocator,
            .config = .{},
            .stack = .empty,
            .visited = null,
            .roots = .empty,
            .current_root_dev = null,
            .path_buf = .empty,
            .entries_emitted = 0,
            .prune_current = false,
        };
    }

    /// Add a root path to walk. May be called multiple times before or
    /// between `next()` calls. Each root is processed in insertion order.
    pub fn addRoot(self: *Walker, path: []const u8) error{OutOfMemory}!void {
        _ = self;
        _ = path;
    }

    /// Advance to the next entry. Returns null when the walk is complete.
    /// Errors are per-entry: I/O errors surface here. After an error,
    /// `next()` may be called again — the walker stays re-entrant.
    /// Returns error.DepthLimitExceeded when config.max_depth is reached.
    /// Returns error.EntryLimitExceeded when config.max_entries is reached.
    pub fn next(self: *Walker, io: std.Io) !?Entry {
        _ = self;
        _ = io;
        return null;
    }

    /// Tell the walker not to descend into the most recently emitted entry,
    /// if it was a directory in pre-order. No-op otherwise.
    pub fn pruneCurrent(self: *Walker) void {
        _ = self;
    }

    /// Free all owned memory; close all open Dir handles still on the stack.
    /// Safe to call multiple times. Must be called even if `next` errored.
    pub fn deinit(self: *Walker, io: std.Io) void {
        _ = self;
        _ = io;
    }

    // -----------------------------------------------------------------------
    // Private helpers (stubs — real logic belongs in the implementer's pass)
    // -----------------------------------------------------------------------

    /// Pop the top frame from the stack, close its dir handle, and restore
    /// path_buf to its pre-descent length.
    fn popFrame(self: *Walker, io: std.Io) void {
        _ = self;
        _ = io;
    }

    /// Push a new directory frame onto the stack, asserting depth < max_depth.
    fn descendInto(
        self: *Walker,
        io: std.Io,
        parent_path_len: usize,
        dir: std.Io.Dir,
        depth: u16,
        root_index: u32,
        pending_post: bool,
    ) error{OutOfMemory}!void {
        _ = self;
        _ = io;
        _ = parent_path_len;
        _ = dir;
        _ = depth;
        _ = root_index;
        _ = pending_post;
    }

    /// Drive one step of the walk: advance the top frame's iterator or pop it.
    fn nextFromStack(self: *Walker, io: std.Io) !?Entry {
        _ = self;
        _ = io;
        return null;
    }
};

// ============================================================================
// Test Helpers
// ============================================================================

/// Build a real path string for a file under tmp_dir.
/// Caller owns the returned slice (allocated with `allocator`).
fn tmpPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_dir: *testing.TmpDir,
    sub_path: []const u8,
) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPath(io, &buf);
    const base = buf[0..n];
    if (sub_path.len == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, sub_path });
}

/// Create a flat file inside a dir.
fn createFile(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    const f = try dir.createFile(io, name, .{});
    f.close(io);
}

/// Describes a single node in a tree fixture.
pub const TreePath = struct {
    path: []const u8,
    kind: enum { file, dir, symlink },
    /// Only used when kind == .symlink.
    symlink_target: []const u8 = "",
};

/// Build a tree described as a flat list of (path, kind) pairs.
/// Each path is relative to `dir`. Intermediate directories are created
/// automatically, so "a/b/c.txt" creates "a", "a/b", then "a/b/c.txt".
fn buildTree(io: std.Io, dir: std.Io.Dir, paths: []const TreePath) !void {
    for (paths) |tp| {
        switch (tp.kind) {
            .file => try createFile(io, dir, tp.path),
            .dir => try dir.createDirPath(io, tp.path),
            .symlink => try dir.symLink(io, tp.symlink_target, tp.path, .{}),
        }
    }
}

/// Collect all entries from a walker. Returns a list of owned Entry copies
/// (path duped, basename duped into path_buf). Caller frees via deinit.
///
/// This variant collects full Entry structs rather than just paths, so tests
/// can check kind, depth, and visit fields.
fn drainEntries(
    walker: *Walker,
    io: std.Io,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Entry),
) !void {
    while (try walker.next(io)) |entry| {
        // Dupe the path so it outlives the walker's internal path_buf.
        const path_copy = try allocator.dupe(u8, entry.path);
        var copy = entry;
        copy.path = path_copy;
        // basename is a slice into path; repoint it into path_copy.
        const offset = @intFromPtr(entry.basename.ptr) - @intFromPtr(entry.path.ptr);
        copy.basename = path_copy[offset .. offset + entry.basename.len];
        try out.append(allocator, copy);
    }
}

/// Collect all entry paths from a walker into a list.
/// Returns the count of entries emitted.
fn drainWalker(
    walker: *Walker,
    io: std.Io,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
) !u32 {
    var count: u32 = 0;
    while (try walker.next(io)) |entry| {
        try out.append(allocator, try allocator.dupe(u8, entry.path));
        count += 1;
    }
    return count;
}

/// Return the index of the first entry whose path ends with `suffix`, or null.
fn indexOfEntry(entries: []const Entry, suffix: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.endsWith(u8, e.path, suffix)) return i;
    }
    return null;
}

// ============================================================================
// Tests — §5.1 Walker unit tests
// ============================================================================

test "walker: empty directory emits nothing after the root" {
    // §5.1 #1: Walk an empty directory. The walker DOES emit the root as its
    // first pre-order entry (depth=0, kind=.directory, visit=.pre), then
    // terminates with null because there are no children.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var w = try Walker.init(testing.allocator, .{});
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    // The root itself must be emitted first (depth=0, directory, pre).
    const first = try w.next(io);
    try testing.expect(first != null); // RED: stub returns null.
    try testing.expectEqual(@as(u16, 0), first.?.depth);
    try testing.expectEqual(std.Io.File.Kind.directory, first.?.kind);
    try testing.expectEqual(.pre, first.?.visit);

    // For .pre order, no more entries (directory is empty).
    const second = try w.next(io);
    try testing.expect(second == null);
}

test "walker: pre-order ordering emits parent before children" {
    // §5.1 #2: Pre-order must emit a directory before its contents.
    // Tree: root/ -> a/ -> x.txt
    // Expected order (by suffix): root_dir, then "a", then "a/x.txt".
    // We verify parent index < child index.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "a", .kind = .dir },
        .{ .path = "a/x.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.path);
        entries.deinit(testing.allocator);
    }
    try drainEntries(&w, io, testing.allocator, &entries);

    // Must emit at least root, "a", and "a/x.txt". RED: stub emits 0.
    try testing.expect(entries.items.len >= 3);

    const idx_a = indexOfEntry(entries.items, "/a");
    const idx_x = indexOfEntry(entries.items, "a/x.txt");
    try testing.expect(idx_a != null and idx_x != null);
    // Parent "a" must appear before child "a/x.txt".
    try testing.expect(idx_a.? < idx_x.?);
}

test "walker: post-order ordering emits children before parent directory" {
    // §5.1 #3: Post-order must emit children before their containing directory.
    // Tree: root/ -> d/ -> file.txt
    // In post order: file.txt first, then "d", then root.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "d", .kind = .dir },
        .{ .path = "d/file.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .post });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.path);
        entries.deinit(testing.allocator);
    }
    try drainEntries(&w, io, testing.allocator, &entries);

    // Must emit at least the file and its parent. RED: stub emits 0.
    try testing.expect(entries.items.len >= 2);

    const idx_child = indexOfEntry(entries.items, "d/file.txt");
    const idx_parent = indexOfEntry(entries.items, "/d");
    try testing.expect(idx_child != null and idx_parent != null);
    // Child file.txt must appear before its parent dir "d".
    try testing.expect(idx_child.? < idx_parent.?);
}

test "walker: both-order emits each directory twice with pre before post" {
    // §5.1 #4: With order=.both, each directory appears once with visit=.pre
    // and once with visit=.post, in the correct relative order.
    // Root is emitted first (pre) and last (post). "sub" also appears twice.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "sub", .kind = .dir },
        .{ .path = "sub/f.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .both });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.path);
        entries.deinit(testing.allocator);
    }
    try drainEntries(&w, io, testing.allocator, &entries);

    var pre_count: u32 = 0;
    var post_count: u32 = 0;
    for (entries.items) |entry| {
        if (entry.kind == .directory) {
            switch (entry.visit) {
                .pre => pre_count += 1,
                .post => post_count += 1,
            }
        }
    }
    // With .both, every directory (root + "sub") must appear as pre AND post.
    // RED: stub emits nothing.
    try testing.expect(pre_count >= 1);
    try testing.expect(post_count >= 1);
    try testing.expectEqual(pre_count, post_count);

    // In .both order, the root pre-entry is first and root post-entry is last.
    try testing.expect(entries.items.len >= 1);
    try testing.expectEqual(.pre, entries.items[0].visit);
    try testing.expectEqual(.post, entries.items[entries.items.len - 1].visit);
}

test "walker: max_depth cap — walker terminates before exceeding limit" {
    // §5.1 #5: A walker configured with max_depth=2 on a 4-deep tree must
    // not descend past depth 2. Against the stub (which returns null
    // immediately), the test fails because it gets zero entries instead of
    // some entries at depth <= 2.
    //
    // Note: when the real implementation hits max_depth it returns
    // error.DepthLimitExceeded from next(). The caller should handle or
    // propagate this. Here we just verify no entry exceeds depth 2.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "l1", .kind = .dir },
        .{ .path = "l1/l2", .kind = .dir },
        .{ .path = "l1/l2/l3", .kind = .dir },
        .{ .path = "l1/l2/l3/l4", .kind = .dir },
        .{ .path = "l1/l2/l3/l4/deep.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .max_depth = 2 });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var max_observed_depth: u16 = 0;
    var count: u32 = 0;
    while (walker_next: {
        const result = w.next(io);
        if (result) |maybe_entry| {
            break :walker_next maybe_entry;
        } else |err| switch (err) {
            error.DepthLimitExceeded => break :walker_next null,
            else => return err,
        }
    }) |entry| {
        if (entry.depth > max_observed_depth) max_observed_depth = entry.depth;
        count += 1;
    }
    // Must emit at least the root + l1 at depth 1. RED: stub emits 0.
    try testing.expect(count >= 1);
    // Must not exceed the cap.
    try testing.expect(max_observed_depth <= 2);
}

test "walker: max_entries cap — next() returns EntryLimitExceeded after limit" {
    // §5.1 #6a: A walker configured with max_entries=3 on a tree with 10
    // files must return error.EntryLimitExceeded on the 4th next() call.
    // Against the stub (next() always returns null), this fails because
    // expectError never sees the error — the walker terminates with null.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build 10 flat files.
    try buildTree(io, tmp.dir, &.{
        .{ .path = "f01.txt", .kind = .file },
        .{ .path = "f02.txt", .kind = .file },
        .{ .path = "f03.txt", .kind = .file },
        .{ .path = "f04.txt", .kind = .file },
        .{ .path = "f05.txt", .kind = .file },
        .{ .path = "f06.txt", .kind = .file },
        .{ .path = "f07.txt", .kind = .file },
        .{ .path = "f08.txt", .kind = .file },
        .{ .path = "f09.txt", .kind = .file },
        .{ .path = "f10.txt", .kind = .file },
    });

    // max_entries=3: root dir + 3 files = first 4 next() calls succeed.
    // The 5th call hits the cap and must return error.EntryLimitExceeded.
    var w = try Walker.init(testing.allocator, .{ .max_entries = 3 });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    // Drain until we get an error or null. Count successful emissions.
    var count: u32 = 0;
    var got_limit_error = false;
    while (true) {
        const result = w.next(io);
        if (result) |maybe_entry| {
            if (maybe_entry == null) break;
            count += 1;
        } else |err| switch (err) {
            error.EntryLimitExceeded => {
                got_limit_error = true;
                break;
            },
            else => return err,
        }
    }
    // Must have hit the limit. RED: stub returns null immediately, no error.
    try testing.expect(got_limit_error);
    // Must have emitted at least 1 entry before hitting the cap.
    try testing.expect(count >= 1);
}

test "walker: max_entries high cap — full tree drains without error" {
    // §5.1 #6b: Positive companion: a generous cap lets all 10 files through.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "f01.txt", .kind = .file },
        .{ .path = "f02.txt", .kind = .file },
        .{ .path = "f03.txt", .kind = .file },
        .{ .path = "f04.txt", .kind = .file },
        .{ .path = "f05.txt", .kind = .file },
        .{ .path = "f06.txt", .kind = .file },
        .{ .path = "f07.txt", .kind = .file },
        .{ .path = "f08.txt", .kind = .file },
        .{ .path = "f09.txt", .kind = .file },
        .{ .path = "f10.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .max_entries = 100 });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var count: u32 = 0;
    while (try w.next(io)) |_| count += 1;

    // Must emit root + 10 files = 11 entries. RED: stub emits 0.
    try testing.expect(count >= 11);
}

test "walker: pruneCurrent on pre-order directory suppresses subtree" {
    // §5.1 #7: Calling pruneCurrent() after receiving a pre-order directory
    // entry must cause the walker to skip that subtree entirely.
    // We prune "prune/" and verify "kept.txt" is still seen but "gone.txt"
    // is not — both assertions are checked in a single walk pass.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "keep", .kind = .dir },
        .{ .path = "keep/inner", .kind = .dir },
        .{ .path = "keep/inner/kept.txt", .kind = .file },
        .{ .path = "prune", .kind = .dir },
        .{ .path = "prune/inner", .kind = .dir },
        .{ .path = "prune/inner/gone.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_kept = false;
    var saw_pruned_content = false;
    while (try w.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "prune")) {
            w.pruneCurrent();
        }
        if (std.mem.eql(u8, entry.basename, "kept.txt")) saw_kept = true;
        if (std.mem.eql(u8, entry.basename, "gone.txt")) saw_pruned_content = true;
    }
    // "kept.txt" must be seen; "gone.txt" must not. RED: stub emits nothing,
    // so saw_kept stays false and the test fails.
    try testing.expect(saw_kept);
    try testing.expect(!saw_pruned_content);
}

test "walker: pruneCurrent on a non-directory is a no-op" {
    // §5.1 #8: Calling pruneCurrent() after a file entry must not crash or
    // skip siblings.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "a.txt", .kind = .file },
        .{ .path = "b.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var count: u32 = 0;
    while (try w.next(io)) |entry| {
        if (entry.kind != .directory) w.pruneCurrent(); // no-op on files
        count += 1;
    }
    // Both files must be emitted despite calling pruneCurrent on each.
    // RED: stub emits 0, so count stays 0, fails >= 2 assertion.
    try testing.expect(count >= 2);
}

test "walker: cycle detection prevents infinite loop on symlink loop" {
    // §5.1 #9: A symlink pointing back into its own ancestor creates a cycle.
    // With detect_cycles=true and follow_all, the walker must terminate and
    // emit no path more than once.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "real.txt");
    try tmp.dir.createDirPath(io, "subdir");
    // loop -> .. (symlink to parent, creating a cycle).
    try tmp.dir.symLink(io, "..", "subdir/loop", .{});

    // Use a generous max_entries so we would spin many times if cycle
    // detection were broken, making a failure loud rather than silent.
    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .detect_cycles = true,
        .max_entries = 50,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.path);
        entries.deinit(testing.allocator);
    }
    try drainEntries(&w, io, testing.allocator, &entries);

    // Must terminate and emit the real file. RED: stub emits 0.
    var saw_real = false;
    for (entries.items) |e| {
        if (std.mem.endsWith(u8, e.path, "real.txt")) saw_real = true;
    }
    try testing.expect(saw_real);

    // Per-path uniqueness: no path should appear twice. Broken cycle
    // detection would produce duplicates before hitting max_entries.
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(testing.allocator);
    for (entries.items) |e| {
        const gop = try seen.getOrPut(testing.allocator, e.path);
        try testing.expect(!gop.found_existing); // path emitted at most once
    }
}

test "walker: stay_on_filesystem flag" {
    // §5.1 #10: stay_on_filesystem must prevent crossing mount boundaries.
    // Portable test: verify the walker compiles and runs with the flag set.
    // Full cross-device behavior requires privileged mount, so we just verify
    // that the walker terminates and emits the root's own contents.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "same_fs.txt");

    var w = try Walker.init(testing.allocator, .{
        .stay_on_filesystem = true,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var count: u32 = 0;
    while (try w.next(io)) |_| count += 1;

    // Must emit at least same_fs.txt. RED: stub emits 0.
    try testing.expect(count >= 1);
}

test "walker: symlink policy no_follow emits symlink but does not descend" {
    // §5.1 #11: With no_follow, a symlink to a directory is emitted as
    // .sym_link kind and is never descended into.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "real_dir", .kind = .dir },
        .{ .path = "real_dir/hidden.txt", .kind = .file },
        .{ .path = "link_dir", .kind = .symlink, .symlink_target = "real_dir" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .no_follow,
        .order = .pre,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_symlink = false;
    var saw_hidden = false;
    while (try w.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "link_dir")) {
            saw_symlink = true;
            try testing.expectEqual(std.Io.File.Kind.sym_link, entry.kind);
        }
        if (std.mem.eql(u8, entry.basename, "hidden.txt")) saw_hidden = true;
    }
    // Must emit the symlink but NOT its target's contents.
    // RED: stub returns null, so saw_symlink=false, fails the expect.
    try testing.expect(saw_symlink);
    try testing.expect(!saw_hidden);
}

test "walker: symlink policy follow_cmdline follows only depth-0 symlinks" {
    // §5.1 #12: With follow_cmdline (-H), symlinks at the root operand level
    // are followed; symlinks encountered during traversal are not.
    // Tree: actual_dir/ -> deep.txt, nested/, nested/inner.txt
    //       actual_dir/nested_link -> nested  (nested symlink, must NOT follow)
    //       root_link -> actual_dir           (depth-0 symlink, MUST follow)
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "actual_dir", .kind = .dir },
        .{ .path = "actual_dir/deep.txt", .kind = .file },
        .{ .path = "actual_dir/nested", .kind = .dir },
        .{ .path = "actual_dir/nested/inner.txt", .kind = .file },
        // nested_link is a symlink inside actual_dir pointing to nested/.
        // follow_cmdline must NOT follow this.
        .{ .path = "actual_dir/nested_link", .kind = .symlink, .symlink_target = "nested" },
        // root_link is the depth-0 operand — follow_cmdline MUST follow this.
        .{ .path = "root_link", .kind = .symlink, .symlink_target = "actual_dir" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_cmdline,
        .order = .pre,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "root_link");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_deep = false;
    var saw_nested_link_followed = false;
    while (try w.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "deep.txt")) saw_deep = true;
        // inner.txt is reachable via the REAL nested/ path, but we only care
        // about paths that went through nested_link. Scope the check to
        // entries whose path contains "nested_link".
        if (std.mem.find(u8, entry.path, "nested_link") != null and
            std.mem.eql(u8, entry.basename, "inner.txt"))
        {
            saw_nested_link_followed = true;
        }
    }
    // Must have followed the cmdline symlink (saw deep.txt).
    // RED: stub emits nothing, so saw_deep stays false.
    try testing.expect(saw_deep);
    try testing.expect(!saw_nested_link_followed);
}

test "walker: symlink policy follow_all follows all symlinks" {
    // §5.1 #13: With follow_all (-L), all symlinks are followed (subject to
    // cycle detection). A symlink to a dir is descended into.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "target_dir", .kind = .dir },
        .{ .path = "target_dir/target_file.txt", .kind = .file },
        .{ .path = "link_to_dir", .kind = .symlink, .symlink_target = "target_dir" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .detect_cycles = true,
        .order = .pre,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_via_link = false;
    while (try w.next(io)) |entry| {
        // When link_to_dir is followed, we expect to see target_file.txt
        // under the link_to_dir path.
        if (std.mem.eql(u8, entry.basename, "target_file.txt") and
            std.mem.find(u8, entry.path, "link_to_dir") != null)
        {
            saw_via_link = true;
        }
    }
    // Must have followed the symlink and descended into it.
    // RED: stub returns null, saw_via_link stays false.
    try testing.expect(saw_via_link);
}

test "walker: sort_children emits directory entries in alphabetical order" {
    // §5.1 #14: With sort_children=true, sibling entries must be emitted in
    // ascending lexicographic order by basename. Only file-kind entries
    // are checked since the root dir entry at depth=0 should not
    // participate in the order assertion.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "z_last.txt", .kind = .file },
        .{ .path = "a_first.txt", .kind = .file },
        .{ .path = "m_middle.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{
        .sort_children = true,
        .order = .pre,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.path);
        entries.deinit(testing.allocator);
    }
    try drainEntries(&w, io, testing.allocator, &entries);

    // Must emit all three files. RED: stub emits 0.
    try testing.expect(entries.items.len >= 3);

    // Filter to only non-directory entries for the order check.
    var file_basenames: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_basenames.deinit(testing.allocator);
    for (entries.items) |e| {
        if (e.kind != .directory) {
            try file_basenames.append(testing.allocator, e.basename);
        }
    }
    try testing.expect(file_basenames.items.len >= 3);

    // Verify sorted order: a_first < m_middle < z_last.
    for (1..file_basenames.items.len) |i| {
        try testing.expect(
            std.mem.order(u8, file_basenames.items[i - 1], file_basenames.items[i]) == .lt,
        );
    }
}

test "walker: multiple roots are drained in insertion order" {
    // §5.1 #15: addRoot("a"); addRoot("b") must fully drain tree "a" before
    // emitting anything from tree "b".
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "tree_a", .kind = .dir },
        .{ .path = "tree_a/file_a.txt", .kind = .file },
        .{ .path = "tree_b", .kind = .dir },
        .{ .path = "tree_b/file_b.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root_a = try tmpPath(testing.allocator, io, &tmp, "tree_a");
    defer testing.allocator.free(root_a);
    const root_b = try tmpPath(testing.allocator, io, &tmp, "tree_b");
    defer testing.allocator.free(root_b);

    try w.addRoot(root_a);
    try w.addRoot(root_b);

    var last_a_index: i64 = -1;
    var first_b_index: i64 = -1;
    var idx: i64 = 0;
    while (try w.next(io)) |entry| {
        if (std.mem.find(u8, entry.path, "tree_a") != null) last_a_index = idx;
        if (std.mem.find(u8, entry.path, "tree_b") != null and first_b_index == -1) {
            first_b_index = idx;
        }
        idx += 1;
    }
    // Must have seen something from both trees. RED: stub emits nothing.
    try testing.expect(last_a_index >= 0);
    try testing.expect(first_b_index >= 0);
    // All of tree_a must come before any of tree_b.
    try testing.expect(last_a_index < first_b_index);
}

test "walker: deinit after mid-walk abandonment closes all directory handles" {
    // §5.1 #16: If the caller stops calling next() before the walk completes,
    // deinit() must close all Dir handles that remain open on the stack.
    // We verify this by ensuring deinit does not leak (testing.allocator will
    // catch memory leaks; file descriptor leaks are harder to observe here,
    // so we verify the walker at least does not crash on deinit).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "sub", .kind = .dir },
        .{ .path = "sub/deep", .kind = .dir },
        .{ .path = "sub/deep/file.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    // Advance exactly one step then abandon the walk.
    const first = try w.next(io);
    // RED: stub returns null here; first is null, test fails on the expect.
    try testing.expect(first != null);
    // Intentionally do not drain; deinit (via defer) must handle cleanup.
}

test "walker: path and basename slices must be duped before next() call" {
    // §5.1 #17: The path and basename slices in Entry are owned by the walker's
    // internal path_buf. After calling next() again, those slices may have been
    // overwritten. Callers must dupe() if they need to retain the path.
    // This test captures the *pointer* of the path slice before and after a
    // second next() call and verifies that the pointer was reused (regression
    // guard for callers who incorrectly retain un-duped slices).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "file1.txt", .kind = .file },
        .{ .path = "file2.txt", .kind = .file },
    });

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    const first_entry = try w.next(io);
    // RED: stub returns null, first_entry is null, test fails on the expect.
    try testing.expect(first_entry != null);

    const first_path_ptr = if (first_entry) |e| e.path.ptr else null;
    const second_entry = try w.next(io);
    const second_path_ptr = if (second_entry) |e| e.path.ptr else null;

    // Both must have been emitted (non-null). RED: stub returns null on both.
    try testing.expect(first_path_ptr != null);
    try testing.expect(second_path_ptr != null);

    // The internal buffer is reused: the second entry's path_ptr should equal
    // the first entry's path_ptr (same backing buffer, different length/content).
    try testing.expectEqual(first_path_ptr, second_path_ptr);
}

test "walker: next() is re-entrant after a per-entry I/O error" {
    // §6.6 design decision: next() returns !?Entry. Errors propagate but the
    // walker stays re-entrant — calling next() again after an error must
    // continue from the next sibling rather than poisoning the walker state.
    //
    // Method: build three sibling directories a/, locked/, z/. Place a file
    // in each. chmod 000 locked/ so opening it returns error.AccessDenied.
    // Walk: expect an error when the walker tries to open locked/, then verify
    // a/ and z/ are still emitted in subsequent next() calls.
    //
    // Restore locked/ to 0o700 in a defer so tmpDir cleanup can succeed.
    // Skip on Windows where chmod semantics differ.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "a", .kind = .dir },
        .{ .path = "a/file_a.txt", .kind = .file },
        .{ .path = "locked", .kind = .dir },
        .{ .path = "locked/file_l.txt", .kind = .file },
        .{ .path = "z", .kind = .dir },
        .{ .path = "z/file_z.txt", .kind = .file },
    });

    // Make locked/ inaccessible using the Zig 0.16 native API (no libc needed).
    const no_access = std.Io.File.Permissions.fromMode(0o000);
    try tmp.dir.setFilePermissions(io, "locked", no_access, .{});
    // Restore on exit so that tmp.cleanup() can remove it.
    defer tmp.dir.setFilePermissions(io, "locked", std.Io.File.Permissions.fromMode(0o700), .{}) catch {};

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_file_a = false;
    var saw_file_z = false;
    var saw_io_error = false;

    // Drive the walker; on an I/O error continue from the next call.
    while (true) {
        const result = w.next(io);
        if (result) |maybe_entry| {
            if (maybe_entry == null) break;
            const entry = maybe_entry.?;
            if (std.mem.eql(u8, entry.basename, "file_a.txt")) saw_file_a = true;
            if (std.mem.eql(u8, entry.basename, "file_z.txt")) saw_file_z = true;
        } else |err| {
            // Any I/O error from the locked dir; record it and keep going.
            _ = err;
            saw_io_error = true;
        }
    }

    // Must have seen an I/O error for locked/. RED: stub returns null, never errors.
    try testing.expect(saw_io_error);
    // Must have recovered and emitted file_a.txt and file_z.txt.
    try testing.expect(saw_file_a);
    try testing.expect(saw_file_z);
}
