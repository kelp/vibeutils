# Integration Test Audit: find

**Date**: 2026-03-28
**Test file**: tests/utilities/find_test.sh

## Executive Summary

PASS WITH ISSUES. The suite covers the most common predicates
with output-verifying tests, but has one failing test caused by
a missing tool dependency (`xxd`), silently broken `-exec`
behavior that goes completely untested, and large swathes of
implemented flags with zero integration test coverage. Several
"accepted" tests verify only that a flag does not crash, not
that it produces correct output.

## Test Run Result

45 passed, 1 failed (`find -print0 produces NUL bytes` — fails
because `xxd` is not present in the Nix shell environment).

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|-------------------|---------|
| find binary | binary exists | INFRA |
| find --help | EXIT_ONLY | WEAK |
| find --version | EXIT_ONLY | WEAK |
| find default lists all entries | OUTPUT (pattern match) | GOOD |
| find -name *.txt | OUTPUT (pattern match) | GOOD |
| find -name hello* | OUTPUT (pattern match) | GOOD |
| find -name ? single char | OUTPUT (pattern match) | GOOD |
| find -iname case insensitive | OUTPUT (pattern match) | GOOD |
| find -type f | OUTPUT (pattern match) | GOOD |
| find -type d | OUTPUT (pattern match) | GOOD |
| find -type l | OUTPUT (pattern match) | GOOD |
| find -empty | OUTPUT (pattern match) | GOOD |
| find -size +1000c | OUTPUT (pattern match) | GOOD |
| find -size 0c | OUTPUT (pattern match) | GOOD |
| find -maxdepth 1 | OUTPUT (pattern match) | GOOD |
| find -maxdepth 0 | OUTPUT (pattern match) | GOOD |
| find -mindepth 2 | OUTPUT (pattern match) | GOOD |
| find -perm 755 | OUTPUT (pattern match) | GOOD |
| find -newer | OUTPUT (pattern match) | GOOD |
| find -or operator | OUTPUT (pattern match) | GOOD |
| find -not operator | OUTPUT (pattern match) | GOOD |
| find ! operator | OUTPUT (pattern match) | GOOD |
| find parentheses grouping | OUTPUT (pattern match) | GOOD |
| find -print0 produces NUL bytes | OUTPUT (binary check) | FAILING |
| find -delete | FILE SYSTEM CHECK | GOOD |
| find -depth order | OUTPUT (line position) | GOOD |
| find -L follows symlinks | OUTPUT (pattern match) | GOOD |
| find -prune skips directory contents | OUTPUT (pattern match) | GOOD |
| find -atime 0 matches recent file | OUTPUT (pattern match) | GOOD |
| find -ctime 0 matches recent file | OUTPUT (pattern match) | GOOD |
| find -atime +1000 excludes recent file | OUTPUT (pattern match) | GOOD |
| find -links 2 matches hard-linked files | OUTPUT (pattern match) | GOOD |
| find -links 1 matches single-link files | OUTPUT (pattern match) | GOOD |
| find -nouser flag accepted | EXIT_ONLY + empty check | WEAK |
| find -nogroup flag accepted | EXIT_ONLY + empty check | WEAK |
| find -xdev flag accepted | OUTPUT (pattern match) | MODERATE |
| find -mount flag accepted | OUTPUT (pattern match) | MODERATE |
| find -ok flag accepted | EXIT_ONLY | WEAK |
| find nonexistent path | EXIT_ONLY + stderr check | OK |
| find unknown predicate | EXIT_ONLY + stderr check | OK |
| find missing argument to -name | EXIT_ONLY | OK |
| find invalid -type argument | EXIT_ONLY | OK |
| find combined -type -name -empty | OUTPUT (pattern match) | GOOD |
| find -user $(whoami) | OUTPUT (pattern match) | GOOD |
| find -path */sub/* | OUTPUT (pattern match) | GOOD |
| find -regex stub returns no matches | EXIT_ONLY + empty check | WEAK |

---

## Weak Tests (exit-code only, no behavioral check)

### find -nouser flag accepted (line 400)
The test confirms exit 0 and empty output against files owned
by the current user. A no-op implementation that always returns
0 with no output would pass this test identically. The test
comment says "positive-match testing requires root" but it does
not even verify negative behavior is correct.

### find -nogroup flag accepted (line 407)
Same problem as `-nouser` above.

### find -ok flag accepted (line 443)
Feeds `/dev/null` as stdin (so no confirmation is given) and
only checks `exit_code -eq 0`. A stub that ignores `-ok` and
returns 0 passes this test. The test does not verify that `-ok`
prompts on stderr or that declining a prompt suppresses
execution.

### find -regex stub returns no matches (line 537)
The test name itself says "stub" — it explicitly only verifies
that the stub doesn't crash and returns no matches. No test
verifies that `-regex` actually matches anything correctly when
the pattern should match.

---

## Missing Coverage

### MUST flags with no integration test

| Flag | Tier | Has Integration Test? | Notes |
|------|------|-----------------------|-------|
| -H | MUST | no | Confirmed working; not tested |
| -X | MUST | no | Confirmed working (warns on special chars); not tested |
| -d | MUST | no | Confirmed working (depth-first short flag); not tested |
| -f | MUST | no | Confirmed working; not tested |
| -x | MUST | no | Confirmed working; not tested |
| -exec | MUST | no | BROKEN — silently produces no output (see F1) |
| -exec {} + | MUST | no | BROKEN — returns error (see F1) |
| -execdir | MUST | no | Broken — produces no output (same root cause) |
| -mtime | MUST | no | Working; not tested |
| -group | MUST | no | Working; not tested |
| -inum | MUST | no | Working; not tested |
| -ls | MUST | no | Working; not tested |
| -flags | MUST | no | Untested (macOS-specific; behavior on Linux unclear) |
| -follow | MUST | no | Accepted (does not crash); no output test |
| -fstype | MUST | no | Untested |
| -amin | MUST | no | Working; not tested |
| -cmin | MUST | no | Not tested |
| -mmin | MUST | no | Working; not tested |
| -anewer | MUST | no | Working (returns matching); not tested |
| -cnewer | MUST | no | Working; not tested |
| -print | MUST | no | Implicit in all tests; no explicit test |

### SHOULD flags with no integration test

| Flag | Tier | Has Integration Test? | Notes |
|------|------|-----------------------|-------|
| -P | SHOULD | no | Working; not tested |
| -E | SHOULD | no | BROKEN — accepts flag, produces no output (see F2) |
| -s | SHOULD | no | BROKEN — does not sort output (see F3) |
| -regex | SHOULD | stub-only | Stub confirmed; no positive-match test |
| -iregex | SHOULD | no | Not tested |
| -ipath | SHOULD | no | Working; not tested |
| -wholename | SHOULD | no | Working; not tested |
| -lname | SHOULD | no | Working; not tested |
| -ilname | SHOULD | no | Not tested |
| -depth N | SHOULD | no | Working (depth as predicate); not tested |
| -newerXY | SHOULD | no | Working; not tested |
| -gid | SHOULD | no | Working; not tested |
| -uid | SHOULD | no | Working; not tested |
| -quit | SHOULD | no | BROKEN — with -print -quit, nothing is printed (see F4) |
| -samefile | SHOULD | no | Working; not tested |
| -printf | SHOULD | no | BROKEN — %f outputs full path instead of filename (see F5) |
| -mount | SHOULD | weak | Only verifies file.txt appears, not xdev behavior |
| -noleaf | SHOULD | no | Not tested |
| -true | SHOULD | no | Working; not tested |
| -false | SHOULD | no | Working (no output); not tested |
| -mnewer | SHOULD | no | Not tested |
| -Bmin | SHOULD | no | Not tested |
| -Bnewer | SHOULD | no | Not tested |
| -Btime | SHOULD | no | Not tested |
| -acl | SHOULD | no | Not tested |
| -ignore_readdir_race | SHOULD | no | Not tested |
| -noignore_readdir_race | SHOULD | no | Not tested |
| -okdir | SHOULD | no | Not tested |
| -sparse | SHOULD | no | Not tested |
| -xattr | SHOULD | no | Not tested |
| -xattrname | SHOULD | no | Not tested |

---

## Expected Output Issues

### -print0 test uses `xxd` (line 267)
`xxd` is not available in the Nix shell environment used by
this project. The test always fails on this system. It should
use `od`, `hexdump`, or a `printf`/`read -r -d` approach that
works with standard Nix-available tools.

### -xdev / -mount tests only check that known files appear
Both tests (lines 421-433) create a single-filesystem temp dir
and confirm the target file appears. They do not verify that a
mounted filesystem boundary is actually excluded. This is a
structural limitation (you need two devices to test xdev) but
the test name "flag accepted" is honest about this. Consider
annotating these as structural skips rather than passing tests
to avoid false confidence.

---

## System Comparison

Tests run on Linux (Nix environment) against
`/usr/bin/find` (GNU find).

### -exec is silently broken (CRITICAL)

```
$ /usr/bin/find /tmp/dir -name "*.txt" -exec echo "SYSTEM_FOUND:" {} ";"
SYSTEM_FOUND: /tmp/dir/a.txt

$ ./zig-out/bin/find /tmp/dir -name "*.txt" -exec echo "OUR_FOUND:" {} ";"
(no output)
```

`-exec` parses without error and exits 0, but the utility is
never invoked. No integration test covers this because the
only action-path test for `-exec`-like behavior uses `-ok`
(which is itself weak). The `-delete` test inadvertently
exercises the action pipeline in a non-exec path.

`-exec {} +` (batching form) errors:
```
find: missing argument to '-exec'
```

### -E (extended regex) produces no matches

```
$ ./zig-out/bin/find -E /tmp/dir -regex ".+\.(txt|md)"
(no output, exit 0)
```

The alternation `(txt|md)` is an ERE feature. With `-E`, it
should match. Without `-E`, it is BRE and `|` is literal.
Our implementation accepts `-E` but does not apply it.

### -s does not sort output

```
$ ./zig-out/bin/find -s /tmp/dir -name "*.txt"
/tmp/dir/beta.txt
/tmp/dir/alpha.txt   ← out of order
/tmp/dir/charlie.txt
```

The flag is accepted and exits 0 but the output is not sorted.

### -printf %f outputs full path instead of filename

GNU/BSD spec: `%f` = filename (last component only).

```
$ /usr/bin/find /tmp/dir -maxdepth 1 -printf "%f\n"
tmp.x2kpodw3Cq
b.md
a.txt

$ ./zig-out/bin/find /tmp/dir -maxdepth 1 -printf "%f\n"
/tmp/tmp.x2kpodw3Cq    ← wrong: full path printed
/tmp/tmp.x2kpodw3Cq/b.md
/tmp/tmp.x2kpodw3Cq/a.txt
```

### -quit with -print does not print

```
$ /usr/bin/find /tmp/dir -name "*.txt" -print -quit
/tmp/dir/a.txt

$ ./zig-out/bin/find /tmp/dir -name "*.txt" -print -quit
(no output)
```

`-quit` terminates before any output is flushed, or the
interaction between `-print` and `-quit` is not implemented.

### -perm with prefix modifiers is broken

Both `+mode` (any bits set) and `-mode` (all bits set) return
an error:

```
$ ./zig-out/bin/find /tmp/dir -perm -644
find: invalid mode '-644'

$ ./zig-out/bin/find /tmp/dir -perm /111
find: invalid mode '/111'
```

The GNU/BSD spec requires both forms. The existing `-perm 755`
test only covers exact-match mode.

---

## Missing Test Scenarios (from macOS spec)

The following behaviors described in `docs/specs/find-macos.txt`
have no integration test:

1. **-d option** performs depth-first traversal (the flag form,
   not the predicate form; `-depth` predicate is tested)
2. **-f path** adds path to traversal list (useful for paths
   starting with `!`, `(`, `-`)
3. **-s** traverses in lexicographical order
4. **-x / -xdev** stays on same device (structural limitation,
   but should be annotated)
5. **-E** enables extended regex for -regex/-iregex
6. **-X** warns about filenames unsafe for xargs
7. **-H** follows command-line symlinks only (not traversal
   symlinks)
8. **-exec utility ; with {} substitution** (confirmed broken)
9. **-exec utility {} +** batching form (confirmed broken)
10. **-execdir** (runs from file's directory; confirmed broken)
11. **-mtime** modification time predicate
12. **-amin, -cmin, -mmin** minute-based time predicates
13. **-anewer, -cnewer, -mnewer** file-relative time predicates
14. **-ls** long listing action
15. **-group** group membership predicate
16. **-inum** inode number predicate
17. **-flags** BSD file flags (macOS-specific)
18. **-fstype** file system type predicate
19. **-follow** deprecated symlink-follow primary
20. **-depth N** numeric depth predicate
21. **-true / -false** boolean constants
22. **-quit** stops traversal after first match
23. **-samefile** hard link identity test
24. **-printf** formatted output action
25. **-newerXY** cross-field time comparison
26. **-ipath / -wholename / -lname / -ilname** path variants
27. **-regex / -iregex** positive-match cases
28. **-perm -mode** (all bits) and **-perm +mode / /mode** (any
    bits)
29. **-gid / -uid** numeric group/user predicates
30. **-ok** prompting behavior (decline suppresses execution)

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| F1 | CRITICAL | `-exec` is silently broken: runs exit 0, invokes nothing |
| F2 | CRITICAL | `-exec {} +` errors: "missing argument to -exec" |
| F3 | CRITICAL | `-printf %f` outputs full path, not filename component |
| F4 | HIGH | `-exec` bug means `-execdir` is also broken (same root cause) |
| F5 | HIGH | `-E` flag accepted but extended regex not applied |
| F6 | HIGH | `-s` flag accepted but output is not sorted |
| F7 | HIGH | `-quit` with `-print` prints nothing (flush/ordering bug) |
| F8 | HIGH | `-perm -mode` and `-perm /mode` reject valid prefix forms |
| F9 | HIGH | `-print0` test fails: `xxd` not available in Nix environment |
| F10 | HIGH | No test for `-exec` behavior at all (bug goes undetected) |
| F11 | HIGH | No test for `-execdir` behavior |
| F12 | HIGH | No test for `-mtime`, `-amin`, `-cmin`, `-mmin` |
| F13 | HIGH | No test for `-group`, `-inum`, `-ls`, `-printf` |
| F14 | HIGH | No test for `-d` / `-s` / `-f` global option flags |
| F15 | MEDIUM | `-nouser` / `-nogroup` tests check only that flag is accepted |
| F16 | MEDIUM | `-ok` test only checks exit code, not prompting behavior |
| F17 | MEDIUM | `-regex` has only a stub/negative test; no positive match |
| F18 | MEDIUM | No tests for `-samefile`, `-newerXY`, `-gid`, `-uid` |
| F19 | MEDIUM | No tests for `-true` / `-false` operators |
| F20 | LOW | `-xdev` / `-mount` tests do not verify cross-device exclusion |

---

## Fix Order for Programmer

```
Fix Order:
1.  [CRITICAL] -exec silently broken (invokes nothing) — src/find.zig
2.  [CRITICAL] -exec {} + errors: missing argument — src/find.zig
3.  [CRITICAL] -printf %f outputs full path not filename — src/find.zig
4.  [HIGH]     -exec fix propagates to -execdir — src/find.zig
5.  [HIGH]     -E flag not applied to regex evaluation — src/find.zig
6.  [HIGH]     -s flag does not sort output — src/find.zig
7.  [HIGH]     -quit with -print flushes nothing — src/find.zig
8.  [HIGH]     -perm prefix forms (-mode, /mode) rejected — src/find.zig
9.  [HIGH]     Fix -print0 test to use od/hexdump not xxd — tests/utilities/find_test.sh:267
10. [HIGH]     Add -exec behavioral test — tests/utilities/find_test.sh
11. [HIGH]     Add -execdir behavioral test — tests/utilities/find_test.sh
12. [HIGH]     Add -mtime, -amin, -cmin, -mmin tests — tests/utilities/find_test.sh
13. [HIGH]     Add -group, -inum, -ls, -printf tests — tests/utilities/find_test.sh
14. [HIGH]     Add -d, -s, -f global option tests — tests/utilities/find_test.sh
15. [MEDIUM]   Add -regex positive-match test — tests/utilities/find_test.sh
16. [MEDIUM]   Add -samefile, -newerXY, -gid, -uid tests — tests/utilities/find_test.sh
17. [MEDIUM]   Add -true / -false operator tests — tests/utilities/find_test.sh
18. [MEDIUM]   Upgrade -nouser/-nogroup tests to check output — tests/utilities/find_test.sh
19. [MEDIUM]   Upgrade -ok test to verify prompt/decline behavior — tests/utilities/find_test.sh
```

REVIEW COMPLETE - NEEDS_FIXES
