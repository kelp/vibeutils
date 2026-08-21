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

## Classification

Behavior-preserving **test refactor**. No production
behavior change, no flags, no man-page flag tables, no
`docs/specs/` edits. `CHANGELOG.md` gets **no**
user-visible bullet (test-only). `TODO.md` checks the
four boxes under this heading.

`src/common/test_dir.zig` already exists and is what
`src/cp.zig` uses. This slice adopts that helper in the
listed utilities and deletes `src/mv.zig`'s local
wrapper.

## In scope

The four TODO boxes:

1. Replace ad-hoc `testing.tmpDir(.{})` (and
   `std.testing.tmpDir(.{})`) in listed utility tests
   with `common.test_dir.TestDir`.
2. Ensure tests use absolute paths via
   `getPath` / `getBasePath` rather than chdir-as-sandbox.
3. Utilities to migrate (the heading's list, plus `mv`
   from box 4):
   cat, chmod, chown, cut, dd, du, find, grep, head,
   ln, ls, mkdir, mktemp, nl, pwd, readlink, realpath,
   rm, rmdir, stat, tac, tail, tee, test, touch, tr,
   uniq, wc, mv.
   `ls` includes every `src/ls/*.zig` test site
   (`main.zig`, `entry_collector.zig`, `core.zig`,
   `types.zig`, `test_utils.zig`, `security_test.zig`,
   `integration_test.zig`).
4. Delete `src/mv.zig`'s local `TestDir` wrapper;
   call `common.test_dir.TestDir` directly.

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
`arena.allocator()`, never `testing.allocator`:

```zig
var arena = privilege_test.TestArena.init();
defer arena.deinit();
const allocator = arena.allocator();
var test_dir = TestDir.init(allocator);
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
| `chdirToBase() !std.Io.Dir` | See "cwd-behavior tests" below. Returns a saved-cwd handle. |
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

### Box 2 — absolute paths, no chdir-as-sandbox

The heading says "ensure all tests use absolute paths
(no fchdir)". Locked reading:

- Tests that today chdir **only to get a sandbox**,
  then pass relative names, switch to `getPath` /
  `getBasePath` and stop chdir'ing.
- Tests whose **behavior under test is the process
  cwd** cannot be driven with an absolute operand
  without a production API change (out of scope).
  Those tests keep a chdir, but **only** through
  `TestDir.chdirToBase` / `restoreCwd`.

Known cwd-behavior sites (measured 2026-08-21 on
`github/main`):

- `src/grep.zig` — `-r` with no operand searches `"."`.
- `src/ls/main.zig` — `lsMain` resolves relative
  operands against `std.Io.Dir.cwd()`.
- `src/realpath.zig` — `--relative-to=.` (issue #46).
- `src/readlink.zig` — `-m` relative missing tail
  (issue #51).
- `src/pwd.zig` — the utility *is* cwd; the one
  `tmpDir` there does **not** chdir, it only needs
  `getBasePath` for `isValidPwd`.

After this slice, listed utility files contain
**zero** `std.Io.Threaded.chdir` call sites. The only
`Threaded.chdir` for these tests lives inside
`TestDir.chdirToBase`.

Do **not** inject a cwd Dir into `runGrep` / `runLs` /
`runRealpath` / `runReadlink` / `runPwd`. That is a
production change.

`rmdir.zig` tests currently create `test_rmdir_*`
directories in the **process cwd** (`Dir.cwd().createDir`).
That is the parallel-unsafe pattern this box exists to
kill. Migrate those fixtures onto `TestDir` and pass
`getPath` absolute operands. Same for any other listed
file that stages fixtures in cwd rather than a tmpDir
(scan during implementation; rmdir is the known one).

`tr.zig` has zero `tmpDir` and no cwd fixtures (stdin
mocks). The lint still lists it; the box checks off
because there is nothing to migrate, not by inventing
filesystem tests.

`src/ls/types.zig`'s non-repo GitContext test
intentionally uses `/tmp/...` **outside** the worktree
because `testing.tmpDir` nests under `.zig-cache` and
would be found by the upward `.git` walk. Keep that
`/tmp` fixture. It is not a `tmpDir(.{})` call. Do not
"fix" it onto `TestDir`.

### Lint (test-writer owned)

This is a refactor: existing unit tests stay GREEN.
The tooth is a **source lint** that fails while any
listed file still calls `tmpDir(.{})`.

**Test-writer owns** `src/common/testdir_lint.zig`
(scan logic + its own fixture tests) **and** the
caller test in `src/common/lib.zig` (same hole-close
as `force_import_lint`: if the module is dropped from
the force-import block, the caller in `lib.zig` still
fails). The test-writer also force-imports the module.
The test-writer does **not** migrate utility tests and
does **not** add API methods to `test_dir.zig`.

**Implementer owns** `test_dir.zig` API lifts, the
mechanical migration, deleting mv's wrapper, the
`TESTING_STRATEGY.md` File System Testing snippet,
and checking the four `TODO.md` boxes. The implementer
does **not** edit `testdir_lint.zig` or the `lib.zig`
caller test.

Do **not** add `tests/utilities/testdir_lint_test.sh`
(the runner would look for a `testdir_lint` binary).
A `just test-testdir-lint` recipe is optional sugar;
`zig build test` is the gate because that is what CI
runs.

Locked needles (call sites, not comments):

| Needle | Where | After GREEN |
| --- | --- | --- |
| `tmpDir(.{})` | listed files only | zero matches |
| `inner: common.test_dir.TestDir` | `src/mv.zig` | zero (wrapper gone) |
| `std.Io.Threaded.chdir` | listed files only | zero (`chdirToBase` owns it) |
| `test_rmdir_` | `src/rmdir.zig` | zero (cwd fixtures gone) |

`src/common/test_dir.zig` **may** contain `tmpDir(.{})`
(it is the wrapper) and `Threaded.chdir` (inside
`chdirToBase`). Do not scan it. Do not scan
`src/common/{walker,file_ops,git,path,file}.zig`,
`src/date.zig`, or `src/cp.zig`.

Negative controls inside `testdir_lint.zig` fixture
tests (not against the live tree):

- A snippet `var t = testing.tmpDir(.{});` is a hit.
- A snippet `std.testing.tmpDir(.{})` is a hit.
- A comment `testing.tmpDir nests under .zig-cache`
  (no `(.{})`) is **not** a hit.
- A synthetic `date.zig`-shaped buffer with
  `tmpDir(.{})` is **not** a hit when the scanner is
  told the listed-name set (proves the allowlist).
- `hasListedPath("src/date.zig")` is false;
  `hasListedPath("src/ls/main.zig")` is true;
  `hasListedPath("src/common/walker.zig")` is false.

`verify()` against the real tree is RED on current
`main` because `src/cat.zig` (and ~20 siblings) still
call `tmpDir(.{})`. That is the required RED. A
missing module is a second RED (coverage), never a
substitute.

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
- Do not rewrite assertions. Do not change operand
  strings except relative → absolute via `getPath`.
- Do not touch production functions (`runCat`,
  `runDd`, …).
- Privileged tests keep the `"privileged: "` prefix,
  `TestArena`, `requiresPrivilege`, `withFakeroot`.
  Only the tmpDir line changes, and the allocator
  passed to `TestDir.init` is the arena's.
- Root-permission unit tests keep
  `if (std.c.geteuid() == 0) return error.SkipZigTest;`.

## Out of scope

- `### 1` fd-mode five-mode matrix.
- `### 2` POSIX I/O contracts (PR #193).
- `### 5` `main()` writer-setup coverage.
- `### 6` dd `conv=` integration coverage.
- `## Bugs` ls pipe single-column.
- `### 4` du color (blocked on #189).
- `### 6` (Modern Features) progress bars (blocked on
  #177).
- Migrating `src/common/{walker,file_ops,git,path,file}.zig`
  (not in the heading's list).
- Migrating `src/date.zig` (not in the list).
- Changing `TestDir`'s internal use of
  `testing.tmpDir` (the helper still owns a TmpDir).
- Injecting cwd into production `run*` signatures.
- Editing `docs/specs/` flag matrices.
- Editing historical `docs/audit/*` snippets.

## Spec impact

No change. Test infrastructure only.

## Tests

Test-writer and implementer are separate agents.

**Required RED on current `main` (right reason):**
`zig build test` (or `zig test src/common/lib.zig`
once the caller exists) fails because `testdir_lint.verify`
reports `tmpDir(.{})` in a listed file (`src/cat.zig`
is sufficient evidence). Confirmed present 2026-08-21:
`src/cat.zig` has 20 call sites.

**Coverage RED:** missing `testdir_lint.zig` / empty
listed-name set / `verify` that inspects zero files.
Distinct from the needle RED. Must not be the only RED.

**Expected GREEN on current `main` (characterization):**
every existing unit test for the listed utilities.
They stay GREEN through the refactor. After migration,
the lint is also GREEN.

**Prove lint teeth after GREEN (transient sabotage,
never committed):** re-insert one `testing.tmpDir(.{})`
in `src/cat.zig`, confirm the lint goes RED, revert
that one line. Do **not** `git checkout -- src/cat.zig`
(that reverts the whole file).

Do not skip a failing lint. Do not weaken the needle
to a comment-matching grep of `testing.tmpDir`.

## Risks

- **Fakeroot hang.** Privileged tests must pass
  `arena.allocator()` into `TestDir.init`.
- **Filter-stdin hangs.** Do not start calling
  `runCat` / `runTee` / … without the existing
  `runUtilWithInput` / file-operand pattern. This
  slice does not add new runUtil calls.
- **`src/common/` boundary.** API lifts stay in
  `test_dir.zig`. Lint is a new common module.
  Do not touch `file_ops.zig` / `walker.zig`.
- **Tiger Style.** New methods ≤ 70 lines, two
  asserts, 100 columns. `chdirToBase` / `restoreCwd`
  must not become a third copy of the ls helper
  with silent restore.
- **macOS signed `st_dev`.** Do not add `@intCast`
  on stat fields while touching tests.
- **getPath on symlinks.** `realPathFileAlloc`
  resolves. For tests that must pass the link path
  unresolved, use `getBasePath` + `allocPrint` (cp
  already documents this).
- **find.zig 122 sites / stat.zig 88.** Mechanical
  but large. The lint is the completeness gate; do
  not "finish" a file with one tmpDir left.
- **Parallel-test cwd.** Remaining chdir is
  process-global. Restore via handle in `defer`,
  panic on failure. Do not `catch {}` on restore
  (grep's current defer absorbs the error; the ls
  helper panics — this slice uses the ls/panic
  shape for the shared helper).
- **`NO_COLOR`.** Not involved; no `just it` color
  tests required. Still run `env -u NO_COLOR just it`
  as the GREEN integration gate so a fixture-path
  rewrite cannot silently break a suite.

## TDD sequence

1. Plan consensus (this file).
2. Test-writer: `testdir_lint.zig` + `lib.zig` caller
   test + force-import. No production Zig. No
   `test_dir.zig` API lifts. No utility migrations.
3. Prove RED: `zig build test` (common tests) fails
   because `verify` found `tmpDir(.{})` in a listed
   file. Record the first listed path from the report.
4. Implementer: API lifts, migrate listed files,
   delete mv wrapper, docs, TODO. Do not edit the
   lint needles or the `lib.zig` caller.
5. Prove GREEN: lint passes; `just fmt-check`;
   `zig build test`; `just test-privileged-local`
   (chmod/chown privileged TestDir sites);
   `just it-util` for a sample of migrated names
   (at least `cat`, `rmdir`, `mv`, `ls`, `grep`,
   `pwd`) then `env -u NO_COLOR just it`.
6. Sabotage one `tmpDir(.{})` in `src/cat.zig`,
   confirm lint RED, revert that line, confirm GREEN.
