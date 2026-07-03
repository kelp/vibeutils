# Tiger Style Review: G7-cp-date-mv

**Files reviewed**: 3 files, ~4730 LOC.

---

## src/cp.zig

### Function-length violations (>70 lines)

- `copySingleFile` (L345–452): 108 lines. The function mixes six distinct
  concerns: symlink-mode resolution, same-file detection, no-clobber check,
  interactive prompt, backup creation, and dispatch. Extract each concern
  into a named helper.

### Line-length violations (>100 cols)

107 violations total. Most are function signatures that lack trailing commas,
so `zig fmt` cannot wrap them. Representative worst offenders:

- L345: 228 cols — `fn copySingleFile(...)` signature.
- L279: 204 cols — `fn executeCopyOperations(...)` signature.
- L175: 173 cols — `parseOrExit` call inside `run`.
- L345, L279, L456, L507, L325, L333, L420 all exceed 150 cols.

Fix: add a trailing comma after the last parameter in every multi-parameter
function signature and let `zig fmt` wrap to 100 cols.

### Assertion gaps

No `std.debug.assert` appears anywhere in the file. The following functions
have meaty logic but zero assertions:

- `copySingleFile` — does not assert `args.len > 0` nor that `is_toplevel`
  is consistent with the call site, nor that the returned `bool` from
  `copySingleFile` is used (it is, but callers cast via `catch false` which
  silently swallows errors).
- `executeCopyOperations` — does not assert `args.len >= 2` at entry (the
  caller already validates, but Tiger Style requires the callee to assert its
  own preconditions).
- `copyRegularFile` — does not assert the paths are non-empty.
- `resolveConflicts` — no assertions on the pointer being non-null (Zig
  catches null deref, but the invariant "config fields start coherent" is
  never stated).
- `copyDirectory` / `copyDirectoryContents` — no assertion that
  `source_path != dest_path`.

### Recursion / unbounded loops

`copyDirectoryContents` (L635) calls `copySingleFile` (L682) which, for
directory entries, calls `copyDirectory` (L447) which calls
`copyDirectoryContents` — a mutual recursion with no explicit depth bound.
Deep directory trees will stack-overflow without warning. Tiger Style
forbids direct recursion; replace with an explicit work-queue loop and a
bounded depth counter.

### Error handling

- L427: `stdout_writer.print(...) catch {}` — silently swallows a write
  error on verbose output. A write failure to stdout is worth surfacing (or
  at minimum asserting unreachable in tests).
- L572: `handleForceOverwrite(io, dest_path) catch {}` inside
  `createHardLink` — if the forced removal fails, the subsequent `hardLink`
  call will likely fail too, but the unlink error is eaten with no comment
  explaining why it is safe to ignore.
- L619: `setPermissions(...) catch {}` — permission-setting failure is
  silently discarded. GNU `cp -p` prints a warning on chmod failure; the
  function already has a `stderr_writer` in scope.
- `copyInPlace` (L517): returns `error.SourceNotReadable` on a copy failure,
  obscuring the original OS error. Callers lose the ability to report the
  true cause.

### Variable scope

- `filtered_args` (L164): initialized with `initCapacity(allocator, 0)`. The
  initial capacity hint of 0 is useless; use `args.len` so no re-allocation
  occurs in the common case.

### Comments

- L462–466 in `copyRegularFile`: the GNU spec comment ("if an existing
  destination file cannot be opened, remove it and try again") is excellent.
  The rest of the file's inline comments describe *what* but not always
  *why* — e.g. L600 "Create destination directory" and L611 "Preserve
  directory permissions when preserve option is set" state the obvious.

### Performance

- `copyDirectory` stats `source_path` twice when both `options.preserve` and
  `options.one_file_system` are true: once at L613 for mode bits, once at
  L627 for `dev`. Consolidate into a single `stat` call.

---

## src/date.zig

### Function-length violations (>70 lines)

- `parseArgs` (L44–223): 180 lines. This is the dominant violation. The
  function handles long-option parsing, short-option parsing, and per-flag
  argument consumption all in one body. The inner `while j < flags.len`
  loop (L124) adds another layer of nesting. Extract long-option handling
  and short-option dispatch into separate helpers.
- `formatDate` (L448–551): 105 lines. The pre-processing loop that replaces
  `%N`, `%s`, `%z`, `%:z`, `%%`, `%n`, `%t` spans ~80 lines of switch
  arms. Extract each custom specifier's formatting logic into a small named
  helper.
- `parseIso8601` (L284–367): 84 lines. Borderline; the nested timezone
  parsing from L322 onward could be a separate `parseTzOffset` helper.

### Line-length violations (>100 cols)

14 violations. Most are in test code (long string literals and call sites).
Production-code offenders:

- L555: 142 cols — `pub fn runDate(...)` signature.
- L487: 115 cols — `std.fmt.bufPrint` call inside `formatDate`.
- L584: 116 cols — `common.printErrorWithProgram` in `runDate`.

### Assertion gaps

Zero `assert` calls in the entire file. Functions with rich preconditions:

- `parseIso8601` — does not assert `ds.len >= 10` at entry after the early
  return (a paired assertion would document the invariant for callers).
- `formatTzOffset` — does not assert `buf.len >= 7` (the minimum needed for
  `±HH:MM\0`); a too-small buffer silently returns `"+00:00"`.
- `formatDate` — does not assert `format.len > 0` or that `epoch_secs` and
  `ns` are plausible (e.g., `ns` should be in `[0, 999_999_999]`).
- `resolveTimestamp` — does not assert the returned `secs` is in a
  reasonable range after parsing.

### Error handling

- `formatDate` (L544–548): when `strftime` returns 0 for a non-empty format,
  the function returns an empty allocated string with no error. Callers
  cannot distinguish "empty format produced empty output" from "strftime
  failed". This silently produces blank date output for pathological inputs.
- `parseArgs` uses `err_msg: ?[]const u8` as an out-of-band error channel
  rather than returning a proper error union. The pattern is intentional
  (date has unusual flag semantics), but the returned struct
  `{ opts, err }` is a two-field tuple that callers must remember to check
  — a naked error union would be safer.

### Naming

- `fi` (L462) and `j` (L124) are abbreviated loop indices. Tiger Style
  permits `i`, `j`, `k` for primitive integer sort/matrix counters, so `j`
  is acceptable. `fi` is non-standard; rename to `fmt_i` or `fi` clarified
  with a comment (it is the format-string index).
- The return type of `parseArgs` is an anonymous struct
  `struct { opts: DateOptions, err: ?[]const u8 }`. Prefer a named struct
  (`ParseResult`) so callers read `result.err` rather than matching an
  implicit field layout.

### Types / division

- `@divTrunc` is used consistently throughout (L244, L270, L278, L436, L437,
  L489, L490) — correct intent is shown.
- `usize` is used for loop indices (`i`, `j`, `fi`) and
  `seconds_end` (L323). These are all stdlib-bound (slice indexing), so they
  are acceptable.

---

## src/mv.zig

### Function-length violations (>70 lines)

- `run` (L806–951): 146 lines. This is the worst violation in the group. The
  function handles arg parsing, last-flag-wins resolution, multi-source
  dispatch, and single-source dispatch in one body. The
  `if (files.len > 2) { ... } else { ... }` branches at L872 and L905
  each duplicate verbose-print logic (four copies of the same
  `stdout_writer.print("'{s}' -> '{s}'\n", ...)` pattern across L901, L919,
  L937, L946). Extract `executeMoveOperations` and a `printVerbose` helper.
- `moveFile` (L670–779): 110 lines. Handles same-file detection, no-clobber
  check, interactive prompt, hint logic, backup, atomic rename, cross-device
  fallback, and EINVAL handling all in sequence. Each concern should be a
  named helper.
- `copyDirectoryRecursive` (L521–609): 89 lines. The directory-entry
  iteration loop handles four entry kinds inline with no helpers.

### Line-length violations (>100 cols)

97 violations total. Again the dominant cause is function signatures without
trailing commas. Most egregious:

- L481: 219 cols — `fn copyFileCross(...)` signature.
- L521: 193 cols — `fn copyDirectoryRecursive(...)` signature.
- L670: 194 cols — `fn moveFile(...)` signature.
- L830: 188 cols — `common.printErrorWithProgram` call.
- L464: 163 cols — `common.printErrorWithProgram` call in `crossFilesystemMove`.

Fix: trailing commas on all multi-param signatures; break long call sites
across lines with `zig fmt`.

### Assertion gaps

Zero `assert` calls in the file. Functions with clear preconditions that go
unasserted:

- `moveFile` — does not assert `source.len > 0` and `dest.len > 0`.
- `copyDirectoryRecursive` — does not assert `source_path != dest_path`,
  which would catch the "move directory into itself" case before the kernel
  returns `EINVAL`.
- `safeRename` — does not assert the paths are non-empty (though the C
  function would fail, the assertion documents the contract).
- `run` — does not assert `files.len >= 2` at the point where it begins the
  multi-vs-single dispatch (it validates earlier, but the assertion in the
  dispatch block would be a paired safety net).

### Recursion / unbounded loops

`copyDirectoryRecursive` (L521) calls itself at L579 for subdirectories.
This is direct recursion with no depth bound. Deep directory trees will
stack-overflow. Tiger Style forbids recursion; replace with an explicit
stack or work-queue with a bounded depth.

### Error handling

- `errdefer` in `crossFilesystemMove` (L439–445):
  `deleteTree(io, dest) catch {}` and `deleteFile(io, dest) catch {}` — the
  cleanup on error silently ignores its own failure. If the rollback fails,
  the destination is left in a partial state with no diagnostic. At minimum,
  log to stderr.
- L760: `std.Io.Dir.cwd().deleteFile(io, dest) catch { ... }` inside
  `moveFile` falls through to `crossFilesystemMove` silently; the comment
  explains the fallback but does not explain why the delete error is
  non-fatal.
- `run` at L895: `moveFile(...) catch { exit_code = .general_error; continue; }`
  — the error is swallowed into a boolean; `moveFile` already prints its
  own error message, so this is fine, but it is worth a comment.

### Naming

- `MvArgs` (L8) — the config struct is named `MvArgs` but the analogous
  struct in `cp.zig` is `CpConfig`. Inconsistent convention; prefer `MvConfig`
  for symmetry across the codebase.
- `hinted_overwrite` / `hinted` — the variable name is descriptive but the
  boolean sense is inverted from what you might expect: `true` means "hint
  already shown, do not show again". A name like `overwrite_hint_shown` is
  clearer.

### Variable scope

- `LastOverwriteFlag` enum (L836) is defined inside `run`. Tiger Style
  prefers the smallest possible scope, and this is correct, but the enum is
  only used for the scan loop immediately below; consider `const` aliasing
  at the point of use to reduce visual distance.
- `last_overwrite_flag` (L837) is declared before the scan loop and read
  after; the scope is already minimal.

### Comments

- L611: `// Rename wrapper that handles EINVAL instead of panicking.` —
  excellent motivating comment with full context. This is model Tiger Style.
- L688–689 (`// Note: On some systems...`) in `copyDirectoryRecursive`:
  describes what is not implemented but not why it is safe to skip.
- L709: `// Skip other file types (block devices, character devices, etc.)`
  — states what but not why skipping is correct (mv does not support
  special files cross-filesystem).

### Performance

- `run` in the single-source case calls `isDestDirectory` (L911), and on
  the "dest is dir" branch immediately calls `std.fs.path.basename` and
  `join`. The stat result from `isDestDirectory` is discarded; it is not
  passed to `moveFile`. This is not a hot path but the repeated OS call
  is avoidable.
- Verbose-output duplication: the four copies of the `stdout_writer.print`
  arrow message (L901, L919, L937, L946) mean any change to the format
  string must be applied in four places.

---

## Summary

| Category | Count |
|---|---|
| Function-length | 8 |
| Line-length | 218 (107 cp + 14 date + 97 mv) |
| Assertion gaps | 3 files, 0 assert calls total |
| Recursion/unbounded loops | 2 (cp mutual recursion, mv direct recursion) |
| Error handling | 7 |
| Naming | 3 |
| Variable scope | 2 |
| Comments | 4 |
| Types/division | 0 |
| Performance | 3 |

**Overall impression**: The three files share two systemic problems — a
complete absence of assertions and pervasive line-length violations driven
by long function signatures without trailing commas — and both the `cp` and
`mv` tree-walking paths use unbounded recursion, which is a Tiger Style hard
violation. The `mv.zig run()` function at 146 lines is the single worst
function-shape violation in the group.

Fix Order:
1. [CRITICAL] Mutual recursion in cp: `copyDirectoryContents` → `copySingleFile` → `copyDirectory` → `copyDirectoryContents` — `src/cp.zig:635`
2. [CRITICAL] Direct recursion in mv: `copyDirectoryRecursive` calls itself — `src/mv.zig:579`
3. [IMPORTANT] Zero assertions across all three files — add precondition asserts to every non-trivial function
4. [IMPORTANT] `run` in mv.zig at 146 lines — `src/mv.zig:806`
5. [IMPORTANT] `parseArgs` in date.zig at 180 lines — `src/date.zig:44`
6. [IMPORTANT] `formatDate` in date.zig at 105 lines — `src/date.zig:448`
7. [IMPORTANT] `copySingleFile` in cp.zig at 108 lines — `src/cp.zig:345`
8. [IMPORTANT] `moveFile` in mv.zig at 110 lines — `src/mv.zig:670`
9. [IMPORTANT] Silent swallow of `handleForceOverwrite` error in `createHardLink` — `src/cp.zig:572`
10. [IMPORTANT] Silent errdefer cleanup in `crossFilesystemMove` — `src/mv.zig:442`
11. [SUGGESTION] Add trailing commas to all multi-param function signatures (218 line-length violations resolve automatically with `zig fmt`)
12. [SUGGESTION] Consolidate double `stat` in `copyDirectory` — `src/cp.zig:613,627`
13. [SUGGESTION] Rename `MvArgs` to `MvConfig` for consistency with `CpConfig` — `src/mv.zig:8`
14. [SUGGESTION] `initCapacity(allocator, 0)` → `initCapacity(allocator, args.len)` — `src/cp.zig:164`
