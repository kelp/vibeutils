# Audit Sweep Design

How to audit this repo for bugs at a cost proportional to the
yield. Supersedes `docs/AUDIT_EXECUTION_PLAN.md` (2026-03) and the
`fix-it-all` workflow (2026-08). Both are described below under
"What was tried", because the reasons they failed are the reasons
this design looks the way it does.

## The finding that drives everything

Two independent audits, eighteen months of CHANGELOG entries, and
the 2026-08 adversarial sweep all converge on the same short list
of defect classes:

1. A flag is parsed into the options struct and never read.
2. A test asserts `parsed.opts.<field>` instead of the program's
   output, so class 1 stays green forever.
3. A shell assertion is unfalsifiable — an unanchored pattern, or
   an oracle that resolves to the binary under test.
4. A code path is reachable only from tests.
5. Output diverges from GNU in a way no test pins down.

Classes 1 through 4 are **mechanically detectable**. They need no
model at all. Class 5 is the only one that genuinely requires
reading code against a spec.

Every confirmed finding from the 2026-08 sweep fell into these
five classes. The sweep spent 24M tokens rediscovering a taxonomy
already written in `AUDIT_EXECUTION_PLAN.md`.

## Design

Three stages, cheapest first. Each stage only hands the next stage
what it could not settle itself.

### Stage 1 — mechanical pre-pass (no model)

A script, run over all 47 units at once, in seconds. It produces a
candidate list, not verdicts.

| Check | Method |
|---|---|
| Stub flags | For each field in the args struct, count reads and writes of `opts.<field>` outside `test` blocks. Writes with zero reads are stubs. |
| Parse-only tests | Test blocks asserting `parsed.opts.<field>` where no behavioral test exercises that flag. |
| Toothless shell assertions | `=~` against a pattern that matches any plausible output; `test_binary_exists` without `\|\| return 1`; `$(cmd)` oracles naming a binary that exists in `zig-out/bin`. |
| PATH-shadowed fixture tools | Unquoted `command <util>`, `find -exec <util>`, `env <util>`, or `run_with_limit N <util>` naming a shipped utility that is not the unit under test. Bare names are intercepted by host wrappers; these lookups bypass them. |
| Test-only code | Functions whose only call sites are inside `test` blocks. |
| Matrix drift | Every `docs/specs/<util>-flags.md` row claiming `Ours: yes` whose flag is absent from the parser or unread. |

The matrix-drift check alone would have found `df -I` and
`df --output`, both of which claim `Ours: yes` and are stubs. The
oracle check would have found the `whoami` test that compares the
binary to itself. Neither needed a model.

Run this in CI. A new stub flag should fail the build, not wait
for the next audit.

#### The script

`scripts/audit-check.sh` implements the table above. `just audit-check` runs it over the
repo, `just test-audit-check` runs its contract tests, and
`.github/workflows/audit.yml` runs both — self-tests first, because
a scanner that has stopped working reports zero findings and exits
0, which reads exactly like a clean tree. It is POSIX sh and awk
over `build/utils.zig`, so it needs no Zig toolchain and no `just`.
The whole sweep takes about three seconds.

| Check | Example key |
|---|---|
| `stub-flag` | `src/df.zig::suppress_inodes` |
| `matrix-drift` | `docs/specs/sort-flags.md::--parallel` |
| `toothless-assert` | `tests/utilities/pwd_test.sh::test_pwd::self-oracle:pwd` |
| `test-only-code` | `src/rm.zig::getDeviceId` |
| `parse-only-test` | `src/df.zig::no_sync` |
| `path-shadow` | `tests/utilities/shadowly_test.sh::test_shadowly::command:chmod` |
| `unscannable` | `src/printf.zig::no-args-struct` |

**`unscannable` is the anti-false-negative device that makes the
other checks worth believing.** A unit whose args struct cannot be
found, whose flag matrix has no `Ours` column, or whose test file is
missing is reported and counted toward the gate, so a unit the
scanner stops understanding fails the build instead of quietly
leaving the scanned set. Reading "no findings" as "no defects" is
only safe while `unscannable` is zero or explicitly baselined.

**`parse-only-test` ships deliberately incomplete.** There is no
reliable mechanical link from a shell test to the struct field it
exercises, so the check implements only the tractable subset: a
field asserted through `parsed.opts.<field>` in a Zig `test` block
whose only other appearance is its parse-site write. A flag whose
behavior nothing pins, but which is never asserted that way, is not
reported. Read a clean `parse-only-test` as "no instances of the
narrow pattern", never as "every flag has a behavioral test" — the
general case is stage 2's. No other check depends on it.

`toothless-assert` splits the oracle rule in two. A `$(...)` naming
the utility **under test** is flagged wherever it appears: the
comparison holds whatever that utility prints, which is the `whoami`
defect above. A `$(...)` naming a **different** vibeutils binary is
flagged only in oracle position (assigned to an `expected`-shaped
name, or inside a comparison), because `tests/integration.sh` pins
`PATH` to `zig-out/bin` and every `$(mktemp -d)` in the suite would
otherwise bury the self-comparisons under a hundred rows of
scaffolding.

Accepted findings live in `scripts/audit-baseline.tsv` as
`<check>` TAB `<key>` TAB `<justification>`. Keys name the
construct, never a line number, so a row keeps covering its finding
when the code around it moves; there is no inline suppression
comment, because a line-local hatch would reintroduce exactly that
fragility. An empty justification, a duplicate key, or an unknown
check name is a hard error — an unjustified row cannot be told apart
from a silent suppression. The exit code is the contract: 0 for no
new findings, 1 for any, 2 for a usage error, an unreadable tree,
zero units enumerated, or a bad baseline. Nothing parses the summary
text.

### Stage 2 — one audit pass per lens per unit

Only for what stage 1 cannot decide: GNU behavioral parity, and
judgement calls about duplication.

**One agent per lens, one pass. No rounds, no consensus, no
judge.** Measured: additional rounds re-derived earlier findings,
adversarial refuters killed 16% of findings while the proof
obligation killed the rest, and a second model family agreed
almost everywhere it mattered.

| Lens | Hunting for |
|---|---|
| GNU parity | Flag semantics, exit codes, byte-exact output and error text, against `docs/specs/<util>-flags.md` and a real GNU binary |
| Platform | macOS signed `st_dev`, `isatty` gating on every interactive path, BSD/GNU divergence, static libc buffer reuse |
| Resources | Leaks, unclosed fds, unflushed writers, unbounded loops |
| Edge cases | Empty input, no operands, `-`, `--`, `''`, lines >8KB, symlinks, permissions, locale and TZ |

Four lenses, one agent each, plus stage 1's candidate list as
seed. Roughly 5 agents per unit against the sweep's 24 to 272.

### Stage 3 — proof, then fix

This is the one thing the expensive sweep contributed that is
worth keeping. **No finding is actionable until it has been
demonstrated.** 88% of findings that survived the sweep's proof
gate were real; the gate, not the adversarial machinery, is what
made the finding lists trustworthy.

| Kind | Obligation |
|---|---|
| `bug` | Run it. Build fixtures, run our binary and the real GNU utility with `LC_ALL=C` and `TZ=UTC` pinned, capture all three channels. Expected values come from a command that was run, never from memory. |
| `test_defect` | Sabotage. Mutate the implementation to break what the test guards. If the test still passes it has no teeth. Revert. If it fails, the finding was wrong. |
| `missing_test` | Show the behavior happens, then show nothing asserts it. |
| `dead_code` | Delete it. Remove the symbol, confirm the build and full suite still pass, revert. If anything fails, the code is live. |
| `duplication` | None available. Judgement call: propose, and let a human decide. Never auto-fix. |

Then fix, red-green, per CLAUDE.md: tests and implementation from
**separate agents**, RED verified for the right reason on macOS
and Linux before any fix is written.

An audit that produces a report and no commits has produced
nothing. `docs/audit/` holds 76 report files from 2026-03 that
went stale before they were acted on. The fix lane is not optional
and it is not a separate project.

## Ordering

Shared code in `src/common/` first, then utilities. A single
`argparse` defect is worth 47 utility defects, and a utility-wave
finding that lands in shared code cannot be fixed in a parallel
worktree without collisions.

Batch 3 to 4 units. Wall clock is dominated by `zig build`
contention, not by unit size — a 13.7x larger target cost 1.5x
the tokens and 2.7x the wall clock.

## Blast radius

The utilities under audit are `chmod`, `chown`, `rm`, `mv`, `dd`.
Running them is ordinary here; **where they are pointed is the
entire safety question.** During the 2026-08 sweep an agent
verifying a failsafe ran
`./zig-out/bin/chmod -R --no-preserve-root 755 /` on the host. It
did no damage only because it ran unprivileged and hit a timeout.

Rules, enforced in `.claude/settings.json` under `autoMode`, not
merely stated in prompts:

- Never run a destructive command against a real system path.
  Build a fixture directory.
- Verifying a failsafe means observing its refusal, never
  overriding it.
- Anything that must touch `/` runs inside `orb -m ubuntu`.
- Never delete anything the agent did not create. Freeing disk
  space is not the agent's call.

Prompt-level rules are advisory; an agent that decides it needs to
reproduce something will talk itself past them. The classifier
tier is the one that holds.

## What was tried

### 2026-03, `AUDIT_EXECUTION_PLAN.md`

3 agents per utility, 4 utilities per batch. Correct taxonomy,
correct rules ("agents MUST build and run utilities"), sane
economics. It failed on the back end: no proof obligation, so
findings were plausible rather than demonstrated, and no fix lane,
so it produced 76 report files that aged out.

### 2026-08, `.claude/workflows/fix-it-all.js`

Loop-until-dry discovery across 12 lenses, two model families
forced to consensus, three adversarial refuters per finding, and a
Fable judge on deadlock.

| Unit | Agents | Tokens | Findings |
|---|---|---|---|
| whoami, 309 lines | 24 | 1.34M | 8 |
| df, 4228 lines | 26 | 2.02M | 6 |
| argparse, tests only | 272 | 20.6M | 1 recovered |

Three units of 47. Zero fix commits. The weekly token limit was
exhausted on the first shared module, and the code half of that
module never ran at all.

What went wrong:

- **Loop-until-dry was the wrong bound.** Cost was ~1.2M fixed
  per unit plus a small per-line term, so ceremony dominated.
  Raising the round cap from 8 to 20 multiplied cost tenfold for
  the same class of yield.
- **Dual-family consensus did not earn its cost.** The proof
  obligation caught the false positives; the refuters and the
  judge mostly ratified.
- **The yield was concentrated in two lenses** that stage 1 can
  now find without a model.
- **It never closed the loop.** Findings accumulated in a ledger
  while the red and green phases waited on a token budget that
  ran out.

Keep from it: the proof obligation table, the lens list, the
worktree preamble, and the blast-radius rules. Discard: the
rounds, the second family, the refuters, and the judge.

## Ledger

One table, in the repo, written by the orchestrator only so
parallel worktrees never conflict on it. Per unit: audit SHA, red
SHA, green SHA, and a line per finding marked demonstrated,
rejected, or routed to the unit that owns the fix. Record the
negative results — a rejected finding recorded with its reason is
what stops the next sweep from re-raising it.
