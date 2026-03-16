# rm - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -f   | yes   | yes   | yes     | yes | yes  | MUST |
| -i   | yes   | yes   | yes     | yes | yes  | MUST |
| -r   | yes   | yes   | yes     | yes | yes  | MUST |
| -R   | yes   | yes   | yes     | yes | yes  | MUST |
| -d   | no    | yes   | yes     | yes | yes  | MUST |
| -v   | no    | yes   | yes     | yes | yes  | MUST |
| -P   | no    | yes   | yes     | no  | yes  | MUST |
| -I   | no    | yes   | no      | yes | yes  | SHOULD |
| -x   | no    | yes   | no      | no  | yes  | SHOULD |
| -W   | no    | yes   | no      | no  | yes  | SHOULD |
| --preserve-root | no | no | no | yes | yes  | SHOULD |
| --no-preserve-root | no | no | no | yes | yes | SHOULD |
| --interactive | no | no | no   | yes | no   | WONT |
| --one-file-system | no | no | no | yes | no  | WONT |
