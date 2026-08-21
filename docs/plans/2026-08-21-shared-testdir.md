# Slice: Adopt Shared TestDir Across All Utilities

## Slice name

`### 3. Adopt Shared TestDir Across All Utilities`

One heading, one PR. Nested boxes under that heading
belong here. Do not pull `### 5` main() coverage,
`### 6` dd `conv=`, `### 1` fd-mode, `### 2` POSIX I/O,
`## Bugs` (`ls` pipe columns), or any Modern Features
heading.

## Predecessor gate (recorded deviation)

Listed Testing Improvements order would wait for `### 2`
(PR #193) to land on `main`. This environment cannot
merge. Branch from `github/main` (`a41eccd`).

`TODO.md` / `CHANGELOG.md` will conflict with stacked
slices; rebase after predecessors land. Do **not** stack
on #193, and do **not** source or copy
`tests/lib/posix_io.sh` / `tests/lib/fd_modes.sh`.

Do not stack on #177 (`dd.zig`) or #189 (`du.zig`):
this slice only rewrites test fixtures in those files,
not production behavior, so independent stacking off
`github/main` is safe as long as the mechanical
replacement does not touch `runDd` / `runDu`.

## Review revision (round 2)

Three-model plan review (Grok, Sol, Fable) all voted
REQUEST CHANGES. Decisions, recorded here:

1. **Predecessor skip stays.** Same campaign override
   as #192/#193. Sol's "stop until #193 is on main"
   is the skill default; this environment cannot
   merge, so stacking off `github/main` is the
   recorded deviation, not a second slice.

2. **Box 2 is annotated, not claimed clean.** Residual
   cwd-behavior tests keep `TestDir.chdirToBase`.
   Checking the box without that note is false.
   Implementer writes the annotation under the box
   when checking it. Sol's isolated-child-process
   alternative is **rejected**: spawning the compiled
   binary is `### 5` (`main()` coverage) and would
   drop in-process coverage of `runGrep` / `runLs` /
   `runRealpath` / `runReadlink` relative-operand
   paths. Production cwd injection stays out of
   scope. Grok+Fable's allowlist + lint is the
   locked approach.

3. **Complete `chdirToBase` allowlist** (file +
   body name). Measured 2026-08-21 on `github/main`.
   Every allowlisted body **must** contain
   `chdirToBase(` after GREEN (dropping chdir from a
   cwd-behavior test is RED). Every `chdirToBase(`
   in listed files must sit in an allowlisted body
   (sandbox-only chdir is RED). Listed files contain
   zero `Threaded.chdir(` and zero `setCurrentDir(`
   call sites (comments mentioning the words are
   not hits; the call shape is the `(`).

   Allowlist (29 bodies; round-3 adds rmdir `-p`):

   `src/grep.zig` tests:
   - `walker-migration: recursive search with no operands searches the current directory`

   `src/readlink.zig` tests:
   - `readlink -m relative path with missing tail resolves via cwd (issue #51)`

   `src/realpath.zig` tests (13):
   - `realpath: relative --relative-to=. resolves against cwd (issue #46)`
   - `realpath: relative --relative-base=sub resolves against cwd (issue #46)`
   - `realpath: -e resolves a relative existing file to an absolute path (issue #46)`
   - `realpath: -s relative existing path resolves via cwd (issue #51)`
   - `realpath: -s relative path with dot components resolves via cwd (issue #51)`
   - `realpath: -m relative path with missing tail resolves via cwd (issue #51)`
   - `realpath: -m relative path with existing components resolves via cwd (issue #51)`
   - `realpath: -s pop of dotdot past missing component errors ENOENT (issue #62)`
   - `realpath: -s pop of dotdot past non-directory errors ENOTDIR (issue #62)`
   - `realpath: -m -s pop of dotdot past missing component succeeds (issue #62)`
   - `realpath: -s pop past existing dir with missing final component succeeds (issue #62)`
   - `realpath: -s pop past symlink-to-directory succeeds (issue #62)`
   - `realpath: -s pop past symlink-to-file errors ENOTDIR (issue #62)`

   `src/ls/main.zig` tests (12):
   - `ls prints a subdirectory operand exactly as given, not its basename (short format)`
   - `ls -l ends a subdirectory operand's line with the full operand path`
   - `ls -1t sorts distinct-mtime file operands newest first, ignoring argv order`
   - `ls -1S sorts distinct-size file operands largest first, ignoring argv order`
   - `ls -1 sorts file operands by name by default, ignoring argv order`
   - `ls -1U preserves argv order for file operands (guards against over-sorting)`
   - `ls -1r reverses the default name sort for file operands`
   - `ls sorts directory operands by name too, so a_dir's header comes before b_dir's`
   - `ls mixed operands: files first, one blank line before the dir section`
   - `ls -C lays out multiple file operands in columns, not one per line`
   - `ls -s prints the block prefix for file operands and no total line`
   - `ls -s sizes the operand block field across all operands, not per operand`

   `src/rmdir.zig` tests:
   - `rmdir: remove with parents`

     GNU `rmdir -p` walks every dirname until `/` or
     `.`. An absolute sandbox path therefore continues
     into `/tmp` after the fixture is gone. Relative
     operands with cwd at the sandbox stop at `.`.
     That is cwd-behavior, not a lint bypass. Use
     `chdirToBase` / `restoreCwd`. Do **not** add a
     local `fchdir` helper (`rmdirEnterSandbox`).

   `src/ls/main.zig` helper (not a test; the #147 ACL
   tests chdir through it):
   - `AclFixture.init`

   Delete `testChdirToTmp` / `testRestoreCwd` from
   `ls/main.zig`. `src/pwd.zig` does **not** chdir
   (getBasePath only). `src/env.zig` has
   `Threaded.chdir`; `env` is not listed; leave it.

4. **Cwd-as-sandbox needle is structural.** In listed
   files, scan **top-level `test "` bodies only**
   (column-zero `test`, same rule as
   `force_import_lint.hasTopLevelTest`). Hits:
   `Dir.cwd().createDir(`, `createDirPath(`,
   `createFile(`, `deleteDir(`, `deleteTree(`.
   Production `rmdir` `Dir.cwd().deleteDir` is
   outside a test body and is **not** a hit.
   `Dir.cwd().openDir` / `statFile` / `access` are
   **not** hits (`chown` opens an absolute
   `root_path`; mktemp stats the printed path).
   `mkdir.zig` and `rmdir.zig` are both in scope.
   After GREEN those five call shapes are zero in
   listed test bodies. `mktemp -d` cleanup of the
   printed (absolute) path switches to
   `std.fs.deleteDirAbsolute` so it does not keep a
   `Dir.cwd().deleteDir` hit.

5. **`tmpDir` needle is the call, not `(.{})`.**
   Hits: `testing.tmpDir(` and `std.testing.tmpDir(`,
   including `tmpDir(.{ .iterate = true })`,
   multiline, and spaced forms. A comment
   `testing.tmpDir nests under` with no `(` is not
   a hit. Fixture tests cover empty options,
   non-empty options, and a multiline call.

6. **`verify` cannot inspect a subset.** Locked
   listed path table is exactly **39** files
   (28 `src/<util>.zig` from the heading plus `mv`,
   plus every `src/ls/*.zig`). `verify` fails if
   any path is missing/unreadable, if the scanned
   count is not 39, or if the table is empty.
   `listed_files_min = 39` is an exact floor, not
   a "at least cat.zig" check. A fixture whose
   only violation is in the **last** table path
   (`src/ls/types.zig` alphabetically last under
   `ls/`, with `src/wc.zig` last among the
   `src/*.zig` names — lock last path as
   `src/wc.zig` in heading order then `mv` then
   `src/ls/*.zig` sorted, so the last path is
   `src/ls/types.zig`) must fail `verify`.

7. **Source root.** `src` is
   `std.fs.path.dirname(build_options.common_source_dir)`.
   Do **not** edit `build.zig`. Test-writer owns
   this derivation.

8. **Assertions may change when the path is the
   assertion.** "Do not rewrite assertions" is
   narrowed: exit codes, GNU templates, and
   behavioral needles stay. Expected stdout/stderr
   **substrings that embed a fixture path** must
   change when the operand becomes absolute
   (`mkdir`/`rmdir` verbose tests). The
   `test_rmdir_` substring needle is **dropped**;
   the structural cwd needle is the tooth.

9. **Tiger Style on `testdir_lint.zig`.** Same
   caps as `force_import_lint.zig`: `files_max`
   64, per-file `bytes_max` 2 MiB (`find.zig` is
   large), bounded loops, two asserts per
   function, 70 lines, 100 columns. Empty scan
   and missing path are distinct errors, not a
   silent pass.

10. **Privileged `TestDir.init`.** Inside
    `withFakeroot`, pass `inner_allocator`, not
    the outer arena and never `testing.allocator`.

11. **Post-GREEN sabotage** (never committed, no
    `git checkout -- <file>`): (a) one
    `testing.tmpDir(.{ .iterate = true })` in
    `src/wc.zig` (not `cat.zig`); (b) one
    `Dir.cwd().createDir(` in a `mkdir.zig` test
    body. Each must RED the matching needle.
    Revert that one line.

12. **Keep the plan-only PR draft** until the
    implementer GREEN commit. Test-writer RED
    makes `zig build test` fail; do not expect
    CI green between steps 3 and 5.

## Classification

Behavior-preserving **test refactor**. No production
behavior change, no flags, no man-page flag tables, no
`docs/specs/` edits. `CHANGELOG.md` gets **no**
user-visible bullet (test-only). `TODO.md` checks the
four boxes under this heading; box 2 carries the
chdirToBase annotation from decision 2.

`src/common/test_dir.zig` already exists and is what
`src/cp.zig` uses. This slice adopts that helper in the
listed utilities and deletes `src/mv.zig`'s local
wrapper.

## In scope

The four TODO boxes:

1. Replace ad-hoc `testing.tmpDir(` /
   `std.testing.tmpDir(` in listed utility tests
   with `common.test_dir.TestDir`.
2. Sandbox fixtures use absolute paths via
   `getPath` / `getBasePath`. Cwd-behavior tests
   on the allowlist use `chdirToBase` (annotated
   residual, not a silent fchdir ban).
3. Utilities to migrate (the heading's list, plus `mv`
   from box 4):
   cat, chmod, chown, cut, dd, du, find, grep, head,
   ln, ls, mkdir, mktemp, nl, pwd, readlink, realpath,
   rm, rmdir, stat, tac, tail, tee, test, touch, tr,
   uniq, wc, mv.
   `ls` includes **every** `src/ls/*.zig` (11 files),
   including those with zero `tmpDir` today
   (`display.zig`, `formatter.zig`, `recursive.zig`,
   `sorter.zig`).
4. Delete `src/mv.zig`'s local `TestDir` wrapper;
   call `common.test_dir.TestDir` directly.

### Locked listed-path table (exactly 39)

Heading order, then `mv`, then `src/ls/*.zig` sorted:

`src/cat.zig`, `src/chmod.zig`, `src/chown.zig`,
`src/cut.zig`, `src/dd.zig`, `src/du.zig`,
`src/find.zig`, `src/grep.zig`, `src/head.zig`,
`src/ln.zig`, `src/mkdir.zig`, `src/mktemp.zig`,
`src/nl.zig`, `src/pwd.zig`, `src/readlink.zig`,
`src/realpath.zig`, `src/rm.zig`, `src/rmdir.zig`,
`src/stat.zig`, `src/tac.zig`, `src/tail.zig`,
`src/tee.zig`, `src/test.zig`, `src/touch.zig`,
`src/tr.zig`, `src/uniq.zig`, `src/wc.zig`,
`src/mv.zig`,
`src/ls/core.zig`, `src/ls/display.zig`,
`src/ls/entry_collector.zig`, `src/ls/formatter.zig`,
`src/ls/integration_test.zig`, `src/ls/main.zig`,
`src/ls/recursive.zig`, `src/ls/security_test.zig`,
`src/ls/sorter.zig`, `src/ls/test_utils.zig`,
`src/ls/types.zig`.

Last path for the single-violation fixture:
`src/ls/types.zig`.

### Target pattern (already in `src/cp.zig`)

```zig
const TestDir = common.test_dir.TestDir;

var test_dir = TestDir.init(testing.allocator);
defer test_dir.deinit();
try test_dir.createFile("source.txt", "Hello, World!", null);
const source_path = try test_dir.getPath("source.txt");
defer testing.allocator.free(source_path);
const base_path = try test_dir.getBasePath();
defer testing.allocator.free(base_path);
const dest_path = try std.fmt.allocPrint(
    testing.allocator,
    "{s}/dest.txt",
    .{base_path},
);
defer testing.allocator.free(dest_path);
```

Privileged tests (`"privileged: "` prefix) pass
`arena.allocator()` outside fakeroot, and
`inner_allocator` **inside** `withFakeroot`:

```zig
try privilege_test.withFakeroot(allocator, struct {
    fn testFn(inner_allocator: std.mem.Allocator) !void {
        var test_dir = TestDir.init(inner_allocator);
        defer test_dir.deinit();
        // ...
    }
}.testFn);
```

`TestDir.init(testing.allocator)` under fakeroot hangs
(CLAUDE.md). Do not introduce that hang while replacing
`testing.tmpDir` in privileged tests. `testing.tmpDir`
itself does not use `testing.allocator`; the trap is
only the TestDir wrapper if it is given the hanging
allocator.

### API lifts onto shared `TestDir`

Keep the surface small. Follow `cp.zig` where it
already works. Lift only what the listed files need
that `cp.zig` does not already express:

| Method | Why |
| --- | --- |
| `dir() std.Io.Dir` | chmod/iterate/openFile/access/readFileAlloc on the sandbox Dir. mv already reaches through `inner.tmp_dir.dir`. Do not wrap every Dir method. |
| `createDirPath(name)` | grep/rm/realpath/rmdir use nested `createDirPath`. `createDir` is single-level. |
| `createUniqueFile(base, content) ![]u8` | mv's wrapper; delegates to `test_utils.createUniqueTestFile`. |
| `getPath(".")` | If `name` is `"."`, return `getBasePath()`. mv's wrapper special-cases this. |
| `chdirToBase() !std.Io.Dir` | Allowlisted cwd-behavior tests only. Returns a saved-cwd handle. |
| `restoreCwd(saved: *std.Io.Dir)` | Restores via `setCurrentDir` on the handle (fchdir), then closes it. Panic if restore fails (same reason as today's `ls` helper: a silent failure poisons later tests). |

Do **not** add `joinPath` / `readFile` aliases.
Dest-that-does-not-exist stays `getBasePath` +
`allocPrint`, matching `cp.zig`. mv call sites that
used `readFile` switch to `readFileAlloc`.

Each new method takes the Tiger Style two-assert
minimum (positive and negative space). `chdirToBase`
asserts the resolved path is absolute and non-empty.
`restoreCwd` asserts the handle is a real fd, not
`AT.FDCWD`.

`createFile` / `createDir` / `createSymlink` /
`getPath` / `getBasePath` / `fileExists` /
`readFileAlloc` / `expectFileContent` / `isSymlink` /
`getSymlinkTarget` / `getFileStat` stay as they are.

### Box 2 — absolute paths; annotated chdir residual

Sandbox fixtures (mkdir/rmdir cwd dirs, tmpDir used
only as a playground) switch to `TestDir` +
`getPath` / `getBasePath`. No listed test body
creates or deletes via `Dir.cwd().createDir` /
`createDirPath` / `createFile` / `deleteDir` /
`deleteTree`.

Cwd-behavior tests on the allowlist (decision 3)
call `chdirToBase` / `restoreCwd`. Local helpers
`testChdirToTmp` / `testRestoreCwd` are deleted.

TODO.md box 2 is checked **with** an inline note
naming `chdirToBase` and pointing at this plan.
Do not check it as if fchdir were gone.

`tr.zig` has zero `tmpDir` and no cwd fixtures
(stdin mocks). The lint still lists it; the box
checks off because there is nothing to migrate, not
by inventing filesystem tests.

`src/ls/types.zig`'s non-repo GitContext test
intentionally uses `/tmp/...` **outside** the worktree
because `testing.tmpDir` nests under `.zig-cache` and
would be found by the upward `.git` walk. Keep that
`/tmp` fixture. It is not a `tmpDir(` call. Do not
"fix" it onto `TestDir`.

### Lint (test-writer owned)

This is a refactor: existing unit tests stay GREEN.
The tooth is a **source lint**.

**Test-writer owns** `src/common/testdir_lint.zig`
(scan logic + its own fixture tests) **and** the
caller test in `src/common/lib.zig` (same hole-close
as `force_import_lint`: if the module is dropped from
the force-import block, the caller in `lib.zig` still
fails). The test-writer also force-imports the module
and derives `src` from `dirname(common_source_dir)`.
The test-writer does **not** migrate utility tests and
does **not** add API methods to `test_dir.zig`.

**Implementer owns** `test_dir.zig` API lifts, the
mechanical migration, deleting mv's wrapper, the
`TESTING_STRATEGY.md` File System Testing snippet,
and checking the four `TODO.md` boxes (box 2
annotated). The implementer does **not** edit
`testdir_lint.zig` or the `lib.zig` caller test.

Do **not** add `tests/utilities/testdir_lint_test.sh`
(the runner would look for a `testdir_lint` binary).
A `just test-testdir-lint` recipe is optional sugar;
`zig build test` is the gate because that is what CI
runs.

Locked needles (call sites, not comments):

| Needle | Where | After GREEN |
| --- | --- | --- |
| `testing.tmpDir(` / `std.testing.tmpDir(` | listed files | zero |
| `inner: common.test_dir.TestDir` | `src/mv.zig` | zero (wrapper gone) |
| `Threaded.chdir(` / `setCurrentDir(` | listed files | zero |
| `chdirToBase(` | listed files | only in the 28 allowlisted bodies; each of those bodies has ≥1 call |
| `Dir.cwd().createDir(` / `createDirPath(` / `createFile(` / `deleteDir(` / `deleteTree(` | listed **test bodies** only | zero |

`src/common/test_dir.zig` **may** contain `tmpDir(`
and `Threaded.chdir(` (inside `chdirToBase`). Do not
scan it. Do not scan
`src/common/{walker,file_ops,git,path,file}.zig`,
`src/date.zig`, or `src/cp.zig`.

Negative / positive fixture tests inside
`testdir_lint.zig` (synthetic buffers, not the live
tree):

- `testing.tmpDir(.{})` is a hit.
- `std.testing.tmpDir(.{ .iterate = true })` is a hit.
- Multiline `testing.tmpDir(\n    .{}\n)` is a hit.
- Comment `testing.tmpDir nests under .zig-cache`
  (no `(`) is **not** a hit.
- `setCurrentDir(` in a comment is **not** a hit;
  `std.process.setCurrentDir(io, dir)` is a hit.
- `Dir.cwd().createDir(` inside a `test "` body is
  a hit; the same call in a `fn removeDirectories`
  production body is **not**.
- A synthetic `date.zig` buffer with `tmpDir(` is
  **not** a live-tree hit (`hasListedPath` false).
- `hasListedPath("src/date.zig")` is false;
  `hasListedPath("src/ls/main.zig")` is true;
  `hasListedPath("src/common/walker.zig")` is false;
  `hasListedPath("src/ls/sorter.zig")` is true.
- Empty listed table / scanned count ≠ 39 /
  missing file → coverage RED.
- Buffer whose only violation is in
  `src/ls/types.zig` (last path) → RED.

`verify()` against the real tree is RED on current
`main` because listed files still call `tmpDir(`.
That is the required RED. Coverage RED is a second
failure, never a substitute.

### Migration rules

- Replace `var tmp_dir = testing.tmpDir(.{}); defer
  tmp_dir.cleanup();` with `TestDir.init` / `deinit`.
- `tmp_dir.dir.createFile` / `writeFile` /
  `createTestFile(..., tmp_dir.dir, ...)` become
  `test_dir.createFile` when that is a one-line
  content write. Otherwise `test_dir.dir()`.
- `tmp_dir.dir.realPathFileAlloc(..., name)` becomes
  `test_dir.getPath(name)` for existing names, or
  `getBasePath` + `allocPrint` for names that do not
  exist yet (dest paths, symlink paths that must not
  be resolved — see `cp.zig` comments).
- Nested dirs: `createDirPath` when the parent may
  not exist; `createDir` when it does.
- Operand strings that were relative sandbox names
  become `getPath` / `getBasePath` absolutes, except
  on the chdirToBase allowlist (those keep relative
  operands; that is the behavior under test).
- **May** rewrite expected stdout/stderr substrings
  that embed those fixture paths. Must **not**
  rewrite exit codes or GNU diagnostic templates
  beyond the path.
- Do not touch production functions (`runCat`,
  `runDd`, …).
- Privileged tests keep the `"privileged: "` prefix,
  `TestArena`, `requiresPrivilege`, `withFakeroot`.
  Inside the fakeroot callback, `TestDir.init` takes
  `inner_allocator`.
- Root-permission unit tests keep
  `if (std.c.geteuid() == 0) return error.SkipZigTest;`.
- `mkdir` / `rmdir` cwd fixtures move onto TestDir.
- `mktemp` cleanup of a printed absolute path uses
  `std.fs.deleteDirAbsolute` / `deleteFileAbsolute`,
  not `Dir.cwd().deleteDir`.

## Out of scope

- `### 1` fd-mode five-mode matrix.
- `### 2` POSIX I/O contracts (PR #193).
- `### 5` `main()` writer-setup coverage, including
  Sol's isolated-child rewrite of cwd tests.
- `### 6` dd `conv=` integration coverage.
- `## Bugs` ls pipe single-column.
- `### 4` du color (blocked on #189).
- `### 6` (Modern Features) progress bars (blocked on
  #177).
- Migrating `src/common/{walker,file_ops,git,path,file}.zig`
  (not in the heading's list).
- Migrating `src/date.zig` or `src/env.zig`.
- Changing `TestDir`'s internal use of
  `testing.tmpDir` (the helper still owns a TmpDir).
- Injecting cwd into production `run*` signatures.
- Editing `build.zig`.
- Editing `docs/specs/` flag matrices.
- Editing historical `docs/audit/*` snippets.

## Spec impact

No change. Test infrastructure only.

## Tests

Test-writer and implementer are separate agents.

**Required RED on current `main` (right reason):**
`zig build test` fails because `testdir_lint.verify`
reports `testing.tmpDir(` in a listed file.
Confirmed 2026-08-21: 631 `tmpDir(.{})` call sites
across the listed utilities, 20 of them in
`src/cat.zig`. Record the first listed path from
the report.

**Coverage RED:** missing `testdir_lint.zig` / empty
table / scanned count ≠ 39 / missing file. Distinct
from the needle RED. Must not be the only RED.

**Expected GREEN on current `main` (characterization):**
every existing unit test for the listed utilities.
They stay GREEN through the refactor. After migration,
the lint is also GREEN.

**Prove lint teeth after GREEN (transient sabotage,
never committed):** decision 11 (`wc.zig` option-
bearing `tmpDir`, `mkdir.zig` cwd `createDir`).

Do not skip a failing lint. Do not weaken needles
to comment-matching greps.

## Risks

- **Fakeroot hang.** Inside `withFakeroot`,
  `TestDir.init(inner_allocator)` only.
- **Filter-stdin hangs.** Do not start calling
  `runCat` / `runTee` / … without the existing
  `runUtilWithInput` / file-operand pattern. This
  slice does not add new runUtil calls.
- **`src/common/` boundary.** API lifts stay in
  `test_dir.zig`. Lint is a new common module.
  Do not touch `file_ops.zig` / `walker.zig`.
  Do not edit `build.zig`.
- **Tiger Style.** New TestDir methods and every
  `testdir_lint` function: ≤ 70 lines, two asserts,
  100 columns, bounded loops (`files_max` 64,
  `bytes_max` 2 MiB).
- **macOS signed `st_dev`.** Do not add `@intCast`
  on stat fields while touching tests.
- **getPath on symlinks.** `realPathFileAlloc`
  resolves. For tests that must pass the link path
  unresolved, use `getBasePath` + `allocPrint` (cp
  already documents this).
- **find.zig 122 sites / stat.zig 88.** Mechanical
  but large. The tmpDir lint is the completeness
  gate; do not "finish" a file with one call left.
- **Parallel-test cwd.** Remaining chdir is
  process-global. Restore via handle in `defer`,
  panic on failure. Do not `catch {}` on restore
  (grep's current defer absorbs the error; the ls
  helper panics — this slice uses the ls/panic
  shape for the shared helper).
- **Verbose-path assertions.** mkdir/rmdir tests
  that `find` a relative fixture name in stdout
  must be updated to the absolute path.
- **`NO_COLOR`.** Not involved; no `just it` color
  tests required. Still run `env -u NO_COLOR just it`
  as the GREEN integration gate so a fixture-path
  rewrite cannot silently break a suite.

## TDD sequence

1. Plan consensus (this file, round 2).
2. Test-writer: `testdir_lint.zig` + `lib.zig` caller
   test + force-import. No production Zig. No
   `test_dir.zig` API lifts. No utility migrations.
3. Prove RED: `zig build test` (common tests) fails
   because `verify` found `testing.tmpDir(` in a
   listed file. Record the first listed path.
   Coverage may also fail; that is extra, not instead.
   This commit makes CI red; the PR stays draft.
4. Implementer: API lifts, migrate listed files,
   delete mv wrapper, docs, annotated TODO. Do not
   edit the lint needles or the `lib.zig` caller.
5. Prove GREEN: lint passes; `just fmt-check`;
   `zig build test`; `just test-privileged-local`
   (chmod/chown privileged TestDir sites);
   `just it-util` for a sample of migrated names
   (at least `cat`, `rmdir`, `mkdir`, `mv`, `ls`,
   `grep`, `pwd`) then `env -u NO_COLOR just it`.
6. Sabotage per decision 11, confirm RED, revert
   those lines, confirm GREEN.
