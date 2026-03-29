# basename Unit Test Audit

**Date:** 2026-03-28
**Source:** `src/basename.zig`
**Assessment:** NEEDS_FIXES

## Test Inventory

9 test blocks — all behavioral (0 parse-only stubs).

| Test | Type | Verdict |
|---|---|---|
| `basename basic functionality` | behavioral | PASS |
| `basename edge cases` | behavioral | CRITICAL bug |
| `basename suffix removal` | behavioral | PASS |
| `basename multiple files (-a flag)` | behavioral | PASS |
| `basename zero delimiter (-z flag)` | behavioral | PASS |
| `basename error handling` | behavioral | PASS |
| `basename help and version` | behavioral | PASS |
| `computeBasename function directly` | behavioral | CRITICAL bug |
| `basename complex path cases` | behavioral | PASS |
| `basename with -s flag (GNU extension)` | behavioral | PASS |

## Issues

---

```
[CRITICAL] Empty-string input returns "." but GNU primary ref returns ""
Location: src/basename.zig:415 (computeBasename direct test)
          src/basename.zig:257-259 (edge cases test)
Problem: computeBasename("", null) returns "." and the unit tests assert "."
         as the expected value.  GNU basename (coreutils 9.10) outputs an
         empty line for `basename ""`.  POSIX marks this case
         implementation-defined, but the source comment says "follows GNU
         basename specifications".  The test therefore encodes the wrong
         expected value and will not catch a conformance fix.
         Confirmed with: `basename "" | od -c` → `\n`
Fix: Change the expected value in both tests to "" (empty string):
     - computeBasename test: expectEqualStrings("", computeBasename("", null));
     - edge cases test: expectEqualStrings("\n", stdout_buffer.items);
     The implementation in computeBasename() must also be changed to return
     "" instead of "." for an empty-string input.
```

---

```
[IMPORTANT] -z unit test does not use runBasename; NUL termination verified
            only at the raw byte level, output path not exercised via full
            integration path
Location: src/basename.zig:338-361
Problem: The -z test calls runBasename directly and checks buffer bytes
         manually — that is fine and correct.  However it uses
         common.null_writer for stderr, which means any error output from a
         bad flag parse would be silently discarded.  Low risk here but
         inconsistent with all other tests in the file.
Fix: Pass a real stderr ArrayList writer as in the other tests so unexpected
     errors surface.
```

---

```
[IMPORTANT] No test for -z combined with -a (multiple files) via runBasename
            at the full-output level
Location: src/basename.zig:338-361
Problem: The -az test in "basename zero delimiter" checks raw bytes, but
         only for two simple filenames with no path components.  There is no
         test for -az with paths containing slashes, which exercises the
         combined computeBasename + writeOutput path.
Fix: Add a test case: args = ["-az", "/usr/bin/sort", "test.c"]
     Expected bytes: "sort\x00test.c\x00" (12 bytes).
```

---

```
[SUGGESTION] "basename help and version" checks --multiple in help text but
             the flag is registered as --multiple (long) and -a (short)
Location: src/basename.zig:394
Problem: The test asserts indexOf(u8, buffer.items, "--multiple") != null.
         The help text uses "--multiple" as the long form — correct.  But
         the version test only checks that the word "basename" appears in
         output; it does not check the version string, meaning a broken
         version format would still pass.
Fix: Add: try testing.expect(std.mem.indexOf(u8, buffer.items, common.version)
     != null);
```

---

```
[SUGGESTION] No test for unknown-flag error path exit code
Location: src/basename.zig
Problem: error.UnknownFlag is handled and returns ExitCode.misuse (2), but
         no unit test exercises this path.  The error-handling test only
         checks missing-operand and too-many-operands.
Fix: Add test: args = ["-x"], expect exit code 2 and stderr containing
     "unrecognized option".
```

## Summary

- CRITICAL: 1 (empty-string expected value wrong — both implementation and
  test encode a value that diverges from the GNU primary reference)
- IMPORTANT: 2
- SUGGESTION: 2

**REVIEW COMPLETE — NEEDS_FIXES**

Fix Order:
1. [CRITICAL] basename "" should return "" not "." — src/basename.zig:171,415
2. [IMPORTANT] null_writer swallows unexpected errors in -z test — src/basename.zig:344
3. [IMPORTANT] No -az test with real path components — src/basename.zig:338
4. [SUGGESTION] Version test does not verify version string — src/basename.zig:401
5. [SUGGESTION] No unit test for unknown-flag error path — src/basename.zig
