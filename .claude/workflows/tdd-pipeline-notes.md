# tdd-pipeline workflow — model choices & pending decisions

Working notes for `tdd-pipeline.js`, the deterministic TDD
pipeline used for the walker migration (and other
behavior-preserving refactors). The script is the only
orchestrator — dispatched agents are leaves and cannot spawn
their own subagents, so any "delegate the slow part" idea
must be expressed as separate `agent()` steps in the script.

## Current model assignments (as of first chmod run)

| Stage | Agent | Model | Rationale |
|---|---|---|---|
| Scout / briefing | workflow-subagent | sonnet | read 3 files once, distill API + recipe + conventions |
| Author tests | tdd-pipeline:test-writer | opus | tests are the spec — highest leverage |
| Review tests | tdd-pipeline:test-reviewer | opus | reviews the spec; highest-stakes gate; loops until APPROVED |
| Prove teeth (sabotage) | workflow-subagent | sonnet | craft mutation, run, restore — the genuine non-opus bet |
| Green check | workflow-subagent | haiku | run suite, report facts |
| Implement | tdd-pipeline:implementer | opus | correct Zig 0.16 + Tiger Style, recursion removal |
| Verify gate | workflow-subagent | haiku | run full+privileged+lint, report facts |
| Code review | tdd-pipeline:code-reviewer | opus | reviews the refactor; sonnet took 5 rounds on the walker, opus one-shots; loops until APPROVED |
| Final verify | workflow-subagent | haiku | one more full-suite run |

Every `model` is an explicit one-liner in the script, so
these are cheap to retune empirically.

## Run 1 scorecard — chmod red phase (run ww9fwma41)

Result: clean. 7 characterization tests, review APPROVED
round 1, sabotage proved all 7 (after one legit teeth-fix
loop), green check passed. `ready_to_commit_red = true`.
Committed as `4c9db97`.

| Stage | Model | Turns | Output tok | Heavy runs |
|---|---|---|---|---|
| Scout | sonnet | 11 | 831 | 1 |
| Author tests | opus | 80 | 24,967 | 12 |
| Review tests | opus | 61 | 7,166 | 6 |
| Prove teeth r1 | sonnet | 78 | 10,041 | 24 |
| Test-writer teeth-fix | opus | 28 | 4,433 | 4 |
| Prove teeth r2 | sonnet | 75 | 8,406 | 18 |
| Green check | haiku | 57 | 3,132 | 13 |
| **Total** | | | **~59K** | **~78** |

Cache reads ~22.5M (briefing reuse — cheap; the
repeated-context worry was a non-issue).

Findings:
- **Cost is wall-clock, not tokens.** ~59K output total but
  ~78 heavy `zig build test`/privileged runs → ~2.7h. The
  lever is cutting full-suite runs, not model price.
- **Sabotage looped once, legitimately** — round 1 found a
  real toothless test, opus strengthened it, round 2 proved
  all 7. ~42 heavy runs across the two passes (ran the full
  suite per mutation).
- **Opus reviewer redundantly self-sabotaged** (6 heavy runs,
  ~13K in + 7K out of opus) — duplicating the dedicated
  sabotage stage. Most fixable opus waste.
- **No haiku misjudgment** — green check passed, never
  triggered a spurious opus re-run (the failure mode I most
  feared did not occur).
- Models validated where it counts: opus test-writer earned
  its 25K output (APPROVED round 1); haiku gate cheap.

## APPLIED after run 1 (a/b/c + scope hardening)

Edits made to `tdd-pipeline.js` (2026-05-29) based on the
scorecard above:
- **(a) Reviewer no longer self-sabotages.** test-reviewer
  now judges teeth BY READING ONLY; the dedicated stage
  proves teeth empirically. Kills the redundant opus runs.
- **(b) Sabotage runs only the guarding test per mutation**,
  via `-Dtest-filter`, piped through `tail`; one full
  `test-util` run at the end. Attacks the ~42-heavy-run cost.
- **(c) Implementer (green) uses fast/scoped/quiet checks
  only** — compile + `test-util`, never the full/privileged/
  integration suites; the haiku verify-gate runs those and
  reports distilled results.
- **Scope hardening (from observed creep):** test-writer,
  implementer, and sabotage agents are told to edit ONLY the
  target file (no TODO.md, no other sources, no build files)
  and never run a tree-wide formatter (`just fmt`) — only
  `fmt-check`. Run 1's test-writer had run global `zig fmt`
  (reflowed 6 unrelated files) and written a backlog section
  into TODO.md; both were reverted.

Still open to revisit after a green-phase run: whether to add
a separate haiku "runner" between writer and review (vs the
implementer self-checking), measured against reload cost.

## APPLIED before chown green (scorecard tuning)

Two edits to the code-review stage in `tdd-pipeline.js`
(2026-05-29), driven by the chmod green-phase scorecard:
- **Promote code-reviewer sonnet → opus.** Sonnet needed 5
  review rounds on the walker migration; the opus test-reviewer
  one-shot its review. Cheaper-per-token but more-rounds was a
  net loss — the counter-intuitive prior we flagged, now
  confirmed on the review gate too.
- **Code-reviewer reviews by READING only.** Told it not to run
  the test/privileged/integration suites or any build — the
  verify gate already proved green + recursion-free; re-running
  was ~17 needless heavy runs. Same fix already applied to the
  test-reviewer (a).

---

### Original framing of the (a/b/c) decision (kept for context)

**Split "opus authors" from "haiku runs the slow/verbose
suites."** Observed: opus authoring sits through slow `zig
build` / very verbose integration + privileged (fakeroot)
runs.

Cost mechanics that must drive the decision:
- Waiting for a build is **wall-clock latency, not opus
  tokens** — moving the trigger to haiku does NOT make the
  build faster.
- The real token waste is **opus ingesting verbose output**
  (thousands of lines of test/integration logs).

Proposed change (apply from a future run, NOT mid-run):
- Opus authors + does only a **fast, quiet, scoped compile
  check** — never the full privileged/integration suites.
- A **haiku runner** executes the slow/verbose authoritative
  suite and returns a **distilled** pass/fail + first-error
  summary; opus never sees the firehose.
- Bounded **write(opus) → run+distill(haiku) → fix(opus)**
  loop. Keep all gates haiku.
- Bake **quiet/scoped command variants** into args (overrides
  the agent-briefing "no redirections" rule, which is
  counterproductive here).

Honest caveat: workflows have no `SendMessage`, so each opus
re-dispatch reloads the briefing (prompt-caching softens
this). Strictly better for the common "passes first try"
case; only pathological multi-fix loops might cost more in
reloads.

## Scorecard to collect from each run (informs the decision)

Pull from the workflow's per-agent usage + transcript dir:
1. Per-agent **model, turn count, token spend**.
2. Any cheaper-model agent that **looped** (sabotage retry,
   review rounds > 1, gate re-dispatch).
3. Specifically flag any **haiku gate that triggered an opus
   re-run** — the expensive-by-proxy failure mode.
4. How much **verbose test output opus actually ingested**
   during authoring/implementation (the thing the split
   would eliminate).

Decide per-agent promotions/demotions from the data, not from
argument. Counter-intuitive prior to watch for: cheaper models
that take more rounds (or trigger opus re-runs) can cost more
than opus one-shotting.

## Bugs already found by dry runs (keep fixed)

1. A local `const phase = ...` shadowed the global `phase()`
   hook → instant crash. (Renamed to `phaseArg`.)
2. `args` arrived as a **JSON-encoded string**, not an object
   → every `a.field` was `undefined`, silently, masked only
   by agents improvising. Fixed with a defensive
   `typeof === 'string' ? JSON.parse(...)` normalize.
   **Lesson: always verify args threaded (check the first
   agent's actual input prompt) when launching a new workflow
   script — stringified-args failure is silent.**
