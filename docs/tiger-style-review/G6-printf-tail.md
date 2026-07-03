# Tiger Style Review: G6-printf-tail

**Files reviewed**: 2 files, ~3871 LOC.

---

## src/printf.zig

### Function-length violations (>70 lines)

- `processEscape` (lines 117–223): 106 lines. A large `switch` over
  escape characters with per-arm logic. Each arm is short but the
  aggregate body exceeds the limit. Extract octal and hex arms into
  `processOctalEscape` / `processHexEscape` helpers.
- `processSpecifier` (lines 233–417): 184 lines. This is the worst
  offender. It combines flag parsing, width parsing, precision
  parsing, and a 15-arm `switch` dispatch — four distinct
  responsibilities in one function. The flag-and-width-and-precision
  parsing section (lines 244–316) is a natural candidate for
  extraction into `parseFormatModifiers(...) FormatSpec`.
- `formatBString` (lines 570–676): 106 lines. Nearly identical
  structure to `processEscape`; same remedy applies. The \x and \0
  arms each embed a small loop that could be a helper.

### Line-length violations (>100 cols)

Production code (excluding test bodies, which repeat the same
pattern mechanically):

- L26: 143 cols — `runPrintf` signature. Add trailing comma to let
  `zig fmt` wrap.
- L28: 116 cols — `printErrorWithProgram` call. Wrap argument list.
- L52: 131 cols — `processFormat` call inside block expression. Wrap
  argument list.
- L97: 128 cols — `processSpecifier` call. Wrap argument list.
- L349: 124 cols — `printErrorWithProgram` call in `processSpecifier`.
- L967: 173 cols — chained ternary in `applyFloatPadding`. Extract
  the prefix-end computation into a named variable.

78 additional lines are over 100 columns in the test section; all
stem from the same repeated `runPrintf(testing.allocator, testing.io,
&args, &buffer_aw.writer, common.null_writer)` call. Adding a
trailing comma to the argument list allows `zig fmt` to wrap.

### Assertion gaps

Zero calls to `std.debug.assert` across the entire file. This is a
blanket violation of the two-asserts-per-function average.

Specific gaps in meaty functions:

- `formatUnsignedBuf` (L839): `pos` starts at `buf.len` (64) and
  decrements once per digit. No assertion that the digit count cannot
  underflow `pos`. A u64 in base 8 requires at most 22 digits; the
  buffer is 64 — safe, but not asserted. Add:
  `std.debug.assert(buf.len >= 22);` at entry and
  `std.debug.assert(pos < buf.len);` after the loop.
- `processSpecifier` (L233): no assertion that `pos < format.len` at
  the function entry (callers guarantee this, but the contract is
  undocumented).
- `formatSignedInt` / `formatUnsignedInt` / `formatHex`: `pos` is
  accumulated into a fixed 128-byte `buf`. No assertion that `pos`
  never exceeds `buf.len`.
- `getNextArg` (L430): no assertion that `arg_idx.*` is
  monotonically non-decreasing across calls (would catch off-by-one
  in callers).

### Recursion / unbounded loops

- `formatSciFloat` (L985), `formatGeneralFloat` (L1053): both contain
  loops of the form `while (abs_val >= 10.0) { abs_val /= 10.0; }`.
  For a finite, non-zero float these terminate in at most ~309
  iterations (range of f64 exponent). For `std.math.inf(f64)` or
  `-std.math.inf(f64)` the condition `Inf >= 10.0` is always true —
  **infinite loop**. GNU printf prints `inf` / `-inf`; this
  implementation has no guard. Fix: check `std.math.isFinite(val)`
  before entering the normalization loop and handle infinity/NaN
  explicitly. No bounds assertion or `@setRuntimeSafety` comment
  justifies the implicit assumption that input is finite.
- `runPrintf` (L49): `while (true)` with a well-placed break on
  `arg_idx <= start_arg_idx` or `arg_idx >= arguments.len`. The loop
  is bounded by argument consumption and the halt flag, but there is
  no assertion documenting the invariant (`arg_idx` is
  non-decreasing, terminates in at most `arguments.len` iterations).

### Error handling

- `processEscape` (L116): the function signature is `!EscapeResult`,
  so errors propagate correctly. However the existing test at L1629
  (`"processEscape should propagate write errors not swallow them"`)
  documents that `runPrintf` reports success (exit 0) even when the
  writer fails, and the test asserts `result != 0` — meaning this
  test is **currently failing**. The write error from `processEscape`
  propagates to `processFormat`, but `processFormat` is called with
  `catch blk: { had_error = true; break :blk false; }` (L51–54),
  which swallows the error and only sets the flag. That means I/O
  errors are demoted to the `had_error` path, which only affects exit
  code, not whether output continues. This is a known bug documented
  by the failing test; flag it for resolution.

### Naming

- `w` and `p` (L279, L300): used as intermediate accumulators for
  `width` and `precision`. These survive into the `if (has_width)
  width = w` assignment. Tiger Style allows `i`, `j`, `k` as
  exceptions for primitives in sort/matrix contexts; `w` and `p`
  here are ordinary parse accumulators and should be named
  `width_acc` / `precision_acc` or the accumulation folded into the
  outer variable directly.
- `v` in `formatUnsignedBuf` (L845): temporary copy of `val` for
  mutation. Name it `remaining` to express intent.
- `_` for the unused `io` parameter in `runPrintf` (L26): acceptable
  in Zig for deliberately unused parameters, and documented.

### Variable scope / aliasing

- `processSpecifier` (L242): `var i = pos + 1` shadows the outer
  loop variable `i` in `processFormat` (L83). Both are `usize`
  position indices. The inner `i` is fine in scope (it's in a
  different function), but the name collision across the call chain
  increases cognitive load. Consider `var spec_i` or `var pos_i` in
  `processSpecifier` to distinguish.
- `FormatSpec` fields `width` and `precision` are `?usize` (L426–427).
  These are format widths, which POSIX limits to reasonable values.
  Using `usize` (pointer-sized on the platform) is wider than
  necessary; `u32` would be sufficient and expresses the bounded
  domain. Flag as `usize`: not stdlib-bound, could be `u32`.

### Comments

- `formatUnsignedBuf` (L838): doc comment says "Format an unsigned
  integer into a buffer." No mention of the `uppercase` parameter's
  effect on digit case, or why the digit is written backwards then
  sliced. A future reader needs to reconstruct the algorithm. Add a
  sentence explaining the right-to-left fill.
- `processEscape` (L114): the `'0'` arm comment says "Octal: \0NNN
  (up to 3 octal digits after the leading 0)" and the `'1'...'7'`
  arm says "Octal: \NNN (up to 3 octal digits, first digit
  included)". The second arm is subtle: `j` starts at `pos + 1` so
  the first character IS the first digit. This distinction is
  important and the comment is correct, but there is no explanation
  of why the two arms differ (the '0' prefix is not counted as a
  digit, while '1'–'7' are).

### Types / division

- `formatUnsignedBuf` (L849, L857): `v % radix` and `v /= radix` use
  bare `/` and `%`. The intent is truncating division; use
  `@divTrunc` and explicit modulo form (`@rem` or document that
  `radix` is always positive and results are non-negative) to show
  intent.
- `value * 16 + digit` (L205, L654): bare `*` without overflow
  annotation. Since `value` is `u8` and the loop runs at most twice,
  overflow is impossible in practice, but no assertion or saturating
  arithmetic (`*%`) makes this explicit. Compare with lines 169 and
  183 which correctly use `*%` for the octal case. The hex arm in
  `processEscape` (L205) and `formatBString` (L654) should use `*%`
  for consistency, or assert `value < 16` before the multiply.
- `width: ?usize` and `precision: ?usize` in `FormatSpec`: as noted
  above, `u32` better expresses the domain.

### Performance

- `writePadding` (L873): writes one byte at a time in a loop. For
  wide output (e.g., `%1000s`), this is 1000 individual `writeByte`
  calls. A `@memset`-based block write through the writer's buffer
  would amortize the overhead.
- `formatBString` (L569): processes one byte at a time. For the
  common non-escape case, a `std.mem.indexOf` scan to the next `\\`
  would let `writeAll` handle runs of plain characters in one call.

### Other observations

- `processEscape` and `formatBString` implement nearly identical
  logic for interpreting backslash escapes (`\n`, `\t`, octal, hex,
  `\c`, etc.), duplicated across ~110 lines. Consolidating into a
  shared `parseEscapeSequence(input, pos) EscapeResult` helper
  would eliminate the duplication and make it impossible for the two
  to diverge.
- `processSpecifier` takes 8 parameters. This is above the threshold
  where argument confusion becomes likely; an `options: struct {}`
  pattern would group `writer`, `stderr_writer`, `allocator`, and
  `had_error` into a context type, reducing the per-call surface.

---

## src/tail.zig

### Function-length violations (>70 lines)

- `runTail` (lines 146–297): 151 lines. Contains argument parsing,
  option construction, file enumeration, follow-mode setup, and error
  reporting — five distinct phases. The follow-mode block (lines
  266–293) alone could be extracted into `enterFollowMode(...)`.
- `followFile` (lines 430–577): 147 lines. Contains the initial
  file-open logic, then splits into a Linux inotify branch (lines
  451–507) and a macOS kqueue branch (lines 508–575), each containing
  near-duplicate rotation and truncation detection logic. Extract the
  rotation detection and inner poll loop into
  `followFileLinux(...)` and `followFileDarwin(...)`.
- `processInputByLinesFromFile` (lines 907–1069): 162 lines. Three
  independent code paths (`from_beginning`, `line_count == null`,
  default) each span ~50 lines and each read and buffer lines
  differently. Extract each path into its own function.
- `processInputByLines` (lines 1072–1179): 107 lines. Same three-path
  structure as `processInputByLinesFromFile`.

### Line-length violations (>100 cols)

41 production lines exceed 100 columns. The most egregious:

- L907: 201 cols — `processInputByLinesFromFile` signature (8
  parameters). Add trailing comma.
- L430: 165 cols — `followFile` signature. Add trailing comma.
- L384: 151 cols — `processInputByLines` call in `processStdin`.
  Wrap argument list.
- L150: 171 cols — `ArgParser.parseOrExit` call. Wrap.
- L281: 173 cols — `printErrorWithProgram` warning in follow setup.
- L626: 143 cols — `std.c.kevent` call in `keventCall`. Wrap.

Function signatures with long parameter lists (L632, L682, L709,
L736, L784, L1072) all need trailing commas to let `zig fmt` wrap.

### Assertion gaps

Zero calls to `std.debug.assert` across the entire file.

Specific gaps:

- `LineBuffer.addLine` (L836): no assertion that `self.capacity > 0`
  (a zero-capacity buffer would divide by zero in
  `(self.next_index + 1) % self.capacity`). No assertion on
  `self.next_index < self.capacity`.
- `LineBuffer.writeAllLines` / `writeAllLinesReversed` (L853, L868):
  no assertion that the iteration index stays within bounds.
- `processInputByBytesNoSeek` (L736): asserts by convention that
  `byte_count <= MAX_CIRCULAR_BUFFER` (the caller checks), but there
  is no in-function assertion documenting this precondition.
- `readNewData` (L401): calls `file.length(io)` twice (once to check,
  once to get the final position). No assertion that the second call
  returns a value `>= last_pos` (it could decrease if the file is
  truncated between calls). A comment explains the intent but no
  assert guards the postcondition.
- `parseSuffixedNumber` (L336): no assertion that `end_of_number > 0`
  before slicing `arg[0..end_of_number]` (the `if (end_of_number ==
  0) return error.InvalidArgument` guard is present, but an assertion
  would make the precondition of the subsequent slice explicit).

### Recursion / unbounded loops

- `followFile` (L430) — inotify path (L461) and kqueue path (L527):
  both contain `while (true)` event loops. These are intentionally
  non-terminating (the function is documented: "runs an infinite loop
  and only returns on error"). Tiger Style requires that
  non-terminating loops assert their continuation property.
  Currently there is no assertion; add a compile-time or runtime
  note: for example, `std.debug.assert(options.follow)` at the top
  of the outer loop body.
- `followFile` inner wait loops (L438, L475, L541): `while (true)`
  waiting for a file to reappear. No timeout, no bound, no assertion.
  Acceptable for a `-F` retry loop but should be commented as
  intentionally infinite and assert the retry condition
  (`options.follow_retry`).
- `processInputByBytesFromBeginningStream` (L709): `while (true)`
  with termination via `EndOfStream`. Bounded by the stream, but no
  assertion documents that `available.len` is always decreasing or
  that the loop terminates.
- `processInputByLinesFromFile` from_beginning path (L919–957): two
  nested `while (true)` loops both terminate only via `return` on
  `EndOfStream`. The skip_count-fast-path (L921–924) always returns
  before reaching the `lines_seen` code at L932. This means the code
  from L932 to the end of the `from_beginning` block is unreachable
  when `skip_count == 0`. There is no `return` or `unreachable` at
  the end of the `from_beginning` block (contrast: `processInputByLines`
  at L1110 does have an explicit `return`). This creates a false
  impression that the function could fall through into the
  `line_count == null` block after the from_beginning path.

### Error handling

- `stdout_writer.flush() catch {}` and `stderr_writer.flush() catch
  {}` appear 10+ times in `followFile` and `runTail`. Silently
  dropping flush errors is arguably correct for the stderr diagnostic
  path (best-effort), but silently dropping stdout flush errors
  (L282, L287, L414) means data loss is invisible. These should
  at least log to stderr before discarding, or propagate.
- `io.sleep(...) catch {}` (L439, L476, L542): sleep errors are
  silently dropped. Acceptable if sleep is best-effort, but the catch
  should be justified by a comment explaining why the error is safe
  to ignore.
- `inotifyRmWatch` (L612): returns `void`; the underlying syscall
  result is discarded. When called during file rotation (L486), a
  failed remove-watch could leave a stale watch descriptor. The
  Linux `inotify_rm_watch` man page lists `EINVAL` as a possible
  error. At minimum, document why the result is safe to ignore.
- `keventCall` (L624): maps all negative return values to
  `error.EventFdNotSupported`, which is a vague error name for
  `kevent(2)` failures. The actual errno (EACCES, EFAULT, EINTR,
  ENOENT, ENOMEM) is lost. Consider retaining `errno` or mapping to
  more specific errors.

### Naming

- `processInputByLines` vs `processInputByLinesFromFile`: the latter
  operates on a `std.Io.File` and the former on a `*std.Io.Reader`.
  The naming is clear about what they take, but the two functions
  share near-identical structure. "FromFile" reads like a modifier;
  "FromReader" / "FromStream" would be more consistent with the
  actual difference.
- `real_file_count` (L269) in `runTail`: counts non-stdin positional
  arguments. `positional_file_count` would be more precise; "real"
  is vague.
- `lc` (L915, L1080): used as a local binding for an `?u64` unwrap.
  Expand to `line_count_unwrapped` or `first_line_num` to reflect
  the semantic (it's the 1-indexed starting line).
- `extra` (L114) in `expandObsoleteArgs`: name does not convey what
  is extra. `obsolete_arg_count` expresses the intent.
- `wd` (L456): watch descriptor from `inotifyAddWatch`. Abbreviation;
  expand to `watch_descriptor`.

### Variable scope / aliasing

- `file_interface` (L393) in `processFile`: created as `&file_reader.interface`,
  then passed to `processInputByBytes`. This is an alias of a field of
  a local struct — valid, but the alias outlives the borrow window
  visually. Tiger Style: do not duplicate variable references; pass
  the struct directly or fold the alias.
- `processInputByLinesFromFile` (L907): takes 8 parameters,
  four of which are booleans (`zero_terminated`, `from_beginning`,
  `reverse`) and one nullable u64 (`line_count`). Callers can
  silently swap these booleans. Use `options: struct { ... }` for the
  boolean/count cluster.

### Comments

- `followFile` (L428): doc comment says "This function runs an
  infinite loop and only returns on error." Correct, but does not
  explain WHY it is split into Linux and macOS branches (kqueue vs
  inotify) or why the branches are structurally duplicated rather
  than sharing a callback. The duplication is intentional (different
  syscall shapes) but the rationale should be stated.
- `processInputByLinesFromFile` from_beginning path: no comment
  explains that the `skip_count == 0` fast path (L921) always
  returns and that L932 is only reached when `skip_count > 0`. The
  missing `return` at L957 (end of from_beginning block) is
  technically safe but needs a comment explaining why fallthrough
  cannot occur.
- `MAX_CIRCULAR_BUFFER` (L733): the constant is well-commented with
  a why. Good example.
- `readNewData` (L399): calls `file.length(io)` twice — once to check
  for new data and once to record the new position after reading.
  No comment explains why the second call is needed instead of
  tracking bytes read. The double-syscall could return different
  values if the file grows again during the read, which would cause
  bytes to be re-read on the next poll. Document or fix.

### Types / division

- `block_count * 512` (L214): bare `*`. Should be
  `@mulWithOverflow` (as used in `parseSuffixedNumber` at L362)
  for consistency, or `std.math.mul(u64, block_count, 512) catch ...`.
- `(block_count - 1) * 512 + 1` (L214): two bare arithmetic
  operators with no overflow check. If `block_count` is 0, the
  subtraction underflows (u64 wraps). The surrounding
  `if (block_count > 0)` guards it, but the expression immediately
  after `if` uses `block_count - 1` without re-asserting
  `block_count > 0`.
- `usize` usage: most `usize` variables (`extra`, `i`, `j`,
  `write_index`, `total_bytes_read`, slice lengths) are required by
  array/slice APIs and are acceptable. `capacity: usize` in
  `LineBuffer` (L815) is slice-sized and fine.
- `@intCast` in `file.handle` → `usize` (L514, L557): silent
  truncation on platforms where `fd_t` and `usize` have different
  widths. Should use `@intCast` with an assertion that the result
  fits, or document the platform assumption.

### Performance

- `readNewData` (L401): calls `file.length(io)` twice: once to check
  `new_end > last_pos` and once at L412 to get the updated position.
  The second call is a syscall (`stat`). Track bytes read from the
  reader loop instead to avoid the second syscall.
- `followFile` inotify path: after a rotation event, all prior
  inotify events in `event_buf` are ignored. The code reads one batch
  of events but only checks `bytes_read > 0` before processing. If
  multiple events arrive in one read (a common inotify behaviour),
  only the first batch is acted on before blocking again — correct but
  could miss a coalesced MODIFY event, forcing an extra round-trip.
  Parsing the full event buffer loop is the standard pattern.
- `processInputByBytesNoSeek` (L736): the circular buffer approach
  iterates the input byte-by-byte inside a `for` loop (L761). For
  typical `BUFFER_SIZE`-sized reads this is efficient, but the inner
  `% buffer_size` on every byte is expensive when `byte_count` is
  small and input is large. A double-copy approach (write then
  wrap) would eliminate the per-byte modulo.

---

## Summary

| Category               | Count |
|------------------------|-------|
| Function-length        | 7     |
| Line-length            | 14+   |
| Assertion gaps         | 12    |
| Recursion/unbounded    | 8     |
| Error handling         | 6     |
| Naming                 | 8     |
| Variable scope         | 4     |
| Comments               | 6     |
| Types/division         | 6     |
| Performance            | 5     |

**Overall impression**: Both files are functionally solid and
well-tested, but neither contains a single `std.debug.assert` call —
a blanket Tiger Style violation. The most urgent issues are the
infinite-loop risk on `Inf`/`-Inf` input in `printf.zig`'s float
normalisation loops (a correctness bug, not just a style gap), and
the several unbounded `while (true)` loops in `tail.zig` that lack
continuation assertions or comments explaining their termination
argument.
