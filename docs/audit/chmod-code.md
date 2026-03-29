# chmod Code Audit

Date: 2026-03-28
Auditor: reviewer agent
Build: passes (`zig build`)
Unit tests: all pass

---

## Flag-by-Flag Verdicts

| Flag | Tier | Verdict |
|------|------|---------|
| `-c` | SHOULD | PASS — suppresses output correctly |
| `-f` | SHOULD | PARTIAL — suppresses messages, but exit code is not suppressed (see issue #3) |
| `-h` | MUST | PASS — uses `fchmodat` with `AT_SYMLINK_NOFOLLOW` |
| `-H` | MUST | PASS — wired into recursive traversal |
| `-L` | MUST | PASS — wired into recursive traversal |
| `-P` | MUST | PASS — default no-symlink-follow behavior |
| `-R` | MUST | PASS — recursive traversal implemented |
| `-v` | SHOULD | FAIL — wrong output when mode unchanged (see issue #2) |
| `-C` | SHOULD | STUB — accepted, no-op, documented as such |
| `-E` | SHOULD | STUB — accepted, no-op, documented as such |
| `-i` | SHOULD | STUB — accepted, no-op, documented as such |
| `-I` | SHOULD | STUB — accepted, no-op, documented as such |
| `-N` | SHOULD | STUB — accepted, no-op, documented as such |
| `--reference` | SHOULD | PASS |
| `--dereference` | SHOULD | PASS (default behavior) |
| `--no-preserve-root` | SHOULD | PASS (default behavior) |
| `--preserve-root` | SHOULD | PASS |

---

## Issues

### [CRITICAL] Mode strings starting with `-` are parsed as flags

**Location:** `src/chmod.zig:67` — `ArgParser.parse(ChmodArgs, ...)`

**Problem:** The argument parser treats any argument starting with `-` as a
flag. Modes like `-w`, `-x`, `-rwx` are rejected with "invalid argument"
instead of being parsed as symbolic modes. The only workaround is `--`, which
users are not expected to know or use.

```
$ chmod -w file          # Error: invalid argument
$ chmod -- -w file       # Works
```

GNU and macOS chmod both accept `-w file` directly. This breaks all symbolic
mode removals specified without an explicit who-prefix when the user omits
`--`. Common real-world invocations like `chmod -x script.sh` fail.

**Fix:** In the argument parser or in `runUtility`, detect the first
positional argument after flags and, if it starts with `-`, `+`, or `=` with
no who-prefix, treat it as the mode string rather than as a flag.

---

### [CRITICAL] Umask not applied when no who-specifier is given

**Location:** `src/chmod.zig:604-606` — `applySymbolicMode`

**Problem:** POSIX and macOS require that when no who-specifier is given, the
umask is applied to the mode change. Currently the code defaults to `who = 7`
(all), treating the operation as if `a` were specified, which bypasses the
umask entirely.

Observed:
```
umask 002
chmod '=rw' file    # vibeutils: 666  system: 664
chmod '+w' file     # vibeutils: 222  system: 220
```

The macOS man page states: "If no value is supplied for who, each permission
bit specified in perm, for which the corresponding bit in the file mode
creation mask is clear, is set." For `=`, the clear-then-set operation must
also respect the umask.

**Fix:** Read the process umask (via `std.posix.umask` or a C `umask(0)/umask`
call) and intersect it with the computed permission bits when `who` was not
explicitly given. Track whether who was explicitly specified vs defaulted.

---

### [IMPORTANT] `-v` prints "changed from X to X" when mode is unchanged

**Location:** `src/chmod.zig:842-850` — `applyModeSpecToFile`

**Problem:** When `-v` is set and the mode does not change, the output reads:

```
mode of 'file' changed from 755 (rwxr-xr-x) to 755 (rwxr-xr-x)
```

Both macOS and GNU emit:

```
mode of 'file' retained as 0755 (rwxr-xr-x)
```

The current code unconditionally prints "changed from" whenever verbose is
on, even when `old_mode == new_mode`. This also produces misleading output
when used in scripts that parse verbose lines.

**Fix:** Check `old_mode != new_mode`. If equal, emit "retained as" message.
If different, emit "changed from ... to ..." message.

---

### [IMPORTANT] Verbose output omits leading `0` from octal values

**Location:** `src/chmod.zig:843` — format string `{o:0>3}`

**Problem:** The format `{o:0>3}` emits 3-digit zero-padded octal (e.g. `644`,
`755`). Both macOS and GNU emit a leading `0` prefix for modes without special
bits (e.g. `0644`, `0755`) and no leading `0` for modes that carry special
bits (e.g. `4755`).

```
# vibeutils
mode of 'file' changed from 644 (rw-r--r--) to 755 (rwxr-xr-x)

# system
mode of 'file' changed from 0644 (rw-r--r--) to 0755 (rwxr-xr-x)
```

**Fix:** Determine the field width dynamically. If the mode has special bits
(value >= `0o1000`), use 4 digits with no leading `0`. Otherwise prefix with
`0` and use 3 digits. Alternatively, always use 4-digit `{o:0>4}` and prepend
`0` only when the special-bit nibble is zero.

---

### [IMPORTANT] Multiple actions per clause not supported

**Location:** `src/chmod.zig:587` — `applySymbolicMode`

**Problem:** The symbolic mode grammar (POSIX, macOS) allows a clause to
contain multiple actions:

```
clause ::= [who ...] [action ...] action
action ::= op [perm ...]
```

So `g=u-w` means "set group to user bits, then remove write from group".
Vibeutils parses only one action per clause and rejects these:

```
$ chmod 'g=u-w' file    # Error: invalid mode
$ chmod 'u=r+x' file    # Error: invalid mode
```

Both `g=u-w` and `u=r+x` are listed or implied by the macOS man page
examples.

**Fix:** After consuming the first `op [perm]`, loop to check for another op
character (`+`, `-`, `=`) in the same clause and process additional actions.

---

### [IMPORTANT] Invalid mode error produces duplicate/triple messages

**Location:** `src/chmod.zig:330-344` and `src/chmod.zig:136-141`

**Problem:** When an invalid numeric mode like `999` is given, vibeutils emits
three separate error lines:

```
chmod: warning: '999' contains non-octal digits; numeric modes use octal (0-7)
chmod: invalid mode: '999'
chmod: operation failed: InvalidOctalMode
```

The system emits one:

```
chmod: invalid mode: '999'
```

The third message ("operation failed") leaks the internal error name
`InvalidOctalMode` to users. The first warning is redundant when an error
immediately follows.

**Fix:** Remove the warning when the mode will be rejected as invalid anyway.
In `runUtility`, catch `ChmodError.InvalidMode` and `InvalidOctalMode` before
the `chmodFiles` call (or suppress the "operation failed" message for these
specific errors that are already reported).

---

### [IMPORTANT] 5-digit octal modes rejected; system accepts them

**Location:** `src/chmod.zig:522-546` — `parseMode`

**Problem:** The parser only accepts 1–4 digit octal strings. GNU chmod and
macOS accept any octal value with leading zeros such as `01755` or `001644`:

```
$ chmod 01755 file    # system: sets sticky+rwxr-xr-x (1755)
$ chmod 01755 file    # vibeutils: invalid mode
```

**Fix:** Relax the length restriction in `parseMode`. Accept all-octal
strings of any length (the resulting numeric value is still validated against
`0o7777`). Only reject strings longer than 4 significant digits.

---

### [SUGGESTION] Error message uses "cannot access" for permission-denied on chmod

**Location:** `src/chmod.zig:424` — `applyModeToPath`

**Problem:** When chmod fails due to `EPERM`/`EACCES` on the chmod syscall
itself (not the file lookup), vibeutils says:

```
chmod: cannot access 'file': PermissionDenied
```

The system says:

```
chmod: changing permissions of 'file': Operation not permitted
```

"Cannot access" implies the file does not exist or the path is bad. The real
failure is the permission change itself. Also, `PermissionDenied` is the
internal Zig error name, not a user-facing string.

**Fix:** Distinguish `error.AccessDenied` / `error.PermissionDenied` from
`error.FileNotFound` in the error reporting. Use "changing permissions of
'file'" for chmod failures and "cannot access 'file'" for lookup failures.
Map `PermissionDenied` to "Operation not permitted".

---

### [SUGGESTION] `applyCopyingMode` does not propagate special bits

**Location:** `src/chmod.zig:655-687` — `applyCopyingMode`

**Problem:** Copying permissions with `g=u`, `o=g`, etc. copies only the
`u3` rwx bits (`mode.user`, `mode.group`, `mode.other`). Setuid/setgid bits
are not copied even if the source class carries `s`. This is consistent with
POSIX behavior (the `s` bit on `u` is setuid, on `g` is setgid — copying
between classes does not transfer these), but if `g=u` is run on a file with
setuid, the setuid bit remains on user and group gets rwx only, which is
correct. No behavior bug, but no test documents this.

**Fix:** Add a test that copies from a source class with `s` bit set and
verifies setuid/setgid is not transferred.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| IMPORTANT | 5 |
| SUGGESTION | 2 |

**Overall assessment: NEEDS_FIXES**

### Fix Order

```
Fix Order:
1. [CRITICAL] Mode strings starting with `-` parsed as flags
   — src/chmod.zig:67 (ArgParser.parse call / runUtility)

2. [CRITICAL] Umask not applied when no who-specifier given
   — src/chmod.zig:604-606 (applySymbolicMode)

3. [IMPORTANT] Multiple actions per clause not supported (g=u-w, u=r+x)
   — src/chmod.zig:587 (applySymbolicMode)

4. [IMPORTANT] -v prints "changed from X to X" when mode is retained
   — src/chmod.zig:842 (applyModeSpecToFile)

5. [IMPORTANT] Verbose octal output missing leading 0 prefix
   — src/chmod.zig:843 (format string)

6. [IMPORTANT] Triple error messages for invalid mode input
   — src/chmod.zig:330-344 and 136-141

7. [IMPORTANT] 5-digit octal modes rejected (01755, 001644)
   — src/chmod.zig:522-546 (parseMode)

8. [SUGGESTION] Error message says "cannot access" for chmod EPERM
   — src/chmod.zig:424 (applyModeToPath)

9. [SUGGESTION] Add test: copying from source class with s-bit set
   — src/chmod.zig:655-687 (applyCopyingMode)
```

**REVIEW COMPLETE - NEEDS_FIXES**
