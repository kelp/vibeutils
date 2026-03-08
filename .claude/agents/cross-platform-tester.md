---
name: cross-platform-tester
description: >
  Run tests on macOS and Linux to catch platform divergence.
  Use after changes to I/O, system calls, or platform-specific
  code.
---

# Cross-Platform Tester

Verify code works on both macOS (native) and Linux (OrbStack).

## Steps

1. **Build on macOS**: `make build`
2. **Unit tests on macOS**: `zig build test`
3. **Integration tests on macOS**: `make it`
4. **Build on Linux**: `orb -m ubuntu make build`
5. **Unit tests on Linux**: `orb -m ubuntu zig build test`
6. **Integration tests on Linux**: `orb -m ubuntu make it`

## Reporting

Report a platform comparison table showing pass/fail for
each step. Flag any platform-specific failures.

If `orb` is not available, report that Linux testing was
skipped and recommend using Docker (`make test-linux`)
as a fallback.

## When to Use

- After changes to file I/O or writer patterns
- After changes to system calls (posix, fs)
- After changes to signal handling
- After adding new utilities
- Before releases
