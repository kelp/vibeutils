# Changelog

## Unreleased

### Documentation
- **Rewrite `docs/INTEGRATION_TESTING.md` to match the tree.** The
  old page described `tests/integration/{lib,utils}/`, `init_framework`,
  and `exec_utility`, none of which exist. The real layout is
  `tests/integration.sh` plus `tests/utilities/` and `tests/lib/`,
  entered only through `scripts/run-integration.sh`. The wave2-walker
  workflow now tells agents to use that wrapper rather than
  `bash tests/integration.sh` as root (#152).
- **Add the `land-todo-slice` agent skill.** Operating procedure
  for landing one `TODO.md` heading as one draft PR: choose the
  slice, write a plan, review it with three models, implement
  with red-green TDD, and drain review comments until CI is
  green.

### Added
- **`tail -f` / `-F` now follow every file operand.** Appends to any
  followed file appear in stdout, with GNU `\n==> file <==\n` headers
  when output switches from one operand to another (suppressed by
  `-q`). Duplicate operands are separate slots. A hard cap of 256 real
  files applies before any dump I/O. `-F` retries missing or rotated
  names without stalling the other files.
- **`free` colors the used column and can draw a usage bar.**
  `--color=WHEN` (always/auto/never) wraps the Mem and Swap used
  fields green below 70%, yellow below 90%, and red otherwise.
  `--bar=WHEN` appends df's 10-cell usage-bar widget.
  `NO_COLOR` and `TERM=dumb` still kill color, including with
  `--color=always`. Default WHEN is `auto`.
- **`stat` gained the BSD display modes `-l`, `-r`, `-s`, `-x` and
  `-F`.** `-r` prints the raw numeric stat fields on one line, `-s`
  prints them as `st_name=value` shell assignments (so
  `eval $(stat -s FILE)` works), `-l` prints an `ls -l` style line,
  `-x` prints a verbose multi-line record, and `-F` appends an
  `ls -F` type suffix to the `-l` rendering. The four whole-output
  modes are mutually exclusive — a second one is an error (exit 1),
  as is `-F` with anything but `-l` — and combining any of them with
  the GNU output selectors `-c`, `--printf`, `-t` or `-f` is
  diagnosed as an error (exit 1) rather than silently picking one.
  Because BSD `-f FORMAT` is declined, these are fixed renderings of
  the FreeBSD preset formats, not a general format engine (#93).
- **`stat` gained the BSD `-n` and `-q` flags.** `-n` suppresses the
  newline that terminates each file's output record, in every output
  mode; newlines interior to a multi-line record are unaffected, and
  `--printf` (which never appended a mandatory newline) is unchanged.
  `-q` suppresses the per-file "cannot stat"/"cannot statfs"
  diagnostics while leaving the exit status non-zero, so a script can
  probe for a file without capturing stderr. Errors in the command line
  itself are still always reported. Neither flag has a long form, because
  BSD defines none (#93).

### Changed
- **Terminal size detection no longer reports a zero width or height.**
  `COLUMNS=0`, an empty or non-numeric `COLUMNS`/`LINES` value, and an
  ioctl window size of 0 all fall back to the 80×24 defaults now, so
  `ls` column layout never sees a zero terminal width. Previously a
  zero from the ioctl or from `COLUMNS`/`LINES` leaked through as-is.
- **`df --total` accumulates byte sums in 128-bit integers.** Two
  large filesystems could wrap the Size/Used/Avail totals at 16 EiB
  (`u64max`), and `used + avail` for the percent column overflowed
  independently. Both the default total row and `--output` now fold
  in `u128`, so a 2e19-byte aggregate prints as 20000000000000000000
  rather than a wrapped residue, and the percent stays the true
  ceiling of used/(used+avail) (#158).
- **`grep` with no pattern prints GNU's Usage line.** Bare `grep` and
  `grep --` wrote `grep: no pattern specified`; GNU prints
  `Usage: grep [OPTION]... PATTERNS [FILE]...` and the Try-help line,
  with no program-name prefix. Exit 2 is unchanged (#162).
- **`grep` frees parsed options on argument errors.** `parseArgs`
  signals those errors with `return null`, which does not run
  `errdefer`, so `--include`/`-e`/`--exclude` buffers leaked on the
  next unrecognized flag. Every `.fail` path now deinits before
  returning null (#164).
- **`ls -l` sizes mixed file-and-directory operands the way GNU does.**
  The file-operand lines were padded from the remaining files only,
  after directories had already been split out, so `ls -l file dir`
  under-padded nlink, owner, group and size whenever a directory
  operand was wider. Those columns now measure every command-line
  operand together; each directory listing still sizes itself from
  its own contents (#166).
- **`tiger-check.sh --staged` scans the index, not the worktree.**
  The pre-commit hook computes added lines from `git diff --cached`
  but used to awk the on-disk file, so staging a violation and then
  reverting the worktree made the hook report clean. Staged bytes
  now come from `git show :path`; the reported path is unchanged
  (#149).
- **Argument and usage errors now exit 1, not 2, across 38
  utilities.** This is a user-visible behavior change: any script
  that tests for exit status 2 from a bad flag, a missing operand,
  or a bad option value must be updated. The old value came from
  `ExitCode.misuse`, which encoded bash's "misuse of shell
  builtins" convention. coreutils has no such concept: POSIX 2024
  mandates no particular number, OpenBSD exits 1 everywhere (its
  one exception is `sort`), and GNU and macOS were measured
  per-utility and exit 1. `basename`, `cat`, `chmod`, `chown`,
  `cp`, `cut`, `date`, `dd`, `df`, `dirname`, `du`, `free`,
  `head`, `id`, `ln`, `mkdir`, `mktemp`, `mv`, `nl`, `printf`,
  `pwd`, `readlink`, `realpath`, `rm`, `rmdir`, `seq`, `sleep`,
  `stat`, `tac`, `tail`, `tee`, `touch`, `tr`, `uniq`, `wc`,
  `whoami` and `yes` all move from 2 to 1.

  Two groups keep a different code, because they need one.
  `grep`, `ls`, `sort`, and `test`/`[` still exit **2**: each
  already reserves 1 for a non-error outcome (no lines matched, a
  false expression, minor trouble), so their errors need a second
  tier. `env` and `timeout` now exit **125** for their own
  argument errors, which distinguishes a failure of the utility
  itself from the 126 and 127 they report for the command they
  run. The `ExitCode.misuse` name is gone; the enum is now
  `success`, `general_error`, `serious_error`, and
  `internal_error`.
- **Integration tests no longer run vibeutils when they mean the host
  tool.** `tests/integration.sh` still prepends `zig-out/bin` so
  `$binary` tests the build, but fixture setup (`chmod`, `ln`, `stat`,
  `mkdir`, …) is routed through `host` / `host_resolve` in
  `tests/lib/common.sh` and prefers `/bin` then `/usr/bin`. A new
  `audit-check` `path-shadow` rule flags the lookups those wrappers
  cannot intercept (`command chmod`, `find -exec chmod`,
  `run_with_limit chmod`). The macOS ACL tests in #147 skipped on CI
  because our `chmod` rejected `+a`; that class of skip is now a
  failure when the host tool cannot build the fixture (#167).
- **`ls` reserves the git-status column only when something has a
  status.** The 3-column indicator was reserved for every entry
  whenever git status was active, so a repository with no changes
  listed with a permanent blank indent. Because `--git` turns itself
  on implicitly wherever icons are on inside a repository, a plain
  `ls` on a dev machine paid for it. The decision is now made per
  directory section: a section whose entries are all clean drops the
  column and renders exactly like `--git=never`, while a section
  holding any modified or untracked entry keeps the column on all of
  its entries, clean ones included, so the indicator stays aligned.
  Under `-R` each section decides independently, so a clean
  subdirectory lists flush left in the same run where its parent does
  not. Non-directory operands make the same decision as a group
  (#113 follow-up, #119).
- **`stat` is now documented as a GNU-interface utility, and BSD
  `-f FORMAT` / `-t TIMEFMT` are explicitly declined.** `stat` is the
  only utility where BSD and GNU give the same flag letter different
  meanings, and the collision is exactly `-f` and `-t`. Both keep their
  GNU meanings (`--file-system`, `--terse`); the BSD spellings are
  retiered from MUST to WONT in `docs/specs/stat-flags.md` rather than
  left as unimplemented requirements. The divergence, and the mapping
  from BSD `stat -f FORMAT` to `stat -c FORMAT`, is now reachable from
  `stat --help` and a CAVEATS section in `stat(1)` — where someone
  surprised by it will actually look — instead of only from the spec
  matrix (#79, #93).
- **`ls -C` separates columns with tabs, matching BSD `ls`.** Column
  width is now `(width + 8) & ~7`, rounded up to a tab stop, and the
  gap is filled with tab characters instead of runs of spaces. A width
  already on a tab stop still gains a full stop, so 8 rounds to 16.
  The rule comes from Apple's `file_cmds` `ls/print.c` and was
  confirmed against `/bin/ls` on 18 fixtures straddling both
  boundaries; our output is byte-identical to `/bin/ls` on them. GNU
  is deliberately not the reference here: it sizes each column to its
  own longest entry, which is denser but is a different layout.
  `-x` keeps its two-space additive padding (#113 follow-up).

### Fixed

- **`tail -f` prints `cannot open` when a follow reopen fails after a
  successful dump.** The slot is still omitted from the follow set, but
  vanishing between dump and reopen no longer exits 1 with empty
  stderr. `-F` already printed this diagnostic; dump-failed `-f` paths
  stay silent because the dump already reported them.

- **Concurrent integration runs no longer race `useradd`.** Two
  `scripts/run-integration.sh` processes creating the same
  `VIBEUTILS_TEST_USER` could leave the home owned by a uid that
  passwd no longer had, and `setpriv` then died with `uid N not
  found`. Provisioning now takes a per-user lock (`flock` on Linux,
  `mkdir` elsewhere) around the existence check, `useradd`, and
  home `chown`, so overlapping creates serialize (#150).
- **`ls -e` dumps the ACL after each long-format line.** The flag
  was parsed into `show_acls` and then ignored, and `--help` called
  it a no-op. `-e` now implies `-l` (BSD) and prints a getfacl-style
  POSIX ACL after a marked entry; a file with no stored ACL is
  unchanged from `ls -l` (#147).
- **`ls -l` `total` now uses GNU's 1024-byte default, and empty
  directories print `total 0`.** The line previously summed raw
  512-byte `st_blocks` (twice GNU) and omitted the header when a
  directory had no visible entries. `-k` matches that 1024-byte
  total; `-h` humanizes the allocated size. `--block-size` stays
  WONT (#160).
- **`find`, `printf`, `dd`, and `date` honor `--` as the end of
  options.** All four hand-rolled parsers treated `--` as an operand
  or unknown flag: `printf -- 'x\n'` printed `--`, `find -- .`
  reported an unknown predicate, `dd -- if=f` was an unrecognized
  operand, and `date -- +%Y` was an unrecognized option. They now
  match GNU: `--` stops option parsing, a leading `--` with nothing
  after it is a missing operand for printf, a second `--` is still a
  predicate for find and an unrecognized operand for dd, and date
  treats a following dash-token as a date string. `--` is a delimiter
  for find only before any start path (`find . --` is an unknown
  predicate). After `dd --`, `--help`/`--version` are unrecognized
  operands, and the first invalid token — including an unknown
  `key=value` or an empty `''` — is the one named. Date collects
  positionals: a second operand is extra (quoted), a single non-`+`
  token is a date string. A leftover non-`+` positional after `--date`
  or `-r` is GNU "lacks a leading '+'". After a find start path, `--`
  is an unknown predicate (`find . -- --help`); `--help` in predicate
  position still prints help (`find . -name -- --help`). Walker
  globals `-depth`/`-d`/`-xdev`/`-mount`/`-follow` are captured
  only as sequential primaries, so a token that is a primary
  argument (`find DIR -exec true -depth \;`) does not flip them (#159).
- **`grep --` no longer swallows the pattern.** `grep -- -v FILE`
  reported "no pattern specified" and exited 2, which made a pattern
  that looks like an option impossible to search for. `--` did not
  consume the pattern; it disabled the branch that assigns one, so
  every operand after it became a file. grep now follows GNU's rule
  and decides the pattern slot after the whole argument scan: the
  first remaining operand is PATTERNS if and only if neither `-e` nor
  `-f` supplied a pattern source. That also fixes `grep FILE -e PAT`,
  which used to take `FILE` as the pattern, and `grep -f empty FILE`,
  which used to read stdin with `FILE` as the pattern. An empty
  pattern set is now legal rather than an error: it matches nothing
  and exits 1, without opening any operand unless `-v` or `-L` is in
  effect. A `-f`/`--file` argument that cannot be *read* is a
  different case and remains fatal, as in GNU: grep names the file,
  exits 2, and opens no operand, and neither an `-e` pattern nor a
  second readable `-f` rescues it. Previously the failure was
  swallowed and left an empty pattern set behind, so `grep -v -f
  typo.txt FILE` printed the entire file and exited 0 — a filtering
  pipeline with a missing blocklist now fails closed (#151).
- **`ls -l` now marks a file carrying an ACL with `+`, the way GNU
  does.** The mode field grows from ten columns to eleven for every
  entry of a section as soon as one of them has an extended ACL —
  `+` for that entry, a pad space for the rest — so a listing that
  mixes the two lines up with GNU's column for column instead of
  drifting one character left. A section with no such entry keeps
  the ten-column field and is byte-identical to before, whether it
  is printed before or after a section that widens. A directory
  carrying only a default ACL is marked too, including on a
  filesystem that leaves `d_type` unfilled, and no ACL is probed at
  all outside `-l`. A symlink listed inside a directory is marked
  only under `-L`; a symlink named directly on the command line is
  marked after its target either way, because `ls -l` on a symlink
  operand already prints the target's mode rather than the link's —
  a separate pre-existing divergence from GNU, and the marker simply
  follows the mode it belongs to. Detection reads
  `system.posix_acl_access` and `system.posix_acl_default` on Linux,
  and `acl_get_file`/`acl_get_link_np` plus `acl_get_entry` on
  macOS; the SELinux `.` marker is not implemented, so on an
  SELinux-enforcing host GNU marks every file `.` and we do not.

  One divergence is left standing: GNU measures every command-line
  operand before it splits directories out of the operand table, so
  a directory operand's ACL widens the mode field of the *file*
  operands printed beside it, and ours does not. The size, link
  count, owner and group columns already scope exactly the same way
  on that path, so this is one instance of a pre-existing family
  rather than anything this change introduced; it is left for a
  separate fix that moves the whole measurement boundary at once
  (#147).
- **Integration runs no longer share a working directory.**
  `tests/utilities/mkdir_test.sh` builds its fixtures with relative
  paths, so whatever directory `scripts/run-integration.sh` was started
  from became scratch space for the whole suite — the caller's cwd (the
  repo root under `just it`) when unprivileged, the test user's home
  when demoting. A leftover `combo/` from an interrupted or concurrent
  run made `mkdir -pv combo/test/path` print two "created directory"
  lines instead of three, failing once and then deleting the
  contaminant, which is why the flake never reproduced. Every run now
  gets a private working directory that is removed afterwards, so
  concurrent suites and interrupted ones can no longer affect each
  other (#125).
- **The Tiger Style scanner now has a contract test suite, and CI runs
  it before trusting the scan.** `tests/tools/tiger-check_test.sh` pins
  that a function whose body grows past the 70-line limit behind an
  unchanged signature is classified `NEW`, not `PRE` — the case the
  pre-commit hook, gating on `new>0`, was waving through — and that the
  same holds for `self-recursion` and for a parameter line added to a
  multi-line signature. It pins the other direction just as hard:
  editing an unrelated function, or deleting lines from a still-too-long
  one, stays `PRE`, so attribution cannot degenerate into "any diff in
  this file blocks". Fixtures are throwaway git repos in a temp dir,
  because the scanner has no `--root` and its diff modes need real git
  history (#131).

- **`df` no longer panics on a very large `--block-size`.** Any block
  size within a filesystem's byte count of `u64max` overflowed the
  ceiling divide `bytes + display_block - 1`, which wraps before the
  division happens, aborting the process where GNU prints an ordinary
  table. The expression appeared twice, reached by different paths —
  `formatSize` for every invocation and `printTotal_formatField` only
  under `--total` — and both now share one overflow-free `ceilDiv`
  helper so they cannot drift apart again (#138).
- **`df` no longer panics computing the use percentage on very large
  filesystems.** `used * 100 + total - 1` was evaluated in u64, so the
  multiply overflowed above 164 PiB of used space and the trailing
  addition wrapped even earlier — at `used == total` the last safe
  value was 182641030432767837. Shipped binaries are ReleaseSafe, so
  this aborted the process rather than printing a table; under
  ReleaseFast it silently reported a full filesystem as `0%`. The
  multiply is now done in u128, exact across the whole u64 range, and
  the ceiling uses GNU's remainder form `q + (r != 0)` from coreutils
  `src/df.c` rather than the overflow-prone `+ total - 1`. The
  `--total` row computed the same expression inline twice and now
  calls the shared helper, so all three sites — per-filesystem,
  `--total`, and `--output=pcent` — are fixed together. Percentages
  for ordinary filesystems are unchanged (#144).
- **`ls -l` sizes the nlink, owner, group and size columns to their
  content.** They were padded to hardcoded widths — 3, 8, 8 and 8, or
  5 for a human-readable size — so every listing of small files
  carried filler, and a username longer than eight characters pushed
  the columns out of alignment outright. Each is now measured across
  the section and separated by a single space, matching GNU. Owner and
  group are left-aligned as names but right-aligned as numbers under
  `-n`, and the size column is measured on the rendered string, so
  `-h`, `-k` and `--thousands` each get the width they actually need.
  `-o` and `-g` keep the surviving column at its section width. The
  four columns join the single measuring pass that already computed
  the time and `-s` widths rather than adding a third traversal (#124).
- **Unambiguous long-option abbreviations now resolve, as GNU's
  `getopt_long` does.** `wc --vers` printed `unrecognized option`
  where GNU prints the version banner, because long flags matched
  only by exact name. A prefix matching exactly one option now
  resolves to it, and one matching several reports them —
  `option '--he' is ambiguous; possibilities: …` — in the order GNU
  itself lists them, not alphabetically. The candidate list follows
  the utility's `Args` field declaration order, so those fields were
  reordered to GNU's own longopts order in `chmod`, `chown`, `cp`,
  `head`, `ln`, `mkdir`, `mv`, `nl`, `rm`, `rmdir` and `tail`:
  `cp --v` now lists `'--verbose' '--version'` and `cp --p` lists
  `'--parents' '--preserve'`, byte for byte as GNU does. An exact
  match still wins over being the prefix of something longer, so
  `cat --number`, `id --group` and `rm --interactive` keep working
  rather than becoming ambiguous. Downstream diagnostics name the
  expanded option, so `cut --deli` reports
  `option '--delimiter' requires an argument`. Shared by the
  utilities that parse through `common.argparse`; those with
  hand-rolled parsers are unaffected (#128).
- **`rm` refuses abbreviations of `--no-preserve-root`.** GNU carves
  that one option out of `getopt_long`'s abbreviation rule on
  purpose, because it disables the guard that stops `rm -r /`, so
  `rm --no-p` must not quietly enable it. It now prints
  `rm: you may not abbreviate the --no-preserve-root option` and
  exits 1, with no `Try 'rm --help'` hint line — GNU dies there
  rather than routing through its usage printer. The check runs
  after the option has resolved, so a prefix that is genuinely
  ambiguous still reports ambiguity: `rm --no-` also abbreviates
  vibeutils' `--no-cross-device`. Every other `rm` long option
  still abbreviates, `--pre` (`--preserve-root`) included. `chmod`
  and `chown` have a no-op `--no-preserve-root` and are not carved
  out, matching GNU (#128).

- **Option errors name the offending flag and carry GNU's hint
  line.** `argparse` collapsed every parse failure into one static
  string, so `whoami --invalid-flag` said only `unrecognized option`
  with no indication of which flag was wrong. It now matches GNU's
  five distinct formats, which differ by more than wording: an
  unrecognized long option quotes the full typed token, while
  "requires an argument" quotes the name with `=value` stripped, and
  short options use a bare character (`invalid option -- 'x'`).
  `-hZ` reports `Z` rather than the first character of the cluster.
  The flag text is a borrowed slice of argv, so naming it costs no
  allocation, and `parse`'s signature is unchanged. Shared by the 27
  utilities that parse through it (#130).
- **`df --block-size=N` abbreviates the header label like GNU.** Only
  512, 1024, 1M and 1G were spelled out; every other size fell back to
  the raw byte count, so `--block-size=2000` printed `2000B-blocks`
  where GNU prints `2kB-blocks`. The label now follows GNU's rule: the
  base is decided by racing the 1000 and 1024 divisibility chains (a
  tie goes to 1000, so `--block-size=1024000` is `1.1MB-blocks`, not
  `1000K-blocks`) and the mantissa is rounded up, never to nearest, so
  `--block-size=1023` is `1.1kB-blocks`. POSIX mode (`-P`) still names
  the raw byte count and never abbreviates (#132).
- **`free -c N` no longer requires `-s`.** It rejected a bare count with
  `free: -c requires -s option` (exit 1). procps accepts it: `-c N`
  repeats N times with an implied one-second interval, paid only
  between reports, so `free -c 1` prints once and returns immediately.
  `-s N -c M` is unchanged. The help text and man page no longer tie
  `-c` to `-s`.
- **`printf` with no operands reports `missing operand`.** It printed
  `printf: usage: printf FORMAT [ARGUMENT...]`; it now matches GNU with
  `printf: missing operand` followed by the
  `Try 'printf --help' for more information.` hint. The exit status
  stays 1.
- **`df --output=FIELD_LIST` selects columns instead of being ignored.**
  The option parsed and set a field list that no renderer ever read, so
  `df --output=source,size /` printed the ordinary table. It now renders
  exactly the requested fields, in the order they were written, from the
  twelve GNU names `source`, `fstype`, `itotal`, `iused`, `iavail`,
  `ipcent`, `size`, `used`, `avail`, `pcent`, `file` and `target`. Bare
  `--output` selects all twelve in GNU's canonical order rather than the
  seven-field subset it used before. An unknown or repeated field is an
  error, as is combining the option with `-i`, `-P` or `-T`. `-h`, `-k`
  and `--block-size` still control how the size columns render, and
  `--total` still appends a total row. Because the field list is chosen
  explicitly, no usage-bar column is injected into it, though color and
  icons still apply to the columns that were asked for.
- **`df` labels the available-space column `Available` in block modes.**
  The dynamic renderer hardcoded `Avail`, which is the human-readable
  spelling. GNU uses `Available` in every block mode, POSIX or not, so
  `df -P`, `df -k` and `df --block-size=1M` were all diverging; only
  human-readable output was right. The label now follows the resolved
  display mode.
- **`df -P` applies the POSIX header set only in block mode.** The
  `Capacity` label came from the presence of `-P` alone, so `df -P -h`
  and `df -P -H` printed a POSIX percent label beside human-readable
  sizes. A human-readable mode now takes the default header set, as in
  GNU.
- **`df -P --block-size=SIZE` names the raw byte count.** POSIX mode
  never abbreviates the block-size label, so `-P --block-size=1M` now
  reads `1048576-blocks` rather than `1M-blocks`. Outside POSIX mode
  the abbreviated spellings are unchanged.
- **`df -I` suppresses the inode columns on macOS.** The flag parsed
  and set a field nothing read, so `df -i -I` still printed inode
  columns. BSD resolves `-i`/`-I` last-flag-wins: `-I` now cancels a
  preceding `-i`, and a following `-i` re-enables inode mode. The help
  text is also platform-correct, describing `-I` as a boolean on macOS
  and as an exclude-type filter taking a `TYPE` argument elsewhere.
- **`whoami` prints the effective user, not the real one.** It looked
  up the real uid via `getuid()`, so a set-user-ID invocation reported
  the invoking user rather than the effective one. Its own help text
  and GNU both define the output as the effective user ID, the same
  identity `id -un` prints. It now resolves `geteuid()`. Only `whoami`
  changed; the shared `getCurrentUserId()` helper keeps its real-uid
  semantics for `chown`, `stat` and `id`.
- **`whoami` appends GNU's hint line to the extra-operand error.**
  An operand produced `whoami: extra operand 'x'` with no follow-up,
  where GNU also prints `Try 'whoami --help' for more information.`
- **`whoami` resolves `--help` and `--version` in command-line
  order.** Both flags were parsed before either was acted on, and
  help was always checked first, so `whoami --version --help` printed
  the usage text. GNU acts on whichever flag appears first, so that
  invocation now prints the version banner.
- **`ls -x` lays out the BSD column grid instead of padding with
  spaces.** `-x` sized its columns as the widest entry plus two
  spaces and filled the gaps with spaces, while BSD gives `-x` and
  `-C` the identical grid and differs only in fill order: across
  rows rather than down columns. Both the separator and the number
  of columns per row were wrong, so `-x` disagreed with `/bin/ls`
  on essentially every listing, not only under `-F`. Nine names of
  ascending length in an 80-column terminal came out in seven
  space-padded columns where BSD prints five tab-separated ones.
  `-x` now shares the column arithmetic with `-C`, including the
  `-F`/`-p` widening and the `-s` prefix, and is byte-identical to
  `/bin/ls` at every width tested.
- **`ls -s` sizes its block-count field to the widest count.** The
  field was a fixed four columns, so a listing whose counts are all
  single digits printed three leading spaces that BSD and GNU both
  omit, and one holding a five-digit count would have run its
  numbers together with the names. The field is now as wide as the
  widest count in the section plus a separating space, right
  aligned, which is what the multi-column path already did. It
  applies to `-1` and `-l` alike.
- **`ls -s` reports allocated blocks instead of a size-derived
  count.** Block counts came from `ceil(size / 512)`, which measures
  how much of a file is written rather than how much space it
  occupies. A 100-byte file reported 1 block where the filesystem had
  allocated 8, and a sparse file reported blocks it does not hold at
  all. `st_blocks` from the stat we already perform is now used, as
  BSD and GNU both do, which corrects the per-entry counts, the
  `total` line that sums them, and the same total under `-l`. `-k`
  rounds that count up to whole kilobytes (#117).
- **`ls` prints non-directory operands as one section.** Operands were
  printed one at a time, so none of them reached the formatter seam
  that lays out a section. A clean tracked file listed as an operand
  reserved the git-status column and came out indented three spaces
  while the very same file listed flush left inside a directory
  section; `ls -C a b` ignored `-C` and printed one operand per line;
  and `ls -s a b` printed no block counts at all. The operand group
  now flows through that seam, so it columnates, prefixes, and
  reserves the git column as a group. `ls -d dir` takes the same path,
  which also gives it the `-F` indicator and the color it was missing.
  The `total` line stays suppressed for operands, matching BSD and GNU
  (#119).
- **`ls -C -F` sizes its columns the way BSD does.** The `-F` type
  indicator was folded into each entry's own width, so it widened the
  column only when the widest entry happened to carry one. BSD adds a
  flat `+1` to the raw maximum name length whenever `-F` or `-p` is
  active, whichever entries get an indicator. A listing of two 7-char
  files and a directory laid out one tab stop narrower than `/bin/ls`;
  it is now byte-identical (#121).
- **`ls` multi-column rows no longer end in whitespace.** The padding
  guard skipped only the last column and the globally last entry, so
  any row whose final cell was followed by an out-of-range column got
  padded anyway: 3 of 4 rows on this repo's root ended in spaces.
  BSD and GNU both stop before padding the last cell of a row. The
  columnar path now breaks on the same row-relative test, which also
  covers a partially filled final row (#113 follow-up).
- **`ls` prints one entry per line when stdout is not a terminal.**
  POSIX requires the default format to be `-1` off a terminal, as GNU
  and BSD both do; we kept the column layout everywhere. Because
  columns are space-padded, every entry but the last on a line carried
  trailing whitespace, so a name was no longer at end-of-line and
  anchored patterns downstream stopped matching: `ls | grep -v
  '\.lock$'` let a padded `0.11.3.lock` through, which silently
  corrupted a gale bootstrap script. `printEntries` picked its format
  from the option flags alone and never consulted the `is_terminal` it
  already computed for icons and colors. Fixing the one branch fixes
  `-R` too, since every directory section prints through it. Explicit
  format flags still win off a terminal, which exposed a second
  defect: `-C` was parsed but never copied into the options struct, so
  it had always been a no-op that only looked correct while the
  default was multi-column. It is now plumbed through and documented
  in `ls(1)`. Icons and git status stay as configured under the new
  implicit default, unlike explicit `-1`, which suppresses them as
  before (#113).
- **`ls` prints file operands as given and sorts the operand list.** A
  non-directory operand was printed as its basename, so `ls subdir/file`
  emitted `file` and the output no longer addressed the file from the
  current directory, breaking `ls dir/*.jsonl | while read` pipelines.
  Operands were also listed in argv order, so `-t`, `-S`, `-r` and the
  POSIX-required default name sort never applied to them, and
  `ls b_dir a_dir` emitted its sections in the wrong order. Both are
  fixed; `-U` and `-f` still preserve argv order. `--git` on an operand
  inside a subdirectory now reports the right status, having previously
  looked up the truncated basename. Two adjacent divergences found while
  rewriting the same function are fixed with it: an operand that cannot
  be stat'd no longer prints a bogus header on stdout, and `-d` with
  several operands sorts them together without headers (#103).
- **A copy that cannot change the destination's mode no longer dumps a
  stack trace.** `setPermissions` classified every `fchmod` failure as
  unexpected, so the ordinary EPERM case ("you do not own this file")
  printed the errno and a stack trace on every Linux run. The suite
  still exited 0, so the damage was to the diagnostic channel: the dump
  carries the literal string `failed command:`, which made anything
  grepping test output for failures report one that was not there.
  EPERM and EROFS are now classified as the ordinary errors they are.
  No exit code, message, or observable behavior changed (#99).
- **`ls -l` renders timestamps in the local timezone.** All four
  timestamp sites decoded epoch seconds with
  `std.time.epoch.EpochSeconds`, which carries no timezone database and
  can only yield UTC, so every stamp was off by the UTC offset and `TZ`
  was never consulted at all — a file touched in the evening could
  display tomorrow's date, which also moved the six-month
  recent-vs-old boundary. They now share one helper built on libc
  `localtime_r`. The offset is resolved per timestamp rather than
  captured once, so stamps on either side of a DST transition each get
  the right one, and `--time-style=long-iso` prints the real offset
  instead of a hardcoded `+0000` (#104).
- **`stat -c %N` matches GNU's shell quoting for awkward names.** `%N`
  always wrapped the name in single quotes, so a name containing one
  came out as three shell tokens rather than the single token `%N`
  exists to guarantee. GNU's `quotearg` reaches for double quotes only
  when nothing inside would itself need escaping within them, so
  `it's` becomes `"it's"` but `it's and $var` becomes
  `'it'\''s and $var'` — a name holding both an apostrophe and any of
  `"`, `\`, `$` or `` ` `` stays single-quoted with the classic splice.
  All three branches are implemented, and a symlink's name and target
  now pick their quote style independently. Non-printable bytes remain
  out of scope: GNU ANSI-C-splices them and we pass them through, which
  a characterization test now pins (#105).
- **`stat` no longer truncates device minor numbers above 255 on
  Linux.** `%t`/`%T`, the `-t` terse fields, and the default
  `Device:` line each re-derived the major and minor with their own
  copy of a mask that kept only the low 8 bits of the minor, dropping
  the high bits the kernel stores elsewhere in the packed `dev_t`.
  `stat -c '%t %T' /dev/binder` reported `a 4` where GNU reports
  `a 104`. All three now use the same extraction helpers, so the bit
  layout is described in exactly one place. macOS was unaffected
  (#92).
- **`stat` reports GNU's `Device type: MAJ,MIN` field.** Character
  and block special files gain the field, which also widens the
  `Links` column to five; every other file type is unchanged (#92).
- **`stat`'s default output matches GNU byte for byte.** GNU
  separates `Size:` from `Blocks:` with a tab, and follows the
  `Blocks`, `IO Block` and `Inode` fields with literal spaces. We
  folded each separator into the preceding column's padding, which
  looks identical for everyday values but drops the separator
  outright once a field outgrows its pad: a 10 GB file printed
  `10737418240Blocks:`, and an inode of 11 digits or more left one
  space before `Links:` where GNU leaves two. On Linux the whole
  record is now identical to `/usr/bin/stat` for regular files,
  directories and device nodes (#98).
- **`stat` no longer reports an epoch birth time as unavailable.**
  Availability was inferred from `btime.sec == 0`, but 0 is a legal
  timestamp, so a file born at or near the epoch printed
  `Birth: -`. It comes from statx's `STATX_BTIME` bit on Linux, which
  was already requested and discarded, and from gnulib's zero-`tv_sec`
  rule on macOS, where no such mask exists. `%W` stays numeric and
  prints 0 when unknown, and `-x` keeps formatting the raw value, both
  matching their own reference (#102).
- **`stat` reported the wrong device number on Linux.** `doStat`
  composed `st_dev` as `(major << 32) | minor`, a synthetic value the
  kernel never uses, so `stat -c %d` printed 1090921693184 where GNU
  printed 65024, `%D` printed `fe00000000` instead of `fe00`, and the
  default `Device:` line printed `0,0` instead of `254,0`. Both
  `st_dev` and `st_rdev` are now packed with the kernel's real
  encoding (glibc `makedev`), which repairs all three at once (#93).
- **The walker's re-entrancy test no longer fails when run as
  root.** It chmods a directory to `000` and expects the walk to
  report an I/O error, but root bypasses DAC, so the premise cannot
  hold and the test failed for anyone working in a container. It
  now skips on `geteuid() == 0`, matching the guard already used in
  `src/common/file_ops.zig`. Unprivileged runs, including CI, still
  execute it.
- **`zig build test` no longer hangs when a test fails.** Tests in
  `display_config.zig`, `du.zig`, `df.zig`, `ls/main.zig`, and
  `ls/display.zig` staged their fixtures with libc
  `setenv`/`unsetenv`. glibc's `unsetenv` compacts the `environ`
  array in place, which invalidates the environment Zig 0.16
  captures once at startup — so the test runner's error-trace path
  (`Io.lockStderr` → `scanEnviron` → `Environ.scan`) null-unwrapped,
  and the panic handler then deadlocked re-entering a mutex it
  already held. A failing test therefore wedged the suite forever,
  surfacing in CI as a timeout rather than a failure. Tests now
  stage the environment through a test-only overlay in `env.zig`
  instead of mutating the process, which also removes a
  use-after-free where saved `getenv` pointers were read back after
  an intervening `unsetenv` (#95).
- **Zig 0.15→0.16 API rot in four previously-dormant modules.**
  Waking the tests above exposed compile errors that had been
  invisible: `colors.zig` used the removed
  `std.ArrayList(u8).Writer` GenericWriter adaptor,
  `relative_date.zig` called `std.time.nanoTimestamp`,
  `test_dir.zig` read `Stat.mode`, and `test_utils.zig` used
  `ArrayListUnmanaged(u8){}` plus 0.14-era capitalized
  `Child.Term` tags. `test_utils_privilege.zig` called the
  long-removed `std.time.timestamp` (#95).
- **Three test assertions that had drifted from the code they
  guard.** `help.zig` asserted both that `isUppercasePlaceholder("N")`
  is true and, three lines later, that it is false — the original
  was never deleted after the correction. `icons.zig` expected the
  plain-Unicode ⚡ for `.zig` and a stale glyph for `.pl` after the
  theme migrated to Nerd Font. In every case the implementation was
  correct and the test was wrong (#95).
- **`cp -p` and `mv` now duplicate the source mode exactly instead
  of letting the umask eat it.** The shared copy leaf set the
  destination mode only through `createFile`'s `O_CREAT` argument,
  which the kernel masks with the process umask, so `umask 077; cp
  -p` turned a 644 source into a 600 copy. `-p` now bypasses the
  umask the way GNU does, applying the mode with an explicit
  `fchmod` after the copy. Two further defects fell out of the same
  call: `O_CREAT`'s mode is ignored outright when the destination
  already exists, so `cp -p` never updated an existing file's mode
  (it now does, truncating in place so the inode and any hard links
  survive); and because ownership was restored last, and Linux
  clears setuid/setgid on any `chown` — even a same-owner no-op —
  a 4755 source silently became 755. Ownership is now restored
  before the mode, so special bits survive. A mode that cannot be
  preserved is reported and fails, matching GNU's per-attribute
  policy, while an unprivileged ownership failure stays silent.
  `cp -a`, `cp --preserve` and every cross-device `mv` share the
  same leaf and are fixed with it; `cp` without `-p` still applies
  the umask and drops special bits, unchanged (#81).
- **`cp -p` and `mv` now preserve directory ownership.** Directory
  preservation applied timestamps and mode but never `chown`ed, so
  a `-p` copy of a tree silently reassigned every directory to the
  copying user while its files kept their owner (#81).
- **cp -r no longer panics or runs away when the destination
  lives inside the source tree.** `cp -r dir/. dst/` (with `dst`
  under `dir`), `cp -r a a`, and `cp -r a a/b` previously aborted
  a debug build on a tree-walk stack-underflow assert and
  self-nested unboundedly in release builds. cp now refuses the
  offending subtree with GNU's `cannot copy a directory, 'X',
  into itself, 'Y'` (exit 1) while still copying unaffected
  siblings. A source ending in `.`/`..` copies the resolved
  directory's contents directly into the destination with no
  nesting layer and no literal `.`/`..` path component, and
  creating a directory over an existing non-directory now fails
  with `cannot overwrite non-directory` instead of silently
  merging (#82).
- **grep now supports the GNU regex escape extensions on macOS.**
  `\s`, `\S`, `\w`, `\W` (in both BRE and ERE) and `\|`
  alternation (in BRE) are translated to portable POSIX
  constructs before compilation, so patterns like
  `grep -E '^\s+plan'` or `grep 'foo\|bar'` match on macOS
  exactly as they do with GNU grep instead of silently matching
  nothing. Bracket expressions keep their POSIX literal meaning
  (`[\s]` still matches `\` or `s`), and `grep -x` no longer
  mangles a `\|` that appears inside brackets. The directional
  word boundaries `\<` and `\>` are also supported on macOS;
  Linux continues using glibc's native boundary escapes. Because
  macOS libc has no numbering-safe equivalent for `\b`/`\B`,
  those two now produce a clear unsupported-pattern error there
  instead of silently matching nothing (#78, #84).
- **cp now duplicates the source's permission bits when creating
  a new destination.** A 755 executable no longer silently
  becomes 644 on copy: new files get the source mode (special
  bits stripped, umask applied — POSIX baseline semantics, not
  `-p` behavior), and `cp -r` creates directories with the source
  directory's mode, kept user-writable during traversal so
  read-only trees still copy, then fixed up post-order, matching
  GNU. Existing destinations keep their own mode, and `-p`
  behavior is unchanged (#77).
- **rm -r and mv no longer silently skip a directory aliased by
  a sibling symlink.** The walker's global visited set
  pre-registered every symlink's followed target, so `rm -r tree`
  with `tree/link -> tree/real` left `real`'s contents undeleted
  and exited 1, and mv's cross-device fallback copied the tree
  without `real`'s contents while still deleting the source
  (data loss). Both now use ancestor-only cycle detection (GNU
  fts semantics, matching GNU rm/mv), and the now-unused
  `ancestors_and_visited` walker mode is deleted (#69).

### Infrastructure

- **CI no longer fails when the `just` release download has a bad
  spell.** `extractions/setup-just` fetches a casey/just release on
  every job, and three `socket hang up` / `HTTP 503` failures landed
  across two PRs inside forty minutes, each failing a job whose real
  work was fine. Every workflow now goes through
  `.github/actions/setup-just`, which tries that action and, only if
  it fails, downloads the tarball directly with curl's own retry. A
  final step runs `just --version`, so neither route is trusted until
  the binary actually works — an install step that succeeds without
  producing a usable binary is the failure this is meant to catch,
  not reproduce. (#132/#133 CI follow-up)

- **The TDD workflows no longer hard-require the `tdd-pipeline`
  plugin.** Their test-writer, implementer and code-reviewer agent
  types were named as bare `tdd-pipeline:` literals, so on any host
  without that plugin installed `agent()` raised `agent type not
  found` and aborted the whole run at the first authoring stage. The
  namespace is now an `agent_ns` workflow argument defaulting to the
  plugin, so a machine that has it is unaffected; passing `""` falls
  back to the default subagent. Separation of test-writing from
  code-writing is unaffected — it rests on distinct invocations and
  disjoint file ownership, not on the plugin's system prompts. (#136
  follow-up)
- **`scripts/audit-check.sh` gates the six mechanically detectable
  defect classes on every push.** Stage 1 of `docs/AUDIT_SWEEP.md`
  is now a script: flags parsed into the options struct and never
  read, `docs/specs/<util>-flags.md` rows claiming `Ours: yes` for a
  flag the parser does not have, shell assertions that cannot fail,
  code reachable only from `test` blocks, and tests that assert
  `parsed.opts.<field>` instead of behavior. It sweeps all 47 units
  in about three seconds using only POSIX sh and awk, so the new
  `audit` workflow installs neither Zig nor `just`, and it runs the
  scanner's own contract tests first — a scanner that has broken
  reports zero findings and exits 0, which reads exactly like a
  clean tree. A sixth check, `unscannable`, reports and gates on any
  unit the scanner cannot parse, so a unit never drops out of
  coverage silently. Existing findings are recorded in
  `scripts/audit-baseline.tsv`, keyed by construct rather than by
  line number so a row keeps covering its finding when the code
  around it moves, and every row must carry a justification: the
  scanner exits 2 on an empty one, a duplicate key, or an unknown
  check name. There is no inline suppression comment (#133).
- **A Linux agent container is now a first-class development
  environment, not a degraded macOS dev box.** The tooling assumed
  OrbStack, a Docker daemon, `codex`, `gh` and a `/Users/tcole`
  worktree layout, and three of those assumptions were silently
  wrong rather than merely unportable. The workflow pipelines had a
  red-phase gate that required a macOS leg and a final gate that
  ANDed five platform legs, so nothing could ever go green where
  there is only one platform; the secondary-platform legs are now
  nullable and an unreachable platform reports as deferred to CI
  instead of as a pass. The `codex` review gate no longer reports
  not-ready forever when `codex` is absent — an independent Claude
  reviewer runs under a distinct agent type and which reviewer ran
  is logged, because "unavailable" must not read as "approved".
  Most costly of all, the pipelines invoked `tests/integration.sh`
  directly, bypassing the `scripts/run-integration.sh` demotion to
  an unprivileged user; as uid 0 that produces roughly two dozen
  phantom permission-denied failures across `cat`, `chmod`,
  `chown`, `grep`, `ls`, `rm` and `stat`. Worktree roots and the
  Linux command prefix are now environment-driven with
  platform-conditional defaults, so the macOS dev box behaves
  exactly as before. Alongside: `just platform` reports what this
  host actually has, Docker and `actionlint` recipes fail with an
  accurate message instead of telling a container to start a daemon
  it cannot start, `scripts/bootstrap.sh` distinguishes
  "not installed by design" (`n/a`) from `MISSING`, a Linux release
  run says plainly that macOS validation is deferred to CI, and
  `VIBEUTILS_TEST_USER` is documented for running two worktrees'
  integration suites concurrently.
- **`CLAUDE.md` trimmed from 724 to 276 lines, with the test-first
  discipline extracted into a `tdd` skill.** Applies Anthropic's
  context-engineering guidance for Claude 5 models: the file now
  carries the repo's gotchas and defers the rest through
  progressive disclosure. The Zig 0.16 pitfall catalog, the release
  gate prose, and the testing conventions were duplicates of the
  `zig-patterns` skill, the release scripts, and
  `docs/TESTING_STRATEGY.md` respectively; the man page house style
  moved to `docs/MAN_PAGE_REFERENCES.md`. The mandatory four-agent
  workflow was dropped as a guardrail written for older models —
  the part worth keeping, that tests and implementation come from
  separate agents, now lives in the new skill.
- **`scripts/bootstrap.sh` installs the toolchain on a fresh clone.**
  One idempotent script that installs the Zig version pinned in
  `build.zig.zon` plus `just`, `mandoc` and `fakeroot`, then proves
  the result by running `zig build --list-steps`. It reads the pin
  rather than carrying its own copy of the version, serialises on a
  lock file so a second run waits for an in-flight install instead
  of racing it, and finishes in under a second once warm. Zig comes
  from the PyPI `ziglang` wheel first, falling back to
  `docker/scripts/install-zig.sh` for the official mirrors — the
  wheel is the only source reachable from networks that block
  `ziglang.org`, which includes hosted agent containers. It also
  installs `bsdextrautils`, without which the `hexdump` the
  integration suite depends on is missing and `pwd` and `dirname`
  fail. Also exposed as `just setup`.
- **`just it` now drops privileges when run as root.** Roughly two
  dozen integration tests across `cat`, `chmod`, `chown`, `grep`,
  `ls`, `rm`, `stat` and others assert that an operation is denied.
  Root bypasses DAC, so those assertions cannot hold and the suite
  was red for anyone working in a container or a Docker image —
  13 of 48 utilities failing for a reason unrelated to the code.
  The new `scripts/run-integration.sh` re-executes the suite as an
  unprivileged user (`vibedev`, created on demand) when it starts
  as root, and is a pass-through otherwise, so CI and dev machines
  are unaffected. `VIBEUTILS_NO_DEMOTE=1` opts out. No test was
  weakened or skipped to achieve this.
- **Claude Code remote/web sessions bootstrap themselves.** A
  `SessionStart` hook (`.claude/hooks/session-start.sh`) runs the
  bootstrap in the background, gated on `CLAUDE_CODE_REMOTE` so it
  never touches a local gale/nix toolchain. New `docs/TOOLCHAIN.md`
  documents how to obtain Zig in every environment, which optional
  tool gates which `just` recipe, and the container caveats
  (blocked hosts, no OrbStack, running as root).
- **272 dormant unit tests across 21 `src/common` modules now
  actually run.** `src/common/lib.zig`'s force-import block listed
  5 of the 26 modules that carry tests. `zig test` collects tests
  only from the module under test, and within a module only from
  files reachable from the root — so a `pub const x =
  @import("x.zig")` the test binary never references is not
  reached, and every unlisted module's tests compiled into no
  binary at all. A dormant test reports no failure, so the suite
  looked green throughout. With the 30 tests added for the new lint
  below, the suite goes 2370 → 2672; the common binary alone goes
  131 → 433. `mode.zig` is the starkest case: 67 tests over
  symbolic mode parsing and the umask interaction, backing both
  `chmod` and `mkdir`, none of which had ever executed.

  This was the third recurrence — `path.zig` (#51) and
  `file_ops.zig` (#81) were each found dormant by accident while
  fixing something unrelated — so the sweep comes with a lint that
  fails the build if any `src/common/*.zig` containing a test is
  missing from the block. The lint lives in
  `src/common/force_import_lint.zig` but is *called* from a test in
  `lib.zig`, the test root, so dropping the module from the block
  cannot take the guard down with it. Both it and the issue-#5
  `writerStreaming` lint now resolve the source tree through a
  build-injected absolute path and fail rather than return when it
  cannot be opened; previously that lint passed vacuously whenever
  it ran from anywhere but the repo root. Those paths ride on a
  separate options module wired only into the three lib.zig-rooted
  test binaries, keeping a test-only concern off the options module
  every utility imports (#95).
- **`zig build test-integration` is wired into CI.** The step
  existed and rooted three test files, but nothing invoked it — not
  the justfile, not any workflow — so its 24 tests had never run
  (#95).
- **All three `src/common/lib.zig` test roots now link libc.** The
  `test-privileged` root did not, and escaped needing it only
  because its `privileged:` filter left libc-touching tests
  unanalyzed. `link_libc` is also behavioral, not merely a link
  flag: `env.getEnv` branches on `builtin.link_libc`, so the roots
  had been taking different environment-lookup paths (#95).
- **The `file_ops` unit tests actually run now.** `src/common/file_ops.zig`
  was missing from the force-import block in `src/common/lib.zig`, so
  every test in it — covering the copy leaf shared by `cp` and `mv` —
  had never executed, the same dormancy that previously hid `path.zig`'s
  coverage. Running them required libc on the common test module and
  fixed two `close` calls that had rotted past a signature change
  without anything noticing. `setPermissions`' unused directory branch
  was removed: `fchmod` on a directory descriptor returns `EBADF` on
  Linux, which is why the path-based `chmodPath` exists (#81).

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
