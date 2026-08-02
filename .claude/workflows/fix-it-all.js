export const meta = {
  name: 'fix-it-all',
  description:
    'Sweep every vibeutils utility: five Opus lenses and five Codex lenses over its tests, then the same over its implementation, a consensus round, a Fable judge on deadlock, and a red-green fix. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Auditing and fixing a wave of utilities end to end. Dispatch phase:"audit" with a wave number, record the findings in FIX.md and commit, then phase:"red" with the audit result, commit the tests, then phase:"green" with the same audit result, commit the fixes.',
  phases: [
    { title: 'Audit tests', detail: '5 opus lenses + 5 codex lenses over the unit and integration tests' },
    { title: 'Audit code', detail: '5 opus lenses + 5 codex lenses over the implementation, seeded with the test gaps' },
    { title: 'Consensus', detail: 'merge, cross-check the one-sided findings, Fable judge on deadlock' },
    { title: 'Red', detail: 'test-writer fixes test defects and writes failing tests; RED proven on both platforms' },
    { title: 'Green', detail: 'implementer fixes the code; scoped loop gate, tiger, review, codex diff review, full final gate' },
  ],
};

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
const phaseArg = a.phase || 'audit';

// ---------------------------------------------------------------------------
// Bounds. Every loop in this script terminates on one of these.
// ---------------------------------------------------------------------------
const TESTFIX_ROUNDS_MAX = 3;
const GATE_FIX_MAX = 4;
const REVIEW_ROUND_MAX = 6;
const CODEX_ROUNDS_MAX = 2;
const ROUTE_HOPS_MAX = 3;

const WT_ROOT = a.wt_root || '/Users/tcole/code';
const CODEX_TMP = '/tmp/fix-it-all';

const COMMON = {
  linux_prefix: 'orb -m ubuntu',
  test_cmd: 'zig build test',
  privileged_test_cmd: 'just test-privileged',
  fmt_cmd: 'zig build fmt-check',
  full_it_cmd: 'bash tests/integration.sh',
  tiger_cmd: 'bash scripts/tiger-check.sh',
};

// ---------------------------------------------------------------------------
// Utility registry
//
// Everything follows src/<u>.zig + tests/utilities/<u>_test.sh +
// docs/specs/<u>-flags.md, so only the two exceptions are spelled out: ls is a
// directory, and `test`/`[` are one source with two binaries and two
// integration files.
// ---------------------------------------------------------------------------
function unit(name, over) {
  const o = over || {};
  return {
    util: name,
    test_util: o.test_util || name,
    src: o.src || [`src/${name}.zig`],
    it_files: o.it_files || [`tests/utilities/${name}_test.sh`],
    it_targets: o.it_targets || [name],
    spec: o.spec || [`docs/specs/${name}-flags.md`],
  };
}

const OVERRIDES = {
  ls: {
    src: [
      'src/ls/main.zig',
      'src/ls/formatter.zig',
      'src/ls/sorter.zig',
      'src/ls/entry_collector.zig',
      'src/ls/display.zig',
      'src/ls/types.zig',
      'src/ls/core.zig',
      'src/ls/recursive.zig',
    ],
    it_files: ['tests/utilities/ls_test.sh'],
  },
  test: {
    it_files: ['tests/utilities/test_test.sh', 'tests/utilities/[_test.sh'],
    it_targets: ['test', '['],
  },
  echo: {
    // echo_test_complex.sh does not match the runner's *_test.sh glob and has
    // therefore never executed. The T3 lens is expected to find this; listing
    // it here makes sure the finders actually read it.
    it_files: ['tests/utilities/echo_test.sh', 'tests/utilities/echo_test_complex.sh'],
  },
};

// Waves are ordered by implementation-size-to-test-coverage gap, not by size
// alone. Wave 0 is a cheap calibration run. Giants get smaller waves because
// wall-clock scales with source size, not with utility count.
const WAVES = [
  ['whoami', 'true', 'false'],
  ['df', 'du', 'free'],
  ['dd', 'sort', 'seq'],
  ['id', 'nl', 'tr'],
  ['cut', 'date', 'timeout'],
  ['uniq', 'tac', 'env'],
  ['realpath', 'readlink', 'mktemp'],
  ['find'],
  ['stat', 'printf'],
  ['cp', 'mv'],
  ['grep', 'ls'],
  ['chmod', 'chown'],
  ['rm', 'rmdir', 'mkdir'],
  ['ln', 'touch', 'test'],
  ['tail', 'head', 'wc'],
  ['cat', 'tee', 'sleep'],
  ['echo', 'yes', 'basename', 'dirname', 'pwd'],
];

function cfgFor(name) {
  const u = unit(name, OVERRIDES[name]);
  const workdir = `${WT_ROOT}/vibeutils-fix-${name}`;
  const at = (p) => `${workdir}/${p}`;
  const inWt = (cmd) => `cd ${workdir} && ${cmd}`;
  const itScoped = u.it_targets.map((t) => inWt(`bash tests/integration.sh ${t}`)).join(' ; ');
  return {
    ...u,
    workdir,
    src_abs: u.src.map(at),
    it_abs: u.it_files.map(at),
    spec_abs: u.spec.map(at),
    util_test_cmd: inWt(`zig build test -Dtest-util=${u.test_util}`),
    it_cmd: itScoped,
    test_cmd: inWt(COMMON.test_cmd),
    privileged_test_cmd: inWt(COMMON.privileged_test_cmd),
    fmt_cmd: inWt(COMMON.fmt_cmd),
    full_it_cmd: inWt(COMMON.full_it_cmd),
    tiger_cmd: inWt(COMMON.tiger_cmd),
    linux_test_cmd: inWt(`${COMMON.linux_prefix} zig build test`),
    linux_build_cmd: inWt(`${COMMON.linux_prefix} zig build`),
    linux_it_cmd: u.it_targets
      .map((t) => inWt(`${COMMON.linux_prefix} bash tests/integration.sh ${t}`))
      .join(' ; '),
  };
}

// ---------------------------------------------------------------------------
// Shared preambles. Byte-identical across every agent in a utility's chain so
// the wave shares prompt-cache prefixes instead of paying for a fresh preamble
// on each dispatch.
// ---------------------------------------------------------------------------
function wtPreamble(c) {
  return [
    `WORKING DIRECTORY: ${c.workdir}`,
    `That path is a dedicated git worktree for \`${c.util}\`, NOT the main checkout. Other agents are`,
    'working concurrently in sibling worktrees; staying inside yours is what keeps them isolated.',
    '',
    'READ THIS TWICE — it is the single easiest way to ruin this run:',
    'This harness RESETS the shell working directory to the repo root after EVERY Bash call. A bare',
    '`cd` does NOT carry over to your next command. So EVERY shell command you run must be',
    `self-contained and start with \`cd ${c.workdir} && \`. orb preserves that cwd inside the VM,`,
    'so the same prefix covers the Linux commands.',
    'For Read/Edit/Write, always use ABSOLUTE paths beginning with the working directory above.',
    'Never read, edit, build, or run anything under /Users/tcole/code/vibeutils itself.',
    '',
    `Utility: ${c.util}`,
    `Implementation: ${c.src.join(', ')}`,
    `Integration tests: ${c.it_files.join(', ')}`,
    `Unit tests: embedded \`test "..."\` blocks inside ${c.src.join(', ')}`,
    `Flag matrix: ${c.spec.join(', ')}`,
  ].join('\n');
}

// The house rules an auditor has to know before it can tell a real defect from
// a house convention. Distilled inline so no agent spends a turn re-reading
// CLAUDE.md or docs/TESTING_STRATEGY.md (see the fleet-efficiency rules).
const HOUSE_RULES = [
  'PROJECT FACTS you must not re-derive:',
  '- GNU coreutils is the primary behavioral reference. Where a flag exists in GNU, GNU wins. For',
  '  macOS/OpenBSD-only flags, follow that spec. `stat` follows the GNU interface, not BSD.',
  '- The flag matrix (docs/specs/<u>-flags.md) is authoritative for WHICH flags are in scope:',
  '  MUST = required, SHOULD = implement when practical, WONT = declined on purpose (not a bug),',
  '  KEEP = a vibeutils addition with no upstream spec. Do NOT report a WONT flag as missing.',
  '- Zig 0.16: every blocking API takes `io`; std.fs moved to std.Io; std.mem.indexOf* is now find*;',
  '  args/env are not global (std.process.Init); stdout/stderr must use `writerStreaming`, never',
  '  `writer` (positional mode silently breaks `>>`); buffered writers must be flushed.',
  '- Exit codes: 0 success, 1 general error, 2 misuse. Argument errors are 2.',
  '- I/O buffers are 8192 bytes by convention, not 4096.',
  '- Unit tests are embedded in the implementation file. Privileged tests are named',
  '  "privileged: ..." and MUST use privilege_test.TestArena, never testing.allocator (fakeroot).',
  '- Integration tests are sourced by tests/lib/test_runner.sh, which requires the file to be named',
  '  tests/utilities/<u>_test.sh and to define test_<u> (test_bracket for `[`). PATH is pinned to',
  '  zig-out/bin. The ONLY sanctioned timeout is `run_with_limit SECONDS CMD...` — GNU timeout(1)',
  '  does not exist on the macOS runners. isatty-dependent behavior needs `run_with_stderr_tty`.',
  '- Filter utilities that read stdin (cat, tee, sort, uniq, tr, cut, nl, tac, head, tail, wc) HANG',
  '  in a unit test that calls runUtil(); they need the runUtilWithInput() pattern.',
  '- Root bypasses DAC, so permission-denied assertions need a root guard.',
  '- Security posture: the OS enforces security. Path-traversal checks, protected-path lists, and',
  '  similar validation are deliberately absent. Do NOT report their absence as a defect.',
  '- Tiger Style: 2+ assertions per function, no recursion, bounded loops, 70-line functions,',
  '  100-column lines. scripts/tiger-check.sh gates this at zero violations, so a Tiger violation',
  '  is already caught by CI and is NOT worth reporting here.',
].join('\n');

const REPORTING_RULES = [
  'REPORTING RULES:',
  '- Report only things that are WRONG or MISSING. No style preferences, no naming opinions, no',
  '  speculative refactors, no "consider adding".',
  '- Every finding needs a `location` as file:line that you actually read, and `evidence` quoting or',
  '  describing the specific code or behavior. A finding without a line you can point at is noise.',
  '- Classify `kind` honestly:',
  '    bug          = the implementation behaves incorrectly.',
  '    test_defect  = an existing test is wrong, toothless, dead, or duplicated.',
  '    missing_test = behavior that is implemented but untested.',
  '    refactor     = duplication or a missed reuse opportunity; behavior-preserving by definition.',
  '- Classify `scope`: `local` if the fix touches only this utility\'s own files; `cross_cutting` if',
  '  it would change src/common/* or another utility. Cross-cutting fixes are deferred to a serial',
  '  wave, so mislabeling one as local will make three worktrees collide.',
  '- Severity: CRITICAL = wrong output/exit code/crash/data loss. IMPORTANT = a real defect with a',
  '  narrower blast radius. SUGGESTION = everything else.',
  '- If you find nothing, return an empty list. An empty list is a legitimate answer and is far more',
  '  useful than a padded one. Do not invent findings to look thorough.',
  '- Do NOT edit any file. This is a read-only pass.',
].join('\n');

// ---------------------------------------------------------------------------
// Lenses. Five distinct angles per target — five identical prompts would
// return four redundant answers.
// ---------------------------------------------------------------------------
const TEST_LENSES = [
  {
    id: 'T1',
    name: 'toothless',
    focus: [
      'Find tests that CANNOT FAIL, or that pass for the wrong reason. Concretely:',
      '- An expected value derived the same way the utility derives it (asserting `whoami` equals',
      '  $USER proves nothing; both read the same source).',
      '- test_command_output_pattern with a pattern loose enough to match any plausible output.',
      '- A missing `|| return 1` after test_binary_exists, so the rest of the function runs against a',
      '  binary that does not exist.',
      '- Assertions on a variable that is empty or unset when the assertion runs.',
      '- A test whose command always succeeds regardless of the behavior under test.',
      '- Unit tests that assert on the PARSED FLAG rather than on the behavior — `parsed.follow ==',
      '  true` is not a test of following.',
      'For each candidate, state the concrete mutation to the implementation that SHOULD break the',
      'test but would not. That mutation is your evidence.',
    ].join('\n'),
  },
  {
    id: 'T2',
    name: 'wrong-expectation',
    focus: [
      'Find tests whose EXPECTED VALUE is wrong — they pin current behavior rather than the',
      'reference behavior. These are the worst class of defect here: they actively defend a bug.',
      'Compare each assertion against what GNU coreutils actually does. You have a Linux VM: run',
      '`orb -m ubuntu <the real GNU utility> <args>` to pin the reference output, exit code, and',
      'error text rather than reasoning from memory. Check the exit code and the stderr text, not',
      'just stdout — error-message wording and operand quoting are in scope and have been the source',
      'of real bugs here.',
      'Also flag assertions that are over-constrained: pinning an incidental detail (a timestamp, a',
      'device number, an inode, a locale-dependent string) that will flake rather than catch a bug.',
    ].join('\n'),
  },
  {
    id: 'T3',
    name: 'duplication-and-dead',
    focus: [
      'Find test code that does not earn its place:',
      '- Near-identical cases that exercise exactly the same code path with different literals.',
      '- Tests that never execute. The runner only picks up tests/utilities/<u>_test.sh and calls',
      '  test_<u>; a helper file with any other name is dead. A test function defined but never',
      '  called from test_<u> is dead. A Zig test in a file that is never force-imported is dormant',
      '  (this repo has shipped 272 dormant tests before — see src/common/force_import_lint.zig).',
      '- Setup or fixtures built and never used.',
      '- Unit tests and integration tests asserting the identical thing, where one is redundant.',
      'Prove deadness: show the glob, the call site that is missing, or the import that is absent.',
    ].join('\n'),
  },
  {
    id: 'T4',
    name: 'missing-edge-cases',
    focus: [
      'Find behavior that is implemented but UNTESTED. Work from the flag matrix: for every MUST and',
      'SHOULD flag marked `yes` in the `Ours` column, find the test that proves it changes behavior.',
      'A flag with no behavioral test is a finding.',
      'Then the input edge cases this codebase has actually been bitten by:',
      '- no operands at all; `-` as an operand; `--` end-of-options; an empty string operand.',
      '- empty input, input with no trailing newline, input with CRLF, binary/NUL bytes, invalid',
      '  UTF-8, a line longer than the 8192-byte buffer (this raises error.StreamTooLong, not',
      '  EndOfStream, and has crashed a utility here).',
      '- 0, 1, and enormous numeric arguments; negative where the flag accepts a sign.',
      '- symlinks, symlink loops, dangling symlinks, a symlink whose target is a directory.',
      '- unreadable files, unwritable directories, a nonexistent path mid-operand-list (partial',
      '  failure must still emit the good output AND exit 1).',
      '- output to a pipe vs to a terminal, where the utility changes behavior on isatty.',
      '- TZ, LANG/LC_ALL, NO_COLOR, and TERM where the utility reads them.',
    ].join('\n'),
  },
  {
    id: 'T5',
    name: 'harness-hazards',
    focus: [
      'Find tests that are broken as TEST CODE, independent of the behavior they assert:',
      '- A unit test calling runUtil() on a utility that reads stdin — it hangs the suite forever.',
      '- `timeout N cmd` instead of run_with_limit (GNU timeout does not exist on the macOS runner).',
      '- An isatty-dependent assertion not routed through run_with_stderr_tty.',
      '- A permission-denied assertion with no root guard: `[[ $(id -u) -eq 0 ]]` skip, or the Zig',
      '  `if (std.c.geteuid() == 0) return error.SkipZigTest;`.',
      '- A privileged test using testing.allocator instead of privilege_test.TestArena (fakeroot',
      '  incompatibility — this hangs).',
      '- Unquoted shell expansions that break on paths with spaces; `local x=$(...)` swallowing the',
      '  exit status; missing cleanup that leaks temp state into the next test.',
      '- A 4096-byte buffer where the convention is 8192.',
      '- Anything that mutates the environment via libc setenv/unsetenv inside a test — Zig 0.16',
      '  captured `environ` at init, and corrupting it has deadlocked the panic handler and hung the',
      '  whole suite (issue #95).',
      '- A test that depends on wall-clock timing or on another test having run first.',
    ].join('\n'),
  },
];

const CODE_LENSES = [
  {
    id: 'C1',
    name: 'gnu-parity',
    focus: [
      'Compare this implementation against GNU coreutils behavior, flag by flag. You have a Linux VM',
      'with the real GNU utilities: run `orb -m ubuntu <util> <args>` to pin actual behavior instead',
      'of reasoning from memory, and compare byte-for-byte with our output.',
      'In scope: flag semantics and their interactions; the default behavior with no flags; exit',
      'codes (0/1/2, argument errors are 2); stdout formatting down to separators, padding, and',
      'trailing newlines; stderr wording, the `util: ` prefix, and operand quoting; the order in',
      'which operands are processed and errors reported; what happens when flags conflict (GNU',
      'usually resolves last-wins rather than erroring).',
      'Do NOT report a flag the matrix marks WONT as missing.',
    ].join('\n'),
  },
  {
    id: 'C2',
    name: 'stubs',
    focus: [
      'Find flags that are PARSED BUT NEVER PLUMBED — accepted on the command line, stored in the',
      'options struct, and then never consulted where they would change behavior. This is the single',
      'highest-yield defect class in this codebase: `ls -C` was parsed and ignored for months, and',
      '`ls` never consulted the `is_terminal` value it had already computed.',
      'Method, do not skip it: for EVERY field of the parsed-options struct, grep for every read of',
      'that field in the implementation. A field that is written by the parser and read nowhere is a',
      'stub. A field read only inside help text, only in a test, or only to be copied into another',
      'struct that is itself never read, is also a stub.',
      'Then the weaker form: a flag consulted on one code path but not on the parallel path that',
      'handles the other case (single operand vs many, file vs directory, terminal vs pipe).',
      'Report the field name, its parse site, and the absence of a real read site.',
    ].join('\n'),
  },
  {
    id: 'C3',
    name: 'memory-and-resources',
    focus: [
      'Find resource defects:',
      '- Allocations not freed on a path the arena does not cover; frees on memory the arena owns.',
      '- Use-after-free, especially pointers into memory owned by something that is reset or freed.',
      '- Pointers returned by libc into STATIC buffers — getpwuid, getgrgid, getpwnam, strerror,',
      '  localtime — used after any other libc call could have reused the buffer. This has caused a',
      '  real bug here; the rule is copy the string out immediately.',
      '- File descriptors, directory handles, and mapped memory not closed on the error path.',
      '- Buffered writers not flushed before the buffer goes out of scope (data loss), or flushed',
      '  after the underlying file is closed.',
      '- Unbounded loops: a `while (true)` with no counter, a retry loop with no cap (an uncapped',
      '  getgrouplist retry once hung CI for 29 minutes), a read loop that does not terminate on a',
      '  short read.',
      '- Integer overflow or truncation in size, offset, and count arithmetic, and casts that can',
      '  trap in a safe build.',
    ].join('\n'),
  },
  {
    id: 'C4',
    name: 'platform',
    focus: [
      'Find behavior that is wrong on one platform. Verify on the Linux VM (`orb -m ubuntu`) rather',
      'than assuming; you are running on macOS.',
      '- Signed stat fields: macOS st_dev on devfs is a signed i32 with the high bit set, so',
      '  @intCast to u64 traps. It must be @bitCast. Check every cast of a libc struct field.',
      '- isatty gating: color, columns, progress, and every interactive prompt need their OWN isatty',
      '  check, not one check on the first path. ColorMode.detect() only reads env vars — without an',
      '  isatty check ANSI codes leak into pipes and test buffers.',
      '- errno values that differ between platforms, and errno classified as unexpected when it is an',
      '  ordinary case (std.posix.unexpectedErrno dumps a stack trace in safe builds).',
      '- struct stat layout and timespec field differences, and File.Stat.atime being optional.',
      '- Timezone handling: std.time.epoch has no tz database, so a naive conversion prints UTC.',
      '- Regex, locale, and libc feature differences (macOS libc rejects GNU regex escapes).',
      '- Zig 0.16 API correctness on paths the compiler may not reach: every blocking call takes io.',
    ].join('\n'),
  },
  {
    id: 'C5',
    name: 'duplication-and-reuse',
    focus: [
      'Find code that should not exist because it already exists in src/common/. Read the module list',
      'first (`ls src/common/`), then look for hand-rolled versions of:',
      '- directory traversal that should use common/walker.zig (bounded, cycle-aware; hand-rolled',
      '  walks here have shipped symlink-loop and sibling-alias data-loss bugs).',
      '- argument parsing that should use common/argparse.zig; help/version output that should use',
      '  common/help.zig; mode/permission parsing that should use common/mode.zig; path manipulation',
      '  that should use common/path.zig; copy/permission primitives in common/file_ops.zig;',
      '  error printing that should use common.printErrorWithProgram.',
      '- the same non-trivial logic copy-pasted between two utilities (compare against the sibling',
      '  utility that shares the behavior — cp/mv, rm/rmdir, head/tail, chmod/chown).',
      '- dead code: functions, branches, and struct fields with no reachable caller.',
      'Every finding here is behavior-preserving by definition, so `kind` is `refactor`. If replacing',
      'the local copy would CHANGE behavior, that is a `bug` finding instead — say which behavior',
      'moves. Judge honestly whether the duplication is worth removing: a little copying is better',
      'than a little dependency, and this project does not refactor for its own sake.',
    ].join('\n'),
  },
];

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const FINDING_PROPS = {
  id: { type: 'string', description: 'Lens id + number, e.g. T1-1 or C2-3.' },
  severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
  kind: { type: 'string', enum: ['bug', 'test_defect', 'missing_test', 'refactor'] },
  scope: { type: 'string', enum: ['local', 'cross_cutting'] },
  location: { type: 'string', description: 'file:line you actually read' },
  claim: { type: 'string' },
  evidence: { type: 'string' },
  fix: { type: 'string', description: 'The concrete change, or the behavior the missing test must assert.' },
};

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'severity', 'kind', 'scope', 'location', 'claim', 'evidence', 'fix'],
        properties: FINDING_PROPS,
      },
    },
    notes: { type: 'string' },
  },
};

const CODEX_FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['invoked_ok', 'findings'],
  properties: {
    invoked_ok: { type: 'boolean', description: 'true only if `codex exec` actually ran and produced output' },
    raw_excerpt: { type: 'string', description: 'Last ~40 lines of Codex output, or the error if it failed.' },
    findings: FINDINGS_SCHEMA.properties.findings,
  },
};

const MERGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['agreed', 'opus_only', 'codex_only'],
  properties: {
    agreed: { type: 'array', items: FINDINGS_SCHEMA.properties.findings.items },
    opus_only: { type: 'array', items: FINDINGS_SCHEMA.properties.findings.items },
    codex_only: { type: 'array', items: FINDINGS_SCHEMA.properties.findings.items },
    duplicates_collapsed: { type: 'integer' },
    notes: { type: 'string' },
  },
};

const CROSSCHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    invoked_ok: { type: 'boolean' },
    raw_excerpt: { type: 'string' },
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'verdict', 'reason'],
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['CONFIRM', 'REJECT', 'DISPUTE'] },
          reason: { type: 'string', description: 'Grounded in code you read, citing file:line.' },
        },
      },
    },
  },
};

const JUDGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'verdict', 'directive', 'rationale'],
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['UPHOLD', 'REJECT', 'DEFER_CROSS_CUTTING'] },
          directive: { type: 'string', description: 'The concrete change to make, or "none".' },
          rationale: { type: 'string', description: 'Must cite file:line you actually read.' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

const TESTWRITE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['tests_written', 'tests_fixed', 'summary'],
  properties: {
    tests_written: { type: 'integer' },
    tests_fixed: { type: 'integer' },
    expected_failing: {
      type: 'array',
      description: 'Tests deliberately left failing because the CODE is wrong. These are the RED tests.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['finding_id', 'test_name', 'asserts'],
        properties: {
          finding_id: { type: 'string' },
          test_name: { type: 'string' },
          asserts: { type: 'string' },
        },
      },
    },
    refused: {
      type: 'array',
      description: 'Findings this agent judged wrong and declined to act on, with the reason.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['finding_id', 'reason'],
        properties: { finding_id: { type: 'string' }, reason: { type: 'string' } },
      },
    },
    summary: { type: 'string' },
  },
};

const REDCHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['all_red_for_right_reason', 'per_test', 'macos_checked', 'linux_checked'],
  properties: {
    all_red_for_right_reason: { type: 'boolean' },
    macos_checked: { type: 'boolean' },
    linux_checked: { type: 'boolean' },
    per_test: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['test_name', 'red', 'right_reason', 'observed'],
        properties: {
          test_name: { type: 'string' },
          red: { type: 'boolean' },
          right_reason: {
            type: 'boolean',
            description: 'Failed on the assertion matching the bug — not a compile error, not a skip.',
          },
          observed: { type: 'string' },
        },
      },
    },
    green_tests_still_pass: { type: 'boolean' },
    notes: { type: 'string' },
  },
};

const SABOTAGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['all_have_teeth', 'per_test', 'restored_clean'],
  properties: {
    all_have_teeth: { type: 'boolean' },
    restored_clean: { type: 'boolean', description: 'git diff shows no leftover mutation.' },
    per_test: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['test_name', 'mutation', 'went_red'],
        properties: {
          test_name: { type: 'string' },
          mutation: { type: 'string' },
          went_red: { type: 'boolean' },
        },
      },
    },
    notes: { type: 'string' },
  },
};

const IMPLEMENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['outcome', 'changed_files', 'summary'],
  properties: {
    outcome: { type: 'string', enum: ['done', 'needs_test_change'] },
    changed_files: { type: 'array', items: { type: 'string' } },
    fixed: { type: 'array', items: { type: 'string' }, description: 'finding ids fixed' },
    test_change_requests: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'note'],
        properties: { id: { type: 'string' }, note: { type: 'string' } },
      },
    },
    summary: { type: 'string' },
  },
};

const GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean'],
  properties: {
    unit_pass: { type: 'boolean' },
    integration_pass: { type: 'boolean' },
    lint_clean: { type: 'boolean' },
    first_failure: { type: 'string' },
    notes: { type: 'string' },
  },
};

const TIGER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clean', 'new_violations'],
  properties: {
    clean: { type: 'boolean' },
    new_violations: { type: 'integer' },
    detail: { type: 'string' },
  },
};

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['assessment', 'issues'],
  properties: {
    assessment: { type: 'string', enum: ['APPROVED', 'CHANGES_REQUIRED'] },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'location', 'claim'],
        properties: {
          severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
          location: { type: 'string' },
          claim: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

const RESOLUTION_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['resolutions', 'summary'],
  properties: {
    resolutions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'action', 'note'],
        properties: {
          id: { type: 'string' },
          action: { type: 'string', enum: ['fixed', 'disputed', 'test_change'] },
          note: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

const REBUTTAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    invoked_ok: { type: 'boolean' },
    raw_excerpt: { type: 'string' },
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'stance', 'reason'],
        properties: {
          id: { type: 'string' },
          stance: { type: 'string', enum: ['WITHDRAWN', 'REAFFIRMED'] },
          reason: { type: 'string' },
        },
      },
    },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: [
    'macos_unit_pass',
    'macos_privileged_pass',
    'macos_full_it_pass',
    'linux_unit_pass',
    'linux_it_pass',
  ],
  properties: {
    macos_unit_pass: { type: 'boolean' },
    macos_privileged_pass: { type: 'boolean' },
    macos_full_it_pass: { type: 'boolean' },
    linux_unit_pass: { type: 'boolean' },
    linux_it_pass: { type: 'boolean' },
    first_failure: { type: 'string' },
    notes: { type: 'string' },
  },
};

// ---------------------------------------------------------------------------
// Codex layer. Codex is not a subagent type: a sonnet RUNNER agent writes the
// prompt to a file and shells out to `codex exec`. The runner is a courier,
// never a substitute reviewer — a silently-Claude "Codex" opinion would void
// the whole two-family premise of this sweep.
// ---------------------------------------------------------------------------
function codexInstructions(promptFile) {
  return [
    'Invoke Codex as an INDEPENDENT auditor. Run exactly:',
    `  mkdir -p ${CODEX_TMP} && codex exec < ${promptFile}`,
    'codex exec reads its instructions from stdin when no prompt argument is given, and is',
    'non-interactive. Pipe its output through `tail -160` so a long transcript does not flood you.',
    'If that invocation errors, run `codex exec --help` ONCE, adapt the flags minimally, and retry ONCE.',
    'If it still fails, set invoked_ok=false, put the error in raw_excerpt, and return an empty list —',
    "do NOT substitute your own analysis for Codex's. You are a runner, not the auditor. A fabricated",
    'Codex opinion destroys the only thing this stage is for: a second, independent model family.',
    'Codex is asked for JSON but may wrap it in prose; extract the JSON array from its output. If it',
    'returns prose only, translate its stated findings faithfully into the schema without adding any',
    'of your own. Put the last ~40 lines of its output in raw_excerpt either way.',
  ].join('\n');
}

function codexAuditPrompt(c, target, lens, seed) {
  const files = target === 'tests' ? c.it_files.concat(c.src) : c.src;
  return [
    `You are auditing the vibeutils repository (a Zig 0.16 implementation of GNU coreutils).`,
    `Utility: \`${c.util}\`. Target: the ${target === 'tests' ? 'TESTS' : 'IMPLEMENTATION'}.`,
    `Read these files yourself: ${files.join(', ')}.`,
    target === 'tests'
      ? `The unit tests are the \`test "..."\` blocks embedded in ${c.src.join(', ')}; the integration tests are ${c.it_files.join(', ')}.`
      : `Its tests are ${c.it_files.join(', ')} plus the \`test "..."\` blocks in the source.`,
    `The authoritative flag matrix is ${c.spec.join(', ')}.`,
    '',
    HOUSE_RULES,
    '',
    `## YOUR LENS — ${lens.id} (${lens.name}). Stay on it; other agents cover the rest.`,
    lens.focus,
    seed ? `\n## CONTEXT FROM THE TEST AUDIT\n${seed}` : '',
    '',
    REPORTING_RULES,
    '',
    'Output ONLY a JSON array, nothing else:',
    '[{"id":"' + lens.id + '-1","severity":"CRITICAL|IMPORTANT|SUGGESTION",',
    '  "kind":"bug|test_defect|missing_test|refactor","scope":"local|cross_cutting",',
    '  "location":"file:line","claim":"what is wrong","evidence":"the code or behavior you cite",',
    '  "fix":"the concrete change"}]',
    'Return [] if you find nothing.',
  ].join('\n');
}

async function codexAudit(c, target, lens, seed) {
  const promptFile = `${CODEX_TMP}/${c.util}-${target}-${lens.id}.md`;
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Codex audit runner)',
      `Write the audit request below to ${promptFile}, then run Codex on it from inside the worktree`,
      `(\`cd ${c.workdir} && codex exec < ${promptFile}\`) so it reads THIS worktree's code.`,
      '',
      codexInstructions(promptFile),
      '',
      `--- BEGIN audit request to write to ${promptFile} ---`,
      codexAuditPrompt(c, target, lens, seed),
      '--- END audit request ---',
    ].join('\n'),
    {
      label: `codex:${c.util}:${target}:${lens.id}`,
      phase: target === 'tests' ? 'Audit tests' : 'Audit code',
      model: 'sonnet',
      schema: CODEX_FINDINGS_SCHEMA,
    },
  ).catch(() => null);
}

// ---------------------------------------------------------------------------
// Opus finders
// ---------------------------------------------------------------------------
async function opusAudit(c, target, lens, seed) {
  const files = target === 'tests' ? c.it_abs.concat(c.src_abs) : c.src_abs;
  return await agent(
    [
      wtPreamble(c),
      '',
      `## YOUR TASK (auditor — lens ${lens.id}, ${lens.name})`,
      `Audit the ${target === 'tests' ? 'TESTS' : 'IMPLEMENTATION'} of \`${c.util}\` through ONE lens.`,
      `Read: ${files.join(', ')}.`,
      'You are one of ten auditors on this target, each with a different lens. Stay on yours — the',
      'others cover the rest, and a broad shallow pass from you is worth less than a deep narrow one.',
      'READ ONLY. Do not edit, do not commit, do not run a formatter.',
      'You MAY build and run things to check a hypothesis; prefer the scoped, quiet commands:',
      `  ${c.util_test_cmd}`,
      `  ${c.it_cmd}`,
      'and pipe verbose output through `tail`.',
      '',
      HOUSE_RULES,
      '',
      `## YOUR LENS — ${lens.id} (${lens.name})`,
      lens.focus,
      seed ? `\n## CONTEXT FROM THE TEST AUDIT\n${seed}` : '',
      '',
      REPORTING_RULES,
    ].join('\n'),
    {
      label: `opus:${c.util}:${target}:${lens.id}`,
      phase: target === 'tests' ? 'Audit tests' : 'Audit code',
      model: 'opus',
      schema: FINDINGS_SCHEMA,
    },
  ).catch(() => null);
}

// ---------------------------------------------------------------------------
// Consensus
// ---------------------------------------------------------------------------
function renderFindings(list) {
  if (!list || list.length === 0) return '(none)';
  return list
    .map(
      (f) =>
        `### ${f.id} [${f.severity}/${f.kind}/${f.scope}] ${f.location}\n` +
        `claim: ${f.claim}\nevidence: ${f.evidence}\nfix: ${f.fix}`,
    )
    .join('\n\n');
}

async function mergeFindings(c, target, opusFindings, codexFindings) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (consensus — merge two independent audits)',
      `Two model families audited the ${target} of \`${c.util}\` through the same five lenses,`,
      'independently. Merge their findings into three buckets. READ ONLY.',
      '',
      'Two findings are THE SAME finding when they describe the same defect, even if they cite',
      'different line numbers, use different words, or came from different lenses. Judge by the',
      'defect, not by the text. Open the cited code when you are unsure — you may read files and run',
      'the scoped checks; you may not edit.',
      '',
      '  agreed     — both families found this defect. Merge into one entry, keeping the clearer',
      '               claim and the stronger evidence, and the HIGHER severity of the two.',
      '  opus_only  — only the first family found it.',
      '  codex_only — only the second family found it.',
      '',
      'Also collapse duplicates WITHIN a family (five lenses overlap at the edges) and report how',
      'many you collapsed. Preserve every id you merged in the claim text so nothing becomes',
      'untraceable, e.g. "(T1-2, T4-5)".',
      'Do not add findings of your own. Do not drop a finding because you disagree with it — that is',
      'the cross-check stage\'s job, not yours.',
      '',
      `## FAMILY A (opus) — ${(opusFindings || []).length} findings`,
      renderFindings(opusFindings),
      '',
      `## FAMILY B (codex) — ${(codexFindings || []).length} findings`,
      renderFindings(codexFindings),
    ].join('\n'),
    {
      label: `merge:${c.util}:${target}`,
      phase: 'Consensus',
      model: 'opus',
      schema: MERGE_SCHEMA,
    },
  ).catch(() => null);
}

async function opusCrossCheck(c, target, list) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (cross-check — adjudicate the other family\'s findings)',
      `An independent auditor (Codex, a different model family) reported these defects in the`,
      `${target} of \`${c.util}\`. Your family did NOT find them. That asymmetry is information, but`,
      'it cuts both ways: it can mean the finding is wrong, or that your family missed it.',
      '',
      'For each, go read the actual code at the cited location and decide:',
      '  CONFIRM — the defect is real. It joins the agreed set and will be fixed.',
      '  REJECT  — the defect is not real. Say concretely why, citing the code that refutes it.',
      '            Rejecting because it is inconvenient, or because a WONT-tier flag is involved',
      '            when it is not, is worse than confirming a marginal finding.',
      '  DISPUTE — you cannot settle it. It goes to a judge.',
      'READ ONLY. You may run the scoped checks to settle a factual question; you may not edit.',
      '',
      HOUSE_RULES,
      '',
      '## FINDINGS TO ADJUDICATE',
      renderFindings(list),
    ].join('\n'),
    {
      label: `crosscheck-opus:${c.util}:${target}`,
      phase: 'Consensus',
      model: 'opus',
      schema: CROSSCHECK_SCHEMA,
    },
  ).catch(() => null);
}

async function codexCrossCheck(c, target, list) {
  const promptFile = `${CODEX_TMP}/${c.util}-${target}-crosscheck.md`;
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Codex cross-check runner)',
      `Write the request below to ${promptFile}, then run Codex on it from inside the worktree.`,
      '',
      codexInstructions(promptFile),
      '',
      `--- BEGIN request to write to ${promptFile} ---`,
      `Continuing your audit of the vibeutils utility \`${c.util}\` (${target}).`,
      'Another auditor (a different model family) reported the defects below. You did not find them.',
      'That asymmetry can mean the finding is wrong, or that you missed it — it is not evidence',
      'either way on its own.',
      '',
      'For each, read the actual code at the cited location and decide:',
      '  CONFIRM — the defect is real.',
      '  REJECT  — it is not real. Say concretely why, citing the code that refutes it.',
      '  DISPUTE — you cannot settle it; it goes to a judge.',
      'Do not edit anything.',
      '',
      HOUSE_RULES,
      '',
      '## FINDINGS TO ADJUDICATE',
      renderFindings(list),
      '',
      'Output ONLY a JSON array, nothing else:',
      '[{"id":"T1-1","verdict":"CONFIRM|REJECT|DISPUTE","reason":"grounded in the code you read"}]',
      '--- END request ---',
    ].join('\n'),
    {
      label: `crosscheck-codex:${c.util}:${target}`,
      phase: 'Consensus',
      model: 'sonnet',
      schema: CROSSCHECK_SCHEMA,
    },
  ).catch(() => null);
}

async function judge(c, target, disputed) {
  const items = disputed
    .map(
      (d) =>
        `### ${d.id} [${d.severity}/${d.kind}] ${d.location}\n` +
        `CLAIMED: ${d.claim}\nEVIDENCE: ${d.evidence}\nPROPOSED FIX: ${d.fix}\n` +
        `THE OTHER FAMILY SAYS: ${d.counter || '(did not find it and could not settle it)'}`,
    )
    .join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (judge — break a deadlock)',
      `Two independent auditors disagree about the ${target} of \`${c.util}\` and neither will move.`,
      'You decide, and your decision is final.',
      '',
      'You must NOT arbitrate between the two written positions. Both may be wrong. Go read the',
      'actual code: open the cited files and read enough of the surrounding code to judge for',
      'yourself. You may run the scoped checks to settle a factual question',
      `(\`${c.util_test_cmd}\`, \`${c.it_cmd}\`) and you may run the real GNU utility on the Linux VM`,
      `(\`${COMMON.linux_prefix} ${c.util} ...\`) to pin reference behavior. You may NOT edit any file.`,
      '',
      HOUSE_RULES,
      '',
      'For each disputed finding return one verdict:',
      '  UPHOLD — the defect is real. `directive` states the concrete change to make.',
      '  REJECT — the defect is not real. `directive` is "none".',
      '  DEFER_CROSS_CUTTING — the defect is real but the fix would change src/common/* or another',
      '    utility, so it cannot be fixed inside this utility\'s worktree. `directive` states the',
      '    change for the later serial wave.',
      'Every rationale must cite specific code you actually read (file:line). A rationale that only',
      "restates one side's argument is not acceptable.",
      '',
      '## DEADLOCKED FINDINGS',
      items,
    ].join('\n'),
    {
      label: `judge:${c.util}:${target}`,
      phase: 'Consensus',
      model: 'fable',
      schema: JUDGE_SCHEMA,
    },
  ).catch(() => null);
}

// A finding that touches shared code cannot be fixed inside a per-utility
// worktree without three of them colliding on the same file. Decide this in
// code rather than trusting the model's own `scope` label alone.
function isCrossCutting(c, f) {
  if (!f) return false;
  if (f.scope === 'cross_cutting') return true;
  const loc = String(f.location || '');
  if (loc.startsWith('src/common/')) return true;
  if (loc.includes('/src/common/')) return true;
  const own = c.src.concat(c.it_files);
  const inOwn = own.some((p) => loc.includes(p));
  return loc.startsWith('src/') && !inOwn;
}

// ---------------------------------------------------------------------------
// One audit target (tests, then code). Ten finders, merge, cross-check, judge.
// ---------------------------------------------------------------------------
async function auditTarget(c, target, lenses, seed) {
  const thunks = [];
  for (const lens of lenses) thunks.push(() => opusAudit(c, target, lens, seed));
  for (const lens of lenses) thunks.push(() => codexAudit(c, target, lens, seed));
  const results = await parallel(thunks);

  const opusRuns = results.slice(0, lenses.length).filter(Boolean);
  const codexRuns = results.slice(lenses.length).filter(Boolean);
  const codexOk = codexRuns.filter((r) => r.invoked_ok);
  if (codexOk.length === 0) {
    log(`${c.util}/${target}: NO codex lens ran — the two-family premise is void for this target.`);
  } else if (codexOk.length < lenses.length) {
    log(`${c.util}/${target}: only ${codexOk.length}/${lenses.length} codex lenses ran.`);
  }

  const opusFindings = opusRuns.flatMap((r) => r.findings || []);
  const codexFindings = codexOk.flatMap((r) => r.findings || []);
  log(`${c.util}/${target}: opus ${opusFindings.length}, codex ${codexFindings.length} raw findings.`);

  if (opusFindings.length === 0 && codexFindings.length === 0) {
    return { target, agreed: [], dropped: [], judged: [], deferred: [], codex_lenses_ok: codexOk.length };
  }

  const merged = await mergeFindings(c, target, opusFindings, codexFindings);
  if (!merged) {
    return {
      target,
      agreed: opusFindings.concat(codexFindings),
      dropped: [],
      judged: [],
      deferred: [],
      codex_lenses_ok: codexOk.length,
      merge_failed: true,
    };
  }

  const agreed = merged.agreed || [];
  const opusOnly = merged.opus_only || [];
  const codexOnly = merged.codex_only || [];
  log(
    `${c.util}/${target}: ${agreed.length} agreed, ${opusOnly.length} opus-only, ` +
      `${codexOnly.length} codex-only (collapsed ${merged.duplicates_collapsed || 0} duplicates).`,
  );

  // Each family adjudicates the findings the OTHER family raised alone.
  const checks = await parallel([
    () => (codexOnly.length > 0 ? opusCrossCheck(c, target, codexOnly) : Promise.resolve(null)),
    () => (opusOnly.length > 0 && codexOk.length > 0 ? codexCrossCheck(c, target, opusOnly) : Promise.resolve(null)),
  ]);

  const verdictOf = (res, id) => {
    const v = res && (res.verdicts || []).find((x) => x.id === id);
    return v || null;
  };

  const confirmed = [];
  const dropped = [];
  const disputed = [];
  const sort = (list, res, sideLabel) => {
    for (const f of list) {
      const v = verdictOf(res, f.id);
      if (!v) {
        // No verdict came back for this finding. Not settled, so do not silently
        // keep it and do not silently drop it — send it to the judge.
        disputed.push({ ...f, counter: `${sideLabel} returned no verdict for this finding.` });
      } else if (v.verdict === 'CONFIRM') {
        confirmed.push({ ...f, confirmed_by: sideLabel, confirm_reason: v.reason });
      } else if (v.verdict === 'REJECT') {
        dropped.push({ ...f, dropped_by: sideLabel, drop_reason: v.reason });
      } else {
        disputed.push({ ...f, counter: v.reason });
      }
    }
  };
  sort(codexOnly, checks[0], 'opus cross-check');
  if (opusOnly.length > 0 && codexOk.length > 0) {
    sort(opusOnly, checks[1], 'codex cross-check');
  } else {
    // Codex never ran, so nothing can cross-check the opus-only set. Judge it
    // rather than accepting it unexamined.
    for (const f of opusOnly) disputed.push({ ...f, counter: 'codex was unavailable to cross-check.' });
  }

  let judged = [];
  if (disputed.length > 0) {
    const ruling = await judge(c, target, disputed);
    judged = (ruling && ruling.verdicts) || [];
    log(`${c.util}/${target}: judge ruled on ${judged.length}/${disputed.length} disputed findings.`);
    for (const f of disputed) {
      const v = judged.find((x) => x.id === f.id);
      if (!v) {
        dropped.push({ ...f, dropped_by: 'judge', drop_reason: 'no verdict returned' });
      } else if (v.verdict === 'UPHOLD') {
        confirmed.push({ ...f, fix: v.directive || f.fix, judged: true, judge_rationale: v.rationale });
      } else if (v.verdict === 'DEFER_CROSS_CUTTING') {
        confirmed.push({ ...f, scope: 'cross_cutting', fix: v.directive || f.fix, judged: true });
      } else {
        dropped.push({ ...f, dropped_by: 'judge', drop_reason: v.rationale });
      }
    }
  }

  const all = agreed.concat(confirmed);
  const deferred = all.filter((f) => isCrossCutting(c, f));
  const actionable = all.filter((f) => !isCrossCutting(c, f));
  log(
    `${c.util}/${target}: ${actionable.length} actionable, ${deferred.length} deferred cross-cutting, ` +
      `${dropped.length} dropped.`,
  );

  return {
    target,
    agreed: actionable,
    deferred,
    dropped,
    judged,
    codex_lenses_ok: codexOk.length,
    merge_notes: merged.notes || '',
  };
}

// ---------------------------------------------------------------------------
// Phase: audit
// ---------------------------------------------------------------------------
function seedFromTests(testResult) {
  const gaps = (testResult.agreed || []).filter((f) => f.kind === 'missing_test' || f.kind === 'test_defect');
  if (gaps.length === 0) return '';
  return [
    'The test audit found these gaps. Behavior that is untested is where bugs survive, so weight',
    'these code paths first — but audit through YOUR lens, not through the test audit\'s.',
    gaps.map((f) => `- [${f.kind}] ${f.location}: ${f.claim}`).join('\n'),
  ].join('\n');
}

async function auditUtility(c) {
  const tests = await auditTarget(c, 'tests', TEST_LENSES, '');
  const code = await auditTarget(c, 'code', CODE_LENSES, seedFromTests(tests));
  return { util: c.util, workdir: c.workdir, tests, code };
}

// ---------------------------------------------------------------------------
// Phase: red — the test-writer owns every test edit. The implementer never
// touches a test; that separation is what keeps the verification honest.
// ---------------------------------------------------------------------------
function findingsByKind(audit, kinds) {
  const out = [];
  for (const t of [audit.tests, audit.code]) {
    for (const f of (t && t.agreed) || []) if (kinds.includes(f.kind)) out.push(f);
  }
  return out;
}

async function writeTests(c, audit, extra) {
  const testDefects = findingsByKind(audit, ['test_defect']);
  const missing = findingsByKind(audit, ['missing_test']);
  const bugs = findingsByKind(audit, ['bug']);
  const refactors = findingsByKind(audit, ['refactor']);
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (test-writer — you own every test in this worktree)',
      `A ten-pass audit of \`${c.util}\` agreed on the findings below. Act on the test-side ones.`,
      `Files you may edit: ${c.it_abs.concat(c.src_abs).join(', ')} — but in the source files you may`,
      'edit ONLY the `test "..."` blocks, never the implementation. Another agent owns that.',
      'Do NOT commit. Do NOT run a tree-wide formatter (`zig build fmt`); use `zig build fmt-check`.',
      'Do NOT touch TODO.md, CHANGELOG.md, or any file not listed above.',
      '',
      'Three jobs, in order:',
      '',
      '1. FIX THE BROKEN TESTS. For each test_defect finding, repair the test so it would fail if the',
      '   behavior regressed. A test that is merely deleted is not fixed unless the finding says the',
      '   test is genuinely dead. Keep every test TOOTHFUL.',
      '',
      '2. ADD THE MISSING TESTS. For each missing_test finding, write a test that asserts the',
      '   BEHAVIOR, not the parse. Some of these will PASS (the behavior is right, it was just',
      '   untested) — good, that is coverage. Some will FAIL, because the behavior is actually wrong.',
      '   Leave those FAILING and list them in expected_failing. Do NOT weaken a test to make it pass.',
      '',
      '3. WRITE THE RED TESTS. For each `bug` finding, write a test that fails NOW and will pass once',
      '   the bug is fixed. Assert the reference (GNU) behavior. You have a Linux VM: pin the real',
      `   behavior with \`${COMMON.linux_prefix} ${c.util} ...\` rather than reasoning from memory.`,
      '   List each in expected_failing with exactly what it asserts.',
      '',
      refactors.length > 0
        ? [
            'REFACTOR findings are behavior-preserving, so they get CHARACTERIZATION tests instead:',
            'tests that pass against the code as it stands today and will still pass after the',
            'refactor. Write those too, and do NOT list them in expected_failing.',
          ].join('\n')
        : '',
      '',
      'If you judge a finding to be WRONG, do not act on it — record it in `refused` with your',
      'reasoning. You are the last check on the audit; a bad finding acted on becomes a bad test.',
      '',
      'Check your work with the scoped commands only (pipe through `tail`):',
      `  ${c.util_test_cmd}`,
      `  ${c.it_cmd}`,
      `  ${c.fmt_cmd}`,
      'Everything must compile and `fmt-check` must be clean. Failures are expected ONLY from the',
      'tests you listed in expected_failing.',
      '',
      HOUSE_RULES,
      '',
      `## TEST DEFECTS TO FIX (${testDefects.length})`,
      renderFindings(testDefects),
      '',
      `## MISSING TESTS TO ADD (${missing.length})`,
      renderFindings(missing),
      '',
      `## BUGS NEEDING A RED TEST (${bugs.length})`,
      renderFindings(bugs),
      '',
      `## REFACTORS NEEDING CHARACTERIZATION TESTS (${refactors.length})`,
      renderFindings(refactors),
      extra ? `\n## FEEDBACK FROM THE PREVIOUS ROUND\n${extra}` : '',
    ].join('\n'),
    {
      label: `test-writer:${c.util}${extra ? ':refix' : ''}`,
      phase: 'Red',
      model: 'opus',
      agentType: 'tdd-pipeline:test-writer',
      schema: TESTWRITE_SCHEMA,
    },
  );
}

async function redCheck(c, expectedFailing) {
  const items = (expectedFailing || [])
    .map((t) => `- ${t.test_name} (finding ${t.finding_id}) asserts: ${t.asserts}`)
    .join('\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (red check — run and report, do not fix)',
      'The test-writer says these tests should be FAILING right now because the implementation is',
      'wrong. Prove it, and prove they fail for the RIGHT REASON.',
      '',
      'A test that fails because it does not compile, because it was skipped, because a fixture is',
      'missing, or because of an unrelated error is NOT red for the right reason — that is a broken',
      'test masquerading as a caught bug, and it is the single most common way this pipeline gets',
      'fooled. For each test, report the actual failure text you observed.',
      '',
      'Run on BOTH platforms — a bug that reproduces on only one is still a bug, but we need to know',
      'which:',
      `  macOS unit:        ${c.util_test_cmd}`,
      `  macOS integration: ${c.it_cmd}`,
      `  Linux build:       ${c.linux_build_cmd}`,
      `  Linux unit:        ${c.linux_test_cmd}`,
      `  Linux integration: ${c.linux_it_cmd}`,
      'Pipe verbose output through `tail`. Also confirm that the tests NOT in this list still pass —',
      'the test-writer may have broken something while editing.',
      'Report facts only. Do not edit any file.',
      '',
      '## TESTS EXPECTED TO BE RED',
      items || '(none — report all_red_for_right_reason=true and check that the suites are green)',
    ].join('\n'),
    {
      label: `red-check:${c.util}`,
      phase: 'Red',
      model: 'sonnet',
      schema: REDCHECK_SCHEMA,
    },
  );
}

async function proveTeeth(c, refactors) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (prove the characterization tests have teeth)',
      'Characterization tests for a behavior-preserving refactor pass against the unchanged code, so',
      'they cannot be proven by a red run. Prove them by SABOTAGE instead: a test that stays green',
      'when you break the thing it guards is worthless.',
      '',
      'For each characterization test:',
      '  1. Temporarily mutate the implementation to break the behavior it asserts.',
      `  2. Run just that test (use \`-Dtest-filter\` or the scoped ${c.util_test_cmd}) and confirm RED.`,
      '  3. REVERT the mutation immediately. Never leave one in place, never commit one.',
      'At the end, run `git diff` and confirm the implementation is byte-identical to how you found',
      'it, then confirm the suite is green again. Report restored_clean honestly — a leftover',
      'mutation would be committed as if it were the fix.',
      '',
      '## CHARACTERIZATION TESTS TO PROVE',
      renderFindings(refactors),
    ].join('\n'),
    {
      label: `sabotage:${c.util}`,
      phase: 'Red',
      model: 'sonnet',
      schema: SABOTAGE_SCHEMA,
    },
  );
}

async function redPhase(c, audit) {
  let written = await writeTests(c, audit, '');
  if (!written) return { util: c.util, ready_to_commit_red: false, reason: 'test-writer failed' };

  let check = await redCheck(c, written.expected_failing);
  for (let round = 1; round < TESTFIX_ROUNDS_MAX && check; round += 1) {
    const bad = (check.per_test || []).filter((t) => !t.red || !t.right_reason);
    const brokeGreen = check.green_tests_still_pass === false;
    if (bad.length === 0 && !brokeGreen) break;
    const feedback = [
      brokeGreen ? 'You broke tests that were passing before. Restore them.' : '',
      bad.length > 0
        ? [
            'These tests are not red for the right reason. Fix the TEST (not the implementation) so it',
            'fails on the assertion that matches the bug:',
            bad.map((t) => `- ${t.test_name}: red=${t.red} right_reason=${t.right_reason} — ${t.observed}`).join('\n'),
          ].join('\n')
        : '',
    ]
      .filter(Boolean)
      .join('\n\n');
    log(`${c.util}: red round ${round} — ${bad.length} test(s) not red for the right reason.`);
    written = await writeTests(c, audit, feedback);
    if (!written) break;
    check = await redCheck(c, written.expected_failing);
  }

  const refactors = findingsByKind(audit, ['refactor']);
  let teeth = null;
  if (refactors.length > 0) {
    teeth = await proveTeeth(c, refactors);
  }

  const ready =
    !!written &&
    !!check &&
    check.all_red_for_right_reason &&
    check.macos_checked &&
    check.linux_checked &&
    check.green_tests_still_pass !== false &&
    (!teeth || (teeth.all_have_teeth && teeth.restored_clean));

  return {
    util: c.util,
    workdir: c.workdir,
    tests_written: written ? written.tests_written : 0,
    tests_fixed: written ? written.tests_fixed : 0,
    expected_failing: written ? written.expected_failing || [] : [],
    refused: written ? written.refused || [] : [],
    red_check: check,
    sabotage: teeth,
    ready_to_commit_red: ready,
  };
}

// ---------------------------------------------------------------------------
// Phase: green — the implementer owns the implementation and may never edit a
// test. When a test genuinely needs to change, it routes to the test-writer,
// which judges first and may refuse. Without that, an implementer could dodge a
// real bug by rewriting the test that caught it.
// ---------------------------------------------------------------------------
async function dispatchImplementer(c, body, label) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (implementer — you own the implementation, never the tests)',
      `Implementation files you may edit: ${c.src_abs.join(', ')} (NOT the \`test "..."\` blocks).`,
      `Test files you may NOT edit under any circumstances: ${c.it_abs.join(', ')}, and every`,
      '`test "..."` block in the source.',
      'Make the MINIMAL change that fixes each finding. Do not refactor surrounding code, do not add',
      'error handling the fix does not need, do not design for hypothetical requirements.',
      'Do NOT weaken, delete, or narrow any test. Do NOT commit. Do NOT run a tree-wide formatter.',
      '',
      'If a finding can only be resolved by changing a TEST, do not do it — return',
      'outcome="needs_test_change" with a precise description of what the test should assert',
      'instead. It routes to the test-writer, which decides whether the test is genuinely wrong.',
      '',
      'Check your work with the scoped, quiet commands ONLY (pipe through `tail`):',
      `  ${c.util_test_cmd}`,
      `  ${c.it_cmd}`,
      `  ${c.fmt_cmd}`,
      'Do not run the full unit, privileged, or full integration suites — a separate gate runs those',
      'and reports distilled results.',
      '',
      HOUSE_RULES,
      '',
      body,
    ].join('\n'),
    {
      label,
      phase: 'Green',
      model: 'opus',
      agentType: 'tdd-pipeline:implementer',
      schema: IMPLEMENT_SCHEMA,
    },
  );
}

async function routeTestChange(c, audit, requests) {
  const body = requests.map((t) => `### ${t.id}\nRequested: ${t.note}`).join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (test-writer — adjudicate requested test changes)',
      'The implementer says these test changes are needed. You own the tests; it does not.',
      'Judge FIRST, edit second.',
      '',
      `Test files you own: ${c.it_abs.join(', ')} and the \`test "..."\` blocks in ${c.src_abs.join(', ')}.`,
      'Implementation code you may NOT touch: everything else in those source files.',
      '',
      'For each request: if the test is genuinely wrong — it asserts the buggy behavior, or asserts',
      'something the reference behavior does not require — fix it, but keep it TOOTHFUL: it must',
      'still fail if the bug returns. If the test is correct and the IMPLEMENTATION is what needs to',
      'change, REFUSE and say so plainly; the implementer will fix the code instead.',
      'The refusal is the point of this stage. An implementer that can rewrite the test that caught',
      'it can make any bug disappear.',
      '',
      'Do NOT commit.',
      '',
      '## REQUESTS',
      body,
    ].join('\n'),
    {
      label: `test-change:${c.util}`,
      phase: 'Green',
      model: 'opus',
      agentType: 'tdd-pipeline:test-writer',
      schema: RESOLUTION_SCHEMA,
    },
  );
}

async function runImplementer(c, audit, body, label) {
  let res = await dispatchImplementer(c, body, label);
  for (let hop = 0; hop < ROUTE_HOPS_MAX; hop += 1) {
    if (!res || res.outcome !== 'needs_test_change') break;
    const reqs = res.test_change_requests || [];
    if (reqs.length === 0) break;
    const tw = await routeTestChange(c, audit, reqs);
    log(`${c.util}: routed ${reqs.length} test-change request(s): ${(tw && tw.summary) || 'no reply'}`);
    const refused = ((tw && tw.resolutions) || []).filter((r) => r.action === 'disputed');
    const feedback = [
      body,
      '',
      '## THE TEST-WRITER HAS RULED ON YOUR REQUESTS',
      ((tw && tw.resolutions) || []).map((r) => `- ${r.id}: ${r.action} — ${r.note}`).join('\n'),
      refused.length > 0
        ? 'Where it REFUSED, the test is correct and the implementation is what must change. Fix the code.'
        : '',
    ].join('\n');
    res = await dispatchImplementer(c, feedback, `${label}:after-test-change`);
  }
  return { result: res, tests_changed: !!res && res.outcome === 'needs_test_change' };
}

async function gate(c, why) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (verify gate — run and report only)',
      `${why}. Run EXACTLY these, in order, and stop reporting detail after the first failure:`,
      `  scoped unit:        ${c.util_test_cmd}`,
      `  scoped integration: ${c.it_cmd}`,
      `  lint:               ${c.fmt_cmd}`,
      'Pipe verbose output through `tail`. Report facts only; do not edit anything, do not fix',
      'anything. If something fails, put the first real failure (the assertion and its message, not',
      'the summary line) in first_failure.',
    ].join('\n'),
    { label: `gate:${c.util}`, phase: 'Green', model: 'haiku', schema: GATE_SCHEMA },
  );
}

async function tigerCheck(c) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Tiger Style gate — run and report only)',
      `Run \`${c.tiger_cmd}\`. It prints TAB-separated \`<rule>\\t<file>:<line>\\t<status>\\t<detail>\``,
      'lines and a final `SUMMARY total=<N> new=<N>`.',
      'The repo baseline is ZERO violations and CI fails on any, so report clean=true only when the',
      'scan is genuinely clean. Report new_violations as the count attributable to the changes in',
      'this worktree (`git diff main...HEAD` shows them). Do not edit anything.',
    ].join('\n'),
    { label: `tiger:${c.util}`, phase: 'Green', model: 'haiku', schema: TIGER_SCHEMA },
  );
}

async function codeReview(c, round) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (code review — read only)',
      `Review the fixes made to \`${c.util}\` in this worktree. Run \`git diff main...HEAD\` and`,
      '`git diff`, and read the surrounding code.',
      '',
      'Do NOT run the test, privileged, or integration suites, and do not build. A separate gate has',
      'already proven the suites green; re-running them here wastes time and tells you nothing new.',
      'Review by reading.',
      '',
      'Review for, in priority order:',
      '  1. Does each change actually fix the finding it claims to, including the edge cases the',
      '     tests do not cover?',
      '  2. Was any test weakened, deleted, or made tautological to reach green?',
      '  3. Does the change break an adjacent code path that shares the modified function?',
      '  4. Zig 0.16 correctness: `io` on every blocking call, std.Io not std.fs, buffered writers',
      '     flushed, `writerStreaming` not `writer` for stdout/stderr.',
      '  5. Memory: allocations freed, arena vs testing.allocator, no pointer into a static libc',
      '     buffer held across another libc call.',
      '  6. Is the change minimal? Refactoring beyond the fix is a finding here, not a virtue.',
      '',
      'Do NOT report style preferences, naming opinions, or speculative refactors. Report only what',
      'is wrong or would break. Return APPROVED when there is nothing left that is wrong.',
      '',
      HOUSE_RULES,
    ].join('\n'),
    {
      label: `review:${c.util}#${round}`,
      phase: 'Green',
      model: 'opus',
      agentType: 'tdd-pipeline:code-reviewer',
      schema: REVIEW_SCHEMA,
    },
  );
}

async function codexDiffReview(c) {
  const promptFile = `${CODEX_TMP}/${c.util}-diff-review.md`;
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Codex diff-review runner)',
      `Write the review request below to ${promptFile}, then run Codex on it from inside the worktree.`,
      '',
      codexInstructions(promptFile),
      '',
      `--- BEGIN review request to write to ${promptFile} ---`,
      `You are reviewing bug fixes to \`${c.util}\` in the vibeutils repository (a Zig 0.16`,
      'implementation of GNU coreutils).',
      '',
      'Inspect the change yourself: run `git diff main...HEAD` and `git diff` and read the',
      'surrounding code. Do not rely on any summary.',
      '',
      HOUSE_RULES,
      '',
      'Review for, in priority order:',
      '  1. Correctness against GNU behavior, including edge cases the tests may not cover.',
      '  2. Whether any test was weakened, deleted, or made tautological to reach green.',
      '  3. Breakage on adjacent code paths that share a changed function.',
      '  4. Zig 0.16 correctness and memory handling.',
      '  5. Whether the change is minimal, or drags in unrelated refactoring.',
      '',
      'Do NOT report style preferences, naming opinions, or speculative refactors. Report only what',
      'is wrong or would break.',
      '',
      'Output ONLY a JSON array, nothing else:',
      '[{"id":"X1","severity":"CRITICAL|IMPORTANT|SUGGESTION","kind":"bug","scope":"local",',
      '  "location":"file:line","claim":"what is wrong","evidence":"the code you cite","fix":"..."}]',
      'Return [] if the change is clean.',
      '--- END review request ---',
    ].join('\n'),
    {
      label: `codex-review:${c.util}`,
      phase: 'Green',
      model: 'sonnet',
      schema: CODEX_FINDINGS_SCHEMA,
    },
  );
}

async function codexRebuttal(c, disputed) {
  const promptFile = `${CODEX_TMP}/${c.util}-rebuttal.md`;
  const items = disputed
    .map(
      (d) =>
        `### Finding ${d.id} (${d.severity}) at ${d.location}\n` +
        `Your claim: ${d.claim}\nYour evidence: ${d.evidence}\n` +
        `The implementer DISPUTES this and replies: ${d.dispute}`,
    )
    .join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Codex rebuttal runner)',
      `Write the request below to ${promptFile}, then run Codex on it from inside the worktree.`,
      '',
      codexInstructions(promptFile),
      '',
      `--- BEGIN request to write to ${promptFile} ---`,
      `Continuing your review of vibeutils \`${c.util}\`.`,
      'The code has changed since your review. Re-read it: run `git diff main...HEAD` and `git diff`.',
      '',
      'For each finding below, the implementer disagreed with you. Consider their reasoning against',
      'the ACTUAL current code, then decide. Withdraw if they are right or if the code no longer has',
      'the problem. Reaffirm only if you have checked the current code and the problem is genuinely',
      'still there. Being talked out of a correct finding is as bad as holding a wrong one.',
      '',
      items,
      '',
      'Output ONLY a JSON array, nothing else:',
      '[{"id":"X1","stance":"WITHDRAWN|REAFFIRMED","reason":"grounded in the code you just read"}]',
      '--- END request ---',
    ].join('\n'),
    { label: `codex-rebuttal:${c.util}`, phase: 'Green', model: 'sonnet', schema: REBUTTAL_SCHEMA },
  );
}

async function finalVerify(c) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (final gate — the authoritative run; report only)',
      'Run EXACTLY these and report each result. This is the gate the commit depends on, so run all',
      'of them even if an early one fails:',
      `  macOS full unit:         ${c.test_cmd}`,
      `  macOS full privileged:   ${c.privileged_test_cmd}`,
      `  macOS FULL integration:  ${c.full_it_cmd}`,
      `  Linux build:             ${c.linux_build_cmd}`,
      `  Linux full unit:         ${c.linux_test_cmd}`,
      `  Linux scoped integration:${c.linux_it_cmd}`,
      '',
      'The FULL integration suite is deliberate: a scoped run cannot catch the cross-utility',
      'regressions that shared-code changes cause.',
      'Pipe verbose output through `tail`. A hung suite is a failure, not a pass — if a command does',
      'not finish, report it as failed and say which one.',
      'Report facts only. Do not edit anything.',
    ].join('\n'),
    { label: `final:${c.util}`, phase: 'Green', model: 'haiku', schema: FINAL_SCHEMA },
  );
}

function renderForImplementer(audit) {
  const bugs = findingsByKind(audit, ['bug']);
  const refactors = findingsByKind(audit, ['refactor']);
  return [
    `## BUGS TO FIX (${bugs.length}) — each has a failing test waiting for it`,
    renderFindings(bugs),
    '',
    `## REFACTORS TO APPLY (${refactors.length}) — behavior-preserving; characterization tests must stay green`,
    renderFindings(refactors),
    '',
    'The tests are already written and committed. Make them pass by changing the implementation.',
    'A refactor that changes any observable behavior is a failure, not a fix.',
  ].join('\n');
}

async function greenPhase(c, audit) {
  const body = renderForImplementer(audit);
  let impl = await runImplementer(c, audit, body, `implement:${c.util}`);
  let testsChanged = impl.tests_changed;

  let g = await gate(c, 'The implementer has applied the fixes');
  for (let round = 1; round < GATE_FIX_MAX && g; round += 1) {
    if (g.unit_pass && g.integration_pass && g.lint_clean) break;
    log(`${c.util}: gate round ${round} failed — ${g.first_failure || 'see notes'}`);
    const fix = await runImplementer(
      c,
      audit,
      [
        body,
        '',
        '## THE VERIFY GATE FAILED',
        `unit_pass=${g.unit_pass} integration_pass=${g.integration_pass} lint_clean=${g.lint_clean}`,
        `First failure: ${g.first_failure || '(not reported)'}`,
        g.notes || '',
        'Fix the implementation. Do not weaken the test.',
      ].join('\n'),
      `implement:${c.util}:gate${round}`,
    );
    testsChanged = testsChanged || fix.tests_changed;
    g = await gate(c, `Re-verifying after gate fix round ${round}`);
  }

  const tiger = await tigerCheck(c);

  let review = await codeReview(c, 1);
  for (let round = 2; round <= REVIEW_ROUND_MAX && review; round += 1) {
    if (review.assessment === 'APPROVED') break;
    const blocking = (review.issues || []).filter((i) => i.severity !== 'SUGGESTION');
    if (blocking.length === 0) break;
    log(`${c.util}: review round ${round - 1} — ${blocking.length} blocking issue(s).`);
    const fix = await runImplementer(
      c,
      audit,
      [
        body,
        '',
        '## CODE REVIEW REQUIRES CHANGES',
        blocking.map((i) => `- [${i.severity}] ${i.location}: ${i.claim}`).join('\n'),
      ].join('\n'),
      `implement:${c.util}:review${round - 1}`,
    );
    testsChanged = testsChanged || fix.tests_changed;
    g = await gate(c, `Re-verifying after review round ${round - 1}`);
    review = await codeReview(c, round);
  }

  // Independent Codex review of the finished diff, with bounded rebuttal.
  const cx = await codexDiffReview(c);
  let codexOk = !!(cx && cx.invoked_ok);
  let deadlocks = [];
  let open = codexOk ? (cx.findings || []).filter((f) => f.severity !== 'SUGGESTION') : [];
  if (!codexOk) log(`${c.util}: codex diff review did not run — surfacing, not silently skipping.`);

  for (let round = 1; round <= CODEX_ROUNDS_MAX && open.length > 0; round += 1) {
    const resp = await runImplementer(
      c,
      audit,
      [
        body,
        '',
        '## AN INDEPENDENT REVIEWER (Codex) FOUND THESE',
        'Treat it as a competent peer who cannot see your reasoning: often right, sometimes',
        'confidently wrong. For each, either fix the implementation, or dispute it concretely citing',
        'the code. Do not dispute merely because a change is inconvenient.',
        renderFindings(open),
      ].join('\n'),
      `implement:${c.util}:codex${round}`,
    );
    testsChanged = testsChanged || resp.tests_changed;
    const fixedIds = new Set(((resp.result && resp.result.fixed) || []).map(String));
    const disputed = open
      .filter((f) => !fixedIds.has(String(f.id)))
      .map((f) => ({ ...f, dispute: (resp.result && resp.result.summary) || 'see implementation' }));
    if (disputed.length === 0) {
      open = [];
      break;
    }
    if (round === CODEX_ROUNDS_MAX) {
      deadlocks = disputed;
      break;
    }
    const reb = await codexRebuttal(c, disputed);
    const stance = new Map((((reb && reb.verdicts) || [])).map((v) => [String(v.id), v]));
    const stillLive = disputed.filter((d) => {
      const s = stance.get(String(d.id));
      return s && s.stance === 'REAFFIRMED';
    });
    log(`${c.util}: codex round ${round} — ${disputed.length - stillLive.length} withdrawn, ${stillLive.length} reaffirmed.`);
    open = stillLive;
    deadlocks = stillLive;
  }

  let verdicts = [];
  if (deadlocks.length > 0) {
    const ruling = await judge(c, 'the fix diff', deadlocks.map((d) => ({ ...d, counter: d.dispute })));
    verdicts = (ruling && ruling.verdicts) || [];
    const upheld = verdicts.filter((v) => v.verdict === 'UPHOLD');
    if (upheld.length > 0) {
      const binding = upheld.map((v) => {
        const src = deadlocks.find((d) => String(d.id) === String(v.id)) || {};
        return {
          ...src,
          claim: `THE JUDGE RULED THIS VALID. Its decision is final and you may not dispute it. Apply: ${v.directive}`,
          evidence: v.rationale,
        };
      });
      const fix = await runImplementer(
        c,
        audit,
        [body, '', '## BINDING JUDGE RULINGS', renderFindings(binding)].join('\n'),
        `implement:${c.util}:judged`,
      );
      testsChanged = testsChanged || fix.tests_changed;
      g = await gate(c, 'Re-verifying after applying binding judge rulings');
    }
  }

  const final = await finalVerify(c);
  const finalPass =
    !!final &&
    final.macos_unit_pass &&
    final.macos_privileged_pass &&
    final.macos_full_it_pass &&
    final.linux_unit_pass &&
    final.linux_it_pass;

  const ready =
    !!g &&
    g.unit_pass &&
    g.integration_pass &&
    g.lint_clean &&
    !!tiger &&
    tiger.clean &&
    !!review &&
    review.assessment === 'APPROVED' &&
    finalPass;

  return {
    util: c.util,
    workdir: c.workdir,
    changed_files: (impl.result && impl.result.changed_files) || [],
    gate: g,
    tiger,
    review,
    codex_ok: codexOk,
    codex_findings: (cx && cx.findings) || [],
    deadlocks,
    judge_verdicts: verdicts,
    final,
    tests_changed_during_green: testsChanged,
    ready_to_commit_green: ready,
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
function resolveUnits() {
  if (Array.isArray(a.utils) && a.utils.length > 0) return a.utils.map(String);
  const w = Number(a.wave);
  if (!Number.isInteger(w) || w < 0 || w >= WAVES.length) {
    throw new Error(`fix-it-all: args.wave must be 0..${WAVES.length - 1}, or pass args.utils`);
  }
  return WAVES[w];
}

const names = resolveUnits();
const cfgs = names.map(cfgFor);
log(`fix-it-all: phase=${phaseArg} wave=${a.wave === undefined ? '(explicit)' : a.wave} utils=${names.join(', ')}`);

if (phaseArg === 'audit') {
  phase('Audit tests');
  const out = (await parallel(cfgs.map((c) => () => auditUtility(c)))).filter(Boolean);
  for (const r of out) {
    const n = (r.tests.agreed || []).length + (r.code.agreed || []).length;
    const d = (r.tests.deferred || []).length + (r.code.deferred || []).length;
    log(`${r.util}: ${n} actionable finding(s), ${d} deferred.`);
  }
  return { phase: 'audit', utils: names, audits: out };
}

const audits = a.audits || [];
if (audits.length === 0) {
  throw new Error(`fix-it-all: phase=${phaseArg} needs args.audits (the object the audit phase returned)`);
}
const byUtil = new Map(audits.map((x) => [x.util, x]));

if (phaseArg === 'red') {
  phase('Red');
  const out = (
    await parallel(
      cfgs.map((c) => () => {
        const audit = byUtil.get(c.util);
        if (!audit) {
          log(`${c.util}: no audit in args.audits — skipping.`);
          return Promise.resolve(null);
        }
        return redPhase(c, audit);
      }),
    )
  ).filter(Boolean);
  const blocked = out.filter((r) => !r.ready_to_commit_red).map((r) => r.util);
  log(`fix-it-all red done. ready: ${out.filter((r) => r.ready_to_commit_red).map((r) => r.util).join(', ') || 'none'}${blocked.length ? `; NOT ready: ${blocked.join(', ')}` : ''}`);
  return { phase: 'red', results: out };
}

if (phaseArg === 'green') {
  phase('Green');
  const out = (
    await parallel(
      cfgs.map((c) => () => {
        const audit = byUtil.get(c.util);
        if (!audit) {
          log(`${c.util}: no audit in args.audits — skipping.`);
          return Promise.resolve(null);
        }
        return greenPhase(c, audit);
      }),
    )
  ).filter(Boolean);
  const blocked = out.filter((r) => !r.ready_to_commit_green).map((r) => r.util);
  log(`fix-it-all green done. ready: ${out.filter((r) => r.ready_to_commit_green).map((r) => r.util).join(', ') || 'none'}${blocked.length ? `; NOT ready: ${blocked.join(', ')}` : ''}`);
  return { phase: 'green', results: out };
}

throw new Error(`fix-it-all: unknown phase "${phaseArg}" (expected audit, red, or green)`);
