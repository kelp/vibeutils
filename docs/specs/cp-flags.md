# cp - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -a   |       | yes   | yes     | yes | yes  | MUST |
| -b   |       |       |         | yes |      | SHOULD |
| -c   |       | yes   |         |     |      | SHOULD |
| -d   |       |       |         | yes | yes  | SHOULD |
| -f   | yes   | yes   | yes     | yes | yes  | MUST |
| -H   | yes   | yes   | yes     | yes | yes  | MUST |
| -i   | yes   | yes   | yes     | yes | yes  | MUST |
| -l   |       | yes   |         | yes |      | SHOULD |
| -L   | yes   | yes   | yes     | yes | yes  | MUST |
| -n   |       | yes   |         | yes | yes  | SHOULD |
| -N   |       | yes   |         |     |      | SHOULD |
| -p   | yes   | yes   | yes     | yes | yes  | MUST |
| -P   | yes   | yes   | yes     | yes | yes  | MUST |
| -R   | yes   | yes   | yes     | yes | yes  | MUST |
| -s   |       | yes   |         | yes |      | SHOULD |
| -S   |       | yes   |         | yes |      | SHOULD |
| -u   |       |       |         | yes |      | WONT |
| -v   |       | yes   | yes     | yes | yes  | MUST |
| -x   |       | yes   |         | yes |      | SHOULD |
| -X   |       | yes   |         |     |      | SHOULD |
| -Z   |       |       |         | yes |      | WONT |
| --attributes-only |  |  |     | yes |      | WONT |
| --copy-contents |  |  |       | yes |      | WONT |
| --debug |    |       |         | yes |      | WONT |
| --keep-directory-symlink | | | | yes |     | WONT |
| --no-preserve |  |   |         | yes |      | WONT |
| --parents |  |       |         | yes |      | SHOULD |
| --preserve | |       |         | yes |      | SHOULD |
| --reflink |  |       |         | yes |      | WONT |
| --remove-destination | |  |   | yes |      | WONT |
| --sparse |   |       |         | yes |      | WONT |
| --strip-trailing-slashes | | | | yes |     | WONT |
| -t   |       |       |         | yes |      | WONT |
| -T   |       |       |         | yes |      | WONT |
| --update |   |       |         | yes |      | WONT |
| --backup |   |       |         | yes |      | SHOULD |
| --context |  |       |         | yes |      | WONT |
