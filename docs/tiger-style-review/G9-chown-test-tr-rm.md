# Tiger Style Review: G9-chown-test-tr-rm

**Files reviewed**: 4 files, ~5173 LOC.

---

## src/chown.zig

### Function-length violations (>70 lines)

- `runChown` — L84–196 (113 lines). Handles parsing, validation, ownership
  spec construction, preserve-root checking, numeric-ID checking, and the
  file loop. Split the validation block (L120–158) and the file-iteration
  loop into named helpers.
- `chownRecursive` — L346–426 (81 lines). The directory-open branch alone
  runs to the bottom of the function. The device-id guard, symlink-traversal
  dispatch, and child recursion are separate concerns; extract them.

### Line-length violations (>100 cols)

72 lines exceed 100 columns. The worst offenders are function signatures and
`printErrorWithProgram` calls that routinely run 130–197 characters. A
representative sample:

- L84 (151 chars): `pub fn runChown(...)` signature — split with trailing comma.
- L305 (197 chars): `fn chownSingle(...)` signature — worst in the file.
- L430 (157 chars): `fn changeOwnership(...)` signature.
- L479 (194 chars): `fn reportChange(...)` signature.
- L489 (131 chars): `fn handleError(...)` signature.
- L146/L365/L388/L411 (113–168 chars): call sites with inline error strings.

All function signatures that exceed 100 columns can be reformatted by adding a
trailing comma after the last parameter and letting `zig fmt` wrap them.

### Assertion gaps

Zero calls to `std.debug.assert` anywhere in the production code (L1–509).
Tiger Style requires a minimum of two assertions per function on average.
Key gaps:

- `chownRecursive` (L346): no precondition asserting `path.len > 0`.
- `changeOwnership` (L430): no assertion that the C result is `0` or `-1`
  (it should never be any other value); no assertion that `path.len > 0`.
- `buildTranslationTable` (absent here, but called by the callers): see tr.zig
  note — same pattern.
- `isNumericOwnerSpec` (L471): trivially short but still benefits from an
  entry-guard `assert(spec.len > 0)` given that its callers only invoke it
  after a length check.

### Recursion / unbounded loops

- **Direct recursion** — `chownRecursive` (L346) calls itself at L411. This
  will stack-overflow on deep directory trees with no bound on nesting depth.
  Tiger Style prohibits direct recursion; rewrite as an explicit stack or queue
  bounded by `max_path_bytes`-limited depth.

### Error handling

- L411: `chownRecursive(…) catch { had_errors = true; }` swallows the error
  value entirely. The specific error is lost; at minimum log it or propagate it
  through `handleError`.
- L184: same pattern — `catch { exit_code = …; }` discards the error type
  from `chownRecursive`.
- `chownFile` (L276) is only called from tests; it re-parses the ownership
  specification even though `runChown` has already parsed it. This is not a
  runtime error but it is dead production code that exists solely to support
  tests whose ownership parsing is redundant.

### Naming

- `H`, `L`, `P` fields in `ChownArgs` (L34–38): single-letter field names
  violate the no-abbreviation rule. Even though these mirror the POSIX flag
  letters, the internal struct should use `traverse_cmdline_symlinks_H`,
  or the comment should make the mapping explicit and unambiguous.
- `current_uid` / `current_gid` vs `new_uid` / `new_gid` in `chownSingle`
  (L312–318): these names are fine, but `stat_info` is slightly abbreviated
  — `file_stat` would be clearer.

### Variable scope / aliasing

- `ownership` in `chownFile` (L286): declared `var` with `undefined` initial
  value, then conditionally assigned. Zig allows `const` with a comptime
  result from a block expression; using `var` + `undefined` invites bugs if a
  future branch forgets to assign it.
- `files` in `runChown` (L137): this is an alias of a slice into
  `positionals`. While not a true alias (it is a distinct binding), the
  two-declaration pattern (`positionals`, then `files`) adds a variable to
  scope unnecessarily. The slice expression could inline at its use sites.

### Comments

- `chownSingle` (L306): `_ = stderr_writer; // Parameter for API consistency,
  errors bubble up to caller`. The comment explains the parameter exists but
  not why the caller is expected to log errors rather than this function —
  document that design decision.
- Several comments throughout say what (`// Build full path`,
  `// Apply ownership change`) rather than why. The most valuable comments
  (explaining `-P` default behavior, L358–360) are good examples of the
  correct style.

### Performance

- `changeOwnership` (L432): allocates a null-terminated copy of `path` for
  every syscall. For the common recursive case where many files share a long
  path prefix, this is O(path\_length) allocation per file. A pre-allocated
  scratch buffer passed through the call chain would eliminate these allocs.

---

## src/test.zig

### Function-length violations (>70 lines)

No top-level functions exceed 70 lines. The `ExpressionParser` methods are
all well under limit. No violations.

### Line-length violations (>100 cols)

11 lines in production code (L1–601) exceed 100 columns:

- L144 (127 chars): compound `if` condition in `isUnknownOperatorLike` — the
  four `and`-chained sub-expressions should each be on their own line.
- L510 (164 chars): `unary_ops` array literal in `isUnaryOperator` — add
  trailing comma and let `zig fmt` wrap.
- L520 (123 chars): `binary_ops` array literal — same fix.
- L529, L542, L561, L580, L585 (101–152 chars): function signatures for
  `evaluateTestArgs`, `runBracketTest`, `runTest`, `runBracketCmd`,
  `runTestCmd` — all fixable with trailing commas.

101 lines in test bodies (L602+) exceed 100 columns, mostly `runTest(…,
common.null_writer, common.null_writer)` calls. Those are mechanical and
can be fixed by extracting `common.null_writer` into a local binding or
splitting the argument list.

### Assertion gaps

- `getRawStat` (L63): no assertion that `path.len <= std.Io.Dir.max_path_bytes`
  before the early return; the guard is there but an assert would pair the
  positive-space check.
- `isSymlink` (L92): same pattern — guard at L94 but no assertion.
- `evaluateNegation` (L205): the final `else` branch at L246 is described in a
  comment as "shouldn't happen"; it should be `unreachable` or followed by an
  assertion. Currently it silently falls through to `evaluateWithoutNegation`
  which may produce incorrect results for malformed input.

### Recursion / unbounded loops

The grammar parser uses mutual recursion across these methods (none are direct
self-calls, but the cycle is real):

- `evaluateLogicalExpression` → `evaluateNegation` (L348)
- `evaluateNegation` → `evaluateWithoutNegation` (L232, L247)
- `evaluateWithoutNegation` → `dispatchExpression` (L255)
- `dispatchExpression` → `evaluateWithParentheses` (L169, L178, L180)
- `evaluateWithParentheses` → `evaluateWithoutNegation` (L300)
- `evaluateWithParentheses` → `evaluateLogicalExpression` (L311)
- `evaluateLogicalExpression` → `evaluateLogicalExpression` (L326, L327, L339,
  L340) — direct self-recursion

The direct self-recursion in `evaluateLogicalExpression` at L326–340 splits
the args slice on each `-o` / `-a` token, so the recursion depth is bounded by
the number of operators in the expression. However, this is not asserted and
Tiger Style requires explicit bounds. A deeply nested expression from untrusted
input could cause a stack overflow. Add a `max_depth` parameter or convert to
an iterative scan.

The depth-tracking loops in `evaluateNegation` (L216–224) and
`evaluateWithParentheses` (L285–291) iterate without an explicit upper bound
assertion on `depth`. Both are bounded by `args.len` (which is bounded by the
process argument list), but that bound is not asserted.

### Error handling

- L1163: `io.sleep(…) catch {}` — the intent is "best-effort sleep; if the
  system can't sleep, proceed." Add a brief comment explaining why discarding
  the error is correct here.

### Naming

- `buf` in `getRawStat` (L64) and `isSymlink` (L93): `buf` is an abbreviation.
  Rename to `path_buf` or `c_path_buf` to be specific about what it holds.
- `sx` in `getRawStat` (L71) and `isSymlink` (L101): abbreviation for the
  `Statx` struct. Rename to `statx` or `stat_result`.
- `l` and `r` in `NumericComparison.compare` (L39–40): `i`, `j`, `k` are the
  only abbreviations Tiger Style permits for primitives. Rename to `left_val`
  and `right_val` or keep `left`/`right` to match the parameter names.
- `open` at L281 in `evaluateWithParentheses`: stores the index of the opening
  paren. The name is non-obvious; `open_paren_idx` would be clearer.

### Types / division

- `usize` in `evaluateNegation` (L214–215), `evaluateWithParentheses`
  (L277, L282), and `evaluateLogicalExpression` (L322, L335): these index
  `args: []const []const u8`. Since the argument count derives from the process
  argument list (bounded by OS limits), `usize` is technically stdlib-bound.
  Acceptable, but worth annotating.

### Other observations

- **`isNewerThan` / `isOlderThan` (L495–505)**: both compare only
  `stat1.mtime.nanoseconds`. `std.Io.File.Stat.mtime` is a `Timestamp` struct
  whose `.nanoseconds` field stores only the sub-second component in the
  0.16 API; the epoch-seconds component is separate. If this interpretation is
  correct, comparing only `.nanoseconds` produces wrong results for files
  created more than one second apart. Verify the `Timestamp` layout and compare
  the full value (e.g. convert to a monotonic nanosecond count via a helper).
  This is a potential correctness bug.

---

## src/tr.zig

### Function-length violations (>70 lines)

- `runTrWithInput` — L462–546 (85 lines). Mixes operand-count validation, two
  separate set-parsing flows, fill-repeat expansion, truncation logic, and mode
  dispatch. Extract the set2 parsing + fill expansion into a
  `parseAndExpandSet2` helper.

### Line-length violations (>100 cols)

13 lines exceed 100 columns, all in production code:

- L33 (187 chars): `.squeeze_repeats` meta description — can be shortened or
  the string split with concatenation.
- L370 (140 chars): `pub fn runTr(...)` signature.
- L372 (158 chars): `ArgParser.parseOrExit(...)` call.
- L387, L396, L401, L472, L512 (135–192 chars): `printErrorWithProgram` calls
  with long format strings.

### Assertion gaps

- `buildTranslationTable` (L334): no assertion that `set1.len <= 256` or that
  `set2.len > 0` (guarded by an early return but not asserted). The identity
  initialization loop at L337–339 sets all 256 entries; an `assert(set1.len <=
  256)` would catch misuse.
- `buildSetMembership` (L355): no assertion on `set.len`.
- `processTranslate` (L549) and siblings: no assertion that the buffer size is
  non-zero or that the reader/writer are non-null. Minimal, but the "minimum
  two per function" average is not met across the codebase.
- `expandClass` (L190): 63 lines of if/else branches with no assertions on the
  character ranges (e.g. assert `'A' <= 'Z'`, which is a compile-time
  constant sanity check Tiger Style recommends).

### Recursion / unbounded loops

- `while (true)` in `processTranslate` (L558), `processTranslateSqueeze`
  (L586), `processDelete` (L617), `processDeleteSqueeze` (L647),
  `processSqueeze` (L682): each loop is terminated by `bytes_read == 0`
  (EOF from the reader) or by a read error. These are legitimately unbounded
  I/O loops, but Tiger Style requires that non-terminating loops assert their
  continuation condition. None of these have such an assertion. Add
  `std.debug.assert(bytes_read > 0 or condition)` or a comment explaining
  the termination guarantee.
- `findFillChar` inner loop at L431: `while (j < set_str.len and set_str[j]
  != ']')` — bounded by `set_str.len`, which is fine, but the outer
  `while (i < set_str.len)` at L414 combined with the inner `i = j + 1` at
  L455 means `i` can advance by large amounts per outer iteration. The logic
  is correct but the relationship between `i` and `j` should be asserted
  (`assert(j >= i)`).

### Error handling

- `processTranslate` L559: `reader.readSliceShort(&buffer) catch { return … }`
  — the error from the reader is swallowed. At minimum the error should be
  mapped (distinguish EOF-with-error from clean EOF). Same pattern at L587,
  L618, L648, L683.
- `processTranslate` L565: `writer.writeByte(table[b]) catch { return … }` —
  same issue; I/O write errors are silently converted to a generic exit code.
- `runTrWithInput` L519 (fill expansion): `allocator.free(set2)` is called,
  then `set2` is replaced with `new_set2`. If the subsequent `set2 = new_set2`
  is reached, the old `set2` is freed and the `defer if (set2_allocated)
  allocator.free(set2)` at L522 will free `new_set2` correctly. However, the
  `set2_allocated` boolean flag pattern is fragile — if a future code path
  conditionally skips the `set2 = new_set2` assignment after the free, it
  becomes a double-free. Prefer a single nullable with a single `defer`.

### Naming

- `i`, `j` in parse functions: `i` is acceptable by Tiger Style as a loop
  index. `j` is acceptable for a secondary index. No violations here.
- `max_positionals` (L470): uses `usize`, which is acceptable (counts args).
  The name is clear.
- `comp_set1` (L485): abbreviation of "complement set 1". Rename to
  `set1_complement` to follow the suffix convention.

### Variable scope / aliasing

- `set1` is mutated in place at L526 (`set1 = set1[0..set2.len]`) to
  implement truncation. This aliases into the memory of either `raw_set1` or
  `comp_set1.?`. The slice is then passed to the process functions. While
  technically safe, aliasing a slice name to a sub-slice of an owned buffer
  is exactly the pattern Tiger Style warns against ("don't take aliases").
  Use a `const truncated_set1` for the process-function calls instead.

### Comments

- `parseSet` (L56): the doc comment is clear. The `// Literal character`
  comment at L117 says what, not why; it's not harmful but not useful either.
- `buildTranslationTable` (L343–348): comment explains GNU behavior (extend
  last char of set2) — good WHY comment.
- `processTranslate` through `processSqueeze`: no function-level comments
  explaining the streaming I/O contract or termination condition.

---

## src/rm.zig

### Function-length violations (>70 lines)

- `removeFiles` — L146–242 (97 lines). This function dispatches into multiple
  error sub-cases for `IsDir` (L190–225), each with its own nested error
  handling. Extract the `IsDir` handler into `handleIsDir(…)` and the
  `remove-empty-dirs` branch into its own helper.
- `removeDirectoryRecursive` — L328–449 (122 lines). Mixes device-id
  guard, directory open, entry collection, depth-first descent, directory
  deletion, and verbose/interactive output. The entry-collection loop (L355–365)
  and the entry-processing loop (L371–413) are each standalone concerns.

### Line-length violations (>100 cols)

41 lines in production code (L1–525) exceed 100 columns:

- L63 (140 chars), L65 (158 chars): `runRm` signature and the `parseOrExit`
  call.
- L146 (165 chars): `removeFiles` signature.
- L149, L159, L167, L169, L172 (108–140 chars): inline error messages and
  prompt calls.
- L245 (152 chars): `removeItem` signature.
- L299 (164 chars): `removeDirectory` signature.
- L328 (197 chars): `removeDirectoryRecursive` signature — longest in the
  file; the 7-parameter list needs a trailing comma + `zig fmt`.

### Assertion gaps

- `removeDirectoryRecursive` (L328): no precondition asserting `dir_path.len >
  0`. No assertion that `root_dev` is consistent with the `no_cross_device`
  option (if `no_cross_device` is false, `root_dev` should be null).
- `removeItem` (L245): no assertion that `file_path.len > 0`.
- `extractBasename` (L458): checks `path.len == 0` and returns early, but
  does not assert the post-condition that the returned slice is non-empty
  (for non-empty input). The `start <= end` invariant is not asserted.
- `isRootPath` (L485): the while loop at L493 decrements `i` without
  bounding the decrement; an `assert(i > 0)` inside the loop would make the
  invariant explicit.

### Recursion / unbounded loops

- **Direct recursion** — `removeDirectoryRecursive` (L328) calls itself at
  L381. A deeply nested directory tree (attacker-controlled or simply deep
  `/proc` subtree) will overflow the stack. Tiger Style prohibits direct
  recursion; convert to an explicit stack with a depth limit.
- `isRootPath` (L492–502): the `while (i > 1)` loop with conditional `i -=
  1` or `i -= 2` is bounded by `path.len`, but `i` can jump by 2, which
  means the loop could terminate at `i == 0` rather than `i == 1` in
  degenerate input. The exit condition `i <= 1` at L506 handles this, but
  it masks the skip-by-2 case without an assertion.

### Error handling

- L447: `if (had_errors) { return error.AccessDenied; }` — this mis-attributes
  all failure modes (DirNotEmpty, permission errors on subdirectories, read
  errors) as `AccessDenied`. The caller at L383–386 then re-maps this to
  `had_errors = true` without printing a message. Information about the actual
  failure is lost by the time it bubbles up. Introduce a dedicated error
  `error.ChildErrors` or propagate a summary.
- L384: `else => had_errors = true` — the error from `removeDirectoryRecursive`
  is swallowed. The caller will set `had_errors` but never print what went
  wrong in that subtree.

### Naming

- `tmp` in test functions (L683, L722, etc.): abbreviation for `tmp_dir`.
  Tiger Style permits `i`/`j`/`k` only for primitive loop counters. `tmp`
  as a `testing.TmpDir` should be `tmp_dir`. (Low priority in test-only
  code, but pervasive.)
- `rd` in `removeDirectoryRecursive` (L331): abbreviation for `root_device`.
  Rename to `root_device` or `expected_dev`.

### Variable scope / aliasing

- `had_errors` (L344) spans the full body of `removeDirectoryRecursive`,
  over 100 lines. Tiger Style recommends declaring at the smallest scope
  possible. Since every branch that sets it eventually leads to the same
  `if (had_errors) return error.AccessDenied` at the bottom, the boolean
  could be replaced by an early-return pattern or a dedicated error type,
  reducing the variable's scope.

### Comments

- L447: `return error.AccessDenied; // Generic error to signal failure` —
  the comment acknowledges the problem but does not explain why a dedicated
  error variant was not used. Add a TODO or fix it.
- `removeDirectory` (L299): the fast-path at L301–307 (`deleteTree` for
  force+non-verbose) is a good optimization, but the comment does not explain
  the safety argument (why it is safe to bypass per-entry checks in this case).

### Types / division

- `start: usize` in `extractBasename` (L473) and `i: usize` in `isRootPath`
  (L492): these index into a path string. Since they are bounded by the
  string length (which may originate from a user argument and is bounded
  by OS path limits), `usize` is acceptable here.

---

## Summary

| Category | Count |
|---|---|
| Function-length | 5 |
| Line-length | ~245 lines across 4 files |
| Assertion gaps | 15+ |
| Recursion/unbounded loops | 4 (2 direct, 2 indirect/mutual) |
| Error handling | 12 |
| Naming | 10 |
| Variable scope | 5 |
| Comments | 7 |
| Types/division | 0 |
| Performance | 1 |

**Overall impression**: The codebase is functionally correct and well-structured
at the module level, but the Tiger Style assertion discipline is entirely absent
— zero production assertions across all four files — and both tree-walkers
(`chownRecursive`, `removeDirectoryRecursive`) use direct recursion that will
stack-overflow on deep directory trees. The pervasive line-length violations
suggest `zig fmt` is not being run on many of these files, or the signatures
were written to avoid the formatter's wrapping. Fix the recursion and add
boundary assertions before the next release; address line length as a
mechanical cleanup pass.
