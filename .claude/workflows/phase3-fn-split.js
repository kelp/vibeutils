export const meta = {
  name: 'phase3-fn-split',
  description: 'Split over-70-line functions into ≤70-line helpers (behavior-preserving), grouped per utility',
  phases: [
    { title: 'Plan', detail: 'design extraction + locate covering tests + sabotage points' },
    { title: 'Implement', detail: 'extract helpers, scoped-verify, loop until green' },
    { title: 'Prove teeth', detail: 'mutate refactored code, confirm scoped tests go RED, restore' },
    { title: 'Review', detail: 'adversarial faithfulness review, fix loop' },
  ],
}

// args: [{ util, testUtil, files:[path...], functions:[{name, file, body_lines}], serial?:bool }]
// testUtil: the -Dtest-util scope name, or null for common/ files (use full `zig build test`).
let parsedArgs = args
if (typeof parsedArgs === 'string') {
  parsedArgs = JSON.parse(parsedArgs)
}
// args is either an array (run items in parallel, scoped-build isolated) or
// { serial: true, items: [...] } (run one at a time — required for common/
// files, which every util compiles, so parallel full builds would contaminate).
const serialMode = !Array.isArray(parsedArgs) && parsedArgs && parsedArgs.serial === true
const items = Array.isArray(parsedArgs)
  ? parsedArgs
  : (parsedArgs && Array.isArray(parsedArgs.items) ? parsedArgs.items : [])
if (items.length === 0) {
  log('phase3-fn-split: no items in args; nothing to do')
  return []
}

// Tiger Style constraints every agent must honor. Kept in one constant so the
// rules are identical across plan, implement, and review.
const TIGER = `Tiger Style rules that govern this refactor:
- Hard limit 70 lines per function body (excluding signature/closing brace). After
  the split EVERY function in scope, and every helper you create, must be <=70 lines.
- Minimum two assertions per function on average. Each new helper gets >=2 std.debug.assert
  asserting its preconditions/invariants (assert the positive space you expect AND negative
  space you don't). Split compound asserts: assert(a); assert(b); not assert(a and b).
- snake_case names. A helper called by a single function is prefixed with the caller's name
  (e.g. parsePrimary -> parsePrimary_matchTest). Callbacks go last in the param list.
- No recursion. Bound every loop. Use explicitly-sized ints (u32/u64), not usize, EXCEPT
  where a std API forces usize (slice indexing) — match the existing code's pattern.
- 100-column hard limit. 4-space indent. Run \`zig fmt\` (or \`zig build fmt\`) before finishing.
- "Push ifs up, push fors down": keep branching in the parent; move straight-line work into
  helpers. Helpers take primitive args where practical (no \`self\`) so hot loops optimize.
- For args >16 bytes that shouldn't be copied, pass *const T.

Zig 0.16 (this project): blocking APIs take an \`io: Io\` param; stdout/stderr use
writerStreaming; env is routed via init, not global. DO NOT change any I/O or arg-passing
pattern — you are ONLY relocating existing logic into helpers. If unsure whether a change
alters behavior, it does: keep it identical.`

function buildNote(item) {
  if (item.testUtil) {
    return `Scoped build/test command for this util: \`zig build test -Dtest-util=${item.testUtil}\`. This
compiles ONLY this util + the common module (build.zig scopes via -Dtest-util), so it is safe to
run while other agents edit other utils. NEVER run a full \`zig build test\` or \`just build\` here —
it would recompile other utils that may be mid-edit and fail spuriously.`
  }
  return `This is a src/common/ file compiled by EVERY utility, so it cannot be scoped — the correct
verify command is the full \`zig build test\`. This wave runs serially (one common file at a time),
so the full build is safe: no other file is being edited concurrently. Use \`zig build test\`.`
}

const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['util', 'functions'],
  properties: {
    util: { type: 'string' },
    functions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'file', 'extraction', 'covering_tests', 'sabotage'],
        properties: {
          name: { type: 'string' },
          file: { type: 'string' },
          extraction: {
            type: 'string',
            description: 'Plain-English plan: which contiguous blocks become which named helpers, and the resulting line budget per piece.',
          },
          covering_tests: {
            type: 'string',
            description: 'Which existing unit test(s) in this file exercise this function. State "NONE (unit)" if only integration tests cover it.',
          },
          sabotage: {
            type: 'object',
            additionalProperties: false,
            required: ['has_unit_coverage', 'mutation', 'expected_failure'],
            properties: {
              has_unit_coverage: { type: 'boolean' },
              mutation: { type: 'string', description: 'A concrete one-line behavior-breaking mutation (exact code change) inside this function that a covering unit test should catch. Empty if has_unit_coverage is false.' },
              expected_failure: { type: 'string', description: 'Which test name should fail under that mutation. Empty if no unit coverage.' },
            },
          },
        },
      },
    },
    risks: { type: 'string', description: 'Any function that resists a clean split, or shared local state that complicates extraction.' },
  },
}

const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['scoped_tests_pass', 'new_violations', 'targets_cleared', 'fmt_clean', 'helpers_added', 'summary'],
  properties: {
    scoped_tests_pass: { type: 'boolean', description: 'Did the scoped `zig build test -Dtest-util=X` (or full build for common/) pass?' },
    new_violations: { type: 'integer', description: 'The `new=` count from `bash scripts/tiger-check.sh --base HEAD`. Must be 0.' },
    targets_cleared: { type: 'boolean', description: 'Do NONE of the target functions still appear as long-fn in `bash scripts/tiger-check.sh src/<file>`?' },
    fmt_clean: { type: 'boolean' },
    helpers_added: { type: 'array', items: { type: 'string' }, description: 'Names of helper functions created.' },
    summary: { type: 'string' },
  },
}

const TEETH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['per_function', 'restored_clean', 'scoped_tests_green_after_restore'],
  properties: {
    per_function: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'teeth_confirmed', 'detail'],
        properties: {
          name: { type: 'string' },
          teeth_confirmed: { type: 'boolean', description: 'Did the mutation make a scoped unit test FAIL (RED)? false if no unit coverage or mutation did not trip a test.' },
          detail: { type: 'string' },
        },
      },
    },
    restored_clean: { type: 'boolean', description: 'After reverting every mutation, does `git diff src/<file>` contain ONLY the split (no leftover mutation)?' },
    scoped_tests_green_after_restore: { type: 'boolean' },
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
          problem: { type: 'string' },
        },
      },
    },
    notes: { type: 'string' },
  },
}

function scopedCmd(item) {
  return item.testUtil ? `zig build test -Dtest-util=${item.testUtil}` : `zig build test`
}

function fnList(item) {
  return item.functions
    .map((f) => `  - ${f.name} (${f.file}, ~${f.body_lines} body lines)`)
    .join('\n')
}

function planPrompt(item) {
  return `You are designing a behavior-preserving function split for the \`${item.util}\` utility in
the vibeutils Zig 0.16 project. These functions exceed Tiger Style's 70-line limit and must be
decomposed into <=70-line helpers WITHOUT changing any behavior:

${fnList(item)}

Files: ${item.files.join(', ')}

${TIGER}

Your job (READ ONLY — do not edit anything):
1. For each target function, read it and design the extraction: which contiguous blocks become
   which named helpers, so that the parent and every helper land <=70 lines. Prefer extracting
   self-contained straight-line blocks; keep branching in the parent (push ifs up).
2. Identify the existing UNIT test(s) in the same file that exercise each function. If only
   integration tests cover it, say so (has_unit_coverage=false).
3. For each function WITH unit coverage, specify one concrete behavior-breaking mutation (exact
   code edit) that a named unit test should catch — this is used later to prove the tests have
   teeth over the refactored code.

Return the structured plan. Do not write code.`
}

function implementPrompt(item, plan, feedback) {
  const cmd = scopedCmd(item)
  return `You are the implementer for a behavior-preserving function split of the \`${item.util}\`
utility (vibeutils, Zig 0.16). Extract helpers so EVERY one of these functions drops to <=70 lines,
changing NO observable behavior — you are relocating existing logic into named helpers, nothing more:

${fnList(item)}

Files you may edit: ${item.files.join(', ')} ONLY.

Extraction plan from the designer:
${JSON.stringify(plan.functions.map((f) => ({ name: f.name, extraction: f.extraction })), null, 2)}

${TIGER}

${buildNote(item)}

HARD CONSTRAINTS:
- Edit ONLY the source file(s) listed. NEVER touch any test (embedded \`test "..."\` blocks in the
  file, or anything under tests/). If you think a test is wrong, STOP and report it — do not edit it.
- NEVER run \`git checkout\`, \`git reset\`, or \`git stash\` — other agents have uncommitted work in
  sibling files. Edit only via Edit/Write on your file(s).
- Faithful extraction only: same logic, same control flow, same error handling, same types. No
  "cleanup", no behavior tweaks, no new features.
${feedback ? `\nFIX THESE problems from the previous attempt:\n${feedback}\n` : ''}
Workflow:
1. Make the extractions per the plan. Add >=2 asserts to each new helper.
2. Run \`zig build fmt\` to format.
3. Verify, and FIX until all green (loop yourself):
   a. \`${cmd}\` exits 0 (scoped tests pass).
   b. \`bash scripts/tiger-check.sh --base HEAD\` shows \`new=0\` in its SUMMARY line.
   c. \`bash scripts/tiger-check.sh ${item.files[0]}\` shows NONE of the target functions as long-fn
      (grep the output for long-fn; the target names must be absent). Check every edited file.
   d. \`zig build fmt-check\` exits 0.
4. If a new helper itself exceeds 70 lines, split it further. If a line exceeds 100 cols, wrap it.
   If tiger-check flags a usize param you introduced, redesign to avoid it, or — only if a std API
   truly forces it — add \`// tiger:allow:usize-arch <reason>\` on that exact line.

Report the structured status. scoped_tests_pass, new_violations=0, targets_cleared=true, and
fmt_clean=true are all REQUIRED for success.`
}

function teethPrompt(item, plan) {
  const cmd = scopedCmd(item)
  const covered = plan.functions.filter((f) => f.sabotage && f.sabotage.has_unit_coverage)
  const mutations = covered
    .map((f) => `  - ${f.name}: mutation = ${f.sabotage.mutation}  (expected to fail test: ${f.sabotage.expected_failure})`)
    .join('\n')
  return `You are proving the existing unit tests have TEETH over the just-refactored \`${item.util}\`
code (vibeutils). The file(s) ${item.files.join(', ')} now contain a behavior-preserving split that
passes scoped tests GREEN. Your job: confirm a deliberate bug in the refactored code is actually
caught by a unit test (transient mutation testing), then restore exactly.

${covered.length === 0
    ? 'The designer found NO unit coverage for these functions (integration-only). Run the scoped tests once to confirm GREEN, then report every function with teeth_confirmed=false and detail="integration-only; no unit coverage". Do NOT mutate anything.'
    : `For EACH function below, one at a time:
${mutations}

Procedure per function (CRITICAL — follow exactly):
1. Read the file and locate the line to mutate inside the refactored code (the helper or parent
   that now owns that logic). Apply the mutation with a SINGLE localized Edit (record the exact
   old_string you replaced).
2. Run \`${cmd}\`. It MUST now FAIL (RED). If it fails, teeth_confirmed=true. If it still passes,
   teeth_confirmed=false (the tests do not cover this path) — note that.
3. REVERT with the inverse Edit (new_string -> the exact old_string you recorded). NEVER use
   \`git checkout\`/\`reset\`/\`stash\`.
4. Move to the next function only after the revert.`}

After all functions:
- Run \`${cmd}\` once more — it MUST be GREEN (scoped_tests_green_after_restore=true). If RED, your
  revert was imperfect: fix it via Edit until the split is intact and tests pass.
- Run \`git diff --stat ${item.files[0]}\` (and each edited file): it MUST still show the split
  changes (restored_clean=true means the diff is ONLY the split, no leftover mutation).

Report structured results. This stage is diagnostic: report honestly even if some functions are
toothless — do NOT fabricate teeth.`
}

function reviewPrompt(item, plan) {
  return `You are an adversarial code reviewer for a behavior-preserving function split of the
\`${item.util}\` utility (vibeutils, Zig 0.16). Files: ${item.files.join(', ')}. The change extracted
helpers so these functions drop to <=70 lines:

${fnList(item)}

Review the diff with \`git diff ${item.files.join(' ')}\`. A faithful extract-method split changes
STRUCTURE ONLY — never behavior. Hunt for any place the split altered behavior:
- Dropped, reordered, or duplicated statements vs the original.
- Changed control flow: an early return/break/continue that no longer short-circuits the parent;
  an error no longer propagated; a defer that now runs in the wrong scope.
- Variable capture bugs: a local read after extraction that now sees a stale/uninitialized value;
  a mutable passed by value instead of pointer; aliasing changes.
- Changed types, integer widths, or division semantics.
- Off-by-one in a relocated loop bound; a loop that lost its bound.
- I/O or error-handling pattern changes (writerStreaming, io param, flush placement).

Also check Tiger Style compliance: every function (parent + helpers) <=70 lines; helpers have >=2
asserts; snake_case + caller-prefixed single-use helper names; no recursion introduced; <=100 cols;
no bare \`usize\` params except std-forced (annotated). Use \`bash scripts/tiger-check.sh ${item.files[0]}\`
and \`bash scripts/tiger-check.sh --base HEAD\` (expect new=0) to spot-check.

You may run the scoped tests (\`${scopedCmd(item)}\`) to confirm green but do NOT edit any file.
Mark approved=true ONLY if there are zero blocker issues. List every issue with severity and exact
location.`
}

// One item through all four stages. Used by both the parallel and serial
// drivers. The serial driver awaits these one at a time so common/ files
// (compiled by every util) never build against a half-edited sibling.
async function processItem(item) {
  // Stage 1: plan
  const plan = await agent(planPrompt(item), { label: `plan:${item.util}`, phase: 'Plan', schema: PLAN_SCHEMA }).catch(() => null)
  if (!plan) return null

  // Stage 2: implement + self-verify, loop up to 3 rounds
  let feedback = ''
  let impl = null
  for (let round = 0; round < 3; round++) {
    impl = await agent(implementPrompt(item, plan, feedback), {
      label: `impl:${item.util}${round ? `#${round + 1}` : ''}`,
      phase: 'Implement',
      schema: IMPL_SCHEMA,
    })
    if (!impl) return null
    const ok = impl.scoped_tests_pass && impl.new_violations === 0 && impl.targets_cleared && impl.fmt_clean
    if (ok) break
    feedback = `scoped_tests_pass=${impl.scoped_tests_pass} new_violations=${impl.new_violations} ` +
      `targets_cleared=${impl.targets_cleared} fmt_clean=${impl.fmt_clean}. ${impl.summary}`
    log(`impl:${item.util} round ${round + 1} not green — retrying`)
  }

  // Stage 3: prove teeth (diagnostic, non-blocking)
  const teeth = await agent(teethPrompt(item, plan), {
    label: `teeth:${item.util}`,
    phase: 'Prove teeth',
    schema: TEETH_SCHEMA,
  }).catch(() => null)

  // Stage 4: adversarial review + fix loop up to 3 rounds
  let review = null
  for (let round = 0; round < 3; round++) {
    review = await agent(reviewPrompt(item, plan), {
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
    const fix = await agent(implementPrompt(item, plan, fb), {
      label: `fix:${item.util}#${round + 1}`,
      phase: 'Implement',
      schema: IMPL_SCHEMA,
    })
    if (!fix) break
  }

  const blockers = review ? (review.issues || []).filter((i) => i.severity === 'blocker') : [{ severity: 'blocker', problem: 'review agent failed' }]
  return {
    util: item.util,
    files: item.files,
    functions: item.functions.map((f) => f.name),
    helpers_added: impl ? impl.helpers_added : [],
    impl_status: impl ? { tests: impl.scoped_tests_pass, new_violations: impl.new_violations, cleared: impl.targets_cleared, fmt: impl.fmt_clean } : null,
    teeth: teeth ? { confirmed: teeth.per_function.filter((f) => f.teeth_confirmed).map((f) => f.name), toothless: teeth.per_function.filter((f) => !f.teeth_confirmed).map((f) => f.name), restored_clean: teeth.restored_clean, green_after_restore: teeth.scoped_tests_green_after_restore } : null,
    review: review ? { approved: review.approved, blockers: blockers.length, issues: review.issues } : null,
    clean: !!(impl && impl.scoped_tests_pass && impl.new_violations === 0 && impl.targets_cleared && impl.fmt_clean && review && review.approved && blockers.length === 0),
  }
}

phase('Plan')
log(`phase3-fn-split: ${items.length} utilities, ${items.reduce((n, i) => n + i.functions.length, 0)} functions to split${serialMode ? ' (serial)' : ''}`)

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
log(`phase3-fn-split done: ${clean.length}/${items.length} utilities clean`)
return final
