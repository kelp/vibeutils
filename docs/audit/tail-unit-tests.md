# tail Unit Test Audit

**Date:** 2026-03-28
**File:** `src/tail.zig`
**Total tests:** 45
**Result:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Flags covered |
|---|-----------|------|---------------|
| 1 | tail outputs default 10 lines | Behavioral | default -n 10 |
| 2 | tail with -n 5 outputs last 5 lines | Behavioral | -n |
| 3 | tail with -n 0 outputs nothing | Behavioral | -n 0 |
| 4 | tail with -c 10 outputs last 10 bytes | Behavioral | -c |
| 5 | tail with -c 0 outputs nothing | Behavioral | -c 0 |
| 6 | tail handles line count larger than file | Behavioral | -n |
| 7 | tail handles byte count larger than file | Behavioral | -c |
| 8 | tail handles empty file | Behavioral | default |
| 9 | tail handles file with no final newline | Behavioral | -n |
| 10 | tail handles very long lines | Behavioral | -n |
| 11 | tail with multiple files shows headers by default | Parse-only stub | multi-file |
| 12 | tail with -q suppresses headers for multiple files | Parse-only stub | -q |
| 13 | tail with -v always shows headers | Parse-only stub | -v |
| 14 | tail handles non-existent file | Error path | error |
| 15 | tail with -z handles zero-terminated lines | Behavioral | -z |
| 16 | tail with binary file in byte mode | Behavioral | -c |
| 17 | parseNumericArg with valid numbers | Unit | internal |
| 18 | parseNumericArg with suffixes | Unit | internal |
| 19 | parseNumericArg with plus prefix | Unit | internal |
| 20 | tail -n +1 outputs entire file (from-beginning) | Behavioral | -n +NUM |
| 21 | tail -n +3 skips first 2 lines (from-beginning) | Behavioral | -n +NUM |
| 22 | tail -n +NUM larger than file outputs nothing | Behavioral | -n +NUM |
| 23 | tail -n +NUM detected via runTail arg parsing | Behavioral | -n +NUM |
| 24 | parseNumericArg with invalid input | Unit | internal |
| 25 | tail shouldShowHeaders logic | Unit | -q/-v logic |
| 26 | tail help output | Behavioral | --help |
| 27 | tail version output | Behavioral | --version |
| 28 | tail with invalid line count | Behavioral | error path |
| 29 | tail with invalid byte count | Behavioral | error path |
| 30 | tail with obsolete -NUM syntax | Behavioral | legacy syntax |
| 31 | tail: -f flag is parsed | Parse-only | -f |
| 32 | tail: -F flag is parsed | Parse-only | -F |
| 33 | tail: -f with nonexistent file gives error | Behavioral | -f error |
| 34 | tail: -F skips nonexistent files in initial processing | Parse-only stub | -F |
| 35 | tail: help output mentions -f and -F flags | Weak behavioral | --help |
| 36 | tail: -b flag is parsed | Parse-only | -b |
| 37 | tail: -b 2 shows last 1024 bytes | Behavioral | -b |
| 38 | tail: -b +2 shows from byte 512 onwards | Behavioral | -b +NUM |
| 39 | tail: -b with file shorter than block count shows everything | Behavioral | -b |
| 40 | tail: -r flag is parsed | Parse-only | -r |
| 41 | tail: -r reverses all lines of a file | Behavioral | -r |
| 42 | tail: -r -n 3 reverses last 3 lines | Behavioral | -r -n |
| 43 | tail: -r on single-line file | Behavioral | -r |
| 44 | tail: -f and -r are mutually exclusive | Behavioral | -f -r conflict |
| 45 | tail: -f with nonexistent file returns error | Behavioral | -f error |

**Parse-only stubs:** 5 (#11, #12, #13, #31, #40)
**Weak stubs (parse-only disguised as behavioral):** 2 (#32, #34)
**Strong behavioral tests:** 38

---

## Stdin Hang Risk

tail is a filter utility. When no files are given, `runTail` calls
`processStdin`, which reads from real stdin. **No unit test calls
`runTail` with zero positional arguments.** All tests that call
`runTail` either pass file paths or expect an error on a
nonexistent path. The stdin code paths are therefore never
exercised in the unit suite.

The test suite ran in ~51 seconds (versus 10–100ms for every other
module). This is abnormal. The most likely cause is the `-f` test
at line 1554 or 1752 blocking on `followFile`, which calls
`inotify_init1` and then loops. Both tests pass nonexistent paths
so `followFile` is never entered — but the delay is still
unexplained and warrants investigation.

---

## Issues

```
[CRITICAL] processInputByLines (stdin path) has zero unit-test
           coverage
Location: src/tail.zig:1022
Problem:  processInputByLinesFromFile is tested via testTailFile.
          processInputByLines — the stream/stdin variant used when no
          file handle is available — is never called by any test.
          Bugs in ring-buffer line handling for stdin would be
          invisible.
Fix:      Add a runTailWithInput() helper that accepts a FixedBufferStream
          (or equivalent) as stdin. Then add behavioral tests for:
            - default 10-line stdin output
            - -n N on stdin
            - -c N on stdin (exercises processInputByBytesNoSeek
              circular buffer, also uncovered)
            - -n +N from-beginning on stdin
            - -r on stdin (processInputByLines null line_count path)
```

```
[CRITICAL] processInputByBytesNoSeek (circular buffer for stdin/
           pipes) has zero test coverage
Location: src/tail.zig:735
Problem:  This function holds the core ring-buffer logic for byte
          mode on non-seekable input. It is never called by any test
          because all byte-mode tests supply a real file (which takes
          the seek path instead). A bug in the circular buffer wrap-
          around logic would go undetected.
Fix:      Cover via runTailWithInput() stdin tests with -c N on
          input larger than N bytes (triggers wrap-around) and
          smaller than N bytes (no wrap).
```

```
[IMPORTANT] -q behavioral output never verified
Location: src/tail.zig:1306–1309
Problem:  Test #12 passes -q with two nonexistent files and checks
          only the exit code (1). It does not verify that the header
          "==> filename <==" is absent. The shouldShowHeaders() logic
          unit test (#25) checks the return value but never observes
          actual output.
Fix:      Create two real test files, run runTail with -q and two
          file args, capture stdout, assert no "==>" appears.
```

```
[IMPORTANT] -v behavioral output never verified
Location: src/tail.zig:1312–1315
Problem:  Test #13 passes -v with a nonexistent file and checks only
          that the exit code is 1. No test verifies that a header IS
          printed when -v is used with a single existing file.
Fix:      Create a real test file, run runTail with -v, capture
          stdout, assert "==>" header is present.
```

```
[IMPORTANT] -F parse-only stub conceals untested behavior
Location: src/tail.zig:1564–1577
Problem:  Test #34 is labeled "skips nonexistent files in initial
          processing" but only checks parsed.follow_retry is true and
          adds a prose comment about where the code path lives. It
          does not call runTail and does not verify that a missing
          file is silently skipped rather than erroring. The
          FileNotFound-continue branch (line ~256) is never exercised
          by the unit suite.
Fix:      Call runTail with ["-F", "/nonexistent/file"] and verify
          exit code 0 (not 1).
```

```
[IMPORTANT] -z behavioral test covers only file path, not stdin
Location: src/tail.zig:1329
Problem:  The -z test exercises processInputByLinesFromFile with
          zero terminators. processInputByLines (the stdin variant)
          passes zero_terminated to a different code path. No test
          covers -z on stdin input.
Fix:      Add a stdin test with NUL-delimited input once the stdin
          test infrastructure exists.
```

```
[IMPORTANT] -r not tested on stdin
Location: src/tail.zig:1686
Problem:  -r tests (#41–43) all use testTailFile, exercising
          processInputByLinesFromFile. processInputByLines has a
          separate -r/null line_count code path (line 1064) that is
          never tested.
Fix:      Add stdin -r test once stdin test infrastructure exists.
```

```
[SUGGESTION] Slow test suite (~51 seconds) needs investigation
Location: src/tail.zig (entire test binary)
Problem:  The tail test binary takes ~51 seconds to pass 45 tests,
          while every other module runs in under 200ms. The most
          likely candidate is a test that indirectly touches a timed
          sleep. Thread.sleep(ns_per_s) at lines 491 and 530 is only
          reachable from followFile, which is only entered when a file
          exists and follow mode is active — not the case in any
          current test. The source of the delay is unknown; it may
          mask a test that is sleeping unnecessarily or performing
          repeated I/O.
Fix:      Run `zig build test -- test.filter tail` with verbose output
          or instrument each test with timestamps to isolate the slow
          test(s).
```

```
[SUGGESTION] -c +N (from-beginning bytes) has no stdin test
Location: src/tail.zig:638
Problem:  -c +N via file exercises processInputByBytesFromBeginning
          with the seekable branch. The stream branch
          processInputByBytesFromBeginningStream is uncovered.
Fix:      Add stdin test with -c +N once stdin infrastructure exists.
```

```
[SUGGESTION] Multi-file header format not verified
Location: src/tail.zig:265–268
Problem:  The "==> filename <==" format is specified in the man page.
          No unit test verifies the exact header string format for
          multiple files with real content.
Fix:      Create two real test files, run with both as args, assert
          header format exactly matches "==> <filename> <==".
```

---

## Flag Coverage Summary

| Flag | Tier | Parse tested | Behavior tested | Notes |
|------|------|-------------|-----------------|-------|
| -n | MUST | yes | yes | from-beginning (+N) covered |
| -c | MUST | yes | yes (file only) | stdin/NoSeek path uncovered |
| -f | MUST | yes | partial | error path tested; follow loop untestable |
| -b | MUST | yes | yes | all three sub-cases covered |
| -r | MUST | yes | yes (file only) | stdin path uncovered |
| -q | SHOULD | yes | NO | only exit-code stub |
| -v | SHOULD | yes | NO | only exit-code stub |
| -F | SHOULD | yes | partial | skip-missing-file branch untested |
| -z | SHOULD | yes | yes (file only) | stdin path uncovered |

---

## Summary

**CRITICAL:** 2
**IMPORTANT:** 5
**SUGGESTION:** 3

**Assessment: NEEDS_FIXES**

The file-based test coverage is solid. The fundamental gap is that
`processInputByLines` and `processInputByBytesNoSeek` — the two code
paths used when tail reads from stdin — are completely untested. All
behavioral tests route through `testTailFile`, which opens a real
file, bypassing both stdin functions. Fix these first by adding a
`runTailWithInput()` helper; the IMPORTANT issues for -q, -v, and
-F then fall out of the same infrastructure.

**Fix Order:**

1. [CRITICAL] Add stdin test infrastructure (runTailWithInput) and
   cover processInputByLines basic cases — src/tail.zig
2. [CRITICAL] Add processInputByBytesNoSeek coverage via stdin -c N
   tests, including wrap-around case — src/tail.zig
3. [IMPORTANT] Replace -q stub with real output-content assertion
   — src/tail.zig:1306
4. [IMPORTANT] Replace -v stub with real output-content assertion
   — src/tail.zig:1312
5. [IMPORTANT] Replace -F stub with runTail call verifying exit 0
   on missing file — src/tail.zig:1564
6. [IMPORTANT] Add -z and -r stdin tests once infrastructure exists
   — src/tail.zig
7. [SUGGESTION] Investigate ~51s test binary runtime — src/tail.zig
8. [SUGGESTION] Add -c +N stdin test (stream branch) — src/tail.zig
9. [SUGGESTION] Add multi-file header format assertion — src/tail.zig
