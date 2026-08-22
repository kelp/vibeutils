---
description: >-
  Land one TODO.md PR slice: choose the next slice, write a plan,
  review the plan with three models to consensus, implement with
  red-green TDD, open a draft pull request, and drain review comments
  until CI is green and no threads remain. Use when starting a TODO
  slice, landing the next milestone PR, planning a slice, or when
  asked to address all PR review comments until they are fixed.
model-invocation: true
---

# Land one TODO.md PR slice

Do this whole procedure for one slice. Do not skip the
plan review. Do not skip the comment drain. Do not start
a second slice in the same change.

`AGENTS.md` is the repository change process.
`CLAUDE.md` is the architecture contract. This skill is
the operating procedure. If this skill conflicts with
those files, follow those files.

## When to use

Use this skill when the user asks to land a slice, do
the next TODO item, plan a slice, or drain PR review
comments to all-clear.

Do not use this skill for a docs-only chore that is not
a `TODO.md` slice, unless the user maps that chore onto
a named slice.

## 1. Choose the work

1. Read `TODO.md` from the start of the current
   milestone. Skip headings marked deferred unless the
   user names them.
2. Fetch `origin/main` when the local default branch
   may be stale.
3. Confirm the local `main` matches `origin/main`
   before you branch.
4. Take the first unchecked **PR slice** in listed
   order inside the current milestone, unless the user
   named a later slice whose predecessors are already
   checked and on `main`.
5. Stop if a predecessor slice is still open. Do not
   start this slice until that predecessor is on
   `main`.
6. Record the exact `TODO.md` heading. That heading is
   the slice name. One heading is one pull request.

A PR slice is one `TODO.md` heading (`###` or `####`)
whose unchecked items form one landable change. Nested
checkboxes under that heading belong to the slice.
Deeper headings are separate slices.

Do not combine slices. Do not pull in the next heading
"while you are here."

## 2. Plan the slice

Write a plan before you change code. Keep the plan
inside this slice. Write it to
`docs/plans/YYYY-MM-DD-<slice-slug>.md` so reviewers
can read it. Do not implement during planning.

The plan must include:

- Slice name (the `TODO.md` heading)
- In scope (behavior, files, modules)
- Out of scope (the next headings, named explicitly)
- Spec impact (`docs/specs/<util>-flags.md`: no
  change, spec-first edit, or design-note only)
- Tests (which failing tests you will add)
- Risks (filter-stdin hangs, privileged tests, macOS
  syscall classes, `src/common/` boundaries, Tiger
  Style caps)

### Spec and design-note slices

A flag-matrix edit or a design note in `docs/plans/`
still needs user approval before any Zig against that
document. Plan review is not that approval.

An implementation slice may proceed after plan
consensus unless the user asked you to wait.

## 3. Review the plan to consensus

Do not implement until this step ends in consensus.

Use these models and no substitute:

- Grok 4.6: `cursor-grok-4.6-high-fast`
- GPT-5.6-Sol: `gpt-5.6-sol-high`
- Opus 5: `claude-opus-5-thinking-high`

Stay at three reviewers. Do not add a fourth
model. If a slug is missing from the Task
allowlist, report it and continue with the two
that remain. Do not invent a substitute.

If a requested model is not in the available list, do
not pick a replacement. Report the missing model.
Continue only when at least two reviews return.

Tell every reviewer: find blocking issues; do not write
code; reply with blocking issues (or “none”), at most
three non-blocking notes, and APPROVE or REQUEST
CHANGES. No file-by-file essay.

### Brief, then split axes

Do not send Sol or Opus `AGENTS.md`, `CLAUDE.md`, or
named source files in full.

1. Grok reads the plan and the files it names, then
   writes a one-page brief: slice heading, in/out of
   scope, the test contract, and the 3–5 files that
   would change. Grok also answers: one slice? process?
   `src/common/` and Tiger caps?
2. Sol gets the brief, the plan, and only the
   `CLAUDE.md` / `tdd` lines that apply (skip-first,
   silently-degrade, TDD split). Sol answers: does the
   plan violate those rules?
3. Opus gets the brief, the plan Tests section, and
   the test file or the `git diff` of the tests. Opus
   answers: are the tests enough, and is RED real?
4. Spec impact: attach `docs/specs/<util>-flags.md`
   only when the plan edits flags. Otherwise write
   “no flag-matrix change” in the brief.

Reviewers must still see the **real plan** (and, for
Opus, the real test text). Do not paraphrase the
change in place of those artifacts.

### Later rounds

Resume the same agent. Send only the delta and the
prior objection. Do not re-attach `AGENTS.md` or
`CLAUDE.md` unless the delta changes which rule
applies.

Re-run **only the objector** unless the revision adds
behavior, files, or a spec change. Nit-only dissent
does not need a second round. Do not start a fourth
full-context round to break a tie: decide from the
repo rules and record the decision in the plan.

The parent watches CI. Reviewers do not `gh run view`
or wait on checks.

Ignore Bugbot / Codex **usage-limit** comments. Those
are not review.

Consensus means: no remaining blocking objection from
a completed review.

Do not skip this step unless the user explicitly says
to skip plan review.

## 4. Implement

Follow `AGENTS.md` and `CLAUDE.md`. Load the
`zig-patterns` skill before writing Zig. Load the
`tdd` skill before writing a fix, a feature, or a
behavior-preserving refactor. Run
`/tiger-style:tiger-patterns` before writing Zig, and
`/tiger-style:tiger-check` after changes.

For a behavior change:

1. Write a failing test. The agent writing the test
   is never the agent writing the code (`tdd` skill).
2. Run that test and confirm it fails for the right
   reason.
3. Make the minimum change.
4. Run the same test and confirm the pass.
5. Run `just fmt-check` and `just test`. For a
   utility behavior change, also run
   `just it-util <name>` (with `env -u NO_COLOR` when
   color is involved). Do not commit a failing state.

You may skip red-green TDD only when the change does
not change program behavior. Still run
`just fmt-check` before each commit, and `just test`
when Zig files changed.

Also:

- Keep module boundaries. Shared code lives in
  `src/common/`. One utility per `src/<utility>.zig`
  (or `src/<utility>/`). Register a new utility in
  `build/utils.zig`. Do not edit `build.zig` itself.
- Do not add path-traversal checks or protected-path
  lists. Trust the OS.
- Do not `@panic` on user input, and do not leave
  I/O buffers unflushed. Return an `ExitCode` and
  print through `common.printErrorWithProgram`.
- Do not bypass Tiger Style with suppressions. No
  new function over 70 lines. No new gating
  violations.
- If code disagrees with
  `docs/specs/<util>-flags.md`, correct the
  specification first (user approval), then the
  code. GNU is the behavioral reference where a flag
  exists in GNU.
- Update `TODO.md` and `CHANGELOG.md` in the same
  commit as the applicable change. `CHANGELOG.md`
  only for user-visible changes.
- Comments are full sentences that say why, not
  what. Man pages follow
  `docs/MAN_PAGE_REFERENCES.md`.

After the local gates are green, commit. Push the
branch. Open a draft pull request unless the user
asked for a ready PR.

Do not merge. Do not enable auto-merge. Do not mark
the PR ready unless the user asks.

## 4b. Review the patch

After the local gates are green, review the **diff**,
not the tree. Same three models, same reply cap, same
axis split as §3.

Prompt is `git show <sha>` (or the merge-base diff),
the 10–20 plan lines that constrain it, and the TDD
split (test-only SHA vs impl-only SHA). Do not say
“read `src/<utility>.zig`.”

Grok: does the diff match the plan and stay in
`src/common/` / Tiger caps?
Sol: CLAUDE / TDD / skip-first on the diff.
Opus: does the guarding test still have teeth?

The parent subscribes to CI. Reviewers do not poll
runs. Ignore usage-limit bot comments.

## 5. Drain review comments to all-clear

Treat inline review threads as work. Loop until the
stop condition.

On each loop:

1. List unresolved review threads and new review
   comments on the PR. Include bot reviews (Bugbot,
   Security Reviewer, and similar).
2. Ignore Codex and Bugbot **usage-limit** issue
   comments. Those are not code review. A Cursor
   Approval Agent “not approving because Bugbot
   skipped” note is also not a review finding.
3. For each remaining comment, either fix it or
   record a brief reason that the repo rules reject
   it.
4. For a behavior fix, use red-green TDD. Run
   `just fmt-check` and `just test`. Commit. Push.
5. Resolve only the threads that the new commit
   actually fixes. In Cursor Cloud, resolve through
   the pull-request tool, not a merge command.
6. Wait for every required check to finish: **Test**,
   **Integration Tests**, **Changelog**, **Audit
   Pre-Pass**, **Tiger Style**, and any required bot
   reviews on the PR. Subscribe to CI and PR events
   rather than polling.
7. Re-list unresolved threads and new comments after
   CI completes. Start this loop again when anything
   remains.

Do not post a "done" comment unless the user asks.
Do not leave a valid review thread open because the
bot is slow. Wait, then look again.

### Stop condition

Stop when all of these are true:

- Local gates passed with no warnings on the last
  commit (`just fmt-check`, and `just test` when Zig
  changed)
- Required CI checks are green
- There are no unresolved review threads
- No new review comment arrived after the last push

Then report the PR URL, the slice heading, and that
the comment drain is all-clear. Do not merge unless
the user explicitly asks to merge.

## What not to do

- Do not combine two `TODO.md` headings in one PR.
- Do not implement before plan consensus.
- Do not write Zig against a new spec or design note
  before the user approves that document.
- Do not substitute a different plan-review model
  when a named model is unavailable.
- Do not send Sol or Opus the full tree, full
  `AGENTS.md` / `CLAUDE.md`, or “read this 9k-line
  file.” Brief + real plan/diff + the rule excerpt
  that applies.
- Do not add a fourth review model. Three axes is
  the gate.
- Do not re-run all three models on a wording nit.
  Resume the objector with the delta.
- Do not ask reviewers to watch CI.
- Do not skip the comment drain after the first
  green CI run.
- Do not merge, enable auto-merge, or mark the PR
  ready unless the user asks.
- Do not start the next slice in this change.
