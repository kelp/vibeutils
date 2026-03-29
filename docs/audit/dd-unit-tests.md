# dd Unit Test Audit

**Date:** 2026-03-28
**File audited:** `src/dd.zig`
**Spec reference:** `docs/specs/dd-flags.md`, `docs/specs/dd-macos.txt`
**Test run result:** All dd tests pass (all suites green, 0 failures)

---

## Test Inventory

74 test blocks total. Classification below.

### BEHAVIOR tests (verify program output or side effects)

| Test name | What it verifies |
|-----------|-----------------|
| `runDd - help flag` | exit 0, "Usage: dd" in stdout |
| `runDd - version flag` | exit 0, "dd (vibeutils)" in stdout |
| `runDd - basic file copy` | file contents copied verbatim |
| `runDd - copy with count` | count=1 bs=10 copies exactly 10 bytes |
| `runDd - copy with conv=ucase` | lowercase input becomes uppercase |
| `runDd - copy with conv=lcase` | uppercase input becomes lowercase |
| `runDd - skip blocks` | skip=1 bs=4 omits first 4 bytes |
| `runDd - statistics output` | stderr contains "records in", "records out", "bytes" |
| `runDd - status=none suppresses output` | stderr is empty |
| `runDd - status=noxfer omits transfer line` | records printed, bytes line absent |
| `runDd - mutually exclusive lcase and ucase` | exit 2 |
| `runDd - nonexistent input file` | exit 1, stderr non-empty |
| `runDd - invalid operand` | exit 2 |
| `runDd - zero block size` | exit 2 |
| `runDd - different ibs and obs` | ibs=4 obs=8 copies data intact |
| `runDd - count=0 copies nothing` | output file is empty |
| `runDd - conv=swab swaps byte pairs` | "ABCD" -> "BADC" |
| `runDd - conv=ebcdic converts ASCII to EBCDIC` | 'A' -> 0xC1 |
| `runDd - conv=ascii converts EBCDIC to ASCII` | 0xC1 -> 'A' |
| `runDd - conv=osync pads final block` | 3-byte input + obs=8 yields 8 bytes |
| `runDd - conv=block pads records to cbs size` | "ab\ncd\n" cbs=5 -> "ab   cd   " |
| `runDd - conv=unblock replaces trailing spaces` | "ab   cd   " cbs=5 -> "ab\ncd\n" |
| `runDd - conv=noxfer is rejected` | exit non-zero |
| `runDd - mutually exclusive ascii and ebcdic` | exit 2 |
| `runDd - mutually exclusive block and unblock` | exit 2 |
| `runDd - block requires cbs` | exit 2 |
| `runDd - unblock requires cbs` | exit 2 |
| `runDd - conv=block with fillchar` | "ab" + cbs=5 + fillchar=X -> "abXXX" |
| `runDd - iseek skips input blocks` | iseek=1 bs=4 -> "BBBB" |
| `runDd - multi-block copy with bs and count` | 20-byte input, bs=4 count=3 -> 12 bytes |
| `applyConversions - lcase` | "HELLO WORLD 123" -> "hello world 123" |
| `applyConversions - ucase` | "hello world 123" -> "HELLO WORLD 123" |
| `applyConversions - no conversion` | buffer unchanged |
| `applyConversions - swab even length` | "ABCD" -> "BADC" |
| `applyConversions - swab odd length` | last byte zeroed |
| `applyConversions - ebcdic conversion` | 'A' -> 0xC1 |
| `applyConversions - ascii conversion` | 0xC1 -> 'A' |
| `applyConversions - ibm conversion` | 'A' -> 0xC1 |
| `formatByteCount - various sizes` | 500/1500/1500000/1500000000 formatted correctly |
| `EBCDIC round-trip` | ascii->ebcdic->ascii is identity for 0..127 |

### PARSING tests (struct-field checks only — no program output verified)

| Test name | Fields checked |
|-----------|---------------|
| `parseByteSize - plain numbers` | return value |
| `parseByteSize - with suffixes` | return value |
| `parseByteSize - multiplication with x` | return value |
| `parseByteSize - errors` | error returns |
| `parseOperands - basic operands` | input_file, output_file, bs |
| `parseOperands - ibs and obs` | ibs, obs, bs==null |
| `parseOperands - count skip seek` | count, skip, seek |
| `parseOperands - conversions` | conv_lcase, conv_ucase, conv_notrunc, conv_noerror, conv_sync |
| `parseOperands - status levels` | status enum value |
| `parseOperands - help and version` | help, version booleans |
| `parseOperands - errors` | error returns |
| `parseOperands - defaults` | all 20+ default field values |
| `parseOperands - cbs operand` | cbs |
| `parseOperands - cbs default is null` | cbs==null |
| `parseOperands - files operand` | files |
| `parseConversions - fsync` | conv_fsync |
| `parseConversions - osync` | conv_osync |
| `parseConversions - swab` | conv_swab |
| `parseConversions - noxfer is rejected in conv` | error return |
| `parseConversions - ascii` | conv_ascii |
| `parseConversions - ebcdic` | conv_ebcdic |
| `parseConversions - ibm` | conv_ibm |
| `parseConversions - block` | conv_block |
| `parseConversions - unblock` | conv_unblock |
| `parseConversions - multiple new conversions` | conv_swab + conv_fsync |
| `parseOperands - iseek maps to skip` | skip |
| `parseOperands - oseek maps to seek` | seek |
| `parseOperands - fillchar single character` | fillchar |
| `parseOperands - fillchar rejects multi-char` | error return |
| `parseOperands - fillchar rejects empty` | error return |
| `parseOperands - iflag accepted and ignored` | input_file==null (wrong field) |
| `parseOperands - oflag accepted and ignored` | output_file==null (wrong field) |
| `parseOperands - speed accepted and ignored` | input_file==null (wrong field) |
| `parseOperands - speed rejects non-numeric` | error return |
| `parseConversions - oldascii maps to ascii` | conv_ascii |
| `parseConversions - oldebcdic maps to ebcdic` | conv_ebcdic |
| `parseConversions - oldibm maps to ibm` | conv_ibm |
| `parseConversions - sparse accepted as no-op` | conv_sparse |
| `parseConversions - pareven accepted as no-op` | conv_pareven |
| `parseConversions - parnone accepted as no-op` | conv_parnone |
| `parseConversions - parodd accepted as no-op` | conv_parodd |
| `parseConversions - parset accepted as no-op` | conv_parset |
| `parseConversions - multiple parity and sparse` | conv_sparse + conv_pareven + conv_lcase |

---

## Findings

### CRITICAL — Stub Tests (parse-only, cannot detect behavior regressions)

**[CRITICAL] `parseOperands - iflag accepted and ignored` is a meaningless check**
Location: `src/dd.zig:1828-1833`
Problem: Asserts `config.input_file == null`. This field is unrelated to
`iflag`. The assertion is trivially true regardless of whether iflag is
parsed, rejected, or silently ignored. A test that deletes iflag handling
entirely would still pass this assertion. The comment "flags are silently
ignored" documents intended behavior that is never verified.
Fix: Assert that `parseOperands` returns without error (which the `try`
already does implicitly), then add a `runDd` behavioral test that passes
`iflag=fullblock` and verifies the copy succeeds and data is correct.

**[CRITICAL] `parseOperands - oflag accepted and ignored` is a meaningless check**
Location: `src/dd.zig:1835-1840`
Problem: Same pattern as iflag above. Asserts `config.output_file == null`,
which is unrelated to oflag. Any mutation to oflag parsing passes this test.
Fix: Same as iflag: verify the copy succeeds end-to-end when oflag is
present.

**[CRITICAL] `parseOperands - speed accepted and ignored` is a meaningless check**
Location: `src/dd.zig:1842-1846`
Problem: Asserts `config.input_file == null`. Completely unrelated to speed.
The intent (speed is accepted without error) is already guaranteed by the
`try` unwrap, making the extra assertion actively misleading.
Fix: Remove the misleading assertion or replace with a `runDd` behavioral
test confirming a copy with `speed=1000000` completes successfully.

---

### IMPORTANT — Missing Behavioral Coverage

**[IMPORTANT] `conv=sync` has no behavioral test**
Location: `src/dd.zig` (no runDd test for conv=sync)
Problem: `conv=sync` is a MUST-tier flag. The spec says short input blocks
are NUL-padded to ibs size. Only `parseOperands - conversions` checks the
parsed field. No test verifies the output is actually padded.
Fix: Write a `runDd` test: ibs=8, input of 3 bytes, conv=sync. Expect 8
bytes of output with the last 5 bytes being NUL.

**[IMPORTANT] `conv=notrunc` has no behavioral test**
Location: `src/dd.zig` (no runDd test for conv=notrunc)
Problem: `conv=notrunc` is MUST-tier. The implementation gates on this flag
to decide whether to truncate the output file at open time. No test verifies
that a pre-existing longer output file is not truncated when notrunc is set.
Fix: Write a `runDd` test: create an 8-byte output file, run dd with a
3-byte input and `conv=notrunc`, verify the output file is still 8 bytes
(original tail preserved).

**[IMPORTANT] `conv=noerror` has no behavioral test**
Location: `src/dd.zig` (no runDd test for conv=noerror)
Problem: `conv=noerror` is MUST-tier. The behavior on read error is
non-trivial (prints a warning but continues). Testing this path likely
requires a synthetic read error, which is hard in unit tests; an integration
test would suffice, but none exists.
Fix: At minimum, document in an `// TODO` comment that behavioral coverage
lives in integration tests, and add the integration test. Or use a named
pipe or /proc path to simulate a read error.

**[IMPORTANT] `seek=` has no behavioral test**
Location: `src/dd.zig` (no runDd test for seek=)
Problem: `seek=` is MUST-tier. The implementation attempts seekTo then falls
back to writing zeros. No test verifies that output data is written at the
correct offset. The skip= operand does have a behavioral test; seek= does
not.
Fix: Write a `runDd` test: seek=2 bs=4, 4-byte input "ABCD". The output
file should have 8 bytes: 8 NUL bytes followed by "ABCD" (or the first 8
bytes zeroed from the seek, depending on seekTo support on the temp file).

**[IMPORTANT] `oseek=` alias has no behavioral test**
Location: `src/dd.zig:1806-1810`
Problem: `parseOperands - oseek maps to seek` only checks the struct field.
oseek= is documented as a synonym for seek=. No end-to-end test confirms
that passing `oseek=N` produces the same output offset as `seek=N`.
Fix: Reuse or extend the seek= behavioral test to cover oseek= as well.

**[IMPORTANT] `conv=ibm` has no end-to-end behavioral test**
Location: `src/dd.zig` (no runDd test for conv=ibm)
Problem: `applyConversions - ibm conversion` checks the table at the
function level for a single byte ('A'). No `runDd` test exercises ibm
through the full copy path with a real file. Given that ibm and ebcdic share
the same code path in `applyConversions` but use a different table, a copy
regression could go undetected.
Fix: Add a `runDd` test mirroring `runDd - conv=ebcdic converts ASCII to
EBCDIC` but using `conv=ibm`.

**[IMPORTANT] `conv=block` partial-record flush has no dedicated test**
Location: `src/dd.zig:797-808`
Problem: The existing `conv=block` test uses input that ends with `\n`, so
the final-record flush path at line 798 is never exercised. The partial
flush path (input with no trailing newline) is untested.
Fix: Add a test with input `"ab"` (no trailing newline), cbs=5. The partial
record should be flushed and padded to 5 bytes: `"ab   "` (or `"abXXX"` with
fillchar).

**[IMPORTANT] `conv=unblock` partial-record flush has no dedicated test**
Location: `src/dd.zig:810-826`
Problem: The existing `conv=unblock` test uses exactly 10 bytes of input
(two complete 5-byte records). The partial-flush path (input length not a
multiple of cbs) at line 811 is untested.
Fix: Add a test with 7 bytes input for cbs=5. Records: one complete 5-byte
record and a 2-byte partial. Verify the partial is flushed with a newline.

---

### SUGGESTION — Minor Issues

**[SUGGESTION] `parseOperands - defaults` tests all 20+ struct fields in one block**
Location: `src/dd.zig:1007-1040`
Problem: Any future field addition that lacks a default will not be caught
by this test because developers tend to append to the struct and forget to
update the test. This is a maintenance concern, not a correctness bug.
Fix: No immediate action required; note for future reviewers.

**[SUGGESTION] `runDd - conv=noxfer is rejected` uses inexact assertion**
Location: `src/dd.zig:1748`
Problem: Asserts `exit_code != 0` rather than the specific exit code 2
(misuse). All other error-path tests use `expectEqual(@as(u8, 2), ...)`.
Fix: Change to `try testing.expectEqual(@as(u8, 2), exit_code);` for
consistency.

**[SUGGESTION] `status=progress` is parsed and accepted but has no behavioral test**
Location: `src/dd.zig` (no runDd test for status=progress)
Problem: `status=progress` is a SHOULD-tier flag. The implementation falls
through to the same `printStats` logic as default. No test confirms the
output format for progress mode, and whether it differs from the default.
Fix: Add a test or a comment explicitly noting that progress mode is
behaviorally identical to default in this implementation.

**[SUGGESTION] `files=` has no behavioral test**
Location: `src/dd.zig`
Problem: `files=` is MUST-tier per the spec but its implementation in
`DdConfig` stores the value without the copy loop ever consulting it. The
copy loop has no `files` logic. The flag is accepted and stored but silently
has no effect.
Fix: Either implement `files=` behavior and add a test, or explicitly mark
it as a stub in the code and add a failing test or TODO comment noting the
gap. Accepting and storing a value with no effect is a correctness bug
masquerading as an accepted flag.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 7 |
| SUGGESTION | 4 |

**Overall assessment: NEEDS_FIXES**

The dd unit tests are substantially better than average for this codebase.
The behavioral test suite is real: 30+ tests exercise `runDd` end-to-end
with actual file I/O and output verification. The three CRITICAL items are
misleading assertions on unrelated fields, not total coverage gaps. The
IMPORTANT items are genuine missing behavioral coverage for MUST-tier flags
(`conv=sync`, `conv=notrunc`, `seek=`, `conv=ibm`) and untested flush paths
in `conv=block`/`conv=unblock`. The `files=` SUGGESTION is potentially a
correctness defect: the flag is accepted, stored, and ignored.

```
Fix Order:
1. [CRITICAL] iflag stub — src/dd.zig:1828
2. [CRITICAL] oflag stub — src/dd.zig:1835
3. [CRITICAL] speed stub — src/dd.zig:1842
4. [IMPORTANT] conv=sync no behavioral test — src/dd.zig (copy loop)
5. [IMPORTANT] conv=notrunc no behavioral test — src/dd.zig:562
6. [IMPORTANT] seek= no behavioral test — src/dd.zig:583
7. [IMPORTANT] oseek= no behavioral test — src/dd.zig:1806
8. [IMPORTANT] conv=ibm no end-to-end test — src/dd.zig:334
9. [IMPORTANT] conv=block partial flush untested — src/dd.zig:797
10. [IMPORTANT] conv=unblock partial flush untested — src/dd.zig:810
11. [SUGGESTION] files= silently ignored (possible correctness defect) — src/dd.zig:43
12. [SUGGESTION] conv=noxfer test uses != 0 instead of == 2 — src/dd.zig:1748
13. [SUGGESTION] status=progress not verified — src/dd.zig
14. [SUGGESTION] parseOperands - defaults maintenance risk — src/dd.zig:1007
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
