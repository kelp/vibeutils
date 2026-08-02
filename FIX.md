# FIX.md — per-utility audit and fix sweep

Every utility gets five Opus lenses and five Codex lenses over its
tests, then the same over its implementation, a consensus round, a
Fable judge on deadlock, and a red-green fix.

Driver: `.claude/workflows/fix-it-all.js`. Three invocations per
wave — `audit`, `red`, `green` — with a signed commit between
each, because workflows never commit.

This file is written by the orchestrator, never by an agent, so
parallel worktrees cannot conflict on it.

## Protocol

**Audit.** Read-only finders per target: five Opus lenses and five
Codex lenses driven through `codex exec`, plus — on the code side
of any utility — a mechanical differential tester that builds our
binary and GNU's and diffs stdout, stderr, and exit code across
flag combinations and input edge cases inside the Linux VM. A
divergence becomes a finding with a runnable reproducer attached,
which is the strongest evidence this sweep produces.

The whole round then **repeats until it goes dry**: each round is
handed every finding already surfaced and told to find what those
rounds missed. A unit is done only after two consecutive rounds
find nothing new, with a 20-round backstop against a pathological
loop. The backstop started at eight and was raised when `S0` ran
all eight productive rounds without ever going twice-dry — it was
truncating real discovery, not noise. Deduplication is against
everything ever *seen*, not against what was confirmed — dedup
against the confirmed set would resurface every refuted finding
each round and the loop would never terminate.

Per round: a merge agent sorts findings into *agreed* (both
families), *opus-only*, and *codex-only*. Each family cross-checks
the other's one-sided findings, returning CONFIRM, REJECT, or
DISPUTE. **Agreed findings are not trusted either** — three
adversarial refuters attack them from distinct angles (does it
reproduce, is it actually wrong, is the proposed fix safe), each
told to default to refuted when uncertain. A majority kills the
finding; a split panel sends it to the judge. Two models agreeing
is not proof, and a bad finding acted on becomes a bad test and
then a bad change to real code.

Anything still contested goes to a Fable judge, which reads the
code rather than arbitrating between the written positions. Its
ruling is binding.

**Nothing is fixed until it is demonstrated.** Every survivor goes
to an agent that did not find it and must be shown to be real —
not argued to be real. What counts as a demonstration depends on
what is claimed:

| Kind | Obligation |
|---|---|
| `bug` | Run it. Build the fixtures, run our binary, run the real GNU utility on the Linux VM with `LC_ALL=C`/`TZ=UTC` pinned, and capture all three channels verbatim. `expected` must come from a command that was run, never from memory. |
| `test_defect` | Sabotage. Mutate the implementation to break what the test guards; if the test still passes it has no teeth. Revert. If it *does* fail, the finding is wrong. |
| `missing_test` | Search. Show the behavior happens, then show nothing asserts it. |
| `dead_code` | Delete it. Grep for every reference, then actually remove the symbol and confirm the build and full suite still pass. Revert. If anything fails, the code is live. |
| `duplication` | **None.** No experiment shows two similar functions ought to be one. |

A finding that cannot be demonstrated is **quarantined**, not
fixed and not silently dropped — it stays in the ledger for human
review. Losing a marginal finding is cheaper than acting on a
false one, and the discovery loop resurfaces anything genuinely
real on a later round.

`duplication` is the one class with no fact to establish, so it
gets a judgement gate instead, bound by the project's own stated
bias: *a little copying is better than a little dependency*, and
*do not refactor beyond what the task requires*. The default
answer is no. It says yes when merging makes the code better
today — most often when one copy is demonstrably more correct, as
with the hand-rolled traversals that shipped data-loss bugs the
shared walker does not have. It says no when the shared version
would need a flag or a branch per caller, which is the usual
reason two similar functions should stay two.

Tests are audited before the implementation, and the test audit's
coverage gaps seed the code audit: untested paths are where bugs
survive.

**Shared code goes first.** A defect in `argparse` or the `walker`
is a defect in every utility at once. Auditing 47 utilities
against broken foundations wastes those audits and risks baking
the shared defect into 47 new test files — `whoami` alone surfaced
a CRITICAL in `argparse`. The seventeen shared waves therefore run
before any utility wave, and **again afterwards** (ids
`S0b`–`S16b`), because the utility fixes add new callers and new
duplication.

**Red.** The test-writer fixes the test defects, adds the missing
tests, and writes a failing test for every agreed bug. A red check
proves each fails *for the right reason* — the assertion matching
the bug, not a compile error or a skip — on macOS and Linux.
Dead-code and approved-duplication findings are
behavior-preserving, so they get characterization tests proven by
transient sabotage instead.
Findings that carry a `corpus_input` also get that content written
under `tests/fuzz/<util>/corpus/`, so every divergence found
becomes a permanent regression fixture outliving this sweep.

**Green.** The implementer makes the minimal fix. It may never
edit a test; when a test genuinely needs to change it routes back
to the test-writer, which judges first and may refuse. Gates:
scoped unit + scoped integration + `fmt-check` per iteration,
then `tiger-check`, then a read-only code review, then an
independent Codex review of the diff with bounded rebuttal and the
judge on deadlock, then the authoritative full run — full unit,
full privileged, and *full* integration on macOS plus full unit
and scoped integration on Linux.

**Deferred.** A finding whose fix reaches into another unit cannot
be applied inside this unit's worktree without two of them
colliding on one file. Those are routed to the owning unit's wave
rather than fixed in place.

**Teardown is mandatory, not tidiness.** Every worktree
accumulates a `.zig-cache` of 1.3–3.6 GB, and OrbStack mounts
`/Users` from the host, so those bytes are charged to the host and
the VM at once. At roughly 3 GB per unit across 63 waves the sweep
would need something like 300 GB if nothing were reclaimed, on a
host that ran out of headroom at 97% during wave `S0`. So after a
wave's green commit merges back, remove its worktrees:

```
git worktree remove --force /Users/tcole/code/vibeutils-fix-<slug>
git branch -D fix/sweep-<slug>
```

Never remove a worktree whose wave is still running — the agents
hold it as their working directory. Check for a live run first.

## Wave status

### Shared code — `src/common/`, swept first

A defect here is a defect in every utility that imports the
module. These waves have no scoped gate: the common test binary
has no per-module filter and the blast radius is the whole tree,
so every iteration runs the full suites. That is the real cost of
touching shared code.

| Wave | Modules | Lines | Why here | Audit | Red | Green |
|---|---|---|---|---|---|---|
| S0 | argparse | 1142 | every utility parses args through it; already has a known CRITICAL | 🔄 | ⬜ | ⬜ |
| S1 | walker | 2270 | 8 utilities traverse through it; history of data-loss bugs | ⬜ | ⬜ | ⬜ |
| S2 | file_ops, file | 1512 | file primitives | ⬜ | ⬜ | ⬜ |
| S3 | directory, path | 739 | directory and path handling | ⬜ | ⬜ | ⬜ |
| S4 | mode, user_group | 1253 | permissions and identity | ⬜ | ⬜ | ⬜ |
| S5 | glob, env | 357 | globbing and environment | ⬜ | ⬜ | ⬜ |
| S6 | constants, format | 357 | shared constants and formatting | ⬜ | ⬜ | ⬜ |
| S7 | help, prompt | 968 | user-facing output plumbing | ⬜ | ⬜ | ⬜ |
| S8 | main, lib | 1077 | entry points and the library root | ⬜ | ⬜ | ⬜ |
| S9 | icons, unicode | 2053 | glyphs and width computation | ⬜ | ⬜ | ⬜ |
| S10 | display_config, style | 694 | display configuration and styling | ⬜ | ⬜ | ⬜ |
| S11 | colors, terminal | 268 | color and terminal capability detection | ⬜ | ⬜ | ⬜ |
| S12 | time, relative_date | 714 | time formatting | ⬜ | ⬜ | ⬜ |
| S13 | git, force_import_lint | 1189 | repository state and the dormant-test lint | ⬜ | ⬜ | ⬜ |
| S14 | test_utils, test_utils_privilege | 777 | test infrastructure; this repo has shipped 272 dormant tests | ⬜ | ⬜ | ⬜ |
| S15 | test_dir, privilege_test | 417 | test fixtures and the privilege harness | ⬜ | ⬜ | ⬜ |
| S16 | privilege_test_integration | 283 | the privilege integration harness | ⬜ | ⬜ | ⬜ |

31 modules, 16030 lines, complete coverage of `src/common/`.

### Utilities

| Wave | Utilities | Lines | Audit | Red | Green |
|---|---|---|---|---|---|
| U0 | whoami, true | 394 | ⬜ | ⬜ | ⬜ |
| U1 | false, free | 1406 | ⬜ | ⬜ | ⬜ |
| U2 | df | 4229 | ⬜ | ⬜ | ⬜ |
| U3 | du | 4052 | ⬜ | ⬜ | ⬜ |
| U4 | dd | 4156 | ⬜ | ⬜ | ⬜ |
| U5 | sort, seq | 4093 | ⬜ | ⬜ | ⬜ |
| U6 | id, nl | 3647 | ⬜ | ⬜ | ⬜ |
| U7 | tr, cut | 3347 | ⬜ | ⬜ | ⬜ |
| U8 | date, timeout | 2870 | ⬜ | ⬜ | ⬜ |
| U9 | uniq, tac | 1991 | ⬜ | ⬜ | ⬜ |
| U10 | env, realpath | 3626 | ⬜ | ⬜ | ⬜ |
| U11 | readlink, mktemp | 2375 | ⬜ | ⬜ | ⬜ |
| U12 | find | 9178 | ⬜ | ⬜ | ⬜ |
| U13 | stat | 6292 | ⬜ | ⬜ | ⬜ |
| U14 | printf, test/`[` | 4899 | ⬜ | ⬜ | ⬜ |
| U15 | ls | 8378 | ⬜ | ⬜ | ⬜ |
| U16 | cp | 5364 | ⬜ | ⬜ | ⬜ |
| U17 | grep | 5149 | ⬜ | ⬜ | ⬜ |
| U18 | mv | 3280 | ⬜ | ⬜ | ⬜ |
| U19 | chmod | 3267 | ⬜ | ⬜ | ⬜ |
| U20 | chown, rm | 5047 | ⬜ | ⬜ | ⬜ |
| U21 | rmdir, mkdir | 1563 | ⬜ | ⬜ | ⬜ |
| U22 | ln, touch | 3568 | ⬜ | ⬜ | ⬜ |
| U23 | tail, head | 3978 | ⬜ | ⬜ | ⬜ |
| U24 | wc, cat | 2262 | ⬜ | ⬜ | ⬜ |
| U25 | tee, sleep | 1337 | ⬜ | ⬜ | ⬜ |
| U26 | echo, yes | 1256 | ⬜ | ⬜ | ⬜ |
| U27 | basename, dirname | 1082 | ⬜ | ⬜ | ⬜ |
| U28 | pwd | 458 | ⬜ | ⬜ | ⬜ |

47 utility units, covering all 48 entries in `build/utils.zig`
(`test` and `[` share `src/test.zig` and are one unit).

Ordering is still by implementation-size-to-test-coverage gap.
`U0`–`U1` calibrate cheaply; `U2`–`U4` are the worst gaps (`df` is
4228 source lines against 26 integration assertions, `du` 4051
against 43). Anything over ~3000 lines runs alone.

### Shared code, re-swept

Waves `S0b`–`S16b` re-run every shared module after the utilities
are done. The utility fixes add callers, add duplication, and
change how the shared modules are used, so the first sweep's
conclusions expire.

| Wave | Audit | Red | Green |
|---|---|---|---|
| S0b–S16b | ⬜ | ⬜ | ⬜ |

**63 waves total**, none wider than two units — a wave's width is
a disk reservation, not just a concurrency setting, since every
unit gets a worktree carrying gigabytes of build cache.

Legend: A = agreed by both model families,
D = dropped at cross-check or by the refuters, J = decided by the
judge. Marks: ⬜ pending, 🔄 in flight, ✅ committed, ⚠️ committed
with a caveat recorded below.

## Findings

One section per utility as its wave completes. Negative results
stay in the record: a finding the judge rejected is as useful to
know about as one it upheld, and re-litigating it later wastes a
wave.

Format:

```markdown
### <util>
- audit `<sha>` — N agreed (T test, C code), D dropped, J judged,
  X deferred; codex lenses ok: 5/5 tests, 5/5 code
- red   `<sha>` — N tests written, M fixed; RED proven on macOS
  and Linux
- green `<sha>` — N fixes; codex found K, J upheld; full suites
  green on both platforms
- findings
  - ✅ C2-3 `src/<u>.zig:1902` — <what was wrong>
        repro: `<exact command>` → observed `<...>`, expected
        `<...>` (pinned by `orb -m ubuntu <u> ...`), confirmed on
        macOS + Linux
  - ✅ T1-1 `tests/utilities/<u>_test.sh:44` — <what was wrong>
        repro: sabotage `<mutation>` → test still passed
  - ✅ C5-1 `src/<u>.zig:220` — dead code, <symbol>
        repro: deleted it, build and full suite still green
  - ❓ C1-4 `src/<u>.zig:77` — QUARANTINED, could not be
    demonstrated: <what was tried and why it did not reproduce>
  - ❌ C4-1 `src/<u>.zig:88` — judge REJECT: <why, with the
    file:line that refutes it>
  - ❌ C6-2 `src/<u>.zig:400` — duplication declined: <why the
    shared version would need a flag per caller>
  - ⏸ C3-2 `src/common/mode.zig:210` — routed to wave S3
  - 🚫 T4-6 — test-writer refused: <why the finding was wrong>
```

Marks: ✅ demonstrated and queued for fixing, ❓ quarantined
(real-looking but never demonstrated), ❌ rejected, ⏸ routed to
another wave, 🚫 refused by the test-writer.

### whoami

- audit `(uncommitted)` — 11 agreed (6 test-side, 5 code-side),
  2 dropped at cross-check, 0 judged, 6 deferred cross-cutting.
  Codex lenses ok: 5/5 tests, 5/5 code. Raw before merge: opus 35,
  codex 15, 14 duplicates collapsed.
- red `⬜`
- green `⬜`
- findings
  - ✅ C4-1 / T1-3 `src/whoami.zig:70` — **CRITICAL.** whoami
    resolves the REAL uid, not the effective uid. It calls
    `common.user_group.getCurrentUserId()`, which is `getuid()`,
    while its own doc comment and help text both say "effective
    user ID. Same as id -un", and `src/id.zig:362` uses a
    dedicated `geteuid()` for that query. Under a setuid binary
    vibeutils `whoami` and vibeutils `id -un` disagree, and GNU
    sides with `id -un`. Fix in whoami only; the shared
    `getCurrentUserId()` real-uid semantics are what chown, stat,
    and id depend on.
  - ✅ T1-1 `tests/utilities/whoami_test.sh:21` — **the reason
    C4-1 survived.** The "matches system whoami" test does
    `expected=$(whoami)` with an unqualified name, but
    `tests/integration.sh:24` pins PATH to `zig-out/bin`, so the
    oracle resolves to the binary under test and the assertion is
    `$x == $x`. Proven by sabotage: a stub printing `WRONG_USER`
    still reports equal. This is the `fa8be65` pitfall inverted.
  - ✅ C1-1 `src/whoami.zig:59-65` — **CRITICAL.** The
    extra-operand error omits the `Try 'whoami --help' for more
    information.` line GNU emits and that 14 other vibeutils
    utilities emit (`src/uniq.zig:327` is the pattern).
  - ✅ C2-4 `src/whoami.zig:36-53` — **CRITICAL.** `--help` and
    `--version` are not resolved in command-line order; all args
    are parsed first and help always wins.
  - ✅ T4-2, T4-3 `src/whoami.zig:58` — `--`, bare `-`, and `""`
    operands are all handled and all untested.
  - ✅ T2-4 `src/whoami.zig:282` — the extra-operand test asserts
    only the substring `extra operand`, which is what let C1-1
    hide.
  - ✅ C3-1 `src/whoami.zig:42` — an allocation failure during
    parsing is reported as a usage error (exit 2).
  - ✅ T3-3, T3-4, T1-4, T1-5, T4-4, T4-6, C2-6, C5-1 — redundant
    tests, unanchored `--help`/`--version` matches, and untested
    branches.
  - ❌ T4-5 — dropped at codex cross-check: the claimed
    help-before-version ordering gap is not what the code does.
  - ❌ C2-2 `src/whoami.zig:66` — dropped at codex cross-check:
    the exit codes are already correct.
  - ⏸ C1-3 `src/common/argparse.zig:79-88` — **CRITICAL,
    cross-cutting.** Unambiguous long-option abbreviations are
    rejected; GNU `getopt_long` accepts them. Affects every
    utility, not just whoami.
  - ⏸ C1-2 `src/common/argparse.zig:540-549` — option-error
    messages discard the offending option text and the GNU hint
    line.
  - ⏸ C4-2 `src/common/user_group.zig:6` — the `c_passwd` extern
    struct declares the glibc layout.
  - ⏸ T1-2, T2-5, C5-2 — shared test-helper and message defects.

## Routed findings

Findings surfaced in one unit's wave whose fix belongs to another
unit. They are carried into the owning wave's input rather than
applied in place, because two worktrees editing one file collide.

Found during `whoami` (U0), all routed into the shared waves that
now run **first**:

- → **S0** `src/common/argparse.zig:79-88` — **CRITICAL.**
  Unambiguous long-option abbreviations are rejected; GNU
  `getopt_long` accepts them. Affects all 47 utilities.
- → **S0** `src/common/argparse.zig:540-549` — option-error
  messages discard the offending option text and the GNU hint
  line.
- → **S3** `src/common/user_group.zig:6` — the `c_passwd` extern
  struct declares the glibc/Linux `struct passwd` layout.
- → **S8** `src/common/test_utils.zig:73,107` — `TestWriter` and
  `StdoutCapture` are dead, zero consumers.

That `whoami`, the fourth-smallest utility in the repo, surfaced a
CRITICAL in the argument parser every utility shares is the
evidence for sweeping shared code first.

### df (round 1, pre-redesign)

Audited under the original single-round design as a scaling probe,
before the shared waves were moved ahead of the utilities. These
are valid round-1 findings for U1, not a converged result.

`df` turned out to be the sharpest demonstration so far of why the
stub lens exists: **three flags are parsed and never read**, and in
every case the tests assert the parsed field rather than the
behavior, so the suite stays green while the flag does nothing.

- ✅ `src/df.zig:110,428` — `-I` (macOS, suppress inodes) is
  stored in `opts.suppress_inodes` and read by no renderer.
  `df -i -I /` still prints `Inodes IUsed IFree IUse%`; BSD `df`
  resolves last-flag-wins and omits them. The guarding test at
  `src/df.zig:4123` documents its own toothlessness in a comment —
  it names the real check ("the Inodes column should be absent")
  and then asserts only `exit == 0`.
- ✅ `src/df.zig:108,301,304` — `--output` is stored in
  `opts.output_fields` and read by no renderer.
  `df --output=source,size /` prints the full default layout,
  byte-identical to bare `df /`. Both guarding tests assert only
  that the field parsed.
- ✅ `src/df.zig:88,340` — `-h` cannot be distinguished from a
  no-op: `human_readable` already defaults to true, so every
  assertion passes against the default. Changing the parse arm to
  `'h' => {}` leaves the whole suite green while `df -k -h` stays
  wrongly in 1K-block mode.
- ✅ `src/df.zig:2491` — `printHeader` / `printFsRow` /
  `printTotal` are only reached through `runDf_renderInodes`,
  which opens with `std.debug.assert(opts.inodes)`. Production
  therefore never executes their non-inode branches, yet nine
  tests exercise exactly those branches. The dead path prints
  `Available` where the live `-P` path prints `Avail`, so the
  tests and the binary disagree and nothing notices.
- ✅ `tests/utilities/df_test.sh:51` — `df /` is asserted with
  `[[ "$output" =~ "/" ]]`; every df line contains a `/`, so
  printing the entire mount table would pass.
- ✅ `src/df.zig:3577` — "printHeader - color mode no Usage
  column" is byte-identical to the plain-mode test above it and
  never enables color.

## Calibration record

Two single-round audits were run as calibration probes. Measured,
not estimated:

| Metric | whoami | df |
|---|---|---|
| Source lines | 309 | 4228 |
| Agents | 24 | 26 |
| Errors / empty results | 0 / 0 | 0 / 0 |
| Subagent tokens | 1.34M | 2.02M |
| Wall clock | 22 min | 59 min |
| Tool uses | 247 | 507 |

**Cost scales with unit count, not with source size.** A 13.7×
larger target cost 1.5× the tokens and 2.7× the wall clock, and
the agent count barely moved. Fitting the two points gives roughly
1.2M tokens of fixed cost per unit plus ~170 tokens per source
line, so the ~101K lines of utility source across 47 units come to
about 73M tokens for a single audit round — dominated by the 56M
of per-unit overhead, not by the code volume.

The current design multiplies that: loop-until-dry runs 3–4 rounds
where this measured one, and each round adds three refuters, a
differential tester, and one reproduction agent per surviving
finding. Budget several hundred million tokens for the audits
alone, with `red` and `green` on top, and the honest wall-clock
estimate is weeks of continuous running rather than days. Both
probes ran one utility at a time; three per wave overlaps but does
not divide that, since the machine is the bottleneck.

All five preflight checks passed: args threaded (no `undefined`
in any prompt), all 12 Codex invocations returned
`invoked_ok=true`, the two families produced different sets, the
cross-check rejected 2 findings, and no agent wrote outside its
worktree.

Two results that should change how later waves are run:

- **Codex found strictly less than Opus.** `codex_only` was 0 on
  both targets: 15 raw Codex findings against 35 from Opus, all
  of them a subset. Consensus still worked, and the Codex
  cross-check earned its place by rejecting 2 Opus findings. But
  on a 309-line utility the five Codex lenses added no finding of
  their own, so the value they deliver here is adjudication, not
  discovery.
- **The Fable judge never ran.** Zero deadlocks: the cross-check
  resolved every one-sided finding. That path is still unproven.

Both results drove the redesign that followed: the audit now loops
until dry, agreed findings face three adversarial refuters, a
mechanical GNU differential tester runs alongside the reading
lenses, and shared code is swept first.

**`whoami`'s audit above ran under the original single-round
design.** It is a valid round 1, not a converged result, and U0
must be re-run under the current workflow before it can be called
clean.
