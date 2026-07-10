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

/// How directory cycles are detected during the walk.
pub const CycleMode = enum {
    /// No cycle detection. Only valid when symlinks != .follow_all, since a
    /// followed symlink loop would otherwise run to the depth/entry bound.
    none,
    /// GNU fts semantics: a child directory is a cycle only when its
    /// (device, inode) matches an ANCESTOR on the current descent path. On
    /// detection next() returns error.DirectoryCycle and cyclePath() names
    /// the offending path. Aliases reached by distinct paths are re-walked.
    ancestors,
    /// Ancestor detection PLUS a global visited set: any directory inode seen
    /// anywhere in the walk is visited at most once (silent skip on repeat).
    /// This is the default and preserves the historical detect_cycles=true
    /// behavior used by mv and rm.
    ancestors_and_visited,
};

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

    /// How directory cycles are detected. Must not be `.none` when
    /// `symlinks == .follow_all` (a followed loop would otherwise run to the
    /// depth/entry bound). Default `.ancestors_and_visited` preserves the
    /// historical global-visited-set behavior for untouched consumers.
    cycle_mode: CycleMode = .ancestors_and_visited,

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

    /// File kind. For no_follow/follow_cmdline it is the readdir dtype (a
    /// symlink stays .sym_link). For follow_all a symlink's kind is the
    /// STATTED target kind (target dir -> .directory and descended, non-dir
    /// -> the target's kind as a leaf); when the target cannot be statted
    /// (broken link or chain loop) the kind is .sym_link.
    kind: std.Io.File.Kind,

    /// Depth from the walk root. Root operand is depth 0.
    depth: u16,

    /// Pre- or post-order visit. For non-directories always .pre.
    /// For directories with order=.both, the walker emits .pre on descent
    /// and .post on unwind.
    visit: enum { pre, post },

    /// Cached stat result. Walker populates when stat is needed for descent
    /// decisions; null otherwise. Callers should use this rather than re-stat.
    stat: ?Stat,

    /// Handle to the parent directory, valid until the next `next()`.
    /// Enables openat-style operations (e.g. chmod via fd, du via fstatat).
    /// Null only at depth 0 (the root operands have no parent in the walk).
    parent_dir: ?std.Io.Dir,
};

// ============================================================================
// Private Types
// ============================================================================

/// A child dirent entry (name + kind) as seen by the iterator.
const DirEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

/// A single in-progress directory frame on the traversal stack.
const Frame = struct {
    /// Owned: closed when popped.
    dir: std.Io.Dir,
    /// Lives alongside dir; iterated until null.
    iterator: std.Io.Dir.Iterator,
    /// Depth of THIS directory (not its children).
    depth: u16,
    /// path_buf length before this dir's name was appended (parent length).
    path_len_on_entry: usize,
    /// path_buf length of this dir's full path (for post-order emit).
    dir_path_len: usize,
    /// Emit this dir post-order when iterator exhausted?
    pending_post: bool,
    /// True once post-order entry was emitted; pop on next next() call.
    post_emitted: bool,
    /// Which root operand index this descended from.
    root_index: u32,
    /// Non-null when sort_children=true: pre-collected sorted entries.
    sorted_entries: ?std.ArrayListUnmanaged(DirEntry),
    /// Next index into sorted_entries to consume.
    sorted_index: u32,
    /// (device, inode) of this directory. Populated whenever the id was
    /// computed — for any cycle_mode != .none (so the traversal stack
    /// doubles as the ancestor chain for `.ancestors` cycle detection), or
    /// for the stay_on_filesystem device check. Unused under `.none`.
    /// Null when neither applies or when fromDir failed.
    fs_id: ?directory.FileSystemId,
};

/// Outcome of filtering an opened child directory before descent.
const ChildOutcome = union(enum) {
    /// Descend; the carried id (when present) is stored in the pushed frame.
    proceed: ?directory.FileSystemId,
    /// Skip silently (already-visited dedup or a filesystem boundary).
    skip,
    /// Ancestor cycle: next() must return error.DirectoryCycle.
    cycle,
};

/// A root path queued for traversal.
const RootSpec = struct {
    /// Owned by allocator.
    path: []const u8,
    /// True if we should follow symlinks when opening this root.
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

    /// Explicit stack of in-progress directory frames. Never exceeds max_depth.
    stack: std.ArrayListUnmanaged(Frame),

    /// Global visited set (dev, inode). Non-null iff
    /// config.cycle_mode == .ancestors_and_visited.
    visited: ?directory.FileSystemIdSet,

    /// Full path of the entry that triggered the most recent per-entry error
    /// from next(): a directory cycle, or a failed openDir during descent.
    /// Valid until the next next() call; exposed via errorPath() (and, for the
    /// cycle case, cyclePath()). error_path_valid gates a meaningful value.
    error_path_buf: std.ArrayListUnmanaged(u8),

    /// True when error_path_buf names the entry behind the error the most
    /// recent next() returned. Reset at the start of every next() so a
    /// successful call clears it.
    error_path_valid: bool,

    /// Root operand queue. The walker drains this before declaring done.
    roots: std.ArrayListUnmanaged(RootSpec),

    /// Index of the next root to start (into roots array).
    root_cursor: u32,

    /// Device of the *current* root, for stay_on_filesystem.
    current_root_dev: ?u64,

    /// Scratch buffer for the path of the currently-emitted entry.
    /// Reused across calls to avoid allocator churn.
    path_buf: std.ArrayListUnmanaged(u8),

    /// Running total of entries emitted. Bounds-checked against max_entries.
    entries_emitted: u64,

    /// When true, the next next() call should pop the top frame (prune).
    prune_current: bool,

    /// True when the last emitted entry was a pre-order directory.
    /// Makes pruneCurrent() effective (pop the top frame next call).
    last_was_pre_dir: bool,

    // -----------------------------------------------------------------------
    // Public lifecycle methods
    // -----------------------------------------------------------------------

    /// Initialize an empty walker. Add roots with `addRoot`, then drive
    /// with `next`. Must be paired with `deinit`.
    pub fn init(
        allocator: std.mem.Allocator,
        config: WalkConfig,
    ) error{OutOfMemory}!Walker {
        assert(config.max_depth > 0);
        assert(config.max_entries > 0);
        // A followed symlink loop has no other stopping mechanism, so
        // follow_all requires a cycle detector.
        assert(config.symlinks != .follow_all or config.cycle_mode != .none);
        var visited: ?directory.FileSystemIdSet = null;
        if (config.cycle_mode == .ancestors_and_visited) {
            visited = directory.FileSystemIdSet.init(allocator);
        }
        return Walker{
            .allocator = allocator,
            .config = config,
            .stack = .empty,
            .visited = visited,
            .error_path_buf = .empty,
            .error_path_valid = false,
            .roots = .empty,
            .root_cursor = 0,
            .current_root_dev = null,
            .path_buf = .empty,
            .entries_emitted = 0,
            .prune_current = false,
            .last_was_pre_dir = false,
        };
    }

    /// Add a root path to walk. May be called multiple times before or
    /// between `next()` calls. Each root is processed in insertion order.
    pub fn addRoot(self: *Walker, path: []const u8) error{OutOfMemory}!void {
        assert(path.len > 0);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const follow_initial = (self.config.symlinks != .no_follow);
        try self.roots.append(self.allocator, RootSpec{
            .path = path_copy,
            .follow_initial = follow_initial,
        });
        assert(self.roots.items.len > 0);
    }

    /// Advance to the next entry. Returns null when the walk is complete.
    /// Errors are per-entry. After an error, next() may be called again.
    /// Returns error.DepthLimitExceeded when config.max_depth is reached.
    /// Returns error.EntryLimitExceeded when config.max_entries is reached.
    /// Under cycle_mode == .ancestors, next() is re-entrant on cycles: it
    /// returns error.DirectoryCycle once per detected ancestor cycle, and the
    /// walk continues normally on the following call. cyclePath() names the
    /// offending path for that error and is valid only until the next next()
    /// call.
    pub fn next(self: *Walker, io: std.Io) !?Entry {
        assert(self.stack.items.len <= self.config.max_depth);
        assert(self.root_cursor <= self.roots.items.len);
        // Any previously recorded error path belongs to the prior call; clear
        // it so errorPath() reflects only what THIS next() produces.
        self.error_path_valid = false;
        if (self.entries_emitted >= self.config.max_entries) {
            return error.EntryLimitExceeded;
        }
        // Handle prune: pop the frame that was just pushed for a pre-dir emit.
        if (self.prune_current and self.last_was_pre_dir) {
            self.prune_current = false;
            self.last_was_pre_dir = false;
            assert(self.stack.items.len > 0);
            self.popFrame(io);
        }
        self.prune_current = false;
        // Drive loop terminates when the explicit stack drains and every root
        // is consumed: each turn either returns an entry, returns null (empty
        // stack and root_cursor == roots.len), or makes monotonic progress
        // (pops a frame, advances a finite dir iterator, or starts the next
        // root, incrementing root_cursor). Stack depth is bounded by max_depth;
        // root_cursor only increases toward roots.items.len.
        while (true) { // tiger:allow:unbounded-loop terminates when stack drains and roots consumed
            // Pop frames whose post-order entry was already emitted.
            if (self.stack.items.len > 0) {
                const top = &self.stack.items[self.stack.items.len - 1];
                if (top.post_emitted) {
                    self.popFrame(io);
                    continue;
                }
            }
            // If stack empty, start next root.
            if (self.stack.items.len == 0) {
                self.last_was_pre_dir = false;
                const maybe = try self.startNextRoot(io);
                if (maybe) |entry| {
                    self.entries_emitted += 1;
                    assert(self.entries_emitted <= self.config.max_entries);
                    self.last_was_pre_dir = (entry.kind == .directory and entry.visit == .pre);
                    return entry;
                }
                // startNextRoot may push a frame without emitting (post-only order).
                // If stack is still empty, all roots are exhausted.
                if (self.stack.items.len == 0) return null;
                continue; // frame was pushed; drive nextFromStack.
            }
            // Advance one step on the current stack.
            self.last_was_pre_dir = false;
            const maybe = try self.nextFromStack(io);
            if (maybe) |entry| {
                self.entries_emitted += 1;
                assert(self.entries_emitted <= self.config.max_entries);
                self.last_was_pre_dir = (entry.kind == .directory and entry.visit == .pre);
                return entry;
            }
            // nextFromStack returned null (frame popped or post emit queued).
        }
    }

    /// Tell the walker not to descend into the most recently emitted entry,
    /// if it was a directory in pre-order. No-op otherwise.
    pub fn pruneCurrent(self: *Walker) void {
        assert(self.stack.items.len <= self.config.max_depth);
        self.prune_current = true;
    }

    /// Free all owned memory; close all open Dir handles on the stack.
    /// Safe to call multiple times. Must be called even if `next` errored.
    pub fn deinit(self: *Walker, io: std.Io) void {
        assert(self.stack.items.len <= self.config.max_depth);
        while (self.stack.items.len > 0) {
            self.popFrame(io);
        }
        assert(self.stack.items.len == 0);
        for (self.roots.items) |root| self.allocator.free(root.path);
        self.roots.deinit(self.allocator);
        self.path_buf.deinit(self.allocator);
        self.error_path_buf.deinit(self.allocator);
        if (self.visited) |*v| v.deinit();
        self.stack.deinit(self.allocator);
    }

    /// Full path of the entry behind the per-entry error the most recent next()
    /// returned: a directory cycle, or a directory that failed to open during
    /// descent. Owned by the walker; the returned slice is valid only until the
    /// next next() call. Returns null when the last next() named no specific
    /// entry (a limit error, or a successful call).
    pub fn errorPath(self: *const Walker) ?[]const u8 {
        assert(self.stack.items.len <= self.config.max_depth);
        if (!self.error_path_valid) return null;
        assert(self.error_path_buf.items.len > 0);
        return self.error_path_buf.items;
    }

    /// Path of the directory that triggered the most recent
    /// error.DirectoryCycle from next(). Owned by the walker; valid only until
    /// the next next() call. Empty before any cycle is detected. Delegates to
    /// errorPath(); consumers call it only after error.DirectoryCycle.
    pub fn cyclePath(self: *const Walker) []const u8 {
        assert(self.stack.items.len <= self.config.max_depth);
        assert(self.config.cycle_mode == .ancestors or !self.error_path_valid);
        return self.errorPath() orelse &.{};
    }

    /// Record `path` as the offending entry for a later errorPath()/cyclePath()
    /// call. Marks the buffer valid only on success; OOM leaves it invalid so
    /// the accessors report null/empty rather than a stale path.
    fn setErrorPath(self: *Walker, path: []const u8) void {
        assert(path.len > 0);
        assert(self.stack.items.len <= self.config.max_depth);
        self.error_path_valid = false;
        self.error_path_buf.clearRetainingCapacity();
        self.error_path_buf.appendSlice(self.allocator, path) catch {
            self.error_path_buf.clearRetainingCapacity();
            return;
        };
        self.error_path_valid = true;
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Pop the top frame: close its dir handle and restore path_buf.
    fn popFrame(self: *Walker, io: std.Io) void {
        assert(self.stack.items.len > 0);
        var frame = self.stack.pop().?;
        assert(frame.path_len_on_entry <= self.path_buf.items.len);
        freeSortedEntries(self.allocator, &frame);
        self.path_buf.items.len = frame.path_len_on_entry;
        frame.dir.close(io);
        assert(self.path_buf.items.len == frame.path_len_on_entry);
    }

    /// Push a new frame; path_buf must already contain the dir's full path.
    fn descendInto(
        self: *Walker,
        io: std.Io,
        path_len_on_entry: usize,
        dir_path_len: usize,
        dir: std.Io.Dir,
        depth: u16,
        root_index: u32,
        pending_post: bool,
        fs_id: ?directory.FileSystemId,
    ) !void {
        assert(self.stack.items.len < self.config.max_depth);
        assert(depth <= self.config.max_depth);
        assert(dir_path_len >= path_len_on_entry);
        var frame = Frame{
            .dir = dir,
            .iterator = dir.iterate(),
            .depth = depth,
            .path_len_on_entry = path_len_on_entry,
            .dir_path_len = dir_path_len,
            .pending_post = pending_post,
            .post_emitted = false,
            .root_index = root_index,
            .sorted_entries = null,
            .sorted_index = 0,
            .fs_id = fs_id,
        };
        // Pre-register symlink targets in the global visited set only under
        // .ancestors_and_visited: scan symlinks and add their followed targets
        // so a real dir reached via both a real path and a not-followed symlink
        // is visited once. Never for follow_all (the symlink IS the path) and
        // never for .ancestors (which re-walks distinct-path aliases).
        const reg = (self.config.cycle_mode == .ancestors_and_visited) and
            (self.config.symlinks != .follow_all);
        // Collect entries when sorting is requested or when the visited-set
        // pre-registration needs to run (both consume the iterator up front).
        const collect = self.config.sort_children or
            (self.config.cycle_mode == .ancestors_and_visited);
        if (collect) {
            try collectAndPreprocess(
                self.allocator,
                io,
                &frame,
                self.config.skip_dot_entries,
                self.config.sort_children,
                reg,
                if (reg) &self.visited else null,
            );
        }
        try self.stack.append(self.allocator, frame);
        assert(self.stack.items.len > 0);
    }

    /// Start traversing the next root from the roots queue.
    fn startNextRoot(self: *Walker, io: std.Io) !?Entry {
        assert(self.stack.items.len == 0);
        assert(self.root_cursor <= self.roots.items.len);
        if (self.root_cursor >= self.roots.items.len) return null;
        const root = self.roots.items[self.root_cursor];
        self.root_cursor += 1;
        assert(root.path.len > 0);
        self.path_buf.items.len = 0;
        try self.path_buf.appendSlice(self.allocator, root.path);
        const path_len = self.path_buf.items.len;
        const basename = std.fs.path.basename(root.path);
        const bn_start = if (path_len >= basename.len) path_len - basename.len else 0;
        assert(bn_start <= path_len);
        // Try opening as a directory (follows symlinks if follow_initial=true).
        const dir = std.Io.Dir.cwd().openDir(io, root.path, .{ .iterate = true }) catch {
            // Not a directory (or a symlink to a non-directory with follow_initial).
            // Emit as a non-directory leaf.
            return buildEntry(self.path_buf.items, bn_start, .file, 0, .pre, null, null);
        };
        // Capture root device for stay_on_filesystem.
        if (self.config.stay_on_filesystem) {
            if (directory.FileSystemId.fromDir(dir)) |fs_id| {
                self.current_root_dev = fs_id.device;
            } else |_| {
                self.current_root_dev = null;
            }
        }
        return self.startRootDir(io, path_len, bn_start, dir);
    }

    /// Open a root directory and push its frame; emit pre-order if needed.
    fn startRootDir(
        self: *Walker,
        io: std.Io,
        path_len: usize,
        bn_start: usize,
        dir: std.Io.Dir,
    ) !?Entry {
        assert(self.stack.items.len == 0);
        assert(dir.handle >= 0);
        assert(bn_start <= path_len);
        // Cycle bookkeeping for the root. Every non-.none mode records the
        // root's id in its frame so the descent stack is a complete ancestor
        // chain; .ancestors_and_visited additionally seeds the global set.
        var root_fs_id: ?directory.FileSystemId = null;
        switch (self.config.cycle_mode) {
            .none => {},
            .ancestors_and_visited => {
                if (self.visited) |*v| {
                    const fs_id = try directory.FileSystemId.fromDir(dir);
                    const gop = try v.getOrPut(fs_id);
                    if (gop.found_existing) {
                        dir.close(io);
                        return null;
                    }
                    root_fs_id = fs_id;
                }
            },
            .ancestors => {
                root_fs_id = directory.FileSystemId.fromDir(dir) catch null;
            },
        }
        const pending_post = (self.config.order != .pre);
        const emit_pre = (self.config.order != .post);
        const root_idx = if (self.root_cursor > 0) self.root_cursor - 1 else 0;
        try self.descendInto(io, 0, path_len, dir, 0, root_idx, pending_post, root_fs_id);
        if (emit_pre) {
            return buildEntry(self.path_buf.items, bn_start, .directory, 0, .pre, null, null);
        }
        return null;
    }

    /// Advance the top frame's iterator; descend or emit as appropriate.
    fn nextFromStack(self: *Walker, io: std.Io) !?Entry {
        assert(self.stack.items.len > 0);
        const frame_idx = self.stack.items.len - 1;
        const frame = &self.stack.items[frame_idx];
        // Get next child dirent.
        const maybe_de = try nextChildDirent(io, frame, self.config.skip_dot_entries);
        if (maybe_de == null) {
            return self.handleExhaustedFrame(io, frame_idx);
        }
        const de = maybe_de.?;
        return self.processChild(io, frame_idx, de);
    }

    /// Process a single child entry: decide whether to descend or emit.
    fn processChild(
        self: *Walker,
        io: std.Io,
        frame_idx: usize,
        de: DirEntry,
    ) !?Entry {
        assert(frame_idx < self.stack.items.len);
        assert(de.name.len > 0);
        const frame = &self.stack.items[frame_idx];
        const parent_path_len = frame.dir_path_len;
        // Build child path in path_buf.
        self.path_buf.items.len = parent_path_len;
        try self.path_buf.append(self.allocator, '/');
        try self.path_buf.appendSlice(self.allocator, de.name);
        const child_path_len = self.path_buf.items.len;
        const bn_start = parent_path_len + 1;
        const child_depth = frame.depth + 1;
        // Resolve effective kind based on symlink policy. For follow_all this
        // stats the symlink target via frame.dir so a link-to-file becomes a
        // leaf and only a link-to-dir descends.
        const eff_kind = resolveKind(frame.dir, de.name, de.kind, self.config.symlinks);
        const is_dir = (eff_kind == .directory);
        const stay = self.shouldStayAbove(de.kind, frame);
        if (!is_dir or stay) {
            return buildEntry(
                self.path_buf.items,
                bn_start,
                eff_kind,
                child_depth,
                .pre,
                null,
                frame.dir,
            );
        }
        // Descend: check depth cap.
        if (child_depth >= self.config.max_depth) {
            self.path_buf.items.len = parent_path_len;
            return error.DepthLimitExceeded;
        }
        return self.descendChildDir(io, frame_idx, child_depth, child_path_len, parent_path_len);
    }

    /// Open and push a child directory frame; emit pre-order if needed.
    fn descendChildDir(
        self: *Walker,
        io: std.Io,
        parent_frame_idx: usize,
        child_depth: u16,
        child_path_len: usize,
        parent_path_len: usize,
    ) !?Entry {
        assert(parent_frame_idx < self.stack.items.len);
        assert(child_depth > 0);
        assert(child_depth < self.config.max_depth);
        assert(child_path_len > parent_path_len);
        const child_path = self.path_buf.items[0..child_path_len];
        const child_dir = std.Io.Dir.cwd().openDir(
            io,
            child_path,
            .{ .iterate = true },
        ) catch |err| {
            // Record the child that failed to open so consumers can name the
            // exact path (e.g. grep's "Permission denied") before it is dropped.
            self.setErrorPath(self.path_buf.items[0..child_path_len]);
            self.path_buf.items.len = parent_path_len;
            return err;
        };
        // Cycle and cross-device filters. `skip` and `cycle` both close the dir
        // and restore path_buf; `cycle` additionally records the offending path
        // and surfaces error.DirectoryCycle. `proceed` carries the id to store.
        const child_fs_id = switch (self.classifyChildDir(child_dir)) {
            .skip => {
                child_dir.close(io);
                self.path_buf.items.len = parent_path_len;
                return null;
            },
            .cycle => {
                self.setErrorPath(self.path_buf.items[0..child_path_len]);
                child_dir.close(io);
                self.path_buf.items.len = parent_path_len;
                return error.DirectoryCycle;
            },
            .proceed => |id| id,
        };
        const pframe = &self.stack.items[parent_frame_idx];
        const root_index = pframe.root_index;
        const pending_post = (self.config.order != .pre);
        const emit_pre = (self.config.order != .post);
        const bn_start = parent_path_len + 1;
        try self.descendInto(
            io,
            parent_path_len,
            child_path_len,
            child_dir,
            child_depth,
            root_index,
            pending_post,
            child_fs_id,
        );
        if (emit_pre) {
            return buildEntry(
                self.path_buf.items,
                bn_start,
                .directory,
                child_depth,
                .pre,
                null,
                null,
            );
        }
        return null; // post-order: emit on unwind.
    }

    /// Classify an opened child dir: proceed (and carry its id), skip silently,
    /// or report an ancestor cycle. The caller closes the dir and restores
    /// path_buf on skip/cycle; this helper only inspects. The id is computed at
    /// most once and reused for the visited set, the ancestor scan, and the
    /// stay-on-filesystem check.
    fn classifyChildDir(
        self: *Walker,
        child_dir: std.Io.Dir,
    ) ChildOutcome {
        assert(child_dir.handle >= 0);
        assert(self.stack.items.len <= self.config.max_depth);
        const need_id = (self.config.cycle_mode != .none) or self.config.stay_on_filesystem;
        const fs_id: ?directory.FileSystemId = if (need_id)
            directory.FileSystemId.fromDir(child_dir) catch null
        else
            null;
        // Cycle detection first (mirrors the historical ordering so the
        // visited-set insert happens before the stay-on-filesystem check).
        switch (self.config.cycle_mode) {
            .none => {},
            .ancestors_and_visited => {
                if (self.visited) |*v| {
                    const id = fs_id orelse return .skip;
                    const gop = v.getOrPut(id) catch return .skip;
                    if (gop.found_existing) return .skip; // Already visited.
                }
            },
            .ancestors => {
                // Cannot verify identity: skip to guarantee termination.
                const id = fs_id orelse return .skip;
                // The stack IS the ancestor chain; its length is bounded by
                // max_depth, so this scan is bounded.
                assert(self.stack.items.len <= self.config.max_depth);
                for (self.stack.items) |frame| {
                    const aid = frame.fs_id orelse continue;
                    if (aid.device == id.device and aid.inode == id.inode) {
                        return .cycle;
                    }
                }
            },
        }
        // Stay-on-filesystem: skip a child on a different device.
        if (self.config.stay_on_filesystem) {
            if (self.current_root_dev) |root_dev| {
                if (fs_id) |id| {
                    if (id.device != root_dev) return .skip; // Cross device.
                }
            }
        }
        return .{ .proceed = fs_id };
    }

    /// Handle an exhausted frame: emit post-order or just pop.
    fn handleExhaustedFrame(self: *Walker, io: std.Io, frame_idx: usize) ?Entry {
        assert(frame_idx < self.stack.items.len);
        const frame = &self.stack.items[frame_idx];
        assert(!frame.post_emitted);
        assert(frame.dir_path_len >= frame.path_len_on_entry);
        if (!frame.pending_post) {
            self.popFrame(io);
            return null;
        }
        // Emit post-order entry. path_buf has this dir's full path.
        self.path_buf.items.len = frame.dir_path_len;
        const path = self.path_buf.items;
        const depth = frame.depth;
        const bn_start = basenameStart(path);
        frame.post_emitted = true; // Pop on next next() call.
        return buildEntry(path, bn_start, .directory, depth, .post, null, null);
    }

    /// Returns true if we should NOT descend due to stay_on_filesystem.
    /// For child entries, we compare device via the opened dir (handled in
    /// descendChildDir). This is a pre-check on the dirent kind only.
    fn shouldStayAbove(self: *Walker, kind: std.Io.File.Kind, frame: *const Frame) bool {
        // The actual device check happens in descendChildDir using fromDir.
        // Here we only skip based on non-directory kind (already handled by caller).
        _ = kind;
        _ = frame;
        if (!self.config.stay_on_filesystem) return false;
        // For stay_on_filesystem, the descendChildDir will check after opening.
        return false;
    }
};

// ============================================================================
// Module-level helpers
// ============================================================================

/// Resolve the effective kind of an entry based on symlink policy.
/// For no_follow / follow_cmdline: symlinks stay as .sym_link during
/// traversal (the follow_cmdline root is handled by startNextRoot with
/// follow_initial=true).
/// For follow_all: a symlink is classified by statting its target (following
/// the link). A target directory becomes .directory (the caller descends via
/// openDir, which follows the link); a non-directory target becomes that
/// target's kind (a leaf). When the target cannot be statted — broken link
/// (ENOENT) or a symlink chain loop (ELOOP) — the link itself is emitted as
/// a .sym_link leaf so the walk continues. Never returns an error.
///
/// `raw_kind` comes from the dirent's d_type. On filesystems that report
/// DT_UNKNOWN (no d_type support), a symlink arrives here as .unknown rather
/// than .sym_link, so it is passed through unfollowed even under follow_all;
/// such targets are not statted.
fn resolveKind(
    dir: std.Io.Dir,
    name: []const u8,
    raw_kind: std.Io.File.Kind,
    policy: SymlinkPolicy,
) std.Io.File.Kind {
    assert(name.len > 0);
    assert(name.len <= std.Io.Dir.max_path_bytes);
    if (raw_kind != .sym_link) return raw_kind;
    switch (policy) {
        .no_follow, .follow_cmdline => return .sym_link,
        .follow_all => return statTargetKind(dir, name),
    }
}

/// Stat the symlink `name` under `dir` following the link and return the
/// target's kind. On any stat failure (broken link, ELOOP chain loop, access
/// denied) return .sym_link so follow_all emits the link itself as a leaf.
/// Takes no io: this is an fd-relative syscall, mirroring
/// directory.FileSystemId.fromDir.
fn statTargetKind(dir: std.Io.Dir, name: []const u8) std.Io.File.Kind {
    assert(name.len > 0);
    assert(name.len <= std.Io.Dir.max_path_bytes);
    var name_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const name_z: [:0]const u8 = name_buf[0..name.len :0];
    const mode = statModeAt(dir.handle, name_z) catch return .sym_link;
    return kindFromMode(mode);
}

/// fstatat/statx the entry `name_z` relative to `fd`, following symlinks
/// (flags=0), and return its st_mode. Mirrors the statx/fstatat pattern in
/// src/common/file.zig. Returns an error on any syscall failure.
fn statModeAt(fd: std.posix.fd_t, name_z: [*:0]const u8) !u32 {
    assert(fd >= 0);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(fd, name_z, 0, linux.STATX.BASIC_STATS, &sx);
        if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
        const mode: u32 = sx.mode;
        return mode;
    } else {
        var stat_buf: std.c.Stat = undefined;
        const result = std.c.fstatat(fd, name_z, &stat_buf, 0);
        if (result != 0) return error.StatFailed;
        const mode: u32 = @intCast(stat_buf.mode);
        return mode;
    }
}

/// Map a stat st_mode to std.Io.File.Kind via the S_IFMT type bits. Mirrors
/// the switch in src/common/file.zig.
fn kindFromMode(mode: u32) std.Io.File.Kind {
    // No precondition: `mode` is OS-returned data, not an internal invariant, and
    // the else branch maps any unrecognized S_IFMT value (including 0) to
    // .unknown, so this mapping is total over all u32 inputs.
    return switch (mode & std.c.S.IFMT) {
        std.c.S.IFREG => .file,
        std.c.S.IFDIR => .directory,
        std.c.S.IFCHR => .character_device,
        std.c.S.IFBLK => .block_device,
        std.c.S.IFIFO => .named_pipe,
        std.c.S.IFLNK => .sym_link,
        std.c.S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };
}

/// Free sorted entries for a frame.
fn freeSortedEntries(allocator: std.mem.Allocator, frame: *Frame) void {
    if (frame.sorted_entries) |*entries| {
        for (entries.items) |de| allocator.free(de.name);
        entries.deinit(allocator);
        frame.sorted_entries = null;
    }
}

/// Collect children of a directory frame into sorted_entries.
/// When sort_entries=true, sort by name ascending.
/// When register_symlink_targets=true, scan all symlinks and add their
/// followed targets to visited before normal iteration. This prevents a
/// real directory from being descended when a not-followed symlink
/// pointing to it appears in the same directory listing.
fn collectAndPreprocess(
    allocator: std.mem.Allocator,
    io: std.Io,
    frame: *Frame,
    skip_dot: bool,
    sort_entries: bool,
    register_symlink_targets: bool,
    visited: ?*?directory.FileSystemIdSet,
) !void {
    assert(frame.sorted_entries == null);
    var entries: std.ArrayListUnmanaged(DirEntry) = .empty;
    errdefer {
        for (entries.items) |de| allocator.free(de.name);
        entries.deinit(allocator);
    }
    while (try frame.iterator.next(io)) |entry| {
        if (skip_dot and isDotEntry(entry.name)) continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);
        try entries.append(allocator, DirEntry{ .name = name_copy, .kind = entry.kind });
    }
    if (sort_entries) {
        std.mem.sort(DirEntry, entries.items, {}, struct {
            fn cmp(_: void, a: DirEntry, b: DirEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.cmp);
    }
    // Pre-register symlink targets in the cycle set so that real dirs
    // pointing to the same inode are skipped when the iterator gets to them.
    // Only done when we are NOT following symlinks (no_follow / follow_cmdline)
    // — in follow_all mode the symlink IS the traversal path and must not be
    // pre-emptively blocked by cycle detection.
    if (register_symlink_targets) {
        if (visited) |v_ptr| {
            if (v_ptr.*) |*v| {
                for (entries.items) |de| {
                    if (de.kind != .sym_link) continue;
                    // Open the symlink target (follows symlink) to get its id.
                    const target_dir = frame.dir.openDir(io, de.name, .{}) catch continue;
                    const fs_id = directory.FileSystemId.fromDir(target_dir) catch {
                        target_dir.close(io);
                        continue;
                    };
                    target_dir.close(io);
                    _ = v.getOrPut(fs_id) catch {};
                }
            }
        }
    }
    frame.sorted_entries = entries;
    assert(frame.sorted_index == 0);
}

/// Get the next child entry from a frame (sorted or live iterator).
fn nextChildDirent(
    io: std.Io,
    frame: *Frame,
    skip_dot: bool,
) !?DirEntry {
    if (frame.sorted_entries) |*entries| {
        if (frame.sorted_index >= entries.items.len) return null;
        const de = entries.items[frame.sorted_index];
        frame.sorted_index += 1;
        assert(frame.sorted_index <= @as(u32, @intCast(entries.items.len)));
        return de;
    }
    // Live iterator.
    while (true) { // tiger:allow:unbounded-loop terminates at EOF when dir iterator returns null
        const maybe = try frame.iterator.next(io);
        if (maybe == null) return null;
        const entry = maybe.?;
        if (skip_dot and isDotEntry(entry.name)) continue;
        return DirEntry{ .name = entry.name, .kind = entry.kind };
    }
}

/// Build an Entry from components.
fn buildEntry(
    path: []const u8,
    basename_start: usize,
    kind: std.Io.File.Kind,
    depth: u16,
    visit: @FieldType(Entry, "visit"),
    stat: ?Stat,
    parent_dir: ?std.Io.Dir,
) Entry {
    assert(basename_start <= path.len);
    return Entry{
        .path = path,
        .basename = path[basename_start..],
        .kind = kind,
        .depth = depth,
        .visit = visit,
        .stat = stat,
        .parent_dir = parent_dir,
    };
}

/// Returns true if the name is "." or "..".
fn isDotEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// Return the byte offset of the last '/' + 1 in path, or 0 if none.
fn basenameStart(path: []const u8) usize {
    assert(path.len > 0);
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return i + 1;
    }
    return 0;
}

const assert = std.debug.assert;

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
    while (true) { // tiger:allow:unbounded-loop bounded walker; exhausts at null
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

test "walker: ancestors_and_visited prevents infinite loop on symlink loop" {
    // §5.1 #9, companion for the default cycle_mode: a symlink pointing back
    // into its own ancestor creates a cycle. Under .ancestors_and_visited
    // (the historical detect_cycles=true default, still used by mv/rm), the
    // global visited set catches the loop silently — next() must never
    // surface error.DirectoryCycle here, and every path is emitted once.
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
        .cycle_mode = .ancestors_and_visited,
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
    // Would fail loudly with error.DirectoryCycle if this mode incorrectly
    // started raising the per-entry error instead of silently deduping.
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

test "walker: ancestors mode raises DirectoryCycle on an ancestor symlink loop" {
    // GNU fts semantics: under .ancestors, a directory cycle is only a cycle
    // when it matches an ANCESTOR on the current descent path. Detection
    // surfaces as a re-entrant error.DirectoryCycle from next(), and
    // cyclePath() names the offending symlink path. The walk must still
    // terminate promptly (not spin toward max_entries/max_depth) and must
    // still emit the sibling real file.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(io, tmp.dir, "real.txt");
    try tmp.dir.createDirPath(io, "subdir");
    // loop -> .. (symlink to parent, creating an ancestor cycle).
    try tmp.dir.symLink(io, "..", "subdir/loop", .{});

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .cycle_mode = .ancestors,
        .order = .pre,
        .sort_children = true, // deterministic: real.txt before subdir.
        .max_entries = 50,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_real = false;
    var cycle_errors: u32 = 0;
    var terminated = false;
    var calls: u32 = 0;
    while (calls < 20) : (calls += 1) { // tiger:allow bounded by explicit calls cap
        const result = w.next(io);
        if (result) |maybe_entry| {
            const entry = maybe_entry orelse {
                terminated = true;
                break;
            };
            if (std.mem.eql(u8, entry.basename, "real.txt")) saw_real = true;
        } else |err| switch (err) {
            error.DirectoryCycle => {
                cycle_errors += 1;
                // cyclePath() is valid until the next next() call, so it must
                // be inspected right here.
                try testing.expect(std.mem.endsWith(u8, w.cyclePath(), "subdir/loop"));
            },
            else => return err,
        }
    }
    // RED against a stub/broken implementation: no cycle would ever be
    // raised (cycle_errors stays 0) or the walk would never terminate
    // (terminated stays false, calls hits the 20 cap).
    try testing.expectEqual(@as(u32, 1), cycle_errors);
    try testing.expect(saw_real);
    try testing.expect(terminated);
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

test "walker: follow_all + ancestors_and_visited dedups the sibling alias" {
    // §5.1 #13, companion for the default cycle_mode: with follow_all (-L),
    // all symlinks are followed. The root holds BOTH the real target_dir and
    // link_to_dir -> target_dir (siblings, same inode). Under
    // .ancestors_and_visited (the historical global-visited-set default),
    // whichever of the two is visited first is fully descended and the other
    // is skipped ENTIRELY — not just deduped per-file: the second alias's
    // directory entry itself must never be emitted. This pins the exact
    // dedup behavior mv/rm depend on continuing unchanged.
    //
    // Without sort_children the visit order is the filesystem's readdir
    // order, which differs across platforms (it descended the link on
    // x86_64 but the real dir on arm CI, making saw_via_link flaky).
    // sort_children=true makes the order deterministic: "link_to_dir" sorts
    // before "target_dir", so the symlink is descended first on every
    // platform, and "target_dir" is therefore the alias that gets skipped.
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
        .cycle_mode = .ancestors_and_visited,
        .order = .pre,
        .sort_children = true,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_via_link = false;
    var saw_target_dir_direct = false;
    while (try w.next(io)) |entry| {
        // When link_to_dir is followed, we expect to see target_file.txt
        // under the link_to_dir path.
        if (std.mem.eql(u8, entry.basename, "target_file.txt") and
            std.mem.find(u8, entry.path, "link_to_dir") != null)
        {
            saw_via_link = true;
        }
        // "target_dir" reached directly (not through the symlink) must never
        // surface as its own entry: it was already visited via link_to_dir.
        if (std.mem.eql(u8, entry.basename, "target_dir")) {
            saw_target_dir_direct = true;
        }
    }
    // Must have followed the symlink and descended into it.
    // RED: stub returns null, saw_via_link stays false.
    try testing.expect(saw_via_link);
    // RED against a wrong .ancestors_and_visited implementation that dedups
    // per-file instead of at the whole-subtree/directory-entry level, or
    // that stops deduping aliases at all: saw_target_dir_direct would
    // flip true.
    try testing.expect(!saw_target_dir_direct);
}

test "walker: follow_all + ancestors mode walks both sibling alias directories" {
    // GNU fts semantics: .ancestors only prunes when a directory matches an
    // ANCESTOR on the current descent path. link_to_dir and target_dir are
    // SIBLINGS, not ancestor/descendant, so under .ancestors both aliases
    // must be independently, fully walked — unlike the
    // .ancestors_and_visited companion above, which dedups this exact
    // fixture down to a single alias.
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
        .cycle_mode = .ancestors,
        .order = .pre,
        .sort_children = true,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_via_link = false;
    var saw_target_dir_direct = false;
    while (try w.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "target_file.txt") and
            std.mem.find(u8, entry.path, "link_to_dir") != null)
        {
            saw_via_link = true;
        }
        if (std.mem.eql(u8, entry.basename, "target_dir")) {
            saw_target_dir_direct = true;
        }
    }
    // RED against a wrong implementation that still applies a global
    // visited-set under .ancestors: saw_target_dir_direct would stay false,
    // just like the .ancestors_and_visited companion above.
    try testing.expect(saw_via_link);
    try testing.expect(saw_target_dir_direct);
}

// Issue #69, T1: under the DEFAULT cycle_mode (deliberately omitted below so
// the struct default `.ancestors_and_visited` is exercised) with no_follow
// symlinks, a real directory that has a SIBLING symlink pointing at it must
// still be fully walked. collectAndPreprocess pre-registers every symlink's
// followed target (dev, ino) into the shared visited set before any child is
// classified, so classifyChildDir later finds the real dir's id already
// `found_existing` and skips it -- this is the issue #69 bug. GNU rm/mv do
// no such inode dedup between a symlink and an unrelated sibling real
// directory: the real dir must be walked pre AND post (order=.both) and its
// child file must appear, while the symlink itself is emitted once as a
// .sym_link leaf and never descended (no emitted path contains "link/").
test "walker: default cycle_mode does not skip a real dir aliased by a sibling symlink" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "real", .kind = .dir },
        .{ .path = "real/inner.txt", .kind = .file },
        .{ .path = "link", .kind = .symlink, .symlink_target = "real" },
    });

    // cycle_mode deliberately omitted -- pins the struct DEFAULT.
    var w = try Walker.init(testing.allocator, .{
        .symlinks = .no_follow,
        .order = .both,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_link_leaf = false;
    var saw_real_pre = false;
    var saw_real_post = false;
    var saw_inner_file = false;
    var saw_path_under_link = false;
    while (try w.next(io)) |entry| {
        if (std.mem.find(u8, entry.path, "link/") != null) saw_path_under_link = true;
        if (std.mem.eql(u8, entry.basename, "link")) {
            saw_link_leaf = true;
            try testing.expectEqual(std.Io.File.Kind.sym_link, entry.kind);
        }
        if (std.mem.eql(u8, entry.basename, "real") and entry.kind == .directory) {
            if (entry.visit == .pre) saw_real_pre = true;
            if (entry.visit == .post) saw_real_post = true;
        }
        if (std.mem.eql(u8, entry.basename, "inner.txt")) saw_inner_file = true;
    }
    // RED today: collectAndPreprocess pre-registers "real"'s (dev,ino) via
    // the "link" sibling before classifyChildDir ever sees "real", so
    // saw_real_pre/saw_real_post/saw_inner_file stay false.
    try testing.expect(saw_link_leaf);
    try testing.expect(!saw_path_under_link);
    try testing.expect(saw_real_pre);
    try testing.expect(saw_real_post);
    try testing.expect(saw_inner_file);
}

// Issue #69, T2: the pre-registration bug above is order-independent -- the
// whole directory listing is drained by collectAndPreprocess before any
// child is classified, so it does not matter whether the symlink's name
// sorts before or after the real directory's name. Pin both orders.
fn checkSiblingAliasWalkedRegardlessOfSortOrder(
    real_name: []const u8,
    link_name: []const u8,
) !void {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const real_inner_path = try std.fmt.allocPrint(testing.allocator, "{s}/inner.txt", .{real_name});
    defer testing.allocator.free(real_inner_path);

    try buildTree(io, tmp.dir, &.{
        .{ .path = real_name, .kind = .dir },
        .{ .path = real_inner_path, .kind = .file },
        .{ .path = link_name, .kind = .symlink, .symlink_target = real_name },
    });

    // cycle_mode deliberately omitted -- pins the struct DEFAULT.
    var w = try Walker.init(testing.allocator, .{
        .symlinks = .no_follow,
        .order = .both,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_real_pre = false;
    var saw_inner_file = false;
    while (try w.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, real_name) and entry.kind == .directory and
            entry.visit == .pre)
        {
            saw_real_pre = true;
        }
        if (std.mem.eql(u8, entry.basename, "inner.txt")) saw_inner_file = true;
    }
    // RED today regardless of alphabetical order: real dir's id gets
    // pre-registered via the sibling symlink before classification, in
    // either sort order, since the whole listing is drained up front.
    try testing.expect(saw_real_pre);
    try testing.expect(saw_inner_file);
}

test "walker: default cycle_mode sibling-alias skip is order-independent (a_real, z_link)" {
    // Symlink name sorts AFTER the real dir name alphabetically.
    try checkSiblingAliasWalkedRegardlessOfSortOrder("a_real", "z_link");
}

test "walker: default cycle_mode sibling-alias skip is order-independent (z_real, a_link)" {
    // Symlink name sorts BEFORE the real dir name alphabetically.
    try checkSiblingAliasWalkedRegardlessOfSortOrder("z_real", "a_link");
}

test "walker: ancestors mode terminates a mutual sibling symlink loop" {
    // Termination trace (from the approved design): a/link_b -> ../b and
    // b/link_a -> ../a form a 2-node mutual cycle with no shared ancestor
    // relationship at the root. Descending a -> a/link_b (id=b, not an
    // ancestor of a/link_b) succeeds; descending further into
    // a/link_b/link_a resolves to id=a, which IS an ancestor (frame "a" is
    // still on the stack) -> pruned as error.DirectoryCycle. Symmetrically
    // for b -> b/link_a -> b/link_a/link_b. Each of a's and b's contents is
    // walked exactly twice (once via its real path, once via the other's
    // alias) before the second walk immediately hits its own cycle. A
    // broken ancestor scan (e.g. one that never matches, or one that
    // degenerates into a global visited set) would produce a different
    // entry/error count than the exact trace pinned below.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "a", .kind = .dir },
        .{ .path = "b", .kind = .dir },
        .{ .path = "a/link_b", .kind = .symlink, .symlink_target = "../b" },
        .{ .path = "b/link_a", .kind = .symlink, .symlink_target = "../a" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .cycle_mode = .ancestors,
        .order = .pre,
        .sort_children = true, // deterministic: "a" walked before "b".
        .max_entries = 50,
        .max_depth = 20,
    });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var dir_entries: u32 = 0;
    var cycle_errors: u32 = 0;
    var saw_a = false;
    var saw_b = false;
    var saw_link_b_under_a = false;
    var saw_link_a_under_b = false;
    var terminated = false;
    var calls: u32 = 0;
    while (calls < 30) : (calls += 1) { // tiger:allow bounded by explicit calls cap
        const result = w.next(io);
        if (result) |maybe_entry| {
            const entry = maybe_entry orelse {
                terminated = true;
                break;
            };
            if (entry.kind == .directory) {
                dir_entries += 1;
                if (std.mem.eql(u8, entry.basename, "a")) saw_a = true;
                if (std.mem.eql(u8, entry.basename, "b")) saw_b = true;
                if (std.mem.eql(u8, entry.basename, "link_b") and
                    std.mem.find(u8, entry.path, "/a/link_b") != null) saw_link_b_under_a = true;
                if (std.mem.eql(u8, entry.basename, "link_a") and
                    std.mem.find(u8, entry.path, "/b/link_a") != null) saw_link_a_under_b = true;
            }
        } else |err| switch (err) {
            error.DirectoryCycle => {
                cycle_errors += 1;
                // First cycle closes back through "a" (a/link_b/link_a);
                // second closes back through "b" (b/link_a/link_b), since
                // sort_children guarantees "a" is walked before "b".
                if (cycle_errors == 1) {
                    try testing.expect(std.mem.endsWith(u8, w.cyclePath(), "a/link_b/link_a"));
                } else if (cycle_errors == 2) {
                    try testing.expect(std.mem.endsWith(u8, w.cyclePath(), "b/link_a/link_b"));
                }
            },
            else => return err,
        }
    }
    // RED against a wrong implementation: an ancestor scan that never fires
    // would spin toward the 30-call cap (terminated stays false); one that
    // over-fires (degenerates to a global visited set) would report fewer
    // than 5 directory entries (one alias silently skipped, mirroring the
    // .ancestors_and_visited fixture above) and fewer than 2 cycle errors.
    try testing.expect(terminated);
    try testing.expectEqual(@as(u32, 5), dir_entries); // root, a, a/link_b, b, b/link_a
    try testing.expectEqual(@as(u32, 2), cycle_errors);
    try testing.expect(saw_a);
    try testing.expect(saw_b);
    try testing.expect(saw_link_b_under_a);
    try testing.expect(saw_link_a_under_b);
}

test "walker: follow_all emits a symlink-to-file as a file leaf" {
    // Issue #47: follow_all must stat the symlink target and classify by the
    // target's real kind. A symlink -> regular file must be emitted as a
    // .file leaf, NOT mapped to .directory (which makes the walker try
    // openDir and raise error.NotDir out of next(), poisoning the walk).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "real_file.txt", .kind = .file },
        .{ .path = "link_to_file", .kind = .symlink, .symlink_target = "real_file.txt" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .cycle_mode = .ancestors_and_visited,
        .order = .pre,
        .sort_children = true,
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
    // RED: the symlink-to-file is mapped to .directory, so next() calls
    // openDir which fails with error.NotDir; the `try` in drainEntries
    // propagates it and this line fails the test.
    try drainEntries(&w, io, testing.allocator, &entries);

    var saw_link_entry = false;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.basename, "link_to_file")) {
            saw_link_entry = true;
            // GREEN pins the target kind: symlink -> file is a .file leaf.
            try testing.expectEqual(std.Io.File.Kind.file, e.kind);
        }
    }
    // The walker must actually emit the link, not silently drop it.
    try testing.expect(saw_link_entry);
}

test "walker: follow_all descends symlink-to-dir and leafs symlink-to-file" {
    // Issue #47: the stat-based resolveKind must still descend a
    // symlink-to-directory while leafing a symlink-to-file in the same dir.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "target_dir", .kind = .dir },
        .{ .path = "target_dir/inside.txt", .kind = .file },
        .{ .path = "real_file.txt", .kind = .file },
        .{ .path = "link_to_dir", .kind = .symlink, .symlink_target = "target_dir" },
        .{ .path = "link_to_file", .kind = .symlink, .symlink_target = "real_file.txt" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .cycle_mode = .ancestors_and_visited,
        .order = .pre,
        .sort_children = true,
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
    // RED: link_to_file mapped to .directory -> openDir NotDir out of next().
    try drainEntries(&w, io, testing.allocator, &entries);

    var descended_dir_link = false;
    var leafed_file_link = false;
    for (entries.items) |e| {
        // Dir symlink was followed: we see inside.txt under the link path.
        if (std.mem.eql(u8, e.basename, "inside.txt") and
            std.mem.find(u8, e.path, "link_to_dir") != null)
        {
            descended_dir_link = true;
        }
        // File symlink leafs correctly as a .file.
        if (std.mem.eql(u8, e.basename, "link_to_file")) {
            leafed_file_link = true;
            try testing.expectEqual(std.Io.File.Kind.file, e.kind);
        }
    }
    try testing.expect(descended_dir_link);
    try testing.expect(leafed_file_link);
}

test "walker: follow_all emits a broken symlink as a sym_link leaf" {
    // Issue #47: a dangling symlink under follow_all must not poison the
    // walk. It is emitted as the link itself (.sym_link) and the walk
    // continues past it.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "good.txt", .kind = .file },
        .{ .path = "broken_link", .kind = .symlink, .symlink_target = "no_such_target" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .cycle_mode = .ancestors_and_visited,
        .order = .pre,
        .sort_children = true,
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
    // RED: broken link mapped to .directory -> openDir ENOENT out of next().
    try drainEntries(&w, io, testing.allocator, &entries);

    var saw_good = false;
    var saw_broken = false;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.basename, "good.txt")) saw_good = true;
        if (std.mem.eql(u8, e.basename, "broken_link")) {
            saw_broken = true;
            try testing.expectEqual(std.Io.File.Kind.sym_link, e.kind);
        }
    }
    // Walk not aborted: good.txt still emitted; broken link surfaced as link.
    try testing.expect(saw_good);
    try testing.expect(saw_broken);
}

test "walker: follow_all does not hang or error on a symlink loop" {
    // Issue #47: mutually-referential symlinks must not hang or raise an
    // error out of next(). The kernel ELOOP is swallowed and each link is
    // emitted as a .sym_link leaf. max_depth is set small as a bound-hitting
    // safety knob so any cycle terminates fast and deterministically.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, tmp.dir, &.{
        .{ .path = "plain.txt", .kind = .file },
        .{ .path = "loop_a", .kind = .symlink, .symlink_target = "loop_b" },
        .{ .path = "loop_b", .kind = .symlink, .symlink_target = "loop_a" },
    });

    var w = try Walker.init(testing.allocator, .{
        .symlinks = .follow_all,
        .cycle_mode = .ancestors_and_visited,
        .order = .pre,
        .sort_children = true,
        .max_depth = 8,
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
    // RED: openDir follows the chain -> error.SymLinkLoop out of next().
    try drainEntries(&w, io, testing.allocator, &entries);

    var saw_plain = false;
    var saw_loop_a = false;
    var saw_loop_b = false;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.basename, "plain.txt")) saw_plain = true;
        if (std.mem.eql(u8, e.basename, "loop_a")) {
            saw_loop_a = true;
            try testing.expectEqual(std.Io.File.Kind.sym_link, e.kind);
        }
        if (std.mem.eql(u8, e.basename, "loop_b")) {
            saw_loop_b = true;
            try testing.expectEqual(std.Io.File.Kind.sym_link, e.kind);
        }
    }
    try testing.expect(saw_plain);
    try testing.expect(saw_loop_a);
    try testing.expect(saw_loop_b);
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
    defer tmp.dir.setFilePermissions(
        io,
        "locked",
        std.Io.File.Permissions.fromMode(0o700),
        .{},
    ) catch {};

    var w = try Walker.init(testing.allocator, .{ .order = .pre });
    defer w.deinit(io);

    const root = try tmpPath(testing.allocator, io, &tmp, "");
    defer testing.allocator.free(root);
    try w.addRoot(root);

    var saw_file_a = false;
    var saw_file_z = false;
    var saw_io_error = false;

    // Drive the walker; on an I/O error continue from the next call.
    while (true) { // tiger:allow:unbounded-loop bounded walker; exhausts at null
        const result = w.next(io);
        if (result) |maybe_entry| {
            if (maybe_entry == null) break;
            const entry = maybe_entry.?;
            if (std.mem.eql(u8, entry.basename, "file_a.txt")) saw_file_a = true;
            if (std.mem.eql(u8, entry.basename, "file_z.txt")) saw_file_z = true;
        } else |err| {
            // Any I/O error from the locked dir; record it and keep going.
            _ = @intFromError(err);
            saw_io_error = true;
        }
    }

    // Must have seen an I/O error for locked/. RED: stub returns null, never errors.
    try testing.expect(saw_io_error);
    // Must have recovered and emitted file_a.txt and file_z.txt.
    try testing.expect(saw_file_a);
    try testing.expect(saw_file_z);
}
