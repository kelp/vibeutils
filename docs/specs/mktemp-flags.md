# mktemp - Flag Coverage

No POSIX spec exists for mktemp. MUST = in both macOS
and OpenBSD.

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -d   | yes   | yes     | yes | yes  | MUST |
| -p   | yes   | yes     | yes | yes  | MUST |
| -q   | yes   | yes     | yes | yes  | MUST |
| -t   | yes   | yes     | yes | yes  | MUST |
| -u   | yes   | yes     | yes | yes  | MUST |
| --suffix | no | no     | yes | yes  | SHOULD |
