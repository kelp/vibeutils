# touch Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/touch_test.sh`
**Result:** 107/107 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| Section | Tests | Quality |
|---|---|---|
| Binary / basic flags | 3 | Strong |
| Infrastructure / basic creation | 5 | Strong |
| File creation behavior | 7 | Strong |
| Timestamp modification (-a, -m) | 6 | Strong |
| Flag combinations (-a -m, -c combos) | 5 | Weak (see issues) |
| Reference file (-r) | 5 | Partial (mtime only) |
| Timestamp parsing (-t) | 11 | Weak (exit-code-only) |
| --time=WORD option | 6 | Weak (exit-code-only) |
| Symlink handling (-h) | 3-4 | Weak (exit-code-only) |
| Date string (-d) | 18 | Strong |
| Error conditions / edge cases | 11 | Mostly strong |
| Multiple files / complex | 8 | Mixed |
| POSIX / GNU compatibility | 7 | Mostly exit-code-only |
| Edge cases / limits | 5 | Mostly exit-code-only |
| Final validation | 2 | Cosmetic |

---

## Findings

### IMPORTANT

**[IMPORTANT] -t flag tests verify only exit code, not resulting timestamp**
Location: `tests/utilities/touch_test.sh:252-288`
Problem: All three `-t` format tests (`touch -t full format`,
`touch -t YY format`, `touch -t MM format`) call
`test_command_succeeds` and move on. None reads back the file's
mtime and checks it against the expected epoch value. A
regression where the timestamp is silently set to "now" instead
of the parsed value would pass all three tests.
Fix: After each `test_command_succeeds` call, read back
`get_mtime` and compare it to the expected epoch value within a
tight range (e.g., ±2 seconds). For `"202312311359.30"`, Dec 31
2023 13:59:30 UTC is approximately epoch 1704027570; assert the
result is within that range.

---

**[IMPORTANT] --time=WORD tests verify only exit code, not which
timestamps change**
Location: `tests/utilities/touch_test.sh:292-318`
Problem: `--time=access` (equivalent to `-a`) and
`--time=modify` (equivalent to `-m`) are tested only with
`test_command_succeeds`. There is no check that `--time=access`
leaves mtime unchanged or that `--time=modify` leaves atime
unchanged. The five variants could all be wired to the same
code path (or to "update both") and every test would still pass.
Fix: Replicate the same before/after atime+mtime pattern used
for `-a` and `-m` tests: capture both timestamps, run the
command, verify only the expected one changed.

---

**[IMPORTANT] -h symlink tests verify only exit code, not that the
link's own timestamps changed**
Location: `tests/utilities/touch_test.sh:327-345`
Problem: `touch -h affects symlink` and
`touch --no-dereference` call `test_command_succeeds` with no
follow-up check. On Linux, `lutimes(2)` or `utimensat` with
`AT_SYMLINK_NOFOLLOW` must be used; if the implementation falls
back to following the link (the wrong behavior), the target
file's timestamp changes and the test still passes. The
distinction between touching the link and touching the target is
never exercised.
Fix: Record the target file's mtime before and after
`touch -h $symlink`. Assert the target's mtime is unchanged.
Also use `stat -c %Y` on the symlink itself with `ls -l --full-time`
or `stat --dereference=no` to assert the link's time changed.

---

**[IMPORTANT] -r copies only mtime verified; atime copy is untested**
Location: `tests/utilities/touch_test.sh:221-231`
Problem: The test records `ref_mtime` and `target_mtime` and
compares them, but never checks `ref_atime` vs `target_atime`.
The `-r` flag must copy both timestamps. An implementation that
copies only mtime and leaves atime alone would pass this test.
Fix: Also capture `ref_atime=$(get_atime "$ref_file")` and
`target_atime=$(get_atime "$target_file")` after the command
and assert the difference is within 1 second.

---

**[IMPORTANT] -a -m combination test uses `-ge` instead of `-gt`,
so it can pass even if timestamps are unchanged**
Location: `tests/utilities/touch_test.sh:179-192`
Problem: The check sets `atime_changed=true` when
`new_atime -ge initial_atime`. Because the two timestamps are
captured from the same file before and after `sleep 2`, they can
be equal only if something is wrong. However, the guard is `-ge`
(not `-gt`), which means a no-op implementation that leaves both
timestamps identical would still pass. The test is safe in
practice only because `sleep 2` makes equality unlikely, not
because the assertion itself enforces the update.
Fix: Change both guards to `-gt`:
```bash
if [[ "$new_atime" -gt "$initial_atime" ]]; then
if [[ "$new_mtime" -gt "$initial_mtime" ]]; then
```

---

### SUGGESTION

**[SUGGESTION] "touch device file" test always passes regardless of
exit code**
Location: `tests/utilities/touch_test.sh:541-548`
Problem: Both branches of the if/else call
`print_test_result "touch device file" "PASS"`. If the binary
crashes or returns an unexpected exit code like 2 (misuse), the
test reports PASS with a misleading note. This masks any
regression on device-file handling.
Fix: The intent seems to be "exit 0 or exit 1 are both
acceptable; exit 2+ is a bug." Implement that explicitly:
```bash
if [[ $dev_exit -le 1 ]]; then
    print_test_result "touch device file" "PASS"
else
    print_test_result "touch device file" "FAIL" \
        "Unexpected exit $dev_exit on /dev/null"
fi
```

---

**[SUGGESTION] -t combined with -a and -m are exit-code-only**
Location: `tests/utilities/touch_test.sh:280-288`
Problem: `touch -t -a combination` and `touch -t -m combination`
check only that the command succeeds. They do not verify that
`-a` limits the change to atime or that `-m` limits it to mtime
when combined with an explicit `-t` timestamp.
Fix: For the `-t -a` case, capture mtime before and after the
touch and assert it is unchanged. Assert atime changed to the
expected epoch. Mirror this for `-t -m`.

---

**[SUGGESTION] -d fractional seconds and UTC ("Z") suffix are
untested**
Location: `tests/utilities/touch_test.sh:347-460`
Problem: The macOS man page (`touch-macos.txt`) documents `-d`
accepting an optional `.frac` fractional component and a `Z`
suffix for UTC. The test suite covers date-only, `T` separator,
and space separator, but never exercises
`"2023-06-15T14:30:00.5"` or `"2023-06-15T14:30:00Z"`.
Fix: Add two tests with fractional seconds and the Z suffix.
For the Z case, assert the resulting mtime equals the expected
UTC epoch regardless of local timezone.

---

**[SUGGESTION] -d tests have an overly wide timestamp range
(200,000-second window)**
Location: `tests/utilities/touch_test.sh:358, 370, 394`
Problem: All `-d "2023-06-15"` tests accept any mtime between
1686700000 and 1686900000, a range of 200,000 seconds (~55
hours). This is wide enough to allow a timezone off-by-one or
DST bug to pass undetected.
Fix: Tighten the window to ±86400 seconds around the known UTC
epoch for that date (1686787200), or compare against the
`date -d "2023-06-15" +%s` output captured at test time.

---

**[SUGGESTION] No test verifies -t timestamp value matches expectation**
(Duplicate of the IMPORTANT above for -t exit-code-only, offered
here as a concrete minimal fix if a full behavioral rewrite is
deferred.)
Location: `tests/utilities/touch_test.sh:252-260`
Fix at minimum: After `touch -t "202312311359.30" "$t_file1"`,
add:
```bash
t_mtime=$(get_mtime "$t_file1")
# Dec 31 2023 13:59:30 UTC ≈ 1704027570
if [[ "$t_mtime" -ge 1703900000 && "$t_mtime" -le 1704100000 ]]; then
    print_test_result "touch -t full format timestamp value" "PASS"
else
    print_test_result "touch -t full format timestamp value" "FAIL" \
        "Got mtime $t_mtime, expected near 1704027570"
fi
```

---

## Coverage Gaps (MUST/SHOULD flags from touch-flags.md)

| Flag | Tier | Exit-code tested | Behavior tested |
|---|---|---|---|
| -a | MUST | yes | yes (strong) |
| -c | MUST | yes | yes (strong) |
| -d | MUST | yes | yes (strong) |
| -m | MUST | yes | yes (strong) |
| -r | MUST | yes | mtime only (atime gap) |
| -t | MUST | yes | no (value never checked) |
| -A | SHOULD | yes (non-zero) | no |
| -f | SHOULD | yes (ignored) | yes (stub confirmed) |
| -h | SHOULD | yes | no (target unchanged never checked) |
| --time=WORD | SHOULD | yes | no (which field changes unchecked) |

---

## Summary

**Critical:** 0
**Important:** 4
**Suggestion:** 5

**REVIEW COMPLETE - NEEDS_FIXES**

The suite is unusually thorough for a touch implementation and
the `-d` section is genuinely well-written with value-range
verification. The main structural weakness is that the newer
SHOULD-tier features (`-t`, `--time=WORD`, `-h`) follow the
exit-code-only pattern: they confirm the binary accepts the flag
without verifying it has the correct effect. The four IMPORTANT
issues are all behavioral gaps that could hide production bugs.

**Fix Order:**
1. [IMPORTANT] `-r` does not verify atime is copied —
   `touch_test.sh:221`
2. [IMPORTANT] `-h` symlink tests do not verify the link vs target
   distinction — `touch_test.sh:327`
3. [IMPORTANT] `-t` format tests do not verify resulting timestamp
   value — `touch_test.sh:252`
4. [IMPORTANT] `--time=WORD` tests do not verify which field changes
   — `touch_test.sh:292`
5. [SUGGESTION] `-a -m` combo check uses `-ge` instead of `-gt` —
   `touch_test.sh:179`
6. [SUGGESTION] Device file test always reports PASS —
   `touch_test.sh:541`
7. [SUGGESTION] `-t -a` and `-t -m` combinations are exit-code-only
   — `touch_test.sh:280`
8. [SUGGESTION] `-d` Z suffix and fractional seconds untested —
   `touch_test.sh:347`
9. [SUGGESTION] `-d` timestamp acceptance window is 200,000 seconds
   wide — `touch_test.sh:358`
