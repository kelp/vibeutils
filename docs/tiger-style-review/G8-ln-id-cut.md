# Tiger Style Review: G8-ln-id-cut

**Files reviewed**: 3 files, ~4134 LOC.

---

## src/ln.zig

### Function-length violations (>70 lines)

- `createSingleLink` — lines 371–585, **214 lines**. The body
  handles link-existence checking, interactive prompt, backup,
  force-remove (two sub-branches), relative-path computation,
  symlink creation, hard-link creation via `linkat`, and verbose
  output. That is seven distinct concerns in one function.
- `createLinks` — lines 262–366, **104 lines**. Dispatches across
  four POSIX forms with duplicated error-path logic; the
  `handleTwoArgFallback` extraction helped but the function is still
  well over limit.

### Line-length violations (>100 cols)

80 lines exceed the 100-column hard limit. Representative worst
offenders (the report lists every instance but highlights the most
egregious):

- `src/ln.zig:251` — 195 cols (function signature for
  `handleTwoArgFallback` written on one line)
- `src/ln.zig:371` — 213 cols (`createSingleLink` signature, all
  on one line)
- `src/ln.zig:571` — 174 cols
- `src/ln.zig:443`, `src/ln.zig:455`, `src/ln.zig:460`,
  `src/ln.zig:468` — 160–178 cols each

Nearly every `common.printErrorWithProgram` call exceeds 100 cols
because the signature and format string are written inline. Adding
trailing commas to the argument lists and letting `zig fmt` wrap
would resolve most of these.

### Assertion gaps

Zero `std.debug.assert` calls appear in any production function.
Tiger Style requires a minimum of two assertions per function on
average. Specific gaps:

- `makeRelativePath` (line 65): no assertion that `from_abs` and
  `to_abs` are non-empty or start with `/`; a caller bug silently
  produces a wrong relative path.
- `createSingleLink` (line 371): no assertion that `target.len > 0`
  or `link_name.len > 0` at entry.
- `createLinks` (line 262): no assertion that `files.len > 0`
  (the caller checks it, but the function itself does not assert the
  precondition it relies on).

### Error handling

- `src/ln.zig:408`: `stderr_writer.flush() catch {}` silently drops
  flush errors. The flush is part of the interactive prompt path; a
  silent failure means the user may never see the prompt. Should log
  the error to stderr or propagate it.

### Naming

- `LnArgs.L` and `LnArgs.P` (lines 18, 22): single-letter uppercase
  field names violate `snake_case` convention for variables. These
  map to the `-L`/`-P` flags but should be named `follow_symlinks`
  and `physical` (or similar) to match the rest of the struct and the
  `LinkOptions` fields they map to.
- `rel_arena` / `temp_allocator` (lines 479–484): `rel_arena` is
  acceptable; `temp_allocator` is an abbreviation. Rename to
  `relative_path_allocator`.
- `no_deref_h` (line 21): abbreviates `no_dereference`. The full
  `no_dereference_h` or `no_dereference_posix` would be clearer given
  that both `-h` and `-n` alias the same behavior.

### Variable scope / aliasing

- `link_dir` is declared twice in `createSingleLink`: once at
  line 506 (inside the `options.relative` block) shadowing nothing,
  but the outer scope also uses `link_name` to derive the same value.
  Consider a single declaration.
- `rel_arena` (line 479) is allocated unconditionally even when
  `options.relative` is false (i.e., the arena is never used for
  most invocations). The allocation should be inside the
  `if (options.relative)` block.

### Comments

- Several inline comments are lowercase fragments without a trailing
  full stop: lines 315–316, 376, 476, 549, 625. Tiger Style requires
  "space after slash, capital letter, full stop."
- `src/ln.zig:1015–1018`: a test comment states "This test should
  FAIL because -P is not implemented yet" — this describes an
  intentionally broken test left in the suite, which is a testing
  integrity issue (see also Testing section below).

### Other observations

- **Known-broken test** at line 976 (`"ln: -P creates hard link to
  symlink itself"`): the comment explicitly says the test is expected
  to fail because `-P` is not implemented. A test that is known to
  fail for the wrong reason should be marked `#[skip]` or tracked
  externally, not left as a passing-but-incorrect test.
- `createSingleLinkInDir` (line 588) is a parallel implementation of
  `createSingleLink` for testing, diverging in important ways (no
  `warn_missing`, no `backup`, simpler force-remove). Any behavior
  change to `createSingleLink` risks the test helper drifting silently.

---

## src/id.zig

### Function-length violations (>70 lines)

- `runId` — lines 92–357, **265 lines**. This is the dominant
  violation. The function is a monolith: it parses args, validates
  flag combinations, resolves the target user, dispatches to `-F`,
  `-P`, `-p`, `-u`, `-g`, `-G`, and default-format paths, all
  inline. Each dispatch branch is large enough to be its own
  function. At minimum the `-G` group-list acquisition block
  (lines 303–333) should be extracted, as it is already duplicated
  verbatim in `printDefaultGidAndGroups`.
- `printDefaultGidAndGroups` — lines 459–532, **73 lines**. Three
  lines over limit; the getgroups() acquisition block is the excess.

### Line-length violations (>100 cols)

57 lines exceed 100 columns. Examples:

- `src/id.zig:92` — 140 cols (function signature written on one line)
- `src/id.zig:95` — 153 cols
- `src/id.zig:127`, `src/id.zig:131`, `src/id.zig:137` — 119–123
  cols each (validation error message lines)

### Assertion gaps

Zero assertions in production functions. Specific gaps:

- `getGroupsForUser` (line 394): no assertion that `uid` is a valid
  value before passing to `getpwuid`. No assertion on the retry loop
  invariant (`ngroups` must grow monotonically).
- `runId` (line 92): no assertion that `args.len` is reasonable or
  that mutually-exclusive flag validation has run before the dispatch
  branches below it.
- `printSingleGroup` (line 360): no assertion that `target_gid` is
  non-zero.

### Recursion / unbounded loops

- `getGroupsForUser` (line 404): the retry loop `while (attempt < 8)`
  is correctly bounded. However, there is no assertion that `ngroups`
  is strictly increasing on each iteration — the comment acknowledges
  this risk and forces a doubling, but the invariant is not asserted:

  ```zig
  // After: should assert ngroups > call_ngroups_before_retry
  ```

### Error handling

- `runId` line 93: `_ = io;` discards the `io` parameter entirely.
  This is a stub that works today because `id` does not open files,
  but it silently ignores the parameter with no comment explaining
  why. Should at minimum have a comment: `// id performs no file I/O;
  all lookups go through libc.`
- `printPrettyGroups` line 562: `_ = stderr_writer;` discards the
  error writer. If a future code path in this function needs to emit
  an error, the writer will be missing. The parameter should be
  removed from the signature if it is truly unused, rather than
  silently discarded.

### Naming

- `pw` (lines 193, 208, 395): abbreviation for `passwd_entry`. Use
  `passwd_entry` or `passwd`.
- `gi` (lines 522, 526, 568, 572): abbreviation for group info.
  Use `group_info` (consistent with `user_info` used elsewhere).
- `rc` (line 407): abbreviation for return code. Use `result` or
  `getgrouplist_result`.
- `ngroups` (lines 308, 402, 406): this is a C API parameter name;
  acceptable as a stdlib-bound name. No flag.
- `buf` (lines 312, 405, 493): ambiguous abbreviation. Use
  `group_id_buf` or `groups_buf`.

### Variable scope / aliasing

- The getgroups() acquisition block (lines 308–332 in `runId` and
  lines 487–513 in `printDefaultGidAndGroups`) is duplicated nearly
  verbatim. This is a variable-scope and factoring problem: the
  shared logic should be a helper `getCurrentProcessGroups(allocator,
  gid, ...) ?[]std.c.gid_t` that both callers use.
- `count` (line 321, 504) is declared inside the `blk:` but then
  used to conditionally construct `exact`. The scope is correct, but
  the duplication across two functions means any fix must be applied
  twice.

### Comments

- `// Copy the username out of the libc static buffer.` (line 397)
  is a good why-comment but ends without a full stop.
- The `getGroupsForUser` doc-comment (lines 382–393) is detailed
  and well-motivated; the one deficiency is the sentence "The retry
  loop is bounded: on macOS …" — this explains the what but does not
  describe what callers should do when null is returned.

### Types / division

- `var count: usize = 0` (line 1181, test): a colon-count loop uses
  `usize`. Acceptable for test code.
- `var ngroups: c_int = 16` (line 402): initial value 16 is a magic
  constant with no named justification. A named constant
  `initial_group_capacity: c_int = 16` with a comment explaining
  the heuristic would satisfy Tiger Style's "always motivate" rule.

### Performance

- The getgroups() two-allocation pattern (alloc at `ngroups` size,
  then `resize` or re-alloc to `count`) appears twice. This is
  correct but verbose; a helper function would make the double-alloc
  contract visible and testable in isolation.

---

## src/cut.zig

### Function-length violations (>70 lines)

- `runCut` — lines 277–438, **161 lines**. Mixes argument parsing,
  validation (6 separate guard clauses), range parsing, delimiter
  resolution, and the file-dispatch loop. The validation block alone
  (lines 293–353) is 60 lines.
- `processFile` — lines 441–536, **95 lines**. The inner `switch`
  over `mode` repeats the `writeAll(line_terminator)` error-path
  pattern four times. Extracting a `writeLine` helper and the
  `while(true)` line-loop body would bring both functions under
  limit.

### Line-length violations (>100 cols)

30 lines exceed 100 columns. The worst:

- `src/cut.zig:279` — 155 cols
- `src/cut.zig:299` — 174 cols
- `src/cut.zig:312` — 192 cols
- `src/cut.zig:318` — 184 cols

These are again `printErrorWithProgram` calls written inline.
Adding trailing commas would let `zig fmt` wrap them.

### Assertion gaps

Zero assertions in production functions. Specific gaps:

- `parseRangeList` (line 62): no assertion that `list_str` does not
  contain null bytes before iterating. No post-condition assertion
  that the returned slice is sorted.
- `isSelected` (line 129): no assertion that `pos >= 1` (it is a
  1-indexed API; pos == 0 silently returns false rather than being
  caught as a caller bug).
- `utf8CharLen` (line 143): no assertion that the return value is
  in `[1, 4]`. The function documents that continuation bytes return
  1, but never asserts the return value.
- `cutBytesOrChars` (line 152): no assertion that `ranges` is
  non-empty or sorted (both preconditions from `parseRangeList`).

### Recursion / unbounded loops

- `processFile` (line 465): `while (true)` terminates only when
  `readLine` returns `eof = true` or an error. The termination
  depends entirely on the underlying reader returning EOF or an
  error — correct for file I/O, but Tiger Style requires this to
  be asserted: "where a loop cannot terminate, this must be
  asserted." A comment explaining the guaranteed termination
  condition would satisfy the rule.
- `readLine` (line 546): same pattern — `while (true)` terminates
  when the reader returns `EndOfStream` or a non-empty chunk
  containing the terminator. No assertion or comment documents the
  termination invariant.

### Error handling

- `processFile` (line 456): the function signature returns `u8`
  (not `!u8`), which means internal errors are converted to numeric
  exit codes. This is an intentional design choice, but the
  `catch |err|` blocks on lines 469–471, 480–486, etc., repeat the
  same convert-to-exit-code pattern four times. A helper macro or
  inline function would reduce the repetition and the risk of
  inconsistent error codes.
- `src/cut.zig:345` and `src/cut.zig:349`: two separate branches
  (`d.len == 0` and `d.len > 1`) produce identical error messages
  and return codes. They should be collapsed into
  `if (d.len != 1)`.

### Naming

- `iter` (lines 66, 217, 262): generic name used for three different
  iterators in three different functions. Acceptable within function
  scope, but consider `token_iter`, `field_iter` for clarity.
- `ch` (line 244): single-letter abbreviation for character. Use
  `byte` or `char_byte` since this is a `u8` scan.
- `pos` (line 161): acceptable as a loop index for a positional
  counter; this is within the "primitive integer" exception.

### Variable scope / aliasing

- `Range.start` and `Range.end` are typed `usize` (platform-width),
  but they represent 1-indexed byte/field positions that cannot
  meaningfully exceed `u32`. The `END` sentinel (`maxInt(usize)`)
  works but ties the sentinel value to the platform word size.
  Prefer `u32` for `start`/`end` with `const END: u32 =
  std.math.maxInt(u32)` to make the domain explicit and save memory
  in the range array.
- `line_has_delim` (line 506) is computed, then immediately used in
  a guard, but `cutFields` re-computes the same `indexOfScalar`
  check internally (line 208). The outer check is redundant and the
  two scans are kept in sync only by convention.

### Comments

- `// Simple byte-by-byte selection` (line 160): no full stop.
- `// Clamp to remaining bytes` (line 176): explains what, not why.
  Why is clamping needed? (Answer: `utf8CharLen` can return 4 for
  a truncated sequence at end-of-input.) The comment should say:
  "Clamp to remaining bytes in case the input ends mid-sequence."
- `// Just "-" alone is invalid` (line 76): no full stop; could
  state the POSIX rationale.
- `// Skip this line` (line 509): this is inside the `if (!line_has_delim
  and only_delimited)` branch. The comment adds nothing the condition
  does not already say. Either remove the comment or explain the
  POSIX behavior it implements.

### Types / division

- `Range.start: usize`, `Range.end: usize` — see Variable scope
  section above. These should be `u32`.
- `std.fmt.parseInt(usize, ...)` (line 88): parsing user input
  directly into `usize` means a 64-bit value on a 64-bit host. A
  user typing `99999999999` gets a valid range position. Consider
  parsing into `u32` and returning `error.InvalidRange` on overflow
  to give a clean error instead of silently accepting astronomically
  large positions.
- No bare `/` division found. No `@divTrunc`/`@divFloor` concerns.

### Performance

- `isSelected` is called once per byte in `cutBytesOrChars` (line
  163) — O(R) per byte where R is the number of ranges. For large
  inputs with many ranges this is O(N·R). A pre-built lookup bitmap
  for the selected-position set (up to some threshold) would collapse
  the per-byte cost to O(1). This is a SHOULD, not a MUST, for
  typical use cases.
- `cutFieldsWhitespace` (lines 242–248) scans the line twice: once
  to detect whitespace presence, then again via `tokenizeAny`. A
  single-pass tokenize-then-check would avoid the redundant scan.

---

## Summary

| Category | Count |
|---|---|
| Function-length | 6 |
| Line-length | 167 (80 + 57 + 30) |
| Assertion gaps | 13 |
| Recursion/unbounded loops | 2 |
| Error handling | 5 |
| Naming | 11 |
| Variable scope | 6 |
| Comments | 10 |
| Types/division | 3 |
| Performance | 3 |

**Overall impression**: The most severe structural problem is the
absence of any `std.debug.assert` calls across all three files —
Tiger Style treats assertions as a primary safety mechanism, and
none of the production functions have them. The line-length discipline
is also comprehensively broken, particularly in `ln.zig` where
function signatures and error-reporting calls routinely hit 150–200
columns; this is a formatting pass away from being fixed. The
`runId` and `createSingleLink` functions are significantly over the
70-line limit and carry the complexity of multiple features that
should be separate helpers.
