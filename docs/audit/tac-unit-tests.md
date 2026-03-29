---
date: 2026-03-28
utility: tac
audit_type: unit-tests
status: NEEDS_FIXES
tests_counted: 17
---

# tac Unit Test Audit

## Summary

17 unit tests. All tests use `testing.tmpDir()` and call
`runTac()` directly — no stdin hang risk exists because every
test passes at least one file-path argument, bypassing the
`files.len == 0` stdin branch. Tests are behavioral (full
output assertions with `expectEqualStrings`), not parse-only.
No tests are parse-only stubs.

However, three important gaps exist: the `-b` flag with a
multi-byte separator is silently broken and no test detects
it, error messages use Zig error names instead of POSIX
strings, and the stdin/`-` path has zero unit coverage.

---

## Filter Utility Assessment

`tac` is a filter utility. The implementation exposes
`runTac()` which opens stdin when `files.len == 0`. All 17
unit tests supply a file-path argument, so they never reach
the stdin branch and will **not hang**. The stdin path is
untested, not a test-hang risk.

No `runTacWithInput()` split exists. This is the correct
pattern for testing stdin paths without hang risk, but it is
absent.

---

## Issues

```
[CRITICAL] -b flag silently ignored for multi-byte separators
Location: src/tac.zig:213
Problem: reverseByStringSeparator() calls writeRecordsReversed()
  with sep_byte=0. Inside writeRecordsReversed(), the before-mode
  branch checks `sep_byte != 0` before moving the separator, so
  the condition is always false when a multi-byte separator is
  used. The -b flag has zero effect with -s '<>' or any multi-byte
  string.
  GNU: printf 'one<>two<>three<>' | tac -s '<>' -b
  outputs: <><>three<>twoone
  Ours outputs: three<>two<>one<> (unchanged from no -b)
  The unit test "tac with multi-byte separator" does not pass -b,
  so this bug is completely invisible to the test suite.
Fix: Pass the separator string to writeRecordsReversed (or create
  a parallel writeRecordsReversedMulti) so before-mode can strip
  the trailing multi-byte separator from each record and prepend it.
  Add a unit test: tac -s '<>' -b on 'one<>two<>three<>' and verify
  against GNU output.
```

```
[IMPORTANT] Error messages use Zig error names, not POSIX strings
Location: src/tac.zig:127
Problem: runTacOnFile() emits @errorName(err) which produces
  "FileNotFound" instead of the POSIX "No such file or directory".
  GNU tac emits: "tac: failed to open 'x': No such file or directory".
  The unit test at src/tac.zig:490 asserts indexOf("FileNotFound")
  — this assertion locks in the wrong behavior and would pass
  even after fixing the error string.
Fix: Map OS errors to POSIX strings (use std.posix.unexpectedErrno
  or a switch on error values). Update the unit test assertion to
  check for the POSIX string.
```

```
[IMPORTANT] stdin path (no-args and "-" arg) has zero unit coverage
Location: src/tac.zig:103-107, 111-114
Problem: When files.len == 0 or a positional equals "-", runTac
  reads from real stdin. No unit test exercises either path.
  Bugs in stdin-specific error handling or the "-" dispatch are
  invisible to the unit suite.
Fix: Add a runTacWithInput() internal helper that accepts an
  io.FixedBufferStream or similar, following the pattern in
  src/tr.zig. Write unit tests for the stdin path (no args)
  and the "-" literal path.
```

```
[IMPORTANT] -b with single-byte separator: edge case divergence untested
Location: src/tac.zig:509-514 (test "tac reverseByByteSeparator with before")
Problem: The unit test checks 'a\nb\nc\n' → '\nc\nb\na', which
  matches the implementation. GNU with the same input produces
  '\n\nc\nba'. The difference arises from how the final empty
  record (after the trailing newline) is handled. Our
  implementation produces different output from GNU in this case,
  and the existing test was written to match our (potentially
  wrong) behavior rather than validated against GNU.
  GNU: printf 'a\nb\nc\n' | tac -b | od -c → \n \n c \n b a
  Ours: od -c → \n c \n b \n a
Fix: Verify the correct GNU behavior for trailing-newline input
  with -b and update the test and implementation to match.
  This may require changing how the final empty record is emitted
  in before-mode.
```

```
[SUGGESTION] Empty separator (-s '') behavior untested
Location: src/tac.zig:157-159 (empty separator path)
Problem: The code has a special branch for separator.len == 0
  (NUL-byte separator). No unit test exercises this path.
  GNU tac -s '' uses the empty string to trigger NUL-separation;
  the behavior is implementation-defined but should be consistent.
Fix: Add a unit test that creates a file with NUL-separated
  records, passes -s '', and asserts the reversed output.
```

```
[SUGGESTION] reverseByByteSeparator no-trailing-separator test
  expects concatenated output
Location: src/tac.zig:501-507
Problem: The test asserts "cb\na\n" for input "a\nb\nc". The
  last record "c" has no trailing newline, so it and the next
  record "b\n" are concatenated as "cb\n". This matches the
  current implementation but the test comment does not explain
  the reasoning. A clear comment noting that the no-separator
  record merges with the preceding reversed record would help
  readers understand whether this matches GNU behavior.
Fix: Add a comment citing the GNU behavior confirmation
  (printf 'a\nb\nc' | tac produces cb\na on GNU).
```

---

## Flag Coverage Matrix

| Flag | Tier   | Unit test exists | Behavioral verification |
|------|--------|-----------------|------------------------|
| -b   | SHOULD | yes (single-byte only) | partial — multi-byte broken, trailing-\n diverges |
| -r   | SHOULD | yes (unsupported) | yes (returns error) |
| -s   | SHOULD | yes (single and multi) | yes (default mode only) |
| -b + -s multi-byte | n/a | **no** | **no** — production bug |
| -s ''  | n/a  | **no** | none |
| stdin (no args) | n/a | **no** | none |
| "-" arg | n/a | **no** | none |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -b ignored for multi-byte separators — src/tac.zig:213
2. [IMPORTANT] Error messages: Zig names vs POSIX strings — src/tac.zig:127
3. [IMPORTANT] Add runTacWithInput() + stdin/dash unit tests — src/tac.zig:103
4. [IMPORTANT] Verify/fix -b single-byte trailing-newline vs GNU — src/tac.zig:509
5. [SUGGESTION] Add -s '' empty separator unit test — src/tac.zig:157
6. [SUGGESTION] Add comment on no-trailing-separator merge behavior — src/tac.zig:501
```

REVIEW COMPLETE - NEEDS_FIXES
