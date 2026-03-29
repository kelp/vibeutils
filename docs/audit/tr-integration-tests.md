# tr Integration Test Audit

Date: 2026-03-28
Auditor: reviewer agent
Result: NEEDS_FIXES

## Test Run Results

43/43 tests pass.

## Test Inventory

| Category | Tests | Type |
|---|---|---|
| Binary exists | 1 | infrastructure |
| --help / --version | 2 | behavioral |
| Error: missing args | 2 | behavioral |
| Basic translation | 7 | behavioral |
| Character ranges | 2 | behavioral |
| Character classes [:upper:]/[:lower:] | 2 | behavioral |
| Delete mode (-d) | 5 | behavioral |
| Squeeze mode (-s) | 3 | behavioral |
| Delete + squeeze (-ds) | 1 | behavioral |
| Complement mode (-c) | 2 | behavioral |
| Truncate mode (-t) | 1 | behavioral |
| Escape sequences (\t, \n) | 2 | behavioral |
| Edge cases | 4 | behavioral |
| POSIX compliance / exit codes | 5 | mixed |
| Error conditions | 3 | behavioral |

The suite is largely behavioral, not exit-code-only stubs.
stdin piping is used correctly throughout via `bash -c "... | '$binary' ..."`.

## Bugs Found

### BUG 1: `[x*]` repeat notation ignored

**Symptom:** `[x*]` in SET2 should expand character `x` to fill
the full length of SET1. vibeutils treats it as three literal
characters `[`, `x`, `*`, `]` instead.

```
# System:
printf 'abc' | /usr/bin/tr 'abc' '[x*]'  # -> xxx

# vibeutils:
printf 'abc' | tr 'abc' '[x*]'           # -> abc (wrong, passthrough)
```

**Affected variants:**
- `[x*]` — fill remainder of SET2 with x (broken)
- `[x*0]` — POSIX synonym for fill (broken)
- `[x*N]` where N > 0 — explicit count (works correctly)

This is a POSIX MUST feature. The `[x*]` form is the primary
mechanism for mapping many-to-one in SET2 without relying on
last-character extension behavior.

### BUG 2: Extra operands not rejected

**Symptom:** `tr a b c` should fail with exit code 1 and an error
message. vibeutils exits 0 silently.

```
# System:
echo x | /usr/bin/tr a b c
# -> tr: extra operand 'c' (exit 1)

# vibeutils:
echo x | tr a b c
# -> x (exit 0, no error, 'c' silently ignored)
```

This is a correctness gap. Scripts relying on `tr` to reject
malformed invocations will silently misbehave.

## Coverage Gaps

### -u flag: no behavioral test

The `-u` flag (unbuffered output) is listed as SHOULD tier in
`docs/specs/tr-flags.md`. The test suite has no test for it at
all — not even an exit-code check. Manual testing confirms
vibeutils accepts `-u` without error. Whether it actually changes
buffering behavior is not verified.

### [:blank:] and other POSIX classes: partially tested

The suite tests `[:upper:]`, `[:lower:]`, and `[:digit:]`, but
does not test:
- `[:blank:]` (space + tab)
- `[:punct:]`
- `[:print:]`
- `[:space:]`
- `[:alnum:]`
- `[:graph:]`
- `[:cntrl:]`

Manual testing shows `[:blank:]` and `[:punct:]` work correctly,
but they have no regression tests.

### Repeat notation `[x*N]`: no test

The working form `[x*3]` has no test case. Because the broken
forms `[x*]` and `[x*0]` are also untested, the test suite does
not catch either the bug or document the working variant.

### Octal `\nnn` in SET: not tested

POSIX specifies `\nnn` (1-3 octal digits) for arbitrary byte
values. The suite uses `\n`, `\t`, and `\0` escape names but
never tests raw octal notation like `\141` for `a`.
Manual testing shows octal notation works, but it has no test.

### Equivalence classes `[=c=]`: not tested

GNU/POSIX tr supports `[=c=]` equivalence classes (useful for
locale-aware matching). Manual testing shows vibeutils handles
the ASCII case correctly but no test covers this.

### Multi-operand rejection: not tested

See Bug 2. No test asserts that `tr a b c` (three operands)
fails.

### -s with character class: no test

Squeeze using a POSIX class (`tr -s '[:alpha:]'`) is not
tested. Manual testing shows it works correctly.

### Large input (behavioral): weak

The existing large-input test (`dd if=/dev/zero`) verifies exit
code only. It does not assert any output content.

## Findings Summary

```
[CRITICAL] [x*] and [x*0] repeat notation not implemented
Location: tests/utilities/tr_test.sh (missing test exposes production bug)
Problem: POSIX requires [x*] in SET2 to repeat character x to fill
         the length of SET1. vibeutils passes the literal characters
         through instead. [x*0] has identical behavior. Both forms
         must expand to a repeated character, not be treated as
         literal bracket expressions.
Fix: Add tests:
     test_command_output "tr [x*] repeat fill" "xxx" \
       bash -c "printf 'abc' | '$binary' 'abc' '[x*]'"
     test_command_output "tr [x*0] repeat fill" "xxxxx" \
       bash -c "printf 'abcde' | '$binary' 'abcde' '[x*0]'"
     Then fix the production code — the SET parser must recognise
     the [c*] form in SET2 and expand it before building the
     translation table.

[IMPORTANT] Extra operands silently ignored, wrong exit code
Location: tests/utilities/tr_test.sh (missing test)
Problem: GNU and macOS tr both exit 1 with an error message when
         given a third operand. vibeutils exits 0 and silently
         ignores the extra argument, masking user mistakes.
Fix: Add test:
     test_command_exit_code "tr extra operand rejected" 1 \
       bash -c "echo x | '$binary' a b c 2>/dev/null"
     Then fix production code to detect argc > 3 (after flag
     parsing) and exit 1 with an error.

[IMPORTANT] [x*N] repeat notation: no regression test
Location: tests/utilities/tr_test.sh (missing test)
Problem: [x*3] works correctly but has no test. If the SET
         parser is refactored to fix [x*] it could break [x*3].
Fix: Add test:
     test_command_output "tr [x*3] explicit repeat" "xxxyz" \
       bash -c "printf 'abcde' | '$binary' 'abcde' '[x*3]yz'"

[SUGGESTION] Add tests for [:blank:], [:punct:], [:print:] classes
Location: tests/utilities/tr_test.sh (coverage gap)
Problem: Only [:upper:], [:lower:], and [:digit:] are tested.
         Other POSIX classes are implemented but unguarded.
Fix: Add one behavioral test per untested class.

[SUGGESTION] Add test for octal \nnn notation
Location: tests/utilities/tr_test.sh (coverage gap)
Problem: Octal escape notation is a POSIX requirement and works
         correctly, but has no test.
Fix: Add test:
     test_command_output "tr octal escape in SET" "xyz" \
       bash -c "printf '\\001\\002\\003' | '$binary' '\\001\\002\\003' 'xyz'"

[SUGGESTION] Add -u flag test
Location: tests/utilities/tr_test.sh (coverage gap)
Problem: -u (SHOULD tier) has zero tests.
Fix: At minimum add an exit-code test confirming -u is accepted:
     test_command_exit_code "tr -u flag accepted" 0 \
       bash -c "echo test | '$binary' -u a b"
```

## Fix Order

```
Fix Order:
1. [CRITICAL] [x*] / [x*0] repeat notation broken — src/tr.zig (SET parser)
2. [IMPORTANT] Extra operands silently ignored — src/tr.zig + tr_test.sh
3. [IMPORTANT] [x*N] regression test missing — tr_test.sh
4. [SUGGESTION] POSIX class coverage — tr_test.sh
5. [SUGGESTION] Octal \nnn test — tr_test.sh
6. [SUGGESTION] -u flag test — tr_test.sh
```

REVIEW COMPLETE - NEEDS_FIXES
