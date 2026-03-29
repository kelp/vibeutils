# id — Unit Test Audit

Date: 2026-03-28
Auditor: reviewer agent
Result: **NEEDS_FIXES**

## Test Run

33/33 tests pass. No skips. Runtime normal (~40ms).

```
run test 33 passed 40ms MaxRSS:7M
```

## Test Inventory

| # | Test Name | Behavioral? | Notes |
|---|-----------|-------------|-------|
| 1 | id default output contains uid and gid | Yes | Contains-check on uid=/gid= |
| 2 | id -u prints effective user ID | Partial | Parses as integer; no value check |
| 3 | id -g prints effective group ID | Partial | Parses as integer; no value check |
| 4 | id -G prints all group IDs | Weak | Length>1 + newline; no numeric check |
| 5 | id -un prints effective user name | Yes | Compares against getUserById |
| 6 | id -gn prints effective group name | Partial | Non-empty + newline; no name check |
| 7 | id -ru prints real user ID | Yes | Compares against getCurrentUserId |
| 8 | id -rg prints real group ID | Yes | Compares against getCurrentGroupId |
| 9 | id -z uses NUL delimiter | Yes | Checks final byte == 0 |
| 10 | id help flag | Yes | Contains "Usage: id" |
| 11 | id short help flag | Yes | Contains "Usage: id" |
| 12 | id version flag | Yes | Contains "id" and common.name |
| 13 | id short version flag | Partial | Contains "id" only |
| 14 | id unknown flag returns misuse | Yes | exit 2 + stderr prefix |
| 15 | id -n without -u/-g/-G returns misuse | Yes | exit 2 + message check |
| 16 | id -r without -u/-g/-G returns misuse | Yes | exit 2 + message check |
| 17 | id mutually exclusive -u and -g | Yes | exit 2 |
| 18 | id extra operand returns misuse | Yes | exit 2 + "extra operand" |
| 19 | id nonexistent user returns error | Yes | exit 1 + "no such user" |
| 20 | id default output has groups field | Yes | Contains "groups=" |
| 21 | id -Gn prints group names | Weak | Non-empty + newline; doesn't verify names |
| 22 | id with numeric user ID | Partial | Contains "uid="; doesn't check UID value |
| 23 | id -p outputs human-readable format with uid line | Yes | Contains "uid\t" |
| 24 | id -p outputs groups line | Yes | Contains "groups\t" |
| 25 | id -p is mutually exclusive with -u -g -G | Yes | exit 2 |
| 26 | id -p does not contain uid= format | Yes | Negative check |
| 27 | id -a shows all groups (same as -G) | Yes | Output of -a equals output of -G |
| 28 | id -a with -n shows group names | Weak | Non-empty; no content check |
| 29 | id -A prints audit stub and exits 1 | Yes | exit 1 + message check |
| 30 | id -F displays full name | Weak | Non-empty + newline; no GECOS content check |
| 31 | id -P displays passwd entry format | Partial | Counts >= 6 colons; doesn't validate fields |
| 32 | id -P output contains current username | Yes | Checks startsWith(username) |
| 33 | printSingleGroup outputs numeric GID with delimiter | Yes | Full expected string comparison |

## Flag Coverage

| Flag | Tier | Has Test | Quality |
|------|------|----------|---------|
| -u | MUST | Yes (#2) | Partial — no value assertion |
| -g | MUST | Yes (#3) | Partial — no value assertion |
| -G | MUST | Yes (#4) | Weak — no numeric content check |
| -n | MUST | Yes (#5,#6,#21) | Mixed; -un good, -gn/-Gn weak |
| -r | MUST | Yes (#7,#8) | Good |
| -p | MUST | Yes (#23,#24,#25,#26) | Good |
| -a | SHOULD | Yes (#27,#28) | Partial |
| -A | SHOULD | Yes (#29) | Good (stub behavior) |
| -F | SHOULD | Yes (#30) | Weak — GECOS content not verified |
| -P | SHOULD | Yes (#31,#32) | Partial — field values not verified |
| -z | SHOULD | Yes (#9) | Good |

## Findings

---

**[IMPORTANT] id -G test does not verify numeric content**
Location: `src/id.zig:672`
Problem: Test checks `len > 1` and trailing newline but never
parses any token as a number. A bug that emits alphabetic
characters (e.g. a name instead of an ID) would pass.
Fix:
```zig
const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
var iter = std.mem.splitScalar(u8, trimmed, ' ');
while (iter.next()) |token| {
    _ = try std.fmt.parseInt(u32, token, 10);
}
```

---

**[IMPORTANT] id -gn test does not verify the output is a name**
Location: `src/id.zig:710`
Problem: Checks non-empty + newline. A bug that prints a
number instead of a name passes the test. Compare to -un (#5)
which correctly resolves and compares the expected name.
Fix: Resolve expected group name via `getGroupById(getegid())`
and compare with `expectEqualStrings`.

---

**[IMPORTANT] id -Gn test does not verify names are present**
Location: `src/id.zig:921`
Problem: Same structural weakness as -gn: non-empty output
with a trailing newline is the entire assertion. A bug that
emits numbers instead of names passes.
Fix: Verify at least one token is non-numeric, or cross-check
against -G numeric output.

---

**[IMPORTANT] id -F test does not verify the GECOS field**
Location: `src/id.zig:1050`
Problem: Checks exit 0 and trailing newline. Any non-empty
line passes. A bug that prints the login name instead of the
GECOS string goes undetected.
Fix: Look up the expected GECOS via `getpwuid(geteuid())` and
compare against stdout. Alternatively, at minimum assert that
the output does not look like a plain UID number.

---

**[IMPORTANT] id -P test only counts colons**
Location: `src/id.zig:1064`
Problem: Counting >= 6 colons verifies that something
colon-delimited was emitted, but not that any field is
correct. The first field (username) is verified by test #32,
but UID and GID values are never checked.
Fix: Parse the colon-delimited fields and assert that field
index 2 matches `geteuid()` and field index 3 matches
`getegid()`.

---

**[SUGGESTION] id -u and -g tests do not assert a specific value**
Location: `src/id.zig:634`, `src/id.zig:654`
Problem: Tests parse the output as an integer to verify it is
numeric, but never compare the value to the expected UID/GID.
A bug that prints a hardcoded number (e.g. 0) passes. Compare
to -ru (#7) and -rg (#8) which do assert the expected value.
Fix: Compare `parseInt` result against `geteuid()` / `getegid()`.

---

**[SUGGESTION] id -a with -n test has no content assertion**
Location: `src/id.zig:1028`
Problem: `len > 1` is the sole assertion. Mirroring the
-Gn test above, a regression where names become numbers
is invisible.
Fix: Same approach as the -Gn fix recommendation above.

---

**[SUGGESTION] -z delimiter not tested with -g or -G**
Location: `src/id.zig:759`
Problem: The -z test only exercises `-u -z`. The -z path
for -g and -G uses the same `delimiter` variable so it
would work, but it is never confirmed.
Fix: Add one test covering `-g -z` or `-G -z`.

---

**[SUGGESTION] -p does not check the euid/elogin line**
Location: `src/id.zig:956`
Problem: The spec says -p also prints "euid" if effective
differs from real. That path is untested. The "login" prefix
path (when `getlogin()` differs) is also untested.
Fix: These require a setuid environment and are hard to unit
test; note them as integration test candidates.

---

## Parse-Only Tests

Zero parse-only tests found. Every test invokes `runId` and
checks output or exit code.

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| IMPORTANT | 4 |
| SUGGESTION | 4 |

Overall: **NEEDS_FIXES**

The suite has no parse-only tests and covers all MUST/SHOULD
flags. The weaknesses are shallow assertions: -G, -gn, -Gn,
and -F check shape (non-empty, newline-terminated) but not
content. The -P test counts colons but skips field
validation. These gaps would allow regressions in name
resolution to go undetected.

## Fix Order

```
Fix Order:
1. [IMPORTANT] id -G: verify output tokens are numeric — src/id.zig:672
2. [IMPORTANT] id -gn: verify output is a group name, not a number — src/id.zig:710
3. [IMPORTANT] id -Gn: verify output contains names, not numbers — src/id.zig:921
4. [IMPORTANT] id -F: verify GECOS field value — src/id.zig:1050
5. [IMPORTANT] id -P: verify UID/GID fields in passwd entry — src/id.zig:1064
6. [SUGGESTION] id -u/-g: assert value equals geteuid()/getegid() — src/id.zig:634,654
7. [SUGGESTION] id -a with -n: verify names in output — src/id.zig:1028
8. [SUGGESTION] -z: add test with -g or -G — src/id.zig:759
```

REVIEW COMPLETE - NEEDS_FIXES
