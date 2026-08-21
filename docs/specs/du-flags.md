# du - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -a | yes | yes | yes | yes | yes | MUST |
| -H | yes | yes | yes | yes | yes | MUST |
| -k | yes | yes | yes | yes | yes | MUST |
| -L | yes | yes | yes | yes | yes | MUST |
| -s | yes | yes | yes | yes | yes | MUST |
| -x | yes | yes | yes | yes | yes | MUST |
| -c | -- | yes | yes | yes | yes | MUST |
| -d | -- | yes | yes | yes | yes | MUST |
| -h | -- | yes | yes | yes | yes | MUST |
| -P | -- | yes | yes | yes | yes | MUST |
| -r | -- | yes | yes | -- | yes | MUST |
| -A | -- | yes | -- | yes | yes | SHOULD |
| -B | -- | yes | -- | yes | yes | SHOULD |
| -g | -- | yes | -- | -- | yes | SHOULD |
| -I | -- | yes | -- | -- | yes | SHOULD |
| -l | -- | yes | -- | yes | yes | SHOULD |
| -m | -- | yes | -- | yes | yes | SHOULD |
| -n | -- | yes | -- | -- | yes | SHOULD |
| -t | -- | yes | -- | yes | yes | SHOULD |
| -0 | -- | -- | -- | yes | -- | WONT |
| -b | -- | -- | -- | yes | yes | SHOULD |
| -D | -- | -- | -- | yes | -- | WONT |
| -S | -- | -- | -- | yes | yes | SHOULD |
| -X | -- | -- | -- | yes | -- | WONT |
| --si | -- | yes | -- | yes | yes | SHOULD |
| --apparent-size | -- | -- | -- | yes | yes | SHOULD |
| --block-size | -- | -- | -- | yes | yes | SHOULD |
| --color | -- | -- | -- | -- | yes | KEEP |
| --exclude | -- | -- | -- | yes | -- | WONT |
| --exclude-from | -- | -- | -- | yes | -- | WONT |
| --files0-from | -- | -- | -- | yes | -- | WONT |
| --icons | -- | -- | -- | -- | yes | KEEP |
| --inodes | -- | -- | -- | yes | -- | WONT |
| --time | -- | -- | -- | yes | -- | WONT |
| --time-style | -- | -- | -- | yes | -- | WONT |

KEEP default (not a flag): bare `du` prints 1024-based human-readable
sizes, matching `df`. `-k` / `-m` / `-g` / `-b` / `--block-size`
restore numeric counts. GNU flag semantics are unchanged.
