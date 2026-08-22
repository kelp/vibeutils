# FIX.md — audit findings ledger

Findings from the audit sweep, and what happened to each. The
method lives in `docs/AUDIT_SWEEP.md`; this file is only the
record.

Marks: ✅ fixed · ⏸ routed, owned by another unit · ❌ rejected,
with the reason · 🔄 in flight

## In flight

Units claimed by a running fleet. The drive lead is the only
writer, so parallel worktrees never conflict here; the contract is
in the `fleet-lead` skill. A unit leaves this table when it lands,
and its result goes to **Status** below.

`Agent` is the SendMessage address and stays stable across a
restart. `Heartbeat` is UTC, minute precision, written by the
drive lead. Two missed intervals means the unit is presumed dead.

| Unit | Lead | Agent | Worktree | Phase | Heartbeat |
|---|---|---|---|---|---|
| _none_ | | | | | |

## Status

| Unit | Audited | Fixed | Notes |
|---|---|---|---|
| whoami | ✅ | ✅ | 3 code fixes, 5 RED tests, oracle repaired |
| df | ✅ | ✅ | `--output` built as a feature; 6 dead helpers deleted |

## Cross-cutting

Findings that are repo-wide rather than owned by one utility.
Fixing this class per-utility makes the codebase less consistent,
not more, so each was resolved once or is still awaiting a ruling.
Unmarked entries are open.

- ✅ **Argument errors exited 2; every reference exits 1.**
  Resolved. POSIX 2024 mandates no number ("exit with an exit
  status that indicates an error occurred"); OpenBSD source uses
  `exit(1)` throughout with only `usr.bin/sort/sort.c:967` at 2;
  GNU and macOS measured per-utility. `misuse = 2` was both
  mis-valued and misnamed — "misuse of shell builtins" is bash's
  convention and coreutils has no such concept. Replaced by
  `general_error = 1`, `serious_error = 2` (ls, sort, grep,
  test/`[`, which reserve 1 for a non-error outcome) and
  `internal_error = 125` (env, timeout, which reserve 126/127 for
  the child command). 38 utilities changed behavior.
- **`src/common/argparse.zig:548` drops the offending flag name.**
  We print `whoami: unrecognized option`; GNU prints
  `whoami: unrecognized option '--invalid-flag'` plus the hint
  line. Shared by every utility.
- **`src/common/argparse.zig:79-88` rejects unambiguous long-option
  abbreviations** that GNU `getopt_long` accepts. Affects all 47
  units.
- **`src/common/user_group.zig:6`** — the `c_passwd` extern struct
  declares the glibc layout unconditionally.
- ✅ **`free -c N` was rejected without `-s`.** Fixed. procps
  repeats N times with an implied one-second interval, paying the
  interval only *between* reports, so `free -c 1` returns
  immediately (measured: 0.001s versus 1.001s for `-c 2`).
  Reports are separated by one blank line with no trailing blank.
  Our help text documented the wrong constraint too.
- ✅ **`printf` with no operands printed the wrong diagnostic.**
  Fixed. Now emits `printf: missing operand` plus the
  `Try 'printf --help' for more information.` hint, matching GNU.
- ✅ **`scripts/tiger-check.sh` printed `new=0` for a value it had
  not computed.** Fixed. `NEW` is only meaningful in `--base` and
  `--staged` mode, which have a baseline; without one the script
  printed 0 anyway. Its *exit code* was always correct — verified
  by injecting a 110-column line, which produced
  `SUMMARY total=1 new=0` and exit 1 — but two readers in a row,
  an agent and me, read the summary text and concluded the gate
  had passed. The non-diff modes now print `new=n/a`. An
  uncomputed value must not render as a reassuring one.
- **`scripts/tiger-check.sh` also misclassifies violations in
  `--base`/`--staged` mode.** A separate bug: the NEW/PRE split
  keys on a function's *declaration* line, so growing a body past
  the 70-line limit without touching the signature reports as
  `PRE`. Caught live: `runDf` grew from under 70 to 77 lines and
  was reported `PRE`.
- **`zig-out/bin` is shared between the macOS host and the
  OrbStack VM.** A background `zig build` in either environment
  rewrites the binaries a concurrent `tests/integration.sh` run is
  executing, producing failures that do not reproduce. Observed
  twice, on `mkdir` both times. Never run a build concurrently
  with the integration suite.

## whoami

Fixed. Tests by one agent, implementation by another, RED verified
on macOS and Linux before the fix, GREEN after.

- ✅ `src/whoami.zig:70` — resolved the REAL uid via
  `getCurrentUserId()` (`getuid()`), while its own help text and
  GNU both define the output as the EFFECTIVE user ID, the
  identity `id -un` prints. Now `geteuid()`. The shared helper
  keeps real-uid semantics for chown, stat and id.
- ✅ `tests/utilities/whoami_test.sh:21` — **the reason the above
  survived.** The oracle was `expected=$(whoami)`, and
  `tests/integration.sh:24` pins PATH to `zig-out/bin`, so it
  compared the binary to itself. Demonstrated: against a build
  printing the wrong user, the old file passed 7/7. Now compares
  against `/usr/bin/id -un`.
- ✅ `src/whoami.zig:59-65` — the extra-operand error dropped
  GNU's `Try 'whoami --help' for more information.` line that 14
  other vibeutils utilities emit.
- ✅ `src/whoami.zig:36-53` — `--help` and `--version` were not
  resolved in command-line order; help always won. GNU acts on
  whichever appears first, verified empirically.
- ✅ Test hygiene — unanchored `--help`/`--version` matches
  tightened to exact equality; `--`, bare `-` and `""` operands
  covered; duplicate cases folded.
- ❌ `src/whoami.zig:66` — exit codes claimed wrong, dropped at
  cross-check: they are already correct for our convention.
- ❌ Claimed help-before-version ordering gap — not what the code
  does.

**Ceiling on the uid fix, stated honestly:** real and effective
uid can only be diverged by a set-user-ID binary executed by root.
`fakeroot` reports `uid=0 euid=0`, and
`unshare --user --map-root-user` maps both identically, so neither
works. The setuid integration test is a real guard for root runs
but **skips on CI**. The unit companion is GREEN either way and
says so in a comment.

## df

Three flags were parsed and never read, and in every case the
guarding test asserted the parsed struct field instead of the
program's output, so the suite stayed green while the flag did
nothing. That single pattern produced every df finding.

**State: GREEN.** 170 pass / 6 skip / 0 fail of 176, from a 24-RED
starting point against a 138 pass / 0 fail baseline. Linux via
`orb -m ubuntu`: 166 pass / 10 skip / 0 fail. Integration 23/23.

The test/implementation separation was verified mechanically, not
assumed: the test author extracted every `test` block from a
snapshot of its own authored state and from the final file, then
compared name→body maps. 0 missing, 0 renamed, 0 added by the
implementer, and the single changed body was the author's own
strengthening. `testExpectTokens` still rejects extra tokens, so
no assertion was relaxed to a prefix match.

- ✅ `src/df.zig:110,428` — `-I` stored in `opts.suppress_inodes`,
  read by no renderer. `df -i -I /` still printed the inode
  columns; BSD resolves last-flag-wins. The guard at `:4123`
  named the real check in a comment and then asserted only
  `exit == 0`.
- ✅ `src/df.zig:108,301,304` — `--output` stored in
  `opts.output_fields`, read by no renderer.
  `df --output=source,size /` was byte-identical to bare `df /`.
  Larger than recorded: our bare `--output` default list has 7
  fields, GNU's has all 12, and GNU makes `--output` mutually
  exclusive with `-i`, `-P` and `-T` where we accepted all three.
- ✅ `src/df.zig:2491` — `printHeader` / `printFsRow` /
  `printTotal` are reachable only through `runDf_renderInodes`,
  which opens `std.debug.assert(opts.inodes)`, so their non-inode
  branches are dead. Nine tests exercised them. Proven three ways,
  including replacing the `"Filesystem"` literal in both arms with
  `"SABOTAGE"` and observing `df /`, `df -P /`, `df -T --total /`
  and `df -i /` print byte-identical output.
- ✅ `src/df.zig:2035` — prints `Avail` unconditionally; GNU uses
  `Avail` only in human mode and `Available` in **every** block
  mode, POSIX or not, so `df -k` and `df --block-size=` diverge
  too. The correct conditional is
  `if (opts.human_readable or opts.si)`, not
  `if (opts.portability)` — a portability-keyed fix passes the
  `-P` test and leaves `df -k` broken, so the `-k` case is pinned
  separately. **The dead code had this right.** Deleting it
  without fixing the live path would have made the divergence
  permanent and untested.
- ⏸ `src/df.zig:2003` — for odd non-POSIX block sizes our label
  is `{d}B-blocks` where GNU abbreviates (`2kB-blocks` for
  `--block-size=2000`). Recorded, not fixed.
- ✅ `src/df.zig:2011` — `df -P -h` keeps the POSIX header set;
  GNU switches to `Size`/`Avail`/`Use%` whenever a human-readable
  mode is active. `-H` behaves the same, so the fix cannot be
  special-cased to `-h`.
- ✅ `src/df.zig:2003` — `df -P --block-size=1M` prints
  `1M-blocks`; GNU prints `1048576-blocks`.
- ✅ `src/df.zig:2720` — help documents `-I TYPE` unconditionally,
  but on darwin `-I` is a boolean.
- ✅ `tests/utilities/df_test.sh:51` — `df /` asserted with
  `[[ "$output" =~ "/" ]]`. Every df line contains a `/`;
  demonstrated to pass against all 16 lines of the mount table.
- ✅ `src/df.zig:3577` — "printHeader - color mode no Usage
  column" was byte-identical to the plain test above it and never
  enabled color. Deleted: `printHeader` takes no style parameter,
  so it has no color behavior to test.
- ❌ `human_readable = true` is **not** a bug. `printHelp:2707`
  says "Displays human-readable sizes by default", `-h` is
  labeled "(default)", and `docs/DESIGN_PHILOSOPHY.md:58` lists it
  as a vibeutils enhancement. GNU defaults to 1K blocks; this is a
  documented, intentional divergence. The finding was that no test
  could distinguish `-h` from the default, which is now fixed.
- ❌ `-h -P` ordering is **not** a divergence to fix. GNU never
  lets `-P` clear human mode, but GNU defaults to block mode.
  Because we default to human, `-P` must clear it or bare `df -P`
  is useless to POSIX consumers. Only the `-P -h` direction was
  broken.

**Ruling on `--output` and decoration:** `--output` controls WHICH
columns appear; the style system controls HOW they render. No
Usage column or bar is injected, because the user enumerated the
fields they want. Color and icons still apply to the selected
columns, gated on `isTty()`.

## Method note

Every finding above was demonstrated before it was fixed: bugs by
running the real GNU utility and capturing output, test defects by
mutating the implementation and observing whether the test
noticed, dead code by deleting it and confirming the build and
suite still passed. Findings that could not be demonstrated were
dropped. That gate, not the volume of review, is what makes this
list trustworthy — see `docs/AUDIT_SWEEP.md` for the cost
evidence.
