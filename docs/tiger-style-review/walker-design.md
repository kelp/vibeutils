# Bounded Iterative Directory Walker — Design

**Status:** Design proposal
**Scope:** Replace direct recursion in `cp`, `mv`, `chmod`, `chown`, `rm`, `du`, `grep`, `find` (walk only — find's expression-parser recursion is out of scope).
**Target:** Zig 0.16.0 / Tiger Style compliance.

---

## 1. Goals & Non-Goals

### Goals

1. Eliminate every `walk*`/`*Recursive` self-call across the eight call-sites.
2. Provide a single iterative depth-first walker keyed off an explicit stack of frames, with a hard depth cap enforced by assertion (Tiger Style "every loop must have a fixed upper bound").
3. Support pre-order, post-order, and both-order traversal in one type — `rm` and `chmod` need bottom-up; `du` needs accumulation on unwind; `find` needs pre-order with optional post-order (`-depth`).
4. Centralize symlink policy (P/H/L), cycle detection (dev+inode), and cross-device boundary checks so each caller just sets flags.
5. Allow per-entry pruning (`find -prune`, grep's `--exclude-dir`, `du --max-depth`-style early-stop) without unwinding mid-iteration.

### Non-Goals

- Fixing find's `parseOr`/`parseUnary`/`parsePrimary` mutual recursion. That is a separate Pratt-parser refactor.
- Replacing `std.Io.Dir.Walker` — we want a *more controllable* walker than stdlib's, owning the stack, depth, cycle set, and visit-cap.
- Making the walker "parallel" or async — single-threaded, synchronous iteration.

---

## 2. API Sketch

Module: `/home/tcole/code/vibeutils/src/common/walker.zig`. Exposed via `src/common/lib.zig` as `pub const walker = @import("walker.zig");`.

### 2.1 Configuration

```zig
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

pub const WalkConfig = struct {
    /// Hard upper bound on stack depth. Assertion fires if exceeded.
    /// Default 1024 — POSIX PATH_MAX gives ~256 components; real filesystems
    /// almost never exceed ~50. 1024 is generous safety margin.
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
```

### 2.2 Entry

```zig
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

/// Lightweight stat snapshot to avoid forcing every caller to redo work
/// the walker already did. Reuses `common.file.FileInfo` shape but kept
/// inline to avoid circular dep.
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
```

### 2.3 Walker Struct

```zig
pub const Walker = struct {
    allocator: std.mem.Allocator,
    config: WalkConfig,

    /// Explicit stack of in-progress directory frames. Never exceeds
    /// config.max_depth — asserted on every push.
    stack: std.ArrayListUnmanaged(Frame),

    /// Cycle detector (dev, inode). Initialized iff config.detect_cycles.
    /// Owned by the walker.
    visited: ?common.directory.FileSystemIdSet,

    /// Root operand queue. The walker drains this before declaring done.
    /// Allows a single walker instance to traverse multiple command-line
    /// operands without reinit (cp src1 src2 src3 dest/).
    roots: std.ArrayListUnmanaged(RootSpec),

    /// Device of the *current* root, for stay_on_filesystem.
    /// Re-captured per root.
    current_root_dev: ?u64,

    /// Scratch buffer for the path of the currently-emitted entry.
    /// Reused across calls to avoid allocator churn.
    path_buf: std.ArrayListUnmanaged(u8),

    /// Running total of entries emitted. Bounds-checked against
    /// config.max_entries on every `next()`.
    entries_emitted: u64,
};

const Frame = struct {
    dir: std.Io.Dir,           // owned: closed when popped
    iterator: std.Io.Dir.Iterator,
    depth: u16,
    path_len_on_entry: usize,  // for trimming path_buf on pop
    pending_post: bool,        // emit this dir post-order on unwind?
    root_index: u32,           // which root this descended from
};

const RootSpec = struct {
    path: []const u8,          // owned by allocator
    follow_initial: bool,      // resolved -H/-L command-line logic
};
```

### 2.4 Lifecycle Methods

```zig
/// Initialize an empty walker. Add roots with `addRoot`, then drive
/// with `next`. Must be paired with `deinit`.
pub fn init(
    allocator: std.mem.Allocator,
    config: WalkConfig,
) error{OutOfMemory}!Walker;

/// Add a root path to walk. May be called multiple times before or
/// between `next()` calls. Each root is processed in insertion order.
pub fn addRoot(self: *Walker, path: []const u8) error{OutOfMemory}!void;

/// Advance to the next entry. Returns null when the walk is complete.
/// Errors are *per-entry*: cycle detection, depth-cap, and entries-cap
/// failures are asserted (programming errors); only I/O errors surface.
/// Callers handle EACCES/ENOENT on individual entries by inspecting
/// the entry — see `next_with_errors` below for the alternate shape.
pub fn next(self: *Walker, io: std.Io) !?Entry;

/// Tell the walker not to descend into the most recently emitted entry,
/// if it was a directory in pre-order. No-op otherwise. Used by find's
/// -prune, grep's --exclude-dir, du's --max-depth pruning, and cp's
/// "destination is inside source" guard.
pub fn pruneCurrent(self: *Walker) void;

/// Free all owned memory; close all open Dir handles still on the stack.
/// Safe to call multiple times. Must be called even if `next` errored.
pub fn deinit(self: *Walker, io: std.Io) void;
```

### 2.5 Why an iterator, not a callback

- Callers retain their own control-flow context. `rm` can hold its
  `had_errors`/interactive-cancel state in normal locals; no closure
  capture acrobatics.
- Errors flow naturally through Zig's `try`/`catch` — no callback
  return-code negotiation.
- Tiger Style prefers data over control: the walker exposes data
  (the `Entry`), not control inversion.
- The `pruneCurrent` hook gives find/grep/du the mid-walk subtree
  decisions they need without callbacks.
- Matches the shape of `std.Io.Dir.Walker` (already used in
  `src/common/lib.zig:335` for the writerStreaming lint test), so it
  will feel idiomatic.

### 2.6 Tiger Style Compliance

- **No recursion.** Every traversal step is an iteration over
  `self.stack`. No function calls itself.
- **Hard bounds.** `max_depth` (1024 default) asserts at every push;
  `max_entries` (16Mi default) asserts at every emit. Both are *config*
  parameters so tests can lower them to exercise the cap paths.
- **Assertions ≥ 2 per function.** Each public method asserts pre- and
  post-conditions: `init` asserts `config.max_depth > 0` and
  `config.max_entries > 0`; `next` asserts the stack invariant
  (`stack.len <= config.max_depth`) before and after; `pruneCurrent`
  asserts the top frame is a pre-order directory.
- **Static-ish memory.** All buffers grow on init/addRoot; the hot
  `next()` path reuses `path_buf` and `stack` without per-call allocs
  (except for opening directory handles).
- **Function shape.** Each method ≤ 70 lines. `next()` is the longest;
  it splits into `nextFromStack`, `descendInto`, and `popFrame` helpers
  to stay under the limit.
- **Pair positive/negative assertions.** E.g. `assert(self.stack.items.len > 0)`
  before popping, `assert(self.stack.items.len < self.config.max_depth)`
  before pushing.

---

## 3. Per-Utility Migration Plan

### 3.1 `chmod` (`src/chmod.zig:402` `chmodRecursive`)

The simplest migration and the canonical first target. chmod's recursion
is post-order (process children before parent so we don't lock ourselves
out by tightening directory perms first).

Mapping:
- `WalkConfig{ .order = .post, .symlinks = <map from -P/-H/-L>, .stay_on_filesystem = false, .detect_cycles = true }`.
- Driver loop: `while (try walker.next(io)) |entry| switch (entry.kind) { .directory, else => applyModeToPath(entry.path, ...) }`.
- Symlinks under `-P`/`-H during recursion` are skipped because the walker emits them as `.sym_link` entries that chmod can ignore in its switch.
- Under `-L`, the walker descends into symlinked dirs; chmod just applies mode to whatever is emitted.

Red flag: chmod currently treats "open the dir before chmod'ing it so
new perms can't lock us out" as a per-frame invariant. The walker
already opens the dir on descent, so by the time the post-order emit
happens, the iterator is closed (post-order fires on pop). chmod
applies the mode after the dir handle is gone — same ordering as today.
Acceptable.

### 3.2 `chown` (`src/chown.zig:346` `chownRecursive`)

Near-identical shape to chmod. Same `Order.post`. Adds the `-x`/
`stay_on_filesystem` flag. The current code threads `effective_root_dev`
through recursion manually — the walker subsumes this.

Mapping:
- `WalkConfig{ .order = .post, .symlinks = ..., .stay_on_filesystem = options.no_cross_device }`.
- For `entry.kind == .sym_link` with `symlinks == .no_follow`, chown still needs to `lchown` the symlink itself — the walker emits it; chown handles it directly.

No red flags. Migrate second to validate that two near-identical
utilities both fit the API cleanly.

### 3.3 `rm` (`src/rm.zig:328` `removeDirectoryRecursive`)

Post-order: must delete children before `deleteDir`. Interactive
prompts complicate things.

Mapping:
- `WalkConfig{ .order = .post, .symlinks = .no_follow, .stay_on_filesystem = options.no_cross_device, .detect_cycles = true }`.
- On `entry.visit == .pre` (only seen if we set `order = .both`): not used; rm wants pure post-order, *but* interactive `-i` prompts ask the user *before* descending. See open question §5.1.
- On `entry.visit == .post` for a directory: call `deleteDir(io, entry.path)`.
- On any non-directory: call `removeItem(allocator, io, entry.path, ...)`.

Red flag: rm's `-i` prompt on the *directory itself* fires *before*
descending in current code (lines 418–422). With pure post-order, the
walker has already entered the directory before rm sees it. Solution:
use `order = .both`, prompt on the pre-order emit, and call
`pruneCurrent()` if the user says no. This is the strongest argument
for `pruneCurrent` being a first-class API method.

Second red flag: `error.InteractiveUserCancelled` currently unwinds
the recursion to skip the parent's `deleteDir`. With the iterator,
rm needs to *track* which directories had a cancelled child and not
delete those. Concrete fix: keep a `cancelled_dirs: HashSet([]const u8)`
keyed by depth-0-parent-path; on `.post` for a directory, check if any
descendant was cancelled and skip `deleteDir` if so. This is a real
behavior change in code shape but identical user-facing semantics.

### 3.4 `du` (`src/du.zig:413` `calculateDu`)

Pre-order traversal that accumulates size on the *unwind*. Hardlink
dedup. Filesystem boundaries.

Mapping:
- `WalkConfig{ .order = .both, .symlinks = <from --dereference flags>, .stay_on_filesystem = options.one_file_system, .detect_cycles = true }`.
- Caller maintains a parallel stack of `[]u64 subtree_sizes`. On each
  pre-order emit of a directory, push 0. On each entry (file or
  post-order dir), look up the file's contribution and add it to
  `subtree_sizes[entry.depth]`. On a post-order dir emit, pop the
  size, add it to `subtree_sizes[entry.depth - 1]`, and print the
  total for this dir.
- Hardlink dedup uses the same `dev, ino` from `entry.stat` (already
  populated by walker — saves a stat call).

Red flag: du currently calls `printEntry` for files when `--all` is
set. That's straightforward in the iterator. But du also handles
`--separate-dirs` by tracking direct-files-only vs subtree size. The
"parallel stack" approach above handles this: maintain two stacks
(`subtree_sizes` and `direct_file_sizes`), update both on each entry,
print the appropriate one on post-order pop.

Second red flag: du uses `apparent_size` mode where dirs contribute 0.
That's purely a caller-side decision once it has `entry.stat` — no
walker change needed.

### 3.5 `cp` (`src/cp.zig:599` `copyDirectory` / `copyDirectoryContents`)

The most complex migration *aside from find*. cp needs to:
1. Create the destination directory.
2. Copy each child (file copy, recursive dir copy, or symlink create).
3. Preserve mode/timestamps/ownership on dirs *after* their contents
   are written.

Mapping:
- `WalkConfig{ .order = .both, .symlinks = <from -L/-P>, .stay_on_filesystem = options.one_file_system, .detect_cycles = true }`.
- Caller maintains a parallel stack of destination paths. On
  pre-order emit of a directory, compute `dest = join(dest_root, entry.path[root_len..])` and `createDir(dest)`. Push `dest` onto stack.
- On file emit (always `.pre`), look up the parent dest from the
  parallel stack and copy file → file.
- On post-order emit of a directory, apply mode preservation (currently
  done inline at lines 612–623), then pop the dest stack.

Red flag: cp's current code passes `hinted_overwrite: *bool` deep
through mutual recursion — this is a per-call "did the user say yes
to overwrite all?" flag. With the iterator, the caller already owns
this state in a local. Simplification, not a problem.

Second red flag: `copySingleFile` (called from `copyDirectoryContents`)
handles non-directory entries including hardlinks (`-l`), symlinks
(`-s`), etc. The iterator emits the entry; the caller dispatches on
`entry.kind` exactly as before. The `--link`/`--symbolic-link` flags
don't change traversal — they change per-file action. Clean fit.

Third red flag: cp's same-source-and-dest detection. The current code
uses path-string heuristics; with the walker we can pass the dest's
device+inode in and have the walker refuse to descend into it
(equivalent to a programmatic `pruneCurrent` on the pre-order emit
of any entry whose `stat.dev, stat.inode` equals the dest's). This is
*better* than the current behavior, but is a scope-creep — leave it
as a follow-up.

### 3.6 `mv` (`src/mv.zig:521` `copyDirectoryRecursive`)

This is the cross-device fallback path only (when rename(2) returned
EXDEV). It is a strict subset of cp's logic — same shape, no
preserve-mode-only-after-children dance is critical because mv
follows up with `deleteTree(source)`.

Mapping: identical to cp's, but with simpler options (no `-l`/`-s`,
no `hinted_overwrite`).

No red flags. After cp is migrated, mv should be near-mechanical:
replace `copyDirectoryRecursive` with a walker driver, and the
existing `copyFileCross` and inline `createDir` calls become the
per-entry action.

### 3.7 `grep` (`src/grep.zig:1017` `searchDirectory`)

Pre-order. Three concerns: glob filtering on filenames (`--include`/
`--exclude`), directory-name filtering (`--exclude-dir`), and
symlink-following (`-R`/`--dereference-recursive` vs `-r`).

Mapping:
- `WalkConfig{ .order = .pre, .symlinks = if (opts.dereference_recursive) .follow_all else .no_follow, .detect_cycles = true }`.
- Driver: `while (try walker.next(io)) |entry|`:
  - `.directory` → if `shouldExcludeDir(entry.basename, opts)`, `walker.pruneCurrent()`. Otherwise no action (descent happens automatically).
  - `.file` → if `shouldIncludeFile(entry.basename, opts)`, run `processFile`.
  - `.sym_link` under `-R` → walker already followed; no extra logic.
  - `.sym_link` under `-r` → walker emits but doesn't descend; grep ignores symlinks-to-files in this mode (current behavior preserved).

Red flag: grep's existing `searchDirectory` opens symlinked files
directly to handle "is this a file-symlink or a dir-symlink?" without
stat'ing first (lines 1062–1077). The walker requires us to stat
upfront to make the descend decision. That is a *real* extra
stat-per-symlink in `-R` mode. Mitigation: the walker emits
`entry.stat` populated, so grep no longer re-stats for size limits etc.
Net change: roughly neutral.

### 3.8 `find` (`src/find.zig:2577` `walkPath`)

The hardest. find drives pre-order *or* post-order (`-depth`),
honors `-prune` to skip subtrees, sorts children (`-sorted`), and
runs the entire expression-evaluator per entry.

Mapping:
- `WalkConfig{ .order = if (config.depth_first) .post else .pre, .symlinks = ..., .stay_on_filesystem = config.xdev, .sort_children = config.sorted, .detect_cycles = true }`.
- Driver: per-entry, call `evaluate(...)` (the existing function, after
  its parser-recursion fix). If `was_pruned`, call
  `walker.pruneCurrent()`.

Red flags:
1. **maxdepth/mindepth.** find has both. The walker has `max_depth`
   as a hard *safety* bound (1024); `maxdepth` is a find-specific
   *behavioral* bound. Solution: the driver compares `entry.depth`
   against `config.maxdepth` and calls `pruneCurrent` when over.
   `mindepth` is purely an emit filter on the caller side.
2. **Evaluate-on-error.** find evaluates the expression even on
   `openDir` failure (lines 2666–2680). With the iterator, that
   error becomes a walker-level event the caller can't see. Solution:
   the walker surfaces per-directory open errors via `next()` as
   regular errors; the find driver catches them, evaluates the
   expression for the failed dir, then continues.
3. **Find's `evaluate` is itself recursive** (lines 1991–2003). Out
   of scope for *this* walker change. The walker doesn't help with
   that — the expression parser/evaluator needs its own iterative
   refactor (Pratt parser + bytecode evaluator). The walker only
   removes the *outer* recursion in `walkPath`.

---

## 4. Order of Migration

Sequence chosen to minimize blast radius and validate the API early:

1. **`chmod`** — simplest post-order. Reveals any blockers in the
   `Order.post` path. The unit tests are mature (≥30 chmod tests).
2. **`chown`** — proves the cross-device flag and confirms two
   utilities with near-identical shape fit cleanly. If chown
   doesn't fit, the API is wrong.
3. **`rm`** — first real test of `pruneCurrent` and the post-order
   "skip parent if child was cancelled" pattern. Validates the
   error-flow shape.
4. **`du`** — first test of `Order.both` and parallel-stack
   accumulation pattern. Tightens the stat-caching story.
5. **`grep`** — first symlink-policy test (especially `-R`/`follow_all`).
   Validates `pruneCurrent` on `--exclude-dir`.
6. **`cp`** — most complex post-order path. By this point the API
   is battle-tested; cp's parallel-stack-of-destination-paths is
   straightforward.
7. **`mv`** — trivial after cp.
8. **`find`** — last, because:
   - It needs every walker feature (sorted, prune, both orders,
     stay_on_fs).
   - Its `evaluate()` mutual recursion is a separate refactor that
     should happen before or alongside this migration. If it happens
     after, find migrates with the existing recursive `evaluate` and
     the walker change is just the outer loop.

Each migration is its own PR — never combine two utility migrations
into one commit, even though the per-utility delta is small. Tiger
Style commits stay reviewable.

---

## 5. Test Strategy

### 5.1 Walker unit tests (`src/common/walker.zig` tests embedded)

Fixture builder: a helper that creates a temp tree from a struct
literal, e.g.:

```zig
const tree = TreeFixture{
    .root = .{
        .dirs = &.{
            .{ .name = "a", .files = &.{ "x.txt", "y.txt" } },
            .{ .name = "b", .dirs = &.{ .{ .name = "c", .files = &.{ "z.txt" } } } },
        },
    },
};
```

Test cases (each ≤30 lines per Tiger Style function-shape guidance):

1. **Empty directory.** Walker visits root, emits nothing else.
2. **Pre-order ordering.** Tree → exact emit sequence.
3. **Post-order ordering.** Same tree → reversed-leaf-first sequence.
4. **Both-order: pre+post.** Each dir emitted twice in the right order.
5. **`max_depth` assertion fires.** Construct a 5-deep tree, set
   `max_depth = 3`, verify the assertion (use a separate
   `WalkConfig{ .max_depth = 3 }` and expect a panic / abort in
   the test runner via `std.testing.expectPanic`-equivalent).
6. **`max_entries` assertion fires.** Same shape with deeply fanned
   tree.
7. **`pruneCurrent` on pre-order dir.** Tree with subtree, prune it,
   verify subtree contents are not emitted.
8. **`pruneCurrent` on non-dir is a no-op.** No crash, no skip.
9. **Cycle detection.** Build a tree, then `symLink(real_dir, real_dir/loop)`.
   With `follow_all`, expect the walker to mark and skip, not loop
   forever. Cap entries low to make the test fail loudly if the
   detector breaks.
10. **`stay_on_filesystem` honored.** Hard to test portably without
    privileges; use a fake stat shim or skip on non-Linux. Linux test
    can `mount --bind /tmp/somewhere /tmp/tree/mounted` under
    privileged_test infrastructure.
11. **Symlink policy: no_follow.** Symlink emitted, never descended.
12. **Symlink policy: follow_cmdline.** Top-level symlink followed;
    deeper symlinks not.
13. **Symlink policy: follow_all.** All symlinks followed.
14. **`sort_children`.** Verify alphabetic emit order.
15. **Multiple roots.** `addRoot("a"); addRoot("b");` — verify a is
    fully drained before b begins.
16. **`deinit` after mid-walk error.** Open a tree, walk halfway,
    return from the loop without finishing, ensure `deinit(io)`
    closes all open Dir handles (verify via fd-leak detection if
    available, or by capacity assertion).
17. **Path/basename lifetime invariant.** Capture `entry.path` slice
    pointer, call `next` once more, verify the buffer was reused
    (regression test for "callers must dupe").

### 5.2 Per-utility regression tests

For each migrated utility, every existing test in its `.zig` file
must continue to pass without modification. This is the *primary*
contract: the walker change is internal refactor, not a behavior
change.

Additionally, add three new tests per utility:
- **Deep tree.** Build a 100-level deep tree; verify the utility
  completes without stack overflow (the whole point of the change).
- **Cycle exposure.** Build a symlink cycle; verify the utility
  exits cleanly rather than infinite-looping. Some utilities
  (chmod -P) didn't follow symlinks anyway and won't loop; for
  those the test just verifies non-failure.
- **Width stress.** Build a wide tree (10k files in one dir);
  verify the utility's emit ordering and accumulated state are
  correct.

### 5.3 Integration tests

The integration test suite under `tests/utilities/` should be
re-run for each migrated utility. No new integration tests needed
— the user-visible behavior is unchanged.

---

## 6. Open Questions

These are the places where the audit's "one walker fixes all"
thesis is at risk:

### 6.1 rm's interactive `-i` on directories

rm prompts *before* descending into a directory under `-i`. The
post-order walker has already descended by the time the dir is
emitted. **Resolution:** use `order = .both`, prompt on pre-order
emit, call `pruneCurrent` on "no". The walker API specifically
supports this pattern, and it's the strongest argument for
`pruneCurrent` being public.

This implies rm's driver becomes:
- On `.pre` for a directory: maybe-prompt; on cancel, `pruneCurrent()`.
- On `.pre` for a file: maybe-prompt; on cancel, do nothing (file
  isn't a subtree to prune).
- On `.post` for a directory: `deleteDir`.

Acceptable, but it does mean the rm driver has more states than the
existing recursive code. Trade-off: explicit > implicit.

### 6.2 find's expression evaluator recursion

The walker only solves the outer `walkPath` recursion. find's
`evaluate` calls itself for `-and`/`-or`/`-not` (lines 1991–2003)
and the parser has mutual recursion at lines 840/846/1991-2003.
This is acknowledged out-of-scope, but it means find's migration
won't fully unblock Tiger Style compliance until a separate Pratt
parser refactor lands. The walker design isn't blocked by this —
they're independent.

### 6.3 cp's "destination inside source" guard

cp must detect when the destination path is inside the source tree
(infinite copy). Today this is a string-prefix check. With the
walker, a cleaner solution is to stat the destination, store
its `(dev, inode)`, and have the walker prune any entry that
matches. But this requires either a custom `pruneCurrent` based on
a stat predicate (not in the API) or the cp driver calling
`pruneCurrent()` itself based on each entry's stat. The latter
fits the existing API; recommended.

### 6.4 du's `--max-depth` vs walker's `max_depth`

These are not the same. du's `--max-depth` is a *display* filter
(don't print children below depth N, but still accumulate them).
The walker's `max_depth` is a *safety* assertion. du's driver
ignores `max_depth` (set it to 1024) and filters its own emit
based on `entry.depth`. No conflict, but worth documenting in the
walker's doc-comment.

### 6.5 Symlink stat semantics

The walker's `Entry.stat` is populated by `stat` (follow) or `lstat`
(no_follow) depending on policy. Callers expecting one or the other
need to know which got used. Resolution: add an `Entry.stat_followed: bool`
field, or document clearly that `entry.kind` reflects the chosen mode
(.sym_link only when no_follow; otherwise the underlying type). The
latter is more idiomatic and matches stdlib `Dir.Iterator` behavior.

### 6.6 Error reporting per entry

Today, each utility prints "cannot open '%s'" / "cannot stat '%s'"
with utility-specific prefix. The walker can either:
- (a) suppress errors and skip silently, leaving the utility to
  redo stat/open and print its own error.
- (b) emit a special `.error` entry kind with the error code.
- (c) return errors from `next()`.

Recommendation: (c) — `next()` returns `!?Entry`. On error, the
caller decides whether to print, mark `had_errors`, and continue.
The walker internally re-enters the next iteration on the next call.
This requires `next()` to be re-entrant after error (its state must
not be poisoned). Worth a unit test specifically: "next returns
error, call next again, walker continues from sibling."

### 6.7 grep's symlink stat overhead

Discussed in §3.7. Net stat cost may slightly increase under
`-R`/`follow_all`. If benchmarks show regression, add a "lazy stat"
fast path: walker exposes only `entry.kind` from the dirent's
d_type (no stat needed) until the caller requests `entry.stat`,
which then does the stat on demand. Not required for v1.

---

## 7. Memory & Performance Back-of-Envelope

- Stack frame size: ~80 bytes (Dir handle + iterator + depth + flags +
  path-len marker). At 1024 max depth: ~80 KB worst-case stack. Fine.
- Path buffer: grows to PATH_MAX (4 KB on Linux). One allocation per
  walker, amortized across all entries.
- Cycle set: one `HashMap(FileSystemId, void)` entry per *directory
  descended into*. For a 1M-file tree with avg fanout 10, ~100K dir
  entries → ~2.5 MB. Acceptable; opt-out via `detect_cycles = false`
  for callers that don't care (du with `dereference_mode = .none` and
  no symlinks).
- Per-entry cost: one `openDir` + iterator next + one stat (cached in
  Entry). Roughly the same as current recursive code, which also did
  one openDir + iterator + per-entry stat.
- Sort path: one `dupe` per child name + sort. Only when
  `sort_children = true`. ~negligible for find with --sort.

---

## 8. Implementation Sketch (for the implementer agent)

A subsequent implementer agent should:

1. Create `src/common/walker.zig` implementing the API in §2.
2. Export from `src/common/lib.zig`: `pub const walker = @import("walker.zig");`.
3. Write the unit tests in §5.1 *first* (red), then implement the
   walker (green). TDD per CLAUDE.md.
4. Migrate utilities one PR at a time, in the order of §4. Each PR
   includes: utility change + walker tweaks if any + existing tests
   still passing + the three new regression tests per §5.2.
5. Run the full Tiger Style audit (`/tiger-style:tiger-check`) after
   each migration to verify the recursion is actually gone.

---

## 9. Summary Table

| Utility | Order   | Symlinks      | Cross-dev | Prune used? | Notes                                                      |
| ------- | ------- | ------------- | --------- | ----------- | ---------------------------------------------------------- |
| chmod   | post    | P/H/L config  | no        | no          | First migration; canonical example                         |
| chown   | post    | P/H/L config  | yes (-x)  | no          | Validates two-utility API stability                        |
| rm      | both    | no_follow     | yes (-x)  | yes (-i)    | Drives `pruneCurrent` API requirement                      |
| du      | both    | from --deref  | yes (-x)  | yes (depth) | Parallel-stack accumulation pattern                        |
| grep    | pre     | -r/-R config  | no        | yes         | First symlink-follow test                                  |
| cp      | both    | -L/-P config  | yes (-x)  | (yes recommend) | Parallel dest-stack; mode-preserve on post                 |
| mv      | both    | follow_all    | n/a       | no          | Cross-device fallback only; subset of cp                   |
| find    | pre or post | -H/-L config | yes (-xdev) | yes (-prune) | Last; expression evaluator recursion separate scope |
