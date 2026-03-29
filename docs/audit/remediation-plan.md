# Remediation Plan

**Date:** 2026-03-28
**Scope:** All 141 audit reports for 47 utilities

CRITICAL findings are grouped by category below, followed by IMPORTANT
findings. Each entry lists: utility, flag/feature, location, one-line
description, and source report file.

---

## CRITICAL Findings

### Category: Silent Stubs (parsed flag has no effect)

| Utility | Flag/Feature | Location | Description | Source |
|---------|-------------|----------|-------------|--------|
| find | `-regex`/`-iregex` | `src/find.zig` | Always returns false; no path ever matches | find-code.md |
| find | `-Bmin`/`-Bnewer`/`-Btime`/`-newerXY` | `src/find.zig` | Always returns true; birth-time predicates unimplemented | find-code.md |
| find | `-printf` | `src/find.zig` | Format string ignored; prints a fixed placeholder | find-code.md |
| find | `-s` (stable order) | `src/find.zig` | Parsed; filesystem-stable ordering not implemented | find-code.md |
| find | `-perm +/-mode` | `src/find.zig` | Permission prefix forms rejected; only exact match works | find-code.md |
| find | `-exec {} +` | `src/find.zig` | Collected-args form crashes with unimplemented error | find-code.md |
| find | `-execdir {} +` | `src/find.zig` | Collected-args form crashes with unimplemented error | find-code.md |
| env | bare `-` | `src/env.zig` | Single dash should clear environment; is a no-op | env-code.md |
| env | `-S` | `src/env.zig` | Shell-split string option: completely unimplemented stub | env-code.md |
| sort | `-V` | `src/sort.zig` | Mapped to `--version` flag instead of version sort | sort-code.md |
| tr | `[c*]`/`[c*0]` | `src/tr.zig` | Fill-to-SET1-length produces empty set; translation silently wrong | tr-code.md |
| tac | `-b`/`--before` | `src/tac.zig` | Separator placement algorithm is wrong; unit tests assert wrong expected values | tac-code.md |
| stat | `%r`/`%R` | `src/stat.zig` | Raw device number fields not implemented | stat-code.md |
| ln | `-h`/`-n` | `src/ln.zig` | No-dereference flag stored but never applied | ln-code.md |
| mktemp | bare template | `src/mktemp.zig` | Bare template should create in cwd; instead goes to /tmp | mktemp-code.md |
| mktemp | `-t` with slash | `src/mktemp.zig` | `-t` accepts slash in template name; should be rejected | mktemp-code.md |

### Category: Wrong Algorithm / Incorrect Behavior

| Utility | Flag/Feature | Location | Description | Source |
|---------|-------------|----------|-------------|--------|
| stat | `+` sign on numbers | `src/stat.zig` | Spurious `+` prefix on all numeric format fields | stat-code.md |
| stat | `macOS StatFs` on Linux | `src/stat.zig` | macOS `StatFs` struct used for Linux filesystem stats; wrong field offsets | stat-code.md |
| stat | `-f` ignores `-c` | `src/stat.zig` | Filesystem mode (`-f`) ignores custom format (`-c`/`--format`) | stat-code.md |
| stat | terse wrong fields | `src/stat.zig` | Terse output has wrong field count and order (14 vs GNU 16) | stat-code.md |
| df | `-I` wrong semantic | `src/df.zig` | `-I` is suppress-inodes (macOS) not type-filter (GNU); wrong on Linux | df-code.md |
| df | `-P` wrong headers | `src/df.zig` | POSIX format headers wrong (wrong column names/order) | df-code.md |
| df | `-n` stub | `src/df.zig` | Darwin NOWAIT flag applied unconditionally; `-n` is a no-op on Linux | df-code.md |
| du | `-L` double-counts | `src/du.zig` | Symlink-follow counts symlink target size multiple times | du-code.md |
| du | `-A`/`-b` dir size | `src/du.zig` | Directory apparent size uses block size not recursive content size | du-code.md |
| du | `-S` wrong | `src/du.zig` | Excludes subdirectory content via inode-only path (wrong semantics) | du-code.md |
| sort | `-h` wrong algorithm | `src/sort.zig` | Human-numeric comparison algorithm incorrect | sort-code.md |
| sort | `-s` no-op | `src/sort.zig` | Stable sort flag is a no-op; last-resort comparison missing | sort-code.md |
| grep | `-x` BRE broken | `src/grep.zig` | `-x` in BRE mode uses ERE group syntax; whole-line anchoring broken | grep-code.md |
| grep | `-o` first match only | `src/grep.zig` | `-o` prints only first match per line; should print all matches | grep-code.md |
| wc | `-c`/`-m` exclusion | `src/wc.zig` | Mutual exclusion inverted: when both given, wrong flag wins | wc-code.md |
| wc | `-L` bytes not columns | `src/wc.zig` | Counts raw bytes not display columns; tabs and CJK produce wrong values | wc-code.md |
| printf | `\NNN` octal | `src/printf.zig` | Octal escape in format string `\NNN` not recognized | printf-code.md |
| printf | `%b` octal | `src/printf.zig` | `%b` operand `\0NNN` has off-by-one in octal parsing | printf-code.md |
| printf | `\c` not handled | `src/printf.zig` | `\c` in format string does not halt output as POSIX requires | printf-code.md |
| printf | `%b` `\c` no halt | `src/printf.zig` | `\c` inside `%b` operand does not halt reuse loop | printf-code.md |
| printf | `%F`/`%a`/`%A` missing | `src/printf.zig` | Three format specifiers entirely unimplemented | printf-code.md |
| mv | `-i` dead on Linux | `src/mv.zig` | Interactive prompt code path is dead on Linux; never prompts | mv-code.md |
| mv | panic on EINVAL | `src/mv.zig` | Moving directory into its own subdirectory panics instead of clean error | mv-code.md |
| mv | flag precedence | `src/mv.zig` | `-f`/`-i`/`-n` flag precedence broken when all three given | mv-code.md |
| nl | section reset | `src/nl.zig` | Section delimiter resets line counter only on header section, not footer | nl-code.md |
| nl | unnumbered separator | `src/nl.zig` | Unnumbered lines use separator string instead of spaces per POSIX | nl-code.md |
| nl | blank line output | `src/nl.zig` | Skipped blank lines output bare newline without indent | nl-code.md |
| nl | pBRE unimplemented | `src/nl.zig` | `-b p:RE` body numbering with POSIX BRE is unimplemented | nl-code.md |
| nl | `-d ''` error | `src/nl.zig` | Empty delimiter string rejected; should be valid | nl-code.md |
| readlink | `-f` all must exist | `src/readlink.zig` | Requires all path components to exist; GNU allows last component missing | readlink-code.md |
| readlink | dangling `-f` | `src/readlink.zig` | Dangling symlink with `-f` exits 1; GNU exits 0 | readlink-code.md |
| realpath | default is `-e` | `src/realpath.zig` | Default mode uses strict-existence semantics; should use `-E` (lenient) | realpath-code.md |
| id | `-G` named user | `src/id.zig` | With named user, `-G` shows only primary GID; should call `getgrouplist` | id-code.md |
| head | crash on error | `src/head.zig` | `IsDir` and `ReadFailed` errors print stack trace instead of clean error | head-code.md |
| ls | exit always 0 | `src/ls/main.zig` | Exit code always 0; GNU requires 2 for inaccessible args, 1 for minor errors | ls-code.md |
| ls | `-a` missing `.`/`..` | `src/ls` | `-a` behaves like `-A`; `.` and `..` entries never shown | ls-integration-tests.md |
| basename | empty string | `src/basename.zig` | Empty string returns `"."` instead of `""` per GNU | basename-code.md |
| touch | `-A` stub | `src/touch.zig` | `-A` (adjust time) completely unimplemented; exits with error | touch-code.md |
| touch | `-d` ignores TZ | `src/touch.zig` | `-d` date string ignores timezone offset and `Z` suffix | touch-code.md |

### Category: Crashes / Memory Safety

| Utility | Flag/Feature | Location | Description | Source |
|---------|-------------|----------|-------------|--------|
| find | `-size` | `src/find.zig` | Block-size rounding uses wrong unit (bytes not 512-byte blocks) | find-code.md |
| tail | OOM on large `-c` | `src/tail.zig:735` | `processInputByBytesNoSeek` allocates full `byte_count` bytes; `tail -c 10G` OOMs | tail-code.md |
| uniq | `--all-repeated=METHOD` | `src/uniq.zig` | With `=none`/`=prepend`/`=separate` suffix, crashes with Zig stack trace | uniq-code.md |
| ln | `--backup=CONTROL` | `src/ln.zig` | `--backup=CONTROL` panics | ln-code.md |
| rm | `-W` | `src/rm.zig` | `-W` supposed to undelete whiteout files; instead deletes regular files (dangerous) | rm-code.md |

### Category: False-Green Tests (tests pass but assert wrong behavior)

| Utility | Flag/Feature | Location | Description | Source |
|---------|-------------|----------|-------------|--------|
| chmod | 49 parse-only stubs | `src/chmod.zig` | 49 unit tests inspect parsed struct fields only; no behavior verified | chmod-unit-tests.md |
| cp | 10 parse-only stubs | `src/cp.zig` | 10 unit tests are parse-only; flag behavior untested | cp-unit-tests.md |
| chown | 8 cannot-fail stubs | `src/chown.zig` | 8 unit tests assert on struct fields that cannot change; no behavior verified | chown-unit-tests.md |
| env | lone dash untested | `src/env.zig` | Lone dash unimplemented and untested; tests only cover implemented paths | env-unit-tests.md |
| timeout | preserve-status skip | `src/timeout.zig:570` | `--preserve-status` test skipped on Linux CI; masks live production bug | timeout-unit-tests.md |
| timeout | command-not-found | `src/timeout.zig:547` | Test accepts any non-zero exit for command-not-found; should assert 127 | timeout-unit-tests.md |
| ls | `-a` test hides bug | `tests/utilities/ls_test.sh:117` | Test validates incorrect behavior (`.`/`..` absent) and masks BUG-1 | ls-integration-tests.md |
| ls | nonexistent exit 0 | `tests/utilities/ls_test.sh:283` | Test deliberately skips exit-code check; encodes known wrong behavior | ls-integration-tests.md |
| stat | cannot-fail tests | `src/stat.zig` | Tests for `%a` octal, `%U` name, and timestamps are cannot-fail | stat-unit-tests.md |
| touch | parseTimestamp | `src/touch.zig:753` | Tests only check `sec > 0`; wrong epoch values cannot be caught | touch-unit-tests.md |
| touch | `-t` no value check | `src/touch.zig:856` | `-t` test only checks `mtime > 0`; wrong timestamp silently passes | touch-unit-tests.md |
| tee | dash-operand tests | `src/tee.zig:451` | Tests assert doubled output; GNU produces single copy (both wrong) | tee-unit-tests.md |
| tee | dash guard | `tests/utilities/tee_test.sh:81` | Guard checks `! -f ./` (always true); never actually validates dash behavior | tee-integration-tests.md |
| uniq | stale FAIL comment | `src/uniq.zig:782` | Stale comment says test will fail; test actually passes; misleads reviewers | uniq-unit-tests.md |
| find | `-exec` silent | `tests/utilities/find_test.sh` | `-exec` silently broken; integration test does not catch it | find-integration-tests.md |
| seq | `-f` zero tests | `tests/utilities/seq_test.sh` | `-f` format has zero integration tests despite being a MUST flag | seq-integration-tests.md |
| echo | `\c` zero tests | `tests/utilities/echo_test.sh` | `\c` (halt output) has zero integration tests | echo-integration-tests.md |
| tail | stdin paths | `src/tail.zig` | `processInputByLines` and `processInputByBytesNoSeek` have zero unit tests | tail-unit-tests.md |
| tr | `-C` untested | `src/tr.zig` | `-C` complement flag has no behavioral test; could be dropped silently | tr-unit-tests.md |
| date | false behavioral | `src/date.zig` | Two unit tests claim to test `-z`/`-f` but only check exit code, masking stubs | date-unit-tests.md |
| printf | exit-code stubs | `src/printf.zig` | Three unit tests check exit code 0 for format specifiers that produce wrong output | printf-unit-tests.md |
| wc | column-width | `tests/utilities/wc_test.sh` | Fixed 8-char column format untested for 9-digit counts; would silently truncate | wc-integration-tests.md |
| wc | `-L` tab/CJK | `tests/utilities/wc_test.sh` | `-L` tab and CJK display-width untested; raw-byte counting bug undetected | wc-integration-tests.md |
| stat | terse wrong | `tests/utilities/stat_test.sh` | Terse output field count wrong; integration test coverage weak | stat-integration-tests.md |
| nl | `-b`/`-f`/`-h` | `tests/utilities/nl_test.sh` | `-b p:RE` unimplemented; `-h`/`-f` have zero behavioral integration tests | nl-integration-tests.md |
| cat | `-e` strips `$` | `tests/utilities/cat_test.sh` | Test captures with command substitution which strips trailing `$`; cannot detect bug | cat-unit-tests.md |
| df | `--output` stub | `src/df.zig` | `--output` field selection is a stub; unit test checks exit code only | df-unit-tests.md |

---

## IMPORTANT Findings

### Category: Missing Flag Implementations

| Utility | Flag/Feature | Location | Description | Source |
|---------|-------------|----------|-------------|--------|
| cp | `-f` unlinks | `src/cp.zig` | `-f` unlinks destination unconditionally even when not needed | cp-code.md |
| cp | `-p` no chown | `src/cp.zig` | `-p` preserve does not call `chown`; ownership not preserved | cp-code.md |
| cp | special files in `-R` | `src/cp.zig` | Special files (device, socket, FIFO) produce error in recursive copy | cp-code.md |
| chown | `user:` login group | `src/chown.zig` | `user:` syntax should set group to user's login group; leaves group unchanged | chown-code.md |
| chown | `-RP` symlink | `src/chown.zig` | `-RP` follows command-line symlink to directory; violates `-P` semantics | chown-code.md |
| date | `-r` numeric | `src/date.zig` | `-r N` with numeric timestamp broken; parses as filename | date-code.md |
| date | `-d` TZ offset | `src/date.zig` | `-d` date string ignores timezone offset component | date-code.md |
| date | conflict detection | `src/date.zig` | `-d`/`-r`/`-f` can be given simultaneously; no conflict error | date-code.md |
| dd | `conv=sync` | `src/dd.zig` | `conv=sync` (pad input blocks) not implemented | dd-code.md |
| dd | `conv=notrunc` | `src/dd.zig` | `conv=notrunc` (no output truncation) not implemented | dd-code.md |
| dd | `conv=ibm` | `src/dd.zig` | `conv=ibm` (EBCDIC variant) not implemented | dd-code.md |
| df | `-t` multi-flag | `src/df.zig` | Multiple `-t` type filters overwrite each other; only last applies | df-code.md |
| du | `-n` wrong | `src/du.zig` | `-n` (no newline) has wrong semantic; affects only total line | du-code.md |
| env | fork vs execve | `src/env.zig` | Uses fork+exec instead of execve; child PID differs from expected | env-code.md |
| env | flags after `NAME=VALUE` | `src/env.zig` | Flags after `NAME=VALUE` pairs not recognized | env-code.md |
| env | `-P` sets PATH | `src/env.zig` | `-P` should restrict PATH for child; sets it in wrong place | env-code.md |
| find | `-size` units | `src/find.zig` | `-size N` (no suffix) should count 512-byte blocks; counts bytes instead | find-code.md |
| find | `-exec` single | `src/find.zig` | `-exec cmd {} ;` form has bugs in argument passing | find-code.md |
| free | `-w` buffers col | `src/free.zig` | Wide mode `-w` always shows 0 for buffers column | free-code.md |
| free | `-c` without `-s` | `src/free.zig` | `-c N` without `-s` silently displays once; GNU rejects with error | free-code.md |
| grep | `-w` zero coverage | `src/grep.zig` | `-w` (whole-word) has zero tests anywhere; behavioral correctness unknown | grep-code.md |
| head | `--silent` broken | `src/head.zig` | `--silent` long alias for `-q` not recognized | head-code.md |
| id | `-z` alone | `src/id.zig` | `-z` alone accepted; GNU rejects without format flag | id-integration-tests.md |
| ln | `-i` no delete | `src/ln.zig` | `-i` interactive prompt accepts `y` but does not remove existing target | ln-code.md |
| ln | `--backup` suffix | `src/ln.zig` | `-b` ignores `SIMPLE_BACKUP_SUFFIX` environment variable | ln-code.md |
| ln | `-vr` wrong target | `src/ln.zig` | `-vr` verbose message shows wrong target path | ln-code.md |
| ls | `-n` implies `-l` | `src/ls/main.zig` | `-n` should force long format; currently produces multi-column output | ls-code.md |
| ls | `-s` with `-l` | `src/ls/main.zig` | `-s -l` missing per-entry block count column | ls-code.md |
| ls | multi-operand headers | `src/ls/main.zig` | Non-directory operands get `filename:` header; should print bare | ls-code.md |
| ls | error messages | `src/ls/main.zig` | Zig error names printed instead of POSIX strings | ls-code.md |
| mkdir | `-m` symbolic modes | `src/mkdir.zig` | Symbolic mode strings rejected; only octal modes accepted | mkdir-code.md |
| mkdir | `-pm` intermediates | `src/mkdir.zig` | `-p -m` applies mode to all intermediate dirs; GNU applies to leaf only | mkdir-code.md |
| mktemp | implicit suffix | `src/mktemp.zig` | Template without `XXX` suffix should be rejected; silently accepted | mktemp-code.md |
| mv | same-file | `src/mv.zig` | Same-file move should exit 0 cleanly; currently aborts with error | mv-code.md |
| nl | `-d ''` | `src/nl.zig` | Empty delimiter string rejected; should default to disabled | nl-code.md |
| printf | `%d` float | `src/printf.zig` | `%d` with float argument produces wrong output | printf-code.md |
| printf | `\NNN` in `%b` | `src/printf.zig` | `\NNN` octal in `%b` operand off-by-one | printf-code.md |
| realpath | error strings | `src/realpath.zig` | Uses `@errorName` (Zig symbols) instead of POSIX error strings | realpath-code.md |
| rmdir | `-v --ignore-fail` | `src/rmdir.zig` | `--ignore-fail-on-non-empty` suppresses verbose output; GNU still prints | rmdir-code.md |
| seq | negative increment | `src/seq.zig` | Negative increment without `--` rejected by flag parser | seq-code.md |
| seq | exit code | `src/seq.zig` | Exits 2 for errors; GNU exits 1 | seq-code.md |
| sleep | error token | `src/sleep.zig` | Error message omits the invalid token (e.g., `'badval'`) | sleep-code.md |
| sleep | `inf`/`infinity` | `src/common/time.zig` | GNU accepts these for indefinite sleep; vibeutils rejects | sleep-code.md |
| stat | device format | `src/stat.zig` | Device shown as BSD `major,minor` format; GNU uses single decimal | stat-code.md |
| tac | `-b` multi-byte | `src/tac.zig` | `-b` with multi-byte separator places separator on wrong side | tac-code.md |
| tee | write errors | `src/tee.zig` | Default mode silently swallows write errors; GNU always reports | tee-code.md |
| tee | `-p` pipe exit | `src/tee.zig` | `-p` does not correctly implement pipe-exit semantics | tee-code.md |
| tee | error filenames | `src/tee.zig` | Error messages do not include the filename | tee-code.md |
| timeout | setpgid race | `src/timeout.zig:287` | `setpgid` called after spawn; race means signals may not reach child | timeout-code.md |
| touch | `-h` no-create | `src/touch.zig` | `-h --no-create` does not correctly skip missing symlinks | touch-code.md |
| tr | extra operands | `src/tr.zig` | Extra operands beyond SET1 SET2 are silently ignored; should error | tr-code.md |
| yes | unknown flag exit | `src/yes.zig:33` | Unknown flag exits 2; GNU exits 1 | yes-code.md |
| yes | error message | `src/yes.zig:32` | Error message omits flag name and "Try --help" hint | yes-code.md |

### Category: Test Coverage Gaps (MUST/SHOULD tier flags with zero tests)

| Utility | Flag/Feature | Location | Description | Source |
|---------|-------------|----------|-------------|--------|
| chmod | `-H`/`-L`/`-P` | `src/chmod.zig` | MUST-tier recursive symlink traversal flags have zero behavioral tests | chmod-unit-tests.md |
| chown | `-H`/`-L`/`-P` | `src/chown.zig` | MUST-tier recursive symlink traversal flags have zero behavioral tests | chown-unit-tests.md |
| cp | `--preserve` | `src/cp.zig` | `--preserve` tests do not check that modes are actually preserved | cp-unit-tests.md |
| cut | `-w`/`-z` | `tests/utilities/cut_test.sh` | Both SHOULD flags have zero integration tests | cut-integration-tests.md |
| date | `-r`/`-j`/`-R`/`-I`/`-d` | `tests/utilities/date_test.sh` | Multiple MUST/SHOULD flags entirely untested | date-integration-tests.md |
| dd | `conv=` values | `tests/utilities/dd_test.sh` | 11 MUST-tier `conv=` values untested | dd-integration-tests.md |
| df | `-k`/`-l`/`-t`/`-n` | `tests/utilities/df_test.sh` | All four MUST flags have zero integration tests | df-integration-tests.md |
| du | `-H`/`-k`/`-L`/`-x`/`-P`/`-r` | `tests/utilities/du_test.sh` | All MUST flags have zero integration tests | du-integration-tests.md |
| find | `-user`/`-group`/`-nogroup` | `src/find.zig` | Ownership predicates have no unit tests | find-unit-tests.md |
| grep | `-w` | `src/grep.zig` | `-w` (whole-word) has zero unit and integration tests | grep-code.md |
| head | `-z` | `tests/utilities/head_test.sh` | `-z` NUL-terminated has zero integration tests | head-integration-tests.md |
| id | `-r`/`-p`/`-F`/`-P`/`-Gn` | `tests/utilities/id_test.sh` | All MUST/SHOULD flags have zero integration tests | id-integration-tests.md |
| ln | `-i`/`-w`/`-F`/`-r`/`-t`/`-T` | `tests/utilities/ln_test.sh` | All SHOULD flags have zero integration tests | ln-integration-tests.md |
| ls | 27 flags missing | `tests/utilities/ls_test.sh` | 27 of 45 MUST/SHOULD/KEEP flags have no behavioral integration test | ls-integration-tests.md |
| mv | `-h`/`-b`/`--backup` | `tests/utilities/mv_test.sh` | `-h` and backup flags have no integration tests | mv-integration-tests.md |
| nl | `-f`/`-p`/`-d`/`-l` | `tests/utilities/nl_test.sh` | Multiple MUST flags untested or tested only with weak grep | nl-integration-tests.md |
| printf | 12+ specifiers | `tests/utilities/printf_test.sh` | `%F`/`%a`/`%A`/`%E`/`%G` and others have zero integration tests | printf-integration-tests.md |
| rm | `-d`/`-P`/`-x`/`-W` | `tests/utilities/rm_test.sh` | All SHOULD/KEEP flags have zero integration tests | rm-integration-tests.md |
| seq | countdown/floats/`-f` | `tests/utilities/seq_test.sh` | Countdown, float, and format string cases have zero integration tests | seq-integration-tests.md |
| sort | `-V` broken | `tests/utilities/sort_test.sh` | `-V` is broken (acts as `--version`) with no integration test catching it | sort-integration-tests.md |
| stat | terse/`-f`/`--printf` | `tests/utilities/stat_test.sh` | 22 of 26 format directives untested | stat-integration-tests.md |
| tail | `-b`/`-r` | `tests/utilities/tail_test.sh` | Both MUST-tier flags have zero integration tests | tail-integration-tests.md |
| test/[ | file primaries | `tests/utilities/test_test.sh` | 10 MUST file primaries (`-r`/`-w`/`-x` etc.) untested | test-integration-tests.md |
| timeout | `--kill-after`/`--verbose`/`--foreground` | `tests/utilities/timeout_test.sh` | All three have zero integration tests | timeout-integration-tests.md |
| touch | `-t` value | `tests/utilities/touch_test.sh` | `-t` format tests verify only exit code, not resulting timestamp | touch-integration-tests.md |
| tr | `[x*N]` regression | `tests/utilities/tr_test.sh` | Working form `[x*N]` has no regression test; could be broken by fixing `[x*]` | tr-integration-tests.md |
| uniq | `-z` | `tests/utilities/uniq_test.sh` | `-z` NUL-terminated has zero integration tests | uniq-integration-tests.md |
| wc | `-m`/`-L` | `tests/utilities/wc_test.sh` | Unicode character count and tab/CJK display width untested | wc-integration-tests.md |
