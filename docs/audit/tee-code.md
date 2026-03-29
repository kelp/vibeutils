---
audit: tee code
date: 2026-03-28
file: src/tee.zig
result: NEEDS_FIXES
build: pass (87/87 IT pass, 9/9 unit pass)
---

# tee Code Audit

## Summary

The implementation builds cleanly, all 87 integration tests
and all 9 unit tests pass. The I/O pattern is correct:
`writerStreaming()` with 8192-byte buffers, flushed before
exit. Core functionality (copy stdin to stdout and files,
append mode, dash-as-stdout) is correct and well-tested.

Three behavioral divergences from GNU coreutils 9.10 are
confirmed. The most significant is that the default
(no-flag) behavior silently suppresses write error
diagnostics where GNU always prints them. The `-p` flag
semantics are also wrong in two related ways: it does not
change SIGPIPE/broken-pipe handling, and the error message
omits the filename. The SIGPIPE handling mismatch means our
default behavior is functionally equivalent to GNU `-p`
rather than GNU default.

---

## Flag-by-Flag Verdict

| Flag | Status | Notes |
|------|--------|-------|
| -a / --append | PASS | Correct open+seek-to-end logic |
| -i / --ignore-interrupts | PASS | Ignores SIGINT only, correct |
| -p | WRONG | Wrong semantics; see below |
| - (dash operand) | PASS | Writes to stdout again, correct |

---

## Issues

```
[IMPORTANT] Default mode silently swallows write errors
Location: src/tee.zig:113-118
Problem: GNU tee always diagnoses (prints to stderr) errors
writing to non-pipe outputs, whether or not -p is set. Our
implementation gates all write error messages on
args.diagnose_errors (-p). Without -p, a file write failure
produces exit code 1 but no diagnostic. The user cannot tell
which file failed or why.

Confirmed:
  echo "test" | /usr/bin/tee /dev/full 2>&1
  → tee: /dev/full: No space left on device (always)
  echo "test" | ./zig-out/bin/tee /dev/full 2>&1
  → (silent)

Fix: Remove the args.diagnose_errors gate from the write error
and flush error paths. Always print diagnostics. The -p flag
should instead change SIGPIPE exit behavior (see next issue),
not control whether errors are printed.
```

```
[IMPORTANT] -p does not implement GNU pipe-exit semantics
Location: src/tee.zig:63-77, 279-303
Problem: GNU tee has two distinct modes:

  Default (no -p): exit immediately when writing to stdout
  fails (SIGPIPE/EPIPE). This means once stdout is a broken
  pipe, tee stops processing even if file outputs are still
  open.

  -p (warn-nopipe mode): continue writing to file outputs
  even after stdout pipe breaks. Exit only when ALL outputs
  become broken pipes.

Our implementation always continues on stdout write error
(because the catch in MultiWriter.write() absorbs it). This
makes our default behavior equivalent to GNU -p, and our
-p has no additional effect on pipe handling. Our -p only
enables error message printing, which is also wrong.

Confirmed:
  (printf 'line1\nline2\nline3\n'; sleep 0.5; printf 'line4\nline5\n') | \
    /usr/bin/tee /tmp/f.txt | head -1
  → file gets lines 1-3 only (stopped when stdout broke)

  Same command with our tee:
  → file gets all 5 lines (continued after stdout broke)

Fix: In the default mode, treat a stdout write error as fatal
(stop reading stdin, flush files, exit 1). Under -p, catch
stdout EPIPE and continue reading/writing to file outputs.
```

```
[IMPORTANT] Error messages omit filename and use Zig error
names instead of POSIX strings
Location: src/tee.zig:115
Problem: GNU error format is "tee: /path/to/file: No space
left on device". Our format is "tee: write error: WriteError".
Two problems: (1) the filename is absent because MultiWriter
doesn't track which file failed, and (2) @errorName() returns
Zig symbols (WriteError, NoSpaceLeft) rather than POSIX
strerror strings (No space left on device).

GNU output:
  tee: /dev/full: No space left on device

Our output:
  tee: write error: WriteError

Fix: MultiWriter.write() needs to iterate files individually,
catching and immediately reporting errors with the filename.
Store file_names in MultiWriter alongside files so the name
is available at error time. Use std.posix.strerror() or the
error's description string rather than @errorName().
```

```
[SUGGESTION] -p help text is misleading
Location: src/tee.zig:167
Problem: Help text says "diagnose errors writing to non
pipes". After fixing the above issues, the text should match
what the flag actually does. GNU says "operate in a more
appropriate MODE with pipes". A simpler honest description
is "continue after stdout pipe error; diagnose non-pipe
errors".

Fix: Update the description once the semantic is corrected.
```

```
[SUGGESTION] -a append uses open+seek rather than O_APPEND
Location: src/tee.zig:239-249
Problem: Append mode opens the file with write_only then
seeks to the end. This works but is not atomic: a concurrent
writer could append between the seek and the first write.
Using the OS O_APPEND flag would be atomic.

Zig OpenFlags has no direct O_APPEND, but you can pass it
via createFile with truncate=false and no-seek, relying on
.mode = .write_only without seek. Actually the correct Zig
approach is to open with .append = true when available, or
pass O_APPEND via posix.open() directly.

Impact: Low; tee is rarely used in concurrent-append
scenarios. This is informational.
```

---

## Test Coverage

Unit tests (9 total): All pass. Coverage is behavioral, not
parse-only. Tests cover: copy to file, append mode, dash
operand (1x, 2x, mixed), no-file passthrough, help, version,
unknown flag.

Integration tests (87 total): All pass. Coverage is thorough
for happy paths. Missing behavioral coverage:

- No test verifies that a write error to a file produces a
  diagnostic message on stderr (the silent-swallow bug is
  undetected because -p is used in error-condition tests).
- No test verifies that -p changes pipe-exit behavior
  (continues after stdout SIGPIPE).
- The read-only directory test and non-existent path test
  verify exit code 1 but suppress stderr (2>/dev/null),
  so they do not verify the error message content.
- No test for -i actually sending SIGINT and verifying the
  process continues. The -i tests only check normal output.

---

## Fix Order

1. [IMPORTANT] Always print write/flush error diagnostics —
   remove args.diagnose_errors gate — src/tee.zig:113-118
2. [IMPORTANT] Implement correct -p pipe-exit semantics —
   src/tee.zig:279-303 and runTeeWithInput
3. [IMPORTANT] Include filename and POSIX error string in
   error messages — src/tee.zig:115, MultiWriter design
4. [SUGGESTION] Update -p help text after semantic fix —
   src/tee.zig:167
5. [SUGGESTION] Consider O_APPEND for atomic append mode —
   src/tee.zig:239-249

REVIEW COMPLETE - NEEDS_FIXES
