export const meta = {
  name: 'phase5-loops',
  description: 'Phase 5: split compound asserts and resolve unbounded loops (bound safely or annotate), per file',
  phases: [
    { title: 'Analyze', detail: 'classify each loop; plan compound-assert splits' },
    { title: 'Implement', detail: 'split asserts, bound/annotate loops, scoped-verify' },
    { title: 'Review', detail: 'adversarial: no truncation risk, justifications true' },
  ],
}

let parsedArgs = args
if (typeof parsedArgs === 'string') parsedArgs = JSON.parse(parsedArgs)
const serialMode = !Array.isArray(parsedArgs) && parsedArgs && parsedArgs.serial === true
const items = Array.isArray(parsedArgs) ? parsedArgs : (parsedArgs && Array.isArray(parsedArgs.items) ? parsedArgs.items : [])
if (items.length === 0) { log('phase5-loops: no items'); return [] }

const RULES = `Tiger Style rules for this pass (two violation types):

1. COMPOUND ASSERT — \`std.debug.assert(a and b)\` must become \`std.debug.assert(a); std.debug.assert(b);\`
   Split every compound assert (any number of \`and\`-ed terms) into one assert per term. Trivial and
   always safe. (Do NOT split \`or\` conditions — only top-level \`and\`.)

2. UNBOUNDED LOOP — \`while (true)\` (and other loops the scanner flags) must either be bounded or
   carry an inline justification. THE TRAP: never add a numeric cap that could TRUNCATE valid input.
   Classify each flagged loop and apply the matching fix:
   - INPUT/STREAM/EOF-driven (reads lines/bytes/dir entries until EOF or a terminator; count is
     unbounded a priori): DO NOT add a numeric cap (it would silently drop data). Add an inline
     comment annotation on the loop's line:
       \`// tiger:allow:unbounded-loop <why it always terminates, e.g. terminates at EOF / on reader
       end / when the iterator is exhausted>\`
     The annotation must state the REAL termination condition. This is the correct, honest fix for
     I/O loops.
   - FINITE-COLLECTION (iterates a slice/array/known count): rewrite as a bounded \`for\`/\`while\` with
     the explicit bound, only if the bound provably covers every valid input.
   - GENUINE EVENT LOOP (cannot terminate by design): keep \`while (true)\` and add
     \`// tiger:allow:unbounded-loop <reason it is intentionally non-terminating>\`.
   The scanner honors \`// tiger:allow:unbounded-loop\` on the flagged line.

GENERAL: change NO observable behavior. Asserts/annotations/equivalent-bound-rewrites only. Do NOT
touch tests. NEVER run git checkout/reset/stash. Run \`zig fmt\`. Keep every function <=70 lines
(splitting an assert adds a line — if that pushes a function over 70, extract a helper). Zig 0.16.`

function buildCmd(item) { return item.testUtil ? `zig build test -Dtest-util=${item.testUtil}` : `zig build test` }
function buildNote(item) {
  return item.testUtil
    ? `Verify with \`zig build test -Dtest-util=${item.testUtil}\` (scoped; safe alongside other utils).`
    : `src/common/ file (every util compiles it); verify with full \`zig build test\`. This wave is serial.`
}

const ANALYZE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['util', 'compound_asserts', 'loops'],
  properties: {
    util: { type: 'string' },
    compound_asserts: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['location', 'terms'], properties: { location: { type: 'string' }, terms: { type: 'integer' } } } },
    loops: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['location', 'kind', 'fix'], properties: {
      location: { type: 'string' },
      kind: { type: 'string', enum: ['input_stream', 'finite_collection', 'event_loop'] },
      fix: { type: 'string', description: 'For input_stream/event_loop: the exact tiger:allow reason. For finite_collection: the bound expression and why it covers all valid input.' },
    } } },
  },
}
const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['tests_pass', 'compound_cleared', 'loops_cleared', 'new_violations', 'long_fn_zero', 'fmt_clean', 'logic_unchanged', 'summary'],
  properties: {
    tests_pass: { type: 'boolean' }, compound_cleared: { type: 'boolean' }, loops_cleared: { type: 'boolean' },
    new_violations: { type: 'integer' }, long_fn_zero: { type: 'boolean', description: 'tiger-check on this file shows no long-fn (splitting asserts did not push a fn over 70).' },
    fmt_clean: { type: 'boolean' }, logic_unchanged: { type: 'boolean' }, summary: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['approved', 'issues'],
  properties: { approved: { type: 'boolean' }, issues: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['severity', 'location', 'problem'], properties: { severity: { type: 'string', enum: ['blocker', 'minor'] }, location: { type: 'string' }, problem: { type: 'string' } } } }, notes: { type: 'string' } },
}

function analyzePrompt(item) {
  return `Analyze \`${item.util}\` (files: ${item.files.join(', ')}, vibeutils Zig 0.16) for Phase 5
loop/assert cleanup. READ ONLY.

${RULES}

Find every compound assert (\`std.debug.assert(... and ...)\`) and every scanner-flagged unbounded loop
(\`bash scripts/tiger-check.sh ${item.files[0]}\` lists them as compound-assert / unbounded-loop; check
every file). For each loop, READ it carefully and classify (input_stream / finite_collection /
event_loop) and give the exact fix — especially the real termination reason for the annotation, or the
provably-safe bound. Be careful: most \`while (true)\` here are I/O read loops that must be ANNOTATED,
not capped. Do not edit.`
}
function implementPrompt(item, plan, feedback) {
  const cmd = buildCmd(item)
  return `Apply Phase 5 loop/assert fixes to \`${item.util}\` (files: ${item.files.join(', ')}).

${RULES}

${buildNote(item)}

Plan:
${JSON.stringify(plan, null, 2)}
${feedback ? `\nFIX THESE from the previous attempt:\n${feedback}\n` : ''}
Steps: split every compound assert; for each loop apply its planned fix (annotate input_stream/
event_loop with \`// tiger:allow:unbounded-loop <reason>\`; convert finite_collection to a bounded form
only if the bound covers all valid input — NEVER risk truncation). \`zig build fmt\`. Then verify and
loop until green:
1. \`${cmd}\` exits 0.
2. \`bash scripts/tiger-check.sh ${item.files[0]}\` (and each file) shows 0 compound-assert and 0
   unbounded-loop.
3. \`bash scripts/tiger-check.sh --base HEAD\` shows new=0; and no long-fn anywhere in these files.
4. \`zig build fmt-check\` exits 0.
Report the structured status.`
}
function reviewPrompt(item) {
  return `Adversarial review of Phase 5 loop/assert cleanup on \`${item.util}\` (files:
${item.files.join(', ')}). \`git diff ${item.files.join(' ')}\`.

${RULES}

THE CRITICAL CHECK: for any loop that was converted to a numeric/bounded form, prove the bound CANNOT
truncate valid input (find an input that exceeds it -> BLOCKER). For any \`// tiger:allow:unbounded-loop\`
annotation, verify the stated termination reason is actually TRUE (a loop that can spin forever with a
false "terminates at EOF" claim -> BLOCKER). Confirm compound-assert splits preserve the exact
conjunction. Confirm NO other logic changed. You may run \`${buildCmd(item)}\` and
\`bash scripts/tiger-check.sh ${item.files[0]}\` (expect 0 compound-assert, 0 unbounded-loop) but do not
edit. approved=true only if zero blockers.`
}

async function processItem(item) {
  const plan = await agent(analyzePrompt(item), { label: `analyze:${item.util}`, phase: 'Analyze', schema: ANALYZE_SCHEMA }).catch(() => null)
  if (!plan) return null
  let feedback = '', impl = null
  for (let r = 0; r < 3; r++) {
    impl = await agent(implementPrompt(item, plan, feedback), { label: `impl:${item.util}${r ? `#${r + 1}` : ''}`, phase: 'Implement', schema: IMPL_SCHEMA })
    if (!impl) return null
    if (impl.tests_pass && impl.compound_cleared && impl.loops_cleared && impl.new_violations === 0 && impl.long_fn_zero && impl.fmt_clean && impl.logic_unchanged) break
    feedback = `tests=${impl.tests_pass} compound_cleared=${impl.compound_cleared} loops_cleared=${impl.loops_cleared} new=${impl.new_violations} long_fn_zero=${impl.long_fn_zero} fmt=${impl.fmt_clean} logic_unchanged=${impl.logic_unchanged}. ${impl.summary}`
    log(`impl:${item.util} round ${r + 1} not green`)
  }
  let review = null
  for (let r = 0; r < 3; r++) {
    review = await agent(reviewPrompt(item), { label: `review:${item.util}${r ? `#${r + 1}` : ''}`, phase: 'Review', schema: REVIEW_SCHEMA })
    if (!review) break
    const bl = (review.issues || []).filter((i) => i.severity === 'blocker')
    if (review.approved && bl.length === 0) break
    if (r === 2) break
    const fb = bl.map((b) => `[${b.location}] ${b.problem}`).join('\n')
    log(`review:${item.util} ${bl.length} blocker(s)`)
    const fix = await agent(implementPrompt(item, plan, fb), { label: `fix:${item.util}#${r + 1}`, phase: 'Implement', schema: IMPL_SCHEMA })
    if (!fix) break
    impl = fix
  }
  const bl = review ? (review.issues || []).filter((i) => i.severity === 'blocker') : [{ severity: 'blocker', problem: 'review failed' }]
  return { util: item.util, files: item.files, impl_status: impl ? { tests: impl.tests_pass, compound: impl.compound_cleared, loops: impl.loops_cleared, new: impl.new_violations, long_fn_zero: impl.long_fn_zero } : null, review: review ? { approved: review.approved, blockers: bl.length, issues: review.issues } : null, clean: !!(impl && impl.tests_pass && impl.compound_cleared && impl.loops_cleared && impl.new_violations === 0 && impl.long_fn_zero && impl.fmt_clean && impl.logic_unchanged && review && review.approved && bl.length === 0) }
}

phase('Analyze')
log(`phase5-loops: ${items.length} items${serialMode ? ' (serial)' : ''}`)
let final = []
if (serialMode) { for (let i = 0; i < items.length; i++) { const r = await processItem(items[i]); if (r) final.push(r) } }
else { final = (await parallel(items.map((it) => () => processItem(it)))).filter(Boolean) }
log(`phase5-loops done: ${final.filter((r) => r.clean).length}/${items.length} clean`)
return final
