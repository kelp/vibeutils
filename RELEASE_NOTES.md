# Release Notes

## Unreleased

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
on macOS and Linux.

### Highlights
- 100% POSIX flag coverage: 288 MUST + 220 SHOULD flags
- ~50 bugs fixed across 8 audit rounds
- Unified DisplayConfig system for color/icon output
- Migrated build system from Makefile to justfile
- Code coverage via kcov integration

### New common modules
- time.zig: C time bindings (localtime_r, strftime, etc.)
- path.zig: canonicalize paths with missing components
- glob.zig: glob matching with bracket expressions
- prompt.zig: interactive yes/no prompts for cp/mv/rm
- format.zig: human-readable sizes (SI/IEC suffixes)
- file_ops.zig: file content copying and same-file detect
- lib.zig: internal stderr color detection

### Bug fixes
- Fix sort multi-file use-after-free in readLines
- Fix timeout exit code for missing operands (now 125)
- Fix sort, timeout, and find integration test failures
- Remove hardcoded isTty, deduplicate common code
- Fix allocator and overflow bugs across utilities

### Infrastructure
- Remove duplicate ubuntu-24.04 CI builds
- Add release notes history (RELEASE_NOTES.md)
- Remove obsolete Makefile (full justfile parity)

## 0.7.3 — 2026-03-07

Fix O_APPEND stdout bug that corrupted output when
multiple utilities wrote to the same file descriptor.

- Fix O_APPEND stdout bug (#5)
- Add regression tests for O_APPEND behavior
- Fix Linux Nix build with multi-platform Cachix CI
- Add strict red-green TDD requirements to CLAUDE.md

## 0.7.2 — 2026-03-05

Colored df output with usage bars, ls git integration
improvements, and Linux Nix build fixes.

- Add colored output, usage bars, and smart grouping
  to df
- Fix ls bugs and convert --git to --git=WHEN
- Enable git status by default in ls for git repos
- Fix Linux Nix build and add multi-platform Cachix CI
- Add screenshots to README

## 0.7.1 — 2026-03-04

Respect VIBEUTILS_STYLE environment variable across
all utilities with color support.

- Respect VIBEUTILS_STYLE in ls, grep, and du

## 0.7.0 — 2026-03-04

Colored help output with nerd-font glyphs, standardized
man pages, and multi-platform release builds.

- Add color and nerd-font glyphs to help output
- Add help text consistency test
- Standardize man pages for consistency and style
- Add VIBEUTILS_STYLE env var and command linter
- Add multi-platform release builds to GitHub Actions
- Fix metavariable detection for trailing punctuation

## 0.6.1 — 2026-03-02

Colorized output across utilities, icon support, and
build tooling improvements.

- Extract shared size colors, add color to du
- Add icon colors and fix ls permission tests
- Add colorized help and enhanced ls display
- Add mandoc lint hook and artifact guard
- Add bash and mandoc to Nix devshell

## 0.6.0 — 2026-02-28

Linux support and cross-platform CI.

- Add Linux support across all utilities
- Add multi-platform CI matrix (macOS + Ubuntu)
- Fix cp fchmod crash on Linux
- Add Nix devshell with actionlint and direnv support
- Remove fuzz test infrastructure

## 0.5.1 — 2026-02-28

Release infrastructure and packaging fixes.

- Add release workflow with prebuilt binaries and Cachix
- Move Homebrew formula to dedicated tap repo
- Add obsolete -NUM syntax to head and tail

## 0.5.0 — 2026-02-27

Initial public release with 47 GNU coreutils
reimplemented in Zig.

**47 utilities:** basename, cat, chmod, chown, cp, cut,
date, dd, df, dirname, du, echo, env, false, find,
free, grep, head, id, ln, ls, mkdir, mktemp, mv, nl,
printf, pwd, readlink, realpath, rm, rmdir, seq, sleep,
sort, stat, tac, tail, tee, test, timeout, touch, tr,
true, uniq, wc, whoami, yes

**Key features:**
- Modern UX: color output, nerd-font icons, progress
  bars
- Terminal adaptation with NO_COLOR support
- Custom argument parser with GNU-style long options
- Comprehensive integration test suite
- GitHub Actions CI/CD with multi-platform builds
- Nix flake and Homebrew packaging
