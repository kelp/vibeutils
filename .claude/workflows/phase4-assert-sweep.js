export const meta = {
  name: 'phase4-assert-sweep',
  description: 'Add meaningful Tiger Style assertions (>=2/function average) to a utility, with adversarial invariant-truth review',
  phases: [
    { title: 'Analyze', detail: 'find real invariants worth asserting per function' },
    { title: 'Implement', detail: 'add asserts, strengthen placeholders, scoped-verify' },
    { title: 'Review', detail: 'adversarial: every assert a TRUE invariant, no tautologies' },
  ],
}

// args: array (parallel, scoped-build isolated) OR { serial:true, items:[...] }
// (serial required for src/common/, compiled by every util).
// item: { util, testUtil, files:[path...] }
let parsedArgs = args
if (typeof parsedArgs === 'string') {
  parsedArgs = JSON.parse(parsedArgs)
}
const serialMode = !Array.isArray(parsedArgs) && parsedArgs && parsedArgs.serial === true
const items = Array.isArray(parsedArgs)
  ? parsedArgs
  : (parsedArgs && Array.isArray(parsedArgs.items) ? parsedArgs.items : [])
if (items.length === 0) {
  log('phase4-assert-sweep: no items in args; nothing to do')
  return []
}

const RULES = `Tiger Style assertion rules for this sweep:
- Add std.debug.assert calls that capture REAL invariants: argument preconditions, postconditions,
  loop bounds, buffer/index bounds, valid-state/enum invariants, and relationships between
  compile-time constants. Target an AVERAGE of >=2 asserts per function across the file.
- Assert the positive space you EXPECT and the negative space you DON'T. Pair a property across at
  least two code paths where natural.
- Split compound asserts: assert(a); assert(b); NOT assert(a and b).
- Assert conditions MUST be side-effect-free: no mutation, no allocation, no I/O, no function calls
  that mutate. Pure reads only. An assert must never change behavior in ReleaseFast (where it
  compiles out) — it only turns an invalid state into a loud panic in Debug/Safe builds.

CRITICAL — the invariant-truth bar (this is where assertions go wrong):
- An assert is correct ONLY if it holds for EVERY valid input/invocation, not just the tested ones.
  If any valid CLI invocation, env var, empty string, zero, max value, or absent optional could make
  it fire, it is WRONG and would be a regression (turning a previously-handled input into a panic).
  Example of the trap we already hit: cp added assert(backup_suffix.len > 0), but \`cp -b -S ''\` is a
  valid invocation with an empty suffix -> that assert is wrong. Think adversarially about edges.
- Prefer asserting on values the function CONTROLS or that are genuinely guaranteed upstream, over
  asserting on raw user input that the code is supposed to tolerate.

DO NOT add tautological / vacuous asserts (these are worse than nothing — they pad the count while
proving zero, and the review WILL reject them):
- @TypeOf(x) == SomeType (the type system already guarantees this).
- len >= 0 / x >= 0 on an unsigned (usize/u32/...) — always true.
- @intFromBool(b) <= 1 — always true.
- x != A immediately after asserting x == B (when A != B is implied).
- comparing a value to the bounds of its own type (x <= maxInt(@TypeOf(x))).
If a function has NO meaningful invariant to assert (a trivial wrapper, a pure dispatcher), add
NOTHING to it and say so — do not invent filler. The file-level average is what matters.

You are ONLY adding asserts (and wrapping any assert line that would exceed 100 cols). Change NO
logic: no reordered statements, no altered control flow, no new variables except where strictly
needed to name a value for an assert (avoid even that when possible). git diff must be assert
additions (and necessary line-wraps) only.

Zig 0.16 project. Use std.debug.assert. Do NOT touch any test (embedded \`test "..."\` blocks or
anything under tests/). NEVER run git checkout/reset/stash.`

function buildCmd(item) {
  return item.testUtil ? `zig build test -Dtest-util=${item.testUtil}` : `zig build test`
}
function buildNote(item) {
  if (item.testUtil) {
    return `Verify with \`zig build test -Dtest-util=${item.testUtil}\` (Debug -> asserts ACTIVE). This
compiles ONLY this util + common, safe to run while other agents edit other utils. NEVER run a full
\`zig build test\`/\`just build\` here.`
  }
  return `This is a src/common/ file compiled by EVERY utility; verify with the full \`zig build test\`
(Debug -> asserts ACTIVE). This wave is serial, so the full build is safe.`
}

const ANALYZE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['util', 'functions', 'placeholders_to_fix'],
  properties: {
    util: { type: 'string' },
    functions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'has_meaningful_invariant', 'asserts'],
        properties: {
          name: { type: 'string' },
          has_meaningful_invariant: { type: 'boolean' },
          asserts: {
            type: 'array',
            description: 'Concrete asserts to add. Empty if has_meaningful_invariant is false.',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['expr', 'why_true_for_all_valid_inputs'],
              properties: {
                expr: { type: 'string', description: 'The exact assert condition, e.g. "buf.len >= count".' },
                why_true_for_all_valid_inputs: { type: 'string', description: 'Why this holds for EVERY valid input, not just tested ones.' },
              },
            },
          },
        },
      },
    },
    placeholders_to_fix: {
      type: 'array',
      description: 'Existing tautological/vacuous asserts (e.g. from Phase 3) to strengthen or remove.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['location', 'current', 'action'],
        properties: {
          location: { type: 'string' },
          current: { type: 'string' },
          action: { type: 'string', description: 'strengthen-to <expr>, or remove' },
        },
      },
    },
    notes: { type: 'string' },
  },
}

const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['tests_pass', 'new_violations', 'fmt_clean', 'asserts_added', 'placeholders_fixed', 'logic_unchanged', 'summary'],
  properties: {
    tests_pass: { type: 'boolean', description: 'Did the scoped/full `zig build test` (Debug, asserts active) pass? No assert fired on a test.' },
    new_violations: { type: 'integer', description: '`new=` from `bash scripts/tiger-check.sh --base HEAD`. Must be 0.' },
    fmt_clean: { type: 'boolean' },
    asserts_added: { type: 'integer' },
    placeholders_fixed: { type: 'integer' },
    logic_unchanged: { type: 'boolean', description: 'Confirm the diff is assert additions (+ necessary line wraps) ONLY — no logic change.' },
    summary: { type: 'string' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['approved', 'issues'],
  properties: {
    approved: { type: 'boolean' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'location', 'problem'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'minor'] },
          location: { type: 'string' },
          problem: { type: 'string', description: 'For a wrong assert, give the valid input that fires it. For a tautology, say why it is vacuous.' },
        },
      },
    },
    notes: { type: 'string' },
  },
}

function analyzePrompt(item) {
  return `Analyze the \`${item.util}\` utility (files: ${item.files.join(', ')}) for Tiger Style
assertion coverage (vibeutils, Zig 0.16). READ ONLY — do not edit.

${RULES}

For each function in the file(s) (production code only, NOT test blocks), decide what REAL invariants
are worth asserting and give the exact assert expressions with a justification of why each holds for
EVERY valid input. Mark functions that have no meaningful invariant (has_meaningful_invariant=false,
empty asserts) — they get nothing. Also list any existing tautological/vacuous asserts (Phase 3 left
placeholders like @TypeOf(x)==u32 or len>=0 on usize) to strengthen or remove.

Return the structured analysis. Be adversarial about edge inputs (empty strings, 0, max, absent
optionals) so you never propose an assert that a valid invocation could fire.`
}

function implementPrompt(item, plan, feedback) {
  const cmd = buildCmd(item)
  return `Add Tiger Style assertions to the \`${item.util}\` utility (files: ${item.files.join(', ')},
vibeutils Zig 0.16). You are the implementer.

${RULES}

${buildNote(item)}

Plan from the analyzer (add these, fix the placeholders):
${JSON.stringify({ functions: plan.functions.filter((f) => f.has_meaningful_invariant), placeholders: plan.placeholders_to_fix }, null, 2)}
${feedback ? `\nFIX THESE problems from the previous attempt (the reviewer found them):\n${feedback}\n` : ''}
Workflow:
1. Add the planned asserts; strengthen/remove the listed placeholders. Split any compound assert.
2. \`zig build fmt\` to format; wrap any assert line over 100 cols.
3. Verify and FIX until green (loop yourself):
   a. \`${cmd}\` exits 0 — Debug build, so asserts are ACTIVE; a green run proves none of your asserts
      fire on the test suite's valid inputs. If one fires, your assert is WRONG (not a true
      invariant) — remove or correct it, do NOT weaken a test.
   b. \`bash scripts/tiger-check.sh --base HEAD\` SUMMARY shows \`new=0\`.
   c. \`zig build fmt-check\` exits 0.
4. Confirm the diff is assert additions (+ necessary wraps) ONLY — no logic change.

Report the structured status. tests_pass, new_violations=0, fmt_clean, logic_unchanged all required.`
}

function reviewPrompt(item) {
  return `Adversarial review of a Tiger Style assertion sweep on \`${item.util}\` (files:
${item.files.join(', ')}, vibeutils Zig 0.16). Review the diff with \`git diff ${item.files.join(' ')}\`.

${RULES}

This is the SAFETY GATE. For EACH added or changed assert, check:
1. INVARIANT-TRUTH (most important): does the condition hold for EVERY valid input/invocation, not
   just the tested ones? Try to find a valid input that fires it — an empty string, 0, a max value,
   an absent optional, an unusual-but-legal CLI flag combo, an env var. If you can, it is a BLOCKER
   (it would turn a previously-handled input into a panic in Debug/Safe builds). Recall the cp
   \`backup_suffix.len > 0\` vs \`cp -b -S ''\` trap.
2. MEANINGFUL: is it a real check, or a tautology (@TypeOf==T, len>=0 on unsigned, @intFromBool<=1,
   x!=A right after x==B, value vs its own type bounds)? Tautologies are BLOCKERS — they must be
   removed or replaced with a real invariant.
3. SIDE-EFFECT-FREE: the condition must not mutate/allocate/do I/O.
4. NO LOGIC CHANGE: the diff must be assert additions (+ line wraps) only — any altered statement,
   control flow, or new non-assert variable is a BLOCKER.

You may run \`${buildCmd(item)}\` (Debug, asserts active) to confirm green, and
\`bash scripts/tiger-check.sh --base HEAD\` (expect new=0), but do NOT edit any file. Approve=true
ONLY if zero blocker issues. For each blocker assert, name the exact valid input that fires it (or
why it is vacuous).`
}

async function processItem(item) {
  const plan = await agent(analyzePrompt(item), { label: `analyze:${item.util}`, phase: 'Analyze', schema: ANALYZE_SCHEMA }).catch(() => null)
  if (!plan) return null

  let feedback = ''
  let impl = null
  for (let round = 0; round < 3; round++) {
    impl = await agent(implementPrompt(item, plan, feedback), {
      label: `impl:${item.util}${round ? `#${round + 1}` : ''}`,
      phase: 'Implement',
      schema: IMPL_SCHEMA,
    })
    if (!impl) return null
    const ok = impl.tests_pass && impl.new_violations === 0 && impl.fmt_clean && impl.logic_unchanged
    if (ok) break
    feedback = `tests_pass=${impl.tests_pass} new_violations=${impl.new_violations} fmt_clean=${impl.fmt_clean} logic_unchanged=${impl.logic_unchanged}. ${impl.summary}`
    log(`impl:${item.util} round ${round + 1} not green — retrying`)
  }

  let review = null
  for (let round = 0; round < 3; round++) {
    review = await agent(reviewPrompt(item), {
      label: `review:${item.util}${round ? `#${round + 1}` : ''}`,
      phase: 'Review',
      schema: REVIEW_SCHEMA,
    })
    if (!review) break
    const blockers = (review.issues || []).filter((i) => i.severity === 'blocker')
    if (review.approved && blockers.length === 0) break
    if (round === 2) break
    const fb = blockers.map((b) => `[${b.location}] ${b.problem}`).join('\n')
    log(`review:${item.util} round ${round + 1} found ${blockers.length} blocker(s) — fixing`)
    const fix = await agent(implementPrompt(item, plan, fb), { label: `fix:${item.util}#${round + 1}`, phase: 'Implement', schema: IMPL_SCHEMA })
    if (!fix) break
    impl = fix
  }

  const blockers = review ? (review.issues || []).filter((i) => i.severity === 'blocker') : [{ severity: 'blocker', problem: 'review agent failed' }]
  return {
    util: item.util,
    files: item.files,
    asserts_added: impl ? impl.asserts_added : 0,
    placeholders_fixed: impl ? impl.placeholders_fixed : 0,
    impl_status: impl ? { tests: impl.tests_pass, new_violations: impl.new_violations, fmt: impl.fmt_clean, logic_unchanged: impl.logic_unchanged } : null,
    review: review ? { approved: review.approved, blockers: blockers.length, issues: review.issues } : null,
    clean: !!(impl && impl.tests_pass && impl.new_violations === 0 && impl.fmt_clean && impl.logic_unchanged && review && review.approved && blockers.length === 0),
  }
}

phase('Analyze')
log(`phase4-assert-sweep: ${items.length} utilities${serialMode ? ' (serial)' : ''}`)

let final = []
if (serialMode) {
  for (let i = 0; i < items.length; i++) {
    log(`serial ${i + 1}/${items.length}: ${items[i].util}`)
    const r = await processItem(items[i])
    if (r) final.push(r)
  }
} else {
  final = (await parallel(items.map((it) => () => processItem(it)))).filter(Boolean)
}

const clean = final.filter((r) => r.clean)
log(`phase4-assert-sweep done: ${clean.length}/${items.length} utilities clean`)
return final
