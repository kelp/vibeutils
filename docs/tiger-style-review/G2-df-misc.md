# Tiger Style Review: G2-df-misc

**Files reviewed**: 6 files, ~4680 LOC.

---

## src/df.zig

### Function-length violations (>70 lines)

- `parseArgs` (lines 131–349): ~218 lines. This is the dominant offender. Split
  into `parseShortOptions`, `parseLongOptions`, and `parseArgs` (dispatcher
  only). The long-option chain (lines 163–238) alone is a candidate helper.
- `printTotal` (lines 1500–1635): ~135 lines. Duplicates the three-column
  format-and-sum pattern from `printTotalDynamic`. Extract
  `sumFilesystemBytes` and a shared `formatTotalStrings` helper; the two
  render functions shrink to ~50 lines each.
- `runDf` (lines 1921–2054): ~133 lines. The ownership/defer block (lines
  1963–1977) and the two rendering branches (lines 2022–2053) should each be
  their own function.
- `printFsRowDynamic` (lines 1693–1803): ~110 lines. The plain-color branch
  and the full-color branch are structurally identical except for icon and
  color calls; split into `printFsRowPlain` and `printFsRowColored`.
- `printTotalDynamic` (lines 1805–1915): ~110 lines. Same problem as
  `printFsRowDynamic`; shares the `sumFilesystemBytes` opportunity above.
- `printFsRow` (lines 1404–1498): ~94 lines. Used only for the `--inodes`
  path; extract `printInodeRow` and `printBlockRow` sub-functions.
- `printHeader` (lines 1315–1402): ~87 lines. Four nearly-identical
  `stdout.print` calls differing only in the presence of the Type and Usage
  columns. A `printHeaderLine(opts, size_label, pct_label, widths?)` helper
  collapses to ~30 lines.
- `getFilesystemForPathLinux` (lines 530–599): ~69 lines. Borderline; the
  `/proc/mounts` fallback (lines 551–566) and the mount-prefix scan (lines
  568–584) are extractable helpers.

### Line-length violations (>100 cols)

24 violations total. Worst 10:

- L1849 (143 cols): `const percent: u8 = if (sum_use_total == 0) 0 else
  @intCast(@min(@divTrunc(...), 100));` — break into a named `calcPercent`
  helper or split the conditional onto separate lines.
- L1080 (136 cols): `var total: usize = widths.filesystem + 2 + widths.size
  + 2 + ...;` — break after each `+`.
- L1983 (134 cols): `common.printErrorWithProgram(...)` — wrap the format
  string literal to a separate line.
- L1921 (134 cols): `pub fn runDf(...)` signature — add trailing comma and
  let `zig fmt` wrap.
- L1805 (132 cols): `fn printTotalDynamic(...)` signature — same fix.
- L1995 (121 cols): `common.printErrorWithProgram(...)` — wrap format string.
- L89 (120 cols): `display: common.display_config.DisplayConfig = .{...}` in
  `DfOptions` struct — split the initializer across lines.
- L707 (119 cols): inline ASCII-tolower in `containsCaseInsensitive` — extract
  `toLower(c: u8) u8` and call it.
- L3118/L3114 (test lines, 158/115 cols): long string literals in tests —
  acceptable in tests but could use multiline string syntax.
- L131 (107 cols): `fn parseArgs(...)` return type on same line — add trailing
  comma.

### Assertion gaps

Zero `std.debug.assert` calls exist anywhere in `df.zig`. Tiger Style requires
a minimum of two assertions per function on average. The entire file — 3588
lines, ~20 non-trivial production functions — has none. Key gaps:

- `formatUsageBar` (L888): no assertion that `percent <= 100` on entry, and no
  assertion that `filled + empty == bar_width` before writing.
- `calcUsagePercent` (L875): no assertion that the result fits in `u8` before
  `@intCast`.
- `capWidthsToTerminal` (L1070): no assertion that `term_width > 0`.
- `truncatePath` (L965): no assertion that `buf.len >= max_width`.
- `formatWithCommas` (L812): no assertion that `out_len <= buf.len` before
  writing (currently returns `"?"` on overflow — a silent degradation rather
  than a caught invariant violation).
- `groupDarwinVolumes` (L757): no post-condition assertion that
  `result.items.len <= filesystems.len`.
- `getMountedFilesystemsDarwin` (L370): `actual` could theoretically exceed
  `ucount` (race condition between two `getfsstat` calls). No assertion that
  `actual_count <= ucount`.

### Error handling

- `visible.append(allocator, fs) catch {}` at L1988 and L2013: silently drops
  a filesystem entry if allocation fails. No comment explaining why loss is
  acceptable here. A best-effort `catch {}` in output loops is understandable
  but must carry a justification comment.
- `printFsRow(...) catch {}` (L2026), `printTotal(...) catch {}` (L2029),
  `printFsRowDynamic(...) catch {}` (L2047), `printTotalDynamic(...) catch {}`
  (L2050): all silently swallow I/O errors during output. A write failure on
  a pipe-closed stdout is plausible in production. Each needs a comment like
  `// Output errors are non-fatal; we continue to show remaining filesystems.`
- `printHelp(...) catch {}` (L1932) and `printVersion(...) catch {}` (L1937):
  if the writer fails here the process returns exit code 0 silently. Logging
  to stderr or returning an error exit code would be more correct.
- **Memory leak in `getMountedFilesystemsLinux`** (L508–510): if
  `allocator.dupe(source_raw)` succeeds but `allocator.dupe(mount_point_raw)`
  fails, `source` is leaked. If both succeed and `allocator.dupe(fstype_raw)`
  fails, both are leaked. There is no `errdefer` for the partially-constructed
  `FsInfo`. Fix: introduce intermediate `errdefer allocator.free(source);`
  etc., or construct the `FsInfo` atomically via a helper that returns the
  full struct only on full success.
- **Same leak pattern in `getFilesystemForPathLinux`** (L587–589) and
  `getFilesystemForPathDarwin` (L441–443): sequential `try allocator.dupe`
  calls without intermediate `errdefer` means the first allocation leaks if a
  later one fails.

### Naming

- `src`, `mnt`, `fst` (L573–575) in `getFilesystemForPathLinux`: abbreviated
  names. Rename to `source_str`, `mount_str`, `fstype_str`.
- `s` and `S` (L1459–1460, L1599–1600, L1951–1952): single-letter names for
  the style struct and its type alias. `style` and `StyleT` (or just inline
  the struct construction) would be clearer.
- `pct` (L877, L883, L1407, L1511, L1576, L1846): acceptable as a local
  intermediate but used inconsistently — sometimes it is a `u8` percentage
  value, sometimes a formatted string. The two roles sharing a name is
  confusing. Prefer `pct_value` for the numeric and keep `pct_str` for the
  formatted form (already done in several places).
- `ucount` / `actual_count` (L376, L384): `ucount` is an unnecessary rename of
  `count` cast to `usize`; prefer `count_usize` to make the cast purpose
  explicit, or just inline the cast.

### Variable scope

- `color_mode_int` (L1945) is computed and then immediately used to construct
  `s` (L1952). The `u8` encoding of an enum is an artifact that leaks through
  the entire `runDf` body and into every call that takes `color_mode_int`.
  Prefer passing the `ColorMode` enum directly. The indirection through an
  integer exists only because `printFsRow` and `printTotal` (the old fixed-
  width path) accept `color_mode_int: u8` — this is a sign that the old path's
  interface was never updated.
- `owns_fs_strings` (L1961) is a boolean flag controlling cleanup in a deferred
  block. This pattern is fragile; a second path that sets `owns_fs_strings =
  true` but then returns early could double-free. Prefer two separate cleanup
  functions that are conditionally deferred, or restructure the ownership so
  both paths use the same `freeFsInfoSlice` cleanup.

### Comments

- `getMountedFilesystemsDarwin` (L371): `// First call to get count` describes
  the *what*, not the *why*. Why is a two-call pattern needed? (Answer:
  `getfsstat` with a null buffer returns the count; without this comment
  explaining the double-call idiom the intent is unclear.)
- `getFilesystemForPathLinux` (L544): `// matching the longest mount point
  prefix of the path.` — starts lowercase, not a sentence.
- Inline comments on L497 (`// statvfs the mount point`), L506 (`// skip mount
  points we can't stat`), L744 (`// skip "disk"`), L969 (`// room for "..."`)
  all start lowercase. Tiger Style requires comments to be sentences.
- The `// Dupe strings so they outlive the getfsstat buffer` comment (L388,
  L439) correctly says *why*; this is a good pattern to follow throughout.

### Types / division

- `ColumnWidths` fields (L1040–1047): all declared as `usize`. These represent
  terminal column widths, which are bounded by `u16` (65535 columns). Using
  `u16` would make the intent explicit and avoid architecture-dependent
  behaviour; `usize` is only needed because `padRight`/`padLeft` pass them
  to slice indexing, which is stdlib-bound. This is a borderline case — flag
  and leave the decision to the programmer.
- `term_width` (L1077): declared as `usize` after casting from a terminal
  width. Same observation.
- Loop counters `i`, `j` in `formatWithCommas` (L828–830) and
  `containsCaseInsensitive` (L703): `usize` is appropriate here since they
  index into slices.
- Float division in `usageGradientRgb` (L1136, L1143, L1150): `/ 70.0` and
  `/ 15.0` are intentional interpolation — acceptable for `f32`.
- Integer ceiling division (L865, L877, L1548, etc.) correctly uses
  `@divTrunc(x + divisor - 1, divisor)` rather than bare `/` — good practice.

### Performance

- `isPseudoFs` (L636) and `isNetworkFs` (L650) perform linear string
  comparisons over small fixed arrays on every filesystem row. These are called
  from `shouldIncludeFs` which itself is called in a loop. For a small number
  of entries (~20 pseudo types, ~8 network types) this is fine, but the arrays
  could be sorted and searched with `std.mem.binarySearch` for correctness
  at scale.
- `computeColumnWidths` (L1050) formats each size value *twice*: once here and
  once in `printFsRowDynamic`. The formatted strings are discarded. Caching the
  formatted widths (or computing column widths from byte estimates without
  actually formatting) would eliminate the redundant work.

### Other observations

- **Parallel rendering paths**: `printHeader`/`printFsRow`/`printTotal` (the
  old fixed-width path, used only for `--inodes`) and
  `printHeaderDynamic`/`printFsRowDynamic`/`printTotalDynamic` (the new
  dynamic path) duplicate the option-branching logic. The inodes path could
  be migrated to the dynamic renderer to eliminate the old functions entirely.
- `DfOptions.suppress_inodes` (L105) is parsed but never consulted during
  output. If it is intentionally unimplemented, a `// TODO` comment is
  needed; otherwise it is a silent no-op.

---

## src/dirname.zig

### Line-length violations (>100 cols)

11 violations, all in function signatures and `printErrorWithProgram` calls:

- L31 (145 cols): `pub fn runDirname(...)` signature — add trailing comma and
  let `zig fmt` wrap.
- L36, L40, L44 (110–123 cols): `printErrorWithProgram(...)` calls in the
  error-handling block — wrap the format-string argument.
- L226, L239, L252, L264, L277, L290, L304 (101–103 cols): test lines with
  long `runDirname(...)` call; acceptable in tests but wrapping would help
  readability.

### Assertion gaps

`extractDirname` has meaningful invariants that go unasserted:

- No assertion that the returned slice is a sub-slice of `path` (or one of the
  two string literals `"."` / `"/"`).
- No assertion that `dirname_end <= end` before the final slice (L112).
- `runDirname` has no assertion that `parsed_args.positionals.len > 0` by the
  time the `for` loop runs (there is an early return at L62–65, but an
  assertion at loop entry would pair it).

### Comments

- `fn printHelp` (L117): doc comment says `// Print help message` — the *why*
  is absent. Trivial wrapper functions do not need rich why-comments, but the
  comment should at least be a sentence: `// Print help message to writer.`

---

## src/whoami.zig

### Line-length violations (>100 cols)

12 violations:

- L36 (166 cols): `const parsed_args = common.argparse.ArgParser.parseOrExit(...)
  catch return ...;` — this is the worst line in the file. Break into a
  `const parse_result = ... catch ...` on one line, then extract the
  exit value separately, or split the long argument list with a trailing comma.
- L53 (127 cols): `common.printErrorWithProgram(...)` — wrap format string.
- L60 (117 cols): `common.user_group.getUserById(...) catch {...}` — break the
  catch body to a new line.
- L103, L125, L138, L152, L166, L180, L197, L211, L225 (101–102 cols): test
  lines — acceptable but borderline.

### Assertion gaps

`runWhoami` has no assertions. At minimum:

- Assert that `user_info.name.len > 0` after a successful `getUserById` call
  before printing (otherwise an empty username is printed silently).

---

## src/true.zig

### Line-length violations (>100 cols)

- L49 (104 cols): test call `runTrue(testing.allocator, io, args, common.null_writer,
  common.null_writer)` — wrap arguments.
- L68 (118 cols): same pattern in the second test.

### Other observations

- `runTrue` discards all five parameters with `_ = ...`. This is correct per
  POSIX, but a brief comment explaining *why* all arguments are ignored would
  help future maintainers: `// POSIX.1-2017 requires true to always succeed and
  ignore all arguments.`

---

## src/false.zig

### Line-length violations (>100 cols)

- L12 (151 cols): `pub fn runFalse(...)` signature — worst offender; add
  trailing comma and let `zig fmt` wrap (same pattern as `runTrue` which is
  correctly multi-line).
- L49 (103 cols): test call — wrap arguments.
- L75 (123 cols): test call — wrap arguments.

### Other observations

- `runFalse` has the same "discard all args" pattern as `runTrue` without the
  module-level doc comment explaining the POSIX rationale. The file-level
  `//!` comment does mention it, which partially mitigates the concern.

---

## src/pwd.zig

### Line-length violations (>100 cols)

- L67 (143 cols): `common.printErrorWithProgram(allocator, stderr_writer, "pwd",
  "failed to get current directory: {s}", .{common.posixErrorString(err)});`
  — wrap the format string.
- L44 (114 cols): `printErrorWithProgram(...)` in the `MissingValue` arm —
  wrap.
- L48 (107 cols): same for `InvalidValue` arm.
- L40 (106 cols): same for `UnknownFlag` arm.
- L24 (103 cols): `logical` field `meta` line — borderline; wrap `desc` string.

### Assertion gaps

- `getCwdAlloc` (L104): no assertion that `n > 0` or that `n <=
  std.Io.Dir.max_path_bytes` after `currentPath` succeeds.
- `isValidPwd` (L146): `physical_cwd` is expected to be an absolute path (the
  caller gets it from `getCwdAlloc`), but there is no assertion on entry.
  Adding `std.debug.assert(physical_cwd.len > 0 and physical_cwd[0] == '/');`
  would document the precondition.
- `getWorkingDirectory` (L112): no assertion that the returned slice starts
  with `'/'` (post-condition).

### Error handling

- `getWorkingDirectory` (L124–127): `getCwdAlloc(...) catch { return
  allocator.dupe(u8, pwd_env); }` silently falls back to an unvalidated
  `PWD` when `currentPath` fails. The comment says "rare edge case" but does
  not note the security implication: an unvalidated `PWD` from the environment
  could point anywhere. The "fails closed" comment on `isValidPwd` (L143–145)
  is correct but this catch block bypasses it entirely.

### Comments

- `isValidPwd` (L146): checks only inode equality, not device number. Two
  files on different devices can share the same inode number. Comparing both
  `inode` and the device identifier (if available from `Stat`) would be safer.
  The current behavior is documented nowhere; add a comment explaining why
  inode-only comparison is considered sufficient.

---

## Summary

| Category | Count |
|---|---|
| Function-length (>70 lines) | 8 |
| Line-length (>100 cols) | 55 (24 in df.zig; 11 dirname; 12 whoami; 2 true; 3 false; 5 pwd) |
| Assertion gaps | 18 |
| Error handling | 8 |
| Naming | 6 |
| Variable scope / aliasing | 2 |
| Comments | 8 |
| Types / division | 2 (borderline `usize` in ColumnWidths) |
| Performance | 2 |
| Memory leaks | 3 |

**Overall impression**: `df.zig` dominates the findings — it is a 3500-line
file with zero assertions, seven functions exceeding the 70-line limit, and
several silent error-discard sites that lack justification comments. The
smaller utilities (`true`, `false`, `whoami`, `pwd`, `dirname`) are
structurally clean but share a consistent line-length problem stemming from
long function signatures and `printErrorWithProgram` call sites, and none of
them use assertions. The three memory-leak patterns in `df.zig`'s platform
filesystem enumeration functions are the most actionable correctness issues.
