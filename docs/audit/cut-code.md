# Code Audit: cut

**Date**: 2026-03-28
**File**: src/cut.zig
**Build result**: passes (`just build-util cut`)
**Integration tests**: 64/64 pass (`just it-util cut`)
**Unit tests**: full suite hangs (unrelated stdin test in
  another utility); cut-specific logic verified manually

---

## Flag Verdict Table

| Flag | Tier | Verdict |
|------|------|---------|
| -b | MUST | PASS — byte selection correct |
| -c | MUST | PASS — behaves identically to -b (correct for GNU/macOS) |
| -d | MUST | PASS — single-byte delimiter enforced |
| -f | MUST | PASS — field splitting correct |
| -n | MUST | PASS — multi-byte character boundary protection works |
| -s | MUST | PASS — suppresses lines without delimiter |
| -w | SHOULD | PASS — whitespace tokenisation correct |
| -z | SHOULD | PASS — NUL-terminated line mode correct |
| --complement | SHOULD | PASS — complement selection correct |
| --output-delimiter | SHOULD | PASS — custom output delimiter correct |

---

## Issues

### [IMPORTANT] Range list rejects whitespace separators

Location: src/cut.zig:66
Problem: `parseRangeList` tokenises only on comma
(`tokenizeScalar(u8, list_str, ',')`). Both the macOS man
page (the primary reference) and GNU cut accept whitespace
as an equivalent separator: `"a comma or whitespace
separated set of numbers"`. The following fails where both
macOS and GNU succeed:

```
printf 'abcde\n' | cut -b '1 3 5'   # expected: ace
```

Our binary exits 2 with "invalid range: '1 3 5'". GNU cut
and macOS cut both produce `ace`.

Fix: Change `tokenizeScalar(u8, list_str, ',')` to
`tokenizeAny(u8, list_str, ", \t")` so commas, spaces, and
tabs are all treated as item separators.

---

### [IMPORTANT] Stale RED-phase comment contradicts live code

Location: src/cut.zig:1295-1339
Problem: The test `"cut: processFile reports read errors to
stderr"` carries a comment claiming `processFile` discards
its `stderr_writer` parameter:

```zig
// the bug (line 469: _ = stderr_writer) means stderr stays empty.
// This assertion will FAIL because processFile discards stderr_writer
```

The comment is false. The current implementation passes
`stderr_writer` through and calls
`common.printErrorWithProgram(allocator, stderr_writer, ...)` on
read errors (line 481). The `_ = stderr_writer` discard was
removed during the fix, but the RED-phase framing was never
updated. The assertion at line 1339 (`stderr_buffer.items.len > 0`)
therefore documents correct expected behaviour, not a
known-failing assertion.

The misleading comment prevents future maintainers from
understanding whether the test is passing or intentionally
broken.

Fix: Remove the stale comment block (lines 1297-1299 and
1338). Replace with a straightforward description of what
the test verifies.

---

### [SUGGESTION] cutBytesOrChars writes one byte at a time

Location: src/cut.zig:159-168
Problem: The non-`no_split` byte path emits each selected
byte with `writer.writeAll(&.{byte})` — one syscall-ready
write per byte. For large inputs this generates a high
volume of tiny writes. The buffered writer in `main` absorbs
these at the 8192-byte buffer boundary, so correctness is
unaffected, but it is less efficient than accumulating a
slice and writing it once per contiguous selected run.

This is a minor concern for a coreutils utility that is
typically used in pipelines; the buffer absorbs the cost.

Fix (optional): Track the start of each contiguous selected
run and emit it with a single `writeAll` call when the run
ends.

---

## Strengths

- `processFile` handles all I/O errors internally and
  returns an exit code; callers never need `try`. The
  pattern is consistent and correct.
- I/O uses `writerStreaming` with 8192-byte buffers
  throughout — no `File.writer()` misuse.
- `stdin` is opened as `std.fs.File.stdin()`, not via
  `std.io.getStdIn()` (Writergate-safe).
- Error messages match the GNU format: "only one type of
  list may be specified", "the delimiter must be a single
  character", etc.
- `-n` semantics are correct: a multibyte character is only
  emitted when ALL its bytes fall within the selected range.
  The macOS spec requires this exact behaviour.
- Range parsing correctly handles overlapping and adjacent
  range merging, out-of-order ranges, and open-ended ranges.
- `-w` uses `tokenizeAny` which naturally handles multiple
  consecutive spaces/tabs as a single separator and skips
  leading whitespace — exactly what macOS specifies.
- The output delimiter for `-w` mode defaults to `" "` (a
  single space), which is a reasonable and consistent choice.
- Mutual-exclusivity constraints (`-w` and `-d`, `-s` and
  non-field mode, `-d` and non-field mode) are all enforced
  with clear error messages.

---

## Summary

**Counts**: 0 CRITICAL, 2 IMPORTANT, 1 SUGGESTION

**Fix Order**:
```
1. [IMPORTANT] Support whitespace list separators in
   parseRangeList — src/cut.zig:66
2. [IMPORTANT] Remove stale RED-phase comment contradicting
   live code — src/cut.zig:1297-1299, 1338
3. [SUGGESTION] Consider batching contiguous byte writes in
   cutBytesOrChars — src/cut.zig:162-167
```

REVIEW COMPLETE - NEEDS_FIXES
