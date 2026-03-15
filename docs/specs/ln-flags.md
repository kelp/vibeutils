# ln - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -f | yes | yes | yes | yes | yes | MUST |
| -L | yes | yes | yes | yes | yes | MUST |
| -P | yes | yes | yes | yes | yes | MUST |
| -s | yes | yes | yes | yes | yes | MUST |
| -h | -- | yes | yes | -- | -- | MUST |
| -n | -- | yes | yes | yes | yes | MUST |
| -i | -- | yes | -- | yes | yes | SHOULD |
| -v | -- | yes | -- | yes | yes | SHOULD |
| -F | -- | yes | -- | yes | -- | SHOULD |
| -w | -- | yes | -- | -- | -- | SHOULD |
| -b | -- | -- | -- | yes | -- | SHOULD |
| -d | -- | -- | -- | yes | -- | WONT |
| -r | -- | -- | -- | yes | yes | SHOULD |
| -S | -- | -- | -- | yes | -- | WONT |
| -t | -- | -- | -- | yes | yes | SHOULD |
| -T | -- | -- | -- | yes | yes | SHOULD |
| --backup | -- | -- | -- | yes | -- | SHOULD |
