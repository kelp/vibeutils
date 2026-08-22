# Slice: Color-Coded Numeric Output leftover `du`

## Slice name

`### 4. Color-Coded Numeric Output` leftover box:

- `du`: color size relative to largest entry

One heading, one PR. `df` usage color, `df --bar`, `du`
icons, and `wc` column colors are already `[x]`. Do not
pull Progress Feedback (`### 6`), leftover human
defaults (`### 3`, PR #189), `tree`, or Success
Criteria.

## Predecessor gate (recorded deviation)

This environment cannot merge. `du.zig` is already
heavily edited on PR #189 (`cursor/todo-vibeutils-style-human-16f1`,
`0cf4b88`, +446). Stack **on that branch**, not on
`github/main` (`a41eccd`), so the relative-color patch
does not fight the KEEP human-size default.

`TODO.md` / `CHANGELOG.md` will still conflict with
other stacked slices. GitHub base for this PR is
`cursor/todo-vibeutils-style-human-16f1` (merge after
#189).

## Classification

`du` already colors the size column via
`common.colors.applySizeColor` using **absolute**
byte tiers (1K / 100K / 1M / 10M). The leftover box
and `docs/plans/2026-03-01-modern-features-design.md`
Feature 4 ask for **relative** color: largest entry
in the listing red, medium yellow, small green.

That is a behavior change, not a check-off. Color
stays gated on the existing display config
(`--color=WHEN`, TTY, `NO_COLOR`). Pipes with
`--color=auto` stay uncolored and **keep
streaming**. Relative color requires knowing the max
printed size, so a color-on run buffers printed
records and emits after the walk.

## In scope

1. Add `applyRelativeSizeColor(style, size_bytes,
   max_bytes)` in `src/common/colors.zig`. Compute
   percent with `u128` (`@divFloor(size * 100, max)`)
   so `size * 100` does not wrap above ~164 PiB
   (`df` #144 / PR #175). `max == 0` is 0%. Tiers
   match `df`'s `applyUsageColor` so the palette is
   one language: green `< 70%` of max, yellow
   `< 90%`, red `>= 90%`. Truecolor / 256 / **basic
   three-color** / none copy `applyUsageColor`'s
   RGB, 256, and green/yellow/red basic mapping —
   **not** `applySizeColor`'s basic-always-green.
   `ls` keeps absolute `applySizeColor`.
   Feature 4's "medium in yellow" is the yellow
   band, not equal thirds: a typical recursive `du`
   listing is mostly green; only near-max lines
   go yellow/red. That is deliberate (`df`
   language).
2. `du`: when `style.color_mode != .none`, record
   each `printEntry` **after** the existing `-t`
   threshold filter (a filtered-out large entry
   must not set max) and emit after the operand
   loop (including `-c` total). Max is the max
   **printed** size. The `-c` `total` line is
   printed output, so it **does** participate: with
   `-c` the sum is usually 100% red and real
   entries are scored against the sum. That is
   deliberate ("largest entry in output"). When
   color is off, keep today's streaming
   `printEntry`. Color-on buffering means walk
   errors on stderr can appear before any stdout
   entries; accept that.
3. Check the leftover `TODO.md` box. CHANGELOG
   Unreleased: `du` colors sizes relative to the
   largest printed entry.

## Out of scope

- Changing `ls` size color.
- New `--color` values or a flag-matrix edit
  (`--color` is already KEEP).
- `df` thresholds or `--bar`.
- Progress Feedback for `cp`/`mv`/`dd`.
- Vendoring GNU tests. Coverage floor.
- Two-pass filesystem walks.

## Spec impact

No `docs/specs/du-flags.md` change. `--color` stays
KEEP. This implements the existing Feature 4 design
note (relative to largest entry). Thresholds are
hardcoded (design: no config for v1).

## Tests

TDD. Test-writer and implementer are separate
agents. Implementer does not edit the guarding
tests.

Tooth (absolute vs relative diverge): two printed
sizes both `>= 10 MiB` (absolute `applySizeColor`
puts both in the top red-orange tier). Relative
70/90-of-max:

- 10 MiB vs 20 MiB = 50% vs 100% → **green vs red**
  (not yellow: 50% is `< 70%`).
- 15 MiB vs 20 MiB = 75% vs 100% → **yellow vs red**
  (`[70, 90)`).

Use `--apparent-size` and sparse `truncate` in the
shell test so the fixture is not a 30 MiB write.
Copy recorded paths off the walker buffer onto the
arena (macOS static-buffer class).

1. `src/common/colors.zig`: `applyRelativeSizeColor`
   none / truecolor / extended / basic for 0%, 50%,
   69%, 70%, 89%, 90%, 100%, `max == 0`, and a
   near-`u64`-max size so `u128` percent cannot
   wrap. At least two asserts per test (positive
   and negative). Basic 50% is green, 75% yellow,
   100% red (df mapping, not always-green).
2. `src/du.zig`: color-on listing with 10 MiB +
   20 MiB: 20 MiB matches 100% red, 10 MiB matches
   50% green (not the absolute `>= 10M` swatch).
   Second listing 15 MiB + 20 MiB: 15 MiB matches
   75% yellow. Color-off still streams identical
   plain text. Equal sizes are all 100% (all red)
   without `-c`. `-c` total participates in max.
   `-t` excludes a larger omitted entry from max
   (the printed max is among surviving rows).
   Buffered walker paths remain distinct copies.
3. `tests/utilities/du_test.sh`: `--color=always
   --apparent-size` with sparse 10 MiB / 20 MiB
   files; `--color=never` has no ANSI. Cloud image
   exports `NO_COLOR=1`; run with `env -u NO_COLOR`.
   `--color=always` still honors `NO_COLOR` (do not
   assert color under ambient `NO_COLOR`).

RED: current `applySizeColor` on 10 MiB and 20 MiB
uses the same `>= 10M` swatch. Prove that before
the implementer switches to relative.

## TDD ownership

- Test-writer: tests above only. No production
  edits (`src/common/colors.zig` function body,
  `src/du.zig` print path).
- Implementer: `applyRelativeSizeColor` + `du`
  buffer-when-color-on. Check TODO box + CHANGELOG.
  Do not alter the guarding tests.

## Risks

- Buffering every printed line when color is on
  delays TTY output until the walk finishes, and
  stderr walk errors can precede stdout. Accept
  for v1; color-off stays streaming.
- Path strings must be copied out of the walker
  buffer (macOS/static-buffer class). Arena.
- Tiger: no recursion; bound the emit loop by the
  recorded count; `printEntry` is near 70 lines —
  split record vs emit rather than growing it.
- `src/common/colors.zig` is shared; do not change
  `applySizeColor` signatures `ls` relies on.
- Filter-stdin: `du` is not a stdin filter.
- Privileged tests: none.

## Files

| File | Who | What |
|---|---|---|
| `docs/plans/2026-08-22-du-relative-color.md` | planner | this plan |
| `src/common/colors.zig` | test-writer tests; implementer fn | relative swatch |
| `src/du.zig` | test-writer tests; implementer print | buffer when color on |
| `tests/utilities/du_test.sh` | test-writer | `--color=always` relative |
| `TODO.md` | implementer | check the `du` color box |
| `CHANGELOG.md` | implementer | Unreleased user-visible |

## Stop condition

- Relative color matches the 70/90-of-max tiers
- Color-off output and streaming unchanged
- `ls` still uses `applySizeColor`
- Leftover `### 4` box checked
