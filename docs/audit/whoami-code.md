# whoami - Code Audit

Date: 2026-03-28
Files reviewed: `src/whoami.zig`
GNU reference: `docs/specs/whoami-gnu.txt`, `docs/specs/whoami-flags.md`
Build: PASS
Integration tests: 7/7 PASS
Unit tests: all PASS

---

## Findings

No behavioral bugs found. The implementation is correct and complete for
its specification.

### SUGGESTION: "extra operand" error omits "Try '...' for more information."

Location: `src/whoami.zig:62-64`

Problem: GNU `whoami extra` prints:
```
whoami: extra operand 'extra'
Try '/path/to/whoami --help' for more information.
```
Vibeutils prints only:
```
whoami: extra operand 'extra'
```
The "Try..." hint is absent. The format matches GNU for the primary error line,
but the diagnostic hint is missing.

Fix:
```zig
if (parsed_args.positionals.len > 0) {
    common.printErrorWithProgram(allocator, stderr_writer, "whoami",
        "extra operand '{s}'", .{parsed_args.positionals[0]});
    common.printErrorWithProgram(allocator, stderr_writer, "whoami",
        "Try 'whoami --help' for more information.", .{});
    return @intFromEnum(common.ExitCode.misuse);
}
```

---

### SUGGESTION: Error exit code is 2 (misuse); GNU uses 1

Location: `src/whoami.zig:63`

Problem: GNU `whoami extra` exits 1. Vibeutils exits 2 (`ExitCode.misuse`).
This is consistent with the project-wide convention but diverges from GNU.
Scripts testing `whoami extra; if [ $? -eq 1 ]` would behave differently.

This is a project-wide convention issue, not unique to whoami.

---

## Test Coverage Assessment

Unit tests cover: basic output correctness (non-empty, ends with newline),
help/version with long and short flags, unknown long and short flags, extra
positional arguments, and output-matches-user-group cross-check. The
`whoami output matches current user` test is particularly strong: it
independently fetches the user info from `common.user_group` and verifies the
output string is exactly `"{username}\n"`.

No coverage gaps for the implemented functionality. The implementation is
simple enough (one OS call, one print) that the existing tests are adequate.

---

## Summary

Counts: 0 CRITICAL, 0 IMPORTANT, 2 SUGGESTIONS

Overall assessment: APPROVED

The implementation is correct. Both suggestions are minor cosmetic issues
that mirror a project-wide pattern (exit code 2 vs 1 and missing "Try..."
hint). Neither affects correctness.

Fix Order:
1. [SUGGESTION] Add "Try '...' hint" after extra-operand error —
   src/whoami.zig:62-64
2. [SUGGESTION] Resolve exit code 2 vs GNU exit code 1 for errors —
   project-wide convention
