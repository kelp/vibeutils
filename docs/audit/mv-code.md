# mv Code Audit

**Date:** 2026-03-28
**File:** `src/mv.zig`
**Build:** passes (`just build-util mv`)
**Unit tests:** all pass
**Integration tests:** 94/95 pass, 1 skipped

---

## Flag Verdict Table

| Flag | Tier | Status | Verdict |
|------|------|--------|---------|
| `-f` | MUST | parsed + applied | BROKEN (see issue 2) |
| `-i` | MUST | parsed, check in dead branch | BROKEN (see issue 1) |
| `-n` | SHOULD | parsed + applied | BROKEN (see issue 3) |
| `-v` | MUST | parsed + applied | WORKS (wrong format, see issue 5) |
| `-h` | SHOULD | parsed + applied | WORKS |
| `-b` | SHOULD | parsed + applied | WORKS |

---

## Issues

---

```
[CRITICAL] -i (interactive) is silently ignored on Linux
Location: src/mv.zig:700-711
Problem: The interactive-mode prompt lives entirely inside the
  `error.PathAlreadyExists` handler of `std.posix.rename()`. On
  Linux, rename(2) returns EINVAL, EXDEV, or succeeds atomically
  when the destination exists — it never returns EEXIST/ENOENT
  mapped to PathAlreadyExists for file-to-file moves. So the
  interactive branch is unreachable on Linux. Confirmed by
  observation: `echo n | mv -i src dst` silently overwrites dst.
  Spec (macOS): "Cause mv to write a prompt to standard error
  before moving a file that would overwrite an existing file."
Fix: Check for a conflicting destination BEFORE calling rename(),
  not inside its error handler. The -n flag already does this
  correctly (lines 653-669). Mirror that pattern for -i: if
  destination exists and options.interactive is true, prompt;
  if user says no, return early.
```

---

```
[CRITICAL] Crash (panic/abort) when moving a directory into one
  of its own subdirectories
Location: src/mv.zig:695
Problem: `std.posix.rename(source, dest)` for
  `mv parent parent/child` causes the kernel to return EINVAL.
  Zig's posix.zig maps EINVAL to `unreachable` inside renameZ,
  which triggers a runtime panic and exits with SIGABRT (exit
  code 134). The integration test at line 348 passes because
  it only checks `exit code != 0`; a crash satisfies that.
  Expected behavior: clean error message and exit code 1.
Fix: Add `error.InvalidArgument` (Zig's EINVAL mapping for
  rename) to the catch switch in moveFile, print an appropriate
  error, and return the error. Example:
    error.InvalidArgument => {
        common.printErrorWithProgram(allocator, stderr_writer,
            "mv", "cannot move '{s}' to a subdirectory of itself,
            '{s}'", .{ source, dest });
        return error.InvalidArgument;
    },
```

---

```
[CRITICAL] Flag-precedence: last flag does not win for -f/-i/-n
  combinations
Location: src/mv.zig:819-826 (MoveOptions construction),
  src/mv.zig:653, 703-711
Problem: All three mutex flags (-f, -i, -n) are stored as
  independent booleans in MvArgs and MoveOptions. There is no
  tracking of which flag appeared last. When multiple flags are
  given, the evaluation order in moveFile is fixed: no_clobber
  check first (line 653), then interactive check (line 703, but
  dead on Linux). This means:
  - `-n -f` → no_clobber wins (WRONG; last flag is -f,
    should overwrite)
  - `-f -i` → silently overwrites (WRONG; last flag is -i,
    should prompt)
  macOS spec: "-f overrides any previous -i or -n options",
  "-i overrides any previous -f or -n options", "-n overrides
  any previous -f or -i options."
  GNU spec: "If you specify more than one of -i, -f, -n, only
  the final one takes effect."
Fix: Track the last-specified mutex flag during argument
  parsing and collapse it into a single enum field, e.g.:
    const OverwriteMode = enum {
        default, force, interactive, no_clobber
    };
  Pass that single value through to moveFile instead of three
  booleans.
```

---

```
[IMPORTANT] Non-standard hint message emitted on stderr during
  every -f overwrite
Location: src/mv.zig:672-677
Problem: When -f is used and the destination exists, mv emits
  "mv: hint: use -i for interactive prompts before overwriting"
  to stderr. Neither macOS mv nor GNU mv emits this hint.
  Scripts that capture stderr for error detection will receive
  unexpected output. The hint also fires on every invocation
  (hinted_overwrite is local to main() so it resets each run).
Fix: Remove the hint entirely. This behavior is not in any
  reference implementation and pollutes stderr.
```

---

```
[IMPORTANT] -v output prints the move arrow even when the move
  was skipped by -n (no-clobber)
Location: src/mv.zig:862-864 (multi-source path),
  src/mv.zig:898-900, 907-909 (single-source path)
Problem: The verbose print (`'src' -> 'dest'`) is emitted by
  the caller (runUtility) after moveFile returns, with no
  knowledge of whether moveFile actually moved anything. When
  -n skips a move because the destination exists, moveFile
  returns nil, and the caller still prints the arrow. Observed:
    $ echo dst > b; echo src > a; mv -nv a b
    mv: not overwriting '.../b' (no-clobber mode)
    '/tmp/.../a' -> '/tmp/.../b'   ← incorrect: move did not happen
Fix: Either (a) move the verbose print inside moveFile, or (b)
  return a boolean from moveFile indicating whether a move
  occurred. Option (a) is simpler and aligns with how verbose
  messages are handled in crossFilesystemMove.
```

---

```
[IMPORTANT] verbose output format uses single quotes (GNU style)
  instead of macOS (BSD) style (no quotes)
Location: src/mv.zig:863, 899, 908
Problem: macOS mv verbose output is:
    /path/to/src -> /path/to/dest
Our output is:
    '/path/to/src' -> '/path/to/dest'
The macOS man page is the primary reference. The GNU-style
  quoted format is a divergence.
Fix: Remove the surrounding single quotes from the format
  strings on lines 863, 899, and 908.
```

---

```
[IMPORTANT] crossFilesystemMove verbose output is verbose
  internal chatter, not the standard single-line summary
Location: src/mv.zig:432-479
Problem: When a cross-filesystem move is triggered, -v causes
  these additional lines on stdout:
    mv: moving 'src' to 'dest' (cross-filesystem)
    mv: copying file 'src' to 'dest'
    mv: removing source 'src'
    mv: completed cross-filesystem move
  GNU mv and macOS mv both emit only the single
  `'src' -> 'dest'` line regardless of whether the move was
  same-filesystem or cross-filesystem.
Fix: Remove the verbose prints from within
  crossFilesystemMove and copyFile. The single-line summary
  is already emitted by the runUtility caller after the move
  completes.
```

---

```
[SUGGESTION] Error message format exposes internal Zig error
  names rather than OS error strings
Location: src/mv.zig:724, 438, and multiple other call sites
Problem: Errors like missing source produce:
    mv: cannot rename '/tmp/missing' to '/tmp/dest':
    error.FileNotFound
  GNU mv and macOS mv produce:
    mv: /tmp/missing: No such file or directory
  The "error.FileNotFound" suffix is Zig's internal error
  tag and is not user-friendly. Same pattern occurs for
  other rename errors.
Fix: Map Zig errors to POSIX strings, or use
  `std.posix.strerror(errno)`. For common cases, handle
  them explicitly:
    error.FileNotFound => "No such file or directory",
    error.AccessDenied => "Permission denied",
```

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 4 |
| SUGGESTION | 1 |

**Overall assessment: BLOCKED**

The `-i` flag is completely non-functional on Linux (the target
platform). The panic on `mv parentdir parentdir/child` is a crash
in a defined-behavior scenario. The flag-precedence bug means
`-n -f` has the wrong winner and `-f -i` skips the prompt it should
show.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Crash on EINVAL (mv dir into subdir of itself)
   — src/mv.zig:695
2. [CRITICAL] -i never prompts on Linux (dead PathAlreadyExists
   branch) — src/mv.zig:700-711
3. [CRITICAL] Last flag does not win for -f/-i/-n combinations
   — src/mv.zig:653, 703-711, 819-826
4. [IMPORTANT] -nv prints arrow even when move was skipped
   — src/mv.zig:862-864, 898-900, 907-909
5. [IMPORTANT] crossFilesystemMove verbose chatter
   — src/mv.zig:432-479
6. [IMPORTANT] Non-standard hint message on every -f overwrite
   — src/mv.zig:672-677
7. [IMPORTANT] Verbose format uses GNU quotes, not macOS style
   — src/mv.zig:863, 899, 908
8. [SUGGESTION] Error messages expose Zig error tags
   — src/mv.zig:724 and call sites
```

REVIEW COMPLETE - BLOCKED
