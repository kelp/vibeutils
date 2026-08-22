# ls - Flag Coverage

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| -1   | yes   | yes   | yes     | yes | yes  | MUST |
| -a   | yes   | yes   | yes     | yes | yes  | MUST |
| -A   | yes   | yes   | yes     | yes | yes  | MUST |
| -c   | yes   | yes   | yes     | yes | yes  | MUST |
| -C   | yes   | yes   | yes     | yes | yes  | MUST |
| -d   | yes   | yes   | yes     | yes | yes  | MUST |
| -f   | yes   | yes   | yes     | yes | yes  | MUST |
| -F   | yes   | yes   | yes     | yes | yes  | MUST |
| -g   | yes   | yes   | yes     | yes | yes  | MUST |
| -H   | yes   | yes   | yes     | yes | yes  | MUST |
| -i   | yes   | yes   | yes     | yes | yes  | MUST |
| -k   | yes   | yes   | yes     | yes | yes  | MUST |
| -l   | yes   | yes   | yes     | yes | yes  | MUST |
| -L   | yes   | yes   | yes     | yes | yes  | MUST |
| -m   | yes   | yes   | yes     | yes | yes  | MUST |
| -n   | yes   | yes   | yes     | yes | yes  | MUST |
| -o   | yes   | yes   | yes     | yes | yes  | MUST |
| -p   | yes   | yes   | yes     | yes | yes  | MUST |
| -q   | yes   | yes   | yes     | yes | yes  | MUST |
| -r   | yes   | yes   | yes     | yes | yes  | MUST |
| -R   | yes   | yes   | yes     | yes | yes  | MUST |
| -s   | yes   | yes   | yes     | yes | yes  | MUST |
| -S   | yes   | yes   | yes     | yes | yes  | MUST |
| -t   | yes   | yes   | yes     | yes | yes  | MUST |
| -u   | yes   | yes   | yes     | yes | yes  | MUST |
| -x   | yes   | yes   | yes     | yes | yes  | MUST |
| -h   | no    | yes   | yes     | yes | yes  | MUST |
| -T   | no    | yes   | yes     | yes | yes  | MUST |
| -b   | no    | yes   | no      | yes | yes  | SHOULD |
| -B   | no    | yes   | no      | yes | yes  | SHOULD |
| -D   | no    | yes   | no      | yes | yes  | SHOULD |
| -e   | no    | yes   | no      | no  | yes  | SHOULD |
| -G   | no    | yes   | no      | yes | yes  | SHOULD |
| -I   | no    | yes   | no      | yes | yes  | SHOULD |
| -N   | no    | no    | no      | yes | no   | WONT |
| -O   | no    | yes   | no      | no  | yes  | SHOULD |
| -P   | no    | yes   | no      | no  | yes  | SHOULD |
| -Q   | no    | no    | no      | yes | no   | WONT |
| -U   | no    | yes   | no      | yes | yes  | SHOULD |
| -v   | no    | yes   | no      | yes | yes  | SHOULD |
| -w   | no    | yes   | no      | yes | yes  | SHOULD |
| -W   | no    | yes   | no      | no  | yes  | SHOULD |
| -X   | no    | yes   | no      | yes | yes  | SHOULD |
| -y   | no    | yes   | no      | no  | yes  | SHOULD |
| -Z   | no    | no    | no      | yes | no   | WONT |
| -@   | no    | yes   | no      | no  | yes  | SHOULD |
| -%   | no    | yes   | no      | no  | yes  | SHOULD |
| -,   | no    | yes   | no      | no  | yes  | SHOULD |
| --color | no | yes   | no      | yes | yes  | SHOULD |
| --group-directories-first | no | no | no | yes | yes | SHOULD |
| --time-style | no | no | no    | yes | yes  | SHOULD |
| --git | no   | no    | no      | no  | yes  | KEEP |
| --icons | no | no    | no      | no  | yes  | KEEP |
| --test-icons | no | no | no   | no  | yes  | KEEP |
| --dired | no | no    | no      | yes | no   | WONT |
| --file-type | no | no | no     | yes | no   | WONT |
| --format | no | no   | no      | yes | no   | WONT |
| --full-time | no | no | no     | yes | no   | WONT |
| --hide | no  | no    | no      | yes | no   | WONT |
| --hyperlink | no | no | no     | yes | no   | WONT |
| --indicator-style | no | no | no | yes | no | WONT |
| --quoting-style | no | no | no | yes | no   | WONT |
| --show-control-chars | no | no | no | yes | no | WONT |
| --si | no    | no    | no      | yes | no   | WONT |
| --sort | no  | no    | no      | yes | no   | WONT |
| --time | no  | no    | no      | yes | no   | WONT |
| --zero | no  | no    | no      | yes | no   | WONT |
| --block-size | no | no | no    | yes | no   | WONT |
| --author | no | no   | no      | yes | no   | WONT |
| --dereference-command-line-symlink-to-dir | no | no | no | yes | no | WONT |

KEEP default (not a flag): `ls -l` prints 1024-based human-readable
sizes, matching `df`. `-k` restores kilobyte counts unless `-h` is
also given. `--block-size` stays WONT. GNU flag semantics are
unchanged.
