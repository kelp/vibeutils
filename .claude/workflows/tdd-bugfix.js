export const meta = {
  name: 'tdd-bugfix',
  description:
    'Classic red-green TDD pipeline for one bug fix. Phase "red": scout the bug site, pin the reference (GNU) behavior on the Linux VM, write FAILING tests, review them to APPROVED, verify RED for the right reason on macOS AND Linux. Phase "green": implement the minimal fix, then loop scoped verify + Tiger check + code review until green, ending with the full suites on both platforms. Commits are done by the orchestrator in the main loop (signing policy), not here.',
  whenToUse:
    'Fixing a behavior bug in a vibeutils utility where a natural failing test exists (GNU-parity divergences, wrong output, wrong exit code). Dispatch twice per bug: phase:"red", commit the tests, phase:"green", commit the fix. For behavior-preserving refactors use tdd-pipeline instead.',
  phases: [
    { title: 'Scout', detail: 'distill bug site + pin GNU behavior on orb ubuntu (sonnet)' },
    { title: 'Author tests', detail: 'write FAILING tests asserting pinned behavior (opus, tdd-pipeline:test-writer)' },
    { title: 'Review tests', detail: 'loop test-reviewer until APPROVED (opus)' },
    { title: 'Red check', detail: 'red for the RIGHT reason, macOS + Linux; rest of suite green (sonnet)' },
    { title: 'Implement', detail: 'minimal fix, scoped quiet checks (opus, tdd-pipeline:implementer)' },
    { title: 'Verify gate', detail: 'SCOPED: util unit + util integration + lint (haiku)' },
    { title: 'Tiger check', detail: 'scan for NEW Tiger Style violations, triage dual-use, fix (haiku/sonnet)' },
    { title: 'Code review', detail: 'loop code-reviewer until APPROVED (opus)' },
    { title: 'Final verify', detail: 'ONCE: full unit + privileged + integration on macOS AND Linux (haiku)' },
  ],
};

// ---------------------------------------------------------------------------
// Inputs (args)
// ---------------------------------------------------------------------------
// {
//   utility, issue, bug_summary, expected_behavior,
//   impl_files[],   // implementation code the implementer may edit
//   test_files[],   // files the test-writer may edit (embedded test blocks + integration .sh)
//   gnu_pin_cmds[], // shell commands to run on the Linux VM to pin GNU behavior
//   behaviors[],    // behaviors the tests must cover
//   test_cmd, privileged_test_cmd, util_test_cmd, it_cmd, fmt_cmd, full_it_cmd,
//   linux_prefix,   // e.g. "orb -m ubuntu" — how to run a command on the Linux VM
//   phase: "red" | "green",
//   briefing: <object returned by the red phase, fed back into green>
// }

const rawArgs = typeof args !== 'undefined' ? args : {};
const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs || {};
log(`args: type=${typeof args} utility=${a.utility || 'MISSING'} issue=${a.issue || '?'} behaviors=${(a.behaviors || []).length}`);
const phaseArg = a.phase || 'red';

// Briefing from the wave-3 red scout (run wf_ea842c94-bfb).
const EMBEDDED_BRIEFING = {"bug_site": "Bug 1 (issue #65 \u2014 multi-char/byte suffixes) is in `parseSingleSize`, src/dd.zig:113-144:\n\n```\nfn parseSingleSize(s: []const u8) !usize {\n    if (s.len == 0) return error.InvalidValue;\n\n    // Find where the numeric part ends\n    var num_end: usize = 0;\n    while (num_end < s.len and s[num_end] >= '0' and s[num_end] <= '9') : (num_end += 1) {}\n    std.debug.assert(num_end <= s.len);\n\n    if (num_end == 0) return error.InvalidValue;\n    std.debug.assert(num_end > 0);\n\n    const num = std.fmt.parseInt(usize, s[0..num_end], 10) catch return error.InvalidValue;\n    const suffix = s[num_end..];\n\n    if (suffix.len == 0) return num;\n\n    const multiplier: usize = switch (suffix[0]) {\n        'c' => 1,\n        'w' => 2,\n        'b' => 512,\n        'k', 'K' => 1024,\n        'M' => 1048576,\n        'G' => 1073741824,\n        else => return error.InvalidValue,\n    };\n\n    if (suffix.len > 1) return error.InvalidValue;   // <-- rejects EVERY multi-char suffix: kB, KiB, MB, MiB, GB, GiB, TB, PB, EB, ...\n\n    return std.math.mul(usize, num, multiplier) catch return error.InvalidValue;\n}\n```\n\nCalled from `parseByteSize` (src/dd.zig:95-110), which is itself called for every dd operand: `bs=`,`ibs=`,`obs=`,`count=`,`skip=`,`seek=`,`cbs=`,`iseek=`,`oseek=` (src/dd.zig:186-211, `parseOperands_applyKeyValue`). Any suffix longer than one character (kB, KiB, MB, MiB, GB, GiB, TB/TiB/PB/PiB/EB/EiB\u2026) is rejected with `error.InvalidValue` regardless of operand. There is no \"trailing B means bytes not blocks\" concept anywhere \u2014 `parseByteSize`'s numeric result is used verbatim as the operand value; for `count=`/`skip=`/`seek=` that value is currently always interpreted as a BLOCK count (see the comment at src/dd.zig:193-196: \"count=1k means 1024 blocks ... used verbatim without any byte conversion\"), and the copy loop (`runDd_skipInput`, `runDd_seekOutput`, and the `config.count` consumer near line 1447) has no notion of a byte-exact skip/seek/count distinct from `N * ibs` / `N * obs`. Concretely: `runDd_skipInput` (src/dd.zig ~745-780) loops reading whole `ibs`-sized blocks `skip_blocks` times; `runDd_seekOutput` (src/dd.zig:787-822) computes `seek_bytes = seek_blocks * obs` (line 799) \u2014 both assume block-granularity, not an independent byte offset. Implementing GNU's \"N ends in B \u2192 bytes not blocks\" semantics for count/skip/seek requires threading a byte-mode flag out of `parseSingleSize`/`parseByteSize` up through `parseOperands_applyKeyValue` into `DdConfig`, and adding an exact-byte skip/seek/count path in the copy code (confirmed empirically that GNU does an exact byte-level skip, not ibs-block-rounded \u2014 see pinned test with non-multiple ibs below).\n\nNo `T`, `P`, `E` (nor `Z/Y/R/Q`) suffixes are implemented at all today (single-char switch only has c/w/b/k/K/M/G); GNU's committed suffix table per `docs/specs/dd-gnu.txt` (already checked into the repo, lines 23-26) is: `c=1, w=2, b=512, kB=1000, K=1024, MB=1000*1000, M=1024*1024, GB=1000*1000*1000, G=1024*1024*1024, and so on for T, P, E, Z, Y, R, Q. Binary prefixes can be used, too: KiB=K, MiB=M, and so on. If N ends in 'B', it counts bytes not blocks.`\n\nBug 2 (issue #64 \u2014 generic error message) is in `runDd`, src/dd.zig:1217-1227:\n\n```\nconst config = parseOperands(args) catch |err| {\n    switch (err) {\n        error.InvalidValue => {\n            common.printErrorWithProgram(allocator, stderr, \"dd\", \"invalid operand value\", .{});\n        },\n        error.UnknownOperand => {\n            common.printErrorWithProgram(allocator, stderr, \"dd\", \"unrecognized operand\", .{});\n        },\n    }\n    return @intFromEnum(common.ExitCode.misuse);\n};\n```\n\n`error.InvalidValue` carries no payload (see all the `return error.InvalidValue;` sites in `parseSingleSize`/`parseByteSize`/`parseOperands_applyKeyValue`/`parseOperands_applyKeyValue_status`/`parseConversions`), so by the time it's caught here the offending string (e.g. `\"1m\"`) is gone \u2014 the message can't name it. Fix requires either printing at the point of failure (pattern already used elsewhere in the codebase, see head.zig below) or plumbing the failing value string back out through the error path. `common.ExitCode.misuse = 2` (src/common/lib.zig:117-124) is the project's deliberate rc, diverging from GNU's rc=1 \u2014 keep that; only the message text changes to match GNU's shape `dd: invalid number: '<value>'`.\n\nReference pattern already in the codebase for GNU-shaped, value-naming messages (src/head.zig:237-246):\n```\nnegative_count = std.fmt.parseUnsigned(u64, lines_str[1..], 10) catch {\n    common.printErrorWithProgram(\n        allocator, stderr_writer, \"head\",\n        \"invalid number of lines: '{s}'\", .{lines_str},\n    );\n    return .{ .line_count = line_count, .negative_count = negative_count, .ok = false };\n};\n```\nThis prints at the failure site (not centrally), which is the model to follow for dd since `parseOperands`/`parseSingleSize` currently discard the failing string.\n\nExisting test that pins the CURRENT (pre-fix) rejection and must be updated in lockstep with the message-shape change, not silently left stale (src/dd.zig:1787-1792):\n```\n// Lowercase 'm' is not in the bs= suffix table; count= must reject it\n// exactly as bs= does. Pins that we did not loosen the grammar.\ntest \"parseOperands - count lowercase m rejected\" {\n    const args = [_][]const u8{\"count=1m\"};\n    try testing.expectError(error.InvalidValue, parseOperands(&args));\n}\n```", "gnu_behavior": "Pinned on the Linux VM (`orb -m ubuntu`), GNU coreutils 9.5:\n\n```\n$ dd --version | head -1\ndd (coreutils) 9.5\n```\n\n(a) trailing-B suffixes are BYTE-exact on count=, independent of bs=:\n```\n$ yes x 2>/dev/null | head -c 4000 > /tmp/dd65.in\n$ dd if=/tmp/dd65.in of=/tmp/dd65.out bs=512 count=1kB status=none; echo rc=$?; wc -c < /tmp/dd65.out\nrc=0\n1000\n$ dd if=/tmp/dd65.in of=/tmp/dd65.out bs=512 count=1B status=none; echo rc=$?; wc -c < /tmp/dd65.out\nrc=0\n1\n$ dd if=/tmp/dd65.in of=/tmp/dd65.out bs=512 count=1KiB status=none; echo rc=$?; wc -c < /tmp/dd65.out\nrc=0\n1024\n```\n\nIMPORTANT \u2014 count=2b (no trailing B) is NOT \"1024 bytes\" as the issue text speculates. Verified twice, including with a fresh output file:\n```\n$ rm -f /tmp/dd65.out; dd if=/tmp/dd65.in of=/tmp/dd65.out bs=512 count=2b status=none; echo rc=$?; wc -c < /tmp/dd65.out\nrc=0\n4000\n$ dd if=/tmp/dd65.in of=/tmp/dd65.out bs=512 count=2b 2>&1; echo rc=$?; wc -c < /tmp/dd65.out\n7+1 records in\n7+1 records out\n4000 bytes (4.0 kB, 3.9 KiB) copied, 9.542e-06 s, 419 MB/s\nrc=0\n4000\n```\nExplanation (consistent with `--help`'s \"N and BYTES may be followed by... b=512... If N ends in 'B', it counts bytes not blocks\"): `2b` has no trailing B, so it stays a pure numeric multiplier on N: N = 2*512 = 1024 *blocks* (at ibs=512 that's a requested cap of 1024*512 = 524288 bytes), which exceeds the 4000-byte input file, so the whole 4000-byte file is copied (EOF-bounded), not 1024 bytes. **The task's issue text's claim of \"count=2b copies 1024 bytes\" is incorrect; the pinned ground truth is 4000 bytes copied (whole file), 7+1 records.** Test writers must assert 4000, not 1024, for this exact input/command, or use a larger/well-chosen count so the intended block-multiplier semantics (N=1024 blocks) is the thing under test rather than EOF truncation.\n\n(b) skip=/seek= are byte-exact, confirmed by content, not just size \u2014 and confirmed to be an exact byte offset, NOT rounded to nearest ibs-multiple (tested with a non-dividing block size):\n```\n$ printf ABCDEFGHIJ > /tmp/dd65b.in; head -c 990 /dev/zero >> /tmp/dd65b.in; printf KLMNOPQRST >> /tmp/dd65b.in\n$ dd if=/tmp/dd65b.in bs=200 skip=1kB status=none | head -c 10; echo; echo rc=$?\nKLMNOPQRST\nrc=0\n$ rm -f /tmp/dd65c.out; dd if=/tmp/dd65.in of=/tmp/dd65c.out bs=100 count=1 seek=1kB status=none; echo rc=$?; wc -c < /tmp/dd65c.out\nrc=0\n1100\n```\n(seek=1kB seeks exactly 1000 output bytes, then count=1 writes one 100-byte block \u2192 1100 total.)\n\nAdditional exact-byte-offset proof (not part of the original pin list, done to resolve an ambiguity \u2014 ibs=300 does NOT evenly divide 1000, ruling out block-rounded skip):\n```\n$ python3 -c \"import sys; sys.stdout.buffer.write(bytes(range(0,256))*5)\" > /tmp/dd65d.in   # 1280 bytes, cyclic 0..255\n$ dd if=/tmp/dd65d.in bs=300 skip=1000B status=none | od -An -tu1 | head -1\n 232 233 234 235 236 237 238 239 240 241 242 243 244 245 246 247\n```\ndata[1000] = 1000 mod 256 = 232 \u2014 matches. Confirms skip=<N>B seeks to the exact byte offset N, independent of block size (not rounded to a multiple of ibs).\n\n(c) bs=<N>B (or any suffix) is a plain byte multiplier regardless of trailing B \u2014 records-in proves 1000-byte blocks:\n```\n$ dd if=/tmp/dd65.in of=/dev/null bs=1kB 2>&1; echo rc=$?\n4+0 records in\n4+0 records out\n4000 bytes (4.0 kB, 3.9 KiB) copied, 5.2125e-05 s, 76.7 MB/s\nrc=0\n```\n(4000/1000 = 4 exact records, confirming ibs=obs=1000 bytes for bs=1kB.)\n\n(d) zero-multiplier warning, verbatim (default UTF-8 locale, curly quotes: U+2018 '\\xe2\\x80\\x98' / U+2019 '\\xe2\\x80\\x99'):\n```\n$ dd if=/tmp/dd65.in of=/dev/null bs=512 count=0x10 2>&1; echo rc=$?\ndd: warning: '0x' is a zero multiplier; use '00x' if that is intended\n0+0 records in\n0+0 records out\n0 bytes copied, 1.75e-06 s, 0.0 kB/s\nrc=0\n```\n(quotes above rendered as straight ASCII for this report; verbatim bytes are curly \u20180x\u2019 / \u201800x\u2019 under the VM's default `LANG=C.UTF-8`.) Under `LC_ALL=C` the SAME message uses plain ASCII quotes instead:\n```\n$ LC_ALL=C dd if=/tmp/dd65.in of=/dev/null bs=512 count=0x10 2>&1 | head -1\ndd: warning: '0x' is a zero multiplier; use '00x' if that is intended\n```\nrc=0 either way; 0 bytes copied, \"0+0 records in/out\" \u2014 count=0x10 parses N=0 (the \"0\" before \"x\", times multiplier from \"x10\"... GNU treats leading \"0\" specially per the warning) and the copy is a no-op. Recommend the project match its own established straight-ASCII-quote convention (see head.zig, sort.zig, tail.zig, and the existing `\"unsupported operand '{s}'\"` message at src/dd.zig:1212) rather than locale-dependent curly quotes \u2014 this sidesteps LC_ALL flakiness in CI and matches the C-locale VM behavior above.\n\n(e) invalid operand value message, verbatim, straight ASCII quotes in BOTH default and C locale:\n```\n$ dd if=/dev/null of=/dev/null count=1m 2>&1; echo rc=$?\ndd: invalid number: '1m'\nrc=1\n$ LC_ALL=C dd if=/dev/null of=/dev/null count=1m 2>&1\ndd: invalid number: '1m'\n```\nGNU's rc is 1; project's committed divergence keeps rc=2 (`ExitCode.misuse`) while adopting this exact message shape (`dd: invalid number: '<value>'`).\n\n(f) garbage suffix combo, verbatim:\n```\n$ dd if=/dev/null of=/dev/null bs=1kBx 2>&1; echo rc=$?\ndd: invalid number: '1kBx'\nrc=1\n```\nSame message shape as (e); again keep project rc=2, adopt GNU's message text.\n\n`dd --help` on the VM (matches `docs/specs/dd-gnu.txt`, already committed in-repo) gives the authoritative suffix grammar:\n```\nN and BYTES may be followed by the following multiplicative suffixes:\nc=1, w=2, b=512, kB=1000, K=1024, MB=1000*1000, M=1024*1024, xM=M,\nGB=1000*1000*1000, G=1024*1024*1024, and so on for T, P, E, Z, Y, R, Q.\nBinary prefixes can be used, too: KiB=K, MiB=M, and so on.\nIf N ends in 'B', it counts bytes not blocks.\n```\nAll requested scenarios were reproducible on the VM; nothing had to be skipped or inferred.", "test_conventions": "Embedded Zig unit tests live at the bottom of `src/dd.zig`. Suffix-parsing tests cluster around line 1660-1852; operand tests around 1660-1864 and again near 2830-2880 (there's a second batch further down the file \u2014 grep `test \"parseOperands` and `test \"parseByteSize` to find all of them, they're not contiguous).\n\nStyle to copy (src/dd.zig:1667-1690):\n```\ntest \"parseByteSize - with suffixes\" {\n    try testing.expectEqual(@as(usize, 1), try parseByteSize(\"1c\"));\n    try testing.expectEqual(@as(usize, 2), try parseByteSize(\"1w\"));\n    try testing.expectEqual(@as(usize, 512), try parseByteSize(\"1b\"));\n    try testing.expectEqual(@as(usize, 1024), try parseByteSize(\"1k\"));\n    try testing.expectEqual(@as(usize, 1024), try parseByteSize(\"1K\"));\n    try testing.expectEqual(@as(usize, 1048576), try parseByteSize(\"1M\"));\n    try testing.expectEqual(@as(usize, 1073741824), try parseByteSize(\"1G\"));\n    try testing.expectEqual(@as(usize, 4096), try parseByteSize(\"4K\"));\n    try testing.expectEqual(@as(usize, 5120), try parseByteSize(\"10b\"));\n}\n...\ntest \"parseByteSize - errors\" {\n    try testing.expectError(error.InvalidValue, parseByteSize(\"\"));\n    try testing.expectError(error.InvalidValue, parseByteSize(\"abc\"));\n    try testing.expectError(error.InvalidValue, parseByteSize(\"1Z\"));\n    try testing.expectError(error.InvalidValue, parseByteSize(\"x1\"));\n}\n```\nAnd the block-vs-byte regression comment style to imitate (src/dd.zig:1787-1792, this exact test must be revisited \u2014 `count=1m` still errors, but now the message text changes, so any new test asserting the message must not duplicate/contradict this one; coordinate rather than delete):\n```\n// Lowercase 'm' is not in the bs= suffix table; count= must reject it\n// exactly as bs= does. Pins that we did not loosen the grammar.\ntest \"parseOperands - count lowercase m rejected\" {\n    const args = [_][]const u8{\"count=1m\"};\n    try testing.expectError(error.InvalidValue, parseOperands(&args));\n}\n```\nExisting must-stay-green regression anchors (block-count semantics from #43, v0.11.0): src/dd.zig:1770-1778 (`\"parseOperands - plain integer count skip seek unchanged\"`) and src/dd.zig:1789-1792 above, plus the \"count=1k means 1024 blocks\" comment at src/dd.zig:193-196 which documents the invariant that non-B-suffixed count is still a block multiplier.\n\nIntegration tests: `tests/utilities/dd_test.sh`, function `test_dd()` (src/... wait, it's the whole file, starts line 7, ends line 560). Sourced by `tests/test_runner.sh`; helpers come from `tests/lib/common.sh` (already loaded when this file is sourced, no need to source it again).\n\nRelevant existing integration tests to keep green, and to copy style from (tests/utilities/dd_test.sh:190-218):\n```\n# Issue #43: count= must accept the same suffixes bs= does. This is\n# the exact command from the issue: bs=512 count=1k -> 512*1024 bytes.\nlocal count_suffix_output=\"$TEMP_DIR/dd_count_suffix.txt\"\n\"$binary\" if=/dev/zero of=\"$count_suffix_output\" bs=512 count=1k status=none 2>/dev/null\nlocal count_suffix_size\ncount_suffix_size=$(get_file_size \"$count_suffix_output\")\nif [[ \"$count_suffix_size\" -eq 524288 ]]; then\n    print_test_result \"dd count=1k suffix\" \"PASS\"\nelse\n    print_test_result \"dd count=1k suffix\" \"FAIL\" \\\n        \"Expected 524288 bytes, got $count_suffix_size\"\nfi\n\n# Issue #43: skip= suffix seeks the input by the suffixed block count.\n# Build a >1KiB input where byte at offset 1024 is known, copy 1 byte.\nlocal skip_suffix_input=\"$TEMP_DIR/dd_skip_suffix_in.txt\"\nprintf '%01024d' 0 > \"$skip_suffix_input\"\nprintf 'Z' >> \"$skip_suffix_input\"\nlocal skip_suffix_output=\"$TEMP_DIR/dd_skip_suffix_out.txt\"\n\"$binary\" if=\"$skip_suffix_input\" of=\"$skip_suffix_output\" \\\n    bs=1 skip=1k count=1 status=none 2>/dev/null\nlocal skip_suffix_content\nskip_suffix_content=$(cat \"$skip_suffix_output\")\nif [[ \"$skip_suffix_content\" == \"Z\" ]]; then\n    print_test_result \"dd skip=1k suffix\" \"PASS\"\nelse\n    print_test_result \"dd skip=1k suffix\" \"FAIL\" \\\n        \"Expected 'Z', got '$skip_suffix_content'\"\nfi\n```\nAlso the generic invalid-operand test to extend/coexist with (tests/utilities/dd_test.sh:162-167):\n```\n# Test invalid operand\nif \"$binary\" invalid=operand status=none 2>/dev/null; then\n    print_test_result \"dd invalid operand\" \"FAIL\" \"Should have failed\"\nelse\n    print_test_result \"dd invalid operand\" \"PASS\"\nfi\n```\nThis checks only exit != 0 with stderr discarded (`2>/dev/null`) \u2014 the new `count=1m` message-shape test needs a fresh case that captures stderr (pattern: `2>\"$err_file\"` then `grep`/`==` on contents, as done at tests/utilities/dd_test.sh:265-279 for the fdatasync-pipe regression, or `test_command_exit_code`).\n\n`test_command_exit_code` helper (tests/lib/common.sh:449-464) \u2014 use for the rc=2 assertion on `count=1m`:\n```\ntest_command_exit_code() {\n    local test_name=\"$1\"\n    local expected_exit=\"$2\"\n    shift 2\n    local command stdout stderr actual_exit\n    run_command command stdout stderr actual_exit \"$@\"\n    if [[ $actual_exit -eq $expected_exit ]]; then\n        print_test_result \"$test_name\" \"PASS\"\n    else\n        print_test_result \"$test_name\" \"FAIL\" \"Expected exit $expected_exit, got $actual_exit\" \"$command\"\n    fi\n}\n```\nExisting precedent in dd_test.sh: `test_command_exit_code \"dd failure exit code\" 1 \"$binary\" if=/nonexistent/path of=/dev/null status=none 2>/dev/null || true` (line 287) \u2014 note the project's OWN failure-exit-code convention there is 1 for a different failure mode (I/O error), not the misuse=2 path; the new count=1m test is specifically about the misuse/parse-error path (rc=2), don't conflate the two.\n\n`run_with_limit` (tests/lib/common.sh:334-373) \u2014 a Python-based `timeout`-equivalent wrapper (`run_with_limit <seconds> <cmd...>`), required per CLAUDE.md instead of GNU `timeout(1)` because macOS runners lack it; use if any new test risks hanging (unlikely for these parse-only cases, but the skip/seek exact-byte tests do real I/O so consider it defensively).\n\n`TEMP_DIR` (tests/lib/common.sh:26): `TEMP_DIR=\"$_temp_root/vibeutils_tests_$$\"` \u2014 use `\"$TEMP_DIR/<name>\"` for scratch files as all existing dd tests do; `create_temp_file \"content\"` (tests/lib/common.sh:551) is the standard content-seeded input-file helper already used throughout dd_test.sh.\n\nExact scoped test commands:\n```\njust test-util dd     # zig build test -Dtest-util=dd  (embedded unit tests; passes today, confirmed)\njust it-util dd        # integration tests for dd only\n```\nFull suites required before declaring done per project CLAUDE.md: `zig build test` and `just it` (both platforms \u2014 macOS host plus `orb -m ubuntu` for Linux \u2014 before any release gate, per the repo's release philosophy, though that's out of scope for a routine bugfix commit).", "notes": "Platform differences observed:\n- All GNU-behavior pinning was done on Linux (`orb -m ubuntu`, coreutils 9.5); macOS has no native GNU dd (BSD dd), so there is no macOS cross-check possible for these suffix semantics \u2014 this is consistent with the existing precedent at src/dd.zig test comment near line 322-324 (\"Reference verified on GNU coreutils 9.5 Linux; hardcoded because BSD dd on macOS does not implement conv=swab the same way\"). New tests pinning GNU-only behavior (trailing-B byte semantics, the 0x zero-multiplier warning, the \"invalid number\" message) should be hardcoded to the Linux-verified GNU values, matching that existing pattern, not shelled out to a live GNU dd binary (which won't exist on the macOS CI runner).\n- Locale sensitivity: the zero-multiplier warning text uses curly Unicode quotes (\u2018\u2019) under the VM's default `LANG=C.UTF-8`, but plain ASCII quotes ('') under `LC_ALL=C`. The \"invalid number\" message uses plain ASCII quotes under BOTH locales (verified independently). Recommend the fix and its tests standardize on plain ASCII quotes for both messages, matching this project's existing convention everywhere else (head.zig, sort.zig, tail.zig, and dd.zig's own `\"unsupported operand '{s}'\"` at line 1212) \u2014 avoids locale-flakiness and doesn't require emitting non-ASCII bytes from the Zig implementation.\n- Critical correction to the issue's own text: the issue asserts \"count=2b copies 1024 bytes\" \u2014 this is WRONG per direct measurement on GNU 9.5. Verified twice (fresh output file both times): `count=2b` with `bs=512` against a 4000-byte input copies the WHOLE 4000-byte file (7+1 records), because `2b` (no trailing B) is a pure block-count multiplier giving N=1024 *blocks* at ibs=512 (a 524288-byte request cap), which exceeds the 4000-byte input and is EOF-truncated. Any test asserting \"count=2b \u2192 exactly 1024 bytes\" against this specific 4000-byte fixture will be WRONG and will not match real GNU dd; either use the actual pinned value (4000) with this fixture, or construct a >=524288-byte fixture if the intent is to test the 1024-block-count computation itself in isolation from EOF truncation.\n- Architecture note for the implementer (not required for the test-writer, but useful context): `DdConfig.skip`/`.seek` are currently pure block counts consumed by `runDd_skipInput` (loops reading whole `ibs` blocks) and `runDd_seekOutput` (`seek_bytes = seek_blocks * obs`, src/dd.zig:799). Supporting GNU's byte-exact skip/seek requires either converting these fields to always store bytes (computing `blocks * ibs`/`blocks * obs` at parse time when non-B, and the literal N when B-suffixed) plus rewriting the skip loop to seek/read an exact byte count rather than a block count, or adding parallel `_is_bytes` flags read at the copy-loop call sites. I independently reproduced GNU's exact-byte (not ibs-block-rounded) skip semantics using a 300-byte ibs against a cyclic-byte fixture (`bs=300 skip=1000B` lands exactly on byte offset 1000, not rounded to a multiple of 300) \u2014 this rules out a naive \"round N bytes up to nearest ibs block\" implementation.\n- Nearby tests that must stay green (do not weaken/delete, only add alongside): src/dd.zig:1770-1778 (plain integer count/skip/seek unchanged), src/dd.zig:1789-1792 (count=1m still rejected \u2014 message text changes but the error path must still fire and exit 2), tests/utilities/dd_test.sh:190-218 (count=1k and skip=1k block-multiplier semantics from issue #43/v0.11.0), tests/utilities/dd_test.sh:162-167 (generic invalid-operand still exits nonzero).\n- `common.ExitCode.misuse` is a `u8` enum value `2` (src/common/lib.zig:117-124); GNU's dd itself uses rc=1 for these errors (confirmed above) \u2014 the project's CLAUDE.md explicitly documents this as a deliberate divergence, so tests must assert rc=2, not rc=1, while matching GNU's message text.\n- `printErrorWithProgram` signature (src/common/lib.zig:205-211): `(allocator, writer, prog_name: []const u8, comptime fmt: []const u8, fmt_args: anytype) void` \u2014 this is the mechanism both the existing `dd:` messages and the head.zig-style value-naming pattern use; any fix threading the failing value string up to `runDd`'s catch block (or printing at the failure site directly, per the head.zig pattern) must use this same call shape to stay consistent with the rest of the codebase."};

const REVIEW_ROUND_MAX = 12;
const GATE_FIX_MAX = 4;

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['bug_site', 'gnu_behavior', 'test_conventions', 'notes'],
  properties: {
    bug_site: {
      type: 'string',
      description:
        'The buggy code: exact file:line references, the relevant function signatures and code excerpts (copy real code, do not paraphrase), and how the buggy path is reached (flags, input conditions).',
    },
    gnu_behavior: {
      type: 'string',
      description:
        'The pinned reference behavior: the EXACT commands run on the Linux VM, their verbatim stdout/stderr and exit codes, and the GNU coreutils version. This is the spec the tests assert. If a pin command could not reproduce the scenario, say so explicitly and quote the issue text as fallback.',
    },
    test_conventions: {
      type: 'string',
      description:
        'What a test author needs without exploring: where embedded unit tests live in the target file (with an excerpt of a nearby existing test to copy the style of), the integration test file and its helper functions (print_test_result, run_with_limit, TEMP_DIR usage), exact scoped test commands, and the privileged/fakeroot rules if relevant.',
    },
    notes: {
      type: 'string',
      description:
        'Anything else downstream agents need: platform differences observed (macOS vs Linux errno/text), pitfalls in the code path, related existing tests that must stay green.',
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

// Red check: the bug-fix substitute for tdd-pipeline's sabotage stage. A
// natural RED proves the tests have teeth; this stage proves the RED is real,
// for the right reason, on both platforms, and that nothing else broke.
const REDCHECK_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['red_macos', 'right_reason', 'rest_green', 'red_linux', 'summary', 'output_excerpt'],
  properties: {
    red_macos: { type: 'boolean', description: 'the new tests FAIL on current code on macOS' },
    right_reason: {
      type: 'boolean',
      description:
        'the failure is the intended assertion mismatch (the bug), NOT a compile error, crash, harness bug, or skip',
    },
    rest_green: {
      type: 'boolean',
      description: 'every pre-existing test still passes; the ONLY failures are the newly added tests',
    },
    red_linux: { type: 'boolean', description: 'the new tests also FAIL on the Linux VM' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string', description: 'the failing assertions verbatim (short)' },
  },
};

const VERIFY_GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'integration_pass', 'lint_clean', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'true if the scoped util_test_cmd unit check passes' },
    integration_pass: { type: 'boolean', description: 'true if the scoped it_cmd integration suite passes' },
    lint_clean: { type: 'boolean', description: 'true if fmt-check passes' },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['unit_pass', 'privileged_pass', 'integration_pass', 'linux_unit_pass', 'linux_integration_pass', 'summary', 'output_excerpt'],
  properties: {
    unit_pass: { type: 'boolean', description: 'true if the FULL unit suite (test_cmd) passes on macOS' },
    privileged_pass: { type: 'boolean', description: 'true if the FULL privileged suite passes on macOS' },
    integration_pass: { type: 'boolean', description: 'true if the FULL integration suite (full_it_cmd) passes on macOS' },
    linux_unit_pass: { type: 'boolean', description: 'true if the full unit suite passes on the Linux VM' },
    linux_integration_pass: {
      type: 'boolean',
      description: 'true if the scoped integration suite for this utility passes on the Linux VM',
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string' },
  },
};

const TIGER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clean', 'new_violations', 'preexisting_count', 'filtered', 'summary', 'output_excerpt'],
  properties: {
    clean: {
      type: 'boolean',
      description: 'true iff there are no confirmed NEW Tiger Style violations after triage',
    },
    new_violations: {
      type: 'array',
      description: 'confirmed NEW violations introduced by this change; these BLOCK until fixed',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rule', 'location', 'detail'],
        properties: {
          rule: {
            type: 'string',
            description:
              'one of: long-line, long-fn, self-recursion, compound-assert, unbounded-loop, usize-arch',
          },
          location: { type: 'string', description: 'file:line as reported by the scanner' },
          detail: { type: 'string', description: 'the scanner detail field (e.g. width=128, fn=NAME)' },
        },
      },
    },
    preexisting_count: {
      type: 'integer',
      description: 'count of PRE-existing violations the scanner reported (reported, not blocking)',
    },
    filtered: {
      type: 'array',
      description: 'candidate violations dismissed as legitimate dual-use, with the reason',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['location', 'why'],
        properties: {
          location: { type: 'string', description: 'file:line of the dismissed candidate' },
          why: {
            type: 'string',
            description:
              'why it is legitimate (e.g. usize required by a std API; while(true) bounded by a break+assert)',
          },
        },
      },
    },
    summary: { type: 'string' },
    output_excerpt: { type: 'string', description: 'a short excerpt of the scanner stdout' },
  },
};

const IMPLEMENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['outcome', 'summary'],
  properties: {
    outcome: {
      type: 'string',
      enum: ['done', 'needs_test_change'],
      description:
        "'done' = implementation complete against the existing tests. 'needs_test_change' = a test is wrong (over-constrained, asserts an unspecified detail, or contradicts the pinned GNU behavior) and must be fixed by the test-writer before the code can be correct.",
    },
    summary: { type: 'string' },
    test_change_instructions: {
      type: 'string',
      description:
        'When outcome=needs_test_change: name the exact test(s), why each is wrong, and what the correct assertion should be. Empty when outcome=done.',
    },
  },
};

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
    '### Bug site',
    b.bug_site,
    '',
    '### Pinned reference (GNU) behavior — this is the spec',
    b.gnu_behavior,
    '',
    '### Test conventions',
    b.test_conventions,
    '',
    '### Notes',
    b.notes,
  ].join('\n');
}

function taskHeader() {
  return [
    `Utility: ${a.utility}`,
    `Issue: #${a.issue}`,
    `Bug: ${a.bug_summary}`,
    `Expected behavior (GNU): ${a.expected_behavior}`,
    `Implementation files (implementer edits ONLY these): ${(a.impl_files || []).join(', ')}`,
    `Test files (test-writer edits ONLY these): ${(a.test_files || []).join(', ')}`,
    `Behaviors the tests must cover:\n- ${(a.behaviors || []).join('\n- ')}`,
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
      'You are scouting a vibeutils bug fix so downstream agents never have to explore.',
      'Copy EXACT code excerpts and signatures; do not paraphrase.',
      '',
      taskHeader(),
      '',
      'Do all of the following:',
      `1. Read the bug site in ${(a.impl_files || []).join(', ')} and distill it (file:line, code excerpts,`,
      '   how the buggy path is reached).',
      `2. Pin the reference behavior: run each of these commands on the Linux VM and record verbatim`,
      '   output and exit codes (also record the GNU coreutils version with --version):',
      ...(a.gnu_pin_cmds || []).map((c) => `     ${a.linux_prefix} ${c}`),
      '   If a command cannot reproduce the scenario, say so explicitly rather than inventing output.',
      `3. Distill test conventions from ${(a.test_files || []).join(', ')}: where embedded unit tests live,`,
      '   an excerpt of a nearby test to copy the style of, the integration helpers',
      '   (print_test_result, run_with_limit, TEMP_DIR), and the exact scoped test commands:',
      `     scoped unit: ${a.util_test_cmd}`,
      `     scoped integration: ${a.it_cmd}`,
      '4. Note platform differences you observe (macOS vs Linux errno text) and nearby tests that must stay green.',
      'Also read CLAUDE.md sections on testing and Tiger Style if you need the rules.',
    ].join('\n'),
    { label: `scout:${a.utility}#${a.issue}`, phase: 'Scout', model: 'sonnet', schema: BRIEFING_SCHEMA },
  );
}

async function routeTestChange(brief, instructions, hop, phaseName) {
  return await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — adjudicate an implementer test-change request',
      taskHeader(),
      '',
      'The implementer reports that a TEST must change rather than the implementation. Judge that FIRST by',
      'reading the test, the behavior it guards, and the pinned GNU behavior in the briefing:',
      '  - If the test is genuinely WRONG (over-constrained, asserts an unspecified detail, or contradicts',
      '    the pinned GNU behavior), fix it — and keep it with TEETH: it must still fail if the guarded',
      '    behavior regresses. Set changed=true and describe the fix.',
      '  - If the test is CORRECT, do NOT change it. Set changed=false and explain why the implementation,',
      '    not the test, must change. The implementer will then be told to fix the code.',
      '',
      `Implementer's request:\n${instructions}`,
      '',
      `Edit ONLY test code in ${(a.test_files || []).join(', ')}; do not touch implementation logic.`,
      'Run `just fmt`. Do NOT commit.',
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
        `Edit ONLY implementation code in ${(a.impl_files || []).join(', ')}. Run \`just fmt\`. Do NOT commit.`,
        'Return your outcome.',
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
// RED phase: failing tests that pin the reference behavior
// ---------------------------------------------------------------------------
async function runRed() {
  const briefing = await scoutBriefing();
  const brief = formatBriefing(briefing);

  phase('Author tests');
  let testNote = await agent(
    [
      brief,
      '',
      '## YOUR TASK (test-writer) — FAILING tests for a bug fix',
      taskHeader(),
      '',
      'This is a classic red-green bug fix. Write tests that assert the PINNED GNU behavior from the',
      'briefing — they must FAIL on the current (buggy) code and will pass once the bug is fixed.',
      '- Do NOT touch or rewrite existing tests; they remain the regression net.',
      '- Assert the reference behavior EXACTLY as pinned (output text, exit codes) — no weaker proxies.',
      '- Each test must fail for the RIGHT reason: the assertion matching the bug, not a compile error,',
      '  crash, or harness bug. Run the new tests and CONFIRM the failure message is the intended one.',
      '- Cover every behavior listed above; prefer a unit test where the code path is directly reachable',
      '  plus an integration test for the user-visible behavior.',
      '- Confirm every PRE-existing test still passes (scoped run) — the new tests are the only reds.',
      '',
      `Run the scoped checks: \`${a.util_test_cmd}\` and \`${a.it_cmd}\`, piped through \`tail\` to keep`,
      'output short. Do NOT run the full suite.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY: ${(a.test_files || []).join(', ')}. Only test code — do NOT change`,
      '    implementation logic, other sources, TODO.md, or build files.',
      '  - DO run `just fmt` to fix formatting.',
      '  - Do NOT commit. Return a short summary: each test added, where it lives, the behavior it guards,',
      '    and the exact failure message you observed (proof of red-for-the-right-reason).',
    ].join('\n'),
    { label: `test-writer:${a.utility}#${a.issue}`, phase: 'Author tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
  );

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
        `Review the failing tests just added to ${(a.test_files || []).join(', ')}. Check: every listed`,
        'behavior is covered; each test asserts the PINNED GNU behavior from the briefing exactly (not a',
        'weaker proxy); the tests will fail on the current buggy code for the right reason and will pass',
        'once the behavior is fixed; no tautologies; no changes to implementation code snuck in.',
        'Judge BY READING AND REASONING ONLY — do NOT run the suite or modify anything; a separate red-check',
        'stage verifies the red empirically. Return APPROVED only when nothing remains.',
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
        'Apply every fix; the tests must still FAIL on current code for the right reason. Do NOT commit.',
        'Return a short summary.',
      ].join('\n'),
      { label: `test-writer:${a.utility}#fix${round}`, phase: 'Review tests', model: 'sonnet', agentType: 'tdd-pipeline:test-writer' },
    );
  }
  if (testReview.assessment !== 'APPROVED') {
    log(`WARNING: test review hit the ${REVIEW_ROUND_MAX}-round backstop without APPROVED — surfacing for human review.`);
  }

  // Red check: prove the red is real, for the right reason, on both platforms.
  phase('Red check');
  const redCheck = await agent(
    [
      '## YOUR TASK (red check — run and report only)',
      taskHeader(),
      '',
      'Verify the newly added tests are RED for the RIGHT reason. Run each step EXACTLY as given and',
      'report facts only; do NOT edit anything.',
      `1. macOS scoped unit: \`${a.util_test_cmd}\` — confirm the ONLY failures are the newly added tests`,
      '   and each failure message is the intended assertion (the bug), not a compile error or crash.',
      `2. macOS scoped integration: \`${a.it_cmd}\` — same standard (new cases fail, old cases pass).`,
      `3. Linux: \`${a.linux_prefix} zig build\` then the scoped unit and integration equivalents:`,
      `   \`${a.linux_prefix} zig build test -Dtest-util=${a.utility}\` and`,
      `   \`${a.linux_prefix} bash tests/integration.sh ${a.utility}\` — confirm the same red.`,
      '   (The VM has zig but not just.)',
      'Pipe verbose output through `tail`. red_macos/red_linux = new tests fail there; right_reason = the',
      'failure is the intended assertion mismatch; rest_green = everything else passes.',
    ].join('\n'),
    { label: `red-check:${a.utility}#${a.issue}`, phase: 'Red check', model: 'sonnet', schema: REDCHECK_SCHEMA },
  );
  log(`red check: macos=${redCheck.red_macos} reason=${redCheck.right_reason} rest=${redCheck.rest_green} linux=${redCheck.red_linux}`);

  return {
    phase: 'red',
    utility: a.utility,
    issue: a.issue,
    briefing,
    test_summary: testNote,
    test_review: testReview,
    red_check: redCheck,
    ready_to_commit_red:
      testReview.assessment === 'APPROVED' &&
      !!(redCheck && redCheck.red_macos && redCheck.right_reason && redCheck.rest_green && redCheck.red_linux),
  };
}

// ---------------------------------------------------------------------------
// GREEN phase: minimal fix, keep everything green
// ---------------------------------------------------------------------------
async function runGreen() {
  const briefing = a.briefing || EMBEDDED_BRIEFING || (await scoutBriefing());
  const brief = formatBriefing(briefing);

  phase('Implement');
  let testsChangedDuringGreen = false;
  let impl = await runImplementer(
    [
      brief,
      '',
      '## YOUR TASK (implementer) — minimal bug fix',
      taskHeader(),
      '',
      'Failing tests already pin the correct (GNU) behavior. Make them pass with the MINIMAL correct fix.',
      'Fix the root cause; do not special-case around the tests. ALL pre-existing tests must stay green.',
      'Honor Tiger Style: 2+ assertions per function, no recursion, bounded loops, 70-line/100-col limits.',
      '',
      'For your own iteration, use only FAST, SCOPED, QUIET checks — a compile check (`zig build`) and at',
      `most \`${a.util_test_cmd}\` and \`${a.it_cmd}\`, piped through \`tail\`. Do NOT run the full suite,`,
      'the privileged/fakeroot suite, or the full integration suite yourself — a dedicated verify stage',
      'runs those and reports back.',
      '',
      'Scope discipline:',
      `  - Hand-edit ONLY implementation code in: ${(a.impl_files || []).join(', ')}. Do NOT hand-edit`,
      '    tests, other source files, TODO.md, or build files.',
      '  - DO run `just fmt` to fix formatting.',
      '  - You may NOT edit tests (the test-writer owns those). If you conclude a TEST is wrong — not the',
      '    code — return outcome=needs_test_change with exact instructions instead of editing it.',
      '  - Do NOT commit. Summarize your changes and set outcome=done when complete.',
    ].join('\n'),
    `implementer:${a.utility}#${a.issue}`,
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
        '## YOUR TASK (verify gate — SCOPED, run and report only)',
        'Run ONLY the fast, scoped checks for the utility under change — the full suites are deferred to',
        'the once-only final gate, so do NOT run them here:',
        `  - scoped unit:        "${a.util_test_cmd}"`,
        `  - scoped integration: "${a.it_cmd}"`,
        `  - lint:               "${a.fmt_cmd}"`,
        'Report facts only. unit_pass = scoped unit green; integration_pass = scoped integration green;',
        'lint_clean = fmt passes.',
      ].join('\n'),
      { label: `verify-gate:${a.utility}#${a.issue}`, phase: 'Verify gate', model: 'haiku', schema: VERIFY_GATE_SCHEMA },
    );
    const ok = verify.unit_pass && verify.integration_pass && verify.lint_clean;
    if (ok) break;
    if (vfix === GATE_FIX_MAX) break;
    vfix += 1;
    log(`verify gate failed (unit=${verify.unit_pass} integration=${verify.integration_pass} lint=${verify.lint_clean}) — re-dispatching implementer.`);
    const vimpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, verify-gate fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        'The verify gate failed. Make every scoped test pass and fmt clean.',
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

  async function runTigerCheck(label) {
    return await agent(
      [
        '## YOUR TASK (Tiger check — scan, triage, and report)',
        'Run, EXACTLY as given, the mechanical Tiger Style scanner exactly as the CI gate does (tree-wide):',
        '  bash scripts/tiger-check.sh',
        'CI fails on ANY gating row (long-line, long-fn, self-recursion, compound-assert, unbounded-loop)',
        'regardless of NEW/PRE — usize-arch rows are informational and never gate. clean must be true only',
        'if the tree-wide gating total is 0.',
        'The scanner emits TAB-separated violation lines (<rule>\\t<file>:<line>\\t<status>\\t<detail>)',
        'with status NEW or PRE, then a final "SUMMARY total=<N> new=<N>" line. It parses stdout only;',
        'stderr carries human notes. Then TRIAGE the candidates:',
        '  - Confirm the genuine NEW violations.',
        '  - FILTER legitimate dual-use cases that the mechanical scanner cannot judge: a `usize` that',
        '    interfaces a std API (required by the signature it talks to), or a `while (true)` that is',
        '    provably bounded by a break/return guarded by an assert. Move each such candidate into',
        '    `filtered` with the reason; do NOT count it as a NEW violation.',
        'Return TIGER_SCHEMA: new_violations = the confirmed NEW violations (these BLOCK);',
        'preexisting_count = how many PRE rows the scanner reported (reported, not blocking);',
        'filtered = the dual-use candidates you dismissed and why. clean = true iff new_violations is',
        'empty after triage. Read code to adjudicate, but do NOT edit anything — report facts only.',
      ].join('\n'),
      { label, phase: 'Tiger check', model: 'haiku', schema: TIGER_SCHEMA },
    );
  }

  phase('Tiger check');
  let tiger = await runTigerCheck(`tiger-check:${a.utility}#${a.issue}`);
  log(`tiger check: clean=${tiger.clean} new=${(tiger.new_violations || []).length} pre=${tiger.preexisting_count} filtered=${(tiger.filtered || []).length}`);
  let tfix = 0;
  while (!tiger.clean && tfix < GATE_FIX_MAX) {
    tfix += 1;
    const violations = (tiger.new_violations || [])
      .map((v) => `- [${v.rule}] ${v.location}: ${v.detail}`)
      .join('\n');
    log(`tiger check failed (${(tiger.new_violations || []).length} new violations) — re-dispatching implementer.`);
    const timpl = await runImplementer(
      [
        brief,
        '',
        '## YOUR TASK (implementer, Tiger-check fix)',
        taskHeader(),
        '',
        `Your earlier summary: ${implNote}`,
        '',
        'The Tiger Style scanner flagged NEW violations your change introduced. Fix every one below while',
        'keeping all tests green and behavior unchanged:',
        violations || '(no specific lines reported; re-read the scanner output and fix the new violations)',
        '',
        'These are NEW violations only — pre-existing ones are out of scope. If a flagged line is actually a',
        'legitimate dual-use case (a `usize` required by a std API, or a `while (true)` provably bounded by a',
        'break/return guarded by an assert), say so in your summary instead of contorting the code; the Tiger',
        'check will re-triage. If a fix would require changing a WRONG test, return outcome=needs_test_change',
        'with instructions instead. Otherwise fix the code and set outcome=done. Do NOT commit.',
      ].join('\n'),
      `implementer:${a.utility}#tfix${tfix}`,
      'Tiger check',
      brief,
    );
    testsChangedDuringGreen = testsChangedDuringGreen || timpl.tests_changed;
    implNote = timpl.result.summary;
    tiger = await runTigerCheck(`tiger-check:${a.utility}#${tfix}`);
    log(`tiger check (after fix ${tfix}): clean=${tiger.clean} new=${(tiger.new_violations || []).length} pre=${tiger.preexisting_count} filtered=${(tiger.filtered || []).length}`);
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
        '## YOUR TASK (code-reviewer)',
        taskHeader(),
        '',
        `Review the fix in ${(a.impl_files || []).join(', ')} (diff against HEAD): correctness against the`,
        'pinned GNU behavior, minimality (root cause, not a special case around the tests), resource',
        'management, error handling on adjacent paths, and Tiger Style compliance.',
        'Judge BY READING AND REASONING ONLY. Do NOT run the test suite, the privileged suite, integration',
        'tests, or any build — a dedicated verify gate already proved the code green, and re-running those',
        'here only burns wall-clock. If you suspect a behavior is wrong, cite the specific code and the',
        'test that should have caught it as an issue instead of running anything.',
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

  const fullItCmd = a.full_it_cmd || 'just it';
  phase('Final verify');
  const finalCheck = await agent(
    [
      '## YOUR TASK (final verify — FULL suite on BOTH platforms, run and report only)',
      'Run all suites EXACTLY as given (this is the once-only authoritative gate):',
      `  - macOS full unit:        "${a.test_cmd}"`,
      `  - macOS full privileged:  "${a.privileged_test_cmd}"`,
      `  - macOS full integration: "${fullItCmd}"`,
      `  - Linux full unit:        "${a.linux_prefix} zig build test"`,
      `  - Linux scoped integration: "${a.linux_prefix} zig build" then "${a.linux_prefix} bash tests/integration.sh ${a.utility}"`,
      'Pipe verbose output through `tail`. Report facts only: unit_pass, privileged_pass,',
      'integration_pass, linux_unit_pass, linux_integration_pass. The full runs cover the whole suite so',
      'a shared/common change that broke another utility is caught.',
    ].join('\n'),
    { label: `final-verify:${a.utility}#${a.issue}`, phase: 'Final verify', model: 'haiku', schema: FINAL_SCHEMA },
  );
  const finalAllPass =
    !!finalCheck &&
    finalCheck.unit_pass &&
    finalCheck.privileged_pass &&
    finalCheck.integration_pass &&
    finalCheck.linux_unit_pass &&
    finalCheck.linux_integration_pass;
  log(`final verify: unit=${finalCheck && finalCheck.unit_pass} priv=${finalCheck && finalCheck.privileged_pass} it=${finalCheck && finalCheck.integration_pass} linux_unit=${finalCheck && finalCheck.linux_unit_pass} linux_it=${finalCheck && finalCheck.linux_integration_pass}`);

  return {
    phase: 'green',
    utility: a.utility,
    issue: a.issue,
    impl_summary: implNote,
    tests_changed_during_green: testsChangedDuringGreen,
    verify_gate: verify,
    tiger_check: tiger,
    code_review: codeReview,
    final_verify: finalCheck,
    final_all_pass: finalAllPass,
    ready_to_commit_green:
      !!(verify && verify.unit_pass && verify.integration_pass && verify.lint_clean) &&
      !!(tiger && tiger.clean) &&
      codeReview.assessment === 'APPROVED' &&
      finalAllPass,
  };
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
log(`tdd-bugfix: ${a.utility || '(no utility)'} #${a.issue || '?'} phase=${phaseArg}`);
const result = phaseArg === 'green' ? await runGreen() : await runRed();
return result;
