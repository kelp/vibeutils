export const meta = {
  name: 'phase4-assert-audit',
  description: 'Adversarial audit of Phase 4 assertions: find asserts that fire on valid-but-untested input and remove/fix them',
  phases: [
    { title: 'Audit', detail: 'for each added assert, find a valid input that fires it' },
    { title: 'Fix', detail: 'remove/correct wrong asserts; verify the firing input no longer crashes' },
  ],
}

// args: array (parallel) OR { serial:true, items:[...] }. item: { util, testUtil, files:[...] }
let parsedArgs = args
if (typeof parsedArgs === 'string') parsedArgs = JSON.parse(parsedArgs)
const serialMode = !Array.isArray(parsedArgs) && parsedArgs && parsedArgs.serial === true
const items = Array.isArray(parsedArgs) ? parsedArgs : (parsedArgs && Array.isArray(parsedArgs.items) ? parsedArgs.items : [])
if (items.length === 0) { log('phase4-assert-audit: no items'); return [] }

// HEAD is the pre-Phase-4 baseline (Phase 4 is uncommitted), so `git diff HEAD`
// shows exactly the asserts this sweep added.
const LENS = `The danger we are hunting: an assertion is WRONG if any VALID input/invocation can make its
condition false, because in Debug/Safe builds that aborts the program (exit 134) on input the code is
supposed to handle. We have already found and removed several such asserts:
- date: assert(tm_gmtoff <= 50400) — fires on \`TZ='XXX-24' date '+%:z'\` (gmtoff = 86400).
- chown: assert(!(opts.L and opts.P)) — argparse sets flags independently (last-wins), so
  \`chown -R -L -P file\` is valid and fires it. assert(has_some_source) fires on \`chown '' file\`.
  assert(path.len > 0) fires on \`chown -R root ''\`.
Common wrong-assert sources to check for EVERY added assert:
- CLI flag combinations: argparse sets each bool flag independently; ANY combination is a valid
  invocation (mutually-exclusive flags are resolved last-wins, NOT rejected). Never assert !(A and B)
  on two user flags.
- Empty strings: an empty argument / operand / option value ('') is valid input.
- Zero / max numeric values: 0 counts, 0 width, huge -n/-c values parsed from the CLI.
- Absent optionals: a value that is null/default when the user did not pass the flag.
- Environment/OS-derived values: TZ -> tm_gmtoff, LANG/locale, getpwuid name, stat fields, file
  contents, terminal size. The code must tolerate whatever the OS/env returns.
An assert is FINE if its condition is genuinely guaranteed for all valid inputs (a value the function
itself computed/clamped, a postcondition of a checked operation, a compile-time constant relationship).`

const AUDIT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['util', 'asserts_examined', 'wrong_asserts'],
  properties: {
    util: { type: 'string' },
    asserts_examined: { type: 'integer' },
    wrong_asserts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['location', 'assert_text', 'firing_input', 'fix'],
        properties: {
          location: { type: 'string', description: 'file:line' },
          assert_text: { type: 'string' },
          firing_input: { type: 'string', description: 'A concrete valid input/invocation that makes the condition false (e.g. a shell command or arg).' },
          fix: { type: 'string', description: 'remove, or correct-to <expr>' },
        },
      },
    },
    notes: { type: 'string' },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['removed_or_fixed', 'tests_pass', 'new_violations', 'fmt_clean', 'firing_inputs_no_longer_crash', 'summary'],
  properties: {
    removed_or_fixed: { type: 'integer' },
    tests_pass: { type: 'boolean' },
    new_violations: { type: 'integer' },
    fmt_clean: { type: 'boolean' },
    firing_inputs_no_longer_crash: { type: 'boolean', description: 'Built the binary and confirmed each firing input now exits cleanly (no abort).' },
    summary: { type: 'string' },
  },
}

function buildCmd(item) { return item.testUtil ? `zig build test -Dtest-util=${item.testUtil}` : `zig build test` }

function auditPrompt(item) {
  return `Adversarially audit the Phase 4 assertions added to \`${item.util}\` (files:
${item.files.join(', ')}, vibeutils Zig 0.16). READ ONLY.

Run \`git diff HEAD -- ${item.files.join(' ')}\` — HEAD is the pre-Phase-4 baseline, so every ADDED
\`std.debug.assert(...)\` line in that diff is in scope. (Removed asserts are not your concern.)

${LENS}

For EACH added assert, trace what values reach its condition (read the surrounding code and callers)
and try hard to construct a CONCRETE valid input that makes it false. If you find one, record it as a
wrong assert with the exact firing input and whether the fix is to remove it or correct its bound.
Examine every added assert; report asserts_examined (the count) and the wrong ones. Be specific and
adversarial — assume the assert is guilty until you have shown no valid input fires it. Do not edit.`
}

function fixPrompt(item, wrong) {
  const cmd = buildCmd(item)
  return `Fix WRONG Phase 4 assertions in \`${item.util}\` (files: ${item.files.join(', ')}). An audit
found these asserts that fire on valid input (they must not abort the program on inputs it should
handle):

${wrong.map((w) => `- ${w.location}: ${w.assert_text}\n    fires on: ${w.firing_input}\n    fix: ${w.fix}`).join('\n')}

Apply each fix (remove the assert, or correct its bound exactly as noted). Prefer REMOVAL when the
asserted value is user- or environment-controlled and the code already tolerates any value. Change NO
other logic. Do NOT touch tests. NEVER run git checkout/reset/stash.

Verify (all required):
1. \`${cmd}\` exits 0.
2. Build the binary (\`zig build\`) and run each firing input above; confirm each now exits cleanly
   (no exit-134 abort). Report the commands and exit codes.
3. \`zig build fmt-check\` exits 0.
4. \`bash scripts/tiger-check.sh --base HEAD\` does not increase the new count due to your edit.

Report removed_or_fixed count, the four results, and firing_inputs_no_longer_crash.`
}

async function processItem(item) {
  const audit = await agent(auditPrompt(item), { label: `audit:${item.util}`, phase: 'Audit', schema: AUDIT_SCHEMA }).catch(() => null)
  if (!audit) return null
  const wrong = audit.wrong_asserts || []
  if (wrong.length === 0) {
    return { util: item.util, files: item.files, asserts_examined: audit.asserts_examined, wrong_found: 0, fixed: 0, clean: true }
  }
  log(`audit:${item.util} found ${wrong.length} wrong assert(s) — fixing`)
  let fix = null
  for (let round = 0; round < 3; round++) {
    fix = await agent(fixPrompt(item, wrong), { label: `fix:${item.util}${round ? `#${round + 1}` : ''}`, phase: 'Fix', schema: FIX_SCHEMA })
    if (!fix) break
    if (fix.tests_pass && fix.new_violations === 0 && fix.fmt_clean && fix.firing_inputs_no_longer_crash) break
  }
  const ok = !!(fix && fix.tests_pass && fix.new_violations === 0 && fix.fmt_clean && fix.firing_inputs_no_longer_crash)
  return { util: item.util, files: item.files, asserts_examined: audit.asserts_examined, wrong_found: wrong.length, wrong_asserts: wrong, fixed: fix ? fix.removed_or_fixed : 0, clean: ok }
}

phase('Audit')
log(`phase4-assert-audit: ${items.length} items${serialMode ? ' (serial)' : ''}`)

let final = []
if (serialMode) {
  for (let i = 0; i < items.length; i++) { const r = await processItem(items[i]); if (r) final.push(r) }
} else {
  final = (await parallel(items.map((it) => () => processItem(it)))).filter(Boolean)
}

const wrongTotal = final.reduce((n, r) => n + (r.wrong_found || 0), 0)
log(`phase4-assert-audit done: ${wrongTotal} wrong asserts found across ${items.length} items; ${final.filter((r) => !r.clean).length} unresolved`)
return final
