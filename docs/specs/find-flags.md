# find - Flag Coverage

## Global Options

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -H | yes | yes | yes | yes | yes | MUST |
| -L | yes | yes | yes | yes | yes | MUST |
| -P | -- | yes | -- | yes | -- | SHOULD |
| -E | -- | yes | -- | -- | -- | SHOULD |
| -X | -- | yes | yes | -- | -- | MUST |
| -d | -- | yes | yes | -- | -- | MUST |
| -f | -- | yes | yes | -- | -- | MUST |
| -s | -- | yes | -- | -- | -- | SHOULD |
| -x | -- | yes | yes | -- | -- | MUST |
| -O | -- | -- | -- | yes | -- | WONT |
| -D | -- | -- | -- | yes | -- | WONT |

## Primaries / Tests

| Primary | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|---------|-------|-------|---------|-----|------|------|
| -name | yes | yes | yes | yes | yes | MUST |
| -path | yes | yes | yes | yes | yes | MUST |
| -nouser | yes | yes | yes | yes | -- | MUST |
| -nogroup | yes | yes | yes | yes | -- | MUST |
| -xdev | yes | yes | yes | yes | -- | MUST |
| -prune | yes | yes | yes | yes | -- | MUST |
| -perm | yes | yes | yes | yes | yes | MUST |
| -type | yes | yes | yes | yes | yes | MUST |
| -links | yes | yes | yes | yes | -- | MUST |
| -user | yes | yes | yes | yes | yes | MUST |
| -group | yes | yes | yes | yes | yes | MUST |
| -size | yes | yes | yes | yes | yes | MUST |
| -atime | yes | yes | yes | yes | -- | MUST |
| -ctime | yes | yes | yes | yes | -- | MUST |
| -mtime | yes | yes | yes | yes | yes | MUST |
| -exec | yes | yes | yes | yes | yes | MUST |
| -ok | yes | yes | yes | yes | -- | MUST |
| -print | yes | yes | yes | yes | yes | MUST |
| -newer | yes | yes | yes | yes | yes | MUST |
| -depth | yes | yes | yes | yes | yes | MUST |
| -iname | -- | yes | yes | yes | yes | MUST |
| -empty | -- | yes | yes | yes | yes | MUST |
| -delete | -- | yes | yes | yes | yes | MUST |
| -maxdepth | -- | yes | yes | yes | yes | MUST |
| -mindepth | -- | yes | yes | yes | -- | MUST |
| -print0 | -- | yes | yes | yes | yes | MUST |
| -execdir | -- | yes | yes | yes | -- | MUST |
| -amin | -- | yes | yes | yes | -- | MUST |
| -anewer | -- | yes | yes | yes | -- | MUST |
| -cmin | -- | yes | yes | yes | -- | MUST |
| -cnewer | -- | yes | yes | yes | -- | MUST |
| -mmin | -- | yes | yes | yes | -- | MUST |
| -ls | -- | yes | yes | yes | -- | MUST |
| -fstype | -- | yes | yes | yes | -- | MUST |
| -inum | -- | yes | yes | yes | -- | MUST |
| -flags | -- | yes | yes | -- | -- | MUST |
| -follow | -- | yes | yes | -- | yes | MUST |
| -ipath | -- | yes | -- | -- | -- | SHOULD |
| -iregex | -- | yes | -- | yes | -- | SHOULD |
| -regex | -- | yes | -- | yes | -- | SHOULD |
| -Bmin | -- | yes | -- | -- | -- | SHOULD |
| -Bnewer | -- | yes | -- | -- | -- | SHOULD |
| -Btime | -- | yes | -- | -- | -- | SHOULD |
| -acl | -- | yes | -- | -- | -- | SHOULD |
| -depth N | -- | yes | -- | -- | -- | SHOULD |
| -gid | -- | yes | -- | -- | -- | SHOULD |
| -ignore_readdir_race | -- | yes | -- | yes | -- | SHOULD |
| -ilname | -- | yes | -- | yes | -- | SHOULD |
| -lname | -- | yes | -- | yes | -- | SHOULD |
| -mnewer | -- | yes | -- | -- | -- | SHOULD |
| -mount | -- | yes | -- | yes | -- | SHOULD |
| -newerXY | -- | yes | -- | yes | -- | SHOULD |
| -noleaf | -- | yes | -- | yes | -- | SHOULD |
| -noignore_readdir_race | -- | yes | -- | yes | -- | SHOULD |
| -okdir | -- | yes | -- | yes | -- | SHOULD |
| -quit | -- | yes | -- | -- | -- | SHOULD |
| -samefile | -- | yes | -- | -- | -- | SHOULD |
| -sparse | -- | yes | -- | -- | -- | SHOULD |
| -uid | -- | yes | -- | -- | -- | SHOULD |
| -wholename | -- | yes | -- | yes | -- | SHOULD |
| -xattr | -- | yes | -- | -- | -- | SHOULD |
| -xattrname | -- | yes | -- | -- | -- | SHOULD |
| -context | -- | -- | -- | yes | -- | WONT |
| -readable | -- | -- | -- | yes | -- | WONT |
| -writable | -- | -- | -- | yes | -- | WONT |
| -executable | -- | -- | -- | yes | -- | WONT |
| -used | -- | -- | -- | yes | -- | WONT |
| -xtype | -- | -- | -- | yes | -- | WONT |
| -printf | -- | -- | -- | yes | -- | SHOULD |
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
| -false | -- | yes | -- | -- | -- | SHOULD |
| -true | -- | yes | -- | -- | -- | SHOULD |
