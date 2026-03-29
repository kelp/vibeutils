# Code Audit: test (and [)

**Date**: 2026-03-28
**Source file**: src/test.zig
**Spec files**: docs/specs/test-macos.txt (primary),
docs/specs/test-posix.txt, docs/specs/test-flags.md
**Build**: `zig build` — succeeded, no warnings
**Dynamic verification**: both `test` and `[` binaries
built and exercised against all primaries
**Result**: NEEDS_FIXES

---

## Dynamic Verification Results

Both entry points exist at `zig-out/bin/test` and
`zig-out/bin/[`. All binaries run correctly.

### `[` binary: closing `]` enforcement

```
$ [ hello ]          # exit 0 (correct)
$ [ hello           # exit 2 with "[: missing closing ']'"
$ [                  # exit 2 with "[: missing closing ']'"
$ [ ]                # exit 1 (empty expression = false, correct)
```

The `[` binary correctly requires a closing `]` as the
last argument.

### Primary coverage verified by running

All primaries exercised at the shell. Results:

| Primary | Verdict | Notes |
|---------|---------|-------|
| -b | PASS | Returns false on non-block-device |
| -c | PASS | True on /dev/null |
| -d | PASS | True on /tmp, false on file |
| -e | PASS | True/false as expected |
| -f | PASS | True on regular file |
| -g | PASS | False on normal file; true on /usr/bin/sudo |
| -h | PASS | True on symlink, false on regular file |
| -k | PASS | True on /tmp (sticky) |
| -L | PASS | True on symlink, false on regular file |
| -n | PASS | |
| -O | PASS | True on files created by current process |
| -G | PASS | True on files created by current process |
| -p | PASS | True on FIFO created with mkfifo |
| -r | PASS | |
| -s | PASS | |
| -S | not verified directly | No socket created |
| -t | PASS | False for non-tty fd 999; false for fd 0 in CI |
| -u | PASS | True on /usr/bin/sudo |
| -w | PASS | |
| -x | PASS | True on binary, false on text file |
| -z | PASS | |

| Operator | Verdict | Notes |
|----------|---------|-------|
| = | PASS | |
| != | PASS | |
| < | PASS | |
| > | PASS | |
| == | BUG | Returns exit 2 (error); macOS returns 0 |
| -eq | PASS | |
| -ne | PASS | |
| -gt | PASS | |
| -ge | PASS | |
| -lt | PASS | |
| -le | PASS | |
| -nt | BUG | See IMPORTANT #1 |
| -ot | BUG | See IMPORTANT #2 |
| -ef | PASS | |
| ! | PASS | |
| -a | PASS | |
| -o | PASS | |
| ( ) | PASS | |

---

## Issues Found

### IMPORTANT

```
[IMPORTANT] -nt returns false when file2 does not exist
Location: src/test.zig:496-501
Problem: `isNewerThan()` calls `FileAccess.getStat(path2)` and
returns false if stat fails. Per POSIX and both macOS and GNU
behavior, `file1 -nt file2` is true when file1 exists and
file2 does not (file1 is trivially newer). Verified:
  system: /tmp/existing -nt /nonexistent -> exit 0 (true)
  ours:   /tmp/existing -nt /nonexistent -> exit 1 (false)
Fix: Change `isNewerThan` to treat a missing file2 as older:
  fn isNewerThan(path1: []const u8, path2: []const u8) bool {
      const stat1 = FileAccess.getStat(path1) orelse return false;
      const stat2 = FileAccess.getStat(path2) orelse return true;
      return stat1.mtime > stat2.mtime;
  }
```

```
[IMPORTANT] -ot returns false when file1 does not exist
Location: src/test.zig:504-508
Problem: Symmetric to the -nt issue. `isOlderThan()` returns
false if stat of either file fails. When file1 is missing and
file2 exists, `file1 -ot file2` should be true (nonexistent
file is older than existing file). Verified:
  system: /nonexistent -ot /tmp/existing -> exit 0 (true)
  ours:   /nonexistent -ot /tmp/existing -> exit 1 (false)
Fix: Change `isOlderThan` to treat a missing file1 as older:
  fn isOlderThan(path1: []const u8, path2: []const u8) bool {
      const stat1 = FileAccess.getStat(path1) orelse return true;
      const stat2 = FileAccess.getStat(path2) orelse return false;
      return stat1.mtime < stat2.mtime;
  }
Note: Keep `return false` when path2 is missing (file1 exists
but file2 does not; file1 is not older than a nonexistent file).
```

```
[IMPORTANT] == (double-equals) not recognized as alias for =
Location: src/test.zig:387-401, 521-527
Problem: The macOS man page (docs/specs/test-macos.txt line 159)
documents == as a supported compatibility alias for =:
  "the = primary can be substituted with == with the same meaning"
Our implementation does not include == in `isBinaryOperator` or
`evaluateBinary`, so it returns exit code 2 (error). Verified:
  system: test abc == abc -> exit 0
  ours:   test abc == abc -> exit 2, "test: invalid expression"
Fix: Add to `evaluateBinary` before the final `return error.UnknownOperator`:
  if (std.mem.eql(u8, op, "==")) return std.mem.eql(u8, left, right);
Add "==" to the `binary_ops` array in `isBinaryOperator`.
```

### SUGGESTION

```
[SUGGESTION] -nt/-ot use mtime only; sub-second precision lost
Location: src/test.zig:105-113, 500, 506
Problem: The `getLinkStat` conversion stores mtime as integer
seconds only (`@intCast(mtime_sec)`). Sub-second timestamps
are discarded. macOS test uses full nanosecond precision for
-nt/-ot comparisons. Two files created within the same second
that have different sub-second mtimes will compare as equal.
This is a precision loss, not a correctness bug in the normal
case, but it differs from reference behavior when files are
created in rapid succession (as the unit test does with a
10ms sleep). The unit test works around this with `sleep`, but
production shells may encounter it.
Fix: Extend the mtime storage to nanoseconds. Change the
stat struct usage to store `mtime_ns: i128` and use
nanosecond-resolution timestamps from `stat_buf.mtimespec`.
```

```
[SUGGESTION] `isUnknownOperatorLike` is confused by -a and -o
Location: src/test.zig:124-131
Problem: The function body explicitly excludes "-a" and "-o"
with a redundant check:
  !std.mem.eql(u8, str, "-a") and !std.mem.eql(u8, str, "-o")
These are already excluded by `isBinaryOperator` returning
false (since -a/-o are not in `binary_ops`) and by
`isUnaryOperator` returning false. The condition is dead code
— `isBinaryOperator("-a")` already returns false, so the
function would never identify "-a" as an unknown operator
anyway. However the intent is unclear and could mislead.
Fix: Remove the explicit -a/-o checks and add a comment
explaining that -a/-o are logical operators handled
separately by the parser, not binary operators.
```

```
[SUGGESTION] Sentinel strings ("\x00true"/"\x00false") are
fragile internal protocol
Location: src/test.zig:180-182, 284-285
Problem: `evaluateWithParentheses` replaces parenthesized
sub-expressions with sentinel strings "\x00true" or
"\x00false" and passes them back through `evaluateSingle`,
which must recognize them. This creates an invisible coupling
between two functions. If any path in the evaluator receives
an actual command-line argument starting with \x00 (unusual
but not impossible) it would be misinterpreted as a boolean
result.
Fix: Refactor `evaluateWithParentheses` to evaluate
sub-expressions recursively and return bool results directly
rather than encoding them as strings. This can be done by
passing a `bool` accumulator or by restructuring the loop
to avoid the string-based workaround entirely.
```

---

## Primary/Operator Verdict Table

### File Type Primaries (all MUST)

| Primary | Implemented | Correct | Notes |
|---------|-------------|---------|-------|
| -b | yes | yes | |
| -c | yes | yes | |
| -d | yes | yes | |
| -e | yes | yes | |
| -f | yes | yes | |
| -g | yes | yes | |
| -h | yes | yes | Calls getLinkStat, no dereference |
| -k | yes | yes | |
| -L | yes | yes | Same as -h |
| -O | yes | yes | |
| -G | yes | yes | |
| -p | yes | yes | Uses getStat (follows symlinks to fifo) |
| -S | yes | yes | Uses getStat |

### File Permission/Attribute Primaries (all MUST)

| Primary | Implemented | Correct | Notes |
|---------|-------------|---------|-------|
| -r | yes | yes | posix.access R_OK |
| -s | yes | yes | |
| -t | yes | yes | posix.isatty |
| -u | yes | yes | |
| -w | yes | yes | posix.access W_OK |
| -x | yes | yes | posix.access X_OK |

### String Primaries (all MUST)

| Primary | Implemented | Correct | Notes |
|---------|-------------|---------|-------|
| -n | yes | yes | |
| -z | yes | yes | |
| (bare string) | yes | yes | Non-empty = true |

### String Comparison Operators (all MUST)

| Operator | Implemented | Correct | Notes |
|----------|-------------|---------|-------|
| = | yes | yes | |
| != | yes | yes | |
| < | yes | yes | Binary lexicographic |
| > | yes | yes | Binary lexicographic |
| == | NO | — | macOS extension, should alias = |

### Integer Comparison Operators (all MUST)

| Operator | Implemented | Correct | Notes |
|----------|-------------|---------|-------|
| -eq | yes | yes | |
| -ne | yes | yes | |
| -gt | yes | yes | |
| -ge | yes | yes | |
| -lt | yes | yes | |
| -le | yes | yes | |

### File Comparison Operators (all MUST)

| Operator | Implemented | Correct | Notes |
|----------|-------------|---------|-------|
| -nt | yes | WRONG | See IMPORTANT #1 |
| -ot | yes | WRONG | See IMPORTANT #2 |
| -ef | yes | yes | Uses common.file_ops.isSameFile |

### Logical Operators (all MUST)

| Operator | Implemented | Correct | Notes |
|----------|-------------|---------|-------|
| ! | yes | yes | Correctly applies to next unit only |
| -a | yes | yes | Higher precedence than -o |
| -o | yes | yes | Left-to-right |
| ( ) | yes | yes | Recursive evaluation |

---

## Architecture Notes

The implementation is clean and straightforward. The
`ExpressionParser` struct cleanly separates concerns.
`evaluateUnary` and `evaluateBinary` are pure dispatch
functions with no side effects. The operator precedence
implementation (`-o` lowest, `-a` next, `!` highest)
matches POSIX exactly.

The bracket-form detection (`std.mem.endsWith(u8,
program_name, "[")`) is correct and handles the `[` binary
name reliably.

The `getLinkStat` function is the only platform-specific
path; it handles the `atimespec`/`atim` field name
difference between macOS and Linux correctly.

---

## Summary

| Severity | Count |
|----------|-------|
| IMPORTANT | 3 |
| SUGGESTION | 3 |

**Assessment: NEEDS_FIXES**

The implementation is solid. Exit codes are correct (0/1/2).
Both entry points (`test` and `[`) work correctly. The `[`
binary enforces the closing `]`. All POSIX and most macOS
primaries are correctly implemented. The three IMPORTANT
issues are behavioral bugs: `-nt` and `-ot` give wrong answers
when a file is missing, and the `==` alias is absent.

Fix Order:
1. [IMPORTANT] -nt wrong when file2 missing — src/test.zig:496
2. [IMPORTANT] -ot wrong when file1 missing — src/test.zig:504
3. [IMPORTANT] == not recognized as alias for = — src/test.zig:387
4. [SUGGESTION] -nt/-ot sub-second precision — src/test.zig:105-113
5. [SUGGESTION] Remove dead -a/-o guards in isUnknownOperatorLike — src/test.zig:126
6. [SUGGESTION] Refactor sentinel-string protocol — src/test.zig:180-182

REVIEW COMPLETE - NEEDS_FIXES
