# POSIX Compliance Coverage Summary

Generated from `docs/specs/*-flags.md` tier
assignments.

## Overview

| Tier | Total | Implemented | Missing |
|------|-------|-------------|---------|
| MUST | 288 | 207 | 81 |
| SHOULD | 220 | 75 | 145 |
| KEEP | 16 | 16 | 0 |
| WONT | 115 | 0 | 115 |
| **Total** | **694** | **298** | **396** |

## MUST Flags — Not Yet Implemented

**81 flags** across 11 utilities.

### chmod

- `-h`
- `-H`
- `-L`
- `-P`

### date

- `-f`
- `-j`
- `-z`

### dd

- `cbs=`
- `files=`
- `ascii`
- `ebcdic`
- `ibm`
- `block`
- `unblock`
- `swab`
- `fsync`
- `osync`
- `noxfer`

### df

- `-n`

### find

- `-X (Global Options)`
- `-d (Global Options)`
- `-f (Global Options)`
- `-x (Global Options)`
- `-nouser (Primaries / Tests)`
- `-nogroup (Primaries / Tests)`
- `-xdev (Primaries / Tests)`
- `-prune (Primaries / Tests)`
- `-links (Primaries / Tests)`
- `-atime (Primaries / Tests)`
- `-ctime (Primaries / Tests)`
- `-ok (Primaries / Tests)`
- `-mindepth (Primaries / Tests)`
- `-execdir (Primaries / Tests)`
- `-amin (Primaries / Tests)`
- `-anewer (Primaries / Tests)`
- `-cmin (Primaries / Tests)`
- `-cnewer (Primaries / Tests)`
- `-mmin (Primaries / Tests)`
- `-ls (Primaries / Tests)`
- `-fstype (Primaries / Tests)`
- `-inum (Primaries / Tests)`
- `-flags (Primaries / Tests)`

### grep

- `-I`
- `-U`
- `-V`
- `-a`
- `-b`
- `-Z`

### id

- `-p`

### ln

- `-h`

### ls

- `-c`
- `-C`
- `-f`
- `-g`
- `-H`
- `-L`
- `-o`
- `-p`
- `-q`
- `-s`
- `-u`
- `-x`
- `-T`

### sort

- `-m`
- `-M`
- `-R`
- `-S`
- `-T`
- `--batch-size`
- `--compress-program`
- `--debug`
- `--files0-from`
- `--parallel`
- `--random-source`
- `--heapsort`
- `--mergesort`
- `--mmap`
- `--qsort`
- `--radixsort`

### tail

- `-b`
- `-r`

## SHOULD Flags — Not Yet Implemented

**145 flags** across 22 utilities.

### cat

- `-l`

### chmod

- `-C`
- `-E`
- `-i`
- `-I`
- `-N`
- `--dereference`
- `--no-preserve-root`
- `--preserve-root`

### chown

- `-n`
- `-x`
- `--dereference`
- `--no-preserve-root`
- `--preserve-root`

### cp

- `-b`
- `-c`
- `-l`
- `-N`
- `-s`
- `-S`
- `-x`
- `-X`
- `--parents`
- `--preserve`
- `--backup`

### cut

- `-w`

### date

- `-n`
- `-v`

### dd

- `fillchar=`
- `iflag=`
- `iseek=`
- `oflag=`
- `oseek=`
- `speed=`
- `oldascii`
- `oldebcdic`
- `oldibm`
- `sparse`
- `pareven`
- `parnone`
- `parodd`
- `parset`

### df

- `-b`
- `-c`
- `-g`
- `-I`
- `-m`
- `-Y`
- `-,`

### du

- `-A`
- `-B`
- `-g`
- `-I`
- `-l`
- `-m`
- `-n`
- `-t`
- `--si`

### env

- `-P`
- `-S`
- `-v`

### find

- `-P (Global Options)`
- `-E (Global Options)`
- `-s (Global Options)`
- `-ipath (Primaries / Tests)`
- `-iregex (Primaries / Tests)`
- `-regex (Primaries / Tests)`
- `-Bmin (Primaries / Tests)`
- `-Bnewer (Primaries / Tests)`
- `-Btime (Primaries / Tests)`
- `-acl (Primaries / Tests)`
- `-depth N (Primaries / Tests)`
- `-gid (Primaries / Tests)`
- `-ignore_readdir_race (Primaries / Tests)`
- `-ilname (Primaries / Tests)`
- `-lname (Primaries / Tests)`
- `-mnewer (Primaries / Tests)`
- `-mount (Primaries / Tests)`
- `-newerXY (Primaries / Tests)`
- `-noleaf (Primaries / Tests)`
- `-noignore_readdir_race (Primaries / Tests)`
- `-okdir (Primaries / Tests)`
- `-quit (Primaries / Tests)`
- `-samefile (Primaries / Tests)`
- `-sparse (Primaries / Tests)`
- `-uid (Primaries / Tests)`
- `-wholename (Primaries / Tests)`
- `-xattr (Primaries / Tests)`
- `-xattrname (Primaries / Tests)`
- `-printf (Primaries / Tests)`
- `-false (Operators)`
- `-true (Operators)`

### grep

- `-D`
- `-d`
- `-J`
- `-M`
- `-O`
- `-p`
- `-S`
- `-u`
- `-X`
- `-y`
- `-z`
- `-P`
- `--label`
- `--line-buffered`
- `--null`
- `--binary-files`
- `--mmap`
- `--include-dir`

### head

- `-z`

### id

- `-a`
- `-A`
- `-F`
- `-P`

### ln

- `-F`
- `-w`
- `-b`
- `--backup`

### ls

- `-b`
- `-B`
- `-D`
- `-e`
- `-G`
- `-I`
- `-O`
- `-P`
- `-U`
- `-v`
- `-w`
- `-W`
- `-X`
- `-y`
- `-@`
- `-%`
- `-,`

### mv

- `-h`
- `-b`
- `--backup`

### rm

- `-x`
- `-W`

### rmdir

- `--ignore-fail-on-non-empty`

### touch

- `-A`

### tr

- `-u`

### wc

- `--libxo`

## KEEP — Vibeutils Extensions

- `du` `--color`
- `du` `--icons`
- `free` `-b`
- `free` `-k`
- `free` `-m`
- `free` `-g`
- `free` `-h`
- `free` `-t`
- `free` `-w`
- `free` `-s N`
- `free` `-c N`
- `ls` `--git`
- `ls` `--icons`
- `ls` `--test-icons`
- `touch` `-V`
- `wc` `--color`

## WONT — Excluded Flags

**115 flags** excluded (obscure GNU-only or OpenBSD-only).

