# printf Code Audit

**Date:** 2026-03-28
**File:** `src/printf.zig`
**Verdict:** NEEDS_FIXES

All findings are from dynamic comparison against `/usr/bin/printf` (macOS
BSD, which is the authoritative reference per audit ground rules).

---

## Issues

---

```
[CRITICAL] Format-string octal \NNN not recognized (only \0NNN works)
Location: src/printf.zig:170-183 (processEscape)
Problem: The switch on format[pos+1] only matches '0', so \NNN sequences
         whose first digit is 1-7 are output literally. macOS printf treats
         any backslash followed by 1-3 octal digits as an octal escape — no
         leading zero required:
           macOS: printf '\101'  → A (0x41)
           ours:  printf '\101'  → \101 (four literal bytes)
         The same bug affects multi-digit octal whose first digit is non-zero.
Fix: In the processEscape switch, replace the '0' branch with a branch that
     matches '0'...'7', then consumes up to 3 total octal digits:
         '0'...'7' => {
             var value: u8 = format[pos + 1] - '0';
             var j: usize = pos + 2;
             var count: usize = 1;
             while (count < 3 and j < format.len and
                    format[j] >= '0' and format[j] <= '7') : ({
                 j += 1; count += 1;
             }) {
                 value = value *% 8 +% (format[j] - '0');
             }
             try writer.writeByte(value);
             return .{ .new_pos = j };
         },
```

---

```
[CRITICAL] %b octal \0NNN bug: reads \0 as a zero-byte then treats NNN
           as a separate sequence
Location: src/printf.zig:540-548 (formatBString)
Problem: The switch branch for '0'...'7' starts j=1 and reads up to 3
         digits beginning at s[i+j]. When the input is \0101, s[i+1]='0',
         so j starts at 1 and reads '0','1','0' → value 8 (010 octal), then
         emits 0x08 and leaves '1' unconsumed. macOS emits 0x41 ('A'):
           macOS: printf '%b' '\0101'  → 0x41
           ours:  printf '%b' '\0101'  → 0x08 0x31
         The root cause is that the leading '0' (at i+1) is consumed by the
         switch match but is not the start digit — j should begin at 1 and
         the matched digit itself (s[i+1]) should be the first digit of the
         value, not discarded.
Fix: Include the matched digit in the value:
         '0'...'7' => {
             var value: u8 = s[i + 1] - '0';  // first digit is the switch match
             var j: usize = 2;                  // additional digits start at i+2
             while (j <= 3 and i + j < s.len and
                    s[i + j] >= '0' and s[i + j] <= '7') : (j += 1) {
                 value = value *% 8 +% (s[i + j] - '0');
             }
             try writer.writeByte(value);
             i += j;
         },
     The check `j <= 3` gives a total of 3 octal digits (the switch-matched
     digit plus up to 2 more).
```

---

```
[CRITICAL] \c in format string is not handled — must terminate all output
Location: src/printf.zig:130-217 (processEscape)
Problem: macOS printf treats \c in the format string as "stop all output
         immediately and exit 0". Our implementation does not match '\c' in
         the processEscape switch, so it falls through to the else branch and
         emits a literal backslash, then 'c' continues as a plain character:
           macOS: printf 'before\cafter'  → "before" (stops here)
           ours:  printf 'before\cafter'  → "before\cafter"
         The %b handler does implement \c for argument strings, but the
         format string path lacks the same handling.
Fix: Add a '\c' case to processEscape. Because processEscape cannot signal
     "stop all processing" through the current EscapeResult struct, the
     simplest fix is to add a `stop: bool` field to EscapeResult and have
     processFormat break its loop when it sees stop=true. The caller
     (runPrintf) must also break its format-reuse loop when processFormat
     signals a stop.
```

---

```
[CRITICAL] %b \c does not halt format-string reuse — further arguments
           still processed
Location: src/printf.zig:510-514 (formatBString), src/printf.zig:69-82
          (runPrintf)
Problem: When \c appears in a %b argument, formatBString returns early
         (correct for the current argument), but processFormat and the
         format-reuse loop in runPrintf have no way to know that processing
         should stop. Remaining arguments continue to be processed:
           macOS: printf '%b\n' hello 'stop\c' after
                  → "hello\nstop" then exits
           ours:  printf '%b\n' hello 'stop\c' after
                  → "hello\nstop\nafter\n"
Fix: Propagate the \c stop signal upward. processFormat should return a
     boolean (or a struct) indicating whether a \c was encountered. The
     format-reuse loop in runPrintf must check this and break immediately.
     The same mechanism resolves the format-string \c issue above.
```

---

```
[CRITICAL] %F (uppercase fixed float) not implemented — outputs literal "%F"
Location: src/printf.zig:310-383 (processSpecifier switch)
Problem: The switch on conv has cases for 'f', 'e', 'E', 'g', 'G' but not
         'F'. The else branch outputs the specifier literally:
           macOS: printf '%F\n' 3.14  → "3.140000"
           ours:  printf '%F\n' 3.14  → "%F"
         %F is identical to %f but prints INF/NAN in uppercase. macOS and
         GNU both require it.
Fix: Add a 'F' case that calls formatFloat with a new 'F' mode (or reuse 'f'
     and add uppercase INF/NAN handling):
         'F' => {
             const arg = getNextArg(arguments, arg_idx);
             const val = parseFloatArg(arg);
             try formatFloat(writer, val, 'F', spec);
         },
     Then handle the 'F' case in formatFloat by delegating to formatFixedFloat
     and uppercasing any "inf"/"nan" in the result.
```

---

```
[CRITICAL] %a/%A (hexadecimal floating-point) not implemented — outputs
           literal "%a" / "%A"
Location: src/printf.zig:375-379 (processSpecifier else branch)
Problem: macOS requires %a/%A (hex float, style [-h.hhh±pd]):
           macOS: printf '%a\n' 1.5   → "0xcp-3"
           ours:  printf '%a\n' 1.5   → "%a"
         These are documented in the macOS man page as mandatory specifiers.
Fix: Add 'a' and 'A' cases to the processSpecifier switch and implement
     formatHexFloat. The format is: sign + "0x" + hex-mantissa + "p" +
     sign + decimal-exponent. Use std.fmt.float.render with mode .hex if
     available in Zig 0.15, otherwise implement manually.
```

---

```
[IMPORTANT] %c does not emit NUL byte when argument is missing or empty
Location: src/printf.zig:319-324 (processSpecifier 'c' case)
Problem: macOS printf '%c' (missing argument) emits a NUL byte (0x00).
         Our implementation emits nothing:
           macOS: printf '%c' | od -An -tx1  → " 00"
           ours:  printf '%c' | od -An -tx1  → (empty)
         This also affects %c with an explicit empty string argument.
Fix: Remove the `if (arg.len > 0)` guard and always write exactly one byte.
     When the argument is empty (or missing), write 0x00:
         'c' => {
             const arg = getNextArg(arguments, arg_idx);
             const byte: u8 = if (arg.len > 0) arg[0] else 0;
             try writer.writeByte(byte);
         },
```

---

```
[IMPORTANT] %c does not apply width modifier
Location: src/printf.zig:319-324 (processSpecifier 'c' case)
Problem: macOS printf '%5c' A → "    A" (4 spaces then A).
         Our implementation ignores width for %c:
           macOS: printf '"%5c"\n' A  → "    A"
           ours:  printf '"%5c"\n' A  → "A"
Fix: After resolving the byte to print, apply width padding using the same
     logic as formatString — right-pad with spaces when left_justify, else
     left-pad:
         const s = [1]u8{byte};
         try formatString(writer, &s, spec);
```

---

```
[IMPORTANT] Invalid numeric argument does not emit a warning or set exit 1
Location: src/printf.zig:408-429 (parseIntArg), src/printf.zig:71-74
          (error handling in runPrintf)
Problem: macOS printf '%d\n' abc prints "0" AND emits a warning to stderr
         AND exits with code 1. Our implementation silently returns 0 and
         exits 0. The had_error mechanism only catches write errors from
         processFormat, not parse errors from parseIntArg.
           macOS: printf '%d\n' abc 2>&1; echo $?
                  → "printf: 'abc': expected a numeric value\n0\n1"
           ours:  printf '%d\n' abc 2>&1; echo $?
                  → "0\n0"
         Partial conversion (printf '%d\n' 5abc) is also not warned.
Fix: parseIntArg (and parseUintArg, parseFloatArg) need to return an error
     union or take a stderr_writer and set a flag when the string is not a
     valid number. The runPrintf loop should catch these and set had_error=true.
```

---

```
[IMPORTANT] Negative dynamic width (*) does not imply left-justify
Location: src/printf.zig:254-258 (width parsing for '*')
Problem: POSIX and macOS: when the argument for '*' width is negative, its
         absolute value is used as the width AND the left-justify flag is set:
           macOS: printf '"%*d"\n' -5 42  → "42   "
           ours:  printf '"%*d"\n' -5 42  → "42"  (no padding at all)
         The current code uses @max(0, ...) which clamps negative values to 0,
         discarding both the absolute width and the implied left-justify.
Fix: Parse the signed value; if negative, set left_justify=true and use
     the absolute value as the width:
         const w_val = std.fmt.parseInt(i64, w_str, 10) catch 0;
         if (w_val < 0) {
             left_justify = true;
             width = @intCast(-w_val);
         } else {
             width = @intCast(w_val);
         }
```

---

```
[IMPORTANT] # flag on floating-point specifiers (%f, %e, %g) not implemented
Location: src/printf.zig:797-843 (formatFloat)
Problem: The # flag must force a decimal point even when precision is 0, and
         for %g/%G it must suppress trailing-zero removal. formatFloat
         ignores hash_flag entirely:
           macOS: printf '%#.0f\n' 3   → "3."
           ours:  printf '%#.0f\n' 3   → "3"

           macOS: printf '%#.0e\n' 100 → "1.e+02"
           ours:  printf '%#.0e\n' 100 → "1e+02"

           macOS: printf '%#g\n' 1.0   → "1.00000"
           ours:  printf '%#g\n' 1.0   → "1"
Fix: Pass spec.hash_flag into formatFixedFloat, formatSciFloat, and
     formatGeneralFloat. In each: if hash_flag and the result has no '.',
     append one. In formatGeneralFloat with hash_flag, skip the
     stripTrailingZeros calls.
```

---

```
[IMPORTANT] Exit code for zero arguments is 2 (misuse); macOS uses 1
Location: src/printf.zig:47-49 (runPrintf)
Problem: macOS printf (no args) exits 1. POSIX specifies exit >=1. Our
         implementation returns ExitCode.misuse which is 2. This is a
         minor behavioral divergence that can break scripts testing for
         exact exit codes.
Fix: Return exit code 1 (general_error) when no arguments are supplied,
     not 2 (misuse).
```

---

```
[SUGGESTION] formatSciFloat uses manual float-to-string conversion instead
             of the Ryu/std.fmt path used by formatFixedFloat
Location: src/printf.zig:852-915 (formatSciFloat)
Problem: formatSciFloat manually normalizes the mantissa by repeated
         division/multiplication. This floating-point loop can accumulate
         rounding errors compared to directly using std.fmt.float.render.
         formatFixedFloat correctly uses std.fmt.float.render. There is no
         corresponding std.fmt.float path tested here.
Fix: Consider using std.fmt.float.render with mode .scientific once Zig
     0.15 exposes that mode, or at minimum add regression tests for
     boundary values like printf '%e' 9.9999995.
```

---

```
[SUGGESTION] No error message when processFormat encounters a write error
Location: src/printf.zig:72-75 (runPrintf)
Problem: When processFormat returns an error, had_error is set to true and
         a non-zero exit code is returned, but no diagnostic is written to
         stderr. The user gets a silent failure.
Fix: Capture the error and emit a message:
         } else |err| {
             had_error = true;
             common.printErrorWithProgram(allocator, stderr_writer,
                 "printf", "write error: {}", .{err});
         }
```

---

## Format Specifier Verdict Table

| Specifier | Status     | Notes                                      |
|-----------|------------|--------------------------------------------|
| %s        | PASS       |                                            |
| %b        | FAIL       | \c does not halt reuse; \0NNN octal bug    |
| %c        | FAIL       | No NUL for missing arg; width not applied  |
| %d / %i   | PASS       | Parse errors not warned (IMPORTANT above)  |
| %u        | PASS       |                                            |
| %o        | PASS       |                                            |
| %x / %X   | PASS       |                                            |
| %f        | FAIL       | # flag not implemented                     |
| %F        | FAIL       | Not implemented at all (CRITICAL)          |
| %e / %E   | FAIL       | # flag not implemented                     |
| %g / %G   | FAIL       | # flag not implemented                     |
| %a / %A   | FAIL       | Not implemented at all (CRITICAL)          |
| %%        | PASS       |                                            |

## Escape Sequence Verdict Table

| Sequence          | Status | Notes                                      |
|-------------------|--------|--------------------------------------------|
| \a \b \f \n \r    | PASS   |                                            |
| \t \v \\          | PASS   |                                            |
| \0NNN (format)    | FAIL   | Leading 0 required; \NNN without 0 broken  |
| \NNN  (format)    | FAIL   | Only \0... handled; \1-\7 not recognized   |
| \xHH  (format)    | PASS   |                                            |
| \c    (format)    | FAIL   | Not recognized; outputs literal \c         |
| \NNN  (%b arg)    | FAIL   | Off-by-one: first digit dropped from value |
| \c    (%b arg)    | PARTIAL| Stops current arg but not format reuse     |

---

## Summary

| Severity   | Count |
|------------|-------|
| CRITICAL   | 6     |
| IMPORTANT  | 5     |
| SUGGESTION | 2     |

**Overall Assessment: BLOCKED**

Six critical defects produce wrong output compared to macOS printf. The two
missing specifiers (%F, %a/%A) output literal percent-sequences. The
format-string octal and \c bugs cause silent incorrect behavior. These must
be fixed before this utility can be considered correct.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Format-string \NNN octal not recognized — src/printf.zig:170
2. [CRITICAL] %b \0NNN octal off-by-one (first digit dropped) — src/printf.zig:540
3. [CRITICAL] \c in format string not handled — src/printf.zig:130
4. [CRITICAL] %b \c does not halt format-string reuse — src/printf.zig:510
5. [CRITICAL] %F not implemented — src/printf.zig:310
6. [CRITICAL] %a/%A not implemented — src/printf.zig:375
7. [IMPORTANT] %c missing-arg should emit NUL, not nothing — src/printf.zig:319
8. [IMPORTANT] %c does not apply width modifier — src/printf.zig:319
9. [IMPORTANT] Invalid numeric arg: no warning, exits 0 — src/printf.zig:408
10. [IMPORTANT] Negative * width does not imply left-justify — src/printf.zig:254
11. [IMPORTANT] # flag on %f/%e/%g not implemented — src/printf.zig:797
12. [IMPORTANT] No-args exit code should be 1, not 2 — src/printf.zig:47
13. [SUGGESTION] formatSciFloat uses manual normalization loop — src/printf.zig:852
14. [SUGGESTION] Write errors silently swallowed — src/printf.zig:72
```

REVIEW COMPLETE - BLOCKED
