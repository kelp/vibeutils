---
audit: tee unit tests
date: 2026-03-28
file: src/tee.zig
result: NEEDS_FIXES
build: 9/9 pass (all tests behavioral, no stdin hang risk)
---

# tee Unit Test Audit

## Summary

9 unit tests, all pass. No stdin hang risk: the implementation
correctly separates `runTee()` (reads real stdin) from
`runTeeWithInput()` (takes a `std.fs.File` argument). All 6
behavioral tests call `runTeeWithInput()` with a temp file,
so no test can block. The 3 flag-parsing tests (`--help`,
`--version`, unknown flag) return before touching stdin.

The test suite has zero parse-only stubs. Coverage is genuinely
behavioral for the features it touches. However, three flags
have no unit tests at all (`-i`, `-p`, and the error paths),
and the three dash-operand tests encode behavior that diverges
from GNU coreutils 9.10 (confirmed with subprocess tests
against coreutils 9.10).

---

## Stdin Hang Risk

**None.** The split between `runTee()` and `runTeeWithInput()`
is the correct pattern for a filter utility. Every test that
exercises data processing calls `runTeeWithInput()` with a
temp file seeked to position 0.

---

## Test-by-Test Analysis

### 1. `tee --help shows help message`
Calls `runTee()`. Returns before stdin is read.
Verifies exit code 0 and `"Usage: tee"` in output.
**Behavioral.** Pass.

### 2. `tee --version shows version information`
Calls `runTee()`. Returns before stdin is read.
Verifies exit code 0 and `"tee"` in output.
**Behavioral.** Pass. Minor: the check `indexOf(_, "tee") !=
null` would pass even for a single-char match; a stronger
check for the version string format would be more robust but
this is low priority.

### 3. `tee with unknown flag should return error`
Calls `runTee()` with `--unknown-flag`.
Verifies exit code 2 and `"unrecognized option"` on stderr.
**Behavioral.** Pass.

### 4. `tee copies input to stdout and files`
Calls `runTeeWithInput()` with a temp file as input.
Verifies exit code 0, stdout content, and file content.
**Behavioral.** Pass. Good test.

### 5. `tee -a appends to existing files`
Calls `runTeeWithInput()` with `append = true`.
Creates a pre-existing file, then verifies combined content.
**Behavioral.** Pass. Good test.

### 6. `tee dash operand writes stdout twice`
Calls `runTeeWithInput()` with `positionals = &.{"-"}`.
Expects `"hello\nhello\n"` (two copies).
**Behavioral — but encodes incorrect GNU semantics.**
See IMPORTANT issue below.

### 7. `tee two dash operands writes stdout three times`
Calls `runTeeWithInput()` with `positionals = &.{"-", "-"}`.
Expects `"hello\nhello\nhello\n"` (three copies).
**Behavioral — but encodes incorrect GNU semantics.**
See IMPORTANT issue below.

### 8. `tee dash with file writes stdout twice and to file`
Calls `runTeeWithInput()` with `positionals = &.{output_path, "-"}`.
Verifies two stdout copies and one file copy.
**Behavioral — but encodes incorrect GNU semantics for stdout.**

### 9. `tee with no files copies stdin to stdout only`
Calls `runTeeWithInput()` with no positionals.
Verifies exit code 0 and stdout content.
**Behavioral.** Pass. Good baseline test.

---

## Issues

```
[IMPORTANT] Dash-operand tests lock in wrong GNU semantics
Location: src/tee.zig:451-543 (tests 6, 7, 8)
Problem: GNU coreutils 9.10 tee treats '-' as a reference to
the same stdout file descriptor, not an independent write.
Because both the normal stdout and the '-' operand share the
same fd, there is no duplication at the fd level:

  python3 -c "
  import subprocess
  r = subprocess.run(['tee', '-'], input=b'hello\n', capture_output=True)
  print(r.stdout.count(b'\n'))   # prints 1
  r2 = subprocess.run(['tee', '-', '-'], input=b'hello\n', capture_output=True)
  print(r2.stdout.count(b'\n'))  # prints 1
  "

vibeutils writes to the stdout writer twice (once for the
normal output, once for the '-' operand), producing two copies.
These tests assert the vibeutils behavior, which is wrong
relative to GNU. Tests 6, 7, and 8 will all produce false
confidence that the implementation is correct.

Fix: Verify the intended '-' behavior by consulting the GNU
coreutils source and POSIX. If the decision is to match GNU
(write to same fd = one copy), fix the implementation and
update these three tests. If the decision is intentional
divergence, document it explicitly in tee-vibeutils.txt and
add a comment in the test.
```

```
[IMPORTANT] -i flag has zero unit test coverage
Location: src/tee.zig (no test for ignore_interrupts)
Problem: The -i/--ignore-interrupts flag sets up SIGINT
ignoring via sigaction(). There is no unit test verifying
that (a) the flag parses, or (b) that it does not break normal
processing. While behavioral SIGINT testing is difficult in
unit tests, at minimum a round-trip test through runTee() with
-i that verifies data flows through and exit code is 0 is
missing.

Fix: Add a test calling runTeeWithInput() with ignore_interrupts
= true and verify normal data copy still works.
```

```
[IMPORTANT] -p flag has zero unit test coverage
Location: src/tee.zig (no test for diagnose_errors)
Problem: No unit test exercises the -p/--diagnose-errors flag.
As noted in the code audit (tee-code.md), -p has incorrect
semantics relative to GNU, and the default mode silently
swallows write errors. Without a unit test that simulates a
write failure, the bug is invisible. A test using a writer
that returns an error would catch this.

Fix: Add a test using a writer that returns WriteError, and
verify (a) without -p: exit code 1, no stderr message; (b)
with -p: exit code 1, stderr contains an error message.
```

```
[SUGGESTION] createTempInput leaks tmpDir
Location: src/tee.zig:568-577
Problem: The helper creates a testing.tmpDir but intentionally
discards it (the comment says "OS reclaims on process exit").
This means the temp directory and file are not cleaned up until
the test binary exits. With 5 tests using createTempInput,
there are 5 leaked temp directories per test run. This is not
a hang risk but it is a resource leak.

Fix: Either store the tmpDir in a struct along with the file
and return that (caller calls cleanup()), or switch to using
std.testing.tmpDir() scoped within each test (avoiding the
separate helper). The current comment acknowledges the leak
but calling it intentional is a stretch.
```

---

## Coverage Gaps

| Feature | Unit Covered | Notes |
|---------|-------------|-------|
| --help | yes | behavioral |
| --version | yes | behavioral |
| unknown flag | yes | behavioral |
| copy to file | yes | behavioral |
| copy to stdout only | yes | behavioral |
| -a append | yes | behavioral |
| - dash operand | yes | behavioral but wrong GNU semantics |
| -i ignore-interrupts | no | zero coverage |
| -p diagnose-errors | no | zero coverage |
| write error path | no | zero coverage |
| read error path | no | zero coverage |
| runTee() data path | no | all data tests bypass runTee() |

---

## Fix Order

1. [IMPORTANT] Clarify and correct dash-operand behavior vs
   GNU — src/tee.zig:451-543
2. [IMPORTANT] Add -i unit test (data flows through) —
   src/tee.zig test section
3. [IMPORTANT] Add -p unit test with failing writer to catch
   silent-swallow bug — src/tee.zig test section
4. [SUGGESTION] Fix createTempInput resource leak —
   src/tee.zig:568-577

REVIEW COMPLETE - NEEDS_FIXES
