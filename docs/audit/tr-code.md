# tr Code Audit

**Date:** 2026-03-28
**File:** `src/tr.zig`
**Build:** passes (`just build-util tr`)
**Tests:** 30/30 unit pass; 43/43 integration pass
**Assessment:** NEEDS_FIXES

---

## Dynamic Verification

All tests confirmed against a freshly built binary at
`zig-out/bin/tr`. Specific invocations used during review:

```
echo "hello world" | tr a-z A-Z         -> HELLO WORLD  OK
echo "hello world" | tr '[:lower:]' '[:upper:]' -> HELLO WORLD  OK
echo "aabbccdd"    | tr -s a-z           -> abcd          OK
echo "hello world" | tr -d aeiou        -> hll wrld       OK
echo "hello world" | tr -ds aeiou ' -~' -> hl wrld        OK
printf 'abc' | tr 'abc' '[x*]'          -> abc  WRONG (bug)
echo "abcXYZ" | tr 'abc' '[x*]'         -> abcXYZ WRONG (bug)
echo "test" | tr a b c                  -> test  WRONG (no error)
```

---

## Flag Verdict

| Flag | Tier | Verdict |
|------|------|---------|
| -c   | MUST | PASS — complement translate and delete work correctly |
| -C   | MUST | PASS — functionally identical to -c for ASCII (correct per spec) |
| -d   | MUST | PASS |
| -s   | MUST | PASS — standalone, with translate, with -d |
| -t   | SHOULD | PASS — truncates SET1 to SET2 length before translate |
| -u   | SHOULD | STUB — accepted silently, no unbuffered effect; documented as such |

---

## Findings

```
[CRITICAL] [c*] fill-to-SET1-length is silently unimplemented
Location: src/tr.zig:290-292 (parseRepeat), src/tr.zig:483-486 (runTrWithInput)
Problem: When [c*] appears in SET2, parseRepeat() sets count = 0 as a
         sentinel. The loop at line 93 executes `for (0..0)` — zero
         iterations — so nothing is appended to the parsed set. The comment
         at line 483-486 claims the re-expansion will happen but the block
         is empty. The net result: [c*] in SET2 produces an empty set,
         which causes buildTranslationTable to receive an empty SET2 and
         return the identity table — silently passing input through
         unchanged.

         [x*0] is equally broken: the octal branch at line 293-299 parses
         '0' as octal zero, producing count = 0, same outcome.

         Dynamic confirmation:
           printf 'abc' | tr 'abc' '[x*]'   -> abc  (expected: xxx)
           printf 'aabbXXcc' | tr -ds abc '[X*]' -> XX (expected: X)

         POSIX specifies [c*] as the canonical mechanism to pad SET2 to
         match SET1's length. It is used in every major tr tutorial for
         many-to-one mapping (e.g., converting all uppercase to a single
         marker character).
Fix: In runTrWithInput, after parsing set2 (line 481), check whether a
     [c*] was encountered. One clean approach: have parseSet return a
     separate field indicating a fill character was requested, then
     expand that character to (set1.len - non-fill-chars.len) copies
     before building the translation table. Alternatively, track the
     fill character during parseRepeat via an out-of-band channel and
     apply the expansion in runTrWithInput where both set1.len and the
     fill character are in scope.
```

```
[IMPORTANT] Extra operands silently ignored instead of rejected
Location: src/tr.zig:421-438 (argument validation in runTr)
Problem: tr accepts at most two operands (SET1 and SET2). Both macOS
         and GNU tr exit 1 with an error when a third operand is given.
         vibeutils passes extra positionals through silently:

           echo test | tr a b c d   -> test  (exit 0, no error)

         macOS: "tr: extra operand 'c'"  (exit 1)
         GNU:   "tr: extra operand 'c'"  (exit 1)

         Scripts that mistype a tr invocation will produce wrong output
         without any diagnostic.
Fix: After the existing operand-count checks (line 436), add:

     if (parsed.positionals.len > 2) {
         common.printErrorWithProgram(allocator, stderr_writer, prog_name,
             "extra operand '{s}'", .{parsed.positionals[2]});
         return @intFromEnum(common.ExitCode.general_error);
     }

     Note: macOS exits 1 (general_error), not 2 (misuse), for this
     error.
```

```
[IMPORTANT] process* functions declared !u8 but never actually return errors
Location: src/tr.zig:519, 545, 578, 606, 642
Problem: All five process functions (processTranslate,
         processTranslateSqueeze, processDelete, processDeleteSqueeze,
         processSqueeze) are typed !u8 but every error path is caught
         inline and converted to a u8 exit code. The error union return
         type is dead — the functions could be typed u8. The misleading
         signature adds no safety (callers use `return`, not `try`) and
         implies callers must handle errors that never actually propagate.
Fix: Change all five function signatures from `!u8` to `u8`. Update
     the callers in runTrWithInput (lines 497, 500, 503, 506, 509)
     from `return func(...)` (which is valid) to match; no other
     changes needed. The internal catch blocks remain as-is.
```

```
[IMPORTANT] -u (SHOULD) is a stub with no behavioral effect
Location: src/tr.zig:35 (TrArgs.ignored_u), src/tr.zig:36 (meta)
Problem: -u is documented in the macOS man page as "Guarantee that any
         output is unbuffered." vibeutils accepts -u without error (the
         field is named `ignored_u`) but the output remains buffered
         through the 8192-byte stdout buffer regardless. This is
         acceptable for a SHOULD flag, but the implementation should be
         explicitly documented as a known stub in the source, not just
         in the field name.
Fix: Add a source comment near the ignored_u field explaining that
     unbuffered output is not implemented and why (buffered I/O is
     intentional in this codebase for performance). Acceptable as-is
     if the project's SHOULD-flag policy allows stubs that don't error.
```

```
[SUGGESTION] buildTranslationTable does not detect duplicate SET1 entries
Location: src/tr.zig:334-352
Problem: When SET1 contains duplicate characters (which can happen via
         [c*n] in SET1 or overlapping ranges), the table is written
         multiple times for the same index. The last write wins
         silently. For example:

           printf 'xxx' | tr '[x*3]' 'abc'  -> ccc

         The expected result per POSIX is that the last mapping for a
         duplicate entry is used, so 'ccc' is technically correct.
         However, there is no diagnostic for this case, and users
         sometimes expect the first mapping to win. This matches GNU/macOS
         behavior (last mapping wins) — noting it for completeness.
Fix: No code change required. Consider adding a comment at line 346
     documenting the last-write-wins policy for duplicate SET1 entries.
```

```
[SUGGESTION] No validation that SET1 is non-empty in translate mode
Location: src/tr.zig:455-459 (parseSet SET1)
Problem: If SET1 parses to an empty slice (e.g., from a backslash at
         end of string that falls through the literal-backslash path),
         no translation occurs and the input passes through unchanged
         with exit 0. This is unlikely in practice but produces no
         diagnostic.
Fix: After line 459, add a check:
     if (raw_set1.len == 0) {
         common.printErrorWithProgram(allocator, stderr_writer,
             prog_name, "SET1 is empty", .{});
         return @intFromEnum(common.ExitCode.misuse);
     }
```

---

## Architecture Notes (No Issues)

The filter architecture is correct and clean. `runTr` reads from
`std.fs.File.stdin()` only after all argument validation, so the
early-return paths (help, version, bad flags, missing operands)
never touch stdin. The internal `runTrWithInput` function accepts
a `std.fs.File` parameter, enabling unit tests to inject a tmpDir-
backed file without any stdin exposure. This pattern is sound.

I/O uses `writerStreaming` with 8192-byte buffers throughout,
consistent with the project's post-Writergate conventions.
`stdout.flush()` is called unconditionally in `main()` before
`process.exit()`, preventing truncated output. Write errors in
the inner loops are caught and converted to `general_error (1)`,
which is the correct POSIX behavior for write failures (e.g.,
broken pipe).

The complement implementation (`complementSet`) produces all 256
byte values not in SET1, ordered by byte value. This matches the
macOS/POSIX specification.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| IMPORTANT | 3 |
| SUGGESTION | 2 |

**Fix Order:**
```
1. [CRITICAL]  [c*] fill-to-SET1-length unimplemented —
               src/tr.zig:290-292, 483-486
2. [IMPORTANT] Extra operands silently ignored —
               src/tr.zig:421-438
3. [IMPORTANT] process* functions wrongly typed !u8 —
               src/tr.zig:519, 545, 578, 606, 642
4. [IMPORTANT] -u stub undocumented in source —
               src/tr.zig:35-36
5. [SUGGESTION] Document last-write-wins for duplicate SET1 —
               src/tr.zig:346
6. [SUGGESTION] Validate SET1 non-empty in translate mode —
               src/tr.zig:455-459
```

REVIEW COMPLETE - NEEDS_FIXES
