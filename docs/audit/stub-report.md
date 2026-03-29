# Stub Flag Report

**Date:** 2026-03-28
**Scope:** All code audit reports in `docs/audit/`

A stub flag is a flag that is parsed by the argument parser but
produces no behavioral change, or where the implementation is
entirely absent and the flag is silently ignored.

---

## Stub Flag Table

Sorted by utility name.

| Utility | Flag | Location | Description |
|---------|------|----------|-------------|
| chmod | symbolic modes | `src/chmod.zig` | Symbolic mode strings (e.g., `u+x`) rejected; only octal modes accepted |
| cp | `-N` | `src/cp.zig` | Parsed but suppresses copy of extended attributes (macOS-only; no-op on Linux) |
| date | `-f` | `src/date.zig` | Flag accepted; completely unimplemented — exits immediately with no output |
| date | `-z` | `src/date.zig` | Flag accepted; sets a field but timezone is never applied to output |
| date | `-v` | `src/date.zig` | Flag accepted; adjustment logic is a stub |
| dd | `files=N` | `src/dd.zig` | Parsed; silently ignored — always reads exactly one input file |
| dd | `iflag=` | `src/dd.zig` | Parsed; all input flags (direct, sync, noerror, fullblock) are no-ops |
| dd | `oflag=` | `src/dd.zig` | Parsed; all output flags (direct, sync, dsync) are no-ops |
| dd | `speed_hz=N` | `src/dd.zig` | Parsed; rate limiting is entirely unimplemented |
| dd | `conv=sparse` | `src/dd.zig` | Parsed; sparse output not implemented |
| dd | `conv=parity` | `src/dd.zig` | Parsed; parity operations unimplemented |
| df | `-I` | `src/df.zig` | Wrong semantic on Linux (macOS suppress-inodes, not GNU type-filter) |
| df | `-n` | `src/df.zig` | Parsed; Darwin `NOWAIT` flag applied unconditionally — no-op on Linux |
| df | `-Y` | `src/df.zig` | Parsed; file system type for file lookups is a stub |
| du | `-I` | `src/du.zig` | Parsed; ignore-pattern is entirely unimplemented |
| du | `-A` | `src/du.zig` | Parsed; apparent size for directories uses block size not content size |
| du | `-b` | `src/du.zig` | Parsed; byte-exact apparent size unimplemented (same issue as `-A`) |
| du | `-S` | `src/du.zig` | Parsed; excludes subdirectory contents from total (wrong: uses inode-only path) |
| env | bare `-` | `src/env.zig` | Single dash should clear environment; treated as no-op |
| env | `-P` | `src/env.zig` | Parsed; sets PATH in child process incorrectly (should set in environment passed to child) |
| env | `-S` | `src/env.zig` | Completely unimplemented stub |
| find | `-regex` | `src/find.zig` | Parsed; always returns false instead of matching |
| find | `-iregex` | `src/find.zig` | Parsed; always returns false instead of matching |
| find | `-Bmin` | `src/find.zig` | Parsed; always returns true (birth-time not supported on Linux) |
| find | `-Bnewer` | `src/find.zig` | Parsed; always returns true |
| find | `-Btime` | `src/find.zig` | Parsed; always returns true |
| find | `-newerXY` | `src/find.zig` | Parsed; always returns true |
| find | `-printf` | `src/find.zig` | Parsed; format string ignored — prints a fixed placeholder |
| find | `-s` | `src/find.zig` | Parsed; file-system stable order not implemented |
| find | `-perm +mode` | `src/find.zig` | `+mode` and `-mode` forms rejected; only exact match works |
| find | `-exec {} +` | `src/find.zig` | Collected-args form of -exec not implemented |
| find | `-execdir {} +` | `src/find.zig` | Collected-args form of -execdir not implemented |
| free | `-s N` | `src/free.zig` | `-s` short flag hijacked by `si` bool field; `-s N` (canonical GNU form) is unreachable |
| grep | `-x` (BRE) | `src/grep.zig` | `-x` in BRE mode uses ERE group syntax; whole-line match broken |
| head | `--silent` | `src/head.zig` | Long-form alias for `-q` is broken; not recognized |
| head | `[-]NUM` | `src/head.zig` | Obsolete `-NUM` syntax not implemented |
| id | `-a` | `src/id.zig` | Parsed; supposed to be ignored per POSIX but field is unread |
| ln | `-h`/`-n` | `src/ln.zig` | Parsed; no-dereference flag stored but never consulted in symlink operation |
| ln | `-i` | `src/ln.zig` | Parsed; interactive prompt accepted `y` but does not delete existing target |
| ls | `-G` | `src/ls/main.zig` | Maps to colorize (macOS) instead of `--no-group` (GNU primary) |
| ls | `-n` | `src/ls/main.zig` | Parsed; does not imply `-l` as GNU requires |
| ls | `-H` | `src/ls/main.zig` | Parsed; symlink resolution always follows regardless of flag |
| ls | `-P` | `src/ls/main.zig` | Parsed; symlink resolution always follows regardless of flag |
| ls | `-D` | `src/ls/main.zig` | Parsed as bool; dired output mode not implemented |
| ls | `-e` | `src/ls/main.zig` | macOS-only (show ACLs); parsed but never read |
| ls | `-O` | `src/ls/main.zig` | macOS-only (show file flags); parsed but never read |
| ls | `-W` | `src/ls/main.zig` | macOS-only (show whiteouts); parsed but never read |
| ls | `-@` | `src/ls/main.zig` | macOS-only (show xattrs); parsed but never read |
| ls | `-%` | `src/ls/main.zig` | macOS-only (SIP info); parsed but never read |
| ls | `-y` | `src/ls/main.zig` | macOS-only tie-breaker for `-t`; field never transferred to LsOptions |
| mktemp | `-t` | `src/mktemp.zig` | Wrong semantics: should place template in `$TMPDIR` with prefix, but uses incorrect path logic |
| mv | `-i` | `src/mv.zig` | Interactive prompt never shown on Linux (dead branch) |
| nl | `-b p:RE` | `src/nl.zig` | Pattern-match body numbering: pBRE (POSIX Basic RE) is unimplemented |
| printf | `\NNN` | `src/printf.zig` | Octal escape in format string not recognized |
| printf | `\c` | `src/printf.zig` | `\c` in format string (halt output) not handled |
| printf | `%F` | `src/printf.zig` | `%F` (uppercase float) not implemented |
| printf | `%a` | `src/printf.zig` | Hex float not implemented |
| printf | `%A` | `src/printf.zig` | Uppercase hex float not implemented |
| readlink | `-f` | `src/readlink.zig` | Requires ALL path components to exist; GNU only requires all but last |
| rm | `-W` | `src/rm.zig` | Supposed to undelete (whiteout files); instead deletes regular files |
| seq | `-f` | `src/seq.zig` | Format string parsed; prefix/suffix text dropped, width/precision ignored |
| sleep | `inf`/`infinity` | `src/common/time.zig` | GNU accepts these for indefinite sleep; vibeutils rejects as invalid |
| sort | `-V` | `src/sort.zig` | Mapped to `--version` instead of version-sort |
| sort | `-h` | `src/sort.zig` | Human-numeric sort uses wrong algorithm |
| sort | `-s` | `src/sort.zig` | Stable sort is a no-op; last-resort comparison missing |
| stat | `%r` | `src/stat.zig` | Raw device type: field not implemented |
| stat | `%R` | `src/stat.zig` | Raw device type (hex): field not implemented |
| stat | `-f` + `-c` | `src/stat.zig` | `-f` (filesystem mode) ignores `-c`/`--format` custom format |
| tac | `-b`/`--before` | `src/tac.zig` | Separator placement algorithm is wrong |
| tee | `-p` | `src/tee.zig` | Parsed; pipe-exit semantics not correctly implemented |
| timeout | setpgid | `src/timeout.zig` | `setpgid` called after spawn (race condition); child may not be in own group when killed |
| touch | `-A` | `src/touch.zig` | Completely unimplemented; exits with "unimplemented" error |
| touch | `-h` | `src/touch.zig` | `-h --no-create` semantics: does not skip missing symlinks correctly |
| tr | `[c*]` | `src/tr.zig` | Fill-to-SET1-length form produces empty set instead of repeating character |
| tr | `[c*0]` | `src/tr.zig` | Same as `[c*]` — POSIX synonym for fill also broken |
| uniq | `--all-repeated=METHOD` | `src/uniq.zig` | With `=none`/`=prepend`/`=separate` suffix causes argparse to crash with stack trace |
| wc | `-c`/`-m` | `src/wc.zig` | Mutual exclusion logic inverted: when both given, wrong one wins |
| wc | `-L` | `src/wc.zig` | Counts raw bytes not display columns (tabs and CJK wrong) |
