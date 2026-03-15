# yes - Flag Coverage

yes is not a POSIX utility. No POSIX column applies.
MUST tier requires presence in both macOS and OpenBSD.

Neither macOS nor OpenBSD define any flags for yes,
so no flags reach MUST tier.

| Flag | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|---------|-----|------|------|
| (none) | -  | -       | -   | -    | -    |

No functional flags exist across any implementation.
GNU provides only --help and --version. Vibeutils
provides -h/--help and -V/--version.
