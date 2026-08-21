# Slice: VIBEUTILS_STYLE leftover human-readable defaults

## Slice name

`### 3. VIBEUTILS_STYLE Environment Variable` remaining items:

- `du`: human-readable by default
- `ls -l`: human-readable by default
- Explicit flags always override

One heading, one PR. Do not pull `### 4. Color-Coded Numeric Output`
(`du` color relative to largest entry), `tree`, Progress Feedback,
LS_COLORS, or BSD CI.

## Predecessor gate (recorded deviation)

Issue PRs #171–#181 and TODO PRs #182–#188 are still open. Branch
from `origin/main` (`a41eccd`). This environment cannot merge.
`TODO.md` / `CHANGELOG.md` will conflict; rebase after predecessors
land.

## In scope

Match the `df` KEEP default already recorded in this heading
(`src/df.zig`: `human_readable = true`). That default is
**unconditional** — not TTY-gated and not `VIBEUTILS_STYLE`-gated.
`VIBEUTILS_STYLE=plain` still leaves `df` human-readable; `du` and
`ls -l` follow the same rule.

### `du`

- Change `DuOptions.human_readable` default to `true`.
- Help text: `-h` is the default, same wording family as
  `docs/specs/df-vibeutils.txt` (`print sizes in powers of 1024
  (default)`).
- After argparse, apply last-wins size-mode overrides so an
  explicit size flag turns human-readable **off**:
  `-k`, `-m`, `-g`, `-b` / `--bytes`, `--block-size=SIZE`.
- `--si` keeps human-readable on (base 1000), as today.
- `-h` / `--human-readable` turns it back on if a prior override
  cleared it. argparse already last-wins independent bools; the
  post-parse step must still clear human-readable when a block-size
  flag is set, matching `df` (`-k` / `-P` clear `human_readable`).

### `ls -l`

- Default `human_readable` **on for long listings only** (`-l`,
  `-g`, `-n`, `-o`). Short listings do not print a size column, so
  they are unchanged.
- `-k` / `--kilobytes` must win over the new default: clear
  `human_readable` so the existing kilobyte branch in
  `src/ls/formatter.zig` runs. Today `if (human_readable) … else if
  (kilobytes)` prefers human when both are true.
- Do **not** treat the default as “as if `-h` was typed.” Explicit
  `-h` currently also switches `time_style` to `.relative`
  (`lsMain_resolveTimeStyle`). That coupling stays on the **flag**,
  not on the default. Bare `ls -l` keeps the default time style and
  only changes the size column.

### Specs and docs

- No new flags. `-h` stays MUST in `docs/specs/du-flags.md` and
  `docs/specs/ls-flags.md`.
- Update `docs/specs/du-vibeutils.txt` and `docs/specs/ls-vibeutils.txt`
  so `-h` is documented as the default, with `-k` / `--block-size`
  restoring POSIX numbers.
- `CHANGELOG.md` under Unreleased: user-visible default change.
- Check the three TODO boxes.

### Tests (TDD; test agent first)

Prove RED against current defaults (`human_readable = false`).

`du` (unit + `tests/utilities/du_test.sh`):

1. Bare `du` on a file larger than 1024 bytes emits a unit suffix
   (`K`/`M`/…), not a raw block count.
2. `du -k` on the same file emits an integer block count (no
   suffix).
3. `du --block-size=1` emits bytes (no suffix).
4. `du -h -k` / `du -k -h`: last flag wins.

`ls` (unit in `src/ls/main.zig` or formatter tests +
`tests/utilities/ls_test.sh`):

1. Bare `ls -l` on a file larger than 1024 bytes uses a human size
   (`1.0K` / `1K` style already used by `-h`).
2. `ls -lk` (or `-l -k`) uses the kilobyte branch, not human.
3. Explicit `-h` still selects relative time style; bare `ls -l`
   does **not**.
4. Non-`-l` listings are unchanged.

Existing tests that assert GNU/POSIX numeric sizes from bare `du`
or `ls -l` must pass `-k` (or `--block-size`) instead of being
deleted. Do not weaken GNU comparison tests by skipping them.

## Out of scope

- `### 4. Color-Coded Numeric Output` (`du` color vs largest entry)
- `### 5. tree Utility`
- `### 6. Progress Feedback`
- `### 7. Smarter Error Messages`
- LS_COLORS (#187), BSD vmactions (#188)
- Gating human-readable on TTY or `VIBEUTILS_STYLE`
- Changing `df` (already done)
- Inventing `--no-human-readable`

## Spec impact

Design-note only in the vibeutils help texts. Flag matrices
unchanged. GNU remains the reference for **flag** semantics; the
**default** is a KEEP divergence already shipped for `df`.

## Risks

- Scripts that parse `ls -l` / `du` columns for raw numbers break
  the same way `df` already did. That is the TODO. Document it in
  the changelog.
- Filter-stdin: neither util reads stdin as a data filter; no hang
  risk from this change.
- Privileged tests: none.
- macOS signed `st_dev`: not touched.
- Tiger Style: keep override resolution in a helper under 70 lines;
  two asserts (human on by default; `-k` clears it).
- `ls -h` relative time must not leak onto the default, or `ls -l`
  goldens for the date column all move.

## Plan review history

Round 1: pending.
