# date - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -a   |       |       | yes     |     |      | WONT |
| -d   |       |       |         | yes | yes  | SHOULD |
| -f   |       | yes   | yes     | yes | yes  | MUST |
| -I   |       | yes   |         | yes | yes  | SHOULD |
| -j   |       | yes   | yes     |     | yes  | MUST |
| -n   |       | yes   |         |     | yes  | SHOULD |
| -r   |       | yes   | yes     | yes | yes  | MUST |
| -R   |       | yes   |         | yes | yes  | SHOULD |
| -s   |       |       |         | yes |      | WONT |
| -u   | yes   | yes   | yes     | yes | yes  | MUST |
| -v   |       | yes   |         |     | yes  | SHOULD |
| -z   |       | yes   | yes     |     | yes  | MUST |
| --debug |    |       |         | yes |      | WONT |
| --rfc-3339 | |      |         | yes | yes  | SHOULD |
| --resolution | |    |         | yes |      | WONT |
