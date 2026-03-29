---
utility: echo
audit_type: integration-tests
date: 2026-03-28
test_count: ~20 assertions (excluding test_basic_flags)
status: NEEDS_FIXES
---

# echo Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/echo_test.sh`
**Test count:** ~20 assertions plus `test_basic_flags`

---

## Summary

The integration suite covers the core use cases well: basic
output, multiple args, empty, `-n`, `-e` with `\n` and `\t`,
`-E`, unknown-flag-as-positional, the `>>` append regression
(issue #5), `\0NNN` octal parsing, single-hex-digit `\x`, and
the help text `"1 to 2"` string. The -e section is thin: only
`\n` and `\t` are tested, leaving `\c`, all other escape
sequences, and compound flag combinations uncovered at the
integration level.

---

## Test Inventory

| Test | Behavioral? | Notes |
|------|-------------|-------|
| test_binary_exists | Infrastructure | Not a feature test |
| test_basic_flags | Infrastructure | --help/--version/exit code |
| echo basic output | Yes | Single arg |
| echo multiple args | Yes | Space-join |
| echo empty | Yes | No args → empty line (via cmd sub) |
| echo -n removes newline | Weak | Uses `diff` against `printf "test"` |
| echo -e newline | Yes | \n interpreted |
| echo -e tab | Yes | \t interpreted |
| echo -E literal | Yes | Literal \n kept |
| echo unknown flag as positional | Yes | --invalid-flag printed |
| POSIX single arg | Yes | Duplicate of basic output |
| POSIX multiple args | Yes | Duplicate of multiple args |
| echo >> file appends (issue #5) | Yes | Regression test |
| echo -e \0101 produces A | Yes | \0NNN regression |
| echo -e \0077 produces ? | Yes | \0NNN regression |
| echo -e \077 produces ? | Yes | \NNN (no-zero prefix) |
| echo --help mentions '1 to 2' | Yes | Help text content |
| echo -e \x9 produces tab | Yes | Single hex digit |

---

## Issues Found

### [CRITICAL] \c termination has zero integration tests
Location: `tests/utilities/echo_test.sh`
Problem: `echo -e 'abc\cdef'` (stop at `\c`, no trailing newline)
is a MUST behavior in GNU echo and affects multi-argument
processing. It is covered in unit tests but has no integration
test. A shell-level regression in `\c` handling would be
undetected.
Fix:
```bash
output=$("$binary" -e 'hello\cworld')
if [[ "$output" == "hello" ]]; then
    print_test_result "echo -e \\c stops output" "PASS"
else
    print_test_result "echo -e \\c stops output" "FAIL" \
        "Expected 'hello', got '$output'"
fi
```

### [CRITICAL] \\ (backslash), \r, \v, \f, \a, \b, \e all have
zero integration tests
Location: `tests/utilities/echo_test.sh`
Problem: Only `\n` and `\t` are tested under `-e`. The remaining
7 escape sequences recognized by GNU echo are entirely absent.
In particular `\\` (backslash-backslash → single backslash) is
a very common use case.
Fix: Add a test for each, or a combined test:
```bash
output=$("$binary" -e 'a\\b')
if [[ "$output" == 'a\b' ]]; then ...
```

### [IMPORTANT] -en and -ne compound flags have no integration
tests
Location: `tests/utilities/echo_test.sh`
Problem: Compound flags like `-en` and `-ne` are tested in unit
tests but absent from integration tests. Shell expansion
differences (e.g., shells that expand `\n` in double quotes)
could cause different behavior than the unit test environment
captures.
Fix: Add tests for `-en 'hello\nworld'` (no trailing newline,
`\n` expanded) and `-ne 'hello\nworld'` (same result, different
order).

### [IMPORTANT] -e -E flag ordering (separate flags) not tested
Location: `tests/utilities/echo_test.sh`
Problem: `echo -e -E 'hello\nworld'` should output the literal
string (last wins). This is unit-tested but absent at the
integration level.
Fix: Add ordering tests for `-e -E` and `-E -e`.

### [IMPORTANT] echo -n check is indirect and fragile
Location: `tests/utilities/echo_test.sh:46-51`
Problem: The `-n` test uses `printf "test" | diff - <(echo -n
"$output")` to check for no newline. Command substitution in
`output=$("$binary" -n "test")` strips trailing newlines anyway,
so the diff comparison is not actually checking whether the
binary emits a newline or not — it would pass even if `-n` was
broken, as long as the output contains "test". This is a
cannot-fail test.
Fix: Use a temp file to capture raw binary output:
```bash
local tmpfile="$TEMP_DIR/echo_n_test"
"$binary" -n "test" > "$tmpfile"
local raw_size
raw_size=$(wc -c < "$tmpfile")
if [[ "$raw_size" -eq 4 ]]; then  # 4 bytes: t-e-s-t, no newline
    print_test_result "echo -n removes newline" "PASS"
else
    print_test_result "echo -n removes newline" "FAIL" \
        "Expected 4 bytes, got $raw_size"
fi
```

### [IMPORTANT] POSIX single arg and POSIX multiple args are
duplicate tests
Location: `tests/utilities/echo_test.sh:93-108`
Problem: "POSIX single arg" is identical to "echo basic output"
and "POSIX multiple args" is identical to "echo multiple args".
These provide no additional coverage and inflate the apparent
test count.
Fix: Remove duplicates or rename to cover a distinct POSIX
behavior (e.g., confirm exit code is always 0).

### [SUGGESTION] \0 (NUL byte) integration test is missing
Location: `tests/utilities/echo_test.sh`
Problem: `echo -e '\0'` (NUL byte output) is unit-tested but
has no integration test. NUL bytes are tricky in shell but can
be detected with `wc -c` or `xxd`.
Fix: Skip or add with appropriate NUL-handling approach.

### [SUGGESTION] No test for echo with no -e but backslash
strings
Location: `tests/utilities/echo_test.sh`
Problem: With the default (no `-e`), backslash sequences should
be printed literally. Only the `-E` explicit flag is tested for
the "no-escape" path. Add a test with no flag at all to verify
the default mode.
Fix:
```bash
output=$("$binary" 'hello\nworld')
if [[ "$output" == 'hello\nworld' ]]; then
    print_test_result "echo default no escapes" "PASS"
...
```

---

## GNU Behavioral Coverage

| GNU Feature | Covered |
|-------------|---------|
| Basic output | Yes |
| Multiple args (space-join) | Yes |
| Empty output | Yes (but via cmd-sub) |
| -n suppress newline | Weak (cannot-fail test) |
| -e enable escapes | Partial (\n \t only) |
| -E disable escapes | Yes |
| -e -E ordering | No |
| -en/-ne compound | No |
| \n \t | Yes |
| \c | No |
| \\ | No |
| \r \v \f \a \b \e | No |
| \0NNN octal | Yes |
| \NNN octal | Yes |
| \xHH hex (2 digit) | No |
| \xH hex (1 digit) | Yes |
| Unknown flag as positional | Yes |
| >> append (issue #5) | Yes |

---

## Overall Assessment: NEEDS_FIXES

2 critical, 4 important, 2 suggestion.
The -n check is a cannot-fail test (IMPORTANT). The missing
`\c`, `\\`, and other escape-sequence integration tests leave
large behavioral gaps for this MUST-tier utility. The POSIX
duplicate tests should be removed.
