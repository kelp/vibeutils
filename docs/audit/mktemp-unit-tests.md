---
date: 2026-03-28
utility: mktemp
audit_type: unit-tests
status: NEEDS_FIXES
tests_counted: 17
---

# mktemp Unit Test Audit

## Summary

17 unit tests. All tests that exercise `runMktemp()` call it with
real side effects (file/directory creation) except for the
error-path tests and the explicit `-u` dry-run test. No stdin
concern — mktemp is not a filter utility.

The suite has reasonable coverage of core behavior but contains
several important gaps: the `-t` flag has no unit test at all,
`TMPDIR` environment-variable resolution is never exercised, and
the `generateTemp uniqueness` test is structurally unsound (it
cannot fail because it compares length, not content). The
`fillRandom produces different results` test has the same flaw.
Default-template path resolution (implied `--tmpdir` when no
template is given) is untested.

---

## Filter Utility Assessment

`mktemp` is not a filter utility. It does not read stdin. No
hang risk exists in the test suite.

---

## Test-by-Test Analysis

### `mktemp countTrailingXs`

Behavioral test of a pure helper function. Covers the happy path,
zero-X, empty string, mid-string X (not trailing), and exact
trailing cases. **Good coverage.**

### `mktemp fillRandom produces alphanumeric characters`

Behavioral. Verifies every character in the output is in the
`alphanumeric` charset. **Good.**

### `mktemp fillRandom produces different results`

[IMPORTANT] Weak assertion. The test fills two 10-byte buffers,
checks both contain valid alphanumeric characters, but never
compares `buf1` to `buf2`. The name claims it verifies
distinctness; the body does not. Two identical buffers would pass.

### `mktemp --help shows usage`

Behavioral. Checks exit code 0, presence of "Usage: mktemp", and
"--directory" in output. **Good.**

### `mktemp --version shows version`

Behavioral. Checks exit code 0, "mktemp" and `common.version` in
output. **Good.**

### `mktemp too few Xs in template`

Behavioral. Passes "tmp.XX" (2 X's), expects exit 1 and "too few
X's" on stderr. **Good.**

### `mktemp too many templates`

Behavioral. Passes two positionals, expects exit 2 and "too many
templates" on stderr. **Good.**

### `mktemp creates file with default template`

Behavioral. Calls `runMktemp` with no arguments. Checks exit 0,
non-empty output ending with `\n`, and cleans up. Does not verify:
- The created file actually exists (stat not checked)
- The path is in `$TMPDIR` or `/tmp` (GNU: "if TEMPLATE is not
  specified, use tmp.XXXXXXXXXX, and --tmpdir is implied")
- The file has mode 0600

### `mktemp creates directory with -d flag`

Behavioral. Calls `runMktemp` with `-d`, stats the output path,
asserts `kind == .directory`. **Good.**

Does not check directory mode 0700 (that is covered by the
integration test but not the unit test).

### `mktemp dry-run does not create file`

Behavioral. Calls with `-u`, verifies the printed path does not
exist on disk. **Good.**

### `mktemp with custom template`

Behavioral. Passes "myapp.XXXXXX", checks basename starts with
"myapp." and cleans up. Does not verify the file was created (no
stat call). **Minor gap.**

### `mktemp with --suffix`

Behavioral. Passes `--suffix=.txt tmpXXXXXX`, checks path ends
with `.txt` and basename starts with `tmp`. Cleans up. **Good.**

### `mktemp suffix with slash is rejected`

Behavioral. Passes `--suffix=/bad tmpXXXXXX`, expects exit 1 and
"contains directory separator" on stderr. **Good.**

### `mktemp with -p flag`

Behavioral. Uses `testing.tmpDir`, passes `-p <dir>`, checks the
output path starts with the specified directory. **Good.**

### `mktemp quiet mode suppresses errors`

Behavioral. Passes `-q tmp.XX`, expects exit 1 and zero bytes on
stderr. **Good.**

### `mktemp invalid option`

Behavioral. Passes `--invalid`, expects exit 2. Does not check
stderr content. Minor: error message wording could drift without
detection.

### `mktemp generateTemp creates unique names`

[IMPORTANT] Structurally unsound. The test generates two
dry-run paths and:

1. Checks both start with "/tmp/test."
2. Checks both have length 16

It never asserts `path1 != path2`. Two identical values would pass.
The comment "Very unlikely to be the same" acknowledges the gap but
does not address it.

---

## Coverage Gaps

### CRITICAL

None. No cannot-fail pattern detected (each test asserts
meaningful output or side effects, with the structural weaknesses
called out below as IMPORTANT).

### IMPORTANT

**[IMPORTANT] `-t` flag has zero unit tests.**
Location: `src/mktemp.zig` — `resolveTmpdir`, `-t` branch (line
208)
Problem: `-t` is a MUST-tier flag per `docs/specs/mktemp-flags.md`.
The code path that checks `t_flag` in `resolveTmpdir` is completely
untested at the unit level.
Fix: Add a test that passes `-t tmpXXXXXX` with `TMPDIR` set and
verifies the output path is under the TMPDIR value.

**[IMPORTANT] `TMPDIR` environment-variable resolution is untested.**
Location: `src/mktemp.zig:210`
Problem: The `std.posix.getenv("TMPDIR")` branch in `resolveTmpdir`
has no test. If this branch is broken the default-template and `-t`
paths silently fall back to `/tmp` with no test failure.
Fix: Set `TMPDIR` via `setenv`, call `runMktemp` with no template,
assert the output path is under `TMPDIR`, then restore the env.

**[IMPORTANT] `fillRandom produces different results` does not
compare the two buffers.**
Location: `src/mktemp.zig:358–370`
Problem: Both buffers are validated for charset, but `buf1 != buf2`
is never asserted. The test name claims uniqueness verification.
Fix:
```zig
// After the two charset loops, add:
try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
```
(The probability of collision on 10 random chars from a 62-char
alphabet is ~62^{-10}, effectively zero.)

**[IMPORTANT] `generateTemp creates unique names` does not compare
the two paths.**
Location: `src/mktemp.zig:622–636`
Problem: Length 16 is asserted; equality of `path1` and `path2` is
never checked.
Fix:
```zig
try testing.expect(!std.mem.eql(u8, path1, path2));
```

**[IMPORTANT] Default-template path is not verified to be under
`/tmp` (or `TMPDIR`).**
Location: `src/mktemp.zig:434–454`
Problem: GNU documents "if TEMPLATE is not specified, use
tmp.XXXXXXXXXX, and --tmpdir is implied." The unit test checks the
output is non-empty and ends with `\n` but does not assert the path
prefix. A regression in `resolveTmpdir` (e.g., using cwd instead
of `/tmp`) would pass undetected.
Fix: Assert `std.mem.startsWith(u8, path, "/tmp/")` (or the
TMPDIR value).

### SUGGESTION

**[SUGGESTION] `mktemp creates file with default template` does not
stat the created file.**
Location: `src/mktemp.zig:434–454`
Problem: `runMktemp` returns exit 0 but the test does not call
`std.fs.cwd().statFile(path)` to confirm the file exists. If
`generateTemp` printed a path without actually creating the file
the test would still pass (the cleanup `deleteFile` would silently
fail).
Fix: Add `try std.fs.cwd().statFile(path)` before cleanup.

**[SUGGESTION] `mktemp with custom template` does not stat the
created file.**
Location: `src/mktemp.zig:499–520`
Same gap as above.

**[SUGGESTION] `mktemp creates directory with -d flag` does not
check mode 0700.**
Location: `src/mktemp.zig:456–477`
Problem: The integration test checks this; the unit test only
checks `kind == .directory`.

---

## Findings Summary

| Severity  | Count |
|-----------|-------|
| CRITICAL  | 0     |
| IMPORTANT | 5     |
| SUGGESTION| 3     |

**Assessment: NEEDS_FIXES**

Fix Order:
1. [IMPORTANT] `-t` flag zero unit tests — `src/mktemp.zig`
   (resolveTmpdir line 208)
2. [IMPORTANT] `TMPDIR` env var branch untested —
   `src/mktemp.zig:210`
3. [IMPORTANT] `generateTemp creates unique names` never compares
   paths — `src/mktemp.zig:622`
4. [IMPORTANT] `fillRandom produces different results` never
   compares buffers — `src/mktemp.zig:358`
5. [IMPORTANT] Default-template path prefix not asserted —
   `src/mktemp.zig:434`

REVIEW COMPLETE - NEEDS_FIXES
