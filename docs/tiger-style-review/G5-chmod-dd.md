# Tiger Style Review: G5-chmod-dd

**Files reviewed**: 2 files, ~4246 LOC.

---

## src/chmod.zig

### Function-length violations (>70 lines)

- `runChmod` (lines 65–162): 98 lines. Handles argument pre-processing,
  parsing, validation, and dispatch all in one body. Should split the
  `--` pre-processing and the preserve-root check into named helpers.
- `chmodFiles` (lines 263–373): 111 lines. The mode-parsing preamble,
  reference-file stat, and per-file dispatch loop are three distinct
  concerns; each could be a helper.
- `chmodRecursive` (lines 401–470): 70 lines. Right at the limit; the
  symlink-follow branch inside the `while` loop (lines 430–443) is a
  candidate for extraction.
- `applyModeSpecToFile` (lines 615–697): 83 lines. The stat block, mode
  computation, and two-branch chmod syscall each belong in a helper.
- `statByPath` (lines 508–571): 64 lines. Not a violation but the
  Linux/non-Linux compile-time branch makes it dense; consider a
  comptime-selected inline helper.

Note: the awk brace-counter falsely inflated `fn chmod` and `fn sym`
to hundreds of lines because test blocks follow immediately. The actual
bodies are 12 lines and 2 lines respectively — no violation.

### Line-length violations (>100 cols)

There are 87 lines over 100 columns across the file; 32 of those are
in production code (lines 1–700). Representative worst cases:

- L66: 151 cols — `pub fn runChmod(...)` signature.
- L92: 170 cols — `ArgParser.parseOrExit(...)` call.
- L142: 185 cols — `common.printErrorWithProgram(...)` inside
  preserve-root guard.
- L264: 176 cols — `fn chmodFiles(...)` signature.
- L378: 175 cols — `fn applyModeToPath(...)` signature.
- L402: 174 cols — `fn chmodRecursive(...)` signature.

All function signatures with 7+ parameters blow the 100-column limit.
Adding trailing commas and letting `zig fmt` wrap would fix these.
The `common.printErrorWithProgram` call sites are also uniformly too
wide; a local `err(...)` alias or shorter helper wrapper would help.

### Assertion gaps

Zero calls to `std.debug.assert` anywhere in production code. Tiger
Style requires a minimum of two assertions per function on average.
Key gaps:

- `chmodFiles`: does not assert `files.len > 0` on entry (callers
  enforce this, but the function itself has no guard).
- `applyModeSpecToFile`: does not assert `file_path.len > 0` or that
  `new_mode <= 0o7777` after computing the symbolic result.
- `chmodRecursive`: no assertion that `dir_path.len > 0` or that
  `depth` of recursion is bounded (see Recursion section).
- `modeToString`: no assertion that `mode <= 0o7777` on entry; input
  outside that range silently produces wrong output.
- `statByPath`: no assertion that `path.len > 0` before the
  `@memcpy`.

### Recursion / unbounded loops

- `chmodRecursive` calls itself at lines 424–426 and 438–440. This is
  direct recursion with no explicit depth bound. A deeply nested
  directory tree (or a symlink cycle when `-L` is active) will exhaust
  the call stack. Tiger Style prohibits recursion; the fix is an
  explicit stack (e.g., an `ArrayList` of pending paths) with an
  assertion on the stack size remaining below a fixed maximum.
- The `while` loop in `chmodFiles` over `files` (line 324) is bounded
  by `files.len`, which is acceptable, but there is no assertion of an
  upper bound.

### Error handling

- Lines 1384 and 1401 in test code use `catch {}` on `chmodFiles`
  after it already returned an error — acceptable in test context where
  the subsequent assertion verifies the error path. No bare `catch {}`
  in production code.
- `applyModeToPath` (line 379) discards the `io` parameter with
  `_ = io;`. This is dead code that should be removed.

### Naming

- The private helper at line 736 is named `fn chmod`. This name
  collides with both the C stdlib `chmod` syscall and the utility's own
  public identity, making call sites ambiguous. Rename to
  `runChmodHelper` or `chmodTestHelper`.
- `ChmodOptions` is passed by value in every internal function
  signature. The struct holds 10 booleans and one optional slice
  pointer — roughly 24 bytes on a 64-bit target. Tiger Style says
  arguments larger than 16 bytes that are not mutated should be
  `*const T`. All four inner functions (`chmodFiles`, `applyModeToPath`,
  `chmodRecursive`, `applyModeSpecToFile`) should take
  `options: *const ChmodOptions`.
- `writer` and `stderr_writer` are `anytype` parameters throughout.
  Tiger Style prefers explicit types; these should be
  `*std.Io.Writer`.

### Variable scope / aliasing

- In `chmodFiles`, `use_reference` at line 277 is immediately
  computable from `reference_mode != null`, but it is declared as a
  separate `var`. This is a minor alias; use the expression directly or
  fold the two `const` declarations.
- `effective_args` in `runChmod` (line 69) is declared before the
  loop that may or may not populate it, then used after. The scope is
  correct but the `defer if (effective_args) |ea|` idiom is unusual;
  a named helper function would make the lifetime clearer.

### Comments

- Lines 66–70: multi-line comment block starts lowercase ("with '-'
  (e.g..."). Should begin with a capital letter.
- Line 447: "and cannot change symlink permissions on Linux, so they
  are / silently skipped." — starts lowercase. Should be a sentence.
- Line 600: starts lowercase ("happens per-file…"). Should be
  capitalized.
- Lines 608–610: module-level comment block starts lowercase. Should be
  a proper sentence.

### Types / division

No bare integer division. No `usize` used where a fixed-width type
would be more appropriate (file mode values use `u32` correctly).

### Performance

- `std.fs.path.join(allocator, ...)` inside the directory iterator
  loop at line 418 allocates on every entry. For deep trees this
  means many small allocations. A pre-allocated path buffer (stack or
  arena) that is reused across iterations would eliminate per-entry
  heap traffic and match Tiger Style's "static memory" principle.
- `getUmask()` (line 574–578) calls `umask(0)` and then restores it
  on every symbolic-mode chmod. For a recursive chmod over thousands of
  files this is called once per file. The umask should be read once
  before the loop and passed through `ChmodOptions` or the `ModeSpec`.
  (The code already passes it via `ModeContext` in the symbolic path,
  but it re-reads the umask on every call to `applyModeSpecToFile`.)

### Other observations

- The `chmod` test helper at line 736 hardcodes `ChmodOptions{}`, so
  tests using it cannot exercise flags like `-v` or `-R`. Tests that
  need flag coverage call `runChmod` or `chmodFiles` directly, making
  the helper redundant.
- The test at line 1671–1723 contains two large comment blocks
  documenting a known bug (`BUG:` prefix). If the bug is real and
  unfixed, it should be a tracked issue, not an inline comment
  suppressing a failing test expectation.

---

## src/dd.zig

### Function-length violations (>70 lines)

- `parseOperands` (lines 117–199): 83 lines. The operand dispatch
  chain is a sequence of `if/else if` arms with no branching logic;
  splitting the numeric-operand parsing and the conv/status parsing
  into sub-functions would bring it under 70 lines.
- `parseConversions` (lines 202–252): 51 lines. Not a violation, but
  the body is a flat `if/else if` chain with 20 arms. A lookup table
  (`std.StaticStringMap`) would be cleaner and shorter.
- `runDd` (lines 476–866): 391 lines. This is the most severe
  violation. The function contains: argument validation (≈50 lines),
  buffer allocation (≈15 lines), file open/skip/seek (≈30 lines), the
  main copy loop (≈175 lines) with four distinct sub-modes
  (simple copy, conv=block, conv=unblock, buffered copy), and several
  flush/fsync epilogues. Each sub-mode is a candidate for a named
  helper. The copy loop alone would be a separate 70-line violation if
  extracted as a function.

### Line-length violations (>100 cols)

There are 57 lines over 100 columns in the file; 26 are in production
code (lines 1–875). Representative cases:

- L477: 134 cols — `pub fn runDd(...)` signature.
- L502: 119 cols — `printErrorWithProgram` inside lcase/ucase check.
- L593: 142 cols — `printErrorWithProgram` inside seek-write fallback.
- L648: 140 cols — `printErrorWithProgram` inside conv=noerror/sync
  error path.

The pattern is the same as chmod: long function signatures and
`common.printErrorWithProgram` call sites. The same remedies apply.

### Assertion gaps

Zero `std.debug.assert` calls in production code. Notable gaps:

- `runDd`: does not assert `ibs > 0` and `obs > 0` before using them
  as buffer sizes (the validation does return early, but an assertion
  would make the invariant explicit at the allocation site).
- `applyConversions`: no assertion that `buf.len > 0`; an empty slice
  is a legal no-op but the function silently accepts it.
- `parseByteSize` / `parseSingleSize`: no assertion that the returned
  value is non-zero or within a sensible range.
- `formatByteCount`: no assertion that `buf.len >= 32` (the function
  could silently return "?" if the buffer is too small).
- `invertTable`: used at comptime — the `@setEvalBranchQuota` suggests
  this was tuned to pass; an assertion that `result` covers all 256
  values (i.e., is a permutation) would catch table corruption.

### Recursion / unbounded loops

- `runDd` line 626: `while (true)` with no assertion on maximum
  iterations. The loop breaks on EOF or `count` exhaustion, but there
  is no `assert(blocks_read < some_upper_bound)` to prove termination.
  Tiger Style requires non-terminating loops to assert their
  continuation condition.
- The `while` loops inside the conv=block (line 689) and conv=unblock
  (line 719) sub-modes are bounded by `data.len`, which is bounded by
  `ibs`. Acceptable, but no assertion confirms this.

### Error handling

- `printStats` (lines 381–389): `stderr.print(...)` errors are
  silently swallowed with `catch {}`. Writing to stderr is a
  best-effort operation, so this is pragmatically defensible, but the
  Tiger Style rule requires justification in a comment. Add "Stderr
  write failures are non-fatal; we cannot report them." as a comment
  adjacent to each `catch {}`.
- `printHelp` and `printVersion` at lines 491 and 496 discard errors
  from writing to stdout with `catch {}`. If stdout is closed (e.g.,
  broken pipe), the caller returns success. The callers should propagate
  these errors.
- The skip loop (lines 571–581) calls `readStreaming` and only handles
  `EndOfStream` and "other". If `conv_noerror` is set but the read
  fails during skip, the code returns `general_error` — inconsistent
  with how read errors in the main loop are handled.

### Naming

- `fb` at lines 357 and 400 is an abbreviation for "float bytes".
  Tiger Style prohibits abbreviations except for loop indices. Rename
  to `bytes_f64` or `bytes_float`.
- `DdConfig` is passed by value to `applyConversions` at line 312.
  `DdConfig` has approximately 28 fields (10+ `bool`, 8 `usize`,
  1 `?usize`, 1 `u8`, 1 `StatusLevel`) — well over 16 bytes. It
  should be `config: *const DdConfig`.
- `ibs`, `obs`, `cbs`, `bs` are domain-standard abbreviations for
  `dd` operand names; they are acceptable as field names within
  `DdConfig` where they match the documented operand name exactly.
  However, as local variables in `runDd` (lines 527–528,
  `const ibs = ...; const obs = ...;`) they could be
  `input_block_size` and `output_block_size` to distinguish the
  effective values from the raw config fields.

### Variable scope / aliasing

- `out_pos` (line 619), `blocks_read` (line 620), and `unblock_pos`
  (line 623) are declared before the `while (true)` loop that uses
  them. This is correct — they must survive across iterations — but
  `unblock_pos` is only used in the `conv_unblock` path. A comment
  explaining why it is declared at the outer scope (not just inside the
  branch) would help readers.
- `simple_copy` at line 616 is computed once and then checked in
  multiple places inside the loop. This is correct amortization, but
  it is declared without an inline assertion confirming the condition
  it encodes (e.g., `assert(!simple_copy or (!config.conv_block and
  !config.conv_unblock))`).
- `data` at line 672 (`var data = in_buf[0..bytes_read]`) is
  re-assigned at line 680 after conv=sync padding. This mutable slice
  alias across two assignments is hard to follow; extract the
  sync-padding step into a helper that returns the final slice.

### Comments

- Lines 499–523: validation comments ("lcase and ucase are mutually
  exclusive", etc.) start lowercase. Should begin with capital letters
  and end with periods.
- Line 677: "and with NUL bytes otherwise." starts lowercase mid-block.
- Line 854: "fsync the output file if requested." starts lowercase.
- The audit-wave tests at lines 2015–2114 include extensive block
  comments explaining known bugs; these are good methodology notes.

### Types / division

- Lines 360–371 and 394–410: floating-point division with `/` is used
  throughout `formatByteCount` and `printStats`. These are display
  computations on `f64`, not integer division, so `@divExact`/
  `@divFloor` do not apply. No violation.
- Line 586: `config.seek * obs` is unchecked integer multiplication on
  two `usize` values. If `config.seek` is large (e.g., parsed from
  user input as `seek=4294967295`) and `obs` is non-trivial, this
  silently overflows on 32-bit targets or wraps on 64-bit. Use
  `std.math.mul(usize, config.seek, obs) catch return ...` to match the
  pattern already used in `parseByteSize`.

### Performance

- `applyConversions` (line 311) accepts `DdConfig` by value, copying
  the entire ~100-byte struct on every call — once per input block.
  For a 1 MB block size that's one copy per block; for a 512-byte
  block size it is called millions of times per GB. Pass `*const
  DdConfig`.

### Other observations

- `config.files` is parsed and stored but never read in `runDd`. The
  `files=N` operand (copy N input files) is silently ignored. This
  should either be implemented or rejected with an "unsupported operand"
  error. Silent no-ops for named operands are user-hostile.
- `conv_sparse`, `conv_pareven`, `conv_parnone`, `conv_parodd`, and
  `conv_parset` are parsed and stored but never applied anywhere in
  `applyConversions` or `runDd`. Like `files`, these are silently
  accepted no-ops. The tests for them only verify that parsing
  succeeds, not that any conversion occurs. Either apply them or
  explicitly reject them.
- `printStats` takes `io: std.Io` as its first parameter but uses it
  only to call `std.Io.Timestamp.now(io, .real)`. If `status == .none`
  or `status == .noxfer`, `io` is never used. The parameter is
  harmless but slightly misleading.

---

## Summary

| Category | chmod.zig | dd.zig | Total |
|---|---|---|---|
| Function-length (>70 lines) | 4 | 3 | 7 |
| Line-length (>100 cols, prod) | 32 | 26 | 58 |
| Assertion gaps | 5 | 5 | 10 |
| Recursion / unbounded loops | 1 (direct recursion) | 1 (while true, no bound assert) | 2 |
| Error handling | 1 (`_ = io` dead param) | 3 (swallowed errors, inconsistent skip) | 4 |
| Naming | 3 | 3 | 6 |
| Variable scope / aliasing | 2 | 3 | 5 |
| Comments | 4 | 4 | 8 |
| Types / division | 0 | 1 (unchecked mul at seek) | 1 |
| Performance | 2 (per-entry alloc, per-file umask read) | 2 (DdConfig copy-by-value, per-block struct copy) | 4 |

**Overall impression**: Both files are functionally solid and well-tested,
but neither follows Tiger Style — zero assertions exist in production
code, the primary business functions far exceed the 70-line limit, and
line lengths consistently breach 100 columns. The direct recursion in
`chmodRecursive` is the most urgent structural issue; `runDd`'s 391-line
monolith is the most urgent readability issue.

Fix Order:
1. [IMPORTANT] Direct recursion in `chmodRecursive` — replace with
   an explicit bounded stack — `src/chmod.zig:401`
2. [IMPORTANT] `runDd` 391-line function — extract sub-mode helpers
   (`copySimple`, `copyBlock`, `copyUnblock`, `copyBuffered`) —
   `src/dd.zig:476`
3. [IMPORTANT] Zero assertions across both files — add entry/exit
   asserts to every meaty function — both files
4. [IMPORTANT] Unchecked `config.seek * obs` multiplication —
   `src/dd.zig:586`
5. [IMPORTANT] `config.files` silently ignored — `src/dd.zig:158`
6. [IMPORTANT] `conv_sparse` / parity flags silently ignored —
   `src/dd.zig:36-40`
7. [SUGGESTION] 58 line-length violations in production code — add
   trailing commas to signatures and let `zig fmt` wrap — both files
8. [SUGGESTION] `ChmodOptions` and `DdConfig` passed by value where
   `*const T` is required — both files
9. [SUGGESTION] `getUmask()` called once per file in recursive mode —
   read umask once before the file loop — `src/chmod.zig:574`
10. [SUGGESTION] Per-entry `allocator.alloc` in `chmodRecursive` loop
    — reuse a path buffer — `src/chmod.zig:418`
11. [SUGGESTION] Rename `fn chmod` helper to avoid name collision —
    `src/chmod.zig:736`
12. [SUGGESTION] Rename `fb` to `bytes_float` in both `formatByteCount`
    and `printStats` — `src/dd.zig:357,400`
