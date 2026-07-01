# Tiger Style Review: G1-find

**Files reviewed**: 1 file, 5584 LOC.

---

## src/find.zig

### Function-length violations (>70 lines)

- `parsePrimary` (lines 858–1656): **798 lines**. This function is an enormous
  flat chain of `if (std.mem.eql(...))` branches, one per flag. Suggestion:
  dispatch through a table of `(flag_name, handler_fn)` pairs, or split into
  logical groups (time predicates, path predicates, exec actions, stub
  predicates), each ≤70 lines.

- `evaluate` (lines 1770–2180): **410 lines**. A single `switch` over all
  `ExprTag` variants. The `printf_action` branch alone is ~80 lines. Suggestion:
  extract `evaluatePrintf`, `evaluateSize`, `evaluateTimeExpr` etc. as private
  helpers, each taking only the fields they need.

- `parseArgs` (lines 589–767): **178 lines**. Two passes over the argument
  array (collecting paths, then pre-scanning for global options), followed by
  expression parsing. Suggestion: extract `collectStartPaths` and
  `prescanGlobalOptions` helpers.

- `walkPath` (lines 2577–2747): **170 lines**. Handles stat, xdev checking,
  xargs checking, breadth-first evaluation, descent, sorted/unsorted iteration,
  and depth-first evaluation in a single function. Suggestion: extract
  `walkDir` (the directory iteration logic, lines 2665–2741) and
  `evaluateEntry` (the entry evaluation + prune logic).

- `doStat` (lines 397–466): **69 lines** — one line under the limit, but only
  because the closing brace is on its own line. The Linux `statx` path and the
  macOS `fstatat` path could each be a private helper to keep the function
  clearly under 70.

### Line-length violations (>100 cols)

177 lines exceed 100 columns. 61 of those exceed 150 columns. The worst
offenders, all requiring trailing-comma reformatting:

- L788: 140 cols — `fn parseOr(...)` signature; add trailing comma after last
  param and let `zig fmt` wrap.
- L805: 141 cols — `fn parseAnd(...)` signature; same fix.
- L831: 143 cols — `fn parseUnary(...)` signature; same fix.
- L858: 145 cols — `fn parsePrimary(...)` signature; same fix.
- L1992: 169 cols — `evaluate(...)` call inside `.and_expr` branch; add
  trailing comma.
- L1994: 157 cols — second `evaluate(...)` call in `.and_expr`; same fix.
- L1997: 169 cols — `evaluate(...)` in `.or_expr`; same fix.
- L1999: 157 cols — second call in `.or_expr`; same fix.
- L2002: 151 cols — `evaluate(...)` in `.not_expr`; same fix.
- L462: 125 cols — `.birthtimespec` struct literal; split to multi-line.

Production code lines >140 cols that are not test invocations: L788, L805,
L831, L858, L1992, L1994, L1997, L1999, L2002, L2631, L2640, L2648, L2659,
L2678, L2745. All are call-sites for the 15-parameter `evaluate()` or
signatures for the 5-parameter parser functions. The root fix is reducing
parameter counts (see Assertion gaps / Performance sections).

Test invocations (e.g. L5246, L5258, L4110–L4172) have long lines because
`runFind` call-sites inline long argument slices. Binding the arg slice to a
`const args = &[_][]const u8{...}` variable before the call would bring them
under 100 cols.

### Assertion gaps

Zero `assert(` calls exist anywhere in the file. Tiger Style requires a
minimum average of two assertions per function over the body of the file. For a
5584-line file this implies ~100+ assertions. The complete absence is the most
significant Tiger Style deviation.

Key functions that lack any assertions:

- `parsePrimary` (L858): No assertion that `pos.*` advances on every code path
  that consumes a token. An off-by-one in `pos.*` advances would be silently
  swallowed; an assert at the top (`assert(pos.* < args.len)`) and at the
  bottom (`assert(pos.* > start_pos)`) would catch regressions.

- `evaluate` (L1770): No assertion that `expr` pointer is non-null (Zig's type
  system enforces this for `*const Expression`, acceptable); but the function
  takes 15 parameters with no pre/postcondition checks. At minimum, assert
  `depth <= std.math.maxInt(u32)` or that `had_error != null` (trivially true
  but documents intent).

- `walkPath` (L2577): No assertion that `depth` does not overflow when
  `depth + 1` is passed to the recursive call. With an arbitrarily deep
  directory tree, `depth` wraps at `maxInt(u32)`. Assert
  `depth < std.math.maxInt(u32)` before recursive descent.

- `doStat` (L397): No assertion that `path.len > 0` before the `memcpy` and
  null-terminator write. A zero-length path is technically valid POSIX behavior
  but would produce a confusing errno; assert `path.len > 0` to document the
  precondition.

- `parseSize` (L253), `parseMtime` (L302), `parsePerm` (L330): Early-return on
  empty input is correct, but the functions have no postcondition assertions
  (e.g. `assert(result.value <= std.math.maxInt(u64))` is trivially true from
  `parseInt`, but asserting that `result.unit` is a valid tag value would pair
  with the parsing logic).

- `SizeExpr.toBytes` (L96): The multiplier table has no assertion that
  `.bytes` is excluded from the `* multiplier` path (the switch is exhaustive
  so no `unreachable` can fire, but the duplicate table between `toBytes` and
  `evaluate`'s `.size` branch means the `.bytes` special-case must be handled
  in two places; assert the invariant in each).

- `exprContainsDelete` (L769): No bound on recursion depth (see Recursion
  section).

- `getBirthTime` (L494): Returns `?i64` with no assertion that the returned
  value is positive (timestamps are expected to be after the Unix epoch).

### Recursion / unbounded loops

- `exprContainsDelete` (L769): Direct recursion into `expr.data.binary.left`
  and `expr.data.binary.right`, and into `expr.data.unary`. The expression tree
  can be arbitrarily deep (limited only by available stack). A pathological
  expression like `( ( ( ( ... ) ) ) )` with hundreds of nesting levels would
  overflow the stack. Convert to an iterative tree walk with an explicit bounded
  stack.

- `evaluate` (L1991–2003): Recursively calls itself for `.and_expr`,
  `.or_expr`, and `.not_expr`. Same depth-unbounded issue. An iterative
  evaluator using a small work stack is the Tiger Style approach.

- `parseUnary` (L840): Calls itself for `!` / `-not`, and calls `parseOr`
  (L846) for parenthesised sub-expressions. `parseOr` calls `parseAnd` calls
  `parseUnary`. This mutual recursion is bounded by the number of tokens in
  `args`, which is bounded by the command line limit (~2 MB on Linux), making
  deep nesting unlikely in practice — but it is still unbounded by design. A
  non-recursive Pratt parser or shunting-yard algorithm would satisfy Tiger
  Style.

- `walkPath` (L2720, L2738): Calls itself for each directory child. Directory
  trees are bounded by filesystem limits in practice, but there is no
  `maxdepth` assertion inside the recursive call to prove the bound. The
  `maxdepth` guard is checked at the top of the function, which is correct but
  only documented by the check itself, not by an assertion like
  `assert(depth + 1 <= config.maxdepth orelse std.math.maxInt(u32))`.

- `while (true)` at L2692 and L2724 (inside `walkPath`): These loops break on
  `iterator.next(io)` returning `null` or an error. The continuation condition
  is the iterator's internal state, not an explicit invariant. Tiger Style asks
  that a non-terminating loop "must be asserted" — add a comment or
  `comptime`-reachable assertion that the iterator is finite (e.g. bounded by
  filesystem entry count).

### Error handling

- L2780: `} else |_| {}` — silently ignores the error from `doStat` when
  computing `root_dev` for `-xdev`. If `stat` fails, `root_dev` stays `null`
  and `-xdev` silently stops enforcing the device boundary. The justification
  (continuing without root_dev is a safe degradation) should be in a comment.

- L629, L876: `} else |_| {}` — parse errors from `std.fmt.parseInt` are
  intentionally ignored to determine whether the next token is numeric. This is
  correct but deserves a brief comment explaining why (distinguishing flag from
  expression context).

- L2205, L2223: `} else |_| {}` — `parseInt` failure in `matchUser`/
  `matchGroup` falls through to the name-lookup path, which is the intended
  behaviour. A comment would make the intent explicit.

- L1704: `stdout.writeAll(result.stdout) catch {};` — write failure is
  silently swallowed inside `BatchContext.flushExec`. The justification (output
  errors are non-fatal for batch exec output) is absent. Add a comment.

- L1757: Same issue in `BatchContext.flushExecdir`.

- L2086: `stderr.print("< ? ... > ", .{}) catch {};` inside `.okdir_stub` —
  if stderr write fails there is no visible indication. A comment noting that
  failure here is non-recoverable (we are already in a best-effort stub) would
  justify the bare catch.

- L2329: Same pattern in `doOk`.

- L2864: `common.help.printColorized(...) catch {};` — if the help text cannot
  be written, the process exits silently with code 0. At minimum this should
  set a flag or write to stderr.

- L2868: `writer.print(...) catch {};` in `printVersion` — same concern.

### Naming

- `s` (L256, L305, L333): Single-letter variable names for the remaining-input
  slice in `parseSize`, `parseMtime`, and `parsePerm`. Tiger Style permits only
  `i`, `j`, `k` as short names (sort/matrix indices). Rename to `remaining` or
  `input`.

- `te` (L980, L1090, L1104, L1118, L1174, L1188, L1202, L1216, L1832, L1854,
  L1865, L1876, L1885, L1896, L1905, L1916, L2017, L2032): Abbreviation for
  `TimeExpr`. Rename to `time_expr`.

- `sz` (L945, L1793): Abbreviation for `SizeExpr`. Rename to `size_expr`.

- `pe` (L1844): Abbreviation for `PermExpr`. Rename to `perm_expr`.

- `sf` (L2080): Abbreviation for samefile data. Rename to `samefile`.

- `bn` (L1725, L1738): Abbreviation for `basename`. Rename to `basename`.

- `blk` (L2336): Abbreviation for block count in `doLs`. Rename to
  `block_count`.

- `fmt` (L469 in `getFileKind`): Named `fmt` but it holds the S_IFMT-masked
  mode bits. Rename to `file_mode_type` or `mode_type`.

- `fmt` (L2096 in `evaluate`'s `.printf_action` branch): Shadows the standard
  `std.fmt` namespace name (though it is in a nested scope). Rename to
  `format_str`.

- `m` (L2408 in `formatPermissions`): Single-letter alias for the `mode`
  parameter. Rename to `mode` (dropping the alias entirely) or `mode_bits`.

- `pctx` (L720, and throughout `parseOr`/`parseAnd`/`parseUnary`/
  `parsePrimary`): Abbreviated parameter name. Rename to `parse_ctx`.

- `rc` (L409): Abbreviated for "return code" from the `statx` syscall. Rename
  to `statx_result` or `errno_result`.

- `TimeExpr.days` field (L111): This field is reused to hold minutes for
  `-mmin`/`-amin`/`-cmin`, link counts for `-links`, and inode numbers for
  `-inum`. The name `days` is wrong in three of these four contexts. Rename the
  field to `value` and let the caller interpret the unit, or split into
  separate `TimeExpr` and `CountExpr` types.

### Variable scope / aliasing

- `is_depth_first` (L2620): Alias for `config.depth_first` created at the top
  of `walkPath` and used throughout. This is exactly the alias anti-pattern
  Tiger Style prohibits. Use `config.depth_first` directly.

- `dummy_pruned` (L2639, L2658, L2677, L2744): A `bool` written by `evaluate`
  but never read is constructed four times across `walkPath`. The need for a
  throwaway pruned pointer signals that `evaluate` has too broad an interface.
  Consider making pruning a return value variant rather than an out-parameter.

- `now` (L2770) and `now` inside `formatDate` (L2444): The same wall-clock
  value is obtained independently in two functions (`runFind` passes `now` as a
  parameter to `walkPath`/`evaluate`; `formatDate` computes its own `now`
  internally). `formatDate` should accept the already-computed timestamp as a
  parameter to remove the duplicate syscall and the internal `_ts` variable.

### Comments

- L2102, L2108, L2115, L2121: Inline comments inside `printf_action` (`//
  basename`, `// dirname`, `// full path`, `// file size in bytes`) describe
  what the specifier does, not why it is handled that way. Remove them — the
  `switch` cases are self-documenting — or replace with a comment explaining
  the subset of specifiers that is implemented and why others are omitted.

- L1805–L1806: `// For block-based units, convert file size to unit count
  // using ceiling division, matching GNU find behavior` — the first clause is
  what; the second is why. Keep only the second clause.

- L2039: `// "days" field holds minutes here` — this comment documents a
  workaround for the field-name confusion identified in the Naming section.
  Fixing the naming removes the need for this comment.

### Types / division

- `usize` at L604, L663, L718 (`expr_start`, `i`, `pos` in `parseArgs`):
  These are indices into `args`, whose `.len` is `usize` — stdlib-bound and
  acceptable.

- `usize` at L2097 (`i` in `printf_action`): Index into `fmt.len`, also
  stdlib-bound and acceptable.

- `usize` at L5438–L5439, L5458–L5459 (`count`, `pos` in test functions):
  Acceptable as `indexOfPos` returns `usize`.

- L1814: `(file_size + unit_size - 1) / unit_size` — bare `/` on integers for
  ceiling division. This should use `std.math.divCeil` (which expresses intent
  explicitly) rather than the manual add-subtract pattern, especially since the
  comment on L1805 already calls out "ceiling division".

- The multiplier table for `SizeUnit` byte-counts is duplicated between
  `SizeExpr.toBytes` (L97–105) and `evaluate`'s `.size` branch (L1806–1813).
  The `evaluate` branch additionally marks `.bytes => unreachable`. These two
  tables should be one: have `evaluate` call `sz.toBytes()` directly (which
  already handles `.bytes` as a special case) and remove the inline table.

### Performance

- `evaluate` (L1770): Takes 15 parameters, several of which (`io`, `allocator`,
  `stdout`, `stderr`, `had_error`, `batch_ctx`) are context that never changes
  across a single file's evaluation. Packing these into a small `EvalContext`
  struct and passing `*const EvalContext` would reduce per-call stack frame
  size and also collapse the 150–169-column call-sites for `.and_expr`,
  `.or_expr`, and `.not_expr` to something readable.

- `regex_match` / `iregex_match` (L2010–2013): Allocates a
  null-terminated copy of `path` via `allocator.dupeZ` on every file
  visited. If `-regex` is used on a large tree this is O(N) allocations in the
  hot evaluation path. Pre-allocating a fixed path buffer in the eval context
  and reusing it (the buffer is already sized to `max_path_bytes` elsewhere)
  would eliminate the per-file allocation.

- `walkPath` sorted branch (L2686–2721): Collects all directory entries into a
  heap-allocated `ArrayList`, sorts, then frees. For directories with many
  entries this allocates and frees O(N) strings. Using a fixed-size sort buffer
  or sorting indices into a single allocation would reduce pressure.

### Other observations

- `TimeExpr` (L109–112) uses a field named `days` to store values that are
  minutes, link counts, and inode numbers depending on the calling context
  (`.mmin`, `.amin`, `.cmin`, `.links`, `.inum`). This is a semantic type
  confusion. The field should be renamed `value` and the struct used as a
  generic `CompareExpr { cmp: Comparison, value: u64 }`, or separate structs
  created for each semantic type.

- `parsePrimary` duplicates the pattern `parseMtime(args[pos.*]) catch { ...
  return error.InvalidExpression }` for seven different flags (`-mmin`,
  `-amin`, `-cmin`, `-inum`, `-links`, `-Bmin`, `-Btime`). A helper
  `parsePrimaryTimeArg(pctx, args, pos, flag_name)` would eliminate ~70 lines
  of repetition.

- `std.process.exit(0)` at L2093 inside `evaluate` for the `.quit_action`
  case. Calling `process.exit` from a deep recursive call bypasses all `defer`
  statements up the call stack. If any deferred flush or cleanup exists above
  this call (currently they do not, but arena cleanup in tests would be
  affected), data would be lost. A cleaner design returns a sentinel error or
  sets a `quit` flag in the eval context, and the top-level runner handles the
  exit.

- `getBirthTime` (L494) repeats `std.Io.Dir.max_path_bytes`-sized buffer
  allocation and null-termination logic that is also present in `doStat`
  (L398–402). A shared `pathToCStr` helper would eliminate the duplication.

---

## Summary

| Category | Count |
|---|---|
| Function-length | 5 (4 severe, 1 borderline) |
| Line-length | 177 lines total; 15 in non-test production code; worst at 169 cols |
| Assertion gaps | 0 assertions in 5584 LOC — entire file |
| Recursion/unbounded loops | 4 (exprContainsDelete, evaluate, parseUnary/parseOr cycle, walkPath) |
| Error handling | 8 bare `catch {}` sites lacking justification comments |
| Naming | 13 identifiers (s, te, sz, pe, sf, bn, blk, fmt×2, m, pctx, rc, TimeExpr.days) |
| Variable scope | 3 (is_depth_first alias, dummy_pruned×4, duplicate now) |
| Comments | 5 (what-not-why inline comments in printf_action and size branches) |
| Types/division | 2 (bare `/` at L1814, duplicated unit multiplier table) |
| Performance | 3 (15-param evaluate signature, per-file regex alloc, sorted-dir alloc) |

**Overall impression**: `find.zig` is functionally rich and well-tested but
violates Tiger Style pervasively. The complete absence of `assert()` calls is
the single most critical gap — the entire 5584-line file has zero runtime
invariant checks. The two mega-functions (`parsePrimary` at 798 lines and
`evaluate` at 410 lines) and the four unbounded recursion paths each individually
would block a Tiger Style approval; together they represent a fundamental
structural issue that requires decomposition before the file can be considered
compliant.
