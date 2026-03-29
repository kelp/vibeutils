# Code Audit: grep

**Date**: 2026-03-28
**Source**: src/grep.zig
**Specs**: grep-posix.txt, grep-gnu.txt, grep-macos.txt

## Executive Summary

FAIL

The implementation has correct behavior for the most common flags (-i,
-v, -c, -n, -l, -L, -r, -R, -e, -f, -E, -F, -G, -A, -B, -C, -m,
-q, -s, -H, -h, context, recursive search). However it contains
several critical behavioral bugs that diverge from the macOS (BSD)
spec, two of which affect commonly used flag combinations (-x in BRE
mode, -o multiple matches).

---

## Flag-by-Flag Compliance

| Flag | Tier | Parsed? | Implemented? | Correct? | Notes |
|------|------|---------|-------------|----------|-------|
| -E | MUST | yes | yes | yes | |
| -F | MUST | yes | yes | yes | |
| -c | MUST | yes | yes | yes | |
| -e | MUST | yes | yes | yes | |
| -f | MUST | yes | partial | no | `-f -` (stdin) fails; empty file exits 2 not 1; empty-line patterns skipped |
| -i | MUST | yes | yes | yes | |
| -l | MUST | yes | yes | yes | |
| -n | MUST | yes | yes | yes | |
| -q | MUST | yes | yes | yes | |
| -s | MUST | yes | yes | yes | |
| -v | MUST | yes | yes | yes | |
| -x | MUST | yes | partial | no | BRE mode broken (uses ERE group syntax); ERE mode correct |
| -A | MUST | yes | yes | yes | |
| -B | MUST | yes | yes | yes | |
| -C | MUST | yes | yes | yes | |
| -G | MUST | yes | yes | yes | |
| -H | MUST | yes | yes | yes | |
| -I | MUST | yes | STUB | no | No binary detection; always treats files as text |
| -L | MUST | yes | yes | yes | |
| -R | MUST | yes | yes | yes | |
| -U | MUST | yes | yes | yes | No-op on Unix; correct |
| -V | MUST | yes | yes | yes | |
| -a | MUST | yes | STUB | no | No binary detection; `-a` is a no-op but already behaves as text |
| -b | MUST | yes | partial | no | Line-start offset correct; with `-o` shows first match offset only |
| -h | MUST | yes | yes | yes | |
| -m | MUST | yes | yes | yes | |
| -o | MUST | yes | partial | no | Only first match per line; should print every non-overlapping match |
| -w | MUST | yes | partial | no | Match detection correct; with `-o` or `--color` includes boundary chars in match span |
| -Z | MUST | yes | yes | yes | NUL after filename (GNU/our behavior) |
| -r | SHOULD | yes | yes | yes | |
| -D | SHOULD | yes | STUB | no | Accepts value, always silently ignored |
| -d | SHOULD | yes | partial | yes | "recurse" and "skip" work; "read" on a directory silently fails instead of erroring |
| -J | SHOULD | yes | STUB | no | no-op; bzip2 decompression not implemented |
| -M | SHOULD | yes | STUB | no | no-op; LZMA decompression not implemented |
| -O | SHOULD | yes | STUB | no | no-op; symlink-on-cmdline behavior not implemented |
| -p | SHOULD | yes | STUB | no | no-op; no-symlink-follow not enforced |
| -S | SHOULD | yes | STUB | no | no-op; follow-all-symlinks not implemented |
| -u | SHOULD | yes | yes | yes | Documented no-op for GNU compat |
| -X | SHOULD | yes | STUB | no | no-op; xz decompression not implemented |
| -y | SHOULD | yes | yes | yes | Alias for -i; correct |
| -z | SHOULD | yes | yes | yes | NUL-terminated line mode |
| -P | SHOULD | yes | yes | yes | Rejected with clear error |
| --color | SHOULD | yes | partial | no | GREP_COLOR env var ignored; color code hardcoded |
| --include | SHOULD | yes | yes | yes | |
| --exclude | SHOULD | yes | yes | yes | |
| --exclude-dir | SHOULD | yes | yes | yes | |
| --label | SHOULD | yes | yes | yes | |
| --line-buffered | SHOULD | yes | yes | yes | No-op; acceptable |
| --null | SHOULD | yes | yes | yes | |
| --binary-files | SHOULD | yes | STUB | no | Accepted but always ignored; no binary detection |
| --mmap | SHOULD | yes | yes | yes | No-op; acceptable (deprecated) |
| --include-dir | SHOULD | yes | STUB | no | Accepted but always ignored |

---

### Stubs Found

**-I (ignore binary files)** `src/grep.zig:276`
Parsed as no-op. Since there is no binary file detection, `-I` should
suppress output for binary files but instead always matches. macOS
`grep -I` on a binary file with a matching byte exits 1; ours exits 0
and prints the line.

**-a / --text** `src/grep.zig:275, 172-173`
Parsed as no-op. Since there is no binary detection, `-a` makes no
observable difference, but the correct behavior when binary detection
is absent is to treat all files as text — which is what we already do.
This stub is therefore harmless as long as binary detection remains
absent, but it will mask a bug once binary detection is added unless
the stub is replaced with real logic.

**--binary-files=value** `src/grep.zig:239-240`
Explicitly commented "Stub: accept silently". `--binary-files=text`,
`--binary-files=without-match`, and `--binary-files=binary` all
produce identical output. Verified: `grep --binary-files=without-match`
on a binary file with match exits 0 and prints the line; macOS exits 1.

**-D (device action)** `src/grep.zig:407-418`
Accepts the value, consumes it, silently ignores. Device behavior is
always "read" regardless of argument.

**-J, -M, -X** `src/grep.zig:278-284`
Decompression flags accepted as no-op. These are macOS-specific
compression format flags. Acceptable given scope, but the flags.md
marks them SHOULD.

**-O, -p, -S (symlink follow policy)** `src/grep.zig:280-283`
Symlink traversal policy in recursive mode is not implemented.
`-R` always follows symlinks (treating them as the default `-O`
behavior), and `-p` (the default no-follow) is also not honored.
`-S` (follow all) has no observable difference from `-R`.

**--include-dir** `src/grep.zig:243-244`
Explicitly commented "No-op stub". Note: the installed macOS binary
also does not recognize `--include-dir`, though the man page lists it.

---

### Incorrect Behavior

**CRITICAL: -x in BRE mode** `src/grep.zig:478-479`
The pattern `^({pattern})$` is compiled for both ERE and BRE modes.
In BRE, `(` and `)` are literal characters. The wrapped pattern
`^(foo)$` therefore matches the literal string "(foo)", not "foo".
Result: `-x` with BRE (the default mode, and with `-G`) never matches
any normal input line. ERE mode (`-E`) is not affected.

Reproduction:
```
echo "foo" | ./zig-out/bin/grep -x "foo"   # exit 1 — wrong
echo "(foo)" | ./zig-out/bin/grep -x "foo" # exit 0 — wrong match
echo "foo" | /usr/bin/grep -x "foo"        # exit 0 — correct
```

Fix: when `regex_mode == .basic`, use `^{pattern}$` (no group wrapper)
or `^\({pattern}\)$` if grouping is needed.

**CRITICAL: -o only prints first match per line** `src/grep.zig:748-770`
`-o` should print every non-overlapping match on a line as a separate
output line. The implementation prints only the first match and stops.

Reproduction:
```
echo "foobarfoo" | ./zig-out/bin/grep -o "foo"  # prints: foo (one line)
echo "foobarfoo" | /usr/bin/grep -o "foo"        # prints: foo\nfoo (two lines)
```

This also breaks `-b -o`: the byte offset always shows the line-start
offset for the first match, not the actual start offset of each match
within the line.

**IMPORTANT: -w with -o or --color includes boundary characters in
match span** `src/grep.zig:481-485`

The BRE word-boundary pattern
`\(^\|[^[:alnum:]_]\)\(pattern\)\([^[:alnum:]_]\|$\)` and the ERE
equivalent wrap the pattern in outer groups. `regexec` fills `pmatch[0]`
with the start/end of the entire expression, including the boundary
characters. When `-o` or `--color` use `result.match_start` and
`result.match_end`, the surrounding non-word characters are included.

Reproduction:
```
echo "hello foo bar" | ./zig-out/bin/grep -wo "foo"
# prints: " foo " (with surrounding spaces)
# should print: "foo"

echo "hello foo bar" | ./zig-out/bin/grep --color=always -w "foo"
# highlights " foo " including leading space
# should highlight only "foo"
```

Fix: compile a two-group pattern and use `pmatch[2]` (the inner
pattern group) for match positions, or use `[[:<:]]foo[[:>:]]` on
platforms that support it (macOS/BSD).

**IMPORTANT: -f with stdin (`-f -`) fails** `src/grep.zig:440-441`

The macOS man page states: `"-" may be used in place of a file name,
anywhere that a file name is accepted, to read from standard input.
This includes both -f and file arguments.`

`loadPatternsFromFile` passes the path directly to
`std.fs.cwd().readFileAlloc`, which fails on the literal string "-".

Reproduction:
```
echo "foo" | ./zig-out/bin/grep -f - /tmp/file.txt  # exits 1 with error
echo "foo" | /usr/bin/grep -f - /tmp/file.txt        # works correctly
```

**IMPORTANT: -f with empty file exits 2 instead of 1**
`src/grep.zig:1062-1065`

When `-f` is given an empty file, no patterns are loaded. The code
then hits the `opts.patterns.items.len == 0` check and prints an
error, returning exit code 2. The macOS spec says "If file is empty,
nothing is matched" — the correct exit is 1 (no match), not 2 (error).

Reproduction:
```
echo "hello" | ./zig-out/bin/grep -f /dev/null  # exits 2 with error message
echo "hello" | /usr/bin/grep -f /dev/null        # exits 1 silently
```

**IMPORTANT: Empty pattern lines in -f file are skipped instead of
matching all** `src/grep.zig:448-451`

The macOS spec says "Empty pattern lines match every input line."
The `loadPatternsFromFile` loop skips empty lines with the condition
`if (idx > start)`. An empty line should be added as an empty pattern
(`""`), which in regex terms matches every line.

Reproduction:
```
printf "hello\n\nworld\n" > /tmp/pats.txt
echo "test" | ./zig-out/bin/grep -f /tmp/pats.txt  # exits 1 (no match)
echo "test" | /usr/bin/grep -f /tmp/pats.txt         # exits 0 (matches all)
```

**IMPORTANT: Giving a directory without -r produces wrong exit code**
`src/grep.zig:1138-1148`

When grep is given a directory path as a file argument and neither
`-r` nor `-d` is specified, macOS emits an error message and exits 2.
Our implementation calls `openFile` on the directory, which on macOS
returns a file descriptor that `readToEndAlloc` silently fails to
read, causing `processFile` to return false (no match) and the tool
exits 1.

Reproduction:
```
./zig-out/bin/grep "hello" /tmp/somedirectory/    # exit 1, no message
/usr/bin/grep "hello" /tmp/somedirectory/          # exit 2: "Is a directory"
```

**SUGGESTION: GREP_OPTIONS environment variable not supported**
`src/grep.zig` (no reference)

The macOS ENVIRONMENT section documents `GREP_OPTIONS` as placing
default options at the beginning of the argument list. The
implementation does not read this variable. This is a documented
environment variable in the macOS spec.

**SUGGESTION: GREP_COLOR environment variable not read**
`src/grep.zig:591-596`

The macOS man page says `--color` marks up matching text with the
expression stored in `GREP_COLOR`. The match highlight color is
hardcoded to `"\x1b[01;31m"` (bold red). `GREP_COLOR` is never read.

---

## Core Behavior Issues

**Exit code when error + match coexist**: When some files succeed
(match found) and some produce errors, our implementation returns 2.
macOS also returns 2 in this case. Behavior matches.

**Stdin reading**: Reads from stdin when no files specified. `-` as
a filename reads stdin. Both are correct.

**Multiple patterns with -e**: OR logic is correct.

**Filename display heuristic**: Correctly suppresses filename for
single stdin, shows for multiple files and recursive. Correct.

**-n ignored with -c, -q, -l, -L**: Verified correct: these modes
suppress line-number output.

---

## I/O Issues

No I/O correctness issues found:
- Uses `.writerStreaming()` throughout (`src/grep.zig:1029, 1033`).
- 8192-byte buffers (`src/grep.zig:1028, 1032`).
- `flush()` called before exit (`src/grep.zig:1038-1039`).
- Errors go to stderr, matches to stdout.

---

## Dynamic Verification

Build: `zig build` — success, no warnings.

Tests: `zig build test --summary all` — 1783/1802 passed, 19 skipped.
No failures. (The -x BRE bug and -o multiple-match bug are not covered
by the unit tests or integration tests.)

Integration tests: `just it-util grep` — 47/47 passed. The -x test
(`grep -x whole line`) uses `-Ex` (ERE mode), which works correctly
and masks the BRE mode bug. The -o test uses a single-match-per-line
input, masking the multiple-match bug.

Key dynamic test results:

| Test | Expected | Actual | Result |
|------|----------|--------|--------|
| `echo "foo" \| grep -x "foo"` (BRE) | exit 0, prints foo | exit 1 | FAIL |
| `echo "foobarfoo" \| grep -o "foo"` | two lines | one line | FAIL |
| `echo "hello foo" \| grep -wo "foo"` | `foo` | ` foo ` | FAIL |
| `echo "foo" \| grep -f - file` | works | file-not-found error | FAIL |
| `echo "" \| grep -f /dev/null` | exit 1 | exit 2 + error | FAIL |
| empty-line pattern in -f | matches all | skipped | FAIL |
| `grep "x" /some/dir/` (no -r) | error + exit 2 | silent exit 1 | FAIL |
| `grep -I "x" binary_file` | exit 1 (skipped) | exit 0 + output | FAIL |
| `grep --binary-files=without-match` | exit 1 | exit 0 + output | FAIL |
| GREP_OPTIONS env var | honored | ignored | FAIL |
| GREP_COLOR env var | used for color | ignored | FAIL |

---

## Findings

| ID | Severity | Category | Description |
|----|----------|----------|-------------|
| G-01 | CRITICAL | Incorrect | `-x` in BRE/default mode: uses ERE group syntax `^(p)$`; literal parens match `(pattern)` not `pattern` |
| G-02 | CRITICAL | Incorrect | `-o` only prints first match per line; all non-overlapping matches required |
| G-03 | IMPORTANT | Incorrect | `-w` with `-o` or `--color`: match span includes boundary characters, not just the word |
| G-04 | IMPORTANT | Incorrect | `-f -` (stdin as pattern file) fails with "No such file or directory" |
| G-05 | IMPORTANT | Incorrect | `-f` with empty file: exits 2 with error message; should exit 1 (no match) |
| G-06 | IMPORTANT | Incorrect | Empty-line patterns in `-f` file skipped; should match every input line |
| G-07 | IMPORTANT | Incorrect | Directory argument without `-r`: silent exit 1; should print error and exit 2 |
| G-08 | IMPORTANT | STUB | `-I` / `--binary-files=without-match`: no binary detection; silently outputs matches |
| G-09 | IMPORTANT | Incorrect | `-b` with `-o`: offset is always line-start of first match; should be offset of each match |
| G-10 | SUGGESTION | Missing | `GREP_OPTIONS` environment variable not read |
| G-11 | SUGGESTION | Incorrect | `GREP_COLOR` environment variable not read; match highlight color hardcoded |
| G-12 | SUGGESTION | STUB | `-J`, `-M`, `-X`: decompression flags are accepted no-ops (scope acceptable, per flags.md SHOULD) |
| G-13 | SUGGESTION | STUB | `-O`, `-p`, `-S`: symlink follow policy in recursive mode not implemented |
| G-14 | SUGGESTION | STUB | `-D`: device action always "read"; value accepted but ignored |

---

## Fix Order

```
Fix Order:
1. [CRITICAL]  -x in BRE mode: change wrap to ^{p}$ not ^({p})$ — src/grep.zig:478-479
2. [CRITICAL]  -o multiple matches: loop regexec advancing past match end — src/grep.zig:748-770
3. [IMPORTANT] -w match span: use pmatch[N] for inner group, not pmatch[0] — src/grep.zig:481-485
4. [IMPORTANT] -f - stdin support: detect "-" and read from stdin — src/grep.zig:440-441
5. [IMPORTANT] -f empty file: treat zero patterns from -f as "no match" (exit 1), not error — src/grep.zig:1062-1065
6. [IMPORTANT] Empty pattern lines in -f: append empty string, don't skip — src/grep.zig:448-451
7. [IMPORTANT] Directory without -r: stat the path and error if directory — src/grep.zig:1122-1148
8. [IMPORTANT] Binary detection: implement NUL-byte scan for -I / -a / --binary-files
9. [IMPORTANT] -b with -o: track running byte offset and emit per-match — src/grep.zig:757-770
10. [SUGGESTION] GREP_OPTIONS: read env var and prepend to args — src/grep.zig:parseArgs
11. [SUGGESTION] GREP_COLOR: read env var for match highlight code — src/grep.zig:595
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
