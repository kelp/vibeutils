# Color-Coded Numeric Output

## Context

TODO.md item #4 has 5 sub-items. Two are already done in
df.zig (`applyUsageColor`, `formatUsageBar`). Three remain:
wc color, du icons, du relative coloring.

## Patterns to Follow (from ls and du)

All utilities share the same infrastructure:

1. **Local `ColorMode` enum** — `always`/`auto`/`never`
   (defined per-utility, e.g. du.zig:19)
2. **Config struct** — holds `color_mode: ColorMode` plus
   other resolved options (e.g. `DuConfig`)
3. **`resolveConfig()`** — parses VIBEUTILS_STYLE first,
   then `--color=WHEN` overrides it
4. **Style init** — `common.style.Style(@TypeOf(writer))`
   with `.init(allocator, writer)` for auto-detection, then
   override `.color_mode` based on resolved ColorMode
5. **Color application** — switch on `style.color_mode` for
   truecolor/extended/basic/none tiers, always `reset()`
6. **Reusable helpers** —
   `common.colors.applySizeColor()` takes `anytype` style,
   branches by color_mode

## Step 1: Update TODO.md

Mark df color and bar items as complete (already implemented
with tests).

## Step 2: wc — Add --color flag (RED then GREEN)

**File:** `src/wc.zig`

Follow du's pattern exactly:
- Add `ColorMode` enum (always/auto/never)
- Add `color: ?[]const u8 = null` to `WcOptions` with
  argparse meta
- Add `WcConfig` struct with `color_mode: ColorMode`
- Add `resolveWcConfig()` — VIBEUTILS_STYLE then --color
- Tests: verify config resolution for each mode, invalid
  value returns error

## Step 3: wc — Color the counts (RED then GREEN)

**File:** `src/wc.zig`

Init `common.style.Style(@TypeOf(stdout))` in `runWc`,
override color_mode per resolved config (match du.zig
lines 540-555). Pass style to `printStats`.

Semantic colors per column (all tiers):
- Lines: cyan / RGB(100, 200, 210)
- Words: green / RGB(115, 195, 120)
- Bytes/chars: yellow / RGB(210, 195, 100)
- Max line length: magenta / RGB(180, 140, 200)
- "total" label: bold

Tests: capture output with style set to specific
color_mode, verify ANSI sequences present/absent. Follow
df.zig test pattern (create style with ArrayList writer,
check output).

Update `--help` text to include `--color=WHEN`.

## Step 4: du — File-type icons (RED then GREEN)

**File:** `src/du.zig`

- Add `show_icons: bool` to `DuConfig`
- Set via VIBEUTILS_STYLE: plain=false, color=false,
  full=true (match ls pattern)
- Add `--icons` flag to options
- In `printEntry`, when icons enabled, call
  `common.icons.getIcon()` with basename and is_directory
  flag, print icon before path
- Tests: verify icon glyph appears in output when enabled,
  absent when disabled

## Step 5: du — Relative size coloring (RED then GREEN)

**Files:** `src/common/colors.zig`, `src/du.zig`

### 5a: New function in colors.zig

Add `applyRelativeSizeColor(style, size, max_size)` —
percentage-based gradient matching `applySizeColor` pattern:
- 0-25%: green tones
- 25-50%: yellow-green
- 50-75%: yellow-orange
- 75-100%: red-orange
- max_size=0: no-op

All four color_mode tiers (truecolor/extended/basic/none).
Tests follow existing `applySizeColor` test pattern.

### 5b: Buffer entries in du.zig

When color is enabled, collect `(size, path)` pairs in an
ArrayList, find max after traversal, then print with
relative coloring. When color disabled, keep streaming
output (current behavior). Replace `applySizeColor` calls
with `applyRelativeSizeColor` when max is available.

## Step 6: Full test suite

Run `zig build test` to verify everything passes.
Manual check: `wc --color=always`, `du --color=always`.

## Key Files

- `src/wc.zig` — color support from scratch
- `src/du.zig` — icons + relative coloring
- `src/common/colors.zig` — `applyRelativeSizeColor`
- `src/common/style.zig` — Style type (reference only)
- `src/common/icons.zig` — icon lookup (reuse as-is)
- `src/du.zig` lines 19-157 — reference for config pattern
- `src/df.zig` lines 795-870 — reference for color tests
