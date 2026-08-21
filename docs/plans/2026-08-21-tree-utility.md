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
`runUtilWithInput`. Classify like `ls` / `find`: walk the
filesystem, print to stdout, errors on stderr.

`tree` is **not** POSIX and **not** GNU coreutils. The de
facto reference is Steve Baker's `tree(1)`. Where that
tool and this TODO disagree, the TODO heading wins; Baker
tree is the reference for flags the TODO names (`-L`, `-d`,
`-I`, the summary line, box-drawing).

## In scope

New `src/tree.zig`, registered **only** in `build/utils.zig`
(do not edit `build.zig`). `runTree`. Arena per invocation.

### Walk

Use `src/common/walker.zig`. No recursion. `sort_children =
true`. `symlinks = .no_follow`. `order = .pre`. Bound
`max_depth` and `max_entries` from `WalkConfig` (defaults
1024 / 16 Mi). Do not follow directory symlinks this slice
(Baker `-l` is out of scope).

### Output

UTF-8 box-drawing (`├── `, `└── `, `│   `, `    `) with an
explicit prefix stack whose length is the walk depth. ASCII
`|--` / `` `-- `` when stdout is not a TTY or `NO_COLOR` is
set is **not** required; emit UTF-8 always so pipes stay
parseable by tools that expect Baker's default charset.
Flush stdout before the writer goes out of scope.

Default operand: `.` when no positionals. Multiple directory
operands: print each tree in argv order, with a blank line
between trees (Baker). Trust the OS; report kernel errors;
do not block `../`.

Skip `.` and `..`. Skip other names that start with `.`
unless `-a` (Baker default; without `-a` hidden files are
invisible). `-a` is in scope because it is required for that
default to be usable.

### Flags (this slice)

| Flag | Tier | Behavior |
|------|------|----------|
| `-L N` / `--level=N` | MUST (TODO) | Do not descend past depth N. Depth 1 is the operand's children. Invalid / non-numeric N is an error (exit 1). |
| `-d` / `--directories-only` | MUST (TODO) | Emit directories only; still count only directories in the summary files=0. |
| `-I PATTERN` / `--ignore=PATTERN` | MUST (TODO) | Exclude a basename matching `common.glob.globMatch`. Applied to files and directories (pruned). Repeatable: last-wins is wrong; **any** matching pattern excludes (Baker: last `-I` replaces — we match Baker: one pattern, last `-I` wins, because argparse optional string is last-wins and repeating fnmatch lists is extra). Record: last `-I` wins. |
| `-a` / `--all` | SHOULD (Baker) | Include names starting with `.` |
| `--color=WHEN` | MUST (TODO) | `always` / `auto` / `never`. Default `auto`. Color only when `isTty()` and not `NO_COLOR`. Reuse `common.display_config` + `common.style` / `common.icons` truecolor→256→basic like `ls`. Do not invent `-C`/`-n` this slice; `--color` is the TODO spelling. |
| `--icons=WHEN` | KEEP (TODO) | `always` / `auto` / `never`. File-type icons before names via `common.icons`. Gated like `ls` (TTY / `NO_COLOR` / `VIBEUTILS_STYLE`). |
| `--help` / `-h` | MUST | Help. Baker uses `-h` for human sizes; we keep `-h` as help (vibeutils convention). Document the divergence. |
| `--version` / `-V` | MUST | Version. |

Summary line after each tree (Baker default, TODO):
`N directories, M files` (British plural: `1 directory, 0 files`).
Count emitted entries, not ignored ones. Directories include
the root operand.

### Color / icons

Do not leak ANSI into pipes, files, or tests. Gate on
`isTty()`, not only `ColorMode.detect()`. `NO_COLOR` wins
even over `--color=always` (vibeutils house rule; Cloud
`NO_COLOR=1`). Directory names get the directory color;
icons use the existing mapping.

### Help, man, specs, changelog

- Help via `common.help.printColorized`.
- `man/man1/tree.1` (mdoc; `docs/MAN_PAGE_REFERENCES.md`).
- New `docs/specs/tree-flags.md` (matrix; POSIX/macOS/OpenBSD
  columns `--`; GNU column is Baker `tree(1)`, labeled as
  such). `docs/specs/tree-vibeutils.txt` for KEEP notes.
- `CHANGELOG.md` Unreleased.
- Check every box under `### 5. `tree` Utility`.

## Out of scope

- `### 4` du relative color
- `### 6` progress
- `### 7` smarter errors
- Baker flags not in the table: `-l` follow, `-f` full path,
  `-P` include pattern, `-s`/`-h` sizes, `-p` permissions,
  `-u`/`-g`, `-D`, `-F`, `-x`, HTML/JSON, `-o`, `--noreport`,
  `--dirsfirst`, gitignore
- Sharing a new module in `src/common/` (walker, glob, icons,
  display_config already exist)
- Editing `build.zig`
- Recursion

## Spec impact

New matrix. No change to other utilities' matrices. `-h` as
help is a documented KEEP vs Baker. `--color=WHEN` is KEEP vs
Baker `-C`/`-n`.

User-visible design; plan review is the consensus gate. Do
not write Zig until the three-model plan review ends in
consensus.

## Tests (TDD; test agent first)

Unit tests in `src/tree.zig` with a temp fixture (dir, file,
subdir, skipped dotfile). Integration `tests/utilities/tree_test.sh`.

1. Bare `tree DIR` prints the root name, box-drawing children
   sorted by name, and a summary. Hidden `.dot` is absent
   without `-a`.
2. `-a` includes `.dot`.
3. `-d` lists directories only; summary files=0.
4. `-L 1` does not print grandchildren.
5. `-I '*.log'` excludes matching basenames (and prunes a
   matching directory).
6. `--color=never` has no ESC; `--color=always` still respects
   `NO_COLOR`.
7. `--icons=always` emits an icon when color/icons are on and
   `NO_COLOR` is unset.
8. `--help` / `--version` / unknown flag exit codes.
9. Nonexistent operand: stderr + nonzero. No path-traversal
   theater.

Prove RED on 1–5 before implementing each (or the first
failing batch, then green). No stdin reads.

## Risks

- Not a filter; no stdin hang.
- No privileged tests. No `st_dev` `@intCast`.
- Walker `max_depth` vs `-L`: set the walker's depth bound
  from `-L` (plus the root frame). Do not recurse if the
  walker is short.
- Tiger: no recursion; prefix loop bound = depth; functions
  ≤70 lines; two asserts per new helper; `u32` indices.
- `isTty()` for color/icons.
- Cloud `NO_COLOR=1`: integration color tests use
  `env -u NO_COLOR`.
- argparse `-h` is help; do not add Baker human-size `-h`.
- Multiple `-I`: last-wins (argparse optional). Document.
- Box-drawing width vs `common.unicode.displayWidth` if we
  pad; we will not pad columns.

## Plan review history

None yet. This is round 1.
