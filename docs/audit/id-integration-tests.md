# id Integration Test Audit

Date: 2026-03-28
Auditor: reviewer agent
Result: NEEDS_FIXES

## Test Run

```
Tests run: 15
Passed:    15
Failed:    0
```

All 15 tests pass.

## Test Inventory

| # | Test Name | Type | Strength |
|---|-----------|------|----------|
| 1 | id binary | binary exists | weak |
| 2 | id --help | exit-code only | weak |
| 3 | id --version | exit-code only | weak |
| 4 | id default output format | regex presence | medium |
| 5 | id -u prints numeric user ID | pattern match | medium |
| 6 | id -g prints numeric group ID | pattern match | medium |
| 7 | id -G prints group IDs | pattern match | weak |
| 8 | id -un matches whoami | value match | strong |
| 9 | id --help shows usage | content check | medium |
| 10 | id --version shows version | content check | medium |
| 11 | id invalid flag exits 2 | exit-code only | weak |
| 12 | id -n alone exits 2 | exit-code only | weak |
| 13 | id nonexistent user exits 1 | exit-code only | weak |
| 14 | id -g numeric GID (regression) | pattern match | medium |
| 15 | id -gn group name (regression) | pattern match | medium |

## Flag Coverage vs id-flags.md

| Flag | Tier | Tested | Test Quality |
|------|------|--------|--------------|
| -u | MUST | yes | medium — pattern only |
| -g | MUST | yes | medium — pattern only |
| -G | MUST | yes | weak — starts with digit only |
| -n | MUST | partial — only -un/-gn | no -Gn test |
| -r | MUST | no | zero coverage |
| -p | MUST | no | zero coverage |
| -a | SHOULD | no | zero coverage |
| -A | SHOULD | no | zero coverage |
| -F | SHOULD | no | zero coverage |
| -P | SHOULD | no | zero coverage |
| -z | SHOULD | no | zero coverage |

## Issues Found

---

```
[CRITICAL] -z alone accepted when GNU requires it to pair with -u/-g/-G
Location: tests/utilities/id_test.sh (no test)
Problem: GNU id exits 1 with "option --zero not permitted in default format"
         when -z is used without -u/-g/-G. The vibeutils implementation
         silently succeeds and emits NUL-terminated default output instead.
         The flag-coverage spec marks -z as SHOULD. No test exists to catch
         this divergence.
Fix: Add a test verifying `id -z` exits 1 with an error message, matching
     GNU behavior.
```

---

```
[IMPORTANT] -r flag has zero integration test coverage
Location: tests/utilities/id_test.sh (missing)
Problem: -r is a MUST-tier flag (POSIX). No test verifies that `id -r -u`
         or `id -r -g` prints the real (not effective) UID/GID. The only
         indirect evidence it works is that it does not crash.
Fix: Add tests for `id -r -u` (numeric only), `id -r -g`, and `id -r -u
     -n` (real username). Verify output equals the running user's real
     UID/GID, comparable against /usr/bin/id -r -u.
```

---

```
[IMPORTANT] -p flag has zero integration test coverage
Location: tests/utilities/id_test.sh (missing)
Problem: -p is a MUST-tier flag (present in both our spec and macOS man
         page). No test verifies the human-readable multi-line output
         format ("uid\t<name>\ngroups\t<names>"). Probing shows it works,
         but output format is untested.
Fix: Add a test that runs `id -p` and checks for "uid" and "groups" labels
     on separate lines. Also test `id -p <user>` with a known user (root).
```

---

```
[IMPORTANT] -G output is weakly tested — order and value unverified
Location: tests/utilities/id_test.sh:61
Problem: The -G test only checks that output starts with a digit
         (`[[ "$groups_output" =~ ^[0-9] ]]`). It does not verify the
         actual group IDs or that all groups appear. Probing also reveals
         that vibeutils -G and GNU -G list groups in different order
         (vibeutils: supplementary first; GNU: effective GID first). This
         divergence is undetected.
Fix: Cross-check `$binary -G` output against `/usr/bin/id -G` (on Linux)
     by sorting both and comparing. Also assert that the output is
     space-separated numbers, not comma-separated.
```

---

```
[IMPORTANT] -Gn has no integration test
Location: tests/utilities/id_test.sh (missing)
Problem: -n is a MUST-tier flag and the -Gn combination (print group
         names for all supplementary groups) is a distinct code path from
         -un and -gn. No test covers it. Probing shows it works but
         correctness is unverified.
Fix: Add a test for `id -Gn` that checks output contains only non-numeric
     tokens (group names) and that the count matches `id -G | wc -w`.
```

---

```
[IMPORTANT] Default output groups order differs from GNU — not detected
Location: tests/utilities/id_test.sh:22
Problem: GNU id prints effective GID first in the groups= list:
         groups=1000(tcole),27(sudo),100(users)
         vibeutils prints supplementary groups first:
         groups=27(sudo),100(users),1000(tcole)
         The default-output test only checks that uid=, gid=, and groups=
         appear — it cannot catch this ordering divergence.
Fix: On Linux, compare `$binary` output directly against `/usr/bin/id`
     output for the current user, or at minimum assert that the first
     entry in groups= matches the GID from `id -g`.
```

---

```
[IMPORTANT] -F flag has zero integration test coverage
Location: tests/utilities/id_test.sh (missing)
Problem: -F (print full/GECOS name) is a SHOULD-tier flag that is
         implemented (probing shows it returns the GECOS field). No test
         verifies this output.
Fix: Add a test that runs `id -F` and checks that output is a non-empty
     string. For a known user (root), verify the output matches getent
     passwd root | cut -d: -f5.
```

---

```
[IMPORTANT] -P flag has zero integration test coverage
Location: tests/utilities/id_test.sh (missing)
Problem: -P (passwd-file-entry format) is a SHOULD-tier flag that is
         implemented. Probing shows output like:
         tcole:x:1000:1000::0:0:Travis Cole:/home/tcole:/bin/fish
         No test checks this format.
Fix: Add a test that runs `id -P` and verifies the colon-delimited format
     (7+ fields). Run `id -P root` and compare UID field against
     `id -u root`.
```

---

```
[IMPORTANT] -A flag behavior untested
Location: tests/utilities/id_test.sh (missing)
Problem: -A is a SHOULD-tier flag. The implementation emits an error
         message on Linux ("not supported on this platform") but exits 0
         (probing not conclusive — needs explicit exit code check). No
         test documents the expected behavior on the test platform.
Fix: Add a platform-conditional test. On Linux, verify `id -A` exits 1
     with a clear "not supported" message. On macOS (if/when tested),
     verify it requires privilege.
```

---

```
[SUGGESTION] Error tests check exit code but not stderr message
Location: tests/utilities/id_test.sh:112-121
Problem: Three error-condition tests ("invalid flag exits 2", "-n alone
         exits 2", "nonexistent user exits 1") use test_command_exit_code,
         which discards stderr. No test verifies that the error message
         reaches stderr and is human-readable.
Fix: Replace with run_command calls that capture stderr and assert a
     non-empty error string, or use a helper that checks both exit code
     and stderr content.
```

---

```
[SUGGESTION] -a flag is unimplemented behavior but untested
Location: tests/utilities/id_test.sh (missing)
Problem: -a is a SHOULD-tier flag defined as "ignored for compatibility."
         No test verifies that `id -a` produces the same output as `id`
         (i.e., the flag is silently ignored, not rejected).
Fix: Add a test: assert `id -a` output equals `id` output and exits 0.
```

---

```
[SUGGESTION] User-argument path only tested for error case
Location: tests/utilities/id_test.sh:119-121
Problem: `id <user>` is tested only for a nonexistent user. The success
         path — `id root` printing correct uid/gid — is never verified
         against a known value. Probing confirms it works, but output
         correctness is unchecked.
Fix: Add a test for `id root` that asserts uid=0 and gid=0 appear in the
     output.
```

---

## Summary

**15 tests pass. 0 fail.**

Severity counts:
- CRITICAL: 1
- IMPORTANT: 7
- SUGGESTION: 3

The test file covers the happy-path MUST flags (-u, -g) adequately for
basic sanity but lacks behavioral depth across the board. The most
serious gap is the -z divergence from GNU (a silent wrong-behavior bug
with no test to catch it). The -r, -p, -F, -P, and -Gn paths — all
implemented and working — have no integration coverage. The default
output groups-ordering difference from GNU is also undetected.

Fix Order:
1. [CRITICAL] -z alone should exit 1 — add error test — id_test.sh
2. [IMPORTANT] -r flag untested (MUST tier) — add -r -u/-g/-n tests — id_test.sh
3. [IMPORTANT] -G order diverges from GNU — strengthen -G test with sort+compare — id_test.sh
4. [IMPORTANT] -Gn untested (MUST tier) — add -Gn test — id_test.sh
5. [IMPORTANT] Default output groups order diverges from GNU — add comparison test — id_test.sh
6. [IMPORTANT] -p untested (MUST tier) — add -p format test — id_test.sh
7. [IMPORTANT] -F untested (SHOULD) — add -F output test — id_test.sh
8. [IMPORTANT] -P untested (SHOULD) — add -P format test — id_test.sh
9. [IMPORTANT] -A error behavior untested — add platform-conditional test — id_test.sh
10. [SUGGESTION] Error tests check no stderr content — capture and assert stderr — id_test.sh
11. [SUGGESTION] -a (ignored flag) not tested — add no-op equivalence test — id_test.sh
12. [SUGGESTION] User-argument success path unchecked — add `id root` value test — id_test.sh

REVIEW COMPLETE - NEEDS_FIXES
