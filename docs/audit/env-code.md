# env Code Audit

**Date:** 2026-03-28
**File:** `src/env.zig`
**Result:** NEEDS_FIXES

---

## Flag-by-Flag Verdict

| Flag | Tier | Verdict |
|------|------|---------|
| `-i` | MUST | PASS — clears environment correctly |
| `-u` | MUST | PASS — unsets variable correctly |
| `-0` | SHOULD | PARTIAL — works for print-env but missing mutual-exclusion check with utility |
| `-C` | SHOULD | PASS — chdir before exec, exits 125 on failure |
| `-P` | SHOULD | WRONG — sets PATH in child env instead of using it only for utility search |
| `-S` | SHOULD | STUB — parses the flag, emits a warning to stderr, does nothing else |
| `-v` | SHOULD | PARTIAL — outputs to stderr correctly but format differs from macOS |

---

## Issues

```
[CRITICAL] -S (split-string) is a confirmed stub
Location: src/env.zig:114-117
Problem: The flag is parsed and stored, but the only action taken is
emitting "env: -S flag not yet fully implemented" to stderr. The
string is never split and no arguments from it are injected into the
pipeline. The help text advertises -S and --split-string=STRING
without marking them as unimplemented. -S is a SHOULD-tier flag
used by shebang lines; silently doing nothing while printing a
warning to stderr instead of acting on the string is stub behavior.
Fix: Either implement split-string processing per the macOS spec
(space/tab splitting, single/double quotes, backslash escapes,
env-var substitution, '#' comment handling) or remove the flag
entirely and return error.UnknownFlag when -S is passed.
```

```
[CRITICAL] -P sets PATH in child environment instead of searching it
Location: src/env.zig:140-148
Problem: The macOS spec states -P replaces the directory search path
used to locate the utility, not the PATH variable seen by the child.
The current implementation does `env_map.put("PATH", alt)`, which
puts the alt path into the child's environment as PATH. A child
command run with `env -i -P /usr/bin printenv PATH` outputs
"/usr/bin", which is wrong: the child should see no PATH (because
-i was given). The -P value should be used only when resolving the
utility binary path before exec, and should never appear in the
child's environment unless the caller also sets it via NAME=VALUE.
Fix: Use alt_path only as the search path passed to execvpeZ (or
equivalent PATH-based lookup), not as a value written into the
child's env_map.
```

```
[CRITICAL] Bare dash (-) does not imply -i
Location: src/env.zig:180-207 (parseArgs)
Problem: Both macOS and GNU specify that a bare "-" argument is
equivalent to -i (clear environment). The macOS usage line shows
"env [-0iv] [-u name] [name=value ...]" with "-" as a synonym,
and the GNU help text reads "A mere - implies -i." The current
parseArgs function reaches the bare "-" in the short-flag branch
(arg.len > 1 check fails because len == 1, and arg[0] == '-'),
so it falls through to the NAME=VALUE / command detection at
line 196. A bare "-" contains no '=', so it is treated as the
start of a command. `env - FOO=bar` runs the binary named "-"
(not found, exit 127) rather than clearing the environment.
Verified: `zig-out/bin/env - FOO=bar` prints the full environment
(136+ lines) instead of one line.
Fix: In parseArgs, add an explicit check before the short-flag
branch: if `std.mem.eql(u8, arg, "-")` then set
`options.ignore_environment = true` and continue.
```

```
[IMPORTANT] -0 accepted with a utility argument (should be an error)
Location: src/env.zig:158-167
Problem: The macOS spec explicitly states: "Both -0 and utility may
not be specified together." The current implementation ignores this
constraint: `env -0 echo hello` outputs "hello" with exit 0 instead
of rejecting the combination. Per spec, the -0 flag is only valid
when printing the environment (no utility given).
Fix: After parsing arguments, if options.null_delimiter and
options.command.len > 0, emit an error to stderr and return exit
code 125.
```

```
[IMPORTANT] execCommand uses fork+wait instead of execve
Location: src/env.zig:370-392
Problem: The implementation uses process.Child.init/spawn/wait,
which forks a child and then waits for it. The real env utility
calls execve, replacing its own process image with the target
command. The fork model has two observable side effects:
1. Signals sent to env during child execution (SIGINT, SIGTERM,
   SIGHUP) are not forwarded to the child process. Ctrl-C sent to
   a pipeline will kill env but the child may survive or behave
   differently than expected.
2. env remains in the process table as a waiting parent, consuming
   a PID and a kernel task-struct entry for the duration of the
   child's execution.
Zig provides std.posix.execveZ and std.posix.execvpeZ_expandArg0
which can be used to implement the correct replace-process behavior.
Fix: Replace Child.spawn/wait with a call to
std.posix.execvpeZ_expandArg0 (or execveZ with a manual PATH
search). On failure (FileNotFound → 127, EACCES/ENOEXEC → 126),
print the error and call std.process.exit directly.
```

```
[IMPORTANT] Flags after first NAME=VALUE assignment are still parsed
as options (not treated as command start)
Location: src/env.zig:196-207
Problem: The macOS spec says "The above options are only recognized
when they are specified before any name=value options." Once the
parser sees a NAME=VALUE token, all subsequent tokens that look like
flags should be treated as the start of the command. The current
code only stops parsing flags when it hits a non-flag, non-assignment
token. A flag-looking token (e.g., -u) that appears after an
assignment is still parsed as a flag. Verified: `env FOO=bar -u FOO`
unsets FOO from the environment rather than treating "-u" as the
command name (which should fail with exit 127).
Fix: Track a boolean `seen_assignment` in parseArgs. Once set, treat
any subsequent argument that starts with "-" as the beginning of the
command (set `options.command = args[i..]` and break), unless it is
a bare "--".
```

```
[IMPORTANT] -v verbose format does not match macOS format
Location: src/env.zig:129-137
Problem: macOS env with -v prints verbose output to stderr in the
format:
  env: setenv   FOO bar
  env: unsetenv HOME
Our implementation uses:
  env: setenv FOO=bar
  env: unsetenv HOME
The macOS format uses a tab-separated or space-padded key/value pair
without an '=' separator in the setenv line. While -v is not tested
by integration tests, the format mismatch means scripts that parse
-v output against the macOS format will fail.
Fix: Change the setenv verbose line from
  `"env: setenv {s}={s}\n"` to `"env: setenv   {s} {s}\n"` to
match the macOS two-space-then-name-then-space-then-value format.
(Confirm the exact spacing by running macOS env -v if available.)
```

```
[IMPORTANT] 126 exit code path in execCommand is unreachable
Location: src/env.zig:379-384
Problem: The code inside child.wait()'s catch block checks
`if (err == error.FileNotFound) 127 else 126`. However, wait() on
a process.Child does not return error.FileNotFound; that error comes
only from spawn(). The spawn() catch block at line 374 already
returns 127 for all spawn errors without distinguishing 126. The
result is that 126 (found but cannot invoke) is never returned.
A command that exists but is not executable should produce exit 126,
not 127.
Fix: In the spawn() catch block, inspect the error: return 127 for
error.FileNotFound, return 126 for error.AccessDenied and
error.PermissionDenied, and 125 for other unexpected errors.
Remove the unreachable FileNotFound check in wait().
```

```
[SUGGESTION] -z is accepted as a null-delimiter alias but is absent
from the flags table and the macOS spec
Location: src/env.zig:252
Problem: The parser maps both '0' and 'z' to null_delimiter. The
macOS spec uses only -0; -z is a GNU extension. The flags.md table
lists -0 as SHOULD and does not list -z at all. Accepting -z
silently without documenting it creates an undocumented extension.
Fix: Either add -z to the flags table as a GNU extension (SHOULD,
GNU-only) and document it in the help text, or remove 'z' from the
case branch to match the macOS behavior.
```

```
[SUGGESTION] Tests for -v, -P, -S, and bare dash are all parse-only
or absent
Location: src/env.zig:856-873 and integration test env_test.sh
Problem: All unit tests for -P and -S check only that the parsed
field is set correctly. There are no behavioral tests that verify:
- -P uses the path to locate the utility (not set child PATH)
- -S actually splits and injects arguments
- bare "-" clears the environment
- -0 with a command argument fails
The integration test file has 26 tests but covers none of the above
four behaviors.
Fix: Add integration tests for each of these behaviors after the
bugs above are fixed.
```

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 4 |
| SUGGESTION | 2 |

**Overall assessment: NEEDS_FIXES**

The core use cases (print env, set/unset variables, run commands,
-i, -u, -C, -0) work correctly and all 26 integration tests pass.
Three correctness bugs block complete compliance: bare "-" is
silently mishandled, -P pollutes the child environment instead of
searching it, and -S is a stub that advertises itself as working.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Bare - does not imply -i — src/env.zig:180-207
2. [CRITICAL] -S is a stub: implement or remove — src/env.zig:114-117
3. [CRITICAL] -P sets child PATH instead of search path — src/env.zig:140-148
4. [IMPORTANT] -0 with utility not rejected — src/env.zig:158-167
5. [IMPORTANT] fork+wait instead of execve — src/env.zig:370-392
6. [IMPORTANT] Flags parsed after NAME=VALUE — src/env.zig:196-207
7. [IMPORTANT] 126 exit code unreachable — src/env.zig:374-384
8. [SUGGESTION] -v format differs from macOS — src/env.zig:129-137
9. [SUGGESTION] Document or remove -z alias — src/env.zig:252
```

REVIEW COMPLETE - NEEDS_FIXES
