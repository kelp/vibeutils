# uniq Code Audit

Date: 2026-03-28
Build: PASS (42/42 unit + integration tests pass)
Assessment: NEEDS_FIXES

---

## Findings

### [CRITICAL] `--all-repeated=METHOD` crashes with unhandled stack trace

Location: `src/uniq.zig:81-97` (arg parsing) + `src/uniq.zig:13-52`
(UniqArgs struct)

Problem: GNU documents `--all-repeated[=METHOD]` where METHOD is one of
`none` (default), `prepend`, or `separate`. The `all_repeated` field is
a plain `bool`, so the argparse library rejects a value attached to the
flag (`--all-repeated=none`) with `error.TooManyValues`. That error
falls through to the `else => return err` branch at line 95, which
propagates the Zig error and produces a raw stack trace on stderr with
exit code 1. This is a crash, not a clean diagnostic.

Observed:

```
$ echo "a" | uniq --all-repeated=none
error: TooManyValues
/home/tcole/code/vibeutils/src/common/argparse.zig:227:25: ...
```

Fix: Accept the optional `=METHOD` argument. Change `all_repeated: bool`
to an enum or a tagged union, or minimally parse and discard the value
for `none` while emitting "not implemented" for `prepend`/`separate`. At
minimum, the `TooManyValues` error must be caught in the arg-error
handler and turned into a clean "unrecognized argument" message with exit
code 2, not a crash.

---

### [IMPORTANT] `-c` flag is silently ignored when combined with `-D`

Location: `src/uniq.zig:299-309` (`outputLine`)

Problem: When `all_repeated` is true, `outputLine` enters the early
return block at line 299 and never reaches the `-c` count-prefix logic
at lines 322-324. GNU uniq prefixes every repeated line with its group
count when both `-c` and `-D` are given:

```
$ printf "aaa\naaa\naaa\n" | uniq -c -D
      3 aaa
      3 aaa
      3 aaa
```

Our output omits the count prefix:

```
aaa
aaa
aaa
```

Fix: Move the count-prefix write inside the `all_repeated` block (before
each `writer.writeAll(line)` call), guarded by `if (opts.count)`.

---

### [IMPORTANT] `--all-repeated` METHOD variants `prepend` and `separate`
are unimplemented with no diagnostic

Location: `src/uniq.zig:18-19`, `src/uniq.zig:299-309`

Problem: GNU supports three METHOD values for `--all-repeated`:
- `none` (default) — no separator
- `prepend` — blank line before each duplicate group
- `separate` — blank line between duplicate groups

None of the separator variants are implemented. Because `all_repeated`
is a plain `bool`, all three would be treated identically (the METHOD
value is rejected entirely today, as noted in the CRITICAL finding
above). Users who rely on `--all-repeated=separate` or
`--all-repeated=prepend` for output formatting will get either a crash
or incorrect output.

Fix: Implement the three METHOD variants. This is the natural fix for
the CRITICAL finding above.

---

### [IMPORTANT] Stale and misleading test comment asserts a bug that no
longer exists

Location: `src/uniq.zig:779-814` (test "uniq read errors print
diagnostic to stderr")

Problem: The comment at lines 810-813 states:

```
// Should have written a diagnostic message to stderr.
// This assertion will FAIL because runUniqWithInput discards
// stderr_writer.
try testing.expect(stderr_buffer.items.len > 0);
```

The assertion does NOT fail — `runUniqWithInput` correctly receives and
uses `stderr_writer` (the last parameter on line 157). The comment
describes a bug that was fixed (or never existed), but the stale text
misleads future readers into thinking the passing test is broken. A
reader may remove the assertion or skip investigation.

Fix: Remove the "will FAIL" comment. Replace with a factual description
of what the test verifies.

---

### [IMPORTANT] `-z` integration and unit test coverage is zero

Location: `tests/utilities/uniq_test.sh`, `src/uniq.zig`

Problem: The `-z` / `--zero-terminated` flag is marked SHOULD in
`docs/specs/uniq-flags.md`. It is functionally implemented and works
correctly (verified manually). However no integration test exercises it,
and no unit test exercises `runUniqWithInput` with
`zero_terminated = true`. A regression to the `-z` path would go
undetected.

Fix: Add at least one integration test using `printf 'a\0a\0b\0'` piped
through `uniq -z` with an assertion on the NUL-delimited output, and one
unit test using `runUniqWithInput` with `UniqArgs{ .zero_terminated =
true }`.

---

### [SUGGESTION] Invalid-option error message does not name the offending
option

Location: `src/uniq.zig:83-86`

Problem: When an unknown flag is passed, the error message is:

```
uniq: invalid option
Try 'uniq --help' for more information.
```

GNU coreutils names the option:

```
uniq: invalid option -- 'x'
uniq: unrecognized option '--bad-flag'
```

Fix: Propagate the offending option name from the argparse error
(requires argparse to surface it) and include it in the message.

---

## Summary

| Severity  | Count |
|-----------|-------|
| CRITICAL  | 1     |
| IMPORTANT | 4     |
| SUGGESTION| 1     |

---

## Fix Order

```
1. [CRITICAL]  --all-repeated=METHOD crashes with raw stack trace
               — src/uniq.zig:18-19, 83-97, 299-309
2. [IMPORTANT] -c flag silently ignored with -D
               — src/uniq.zig:299-309
3. [IMPORTANT] --all-repeated prepend/separate unimplemented, no diagnostic
               — src/uniq.zig:18-19, 299-309
4. [IMPORTANT] Stale comment falsely describes passing test as failing
               — src/uniq.zig:810-813
5. [IMPORTANT] -z has no integration or unit tests
               — tests/utilities/uniq_test.sh, src/uniq.zig
6. [SUGGESTION] Error message does not name the offending option
               — src/uniq.zig:83-86
```

REVIEW COMPLETE - NEEDS_FIXES
