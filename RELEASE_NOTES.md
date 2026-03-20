# Release Notes

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
