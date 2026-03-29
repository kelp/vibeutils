---
audit: cat code
date: 2026-03-28
file: src/cat.zig
result: NEEDS_FIXES
build: pass (59/59 IT pass, 17/17 unit pass)
---

# cat Code Audit

## Summary

The implementation is structurally sound. It builds cleanly, all
59 integration tests and all 17 unit tests pass. The I/O pattern
is correct: `writerStreaming()` with 8192-byte buffers, flushed
before exit. The flag-combination resolution (`-A`, `-e`, `-t`)
is correct. The passthrough path (`peekGreedy`/`toss` when no
formatting flags are set) is an efficient zero-copy approach.
Long-line handling via `StreamTooLong` is correct. Line-number
state persists correctly across multiple files.

Two behavioral bugs are confirmed against GNU coreutils 9.10:
one is IMPORTANT (`-E` does not emit `^M$` for CRLF lines) and
one is IMPORTANT (error messages use Zig error names rather than
POSIX strings). One flag is SHOULD-tier and intentionally
ignored (`-l`).

---

## Flag-by-Flag Verdict

| Flag | Tier   | Status   | Notes |
|------|--------|----------|-------|
| -b   | MUST   | PASS     | Numbers non-blank lines; correctly overrides -n |
| -e   | MUST   | PASS     | Resolves to show_ends + show_nonprinting |
| -n   | MUST   | PASS     | Numbers all lines; continuous across files |
| -s   | MUST   | PASS     | Squeezes consecutive blank lines |
| -t   | MUST   | PASS     | Resolves to show_tabs + show_nonprinting |
| -u   | MUST   | PASS     | Accepted and ignored (correct) |
| -v   | MUST   | PASS     | Caret/M- notation; LFD and TAB correctly excluded |
| -A   | SHOULD | PASS     | Correctly resolves to -vET |
| -E   | SHOULD | **BUG**  | Does not show `^M$` for CRLF lines without -v |
| -T   | SHOULD | PASS     | TAB rendered as `^I` |
| -l   | SHOULD | STUB     | Accepted and ignored; macOS advisory-lock semantics not implemented |

---

## Issues

```
[IMPORTANT] -E does not render trailing CR as ^M$ on CRLF lines
Location: src/cat.zig:329-340 (processFormattedLineChunk)
Problem: GNU cat's man page states -E displays "$ or ^M$ at end
  of each line". When a line ends with \r\n, GNU cat emits
  "content^M$\n" even without -v. Our implementation emits
  "content\r$\n": the raw \r byte is written by writeAll(chunk),
  then "$\n" is appended. On a terminal the \r causes the cursor
  to return to column zero and $ overwrites the first character,
  mangling the display entirely.

  Confirmed with GNU coreutils 9.10:
    printf 'test\r\n' | /usr/bin/cat -E | od -c
    0000000   t   e   s   t   ^   M   $  \n

    printf 'test\r\n' | ./zig-out/bin/cat -E | od -c
    0000000   t   e   s   t  \r   $  \n

  Note: mid-line \r is NOT converted (GNU leaves it as-is).
  Only a trailing \r (the last byte of the chunk before the
  newline) is promoted to ^M under -E. When -v is also active,
  the existing writeWithSpecialChars path already handles \r
  correctly as a control character, so -vE is correct.

Fix: In processFormattedLineChunk, when show_ends is true and
  show_nonprinting is false, check whether the last byte of chunk
  is '\r' before writing:
    if (options.show_ends and !options.show_nonprinting and
        chunk.len > 0 and chunk[chunk.len - 1] == '\r') {
        try writer.writeAll(chunk[0 .. chunk.len - 1]);
        try writer.writeAll("^M");
    } else {
        try writer.writeAll(chunk);
    }
  Then write "$\n" as normal.
```

```
[IMPORTANT] Error messages use Zig error names, not POSIX strings
Location: src/cat.zig:116, 125, 131, 140
Problem: All error paths use @errorName(err), which produces Zig
  internal identifiers ("FileNotFound", "AccessDenied",
  "ReadFailed") instead of the POSIX strings that users and
  scripts expect ("No such file or directory", "Permission
  denied", "Is a directory").

  Observed:
    $ cat /nonexistent
    cat: /nonexistent: FileNotFound        ← ours
    cat: /nonexistent: No such file or directory  ← GNU

    $ cat /tmp
    cat: /tmp: ReadFailed                  ← ours
    cat: /tmp: Is a directory              ← GNU

  This is a project-wide pattern (26 source files use
  @errorName). Raising it here because cat is a high-visibility
  utility where incorrect error messages break scripts that grep
  stderr for known POSIX strings. The fix in cat.zig is local
  regardless of whether a project-wide helper is added.

Fix: Map the common Zig file errors to their POSIX strings. A
  minimal helper in the file-open catch block:
    const msg = switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.IsDir        => "Is a directory",
        else => @errorName(err),
    };
  Apply the same mapping to the processInput catch block using
  ReadFailed -> "Is a directory" (EISDIR on a dir fd read). A
  shared helper in src/common/ would serve all 26 affected files.
```

```
[SUGGESTION] -l (SHOULD, macOS-only) is intentionally ignored
Location: src/cat.zig:43 (ignored_l field)
Problem: -l sets an exclusive advisory lock on stdout via
  fcntl(F_SETLKW). The flag is SHOULD tier and macOS-only (not
  in GNU cat). The current no-op is the correct choice on Linux
  and reasonable on macOS given that advisory locks on stdout are
  rarely needed. The flag is at least accepted without error,
  which prevents breakage when macOS shell scripts use it.
Fix: No code change required. If macOS parity becomes a
  requirement, implement using std.posix.fcntl with F_SETLKW on
  stdout's file descriptor.
```

---

## I/O Pattern Review

- `writerStreaming()` is used for both stdout and stderr in
  `main()`. Correct per project requirement.
- Buffers are 8192 bytes. Correct.
- `defer stdout.flush() catch {}` is called before `exit()`.
  Correct.
- `stdin_reader` is stack-allocated with an 8192-byte buffer and
  reused across all `-` arguments in one invocation. Correct:
  subsequent `-` reads on drained stdin yield EOF, matching GNU
  behavior.
- File readers use per-file 8192-byte stack buffers (`var
  file_buffer: [8192]u8 = undefined`). Correct; buffers go out of
  scope only after `file.close()`.
- The passthrough path (`peekGreedy`/`toss` loop) is correct
  zero-copy streaming with no heap allocation.

---

## Core Behavior Review

- Concat of multiple files: correct. Line-number state persists
  across file boundaries.
- `-` as stdin placeholder: handled correctly at line 122.
- No-argument stdin fallback: correct at line 113.
- Error on one file continues to next file: correct at lines
  131-133 (continue after error) and line 147 (returns
  general_error if any file failed).
- Long lines (> 8192 bytes) handled via StreamTooLong with
  per-chunk processing: verified by unit test at line 646.

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -E does not emit ^M$ for CRLF lines
               — src/cat.zig:329-340 (processFormattedLineChunk)
2. [IMPORTANT] Error messages use Zig names, not POSIX strings
               — src/cat.zig:116, 125, 131, 140
3. [SUGGESTION] -l stub acceptable; document if macOS parity required
               — src/cat.zig:43
```

REVIEW COMPLETE - NEEDS_FIXES
