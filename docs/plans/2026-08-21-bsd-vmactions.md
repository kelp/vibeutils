# Slice: Privileged Testing — BSD vmactions CI

## Slice name

`#### 2. GitHub Actions Workflow` remaining item:

- BSD: Set up VM-based testing with vmactions

One heading, one PR. Do not pull `VIBEUTILS_STYLE` leftovers, `du`
relative color, `tree`, or LS_COLORS.

## Predecessor gate

Predecessors #171–#187 and later TODO slices through Progress
Feedback (#200) plus main repairs (#202–#204) are on `main`.
This branch merged `origin/main` at `098a076` before the
allowlist-bypass revision.

Linux cloud agents cannot prove BSD. GitHub Actions is the proof.

## In scope

Add `.github/workflows/bsd.yml`:

- Triggers: pull_request and push to `main` (same as `test.yml`).
- `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` (repo convention).
- Concurrency group `bsd-${{ github.ref }}`, cancel-in-progress.
- `runs-on: ubuntu-latest` for every job (vmactions nests the
  BSD VM on an Ubuntu GitHub runner). `actions/checkout` (pinned
  SHA, same as `test.yml`) **before** the VM action so the tree is
  on the host and then synced in.
- Three **independent** jobs (not a matrix; no `fail-fast` key):
  FreeBSD, OpenBSD, NetBSD. A red job fails the workflow.
- **Do not write `uses: vmactions/…`.** Repo
  `selected-actions` is SHA-exact (`verified_allowed: false`).
  Runs 32502582357, 32503154809, and 32504080714 failed at parse
  with zero jobs because those remote actions are not in the
  pattern list. This environment still gets 403 on GET/PUT
  `repos/kelp/vibeutils/actions/permissions/selected-actions`.
  Waiting for an owner PUT is out of scope for this revision:
  the campaign cannot finish on that gate.
- **Allowlist bypass (this revision):** each guest job
  `actions/checkout`s this repo, clones the pinned vmactions
  SHA into a workspace path, then `uses: ./_vmactions/<os>-vm`.
  A `uses: ./…` path is a same-repo local action (kelp-owned)
  and is not matched against the third-party pattern list.
  Do not vendor `node_modules` (~26MB). Do not add git
  submodules. Do not invoke `node index.js` by hand — let the
  runner load the cloned JS action so inputs and the toolkit
  stay intact.
- Locked SHAs (last node20 releases; current `v1` / v1.5.3
  declare `using: node24`):
  - FreeBSD `vmactions/freebsd-vm`
    `c9f815bc7aa0d34c9fdd0619b034a32d6ca7b57e` (`v1.4.2`)
  - OpenBSD `vmactions/openbsd-vm`
    `9a8e4351a4a0dc6238e7c69276dcbf6c03bea576` (`v1.3.6`)
  - NetBSD `vmactions/netbsd-vm`
    `e04aec09540429f9cebb0e7941f7cd0c0fc3b44f` (`v1.3.6`)
- Clone step must `git checkout` that exact SHA (not a
  floating tag). `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` still
  upgrades the cloned node20 action at runtime.
- Pin checkout like other workflows
  (`actions/checkout@de0fac2e…` plus SHA comments).
- Keep the host-side `workflow-ok` job (checkout + pin-check
  only) so a clone/`uses` failure still leaves a Linux job
  in the graph.
- `usesh: true` on each VM.
- Install Zig **0.16.0** from ziglang.org inside `prepare` (official
  `x86_64-freebsd` / `x86_64-openbsd` / `x86_64-netbsd` tarballs). Do
  not use `mlugg/setup-zig` inside the VM (Linux/macOS action). Do not
  run `scripts/bootstrap.sh` as-is (Linux toolchain paths).
- `run`: `zig build test` then, where fakeroot exists (FreeBSD
  `pkg install fakeroot`), `fakeroot zig build test-privileged`.
  OpenBSD/NetBSD: skip fakeroot if the port is absent; still run
  unprivileged `zig build test`.
- Do not `continue-on-error`. A red BSD job is a real failure.

Wire a pin-check that actually runs on Linux CI (issue #133:
`tests/tools/` is not globbed by `test_runner.sh`):

- `tests/tools/bsd-workflow_test.sh` (executed, not sourced).
- `just test-bsd-workflow` invokes it.
- `.github/workflows/audit.yml` (or `bsd.yml` host-side step)
  runs `bash tests/tools/bsd-workflow_test.sh` so the pins cannot
  rot without a Linux job going red.

Check the TODO box. No CHANGELOG (CI-only, not user-visible). No Zig
unless CI shows a BSD-tag mismatch that must `SkipZigTest`.

## Out of scope

- `VIBEUTILS_STYLE`, `du` color, `tree`, Progress Feedback
- Making every integration shell test (`just it`) run on BSD
- OpenBSD `doas` / NetBSD privileged tests (unprivileged
  `zig build test` only there)
- macOS `vmactions` (macOS already has GitHub runners)
- Weakening GNU tests to pass on BSD
- Owner PUT of `selected-actions` (this token cannot)
- Vendoring vmactions `node_modules` or adding submodules

## Spec impact

None. No flag matrices.

## Tests

This environment cannot boot a BSD VM. Prove what we can.

Required, not optional: `tests/tools/bsd-workflow_test.sh` plus
`just test-bsd-workflow`, invoked from Linux CI. The script
asserts:

1. `.github/workflows/bsd.yml` exists.
2. It does **not** contain `uses: vmactions/` (that string is
   the parse-time allowlist failure).
3. Each guest job contains `git clone https://github.com/vmactions/<os>-vm`
   and `git checkout <locked-sha>` for that OS (not a
   file-wide SHA grep — those SHAs already sit on today's
   remote `uses:` lines). Do not `git clone --depth 1`
   without fetching the pin. Do not write the literal
   `uses: vmactions/` in comments (assert 2 is a substring).
4. Each guest job then has `uses: ./_vmactions/<os>-vm`
   (`freebsd-vm`, `openbsd-vm`, `netbsd-vm`).
5. It installs Zig 0.16.0.
6. `runs-on: ubuntu-latest` appears.
7. No `continue-on-error`.
8. `fakeroot` appears only in the FreeBSD job.

RED: update the pin-check first; current `bsd.yml` still has
`uses: vmactions/…@<sha>` and must fail the new assertions.

RED: the script fails until `bsd.yml` and the recipe exist.

GitHub CI on this PR is the real GREEN. All three guest jobs
(FreeBSD, OpenBSD, NetBSD) must finish green. A red guest job
is a real failure: diagnose and fix the portability bug. Do
**not** add `SkipZigTest` to green CI. A skip is allowed only
for a test that is documented as genuinely inapplicable on
that OS or blocked by an upstream limitation, using the exact
tag CI named (`.freebsd` / `.openbsd` / `.netbsd`) — never
`!= .linux` (that would skip macOS). Two asserts in any skip
helper. Do not pre-emptively skip.

## Risks

- First `zig build test` on a guest may fail on Linux-only
  syscalls. Diagnose and fix. Skip only when the test is
  genuinely inapplicable, using the exact tag CI named
  (`.freebsd` / `.openbsd` / `.netbsd`). Do **not** write
  `!= .linux` — that would skip macOS. Two asserts in any
  helper. All three guest jobs are required green.
- vmactions jobs are slow; 60-minute timeout. Do not add `just it`.
- Fakeroot on OpenBSD is not the Linux binary; do not assume it.
- Trust the OS: no extra path sandbox in the workflow.
- GitHub may reject `uses: ./_vmactions/…` if it treats a
  cloned third-party `action.yml` as still `vmactions/*`.
  If CI names that, fall back to a committed composite
  under `.github/actions/<os>-vm` that clones the same SHA
  and execs `node index.js` with `INPUT_*` and
  `GITHUB_ACTION_PATH`. Do not implement the fallback
  unless CI proves the local-`uses` path is blocked.
- Clone needs network on `ubuntu-latest` (already granted).
  Pin HTTPS to `github.com/vmactions/<os>-vm`.

## Plan review history

Round 1: Grok REQUEST CHANGES (SkipZigTest must not skip macOS;
wire `just` + Linux CI for the pin-check; `runs-on: ubuntu-latest`
and checkout-before-VM). GPT REQUEST CHANGES (unconditional tool
test + just recipe + Linux CI; independent jobs not a matrix
`fail-fast`). Fable APPROVE. This revision locks those.

Round 2 (this revision): owner PUT of `selected-actions` is
still 403. Change the guest jobs from `uses: vmactions/…@SHA`
to clone-at-SHA plus `uses: ./_vmactions/<os>-vm` so the
workflow can start without expanding the allowlist. Do not
vendor `node_modules`. Do not add a new TODO heading.
