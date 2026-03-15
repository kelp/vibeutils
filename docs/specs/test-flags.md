# test - Flag Coverage

test uses expression primaries and operators rather than
conventional flags. GNU and vibeutils spec files are empty,
so GNU coverage is inferred from the macOS man page (which
documents a superset of POSIX).

## File Type Primaries

| Primary | POSIX | macOS | OpenBSD | Tier |
|---------|-------|-------|---------|------|
| -b | yes | yes | yes | MUST |
| -c | yes | yes | yes | MUST |
| -d | yes | yes | yes | MUST |
| -e | yes | yes | yes | MUST |
| -f | yes | yes | yes | MUST |
| -g | yes | yes | yes | MUST |
| -h | yes | yes | yes | MUST |
| -L | yes | yes | yes | MUST |
| -p | yes | yes | yes | MUST |
| -S | yes | yes | yes | MUST |
| -k | - | yes | yes | MUST |
| -G | - | yes | yes | MUST |
| -O | - | yes | yes | MUST |

## File Permission/Attribute Primaries

| Primary | POSIX | macOS | OpenBSD | Tier |
|---------|-------|-------|---------|------|
| -r | yes | yes | yes | MUST |
| -s | yes | yes | yes | MUST |
| -t | yes | yes | yes | MUST |
| -u | yes | yes | yes | MUST |
| -w | yes | yes | yes | MUST |
| -x | yes | yes | yes | MUST |

## String Primaries

| Primary | POSIX | macOS | OpenBSD | Tier |
|---------|-------|-------|---------|------|
| -n | yes | yes | yes | MUST |
| -z | yes | yes | yes | MUST |

## String Comparison Operators

| Operator | POSIX | macOS | OpenBSD | Tier |
|----------|-------|-------|---------|------|
| = | yes | yes | yes | MUST |
| != | yes | yes | yes | MUST |
| < | - | yes | yes | MUST |
| > | - | yes | yes | MUST |

## Integer Comparison Operators

| Operator | POSIX | macOS | OpenBSD | Tier |
|----------|-------|-------|---------|------|
| -eq | yes | yes | yes | MUST |
| -ne | yes | yes | yes | MUST |
| -gt | yes | yes | yes | MUST |
| -ge | yes | yes | yes | MUST |
| -lt | yes | yes | yes | MUST |
| -le | yes | yes | yes | MUST |

## File Comparison Operators

| Operator | POSIX | macOS | OpenBSD | Tier |
|----------|-------|-------|---------|------|
| -nt | - | yes | yes | MUST |
| -ot | - | yes | yes | MUST |
| -ef | - | yes | yes | MUST |

## Logical Operators

| Operator | POSIX | macOS | OpenBSD | Tier |
|----------|-------|-------|---------|------|
| ! | yes | yes | yes | MUST |
| -a | yes | yes | yes | MUST |
| -o | yes | yes | yes | MUST |
| ( ) | yes | yes | yes | MUST |
