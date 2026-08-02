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
find nothing new, capped at eight rounds. Deduplication is against
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
a CRITICAL in `argparse`. The nine shared waves therefore run
before any utility wave, and **again afterwards** (ids `S0b`–`S8b`),
because the utility fixes add new callers and new duplication.

**Red.** The test-writer fixes the test defects, adds the missing
tests, and writes a failing test for every agreed bug. A red check
proves each fails *for the right reason* — the assertion matching
the bug, not a compile error or a skip — on macOS and Linux.
Refactor findings are behavior-preserving, so they get
characterization tests proven by transient sabotage instead.
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

## Wave status

### Shared code — `src/common/`, swept first

A defect here is a defect in every utility that imports the
module. These waves have no scoped gate: the common test binary
has no per-module filter and the blast radius is the whole tree,
so every iteration runs the full suites. That is the real cost of
touching shared code.

| Wave | Modules | Lines | Why here | Audit | Red | Green |
|---|---|---|---|---|---|---|
| S0 | argparse | 1141 | every utility parses through it; known CRITICAL | ⬜ | ⬜ | ⬜ |
| S1 | walker | 2269 | 8 utilities traverse through it; data-loss history | ⬜ | ⬜ | ⬜ |
| S2 | file_ops, file, directory | 1690 | file primitives | ⬜ | ⬜ | ⬜ |
| S3 | mode, user_group | 1251 | permissions and identity | ⬜ | ⬜ | ⬜ |
| S4 | path, glob, env, constants | 1076 | path and environment | ⬜ | ⬜ | ⬜ |
| S5 | help, format, prompt, main | 1470 | user-facing output plumbing | ⬜ | ⬜ | ⬜ |
| S6 | icons, unicode, display_config, style, colors, terminal | 3009 | terminal presentation | ⬜ | ⬜ | ⬜ |
| S7 | time, relative_date, git | 1145 | time and repository state | ⬜ | ⬜ | ⬜ |
| S8 | test_utils, test_utils_privilege, test_dir, privilege_test, privilege_test_integration, force_import_lint, lib | 3059 | the test infrastructure itself; 272 dormant tests have shipped here | ⬜ | ⬜ | ⬜ |

31 modules, 16030 lines, complete coverage of `src/common/`.

### Utilities

| Wave | Utilities | Audit | Red | Green | A / D / J | Deferred |
|---|---|---|---|---|---|---|
| U0 | whoami, true, false | 🔄 | ⬜ | ⬜ | 11 / 2 / 0 | 6 |
| U1 | df, du, free | 🔄 | ⬜ | ⬜ | | |
| U2 | dd, sort, seq | ⬜ | ⬜ | ⬜ | | |
| U3 | id, nl, tr | ⬜ | ⬜ | ⬜ | | |
| U4 | cut, date, timeout | ⬜ | ⬜ | ⬜ | | |
| U5 | uniq, tac, env | ⬜ | ⬜ | ⬜ | | |
| U6 | realpath, readlink, mktemp | ⬜ | ⬜ | ⬜ | | |
| U7 | find | ⬜ | ⬜ | ⬜ | | |
| U8 | stat, printf | ⬜ | ⬜ | ⬜ | | |
| U9 | cp, mv | ⬜ | ⬜ | ⬜ | | |
| U10 | grep, ls | ⬜ | ⬜ | ⬜ | | |
| U11 | chmod, chown | ⬜ | ⬜ | ⬜ | | |
| U12 | rm, rmdir, mkdir | ⬜ | ⬜ | ⬜ | | |
| U13 | ln, touch, test/`[` | ⬜ | ⬜ | ⬜ | | |
| U14 | tail, head, wc | ⬜ | ⬜ | ⬜ | | |
| U15 | cat, tee, sleep | ⬜ | ⬜ | ⬜ | | |
| U16 | echo, yes, basename, dirname, pwd | ⬜ | ⬜ | ⬜ | | |

47 utility units, covering all 48 entries in `build/utils.zig`
(`test` and `[` share `src/test.zig` and are one unit).

Ordering is by implementation-size-to-test-coverage gap, not by
size. U0 calibrates the pipeline cheaply. U1–U6 hit the worst
gaps: `df` is 4228 source lines against 26 integration assertions,
`du` 4051 against 43, `free` 1302 against 26. Giants land
mid-sweep with smaller waves, because wall-clock scales with
source size rather than with utility count.

### Shared code, re-swept

Waves `S0b`–`S8b` re-run every shared module after the utilities
are done. The utility fixes add callers, add duplication, and
change how the shared modules are used, so the first sweep's
conclusions expire.

| Wave | Audit | Red | Green |
|---|---|---|---|
| S0b–S8b | ⬜ | ⬜ | ⬜ |

**35 waves total.** Legend: A = agreed by both model families,
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

## Calibration record

Wave 0's `whoami` audit is the pipeline's own validation run.
Measured, not estimated:

| Metric | Value |
|---|---|
| Agents | 24 (0 errors, 0 empty results) |
| Subagent tokens | 1.34M |
| Wall clock | 22 min |
| Tool uses | 247 |
| Target size | 309 source lines, 62 integration lines |

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
