---
date: 2026-03-28
utility: mkdir
source: src/mkdir.zig
integration_tests: tests/utilities/mkdir_test.sh
spec: docs/specs/mkdir-flags.md
gnu_reference: mkdir (GNU coreutils) 9.10
---

# mkdir Code Audit

## Test Results

- Integration tests: 98/98 PASS
- Unit tests: 19 tests embedded in src/mkdir.zig (all pass via `zig build`)

## Flag Coverage

| Flag | Tier | Implemented | Correct |
|------|------|-------------|---------|
| -m   | MUST | yes | partial — octal only, symbolic modes rejected |
| -p   | MUST | yes | partial — `-p -m` applies mode to ALL dirs, not just leaf |
| -v   | SHOULD | yes | yes |

---

## Findings

### [IMPORTANT] `-m` rejects symbolic mode strings; GNU accepts them

Location: `src/mkdir.zig:177-194` (`parseMode`)

Problem: `parseMode` only calls `std.fmt.parseInt(u32, mode_str, 8)`.
Any mode using symbolic notation (e.g. `u+rwx,g+rx`, `a+rwx`, `755`
already works because it is octal, but `u+x` does not). GNU mkdir
accepts the full chmod symbolic syntax. The spec comment on line 179
acknowledges this with "TODO: Support symbolic modes like u+rwx".

Fix: Implement symbolic mode parsing (or at minimum, surface a clear
WONT note in the spec). As written this is a behavioral divergence
from GNU for any non-octal mode string.

---

### [IMPORTANT] `-p -m MODE` applies mode to ALL intermediate directories; GNU applies it only to the leaf

Location: `src/mkdir.zig:272-275` inside `createPathComponents`

Problem: GNU documentation explicitly states: `-p, --parents: no error
if existing, make parent directories as needed, **with their file modes
unaffected by any -m option**." Only the final (leaf) directory receives
the `-m` mode; parent components are created with the umask-derived
default. The vibeutils implementation calls `setDirectoryMode` inside
the per-component loop, so every newly-created directory — including
intermediates — gets the requested mode.

Verified with GNU 9.10:
```
$ mkdir -pm 700 test/a/b
$ stat -c %a test test/a test/a/b
775   (umask default)
775   (umask default)
700   (leaf only)
```

Vibeutils outputs 700 for all three levels.

The unit tests `"mkdir -pm sets mode on intermediate directories"`,
`"mkdir -pm sets mode on all directories including first parent"`, and
the integration test `"mkdir -p -m 700 intermediate dir mode"` all
assert the WRONG behavior (700 on intermediates), so they will
continue passing even after the semantics diverge from GNU. These tests
need to be inverted to match the correct GNU behavior before the fix is
applied.

Fix: Move `setDirectoryMode` outside the per-component loop. Record
which path components were newly created during the `-p` walk, then
after the loop apply the mode only to the leaf (last created)
directory.

---

### [SUGGESTION] Help text for `-p` omits the `-m` interaction caveat

Location: `src/mkdir.zig:135-146` (`printHelp`) and `src/mkdir.zig:21`
(`meta`)

Problem: GNU's help text says "with their file modes unaffected by any
-m option" for `-p`. The vibeutils help and argparse meta descriptions
say only "Make parent directories as needed, no error if existing",
omitting the critical mode-interaction detail. Once the `-p -m`
behavior is fixed, the help text should be updated to match GNU.

Fix: After fixing the `-p -m` behavior, update the `-p` description to
add: ", with their file modes unaffected by any -m option".

---

### [SUGGESTION] `errorToMessage` falls back to `@errorName` for unlisted errors

Location: `src/mkdir.zig:197-208`

Problem: The `else` branch returns `@errorName(err)`, which emits
Zig-internal error names (e.g. `SymLinkLoop`, `SystemResources`) to
users. Other utilities in the project use POSIX strings for all
commonly encountered errors. This is a cosmetic issue but inconsistent.

Fix: Add missing POSIX mappings: `error.SymLinkLoop => "Too many levels
of symbolic links"`, `error.SystemResources => "Cannot allocate
resource"`, etc.

---

## Summary

Counts: 0 CRITICAL, 2 IMPORTANT, 2 SUGGESTION

Assessment: NEEDS_FIXES

The `-p -m` semantics diverge from GNU in a way that is wrong and has
unit and integration tests that lock in the wrong behavior. Symbolic
mode support is a documented gap.

Fix Order:
1. [IMPORTANT] Fix `-p -m` to apply mode only to leaf directory, update
   tests — `src/mkdir.zig:272-275`
2. [IMPORTANT] Implement symbolic mode parsing for `-m` —
   `src/mkdir.zig:177-194`
3. [SUGGESTION] Update `-p` help text to mention mode unaffected —
   `src/mkdir.zig:135-146`
4. [SUGGESTION] Expand `errorToMessage` POSIX mappings —
   `src/mkdir.zig:197-208`
