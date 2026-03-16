# test - Flag Coverage

test uses expression primaries and operators rather than
conventional flags. GNU and vibeutils spec files are empty,
so GNU coverage is inferred from the macOS man page (which
documents a superset of POSIX).

## File Type Primaries

| Primary | POSIX | macOS | OpenBSD | Ours | Tier |
|---------|-------|-------|---------|------|------|
| -b | yes | yes | yes | yes | MUST |
| -c | yes | yes | yes | yes | MUST |
| -d | yes | yes | yes | yes | MUST |
| -e | yes | yes | yes | yes | MUST |
| -f | yes | yes | yes | yes | MUST |
| -g | yes | yes | yes | yes | MUST |
| -h | yes | yes | yes | yes | MUST |
| -L | yes | yes | yes | yes | MUST |
| -p | yes | yes | yes | yes | MUST |
| -S | yes | yes | yes | yes | MUST |
| -k | - | yes | yes | yes | MUST |
| -G | - | yes | yes | yes | MUST |
| -O | - | yes | yes | yes | MUST |

## File Permission/Attribute Primaries

| Primary | POSIX | macOS | OpenBSD | Ours | Tier |
|---------|-------|-------|---------|------|------|
| -r | yes | yes | yes | yes | MUST |
| -s | yes | yes | yes | yes | MUST |
| -t | yes | yes | yes | yes | MUST |
| -u | yes | yes | yes | yes | MUST |
| -w | yes | yes | yes | yes | MUST |
| -x | yes | yes | yes | yes | MUST |

## String Primaries

| Primary | POSIX | macOS | OpenBSD | Ours | Tier |
|---------|-------|-------|---------|------|------|
| -n | yes | yes | yes | yes | MUST |
| -z | yes | yes | yes | yes | MUST |

## String Comparison Operators

| Operator | POSIX | macOS | OpenBSD | Ours | Tier |
|----------|-------|-------|---------|------|------|
| = | yes | yes | yes | yes | MUST |
| != | yes | yes | yes | yes | MUST |
| < | - | yes | yes | yes | MUST |
| > | - | yes | yes | yes | MUST |

## Integer Comparison Operators

| Operator | POSIX | macOS | OpenBSD | Ours | Tier |
|----------|-------|-------|---------|------|------|
| -eq | yes | yes | yes | yes | MUST |
| -ne | yes | yes | yes | yes | MUST |
| -gt | yes | yes | yes | yes | MUST |
| -ge | yes | yes | yes | yes | MUST |
| -lt | yes | yes | yes | yes | MUST |
| -le | yes | yes | yes | yes | MUST |

## File Comparison Operators

| Operator | POSIX | macOS | OpenBSD | Ours | Tier |
|----------|-------|-------|---------|------|------|
| -nt | - | yes | yes | yes | MUST |
| -ot | - | yes | yes | yes | MUST |
| -ef | - | yes | yes | yes | MUST |

## Logical Operators

| Operator | POSIX | macOS | OpenBSD | Ours | Tier |
|----------|-------|-------|---------|------|------|
| ! | yes | yes | yes | yes | MUST |
| -a | yes | yes | yes | yes | MUST |
| -o | yes | yes | yes | yes | MUST |
| ( ) | yes | yes | yes | yes | MUST |
