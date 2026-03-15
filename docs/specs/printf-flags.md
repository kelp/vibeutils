# printf - Flag Coverage

printf takes no command-line option flags. It uses a
format string and arguments as operands. All platforms
(POSIX, macOS, OpenBSD, GNU) agree on this interface.

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|

No flags to compare. The utility's behavior is controlled
entirely through the format string operand.
