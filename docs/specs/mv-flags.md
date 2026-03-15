# mv - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -f   | yes   | yes   | yes     | yes | yes  | MUST |
| -i   | yes   | yes   | yes     | yes | yes  | MUST |
| -n   | no    | yes   | no      | yes | yes  | SHOULD |
| -v   | no    | yes   | yes     | yes | yes  | MUST |
| -h   | no    | yes   | no      | no  | no   | SHOULD |
| -b   | no    | no    | no      | yes | no   | SHOULD |
| -u   | no    | no    | no      | yes | no   | WONT |
| -S   | no    | no    | no      | yes | no   | WONT |
| -t   | no    | no    | no      | yes | no   | WONT |
| -T   | no    | no    | no      | yes | no   | WONT |
| -Z   | no    | no    | no      | yes | no   | WONT |
| --backup | no | no   | no      | yes | no   | SHOULD |
| --debug | no | no    | no      | yes | no   | WONT |
| --exchange | no | no | no      | yes | no   | WONT |
| --no-copy | no | no  | no      | yes | no   | WONT |
| --strip-trailing-slashes | no | no | no | yes | no | WONT |
| --update | no | no   | no      | yes | no   | WONT |
