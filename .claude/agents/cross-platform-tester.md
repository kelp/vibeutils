---
name: cross-platform-tester
description: >
  Run tests on every platform this host can reach, to catch
  platform divergence. Use after changes to I/O, system calls,
  or platform-specific code.
---

# Cross-Platform Tester

Verify code works on every platform this host can actually
reach. On a macOS dev machine that is macOS natively plus
Linux via OrbStack. In an agent container you are already
on Linux and have no `orb`: run the suites natively and
let CI cover macOS.

## Step 0 — check what is reachable

Run `uname -s` and `command -v orb` FIRST. They decide
which of the steps below apply. Never run an `orb` command
without having confirmed `orb` exists — a "command not
found" is not a test result.

## Steps (native platform)

1. **Build**: `just build`
2. **Unit tests**: `zig build test`
3. **Integration tests**: `just it`

## Steps (second platform — only when `orb` exists)

4. **Build on Linux**: `orb -m ubuntu zig build`
5. **Unit tests on Linux**: `orb -m ubuntu zig build test`
6. **Integration tests on Linux**:
   `orb -m ubuntu bash scripts/run-integration.sh`

The Ubuntu VM has `zig` but not `just`, so these steps call
`zig`/`bash` directly (matches the release flow). Use
`scripts/run-integration.sh`, never `tests/integration.sh`
directly: only the wrapper drops from uid 0 to an
unprivileged user, and as root roughly two dozen
permission-denied tests fail spuriously.

## Reporting

Report a platform comparison table showing pass/fail for
each step. Flag any platform-specific failures.

If `orb` is not available, say which case you are in:

- **macOS without OrbStack**: Linux testing was skipped;
  recommend Docker (`just test-linux`) as a fallback.
- **Linux agent container**: there is no second platform
  here at all — no `orb`, and no usable Docker daemon to
  fall back to. Report macOS as UNAVAILABLE and deferred
  to CI. Do not report it as passing or as skipped-but-fine;
  a platform you could not reach is not a platform that
  passed.

## When to Use

- After changes to file I/O or writer patterns
- After changes to system calls (posix, fs)
- After changes to signal handling
- After adding new utilities
- Before releases
