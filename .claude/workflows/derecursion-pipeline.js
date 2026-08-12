export const meta = {
  name: 'derecursion-pipeline',
  description:
    'TDD pipeline for removing direct recursion from one function by replacing it with an explicit bounded stack/queue (Tiger Style: no recursion, bounded loops). Behavior-preserving refactor, optionally hybrid (a deep-input crash that the iterative version fixes). Phase "red" scouts a briefing, writes characterization tests, reviews them to APPROVED, then PROVES teeth by transient sabotage. Phase "green" implements the iterative rewrite, then loops verify + code-review until green. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Removing recursion from a function (e.g. find\'s expression parser/evaluator) without changing behavior. Dispatch twice per unit: phase:"red", commit tests, phase:"green", commit the rewrite.',
  phases: [
    { title: 'Scout', detail: 'distill the recursion site + iterative plan + conventions (sonnet)' },
    { title: 'Author tests', detail: 'characterization tests, green on real code (opus, tdd-pipeline:test-writer)' },
    { title: 'Review tests', detail: 'loop test-reviewer until APPROVED (opus)' },
    { title: 'Prove teeth', detail: 'sabotage impl to confirm tests can fail, then restore (sonnet)' },
    { title: 'Green check', detail: 'tests green on restored real code, compiles (haiku)' },
    { title: 'Implement', detail: 'replace recursion with an explicit bounded stack (opus, tdd-pipeline:implementer)' },
    { title: 'Verify gate', detail: 'SCOPED: util unit + util integration + lint + no self-recursion (haiku)' },
    { title: 'Tiger check', detail: 'scan for NEW Tiger Style violations, triage dual-use, fix (haiku/sonnet)' },
    { title: 'Code review', detail: 'loop code-reviewer until APPROVED (opus)' },
    { title: 'Final verify', detail: 'ONCE: full unit + full privileged + full integration (haiku)' },
  ],
};

// ---------------------------------------------------------------------------
// Inputs (args)
// ---------------------------------------------------------------------------
// {
//   utility, target_file, recursion_fn, behaviors[],
//   design_doc,
//   test_cmd, privileged_test_cmd, util_test_cmd, it_cmd, fmt_cmd, full_it_cmd,
//   phase: "red" | "green",
//   briefing: <object returned by the red phase, fed back into green>
// }

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
log(`args: type=${typeof args} utility=${a.utility || 'MISSING'} behaviors=${(a.behaviors || []).length}`);
const phaseArg = a.phase || 'red';

const REVIEW_ROUND_MAX = 12;
const GATE_FIX_MAX = 4;

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['current_recursion', 'iterative_plan', 'conventions'],
  properties: {
    current_recursion: {
      type: 'string',
      description:
        'The recursive function(s) being made iterative: full signature(s), every recursive call site with line numbers, the data each call carries, traversal/visit order, short-circuit or early-exit behavior, side effects performed during the walk, and any out-params (so a saboteur knows what to mutate and the implementer knows what to preserve).',
    },
    iterative_plan: {
      type: 'string',
      description:
        'The concrete plan to remove the recursion: the explicit stack/queue shape (element type, what state each frame carries), how visit order and short-circuit are preserved, where side effects fire, and the bound on the stack. Note the function keeps its name and external signature.',
    },
    conventions: {
      type: 'string',
      description:
        'Project conventions an agent needs without exploring: exact test/lint commands, embedded-test pattern, the error-helper signature, the Tiger Style essentials (2+ asserts/fn, 70-line/100-col limits, no recursion), and the test-first discipline (separate agents; refactors prove teeth by sabotage).',
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

const SABOTAGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['all_behaviors_proven', 'file_restored_clean', 'results', 'summary'],
  properties: {
    all_behaviors_proven: {
      type: 'boolean',
      description: 'true only if EVERY targeted behavior went red under its mutation and then restored green',
    },
    file_restored_clean: {
      type: 'boolean',
      description:
        'true if the target file is back to its pre-sabotage state (the newly-added tests intact, no mutation left behind; confirmed via git diff)',
    },
    results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['behavior', 'mutation', 'went_red', 'restored_green'],
        properties: {
          behavior: { type: 'string' },
          mutation: { type: 'string', description: 'the minimal change made to break this behavior' },
          went_red: { type: 'boolean', description: 'did the guarding test(s) fail under the mutation' },
          restored_green: { type: 'boolean', description: 'did the test(s) pass again after reverting' },
          guarding_tests: { type: 'string', description: 'which test(s) caught (or failed to catch) the break' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

const GREEN_CHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['compiled', 'all_pass', 'summary', 'output_excerpt'],
  properties: {
    compiled: { type: 'boolean' },
    all_pass: { type: 'boolean', description: 'true if every test passes on the real, restored code' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const VERIFY_GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean', 'no_self_recursion', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'true if the scoped util_test_cmd unit check passes' },
    integration_pass: { type: 'boolean', description: 'true if the scoped it_cmd integration suite passes' },
    lint_clean: { type: 'boolean', description: 'true if fmt-check passes' },
    no_self_recursion: {
      type: 'boolean',
      description:
        'true if the target function(s) no longer call themselves (directly or mutually) — confirmed by reading the function bodies; the recursion is replaced by an explicit stack/queue loop',
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'privileged_pass', 'integration_pass', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'true if the FULL unit suite (test_cmd) passes' },
    privileged_pass: { type: 'boolean', description: 'true if the FULL privileged suite passes' },
    integration_pass: { type: 'boolean', description: 'true if the FULL integration suite (just it) passes' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

// Tiger check — runs the mechanical Tiger Style scanner against the diff, then
// TRIAGES its candidate violations: confirm real ones and FILTER legitimate
// dual-use cases (a `usize` that interfaces a std API; a `while (true)` provably
// bounded by a break/return guarded by an assert). NEW violations block; the
// scanner also reports PRE-existing ones (preexisting_count) but those do not
// block. clean=true iff no confirmed NEW violations remain after triage.
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
        "'done' = implementation complete against the existing tests. 'needs_test_change' = a test is wrong (over-constrained, toothless, asserts an unspecified detail, or references a renamed symbol) and must be fixed by the test-writer before the code can be correct.",
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
    '### Current recursion being replaced',
    b.current_recursion,
    '',
    '### Iterative (de-recursion) plan',
    b.iterative_plan,
    '',
    '### Project conventions',
    b.conventions,
  ].join('\n');
}


// The tdd-pipeline plugin supplies tailored test-writer, implementer and
// code-reviewer agents. Where that plugin is not installed — a fresh agent
// container, a CI runner — agent() throws "agent type not found" and takes the
// whole run down with it. Pass `agent_ns: ""` to fall back to the default
// workflow subagent: the separate-agents rule is enforced by distinct
// invocations and by file-ownership scoping, not by the system prompt the
// plugin happens to add. The default is unchanged, so a machine with the
// plugin installed behaves exactly as before.
//
// Read the PARSED args (`a`), never the raw `args` global: the harness may hand
// the script a JSON string, in which case `args.agent_ns` reads as undefined
// and this would fall back to the plugin on the very hosts that cannot resolve
// it — failing exactly where the fallback is needed.
const AGENT_NS = a.agent_ns !== undefined ? a.agent_ns : 'tdd-pipeline:';
const agentTypeFor = (role) => (AGENT_NS ? `${AGENT_NS}${role}` : undefined);

function taskHeader() {
  return [
    `Unit: ${a.utility}`,
    `Target file: ${a.target_file}`,
    `Recursive function(s) to make iterative: ${a.recursion_fn}`,
    `Behaviors to cover:\n- ${(a.behaviors || []).join('\n- ')}`,
    '',
    `Reference (open only if the briefing is insufficient): design doc ${a.design_doc}`,
  ].join('\n');
}

function reviewFeedback(review) {
  const lines = (review.issues || []).map((i) => `- [${i.severity}] ${i.location}: ${i.description}`);
  return [`Reviewer assessment: ${review.assessment}`, review.summary, '', 'Fix every issue below:', ...lines].join('\n');
}

async function scoutBriefing() {
  phase('Scout');
  return await agent(
    [
      'You are scouting a recursion-removal refactor in a vibeutils source file: a recursive function is to',
      'be rewritten with an explicit bounded stack/queue (Tiger Style: no recursion). Read the code below',
      'and return a distilled briefing every downstream agent will rely on, so they never have to explore.',
      'Copy EXACT signatures; do not paraphrase types or field names. Be precise about visit order,',
      'short-circuit/early-exit, side effects performed during the walk, and any out-params.',
      '',
      taskHeader(),
      '',
      `Read in full: ${a.target_file} (focus on ${a.recursion_fn} and its call sites). Also read CLAUDE.md`,
      'for test/lint commands and the Tiger Style + test-first rules. Be precise and concise.',
    ].join('\n'),
    { label: `scout:${a.utility}`, phase: 'Scout', model: 'sonnet', schema: BRIEFING_SCHEMA },
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
      'reading the test and the behavior it guards:',
      '  - If the test is genuinely WRONG (over-constrained, asserts an unspecified detail, references a',
      '    renamed symbol, or is toothless), fix it — and keep it with TEETH: it must still fail if the',
      '    guarded behavior regresses. Set changed=true and describe the fix.',
      '  - If the test is CORRECT, do NOT change it. Set changed=false and explain why the implementation,',
      '    not the test, must change. The implementer will then be told to fix the code.',
      '',
      `Implementer's request:\n${instructions}`,
      '',
      `Edit ONLY the test code in ${a.target_file}; do not touch implementation logic. Run \`just fmt\`.`,
      'Do NOT commit.',
    ].join('\n'),
    {
      label: `test-writer:${a.utility}#adjudicate${hop}`,
      phase: phaseName,
      model: 'opus',
      agentType: agentTypeFor('test-writer'),
      schema: TESTFIX_SCHEMA,
    },
  );
}

async function runImplementer(promptText, label, phaseName, brief) {
  let result = await agent(promptText, {
    label,
    phase: phaseName,
    model: 'opus',
    agentType: agentTypeFor('implementer'),
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
        `Edit ONLY ${a.target_file} implementation code. Run \`just fmt\`. Do NOT commit. Return your outcome.`,
      ].join('\n'),
      {
        label: `${label}#aftertest${hop}`,
        phase: phaseName,
        model: 'opus',
        agentType: agentTypeFor('implementer'),
        schema: IMPLEMENT_SCHEMA,
      },
    );
  }
  return { result, tests_changed };
}

// ---------------------------------------------------------------------------
// RED phase: characterization tests + prove-teeth (sabotage)
// ---------------------------------------------------------------------------
async function runRed() {
  const briefing = await scoutBriefing();
  const brief = formatBriefing(briefing);

  phase('Author tests');
  let testNote = await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — characterization tests for a recursion-removal refactor',
      taskHeader(),
      '',
      'This is a behavior-PRESERVING refactor, so the tests should PASS on the current code. Their job is to',
      'lock in the behavior the iterative rewrite must preserve. Therefore:',
      '- Do NOT touch or rewrite existing tests; they remain the regression net.',
      '- Add NEW characterization tests for the behaviors above. Pay special attention to ORDER-SENSITIVE',
      '  and SIDE-EFFECTING behavior (short-circuit, early-exit, which actions fire in which order) — those',
      '  are exactly what a wrong iterative rewrite silently breaks.',
      '- Each test must assert a SPECIFIC behavior a wrong implementation would break — no default-value',
      '  traps, no tautologies. A later step will sabotage the implementation to prove each test can fail.',
      '',
      `Run the tests and confirm they PASS on the current code. Prefer the scoped \`${a.util_test_cmd}\``,
      'piped through `tail`; run the full suite at most once. Keep output short.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY ${a.target_file}. Do NOT hand-edit other source files, TODO.md, or build files.`,
      '  - DO run `just fmt` to fix formatting.',
      '  - Do NOT commit. Return a short summary of the tests you added, where they live, and which',
      '    behavior each one guards.',
    ].join('\n'),
    { label: `test-writer:${a.utility}`, phase: 'Author tests', model: 'opus', agentType: agentTypeFor('test-writer') },
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
        `Review the characterization tests just added to ${a.target_file}. Check: every listed behavior is`,
        'covered; each test exercises real production code; NO default-value traps or tautologies; order-',
        'sensitive and side-effecting behavior is genuinely pinned (a reordered/short-circuit-broken rewrite',
        'would fail them). Since these tests pass on current code by design, confirm they have TEETH. Judge',
        'BY READING AND REASONING ONLY. Do NOT modify or run anything — a separate stage proves teeth',
        'empirically. Flag any toothless test as an issue. Return APPROVED only when nothing remains.',
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
        'Apply every fix; keep the tests passing on current code. Do NOT commit. Return a short summary.',
      ].join('\n'),
      { label: `test-writer:${a.utility}#fix${round}`, phase: 'Review tests', model: 'opus', agentType: agentTypeFor('test-writer') },
    );
  }
  if (testReview.assessment !== 'APPROVED') {
    log(`WARNING: test review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED — surfacing for human review.`);
  }

  phase('Prove teeth');
  let sabotage = null;
  let teethFix = 0;
  while (teethFix <= GATE_FIX_MAX) {
    sabotage = await agent(
      [
        brief,
        '',
        '## YOUR TASK (prove the tests have teeth via transient sabotage)',
        taskHeader(),
        '',
        'A refactor has no natural RED, so prove the new characterization tests can fail. For EACH key',
        'behavior the tests guard:',
        `  1. Back up ${a.target_file} first: copy it to a temp path (e.g. /tmp/${a.utility}.bak).`,
        '  2. Apply a MINIMAL mutation to the PRODUCTION code (not the tests) that breaks that behavior',
        '     (e.g. flip a short-circuit branch, swap left/right evaluation order, drop an action).',
        '  3. Run ONLY the specific guarding test(s) for THIS behavior — NOT the whole suite. Filter by',
        `     test name (e.g. \`zig build test -Dtest-filter="<test name>"\`) and pipe through \`tail\`.`,
        '     Confirm the guarding test(s) FAIL (went_red).',
        `  4. RESTORE ${a.target_file} from the backup (do NOT leave any mutation behind) and re-run that`,
        '     same filtered test to confirm it PASSES again (restored_green).',
        'After all behaviors, run `git diff -- ' + a.target_file + '` and confirm ONLY the test additions',
        `remain (no leftover sabotage) — report that as file_restored_clean. Run \`${a.util_test_cmd}\` ONCE`,
        'at the very end to confirm the restored tree is green.',
        '',
        'If any behavior does NOT go red, its test is toothless: report went_red=false with which test',
        'failed to catch the break. Do NOT write the real iterative implementation.',
        '',
        'Scope discipline (strict): mutate ONLY ' + a.target_file + ' and always restore it. Do NOT edit any',
        'other file, do NOT run a tree-wide formatter, and do NOT commit.',
      ].join('\n'),
      { label: `prove-teeth:${a.utility}`, phase: 'Prove teeth', model: 'sonnet', schema: SABOTAGE_SCHEMA },
    );
    log(`prove-teeth: proven=${sabotage.all_behaviors_proven} clean=${sabotage.file_restored_clean}`);
    if (sabotage.all_behaviors_proven && sabotage.file_restored_clean) break;
    if (teethFix === GATE_FIX_MAX) break;
    teethFix += 1;

    const toothless = (sabotage.results || [])
      .filter((r) => !r.went_red)
      .map((r) => `- ${r.behavior}: sabotage "${r.mutation}" did not fail ${r.guarding_tests || 'any test'}`)
      .join('\n');
    testNote = await agent(
      [
        brief,
        '',
        '## YOUR TASK (test-writer, teeth fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${testNote}`,
        '',
        'Sabotage proved these tests CANNOT fail when their behavior is broken — they are toothless and',
        'must be strengthened so they genuinely assert the behavior:',
        toothless || '(file was left dirty by sabotage; ensure your tests are intact and pass on real code)',
        '',
        'Strengthen the tests so a broken implementation would fail them; keep them green on current code.',
        'Do NOT commit. Return a short summary.',
      ].join('\n'),
      { label: `test-writer:${a.utility}#teethfix${teethFix}`, phase: 'Prove teeth', model: 'opus', agentType: agentTypeFor('test-writer') },
    );
  }

  phase('Green check');
  const greenCheck = await agent(
    [
      '## YOUR TASK (green check — run and report only)',
      `Run, EXACTLY as given, the ${a.utility} tests on the real (restored) code:`,
      `${a.privileged_test_cmd}, ${a.util_test_cmd}, and ${a.it_cmd}. Confirm the build compiles and`,
      'report whether all tests pass (the newly-added characterization tests included). De-recursion',
      'targets (find, rm, the walker) often have fakeroot `privileged:` characterization tests, so the',
      'privileged suite must run here too. For a HYBRID migration with intentionally-RED tests (a real',
      'behavior change, not a pure refactor), some new tests are expected to FAIL here until green —',
      'report all_pass honestly. Report facts only.',
    ].join('\n'),
    { label: `green-check:${a.utility}`, phase: 'Green check', model: 'haiku', schema: GREEN_CHECK_SCHEMA },
  );

  return {
    phase: 'red',
    utility: a.utility,
    briefing,
    test_summary: testNote,
    test_review: testReview,
    sabotage,
    green_check: greenCheck,
    ready_to_commit_red:
      testReview.assessment === 'APPROVED' &&
      !!(sabotage && sabotage.all_behaviors_proven && sabotage.file_restored_clean) &&
      !!(greenCheck && greenCheck.compiled && greenCheck.all_pass),
  };
}

// ---------------------------------------------------------------------------
// GREEN phase: implement the iterative rewrite, keep everything green
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
      '## YOUR TASK (implementer) — recursion-removal refactor',
      taskHeader(),
      '',
      `Replace the direct recursion in ${a.recursion_fn} with an explicit, bounded stack/queue so NO`,
      'recursion remains (no direct self-call, no mutual recursion among the named functions). The',
      'function(s) keep their name(s) and external signature(s) — callers and tests are unchanged. This is a',
      'behavior-preserving refactor: visit order, short-circuit/early-exit, which side effects fire and in',
      'what order, out-params, and error parity must all stay identical. The previously-RED deep-nesting',
      'test (the intended robustness fix) must now pass: the explicit stack is heap-backed so deep input no',
      'longer overflows. Honor Tiger Style: 2+ assertions per function, bounded loops, 70-line/100-col',
      'limits; assert the stack bound.',
      '',
      'For your own iteration, use only FAST, SCOPED, QUIET checks — a compile check (`zig build`) and at',
      `most \`${a.util_test_cmd}\`, piped through \`tail\`. Do NOT run the full/privileged/integration suites`,
      'yourself — a dedicated verify stage runs those.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY ${a.target_file}. Do NOT hand-edit other source files, TODO.md, or build files.`,
      '  - DO run `just fmt`.',
      '  - You may NOT edit tests. If you conclude a TEST is wrong — not the code — return',
      '    outcome=needs_test_change with exact instructions instead of editing it or contorting the code.',
      '  - Do NOT commit. Summarize your changes and set outcome=done when complete.',
    ].join('\n'),
    `implementer:${a.utility}`,
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
        'Run ONLY the fast, scoped checks for the unit under change — the full unit and privileged suites are',
        'deferred to the final gate, so do NOT run them here:',
        `  - scoped unit:        "${a.util_test_cmd}"`,
        `  - scoped integration: "${a.it_cmd}"`,
        `  - lint:               "${a.fmt_cmd}"`,
        `Then read ${a.target_file} and confirm ${a.recursion_fn} no longer calls itself (the recursion is`,
        'replaced by an explicit stack/queue loop). Report facts only. unit_pass = scoped unit green;',
        'integration_pass = scoped integration green; lint_clean = fmt passes; no_self_recursion = the',
        'function(s) contain no recursive self-call.',
      ].join('\n'),
      { label: `verify-gate:${a.utility}`, phase: 'Verify gate', model: 'haiku', schema: VERIFY_GATE_SCHEMA },
    );
    const ok = verify.unit_pass && verify.integration_pass && verify.lint_clean && verify.no_self_recursion;
    if (ok) break;
    if (vfix === GATE_FIX_MAX) break;
    vfix += 1;
    log(`verify gate failed (unit=${verify.unit_pass} integration=${verify.integration_pass} lint=${verify.lint_clean} norec=${verify.no_self_recursion}) — re-dispatching implementer.`);
    const vimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, verify-gate fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        'The verify gate failed. Make every test pass, fmt clean, and ensure no self-recursion remains.',
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

  // Tiger check: scan the diff for NEW Tiger Style violations, triage dual-use
  // candidates, and re-dispatch the implementer to fix any confirmed NEW ones.
  // PRE-existing violations are reported but do not block.
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
  let tiger = await runTigerCheck(`tiger-check:${a.utility}`);
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
        `Review the iterative rewrite in ${a.target_file}: correctness against the tests, that visit order /`,
        'short-circuit / side-effect ordering / out-params / error parity are preserved exactly, resource',
        'management (the explicit stack is freed; no leaks), the stack bound is asserted, and that NO',
        'recursion remains. Judge BY READING AND REASONING ONLY. Do NOT run tests or builds — a verify gate',
        'already proved the code green and recursion-free. Cite specific code for every issue. Return',
        'APPROVED only when there is nothing left to fix.',
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
      '## YOUR TASK (final verify — FULL suite, run and report only)',
      'Run all three FULL suites EXACTLY as given (this is the once-only authoritative gate):',
      `  - full unit:        "${a.test_cmd}"`,
      `  - full privileged:  "${a.privileged_test_cmd}"`,
      `  - full integration: "${fullItCmd}"`,
      'Report facts only: unit_pass, privileged_pass, integration_pass.',
    ].join('\n'),
    { label: `final-verify:${a.utility}`, phase: 'Final verify', model: 'haiku', schema: FINAL_SCHEMA },
  );
  const finalAllPass =
    !!finalCheck && finalCheck.unit_pass && finalCheck.privileged_pass && finalCheck.integration_pass;
  log(`final verify: unit=${finalCheck && finalCheck.unit_pass} privileged=${finalCheck && finalCheck.privileged_pass} integration=${finalCheck && finalCheck.integration_pass}`);

  return {
    phase: 'green',
    utility: a.utility,
    impl_summary: implNote,
    tests_changed_during_green: testsChangedDuringGreen,
    verify_gate: verify,
    tiger_check: tiger,
    code_review: codeReview,
    final_verify: finalCheck,
    final_all_pass: finalAllPass,
    ready_to_commit_green:
      !!(verify && verify.unit_pass && verify.integration_pass && verify.lint_clean && verify.no_self_recursion) &&
      !!(tiger && tiger.clean) &&
      codeReview.assessment === 'APPROVED' &&
      finalAllPass,
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
log(`derecursion-pipeline: ${a.utility || '(no utility)'} phase=${phaseArg}`);
const result = phaseArg === 'green' ? await runGreen() : await runRed();
return result;
