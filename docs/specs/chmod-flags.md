# chmod - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -c   |       |       |         | yes | yes  | SHOULD |
| -f   |       | yes   |         | yes | yes  | SHOULD |
| -h   |       | yes   | yes     | yes | yes  | MUST |
| -H   |       | yes   | yes     | yes | yes  | MUST |
| -L   |       | yes   | yes     | yes | yes  | MUST |
| -P   |       | yes   | yes     | yes | yes  | MUST |
| -R   | yes   | yes   | yes     | yes | yes  | MUST |
| -v   |       | yes   |         | yes | yes  | SHOULD |
| -C   |       | yes   |         |     | yes  | SHOULD |
| -E   |       | yes   |         |     | yes  | SHOULD |
| -i   |       | yes   |         |     | yes  | SHOULD |
| -I   |       | yes   |         |     | yes  | SHOULD |
| -N   |       | yes   |         |     | yes  | SHOULD |
| --reference | |      |         | yes | yes  | SHOULD |
| --dereference | |    |         | yes | yes  | SHOULD |
| --no-preserve-root | | |      | yes | yes  | SHOULD |
| --preserve-root | |  |         | yes | yes  | SHOULD |
