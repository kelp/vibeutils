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

1. `make test UTIL=$ARG`

## Without argument:

Run on each platform:

1. `zig build test` (unit tests)
2. `make it` (integration tests)

## Execution

Run macOS tests first, then Linux tests. For Linux, prefix
each command with `orb -m ubuntu` and run from the project
directory.

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
