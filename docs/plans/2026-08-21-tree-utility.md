# Slice: tree utility

## Slice name

`### 5. `tree` Utility`

One heading, one PR. Nested boxes under that heading belong
here. Do not pull `### 4. Color-Coded Numeric Output`,
`### 6. Progress Feedback`, `### 7. Smarter Error Messages`,
testing-improvement headings, or `## Bugs`.

## Predecessor gate (recorded deviation)

Listed order would take `### 4` next (`du` color relative to
the largest entry). That heading edits `src/du.zig`, which
open PR #189 also edits. This environment cannot merge.
Branch from `github/main` (`a41eccd`) with an independent
utility so `TODO.md` / `CHANGELOG.md` will still conflict;
rebase after predecessors land. Do not stack on #189.

## Classification

Info/query (directory listing), not a stdin filter. No
`runUtilWithInput`. Classify like `ls` / `find`.

`tree` is **not** POSIX and **not** GNU coreutils. Steve
Baker's `tree(1)` (2.x) is the de facto reference for flags
the TODO names. Where Baker and the TODO disagree, the TODO
wins (`--color=WHEN`, `-h` as help).

## In scope

New `src/tree.zig`, registered **only** in `build/utils.zig`
(do not edit `build.zig`). `runTree`. Arena per invocation.
Do not add walker API this slice.

### Walk

`src/common/walker.zig`. No recursion. `sort_children =
true`. `symlinks = .no_follow`. `order = .pre`. Leave
`WalkConfig.max_depth` at its **safety** default (1024) and
`max_entries` at 16 Mi. `DepthLimitExceeded` /
`EntryLimitExceeded` are hard failures, not `-L`.

Do not follow directory symlinks (Baker `-l` is out of
scope). Do not print `name -> target`.

Preflight each operand with open/stat. A missing or
unreadable root is a stderr diagnostic and a nonzero exit;
do not rely on the walker turning a failed `openDir` into a
`.file` entry.

### `-L` (not walker `max_depth`)

Walker root is depth 0. `-L N` means emit the operand and
descendants with `entry.depth <= N`. After emitting a
**directory** at `depth == N`, call `walker.pruneCurrent()`
so grandchildren are not visited. `-L 1` is the operand's
direct children. `-L 0` emits only the operand (then prune
if it is a directory). Missing, non-numeric, negative, or
overflowing `N` is an error, exit 1.

### `-I`

Baker 2.x **accumulates** repeated `-I` / `--ignore` and
treats `|` inside a pattern as alternation. Do not last-wins.

Argparse optional string cannot store a list. Scan argv
(stop at `--`) for `-I PATTERN`, `-IPATTERN`, `--ignore`,
and `--ignore=PATTERN`. Bound `args.len`. Split each
PATTERN on `|` and match basename with
`common.glob.globMatch`. A name matches if **any**
alternative of **any** `-I` matches. On a matching
directory, `pruneCurrent()` after deciding to skip it so
children do not leak.

Long `--ignore` is KEEP house style (every flag has a long
spelling), not an invented Baker flag.

### Output / box-drawing

UTF-8 `├── ` / `└── ` / `│   ` / `    ` always (no ASCII
fallback this slice). Flush stdout before the writer leaves
scope.

`Entry` has no last-sibling bit, and pre-order streaming
emits a directory's subtree before its next sibling. Buffer
the **filtered** tree (or per-directory filtered child
lists) in the arena, bound by `max_entries`, **then** print.
Connectors use last-**emitted** child after `-a` / `-d` /
`-I` filters. If the alphabetically last child is excluded,
the previous remaining sibling gets `└──`.

Prefix/connector loops are indexed with `u16` to match
`Entry.depth`. No recursion.

Default operand: `.`. Multiple operands: print each tree in
argv order with a blank line between trees, then **one**
combined summary at the end (Baker). A file operand is a
single-node tree (just the name). Trust the OS; no `../`
theater.

Skip `.` and `..`. Skip other `.*` names unless `-a`.

### Flags (this slice)

Matrix header: tree is in no POSIX/macOS/OpenBSD/GNU
coreutils spec. **SHOULD** = Baker `tree(1)` and in this
TODO heading. **KEEP** = vibeutils spelling or convention.
Implement every TODO box this slice even though CLAUDE MUST
(POSIX+other) does not apply.

| Flag | Tier | Behavior |
|------|------|----------|
| `-L N` / `--level=N` | SHOULD | Depth cap via `pruneCurrent`; see above. |
| `-d` / `--directories-only` | SHOULD | Directories only. |
| `-I PATTERN` / `--ignore=PATTERN` | SHOULD | Cumulative ignore; `\|` alternation; prune matching dirs. Repeatable. |
| `-a` / `--all` | SHOULD | Include `.*` names. Needed so the Baker hidden default is usable. |
| `--color=WHEN` | KEEP | `always`/`auto`/`never`. Default `auto`. Not Baker `-C`/`-n`. |
| `--icons=WHEN` | KEEP | `always`/`auto`/`never`. `common.icons`. |
| `--help` / `-h` | KEEP | Help. Baker `-h` is human sizes; we do not implement that. |
| `--version` / `-V` | KEEP | Version (vibeutils `-V`). |

`--level`, `--directories-only`, `--ignore`, `--all` are
KEEP long spellings required by man-page house style.

### Summary

One report after all operands. Baker 2.x counts the listed
root directory (empty dir: `1 directory, 0 files`). British
plurals. Count emitted entries only.

`-d`: Baker prints only `N directories` (no `, 0 files`).
Match Baker.

### Color / icons

Follow `ls`/`wc`: `DisplayConfig.resolve()`, then apply
`--color`/`--icons` WHEN. Gate color on `isTty()`, not only
`ColorMode.detect()`. `NO_COLOR` disables **color**, not
icons (same as `display_config` / `ls`). `--color=always`
still loses to `NO_COLOR`. Icons with `--icons=always` may
appear without color. Cloud tests that need color use
`env -u NO_COLOR`.

### Help, man, specs, changelog

- `common.help.printColorized`.
- `man/man1/tree.1` (mdoc; `mandoc -T lint`; NAME,
  SYNOPSIS, DESCRIPTION, EXIT STATUS, EXAMPLES, SEE ALSO,
  STANDARDS, AUTHORS; no HISTORY).
- `docs/specs/tree-flags.md` with the tier basis in the
  header. Remaining Baker flags (`-l`, `-f`, `-P`, sizes,
  HTML/JSON, `-o`, `--noreport`, …) listed **WONT** this
  slice with one-line rationale. `docs/specs/tree-vibeutils.txt`.
- `CHANGELOG.md` Unreleased.
- Check every box under `### 5`.

## Out of scope

- `### 4` du relative color
- `### 6` progress
- `### 7` smarter errors
- Baker flags marked WONT in the matrix
- New `src/common/` module or walker API
- Editing `build.zig`
- Recursion
- ASCII box-drawing charset
- `name -> target`

## Spec impact

New matrix only. KEEP: `--color=WHEN` vs `-C`/`-n`; `-h`
help vs Baker sizes.

Do not write Zig until this revision's three-model review
ends in consensus.

## Tests (TDD; separate test-writer; all new behavior RED)

Assert **emitted output and exit codes**, never argparse
fields. `common.env.test_overrides` for env, not libc
`setenv`. Unit tests in `src/tree.zig`. Integration
`tests/utilities/tree_test.sh`.

1. Bare `tree DIR`: root name, sorted children, `├──` /
   `└──` / `│` topology, hidden `.dot` absent, summary
   `1 directory, N files` (or the fixture's counts).
2. `-a` includes `.dot`.
3. `-d`: directories only; summary is `N directories` with
   no file clause.
4. `-L 1` on a deeper tree **succeeds** and omits
   grandchildren (`pruneCurrent`, not `DepthLimitExceeded`).
5. `-L 0` prints only the operand.
6. Invalid / missing / negative `-L`: exit 1.
7. `-I '*.log'` excludes matching basenames and prunes a
   matching directory.
8. Repeated `-I skipme -I '*.log'` excludes both.
9. `-I 'skipme|*.log'` same as two alternatives.
10. Last remaining sibling gets `└──` when the
    alphabetically last child is excluded by `-I` or `-d`.
11. Default `.` when no operands.
12. Two directory operands: blank line between trees, **one**
    summary at the end.
13. `--color=never`: no ESC. `--color=always` with `NO_COLOR`
    set: no ESC. `--icons=always` with `NO_COLOR`: icon
    present, no color.
14. `--help` / `--version` / unknown flag / invalid
    `--color`/`--icons` exit codes.
15. Nonexistent operand: stderr, nonzero, no Zig error names.
16. Directory symlink: listed, not followed.

Prove RED before GREEN. Test-writer does not edit production;
implementer does not author those tests.

Gates: `just fmt-check`, `zig build test -Dtest-util=tree`,
`env -u NO_COLOR just it-util tree`, `scripts/tiger-check.sh`,
`scripts/audit-check.sh`, `mandoc -T lint man/man1/tree.1`.
No privileged tests. Do not run the full `just it` unless
needed.

## Risks

- Not a filter; no stdin hang.
- No privileged tests. No `st_dev` `@intCast`.
- `-L` **must not** lower `WalkConfig.max_depth`.
- Buffer the filtered tree; bound `max_entries`.
- Tiger: no recursion; prefix loops bound by depth (`u16`);
  helpers ≤70 lines; two asserts each.
- `isTty()` for color; `NO_COLOR` does not force icons off.
- argparse `-h` is help.

## Plan review history

Round 1: Grok, GPT, and Fable REQUEST CHANGES. `-L` via
walker `max_depth` would error instead of truncate;
`Entry` cannot choose `└──` while streaming; `-I` text
contradicted itself and Baker 2.x accumulates + `|`;
summary/multi-root Baker shape was wrong; spec tiers MUST
were illegal for a no-spec utility; `NO_COLOR` vs icons
must match `ls`; tests incomplete.

This revision locks: `pruneCurrent` for `-L`/`-I` dirs;
buffer-then-print; cumulative `-I` with `|`; one combined
Baker-2.x summary; SHOULD/KEEP tiers; `ls` color/icon
precedence; expanded RED tests. Long aliases stay KEEP
house style (GPT asked to drop them; man-page house style
requires a long spelling).
