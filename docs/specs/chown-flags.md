# chown - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -c   |       |       |         | yes | yes  | SHOULD |
| -f   |       | yes   |         | yes | yes  | SHOULD |
| -h   | yes   | yes   | yes     | yes | yes  | MUST |
| -H   | yes   | yes   | yes     | yes | yes  | MUST |
| -L   | yes   | yes   | yes     | yes | yes  | MUST |
| -n   |       | yes   |         |     | yes  | SHOULD |
| -P   | yes   | yes   | yes     | yes | yes  | MUST |
| -R   | yes   | yes   | yes     | yes | yes  | MUST |
| -v   |       | yes   |         | yes | yes  | SHOULD |
| -x   |       | yes   |         |     | yes  | SHOULD |
| --from |     |       |         | yes |      | WONT |
| --reference |  |     |         | yes |      | WONT |
| --dereference |  |   |         | yes | yes  | SHOULD |
| --no-preserve-root | |  |     | yes | yes  | SHOULD |
| --preserve-root |  |  |       | yes | yes  | SHOULD |
