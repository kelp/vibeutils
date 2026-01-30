---
description: Audit Zig code for 0.15.1 correctness
disable-model-invocation: true
---

# /zig-check [file]

Audit Zig source files for common Zig 0.15.1 mistakes. If a file
path is given, check that file. Otherwise check all `src/*.zig`
files that were modified in the current git diff (staged and
unstaged).

## Procedure

### 1. Determine target files

If argument provided:
- Check only that file

If no argument:
- Run `git diff --name-only` and `git diff --cached --name-only`
- Filter to `src/*.zig` files
- If no modified Zig files, report "No modified Zig files to
  check" and exit

### 2. Read each target file

Use the Read tool to read the full contents of each file.

### 3. Check for violations

Search each file for these patterns. Report each violation with
file path, line number, and the specific issue.

#### Critical (must fix):

1. **Deleted API usage:**
   - `std.io.getStdOut` or `std.io.getStdErr` -- use buffered
     writer pattern
   - `usingnamespace` -- removed from language
   - `async` / `await` -- removed from language
   - `std.BoundedArray` -- use `ArrayListUnmanaged.initBuffer`

2. **takeDelimiterExclusive in while loops:**
   - `while` loop calling `takeDelimiterExclusive` -- use
     `appendRemaining` instead (hangs on stdin)

3. **Missing writer flush:**
   - `stdout_writer` or `stderr_writer` created without a
     corresponding `defer ... flush() catch {}`

4. **ArrayList without allocator:**
   - `.append(`, `.appendSlice(`, `.deinit()` etc. without
     allocator as first argument (for `ArrayListUnmanaged`)

5. **Ambiguous format strings:**
   - `"{}"` in print/format calls -- must use `{s}`, `{d}`,
     `{any}`, etc.

6. **Runtime signed division:**
   - `/` operator on values that could be runtime signed integers
     -- use `@divTrunc`, `@divFloor`, or `@divExact`

#### Warnings (should fix):

7. **Wrong exit code for arg errors:**
   - `error.UnknownFlag`, `error.MissingValue`, or
     `error.InvalidValue` returning `general_error` (1) instead
     of `misuse` (2)

8. **Inconsistent buffer sizes:**
   - I/O buffers not 8192 bytes (some legacy code uses 4096 --
     flag for new code only)

9. **Direct stderr instead of printErrorWithProgram:**
   - Writing error messages directly to stderr instead of using
     `common.printErrorWithProgram`

10. **Security theater:**
    - Path validation checking for `"../"` or similar traversal
    - Maintaining "protected" file lists
    - Any path-based security checks (trust the OS)

11. **Stdin-dependent unit tests:**
    - Filter utilities with unit tests that read from stdin
      without using `runUtilWithInput` pattern -- these will hang

12. **Missing test allocator:**
    - Tests using `std.heap.page_allocator` or hardcoded
      allocators instead of `testing.allocator`
    - Privileged tests using `testing.allocator` instead of
      `privilege_test.TestArena`

### 4. Report results

Format output as:

```
## /zig-check Results

### <file_path>

CRITICAL: <line>: <description>
CRITICAL: <line>: <description>
WARNING:  <line>: <description>

### <file_path>

No issues found.

---
Summary: X critical, Y warnings across Z files
```

If no issues found in any file:

```
## /zig-check Results

All files pass. No Zig 0.15.1 issues found.
```

### 5. Suggest fixes

For each critical issue, include a one-line fix suggestion. For
example:

- "Replace `std.io.getStdOut()` with buffered writer pattern
  (see zig-patterns skill)"
- "Replace `while (reader.takeDelimiterExclusive(...))` with
  `reader.appendRemaining()`"
- "Add `defer stdout.flush() catch {};` after writer creation"
- "Change `list.append(val)` to `list.append(allocator, val)`"
- "Change `"{}"` to `"{s}"` (or appropriate specifier)"
- "Change `return @intFromEnum(common.ExitCode.general_error)`
  to `misuse` for arg parse errors"
