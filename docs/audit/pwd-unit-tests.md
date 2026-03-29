# pwd Unit Test Audit

**Date:** 2026-03-28
**File:** `src/pwd.zig`
**Tests:** 13 declared; all 13 pass
**Assessment:** NEEDS_FIXES

---

## Test Inventory

| # | Test name | Type | Notes |
|---|-----------|------|-------|
| 1 | `getWorkingDirectory physical mode` | behavioral | checks absolute path returned |
| 2 | `getWorkingDirectory logical mode without PWD` | behavioral | fallback to physical |
| 3 | `getWorkingDirectory logical mode with valid PWD` | behavioral | tests isValidPwd directly |
| 4 | `isValidPwd security validation` | behavioral | good coverage |
| 5 | `PwdArgs defaults` | parse-only | checks bool defaults only |
| 6 | `runPwd with help flag` | behavioral | checks output content |
| 7 | `runPwd with version flag` | behavioral | checks output content |
| 8 | `runPwd with short help flag` | behavioral | checks output content |
| 9 | `runPwd with short version flag` | behavioral | checks output content |
| 10 | `runPwd with no arguments` | behavioral | checks absolute path + newline |
| 11 | `runPwd with -L flag` | behavioral | weak: only checks absolute path |
| 12 | `runPwd with -P flag` | behavioral | weak: only checks absolute path |
| 13 | `runPwd with invalid flag` | behavioral | checks exit 2 + stderr |

---

## Findings

### [IMPORTANT] `-L` with a valid PWD containing a symlink is not tested at the `runPwd` level

**Location:** `src/pwd.zig:359-379`

`runPwd with -L flag` only confirms the output starts with `/` and ends with `\n`. It does not verify that `-L` actually returns a different path than `-P` when the current directory was reached through a symlink. This is the defining behavioral difference between `-L` and `-P`. A regression that makes `-L` always call `getCwdAlloc` (physical) would pass this test.

Test 3 (`getWorkingDirectory logical mode with valid PWD`) exercises the lower-level function but does so in a no-PWD-set scenario, which falls back to physical. It never exercises the actual logical path where PWD is present and valid.

**Fix:** Add a `runPwd` test that:
1. Creates a temporary symlink to a real directory
2. Changes into the symlink
3. Sets `PWD` env to the symlink path
4. Runs `runPwd` with `-L` and asserts the output equals the symlink path
5. Runs `runPwd` with `-P` and asserts the output equals the resolved real path

---

### [IMPORTANT] `-P` symlink resolution is not tested at the `runPwd` level

**Location:** `src/pwd.zig:381-401`

`runPwd with -P flag` checks only that the output is an absolute path. Whether `-P` actually resolves symlinks — the core POSIX requirement — is not verified. The integration tests cover this, but the unit tests do not.

**Fix:** Add a unit test that changes into a symlinked directory and asserts `-P` returns the real path, not the symlink path (using `testing.tmpDir` and `std.fs.Dir.symLink`).

---

### [IMPORTANT] `-L` vs `-P` conflict (`-L -P` and `-P -L` ordering) is not tested at unit level

**Location:** `src/pwd.zig:122-123`

The implementation documents `-P takes priority when both are set`. No unit test verifies the conflict resolution: when both flags are given in either order, `-P` must win. The integration test suite does check this but a unit-level regression would be undetected until integration runs.

**Fix:** Add a unit test covering `PwdArgs{ .logical = true, .physical = true }` → result equals physical path; and `PwdArgs{ .logical = false, .physical = false }` → result equals physical path (default).

---

### [IMPORTANT] Positional arguments are silently ignored — no unit test for this behavior

**Location:** `src/pwd.zig:30-68`

`PwdArgs.positionals` is parsed and then never checked. The integration test explicitly acknowledges this as a known deviation from POSIX:

> `# NOTE: Current implementation ignores positional arguments (not POSIX compliant)`

No unit test documents this behavior or would catch if it were accidentally changed. GNU pwd also ignores positional arguments (unlike OpenBSD which exits 1 with an error), so the current behavior matches GNU.

**Fix:** Add a unit test that passes a positional argument to `runPwd` and asserts it succeeds with exit 0 and no stderr. This documents the intentional GNU-compatible behavior.

---

### [SUGGESTION] `PwdArgs defaults` is parse-only

**Location:** `src/pwd.zig:251-257`

```zig
test "PwdArgs defaults" {
    const args = PwdArgs{};
    try testing.expect(!args.logical);
    try testing.expect(!args.physical);
    ...
}
```

This tests struct field initialization, not parsed behavior. It would pass even if `ArgParser` set wrong defaults. It is not a behavioral test. It is low-value but not harmful.

---

### [SUGGESTION] `isValidPwd` with a trailing slash in PWD is not tested at unit level

**Location:** `src/pwd.zig:162-180`

The integration tests check `PWD="$path/"` (trailing slash). The unit tests for `isValidPwd` do not cover this case. The implementation uses `statFile` which may or may not normalize trailing slashes depending on OS. This edge case should be unit-tested.

---

## Summary

- **CRITICAL:** 0
- **IMPORTANT:** 4 (−L symlink behavioral, −P symlink behavioral, flag-conflict ordering, positionals silence)
- **SUGGESTION:** 2 (PwdArgs defaults parse-only; trailing slash in isValidPwd)

**No currently broken tests. All 13 pass.** The gaps are missing behavioral tests for the core `-L`/`-P` distinction, which is the main purpose of pwd's flags.

**Overall: NEEDS_FIXES**

Fix order:
1. [IMPORTANT] Add `runPwd` unit test: `-L` returns symlink path, `-P` returns real path — `src/pwd.zig`
2. [IMPORTANT] Add `runPwd` unit test: `-P` resolves symlinks — `src/pwd.zig`
3. [IMPORTANT] Add unit test for `-L -P` / `-P -L` conflict resolution — `src/pwd.zig`
4. [IMPORTANT] Add unit test documenting positional-argument silent-ignore behavior — `src/pwd.zig`
5. [SUGGESTION] Add trailing-slash PWD to `isValidPwd` unit tests — `src/pwd.zig:162`
