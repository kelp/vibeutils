# tail Code Audit

**Date:** 2026-03-28
**File:** `src/tail.zig`
**Verdict:** NEEDS_FIXES

---

## Flag-by-Flag Compliance Table

| Flag | Tier | Parsed | Behavioral | Verdict |
|------|------|--------|------------|---------|
| `-n` | MUST | yes | yes | PASS |
| `-c` | MUST | yes | yes | PASS |
| `-f` | MUST | yes | yes | PASS |
| `-F` | SHOULD | yes | yes | PASS |
| `-b` | MUST | yes | yes | PASS |
| `-r` | MUST | yes | partial — see below | FAIL |
| `-q` | SHOULD | yes | yes | PASS |
| `-v` | SHOULD | yes | yes | PASS |
| `-z` | SHOULD | yes | yes | PASS |

---

## Incorrect Behavior

### `-r` is silently ignored when `-c` or `-b` is set

**[IMPORTANT] `-r` flag ignored when combined with `-c` or `-b`**
Location: `src/tail.zig:431-440` (`processFile`)

Problem: `processFile` routes exclusively on whether `byte_count` is set.
When `-r` and `-c` (or `-b`) are both given, `options.reverse` is `true`
but the byte path is taken and `-r` has no effect. The output is identical
to `-c N` or `-b N` with no `-r`.

Per the macOS man page (the authoritative reference for `-r`): "when the
`-r` option is specified, these options specify the number of bytes, lines
or 512-byte blocks **to display**" — i.e., reverse all content first, then
limit output to N bytes/blocks. The current implementation does neither the
reversal nor the correct limiting for the combined case.

Verified:
```
$ printf "aaaa\nbbbb\ncccc\n" > /tmp/t.txt
$ ./zig-out/bin/tail -r -c 9 /tmp/t.txt
bbb
cccc
         # (last 9 bytes — -r is ignored)
# Expected (reverse all, show 9 bytes): cccc\nbbb
```

Fix: In `processFile` (and `processStdin`), when both `reverse` and
`byte_count` are set, collect all content, reverse by lines, then emit only
the first `byte_count` bytes. Alternatively, add a validation error
rejecting `-r` combined with `-c`/`-b` (GNU does not support `-r` at all;
macOS does, and defines the combined semantics above).

---

### `-f` with multiple files only follows the last file

**[IMPORTANT] `-f` follows only the last real file; silently drops others**
Location: `src/tail.zig:274-300`

Problem: When `-f` is given with multiple file arguments, the code prints
a warning to stderr and then enters `followFile` for only the last real
file. GNU `tail -f` follows all listed files and labels each new chunk with
a `==> filename <==` header when content arrives from different files.

This is documented as "not yet supported" but is a named SHOULD-tier flag
behavior that diverges from both GNU and macOS semantics.

Fix: Implement a multi-file follow loop that tracks each file's position
and inode, multiplexing output with filename headers when the active file
changes.

---

### `-f` on stdin (pipe) silently ignored — no error

**[SUGGESTION] `-f` with no file arguments (stdin pipe) produces no follow**
Location: `src/tail.zig:237-239`, `275-300`

Problem: When `-f` is given with no file arguments, `processStdin` runs
(consuming the pipe), then the follow block finds `last_file_path = null`
and exits normally. No error, no follow. POSIX says `-f` is ignored if
stdin is a pipe, so the correct behavior is to silently do nothing — which
is what happens — but there is no test validating this is intentional
rather than accidental, and the macOS man page notes `-f` is NOT ignored
on a FIFO (our implementation makes no distinction).

---

## Stubs Found

None. All flags that are parsed affect program behavior. The `-f` and `-F`
follow behavior is implemented with real OS-level watchers (inotify on
Linux, kqueue on macOS).

---

## Core Behavior Issues

No regressions in the core default-10-lines, `-n`, `-c`, stdin, multiple
files, headers, or empty-file handling. All 76 integration tests pass.

---

## Potential Crash / OOM

**[IMPORTANT] `processInputByBytesNoSeek` allocates `byte_count` bytes
unconditionally**
Location: `src/tail.zig:735-739`

Problem: For non-seekable input (stdin, pipes), `-c N` allocates an
`N`-byte circular buffer on the heap with no upper bound. A call like
`tail -c 10G < /dev/zero` will attempt to allocate 10 GiB, killing the
process or triggering OOM.

```zig
const buffer_size = @as(usize, @intCast(byte_count)); // no cap
const circular_buffer = try allocator.alloc(u8, buffer_size);
```

GNU `tail` uses a fixed-size paging buffer for large values. The fix is to
cap the allocation at a reasonable maximum (e.g., 1 MiB) and fall back to
a two-pass or streaming approach when the requested count exceeds that cap,
or at minimum add a sanity limit and return an error for unreasonably large
values.

---

## I/O Correctness

- `writerStreaming()` used correctly throughout `main()`. PASS.
- 8192-byte buffers used for stdout and stderr in `main()`. PASS.
- `flush()` called before exit. PASS.
- `flushWriter()` helper used in follow loops before blocking. PASS.

---

## Dynamic Verification

All tests run against `./zig-out/bin/tail` (built clean before testing).

| Test | Result |
|------|--------|
| Default 10 lines | PASS |
| `-n N` | PASS |
| `-n +N` | PASS |
| `-c N` | PASS |
| `-c +N` | PASS |
| `-b N` | PASS |
| `-b +N` | PASS |
| `-r` (alone) | PASS |
| `-r -n N` | PASS |
| `-r -c N` | **FAIL** (ignores `-r`) |
| `-r -b N` | **FAIL** (ignores `-r`) |
| `-z` | PASS |
| `-z -r` | PASS |
| `-q` multi-file | PASS |
| `-v` single file | PASS |
| `-f` follow (integration) | PASS |
| `-F` retry/rotate (integration) | PASS |
| `-f -r` mutual exclusion | PASS |
| Multi-file headers | PASS |
| Empty file | PASS |
| Binary file | PASS |
| No trailing newline | PASS |
| Unit tests (tail) | 45 passed, 0 failed |
| Integration tests | 76 passed, 0 failed |

---

## Findings Table

| Severity | Description | Location |
|----------|-------------|----------|
| IMPORTANT | `-r` silently ignored when `-c` or `-b` is set | `tail.zig:431-440` |
| IMPORTANT | `-f` follows only last file; multi-file follow unimplemented | `tail.zig:274-300` |
| IMPORTANT | `processInputByBytesNoSeek` allocates full `byte_count` bytes (OOM risk) | `tail.zig:735-739` |
| SUGGESTION | `-f` on stdin FIFO vs pipe not distinguished (macOS spec difference) | `tail.zig:237-239` |
| SUGGESTION | Unit tests for `-q` and `-v` are exit-code-only stubs | `tail.zig:1306-1316` |

---

## Summary

**5 findings: 0 CRITICAL, 3 IMPORTANT, 2 SUGGESTION**

The implementation is substantially correct. Core behavior (`-n`, `-c`,
`-b`, `-f`, `-F`, `-r`, `-z`, `-q`, `-v`, multi-file headers, stdin,
follow-mode with inotify/kqueue) all work correctly in isolation. The
primary correctness gap is that `-r` is silently dropped when combined
with `-c` or `-b`, which violates the macOS spec. The OOM vector in
`processInputByBytesNoSeek` is a reliability issue for large values.
Multi-file `-f` is a known stub with a warning but degrades silently
rather than erroring.

**Overall: NEEDS_FIXES**

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -r silently ignored with -c/-b — tail.zig:431-440
2. [IMPORTANT] processInputByBytesNoSeek OOM on large -c values — tail.zig:735-739
3. [IMPORTANT] -f multi-file follow unimplemented — tail.zig:274-300
4. [SUGGESTION] -f stdin FIFO vs pipe distinction — tail.zig:237-239
5. [SUGGESTION] -q and -v unit tests are exit-code-only stubs — tail.zig:1306-1316
```

REVIEW COMPLETE - NEEDS_FIXES
