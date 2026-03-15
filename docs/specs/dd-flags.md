# dd - Flag Coverage

Operands are treated as flags for this table.

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| if=  | yes   | yes   | yes     | yes | yes  | MUST |
| of=  | yes   | yes   | yes     | yes | yes  | MUST |
| bs=  | yes   | yes   | yes     | yes | yes  | MUST |
| ibs= | yes   | yes   | yes     | yes | yes  | MUST |
| obs= | yes   | yes   | yes     | yes | yes  | MUST |
| cbs= | yes   | yes   | yes     | yes |      | MUST |
| skip= | yes  | yes   | yes     | yes | yes  | MUST |
| seek= | yes  | yes   | yes     | yes | yes  | MUST |
| count= | yes | yes   | yes     | yes | yes  | MUST |
| conv= | yes  | yes   | yes     | yes | yes  | MUST |
| files= |     | yes   | yes     |     |      | MUST |
| fillchar= |  | yes   |         |     |      | SHOULD |
| iflag= |     | yes   |         | yes |      | SHOULD |
| iseek= |     | yes   |         | yes |      | SHOULD |
| oflag= |     | yes   |         | yes |      | SHOULD |
| oseek= |     | yes   |         | yes |      | SHOULD |
| speed= |     | yes   |         |     |      | SHOULD |
| status= |    | yes   | yes     | yes | yes  | MUST |

### conv= values

| Value | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|-------|-------|-------|---------|-----|------|------|
| ascii | yes   | yes   | yes     | yes |      | MUST |
| ebcdic | yes  | yes   | yes     | yes |      | MUST |
| ibm   | yes   | yes   | yes     | yes |      | MUST |
| block | yes   | yes   | yes     | yes |      | MUST |
| unblock | yes | yes   | yes     | yes |      | MUST |
| lcase | yes   | yes   | yes     | yes | yes  | MUST |
| ucase | yes   | yes   | yes     | yes | yes  | MUST |
| swab  | yes   | yes   | yes     | yes |      | MUST |
| noerror | yes | yes   | yes     | yes | yes  | MUST |
| notrunc | yes | yes   | yes     | yes | yes  | MUST |
| sync  | yes   | yes   | yes     | yes | yes  | MUST |
| oldascii |   | yes   |         |     |      | SHOULD |
| oldebcdic |  | yes   |         |     |      | SHOULD |
| oldibm |     | yes   |         |     |      | SHOULD |
| fsync |      | yes   | yes     | yes |      | MUST |
| osync |      | yes   | yes     |     |      | MUST |
| sparse |     | yes   |         | yes |      | SHOULD |
| pareven |    | yes   |         |     |      | SHOULD |
| parnone |    | yes   |         |     |      | SHOULD |
| parodd |     | yes   |         |     |      | SHOULD |
| parset |     | yes   |         |     |      | SHOULD |
| excl  |      |       |         | yes |      | WONT |
| nocreat |    |       |         | yes |      | WONT |
| fdatasync |  |       |         | yes |      | WONT |

### status= values

| Value | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|-------|-------|-------|---------|-----|------|------|
| none  |       | yes   | yes     | yes | yes  | MUST |
| noxfer |      | yes   | yes     | yes |      | MUST |
| progress |   | yes   |         | yes | yes  | SHOULD |
