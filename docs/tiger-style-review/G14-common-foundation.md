# Tiger Style Review: G14-common-foundation

**Files reviewed**: 13 files in `src/common/`, ~5,777 LOC total.

---

## src/common/argparse.zig

### Function length

`ArgParser.parse` (lines 49–173) runs **125 lines** — nearly double the 70-line
limit. The outer loop contains two distinct phases (flag parsing and positional
collection) followed by an `inline for` field fixup. These are separable.

Location: `src/common/argparse.zig:49`
Fix: Extract a `parseFlags` helper (the `while (i < args.len)` block) and a
`collectPositionals` finalisation step. Keep `parse` as the thin coordinator.

### Assertions

Zero runtime assertions across all parsing helpers. This is the most-used
module in the codebase — every utility calls `ArgParser.parse` or
`ArgParser.parseOrExit` — making assertion gaps here higher-leverage than
anywhere else.

- `parse`: no assertion on `args.len`, no postcondition on `result`.
- `parseLongFlagWithValue` / `parseShortFlagWithValue`: no assertion that
  `provided_value` and `next_arg` are not both non-null simultaneously, nor
  that the returned `ValueUsage` is consistent with the field type.
- `parseValue`: `flag_name` and `position` are immediately discarded with `_ =`
  (dead parameters). Remove them or use them.

Location: `src/common/argparse.zig:337-339`
Fix: Remove the two dead parameters from `parseValue`'s signature and update
all three call sites (lines 226, 260). Add at least a precondition assertion
at the top of `parse` (e.g., `std.debug.assert(args.len < std.math.maxInt(usize) / 2)`).

### Line length

Multiple function signatures and internal expressions exceed 100 columns:

- Line 203: `parseLongFlagWithValue` signature — 162 chars.
- Line 234: `parseShortFlagWithValue` signature — 155 chars.
- Lines 84, 91, 109, 125, 142, 226, 260: call sites inside `parse` — 108–126 chars.

Fix: Add trailing commas to multi-parameter signatures and let `zig fmt` wrap
them. The function bodies need restructuring as part of the length fix above.

### Error handling

`parseOrExit` at line 392: `stderr_writer.print(...) catch {}` silently discards
a write failure just before returning an error. The caller will see
`error.ParseFailed` with no visible message if the write fails. Acceptable at
program exit but deserves a brief comment explaining the rationale.

### Comments (WHY)

`parseOrExit` documents *what* errors it handles but not *why* `OutOfMemory`
propagates unwrapped while the others are normalised. The asymmetry is
intentional (OOM is unrecoverable) but is only explained in the doc-comment
above the function, not at the `return error.OutOfMemory` site.

---

## src/common/help.zig

### Assertions

No assertions in any public or private function. `colorizeHelp` iterates over
`help_text` without asserting that `pos` advances monotonically or that
`line_end + 1 <= help_text.len` before advancing `pos`.

`containsUtf8` silently truncates strings longer than 256 bytes — a locale
string should never reach 256 bytes in practice, but the truncation is a
silent correctness hazard. An assertion `std.debug.assert(val.len <= 256)`
or a comment explaining the intentional truncation would make this explicit.

Location: `src/common/help.zig:65`

### Line length

- Line 242: `colorizeUsageLine` signature — 121 chars.
- Line 306: `colorizeFlagLine` signature — 102 chars.
- Line 549 (test): assertion string — 121 chars.

Fix: Add trailing commas to the two function signatures.

### API design (`options: struct {}`)

`colorizeHelp` accepts `help_style: anytype` and uses a runtime type dispatch
`blk` to handle both `bool` and `HelpStyle`. The `bool` path is legacy
compatibility. The comment says "backward compatibility" but this is pre-1.0
software with no external users — per project philosophy, the `bool` path
should be deleted and all callers updated to pass `HelpStyle`.

Location: `src/common/help.zig:85-96`

### API naming

`std.mem.indexOf` is used at lines 70–71 (inside `containsUtf8`) but the
project targets Zig 0.16 where the function is `std.mem.find` /
`std.mem.findPos`. `indexOfScalar` is the correct name for scalar searches and
is used correctly elsewhere in the file, but the `indexOf` calls at 70–71 will
not compile under 0.16 without an alias. Verify this compiles — if it does,
document why; if it doesn't, replace with `std.mem.find`.

Location: `src/common/help.zig:70-71`

---

## src/common/lib.zig

### Line length

The three `printXxxWithProgram` function signatures each exceed 100 columns on
a single line:

- Line 199: `printErrorWithProgram` — 150 chars.
- Line 221: `printHintWithProgram` — 149 chars.
- Line 242: `printWarningWithProgram` — 152 chars.

Fix: Add trailing commas; `zig fmt` will wrap them.

### Error handling (`catch {}`)

`fatalWithWriter` (line 161–162) discards both the print and flush failures
with `catch {}` before calling `std.process.exit`. This is acceptable since
the process is terminating, but the rationale deserves a brief inline comment
("best-effort: process is exiting regardless").

The three `printXxxWithProgram` functions call `s.setColor` / `s.reset` with
`catch {}` (lines 207–209, 229–231, 250–252). These are colour escape writes to
a writer that already succeeded for the preceding `writer.print`; the silent
drop is defensible but undocumented.

### Assertions

`null_writer` is a mutable global (lines 129–131). Tiger Style requires all
memory to be statically allocated, but mutable global state that is shared
implicitly across callers is a red flag. The doc-comment warns "not
thread-safe" — this is acceptable for a test helper, but the global state
means two concurrent test helpers sharing `null_writer` will corrupt each
other's buffer. An assertion `std.debug.assert(!in_use)` or a per-call
local writer would be cleaner.

Location: `src/common/lib.zig:129-131`

---

## src/common/main.zig

### Assertions

`runWithBufferedIO` (line 71–85) does not assert that `args.len >= 1` before
indexing `args[1..]`. If called with an empty slice, the slice expression
`args[1..]` will panic with an out-of-bounds access rather than a meaningful
assertion failure. Add `std.debug.assert(args.len >= 1)` at the top.

Location: `src/common/main.zig:80`

### Error handling

`utilityMain` silently flushes stdout and stderr with `catch {}` at lines
60–61 after the run function succeeds. A flush failure means output is silently
lost; the utility exits 0. This is subtle data-loss territory. At minimum, a
non-zero exit code should be returned on flush failure.

Location: `src/common/main.zig:60-61`

---

## src/common/style.zig

Clean file. No significant Tiger Style violations. `ColorMode.detect` takes
`_: std.mem.Allocator` (unused parameter kept for API symmetry) — the discard
is fine given the context.

---

## src/common/colors.zig

### Types and division

`applySizeColor` uses hardcoded integer literals for size thresholds
(`1024`, `100 * 1024`, `1024 * 1024`, `10 * 1024 * 1024`) directly in the
`if` chain without naming them. These are the same threshold values used in
multiple utilities. Naming them as `const kb: u64 = 1024` etc. at the top of
`applySizeColor` or in `constants.zig` would make the intent explicit and
keep them consistent.

Location: `src/common/colors.zig:19-50`

---

## src/common/icons.zig

### Function length

`getIconColorInfo` (lines 955–1047) is **93 lines** — 23 lines over the limit.
The body is a flat sequence of `if (eql(...)) return` branches organised by
category (languages, devops, documents, etc.). The categories are labelled by
comments.

Fix: Split by category into private helpers — `languageIconColor`,
`devopsIconColor`, `documentIconColor`, `mediaIconColor` — each under 25 lines,
and have `getIconColorInfo` dispatch to them. This also makes adding a new
language colour an isolated change.

Location: `src/common/icons.zig:955`

### Types and division

`findExtensionIcon` at line 874 uses bare `/` division:

```zig
const mid = left + (right - left) / 2;
```

This is an integer division; intent is floor division. Use `@divFloor` or at
least a comment. Tiger Style requires explicit intent.

Location: `src/common/icons.zig:874`

### Assertions

`findExtensionIcon` performs a binary search over `extension_map` with no
assertion that the table is actually sorted. A compile-time or startup
assertion that `extension_map[i].ext < extension_map[i+1].ext` for all `i`
would catch accidental ordering bugs when entries are added.

`getIcon` uses a stack buffer of 256 bytes for `lower_name` (line 895) and
silently truncates filenames longer than 255 bytes (via `toLowercase`). This
is documented in the test at line 1189, but the truncation is a correctness
issue for very long filenames: the extension lookup will receive a truncated
string. An assertion or a comment at the call site is needed.

Location: `src/common/icons.zig:895`

### Line length

The `getIconColorInfo` body has many lines exceeding 100 columns (e.g., lines
961–1044). These are data lines, not logic, and the violation is structural —
splitting into helpers (see above) will resolve them.

---

## src/common/unicode.zig

Clean file. `displayWidth`, `calculateUnicodeWidth`, and the helper predicates
are all well within the function-length limit, well-tested, and correctly
bounded. The dual-pass (ASCII fast path, then Unicode slow path) is a sound
performance optimisation.

Minor: `displayWidth` returns `usize` (stdlib-bound for string indexing), which
is appropriate here. No issue.

---

## src/common/glob.zig

### Bounded loops

`globMatchImpl` (lines 13–77) has an outer `while` loop that backtracks on
`*` matches by incrementing `star_si`. The backtracking is bounded by
`string.len` — when `si > string.len` the function returns false. However,
there is no explicit upper-bound assertion. An assertion at the top:

```zig
std.debug.assert(pattern.len < 4096);
std.debug.assert(string.len < 4096);
```

or at least a comment citing the bound (`// bounded by string.len via the
si > string.len guard`) would satisfy Tiger Style's requirement that
non-terminating loops be explicitly documented.

Location: `src/common/glob.zig:19`

### Assertions

`star_si.?` is unwrapped at line 67 without an assertion. It is always safe
because `star_si` is set together with `star_pi` (line 23–24), but this
invariant is implicit. Add `std.debug.assert(star_si != null)` immediately
before the unwrap, or use a separate named pair type.

Location: `src/common/glob.zig:67`

### Naming

`pi` and `si` are abbreviations for "pattern index" and "string index". Tiger
Style permits `i`, `j`, `k` as short names for primitive integer indices, but
`pi` and `si` are two-letter abbreviations — borderline. Given they are used
throughout the function with clear meaning from context, this is marginal.

---

## src/common/format.zig

### Types and division

`formatHumanReadable` uses `value /= base` (line 33) where `base` is an `f64`.
This is floating-point division, so intent is unambiguous. No issue.

`unit_idx` is typed as `usize` but is bounded to `suffixes.len - 1` (at most 6
for the longest table). A `u8` or explicit `u32` would better express the
bounded intent per Tiger Style.

Location: `src/common/format.zig:30`

### Error handling

`bufPrint` failures are silently replaced with the string `"?"` (lines 38,
40, 42). This is a data-loss situation — callers receive `"?"` with no
indication of failure. The `buf` parameter is caller-supplied; if it is too
small the caller should be notified. Return type should be `![]const u8` with
error propagation, or the function should assert that `buf` is large enough for
the maximum output string at compile time.

Location: `src/common/format.zig:38-42`

---

## src/common/terminal.zig

### Line length

Lines 27–29 exceed 100 columns (the `ioctl` match arms for macOS and BSDs):

- Line 27: 114 chars.
- Line 28: 110 chars.
- Line 29: 120 chars.

Fix: Assign the `ioctl` call to a local variable, or add a trailing comma and
let `zig fmt` wrap the match arm.

### Assertions

`getTerminalDimension` returns a parsed `u16` from the `COLUMNS`/`LINES` env
var with no assertion on the parsed value. A terminal width of 0 columns would
cause divide-by-zero in any caller doing column layout. Add:
`std.debug.assert(result > 0)` before returning.

Location: `src/common/terminal.zig:52-53`

---

## src/common/constants.zig

Clean file. Well-tested. One naming note: Tiger Style uses `lower_snake_case`
for all Zig identifiers including constants; `SCREAMING_SNAKE_CASE` constants
like `DEFAULT_TERMINAL_WIDTH` are a C/C++ convention. This is a pervasive
pattern throughout the codebase, so changing it would be a large-scale
refactor, but it is worth noting as a divergence from Zig idiom.

Location: `src/common/constants.zig:23` (and all other `pub const` lines)

---

## src/common/display_config.zig

### Function length

`DisplayConfig.resolve` (lines 38–112) is **75 lines** — 5 lines over the
limit. The function is a single-pass env-var resolution. It could be split by
extracting the VIBEUTILS\_STYLE preset application (lines 52–75) into a private
`applyStylePreset` helper.

Location: `src/common/display_config.zig:38`

### Line length and formatting

Lines 79, 83, 87, and 91 are chained `if ... else if ...` on one line, each
exceeding 100 columns (113–121 chars). They also violate Tiger Style's rule
that compound conditions should be split into nested branches:

```zig
// Current (violates 100-col limit and bracing rule):
if (std.mem.eql(u8, val, "always")) color = .on else if (...) color = .off;

// Fix:
if (std.mem.eql(u8, val, "always")) {
    color = .on;
} else if (std.mem.eql(u8, val, "never")) {
    color = .off;
}
```

Location: `src/common/display_config.zig:79`, 83, 87, 91

---

## Summary

| Category | Count |
|---|---|
| Function-length (> 70 lines) | 4 |
| Line-length (> 100 columns) | 28+ |
| Assertion gaps | 9 |
| Recursion/unbounded loops | 1 |
| Error handling | 5 |
| Naming/abbreviations | 2 |
| Variable scope / dead params | 1 |
| Comments (WHY missing) | 3 |
| Types/division | 3 |
| API design | 2 |

**Overall impression**: The foundation is solid and well-tested, but assertion
coverage is essentially zero across all 13 modules — a particularly high-impact
gap because every utility in the project calls these functions on every
invocation. Fixing the three oversized functions (`parse`, `getIconColorInfo`,
`resolve`) and adding the missing 100-column wraps are the highest-priority
mechanical changes.

**Fix order**:

1. `[IMPORTANT]` Add assertions to `ArgParser.parse`, `runWithBufferedIO`,
   `getTerminalDimension`, `findExtensionIcon`, and `globMatchImpl`'s
   `star_si.?` unwrap — these are the highest-leverage gaps.
2. `[IMPORTANT]` Remove dead `flag_name`/`position` params from `parseValue`
   — `src/common/argparse.zig:337`.
3. `[IMPORTANT]` Split `ArgParser.parse` (125 lines) into helpers
   — `src/common/argparse.zig:49`.
4. `[IMPORTANT]` Split `getIconColorInfo` (93 lines) by category
   — `src/common/icons.zig:955`.
5. `[IMPORTANT]` Fix `bufPrint` silent `"?"` fallback in `formatHumanReadable`
   — `src/common/format.zig:38-42`.
6. `[IMPORTANT]` Fix `display_config.resolve` 100-col `if-else` chains and
   split function to 70 lines — `src/common/display_config.zig:79`.
7. `[IMPORTANT]` Fix `main.zig` stdout/stderr flush failure (silent data loss
   on success path) — `src/common/main.zig:60-61`.
8. `[SUGGESTION]` Drop `bool` overload in `colorizeHelp` (legacy compat in
   pre-1.0 code) — `src/common/help.zig:85`.
9. `[SUGGESTION]` Replace `getIconColorInfo` bare `/` with `@divFloor`
   — `src/common/icons.zig:874`.
10. `[SUGGESTION]` Rename `constants.zig` `SCREAMING_SNAKE_CASE` to
    `lower_snake_case` per Zig convention.
