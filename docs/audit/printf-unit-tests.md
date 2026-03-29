# printf Unit Test Audit

**Date:** 2026-03-28
**File:** `src/printf.zig`
**Tests:** 48 / 48 pass
**Verdict:** NEEDS_FIXES

---

## Test Inventory

48 tests are embedded in `src/printf.zig`. All pass. The
list below maps each test to the behavior it covers.

| # | Test Name | What It Covers |
|---|-----------|---------------|
| 1 | printf basic string | `%s` basic output |
| 2 | printf string with newline escape | `\n` in format string |
| 3 | printf integer formatting | `%d` positive |
| 4 | printf negative integer | `%d` negative |
| 5 | printf octal | `%o` |
| 6 | printf hex lowercase | `%x` |
| 7 | printf hex uppercase | `%X` |
| 8 | printf unsigned integer | `%u` |
| 9 | printf character | `%c` |
| 10 | printf float | `%f` default precision |
| 11 | printf literal percent | `%%` |
| 12 | printf width right-aligned | `%10s` |
| 13 | printf width left-aligned | `%-10s` |
| 14 | printf precision truncates string | `%.3s` |
| 15 | printf zero-padded integer | `%05d` |
| 16 | printf format string reuse | multiple args consume format |
| 17 | printf missing argument defaults to empty string | `%s` with no arg |
| 18 | printf missing argument defaults to zero for integers | `%d` with no arg |
| 19 | printf escape sequences in format | `\t\n\r\a` |
| 20 | printf octal escape in format | `\0101` → `A` |
| 21 | printf hex escape in format | `\x41` → `A` |
| 22 | printf backslash escape | `\\` → `\` |
| 23 | printf %b with escape sequences | `%b` + `\n` in arg |
| 24 | printf no arguments shows usage error | exit code 2 |
| 25 | printf --help | help text emitted |
| 26 | printf --version | version string emitted |
| 27 | printf multiple format specifiers | `%s` and `%d` in one format |
| 28 | printf character from quote syntax | `'A` → 65 |
| 29 | printf hex argument prefix | `0xff` → 255 |
| 30 | printf octal argument prefix | `010` → 8 |
| 31 | printf scientific notation | `%e` |
| 32 | printf plus sign flag | `%+d` |
| 33 | printf hash flag for octal | `%#o` |
| 34 | printf hash flag for hex | `%#x` |
| 35 | printf width with integer | `%8d` |
| 36 | printf empty format | empty string |
| 37 | printf plain text no specifiers | literal output |
| 38 | printf %g removes trailing zeros | `%g` 3.0 → "3" |
| 39 | printf %c with empty argument | `%c ""` → empty |
| 40 | printf %c with missing argument | `%c` (no arg) → empty |
| 41 | printf float with precision | `%.2f` |
| 42 | printf float zero | `%f` 0 |
| 43 | processEscape should propagate write errors | write-error path |
| 44 | printf float carry propagation: 9.995 → 10.00 | rounding |
| 45 | printf float carry propagation: 9.95 → 10.0 | rounding |
| 46 | printf float carry propagation zero precision: 9.5 → 10 | rounding |
| 47 | printf float carry propagation multi-digit: 99.999 → 100.00 | rounding |
| 48 | printf float simple rounding no carry overflow: 1.005 → 1.01 | rounding |

---

## Issues

---

```
[CRITICAL] Test 24 asserts exit code 2; correct exit code is 1
Location: src/printf.zig:1312
Problem: "printf no arguments shows usage error" asserts
         `result == 2`. The code-audit established that macOS
         printf exits 1 for zero arguments, and POSIX requires
         exit >= 1. The test is written to pass on the bug: when
         the exit code is fixed to 1, this test will fail. It
         documents incorrect behavior as correct.
Fix: Change the expectation to exit code 1:
         try testing.expectEqual(@as(u8, 1), result);
     Then fix runPrintf to return general_error (1) instead of
     misuse (2) on zero arguments.
```

---

```
[CRITICAL] Tests 39/40 assert that %c with empty/missing arg
           emits nothing; correct behavior is to emit NUL (0x00)
Location: src/printf.zig:1461-1473
Problem: Both tests call expectEqualStrings("", ...). The
         code-audit established that macOS printf '%c' (missing
         arg) emits a NUL byte. These tests are written to pass
         on the bug and will fail once the bug is fixed.
Fix: Update both tests to assert a single NUL byte:
         try testing.expectEqualStrings("\x00", buffer.items);
```

---

```
[CRITICAL] Test 43 (write-error propagation) comment contradicts
           the assertion — stale "documents a bug" text that is
           no longer true
Location: src/printf.zig:1496-1518
Problem: The comment states "BUG: processEscape swallows the
         error, so result is 0" but the assertion is
         `result != 0` and the test passes (48/48). The comment
         misleads the programmer: it claims there is a known bug
         when the implementation is actually correct. A future
         reader may conclude the test is intentionally
         documenting a broken state and not investigate further.
Fix: Rewrite the comment to reflect the current correct behavior:
         // processEscape propagates write errors via `try`,
         // so runPrintf returns a non-zero exit code when the
         // write fails. This test guards against regressions.
```

---

```
[IMPORTANT] No behavioral test for %i (signed decimal alias)
Location: src/printf.zig (tests section)
Problem: %i is handled alongside %d at line 325 but no test
         exercises it directly. If the case were accidentally
         removed from the switch, all existing tests would still
         pass.
Fix: Add:
         test "printf %i signed decimal" {
             // same as %d
             const args = [_][]const u8{ "%i", "42" };
             ...
             try testing.expectEqualStrings("42", buffer.items);
         }
```

---

```
[IMPORTANT] No behavioral test for %E (uppercase scientific)
Location: src/printf.zig (tests section)
Problem: %E is implemented at line 360 but only %e is tested
         (test 31). If the 'E' case were removed the suite
         still passes.
Fix: Add a test asserting the output uses uppercase 'E':
         const args = [_][]const u8{ "%E", "100000" };
         // expected: "1.000000E+05"
```

---

```
[IMPORTANT] No behavioral test for %G (uppercase general float)
Location: src/printf.zig (tests section)
Problem: %G is implemented at line 370 but has no test. Only
         %g is covered (test 38).
Fix: Add a test asserting uppercase 'E' in the exponent when
     scientific notation is chosen:
         const args = [_][]const u8{ "%G", "0.00001" };
         // expected: "1E-05"
```

---

```
[IMPORTANT] No test for * (dynamic) width or precision from argument
Location: src/printf.zig:254-287 (parsing), tests section
Problem: The * syntax for width and precision is implemented but
         has zero test coverage. The negative-* left-justify bug
         (code-audit IMPORTANT #4) is also untested.
Fix: Add at minimum:
         test "printf dynamic width from argument" {
             const args = [_][]const u8{ "%*s", "10", "hello" };
             // expected: "     hello"
         }
         test "printf dynamic precision from argument" {
             const args = [_][]const u8{ "%-.*s", "3", "hello" };
             // expected: "hel"
         }
```

---

```
[IMPORTANT] No test for space-sign flag (% d)
Location: src/printf.zig:615-616 (space_sign in formatSignedInt)
Problem: The space flag is parsed and applied to signed integers
         and floats but has no test. Breakage would be silent.
Fix: Add:
         test "printf space sign flag positive" {
             const args = [_][]const u8{ "% d", "42" };
             // expected: " 42"
         }
         test "printf space sign flag negative" {
             const args = [_][]const u8{ "% d", "-7" };
             // expected: "-7"  (+ overrides space when negative)
         }
```

---

```
[IMPORTANT] No test for %b \c (suppress further output)
Location: src/printf.zig:510-514 (formatBString \c case)
Problem: The \c handler in formatBString returns early but there
         is no test verifying that output before \c is emitted
         and output after is suppressed. The code-audit found
         that format-reuse is not halted (\c only stops the
         current argument). Both the partial-stop (correct) and
         the reuse-not-stopped (bug) behaviors are untested.
Fix: Add:
         test "printf %b \\c stops within argument" {
             const args = [_][]const u8{ "%b", "hello\\cworld" };
             // expected: "hello" (world suppressed)
         }
```

---

```
[IMPORTANT] No test for invalid numeric argument behavior
Location: src/printf.zig:408-429 (parseIntArg)
Problem: The code-audit found that invalid numeric arguments
         (e.g. "abc" for %d) should emit a stderr warning and
         exit 1. No unit test exercises the error path for
         invalid arguments. The had_error mechanism in runPrintf
         is also untested.
Fix: Add:
         test "printf invalid integer arg exits nonzero" {
             var stderr = std.ArrayList(u8)...;
             const args = [_][]const u8{ "%d", "abc" };
             const result = try runPrintf(..., stderr.writer(...));
             try testing.expect(result != 0);
             try testing.expect(stderr.items.len > 0);
         }
     Note: this test will fail until the underlying bug is fixed.
     Write it first (RED), then fix.
```

---

```
[IMPORTANT] No test for %#x with val == 0 (# flag on zero)
Location: src/printf.zig:714-717 (prefix_str in formatHex)
Problem: The code does not emit "0x" prefix when val == 0
         (`if (spec.hash_flag and val != 0)`). macOS behavior:
         `printf '%#x' 0` → "0" (no prefix). This is correct,
         but it is not tested. If the condition were accidentally
         changed to always emit the prefix, no test would catch it.
Fix: Add:
         test "printf hash flag for hex with zero" {
             const args = [_][]const u8{ "%#x", "0" };
             // expected: "0" (no 0x prefix)
         }
```

---

```
[SUGGESTION] No test for %f / %e precision 0 (no decimal point)
Location: src/printf.zig tests section
Problem: `%.0f 3` should emit "3" with no decimal point. The
         float-carry tests cover `%.0f` but not the
         no-decimal-point case. The `%.0e` case (scientific
         with precision 0) is entirely untested.
Fix: Add:
         test "printf %f precision zero omits decimal" {
             const args = [_][]const u8{ "%.0f", "3.7" };
             // expected: "4"
         }
         test "printf %e precision zero" {
             const args = [_][]const u8{ "%.0e", "100" };
             // expected: "1e+02"
         }
```

---

```
[SUGGESTION] No test for zero-pad flag on floats (%0Nf)
Location: src/printf.zig:828-843 (formatFloat zero-pad branch)
Problem: The zero-pad path for floats is implemented but only
         tested for integers (test 15). Float zero-padding has
         distinct sign-placement behavior (sign before zeros).
Fix: Add:
         test "printf zero-padded float" {
             const args = [_][]const u8{ "%010.2f", "3.14" };
             // expected: "0000003.14"
         }
         test "printf zero-padded negative float" {
             const args = [_][]const u8{ "%010.2f", "-3.14" };
             // expected: "-000003.14"
         }
```

---

```
[SUGGESTION] No test for trailing backslash in format string
Location: src/printf.zig:131-134 (processEscape trailing backslash)
Problem: A trailing `\` at the end of the format string is
         handled by outputting a literal backslash. This edge
         case (line 131) has no test.
Fix: Add:
         test "printf trailing backslash in format" {
             const args = [_][]const u8{"abc\\"};
             // expected: "abc\"  (literal backslash at end)
         }
```

---

```
[SUGGESTION] No test for format reuse with zero consuming specifiers
Location: src/printf.zig:69-82 (runPrintf reuse loop)
Problem: The loop breaks when `arg_idx <= start_arg_idx` (no
         args consumed in a pass). This guard is untested. A
         format string with no specifiers and extra arguments
         should produce output exactly once.
Fix: Add:
         test "printf no-specifier format with extra args produces once" {
             const args = [_][]const u8{ "hello", "ignored" };
             // expected: "hello"  (not "hellohello")
         }
```

---

## Format Specifier Coverage

| Specifier | Behavioral Test | Notes |
|-----------|----------------|-------|
| %s | Yes (tests 1, 12, 13, 14, 17, 27) | |
| %b | Partial (test 23) | No `\c`, no octal in %b arg |
| %c | Partial (tests 9, 39, 40) | Tests pass on bugs (#39/#40) |
| %d | Yes (tests 3, 4, 15, 18, 32, 35) | |
| %i | No | Handled by same branch as %d |
| %u | Yes (test 8) | |
| %o | Yes (tests 5, 33) | |
| %x | Yes (tests 6, 34) | No zero-val # test |
| %X | Yes (test 7) | |
| %f | Yes (tests 10, 41, 42, 44-48) | No zero-pad, no # flag |
| %F | No | Specifier not implemented (code bug) |
| %e | Yes (test 31) | No # flag, no precision 0 |
| %E | No | Specifier implemented, zero test |
| %g | Yes (test 38) | No # flag |
| %G | No | Specifier implemented, zero test |
| %a | No | Specifier not implemented (code bug) |
| %A | No | Specifier not implemented (code bug) |
| %% | Yes (test 11) | |

## Escape Sequence Coverage

| Sequence | Behavioral Test | Notes |
|----------|----------------|-------|
| `\a` | Yes (test 19) | |
| `\b` | Partial (in test 19 list, not asserted separately) | |
| `\f` | No | Not in any test |
| `\n` | Yes (tests 2, 19) | |
| `\r` | Yes (test 19) | |
| `\t` | Yes (test 19) | |
| `\v` | No | Parsed but not tested |
| `\\` | Yes (test 22) | |
| `\0NNN` | Yes (test 20) | Tests `\0101`; leading-0 form only |
| `\NNN` (no 0) | No | Code bug; no regression test either |
| `\xHH` | Yes (test 21) | |
| `\c` (format) | No | Code bug; no regression test |
| `%b` `\NNN` | No | Code bug; no regression test |
| `%b` `\c` | No | Code bug; no regression test |

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 7 |
| SUGGESTION | 4 |

**Overall Assessment: NEEDS_FIXES**

Three tests assert incorrect (buggy) behavior as expected,
making them cannot-fail checks for bugs rather than regressions.
Seven important gaps leave implemented features—%i, %E, %G,
dynamic width, space-sign, %b `\c`, and invalid-arg error
path—completely uncovered. The specifiers with known code bugs
(%F, %a/%A, \c, \NNN) have no corresponding failing tests, so
fixing the bugs could be done without test guidance (violating
red-green TDD).

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Test 24 asserts exit code 2 (bug) — src/printf.zig:1312
2. [CRITICAL] Tests 39/40 assert empty output for %c missing arg (bug)
              — src/printf.zig:1461-1473
3. [CRITICAL] Test 43 comment says "documents bug" but test is correct
              — src/printf.zig:1496 (update comment only)
4. [IMPORTANT] Add %i behavioral test — tests section
5. [IMPORTANT] Add %E behavioral test — tests section
6. [IMPORTANT] Add %G behavioral test — tests section
7. [IMPORTANT] Add * dynamic width/precision tests — tests section
8. [IMPORTANT] Add space-sign flag tests — tests section
9. [IMPORTANT] Add %b \c behavioral test — tests section
10. [IMPORTANT] Add invalid numeric arg error-path test — tests section
11. [SUGGESTION] Add %#x with zero test — tests section
12. [SUGGESTION] Add %.0f / %.0e tests — tests section
13. [SUGGESTION] Add zero-padded float tests — tests section
14. [SUGGESTION] Add trailing backslash test — tests section
```

REVIEW COMPLETE - NEEDS_FIXES
