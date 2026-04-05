# FINAL PLAN: Codebase Refactoring — Converged from Opus + GPT Syntheses

**Author:** Architect (convergence of OPUS_SYNTHESIS.md + GPT_SYNTHESIS.md)
**Date:** 2026-04-04
**Status:** READY FOR EXECUTION

---

## Verified Codebase Facts

Before converging opinions, I independently verified every disputed number:

| Fact | Opus | GPT | **Verified** |
|------|------|-----|-------------|
| Utilities with `main()` | 45 | 45 | **45** (2 empty: free.zig, yes.zig; 2 trivial: true.zig, false.zig) |
| Files with `printVersion` | 36 (implicit 45) | 36 | **36** |
| Files with argparse catch block | 24 (implicit 45) | 24 | **24** |
| Files with `parsed_args.help` | 45 (assumed) | 21 | **21** |
| GPA utilities | Not flagged | 8 | **9** (chmod, chown, cp, ln, mkdir, rm, rmdir, touch, ls/main.zig) |
| `@errorName` sites | 107 | 103 | **109** (grep of production code) |
| Local error-mapping functions | 9 | 9 | **9** (cp, chmod, tee, mkdir, head, tail, rmdir, realpath, ls/main.zig) |
| `posixErrorString` production callers | 0 | 0 | **0** |
| `printTryHelp` production callers | 0 | 0 | **0** |
| free.zig / yes.zig | Have exit code bugs | Empty (0 bytes) | **0 bytes — GPT correct** |
| true.zig / false.zig | Standard utilities | Trivial mains | **Trivial** (`std.process.exit(0)` / `exit(1)`) |

---

## Top 10 Ranked Extractions

### E1 — `common/main.zig`: `utilityMain` Composite Wrapper

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #1, GPT #1) |
| **Consensus** | FULL — both agree this is the dominant extraction |
| **Files affected** | 41 utilities (45 − 2 empty − 2 trivial) |
| **Net lines saved** | ~1,200–1,400 (GPT's verified count; Opus's 2,475 is inflated) |
| **Effort** | 3–4 days |
| **Risk** | Low (mechanical) |
| **Depends on** | Nothing |

**Disputed: Should the wrapper absorb argparse?**
- *Opus says yes:* One monolithic wrapper handles main(), argparse errors, help/version, and printVersion.
- *GPT says no:* Keep the wrapper simple (setup/teardown only) + separate `ArgParser.parseOrExit()`.

**My ruling: GPT wins.** The wrapper should do exactly 5 things: allocator, args, buffers, flush, exit. Reason: echo, date, env, and test don't use ArgParser at all. A monolith requires escape hatches for these 4+ utilities, which defeats the purpose. Two composable primitives are better than one leaky framework.

**Disputed: Line count**
- *Opus:* ~2,475 (55 × 45)
- *GPT:* ~1,200–1,400 (component-by-component verified)

**My ruling: GPT wins.** Opus assumed uniform 55 lines across all 45 utilities. Verified counts show only 24 have argparse catch, only 21 check `parsed_args.help`, only 36 have `printVersion`. The realistic composite is ~1,300 net.

**API (adopted from GPT's design):**
```zig
// src/common/main.zig
pub fn utilityMain(
    comptime runFn: fn (std.mem.Allocator, []const []const u8, anytype, anytype) anyerror!u8,
) noreturn {
    // arena setup, argsAlloc, stdout/stderr buffers, call runFn, flush, exit
}
```

**GPA→Arena migration:** The 9 GPA utilities must be migrated to Arena first. Both agree Arena is correct for production CLI tools; GPA is only useful during development for leak detection and `zig build test` provides that.

---

### E2 — Expand and Roll Out `posixErrorString`

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #2, GPT #2) |
| **Consensus** | FULL |
| **Files affected** | 9 files (delete local functions) + ~30 files (replace `@errorName`) |
| **Net lines saved** | ~113 (delete 9 functions ~130 lines, add ~17 mappings) |
| **Effort** | 1–2 days |
| **Risk** | Very low |
| **Depends on** | Nothing |

Expand from 15 to ~32 mappings (superset from all 9 local functions, especially cp.zig's 28-mapping version). Delete 9 local functions. Replace 109 `@errorName` sites. **Zero production callers today — this is an execution failure, not a design problem.**

---

### E3 — Extract Symbolic Mode Parser to `common/mode.zig`

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #3, GPT #3) |
| **Consensus** | FULL — both credit GPT reviewer for catching this |
| **Files affected** | `src/chmod.zig` (lines 566–797), `src/mkdir.zig` (lines 221–312) |
| **Net lines saved** | ~145 |
| **Effort** | 1–2 days |
| **Risk** | Low-medium |
| **Depends on** | Nothing |

chmod's parser is the superset (handles `s/t/X`, permission-copying `g=u`, `is_directory` context). mkdir's is a subset. Extract chmod's as the canonical implementation with a `ModeContext` struct; mkdir calls with defaults.

---

### E4 — `printTryHelp` Rollout

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #4, GPT #4) |
| **Consensus** | FULL |
| **Files affected** | ~47 utilities |
| **Net lines saved** | ~0 (consistency improvement, not line reduction) |
| **Effort** | Half a day |
| **Risk** | Zero |
| **Depends on** | E1 partially (utilityMain absorbs some error paths) |

Replace 54 inline "Try --help" strings across 19 utilities. Add to 28 utilities that are missing it entirely. **Zero production callers today.** GNU compatibility is a project goal — ship this.

---

### E5 — `ArgParser.parseOrExit()` (Standalone)

| Attribute | Value |
|-----------|-------|
| **Recommended by** | GPT (explicitly); Opus (as part of utilityMain, which I rejected above) |
| **Consensus** | PARTIAL — both want the catch block extracted; disagree on where it lives |
| **Files affected** | 24 utilities with argparse error catch blocks |
| **Net lines saved** | ~360 (15 lines × 24 utilities) |
| **Effort** | Half a day |
| **Risk** | Low |
| **Depends on** | Nothing (but pairs naturally with E1) |

Creates `ArgParser.parseOrExit(T, allocator, args, prog_name, stderr)` that encapsulates the `UnknownFlag`/`MissingValue`/`InvalidValue` catch block. Called inside each utility's `runX` function. Utilities with custom parsers (echo, date, env, test) simply don't call it.

This is the GPT-recommended decomposition over Opus's monolithic wrapper. It composes with E1 cleanly.

---

### E6 — Fix Crash/Panic Bugs (mv, uniq, ln, head)

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #9 partially, GPT #6) |
| **Consensus** | FULL on existence; disagreement on ranking |
| **Files affected** | mv.zig, uniq.zig, ln.zig, head.zig |
| **Net lines saved** | ~0 (bug fixes) |
| **Effort** | 2 days |
| **Risk** | Low individually |
| **Depends on** | Nothing |

| Bug | Utility |
|-----|---------|
| SIGABRT moving dir into own subdirectory | mv |
| `-i` interactive prompt dead on Linux | mv |
| `--all-repeated=METHOD` crashes | uniq |
| `--backup=CONTROL` panics | ln |
| Reading a directory crashes with stack trace | head |

GPT correctly ranks crashes higher than Opus. Crashes are P0. These should be in Batch 1.

---

### E7 — Fix `canonicalizeParentMustExist` + readlink/realpath

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #8, GPT #5) |
| **Consensus** | FULL |
| **Files affected** | common/path.zig, readlink.zig, realpath.zig |
| **Net lines changed** | ~45 |
| **Effort** | Half a day |
| **Risk** | Medium (must verify against GNU behavior) |
| **Depends on** | Nothing |

Both `readlink -f` and `realpath` (default mode) are broken. The `canonicalizeMissing` ".." past root bug is a security issue. Fix together.

---

### E8 — Merge ISO 8601 Parsers into `common/time.zig`

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #6, GPT #8) |
| **Consensus** | FULL (both note TZ bug is already fixed; dedup on structural grounds) |
| **Files affected** | date.zig, touch.zig, common/time.zig |
| **Net lines saved** | ~80 |
| **Effort** | 1 day |
| **Risk** | Low |
| **Depends on** | Nothing |

The two `parseIso8601` functions are ~75% similar. touch.zig also has standalone calendar helpers (`daysFromYMD`, `isLeapYear`, `getDaysInMonth`) at lines 544-575 that should move to `common/time.zig` during this extraction.

---

### E9 — Permission/Ownership Bug Fixes (chown, chmod, id)

| Attribute | Value |
|-----------|-------|
| **Recommended by** | GPT #7 (Opus mentions chmod umask inline) |
| **Consensus** | PARTIAL — GPT elevated this; Opus treated as scattered inline fixes |
| **Files affected** | chown.zig, chmod.zig, id.zig, common/user_group.zig |
| **Net lines changed** | ~40 |
| **Effort** | 1–2 days |
| **Risk** | Medium (needs careful testing with real permissions) |
| **Depends on** | Nothing |

| Bug | Detail |
|-----|--------|
| `user:` login group | Must use `getpwnam`/`getpwuid` for primary group |
| chown `-R` symlink traversal under `-P` | `stat()` instead of `lstat()` for cmdline args |
| chmod umask bypass | `who=7` when no who-specifier given |
| chmod `-x script.sh` parsed as flag | Symbolic modes starting with `-` conflict with flags |

Only GPT bundled these together. Correct call — they share a "permissions/ownership" theme and should be verified together.

---

### E10 — Exit Code 2→1 + Backup Env Var (Trivial Inline Fixes)

| Attribute | Value |
|-----------|-------|
| **Recommended by** | Both (Opus #10 + #7, GPT #9 + #10) |
| **Consensus** | FULL (GPT correctly reduced from 8→6 utilities for exit codes) |
| **Files affected** | sleep, seq, date, dd, printf, whoami (exit codes); cp.zig, mv.zig (backup env var) |
| **Net lines changed** | ~20 |
| **Effort** | 30 minutes |
| **Risk** | Zero |
| **Depends on** | Nothing |

Exit 2→1 for value errors (not flag-syntax errors). Add `SIMPLE_BACKUP_SUFFIX` env var read to cp.zig and mv.zig (ln.zig already has it).

**Note:** Opus and the Roadmap listed `yes` and `free` — both are 0-byte empty files. Actual count: **6 utilities**, not 8.

---

## Dependency Graph

```
E1 (utilityMain)  ──────────────────┐
                                    ├──→ E4 (printTryHelp rollout — partially absorbed by E1)
E5 (parseOrExit)  ──────────────────┘

E2 (posixErrorString)  ── standalone ── integrates naturally with E5's error paths

E3 (mode.zig)     ── standalone
E6 (crash fixes)  ── standalone
E7 (path fixes)   ── standalone
E8 (time.zig)     ── standalone
E9 (perm fixes)   ── standalone
E10 (trivial)     ── standalone
```

**Hard dependencies:**
- E4 (printTryHelp rollout) benefits from E1 being done first — the wrapper's error paths can call `printTryHelp` automatically. But E4 can also proceed independently for the 28 utilities that need manual addition.

**Soft dependencies:**
- E5 (parseOrExit) pairs naturally with E1 — both touch the same boilerplate area. Doing them in sequence reduces merge conflicts.
- E2 (posixErrorString) integrates well with E5 — `parseOrExit` can use `posixErrorString` for its error messages.

**No dependencies:** E3, E6, E7, E8, E9, E10 are all fully independent.

---

## 3 Parallel Execution Batches

### Batch 1: Foundation + Critical Bugs (Week 1)
**Goal:** Build the primitives and fix anything that crashes.

| Track | Extractions | Effort | Parallelizable? |
|-------|------------|--------|-----------------|
| Track A | **E1** (utilityMain) + **E5** (parseOrExit) — write common modules, convert 5 pilot utilities | 2 days | Yes |
| Track B | **E6** (crash fixes: mv, uniq, ln, head) | 2 days | Yes (independent of Track A) |
| Track C | **E2** (expand posixErrorString to 32 mappings) + **E10** (trivial inline fixes) | 1 day | Yes (independent of both) |

**Exit criteria:** common/main.zig exists and works for 5 utilities. posixErrorString has 32 mappings. All 5 crash bugs fixed. Exit codes corrected.

### Batch 2: Rollout + Structural Extractions (Week 2)
**Goal:** Migrate remaining utilities to new patterns. Extract shared modules.

| Track | Extractions | Effort | Parallelizable? |
|-------|------------|--------|-----------------|
| Track A | **E1 continued** (migrate remaining 36 utilities, including 9 GPA→Arena) + **E5 continued** (rollout parseOrExit to 24 utilities) | 3 days | Yes |
| Track B | **E2 continued** (delete 9 local functions, replace 109 `@errorName` sites) + **E4** (printTryHelp rollout) | 2 days | Yes |
| Track C | **E3** (mode.zig extraction from chmod/mkdir) + **E8** (time.zig merge) | 2 days | Yes |

**Exit criteria:** All 41 utilities use `utilityMain`. All 24 argparse utilities use `parseOrExit`. `posixErrorString` has zero local duplicates. `printTryHelp` deployed everywhere. mode.zig and time.zig extracted.

### Batch 3: Correctness Sweep (Week 3)
**Goal:** Fix all remaining correctness bugs.

| Track | Extractions | Effort | Parallelizable? |
|-------|------------|--------|-----------------|
| Track A | **E7** (path canonicalization: readlink -f, realpath, ".." past root) | 1 day | Yes |
| Track B | **E9** (permission/ownership: chown user:, chmod umask, chmod -x flag, id -G) | 2 days | Yes |
| Track C | Behavioral test coverage for all changed utilities | 2 days | Yes |

**Exit criteria:** All correctness bugs fixed. Test coverage for new common modules ≥90%. All utilities pass existing tests.

---

## DO NOT DO List

### ❌ 1. Do NOT create `common/overwrite.zig`
**Appears in:** REFACTORING_ROADMAP D2, DUPLICATION_REPORT §3.2
**Both agree:** ✅ Consensus rejection
**Why:** rm has 3 modes (`force`, `interactive`, `interactive_once`). ln has `force` + `interactive` + backup interaction. cp has `force` + `interactive` + `no_clobber` + backup. A shared enum would need per-utility variants — worse than no abstraction. Fix the 2 precedence bugs (mv `-n -f`, rm `-f -i`) inline in E6.

### ❌ 2. Do NOT create `common/numeric.zig`
**Appears in:** REFACTORING_ROADMAP D3, DUPLICATION_REPORT §3.4
**Both agree:** ✅ Consensus rejection
**Why:** 5 parsers with genuinely different requirements: dd needs `c/w/b` + `NxN` multiplication (POSIX-mandated), find returns a `SizeExpr` struct (different return type), sort's parser is 22 lines (not worth extracting), tail has a tail-specific suffix set, and du/df already share `format.parseBlockSize`. A kitchen-sink `NumericOptions{allow_si, allow_iec, allow_dd_suffixes, allow_multiplication}` is harder to understand than 5 focused parsers.

### ❌ 3. Do NOT create `common/file_header.zig`
**Appears in:** REFACTORING_ROADMAP D4, DUPLICATION_REPORT §3.7
**Both agree:** ✅ Consensus rejection
**Why:** 4 inline `==> {s} <==\n` format strings. Net +6 lines for a new module, import, and function call. Pure over-engineering.

### ❌ 4. Do NOT create `common/backup.zig`
**Appears in:** DUPLICATION_REPORT §3.3
**Both agree:** ✅ Consensus rejection
**Why:** 3 callers. The shared logic is 2 lines (`std.posix.getenv("SIMPLE_BACKUP_SUFFIX")` with default `"~"`). Add 2 lines to cp.zig and mv.zig. Done. (This is E10.)

### ❌ 5. Do NOT extend ArgParser for env/date custom syntax
**Appears in:** AUDIT_SYSTEM_INFO §2, AUDIT_UTIL_AGENT Architecture Issue #2
**Both agree:** ✅ Consensus rejection
**Why:** env's `NAME=VALUE` stops flag parsing; date's `+FORMAT` prefix. Adding `CustomParsing` hooks, `is_assignment_fn`, and `on_assignment_fn` callbacks makes ArgParser harder to understand for 43 utilities that don't need them. env and date's custom parsers are ~200 lines each, well-tested, well-understood. Leave them.

### ❌ 6. Do NOT tag 186 tests with `// PARSE-ONLY` comments
**Appears in:** REFACTORING_ROADMAP G1
**Both agree:** ✅ Consensus rejection
**Why:** Comments don't prevent false confidence. They're visual noise. Write behavioral companion tests instead. Parse-only tests are fine as parser regression tests.

### ❌ 7. Do NOT make `utilityMain` a monolithic framework
**Appears in:** Opus's design (absorb argparse + help/version into wrapper)
**GPT wins this dispute:** Keep the wrapper simple (5 responsibilities: allocator, args, buffers, flush, exit). Separate `parseOrExit` handles argparse errors for the 24 utilities that need it. This composes cleanly; echo/date/env/test don't call `parseOrExit`.

### ❌ 8. Do NOT count free.zig or yes.zig in any extraction
**Both syntheses note this but earlier reports didn't check:** These are 0-byte empty placeholder files. They cannot have bugs, exit code issues, or extractable patterns. Any plan that lists them is wrong.

---

## Summary Metrics

| Metric | Value |
|--------|-------|
| **Total net lines removed** | ~1,900 (~2.6% of 73,156-line codebase) |
| **Crash bugs fixed** | 5 |
| **Correctness bugs fixed** | 9 |
| **New common modules** | 2 (main.zig, mode.zig) |
| **Expanded common modules** | 2 (lib.zig/posixErrorString, time.zig) |
| **Estimated total effort** | ~3 weeks with TDD |
| **Modules NOT created** | 5 (overwrite, numeric, file_header, backup, ArgParser extensions) |

---

## Appendix: Arbitration Record

| Dispute | Opus Position | GPT Position | Ruling | Reason |
|---------|--------------|-------------|--------|--------|
| utilityMain line savings | ~2,475 | ~1,200–1,400 | **GPT** | Component-by-component verification shows only 24/45 have argparse catch, 21/45 have help check, 36/45 have printVersion |
| Should utilityMain absorb argparse? | Yes (monolithic) | No (composable) | **GPT** | 4+ utilities don't use ArgParser. Monolith needs escape hatches. Two composable functions are simpler |
| Total effort estimate | ~2 weeks | ~3 weeks | **GPT** | 41-file migration with TDD, 9 GPA→Arena conversions, and behavioral tests takes longer than optimistic estimates |
| sort -R fixed seed severity | CRITICAL | IMPORTANT | **GPT** | Deterministic shuffle ≠ data loss or security. Young project, unlikely to be used in production |
| `@errorName` exact count | 107 | 103 | **Neither — actual: 109** | Small discrepancy, doesn't affect the plan |
| GPA utility count | Not flagged | 8 | **Actual: 9** (GPT missed ls/main.zig) | GPT gets credit for finding the pattern; count adjusted |
| Crash fixes ranking | #9 area (scattered) | #6 (bundled) | **GPT** | Crashes are P0. Grouping them for Batch 1 is correct |
| Permission bugs grouping | Scattered inline | Bundled as #7 | **GPT** | Thematic grouping aids testing and verification |
| Primary argument for utilityMain | Line count (2,400+) | Architectural forcing function | **GPT** | Lines are a side effect. The real value is enforced consistency, GPA→Arena standardization, and future extensibility |

---

*ARCHITECTURE COMPLETE — Ready for programmer execution in 3 batches.*
