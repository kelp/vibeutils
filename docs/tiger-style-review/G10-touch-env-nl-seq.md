# Tiger Style Review: G10-touch-env-nl-seq

**Files reviewed**: 4 files, ~4735 LOC.

---

## src/touch.zig

### Function-length violations (>70 lines)

- `run` — `src/touch.zig:49`, body 84 lines. The error-dispatch block
  for `touchFile` errors (lines 104–129) is the main driver of length;
  it can be extracted into a helper such as `printTouchError`.
- `parseTimestamp` — `src/touch.zig:318`, body 97 lines. Contains three
  distinct length-based parse branches and a validation+conversion tail;
  each deserves its own helper.

### Line-length violations (>100 cols)

55 lines exceed 100 columns. Representative examples:

- `src/touch.zig:29` — 139 cols (`.adjust` meta descriptor)
- `src/touch.zig:49` — 142 cols (function signature)
- `src/touch.zig:52` — 166 cols (`ArgParser.parseOrExit` call)
- `src/touch.zig:95` — 152 cols (`printErrorWithProgram` call)
- `src/touch.zig:541` — 138 cols (`handleError` signature)
- `src/touch.zig:544`–`556` — every arm of `handleError`'s switch
  exceeds 100 cols; most reach 150–163.

The `handleError` switch block is the worst offender; trailing commas
and a multi-line struct literal would let `zig fmt` wrap these.

### Assertion gaps

Zero calls to `std.debug.assert` anywhere in the file. Notable gaps:

- `daysFromYMD` (`src/touch.zig:512`) — civil-day formula is
  non-obvious; no assertion that `m` is in `[1,12]` or `d` in `[1,31]`
  before computing. Callers validate separately, but the function itself
  makes no claim about its preconditions.
- `nsToTimespec` (`src/touch.zig:504`) — no assertion that the
  resulting `.nsec` field is in `[0, 999_999_999]` before returning.
- `parseTimestamp` and `parseIso8601` — computed `days_since_epoch`
  is asserted negative via an `if` that returns an error, but the
  positive-space invariant (that `total_seconds` is representable as
  `i64`) is checked only for `parseTimestamp`, not `parseIso8601`
  (line 481–483). `parseIso8601` uses bare `* 86400` (see below) with
  no overflow check.

### Error handling

- `parseIso8601` (`src/touch.zig:481`) — `day_seconds = @as(i64,
  days_since_epoch) * 86400` is an unchecked multiplication. For large
  years, this can overflow silently. `parseTimestamp` (line 402) guards
  the same multiplication with `std.math.mul`; `parseIso8601` does not.
  This is an inconsistency and a potential overflow bug.

### Naming

- `yy` (`src/touch.zig:351`) — abbreviation for "year (two-digit)".
  Tiger Style bans abbreviations; prefer `year_two_digit`.
- `ts` (`src/touch.zig:195`, `src/touch.zig:362`) — abbreviation for
  `timespec`. Prefer `current_time` or `clock_time`.
- Magic literal `86400` appears three times
  (`src/touch.zig:399,402,481`). It has a comment on line 398 but is not
  a named constant. `std.time.s_per_day` or a local
  `const seconds_per_day: i64 = 86400` would make intent explicit.

### Variable scope / aliasing

- `touchFile` (`src/touch.zig:174`) — `times[0]` and `times[1]` are
  set through four separate branches with identical structure. A helper
  `fn currentTimespec() c.timespec` for the "use current time" branch
  would reduce the scope of the `ts` variable to a single expression.

### Comments

- `parseTimestamp` comments say "use POSIX rules" for the 2-digit year
  branch (line 352–354) but do not explain _why_ 69 is the pivot: this
  is the POSIX-specified Y2K transition point, which future readers may
  not know. A sentence explaining the rationale would satisfy the "always
  say why" rule.
- `daysFromYMD` (`src/touch.zig:512`) — the civil-day formula is
  copied from Chrono (Howard Hinnant's algorithm); a citation or brief
  proof sketch is missing. The comment says only "civil-day formula".

### Types / division

- `src/touch.zig:399` — `std.math.maxInt(i64) / 86400`: this is
  bare `/` on signed integers. Because it is used only to compute a
  maximum bound (truncation toward zero is acceptable here), `@divTrunc`
  should be used explicitly to document intent.
- `src/touch.zig:481` — `@as(i64, days_since_epoch) * 86400`: bare
  integer multiplication with no overflow guard (inconsistent with
  `parseTimestamp`; see Error handling above).

---

## src/env.zig

### Function-length violations (>70 lines)

- `runEnv` — `src/env.zig:84`, body 154 lines. The `-S` split-string
  block alone (lines 120–184) is 64 lines. The verbose output block,
  chdir, and exec call follow. At least three helpers are warranted:
  `processSplitString`, `applyVerboseOutput`, and the main dispatch
  remains readable.
- `parseArgs` — `src/env.zig:241`, body 178 lines. The long-option
  chain (lines 295–329) and the short-option switch (lines 334–403) are
  independently large. Splitting into `parseLongFlag` and
  `parseShortFlags` helpers would bring each under 70 lines.

### Line-length violations (>100 cols)

41 lines exceed 100 columns. Representative examples:

- `src/env.zig:84` — 197 cols (function signature)
- `src/env.zig:88,92` — 146/154 cols (`printErrorWithProgram` calls in
  the parse-error handler)
- `src/env.zig:209` — 155 cols (chdir error message)
- `src/env.zig:241` — 121 cols (parseArgs signature with error union)
- `src/env.zig:462` — 154 cols (execCommand signature)

### Assertion gaps

Zero calls to `std.debug.assert`. Notable gaps:

- `execCommand` (`src/env.zig:462`) — takes `command: []const []const
  u8` but never asserts `command.len > 0`. The sole caller in `runEnv`
  guards this, but the function itself has no precondition assertion.
- `buildEnvMap` (`src/env.zig:422`) — returns a map; no post-condition
  assertion that variables from `assignments` are actually present, even
  a sampling assertion would help.

### Error handling

- `src/env.zig:74–75` — `catch {}` on `stderr.print` and `stderr.flush`
  in the fatal error path is acceptable (we are already exiting), but
  no comment explains this. Add `// best-effort; process is exiting`.
- `src/env.zig:104,109` — `printHelp` and `printVersion` called with
  `catch {}`. A help-print failure is unlikely but silently swallowed
  with no comment. At minimum, document why the error is intentionally
  ignored.
- `src/env.zig:196,199,202,228` — verbose stderr writes all use
  `catch {}` with no comment. These are non-fatal informational writes
  and silencing is defensible, but add a comment.

### Variable scope / aliasing

- `runEnv` (`src/env.zig:84`) — `split_assignments` and
  `split_command` are declared at the top of the `-S` block but their
  scope extends to the bottom of the function via
  `options.command = split_command.items`. This aliases `split_command`
  data into `options.command` without clearly documenting the lifetime
  dependency. If `split_command` were to be freed early, the alias would
  dangle.

### Comments

- `src/env.zig:222–233` — the `-P` block comment explains _what_ it
  does but not _why_ the path must be set in `env_map` at exec time
  rather than at parse time. The spec distinction (affect search only,
  not child env) is mentioned but not the implementation rationale.

---

## src/nl.zig

### Function-length violations (>70 lines)

- `resolveOptions` — `src/nl.zig:207`, body 104 lines. Consists of 9
  nearly identical option-resolution blocks. These could be unified
  with a helper or by factoring out each block into a one- or two-liner
  with a shared `parseStyleOption` pattern.
- `runNl` — `src/nl.zig:559`, body 77 lines. The stdin vs. file
  branching (lines 600–634) accounts for the excess; a helper
  `processInput(reader, ...)` would reduce this below 70.
- `processLine` — `src/nl.zig:480`, body 71 lines. One line over limit.
  The `regex` arm is the longest branch; extracting it as
  `processLineRegex` would solve it.

### Line-length violations (>100 cols)

70 lines exceed 100 columns, the most of any file in this group. The
primary sources are:

- `src/nl.zig:88–108` — `NlArgs.meta` descriptor struct literals
- `src/nl.zig:214,223,232,241,251,267,276,294,304` — all
  `printErrorWithProgram` calls in `resolveOptions`
- `src/nl.zig:559,561` — `runNl` signature and the `parseOrExit` call
- `src/nl.zig:619,628` — file-open error and `numberLines` error calls

### Assertion gaps

Zero calls to `std.debug.assert`. Notable gaps:

- `formatNumber` (`src/nl.zig:363`) — takes `width: u32` but uses it
  as `w: usize = @intCast(width)`. No assertion that `w <= buf.len`
  before any indexing, even though there is an early-return guard
  (`if (w > buf.len) return ""`). Per Tiger Style, assert the positive
  space as well: `assert(buf.len >= w)` (or remove the guard and assert
  instead).
- `isSectionDelimiter` (`src/nl.zig:332`) — asserts implicitly via the
  `if` chain, but `pairs` is computed after a modulo check without
  asserting `line.len % 2 == 0` first.

### Recursion / unbounded loops

- `numberLines` (`src/nl.zig:448`) — `while (true)` with no explicit
  upper bound. The loop terminates only via `error.EndOfStream` or a
  propagated error. Tiger Style requires that non-terminating loops
  assert continuation. A comment explaining why this loop is inherently
  bounded by the stream would satisfy the rule; an assertion would be
  stronger.

### Error handling

- `numberLines` (`src/nl.zig:451–459`) — the `error.StreamTooLong`
  arm reads `reader.buffered()`, outputs the partial line _without_
  numbering, calls `reader.toss()`, then `continue`. This skips the
  numbering logic entirely for overlong lines, which changes program
  behavior silently. There is a comment, but no stderr warning to the
  user.

### Variable scope / aliasing

- `writeUnnumberedLine` (`src/nl.zig:436`) — `total_pad` is computed
  by adding `opts.width` (u32) and `@as(u32, @intCast(opts.separator.len))`.
  The cast from `usize` to `u32` will panic in debug mode if
  `separator.len > std.math.maxInt(u32)`. While a separator longer than
  4 GiB is not realistic, Tiger Style asks for an explicit assertion
  rather than relying on the implicit debug-mode check.

### Comments

- `isSectionDelimiter` (`src/nl.zig:327`) — the doc comment explains
  the structure of the delimiter encoding but does not say _why_ the GNU
  format chose `\:` repeated 1/2/3 times. A one-line historical note
  ("POSIX/GNU nl uses repetition count to distinguish page sections")
  aids maintenance.

### Types / division

- `formatNumber` (`src/nl.zig:364`) — `const w: usize = @intCast(width)`:
  `width` is `u32` (correctly sized) but is widened to `usize` only to
  index slice operations. This is stdlib-bound (slice indexing requires
  `usize`) and is acceptable, but should have a comment noting the
  widening.
- `isSectionDelimiter` (`src/nl.zig:335`) — `const pairs = line.len /
  2`: bare division on `usize`. Intent is exact division (already
  guarded by `line.len % 2 != 0` check above), so this should be
  `@divExact(line.len, 2)` to document intent.

---

## src/seq.zig

### Function-length violations (>70 lines)

- `formatWithSpec` — `src/seq.zig:182`, body 119 lines. The function
  has three logical phases (prefix copy, format-spec parse, suffix
  copy) plus a padding sub-block. Extract `applyPadding` and
  `parseFormatSpec` helpers.
- `run` — `src/seq.zig:463`, body 160 lines. The largest function
  in this group. It handles argument parsing, float validation, format
  selection, precision computation, width computation, and the generation
  loop. At minimum, extract `validateArgs`, `determineFormat`, and the
  generation loop into separate functions.
- `preprocessArgs` — `src/seq.zig:389`, body 71 lines. One line over
  limit; duplicates the known-flag detection logic in two passes.
  Extracting a `isKnownSeqFlag` helper would reduce both passes.

### Line-length violations (>100 cols)

17 lines exceed 100 columns. Key examples:

- `src/seq.zig:463` — 134 cols (function signature)
- `src/seq.zig:474` — 170 cols (`ArgParser.parseOrExit` call)
- `src/seq.zig:511,518,523,530,535,540` — 139 cols each (repeated
  `printErrorWithProgram` + parse-float error handling)
- `src/seq.zig:626` — 139 cols (`printNumber` signature)

### Assertion gaps

Zero calls to `std.debug.assert`. Notable gaps:

- `formatScientific` (`src/seq.zig:304`) — the two unbounded `while`
  loops (lines 314, 319; see below) have no assertion that `mantissa`
  is finite and non-zero entering the loop. The guard `if (value ==
  0.0) return` handles the zero case, but no assertion before the loops
  asserts `mantissa > 0.0`.
- `run` (`src/seq.zig:463`) — after parsing `increment`, there is a
  zero-check (line 563) but no assertion. Per Tiger Style, important
  invariants should be asserted: `assert(increment != 0.0)` after the
  early-return check.
- `printNumber` (`src/seq.zig:626`) — takes `pad_width: usize` and
  `precision: usize`. No assertions on plausible ranges (e.g., that
  `precision < 32` to bound `appendFracDigits`' fixed `[32]u8` buffer).

### Recursion / unbounded loops

- `formatScientific` (`src/seq.zig:314`) — `while (mantissa >= 10.0)`
  divides `mantissa` by 10 each iteration. If `mantissa` is a denormal
  or if floating-point rounding prevents it ever reaching `< 10.0`,
  the loop may not terminate. The NaN/Inf check in `run` guards the
  call site, but `formatScientific` itself has no precondition assertion
  and no bound. Add `assert(std.math.isFinite(value) and value != 0.0)`
  before entering these loops, and a bound (`exp` should never exceed
  309 for `f64`; assert that).
- `formatScientific` (`src/seq.zig:319`) — same issue for the `while
  (mantissa < 1.0)` loop when counting down.

### Error handling

- `formatWithSpec` (`src/seq.zig:182`) — `buf[pos] = '%'` (line 191)
  and `buf[pos] = fmt_str[i]` (line 291) write into `buf` without
  checking `pos < buf.len` first. If the caller provides a `buf` of
  128 bytes (as `printNumber` does) and the format string plus output is
  longer, these writes index out of bounds silently in release mode.
  Add `if (pos >= buf.len) return error.NoSpaceLeft` before each write.
- `run` (`src/seq.zig:592`) — the double-break pattern (`while ...
  break; if ... break`) is unusual. The loop guard and the inner guard
  are redundant (the inner `if current > last + epsilon then break` is
  identical to the loop condition). This creates confusion about which
  guard is authoritative. Remove one or add a comment explaining why
  both are needed.

### Naming

- `pos` throughout `formatWithSpec` — acceptable as a conventional
  buffer position cursor but verges on abbreviation; `write_pos` or
  `out_pos` is more self-documenting.
- `yy` does not appear here (it is in `touch.zig`), but `w` (`width`),
  `j` (outer loop index in `preprocessArgs`), and `i` (inner) are
  acceptable as `i`/`j` are explicitly allowed by Tiger Style for loop
  indices.
- `src/seq.zig:564` — error message reads `"invalid Zero increment
  value"` with an uppercase `Z` mid-sentence. This is a capitalization
  bug in user-facing output.

### Variable scope / aliasing

- `run` (`src/seq.zig:501–545`) — `first_str`, `incr_str`, `last_str`
  are declared before the `switch` and conditionally assigned inside it.
  The `last_str` variable is left `undefined` at declaration (line 506)
  until the `switch` assigns it. Tiger Style prefers declaring variables
  as close to use as possible; `last_str = undefined` at declaration is
  a footgun if a new branch is added without assigning it.
- `preprocessArgs` (`src/seq.zig:416`) — `@constCast(args)` is used
  to return the original args unchanged. This discards const without
  comment. While logically safe here (the caller owns the slice and will
  not mutate it), it is worth a comment: `// no allocation; safe to
  discard const`.

### Comments

- `formatWithSpec` (`src/seq.zig:182`) — the function is 119 lines
  with no top-level doc comment explaining the subset of printf it
  supports (only `%f`, `%e`, `%g`; not `%d`, `%s`, etc.). The
  `printHelp` text mentions this but the function itself has no comment.
- `run` (`src/seq.zig:592`) — the epsilon `0.5e-10` magic constant for
  floating-point comparison has no comment explaining where it comes from
  or why that specific value is appropriate. GNU seq uses a similar
  tolerance; document the rationale.

### Types / division

- `usize` for `precision`, `pad_width`, `width`, `offset`, `pos`, and
  `dot_pos` throughout `seq.zig`: these are all buffer-index or
  count quantities, and `usize` is appropriate because they interact
  with slice lengths. Acceptable.
- `formatWithSpec` (`src/seq.zig:214`) — `width = width * 10 +
  (fmt_str[j] - '0')`: bare multiplication on `usize` with no overflow
  check. A pathological format string like `%99999999999f` could
  overflow `width`. Use `std.math.mul(usize, width, 10) catch return
  error.NoSpaceLeft` or add an upper bound assertion.

### Performance

- `formatScientific` / `formatWithPrecision` are called once per
  sequence element inside the generation loop. These functions allocate
  stack buffers and recompute from scratch on every call. For large
  sequences (e.g., `seq 1 1000000`) the cost is measurable. The loop
  in `run` could compute the format parameters once outside the loop
  and pass them in. This is a suggestion, not a blocker.
- `writeUnnumberedLine` in `nl.zig` (`src/nl.zig:436`) outputs one
  space at a time via `writer.writeAll(" ")` in a loop. For wide
  columns this is inefficient; a single `writer.writeAll(spaces[0..N])`
  from a pre-allocated spaces buffer would amortize the syscall overhead.

---

## Summary

| Category | Count |
|---|---|
| Function-length (>70 lines) | 9 |
| Line-length (>100 cols) | 183 total (touch:55, env:41, nl:70, seq:17) |
| Assertion gaps | 4 files × 0 assertions = 0 assertions in prod code |
| Recursion/unbounded loops | 3 (nl `while(true)`, seq scientific ×2) |
| Error handling | 7 (overflow in parseIso8601, unguarded buf writes in formatWithSpec, silenced catch{} blocks, StreamTooLong silent behavior) |
| Naming | 5 (yy, ts, magic 86400, uppercase Z in error msg, pos) |
| Variable scope | 4 (last_str undefined, split_command alias, @constCast, separator cast) |
| Comments | 5 (missing why, missing citations, missing bounds rationale) |
| Types/division | 4 (bare `/` on i64, bare `*86400` overflow, @divExact for pairs, usize width overflow) |
| Performance | 2 (per-element format recomputation in seq, char-by-char space write in nl) |

**Overall impression**: The code is functional and well-tested, but
carries pervasive line-length violations (183 lines across four files),
a complete absence of runtime assertions, and two credible correctness
issues — an unguarded integer overflow in `parseIso8601` and
unguarded buffer writes in `formatWithSpec` — that should be addressed
before the next release.
