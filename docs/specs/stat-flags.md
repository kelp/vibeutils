# stat - Flag Coverage

stat is not a POSIX utility. macOS and OpenBSD share a BSD
interface; GNU uses a different interface. Per the project
conflict rule (see `docs/DESIGN_PHILOSOPHY.md`), where the
two assign different meanings to the same spelling we
follow BSD — so the vibeutils implementation is the **BSD
interface**, on every platform.

`-f` and `-t` are the collisions: BSD `-f format` is a
format string while GNU `-f` means file-system mode, and
BSD `-t timefmt` sets the time format while GNU `-t` means
terse output. Both resolve to BSD.

GNU's long spellings are kept, because a long option is
not a collision. `-f` is therefore **not** an alias of
`--file-system`, and `-t` is **not** an alias of
`--terse`. Two directive languages coexist, selected by
the flag that introduced the format string: `-c` /
`--format` / `--printf` parse GNU directives, `-f` parses
BSD ones.

Authoritative specs are vendored beside this file:
`stat-macos.txt` (full man page including the FORMATS
grammar), `stat-openbsd.txt`, `stat-gnu.txt`.

## Shared flags (same semantics across BSD and GNU)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -L | yes | yes | yes | yes | MUST |

## BSD-only flags (macOS/OpenBSD interface)

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -F | yes | yes | - | yes | MUST |
| -f format | yes | yes | - | yes | MUST |
| -l | yes | yes | - | yes | MUST |
| -n | yes | yes | - | yes | MUST |
| -q | yes | yes | - | yes | MUST |
| -r | yes | yes | - | yes | MUST |
| -s | yes | yes | - | yes | MUST |
| -t timefmt | yes | yes | - | yes | MUST |
| -x | yes | yes | - | yes | MUST |

## GNU-only flags

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -c / --format | - | - | yes | yes | SHOULD |
| --file-system | - | - | yes | yes | SHOULD |
| --terse | - | - | yes | yes | SHOULD |
| --cached | - | - | yes | - | WONT |
| --printf | - | - | yes | yes | SHOULD |

GNU's short `-f` and `-t` are **not** implemented as GNU
spells them; those letters carry their BSD meanings. The
GNU behavior remains reachable through the long options
above.
