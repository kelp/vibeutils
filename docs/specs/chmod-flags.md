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
| -C   |       | yes   |         |     |      | SHOULD |
| -E   |       | yes   |         |     |      | SHOULD |
| -i   |       | yes   |         |     |      | SHOULD |
| -I   |       | yes   |         |     |      | SHOULD |
| -N   |       | yes   |         |     |      | SHOULD |
| --reference | |      |         | yes | yes  | SHOULD |
| --dereference | |    |         | yes |      | SHOULD |
| --no-preserve-root | | |      | yes |      | SHOULD |
| --preserve-root | |  |         | yes |      | SHOULD |
