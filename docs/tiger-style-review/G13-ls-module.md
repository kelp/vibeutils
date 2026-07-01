# Tiger Style Review: G13-ls-module

**Files reviewed**: 11 files in `src/ls/`, ~5233 LOC.

---

## src/ls/core.zig

### Line-length >100

Every public function signature in this file is a single-line declaration,
each exceeding 100 columns by a large margin:

- `src/ls/core.zig:15` — `listDirectoryImplWithVisited` signature: 289 columns.
- `src/ls/core.zig:32` — `collectAndPrepareEntries` signature: 191 columns.
- `src/ls/core.zig:65` — `printDirectoryListing` signature: 155 columns.
- `src/ls/core.zig:76` — `processRecursiveDirectories` signature: 304 columns.
- `src/ls/core.zig:17`, `28`, `40`, `78` — call sites that also exceed 100 columns.

All of these should use trailing commas on parameters so `zig fmt` wraps them.
The signatures are especially long because they thread `io`, `allocator`,
`writer`, `stderr_writer`, `options`, `style`, `visited_fs_ids`, and
`git_context` together every time. See the coupling note below.

### Assertion gaps

Zero assertions across all six functions. The public surface accepts
`anytype` writer arguments, `anyerror!void` return types, and nullable
`git_context` — none of this is guarded. Tiger Style requires a minimum of
two assertions per function on average. The module has zero.

### Naming

All four helper functions are `pub` but only called from within `core.zig`
itself (`collectAndPrepareEntries`, `sortEntriesFromOptions`,
`printDirectoryListing`, `processRecursiveDirectories`). They should be
`fn` (private).

### Comments

Comments restate the code (`// Collect and prepare entries`, `// Sort
entries based on options`, `// Print directory listing`). Tiger Style
requires comments to say *why*, not *what*. The code already says what.

### Other observations

**Cross-file coupling / parameter explosion.** `listDirectoryImplWithVisited`
takes 11 parameters. The same 11-parameter signature recurs in
`processRecursiveDirectories` (11 params), `recursive.zig`
`recurseIntoSubdirectory` (10 params), and
`entry_collector.processSubdirectoriesRecursively` (11 params). This is the
dominant architectural issue in the module: the absence of a context struct
forces every caller to pass the entire context by position. A
`ListContext` struct holding `io`, `allocator`, `options`, `style`,
`visited_fs_ids`, and `git_context` would collapse these to two or three
parameters and eliminate the 300-column signatures.

---

## src/ls/display.zig

### Function-length >70

`printEntryName` (`src/ls/display.zig:208`): 73 lines. Handles git status
coloring, icon printing, color setting, name sanitization/escaping, and
file type indicators in a single function. Extracting the git-status block
and the icon block into private helpers would each come in under 70 lines.

### Line-length >100

- `src/ls/display.zig:10` — `initStyle` signature: 125 columns.
- `src/ls/display.zig:232` — `getIcon` call: 134 columns.

### Assertion gaps

Zero assertions. `initStyle` modifies `style.color_mode` based on three
different conditions with no precondition check; `printEntryName` uses
`entry.name` without asserting it is non-empty.

### Error handling

`src/ls/display.zig:150` — `if (out + 4 > buf.len) break;` inside
`escapeName` silently truncates the output. The caller cannot distinguish
a truncated result from a complete one. The function signature returns
`[]const u8` with no error path; this should either return an error or the
buffer contract should be documented with an assertion that `buf` is always
large enough (the caller at line 254 uses `max_path_bytes * 4`, which is
correct, but there is no assertion to prove it).

### Naming

`getColorForKind` and `getFileColor` do the same thing via two different
call paths: both switch on `std.Io.File.Kind` and return a `Color`.
`getFileColor` additionally checks executable bit on `file` kind.
`getColorForKind` exists only because `formatter.zig` needs to color symlink
targets without a full `Entry`. The name difference obscures the
relationship; a comment explaining why two functions exist would clarify.

`gc` at `src/ls/display.zig:215` abbreviates `git_status_color_info`. Tiger
Style prohibits abbreviations outside of primitive-integer loop indices.

### Variable scope

`src/ls/display.zig:254` — `var name_buf: [std.Io.Dir.max_path_bytes * 4]u8`
is stack-allocated inside an `if` branch, which is correct. However the
same name `name_buf` is also declared in the `else if` branch at line 258 as
a smaller buffer. These are separate scopes so there is no actual aliasing,
but the identical name makes diffs and code reading unnecessarily confusing.

### Types/division

`sanitizeName` and `escapeName` accept and return `[]const u8` but their
natural type for the length calculation is `usize`, which is
architecture-dependent. For a buffer-index counter that is always
bounded by `max_path_bytes`, this is stdlib-bound and acceptable, but
`blockCountWidth` in `formatter.zig` returns `usize` where `u16` or `u32`
would suffice — see that file's entry.

---

## src/ls/entry_collector.zig

### Function-length >70

`collectFilteredEntries` (`src/ls/entry_collector.zig:10`): 71 lines body.
Just over the limit. The `if (options.all and !options.almost_all)` block
that manually prepends `.` and `..` (lines 38–52) could be a private helper.

### Line-length >100

Multiple lines exceed 100 columns in both production code and tests:

- Line 96 — `readSymlinkSafely` signature: 130 columns.
- Line 103 — error print call: 134 columns.
- Lines 159, 165, 173, 180, 223, 230, 235, 241 — various calls.
- Test lines 335, 369, 396 — `collectFilteredEntries` calls in tests.

### Assertion gaps

Zero assertions. `enhanceEntriesWithMetadata` takes a nullable
`git_context` but the `needs_git` computation re-checks `git_context !=
null` at line 178 after already computing it correctly at line 134. An
assertion `std.debug.assert(needs_git == (options.show_git_status and
git_context != null))` at that point would catch divergence.

### Performance

`enhanceEntriesWithMetadata` builds three index lists (`stat_indices`,
`symlink_indices`, `git_indices`) via a grouping loop, then immediately
iterates each list in a second pass. Because `needs_stat` applies to all
entries when true, `stat_indices` always contains every index — it is
equivalent to a plain `for (entries, 0..) |_, i|` loop. The two-pass
grouping adds arena allocation and two loop iterations for no benefit over a
single combined loop. This looks like premature "batching" abstraction that
adds complexity without amortizing any real cost (all three operations hit
the same syscall boundary serially anyway).

### Other observations

**Duplicated metadata predicate.** `needsMetadata` (line 89) and the
`needs_stat` computation inside `enhanceEntriesWithMetadata` (lines 130–132)
express overlapping but slightly different conditions. `needsMetadata`
includes `show_git_status`; `needs_stat` does not (git status uses a
separate `needs_git` variable). If either predicate drifts, the caller
(`core.zig:39`) may skip `enhanceEntriesWithMetadata` when it is needed, or
enter it to do nothing. A single source of truth (e.g., a `MetadataNeeds`
struct computed once) would eliminate the divergence risk.

---

## src/ls/formatter.zig

### Function-length >70

- `formatTimeWithStyle` (`src/ls/formatter.zig:213`): 106 lines. Each of
  the five `TimeStyle` arms is a complete formatting sub-routine. Extracting
  each arm into a private `formatDefault`, `formatRelative`, `formatIso`,
  `formatLongIso`, `formatFull` function would bring each well under 70
  lines and make the dispatch table obvious.

- `printLongFormatEntryAligned` (`src/ls/formatter.zig:327`): 98 lines.
  Handles blocks, permissions, nlinks, owner/group, size, date, name, and
  symlink target in sequence. Each section could be a private helper; the
  function would become a sequenced call list under 20 lines.

- `printEntries` (`src/ls/formatter.zig:619`): 74 lines. The five format
  dispatch branches (one-per-line, long, comma, across, default) could each
  be extracted.

### Line-length >100

Pervasive. Notable worst offenders in production code:

- Lines 489, 528, 578, 609 — `getDisplayWidth(...)` calls: 196–211 columns.
  The four boolean arguments are passed explicitly every time; an options
  struct would shrink these to one argument and eliminate the overlong lines
  entirely (see naming section below).
- Line 116 — `writeUserGroupColored` signature: 148 columns.
- Lines 218, 264, 281, 299 — repeated `EpochSeconds{ .secs = std.math.cast(...) }`:
  138 columns each.

### Assertion gaps

Zero assertions. Division operations in `calculateDisplayBlocks` and
`calculateBlocks` assume `BLOCK_SIZE > 0` with no assertion. `blockCountWidth`
assumes `blocks` can fit in a `usize` loop counter with no assertion.
`formatWithThousands` silently returns `num_str` (the unformatted value)
when `total_len > buf.len` at line 442 — the caller cannot tell the
difference.

### Types/division

**Bare `/` throughout column math.** Tiger Style requires showing intent for
all division:

- `src/ls/formatter.zig:440` — `(num_str.len - 1) / 3` — should be
  `@divTrunc` or `@divFloor` (the result is truncated; intent is floor).
- `src/ls/formatter.zig:497`, `586` — `term_width / col_width` — column
  count is naturally floor division; use `@divFloor`.
- `src/ls/formatter.zig:500` — `(entries.len + num_cols - 1) / num_cols` —
  ceiling division; a named `div_ceil` call would make intent explicit.
- `src/ls/formatter.zig:542`, `553` — `(size + BLOCK_ROUNDING) / BLOCK_SIZE`
  — this is a ceiling-division idiom; `@divFloor` with the rounding addend
  should be `@divFloor`, not bare `/`.
- `src/ls/formatter.zig:551` — `(stat.size + 1023) / 1024` — same pattern.

`blockCountWidth` returns `usize` where `u8` would suffice (a block count
can never have more than ~20 decimal digits on any real system). The
function is only used as a width for right-alignment; `u8` expresses the
intent.

### Variable scope

`src/ls/formatter.zig:655` — `var one_opts = options;` is a mutable alias
of the immutable `options` parameter, created solely to flip two booleans.
Tiger Style prohibits aliases. This should be `const one_opts: LsOptions =
.{ ...options fields..., .icon_mode = .never, .show_git_status = false }`.

### Naming

`getDisplayWidth` takes four positional `bool` arguments:
`(file_type_indicators, append_slash_dirs, show_icons, show_git_status)`.
These are easy to confuse at the call site. Tiger Style requires an
`options: struct {}` argument when args could be mixed up. A
`DisplayWidthOptions` struct with those four fields would eliminate the
196-column call lines and the confusion risk.

`blockCountWidth` abbreviates the concept: the function computes the number
of decimal digits in a block count, which is really `digitCount`. The
current name reads as "the width of a block count" (a column layout
concept) rather than "how many digits does this number have."

### Performance

`printColumnar` and `printColumnarAcross` share roughly 30 lines of
identical setup code (terminal width, block prefix width calculation,
max-width pre-pass). A shared `computeColumnarLayout` helper returning a
small struct (`col_width`, `num_cols`, `block_prefix_width`) would
deduplicate this and make both functions easier to read.

---

## src/ls/integration_test.zig

Clean file overall. Tests are well-named and cover behavioral flags, not
just parsing.

### Line-length >100

- Line 130 — inline array literal: 102 columns.
- Lines 841, 859 — `expectOnePerLineOrder` calls: 104 and 102 columns.
- Lines 1062, 1065 — `debug.print` calls in test assertions: 112 and 115
  columns.

### Other observations

The recursive-header test at line 316 (`"recursive: shows directory headers
with proper formatting"`) uses `expectDirectoryHeader` which does a
substring `find`. It would not catch doubled headers. See the bug described
under `src/ls/entry_collector.zig` — the test passes even if each subdir
header appears twice in the output.

---

## src/ls/main.zig

### Function-length >70

`lsMain` (`src/ls/main.zig:160`): 185 lines — the single largest function
in the module. It handles help, version, icons, test-icons, color mode
resolution, git mode resolution, time style parsing, options struct
construction, git context initialization, path dispatch, and multi-path
GNU-style separation. Tiger Style hard-caps at 70 lines with no exceptions.

Extracting the options construction (lines 235–278) into
`buildLsOptions(args, color_mode, icon_mode, time_style)` and the
multi-path dispatch (lines 302–342) into a private helper would each remove
30–50 lines.

### Line-length >100

Minor; mostly long string literals in the help text (acceptable for
documentation strings).

### Assertion gaps

Zero assertions. `lsMain` accumulates state across many branches; no
invariants are asserted at any transition point. At minimum, the
`git_context` initialization result could be asserted to match
`options.show_git_status`.

### Recursion/unbounded loops

`isInGitRepo` (`src/ls/main.zig:564`) uses `while (true)` without an
explicit iteration bound. The loop terminates only when `path == parent`
(filesystem root) or on an open/stat error. On a deep filesystem tree this
could iterate hundreds of times; on a malformed path (circular symlink in
directory hierarchy) it could loop indefinitely. Tiger Style requires every
loop to have an explicit upper bound. A `var depth: u16 = 0` counter with
`if (depth > 64) return false; depth += 1;` would bound it.

The comment at `src/ls/main.zig:563` says "by walking up looking for a
.git directory or file" — this is *what*, not *why*. The why is: git
repositories can be rooted anywhere in the path, so we must walk upward
rather than just checking `.`.

### Performance

**Triple stat per path for multiple operands** (`src/ls/main.zig:303–342`).
When `paths.len > 1`, each path is `stat`-ed up to three times: once in the
initial count loop (line 309), once in the first-pass file loop (line 317),
and once in the second-pass directory loop (line 329). The results should be
cached (e.g., `const kinds = try classifyPaths(io, paths, allocator)`)
and reused across all three passes.

### Variable scope

`file_count` at line 306 is computed in a separate counting loop and then
only used to decide whether to print a blank line separator. The same
information could be derived from `dir_idx` and whether any file-type
entries were seen in the first pass, eliminating the pre-count loop.

---

## src/ls/recursive.zig

Clean — 31 lines, one function, well within limits. The `catch |err| switch`
pattern correctly distinguishes `BrokenPipe` from other errors.

### Line-length >100

None.

### Assertion gaps

`recurseIntoSubdirectory` is thin by design; the single assertion gap is
that `subdir_path` being non-empty is never checked. Low priority given the
controlled call site.

### Other observations

The `@import("core.zig")` inside the function body at line 23 breaks the
circular dependency between `core.zig` and `recursive.zig`. The comment
explains *what* ("avoid circular dependency") but not *why the circularity
exists* — a one-line comment on the design decision ("core calls
entry_collector which calls recursive which must call back into core;
forward import breaks the cycle") would help future readers.

---

## src/ls/security_test.zig

Clean file. Tests cover `FileSystemId` equality, `CycleDetector`, and
error handling for the symlink metadata path.

### Assertion gaps

The performance test at line 131 asserts `duration_ms < 100.0` using a
`try testing.expect` — this is a timing assertion on CI, which is fragile.
The 100ms threshold is noted as "for reliability in containers/CI" but there
is no assertion explaining *why* the operation must be fast (i.e., what
the operational budget is). This is a comment quality issue, not a logic bug.

### Other observations

`fs_id.device` is accessed at line 90 with a comment "verify we can access
it without error" but the value is never checked. This tests compilation
more than runtime behavior. An assertion `try testing.expect(fs_id.device
!= 0)` (parallel to the inode check at line 93) would complete the
behavioral test.

---

## src/ls/sorter.zig

Clean overall. The `versionCompare` algorithm is readable and correctly
bounded.

### Assertion gaps

`compareEntries` has no assertions. The function should assert that the
`config` struct is self-consistent — for example, `use_ctime` and `use_atime`
can both be true (the ctime-takes-precedence behavior is tested but not
asserted within the comparator itself). `sortEntries` has no precondition
assertion on `entries.len`.

### Naming

`a_start`, `b_start`, `a_num_start`, `b_num_start`, `a_num_len`,
`b_num_len` in `versionCompare` are acceptable as they are parallel
primitive-integer loop indices in a sort context. `ai` and `bi` are also
acceptable (`i` suffix with a prefix character is a common sort-index idiom).

### Types/division

`getExtension` uses `usize` for the loop counter `i` (stdlib-bound on
`name.len`): acceptable.

---

## src/ls/test_utils.zig

### Assertion gaps

`listDirectoryTest` is a 62-line function that replicates `core.zig` logic
manually — sort config construction, metadata enhancement, recursion. It has
drifted from the production path: it does not call `core.zig` at all. If
`core.zig` changes, `listDirectoryTest` will silently diverge. This is a
maintenance risk, not a Tiger Style assertion gap per se, but a `comptime`
check that `listDirectoryTest` produces output equivalent to the production
path for a known input would catch drift.

### Variable scope

`var test_options = options;` at line 34 is a mutable alias of the
parameter — same pattern as `var one_opts` in `formatter.zig`. Tiger Style
prohibits aliases. Use `const test_options: LsOptions = .{ ...options...,
.color_mode = if (options.color_mode == .auto) .never else options.color_mode }`.

### Other observations

`createFileWithSize` (`src/ls/test_utils.zig:186`) allocates a
`size`-byte buffer, fills it with a single character, then writes it. For
test use this is fine, but `size` is `usize` (architecture-dependent). A
`u32` would be sufficient and more explicit.

---

## src/ls/types.zig

### Assertion gaps

`getDisplayWidth` (`src/ls/types.zig:110`) caches its result in
`self.display_width`. After caching, there is no assertion that
`self.display_width` equals the freshly computed value. A debug-mode
assertion `std.debug.assert(width == self.display_width.?)` after the cache
write would catch bugs where `calculateDisplayWidth` is called with
different arguments on successive calls to the same entry.

`calculateDisplayWidth` (`src/ls/types.zig:77`) takes four positional bools —
the same concern as `getDisplayWidth` in formatter context: these are easy
to pass in the wrong order.

### Naming

`display_width: ?usize` and `file_type_indicator: ?u8` on `Entry` (lines 73–74)
are documented as "Cached display width for performance" and "Cached file
type indicator for performance". The cache invalidation function
`resetCache` exists but is never called anywhere in the module. Either the
cache invalidation path is dead code or there is a missing call site. A
comment on the field noting *when* the cache becomes stale would clarify
the contract.

### Types/division

`display_width: ?usize` — a display width is bounded by the maximum
terminal width (≤ 32767 for any real terminal). `u16` would express the
bound explicitly. Same for `calculateDisplayWidth` return type.

---

## Summary

| Category | Count |
|---|---|
| Function-length >70 | 6 |
| Line-length >100 | ~55 (pervasive in formatter.zig and core.zig) |
| Assertion gaps | 11 files × 0 assertions = zero assertions module-wide |
| Recursion/unbounded loops | 1 (`isInGitRepo` `while (true)`) |
| Error handling | 1 (silent truncation in `escapeName`) |
| Naming | 4 (abbreviation `gc`, four-bool API `getDisplayWidth`, `blockCountWidth`, variable aliases) |
| Variable scope | 2 mutable aliases (`one_opts`, `test_options`) |
| Comments | Pervasive in `core.zig`; explain what not why |
| Types/division | 6 bare `/` in column/block math; 3 `usize` where smaller type fits |
| Performance | 3 (triple-stat in `lsMain`, fake batching in `enhanceEntriesWithMetadata`, duplicated columnar setup) |

**Overall impression**: The module is functionally well-structured and
behaviorally tested, but it violates Tiger Style on the two rules that matter
most — zero assertions across ~5000 lines of production and test code, and
six functions that exceed the 70-line hard limit, with `lsMain` at 185 lines
being the most egregious. The pervasive 11-parameter signatures are the
root cause of the 100-column violations and are the highest-leverage
structural fix. There is also a likely correctness bug: subdir headers are
printed by both `entry_collector.processSubdirectoriesRecursively` and
`core.printDirectoryListing` for the same directory, producing doubled
output in recursive mode.
