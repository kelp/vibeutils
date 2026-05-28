/// Bounded iterative directory walker for vibeutils.
///
/// Replaces direct recursion in cp, mv, chmod, chown, rm, du, grep, find.
/// Uses an explicit stack of directory frames so max_depth is assertable
/// at every push — Tiger Style "every loop must have a fixed upper bound."
///
/// Design contract: docs/tiger-style-review/walker-design.md
const std = @import("std");
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
    /// Hard upper bound on stack depth. Assertion fires if exceeded.
    /// Default 1024 — POSIX PATH_MAX gives ~256 components; real filesystems
    /// almost never exceed ~50. 1024 is a generous safety margin.
    max_depth: u16 = 1024,

    /// Hard upper bound on total entries emitted before the walk forcibly
    /// halts. Defends against pathologically large trees. Default 16 Mi.
    /// Assertion fires on overflow; caller can lower for testing.
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
    /// config.max_depth — asserted on every push.
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

/// Create a flat file inside tmp_dir.
fn createFile(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    const f = try dir.createFile(io, name, .{});
    f.close(io);
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

// ============================================================================
// Tests — §5.1 Walker unit tests
// ============================================================================

test "walker: empty directory emits nothing after the root" {
    // §5.1 #1: Walk an empty directory. The walker should terminate without
    // emitting any children (root itself is not emitted in pre-order by most
    // callers, but we add the root path and expect next() to return null for
    // an empty dir).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var w = try Walker.init(testing.allocator, .{});
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    // Stub always returns null, so next() terminates immediately.
    // The test verifies the walker emitted at least the root entry — this will
    // FAIL against the stub since next() returns null with zero entries.
    const entry = try w.next(io);
    try testing.expect(entry != null); // RED: stub returns null
}

test "walker: pre-order ordering emits parent before children" {
    // §5.1 #2: Pre-order must emit a directory before its children.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "a");
    try createFile(io, tmp.dir, "a/x.txt");

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e);
        entries.deinit(testing.allocator);
    }
    const count = try drainWalker(&w, io, testing.allocator, &entries);

    // Expect at minimum the directory "a" and "a/x.txt". RED: stub emits 0.
    try testing.expect(count >= 2);
}

test "walker: post-order ordering emits children before parent directory" {
    // §5.1 #3: Post-order must emit children before their containing directory.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "d");
    try createFile(io, tmp.dir, "d/file.txt");

    var w = try Walker.init(testing.allocator, .{ .order = .post });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e);
        entries.deinit(testing.allocator);
    }
    const count = try drainWalker(&w, io, testing.allocator, &entries);

    // Must emit at least the file and its parent dir. RED: stub emits 0.
    try testing.expect(count >= 2);
    // When implemented, entries.items[0] should be the file, not the dir.
    // For now just assert we got something non-empty.
}

test "walker: both-order emits each directory twice with pre before post" {
    // §5.1 #4: With order=.both, each directory appears once with visit=.pre
    // and once with visit=.post, in the correct relative order.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub");
    try createFile(io, tmp.dir, "sub/f.txt");

    var w = try Walker.init(testing.allocator, .{ .order = .both });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var pre_count: u32 = 0;
    var post_count: u32 = 0;
    while (try w.next(io)) |entry| {
        if (entry.kind == .directory) {
            switch (entry.visit) {
                .pre => pre_count += 1,
                .post => post_count += 1,
            }
        }
    }
    // With .both, "sub" must appear as pre AND post. RED: stub emits nothing.
    try testing.expect(pre_count >= 1);
    try testing.expect(post_count >= 1);
    try testing.expectEqual(pre_count, post_count);
}

test "walker: max_depth cap — walker terminates before exceeding limit" {
    // §5.1 #5: A walker configured with max_depth=2 on a 4-deep tree must
    // not descend past depth 2. Against the stub (which returns null
    // immediately), the test fails because it gets zero entries instead of
    // some entries at depth <= 2.
    //
    // Note: the real implementation asserts on overflow, causing a panic.
    // The stub never reaches that assert, so the test goes RED on the
    // "at least one entry was emitted" assertion below.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "l1/l2/l3/l4");
    try createFile(io, tmp.dir, "l1/l2/l3/l4/deep.txt");

    var w = try Walker.init(testing.allocator, .{ .max_depth = 2 });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var max_observed_depth: u16 = 0;
    var count: u32 = 0;
    while (try w.next(io)) |entry| {
        if (entry.depth > max_observed_depth) max_observed_depth = entry.depth;
        count += 1;
    }
    // Must emit at least one entry (l1 at depth 1). RED: stub emits 0.
    try testing.expect(count >= 1);
    // Must not exceed the cap.
    try testing.expect(max_observed_depth <= 2);
}

test "walker: max_entries cap — walker terminates after limit entries" {
    // §5.1 #6: A walker configured with max_entries=3 on a wider tree must
    // stop after 3 entries. Against the stub (next() returns null), count is 0
    // and the test fails on the "count == 3" assertion.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "f1.txt");
    try createFile(io, tmp.dir, "f2.txt");
    try createFile(io, tmp.dir, "f3.txt");
    try createFile(io, tmp.dir, "f4.txt");
    try createFile(io, tmp.dir, "f5.txt");

    var w = try Walker.init(testing.allocator, .{ .max_entries = 3 });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var count: u32 = 0;
    while (try w.next(io)) |_| {
        count += 1;
    }
    // Must emit exactly max_entries entries then stop. RED: stub emits 0.
    try testing.expectEqual(@as(u32, 3), count);
}

test "walker: pruneCurrent on pre-order directory suppresses subtree" {
    // §5.1 #7: Calling pruneCurrent() after receiving a pre-order directory
    // entry must cause the walker to skip that subtree entirely.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "keep/inner");
    try createFile(io, tmp.dir, "keep/inner/kept.txt");
    try tmp.dir.createDirPath(io, "prune/inner");
    try createFile(io, tmp.dir, "prune/inner/gone.txt");

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_pruned_content = false;
    while (try w.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "prune")) {
            w.pruneCurrent();
        }
        if (std.mem.eql(u8, entry.basename, "gone.txt")) {
            saw_pruned_content = true;
        }
    }
    // The pruned subtree's content must not appear. RED: stub emits nothing so
    // neither "prune" dir nor "gone.txt" is ever seen, but the test also
    // expects to have seen "kept.txt" — assert that at minimum something emits.
    //
    // Simpler RED condition: assert we did NOT see "gone.txt", but also
    // that the walker emitted at least 1 entry from "keep/".
    try testing.expect(!saw_pruned_content);
    // The stub satisfies this (never emits anything), so we add the positive
    // assertion that the walker must have emitted at least "keep".
    // Re-check: we need to assert count > 0. Use saw_pruned_content negation
    // plus a separate count. We'll keep this test focused: RED is that
    // the "keep" subtree was NOT emitted (stub returns null immediately).
    // Assert the walker emitted entries from "keep":
    var w2 = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w2.deinit(io);
    const root2 = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root2);
    try w2.addRoot(root2);
    var saw_kept: bool = false;
    while (try w2.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "kept.txt")) saw_kept = true;
    }
    try testing.expect(saw_kept); // RED: stub returns null, saw_kept stays false
}

test "walker: pruneCurrent on a non-directory is a no-op" {
    // §5.1 #8: Calling pruneCurrent() after a file entry must not crash or
    // skip siblings.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "a.txt");
    try createFile(io, tmp.dir, "b.txt");

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
    // With detect_cycles=true and follow_all, the walker must terminate.
    // With the stub (next() always null), this test fails because it gets
    // zero entries but expects to see at least the initial file.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "real.txt");
    try tmp.dir.createDirPath(io, "subdir");
    // loop -> .. (symlink to parent, creating a cycle)
    try tmp.dir.symLink(io, "..", "subdir/loop", .{});

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .detect_cycles = true,
        .max_entries = 200,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e);
        entries.deinit(testing.allocator);
    }
    const count = try drainWalker(&w, io, testing.allocator, &entries);

    // Must terminate and emit the real file. RED: stub emits 0.
    try testing.expect(count >= 1);
    // No path should appear twice (no duplicate visits from cycle).
    // Verify uniqueness: check for real.txt specifically.
    var saw_real = false;
    for (entries.items) |p| {
        if (std.mem.endsWith(u8, p, "real.txt")) saw_real = true;
    }
    try testing.expect(saw_real);
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

    try tmp.dir.createDirPath(io, "real_dir");
    try createFile(io, tmp.dir, "real_dir/hidden.txt");
    try tmp.dir.symLink(io, "real_dir", "link_dir", .{});

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
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "actual_dir");
    try createFile(io, tmp.dir, "actual_dir/deep.txt");
    try tmp.dir.createDirPath(io, "actual_dir/nested");
    try tmp.dir.symLink(io, "nested", "actual_dir/nested_link", .{});
    try createFile(io, tmp.dir, "actual_dir/nested/inner.txt");

    // The root operand is a symlink to actual_dir.
    try tmp.dir.symLink(io, "actual_dir", "root_link", .{});

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
        // If nested_link is followed (wrong), we'd see inner.txt via that path.
        if (std.mem.eql(u8, entry.basename, "inner.txt")) {
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

    try tmp.dir.createDirPath(io, "target_dir");
    try createFile(io, tmp.dir, "target_dir/target_file.txt");
    try tmp.dir.symLink(io, "target_dir", "link_to_dir", .{});

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
    // ascending lexicographic order by basename.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "z_last.txt");
    try createFile(io, tmp.dir, "a_first.txt");
    try createFile(io, tmp.dir, "m_middle.txt");

    var w = try Walker.init(testing.allocator, .{
        .sort_children = true,
        .order = .pre,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e);
        entries.deinit(testing.allocator);
    }
    const count = try drainWalker(&w, io, testing.allocator, &entries);

    // Must emit all three files. RED: stub emits 0.
    try testing.expect(count >= 3);
    // Verify sorted order: a_ before m_ before z_.
    if (entries.items.len >= 3) {
        const first = std.fs.path.basename(entries.items[0]);
        const second = std.fs.path.basename(entries.items[1]);
        const third = std.fs.path.basename(entries.items[2]);
        try testing.expect(std.mem.order(u8, first, second) == .lt);
        try testing.expect(std.mem.order(u8, second, third) == .lt);
    }
}

test "walker: multiple roots are drained in insertion order" {
    // §5.1 #15: addRoot("a"); addRoot("b") must fully drain tree "a" before
    // emitting anything from tree "b".
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "tree_a");
    try createFile(io, tmp.dir, "tree_a/file_a.txt");
    try tmp.dir.createDirPath(io, "tree_b");
    try createFile(io, tmp.dir, "tree_b/file_b.txt");

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

    try tmp.dir.createDirPath(io, "sub/deep");
    try createFile(io, tmp.dir, "sub/deep/file.txt");

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

    try createFile(io, tmp.dir, "file1.txt");
    try createFile(io, tmp.dir, "file2.txt");

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
    // This test fakes the scenario by checking that the walker doesn't crash
    // or get stuck after receiving an error on one entry. Since we can't
    // easily inject an I/O error without fakeroot, we verify the walker
    // handles a normal multi-entry walk and terminates cleanly — the real
    // re-entrant behavior can only be tested with error injection.
    //
    // RED condition: the stub returns null immediately (zero entries), so
    // the assertion that at least 2 entries were emitted fails.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "sibling1.txt");
    try createFile(io, tmp.dir, "sibling2.txt");
    try createFile(io, tmp.dir, "sibling3.txt");

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var count: u32 = 0;
    while (try w.next(io)) |_| count += 1;

    // All three siblings must be emitted. RED: stub emits 0.
    try testing.expect(count >= 3);
}
