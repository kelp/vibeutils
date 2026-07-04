# Changelog

## Unreleased

## v0.12.0 — 2026-07-03

### Added
- **dd accepts the full GNU size-suffix family with byte
  semantics.** `bs=`/`ibs=`/`obs=` and the count-like operands
  now take `B`, decimal `kB`/`MB`/`GB`/`TB`/`PB`/`EB`, and
  binary `K`/`KiB` through `E`/`EiB` suffixes. On
  `count=`/`skip=`/`seek=`, a suffix ending in `B` counts
  exact BYTES rather than blocks (`bs=512 count=1kB` copies
  exactly 1000 bytes; byte-precise skip/seek offsets), matching
  GNU. A zero multiplier such as `count=0x10` now emits GNU's
  `'0x' is a zero multiplier` warning (#65).

### Changed
- **Error messages quote operands exactly as GNU does.** Every
  diagnostic that names a user operand was audited against GNU
  coreutils 9.5: sites in GNU's quoted families (`cannot
  access 'x'`, `cannot open 'x' for reading`, `failed to
  open 'x'`, tail's rotation messages, and others across ls,
  head, tail, dd, tac) now quote the operand with GNU's exact
  wording, while utilities GNU prints bare (cat, wc, uniq,
  grep, sort, tee, realpath, readlink) stay bare with parity
  pinned by tests. tail's `-F` retry message drops the
  invented "waiting for it to appear" suffix to match GNU
  verbatim (#63).

### Fixed
- **mv renders the errno string instead of a raw Zig error name.**
  A failed move (missing source, unremovable source, backup
  failure, and others) printed `error.FileNotFound` and similar
  internal names; every mv diagnostic now maps the error to its
  GNU strerror text (`No such file or directory`).
- **chmod no longer appends a redundant error line for an invalid
  mode.** An invalid numeric mode such as `999` reported `invalid
  mode: '999'` and then a spurious `operation failed:
  InvalidOctalMode` leaking the raw error variant; the redundant
  second line is gone, matching GNU's single diagnostic.
- **chown/chmod `-RL` reach directories aliased by sibling
  symlinks.** The walker's global visited set skipped whichever
  of a directory and a symlink to it was seen second, so the
  real directory's ownership or mode was never changed. Under
  `-L` both paths are now walked, matching the reference tools;
  a symlink loop is serviced as a leaf and the walk continues
  (#60).
- **du `-L` prunes ancestor symlink loops.** A loop such as
  `inner/up -> ..` previously walked to the 1024-depth bound,
  emitting repeated paths; du now reports the cycle once on
  stderr, lists each real directory once, and exits 1, matching
  GNU. Per-path counting of legitimately aliased files is
  preserved (#61).
- **realpath `-s` validates the component preceding `..`.**
  Popping `..` past a missing component now errors `No such
  file or directory`, and past a file (or symlink to one)
  errors `Not a directory`, both exit 1, matching GNU. A
  symlink to a directory is accepted and popped textually;
  `-m -s` still skips the check entirely (#62).
- **grep `-r` exits 2 when the walk hits errors.** An unreadable
  subdirectory (or the walker entry cap) during a recursive
  search now sets exit code 2 like GNU, instead of reporting
  0/1 as if the truncated results were complete. Matching GNU,
  errors dominate a found match unless `-q` is given; under
  `-q` with no match, an error still exits 2 (#58).
- **grep `-r` names the exact unreadable directory.** The walker
  now records the path of a directory it fails to open, and grep
  reports that path directly. The previous rescan heuristic could
  name a readable sibling depending on readdir order.
- **dd names the offending value in operand errors.**
  `dd count=1m` now reports `invalid number: '1m'` in GNU's
  message shape instead of a generic `invalid operand value`;
  the exit code stays 2 per the project-wide misuse convention
  (#64).
- **dd `conv=noerror,sync` counts error-synthesized blocks as
  partial records in.** Blocks NUL-padded after a read error
  (zero bytes actually read) now report as `0+N records in`,
  matching GNU; they were previously counted as full. The
  padded writes still count as full records out (#59).
- **cat reports `Is a directory` for directory operands.**
  Reading a directory leaked Zig's raw `ReadFailed` error name
  (`cat: somedir: ReadFailed`); cat now stats the operand and
  reports `cat: somedir: Is a directory` with exit 1, matching
  GNU. Found by the new quoting-parity tests.

### Infrastructure
- **Walker cycle detection split into modes.** The single
  `detect_cycles` flag became `cycle_mode`: `ancestors` (GNU
  fts semantics — only true ancestor loops are cycles; aliases
  are re-walked; used by du/chown/chmod under `-L`),
  `ancestors_and_visited` (the old global visit-once set; mv
  and rm keep it bit-for-bit), and `none` (cp, grep, find). The
  traversal stack doubles as the ancestor chain, so detection
  adds no allocation and stays bounded by `max_depth`.

## v0.11.0 — 2026-07-02

### Added
- **dd `count=`/`skip=`/`seek=` accept size suffixes and
  `conv=fdatasync` is supported.** The count-like operands now
  honor the same K/M/G suffix grammar as `bs=` (as block-count
  multipliers, matching GNU), and `conv=fdatasync` performs a
  data-only flush before exit (full fsync on non-Linux and when
  combined with `conv=fsync`).

### Fixed
- **dd `conv=fdatasync`/`conv=fsync` report sync failures
  instead of aborting.** Syncing a pipe (for example dd in a
  pipeline) previously crashed with SIGABRT; it now reports
  `fsync failed for 'standard output'` and exits 1, matching
  GNU.
- **realpath/readlink resolve relative paths again with `-s` and
  `-m`.** A Zig 0.16 Threaded-io regression made `cwd().realPath`
  fail on the AT_FDCWD pseudo-fd, so `realpath -s <relative>`,
  `realpath -m <relative>`, and `readlink -m <relative>` reported
  "No such file or directory" for paths that exist. Empty
  operands now also error with exit 1 under `-s`/`-m`, matching
  GNU, instead of resolving to the working directory.
- **The directory walker follows symlinks correctly under
  `follow_all`, fixing `chown -RL` and `du -L` on symlinked
  files.** Every symlink was classified as a directory without
  checking its target, so a symlink-to-file, broken link, or
  loop poisoned the whole walk (chown -RL aborted entire trees).
  The walker now stats targets; du -L also gained diagnostics
  and exit 1 for dangling/looping links, matching GNU.
- **dd `conv=noerror` no longer spins forever on persistent read
  errors.** A failed read never consumed the `count=` budget and
  never advanced the input. Failed reads now count against
  `count=`, dd seeks past bad blocks on seekable inputs, and two
  finite retry bounds terminate cases where GNU dd retries
  without bound (documented in the man page).
- **realpath no longer aborts on relative or empty path inputs.**
  An empty or relative `--relative-to=`/`--relative-base=` value,
  an empty `-e` operand, or a relative `-e` operand tripped a
  std-library assertion and killed the process (SIGABRT, exit
  134). Relative paths now resolve against the working directory
  and empty paths report `No such file or directory` with exit 1,
  matching GNU.
- **grep `-r` and mv now halt cleanly at the walker entry cap.**
  Hitting the 16M-entry safety cap previously re-fired the same
  error on every subsequent iteration, an infinite storm of
  identical diagnostics; the cap is now reported once, the walk
  stops, and the usual error exit status is preserved.
- **grep `-R` now descends symbolic links to directories.**
  Following a directory symlink under `-R` previously did nothing
  (opening the symlink read-only succeeded, so grep treated it as a
  file and never recursed); it now descends and searches the target,
  matching GNU.
- **cp `-p`/`-a` now preserves directory modes and timestamps.**
  Directory permission/mtime preservation was silently dropped
  (`fchmod` on a fresh dir handle failed `EBADF`, swallowed). Modes
  and mtimes are now applied post-order, so even a read-only `0555`
  source directory copies its contents and lands the right mode.
- **cp `-L` no longer runs away on symlink cycles.** A directory
  symlink cycle under `-L` previously recursed to the kernel symlink
  limit, materializing dozens of junk levels; cp now reports
  `cannot copy cyclic symbolic link` and skips it, matching GNU.
- **mv cross-device moves preserve directory mode and mtime and
  continue past errors.** The EXDEV copy fallback no longer breaks
  on a read-only source subdirectory, now carries directory mtimes,
  and reports per-entry errors while continuing with siblings
  instead of aborting; a failed copy never deletes the source.
- **find `-xdev` now emits mount-point entries.** Cross-device
  directories were skipped entirely; they are now reported (without
  descending), matching GNU.
- **find `-L` detects filesystem loops.** A symlink loop under `-L`
  previously walked ~40 junk levels until the kernel symlink limit;
  find now prints `File system loop detected`, skips the loop, and
  continues with siblings.

### Infrastructure
- **Tiger Style Phase 2: bounded directory walker.** All eight
  recursive tree-walkers (chmod, chown, rm, du, grep, cp, mv, find)
  now run on the shared bounded, iterative `common.walker`; no
  direct filesystem-walk recursion remains. Shared per-file copy
  leaves were extracted into `common/file_ops` for cp and mv.
- **Tiger Style CI gate.** A `Tiger Style` workflow runs the
  `tiger-check` scanner tree-wide on every PR and push to `main`,
  failing on any gating violation (oversized function, long line,
  recursion, compound assert, unbounded loop). Available locally as
  `just tiger-check`.
- **Changelog CI gate.** A `Changelog` workflow lints CHANGELOG.md
  structure on every PR and push to `main`: the `## Unreleased`
  heading must be present (except during the release-promotion
  window), every released `## vX.Y.Z` section must be byte-identical
  to its git tag, and no merge-conflict markers may remain. Catches
  clean-but-wrong automerges that file unreleased entries into an
  already-tagged section. Available locally as `just lint-changelog`.
- Add `actionlint` to the project gale deps so `just lint-actions`
  runs everywhere, and fix the three shellcheck findings its first
  run surfaced in `test.yml` and `release.yml` (unquoted `$(nproc)`,
  an unquoted `${VERSION}` glob, a dead `VERSION` assignment). All
  behavior-preserving; the workflow lint is now clean.

## v0.10.3 — 2026-06-29

### Fixed
- **`ls` no longer panics on directories whose device id has the
  high bit set (e.g. `ls /`).** macOS `stat.st_dev` is a signed
  `i32`, and filesystems such as devfs (`/dev`) report an id that
  reads as negative. `statToFileInfo` `@intCast` that value into a
  `u64` field, which trapped with "integer does not fit in
  destination type" and aborted the process. The conversion now
  reinterprets the bits with `@bitCast`.

### Infrastructure
- Make the release workflow's GitHub-release steps idempotent
  so the `release` job can be safely re-run to recover a failed
  downstream step (e.g. the Homebrew tap update) without
  colliding with the already-published, immutable release. The
  draft-cleanup step now only deletes a leftover *draft*, and
  create/publish is skipped when the release already exists.
- On a release recovery re-run, derive the Homebrew bottle
  sha256 from the already-published bottle asset rather than a
  freshly rebuilt one. The bottle tarball is not byte-
  reproducible, so a rebuilt bottle's hash would not match the
  immutable asset users download, breaking `brew install`.
- Opt JS-based actions into Node 24 with
  `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`, the variable GitHub
  honors for the Node 20 to 24 cutover, replacing the
  ineffective `ACTIONS_RUNNER_FORCE_ACTIONS_NODE_VERSION` and
  silencing the `setup-zig` Node 20 deprecation warning.

## v0.10.2 — 2026-06-15

### Removed
- **Dropped the `darwin-amd64` (Intel macOS) prebuilt binary.**
  Builds and CI now target macOS 26 (Tahoe), which is Apple
  Silicon only, so the release no longer ships an x86_64 macOS
  tarball and Homebrew bottles are tagged `arm64_tahoe` instead
  of `arm64_sequoia`. Intel Mac users can still build from
  source. CI (`test.yml`/`integration.yml`) and the release
  build all run on `macos-26`, plus Linux x86_64 and arm64.

### Fixed
- Stop `ls` from printing a false "git command not found in
  PATH" warning (#41). `findGitRoot` now resolves relative start
  paths through `std.process.currentPath` instead of
  `realPath` on the cwd handle, so it locates the repository
  root from a subdirectory. Git status now degrades silently
  when no repository is found; a warning prints only on a real
  initialization error (e.g. out of memory) under
  `--git=always`. Re-enabled `src/common/git.zig`'s unit tests
  in the build, which had been silently excluded.

## v0.10.1 — 2026-05-28

### Fixed
- **macOS build broken on the macOS 26 SDK (#40).** `free`
  imported the mach headers via `@cImport`, but Zig 0.16's
  translate-c cannot size the `mach_msg_*_descriptor_t`
  bitfield/union types in the 26.x SDK, failing the build
  with "struct changed size unexpectedly". Replaced the mach
  `@cImport` with hand-written `extern` declarations for the
  few calls `free` needs (`host_statistics64`,
  `mach_host_self`, `vm_statistics64_data_t`). These track
  the stable kernel ABI and are immune to SDK header churn.

## v0.10.0 — 2026-05-26

### Infrastructure
- **Migrate to Zig 0.16.0.** All 47 utilities and the shared
  common library are ported off 0.15.x's pre-Writergate APIs.
  `main` now receives `std.process.Init`; every utility runs
  through `common.utilityMain` with the new `runFn` signature
  (`*std.Io.Writer` for stdout/stderr, explicit `io: std.Io`).
  Toolchain pins (gale, flake, CI) and `build.zig.zon`'s
  `minimum_zig_version` all bumped to `0.16.0`. Build infra
  ported off `linkLibC()` and `addRemoveDirTree`. Contributor
  docs, Docker version defaults, and `.claude/` skills updated
  to reflect the 0.16-only state (CLAUDE.md, ZIG_PATTERNS.md,
  ZIG_BREAKING_CHANGES.md, TESTING_STRATEGY.md, AGENTS.md,
  zig-patterns and zig-check skills).
- **Add Tiger Style coding guidance** to CLAUDE.md — paired
  assertions, bounded loops, static-after-init memory,
  snake_case naming with unit suffixes, 70-line function
  limit, 100-column line limit. Advisory for new code and
  refactors; not retroactively enforced.
- **Pin integration tests to `zig-out/bin` via PATH.**
  `tests/integration.sh` now prepends the freshly-built
  binary directory to `PATH` so unqualified utility names
  in test scripts (e.g. `head -n 1` in `yes_test.sh`)
  resolve to the current build rather than whatever
  vibeutils is installed system-wide. Reproduced as
  `yes large string (9000 chars)` failing locally when the
  installed `head` predated the `streamOneLine`
  `StreamTooLong` fix.
- **Pre-empt GitHub Actions Node 24 cutover (June 2, 2026).**
  All workflows now set
  `ACTIONS_RUNNER_FORCE_ACTIONS_NODE_VERSION: node24` at the
  workflow level so JS-based actions (`setup-zig`,
  `setup-just`, `install-nix-action`, etc.) run on Node 24
  ahead of the forced runtime upgrade. Validates ahead of
  time that our action set is Node-24-compatible, since the
  pinned `mlugg/setup-zig@v2.2.1` still declares
  `using: 'node20'` in its `action.yml`.
- **Tighten GitHub Actions allowlist** (`gh api PUT
  repos/kelp/vibeutils/actions/permissions/selected-actions`).
  Replaced wildcard third-party patterns
  (`extractions/setup-just@*`, `cachix/cachix-action@*`,
  `cachix/install-nix-action@*`, `mlugg/setup-zig@*`) with
  the specific commit SHAs the workflows pin to. Added the
  transitive `extractions/setup-crate@0551596…` (pulled in by
  `setup-just`) — its absence had been failing every CI run
  on `main` since 2026-05-23. Flipped `verified_allowed` from
  `true` to `false`; current workflows don't rely on it and
  removing it prevents drift.

### Security
- **mktemp: enforce `0o600` on created files.** Zig 0.16's
  `createFile` defaults to `0o666`; POSIX requires temp
  files to be created mode `0o600` so other users on the
  system can't read them. `mktemp` now passes the explicit
  mode. Regression introduced during the 0.16 migration.

### Bug Fixes
- **head: streams lines longer than the read buffer.**
  `takeDelimiterInclusive` returns `error.StreamTooLong`
  when a line doesn't fit in head's 8 KB read buffer; the
  previous catch only handled `EndOfStream`, so e.g.
  `yes <9KB-str> | head -n 1` exited with `StreamTooLong`
  and zero output. `streamOneLine` now drains the buffered
  prefix and keeps refilling until the delimiter is found.
  Regression introduced during the 0.16 migration.
- **ls: memory leak in git status integration.** When
  `git status --porcelain` reported the same filename twice
  (e.g. `D  foo` plus `?? foo` for a staged-deleted-and-recreated
  file), `refreshStatus` allocated a fresh key for the second
  line that `HashMap.put` silently dropped — leaking one
  allocation per duplicate. Reproduced as `error(gpa): memory
  address … leaked` after `ls --icons=always --git=always` in
  repos with such states.

## v0.9.3 — 2026-04-15

### Infrastructure
- Switch project environment from Nix flake to Gale
- Drop `--ignored` from `git status --porcelain` in ls git
  integration

## v0.9.2 — 2026-04-06

Patch release. Fixes a memory safety bug in mktemp, consolidates
the symbolic mode parser, and adds POSIX umask support for
implicit-who symbolic mode clauses.

### Bug Fixes
- **mktemp: undefined memory beyond 256 X's.** `fillRandom` used
  a fixed 256-byte getrandom buffer and silently left template
  positions past 256 as uninitialized stack memory. Templates like
  `myapp.XXXX...` (300+ X's) produced garbage bytes in the output
  filename. Now uses chunked getrandom calls to fill any length.
- **mkdir: umask for implicit-who symbolic modes.** `mkdir -m =rw`
  with umask 022 produced 666 (umask ignored). GNU applies umask
  to clauses without an explicit who-specifier (`=rw`, `+x`) per
  POSIX §4.7. Now produces 644, matching GNU.

### Improvements
- **chmod: deduplicate symbolic mode parser (-368 lines).** chmod
  had its own 200-line symbolic mode parser duplicating the shared
  parser in `common/mode.zig`. Deleted the local copy; chmod now
  delegates to `common.mode.parseSymbolic`. Net removal: 609 lines
  deleted, 241 added.
- **common/mode.zig: POSIX umask support.** Activated the
  `ModeContext.umask` field (was reserved/unused). When no explicit
  who-specifier is given and the operator is `+` or `=`, the
  complement of the umask is applied per-class. `-` operations
  are never constrained. Both chmod and mkdir benefit.
- **mktemp: document intentional GNU divergences.** `--tmpdir`
  optional-value semantics (a getopt quirk no scripts rely on)
  and the now-fixed `fillRandom` limit are documented in the
  module doc comment.

### Verified
- All unit tests pass on macOS and Linux.
- Full integration suite: 48/48 utilities on Linux.
- mkdir 112/112, chmod all passing on both platforms.
- Umask semantics match GNU: `chmod +rw` with umask 022 = 0644,
  `mkdir -m =rw` with umask 022 = 644, `mkdir -m =rwx` = 755.

## v0.9.1 — 2026-04-05

Patch release. Fixes correctness bugs and test infrastructure
problems exposed by tightening CI coverage after 0.9.0.

### Bug Fixes
- **realpath / readlink**: default mode now matches GNU `-E`
  semantics (parent directory must be resolvable, last component
  may be missing). 0.9.0 accidentally routed default mode through
  `canonicalizeMissing`, allowing paths like `/nonexistent/dir/file`
  to succeed even when the parent was missing. New
  `canonicalizeParentMustExist` verifies the parent exists and
  is an actual directory (rejecting `file/foo` with `NotDir`).
- **mkdir -m symbolic mode**: fixed parser start base. `mkdir -m
  go-w foo` previously produced mode `0o000` (making the directory
  inaccessible even to its owner) because the local parser started
  from `0`. GNU mkdir starts from `0o777`. Now delegates to the
  shared `common.mode.parseSymbolic` with the correct base.
- **mktemp**: four GNU-compat fixes.
  - No-argument default template now lands in `$TMPDIR`/`/tmp`
    (was: cwd).
  - User-supplied bare templates (`mktemp myapp.XXX`) print
    `myapp.XXX` verbatim, matching GNU (was: `./myapp.XXX`).
  - `-t` with a template containing a slash now fails with
    `invalid template, '...', contains directory separator`.
  - `./myapp.XXX`, `foo/bar.XXX`, and `/abs/x.XXX` are all
    preserved verbatim in output.
- **id -G \<user\>**: no longer hangs on macOS CI. The
  `getgrouplist(3)` retry loop was unbounded and held a pointer
  into libc's static `getpwuid` buffer across calls. Now copies
  the username into an owned buffer, caps retries at 8, and
  forces strict `ngroups` growth on each retry.
- **tee**: error messages now include the failing filename,
  matching GNU's `tee: <file>: <error>` format (was:
  `tee: failed to open files: <error>` with no file identification).

### Test Infrastructure
- Add `run_with_limit SECONDS CMD...` helper in `tests/lib/common.sh`
  using Python 3 `os.fork`/`os.execvp`. Replaces GNU `timeout(1)`,
  which macOS GitHub Actions runners lack. Used by free, sleep, tee,
  and timeout test suites.
- Add `run_with_stderr_tty CMD...` helper using Python 3 `pty.fork`
  to exercise code paths gated on `isatty(stderr)` (cp's overwrite
  hint). Portable across Linux and macOS.
- dd conv=swab/block/unblock/ibm/ebcdic tests now assert against
  hardcoded GNU reference bytes instead of invoking `/usr/bin/dd`,
  which on macOS (BSD dd) does not implement these conv modes.
- du -L/-b/-S tests assert against hardcoded byte counts instead
  of `/usr/bin/du -b`, which BSD du does not support.
- mkdir integration tests now numerically verify the resulting
  mode for `go-w`, `a+rx`, and `u=rx` — catches future regressions
  in symbolic mode parsing that the old exit-code-only assertions
  missed.
- `test-privileged` recipe now retries up to 3 times to absorb
  ETXTBSY flakes (Linux kernel race between linker close and
  test exec under fakeroot).

### Platform Divergences Handled
- `id -G <user>` vs `id -G` count: macOS caps `getgroups(2)` at
  `NGROUPS_MAX=16` but `getgrouplist(3)` is uncapped, so the named
  form can legitimately have more groups than the no-user form on
  macOS runners. Unit and integration tests relaxed to assert
  that the named form is a superset of the no-user form rather
  than strict equality.

### Verified
- Full integration suite passes on both Linux (orb VM) and
  macOS CI: 48/48 utilities.
- All unit tests pass on both platforms.
- All symbolic mkdir modes (`go-w`, `u=rwx`, `a+rx`, `u=rx`,
  `g=rx`, `u=rwx,g=rx,o=r`, `a+X`) produce the same byte output
  as GNU coreutils 9.5 on Linux.
- All 6 dd conv modes produce GNU-matching output.

## v0.9.0 — 2026-04-05

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

## v0.8.4 — 2026-03-31

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

## v0.8.3 — 2026-03-29

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

## v0.8.2 — 2026-03-28

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

## v0.8.1 — 2026-03-27

### Infrastructure
- Fix Homebrew formula: switch to source archive URL with
  pre-built ARM64 bottle
- Build matrix uses native runners per platform instead of
  cross-compiling on ubuntu-latest

## v0.8.0 — 2026-03-20

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

## v0.7.3 — 2026-03-07

Fix O_APPEND stdout bug that corrupted output when
multiple utilities wrote to the same file descriptor.

- Fix O_APPEND stdout bug (#5)
- Add regression tests for O_APPEND behavior
- Fix Linux Nix build with multi-platform Cachix CI
- Add strict red-green TDD requirements to CLAUDE.md

## v0.7.2 — 2026-03-05

Colored df output with usage bars, ls git integration
improvements, and Linux Nix build fixes.

- Add colored output, usage bars, and smart grouping
  to df
- Fix ls bugs and convert --git to --git=WHEN
- Enable git status by default in ls for git repos
- Fix Linux Nix build and add multi-platform Cachix CI
- Add screenshots to README

## v0.7.1 — 2026-03-04

Respect VIBEUTILS_STYLE environment variable across
all utilities with color support.

- Respect VIBEUTILS_STYLE in ls, grep, and du

## v0.7.0 — 2026-03-04

Colored help output with nerd-font glyphs, standardized
man pages, and multi-platform release builds.

- Add color and nerd-font glyphs to help output
- Add help text consistency test
- Standardize man pages for consistency and style
- Add VIBEUTILS_STYLE env var and command linter
- Add multi-platform release builds to GitHub Actions
- Fix metavariable detection for trailing punctuation

## v0.6.1 — 2026-03-02

Colorized output across utilities, icon support, and
build tooling improvements.

- Extract shared size colors, add color to du
- Add icon colors and fix ls permission tests
- Add colorized help and enhanced ls display
- Add mandoc lint hook and artifact guard
- Add bash and mandoc to Nix devshell

## v0.6.0 — 2026-02-28

Linux support and cross-platform CI.

- Add Linux support across all utilities
- Add multi-platform CI matrix (macOS + Ubuntu)
- Fix cp fchmod crash on Linux
- Add Nix devshell with actionlint and direnv support
- Remove fuzz test infrastructure

## v0.5.1 — 2026-02-28

Release infrastructure and packaging fixes.

- Add release workflow with prebuilt binaries and Cachix
- Move Homebrew formula to dedicated tap repo
- Add obsolete -NUM syntax to head and tail

## v0.5.0 — 2026-02-27

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
