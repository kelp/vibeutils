# dd - Flag Coverage

Operands are treated as flags for this table.

| Flag | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|------|-------|-------|---------|-----|------|------|
| if=  | yes   | yes   | yes     | yes | yes  | MUST |
| of=  | yes   | yes   | yes     | yes | yes  | MUST |
| bs=  | yes   | yes   | yes     | yes | yes  | MUST |
| ibs= | yes   | yes   | yes     | yes | yes  | MUST |
| obs= | yes   | yes   | yes     | yes | yes  | MUST |
| cbs= | yes   | yes   | yes     | yes | yes  | MUST |
| skip= | yes  | yes   | yes     | yes | yes  | MUST |
| seek= | yes  | yes   | yes     | yes | yes  | MUST |
| count= | yes | yes   | yes     | yes | yes  | MUST |
| conv= | yes  | yes   | yes     | yes | yes  | MUST |
| files= |     | yes   | yes     |     | yes  | MUST |
| fillchar= |  | yes   |         |     | yes  | SHOULD |
| iflag= |     | yes   |         | yes | yes  | SHOULD |
| iseek= |     | yes   |         | yes | yes  | SHOULD |
| oflag= |     | yes   |         | yes | yes  | SHOULD |
| oseek= |     | yes   |         | yes | yes  | SHOULD |
| speed= |     | yes   |         |     | yes  | SHOULD |
| status= |    | yes   | yes     | yes | yes  | MUST |

### conv= values

| Value | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|-------|-------|-------|---------|-----|------|------|
| ascii | yes   | yes   | yes     | yes | yes  | MUST |
| ebcdic | yes  | yes   | yes     | yes | yes  | MUST |
| ibm   | yes   | yes   | yes     | yes | yes  | MUST |
| block | yes   | yes   | yes     | yes | yes  | MUST |
| unblock | yes | yes   | yes     | yes | yes  | MUST |
| lcase | yes   | yes   | yes     | yes | yes  | MUST |
| ucase | yes   | yes   | yes     | yes | yes  | MUST |
| swab  | yes   | yes   | yes     | yes | yes  | MUST |
| noerror | yes | yes   | yes     | yes | yes  | MUST |
| notrunc | yes | yes   | yes     | yes | yes  | MUST |
| sync  | yes   | yes   | yes     | yes | yes  | MUST |
| oldascii |   | yes   |         |     | yes  | SHOULD |
| oldebcdic |  | yes   |         |     | yes  | SHOULD |
| oldibm |     | yes   |         |     | yes  | SHOULD |
| fsync |      | yes   | yes     | yes | yes  | MUST |
| osync |      | yes   | yes     |     | yes  | MUST |
| sparse |     | yes   |         | yes | yes  | SHOULD |
| pareven |    | yes   |         |     | yes  | SHOULD |
| parnone |    | yes   |         |     | yes  | SHOULD |
| parodd |     | yes   |         |     | yes  | SHOULD |
| parset |     | yes   |         |     | yes  | SHOULD |
| excl  |      |       |         | yes |      | WONT |
| nocreat |    |       |         | yes |      | WONT |
| fdatasync |  |       |         | yes | yes  | SHOULD |

### status= values

| Value | POSIX | macOS | OpenBSD | GNU | Ours | Tier |
|-------|-------|-------|---------|-----|------|------|
| none  |       | yes   | yes     | yes | yes  | MUST |
| noxfer |      | yes   | yes     | yes | yes  | MUST |
| progress |   | yes   |         | yes | yes  | SHOULD |
