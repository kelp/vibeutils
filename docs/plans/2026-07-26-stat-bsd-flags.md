# stat: BSD/GNU Interface Resolution — Implementation Plan

Date: 2026-07-26
Issues: #93 (scope + decision), #79 (user-facing symptom)

## Decision Summary (settled in #93 — do not re-litigate)

1. GNU stays the primary interface, project-wide and for
   `stat`. No global spec-priority flip, no
   platform-conditional flag semantics, no packaging or
   naming changes.
2. Implement the 7 BSD flags whose letters GNU `stat` does
   not use: `-F -l -n -q -r -s -x`. They keep their MUST
   tier.
3. `-f format` and `-t timefmt` (the two colliding letters)
   are retiered MUST → WONT. `-f` stays GNU
   `--file-system`; `-t` stays GNU `--terse`. The BSD
   spellings are never getting BSD semantics here.
4. For `-f`/`-t`, documentation IS the deliverable: the
   divergence note must be reachable from `stat --help` and
   `man stat`, not only the spec matrix.
5. The `%`-sniffing heuristic for `-f` operands (#93 item 5,
   #79 option b) is explicitly OUT of scope. It is a
   separate decision; this plan proposes not doing it.

## Current State (verified against src/stat.zig @ 426e008)

- `src/stat.zig` (~2980 lines): manual arg parsing
  (`parseArgs`, `parseArgs_longOption`,
  `parseArgs_shortOption` at src/stat.zig:80-239), a
  cross-platform `StatResult` (src/stat.zig:247) populated
  by `statx` on Linux / `fstatat` on Darwin, GNU renderers
  (`printDefaultFormat`, `printTerseFormat`,
  `printFileSystemInfo`), a `%`-directive engine
  (`processFormatString` / `expandFormatDirective*`), and
  `processOnePath` (src/stat.zig:1364) dispatching per
  path. Help text at `printHelp` (src/stat.zig:1445).
- Existing flags: `-L -f -t -c -h -V` + long forms +
  `--printf`. All GNU semantics.
- `StatResult` already carries dev, ino, mode, nlink, uid,
  gid, rdev, size, blksize, blocks, and all four
  timestamps including birth time. Missing for BSD modes:
  `st_flags` (and possibly `st_gen`, see below).
- `docs/specs/stat-flags.md` lists the 9 BSD flags as
  unimplemented MUST.
- `man/man1/stat.1` documents only the GNU interface, no
  divergence note.
- Integration tests: `tests/utilities/stat_test.sh`.

### On #79's "exit 0" claim — verify first

Reading the current code, `stat -f '%m' /tmp/f` parses
`%m` as a positional; `printFileSystemInfo("%m")` fails
`statfs`, prints `cannot statfs '%m': ...`, and
`runStat` returns exit 1 (src/stat.zig:1371-1383,
1339-1359). That means the "wrong answer with exit 0" as
reported against 0.10.2 may already be partially fixed:
today a BSD-style invocation should fail loudly on the
format-string operand. Step 0 of the implementation is to
verify this on both platforms and pin it with an
integration test (nonzero exit + diagnostic mentioning the
`%...` operand). If it actually exits 0, that is a bug to
fix in Stage 2. GNU parity check: `stat -f %m file` under
GNU coreutils diagnoses `%m` and exits 1 while still
printing fs status for `file` — ours should match.

## Behavioral Reference

These flags exist only in BSD (macOS/OpenBSD), so per the
spec hierarchy the BSD spec governs their semantics.
Reference: `/usr/bin/stat` on macOS (available locally on
the dev Mac and on the `macos-latest` CI runner) and the
FreeBSD/macOS stat(1) man page. GNU coreutils has none of
these letters, so there is no GNU behavior to match.

**Red-phase agents must pin exact expected output by
running `/usr/bin/stat` on macOS** rather than trusting
this plan's from-memory sketches below.

### Flag semantics (BSD stat(1))

| Flag | Meaning |
|------|---------|
| `-n` | Do not force a newline after each piece of output |
| `-q` | Suppress error messages on failed stat/lstat calls (exit status still nonzero) |
| `-r` | Raw mode: numeric fields, times as epoch seconds |
| `-s` | Shell mode: `st_dev=... st_ino=... ...` eval-able assignments |
| `-l` | `ls -lT`-style line: mode string, links, owner, group, size, mtime, name |
| `-x` | Verbose multi-line display (Linux-`stat`-ish block) |
| `-F` | Type suffixes (`/` `*` `@` `=` `|`) on names, symlinks as `link -> target`; implies `-l` |

Mode selection is **mutually exclusive and diagnosed**, not
last-one-wins. From FreeBSD `usr.bin/stat/stat.c`:

```c
case 'f': statfmt = optarg;  /* FALLTHROUGH */
case 'l': case 'r': case 's': case 'x':
    if (fmtchar != 0)
        errx(1, "can't use format '%c' with '%c'", fmtchar, ch);
    fmtchar = ch;
```

So two of `-l -r -s -x` is a hard error, exit 1:
`stat: can't use format 'l' with 'r'`.

`-F` sets only `lsF`. Afterwards, if no mode flag was given
it selects `l`; and `if (lsF && fmtchar != 'l')` is an
error. So `-F` alone and `-F -l` both render LSF_FORMAT,
while `-F -r` exits 1. The fall-through in the source is
`-f` falling into the mutual-exclusion check — it is not
`-F` implying `-l`.

> Corrected 2026-07-26 against the FreeBSD source. The
> first draft of this plan claimed "last one wins" and that
> `-F`'s suffix persists across a later mode flag; both were
> wrong, and were written from memory rather than the spec.

### Cross-interface combinations

Combining a BSD display mode (`-l -r -s -x -F`) with a GNU
output selector (`-c/--format`, `--printf`, `-t/--terse`,
`-f/--file-system`) is defined by no spec. Per the
"no silent degradation" rule, diagnose it:

```
stat: cannot combine BSD display option '-l' with '--format'
Try 'stat --help' for more information.
```

exit `ExitCode.misuse`. `-n`, `-q`, and `-L` are
independent toggles and combine with everything.

`-n` applies to every output mode including `-c` (BSD `-n`
modifies `-f` output the same way): it suppresses the
newline that terminates each file's output record. For
multi-line modes (`-x`, GNU default, `--file-system`) that
is the final trailing newline.

## Implementation Stages

Ship as two PRs: **PR A (docs only, Stage 1)** can land
immediately and closes the `-f`/`-t` half of #79.
**PR B (code, Stages 2-6)** delivers the seven flags.
Within PR B, each stage is a red/green commit pair
following the repo's TDD discipline (separate test-writer
and implementer agents; RED verified on macOS AND Linux
via `orb -m ubuntu` before GREEN).

### Stage 1 — Documentation (PR A)

1. `docs/specs/stat-flags.md`:
   - Retier `-f format` and `-t timefmt` to WONT, with a
     one-line inline rationale each (letter collision with
     GNU; `-c FORMAT` / no equivalent respectively).
   - Expand the preamble: state the interface choice
     (GNU primary, 7 BSD flags adopted, 2 declined), and
     point at `man vstat` for the user-facing note.
2. `printHelp` (src/stat.zig:1445): append a short note
   after the format-sequence table, e.g.:

   ```
   NOTE: This stat uses the GNU interface. On BSD/macOS,
   -f and -t mean different things: BSD 'stat -f FORMAT'
   is 'stat -c FORMAT' here; BSD 'stat -t TIMEFMT' has no
   equivalent. Here -f is --file-system, -t is --terse.
   ```

   (This is the one code-file edit in PR A; it is a string
   change with an accompanying help-output test update.)
3. `man/man1/stat.1`: add a CAVEATS section documenting
   the divergence with the same BSD→GNU mapping, and note
   it early in DESCRIPTION. `mandoc -T lint` clean.
4. Comment on #79 pointing at the shipped note (the issue
   is closed by the combination of PR A + the Stage 2
   exit-code test).

### Stage 2 — `-n`, `-q` + #79 exit-code pin (PR B start)

Small and independent; no new renderer machinery.

- Parsing: add `no_newline: bool`, `quiet: bool` to
  `StatOptions`; wire `'n'`/`'q'` into
  `parseArgs_shortOption`.
- `-q`: in `processOnePath`, skip both
  `printErrorWithProgram` calls when quiet; still return
  `true` so the exit code stays nonzero.
- `-n`: restructure `processOnePath` so the trailing
  newline of each record is appended centrally and skipped
  when `no_newline` (today `-c` appends `'\n'` inline at
  src/stat.zig:1414; the GNU default/terse/fs renderers end
  with their own `'\n'` — have them emit the final newline
  via the central path).
- Tests: behavioral, not parse-only. `-n` → `wc -c`
  comparison / no trailing newline; `-q` → empty stderr +
  exit 1 on missing file; and the Step-0 pin:
  `stat -f '%m' FILE` exits 1 with a diagnostic naming
  `%m` (this is the #79 regression guard).

### Stage 3 — BSD field plumbing + `-r` (raw)

`-r` is the simplest whole-record mode and forces the
field plumbing everything else reuses.

- `StatResult`: add `flags: u32` (Darwin:
  `stat_buf.flags`; Linux: 0 — statx has no BSD
  st_flags). Add `gen: u32` only if the pinned macOS
  reference output for `-s`/`-r` includes `st_gen`
  (Darwin `stat_buf.gen`; Linux 0).
- **Drive-by correctness check (macOS pitfall)**:
  `doStat_darwin` uses `@intCast(stat_buf.dev)`
  (src/stat.zig:345). Per the repo's known devfs failure
  class (6b97443: signed `st_dev` with high bit set traps
  `@intCast`), switch dev/rdev to the `@bitCast`-then-widen
  pattern and add a macOS test statting a devfs node
  (`/dev/null`).
- New renderer section `printBsdRawFormat`: one line per
  file, numeric fields, epoch times, ends via the central
  newline path. Exact field list/order pinned from
  `/usr/bin/stat -r` on macOS.
- Parsing: add
  `bsd_mode: enum { none, ls, raw, shell, verbose }` to
  `StatOptions`. Setting a mode when one is already set is
  an error (`can't use format 'X' with 'Y'`), and `-F` with
  any mode other than `ls` is an error
  (`can't use format 'X' with -F`). Plus the
  cross-interface conflict diagnostic (checked once after
  parsing, in `runStat`).

### Stage 4 — `-s` (shell mode)

- `printBsdShellFormat`: `st_dev=... st_ino=...`
  assignments, exactly the fields and order macOS emits
  (pin whether the file name is included — FreeBSD/macOS
  omit it). Values must be eval-safe
  (`eval $(vstat -s file)` works in sh).

### Stage 5 — `-l` and `-F`

- `printBsdLsFormat`: `ls -lT`-shaped line reusing
  `formatPermissions` and the existing user/group-name
  helpers (`expandFormatDirective_userName`/`_groupName`;
  extract shared lookup helpers if needed — mind the
  static-libc-buffer pitfall: copy strings out
  immediately). New time helper for the
  `%b %e %H:%M:%S %Y` shape (C-locale month names,
  space-padded day; build on `common.time.localtime_r`
  like `formatTimestamp`).
- `-F`: `type_suffix` bool on `StatOptions`; `'F'` sets it
  AND sets `bsd_mode = .ls`. Suffix selection from mode
  bits (`/` dir, `*` exec regular, `@` symlink, `=`
  socket, `|` fifo); symlinks render `name -> target`
  (readlink; the utility already links against the common
  lib — pin exact BSD behavior for `-F` + `-L`
  combinations).

### Stage 6 — `-x` (verbose)

- `printBsdVerboseFormat`: multi-line block (File/Size/
  FileType/Mode/Uid/Gid/Device/Inode/Links/Access/Modify/
  Change/Birth), ctime-style times
  (`%a %b %e %H:%M:%S %Y`). Pin exact spacing from macOS
  output — this mode is the fussiest to match.

### Stage 7 — Close-out

- `docs/specs/stat-flags.md`: flip Ours to `yes` for the
  seven flags.
- `man/man1/stat.1` + `printHelp`: document all seven
  flags (short-only; no long forms — BSD defines none, do
  not invent them).
- `CHANGELOG.md` `## Unreleased`: Added bullets for the
  seven flags; Fixed/Changed bullet for the divergence
  documentation.
- Close #79 and #93 via PR description keywords.
- File the deferred decision (diagnosing `-f` operands
  that look like BSD format strings) as its own issue so
  #93 item 5 has a tracking home.

## Testing Plan

- **Unit tests** embedded in `src/stat.zig` per repo
  pattern (drive `runStat` with fixed writers): parsing
  (last-one-wins, `-F` implies `-l`, conflict diagnostics,
  cluster forms like `-rn`), and renderer behavior against
  a scratch file (field counts, octal mode, epoch times
  numeric, `st_*=` keys present, suffix chars).
- **Integration tests** in `tests/utilities/stat_test.sh`,
  behavioral per flag (required by the flag-matrix policy):
  - On macOS, compare directly against `/usr/bin/stat`
    output for the same scratch file (`-r`, `-s`, `-l`,
    `-x`, `-F`) — the CI macOS runner ships BSD stat, so
    this is a free oracle. Normalize nothing; the point is
    exact parity.
  - On Linux, structural assertions (no BSD oracle
    exists): field counts for `-r`, `st_flags=0` accepted,
    `eval`-ability for `-s`, `-n` newline suppression via
    byte count, `-q` stderr emptiness.
  - Use `run_with_limit`, never `timeout(1)` (macOS CI).
- **TDD discipline**: per stage, test-writer and
  implementer are separate agents; RED verified for the
  right reason on macOS and Linux (`orb -m ubuntu`) before
  the fix lands; full `zig build test` + `just it` on both
  platforms before each push. The repo's `tdd-bugfix`
  skill fits Stage 2; `tdd-pipeline` fits Stages 3-6.
- **Tiger check** (`/tiger-style:tiger-check`) after each
  stage: renderers must stay ≤70 lines (split per-line
  helpers as the existing `printDefaultFormat_*` functions
  do), ≥2 asserts per function, explicitly sized ints.

## Zig 0.16 / Repo Pitfalls to Respect

- Check `docs/ZIG_BREAKING_CHANGES.md` before writing any
  code; `std.mem.indexOf*` → `find*`, `std.fs.*` →
  `std.Io.*`, etc.
- The `writerStreaming` lint in `src/common/lib.zig` —
  don't introduce `.stdout().writer(`.
- macOS: `@bitCast` for possibly-signed stat fields
  (Stage 3 drive-by); copy strings out of
  `getpwuid`/`getgrgid` static buffers before the next
  libc call.
- All commits signed; pre-commit hook requires clean
  `zig fmt`.

## Acceptance Criteria (mirrors #93 work items)

- [x] `-f format` / `-t timefmt` retiered WONT with
      rationale in `docs/specs/stat-flags.md`
- [x] Matrix preamble states the interface choice
- [x] `stat --help` surfaces the BSD divergence note
- [x] `man/man1/stat.1` documents it; `mandoc -T lint`
      clean
- [x] `-n`, `-q` implemented with behavioral tests
- [x] `stat -f '%m' FILE` proven to exit nonzero with a
      diagnostic (integration test). NOTE: this already
      held before the change — #79's reported "exit 0"
      does not reproduce on current main, so the test is a
      regression pin, not a fix.
- [x] `-r`, `-s`, `-l`, `-x`, `-F` implemented over shared
      BSD field plumbing. Corrected from the original
      wording: mode selection is mutually exclusive and
      diagnosed, NOT last-one-wins, and `-F` combines only
      with `-l` rather than implying it unconditionally.
- [x] Cross-interface combos diagnosed as misuse
- [x] macOS integration tests compare against
      `/usr/bin/stat`; Linux tests structural
- [x] Linux suites green (unit 2304/2359, integration 70
      pass / 1 skip). macOS parity is verified by CI, which
      is the only BSD oracle available.
- [ ] #79 closed with the documented outcome; follow-up
      issue filed for the `-f` operand diagnosis decision
      — left for the repo owner; both are outward-facing
      actions on the tracker.

## Unplanned work that landed with this

- **Fixed a pre-existing device-number bug on Linux.**
  `doStat_linux` packed `st_dev` as `(major << 32) | minor`,
  so `stat -c %d` printed 1090921693184 against GNU's
  65024, `%D` printed `fe00000000` against `fe00`, and the
  default `Device:` line printed `0,0` against `254,0`.
  Not in the original plan; found while scoping the raw
  mode, which prints `st_dev` and could not have been
  correct without it. The existing Device-line test missed
  it because it only asserted the line was not in the old
  format and never checked the values.
