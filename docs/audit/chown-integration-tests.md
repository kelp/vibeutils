# chown Integration Test Audit

Date: 2026-03-28
File: `tests/utilities/chown_test.sh`
Result: 83/83 pass

---

## Summary

The suite passes cleanly but is riddled with cannot-fail
assertions and near-zero behavioral verification. Most flag
tests only confirm exit code 0 while running as the current
user — a no-op ownership change. The three SHOULD-tier flags
with meaningful behavioral contracts (-n, -x,
--preserve-root / --no-preserve-root) have zero coverage.
The -c and -v behavioral tests are unconditional PASS stubs.

---

## Issues

### CRITICAL

**[CRITICAL] "chown -c behavior" is an unconditional PASS
stub**
Location: `tests/utilities/chown_test.sh:88`
Problem: The test captures output from `-c` but then
calls `print_test_result "chown -c behavior" "PASS"` with
a hard-coded result regardless of what was captured. This
is not a test — it is a certificate of absence. The
behavioral contract of `-c` is: produce output when
ownership changes, produce no output when it does not.
Neither direction is verified.
Fix:

```bash
# Apply ownership once to establish baseline
"$binary" "$current_uid:$current_gid" "$changes_test_file" \
    2>/dev/null || true
# Second application — same owner — must be silent
local silent_out
silent_out=$("$binary" -c "$current_uid:$current_gid" \
    "$changes_test_file" 2>&1)
if [[ -z "$silent_out" ]]; then
    print_test_result "chown -c silent when no change" "PASS"
else
    print_test_result "chown -c silent when no change" "FAIL" \
        "Expected no output, got: $silent_out"
fi
```

---

**[CRITICAL] "chown -c no change behavior" is a second
unconditional PASS stub**
Location: `tests/utilities/chown_test.sh:299`
Problem: Identical to the above — output is captured into
`$changes_output1` and then discarded. The comment says
"Should be empty … or show retention message" but neither
is actually asserted. This is the only other test touching
`-c` behavior; both are stubs.
Fix: Apply the same pattern from the fix above. Remove this
duplicate stub entirely once the behavioral test is correct.

---

**[CRITICAL] "chown -v output format" is an unconditional
PASS stub**
Location: `tests/utilities/chown_test.sh:288-291`
Problem: The if/else branches both call
`print_test_result … "PASS"`. The condition can never
produce a FAIL. Verbose output correctness is completely
untested.
Fix:

```bash
verbose_output=$("$binary" -v "$current_uid" "$test_file1" \
    2>&1)
if [[ "$verbose_output" =~ (ownership|retained|changed) ]]; then
    print_test_result "chown -v output format" "PASS"
else
    print_test_result "chown -v output format" "FAIL" \
        "Expected ownership message, got: '$verbose_output'"
fi
```

---

### IMPORTANT

**[IMPORTANT] -f tests check stdout but errors go to stderr;
2>&1 is passed as a literal argument**
Location: `tests/utilities/chown_test.sh:96-98`
Problem: `test_command_output` captures only stdout (see
`common.sh:339`). The string `2>&1` is passed as the final
argument and is treated as a filename for chown to operate
on, not as a shell redirect. The function's `run_command`
captures stderr separately. The `-f` test therefore passes
because stdout is empty — but it would pass even if stderr
were full of errors, because stderr is never checked.
The string `"2>&1"` is also silently handed to the binary
as a path argument; the binary happens to ignore it after
the error on the nonexistent file.
Fix: Use `run_command` directly and assert that stderr is
empty:

```bash
local cmd stdout stderr exit_code
run_command cmd stdout stderr exit_code \
    "$binary" -f "$current_uid" "/nonexistent/file"
if [[ -z "$stderr" ]]; then
    print_test_result "chown -f suppresses errors" "PASS"
else
    print_test_result "chown -f suppresses errors" "FAIL" \
        "Expected no stderr, got: $stderr"
fi
```
Apply the same fix to `--silent` and `--quiet` variants.

---

**[IMPORTANT] "chown -f root no output" has the same
stderr-only vs stdout confusion**
Location: `tests/utilities/chown_test.sh:232`
Problem: Same as above. The permission-denied error from
attempting `chown 0:0` goes to stderr; stdout is always
empty. This test cannot distinguish a working `-f` from a
binary that emits nothing to stdout by default.
Fix: Assert stderr is empty using `run_command` as shown
above.

---

**[IMPORTANT] -v "shows change" test cannot fail**
Location: `tests/utilities/chown_test.sh:72-75`
Problem: `test_command_output_pattern` is called with
pattern `"ownership.*"`. If the pattern does not match,
the `||` branch calls `print_test_result … "PASS"` anyway.
The test name says "shows change" but the test accepts any
output or no match as passing.
Fix: Remove the `|| { … }` fallback entirely, or restructure
to actually produce a visible change (change to a different
uid, then change back) before testing the `-v` output.

---

**[IMPORTANT] -n flag (numeric UID/GID interpretation) has
zero tests**
Location: none
Problem: `-n` is a SHOULD-tier flag listed in both
`chown-flags.md` and the macOS man page. Its behavioral
contract is "interpret user ID and group ID as numeric,
avoiding name lookups." There is no test confirming that
`chown -n <uid>` accepts a numeric ID and rejects a
symbolic name (or handles it differently).
Fix: Add a behavioral test:

```bash
# -n: numeric ID must succeed
test_command_succeeds "chown -n numeric uid" \
    "$binary" -n "$current_uid" "$test_file1"
# -n: symbolic name may still work but behavior differs —
# at minimum confirm the flag is recognized and exit code 0
test_command_succeeds "chown -n symbolic user" \
    "$binary" -n "$current_user" "$test_file1"
```

---

**[IMPORTANT] -x flag (no cross-mount-point traversal) has
zero tests**
Location: none
Problem: `-x` is a SHOULD-tier flag. There is no test
confirming the flag is accepted, let alone that it
restricts traversal.
Fix: At minimum confirm the flag is recognized:

```bash
test_command_succeeds "chown -x no cross-mount" \
    "$binary" -x "$current_uid" "$test_dir"
test_command_succeeds "chown -Rx no cross-mount" \
    "$binary" -R -x "$current_uid" "$recursive_dir"
```

---

**[IMPORTANT] -H/-L/-P tests only check exit code 0 and
do not verify traversal behavior**
Location: `tests/utilities/chown_test.sh:137-139`
Problem: The three traversal flags have distinct and
testable behaviors:
- `-H`: follow symlinks on the command line only
- `-L`: follow all symlinks during traversal
- `-P`: do not follow any symlinks (operate on link itself)

All three tests use `test_command_succeeds`, which only
checks exit code. There is no verification that the symlink
target was or was not chowned.
Fix: After running each variant, stat the target file and
the symlink itself to confirm which one changed:

```bash
# -P: symlink's uid should change; target's should not
"$binary" -P -R "$current_uid" "$dir_symlink"
# Confirm link owner changed (lstat) vs target unchanged
```

---

**[IMPORTANT] -R recursive tests only check exit code;
no verification that children were actually changed**
Location: `tests/utilities/chown_test.sh:158-162`
Problem: `chown -R` could silently no-op on all child files
and these tests would still pass. The behavioral contract
(all files in the tree have the new owner) is never
verified.
Fix:

```bash
"$binary" -R "$current_uid:$current_gid" "$recursive_dir"
# Confirm deepest file was affected
local owner
owner=$(stat -c %u "$rfile3" 2>/dev/null || \
    stat -f %u "$rfile3")
if [[ "$owner" == "$current_uid" ]]; then
    print_test_result "chown -R changes child files" "PASS"
else
    print_test_result "chown -R changes child files" "FAIL" \
        "Expected uid $current_uid on $rfile3, got $owner"
fi
```

---

**[IMPORTANT] --preserve-root and --no-preserve-root have
zero tests**
Location: none
Problem: Both are SHOULD-tier flags in `chown-flags.md`.
`--preserve-root` should refuse to operate on `/`
recursively. Neither flag is mentioned anywhere in the test
file.
Fix: Add at minimum a recognition test and a behavioral
test for `--preserve-root -R /`:

```bash
test_command_fails "chown --preserve-root -R /" \
    "$binary" --preserve-root -R "$current_uid" "/"
test_command_succeeds "chown --no-preserve-root recognized" \
    "$binary" --no-preserve-root "$current_uid" "$test_file1"
```

---

**[IMPORTANT] -h and -v "chown -h symlink" / "chown
--no-dereference symlink" tests only check exit code**
Location: `tests/utilities/chown_test.sh:115-116`
Problem: The behavioral distinction between `-h` (change
link itself) and the default (follow link, change target)
is never verified. Both tests call `test_command_succeeds`.
Fix: After `chown -h "$current_uid" "$symlink_file"`,
confirm that the symlink's own UID matches (using
`lstat`-equivalent: `stat -c %u` on the link without
dereferencing, or `ls -ln` output).

---

**[IMPORTANT] "chown -v shows operation" is pattern
matched on combined stdout; verbose output may go to
stderr**
Location: `tests/utilities/chown_test.sh:66-67`
Problem: `test_command_output_pattern` only checks stdout
(see `common.sh:380`). If the implementation writes verbose
output to stderr (as GNU chown does), the pattern will never
match and the test will fail — or, if it passes, that means
the output goes to stdout, which should also be verified.
The test should capture both streams and assert the
correct one.
Fix: Capture both and assert stderr contains the message
(GNU behavior), or assert stdout if that is the
implementation's choice — but do it explicitly.

---

### SUGGESTION

**[SUGGESTION] "chown device file handled" is an
unconditional PASS stub**
Location: `tests/utilities/chown_test.sh:331-333`
Problem: The binary is run, the result is discarded with
`|| true`, and PASS is printed. This verifies nothing.
Fix: At minimum assert the exit code matches expectations
(likely non-zero due to permissions, or zero if running as
owner).

**[SUGGESTION] "chown -R large tree performance" is an
unconditional PASS stub**
Location: `tests/utilities/chown_test.sh:316`
Problem: Performance is entirely implicit ("if it hangs,
the test will timeout"). The explicit PASS call adds noise
with no signal.
Fix: Remove the explicit `print_test_result` call — the
preceding `test_command_succeeds` already provides a
pass/fail signal.

**[SUGGESTION] Flag-recognition loop always passes**
Location: `tests/utilities/chown_test.sh:351-356`
Problem: The condition `|| [[ $? -eq 1 || $? -eq 2 ]]`
accepts any exit code up to 2 as a pass. Since `$?` inside
`[[ ]]` reflects the exit of the previous command, this
condition is effectively `true` for exit codes 0, 1, or 2.
Exit code 2 ("misuse") would indicate the flag was not
recognized and the binary printed a usage error, but the
test still passes.
Fix: Remove the loop entirely — each tested flag already
has a dedicated behavioral test. If the loop is kept,
assert exit code 0 only.

**[SUGGESTION] "chown -v shows change" test name is
misleading**
Location: `tests/utilities/chown_test.sh:72`
Problem: The test runs `chown -v` on a file that already
has `$current_uid:$current_gid` as its owner. There is no
actual ownership change, so the output will always say
"retained" not "changed." The test name implies a change
is being observed.
Fix: Either rename to "chown -v shows retained" or set up
a genuine ownership change (requires a second user or
manipulating the GID).

---

## Coverage Gaps by Flag

| Flag | MUST/SHOULD | Behavioral test? |
|------|-------------|-----------------|
| -c   | SHOULD      | NO (2 stubs)    |
| -f   | SHOULD      | NO (stdout/stderr bug) |
| -h   | MUST        | NO (exit-code only) |
| -H   | MUST        | NO (exit-code only) |
| -L   | MUST        | NO (exit-code only) |
| -n   | SHOULD      | ZERO coverage   |
| -P   | MUST        | NO (exit-code only) |
| -R   | MUST        | NO (exit-code only) |
| -v   | SHOULD      | NO (2 stubs)    |
| -x   | SHOULD      | ZERO coverage   |
| --preserve-root | SHOULD | ZERO coverage |
| --no-preserve-root | SHOULD | ZERO coverage |
| --reference | SHOULD | exit-code only |

---

## Counts

- CRITICAL: 3
- IMPORTANT: 10
- SUGGESTION: 4

## Assessment: NEEDS_FIXES

83/83 tests pass, but the passing rate is misleading. At
least 5 tests are unconditional PASS stubs (lines 88, 291,
299, 316, 332). The -f stderr-capture bug means two tests
verify nothing. Every MUST-tier traversal flag (-H, -L, -P,
-R) is tested only at the exit-code level. Two SHOULD-tier
flags (-n, -x) have zero coverage, and --preserve-root /
--no-preserve-root are absent entirely.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] "chown -c behavior" unconditional PASS stub
   — tests/utilities/chown_test.sh:88
2. [CRITICAL] "chown -c no change behavior" unconditional PASS stub
   — tests/utilities/chown_test.sh:299
3. [CRITICAL] "chown -v output format" unconditional PASS stub
   — tests/utilities/chown_test.sh:288-291
4. [IMPORTANT] -f/--silent/--quiet tests check stdout,
   not stderr — tests/utilities/chown_test.sh:96-98
5. [IMPORTANT] "chown -f root no output" same bug
   — tests/utilities/chown_test.sh:232
6. [IMPORTANT] "-v shows change" cannot fail
   — tests/utilities/chown_test.sh:72-75
7. [IMPORTANT] -n flag: zero behavioral coverage
8. [IMPORTANT] -x flag: zero coverage
9. [IMPORTANT] --preserve-root/--no-preserve-root: zero coverage
10. [IMPORTANT] -H/-L/-P traversal not behaviorally verified
    — tests/utilities/chown_test.sh:137-139
11. [IMPORTANT] -R recursive does not verify children changed
    — tests/utilities/chown_test.sh:158-162
12. [IMPORTANT] -h no-dereference not behaviorally verified
    — tests/utilities/chown_test.sh:115-116
13. [IMPORTANT] -v output stream not verified (stdout vs stderr)
    — tests/utilities/chown_test.sh:66-67
14. [SUGGESTION] "chown device file handled" unconditional PASS
    — tests/utilities/chown_test.sh:331-333
15. [SUGGESTION] "chown -R large tree performance" extra PASS stub
    — tests/utilities/chown_test.sh:316
16. [SUGGESTION] Flag-recognition loop accepts exit code 2 as pass
    — tests/utilities/chown_test.sh:351-356
```

REVIEW COMPLETE - NEEDS_FIXES
