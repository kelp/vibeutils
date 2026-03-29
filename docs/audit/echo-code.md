# echo Code Audit

Date: 2026-03-28
GNU coreutils 9.10 is the primary behavioral reference.
Build: passing. Unit tests: all pass (see echo-unit-tests.md).
Integration tests: 19/19 pass (see echo-integration-tests.md).

---

## Issues

### [SUGGESTION] `echo_test_complex.sh` is a dead file with a wrong assertion

Location: `tests/utilities/echo_test_complex.sh:167`

Problem: The file defines `test_echo()` but is never sourced
by the test runner (which loads `echo_test.sh` by convention).
It therefore has zero test coverage effect. One assertion
inside it is wrong:

```bash
test_command_fails "echo invalid flag" "$binary" --invalid-flag
```

GNU echo treats all unrecognized flags as positional
arguments and exits 0. The assertion expects exit non-zero,
which contradicts GNU behavior and contradicts the correct
test in `echo_test.sh:86-91`. If `echo_test_complex.sh`
were ever activated, this test would fail.

Fix: Either delete `echo_test_complex.sh` entirely, or
correct line 167 to `test_command_output` checking that
`--invalid-flag` is printed as a positional argument, and
then register it with the test runner.

---

### [SUGGESTION] `\u` and `\U` Unicode escapes not implemented

Location: `src/echo.zig:272` (the `else` branch in
`writeWithEscapes`)

Problem: GNU echo with `-e` supports `\uNNNN` (4-hex-digit
Unicode code point) and `\UNNNNNNNN` (8-hex-digit). Our
implementation falls through to the `else` branch and
outputs a literal backslash followed by the `u`.

```
GNU:  echo -e '\u0041'  →  "A"
Ours: echo -e '\u0041'  →  "\u0041"
```

This is a SHOULD-level GNU extension. It does not affect the
MUST flags (`-n`, `-e`, `-E`) but is present in GNU echo and
widely relied upon in scripts.

Fix: Add `'u'` and `'U'` cases in the escape switch that
parse 4 or 8 hex digits respectively, encode the resulting
code point as UTF-8, and write the bytes.

---

### [SUGGESTION] No test coverage for `\a`, `\b`, `\f`, `\v`, `\e` in unit tests

Location: `src/echo.zig` (unit test section)

Problem: The unit test suite covers `\n`, `\t`, `\\`, `\c`,
`\0NNN`, `\NNN`, `\xHH`. The five other single-character
escapes (`\a` BEL, `\b` backspace, `\f` form feed, `\v`
vertical tab, `\e` ESC) are only tested in
`echo_test_complex.sh`, which is never run. None of the
embedded unit tests exercise them.

Fix: Add unit test cases for each of the five escapes in the
`writeWithEscapes` section.

---

## What Is Correct

The core behavior matches GNU closely:

- Flag parsing: only `-n`, `-e`, `-E` (and combinations like
  `-ne`, `-eE`) are recognized as flags; everything else,
  including `--`, `-z`, `--unknown`, is treated as a
  positional argument. Verified correct.
- Once a non-flag argument is encountered, all remaining
  arguments (even flag-shaped) are positional. Correct.
- Last-wins semantics for `-e`/`-E` within a combined flag
  string (e.g., `-eE` disables escapes, `-Ee` enables them).
  Correct.
- `\c` halts all further output including the trailing
  newline, across argument boundaries. Correct.
- `\0NNN`: `\0` is a prefix introducer followed by up to 3
  octal digits; distinct from `\NNN` where the first digit is
  part of the value. Correct.
- `\xH` / `\xHH`: accepts 1 or 2 hex digits. Correct.
- Unknown escape sequence `\q` outputs literal `\q`.
  Matches GNU.
- `--help` and `--version` present (GNU extension). Correct.
- `writerStreaming` I/O pattern used. No `>>` append bug.

---

## Flag Coverage

| Flag | Tier | Status |
|------|------|--------|
| -n | MUST | Correct |
| -e | SHOULD | Correct (core escapes) |
| -E | SHOULD | Correct |
| \uNNNN / \UNNNNNNNN | — | Not implemented (GNU extension) |

---

## Summary

APPROVED (minor suggestions only)

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| IMPORTANT | 0 |
| SUGGESTION | 3 |

Fix Order:
1. [SUGGESTION] Dead `echo_test_complex.sh` with wrong assertion —
   `tests/utilities/echo_test_complex.sh:167`
2. [SUGGESTION] `\u`/`\U` Unicode escapes not implemented —
   `src/echo.zig:272`
3. [SUGGESTION] No unit tests for `\a`/`\b`/`\f`/`\v`/`\e` —
   `src/echo.zig` (test section)
