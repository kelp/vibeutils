# tail Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/tail_test.sh`
**Spec:** `docs/specs/tail-flags.md`, `docs/specs/tail-macos.txt`
**Result:** NEEDS_FIXES

---

## Run Results

```
Tests run: 76
Passed:    76
Failed:    0
```

All 76 tests pass. The issues below are coverage gaps, not
failures.

---

## Flag Coverage Matrix

| Flag | Tier | Has output test | Has exit-code-only | Gap |
|------|------|----------------|-------------------|-----|
| -n NUM | MUST | yes | — | none |
| -n +NUM | MUST | yes | — | none |
| -c NUM | MUST | yes | — | none |
| -c +NUM | MUST | yes | — | none |
| -f | MUST | yes (timing) | — | see below |
| -b | MUST | none | none | CRITICAL |
| -r | MUST | none | none | CRITICAL |
| -q | SHOULD | yes | — | none |
| -v | SHOULD | yes | — | none |
| -F | SHOULD | yes (timing) | — | see below |
| -z | SHOULD | none | exit-code only | IMPORTANT |

---

## Findings

### [CRITICAL] -b flag has zero integration coverage

**Location:** `tests/utilities/tail_test.sh` — no test exists

**Problem:** `-b` (512-byte block count) is a MUST-tier flag
present on macOS and OpenBSD. The spec documents `--blocks=`
as the long form. Unit tests exist in `src/tail.zig` but
integration tests (which verify the real binary end-to-end)
have no coverage at all: no output test, no exit-code test.

**Fix:**

```bash
echo -e "${CYAN}Testing block count flag...${NC}"

# 3 blocks of 512 = 1536 bytes; create a 2048-byte file
local block_file
block_file=$(create_temp_file "$(printf '%01024d' 0)$(printf '%01024d' 0)")
# tail -b 2 = last 1024 bytes
local block_expected
block_expected=$(printf '%01024d' 0)
test_command_output "tail -b 2" "$block_expected" "$binary" -b 2 "$block_file"

# tail -b +2 = from byte 513 onwards
test_command_output "tail -b +2" \
    "$(dd if="$block_file" bs=512 skip=1 2>/dev/null)" \
    "$binary" -b +2 "$block_file"

# --blocks= long form
test_command_output "tail --blocks=1" \
    "$(tail -c 512 "$block_file")" \
    "$binary" --blocks=1 "$block_file"
```

---

### [CRITICAL] -r flag has zero integration coverage

**Location:** `tests/utilities/tail_test.sh` — no test exists

**Problem:** `-r` (reverse order display) is a MUST-tier flag
on macOS and OpenBSD. The only -r test in the file is for
the `-f -r` mutual exclusion error path. There is no test
that verifies `-r` actually reverses output, that `-r -n N`
reverses the last N lines, or that `-r` on stdin works. Unit
tests cover this in `src/tail.zig` but integration tests do
not.

**Fix:**

```bash
echo -e "${CYAN}Testing reverse flag...${NC}"

local rev_file
rev_file=$(create_temp_file $'alpha\nbeta\ngamma\ndelta')

test_command_output "tail -r reverses all lines" \
    $'delta\ngamma\nbeta\nalpha' \
    "$binary" -r "$rev_file"

test_command_output "tail -r -n 3 reverses last 3 lines" \
    $'delta\ngamma\nbeta' \
    "$binary" -r -n 3 "$rev_file"

test_command_output "tail -r single line file" \
    "alpha" \
    "$binary" -r "$(create_temp_file 'alpha')"

# stdin
test_command_output "tail -r from stdin" \
    $'c\nb\na' \
    bash -c "printf 'a\nb\nc' | '$binary' -r"
```

---

### [IMPORTANT] -z tests are exit-code-only (all 5)

**Location:** `tests/utilities/tail_test.sh:125-128,137`

**Problem:** All five `-z` / `--zero-terminated` tests use
`test_command_exit_code`. They confirm the flag does not
crash but do not verify that NUL-delimited records are
counted and output correctly. A bug that outputs the wrong
records — or ignores NUL delimiters entirely and falls back
to newlines — would pass all five tests.

**Fix:** Replace the exit-code-only tests with output
verification:

```bash
local nul_file
nul_file=$(create_temp_file $'r1\x00r2\x00r3\x00r4\x00r5\x00')

# -z -n 2 should return last 2 NUL-delimited records
test_command_output_exact "tail -z -n 2 output" \
    $'r4\x00r5\x00' \
    "$binary" -z -n 2 "$nul_file"

# -z -n +3 should return records 3 onwards (r3, r4, r5)
test_command_output_exact "tail -z -n +3 output" \
    $'r3\x00r4\x00r5\x00' \
    "$binary" -z -n +3 "$nul_file"
```

Note: use `test_command_output_exact` here because
`test_command_output` strips trailing newlines via command
substitution and will silently eat the NUL terminators.

---

### [IMPORTANT] -f initial-content test is output-only for
appended lines; initial lines not verified

**Location:** `tests/utilities/tail_test.sh:142-155`

**Problem:** The `-f` append test checks that `"appended
line"` appears in the output file, but does not assert
`"initial line"` also appears. GNU and POSIX tail always
prints the existing tail of the file before entering follow
mode. A regression that skips the initial content would
pass the current test.

**Fix:** Change the grep check at line 151:

```bash
if grep -q "initial line" "$follow_output" && \
   grep -q "appended line" "$follow_output"; then
    print_test_result "tail -f sees appended data" "PASS"
```

---

### [IMPORTANT] -z -c combination has no output test

**Location:** `tests/utilities/tail_test.sh:128`

**Problem:** `tail -z -c works` is exit-code-only. The `-z`
flag changes what counts as a "byte boundary" in terms of
record semantics but `-c` itself is byte-based; the test
does not verify that byte extraction works correctly in
conjunction with NUL-terminated mode.

**Fix:** Add a targeted output verification test alongside
the existing exit-code test.

---

### [SUGGESTION] -q test has a latent newline-joining bug

**Location:** `tests/utilities/tail_test.sh:87-88`

**Problem:** The expected string for the `-q` multiple-file
test concatenates the two files without a separating
newline:

```
$'File A Line 1\nFile A Line 2\nFile A Line 3File B Line 1\n...'
```

`File A Line 3` and `File B Line 1` are joined without a
newline. This is intentional only if `create_temp_file`
writes content without a trailing newline (which it does —
it uses `echo -n`). The test is technically correct but
fragile: a future change that adds a trailing newline to
file creation would silently break the expectation string
without obvious cause. A comment explaining the deliberate
newline-join would prevent confusion.

---

### [SUGGESTION] -F stderr message strings are hardcoded

**Location:** `tests/utilities/tail_test.sh:169,189,206`

**Problem:** The tests grep for exact strings:
`"file truncated"`, `"file has been replaced"`, and
`"waiting for it to appear"`. These will fail silently if
the implementation changes the wording. The strings are not
documented in the spec. Consider extracting them to named
constants or documenting them as the normative message
format.

---

### [SUGGESTION] Timing values are inflexible

**Location:** `tests/utilities/tail_test.sh:146-154,162-173,
180-193,198-210`

**Problem:** The follow-mode tests use hard-coded `sleep 1`,
`sleep 2`, and `sleep 3` delays. On a heavily loaded system
or slow CI runner these races can cause flaky failures. The
total wait across the four follow tests is about 16 seconds.
Consider using a poll loop (check for condition up to N
times with a short sleep) rather than fixed delays.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 3 |
| SUGGESTION | 3 |

**Overall assessment: NEEDS_FIXES**

The basic functionality, stdin filter path, -n, -c, -q, -v,
and -F tests are solid and output-verified. The two CRITICAL
gaps are entire MUST-tier flags (-b, -r) with zero
integration coverage. The three IMPORTANT issues are weak
exit-code-only tests for -z and an incomplete assertion in
the -f follow test.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Add -r output tests (reverse display) — tail_test.sh
2. [CRITICAL] Add -b output tests (block count) — tail_test.sh
3. [IMPORTANT] Replace all 5 -z exit-code tests with output
   tests using test_command_output_exact — tail_test.sh:125-128,137
4. [IMPORTANT] Assert initial content present in -f follow
   test — tail_test.sh:151
5. [IMPORTANT] Add -z -c output test — tail_test.sh:128
6. [SUGGESTION] Comment the newline-join in -q multi-file
   expected string — tail_test.sh:87-88
7. [SUGGESTION] Extract -F stderr message strings to named
   constants — tail_test.sh:169,189,206
8. [SUGGESTION] Replace fixed sleep delays with poll loops
   in follow-mode tests — tail_test.sh:146-210
```

REVIEW COMPLETE - NEEDS_FIXES
