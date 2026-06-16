# Tiger Style Audit — vibeutils

Baseline audit of the entire `src/` tree against
[Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
which `CLAUDE.md` declares as the project's coding standard. This pass
is **findings-only**: no source files were modified. A separate
remediation plan will triage and address the findings.

Audit date: 2026-05-27.

## Scope

50 Zig source files in `src/` (47 standalone utilities, 11 files in
`src/ls/`, 30 files in `src/common/`), ~59,000 lines of code.
`src/regex_alloc.c` excluded (not Zig).

## How it ran

15 parallel review groups balanced by line count, executed in three
batches of 6 + 6 + 3 `reviewer` subagents. Each agent applied the
same Tiger Style rule set and wrote one structured markdown file.

## Findings files

| Group | Files reviewed | LOC | Findings |
|---|---|---|---|
| [G1-find](G1-find.md) | `find.zig` | 5,584 | Massive functions (`parsePrimary` 798 lines, `evaluate` 410), four recursion paths, 0 assertions, 177 long lines, `std.process.exit` bypassing defers |
| [G2-df-misc](G2-df-misc.md) | `df.zig`, `dirname.zig`, `whoami.zig`, `true.zig`, `false.zig`, `pwd.zig` | 4,680 | Memory leaks in three `df` filesystem helpers (no `errdefer` between `dupe` calls), 8 silent `catch {}` in `runDf`, `pwd.isValidPwd` ignores device number |
| [G3-stat-grep](G3-stat-grep.md) | `stat.zig`, `grep.zig` | 4,814 | `grep.searchDirectory` recursive with no depth limit, `printContextLine` has 11 params on a 240-col line, `processFile` slurps whole file into two parallel arrays, `dupeZ` inside `matchLine` loop is O(n²) per line, OOM corrupts grep exit code |
| [G4-du-sort](G4-du-sort.md) | `du.zig`, `sort.zig` | 4,502 | `du.calculateDu` direct recursion (stack overflow on deep trees), `seen_inodes.put` swallows OOM (double-counting), `readLines` swallows non-OOM I/O errors, output-writer flush failures silenced, ceiling-division uses bare `/` |
| [G5-chmod-dd](G5-chmod-dd.md) | `chmod.zig`, `dd.zig` | 4,246 | `chmodRecursive` direct recursion, `dd.runDd` is 391 lines, unchecked `config.seek * obs` multiplication, `conv_sparse`/parity/`files=` operands silently ignored, `applyConversions` copies whole `DdConfig` per block |
| [G6-printf-tail](G6-printf-tail.md) | `printf.zig`, `tail.zig` | 3,871 | **Infinite loop in `formatSciFloat`/`formatGeneralFloat` on Inf/NaN input**, known-failing test for write-error propagation in `processEscape`, `processSpecifier` is 184 lines, `followFile` silently drops stdout data loss |
| [G7-cp-date-mv](G7-cp-date-mv.md) | `cp.zig`, `date.zig`, `mv.zig` | 4,730 | Mutual recursion in cp's directory walk, direct recursion in `mv.copyDirectoryRecursive`, `mv.run` is 146 lines, `date.parseArgs` is 180 lines, 218 long lines across the three files |
| [G8-ln-id-cut](G8-ln-id-cut.md) | `ln.zig`, `id.zig`, `cut.zig` | 4,134 | `ln.createSingleLink` is 214 lines, `id.runId` is 265 lines, `cut.processFile` and `readLine` use unbounded `while (true)` without termination assert, `LnArgs.L`/`.P` violate snake_case, known-broken test left in suite |
| [G9-chown-test-tr-rm](G9-chown-test-tr-rm.md) | `chown.zig`, `test.zig`, `tr.zig`, `rm.zig` | 5,173 | `chown.chownRecursive` and `rm.removeDirectoryRecursive` direct recursion, `test.isNewerThan`/`isOlderThan` compare only sub-second component (likely wrong for files >1s apart), all errors from recursive removal collapse to `error.AccessDenied` |
| [G10-touch-env-nl-seq](G10-touch-env-nl-seq.md) | `touch.zig`, `env.zig`, `nl.zig`, `seq.zig` | 4,735 | Unguarded integer overflow in `touch.parseIso8601` (inconsistent with `parseTimestamp`), unguarded buffer writes in `seq.formatWithSpec`, unbounded `while` loops in `seq.formatScientific`, 9 functions over 70 lines (worst: `env.runEnv` 178 lines) |
| [G11-readlink-uniq-free-head-wc](G11-readlink-uniq-free-head-wc.md) | `readlink.zig`, `uniq.zig`, `free.zig`, `head.zig`, `wc.zig` | 4,858 | `head.processInput` swallows OOM and returns success, `readlink.resolveCanonicalMissingOk` discards `AccessDenied` errors, `uniq.runUniq` 129 lines with duplicated output-open block, `free.printHelp/printVersion` swallow I/O errors |
| [G12-small-utils](G12-small-utils.md) | `realpath`, `cat`, `timeout`, `mktemp`, `mkdir`, `tac`, `echo`, `rmdir`, `tee`, `basename`, `yes`, `sleep`, `integration_tests` | 7,773 | `timeout.preserve-status` is dead code (both branches identical), `tee.MultiWriter.deinit` silently drops flush errors, `integration_tests.zig` uses pre-0.16 file APIs, `runTimeout` is 149 lines |
| [G13-ls-module](G13-ls-module.md) | all 11 files in `src/ls/` | 4,321 | Likely correctness bug: doubled recursive-listing headers (`entry_collector.processSubdirectoriesRecursively` prints header, then recurses into code that prints header again), `lsMain` is 185 lines, `isInGitRepo` unbounded `while (true)`, 11-param context threading drives most line-length violations |
| [G14-common-foundation](G14-common-foundation.md) | `argparse`, `help`, `lib`, `main`, `style`, `colors`, `icons`, `unicode`, `glob`, `format`, `terminal`, `constants`, `display_config` | 5,777 | `ArgParser.parse` is 125 lines with two dead `_ =` params in `parseValue`, `format.formatHumanReadable` returns literal `"?"` on `bufPrint` failure (callers can't distinguish), `runWithBufferedIO` silently drops final-flush failures, `getTerminalDimension` doesn't assert width > 0 (divide-by-zero risk in callers) |
| [G15-common-fs-test](G15-common-fs-test.md) | `file`, `file_ops`, `directory`, `path`, `mode`, `env`, `time`, `relative_date`, `user_group`, `git`, `prompt`, `privilege_test`, `privilege_test_integration`, `test_utils`, `test_utils_privilege`, `test_dir` | 4,941 | **`privilege_test_integration.zig` and `test_utils_privilege.zig` were not migrated to 0.16 — likely don't compile, providing false test coverage**, `directory.EntryFilter.shouldInclude` panics on empty name, `path.canonicalizeMissing` is 122 lines with O(n²) inner loop, `git.findGitRoot` unbounded ascent loop, `currentTimestampSeconds/Nanoseconds` discard `clock_gettime` errors and may return uninitialized memory |

## Cross-cutting themes

The same patterns recur in nearly every group, so they should be
addressed as systemic fixes rather than one-by-one:

### 1. Zero assertions, project-wide

**Every file in every group reports zero `std.debug.assert` calls in
production code.** Tiger Style requires an average of two per
function. This is the single largest gap. Highest-leverage targets
(used by every utility):

- `src/common/argparse.zig` — every utility calls `ArgParser.parse`.
- `src/common/main.zig` — `runWithBufferedIO` is the entry shim.
- `src/common/file.zig` — `statToFileInfo`, `fstatatToFileInfo`,
  `formatPermissions`, `currentTimestamp*`.
- `src/common/mode.zig` — `toOctal`/`fromOctal`/`parseSymbolic`.
- `src/common/path.zig` — `canonicalizeMissing`.

### 2. Direct or mutual recursion in tree-walking utilities

Every utility that walks a directory tree uses direct recursion with
no depth bound. Tiger Style forbids recursion. **At least eight
recursive paths identified:**

- `src/cp.zig` — mutual recursion `copyDirectoryContents` →
  `copySingleFile` → `copyDirectory` → `copyDirectoryContents`.
- `src/mv.zig:579` — `copyDirectoryRecursive`.
- `src/chmod.zig:401` — `chmodRecursive`.
- `src/chown.zig:411` — `chownRecursive`.
- `src/rm.zig:381` — `removeDirectoryRecursive`.
- `src/du.zig:521` — `calculateDu`.
- `src/grep.zig:1017/1044/1068` — `searchDirectory`.
- `src/find.zig:2720/2738` — `walkPath`; also `parsePrimary` ↔
  `parseUnary` ↔ `parseOr` mutual recursion in the expression parser
  (`find.zig:840/846/1991-2003`).

A shared "directory walker" helper using an explicit bounded
`ArrayList(Frame)` stack would fix all of them in one place.

### 3. Function-length violations are everywhere

The 70-line limit is missed by **20+ functions across the codebase**.
Worst offenders:

| Function | File | Lines |
|---|---|---|
| `parsePrimary` | `find.zig:858` | 798 |
| `evaluate` | `find.zig:1770` | 410 |
| `runDd` | `dd.zig:476` | 391 |
| `runId` | `id.zig:92` | 265 |
| `expandFormatDirective` | `stat.zig` | 251 |
| `parseArgs` | `df.zig` | 218 |
| `createSingleLink` | `ln.zig:371` | 214 |
| `lsMain` | `ls/main.zig` | 185 |
| `processSpecifier` | `printf.zig:233` | 184 |
| `runEnv` | `env.zig` | 178 |
| `parseArgs` | `date.zig:44` | 180 |
| `runCut` | `cut.zig:277` | 161 |
| `formatWithSpec` | `seq.zig` | 160 |
| `parseArgs` | `env.zig` | 154 |
| `runTimeout` | `timeout.zig:287` | 149 |
| `run` | `mv.zig:806` | 146 |

Common pattern: a single `runX`/`parseArgs` function handles
argument parsing, validation, and dispatch in one body.

### 4. Line-length violations are universal

**~1000 lines exceed the 100-column hard limit across the project.**
Root cause is uniform: multi-parameter function signatures and
`printErrorWithProgram` call sites lack trailing commas, so `zig fmt`
cannot wrap them. A mechanical pass adding trailing commas resolves
the majority. Worst single line spotted: 240 cols
(`grep.printContextLine` signature with 11 params).

### 5. Silent error swallowing

Pervasive `catch {}` patterns without justification comments. Two
categories of concrete bugs from this:

- **Silent data loss**: `cp.zig:619` (`setPermissions`), `mv.zig:760`
  (delete-before-rename retry), `tail.zig:282/287/414`
  (`followFile.flush`), `sort.zig:514/570` (output flush),
  `tee.zig:239` (`MultiWriter.deinit` flush), `du.zig:475`
  (`seen_inodes.put` → double counting on OOM).
- **Silent error type collapse**: `rm.zig:447` collapses all
  removal errors to `error.AccessDenied`; `head.zig:270-283` returns
  no-match on OOM (corrupts exit code); `readlink.zig:168/199`
  discards `AccessDenied` as "not a symlink".

### 6. Pre-0.16 stale APIs in privileged-test infrastructure

`src/common/privilege_test_integration.zig` calls
`FakerootContext.init(allocator)` without the required `io`
parameter and uses `.Exited` (pre-0.16 enum) at multiple sites.
`src/common/test_utils_privilege.zig` uses the entire pre-0.16
`std.fs.*` / `std.process.Child.run` surface. Both **likely do not
compile against the current toolchain**, which means they provide
false privileged-test coverage. Verify and fix before relying on
`just test-privileged`.

`src/integration_tests.zig` also uses pre-0.16 file APIs
(`file.close()` missing `io`).

### 7. `usize` overuse

Widespread `usize` declarations for values that are bounded ranges,
indexes into known-small arrays, or 1-indexed positions. Worst:
`cut.zig:Range.start/end` ties a sentinel to platform word size;
`std.fmt.parseInt(usize, ...)` parses user-supplied bounds directly
into platform-width.

### 8. Bare integer division

Multiple bare `/` operators where Tiger Style requires
`@divExact`/`@divFloor`/`@divTrunc`/`div_ceil`:
`du.zig:583`, `nl.zig:335`, `touch.zig:399`, `formatter.zig` (six
places), `find.zig:1814`, `wc.zig`, `cut.zig`,
`integration_tests.zig:318`, `icons.zig:874`, `file.zig:282`.

## Likely correctness bugs surfaced during the audit

The audit was style-focused but several functional bugs fell out:

1. **`printf.zig` infinite loop on Inf/NaN** — `formatSciFloat` and
   `formatGeneralFloat` normalize via `while (abs_val >= 10.0)`. For
   `std.math.inf(f64)`, this never terminates. GNU printf prints
   `inf`; vibeutils hangs.
2. **`test.zig:498/505` `-nt`/`-ot` likely broken across seconds**
   — comparison uses `mtime.nanoseconds` only, not the seconds
   component. Verify `Timestamp` layout; if `nanoseconds` is the
   sub-second part, comparisons are wrong for any two files more
   than one second apart.
3. **`ls/entry_collector.processSubdirectoriesRecursively` likely
   prints recursive headers twice** — prints the header itself, then
   recurses into `printDirectoryListing` which prints it again.
   Integration tests use substring-contains and pass anyway.
4. **`df.zig` memory leaks on partial failure** — three filesystem
   helpers `dupe` multiple strings sequentially with no `errdefer`
   between them; if the second or third dupe fails, earlier
   allocations leak.
5. **`pwd.zig:isValidPwd` cross-device false positives** — checks
   only inode equality, not device number; two different devices can
   share inode numbers on Linux.
6. **`stat.zig %o` directive has identical branches** — the dead
   platform branch produces the same output as the live one.
7. **`stat.zig` `@intCast(i64 → u64)` on `stat_buf.size`** will
   panic at runtime if size is ever negative, with no assertion to
   surface the invariant.
8. **`seq.zig:formatWithSpec` out-of-bounds writes** —
   `buf[pos] = '%'` and friends write into the caller's 128-byte
   buffer without bounds checks.
9. **`touch.zig:parseIso8601` integer overflow** — `days_since_epoch
   * 86400` has no overflow guard, unlike sister function
   `parseTimestamp` which uses `std.math.mul`.
10. **`dd.zig` `conv_sparse`/parity/`files=` silently ignored** —
    parsed, stored, never applied.
11. **`timeout.zig` `preserve-status` dead code** — both branches
    return the same value.
12. **`free.zig` `currentTimestamp{Seconds,Nanoseconds}` may return
    uninitialized memory** — `clock_gettime` return value is
    discarded with `_ =`.

## Suggested next-step grouping for remediation

Roughly ordered by impact-per-effort:

1. **Fix the correctness bugs above** — surfaced by accident, each
   is a small targeted change.
2. **Extract a shared bounded directory walker** — replaces all 8+
   recursive paths in one PR; biggest Tiger Style wins.
3. **Mechanical `zig fmt` pass with trailing-comma sweep** — closes
   ~1000 line-length violations.
4. ~~**Migrate `privilege_test_integration.zig` and
   `test_utils_privilege.zig` to 0.16**~~ — done in commit
   c8324b3 (orphan `src/integration_tests.zig` also removed in
   6c83bc8; stale `ln -P` known-broken comment fixed in e90a923).
   `zig build test-integration` now compiles cleanly; 11 of 24
   tests skip without fakeroot in scope.
5. **Assertion sweep on `src/common/` foundation modules** —
   highest leverage. argparse, main, file, mode, path, terminal.
6. **Split the worst function-length offenders** — `find.zig`,
   `dd.zig`, `id.zig`, `stat.zig` are the obvious starts.
7. **`catch {}` audit** — every site either gets a justification
   comment or propagates the error. Concentrate on the silent
   data-loss list in section 5 above.
8. **Per-utility assertion sweeps** — long tail, do as time
   permits.

## Remediation progress

- ✅ **Phase 0 — Pre-0.16 test infrastructure migration**
  (commits `6c83bc8`, `c8324b3`, `318a023`, `e90a923`).
  `zig build test`, `zig build test-integration`, and `just it`
  all compile and run cleanly.
- ✅ **Phase 1 — Correctness bugs (12 audit items).**
  - `f073d4b` — printf %e/%E/%g/%G Inf/NaN infinite loop
  - `2c1a715` — test(1) -nt/-ot regression cover (audit claim
    was wrong; locked correctness in)
  - `2ec4a2a` + `e835538` — ls -R duplicate directory headers
  - `565f8e9` — timeout --preserve-status SIGKILL dead branch
  - `4a81005` — stat %o dead branch + @intCast assertions
  - `e7d70bd` — df sequential-dupe partial-allocation leaks
  - `bc3c777` — common.file clock_gettime uninitialized read
  - touch parseIso8601 — audit claim unreachable; no fix
    needed (year capped at 4 digits by parser, max
    `days * 86400` ≈ 2.5×10¹¹ vs i64 max 9.2×10¹⁸)
  - `fcbb999` + `3524b62` — pwd PWD validation now compares
    (inode, dev) not inode alone
  - `373b741` + `80f437a` — seq formatWithSpec buffer overflow
    and formatScientific unbounded loops
  - `cc57c2a` + `456a1de` — dd rejects unsupported
    conv=sparse / conv=par* / files= operands at parse time
- ✅ **Phase 2 — shared bounded walker.** All 8 recursive
  tree-walkers migrated onto `src/common/walker.zig`; no direct
  filesystem-walk recursion remains.
  - `64ab8dc` + `4a551f8` — du walker migration (RED/GREEN)
  - `cdf07f6` + `a5eee53` — grep `searchDirectory` → walker
    (fixes `-R` symlink-to-dir descent)
  - `b32624a` + `3081228` — cp recursive copy → walker
    (fixes `-rp` dir mode/mtime, `-rL` cycle diagnostic)
  - `1bef185` — extract shared copy leaves into `common/file_ops`
  - `fe45fe6` + `97db36a` — mv EXDEV fallback → walker
    (fixes read-only-subdir copy, dir mtime, error continuation)
  - `99ee975` + `ea4eca4` — find `walkPath` → walker
    (fixes `-xdev` mount-point emission, `-L` loop diagnostic)
  - Carve-out, tracked separately: find's expression
    parser/evaluator recursion (Pratt refactor).
- ✅ **Phase 3 — function-length splits.** Every function in
  `src/` now fits Tiger Style's 70-line limit; tree-wide
  `long-fn` count is 0. 83 functions across 41 files decomposed
  into named, asserted helpers by faithful extract-method
  (behavior-preserving). Run as 5 size-ordered waves via the
  `phase3-fn-split` ultracode workflow (per-utility plan →
  implement+scoped-verify → prove-teeth → adversarial review);
  full `zig build test` + `just it` (48 utilities) green after
  every wave.
  - Wave 1 (giants ≥200 lines): `find` (parsePrimary 798,
    evaluateLeaf 388), `dd` (runDd 394), `grep`, `id`, `stat`,
    `sort`, `df`, `ln`.
  - Wave 2 (150-199): `ls`, `env`, `date`, `printf`, `tail`,
    `seq`, `cut`.
  - Wave 3 (100-149): `mv`, `timeout`, `uniq`, `mktemp`,
    `chown`, `cp`, `echo`, `wc`, `nl`, `realpath`, `head`, `du`.
    (`cp` also dropped a non-faithful `backup_suffix.len` assert
    the split had introduced.)
  - Wave 4 (71-99): `touch`, `rm`, `tee`, `yes`, `cat`, `tr`,
    `free`.
  - Wave 5 (`src/common/`, run serially since every util
    compiles them): `argparse`, `path`, `style`, `mode`,
    `icons`, `display_config`, `time`.
  - Note for Phase 4: many extracted helpers carry placeholder
    `>=2` asserts that are tautological (e.g. `@TypeOf(x) == u32`,
    `len >= 0` on a usize). Strengthen these into real
    invariants during the assertion sweep.
- ⬜ Phase 4 — assertion sweep.
- ⬜ Phase 5 — mechanical cleanups.
- ⬜ Phase 6 — final verification + summary.

## Methodology notes

- Reviewers had Read/Grep/Glob/LS/Bash/Write/Edit. They were
  instructed not to edit source files; spot-checks via `git status`
  confirm no `src/` files changed.
- Function-length numbers were measured by counting lines from
  opening `{` to matching `}`. One reviewer noted the `awk` brace
  counter can over-report when tests immediately follow a function
  body; treat numbers near the limit as approximate.
- One reviewer accidentally left an `awk` working file named `LONG`
  at the repo root during analysis; it has been cleaned up.
- Reviewers used judgment on assertion gaps: trivial one-line
  wrappers (`ExitCode.from`, `pub fn version() void`) were not
  flagged.
