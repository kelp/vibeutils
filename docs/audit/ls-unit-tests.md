# Unit Test Audit: ls

**Date**: 2026-03-28
**Source**: `src/ls/*.zig`
**Tests run**: All pass (1783/1802 total suite; 19 skipped, 0 failed)

---

## Executive Summary

**PASS WITH ISSUES**

The ls test suite is substantial and well-structured. Most integration
tests genuinely verify behavior. However, several tests are weakened
by what they do not assert, a few MUST-tier flags have no behavioral
verification, and three integration tests are acceptance tests (runs
without crash) rather than behavior tests. No tests check parse-only
struct fields, so there are no classic stub-test violations.

---

## Test Inventory

| Test Name | File | Tests Behavior? | Verdict |
|-----------|------|----------------|---------|
| test\_utils - createTestEntry | test\_utils.zig | No — verifies test helper struct fields | STUB |
| test\_utils - createTestEntries | test\_utils.zig | No — verifies test helper struct fields | STUB |
| test\_utils - LsTestEnv basic operations | test\_utils.zig | Yes — runs ls, checks output | OK |
| test\_utils - LsAssertions validation | test\_utils.zig | Partial — exercises assertion helpers on static strings | WEAK |
| basic: lists files in current directory | integration\_test.zig | Yes | OK |
| basic: handles empty directory | integration\_test.zig | Yes | OK |
| basic: shows directories and files together | integration\_test.zig | Yes | OK |
| hidden: ignores hidden files by default | integration\_test.zig | Yes | OK |
| hidden: shows hidden files with -a flag | integration\_test.zig | Yes | OK |
| hidden: shows almost all files with -A flag | integration\_test.zig | Partial — does not verify `.` and `..` are absent | WEAK |
| format: one file per line with -1 flag | integration\_test.zig | Yes | OK |
| format: comma-separated output with -m flag | integration\_test.zig | Yes | OK |
| format: multi-column output by default | integration\_test.zig | Yes | OK |
| long\_format: shows detailed information with -l flag | integration\_test.zig | Yes | OK |
| long\_format: shows human readable sizes with -lh flags | integration\_test.zig | Yes | OK |
| long\_format: shows kilobyte sizes with -lk flags | integration\_test.zig | No — only checks filename presence, not KB output | WEAK |
| long\_format: shows numeric user and group IDs with -n flag | integration\_test.zig | No — only checks filename and permission prefix | WEAK |
| symlinks: shows symlink targets in long format | integration\_test.zig | Yes | OK |
| file\_type: adds indicators with -F flag | integration\_test.zig | Yes | OK |
| directory: lists directory itself with -d flag | integration\_test.zig | Yes | OK |
| inodes: shows inode numbers with -i flag | integration\_test.zig | Yes | OK |
| recursive: lists subdirectories with proper structure | integration\_test.zig | Yes | OK |
| recursive: shows directory headers with proper formatting | integration\_test.zig | Yes | OK |
| recursive: handles symlink cycles safely | integration\_test.zig | Yes | OK |
| append\_slash: appends / to directories but not files | integration\_test.zig | Yes | OK |
| append\_slash: does not add indicators for executables or symlinks | integration\_test.zig | Yes | OK |
| non\_printable: replaces control chars with question marks | integration\_test.zig | Yes | OK |
| omit\_owner: long format without owner column | integration\_test.zig | Partial — line-length comparison is fragile | WEAK |
| omit\_group: long format without group column | integration\_test.zig | Partial — line-length comparison is fragile | WEAK |
| no\_sort: -f shows hidden files (implies -a) | integration\_test.zig | Yes | OK |
| no\_sort: -f does not sort entries alphabetically | integration\_test.zig | Partial — only checks presence, not order | WEAK |
| show\_blocks: -s displays block counts | integration\_test.zig | Yes | OK |
| show\_blocks: -s prints total line | integration\_test.zig | Yes | OK |
| use\_atime: -u flag is accepted | integration\_test.zig | No — smoke test only | SMOKE |
| use\_atime: -u with -t sorts by access time | integration\_test.zig | No — smoke test only | SMOKE |
| multi\_column: -C forces multi-column output | integration\_test.zig | Yes | OK |
| columns\_across: -x sorts entries across rows | integration\_test.zig | Partial — checks all-present + multi-column, not row order | WEAK |
| columns\_across: -x first row contains first entries | integration\_test.zig | Yes | OK |
| full\_time: -T shows seconds in long format | integration\_test.zig | Weak — colon count is an indirect proxy | WEAK |
| full\_time: -T without -l has no effect | integration\_test.zig | Yes | OK |
| follow\_symlinks: -L shows target file info instead of link info | integration\_test.zig | Yes | OK |
| follow\_symlinks: -L does not show symlink arrow | integration\_test.zig | Yes | OK |
| follow\_cmdline: -H flag is accepted | integration\_test.zig | No — smoke test only | SMOKE |
| hide\_backups: -B hides files ending with ~ | integration\_test.zig | Yes | OK |
| ignore\_pattern: -I filters entries matching glob | integration\_test.zig | Yes | OK |
| unsorted: -U disables sorting | integration\_test.zig | No — only checks presence, not order | WEAK |
| version\_sort: -v sorts version numbers naturally | integration\_test.zig | Yes | OK |
| sort\_by\_extension: -X sorts by file extension | integration\_test.zig | Yes | OK |
| output\_width: -w overrides terminal width | integration\_test.zig | Yes | OK |
| lsMain help works with different writers | main.zig | Yes | OK |
| lsMain version works with different writers | main.zig | Yes | OK |
| runLs function works with separate writers | main.zig | Yes | OK |
| initStyle with auto color mode disables colors when stdout is not a TTY | main.zig | Yes | OK |
| entry\_collector - needsMetadata | entry\_collector.zig | Partial — tests struct bool results, not filtering behavior | WEAK |
| entry\_collector - collectFilteredEntries basic | entry\_collector.zig | Yes | OK |
| entry\_collector - collectFilteredEntries with all option | entry\_collector.zig | Yes | OK |
| entry\_collector - hide\_backups filters tilde files | entry\_collector.zig | Yes | OK |
| entry\_collector - ignore\_pattern filters matching files | entry\_collector.zig | Yes | OK |
| sorter - alphabetical sorting | sorter.zig | Yes | OK |
| sorter - reverse alphabetical sorting | sorter.zig | Yes | OK |
| sorter - directories first | sorter.zig | Yes | OK |
| sorter - size sorting | sorter.zig | Yes | OK |
| sorter - time sorting | sorter.zig | Yes | OK |
| sorter - atime sorting with use\_atime | sorter.zig | Yes | OK |
| sorter - ctime sorting with use\_ctime | sorter.zig | Yes | OK |
| sorter - ctime takes precedence over atime | sorter.zig | Yes | OK |
| sorter - extension sorting | sorter.zig | Yes | OK |
| sorter - extension sorting with no extension | sorter.zig | Yes | OK |
| sorter - version sort basic | sorter.zig | Yes | OK |
| sorter - version sort mixed | sorter.zig | Yes | OK |
| sorter - getExtension | sorter.zig | Yes | OK |
| sorter - versionCompare | sorter.zig | Yes | OK |
| formatter - formatTimeWithStyle relative | formatter.zig | Yes | OK |
| formatter - formatTimeWithStyle default recent | formatter.zig | Yes | OK |
| formatter - formatTimeWithStyle default old | formatter.zig | Yes | OK |
| formatter - formatTimeWithStyle full | formatter.zig | Yes | OK |
| formatter - formatTimeWithStyle full always shows year | formatter.zig | Yes | OK |
| formatter - formatTimeWithStyle iso | formatter.zig | Yes | OK |
| formatter - printColumnar basic | formatter.zig | Yes | OK |
| writeColoredPermissions - no color mode writes plain string | formatter.zig | Yes | OK |
| writeColoredPermissions - basic mode adds ANSI codes | formatter.zig | Yes | OK |
| writeColoredPermissions - symlink permissions | formatter.zig | Yes | OK |
| writeNlinkColored - no color writes plain | formatter.zig | Yes | OK |
| writeNlinkColored - basic mode uses bright\_black | formatter.zig | Yes | OK |
| writeUserGroupColored - no color writes plain | formatter.zig | Yes | OK |
| writeUserGroupColored - basic mode uses yellow for user and cyan for group | formatter.zig | Yes | OK |
| writeUserGroupColored - omit\_owner hides user column | formatter.zig | Yes | OK |
| writeUserGroupColored - omit\_group hides group column | formatter.zig | Yes | OK |
| writeSizeColored - no color writes plain | formatter.zig | Yes | OK |
| writeSizeColored - human readable format | formatter.zig | Yes | OK |
| writeSizeColored - truecolor small file uses green | formatter.zig | Yes | OK |
| writeSizeColored - truecolor large file uses red-orange | formatter.zig | Yes | OK |
| writeSizeColored - 256 color mode | formatter.zig | Yes | OK |
| writeSizeColored - basic mode uses green | formatter.zig | Yes | OK |
| writeSizeColored - basic mode bold for human readable | formatter.zig | Yes | OK |
| writeSizeColored - all truecolor tiers | formatter.zig | Yes | OK |
| writeDateColored - no color writes plain | formatter.zig | Yes | OK |
| writeDateColored - truecolor recent file uses bright green | formatter.zig | Yes | OK |
| writeDateColored - truecolor old file uses gray | formatter.zig | Yes | OK |
| writeDateColored - 256 color mode recent | formatter.zig | Yes | OK |
| writeDateColored - basic mode uses blue | formatter.zig | Yes | OK |
| writeDateColored - pads to max width | formatter.zig | Yes | OK |
| writeDateColored - all truecolor age tiers | formatter.zig | Yes | OK |
| formatWithThousands - basic formatting | formatter.zig | Yes | OK |
| display - getFileTypeIndicator | display.zig | Yes | OK |
| display - isExecutable | display.zig | Yes | OK |
| display - escapeName basic | display.zig | Yes | OK |
| display - escapeName special chars | display.zig | Yes | OK |
| display - sanitizeName | display.zig | Yes | OK |
| display - initStyle color=always with NO\_COLOR must not emit ANSI codes | display.zig | Yes | OK |
| display - initStyle color=always without NO\_COLOR produces colors | display.zig | Yes | OK |
| FileSystemId - different device/inode pairs are distinguishable | security\_test.zig | Yes | OK |
| FileSystemId - identical device/inode pairs are equal | security\_test.zig | Yes | OK |
| CycleDetector - basic same-directory detection | security\_test.zig | Yes | OK |
| CycleDetector - real device ID extraction | security\_test.zig | Yes | OK |
| Symlink processing - error handling via metadata enhancement | security\_test.zig | Yes | OK |
| Cycle detection - performance with nested directories | security\_test.zig | Yes | OK |

---

## Parse-Only Tests (CRITICAL)

None found. No test in the ls suite reduces to checking only parsed
struct field values without running the utility. This is the primary
class of stub test and it is absent here.

---

## Smoke-Only Tests (IMPORTANT)

These tests set a flag, run ls, and only verify the tool does not
crash and the files still appear. They cannot catch regressions
where the flag is silently ignored.

| Test | Flag | What it should verify but doesn't |
|------|------|------------------------------------|
| use\_atime: -u flag is accepted | `-u` | That `-ul` shows access time, not mtime, in the timestamp column |
| use\_atime: -u with -t sorts by access time | `-u -t` | That sort order differs from `-t` alone when atimes differ from mtimes |
| follow\_cmdline: -H flag is accepted | `-H` | That a symlink-to-directory argument is listed as its target directory's contents |

---

## Weak Behavioral Tests (IMPORTANT)

Tests that run the utility but whose assertions are too loose to catch
the regression they are named for.

**`hidden: shows almost all files with -A flag`**
(`integration_test.zig:83`)

The test verifies `.hidden` and `visible.txt` appear. It does not
verify that `.` and `..` are absent. A broken `-A` that behaves
identically to `-a` would pass. The defining difference between `-a`
and `-A` is the suppression of `.` and `..`; that is not tested.

**`long_format: shows kilobyte sizes with -lk flags`**
(`integration_test.zig:170`)

Only checks filenames appear. Does not verify that sizes are printed
in kilobytes. A completely ignored `-k` flag would pass this test.

**`long_format: shows numeric user and group IDs with -n flag`**
(`integration_test.zig:184`)

Only checks the filename and permission prefix. Does not verify that
the owner/group columns contain digits rather than names. A completely
ignored `-n` flag would pass this test.

**`omit_owner: long format without owner column`** and
**`omit_group: long format without group column`**
(`integration_test.zig:426`, `465`)

Use line-length comparison (`g_line.len < normal_line.len`) as the
sole behavioral signal. This passes even if both outputs are wrong in
the same direction. A more direct assertion — that the current user's
login name is absent from the `-g` output, or that the current group
name is absent from the `-o` output — would be both clearer and
harder to accidentally satisfy.

**`no_sort: -f does not sort entries alphabetically`**
(`integration_test.zig:518`)

Only checks that all three files appear. Does not verify order.
Without an ordering assertion, a sorted `-f` passes. The test comment
acknowledges directory order is filesystem-dependent, but on Linux
with a `tmpDir`, creation order is stable enough to assert.

**`unsorted: -U disables sorting`**
(`integration_test.zig:811`)

Same problem as `-f` above: only checks presence. A sorted `-U`
passes.

**`full_time: -T shows seconds in long format`**
(`integration_test.zig:669`)

Counts colons in the entire output, which includes the filename and
any other colons. With one file, two or more colons strongly implies
`HH:MM:SS`, but the test does not pin the time format string for the
`test.txt` line specifically. A format like `HH:MM year:col` would
also pass. The formatter unit test for `.full` style is solid; the
integration test adds little confidence on top of it.

---

## Missing Coverage

Flags marked MUST or SHOULD in `docs/specs/ls-flags.md` with no
integration test that verifies behavioral change.

| Flag | Tier | Situation |
|------|------|-----------|
| `-c` (use ctime) | MUST | No integration test. Sorter unit tests cover ctime ordering; the display of ctime in `-lc` is uncovered. |
| `-r` (reverse sort) | MUST | No integration test. Sorter unit tests cover reverse; end-to-end output order uncovered. |
| `-S` (sort by size) | MUST | No integration test. Sorter unit tests cover size ordering; end-to-end output order uncovered. |
| `-t` (sort by time) | MUST | No integration test except `-u -t` smoke test. End-to-end sort order uncovered. |
| `--group-directories-first` | SHOULD | No integration test at all. |
| `-,` (thousands grouping) | SHOULD | `formatWithThousands` unit test covers the formatter; no integration test verifies `-,` affects ls output. |
| `-b` (escape non-printable) | SHOULD | No integration test. (`-q` is tested; `-b` is a different output format.) |
| `--time-style` | SHOULD | No integration test. |
| `-e` (show ACLs) | SHOULD | No test of any kind. |
| `-O` (show file flags) | SHOULD | No test of any kind. |
| `--git` | KEEP | No test of any kind. |
| `--icons` | KEEP | No test of any kind. |
| `--color` | SHOULD | `initStyle` unit tests cover color mode; no integration test verifies `--color=always` leaks ANSI codes or `--color=never` suppresses them in ls output. |

---

## Other Issues

**`test_utils - createTestEntry` / `createTestEntries`**
(`test_utils.zig:397`, `405`)

These tests verify only that the test-helper functions set struct
fields correctly. They have no value as ls behavioral tests. They are
test infrastructure tests, which is harmless but inflates the test
count.

**`entry_collector - needsMetadata`**
(`entry_collector.zig:236`)

Checks bool return values of an internal helper. This is more of a
change-detector than a behavioral test: it will catch accidental
changes to the metadata-needed conditions, which is useful, but it
gives no confidence that the conditions are correct.

**`-A` does not verify the defining behavior**

The difference between `-a` and `-A` is that `-A` suppresses `.` and
`..`. Neither the integration test nor any unit test asserts this.

---

## Findings

| ID | Severity | Description | Location |
|----|----------|-------------|----------|
| F1 | IMPORTANT | `-u` has only a smoke test; no behavioral verification that atime is used as display or sort key | `integration_test.zig:572,584` |
| F2 | IMPORTANT | `-H` has only a smoke test; no behavioral verification | `integration_test.zig:755` |
| F3 | IMPORTANT | `-A` does not verify `.` and `..` are absent from output | `integration_test.zig:83` |
| F4 | IMPORTANT | `-k` test does not verify KB-formatted sizes appear | `integration_test.zig:170` |
| F5 | IMPORTANT | `-n` test does not verify numeric UID/GID appear in output | `integration_test.zig:184` |
| F6 | IMPORTANT | No integration test for `-r` (reverse sort order end-to-end) | — |
| F7 | IMPORTANT | No integration test for `-S` (sort by size end-to-end) | — |
| F8 | IMPORTANT | No integration test for `-t` alone (sort by mtime end-to-end) | — |
| F9 | IMPORTANT | No integration test for `-c` (use ctime in display or sort) | — |
| F10 | IMPORTANT | No integration test for `--group-directories-first` | — |
| F11 | SUGGESTION | `-f` and `-U` tests check presence only, not order | `integration_test.zig:518,811` |
| F12 | SUGGESTION | `-g`/`-o` tests use line-length proxy instead of column-content assertion | `integration_test.zig:426,465` |
| F13 | SUGGESTION | `-T` integration test uses colon count rather than asserting the time format for the file's line | `integration_test.zig:669` |
| F14 | SUGGESTION | No integration test for `--time-style` | — |
| F15 | SUGGESTION | No integration test for `-b` (C-style escapes, distinct from `-q`) | — |
| F16 | SUGGESTION | No integration test for `-,` thousands grouping in ls output | — |
| F17 | SUGGESTION | No integration test for `--color` flag effect on output | — |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -A test must assert . and .. are absent — integration_test.zig:83
2. [IMPORTANT] -u smoke tests: add atime display/sort behavioral assertion — integration_test.zig:572,584
3. [IMPORTANT] -H smoke test: add behavioral assertion (symlink dir resolved) — integration_test.zig:755
4. [IMPORTANT] -k test: assert sizes contain "K" suffix or numeric KB value — integration_test.zig:170
5. [IMPORTANT] -n test: assert owner/group columns contain digits — integration_test.zig:184
6. [IMPORTANT] Add integration test for -r (reverse sort order) — new test
7. [IMPORTANT] Add integration test for -S (sort by size, largest first) — new test
8. [IMPORTANT] Add integration test for -t alone (sort by mtime, newest first) — new test
9. [IMPORTANT] Add integration test for -c (ctime display or sort) — new test
10. [IMPORTANT] Add integration test for --group-directories-first — new test
11. [SUGGESTION] -f and -U: assert order, not just presence — integration_test.zig:518,811
12. [SUGGESTION] -g and -o: assert column name absent, not just line length — integration_test.zig:426,465
13. [SUGGESTION] -T: assert time format on the specific file line — integration_test.zig:669
14. [SUGGESTION] Add integration test for --time-style — new test
15. [SUGGESTION] Add integration test for -b escape sequences — new test
16. [SUGGESTION] Add integration test for -, thousands grouping — new test
17. [SUGGESTION] Add integration test for --color flag suppressing/emitting ANSI — new test
```

---

REVIEW COMPLETE - NEEDS\_FIXES
