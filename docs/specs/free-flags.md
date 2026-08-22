# free - Flag Coverage

`free` is not a POSIX utility. It does not exist on macOS
or OpenBSD. It is a Linux procps utility. The vibeutils
implementation is cross-platform.

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -b | -- | -- | -- | n/a | yes | KEEP |
| -k | -- | -- | -- | n/a | yes | KEEP |
| -m | -- | -- | -- | n/a | yes | KEEP |
| -g | -- | -- | -- | n/a | yes | KEEP |
| -h | -- | -- | -- | n/a | yes | KEEP |
| -t | -- | -- | -- | n/a | yes | KEEP |
| -w | -- | -- | -- | n/a | yes | KEEP |
| -s N | -- | -- | -- | n/a | yes | KEEP |
| -c N | -- | -- | -- | n/a | yes | KEEP |
| --si | -- | -- | -- | n/a | -- | WONT |
| --color=WHEN | -- | -- | -- | n/a | yes | KEEP |
| --bar=WHEN | -- | -- | -- | n/a | yes | KEEP |

Note: GNU column is marked n/a because the GNU (procps)
version is Linux-only and serves as the de facto reference
rather than a separate competing implementation.
