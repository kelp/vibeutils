# yes — Code Audit

**Date:** 2026-03-28
**Assessment:** NEEDS_FIXES
**Tests:** 8/8 integration pass, 8 unit tests (all pass)

---

## Summary

yes is behaviorally correct for its core function. Two
deviations from GNU exist: the exit code on unknown options
(2 instead of 1), and the error message omits the "Try
'yes --help'" hint. Both are minor. The buffering
optimization for large strings is well-implemented and
regression-tested.

---

## Findings

### IMPORTANT

```
[IMPORTANT] Unknown option exits with code 2, GNU exits with code 1
Location: src/yes.zig:33
Problem: When an unknown flag is passed, runYes returns
  ExitCode.misuse (2). GNU yes exits 1 on unrecognized
  options. The exit code is part of observable behavior.
  $ yes --bad 2>/dev/null; echo $?
  GNU: 1
  vibeutils: 2
Fix: Return ExitCode.general_error (1) instead of
  ExitCode.misuse (2) for UnknownFlag in the yes error
  handler.
```

```
[IMPORTANT] Error message omits "Try '... --help'" hint
Location: src/yes.zig:32
Problem: GNU yes prints:
  "yes: unrecognized option '--badoption'"
  "Try 'yes --help' for more information."
  vibeutils prints only:
  "yes: unrecognized option"
  The option name is not included in the message and the
  hint line is absent.
Fix: Include the unknown flag name in the error message
  and add the hint line, matching GNU format:
  common.printErrorWithProgram(..., "yes",
    "unrecognized option '{s}'", .{flag_name});
  then print the hint. This requires the argparse error
  to carry the flag name, or catching it differently.
```

---

### SUGGESTION

```
[SUGGESTION] Help flag uses -h, GNU uses only --help
Location: src/yes.zig:14, YesArgs.meta
Problem: GNU yes exposes only --help (long form). vibeutils
  adds -h as a short alias. This is a harmless extension
  but diverges from GNU. The flags.md already documents
  that no flags reach MUST tier for yes.
Fix: No action required unless strict GNU compat is needed.
  Document intentional extension.
```

```
[SUGGESTION] Version flag is -V/--version, GNU is --version only
Location: src/yes.zig:15, YesArgs.meta
Problem: Same pattern as above — GNU yes provides only
  --version (no -V short alias). vibeutils adds -V.
Fix: Same as above — document as intentional extension.
```

---

## What Is Correct

- Default output "y\n" matches GNU.
- Multiple arguments joined with spaces matches GNU.
- Silent exit on SIGPIPE / BrokenPipe is correct.
- Large-string path (>8192 bytes) writes directly and is
  regression-tested with three edge cases.
- Buffer-fill loop for short strings is correct and
  efficient.
- `--` end-of-options terminates flag parsing; subsequent
  args become positionals (matching GNU: `yes --` outputs
  "y").

---

## Fix Order

1. [IMPORTANT] Unknown option exit code 2 vs 1 — src/yes.zig:33
2. [IMPORTANT] Error message missing flag name and hint — src/yes.zig:32
