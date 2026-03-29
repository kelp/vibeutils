# dd Code Audit

**Date:** 2026-03-28
**Auditor:** reviewer agent
**File:** `src/dd.zig`
**Assessment:** NEEDS_FIXES

---

## Executive Summary

The core dd copy engine is functional and correctly handles the
primary use cases: block copying, basic conversions (lcase, ucase,
swab, ascii/ebcdic), skip, seek, count, conv=block, and
conv=unblock. However, five flags accepted on the command line
produce no behavioral effect (stubs), three spec behaviors are
implemented incorrectly, and several minor deviations exist in
error messages and stats output. The implementation is not safe
to ship as spec-compliant for `iflag=`, `oflag=`, `speed=`,
`files=`, parity conversions, or `conv=sparse`.

---

## Flag-by-Flag Compliance Table

| Flag         | Tier   | Status      | Notes |
|--------------|--------|-------------|-------|
| if=          | MUST   | CORRECT     | |
| of=          | MUST   | CORRECT     | |
| bs=          | MUST   | CORRECT     | |
| ibs=         | MUST   | CORRECT     | |
| obs=         | MUST   | CORRECT     | |
| cbs=         | MUST   | CORRECT     | |
| skip=        | MUST   | CORRECT     | |
| seek=        | MUST   | CORRECT     | |
| count=       | MUST   | CORRECT     | |
| conv=        | MUST   | PARTIAL     | see below |
| files=       | MUST   | STUB        | parsed, never used in runDd |
| status=none  | MUST   | CORRECT     | |
| status=noxfer| MUST   | CORRECT     | |
| status=progress | MUST | INCORRECT  | behaves identically to default; no periodic 1s printing |
| fillchar=    | SHOULD | CORRECT     | |
| iflag=       | SHOULD | STUB        | silently accepted, all values ignored |
| iseek=       | SHOULD | CORRECT     | alias for skip= works |
| oflag=       | SHOULD | STUB        | silently accepted, all values ignored |
| oseek=       | SHOULD | CORRECT     | alias for seek= works |
| speed=       | SHOULD | STUB        | parses integer only, no rate limiting |

### conv= Values

| Value     | Tier   | Status      | Notes |
|-----------|--------|-------------|-------|
| ascii     | MUST   | CORRECT     | |
| ebcdic    | MUST   | CORRECT     | |
| ibm       | MUST   | CORRECT     | |
| block     | MUST   | INCORRECT   | no truncated-record count in stats |
| unblock   | MUST   | CORRECT     | |
| lcase     | MUST   | CORRECT     | |
| ucase     | MUST   | CORRECT     | |
| swab      | MUST   | INCORRECT   | odd byte zeroed instead of preserved |
| noerror   | MUST   | CORRECT     | |
| notrunc   | MUST   | CORRECT     | |
| sync      | MUST   | INCORRECT   | always pads with NUL; should use spaces with block-oriented conversions |
| fsync     | MUST   | CORRECT     | |
| osync     | MUST   | INCORRECT   | no incompatibility check with bs=; see below |
| oldascii  | SHOULD | INCORRECT   | maps to same table as ascii; should use separate old table |
| oldebcdic | SHOULD | INCORRECT   | maps to same table as ebcdic; should use separate old table |
| oldibm    | SHOULD | INCORRECT   | maps to same table as ibm; should use separate old table |
| sparse    | SHOULD | STUB        | flag parsed, zero sparse-write logic in runDd |
| pareven   | SHOULD | STUB        | flag parsed, zero parity logic in runDd |
| parnone   | SHOULD | STUB        | flag parsed, zero parity logic in runDd |
| parodd    | SHOULD | STUB        | flag parsed, zero parity logic in runDd |
| parset    | SHOULD | STUB        | flag parsed, zero parity logic in runDd |

---

## Stubs Found

```
[CRITICAL] files= parsed but never used
Location: src/dd.zig:158 (parse), no reference in runDd
Problem: config.files is stored but runDd never reads it. dd always
  copies exactly one "file" regardless of the operand value. For tape
  inputs this changes how many logical EOF records are consumed.
Fix: Use config.files as the outer loop count in runDd, advancing past
  EOF markers the correct number of times.
```

```
[CRITICAL] iflag= silently accepted with no effect
Location: src/dd.zig:173-174
Problem: All iflag= values (fullblock, direct) are parsed and
  discarded. iflag=fullblock must cause the read loop to retry short
  reads until a full ibs block is obtained. iflag=direct must set
  F_NOCACHE on the input file descriptor. Accepting the flag without
  acting on it produces wrong count semantics and no cache bypass.
Fix: Parse iflag into a struct; implement fullblock retry loop in the
  read path; call fcntl(F_NOCACHE) for direct on supported platforms.
```

```
[CRITICAL] oflag= silently accepted with no effect
Location: src/dd.zig:175-176
Problem: All oflag= values (fsync, sync, direct) are parsed and
  discarded. oflag=fsync and oflag=sync must set O_FSYNC or O_SYNC on
  the output file descriptor at open time. oflag=direct must set
  F_NOCACHE.
Fix: Parse oflag into a struct; pass the appropriate OpenFlags to
  createFile for sync/fsync; call fcntl(F_NOCACHE) for direct.
```

```
[CRITICAL] speed= silently accepted with no effect
Location: src/dd.zig:177-180
Problem: The value is parsed as an integer to validate syntax, then
  thrown away. The copy loop never throttles throughput.
Fix: After each write, compute elapsed time and sleep for the
  remaining interval if bytes/second exceeds the limit.
```

```
[CRITICAL] conv=sparse parsed, zero implementation in runDd
Location: src/dd.zig:36, src/dd.zig:240
Problem: config.conv_sparse is set but never read inside runDd. No
  all-NUL block detection or lseek-instead-of-write logic exists.
Fix: Before writing each output block, check if all bytes are NUL;
  if so, seek forward obs bytes instead of writing.
```

```
[CRITICAL] conv=pareven/parnone/parodd/parset parsed, zero
  implementation
Location: src/dd.zig:37-40, src/dd.zig:242-248
Problem: All four parity fields are set during parsing but never read
  in runDd or applyConversions. No parity bit computation occurs.
Fix: In applyConversions, after other conversions, apply the parity
  bit to each output byte: parset=set bit 7, parnone=clear bit 7,
  pareven=set bit 7 to make popcount even, parodd=set bit 7 to make
  popcount odd. Strip parity on input unless EBCDIC->ASCII is also
  specified.
```

---

## Incorrect Behavior

```
[IMPORTANT] conv=swab with odd-length input zeroes last byte instead
  of preserving it
Location: src/dd.zig:318-321
Problem: The macOS man page states: "If an input buffer has an odd
  number of bytes, the last byte will be ignored during swapping."
  "Ignored" means the byte passes through unchanged. The code instead
  writes NUL (0x00) to the last position.
Fix: Remove the line `buf[buf.len - 1] = 0;`. The byte at
  buf[buf.len - 1] was never swapped and already holds the original
  value; no action is needed.
```

```
[IMPORTANT] conv=sync always pads with NUL; should use spaces with
  block-oriented conversions
Location: src/dd.zig:674-677
Problem: The macOS man page states: "Spaces are used for pad bytes if
  a block oriented conversion value is specified, otherwise NUL bytes
  are used." The code calls `@memset(in_buf[bytes_read..], 0)`
  unconditionally.
Fix: Check whether conv_block or conv_unblock is set; if so, pad with
  ' ' (0x20) instead of 0x00. Also honour fillchar when noerror+sync
  is in effect, per the man page.
```

```
[IMPORTANT] conv=block does not count or report truncated input
  records
Location: src/dd.zig:700-706, src/dd.zig:380-419 (printStats)
Problem: The macOS man page states: "The number of truncated input
  records, if any, are reported to the standard error output at the
  completion of the copy." The DdStats struct has no
  truncated_records field. When a conv=block record exceeds cbs,
  bytes past position cbs_pos==cbs are silently dropped with no
  counter increment. printStats never outputs a "truncated" line.
Fix: Add `truncated_records: usize = 0` to DdStats. In the block
  loop, increment it when a byte is discarded because cbs_pos >= cbs.
  In printStats, if truncated_records > 0, print
  `"{d} truncated record(s)\n"`.
```

```
[IMPORTANT] status=progress does not print periodic statistics
Location: src/dd.zig:49-54, src/dd.zig:380-419
Problem: The macOS man page states: "Print basic transfer statistics
  once per second." The StatusLevel.progress variant exists but is
  handled identically to .default — only a single summary is printed
  at completion. No timer, thread, or periodic flush exists.
Fix: Before the main copy loop, if status == .progress, spawn a
  background thread or use a timer that calls printStats once per
  second. A simpler approach: check elapsed time after each
  read/write cycle and print if >= 1 second since last print.
```

```
[IMPORTANT] conv=osync not rejected when bs= is specified
Location: src/dd.zig:528-535 (validation block), macOS man page
Problem: The macOS man page states: "This option is incompatible with
  use of the bs=n block size specification." No validation check
  exists. The combination silently proceeds, applying osync padding
  inside the simple_copy path where it would conflict.
Fix: After the bs/ibs/obs resolution block, add:
  if (config.bs != null and config.conv_osync) {
      // error: osync incompatible with bs=
  }
```

```
[SUGGESTION] oldascii/oldebcdic/oldibm map to same conversion tables
  as their modern counterparts
Location: src/dd.zig:233-238
Problem: The macOS man page distinguishes "historic AT&T UNIX and
  pre-4.3BSD-Reno" tables from the System V tables. The code sets
  conv_ascii/conv_ebcdic/conv_ibm for both variants, using identical
  lookup tables. The old variants require separate conversion tables.
Fix: Add conv_oldascii, conv_oldebcdic, conv_oldibm fields and
  supply the historically-correct tables from BSD sources. Until the
  correct tables are available, at minimum document the limitation.
```

---

## Core Behavior Issues

```
[IMPORTANT] Missing 't' (terabyte) and 'p' (petabyte) size suffixes
Location: src/dd.zig:101-109 (parseSingleSize)
Problem: The macOS man page lists valid suffixes as: b=512, k/K=1024,
  m=1048576, g=1073741824, t=1099511627776, p=1125899906842624,
  w=sizeof(int). The parseSingleSize switch handles only b/k/K/M/G/c/w.
  Passing bs=1t or bs=1p returns InvalidValue.
Fix: Add cases to the switch:
  't' => 1_099_511_627_776,
  'p' => 1_125_899_906_842_624,
  Also note: the spec lists 'm' (lowercase) as 1M=1048576;
  currently only 'M' (uppercase) is accepted.
```

```
[IMPORTANT] SIGINFO and SIGINT handlers not implemented
Location: src/dd.zig (no signal handling code exists)
Problem: The macOS man page states: "If dd receives a SIGINFO signal,
  the current input and output block counts will be written to
  standard error. If dd receives a SIGINT signal, the current input
  and output block counts will be written ... and dd will exit."
  No signal handler is registered. Sending SIGINFO to a running dd
  produces no output.
Fix: Register a SIGINFO handler (on macOS/BSD; use SIGUSR1 on Linux)
  that atomically reads stats and calls printStats. Register a SIGINT
  handler that does the same then exits with code 1.
```

```
[SUGGESTION] Error messages do not include the operand name
Location: src/dd.zig:479-488
Problem: When an unknown operand is given, macOS dd prints
  "dd: unknown operand <name>". Our implementation prints only
  "dd: unrecognized operand" without naming the offending operand,
  making diagnosis harder.
Fix: Pass the operand key string to the error message:
  common.printErrorWithProgram(..., "dd", "unknown operand: {s}", .{key});
```

```
[SUGGESTION] Stats output format differs from macOS
Location: src/dd.zig:414
Problem: macOS format: "N bytes transferred in T.T secs (R bytes/sec)"
  Our format: "N bytes (X) copied, T.TTTT s, R kB/s"
  This is a cosmetic divergence but tools that parse dd stderr will
  break.
Fix: Match the macOS format exactly, or document the deliberate
  deviation.
```

---

## I/O Correctness

No I/O pattern issues found. The implementation correctly uses
`.writerStreaming()` for stdout/stderr buffers, flushes before
exit, and defers file closes. Output goes to stdout (file) and
stats to stderr. Error messages are correctly directed to stderr.

The output file is correctly opened with `truncate = !config.conv_notrunc`.
seek-past-EOF correctly falls back to writing NUL blocks when
`seekTo` fails (for non-seekable devices).

---

## Dynamic Verification

Binary built cleanly with `zig build`.

| Test | Result |
|------|--------|
| `dd --help` | PASS - outputs usage |
| `dd --version` | PASS - outputs version |
| basic stdin passthrough | PASS |
| `bs=5 count=1` | PASS - copies 5 bytes |
| `conv=ucase` | PASS |
| `conv=lcase` | PASS |
| `status=none` | PASS - no stderr |
| `status=noxfer` | PASS - records but no xfer line |
| `status=progress` | FAIL - identical to default, no periodic output |
| `skip=1 bs=4` | PASS |
| `seek=2 bs=4` | PASS - NUL fill confirmed |
| `conv=notrunc` | PASS |
| `conv=swab` odd byte | FAIL - last byte is NUL, not preserved |
| `conv=block cbs=3` truncation | FAIL - no truncated record in stats |
| `bs=1t` | FAIL - InvalidValue |
| `bs=1p` | FAIL - InvalidValue |
| `iflag=fullblock` | STUB - silently accepted |
| `oflag=sync` | STUB - silently accepted |
| `speed=1000000` | STUB - no throttling |
| `conv=sparse` | STUB - no sparse write |
| `conv=pareven` | STUB - no parity computation |
| `conv=osync` with `bs=` | FAIL - no incompatibility error |

---

## Findings Summary

| Severity   | Count |
|------------|-------|
| CRITICAL   | 6     |
| IMPORTANT  | 6     |
| SUGGESTION | 3     |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] files= parsed but never used — src/dd.zig:158
2. [CRITICAL] iflag= silently accepted, fullblock/direct not implemented — src/dd.zig:173
3. [CRITICAL] oflag= silently accepted, fsync/sync/direct not implemented — src/dd.zig:175
4. [CRITICAL] speed= silently accepted, no rate limiting — src/dd.zig:177
5. [CRITICAL] conv=sparse parsed, no seek-instead-of-write logic — src/dd.zig:36
6. [CRITICAL] conv=pareven/parnone/parodd/parset parsed, no parity logic — src/dd.zig:37
7. [IMPORTANT] conv=swab zeroes odd last byte instead of preserving it — src/dd.zig:319
8. [IMPORTANT] conv=sync always pads NUL, should use spaces with block mode — src/dd.zig:675
9. [IMPORTANT] conv=block missing truncated-record count in stats — src/dd.zig:700
10. [IMPORTANT] status=progress no periodic 1-second printing — src/dd.zig:53
11. [IMPORTANT] conv=osync not rejected when bs= is specified — src/dd.zig:528
12. [IMPORTANT] Missing 't' and 'p' size suffixes, possibly 'm' lowercase — src/dd.zig:101
13. [IMPORTANT] SIGINFO/SIGINT handlers not registered — src/dd.zig (absent)
14. [SUGGESTION] oldascii/oldebcdic/oldibm use wrong tables — src/dd.zig:233
15. [SUGGESTION] Error message omits offending operand name — src/dd.zig:485
16. [SUGGESTION] Stats output format differs from macOS — src/dd.zig:414
```

REVIEW COMPLETE - NEEDS_FIXES
