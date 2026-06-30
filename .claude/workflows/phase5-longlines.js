export const meta = {
  name: 'phase5-longlines',
  description: 'Phase 5: wrap every >100-column line to satisfy the Tiger Style 100-col limit, behavior-preserving, per file',
  phases: [
    { title: 'Wrap', detail: 'wrap long lines; split any fn pushed >70' },
    { title: 'Review', detail: 'formatting-only, no behavior change, all <=100' },
  ],
}

let parsedArgs = args
if (typeof parsedArgs === 'string') parsedArgs = JSON.parse(parsedArgs)
const serialMode = !Array.isArray(parsedArgs) && parsedArgs && parsedArgs.serial === true
const items = Array.isArray(parsedArgs) ? parsedArgs : (parsedArgs && Array.isArray(parsedArgs.items) ? parsedArgs.items : [])
if (items.length === 0) { log('phase5-longlines: no items'); return [] }

const RULES = `Tiger Style: hard 100-column limit, no exceptions. Wrap EVERY line in these files that exceeds
100 columns. This is a FORMATTING change only — preserve behavior exactly.

How to wrap, by line kind:
- Multi-argument function CALL or SIGNATURE: add a trailing comma after the last argument/parameter
  (before the closing \`)\`); \`zig fmt\` then breaks each arg onto its own line. This fixes the majority.
- Long STRING literal: split with Zig multiline strings (\\\\ lines) or \`"a" ++ "b"\` concatenation. The
  concatenated/!joined value MUST be byte-identical to the original — do not add/drop spaces.
- Long COMMENT: wrap onto multiple \`//\` lines at a word boundary.
- Long expression / struct literal: add a trailing comma to the braced/parenthesized group, or hoist a
  subexpression into a \`const\` named binding (only if behavior-identical).
- Format strings in print(): keep the format string intact; break at the argument list comma.

CRITICAL — long-fn coupling: wrapping ADDS lines to a function. If wrapping pushes any function over
70 lines, you MUST extract a helper (faithful extract-method) to keep every function <=70. Do not
leave a new long-fn.

CRITICAL — preserve loop annotations: if a \`while (true)\` (or other loop) already carries a
\`// tiger:allow:unbounded-loop ...\` annotation, keep that annotation ON THE LOOP LINE. If you extract
the loop into a helper or move it, the annotation must move WITH the loop line and stay <=100 cols.
Never strip it (that re-introduces an unbounded-loop violation).

Change NO logic, control flow, types, or string values. Do NOT touch tests (but DO wrap >100-col lines
that are inside test blocks — formatting applies there too; just never change a test's assertions or
logic). NEVER run git checkout/reset/stash. Run \`zig fmt\`. Zig 0.16.

STRICTLY FORBIDDEN: do NOT suppress a long line with \`// tiger:allow:long-line\`. The mandate is to
WRAP every long line, not hide it. If you find an EXISTING \`// tiger:allow:long-line\` annotation in
these files, REMOVE it and genuinely wrap that line. (Keep any \`// tiger:allow:usize-arch\` or
\`// tiger:allow:unbounded-loop\` annotations — those are legitimate and unrelated — but the line they
sit on must still be wrapped to <=100 columns; move the annotation onto the wrapped form.) A line that
ends up <=100 only because of a tiger:allow:long-line suppression counts as FAILED.`

function buildCmd(item) { return item.testUtil ? `zig build test -Dtest-util=${item.testUtil}` : `zig build test` }
function buildNote(item) {
  return item.testUtil
    ? `Verify with \`zig build test -Dtest-util=${item.testUtil}\` (scoped; safe alongside other utils).`
    : `src/common/ file (compiled by every util); verify with full \`zig build test\`. Serial wave.`
}

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['tests_pass', 'long_line_cleared', 'long_fn_zero', 'new_violations', 'fmt_clean', 'logic_unchanged', 'helpers_extracted', 'summary'],
  properties: {
    tests_pass: { type: 'boolean' },
    long_line_cleared: { type: 'boolean', description: 'tiger-check on these files shows 0 long-line.' },
    long_fn_zero: { type: 'boolean', description: 'tiger-check on these files shows 0 long-fn (wrapping did not push a fn over 70, or it was split).' },
    new_violations: { type: 'integer', description: '`new=` from tiger-check --base HEAD; must be 0.' },
    fmt_clean: { type: 'boolean' },
    logic_unchanged: { type: 'boolean' },
    helpers_extracted: { type: 'array', items: { type: 'string' }, description: 'Any helpers extracted to keep functions <=70 after wrapping.' },
    summary: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['approved', 'issues'],
  properties: { approved: { type: 'boolean' }, issues: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['severity', 'location', 'problem'], properties: { severity: { type: 'string', enum: ['blocker', 'minor'] }, location: { type: 'string' }, problem: { type: 'string' } } } }, notes: { type: 'string' } },
}

function implPrompt(item, feedback) {
  const cmd = buildCmd(item)
  return `Wrap all >100-column lines in \`${item.util}\` (files: ${item.files.join(', ')}, vibeutils Zig
0.16). You are the implementer.

${RULES}

${buildNote(item)}
${feedback ? `\nFIX THESE from the previous attempt:\n${feedback}\n` : ''}
Steps: find every >100-col line (\`bash scripts/tiger-check.sh ${item.files[0]}\` lists them as long-line;
check each file). Wrap each per the rules. If any function exceeds 70 after wrapping, extract a helper.
\`zig build fmt\`. Then verify and loop until green:
1. \`${cmd}\` exits 0.
2. \`bash scripts/tiger-check.sh ${item.files.join(' ')}\` shows 0 long-line, 0 long-fn, AND 0
   unbounded-loop (you did not strip any existing loop annotation).
3. \`bash scripts/tiger-check.sh --base HEAD\` shows new=0.
4. \`zig build fmt-check\` exits 0.
5. \`grep -n 'tiger:allow:long-line' ${item.files.join(' ')}\` returns NOTHING (no long-line
   suppressions — every long line must be genuinely wrapped).
Report the structured status.`
}
function reviewPrompt(item) {
  return `Review the line-wrapping of \`${item.util}\` (files: ${item.files.join(', ')}).
\`git diff ${item.files.join(' ')}\`. This must be FORMATTING ONLY.

${RULES}

Check: (1) every wrapped string literal's value is byte-identical to the original (a dropped/added
space or wrong split point is a BLOCKER); (2) no logic/control-flow/type changed — only line breaks,
trailing commas, and behavior-identical const-hoists/helper-extractions; (3) any extracted helper is a
faithful extract-method (BLOCKER if it alters behavior); (4) all lines now <=100 cols. You may run
\`${buildCmd(item)}\` and \`bash scripts/tiger-check.sh ${item.files[0]}\` (expect 0 long-line, 0 long-fn)
but do not edit. approved=true only if zero blockers.`
}

async function processItem(item) {
  let feedback = '', impl = null
  for (let r = 0; r < 3; r++) {
    impl = await agent(implPrompt(item, feedback), { label: `wrap:${item.util}${r ? `#${r + 1}` : ''}`, phase: 'Wrap', schema: IMPL_SCHEMA })
    if (!impl) return null
    if (impl.tests_pass && impl.long_line_cleared && impl.long_fn_zero && impl.new_violations === 0 && impl.fmt_clean && impl.logic_unchanged) break
    feedback = `tests=${impl.tests_pass} long_line_cleared=${impl.long_line_cleared} long_fn_zero=${impl.long_fn_zero} new=${impl.new_violations} fmt=${impl.fmt_clean} logic_unchanged=${impl.logic_unchanged}. ${impl.summary}`
    log(`wrap:${item.util} round ${r + 1} not green`)
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
    const fix = await agent(implPrompt(item, fb), { label: `fix:${item.util}#${r + 1}`, phase: 'Wrap', schema: IMPL_SCHEMA })
    if (!fix) break
    impl = fix
  }
  const bl = review ? (review.issues || []).filter((i) => i.severity === 'blocker') : [{ severity: 'blocker', problem: 'review failed' }]
  return { util: item.util, files: item.files, helpers_extracted: impl ? impl.helpers_extracted : [], impl_status: impl ? { tests: impl.tests_pass, long_line: impl.long_line_cleared, long_fn_zero: impl.long_fn_zero, new: impl.new_violations } : null, review: review ? { approved: review.approved, blockers: bl.length, issues: review.issues } : null, clean: !!(impl && impl.tests_pass && impl.long_line_cleared && impl.long_fn_zero && impl.new_violations === 0 && impl.fmt_clean && impl.logic_unchanged && review && review.approved && bl.length === 0) }
}

phase('Wrap')
log(`phase5-longlines: ${items.length} items${serialMode ? ' (serial)' : ''}`)
let final = []
if (serialMode) { for (let i = 0; i < items.length; i++) { const r = await processItem(items[i]); if (r) final.push(r) } }
else { final = (await parallel(items.map((it) => () => processItem(it)))).filter(Boolean) }
log(`phase5-longlines done: ${final.filter((r) => r.clean).length}/${items.length} clean`)
return final
