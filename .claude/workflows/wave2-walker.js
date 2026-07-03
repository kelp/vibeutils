export const meta = {
  name: 'wave2-walker',
  description:
    'TDD pipeline for the walker cycle_mode split (issues #60/#61 + chmod). Phase "red": scout walker internals, pin reference behavior (GNU du/chown on Linux, BSD chmod on macOS if GNU lacks -L), write FAILING CLI-level tests for du -L loops and chown/chmod -RL sibling aliases in parallel, review, verify RED on both platforms. Phase "green": implement the walker cycle_mode enum + consumer migrations, verify-gate loop, walker characterization-test hardening with sabotage-proven teeth, Tiger check, adversarial code review, full-suite final gates on both platforms. Commits by the orchestrator (signing policy).',
  whenToUse:
    'One-shot workflow for the wave-2 walker change. Dispatch phase:"red", commit tests, phase:"green", commit the implementation.',
  phases: [
    { title: 'Scout', detail: 'walker internals + pin GNU/BSD reference behavior (sonnet)' },
    { title: 'Author tests', detail: 'parallel failing tests for du/chown/chmod (opus, test-writer)' },
    { title: 'Review tests', detail: 'parallel reviews until APPROVED (opus)' },
    { title: 'Red check', detail: 'red for the right reason, macOS + Linux (sonnet)' },
    { title: 'Implement', detail: 'walker cycle_mode + consumer migration (opus, implementer)' },
    { title: 'Verify gate', detail: 'full unit + scoped integration ×3 + lint (haiku)' },
    { title: 'Harden walker tests', detail: 'revise/add walker unit tests, sabotage-prove teeth (opus/sonnet)' },
    { title: 'Tiger check', detail: 'scan diff for NEW violations (haiku)' },
    { title: 'Code review', detail: 'adversarial review until APPROVED (fable)' },
    { title: 'Final verify', detail: 'ONCE: full suites on macOS AND Linux (haiku)' },
  ],
};

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
log(`args: type=${typeof args} phase=${a.phase || 'red'} design=${(a.design || '').length} chars`);
const phaseArg = a.phase || 'red';

const REVIEW_ROUND_MAX = 12;
const GATE_FIX_MAX = 4;

// Utilities under behavior change. Each gets its own test-writer/reviewer.
const UNITS = [
  { util: 'du', issue: 61 },
  { util: 'chown', issue: 60 },
  { util: 'chmod', issue: 60 },
];

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['walker_internals', 'reference_behavior', 'test_conventions', 'notes'],
  properties: {
    walker_internals: {
      type: 'string',
      description:
        'Exact excerpts from src/common/walker.zig: WalkConfig fields with defaults, Frame struct, the visited-set mechanics (startRootDir, childDirRejected, collectAndPreprocess with line numbers), SymlinkPolicy, error set of next(), and the du/chown/chmod Walker.init call sites with their configs. Copy real code; do not paraphrase.',
    },
    reference_behavior: {
      type: 'string',
      description:
        'Pinned reference behavior with VERBATIM command output and exit codes: (1) GNU du -L on an ancestor loop (exact stdout lines, exact multi-line stderr warning text, rc); (2) GNU du -L sibling-alias counting; (3) GNU chown -v -RL sibling alias (both chowned? verbatim -v lines, rc) and chown -RL on an ancestor loop (diagnostic + rc); (4) chmod -RL reference — state explicitly whether GNU chmod 9.5 supports -L; if not, pin macOS /bin/chmod -v -RL for the same scenarios and say BSD is the reference. Include the tool versions.',
    },
    test_conventions: {
      type: 'string',
      description:
        'What test authors need: integration helper idioms per test file (print_test_result, run_with_limit, TEMP_DIR, how du/chown/chmod tests assert), whether chown/chmod tests need fakeroot/root skip guards, unit-test style for driving runDu/runChown/runChmod or walker directly, and the exact scoped commands per utility.',
    },
    notes: {
      type: 'string',
      description:
        'Platform differences observed, existing tests that must stay green (du F22/F25/F26, chown -H/-L traversal tests, walker unit tests incl. the alias lock-in at ~1490 and ancestor-loop at ~1324), and pitfalls.',
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

const REDCHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['red_macos', 'right_reason', 'rest_green', 'red_linux', 'summary', 'output_excerpt'],
  properties: {
    red_macos: { type: 'boolean' },
    right_reason: {
      type: 'boolean',
      description: 'failures are the intended assertion mismatches, NOT compile errors/crashes/hangs',
    },
    rest_green: { type: 'boolean', description: 'only the newly added tests fail' },
    red_linux: { type: 'boolean' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const VERIFY_GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'full `zig build test` green (walker tests are shared code)' },
    integration_pass: { type: 'boolean', description: 'scoped integration for du AND chown AND chmod all green' },
    lint_clean: { type: 'boolean' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const SABOTAGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['all_behaviors_proven', 'file_restored_clean', 'results', 'summary'],
  properties: {
    all_behaviors_proven: { type: 'boolean' },
    file_restored_clean: {
      type: 'boolean',
      description: 'walker.zig restored to pre-sabotage state, confirmed via git diff',
    },
    results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['behavior', 'mutation', 'went_red', 'restored_green'],
        properties: {
          behavior: { type: 'string' },
          mutation: { type: 'string' },
          went_red: { type: 'boolean' },
          restored_green: { type: 'boolean' },
          guarding_tests: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

const TIGER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clean', 'new_violations', 'preexisting_count', 'filtered', 'summary', 'output_excerpt'],
  properties: {
    clean: { type: 'boolean' },
    new_violations: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rule', 'location', 'detail'],
        properties: {
          rule: { type: 'string' },
          location: { type: 'string' },
          detail: { type: 'string' },
        },
      },
    },
    preexisting_count: { type: 'integer' },
    filtered: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['location', 'why'],
        properties: { location: { type: 'string' }, why: { type: 'string' } },
      },
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const IMPLEMENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['outcome', 'summary'],
  properties: {
    outcome: { type: 'string', enum: ['done', 'needs_test_change'] },
    summary: { type: 'string' },
    test_change_instructions: { type: 'string' },
  },
};

const TESTFIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['changed', 'summary'],
  properties: {
    changed: { type: 'boolean' },
    summary: { type: 'string' },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'privileged_pass', 'integration_pass', 'linux_unit_pass', 'linux_integration_pass', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean' },
    privileged_pass: { type: 'boolean' },
    integration_pass: { type: 'boolean' },
    linux_unit_pass: { type: 'boolean' },
    linux_integration_pass: {
      type: 'boolean',
      description: 'du AND chown AND chmod scoped integration all green on the Linux VM',
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function formatBriefing(b) {
  return [
    '## SHARED BRIEFING (do not re-explore unless something below is missing)',
    '',
    '### Design (approved; implement THIS, do not redesign)',
    a.design,
    '',
    '### Walker internals',
    b.walker_internals,
    '',
    '### Pinned reference behavior — this is the spec',
    b.reference_behavior,
    '',
    '### Test conventions',
    b.test_conventions,
    '',
    '### Notes',
    b.notes,
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
      'You are scouting the wave-2 walker change for vibeutils (issues #60 and #61 plus the same',
      'chmod -RL bug). Downstream agents rely entirely on your briefing; copy EXACT code excerpts.',
      '',
      '### Design you are scouting for (already approved):',
      a.design,
      '',
      'Do all of the following:',
      '1. Read src/common/walker.zig in full: WalkConfig, Frame, SymlinkPolicy, the visited-set',
      '   mechanics (startRootDir ~441, childDirRejected ~577-616, collectAndPreprocess ~755-807),',
      '   next()\'s error set, and the unit tests at ~1324 (ancestor loop) and ~1490 (alias lock-in).',
      '2. Read the Walker.init call sites + drain loops in src/du.zig (walkDirectoryOperand ~603-667,',
      '   drain loop ~694, rationale comment ~619-623), src/chown.zig (chownWalk ~582-627, walkAndApply',
      '   ~642-680), src/chmod.zig (~659 area). List every other Walker.init call site (grep) with its',
      '   current detect_cycles value: cp, grep, find, mv, rm, plus test call sites and the @hasField',
      '   guard in grep tests (~4285).',
      '3. Pin reference behavior. On the Linux VM (prefix each with `' + a.linux_prefix + '`):',
      "   a. du -L ancestor loop: bash -c 'rm -rf /tmp/w2 && mkdir -p /tmp/w2/cyc/inner && ln -s .. /tmp/w2/cyc/inner/up && du -L /tmp/w2/cyc; echo rc=$?' — record VERBATIM stdout, stderr (the multi-line circular-directory warning), rc.",
      "   b. du -L sibling alias: bash -c 'rm -rf /tmp/w2b && mkdir -p /tmp/w2b/real && echo xx > /tmp/w2b/real/f && ln -s real /tmp/w2b/link && du -aL /tmp/w2b; echo rc=$?' — is the aliased tree listed under BOTH names?",
      "   c. chown -RL sibling alias: bash -c 'rm -rf /tmp/w2c && mkdir -p /tmp/w2c/real && touch /tmp/w2c/real/f && ln -s real /tmp/w2c/link && chown -v -RL $(id -u) /tmp/w2c; echo rc=$?' — verbatim -v lines (does GNU visit the tree via both names?), rc.",
      "   d. chown -RL ancestor loop: bash -c 'rm -rf /tmp/w2d && mkdir -p /tmp/w2d/cyc/inner && ln -s .. /tmp/w2d/cyc/inner/up && chown -v -RL $(id -u) /tmp/w2d; echo rc=$?' — diagnostic + rc.",
      '   e. GNU chmod -L support: run `' + a.linux_prefix + " chmod --help | grep -c '\\-L'` and `" + a.linux_prefix + " bash -c 'chmod -RL 755 /tmp/w2c 2>&1; echo rc=$?'` — does GNU chmod 9.5 accept -L?",
      '   f. If GNU chmod lacks -L, pin the SAME sibling-alias and loop scenarios with macOS /bin/chmod',
      '      (run locally WITHOUT the linux prefix, using /bin/chmod -v -R -L and a mode like 700→755):',
      '      BSD chmod is then the reference per the project spec hierarchy (docs/specs/chmod-flags.md',
      '      marks -L MUST from POSIX/BSD).',
      '   Record every command + verbatim output + rc. If a scenario cannot be pinned, say so explicitly.',
      '4. Distill test conventions for tests/utilities/{du,chown,chmod}_test.sh (helpers, root/fakeroot',
      '   guards — chown to own uid needs no root; note du F22/F25/F26 and chown -H/-L tests that must',
      '   stay green) and the unit-test style for driving these utilities or the walker directly.',
      'Also read CLAUDE.md testing/Tiger sections if needed. Be precise; downstream agents do not re-read.',
    ].join('\n'),
    { label: 'scout:wave2', phase: 'Scout', model: 'sonnet', schema: BRIEFING_SCHEMA },
  );
}

async function routeTestChange(brief, instructions, hop, phaseName) {
  return await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — adjudicate an implementer test-change request',
      'The implementer reports that a TEST must change rather than the implementation. Judge FIRST',
      'against the pinned reference behavior and the approved design:',
      '  - If the test is genuinely WRONG, fix it keeping TEETH. changed=true.',
      '  - If the test is CORRECT, do NOT change it. changed=false; the implementation must change.',
      '',
      `Implementer's request:\n${instructions}`,
      '',
      'Edit ONLY test code. Run `just fmt`. Do NOT commit.',
    ].join('\n'),
    {
      label: `test-writer:adjudicate${hop}`,
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
    if (verdict.changed) tests_changed = true;
    log(`implementer requested a test change (hop ${hop}); test-writer changed=${verdict.changed}`);
    result = await agent(
      [
        brief,
        '',
        '## YOUR TASK (implementer, after the test-writer adjudicated)',
        `Your earlier summary: ${result.summary}`,
        `Test-writer changed the test: ${verdict.changed}`,
        `Test-writer note: ${verdict.summary}`,
        verdict.changed
          ? 'The test was updated. Make the implementation pass against the UPDATED tests.'
          : 'The test-writer judged the test CORRECT. Do NOT request another change for this issue — fix the IMPLEMENTATION.',
        '',
        'Edit ONLY implementation code. Run `just fmt`. Do NOT commit. Return your outcome.',
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
// RED phase
// ---------------------------------------------------------------------------
async function runRed() {
  const briefing = await scoutBriefing();
  const brief = formatBriefing(briefing);

  // Parallel per-utility test authoring. Files are disjoint per utility
  // (src/<u>.zig + tests/utilities/<u>_test.sh), so parallel writers are safe.
  phase('Author tests');
  const testPrompt = (u) =>
    [
      brief,
      '',
      `## YOUR TASK (test-writer for ${u.util}, issue #${u.issue}) — FAILING CLI-level tests`,
      '',
      'Write tests that assert the PINNED reference behavior from the briefing for YOUR utility only.',
      'They must FAIL on current code and will pass once the walker cycle_mode change lands.',
      u.util === 'du'
        ? 'Cover: (1) du -L on an ancestor-loop symlink (inner/up -> ..): output shape and exit code exactly as pinned (one line per real dir, cycle diagnostic on stderr, rc as pinned) instead of the current repeated cyc/up/cyc/up walk to the depth bound; (2) du -L sibling-alias counting stays per-path as pinned (guards the no-global-dedup rationale — likely already green).'
        : u.util === 'chown'
          ? 'Cover: (1) chown -RL with a directory and a sibling symlink alias to it: BOTH the real directory tree and the alias path get chowned (use -v to observe visited paths; chown to your own uid so no root needed) — currently the second-encountered alias is skipped; (2) chown -RL on an ancestor loop: terminates with the pinned diagnostic/rc and still chowns the rest.'
          : 'Cover: (1) chmod -RL with a directory and a sibling symlink alias: BOTH get the mode change (verify with stat on the real dir AND through the alias path after setting distinct starting modes) — currently the second-encountered alias is skipped; (2) chmod -RL on an ancestor loop: terminates with the pinned behavior. Use the reference pinned in the briefing (BSD chmod if GNU lacks -L).',
      '',
      'Rules:',
      '- Do NOT touch or rewrite existing tests; do NOT touch walker.zig or any implementation code.',
      `- Hand-edit ONLY: src/${u.util}.zig (test blocks only) and tests/utilities/${u.util}_test.sh.`,
      '- Prefer integration tests (they drive the real binary); add unit tests only where the utility',
      '  test conventions make it practical without referencing walker API that does not exist yet.',
      '  Tests must fail on ASSERTIONS, never on compile errors — do not reference cycle_mode or any',
      '  not-yet-existing symbol.',
      `- Run scoped checks: \`just test-util ${u.util}\` and \`just it-util ${u.util}\`, piped through tail.`,
      '  Confirm your new tests FAIL for the intended reason and everything else passes.',
      '- Loop symlink tests MUST bound runtime (run_with_limit) — the current bug walks to depth 1024.',
      '- Run `just fmt`. Do NOT commit. Report each test, the behavior it guards, and the observed',
      '  failure message (proof of red).',
    ].join('\n');

  let testNotes = await parallel(
    UNITS.map((u) => () =>
      agent(testPrompt(u), {
        label: `test-writer:${u.util}`,
        phase: 'Author tests',
        model: 'sonnet',
        agentType: 'tdd-pipeline:test-writer',
      })),
  );

  // Per-utility review loops, in parallel across utilities.
  phase('Review tests');
  const reviews = await parallel(
    UNITS.map((u, i) => async () => {
      let review = null;
      let note = testNotes[i];
      let round = 0;
      while (round < REVIEW_ROUND_MAX) {
        round += 1;
        review = await agent(
          [
            brief,
            '',
            `## YOUR TASK (test-reviewer for ${u.util}, issue #${u.issue})`,
            `Review the failing tests just added to src/${u.util}.zig and tests/utilities/${u.util}_test.sh.`,
            'Check: pinned reference behavior asserted exactly (not a weaker proxy); failures will be for',
            'the right reason; loop tests bound their runtime; no implementation code touched; no',
            'references to not-yet-existing walker API in test code. Judge BY READING ONLY — do not run',
            'suites or modify anything. Return APPROVED only when nothing remains.',
          ].join('\n'),
          { label: `test-review:${u.util}#${round}`, phase: 'Review tests', model: 'opus', schema: REVIEW_SCHEMA },
        );
        log(`test review ${u.util} round ${round}: ${review.assessment} (${(review.issues || []).length} issues)`);
        if (review.assessment === 'APPROVED') break;
        note = await agent(
          [
            brief,
            '',
            `## YOUR TASK (test-writer for ${u.util}, fix round)`,
            `Your earlier summary: ${note}`,
            '',
            reviewFeedback(review),
            '',
            'Apply every fix; tests must still FAIL on current code for the right reason. Do NOT commit.',
          ].join('\n'),
          { label: `test-writer:${u.util}#fix${round}`, phase: 'Review tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
        );
      }
      return { util: u.util, review, note };
    }),
  );

  phase('Red check');
  const redCheck = await agent(
    [
      '## YOUR TASK (red check — run and report only; no edits)',
      'New failing tests were added for du (#61), chown (#60), and chmod (walker alias bug). Verify the',
      'red is real, for the right reason, on both platforms:',
      '1. macOS: `just test-util du`, `just test-util chown`, `just test-util chmod` and',
      '   `just it-util du`, `just it-util chown`, `just it-util chmod` — the ONLY failures are the',
      '   newly added tests, each failing on its intended assertion (not compile error/crash/timeout).',
      `2. Linux: \`${a.linux_prefix} zig build\` then \`${a.linux_prefix} zig build test -Dtest-util=du\` (and chown, chmod)`,
      `   and \`${a.linux_prefix} bash tests/integration.sh du\` (and chown, chmod) — same red shape.`,
      'Pipe verbose output through tail. Note any loop test that hangs rather than failing fast — that',
      'is a broken test (must be reported, right_reason=false).',
    ].join('\n'),
    { label: 'red-check:wave2', phase: 'Red check', model: 'sonnet', schema: REDCHECK_SCHEMA },
  );
  log(`red check: macos=${redCheck.red_macos} reason=${redCheck.right_reason} rest=${redCheck.rest_green} linux=${redCheck.red_linux}`);

  const allApproved = reviews.filter(Boolean).every((r) => r.review && r.review.assessment === 'APPROVED');
  return {
    phase: 'red',
    briefing,
    test_notes: reviews.filter(Boolean).map((r) => ({ util: r.util, note: r.note, assessment: r.review.assessment })),
    red_check: redCheck,
    ready_to_commit_red:
      allApproved &&
      !!(redCheck && redCheck.red_macos && redCheck.right_reason && redCheck.rest_green && redCheck.red_linux),
  };
}

// ---------------------------------------------------------------------------
// GREEN phase
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
      '## YOUR TASK (implementer) — walker cycle_mode split + consumer migration',
      '',
      'Implement the approved design EXACTLY. Failing CLI tests for du/chown/chmod pin the target',
      'behavior. Scope:',
      '- src/common/walker.zig: replace detect_cycles with the CycleMode enum, add Frame.fs_id, the',
      '  bounded ancestor scan, error.DirectoryCycle + cyclePath(), and gate the three insertion points',
      '  per the design. .ancestors_and_visited must stay bit-for-bit today\'s behavior.',
      '- src/du.zig: .ancestors mode; DirectoryCycle arm in the drain loop printing the pinned',
      '  diagnostic; update the detect_cycles rationale comment; has_error/exit semantics as pinned.',
      '- src/chown.zig and src/chmod.zig: .ancestors mode; restructure their walk loops to report',
      '  DirectoryCycle (and other per-entry errors) and CONTINUE, per the pinned reference.',
      '- Mechanical migration of every other Walker.init call site and test config to the new field',
      '  (cp/grep/find -> .none; mv/rm and their tests -> .ancestors_and_visited; grep @hasField guard).',
      '  Test-code edits here must be strictly mechanical (field renames / new-arg threading); semantic',
      '  test changes go through needs_test_change.',
      '- Tiger Style throughout: bounded ancestor scan asserted against max_depth, 2+ asserts per new',
      '  function, no recursion, 70-line/100-col limits.',
      '',
      'Iterate with FAST checks only: `zig build`, `zig build test -Dtest-util=du` (and chown/chmod),',
      '`just it-util du` (etc.), piped through tail. Walker unit tests run in the full suite — you may',
      'run `zig build test` sparingly (it is the authoritative unit gate here), always through tail.',
      'Do NOT run privileged or full integration; the verify stage does that.',
      '',
      'You may NOT make semantic edits to tests. If a test is wrong (including the walker alias',
      'lock-in test at ~1490 if it conflicts with keeping .ancestors_and_visited semantics), return',
      'outcome=needs_test_change with instructions. Run `just fmt`. Do NOT commit.',
    ].join('\n'),
    'implementer:wave2',
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
        '## YOUR TASK (verify gate — run and report only)',
        'Run EXACTLY:',
        '  - full unit:          "zig build test" (walker is shared code; the full unit suite is the gate)',
        '  - scoped integration: "just it-util du" AND "just it-util chown" AND "just it-util chmod"',
        '  - lint:               "just fmt-check"',
        'Pipe verbose output through tail. unit_pass = full unit green; integration_pass = ALL THREE',
        'scoped integration suites green; lint_clean = fmt passes.',
      ].join('\n'),
      { label: 'verify-gate:wave2', phase: 'Verify gate', model: 'haiku', schema: VERIFY_GATE_SCHEMA },
    );
    const ok = verify.unit_pass && verify.integration_pass && verify.lint_clean;
    if (ok) break;
    if (vfix === GATE_FIX_MAX) break;
    vfix += 1;
    log(`verify gate failed (unit=${verify.unit_pass} it=${verify.integration_pass} lint=${verify.lint_clean}) — re-dispatching implementer.`);
    const vimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, verify-gate fix)',
        `Your earlier summary: ${implNote}`,
        '',
        'The verify gate failed. Make everything pass.',
        `Gate report: ${verify.summary}`,
        `Output excerpt:\n${verify.output_excerpt}`,
        '',
        'If the failure is a WRONG test, return outcome=needs_test_change. Do NOT commit.',
      ].join('\n'),
      `implementer:wave2#vfix${vfix}`,
      'Verify gate',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || vimpl.tests_changed;
    implNote = vimpl.result.summary;
  }

  // Harden the walker characterization tests, then prove their teeth by
  // transient sabotage of walker.zig (the refactor lane for the shared core).
  phase('Harden walker tests');
  let hardenNote = await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — walker unit-test hardening for cycle_mode',
      '',
      'The implementation just landed in the working tree. Revise and extend the walker unit tests in',
      'src/common/walker.zig so the new semantics are pinned:',
      '- REVISE the alias lock-in test (~1490, "whichever is visited first ... skipped"): under',
      '  .ancestors it must assert BOTH the real directory and the sibling alias are fully walked',
      '  (both emit their children). Keep (or add) a companion asserting .ancestors_and_visited still',
      '  dedups exactly as before.',
      '- REVISE/extend the ancestor-loop test (~1324): under .ancestors an ancestor loop yields',
      '  error.DirectoryCycle from next() (re-entrant), cyclePath() names the offending path, and the',
      '  walk terminates promptly.',
      '- ADD: mutual sibling symlinks (a/link_b -> ../b, b/link_a -> ../a) terminate under .ancestors',
      '  with each dir walked exactly twice (trace from the design); .none mode unchanged semantics.',
      '- Each test must assert behavior a wrong implementation would break — no tautologies. They must',
      '  all PASS on the current (fixed) code.',
      'Hand-edit ONLY test code in src/common/walker.zig. Run the walker tests via `zig build test`',
      'piped through tail (confirm green). Run `just fmt`. Do NOT commit. Report each test and the',
      'production behavior it guards.',
    ].join('\n'),
    { label: 'test-writer:walker-harden', phase: 'Harden walker tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
  );

  let sabotage = null;
  let teethFix = 0;
  while (teethFix <= GATE_FIX_MAX) {
    sabotage = await agent(
      [
        brief,
        '',
        '## YOUR TASK (prove the walker tests have teeth via transient sabotage)',
        '',
        'For EACH key walker behavior below, prove its guarding unit test can fail:',
        '  1. Back up src/common/walker.zig to a temp path first.',
        '  2. Apply a MINIMAL mutation breaking that behavior (e.g. skip the ancestor scan, make',
        '     .ancestors dedup like .ancestors_and_visited, drop the DirectoryCycle error, return a',
        '     wrong cyclePath, break the .ancestors_and_visited pre-registration).',
        '  3. Run ONLY the guarding test(s) via `zig build test -Dtest-filter="<test name>"` piped',
        '     through tail; confirm RED.',
        '  4. RESTORE walker.zig from the backup; re-run the same filtered test; confirm GREEN.',
        'Behaviors: (a) .ancestors re-walks sibling aliases; (b) .ancestors detects ancestor loops with',
        'DirectoryCycle + correct cyclePath; (c) .ancestors_and_visited preserves the old global dedup;',
        '(d) mutual sibling symlinks terminate.',
        'After all: `git diff -- src/common/walker.zig` must show ONLY the implementation change from',
        'this branch plus the new tests (no leftover mutation) — report file_restored_clean. Then run',
        'one full `zig build test` through tail to confirm green.',
        'Mutate ONLY src/common/walker.zig, always restore, never run tree-wide formatters, do NOT commit.',
      ].join('\n'),
      { label: 'prove-teeth:walker', phase: 'Harden walker tests', model: 'sonnet', schema: SABOTAGE_SCHEMA },
    );
    log(`prove-teeth: proven=${sabotage.all_behaviors_proven} clean=${sabotage.file_restored_clean}`);
    if (sabotage.all_behaviors_proven && sabotage.file_restored_clean) break;
    if (teethFix === GATE_FIX_MAX) break;
    teethFix += 1;
    const toothless = (sabotage.results || [])
      .filter((r) => !r.went_red)
      .map((r) => `- ${r.behavior}: mutation "${r.mutation}" did not fail ${r.guarding_tests || 'any test'}`)
      .join('\n');
    hardenNote = await agent(
      [
        brief,
        '',
        '## YOUR TASK (test-writer, teeth fix)',
        `Your earlier summary: ${hardenNote}`,
        '',
        'Sabotage proved these walker tests CANNOT fail when their behavior breaks — strengthen them:',
        toothless || '(tree left dirty; ensure tests are intact and pass on real code)',
        '',
        'Keep them green on the current fixed code. Do NOT commit.',
      ].join('\n'),
      { label: `test-writer:walker-teethfix${teethFix}`, phase: 'Harden walker tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
    );
  }

  async function runTigerCheck(label) {
    return await agent(
      [
        '## YOUR TASK (Tiger check — scan, triage, and report)',
        'Run EXACTLY: bash scripts/tiger-check.sh --base HEAD',
        'TAB-separated lines (<rule>\\t<file>:<line>\\t<status>\\t<detail>), status NEW or PRE, then',
        '"SUMMARY total=<N> new=<N>". Triage: confirm genuine NEW violations; FILTER legitimate',
        'dual-use (usize required by std API; while(true) provably bounded with assert). clean=true iff',
        'no confirmed NEW violations. Read to adjudicate; do NOT edit.',
      ].join('\n'),
      { label, phase: 'Tiger check', model: 'haiku', schema: TIGER_SCHEMA },
    );
  }

  phase('Tiger check');
  let tiger = await runTigerCheck('tiger-check:wave2');
  log(`tiger check: clean=${tiger.clean} new=${(tiger.new_violations || []).length} pre=${tiger.preexisting_count}`);
  let tfix = 0;
  while (!tiger.clean && tfix < GATE_FIX_MAX) {
    tfix += 1;
    const violations = (tiger.new_violations || []).map((v) => `- [${v.rule}] ${v.location}: ${v.detail}`).join('\n');
    const timpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, Tiger-check fix)',
        `Your earlier summary: ${implNote}`,
        '',
        'Fix every NEW Tiger Style violation below, keeping all tests green and behavior unchanged:',
        violations,
        '',
        'If a flagged line is legitimate dual-use, say so in your summary. Do NOT commit.',
      ].join('\n'),
      `implementer:wave2#tfix${tfix}`,
      'Tiger check',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || timpl.tests_changed;
    implNote = timpl.result.summary;
    tiger = await runTigerCheck(`tiger-check:wave2#${tfix}`);
    log(`tiger check (after fix ${tfix}): clean=${tiger.clean} new=${(tiger.new_violations || []).length}`);
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
        '## YOUR TASK (adversarial code review of the walker cycle_mode change)',
        '',
        'Review the full diff (git diff against HEAD) with an adversarial eye. This is shared traversal',
        'core used by 8 utilities; a subtle bug here corrupts recursive operations everywhere. Attack:',
        '- Termination: can ANY topology make .ancestors walk forever or blow the stack/entry caps',
        '  pathologically? (mutual aliases, deep alias meshes, symlink chains, loops through the root)',
        '- Bit-for-bit preservation: does .ancestors_and_visited REALLY behave identically to the old',
        '  detect_cycles=true on every path (startRootDir, childDirRejected, collectAndPreprocess,',
        '  including the no_follow/follow_cmdline pre-registration)?',
        '- The re-entrant error contract of next() after DirectoryCycle: frame/path_buf state, dir',
        '  handle leaks, cyclePath() lifetime.',
        '- Resource management on every early-exit path (dir handles closed, path_buf restored).',
        '- Consumer correctness: du exit/diagnostic semantics vs the pin; chown/chmod continue-on-error',
        '  restructures (did aborting-on-first-error semantics change anywhere it should not have?);',
        '  the mechanical .none/.ancestors_and_visited migrations (any consumer accidentally moved to a',
        '  different mode?).',
        '- Tiger Style: bounded loops with asserts, function sizes.',
        'Judge BY READING AND REASONING ONLY — no builds, no test runs (verify gates already ran).',
        'Cite specific code for every issue. Return APPROVED only when nothing real remains.',
      ].join('\n'),
      { label: `code-review:wave2#${round}`, phase: 'Code review', model: 'fable', schema: REVIEW_SCHEMA },
    );
    log(`code review round ${round}: ${codeReview.assessment} (${(codeReview.issues || []).length} issues)`);
    if (codeReview.assessment === 'APPROVED') break;
    const crimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, code-review fix)',
        `Your earlier summary: ${implNote}`,
        '',
        reviewFeedback(codeReview),
        '',
        'Apply every fix, keep all tests green. If a point is a WRONG test, return',
        'outcome=needs_test_change. Do NOT commit.',
      ].join('\n'),
      `implementer:wave2#crfix${round}`,
      'Code review',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || crimpl.tests_changed;
    implNote = crimpl.result.summary;
  }
  if (codeReview.assessment !== 'APPROVED') {
    log(`WARNING: code review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED.`);
  }

  phase('Final verify');
  const finalCheck = await agent(
    [
      '## YOUR TASK (final verify — FULL suites on BOTH platforms, run and report only)',
      'Run EXACTLY (pipe verbose output through tail):',
      '  - macOS full unit:        "zig build test"',
      '  - macOS full privileged:  "just test-privileged"',
      '  - macOS full integration: "just it"',
      `  - Linux full unit:        "${a.linux_prefix} zig build test"`,
      `  - Linux integration:      "${a.linux_prefix} zig build" then "${a.linux_prefix} bash tests/integration.sh du",`,
      `    "${a.linux_prefix} bash tests/integration.sh chown", "${a.linux_prefix} bash tests/integration.sh chmod"`,
      'Report facts only.',
    ].join('\n'),
    { label: 'final-verify:wave2', phase: 'Final verify', model: 'haiku', schema: FINAL_SCHEMA },
  );
  const finalAllPass =
    !!finalCheck &&
    finalCheck.unit_pass &&
    finalCheck.privileged_pass &&
    finalCheck.integration_pass &&
    finalCheck.linux_unit_pass &&
    finalCheck.linux_integration_pass;
  log(`final verify: all=${finalAllPass}`);

  return {
    phase: 'green',
    impl_summary: implNote,
    tests_changed_during_green: testsChangedDuringGreen,
    verify_gate: verify,
    walker_test_note: hardenNote,
    sabotage,
    tiger_check: tiger,
    code_review: codeReview,
    final_verify: finalCheck,
    final_all_pass: finalAllPass,
    ready_to_commit_green:
      !!(verify && verify.unit_pass && verify.integration_pass && verify.lint_clean) &&
      !!(sabotage && sabotage.all_behaviors_proven && sabotage.file_restored_clean) &&
      !!(tiger && tiger.clean) &&
      codeReview.assessment === 'APPROVED' &&
      finalAllPass,
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
log(`wave2-walker: phase=${phaseArg}`);
const result = phaseArg === 'green' ? await runGreen() : await runRed();
return result;
