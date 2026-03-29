# Integration Test Audit: env

**Date**: 2026-03-28
**Test file**: tests/utilities/env_test.sh
**Flags spec**: docs/specs/env-flags.md
**Test run**: 26 tests, 26 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 26 tests pass. The suite has solid coverage of the MUST-tier
flags (-i, -u, -C, -0), good behavioral verification (output
content checked rather than exit codes alone), and correct
exit-code passthrough tests. However, three SHOULD-tier flags
(-P, -S, -v) have zero integration tests, and -S is a known
production stub that prints an error and continues rather than
splitting strings. Two error tests use `test_command_fails`
which only checks for non-zero exit, masking the specific exit
code. One output check (`--help shows usage`) accepts any
output containing "Usage: env" but does not verify flag
descriptions are present.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| env binary | binary exists | Weak |
| env --help (basic_flags) | exit code 0 | Weak |
| env --version (basic_flags) | exit code 0 | Weak |
| env --help shows usage | output contains "Usage: env" | Weak |
| env --version shows version | output contains "env" | Weak |
| env prints current environment | output contains "PATH=" | OK |
| env -i prints empty environment | output is empty string | OK |
| env -i FOO=bar prints assignment | output == "FOO=bar" | Strong |
| env echo hello | output == "hello" | Strong |
| env -i FOO=bar sh -c 'echo $FOO' | output == "bar" | Strong |
| env passes through exit code | exit code == 42 | Strong |
| env -u FOO unsets variable | output == "FOO=unset" | Strong |
| env --unset=FOO unsets variable | output == "FOO=unset" | Strong |
| env -C /tmp changes directory | output == "/tmp" or "/private/tmp" | Strong |
| env --chdir=/tmp changes directory | output == "/tmp" or "/private/tmp" | Strong |
| env -C nonexistent exits 125 | exit code == 125 | Strong |
| env -0 uses null delimiter | byte-exact cmp | Strong |
| env unknown flag | exit code non-zero | Weak |
| env -u without value | exit code non-zero | Weak |
| env -C without value | exit code non-zero | Weak |
| env command not found exits 127 | exit code == 127 | Strong |
| env -- echo hello | output == "hello" | Strong |
| env -i0 combined flags | byte-exact cmp | Strong |
| env FOO= sets empty value | output == "FOO=" | Strong |
| env exit code 0 passthrough (regression) | exit code == 0 | Strong |
| env exit code 255 passthrough (regression) | exit code == 255 | Strong |

---

## Flags Coverage

| Flag | Tier | Integration Tests | Notes |
|------|------|-------------------|-------|
| -i | MUST | Yes — behavioral | Strong |
| -u | MUST | Yes — behavioral | Strong |
| -0 | SHOULD | Yes — byte-exact | Strong |
| -C | SHOULD | Yes — behavioral | Strong |
| -P | SHOULD | **None** | Parses correctly; no test |
| -S | SHOULD | **None** | Stub: prints error, does not split |
| -v | SHOULD | **None** | Parses; no output verified |

---

## Issues

### IMPORTANT: -S is a silent stub in production

**Location**: src/env.zig:115-117

The implementation detects `-S` and prints an error message to
stderr, then continues without splitting the string. A user who
passes `-S 'FOO=bar cmd'` will silently get wrong behavior: the
string is never split into arguments. There is no integration
test that would catch this.

The implementation reads:

```zig
if (options.split_string != null) {
    common.printErrorWithProgram(allocator, stderr_writer, "env",
        "-S flag not yet fully implemented", .{});
}
```

A minimal test would be:

```bash
output=$("$binary" -S "FOO=bar" sh -c 'echo $FOO')
if [[ "$output" == "bar" ]]; then ...
```

This test would currently fail (RED), exposing the stub.

### IMPORTANT: -P flag has zero integration tests

**Location**: tests/utilities/env_test.sh (absent)

The flag is implemented: it substitutes the provided path for
PATH when searching for the command. There is no integration
test verifying that a utility found only on the alternate path
is actually located. A suitable test:

```bash
# Create a wrapper in a temp dir
mkdir -p "$TEMP_DIR/altbin"
cp "$binary" "$TEMP_DIR/altbin/myecho"  # or write a tiny script
output=$("$binary" -P "$TEMP_DIR/altbin" myecho hello 2>/dev/null)
if [[ "$output" == "hello" ]]; then ...
```

### IMPORTANT: -v flag has zero integration tests

**Location**: tests/utilities/env_test.sh (absent)

The flag is implemented: it prints `env: setenv NAME=VALUE`
and `env: unsetenv NAME` lines to stderr. No test verifies
this output. A suitable test:

```bash
stderr_out=$(FOO=old "$binary" -v -u FOO BAR=baz sh -c 'true' 2>&1 >/dev/null)
[[ "$stderr_out" =~ "env: unsetenv FOO" ]]
[[ "$stderr_out" =~ "env: setenv BAR=baz" ]]
```

### SUGGESTION: Error tests only check non-zero exit

**Location**: tests/utilities/env_test.sh:172-178

The three error-condition tests ("unknown flag", "-u without
value", "-C without value") use `test_command_fails`, which
only checks for a non-zero exit code. GNU env exits 125 for
usage errors. The tests would pass even if the exit code were
1 or 2. Tightening to `test_command_exit_code ... 125` would
catch regressions.

### SUGGESTION: --help and --version content checks are minimal

**Location**: tests/utilities/env_test.sh:23, 34

`--help` is checked for the string `"Usage: env"`. This passes
even if all flag descriptions are missing. `--version` is
checked for the string `"env"`, which would pass for almost any
output. These are appropriate smoke tests but provide no
protection against help-text regressions.

### SUGGESTION: env prints current environment uses substring match

**Location**: tests/utilities/env_test.sh:46

The test checks `output =~ "PATH="`. This is correct and
sufficient for verifying the basic environment print, but it
does not verify the `NAME=VALUE` format of other variables
or that newlines (not NUL) delimit them by default.

---

## Coverage Gaps (SHOULD-tier flags with zero tests)

1. **-S / --split-string** — confirmed production stub, no test
2. **-P / alt_path** — implemented, no behavioral test
3. **-v / verbose** — implemented, no stderr output test

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] Add -S integration test (will expose stub) — env_test.sh
2. [IMPORTANT] Add -P integration test — env_test.sh
3. [IMPORTANT] Add -v verbose stderr output test — env_test.sh
4. [SUGGESTION] Tighten error exit codes to 125 — env_test.sh:172-178
5. [SUGGESTION] Strengthen --help/--version content checks — env_test.sh:23,34
```

REVIEW COMPLETE - NEEDS_FIXES
