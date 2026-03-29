# basename Code Audit

**Date:** 2026-03-28
**Reference:** GNU coreutils (primary), POSIX (baseline)
**Build:** passes (`just build-util basename`)
**Unit tests:** all pass
**Integration tests:** 78/78 pass

---

## Summary

`src/basename.zig` is a clean, well-structured implementation. All
SHOULD-tier flags (-a, -s, -z) are implemented and working. The
POSIX two-argument form (NAME SUFFIX) and the GNU multi-file
extension are both correct. One critical behavioral divergence from
GNU exists for empty-string input.

---

## Findings

### [CRITICAL] Empty string returns "." instead of empty string

**Location:** `src/basename.zig:171-172`

**Problem:** When given an empty string as input, the implementation
returns `"."`. GNU coreutils returns an empty string (a bare
newline). Verified against `/usr/bin/basename ""`:

```
$ /usr/bin/basename ""   ->  (empty line, 1 byte: 0x0a)
$ our basename ""        ->  . (2 bytes: 0x2e 0x0a)
```

The same divergence appears in the unit test at line 415, which
asserts `"."` for empty input and therefore passes but validates
the wrong behavior.

POSIX does not define behavior for empty input, so GNU is the
governing reference here.

**Fix:**

```zig
fn computeBasename(path: []const u8, maybe_suffix: ?[]const u8) []const u8 {
    if (path.len == 0) {
        return "";   // GNU returns empty, not "."
    }
    // ... rest unchanged
```

The unit test at line 415 must also be updated:

```zig
try testing.expectEqualStrings("", computeBasename("", null));
```

The integration test at `tests/utilities/basename_test.sh:41`
(`"POSIX: empty string becomes dot"`) also validates wrong behavior
and must be updated to expect an empty line.

---

### [IMPORTANT] Error messages omit the "Try ... --help" hint

**Location:** `src/basename.zig:55-67` (error handling block)

**Problem:** GNU error messages include a "Try '...' --help for
more information." trailer. Ours do not. Example:

```
GNU: basename: invalid option -- 'x'
     Try '/usr/bin/basename --help' for more information.
Our: basename: unrecognized option
```

This is a project-wide pattern gap, not unique to basename. The
error text itself is also slightly different ("invalid option --
'x'" vs "unrecognized option" and "option requires an argument --
's'" vs "option missing required argument").

**Fix:** Add the help hint to error output. The exact wording
("invalid option -- 'x'") matches GNU more closely than
"unrecognized option" and should be updated project-wide.

---

### [SUGGESTION] `computeBasename` test at line 415 asserts wrong behavior

**Location:** `src/basename.zig:415`

Already covered under the CRITICAL finding above. The test
is not a separate issue — fixing the implementation will require
fixing this test.

---

### [SUGGESTION] Help says `--multiple` in content check; long flag is correct

**Location:** `src/basename.zig:395`

The integration test checks for `--multiple` in help output.
The help text says `-a, --multiple`. No issue; this is
consistent. Noted for completeness.

---

## Coverage Assessment

| Behavior | Tested | Notes |
|---|---|---|
| Basic path stripping | Yes | Integration + unit |
| Root `/` | Yes | Both test layers |
| `//` edge case | Yes | Both test layers |
| Trailing slashes | Yes | Both test layers |
| POSIX 2-arg (NAME SUFFIX) | Yes | Integration only |
| Suffix no-match | Yes | Both |
| Suffix equals entire name | Yes | Both (but wrong for empty) |
| Empty suffix | Yes | Both |
| `-a` multiple files | Yes | Both |
| `-s` implies `-a` | Yes | Both |
| `-z` null delimiter | Yes | Both (binary comparison) |
| `-az` combined | Yes | Integration |
| `--` separator | Yes | Integration |
| Empty string input | Yes | WRONG (asserts ".") |
| Error: no args | Yes | Both |
| Error: too many args | Yes | Both |
| Error: invalid flag | Yes | Integration |

---

## Overall Assessment

**NEEDS_FIXES**

Fix order:
1. [CRITICAL] Empty string returns "." instead of "" —
   `src/basename.zig:171-172` (and line 415 test, integration test)
2. [IMPORTANT] Error messages omit "Try --help" hint —
   `src/basename.zig:55-67`
