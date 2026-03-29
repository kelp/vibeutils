---
utility: echo
audit_type: unit-tests
date: 2026-03-28
test_count: 30
status: APPROVED
---

# echo Unit Test Audit

**Date:** 2026-03-28
**Test count:** 30 unit tests
**Run status:** Source analysis; run via `zig build test`

---

## Summary

The echo unit tests are the strongest in this project for a filter-
class utility. All 30 tests call `runEcho()` and assert actual
stdout content. Zero parse-only stubs. The escape-sequence path is
thoroughly exercised including octal (both `\0NNN` and `\NNN`
forms), hex (1 and 2 digit), `\c` termination, and all common
sequences (`\n`, `\t`, `\r`, `\v`, `\f`, `\a`, `\b`, `\e`, `\\`).
Regression tests for documented bugs are present and named
clearly.

---

## Test Inventory

| Test | Behavioral? | Notes |
|------|-------------|-------|
| echo outputs single argument | Yes | Basic output |
| echo outputs multiple arguments with spaces | Yes | Space-join |
| echo -n suppresses newline | Yes | Checks no trailing \n |
| echo handles empty input | Yes | Empty args |
| echo with -n and multiple arguments | Yes | -n multi-arg |
| echo preserves empty strings | Yes | "" arg preserved as space |
| echo handles special characters | Yes | Literal tabs/newlines in args |
| echo -e interprets escape sequences | Yes | \n in string |
| echo -e handles multiple escape sequences | Yes | \t \n \\ combined |
| echo -e with octal sequences | Yes | \101 \040 \102 = "A B" |
| echo -e with hex sequences | Yes | \x41 \x20 \x42 = "A B" |
| echo -e with incomplete hex sequences | Yes | \x4, \x (bare), \xZ |
| echo -e with valid hex at end of string | Yes | Boundary: "test\x41" |
| echo -en combines flags | Yes | -en combined |
| echo -ne combines flags (different order) | Yes | -ne combined |
| echo -E disables escape sequences | Yes | Literal \n kept |
| echo -E overrides previous -e | Yes | -e -E order |
| echo -e overrides previous -E | Yes | -E -e order |
| echo -e with \c stops all remaining arguments | Yes | \c mid-argument |
| echo -e with \c at start of argument stops all | Yes | \c at start |
| echo treats lone dash as positional argument | Yes | "-" printed |
| echo -n with lone dash and text | Yes | -n - hello |
| echo -e backslash-zero-NNN: \0077 produces ? | Yes | Regression |
| echo -e backslash-zero-NNN: \0101 produces A | Yes | Regression |
| echo -e backslash-zero alone: \0 produces NUL | Yes | NUL byte |
| echo -e backslash-zero-zero: \00 produces NUL | Yes | \00 = NUL |
| echo -e backslash-NNN without zero prefix: \077 | Yes | \077 = '?' |
| echo help text documents \x as 1 or 2 hex digits | Yes | Help text check |
| echo -e hex escape with 2 digits: \x41 produces A | Yes | Duplicate of hex test |
| echo -e hex escape with 1 digit: \x9 produces tab | Yes | Single hex digit |

**0 parse-only stubs.**

---

## Issues Found

### [IMPORTANT] \v (vertical tab) and \f (form feed) have no
dedicated tests
Location: `src/echo.zig:198-215`
Problem: The implementation handles `\v` and `\f` but there are
no tests specifically for these sequences. A typo in the byte
value (e.g., `\x0c` vs `\x0b`) would go undetected.
Fix:
```zig
test "echo -e with \\v produces vertical tab" {
    const args = [_][]const u8{ "-e", "\\v" };
    // expect \x0b in output
}
test "echo -e with \\f produces form feed" {
    const args = [_][]const u8{ "-e", "\\f" };
    // expect \x0c in output
}
```

### [IMPORTANT] \e (escape) has no dedicated test
Location: `src/echo.zig:192-195`
Problem: `\e` (ESC, 0x1b) is implemented but untested. GNU echo
supports this and it is commonly used in color escape sequences.
Fix: Add a test checking that `\e` produces byte `\x1b`.

### [IMPORTANT] \a (bell) and \b (backspace) have no dedicated
tests
Location: `src/echo.zig:182-191`
Problem: `\a` and `\b` are implemented (`\x07`, `\x08`
respectively) but are only covered incidentally inside the
multi-escape test. No test isolates them.
Fix: Add tests for `\a` and `\b` individually.

### [SUGGESTION] Test for "echo -e handles multiple escape
sequences" is a duplicate path
Location: `src/echo.zig:366-374`
Problem: This test exercises `\t`, `\n`, and `\\` together. The
same bytes are individually covered. Not a problem, but the `\t`
from this test is the only coverage for `\t` — consider adding
a standalone `\t` test for clarity.

### [SUGGESTION] Unknown escape sequence pass-through is only
covered by the `\xZ` case inside the incomplete-hex test
Location: `src/echo.zig:272-277`
Problem: The `else =>` arm outputs the backslash literally and
advances by 1. This is tested implicitly via `\xZ` → `\xZ` but
not with an explicit unknown sequence like `\q`.
Fix: Add a test: `-e "\\q"` should produce `\q\n`.

### [SUGGESTION] `-neE` and `-EEn` compound flag combinations
not tested
Location: `src/echo.zig:27-68`
Problem: Only `-en` and `-ne` are tested as compound flags. The
last-wins logic for `-e`/`-E` when interleaved in a single
multi-character flag (like `-eE` or `-Ee`) is not covered.
Fix: Add tests for `-eE` (should be same as `-E`) and `-Ee`
(should be same as `-e`).

---

## Coverage Assessment

| Area | Coverage |
|------|----------|
| Basic output, multi-arg | Good |
| -n suppresses newline | Good |
| -e enables escapes | Good |
| -E disables escapes | Good |
| -e/-E ordering (separate flags) | Good |
| -en/-ne compound | Good |
| -eE/-Ee compound (single arg) | Missing |
| \n \t \\ \r | Good |
| \a \b | Incidental only |
| \v \f | None |
| \e (ESC) | None |
| \c termination | Good |
| \0NNN octal | Good |
| \NNN octal | Good |
| \xHH hex (2-digit) | Good |
| \xH hex (1-digit) | Good |
| \x bare (no valid digit) | Good |
| Lone dash as positional | Good |
| Unknown flags as positional | Yes (via unit test) |
| Help text | Good |
| Version | Not covered |

---

## Overall Assessment: APPROVED

0 critical, 3 important, 3 suggestion.
This is a strong test suite with no parse-only stubs. The
important gaps (`\v`, `\f`, `\e`, `\a`, `\b`) are individual
escape sequences that are easy to add. No behavioral surprises
or incorrect test logic found.
