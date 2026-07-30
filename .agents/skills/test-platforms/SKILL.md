---
description: Run tests on macOS and Linux (via OrbStack)
disable-model-invocation: true
---

# /test-platforms [utility]

Run tests on both macOS (native) and Linux (via `orb -m ubuntu`).

## Prerequisites

- Linux testing requires OrbStack (`orb`) to be installed
- If `orb` is not available, skip Linux and note it was skipped

## With argument (e.g., `/test-platforms wc`):

Run on each platform:

- macOS: `just test-util $ARG`
- Linux: `orb -m ubuntu zig build test` (the Ubuntu VM has
  `zig` but not `just`, so run the unit suite directly)

## Without argument:

Run on each platform:

- macOS: `zig build test` (unit) and `just it` (integration)
- Linux: `orb -m ubuntu zig build test` (unit), then
  `orb -m ubuntu zig build` and
  `orb -m ubuntu bash tests/integration.sh` (integration).
  The Ubuntu VM has `zig` but not `just`, so invoke the
  integration script directly (matches the release flow).

## Execution

Run macOS tests first, then Linux tests. Run Linux commands
with `orb -m ubuntu` from the project directory, calling
`zig`/`bash` directly since `just` is not installed in the VM.

Check whether `orb` is available before attempting Linux
tests. If the command is not found, skip Linux and mark it
as SKIPPED in the results table.

## Report

Present results in a side-by-side table:

```
| Platform | Unit Tests | Integration |
|----------|------------|-------------|
| macOS    | PASS       | PASS        |
| Linux    | PASS       | PASS        |
```

When a utility argument is provided, use a single "Tests"
column instead:

```
| Platform | Tests |
|----------|-------|
| macOS    | PASS  |
| Linux    | PASS  |
```

Mark failed steps as FAIL and include the relevant error
output below the table. Mark skipped steps as SKIPPED.
