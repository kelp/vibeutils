---
description: Run tests natively and, where a second platform is reachable, there too (macOS + Linux via OrbStack)
disable-model-invocation: true
---

# /test-platforms [utility]

Run the tests on every platform this host can actually
reach. On the macOS dev box that is macOS natively plus
Linux via `orb -m ubuntu`. In an agent container you are
already on Linux and have no `orb`: run the suites
natively and let CI cover macOS.

## Prerequisites

Check both of these before running anything:

- `uname -s` — which platform you are natively on.
- `command -v orb` — whether a second platform is
  reachable at all.

If `orb` is absent there is no second platform here. Do
not try to install it and do not silently substitute
Docker. Mark the other platform UNAVAILABLE and note
that CI covers it.

## With argument (e.g., `/test-platforms wc`):

Run on each platform available:

- Native: `just test-util $ARG`
- Second platform (only with `orb`):
  `orb -m ubuntu zig build test` (the Ubuntu VM has
  `zig` but not `just`, so run the unit suite directly)

## Without argument:

Run on each platform available:

- Native: `zig build test` (unit) and `just it`
  (integration)
- Second platform (only with `orb`):
  `orb -m ubuntu zig build test` (unit), then
  `orb -m ubuntu zig build` and
  `orb -m ubuntu bash scripts/run-integration.sh`
  (integration). The Ubuntu VM has `zig` but not `just`,
  so invoke the script directly (matches the release
  flow).

Always drive the integration suite through
`scripts/run-integration.sh` (or `just it` /
`just it-util`), never `tests/integration.sh` directly.
Only the wrapper drops from uid 0 to an unprivileged
user; run as root, roughly two dozen permission-denied
tests fail spuriously.

## Execution

Run the native tests first, then the second platform if
one exists. Run second-platform commands with
`orb -m ubuntu` from the project directory, calling
`zig`/`bash` directly since `just` is not installed in
the VM.

## Report

Present results in a side-by-side table. Name the rows
for the platforms you actually ran on, and keep a row
for one you could not reach:

```
| Platform | Unit Tests  | Integration |
|----------|-------------|-------------|
| Linux    | PASS        | PASS        |
| macOS    | UNAVAILABLE | UNAVAILABLE |
```

When a utility argument is provided, use a single "Tests"
column instead:

```
| Platform | Tests       |
|----------|-------------|
| Linux    | PASS        |
| macOS    | UNAVAILABLE |
```

Mark failed steps as FAIL and include the relevant error
output below the table. Mark skipped steps as SKIPPED.
Mark a platform you have no way to reach as UNAVAILABLE
and add a line saying it is deferred to CI. UNAVAILABLE
is not PASS and must never be reported as one.
