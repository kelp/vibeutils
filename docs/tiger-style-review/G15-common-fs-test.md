# Tiger Style Review: G15-common-fs-test

**Files reviewed**: 16 files in `src/common/`, 4941 LOC.

---

## src/common/file.zig

### Assertion gaps

`statToFileInfo` (line 17), `fstatatToFileInfo` (line 65), and `statFile`
(line 162) perform multiple `@intCast` conversions on raw C values (`size`,
`mode`, `uid`, `gid`, `nlink`, `dev`) with no pre-assertions that the values
fit the target type. An `nlink` count that overflows `u32`, for example, will
panic in debug and silently truncate in release. Minimum: assert each source
value fits before casting.

`formatPermissions` (line 224) has a single buffer-size guard (`buf.len < 10`)
but no assertion that `mode` is within the 12-bit range 0–0o7777. A caller
passing an arbitrary `mode_t` that has upper bits set would silently corrupt
the permission string.

`currentTimestampSeconds` (line 287) and `currentTimestampNanoseconds`
(line 294) discard the return value of `clock_gettime` with `_ =`. If the
call fails (rare, but possible if `CLOCK_REALTIME` is unavailable), `ts`
contains uninitialized data and the function returns garbage. The return value
should be checked and the function should return an error or assert.

`getUserName` (line 333) and `getGroupName` (line 353) check `name.len < buf.len`
(strict less-than) to decide whether to copy. When `name.len == buf.len` the
name is silently dropped and the function falls back to the numeric ID. The
correct condition is `<=`, and the discarded-name path deserves at least a
comment explaining the intent.

### Line length

Line 314 is 119 columns (the month-name array literal). Hard limit is 100.

### Types / division

`formatSizeKilobytes` (line 282): uses bare `/` operator for integer division.
Per Tiger Style, division must use `@divFloor`, `@divExact`, or `@divTrunc`
to make intent explicit. The rounding-up pattern `(size + 1023) / 1024` should
be `@divTrunc(size + 1023, 1024)` or expressed as `std.math.divCeil`.

### Comments / why

The `<< 8` bit-shift used to pack `dev_major` and `dev_minor` into a single
`u64` at lines 106 and 194 appears three times across `file.zig` and
`directory.zig` with no explanation of the encoding. The traditional
`makedev(major, minor)` formula is `(major << 8) | minor` for old-style
device numbers, but `statx` already provides the fields separately, so this
packed representation is an arbitrary convention that should be documented.

### Code duplication

The statx pattern (lines 65–128 and 162–205) is duplicated nearly verbatim
between `fstatatToFileInfo` and `FileInfo.statFile`. The Linux branch in both
builds `FileInfo` from `linux.Statx` with identical field assignments.
Extracting a helper `fileInfoFromStatx(sx: linux.Statx) FileInfo` would
eliminate the duplication.

---

## src/common/file_ops.zig

### Line length

The function signature for `setPermissions` at line 28 is 170 columns. The
four `printWarningWithProgram` call-sites at lines 46, 48, 61, and 63 range
from 145 to 181 columns. All exceed the 100-column hard limit.

### Assertion gaps

`setPermissions` (line 28) accepts `mode: std.posix.mode_t` but applies `&
0o7000` and `& 0o0777` masks without asserting that `mode` is a valid 12-bit
mode value. An out-of-range mode reaching `fchmod` could produce a confusing
kernel error with no indication of the bad input.

`copyFileContents` (line 169): the `while (true)` loop has no explicit upper
bound. It terminates only on `EndOfStream` or a read error. Tiger Style
requires either a documented justification or a counter with a max-iteration
assertion. The justification exists (copy until EOF), but it is not stated.

`isSameFileHandle` (line 138) uses the magic literal `0x1000` for
`AT_EMPTY_PATH` with a comment explaining its meaning. However, the same
`EMPTY_PATH` constant is available as `linux.AT.EMPTY_PATH` (used correctly
in `fstatatToFileInfo` in `file.zig`). Using the named constant removes the
need for the comment.

---

## src/common/directory.zig

### Assertion gaps

`EntryFilter.shouldInclude` (line 82) accesses `name[0]` unconditionally at
line 84 without checking `name.len > 0`. If the OS or a test passes an
empty name, this is a panic. Assert `name.len > 0` at the top of the
function, or restructure to check length first.

### Line length

Line 4 (`FileSystemIdSet` type alias) is 124 columns. Line 157 is 103
columns. Both exceed 100.

---

## src/common/path.zig

### Function length

`canonicalizeMissing` (lines 84–205) is 122 lines, 74% over the 70-line
limit. The function has three distinct phases: (1) build an absolute path,
(2) resolve as much as possible via `realPathDupe`, (3) clean remaining
components. Each phase should be a separate helper.

### Assertion gaps

Zero assertions in any of the four public/private functions. `canonicalizeMissing`
and `canonicalizeParentMustExist` both operate on caller-supplied paths with no
invariant assertions (e.g., asserting the result starts with `/` before
returning, asserting `resolved_count <= all_components.items.len`).

### Line length

Twelve test lines exceed 100 columns (lines 223, 229, 266, 274, 292, 298,
304, 331, 336, 343, and surrounding context). The long lines all originate
from inline test assertions passing both `testing.allocator` and `testing.io`
in the same call. Adding trailing commas and letting `zig fmt` wrap would
fix them.

### Types

`usize` is used for `prefix_len`, `pos`, `resolved_count`, and `try_count`
(lines 119–131). These index into `ArrayListUnmanaged` which requires `usize`,
so the usage is stdlib-bound and acceptable. However, `resolved_count` is
compared against `all_components.items.len` (both `usize`) without an
assertion that `resolved_count <= all_components.items.len` before the slice
at line 157.

### Bounded loops

The inner `for` loop inside the `while (try_count > 0)` loop at lines 125–136
is O(n²) in the number of path components. For the common case this is fine,
but there is no assertion on a maximum number of components (no path depth
limit). A path with many thousands of components could be slow; a comment
noting the O(n²) cost and why it is acceptable would satisfy Tiger Style.

---

## src/common/mode.zig

### Function length

`applyClause` (lines 113–210) is 97 lines, 39% over the 70-line limit.
The function handles three distinct sub-problems: parsing the who-specifier,
detecting permission-copying clauses, and parsing permission characters with
umask application. Extract at least `parseWho` and `parsePermChars` as
separate helpers.

### Assertion gaps

None of the public or internal functions contain any `std.debug.assert` calls.
`parseOctal` has good early-return guards but no assertions. `toOctal` and
`fromOctal` are trivial but Tiger Style requires at minimum an assertion that
the octal value fits within 12 bits (0–0o7777). `parseSymbolic` should assert
`mode_str.len > 0` (the empty-string case is handled by the comma-split
returning an empty clause, but only detected two levels deep).

### Magic literals

`applyClause` uses the literal `8` (line 244: `if (perms & 8 != 0)`) for the
setuid/setgid bit in the internal `perms` bitmask, and `16` (line 262) for
sticky. These should be named constants (`PERM_SPECIAL = 8`, `PERM_STICKY =
16`) or at minimum a comment alongside each. The rwx bits use `7`, also
unnamed.

---

## src/common/env.zig

Clean. The file is 42 lines, the logic is simple, and the platform guards are
well-commented. No Tiger Style violations.

---

## src/common/time.zig

### Function length

`parseTimeString` (lines 60–132) is 73 lines, 4% over the limit. The number-
parsing section (lines 99–131) could be split into a small `parseFloatNanos`
helper, bringing both under 70 lines.

### Assertion gaps

`parseTimeString` calls `std.fmt.parseFloat` and converts via `@intFromFloat`
(line 131) after checking for overflow against `maxInt(u64)` as a float
comparison. There is no assertion that the float result is finite and
non-negative immediately before the cast; the preceding checks cover it, but
a `std.debug.assert(total_nanos >= 0 and total_nanos <= ...)` paired assertion
would be safer.

### Line length

Lines 146–149, 154, 161–162, 168, 174, and 187 are all 105–110 columns in
the test section. The pattern is `@intFromFloat(decimal * constant)` inside
`expectEqual`; use an intermediate `const expected =` to keep lines short.

---

## src/common/relative_date.zig

### Function length

`formatRelativeDate` (lines 66–139) is 74 lines, just over the limit. The
long if-else chain comparing time thresholds is the problem. Extracting a
helper `formatRelativeDiff(diff_seconds: i128, config: RelativeDateConfig,
allocator: Allocator) ![]u8` that handles all the relative-time branches
would bring both functions within 70 lines.

### Assertion gaps

`formatRelativeDate` performs no input assertions. `diff_ns < 0` is handled
by branching to `formatAbsoluteDate`, but there is no assertion that
`max_relative_age_days` is sane (e.g., not zero). `formatAbsoluteDate`
(line 144) calls `@intCast(timestamp_s)` on an `i128`-derived `i64` without
asserting that the value fits in the `u64` expected by `EpochSeconds.secs`.

### Coupling

`formatAbsoluteDate` (line 144) calls `@import("file.zig")` inside the
function body at lines 153 and 176 to get the current timestamp. Importing
inside a function body is unusual in this codebase and hides the dependency.
The current time should be a parameter, or the import should move to the top
of the file. This also makes testing `formatAbsoluteDate` harder without a
real clock.

### Line length

Lines 46, 166, 169, and 244 exceed 100 columns.

---

## src/common/user_group.zig

### Assertion gaps

`getUserById` (line 170) and `getGroupById` (line 183) call `std.mem.span` on
C string pointers with no assertion that the pointer is non-null (it is
non-null because `getpwuid`/`getgrgid` returning null is checked above, but
the connection is implicit). A brief assertion or comment would make the
safety argument explicit.

`getCurrentUserId` (line 194) performs `@intCast(getuid())`. POSIX guarantees
`getuid()` returns a valid `uid_t`, but the cast is to `std.posix.uid_t` and
the type alias is the same type — so this cast is a no-op that could be
removed to eliminate confusion.

### Line length

Lines 217, 222, 324, and 328 exceed 100 columns (long string literals in
`expectError` test calls).

---

## src/common/git.zig

### Bounded loops / no recursion

`findGitRoot` (lines 174–215) uses an unbounded `while (true)` loop (line 189)
that walks up the directory tree. There is no cap on the number of ascents.
Per Tiger Style, every loop must have a fixed upper bound. A filesystem with
a very deep directory tree or a pathological path could loop many hundreds of
times. Add a `const max_ascents: u32 = 64` constant and a counter with an
assertion, breaking out (returning `null`) if the limit is exceeded.

### Assertion gaps

`parsePorcelainOutput` (line 125) and `refreshStatus` (line 92) contain no
assertions. `parsePorcelainOutput` assumes `line[0..2]` is safe because it
checks `line.len < 3` at line 128, but that guard is a `continue` rather than
an assertion of the positive-space invariant. For infrastructure called by
many utilities, asserting `line.len >= 3` before accessing `line[0..2]` is
more defensible.

`makeRelativePath` (line 152) returns the original `file_path` slice unchanged
when the path is already relative, or when it cannot be made relative. The
caller's `defer` at lines 83–87 then conditionally frees based on pointer
comparison. This is a subtle invariant that is easy to break — it should be
asserted or at minimum given a why-comment explaining the ownership rule.

### Comments

The `REFRESH_INTERVAL_NS` constant (line 42) is defined but never used in
the code — `refreshStatus` is called only lazily on first access. The unused
constant and its stale comment are misleading.

---

## src/common/prompt.zig

### Error handling

`writer.flush() catch {}` at line 23: the empty catch is intentional (a
failed flush still leaves the write visible, and prompting should proceed).
A brief comment stating why the flush failure is acceptable would satisfy
Tiger Style's requirement to justify silent error drops.

### Line length

Line 21 is 105 columns.

---

## src/common/privilege_test.zig

### API inconsistency / stale code

`FakerootContext.init` (line 58) takes `(allocator, io)`. `requiresPrivilege`
(line 83) takes `(io)`. But `privilege_test_integration.zig` calls both
without the `io` parameter (lines 87, 90, 112, 136, 143, 156, 182, 218). This
is either a compile error that is never exercised, or the integration file
targets a stale API and is effectively dead. The mismatch should be resolved
— either the signatures need to be updated or the integration tests updated to
pass the `io` parameter.

### Error handling

`checkCommandExists` (line 110) runs a `which fakeroot` subprocess. If the
process fails to launch, the error is swallowed by the `catch return false`.
The justification ("command not found = false") is reasonable, but the
`GeneralPurposeAllocator` is allocated and freed inline (lines 122–124) within
a function that is documented as a fakeroot detector. This GPA allocation
happens only in non-test builds, but its existence is surprising. A comment
explaining why a local GPA is used here instead of taking an allocator
parameter would help.

### Comments

The `TestArena` doc comment (line 6–8) says "Zig 0.14 test runner
incompatibility" — the project now targets 0.16. The referenced issue comment
should be verified and the version number updated.

---

## src/common/privilege_test_integration.zig

### Error handling / stale API

Multiple tests call `privilege_test.FakerootContext.init(allocator)` (lines 87,
112, 136, 143) and `privilege_test.requiresPrivilege()` (lines 90, 156, 182,
218) without the required `io` parameter. If these tests ever compile and run,
they will fail. The integration file appears to target an older version of the
`privilege_test` API.

Several tests use `std.process.Child.run` (lines 167) and `result.term.Exited`
— the `.Exited` variant is from the old pre-0.16 API (0.16 uses `.exited`).
This makes the file a collection of tests that likely do not compile against
the current toolchain.

### Line length

Lines 45, 56, 255 exceed 100 columns.

### Missing why-comments

`testCrossUtilityWorkflow` (line 255) is a `pub fn` that is exported but
never called from within the file. No comment explains its intended caller or
how it fits into the test infrastructure.

---

## src/common/test_utils.zig

### Bounded loops

`stripAnsiCodes` (lines 207–273) contains an OSC-sequence inner loop at lines
239–251 that iterates until it finds a BEL or ST terminator. An input with an
unterminated OSC sequence (no `\x07` or `\x1b\\`) will scan to the end of
input without breaking, which is handled correctly by the outer `i < input.len`
bound — but this is not obvious. An upper-bound comment or assertion stating
that the inner loop always terminates within `input.len` iterations would
clarify intent.

### Line length

Lines 45, 59, and 470 exceed 100 columns.

### Types

`usize` for `i` (line 211) is required by slice indexing, so it is
stdlib-bound and acceptable.

### Naming

`expectStdoutContains` and `expectStderrContains` (lines 181–192) call
`try testing.expect(false)` to indicate failure. The failure message will
read "expected true" with no context about what was not found. Prefer
`return error.TestExpectedContains` or `testing.expectStringContains` if
available, or at minimum a comment explaining why `expect(false)` is used
here.

---

## src/common/test_utils_privilege.zig

### Stale API

`TestUtils.runCommand` (line 30) and `runCommandExpectError` (line 49) call
`std.process.Child.run` directly, which is the pre-0.16 API. The project-wide
pattern is `std.process.run(allocator, io, .{...})`. Using the old API bypasses
the 0.16 `Io` interface.

`getBinaryPath` (line 109) uses `std.fs.cwd()` (line 123), `std.fs.path.join`
(lines 120, 134, 137), and `createTestSubdir` (line 98) uses `std.fs.Dir`
and `temp_dir.dir.makeOpenPath`. All of these are pre-0.16 `std.fs` APIs.
In 0.16, the filesystem API moved to `std.Io.*`. These usages suggest this
file was not migrated during the 0.15→0.16 transition.

### Line length

Lines 30, 49, 82, 98, 101, 152, and 282 exceed 100 columns.

### Ownership hazard

`getTempDir` (line 23) stores a `?TmpDir` by value inside `TestUtils` and
returns a copy of the `TmpDir` on line 25. The caller then holds a copy of
the `TmpDir` struct while the original lives in `TestUtils`. When `TestUtils.deinit`
runs, it calls `tmp.cleanup()` on the stored copy. If the caller's copy also
calls cleanup (or the test framework does), the directory is cleaned up twice.
The function should return a pointer to the stored `TmpDir`, not a copy.

---

## src/common/test_dir.zig

Clean for its scope. The file is well-structured and consistently uses the
0.16 `io`-threaded APIs. One minor note:

`getPath` (line 52) calls `realPathFileAlloc`, dereferences the result, then
immediately `dupe`s and frees the original. The comment on lines 54–55
explains the why (debug-allocator size mismatch with `:0` vs `[]u8`). This is
a good non-obvious justification and satisfies Tiger Style's why requirement.

---

## Summary

| Category | Count |
|---|---|
| Function-length | 4 |
| Line-length | ~50 (spread across 9 files) |
| Assertion gaps | 14 |
| Recursion/unbounded loops | 1 (`findGitRoot`) |
| Error handling | 5 |
| Naming | 2 |
| Variable scope | 0 |
| Comments | 5 |
| Types/division | 3 |
| Performance | 1 (O(n²) in `canonicalizeMissing`) |

**Overall impression**: The production logic in `mode.zig`, `path.zig`, and
`file.zig` is reasonably solid, but assertion density is well below the Tiger
Style minimum of two per function — notable because these modules underpin
every utility in the project. The `privilege_test_integration.zig` and
`test_utils_privilege.zig` files appear to have been left behind during the
0.15→0.16 migration and likely do not compile against the current toolchain;
they should be audited and updated or removed before they create false
confidence in test coverage.
