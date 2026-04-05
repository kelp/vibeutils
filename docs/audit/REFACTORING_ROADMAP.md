# Vibeutils Consolidated Refactoring Roadmap

**Date:** 2026-04-04
**Source:** Cross-referencing 4 independent section audits (A–D), 141 per-utility reports
**Codebase:** 72.8K lines of Zig, 47 utilities, 2222 test blocks, 26 common modules

---

## Executive Summary

The four audits independently converged on **six systemic problems** that cut across
the entire codebase. Fixing these at the library level would resolve findings in
30+ utilities simultaneously. The audits found **209 CRITICAL** and **574 IMPORTANT**
issues, but approximately 60% trace back to just these six root causes.

**Highest-leverage changes (fix once, benefit everywhere):**
1. `@errorName` → POSIX error strings (108 call sites across 30+ files)
2. `canonicalizeParentMustExist` in `path.zig` (fixes readlink + realpath simultaneously)
3. Shared `OverwriteMode` for `-f`/`-i`/`-n` flag precedence (cp, mv, rm, ln)
4. `promptYesNo` with `isatty` guard (cp, mv, rm)
5. Exit code 2→1 convention fix for value errors (8+ utilities)
6. `argparse.zig` flag-name payload (enables proper error messages in 20+ utilities)

---

## Part 1: Prioritized Refactoring Tasks by Theme

### Theme A: Common Library — Error Infrastructure [FOUNDATION]
**Confidence: ★★★★★** (independently found by all 4 auditors)

| # | Task | Files Affected | Line Impact | Priority |
|---|------|---------------|-------------|----------|
| A1 | **Add `posixErrorString(err) []const u8` to `common/lib.zig`** — Map Zig errors to POSIX strings: `FileNotFound→"No such file or directory"`, `AccessDenied→"Permission denied"`, `IsDir→"Is a directory"`, etc. | `src/common/lib.zig` (new fn, ~30 lines) | +30 | P0 |
| A2 | **Replace all 108 `@errorName(err)` call sites** with `common.posixErrorString(err)` in production code paths (not tests). | 30+ files in `src/` | ~108 lines changed | P0 |
| A3 | **Add "Try --help" bare hint function** — `pub fn printTryHelp(writer, prog_name)` that prints `"Try 'prog --help' for more information."` on its own line, matching GNU format exactly. | `src/common/lib.zig` (+10 lines) | +10, then ~40 call sites | P1 |
| A4 | **Fix `ExitCode.misuse` usage** — Reserve exit 2 for genuine flag-syntax errors. Value errors (bad number, invalid time, etc.) should use exit 1. | `src/sleep.zig`, `src/seq.zig`, `src/yes.zig`, `src/whoami.zig`, `src/date.zig`, `src/free.zig`, `src/dd.zig`, `src/printf.zig` | ~15 lines each, 8 files | P1 |

### Theme B: Common Library — Argument Parsing [FOUNDATION]
**Confidence: ★★★★☆** (found by sections A, B, D; verified in codebase)

| # | Task | Files Affected | Line Impact | Priority |
|---|------|---------------|-------------|----------|
| B1 | **Add flag-name payload to `ParseError.UnknownFlag`** or add post-parse "find bad flag" helper. Currently 20+ utilities print `"unrecognized option"` without naming the offending flag. | `src/common/argparse.zig` | ~20 lines | P1 |
| B2 | **Fix auto-derived short flag collision** — `getShortFlag("si")→'s'` collides with `--seconds/-s` in `free`. Add explicit `short = 0` suppression where names collide, or suppress auto-derivation when conflict exists. | `src/common/argparse.zig`, `src/free.zig` | ~10 lines | P0 |
| B3 | **Add POSIX "stop-at-first-positional" mode** — After the first positional arg, stop scanning for flags. Needed by `env` (flags after `NAME=VALUE`). | `src/common/argparse.zig` | ~30 lines | P2 |
| B4 | **Add `--flag[=value]` optional-value syntax** — `--all-repeated=METHOD` currently crashes `uniq` with unhandled `TooManyValues`. | `src/common/argparse.zig` | ~40 lines | P1 |

### Theme C: Common Library — Path Resolution [FOUNDATION]
**Confidence: ★★★★★** (independently found by sections A, D; same root cause)

| # | Task | Files Affected | Line Impact | Priority |
|---|------|---------------|-------------|----------|
| C1 | **Add `canonicalizeParentMustExist(allocator, path)` to `path.zig`** — Resolve parent via `realpathAlloc`, append basename. This is the `-f` / default realpath semantic ("all-but-last must exist"). | `src/common/path.zig` | +20 lines | P0 |
| C2 | **Fix `readlink -f` to use new function** — Replace strict `realpathAlloc` with `canonicalizeParentMustExist` for the `-f` mode. | `src/readlink.zig:151-165` | ~10 lines | P0 |
| C3 | **Fix `realpath` default mode** — Default should be `-E` (all-but-last-exist), not `-e` (strict). Use `canonicalizeParentMustExist`. | `src/realpath.zig:124-132` | ~15 lines | P0 |
| C4 | **Fix tests that assert wrong behavior** — `readlink.zig:580-598` and `realpath.zig:382-391` and `realpath_test.sh:52` currently encode the bug as expected. Must flip after C2/C3. | 3 test locations | ~10 lines | P0 |

### Theme D: Common Library — Shared Utilities [HIGH VALUE]
**Confidence: ★★★★☆** (independently found by sections A, B)

| # | Task | Files Affected | Line Impact | Priority |
|---|------|---------------|-------------|----------|
| D1 | **Add `isatty` guard to `promptYesNo`** — Currently prompts into pipes and `/dev/null`. Default to `false` (no prompt) when stdin is not a TTY. | `src/common/prompt.zig` | +5 lines | P0 |
| D2 | **Create `common/overwrite.zig` — shared `OverwriteMode` enum** with last-flag-wins resolver for `-f`/`-i`/`-n`. cp, mv, rm, ln all need this. | New file `src/common/overwrite.zig` | +40 lines | P1 |
| D3 | **Create shared `parseNumericWithSuffix(str, suffixes)` in `common/format.zig`** — Unify suffix parsing for `sort -S`, `head -c`, `tail -c`, `dd bs=`. Each has a different implementation; sort rejects valid suffixes head accepts. | `src/common/format.zig` | +50 lines, then refactor 4 callers | P2 |
| D4 | **Add shared `writeFileHeader(writer, filename)`** for `==> filename <==` — Used by head, tail, cat, nl. Currently 4 independent implementations. | `src/common/lib.zig` or new file | +15 lines, ~20 lines removed | P3 |
| D5 | **Move ISO 8601 parser from `date.zig` to `common/time.zig`** — Shared by date, touch, stat, find (all need timestamp parsing). Fix the timezone-offset bug during extraction. | `src/common/time.zig` (+80 lines), `src/date.zig` (-80 lines) | Net 0 | P2 |

### Theme E: Silent Stub Flags [CRITICAL CORRECTNESS]
**Confidence: ★★★★★** (the #1 finding across all 4 audits)

These are flags that parse successfully but have zero runtime effect. Users get
silent wrong answers. Ordered by blast radius.

| # | Utility | Stub Flags | Location | Line Impact | Priority |
|---|---------|-----------|----------|-------------|----------|
| E1 | **find** | `-regex/-iregex` (always false), `-Bmin/-Bnewer/-Btime/-newerXY` (always true), `-printf` (placeholder), `-s`, `-perm +/-`, `-exec {}+`, `-execdir {}+` | `src/find.zig` | ~300 lines to implement | P0 |
| E2 | **stat** | `%r/%R` (missing), `-f` ignores `-c`, terse wrong field count, macOS `StatFs` on Linux, `+` prefix on numbers | `src/stat.zig` | ~200 lines | P0 |
| E3 | **printf** | `\NNN` octal, `%b \0NNN` off-by-one, `\c` not handled, `%F/%a/%A` missing | `src/printf.zig` | ~150 lines | P0 |
| E4 | **dd** | `iflag=`, `oflag=`, `speed=`, `files=`, `conv=sparse`, `conv=par*` | `src/dd.zig` | ~200 lines | P1 |
| E5 | **sort** | `-V` (acts as `--version`!), `-h` (wrong algorithm), `-s` (no-op) | `src/sort.zig` | ~100 lines | P0 |
| E6 | **nl** | `pBRE` numbering, section reset, unnumbered line spacing, blank line indent, `-d ''` | `src/nl.zig` | ~120 lines | P1 |
| E7 | **du** | `-I` (ignore pattern), `-S` (separate-dirs), `-A/-b` (apparent dir size) | `src/du.zig` | ~80 lines | P1 |
| E8 | **df** | `-n` (stub), `-Y` (no-op), `-I` (wrong semantic), `-P` (wrong headers), `--output` (stub) | `src/df.zig` | ~100 lines | P1 |
| E9 | **ls** | Exit code always 0, `-P`/`-H` (parsed never used), `-G` (wrong semantic), `-a` ≡ `-A` | `src/ls/main.zig` | ~60 lines | P1 |
| E10 | **env** | `-S` (stub), bare `-` (no-op), `-P` (wrong semantic) | `src/env.zig` | ~80 lines | P1 |
| E11 | **date** | `-z` (no-op), `-f` (broken), `-r` numeric (broken) | `src/date.zig` | ~60 lines | P1 |
| E12 | **ln** | `-h/-n` (parsed, never applied), `--backup=CONTROL` (panics) | `src/ln.zig` | ~40 lines | P1 |
| E13 | **tr** | `[c*]/[c*0]` fill-to-length produces empty set | `src/tr.zig` | ~30 lines | P1 |
| E14 | **touch** | `-A` (stub), `-d` ignores TZ | `src/touch.zig` | ~50 lines | P1 |
| E15 | **chmod** | Symbolic modes starting with `-` parsed as flags; umask not applied without who-specifier | `src/chmod.zig` | ~40 lines | P0 |
| E16 | **wc** | `-c`/`-m` mutual exclusion inverted; `-L` counts bytes not display columns | `src/wc.zig` | ~60 lines | P1 |

### Theme F: Crash / Safety Bugs [CRITICAL]
**Confidence: ★★★★★** (verified by multiple auditors)

| # | Utility | Bug | Location | Priority |
|---|---------|-----|----------|----------|
| F1 | **mv** | Panics (SIGABRT) moving directory into its own subdirectory | `src/mv.zig` | P0 |
| F2 | **mv** | `-i` interactive prompt completely dead on Linux | `src/mv.zig` | P0 |
| F3 | **uniq** | `--all-repeated=METHOD` crashes with Zig stack trace | `src/uniq.zig:81-97` | P0 |
| F4 | **ln** | `--backup=CONTROL` panics | `src/ln.zig` | P0 |
| F5 | **head** | Reading a directory crashes with stack trace | `src/head.zig:138,153` | P0 |
| F6 | **tail** | `processInputByBytesNoSeek` allocates full `byte_count` → OOM on `tail -c 10G` | `src/tail.zig:735` | P1 |
| F7 | **rm** | `-W` deletes files instead of undelete; silently dangerous | `src/rm.zig` | P0 |
| F8 | **timeout** | `setpgid` race: called after spawn, signals may miss child | `src/timeout.zig:287-289` | P1 |

### Theme G: Test Quality — False-Green Tests [HIGH]
**Confidence: ★★★★★** (the #2 finding; independently flagged by all auditors)

The codebase has ~200 parse-only stub tests that give false confidence. These are
tests that call `parseArgs()` and assert struct field values without ever running
the utility. A completely broken flag passes them.

| # | Task | Affected Utilities | Estimated Tests | Priority |
|---|------|--------------------|-----------------|----------|
| G1 | **Audit and tag all parse-only tests** — Add `// PARSE-ONLY: needs behavioral companion` comment to each. Do NOT delete; they still catch parser regressions. | chmod (49), sort (32), grep (35), cp (10), chown (8), df (36), stat (9), dd (7+) | ~186 tests | P2 |
| G2 | **Write behavioral companion tests** for MUST-tier flags that only have parse-only coverage. Use `runUtilWithInput` pattern. | Same utilities | ~100 new tests | P1 |
| G3 | **Fix false-green tests** that assert buggy behavior as correct: tac `-b`, nl `-b n`, wc `-c/-m`, printf exit code, ls `-a`, readlink `-f`, realpath default | tac, nl, wc, printf, ls, readlink, realpath | ~15 tests to rewrite | P0 |
| G4 | **Standardize `runUtilWithInput` split** for filter utilities — grep, sort, head, nl, cat, tac lack the injectable stdin pattern that tr/tee/uniq have. Makes stdin paths structurally untestable. | 6 utilities | ~20 lines each | P2 |

### Theme H: Platform Divergence (macOS ↔ Linux) [IMPORTANT]
**Confidence: ★★★★☆** (found by section C primarily; confirmed by D)

| # | Task | Files | Priority |
|---|------|-------|----------|
| H1 | **stat: Add Linux `statfs` struct** — Currently uses macOS `StatFs` unconditionally; all `-f` output is garbage on Linux | `src/stat.zig:20-38` | P0 |
| H2 | **stat: Use `statx(2)` for birth time on Linux** — `%w/%W` always returns 0 on Linux | `src/stat.zig:229-233` | P1 |
| H3 | **stat: Fix `+` prefix on numeric fields** — Zig 0.15.2 format bug with signed integer + width specifier | `src/stat.zig:675` | P0 |
| H4 | **ls: Fix `-G` semantic** — Currently macOS (colorize); should be GNU (omit group column) when targeting GNU compat | `src/ls/main.zig:113` | P1 |
| H5 | **du: Fix `-n` semantic** — Mapped to `-P` (no-follow); should be nodump on macOS, unrecognized on GNU | `src/du.zig:47-48` | P1 |
| H6 | **df: Fix `-I` semantic** — Treated as type-filter requiring argument; macOS: boolean suppress-inodes | `src/df.zig:300-313` | P1 |

### Theme I: Permission/Ownership Handling [CRITICAL]
**Confidence: ★★★★★** (section C deep dive; cross-verified)

| # | Task | Files | Priority |
|---|------|-------|----------|
| I1 | **Fix `user:` login group in `user_group.zig`** — Must look up user's primary group via `getpwnam`/`getpwuid` | `src/common/user_group.zig:74-87` | P0 |
| I2 | **Fix chown `-R` symlink traversal at entry point** — `stat()` called instead of `lstat()` for cmdline args under `-P` | `src/chown.zig:388` | P0 |
| I3 | **Fix chmod umask bypass** — When no who-specifier given, `who=7` bypasses umask | `src/chmod.zig:604-606` | P0 |
| I4 | **Fix chmod `-` flag collision** — `chmod -x script.sh` parsed as flag instead of symbolic mode | `src/chmod.zig:67` | P0 |
| I5 | **Fix `id -G` with named user** — Must call `getgrouplist(3)` for supplementary groups | `src/id.zig:309-313` | P1 |

---

## Part 2: Recommended Execution Order

### Phase 0: Library Foundation (do first — everything else depends on this)

```
Week 1-2: Library infrastructure
├── A1: posixErrorString() in lib.zig                     [30 lines, 0 deps]
├── B2: Fix free -s flag collision                         [10 lines, 0 deps]
├── C1: canonicalizeParentMustExist() in path.zig          [20 lines, 0 deps]
├── D1: isatty guard in promptYesNo()                      [5 lines, 0 deps]
├── B4: Optional-value syntax in argparse                  [40 lines, 0 deps]
└── A3: printTryHelp() in lib.zig                          [10 lines, 0 deps]
```

All of these are independent of each other. **Can be parallelized.**
Estimated: ~115 lines of new common code.

### Phase 1: Critical Crash/Safety Fixes (fix before anything user-facing)

```
Week 2-3: Crash eliminators (depends on Phase 0)
├── F1: mv directory-into-self panic                       [~20 lines]
├── F2: mv -i dead on Linux                                [~30 lines]
├── F3: uniq --all-repeated crash (needs B4 from Phase 0)  [~15 lines]
├── F4: ln --backup=CONTROL panic                          [~20 lines]
├── F5: head directory-read crash                          [~10 lines]
├── F7: rm -W deletes instead of undelete                  [~20 lines, or remove the flag]
├── G3: Fix false-green tests (prevents confusion)         [~15 tests]
├── C2+C3+C4: readlink/realpath -f fix (needs C1)         [~25 lines + tests]
└── I1-I4: Permission/ownership chain (needs A1)           [~80 lines]
```

### Phase 2: Worst Silent Stubs (highest user impact)

```
Week 3-5: Make flags actually work (depends on Phase 0-1)
├── E5:  sort -V, -h, -s                                  [~100 lines]
├── E3:  printf \NNN, \c, %F/%a/%A                         [~150 lines]
├── E15: chmod symbolic modes + umask                      [~40 lines]
├── E1:  find -regex (partial), -perm +/-, -exec {}+       [~200 lines]
├── E2:  stat format fixes + platform struct               [~200 lines]
├── A2:  Roll out posixErrorString across 30 files         [108 site changes]
├── H1+H3: stat Linux fixes                                [~50 lines]
└── F8:  timeout setpgid race fix                          [~10 lines]
```

### Phase 3: Secondary Stubs + Test Quality

```
Week 5-7: Fill remaining gaps (depends on Phase 2)
├── E4:  dd iflag/oflag stubs                              [~200 lines]
├── E6:  nl section handling + pBRE                        [~120 lines]
├── E7:  du -I, -S, -A/-b                                 [~80 lines]
├── E8:  df -n, -P headers, -I, --output                  [~100 lines]
├── E9:  ls exit codes, -P/-H, -a vs -A                   [~60 lines]
├── E10: env -S, bare -, -P                                [~80 lines]
├── E11: date -z, -f, -r numeric                           [~60 lines]
├── D2:  OverwriteMode shared enum                         [~40 lines]
├── D5:  ISO 8601 parser → common/time.zig                 [net 0]
├── G1:  Tag parse-only tests                              [~186 comments]
├── G2:  Write behavioral companion tests                  [~100 new tests]
└── G4:  runUtilWithInput split for 6 filter utils         [~120 lines]
```

### Phase 4: Polish + Library Improvements

```
Week 7-9: Quality of life (depends on Phase 3)
├── A4: Exit code 2→1 convention (8 utilities)             [~15 lines each]
├── B1: Flag-name payload in argparse UnknownFlag          [~20 lines]
├── B3: POSIX stop-at-first-positional mode                [~30 lines]
├── D3: Shared parseNumericWithSuffix                      [~50 lines]
├── D4: Shared writeFileHeader                             [~15 lines]
├── H2: stat birth time via statx(2)                       [~30 lines]
├── H4-H6: ls/du/df semantic fixes                         [~40 lines each]
├── I5: id -G getgrouplist                                 [~30 lines]
├── E12-E16: Remaining stub flags (ln, tr, touch, wc)      [~230 lines]
└── All remaining IMPORTANT findings from audit reports
```

---

## Part 3: Dependency Graph

```
                    ┌─────────────┐
                    │  Phase 0    │
                    │ Library     │
                    │ Foundation  │
                    └──────┬──────┘
                           │
               ┌───────────┼───────────┐
               ▼           ▼           ▼
        ┌────────────┐ ┌────────┐ ┌──────────┐
        │  Phase 1   │ │Phase 1 │ │ Phase 1  │
        │  Crashes   │ │ Perms  │ │ Tests    │
        └──────┬─────┘ └───┬────┘ └────┬─────┘
               │           │           │
               └───────────┼───────────┘
                           ▼
                    ┌─────────────┐
                    │  Phase 2    │
                    │  Worst      │
                    │  Stubs      │
                    └──────┬──────┘
                           │
               ┌───────────┼───────────┐
               ▼           ▼           ▼
        ┌────────────┐ ┌────────┐ ┌──────────┐
        │ Phase 3    │ │Phase 3 │ │ Phase 3  │
        │ More Stubs │ │ Tests  │ │ Library  │
        └──────┬─────┘ └───┬────┘ └────┬─────┘
               └───────────┼───────────┘
                           ▼
                    ┌─────────────┐
                    │  Phase 4    │
                    │  Polish     │
                    └─────────────┘
```

### Key Dependencies

| Task | Depends On | Why |
|------|-----------|-----|
| A2 (roll out posixErrorString) | A1 (create function) | Can't use it until it exists |
| C2, C3 (readlink/realpath fix) | C1 (canonicalizeParentMustExist) | Both call the same new function |
| F3 (uniq crash) | B4 (optional-value argparse) | Crash is caused by argparse limitation |
| I1-I4 (permission fixes) | A1 (error strings) | Error paths need POSIX strings |
| E2 (stat format) | H1 (Linux statfs struct) | Can't fix format without correct struct |
| G2 (behavioral tests) | G3 (fix false-greens first) | Don't write tests against buggy behavior |
| D2 (OverwriteMode) | F1, F2 (mv crash fixes) | mv is the most broken consumer |

---

## Part 4: What the Auditors Missed or Got Wrong

### Missed

1. **`promptYesNo` has no `isatty` check** — The code comment says "caller is
   responsible for checking whether stdin is a TTY" but none of the 3 callers
   (cp, mv, rm) actually check. Piping into `rm -i` prompts into the pipe. Only
   Section A caught this partially; none quantified that zero callers check.

2. **`sort -R` uses a fixed seed of 0** — `--random-source` is parsed but never
   used; the PRNG is deterministic. Section B flagged it as IMPORTANT but this is
   arguably CRITICAL: users expecting randomized output get the same order every
   time.

3. **`tee` append mode uses `open + seek-to-end` instead of `O_APPEND`** — Not
   atomic with concurrent writers. Only Section B caught this; it's a data-loss
   risk when multiple processes write to the same file via tee.

4. **`chown` has dead code that tests exercise but production never calls** —
   `chownFile()` is called from 11 test sites but `runChown()` bypasses it entirely.
   Unit test coverage of this function provides zero confidence about production
   behavior. Section C caught this but it was not in the remediation plan.

5. **`du` help text claims `BLOCKSIZE`/`POSIXLY_CORRECT` env vars work; they
   don't** — False documentation. None of the 4 auditors flagged the documentation
   lie explicitly; Section C mentioned it only as IMPORTANT.

6. **`inf`/`infinity` case sensitivity** — `common/time.zig` only accepts lowercase.
   GNU sleep accepts all case variants. Section D noted this was partially fixed
   but the case-insensitive handling is still incomplete.

### Got Wrong

1. **Section D auditor said `sleep inf` was fixed** — Checked `time.zig:53-56` and
   confirmed lowercase `inf`/`infinity` work. However, the auditor's note that "the
   audit report is outdated" may itself be misleading: uppercase `INF` still fails.
   The fix was partial, not complete.

2. **Remediation plan lists `rm -W` as CRITICAL for "deletes instead of undelete"** —
   While technically correct, the `-W` flag is macOS-only (BSD whiteout files), and
   the undelete syscall doesn't exist on Linux. The practical fix is to either
   remove the flag or gate it behind `@import("builtin").os.tag == .macos`. This is
   not a "fix the implementation" task; it's a "remove or gate" task.

3. **Multiple auditors flagged the `stat +` prefix as a Zig 0.15.2 formatting bug** —
   This is actually a consequence of using `{d: <10}` format specifier on a signed
   integer where Zig 0.15 emits the `+` sign for the width directive. The fix is to
   cast to unsigned before formatting, not to wait for a Zig compiler fix.

---

## Part 5: Summary Statistics

| Metric | Count |
|--------|-------|
| Total CRITICAL findings | 209 |
| Total IMPORTANT findings | 574 |
| Unique crash/panic bugs | 8 |
| Silent stub flags (parsed, no effect) | 45+ |
| Parse-only stub tests | ~186 |
| False-green tests (assert wrong behavior) | ~15 |
| `@errorName` call sites to fix | 108 |
| Utilities marked BLOCKED | 5 (df, du, mv, printf, stat) |
| Utilities marked APPROVED | 1 (pwd) |
| Common library functions to add | 8 |
| Estimated total lines changed | ~3,500–4,000 |

### Impact by Phase

| Phase | CRITICAL Resolved | IMPORTANT Resolved | Lines Changed |
|-------|------------------|--------------------|---------------|
| 0 (Foundation) | 5 | 15 | ~115 |
| 1 (Crashes + Perms) | 25 | 20 | ~250 |
| 2 (Worst Stubs) | 60 | 40 | ~900 |
| 3 (Secondary + Tests) | 80 | 200 | ~1,200 |
| 4 (Polish) | 39 | 299 | ~1,000 |

---

## Appendix: Cross-Reference Matrix

Issues found by multiple auditors independently (highest confidence):

| Finding | Section A | Section B | Section C | Section D |
|---------|:---------:|:---------:|:---------:|:---------:|
| `@errorName` in user messages | ✓ | ✓ | ✓ | ✓ |
| Parse-only stub tests | ✓ | ✓ | ✓ | ✓ |
| Exit code 2 vs 1 misuse | ✓ | ✓ | | ✓ |
| Missing "Try --help" hint | ✓ | | | ✓ |
| `-f/-i/-n` precedence bugs | ✓ | | | |
| Path resolution wrong semantics | | | | ✓ (+ A for find) |
| Platform struct divergence | | | ✓ | |
| Timezone ignored in date parsing | ✓ (touch) | | | ✓ (date) |
| `promptYesNo` no isatty check | ✓ | | | |
| `runUtilWithInput` split missing | | ✓ | | |
| Tests encoding buggy behavior | ✓ | ✓ | ✓ | ✓ |
| Numeric suffix parsing divergence | | ✓ | | ✓ |
