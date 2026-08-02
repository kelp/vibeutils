export const meta = {
  name: 'fix-it-all',
  description:
    'Exhaustive per-unit audit sweep: five Opus lenses and five Codex lenses plus mechanical GNU differential testing, looped until two consecutive rounds find nothing new, every agreed finding attacked by three adversarial refuters, and a Fable judge on deadlock. Fixes go through a red-green pipeline. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Auditing and fixing a wave end to end. Dispatch phase:"audit" with a wave id (S0-S8 shared code, U0-U16 utilities), record the findings in FIX.md and commit, then phase:"red" with the audit result, commit the tests, then phase:"green", commit the fixes.',
  phases: [
    { title: 'Audit tests', detail: '5 opus + 5 codex lenses over the tests, looped until dry' },
    { title: 'Audit code', detail: '5 opus + 5 codex lenses over the implementation, seeded with the test gaps' },
    { title: 'Differential', detail: 'mechanical ours-vs-GNU comparison on the Linux VM' },
    { title: 'Consensus', detail: 'merge, cross-check, three adversarial refuters, Fable judge on deadlock' },
    { title: 'Reproduce', detail: 'independently demonstrate every survivor; duplication gets a judgement gate instead' },
    { title: 'Red', detail: 'test-writer fixes tests, writes failing tests, persists fuzz corpora' },
    { title: 'Green', detail: 'implementer fixes the code; scoped loop gate, tiger, review, codex diff review, full final gate' },
  ],
};

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
const phaseArg = a.phase || 'audit';

// ---------------------------------------------------------------------------
// Bounds. Every loop in this script terminates on one of these.
// ---------------------------------------------------------------------------
const DRY_ROUNDS_REQUIRED = 2; // consecutive rounds finding nothing new
// Hard backstop on the discovery loop. Raised from 8 after S0/argparse ran all
// eight productive rounds without ever hitting two consecutive dry ones — and
// the findings held up (the refuters killed 18 of 111, and 58 of 66 survivors
// were demonstrated), so the cap was cutting off real discovery rather than
// noise. This is a backstop against a pathological loop, not a budget.
const AUDIT_ROUNDS_MAX = 20;
const REFUTERS = 3; // adversarial skeptics per agreed set
const REFUTE_KILL_VOTES = 2; // majority of REFUTERS kills a finding
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
// Unit registry
//
// Two kinds of unit. A `utility` has a CLI, an integration test file, and a
// flag matrix, so it can be diff-tested against GNU and its suites can be
// scoped. A `module` under src/common/ has none of those: its tests are in the
// shared `common` test binary, which has no per-module filter, and its blast
// radius is every utility that imports it — so its gates are the FULL suites,
// always.
// ---------------------------------------------------------------------------
function utility(name, over) {
  const o = over || {};
  return {
    kind: 'utility',
    key: name,
    util: name,
    test_util: o.test_util || name,
    src: o.src || [`src/${name}.zig`],
    it_files: o.it_files || [`tests/utilities/${name}_test.sh`],
    it_targets: o.it_targets || [name],
    spec: o.spec || [`docs/specs/${name}-flags.md`],
  };
}

function module_(name) {
  return {
    kind: 'module',
    key: `common/${name}`,
    util: `common/${name}`,
    src: [`src/common/${name}.zig`],
    it_files: [],
    it_targets: [],
    spec: [],
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
    // therefore never executed. Listing it makes the finders actually read it.
    it_files: ['tests/utilities/echo_test.sh', 'tests/utilities/echo_test_complex.sh'],
  },
};

// Shared code is swept FIRST. A bug in argparse or the walker is a bug in all
// 47 utilities at once, and auditing a utility against a broken foundation
// wastes the audit and risks baking the shared defect into its new tests.
// These same waves run AGAIN at the end (ids S0b..S8b), because the utility
// fixes add new callers and new duplication worth consolidating.
// Capped at WAVE_UNITS_MAX. Every unit gets its own worktree and every
// worktree carries 1.3-3.6 GB of .zig-cache (more once the green phase starts
// running full suites), so a wave's width is a disk reservation, not just a
// concurrency knob. The earlier theme-based grouping put 7 modules in one wave,
// which would have meant ~21 GB of simultaneous cache on a host that had 35 GB
// free.
const SHARED_WAVES = [
  { id: 'S0', why: 'every utility parses args through it; already has a known CRITICAL', modules: ['argparse'] },
  { id: 'S1', why: '8 utilities traverse through it; history of data-loss bugs', modules: ['walker'] },
  { id: 'S2', why: 'file primitives', modules: ['file_ops', 'file'] },
  { id: 'S3', why: 'directory and path handling', modules: ['directory', 'path'] },
  { id: 'S4', why: 'permissions and identity', modules: ['mode', 'user_group'] },
  { id: 'S5', why: 'globbing and environment', modules: ['glob', 'env'] },
  { id: 'S6', why: 'shared constants and formatting', modules: ['constants', 'format'] },
  { id: 'S7', why: 'user-facing output plumbing', modules: ['help', 'prompt'] },
  { id: 'S8', why: 'entry points and the library root', modules: ['main', 'lib'] },
  { id: 'S9', why: 'glyphs and width computation', modules: ['icons', 'unicode'] },
  { id: 'S10', why: 'display configuration and styling', modules: ['display_config', 'style'] },
  { id: 'S11', why: 'color and terminal capability detection', modules: ['colors', 'terminal'] },
  { id: 'S12', why: 'time formatting', modules: ['time', 'relative_date'] },
  { id: 'S13', why: 'repository state and the dormant-test lint', modules: ['git', 'force_import_lint'] },
  { id: 'S14', why: 'test infrastructure; this repo has shipped 272 dormant tests', modules: ['test_utils', 'test_utils_privilege'] },
  { id: 'S15', why: 'test fixtures and the privilege harness', modules: ['test_dir', 'privilege_test'] },
  { id: 'S16', why: 'the privilege integration harness', modules: ['privilege_test_integration'] },
];

// Utility waves, ordered by implementation-size-to-test-coverage gap. Giants
// get smaller waves because wall-clock scales with source size.
// Same cap. Anything over ~3000 source lines runs alone, because its cache and
// its wall clock are both roughly double a small utility's; the rest pair up.
// Ordering is still by implementation-size-to-test-coverage gap.
const UTIL_WAVES = [
  { id: 'U0', utils: ['whoami', 'true'] },
  { id: 'U1', utils: ['false', 'free'] },
  { id: 'U2', utils: ['df'] },
  { id: 'U3', utils: ['du'] },
  { id: 'U4', utils: ['dd'] },
  { id: 'U5', utils: ['sort', 'seq'] },
  { id: 'U6', utils: ['id', 'nl'] },
  { id: 'U7', utils: ['tr', 'cut'] },
  { id: 'U8', utils: ['date', 'timeout'] },
  { id: 'U9', utils: ['uniq', 'tac'] },
  { id: 'U10', utils: ['env', 'realpath'] },
  { id: 'U11', utils: ['readlink', 'mktemp'] },
  { id: 'U12', utils: ['find'] },
  { id: 'U13', utils: ['stat'] },
  { id: 'U14', utils: ['printf', 'test'] },
  { id: 'U15', utils: ['ls'] },
  { id: 'U16', utils: ['cp'] },
  { id: 'U17', utils: ['grep'] },
  { id: 'U18', utils: ['mv'] },
  { id: 'U19', utils: ['chmod'] },
  { id: 'U20', utils: ['chown', 'rm'] },
  { id: 'U21', utils: ['rmdir', 'mkdir'] },
  { id: 'U22', utils: ['ln', 'touch'] },
  { id: 'U23', utils: ['tail', 'head'] },
  { id: 'U24', utils: ['wc', 'cat'] },
  { id: 'U25', utils: ['tee', 'sleep'] },
  { id: 'U26', utils: ['echo', 'yes'] },
  { id: 'U27', utils: ['basename', 'dirname'] },
  { id: 'U28', utils: ['pwd'] },
];

function cfgFor(u) {
  const slug = u.key.replace('/', '-');
  const workdir = `${WT_ROOT}/vibeutils-fix-${slug}`;
  const at = (p) => `${workdir}/${p}`;
  const inWt = (cmd) => `cd ${workdir} && ${cmd}`;
  const isUtil = u.kind === 'utility';
  // A module change can break any utility, and the common test binary has no
  // per-module filter, so its "scoped" gate is the full suite. That is the
  // real cost of touching shared code, not an oversight.
  const scopedUnit = isUtil ? `zig build test -Dtest-util=${u.test_util}` : COMMON.test_cmd;
  const scopedIt = isUtil
    ? u.it_targets.map((t) => inWt(`bash tests/integration.sh ${t}`)).join(' ; ')
    : inWt(COMMON.full_it_cmd);
  return {
    ...u,
    workdir,
    src_abs: u.src.map(at),
    it_abs: u.it_files.map(at),
    spec_abs: u.spec.map(at),
    util_test_cmd: inWt(scopedUnit),
    it_cmd: scopedIt,
    test_cmd: inWt(COMMON.test_cmd),
    privileged_test_cmd: inWt(COMMON.privileged_test_cmd),
    fmt_cmd: inWt(COMMON.fmt_cmd),
    full_it_cmd: inWt(COMMON.full_it_cmd),
    tiger_cmd: inWt(COMMON.tiger_cmd),
    linux_test_cmd: inWt(`${COMMON.linux_prefix} ${COMMON.test_cmd}`),
    linux_build_cmd: inWt(`${COMMON.linux_prefix} zig build`),
    linux_it_cmd: isUtil
      ? u.it_targets.map((t) => inWt(`${COMMON.linux_prefix} bash tests/integration.sh ${t}`)).join(' ; ')
      : inWt(`${COMMON.linux_prefix} ${COMMON.full_it_cmd}`),
  };
}

// ---------------------------------------------------------------------------
// Shared preambles. Byte-identical across every agent in a unit's chain so the
// wave shares prompt-cache prefixes instead of paying for a fresh preamble on
// each dispatch.
// ---------------------------------------------------------------------------
function wtPreamble(c) {
  const lines = [
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
    `Unit: ${c.util} (${c.kind})`,
    `Source: ${c.src.join(', ')}`,
    `Unit tests: embedded \`test "..."\` blocks inside ${c.src.join(', ')}`,
  ];
  if (c.kind === 'utility') {
    lines.push(`Integration tests: ${c.it_files.join(', ')}`);
    lines.push(`Flag matrix: ${c.spec.join(', ')}`);
  } else {
    lines.push('This is a SHARED MODULE under src/common/. It has no integration test file and no flag');
    lines.push('matrix. Every utility that imports it is its blast radius, so a defect here is a defect');
    lines.push('in many utilities at once — and its tests live in the shared `common` test binary,');
    lines.push('which has NO per-module filter.');
  }
  return lines.join('\n');
}

// The house rules an auditor needs to tell a real defect from a convention.
// Distilled inline so no agent spends a turn re-reading CLAUDE.md or
// docs/TESTING_STRATEGY.md (see the fleet-efficiency rules).
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
  '- Classify `kind` honestly. The kind decides what you will be asked to PROVE, so it matters:',
  '    bug          = the implementation behaves incorrectly. Must be reproducible: someone will be',
  '                   asked to run a command and watch it fail. Do not file a bug you cannot imagine',
  '                   a reproduction for.',
  '    test_defect  = an existing test is wrong, toothless, dead, or duplicated. Proven by sabotage.',
  '    missing_test = behavior that is implemented but untested. Proven by a coverage search.',
  '    dead_code    = code with no reachable caller. DETERMINISTIC: provable by deleting it and',
  '                   watching the build and full suite still pass. File it only when you believe',
  '                   that would hold.',
  '    duplication  = the same logic exists elsewhere, or a shared helper already does this. This is',
  '                   a JUDGEMENT CALL, not a fact — it goes to a separate reviewer who decides',
  '                   whether consolidating is worth it. Say plainly what you would merge into what.',
  '- Classify `scope`: `local` if the fix touches only this unit\'s own files; `cross_cutting` if it',
  '  would change another unit. Cross-cutting fixes are routed to their owning wave, so mislabeling',
  '  one as local will make two worktrees collide.',
  '- Severity: CRITICAL = wrong output/exit code/crash/data loss. IMPORTANT = a real defect with a',
  '  narrower blast radius. SUGGESTION = everything else.',
  '- Fill `reproducer` with an exact shell command that demonstrates the defect whenever one exists.',
  '  A finding with a reproducer is worth several without one.',
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
      '- An expected value derived the same way the code under test derives it. This is the defect',
      '  that hid a real CRITICAL bug in this repo: whoami\'s integration test did `expected=$(whoami)`',
      '  with an unqualified name while PATH was pinned to zig-out/bin, so the oracle WAS the binary',
      '  under test. Check every oracle for this.',
      '- test_command_output_pattern with a pattern loose enough to match any plausible output.',
      '- A missing `|| return 1` after test_binary_exists, so the rest runs against a missing binary.',
      '- Assertions on a variable that is empty or unset when the assertion runs.',
      '- A test whose command always succeeds regardless of the behavior under test.',
      '- Unit tests that assert on the PARSED FLAG rather than the behavior — `parsed.follow == true`',
      '  is not a test of following.',
      'For each candidate, state the concrete mutation to the implementation that SHOULD break the',
      'test but would not. That mutation is your evidence.',
    ].join('\n'),
  },
  {
    id: 'T2',
    name: 'wrong-expectation',
    focus: [
      'Find tests whose EXPECTED VALUE is wrong — they pin current behavior rather than the reference',
      'behavior. These are the worst class of defect here: they actively defend a bug.',
      'Compare each assertion against what GNU coreutils actually does. You have a Linux VM: run',
      '`orb -m ubuntu <the real GNU utility> <args>` to pin the reference output, exit code, and error',
      'text rather than reasoning from memory. Check the exit code and the stderr text, not just',
      'stdout — error-message wording and operand quoting are in scope and have been real bugs here.',
      'Also flag assertions that are over-constrained: pinning an incidental detail (a timestamp, a',
      'device number, an inode, a locale-dependent string) that will flake rather than catch a bug.',
    ].join('\n'),
  },
  {
    id: 'T3',
    name: 'duplication-and-dead',
    focus: [
      'Find test code that does not earn its place:',
      '- Near-identical cases that exercise the same code path with different literals.',
      '- Tests that never execute. The runner only picks up tests/utilities/<u>_test.sh and calls',
      '  test_<u>; a helper file with any other name is dead. A test function defined but never called',
      '  from test_<u> is dead. A Zig test in a file that is never force-imported is dormant — this',
      '  repo has shipped 272 dormant tests, three separate times (see force_import_lint.zig).',
      '- Setup or fixtures built and never used.',
      '- Unit tests and integration tests asserting the identical thing, where one is redundant.',
      'Prove deadness: show the glob, the missing call site, or the absent import.',
    ].join('\n'),
  },
  {
    id: 'T4',
    name: 'missing-edge-cases',
    focus: [
      'Find behavior that is implemented but UNTESTED. For a utility, work from the flag matrix: for',
      'every MUST and SHOULD flag marked `yes` in the `Ours` column, find the test that proves it',
      'changes behavior. A flag with no behavioral test is a finding. For a shared module, work from',
      'the public API: every exported function and every branch inside it.',
      'Then the input edge cases this codebase has actually been bitten by:',
      '- no operands at all; `-` as an operand; `--` end-of-options; an empty string operand.',
      '- empty input, input with no trailing newline, CRLF, NUL bytes, invalid UTF-8, a line longer',
      '  than the 8192-byte buffer (raises error.StreamTooLong, not EndOfStream, and has crashed a',
      '  utility here).',
      '- 0, 1, and enormous numeric arguments; negative where the flag accepts a sign.',
      '- symlinks, symlink loops, dangling symlinks, a symlink whose target is a directory.',
      '- unreadable files, unwritable directories, a nonexistent path mid-operand-list (partial',
      '  failure must still emit the good output AND exit 1).',
      '- output to a pipe vs a terminal, where behavior changes on isatty.',
      '- TZ, LANG/LC_ALL, NO_COLOR, and TERM where they are read.',
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
      '  exit status; missing cleanup leaking temp state into the next test.',
      '- A 4096-byte buffer where the convention is 8192.',
      '- Anything mutating the environment via libc setenv/unsetenv inside a test — Zig 0.16 captured',
      '  `environ` at init, and corrupting it deadlocked the panic handler and hung the whole suite',
      '  (issue #95).',
      '- A test depending on wall-clock timing or on another test having run first.',
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
      'In scope: flag semantics and their interactions; default behavior with no flags; exit codes',
      '(0/1/2, argument errors are 2); stdout formatting down to separators, padding, and trailing',
      'newlines; stderr wording, the `util: ` prefix, and operand quoting; the order operands are',
      'processed and errors reported; what happens when flags conflict (GNU usually resolves',
      'last-wins rather than erroring).',
      'For a shared module, compare the behavior it produces in each utility that calls it.',
      'Do NOT report a flag the matrix marks WONT as missing.',
    ].join('\n'),
  },
  {
    id: 'C2',
    name: 'stubs',
    focus: [
      'Find flags and options that are PARSED BUT NEVER PLUMBED — accepted, stored in the options',
      'struct, then never consulted where they would change behavior. This is the highest-yield',
      'defect class in this codebase: `ls -C` was parsed and ignored for months, and `ls` never',
      'consulted the `is_terminal` value it had already computed.',
      'Method, do not skip it: for EVERY field of the parsed-options struct, grep for every read of',
      'that field. A field written by the parser and read nowhere is a stub. A field read only in',
      'help text, only in a test, or only to be copied into another struct that is itself never read,',
      'is also a stub.',
      'Then the weaker form: a flag consulted on one code path but not on the parallel path handling',
      'the other case (single operand vs many, file vs directory, terminal vs pipe).',
      'For a shared module: every exported function with no caller, every parameter never read, every',
      'struct field never consulted.',
      'Report the field name, its write site, and the absence of a real read site.',
    ].join('\n'),
  },
  {
    id: 'C3',
    name: 'memory-and-resources',
    focus: [
      'Find resource defects:',
      '- Allocations not freed on a path the arena does not cover; frees on memory the arena owns.',
      '- Use-after-free, especially pointers into memory owned by something reset or freed.',
      '- Pointers returned by libc into STATIC buffers — getpwuid, getgrgid, getpwnam, strerror,',
      '  localtime — used after any other libc call could have reused the buffer. This has caused a',
      '  real bug here; the rule is copy the string out immediately.',
      '- File descriptors, directory handles, and mapped memory not closed on the error path.',
      '- Buffered writers not flushed before the buffer goes out of scope (data loss), or flushed',
      '  after the underlying file is closed.',
      '- Unbounded loops: `while (true)` with no counter, a retry loop with no cap (an uncapped',
      '  getgrouplist retry once hung CI for 29 minutes), a read loop not terminating on a short read.',
      '- Integer overflow or truncation in size, offset, and count arithmetic, and casts that can trap',
      '  in a safe build.',
    ].join('\n'),
  },
  {
    id: 'C4',
    name: 'platform',
    focus: [
      'Find behavior that is wrong on one platform. Verify on the Linux VM (`orb -m ubuntu`) rather',
      'than assuming; you are running on macOS.',
      '- Signed stat fields: macOS st_dev on devfs is a signed i32 with the high bit set, so @intCast',
      '  to u64 traps. It must be @bitCast. Check every cast of a libc struct field.',
      '- isatty gating: color, columns, progress, and every interactive prompt need their OWN isatty',
      '  check, not one check on the first path. ColorMode.detect() only reads env vars — without an',
      '  isatty check ANSI codes leak into pipes and test buffers.',
      '- errno values that differ between platforms, and errno classified as unexpected when it is an',
      '  ordinary case (std.posix.unexpectedErrno dumps a stack trace in safe builds).',
      '- struct layout differences between glibc and macOS libc for any extern struct, and',
      '  File.Stat.atime being optional.',
      '- Timezone handling: std.time.epoch has no tz database, so a naive conversion prints UTC.',
      '- Regex, locale, and libc feature differences (macOS libc rejects GNU regex escapes).',
      '- Zig 0.16 API correctness on paths the compiler may not reach: every blocking call takes io.',
    ].join('\n'),
  },
  {
    id: 'C5',
    name: 'dead-code',
    focus: [
      'Find code with NO REACHABLE CALLER. This is the deterministic half of the cleanup work: a dead',
      'symbol is a fact you can prove, not an opinion.',
      '- exported and private functions never called.',
      '- struct fields written but never read, or never touched at all.',
      '- enum variants never constructed, switch arms never reachable.',
      '- branches whose condition cannot hold, and error paths for errors the callee cannot return.',
      '- whole files nobody imports, and test helpers with zero consumers (this repo already carries',
      '  `TestWriter` and `StdoutCapture` in src/common/test_utils.zig with no users at all).',
      'Method: for each candidate, grep the WHOLE tree for its name and show that the only hits are',
      'the definition itself, its own doc comment, and nothing else. Be careful with the two ways this',
      'codebase hides live references: `@import` chains that only look dead (see',
      'src/common/force_import_lint.zig) and symbols reached through comptime or a struct literal',
      'rather than by name.',
      'Set `kind` to `dead_code`. The proof obligation is deletion: someone will delete it and confirm',
      'the build and the full suite still pass, so only file it when you expect that to hold.',
    ].join('\n'),
  },
  {
    id: 'C6',
    name: 'duplication-and-reuse',
    focus: [
      'Find logic that already exists elsewhere. Unlike the other lenses this one is a JUDGEMENT CALL,',
      'and you are expected to exercise judgement rather than report every similarity you notice.',
      'Read the shared module list first (`ls src/common/`), then look for hand-rolled versions of:',
      '- directory traversal that should use common/walker.zig (bounded, cycle-aware; hand-rolled',
      '  walks here have shipped symlink-loop and sibling-alias data-loss bugs, so this one usually',
      '  IS worth consolidating).',
      '- argument parsing that should use common/argparse.zig; help/version output that should use',
      '  common/help.zig; mode parsing that should use common/mode.zig; path manipulation that should',
      '  use common/path.zig; copy and permission primitives in common/file_ops.zig; error printing',
      '  that should use common.printErrorWithProgram.',
      '- the same non-trivial logic copy-pasted between two units (compare against the sibling that',
      '  shares the behavior — cp/mv, rm/rmdir, head/tail, chmod/chown).',
      'This project states its own bias plainly: a little copying is better than a little dependency,',
      'and it does not refactor for its own sake. So the bar is not "these look similar" — it is',
      '"merging these would make the code genuinely better, and the shared version would not need a',
      'flag or a branch for each caller." Two functions that resemble each other but drift for good',
      'reasons are correctly duplicated. Report the weak ones anyway if you find them, but say so',
      'honestly in `claim`; a reviewer decides, and an inflated list wastes its time.',
      'Set `kind` to `duplication` and state exactly what you would merge into what.',
      'If replacing the local copy would CHANGE behavior, that is a `bug` finding instead — say which',
      'behavior moves.',
    ].join('\n'),
  },
  {
    id: 'C7',
    name: 'cross-utility-consistency',
    focus: [
      'Find where this unit is INCONSISTENT with its siblings on behavior every utility should share.',
      'This class is invisible to a per-unit audit, so it is yours alone. A real example from this',
      'sweep: whoami omits the `Try \'whoami --help\' for more information.` line that 14 other',
      'vibeutils utilities emit after a usage error — found only by comparison.',
      'Method: pick the behavior, then grep the whole of src/ for how every other utility does it, and',
      'report this unit as the outlier (or report that it is right and the majority is wrong — say',
      'which, and check GNU to break the tie).',
      'Behaviors worth comparing across all utilities:',
      '- the exact shape of usage/argument errors, and whether the `Try ... --help` hint follows.',
      '- the `--help` layout, the `--version` string format, and whether both are handled in',
      '  command-line order.',
      '- how operands are quoted in error messages.',
      '- exit code selection for the same class of failure.',
      '- whether `--` and a bare `-` are honored.',
      '- isatty gating and NO_COLOR handling.',
      '- how errors from a shared helper are reported to the user.',
    ].join('\n'),
  },
];

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const FINDING_PROPS = {
  id: { type: 'string', description: 'Lens id + number, e.g. T1-1, C2-3, D-7.' },
  severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
  kind: { type: 'string', enum: ['bug', 'test_defect', 'missing_test', 'dead_code', 'duplication'] },
  scope: { type: 'string', enum: ['local', 'cross_cutting'] },
  location: { type: 'string', description: 'file:line you actually read' },
  claim: { type: 'string' },
  evidence: { type: 'string' },
  fix: { type: 'string', description: 'The concrete change, or the behavior the missing test must assert.' },
  reproducer: { type: 'string', description: 'Exact shell command demonstrating the defect, if one exists.' },
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

const DIFF_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['invocations_compared', 'divergences', 'both_built'],
  properties: {
    both_built: { type: 'boolean', description: 'Our Linux binary built AND the GNU reference was found.' },
    invocations_compared: { type: 'integer' },
    divergences: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['reproducer', 'ours', 'gnu', 'channel', 'severity'],
        properties: {
          reproducer: { type: 'string', description: 'Exact command, runnable as-is on the Linux VM.' },
          channel: { type: 'string', enum: ['stdout', 'stderr', 'exit_code', 'multiple'] },
          ours: { type: 'string' },
          gnu: { type: 'string' },
          severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
          corpus_input: {
            type: 'string',
            description: 'Input file content that triggers it, if the reproducer needs one, for tests/fuzz/<u>/corpus/.',
          },
          environment_dependent: {
            type: 'boolean',
            description: 'true if the difference is host state (mounts, uid, clock), not a defect.',
          },
        },
      },
    },
    notes: { type: 'string' },
  },
};

const REPRO_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['finding_id', 'reproduced', 'reproduction_kind', 'command', 'observed', 'expected'],
  properties: {
    finding_id: { type: 'string' },
    reproduced: {
      type: 'boolean',
      description: 'You RAN this and SAW the defect. Not "the code looks like it would".',
    },
    reproduction_kind: {
      type: 'string',
      enum: ['shell', 'zig_test', 'sabotage', 'coverage_gap', 'not_reproducible'],
    },
    setup: { type: 'string', description: 'Commands creating the fixtures, runnable as-is. Empty if none.' },
    command: { type: 'string', description: 'The exact command that exhibits the defect, runnable after setup.' },
    observed: { type: 'string', description: 'Verbatim output and exit code you actually saw.' },
    expected: { type: 'string', description: 'Verbatim reference output and exit code, or the behavior required.' },
    reference_command: { type: 'string', description: 'The GNU invocation used to pin `expected`, if applicable.' },
    platforms: {
      type: 'array',
      items: { type: 'string', enum: ['macos', 'linux'] },
      description: 'Where you confirmed it. Empty means you confirmed it nowhere.',
    },
    corpus_input: { type: 'string', description: 'File content that triggers it, for tests/fuzz/<u>/corpus/.' },
    notes: { type: 'string', description: 'If not reproduced, why — and what would be needed to stage it.' },
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

const REFUTE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'refuted', 'reason'],
        properties: {
          id: { type: 'string' },
          refuted: { type: 'boolean', description: 'true if the finding is wrong or does not reproduce' },
          reason: { type: 'string', description: 'Must cite file:line or a command you ran.' },
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
    corpus_files_written: { type: 'array', items: { type: 'string' } },
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
// never a substitute auditor — a silently-Claude "Codex" opinion would void
// the two-family premise this whole sweep rests on.
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

// Findings already surfaced in earlier rounds. Rendered compactly: the finders
// need to know what is taken, not to re-read it.
function knownList(seen) {
  if (!seen || seen.length === 0) return '';
  return [
    '',
    `## ALREADY FOUND (${seen.length}) — do NOT report these again`,
    'Earlier rounds surfaced the findings below. Reporting any of them again is wasted work. Your job',
    'this round is to find what those rounds MISSED. Go deeper: read the code paths nobody cited,',
    'follow the callers, try the input shapes nobody tried. If after genuine effort there is nothing',
    'new, return an empty list — that is the signal this unit is converging, and a padded list',
    'actively harms it.',
    seen.map((f) => `- ${f.location}: ${f.claim}`).join('\n'),
  ].join('\n');
}

function codexAuditPrompt(c, target, lens, seed, seen) {
  const files = target === 'tests' ? c.it_files.concat(c.src) : c.src;
  return [
    'You are auditing the vibeutils repository (a Zig 0.16 implementation of GNU coreutils).',
    `Unit: \`${c.util}\`. Target: the ${target === 'tests' ? 'TESTS' : 'IMPLEMENTATION'}.`,
    `Read these files yourself: ${files.join(', ')}.`,
    c.kind === 'utility'
      ? `The unit tests are the \`test "..."\` blocks embedded in ${c.src.join(', ')}; the integration tests are ${c.it_files.join(', ')}. The authoritative flag matrix is ${c.spec.join(', ')}.`
      : 'This is a shared module under src/common/. It has no integration test file and no flag matrix; its tests live in the shared `common` test binary, and every utility importing it is its blast radius.',
    '',
    HOUSE_RULES,
    '',
    `## YOUR LENS — ${lens.id} (${lens.name}). Stay on it; other agents cover the rest.`,
    lens.focus,
    seed ? `\n## CONTEXT FROM THE TEST AUDIT\n${seed}` : '',
    knownList(seen),
    '',
    REPORTING_RULES,
    '',
    'Output ONLY a JSON array, nothing else:',
    `[{"id":"${lens.id}-1","severity":"CRITICAL|IMPORTANT|SUGGESTION",`,
    '  "kind":"bug|test_defect|missing_test|refactor","scope":"local|cross_cutting",',
    '  "location":"file:line","claim":"what is wrong","evidence":"the code or behavior you cite",',
    '  "fix":"the concrete change","reproducer":"exact shell command, or empty"}]',
    'Return [] if you find nothing.',
  ].join('\n');
}

async function codexAudit(c, target, lens, seed, seen, round) {
  const promptFile = `${CODEX_TMP}/${c.key.replace('/', '-')}-${target}-${lens.id}-r${round}.md`;
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
      codexAuditPrompt(c, target, lens, seed, seen),
      '--- END audit request ---',
    ].join('\n'),
    {
      label: `codex:${c.util}:${target}:${lens.id}:r${round}`,
      phase: target === 'tests' ? 'Audit tests' : 'Audit code',
      model: 'sonnet',
      schema: CODEX_FINDINGS_SCHEMA,
    },
  ).catch(() => null);
}

async function opusAudit(c, target, lens, seed, seen, round) {
  const files = target === 'tests' ? c.it_abs.concat(c.src_abs) : c.src_abs;
  return await agent(
    [
      wtPreamble(c),
      '',
      `## YOUR TASK (auditor — lens ${lens.id}, ${lens.name}, round ${round})`,
      `Audit the ${target === 'tests' ? 'TESTS' : 'IMPLEMENTATION'} of \`${c.util}\` through ONE lens.`,
      `Read: ${files.join(', ')}.`,
      'You are one of ten auditors on this target, each with a different lens. Stay on yours — the',
      'others cover the rest, and a broad shallow pass from you is worth less than a deep narrow one.',
      'READ ONLY. Do not edit, do not commit, do not run a formatter.',
      'You MAY build and run things to check a hypothesis; prefer the scoped, quiet commands:',
      `  ${c.util_test_cmd}`,
      c.kind === 'utility' ? `  ${c.it_cmd}` : '',
      'and pipe verbose output through `tail`.',
      c.kind === 'module'
        ? [
            'This module has NO scoped suite — the common test binary has no per-module filter and the',
            'integration suite covers all 47 utilities, so both take many minutes. Use `zig build` to',
            'compile-check a hypothesis, run the unit suite sparingly, and do not run the integration',
            'suite during the audit at all. Reading is cheaper than running here, and the gates in a',
            'later phase do the exhaustive verification.',
          ].join('\n')
        : '',
      '',
      HOUSE_RULES,
      '',
      `## YOUR LENS — ${lens.id} (${lens.name})`,
      lens.focus,
      seed ? `\n## CONTEXT FROM THE TEST AUDIT\n${seed}` : '',
      knownList(seen),
      '',
      REPORTING_RULES,
    ].join('\n'),
    {
      label: `opus:${c.util}:${target}:${lens.id}:r${round}`,
      phase: target === 'tests' ? 'Audit tests' : 'Audit code',
      model: 'opus',
      schema: FINDINGS_SCHEMA,
    },
  ).catch(() => null);
}

// ---------------------------------------------------------------------------
// Differential testing. The only stage that finds defects mechanically rather
// than by reading — it runs our binary and GNU's side by side and diffs them.
// Both run INSIDE the Linux VM so a divergence means a real behavior
// difference, not a macOS-versus-Linux artifact.
// ---------------------------------------------------------------------------
async function differentialTest(c, seen, round) {
  return await agent(
    [
      wtPreamble(c),
      '',
      `## YOUR TASK (differential tester — ours vs GNU, round ${round})`,
      `Mechanically compare \`${c.util}\` against the real GNU coreutils implementation and report`,
      'every behavioral difference. This is the one stage that finds bugs by RUNNING code rather than',
      'reading it, so bias hard toward running more invocations rather than reasoning about fewer.',
      '',
      'SETUP — both binaries must run in the same environment or the comparison is worthless:',
      `  1. Build ours for Linux:  ${c.linux_build_cmd}`,
      `  2. Confirm the GNU one exists: cd ${c.workdir} && ${COMMON.linux_prefix} which ${c.util}`,
      `     and check it is GNU: ${COMMON.linux_prefix} ${c.util} --version | head -1`,
      '  3. Run BOTH inside the VM. Ours is ./zig-out/bin/<u>; GNU is the absolute path from `which`.',
      '     Never compare a macOS run against a Linux run — that conflates platform with defect.',
      '  4. Pin the environment on every invocation: LC_ALL=C, LANG=C, TZ=UTC, and a fresh temp',
      '     directory with fixtures you create, so both see identical inputs.',
      'If either binary cannot be built or found, set both_built=false and say why. Do not guess at',
      'what GNU would print.',
      '',
      'WHAT TO COMPARE — for each invocation capture stdout, stderr, AND exit code separately, and',
      'diff all three. Most real findings in this repo have been in stderr text or the exit code, not',
      'stdout.',
      '',
      'WHAT TO INVOKE — be systematic, not anecdotal:',
      `  - every MUST and SHOULD flag in ${c.spec.join(', ')}, alone.`,
      '  - pairs and triples of flags that plausibly interact, including combinations the matrix does',
      '    not mention and combinations that contradict each other (GNU usually resolves last-wins',
      '    rather than erroring — verify which).',
      '  - the argument edge cases: no operands, `-`, `--`, an empty-string operand, a nonexistent',
      '    path, a path that is a directory where a file is expected, too many operands, an unknown',
      '    flag, a flag missing its required value, a numeric argument of 0 and one absurdly large.',
      '  - the input edge cases where the utility reads data: empty input, no trailing newline, CRLF,',
      '    NUL bytes, invalid UTF-8, a line longer than 8192 bytes, a very large file.',
      '  - filesystem shapes where relevant: symlinks, symlink loops, dangling symlinks, unreadable',
      '    files, unwritable directories, a directory operand.',
      '',
      'WHAT NOT TO REPORT — mark environment_dependent=true instead, and keep going:',
      '  - output that legitimately depends on host state: mount tables, uids, the clock, hostnames,',
      '    inode and device numbers, filesystem free space, memory totals.',
      '  - version strings and any `vibeutils` self-identification.',
      '  - differences that follow from a flag the matrix marks WONT.',
      'Everything else is a real divergence. GNU is the reference: when we differ, we are wrong unless',
      'the matrix says the flag is ours alone.',
      '',
      'For each divergence give a `reproducer` that runs AS-IS on the VM and demonstrates it, plus',
      'both outputs verbatim. Where the trigger is file content rather than arguments, put that',
      'content in `corpus_input` — it becomes a permanent regression fixture under',
      `tests/fuzz/${c.util}/corpus/.`,
      'Report invocations_compared honestly; it is the measure of how hard you looked.',
      'Do NOT edit any file, and do NOT write the corpus yourself — a later stage does that.',
      knownList(seen),
    ].join('\n'),
    {
      label: `diff-test:${c.util}:r${round}`,
      phase: 'Differential',
      model: 'opus',
      schema: DIFF_SCHEMA,
    },
  ).catch(() => null);
}

// A divergence is a finding with a reproducer attached and machine-checked
// evidence, which makes it the strongest kind this sweep produces.
function divergencesToFindings(diff, round) {
  if (!diff || !diff.both_built) return [];
  return (diff.divergences || [])
    .filter((d) => !d.environment_dependent)
    .map((d, i) => ({
      id: `D${round}-${i + 1}`,
      severity: d.severity || 'IMPORTANT',
      kind: 'bug',
      scope: 'local',
      location: `${d.reproducer}`,
      claim: `Differs from GNU on ${d.channel}: ours produced ${JSON.stringify(d.ours).slice(0, 300)}, GNU produced ${JSON.stringify(d.gnu).slice(0, 300)}.`,
      evidence: `Machine-compared inside the Linux VM with LC_ALL=C and TZ=UTC. Reproducer: ${d.reproducer}`,
      fix: 'Match GNU behavior on this invocation.',
      reproducer: d.reproducer,
      corpus_input: d.corpus_input || '',
    }));
}

// ---------------------------------------------------------------------------
// Consensus
// ---------------------------------------------------------------------------
function renderFindings(list) {
  if (!list || list.length === 0) return '(none)';
  return list
    .map((f) => {
      const head =
        `### ${f.id} [${f.severity}/${f.kind}/${f.scope}] ${f.location}\n` +
        `claim: ${f.claim}\nevidence: ${f.evidence}\nfix: ${f.fix}` +
        (f.reproducer ? `\nreproducer: ${f.reproducer}` : '');
      const r = f.repro;
      if (!r) return head;
      // The verified reproduction is the most useful thing downstream agents
      // get: it is a command someone already ran and watched fail.
      return [
        head,
        `VERIFIED REPRODUCTION (${r.reproduction_kind}, confirmed on ${(r.platforms || []).join(' + ') || 'no platform'}):`,
        r.setup ? `  setup:    ${r.setup}` : '',
        `  command:  ${r.command}`,
        `  observed: ${r.observed}`,
        `  expected: ${r.expected}`,
        r.reference_command ? `  pinned by: ${r.reference_command}` : '',
      ]
        .filter(Boolean)
        .join('\n');
    })
    .join('\n\n');
}

async function mergeFindings(c, target, opusFindings, codexFindings, round) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (consensus — merge two independent audits)',
      `Two model families audited the ${target} of \`${c.util}\` through the same lenses,`,
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
      'Also collapse duplicates WITHIN a family (the lenses overlap at the edges) and report how many',
      'you collapsed. Preserve every id you merged in the claim text so nothing becomes untraceable,',
      'e.g. "(T1-2, T4-5)".',
      'Do not add findings of your own. Do not drop a finding because you disagree with it — later',
      'stages exist for that, and dropping it here hides it from them.',
      '',
      `## FAMILY A (opus) — ${(opusFindings || []).length} findings`,
      renderFindings(opusFindings),
      '',
      `## FAMILY B (codex) — ${(codexFindings || []).length} findings`,
      renderFindings(codexFindings),
    ].join('\n'),
    {
      label: `merge:${c.util}:${target}:r${round}`,
      phase: 'Consensus',
      model: 'opus',
      schema: MERGE_SCHEMA,
    },
  ).catch(() => null);
}

async function opusCrossCheck(c, target, list, round) {
  return await agent(
    [
      wtPreamble(c),
      '',
      "## YOUR TASK (cross-check — adjudicate the other family's findings)",
      'An independent auditor (Codex, a different model family) reported these defects in the',
      `${target} of \`${c.util}\`. Your family did NOT find them. That asymmetry is information, but`,
      'it cuts both ways: it can mean the finding is wrong, or that your family missed it.',
      '',
      'For each, go read the actual code at the cited location and decide:',
      '  CONFIRM — the defect is real. It joins the agreed set and will be fixed.',
      '  REJECT  — the defect is not real. Say concretely why, citing the code that refutes it.',
      '            Rejecting because it is inconvenient, or because you assume a WONT-tier flag is',
      '            involved when it is not, is worse than confirming a marginal finding.',
      '  DISPUTE — you cannot settle it. It goes to a judge.',
      'READ ONLY. You may run the scoped checks to settle a factual question; you may not edit.',
      '',
      HOUSE_RULES,
      '',
      '## FINDINGS TO ADJUDICATE',
      renderFindings(list),
    ].join('\n'),
    {
      label: `crosscheck-opus:${c.util}:${target}:r${round}`,
      phase: 'Consensus',
      model: 'opus',
      schema: CROSSCHECK_SCHEMA,
    },
  ).catch(() => null);
}

async function codexCrossCheck(c, target, list, round) {
  const promptFile = `${CODEX_TMP}/${c.key.replace('/', '-')}-${target}-crosscheck-r${round}.md`;
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
      `Continuing your audit of the vibeutils unit \`${c.util}\` (${target}).`,
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
      label: `crosscheck-codex:${c.util}:${target}:r${round}`,
      phase: 'Consensus',
      model: 'sonnet',
      schema: CROSSCHECK_SCHEMA,
    },
  ).catch(() => null);
}

// Both families agreeing is weaker evidence than it looks: they can be
// confidently wrong together, and a bad finding acted on becomes a bad test.
// Three skeptics with distinct lenses try to kill the agreed set.
const REFUTE_LENSES = [
  {
    id: 'R1',
    name: 'does-it-reproduce',
    focus: [
      'Attack the CLAIM OF FACT. For each finding, actually try to make the defect happen: build the',
      'binary, run the reproducer if there is one, construct one if there is not, and observe. A',
      'finding whose described behavior you cannot produce is refuted, regardless of how plausible',
      'the reasoning looks. Say exactly what you ran and what you saw.',
    ].join('\n'),
  },
  {
    id: 'R2',
    name: 'is-it-actually-wrong',
    focus: [
      'Grant that the behavior happens, and attack whether it is WRONG. Check the reference: run the',
      'real GNU utility on the Linux VM and see whether it does the same thing. Check the flag matrix',
      'for a WONT tier that makes the gap deliberate. Check CLAUDE.md conventions for a house rule',
      'that makes it correct here. Many "bugs" are the specified behavior, and this repo deliberately',
      'declines whole categories of validation.',
    ].join('\n'),
  },
  {
    id: 'R3',
    name: 'is-the-fix-right',
    focus: [
      'Grant that it is a real defect, and attack the PROPOSED FIX. Would applying it break another',
      'caller, another platform, or another test? Does it change shared behavior that other units',
      'depend on? Is it scoped to this unit, or does it silently reach into src/common where it would',
      'collide with a concurrent worktree? Is it minimal, or does it drag in refactoring? Refute if',
      'the fix as written would do damage, and say what it would break.',
    ].join('\n'),
  },
];

async function refute(c, target, list, lens, round) {
  return await agent(
    [
      wtPreamble(c),
      '',
      `## YOUR TASK (adversarial refuter — lens ${lens.id}, ${lens.name})`,
      `Two independent auditors AGREED on the findings below about \`${c.util}\`. Your job is to prove`,
      'them WRONG. Agreement between two models is not proof: they share training data and they can',
      'be confidently wrong together. You are the check on that.',
      '',
      'Default to refuted=true when you are uncertain. A wrong finding that survives becomes a wrong',
      'test and then a wrong "fix" to real code, which is far more expensive than losing a marginal',
      'finding — another round of the audit loop will resurface anything genuinely real.',
      '',
      `## YOUR ANGLE OF ATTACK — ${lens.id}`,
      lens.focus,
      '',
      'You may build, run, and read anything, including the real GNU utilities on the Linux VM',
      `(\`${COMMON.linux_prefix} ...\`). You may NOT edit any file.`,
      'Every reason must cite a file:line you read or a command you ran with its output. "Seems fine"',
      'is not a refutation, and neither is "seems right" a confirmation.',
      '',
      HOUSE_RULES,
      '',
      '## FINDINGS TO ATTACK',
      renderFindings(list),
    ].join('\n'),
    {
      label: `refute:${c.util}:${target}:${lens.id}:r${round}`,
      phase: 'Consensus',
      model: 'opus',
      schema: REFUTE_SCHEMA,
    },
  ).catch(() => null);
}

// What counts as a reproduction depends on what kind of defect is claimed.
// A behavior bug is reproduced by making it happen; a toothless test is
// reproduced by breaking what it guards and watching it pass anyway.
const REPRO_OBLIGATION = {
  bug: [
    'This claims the implementation BEHAVES INCORRECTLY. Reproduce it by making it happen:',
    '  1. Build the binary and construct whatever fixtures are needed. Keep them minimal — the',
    '     smallest input that still exhibits the defect, not the one from the finding.',
    '  2. Run our binary. Capture stdout, stderr, and the exit code verbatim.',
    '  3. Pin the reference: run the real GNU utility on the Linux VM with the SAME input and the',
    '     same pinned environment (LC_ALL=C, LANG=C, TZ=UTC). Capture all three channels. Put the',
    '     invocation in reference_command. Never write `expected` from memory or from the finding —',
    '     it must come from a command you ran, or from the flag matrix if the flag is ours alone.',
    '  4. Confirm the two differ in the way the finding claims. If they differ some OTHER way, say so',
    '     in notes: the finding is mis-stated even if a defect exists.',
    'reproduction_kind is `shell` when a command line demonstrates it, `zig_test` when it can only be',
    'shown through an in-process test (an internal API, an allocator failure, a code path with no CLI',
    'route).',
  ].join('\n'),
  test_defect: [
    'This claims an EXISTING TEST IS BROKEN. A test cannot be shown broken by reading it, so',
    'reproduce it by SABOTAGE:',
    '  1. Temporarily mutate the implementation to break exactly the behavior this test claims to',
    '     guard. Write the mutation into `command` so it is reproducible.',
    '  2. Run the test. If it still PASSES, the defect is real and reproduced: the test has no teeth.',
    '     `observed` is the passing result under sabotage; `expected` is that it should have failed.',
    '  3. REVERT the mutation immediately and confirm the suite is back to its original state. Never',
    '     leave one in place. Say in notes that you reverted.',
    'If the test DOES fail under sabotage, it has teeth and the finding is wrong — set',
    'reproduced=false and say so. That is a valuable result, not a failure on your part.',
    'For a test that is claimed DEAD rather than toothless, reproduce differently: show the runner',
    'never reaches it (the glob that excludes the file, the missing call site, the absent',
    'force-import) by running the command that proves it. reproduction_kind is still `sabotage`.',
  ].join('\n'),
  missing_test: [
    'This claims behavior is IMPLEMENTED BUT UNTESTED. Reproduce the GAP, not a bug:',
    '  1. Show the behavior exists: run the invocation and capture what it does. That is `observed`.',
    '  2. Show nothing asserts it: grep the unit tests and the integration file for any assertion',
    '     covering it, and put that search in `command` with its (empty or irrelevant) output.',
    '  3. `expected` is what a test SHOULD assert about this behavior, pinned against GNU where GNU',
    '     defines it.',
    'reproduction_kind is `coverage_gap`. If you find an existing test that DOES cover it, the finding',
    'is wrong: set reproduced=false and cite that test.',
  ].join('\n'),
  dead_code: [
    'This claims code has NO REACHABLE CALLER. That is deterministic, so prove it deterministically —',
    'by deletion, not by reading:',
    '  1. Grep the whole tree for every reference to the symbol. Put that search and its output in',
    '     `command` and `observed`. Watch for the two ways this codebase hides live references:',
    '     `@import` force-import chains (src/common/force_import_lint.zig exists because of exactly',
    '     this) and symbols reached through comptime or a struct literal rather than by name.',
    '  2. Then actually DELETE it and build. Run the full unit suite and, for a utility, the scoped',
    '     integration suite. If everything still passes, the code is dead and you have proven it.',
    '  3. REVERT the deletion and confirm the tree is byte-identical to how you found it. Say in',
    '     notes that you reverted. The deletion is the proof, not the fix — a later phase does that.',
    '`expected` is that the build and suites pass without it. If ANY of them fail, the code is live:',
    'set reproduced=false and name the caller you uncovered. reproduction_kind is `sabotage`.',
  ].join('\n'),
};

const DUP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'worth_doing', 'reason'],
        properties: {
          id: { type: 'string' },
          worth_doing: { type: 'boolean' },
          reason: { type: 'string', description: 'Cite the two sites and say what merging would cost or save.' },
          consolidation: { type: 'string', description: 'If worth doing: exactly what merges into what.' },
        },
      },
    },
    summary: { type: 'string' },
  },
};

// Duplication is the one finding class with no fact to establish. Nothing can
// be run to prove that two similar functions SHOULD be one, so it gets a
// judgement gate instead of a reproduction gate. The bias is the project's
// own: a little copying beats a little dependency.
async function judgeDuplication(c, list, round) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (duplication reviewer — decide what is actually worth merging)',
      `Auditors flagged the duplication below in \`${c.util}\`. Unlike every other finding in this`,
      'sweep there is nothing to reproduce: no command proves that two similar functions ought to be',
      'one. It is a judgement call, and you are making it.',
      '',
      'This project states its bias plainly, and you are bound by it:',
      '  "Prefer simple, well-known tools. Avoid unnecessary complexity. A little copying is better',
      '   than a little dependency."',
      '  "Do not refactor, abstract, or add error handling beyond what the task requires. Do not',
      '   design for hypothetical future requirements."',
      'So the default answer is NO. Say yes only when merging makes the code genuinely better today.',
      '',
      'Go read BOTH sites before deciding — the whole function, not the flagged lines. Then weigh:',
      '  - Would the shared version need a flag, a branch, or a callback for each caller? If so the',
      '    duplication is doing real work and should stay. This is the most common reason to decline.',
      '  - Have the two copies already DRIFTED? Drift is usually a sign they answer different',
      '    questions, not that one is stale — but check whether the drift is a latent bug, and if it',
      '    is, say so: that is a `bug`, not duplication.',
      '  - Is one copy demonstrably more correct? Consolidating onto the better one fixes a real',
      '    defect and is usually worth it. common/walker.zig is the precedent: hand-rolled traversals',
      '    here shipped symlink-loop and sibling-alias data-loss bugs that the shared walker does not',
      '    have.',
      '  - How large and how tangled is the duplicated logic? Three similar lines are not worth a new',
      '    abstraction. Two hundred lines of subtle traversal or permission logic usually are.',
      '  - Would merging cross a unit boundary into src/common, and is that justified by more than',
      '    one caller needing it?',
      '',
      'You may read and build; you may NOT edit. Every reason must cite both sites by file:line.',
      'Declining is a real answer and needs no apology — record it and move on.',
      '',
      HOUSE_RULES,
      '',
      '## DUPLICATION TO JUDGE',
      renderFindings(list),
    ].join('\n'),
    {
      label: `dup-review:${c.util}:r${round}`,
      phase: 'Reproduce',
      model: 'opus',
      schema: DUP_SCHEMA,
    },
  ).catch(() => null);
}

// The finder claims; an independent agent must make the defect happen. A finder
// that both asserts and "verifies" its own bug is not evidence, which is the
// same separation this repo already enforces between tests and implementation.
async function reproduce(c, target, f, round) {
  const obligation = REPRO_OBLIGATION[f.kind] || REPRO_OBLIGATION.bug;
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (reproduction engineer — build it and run it)',
      'A finding has survived two independent audits and three adversarial refuters. Before anyone',
      'writes a test or changes a line of code, YOU must make the defect actually happen and record',
      'exactly how.',
      '',
      'You did not find this and you have no stake in it being real. Report what the machine does, not',
      'what the finding predicts. `reproduced=true` means you RAN something and SAW the defect — never',
      'that the code looks like it would misbehave. If you cannot make it happen, say so: an',
      'unreproduced finding is quarantined rather than fixed, and that is the correct outcome.',
      '',
      'Everything you write must be runnable AS-IS by someone who has only this worktree:',
      '  - `setup` creates every fixture from scratch in a fresh temp directory.',
      '  - `command` is the exact invocation, with our binary referenced by path.',
      '  - `observed` and `expected` are verbatim captures, including the exit code, not paraphrases.',
      'Prefer the smallest reproduction that still exhibits the defect. This becomes the regression',
      'test in the next phase, so a bloated one becomes a bloated test.',
      '',
      `Build with \`${c.linux_build_cmd}\` for Linux work and a plain \`cd ${c.workdir} && zig build\``,
      `for macOS. The real GNU utilities are on the VM (\`${COMMON.linux_prefix} ...\`).`,
      'Try BOTH platforms and record in `platforms` where it actually reproduced — a defect that',
      'appears on only one is still real, and knowing which one is what makes the fix correct.',
      'If the trigger is file CONTENT rather than arguments, put that content in `corpus_input`; it',
      `becomes a permanent fixture under tests/fuzz/${c.util}/corpus/.`,
      '',
      'You may create scratch files under /tmp and you may build. You may NOT edit any tracked file,',
      'except for a sabotage mutation you revert before finishing.',
      '',
      `## THE OBLIGATION FOR THIS KIND OF FINDING (${f.kind})`,
      obligation,
      '',
      HOUSE_RULES,
      '',
      '## THE FINDING',
      renderFindings([f]),
    ].join('\n'),
    {
      label: `repro:${c.util}:${f.id}`,
      phase: 'Reproduce',
      model: 'opus',
      schema: REPRO_SCHEMA,
    },
  ).catch(() => null);
}

async function judge(c, target, disputed, round) {
  const items = disputed
    .map(
      (d) =>
        `### ${d.id} [${d.severity}/${d.kind}] ${d.location}\n` +
        `CLAIMED: ${d.claim}\nEVIDENCE: ${d.evidence}\nPROPOSED FIX: ${d.fix}\n` +
        (d.reproducer ? `REPRODUCER: ${d.reproducer}\n` : '') +
        `THE OPPOSING VIEW: ${d.counter || '(unsettled)'}`,
    )
    .join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (judge — break a deadlock)',
      `Independent reviewers disagree about \`${c.util}\` (${target}) and neither will move. You`,
      'decide, and your decision is final.',
      '',
      'You must NOT arbitrate between the two written positions. Both may be wrong. Go read the',
      'actual code: open the cited files and read enough of the surrounding code to judge for',
      'yourself. You may run the scoped checks to settle a factual question',
      `(\`${c.util_test_cmd}\`${c.it_cmd ? `, \`${c.it_cmd}\`` : ''}) and you may run the real GNU`,
      `utility on the Linux VM (\`${COMMON.linux_prefix} ...\`) to pin reference behavior. You may NOT`,
      'edit any file.',
      '',
      HOUSE_RULES,
      '',
      'For each disputed finding return one verdict:',
      '  UPHOLD — the defect is real. `directive` states the concrete change to make.',
      '  REJECT — the defect is not real. `directive` is "none".',
      '  DEFER_CROSS_CUTTING — the defect is real but the fix would change another unit, so it cannot',
      "    be applied inside this unit's worktree. `directive` states the change for the owning wave.",
      'Every rationale must cite specific code you actually read (file:line). A rationale that only',
      "restates one side's argument is not acceptable.",
      '',
      '## DEADLOCKED FINDINGS',
      items,
    ].join('\n'),
    {
      label: `judge:${c.util}:${target}:r${round}`,
      phase: 'Consensus',
      model: 'fable',
      schema: JUDGE_SCHEMA,
    },
  ).catch(() => null);
}

// A finding whose fix reaches into another unit cannot be applied inside this
// worktree without two of them colliding on one file. Decide it in code rather
// than trusting the model's own label alone.
function isCrossCutting(c, f) {
  if (!f) return false;
  if (f.scope === 'cross_cutting') return true;
  const loc = String(f.location || '');
  const own = c.src.concat(c.it_files);
  const inOwn = own.some((p) => loc.includes(p));
  if (inOwn) return false;
  // A location that names some other source file belongs to that file's wave.
  return /(^|\/)src\//.test(loc) && !inOwn;
}

// Dedup key. Deliberately coarse: the same defect reported at a slightly
// different line in a later round must collide, or the loop never goes dry.
function dedupKey(f) {
  const loc = String(f.location || '').split(':')[0];
  const claim = String(f.claim || '')
    .toLowerCase()
    .replace(/[^a-z0-9 ]/g, '')
    .split(/\s+/)
    .filter((w) => w.length > 3)
    .slice(0, 8)
    .join(' ');
  return `${loc}|${claim}`;
}

// ---------------------------------------------------------------------------
// One discovery round over one target.
// ---------------------------------------------------------------------------
async function auditRound(c, target, lenses, seed, seen, round) {
  const thunks = [];
  for (const lens of lenses) thunks.push(() => opusAudit(c, target, lens, seed, seen, round));
  for (const lens of lenses) thunks.push(() => codexAudit(c, target, lens, seed, seen, round));
  // Differential testing is a code-side discovery channel and only exists for
  // units with a CLI.
  const wantDiff = target === 'code' && c.kind === 'utility';
  if (wantDiff) thunks.push(() => differentialTest(c, seen, round));

  const results = await parallel(thunks);
  const opusRuns = results.slice(0, lenses.length).filter(Boolean);
  const codexRuns = results.slice(lenses.length, lenses.length * 2).filter(Boolean);
  const diffRun = wantDiff ? results[lenses.length * 2] : null;

  const codexOk = codexRuns.filter((r) => r.invoked_ok);
  if (codexOk.length === 0) {
    log(`${c.util}/${target} r${round}: NO codex lens ran — the two-family premise is void this round.`);
  } else if (codexOk.length < lenses.length) {
    log(`${c.util}/${target} r${round}: only ${codexOk.length}/${lenses.length} codex lenses ran.`);
  }

  const diffFindings = divergencesToFindings(diffRun, round);
  if (wantDiff) {
    if (!diffRun || !diffRun.both_built) {
      log(`${c.util} r${round}: differential testing did NOT run (both_built=false) — surfacing, not skipping.`);
    } else {
      log(
        `${c.util} r${round}: differential compared ${diffRun.invocations_compared} invocations, ` +
          `${(diffRun.divergences || []).length} divergences (${diffFindings.length} real).`,
      );
    }
  }

  return {
    opus: opusRuns.flatMap((r) => r.findings || []).concat(diffFindings),
    codex: codexOk.flatMap((r) => r.findings || []),
    codexOk: codexOk.length,
    diff: diffRun,
  };
}

// Adjudicate one round's fresh findings: merge, cross-check the one-sided ones,
// attack the agreed ones, judge whatever is still contested.
async function adjudicate(c, target, opusFindings, codexFindings, codexOkCount, round) {
  const merged = await mergeFindings(c, target, opusFindings, codexFindings, round);
  if (!merged) return { confirmed: opusFindings.concat(codexFindings), dropped: [], judged: [] };

  const agreed = merged.agreed || [];
  const opusOnly = merged.opus_only || [];
  const codexOnly = merged.codex_only || [];
  log(
    `${c.util}/${target} r${round}: ${agreed.length} agreed, ${opusOnly.length} opus-only, ` +
      `${codexOnly.length} codex-only (collapsed ${merged.duplicates_collapsed || 0}).`,
  );

  // Each family adjudicates what the other raised alone; three skeptics attack
  // what both raised together. All of it runs concurrently.
  const jobs = [
    () => (codexOnly.length > 0 ? opusCrossCheck(c, target, codexOnly, round) : Promise.resolve(null)),
    () =>
      opusOnly.length > 0 && codexOkCount > 0
        ? codexCrossCheck(c, target, opusOnly, round)
        : Promise.resolve(null),
  ];
  for (const lens of REFUTE_LENSES.slice(0, REFUTERS)) {
    jobs.push(() => (agreed.length > 0 ? refute(c, target, agreed, lens, round) : Promise.resolve(null)));
  }
  const out = await parallel(jobs);
  const opusCheck = out[0];
  const codexCheck = out[1];
  const refutations = out.slice(2).filter(Boolean);

  const confirmed = [];
  const dropped = [];
  const disputed = [];

  // Agreed findings survive only if fewer than a majority of skeptics kill them.
  for (const f of agreed) {
    const votes = refutations
      .map((r) => (r.verdicts || []).find((v) => String(v.id) === String(f.id)))
      .filter(Boolean);
    const kills = votes.filter((v) => v.refuted);
    if (kills.length >= REFUTE_KILL_VOTES) {
      dropped.push({
        ...f,
        dropped_by: `${kills.length}/${refutations.length} adversarial refuters`,
        drop_reason: kills.map((v) => v.reason).join(' | '),
      });
    } else if (kills.length > 0) {
      // A split panel is exactly what the judge is for.
      disputed.push({ ...f, counter: kills.map((v) => v.reason).join(' | ') });
    } else {
      confirmed.push({ ...f, survived_refutation: `${votes.length} skeptics, 0 kills` });
    }
  }

  const sortOneSided = (list, res, sideLabel) => {
    for (const f of list) {
      const v = res && (res.verdicts || []).find((x) => String(x.id) === String(f.id));
      if (!v) {
        disputed.push({ ...f, counter: `${sideLabel} returned no verdict.` });
      } else if (v.verdict === 'CONFIRM') {
        confirmed.push({ ...f, confirmed_by: sideLabel, confirm_reason: v.reason });
      } else if (v.verdict === 'REJECT') {
        dropped.push({ ...f, dropped_by: sideLabel, drop_reason: v.reason });
      } else {
        disputed.push({ ...f, counter: v.reason });
      }
    }
  };
  sortOneSided(codexOnly, opusCheck, 'opus cross-check');
  if (opusOnly.length > 0 && codexOkCount > 0) {
    sortOneSided(opusOnly, codexCheck, 'codex cross-check');
  } else {
    for (const f of opusOnly) disputed.push({ ...f, counter: 'codex was unavailable to cross-check.' });
  }

  let judged = [];
  if (disputed.length > 0) {
    const ruling = await judge(c, target, disputed, round);
    judged = (ruling && ruling.verdicts) || [];
    log(`${c.util}/${target} r${round}: judge ruled on ${judged.length}/${disputed.length}.`);
    for (const f of disputed) {
      const v = judged.find((x) => String(x.id) === String(f.id));
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

  // Final gate, and it splits by kind. Everything with a fact to establish must
  // be PROVEN by an agent that did not find it: a bug by reproducing it, a
  // toothless test by sabotage, a coverage gap by search, dead code by deleting
  // it and watching the suite pass. A defect nobody can demonstrate is a defect
  // nobody has proven, and acting on one costs more than losing it — the
  // discovery loop resurfaces anything genuinely real on a later round.
  //
  // Duplication is the exception. There is no experiment that shows two similar
  // functions ought to be one, so it gets a judgement gate instead, biased
  // toward leaving the code alone.
  const provable = confirmed.filter((f) => f.kind !== 'duplication');
  const dupes = confirmed.filter((f) => f.kind === 'duplication');

  const proofJobs = [
    () => (dupes.length > 0 ? judgeDuplication(c, dupes, round) : Promise.resolve(null)),
  ].concat(provable.map((f) => () => reproduce(c, target, f, round)));
  const proofOut = await parallel(proofJobs);
  const dupRuling = proofOut[0];
  const repros = proofOut.slice(1);

  const reproduced = [];
  const unreproduced = [];
  for (let i = 0; i < provable.length; i += 1) {
    const f = provable[i];
    const r = repros[i];
    if (r && r.reproduced) {
      reproduced.push({ ...f, repro: r, corpus_input: r.corpus_input || f.corpus_input || '' });
    } else {
      unreproduced.push({
        ...f,
        repro: r || null,
        quarantine_reason: r ? r.notes || 'could not be demonstrated' : 'proof agent returned nothing',
      });
    }
  }

  const declined = [];
  for (const f of dupes) {
    const v = dupRuling && (dupRuling.verdicts || []).find((x) => String(x.id) === String(f.id));
    if (v && v.worth_doing) {
      reproduced.push({ ...f, fix: v.consolidation || f.fix, dup_reason: v.reason });
    } else {
      declined.push({
        ...f,
        dropped_by: 'duplication review',
        drop_reason: v ? v.reason : 'no verdict returned; left alone by default',
      });
    }
  }
  dropped.push(...declined);

  if (confirmed.length > 0) {
    log(
      `${c.util}/${target} r${round}: proved ${reproduced.length - (dupes.length - declined.length)}/${provable.length}, ` +
        `${unreproduced.length} quarantined; duplication ${dupes.length - declined.length}/${dupes.length} judged worth doing.`,
    );
  }

  return { confirmed: reproduced, unreproduced, dropped, judged };
}

// ---------------------------------------------------------------------------
// Loop-until-dry over one target. Rounds keep running until DRY_ROUNDS_REQUIRED
// consecutive rounds surface nothing new.
//
// Dedup is against everything ever SEEN, not against what was confirmed. Using
// the confirmed set instead would resurface every refuted finding on every
// round and the loop would never terminate.
// ---------------------------------------------------------------------------
async function auditTarget(c, target, lenses, seed) {
  const seen = new Map();
  const confirmed = [];
  const unreproduced = [];
  const dropped = [];
  const judged = [];
  let codexOkTotal = 0;
  let diffTotal = 0;
  let dry = 0;
  let round = 0;

  while (dry < DRY_ROUNDS_REQUIRED && round < AUDIT_ROUNDS_MAX) {
    round += 1;
    const known = [...seen.values()];
    const r = await auditRound(c, target, lenses, seed, known, round);
    codexOkTotal += r.codexOk;
    if (r.diff && r.diff.both_built) diffTotal += r.diff.invocations_compared || 0;

    const freshOpus = (r.opus || []).filter((f) => !seen.has(dedupKey(f)));
    const freshCodex = (r.codex || []).filter((f) => !seen.has(dedupKey(f)));
    const freshCount = freshOpus.length + freshCodex.length;

    if (freshCount === 0) {
      dry += 1;
      log(`${c.util}/${target} r${round}: nothing new (dry ${dry}/${DRY_ROUNDS_REQUIRED}).`);
      continue;
    }
    dry = 0;
    for (const f of freshOpus.concat(freshCodex)) seen.set(dedupKey(f), f);
    log(`${c.util}/${target} r${round}: ${freshCount} new raw findings (${seen.size} seen total).`);

    const adj = await adjudicate(c, target, freshOpus, freshCodex, r.codexOk, round);
    confirmed.push(...adj.confirmed);
    unreproduced.push(...(adj.unreproduced || []));
    dropped.push(...adj.dropped);
    judged.push(...adj.judged);
  }

  if (round >= AUDIT_ROUNDS_MAX && dry < DRY_ROUNDS_REQUIRED) {
    log(`${c.util}/${target}: hit the ${AUDIT_ROUNDS_MAX}-round cap while still finding new defects — NOT converged.`);
  }

  const deferred = confirmed.filter((f) => isCrossCutting(c, f));
  const actionable = confirmed.filter((f) => !isCrossCutting(c, f));
  log(
    `${c.util}/${target}: converged after ${round} rounds — ${actionable.length} actionable ` +
      `(all reproduced), ${deferred.length} deferred, ${unreproduced.length} quarantined, ` +
      `${dropped.length} dropped.`,
  );

  return {
    target,
    rounds: round,
    converged: dry >= DRY_ROUNDS_REQUIRED,
    agreed: actionable,
    deferred,
    unreproduced,
    dropped,
    judged,
    codex_lens_runs_ok: codexOkTotal,
    diff_invocations: diffTotal,
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
    "these code paths first — but audit through YOUR lens, not through the test audit's.",
    gaps.map((f) => `- [${f.kind}] ${f.location}: ${f.claim}`).join('\n'),
  ].join('\n');
}

async function auditUnit(c) {
  const tests = await auditTarget(c, 'tests', TEST_LENSES, '');
  const code = await auditTarget(c, 'code', CODE_LENSES, seedFromTests(tests));
  return { util: c.util, key: c.key, kind: c.kind, workdir: c.workdir, tests, code };
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
  const refactors = findingsByKind(audit, ['dead_code', 'duplication']);
  const withCorpus = bugs.filter((f) => f.corpus_input);
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (test-writer — you own every test in this worktree)',
      `An exhaustive audit of \`${c.util}\` agreed on the findings below. Act on the test-side ones.`,
      `Files you may edit: ${c.it_abs.concat(c.src_abs).join(', ')} — but in the source files you may`,
      'edit ONLY the `test "..."` blocks, never the implementation. Another agent owns that.',
      'Do NOT commit. Do NOT run a tree-wide formatter (`zig build fmt`); use `zig build fmt-check`.',
      'Do NOT touch TODO.md, CHANGELOG.md, or any file not listed above.',
      '',
      'Four jobs, in order:',
      '',
      '1. FIX THE BROKEN TESTS. For each test_defect finding, repair the test so it would fail if the',
      '   behavior regressed. A test that is merely deleted is not fixed unless the finding says it is',
      '   genuinely dead. Keep every test TOOTHFUL.',
      '',
      '2. ADD THE MISSING TESTS. For each missing_test finding, assert the BEHAVIOR, not the parse.',
      '   Some will PASS — good, that is coverage. Some will FAIL because the behavior is actually',
      '   wrong: leave those FAILING and list them in expected_failing. Never weaken a test to pass.',
      '',
      '3. WRITE THE RED TESTS. Every finding below carries a VERIFIED REPRODUCTION: a command an',
      '   independent agent already ran and watched fail, with the observed and expected output',
      '   captured verbatim. Build each test directly on that — the reproduction IS the test, and',
      '   translating it into the suite is most of your job here.',
      '   Assert `expected` exactly as recorded; it was pinned by running the real GNU utility, so do',
      '   not soften it to a substring match or re-derive it from your own reasoning. If the recorded',
      '   reproduction looks wrong to you, say so in `refused` rather than quietly asserting something',
      '   weaker.',
      '   List each in expected_failing with exactly what it asserts.',
      '',
      withCorpus.length > 0
        ? [
            `4. PERSIST THE FUZZ CORPORA. ${withCorpus.length} finding(s) carry a \`corpus_input\`: the`,
            `   file content that triggers the divergence. Write each under tests/fuzz/${c.util}/corpus/`,
            '   with a short descriptive filename, so it becomes a permanent regression fixture beyond',
            '   this sweep. Report the paths in corpus_files_written.',
          ].join('\n')
        : '4. No findings carry corpus input this time; skip the corpus step.',
      '',
      refactors.length > 0
        ? [
            'DEAD CODE and DUPLICATION findings are behavior-preserving, so they get CHARACTERIZATION',
            'tests instead: tests that pass against the code as it stands today and still pass after',
            'the cleanup. Write those too, and do NOT list them in expected_failing.',
            'Dead-code findings arrive with a deletion proof — an agent already removed the symbol and',
            'watched the build and suite pass. So the characterization test is not about the dead code',
            'itself (there is nothing to preserve); write it for the surrounding behavior the deletion',
            'must not disturb.',
          ].join('\n')
        : '',
      '',
      'If you judge a finding to be WRONG, do not act on it — record it in `refused` with your',
      'reasoning. You are the last check on the audit; a bad finding acted on becomes a bad test.',
      '',
      'Check your work with the scoped commands only (pipe through `tail`):',
      `  ${c.util_test_cmd}`,
      c.it_cmd ? `  ${c.it_cmd}` : '',
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
      `## DEAD CODE AND DUPLICATION NEEDING CHARACTERIZATION TESTS (${refactors.length})`,
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
      c.it_cmd ? `  macOS integration: ${c.it_cmd}` : '',
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
    { label: `red-check:${c.util}`, phase: 'Red', model: 'sonnet', schema: REDCHECK_SCHEMA },
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
      `  2. Run just that test (use \`-Dtest-filter\` or ${c.util_test_cmd}) and confirm RED.`,
      '  3. REVERT the mutation immediately. Never leave one in place, never commit one.',
      'At the end, run `git diff` and confirm the implementation is byte-identical to how you found',
      'it, then confirm the suite is green again. Report restored_clean honestly — a leftover mutation',
      'would be committed as if it were the fix.',
      '',
      '## CHARACTERIZATION TESTS TO PROVE',
      renderFindings(refactors),
    ].join('\n'),
    { label: `sabotage:${c.util}`, phase: 'Red', model: 'sonnet', schema: SABOTAGE_SCHEMA },
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

  const refactors = findingsByKind(audit, ['dead_code', 'duplication']);
  const teeth = refactors.length > 0 ? await proveTeeth(c, refactors) : null;

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
    corpus_files_written: written ? written.corpus_files_written || [] : [],
    expected_failing: written ? written.expected_failing || [] : [],
    refused: written ? written.refused || [] : [],
    red_check: check,
    sabotage: teeth,
    ready_to_commit_red: ready,
  };
}

// ---------------------------------------------------------------------------
// Phase: green
// ---------------------------------------------------------------------------
async function dispatchImplementer(c, body, label) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (implementer — you own the implementation, never the tests)',
      `Implementation files you may edit: ${c.src_abs.join(', ')} (NOT the \`test "..."\` blocks).`,
      `Test files you may NOT edit under any circumstances: ${c.it_abs.join(', ') || '(none)'}, and`,
      'every `test "..."` block in the source.',
      'Make the MINIMAL change that fixes each finding. Do not refactor surrounding code, do not add',
      'error handling the fix does not need, do not design for hypothetical requirements.',
      'Do NOT weaken, delete, or narrow any test. Do NOT commit. Do NOT run a tree-wide formatter.',
      '',
      'If a finding can only be resolved by changing a TEST, do not do it — return',
      'outcome="needs_test_change" with a precise description of what the test should assert instead.',
      'It routes to the test-writer, which decides whether the test is genuinely wrong.',
      '',
      'Check your work with the scoped, quiet commands ONLY (pipe through `tail`):',
      `  ${c.util_test_cmd}`,
      c.it_cmd ? `  ${c.it_cmd}` : '',
      `  ${c.fmt_cmd}`,
      'Do not run the privileged or full-platform suites — a separate gate runs those and reports',
      'distilled results.',
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

async function routeTestChange(c, requests) {
  const body = requests.map((t) => `### ${t.id}\nRequested: ${t.note}`).join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (test-writer — adjudicate requested test changes)',
      'The implementer says these test changes are needed. You own the tests; it does not.',
      'Judge FIRST, edit second.',
      '',
      `Test files you own: ${c.it_abs.join(', ') || '(none)'} and the \`test "..."\` blocks in`,
      `${c.src_abs.join(', ')}. Implementation code you may NOT touch: everything else in those files.`,
      '',
      'For each request: if the test is genuinely wrong — it asserts the buggy behavior, or asserts',
      'something the reference behavior does not require — fix it, but keep it TOOTHFUL: it must still',
      'fail if the bug returns. If the test is correct and the IMPLEMENTATION is what needs to change,',
      'REFUSE and say so plainly; the implementer will fix the code instead.',
      'The refusal is the point of this stage. An implementer that can rewrite the test that caught it',
      'can make any bug disappear.',
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

async function runImplementer(c, body, label) {
  let res = await dispatchImplementer(c, body, label);
  for (let hop = 0; hop < ROUTE_HOPS_MAX; hop += 1) {
    if (!res || res.outcome !== 'needs_test_change') break;
    const reqs = res.test_change_requests || [];
    if (reqs.length === 0) break;
    const tw = await routeTestChange(c, reqs);
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
      `${why}. Run EXACTLY these, in order:`,
      `  scoped unit:        ${c.util_test_cmd}`,
      c.it_cmd ? `  scoped integration: ${c.it_cmd}` : '',
      `  lint:               ${c.fmt_cmd}`,
      'Pipe verbose output through `tail`. Report facts only; do not edit or fix anything. If',
      'something fails, put the first real failure (the assertion and its message, not the summary',
      'line) in first_failure.',
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
      'scan is genuinely clean. Report new_violations as the count attributable to the changes in this',
      'worktree (`git diff main...HEAD` shows them). Do not edit anything.',
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
      'already proven the suites green; re-running them wastes time and tells you nothing new. Review',
      'by reading.',
      '',
      'Review for, in priority order:',
      '  1. Does each change actually fix the finding it claims to, including edge cases the tests do',
      '     not cover?',
      '  2. Was any test weakened, deleted, or made tautological to reach green?',
      '  3. Does the change break an adjacent code path that shares the modified function?',
      '  4. Zig 0.16 correctness: `io` on every blocking call, std.Io not std.fs, buffered writers',
      '     flushed, `writerStreaming` not `writer` for stdout/stderr.',
      '  5. Memory: allocations freed, arena vs testing.allocator, no pointer into a static libc',
      '     buffer held across another libc call.',
      '  6. Is the change minimal? Refactoring beyond the fix is a finding here, not a virtue.',
      '',
      'Do NOT report style preferences, naming opinions, or speculative refactors. Report only what is',
      'wrong or would break. Return APPROVED when there is nothing left that is wrong.',
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
  const promptFile = `${CODEX_TMP}/${c.key.replace('/', '-')}-diff-review.md`;
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
      `You are reviewing fixes to \`${c.util}\` in the vibeutils repository (a Zig 0.16 implementation`,
      'of GNU coreutils).',
      '',
      'Inspect the change yourself: run `git diff main...HEAD` and `git diff` and read the surrounding',
      'code. Do not rely on any summary.',
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
      'Do NOT report style preferences, naming opinions, or speculative refactors. Report only what is',
      'wrong or would break.',
      '',
      'Output ONLY a JSON array, nothing else:',
      '[{"id":"X1","severity":"CRITICAL|IMPORTANT|SUGGESTION","kind":"bug","scope":"local",',
      '  "location":"file:line","claim":"what is wrong","evidence":"the code you cite","fix":"..."}]',
      'Return [] if the change is clean.',
      '--- END review request ---',
    ].join('\n'),
    { label: `codex-review:${c.util}`, phase: 'Green', model: 'sonnet', schema: CODEX_FINDINGS_SCHEMA },
  );
}

async function codexRebuttal(c, disputed) {
  const promptFile = `${CODEX_TMP}/${c.key.replace('/', '-')}-rebuttal.md`;
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
      'Run EXACTLY these and report each result. This is the gate the commit depends on, so run all of',
      'them even if an early one fails:',
      `  macOS full unit:        ${c.test_cmd}`,
      `  macOS full privileged:  ${c.privileged_test_cmd}`,
      `  macOS FULL integration: ${c.full_it_cmd}`,
      `  Linux build:            ${c.linux_build_cmd}`,
      `  Linux full unit:        ${c.linux_test_cmd}`,
      `  Linux integration:      ${c.linux_it_cmd}`,
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
  const refactors = findingsByKind(audit, ['dead_code', 'duplication']);
  return [
    `## BUGS TO FIX (${bugs.length}) — each has a failing test waiting for it`,
    renderFindings(bugs),
    '',
    `## CLEANUPS TO APPLY (${refactors.length}) — dead code and approved duplication; behavior-preserving, characterization tests stay green`,
    renderFindings(refactors),
    '',
    'The tests are already written and committed. Make them pass by changing the implementation.',
    'A refactor that changes any observable behavior is a failure, not a fix.',
  ].join('\n');
}

async function greenPhase(c, audit) {
  const body = renderForImplementer(audit);
  const impl = await runImplementer(c, body, `implement:${c.util}`);
  let testsChanged = impl.tests_changed;

  let g = await gate(c, 'The implementer has applied the fixes');
  for (let round = 1; round < GATE_FIX_MAX && g; round += 1) {
    if (g.unit_pass && g.integration_pass && g.lint_clean) break;
    log(`${c.util}: gate round ${round} failed — ${g.first_failure || 'see notes'}`);
    const fix = await runImplementer(
      c,
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
      [body, '', '## CODE REVIEW REQUIRES CHANGES', blocking.map((i) => `- [${i.severity}] ${i.location}: ${i.claim}`).join('\n')].join('\n'),
      `implement:${c.util}:review${round - 1}`,
    );
    testsChanged = testsChanged || fix.tests_changed;
    g = await gate(c, `Re-verifying after review round ${round - 1}`);
    review = await codeReview(c, round);
  }

  const cx = await codexDiffReview(c);
  const codexOk = !!(cx && cx.invoked_ok);
  let deadlocks = [];
  let open = codexOk ? (cx.findings || []).filter((f) => f.severity !== 'SUGGESTION') : [];
  if (!codexOk) log(`${c.util}: codex diff review did not run — surfacing, not silently skipping.`);

  for (let round = 1; round <= CODEX_ROUNDS_MAX && open.length > 0; round += 1) {
    const resp = await runImplementer(
      c,
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
    const stance = new Map(((reb && reb.verdicts) || []).map((v) => [String(v.id), v]));
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
    const ruling = await judge(c, 'the fix diff', deadlocks.map((d) => ({ ...d, counter: d.dispute })), 1);
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
  if (Array.isArray(a.utils) && a.utils.length > 0) {
    return a.utils.map((n) => (String(n).startsWith('common/') ? module_(String(n).slice(7)) : utility(String(n), OVERRIDES[n])));
  }
  const id = String(a.wave || '');
  const base = id.replace(/b$/, '');
  const shared = SHARED_WAVES.find((w) => w.id === base);
  if (shared) return shared.modules.map(module_);
  const uw = UTIL_WAVES.find((w) => w.id === base);
  if (uw) return uw.utils.map((n) => utility(n, OVERRIDES[n]));
  const ids = SHARED_WAVES.map((w) => w.id).concat(UTIL_WAVES.map((w) => w.id));
  throw new Error(`fix-it-all: unknown wave "${a.wave}". Known: ${ids.join(', ')} (append "b" for a re-sweep), or pass args.utils`);
}

const units = resolveUnits();
const cfgs = units.map(cfgFor);
log(`fix-it-all: phase=${phaseArg} wave=${a.wave || '(explicit)'} units=${units.map((u) => u.key).join(', ')}`);

if (phaseArg === 'audit') {
  phase('Audit tests');
  const out = (await parallel(cfgs.map((c) => () => auditUnit(c)))).filter(Boolean);
  for (const r of out) {
    const n = (r.tests.agreed || []).length + (r.code.agreed || []).length;
    const d = (r.tests.deferred || []).length + (r.code.deferred || []).length;
    const conv = r.tests.converged && r.code.converged;
    log(`${r.util}: ${n} actionable, ${d} deferred, ${r.tests.rounds}+${r.code.rounds} rounds${conv ? '' : ' — NOT CONVERGED'}.`);
  }
  return { phase: 'audit', wave: a.wave, units: units.map((u) => u.key), audits: out };
}

const audits = a.audits || [];
if (audits.length === 0) {
  throw new Error(`fix-it-all: phase=${phaseArg} needs args.audits (the object the audit phase returned)`);
}
const byUtil = new Map(audits.map((x) => [x.util, x]));

function runPhase(fn, label, readyKey) {
  return parallel(
    cfgs.map((c) => () => {
      const audit = byUtil.get(c.util);
      if (!audit) {
        log(`${c.util}: no audit in args.audits — skipping.`);
        return Promise.resolve(null);
      }
      return fn(c, audit);
    }),
  ).then((out) => {
    const res = out.filter(Boolean);
    const ready = res.filter((r) => r[readyKey]).map((r) => r.util);
    const blocked = res.filter((r) => !r[readyKey]).map((r) => r.util);
    log(`fix-it-all ${label} done. ready: ${ready.join(', ') || 'none'}${blocked.length ? `; NOT ready: ${blocked.join(', ')}` : ''}`);
    return res;
  });
}

if (phaseArg === 'red') {
  phase('Red');
  return { phase: 'red', wave: a.wave, results: await runPhase(redPhase, 'red', 'ready_to_commit_red') };
}

if (phaseArg === 'green') {
  phase('Green');
  return { phase: 'green', wave: a.wave, results: await runPhase(greenPhase, 'green', 'ready_to_commit_green') };
}

throw new Error(`fix-it-all: unknown phase "${phaseArg}" (expected audit, red, or green)`);
