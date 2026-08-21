# Slice: Privileged Testing — BSD vmactions CI

## Slice name

`#### 2. GitHub Actions Workflow` remaining item:

- BSD: Set up VM-based testing with vmactions

One heading, one PR. Do not pull `VIBEUTILS_STYLE` leftovers, `du`
relative color, `tree`, or LS_COLORS.

## Predecessor gate (recorded deviation)

Issue PRs #171–#181 and TODO PRs #182–#187 are still open. Branch from
`origin/main` (`a41eccd`). This environment cannot merge. Files:
`.github/workflows/bsd.yml`, `tests/tools/bsd-workflow_test.sh`,
`justfile`, maybe `audit.yml`, `TODO.md`. `TODO.md` will conflict;
rebase after predecessors land.

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
- FreeBSD via `vmactions/freebsd-vm` pinned to
  `83b151f58c6047089f4c80eb5ba2039d158ce093` (`v1`).
- OpenBSD via `vmactions/openbsd-vm` pinned to
  `e6c68b637a12e83519688d115d57d5b0b53923cd` (`v1`).
- NetBSD via `vmactions/netbsd-vm` pinned to
  `00081e82b14bc40114eb97f32b4455306828516b` (`v1`).
- Pin like other workflows (`checkout@de0fac2e…` plus SHA comments).
  Do not use floating `@v1` tags.
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

## Spec impact

None. No flag matrices.

## Tests

This environment cannot boot a BSD VM. Prove what we can.

Required, not optional: `tests/tools/bsd-workflow_test.sh` plus
`just test-bsd-workflow`, invoked from Linux CI. The script
asserts:

1. `.github/workflows/bsd.yml` exists.
2. It contains the three pinned SHAs above (not `@v1` unpinned).
3. It installs Zig 0.16.0.
4. `runs-on: ubuntu-latest` appears.
5. No `continue-on-error`.
6. `fakeroot` appears only in the FreeBSD job.

RED: the script fails until `bsd.yml` and the recipe exist.

GitHub CI on this PR is the real GREEN for `zig build test` on
FreeBSD. Iterate SkipZigTest only for the **BSD tags CI named**
(`.freebsd`, `.openbsd`, `.netbsd`) — never `!= .linux` (that
would skip macOS). Two asserts in any skip helper. Do not
pre-emptively skip.

## Risks

- First FreeBSD `zig build test` may fail on Linux-only syscalls.
  Skip only the failing `builtin.os.tag` values CI reported
  (`.freebsd` / `.openbsd` / `.netbsd`). Do **not** write
  `!= .linux` — that would skip macOS. Two asserts in the helper.
- vmactions jobs are slow; 60-minute timeout. Do not add `just it`.
- Fakeroot on OpenBSD is not the Linux binary; do not assume it.
- Trust the OS: no extra path sandbox in the workflow.

## Plan review history

Round 1: Grok REQUEST CHANGES (SkipZigTest must not skip macOS;
wire `just` + Linux CI for the pin-check; `runs-on: ubuntu-latest`
and checkout-before-VM). GPT REQUEST CHANGES (unconditional tool
test + just recipe + Linux CI; independent jobs not a matrix
`fail-fast`). Fable APPROVE. This revision locks those.
