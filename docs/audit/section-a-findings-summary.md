# Section A — Audit Findings Summary
**Scope:** find, cp, rm, ln, mv, mkdir, touch, basename, dirname, mktemp  
**Source reports:** docs/audit/{utility}-code.md, docs/audit/{utility}-unit-tests.md  
**Date compiled:** 2026-04-04

---

## 1. CRITICAL Findings

### 1.1 Logic / Behavioral CRITICAL

| ID | Utility | Affected File | Location | Description |
|----|---------|--------------|----------|-------------|
| C-FIND-01 | find | `src/find.zig` | lines 147–148, 1584 | **-regex/-iregex stubs** always return `false`; `find . -regex ".*"` silently matches nothing |
| C-FIND-02 | find | `src/find.zig` | lines 152–154, 1585 | **-Bmin/-Bnewer/-Btime stubs** always return `true`; any file matches any birth-time predicate |
| C-FIND-03 | find | `src/find.zig` | line 159, 1586 | **-newerXY stub** always returns `true`; any `-newerXY` variant matches all files |
| C-FIND-04 | find | `src/find.zig` | line 164, 1618–1623 | **-printf stub** ignores format string entirely; always emits `path\n` |
| C-FIND-05 | find | `src/find.zig` | line 448 | **-s no-op**; traversal order is never sorted (macOS spec requires lexicographic order) |
| C-FIND-06 | find | `src/find.zig` | line 294 | **-perm rejects +mode/-mode prefix forms**; `find . -perm -644` errors instead of matching |
| C-FIND-07 | find | `src/find.zig` | line 294 | **-perm rejects symbolic modes** (`u=rw` etc.); spec requires full chmod symbolic syntax |
| C-FIND-08 | find | `src/find.zig` | lines 1417–1425 | **-size block-unit rounding wrong**; compares raw bytes instead of rounded-up 512-byte blocks |
| C-FIND-09 | find | `src/find.zig` | lines 855–879, 1059–1083 | **-exec/-execdir `{}+` batch form** not implemented; reported as "missing argument" |
| C-RM-01 | rm | `src/rm.zig` | lines 89–92, 107 | **-W deletes files** instead of attempting undelete; exits 0; all three behaviors wrong |
| C-LN-01 | ln | `src/ln.zig` | lines 211, 278 | **-h/-n stub**: `no_dereference` stored but never consulted; symlink-to-directory as link_name is silently entered |
| C-LN-02 | ln | `src/ln.zig` | lines 423–454 | **-i 'y' fails**: falls through to `symLink`/`linkat` without removing existing destination → `PathAlreadyExists` |
| C-MV-01 | mv | `src/mv.zig` | line 695 | **Crash (SIGABRT)** on `mv parentdir parentdir/child`; Zig maps EINVAL to `unreachable` in `renameZ` |
| C-MV-02 | mv | `src/mv.zig` | lines 700–711 | **-i silently ignored on Linux**; interactive branch lives inside `error.PathAlreadyExists` which `rename(2)` never raises on Linux |
| C-MV-03 | mv | `src/mv.zig` | lines 653, 703–711, 819–826 | **Last-flag-wins missing for -f/-i/-n**; three flags stored as independent booleans; `-n -f` leaves no-clobber winning |
| C-TOUCH-01 | touch | `src/touch.zig` | lines 104–107 | **-A is a documented stub** that exits non-zero; SHOULD-tier flag fails loudly instead of implementing or omitting |
| C-TOUCH-02 | touch | `src/touch.zig` | lines 110–113 | **-h does not imply -c**; `touch -h new_file` creates a regular file; macOS spec: "-h implies -c" |
| C-TOUCH-03 | touch | `src/touch.zig` | lines 454–502 | **-d ignores timezone**; `parseIso8601` treats all input as UTC; trailing Z and `+HH:MM` offsets silently discarded |
| C-BASENAME-01 | basename | `src/basename.zig` | lines 171–172 | **Empty string returns "."** instead of empty string; GNU returns empty; unit test at line 415 locks in wrong behavior |
| C-MKTEMP-01 | mktemp | `src/mktemp.zig` | line 208 | **Bare user-supplied template routed to `/tmp`** instead of cwd; default template and bare template indistinguishable |
| C-MKTEMP-02 | mktemp | `src/mktemp.zig` | lines 139, 147 | **-t with slash template silently uses basename** instead of emitting "contains directory separator" error |
| C-MKTEMP-03 | mktemp | `src/mktemp.zig` | lines 130–136 | **Implicit suffix not recognized**; `myapp.XXXXXXtxt` fails with "too few X's" instead of treating `txt` as suffix |

---

### 1.2 Test Quality CRITICAL

| ID | Utility | Affected File | Location | Description |
|----|---------|--------------|----------|-------------|
| CT-FIND-01 | find | `src/find.zig` | (no test) | **-exec MUST-tier** has zero unit tests |
| CT-FIND-02 | find | `src/find.zig` | (no test) | **-user MUST-tier** has zero unit tests |
| CT-FIND-03 | find | `src/find.zig` | (no test) | **-group MUST-tier** has zero unit tests |
| CT-FIND-04 | find | `src/find.zig` | (no test) | **-nogroup MUST-tier** has zero unit tests |
| CT-FIND-05 | find | `src/find.zig` | (no test) | **-newer MUST-tier** has zero unit tests (only alias `-mnewer` tested) |
| CT-FIND-06 | find | `src/find.zig` | (no test) | **-follow/-L/-H MUST-tier** options have zero unit tests |
| CT-FIND-07 | find | `src/find.zig` | (no test) | **-and/-a MUST-tier** operator has zero unit tests |
| CT-CP-01 | cp | `src/cp.zig` | lines 1302–1345 | **5 parse-only stubs** for symlink-mode flags check struct fields, not filesystem behavior |
| CT-CP-02 | cp | `src/cp.zig` | line 1511 | **-a parse-only stub**: checks `rt.recursive/preserve/symlink_mode`; never copies a tree |
| CT-CP-03 | cp | `src/cp.zig` | lines 1623–1652 | **Last-wins flag stubs**: call `resolveConflicts()` directly, never `runUtility()` |
| CT-CP-04 | cp | `src/cp.zig` | lines 1956–1997 | **5 redundant config stubs** for -x, -l, -s, -b, -b -S duplicate behavioral tests below them |
| CT-CP-05 | cp | `src/cp.zig` | line 1824 | **-N parse-only stub**: no behavioral symlink test |
| CT-LN-01 | ln | `src/ln.zig` | line 970 | **-P test is cannot-fail**: `lstat` inode comparison is trivially true in both P and non-P cases; test comment admits `-P` is unimplemented |
| CT-LN-02 | ln | `src/ln.zig` | line 750 | **-r test is a stub**: manually calls `symLink` directly; never invokes `runLn` with `relative=true` |
| CT-MV-01 | mv | `src/mv.zig` | line 214 | **"directory move" cannot-fail**: `access` success silently skips the catch block; source never verified gone |
| CT-TOUCH-01 | touch | `src/touch.zig` | lines 753, 761 | **parseTimestamp tests are parse-only**: only assert `sec > 0`; wrong epoch values pass |
| CT-TOUCH-02 | touch | `src/touch.zig` | line 856 | **-t timestamp test cannot-fail**: only checks `mtime > 0`; any positive timestamp passes |

---

## 2. IMPORTANT Findings

### 2.1 Behavioral IMPORTANT

| ID | Utility | Affected File | Location | Description |
|----|---------|--------------|----------|-------------|
| I-FIND-01 | find | `src/find.zig` | lines 1440, 1457, 1468 | **-mtime/-atime/-ctime truncates** instead of rounding up to next full 24-hour period |
| I-FIND-02 | find | `src/find.zig` | lines 1488, 1508, 1519 | **-mmin/-amin/-cmin truncates** instead of rounding up to next full minute |
| I-FIND-03 | find | `src/find.zig` | line 266 | **-mtime time-unit suffixes** (`smhdw`) not parsed; `-mtime -1h` errors |
| I-FIND-04 | find | `src/find.zig` | line 239 | **-size T/P unit suffixes** missing; `-size 1T` errors (macOS spec) |
| I-FIND-05 | find | `src/find.zig` | lines 1768–1778 | **-ok always denies** with wrong prompt format; missing command and path in `< ? ... >` |
| I-FIND-06 | find | `src/find.zig` | lines 1608–1611 | **-okdir always denies** with wrong prompt format |
| I-FIND-07 | find | `src/find.zig` | line 435 | **-follow not recognized** in expression position; only works as global option |
| I-FIND-08 | find | `src/find.zig` | lines 1194, 1340 | **-gid/-uid reject names**; macOS spec allows names in addition to numeric IDs |
| I-FIND-09 | find | `src/find.zig` | lines 1972–1995 | **-flags +/- prefix semantics** not implemented; all calls use "at least all" unconditionally |
| I-FIND-10 | find | `src/find.zig` | lines 1955–1961 | **-fstype always false on Linux** (stub); macOS also missing `local`/`rdonly` pseudo-types |
| I-FIND-11 | find | `src/find.zig` | lines 560–563 | **-delete does not check -L incompatibility**; should error when both are combined |
| I-CP-01 | cp | `src/cp.zig` | lines 487–492 | **-f always unlinks** even when destination is writable; breaks hard links unnecessarily |
| I-CP-02 | cp | `src/cp.zig` | lines 654–678 | **-p missing chown**: uid/gid not preserved; `std.fs.File.Stat` doesn't expose uid/gid; needs `posix.stat` + `fchown` |
| I-CP-03 | cp | `src/cp.zig` | lines 61, 106 | **-N wrong behavior**: sets `symlink_mode = follow_none` instead of suppressing BSD file flags |
| I-CP-04 | cp | `src/cp.zig` | lines 471–475 | **Special files not recreated under -R**: fifos, device nodes return error instead of `mknod` |
| I-CP-05 | cp | `src/cp.zig` | lines 596, 626 | **-x uses openFile on directory**: `EISDIR` silently swallowed on macOS, disabling filesystem-boundary check |
| I-RM-01 | rm | `src/rm.zig` | lines 287–303 | **-f/-i flag ordering broken**: force always wins; last-flag-wins semantics not implemented |
| I-RM-02 | rm | `src/rm.zig` | lines 294–303 | **Write-protected prompt ignores tty check**: prompts even when stdin is a pipe/`/dev/null` |
| I-RM-03 | rm | `src/rm.zig` | line 245 | **-d verbose suppressed by prior error**: `any_errors` flag gates verbose output for ALL subsequent removes |
| I-LN-01 | ln | `src/ln.zig` | line 209 | **-F activates force without -s**: macOS spec says `-F` is no-op unless `-s` specified |
| I-LN-02 | ln | `src/ln.zig` | line 459 | **-b ignores SIMPLE_BACKUP_SUFFIX env var**: suffix hardcoded to `~`; GNU reads this env var |
| I-LN-03 | ln | `src/ln.zig` | lines 183–190 | **--backup=CONTROL panics**: `ParseError.TooManyValues` not caught; prints Zig stack trace |
| I-LN-04 | ln | `src/ln.zig` | lines 587–593 | **-v with -r shows original target** not computed relative path; GNU shows stored path |
| I-MV-01 | mv | `src/mv.zig` | lines 672–677 | **Non-standard hint message** on every -f overwrite; not in GNU or macOS; pollutes stderr in scripts |
| I-MV-02 | mv | `src/mv.zig` | lines 862–864, 898–900, 907–909 | **-nv prints arrow even when move skipped**: verbose caller unaware of no-clobber skip |
| I-MV-03 | mv | `src/mv.zig` | lines 432–479 | **crossFilesystemMove verbose chatter**: emits 4 internal lines instead of standard single arrow |
| I-MV-04 | mv | `src/mv.zig` | lines 863, 899, 908 | **Verbose uses GNU single-quote style** (`'src' -> 'dest'`) instead of macOS style (no quotes) |
| I-MV-05 | mv | `src/mv.zig` | line 724 | **Error messages expose Zig error tags** (`error.FileNotFound`) instead of POSIX strings |
| I-MKDIR-01 | mkdir | `src/mkdir.zig` | lines 177–194 | **-m rejects symbolic mode strings**: only parses octal; `u+rwx` errors; GNU accepts full chmod syntax |
| I-MKDIR-02 | mkdir | `src/mkdir.zig` | lines 272–275 | **-p -m applies mode to ALL intermediate dirs**: GNU spec: only leaf directory gets -m mode |
| I-TOUCH-01 | touch | `src/touch.zig` | lines 415, 489 | **-t and -d reject SS=60** (leap second); spec allows 60 |
| I-TOUCH-02 | touch | `src/touch.zig` | lines 419, 490 | **Pre-1970 timestamps rejected** on 64-bit target; removes valid range |
| I-TOUCH-03 | touch | `src/touch.zig` | line 136 | **"-" creates file** named `-` instead of updating stdout's timestamps (GNU spec) |
| I-BASENAME-01 | basename | `src/basename.zig` | lines 55–67 | **Error messages omit "Try --help" hint** and use different error verb than GNU |
| I-DIRNAME-01 | dirname | `src/dirname.zig` | lines 35–46 | **Error messages omit "Try --help" hint** and use different error verb than GNU |
| I-MKTEMP-01 | mktemp | `src/mktemp.zig` | lines 82–98 | **--tmpdir rejects no-argument form**: GNU accepts `--tmpdir` without a value; ours errors |
| I-MKTEMP-02 | mktemp | `src/mktemp.zig` | lines 291–309 | **fillRandom leaves positions uninitialized** for templates with >256 X's |

---

### 2.2 Test Quality IMPORTANT

| ID | Utility | Affected File | Location | Description |
|----|---------|--------------|----------|-------------|
| IT-FIND-01 | find | `src/find.zig` | line ~3424 | **-ok test never fires** the primary; uses `-maxdepth 0` so no file is visited |
| IT-FIND-02 | find | `src/find.zig` | line ~3438 | **-execdir test doesn't verify cwd change**; only checks exit 0 |
| IT-FIND-03 | find | `src/find.zig` | lines 3032, 3042 | **-xdev/-x/-mount tests** don't verify cross-device filtering; only check exit 0 |
| IT-FIND-04 | find | `src/find.zig` | line ~3484 | **-fstype test is platform-specific** (apfs) and only checks exit 0; false green on Linux |
| IT-FIND-05 | find | `src/find.zig` | line ~3505 | **-flags test** only checks exit 0; filter behavior not verified |
| IT-FIND-06 | find | `src/find.zig` | (stubs) | **-regex/-iregex** documented as stubs in tests; SHOULD-tier primaries non-functional |
| IT-CP-01 | cp | `src/cp.zig` | lines 1910, 1933 | **--preserve/--preserve=mode** tests verify content not mode bits; attribute preservation not confirmed |
| IT-CP-02 | cp | `src/cp.zig` | line 2079 | **-f test has stale comment** describing bug that was partially fixed; different bug (hard-link path) still silently swallows errors |
| IT-CP-03 | cp | `src/cp.zig` | (no test) | **-i stdin prompt flow** (y/n) has zero behavioral test coverage |
| IT-CP-04 | cp | `src/cp.zig` | (no test) | **-x behavioral test** absent; parse-only stub only |
| IT-RM-01 | rm | `src/rm.zig` | (no test) | **-i has zero unit test coverage**: MUST-tier flag; prompt/cancel/force-override untested |
| IT-RM-02 | rm | `src/rm.zig` | (no test) | **-I has no behavioral test**: threshold logic (>3 files, recursive) never exercised |
| IT-RM-03 | rm | `src/rm.zig` | lines 703, 741 | **-v not tested via runRm**: both verbose tests bypass CLI and call `removeFiles` directly |
| IT-RM-04 | rm | `src/rm.zig` | (no standalone) | **-R only tested in combination** (-rf); standalone `-R` recursion path untested |
| IT-RM-05 | rm | `src/rm.zig` | line 816 | **--no-preserve-root is parse-only**: never verifies root guard is actually disabled |
| IT-LN-01 | ln | `src/ln.zig` | (no test) | **-v has zero behavioral tests**: correct arrow style (`->` vs `=>`) untested |
| IT-LN-02 | ln | `src/ln.zig` | (no test) | **-i interactive path** has zero behavioral tests |
| IT-LN-03 | ln | `src/ln.zig` | (no test) | **-t and -T** have zero behavioral tests |
| IT-LN-04 | ln | `src/ln.zig` | line 468 | **-F directory-removal branch** has zero behavioral tests |
| IT-MV-01 | mv | `src/mv.zig` | line 1044 | **-i hint test swallows error**: `catch {}` makes assertions unreliable |
| IT-MV-02 | mv | `src/mv.zig` | lines 1219–1247 | **4 parse-only stubs** for -b, --backup, -h, --help; behavioral tests already exist |
| IT-MV-03 | mv | `src/mv.zig` | lines 778–913 | **runUtility error paths** (no args, 1 arg, unknown flag, multi-to-non-dir) have zero unit tests |
| IT-MV-04 | mv | `src/mv.zig` | lines 644–648 | **Same-file detection** has no unit test; binary aborts at integration level |
| IT-MKDIR-01 | mkdir | `src/mkdir.zig` | lines 573–622 | **Tests 20/21 lock in wrong behavior**: assert mode on all intermediate dirs; contradicts GNU spec |
| IT-MKDIR-02 | mkdir | `src/mkdir.zig` | line 534 | **Test 18 is near-no-op**: only opens dir to confirm existence; no mode assertion |
| IT-TOUCH-01 | touch | `src/touch.zig` | (no test) | **-h flag has zero unit tests**: `AT_SYMLINK_NOFOLLOW` path never exercised |
| IT-TOUCH-02 | touch | `src/touch.zig` | lines 239–254 | **--time= aliases** `atime`, `use`, `mtime` untested; only `access` and `modify` covered |
| IT-TOUCH-03 | touch | `src/touch.zig` | line 73 | **runTouch error paths** (unknown flag, missing value, no operand) untested |
| IT-TOUCH-04 | touch | `src/touch.zig` | line 907 | **"-d flag is parsed by argparser"** is redundant parse-only test |
| IT-MKTEMP-01 | mktemp | `src/mktemp.zig` | line 208 | **-t flag has zero unit tests** |
| IT-MKTEMP-02 | mktemp | `src/mktemp.zig` | line 210 | **TMPDIR env var branch** never exercised in unit tests |
| IT-MKTEMP-03 | mktemp | `src/mktemp.zig` | lines 358–370 | **fillRandom test never compares buffers**: two buffers validated for charset but never compared |
| IT-MKTEMP-04 | mktemp | `src/mktemp.zig` | lines 622–636 | **generateTemp uniqueness test** never asserts `path1 != path2` |
| IT-MKTEMP-05 | mktemp | `src/mktemp.zig` | lines 434–454 | **Default-template path prefix not asserted**: regression to cwd would be invisible |

---

## 3. Cross-Cutting Themes (Shared Anti-Patterns)

### Theme A — Silent Stub Flags (Wrong Boolean Results)

**Pattern:** A flag is parsed and stored but the evaluation always returns a hardcoded wrong value (`true` or `false`) with no error, no warning, and no documentation that the feature is a stub.

**Affected utilities:**
- **find** (9 stubs): `-regex`/`-iregex` (always false), `-Bmin`/`-Bnewer`/`-Btime`/`-newerXY` (always true), `-printf` (prints path not format), `-s` (no-op, order unchanged), `-okdir` (always false)
- **touch**: `-A` (exits non-zero with "not implemented" — worse than silent: loud failure)
- **ln**: `-h`/`-n` (`no_dereference` stored but never read; field has zero call sites)
- **cp**: `-c` (clonefile no-op), `-X` (EA suppression no-op)

**Risk:** Silent wrong results are worse than errors. A user pipeline using `-Btime`, `-newerXY`, or `-regex` gets plausible-looking output that is completely wrong.

**Fix pattern:** For each stub:
1. Either implement it, or
2. Make it a hard error: `"flag X is not implemented on this platform"` + exit 1

---

### Theme B — Flag-Precedence (Last-Flag-Wins) Missing

**Pattern:** Mutually exclusive flags (`-f`/`-i`/`-n`) are stored as independent booleans. When multiple are given, precedence is decided by evaluation order in code, not parse order. All three POSIX/GNU specs require last-supplied flag wins.

**Affected utilities:**
- **rm** (I-RM-01): `-f` always wins over `-i`; `-fi` should be interactive, `-if` should be force
- **mv** (C-MV-03): Three-way mutex for `-f`/`-i`/`-n`; `-n -f` leaves no-clobber winning; `-f -i` skips prompt
- **ln**: `-b`/`-i` interaction (I-LN suggestion: backup bypasses interactive prompt even when `-i` given last)
- **cp**: Last-wins stubs (CT-CP-03) exist but they only test struct fields, not actual behavior

**Fix pattern:** Replace three separate booleans with a single enum:
```zig
const OverwriteMode = enum { default, force, interactive, no_clobber };
```
Track parse order; collapse to single value before passing to runtime.

---

### Theme C — Interactive Flags Broken or Untested

**Pattern:** `-i` (interactive) is either non-functional on the primary target platform (Linux) or is completely absent from unit tests.

**Affected utilities:**
- **mv** (C-MV-02): Interactive branch is inside `error.PathAlreadyExists` handler which `rename(2)` never raises on Linux; `-i` is completely non-functional
- **rm** (IT-RM-01): MUST-tier flag; zero unit tests for prompt/cancel/force-override
- **ln** (C-LN-02, IT-LN-02): 'y' response fails with `PathAlreadyExists`; zero behavioral unit tests
- **cp** (IT-CP-03): `-i` stdin injection (y/n) has zero behavioral tests

**Fix pattern (mv):** Check for destination existence BEFORE calling `rename()`, not inside the error handler. Mirror the `-n` check that already does this correctly.

---

### Theme D — Parse-Only / Cannot-Fail Tests

**Pattern:** Tests that assert struct field values (never call `runUtility`) or use assertions that are satisfied by the wrong value (e.g., `expect(sec > 0)`, `access()` where success silently passes the catch block).

**Scale of problem:**
- **cp**: 10 parse-only tests
- **ln**: 8 parse-only tests + 1 cannot-fail (-P test)
- **rm**: 5 parse-only tests
- **mv**: 4 parse-only tests + 1 cannot-fail ("directory move")
- **touch**: 2 parse-only tests + 2 cannot-fail (parseTimestamp, -t behavioral)
- **mktemp**: 2 cannot-fail (fillRandom, generateTemp)
- **find**: 5 acceptance-only tests (exit 0, no behavior verified)

**Total: ~32 tests that cannot catch regressions in the code they nominally cover.**

**Fix pattern:** For parse-only tests that have a behavioral equivalent, delete the parse-only test. For those without, add a `runUtility` call that exercises the real code path and asserts on filesystem state or output content.

---

### Theme E — Error Messages Don't Match GNU/POSIX Convention

**Pattern (a) — Missing "Try --help" hint:** GNU appends `"Try 'PROG --help' for more information."` to every error message. Missing project-wide.
- **basename** (I-BASENAME-01): `src/basename.zig:55–67`
- **dirname** (I-DIRNAME-01): `src/dirname.zig:35–46`
- Likely present in many other utilities (only these two were explicitly noted)

**Pattern (b) — Zig error tag names in output:** `error.FileNotFound` appears in user-visible messages instead of POSIX strings (`No such file or directory`).
- **mv** (I-MV-05): `src/mv.zig:724`
- **mkdir** (SUGGESTION): `src/mkdir.zig:197–208` — `errorToMessage` falls back to `@errorName`
- Likely present in other utilities

**Pattern (c) — Wrong error verb:** "unrecognized option" instead of GNU's "invalid option -- 'x'"
- **basename** and **dirname** both noted

---

### Theme F — Verbose Output Format Inconsistencies

**Pattern:** Verbose output either uses the wrong format, fires at the wrong time, or emits extra internal chatter not present in reference implementations.

**Affected utilities:**
- **mv** (I-MV-02): `-nv` prints `'src' -> 'dest'` even when move was skipped (no-clobber)
- **mv** (I-MV-03): Cross-filesystem move emits 4 extra internal lines; GNU emits only 1 line
- **mv** (I-MV-04): Uses GNU single-quote style; macOS reference uses no quotes
- **mv** (I-MV-01): Non-standard "hint" message emitted on stderr for every `-f` overwrite
- **ln** (I-LN-04): `-v` with `-r` shows original argument, not computed relative path
- **rm** (I-RM-03): `-d` verbose output gated on `any_errors` flag; successful removes not reported if any prior error occurred

**Common cause:** Verbose print is emitted by the caller after the operation function returns, without the operation function communicating whether an actual move/link/deletion occurred.

---

### Theme G — Time/Date Handling Bugs

**Pattern:** Multiple utilities have related timestamp calculation errors.

- **find** (I-FIND-01, I-FIND-02): `-mtime`/`-atime`/`-ctime`/`-mmin`/`-amin`/`-cmin` all use `@divTrunc` instead of ceiling division
- **find** (I-FIND-03): Time-unit suffixes (`smhdw`) not parsed
- **touch** (C-TOUCH-03): `-d` ignores timezone/TZ env var; Z and `+HH:MM` offset discarded
- **touch** (I-TOUCH-01): Both `-t` and `-d` reject SS=60 (valid leap second)
- **touch** (I-TOUCH-02): Pre-1970 timestamps rejected on 64-bit target where they are valid

**Shared root cause:** Timestamp arithmetic in `parseMtime` (find) and `parseTimestamp`/`parseIso8601` (touch) both lack proper ceiling division and timezone handling.

---

### Theme H — Ownership/Attribute Preservation Gaps

- **cp** (I-CP-02): `-p` never calls `chown`/`fchown`; uid/gid silently not preserved
- **cp** (I-CP-03): `-N` wired to symlink no-dereference mode instead of BSD file-flags suppression
- **cp** (I-CP-04): Special files (fifos, device nodes) not recreated under `-R`; returns error
- **mkdir** (I-MKDIR-02): `-p -m` applies mode to ALL intermediate directories; GNU spec: only leaf gets the `-m` mode

---

### Theme I — Backup Suffix Duplication

Both **cp** and **ln** implement backup suffix logic with the same hardcoded `~` default. Neither reads `SIMPLE_BACKUP_SUFFIX`:
- **ln** (I-LN-02): `src/ln.zig:459` — `"{s}~"` hardcoded
- **cp**: backup suffix via `-S` is implemented but only via flag; env var not checked

Both utilities also have partial `--backup=CONTROL` support or panicking behavior (ln panics on `TooManyValues`).

---

### Theme J — stdin tty Check Missing Before Prompts

**rm** (I-RM-02): `promptYesNo` called without first checking `std.posix.isatty(stdin)`. When stdin is a pipe, the prompt appears on stderr but reads EOF from stdin, causing the file to be treated as "not removed" and exit 1. POSIX specifies: prompt only when stdin is a terminal.

This is a risk in any utility that uses `common.prompt.promptYesNo`: the tty check belongs either in `promptYesNo` itself or consistently before every call site.

---

## 4. Findings That Relate to `src/common/` Modules

| Finding | Utility | Common Module Concern |
|---------|---------|----------------------|
| I-RM-02 — stdin tty check missing before prompt | rm | `common.prompt.promptYesNo` should either always check `isatty` internally, or its API should document that callers must check first. Currently no utility checks. |
| I-BASENAME-01, I-DIRNAME-01 — "Try --help" hint absent | basename, dirname | A common `printErrorWithUsageHint(prog_name, message)` wrapper would ensure all utilities include the hint consistently. |
| I-LN-02, cp backup suffix — `SIMPLE_BACKUP_SUFFIX` ignored | ln, cp | Backup suffix resolution (env var + flag + default) should live in `src/common/backup.zig` and be shared. |
| I-MV-05, mkdir SUGGESTION — Zig error names in output | mv, mkdir | `common.errorToMessage` (or equivalent) is either missing or incomplete; utilities fall back to `@errorName`. A complete mapping in common would fix this project-wide. |
| Theme B — Last-flag-wins for -f/-i/-n | rm, mv, ln | The `OverwriteMode` enum pattern (or a `resolveOverwriteMode` helper) could live in `src/common/` so all three utilities share the same precedence logic. |
| I-FIND-01/02 — Ceiling division for time periods | find | `std.math.divCeil` (or a `ceilDiv` helper) should replace `@divTrunc` wherever period-based time matching is done. |
| C-TOUCH-03 — Timezone handling in ISO 8601 | touch | A `parseIso8601WithTZ` helper in `src/common/time.zig` would prevent this class of bug appearing in other utilities. |
| IT-TOUCH-01 / C-TOUCH-02 — `-t`/`-d` share duplicated validation | touch | `validateAndConvertToTimespec(year, month, day, hour, minute, second)` extracted to common would remove the parallel duplicated range checks. |
| IT-RM-01 — -i flag zero tests; common.prompt testing helper | rm | If `common.prompt` exposes a testing seam (reader injection), `-i` tests become straightforward across all utilities. |

---

## 5. Duplicate Code / Logic That Could Be Shared

### 5.1 Backup Suffix Logic
**Duplicated in:** `src/ln.zig`, `src/cp.zig`  
**What to share:**  
```zig
// src/common/backup.zig
pub fn resolveBackupSuffix(flag_suffix: ?[]const u8) []const u8 {
    if (flag_suffix) |s| return s;
    return std.posix.getenv("SIMPLE_BACKUP_SUFFIX") orelse "~";
}

pub fn makeBackupPath(allocator, path, suffix) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{path, suffix});
}
```

### 5.2 Overwrite Mode Precedence
**Duplicated in:** `src/rm.zig`, `src/mv.zig`, `src/ln.zig`, `src/cp.zig`  
**What to share:**  
```zig
// src/common/overwrite_mode.zig
pub const OverwriteMode = enum { default, force, interactive, no_clobber };

pub fn resolveOverwriteMode(
    force: bool, interactive: bool, no_clobber: bool,
    // order: index of last flag in argv, e.g. via parse tracking
) OverwriteMode { ... }
```

### 5.3 stdin tty Guard for Prompts
**Affected:** `src/rm.zig` (confirmed), likely `src/mv.zig`, `src/ln.zig`, `src/cp.zig`  
**What to share:** Move `isatty` check into `common.prompt.promptYesNo`:
```zig
// src/common/prompt.zig
pub fn promptYesNo(writer, fmt, args) !bool {
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) return true; // non-interactive: proceed
    ...
}
```
(Or expose a `promptYesNoIfTty` variant that auto-skips on non-tty stdin.)

### 5.4 Error-to-POSIX-String Mapping
**Affected:** `src/mv.zig`, `src/mkdir.zig`, likely others  
**What to share:** A complete `common.errorToMessage(err: anyerror) []const u8` that handles all common POSIX errors (`FileNotFound` → `"No such file or directory"`, `AccessDenied` → `"Permission denied"`, `SymLinkLoop` → `"Too many levels of symbolic links"`, etc.) rather than falling back to `@errorName`.

### 5.5 Timestamp Parsing Validation
**Duplicated in:** `src/touch.zig` (`parseTimestamp` and `parseIso8601` share identical range checks)  
**Internal to touch:** Extract `validateDateComponents(year, month, day, hour, minute, second) !Timespec` helper.  
**Potentially shared:** Any future utility needing timestamp parsing (e.g., `date`) should use `src/common/time.zig`.

### 5.6 "Try --help" Error Hint
**Affected:** All utilities (basename and dirname confirmed missing; likely universal gap)  
**What to share:** Add to `common.printErrorWithProgram` or create `common.printErrorWithHint`:
```zig
pub fn printErrorWithHint(writer, prog, fmt, args) !void {
    try printErrorWithProgram(writer, prog, fmt, args);
    try writer.print("Try '{s} --help' for more information.\n", .{prog});
}
```

### 5.7 Ceiling Division for Time Period Matching
**Duplicated in:** `src/find.zig` (6 call sites with `@divTrunc`)  
**What to share:**
```zig
// src/common/math.zig (or inline in find.zig)
pub fn ceilDivU64(a: u64, b: u64) u64 {
    return (a + b - 1) / b;
}
```

---

## Summary Statistics

| Category | Count |
|----------|-------|
| CRITICAL behavioral findings | 22 |
| CRITICAL test quality findings | 17 |
| IMPORTANT behavioral findings | 37 |
| IMPORTANT test quality findings | 35 |
| Cross-cutting themes identified | 10 |
| `src/common/` improvement opportunities | 9 |
| Shared logic extraction opportunities | 7 |
| **Total findings** | **~111** |

### By Utility (behavioral only)

| Utility | CRITICAL | IMPORTANT |
|---------|----------|-----------|
| find | 9 | 11 |
| cp | 0 | 5 |
| rm | 1 | 3 |
| ln | 2 | 4 |
| mv | 3 | 5 |
| mkdir | 0 | 2 |
| touch | 3 | 3 |
| basename | 1 | 1 |
| dirname | 0 | 1 |
| mktemp | 3 | 2 |
| **Total** | **22** | **37** |

### Utilities by Status

| Status | Utilities |
|--------|-----------|
| BLOCKED | mv (crash + -i non-functional on Linux) |
| NEEDS_FIXES (CRITICAL) | find, rm, ln, touch, basename, mktemp |
| NEEDS_FIXES (IMPORTANT only) | cp, mkdir, dirname |
| APPROVED with minor issues | dirname (1 IMPORTANT, no behavioral regressions) |
