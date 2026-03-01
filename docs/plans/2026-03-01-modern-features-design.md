# Modern Features Design

Date: 2026-03-01

## Goal

Fulfill the "modern enhancements" promise for vibeutils.
Spread existing style infrastructure (colors, terminal
detection, NO_COLOR) beyond `ls` to more utilities, add
progress feedback for long operations, and make defaults
smarter for interactive use.

## Audience

Building for personal daily use but with the quality bar
that others could adopt it. Features should feel natural
and unobtrusive — enhance without getting in the way.

## Approach

Feature-by-feature, shipped independently in priority
order. Each feature is a standalone PR that adds value
immediately.

## Compatibility Strategy

Standard POSIX behavior by default. Modern defaults
available via `VIBEUTILS_MODERN=1` env var. Color output
activates only when stdout/stderr is a TTY. Scripts and
piped output are never affected.

---

## Feature 1: Colored `--help` Output

**Priority:** Highest — one change benefits all 47 utilities.

Modify `src/common/argparse.zig` to render help text with
ANSI colors when stdout is a terminal.

**Visual design:**
- Utility name in bold
- Synopsis: flags in cyan, arguments in yellow
- Section headers (OPTIONS, EXAMPLES) in bold
- Flag names (`-h`, `--help`) in cyan
- Flag descriptions in default color

**Scope:** One file change (argparse.zig) + tests. No
per-utility changes needed.

**Rules:** Only activates when stdout is a TTY. Piped
output stays plain text. Respects NO_COLOR.

## Feature 2: `grep --color=auto`

**Priority:** High — most used color feature after `ls`.

Add colored match highlighting to `src/grep.zig`.

**Behavior:**
- `--color=auto` (default): color when TTY, plain when
  piped
- `--color=always`: force color (for piping to `less -R`)
- `--color=never`: no color

**Color scheme:**
- Matched text: bold red
- Filename prefix: magenta
- Line numbers: green
- Separator (`:`): cyan

Uses existing `common.style` infrastructure. Matches GNU
grep color conventions exactly.

## Feature 3: `VIBEUTILS_MODERN=1` Environment Variable

**Priority:** High — central mechanism for smart defaults.

Add `common.isModernMode()` that checks the
`VIBEUTILS_MODERN` env var. Utilities query this at
argument parsing time and adjust defaults.

**What it controls:**
- `df`, `du`, `ls -l`: human-readable sizes by default
  (as if `-h` was passed)
- Future smart defaults plug in here

**Rules:**
- Explicit flags always override
- Off by default — standard POSIX behavior unless opted in
- No config file — just one env var
- User adds `export VIBEUTILS_MODERN=1` to shell profile

## Feature 4: `df`/`du` Color-Coded Capacity

**Priority:** Medium — quick visual scan of disk usage.

Color the usage percentage based on thresholds when stdout
is a TTY.

**`df` behavior:**
- Green: 0-70% used
- Yellow: 70-90% used
- Red: 90%+ used
- Optional inline bar: `[████░░░░░░] 43%`

**`du` behavior:**
- Color size column relative to largest entry in output
- Largest in red, medium in yellow, small in green

**Rules:** Respects NO_COLOR, terminal detection. Plain
text when piped. Thresholds hardcoded (no config for v1).

## Feature 5: Progress Feedback for `cp`/`mv`/`dd`

**Priority:** Medium — makes long operations less opaque.

Show a status line on stderr when an operation takes
longer than ~2 seconds.

**Format:**
```
cp: copying large-file.iso  248MB/1.2GB  20%
```

**How it works:**
- Start timer when operation begins
- After 2 seconds with no completion, print status to
  stderr
- Update in place (~every 0.5s) via carriage return
- Clear the line when done
- Only when stderr is a TTY

**What triggers it:**
- `cp`: file-to-file copy above time threshold
- `mv`: cross-filesystem moves (same-filesystem is
  instant rename)
- `dd`: already has `status=progress` — unify the style

**Infrastructure:** Small progress module in `src/common/`
— a struct tracking start time, bytes transferred, total
bytes. Utilities call `progress.update(bytes_so_far)` in
their copy loops.

## Feature 6: Smarter Error Messages

**Priority:** Medium-low — incremental improvement, not
a big-bang change.

Enhance individual utilities to suggest fixes when the
cause is obvious.

**Patterns:**
- File not found + similar name exists:
  `rm: cannot remove 'tset.txt': No such file or
  directory (did you mean 'test.txt'?)`
- Permission denied on owned file:
  `cp: cannot open 'readonly.txt': Permission denied
  (file is not writable)`
- Directory not empty:
  `rmdir: failed to remove 'src': Directory not empty
  (use rm -r to remove recursively)`

**Rules:**
- Suggestions in parentheses after the standard error
- Standard error format stays intact for script parsing
- Fuzzy matching: simple Levenshtein or prefix match,
  only suggest if single close match
- No suggestion better than wrong suggestion
- No suggestions when stderr is not a TTY
- No expensive operations (no recursive searches)

**Scope:** Start with `rm`, `cp`, `cat`. Add to other
utilities as opportunities arise.

## Feature 7: `diff` Utility with Colored Output

**Priority:** Low — largest effort, new utility.

Add `src/diff.zig` implementing unified diff with colored
output.

**Core features:**
- Unified diff (`-u`) as default format
- Color when TTY: red removed, green added, cyan hunk
  headers, bold file headers
- Flags: `-u` (unified), `-c` (context), `-y`
  (side-by-side), `-r` (recursive), `-q` (brief)
- `--color=auto/always/never`

**Algorithm:** Myers diff, implemented from scratch.

**Scope:** New `src/diff.zig`, add to `build.zig`, man
page `man/man1/diff.1`. Largest item — own sprint.

**Compatibility:** Output format matches GNU unified diff.
Tools that parse diff output (patch, git) work unchanged.
