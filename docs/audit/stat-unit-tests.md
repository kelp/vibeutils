# Unit Test Audit: stat

**Date**: 2026-03-28
**Source file**: src/stat.zig
**Flags spec**: docs/specs/stat-flags.md
**Test count**: 41 tests, all pass
**Related audit**: docs/audit/stat-integration-tests.md (integration audit,
NEEDS_FIXES, same date)

---

## Executive Summary

NEEDS_FIXES

41 unit tests, all passing. The suite has good behavioral coverage
for format directives — better than most utilities audited so far.
However, it contains 8 tests that cannot meaningfully fail (the
`trimmed.len > 0` family), 1 test that validates only structure
not values (`stat -c format: permissions octal`), and 6 tests
for the default output that check keyword presence rather than
structure. There are also 10 untested format directives: `%b`,
`%B`, `%D`, `%f`, `%G`, `%m`, `%N`, `%o`, `%t`, `%T`, `%w`,
`%W`, `%x`, `%y`, `%z`, `%Z`. The `-f` filesystem mode has only
two substring-presence assertions and no field-level check.

---

## Test Inventory

| Test Name | Lines | Verification Type | Verdict |
|-----------|-------|------------------|---------|
| stat --help shows usage | 1003 | exit 0 + substring | Behavioral |
| stat -h shows usage | 1017 | exit 0 + substring | Behavioral |
| stat --version shows version | 1028 | exit 0 + version string | Behavioral |
| stat -V shows version | 1042 | exit 0 + "stat" substring | Weak |
| stat missing operand returns misuse | 1053 | exit 2 + stderr substring | Behavioral |
| stat unknown flag returns misuse | 1066 | exit 2 + stderr substring | Behavioral |
| stat nonexistent file returns error | 1079 | exit 1 + "cannot stat" | Behavioral |
| stat default output on regular file | 1092 | keyword presence x9 | Weak |
| stat -c format: file name | 1124 | exact string match | Strong |
| stat -c format: size | 1147 | exact string "5\n" | Strong |
| stat -c format: file type | 1168 | exact string "directory\n" | Strong |
| stat -c format: inode number | 1187 | parse as u64 > 0 | Behavioral |
| stat -c format: permissions octal | 1210 | trimmed.len > 0 | Parse-Only |
| stat -c format: permissions human readable | 1232 | len >= 10 + first byte '-' | Weak |
| stat -c format: user and group IDs | 1254 | parse both as u32 | Behavioral |
| stat -c format: user and group names | 1280 | trimmed.len > 0 | Parse-Only |
| stat -c format: timestamps | 1302 | trimmed.len > 0 | Parse-Only |
| stat --printf interprets escapes | 1325 | exact string "4\n" | Strong |
| stat --format=FMT syntax | 1346 | exact string "5\n" | Strong |
| stat -t terse output | 1367 | len > 0 + startsWith path | Weak |
| stat empty file shows regular empty file | 1392 | exact string | Strong |
| stat directory type | 1412 | exact string "directory\n" | Strong |
| stat symlink without dereference | 1431 | exact string "symbolic link\n" | Strong |
| stat symlink with dereference | 1465 | exact string "regular file\n" | Strong |
| stat multiple files | 1491 | exact string "3\n5\n" | Strong |
| stat -f file system info | 1518 | exit 0 + 2 substrings | Weak |
| stat -c format: hard links | 1542 | exact string "1\n" | Strong |
| stat -c format: device number | 1562 | parse as u64 | Behavioral |
| stat -c format: multiple directives | 1583 | exact string | Strong |
| stat partial failure with multiple files | 1604 | exit 1 + exact stdout + stderr | Strong |
| formatPermissions basic | 1631 | exact string "-rw-r--r--" | Strong |
| formatPermissions directory | 1639 | exact string "drwxr-xr-x" | Strong |
| formatPermissions symlink | 1646 | exact string "lrwxrwxrwx" | Strong |
| formatPermissions setuid | 1653 | exact string "-rwsr-xr-x" | Strong |
| formatPermissions setgid | 1660 | exact string "-rwxr-sr-x" | Strong |
| formatPermissions sticky | 1667 | exact string "drwxr-xr-t" | Strong |
| fileTypeString | 1674 | exact string x7 | Strong |
| fileTypeString unknown mode | 1684 | exact string x2 | Strong |
| stat -- separator | 1691 | exact string "5\n" | Strong |
| stat nonexistent file error message says No such file | 1712 | stderr substrings x2 | Strong |
| stat permission denied error message is not No such file | 1728 | stderr substrings x2 | Behavioral |

---

## Findings

### [CRITICAL] stat -c format: permissions octal — cannot fail

**Location**: src/stat.zig:1210
**Problem**: The test passes `-c '%a'` to a mode-0644 file but
asserts only `trimmed.len > 0`. Any non-empty output — including
a corrupted or wrong-format value — passes. The comment at
line 1227 even acknowledges the umask influence but does not
verify the value. A bug that prints "644" as decimal ("420")
instead of octal would pass this test.

**Fix**:
```zig
// Mode 0644 has no setuid/setgid/sticky bits, so umask cannot
// affect the bits already set. On a standard system the
// output will be exactly "644".
try testing.expectEqualStrings("644\n", stdout_buffer.items);
```
If umask sensitivity is a real concern, at minimum verify the
format is octal digits only:
```zig
for (trimmed) |ch| {
    try testing.expect(ch >= '0' and ch <= '7');
}
try testing.expect(trimmed.len >= 3 and trimmed.len <= 4);
```

---

### [CRITICAL] stat -c format: user and group names — cannot fail

**Location**: src/stat.zig:1280
**Problem**: The test passes `-c '%U'` and asserts
`trimmed.len > 0`. Any non-empty string — including the numeric
UID fallback that `expandFormatDirective` emits when the username
lookup fails — passes. There is no way to distinguish a correct
username from a fallback numeric ID. The test cannot detect a
broken username-lookup path.

**Fix**:
```zig
// The current user's name should not be all digits.
const is_numeric = for (trimmed) |ch| {
    if (ch < '0' or ch > '9') break false;
} else true;
try testing.expect(!is_numeric);
// Should not be empty
try testing.expect(trimmed.len > 0);
```
Or compare against the actual uid and the `getpwuid` lookup
result if a helper is available.

---

### [CRITICAL] stat -c format: timestamps — cannot fail

**Location**: src/stat.zig:1302
**Problem**: The test passes `-c '%X %Y %Z'` (epoch-second
timestamps) and asserts `trimmed.len > 0`. Any output, including
"0 0 0" or empty-after-trim, would pass (well, not the latter,
but "0 0 0" does). There is no check that the values are
positive integers, that there are three of them, or that they
are plausibly recent.

**Fix**:
```zig
var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
const atime = try std.fmt.parseInt(i64, it.next() orelse return error.TestFailed, 10);
const mtime = try std.fmt.parseInt(i64, it.next() orelse return error.TestFailed, 10);
const ctime = try std.fmt.parseInt(i64, it.next() orelse return error.TestFailed, 10);
// Timestamps must be positive (after 1970-01-01)
try testing.expect(atime > 0);
try testing.expect(mtime > 0);
try testing.expect(ctime > 0);
// No fourth token
try testing.expect(it.next() == null);
```

---

### [IMPORTANT] stat -c format: permissions human readable — weak assertion

**Location**: src/stat.zig:1232
**Problem**: The test asserts `len >= 10` and first byte `'-'`.
It does not verify the full 10-character permission string.
A bug that prints "-?????????" or "-rw-------" for a 0644 file
would pass. The `formatPermissions` pure-unit tests at line 1631
do verify the string exactly, but those test the helper function
directly, not the `%A` directive path through
`expandFormatDirective`.

**Fix**:
```zig
// File was created with mode 0o644, so:
try testing.expectEqualStrings("-rw-r--r--\n", stdout_buffer.items);
```

---

### [IMPORTANT] stat -V shows version — weak assertion

**Location**: src/stat.zig:1042
**Problem**: The test asserts that the string "stat" appears
anywhere in stdout. This is trivially satisfied by any string
containing the word "stat". It does not verify `common.version`
is present, unlike the `--version` test at line 1028 which
checks both "stat" and `common.version`.

**Fix**:
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
```

---

### [IMPORTANT] stat -t terse output — weak assertion

**Location**: src/stat.zig:1367
**Problem**: The test verifies `trimmed.len > 0` and that the
output starts with `test_path`. It does not verify the number
of fields, their separators, or any field value. GNU terse
format emits exactly 14 space-separated fields in a defined
order. The implementation at line 779 emits 14 fields, but
the test verifies none of them.

**Fix**:
```zig
var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
var field_count: usize = 0;
while (it.next()) |_| field_count += 1;
try testing.expectEqual(@as(usize, 14), field_count);

// Re-iterate to check field values
it = std.mem.tokenizeScalar(u8, trimmed, ' ');
const f0 = it.next() orelse return error.TestFailed; // path
const f1 = it.next() orelse return error.TestFailed; // size
try testing.expectEqualStrings(test_path, f0);
try testing.expectEqualStrings("5", f1); // wrote "hello"
```

---

### [IMPORTANT] stat -f file system info — weak assertions

**Location**: src/stat.zig:1518
**Problem**: The test asserts exit 0 and that "File:" and
"Block" appear anywhere in output. The implementation emits 7
labelled lines (File, ID/Namelen/Type, Block size, Blocks
Total/Free/Available, Inodes Total/Free, Mount, From). The
test verifies two keywords and ignores all field values and
line structure.

**Fix**:
```zig
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "  File:") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Block size:") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Blocks: Total:") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Inodes: Total:") != null);
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, " Mount:") != null);
```

---

### [IMPORTANT] stat default output — keyword presence only

**Location**: src/stat.zig:1092
**Problem**: The 9-assertion block at lines 1113-1121 checks
that keywords appear somewhere in output. It does not verify
line count (expected: 8), field ordering, or that any value is
correct. The file was written with "hello world" (11 bytes) but
the test does not check that "11" appears as the size. A
regression that prints all fields on one line would pass.

**Fix** (minimal addition, structural verification):
```zig
// Verify exact line count
const line_count = std.mem.count(u8, stdout_buffer.items, "\n");
try testing.expectEqual(@as(usize, 8), line_count);
// Verify size is present
try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "11") != null);
```

---

### [IMPORTANT] Untested format directives (16 of 26)

**Location**: src/stat.zig, expandFormatDirective (lines 362-584)
**Problem**: 16 format directives have no unit test at all:

| Directive | Meaning | Lines |
|-----------|---------|-------|
| `%b` | blocks allocated | 373 |
| `%B` | block size (always 512) | 377 |
| `%D` | device number hex | 385 |
| `%f` | raw mode in hex | 388 |
| `%G` | group name | 406 |
| `%m` | mount point | 422 |
| `%N` | quoted name with symlink arrow | 447 |
| `%o` | optimal I/O transfer size | 459 |
| `%t` | major device type in hex | 471 |
| `%T` | minor device type in hex | 484 |
| `%w` | birth time human-readable | 510 |
| `%W` | birth time epoch seconds | 525 |
| `%x` | atime human-readable | 534 |
| `%y` | mtime human-readable | 549 |
| `%z` | ctime human-readable | 564 |
| `%Z` | ctime epoch seconds | 575 |

Highest-risk gaps:
- `%B` always prints "512" with no conditional — trivial to add
  and verify.
- `%G` (group name) shares the same fallback logic as `%U` but
  has no test at all (unlike `%U` which has a parse-only test).
- `%N` on a symlink should print `'src' -> 'target'` — this
  behavioral branch is untested.
- `%w` / `%W` birth-time tests would verify the macOS-vs-Linux
  platform branch at lines 510-532.

**Fix** (representative subset):
```zig
test "stat -c format: block size %B is always 512" {
    // setup: any file
    const args = [_][]const u8{ "-c", "%B", test_path };
    // ...
    try testing.expectEqualStrings("512\n", stdout_buffer.items);
}

test "stat -c format: %N symlink shows arrow" {
    // setup: symlink -> target
    const args = [_][]const u8{ "-c", "%N", symlink_path };
    // ...
    const expected = try std.fmt.allocPrint(testing.allocator,
        "'{s}' -> '{s}'\n", .{ symlink_path, target_path });
    try testing.expectEqualStrings(expected, stdout_buffer.items);
}

test "stat -c format: %N regular file is quoted" {
    // setup: regular file
    const args = [_][]const u8{ "-c", "%N", test_path };
    // ...
    const expected = try std.fmt.allocPrint(testing.allocator,
        "'{s}'\n", .{test_path});
    try testing.expectEqualStrings(expected, stdout_buffer.items);
}
```

---

### [SUGGESTION] -c format: inode — asserts inode > 0

**Location**: src/stat.zig:1207
**Problem**: The inode test asserts the value is a valid u64
greater than 0. This is reasonable but inode 0 is not a valid
file inode on any real filesystem, so the `> 0` check adds no
information. The test is effectively `parseInt succeeds`, which
is useful. No change needed, but noted for completeness.

---

### [SUGGESTION] Unknown directive fallback not tested

**Location**: src/stat.zig:579
**Problem**: The `else` branch in `expandFormatDirective` at
line 579 prints `%X` literally for unknown directives. No unit
test exercises this fallback. A change to the fallback behavior
(e.g. silently drop unknown directives) would go undetected.

**Fix**:
```zig
test "stat -c format: unknown directive prints literal" {
    // setup: any file
    const args = [_][]const u8{ "-c", "%Q", test_path };
    // ...
    try testing.expectEqualStrings("%Q\n", stdout_buffer.items);
}
```

---

### [SUGGESTION] --printf with no trailing newline not unit tested

**Location**: src/stat.zig (absent)
**Problem**: The `--printf` test at line 1325 verifies that
`%s\n` produces `"4\n"`. This exercises escape interpretation
but not the key behavioral difference from `--format`: that
`--printf` does NOT append a trailing newline when the format
string itself has none. A regression where `--printf` starts
adding a newline unconditionally would not be caught by any
unit test.

**Fix**:
```zig
test "stat --printf does not add trailing newline" {
    // setup: file with known size
    const args = [_][]const u8{ "--printf=%s", test_path };
    // ...
    // "5" with no newline
    try testing.expectEqualStrings("5", stdout_buffer.items);
}
```

---

## Coverage Summary by Flag

| Flag | MUST/SHOULD | Implemented | Has Behavioral Test |
|------|-------------|-------------|---------------------|
| -L / --dereference | MUST | yes | yes (symlink tests) |
| -f / --file-system | SHOULD | yes | weak (keyword only) |
| -c / --format | SHOULD | yes | yes (many, some weak) |
| --printf | SHOULD | yes | yes (escape test only) |
| -t / --terse | SHOULD | yes | weak (no field check) |

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| IMPORTANT | 5 |
| SUGGESTION | 3 |

**Overall assessment: NEEDS_FIXES**

The stat unit tests are in better shape than most utilities
audited here: 21 of 41 tests use exact string matching, and
the pure-function tests for `formatPermissions` and
`fileTypeString` are thorough. The main problems are three
tests that cannot fail (`%a` octal, `%U` username, timestamps),
five structural weaknesses (default output, `-V`, terse output,
`-f` filesystem, `%A` permissions), and 16 format directives
with no unit test at all.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] stat -c format: permissions octal cannot fail
   — src/stat.zig:1210
2. [CRITICAL] stat -c format: user and group names cannot fail
   — src/stat.zig:1280
3. [CRITICAL] stat -c format: timestamps cannot fail
   — src/stat.zig:1302
4. [IMPORTANT] stat -c format: permissions human readable weak
   — src/stat.zig:1232
5. [IMPORTANT] stat -t terse output field count not verified
   — src/stat.zig:1367
6. [IMPORTANT] stat -f filesystem output keyword-only
   — src/stat.zig:1518
7. [IMPORTANT] stat default output no structural verification
   — src/stat.zig:1092
8. [IMPORTANT] 16 format directives untested (%b %B %D %f %G
   %m %N %o %t %T %w %W %x %y %z %Z)
   — src/stat.zig:362-584
9. [SUGGESTION] stat -V missing version-string check
   — src/stat.zig:1042
10. [SUGGESTION] Unknown format directive fallback not tested
    — src/stat.zig:579
11. [SUGGESTION] --printf no-trailing-newline not tested
    — src/stat.zig (absent)
```

REVIEW COMPLETE - NEEDS_FIXES
