# stat - Flag Coverage

stat is not a POSIX utility. macOS and OpenBSD share a BSD
interface; GNU uses a different interface. The vibeutils
implementation follows the GNU interface.

Note: `-f` and `-t` have different meanings in BSD vs GNU.
BSD `-f format` is a format string; GNU `-f` means
file-system mode. BSD `-t timefmt` sets time format; GNU
`-t` means terse output.

### The `-f` collision (#79)

Because a Homebrew install can put vibeutils `stat` ahead of
`/usr/bin/stat`, a BSD script's `stat -f FORMAT` silently
becomes "file-system status of a file named FORMAT" — same
flag, different meaning, and no error at all unless an
operand happens to be missing.

vibeutils does **not** make `-f` platform-adaptive. GNU
semantics are identical on every platform we ship; a flag
whose meaning depends on the host is worse than one that is
merely different from BSD's. We also do not turn the misuse
into an exit-2 error, because that would break GNU parity
for anyone legitimately running `stat -f` on a path that
does not exist.

Instead `stat` prints one extra `stat: hint: ...` line on
stderr when `-f` is given without `-c`/`--printf` and an
operand that reads as a format string names no existing
file. Exit status and stdout are byte-for-byte unchanged, so
GNU parity is fully preserved. Translations:

- BSD `stat -f FORMAT` → `stat -c FORMAT`
- BSD `stat -t TIMEFMT` → no equivalent; our `-t` is GNU's
  terse output

The divergence is also documented in the man page (CAVEATS)
and in `stat --help`.

## Shared flags (same semantics across BSD and GNU)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -L | yes | yes | yes | yes | MUST |

## BSD-only flags (macOS/OpenBSD interface)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -F | yes | yes | - | - | MUST |
| -f format | yes | yes | - | - | MUST |
| -l | yes | yes | - | - | MUST |
| -n | yes | yes | - | - | MUST |
| -q | yes | yes | - | - | MUST |
| -r | yes | yes | - | - | MUST |
| -s | yes | yes | - | - | MUST |
| -t timefmt | yes | yes | - | - | MUST |
| -x | yes | yes | - | - | MUST |

## GNU-only flags

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -c / --format | - | - | yes | yes | SHOULD |
| -f / --file-system | - | - | yes | yes | SHOULD |
| -t / --terse | - | - | yes | yes | SHOULD |
| --cached | - | - | yes | - | WONT |
| --printf | - | - | yes | yes | SHOULD |
