# readlink - Flag Coverage

No POSIX spec exists for readlink. MUST = in both macOS
and OpenBSD.

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -f   | yes   | yes     | yes | yes  | MUST |
| -n   | yes   | yes     | yes | yes  | MUST |
| -e   | no    | no      | yes | yes  | SHOULD |
| -m   | no    | no      | yes | yes  | SHOULD |
| -q   | no    | no      | yes | yes  | SHOULD |
| -v   | no    | no      | yes | yes  | SHOULD |
| -z   | no    | no      | yes | yes  | SHOULD |
