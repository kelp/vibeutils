# GPT Synthesis: Consolidated Refactoring Opinion

**Author:** Claude Sonnet (Architect review — "GPT" role in chain)
**Date:** 2026-04-04
**Inputs:** REFACTORING_ROADMAP.md, DUPLICATION_REPORT.md, DUPLICATION_REVIEW.md, OPUS_SYNTHESIS.md, AUDIT_SYSTEM_INFO.md, AUDIT_UTIL_AGENT.md, context.md + independent codebase verification
**Codebase:** 73,156 lines of Zig, 45 utilities with `main()` (2 empty: free.zig, yes.zig), 36 with `printVersion`, 24 with argparse error catch blocks, 26 common modules

---

## Executive Opinion

Opus's synthesis is strong. The `utilityMain` composite extraction is real, it's the right #1, and the "what NOT to do" list is mostly correct. But Opus overcounts the savings, undercounts the complexity, and makes several factual errors that inflate the case. I agree with the direction but want to be precise about what we're actually buying.

**My headline disagreement:** Opus claims ~2,475 lines saved from `utilityMain`. My verified count is **~1,100–1,400 lines**. Still dominant — still #1 by a wide margin — but the 2,475 figure is inflated by double-counting and assuming uniformity that doesn't exist. When you tell a developer "we'll save 2,400 lines" and they actually save 1,200, you've damaged credibility. Get the numbers right.

**My headline agreement:** The 5 "do NOT create" modules (overwrite.zig, numeric.zig, file_header.zig, backup.zig, ArgParser custom extensions) are correct rejections. The GPT reviewer in DUPLICATION_REVIEW.md did excellent work catching these. The duplication report proposed abstractions for duplication that doesn't actually share semantics.

---

## Part 1: TOP 10 Highest-ROI Extractions

Ranked by **verified net lines saved × confidence × breadth of impact**. I verified every number against the actual codebase.

### #1 — `common.utilityMain()` Composite Wrapper
**Verified score: ~1,100–1,400 lines saved across 36–43 utilities**

| Component | Per-utility lines | Utilities | Subtotal | Verified? |
|-----------|------------------|-----------|----------|-----------|
| `main()` boilerplate (arena+args+buffers+flush+exit) | 22 | 36 (arena) + 8 (GPA) = 44 | ~968 | ✅ Verified: 36 use ArenaAllocator, 8 use GPA, 2 trivial (true/false) |
| `printVersion` function definition | 3 | 36 | ~108 | ✅ Verified: exactly 36 files with `fn printVersion` |
| Help/version flag check | 5 | 21 (with `parsed_args.help`) | ~105 | ✅ Verified: 21 utilities check `parsed_args.help` (not all do) |
| ArgParser error catch block | 15 | 24 | ~360 | ✅ Verified: 24 files with `error.UnknownFlag =>` |
| **Realistic total** | | | **~1,200–1,500** | |

**Why Opus overcounts (2,475):** Opus assumed 45 utilities × 55 lines each. But:
- 2 utilities are **empty files** (free.zig, yes.zig) — 0 lines to extract
- 2 utilities have trivial mains (true.zig: `std.process.exit(0)`, false.zig: `std.process.exit(1)`) — not extractable
- Only 21 utilities have `parsed_args.help` (not 45) — echo, true, false, and others don't use argparse at all
- Only 24 utilities have the argparse error catch block (not 45)
- Only 36 have `printVersion` (not 45)
- 8 utilities use `GeneralPurposeAllocator` instead of `ArenaAllocator` — the wrapper must handle both, or the GPA utilities need migration first

**Realistic estimate: ~1,200 lines net.** Still dominant. Still #1 by 10×.

**Critical design issue Opus missed:** The 8 GPA utilities (chmod, chown, cp, ln, mkdir, rm, rmdir, touch) chose GPA deliberately — probably for leak detection during development. The wrapper needs to either:
- (a) Force arena everywhere (breaking the GPA choice), or
- (b) Accept a `comptime allocator_kind` parameter, or
- (c) Just use arena and let developers use `zig build test` for leak detection

Option (c) is correct. Arena is the right production allocator for CLI tools. Standardize.

**Effort:** Medium (2–3 days). The main() body is mechanical. The catch block + help/version integration requires the wrapper to know the utility name and the help function — this is a comptime parameter design exercise, not just copy-paste.

**Risk:** Low for the main() body. Medium for integrating argparse error handling — some utilities (echo, date, env, test) have custom parsers and won't benefit from the argparse catch block portion.

---

### #2 — Expand and Roll Out `posixErrorString`
**Verified score: ~113 lines removed + 103 sites producing correct messages**

| Component | Count | Verified? |
|-----------|-------|-----------|
| Local error-mapping functions to delete | 9 functions (~130 lines) | ✅ All 9 verified at cited locations |
| `@errorName` sites to replace | 103 (not 114, not 107) | ✅ My grep: 103 in production code |
| Mappings to add to canonical function | ~17 (expand from 15 to ~32) | ✅ cp.zig has 28 mappings — superset |
| Production callers of `posixErrorString` | **0** | ✅ Zero. Verified. |

**What Opus got right:** This is #2 and it's mechanical. The function exists, is tested, and has zero adopters. Embarrassing.

**What Opus got wrong:** Opus said 107 `@errorName` sites. The Duplication Report said 114. My grep of production code (excluding test blocks and comments) found **103**. The discrepancy is small but shows the pattern: everyone rounds up.

**Effort:** Low (1–2 days). Purely mechanical find-and-replace per file.
**Risk:** Very low. The function already works.

---

### #3 — Extract Symbolic Mode Parser to `common/mode.zig`
**Verified score: ~90 lines saved, 2 utilities + future consumers**

| Component | Lines | Verified? |
|-----------|-------|-----------|
| chmod.zig symbolic parser (lines 615–797) | 183 lines | ✅ |
| mkdir.zig symbolic parser (lines 221–312) | 92 lines | ✅ |
| Shared module (superset from chmod) | ~130 lines | Estimate |
| **Net reduction** | **~145 lines** | |

**Agreement with Opus:** This is a genuine, high-value extraction. GPT's DUPLICATION_REVIEW correctly identified that mkdir already has its own parser (contradicting the original report's claim that "mkdir rejects symbolic modes"). Both auditors (Opus and GPT reviewer) caught this. It's the GPT reviewer's single best contribution.

**Design consideration:** chmod's parser needs `is_directory` and `current_mode` context for `X` (conditional exec) and `g=u` (permission copying). mkdir's doesn't. The shared API must accept optional context without burdening mkdir. A `ModeContext` struct with optional fields works.

**Effort:** Medium (1–2 days).
**Risk:** Low-medium. Getting the API right for both consumers is a small design exercise.

---

### #4 — `printTryHelp` Rollout
**Verified score: ~0 lines saved, 47 utilities made GNU-compatible**

| Component | Count | Verified? |
|-----------|-------|-----------|
| Inline "Try --help" strings | 54 sites across 19 utilities | ✅ Per DUPLICATION_REPORT |
| Utilities missing the hint | 28 | ✅ Per DUPLICATION_REPORT |
| Production callers of `common.printTryHelp` | **0** | ✅ Zero. Verified. |

**Agreement with Opus:** Embarrassing that this has zero adopters. Ship it.

**Why it's #4 despite zero line savings:** GNU compatibility is a project goal. This is the lowest-hanging fruit in the entire codebase. If `utilityMain` is done first, it absorbs the argparse-error-path hints automatically. The remaining 28 missing utilities need manual addition.

**Effort:** Low (half a day).
**Risk:** Zero.

---

### #5 — Fix `canonicalizeParentMustExist` + readlink/realpath
**Verified score: correctness fix, ~45 lines changed, 2 utilities**

| Component | Detail |
|-----------|--------|
| New function in common/path.zig | ~20 lines |
| readlink.zig -f fix | ~10 lines |
| realpath.zig default mode fix | ~15 lines |
| False-green tests to flip | 3 locations |
| `canonicalizeMissing` ".." past root bug | Security fix (AUDIT_UTIL_AGENT Critical #1) |

**This is correctness, not optimization.** Both `readlink -f` and `realpath` (default) are broken. The AUDIT_UTIL_AGENT also found a security-relevant ".." past root bug in `canonicalizeMissing`. These should be fixed together.

**Effort:** Low (half a day).
**Risk:** Medium — must verify against GNU behavior carefully.

---

### #6 — Crash/Panic Fixes (mv, uniq, ln, head)
**Verified: 4 crash bugs, all independently confirmed by multiple auditors**

| Bug | Utility | Source |
|-----|---------|--------|
| SIGABRT moving dir into own subdirectory | mv | ROADMAP F1 |
| `-i` interactive prompt dead on Linux | mv | ROADMAP F2 |
| `--all-repeated=METHOD` crashes | uniq | ROADMAP F3 |
| `--backup=CONTROL` panics | ln | ROADMAP F4 |
| Reading a directory crashes with stack trace | head | ROADMAP F5 |

**Why this ranks here:** Crashes are never acceptable. These are all P0. They should arguably be #1 in terms of *urgency*, even if they're lower in terms of lines-of-code impact.

**Effort:** Medium (2 days). Each is an independent fix.
**Risk:** Low individually. The uniq crash depends on argparse `--flag[=value]` optional syntax (B4).

---

### #7 — Permission/Ownership Chain (chown, chmod, id)
**Verified: 4 correctness bugs, independently confirmed**

| Bug | Detail |
|-----|--------|
| `user:` login group in user_group.zig | Must use `getpwnam`/`getpwuid` for primary group |
| chown `-R` symlink traversal under `-P` | `stat()` instead of `lstat()` for cmdline args |
| chmod umask bypass | `who=7` when no who-specifier given |
| chmod `-x script.sh` parsed as flag | Symbolic modes starting with `-` conflict with flags |

**Effort:** Medium (1–2 days).
**Risk:** Medium — need careful testing with real permission scenarios.

---

### #8 — Merge ISO 8601 Parsers into `common/time.zig`
**Verified score: ~80 lines saved, 2 utilities**

| Component | Lines |
|-----------|-------|
| date.zig parseIso8601 | ~70 lines |
| touch.zig parseIso8601 + parseTimestamp | ~120 lines |
| Common module addition | ~110 lines |
| **Net reduction** | **~80 lines** |

**Agreement with GPT reviewer and Opus:** The timezone bug is already fixed in both implementations. The dedup is still valid on structural grounds — the two functions are ~75% similar. But urgency is lower than the original audit claimed.

**Bonus:** touch.zig has standalone calendar helpers (`daysFromYMD`, `isLeapYear`, `getDaysInMonth`) at lines 544-575 that should go into `common/time.zig` during this extraction.

**Effort:** Medium (1 day).
**Risk:** Low.

---

### #9 — Exit Code 2→1 Convention Fix
**Verified score: ~20 lines changed across 6 utilities (not 8)**

| Utility | Verified? |
|---------|-----------|
| sleep | ✅ |
| seq | ✅ |
| date | ✅ |
| dd | ✅ |
| printf | ✅ |
| whoami | ✅ |
| yes | ❌ **Empty file** — can't have exit code bug |
| free | ❌ **Empty file** — can't have exit code bug |

**Opus and the Roadmap both listed 8 utilities including yes and free.** These files are 0 bytes. This is a credibility issue: nobody checked whether the files existed before including them in the list. Actual count: 6 utilities.

**Effort:** Trivial (15 minutes).
**Risk:** Zero.

---

### #10 — Backup Suffix Env Var Fix (Inline)
**Verified score: 2 bug fixes, ~2 lines per file**

| Utility | Bug | Fix |
|---------|-----|-----|
| cp.zig | Ignores `SIMPLE_BACKUP_SUFFIX` env var | Add `std.posix.getenv(...)` before default |
| mv.zig | Ignores `SIMPLE_BACKUP_SUFFIX` env var | Add `std.posix.getenv(...)` before default |
| ln.zig | ✅ Already reads it correctly | N/A |

**Agreement with Opus and GPT reviewer:** This is a 2-line fix, not a module extraction. Do NOT create `common/backup.zig`.

**Effort:** Trivial (15 minutes).
**Risk:** Zero.

---

## Part 2: Detailed Specifications for Top 3

### #1: `common/main.zig` — `utilityMain`

**Exact affected files:**
- **36 arena utilities:** basename, cat, cut, date, dd, df, dirname, du, echo, env, find, grep, head, id, ln, mktemp, mv, nl, printf, pwd, readlink, realpath, seq, sleep, sort, stat, tac, tail, tee, test, timeout, tr, uniq, wc, whoami, ls/main.zig
- **8 GPA utilities (migrate to arena):** chmod, chown, cp, mkdir, rm, rmdir, touch, ln
- **2 trivial (no change):** true, false
- **2 empty (skip):** free, yes

**Proposed API:**
```zig
// src/common/main.zig
pub fn utilityMain(
    comptime runFn: fn (std.mem.Allocator, []const []const u8, anytype, anytype) anyerror!u8,
) noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch
        std.process.exit(@intFromEnum(ExitCode.general_error));

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);

    const exit_code = runFn(allocator, args[1..], &stdout_writer.interface, &stderr_writer.interface) catch
        @intFromEnum(ExitCode.general_error);

    stdout_writer.interface.flush() catch {};
    stderr_writer.interface.flush() catch {};
    std.process.exit(exit_code);
}
```

**After refactoring, every utility becomes:**
```zig
pub fn main() noreturn {
    common.main.utilityMain(runBasename);
}
```

**Note on the argparse catch block:** I recommend NOT folding the argparse catch block into `utilityMain`. Reason: only 24 of 44 utilities use it, the catch block references the utility name (a per-utility string), and some utilities have custom parsers. Instead, create a separate `ArgParser.parseOrExit()` that 24 utilities call. This gives you two independent, composable extractions instead of one monolith.

**Design note on return type:** The current `main()` returns `!void` and uses `try` for argsAlloc. The wrapper must change this to `noreturn` and catch the error internally. This is a small but important API change.

### #2: `posixErrorString` Expansion

**Canonical function:** `src/common/lib.zig:131` — currently 15 mappings.

**Expansion plan:** Merge the superset from all 9 local functions. The union has ~32 unique error→string mappings. Add 17 new mappings to the canonical function.

**Rollout:** Delete 9 local functions, then find-replace 103 `@errorName(err)` → `common.posixErrorString(err)` sites.

### #3: `common/mode.zig` — Symbolic Mode Parser

**Extract from:** `src/chmod.zig` lines 566-797 (full parser with s/t/X/permission-copying)
**Delete from:** `src/mkdir.zig` lines 177-312 (subset parser)

**Proposed API:**
```zig
// src/common/mode.zig
pub const ModeContext = struct {
    is_directory: bool = false,
    current_mode: ?u32 = null,  // needed for X and permission-copying
};

pub fn parseMode(mode_str: []const u8, context: ModeContext) !u32 { ... }
pub fn parseOctalMode(mode_str: []const u8) !u32 { ... }
pub fn parseSymbolicMode(mode_str: []const u8, context: ModeContext) !u32 { ... }
```

mkdir calls with `ModeContext{}` (defaults). chmod calls with full context.

---

## Part 3: Where I AGREE with Opus

### 3.1 — `utilityMain` is #1
**Opus claim:** "The #1 insight the auditors collectively missed: main() boilerplate + argparse + help/version + printVersion form a composite pattern."

**My verdict:** ✅ **CORRECT.** Nobody else connected these into one extraction. Every auditor saw the pieces but not the whole. Opus's architectural insight here is the most valuable contribution in the entire audit chain.

### 3.2 — 5 modules should NOT be created
**Opus claim:** Skip overwrite.zig, numeric.zig, file_header.zig, backup.zig, and ArgParser custom-syntax extensions.

**My verdict:** ✅ **CORRECT on all 5.** The reasoning is sound for each:
- **overwrite.zig:** 4 utilities with genuinely different semantics (rm has 3 modes, ln has backup interaction). Fix bugs inline.
- **numeric.zig:** 5 parsers with genuinely different requirements (dd needs `c/w/b/NxN`, find returns a comparison struct). Kitchen-sink `NumericOptions` is worse than focused parsers.
- **file_header.zig:** 4 lines of `==> {s} <==\n`. Net +6 lines. Absurd.
- **backup.zig:** 3 callers, 2-line fix per file. Not a module.
- **ArgParser extensions for env/date:** These have genuinely unusual syntax. Adding callbacks makes ArgParser harder for 43 utilities that don't need them.

### 3.3 — Phase 0 functions having zero adopters is an execution failure
**Opus claim:** "This should be addressed immediately."

**My verdict:** ✅ **CORRECT.** `posixErrorString()` and `printTryHelp()` were created, tested, and never deployed. This is the most important process observation in the entire audit. It suggests the project lacks a rollout discipline: someone writes the common function, checks the box, and moves on without actually using it.

### 3.4 — GPT reviewer was the most valuable contributor
**Opus claim:** "The GPT reviewer correctly identified the ISO 8601 TZ bug as already-fixed, correctly caught mkdir's existing symbolic parser, and correctly flagged 4 over-engineered proposals."

**My verdict:** ✅ **CORRECT.** The DUPLICATION_REVIEW.md is the highest-signal document in the chain. It caught real errors in the DUPLICATION_REPORT and applied good judgment about what not to abstract.

### 3.5 — Symbolic mode extraction is high ROI
**Opus claim (sourced from GPT reviewer):** "~150 lines, real duplication."

**My verified count:** ~145 lines net. Close enough. ✅ **CORRECT.**

---

## Part 4: Where I DISAGREE with Opus

### 4.1 — Line count for `utilityMain` is inflated by ~50%

**Opus claim:** "~55 lines per utility × 45 utilities = ~2,475 lines"

**My counterargument:** Opus assumed all 45 utilities have all 4 components (main body, argparse catch, help/version check, printVersion). They don't.

| Component | Opus assumed | Actual verified count |
|-----------|-------------|----------------------|
| Utilities with `main()` | 45 | 45 (but 2 empty, 2 trivial = 41 real) |
| Utilities with argparse catch block | 45 | **24** |
| Utilities with `parsed_args.help` | 45 | **21** |
| Utilities with `printVersion` | 45 | **36** |

Calculating properly:
- main() body: 22 lines × 41 real utilities = **902 lines**
- argparse catch: 15 lines × 24 = **360 lines**
- help/version check: 5 lines × 21 = **105 lines**
- printVersion fn: 3 lines × 36 = **108 lines**
- **Total: ~1,475 lines** (before accounting for the ~60 lines of common code added)
- **Net: ~1,415 lines**

Still massive. Still #1 by 10×. But it's not 2,475. When planning work estimates, the gap between 1,400 and 2,475 is a full day of work. Get the numbers right.

### 4.2 — "free" and "yes" are listed as having exit code bugs

**Opus claim (via ROADMAP A4):** "Exit code 2→1 fix needed for: sleep, seq, yes, whoami, date, free, dd, printf"

**My counterargument:** `src/free.zig` and `src/yes.zig` are **empty files** (0 bytes). They cannot have exit code bugs. They cannot have any bugs. Two of the eight listed utilities don't exist. Actual count: **6 utilities**.

This is a recurring pattern: the audit reports list things without verifying the files exist. In an AI-generated codebase, empty placeholder files are common. Every claim should be verified against the actual source.

### 4.3 — `utilityMain` should NOT absorb the argparse catch block

**Opus claim:** "If `utilityMain` handles argparse errors, it can call `posixErrorString` internally. If it handles `--help` and `--version`, it can call `printTryHelp` on error paths."

**My counterargument:** Folding argparse error handling into `utilityMain` requires the wrapper to know:
1. The utility name (for error messages) — this is fine as a comptime parameter
2. The Args type — this means the wrapper must call `ArgParser.parse` internally
3. The help function — this means the wrapper must know the print-help function pointer
4. That the utility uses ArgParser at all — **echo, date, env, test** don't

This turns the wrapper from a simple "setup/teardown" function into a "framework" that prescribes the entire utility structure. Some utilities (echo) have no argparse at all. Others (date, env) have custom parsers. The wrapper would need escape hatches for these.

**Better approach:** Two composable extractions:
1. `common.main.utilityMain(runFn)` — just handles arena, args, buffers, flush, exit. Simple. Universal. 41 utilities.
2. `ArgParser.parseOrExit(T, allocator, args, prog_name, stderr)` — handles the catch block. 24 utilities call this inside their `runX` function.

These compose cleanly. The wrapper stays simple. Utilities that need custom parsers just don't call `parseOrExit`.

### 4.4 — The effort estimates are optimistic

**Opus claim:** "Total estimated effort: ~2 weeks of focused work"

**My counterargument:** The `utilityMain` refactoring alone touches 41 files. Each requires:
1. Change `main()` to call `common.main.utilityMain`
2. Verify the `runX` function signature matches the wrapper's expected type
3. Migrate GPA→Arena for 8 utilities
4. Handle the `main() !void` → `main() noreturn` return type change
5. Run tests for each utility

At ~15 minutes per utility (optimistic for a well-prepared developer), that's ~10 hours just for the mechanical part. Add the common module design, testing, edge cases (true/false/echo), and you're at 3–4 days for `utilityMain` alone.

The full scope (10 items) is more like **3 weeks** with proper TDD, not 2.

### 4.5 — "sort -R uses a fixed seed of 0" is overclaimed

**Opus claim (via ROADMAP):** "Arguably CRITICAL, not IMPORTANT"

**My counterargument:** If nobody is using `sort -R` in production (likely, given this is a young project), the impact is zero. It's a correctness bug, but "CRITICAL" implies user-facing data loss or security. A deterministic shuffle is annoying, not critical. IMPORTANT is the right severity.

---

## Part 5: What is the Single Most Important Refactoring and Why?

### `utilityMain` — and I agree with Opus here.

**But my reasoning is different.**

Opus argues `utilityMain` is #1 because of raw line count. That's the weakest reason. The strongest reasons are:

1. **It's a forcing function for consistency.** Once the wrapper exists, new utilities get correct buffer sizes, proper flush-on-exit, consistent error handling for free. You can't accidentally forget to flush stderr. You can't accidentally use a 4096-byte buffer when everyone else uses 8192. The wrapper makes the right thing automatic.

2. **It resolves the GPA/Arena inconsistency.** 36 utilities use ArenaAllocator. 8 use GeneralPurposeAllocator. There's no good reason for the divergence in production code. The wrapper standardizes on Arena, which is correct for CLI tools. This eliminates a class of "which allocator do I use?" confusion.

3. **It creates the hook point for future cross-cutting concerns.** Signal handling, profiling, debug flags, POSIX locale setup — all of these would otherwise require touching 45 files. With `utilityMain`, they're one-line additions.

4. **It makes the `posixErrorString` and `printTryHelp` rollouts partially automatic.** The argparse catch block (via `parseOrExit`) can use `posixErrorString` internally. The help/version handling can incorporate `printTryHelp` on error paths. Two rollout problems get partial solutions for free.

If I could only do ONE thing, it would be this.

**If Opus and I differ on anything:** Opus treats the line count as the primary argument. I treat the architectural forcing function as the primary argument. The line count is a pleasant side effect, not the point.

---

## Part 6: What We Should NOT Do

### ❌ Do NOT create `common/overwrite.zig`
**Source:** ROADMAP D2, DUPLICATION_REPORT §3.2
**Why:** rm has `{force, interactive, interactive_once}`. ln has `{force, interactive}` + backup. cp has `{force, interactive, no_clobber}` + backup suffix. A shared enum would need per-utility variants, which is worse than no abstraction. Fix the 2 precedence bugs inline (mv `-n -f`, rm `-f -i`).

### ❌ Do NOT create `common/numeric.zig`
**Source:** ROADMAP D3, DUPLICATION_REPORT §3.4
**Why:** The 5 parsers have genuinely different requirements:
- dd needs `c/w/b` and `NxN` multiplication (POSIX)
- find returns `SizeExpr` struct (different return type)
- sort is 22 lines (not worth extracting)
- tail has the most complex suffix set (tail-specific)
- du/df already share `format.parseBlockSize`

A `NumericOptions{allow_si, allow_iec, allow_dd_suffixes, allow_multiplication}` is a worse API than 5 focused parsers. Just delete the thin wrappers in du.zig and df.zig (~10 lines).

### ❌ Do NOT create `common/file_header.zig`
**Source:** ROADMAP D4, DUPLICATION_REPORT §3.7
**Why:** 4 instances of `==> {s} <==\n`. Net +6 lines. A module, import, and function call for one format string is pure over-engineering.

### ❌ Do NOT create `common/backup.zig`
**Source:** DUPLICATION_REPORT §3.3
**Why:** 3 callers. The shared logic is 2 lines (read env var, default to `"~"`). Add the 2 lines to cp.zig and mv.zig. Done.

### ❌ Do NOT extend ArgParser for env/date custom syntax
**Source:** AUDIT_SYSTEM_INFO §2, AUDIT_UTIL_AGENT Architecture Issue #2
**Why:** env and date have genuinely unusual syntax (`NAME=VALUE`, `+FORMAT`). Adding `CustomParsing` hooks with `is_assignment_fn` and `on_assignment_fn` callbacks makes ArgParser harder to understand for the 43 utilities that don't need them. env and date's custom parsers are ~200 lines each, well-tested, and well-understood. Leave them.

### ❌ Do NOT tag 186 tests with `// PARSE-ONLY` comments
**Source:** ROADMAP G1
**Why:** Comments don't prevent false confidence. They're visual noise. Write the behavioral companion tests (G2) instead. The parse-only tests are fine as parser regression tests — they just shouldn't be the *only* tests.

### ⚠️ Be cautious with scope creep on `utilityMain`
The temptation will be to keep adding things to the wrapper: locale setup, signal handling, environment validation, custom allocator selection. Resist this. The wrapper should do exactly 5 things: allocator setup, arg parsing, buffer creation, flush, exit. Everything else belongs in the `runX` function or in a separate composable helper.

---

## Summary: Recommended Execution Order

| Phase | Task | Net Lines Impact | Effort | Deps |
|-------|------|-----------------|--------|------|
| **0a** | Write `common/main.zig` + `ArgParser.parseOrExit` | +80 common | 1 day | None |
| **0b** | Expand `posixErrorString` to 32 mappings | +17 common | 2 hours | None |
| **0c** | Fix crashes: mv panic, uniq crash, ln panic, head crash | Bug fixes | 2 days | None |
| **1a** | Migrate 41 utilities to `utilityMain` (8 GPA→Arena first) | -1,200 lines | 2 days | 0a |
| **1b** | Migrate 24 utilities to `parseOrExit` | -360 lines | 1 day | 0a |
| **1c** | Roll out `posixErrorString`: delete 9 locals + fix 103 `@errorName` sites | -113 lines | 1 day | 0b |
| **1d** | Roll out `printTryHelp` to 47 utilities | ~0 lines (consistency) | 0.5 day | 0a |
| **2a** | Extract `common/mode.zig` from chmod/mkdir | -145 lines | 1.5 days | None |
| **2b** | Fix path canonicalization (readlink -f, realpath, ".." past root) | Bug fixes | 1 day | None |
| **2c** | Fix permissions: chown user:, chmod umask, chmod -x, id -G | Bug fixes | 1.5 days | None |
| **3** | Merge ISO 8601 parsers into `common/time.zig` | -80 lines | 1 day | None |
| **4** | Exit code 2→1 for 6 utilities + backup env var for cp/mv | -0 + bug fixes | 30 min | None |

**Total estimated net reduction:** ~1,900 lines (~2.6% of codebase)
**Total estimated effort:** ~3 weeks with proper TDD

---

## Appendix: Disagreement Matrix with Opus

| Claim | Source | Opus's Verdict | My Verdict | Reason |
|-------|--------|---------------|-----------|--------|
| `utilityMain` saves ~2,475 lines | Opus | ✅ | ⚠️ **OVERCOUNTED** | Actual: ~1,200-1,400. Not all 45 utilities have all 4 components. 2 empty, 2 trivial, only 24 have argparse catch, only 21 have help check, only 36 have printVersion. |
| `utilityMain` should absorb argparse catch | Opus | ✅ | ❌ **DISAGREE** | Makes wrapper a framework. echo/date/env/test have no argparse. Keep as separate composable `parseOrExit`. |
| free.zig and yes.zig have exit code bugs | Opus via Roadmap | ✅ (listed) | ❌ **WRONG** | Both files are 0 bytes. Empty. |
| Total effort is ~2 weeks | Opus | ✅ | ⚠️ **OPTIMISTIC** | More like 3 weeks with TDD. 41-file migration alone is 2-3 days. |
| sort -R fixed seed is arguably CRITICAL | Opus | ✅ | ❌ **OVERCLAIMED** | IMPORTANT is correct. Deterministic shuffle ≠ data loss or security. |
| `@errorName` count is 107 | Opus | ✅ | ⚠️ **SLIGHTLY OFF** | My count: 103. Duplication Report: 114. All three are close but none match exactly. |
| 5 "do NOT create" modules | Opus | ❌ Skip | ✅ **AGREE** | All 5 rejections are correct and well-reasoned. |
| Symbolic mode extraction is high ROI | Opus, GPT reviewer | ✅ | ✅ **AGREE** | ~145 lines, real duplication, feature improvement for mkdir. |
| Phase 0 = execution failure | Opus | ✅ | ✅ **AGREE** | Zero adopters after creation = process gap, not design gap. |
| ISO 8601 TZ bug is already fixed | GPT reviewer | ✅ | ✅ **AGREE** | Both parsers handle TZ. Dedup still valid on structure. |
| GPA vs Arena inconsistency | Not flagged | — | ✅ **NEW** | 8 utilities use GPA, 36 use Arena. No good reason. Standardize on Arena. |
