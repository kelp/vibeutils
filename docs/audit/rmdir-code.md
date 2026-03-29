---
date: 2026-03-28
utility: rmdir
source: src/rmdir.zig
integration_tests: tests/utilities/rmdir_test.sh
spec: docs/specs/rmdir-flags.md
gnu_reference: rmdir (GNU coreutils) 9.10
---

# rmdir Code Audit

## Test Results

- Integration tests: 45/45 PASS
- Unit tests: 12 tests embedded in src/rmdir.zig (all pass)

## Flag Coverage

| Flag | Tier | Implemented | Correct |
|------|------|-------------|---------|
| -p / --parents | MUST | yes | yes |
| -v / --verbose | SHOULD | yes | partial — see finding below |
| --ignore-fail-on-non-empty | SHOULD | yes | partial — see finding below |

---

## Findings

### [IMPORTANT] `-v --ignore-fail-on-non-empty` suppresses verbose message on silenced failure; GNU still prints it

Location: `src/rmdir.zig:213-223` (`removeSingleDirectory`)

Problem: When a directory is non-empty and `--ignore-fail-on-non-empty`
is set, `removeSingleDirectory` returns early (`return`) before
reaching the verbose print statement at line 221. GNU rmdir prints the
"removing directory" message even when the actual removal fails
silently:

```
$ mkdir /tmp/t && touch /tmp/t/f
$ rmdir -v --ignore-fail-on-non-empty /tmp/t
rmdir: removing directory, '/tmp/t'
$ echo $?
0
```

Vibeutils prints nothing.

The distinction matters: verbose mode documents *attempts*, not just
successes. The integration test `"rmdir -v --ignore-fail-on-non-empty"`
only checks exit code 0; it does not verify the verbose line is
present, so the test does not catch the divergence.

Fix: In `removeSingleDirectory`, print the verbose message before
attempting deletion, not after. Or move the verbose print to before the
`deleteDir` call so it always fires when verbose is requested.

---

### [SUGGESTION] `ParentIterator.next()` stops at single-component paths, skipping removal of the top-level parent

Location: `src/rmdir.zig:53-63` (`ParentIterator.next`)

Problem: The iterator returns `null` when `std.fs.path.dirname` yields
`"."` (single-component relative path like `"a"`). This means `rmdir
-p a/b/c` removes `a/b/c`, `a/b`, but not `a` itself, because after
yielding `"a/b"` the next call gets dirname `"a"` → next call returns
`null` after yielding `"a"`. Let me re-read: the iterator's `next`
returns `parent` and sets `self.current = parent`. So it yields `a/b`,
`a`, then `dirname("a")` = `.` which is caught and returns null. So
`a` is actually yielded. Tracing more carefully:

- Initial: `current = "a/b/c"`, `next()` yields `"a/b"`, sets
  `current = "a/b"`
- `next()` yields `"a"`, sets `current = "a"`
- `next()` calls `dirname("a")` → `"."`, hits the `"."` guard,
  returns `null`

So `"a"` is yielded. The unit test `"rmdir: parent iterator memory
management"` confirms `"a"` is yielded as `parent4`. This is correct.
No bug here — the `"."` guard is right.

This finding is WITHDRAWN.

---

### [SUGGESTION] `formatError` falls back to `@errorName` for unlisted errors

Location: `src/rmdir.zig:67-76`

Problem: The `else` branch of `formatError` returns `@errorName(err)`,
emitting Zig-internal error tag names to the user (e.g.
`SymLinkLoop`). POSIX specifies these as human-readable strings.

Fix: Add standard POSIX mappings as needed: `error.SymLinkLoop => "Too
many levels of symbolic links"`, etc.

---

### [SUGGESTION] Verbose message prints path name but integration test uses weak substring match

Location: `tests/utilities/rmdir_test.sh:193` (`rmdir -pv shows each
removal`)

Problem: The test checks `"$vp_out" =~ "a/b"` and `removing.*directory`
but does not check that the full path of each ancestor is printed. The
verbose format is `"rmdir: removing directory, 'PATH'"` — the test
should verify the complete path strings appear in the output, not just
a substring. This is a test quality issue, not a code bug.

Fix: Replace the weak substring check with an exact match on each
directory path that should appear in the verbose output.

---

## Summary

Counts: 0 CRITICAL, 1 IMPORTANT, 2 SUGGESTION (one finding withdrawn
after re-analysis)

Assessment: NEEDS_FIXES

The sole important issue is the verbose/ignore-fail interaction. The
code is otherwise clean and well-tested; POSIX error strings and one
weak test are cosmetic items.

Fix Order:
1. [IMPORTANT] Print verbose message before attempting removal so it
   fires even when `--ignore-fail-on-non-empty` suppresses the error
   — `src/rmdir.zig:213-223`; update integration test to assert the
   verbose line is present
2. [SUGGESTION] Expand `formatError` POSIX mappings —
   `src/rmdir.zig:67-76`
3. [SUGGESTION] Strengthen `-pv` integration test to assert full paths
   — `tests/utilities/rmdir_test.sh:193`
