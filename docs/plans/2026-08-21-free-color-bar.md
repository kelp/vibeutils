# Slice: `#### 28. free ✓` (color and usage bar)

## Slice name

`#### 28. free ✓` remaining unchecked items:

- Test: Color-coded memory usage levels (green/yellow/red)
- Implement: Color-coded output with terminal detection
- Implement: Inline usage bar (parallels df's `--bar`)

One heading, one PR. Already-checked free items stay untouched.

## In scope

Color and an inline usage bar on `free`'s Mem (and Swap, when shown)
rows.

- **Color:** used-memory percentage uses df's bands: green 0–69%,
  yellow 70–89%, red 90%+. Gate on `env.isTty(stdout)` **and**
  `DisplayConfig` / `NO_COLOR` / `TERM=dumb`. `ColorMode.detect()`
  alone is not enough (it only reads env; ANSI must not leak into
  pipes). `--color=always` still loses to `NO_COLOR` (vibeutils house
  rule; Cloud Agent `NO_COLOR=1` is why `env -u NO_COLOR` is required
  for color-sensitive integration tests).
- **Bar:** the same `[████████░░]  84%` widget df draws in full/icon
  mode (`formatUsageBar` in `src/df.zig`). Default on when stdout is a
  TTY (df's full mode). `--bar` KEEP forces it; `--bar=never` / piping
  suppresses it. Do not copy df's code — extract a shared helper into
  `src/common/` only if both call sites stay under Tiger caps without
  a grab-bag module. Prefer a small `free`-local helper that matches
  df's fill math (`filled = (percent * 10 + 99) / 100`).
- **Flags (KEEP):** `--color[=WHEN]` (`always`/`auto`/`never`) and
  `--bar` / `--bar=WHEN` with the same WHEN vocabulary as du/wc
  `--color`. Document them in `docs/specs/free-flags.md`,
  `free --help`, and `man/man1/free.1`.
- **Files:** `src/free.zig` (print path + tests),
  `docs/specs/free-flags.md`, `man/man1/free.1`, `CHANGELOG.md`,
  `TODO.md` (check the three boxes). No `build.zig` edit.

## Out of scope

- `#### 29. dd ✓` and every later TODO heading
- Changing already-implemented free flags (`-h`, `-s`, `-c`, `-w`,
  `-t`, units)
- `--si` (matrix WONT; existing `--si` in help is not this slice)
- `LS_COLORS`, df itself, extracting df's gradient bar
- `--block-size` on ls, or the `-s` empty-dir `total 0` follow-up
  from #160

## Spec impact

Spec-first KEEP rows on `docs/specs/free-flags.md`:

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| --color | -- | -- | -- | n/a | yes | KEEP |
| --bar | -- | -- | -- | n/a | yes | KEEP |

procps `free` has neither flag. These are vibeutils additions, same
tier as `du --color` and `wc --color`. The TODO heading already named
the behavior; the matrix edit records it. No GNU semantics to match
beyond "don't invent a second color vocabulary" — reuse df's 70/90
bands and du/wc's WHEN values.

## Tests (failing first, separate test-writer)

Embedded in `src/free.zig`. Names must not contain `#`.

1. `free colors used-percent green below 70` — fixture MemInfo with
   used/total → 50%; `--color=always`; stdout contains green SGR (or
   the Style basic/truecolor sequence df uses), not yellow/red.
2. `free colors used-percent yellow from 70 to 89` — 75%.
3. `free colors used-percent red at 90 and above` — 90% and 100%.
4. `free emits no color when stdout is not a tty` — default auto,
   piped writer; no CSI in the buffer. Positive+negative: same fixture
   with `--color=always` does emit.
5. `free emits no color when NO_COLOR is set even with --color=always`.
6. `free --bar prints a 10-cell usage bar and percent` — contains
   U+2588 / U+2591 (or their UTF-8 bytes) and a percent; fill count
   matches df's formula.
7. `free without --bar on a pipe omits the bar glyphs`.
8. Swap row, when shown, gets the same color/bar treatment from
   swap_used/swap_total.

Prove RED against current `printReport` (no color, no bar). Tests
drive `printReport` / `runFree` with a buffer writer, not a hang on
stdin. No privileged tests. macOS: MemInfo is already abstracted;
fixtures do not parse `/proc/meminfo`.

## Risks

- **ANSI in pipes:** must check `isTty()`, not only `ColorMode.detect()`.
- **NO_COLOR vs `--color=always`:** house rule, NO_COLOR wins; Cloud
  integration runs need `env -u NO_COLOR`.
- **Tiger Style:** `printReport` is already near the line cap; new
  color/bar rendering goes in helpers ≤70 lines, two asserts each, no
  recursion, `u8` percent not `usize`.
- **`src/common/`:** reuse `DisplayConfig`, `env.isTty`, `style.Style`.
  Do not add path validation. Do not grow `df.zig`.
- **UTF-8 bar in tests:** compare UTF-8 bytes, not grapheme columns.
- **Continuous `-s`/`-c`:** each refresh must re-apply color/bar;
  don't skip isatty after the first frame (mv -i hang class).
