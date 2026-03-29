# Integration Test Audit: dd

**Date**: 2026-03-28
**Test file**: tests/utilities/dd_test.sh
**Flags spec**: docs/specs/dd-flags.md
**Test run**: 22 tests, 22 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 22 tests pass. The test suite covers the primary operands and
basic I/O behavior with strong output-verifying tests. However,
the majority of MUST-tier conv= values have no integration test,
three operands explicitly documented as stubs (iflag=, oflag=,
speed=) are silently accepted without behavioral verification, and
several important edge-case behaviors (ibs/obs interaction, osync
padding, notrunc, sync padding) are untested. The status=noxfer
test is also incorrect.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| dd binary | binary exists | Weak |
| dd --help | exit code 0 | Weak |
| dd --version | exit code 0 | Weak |
| dd basic file copy | file content exact | Strong |
| dd copy with bs=1024 | file content exact | Strong |
| dd count=2 bs=5 | file content exact | Strong |
| dd count=0 copies nothing | file empty check | Strong |
| dd skip=1 bs=4 | file content exact | Strong |
| dd seek=1 bs=4 | file size check | Moderate |
| dd conv=ucase | file content exact | Strong |
| dd conv=lcase | file content exact | Strong |
| dd status=none | stderr empty | Strong |
| dd default status shows records | stderr pattern | Strong |
| dd status=noxfer | stderr pattern | INCORRECT |
| dd from stdin to stdout | stdout exact | Strong |
| dd nonexistent input | exit non-zero | Weak |
| dd invalid operand | exit non-zero | Weak |
| dd lcase+ucase conflict | exit non-zero | Weak |
| dd bs=1K suffix | file size exact | Strong |
| dd success exit code | exit code 0 | Weak |
| dd failure exit code | exit code 1 | Weak |
| dd bs=1 count=5 (argsFree regression) | stdout exact | Strong |

---

## Incorrect Tests

### status=noxfer test logic is inverted

**Location**: tests/utilities/dd_test.sh:136-140

The test checks that stderr contains `"records in"` AND does not
contain `"bytes"`:

```bash
if echo "$stderr_output" | grep -q "records in" && \
   ! echo "$stderr_output" | grep -q "bytes"; then
```

The GNU/BSD spec for `status=noxfer` is: print the records
counts but suppress the transfer rate/bytes line. The test
correctly captures the intent, but the `"bytes"` pattern is too
broad. The final stats line emitted by our implementation
contains `"bytes copied"`. Depending on exact wording the check
may pass even when the bytes line is still printed if the word
`"bytes"` appears elsewhere. More critically: if the
implementation is broken and prints nothing at all, `grep -q
"records in"` would fail, making the test fail for the wrong
reason. The test needs a positive assertion that the records line
is present AND a negative assertion that the transfer-rate line
(a more specific pattern such as `"bytes copied"` or
`"bytes/sec"`) is absent.

---

## Weak Tests

### --help / --version

**Location**: tests/utilities/dd_test.sh:15 (via test_basic_flags)

`test_basic_flags` only checks exit code 0. It does not verify
that help or version text is printed. A no-op implementation
would pass.

### Error-handling tests

**Location**: tests/utilities/dd_test.sh:156-174

Three tests (nonexistent input, invalid operand, lcase+ucase
conflict) only verify a non-zero exit code. They do not check
that an error message is written to stderr. A silent crash would
pass.

### seek=1 bs=4

**Location**: tests/utilities/dd_test.sh:76-85

Verifies output file size is 8 bytes after seeking 1 block. This
is moderate: it confirms seek created the expected sparse region,
but does not check that the leading 4 bytes are NUL and the
trailing 4 bytes are the input data. A correct size from a
different write pattern would pass.

---

## Coverage Gaps: MUST-Tier Operands

### ibs= and obs= (separate input/output block sizes)

The only ibs/obs test is the combined bs= operand. There is no
test that sets ibs and obs to different values and verifies the
aggregation/splitting behavior. This is a distinct code path from
bs= (simple_copy mode vs. aggregation mode in src/dd.zig:616).

### cbs= with conv=block

**Required by MUST tier.** conv=block pads newline-terminated
records to cbs size. No integration test exists. The
implementation at src/dd.zig:683-708 is non-trivial and
untested at the integration level.

### cbs= with conv=unblock

**Required by MUST tier.** conv=unblock converts fixed-size
records back to newline-terminated. No integration test exists.

### conv=swab

**Required by MUST tier.** Swaps byte pairs. No integration test
exists. An even-length input like `"ABCD"` should produce
`"BADC"`.

### conv=sync (padding behavior)

**Required by MUST tier.** When an input block is shorter than
ibs, sync pads it with NUL bytes. No integration test verifies
the padding. Example: `bs=4 conv=sync` on a 3-byte input should
produce a 4-byte output.

### conv=noerror

**Required by MUST tier.** On read error, continue rather than
abort. No integration test exists. Testing requires a device or
file that produces read errors (or use of a named pipe that
closes mid-stream).

### conv=notrunc (output file not truncated)

**Required by MUST tier.** When writing to an existing larger
file with conv=notrunc, the file should not be truncated. The
existing seek test uses conv=notrunc only as a side effect of
seeking; there is no test that writes a small file over a large
file and verifies the tail bytes are preserved.

### conv=fsync and conv=osync

**Required by MUST tier.** fsync flushes to disk on close; osync
pads the final output block to obs size. Both are accepted in
parsing but have no behavioral integration test. osync in
particular changes output size in a verifiable way.

### conv=ascii and conv=ebcdic

**Required by MUST tier.** EBCDIC/ASCII character set
translation. No integration test exists. A round-trip test
(ascii->ebcdic->ascii) should reproduce the original bytes.

### conv=ibm

**Required by MUST tier.** No integration test exists.

### files=

**Required by MUST tier** (per dd-flags.md). No integration test
exists. Testing on regular files rather than tape would require
chaining two input files, which our implementation supports via
the files= counter.

---

## Coverage Gaps: SHOULD-Tier Operands

### iflag= (silently stubbed)

**Location**: src/dd.zig:173-174

iflag= is parsed and silently ignored. The unit test at
src/dd.zig:1828 only verifies that the operand parses without
error; it does not verify the flag has any effect.
`iflag=fullblock` changes read semantics: without it, count=
counts read(2) calls; with it, count= counts complete blocks.
This is a behavioral difference that integration tests should
cover once the stub is implemented.

### oflag= (silently stubbed)

**Location**: src/dd.zig:175-176

Same situation as iflag=. `oflag=fsync` and `oflag=sync` should
force synchronous writes. Stubbed and untested behaviorally.

### iseek= / oseek= (synonyms for skip=/seek=)

No integration test verifies that `iseek=N` is equivalent to
`skip=N` and `oseek=N` is equivalent to `seek=N`.

### speed= (silently stubbed)

**Location**: src/dd.zig:177-178

Stubbed. No integration test. A rate-limit test is hard to write
reliably, but at minimum a test should verify that
`speed=1000000` does not change output content.

### fillchar=

The fillchar= operand is parsed and stored but is only used
during conv=block padding and conv=noerror+sync NUL-fill. No
integration test verifies that fillchar=X causes X to be used as
the pad character rather than the default space or NUL.

### status=progress

No integration test. The output format for periodic progress
reporting is unverified.

### oldascii / oldebcdic / oldibm

These are treated as aliases for ascii/ebcdic/ibm in the parser
(src/dd.zig:233-238) rather than using separate translation
tables. No integration test verifies either that the alias works
or that the translation is correct.

---

## Findings Summary

```
Fix Order:
1. [IMPORTANT] status=noxfer test uses a pattern that could pass
   incorrectly — tests/utilities/dd_test.sh:136
2. [IMPORTANT] conv=swab has no integration test — MUST tier
3. [IMPORTANT] conv=sync (padding) has no integration test — MUST tier
4. [IMPORTANT] conv=block + cbs= has no integration test — MUST tier
5. [IMPORTANT] conv=unblock + cbs= has no integration test — MUST tier
6. [IMPORTANT] conv=notrunc behavioral test is missing — MUST tier
7. [IMPORTANT] conv=ascii / conv=ebcdic have no integration tests — MUST tier
8. [IMPORTANT] conv=ibm has no integration test — MUST tier
9. [IMPORTANT] conv=fsync / conv=osync have no behavioral tests — MUST tier
10. [IMPORTANT] ibs= and obs= separate-path behavior is untested — MUST tier
11. [IMPORTANT] files= has no integration test — MUST tier
12. [SUGGESTION] iflag=/oflag= stubs should have a "content unchanged"
    smoke test until the real implementation lands
13. [SUGGESTION] iseek=/oseek= synonym equivalence is untested
14. [SUGGESTION] fillchar= behavioral test is missing
15. [SUGGESTION] oldascii/oldebcdic/oldibm alias correctness is untested
16. [SUGGESTION] Error-handling tests should assert stderr message content,
    not just non-zero exit code
```

**Counts**: 0 CRITICAL, 11 IMPORTANT, 5 SUGGESTION

**Assessment**: NEEDS_FIXES

The core copy path (if=, of=, bs=, count=, skip=, seek=,
conv=ucase/lcase, status=none/default) is well covered by strong
tests. The gaps are concentrated in the conversion subsystem
where the majority of MUST-tier conv= values have no integration
test, and in operands (ibs/obs, files=) that exercise different
code paths from the tested bs= fast path.
