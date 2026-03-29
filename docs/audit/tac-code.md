# tac Code Audit

**Date:** 2026-03-28
**Reference:** GNU coreutils 9.10 (primary), no POSIX or macOS
  native equivalent
**Unit tests:** 17 tests in `src/tac.zig` (all pass)
**Integration tests:** 25/25 pass (`just it-util tac`)
**Assessment:** NEEDS_FIXES

---

## Summary

`tac` is a GNU-only utility. The implementation is clean and
well-structured. Two behavioral divergences from GNU exist: the
`-b`/`--before` separator-placement algorithm is wrong, producing
incorrect output for all inputs with a trailing separator or more
than two records; and `-r`/`--regex` rejects immediately (exit 2)
rather than treating the newline as a literal regex and succeeding
(exit 0) as GNU does. The `-b` bug is masked by a unit test that
asserts the wrong expected value, and by an integration test whose
expected string is also wrong.

Error messages use Zig's `@errorName` (e.g., `FileNotFound`)
instead of POSIX strings (`No such file or directory`), diverging
from GNU's format.

---

## Findings

```
[CRITICAL] -b/--before separator placement is wrong for all
  inputs with a trailing separator
Location: src/tac.zig:218 writeRecordsReversed
          src/tac.zig:229-246 (before branch)
Problem: GNU -b means: the separator belongs *before* every
  record except the very first record in the original input
  (which prints last). Our implementation prepends the sep
  to all records *except the last record in the original*
  (i.e., the first printed). This is the opposite. For
  "a\nb\nc\n", GNU gives "\n\nline3\nline2line1"; we give
  "\nline3\nline2\nline1".

  For single-byte sep with trailing sep in input:
    GNU:  printf 'a\nb\nc\n' | tac -b  ->  \n\nline3\nline2line1
    Ours: printf 'a\nb\nc\n' | tac -b  ->  \nline3\nline2\nline1

  For single-byte sep without trailing sep:
    GNU:  printf 'a\nb\nc' | tac -b  ->  \nc\nb a  (sep before
          all but first original)
    Ours: printf 'a\nb\nc' | tac -b  ->  c\nb\na   (sep appended)

  For multi-byte sep:
    GNU:  printf 'one<>two<>three<>' | tac -s'<>' -b  ->
          <>three<>twoone
    Ours: printf 'one<>two<>three<>' | tac -s'<>' -b  ->
          three<>two<>one<>  (no -b effect at all for multi-byte)

  The correct algorithm:
  1. Strip trailing sep from each record, store stripped content.
  2. Reverse the record list.
  3. Print the first reversed record (= last original) with NO
     leading sep.
  4. Print all remaining reversed records each with sep prepended.

  Consequence: writeRecordsReversed also receives sep_byte=0 for
  multi-byte separators (line 213), making -b entirely inert on
  multi-byte input.
Fix: Rework writeRecordsReversed. For -b mode, pass the full
  separator string (not just a byte) and use the correct
  algorithm. Specifically:
  - Strip trailing sep from each record when building records
    list (in both reverseByByteSeparator and
    reverseByStringSeparator).
  - In writeRecordsReversed, iterate reversed records; write
    records[i] for the first (i = len-1, the last original);
    write sep + records[i] for all others.
```

```
[CRITICAL] Unit tests assert wrong expected output for -b
Location: src/tac.zig:435-454 "tac with --before flag"
          src/tac.zig:509-514 "tac reverseByByteSeparator with
          before"
Problem: "tac with --before flag" expects "\nline3\nline2\nline1"
  but GNU produces "\n\nline3\nline2line1". The test passes
  today only because the code is wrong in the same way. When
  the code is fixed, this test will fail unless the expected
  value is also corrected.
  Same issue in "tac reverseByByteSeparator with before":
  expects "\nc\nb\na" but GNU produces "\nc\nb a" (no newline
  between b and a, because "a" is the first original record and
  gets no leading sep).
Fix: After correcting the algorithm, update both tests to assert
  the correct GNU-matching output:
  - "tac with --before flag": "\n\nline3\nline2line1"
  - "tac reverseByByteSeparator with before": "\nc\nba"
```

```
[IMPORTANT] -r/--regex rejects unconditionally; GNU accepts
  -r with the default separator as a literal regex
Location: src/tac.zig:95-98
Problem: Our code returns exit 2 (misuse) whenever -r is passed.
  GNU tac -r uses the separator (default "\n") as a BRE regex
  and exits 0 on valid patterns. With no -s, -r on "a\nb\nc\n"
  produces the same output as plain tac (because "\n" as a BRE
  matches "\n"). This is a SHOULD flag per the spec table.
  Returning exit 2 for a recognized flag is non-compliant.
Fix: Either implement BRE regex matching for the separator (the
  full fix), or at minimum do not error when -r is passed with
  the default separator and the regex matches the same as
  literal newline split (acceptable stopgap). A proper fix
  requires linking a POSIX regex library or using Zig's RE2
  bindings, which may be a larger effort. If full implementation
  is deferred, the error message should use exit 1 (general
  error) not exit 2 (misuse), and say "not yet implemented"
  rather than "not supported" (which implies it will never be).
```

```
[IMPORTANT] Error messages use @errorName instead of POSIX
  strings
Location: src/tac.zig:128
Problem: File open errors print "tac: /path: FileNotFound"
  instead of GNU's "tac: failed to open '/path' for reading:
  No such file or directory". Scripts that parse tac error
  output will not match. Other utilities in this project have
  the same pattern but it is worth flagging consistently.
Fix: Map the Zig error code to a POSIX string, e.g.:
    const msg = switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        else => @errorName(err),
    };
    common.printErrorWithProgram(allocator, stderr_writer,
        "tac", "failed to open '{s}' for reading: {s}",
        .{ file_path, msg });
```

```
[IMPORTANT] Integration test -b expected value is wrong
Location: tests/utilities/tac_test.sh:62
Problem: The test expects $'\nline3\nline2\nline1' but GNU
  produces $'\n\nline3\nline2line1'. The test currently passes
  only because both the code and test are wrong in the same way.
Fix: Update the expected string after fixing the code.
```

```
[SUGGESTION] reverseByStringSeparator passes sep_byte=0 to
  writeRecordsReversed, silently disabling -b
Location: src/tac.zig:213
Problem: The call passes sep_byte=0 as a sentinel meaning "no
  byte separator", but writeRecordsReversed checks
  `sep_byte != 0` to decide whether to move the separator in
  -b mode (line 237). For multi-byte separators, -b is
  completely inert. This will be resolved by the -b algorithm
  fix above, which should pass the full separator string.
Fix: Addressed by the -b fix. No separate change needed if
  writeRecordsReversed is rewritten to take a []const u8
  separator.
```

```
[SUGGESTION] "tac reverses lines without trailing newline"
  unit test expected value looks wrong
Location: src/tac.zig:352-353
Problem: Input "line1\nline2\nline3" (no trailing newline).
  Expected: "line3line2\nline1\n". This is the current output
  but it is worth verifying against GNU:
    printf 'a\nb\nc' | tac -> "cb\na\n"
  which matches. The test is correct as-is (GNU behavior
  confirmed). Leaving as a note that this counter-intuitive
  output is intentional.
Fix: No change needed.
```

---

## Test Coverage Assessment

17 unit tests cover: help/version flags, unknown flag error, -r
rejection, basic reversal, single/empty/no-newline file, custom
separator (single-byte and multi-byte), -b flag, multiple files,
nonexistent file, and internal functions reverseByByteSeparator
(3 cases) and reverseByStringSeparator (1 case).

Coverage gaps:
- `-b` with multi-byte separator (untested; currently wrong)
- `-b` with empty trailing record (tests with trailing-newline
  input happen to hit this but assert wrong output)
- `-s` with empty string separator (NUL-split) is tested in unit
  tests only implicitly via the code path; no explicit stdin test
- stdin via "-" filename is not unit-tested
- Read error mid-stream (partial read failure) has no test

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Fix -b algorithm in writeRecordsReversed
   — src/tac.zig:218 (also reverseByStringSeparator:213)
2. [CRITICAL] Update unit tests to assert correct -b output
   — src/tac.zig:435 and src/tac.zig:509
3. [IMPORTANT] Update integration test -b expected value
   — tests/utilities/tac_test.sh:62
4. [IMPORTANT] Fix -r to not error with exit 2 on a valid
   (if unimplemented) flag — src/tac.zig:95
5. [IMPORTANT] Use POSIX error strings for file open failures
   — src/tac.zig:128
```

State: "REVIEW COMPLETE - NEEDS_FIXES"
