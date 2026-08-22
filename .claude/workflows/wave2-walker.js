export const meta = {
  name: 'wave2-walker',
  description:
    'TDD pipeline for the walker cycle_mode split (issues #60/#61 + chmod). Phase "red": scout walker internals, pin reference behavior (GNU du/chown on Linux, BSD chmod on macOS if GNU lacks -L), write FAILING CLI-level tests for du -L loops and chown/chmod -RL sibling aliases in parallel, review, verify RED on both platforms. Phase "green": implement the walker cycle_mode enum + consumer migrations, verify-gate loop, walker characterization-test hardening with sabotage-proven teeth, Tiger check, adversarial code review, full-suite final gates on both platforms. Commits by the orchestrator (signing policy).',
  whenToUse:
    'One-shot workflow for the wave-2 walker change. Dispatch phase:"red", commit tests, phase:"green", commit the implementation.',
  phases: [
    { title: 'Scout', detail: 'walker internals + pin GNU/BSD reference behavior (sonnet)' },
    { title: 'Author tests', detail: 'parallel failing tests for du/chown/chmod (opus, test-writer)' },
    { title: 'Review tests', detail: 'parallel reviews until APPROVED (opus)' },
    { title: 'Red check', detail: 'red for the right reason, macOS + Linux (sonnet)' },
    { title: 'Implement', detail: 'walker cycle_mode + consumer migration (opus, implementer)' },
    { title: 'Verify gate', detail: 'full unit + scoped integration ×3 + lint (haiku)' },
    { title: 'Harden walker tests', detail: 'revise/add walker unit tests, sabotage-prove teeth (opus/sonnet)' },
    { title: 'Tiger check', detail: 'scan diff for NEW violations (haiku)' },
    { title: 'Code review', detail: 'adversarial review until APPROVED (fable)' },
    { title: 'Final verify', detail: 'ONCE: full suites on macOS AND Linux (haiku)' },
  ],
};

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
log(`args: type=${typeof args} phase=${a.phase || 'red'} design=${(a.design || '').length} chars`);
const phaseArg = a.phase || 'red';

// Briefing from the red-phase scout (run wf_ea787636-fd1), embedded so the
// green phase reuses it without re-scouting.
const EMBEDDED_BRIEFING = {"walker_internals": "File: src/common/walker.zig (1976 lines total).\n\nWalkConfig (lines 32-66):\n```\npub const WalkConfig = struct {\n    max_depth: u16 = 1024,\n    max_entries: u64 = 1 << 24,\n    symlinks: SymlinkPolicy = .no_follow,\n    order: Order = .pre,\n    stay_on_filesystem: bool = false,\n    sort_children: bool = false,\n    detect_cycles: bool = true,\n    skip_dot_entries: bool = true,\n};\n```\nSymlinkPolicy (18-25): `no_follow` (-P), `follow_cmdline` (-H, depth-0 only), `follow_all` (-L).\nOrder (29): `pre`, `post`, `both`.\n\nFrame (private struct, lines 130-151) \u2014 the traversal stack element, no fs_id field yet:\n```\nconst Frame = struct {\n    dir: std.Io.Dir,                 // Owned: closed when popped.\n    iterator: std.Io.Dir.Iterator,\n    depth: u16,                      // Depth of THIS directory (not children).\n    path_len_on_entry: usize,        // path_buf length before this dir's name.\n    dir_path_len: usize,             // path_buf length of this dir's full path.\n    pending_post: bool,\n    post_emitted: bool,\n    root_index: u32,\n    sorted_entries: ?std.ArrayListUnmanaged(DirEntry),\n    sorted_index: u32,\n};\n```\nWalker struct fields (172-203): allocator, config, stack: ArrayListUnmanaged(Frame), visited: ?directory.FileSystemIdSet, roots, root_cursor, current_root_dev, path_buf, entries_emitted, prune_current, last_was_pre_dir. `visited` is Non-null iff config.detect_cycles (init, lines 211-234): `if (config.detect_cycles) { visited = directory.FileSystemIdSet.init(allocator); }`.\n\nnext() signature (254): `pub fn next(self: *Walker, io: std.Io) !?Entry` \u2014 fully INFERRED error set, no named `WalkError`. No `error{...}` anywhere in the file except addRoot/init's `error{OutOfMemory}`. Concrete errors observed flowing out today: error.DepthLimitExceeded (explicit, line 514), error.EntryLimitExceeded (explicit, line 258), error.NotDir/ENOENT/etc from openDir (descendChildDir, line 533-540 `catch |err| { self.path_buf.items.len = parent_path_len; return err; }`), plus whatever FileSystemId.fromDir/getOrPut raise (OOM, SystemResources). Adding `error.DirectoryCycle` requires no error-set declaration change anywhere \u2014 it just needs to appear in a `return`/`try` inside next()'s call graph and Zig's inference picks it up; every existing `catch |err| switch (err) { ..., else => ... }` call site (du/chmod already have such switches; chown does not, see below) will route it through their `else` arm unless a new arm is added.\n\nstartRootDir (441-460, exact text):\n```\nfn startRootDir(\n    self: *Walker,\n    io: std.Io,\n    path_len: usize,\n    bn_start: usize,\n    dir: std.Io.Dir,\n) !?Entry {\n    assert(self.stack.items.len == 0);\n    assert(dir.handle >= 0);\n    assert(bn_start <= path_len);\n    // Cycle detection for the root.\n    if (self.config.detect_cycles) {\n        if (self.visited) |*v| {\n            const fs_id = try directory.FileSystemId.fromDir(dir);\n            const gop = try v.getOrPut(fs_id);\n            if (gop.found_existing) {\n                dir.close(io);\n                return null;\n            }\n        }\n    }\n    const pending_post = (self.config.order != .pre);\n    const emit_pre = (self.config.order != .post);\n    const root_idx = if (self.root_cursor > 0) self.root_cursor - 1 else 0;\n    try self.descendInto(io, 0, path_len, dir, 0, root_idx, pending_post);\n    if (emit_pre) {\n        return buildEntry(self.path_buf.items, bn_start, .directory, 0, .pre, null, null);\n    }\n    return null;\n}\n```\nNote: a root-level cycle hit silently returns `null` (treated as \"no more roots\"), NOT an error \u2014 different from childDirRejected's silent skip-and-continue. The design's \".ancestors mode stores the root's fs_id in its frame\" needs a Frame.fs_id write-back after descendInto is called here (descendInto doesn't currently know fs_id; the id was computed locally in this function via `FileSystemId.fromDir(dir)` only inside the `if (config.detect_cycles)` block \u2014 under `.ancestors` mode with detect_cycles no longer gating this, fs_id must be computed unconditionally for any non-`.none` mode and threaded into the pushed Frame).\n\nchildDirRejected (577-616, exact text):\n```\nfn childDirRejected(\n    self: *Walker,\n    io: std.Io,\n    child_dir: std.Io.Dir,\n    parent_path_len: usize, // tiger:allow:usize-arch mirrors path_buf.items.len\n) bool {\n    assert(parent_path_len <= self.path_buf.items.len);\n    // Cycle detection.\n    if (self.config.detect_cycles) {\n        if (self.visited) |*v| {\n            const fs_id = directory.FileSystemId.fromDir(child_dir) catch {\n                child_dir.close(io);\n                self.path_buf.items.len = parent_path_len;\n                return true;\n            };\n            const gop = v.getOrPut(fs_id) catch {\n                child_dir.close(io);\n                self.path_buf.items.len = parent_path_len;\n                return true;\n            };\n            if (gop.found_existing) {\n                child_dir.close(io);\n                self.path_buf.items.len = parent_path_len;\n                return true; // Cycle: skip.\n            }\n        }\n    }\n    // Check stay_on_filesystem for the opened child dir.\n    if (self.config.stay_on_filesystem) {\n        if (self.current_root_dev) |root_dev| {\n            const child_dev_id = directory.FileSystemId.fromDir(child_dir) catch null;\n            if (child_dev_id != null and child_dev_id.?.device != root_dev) {\n                child_dir.close(io);\n                self.path_buf.items.len = parent_path_len;\n                return true; // Cross device: skip.\n            }\n        }\n    }\n    return false;\n}\n```\nCalled from descendChildDir (line 543): `if (self.childDirRejected(io, child_dir, parent_path_len)) { return null; }`. Its `bool` return type is a problem for the new design: `.ancestors` mode needs to signal \"raise error.DirectoryCycle\" vs \"silently skip\" (stay_on_filesystem) vs \"proceed\" \u2014 a plain bool can no longer distinguish these three outcomes, so the function signature (or its caller) must change (e.g. return an error union, or a tri-state enum, or have descendChildDir do the ancestor scan itself before calling this helper). This is exactly where `fs_id` gets computed once \u2014 `FileSystemId.fromDir(child_dir)` is already called here; the design's \"hoist so the id is computed once and stored in the frame via the descend path\" means this computed fs_id (already in hand at this call site) should be threaded into descendInto -> Frame.fs_id instead of only living in a local variable, and reused for the ancestor scan without a second syscall.\n\ncollectAndPreprocess (749-807 doc + 755-807 body, exact text):\n```\n/// Collect children of a directory frame into sorted_entries.\n/// When sort_entries=true, sort by name ascending.\n/// When register_symlink_targets=true, scan all symlinks and add their\n/// followed targets to visited before normal iteration. This prevents a\n/// real directory from being descended when a not-followed symlink\n/// pointing to it appears in the same directory listing.\nfn collectAndPreprocess(\n    allocator: std.mem.Allocator,\n    io: std.Io,\n    frame: *Frame,\n    skip_dot: bool,\n    sort_entries: bool,\n    register_symlink_targets: bool,\n    visited: ?*?directory.FileSystemIdSet,\n) !void {\n    ...\n    while (try frame.iterator.next(io)) |entry| { ... collect into entries ... }\n    if (sort_entries) { std.mem.sort(...); }\n    // Pre-register symlink targets in the cycle set so that real dirs\n    // pointing to the same inode are skipped when the iterator gets to them.\n    // Only done when we are NOT following symlinks (no_follow / follow_cmdline)\n    // \u2014 in follow_all mode the symlink IS the traversal path and must not be\n    // pre-emptively blocked by cycle detection.\n    if (register_symlink_targets) {\n        if (visited) |v_ptr| {\n            if (v_ptr.*) |*v| {\n                for (entries.items) |de| {\n                    if (de.kind != .sym_link) continue;\n                    const target_dir = frame.dir.openDir(io, de.name, .{}) catch continue;\n                    const fs_id = directory.FileSystemId.fromDir(target_dir) catch { target_dir.close(io); continue; };\n                    target_dir.close(io);\n                    _ = v.getOrPut(fs_id) catch {};\n                }\n            }\n        }\n    }\n    frame.sorted_entries = entries;\n    assert(frame.sorted_index == 0);\n}\n```\nCall site in descendInto (374-394):\n```\nif (self.config.sort_children or self.config.detect_cycles) {\n    const reg = self.config.detect_cycles and\n        (self.config.symlinks != .follow_all);\n    try collectAndPreprocess(\n        self.allocator, io, &frame, self.config.skip_dot_entries,\n        self.config.sort_children, reg,\n        if (self.config.detect_cycles) &self.visited else null,\n    );\n}\n```\nPer design: pre-registration (`reg`) must fire ONLY under `.ancestors_and_visited` (not `.ancestors`), same `symlinks != .follow_all` guard preserved.\n\ninit() precondition to add per design: `assert(config.symlinks != .follow_all or config.cycle_mode != .none)` (mirrors today's implicit requirement that follow_all needs a cycle mechanism; today's field is `detect_cycles: bool = true` with no such explicit assert \u2014 it is only enforced by convention/comments, e.g. chmod.zig's own comment \"Terminates symlink cycles under -L\").\n\nFileSystemId / FileSystemIdSet (src/common/directory.zig, lines 1-70, full text read): `FileSystemIdSet = std.HashMap(FileSystemId, void, FileSystemId.Context, default_max_load_percentage)`; `FileSystemId{ device: u64, inode: u64 }`; `FileSystemId.fromDir(dir: std.Io.Dir) !FileSystemId` uses `linux.statx(fd, \"\", AT.EMPTY_PATH, ...)` on Linux and `std.c.fstat` elsewhere \u2014 this is the exact primitive `.ancestors` mode's bounded ancestor scan must call per candidate ancestor Frame (comparing `.device`/`.inode` via `FileSystemId.Context.eql`, itself already `pub`).\n\nWalker unit tests (embedded, same file):\n- Line 1324, `test \"walker: cycle detection prevents infinite loop on symlink loop\"` \u2014 builds `real.txt` + `subdir/loop -> ..` (an ancestor loop: loop resolves to the walk root, an ancestor of `subdir`), runs with `.symlinks = .follow_all, .detect_cycles = true, .max_entries = 50`, asserts `saw_real` true and every emitted path is unique (StringHashMapUnmanaged dedup check). Under the redesign this is an `.ancestors`-relevant test: it must be revised to also assert exactly one `error.DirectoryCycle` surfaces from `next()` with `cyclePath()` matching the offending path, then confirms the walk terminates promptly (not merely \"no duplicate paths\", which the current assertion style still allows even if the loop silently prunes without ever raising the new error).\n- Line 1490, `test \"walker: symlink policy follow_all follows all symlinks\"` (the \"alias lock-in\" test per briefing) \u2014 root holds BOTH `target_dir/` and `link_to_dir -> target_dir` (siblings, not ancestor/descendant), uses `sort_children = true` to force deterministic order (`link_to_dir` sorts before `target_dir`), and asserts `saw_via_link` (target reached via the link) is true. Today's `.detect_cycles = true` (global set) means once `link_to_dir` is descended, `target_dir` is silently skipped as an already-visited duplicate (the test never checks that `target_dir` is ALSO independently walked \u2014 it only requires the link path succeeded). Per design: REVISE this test to assert BOTH alias branches (`link_to_dir/target_file.txt` AND `target_dir/target_file.txt`) are fully walked under `.ancestors`; add/keep a companion test pinned to `.ancestors_and_visited` that asserts the OLD dedup (only one of the two is walked) still holds, since `.ancestors_and_visited` is the default and must stay bit-for-bit unchanged.\n- Other symlink-policy tests worth knowing about (unaffected by this change, cited for calibration): line 1401 no_follow-emits-but-no-descend, 1439 follow_cmdline depth-0-only, 1538/1586/1640 the three `resolveKind`/`statTargetKind` leaf-classification tests from issue #47 (broken link, symlink-to-file, symlink-to-dir) \u2014 none of these touch cycle_mode and should need zero changes.", "reference_behavior": "Tool versions: GNU coreutils 9.5 (Ubuntu 25.04 via `orb -m ubuntu`, confirmed `du --version`/`chown --version`/`chmod --version` all report \"9.5\"). All commands below run inside `orb -m ubuntu bash -c '...'` unless noted \"LOCAL\" (macOS host).\n\nIMPORTANT CORRECTION TO THE DESIGN BRIEF: GNU du/chown/chmod 9.5 do NOT print any \"circular directory\" diagnostic on an ancestor loop, unlike GNU `find` which does. The brief's phrase \"pinned GNU-style circular-directory warning\" for du has no GNU text to pin \u2014 there is none. Confirmed by contrast-testing `find -L` on the identical fixture (below), which DOES warn.\n\n(a) `du -L` ancestor loop \u2014 VERBATIM:\n```\n$ rm -rf /tmp/w2 && mkdir -p /tmp/w2/cyc/inner && ln -s .. /tmp/w2/cyc/inner/up && du -L /tmp/w2/cyc\n0\t/tmp/w2/cyc/inner\n0\t/tmp/w2/cyc\nrc=0\n```\nstderr is EMPTY (verified by redirecting streams separately: `/tmp/err2.txt` was a 0-byte file). Even `du -aL` (which lists every entry, including symlinks) does NOT print an `up` line at all \u2014 it is silently pruned, not even shown as a leaf:\n```\n$ du -aL /tmp/w2/cyc      # (rm -rf/mkdir/ln -s same as above)\n0\t/tmp/w2/cyc/inner\n0\t/tmp/w2/cyc\nrc=0, stderr empty\n```\nContrast \u2014 `find -L` on the SAME fixture DOES warn and fails:\n```\n$ find -L /tmp/w2/cyc\n/tmp/w2/cyc\n/tmp/w2/cyc/inner\nrc=1\nstderr: find: File system loop detected; '/tmp/w2/cyc/inner/up' is part of the same file system loop as '/tmp/w2/cyc'.\n```\nA deeper 2-level ancestor loop (`a/b/up -> ../..`) and a pure self-loop (`dir/loop -> .`) and a 2-node mutual-sibling loop (`a/link_b -> ../b`, `b/link_a -> ../a`) were also tried with `du -aL`: all rc=0, all stderr-empty, and in every case the recursive symlink itself is simply absent from the listing (not shown as a leaf, no warning). Exact commands/output:\n```\n$ rm -rf /tmp/w2e && mkdir -p /tmp/w2e/a/b && ln -s ../.. /tmp/w2e/a/b/up && du -aL /tmp/w2e\n0\t/tmp/w2e/a/b\n0\t/tmp/w2e/a\n0\t/tmp/w2e\nrc=0, stderr empty\n\n$ rm -rf /tmp/w2f && mkdir -p /tmp/w2f && ln -s . /tmp/w2f/loop && du -aL /tmp/w2f\n0\t/tmp/w2f\nrc=0, stderr empty\n\n$ rm -rf /tmp/w2g && mkdir -p /tmp/w2g/a /tmp/w2g/b && ln -s ../b /tmp/w2g/a/link_b && ln -s ../a /tmp/w2g/b/link_a && du -aL /tmp/w2g\n0\t/tmp/w2g/b/link_a\n0\t/tmp/w2g/b\n0\t/tmp/w2g\nrc=0, stderr empty\n```\nNote only ONE of `a`/`b` (whichever readdir returns first) is ever descended in the mutual-sibling case \u2014 the other is fully absent (see (b) below, same mechanism).\n\n(b) `du -aL` sibling alias \u2014 VERBATIM:\n```\n$ rm -rf /tmp/w2b && mkdir -p /tmp/w2b/real && echo xx > /tmp/w2b/real/f && ln -s real /tmp/w2b/link && du -aL /tmp/w2b\n4\t/tmp/w2b/link/f\n4\t/tmp/w2b/link\n4\t/tmp/w2b\nrc=0\n```\nANSWER: the aliased tree is NOT listed under both names. `real` and `real/f` are entirely ABSENT from the output \u2014 only `link` (the alias GNU's directory-level visited-set happened to reach first in readdir order) is shown, deduped at the WHOLE-SUBTREE level, not per-file. Confirmed readdir returns `link` before `real` here (`ls -f /tmp/w2b` \u2192 `. .. link real`), i.e. directory order, not alphabetical, decided which alias won. This is GNU du's own global (non-ancestor-scoped) directory-visited-set at work \u2014 the same mechanism that silently prunes the ancestor-loop case in (a).\n\n(c) `chown -v -RL <own-uid>` sibling alias \u2014 VERBATIM:\n```\n$ rm -rf /tmp/w2c && mkdir -p /tmp/w2c/real && touch /tmp/w2c/real/f && ln -s real /tmp/w2c/link && chown -v -RL $(id -u) /tmp/w2c\nownership of '/tmp/w2c/link/f' retained as tcole\nownership of '/tmp/w2c/link' retained as tcole\nownership of '/tmp/w2c/real/f' retained as tcole\nownership of '/tmp/w2c/real' retained as tcole\nownership of '/tmp/w2c' retained as tcole\nrc=0\n```\nANSWER: YES \u2014 unlike du, GNU chown -RL visits and reports BOTH `link` and `real` in full (5 lines: link/f, link, real/f, real, parent). No dedup at all for chown.\n\n(d) `chown -v -RL <own-uid>` ancestor loop \u2014 VERBATIM:\n```\n$ rm -rf /tmp/w2d && mkdir -p /tmp/w2d/cyc/inner && ln -s .. /tmp/w2d/cyc/inner/up && chown -v -RL $(id -u) /tmp/w2d\nownership of '/tmp/w2d/cyc/inner/up' retained as tcole\nownership of '/tmp/w2d/cyc/inner' retained as tcole\nownership of '/tmp/w2d/cyc' retained as tcole\nownership of '/tmp/w2d' retained as tcole\nrc=0\n```\nNote: unlike du, chown DOES print a line for the cycle-forming symlink `up` itself \u2014 it is chowned as a (non-descended) leaf, \"retained\". No warning/diagnostic, no stderr, rc=0. This differs from the design brief's assumption of a printed \"DirectoryCycle\" diagnostic \u2014 GNU is completely silent here; it just stops descending and still services the symlink path itself as an ordinary target.\n\n(e) GNU chmod -L support \u2014 CONFIRMED SUPPORTED, contrary to the brief's uncertainty:\n```\n$ chmod --help | grep -c '\\-L'\n1\n$ chmod --help   (relevant excerpt)\nThe following options modify how a hierarchy is traversed when the -R\noption is also specified.  If more than one is specified, only the final\none takes effect. '-H' is the default.\n  -H     if a command line argument is a symbolic link to a directory, traverse it\n  -L     traverse every symbolic link to a directory encountered\n  -P     do not traverse any symbolic links\n$ chmod -RL 755 /tmp/w2c\nrc=0   (no error)\n```\nGNU chmod 9.5 fully supports -L. docs/specs/chmod-flags.md line 9 already marks `-L | | yes | yes | yes | yes | MUST` (implemented, not a gap). Reference pinned on GNU chmod 9.5 directly \u2014 no BSD fallback needed, section (f) of the task is moot.\n\nSibling-alias and ancestor-loop reference for `chmod -RL`, VERBATIM (mirrors chown exactly: no dedup for aliases, silent leaf-treatment of the cycle symlink, rc=0, no diagnostics):\n```\n$ rm -rf /tmp/w2h && mkdir -p /tmp/w2h/real && touch /tmp/w2h/real/f && chmod 700 /tmp/w2h/real && ln -s real /tmp/w2h/link && chmod -v -RL 755 /tmp/w2h\nmode of '/tmp/w2h' retained as 0755 (rwxr-xr-x)\nmode of '/tmp/w2h/link' changed from 0700 (rwx------) to 0755 (rwxr-xr-x)\nmode of '/tmp/w2h/link/f' changed from 0644 (rw-r--r--) to 0755 (rwxr-xr-x)\nmode of '/tmp/w2h/real' retained as 0755 (rwxr-xr-x)\nmode of '/tmp/w2h/real/f' retained as 0755 (rwxr-xr-x)\nrc=0, stderr empty\n\n$ rm -rf /tmp/w2i && mkdir -p /tmp/w2i/cyc/inner && ln -s .. /tmp/w2i/cyc/inner/up && chmod -v -RL 755 /tmp/w2i\nmode of '/tmp/w2i' retained as 0755 (rwxr-xr-x)\nmode of '/tmp/w2i/cyc' retained as 0755 (rwxr-xr-x)\nmode of '/tmp/w2i/cyc/inner' retained as 0755 (rwxr-xr-x)\nmode of '/tmp/w2i/cyc/inner/up' retained as 0755 (rwxr-xr-x)\nrc=0, stderr empty\n```\n\nCURRENT VIBEUTILS BEHAVIOR (built locally, `zig build -Doptimize=Debug`, macOS host, run WITHOUT the orb prefix) on the identical fixtures \u2014 captures the exact bugs wave-2 fixes and calibrates how far the new design's plan diverges from raw GNU parity:\n- `du -L` ancestor loop: RUNS AWAY. `./zig-out/bin/du -L /tmp/vw2/cyc` (same `cyc/inner/up -> ..` fixture) printed ~50 entries of monotonically deepening paths (`cyc/inner/up/inner/up/inner/up/...`) before finally erroring `du: cannot read directory '/tmp/vw2/cyc': Too many levels of symbolic links`, rc=1. This is the live bug: du's `detect_cycles = false` today means literally no ancestor detection, and it descends until hitting an OS ELOOP (~50 levels here, filesystem/path-length dependent \u2014 NOT a clean bounded stop). This is exactly the bug `.ancestors` mode must fix for du (GNU's instant, silent 2-line result above is the target).\n- `du -aL` sibling alias: `./zig-out/bin/du -aL /tmp/vw2b` (same real/link fixture) printed BOTH `real` (4 bytes, listed in full) AND `link` (0 bytes \u2014 file-level dedup via du's own separate `seen_inodes` hashmap zeroes the double-counted content, but the alias subtree is still fully LISTED, just with zeroed sizes for repeats). This is the current, INTENTIONAL divergence from GNU documented in du.zig's own comment at line ~619-623 (\"du counts a file reached via two distinct directory paths ... once per path, matching the [pre-walker] recursion\") \u2014 i.e. vibeutils du has never matched GNU's directory-level whole-subtree dedup and the design's `.ancestors` plan explicitly preserves that divergence (per-path listing, zero-sized repeats via the orthogonal `seen_inodes` mechanism), not GNU's single-alias-wins behavior. Confirm this is a deliberate, pre-existing design choice, not a new regression to fix.\n- `chown -v -RL <own-uid>` sibling alias: `./zig-out/bin/chown -v -RL $(id -u) /tmp/vw2c` \u2014 BUG CONFIRMED. Only 3 lines printed (`real/f`, `real`, parent `/tmp/vw2c`); `link` and `link/f` are COMPLETELY ABSENT. This is the live undercounting bug `.ancestors` mode is meant to fix for chown: today's global visited-set (`detect_cycles = true`) silently drops the second-encountered alias entirely, unlike GNU which chowns both (see (c) above). This is issue #61's chown half.\n- `chmod -v -RL 755` sibling alias: same bug confirmed, `./zig-out/bin/chmod -v -RL 755 /tmp/vw2h` only reports `real/f`, `real`, parent \u2014 `link` absent, matching chown's bug exactly.\n- `chown -v -RL <own-uid>` / `chmod -v -RL 755` ancestor loop (`cyc/inner/up -> ..`): both ALREADY terminate cleanly today (rc=0, no hang, no error) \u2014 `cyc/inner`, `cyc`, parent all reported, no infinite loop \u2014 because chown/chmod already default `detect_cycles = true` (global set) which happens to catch ancestor loops as a side effect of catching everything else. BUT neither currently lists the `up` symlink itself as a leaf (GNU DOES list it, \"retained\" \u2014 see (d) above), and the design's plan (raising `error.DirectoryCycle` from `next()` in `.ancestors` mode, then chown/chmod's drive loops catching it and printing a diagnostic + setting `had_errors`) would introduce a NEW diagnostic + a nonzero-error condition (`error.FileOperationFailed`/similar) for a case GNU treats as a fully silent, zero-exit-code success. Flag this explicitly for the implementer: matching the design brief literally (report+continue on DirectoryCycle) will NOT match raw GNU chown/chmod parity (GNU is silent, rc=0, and even chowns/chmods the cycle-forming symlink path itself as an ordinary leaf) \u2014 this is a real open design tension between \"make cycles diagnosable\" (brief's apparent intent) and \"byte-for-byte GNU parity\" (project's stated spec hierarchy). Confirmed observed GNU fact, not a recommendation on which to pick \u2014 that's a downstream call.", "test_conventions": "Integration test file conventions (tests/utilities/{du,chown,chmod}_test.sh, sourced by tests/test_runner.sh so tests/lib/common.sh helpers are already in scope):\n- Standard skeleton: `test_<util>() { local util=\"<name>\"; local binary=\"$BIN_DIR/$util\"; test_binary_exists \"$util\" || return 1; test_basic_flags \"$util\"; ... }`.\n- `print_test_result \"<name>\" \"PASS|FAIL|SKIP\" [\"details\"] [\"failed_command\"]` \u2014 the base primitive; increments TESTS_RUN/PASSED/FAILED/SKIPPED and appends to FAILED_TESTS on fail. All higher-level helpers (test_command_succeeds/fails) end up calling this.\n- `test_command_succeeds \"<name>\" \"$binary\" arg1 arg2...` / `test_command_fails \"<name>\" \"$binary\" args...` \u2014 thin wrappers around `run_command` (captures stdout/stderr/exit) checking exit==0 or !=0 respectively. For richer assertions (matching stdout/stderr text), tests fall back to manually running the binary with output/err redirected to files under `$TEMP_DIR` or `\"$dir.stderr\"`-style sidecar files, then `grep -q` the captured text and check `$?` \u2014 see du_test.sh F25/F26 (lines 279-327) as the exact idiom to copy for a new \"du -L prints X, exits 1\" assertion.\n- `create_temp_file \"<content>\" [\"path\"]` / `create_temp_dir [\"path\"]` \u2014 write into `$TEMP_DIR` (a per-run `mktemp`-based dir cleaned up by the harness); omit the path arg to get an auto-generated one echoed back for `local x=$(create_temp_file ...)`.\n- `run_with_limit SECONDS CMD ARGS...` (tests/lib/common.sh:334) \u2014 fork+exec+poll based timeout via python3 (NOT the shell/coreutils `timeout(1)`, which CLAUDE.md flags as absent on some CI runners / macOS). MUST be used for any new ancestor-loop / cycle-termination integration test to bound a potential hang instead of relying on CI's outer job timeout; NONE of du_test.sh/chown_test.sh/chmod_test.sh currently use it (grep confirmed zero hits in all three files) \u2014 new cycle tests are the first callers, e.g. `run_with_limit 10 \"$binary\" -RL \"$current_uid\" \"$cyc_dir\"; local rc=$?`.\n- Root/fakeroot guards: `chown`/`chmod` integration tests in this repo ONLY chown to the invoking user's own uid/gid (`$(id -u)`, `$(id -g)`, `$(whoami)`) \u2014 this needs NO root and none of chown_test.sh/chmod_test.sh currently gate on EUID/fakeroot (grep confirmed zero hits). New shell-level cycle/alias tests for chown/chmod can follow this same own-uid pattern and skip privilege guards entirely. Only the embedded Zig unit tests that chown to an ARBITRARY uid (e.g. `characterization_uid` in chown.zig's privileged tests) need `privilege_test.TestArena` + `privilege_test.requiresPrivilege(io)` + `privilege_test.withFakeroot(...)`.\n- Existing tests that MUST stay green (exact anchors): du_test.sh F22 (~line 194-215, `du -L -b -s` file-level hardlink/symlink dedup via `seen_inodes`, NOT the walker's directory cycle_mode \u2014 orthogonal mechanism, unaffected by this change), F25 (~273-299, dangling-symlink-under-`-L` diagnostic, driven by `resolveKind`/`statTargetKind` returning `.sym_link` on stat failure, also orthogonal to ancestor cycle_mode), F26 (~302-327, ELOOP-chain-under-`-L` diagnostic, same orthogonal mechanism as F25). chown_test.sh lines 122-143 \"Testing traversal flags (-H, -L, -P)\" \u2014 only asserts exit-success for `-H`/`-L`/`-P` traversal on a simple non-cyclic symlinked dir, no behavioral/cycle assertions, trivially preserved.\n\nZig embedded unit-test style for driving du/chown/chmod (or the walker) directly:\n- du: call `runDu(allocator, io, args: []const []const u8, stdout_writer, stderr_writer) !u8` end-to-end (see du.zig:3802 `\"du survives a symlink cycle without infinite recursion (-L)\"` and :3833). Args are the literal CLI argv slice (e.g. `&[_][]const u8{ \"-b\", \"-L\", dir_path }`); assert on `out.writer.buffered()` content and/or the returned exit code. `std.Io.Writer.Allocating` is the standard captured-output type (`var out: std.Io.Writer.Allocating = .init(testing.allocator); defer out.deinit();` then pass `&out.writer`).\n- chown: unprivileged tests can call `runChown`-level entry points directly (not surveyed exhaustively here \u2014 grep `pub fn runChown` if needed); PRIVILEGED tests (arbitrary target uid) call `chownWalk(io, path, ownership, options, allocator, stdout_writer, stderr_writer) !void` directly inside a `privilege_test.withFakeroot(allocator, struct { fn testFn(inner_allocator) !void { ... } }.testFn)` closure, per the exact pattern at chown.zig:2474-2541 (\"privileged: -L with a symlink cycle terminates cleanly instead of looping forever\"). That test currently does `chownWalk(...) catch {};` (swallows ANY error, including the future `error.DirectoryCycle`) and then asserts a specific `characterizationReported(out, file_marker)` substring is present in stdout \u2014 i.e. it proves partial success survived an error, not that zero errors occurred. This exact test is the \"companion\" the briefing's tdd-pipeline should extend/revise: today it only proves \"didn't hang, file.txt eventually reported\"; the redesign should tighten it to also assert BOTH aliases get processed where relevant, and pin whether `error.DirectoryCycle` now surfaces (design intent) vs. GNU's silent success (see reference_behavior note on the (d)/chmod-analog divergence).\n- chmod: `chmodWalk(io, allocator, dir_path, mode_spec, writer, stderr_writer, options) !void` is the direct entry point (chmod.zig:643), exercised by e.g. `test \"char: symlink cycle does not cause an infinite loop\"` (chmod.zig:3118) and `test \"char: -L descends symlinked directory and chmods its contents\"` (chmod.zig:2938) \u2014 read those two for the exact fixture/assertion idiom before writing new ones (not fully transcribed here for space; grep them directly, they follow the same tmpDir+buildTree-by-hand shape as chown's, no privilege guard needed since chmod doesn't touch uid/gid).\n- Walker-direct unit tests: use the walker.zig test-helper block (lines 876-963) \u2014 `tmpPath(allocator, io, &tmp, sub_path)`, `buildTree(io, dir, &[]TreePath{...})` (declarative `.{ .path, .kind: .file|.dir|.symlink, .symlink_target }` list, auto-creates intermediate dirs), `drainEntries(&w, io, allocator, &entries: ArrayListUnmanaged(Entry))` (collects full Entry copies with path/basename re-pointed into owned copies \u2014 use this over `drainWalker` when kind/depth/visit assertions are needed), `indexOfEntry(entries, suffix)`. New `.ancestors`/`.ancestors_and_visited` differential tests should build on this exact helper set, matching the style of the existing tests at lines 1324 and 1490 (both already read in full above) rather than inventing new scaffolding.\n\nScoped commands for iterating on this work: `zig build test --summary all` for full unit suite (or narrower: build a small filter via `zig build test -Dtest-filter=\"walker:\"` \u2014 verify the exact flag name in build.zig/build/utils.zig before relying on it, not independently confirmed this session); `just test-util chown` / `just test-util chmod` / `just test-util du` for the smoke-test-only path; `just it-util chown` / `just it-util chmod` / `just it-util du` for the bash integration suites; `just fmt` before commit (pre-commit hook blocks on `zig fmt` dirtiness).", "notes": "Platform/version pins: GNU coreutils 9.5 on Ubuntu 25.04 via `orb -m ubuntu` (confirmed `du/chown/chmod --version`); vibeutils built locally on macOS (Darwin 25.5.0) via `zig build -Doptimize=Debug` for the \"current vibeutils behavior\" comparisons \u2014 those macOS-built binaries were NOT cross-checked against a Linux vibeutils build in this scouting pass (time-boxed); if Linux-specific walker behavior (e.g. statx vs fstat path in `FileSystemId.fromDir`) matters, re-verify the \"current bug\" repros with `orb -m ubuntu zig build` + the same fixtures before relying on them as a Linux baseline.\n\nBiggest pitfall for downstream: the design brief's assumed GNU reference (\"pinned GNU-style circular-directory warning\" for du; implied diagnostics for chown/chmod cycles) does NOT match observed GNU 9.5 behavior \u2014 GNU du/chown/chmod are completely silent (rc=0, empty stderr) on both the ancestor-loop and sibling-alias cases; only `find -L` warns loudly (`File system loop detected`, rc=1). Whoever writes the red-phase tests must decide, and should get explicit confirmation, whether the target behavior is (a) strict GNU parity (silent success, chown/chmod even service the cycle-symlink path itself as a leaf, du dedups whole aliased subtrees at the directory level) or (b) the brief's apparent intent (a diagnosable `error.DirectoryCycle`, printed diagnostic, `had_errors`/nonzero exit) which is a vibeutils-specific enhancement beyond GNU. These are NOT the same behavior and the existing embedded unit tests (chown.zig:2474, presumably a chmod.zig analog) currently tolerate either outcome loosely (`catch {}` + substring check) \u2014 tightening them requires this decision first.\n\nSecond pitfall: du's per-path (non-deduped) alias listing is a PRE-EXISTING, DOCUMENTED, INTENTIONAL divergence from GNU (du.zig comment ~619-623, \"matching the recursion\") \u2014 do not \"fix\" it to match GNU's single-alias-wins directory dedup as part of this refactor; the design's `.ancestors` mode for du is specified to preserve exactly this per-path counting (no global dedup, ancestor loops pruned via the bounded stack scan instead of a hash set). The already-orthogonal `seen_inodes` file-level dedup (du.zig, used at 8 call sites, backing F22/F25/F26) is untouched by any of this \u2014 it's a separate hashmap keyed on stat'd (dev,inode) at the du layer, not the walker's `FileSystemIdSet`/cycle_mode at all; don't conflate the two when reasoning about \"does this test still pass.\"\n\nThird pitfall: `childDirRejected`'s current `bool` return type cannot express the three-way outcome `.ancestors` mode needs (proceed / silently-skip-cross-device / raise-DirectoryCycle) \u2014 implementer will need to change its signature or restructure the caller (`descendChildDir`, walker.zig:520-572) rather than shoehorning a new meaning into `true`/`false`. Also note `startRootDir`'s cycle branch (line 442-451) returns bare `null` on a root-level dedup hit (not an error) \u2014 decide whether a root operand that IS itself a cycle-forming alias of an already-processed root needs the same `error.DirectoryCycle` treatment or keeps today's silent-null root-skip (this only matters for multi-operand invocations like `chown -RL a b` where `b` is a symlink alias of `a`; not covered by any pinned reference command above \u2014 untested, flag as open).\n\nFourth: chown's `walkAndApply` (chown.zig:642-685) is structurally an abort-on-first-`next()`-error shape today (`while (walk.next(io)) |maybe_entry| {...} else |err| { report; had_errors = true; }` \u2014 Zig's `while |x| ... else |err|` construct ends the loop entirely the first time the iterated expression itself errors, it does not resume). This is different from chmod's `walkAndApply` (chmod.zig:699-739), which already uses an explicit `while (true) { switch (walker.next(io) catch |err| switch (err) {...}) }` continue-on-error shape. So chown genuinely needs restructuring to match chmod's shape (as the design brief states); chmod likely only needs the mechanical `detect_cycles` \u2192 `cycle_mode = .ancestors` rename plus possibly a dedicated `error.DirectoryCycle` arm in its existing `switch` if a GNU-diverging diagnostic is wanted (currently DirectoryCycle would just fall into chmod's generic `else` arm, printing \"cannot read directory under '<path>': DirectoryCycle\" via `posixErrorString` \u2014 verify `posixErrorString` has/needs a mapping for this new error name, or it may print the raw Zig error tag).\n\nFifth: `docs/tiger-style-review/walker-design.md` exists (referenced in the walker.zig file header) but predates this cycle_mode redesign entirely \u2014 grepped for `cycle_mode`/`ancestors`/`DirectoryCycle`/`cyclePath`, zero hits. Don't rely on it for design context beyond what's already in the approved briefing; it will need updating post-implementation, not before.\n\nFiles touched by this scouting, for reference (no edits made): src/common/walker.zig, src/common/directory.zig, src/du.zig, src/chown.zig, src/chmod.zig, src/cp.zig, src/mv.zig, src/rm.zig, src/find.zig, src/grep.zig, tests/lib/common.sh, tests/utilities/du_test.sh, tests/utilities/chown_test.sh, tests/utilities/chmod_test.sh, docs/specs/chmod-flags.md. Local vibeutils binaries used for comparison were built via `zig build -Doptimize=Debug` at repo root (zig-out/bin/{du,chown,chmod}); no repo files were modified, only /tmp fixtures created/destroyed on both the macOS host and the `orb -m ubuntu` Linux VM."};

const REVIEW_ROUND_MAX = 12;
const GATE_FIX_MAX = 4;

// Utilities under behavior change. Each gets its own test-writer/reviewer.
const UNITS = [
  { util: 'du', issue: 61 },
  { util: 'chown', issue: 60 },
  { util: 'chmod', issue: 60 },
];

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['walker_internals', 'reference_behavior', 'test_conventions', 'notes'],
  properties: {
    walker_internals: {
      type: 'string',
      description:
        'Exact excerpts from src/common/walker.zig: WalkConfig fields with defaults, Frame struct, the visited-set mechanics (startRootDir, childDirRejected, collectAndPreprocess with line numbers), SymlinkPolicy, error set of next(), and the du/chown/chmod Walker.init call sites with their configs. Copy real code; do not paraphrase.',
    },
    reference_behavior: {
      type: 'string',
      description:
        'Pinned reference behavior with VERBATIM command output and exit codes: (1) GNU du -L on an ancestor loop (exact stdout lines, exact multi-line stderr warning text, rc); (2) GNU du -L sibling-alias counting; (3) GNU chown -v -RL sibling alias (both chowned? verbatim -v lines, rc) and chown -RL on an ancestor loop (diagnostic + rc); (4) chmod -RL reference — state explicitly whether GNU chmod 9.5 supports -L; if not, pin macOS /bin/chmod -v -RL for the same scenarios and say BSD is the reference. Include the tool versions.',
    },
    test_conventions: {
      type: 'string',
      description:
        'What test authors need: integration helper idioms per test file (print_test_result, run_with_limit, TEMP_DIR, how du/chown/chmod tests assert), whether chown/chmod tests need fakeroot/root skip guards, unit-test style for driving runDu/runChown/runChmod or walker directly, and the exact scoped commands per utility.',
    },
    notes: {
      type: 'string',
      description:
        'Platform differences observed, existing tests that must stay green (du F22/F25/F26, chown -H/-L traversal tests, walker unit tests incl. the alias lock-in at ~1490 and ancestor-loop at ~1324), and pitfalls.',
    },
  },
};

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['assessment', 'issues', 'summary'],
  properties: {
    assessment: { type: 'string', enum: ['APPROVED', 'NEEDS_FIXES'] },
    summary: { type: 'string' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'location', 'description'],
        properties: {
          severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
          location: { type: 'string' },
          description: { type: 'string' },
        },
      },
    },
  },
};

const REDCHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['red_macos', 'right_reason', 'rest_green', 'red_linux', 'summary', 'output_excerpt'],
  properties: {
    red_macos: { type: 'boolean' },
    right_reason: {
      type: 'boolean',
      description: 'failures are the intended assertion mismatches, NOT compile errors/crashes/hangs',
    },
    rest_green: { type: 'boolean', description: 'only the newly added tests fail' },
    red_linux: { type: 'boolean' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const VERIFY_GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'full `zig build test` green (walker tests are shared code)' },
    integration_pass: { type: 'boolean', description: 'scoped integration for du AND chown AND chmod all green' },
    lint_clean: { type: 'boolean' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const SABOTAGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['all_behaviors_proven', 'file_restored_clean', 'results', 'summary'],
  properties: {
    all_behaviors_proven: { type: 'boolean' },
    file_restored_clean: {
      type: 'boolean',
      description: 'walker.zig restored to pre-sabotage state, confirmed via git diff',
    },
    results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['behavior', 'mutation', 'went_red', 'restored_green'],
        properties: {
          behavior: { type: 'string' },
          mutation: { type: 'string' },
          went_red: { type: 'boolean' },
          restored_green: { type: 'boolean' },
          guarding_tests: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

const TIGER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clean', 'new_violations', 'preexisting_count', 'filtered', 'summary', 'output_excerpt'],
  properties: {
    clean: { type: 'boolean' },
    new_violations: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rule', 'location', 'detail'],
        properties: {
          rule: { type: 'string' },
          location: { type: 'string' },
          detail: { type: 'string' },
        },
      },
    },
    preexisting_count: { type: 'integer' },
    filtered: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['location', 'why'],
        properties: { location: { type: 'string' }, why: { type: 'string' } },
      },
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const IMPLEMENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['outcome', 'summary'],
  properties: {
    outcome: { type: 'string', enum: ['done', 'needs_test_change'] },
    summary: { type: 'string' },
    test_change_instructions: { type: 'string' },
  },
};

const TESTFIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['changed', 'summary'],
  properties: {
    changed: { type: 'boolean' },
    summary: { type: 'string' },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'privileged_pass', 'integration_pass', 'linux_unit_pass', 'linux_integration_pass', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean' },
    privileged_pass: { type: 'boolean' },
    integration_pass: { type: 'boolean' },
    linux_unit_pass: { type: 'boolean' },
    linux_integration_pass: {
      type: 'boolean',
      description: 'du AND chown AND chmod scoped integration all green on the Linux VM',
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function formatBriefing(b) {
  return [
    '## SHARED BRIEFING (do not re-explore unless something below is missing)',
    '',
    '### Design (approved; implement THIS, do not redesign)',
    a.design,
    '',
    '### Walker internals',
    b.walker_internals,
    '',
    '### Pinned reference behavior — this is the spec',
    b.reference_behavior,
    '',
    '### Test conventions',
    b.test_conventions,
    '',
    '### Notes',
    b.notes,
  ].join('\n');
}


// The tdd-pipeline plugin supplies tailored test-writer, implementer and
// code-reviewer agents. Where that plugin is not installed — a fresh agent
// container, a CI runner — agent() throws "agent type not found" and takes the
// whole run down with it. Pass `agent_ns: ""` to fall back to the default
// workflow subagent: the separate-agents rule is enforced by distinct
// invocations and by file-ownership scoping, not by the system prompt the
// plugin happens to add. The default is unchanged, so a machine with the
// plugin installed behaves exactly as before.
//
// Read the PARSED args (`a`), never the raw `args` global: the harness may hand
// the script a JSON string, in which case `args.agent_ns` reads as undefined
// and this would fall back to the plugin on the very hosts that cannot resolve
// it — failing exactly where the fallback is needed.
const AGENT_NS = a.agent_ns !== undefined ? a.agent_ns : 'tdd-pipeline:';
const agentTypeFor = (role) => (AGENT_NS ? `${AGENT_NS}${role}` : undefined);

function reviewFeedback(review) {
  const lines = (review.issues || []).map(
    (i) => `- [${i.severity}] ${i.location}: ${i.description}`,
  );
  return [`Reviewer assessment: ${review.assessment}`, review.summary, '', 'Fix every issue below:', ...lines].join('\n');
}

async function scoutBriefing() {
  phase('Scout');
  return await agent(
    [
      'You are scouting the wave-2 walker change for vibeutils (issues #60 and #61 plus the same',
      'chmod -RL bug). Downstream agents rely entirely on your briefing; copy EXACT code excerpts.',
      '',
      '### Design you are scouting for (already approved):',
      a.design,
      '',
      'Do all of the following:',
      '1. Read src/common/walker.zig in full: WalkConfig, Frame, SymlinkPolicy, the visited-set',
      '   mechanics (startRootDir ~441, childDirRejected ~577-616, collectAndPreprocess ~755-807),',
      '   next()\'s error set, and the unit tests at ~1324 (ancestor loop) and ~1490 (alias lock-in).',
      '2. Read the Walker.init call sites + drain loops in src/du.zig (walkDirectoryOperand ~603-667,',
      '   drain loop ~694, rationale comment ~619-623), src/chown.zig (chownWalk ~582-627, walkAndApply',
      '   ~642-680), src/chmod.zig (~659 area). List every other Walker.init call site (grep) with its',
      '   current detect_cycles value: cp, grep, find, mv, rm, plus test call sites and the @hasField',
      '   guard in grep tests (~4285).',
      '3. Pin reference behavior. On the Linux VM (prefix each with `' + a.linux_prefix + '`):',
      "   a. du -L ancestor loop: bash -c 'rm -rf /tmp/w2 && mkdir -p /tmp/w2/cyc/inner && ln -s .. /tmp/w2/cyc/inner/up && du -L /tmp/w2/cyc; echo rc=$?' — record VERBATIM stdout, stderr (the multi-line circular-directory warning), rc.",
      "   b. du -L sibling alias: bash -c 'rm -rf /tmp/w2b && mkdir -p /tmp/w2b/real && echo xx > /tmp/w2b/real/f && ln -s real /tmp/w2b/link && du -aL /tmp/w2b; echo rc=$?' — is the aliased tree listed under BOTH names?",
      "   c. chown -RL sibling alias: bash -c 'rm -rf /tmp/w2c && mkdir -p /tmp/w2c/real && touch /tmp/w2c/real/f && ln -s real /tmp/w2c/link && chown -v -RL $(id -u) /tmp/w2c; echo rc=$?' — verbatim -v lines (does GNU visit the tree via both names?), rc.",
      "   d. chown -RL ancestor loop: bash -c 'rm -rf /tmp/w2d && mkdir -p /tmp/w2d/cyc/inner && ln -s .. /tmp/w2d/cyc/inner/up && chown -v -RL $(id -u) /tmp/w2d; echo rc=$?' — diagnostic + rc.",
      '   e. GNU chmod -L support: run `' + a.linux_prefix + " chmod --help | grep -c '\\-L'` and `" + a.linux_prefix + " bash -c 'chmod -RL 755 /tmp/w2c 2>&1; echo rc=$?'` — does GNU chmod 9.5 accept -L?",
      '   f. If GNU chmod lacks -L, pin the SAME sibling-alias and loop scenarios with macOS /bin/chmod',
      '      (run locally WITHOUT the linux prefix, using /bin/chmod -v -R -L and a mode like 700→755):',
      '      BSD chmod is then the reference per the project spec hierarchy (docs/specs/chmod-flags.md',
      '      marks -L MUST from POSIX/BSD).',
      '   Record every command + verbatim output + rc. If a scenario cannot be pinned, say so explicitly.',
      '4. Distill test conventions for tests/utilities/{du,chown,chmod}_test.sh (helpers, root/fakeroot',
      '   guards — chown to own uid needs no root; note du F22/F25/F26 and chown -H/-L tests that must',
      '   stay green) and the unit-test style for driving these utilities or the walker directly.',
      'Also read CLAUDE.md testing/Tiger sections if needed. Be precise; downstream agents do not re-read.',
    ].join('\n'),
    { label: 'scout:wave2', phase: 'Scout', model: 'sonnet', schema: BRIEFING_SCHEMA },
  );
}

async function routeTestChange(brief, instructions, hop, phaseName) {
  return await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — adjudicate an implementer test-change request',
      'The implementer reports that a TEST must change rather than the implementation. Judge FIRST',
      'against the pinned reference behavior and the approved design:',
      '  - If the test is genuinely WRONG, fix it keeping TEETH. changed=true.',
      '  - If the test is CORRECT, do NOT change it. changed=false; the implementation must change.',
      '',
      `Implementer's request:\n${instructions}`,
      '',
      'Edit ONLY test code. Run `just fmt`. Do NOT commit.',
    ].join('\n'),
    {
      label: `test-writer:adjudicate${hop}`,
      phase: phaseName,
      model: 'opus',
      agentType: agentTypeFor('test-writer'),
      schema: TESTFIX_SCHEMA,
    },
  );
}

async function runImplementer(promptText, label, phaseName, brief) {
  let result = await agent(promptText, {
    label,
    phase: phaseName,
    model: 'opus',
    agentType: agentTypeFor('implementer'),
    schema: IMPLEMENT_SCHEMA,
  });
  let tests_changed = false;
  let hop = 0;
  while (result.outcome === 'needs_test_change' && hop < GATE_FIX_MAX) {
    hop += 1;
    const verdict = await routeTestChange(brief, result.test_change_instructions || '', hop, phaseName);
    if (verdict.changed) tests_changed = true;
    log(`implementer requested a test change (hop ${hop}); test-writer changed=${verdict.changed}`);
    result = await agent(
      [
        brief,
        '',
        '## YOUR TASK (implementer, after the test-writer adjudicated)',
        `Your earlier summary: ${result.summary}`,
        `Test-writer changed the test: ${verdict.changed}`,
        `Test-writer note: ${verdict.summary}`,
        verdict.changed
          ? 'The test was updated. Make the implementation pass against the UPDATED tests.'
          : 'The test-writer judged the test CORRECT. Do NOT request another change for this issue — fix the IMPLEMENTATION.',
        '',
        'Edit ONLY implementation code. Run `just fmt`. Do NOT commit. Return your outcome.',
      ].join('\n'),
      {
        label: `${label}#aftertest${hop}`,
        phase: phaseName,
        model: 'opus',
        agentType: agentTypeFor('implementer'),
        schema: IMPLEMENT_SCHEMA,
      },
    );
  }
  return { result, tests_changed };
}

// ---------------------------------------------------------------------------
// RED phase
// ---------------------------------------------------------------------------
async function runRed() {
  const briefing = await scoutBriefing();
  const brief = formatBriefing(briefing);

  // Parallel per-utility test authoring. Files are disjoint per utility
  // (src/<u>.zig + tests/utilities/<u>_test.sh), so parallel writers are safe.
  phase('Author tests');
  const testPrompt = (u) =>
    [
      brief,
      '',
      `## YOUR TASK (test-writer for ${u.util}, issue #${u.issue}) — FAILING CLI-level tests`,
      '',
      'Write tests that assert the PINNED reference behavior from the briefing for YOUR utility only.',
      'They must FAIL on current code and will pass once the walker cycle_mode change lands.',
      u.util === 'du'
        ? 'Cover: (1) du -L on an ancestor-loop symlink (inner/up -> ..): output shape and exit code exactly as pinned (one line per real dir, cycle diagnostic on stderr, rc as pinned) instead of the current repeated cyc/up/cyc/up walk to the depth bound; (2) du -L sibling-alias counting stays per-path as pinned (guards the no-global-dedup rationale — likely already green).'
        : u.util === 'chown'
          ? 'Cover: (1) chown -RL with a directory and a sibling symlink alias to it: BOTH the real directory tree and the alias path get chowned (use -v to observe visited paths; chown to your own uid so no root needed) — currently the second-encountered alias is skipped; (2) chown -RL on an ancestor loop: terminates with the pinned diagnostic/rc and still chowns the rest.'
          : 'Cover: (1) chmod -RL with a directory and a sibling symlink alias: BOTH get the mode change (verify with stat on the real dir AND through the alias path after setting distinct starting modes) — currently the second-encountered alias is skipped; (2) chmod -RL on an ancestor loop: terminates with the pinned behavior. Use the reference pinned in the briefing (BSD chmod if GNU lacks -L).',
      '',
      'Rules:',
      '- Do NOT touch or rewrite existing tests; do NOT touch walker.zig or any implementation code.',
      `- Hand-edit ONLY: src/${u.util}.zig (test blocks only) and tests/utilities/${u.util}_test.sh.`,
      '- Prefer integration tests (they drive the real binary); add unit tests only where the utility',
      '  test conventions make it practical without referencing walker API that does not exist yet.',
      '  Tests must fail on ASSERTIONS, never on compile errors — do not reference cycle_mode or any',
      '  not-yet-existing symbol.',
      `- Run scoped checks: \`just test-util ${u.util}\` and \`just it-util ${u.util}\`, piped through tail.`,
      '  Confirm your new tests FAIL for the intended reason and everything else passes.',
      '- Loop symlink tests MUST bound runtime (run_with_limit) — the current bug walks to depth 1024.',
      '- Run `just fmt`. Do NOT commit. Report each test, the behavior it guards, and the observed',
      '  failure message (proof of red).',
    ].join('\n');

  let testNotes = await parallel(
    UNITS.map((u) => () =>
      agent(testPrompt(u), {
        label: `test-writer:${u.util}`,
        phase: 'Author tests',
        model: 'sonnet',
        agentType: agentTypeFor('test-writer'),
      })),
  );

  // Per-utility review loops, in parallel across utilities.
  phase('Review tests');
  const reviews = await parallel(
    UNITS.map((u, i) => async () => {
      let review = null;
      let note = testNotes[i];
      let round = 0;
      while (round < REVIEW_ROUND_MAX) {
        round += 1;
        review = await agent(
          [
            brief,
            '',
            `## YOUR TASK (test-reviewer for ${u.util}, issue #${u.issue})`,
            `Review the failing tests just added to src/${u.util}.zig and tests/utilities/${u.util}_test.sh.`,
            'Check: pinned reference behavior asserted exactly (not a weaker proxy); failures will be for',
            'the right reason; loop tests bound their runtime; no implementation code touched; no',
            'references to not-yet-existing walker API in test code. Judge BY READING ONLY — do not run',
            'suites or modify anything. Return APPROVED only when nothing remains.',
          ].join('\n'),
          { label: `test-review:${u.util}#${round}`, phase: 'Review tests', model: 'opus', schema: REVIEW_SCHEMA },
        );
        log(`test review ${u.util} round ${round}: ${review.assessment} (${(review.issues || []).length} issues)`);
        if (review.assessment === 'APPROVED') break;
        note = await agent(
          [
            brief,
            '',
            `## YOUR TASK (test-writer for ${u.util}, fix round)`,
            `Your earlier summary: ${note}`,
            '',
            reviewFeedback(review),
            '',
            'Apply every fix; tests must still FAIL on current code for the right reason. Do NOT commit.',
          ].join('\n'),
          { label: `test-writer:${u.util}#fix${round}`, phase: 'Review tests', model: 'sonnet', agentType: agentTypeFor('test-writer') },
        );
      }
      return { util: u.util, review, note };
    }),
  );

  phase('Red check');
  const redCheck = await agent(
    [
      '## YOUR TASK (red check — run and report only; no edits)',
      'New failing tests were added for du (#61), chown (#60), and chmod (walker alias bug). Verify the',
      'red is real, for the right reason, on both platforms:',
      '1. macOS: `just test-util du`, `just test-util chown`, `just test-util chmod` and',
      '   `just it-util du`, `just it-util chown`, `just it-util chmod` — the ONLY failures are the',
      '   newly added tests, each failing on its intended assertion (not compile error/crash/timeout).',
      `2. Linux: \`${a.linux_prefix} zig build\` then \`${a.linux_prefix} zig build test -Dtest-util=du\` (and chown, chmod)`,
      `   and \`${a.linux_prefix} scripts/run-integration.sh du\` (and chown, chmod) — same red shape.`,
      'Pipe verbose output through tail. Note any loop test that hangs rather than failing fast — that',
      'is a broken test (must be reported, right_reason=false).',
    ].join('\n'),
    { label: 'red-check:wave2', phase: 'Red check', model: 'sonnet', schema: REDCHECK_SCHEMA },
  );
  log(`red check: macos=${redCheck.red_macos} reason=${redCheck.right_reason} rest=${redCheck.rest_green} linux=${redCheck.red_linux}`);

  const allApproved = reviews.filter(Boolean).every((r) => r.review && r.review.assessment === 'APPROVED');
  return {
    phase: 'red',
    briefing,
    test_notes: reviews.filter(Boolean).map((r) => ({ util: r.util, note: r.note, assessment: r.review.assessment })),
    red_check: redCheck,
    ready_to_commit_red:
      allApproved &&
      !!(redCheck && redCheck.red_macos && redCheck.right_reason && redCheck.rest_green && redCheck.red_linux),
  };
}

// ---------------------------------------------------------------------------
// GREEN phase
// ---------------------------------------------------------------------------
async function runGreen() {
  const briefing = a.briefing || EMBEDDED_BRIEFING || (await scoutBriefing());
  const brief = formatBriefing(briefing);

  phase('Implement');
  let testsChangedDuringGreen = false;
  let impl = await runImplementer(
    [
      brief,
      '',
      '## YOUR TASK (implementer) — walker cycle_mode split + consumer migration',
      '',
      'Implement the approved design EXACTLY. Failing CLI tests for du/chown/chmod pin the target',
      'behavior. Scope:',
      '- src/common/walker.zig: replace detect_cycles with the CycleMode enum, add Frame.fs_id, the',
      '  bounded ancestor scan, error.DirectoryCycle + cyclePath(), and gate the three insertion points',
      '  per the design. .ancestors_and_visited must stay bit-for-bit today\'s behavior.',
      '- src/du.zig: .ancestors mode; DirectoryCycle arm in the drain loop printing the pinned',
      '  diagnostic; update the detect_cycles rationale comment; has_error/exit semantics as pinned.',
      '- src/chown.zig and src/chmod.zig: .ancestors mode; restructure their walk loops to report',
      '  DirectoryCycle (and other per-entry errors) and CONTINUE, per the pinned reference.',
      '- Mechanical migration of every other Walker.init call site and test config to the new field',
      '  (cp/grep/find -> .none; mv/rm and their tests -> .ancestors_and_visited; grep @hasField guard).',
      '  Test-code edits here must be strictly mechanical (field renames / new-arg threading); semantic',
      '  test changes go through needs_test_change.',
      '- Tiger Style throughout: bounded ancestor scan asserted against max_depth, 2+ asserts per new',
      '  function, no recursion, 70-line/100-col limits.',
      '',
      'Iterate with FAST checks only: `zig build`, `zig build test -Dtest-util=du` (and chown/chmod),',
      '`just it-util du` (etc.), piped through tail. Walker unit tests run in the full suite — you may',
      'run `zig build test` sparingly (it is the authoritative unit gate here), always through tail.',
      'Do NOT run privileged or full integration; the verify stage does that.',
      '',
      'You may NOT make semantic edits to tests. If a test is wrong (including the walker alias',
      'lock-in test at ~1490 if it conflicts with keeping .ancestors_and_visited semantics), return',
      'outcome=needs_test_change with instructions. Run `just fmt`. Do NOT commit.',
    ].join('\n'),
    'implementer:wave2',
    'Implement',
    brief,
  );
  testsChangedDuringGreen = testsChangedDuringGreen || impl.tests_changed;
  let implNote = impl.result.summary;

  phase('Verify gate');
  let verify = null;
  let vfix = 0;
  while (vfix <= GATE_FIX_MAX) {
    verify = await agent(
      [
        '## YOUR TASK (verify gate — run and report only)',
        'Run EXACTLY:',
        '  - full unit:          "zig build test" (walker is shared code; the full unit suite is the gate)',
        '  - scoped integration: "just it-util du" AND "just it-util chown" AND "just it-util chmod"',
        '  - lint:               "just fmt-check"',
        'Pipe verbose output through tail. unit_pass = full unit green; integration_pass = ALL THREE',
        'scoped integration suites green; lint_clean = fmt passes.',
      ].join('\n'),
      { label: 'verify-gate:wave2', phase: 'Verify gate', model: 'haiku', schema: VERIFY_GATE_SCHEMA },
    );
    const ok = verify.unit_pass && verify.integration_pass && verify.lint_clean;
    if (ok) break;
    if (vfix === GATE_FIX_MAX) break;
    vfix += 1;
    log(`verify gate failed (unit=${verify.unit_pass} it=${verify.integration_pass} lint=${verify.lint_clean}) — re-dispatching implementer.`);
    const vimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, verify-gate fix)',
        `Your earlier summary: ${implNote}`,
        '',
        'The verify gate failed. Make everything pass.',
        `Gate report: ${verify.summary}`,
        `Output excerpt:\n${verify.output_excerpt}`,
        '',
        'If the failure is a WRONG test, return outcome=needs_test_change. Do NOT commit.',
      ].join('\n'),
      `implementer:wave2#vfix${vfix}`,
      'Verify gate',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || vimpl.tests_changed;
    implNote = vimpl.result.summary;
  }

  // Harden the walker characterization tests, then prove their teeth by
  // transient sabotage of walker.zig (the refactor lane for the shared core).
  phase('Harden walker tests');
  let hardenNote = await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — walker unit-test hardening for cycle_mode',
      '',
      'The implementation just landed in the working tree. Revise and extend the walker unit tests in',
      'src/common/walker.zig so the new semantics are pinned:',
      '- REVISE the alias lock-in test (~1490, "whichever is visited first ... skipped"): under',
      '  .ancestors it must assert BOTH the real directory and the sibling alias are fully walked',
      '  (both emit their children). Keep (or add) a companion asserting .ancestors_and_visited still',
      '  dedups exactly as before.',
      '- REVISE/extend the ancestor-loop test (~1324): under .ancestors an ancestor loop yields',
      '  error.DirectoryCycle from next() (re-entrant), cyclePath() names the offending path, and the',
      '  walk terminates promptly.',
      '- ADD: mutual sibling symlinks (a/link_b -> ../b, b/link_a -> ../a) terminate under .ancestors',
      '  with each dir walked exactly twice (trace from the design); .none mode unchanged semantics.',
      '- Each test must assert behavior a wrong implementation would break — no tautologies. They must',
      '  all PASS on the current (fixed) code.',
      'Hand-edit ONLY test code in src/common/walker.zig. Run the walker tests via `zig build test`',
      'piped through tail (confirm green). Run `just fmt`. Do NOT commit. Report each test and the',
      'production behavior it guards.',
    ].join('\n'),
    { label: 'test-writer:walker-harden', phase: 'Harden walker tests', model: 'sonnet', agentType: agentTypeFor('test-writer') },
  );

  let sabotage = null;
  let teethFix = 0;
  while (teethFix <= GATE_FIX_MAX) {
    sabotage = await agent(
      [
        brief,
        '',
        '## YOUR TASK (prove the walker tests have teeth via transient sabotage)',
        '',
        'For EACH key walker behavior below, prove its guarding unit test can fail:',
        '  1. Back up src/common/walker.zig to a temp path first.',
        '  2. Apply a MINIMAL mutation breaking that behavior (e.g. skip the ancestor scan, make',
        '     .ancestors dedup like .ancestors_and_visited, drop the DirectoryCycle error, return a',
        '     wrong cyclePath, break the .ancestors_and_visited pre-registration).',
        '  3. Run ONLY the guarding test(s) via `zig build test -Dtest-filter="<test name>"` piped',
        '     through tail; confirm RED.',
        '  4. RESTORE walker.zig from the backup; re-run the same filtered test; confirm GREEN.',
        'Behaviors: (a) .ancestors re-walks sibling aliases; (b) .ancestors detects ancestor loops with',
        'DirectoryCycle + correct cyclePath; (c) .ancestors_and_visited preserves the old global dedup;',
        '(d) mutual sibling symlinks terminate.',
        'After all: `git diff -- src/common/walker.zig` must show ONLY the implementation change from',
        'this branch plus the new tests (no leftover mutation) — report file_restored_clean. Then run',
        'one full `zig build test` through tail to confirm green.',
        'Mutate ONLY src/common/walker.zig, always restore, never run tree-wide formatters, do NOT commit.',
      ].join('\n'),
      { label: 'prove-teeth:walker', phase: 'Harden walker tests', model: 'sonnet', schema: SABOTAGE_SCHEMA },
    );
    log(`prove-teeth: proven=${sabotage.all_behaviors_proven} clean=${sabotage.file_restored_clean}`);
    if (sabotage.all_behaviors_proven && sabotage.file_restored_clean) break;
    if (teethFix === GATE_FIX_MAX) break;
    teethFix += 1;
    const toothless = (sabotage.results || [])
      .filter((r) => !r.went_red)
      .map((r) => `- ${r.behavior}: mutation "${r.mutation}" did not fail ${r.guarding_tests || 'any test'}`)
      .join('\n');
    hardenNote = await agent(
      [
        brief,
        '',
        '## YOUR TASK (test-writer, teeth fix)',
        `Your earlier summary: ${hardenNote}`,
        '',
        'Sabotage proved these walker tests CANNOT fail when their behavior breaks — strengthen them:',
        toothless || '(tree left dirty; ensure tests are intact and pass on real code)',
        '',
        'Keep them green on the current fixed code. Do NOT commit.',
      ].join('\n'),
      { label: `test-writer:walker-teethfix${teethFix}`, phase: 'Harden walker tests', model: 'sonnet', agentType: agentTypeFor('test-writer') },
    );
  }

  async function runTigerCheck(label) {
    return await agent(
      [
        '## YOUR TASK (Tiger check — scan, triage, and report)',
        'Run EXACTLY: bash scripts/tiger-check.sh --base HEAD',
        'TAB-separated lines (<rule>\\t<file>:<line>\\t<status>\\t<detail>), status NEW or PRE, then',
        '"SUMMARY total=<N> new=<N>". Triage: confirm genuine NEW violations; FILTER legitimate',
        'dual-use (usize required by std API; while(true) provably bounded with assert). clean=true iff',
        'no confirmed NEW violations. Read to adjudicate; do NOT edit.',
      ].join('\n'),
      { label, phase: 'Tiger check', model: 'haiku', schema: TIGER_SCHEMA },
    );
  }

  phase('Tiger check');
  let tiger = await runTigerCheck('tiger-check:wave2');
  log(`tiger check: clean=${tiger.clean} new=${(tiger.new_violations || []).length} pre=${tiger.preexisting_count}`);
  let tfix = 0;
  while (!tiger.clean && tfix < GATE_FIX_MAX) {
    tfix += 1;
    const violations = (tiger.new_violations || []).map((v) => `- [${v.rule}] ${v.location}: ${v.detail}`).join('\n');
    const timpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, Tiger-check fix)',
        `Your earlier summary: ${implNote}`,
        '',
        'Fix every NEW Tiger Style violation below, keeping all tests green and behavior unchanged:',
        violations,
        '',
        'If a flagged line is legitimate dual-use, say so in your summary. Do NOT commit.',
      ].join('\n'),
      `implementer:wave2#tfix${tfix}`,
      'Tiger check',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || timpl.tests_changed;
    implNote = timpl.result.summary;
    tiger = await runTigerCheck(`tiger-check:wave2#${tfix}`);
    log(`tiger check (after fix ${tfix}): clean=${tiger.clean} new=${(tiger.new_violations || []).length}`);
  }

  phase('Code review');
  let codeReview = null;
  let round = 0;
  while (round < REVIEW_ROUND_MAX) {
    round += 1;
    codeReview = await agent(
      [
        brief,
        '',
        '## YOUR TASK (adversarial code review of the walker cycle_mode change)',
        '',
        'Review the full diff (git diff against HEAD) with an adversarial eye. This is shared traversal',
        'core used by 8 utilities; a subtle bug here corrupts recursive operations everywhere. Attack:',
        '- Termination: can ANY topology make .ancestors walk forever or blow the stack/entry caps',
        '  pathologically? (mutual aliases, deep alias meshes, symlink chains, loops through the root)',
        '- Bit-for-bit preservation: does .ancestors_and_visited REALLY behave identically to the old',
        '  detect_cycles=true on every path (startRootDir, childDirRejected, collectAndPreprocess,',
        '  including the no_follow/follow_cmdline pre-registration)?',
        '- The re-entrant error contract of next() after DirectoryCycle: frame/path_buf state, dir',
        '  handle leaks, cyclePath() lifetime.',
        '- Resource management on every early-exit path (dir handles closed, path_buf restored).',
        '- Consumer correctness: du exit/diagnostic semantics vs the pin; chown/chmod continue-on-error',
        '  restructures (did aborting-on-first-error semantics change anywhere it should not have?);',
        '  the mechanical .none/.ancestors_and_visited migrations (any consumer accidentally moved to a',
        '  different mode?).',
        '- Tiger Style: bounded loops with asserts, function sizes.',
        'Judge BY READING AND REASONING ONLY — no builds, no test runs (verify gates already ran).',
        'Cite specific code for every issue. Return APPROVED only when nothing real remains.',
      ].join('\n'),
      { label: `code-review:wave2#${round}`, phase: 'Code review', model: 'fable', schema: REVIEW_SCHEMA },
    );
    log(`code review round ${round}: ${codeReview.assessment} (${(codeReview.issues || []).length} issues)`);
    if (codeReview.assessment === 'APPROVED') break;
    const crimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, code-review fix)',
        `Your earlier summary: ${implNote}`,
        '',
        reviewFeedback(codeReview),
        '',
        'Apply every fix, keep all tests green. If a point is a WRONG test, return',
        'outcome=needs_test_change. Do NOT commit.',
      ].join('\n'),
      `implementer:wave2#crfix${round}`,
      'Code review',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || crimpl.tests_changed;
    implNote = crimpl.result.summary;
  }
  if (codeReview.assessment !== 'APPROVED') {
    log(`WARNING: code review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED.`);
  }

  phase('Final verify');
  const finalCheck = await agent(
    [
      '## YOUR TASK (final verify — FULL suites on BOTH platforms, run and report only)',
      'Run EXACTLY (pipe verbose output through tail):',
      '  - macOS full unit:        "zig build test"',
      '  - macOS full privileged:  "just test-privileged"',
      '  - macOS full integration: "just it"',
      `  - Linux full unit:        "${a.linux_prefix} zig build test"`,
      `  - Linux integration:      "${a.linux_prefix} zig build" then "${a.linux_prefix} scripts/run-integration.sh du",`,
      `    "${a.linux_prefix} scripts/run-integration.sh chown", "${a.linux_prefix} scripts/run-integration.sh chmod"`,
      'Report facts only.',
    ].join('\n'),
    { label: 'final-verify:wave2', phase: 'Final verify', model: 'haiku', schema: FINAL_SCHEMA },
  );
  const finalAllPass =
    !!finalCheck &&
    finalCheck.unit_pass &&
    finalCheck.privileged_pass &&
    finalCheck.integration_pass &&
    finalCheck.linux_unit_pass &&
    finalCheck.linux_integration_pass;
  log(`final verify: all=${finalAllPass}`);

  return {
    phase: 'green',
    impl_summary: implNote,
    tests_changed_during_green: testsChangedDuringGreen,
    verify_gate: verify,
    walker_test_note: hardenNote,
    sabotage,
    tiger_check: tiger,
    code_review: codeReview,
    final_verify: finalCheck,
    final_all_pass: finalAllPass,
    ready_to_commit_green:
      !!(verify && verify.unit_pass && verify.integration_pass && verify.lint_clean) &&
      !!(sabotage && sabotage.all_behaviors_proven && sabotage.file_restored_clean) &&
      !!(tiger && tiger.clean) &&
      codeReview.assessment === 'APPROVED' &&
      finalAllPass,
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
log(`wave2-walker: phase=${phaseArg}`);
const result = phaseArg === 'green' ? await runGreen() : await runRed();
return result;
