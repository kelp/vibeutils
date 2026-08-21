# Slice: Privileged Testing — BSD vmactions CI

## Slice name

`#### 2. GitHub Actions Workflow` remaining item:

- BSD: Set up VM-based testing with vmactions

One heading, one PR. Do not pull `VIBEUTILS_STYLE` leftovers, `du`
relative color, `tree`, or LS_COLORS.

## Predecessor gate (recorded deviation)

Issue PRs #171–#181 and TODO PRs #182–#187 are still open. Branch from
`origin/main` (`a41eccd`). This environment cannot merge. This slice's
files (`.github/workflows/bsd.yml`, `TODO.md`) are disjoint from #187
(`src/ls`, `src/common/ls_colors.zig`). `TODO.md` will conflict; rebase
after predecessors land.

Linux cloud agents cannot prove BSD. GitHub Actions is the proof.

## In scope

Add `.github/workflows/bsd.yml`:

- Triggers: pull_request and push to `main` (same as `test.yml`).
- `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` (repo convention).
- Concurrency group `bsd-${{ github.ref }}`, cancel-in-progress.
- Three jobs, `fail-fast: false`, timeout 60 minutes each:
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

Check the TODO box. No CHANGELOG (CI-only, not user-visible). No Zig
unless CI shows a Linux-only test that must `SkipZigTest` on BSD.

## Out of scope

- `VIBEUTILS_STYLE`, `du` color, `tree`, Progress Feedback
- Making every integration shell test (`just it`) run on BSD
- macOS `vmactions` (macOS already has GitHub runners)
- Weakening GNU tests to pass on BSD

## Spec impact

None. No flag matrices.

## Tests

This environment cannot boot a BSD VM. Prove what we can:

1. Workflow file exists at `.github/workflows/bsd.yml`.
2. It references the three pinned SHAs above (not `@v1`).
3. It installs Zig 0.16.0, not another version.
4. `yamllint` or `python3 -c 'import yaml; yaml.safe_load(...)'` if
   PyYAML is present; otherwise a `rg` assertion in
   `tests/tools/bsd-workflow_test.sh` sourced like other tool tests.
5. GitHub CI on this PR is the real GREEN for `zig build test` on
   FreeBSD. Iterate SkipZigTest only for `builtin.os.tag` mismatches
   CI reports — do not pre-emptively skip.

RED: the test script fails until `bsd.yml` exists with those pins.

## Risks

- First FreeBSD `zig build test` may fail on Linux-only syscalls.
  Fix with `if (builtin.os.tag != .linux) return error.SkipZigTest`
  only where the failure is OS-real, with two asserts in the helper.
- vmactions jobs are slow; 60-minute timeout. Do not add `just it`.
- Fakeroot on OpenBSD is not the Linux binary; do not assume it.
- Trust the OS: no extra path sandbox in the workflow.

## Plan review history

Round 1: pending.
