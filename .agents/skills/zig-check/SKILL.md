---
description: Audit Zig code for 0.16.0 correctness
disable-model-invocation: true
---

# /zig-check [file]

Audit Zig source files for common Zig 0.16.0 mistakes. If a file
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

1. **Deleted / moved API usage (0.16 namespace and signature
   changes):**
   - `std.io.getStdOut` / `std.io.getStdErr` -- removed; use the
     buffered writer pattern with `std.Io.File.stdout()`.
   - `std.fs.cwd` / `std.fs.File` / `std.fs.Dir` -- moved to
     `std.Io.Dir.cwd` / `std.Io.File` / `std.Io.Dir`.
   - `std.io.fixedBufferStream` -- removed; use
     `std.Io.Reader.fixed(data)` / `std.Io.Writer.fixed(buffer)`.
   - `std.process.argsAlloc` -- removed; use
     `init.minimal.args.toSlice(...)`.
   - `std.os.environ` / `std.posix.getenv` / `std.posix.setenv` --
     removed; plumb `init.environ_map` instead.
   - `usingnamespace` -- removed from language.
   - `async` / `await` -- removed from language.
   - `std.BoundedArray` -- use `ArrayListUnmanaged.initBuffer`.
   - Managed `std.ArrayList(T).init(allocator)` -- use
     `std.ArrayListUnmanaged(T) = .empty` with allocator-per-call.

2. **Positional writer for stdout/stderr (issue #5):**
   - `.stdout().writer(` / `.stderr().writer(` -- positional mode
     ignores O_APPEND, breaks shell `>>` on macOS. Use
     `.stdout().writerStreaming(io, &buf)` /
     `.stderr().writerStreaming(io, &buf)`.

3. **Missing `io` parameter on blocking APIs:**
   - `file.close()` / `file.read(` / `file.write(` /
     `dir.openDir(` / `dir.createDir(` etc. without `io` as the
     first argument -- 0.16 requires `io: std.Io` plumbed in.

4. **`runUtil`-style functions using `anytype` writers or missing
   `io`:**
   - Signature must be
     `(allocator, io: std.Io, args, *std.Io.Writer, *std.Io.Writer) !u8`.

5. **takeDelimiterExclusive in while loops:**
   - `while` loop calling `takeDelimiterExclusive` on stdin --
     hangs on stdin in unit tests. Use `appendRemaining` or the
     `runUtilWithInput` split.

6. **Missing writer flush:**
   - `stdout_writer` or `stderr_writer` created without a
     corresponding `defer ... flush() catch {}`.

7. **ArrayList without allocator:**
   - `.append(`, `.appendSlice(`, `.deinit()` etc. without
     allocator as the first argument (for `ArrayListUnmanaged`).

8. **Ambiguous format strings:**
   - `"{}"` in print/format calls -- must use `{s}`, `{d}`,
     `{any}`, etc.

9. **Runtime signed division:**
   - `/` operator on values that could be runtime signed integers
     -- use `@divTrunc`, `@divFloor`, or `@divExact`.

10. **`@Type(...)` reflection use:**
    - `@Type(.{ .int = ... })` etc. -- replaced by `@Int`,
      `@Tuple`, `@Struct`, `@Enum`, `@Union`, `@Fn`, `@Pointer`,
      `@EnumLiteral` in 0.16.

11. **Deprecated `indexOf*` aliases:**
    - `std.mem.indexOf`, `indexOfScalar`, `indexOfPos`,
      `lastIndexOf`, `lastIndexOfScalar` -- still compile (as
      aliases) but prefer the canonical `find`, `findScalar`,
      `findPos`, `findLast`, `findScalarLast` etc.

#### Warnings (should fix):

12. **Wrong exit code for arg errors:**
    - `error.UnknownFlag`, `error.MissingValue`, or
      `error.InvalidValue` returning `general_error` (1) instead
      of `misuse` (2).

13. **Inconsistent buffer sizes:**
    - I/O buffers not 8192 bytes (some legacy code uses 4096 --
      flag for new code only).

14. **Direct stderr instead of printErrorWithProgram:**
    - Writing error messages directly to stderr instead of using
      `common.printErrorWithProgram`.

15. **Security theater:**
    - Path validation checking for `"../"` or similar traversal.
    - Maintaining "protected" file lists.
    - Any path-based security checks (trust the OS).

16. **Stdin-dependent unit tests:**
    - Filter utilities with unit tests that read from process
      stdin instead of an injected `std.Io.Reader.fixed(input)` --
      these will hang.

17. **Missing test allocator / io:**
    - Tests using `std.heap.page_allocator` or hardcoded
      allocators instead of `testing.allocator`.
    - Tests calling `io`-taking APIs without passing
      `std.testing.io`.
    - Privileged tests using `testing.allocator` instead of
      `privilege_test.TestArena`.

18. **`File.Stat.atime` used without null-check:**
    - 0.16 made `atime` optional; bare access without
      `orelse error.FileAccessTimeUnavailable` (or equivalent)
      will fail to compile or silently propagate `null`.

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

All files pass. No Zig 0.16.0 issues found.
```

### 5. Suggest fixes

For each critical issue, include a one-line fix suggestion. For
example:

- "Replace `std.fs.cwd()` with `std.Io.Dir.cwd()` and pass `io`
  to subsequent file/dir methods."
- "Replace `.stdout().writer(io, &buf)` with
  `.stdout().writerStreaming(io, &buf)` (issue #5 regression)."
- "Add `io: std.Io` parameter to `runUtil`; change writer
  parameters from `anytype` to `*std.Io.Writer`."
- "Replace `while (reader.takeDelimiterExclusive(...))` with
  `reader.appendRemaining()`."
- "Add `defer stdout.flush() catch {};` after writer creation."
- "Change `list.append(val)` to `list.append(allocator, val)`."
- "Change `"{}"` to `"{s}"` (or appropriate specifier)."
- "Change `return @intFromEnum(common.ExitCode.general_error)`
  to `misuse` for arg parse errors."
- "Replace `@Type(.{ .int = ... })` with `@Int(.unsigned, N)`."
- "Replace `std.process.argsAlloc(allocator)` with
  `init.minimal.args.toSlice(init.arena.allocator())`."
