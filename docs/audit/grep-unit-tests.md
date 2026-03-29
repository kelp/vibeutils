# Unit Test Audit: grep

**Date**: 2026-03-28
**Source**: `src/grep.zig`
**Test runner result**: 1783/1802 tests passed (suite-wide); all grep
tests pass

---

## Executive Summary

**PASS WITH ISSUES**

The grep unit tests are largely well-structured. Most tests use
`testRunGrepOutput()` to exercise real program output, and the file
avoids all stdin-hang risk by always passing explicit file paths. The
bulk of the MUST-tier flags have behavioral coverage. However, a large
cluster of tests — primarily covering SHOULD-tier stub flags — are
pure parse-only tests that cannot detect behavioral regressions.
Several MUST-tier flags also lack behavioral verification, and
`-w`/`--word-regexp` has no test of any kind.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|----------------|---------|
| `parseArgs basic pattern` | No — struct field only | PARSING |
| `parseArgs pattern and files` | No — struct fields only | PARSING |
| `parseArgs -e multiple patterns` | No — struct fields only | PARSING |
| `parseArgs -e with files` | No — struct fields only | PARSING |
| `parseArgs short flags` | No — struct fields only | PARSING |
| `parseArgs long flags` | No — struct fields only | PARSING |
| `parseArgs regex modes` | No — struct fields only | PARSING |
| `parseArgs -m max-count` | No — struct field only | PARSING |
| `parseArgs context flags` | No — struct fields only | PARSING |
| `parseArgs color modes` | No — struct fields only | PARSING |
| `parseArgs -- separator` | No — struct fields only | PARSING |
| `parseArgs invalid option returns null` | Partial — exit path only | PARSING |
| `parseArgs --include and --exclude` | No — struct fields only | PARSING |
| `fixed string matching` | Yes — matchLine output | BEHAVIOR |
| `fixed string no match` | Yes — matchLine output | BEHAVIOR |
| `fixed string case insensitive` | Yes — matchLine output | BEHAVIOR |
| `regex matching basic` | Yes — matchLine output | BEHAVIOR |
| `regex no match` | Yes — matchLine output | BEHAVIOR |
| `toLower conversion` | Yes — function output | BEHAVIOR |
| `toLower empty string` | Yes — function output | BEHAVIOR |
| `runGrep no pattern returns misuse` | Partial — exit code only | BEHAVIOR |
| `runGrep --help returns success` | Partial — exit code only | BEHAVIOR |
| `runGrep --version returns success` | Partial — exit code only | BEHAVIOR |
| `runGrep with file` | Yes — exit code from file | BEHAVIOR |
| `runGrep no match returns 1` | Yes — exit code | BEHAVIOR |
| `runGrep -c count mode` | Partial — exit code only | STUB |
| `runGrep -v invert match` | Partial — exit code only | STUB |
| `runGrep -F fixed strings` | Partial — exit code only | STUB |
| `runGrep -E extended regex` | Partial — exit code only | STUB |
| `runGrep nonexistent file returns error` | Yes — exit code | BEHAVIOR |
| `runGrep -q quiet mode match` | Yes — exit code | BEHAVIOR |
| `runGrep -q quiet mode no match` | Yes — exit code | BEHAVIOR |
| `runGrep invalid regex returns misuse` | Yes — exit code | BEHAVIOR |
| `runGrep -m max-count` | Partial — exit code only | STUB |
| `parseArgs -b sets byte_offset` | No — struct field only | PARSING |
| `parseArgs --byte-offset sets byte_offset` | No — struct field only | PARSING |
| `parseArgs -a flag accepted (no-op)` | No — pattern count only | PARSING |
| `parseArgs --text flag accepted (no-op)` | No — pattern count only | PARSING |
| `parseArgs -I flag accepted (no-op)` | No — pattern count only | PARSING |
| `parseArgs -U flag accepted (no-op)` | No — pattern count only | PARSING |
| `parseArgs --binary flag accepted (no-op)` | No — pattern count only | PARSING |
| `runGrep -b prints byte offset` | Yes — output content | BEHAVIOR |
| `runGrep -b -n prints line number then byte offset` | Yes — output content | BEHAVIOR |
| `runGrep -b -c prints only count` | Yes — output content | BEHAVIOR |
| `runGrep -b multiple matches` | Yes — output content | BEHAVIOR |
| `parseArgs -Z sets null_data` | No — struct field only | PARSING |
| `parseArgs --null sets null_data` | No — struct field only | PARSING |
| `runGrep -lZ uses NUL byte after filename` | Yes — output bytes | BEHAVIOR |
| `runGrep -l without -Z uses newline after filename` | Yes — output bytes | BEHAVIOR |
| `parseArgs -J flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -M flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -O flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -p flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -S flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -u flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -X flag accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -D flag accepted (stub)` | No — pattern count only | PARSING |
| `parseArgs -D skip accepted (stub)` | No — pattern count only | PARSING |
| `parseArgs --line-buffered accepted (no-op)` | No — pattern count only | PARSING |
| `parseArgs --binary-files=text accepted (stub)` | No — pattern count only | PARSING |
| `parseArgs --binary-files=without-match accepted (stub)` | No — pattern count only | PARSING |
| `parseArgs --mmap accepted (no-op)` | No — pattern count only | PARSING |
| `parseArgs --include-dir=PATTERN accepted (no-op stub)` | No — pattern count only | PARSING |
| `parseArgs -y sets ignore_case (alias for -i)` | No — struct field only | PARSING |
| `runGrep -y case insensitive match` | Yes — exit code | BEHAVIOR |
| `parseArgs -P returns null (error stub)` | Partial — null return | PARSING |
| `runGrep -P returns misuse exit code` | Yes — exit code | BEHAVIOR |
| `parseArgs -d recurse sets recursive` | No — struct field only | PARSING |
| `parseArgs -d skip sets skip_dirs` | No — struct field only | PARSING |
| `parseArgs -d read is default (no change)` | No — struct fields only | PARSING |
| `runGrep -d skip silently skips directories` | Yes — output content | BEHAVIOR |
| `parseArgs -z sets null_line_sep` | No — struct field only | PARSING |
| `parseArgs --null-data sets null_line_sep` | No — struct field only | PARSING |
| `runGrep -z splits on NUL and terminates with NUL` | Yes — output bytes | BEHAVIOR |
| `parseArgs --label=LABEL sets stdin_label` | No — struct field only | PARSING |
| `runGrep -HZ uses NUL after filename in normal output` | Yes — output bytes | BEHAVIOR |
| `runGrep -cZ uses NUL after filename in count output` | Yes — output bytes | BEHAVIOR |
| `processFile reads multi-line file and returns correct matches` | Yes — output content | BEHAVIOR |
| `processFile reads file with many lines and matches selectively` | Yes — output content | BEHAVIOR |
| `runGrep -f pattern file does not leak file contents buffer` | Partial — leak detection | BEHAVIOR |

**Total**: 74 tests — 35 BEHAVIOR, 35 PARSING, 4 STUB (exit-code-only
for flags that affect output)

---

## Filter Utility Check

**No stdin hang risk.** grep is a filter utility, but the unit
tests never call `runGrep` without a file argument. Both `testRunGrep`
and `testRunGrepOutput` create a temp file and pass its path as the
last argument. There is no test that exercises the stdin code path at
all — which is itself a coverage gap (see below).

`runUtilWithInput()` is not used here; the approach taken (always
passing a temp file) achieves the same safety guarantee and is
consistent with grep's hybrid identity as both a filter and a
file-processor.

---

## Parse-Only Tests (CRITICAL)

The tests below check only that `parseArgs` populates a struct field.
They assert `parsed.flag == true` or `opts.patterns.items.len == 1`
without running the program. If the flag were parsed correctly but
then completely ignored in `processFile` or `runGrep`, these tests
would still pass.

**[CRITICAL] 35 stub/parsing tests cannot detect behavioral regressions**

The most consequential pure-parse stubs for implemented (non-no-op)
flags are:

```
[CRITICAL] parseArgs short flags — asserts opts.ignore_case/invert_match/
           line_number from -ivn but never runs grep
Location:  src/grep.zig:1221

[CRITICAL] parseArgs long flags — asserts opts.count/recursive from
           --count/--recursive but never runs grep
Location:  src/grep.zig:1231

[CRITICAL] parseArgs regex modes — asserts opts.regex_mode from
           -E/-F/-G but never runs grep
Location:  src/grep.zig:1241

[CRITICAL] parseArgs context flags — asserts before_context/after_context
           from -A/-B/-C but never runs grep
Location:  src/grep.zig:1270

[CRITICAL] parseArgs --include and --exclude — asserts glob arrays are
           populated but never tests that files are actually filtered
Location:  src/grep.zig:1330
```

The SHOULD-tier stub-flag parse tests (`-J`, `-M`, `-O`, `-p`, `-S`,
`-u`, `-X`, `-D`, `--line-buffered`, `--binary-files=*`, `--mmap`,
`--include-dir`) are pure acceptance tests. They are appropriate for
no-op stubs and are less concerning, but see "Other Issues" below.

---

## Behavioral Stubs (IMPORTANT)

These tests use `testRunGrep` but only check the exit code. They
exercise the right code path but cannot detect output format
regressions:

```
[IMPORTANT] runGrep -c count mode — does not verify the count printed
Location:  src/grep.zig:1478
Problem:   -c could print "2\n" or "2 matches\n" or garbage and this
           test would pass as long as the exit code is 0.
Fix:       Use testRunGrepOutput and assert the count string.

[IMPORTANT] runGrep -v invert match — does not verify which lines printed
Location:  src/grep.zig:1483
Problem:   Could print matched lines (wrong behavior) with exit 0 and
           the test would pass.
Fix:       Use testRunGrepOutput and assert only non-matching lines appear.

[IMPORTANT] runGrep -F fixed strings — does not verify literal dot
           behavior
Location:  src/grep.zig:1488
Problem:   The key contract of -F is that '.' is not a wildcard.
           This test only checks that a match was found — it does not
           verify a line like "helloXworld" was NOT matched.
Fix:       Use testRunGrepOutput with both a literal-match line and a
           regex-match-only line; assert only the literal match appears.

[IMPORTANT] runGrep -E extended regex — does not verify ERE-specific
           behavior (alternation, +, ?, {n,m})
Location:  src/grep.zig:1493
Problem:   Could fall back to BRE and still exit 0 on simple patterns.
Fix:       Use a pattern that only works as ERE (e.g., 'hel+o|world')
           and verify both matches appear in output.

[IMPORTANT] runGrep -m max-count — does not verify early stop
Location:  src/grep.zig:1524
Problem:   If -m is silently ignored and all 4 lines match, exit is
           still 0.
Fix:       Use testRunGrepOutput and assert exactly N lines appear.
```

---

## Missing Coverage

### MUST-tier flags with no behavioral test

| Flag | Has Any Test? | Test Type | Notes |
|------|--------------|-----------|-------|
| `-w` / `--word-regexp` | No | None | No test at all — not in unit tests or integration tests |
| `-n` / `--line-number` | Parse only | PARSING | No output verification |
| `-i` / `--ignore-case` | Parse only (unit) | PARSING | Integration test covers it |
| `-G` / `--basic-regexp` | Parse only | PARSING | No behavioral test for BRE-specific syntax |
| `-H` / `--with-filename` | Only via -HZ | BEHAVIOR | The NUL test incidentally exercises -H |
| `-h` / `--no-filename` | No unit test | None | Integration test only |
| `-s` / `--no-messages` | No unit test | None | Integration test only |
| `-x` / `--line-regexp` | No unit test | None | Integration test only |
| `-l` / `--files-with-matches` | Only via -lZ | BEHAVIOR | Newline variant tested, no output-content test |
| `-L` / `--files-without-match` | No unit test | None | Integration test only |
| `-e` multiple | Parse only | PARSING | No test that two `-e` patterns each match different lines |
| `-f` | Leak-detection only | BEHAVIOR | Does not verify correct lines are matched |

### SHOULD-tier flags with no behavioral test (non-stub)

| Flag | Notes |
|------|-------|
| `--label` | Parse-only test; no test that label appears in output |
| `-z` / `--null-data` | Has behavioral test — covered |
| `-r` / `-R` | Integration test only for recursion |

### Untested code path: stdin

No unit test exercises the stdin path (no file arguments, or `-` as a
file argument). The `processFile` function is called with
`std.fs.File.stdin()` in two code paths in `runGrep` (lines 1106 and
1116). A hang here would only surface in integration tests or
production, not unit tests.

---

## Other Issues

### Memory: `testRunGrepOutput` arena is not backed by `testing.allocator`

```
[IMPORTANT] testRunGrepOutput leaks arena without testing.allocator backing
Location:  src/grep.zig:1530-1554
Problem:   The helper creates `std.heap.ArenaAllocator.init(testing.allocator)`
           and returns the arena to the caller for deferred deinit. This
           pattern is correct IF every caller calls `result.arena.deinit()`.
           All current callers do call `defer result.arena.deinit()`, so
           there is no current leak. But the return-arena-to-caller idiom
           is fragile — a future test that forgets the defer will silently
           leak. Consider wrapping with a helper that takes a callback or
           documents the contract explicitly.
Fix:       Add a comment to testRunGrepOutput: "Caller MUST call
           result.arena.deinit() to free all allocations."
```

### `-w` / `--word-regexp`: zero test coverage

```
[IMPORTANT] -w has no unit test and no integration test
Location:  src/grep.zig:282 (parseArgs), src/grep.zig:481 (compilePattern)
Problem:   The word-regexp wrapping logic in compilePattern uses different
           BRE/ERE syntax and is non-trivial. There is no test that
           "cat" matches "the cat sat" but not "concatenate".
Fix:       Add unit test using testRunGrepOutput:
           - "cat" with -w matches "the cat sat" but not "concatenate"
           - "foo" with -w does not match "foobar" or "barfoo"
           Add integration test in grep_test.sh.
```

### `-n` / `--line-number`: only integration-tested

```
[SUGGESTION] -n has no unit test verifying output format
Location:  src/grep.zig:1221 (parse only)
Problem:   The integration test in grep_test.sh covers -n, but there is
           no unit test that captures output and verifies the "N:line"
           format. If the separator changed from ':' to something else,
           unit tests would not catch it.
Fix:       Add a testRunGrepOutput test: grep -n on known content,
           assert "2:hello" format.
```

### `-c` output format: integration-tested but unit-stub only

```
[SUGGESTION] runGrep -c count mode tests exit code but not output
Location:  src/grep.zig:1478
Problem:   Described above under behavioral stubs. Integration test
           in grep_test.sh verifies "2" output, so this is not a
           complete gap — but unit coverage would catch regressions
           faster.
```

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| G-01 | CRITICAL | 35 tests are parse-only and cannot detect behavioral regressions for implemented flags |
| G-02 | CRITICAL | `-w` / `--word-regexp` has zero test coverage (no unit, no integration) |
| G-03 | IMPORTANT | `runGrep -c`, `-v`, `-F`, `-E`, `-m` only check exit code; output format untested in unit tests |
| G-04 | IMPORTANT | `-n` / `--line-number` format (`N:line`) only integration-tested, not unit-tested |
| G-05 | IMPORTANT | stdin code path has no unit test coverage |
| G-06 | IMPORTANT | `-f` unit test only checks for leaks; does not verify matched lines |
| G-07 | IMPORTANT | `testRunGrepOutput` returns arena to caller — fragile pattern with silent leak risk if future callers omit `defer` |
| G-08 | SUGGESTION | `-L`, `-h`, `-s`, `-x` have no unit tests (integration-only) |
| G-09 | SUGGESTION | `-e` multiple patterns has no behavioral test verifying both patterns independently match |
| G-10 | SUGGESTION | `--label` parse test only; no test that label appears in output when stdin is searched |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -w has no tests at all — src/grep.zig (compilePattern ~line 481)
2. [CRITICAL] parseArgs short/long/regex/context/include tests only check
   struct fields — add runGrep behavioral counterparts
3. [IMPORTANT] runGrep -c/-v/-F/-E/-m: switch from exit-code-only to
   testRunGrepOutput with output content assertions
4. [IMPORTANT] runGrep -n: add testRunGrepOutput test asserting "N:line" format
5. [IMPORTANT] Stdin path: add a unit test using a temp file passed as "-"
6. [IMPORTANT] runGrep -f: add output-content assertion to the existing leak test
7. [SUGGESTION] -L/-h/-s/-x: add behavioral unit tests
8. [SUGGESTION] -e multiple: add test verifying two independent patterns each match
9. [SUGGESTION] --label: add test that label appears in -H output for stdin
```

---

**REVIEW COMPLETE - NEEDS_FIXES**
