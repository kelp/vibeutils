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
(`src/df.zig`: human-readable sizes unless an explicit size-mode
flag says otherwise). The KEEP default is **unconditional** — not
TTY-gated and not `VIBEUTILS_STYLE`-gated. `VIBEUTILS_STYLE=plain`
still leaves `df` human-readable; `du` and `ls -l` follow that
rule.

Do **not** default argparse `human_readable` fields to `true`.
That would be “as if `-h` was typed” and would leak `ls -h`’s
relative time style. Apply the KEEP default **after** parse, and
keep a separate “user passed `-h` / `--human-readable`” bit for
`ls` time style.

### `du` size mode (argv last-wins)

`du` uses shared argparse. Independent bools do not record order
across flags, so `du -k` and `du -k -h` would look the same if we
only inspected `DuOptions`. `df` last-wins because its parser
walks argv. `du` already has the same pattern for `-P`/`-H`/`-L`
in `resolveDerefMode`.

Add `resolveSizeMode(args)` that scans argv once with bound
`args.len`:

- Stop at `--`.
- Short clusters: each of `h`, `k`, `m`, `g`, `b` is a size-mode
  event (last char in the cluster wins among them). Valued
  `-B SIZE` / `-BSIZE` is the same event as `--block-size`
  (`block_size.short = 'B'`). Skip the SIZE token so it is not
  scanned as a flag.
- Long: `--human-readable`, `--si`, `--bytes`, `--block-size=SIZE`,
  and `--block-size` followed by `SIZE` if that form is accepted
  today.
- No size-mode flag → KEEP default: human, powers of 1024.
- Last event wins: `-h` / `--human-readable` → human 1024;
  `--si` → human 1000; `-k`/`-m`/`-g`/`-b`/`--bytes`/`--block-size`
  → not human, use that scale.

Do not share this helper in `src/common/`. `df` / `du` / `ls` flag
sets differ. Two runtime asserts in the helper (default human when
argv has no size flag; last `-k` clears human).

Update the file comment (it still says 1024-byte blocks by
default), help text, `man/man1/du.1` (same “by default …
human-readable … `-k` restores 1024-byte blocks” family as
`df.1`), and `docs/specs/du-vibeutils.txt`. Flag matrix unchanged;
add a KEEP-default sentence there so auditors do not treat the
default as a GNU mismatch.

`ls` `--block-size` is WONT. Do not mention it as an `ls` override.

### `ls -l` size mode

KEEP default: long listings (`-l`, `-g`, `-n`, `-o`) print human
sizes (powers of 1024).

`-k` / `--kilobytes` suppresses that **implicit** default so the
existing kilobyte branch in `src/ls/formatter.zig` runs.

Explicit `-h` / `--human-readable` always keeps human sizes, even
when `-k` is also present. Clusters `-lhk` and `-lkh` are both
human. Do not change today’s formatter rule that human beats
kilobytes when both option bits are true; set the bits so that
rule matches this policy (`human_readable` true unless `-k` is set
and `-h` is not).

Explicit `-h` still selects relative `time_style`. Bare `ls -l`
does **not**.

`ls -s` without `-l` stays numeric. This slice is `ls -l` only.

Update help, `man/man1/ls.1`, and `docs/specs/ls-vibeutils.txt`.
`-k` here is kilobytes in this implementation, not “POSIX bytes.”
`--block-size` stays WONT.

### Specs and docs

- No new flags. `-h` stays MUST. Do not invent
  `--no-human-readable`.
- `CHANGELOG.md` Unreleased: user-visible KEEP default.
- Check the three TODO boxes.

### Tests (TDD; test agent first)

Behavior, not argparse fields. Fixtures must be allocated files
large enough that human form is not a bare integer. Assert the
size field, not “any suffix on the line.” `ls -l shows sizes` in
`ls_test.sh` greps `[0-9]+`; that still matches `1.0K` — do not
treat it as coverage of this default.

`du` (unit + `tests/utilities/du_test.sh`):

1. Bare `du` on a file >1024 bytes emits a 1024-based unit suffix.
2. Each override is not human: `-k`, `-m`, `-g`, `-b`/`--bytes`,
   `--block-size=1` (and `--block-size 1` if accepted).
3. `--si` emits a 1000-based suffix.
4. Last-wins on argv: `du -h -k` not human; `du -k -h` human;
   clustered `-kh` / `-hk`; `--si` vs `-k` order; `--` stops the
   scan.
5. Existing GNU/POSIX numeric goldens pass `-k` (or
   `--block-size`); do not skip them.

`ls` (option-resolution / `runLs` + `tests/utilities/ls_test.sh`):

1. Bare `ls -l` human size column; date column is the default
   clock style, not relative.
2. `ls -lk` / `ls -l -k` kilobyte size column.
3. `ls -lhk` and `ls -lkh` human sizes.
4. `ls -lh` relative date column (existing `-h` coupling).
5. `ls -s` without `-l` stays numeric.

New default tests are classic RED. Override and
unchanged-output tests that already pass need transient sabotage
during TDD to prove they can fail; do not commit the sabotage.

## Out of scope

- `### 4. Color-Coded Numeric Output`
- `### 5. tree Utility`
- `### 6. Progress Feedback`
- `### 7. Smarter Error Messages`
- LS_COLORS (#187), BSD vmactions (#188)
- Gating human-readable on TTY or `VIBEUTILS_STYLE`
- Changing `df`
- Inventing `--no-human-readable`
- Implementing `ls --block-size` (WONT)

## Spec impact

Design-note in vibeutils help, man pages, and the two
`*-vibeutils.txt` files, plus a KEEP-default sentence on the
matrices. GNU remains the reference for **flag** semantics; the
**default** is a KEEP divergence already shipped for `df`.

## Risks

- Scripts that parse `ls -l` / `du` for raw numbers break the same
  way `df` already did. Changelog says so.
- Neither util reads stdin as a data filter.
- No privileged tests. No `st_dev` path.
- Tiger Style: argv loop bound `args.len`; helper ≤70 lines; two
  asserts in the helper (not only in tests).
- `ls -h` relative time must not leak onto the default.

## Plan review history

Round 1: Grok, GPT, and Fable REQUEST CHANGES. argparse bools do
not last-wins across flags; do not default `human_readable` on
the args struct; `ls --block-size` is WONT; man pages required;
`ls -s` is not a size column of `-l`; explicit `-h` beats `-k`
on `ls` without an argv scan.

This revision locks those.

## Patch review (HEAD after 6361563)

Round 1 on the implementation: Grok, GPT, and Fable REQUEST
CHANGES. `shortClusterEndedInK` scanned attached `-B`/`-t`/`-I`
values, so `du -B1k` Debug-panicked and `-t1k`/`-Ifoo-k` stole
the KEEP default. Fold last-was-k into `applySizeModeCluster`,
stop at valued shorts (`B`/`d`/`I`/`t`), and skip the next argv
token when the value is not attached. Do not scan size-mode
letters inside those values.

Valued longs with a separate token (`--threshold -4k`,
`--ignore-pattern -k`) skip that token the same way; attached
`--threshold=-4k` is already safe because it is one argv word.
Unique GNU prefixes (`--thresh`, `--human-r`, `--blo`) resolve
against the full DuOptions long set, matching argparse, then
classify the canonical name.
