# realpath - Flag Coverage

No POSIX spec exists for realpath. MUST = in both macOS
and OpenBSD.

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -q   | yes   | yes     | yes | yes  | MUST |
| -e   | no    | no      | yes | yes  | SHOULD |
| -m   | no    | no      | yes | yes  | SHOULD |
| -s   | no    | no      | yes | yes  | SHOULD |
| -z   | no    | no      | yes | yes  | SHOULD |
| -E   | no    | no      | yes | no   | WONT |
| -L   | no    | no      | yes | no   | WONT |
| -P   | no    | no      | yes | no   | WONT |
| --relative-to | no | no | yes | yes | SHOULD |
| --relative-base | no | no | yes | yes | SHOULD |
