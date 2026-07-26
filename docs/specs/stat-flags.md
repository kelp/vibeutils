# stat - Flag Coverage

stat is not a POSIX utility. macOS and OpenBSD share a BSD
interface; GNU uses a different interface. The vibeutils
implementation follows the GNU interface.

## Interface choice

`stat` is the only utility in this repo where BSD and GNU
assign different meanings to the same flag letter. The
collision set is exactly `{-f, -t}`. Resolution (issue #93):

- **GNU stays primary.** `-f` is `--file-system` and `-t`
  is `--terse`, as in GNU coreutils. GNU `stat -c` is the
  spelling that appears in scripts, containers, and CI, and
  `-c`/`--format` already covers everything BSD `-f` does,
  so the BSD spelling would add ambiguity and no capability.
- **The seven non-colliding BSD flags are implemented.**
  `-F -l -n -q -r -s -x` are unused by GNU stat, so they
  carry BSD semantics here with no ambiguity.
- **BSD `-f format` and `-t timefmt` are declined** (WONT,
  below). Both GNU meanings have unambiguous long forms
  (`--file-system`, `--terse`), so nothing is lost.
- **No platform-conditional semantics.** Making a flag mean
  different things per build target would make
  cross-platform scripts unwritable, and is the "invent
  custom behavior / silently degrade" failure mode
  `CLAUDE.md` prohibits.

The divergence is documented where a surprised user lands:
`stat --help` and `stat(1)`. See the CAVEATS section of
`man/man1/stat.1`.

Because `-f format` is declined, the BSD format-directive
language is not reachable from user input. The BSD display
modes are therefore fixed renderings equivalent to the
FreeBSD preset format strings, not a general format engine.

## Shared flags (same semantics across BSD and GNU)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -L | yes | yes | yes | yes | MUST |

## BSD-only flags (macOS/OpenBSD interface)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -F | yes | yes | - | yes | MUST |
| -l | yes | yes | - | yes | MUST |
| -n | yes | yes | - | yes | MUST |
| -q | yes | yes | - | yes | MUST |
| -r | yes | yes | - | yes | MUST |
| -s | yes | yes | - | yes | MUST |
| -x | yes | yes | - | yes | MUST |

`-l`, `-r`, `-s` and `-x` are mutually exclusive whole-output
display modes, not independent toggles; combining two is an
error. `-F` selects the `-l` rendering with `ls -F` type
suffixes appended, so it combines with `-l` and conflicts
with the others. `-n` and `-q` are independent toggles that
combine with everything.

## Declined BSD flags (letter collision with GNU)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -f format | yes | yes | - | - | WONT |
| -t timefmt | yes | yes | - | - | WONT |

- **`-f format`** — the letter is GNU `--file-system` here.
  BSD `stat -f FORMAT` is spelled `stat -c FORMAT` in this
  implementation, which is capability-equivalent.
- **`-t timefmt`** — the letter is GNU `--terse` here. BSD
  `-t` supplies a strftime format for the time fields of the
  BSD display modes; those modes use the BSD default time
  format, and there is no vibeutils spelling for overriding
  it.

## GNU-only flags

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -c / --format | - | - | yes | yes | SHOULD |
| -f / --file-system | - | - | yes | yes | SHOULD |
| -t / --terse | - | - | yes | yes | SHOULD |
| --cached | - | - | yes | - | WONT |
| --printf | - | - | yes | yes | SHOULD |
