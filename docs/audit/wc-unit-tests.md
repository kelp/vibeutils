---
date: 2026-03-28
utility: wc
audit_type: unit_tests
result: NEEDS_FIXES
tests_passed: 31/31
---

# wc Unit Test Audit

Date: 2026-03-28
File: `src/wc.zig`
Test count: 31 tests, all pass

## Stdin Hang Risk Assessment

**No hang risk.** All `countReader` tests pass a real
`file.reader()` backed by a `tmpDir` file. No test calls
`runWc` without file arguments, so no test touches
`std.fs.File.stdin()`. The filter-utility hang pattern
does not apply here.

## Test Inventory

| # | Test Name | Category | Behavioral? |
|---|-----------|----------|-------------|
| 1 | wc counts lines correctly | countReader | Yes |
| 2 | wc counts words correctly | countReader | Yes |
| 3 | wc counts bytes correctly | countReader | Yes |
| 4 | wc counts UTF-8 characters correctly | countReader | Yes |
| 5 | wc finds maximum line length | countReader | Yes |
| 6 | wc handles empty input | countReader | Yes |
| 7 | wc handles input without final newline | countReader | Yes |
| 8 | wc counts multiple whitespace correctly | countReader | Yes |
| 9 | wc handles all counts together | countReader | Yes |
| 10 | wc addStats combines statistics correctly | addStats | Yes |
| 11 | wc output formatting | printStats | Yes |
| 12 | wc runWc with default options | runWc | Yes |
| 13 | wc with multiple files shows total | runWc | Yes |
| 14 | wc --help shows usage | runWc | Yes |
| 15 | wc --version shows version | runWc | Yes |
| 16 | wc reports error for directory | runWc | Yes |
| 17 | resolveConfig defaults: color off in test (no TTY) | config | Yes |
| 18 | resolveConfig --color=always sets display.color on | config | Yes |
| 19 | resolveConfig --color=never sets display.color off | config | Yes |
| 20 | resolveConfig --color=invalid returns error | config | Yes |
| 21 | applyWcColumnColor truecolor: lines | style | Yes |
| 22 | applyWcColumnColor truecolor: words | style | Yes |
| 23 | applyWcColumnColor truecolor: bytes_chars | style | Yes |
| 24 | applyWcColumnColor truecolor: max_line_length | style | Yes |
| 25 | applyWcColumnColor basic: lines uses cyan | style | Yes |
| 26 | applyWcColumnColor basic: words uses green | style | Yes |
| 27 | applyWcColumnColor basic: bytes_chars uses yellow | style | Yes |
| 28 | applyWcColumnColor basic: max_line_length uses magenta | style | Yes |
| 29 | applyWcColumnColor none: no output | style | Yes |
| 30 | wc --libxo prints error and exits with code 1 | runWc | Yes |
| 31 | wc --color=invalid exits with code 2 | runWc | Yes |

No parse-only stubs found. Every test either runs
`countReader` against real file data, calls `runWc` end-to-end,
or asserts byte output from `printStats`/`applyWcColumnColor`.

---

## Issues

### IMPORTANT

---

**[IMPORTANT] -c/-m mutual exclusion is not directly unit tested**
Location: `src/wc.zig:182-208`
Problem: The "last flag wins" logic for combined `-cm`/`-mc`
combined flags and separate `--bytes`/`--chars` is untested
at the unit level. No `runWc` test passes both `-c` and `-m`
together to verify which one survives. A regression in that
scan loop would go undetected.
Fix: Add tests covering at least three cases:
- `runWc` with `["-c", "-m"]` — chars should win
- `runWc` with `["-m", "-c"]` — bytes should win
- `runWc` with `["-cm"]` — chars should win (last in combined
  form)

---

**[IMPORTANT] Unknown flag / bad arg exit-code untested**
Location: `src/wc.zig:146-161`
Problem: `error.UnknownFlag` and `error.MissingValue` paths
return `ExitCode.misuse` (exit code 2). No unit test calls
`runWc` with an invalid flag to confirm the exit code and
error message. Integration tests may cover this, but
unit-level regression is absent.
Fix: Add two `runWc` tests:
- `&[_][]const u8{"--bogus"}` — expect exit code 2 and
  "invalid option" on stderr
- `&[_][]const u8{"--color"}` (missing value) — expect
  exit code 2 and "option requires an argument" on stderr

---

**[IMPORTANT] stdin path (`-` positional) is untested**
Location: `src/wc.zig:245-251`
Problem: When a positional argument equals `"-"`, `runWc`
reads from `std.fs.File.stdin()`. No unit test exercises
this branch. The argument is intentionally avoided to
prevent hangs, but the branch is structurally distinct
from the file path and the skip is undocumented.
Fix: Add a comment at the test section noting that the `-`
stdin branch is intentionally excluded from unit tests
because it requires a real stdin pipe. Add an integration
test to `tests/utilities/wc.sh` for `echo "foo" | wc -`.

---

**[IMPORTANT] runWc with only `-l`, `-w`, `-m`, or `-L`
  (non-default single-flag) not tested at runWc level**
Location: `src/wc.zig:646-706`
Problem: The two `runWc`-level behavioral tests (default
options and multiple files) only exercise the default
lines/words/bytes combination. The individual flag paths
(`-l`, `-w`, `-m`, `-L`, and `--max-line-length`) through
`runWc` are not covered; formatting differences and field
ordering bugs could go undetected.
Fix: Add one `runWc` test per non-default flag confirming
that only the correct column appears in stdout. For example,
`runWc` with `["-l", path]` should produce a line with a
single number and the filename, with no extra columns.

---

### SUGGESTION

---

**[SUGGESTION] `applyWcColumnColor` extended (256-color)
  mode is not tested**
Location: `src/wc.zig:97-109`
Problem: The `extended` branch of `applyWcColumnColor`
(256-color) has no corresponding unit test. The four
truecolor tests and four basic tests are mirrored, but
256-color coverage is absent.
Fix: Add four tests mirroring the truecolor tests with
`color_mode = .extended`, asserting the `\x1b[38;5;NNNm`
escape sequences.

---

**[SUGGESTION] `wc --version` test is underspecified**
Location: `src/wc.zig:720-730`
Problem: The version test checks that the output contains
`"wc"` and `common.version`, but not that the full string
`"wc (vibeutils) X.Y.Z\n"` is present. A regression that
adds junk before `"wc"` or changes the format would pass.
Fix: Use `expectEqualStrings` against the full expected
string, or at minimum check for the exact prefix
`"wc (vibeutils) "`.

---

**[SUGGESTION] `wc output formatting` test uses `.none` style
  only; no test covers formatted output with color on**
Location: `src/wc.zig:619-644`
Problem: `printStats` is only exercised with
`color_mode = .none`. A regression in the color-on path
of `printStats` (e.g., forgetting to reset after one of
the columns) would not be caught by unit tests.
Fix: Add one `printStats` test with `color_mode = .basic`
and verify that the output contains the expected ANSI
reset sequences around each column.

---

## Summary

31 tests, all pass. 0 parse-only stubs. No stdin hang
risk. The `countReader` and color helper layers are
well-covered. The main gaps are at the `runWc` integration
layer: mutual exclusion of `-c`/`-m`, unknown-flag error
paths, the `-` stdin branch, and single-flag output format
are all untested.

**Fix Order:**
1. [IMPORTANT] -c/-m mutual exclusion — `src/wc.zig:182`
2. [IMPORTANT] Unknown flag / bad arg exit code — `src/wc.zig:146`
3. [IMPORTANT] stdin `-` branch untested (add comment +
   integration test) — `src/wc.zig:245`
4. [IMPORTANT] Single-flag runWc coverage gaps — `src/wc.zig:646`
5. [SUGGESTION] 256-color applyWcColumnColor tests — `src/wc.zig:97`
6. [SUGGESTION] --version format assertion too loose — `src/wc.zig:720`
7. [SUGGESTION] printStats with color enabled — `src/wc.zig:619`

REVIEW COMPLETE - NEEDS_FIXES
