# nl Code Audit

Date: 2026-03-28
Build: PASS (zig build)
Unit tests: PASS (all embedded tests pass)
Integration tests: 41/41 PASS

Assessment: NEEDS_FIXES

---

## Issues

### [CRITICAL] Section delimiter resets line counter only on header transition

Location: `src/nl.zig:444-447` (`processLine`)

Problem: The code resets `state.line_number` only when the delimiter
signals a `.header` section. GNU resets the counter on **every**
section delimiter transition (body, footer, and header). Without
`-p`, encountering any section delimiter begins a new logical page
and the counter restarts from `-v`.

Observed:

```
$ printf '\\:\\:\nbody1\n\\:\\:\nbody2\n' | nl
```

GNU output:
```
(blank)
     1  body1
(blank)
     1  body2
```

vibeutils output:
```
(blank)
     1  body1
(blank)
     2  body2
```

Fix: Change the reset condition from `if (new_section == .header)`
to always reset unless `opts.no_renumber`:

```zig
if (!opts.no_renumber) {
    state.line_number = opts.start;
}
```

---

### [CRITICAL] Unnumbered lines use separator characters instead of spaces

Location: `src/nl.zig:394-404` (`writeUnnumberedLine`)

Problem: GNU outputs `width + len(separator)` spaces for
non-numbered lines, with **no separator character**. vibeutils
outputs `width` spaces followed by the separator string, then the
content. The separator leaks into lines that should have no number.

Observed with `-b n -s ':'`:

GNU: `       a` (7 spaces, no colon)
vibeutils: `      :a` (6 spaces + colon)

The correct formula is `width + len(separator)` spaces, then content.

Fix: Replace `writeUnnumberedLine` body:

```zig
fn writeUnnumberedLine(writer: anytype, line: []const u8,
    opts: NlOptions) !void {
    const total_spaces = opts.width + @as(u32, @intCast(opts.separator.len));
    var i: u32 = 0;
    while (i < total_spaces) : (i += 1) {
        try writer.writeAll(" ");
    }
    try writer.writeAll(line);
    try writer.writeAll("\n");
}
```

---

### [CRITICAL] Non-numbered blank lines output bare newline instead of padded spaces

Location: `src/nl.zig:474-476` (`processLine`, `.non_empty` branch)

Problem: When a blank line is skipped under `-b t` (default) or `-b
a -l N` (below threshold), GNU outputs `width` spaces followed by a
newline. vibeutils outputs a bare newline. This produces incorrect
output for any pipeline that relies on column-aligned nl output.

Observed with default settings:

GNU: `       \n` (6 spaces then newline) for each skipped blank
vibeutils: `\n` (bare newline)

This is the same root cause as the `writeUnnumberedLine` bug: skipped
blank lines must also be formatted as `width + len(separator)` spaces.

Fix: Replace the bare `try writer.writeAll("\n")` for non-numbered
blank lines with a call to `writeUnnumberedLine(writer, "", opts)`.

Affects `.non_empty` blank path at line 475 and the below-threshold
blank path in the `.all` branch at line 465.

---

### [CRITICAL] pBRE numbering style (`pBRE`) not implemented

Location: `src/nl.zig:142-147` (`parseNumberingStyle`)

Problem: GNU `-b pBRE`, `-h pBRE`, and `-f pBRE` number only lines
matching a POSIX basic regular expression. This is a MUST-tier flag
(listed in POSIX). vibeutils returns an invalid-style error for any
value starting with `p`.

Observed:

```
$ echo -e "hello\nworld" | nl -b phello
nl: invalid body numbering style: 'phello'
```

GNU output: `     1  hello` (only matching line numbered).

Fix: Extend `NumberingStyle` with a `regex` variant holding the BRE
pattern string. In `parseNumberingStyle`, detect the `p` prefix and
store the remainder. In `processLine`, use POSIX `regcomp`/`regexec`
(via C extern) or `std.posix.regex` to test each line.

---

### [CRITICAL] `-d ''` (empty delimiter, disable section matching) rejected as error

Location: `src/nl.zig:247-256` (`resolveOptions`)

Problem: GNU documents that `-d ''` disables section delimiter
matching entirely (a GNU extension). vibeutils returns an error for
any delimiter string not of length 1 or 2. Scripts that pass `-d ''`
to disable paging will fail.

Observed:

```
$ printf '\\:\nhello\n' | nl -d '' -b a
nl: invalid section delimiter: ''
```

GNU output: numbers all lines including the literal `\:` line.

Fix: Treat empty delimiter as a special "disabled" state. Add a
`delimiter_disabled: bool` field to `NlOptions`. When disabled, skip
`isSectionDelimiter` checks entirely.

---

### [IMPORTANT] `-d` rejects more than 2 characters (GNU extension not supported)

Location: `src/nl.zig:247-256` (`resolveOptions`)

Problem: GNU accepts delimiter strings longer than 2 characters as a
documented extension. vibeutils returns an error for any string with
`len > 2`.

Observed:

```
$ printf 'abcabcabc\nhello\n' | nl -d 'abc' -b a
nl: invalid section delimiter: 'abc'
```

GNU output: recognises `abcabcabc` (3 pairs of `abc`) as a header
delimiter.

Fix: Remove the `> 2` length restriction. Store the full delimiter
string and update `isSectionDelimiter` to use variable-length pair
matching.

---

### [IMPORTANT] Unit test for `-b n` validates wrong behavior

Location: `src/nl.zig:732`

Problem: The test expects `"      \thello\n      \tworld\n"` (6
spaces + TAB). GNU outputs `"       hello\n       world\n"` (7
spaces, no TAB). The test passes against the implementation but locks
in non-GNU behavior, concealing the `writeUnnumberedLine` bug.

Fix: After fixing `writeUnnumberedLine`, update the expected string
to `"       hello\n       world\n"`.

---

### [IMPORTANT] Integration test for "nl default skips blanks" hides blank-line format bug

Location: `tests/utilities/nl_test.sh` (`nl default skips blanks`)

Problem: The expected string contains a bare empty line between
numbered lines. GNU outputs 6 spaces on that line. The test passes
against vibeutils' bare-newline output and masks the blank-line
padding bug identified above.

Fix: After fixing the blank-line output, update the expected string
to include the space-padded blank line. Use `printf` with `\n`
escapes or a heredoc to express the exact expected bytes.

---

### [IMPORTANT] Integration test for "nl -b n numbers none" validates wrong behavior

Location: `tests/utilities/nl_test.sh` (`nl -b n numbers none`)

Problem: The expected string is `"      \thello\n      \tworld\n"`
(6 spaces + TAB), matching the vibeutils bug rather than GNU
behavior.

Fix: After fixing `writeUnnumberedLine`, update expected to
`"       hello\n       world\n"`.

---

## Fix Order

1. [CRITICAL] Section delimiter resets on header only — `src/nl.zig:444`
2. [CRITICAL] `writeUnnumberedLine` uses separator instead of spaces — `src/nl.zig:394`
3. [CRITICAL] Skipped blank lines output bare newline — `src/nl.zig:465,475`
4. [CRITICAL] pBRE style not implemented — `src/nl.zig:142`
5. [CRITICAL] `-d ''` rejected instead of disabling section matching — `src/nl.zig:247`
6. [IMPORTANT] `-d` with >2 chars rejected — `src/nl.zig:247`
7. [IMPORTANT] Fix unit test `-b n` expected string — `src/nl.zig:732`
8. [IMPORTANT] Fix IT test `nl default skips blanks` expected string — `tests/utilities/nl_test.sh`
9. [IMPORTANT] Fix IT test `nl -b n numbers none` expected string — `tests/utilities/nl_test.sh`

---

## Counts

- CRITICAL: 5
- IMPORTANT: 4
- SUGGESTION: 0

State: REVIEW COMPLETE - NEEDS_FIXES
