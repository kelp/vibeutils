# Tiger Style Review: G3-stat-grep

**Files reviewed**: 2 files, ~4814 LOC.

---

## src/stat.zig

### Function-length violations (>70 lines)

- `expandFormatDirective` (lines 411–661): 251 lines. The body is a
  single large `switch` with 26 arms, many of which contain branching
  sub-logic. The largest arms (`'m'`, `'N'`) could be extracted into
  named helpers.
- `printDefaultFormat` (lines 723–867): 145 lines. Two nested blk
  expressions for username/groupname lookup obscure the main flow;
  each could move to a helper.
- `parseArgs` (lines 76–194): 119 lines. The manual arg-loop is
  typical for the codebase pattern but still oversized.
- `lookupMountInfo` (lines 963–1044): 82 lines.
- `doStat` (lines 220–292): 73 lines. Minimally over; the Linux/macOS
  branching accounts for most of the body.

### Line-length violations (>100 cols)

67 lines exceed 100 columns. Worst offenders:

- `src/stat.zig:1120` — 142 cols (`pub fn runStat` signature)
- `src/stat.zig:1151` — 141 cols (`printErrorWithProgram` call)
- `src/stat.zig:1142` — 139 cols (`printErrorWithProgram` call)
- `src/stat.zig:1127` — 134 cols (`printErrorWithProgram` call)
- `src/stat.zig:965` — 126 cols (`lookupMountInfo` fd open call)
- `src/stat.zig:963` — 126 cols (`lookupMountInfo` fn signature)
- `src/stat.zig:1167` — 120 cols (`printErrorWithProgram` call)
- `src/stat.zig:339` — 116 cols (`std.fmt.bufPrint` in `formatTimestamp`)
- `src/stat.zig:2113` — 114 cols (test body)
- `src/stat.zig:1505` — 114 cols (test body)

All 67 violations hide code behind horizontal scroll. The function
signatures for `runStat` (line 1120) and `lookupMountInfo` (line 963)
are the worst; add trailing commas and let `zig fmt` wrap them.

### Assertion gaps

Zero calls to `std.debug.assert` appear in either file's non-test
code. This is the most significant Tiger Style deviation: the entire
1250-line production surface of `stat.zig` runs without a single
runtime assertion.

Specific gaps:

- `doStat` (line 220): no assertion that `path.len > 0` on entry, and
  no assertion that the returned `StatResult` fields satisfy expected
  invariants (e.g. `mode != 0` for a found file).
- `formatTimestamp` (line 316): no assertion that `nsec >= 0` before
  the clamp at line 329. The comment explains the clamp but an assert
  would catch upstream bugs.
- `formatPermissions` (line 364): no assertion that `mode` contains a
  valid IFMT bits combination.
- `expandFormatDirective` (line 411): no assertion that `directive` is
  a printable ASCII byte before the switch.
- `printDefaultFormat` (line 723): `size_u: u64 = @intCast(stat_buf.size)`
  at line 761 will panic at runtime if `size` is negative. There is no
  `assert(stat_buf.size >= 0)` to surface the invariant. The same
  applies to `blocks_u` and `blksize_u` at lines 762–763.
- `lookupMountInfo` (line 963): no assertion that the returned mount
  string is non-empty; callers rely on the "/" fallback implicitly.

### Recursion / unbounded loops

No violations in `stat.zig`.

### Error handling

- `src/stat.zig:536–541` (`expandFormatDirective`, `'o'` arm): both
  branches of the `if (builtin.os.tag == .macos ...)` block emit
  identical output (`stat_buf.blksize`). The conditional is dead code
  — the two arms are identical. If there is a platform difference
  intended here (e.g. `f_iosize` on macOS), it has been lost. Remove
  the dead branch or implement the distinction.
- `src/stat.zig:988` (`lookupMountInfo`): `std.posix.read` error is
  silently discarded via `catch break`. A read error is treated
  identically to EOF, which can yield a silently truncated result and
  a wrong mount point. The comment on line 964 acknowledges the raw
  syscall approach but does not justify the silent error drop.

### Naming

- `src/stat.zig:521` and `src/stat.zig:741`: `n` used as the return
  value of `c.readlink(...)`. Tiger Style prohibits abbreviations
  except for primitive loop indices. Rename to `bytes_read` or
  `link_len` for clarity.
- `src/stat.zig:988`: same issue — `n` as the return value of
  `std.posix.read`. Use `bytes_read`.

### Variable scope / aliasing

- `src/stat.zig:756–761` (`printDefaultFormat`): `size` (i64) is
  declared at line 756, used once at line 757, then immediately
  shadowed by `size_u` (u64) at line 761, also derived from
  `stat_buf.size`. Two variables alias the same field with different
  types. The i64 form is only needed for the zero-check; use
  `stat_buf.size == 0` directly and keep only `size_u`, or assert
  `stat_buf.size >= 0` and use a single cast.

### Comments

- `src/stat.zig:536` (`'o'` arm): the comment says "Optimal I/O
  transfer size" but gives no rationale for the platform conditional
  that does nothing. Comments must say why; this one only names what.
- `src/stat.zig:231`: `// BASIC_STATS | BTIME` partially explains the
  magic number `0xfff` but does not state why `@bitCast` is used
  instead of a named constant or flag combination. The why is missing.

### Types / division

- `src/stat.zig:230`: `const statx_mask: linux.STATX = @bitCast(@as(u32, 0xfff))`.
  The magic constant `0xfff` is unexplained at the type level. The
  `linux.STATX` type presumably has named fields; using a bitcast with
  a raw hex literal bypasses the type's intent. This is a correctness
  risk if the bit layout of `linux.STATX` changes.
- `src/stat.zig:334–337` (`formatTimestamp`): `@divTrunc` is used
  correctly for timezone offset arithmetic. No bare `/` violations.

### Performance

No significant hot-path concerns in `stat.zig` given it processes one
file at a time.

### Other observations

- `src/stat.zig:963`: `lookupMountInfo` reads all of
  `/proc/self/mountinfo` (up to 32 KB) into a stack buffer on every
  call to `expandFormatDirective` for `'m'`. When processing many
  files with `%m` in the format, this reads the file repeatedly. The
  result could be cached across the `for (positionals)` loop in
  `runStat`.

---

## src/grep.zig

### Function-length violations (>70 lines)

- `parseArgs` (lines 106–437): 332 lines. Massively over limit. The
  long-option and short-option arms are independent enough to split
  into `parseLongOption` and `parseShortOption` helpers.
- `processFile` (lines 774–962): 189 lines. Contains the context
  window logic, the `-o` multi-match loop, the count/files-with-match
  post-processing, and the line-splitting — four distinct concerns.
- `runGrep` (lines 1157–1271): 115 lines. Mixes pattern compilation,
  filename-display decision, stdin handling, recursive dispatch, and
  per-file dispatch.
- `matchLine` (lines 606–692): 87 lines. Has four semi-independent
  code paths (fixed/regex × word_regexp/not).

### Line-length violations (>100 cols)

75 lines exceed 100 columns. Worst offenders:

- `src/grep.zig:965` — 240 cols (`fn printContextLine` signature with
  11 parameters)
- `src/grep.zig:440` — 221 cols (`fn loadPatternsFromFile` signature)
- `src/grep.zig:856` — 218 cols (call to `printContextLine` inside
  `processFile`)
- `src/grep.zig:930` — 185 cols (second call to `printContextLine`)
- `src/grep.zig:899` — 173 cols (`matchAnyPattern` call in `-o` loop)
- `src/grep.zig:1643` — 157 cols (`testRunGrepOutput` return type)
- `src/grep.zig:1051` — 152 cols (`printErrorWithProgram` in
  `searchDirectory`)
- `src/grep.zig:872` — 151 cols (`while` condition in `-o` loop)
- `src/grep.zig:1157` — 150 cols (`pub fn runGrep` signature)
- `src/grep.zig:1238` — 148 cols (`printErrorWithProgram` call)

The 240-column `printContextLine` signature is the worst in the
entire review. The 11-parameter list violates the Tiger Style options
pattern as well (see Naming below).

### Assertion gaps

Zero calls to `std.debug.assert` appear in non-test code. Specific
gaps:

- `matchLine` (line 606): no assertion that `match_start <= match_end`
  holds on all return paths. The `printMatchLine` caller at line 915
  relies on this invariant but does not assert it.
- `processFile` (line 774): no assertion that `patterns.len > 0` on
  entry. An empty pattern slice would silently produce no output.
- `compilePattern` (line 511): no assertion that `pattern_z` is
  NUL-terminated before passing to `c.regcomp`.
- `anchorBreAlternatives` (line 472): on OOM the function returns
  `.{ .pattern = null, .use_ere = false }` silently. The caller at
  line 530 propagates `null` upward, but neither site asserts that the
  allocator succeeded or explains the silent degradation.
- `searchDirectory` (line 1017): the `while iter.next(io) catch null`
  at line 1037 silently discards directory read errors. An `assert` or
  at minimum a logged error path would be appropriate.

### Recursion / unbounded loops

- `src/grep.zig:1044` and `src/grep.zig:1068` (`searchDirectory`):
  direct recursion on directory traversal. On a deeply-nested
  filesystem or a symlink cycle (even with `-r` not `-R`) this will
  stack-overflow. Tiger Style requires iteration with an explicit
  depth bound; the current implementation has neither. The missing
  depth limit is a correctness risk: `grep -r /` on a pathological
  filesystem will crash.
- `src/grep.zig:651` (`matchLine`, regex word_regexp path): the inner
  while loop `while (search_start <= line.len)` is bounded by `line.len`,
  not unbounded. Acceptable, though the exit condition at line 672
  relies on `abs_start + 1 > line.len` which is subtle. No assert
  guards the loop termination.
- `src/grep.zig:618` (`matchLine`, fixed word_regexp path):
  `while (pos <= haystack.len)` is similarly bounded. The
  `pos = abs_start + 1` advance guarantees termination only if
  `find` always returns a non-decreasing position, which is true for
  `std.mem.find` but not asserted.

### Error handling

- `src/grep.zig:719–766` (output helper functions `printFilename`,
  `printLineNumber`, `printByteOffset`, `printSep`, `printMatchLine`):
  every write is `catch {}`, silently swallowing write errors. If the
  output pipe is broken (e.g. `grep ... | head`), errors are dropped
  on the floor with no way to detect or propagate them. This is the
  design pattern used across the file, but it means grep will silently
  produce incomplete output rather than exiting with an error, which
  differs from GNU grep behavior.
- `src/grep.zig:1037`: `iter.next(io) catch null` drops directory
  iteration errors silently. Errors during recursive traversal are
  indistinguishable from end-of-directory.
- `src/grep.zig:787`: `allocRemaining(...) catch return false`. An OOM
  during file reading causes `processFile` to return `false` (no
  match), which is incorrect: the file was not processed, but the
  caller treats it as "processed with no match." This can produce a
  false exit code of 1 when the real cause is OOM.

### Naming

- `src/grep.zig:965` (`printContextLine`): the function takes 11
  parameters including `show_filename`, `show_line_number`,
  `show_byte_offset`, `use_color`, `fn_sep`, `line_term`. Tiger Style
  requires `options: struct {}` when arguments could be confused at
  the call site. With 11 positional booleans and integers, call sites
  at lines 856 and 930 are 200+ columns wide and unreadable.
- `src/grep.zig:710`: `const line_number = "\x1b[32m"` in the `Color`
  struct shadows the semantic meaning of `opts.line_number` (a bool).
  Within `printLineNumber`, both `line_number` (the ANSI code) and
  `line_num` (the actual line number) appear; the naming collision
  is confusing.
- `src/grep.zig:605` (`matchLine`): parameter `word_regexp: bool`
  duplicates the field name from `GrepOptions`. Consistent, but the
  function also takes `prev_char: ?u8` which is a sentinel-heavy
  design. The parameter names themselves are acceptable.

### Variable scope / aliasing

- `src/grep.zig:795–801` (`processFile`): `line_term` and `line_delim`
  are computed from the same `opts.null_line_sep` field. In all cases
  where `null_line_sep` is true, `line_delim == line_term == 0`, and
  where false, both are `'\n'`. The two variables are perfect aliases.
  Collapse to one.
- `src/grep.zig:612–615` (`matchLine`, fixed word_regexp): the tuple
  `search_info` is assigned and immediately destructured into
  `haystack`, `needle`, `need_free`. Zig does not have destructuring
  tuple syntax the way this is written — this uses index access
  (`search_info[0]`, `[1]`, `[2]`), which obscures what the fields
  represent. Declare them as named variables.

### Comments

- `src/grep.zig:599–604` (doc comment on `matchLine`): explains what
  `prev_char` is but not why the post-validation approach was chosen
  over pattern wrapping. The comment mentions "macOS doesn't support
  `\|` in BRE" which is the correct why — but it is buried in the
  middle of the sentence. The explanation is present; the structure
  could be clearer.
- `src/grep.zig:172–173` (`--text`, `--binary` stubs): `// No-op`
  comments describe what the handler does, not why accepting these
  silently is correct (i.e., the rationale that Unix treats all files
  as text by default). The why should be explicit to prevent someone
  from "completing" a stub that is intentionally minimal.

### Types / division

- `src/grep.zig:63–65` (`GrepOptions`): `max_count: ?usize`,
  `after_context: usize`, `before_context: usize`. These count lines
  and bytes; `usize` is appropriate here since they interface with
  slice indices. Acceptable.
- `src/grep.zig:590–591` (`MatchResult`): `match_start: usize`,
  `match_end: usize`. Same justification — slice indices. Acceptable.
- No bare `/` division found.

### Performance

- `src/grep.zig:787` (`processFile`): the entire file is read into a
  single heap allocation (`allocRemaining`, up to 512 MB), then split
  into two parallel dynamic arrays (`lines` + `line_offsets`). For
  large files this triples the effective memory footprint. The
  canonical approach for line-by-line processing is to walk the buffer
  once without materializing a line array, computing offsets on the
  fly. The current design also precludes streaming (files larger than
  512 MB are silently capped).
- `src/grep.zig:654` (`matchLine`, regex word_regexp): `allocator.dupeZ`
  is called inside the while loop, allocating a new NUL-terminated
  copy of the suffix on each iteration. For a line with many
  non-word-boundary matches this can produce O(n²) allocations per
  line. The allocation could be hoisted: NUL-terminate the full line
  once and use offset-based `regexec` calls.

---

## Summary

| Category | stat.zig | grep.zig | Total |
|---|---|---|---|
| Function-length (>70 lines) | 5 | 4 | 9 |
| Line-length (>100 cols) | 67 | 75 | 142 |
| Assertion gaps | 6 | 5 | 11 |
| Recursion/unbounded loops | 0 | 2 | 2 |
| Error handling | 2 | 3 | 5 |
| Naming | 2 | 3 | 5 |
| Variable scope/aliasing | 1 | 2 | 3 |
| Comments | 2 | 2 | 4 |
| Types/division | 1 | 0 | 1 |
| Performance | 1 | 2 | 3 |

**Overall impression**: Both files are functionally well-tested and
implement correct behavior, but neither comes close to Tiger Style
compliance: zero runtime assertions across ~2500 lines of production
code is the most critical gap, and `grep.zig`'s unbounded recursive
`searchDirectory` is a latent stack-overflow. The 100-column line
limit is violated pervasively in both files (142 violations combined),
with `printContextLine`'s 240-column signature being the most
egregious single instance.

**Fix priority for the programmer:**

```
Fix Order:
1. [Assertions] Add std.debug.assert throughout both files — start
   with invariants at function entry/exit in doStat, matchLine,
   processFile, and printDefaultFormat.
2. [Recursion] searchDirectory grep.zig:1017 — convert to iterative
   with an explicit depth limit (e.g. max 256 levels).
3. [Error handling] processFile grep.zig:787 — OOM returns false
   (treated as no-match); should propagate error or count as had_error.
4. [Dead code] expandFormatDirective stat.zig:536–541 — both branches
   of the %o platform check are identical; collapse or implement the
   difference.
5. [Variable aliasing] printDefaultFormat stat.zig:756–761 — remove
   the redundant `size` (i64) alias; use a single cast with an assert.
6. [Naming/line-length] printContextLine grep.zig:965 — 11 parameters
   at 240 cols; wrap into an options struct.
7. [Line-length] runStat stat.zig:1120, runGrep grep.zig:1157 —
   add trailing commas to signatures and let zig fmt wrap.
8. [Naming] `n` for readlink/read return values stat.zig:521,741,988
   — rename to `link_len` / `bytes_read`.
9. [Performance] matchLine grep.zig:654 — hoist the dupeZ out of the
   word_regexp while loop.
10. [Types] statx_mask stat.zig:230 — replace the @bitCast magic
    constant with named STATX flag combinations.
```
