export const meta = {
  name: 'tdd-pipeline',
  description:
    'TDD pipeline for one unit of work, tuned for behavior-preserving refactors (e.g. the walker migration). Phase "red" scouts a shared briefing, writes characterization tests, reviews them to APPROVED, then PROVES the tests have teeth by transiently sabotaging the implementation (tests must go red, then restore green). Phase "green" implements against the briefing, then loops verify + code-review until fully green. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Migrating a vibeutils utility onto the bounded walker, or any behavior-preserving refactor warranting the full pipeline. Dispatch twice per utility: phase:"red", commit the tests, phase:"green", commit the refactor.',
  phases: [
    { title: 'Scout', detail: 'distill walker API + recursion site + conventions (sonnet)' },
    { title: 'Author tests', detail: 'write characterization tests, green on real code (opus, tdd-pipeline:test-writer)' },
    { title: 'Review tests', detail: 'loop test-reviewer until APPROVED (opus)' },
    { title: 'Prove teeth', detail: 'sabotage impl to confirm tests can fail, then restore (sonnet)' },
    { title: 'Green check', detail: 'tests green on restored real code, compiles (haiku)' },
    { title: 'Implement', detail: 'rewire onto walker, remove recursion (opus, tdd-pipeline:implementer)' },
    { title: 'Verify gate', detail: 'full+privileged suites green, lint clean, recursion gone (haiku)' },
    { title: 'Code review', detail: 'loop code-reviewer until APPROVED (sonnet)' },
    { title: 'Final verify', detail: 'full suite green once more (haiku)' },
  ],
};

// ---------------------------------------------------------------------------
// Inputs (args)
// ---------------------------------------------------------------------------
// {
//   utility, target_file, recursion_fn, behaviors[],
//   walker_file, design_doc,
//   test_cmd, privileged_test_cmd, util_test_cmd, it_cmd, fmt_cmd,
//   phase: "red" | "green",
//   briefing: <object returned by the red phase, fed back into green>
// }

// args may arrive as an object OR as a JSON-encoded string depending on how
// the workflow is invoked; normalize both so a.utility etc. resolve.
const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
log(`args: type=${typeof args} utility=${a.utility || 'MISSING'} behaviors=${(a.behaviors || []).length}`);
const phaseArg = a.phase || 'red';

// The user wants review gates to loop until fully green. This cap only
// exists to surface a runaway loudly instead of spinning forever; hitting
// it is an error condition, not a normal exit.
const REVIEW_ROUND_MAX = 12;
const GATE_FIX_MAX = 4;

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['walker_api', 'current_recursion', 'migration_steps', 'conventions'],
  properties: {
    walker_api: {
      type: 'string',
      description:
        'Exact public API of the walker: init/addRoot/next/pruneCurrent/deinit signatures, WalkConfig fields with defaults, the Entry struct next() yields (every field + lifetime), and the error set. Copy real signatures; do not paraphrase types.',
    },
    current_recursion: {
      type: 'string',
      description:
        'The recursive function being replaced: full signature, traversal order (pre/post), open-first semantics, every call site with line numbers, how -R / symlink flags flow in, and which production functions implement each user-visible behavior (so a saboteur knows what to mutate).',
    },
    migration_steps: {
      type: 'string',
      description:
        'The concrete recipe from the design doc for THIS utility: the WalkConfig to use (order, symlinks, stay_on_filesystem, prune), the driver-loop shape, and any invariants to preserve.',
    },
    conventions: {
      type: 'string',
      description:
        'Project conventions an agent needs without exploring: exact test/lint commands, embedded-test pattern, the privileged/fakeroot test harness, the error-helper signature, the Tiger Style essentials (2+ asserts/fn, 70-line/100-col limits, no recursion), and the test-first discipline (separate agents; refactors prove teeth by sabotage).',
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

// Sabotage / "prove teeth": for each behavior, break the impl, confirm the
// guarding test fails, then restore and confirm green. This is the
// refactor-appropriate substitute for a natural RED.
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
  required: ['all_pass', 'lint_clean', 'recursion_removed', 'summary', 'output_excerpt'],
  properties: {
    all_pass: { type: 'boolean', description: 'true if the full and privileged suites both pass' },
    lint_clean: { type: 'boolean', description: 'true if fmt-check passes' },
    recursion_removed: {
      type: 'boolean',
      description: 'true if the old recursive function is gone from the target file (grep confirms)',
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['all_pass', 'summary', 'output_excerpt'],
  properties: {
    all_pass: { type: 'boolean' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

// The implementer may discover that a TEST (not the code) is wrong. It must
// NOT edit the test itself (separate-agents rule); instead it signals
// needs_test_change so the orchestrator can route the change to the
// test-writer. This is the path that was missing — without it the implementer
// either stalls or contorts the code to satisfy a bad test.
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

// The test-writer adjudicates an implementer's test-change request judge-first:
// fix the test (keeping it toothful) only if it is genuinely wrong; otherwise
// refuse and bounce it back so the implementer fixes the code. This guardrail
// stops an implementer from dodging a real bug by declaring the test wrong.
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
    '### Walker public API',
    b.walker_api,
    '',
    '### Current recursion being replaced',
    b.current_recursion,
    '',
    '### Migration recipe for this utility',
    b.migration_steps,
    '',
    '### Project conventions',
    b.conventions,
  ].join('\n');
}

function taskHeader() {
  return [
    `Utility: ${a.utility}`,
    `Target file: ${a.target_file}`,
    `Recursive function to remove: ${a.recursion_fn}`,
    `Behaviors to cover:\n- ${(a.behaviors || []).join('\n- ')}`,
    '',
    'Reference files (open only if the briefing is insufficient):',
    `- walker: ${a.walker_file}`,
    `- design doc: ${a.design_doc}`,
  ].join('\n');
}

function reviewFeedback(review) {
  const lines = (review.issues || []).map(
    (i) => `- [${i.severity}] ${i.location}: ${i.description}`,
  );
  return [`Reviewer assessment: ${review.assessment}`, review.summary, '', 'Fix every issue below:', ...lines].join('\n');
}

// Scout once: read the walker, target file, and design doc; distill a briefing
// every downstream agent reuses so none of them re-explores.
async function scoutBriefing() {
  phase('Scout');
  return await agent(
    [
      'You are scouting a vibeutils utility migration onto the shared bounded walker.',
      'Read the files below and return a distilled briefing every downstream agent will rely on,',
      'so they never have to explore. Copy EXACT signatures; do not paraphrase types or field names.',
      '',
      taskHeader(),
      '',
      `Read in full: ${a.walker_file}, ${a.target_file} (focus on ${a.recursion_fn} and its call sites),`,
      `and the ${a.utility} section of ${a.design_doc}. Also read CLAUDE.md for test/lint commands and`,
      'the Tiger Style + test-first rules. Be precise and concise.',
    ].join('\n'),
    { label: `scout:${a.utility}`, phase: 'Scout', model: 'sonnet', schema: BRIEFING_SCHEMA },
  );
}

// Route an implementer's test-change request to the test-writer (the only
// agent allowed to edit tests), judge-first. Returns { changed, summary }.
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
      agentType: 'tdd-pipeline:test-writer',
      schema: TESTFIX_SCHEMA,
    },
  );
}

// Dispatch the implementer and, if it reports a test is wrong, route the change
// to the test-writer (judge-first) and re-dispatch the implementer. Bounded.
// Returns { result: <IMPLEMENT_SCHEMA>, tests_changed: bool }.
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
        `Edit ONLY ${a.target_file} implementation code. Run \`just fmt\`. Do NOT commit. Return your outcome.`,
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
      '## YOUR TASK (test-writer) — characterization tests for a refactor',
      taskHeader(),
      '',
      'This is a behavior-PRESERVING migration, so the tests should PASS on the current code.',
      'Their job is to lock in the behavior the walker rewrite must preserve. Therefore:',
      '- Do NOT touch or rewrite existing tests; they remain the regression net.',
      '- Add NEW characterization tests for the behaviors above (e.g. post-order ordering,',
      '  symlink -P/-H/-L handling, multi-level tree correctness, deep/wide trees, cycle safety).',
      '- Each test must assert a SPECIFIC behavior that a wrong implementation would break — no',
      '  default-value traps, no tautologies. A later step will sabotage the implementation to prove',
      '  each test can actually fail, so write tests that genuinely exercise the behavior.',
      '- Recursive-walk tests are PRIVILEGED (fakeroot): follow the privileged_test harness and the',
      '  "privileged:" naming, NOT testing.allocator.',
      '',
      `Run the tests and confirm they PASS on the current code. Prefer the scoped \`${a.util_test_cmd}\``,
      `piped through \`tail\`; run the full \`${a.test_cmd}\` at most once to confirm. Keep output short.`,
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY ${a.target_file}. Do NOT hand-edit other source files, TODO.md, or build files.`,
      '  - DO run `just fmt` to fix formatting — we always want formatting auto-fixed. (The repo is kept',
      '    fmt-clean, so `just fmt` should only reflow the file you edited.)',
      '  - Do NOT commit. Return a short summary of the tests you added, where they live, and which',
      '    production behavior each one guards.',
    ].join('\n'),
    { label: `test-writer:${a.utility}`, phase: 'Author tests', model: 'opus', agentType: 'tdd-pipeline:test-writer' },
  );

  // Review tests: loop until APPROVED (user requirement).
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
        `Review the characterization tests just added to ${a.target_file}. Check: every listed behavior`,
        'is covered; each test exercises real production code; NO default-value traps or tautologies (every',
        'test must be one a wrong implementation would break); privileged tests use the fakeroot harness.',
        'Since these tests pass on current code by design, your job is to confirm they have TEETH — that',
        'each would fail if the guarded behavior regressed. Judge this BY READING AND REASONING ONLY. Do',
        'NOT modify or run the implementation, do NOT run a sabotage campaign yourself, and do NOT run the',
        'test suite — a separate dedicated stage proves teeth empirically. Flag any test you suspect is',
        'toothless as an issue. Return APPROVED only when nothing remains.',
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
      { label: `test-writer:${a.utility}#fix${round}`, phase: 'Review tests', model: 'opus', agentType: 'tdd-pipeline:test-writer' },
    );
  }
  if (testReview.assessment !== 'APPROVED') {
    log(`WARNING: test review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED — surfacing for human review.`);
  }

  // Prove teeth: transient sabotage. A different agent than the test-writer.
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
        '     (e.g. flip post-order to pre-order, drop a symlink branch, skip an entry).',
        `  3. Run ONLY the specific guarding test(s) for THIS behavior — NOT the whole suite. Filter by`,
        `     test name (e.g. \`zig build test -Dtest-filter="<test name>"\`, or the privileged equivalent`,
        `     \`fakeroot zig build test-privileged -Dtest-filter="<test name>"\` for fakeroot tests), and`,
        '     pipe through `tail` to keep output short. Confirm the guarding test(s) FAIL (went_red).',
        '     Running the full suite per mutation is slow and wasteful — do not do it.',
        `  4. RESTORE ${a.target_file} from the backup (do NOT leave any mutation behind) and re-run that`,
        '     same filtered test to confirm it PASSES again (restored_green).',
        'After all behaviors, run `git diff -- ' + a.target_file + '` and confirm ONLY the test additions',
        'remain (no leftover sabotage) — report that as file_restored_clean. Run a single full',
        `\`${a.util_test_cmd}\` ONCE at the very end to confirm the restored tree is green.`,
        '',
        'If any behavior does NOT go red, its test is toothless: report went_red=false with which test',
        'failed to catch the break, so the test-writer can fix it. Do NOT write the real implementation.',
        '',
        'Scope discipline (strict): mutate ONLY ' + a.target_file + ' and always restore it from the',
        'backup. Do NOT edit any other file, do NOT run a tree-wide formatter (`just fmt`/`zig build fmt`),',
        'and do NOT commit.',
      ].join('\n'),
      { label: `prove-teeth:${a.utility}`, phase: 'Prove teeth', model: 'sonnet', schema: SABOTAGE_SCHEMA },
    );
    log(`prove-teeth: proven=${sabotage.all_behaviors_proven} clean=${sabotage.file_restored_clean}`);
    if (sabotage.all_behaviors_proven && sabotage.file_restored_clean) break;
    if (teethFix === GATE_FIX_MAX) break;
    teethFix += 1;

    // Toothless tests are a test bug -> back to the test-writer.
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
      { label: `test-writer:${a.utility}#teethfix${teethFix}`, phase: 'Prove teeth', model: 'opus', agentType: 'tdd-pipeline:test-writer' },
    );
  }

  // Green check: confirm the restored real code is fully green and compiles.
  phase('Green check');
  const greenCheck = await agent(
    [
      '## YOUR TASK (green check — run and report only)',
      `Run, EXACTLY as given, the ${a.utility} tests on the real (restored) code:`,
      `${a.privileged_test_cmd} and ${a.util_test_cmd}. Confirm the build compiles and ALL tests pass`,
      '(the newly-added characterization tests included). Report facts only.',
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
// GREEN phase: implement the refactor, keep everything green
// ---------------------------------------------------------------------------
async function runGreen() {
  // Reuse the red phase's briefing if it was threaded in; otherwise re-scout
  // (cheap) rather than require a large object to be passed back by hand.
  const briefing = a.briefing || (await scoutBriefing());
  const brief = formatBriefing(briefing);

  phase('Implement');
  let testsChangedDuringGreen = false;
  let impl = await runImplementer(
    [
      brief,
      '',
      '## YOUR TASK (implementer) — behavior-preserving refactor',
      taskHeader(),
      '',
      `Rewire ${a.utility} onto the bounded walker per the migration recipe, and DELETE ${a.recursion_fn}`,
      'entirely (no recursion may remain). ALL tests must stay green — the characterization tests and every',
      'existing one. This is a refactor: do NOT change user-visible behavior (e.g. chmod stays post-order,',
      'open-first, honors -P/-H/-L). Honor Tiger Style: 2+ assertions per function, no recursion, bounded',
      'loops, 70-line/100-col limits.',
      '',
      'For your own iteration, use only FAST, SCOPED, QUIET checks — a compile check (`zig build`) and at',
      `most \`${a.util_test_cmd}\`, piped through \`tail\` to keep output short. Do NOT run the full suite,`,
      'the privileged/fakeroot suite, or integration tests yourself — a dedicated verify stage runs those',
      'and reports back. Ingesting their verbose output wastes your context.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY ${a.target_file}. Do NOT hand-edit other source files, TODO.md, or build files.`,
      '  - DO run `just fmt` to fix formatting — we always want formatting auto-fixed, and a pre-commit',
      '    hook will block the commit if it is not clean. (The repo is kept fmt-clean, so `just fmt` should',
      '    only reflow the file you edited.)',
      '  - You may NOT edit tests (the test-writer owns those). If you conclude a TEST is wrong — not the',
      '    code — return outcome=needs_test_change with exact instructions instead of editing it or',
      '    contorting the implementation; the test-writer will adjudicate and the loop returns to you.',
      '  - Do NOT commit. Summarize your changes and set outcome=done when complete.',
    ].join('\n'),
    `implementer:${a.utility}`,
    'Implement',
    brief,
  );
  testsChangedDuringGreen = testsChangedDuringGreen || impl.tests_changed;
  let implNote = impl.result.summary;

  // Verify gate: re-dispatch implementer on failure (bounded).
  phase('Verify gate');
  let verify = null;
  let vfix = 0;
  while (vfix <= GATE_FIX_MAX) {
    verify = await agent(
      [
        '## YOUR TASK (verify gate — run and report only)',
        `Run, EXACTLY as given: full suite "${a.test_cmd}", privileged "${a.privileged_test_cmd}", lint "${a.fmt_cmd}".`,
        `Then grep ${a.target_file} for "${a.recursion_fn}" to confirm the recursive function is gone.`,
        'Report facts only. all_pass = both suites green; lint_clean = fmt passes; recursion_removed = grep finds nothing.',
      ].join('\n'),
      { label: `verify-gate:${a.utility}`, phase: 'Verify gate', model: 'haiku', schema: VERIFY_GATE_SCHEMA },
    );
    const ok = verify.all_pass && verify.lint_clean && verify.recursion_removed;
    if (ok) break;
    if (vfix === GATE_FIX_MAX) break;
    vfix += 1;
    log(`verify gate failed (pass=${verify.all_pass} lint=${verify.lint_clean} recursionGone=${verify.recursion_removed}) — re-dispatching implementer.`);
    const vimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, verify-gate fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        'The verify gate failed. Make every test pass, fmt clean, and ensure the recursive function is gone.',
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

  // Code review: loop until APPROVED (user requirement).
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
        `Review the implementation in ${a.target_file}: correctness against the tests, resource management`,
        '(walker deinit, dir handles, path dupes), Tiger Style compliance, and that no recursion remains.',
        'Judge BY READING AND REASONING ONLY. Do NOT run the test suite, the privileged suite, integration',
        'tests, or any build — a dedicated verify gate already proved the code green and recursion-free, and',
        're-running those here only burns wall-clock. If you suspect a behavior is wrong, cite the specific',
        'code and the test that should have caught it as an issue instead of running anything.',
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

  // Final full-suite confirmation (CLAUDE.md: full suite before declaring success).
  phase('Final verify');
  const finalCheck = await agent(
    [
      '## YOUR TASK (final verify — run and report only)',
      `Run the FULL suite "${a.test_cmd}" and "${a.privileged_test_cmd}" EXACTLY as given. Report whether everything is green.`,
    ].join('\n'),
    { label: `final-verify:${a.utility}`, phase: 'Final verify', model: 'haiku', schema: FINAL_SCHEMA },
  );

  return {
    phase: 'green',
    utility: a.utility,
    impl_summary: implNote,
    tests_changed_during_green: testsChangedDuringGreen,
    verify_gate: verify,
    code_review: codeReview,
    final_verify: finalCheck,
    ready_to_commit_green:
      !!(verify && verify.all_pass && verify.lint_clean && verify.recursion_removed) &&
      codeReview.assessment === 'APPROVED' &&
      !!(finalCheck && finalCheck.all_pass),
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
log(`tdd-pipeline: ${a.utility || '(no utility)'} phase=${phaseArg}`);
const result = phaseArg === 'green' ? await runGreen() : await runRed();
return result;
