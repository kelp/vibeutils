# Vibeutils Correctness Audit — Execution Plan

## Instructions for Claude Code

You are the orchestrator for a full correctness audit of
this project. Read this file completely before starting.

Run `--dangerously-skip-permissions` is assumed. Power
through without asking for permission.

## Problem

This project has a pattern of incomplete implementations:

- Flags parsed into structs but never used in logic
- Tests that verify parsing, not behavior
- Core features silently being no-ops (e.g., `tail -f`
  did nothing and exited silently)
- Coverage summary claims 100% MUST/SHOULD. We don't
  trust it.

## Goal

Independently verify every utility against specs. Find
every stub, every fake test, every behavioral
divergence. Write findings to report files.

## Rules

1. **GNU coreutils is the primary behavioral reference.**
   When a flag exists in GNU, match GNU semantics. For
   flags only in macOS/OpenBSD, follow that spec. For
   `stat`, we follow GNU. See `docs/specs/<util>-flags.md`
   for the per-utility flag matrix and tier assignments.
2. Do NOT trust the coverage summary
3. A flag that is parsed but doesn't change output is a
   **STUB** — severity CRITICAL
4. A test that verifies parsing but not behavior is a
   **STUB TEST** — severity CRITICAL
5. Agents MUST build and run utilities, not just read code
6. Compare output against system utilities where possible
   (on Linux: use GNU coreutils at `/usr/bin/<util>` as
   reference — GNU is our primary behavioral target.
   Check `docs/specs/<util>-flags.md` for the flag matrix)
7. Every MUST and SHOULD flag must get a verdict

## Orchestration

### Pre-Flight

Run these before starting any batch:

```bash
zig build
mkdir -p docs/audit
zig build test --summary all 2>&1 | tail -20
```

Record any pre-existing test failures.

### Batch Execution

Process 4 utilities per batch. For each utility, launch
3 background agents simultaneously (12 agents total per
batch). Wait for all 12 to complete before starting the
next batch.

Use the `Agent` tool with `run_in_background: true` for
all 12 agents in a single message. Use `subagent_type`:
`feature-dev:code-reviewer` for all agents.

### Batch Order

| Batch | Utilities | Why First |
|-------|-----------|-----------|
| 1  | find, ls, cp, grep | Largest, most flags |
| 2  | dd, sort, chmod, stat | Data transform, complex |
| 3  | tail, mv, rm, test | Known stub history |
| 4  | printf, tr, cut, date | Format strings |
| 5  | df, du, chown, touch | Filesystem metadata |
| 6  | ln, id, env, head | Links, identity |
| 7  | cat, wc, nl, uniq | Text utilities |
| 8  | tee, tac, mktemp, free | Streams, temp files |
| 9  | readlink, realpath, mkdir, rmdir | Path resolution |
| 10 | seq, echo, basename, dirname | Simple generators |
| 11 | timeout, pwd, sleep, whoami | Process control |
| 12 | yes, true, false, (re-audit) | Trivial + retries |

### After Each Batch

1. Verify all report files were written
2. Count CRITICAL/HIGH findings
3. Log batch completion

### After All Batches

Generate three summary files:
- `docs/audit/summary.md` — findings by severity
- `docs/audit/stub-report.md` — every stub flag found
- `docs/audit/remediation-plan.md` — prioritized fix list

---

## Agent Prompts

### Prompt: Code Review Agent

For each utility, copy this prompt and replace `{UTIL}`
with the utility name. For `ls`, replace `src/{UTIL}.zig`
with `src/ls/main.zig` and instruct the agent to also
read all files in `src/ls/`.

```
You are auditing the vibeutils implementation of {UTIL}.
Your job is to find stubs, incorrect behavior, and
divergences from specs. You are a code reviewer, not a
fixer. Report problems only.

GROUND RULES:
- Do NOT trust docs/specs/COVERAGE_SUMMARY.md
- GNU coreutils is the primary behavioral reference.
  For flags only in macOS/OpenBSD, follow that spec.
  Check docs/specs/{UTIL}-flags.md for the matrix.
- A parsed flag that doesn't change output is a STUB
  (CRITICAL severity)
- You MUST build and run the utility
- Read the GNU man page AND the flags matrix
- Every MUST/SHOULD flag must get a verdict

## Files to Read

1. src/{UTIL}.zig — the implementation
2. docs/specs/{UTIL}-flags.md — flag coverage matrix
3. docs/specs/{UTIL}-macos.txt — macOS man page (for macOS-only flags)
4. docs/specs/{UTIL}-posix.txt — POSIX spec
5. docs/specs/{UTIL}-gnu.txt — GNU reference

## What to Check

### Flag-by-Flag Audit
For each flag marked MUST or SHOULD in the flags.md:
1. Find where it's parsed in the argument struct
2. Grep for the struct field name AFTER the parsing section
3. Trace the code path — does the flag actually change
   program behavior?
4. If the field is only in help text or never read: STUB
5. If read but conditional body is empty/TODO: STUB
6. If behavior doesn't match the governing spec per the
   flags matrix: INCORRECT

### Core Behavior
- Does the utility do its primary job correctly?
- stdin handling (filter utils must read stdin with no args)
- Does `-` work as stdin placeholder (if spec says so)?
- Exit codes: 0=success, 1=error, 2=misuse
- Partial failure: e.g., `cat good.txt missing.txt` should
  output good.txt AND exit 1

### I/O Correctness
- Uses `.writerStreaming()` not `.writer()`
- 8192-byte buffers
- Flushes before exit
- Errors to stderr, output to stdout

### Dynamic Verification
Build and run the utility:
```bash
zig build -Dutil={UTIL} 2>/dev/null || zig build
./zig-out/bin/{UTIL} --help
./zig-out/bin/{UTIL} --version
```

For each MUST flag, construct a test command and run it.
Also run the same command with the system utility
(`/usr/bin/{UTIL}` or equivalent). Compare outputs.

Run at least these edge cases:
- No arguments
- Invalid flags
- Nonexistent files
- Empty files
- Permission denied (create a file, chmod 000 it)

### Spec Compliance
For flags in GNU, verify behavior matches GNU. For
flags only in macOS/OpenBSD, verify behavior matches
that spec. Check the flags matrix to determine which
spec governs each flag.

## Report Format

Write your report to: docs/audit/{UTIL}-code.md

```markdown
# Code Audit: {UTIL}

**Date**: {today}
**Source**: src/{UTIL}.zig
**Specs**: {UTIL}-posix.txt, {UTIL}-gnu.txt, {UTIL}-macos.txt

## Executive Summary

PASS / PASS WITH ISSUES / FAIL
<1-3 sentence explanation>

## Flag-by-Flag Compliance

| Flag | Tier | Parsed? | Implemented? | Correct? | Notes |
|------|------|---------|-------------|----------|-------|

### Stubs Found
<List every flag parsed but not implemented. Include
the line number where the field is defined and evidence
it's unused.>

### Incorrect Behavior
<For each wrong behavior: what spec says, what code
does, how to reproduce.>

## Core Behavior Issues
<stdin, exit codes, error messages, partial failure>

## I/O Issues
<writer type, buffer size, flush, stderr vs stdout>

## Dynamic Verification
<Commands run, outputs compared, divergences found>

## Findings

| ID | Severity | Category | Description |
|----|----------|----------|-------------|
| C1 | CRITICAL | stub | -X flag parsed but never used |

Severity: CRITICAL (no-op/silent wrong), HIGH (wrong
behavior), MEDIUM (edge case), LOW (style)
```
```

### Prompt: Unit Test Review Agent

```
You are auditing the unit tests for the vibeutils {UTIL}
utility. Your job is to find tests that don't actually
verify behavior — parse-only tests, tests that can't
fail, and missing coverage.

GROUND RULES:
- A test that asserts `parsed.flag == true` without
  verifying program output is a STUB TEST (CRITICAL)
- Every MUST/SHOULD flag should have a behavioral test
- Tests must use `testing.allocator` for leak detection
- Filter utilities must use `runUtilWithInput()` pattern

## Files to Read

1. src/{UTIL}.zig — implementation AND embedded tests
   (tests are in `test` blocks at the bottom)
2. docs/specs/{UTIL}-flags.md — what flags exist
3. docs/specs/{UTIL}-macos.txt — expected behavior

## What to Check

### Test Inventory
List every `test "..."` block. For each one:
- What does it claim to test?
- Does it test BEHAVIOR (program output changes) or
  PARSING (struct field values)?
- Could it pass with a completely wrong implementation?
- Is the expected value correct per the governing spec?

### Parse-Only Tests (the primary target)
These are the #1 problem in this codebase. A parse-only
test looks like:

```zig
test "follow flag" {
    const args = parseArgs(&.{"-f"});
    try testing.expect(args.follow == true);
}
```

This ONLY verifies the argument parser. It does NOT
verify that the program actually follows the file.
Flag every such test as CRITICAL.

### Coverage Gaps
Cross-reference every MUST/SHOULD flag in flags.md
against the test list:
- Flag has no test at all → CRITICAL
- Flag has parse-only test → CRITICAL
- Flag has behavioral test → GOOD
- Flag has behavioral test but wrong expected value → HIGH

### Assertion Quality
- Tests with tautological assertions (always true)
- Tests checking the wrong thing (name says X, tests Y)
- Tests with hardcoded values that could drift

### Filter Utility Check
If {UTIL} reads stdin (cat, head, tail, sort, uniq, tr,
cut, tee, tac, wc, nl, grep):
- Do any tests risk hanging on stdin?
- Is `runUtilWithInput()` used correctly?

### Run the Tests
```bash
zig build test --summary all 2>&1 | grep -i "{UTIL}"
```
Report which tests pass/fail and execution time.

## Report Format

Write to: docs/audit/{UTIL}-unit-tests.md

```markdown
# Unit Test Audit: {UTIL}

**Date**: {today}
**Source**: src/{UTIL}.zig

## Executive Summary

PASS / PASS WITH ISSUES / FAIL
<1-3 sentences>

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|----------------|---------|
| "follow flag" | NO — parse only | STUB TEST |
| "tail last 5 lines" | YES | GOOD |

## Parse-Only Tests (CRITICAL)
<Every test that checks struct fields instead of output>

## Missing Coverage

| Flag | Tier | Has Test? | Test Type |
|------|------|-----------|-----------|
| -f   | MUST | yes       | parse-only (INSUFFICIENT) |
| -r   | MUST | no        | MISSING |

## Other Issues
<Hang risks, wrong allocator, tautological assertions>

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| U1 | CRITICAL | -f test only checks parsing |
```
```

### Prompt: Integration Test Review Agent

```
You are auditing the integration tests for vibeutils
{UTIL}. Your job is to find tests that verify flag
existence rather than behavior, and identify missing
test coverage.

GROUND RULES:
- A test using only `test_command_succeeds` or
  `test_command_exit_code` without output verification
  can pass even if the flag is a complete no-op
- Every MUST/SHOULD flag should have an output-verifying
  integration test
- Expected outputs must match spec behavior

## Test Infrastructure

The test framework (tests/lib/common.sh) provides:
- `test_command_output "name" "expected" cmd args` —
  verifies stdout matches expected (STRONG)
- `test_command_output_exact "name" "expected" cmd args` —
  byte-exact comparison (STRONGEST)
- `test_command_output_pattern "name" "regex" cmd args` —
  regex match (MODERATE)
- `test_command_exit_code "name" CODE cmd args` —
  exit code only (WEAK — no output check)
- `test_command_succeeds "name" cmd args` —
  just checks exit 0 (WEAKEST)
- `test_command_fails "name" cmd args` —
  just checks exit != 0 (WEAK)

## Files to Read

1. tests/utilities/{UTIL}_test.sh — the integration tests
2. docs/specs/{UTIL}-flags.md — what flags exist
3. docs/specs/{UTIL}-macos.txt — expected behavior
4. docs/specs/{UTIL}-gnu.txt — GNU behavior for reference
5. tests/lib/common.sh — test framework (skim for context)

## What to Check

### Test Inventory
List every test in the file. Classify each:
- OUTPUT: uses test_command_output/exact/pattern (STRONG)
- EXIT_ONLY: uses test_command_exit_code/succeeds/fails
  (WEAK — flag could be a no-op and still pass)
- EXISTENCE: just checks --help mentions the flag (USELESS)

### Weak Test Detection (primary target)
For each test using exit-code-only checking:
- Could this test pass if the flag were a complete no-op
  that just returns 0?
- If yes, it's a weak test. Severity HIGH.

### Coverage Gaps
Cross-reference MUST/SHOULD flags against tests:
- Flag has output-verifying test → GOOD
- Flag has exit-code-only test → WEAK (HIGH severity)
- Flag has no integration test → MISSING (HIGH severity)

### Expected Output Correctness
For tests that DO verify output:
- Is the expected output correct per the governing spec?
- Does it account for platform differences?
- Are trailing newlines handled correctly?

### Run the Tests
```bash
just it-util {UTIL} 2>&1
```
Report results. If tests fail, that's a finding.

### System Comparison
For key flags, run the same command with both:
```bash
./zig-out/bin/{UTIL} <args>
/usr/bin/{UTIL} <args>  # system utility
```
Note: on Linux, system utils are GNU. Check the macOS
flag matrix for which spec governs each flag.

### Missing Scenarios
Read docs/specs/{UTIL}-macos.txt end-to-end. For each
described behavior, check if a test exists. List all
untested behaviors.

## Report Format

Write to: docs/audit/{UTIL}-integration-tests.md

```markdown
# Integration Test Audit: {UTIL}

**Date**: {today}
**Test file**: tests/utilities/{UTIL}_test.sh

## Executive Summary

PASS / PASS WITH ISSUES / FAIL
<1-3 sentences>

## Test Inventory

| Test | Verification Type | Verdict |
|------|------------------|---------|
| "basic output" | OUTPUT (strong) | GOOD |
| "flag -z works" | EXIT_ONLY (weak) | WEAK TEST |

## Weak Tests (exit-code only, no output check)
<List every test that only checks exit code>

## Missing Coverage

| Flag | Tier | Has Integration Test? | Strength |
|------|------|--------------------- |----------|
| -f   | MUST | yes | WEAK (exit only) |
| -r   | MUST | no  | MISSING |

## Expected Output Issues
<Tests with wrong expected values>

## System Comparison
<Commands run, divergences found>

## Missing Test Scenarios
<Behaviors described in governing spec with no test>

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| I1 | HIGH | -z test only checks exit code |
```
```

---

## Special Cases

### ls (Batch 1)
Source is split across `src/ls/main.zig`, `src/ls/core.zig`,
`src/ls/display.zig`, `src/ls/formatter.zig`,
`src/ls/sorter.zig`, `src/ls/types.zig`, etc. Code review
agent must read ALL files in `src/ls/` and trace flags
across module boundaries.

### test / [ (Batch 3)
Two entry points, same implementation. Verify `[` binary
exists and requires closing `]`. Check both
`tests/utilities/test_test.sh` and
`tests/utilities/[_test.sh`.

### stat (Batch 2)
BSD and GNU have different default output formats and
different `-f` flag semantics. Implementation must follow
macOS (BSD) behavior.

### Filter utilities
These read stdin: cat, head, tail, sort, uniq, tr, cut,
tee, tac, wc, nl, grep. Unit test agents must check for
hang risks. Integration test agents should verify stdin
piping works.

---

## Orchestrator Workflow (step by step)

1. Run pre-flight commands
2. For batch 1 (find, ls, cp, grep):
   - Launch 12 background agents (3 per utility) in a
     single message with 12 Agent tool calls
   - Wait for all to complete
   - Verify 12 report files exist in docs/audit/
   - Log any failures
3. Repeat for batches 2-12
4. After all batches: generate summary files
5. Report total findings to user

### Agent Launch Template

For each utility in the batch, launch 3 agents:

```
Agent(description="audit {UTIL} code",
      subagent_type="feature-dev:code-reviewer",
      run_in_background=true,
      prompt=<code review prompt with {UTIL} filled in>)

Agent(description="audit {UTIL} unit tests",
      subagent_type="feature-dev:code-reviewer",
      run_in_background=true,
      prompt=<unit test prompt with {UTIL} filled in>)

Agent(description="audit {UTIL} integration tests",
      subagent_type="feature-dev:code-reviewer",
      run_in_background=true,
      prompt=<integration test prompt with {UTIL} filled in>)
```

### Severity Definitions

- **CRITICAL**: Feature is a no-op, silently wrong, or test
  verifies nothing. This is what the audit exists to find.
- **HIGH**: Incorrect behavior users will encounter, or
  missing test coverage for a MUST flag.
- **MEDIUM**: Edge case bugs, resource management issues.
- **LOW**: Style deviations, minor spec divergences.
