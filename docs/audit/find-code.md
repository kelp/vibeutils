# Code Audit: find

**Date**: 2026-03-28
**Source**: src/find.zig
**Specs**: find-posix.txt, find-gnu.txt, find-macos.txt

## Executive Summary

PASS WITH ISSUES

The core find functionality (path traversal, -name, -type,
-exec, -print, -delete, operators) is implemented correctly
and produces output matching the system find for common
usage. However, ten flags declared "yes" in the coverage
matrix are stubs that silently return wrong results, three
flags accepted in only the wrong position, and several
correctness bugs affect -perm, -size semantics, -ok/-okdir
prompt format, and time-rounding for -mtime/-atime/-ctime.

---

## Flag-by-Flag Compliance

| Flag | Tier | Parsed? | Implemented? | Correct? | Notes |
|------|------|---------|-------------|----------|-------|
| -H | MUST | yes | yes | yes | |
| -L | MUST | yes | yes | yes | |
| -P | SHOULD | yes | yes | yes | no-op; correct (default) |
| -E | SHOULD | yes | NO | NO | accepted as no-op stub |
| -X | MUST | yes | yes | yes | checks basename only |
| -d | MUST | yes | yes | yes | |
| -f | MUST | yes | yes | yes | |
| -s | SHOULD | yes | NO | NO | accepted as no-op; traversal order unchanged |
| -x | MUST | yes | yes | yes | |
| -name | MUST | yes | yes | yes | |
| -iname | MUST | yes | yes | yes | |
| -path/-wholename | MUST | yes | yes | yes | |
| -ipath/-iwholename | SHOULD | yes | yes | yes | |
| -type | MUST | yes | yes | yes | |
| -size | MUST | yes | PARTIAL | NO | block-unit rounding wrong; T/P units missing |
| -empty | MUST | yes | yes | yes | |
| -newer | MUST | yes | yes | yes | |
| -anewer | MUST | yes | yes | yes | uses atime of current, mtime of ref |
| -cnewer | MUST | yes | yes | yes | uses ctime of current, mtime of ref |
| -mtime | MUST | yes | PARTIAL | NO | time-unit suffix not supported; truncates instead of rounds up |
| -atime | MUST | yes | PARTIAL | NO | same rounding issue |
| -ctime | MUST | yes | PARTIAL | NO | same rounding issue |
| -mmin | MUST | yes | PARTIAL | NO | truncates instead of rounds up |
| -amin | MUST | yes | PARTIAL | NO | same |
| -cmin | MUST | yes | PARTIAL | NO | same |
| -perm | MUST | yes | PARTIAL | NO | + and - prefix rejected; symbolic mode rejected |
| -user | MUST | yes | yes | yes | |
| -group | MUST | yes | yes | yes | |
| -nouser | MUST | yes | yes | yes | |
| -nogroup | MUST | yes | yes | yes | |
| -links | MUST | yes | yes | yes | |
| -inum | MUST | yes | yes | yes | |
| -exec ; | MUST | yes | yes | yes | |
| -exec + | MUST | NO | NO | NO | + form rejected as missing argument |
| -execdir ; | MUST | yes | yes | yes | |
| -execdir + | MUST | NO | NO | NO | + form rejected as missing argument |
| -ok | MUST | yes | PARTIAL | NO | always denies; wrong prompt format |
| -okdir | SHOULD | yes | PARTIAL | NO | always denies; wrong prompt format |
| -print | MUST | yes | yes | yes | |
| -print0 | MUST | yes | yes | yes | |
| -ls | MUST | yes | yes | yes | |
| -delete | MUST | yes | PARTIAL | NO | no -L incompatibility check; no path-with-/ security check |
| -prune | MUST | yes | yes | yes | |
| -depth | MUST | yes | yes | yes | |
| -depth N | SHOULD | yes | yes | yes | |
| -maxdepth | MUST | yes | yes | yes | |
| -mindepth | MUST | yes | yes | yes | |
| -xdev/-mount | MUST | yes | yes | yes | |
| -fstype | MUST | yes | PARTIAL | NO | always returns false on Linux; no pseudo-types on macOS |
| -flags | MUST | yes | PARTIAL | NO | +/- prefix semantics not implemented |
| -follow | MUST | yes | PARTIAL | NO | only recognized before paths, not in expression position |
| -regex | SHOULD | yes | NO | NO | stub returns false (silently matches nothing) |
| -iregex | SHOULD | yes | NO | NO | stub returns false |
| -Bmin | SHOULD | yes | NO | NO | stub returns true (silently matches everything) |
| -Bnewer | SHOULD | yes | NO | NO | stub returns true |
| -Btime | SHOULD | yes | NO | NO | stub returns true |
| -acl | SHOULD | yes | PARTIAL | partial | stub returns false; acceptable on Linux |
| -newerXY | SHOULD | yes | NO | NO | stub returns true |
| -sparse | SHOULD | yes | PARTIAL | partial | stub returns false |
| -xattr | SHOULD | yes | PARTIAL | partial | stub returns false; acceptable on Linux |
| -xattrname | SHOULD | yes | PARTIAL | partial | stub returns false |
| -gid | SHOULD | yes | PARTIAL | NO | rejects names; macOS spec allows names |
| -uid | SHOULD | yes | PARTIAL | NO | rejects names; macOS spec allows names |
| -samefile | SHOULD | yes | yes | yes | |
| -lname | SHOULD | yes | yes | yes | |
| -ilname | SHOULD | yes | yes | yes | |
| -mnewer | SHOULD | yes | yes | yes | alias for -newer |
| -quit | SHOULD | yes | yes | yes | calls process.exit(0) |
| -noleaf | SHOULD | yes | yes | yes | correct no-op |
| -ignore_readdir_race | SHOULD | yes | yes | yes | correct no-op |
| -noignore_readdir_race | SHOULD | yes | yes | yes | correct no-op |
| -printf | SHOULD | yes | NO | NO | stub prints path+newline, ignores format string |
| ( ) | MUST | yes | yes | yes | |
| ! / -not | MUST | yes | yes | yes | |
| -a / -and | MUST | yes | yes | yes | |
| -o / -or | MUST | yes | yes | yes | |
| -true | SHOULD | yes | yes | yes | |
| -false | SHOULD | yes | yes | yes | |

---

### Stubs Found

**Stubs that silently return wrong boolean results (CRITICAL):**

1. **-regex** — `regex_stub` defined at line 147, evaluated
   at line 1584. Always returns `false`. A pattern like
   `find . -regex ".*"` silently matches nothing instead of
   matching everything.

2. **-iregex** — `iregex_stub` at line 148, evaluated at
   line 1584 alongside regex_stub. Same always-false problem.

3. **-Bmin** — `bmin_stub` at line 152, evaluated at line
   1585. Always returns `true`. `-Bmin +999999` matches
   every file regardless of birth time.

4. **-Bnewer** — `bnewer_stub` at line 153, evaluated at
   line 1585. Always returns `true`.

5. **-Btime** — `btime_stub` at line 154, evaluated at line
   1585. Always returns `true`.

6. **-newerXY** — `newerxy_stub` at line 159, evaluated at
   line 1586. Always returns `true`. Any `-newer??` variant
   matches every file.

7. **-printf** — `printf_action` at line 164, evaluated at
   lines 1618–1623. Ignores the format string entirely and
   prints `path\n` instead. Example: `-printf "%f\n"` prints
   the full path, not just the filename.

8. **-s** — Accepted as a no-op at line 448 in parseArgs.
   The traversal order is unchanged, violating the macOS
   spec requirement for lexicographical (alphabetical)
   ordering within each directory.

9. **-E** — Accepted as no-op at line 444. The flag must
   switch -regex/-iregex from basic to extended regex
   semantics. Since -regex is itself a stub this compounds
   to a no-op.

10. **-okdir** — `okdir_stub` evaluated at lines 1608–1611.
    Prints `< ? ... >` to stderr and always returns false
    without prompting or executing. The comment says "stub:
    always false" even though a real implementation must
    prompt the user.

---

### Incorrect Behavior

**I1 — -perm rejects + and - prefix modes**
Location: `src/find.zig:294` (parsePerm)

Problem: `parsePerm` only accepts plain octal strings (no
leading `+` or `-`). The macOS spec requires:
- `-perm -mode`: true if **at least** the mode bits are set
- `-perm +mode`: true if **any** mode bits are set
- `-perm mode`: exact match

Reproduce:
```
./find . -perm -644   # "invalid mode '-644'"
./find . -perm +111   # "invalid mode '+111'"
```
System find accepts both forms.

**I2 — -perm rejects symbolic modes**
Location: `src/find.zig:294`

Problem: `parsePerm` only parses octal digits. The spec
says "mode may be either symbolic (see chmod(1)) or an
octal number". `find . -perm u=rw` returns an error.

Reproduce:
```
./find . -perm u=rw   # "invalid mode 'u=rw'"
```

**I3 — -size block-unit semantics wrong**
Location: `src/find.zig:1417–1425`

Problem: For block units (default, no suffix), the spec
says "rounded up, in 512-byte blocks". The code compares
`stat.size` bytes directly against `N * 512`. A 600-byte
file should match `-size 2` (ceil(600/512) = 2 blocks) but
the code computes `600 == 1024`, which is false. The system
find correctly matches it.

Reproduce:
```
dd if=/dev/zero of=/tmp/t600 bs=1 count=600
find /tmp -name t600 -size 2     # matches
./find /tmp -name t600 -size 2   # no match
```

The macOS spec also adds `T` (terabytes) and `P` (petabytes)
as size suffixes. The implementation supports only
`c w b k M G`. Attempting `-size 1T` returns an error.

**I4 — -mtime/-atime/-ctime truncates instead of rounding up**
Location: `src/find.zig:1440, 1457, 1468`

Problem: The spec says "rounded up to the next full 24-hour
period". The code uses `@divTrunc(age_secs, 86400)` which
truncates. A file modified 25 hours ago has age_secs=90000.
The spec rounds up: 2 periods. The code truncates: 1 period.
This affects the "exactly N" case: a file from 25 hours ago
should NOT match `-mtime 1` but will with the truncation.

Same issue at lines 1488, 1508, 1519 for -mmin/-amin/-cmin
(truncates to minutes instead of rounding up to next full
minute).

**I5 — -mtime/-atime/-ctime: time-unit suffixes not supported**
Location: `src/find.zig:266` (parseMtime)

Problem: The macOS spec documents `-mtime n[smhdw]` with
optional unit suffixes (s=second, m=minute, h=hour, d=day,
w=week) and combination support like `-atime -1h30m`.
`parseMtime` only accepts a plain integer. `-mtime -1h`
returns an error.

**I6 — -exec and -execdir do not support {} + batch form**
Location: `src/find.zig:855–879`, `1059–1083`

Problem: Both `-exec cmd {} +` and `-execdir cmd {} +` are
required by POSIX and supported by macOS. The parser only
recognizes `;` as a terminator. When it encounters `+` as a
terminator it runs past it and reports "missing argument to
'-exec'".

Reproduce:
```
./find . -exec echo {} +   # "missing argument to '-exec'"
find . -exec echo {} +     # works, batches paths
```

**I7 — -ok always denies with wrong prompt format**
Location: `src/find.zig:1768–1778`

Problem: `-ok` is supposed to open `/dev/tty`, print the
prompt `< cmd ... path > ?`, read a response, and execute
if affirmative. The implementation always prints `< ? ... >`
and returns false without reading any response. The format
doesn't include the command or path. A correct prompt for
`find . -ok rm {} \;` matching `./foo` would be:
`< rm ... ./foo > ?`.

**I8 — -follow only recognized as global option, not as expression primary**
Location: `src/find.zig:435`

Problem: The macOS man page lists `-follow` under PRIMARIES
as a deprecated expression. The implementation recognizes it
only in the global option scan (before any expressions). If
it appears after another primary it triggers "unknown
predicate '-follow'".

Reproduce:
```
./find . -maxdepth 1 -follow   # "unknown predicate '-follow'"
/usr/bin/find . -maxdepth 1 -follow   # works
```

**I9 — -delete does not check for -L incompatibility**
Location: `src/find.zig:560–563`

Problem: The macOS man page states "Following symlinks is
incompatible with this option". When `-L` and `-delete` are
combined the implementation silently proceeds. It should
error out.

**I10 — -gid and -uid reject non-numeric arguments**
Location: `src/find.zig:1194`, `1340`

Problem: macOS spec says `-gid gname` is "the same thing as
`-group gname` for compatibility" and `-uid uname` is "same
as `-user uname`". Both should accept names in addition to
numeric IDs. The implementation calls `parseInt` and rejects
any non-numeric value.

Reproduce:
```
./find . -gid tcole   # "invalid argument 'tcole' to '-gid'"
./find . -uid tcole   # "invalid argument 'tcole' to '-uid'"
```

**I11 — -flags: +/- prefix semantics not implemented**
Location: `src/find.zig:1972–1995`

Problem: The macOS spec defines three match modes for
`-flags`:
- exact match (no prefix)
- `-flags` (dash prefix): at least all specified bits set
- `+flags` (plus prefix): any specified bit set

`matchFlagsDarwin` doesn't check for or handle a leading
`-` or `+` on the `flag_str` argument. All calls use
"at least all" semantics unconditionally.

**I12 — -fstype always returns false on Linux**
Location: `src/find.zig:1955–1961`

Problem: `matchFstypeLinux` is a no-op stub returning
`false`. The system find on Linux reads `/proc/mounts` or
uses `statfs`. The implementation silently matches nothing.
The macOS implementation also lacks `local` and `rdonly`
pseudo-type support.

---

## Core Behavior Issues

**B1 — Exit code for parse errors should be 2 (misuse), not 1**
Location: `src/find.zig:2172–2173`

All parse failures return `general_error` (1). Standard
coreutils use exit code 2 for usage/argument errors and 1
for runtime errors. The `common.ExitCode.misuse` (2) value
exists but is not used.

Reproduce:
```
./find . -badopt; echo $?   # prints 1
find . -badopt; echo $?     # prints 1 (GNU also uses 1 here)
```
Note: GNU find also uses 1 for bad predicates so this may
be a low priority. POSIX specifies exit >0 for errors.

---

## I/O Issues

No I/O issues found. The implementation correctly:
- Uses `.writerStreaming()` for stdout and stderr (lines
  2200–2207)
- Uses 8192-byte buffers
- Flushes both before exit (lines 2210–2211)
- Sends errors to stderr, output to stdout

---

## Dynamic Verification

Commands run and results compared:

| Command | vibeutils | system | Match? |
|---------|-----------|--------|--------|
| `find /tmp/t` | correct list | same | yes |
| `find /tmp/t -name "*.txt"` | correct | same | yes |
| `find /tmp/t -type f` | correct | same | yes |
| `find /tmp/t -maxdepth 1` | correct | same | yes |
| `find /tmp/t -mtime -1` | correct | same | yes |
| `find /tmp/t -perm -644` | error | matches | NO |
| `find /tmp/t -perm u=rw` | error | matches | NO |
| `find /tmp/t -size 2` (600B file) | no match | matches | NO |
| `find /tmp/t -regex ".*"` | no output | full list | NO |
| `find /tmp/t -Bmin -60` | all files | error (GNU) | N/A |
| `find /tmp/t -newerma ref` | all files | empty | NO |
| `find /tmp/t -exec echo {} +` | error | works | NO |
| `find /tmp/t -s` (unsorted dir) | unsorted | N/A | FAIL |
| `find -f /tmp/t -name "*.txt"` | correct | same | yes |
| `find /tmp/t -d` (depth-first) | correct | same | yes |
| `find /tmp/nonexistent` | error+exit 1 | same | yes |
| `find /tmp/t -badopt` | error+exit 1 | same | yes |
| `find /tmp/t -X` (xargs-safe) | warns+skips | error (GNU) | N/A |
| `find /tmp/t -printf "%f\n"` | full paths | filenames | NO |

---

## Findings

| ID | Severity | Category | Description |
|----|----------|----------|-------------|
| C1 | CRITICAL | stub | -regex/-iregex: parsed but silently return false |
| C2 | CRITICAL | stub | -Bmin/-Bnewer/-Btime: parsed but silently return true |
| C3 | CRITICAL | stub | -newerXY: parsed but silently returns true |
| C4 | CRITICAL | stub | -printf: ignores format string, prints full path |
| C5 | CRITICAL | stub | -s: no-op; traversal order not sorted |
| C6 | CRITICAL | incorrect | -perm: rejects +mode and -mode prefix forms |
| C7 | CRITICAL | incorrect | -perm: rejects symbolic modes (u=rw etc) |
| C8 | CRITICAL | incorrect | -size: wrong block-unit rounding semantics |
| C9 | CRITICAL | missing | -exec/execdir {} + batch form not implemented |
| H1 | HIGH | incorrect | -mtime/-atime/-ctime: truncates instead of rounding up |
| H2 | HIGH | incorrect | -mmin/-amin/-cmin: truncates instead of rounding up |
| H3 | HIGH | incorrect | -mtime/-atime/-ctime: time-unit suffixes (smhdw) rejected |
| H4 | HIGH | missing | -size: T and P unit suffixes missing (macOS spec) |
| H5 | HIGH | stub | -ok: always denies; wrong prompt format (missing cmd and path) |
| H6 | HIGH | stub | -okdir: always denies; wrong prompt format |
| H7 | HIGH | incorrect | -follow: not recognized in expression position |
| H8 | HIGH | incorrect | -gid: rejects names; macOS spec requires name support |
| H9 | HIGH | incorrect | -uid: rejects names; macOS spec requires name support |
| H10 | HIGH | incorrect | -flags: +/- prefix semantics not implemented |
| H11 | HIGH | stub | -fstype: always false on Linux |
| M1 | MEDIUM | incorrect | -delete: no error when combined with -L |
| M2 | MEDIUM | incorrect | -fstype: no 'local' or 'rdonly' pseudo-type support (macOS) |
| M3 | MEDIUM | stub | -E: no-op; does not affect -regex regex dialect |
| L1 | LOW | exit-code | Parse errors exit 1 instead of 2 (misuse) |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -exec/execdir {} + batch form not implemented — find.zig:855,1059
2. [CRITICAL] -perm: rejects + and - prefix forms — find.zig:294
3. [CRITICAL] -perm: rejects symbolic modes — find.zig:294
4. [CRITICAL] -size: block-unit rounding is wrong — find.zig:1417
5. [CRITICAL] -regex/-iregex stub returns false — find.zig:1584
6. [CRITICAL] -Bmin/-Bnewer/-Btime stub returns true — find.zig:1585
7. [CRITICAL] -newerXY stub returns true — find.zig:1586
8. [CRITICAL] -printf stub ignores format string — find.zig:1618
9. [CRITICAL] -s no-op; traversal not sorted — find.zig:448
10. [HIGH] -mtime/-atime/-ctime/-mmin/-amin/-cmin: truncate instead of round up — find.zig:1440,1457,1468,1488,1508,1519
11. [HIGH] -mtime/-atime/-ctime: time-unit suffixes not parsed — find.zig:266
12. [HIGH] -size: T/P unit suffixes missing — find.zig:239
13. [HIGH] -ok/-okdir: always denies; prompt format wrong — find.zig:1768,1608
14. [HIGH] -follow not recognized in expression position — find.zig:435
15. [HIGH] -gid/-uid: reject names — find.zig:1194,1340
16. [HIGH] -flags: +/- prefix semantics — find.zig:1972
17. [HIGH] -fstype: always false on Linux — find.zig:1955
18. [MEDIUM] -delete: no -L incompatibility check — find.zig:560
19. [MEDIUM] -fstype: no local/rdonly pseudo-types — find.zig:1952
20. [MEDIUM] -E: no-op stub — find.zig:444
```

STATE: REVIEW COMPLETE - NEEDS_FIXES
