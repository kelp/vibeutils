# tail - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -c | yes | yes | yes | yes | yes | MUST |
| -f | yes | yes | yes | yes | yes | MUST |
| -n | yes | yes | yes | yes | yes | MUST |
| -b | - | yes | yes | - | yes | MUST |
| -q | - | yes | - | yes | yes | SHOULD |
| -r | - | yes | yes | - | - | MUST |
| -v | - | yes | - | yes | yes | SHOULD |
| -F | - | yes | - | yes | yes | SHOULD |
| -z | - | - | - | yes | yes | SHOULD |
| -s / --sleep-interval | - | - | - | yes | - | WONT |
| --pid | - | - | - | yes | - | WONT |
| --retry | - | - | - | yes | - | WONT |
| --max-unchanged-stats | - | - | - | yes | - | WONT |
| --debug | - | - | - | yes | - | WONT |
