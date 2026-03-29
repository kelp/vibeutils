# head Code Audit

**Date:** 2026-03-28
**Files reviewed:** `src/head.zig`, `docs/specs/head-flags.md`,
`docs/specs/head-macos.txt`, `docs/specs/head-posix.txt`,
`docs/specs/head-gnu.txt`
**Build:** passes (`just build-util head`)
**Unit tests:** 19 tests (all pass)
**Integration tests:** 76/76 pass

---

## Flag-by-Flag Verdict

| Flag | Tier | Verdict | Notes |
|------|------|---------|-------|
| `-n` | MUST | PASS | Correct |
| `-c` | SHOULD | PASS | Correct |
| `-q` | SHOULD | PASS | Correct |
| `-v` | SHOULD | PASS | Correct |
| `-z` | SHOULD | PASS | Correct |
| `--silent` | SHOULD | FAIL | GNU alias for `-q`; argparse has no alias support; returns exit 2 |
| `-n [-]NUM` | SHOULD | FAIL | GNU "all but last N lines" not implemented; returns exit 2 |
| `-c [-]NUM` | SHOULD | FAIL | GNU "all but last N bytes" not implemented; returns exit 2 |
| NUM suffixes | SHOULD | FAIL | `K`, `1k`, `MB`, etc. not parsed; returns exit 2 |

---

## Issues

### CRITICAL

**[CRITICAL] IsDir and ReadFailed crash with stack trace instead of
clean error message**
Location: `src/head.zig:153`
Problem: `openFile` on a directory succeeds on Linux. The read
attempt inside `processInput` then propagates `error.ReadFailed`
(which wraps `EISDIR`). The call at line 153 is a bare `try`, so
the error bubbles up to `main`'s `!void` return and the runtime
prints an unwinding stack trace. The system produces:

```
head: error reading '/tmp': Is a directory
```

The implementation produces:

```
error: ReadFailed
/nix/store/.../posix.zig:1180:23: 0x116bd19 in preadv (std.zig)
...
```

This also affects `-c` mode (byte path, line 238). The same crash
occurs for any read-time I/O error on an already-opened file
descriptor: broken pipes on special files, device errors, etc.

Fix: Wrap `processInput` calls at lines 138 and 153 in a `catch`
block and emit a clean error, analogous to the `openFile` handler
at line 141-145. Also add `error.ReadFailed` and `error.IsDir` to
`errorToMessage`.

---

### IMPORTANT

**[IMPORTANT] `--silent` long option alias not recognized**
Location: `src/head.zig:203` (help text), `src/head.zig:30`
Problem: The help text advertises `-q, --quiet, --silent` but
`--silent` returns exit 2 ("unrecognized option"). The argparse
module has no alias mechanism, so only `--quiet` resolves to the
`quiet` field. GNU coreutils accepts all three.

Verified:
```
./head --silent /tmp/h1.txt /tmp/h2.txt
head: unrecognized option   (exit 2)
```

Fix: Remove `--silent` from the help text until alias support
exists in argparse, OR add alias support to argparse and register
`silent` as an alias for `quiet`.

---

**[IMPORTANT] GNU `[-]NUM` negative suffix not implemented for `-n`
and `-c`**
Location: `src/head.zig:27-28` (help text), implementation
Problem: GNU head (and the system `head` on this machine) supports
`-n -NUM` and `-c -NUM` to mean "all but the last NUM lines/bytes".
The implementation rejects negative values with exit 2. The help
text correctly omits this syntax (regression test at line 266-272
of the integration test verifies no false advertising), so this is
a missing feature, not an inconsistency in documentation. However,
it is a SHOULD-tier behavioral gap because `head -n -3` is a common
idiom.

Fix: Parse a leading `-` on the NUM argument as a "skip-tail"
modifier. Implement by buffering or two-pass reading for the
"all but last N" path.

---

**[IMPORTANT] Multiplier suffixes (`K`, `kB`, `M`, etc.) not
parsed**
Location: `src/head.zig:77-93` (argparse path)
Problem: GNU head accepts `b`, `kB`, `K`, `MB`, `M`, `GB`, `G`,
`T`, `P`, `E`, `Z`, `Y`, `R`, `Q` and their `KiB`/`MiB` variants
as multiplier suffixes on `-c` and `-n` values. Any suffix causes
`error.InvalidValue` and exit 2.

Verified:
```
./head -c 1K /tmp/h1.txt
head: invalid option value   (exit 2)
```

Fix: Parse suffixes in the value-extraction path before passing to
`std.fmt.parseInt`. Apply the appropriate multiplier.

---

### SUGGESTION

**[SUGGESTION] `processInput` is `pub` with no callers outside
the file**
Location: `src/head.zig:230`
Problem: `processInput` is exported `pub` but is only called
within `head.zig`. Marking it `pub` unnecessarily widens the API
surface.

Fix: Change to `fn processInput(...)`.

---

**[SUGGESTION] `TEST_NEGATIVE_VALUE` constant leaks test
implementation detail**
Location: `src/head.zig:287`
Problem: `const TEST_NEGATIVE_VALUE: []const u8 = "-5";` is a
file-level constant used in a single test. It adds no clarity over
an inline literal.

Fix: Inline the literal in the test.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| IMPORTANT | 2 |
| SUGGESTION | 2 |

**Assessment: NEEDS_FIXES**

The core line-counting, byte-counting, `-q`, `-v`, `-z`, header
logic, multi-file handling, stdin (`-`), and obsolete `-NUM`
syntax all work correctly and match the reference. The 76/76
integration tests pass.

The CRITICAL issue is a crash (stack trace) when reading a
directory instead of a clean error message. The two IMPORTANT
issues are missing GNU features that the help text deliberately
does not advertise but that real users expect.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] IsDir/ReadFailed crash — src/head.zig:138,153
2. [IMPORTANT] --silent alias not recognized — src/head.zig:30
3. [IMPORTANT] [-]NUM not implemented for -n/-c — src/head.zig:77
4. [SUGGESTION] processInput should not be pub — src/head.zig:230
5. [SUGGESTION] inline TEST_NEGATIVE_VALUE — src/head.zig:287
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
