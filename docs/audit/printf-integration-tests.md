# Integration Test Audit: printf

**Date**: 2026-03-28
**Test file**: tests/utilities/printf_test.sh
**Flags spec**: docs/specs/printf-flags.md
**Test run**: 23 tests, 23 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 23 tests pass, but the suite has three confirmed code bugs
that no test exercises, and fourteen format specifiers or
behaviors from the man page with zero integration test coverage.
Two bugs are CRITICAL (silent wrong output with no error),
one is IMPORTANT (%F unimplemented), and the missing tests leave
large surface area invisible to CI.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| printf binary | binary exists | Weak |
| printf --help | exit code 0 | Weak |
| printf --version | exit code 0 | Weak |
| printf %s basic | output match | Strong |
| printf %s with newline | output match | Strong |
| printf %d decimal | output match | Strong |
| printf %o octal | output match | Strong |
| printf %x hex | output match | Strong |
| printf %X hex uppercase | output match | Strong |
| printf %10s right-aligned | output match | Strong |
| printf %-10s left-aligned | output match | Strong |
| printf %05d zero-padded | output match | Strong |
| printf %.3s precision | output match | Strong |
| printf tab escape | output match | Strong |
| printf literal percent | output match | Strong |
| printf format reuse | output match | Strong |
| printf --help shows usage | exit + regex | Weak |
| printf --version shows version | exit + regex | Weak |
| printf no args exits 2 | exit code only | Weak |
| printf backslash-n produces newline | output match | Strong |
| printf %.2f 9.995 rounds to 10.00 | output match | Strong |
| printf %.0f 9.5 rounds to 10 | output match | Strong |
| printf %.2f 99.999 rounds to 100.00 | output match | Strong |

---

## Confirmed Bugs (Zero Test Coverage)

### Bug 1: %F not implemented — outputs literal "%F"

```
$ ./zig-out/bin/printf '%F\n' 3.14
%F
```

`'F'` falls through to the `else` branch in the `switch (conv)`
dispatch (src/printf.zig line 375), which writes `%` + the
character literally. GNU and macOS both output `3.140000`.

### Bug 2: %a / %A not implemented — outputs literal

```
$ ./zig-out/bin/printf '%a\n' 3.14
%a
```

Same cause as %F. The `else` branch catches `'a'` and `'A'`.
GNU outputs `0xc.8f5c28f5c28f5c3p-2`; both are POSIX-required
specifiers.

### Bug 3: %u with negative input silently outputs 0

```
$ ./zig-out/bin/printf '%u\n' -1
0               # ours
18446744073709551615   # GNU / macOS (two's complement wrap)
```

`parseUintArg` calls `std.fmt.parseInt(u64, s, 10)` which fails
on "-1" and returns 0 (src/printf.zig line 452). GNU treats the
bit pattern as unsigned, yielding ULLONG_MAX. The silent 0 is
wrong and no test catches it.

### Bug 4: %d/%i with float input silently outputs 0, no error

```
$ ./zig-out/bin/printf '%d\n' 3.9
0               # ours, exit 0
3               # GNU, exit 1 with "value not completely converted"
```

`parseIntArg` falls through to `std.fmt.parseInt(i64, s, 10)`
which fails on "3.9" and returns 0 silently. GNU truncates to
integer and exits 1. Our implementation emits no warning and
exits 0 — the wrong value is completely invisible.

### Bug 5: \' escape emits backslash+quote, not bare quote

```
$ ./zig-out/bin/printf "\'" | od -An -tx1 | tr -d ' '
5c27   # backslash + quote
27     # quote only (POSIX / GNU expected)
```

The format-string escape handler does not have a `'\''` case;
it falls through to the literal-copy path. POSIX requires `\'`
→ `'` (0x27).

### Bug 6: \NNN octal escape in format string not interpreted

```
$ ./zig-out/bin/printf '\101\n'
\101   # ours (literal)
A      # GNU / macOS
```

The format-string escape scanner handles `\n`, `\t`, `\r`, etc.
but not `\NNN` octal sequences. This is a separate path from
`%b` argument escapes, which do work correctly.

---

## Coverage Gaps (No Integration Tests)

The following behaviors are documented in the man page or
confirmed working in the implementation but have zero tests.

### Format specifiers with zero tests

| Specifier | Example | Notes |
|-----------|---------|-------|
| `%i` | `printf '%i' 42` → `42` | Synonym for `%d`; works but untested |
| `%u` | `printf '%u' 42` → `42` | Works; negative case broken (Bug 3) |
| `%f` | `printf '%f' 3.14` → `3.140000` | Works; no test |
| `%e` | `printf '%e' 3.14` → `3.140000e+00` | Works; no test |
| `%E` | `printf '%E' 3.14` → `3.140000E+00` | Works; no test |
| `%g` | `printf '%g' 3.14` → `3.14` | Works; no test |
| `%G` | `printf '%G' 3.14` → `3.14` | Works; no test |
| `%F` | `printf '%F' 3.14` | Broken (Bug 1); no test |
| `%a` | `printf '%a' 3.14` | Broken (Bug 2); no test |
| `%A` | `printf '%A' 1.5` | Broken (Bug 2); no test |
| `%c` | `printf '%c' A` → `A` | Works; no test |
| `%b` | `printf '%b' 'a\tb'` | Works; no test for content |

### Format flags with zero tests

| Flag | Example | Notes |
|------|---------|-------|
| `+` sign flag | `printf '%+d' 42` → `+42` | Works; no test |
| space sign | `printf '% d' 42` → ` 42` | Works; no test |
| `#` alternate form | `printf '%#x' 255` → `0xff` | Works; no test |
| `#` on octal | `printf '%#o' 8` → `010` | Works; no test |
| `*` width from arg | `printf '%*s' 8 hi` → `      hi` | Works; no test |
| `*` precision from arg | `printf '%.*f' 3 3.14` → `3.142` | Works; no test |

### Escape sequences with zero tests

| Sequence | Expected byte | Status |
|----------|--------------|--------|
| `\a` (bell) | 0x07 | Works; no test |
| `\b` (backspace) | 0x08 | Works; no test |
| `\r` (CR) | 0x0d | Works; no test |
| `\v` (vertical tab) | 0x0b | Works; no test |
| `\f` (form-feed) | 0x0c | Works; no test |
| `\NNN` octal | byte value | Broken (Bug 6); no test |
| `\'` single quote | 0x27 | Broken (Bug 5); no test |
| `\\` backslash | 0x5c | Works; no test |

### Edge cases with zero tests

- Character value from leading quote: `printf '%d' "'A"` → `65`
- Hex input to integer format: `printf '%d' 0xff` → `255`
- Precision on integer: `printf '%.5d' 42` → `00042`
- Width + precision on float: `printf '%10.3f' 3.14` → `     3.140`
- Zero-padded float: `printf '%010.3f' 3.14` → `000003.140`
- `inf` / `nan` inputs: `printf '%f' inf` → `inf`
- Extra format specs with no args (zero/empty): `printf '%d %s\n'`
  → `0 `
- Format reuse with `%d`: `printf '%d\n' 1 2 3` → three lines

---

## Issues by Severity

```
[CRITICAL] %d/%i silently outputs 0 for float input, no warning
Location: src/printf.zig:428 (parseIntArg fallthrough)
Problem: printf '%d' 3.9 outputs 0 and exits 0. GNU outputs 3
         with a stderr warning and exits 1. Silent wrong output
         is worse than an error.
Fix: After int parse fails, attempt float parse, truncate to
     i64, emit "value not completely converted" warning to
     stderr, set exit code 1.

[CRITICAL] \NNN octal escape in format string not interpreted
Location: src/printf.zig (format-string escape scanner)
Problem: printf '\101\n' outputs literal \101 instead of A.
         POSIX requires octal escapes in the format string.
Fix: Add \0-\7 case to the format-string escape handler that
     reads up to 3 octal digits and emits the byte value.

[IMPORTANT] %F not implemented
Location: src/printf.zig:375 (else branch)
Problem: printf '%F' 3.14 outputs literal %F. %F is a
         POSIX-required uppercase variant of %f.
Fix: Add 'F' case to the switch that calls formatFloat with
     conv = 'F'; formatFloat already handles 'f' so the
     uppercase path only needs to capitalize the output.

[IMPORTANT] %a / %A not implemented
Location: src/printf.zig:375 (else branch)
Problem: printf '%a' 3.14 outputs literal %a. %a/%A are
         POSIX-required hex floating-point specifiers.
Fix: Implement hex float formatting using the form
     [-]0xh.hhhp[+-]d as described in the man page.

[IMPORTANT] %u with negative input outputs 0 instead of wrapping
Location: src/printf.zig:452 (parseUintArg fallthrough)
Problem: printf '%u' -1 outputs 0. GNU / POSIX treat the value
         as two's complement unsigned (ULLONG_MAX for -1).
Fix: Parse as i64 first; if negative, reinterpret the bit
     pattern as u64 via @bitCast.

[IMPORTANT] \' escape emits backslash+quote, not bare quote
Location: src/printf.zig (format-string escape handler)
Problem: printf "\'" outputs 0x5c27. POSIX requires 0x27.
Fix: Add '\'' case to the escape handler that emits 0x27.

[IMPORTANT] No tests for %i, %u, %f, %e, %E, %g, %G, %c, %b
Location: tests/utilities/printf_test.sh
Problem: Eleven format specifiers are either untested or only
         partially tested. Regressions would not be caught.
Fix: Add one output-verifying test per specifier; include at
     least one test for each bug listed above to enforce
     red-green TDD.

[IMPORTANT] No tests for format flags: +, space, #, *, .*
Location: tests/utilities/printf_test.sh
Problem: Six flag combinations are implemented but untested.
Fix: Add one output-verifying test per flag combination.

[SUGGESTION] No tests for escape sequences \a, \b, \r, \v, \f, \\
Location: tests/utilities/printf_test.sh
Problem: Byte-level behavior untested; byte comparison via od
         or printf '%b' would verify correctness.
Fix: Add output-verifying tests using $'...' ANSI C quoting or
     od comparison for byte sequences.

[SUGGESTION] --help and --version checks use regex, not content
Location: tests/utilities/printf_test.sh:154,166
Problem: [Uu]sage and "printf" are very loose patterns.
Fix: Check for specific flag documentation in --help output.
```

---

## Fix Order

```
Fix Order:
1. [CRITICAL] %d/%i silently outputs 0 for float — src/printf.zig:428
2. [CRITICAL] \NNN octal escape in format string — src/printf.zig escape handler
3. [IMPORTANT] %F not implemented — src/printf.zig:375
4. [IMPORTANT] %a / %A not implemented — src/printf.zig:375
5. [IMPORTANT] %u negative input outputs 0 — src/printf.zig:452
6. [IMPORTANT] \' escape emits backslash+quote — src/printf.zig escape handler
7. [IMPORTANT] Add tests for %i %u %f %e %E %g %G %c %b — printf_test.sh
8. [IMPORTANT] Add tests for +, space, #, *, .* flags — printf_test.sh
9. [SUGGESTION] Add byte-level escape sequence tests — printf_test.sh
10. [SUGGESTION] Tighten --help / --version output checks — printf_test.sh
```

REVIEW COMPLETE - NEEDS_FIXES
