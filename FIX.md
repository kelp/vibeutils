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

**Audit.** Ten read-only finders per target. Opus lenses T1–T5 and
C1–C5 run against the same brief as five Codex lenses driven
through `codex exec`. A merge agent sorts the results into
*agreed* (both families), *opus-only*, and *codex-only*. Each
family then cross-checks the other's one-sided findings, returning
CONFIRM, REJECT, or DISPUTE. Anything still disputed goes to a
Fable judge, which reads the code rather than arbitrating between
the two written positions. Its ruling is binding.

Tests are audited before the implementation, and the test audit's
coverage gaps seed the code audit: untested paths are where bugs
survive.

**Red.** The test-writer fixes the test defects, adds the missing
tests, and writes a failing test for every agreed bug. A red check
proves each fails *for the right reason* — the assertion matching
the bug, not a compile error or a skip — on macOS and Linux.
Refactor findings are behavior-preserving, so they get
characterization tests proven by transient sabotage instead.

**Green.** The implementer makes the minimal fix. It may never
edit a test; when a test genuinely needs to change it routes back
to the test-writer, which judges first and may refuse. Gates:
scoped unit + scoped integration + `fmt-check` per iteration,
then `tiger-check`, then a read-only code review, then an
independent Codex review of the diff with bounded rebuttal and the
judge on deadlock, then the authoritative full run — full unit,
full privileged, and *full* integration on macOS plus full unit
and scoped integration on Linux.

**Deferred.** A finding whose fix would change `src/common/*` or
another utility cannot be applied inside a per-utility worktree
without three of them colliding on one file. Those are recorded
here and fixed serially in the cross-cutting wave.

## Wave status

| Wave | Utilities | Audit | Red | Green | A / D / J | Deferred |
|---|---|---|---|---|---|---|
| 0 | whoami, true, false | 🔄 | ⬜ | ⬜ | 11 / 2 / 0 | 6 |
| 1 | df, du, free | ⬜ | ⬜ | ⬜ | | |
| 2 | dd, sort, seq | ⬜ | ⬜ | ⬜ | | |
| 3 | id, nl, tr | ⬜ | ⬜ | ⬜ | | |
| 4 | cut, date, timeout | ⬜ | ⬜ | ⬜ | | |
| 5 | uniq, tac, env | ⬜ | ⬜ | ⬜ | | |
| 6 | realpath, readlink, mktemp | ⬜ | ⬜ | ⬜ | | |
| 7 | find | ⬜ | ⬜ | ⬜ | | |
| 8 | stat, printf | ⬜ | ⬜ | ⬜ | | |
| 9 | cp, mv | ⬜ | ⬜ | ⬜ | | |
| 10 | grep, ls | ⬜ | ⬜ | ⬜ | | |
| 11 | chmod, chown | ⬜ | ⬜ | ⬜ | | |
| 12 | rm, rmdir, mkdir | ⬜ | ⬜ | ⬜ | | |
| 13 | ln, touch, test/`[` | ⬜ | ⬜ | ⬜ | | |
| 14 | tail, head, wc | ⬜ | ⬜ | ⬜ | | |
| 15 | cat, tee, sleep | ⬜ | ⬜ | ⬜ | | |
| 16 | echo, yes, basename, dirname, pwd | ⬜ | ⬜ | ⬜ | | |
| 17 | cross-cutting (`src/common/*`), serial | ⬜ | ⬜ | ⬜ | | |

47 utility units, covering all 48 entries in `build/utils.zig`
(`test` and `[` share `src/test.zig` and are one unit).

Ordering is by implementation-size-to-test-coverage gap, not by
size. Wave 0 calibrates the pipeline cheaply. Waves 1–6 hit the
worst gaps: `df` is 4228 source lines against 26 integration
assertions, `du` 4051 against 43, `free` 1302 against 26. Giants
land mid-sweep with smaller waves, because wall-clock scales with
source size rather than with utility count.

Legend: A = agreed by both model families, D = dropped at
cross-check, J = decided by the judge.
Marks: ⬜ pending, 🔄 in flight, ✅ committed, ⚠️ committed with a
caveat recorded below.

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
  - ✅ T1-1 `tests/utilities/<u>_test.sh:44` — <what was wrong>
  - ✅ C2-3 `src/<u>.zig:1902` — <what was wrong>
  - ❌ C4-1 `src/<u>.zig:88` — judge REJECT: <why, with the
    file:line that refutes it>
  - ⏸ C5-2 `src/common/mode.zig:210` — cross-cutting, wave 17
  - 🚫 T4-6 — test-writer refused: <why the finding was wrong>
```

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

## Cross-cutting backlog (wave 17)

Findings deferred out of their own wave because the fix touches
shared code. Fixed serially at the end, gated on the full suite
rather than a scoped one.

- `src/common/argparse.zig` — long-option abbreviation rejection
  (C1-3, CRITICAL); option-error messages missing the offending
  option and the GNU hint line (C1-2). Both found via whoami;
  both affect every utility.
- `src/common/user_group.zig:6` — `c_passwd` declares the
  glibc/Linux `struct passwd` layout (C4-2).
- `src/common/test_utils.zig:73,107` — `TestWriter` and
  `StdoutCapture` are dead, zero consumers (C5-2).

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
