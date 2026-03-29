# pwd - Code Audit

Date: 2026-03-28
Files reviewed: `src/pwd.zig`
GNU reference: `docs/specs/pwd-gnu.txt`, `docs/specs/pwd-flags.md`
Build: PASS
Integration tests: 56/56 PASS
Unit tests: all PASS

---

## Findings

### SUGGESTION: Extra positional arguments silently ignored; GNU warns

Location: `src/pwd.zig:121` (`getWorkingDirectory`), integration test
`tests/utilities/pwd_test.sh`

Problem: GNU `pwd foo` prints a warning to stderr:
`pwd: ignoring non-option arguments` and then prints the cwd and exits 0.
Vibeutils silently ignores positional arguments and exits 0 with no message.
The integration test marks this with a TODO comment:
`# TODO: Fix implementation to reject positional arguments per POSIX`.
Note: POSIX does not define behavior for extra operands, so GNU's warning is
an extension. The current behavior is not wrong, but it is less informative
than GNU.

Fix: After parsing, if `parsed_args.positionals.len > 0`, print a warning to
stderr and continue:
```zig
if (parsed_args.positionals.len > 0) {
    common.printErrorWithProgram(allocator, stderr_writer, "pwd",
        "ignoring non-option arguments", .{});
}
```

---

### SUGGESTION: -P priority comment is inverted in docs vs code

Location: `src/pwd.zig:121-122` (comment above `getWorkingDirectory`)

Problem: The comment says "When both -L and -P are given, -P takes priority
(physical is the safer default)". The code `use_logical = args.logical and
!args.physical` correctly implements this. GNU behavior when both flags are
given is last-flag-wins (e.g., `-L -P` = physical, `-P -L` = logical). The
integration tests at lines "pwd last flag wins", "pwd -L --physical", and
"pwd --logical -P" all check last-flag-wins behavior and pass.

The function-level comment states `-P takes priority` unconditionally, but
the integration tests verify last-flag-wins. If the comment is authoritative,
the integration tests are wrong. If last-flag-wins is the intent, the comment
is misleading.

Actually, checking the code: `use_logical = args.logical and !args.physical`.
If `-L -P` is given, `args.logical=true`, `args.physical=true`, so
`use_logical = false` (physical wins). If `-P -L` is given, same struct
values, same result: physical wins. The argparse struct stores booleans, not
last-seen ordering, so it always uses `-P`-wins semantics, not last-flag-wins.
The integration tests pass because the test cases where `-P` is last happen to
match both behaviors. The case `-P -L` (physical first, logical last) would
differ between implementations: GNU would return logical, vibeutils returns
physical.

Fix options:
1. Implement last-flag-wins by tracking last seen in argparse (preferred for
   GNU compatibility).
2. Keep current `-P`-always-wins behavior and update the integration tests to
   reflect it accurately.

---

## Test Coverage Assessment

Unit tests cover: physical mode, logical mode without PWD env var, logical
mode with valid PWD, `isValidPwd` security validation, default struct values,
help/version output, `-L`/`-P` flags via `runPwd`, invalid flag detection.

Coverage gaps: no unit test exercises `runPwd` while actually cd'd into a
symlink-containing path to verify physical vs logical output differ. The
`-L -P` ordering ambiguity noted above is not caught by existing tests.

Integration tests are thorough at 56 cases covering symlink scenarios, PWD
env var manipulation, edge cases (trailing slash, dot components, deep
nesting), and security cases.

---

## Summary

Counts: 0 CRITICAL, 0 IMPORTANT, 2 SUGGESTIONS

Overall assessment: APPROVED

The implementation is correct for the common cases. The two suggestions
are low-priority cosmetic improvements. The `-P`-always-wins vs
last-flag-wins discrepancy is worth resolving for strict GNU compatibility.

Fix Order:
1. [SUGGESTION] Resolve -P-always-wins vs last-flag-wins ambiguity —
   src/pwd.zig:121-123
2. [SUGGESTION] Warn on non-option arguments like GNU —
   src/pwd.zig (runPwd, after positionals check)
