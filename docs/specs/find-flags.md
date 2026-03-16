# find - Flag Coverage

## Global Options

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -H | yes | yes | yes | yes | yes | MUST |
| -L | yes | yes | yes | yes | yes | MUST |
| -P | -- | yes | -- | yes | yes | SHOULD |
| -E | -- | yes | -- | -- | yes | SHOULD |
| -X | -- | yes | yes | -- | yes | MUST |
| -d | -- | yes | yes | -- | yes | MUST |
| -f | -- | yes | yes | -- | yes | MUST |
| -s | -- | yes | -- | -- | yes | SHOULD |
| -x | -- | yes | yes | -- | yes | MUST |
| -O | -- | -- | -- | yes | -- | WONT |
| -D | -- | -- | -- | yes | -- | WONT |

## Primaries / Tests

| Primary | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|---------|-------|-------|---------|-----|------|------|
| -name | yes | yes | yes | yes | yes | MUST |
| -path | yes | yes | yes | yes | yes | MUST |
| -nouser | yes | yes | yes | yes | yes | MUST |
| -nogroup | yes | yes | yes | yes | yes | MUST |
| -xdev | yes | yes | yes | yes | yes | MUST |
| -prune | yes | yes | yes | yes | yes | MUST |
| -perm | yes | yes | yes | yes | yes | MUST |
| -type | yes | yes | yes | yes | yes | MUST |
| -links | yes | yes | yes | yes | yes | MUST |
| -user | yes | yes | yes | yes | yes | MUST |
| -group | yes | yes | yes | yes | yes | MUST |
| -size | yes | yes | yes | yes | yes | MUST |
| -atime | yes | yes | yes | yes | yes | MUST |
| -ctime | yes | yes | yes | yes | yes | MUST |
| -mtime | yes | yes | yes | yes | yes | MUST |
| -exec | yes | yes | yes | yes | yes | MUST |
| -ok | yes | yes | yes | yes | yes | MUST |
| -print | yes | yes | yes | yes | yes | MUST |
| -newer | yes | yes | yes | yes | yes | MUST |
| -depth | yes | yes | yes | yes | yes | MUST |
| -iname | -- | yes | yes | yes | yes | MUST |
| -empty | -- | yes | yes | yes | yes | MUST |
| -delete | -- | yes | yes | yes | yes | MUST |
| -maxdepth | -- | yes | yes | yes | yes | MUST |
| -mindepth | -- | yes | yes | yes | yes | MUST |
| -print0 | -- | yes | yes | yes | yes | MUST |
| -execdir | -- | yes | yes | yes | yes | MUST |
| -amin | -- | yes | yes | yes | yes | MUST |
| -anewer | -- | yes | yes | yes | yes | MUST |
| -cmin | -- | yes | yes | yes | yes | MUST |
| -cnewer | -- | yes | yes | yes | yes | MUST |
| -mmin | -- | yes | yes | yes | yes | MUST |
| -ls | -- | yes | yes | yes | yes | MUST |
| -fstype | -- | yes | yes | yes | yes | MUST |
| -inum | -- | yes | yes | yes | yes | MUST |
| -flags | -- | yes | yes | -- | yes | MUST |
| -follow | -- | yes | yes | -- | yes | MUST |
| -ipath | -- | yes | -- | -- | yes | SHOULD |
| -iregex | -- | yes | -- | yes | yes | SHOULD |
| -regex | -- | yes | -- | yes | yes | SHOULD |
| -Bmin | -- | yes | -- | -- | yes | SHOULD |
| -Bnewer | -- | yes | -- | -- | yes | SHOULD |
| -Btime | -- | yes | -- | -- | yes | SHOULD |
| -acl | -- | yes | -- | -- | yes | SHOULD |
| -depth N | -- | yes | -- | -- | yes | SHOULD |
| -gid | -- | yes | -- | -- | yes | SHOULD |
| -ignore_readdir_race | -- | yes | -- | yes | yes | SHOULD |
| -ilname | -- | yes | -- | yes | yes | SHOULD |
| -lname | -- | yes | -- | yes | yes | SHOULD |
| -mnewer | -- | yes | -- | -- | yes | SHOULD |
| -mount | -- | yes | -- | yes | yes | SHOULD |
| -newerXY | -- | yes | -- | yes | yes | SHOULD |
| -noleaf | -- | yes | -- | yes | yes | SHOULD |
| -noignore_readdir_race | -- | yes | -- | yes | yes | SHOULD |
| -okdir | -- | yes | -- | yes | yes | SHOULD |
| -quit | -- | yes | -- | -- | yes | SHOULD |
| -samefile | -- | yes | -- | -- | yes | SHOULD |
| -sparse | -- | yes | -- | -- | yes | SHOULD |
| -uid | -- | yes | -- | -- | yes | SHOULD |
| -wholename | -- | yes | -- | yes | yes | SHOULD |
| -xattr | -- | yes | -- | -- | yes | SHOULD |
| -xattrname | -- | yes | -- | -- | yes | SHOULD |
| -context | -- | -- | -- | yes | -- | WONT |
| -readable | -- | -- | -- | yes | -- | WONT |
| -writable | -- | -- | -- | yes | -- | WONT |
| -executable | -- | -- | -- | yes | -- | WONT |
| -used | -- | -- | -- | yes | -- | WONT |
| -xtype | -- | -- | -- | yes | -- | WONT |
| -printf | -- | -- | -- | yes | yes | SHOULD |
| -fprintf | -- | -- | -- | yes | -- | WONT |
| -fprint | -- | -- | -- | yes | -- | WONT |
| -fprint0 | -- | -- | -- | yes | -- | WONT |
| -fls | -- | -- | -- | yes | -- | WONT |
| -daystart | -- | -- | -- | yes | -- | WONT |
| -nowarn | -- | -- | -- | yes | -- | WONT |
| -warn | -- | -- | -- | yes | -- | WONT |
| -regextype | -- | -- | -- | yes | -- | WONT |
| -files0-from | -- | -- | -- | yes | -- | WONT |

## Operators

| Operator | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|----------|-------|-------|---------|-----|------|------|
| ( ) | yes | yes | yes | yes | yes | MUST |
| ! / -not | yes | yes | yes | yes | yes | MUST |
| -a / -and | yes | yes | yes | yes | yes | MUST |
| -o / -or | yes | yes | yes | yes | yes | MUST |
| -false | -- | yes | -- | -- | yes | SHOULD |
| -true | -- | yes | -- | -- | yes | SHOULD |
