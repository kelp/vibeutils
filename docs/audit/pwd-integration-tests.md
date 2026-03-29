# pwd Integration Test Audit

**Date:** 2026-03-28
**File:** `tests/utilities/pwd_test.sh`
**Tests:** 56 run; all 56 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory (summary by section)

| Section | Test names | Count | Pass? |
|---------|------------|-------|-------|
| Basic flags | help, version (via test_basic_flags) | 2 | PASS |
| Core functionality | default behavior, -P, --physical, -L, --logical | 5 | PASS |
| Flag behavior | last flag wins, -L --physical, --logical -P | 3 | PASS |
| Output formatting | ends with newline, is absolute, no extra whitespace | 3 | PASS |
| Symlink handling | -P resolves, -P resolves nested, -P resolves chains | 4 | PASS |
| PWD env handling | valid, relative, nonexistent, empty, unset, symlink, -P ignores | 7 | PASS |
| Error conditions | invalid long/short flags, error message, multiple invalid, unknown long | 5 | PASS |
| Positional arguments | ignores positionals (current behavior x3) | 3 | PASS |
| POSIX compliance | success code, failure code, default is physical, output format, -L -P / -P -L | 6 | PASS |
| Edge cases | long names, special characters, deep nesting | 3 | PASS |
| Cross-platform | consistent output, PATH independence | 2 | PASS |
| Performance | rapid successive calls | 1 | PASS |
| Complex symlinks | chain resolution, chain with PWD, relative symlink | 3 | PASS |
| Env edge cases | trailing slash, dot components | 2 | PASS |
| GNU compat | --logical, --physical, --help, --version | 4 | PASS |
| Security | no sensitive terms in error, dangerous PWD safely handled | 2 | PASS |
| Final validation | test count ≥50, cleanup check | 2 | PASS |

---

## Findings

### [IMPORTANT] Positional argument tests document a known POSIX divergence without enforcing GNU behavior

**Location:** `tests/utilities/pwd_test.sh:291-303`

The tests explicitly call out:

> `# NOTE: Current implementation ignores positional arguments (not POSIX compliant)`
> `# TODO: Fix implementation to reject positional arguments per POSIX`

GNU pwd also ignores extra operands and exits 0 (confirmed: `pwd /some/path` on GNU coreutils silently prints CWD). POSIX says undefined behavior. The comment "not POSIX compliant" is misleading — it matches GNU. The TODO suggests fixing to reject them, which would break GNU compatibility. The test should be updated to document the intentional GNU-compatible behavior and remove the misleading TODO.

---

### [IMPORTANT] `pwd last flag wins` test does not check which flag actually won

**Location:** `tests/utilities/pwd_test.sh:94-99`

```bash
if [[ -n "$lp_output" && -n "$pl_output" ]]; then
    print_test_result "pwd last flag wins" "PASS" "-L -P and -P -L both work"
```

This only checks both return non-empty output. It does not verify which flag takes priority. Per the implementation comment "−P takes priority when both are set" (not "last wins"), the test name is also misleading. A regression that ignored `-L` entirely would pass this test.

**Fix:** When inside a symlinked directory with a valid PWD set to the symlink path, assert that `-L -P` returns the physical path (since `-P` wins), and `-P -L` also returns the physical path.

---

### [IMPORTANT] `-L` preserves symlink path test relies on shell PWD behavior, not binary behavior

**Location:** `tests/utilities/pwd_test.sh:236-245`

```bash
cd "$link_dir"
PWD="$link_dir"
export PWD
local logical_symlink_pwd
logical_symlink_pwd=$("$binary" -L 2>/dev/null)
if [[ "$logical_symlink_pwd" == "$link_dir" ]]; then
```

This test sets `PWD="$link_dir"` explicitly before calling the binary. This is correct. However, the test for the chain symlink case (line 452-460) does the same but uses `chain_link3` which is a symlink-to-symlink-to-symlink. The intermediate `isValidPwd` stat comparison uses inode matching, which works, but the test does not verify what happens when the inode-check fails (i.e., when PWD is set to a path whose inode does not match the current directory's inode). There is no negative test at this level for inode mismatch.

---

### [SUGGESTION] "pwd last flag wins" test name contradicts the implementation semantics

**Location:** `tests/utilities/pwd_test.sh:94`

The implementation at `src/pwd.zig:122` reads:

```zig
// -P takes priority when both are set (physical is the safer default)
const use_logical = args.logical and !args.physical;
```

This is not "last flag wins" — it is "-P always wins". The GNU man page says "If no option is specified, -P is assumed" but does not specify priority when both are given. The test name "pwd last flag wins" is incorrect and could mislead future maintainers.

**Fix:** Rename to "pwd -P takes priority over -L" and add actual assertions.

---

### [SUGGESTION] "pwd comprehensive test count" meta-test is fragile

**Location:** `tests/utilities/pwd_test.sh:573-577`

```bash
if [[ $TESTS_RUN -ge 50 ]]; then
    print_test_result "pwd comprehensive test count" "PASS"
```

This counts the global `TESTS_RUN` counter from the test session, not just pwd tests. If the test runner adds or removes tests for other utilities before pwd runs, this meta-assertion can give false results.

**Fix:** Remove this test; rely on the runner's summary for count validation.

---

### [SUGGESTION] `--physical` and `--logical` long option tests are exit-code only

**Location:** `tests/utilities/pwd_test.sh:75-87` via `test_command_output_pattern`

```bash
test_command_output_pattern "pwd --physical long option" "^/.*" "$binary" --physical
test_command_output_pattern "pwd --logical long option" "^/.*" "$binary" --logical
```

These only confirm output starts with `/`. They do not check that `--physical` and `--logical` map correctly to `-P` and `-L` respectively (i.e., same output as the short forms). A swap of the two long option handlers would pass.

---

## Summary

- **CRITICAL:** 0
- **IMPORTANT:** 3 (last-flag-wins test doesn't check winner; positionals TODO misleading; inode mismatch not tested)
- **SUGGESTION:** 3 (test name wrong; meta-count test fragile; long option tests are pattern-only)

**All 56 tests pass.** The suite is the strongest pwd test suite in the project. The symlink and PWD environment coverage is thorough. The main gaps are that several behavioral assertions are too weak (non-empty / starts with /) to catch regressions in flag priority.

**Overall: NEEDS_FIXES**

Fix order:
1. [IMPORTANT] Tighten "pwd last flag wins" to assert which flag actually wins — `pwd_test.sh:94`
2. [IMPORTANT] Update positionals comment from "not POSIX compliant" to "matches GNU behavior" — `pwd_test.sh:291`
3. [IMPORTANT] Add inode-mismatch negative test for `-L` with wrong PWD — `pwd_test.sh`
4. [SUGGESTION] Rename "last flag wins" test to "-P takes priority over -L" — `pwd_test.sh:94`
5. [SUGGESTION] Remove meta-count test — `pwd_test.sh:573`
6. [SUGGESTION] Add output-equality checks to `--physical`/`--logical` long option tests — `pwd_test.sh:75`
