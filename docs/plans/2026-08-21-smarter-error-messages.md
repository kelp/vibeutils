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

## In scope

The two TODO boxes:

1. Permission denied with an actionable hint.
2. Directory not empty with an `rm -r` suggestion.

Utilities: `rm`, `rmdir`, `cp`, and `cat` (the design
doc’s starting set, plus `rmdir` because that is where
`DirNotEmpty` is the primary user-facing error).

### When to hint

Gate on **process stderr** being a TTY
(`common.env.isTty(std.Io.File.stderr().handle)`), the
same check `cp` already uses for overwrite hints. No
hint when stderr is a pipe, file, or `TERM=dumb` is
irrelevant here — dumb terminals are still TTYs; still
hint, without requiring color.

Do not hint when `geteuid() == 0` (root bypasses DAC;
the message would be wrong). Skip that case in tests
with `error.SkipZigTest`.

### Wording (KEEP)

Keep the existing GNU-shaped first clause intact. Append
one parenthetical on the same line. Do not emit a second
`prog: hint:` line (`printHintWithProgram` stays for the
existing overwrite hints only).

| Error | Condition | Suffix |
| --- | --- | --- |
| `DirNotEmpty` | `rm` / `rmdir` (including `rm -d`) | ` (use rm -r to remove recursively)` |
| `AccessDenied` on a path we own whose owner-write bit is off, and the failing op needs write (unlink, rmdir, truncate/create) | `(file is not writable)` |
| `AccessDenied` on a path we own whose owner-read bit is off, and the failing op needs read (`cat`, `cp` source) | `(file is not readable)` |

If `lstat` fails, or the uid is not ours, or the mode
bit that matches the operation is already set (so the
denial is a parent directory / ACL / other cause), print
the GNU line **with no suffix**. Wrong hint is worse than
none.

Examples:

```
rmdir: failed to remove 'src': Directory not empty (use rm -r to remove recursively)
rm: cannot remove 'readonly.txt': Permission denied (file is not writable)
cat: secret.txt: Permission denied (file is not readable)
```

Non-TTY (unit Allocating writer, pipes, integration
without a pty):

```
rmdir: failed to remove 'src': Directory not empty
```

### Code shape

Do not add a new `src/common/` module. Add a small helper
next to `printErrorWithProgram` in `src/common/lib.zig`:

- `pub fn actionableHint(err: anyerror, path: []const u8, op: HintOp) ?[]const u8`
  returns a static suffix or null. `HintOp` is
  `.read` or `.write`. `DirNotEmpty` ignores `op`.
- Ownership/mode uses `common.file.FileInfo.lstat` and
  `std.c.geteuid()`. Copy nothing that a later libc call
  can clobber; uid is an integer.

Callers (`rm`, `rmdir`, `cp`, `cat`) keep their current
format strings. After composing the GNU line they append
`hint orelse ""` only when stderr is a TTY.

Do not change `posixErrorString`. Do not change
`printErrorWithProgram` to auto-append hints (that would
leak into every utility).

### Tests (TDD; separate test-writer; all new behavior RED)

Assert emitted stderr and exit codes. Existing exact-match
tests that run with a non-TTY process stderr stay valid
because hints are TTY-gated on **process** stderr, not the
test writer. Cloud CI stderr is typically not a TTY.

To pin the positive TTY case without depending on the
runner, add a test-only overlay on `common.env` analogous
to `test_overrides`:

- `pub var test_stderr_tty: ?bool = null` (test builds
  only). `isTty` returns it when non-null.
- Unit tests stage `.true` / `.false` and restore.

Tests:

1. `rmdir DIR` on a non-empty dir, overlay false: exact
   GNU line, no `(`; exit 1.
2. Same, overlay true: GNU line plus
   ` (use rm -r to remove recursively)`; exit 1.
3. `rm -d DIR` on a non-empty dir, overlay true: same
   suffix on rm’s `cannot remove` line.
4. Owned `chmod 000` file, `rm` without `-f` overlay
   true: Permission denied plus
   `(file is not writable)`. Overlay false: no suffix.
   Skip if `geteuid() == 0`.
5. Owned `chmod 000` file, `cat` overlay true:
   `(file is not readable)`. Skip if root.
6. `AccessDenied` on a path we do **not** own (or whose
   owner-write bit is already on): overlay true, **no**
   suffix. Skip if we cannot construct that fixture.
7. Integration `rmdir` / `rm -d` on a non-empty dir
   (piped stderr): no parenthetical. Existing
   `rmdir_test.sh` substring checks stay green.

Do not rewrite existing assertions that pin the GNU
prefix.

## Out of scope

- `### 6` progress bars
- `### 4` `du` relative color
- Fuzzy “did you mean” / Levenshtein
- `printHintWithProgram` rewrite
- New flags
- Hints on other utilities (`mv`, `mkdir`, `touch`, …)
- Changing exit codes
- Man-page HISTORY
- `## Bugs` ls-pipe
- Testing-improvement headings

## Spec impact

No flag-matrix edit. This is KEEP house wording on
existing diagnostics. Mention in `CHANGELOG.md`
Unreleased. Check both boxes under `### 7`. Optional
one-line note in `man/man1/rm.1` and `man/man1/rmdir.1`
that TTY stderr may append a suggestion; skip if
reviewers prefer changelog-only.

## Risks

- Filter-stdin: none.
- Privileged: permission tests must skip as root
  (`geteuid() == 0`).
- macOS: `st_uid` compare uses the integer; no
  `getpwuid` string. Mode bits via `FileInfo`.
- `src/common/` boundary: helper in `lib.zig` plus a
  test overlay on `env.zig`. No new module.
- Tiger Style: helper under 70 lines; two asserts;
  no recursion. `actionableHint` must not `@panic` on
  user paths.
- Existing tests: TTY-off is the default in CI, so
  exact GNU matches should not break. Overlay restore
  is mandatory in every test (`defer`).
- Wrong hint on `EACCES` from a missing search bit on
  a parent: the lstat-of-the-operand check refuses to
  hint when the operand’s own mode already allows the
  op. If lstat itself gets `AccessDenied`, return null.

## Implementation order after plan consensus

1. Test-writer adds RED unit + integration coverage.
2. Prove RED (missing suffix / unexpected suffix), not
   compile errors.
3. Separate implementer lands the helper and call sites.
4. `just fmt-check`, `zig build test -Dtest-util=rm`,
   `-Dtest-util=rmdir`, `-Dtest-util=cp`, `-Dtest-util=cat`,
   `just it-util rmdir`, `just it-util rm`,
   `scripts/audit-check.sh`, `scripts/tiger-check.sh --base github/main`.
