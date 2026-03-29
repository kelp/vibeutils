---
audit: nl integration tests
date: 2026-03-28
result: NEEDS_FIXES
tests_run: 41
tests_passed: 41
tests_failed: 0
---

# nl Integration Test Audit

**Date:** 2026-03-28
**Result:** NEEDS_FIXES
**Tests:** 41/41 pass

## Summary

All 41 tests pass. Coverage is better than average for this project:
behavioral output tests outnumber exit-code-only tests by a wide
margin. However, three MUST flags have zero behavioral coverage,
the `-b p:REGEX` numbering style is completely absent, and several
important GNU behavioral details are untested or tested weakly.

---

## Issues

### [CRITICAL] -b p:REGEX style is unimplemented and untested

**Location:** `tests/utilities/nl_test.sh` (no test present);
`/home/tcole/code/vibeutils/src/nl.zig:142-147`

**Problem:** GNU `nl` supports `-b p:BRE` to number only lines
matching a basic regular expression. `parseNumberingStyle` returns
`null` for any string starting with `p`, so `-b p:foo` exits with
an invalid-style error. The flag is documented as MUST in
`docs/specs/nl-flags.md` via `-b`. No integration test exercises
this path, so the production gap is completely invisible.

**Fix:** Add a test that exposes the current rejection:

```bash
local pfile=$(create_temp_file $'apple\nbanana\napricot')
# GNU: only lines matching "^a" are numbered
test_command_output "nl -b p:^a numbers matching lines" \
    "     1	apple
      	banana
     2	apricot" \
    "$binary" -b p:^a "$pfile"
```

This test will fail today, correctly marking the bug as RED before
a fix is written.

---

### [CRITICAL] -h and -f flags have zero behavioral tests

**Location:** `tests/utilities/nl_test.sh` (no tests present)

**Problem:** `-h` (header numbering style) and `-f` (footer
numbering style) are both MUST flags. The section-delimiter smoke
test at line 132 only confirms "body1" appears in output; it never
verifies that header or footer lines are numbered (or not) according
to the active style. Passing `-h a` to number header lines, or
`-f a` to number footer lines, has no test at all.

**Fix:** Replace the weak smoke test with output-verified tests:

```bash
local sec_file=$(create_temp_file \
    $'\\:\\:\\:\nHEADER\n\\:\\:\nbody1\nbody2\n\\:\nFOOTER')

# Default: header=none, body=non_empty, footer=none
test_command_output "nl sections default" \
$'\n     1\tHEADER\n\n     1\tbody1\n     2\tbody2\n\n      \tFOOTER' \
    "$binary" "$sec_file"

# -h a: header lines are numbered
test_command_output "nl -h a numbers header" \
$'\n     1\tHEADER\n\n     1\tbody1\n     2\tbody2\n\n      \tFOOTER' \
    "$binary" -h a "$sec_file"

# -f a: footer lines are numbered
test_command_output "nl -f a numbers footer" \
$'\n      \tHEADER\n\n     1\tbody1\n     2\tbody2\n\n     3\tFOOTER' \
    "$binary" -f a "$sec_file"
```

---

### [CRITICAL] -d flag has zero behavioral tests

**Location:** `tests/utilities/nl_test.sh` (no test present)

**Problem:** `-d CC` replaces the section delimiter pair. It is a
MUST flag with full implementation in the source, but no integration
test verifies it changes which lines are treated as section
boundaries. A bug that silently ignored `-d` would not be caught.

**Fix:**

```bash
local dfile=$(create_temp_file $'!!!!!!\nHEADER\n!!!!\nbody1\n!!\nFOOTER')
# With -d '!!' the pair '!!' is the delimiter
test_command_output "nl -d custom delimiter" \
$'\n      \tHEADER\n\n     1\tbody1\n\n      \tFOOTER' \
    "$binary" -d '!!' "$dfile"
```

---

### [IMPORTANT] -l (join blank lines) has zero tests

**Location:** `tests/utilities/nl_test.sh` (no test present)

**Problem:** `-l N` causes N consecutive blank lines to be treated
as a single blank line for numbering purposes under `-b a`. It is a
MUST flag. No test exercises it.

**Fix:**

```bash
local lfile=$(create_temp_file $'line1\n\n\n\nline2')
# -b a -l 2: two blank lines count as one; a run of 3 means
# the third gets a number
test_command_output "nl -b a -l 2 join blanks" \
    "     1	line1

     2
     3	line2" \
    "$binary" -b a -l 2 "$lfile"
```

---

### [IMPORTANT] -p test is exit-code-only and uses a weak grep

**Location:** `tests/utilities/nl_test.sh:146-151`

**Problem:** The `-p` test greps for `"3.*line3"` in the output
without anchoring or verifying the full line format. It does not
check that lines 1 and 2 are also numbered (i.e., that numbering
actually continued from before the page boundary), and does not
verify that numbering did NOT reset to 1 when `-p` is absent. A
partially broken implementation could pass this test.

**Fix:** Use `test_command_output` with the full expected output:

```bash
local pfile=$(create_temp_file $'line1\nline2\n\\:\\:\\:\nline3\nline4')
# Without -p: number resets to 1 at header boundary
test_command_output "nl resets at header" \
    $'     1\tline1\n     2\tline2\n\n     1\tline3\n     2\tline4' \
    "$binary" -b a -h a "$pfile"
# With -p: number continues
test_command_output "nl -p continues numbering" \
    $'     1\tline1\n     2\tline2\n\n     3\tline3\n     4\tline4' \
    "$binary" -p -b a -h a "$pfile"
```

---

### [IMPORTANT] Section delimiter smoke test is exit-code-only

**Location:** `tests/utilities/nl_test.sh:132-138`

**Problem:** The section delimiter test runs the binary, captures
output, then greps for "body1". It does not check: (a) that body
lines are correctly numbered, (b) that delimiter lines become blank
lines in the output, (c) that header/footer lines are unnumbered by
default. The `2>/dev/null` redirect also swallows any error output,
hiding crashes or warnings.

**Fix:** Covered by the fix described under `-h`/`-f` above —
replace with full `test_command_output` assertions.

---

### [IMPORTANT] -v with negative start value is untested

**Location:** `tests/utilities/nl_test.sh` (no test present)

**Problem:** GNU `nl` accepts negative starting numbers (`-v -5`).
The source uses `parseSignedInt` (i64), so this should work, but no
test confirms it. The `-n rz` path for negative numbers has a
special code branch in `formatNumber` that is also untested.

**Fix:**

```bash
test_command_output "nl -v -2 negative start" \
    "    -2	hello
    -1	world" \
    "$binary" -v -2 "$simple_file"

test_command_output "nl -n rz -v -2 negative zero-pad" \
    "-00002	hello
-00001	world" \
    "$binary" -n rz -v -2 "$simple_file"
```

---

### [IMPORTANT] Long-line path skips numbering logic silently

**Location:** `tests/utilities/nl_test.sh:181`

**Problem:** The "very long line" test is exit-code-only (`test_
command_exit_code`). The source at `nl.zig:411-418` has a
`StreamTooLong` branch that dumps the partial buffer without
numbering. A regression that broke numbering of long lines would
not be caught.

**Fix:**

```bash
local long_line=$(printf 'A%.0s' {1..1000})
local long_file=$(create_temp_file "$long_line")
# Should produce a numbered line, not raw content
test_command_output_pattern "nl very long line numbered" \
    "^ {5}1	A" "$binary" "$long_file"
```

---

### [SUGGESTION] `--body-numbering` long-form test uses `-a` not `-b a`

**Location:** `tests/utilities/nl_test.sh:52-53`

**Problem:** The `--body-numbering=a` test uses `simple_file` (no
blank lines), which makes it identical to the default behavior. A
regression where `--body-numbering=n` was accepted but treated as
`t` would not be caught. Consider testing `--body-numbering=n`
against blank_file to confirm the long form is distinct from the
short form.

---

### [SUGGESTION] POSIX width and separator tests use grep, not output comparison

**Location:** `tests/utilities/nl_test.sh:192-204`

**Problem:** The POSIX default-width and default-separator checks
run `grep -qE "^ {5}1"` and `grep -q '\t'` against captured output.
These patterns would match even if extra content preceded the number
field. The existing `test_command_output "nl default non-empty"`
test at line 27 already covers this exactly; these two pattern tests
are redundant and weaker. They inflate the pass count without adding
assurance.

---

## Coverage Matrix

| Flag | MUST | Tests | Quality |
|------|------|-------|---------|
| -b a/t/n | yes | output verified | good |
| -b p:RE | yes | **NONE** | **missing** |
| -d | yes | **NONE** | **missing** |
| -f | yes | exit-code only | weak |
| -h | yes | exit-code only | weak |
| -i | yes | output verified | good |
| -l | yes | **NONE** | **missing** |
| -n ln/rn/rz | yes | output verified | good |
| -p | yes | grep only | weak |
| -s | yes | output verified | good |
| -v | yes | output verified (positive only) | partial |
| -w | yes | output verified | good |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -b p:REGEX unimplemented and untested — nl_test.sh
2. [CRITICAL] -h/-f have zero behavioral tests — nl_test.sh
3. [CRITICAL] -d has zero behavioral tests — nl_test.sh
4. [IMPORTANT] -l has zero tests — nl_test.sh
5. [IMPORTANT] -p test is weak grep, not output comparison — nl_test.sh:146
6. [IMPORTANT] Section delimiter test is exit-code-only — nl_test.sh:132
7. [IMPORTANT] -v negative start value untested — nl_test.sh
8. [IMPORTANT] Long-line path tested by exit code only — nl_test.sh:181
9. [SUGGESTION] --body-numbering long form test is trivially weak — nl_test.sh:52
10. [SUGGESTION] Redundant POSIX grep checks — nl_test.sh:192-204
```

REVIEW COMPLETE - NEEDS_FIXES
