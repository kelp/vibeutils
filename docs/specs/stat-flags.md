# stat - Flag Coverage

stat is not a POSIX utility. macOS and OpenBSD share a BSD
interface; GNU uses a different interface. The vibeutils
implementation follows the GNU interface.

Note: `-f` and `-t` have different meanings in BSD vs GNU.
BSD `-f format` is a format string; GNU `-f` means
file-system mode. BSD `-t timefmt` sets time format; GNU
`-t` means terse output.

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
