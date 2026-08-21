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

Launch three independent reviewers in parallel. Give
each reviewer the plan, the slice heading from
`TODO.md`, `AGENTS.md`, `CLAUDE.md`, the relevant flag
matrix or plan file, and the source files the plan
names. Tell each reviewer to find blocking issues.
Tell each reviewer not to write code.

In Cursor, use the Task tool with these models and no
substitute:

- Grok 4.6: `cursor-grok-4.6-high-fast`
- GPT-5.6-Sol: `gpt-5.6-sol-high`
- Fable 5: `claude-fable-5-thinking-high`

If a requested model is not in the available list, do
not pick a replacement. Report the missing model.
Continue only when at least two reviews return.

Each reviewer must answer:

- Is this exactly one `TODO.md` PR slice?
- Does the plan violate `AGENTS.md` or `CLAUDE.md`?
- Does the plan conflict with
  `docs/specs/<util>-flags.md`, or invent a flag that
  is WONT or missing from the matrix?
- Are `src/common/` boundaries and Tiger Style caps
  respected?
- Are the tests enough for the behavior change? (See
  the `tdd` skill.)
- Blocking issues, non-blocking notes, and a vote:
  approve or request changes

Resolve every blocking issue in a revised plan. If
reviewers disagree, decide with the repo rules, then
record the decision in the plan. Re-run the three
reviewers on the delta when the revision adds
behavior, files, or a spec change. Nit-only dissent
does not need a second round.

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

## 5. Drain review comments to all-clear

Treat inline review threads as work. Loop until the
stop condition.

On each loop:

1. List unresolved review threads and new review
   comments on the PR. Include bot reviews (Bugbot,
   Security Reviewer, and similar).
2. Ignore Codex **usage-limit** issue comments.
   Those are not code review.
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
- Do not skip the comment drain after the first
  green CI run.
- Do not merge, enable auto-merge, or mark the PR
  ready unless the user asks.
- Do not start the next slice in this change.
