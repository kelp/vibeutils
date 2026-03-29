# id — Code Audit

**Date:** 2026-03-28
**File:** `src/id.zig`
**Result:** NEEDS_FIXES

---

## Flag Verdict Table

| Flag | Tier   | Verdict       | Notes |
|------|--------|---------------|-------|
| -u   | MUST   | PASS          | Effective UID, -r, -n all work |
| -g   | MUST   | PASS          | Effective GID, -r, -n all work |
| -G   | MUST   | FAIL (CRITICAL)| Shows only primary GID for named user |
| -n   | MUST   | PASS          | Name substitution works with -u/-g/-G |
| -r   | MUST   | PASS          | Real UID/GID correct for current process |
| -p   | MUST   | FAIL (IMPORTANT)| Missing login/euid/rgid keywords |
| -a   | SHOULD | FAIL (IMPORTANT)| Should be no-op; instead acts as -G |
| -z   | SHOULD | FAIL (IMPORTANT)| Accepted in default format; GNU rejects it |
| -F   | SHOULD | PASS          | GECOS field printed; Linux path functional |
| -P   | SHOULD | PASS (with caveat)| Linux stub uses hardcoded 0s for class/change/expire |
| -A   | SHOULD | PARTIAL       | Error stub with exit 1; acceptable on Linux |

---

## Issues

### CRITICAL

**[CRITICAL] -G with a named user shows only primary GID**
Location: `src/id.zig:309-313`
Problem: When a username argument is given, the code calls
`printSingleGroup` with only the primary `gid` obtained from the
passwd entry. It never reads `/etc/group` (via `getgrouplist` or
iterating the group database) to find supplementary groups for that
user. Both macOS and GNU `id -G username` return all groups the user
belongs to.

Verification:
```
$ zig-out/bin/id -G tcole
1000
$ /usr/bin/id -G tcole
1000 27 100
```

The same bug affects the default format (`id username`) — the
`groups=` field shows only the primary group:
```
$ zig-out/bin/id tcole
uid=1000(tcole) gid=1000(tcole) groups=1000(tcole)
$ /usr/bin/id tcole
uid=1000(tcole) gid=1000(tcole) groups=1000(tcole),27(sudo),100(users)
```

Fix: Use `getgrouplist(3)` (available on both macOS and Linux) to
enumerate all groups for a named user before printing. Example
C signature:
```c
int getgrouplist(const char *name, gid_t basegid,
                 gid_t *groups, int *ngroups);
```
Call it with the username from the passwd entry and the primary gid,
then use the returned list for `-G` and for the `groups=` field in
default output.

---

### IMPORTANT

**[IMPORTANT] -p is missing the login/euid/rgid conditional lines**
Location: `src/id.zig:476-557`
Problem: The macOS man page specifies four conditional lines for
`-p` (human-readable) output:
1. `login\t<name>` — only when `getlogin(2)` differs from the uid
   name
2. `uid\t<name>` — always
3. `euid\t<name>` — only when effective UID differs from real UID
4. `rgid\t<name>` — only when effective GID differs from real GID
5. `groups\t<name1> <name2> ...` — always

The implementation prints only `uid` and `groups`. It has no call to
`getlogin(2)` and no comparison of effective vs real IDs. Under
normal circumstances (no `su`/`setuid`) the missing lines are
invisible, which is why the test suite passes. Under a setuid
process the output will be structurally wrong.

Fix: Add `extern "c" fn getlogin() ?[*:0]u8;`, compare its result
to the resolved uid name, and emit the `login` line when they
differ. Call `geteuid`/`getuid` and `getegid`/`getgid` and emit
`euid`/`rgid` lines when the pairs differ.

---

**[IMPORTANT] -a is treated as -G instead of being ignored**
Location: `src/id.zig:137`, `src/id.zig:81-82`
Problem: Both macOS and GNU define `-a` as "ignored for
compatibility." The macOS man page says "Ignored for compatibility
with other id implementations." GNU says "ignore, for compatibility
with other versions." Neither reference implementation makes `-a`
equivalent to `-G`.

Current code: `const show_groups = parsed.groups or parsed.all;`
This makes `-a` silently activate `-G` behavior, which is wrong.
Verification:
```
$ zig-out/bin/id -a
27 100 1000          # -G behavior
$ /usr/bin/id -a
uid=1000(tcole) gid=1000(tcole) groups=...  # default format, -a ignored
```

Fix: Remove `parsed.all` from the `show_groups` computation.
`-a` should be parsed and accepted (so it doesn't error) but must
not change output. The test at line 1010–1026 (`id -a shows all
groups (same as -G)`) encodes the wrong behavior and must also be
corrected.

---

**[IMPORTANT] -z accepted in default format; should be rejected**
Location: `src/id.zig:164`
Problem: GNU `id` documents that `-z` is "not permitted in default
format" and exits 1 when `-z` is given without `-u`, `-g`, or `-G`.
Our implementation silently accepts it and replaces the trailing
newline with NUL, producing malformed output.
Verification:
```
$ /usr/bin/id -z; echo "exit=$?"
id: option --zero not permitted in default format
exit=1
$ zig-out/bin/id -z; echo "exit=$?"
uid=1000(tcole) gid=1000(tcole) groups=...  exit=0
```

Fix: After resolving `mode_count` and `parsed.pretty`, check
`parsed.zero` with no mode flag active and reject with an error
message and exit code 1.

---

**[IMPORTANT] -P Linux stub uses hardcoded 0 for class/change/expire**
Location: `src/id.zig:238`
Problem: On Linux the `c_passwd` struct has no `pw_change`,
`pw_class`, or `pw_expire` fields. The Linux code path emits them
as literal `0`. The macOS man page example output shows real values
for `change` and `expire` (`bob:*:0:0::0:0:Robert:/bob:...`),
where those zeros reflect actual database values. On Linux this is
structurally unavoidable, but the format string comment at line 214
claims the Linux output matches macOS format when the field order
differs: macOS is `name:passwd:uid:gid:class:change:expire:gecos:home:shell`
but the Linux code emits `name:passwd:uid:gid::0:0:gecos:home:shell`,
which puts the empty class before the numeric fields rather than
after them. The ordering is consistent with the macOS format (empty
class in position 5, change in 6, expire in 7), so the positional
layout is correct; the issue is documentation only.

No code change needed, but add a comment clarifying that Linux
always emits zeros for positions 6 and 7 because the platform
passwd struct carries no change/expire data.

---

### SUGGESTION

**[SUGGESTION] printPrettyGroups ignores -r context**
Location: `src/id.zig:258`
Problem: `printPrettyFormat` is called after the uid/gid are
resolved, but `printPrettyGroups` calls `getgroups()` for the
current process regardless of the `is_specified_user` path. For a
specified user this means `groups` shows the current process groups
rather than an empty or primary-group-only list. This is less severe
than the `-G` bug above because `-p` with a named user is rare, but
it is inconsistent.

Fix: After the `printSingleGroup`-based fix for `-G` is applied,
use the same group-list function in `printPrettyGroups` for named
users.

---

**[SUGGESTION] -F and default format use effective UID, not resolved uid**
Location: `src/id.zig:200-210`
Problem: When a username is provided via positional argument, `uid`
is set from the passwd lookup. When `-F` runs, it calls
`getpwuid(uid)` which is the correct value. This is fine. The
comment at line 199 could note explicitly that `uid` is already the
target uid (resolved from the positional argument or from
`geteuid()`), to avoid confusion with the similar `getpwuid`
pattern in `-P`.

---

## Summary

| Severity   | Count |
|------------|-------|
| CRITICAL   | 1     |
| IMPORTANT  | 3     |
| SUGGESTION | 2     |

**Assessment: NEEDS_FIXES**

The CRITICAL bug (all-groups enumeration for named users) produces
wrong output for a core POSIX use case. The two behavioral
IMPORTANT bugs (-a acting as -G, -z accepted in default format)
both contradict the reference implementations.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -G/default named user shows only primary group
   — src/id.zig:309-313 and src/id.zig:428-433
   Use getgrouplist(3) to enumerate supplementary groups.

2. [IMPORTANT] -a treated as -G instead of no-op
   — src/id.zig:137
   Remove `parsed.all` from show_groups; fix test at line 1010.

3. [IMPORTANT] -z accepted in default format; should exit 1
   — src/id.zig:164 (add guard after mode_count check)

4. [IMPORTANT] -p missing login/euid/rgid conditional lines
   — src/id.zig:476-557
   Add getlogin() call and effective-vs-real comparisons.

5. [SUGGESTION] -P Linux stub comment clarification
   — src/id.zig:238

6. [SUGGESTION] printPrettyGroups named-user group list
   — src/id.zig:507-515 (deferred until fix #1 lands)
```

REVIEW COMPLETE - NEEDS_FIXES
