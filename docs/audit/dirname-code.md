# dirname Code Audit

**Date:** 2026-03-28
**Reference:** GNU coreutils (primary), POSIX (baseline)
**Build:** passes (`just build-util dirname`)
**Unit tests:** all pass
**Integration tests:** 88/88 pass

---

## Summary

`src/dirname.zig` is a correct, minimal implementation. All
POSIX path-processing rules are implemented accurately. The only
SHOULD-tier flag (-z) is implemented and verified against the
system GNU binary. No behavioral divergence from GNU was found.
One style-level gap exists (error message format). Test coverage
is strong.

---

## Findings

### [IMPORTANT] Error messages omit the "Try ... --help" hint

**Location:** `src/dirname.zig:35-46` (error handling block)

**Problem:** GNU includes a help hint in every error message. Ours
does not. The error verb also differs slightly:

```
GNU: dirname: invalid option -- 'x'
     Try '/usr/bin/dirname --help' for more information.
Our: dirname: unrecognized option
```

```
GNU: dirname: missing operand
     Try '/usr/bin/dirname --help' for more information.
Our: dirname: missing operand
```

The "missing operand" text matches GNU exactly; only the "Try"
trailer is absent. The invalid-flag text diverges ("invalid option
-- 'x'" vs "unrecognized option"). This is a project-wide pattern
gap.

**Fix:** Add the help-hint trailer to all error paths. Update the
invalid-flag message to match GNU's "invalid option -- 'x'" format.

---

## Coverage Assessment

| Behavior | Tested | Notes |
|---|---|---|
| Basic absolute path | Yes | Integration + unit |
| Relative path | Yes | Both |
| No slash → "." | Yes | Both |
| Root "/" | Yes | Both |
| "//" and "///" | Yes | Both |
| Trailing slash(es) | Yes | Both |
| Empty string → "." | Yes | Both (matches GNU) |
| "." and ".." inputs | Yes | Both |
| Multiple paths | Yes | Both |
| Order preservation | Yes | Integration |
| `-z` null delimiter | Yes | Both (binary comparison) |
| `--zero` long flag | Yes | Integration |
| `--` separator | Yes | Integration |
| Flag-like path (-- prefix) | Yes | Integration |
| Error: no args | Yes | Both |
| Error: invalid flag | Yes | Integration |
| Unicode paths | Yes | Integration |
| Paths with spaces | Yes | Integration |
| Dot-component paths | Yes | Both |

---

## Algorithm Correctness

`extractDirname` correctly implements the POSIX algorithm:

1. Strip trailing slashes (keeping at least one character) ✓
2. Find last `/` in trimmed path ✓
3. If no slash → return "." ✓
4. If slash at position 0 → return "/" ✓
5. Strip trailing slashes from the directory portion ✓

The `//` case: both the system GNU binary and this implementation
return `/`, which is correct for Linux (where `//` has no special
meaning, unlike some other POSIX systems).

---

## Overall Assessment

**APPROVED** (with one IMPORTANT to address)

Fix order:
1. [IMPORTANT] Error messages omit "Try --help" hint —
   `src/dirname.zig:35-46` (project-wide fix preferred)
