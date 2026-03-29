# true — Code Audit

**Date:** 2026-03-28
**Assessment:** NEEDS_FIXES
**Tests:** 8/8 integration pass, 2 unit tests (all pass)

---

## Summary

true correctly exits 0 in all tested cases. The core
behavioral contract (always exit 0, produce no output) is
met. One important deviation from GNU: GNU `true --help`
and `true --version` produce output and still exit 0.
vibeutils silently ignores these flags, producing no
output. This diverges from expected behavior for users
who invoke `true --help`.

---

## Findings

### IMPORTANT

```
[IMPORTANT] --help and --version produce no output
Location: src/true.zig:11-18
Problem: GNU true supports --help and --version as special
  cases that print help/version text then exit 0. All
  other arguments (including misspelled options) are
  silently ignored with exit 0 per POSIX. vibeutils
  ignores --help and --version entirely, producing no
  output.

  $ /usr/bin/true --help  (prints usage text, exits 0)
  $ zig-out/bin/true --help  (prints nothing, exits 0)

  The exit code is correct (0 in both cases) but the
  missing output means `true --help` is a silent no-op.
  The flags.md spec does not document --help/--version,
  but GNU coreutils true does implement them.
Fix: Add --help and --version handling with appropriate
  output, similar to false. Both should exit 0. All
  other flags continue to be silently ignored per POSIX.
```

---

### SUGGESTION

```
[SUGGESTION] main() bypasses the runTrue wrapper
Location: src/true.zig:22
Problem: main() calls std.process.exit(0) directly,
  bypassing runTrue entirely. This is not a behavioral
  bug (true must always exit 0) but it means the
  runTrue function is never called from main, making the
  production code path untested at the integration
  boundary.
Fix: For consistency with other utilities, wire main()
  through runTrue. In this case it is a very minor
  concern because the behavior is trivially correct.
  Acceptable to leave as-is given the utility's
  simplicity.
```

---

## What Is Correct

- Always exits 0 regardless of arguments.
- Produces no stdout or stderr output (for non-help args).
- POSIX conformant: ignores all non-help arguments.
- Exit code behavior matches GNU for ordinary usage.

---

## Fix Order

1. [IMPORTANT] --help / --version produce no output — src/true.zig:11-18
