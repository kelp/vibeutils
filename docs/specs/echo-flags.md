# echo - Flag Coverage

POSIX specifies no options for echo. The -n flag is a
widely adopted extension.

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -n | -- | yes | yes | yes | yes | MUST |
| -e | -- | -- | yes | yes | yes | SHOULD |
| -E | -- | -- | yes | yes | yes | SHOULD |
