# Release Notes

## 0.9.0 — 2026-04-05

### Architecture
- Extract `common/main.zig` with `utilityMain` wrapper—
  41 utilities migrated, eliminating ~1,200 lines of
  duplicated allocator/buffer/exit boilerplate
- Extract `common/argparse.parseOrExit`—24 utilities
  now use standardized argument parsing error handling
- Extract `common/mode.zig`—shared symbolic mode parser
  for chmod and mkdir (was ~400 lines duplicated)
- Migrate 9 utilities from GeneralPurposeAllocator to
  Arena (cp, ln, mkdir, touch, mv, rm, chmod, chown, ls)
- Delete 9 local error-mapping functions, replace 109
  `@errorName` call sites with `posixErrorString`
- Net reduction: ~1,243 lines

### Bug Fixes
- mv: no longer panics moving directory into itself
- uniq: --all-repeated=METHOD no longer crashes
- ln: --backup=CONTROL no longer panics
- head: reading a directory prints error instead of
  crashing with stack trace
- chmod: umask now applied when no who-specifier given
  (e.g., `chmod +x` respects umask per POSIX)
- chmod: `-x` no longer parsed as a flag
- readlink -f: allows missing last path component
- realpath: default mode matches GNU all-but-last-exist
- path.zig: `..` past root properly clamped (security)
- Exit code 2→1 for value errors in sleep, date, dd,
  printf (reserved 2 for flag-syntax errors only)
- cp, mv: respect SIMPLE_BACKUP_SUFFIX env var
- promptYesNo: returns false when stdin is not a TTY

### Common Library
- `posixErrorString`: 32 POSIX error mappings (was 15)
- `printTryHelp`: GNU-style "Try --help" hint
- `canonicalizeMissing`: path resolution where last
  component may not exist
- `parseOrExit`: unified argparse error handling

### Tests
- 64 new behavioral tests for common modules
- Path canonicalization security tests
- Permission/ownership bug regression tests

## 0.8.4 — 2026-03-31

IMPORTANT findings remediation. ~120 additional bugs
fixed across 35 utilities, plus full integration test
coverage verified on both Linux and macOS.

### Correctness Fixes

**File operations:**
- cp: -f preserves hard links (only unlinks non-writable),
  -p preserves ownership via fchown, -N no longer affects
  symlink mode, overwrite hint gated on isatty(stderr)
- chown: user: sets login group via getpwuid, -RP uses
  lstat for command-line symlinks
- chmod: -R -P skips symlinks during traversal
- ln: -si deletes before relink, -sb reads
  SIMPLE_BACKUP_SUFFIX env, -svr shows relative path,
  -F requires -s
- mv: same-file hardlink unlinks source correctly
- touch: -h implies -c (no create)
- mktemp: implicit suffix support (myapp.XXXXXXtxt)
- rmdir: -v prints before delete attempt
- mkdir: symbolic mode parsing (u+rwx etc.), -pm
  applies mode to leaf only

**Text processing:**
- grep: -x BRE alternation works cross-platform, -wo
  trims boundary chars consistently, -w uses post-match
  boundary validation on macOS
- cat: -E emits ^M$ for CRLF lines
- head: --silent alias, -n -NUM negative suffix
- wc: -L tab expansion (8-col stops), -c/-m both shown,
  CJK display width
- nl: footer counter reset, blank join indentation
- printf: %d warns on non-numeric, negative * width
- seq: -f prefix/suffix/width/precision, negative
  increment without --, nan rejected
- cut: whitespace range separators
- tr: extra operand exit code matches GNU
- tee: always reports write errors, -p pipe exit
  semantics, POSIX error strings with filenames
- tac: -b separator placement (both byte and string)

**System utilities:**
- find: -perm prefix forms (-644, /111), -printf format
  specifiers, -s sorted traversal, -exec/-execdir {} +
  batch mode, -regex/-iregex via C POSIX regex, birth
  time predicates via statx()
- ls: -n implies -l, -sl per-entry blocks, multi-operand
  headers, POSIX error strings
- stat: Linux StatFs struct fixed, GNU Device format,
  timestamp formatting
- df: -P POSIX headers (1024-blocks, Capacity), -I
  boolean on macOS, -n rejected on Linux
- du: -L dedup, -A excludes dir metadata, -S direct
  file sum
- dd: conv=swab preserves odd byte, sync+block pads
  spaces, EBCDIC/IBM tables corrected
- env: -0+utility rejected, flags stop after NAME=VALUE,
  -P restricts search path
- free: -w shows buffers, -c requires -s, -s flag fixed
- id: -z requires format flag, -a is no-op
- sleep: accepts inf/infinity, error includes token
- yes: exit 1 for errors, includes flag name
- timeout: --kill-after returns child exit code
- realpath: POSIX error strings
- tail: 64MB cap + dynamic buffer for large -c stdin

### Infrastructure

- ~400 new integration + unit tests
- Full cross-platform verification (Linux + macOS)
- All tests pass on both platforms
- Add job timeouts to all CI workflows
- Update CI actions and add concurrency groups
- Add commit signing rules to CLAUDE.md

## 0.8.3 — 2026-03-29

Full correctness audit and remediation. 78 CRITICAL bugs
fixed across 26 utilities, verified against GNU coreutils
9.10 on both Linux and macOS.

### Correctness Fixes (78 CRITICAL)

**Crashes and safety:**
- mv: no longer panics on move-into-subdirectory (EINVAL)
- head: clean error on directory instead of stack trace
- rm: -W no longer deletes files (was destroying data)
- uniq: --all-repeated=METHOD no longer crashes
- ln: --backup=CONTROL no longer panics
- timeout: fix setpgid race that dropped signals

**Wrong behavior fixed:**
- basename: empty string returns "" per GNU (was ".")
- chmod: mode strings starting with - parsed correctly
- readlink: -f allows missing last component per GNU
- realpath: default mode allows missing last component
- mv: -i now prompts on Linux; last-flag-wins for -f/-i/-n
- ln: -h/-n no-dereference now applied to symlink targets
- tr: [c*] fill-to-SET1-length implemented
- env: bare - clears environment; -S string splitting
- touch: -d timezone offsets (Z, +HH:MM) now parsed
- sort: -V does version-sort (was mapped to --version)
- sort: -h uses suffix rank (K<M<G not raw bytes)
- sort: -s omission triggers full-line tiebreaker
- grep: -x works in BRE mode (was using ERE syntax)
- grep: -o prints all matches per line (was first only)
- nl: section delimiter resets on all transitions
- nl: unnumbered lines use spaces per GNU (not separator)
- nl: -b p:REGEX body numbering implemented
- nl: -d '' (empty delimiter) accepted
- printf: \NNN octal escapes in format string
- printf: %b \0NNN off-by-one fixed
- printf: \c halts output; %b \c halts reuse loop
- printf: %F, %a, %A format specifiers implemented
- date: -r accepts numeric epoch seconds
- date: -d parses timezone offsets in ISO 8601
- ls: exit code 2 on errors (was always 0)
- ls: -a includes . and .. entries
- stat: no spurious + on numeric fields
- stat: -f honors -c format string
- stat: terse output has 16 GNU-compatible fields
- df: -P uses POSIX headers (1024-blocks, Capacity)
- df: -n rejected on Linux per GNU
- du: -L dedup guard covers symlink targets
- du: -A excludes directory metadata
- du: -S shows direct file sum (not inode blocks)
- find: -size uses ceiling division for block rounding
- id: -G with named user shows supplementary groups
- tac: -b separator placement algorithm rewritten
- timeout: command-not-found exits 127

**Test infrastructure:**
- 293 new tests encoding correct GNU coreutils behavior
- Strict red-green TDD: every fix has a corresponding
  test that fails without it

### Documentation

- CLAUDE.md: spec reference hierarchy (GNU primary,
  macOS/OpenBSD for their exclusive flags, flag matrices
  authoritative)
- DESIGN_PHILOSOPHY.md: matching spec hierarchy and
  per-utility exceptions (stat, test)
- 141 audit reports in docs/audit/ covering all 47
  utilities (code, unit tests, integration tests)
- docs/audit/summary.md: per-utility finding breakdown
- docs/audit/remediation-plan.md: prioritized fix list
- docs/audit/stub-report.md: all stub flags cataloged

## 0.8.2 — 2026-03-28

### Features
- tail: implement -f (follow) using kqueue on macOS and
  inotify on Linux for event-driven file watching
- tail: implement -F (follow with retry) with file rotation
  detection and wait-for-file on initially missing files
- tail: truncation detection with stderr warning

### Docs
- Fix stale I/O examples: .writer() → .writerStreaming(),
  4096 → 8192 buffers (drifted after issue #5 fix and
  buffer standardization)
- Add behavioral testing and GNU conformance rules to
  CLAUDE.md

## 0.8.1 — 2026-03-27

### Infrastructure
- Fix Homebrew formula: switch to source archive URL with
  pre-built ARM64 bottle
- Build matrix uses native runners per platform instead of
  cross-compiling on ubuntu-latest

## 0.8.0 — 2026-03-20

Full POSIX flag compliance, massive bug sweep, and 7 new
shared common modules. All 47 utilities pass smoke tests
