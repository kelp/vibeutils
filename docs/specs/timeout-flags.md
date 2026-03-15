# timeout - Flag Coverage

timeout is not a POSIX utility. It is not available on
macOS natively.

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| -s / --signal | - | yes | yes | yes | SHOULD |
| -k / --kill-after | - | yes | yes | yes | SHOULD |
| -f / --foreground | - | yes | yes | long only | SHOULD |
| -p / --preserve-status | - | yes | yes | long only | SHOULD |
| -v / --verbose | - | - | yes | yes | SHOULD |
