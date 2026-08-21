# Slice: `## Tiger Style remediation (deferred)`

## Slice name

`## Tiger Style remediation (deferred)` — the unchecked box
that asks CI to run `scripts/tiger-check.sh --base origin/main`
so PRs fail on NEW Tiger Style violations.

## Predecessor gate (recorded deviation)

Issues #146–#166 still have open draft PRs (#171–#181). TODO
slices `#### 28. free` (#182), `#### 37. tail` (#183), and
`### Shared Components` (#184) are also open. This branch is
from `origin/main` (`a41eccd`) and touches only `TODO.md` plus
this plan. This environment cannot merge.

The attached campaign plan lists this heading first among
remaining TODO slices. Free/tail/shared were stacked earlier
because merge is blocked; this slice fills the skipped first
heading.

## In scope

**The CI job already exists.** `.github/workflows/tiger-style.yml`
runs on every PR and push to `main`:

1. `bash tests/tools/tiger-check_test.sh` (scanner self-test)
2. `just tiger-check` → `scripts/tiger-check.sh` with **no
   args** (tree-wide). Exit 1 on any gating violation.

That is **stricter** than `--base origin/main`. `--base` only
fails on NEW violations in the diff. Tree-wide fails on any
gating violation anywhere, including a function that crosses
70 lines on lines the PR did not touch. The workflow comment
states this on purpose. `docs/tiger-style-review/README.md`
Phase 6 is checked: tree-wide gating counts are 0.
`CHANGELOG.md` already records the "Tiger Style CI gate"
under a released section.

This slice does **not** weaken the gate to `--base`. It
records that the deferred work landed, and checks the box.

Edits:

- `TODO.md`: check the box. Replace the "Deferred
  deliberately…" rationale with a one-sentence note that CI
  already runs tree-wide `just tiger-check` (stricter than
  `--base origin/main`).
- `docs/plans/2026-08-21-tiger-ci-gate.md` (this file).

No `.github/workflows/` edit. No `scripts/tiger-check.sh`
edit. No Zig. No `CHANGELOG.md` (already shipped).

## Out of scope

- Changing the job from tree-wide to `--base origin/main`
  (would weaken the gate)
- Adding a second redundant `--base` job
- Remaining TODO headings (`### Build System` man pages,
  `LS_COLORS`, …)
- Issue PRs #171–#181

## Spec impact

None. No flag matrix.

## Tests

None. This is a documentation checkbox for a CI job that
already runs in `.github/workflows/tiger-style.yml`. Skip
red-green TDD (no program behavior change). Before each
commit run `just fmt-check` (or `zig fmt --check` when
`just` is the node wrapper) even for docs-only edits. Do
not run the full test suite for a TODO.md tick.

Evidence the job exists: every open PR on this repo already
shows a `tiger-check` required check.

## Risks

- Checking a stale box without the `--base` command the text
  named. Mitigated: tree-wide is a strict superset of
  `--base` for gating NEW violations, and also catches
  pre-existing debt regressions. Document that in TODO.md.
- Do not add `tiger:allow` suppressions. Do not edit the
  scanner.

## Plan review

Three-model review before checking the box. Nit-only dissent
does not need a second round.
