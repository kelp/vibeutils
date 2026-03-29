# Code Audit: ls

> **Re-audited 2026-03-28**: Corrected from macOS-primary
> to GNU-primary behavioral reference per project spec.
> Flags that exist in both GNU and macOS with different
> semantics: the GNU semantics are correct. Six previous
> CRITICAL findings (F05-F10) have been removed because
> the code correctly follows GNU. One new CRITICAL finding
> added: -G means --no-group in GNU but colorize in our code.

**Date**: 2026-03-28
**Source**: src/ls/main.zig, core.zig, display.zig,
            formatter.zig, sorter.zig, types.zig,
            entry_collector.zig, recursive.zig
**Specs**: ls-posix.txt, ls-gnu.txt (PRIMARY),
           ls-macos.txt (for macOS-only flags),
           docs/specs/ls-flags.md (tier matrix)

## Executive Summary

NEEDS_FIXES — Several real bugs remain after correcting the
reference spec. Exit codes are always 0 (GNU requires 0/1/2).
-G is mapped to the wrong semantic. -n does not imply -l.
-s with -l omits per-entry block counts. Multi-operand output
puts headers on non-directory operands. Error messages use
Zig internal names rather than POSIX strings. Several
macOS-only flags are accepted but silently no-op.

---

## Spec Hierarchy Applied

Per `docs/specs/ls-flags.md`, when a flag appears in both
GNU and macOS with different semantics, GNU wins:

| Flag | GNU meaning          | macOS meaning        | Code follows | Correct? |
|------|----------------------|----------------------|--------------|----------|
| -B   | hide backups (~)     | octal non-printable  | GNU          | YES      |
| -D   | dired mode (bool)    | strftime format arg  | GNU (stub)   | YES      |
| -G   | --no-group           | colorize             | macOS        | **NO**   |
| -I   | ignore PATTERN       | prevent root -A      | GNU          | YES      |
| -U   | no sort (dir order)  | creation-time sort   | GNU          | YES      |
| -v   | version sort         | raw/unedited print   | GNU          | YES      |
| -w   | set width (COLS)     | raw print            | GNU          | YES      |
| -X   | sort by extension    | no cross-fs in -R    | GNU          | YES      |

Flags that are macOS-only (not in GNU): -D (GNU is dired,
macOS is strftime — GNU wins), -e, -O, -P, -W, -y, -@, -%,
-, (comma). For these, macOS spec applies.

---

## Flag-by-Flag Compliance

| Flag | Tier  | Parsed? | Implemented? | Correct? | Notes |
|------|-------|---------|-------------|----------|-------|
| -1   | MUST  | yes | yes | yes | |
| -a   | MUST  | yes | yes | yes | |
| -A   | MUST  | yes | yes | yes | |
| -c   | MUST  | yes | yes | yes | |
| -C   | MUST  | yes | yes | yes | |
| -d   | MUST  | yes | yes | yes | |
| -f   | MUST  | yes | yes | yes | no_sort skips sort; implies -a |
| -F   | MUST  | yes | yes | yes | |
| -g   | MUST  | yes | yes | yes | GNU: like -l but omit owner; correct |
| -H   | MUST  | yes | **NO** | **NO** | parsed but stat path ignores it |
| -i   | MUST  | yes | yes | yes | |
| -k   | MUST  | yes | yes | yes | |
| -l   | MUST  | yes | yes | yes | |
| -L   | MUST  | yes | yes | yes | |
| -m   | MUST  | yes | yes | yes | |
| -n   | MUST  | yes | partial | **NO** | GNU: "like -l"; our: does not imply -l |
| -o   | MUST  | yes | yes | yes | |
| -p   | MUST  | yes | yes | yes | |
| -q   | MUST  | yes | yes | partial | GNU: default on TTY; our: never default |
| -r   | MUST  | yes | yes | yes | |
| -R   | MUST  | yes | yes | yes | |
| -s   | MUST  | yes | partial | **NO** | -sl missing per-entry block column |
| -S   | MUST  | yes | yes | yes | |
| -t   | MUST  | yes | yes | yes | |
| -u   | MUST  | yes | yes | yes | |
| -x   | MUST  | yes | yes | yes | |
| -h   | MUST  | yes | yes | yes | |
| -T   | MUST  | yes | yes | yes | |
| -b   | SHOULD| yes | yes | yes | GNU C-escape semantics |
| -B   | SHOULD| yes | yes | yes | GNU: hide backups (~); correct |
| -D   | SHOULD| yes | **STUB** | partial | GNU: dired mode (bool); parsed as bool, help says no-op |
| -e   | SHOULD| yes | **STUB** | n/a | macOS-only: show ACLs in -l; no-op |
| -G   | SHOULD| yes | yes | **NO** | GNU: --no-group; our: colorize (macOS) |
| -I   | SHOULD| yes | yes | yes | GNU: ignore PATTERN; correct |
| -O   | SHOULD| yes | **STUB** | n/a | macOS-only: show file flags; no-op |
| -P   | SHOULD| yes | **STUB** | **NO** | field set but stat path always follows symlinks |
| -U   | SHOULD| yes | yes | yes | GNU: no sort; correct |
| -v   | SHOULD| yes | yes | yes | GNU: version sort; correct |
| -w   | SHOULD| yes | yes | yes | GNU: set width COLS; correct |
| -W   | SHOULD| yes | **STUB** | n/a | macOS-only: whiteouts; no-op |
| -X   | SHOULD| yes | yes | yes | GNU: sort by extension; correct |
| -y   | SHOULD| yes | **NO** | **NO** | macOS-only: tie-break -t; field never transferred to LsOptions |
| -@   | SHOULD| yes | **STUB** | n/a | macOS-only: xattrs; no-op |
| -%   | SHOULD| yes | **STUB** | n/a | macOS-only: SIP info; no-op |
| -,   | SHOULD| yes | yes | yes | |
| --color | SHOULD| yes | yes | yes | |
| --group-directories-first | SHOULD| yes | yes | yes | |
| --time-style | SHOULD| yes | yes | yes | |

---

### Stubs Found

These flags are parsed but produce no behavioral change.
MacOS-only stubs are lower severity because they are optional
platform extensions.

**-D (dired)** — `src/ls/main.zig:54`. GNU defines -D as
dired mode output. Parsed as `dired: bool` but never
transferred to `LsOptions` and not used. Help text labels
it "(no-op)". Parsing as bool is correct per GNU; the stub
behavior should be documented.

**-e (show_acls)** — `src/ls/main.zig:55`. macOS-only.
Parsed, never read. Acceptable as macOS-only no-op.

**-O (show_file_flags)** — `src/ls/main.zig:58`. macOS-only.
Parsed, never read. Acceptable as macOS-only no-op.

**-W (show_whiteouts)** — `src/ls/main.zig:63`. macOS-only.
Parsed, never read. Acceptable as macOS-only no-op.

**-@ (show_xattrs)** — `src/ls/main.zig:66`. macOS-only.
Parsed, never read. Acceptable as macOS-only no-op.

**-% (show_sip)** — `src/ls/main.zig:67`. macOS-only.
Parsed, never read. Acceptable as macOS-only no-op.

**-P (no_follow_symlinks)** — `src/ls/types.zig:59`.
Transferred to `LsOptions` at `main.zig:329`. But
`listDirectory()` at `main.zig:503` always calls
`common.file.FileInfo.stat()` (which follows symlinks)
regardless of this flag. `-H` suffers the same problem.
This is a real stub even though -P is macOS-only.

---

### Incorrect Behavior

**-G: mapped to colorize instead of GNU --no-group**
GNU man page: "-G, --no-group: in a long listing, don't
print group names."
Our code: `args.colorize` sets `color_mode = .auto`.
The -G flag in macOS means colorize, but -G is in GNU too
with the opposite meaning. Since GNU is primary, our -G
should suppress group names in long format, not enable color.
Running `ls -lG` should omit the group column. Instead it
enables color.
Location: `src/ls/main.zig:251-253` (colorize check) and
`src/ls/main.zig:113` (meta mapping omit_group to -G).

**-n: does not imply -l**
GNU man page: "-n, --numeric-uid-gid: like -l, but list
numeric user and group IDs."
`main.zig:295` long_format condition:
`args.long_format or args.omit_owner or args.omit_group`
does not include `args.numeric_ids`.
Running `ls -n` produces multi-column output, not long
format.

**-s with -l: no per-entry block count column**
GNU -s: "print the allocated size of each file, in blocks."
When combined with -l, each long-format line should begin
with the block count. `printLongFormatEntryAligned` in
`formatter.zig:327` never prints a block count prefix;
`printEntries` at `formatter.zig:619` explicitly skips
the total header when `long_format` is true and has no
block-per-entry path for long format.
Expected: `  8 -rw-r--r-- 1 user group 2534 Mar 1 file`
Observed: `-rw-r--r-- 1 user group 2534 Mar 1 file`

**-P and -H: symlink resolution ignores flags**
`listDirectory()` at `main.zig:503` calls
`common.file.FileInfo.stat(path)` unconditionally for
command-line paths. This always follows symlinks. `-P`
(don't follow) and `-H` (follow cmd-line only) are stored
in `LsOptions` but never consulted in the `stat()` call
that determines entry kind and stat for command-line
operands. `ls -P /tmp/link_to_dir` lists the target
directory's contents rather than the link itself.

**Multiple file operands: all paths get a colon header**
GNU ls: when multiple operands are given, non-directory
operands are listed bare (no header); directory operands
get a `dirname:` header only when mixed with other
operands. `main.zig:357-364` unconditionally prints
`path:\n` for every operand when `paths.len > 1`, even
plain files. Running `ls README.md src/` prints
`README.md:\nREADME.md\n` then `src/:\n...`. The file
should be printed without a header line.

**Error messages use Zig internal error names**
`ls /nonexistent` prints:
  `ls: /nonexistent: error.FileNotFound`
GNU convention:
  `ls: cannot access '/nonexistent': No such file or directory`
Zig error names are not user-facing strings and confuse
users who expect POSIX error messages.
Location: `main.zig:504`.

**Exit code always 0 on error**
GNU ls exit status: 0 if OK, 1 if minor problems
(e.g., cannot access a subdirectory), 2 if serious trouble
(e.g., cannot access a command-line argument).
`ls /nonexistent` exits 0. `runUtility` at `main.zig:194`
returns 0 unconditionally. `listDirectory` at `main.zig:504`
prints the error and returns void, never propagating an
error signal.

**-y: macOS-only tie-breaker, not implemented**
macOS -y: when -t is active, sort lexicographic ties in the
same direction as the time sort (LS_SAMESORT behavior).
Our code parses `-y` into `sort_by_name: bool` at
`main.zig:65`, but that field is never transferred to
`LsOptions` and never read in the sorter. Since -y is
macOS-only, the macOS spec applies here.

**-q not default on terminal output**
GNU man page: `--show-control-chars` is "the default,
unless program is 'ls' and output is a terminal." This
means GNU ls also defaults to `-q` behavior when stdout
is a TTY. Our code initializes
`non_printable_as_question: bool = false` with no TTY
check. Filenames with non-printable characters are passed
raw to the terminal when they should be replaced with `?`.
Location: `src/ls/types.zig:35`.

---

## Core Behavior Issues

**-G semantic collision (CRITICAL)**
The `-G` flag has opposite meanings in GNU and macOS. GNU
is the primary spec. Our implementation follows macOS. This
means `-lG` does not suppress group names as GNU users
expect, and users relying on macOS color shorthand get it
but at the cost of violating the primary spec.

**Multi-operand ordering (IMPORTANT)**
All operands print with `path:` headers when more than one
is given. Non-directory operands should be printed bare,
preceding all directory operands. The sort-and-separate
logic is missing entirely.

**Exit code 3-level scheme (IMPORTANT)**
GNU specifies three exit codes (0/1/2), not just 0/1. The
current code always returns 0, failing both the "minor
error" (1) and "serious error" (2) contracts.

---

## I/O Issues

No I/O correctness issues found. The implementation:
- Uses `.writerStreaming()` correctly at `main.zig:170`
- Uses 8192-byte buffers at `main.zig:169`
- Flushes before exit at `main.zig:180-181`
- Sends errors to stderr

---

## Dynamic Verification

```
./zig-out/bin/ls                    # OK
./zig-out/bin/ls --version          # OK: "ls (vibeutils) 0.8.2"
./zig-out/bin/ls --invalid-flag     # exit 1, correct
./zig-out/bin/ls /nonexistent       # exit 0, WRONG (should be 2)
./zig-out/bin/ls -n                 # multi-column, WRONG (should be long)
./zig-out/bin/ls -lG                # colorize, WRONG (should omit group)
./zig-out/bin/ls -lP /tmp/etc_link  # lists target, WRONG (should show link)
./zig-out/bin/ls -sl                # no per-entry blocks, WRONG
./zig-out/bin/ls README.md src/     # file gets header, WRONG
```

---

## Findings

| ID  | Severity  | Category  | Description |
|-----|-----------|-----------|-------------|
| F01 | CRITICAL  | Exit code | Exit code always 0; GNU requires 2 for bad cmd-line args, 1 for minor errors |
| F02 | CRITICAL  | Stub      | -P parsed but never used; symlinks always followed for cmd-line args |
| F03 | CRITICAL  | Stub      | -H parsed but never used; symlinks always followed for cmd-line args |
| F04 | CRITICAL  | Incorrect | -G: enables color (macOS) instead of omitting group column (GNU primary) |
| F05 | IMPORTANT | Incorrect | -n does not imply -l; GNU spec "like -l, but numeric IDs" |
| F06 | IMPORTANT | Incorrect | -s with -l: no per-entry block count column |
| F07 | IMPORTANT | Incorrect | Multi-operand: file operands get `filename:` header; should print bare |
| F08 | IMPORTANT | Incorrect | Error messages show Zig error names, not POSIX/GNU strings |
| F09 | IMPORTANT | Stub      | -D parsed as bool no-op; GNU dired mode is also a stub (help says so) |
| F10 | IMPORTANT | Stub      | -e, -O, -W, -@, -% macOS-only stubs; no-op; help is clear |
| F11 | IMPORTANT | Incorrect | -y no-op; macOS-only tie-break for -t; field never used |
| F12 | SUGGESTION| Incorrect | -q not default on terminal; GNU and POSIX both require it |

**Findings removed vs previous audit** (code correctly follows GNU):
- ~~F05: -X extension sort~~ — GNU behavior, correct
- ~~F06: -U no sort~~ — GNU behavior, correct
- ~~F07: -v version sort~~ — GNU behavior, correct
- ~~F08: -B hide backups~~ — GNU behavior, correct
- ~~F09: -w set width~~ — GNU behavior, correct
- ~~F10: -I pattern filter~~ — GNU behavior, correct
- ~~F12: -g omits owner~~ — GNU behavior, correct
- ~~F14: -s totals in single-column~~ — macOS-only restriction; GNU prints totals; code is correct
- ~~F20: -D strftime vs dired~~ — GNU dired is bool; code is correct per GNU

---

## Fix Order

```
Fix Order:
1.  [CRITICAL] Exit codes: return 2 for inaccessible cmd-line
    args, 1 for minor errors during listing
    — main.zig:494-506 (listDirectory, runUtility)
2.  [CRITICAL] -G: map to omit_group+long_format per GNU, not
    colorize; add --color or -G-as-color to a custom extension
    — main.zig:113 (meta) and main.zig:251-253 (colorize check)
3.  [CRITICAL] -P/-H: command-line stat uses stat() not lstat()
    — main.zig:503; must call lstat() when -P is set,
    stat() when -H, stat() by default (GNU default follows
    cmd-line symlinks to dirs)
4.  [IMPORTANT] -n implies -l: add `or args.numeric_ids`
    to long_format condition
    — main.zig:295
5.  [IMPORTANT] -s with -l: print per-entry block count as
    first field in printLongFormatEntryAligned
    — formatter.zig ~line 327 (before permissions)
6.  [IMPORTANT] Multi-operand headers: separate non-dir from
    dir operands; print non-dirs bare first, then dirs with
    headers
    — main.zig:354-364
7.  [IMPORTANT] Error messages: map Zig error names to POSIX
    strings (FileNotFound → "No such file or directory", etc.)
    — main.zig:504
8.  [IMPORTANT] -y: implement macOS tie-breaking for -t, or
    transfer sort_by_name to LsOptions and use in sorter
    — main.zig:65 (transfer field), sorter.zig compareEntries
9.  [SUGGESTION] -q default on terminal: set
    non_printable_as_question = is_terminal at options build
    — main.zig:292-335 (LsOptions init block)
```

STATE: REVIEW COMPLETE — NEEDS_FIXES
