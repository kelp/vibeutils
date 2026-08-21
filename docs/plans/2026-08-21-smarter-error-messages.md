# Slice: smarter error messages

## Slice name

`### 7. Smarter Error Messages`

One heading, one PR. Nested boxes under that heading
belong here. Do not pull `### 6. Progress Feedback`,
`### 4. Color-Coded Numeric Output`, testing-improvement
headings, `## Bugs`, or design-doc extras that the TODO
does not name (fuzzy “did you mean”, `diff`).

## Predecessor gate (recorded deviation)

Listed order would take `### 6` next (progress for
`cp`/`mv`/`dd`). That heading adds a `src/common/`
progress module and edits `src/dd.zig`, which open PR
#177 also edits. This environment cannot merge. Branch
from `github/main` (`a41eccd`) with the next independent
heading. `TODO.md` / `CHANGELOG.md` will still conflict;
rebase after predecessors land. Do not stack on #177 or
#189. `### 4` (`du` color) still waits on #189.

## Classification

Diagnostics only. Not a stdin filter. Hints are TTY-only
and must not change exit codes or the GNU prefix that
scripts parse.

`docs/plans/2026-03-01-modern-features-design.md`
Feature 6 is background. The TODO boxes win when they
are narrower: only permission-denied and directory-not-empty
hints. Do not implement Levenshtein “did you mean”.

Wrong hint is worse than none.

## In scope

The two TODO boxes:

1. Permission denied with an actionable hint.
2. Directory not empty with an `rm -r` suggestion.

Utilities: `rm`, `rmdir`, `cp`, and `cat`.

### When to hint

Use a **hint seam**, not `isTty` itself:

```zig
pub fn stderrHintsEnabled() bool
```

Production: `common.env.isTty(std.Io.File.stderr().handle)`.
Do not copy `std.c.isatty` (`cp` overwrite still uses
that; leave it). `TERM=dumb` does not suppress hints
(dumb is still a TTY).

Test builds: default **off**, ignoring the process TTY,
unless `common.env.test_stderr_hints == true`. This is
**not** an `isTty` overlay. Color
(`stderrSupportsColor` → `isTty`) stays independent, so
exact-match hint tests do not grow ANSI from a flipped
isatty. Overlay applies only to this function, not every
fd.

`geteuid() == 0` suppresses **permission** hints only
(root bypasses DAC). `DirNotEmpty` hints still fire for
root. Permission fixtures `SkipZigTest` when
`geteuid() == 0`. Under fakeroot, euid is 0 and
permission hints stay off; document that, do not special-case
fakeroot.

### Wording (KEEP)

Keep the existing GNU-shaped first clause intact. Append
one parenthetical on the **same** line, including the
leading space. `printErrorWithProgram` always adds `\n`,
so callers pass the suffix inside the format
(`"{s}{s}"`, `.{ gnu_clause, hint orelse "" }`). Do not
print, then append. Do not emit a second `prog: hint:`
line (`printHintWithProgram` stays for overwrite hints).

Exact suffixes (byte-for-byte):

- DirNotEmpty: ` (use rm -r to remove recursively)`
- write-denied on a dest we own: ` (file is not writable)`
- read-denied on a source we own: ` (file is not readable)`

| Error | Who | Condition | Suffix |
| --- | --- | --- | --- |
| `DirNotEmpty` | `rm`, `rmdir` (including `rm -d`) | stderr hints enabled | ` (use rm -r to remove recursively)` |
| `AccessDenied` | `cp` destination (create/truncate/open-write) | hints on, not root, `lstat` ok, `st_uid == euid`, owner-write bit **off** | ` (file is not writable)` |
| `AccessDenied` | `cat` operand or `cp` source (open-read) | hints on, not root, `lstat` ok, `st_uid == euid`, owner-read bit **off** | ` (file is not readable)` |

Do **not** attach a write hint to `rm` / `rmdir`
`AccessDenied`. Unlink and `rmdir(2)` need write+search
on the **parent**, not owner-write on the operand. An
owned `chmod 000` file in a writable directory is
removable; `rm` without `-f` prompts, then deletes.
Hinting `(file is not writable)` on a parent-dir `EACCES`
would be the wrong cause.

If `lstat` fails, uid is not ours, or the mode bit that
matches the **open** already allows the op (denial is
parent / ACL / other), print the GNU line with **no**
suffix.

Examples (hints enabled):

```
rmdir: failed to remove 'src': Directory not empty (use rm -r to remove recursively)
rm: cannot remove 'src': Directory not empty (use rm -r to remove recursively)
cp: cannot create regular file 'readonly.txt': Permission denied (file is not writable)
cat: secret.txt: Permission denied (file is not readable)
```

Pipes / test default (hints off): GNU line only, no `(`.

### Code shape

No new `src/common/` module.

- `src/common/env.zig`: `test_stderr_hints: ?bool = null`
  (test builds) and `stderrHintsEnabled()`. Do not change
  `isTty`’s meaning for other fds. Add two assertions to
  `stderrHintsEnabled` (and to `isTty` if that function is
  touched; today it has none — do not touch it).
- `src/common/lib.zig`: `HintOp { read, write }` and
  `pub fn actionableHint(err: anyerror, path: []const u8, op: HintOp) ?[]const u8`
  returning a static suffix or null. `DirNotEmpty` ignores
  `op`. Ownership/mode via `FileInfo.lstat` + `geteuid()`.
  No `getpwuid`. Under 70 lines, two asserts, no recursion,
  no `@panic` on user paths.
- Call sites: `rm.zig` / `rmdir.zig` **only** for
  `DirNotEmpty`. `cat.zig` / `cp.zig` for `AccessDenied`
  with the matching `HintOp`. Do not grow
  `runCat_processFile` (already 70 lines) or
  `removeFiles_removeOne` (already over) in place —
  extract the diagnostic into a helper under 70 lines.

Do not change `posixErrorString` or make
`printErrorWithProgram` auto-append hints.

### Phased TDD

The overlay and `actionableHint` do not exist yet.
Tests that name them would fail to compile, which is
not a valid RED.

1. **Seam (implementer, behavior-preserving).** Add
   `stderrHintsEnabled` (prod = isTty(stderr); tests =
   overlay or false) and `actionableHint` that always
   returns null. No call-site wiring. Existing suites
   stay GREEN. Prove the overlay with transient sabotage
   (force `true` in a probe that expects no suffix today,
   confirm nothing changes because the helper is unused;
   then a tiny test that `stderrHintsEnabled()` follows
   the overlay). Do not commit the sabotage.
2. **Tests (test-writer).** RED on emitted stderr/exit
   once call sites are expected to append. Fail for
   missing suffix, not compile errors.
3. **Wire (implementer).** Call sites + real
   `actionableHint` logic. Same tests GREEN.

### Tests (after the seam)

Assert emitted stderr and exit codes. Stage
`NO_COLOR=1` in overlay-true tests anyway so a future
color leak cannot break exact match.

1. `rmdir DIR` non-empty, overlay false/default:
   exact GNU line, no `(`; exit 1. Characterization
   of today’s string (sabotage-prove by mutating the
   expected suffix).
2. Same, overlay true: GNU line plus exact
   ` (use rm -r to remove recursively)`; exit 1. This
   is the DirNotEmpty RED.
3. `rm -d DIR` non-empty, overlay true: rm’s
   `cannot remove` line plus the same suffix.
4. **Removed.** Do not test `rm` of `chmod 000` for a
   write hint.
5. Owned `chmod 000` file, `cat`, overlay true:
   `(file is not readable)`; overlay false: no suffix.
   Skip if root.
6. Owned mode-0444 dest, `cp` overwrite/create, overlay
   true: GNU create/open line plus
   `(file is not writable)`; overlay false: no suffix.
   Skip if root.
7. Owned `chmod 000` source, `cp src dest`, overlay
   true: `(file is not readable)`. Skip if root.
8. `AccessDenied` whose operand mode already allows the
   op (writable dest whose **parent** is 555): overlay
   true, **no** suffix. Constructible without a foreign
   uid. Skip if root.
9. Integration `rmdir` / `rm -d` on a non-empty dir
   (piped stderr): no parenthetical.

Do not rewrite existing GNU-prefix assertions.

## Out of scope

- `### 6` progress bars
- `### 4` `du` relative color
- Fuzzy “did you mean”
- `printHintWithProgram` rewrite / `cp` overwrite isatty
- Permission hints on `rm`/`rmdir` `AccessDenied`
- New flags; other utilities (`mv`, `mkdir`, `touch`)
- Exit codes; fakeroot-specific DAC
- `## Bugs` ls-pipe; testing-improvement headings

## Spec impact

No flag-matrix edit. KEEP house wording. `CHANGELOG.md`
Unreleased. Check both `### 7` boxes. One-line
DIAGNOSTICS note in `man/man1/rm.1`, `rmdir.1`, `cp.1`,
and `cat.1` that TTY stderr may append a suggestion.
No HISTORY.

## Risks

- Filter-stdin: none.
- Privileged: permission tests skip as root.
- macOS: integer `st_uid` / mode; no `getpwuid`.
- `src/common/` : helper in `lib.zig`, seam in `env.zig`.
- Tiger: extract before growing 70-line functions.
- Existing tests: default overlay off, so GNU exact
  matches stay. Restore overlay with `defer`.
- Parent `EACCES` vs file mode: test 8 locks the
  no-suffix rule.

## Implementation order after plan consensus

1. Seam commit (implementer).
2. RED tests (test-writer).
3. Wire hints (implementer).
4. `just fmt-check`; `zig build test -Dtest-util=` rm,
   rmdir, cp, cat, and common if `lib.zig`/`env.zig`
   tests live there; `just it-util rmdir`; `just it-util rm`;
   `just it-util cp`; `just it-util cat`;
   `scripts/audit-check.sh`;
   `scripts/tiger-check.sh --base github/main`.
