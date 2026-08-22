# Slice: Bugs (`ls` pipe columns / #113)

## Slice name

`## Bugs`

One heading, one PR. The heading has a single
unchecked box: `ls` does not switch to single-column
output when stdout is a pipe (POSIX, tracked as
#113). Do not pull `## Success Criteria`, leftover
`du` color, `### 6. Progress Feedback`, or any
Testing Improvements heading.

## Predecessor gate (recorded deviation)

Listed order would wait for `### 6` dd conv=
(PR #196) and several earlier slices to land on
`main`. This environment cannot merge. Branch from
`github/main` (`a41eccd`). Do **not** stack on
#177, #189, #195, or #196.

`TODO.md` will conflict with stacked slices.

## Classification

The bug is **already fixed and closed**. GitHub
issue #113 is CLOSED (2026-08-01,
"ls: multi-column output when stdout is not a
terminal (POSIX requires -1)"). Production already
forces one-per-line when stdout is not a TTY
(`src/ls/formatter.zig` around the POSIX comment
"If the standard output is not a terminal, the
default format shall be the same as the -1
option."). Integration coverage already lives in
`tests/utilities/ls_test.sh` under
`# Issue #113:` (piped default, redirected file,
no trailing whitespace, `-C`/`-x`/`-m` keep their
layouts, `-1` and `-l` unchanged, `-R` one-per-line
per section). Zig unit coverage exists in
`src/ls/integration_test.zig`
(`format: default output is one entry per line
when stdout is not a terminal`).

This slice is a **verify-and-check** of the
unchecked `TODO.md` box. No user-visible change.
No `CHANGELOG`. No `src/ls/` edit. No new tests
unless verification finds a missing locked
assertion (it should not).

Skip red-green TDD: the change does not change
program behavior (`land-todo-slice` §4).

## In scope

1. Re-run `just it-util ls` (or the #113-named
   cases) on unmodified HEAD and confirm the
   existing names PASS:
   - `ls #113: default output piped is one entry per line`
   - `ls #113: default output redirected to a file is one entry per line`
   - `ls #113: default piped output has no trailing whitespace`
2. Confirm `grep` of `src/ls/` still sets
   `one_per_line` when stdout is not a terminal.
3. Implementer checks the `## Bugs` box in
   `TODO.md`.

## Out of scope

- Any edit to `src/ls/`.
- New tests (existing #113 block already pins the
  gale `grep -v '\.lock$'` failure mode: no
  trailing padding whitespace on piped default
  output).
- Reopening or commenting on GitHub #113.
- `## Success Criteria`.
- Leftover `du` color (`### 4`).
- Progress feedback for `cp`/`mv`/`dd`.
- `CHANGELOG.md`, man pages, flag matrix.

## Spec impact

No change. POSIX `ls` non-tty default = `-1` is
already the implemented contract.

## Tests

None new. Test-writer does not add files. If
`just it-util ls` shows a #113 case FAIL on
unmodified HEAD, stop and treat that as a real
bug (separate from this check-off).

Implementer commit: check the one `TODO.md` box.
Do not edit `ls_test.sh` or `src/ls/`.

Local gates: `just fmt-check`. `just it-util ls`
on the test-writer/verifier pass (or the planner
records a green run in the PR). Skip `just test`
unless Zig is forced (it must not be).

## TDD ownership

- Verifier/test-writer: confirm existing tests
  PASS; no test file edits.
- Implementer: `TODO.md` box only.

## Risks

- Checking the box without the tests would hide a
  regression. The existing names are the teeth;
  do not delete them.
- `src/common/` untouched.
- Tiger: no new Zig.

## Files

| File | Who | What |
|---|---|---|
| `docs/plans/2026-08-22-ls-pipe-columns.md` | planner | this plan |
| `TODO.md` | implementer | check the Bugs box |

## Stop condition

- Existing #113 integration names PASS
- `TODO.md` `## Bugs` box checked
- `src/ls/` and `tests/utilities/ls_test.sh`
  untouched
