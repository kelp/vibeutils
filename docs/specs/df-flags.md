# df - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -a   |       | yes   |         | yes | yes  | SHOULD |
| -b   |       | yes   |         |     | yes  | SHOULD |
| -B   |       |       |         | yes |      | WONT |
| -c   |       | yes   |         |     | yes  | SHOULD |
| -g   |       | yes   |         |     | yes  | SHOULD |
| -h   |       | yes   | yes     | yes | yes  | MUST |
| -H   |       | yes   |         | yes | yes  | SHOULD |
| -i   |       | yes   | yes     | yes | yes  | MUST |
| -I   |       | yes   |         |     | yes  | SHOULD |
| -k   | yes   | yes   | yes     | yes | yes  | MUST |
| -l   |       | yes   | yes     | yes | yes  | MUST |
| -m   |       | yes   |         |     | yes  | SHOULD |
| -n   |       | yes   | yes     |     | yes  | MUST |
| -P   | yes   | yes   | yes     | yes | yes  | MUST |
| -t   | yes   | yes   | yes     | yes | yes  | MUST |
| -T   |       | yes   |         | yes | yes  | SHOULD |
| -v   |       |       |         | yes |      | WONT |
| -x   |       |       |         | yes | yes  | SHOULD |
| -Y   |       | yes   |         |     | yes  | SHOULD |
| -,   |       | yes   |         |     | yes  | SHOULD |
| --block-size | |     |         | yes | yes  | SHOULD |
| --no-sync |  |       |         | yes |      | WONT |
| --output |   |       |         | yes | yes  | SHOULD |
| --sync |     |       |         | yes |      | WONT |
| --total |    |       |         | yes | yes  | SHOULD |
