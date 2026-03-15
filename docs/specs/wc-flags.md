# wc - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -c   | yes   | yes   | yes     | yes | yes  | MUST |
| -l   | yes   | yes   | yes     | yes | yes  | MUST |
| -m   | yes   | yes   | yes     | yes | yes  | MUST |
| -w   | yes   | yes   | yes     | yes | yes  | MUST |
| -L   | -     | yes   | -       | yes | yes  | SHOULD |
| -h   | -     | -     | yes     | -   | -    | WONT |
| --files0-from=F | - | -  | -   | yes | -    | WONT |
| --total=WHEN | - | - | -       | yes | -    | WONT |
| --debug | -  | -     | -       | yes | -    | WONT |
| --libxo | -  | yes   | -       | -   | -    | SHOULD |
| --color | -  | -     | -       | -   | yes  | KEEP |
