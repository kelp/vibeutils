# Integration Test Audit: stat

**Date**: 2026-03-28
**Test file**: tests/utilities/stat_test.sh
**Flags spec**: docs/specs/stat-flags.md
**Platform spec**: docs/specs/stat-macos.txt
**Test run**: 19 tests, 19 passed, 0 failed

## Executive Summary

NEEDS_FIXES

All 19 tests pass. However, the test suite has a fundamental
orientation problem: `stat-flags.md` documents this as a GNU
interface implementation, but the tests include no output-format
verification for 24 of the 26 implemented `%` directives, no
`--printf` test at all, no terse field-by-field verification,
no file-system mode field verification, and no multi-file
behavior test. Default output is verified only by substring
presence ("File:", "Size:", "Inode:"), not by structure or
field values. Several tests are exit-code-only.

The BSD flags (`-F`, `-f format`, `-l`, `-n`, `-q`, `-r`,
`-s`, `-t timefmt`, `-x`) are all MUST-tier per the spec, all
absent from the implementation, and all absent from the tests.
This is a conscious design choice (GNU interface only), but the
audit notes the coverage gap.

---

## Test Inventory

| Test Name | Verification Type | Verdict |
|-----------|------------------|---------|
| stat binary | binary exists | Weak |
| stat --help | exit code 0 | Weak |
| stat --version | exit code 0 | Weak |
| stat default output has expected fields | substring presence | Weak |
| stat -c '%s' shows file size | exact value "6" | Strong |
| stat -c '%F' shows file type | exact string "regular file" | Strong |
| stat -c '%n' shows file name | exact path string | Strong |
| stat --format='%s' syntax works | exact value "6" | Strong |
| stat shows symbolic link type | exact string "symbolic link" | Strong |
| stat -L follows symlinks | exact string "regular file" | Strong |
| stat -t produces terse output | line count + filename substring | Weak |
| stat -f shows file system info | exit 0 + "Block" substring | Weak |
| stat invalid flag exits 2 | exit code only | Weak |
| stat missing operand exits 2 | exit code only | Weak |
| stat nonexistent file exits 1 | exit code only | Weak |
| stat nonexistent shows 'No such file' | stderr substring | Strong |
| stat permission denied shows correct message | stderr substring | Strong |
| stat regular file type string | stdout substring | Weak |
| stat directory type string | stdout substring | Weak |

---

## Findings

### [CRITICAL] Default output format not verified structurally

**Location**: tests/utilities/stat_test.sh:28

**Problem**: The default output test checks only that three
keywords appear anywhere in output. It does not verify: line
count, field ordering, field separators, octal permission
format, timestamp format, or the "Access:", "Modify:",
"Change:", " Birth:" labels. A regression that scrambles the
output order or swaps field values would pass.

**Fix**:
```bash
# Check default output structure line-by-line
local line1 line2 line3 line4 line5 line6 line7 line8
line1=$(echo "$output" | sed -n '1p')
line2=$(echo "$output" | sed -n '2p')
line3=$(echo "$output" | sed -n '3p')
line4=$(echo "$output" | sed -n '4p')
line5=$(echo "$output" | sed -n '5p')
line6=$(echo "$output" | sed -n '6p')
line7=$(echo "$output" | sed -n '7p')
line8=$(echo "$output" | sed -n '8p')

[[ "$line1" =~ "  File: " ]]
[[ "$line2" =~ "  Size: " && "$line2" =~ "Blocks: " && \
   "$line2" =~ "IO Block: " ]]
[[ "$line3" =~ "Device: " && "$line3" =~ "Inode: " && \
   "$line3" =~ "Links: " ]]
[[ "$line4" =~ "Access: (" && "$line4" =~ "Uid: " && \
   "$line4" =~ "Gid: " ]]
[[ "$line5" =~ "Access: " ]]  # timestamp
[[ "$line6" =~ "Modify: " ]]
[[ "$line7" =~ "Change: " ]]
[[ "$line8" =~ " Birth: " ]]
```

---

### [CRITICAL] --printf flag has zero test coverage

**Location**: tests/utilities/stat_test.sh (absent)

**Problem**: `--printf` is a SHOULD-tier flag documented in
`stat-flags.md` and implemented in `src/stat.zig:117`. It
differs from `--format` in that it interprets backslash
escapes (`\n`, `\t`) and does not add a trailing newline. The
unit test at stat.zig:1325 covers the escape interpretation,
but there is no integration test verifying the binary's
`--printf` flag end-to-end.

**Fix**:
```bash
# --printf does not add trailing newline
output=$("$binary" --printf='%s' "$tmpfile")
if [[ "$output" == "6" ]]; then
    print_test_result "stat --printf='%s' shows size" "PASS"
else
    print_test_result "stat --printf='%s' shows size" "FAIL" \
        "Expected '6', got '$output'"
fi

# --printf interprets \n escape
output=$("$binary" --printf='%n\n%s\n' "$tmpfile")
local expected_printf="${tmpfile}
6"
if [[ "$output" == "$expected_printf" ]]; then
    print_test_result "stat --printf interprets \\n escape" "PASS"
else
    print_test_result "stat --printf interprets \\n escape" "FAIL" \
        "Expected two lines, got: '$output'"
fi

# --printf with no trailing newline (raw byte check)
local printf_out
printf_out=$(printf '%s' \
    "$("$binary" --printf='%s' "$tmpfile")")
if [[ ${#printf_out} -eq 1 ]]; then
    print_test_result "stat --printf no trailing newline" "PASS"
else
    print_test_result "stat --printf no trailing newline" "FAIL" \
        "Output had unexpected length: ${#printf_out}"
fi
```

---

### [CRITICAL] Terse output fields not verified

**Location**: tests/utilities/stat_test.sh:100-108

**Problem**: The `-t` test verifies only that output is one
line and contains the filename. GNU terse format is a
space-separated record with 14 fixed fields in a defined
order: `name size blocks mode uid gid device inode nlink
atime mtime ctime blksize blocks`. A regression that drops
or reorders fields would pass. The implementation at
stat.zig:779 emits exactly 14 space-separated fields; the
test verifies none of them.

**Fix**:
```bash
output=$("$binary" -t "$tmpfile" 2>/dev/null)
IFS=' ' read -ra fields <<< "$output"
if [[ ${#fields[@]} -eq 14 ]]; then
    print_test_result "stat -t has 14 fields" "PASS"
else
    print_test_result "stat -t has 14 fields" "FAIL" \
        "Expected 14 fields, got ${#fields[@]}"
fi
# Field 0 = path, field 1 = size
if [[ "${fields[0]}" == "$tmpfile" && "${fields[1]}" == "6" ]]; then
    print_test_result "stat -t field[0]=path field[1]=size" "PASS"
else
    print_test_result "stat -t field[0]=path field[1]=size" "FAIL" \
        "Got: fields[0]=${fields[0]} fields[1]=${fields[1]}"
fi
```

---

### [CRITICAL] -f filesystem output fields not verified

**Location**: tests/utilities/stat_test.sh:113-120

**Problem**: The `-f` test verifies exit 0 and that the
string "Block" appears somewhere. It does not verify the
presence of the ID, Namelen, Type, Blocks: Total/Free/
Available, Inodes: Total/Free, Mount, or From fields.
The implementation at stat.zig:820-841 emits 7 labelled
lines; the test verifies one keyword.

**Fix**:
```bash
output=$("$binary" -f "$tmpfile" 2>/dev/null)
local fs_tests=(
    '  File: '
    'Block size: '
    'Blocks: Total: '
    'Inodes: Total: '
    ' Mount: '
)
for expected in "${fs_tests[@]}"; do
    if [[ "$output" == *"$expected"* ]]; then
        print_test_result "stat -f contains '$expected'" "PASS"
    else
        print_test_result "stat -f contains '$expected'" "FAIL" \
            "Missing in output"
    fi
done
```

---

### [IMPORTANT] Format directives: 22 of 26 have no test

**Location**: tests/utilities/stat_test.sh (absent)

**Problem**: The implementation supports 26 `%` format
directives (`%a %A %b %B %d %D %f %F %g %G %h %i %m %n
%N %o %s %t %T %u %U %w %W %x %X %y %Y %z %Z`). The test
suite covers only `%s`, `%F`, and `%n`. Missing coverage
includes:
- `%a` / `%A`: octal and symbolic permissions
- `%b` / `%B`: blocks and block size
- `%d` / `%D`: device number decimal/hex
- `%g` / `%G`: gid and group name
- `%h`: hard link count
- `%i`: inode number
- `%m`: mount point
- `%N`: quoted name with symlink arrow
- `%o`: I/O block size
- `%t` / `%T`: major/minor device (for device files)
- `%u` / `%U`: uid and user name
- `%w` / `%W`: birth time (human and epoch)
- `%x` / `%X`: atime (human and epoch)
- `%y` / `%Y`: mtime (human and epoch)
- `%z` / `%Z`: ctime (human and epoch)

Priority fixes: `%a`, `%A`, `%h`, `%i`, `%g`, `%u` — these
are the fields most likely to regress during a refactor.

**Fix** (representative subset):
```bash
# Permissions in octal
output=$("$binary" -c '%a' "$tmpfile" 2>/dev/null)
if [[ "$output" =~ ^[0-7]{3,4}$ ]]; then
    print_test_result "stat -c '%a' is octal mode" "PASS"
else
    print_test_result "stat -c '%a' is octal mode" "FAIL" \
        "Expected octal, got '$output'"
fi

# Permissions in symbolic form
output=$("$binary" -c '%A' "$tmpfile" 2>/dev/null)
if [[ "$output" =~ ^[-dlcbps][rwx-]{9}$ ]]; then
    print_test_result "stat -c '%A' is symbolic mode" "PASS"
else
    print_test_result "stat -c '%A' is symbolic mode" "FAIL" \
        "Expected 10-char symbolic mode, got '$output'"
fi

# Hard link count is a positive integer
output=$("$binary" -c '%h' "$tmpfile" 2>/dev/null)
if [[ "$output" =~ ^[0-9]+$ ]]; then
    print_test_result "stat -c '%h' is numeric" "PASS"
else
    print_test_result "stat -c '%h' is numeric" "FAIL" \
        "Expected integer, got '$output'"
fi

# Inode is a positive integer
output=$("$binary" -c '%i' "$tmpfile" 2>/dev/null)
if [[ "$output" =~ ^[0-9]+$ ]]; then
    print_test_result "stat -c '%i' is numeric" "PASS"
else
    print_test_result "stat -c '%i' is numeric" "FAIL" \
        "Expected integer, got '$output'"
fi

# %N on regular file: quoted name
output=$("$binary" -c '%N' "$tmpfile" 2>/dev/null)
if [[ "$output" == "'${tmpfile}'" ]]; then
    print_test_result "stat -c '%N' regular file quoted name" "PASS"
else
    print_test_result "stat -c '%N' regular file quoted name" "FAIL" \
        "Expected \"'$tmpfile'\", got '$output'"
fi

# %N on symlink: name -> target
output=$("$binary" -c '%N' "$tmplink" 2>/dev/null)
if [[ "$output" == "'${tmplink}' -> '${tmpfile}'" ]]; then
    print_test_result "stat -c '%N' symlink includes arrow" "PASS"
else
    print_test_result "stat -c '%N' symlink includes arrow" "FAIL" \
        "Got '$output'"
fi
```

---

### [IMPORTANT] No multi-file behavior test

**Location**: tests/utilities/stat_test.sh (absent)

**Problem**: `stat` accepts multiple file arguments. There is
no test verifying that passing two files produces two output
blocks, that they are separated correctly, or that a mix of
valid and invalid files reports partial results with exit 1.

**Fix**:
```bash
local tmpfile2
tmpfile2=$(mktemp)
echo "hi" > "$tmpfile2"

# Two valid files produce two output blocks
output=$("$binary" "$tmpfile" "$tmpfile2" 2>/dev/null)
local block_count
block_count=$(echo "$output" | grep -c "^  File:")
if [[ "$block_count" -eq 2 ]]; then
    print_test_result "stat two files produces two blocks" "PASS"
else
    print_test_result "stat two files produces two blocks" "FAIL" \
        "Expected 2 'File:' lines, got $block_count"
fi

# One valid, one invalid: exits 1, still prints valid block
local mixed_out mixed_exit
mixed_out=$("$binary" "$tmpfile" /nonexistent 2>/dev/null)
mixed_exit=$?
if [[ $mixed_exit -eq 1 && "$mixed_out" == *"File:"* ]]; then
    print_test_result "stat partial failure exits 1, prints valid" "PASS"
else
    print_test_result "stat partial failure exits 1, prints valid" "FAIL" \
        "exit=$mixed_exit output='$mixed_out'"
fi

rm -f "$tmpfile2"
```

---

### [IMPORTANT] Default output "regular empty file" type not tested

**Location**: tests/utilities/stat_test.sh (absent)

**Problem**: The implementation at stat.zig:671-674 and
stat.zig:394-399 has a special case: a zero-byte regular
file reports "regular empty file" instead of "regular file".
The `stat regular file type string` test uses a file created
with `create_temp_file "regular file test"` which has 17
bytes, so it never exercises this branch.

**Fix**:
```bash
local emptyfile
emptyfile=$(mktemp)
# emptyfile is zero bytes by default from mktemp
output=$("$binary" -c '%F' "$emptyfile" 2>/dev/null)
if [[ "$output" == "regular empty file" ]]; then
    print_test_result "stat -c '%F' empty file type" "PASS"
else
    print_test_result "stat -c '%F' empty file type" "FAIL" \
        "Expected 'regular empty file', got '$output'"
fi
# Also verify default output contains the string
output=$("$binary" "$emptyfile" 2>/dev/null)
if [[ "$output" == *"regular empty file"* ]]; then
    print_test_result "stat default output empty file type" "PASS"
else
    print_test_result "stat default output empty file type" "FAIL" \
        "Expected 'regular empty file' in output"
fi
rm -f "$emptyfile"
```

---

### [IMPORTANT] Access/Modify/Change/Birth timestamp format not verified

**Location**: tests/utilities/stat_test.sh (absent)

**Problem**: The default output includes four timestamp lines
formatted by `formatTimestamp()` at stat.zig:258. No test
verifies that these lines exist in the default output, that
they match the expected `YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ`
format, or that `%x`, `%y`, `%z` format directives return
non-empty timestamp strings. A change to the timestamp format
would not be caught.

**Fix**:
```bash
# %x (atime) and %X (atime epoch) are consistent
local atime_human atime_epoch
atime_human=$("$binary" -c '%x' "$tmpfile" 2>/dev/null)
atime_epoch=$("$binary" -c '%X' "$tmpfile" 2>/dev/null)
if [[ "$atime_human" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} && \
      "$atime_epoch" =~ ^[0-9]+$ ]]; then
    print_test_result "stat -c '%x'/'%X' atime format" "PASS"
else
    print_test_result "stat -c '%x'/'%X' atime format" "FAIL" \
        "human='$atime_human' epoch='$atime_epoch'"
fi
```

---

### [SUGGESTION] Temp file cleanup uses `rm -f` outside TEMP_DIR

**Location**: tests/utilities/stat_test.sh:19,190

**Problem**: The test creates `tmpfile=$(mktemp)` outside
of `TEMP_DIR`. If the test exits early, `cleanup_test_session`
will not remove it because it is not under `$TEMP_DIR`. The
symlink cleanup on line 190 uses `rm -f "$tmpfile" "$tmplink"`
manually, which would leave the files if the test aborts mid-
way.

**Fix**: Create the temp file under `TEMP_DIR`:
```bash
tmpfile=$(mktemp "$TEMP_DIR/stat_test_XXXXXX")
```

---

### [SUGGESTION] BSD flags: test for clean "unrecognized option" rejection

**Location**: tests/utilities/stat_test.sh (absent)

**Problem**: The BSD-only flags (`-F`, `-r`, `-s`, `-q`,
`-x`) are MUST-tier in the spec and explicitly not
implemented. The `stat invalid flag exits 2` test uses
`--invalid-flag`, not any BSD short flag. If a future
contributor accidentally maps `-r` or `-s` to an unrelated
behavior, no test would catch it.

**Fix**: Add explicit rejection tests for each BSD flag:
```bash
for bsd_flag in -F -r -s -q; do
    test_command_exit_code \
        "stat $bsd_flag is rejected (BSD-only, exit 2)" 2 \
        "$binary" "$bsd_flag" "$tmpfile"
done
```

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4 |
| IMPORTANT | 4 |
| SUGGESTION | 2 |

**Overall assessment: NEEDS_FIXES**

The suite passes 19/19 tests but covers a small fraction of
the implemented surface. The four CRITICAL gaps (default
output structure, `--printf`, terse fields, filesystem
fields) leave entire subsystems unverifiable. The IMPORTANT
gaps (22 unverified format directives, multi-file behavior,
empty-file type, timestamp format) mean the `%`-expansion
engine is exercised end-to-end for only three of 26
directives.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Default output structure not verified
   — tests/utilities/stat_test.sh:28
2. [CRITICAL] --printf flag has zero integration coverage
   — tests/utilities/stat_test.sh (absent)
3. [CRITICAL] -t terse fields not verified
   — tests/utilities/stat_test.sh:100
4. [CRITICAL] -f filesystem output fields not verified
   — tests/utilities/stat_test.sh:113
5. [IMPORTANT] 22 of 26 format directives untested
   — tests/utilities/stat_test.sh (absent)
6. [IMPORTANT] Multi-file behavior untested
   — tests/utilities/stat_test.sh (absent)
7. [IMPORTANT] "regular empty file" branch not exercised
   — tests/utilities/stat_test.sh (absent)
8. [IMPORTANT] Timestamp format not verified
   — tests/utilities/stat_test.sh (absent)
9. [SUGGESTION] Temp file created outside TEMP_DIR
   — tests/utilities/stat_test.sh:19
10. [SUGGESTION] BSD flag rejection not explicitly tested
    — tests/utilities/stat_test.sh (absent)
```

REVIEW COMPLETE - NEEDS_FIXES
