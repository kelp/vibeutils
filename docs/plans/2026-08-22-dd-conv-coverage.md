# Slice: dd MUST-tier conv= Integration Coverage

## Slice name

`### 6. dd MUST-tier conv= Integration Coverage`

One heading, one PR. Nested boxes under that heading
belong here. Do not pull `### 5` main() coverage,
`## Bugs` (`ls` pipe columns), leftover `du` color,
`### 6. Progress Feedback` for `cp`/`mv`/`dd`,
`### 1` fd-mode, `### 2` POSIX I/O, or `### 3` TestDir.

## Predecessor gate (recorded deviation)

Listed Testing Improvements order would wait for `### 5`
(PR #195) to land on `main`. This environment cannot
merge. Branch from `github/main` (`a41eccd`).

`TODO.md` / `CHANGELOG.md` will conflict with stacked
slices; rebase after predecessors land. Do **not** stack
on #177 (`dd.zig` `--` delimiter), #192, #193, #194, or
#195. Do **not** source or copy `tests/lib/fd_modes.sh`
or `tests/lib/posix_io.sh`. Do **not** edit `src/dd.zig`
in this slice unless a locked test fails for a real
production bug (then only the implementer, after RED).

## Classification

Characterization coverage of **existing** `dd` behavior
on the compiled binary. Closed PR #34 already described
the missing cases; later audit waves hardcoded GNU hex
for swab/block/ibm/sync+block and added strong
`conv=noerror` tests (issues #44 / #59). This slice
finishes the three TODO boxes. It does not change
user-visible behavior, flags, or man pages. No
`CHANGELOG` bullet.

Live characterization against `zig-out/bin/dd` on
`github/main` (`a41eccd`) already matches every locked
assertion below. Tests are expected **GREEN** on
unmodified production. Teeth come from uncommitted
**production** sabotage, not compile-error RED and not
inverted test expectations.

## Round-1 review decisions

Grok APPROVE. Sol REQUEST CHANGES. Fable REQUEST
CHANGES (one blocking item). Recorded here so the
delta is reviewable.

1. **Spec matrix vs Box 3 rejections.** Sol asked to
   stop and run spec-first approval because
   `docs/specs/dd-flags.md` lists `files=` MUST /
   Ours=yes and `sparse`/`par*` SHOULD / Ours=yes
   while cc57c2a rejects them. Grok and Fable both
   treat Box 3 as characterization of shipped
   `runDd` and forbid a matrix edit without user
   approval. Decision: **keep Box 3**. The TODO box
   text is the cross-check against cc57c2a. Editing
   the matrix is a different, spec-first slice
   (`land-todo-slice` §2). Do not implement `files=`
   or `sparse`. Do not edit `dd-flags.md`.
2. **`conv=fsync` must observe the syscall path.**
   Sol: a regular-file copy still passes if
   `runDd_finish_sync` is skipped. Decision:
   **replace** the regular-file smoke with the
   existing pipe-failure pattern (issue #43
   `conv=fdatasync` on a pipe). Live binary:
   `conv=fsync` to a pipe exits **1** and prints
   `dd: fsync failed for 'standard output': Invalid
   argument`. That RED's if `finish_sync` is bypassed
   (pipe copy would then exit 0). The existing
   `conv=fdatasync,fsync` combo already copies a
   regular file; do not duplicate that smoke.
3. **Case 2 must not use `$(cat)`.** Fable: bash
   command substitution drops NUL bytes, so
   `ABCD` + padding NULs still equals `ABCD`.
   Decision: pin **size 4** and hex `41424344`.
4. **Sabotage mutates production, one per assertion
   shape.** Sol: inverting an expected exit is not
   mutation testing; every new case needs teeth.
   Fable: prefer production mutation; one sabotage
   per distinct assertion shape. Decision: uncommitted
   edits to `src/dd.zig` (or the invocation's
   production path) only. Restore before commit.
   Do **not** invert test assertions. Shapes listed
   under Tests.

## In scope

The three TODO boxes.

### Box 1 — replace macOS `/usr/bin/dd` comparisons

`tests/utilities/dd_test.sh` on `github/main` already
contains **zero** `/usr/bin/dd` invocations (verified
`grep`). Later commits replaced PR #34's five
`cmp` against macOS `dd` with hardcoded GNU hex
(swab odd-length, sync+block, ibm vs ebcdic, block,
unblock).

This box is a **verify-and-check** item:

- Test-writer: `grep -n '/usr/bin/dd' tests/utilities/dd_test.sh`
  must print nothing. Do **not** rewrite the already-
  hardcoded cases. Do **not** add a new comparison to
  any host `dd`.
- Implementer: check the box in `TODO.md` after that
  grep is clean on the branch.

### Box 2 — add the missing MUST-tier behavioral cases

These cases are **absent** from `dd_test.sh` today.
Unit tests in `src/dd.zig` cover some of them via
`runDd`; this slice pins the **compiled binary**.

Add exactly these eight cases, hardcoded GNU-equivalent
values, using `$binary` (already `$BIN_DIR/dd`),
`status=none` except where noted, and `od -A n -t x1`
hex with spaces/newlines stripped (`tr -d ' \n'`),
matching the existing suite. **Never** compare binary
payloads with `$(cat)` / `[[ == ]]` — bash drops NULs.

1. **`conv=sync` NUL-pads a short block.**
   `printf 'AB'` , `bs=4 conv=sync count=1` → hex
   `41420000`.
2. **`conv=sync` leaves a full block unchanged.**
   `printf 'ABCD'` , `bs=4 conv=sync count=1` →
   `get_file_size` **4** and hex `41424344`.
   Do not use `$(cat)`.
3. **Default truncate contrast** (pairs with the
   existing `conv=notrunc preserves existing data`
   case). Pre-fill 20 `X` bytes, copy `HI` without
   `notrunc` → output size **2**.
4. **`conv=fsync` on a pipe reports the syscall.**
   Match `dd conv=fdatasync on pipe does not panic`
   (`tests/utilities/dd_test.sh`):
   `"$binary" if=/dev/zero count=1 conv=fsync status=none 2>"$err" | cat >/dev/null`
   then `PIPESTATUS[0]` is **1**, stderr has no
   `panic`, and stderr matches `fsync failed`
   (GNU wording on this host: `dd: fsync failed for
   'standard output': Invalid argument`). Never
   exit `>= 128`. This is the locked standalone
   `fsync` case — not a regular-file copy.
5. **`conv=osync` pads the final output block.**
   `printf 'AB'` , `ibs=2 obs=4 conv=osync` → size 4,
   hex `41420000`.
6. **`conv=ascii` standalone.** Input byte `0xC1`
   (`printf '\xC1'`) → hex `41` (do not `$(cat)`
   even for a one-byte ASCII result).
7. **`conv=ebcdic` standalone.** Input `A` → hex `c1`.
8. **`conv=ibm` standalone.** Input `!` → hex `5a`.
   (The existing `^` ibm-vs-ebcdic contrast stays;
   this pins a byte that both tables map the same.)

Do **not** add PR #34's weak `conv=noerror accepted`
exit-code-only case. Issues #44 and #59 already pin
`conv=noerror` termination, `conv=noerror,sync`
accounting, and genuine short-read `conv=sync`
record counts. Box 2's `conv=noerror` line is
satisfied by those existing tests plus this
cross-check: the new block must not delete or
weaken them. The implementer commit message must
cite those three existing test names as the
coverage for the `conv=noerror` checkbox.

Place the new cases in one comment-delimited block
at the end of `test_dd()`, after the issue #65
suffix tests and before the closing `}` of
`test_dd`. Header:

```
# MUST-tier conv= coverage (TODO ### 6)
```

Use `print_test_result` names:

- `dd conv=sync pads short block with NUL`
- `dd conv=sync full block unchanged`
- `dd default truncates output file`
- `dd conv=fsync on pipe reports fsync failure`
- `dd conv=osync pads final output block`
- `dd conv=ascii converts EBCDIC to ASCII`
- `dd conv=ebcdic converts ASCII to EBCDIC`
- `dd conv=ibm converts ASCII to IBM EBCDIC`
- `dd rejects conv=sparse`
- `dd rejects conv=pareven`
- `dd rejects conv=parnone`
- `dd rejects conv=parodd`
- `dd rejects conv=parset`
- `dd rejects files=`

Do not use `timeout N`; if a hang bound is needed,
use `run_with_limit` from `tests/lib/common.sh`
(already loaded). Cases 1–3 and 5–8 call `$binary`
directly. Case 4 uses the pipe pattern above (finite
`count=1` from `/dev/zero`). Box 3 uses
`if=/dev/null`.

### Box 3 — cross-check cc57c2a rejection tests

Commit `cc57c2a` added Zig unit tests that `runDd`
rejects unimplemented `conv=sparse`,
`conv=par{even,none,odd,set}`, and `files=` with
exit 1 and a diagnostic naming the operand. Those
unit tests stay. This box adds the same six
assertions against the **compiled binary** so a
parser-only `runDd` test cannot drift from
`utilityMain`.

Live binary on `github/main`:

```
dd: unsupported operand 'sparse' (not implemented)
```

(and `'pareven'`, `'parnone'`, `'parodd'`,
`'parset'`, `'files'`). Exit code **1**.

Add six cases in the same TODO ### 6 block:

| operand | stderr must contain |
|---|---|
| `conv=sparse` | `unsupported operand 'sparse'` |
| `conv=pareven` | `unsupported operand 'pareven'` |
| `conv=parnone` | `unsupported operand 'parnone'` |
| `conv=parodd` | `unsupported operand 'parodd'` |
| `conv=parset` | `unsupported operand 'parset'` |
| `files=3` | `unsupported operand 'files'` |

Each case: `if=/dev/null of=/dev/null status=none`,
capture stderr, pin exit code **1** and the needle.
Do not assert the full sentence beyond the
`unsupported operand '…'` needle — the
`(not implemented)` suffix may move; the operand
name must not.

Do **not** implement `files=` or `conv=sparse`.
`docs/specs/dd-flags.md` still lists `files=` as
MUST / Ours=yes and `sparse` as SHOULD / Ours=yes;
cc57c2a made the binary reject them. Correcting
that matrix is a spec-first slice and needs user
approval (`land-todo-slice` §2). This slice records
the mismatch and tests the **rejection** the code
actually ships.

## Out of scope

- Any edit to `src/dd.zig` unless a locked test
  fails on unmodified HEAD for a real bug.
- `docs/specs/dd-flags.md`, man page, help text.
- Implementing `files=`, `conv=sparse`, `par*`,
  `fillchar=`, `iflag=`, `oflag=`, `oldascii`.
- SHOULD-tier conv values beyond the rejection
  cross-check.
- Rewriting existing hardcoded swab / block /
  unblock / ibm-contrast / noerror tests.
- `CHANGELOG.md`.
- `docs/TESTING_STRATEGY.md`.
- Progress bars for `dd` (`### 6. Progress Feedback`).
- PR #177 `--` end-of-options behavior.

## Spec impact

No change. GNU remains the behavioral reference
for flags that exist in GNU (`conv=sync`,
`notrunc`, `fsync`, `ascii`, `ebcdic`, `ibm`).
`conv=osync` is macOS/OpenBSD MUST (not GNU);
pin the live vibeutils/OpenBSD-shaped padding
already implemented (`ibs=2 obs=4` → 4 NUL-padded
bytes), which matches the unit test
`runDd - conv=osync pads final block`.

## Tests

Characterization TDD, **not** compile-error RED.

1. Test-writer commit 1: add the eight Box 2 cases
   and six Box 3 cases to `tests/utilities/dd_test.sh`.
   Do not touch `src/dd.zig`. Do not check TODO
   boxes. `just it-util dd` is GREEN on unmodified
   production.
2. Prove teeth with **uncommitted production**
   sabotage in `src/dd.zig`, then restore the file
   (do not `git checkout --` a dirty mix of other
   edits). One sabotage per assertion shape. Do
   **not** invert test expectations.

   | Shape | Cases | Uncommitted production mutation | RED signal |
   |---|---|---|---|
   | short-block NUL pad hex | 1 | skip the `conv_sync` pad when `bytes_read < ibs` | hex is `4142`, not `41420000` |
   | full-block exact hex+size | 2 | pad even when `bytes_read == ibs` (or always pad +4) | size ≠ 4 or hex ≠ `41424344` |
   | truncate size | 3 | force `conv_notrunc = true` after parse | size stays 20 |
   | fsync syscall on pipe | 4 | skip `runDd_finish_sync` (always success) | `PIPESTATUS[0]` is 0 |
   | osync tail pad hex+size | 5 | skip osync pad of a short final block | size 2, hex `4142` |
   | charset table hex | 6–8 | skip `applyConversions` | ascii hex ≠ `41` |
   | rejection rc+needle | Box 3 | `findUnsupportedOperand` returns null | `conv=sparse` exits 0 |

3. Implementer commit: check the three `TODO.md`
   boxes. Commit message cites
   `dd conv=noerror terminates on persistent read error`,
   `dd conv=noerror,sync count= bounds read-error retries`,
   and
   `dd conv=noerror,sync counts synthesized blocks as partial in`
   as the coverage for the `conv=noerror` line.
   Do not edit `dd_test.sh`. Do not edit
   `docs/TESTING_STRATEGY.md`.

The integration runner already picks up
`tests/utilities/dd_test.sh` via binary-name
matching. No new hook file. No
`tests/tools/` helper.

## TDD ownership

- Test-writer owns `tests/utilities/dd_test.sh`.
- Implementer owns `TODO.md` box checks.
- Implementer must not author or alter the
  guarding tests.

## Risks

- **macOS `/usr/bin/dd`:** never invoke it. CI
  macOS has BSD `dd` without GNU `conv=swab` /
  EBCDIC tables; that is why PR #34 went RED on
  `cmp`. Hardcoded hex only.
- **NUL-safe comparisons:** `$(cat)` and bash
  `[[ == ]]` drop NUL bytes. Pin size + `od` hex
  for any payload that might contain `0x00`.
- **Filter stdin hangs:** these cases use `if=`
  files or `/dev/null`, not a blocking stdin
  read. Case 4 reads `/dev/zero` with `count=1`.
- **`printf '\xC1'`:** bash 4+; the suite already
  requires bash 4. Characterized on this host.
- **Hex case:** `od -t x1` emits lowercase
  (`c1`, `5a`, `41`). Pin lowercase.
- **Pipe `PIPESTATUS`:** case 4 must read
  `${PIPESTATUS[0]}` immediately, like the
  existing fdatasync pipe test.
- **`src/common/`:** no new modules. No
  `build.zig` edit.
- **Tiger Style:** no new Zig in the happy path.
  If an unexpected production bug forces a
  `src/dd.zig` fix, implementer follows Tiger
  caps (70 lines, no recursion, two asserts).
- **Privilege:** none of these cases need
  fakeroot.
- **`files=` spec lie:** do not "fix" it here.

## Files

| File | Who | What |
|---|---|---|
| `docs/plans/2026-08-22-dd-conv-coverage.md` | planner | this plan |
| `tests/utilities/dd_test.sh` | test-writer | eight + six cases |
| `TODO.md` | implementer | check three boxes |

## Stop condition

- `grep '/usr/bin/dd' tests/utilities/dd_test.sh` empty
- `just it-util dd` green (including the new names)
- Three TODO boxes checked in the implementer commit
- `dd_test.sh` untouched by the implementer
- `src/dd.zig` and `docs/specs/dd-flags.md` untouched
  unless a locked test exposed a real bug
