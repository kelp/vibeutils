# Tiger Style Review: G4-du-sort

**Files reviewed**: 2 files, ~4502 LOC.

---

## src/du.zig

### Function-length violations (>70 lines)

- `resolveConfig` (lines 193-286): 93 lines. Branches over eight
  option interactions; extracting block-size resolution and color/icon
  resolution into helpers would bring each under the limit.
- `doStat` (lines 322-392): 71 lines (one over). The Linux/non-Linux
  split adds to the count; the platform-specific paths could be helper
  functions.
- `calculateDu` (lines 413-549): 137 lines. This is the most serious
  violation. It combines symlink policy, inode dedup, directory open,
  entry iteration, and recursive descent in a single body. Hard limit
  is 70.
- `runDu` (lines 647-753): 106 lines. Argument parsing, config
  resolution, style setup, and the main traversal loop all live here.

### Line-length violations (>100 cols)

Production code (excluding tests):

- L83: 127 cols (meta descriptor)
- L84: 107 cols (meta descriptor)
- L89: 105 cols (meta descriptor)
- L92: 107 cols (meta descriptor)
- L94: 108 cols (meta descriptor)
- L97: 109 cols (meta descriptor)
- L99: 118 cols (meta descriptor)
- L100: 129 cols (meta descriptor)
- L104: 128 cols (meta descriptor)
- L105: 124 cols (meta descriptor)
- L480: 102 cols
- L543: 115 cols (ternary spread across line)
- L559: 142 cols (`printEntry` signature)
- L614: 103 cols (`printStatError` signature)
- L623: 107 cols (error message call)
- L626: 102 cols (`printDirError` signature)
- L632: 115 cols (error message call)
- L635: 103 cols (`printIterError` signature)
- L636: 140 cols (error message call)
- L647: 134 cols (`runDu` signature)
- L651-L706: multiple lines 106-188 cols inside `runDu`'s error
  switch blocks

The meta descriptor block (L83-L105) alone has 10 violations.
Adding trailing commas to the struct literal and letting `zig fmt`
wrap them would fix all of those.

### Assertion gaps

Zero assertions exist anywhere in this file. Tiger Style requires a
minimum average of two per function. Functions with meaningful logic
and no assertions:

- `resolveConfig`: no assertion that `config.block_size > 0` after
  resolution, no assertion that `max_depth <= u64.max/2` when set.
- `calculateDu`: no assertion that `depth` does not overflow, no
  assertion on the inode key uniqueness invariant, no assertion that
  `dir_own_size + subtree_size` does not overflow `u64`.
- `getFileSize`: `@intCast(@max(0, stat_buf.blocks))` could assert
  `stat_buf.blocks >= 0` before casting rather than relying on `@max`.
- `printEntry`: the threshold logic negates `thresh` without asserting
  `thresh != std.math.minInt(i64)` (negation overflow).
- `parseThreshold`: `@intCast(abs_val)` to `i64` without asserting
  `abs_val <= std.math.maxInt(i64)`.

### Recursion / unbounded loops

**Direct recursion — CRITICAL.**
`calculateDu` calls itself at line 521 with no upper bound on depth.
A directory tree with symlink loops (even with `-P`, deeply nested
real trees) or a pathologically deep filesystem hierarchy will
overflow the call stack. Tiger Style prohibits recursion; the standard
fix is an explicit stack (e.g. `std.ArrayList` of pending paths) with
a hard depth cap and an assertion.

The directory iterator loop at lines 506-540 uses `while (true)` and
breaks on `iterator.next()` returning `null` or an error. This is
bounded by filesystem entry count, which is fine, but it lacks an
explicit upper-bound assertion. For Tiger Style strict compliance the
bound should be named and asserted.

### Error handling

- `seen_inodes.put(key, {}) catch {}` (line 475): silently drops an
  OOM failure. If the put fails, the same inode will not be tracked,
  causing it to be counted again on the next encounter. The error
  should propagate via `has_error` or bubble up.
- `printHelp` / `printVersion`: `writer.print(...) catch {}` silences
  stdout write failures. In a utility this is borderline acceptable
  (broken pipe scenario), but no comment explains the intent.
- `printEntry` (lines 574-607): seven consecutive `catch {}` without
  any comment motivating the silence. The stdout write failure at
  line 576/585 and icon color failures at lines 596-598 are distinct
  cases; the intentional ones deserve a comment.
- Line 514 and 514 in the merge path (`out_writer.flush() catch {}`):
  silences a flush failure on the output file, which could silently
  lose the last write buffer.

### Naming

- `resolveConfig` takes `deref_mode` as a parameter that is already
  resolved externally; the name `DereferenceMode` for the type and
  `.none`/`.args_only`/`.all` for variants is clear. No issues here.
- `val_str`, `hr_buf`, `stat_buf`, `c_path`, `path_buf` are common
  abbreviations. Tiger Style asks for no abbreviations. `val_str`
  should be `value_string` or `value_str` is already borderline;
  `hr_buf` should be `human_readable_buffer`. Pervasive throughout
  the file.
- `style: anytype` in `calculateDu` and `printEntry`: passing an
  opaque type through 11-argument recursion is a design smell. A
  concrete `*common.style.Style(...)` or an interface pointer would
  make the call site auditable.

### Variable scope / aliasing

- In `calculateDu`, `is_duplicate` is declared as `var` and then
  conditionally set inside an `if` block (lines 467-476). It could
  be a `const` computed by a helper to minimize mutable state.
- `effective_root_dev` (line 488) is only used inside the directory
  branch but is declared after the early return for non-directories.
  Its scope is correct but it sits 30+ lines before first use.
- `style` in `runDu` (line 714) is a copy of a `Style` struct; it
  is immediately passed to `calculateDu` by value, which in turn
  passes it by value again through all recursive calls. If `Style`
  grows beyond 16 bytes this becomes expensive. Pass `*const Style`.

### Comments

- `calculateDu` has a one-line doc comment ("Calculate disk usage for
  a path, recursively for directories") that says *what*, not *why*
  the function exists or what invariants the caller must satisfy
  (e.g. `depth == 0` for top-level arguments).
- The inode dedup comment at line 459-462 is the strongest comment in
  the file — it explains the symlink-with-nlink==1 edge case. This is
  good; the pattern should be applied elsewhere.
- The `// Still report the directory entry size itself` comment at
  line 498 says what, not why. Why is the directory size still
  reported when we can't read it?

### Types / division

- Line 583: `(size_bytes + config.block_size - 1) / config.block_size`
  — bare `/` for ceiling division. Tiger Style requires `@divFloor`
  or a named `div_ceil` helper to show intent. Also,
  `size_bytes + config.block_size - 1` can overflow `u64` if
  `size_bytes` is near `maxInt(u64)` and `config.block_size` is
  large; this should be `@divFloor(size_bytes + (config.block_size - 1), config.block_size)` with an assertion that `config.block_size > 0`.
- `usize` is used for loop indices and array sizes throughout — these
  are stdlib-bound (slice indexing) and acceptable.

### Performance

- `calculateDu` is called recursively, building a new stack frame for
  every directory level. With deep trees this is both a stack overflow
  risk and a performance concern; an iterative traversal with an
  explicit queue would be O(1) stack.
- `std.fs.path.join` is called inside the hot directory iterator loop
  (line 514), allocating a new heap string for every entry. A
  fixed-size path buffer built with a single concatenation (appending
  to a pre-allocated buffer) would eliminate per-entry allocation.

---

## src/sort.zig

### Function-length violations (>70 lines)

- `parseArgs` (lines 86-312): 227 lines. The entire argument parser
  is one function. Long option parsing (lines 102-198) and short
  option parsing (lines 199-304) could each be a helper. The function
  is a `while` loop over `i < args.len` with two large nested
  `if`/`else if` chains; Tiger Style asks to push `if`s up and `for`s
  down — these should be separate functions.
- `runSort` (lines 413-575): 163 lines. Handles `--files0-from`
  expansion, merge mode, stdin/file reading, check mode, sorting, and
  output — six distinct concerns in one body.

### Line-length violations (>100 cols)

Production code:

- L138: 129 cols
- L149: 105 cols
- L151: 103 cols
- L156: 134 cols
- L163: 126 cols
- L172: 140 cols
- L184: 138 cols
- L197: 163 cols
- L224: 137 cols
- L228: 134 cols
- L240: 137 cols
- L260: 137 cols
- L264: 137 cols
- L277: 137 cols
- L281: 133 cols
- L294: 137 cols
- L301: 164 cols
- L360: 106 cols
- L369: 106 cols
- L413: 142 cols (`runSort` signature)
- L431: 178 cols
- L439: 165 cols
- L446: 149 cols
- L484: 157 cols
- L505-506: 107/152 cols
- L542: 157 cols
- L561-562: 103/148 cols
- L581: 178 cols (`readLines` signature)
- L584: 106 cols
- L994: 106 cols
- L1274: 131 cols (`mergeLines` signature)
- L1311: 143 cols (`checkSorted` signature)
- L1329: 139 cols
- L1340: 106 cols (`writeLines` signature)

The `printErrorWithProgram` call-sites are the dominant driver. These
are unlikely to fit in 100 cols, but the function signatures at L413,
L581, L1274, L1311 can be wrapped with trailing commas.

### Assertion gaps

No assertions anywhere in this file. Specific gaps:

- `splitFields`: `MAX_FIELDS = 256` is silently enforced by the
  `if (count < MAX_FIELDS)` guards, but no assertion fires when
  a line exceeds the limit. A caller gets a silently truncated field
  list. An `assert(count <= MAX_FIELDS)` at the end would catch this
  in debug builds.
- `fieldOffset`: asserts `field_idx < fields.len` via an early return
  but does not assert that `field_ptr >= line_ptr` before computing
  the offset difference (a negative result would wrap `usize`).
- `parseLeadingNumber` / `parseHumanParts`: both are called on every
  comparison in the hot sort path. Neither asserts preconditions on
  the input slice.
- `compareVersion`: the loop over `ai` and `bi` has no assertion that
  they never exceed `a.len` and `b.len` respectively before the inner
  index access.
- `mergeLines`: `positions` is allocated as `file_lines.len` entries
  but no assertion checks this invariant before the inner loop indexes
  `positions[file_idx]` and `file_lines[file_idx]`.
- `checkSorted`: `lines[1..]` is indexed with `idx + 2` in the error
  message without asserting `lines.len >= 2` (guarded only by an
  early return on `lines.len <= 1`; that guard is sufficient but an
  assertion would make the invariant explicit).

### Recursion / unbounded loops

**Unbounded `while (true)` loops without explicit capacity assertions:**

- `compareDictionary` (line 847): bounded by `a.len` and `b.len`,
  both of which progress monotonically. No upper-bound assertion.
  Tiger Style requires the bound to be named and asserted.
- `comparePrintable` (line 890): same pattern.
- `mergeLines` (line 1283): bounded by the total number of lines
  across all files, but this count is never computed or asserted. The
  loop will terminate when all `positions[i]` reach their respective
  file lengths, but nothing makes this invariant visible.
- `compareVersion` (line 1157): the outer `while (ai < a.len and
  bi < b.len)` is a bounded loop, not `while (true)` — this one is
  fine.

None of the `while (true)` loops are direct infinite loops, but Tiger
Style requires explicit bounds (`const max_iterations = ...;
assert(iterations < max_iterations);`).

No recursion found in sort.zig.

### Error handling

- `readLines` (lines 583-586): non-`OutOfMemory` read errors are
  silently swallowed (`else => return`). An I/O error on a file opens
  the question: should the caller see an empty result or an error?
  Silently returning an empty line list while the caller proceeds to
  sort-and-emit is misleading. The error should be propagated or at
  minimum logged.
- `out_writer.flush() catch {}` (lines 514, 570): silences flush
  failures on the output file. A partially flushed sort result is a
  data-loss scenario.

### Naming

- `f0f_path`, `f0f_file`, `f0f_reader`, `f0f_buf` (lines 433-448):
  `f0f` is an opaque abbreviation for `files0_from`. Should be
  `files0_path`, `files0_file`, etc.
- `a_str`, `b_str` in `compareWithFlags` (lines 800-801): these are
  aliases of `a` and `b` with leading blanks stripped. `a_stripped`
  and `b_stripped` would be clearer.
- `val_str` appears multiple times in `parseArgs` for different
  option values — using the same name for different local values
  inside the same long function reduces clarity.
- `min_idx` in `mergeLines` (line 1285): `min_file_index` would be
  clearer, though `min_idx` is borderline acceptable for a loop
  variable.
- `S` as the name for the inner `struct` holding `threadlocal var
  fields` (line 718): a single letter for a type is not `snake_case`
  for a variable but it is an unusual pattern. `FieldStorage` or
  simply naming the `threadlocal` at module scope would be clearer.

### Variable scope / aliasing

- `sort_ctx` (line 458) is created before the merge-mode check
  (line 464) and the single-file path (line 556). The variable is
  always used, but its declaration site is 100 lines above some uses.
  Declare it adjacent to first use in each branch.
- `linesEqual` creates a `SortContext` with `allocator = undefined`
  (line 1364). This is safe only because `compareLines` does not
  allocate when called from this path, but the `undefined` allocator
  is a silent footgun. A comment explaining why this is safe, and an
  assertion that no keys using allocation are active, would help.
- `per_file_lines` and `merge_buffers` in the merge path (lines
  465-474): both declared with blank lines separating the `defer`
  blocks. This is good Tiger Style practice — noted as correct.

### Comments

- `compareDictionary` and `comparePrintable` share the exact same
  structure but the second has no doc comment explaining *why* it
  mirrors the first rather than reusing it. A comment on
  `comparePrintable` explaining the deliberate duplication (or lack
  thereof) is missing.
- `splitFields`: the `MAX_FIELDS = 256` cap comment says "should be
  sufficient" without stating the consequence of exceeding it (silent
  field truncation). That consequence deserves a sentence.
- `linesEqual` (line 1362): the comment "If neither a < b nor b < a,
  they are equal" states what the code does. It does not say *why*
  `compareLines` is called twice rather than returning `.eq` directly
  from `compareLines`. The reason (comparator returns `bool`, not
  `Order`) deserves a note.
- `readLines` non-OOM catch (line 585): `else => return` has no
  comment explaining the policy (silently treating read errors as
  empty files).

### Types / division

- `start_field`, `start_char`, `end_field`, `end_char` in `KeyDef`
  are all `usize`. These represent user-supplied 1-based field numbers
  which are logically bounded by the file line count, itself bounded
  by available memory. Using `u32` would make the intent (field
  numbers are small) explicit and reduce the struct size.
- `parseBufferSize` returns `?usize` and the multiplication
  `num * 1024 * 1024 * 1024` (line 1268) can overflow `usize` on
  32-bit targets. An overflow check or `@mulWithOverflow` assertion
  is missing.
- No bare `/` in production sort code. The numeric parsers use
  floating-point arithmetic throughout, which is acceptable for sort
  comparisons.

### Performance

- `splitFields` uses a `threadlocal` static buffer of 256 entries.
  This avoids allocation on every comparison call and is a correct
  hot-path optimization. The trade-off is that it breaks if sort is
  ever parallelised (each thread gets its own copy, which is actually
  safe for `threadlocal`, but the limit is per-thread so the global
  constant `MAX_FIELDS` covers all threads independently — this is
  fine).
- `linesEqual` (line 1362) calls `compareLines` twice for every
  unique-filter decision. A `compareWithFlags`-level function that
  returns `Order` would cut this to one call, but the current
  `compareLines` API returns `bool`. This is an artifact of
  `std.mem.sort`'s comparator contract; changing it would require
  a wrapper anyway. Noted as a minor inefficiency.
- `mergeLines` is an O(N * K) merge (for N total lines and K files)
  because it scans all file heads linearly for each output line. A
  min-heap would give O(N log K). For the typical `sort -m` use case
  (few files), the linear scan is fine, but no comment documents this
  complexity choice.
- `parseLeadingNumber` and `parseHumanParts` duplicate the same
  whitespace-skip and digit-accumulation logic. `parseHumanNumber`
  (line 1101) is a third copy of the same pattern. Extract a shared
  `parseNumberPrefix(s: []const u8) struct { value: f64, end: usize,
  negative: bool }` helper to eliminate the triplication and reduce
  maintenance risk.

---

## Summary

| Category | Count |
|---|---|
| Function-length | 6 (4 in du.zig, 2 in sort.zig) |
| Line-length | 60+ (34 production in du.zig, 36 production in sort.zig) |
| Assertion gaps | 11 (5 in du.zig, 6 in sort.zig) |
| Recursion/unbounded loops | 4 (1 recursion + 1 loop in du.zig, 3 loops in sort.zig) |
| Error handling | 5 (3 in du.zig, 2 in sort.zig) |
| Naming | 7 (3 in du.zig, 4 in sort.zig) |
| Variable scope | 4 (2 in du.zig, 2 in sort.zig) |
| Comments | 5 (3 in du.zig, 2 in sort.zig — excluding already-noted items) |
| Types/division | 4 (2 in du.zig, 2 in sort.zig) |
| Performance | 5 (2 in du.zig, 3 in sort.zig) |

**Overall impression**: Both files are functional and well-tested, but
neither conforms to Tiger Style. The most serious issue is
`calculateDu`'s direct recursion with no depth bound, which violates
both the "no recursion" and "bounded loops" rules and poses a real
stack-overflow risk on deep or adversarial filesystems. The complete
absence of `assert` calls across 4500 lines of production code is the
second-most significant gap — Tiger Style's safety model depends on
assertions catching violated invariants at every function boundary.
