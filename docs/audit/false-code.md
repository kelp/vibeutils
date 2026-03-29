# false — Code Audit

**Date:** 2026-03-28
**Assessment:** NEEDS_FIXES
**Tests:** 8/8 integration pass, 2 unit tests (all pass)

---

## Summary

false correctly exits 1 in all tested cases, including
when passed arbitrary arguments. The core behavioral
contract is met. Two deviations from GNU: --help and
--version produce no output (GNU produces text for both),
and the exit code for those flags must remain 1 per GNU
(which it currently does, correctly). The main gap is
missing --help/--version output.

---

## Findings

### IMPORTANT

```
[IMPORTANT] --help and --version produce no output
Location: src/false.zig:11-19
Problem: GNU false supports --help and --version as special
  cases that print help/version text, then exit with the
  utility's normal exit code (1). vibeutils false
  silently ignores these flags entirely.

  $ /usr/bin/false --help   (prints usage text, exits 1)
  $ /usr/bin/false --version (prints version, exits 1)
  $ zig-out/bin/false --help   (no output, exits 1)
  $ zig-out/bin/false --version (no output, exits 1)

  Exit codes are correct (both exit 1), but the missing
  output diverges from GNU. A user invoking `false --help`
  gets no information.
Fix: Add --help and --version output. The exit code must
  remain 1 (not 0) — false always exits 1, even after
  printing help. This is the key difference from true.
  Example structure:
    if (args includes --help) { printHelp(); return 1; }
    if (args includes --version) { printVersion(); return 1; }
```

---

### SUGGESTION

```
[SUGGESTION] main() bypasses the runFalse wrapper
Location: src/false.zig:22
Problem: main() calls std.process.exit(1) directly,
  bypassing runFalse entirely. Same pattern as true.
  Not a behavioral bug but the runFalse production code
  path is never exercised from main.
Fix: Wire main() through runFalse for consistency. Not
  urgent given the utility's simplicity.
```

---

## What Is Correct

- Always exits 1 regardless of arguments.
- Produces no stdout or stderr output for non-help args.
- POSIX conformant: ignores all non-help arguments.
- Exit code remains 1 even for --help/--version (correct
  GNU behavior: false always exits 1).

---

## Fix Order

1. [IMPORTANT] --help / --version produce no output — src/false.zig:11-19
