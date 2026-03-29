# wc Code Audit

Date: 2026-03-28
File: `src/wc.zig`
Build: passes (`just build-util wc`)
Unit tests: pass (`zig build test`)
Integration tests: 96/96 pass (`just it-util wc`)

---

## Findings

---

```
[CRITICAL] -c and -m are not mutually exclusive in GNU — both columns
           print when both flags are given
Location: src/wc.zig:182-208
Problem: The code treats -c/-m as mutually exclusive ("last flag wins")
         and removes one flag. GNU wc displays both char and byte columns
         when both are specified. The column order for -lmcw is:
         newline, word, character, byte, max_line_length. Verified:
           printf "café\n" | wc -cm
           GNU output:  5  6       (chars then bytes)
           Our output:  5          (only one column)
         The integration tests at lines 91-92 of wc_test.sh encode this
         wrong behavior as the expected values, so the tests pass while
         hiding the bug.
Fix: Remove the entire mutual-exclusion block (lines 182-208). When both
     opts.chars and opts.bytes are true, printStats already handles both
     separately — chars prints at its position, bytes at its position.
     Both columns will appear in the correct GNU-mandated order.
```

---

```
[CRITICAL] -L counts raw bytes, not display columns
Location: src/wc.zig:302-353 (countReader function)
Problem: current_line_length is incremented by 1 for every non-newline
         byte. GNU -L counts display width: tabs expand to the next 8-
         column tab stop; multibyte characters contribute their display
         width (e.g., CJK chars are 2 columns). Verified:
           printf "ab\tcd\n" | wc -L
           GNU: 10   (ab=2, tab expands to col 8, cd=2 → total 10)
           Ours: 5   (counts 5 raw bytes: a b \t c d)

           printf "hello 世界\n" | wc -L
           GNU: 10   (hello=5, space=1, 世=2, 界=2 → 10 display cols)
           Ours: 12  (counts 12 non-newline bytes)
         The integration tests do not cover tabs or multibyte in -L, so
         all 96 tests pass while the bug exists.
Fix: Replace the raw-byte line-length counter with a display-width
     counter. For each byte/codepoint:
     - Tab: advance to next multiple of 8
       (new_len = (current_line_length / 8 + 1) * 8)
     - ASCII printable (0x20–0x7E): add 1
     - UTF-8 continuation byte (10xxxxxx): skip (width already counted
       on the lead byte)
     - UTF-8 lead byte: decode the codepoint and call wcwidth() or a
       table lookup for display width (0 for combining, 1 for most, 2
       for CJK wide chars)
     - Control chars: 0 or counted per POSIX terminal rules (GNU skips
       non-printable non-tab control chars in the count)
```

---

```
[IMPORTANT] Error messages use Zig error names, not POSIX strings
Location: src/wc.zig:255, 268, 276
Problem: Error messages use @errorName(err) which produces Zig-internal
         names such as "FileNotFound" and "AccessDenied". GNU wc prints
         POSIX strerror() strings: "No such file or directory",
         "Permission denied". Verified:
           wc /nonexistent
           GNU:  wc: /nonexistent: No such file or directory
           Ours: wc: /nonexistent: FileNotFound
Fix: Map Zig errors to POSIX strings, or call std.posix.strerror on the
     underlying errno. The common pattern used elsewhere in vibeutils is
     to translate via a helper. At minimum:
       error.FileNotFound => "No such file or directory"
       error.AccessDenied => "Permission denied"
       error.IsDir        => "Is a directory"  (already handled)
```

---

```
[IMPORTANT] Directory argument: stats line suppressed before error
Location: src/wc.zig:260-264
Problem: When a directory is passed, the code skips printing stats and
         jumps to the error. GNU wc prints a "0 0 0 /dir" stats line
         first, then the error on stderr. Verified:
           wc /tmp
           GNU:  0  0  0 /tmp
                 wc: /tmp: Is a directory
           Ours: (no stats line)
                 wc: /tmp: Is a directory
Fix: Print the zero stats for the directory before emitting the error.
     Set stat values to all zeros and call printStats before the error
     message.
```

---

```
[IMPORTANT] Error output ordering differs from GNU (stderr buffering)
Location: src/wc.zig:130-133 (buffered stderr)
Problem: stderr is buffered in an 8192-byte buffer and flushed only at
         exit. GNU wc interleaves error messages with output in file-
         argument order. Our buffering causes all error lines to appear
         after all stdout. Verified:
           wc /nonexistent good.txt
           GNU:  wc: /nonexistent: No such file or directory
                 1 1 6 good.txt
                 1 1 6 total
           Ours: 1 1 6 good.txt
                 1 1 6 total
                 wc: /nonexistent: FileNotFound
Fix: Flush stderr after each per-file error:
       stderr.flush() catch {};
     inside the error-handling branches at lines 255, 261, 269, 277.
```

---

```
[IMPORTANT] Word counting is ASCII-only, not locale-aware
Location: src/wc.zig:337
Problem: Word boundaries use std.ascii.isWhitespace(), which only
         recognises the 6 ASCII whitespace bytes (0x09 0x0A 0x0B 0x0C
         0x0D 0x20). GNU wc uses iswspace() after decoding UTF-8, so
         U+00A0 NO-BREAK SPACE (0xC2 0xA0) and other Unicode whitespace
         codepoints act as word boundaries. Verified:
           printf "word1\xc2\xa0word2\n" | wc -w
           GNU: 2    (U+00A0 is Unicode whitespace → splits words)
           Ours: 1   (0xC2 and 0xA0 are not ASCII whitespace)
Fix: Decode UTF-8 codepoints in the counting loop and call a Unicode
     whitespace check (e.g., consult a table for General Category Z*
     or the explicit Unicode whitespace set). For the common case of
     ASCII input, the fast path remains unchanged.
```

---

```
[SUGGESTION] Column width is fixed at 8; GNU uses dynamic width
Location: src/wc.zig:380-401 (printStats)
Problem: Every number is printed with "{d: >8}" (fixed 8-wide). GNU
         computes the minimum field width needed to fit the largest
         count across all files in the argument list, then pads to that
         width. For inputs with single-digit counts, GNU uses narrower
         columns (e.g., "1 1 2 file"). For very large counts (>9999999)
         the fixed-8 field would overflow. Verified:
           wc a.txt b.txt   (each has 1 line)
           GNU:  1 1 2 a.txt
           Ours:        1       1       2 a.txt
Fix: For stdin-only mode, compute required width after counting. For
     multi-file mode, either do a two-pass (count all files first, then
     print) or use a sufficiently wide field. The minimum GNU-compatible
     approach is to format each number without zero-padding and let
     the caller right-pad to the max observed digit-count.
     This is a cosmetic difference for typical inputs but a correctness
     issue when counts exceed 99999999.
```

---

## Summary

| Severity   | Count |
|------------|-------|
| CRITICAL   | 2     |
| IMPORTANT  | 3     |
| SUGGESTION | 1     |

**Assessment: NEEDS_FIXES**

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -c/-m mutual exclusion: remove last-wins logic — src/wc.zig:182-208
2. [CRITICAL] -L counts raw bytes not display columns — src/wc.zig:302-353
3. [IMPORTANT] Error messages use Zig names not POSIX strings — src/wc.zig:255,268,276
4. [IMPORTANT] Directory arg prints no stats before error — src/wc.zig:260-264
5. [IMPORTANT] stderr buffering causes wrong error ordering — src/wc.zig:255,261,269,277
6. [IMPORTANT] Word counting is ASCII-only, not Unicode-aware — src/wc.zig:337
7. [SUGGESTION] Column width is fixed 8; GNU uses dynamic width — src/wc.zig:380-401
```

REVIEW COMPLETE - NEEDS_FIXES
