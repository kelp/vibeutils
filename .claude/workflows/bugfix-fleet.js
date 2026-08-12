export const meta = {
  name: 'bugfix-fleet',
  description:
    'Fan several vibeutils bug fixes through the tdd-bugfix red-green pipeline concurrently, one dedicated git worktree each, then subject every green diff to an independent Codex review with bounded rebuttal rounds and a Fable judge for deadlocks. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Running 2+ independent bug fixes in parallel worktrees. Dispatch phase:"red" with a wave of issue ids, commit each worktree\'s tests, then phase:"green" with the briefings the red run returned.',
  phases: [
    { title: 'Red fan-out', detail: 'one tdd-bugfix red pipeline per issue, concurrent (child workflows)' },
    { title: 'Green fan-out', detail: 'one tdd-bugfix green pipeline per issue, concurrent (child workflows)' },
    { title: 'Independent review', detail: 'headless `codex exec` review of each worktree diff, or a distinct Claude reviewer agent where codex is absent' },
    { title: 'Adjudicate', detail: 'implementer responds, bounded rebuttal rounds, Fable judge on deadlock' },
  ],
};

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
const phaseArg = a.phase || 'red';

// A finding must survive this many codex rounds still disputed before the
// Fable judge is called. Two rounds gives Codex one chance to withdraw after
// hearing the implementer's reasoning, which is where most noise dies.
const CODEX_ROUNDS_MAX = 2;

// ---------------------------------------------------------------------------
// Host detection
//
// This fleet used to hardcode one developer's macOS layout: worktrees under
// /Users/tcole/code, and a Linux VM behind `orb -m ubuntu`. Neither exists in
// a Linux agent container, where the fleet is now expected to run too. Both
// are derived from the host instead, with the defaults chosen so the macOS dev
// box resolves to exactly what was hardcoded before.
//
// The `typeof process` guards keep this working if the workflow runtime ever
// evaluates without a Node global. When the platform is genuinely undetectable
// we fall back to the historical macOS defaults and say so loudly: silently
// dropping the Linux leg is the failure mode this change exists to prevent.
// ---------------------------------------------------------------------------
const HAVE_PROCESS = typeof process !== 'undefined' && !!process.platform;
const ENV = (HAVE_PROCESS && process.env) || {};
const IS_DARWIN = HAVE_PROCESS ? process.platform === 'darwin' : true;
if (!HAVE_PROCESS) {
  log('bugfix-fleet: WARNING — cannot detect the host platform; assuming the macOS dev-box defaults.');
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

// The checkout this fleet was dispatched from. Every worktree is its sibling,
// and it is the one tree no worktree agent may touch.
const MAIN_CHECKOUT =
  ENV.VIBEUTILS_MAIN_CHECKOUT ||
  (HAVE_PROCESS && process.cwd ? process.cwd() : '') ||
  '/Users/tcole/code/vibeutils';

// Parent of the checkout: on the dev box that is /Users/tcole/code, byte for
// byte what this used to be.
const WT_ROOT = ENV.VIBEUTILS_WT_ROOT || MAIN_CHECKOUT.replace(/\/+[^/]+\/*$/, '') || '/';

// How to reach the SECONDARY platform: `orb -m ubuntu` on macOS, nothing at
// all in a Linux container where the second platform is CI's business. An
// empty string is a meaningful value, so only an undefined override falls
// through to the default.
const LINUX_PREFIX =
  ENV.VIBEUTILS_LINUX_PREFIX !== undefined
    ? ENV.VIBEUTILS_LINUX_PREFIX.trim()
    : IS_DARWIN
      ? 'orb -m ubuntu'
      : '';
const SECONDARY_AVAILABLE = LINUX_PREFIX.length > 0;

log(
  `bugfix-fleet: host=${HAVE_PROCESS ? process.platform : 'unknown'} main_checkout=${MAIN_CHECKOUT} ` +
    `wt_root=${WT_ROOT} secondary=${LINUX_PREFIX || 'NONE (deferred to CI)'}`,
);

// ---------------------------------------------------------------------------
// Shared per-issue configuration
//
// Every field here is interpolated into the child pipeline's prompts. The
// issue analyses are distilled inline rather than pointed at, so that no agent
// spends a turn re-running `gh issue view` (see the fleet-efficiency rules).
// ---------------------------------------------------------------------------
const COMMON = {
  linux_prefix: LINUX_PREFIX,
  main_checkout: MAIN_CHECKOUT,
  test_cmd: 'zig build test',
  privileged_test_cmd: 'just test-privileged',
  fmt_cmd: 'zig build fmt-check',
  // Never `bash tests/integration.sh`. Only the wrapper drops from uid 0 to an
  // unprivileged user, and as root roughly two dozen permission-denied tests
  // across cat/chmod/chown/grep/ls/rm/stat fail for reasons that have nothing
  // to do with the fix under test.
  full_it_cmd: 'scripts/run-integration.sh',
};

const ISSUES = {
  99: {
    issue: 99,
    utility: 'cp',
    workdir: `${WT_ROOT}/vibeutils-wt-99`,
    impl_files: ['src/common/file_ops.zig'],
    test_files: ['src/cp.zig', 'tests/utilities/cp_test.sh'],
    bug_summary:
      'setPermissions in src/common/file_ops.zig:66-68 classifies EVERY fchmod failure as unexpected: ' +
      '`const err = std.posix.unexpectedErrno(std.c.errno(fchmod_result));`. std.posix.unexpectedErrno is ' +
      'for errno values the caller did not anticipate — in Debug and ReleaseSafe it prints the errno and ' +
      'dumps a stack trace before returning error.Unexpected. But EPERM from fchmod is the ordinary ' +
      '"you do not own this file" case, and src/cp.zig:5120 ("issue 81 U13 (error path)") deliberately ' +
      'provokes it using /dev/null as a destination an unprivileged process can write but not chmod. ' +
      'So every `zig build test` run on Linux prints a stack trace containing the literal string ' +
      '"failed command:", which makes anything grepping test output for failures report a false positive. ' +
      'The suite still exits 0 — this is purely diagnostic-channel noise, but it has already cost real ' +
      'debugging time twice.',
    expected_behavior:
      'Handle the expected errnos explicitly and reserve unexpectedErrno for the rest:\n' +
      '  const err = switch (std.c.errno(fchmod_result)) {\n' +
      '      .PERM => error.AccessDenied,\n' +
      '      .ROFS => error.ReadOnlyFileSystem,\n' +
      '      else => |e| std.posix.unexpectedErrno(e),\n' +
      '  };\n' +
      'The downstream branches already map the error to a warning on macOS and to ExitCode.general_error ' +
      'on Linux, so ONLY the classification changes. No observable behavior — exit codes, stdout, the ' +
      'user-facing error text — may move. After the fix, ' +
      '`orb -m ubuntu zig build test 2>&1 | grep -c "unexpected errno"` goes from 1 to 0 while the suite ' +
      'still exits 0.',
    behaviors: [
      'DIAGNOSTIC CHANNEL (this is the actual bug): a Linux `zig build test` run emits NOTHING matching ' +
        '"unexpected errno" and nothing matching "failed command:" from this code path. Nothing in the ' +
        'repo currently observes stderr here, so this assertion has to be built, not just extended — ' +
        'that is the whole point of the fix and the test must fail before it.',
      'EPERM from fchmod maps to error.AccessDenied, not error.Unexpected.',
      'EROFS from fchmod maps to error.ReadOnlyFileSystem, not error.Unexpected.',
      'An errno that is genuinely unanticipated still routes through std.posix.unexpectedErrno.',
      'REGRESSION GUARD: src/cp.zig:5120 keeps passing unchanged — cp -p still reports ' +
        'ExitCode.general_error when the final chmod fails on Linux, and still degrades to a warning ' +
        'with success on macOS.',
    ],
    gnu_pin_cmds: [
      'sh -c \'cp --version | head -1\'',
      'sh -c \'cd /tmp && printf hi > src.txt && cp -p src.txt /dev/null; echo "exit=$?"\'',
    ],
    notes:
      'This is a shared-library change: src/cp.zig and src/common/file_ops.zig are the ONLY users of ' +
      'setPermissions, so cp is the blast radius, but the full suite is still the gate. The failure mode ' +
      'lives entirely in what gets written to stderr, so a test that only checks an exit code cannot ' +
      'catch it.',
  },

  103: {
    issue: 103,
    utility: 'ls',
    workdir: `${WT_ROOT}/vibeutils-wt-103`,
    impl_files: ['src/ls/main.zig'],
    test_files: ['src/ls/main.zig', 'tests/utilities/ls_test.sh'],
    bug_summary:
      'ls mishandles non-directory operands in two ways, both diverging from GNU and BSD.\n' +
      'Bug A — operand printed as basename: listSingleFileEntry (src/ls/main.zig:755) builds the entry ' +
      'with `.name = std.fs.path.basename(path)`, so `ls t/new.txt` prints `new.txt` and `ls -l t/new.txt` ' +
      'ends in `new.txt`. GNU/BSD echo the operand exactly as written. This broke a real ' +
      '`ls dir/*.jsonl | while read` pipeline. listDirectoryItself (src/ls/main.zig:786) already does the ' +
      'right thing with `.name = path` for the -d case.\n' +
      'Bug B — operand list never sorted: lsMain_listOperands (src/ls/main.zig:504-530) iterates `paths` ' +
      'in argv order and prints each file operand immediately, with no collect-then-sort step, so -t, -S, ' +
      '-r and the default name sort are all ignored for operands. Directory CONTENTS sort correctly; the ' +
      'sorter in src/ls/sorter.zig is only reached via the directory-listing path. The second pass over ' +
      'directory operands (src/ls/main.zig:516-530) has the same gap, so `ls b_dir a_dir` emits the ' +
      '`b_dir:` section first when GNU emits `a_dir:` first.',
    expected_behavior:
      'Bug A: pass the operand through unmodified, exactly as listDirectoryItself does — `ls t/new.txt` ' +
      'prints `t/new.txt` in both short and -l format.\n' +
      'Bug B: in lsMain_listOperands, partition operands into files and directories, sort each group with ' +
      'the SAME comparator the directory listing uses (honoring -t/-S/-r/-U/--sort), then emit. Name sort ' +
      'is the POSIX-required default; argv order is what -U (and -f) are for, so -U must still preserve ' +
      'argv order. Note the single-operand fast path at src/ls/main.zig:481-487 routes one file operand ' +
      'through listDirectory, so Bug A reproduces with a single argument too.',
    behaviors: [
      '`ls subdir/file` prints `subdir/file`, not `file` — in short format.',
      '`ls -l subdir/file` ends the line with `subdir/file`, not `file`.',
      '`ls -1t f_old f_new` (distinct mtimes) prints f_new first.',
      '`ls -1S f_small f_big` (distinct sizes) prints f_big first.',
      '`ls -1 z_file a_file` prints a_file first (default name sort).',
      '`ls -1U z_file a_file` preserves argv order — guards against over-sorting.',
      '`ls -1r big small` reverses the name sort.',
      '`ls b_dir a_dir` emits the `a_dir:` header section before `b_dir:`.',
      'A --git case on a file operand inside a subdirectory still reports the right status.',
    ],
    gnu_pin_cmds: [
      'sh -c \'ls --version | head -1\'',
      'sh -c \'cd /tmp && rm -rf lsop && mkdir -p lsop/t && cd lsop && touch t/old.txt && sleep 1 && touch t/new.txt && printf aaaa > t/big.txt && printf a > t/small.txt && echo "--- ls t/new.txt ---" && ls t/new.txt && echo "--- ls -l t/new.txt ---" && ls -l t/new.txt && echo "--- ls -1t ---" && ls -1t t/old.txt t/new.txt && echo "--- ls -1S ---" && ls -1S t/small.txt t/big.txt && echo "--- ls -1 ---" && ls -1 t/small.txt t/big.txt && echo "--- ls -1U ---" && ls -1U t/small.txt t/big.txt && echo "--- ls -1r ---" && ls -1r t/big.txt t/small.txt\'',
      'sh -c \'cd /tmp && rm -rf lsdir && mkdir -p lsdir/a_dir lsdir/b_dir && touch lsdir/a_dir/x lsdir/b_dir/y && cd lsdir && ls b_dir a_dir\'',
    ],
    notes:
      'entry.name is also fed to git_context.?.getFileStatus at src/ls/main.zig:763, which presumably ' +
      'wants a repo-relative path — so that call may need the basename (or a properly repo-relative ' +
      'path) even after .name is corrected. Verify --git on a file operand in a subdirectory reports the ' +
      'right status; do not silently regress it.\n' +
      'CONFLICT RULE: issue #104 also lands in src/ls/ and also appends to tests/utilities/ls_test.sh. ' +
      'Put every new integration case at END OF FILE inside a fenced block delimited by ' +
      '`# >>> issue #103` and `# <<< issue #103`, and never modify an existing line of ls_test.sh. ' +
      'Assert only the NAME portion of -l output (anchor to end of line); never assert a whole -l line, ' +
      'because #104 is concurrently changing how the timestamp field renders.',
  },

  104: {
    issue: 104,
    utility: 'ls',
    workdir: `${WT_ROOT}/vibeutils-wt-104`,
    impl_files: ['src/ls/formatter.zig'],
    test_files: ['src/ls/formatter.zig', 'tests/utilities/ls_test.sh'],
    bug_summary:
      'ls -l renders mtime/atime/ctime in UTC instead of the local timezone, so every timestamp is wrong ' +
      'by the UTC offset. src/ls/formatter.zig decodes raw epoch seconds with ' +
      '`std.time.epoch.EpochSeconds`, which is UTC-only and has no notion of a local offset, and no ' +
      'offset is added before or after:\n' +
      '  const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };\n' +
      '  const year_day = epoch_seconds.getEpochDay().calculateYearDay();\n' +
      '  const day_seconds = epoch_seconds.getDaySeconds();\n' +
      'FOUR call sites do this with the same omission: src/ls/formatter.zig:254, :316, :339 and :360. ' +
      'Setting TZ explicitly changes nothing, so the timezone is never consulted at all. A file touched ' +
      'in the evening can display tomorrow\'s date, which also makes the "within 6 months -> show time, ' +
      'else show year" heuristic fire on the wrong side of the boundary near it.',
    expected_behavior:
      '`ls -l` prints local wall time, matching /bin/ls, and honors TZ.\n' +
      'MANDATED REUSE — do not invent anything here. The repo already has what this needs:\n' +
      '  - src/common/time.zig exports the libc bindings: `c_tm`, `localtime_r`, `gmtime_r`, `strftime`.\n' +
      '  - src/stat.zig:495 `formatTimestamp` is a WORKING reference implementation of exactly this ' +
      'conversion: it does `const time_val: c.time_t = @intCast(sec); var tm: time.c_tm = undefined; ' +
      'if (time.localtime_r(&time_val, &tm) == null) return error.TimeConversion;` and then reads ' +
      'tm_year/tm_mon/tm_mday/tm_hour/tm_min/tm_sec (and tm_gmtoff for the offset). Copy that shape.\n' +
      'Zig\'s stdlib has no timezone database, so the conversion MUST go through libc localtime_r. Do NOT ' +
      'capture a fixed offset once at startup and add it: that is still wrong for files stamped on the ' +
      'other side of a DST transition. The offset has to be resolved PER TIMESTAMP.',
    behaviors: [
      'With TZ=UTC, `ls -l` on a known epoch stamp prints the UTC wall time — this is current behavior ' +
        'and must keep passing.',
      'With TZ=America/Los_Angeles, the same stamp prints a wall time 7 or 8 hours earlier depending on ' +
        'DST. THIS is the assertion that must go RED first.',
      'A timestamp on each side of a DST transition renders with the correct respective offset, proving ' +
        'the offset is resolved per timestamp and not captured once per run.',
      'A timestamp whose local and UTC calendar DATES differ renders the local date — pins the date, not ' +
        'just the clock time.',
      'The recent-vs-old heuristic ("within 6 months -> show time, else show year") is evaluated against ' +
        'local time, so a stamp near the boundary does not flip sides.',
      'REGRESSION GUARD: --time-style / --full-time output still renders correctly, since everything that ' +
        'formats a time goes through these same four sites.',
    ],
    gnu_pin_cmds: [
      'sh -c \'ls --version | head -1\'',
      'sh -c \'cd /tmp && rm -rf tzls && mkdir tzls && cd tzls && touch -d "2026-07-30 03:44:48 UTC" f && for z in UTC America/Los_Angeles America/New_York Asia/Kolkata; do echo "--- $z ---"; TZ=$z ls -l f; done\'',
      'sh -c \'cd /tmp/tzls && touch -d "2026-01-15 12:00:00 UTC" winter && touch -d "2026-07-15 12:00:00 UTC" summer && echo "--- PST/PDT both sides of DST ---" && TZ=America/Los_Angeles ls -l --full-time winter summer\'',
      'sh -c \'cd /tmp/tzls && touch -d "2026-07-30 03:44:48 UTC" crossdate && echo "--- local date differs from UTC date ---" && TZ=America/Los_Angeles ls -l --full-time crossdate && TZ=UTC ls -l --full-time crossdate\'',
    ],
    notes:
      'TEST PLACEMENT IS CONSTRAINED. Environment variables are not settable in-process under Zig 0.16 ' +
      '(std.posix.setenv/unsetenv C-extern workarounds were deliberately removed from this repo), so a ' +
      'TZ-varying assertion CANNOT be a unit test. Every TZ-dependent assertion must be an INTEGRATION ' +
      'test in tests/utilities/ls_test.sh using the `env TZ=...` idiom already established at ' +
      'tests/utilities/date_test.sh:153 (`env TZ=America/New_York "$binary" ...`). Pin TZ explicitly ' +
      'rather than relying on the runner\'s ambient zone. Unit tests in src/ls/formatter.zig may still ' +
      'cover the pure conversion helper.\n' +
      'The existing unit tests around src/ls/formatter.zig:1018 and :1056 assert against timestamps their ' +
      'comments describe as UTC, so they currently pass while ENCODING the bug. Most are loose (they ' +
      'check "contains 2024", "2 colons") and will survive, but any that pin an exact wall time must ' +
      'change. The implementer MAY NOT edit tests: if a test is wrong, return outcome "needs_test_change" ' +
      'and route it to the test-writer, which adjudicates judge-first.\n' +
      'Check docs/specs/ls-flags.md and the --time-style behavior at the same time.\n' +
      'CONFLICT RULE: issue #103 also lands in src/ls/ and also appends to tests/utilities/ls_test.sh. ' +
      'Put every new integration case at END OF FILE inside a fenced block delimited by ' +
      '`# >>> issue #104` and `# <<< issue #104`, and never modify an existing line of ls_test.sh. ' +
      'You own src/ls/formatter.zig only; do not touch src/ls/main.zig.',
  },

  105: {
    issue: 105,
    utility: 'stat',
    workdir: `${WT_ROOT}/vibeutils-wt-105`,
    impl_files: ['src/stat.zig'],
    test_files: ['src/stat.zig', 'tests/utilities/stat_test.sh'],
    bug_summary:
      '%N always wraps the file name in single quotes. expandFormatDirective_quotedName at ' +
      'src/stat.zig:748 emits `\'{s}\'` unconditionally. GNU uses gnulib\'s quotearg in ' +
      'shell_escape_quoting_style, which picks the quote character based on the content, switching to ' +
      'double quotes when the name itself contains a single quote. For a file named `it\'s`, GNU prints ' +
      '"it\'s" while we print \'it\'s\' — three shell tokens, not one. Every other case matches exactly: ' +
      'plain, embedded space, and the symlink form `\'lnk\' -> \'plain\'` are all byte-identical to GNU.',
    expected_behavior:
      'Match GNU shell_escape_quoting_style for %N. CAUTION: the rule is NOT the one-liner the issue ' +
      'suggests ("switch to double quotes when the name contains a single quote"). That is only correct ' +
      'for the simplest case and produces WRONG output for a name like `it\'s and $var`. The actual rule ' +
      'was pinned against GNU coreutils 9.5 on the Linux VM and is:\n' +
      "  1. No single quote in the name        -> single quotes, content verbatim.\n" +
      "       plain          -> 'plain'\n" +
      "       with space     -> 'with space'\n" +
      "       dq\"name        -> 'dq\"name'        (a double quote alone does NOT change anything)\n" +
      "       back\\slash     -> 'back\\slash'\n" +
      "       dollar$var     -> 'dollar$var'\n" +
      '  2. Single quote present AND none of  "  \\  $  `  present -> DOUBLE quotes.\n' +
      "       it's           -> \"it's\"\n" +
      "       it's space     -> \"it's space\"\n" +
      '  3. Single quote present AND at least one of  "  \\  $  `  present -> single quotes with the\n' +
      "     classic '\\'' splice (close, escaped quote, reopen).\n" +
      "       it's and $var  -> 'it'\\''s and $var'\n" +
      "       it's\"dq        -> 'it'\\''s\"dq'\n" +
      "       it's back\\slash-> 'it'\\''s back\\slash'\n" +
      "       it's `tick`    -> 'it'\\''s `tick`'\n" +
      '  4. Non-printable characters use ANSI-C splicing rather than being emitted raw.\n' +
      "       nl<newline>name -> 'nl'$'\\n''name'\n" +
      'Rule 2 vs rule 3 is the crux: the choice of double quotes is only available when nothing inside ' +
      'would itself need escaping within double quotes. Implement rules 1-3 as the core fix. Rule 4 ' +
      '(non-printables) is a separate concern — pin what we currently do for it, and if matching GNU ' +
      'there is a larger change, say so explicitly and scope it out rather than half-implementing it.\n' +
      'The whole point of %N over %n is that the output is safe to paste into a shell, so the result must ' +
      'be exactly one shell token.\n' +
      'The default record\'s `File:` line is NOT affected: GNU leaves it unquoted, including for names ' +
      'with spaces, and we already match it byte for byte. Do not change it.',
    behaviors: [
      "RULE 2 (the reported bug): stat -c %N on `it's` emits \"it's\" with DOUBLE quotes.",
      "RULE 2: stat -c %N on `it's space` emits \"it's space\".",
      "RULE 3: stat -c %N on `it's and $var` emits 'it'\\''s and $var' — single quotes with the splice, " +
        'NOT double quotes. This is the case the issue\'s suggested fix would get wrong.',
      "RULE 3: stat -c %N on `it's\"dq` (both quote kinds) emits 'it'\\''s\"dq'.",
      "RULE 3: stat -c %N on a name with a single quote and a backslash, and one with a single quote and " +
        'a backtick, both take the splice form.',
      "RULE 1: a name containing only a double quote (dq\"name) still emits single quotes — unchanged.",
      'RULE 1: plain and embedded-space names still emit single quotes — unchanged.',
      'The symlink form (%N on an unfollowed symlink) applies the SAME rule independently to the link ' +
        'name and to the target.',
      '%N inside a longer -c/--printf format string quotes identically to a bare -c %N.',
      "REGRESSION GUARD: the default record's `File:` line stays unquoted for every one of those names.",
    ],
    // Already run and verified against GNU coreutils 9.5 on the VM; the table
    // in expected_behavior is their output. Re-run them to confirm rather than
    // to discover, and extend if a case is missing. Write the script to a file
    // and run that — do not try to nest this quoting inside another shell.
    gnu_pin_cmds: [
      'bash -c \'stat --version | head -1\'',
      'bash -c \'cd /tmp && rm -rf statq && mkdir statq && cd statq && ' +
        'names=("plain" "with space" "it\'"\'"\'s" "it\'"\'"\'s space" "it\'"\'"\'s and \\$var" ' +
        '"it\'"\'"\'s\\"dq" "dq\\"name" "back\\\\slash" "dollar\\$var"); ' +
        'for f in "${names[@]}"; do touch -- "$f"; printf -- "in=%q -> " "$f"; stat -c %N "$f"; done\'',
      'bash -c \'cd /tmp/statq && ln -s plain lnk && echo "--- symlink ---" && stat -c %N lnk\'',
      'bash -c \'cd /tmp/statq && echo "--- %N inside a longer format ---" && stat -c "name=%N size=%s" "it\'"\'"\'s"\'',
      'bash -c \'cd /tmp/statq && for f in "plain" "with space" "it\'"\'"\'s"; do echo "--- default record ---"; stat "$f" | head -1; done\'',
    ],
    notes:
      'Scope is narrow: only names containing a single quote are wrong, and only via %N (including %N ' +
      'inside a -c/--printf format). The existing unit test at src/stat.zig:3434 ' +
      '("stat -c format: %N regular file is quoted") pins only the always-single-quote shape for a plain ' +
      'name, so it does not catch this and must keep passing.\n' +
      'The natural test is differential against /usr/bin/stat -c %N over a set of awkward names, in the ' +
      'style of the existing _test_stat_default_record_parity in tests/utilities/stat_test.sh. That ' +
      'helper only exists on Linux where GNU stat is present — follow its existing guard for skipping on ' +
      'macOS.',
  },
};

// ---------------------------------------------------------------------------
// Schemas for the review/adjudication layer
// ---------------------------------------------------------------------------
const CODEX_FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['invoked_ok', 'findings', 'raw_excerpt'],
  properties: {
    invoked_ok: {
      type: 'boolean',
      description: 'the codex CLI ran and produced a parseable review; false if it errored or stalled',
    },
    raw_excerpt: { type: 'string', description: "short verbatim excerpt of codex's output, for the record" },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'severity', 'location', 'claim', 'evidence'],
        properties: {
          id: { type: 'string', description: 'stable short id, e.g. C1, C2' },
          severity: { type: 'string', enum: ['CRITICAL', 'IMPORTANT', 'SUGGESTION'] },
          location: { type: 'string', description: 'file:line' },
          claim: { type: 'string', description: 'what is allegedly wrong' },
          evidence: { type: 'string', description: 'the code or behavior codex cites' },
        },
      },
    },
  },
};

const RESOLUTION_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['resolutions', 'summary'],
  properties: {
    summary: { type: 'string' },
    resolutions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'action', 'note'],
        properties: {
          id: { type: 'string' },
          action: {
            type: 'string',
            enum: ['fixed', 'disputed', 'test_change'],
            description:
              'fixed = implementation corrected; disputed = the finding is wrong, note explains why; ' +
              'test_change = correct but needs a TEST edit, which you may not make yourself',
          },
          note: { type: 'string' },
        },
      },
    },
  },
};

const REBUTTAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['invoked_ok', 'verdicts', 'raw_excerpt'],
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

const JUDGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts', 'summary'],
  properties: {
    summary: { type: 'string' },
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'verdict', 'directive', 'rationale'],
        properties: {
          id: { type: 'string' },
          verdict: {
            type: 'string',
            enum: ['UPHOLD_FINDING', 'REJECT_FINDING', 'TEST_CHANGE_REQUIRED'],
          },
          directive: {
            type: 'string',
            description: 'the concrete change to make, or "none" when the finding is rejected',
          },
          rationale: { type: 'string', description: 'grounded in code you actually read, citing file:line' },
        },
      },
    },
  },
};

const POSTGATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean', 'full_unit_pass', 'summary'],
  properties: {
    unit_pass: { type: 'boolean' },
    integration_pass: { type: 'boolean' },
    lint_clean: { type: 'boolean' },
    full_unit_pass: { type: 'boolean', description: 'macOS full `zig build test`' },
    summary: { type: 'string' },
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
// Every command is made self-contained with its own `cd`, and every file path
// absolute, because this harness resets the shell cwd to the project root
// between Bash calls and resolves bare paths there. Leaving either relative is
// what sent an earlier run's work into the main checkout.
function cfgFor(issue) {
  const c = ISSUES[issue];
  if (!c) throw new Error(`bugfix-fleet: no configuration for issue #${issue}`);
  const at = (p) => `${c.workdir}/${p}`;
  const inWt = (cmd) => `cd ${c.workdir} && ${cmd}`;
  return {
    ...COMMON,
    ...c,
    // Forward the namespace so a child tdd-bugfix run resolves its agents the
    // same way this run did; without it the child re-defaults to the plugin
    // and dies on a host where the plugin is not installed.
    agent_ns: AGENT_NS,
    impl_files: c.impl_files.map(at),
    test_files: c.test_files.map(at),
    util_test_cmd: inWt(`zig build test -Dtest-util=${c.utility}`),
    it_cmd: inWt(`scripts/run-integration.sh ${c.utility}`),
    test_cmd: inWt(COMMON.test_cmd),
    privileged_test_cmd: inWt(COMMON.privileged_test_cmd),
    fmt_cmd: inWt(COMMON.fmt_cmd),
    full_it_cmd: inWt(COMMON.full_it_cmd),
  };
}

// Byte-identical across every agent in an issue's chain, so the fleet shares
// prompt-cache prefixes instead of paying for a fresh preamble each dispatch.
function wtPreamble(c) {
  return [
    `WORKING DIRECTORY: ${c.workdir}`,
    'That path is a dedicated git worktree for this issue, NOT the main checkout. Other agents are',
    'working concurrently in sibling worktrees; staying inside yours is what keeps them isolated.',
    '',
    'READ THIS TWICE — it is the single easiest way to ruin this run:',
    'This harness RESETS the shell working directory to the repo root after EVERY Bash call. A bare',
    '`cd` does NOT carry over to your next command. So EVERY shell command you run must be',
    `self-contained and start with \`cd ${c.workdir} && \`.`,
    SECONDARY_AVAILABLE
      ? 'The VM launcher preserves that cwd inside the VM, so the same prefix covers both platforms.'
      : 'There is no secondary-platform launcher on this host, so every command runs natively.',
    'For Read/Edit/Write, always use ABSOLUTE paths beginning with the working directory above.',
    `Never read, edit, build, or run anything under the main checkout at ${MAIN_CHECKOUT} itself.`,
    '',
    `Issue: #${c.issue} (${c.utility})`,
  ].join('\n');
}

// ---------------------------------------------------------------------------
// Independent review layer
//
// The point of this stage is that a reviewer which did NOT write the fix looks
// at it. Codex is the preferred reviewer because it is a different model
// family entirely. It is simply absent in an agent container, and the old code
// turned that absence into `codex_ok: false`, which `ready` ANDed — so every
// issue reported not-ready forever with nothing wrong with it.
//
// The gate is not removed. When Codex is missing the review still happens, run
// by a Claude subagent under an agentType distinct from the implementer's so
// it is at least a different context with a different brief. Which reviewer
// ran is recorded and logged, because "reviewed by the fallback" and
// "reviewed by Codex" are not the same claim — and neither is ever allowed to
// mean "review skipped".
// ---------------------------------------------------------------------------

// Probed once per fleet run. The PROMISE is memoized, not the result: issues
// adjudicate concurrently, so caching only the resolved value would let every
// issue in the wave dispatch its own probe before the first one returned.
let codexProbe = null;
function codexAvailable() {
  if (codexProbe === null) codexProbe = probeCodex();
  return codexProbe;
}

async function probeCodex() {
  const probe = await agent(
    [
      '## YOUR TASK (probe only — one command, no edits)',
      'Run exactly: `command -v codex || echo NOT_FOUND`',
      'Report whether the codex CLI is installed on this host. Do not install anything, do not read any',
      'files, and do not do anything else.',
    ].join('\n'),
    {
      label: 'probe:codex',
      phase: 'Codex review',
      model: 'haiku',
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['available', 'detail'],
        properties: {
          available: { type: 'boolean', description: 'true iff `command -v codex` resolved to a path' },
          detail: { type: 'string', description: 'the resolved path, or the not-found output' },
        },
      },
    },
  );
  const available = !!(probe && probe.available);
  log(
    available
      ? `bugfix-fleet: REVIEWER = codex (${(probe && probe.detail) || 'found'}).`
      : 'bugfix-fleet: REVIEWER = Claude fallback subagent — codex is NOT installed on this host. ' +
          'The independent-review gate still applies; it is simply being run by a different reviewer.',
  );
  return available;
}

// The review brief itself, shared by both reviewers so they are held to the
// same standard and the same output shape.
function reviewRequestBody(c, green) {
  const spec = (green && green.briefing && green.briefing.gnu_behavior) || c.expected_behavior;
  return [
    `You are reviewing a bug fix in the vibeutils repository (a Zig implementation of GNU coreutils).`,
    `Issue #${c.issue}, utility \`${c.utility}\`.`,
    '',
    'Inspect the change yourself: run `git diff main...HEAD` and `git diff` and read the surrounding',
    'code. Do not rely on this summary alone.',
    '',
    `THE BUG THAT WAS FIXED:\n${c.bug_summary}`,
    '',
    `THE SPECIFICATION THE FIX MUST MEET (pinned reference behavior):\n${spec}`,
    '',
    'Review for, in priority order:',
    '  1. Correctness against that specification, including edge cases the tests may not cover.',
    '  2. Whether any test was weakened, deleted, or made tautological to get to green.',
    '  3. Breakage on adjacent code paths that share the changed function.',
    '  4. Zig 0.16 correctness: every blocking API takes an `io` parameter, std.fs moved to std.Io,',
    '     buffered writers must be flushed, `writerStreaming` not `writer` for stdout/stderr.',
    '  5. Memory: allocations freed, arena vs testing.allocator used appropriately.',
    '',
    'Do NOT report style preferences, naming opinions, or speculative refactors. Report only things',
    'that are wrong or would break.',
    '',
    'Output ONLY a JSON array, nothing else:',
    '[{"id":"C1","severity":"CRITICAL|IMPORTANT|SUGGESTION","location":"file:line",',
    '  "claim":"what is wrong","evidence":"the code or behavior you cite"}]',
    'Return [] if the change is clean.',
  ].join('\n');
}

function codexInstructions(promptFile) {
  return [
    'Invoke Codex as an INDEPENDENT reviewer. Run exactly:',
    `  codex exec < ${promptFile}`,
    'codex exec reads its instructions from stdin when no prompt argument is given, and is',
    'non-interactive. Pipe its output through `tail -120` so a long transcript does not flood you.',
    'If that invocation errors, run `codex exec --help` ONCE, adapt the flags minimally, and retry ONCE.',
    'If it still fails, set invoked_ok=false, put the error in raw_excerpt, and return an empty list —',
    'do NOT substitute your own review for Codex\'s. You are a runner, not the reviewer.',
    'Codex is asked for JSON but may wrap it in prose; extract the JSON array from its output. If it',
    'returns prose only, translate its stated findings faithfully into the schema without adding any of',
    'your own.',
  ].join('\n');
}

async function codexReview(c, green) {
  const promptFile = `/tmp/codex-review-${c.issue}.md`;
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Codex review runner)',
      `Write the review request below to ${promptFile}, then run Codex on it.`,
      '',
      codexInstructions(promptFile),
      '',
      `--- BEGIN review request to write to ${promptFile} ---`,
      reviewRequestBody(c, green),
      `--- END review request ---`,
    ].join('\n'),
    {
      label: `codex-review:${c.utility}#${c.issue}`,
      phase: 'Codex review',
      model: 'sonnet',
      schema: CODEX_FINDINGS_SCHEMA,
    },
  );
}

// Fallback reviewer for hosts without codex. Deliberately dispatched under
// `tdd-pipeline:code-reviewer`, NOT the implementer's agentType: a reviewer
// carrying the implementer's brief would just re-argue its own fix.
async function claudeFallbackReview(c, green) {
  const review = await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (independent reviewer — FALLBACK for an absent Codex)',
      'The Codex CLI is not installed on this host, so you are standing in as the independent reviewer.',
      'You did NOT write this fix and you must not defend it. Read the code and judge it on its merits;',
      'if it is clean, say so with an empty findings list — but do not wave anything through because it',
      'looks plausible. Your verdict is the review of record for this change and will be logged as',
      'having come from the fallback reviewer, not from Codex.',
      'You may NOT edit any file. Report findings only.',
      '',
      reviewRequestBody(c, green),
      '',
      'Return your findings in the required schema. Set invoked_ok=true when you completed the review',
      '(that is the "a review actually happened" flag, and for you it should be true unless you were',
      'unable to read the diff at all), and put a one-line note in raw_excerpt recording that this was',
      'the Claude fallback reviewer rather than Codex.',
    ].join('\n'),
    {
      label: `fallback-review:${c.utility}#${c.issue}`,
      phase: 'Codex review',
      model: 'opus',
      agentType: agentTypeFor('code-reviewer'),
      schema: CODEX_FINDINGS_SCHEMA,
    },
  );
  return review;
}

// Routes to whichever independent reviewer this host actually has.
async function independentReview(c, green) {
  const haveCodex = await codexAvailable();
  const review = haveCodex ? await codexReview(c, green) : await claudeFallbackReview(c, green);
  return { review, reviewer: haveCodex ? 'codex' : 'claude-fallback' };
}

async function codexRebuttal(c, disputed) {
  const promptFile = `/tmp/codex-rebuttal-${c.issue}.md`;
  const items = disputed
    .map(
      (d) =>
        `### Finding ${d.id} (${d.severity}) at ${d.location}\n` +
        `Your claim: ${d.claim}\n` +
        `Your evidence: ${d.evidence}\n` +
        `The implementer DISPUTES this and replies: ${d.dispute}`,
    )
    .join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (Codex rebuttal runner)',
      `Write the request below to ${promptFile}, then run Codex on it.`,
      '',
      codexInstructions(promptFile),
      '',
      `--- BEGIN request to write to ${promptFile} ---`,
      `Continuing your review of vibeutils issue #${c.issue} (${c.utility}).`,
      'The code has changed since your review. Re-read it: run `git diff main...HEAD` and `git diff`.',
      '',
      'For each finding below, the implementer disagreed with you. Consider their reasoning against the',
      'ACTUAL current code, then decide. Withdraw if they are right or if the code no longer has the',
      'problem. Reaffirm only if you have checked the current code and the problem is genuinely still',
      'there. Being talked out of a correct finding is as bad as holding a wrong one.',
      '',
      items,
      '',
      'Output ONLY a JSON array, nothing else:',
      '[{"id":"C1","stance":"WITHDRAWN|REAFFIRMED","reason":"grounded in the code you just read"}]',
      `--- END request ---`,
    ].join('\n'),
    {
      label: `codex-rebuttal:${c.utility}#${c.issue}`,
      phase: 'Adjudicate',
      model: 'sonnet',
      schema: REBUTTAL_SCHEMA,
    },
  );
}

// The rebuttal half of the fallback path: same bounded withdraw-or-reaffirm
// contract, same reviewer agentType, so the rounds logic below is identical
// whichever reviewer this host has.
function rebuttalItems(disputed) {
  return disputed
    .map(
      (d) =>
        `### Finding ${d.id} (${d.severity}) at ${d.location}\n` +
        `Your claim: ${d.claim}\n` +
        `Your evidence: ${d.evidence}\n` +
        `The implementer DISPUTES this and replies: ${d.dispute}`,
    )
    .join('\n\n');
}

async function claudeFallbackRebuttal(c, disputed) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (independent reviewer — rebuttal round, FALLBACK for an absent Codex)',
      `Continuing YOUR OWN review of vibeutils issue #${c.issue} (${c.utility}).`,
      'The code has changed since your review. Re-read it: run `git diff main...HEAD` and `git diff`.',
      '',
      'For each finding below, the implementer disagreed with you. Consider their reasoning against the',
      'ACTUAL current code, then decide. Withdraw if they are right or if the code no longer has the',
      'problem. Reaffirm only if you have checked the current code and the problem is genuinely still',
      'there. Being talked out of a correct finding is as bad as holding a wrong one.',
      'You may NOT edit any file.',
      '',
      rebuttalItems(disputed),
    ].join('\n'),
    {
      label: `fallback-rebuttal:${c.utility}#${c.issue}`,
      phase: 'Adjudicate',
      model: 'opus',
      agentType: agentTypeFor('code-reviewer'),
      schema: REBUTTAL_SCHEMA,
    },
  );
}

async function independentRebuttal(c, disputed) {
  return (await codexAvailable()) ? await codexRebuttal(c, disputed) : await claudeFallbackRebuttal(c, disputed);
}

async function respondToFindings(c, findings, roundLabel) {
  const items = findings
    .map(
      (f) =>
        `### ${f.id} (${f.severity}) at ${f.location}\n` +
        `Claim: ${f.claim}\nEvidence: ${f.evidence}`,
    )
    .join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (implementer — respond to an independent review)',
      'An INDEPENDENT reviewer — Codex where it is installed, otherwise a separate Claude reviewer',
      'agent that did not write this fix — reviewed your work. Treat it as a competent',
      'peer who cannot see your reasoning: it is often right, and sometimes confidently wrong.',
      '',
      `Implementation files you may edit: ${c.impl_files.join(', ')}`,
      `Test files you may NOT edit under any circumstances: ${c.test_files.join(', ')}`,
      '',
      'For each finding, choose exactly one action:',
      '  - "fixed": the finding is right. Correct the IMPLEMENTATION. Then run',
      `      ${c.util_test_cmd}`,
      `      ${c.it_cmd}`,
      '    and make sure they still pass.',
      '  - "disputed": the finding is wrong. Explain concretely why, citing the code. Do not dispute',
      '    merely because a change would be inconvenient.',
      '  - "test_change": the finding is right, but fixing it requires editing a TEST. You may not do',
      '    that. Describe precisely what the test should assert instead; it will be routed to the',
      '    test-writer, which decides whether the test is genuinely wrong.',
      '',
      'Do NOT weaken, delete, or narrow any test to resolve a finding. Do NOT commit.',
      '',
      `## FINDINGS (${roundLabel})`,
      items,
    ].join('\n'),
    {
      label: `respond:${c.utility}#${c.issue}:${roundLabel}`,
      phase: 'Adjudicate',
      model: 'opus',
      agentType: agentTypeFor('implementer'),
      schema: RESOLUTION_SCHEMA,
    },
  );
}

async function routeTestChange(c, items) {
  const body = items.map((t) => `### ${t.id}\nRequested: ${t.note}`).join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (test-writer — adjudicate requested test changes)',
      'The implementer says these test changes are needed to resolve review findings. You own the tests;',
      'it does not. Judge FIRST, edit second.',
      '',
      `Test files you own: ${c.test_files.join(', ')}`,
      `Implementation files you may NOT touch: ${c.impl_files.join(', ')}`,
      '',
      'For each request: if the test is genuinely wrong (it asserts the buggy behavior, or asserts',
      'something the specification does not require), fix it — but keep it TOOTHFUL: it must still fail',
      'if the bug returns. If the test is correct and the implementation is what needs to change, REFUSE',
      'and say so plainly; the implementer will fix the code instead.',
      '',
      `Specification for reference:\n${c.expected_behavior}`,
      '',
      'Do NOT commit.',
      '',
      '## REQUESTS',
      body,
    ].join('\n'),
    {
      label: `test-change:${c.utility}#${c.issue}`,
      phase: 'Adjudicate',
      model: 'opus',
      agentType: agentTypeFor('test-writer'),
      schema: RESOLUTION_SCHEMA,
    },
  );
}

async function fableJudge(c, deadlocks, green) {
  const spec = (green && green.briefing && green.briefing.gnu_behavior) || c.expected_behavior;
  const items = deadlocks
    .map(
      (d) =>
        `### ${d.id} (${d.severity}) at ${d.location}\n` +
        `CODEX CLAIMS: ${d.claim}\n` +
        `CODEX EVIDENCE: ${d.evidence}\n` +
        `IMPLEMENTER DISPUTES: ${d.dispute}\n` +
        `CODEX REAFFIRMED, saying: ${d.reaffirm}`,
    )
    .join('\n\n');
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (judge — break a deadlock)',
      'Two reviewers have disagreed twice and neither will move. You decide, and your decision is final.',
      '',
      'You must NOT arbitrate between the two written positions. Both may be wrong. Go read the actual',
      'code: run `git diff main...HEAD`, open the implementation and the tests, and read enough of the',
      'surrounding code to judge for yourself. You may run the scoped checks to settle a factual',
      `question (\`${c.util_test_cmd}\`, \`${c.it_cmd}\`). You may NOT edit any file.`,
      '',
      `THE SPECIFICATION THAT GOVERNS:\n${spec}`,
      '',
      'For each disputed finding return one verdict:',
      '  - UPHOLD_FINDING: the reviewer is right. `directive` states the concrete change to make.',
      '  - REJECT_FINDING: the implementer is right. `directive` is "none".',
      '  - TEST_CHANGE_REQUIRED: the real defect is in a test, not the implementation. `directive`',
      '    states what the test must assert instead.',
      'Every rationale must cite specific code you actually read (file:line). A rationale that only',
      'restates one side\'s argument is not acceptable.',
      '',
      '## DEADLOCKED FINDINGS',
      items,
    ].join('\n'),
    {
      label: `judge:${c.utility}#${c.issue}`,
      phase: 'Adjudicate',
      model: 'fable',
      schema: JUDGE_SCHEMA,
    },
  );
}

async function postGate(c, why) {
  return await agent(
    [
      wtPreamble(c),
      '',
      '## YOUR TASK (post-adjudication gate — run and report only)',
      `Code changed after the pipeline's final verify (${why}), so re-verify. Run EXACTLY:`,
      `  - scoped unit:        ${c.util_test_cmd}`,
      `  - scoped integration: ${c.it_cmd}`,
      `  - lint:               ${c.fmt_cmd}`,
      `  - macOS full unit:    ${c.test_cmd}`,
      'Pipe verbose output through `tail`. Report facts only; do not edit anything.',
    ].join('\n'),
    {
      label: `post-gate:${c.utility}#${c.issue}`,
      phase: 'Adjudicate',
      model: 'haiku',
      schema: POSTGATE_SCHEMA,
    },
  );
}

// One issue's full post-green adjudication. Bounded at every step.
async function adjudicate(c, green) {
  const { review, reviewer } = await independentReview(c, green);
  if (!review || !review.invoked_ok) {
    log(`#${c.issue}: ${reviewer} review did not run cleanly — surfacing, not silently skipping.`);
    return { codex_ok: false, reviewer, findings: [], deadlocks: [], verdicts: [], post_gate: null };
  }
  let open = (review.findings || []).filter((f) => f.severity !== 'SUGGESTION');
  const dropped = (review.findings || []).length - open.length;
  if (dropped > 0) log(`#${c.issue}: ${dropped} SUGGESTION-severity ${reviewer} finding(s) logged but not gated on.`);
  if (open.length === 0) {
    log(`#${c.issue}: ${reviewer} review clean.`);
    return { codex_ok: true, reviewer, findings: review.findings || [], deadlocks: [], verdicts: [], post_gate: null };
  }

  let changed = false;
  let deadlocks = [];
  for (let round = 1; round <= CODEX_ROUNDS_MAX; round += 1) {
    const resp = await respondToFindings(c, open, `round ${round}`);
    const byId = new Map((resp.resolutions || []).map((r) => [r.id, r]));
    if ((resp.resolutions || []).some((r) => r.action === 'fixed')) changed = true;

    const testChanges = (resp.resolutions || []).filter((r) => r.action === 'test_change');
    if (testChanges.length > 0) {
      const tw = await routeTestChange(c, testChanges);
      changed = true;
      log(`#${c.issue}: routed ${testChanges.length} test-change request(s): ${tw.summary}`);
    }

    const disputed = open
      .filter((f) => byId.get(f.id) && byId.get(f.id).action === 'disputed')
      .map((f) => ({ ...f, dispute: byId.get(f.id).note }));
    if (disputed.length === 0) {
      open = [];
      break;
    }
    if (round === CODEX_ROUNDS_MAX) {
      deadlocks = disputed.map((d) => ({ ...d, reaffirm: `(final round — not re-put to ${reviewer})` }));
      break;
    }

    const reb = await independentRebuttal(c, disputed);
    const stance = new Map(((reb && reb.verdicts) || []).map((v) => [v.id, v]));
    const stillLive = disputed.filter((d) => {
      const s = stance.get(d.id);
      return s && s.stance === 'REAFFIRMED';
    });
    log(`#${c.issue}: round ${round} — ${disputed.length - stillLive.length} withdrawn, ${stillLive.length} reaffirmed.`);
    if (stillLive.length === 0) {
      open = [];
      break;
    }
    deadlocks = stillLive.map((d) => ({ ...d, reaffirm: (stance.get(d.id) || {}).reason || '' }));
    open = stillLive;
  }

  let verdicts = [];
  if (deadlocks.length > 0) {
    const judged = await fableJudge(c, deadlocks, green);
    verdicts = (judged && judged.verdicts) || [];
    log(`#${c.issue}: judge ruled on ${verdicts.length} deadlock(s): ${(judged || {}).summary || ''}`);

    const upheld = verdicts.filter((v) => v.verdict === 'UPHOLD_FINDING');
    if (upheld.length > 0) {
      await respondToFindings(
        c,
        upheld.map((v) => {
          const src = deadlocks.find((d) => d.id === v.id) || {};
          return {
            id: v.id,
            severity: src.severity || 'IMPORTANT',
            location: src.location || '',
            claim: `JUDGE RULED THIS FINDING VALID. Its decision is final — you may not dispute it. Apply this directive: ${v.directive}`,
            evidence: v.rationale,
          };
        }),
        'judge-upheld (binding)',
      );
      changed = true;
    }
    const testReq = verdicts.filter((v) => v.verdict === 'TEST_CHANGE_REQUIRED');
    if (testReq.length > 0) {
      await routeTestChange(
        c,
        testReq.map((v) => ({ id: v.id, note: `JUDGE RULED A TEST CHANGE IS REQUIRED: ${v.directive} (${v.rationale})` })),
      );
      changed = true;
    }
  }

  const gate = changed ? await postGate(c, 'adjudication applied changes') : null;
  return {
    codex_ok: true,
    reviewer,
    findings: review.findings || [],
    deadlocks,
    verdicts,
    post_gate: gate,
    adjudication_clean:
      !gate || (gate.unit_pass && gate.integration_pass && gate.lint_clean && gate.full_unit_pass),
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
const wave = (a.issues || []).map((n) => Number(n));
if (wave.length === 0) throw new Error('bugfix-fleet: args.issues must be a non-empty array of issue numbers');
log(`bugfix-fleet: phase=${phaseArg} issues=${wave.join(', ')}`);

if (phaseArg !== 'green') {
  phase('Red fan-out');
  // Barrier, not pipeline: the main loop needs every briefing back together so
  // it can make the signed test commits before green starts.
  const reds = await parallel(
    wave.map((n) => () => workflow('tdd-bugfix', { ...cfgFor(n), phase: 'red' })),
  );
  const ok = reds.filter(Boolean);
  for (const r of ok) {
    log(`#${r.issue} (${r.utility}) red: ready_to_commit=${r.ready_to_commit_red}`);
  }
  return {
    phase: 'red',
    issues: wave,
    per_issue: Object.fromEntries(ok.map((r) => [r.issue, r])),
    briefings: Object.fromEntries(ok.map((r) => [r.issue, r.briefing])),
    commit_plan: ok.map((r) => ({
      issue: r.issue,
      workdir: ISSUES[r.issue].workdir,
      ready: r.ready_to_commit_red,
    })),
  };
}

phase('Green fan-out');
const briefings = a.briefings || {};
const greens = await parallel(
  wave.map((n) => async () => {
    const c = cfgFor(n);
    const green = await workflow('tdd-bugfix', {
      ...c,
      phase: 'green',
      briefing: briefings[n] || briefings[String(n)],
    });
    if (!green) return null;
    // Sequential within the issue: the review needs the finished diff. Across
    // issues these chains run concurrently. runGreen does not return the
    // briefing, so re-attach the one the red phase produced — the independent
    // reviewer and the judge both need its pinned GNU behavior as the spec.
    const adj = await adjudicate(c, {
      ...green,
      briefing: briefings[n] || briefings[String(n)],
    });
    return { ...green, adjudication: adj };
  }),
);

const ok = greens.filter(Boolean);
for (const g of ok) {
  log(
    `#${g.issue} (${g.utility}) green: pipeline=${g.ready_to_commit_green} ` +
      `reviewer=${g.adjudication.reviewer || 'unknown'} ` +
      `findings=${(g.adjudication.findings || []).length} ` +
      `deadlocks=${(g.adjudication.deadlocks || []).length}`,
  );
}
return {
  phase: 'green',
  issues: wave,
  // The review gate is unchanged in strength: `review_ok` is still ANDed into
  // `ready`. What changed is that an absent codex now selects a different
  // reviewer instead of failing the gate forever — and `reviewer` records
  // which one actually ran, so "not reviewed by Codex" is never mistaken for
  // "not reviewed".
  reviewer: (ok[0] && ok[0].adjudication && ok[0].adjudication.reviewer) || 'unknown',
  secondary_platform: LINUX_PREFIX || 'unavailable on this host; macOS deferred to CI',
  per_issue: Object.fromEntries(ok.map((g) => [g.issue, g])),
  commit_plan: ok.map((g) => ({
    issue: g.issue,
    workdir: ISSUES[g.issue].workdir,
    reviewer: g.adjudication.reviewer || 'unknown',
    ready:
      g.ready_to_commit_green &&
      g.adjudication.codex_ok &&
      g.adjudication.adjudication_clean !== false,
  })),
};
