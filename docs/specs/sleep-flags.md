# sleep - Flag Coverage

sleep has no flags in any implementation. POSIX, macOS,
OpenBSD, and GNU all accept only operands (no dash-flags).

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|

No flags to compare. All implementations accept numeric
duration operands; macOS and GNU extend POSIX by supporting
fractional seconds and time-unit suffixes (s, m, h, d).
