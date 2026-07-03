export const meta = {
  name: 'tdd-bugfix',
  description:
    'Classic red-green TDD pipeline for one bug fix. Phase "red": scout the bug site, pin the reference (GNU) behavior on the Linux VM, write FAILING tests, review them to APPROVED, verify RED for the right reason on macOS AND Linux. Phase "green": implement the minimal fix, then loop scoped verify + Tiger check + code review until green, ending with the full suites on both platforms. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Fixing a behavior bug in a vibeutils utility where a natural failing test exists (GNU-parity divergences, wrong output, wrong exit code). Dispatch twice per bug: phase:"red", commit the tests, phase:"green", commit the fix. For behavior-preserving refactors use tdd-pipeline instead.',
  phases: [
    { title: 'Scout', detail: 'distill bug site + pin GNU behavior on orb ubuntu (sonnet)' },
    { title: 'Author tests', detail: 'write FAILING tests asserting pinned behavior (opus, tdd-pipeline:test-writer)' },
    { title: 'Review tests', detail: 'loop test-reviewer until APPROVED (opus)' },
    { title: 'Red check', detail: 'red for the RIGHT reason, macOS + Linux; rest of suite green (sonnet)' },
    { title: 'Implement', detail: 'minimal fix, scoped quiet checks (opus, tdd-pipeline:implementer)' },
    { title: 'Verify gate', detail: 'SCOPED: util unit + util integration + lint (haiku)' },
    { title: 'Tiger check', detail: 'scan for NEW Tiger Style violations, triage dual-use, fix (haiku/sonnet)' },
    { title: 'Code review', detail: 'loop code-reviewer until APPROVED (opus)' },
    { title: 'Final verify', detail: 'ONCE: full unit + privileged + integration on macOS AND Linux (haiku)' },
  ],
};

// ---------------------------------------------------------------------------
// Inputs (args)
// ---------------------------------------------------------------------------
// {
//   utility, issue, bug_summary, expected_behavior,
//   impl_files[],   // implementation code the implementer may edit
//   test_files[],   // files the test-writer may edit (embedded test blocks + integration .sh)
//   gnu_pin_cmds[], // shell commands to run on the Linux VM to pin GNU behavior
//   behaviors[],    // behaviors the tests must cover
//   test_cmd, privileged_test_cmd, util_test_cmd, it_cmd, fmt_cmd, full_it_cmd,
//   linux_prefix,   // e.g. "orb -m ubuntu" — how to run a command on the Linux VM
//   phase: "red" | "green",
//   briefing: <object returned by the red phase, fed back into green>
// }

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
log(`args: type=${typeof args} utility=${a.utility || 'MISSING'} issue=${a.issue || '?'} behaviors=${(a.behaviors || []).length}`);
const phaseArg = a.phase || 'red';

const REVIEW_ROUND_MAX = 12;
const GATE_FIX_MAX = 4;

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['bug_site', 'gnu_behavior', 'test_conventions', 'notes'],
  properties: {
    bug_site: {
      type: 'string',
      description:
        'The buggy code: exact file:line references, the relevant function signatures and code excerpts (copy real code, do not paraphrase), and how the buggy path is reached (flags, input conditions).',
    },
    gnu_behavior: {
      type: 'string',
      description:
        'The pinned reference behavior: the EXACT commands run on the Linux VM, their verbatim stdout/stderr and exit codes, and the GNU coreutils version. This is the spec the tests assert. If a pin command could not reproduce the scenario, say so explicitly and quote the issue text as fallback.',
    },
    test_conventions: {
      type: 'string',
      description:
        'What a test author needs without exploring: where embedded unit tests live in the target file (with an excerpt of a nearby existing test to copy the style of), the integration test file and its helper functions (print_test_result, run_with_limit, TEMP_DIR usage), exact scoped test commands, and the privileged/fakeroot rules if relevant.',
    },
    notes: {
      type: 'string',
      description:
        'Anything else downstream agents need: platform differences observed (macOS vs Linux errno/text), pitfalls in the code path, related existing tests that must stay green.',
    },
  },
};

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['assessment', 'issues', 'summary'],
  properties: {
    assessment: { type: 'string', enum: ['APPROVED', 'NEEDS_FIXES'] },
    summary: { type: 'string' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'location', 'description'],
        properties: {
          severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
          location: { type: 'string' },
          description: { type: 'string' },
        },
      },
    },
  },
};

// Red check: the bug-fix substitute for tdd-pipeline's sabotage stage. A
// natural RED proves the tests have teeth; this stage proves the RED is real,
// for the right reason, on both platforms, and that nothing else broke.
const REDCHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['red_macos', 'right_reason', 'rest_green', 'red_linux', 'summary', 'output_excerpt'],
  properties: {
    red_macos: { type: 'boolean', description: 'the new tests FAIL on current code on macOS' },
    right_reason: {
      type: 'boolean',
      description:
        'the failure is the intended assertion mismatch (the bug), NOT a compile error, crash, harness bug, or skip',
    },
    rest_green: {
      type: 'boolean',
      description: 'every pre-existing test still passes; the ONLY failures are the newly added tests',
    },
    red_linux: { type: 'boolean', description: 'the new tests also FAIL on the Linux VM' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string', description: 'the failing assertions verbatim (short)' },
  },
};

const VERIFY_GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'true if the scoped util_test_cmd unit check passes' },
    integration_pass: { type: 'boolean', description: 'true if the scoped it_cmd integration suite passes' },
    lint_clean: { type: 'boolean', description: 'true if fmt-check passes' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'privileged_pass', 'integration_pass', 'linux_unit_pass', 'linux_integration_pass', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'true if the FULL unit suite (test_cmd) passes on macOS' },
    privileged_pass: { type: 'boolean', description: 'true if the FULL privileged suite passes on macOS' },
    integration_pass: { type: 'boolean', description: 'true if the FULL integration suite (full_it_cmd) passes on macOS' },
    linux_unit_pass: { type: 'boolean', description: 'true if the full unit suite passes on the Linux VM' },
    linux_integration_pass: {
      type: 'boolean',
      description: 'true if the scoped integration suite for this utility passes on the Linux VM',
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const TIGER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clean', 'new_violations', 'preexisting_count', 'filtered', 'summary', 'output_excerpt'],
  properties: {
    clean: {
      type: 'boolean',
      description: 'true iff there are no confirmed NEW Tiger Style violations after triage',
    },
    new_violations: {
      type: 'array',
      description: 'confirmed NEW violations introduced by this change; these BLOCK until fixed',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rule', 'location', 'detail'],
        properties: {
          rule: {
            type: 'string',
            description:
              'one of: long-line, long-fn, self-recursion, compound-assert, unbounded-loop, usize-arch',
          },
          location: { type: 'string', description: 'file:line as reported by the scanner' },
          detail: { type: 'string', description: 'the scanner detail field (e.g. width=128, fn=NAME)' },
        },
      },
    },
    preexisting_count: {
      type: 'integer',
      description: 'count of PRE-existing violations the scanner reported (reported, not blocking)',
    },
    filtered: {
      type: 'array',
      description: 'candidate violations dismissed as legitimate dual-use, with the reason',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['location', 'why'],
        properties: {
          location: { type: 'string', description: 'file:line of the dismissed candidate' },
          why: {
            type: 'string',
            description:
              'why it is legitimate (e.g. usize required by a std API; while(true) bounded by a break+assert)',
          },
        },
      },
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string', description: 'a short excerpt of the scanner stdout' },
  },
};

const IMPLEMENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['outcome', 'summary'],
  properties: {
    outcome: {
      type: 'string',
      enum: ['done', 'needs_test_change'],
      description:
        "'done' = implementation complete against the existing tests. 'needs_test_change' = a test is wrong (over-constrained, asserts an unspecified detail, or contradicts the pinned GNU behavior) and must be fixed by the test-writer before the code can be correct.",
    },
    summary: { type: 'string' },
    test_change_instructions: {
      type: 'string',
      description:
        'When outcome=needs_test_change: name the exact test(s), why each is wrong, and what the correct assertion should be. Empty when outcome=done.',
    },
  },
};

const TESTFIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['changed', 'summary'],
  properties: {
    changed: {
      type: 'boolean',
      description:
        'true if the test was genuinely wrong and you fixed it (still with teeth); false if the test is correct and the implementation must change instead.',
    },
    summary: {
      type: 'string',
      description: 'What you changed and why, or why the test stands and the code must change.',
    },
  },
};

// ---------------------------------------------------------------------------
// Briefing helpers
// ---------------------------------------------------------------------------
function formatBriefing(b) {
  return [
    '## SHARED BRIEFING (do not re-explore unless something below is missing)',
    '',
    '### Bug site',
    b.bug_site,
    '',
    '### Pinned reference (GNU) behavior — this is the spec',
    b.gnu_behavior,
    '',
    '### Test conventions',
    b.test_conventions,
    '',
    '### Notes',
    b.notes,
  ].join('\n');
}

function taskHeader() {
  return [
    `Utility: ${a.utility}`,
    `Issue: #${a.issue}`,
    `Bug: ${a.bug_summary}`,
    `Expected behavior (GNU): ${a.expected_behavior}`,
    `Implementation files (implementer edits ONLY these): ${(a.impl_files || []).join(', ')}`,
    `Test files (test-writer edits ONLY these): ${(a.test_files || []).join(', ')}`,
    `Behaviors the tests must cover:\n- ${(a.behaviors || []).join('\n- ')}`,
  ].join('\n');
}

function reviewFeedback(review) {
  const lines = (review.issues || []).map(
    (i) => `- [${i.severity}] ${i.location}: ${i.description}`,
  );
  return [`Reviewer assessment: ${review.assessment}`, review.summary, '', 'Fix every issue below:', ...lines].join('\n');
}

async function scoutBriefing() {
  phase('Scout');
  return await agent(
    [
      'You are scouting a vibeutils bug fix so downstream agents never have to explore.',
      'Copy EXACT code excerpts and signatures; do not paraphrase.',
      '',
      taskHeader(),
      '',
      'Do all of the following:',
      `1. Read the bug site in ${(a.impl_files || []).join(', ')} and distill it (file:line, code excerpts,`,
      '   how the buggy path is reached).',
      `2. Pin the reference behavior: run each of these commands on the Linux VM and record verbatim`,
      '   output and exit codes (also record the GNU coreutils version with --version):',
      ...(a.gnu_pin_cmds || []).map((c) => `     ${a.linux_prefix} ${c}`),
      '   If a command cannot reproduce the scenario, say so explicitly rather than inventing output.',
      `3. Distill test conventions from ${(a.test_files || []).join(', ')}: where embedded unit tests live,`,
      '   an excerpt of a nearby test to copy the style of, the integration helpers',
      '   (print_test_result, run_with_limit, TEMP_DIR), and the exact scoped test commands:',
      `     scoped unit: ${a.util_test_cmd}`,
      `     scoped integration: ${a.it_cmd}`,
      '4. Note platform differences you observe (macOS vs Linux errno text) and nearby tests that must stay green.',
      'Also read CLAUDE.md sections on testing and Tiger Style if you need the rules.',
    ].join('\n'),
    { label: `scout:${a.utility}#${a.issue}`, phase: 'Scout', model: 'sonnet', schema: BRIEFING_SCHEMA },
  );
}

async function routeTestChange(brief, instructions, hop, phaseName) {
  return await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — adjudicate an implementer test-change request',
      taskHeader(),
      '',
      'The implementer reports that a TEST must change rather than the implementation. Judge that FIRST by',
      'reading the test, the behavior it guards, and the pinned GNU behavior in the briefing:',
      '  - If the test is genuinely WRONG (over-constrained, asserts an unspecified detail, or contradicts',
      '    the pinned GNU behavior), fix it — and keep it with TEETH: it must still fail if the guarded',
      '    behavior regresses. Set changed=true and describe the fix.',
      '  - If the test is CORRECT, do NOT change it. Set changed=false and explain why the implementation,',
      '    not the test, must change. The implementer will then be told to fix the code.',
      '',
      `Implementer's request:\n${instructions}`,
      '',
      `Edit ONLY test code in ${(a.test_files || []).join(', ')}; do not touch implementation logic.`,
      'Run `just fmt`. Do NOT commit.',
    ].join('\n'),
    {
      label: `test-writer:${a.utility}#adjudicate${hop}`,
      phase: phaseName,
      model: 'opus',
      agentType: 'tdd-pipeline:test-writer',
      schema: TESTFIX_SCHEMA,
    },
  );
}

async function runImplementer(promptText, label, phaseName, brief) {
  let result = await agent(promptText, {
    label,
    phase: phaseName,
    model: 'opus',
    agentType: 'tdd-pipeline:implementer',
    schema: IMPLEMENT_SCHEMA,
  });
  let tests_changed = false;
  let hop = 0;
  while (result.outcome === 'needs_test_change' && hop < GATE_FIX_MAX) {
    hop += 1;
    const verdict = await routeTestChange(brief, result.test_change_instructions || '', hop, phaseName);
    if (verdict.changed) {
      tests_changed = true;
    }
    log(`implementer requested a test change (hop ${hop}); test-writer changed=${verdict.changed}`);
    result = await agent(
      [
        brief,
        '',
        '## YOUR TASK (implementer, after the test-writer adjudicated)',
        taskHeader(),
        '',
        `Your earlier summary: ${result.summary}`,
        `Test-writer changed the test: ${verdict.changed}`,
        `Test-writer note: ${verdict.summary}`,
        verdict.changed
          ? 'The test was updated. Make the implementation pass against the UPDATED tests.'
          : 'The test-writer judged the test CORRECT and did not change it. Do NOT request another test change for this issue — fix the IMPLEMENTATION to satisfy the existing test.',
        '',
        `Edit ONLY implementation code in ${(a.impl_files || []).join(', ')}. Run \`just fmt\`. Do NOT commit.`,
        'Return your outcome.',
      ].join('\n'),
      {
        label: `${label}#aftertest${hop}`,
        phase: phaseName,
        model: 'opus',
        agentType: 'tdd-pipeline:implementer',
        schema: IMPLEMENT_SCHEMA,
      },
    );
  }
  return { result, tests_changed };
}

// ---------------------------------------------------------------------------
// RED phase: failing tests that pin the reference behavior
// ---------------------------------------------------------------------------
async function runRed() {
  const briefing = await scoutBriefing();
  const brief = formatBriefing(briefing);

  phase('Author tests');
  let testNote = await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — FAILING tests for a bug fix',
      taskHeader(),
      '',
      'This is a classic red-green bug fix. Write tests that assert the PINNED GNU behavior from the',
      'briefing — they must FAIL on the current (buggy) code and will pass once the bug is fixed.',
      '- Do NOT touch or rewrite existing tests; they remain the regression net.',
      '- Assert the reference behavior EXACTLY as pinned (output text, exit codes) — no weaker proxies.',
      '- Each test must fail for the RIGHT reason: the assertion matching the bug, not a compile error,',
      '  crash, or harness bug. Run the new tests and CONFIRM the failure message is the intended one.',
      '- Cover every behavior listed above; prefer a unit test where the code path is directly reachable',
      '  plus an integration test for the user-visible behavior.',
      '- Confirm every PRE-existing test still passes (scoped run) — the new tests are the only reds.',
      '',
      `Run the scoped checks: \`${a.util_test_cmd}\` and \`${a.it_cmd}\`, piped through \`tail\` to keep`,
      'output short. Do NOT run the full suite.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY: ${(a.test_files || []).join(', ')}. Only test code — do NOT change`,
      '    implementation logic, other sources, TODO.md, or build files.',
      '  - DO run `just fmt` to fix formatting.',
      '  - Do NOT commit. Return a short summary: each test added, where it lives, the behavior it guards,',
      '    and the exact failure message you observed (proof of red-for-the-right-reason).',
    ].join('\n'),
    { label: `test-writer:${a.utility}#${a.issue}`, phase: 'Author tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
  );

  phase('Review tests');
  let testReview = null;
  let round = 0;
  while (round < REVIEW_ROUND_MAX) {
    round += 1;
    testReview = await agent(
      [
        brief,
        '',
        '## YOUR TASK (test-reviewer)',
        taskHeader(),
        '',
        `Review the failing tests just added to ${(a.test_files || []).join(', ')}. Check: every listed`,
        'behavior is covered; each test asserts the PINNED GNU behavior from the briefing exactly (not a',
        'weaker proxy); the tests will fail on the current buggy code for the right reason and will pass',
        'once the behavior is fixed; no tautologies; no changes to implementation code snuck in.',
        'Judge BY READING AND REASONING ONLY — do NOT run the suite or modify anything; a separate red-check',
        'stage verifies the red empirically. Return APPROVED only when nothing remains.',
      ].join('\n'),
      { label: `test-review:${a.utility}#${round}`, phase: 'Review tests', model: 'opus', schema: REVIEW_SCHEMA },
    );
    log(`test review round ${round}: ${testReview.assessment} (${(testReview.issues || []).length} issues)`);
    if (testReview.assessment === 'APPROVED') break;

    testNote = await agent(
      [
        brief,
        '',
        '## YOUR TASK (test-writer, fix round)',
        taskHeader(),
        '',
        `Your earlier summary: ${testNote}`,
        '',
        reviewFeedback(testReview),
        '',
        'Apply every fix; the tests must still FAIL on current code for the right reason. Do NOT commit.',
        'Return a short summary.',
      ].join('\n'),
      { label: `test-writer:${a.utility}#fix${round}`, phase: 'Review tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
    );
  }
  if (testReview.assessment !== 'APPROVED') {
    log(`WARNING: test review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED — surfacing for human review.`);
  }

  // Red check: prove the red is real, for the right reason, on both platforms.
  phase('Red check');
  const redCheck = await agent(
    [
      '## YOUR TASK (red check — run and report only)',
      taskHeader(),
      '',
      'Verify the newly added tests are RED for the RIGHT reason. Run each step EXACTLY as given and',
      'report facts only; do NOT edit anything.',
      `1. macOS scoped unit: \`${a.util_test_cmd}\` — confirm the ONLY failures are the newly added tests`,
      '   and each failure message is the intended assertion (the bug), not a compile error or crash.',
      `2. macOS scoped integration: \`${a.it_cmd}\` — same standard (new cases fail, old cases pass).`,
      `3. Linux: \`${a.linux_prefix} zig build\` then the scoped unit and integration equivalents:`,
      `   \`${a.linux_prefix} zig build test -Dtest-util=${a.utility}\` and`,
      `   \`${a.linux_prefix} bash tests/integration.sh ${a.utility}\` — confirm the same red.`,
      '   (The VM has zig but not just.)',
      'Pipe verbose output through `tail`. red_macos/red_linux = new tests fail there; right_reason = the',
      'failure is the intended assertion mismatch; rest_green = everything else passes.',
    ].join('\n'),
    { label: `red-check:${a.utility}#${a.issue}`, phase: 'Red check', model: 'sonnet', schema: REDCHECK_SCHEMA },
  );
  log(`red check: macos=${redCheck.red_macos} reason=${redCheck.right_reason} rest=${redCheck.rest_green} linux=${redCheck.red_linux}`);

  return {
    phase: 'red',
    utility: a.utility,
    issue: a.issue,
    briefing,
    test_summary: testNote,
    test_review: testReview,
    red_check: redCheck,
    ready_to_commit_red:
      testReview.assessment === 'APPROVED' &&
      !!(redCheck && redCheck.red_macos && redCheck.right_reason && redCheck.rest_green && redCheck.red_linux),
  };
}

// ---------------------------------------------------------------------------
// GREEN phase: minimal fix, keep everything green
// ---------------------------------------------------------------------------
async function runGreen() {
  const briefing = a.briefing || (await scoutBriefing());
  const brief = formatBriefing(briefing);

  phase('Implement');
  let testsChangedDuringGreen = false;
  let impl = await runImplementer(
    [
      brief,
      '',
      '## YOUR TASK (implementer) — minimal bug fix',
      taskHeader(),
      '',
      'Failing tests already pin the correct (GNU) behavior. Make them pass with the MINIMAL correct fix.',
      'Fix the root cause; do not special-case around the tests. ALL pre-existing tests must stay green.',
      'Honor Tiger Style: 2+ assertions per function, no recursion, bounded loops, 70-line/100-col limits.',
      '',
      'For your own iteration, use only FAST, SCOPED, QUIET checks — a compile check (`zig build`) and at',
      `most \`${a.util_test_cmd}\` and \`${a.it_cmd}\`, piped through \`tail\`. Do NOT run the full suite,`,
      'the privileged/fakeroot suite, or the full integration suite yourself — a dedicated verify stage',
      'runs those and reports back.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY implementation code in: ${(a.impl_files || []).join(', ')}. Do NOT hand-edit`,
      '    tests, other source files, TODO.md, or build files.',
      '  - DO run `just fmt` to fix formatting.',
      '  - You may NOT edit tests (the test-writer owns those). If you conclude a TEST is wrong — not the',
      '    code — return outcome=needs_test_change with exact instructions instead of editing it.',
      '  - Do NOT commit. Summarize your changes and set outcome=done when complete.',
    ].join('\n'),
    `implementer:${a.utility}#${a.issue}`,
    'Implement',
    brief,
  );
  testsChangedDuringGreen = testsChangedDuringGreen || impl.tests_changed;
  let implNote = impl.result.summary;

  phase('Verify gate');
  let verify = null;
  let vfix = 0;
  while (vfix <= GATE_FIX_MAX) {
    verify = await agent(
      [
        '## YOUR TASK (verify gate — SCOPED, run and report only)',
        'Run ONLY the fast, scoped checks for the utility under change — the full suites are deferred to',
        'the once-only final gate, so do NOT run them here:',
        `  - scoped unit:        "${a.util_test_cmd}"`,
        `  - scoped integration: "${a.it_cmd}"`,
        `  - lint:               "${a.fmt_cmd}"`,
        'Report facts only. unit_pass = scoped unit green; integration_pass = scoped integration green;',
        'lint_clean = fmt passes.',
      ].join('\n'),
      { label: `verify-gate:${a.utility}#${a.issue}`, phase: 'Verify gate', model: 'haiku', schema: VERIFY_GATE_SCHEMA },
    );
    const ok = verify.unit_pass && verify.integration_pass && verify.lint_clean;
    if (ok) break;
    if (vfix === GATE_FIX_MAX) break;
    vfix += 1;
    log(`verify gate failed (unit=${verify.unit_pass} integration=${verify.integration_pass} lint=${verify.lint_clean}) — re-dispatching implementer.`);
    const vimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, verify-gate fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        'The verify gate failed. Make every scoped test pass and fmt clean.',
        `Gate report: ${verify.summary}`,
        `Output excerpt:\n${verify.output_excerpt}`,
        '',
        'If the failure is a WRONG test rather than wrong code, return outcome=needs_test_change with',
        'instructions instead of editing the test. Otherwise fix the code and set outcome=done. Do NOT commit.',
      ].join('\n'),
      `implementer:${a.utility}#vfix${vfix}`,
      'Verify gate',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || vimpl.tests_changed;
    implNote = vimpl.result.summary;
  }

  async function runTigerCheck(label) {
    return await agent(
      [
        '## YOUR TASK (Tiger check — scan, triage, and report)',
        'Run, EXACTLY as given, the mechanical Tiger Style scanner against this change:',
        '  bash scripts/tiger-check.sh --base HEAD',
        'The scanner emits TAB-separated violation lines (<rule>\\t<file>:<line>\\t<status>\\t<detail>)',
        'with status NEW or PRE, then a final "SUMMARY total=<N> new=<N>" line. It parses stdout only;',
        'stderr carries human notes. Then TRIAGE the candidates:',
        '  - Confirm the genuine NEW violations.',
        '  - FILTER legitimate dual-use cases that the mechanical scanner cannot judge: a `usize` that',
        '    interfaces a std API (required by the signature it talks to), or a `while (true)` that is',
        '    provably bounded by a break/return guarded by an assert. Move each such candidate into',
        '    `filtered` with the reason; do NOT count it as a NEW violation.',
        'Return TIGER_SCHEMA: new_violations = the confirmed NEW violations (these BLOCK);',
        'preexisting_count = how many PRE rows the scanner reported (reported, not blocking);',
        'filtered = the dual-use candidates you dismissed and why. clean = true iff new_violations is',
        'empty after triage. Read code to adjudicate, but do NOT edit anything — report facts only.',
      ].join('\n'),
      { label, phase: 'Tiger check', model: 'haiku', schema: TIGER_SCHEMA },
    );
  }

  phase('Tiger check');
  let tiger = await runTigerCheck(`tiger-check:${a.utility}#${a.issue}`);
  log(`tiger check: clean=${tiger.clean} new=${(tiger.new_violations || []).length} pre=${tiger.preexisting_count} filtered=${(tiger.filtered || []).length}`);
  let tfix = 0;
  while (!tiger.clean && tfix < GATE_FIX_MAX) {
    tfix += 1;
    const violations = (tiger.new_violations || [])
      .map((v) => `- [${v.rule}] ${v.location}: ${v.detail}`)
      .join('\n');
    log(`tiger check failed (${(tiger.new_violations || []).length} new violations) — re-dispatching implementer.`);
    const timpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, Tiger-check fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        'The Tiger Style scanner flagged NEW violations your change introduced. Fix every one below while',
        'keeping all tests green and behavior unchanged:',
        violations || '(no specific lines reported; re-read the scanner output and fix the new violations)',
        '',
        'These are NEW violations only — pre-existing ones are out of scope. If a flagged line is actually a',
        'legitimate dual-use case (a `usize` required by a std API, or a `while (true)` provably bounded by a',
        'break/return guarded by an assert), say so in your summary instead of contorting the code; the Tiger',
        'check will re-triage. If a fix would require changing a WRONG test, return outcome=needs_test_change',
        'with instructions instead. Otherwise fix the code and set outcome=done. Do NOT commit.',
      ].join('\n'),
      `implementer:${a.utility}#tfix${tfix}`,
      'Tiger check',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || timpl.tests_changed;
    implNote = timpl.result.summary;
    tiger = await runTigerCheck(`tiger-check:${a.utility}#${tfix}`);
    log(`tiger check (after fix ${tfix}): clean=${tiger.clean} new=${(tiger.new_violations || []).length} pre=${tiger.preexisting_count} filtered=${(tiger.filtered || []).length}`);
  }

  phase('Code review');
  let codeReview = null;
  let round = 0;
  while (round < REVIEW_ROUND_MAX) {
    round += 1;
    codeReview = await agent(
      [
        brief,
        '',
        '## YOUR TASK (code-reviewer)',
        taskHeader(),
        '',
        `Review the fix in ${(a.impl_files || []).join(', ')} (diff against HEAD): correctness against the`,
        'pinned GNU behavior, minimality (root cause, not a special case around the tests), resource',
        'management, error handling on adjacent paths, and Tiger Style compliance.',
        'Judge BY READING AND REASONING ONLY. Do NOT run the test suite, the privileged suite, integration',
        'tests, or any build — a dedicated verify gate already proved the code green, and re-running those',
        'here only burns wall-clock. If you suspect a behavior is wrong, cite the specific code and the',
        'test that should have caught it as an issue instead of running anything.',
        'Return APPROVED only when there is nothing left to fix.',
      ].join('\n'),
      { label: `code-review:${a.utility}#${round}`, phase: 'Code review', model: 'opus', schema: REVIEW_SCHEMA },
    );
    log(`code review round ${round}: ${codeReview.assessment} (${(codeReview.issues || []).length} issues)`);
    if (codeReview.assessment === 'APPROVED') break;

    const crimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, code-review fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        reviewFeedback(codeReview),
        '',
        'Apply every fix and keep all tests green. If a review point is actually a WRONG test rather than',
        'wrong code, return outcome=needs_test_change with instructions instead of editing the test.',
        'Otherwise fix the code and set outcome=done. Do NOT commit.',
      ].join('\n'),
      `implementer:${a.utility}#crfix${round}`,
      'Code review',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || crimpl.tests_changed;
    implNote = crimpl.result.summary;
  }
  if (codeReview.assessment !== 'APPROVED') {
    log(`WARNING: code review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED — surfacing for human review.`);
  }

  const fullItCmd = a.full_it_cmd || 'just it';
  phase('Final verify');
  const finalCheck = await agent(
    [
      '## YOUR TASK (final verify — FULL suite on BOTH platforms, run and report only)',
      'Run all suites EXACTLY as given (this is the once-only authoritative gate):',
      `  - macOS full unit:        "${a.test_cmd}"`,
      `  - macOS full privileged:  "${a.privileged_test_cmd}"`,
      `  - macOS full integration: "${fullItCmd}"`,
      `  - Linux full unit:        "${a.linux_prefix} zig build test"`,
      `  - Linux scoped integration: "${a.linux_prefix} zig build" then "${a.linux_prefix} bash tests/integration.sh ${a.utility}"`,
      'Pipe verbose output through `tail`. Report facts only: unit_pass, privileged_pass,',
      'integration_pass, linux_unit_pass, linux_integration_pass. The full runs cover the whole suite so',
      'a shared/common change that broke another utility is caught.',
    ].join('\n'),
    { label: `final-verify:${a.utility}#${a.issue}`, phase: 'Final verify', model: 'haiku', schema: FINAL_SCHEMA },
  );
  const finalAllPass =
    !!finalCheck &&
    finalCheck.unit_pass &&
    finalCheck.privileged_pass &&
    finalCheck.integration_pass &&
    finalCheck.linux_unit_pass &&
    finalCheck.linux_integration_pass;
  log(`final verify: unit=${finalCheck && finalCheck.unit_pass} priv=${finalCheck && finalCheck.privileged_pass} it=${finalCheck && finalCheck.integration_pass} linux_unit=${finalCheck && finalCheck.linux_unit_pass} linux_it=${finalCheck && finalCheck.linux_integration_pass}`);

  return {
    phase: 'green',
    utility: a.utility,
    issue: a.issue,
    impl_summary: implNote,
    tests_changed_during_green: testsChangedDuringGreen,
    verify_gate: verify,
    tiger_check: tiger,
    code_review: codeReview,
    final_verify: finalCheck,
    final_all_pass: finalAllPass,
    ready_to_commit_green:
      !!(verify && verify.unit_pass && verify.integration_pass && verify.lint_clean) &&
      !!(tiger && tiger.clean) &&
      codeReview.assessment === 'APPROVED' &&
      finalAllPass,
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
log(`tdd-bugfix: ${a.utility || '(no utility)'} #${a.issue || '?'} phase=${phaseArg}`);
const result = phaseArg === 'green' ? await runGreen() : await runRed();
return result;
