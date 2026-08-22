# tree - Flag Coverage

`tree` is not POSIX and is not GNU coreutils. It does not
exist in macOS or OpenBSD base. Steve Baker's `tree(1)`
(2.x) is the de facto reference for named flags. **SHOULD**
= Baker flag named by this TODO heading. **KEEP** =
vibeutils spelling or convention. Remaining Baker flags
are **WONT** this slice.

`-L 0` is a house deviation: Baker 2.x rejects it; we emit
only the operand.

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -L N | -- | -- | -- | n/a | yes | SHOULD |
| --level=N | -- | -- | -- | n/a | yes | KEEP |
| -d | -- | -- | -- | n/a | yes | SHOULD |
| --directories-only | -- | -- | -- | n/a | yes | KEEP |
| -I PATTERN | -- | -- | -- | n/a | yes | SHOULD |
| --ignore=PATTERN | -- | -- | -- | n/a | yes | KEEP |
| -a | -- | -- | -- | n/a | yes | SHOULD |
| --all | -- | -- | -- | n/a | yes | KEEP |
| --color=WHEN | -- | -- | -- | n/a | yes | KEEP |
| --icons=WHEN | -- | -- | -- | n/a | yes | KEEP |
| -h / --help | -- | -- | -- | n/a | yes | KEEP |
| -V / --version | -- | -- | -- | n/a | yes | KEEP |
| -C | -- | -- | -- | n/a | -- | WONT |
| -n | -- | -- | -- | n/a | -- | WONT |
| -l | -- | -- | -- | n/a | -- | WONT |
| -f | -- | -- | -- | n/a | -- | WONT |
| -P | -- | -- | -- | n/a | -- | WONT |
| -p | -- | -- | -- | n/a | -- | WONT |
| -s | -- | -- | -- | n/a | -- | WONT |
| -h (human sizes) | -- | -- | -- | n/a | -- | WONT |
| -u | -- | -- | -- | n/a | -- | WONT |
| -g | -- | -- | -- | n/a | -- | WONT |
| -D | -- | -- | -- | n/a | -- | WONT |
| -t | -- | -- | -- | n/a | -- | WONT |
| -F | -- | -- | -- | n/a | -- | WONT |
| -Q | -- | -- | -- | n/a | -- | WONT |
| -x | -- | -- | -- | n/a | -- | WONT |
| -o | -- | -- | -- | n/a | -- | WONT |
| --noreport | -- | -- | -- | n/a | -- | WONT |
| --dirsfirst | -- | -- | -- | n/a | -- | WONT |
| HTML/JSON output | -- | -- | -- | n/a | -- | WONT |
| ASCII charset (-A/-S) | -- | -- | -- | n/a | -- | WONT |

Baker `-C`/`-n` are declined in favor of `--color=WHEN`.
Baker `-h` is human-readable sizes; vibeutils `-h` is help.
`-l` (follow directory symlinks), `-f` (full path), `-P`
(include pattern), size/owner/time columns, HTML/JSON, `-o`,
and `--noreport` are out of this slice.
