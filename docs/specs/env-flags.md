# env - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -i | yes | yes | yes | yes | yes | MUST |
| -u | -- | yes | yes | yes | yes | MUST |
| -0 | -- | yes | -- | yes | yes | SHOULD |
| -C | -- | yes | -- | yes | yes | SHOULD |
| -P | -- | yes | -- | -- | -- | SHOULD |
| -S | -- | yes | -- | yes | -- | SHOULD |
| -v | -- | yes | -- | yes | -- | SHOULD |
| -a | -- | -- | -- | yes | -- | WONT |
| --block-signal | -- | -- | -- | yes | -- | WONT |
| --default-signal | -- | -- | -- | yes | -- | WONT |
| --ignore-signal | -- | -- | -- | yes | -- | WONT |
| --list-signal-handling | -- | -- | -- | yes | -- | WONT |
