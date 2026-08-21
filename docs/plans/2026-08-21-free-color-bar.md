# Slice: `#### 28. free ✓` (color and usage bar)

## Slice name

`#### 28. free ✓` remaining unchecked items:

- Test: Color-coded memory usage levels (green/yellow/red)
- Implement: Color-coded output with terminal detection
- Implement: Inline usage bar (parallels df's `--bar`)

One heading, one PR. Already-checked free items stay untouched.

## Plan-review decisions (round 1)

Grok, GPT, and Fable all REQUEST CHANGES. Recorded here so the
delta is the contract:

1. **Flag grammar is required-value `--color=WHEN` and
   `--bar=WHEN`**, matching du/wc. argparse optional fields require a
   value (`MissingValue` on bare `--bar`; `--bar -t` would steal
   `-t`). No GNU-style `[=WHEN]`. Invalid WHEN → exit 1.
2. **df has no `--bar` flag.** df draws the `[████████░░]  84%`
   widget when `opts.display.icons == .on` (TTY/full mode). This
   slice copies that *widget and fill math*, not a nonexistent CLI.
3. **Color the used column** of the Mem row and of the Swap row
   (same bands). Headers and the total/free/available/shared/buff
   columns stay uncolored. When the bar is on, color the bar (and
   its percent) with the same band; the used column still gets the
   SGR wrap. Reset after the colored span.
4. **`--color=always` bypasses TTY; `NO_COLOR` and `TERM=dumb`
   still kill color** (ls's guard, not du/wc's initStyle, which
   lets always beat NO_COLOR). `auto` uses `env.isTty` of the real
   stdout fd. `never` is off.
5. **`--bar=always` bypasses TTY; `auto` follows resolved
   `DisplayConfig.icons` (TTY/full); `never` is off.** Default
   WHEN is `auto`.
6. **Do not extract a `src/common/` bar helper this slice.**
   Free-local `formatUsageBar` matching df's
   `filled = @divTrunc(percent * 10 + 99, 100)`. Do not grow
   `df.zig`. GPT asked to extract; Grok and Fable preferred a local
   copy. Local copy wins.
7. **KEEP matrix rows ship in this PR.** The TODO heading already
   named the behavior. Plan review is not a separate spec-approval
   gate (Grok). GPT's spec-first pause is declined for this KEEP
   addition.
8. **Meta `.short = 0`** on both flags. argparse maps `"color"` →
   `-c` (collides with count) and `"bar"` → `-b` (collides with
   bytes).
9. **Inject a resolved render config into `printReport`.**
   `DisplayConfig.resolve()` / `isTty` look at the process stdout
   handle, not the test buffer. Tests pass a config/style, as
   du/wc do. Stage `NO_COLOR`/`TERM` with `env.test_overrides`
   (never libc `setenv`; Zig 0.16 deadlock, issue #95). If color
   is on and `ColorMode.detect()` is `.none`, fall back to
   **basic** (df `runDf_resolveColorMode`). Color tests pin basic
   SGR `32`/`33`/`31`.
10. Pack color/bar into a small render-options struct. Do not
    thread six more parameters through `displayOnce` /
    `runFree_displayContinuous`. Resolve config once before the
    `-s`/`-c` loop and reuse it each frame.

## In scope

- **Color bands** (df `applyUsageColor`): green `percent < 70`,
  yellow `percent < 90`, red otherwise. Percent is
  `used * 100 / total` clamped to 100, or **0 when total is 0**
  (df `calcUsagePercent`; no divide-by-zero). `u8`. `@divTrunc`.
- **Bar:** 10 cells, U+2588 filled / U+2591 empty, then a space and
  `{d:>3}%`, same fill formula as df.
- **Flags:** `--color=WHEN` and `--bar=WHEN` (required value),
  WHEN ∈ {always, auto, never}. Document in
  `docs/specs/free-flags.md` (KEEP), `free --help`, `man/man1/free.1`.
- **Files:** `src/free.zig`, `docs/specs/free-flags.md`,
  `man/man1/free.1`, `CHANGELOG.md`, `TODO.md`. No `build.zig`.
  `tests/utilities/free_test.sh` for flag-level integration.

## Out of scope

- `#### 29. dd ✓` and every later heading
- Existing free flags, including the pre-existing `--si` vs WONT
  matrix mismatch
- Changing df, extracting a shared bar module, `LS_COLORS`
- argparse optional-value support
- `--no-swap` (not in the matrix)

## Spec impact

KEEP rows. GNU column stays `n/a` (procps convention in this
matrix). No POSIX/macOS/OpenBSD flag.

## Tests (failing first, separate test-writer)

Unit tests in `src/free.zig`. Names must not contain `#`. Drive
`printReport` with a buffer writer, injected render config, and
`env.test_overrides` (`NO_COLOR = null`, `TERM` pinned). Fixture
`MemInfo`; do not parse `/proc/meminfo`.

Color (basic SGR; wrap the used field; reset after):

1. `free colors used-percent green below 70` — 50% and **69%**.
   Used column is wrapped in `32`; Total is not.
2. `free colors used-percent yellow from 70` — **70%** and 89%.
   `33`.
3. `free colors used-percent red at 90` — **90%** and 100%. `31`.
4. `free auto emits no color when render.color is off` — injected
   auto-off (the real non-TTY path). No CSI. Same fixture with
   `--color=always` (and NO_COLOR unset in overrides) does emit.
5. `free emits no color when NO_COLOR is set even with --color=always`.
6. `free --color=never emits no color`.
7. `free --color=bogus exits 1` (and `--bar=bogus`).

Bar:

8. `free --bar=always prints a 10-cell usage bar and percent` —
   UTF-8 U+2588/U+2591 bytes; fill count matches
   `@divTrunc(percent * 10 + 99, 100)` for 0, 1, 50, 100.
9. `free --bar=never omits bar glyphs`.
10. `free --bar=auto with icons off omits the bar`.
11. Swap row uses swap_used/swap_total; `swap_total == 0` → 0%, no
    crash, green unused/empty bar.

Integration (`tests/utilities/free_test.sh`), `env -u NO_COLOR`:

12. `free --help` lists `--color=WHEN` and `--bar=WHEN`.
13. `free --color=always` emits CSI; default pipe does not.
14. `free --bar=always` emits bar bytes through a pipe; default
    pipe does not.

Prove RED against current `printReport`. No stdin, no privileged
tests.

## Risks

- **ANSI in pipes:** auto path uses `isTty(stdout fd)`, not
  `ColorMode.detect()` alone.
- **NO_COLOR vs always:** copy ls, not du/wc.
- **Tiger:** helpers ≤70 lines, two asserts, no recursion, `u8`
  percent. `printMemRow` is already ~39 lines — color/bar go in
  helpers. `printReport` is short (~15); pack a render-options
  struct rather than growing arity.
- **`src/common/`:** reuse DisplayConfig, env.isTty, Style,
  test_overrides. Do not add path checks. Do not grow df.zig.
- **Continuous mode:** resolve render config once before the loop;
  reuse each frame (env cannot change; this is not the mv -i
  isatty-per-prompt class).
