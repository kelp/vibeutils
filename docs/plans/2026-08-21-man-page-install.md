# Slice: `### Build System` remaining item — man-page install

## Slice name

`### Build System` unchecked box:

- Add install targets for man pages

One heading, one PR. Do not pull `### Color Support` (`LS_COLORS`)
or later headings.

## Predecessor gate (recorded deviation)

The campaign plan lists this after Tiger Style CI, free, tail,
and Shared Components. Those PRs (#185, #182, #183, #184) and
the issue PRs (#171–#181) are still open drafts. This branch
is from `origin/main` (`a41eccd`). Files are disjoint
(`build.zig` / `build/`, `justfile`, `TODO.md`, `CHANGELOG.md`,
a tools test). This environment cannot merge.

## In scope

`zig build` (the default install step) currently copies
binaries to `zig-out/bin/` and does not install `man/man1/*.1`.
Nix copies man pages in `flake.nix` `installPhase` after
`zig build --prefix $out`. A non-Nix `zig build --prefix /usr/local`
therefore ships no man pages.

Add man-page install to the **default** install step:

- Destination: `{prefix}/share/man/man1/<name>.1` (FHS).
- Source: `man/man1/<name>.1` for every entry in
  `build/utils.zig` `utilities` (including `[.1` for the
  `[` utility and `test.1` for `test`).
- Implementation lives in `build/man.zig` (keep `build.zig`
  a thin call). `build.zig` gains one hook, e.g.
  `man.addInstall(b);`. Do **not** rewrite unrelated
  `build.zig` logic. Do not edit `build/utils.zig` metadata
  unless a man-page path field is required; prefer
  `man/man1/{name}.1` by convention.
- `just install` documents that man pages land under
  `zig-out/share/man/man1/` as well as binaries under
  `zig-out/bin/`.
- `just test-man-install` runs the contract tests (same
  pattern as `just test-tiger-check`).
- Wire that recipe into CI: `.github/workflows/test.yml`
  after `just build` (the test job already builds; the
  man-install test needs a Debug `zig build` prefix). Do
  not add a new workflow.
- Leave `flake.nix` `installPhase` `cp` in place this slice
  (idempotent overwrite). Removing it is a follow-up, not
  this heading.

**`build.zig` (recorded 2/3):** CLAUDE.md "don't edit
`build.zig`" is utility registration via `build/utils.zig`.
This heading *is* an install-target change. A one-line
`man.addInstall(b)` hook plus `build/man.zig` is the
exception. GPT asked to revise the architecture contract
instead; declined as out of scope for this slice.

`CHANGELOG.md` Unreleased / Added: `zig build` installs
man pages under `share/man/man1`. User-visible for anyone
who installs from source.

Check the TODO box in the same commit as the install hook.

## Out of scope

- `### Color Support` `LS_COLORS`
- Compressing man pages (`.gz`)
- `mandoc` lint in this PR (docs.yml already has mandoc)
- Windows man-page paths
- Changing man page *content*
- `DESTDIR` / Homebrew bottle scripts (`release.yml` already
  copies `man/man1`)

## Spec impact

None. No flag matrix.

## Tests (failing first, separate test-writer)

No privileged tests. No stdin-filter hangs. Names without `#`.

A shell contract test under `tests/tools/` (same pattern as
`tests/tools/tiger-check_test.sh`, invoked from `justfile`,
not globbed by `test_runner.sh`):

1. `man install puts ls.1 under share/man/man1` — after
   `zig build` (or `zig build --prefix <tmp>`),
   `<prefix>/share/man/man1/ls.1` exists and is non-empty.
2. `man install installs a page per utility` — every
   `utilities` name has `<prefix>/share/man/man1/<name>.1`,
   including `[.1` and `test.1`. Installed count equals
   `man/man1/*.1` count (do not hardcode 48).
3. `man install page is the repo source` — installed
   `ls.1` is byte-identical to `man/man1/ls.1` (no
   mandoc rewrite).

RED: today `zig build` does not create
`zig-out/share/man/man1/ls.1`. Prove that with the test
before adding the install hook.

CI must invoke `just test-man-install` (GPT round-1). A
`just` recipe that CI never calls is a silent skip.

Do not add Zig unit tests inside `src/` (this is build
graph behavior).

## Risks

- **CLAUDE.md "don't edit build.zig":** that rule is for
  registering new utilities in `build/utils.zig`. This
  heading *is* an install-target change; a one-line hook
  plus `build/man.zig` is the minimum. Do not dump the
  install loop inline as a 70+ line block in `build.zig`.
- **`[` man page:** file name `[.1` is legal on Unix. Do
  not skip it.
- **Prefix:** tests must use `--prefix` into a temp dir
  (or inspect `zig-out` after a Debug `zig build`) so they
  never write to `/usr`.
- **macOS / Linux:** install path is the same FHS layout
  Zig uses (`share/man/man1` under prefix).
- Trust the OS: no path-traversal checks on man names.

## Plan review

Three-model review before Zig/build edits.
