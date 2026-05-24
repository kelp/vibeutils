# Zig Patterns for vibeutils

This document contains Zig 0.16.x patterns and idioms used in this
codebase. It serves as a quick reference for implementing GNU coreutils
in Zig.

vibeutils builds against Zig 0.16.0 (`build.zig.zon` and `flake.nix`
both pin `0.16.0`); the 0.15 → 0.16 source migration is complete.
The full 0.15.x → 0.16 breaking-change catalog (Writergate-scale APIs
renamed, I/O as an Interface, environ becoming non-global, etc.)
lives in `ZIG_BREAKING_CHANGES.md`. This document focuses on **the
right way to do things in 0.16**; cross-references point at the
breaking-changes doc for migration tables.

> Verification note: every code pattern below was checked against
> `docs/zig-0.16.0-docs.md` and `docs/zig-0.16.0-release-notes.md`. A
> few constructions (notably the buffered-stdout call shape) are
> derived from analogous file APIs because the lang ref only shows the
> unbuffered variant; those cases are flagged inline.

## Memory Management

### Arena Allocator Pattern (preferred for CLI tools)
```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
// All allocations are freed when arena.deinit() is called
```

In 0.16, `ArenaAllocator` is **lock-free and thread-safe**. You no
longer need to wrap it with `ThreadSafeAllocator`, and that wrapper
has been removed from the standard library entirely. The arena can be
used as the backing allocator for an `Io` instance directly.

When using "Juicy Main" (see Command-Line Arguments below), there is
also a process-wide arena available as `init.arena` that the runtime
manages and cleans up at exit.

### General Purpose Allocator (debug builds, leak detection)
```zig
var debug_allocator = std.heap.DebugAllocator(.{}).init;
defer _ = debug_allocator.deinit();
const allocator = debug_allocator.allocator();
```

`DebugAllocator` (formerly `GeneralPurposeAllocator`) is the right
choice for debug builds when you want leak checking. For release
builds, prefer `std.heap.smp_allocator` if you do not have a clear
arena lifetime.

## Command Line Arguments

In 0.16, args and environment variables are **no longer global**.
Both are obtained via the optional first parameter of `main`.

### Recommended: "Juicy Main"
```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // Heap-allocated argv slice, freed when the process exits.
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        // process arg
        _ = arg;
    }

    _ = gpa;
    _ = io;
}
```

`std.process.Init` provides pre-initialized `gpa`, `io`, `arena`,
`environ_map`, `preopens`, plus the raw argv/environ inside
`init.minimal`. This is the recommended shape for vibeutils
utilities — it bundles the allocator, the `Io` instance, and the
args parser together.

### Iterator (no allocation)
```zig
pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    while (args.next()) |arg| {
        // process arg
        _ = arg;
    }
}
```

`Init.Minimal` provides only argv and environ in raw form — useful
for utilities that want to parse arguments without going through an
allocator at all.

### Three legal `main` signatures
- `pub fn main() void` (or `!void`) — no access to argv or env.
- `pub fn main(init: std.process.Init.Minimal) ...` — argv + environ.
- `pub fn main(init: std.process.Init) ...` — full Juicy Main.

The 0.15 `std.process.argsAlloc` / `std.process.argsFree` pair has
been removed. See `ZIG_BREAKING_CHANGES.md` for the migration table.

## I/O Operations

In 0.16, every blocking API takes an `Io` instance as a parameter.
`std.fs.File` was renamed to `std.Io.File`, and most I/O methods grew
an `io: Io` parameter. The `Io` instance comes from "Juicy Main" or is
constructed manually for non-`main` code.

### Standard streams (unbuffered)
```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try std.Io.File.stdout().writeStreamingAll(io, "Hello, world!\n");
}
```

This is the simplest pattern, taken straight from the 0.16 lang ref.
It bypasses buffering — every call goes to the OS directly.

### Standard streams (buffered) — verified against 0.16.0
```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer =
        std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer =
        std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    try stdout.print("count: {d}\n", .{42});
    _ = stderr;
}
```

Use `writerStreaming` (not `writer`) for stdout/stderr.
`writerStreaming` initializes in `.streaming` mode (regular
write syscalls, O_APPEND respected). `writer` initializes in
`.positional` mode (uses pwritev at offset 0, ignores
O_APPEND, breaks shell `>>` redirects on macOS). Same lesson
as 0.15.

The two return the same `std.Io.File.Writer` type, which has
an `.interface: std.Io.Writer` field and a `.flush()` method
on the interface.

### Stdin
```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdin_buf: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;
    _ = stdin;
}
```

Reader and writer have **symmetric** signatures —
`pub fn reader(file: File, io: Io, buffer: []u8) Reader` and
`pub fn writer(file: File, io: Io, buffer: []u8) Writer`.
Both take `io`. (Earlier release-notes examples that show
`file.reader(&.{})` predate the final API.)

### Reading a whole file
```zig
// Via Dir, with a size limit:
const contents = try std.Io.Dir.cwd().readFileAlloc(
    io, file_name, allocator, .limited(1024 * 1024),
);
defer allocator.free(contents);
```

The limit type is `.limited(N)` (or `.unlimited`); reaching the limit
returns `error.StreamTooLong` (formerly `error.FileTooBig`).

### Reading from an open file
```zig
var read_buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &read_buffer);
const contents = try file_reader.interface.allocRemaining(
    allocator, .limited(1024 * 1024),
);
defer allocator.free(contents);
```

### File I/O with explicit buffers
```zig
// Reading with buffer
var read_buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &read_buffer);
const reader = &file_reader.interface;

// Writing with buffer
var write_buffer: [8192]u8 = undefined;
var file_writer = file.writer(io, &write_buffer);
const writer = &file_writer.interface;
defer writer.flush() catch {};
```

Note that `std.io.bufferedReader` / `bufferedWriter` no longer exist.
Buffering is now part of `Io.Reader` / `Io.Writer` and is configured
by passing a buffer to `reader()` / `writer()`. `FixedBufferStream`
was deleted; see Testing below for the replacement.

### Atomic file writes
```zig
var atomic_file = try dir.createFileAtomic(io, dest_path, .{
    .permissions = perms,
    .make_path = true,
    .replace = true,
});
defer atomic_file.deinit(io);

var buffer: [4096]u8 = undefined;
var file_writer = atomic_file.file.writer(io, &buffer);
// write through file_writer ...
try file_writer.flush();
try atomic_file.replace(io);
```

### vibeutils runner pattern
The `runUtil` helper used in our utility entry points threads `io`
alongside the allocator and writers:

```zig
pub fn runUtil(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    common.printErrorWithProgram(
        allocator, stderr_writer, "util",
        "error: {s}", .{"example"},
    );
    return @intFromEnum(common.ExitCode.general_error);
    // io may be needed for file ops, child processes, etc.
    // _ = io; if unused.
}
```

The signature differs from the 0.15 version (`runUtil(allocator,
args, stdout, stderr)`) by the addition of `io`. Writers are now
concrete `*std.Io.Writer`, not generic `anytype` — though `anytype`
is still acceptable when you want to accept any compatible writer.

## Error Handling

The error-set patterns themselves are unchanged in 0.16. A few error
names were renamed (notably `RenameAcrossMountPoints` → `CrossDevice`
and `SharingViolation` → `FileBusy`). Several APIs added
`error.Canceled` to their error sets to support task cancelation; if
you propagate errors with `try`, this is usually invisible. See
`ZIG_BREAKING_CHANGES.md` for the full list.

### Error sets
```zig
const FileError = error{
    PermissionDenied,
    FileNotFound,
    DiskFull,
};

fn readFile() FileError![]u8 {
    return error.FileNotFound;
}
```

### Error union pattern
```zig
fn mayFail() !void {
    try doSomething();

    doSomething() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
}
```

### Common error patterns
```zig
// Ignore errors
doSomething() catch {};

// Convert error to optional
const result = doSomething() catch null;

// Provide default value
const value = getValue() catch 42;

// Handle specific errors
readFile() catch |err| switch (err) {
    error.FileNotFound => return,
    error.PermissionDenied => try stderr.print("Permission denied\n", .{}),
    error.Canceled => return err, // 0.16: surface cancelation
    else => return err,
};
```

## Testing

`std.testing.allocator` is unchanged. 0.16 also introduces
`std.testing.io` — a test-context `Io` analogous to
`std.testing.allocator`. Use it whenever a function under test needs
an `Io` parameter.

### Basic test pattern
```zig
test "description" {
    try std.testing.expect(true);
    try std.testing.expectEqual(@as(i32, 42), 42);
    try std.testing.expectEqualStrings("hello", "hello");
}
```

### Testing with allocator
```zig
test "with allocation" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);
    // Test fails if memory is leaked.
}
```

### Testing with `Io`
```zig
test "with io" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    _ = io;
    _ = cwd;
    // Use io for any I/O calls under test.
}
```

### Capturing output (fixed-buffer writer)
```zig
test "test output" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try myFunction(&writer);
    try std.testing.expectEqualStrings(
        "expected output",
        writer.buffered(),
    );
}
```

`std.Io.Writer.fixed(buffer)` replaces the 0.15
`std.io.fixedBufferStream(buffer).writer()` pattern. The corresponding
read-side helper is `var reader: std.Io.Reader = .fixed(data);`.

### `ArrayList` in tests
```zig
test "list test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.append(gpa, 'a');
    try std.testing.expectEqual(1, list.items.len);
}
```

`ArrayList` is now allocator-per-method (the "unmanaged" form is the
only form). Initialize with `.empty`, and pass the allocator into
every mutating method and `deinit`.

### Privileged tests
The project's `privilege_test.TestArena` rule is unchanged: privileged
tests **must** use `privilege_test.TestArena`, not
`testing.allocator`. This is a vibeutils-specific workaround for a
fakeroot interaction; it pre-dates 0.16 and is independent of the
stdlib changes.

## String Operations

### String comparison
```zig
std.mem.eql(u8, str1, str2)
std.mem.startsWith(u8, haystack, needle)
std.mem.endsWith(u8, haystack, needle)
std.mem.findScalar(u8, haystack, needle) // ?usize
std.mem.find(u8, haystack, needle)       // ?usize, multi-element
```

The `indexOf*` family was renamed to `find*` in 0.16 (`indexOf` →
`find`, `indexOfScalar` → `findScalar`, `indexOfPos` → `findPos`,
`indexOfLast` → `findLast`, etc.). See `ZIG_BREAKING_CHANGES.md` for
the complete rename table.

0.16 also adds a family of `cut*` functions (`cut`, `cutPrefix`,
`cutSuffix`, `cutScalar`, `cutLast`, `cutScalarLast`) that return both
sides of a split in one call — handy for parsing `key=value` strings.

### String manipulation
```zig
// Tokenize
var iter = std.mem.tokenizeAny(u8, input, " \t\n");
while (iter.next()) |token| {
    // process token
}

// Split (includes empty strings)
var iter = std.mem.splitScalar(u8, input, ',');

// Trim
const trimmed = std.mem.trim(u8, input, " \t\n");
```

### Formatting
```zig
// Format to writer (0.16: writer is *std.Io.Writer)
try writer.print("{s}: {d}\n", .{ name, value });

// Format to fixed buffer
var buf: [100]u8 = undefined;
const formatted = try std.fmt.bufPrint(&buf, "{d}", .{42});

// Format with allocator
const formatted = try std.fmt.allocPrint(allocator, "{s}-{d}",
    .{ prefix, num });
defer allocator.free(formatted);
```

`std.fmt.format` was replaced by `std.Io.Writer.print` in 0.16. The
custom-formatter type `std.fmt.Formatter` was renamed to
`std.fmt.Alt`. `std.fmt.bufPrintZ` (sentinel-terminated) became
`std.fmt.bufPrintSentinel`. `std.fmt.bufPrint` and
`std.fmt.allocPrint` keep their names.

## Path Operations

`std.fs.path` is now deprecated in favor of `std.Io.Dir.path`. The old
spelling is still accepted as an alias.

```zig
// Join paths
const path = try std.Io.Dir.path.join(allocator,
    &.{ "dir", "subdir", "file.txt" });
defer allocator.free(path);

// Basename / dirname / extension are pure functions
const base = std.Io.Dir.path.basename("/path/to/file.txt"); // "file.txt"
const dir = std.Io.Dir.path.dirname("/path/to/file.txt");   // "/path/to"
const ext = std.Io.Dir.path.extension("file.txt");          // ".txt"
```

### `relative` is now pure
`std.Io.Dir.path.relative` (and its Posix/Windows variants) no longer
queries the OS. Pass the CWD path and environ map explicitly:

```zig
const cwd_path = try std.process.currentPathAlloc(io, allocator);
defer allocator.free(cwd_path);

const rel = try std.Io.Dir.path.relative(
    allocator, cwd_path, environ_map, from, to,
);
defer allocator.free(rel);
```

The `environ_map` comes from `init.environ_map` in Juicy Main; on
non-Windows targets it can be `null` if you don't need drive-relative
path resolution.

### Trailing-Z / -W path variants are gone
Functions like `std.fs.realpathZ`, `std.fs.Dir.deleteFileZ`,
`std.fs.symLinkAbsoluteW`, etc. were removed. Convert your sentinel-
terminated paths to slices and use the regular APIs.

## Common Patterns for Coreutils

### Exit codes
```zig
std.process.exit(1); // unchanged
return @intFromEnum(common.ExitCode.general_error); // preferred from runUtil
```

### Print error and exit
```zig
fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    stderr.print(fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}
```

The buffered `.writerStreaming(io, &buffer)` shape is the same one flagged
under "Standard streams (buffered)" above — verify the call site if a
0.16 release of the project changes the spelling.

### Argument parsing
```zig
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(arena);

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            // ...
        } else if (std.mem.eql(u8, arg, "--")) {
            try positional.appendSlice(arena, args[i + 1 ..]);
            break;
        } else if (arg.len > 0 and arg[0] == '-') {
            // unknown option — fatal()
            return error.UnknownOption;
        } else {
            try positional.append(arena, arg);
        }
    }
}
```

For all but the simplest utilities, prefer the project's argparse
module (`src/common/argparse.zig`) over hand-rolled parsing.

### Environment variables
```zig
pub fn main(init: std.process.Init) !void {
    // Iterate the parsed map.
    for (init.environ_map.keys(), init.environ_map.values()) |k, v| {
        std.debug.print("{s}={s}\n", .{ k, v });
    }

    // Look up a single var (allocates).
    const home = try init.environ.getAlloc(
        init.arena.allocator(), "HOME",
    );
    _ = home;
}
```

`std.posix.getenv` was removed. The C-extern `setenv`/`unsetenv`
workaround that the 0.15 docs mentioned for tests is now obsolete —
environment is local to `init`, and tests should plumb a synthetic
`*Environ.Map` through the call chain instead.

### Spawning child processes
```zig
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
    .stdout = .pipe,
    .stderr = .pipe,
});
```

`std.process.Child.init` / `Child.spawn` were replaced by
`std.process.spawn(io, .{ ... })`. Likewise:

- `Child.run(allocator, io, opts)` → `process.run(allocator, io, opts)`
- `process.execv(arena, argv)` → `process.replace(io, .{ .argv = argv })`

### Current working directory
```zig
const cwd_path = try std.process.currentPathAlloc(io, allocator);
defer allocator.free(cwd_path);
```

`std.process.getCwd` / `getCwdAlloc` were renamed to
`std.process.currentPath` / `currentPathAlloc` and now require an
`Io` parameter.

### Signals
0.16 removed the medium-abstraction `std.posix` signal helpers along
with most of the `std.posix` namespace. The recommendation in the
release notes is "go higher (use `std.Io`) or go lower (use
`std.posix.system` directly)". Until `std.Io` grows a signal API,
direct syscalls via `std.posix.system` are the only stable option for
signal handling. Verify the exact entry points against the 0.16 lang
ref before adding signal handling to a utility — the surface here is
small and may shift again before 1.0.

### Timestamps
`File.Stat.atime` is now optional (`?i128`). Filesystems that refuse
to report access times (ZFS, certain network filesystems) return
`null`:

```zig
const at = stat.atime orelse return error.FileAccessTimeUnavailable;
```

`setTimestamps` now takes a struct so each field can independently use
`UTIME_OMIT` / `UTIME_NOW`:

```zig
try file.setTimestamps(io, .{
    .access_timestamp = .init(src_stat.atime),
    .modify_timestamp = .init(src_stat.mtime),
});
```

## Performance Tips

1. Use `std.mem.copyForwards` / `copyBackwards` instead of loops for
   bulk copying.
2. Prefer stack allocation with fixed buffers when size is known.
3. Use `std.ArrayList` for dynamic arrays (`.empty` to init,
   allocator passed per-method).
4. Use `std.StringHashMap` for string-keyed maps (or
   `std.array_hash_map.String` for ordered iteration).
5. Buffer I/O for file operations (`file.writer(io, &buf)` /
   `file.reader(io, &buf)`; use `writerStreaming` for stdout/stderr
   to respect O_APPEND).
6. Arena allocator for short-lived programs — and now lock-free, so
   safe across threads without wrapping.

## Common Gotchas

1. **Slices don't own memory** — be careful with lifetimes.
2. **Integer overflow is defined behavior** — use `%` operators for
   wrapping.
3. **No null-terminated strings by default** — use `[:0]const u8` when
   needed.
4. **Comptime parameters** — many std functions require comptime-known
   values.
5. **Error unions in struct fields** — not allowed; pin error sets to
   functions.
6. **Forgetting the `io` parameter** — every blocking API in 0.16
   takes one. Compile errors here usually point to a missing `io`.
7. **`std.fs.File.stdout()` no longer works** — it's `std.Io.File.stdout()`.
8. **`File.Stat.atime` is optional** — `orelse` it.
9. **`std.posix.getCwd` is gone** — use `std.process.currentPath`.
10. **`std.os.environ` is gone** — route `init.environ_map` through
    your call chain.
11. **`std.fs.path` deprecated** — prefer `std.Io.Dir.path`.
12. **`fixedBufferStream` removed** — use
    `var w: std.Io.Writer = .fixed(buf);` /
    `var r: std.Io.Reader = .fixed(data);`.

## Useful Standard Library

- `std.Io` — I/O interface, file and dir APIs, readers and writers
- `std.Io.File`, `std.Io.Dir` — file and directory operations
- `std.process` — process management, args, env, exit, spawn, replace
- `std.mem` — memory operations (find, cut, eql, copy*)
- `std.fmt` — formatting (bufPrint, allocPrint, Alt)
- `std.testing` — testing utilities, including `testing.io`
- `std.sort` — sorting algorithms
- `std.ArrayList` — dynamic arrays (allocator-per-method)
- `std.StringHashMap`, `std.array_hash_map.String` — hash maps

## Documentation Patterns

### Doc comment types

Zig has three types of comments with specific purposes:

1. **Normal comments** (`//`) — implementation details, not in docs.
2. **Doc comments** (`///`) — document the declaration below them.
3. **Top-level doc comments** (`//!`) — document the current
   module/file.

### Doc comment rules
- Doc comments must immediately precede the declaration they document.
- No blank lines between doc comment and declaration.
- Multiple doc comments merge into a multiline comment.
- Doc comments in unexpected places cause compile errors.

### Good documentation examples

```zig
//! vibeutils common library — shared functionality for all utilities

const std = @import("std");

/// Common error types used across vibeutils.
pub const Error = error{
    ArgumentError,
    FileNotFound,
    PermissionDenied,
};

/// Execute a copy operation with progress tracking.
/// Returns an error if the source cannot be read or the destination
/// cannot be written.
pub fn executeCopy(self: *CopyEngine, op: types.CopyOperation) !void {
    // Implementation details use normal comments.
}

/// Options controlling copy behavior.
pub const CopyOptions = struct {
    /// Preserve file attributes (permissions, timestamps).
    preserve: bool = false,
    /// Prompt before overwriting existing files.
    interactive: bool = false,
    /// Copy directories recursively.
    recursive: bool = false,
};

/// Errors specific to copy operations.
pub const CopyError = error{
    /// Source and destination refer to the same file.
    SameFile,
    /// Filesystem does not support the requested operation.
    UnsupportedFileType,
    /// Destination exists and would be overwritten.
    DestinationExists,
};
```

### What NOT to do

```zig
// BAD — don't use JavaDoc tags
/// @param allocator The allocator to use
/// @return A new instance
/// @throws OutOfMemory if allocation fails

// BAD — don't use markdown formatting
/// Creates a **new** instance with `default` values
/// See [documentation](https://example.com)

// BAD — don't state the obvious
/// Adds two numbers
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

// BAD — Zig doesn't support /* */ comments
/*
 * This style is not valid in Zig
 */
```

### Naming conventions

- **Functions**: camelCase (`copyFile`, `printError`)
- **Types**: PascalCase (`CopyEngine`, `FileType`)
- **Constants**: UPPER_SNAKE_CASE for truly constant values, otherwise
  camelCase
- **Variables**: snake_case (`file_path`, `dest_exists`)
- **Error sets**: PascalCase ending with `Error` (`CopyError`,
  `ParseError`)

```zig
// Function names should be verbs or verb phrases
pub fn executeCopy() !void {}
pub fn validatePath() !void {}
pub fn shouldOverwrite() !bool {}

// Types should be nouns
pub const CopyOperation = struct {};
pub const FileMetadata = struct {};

// Boolean variables should ask a question
const is_directory: bool = false;
const has_permissions: bool = true;
const should_recurse: bool = false;
```

### When to document

**Always document:**
- Public functions, types, and constants.
- Complex algorithms or non-obvious logic.
- Error conditions and edge cases.
- Module-level purpose with `//!`.

**Let code speak:**
- Simple getters/setters with obvious behavior.
- Internal implementation details.
- Temporary variables with clear names.
- Standard library usage patterns.

### Documentation best practices

1. **Be concise**: one or two lines is often sufficient.
2. **Focus on "why"**: explain purpose and behavior, not
   implementation.
3. **Document contracts**: preconditions, postconditions, invariants.
4. **Use present tense**: "Returns" not "Will return".
5. **Avoid pronouns**: "Parse the string" not "This parses the
   string".
6. **Document errors**: when functions return errors, explain when
   they occur.

### File headers

Start each file with a top-level doc comment:

```zig
//! Copy engine implementation for vibeutils cp command.
//! Handles file copying with progress tracking and error recovery.

const std = @import("std");
// ...
```

### Doctests

Use doctests to provide executable examples:

```zig
/// Parse a file mode string into numeric form.
pub fn parseMode(mode_str: []const u8) !u32 {
    // ...
}

test parseMode {
    try testing.expectEqual(@as(u32, 0o755), try parseMode("755"));
    try testing.expectEqual(@as(u32, 0o644), try parseMode("644"));
    try testing.expectError(error.InvalidMode, parseMode("999"));
}
```

## Summary

These patterns target Zig 0.16.x and reflect the I/O-as-Interface
redesign. When in doubt, look at existing implementations in `src/`
for examples — and consult `ZIG_BREAKING_CHANGES.md` whenever you hit
a compile error that mentions a renamed type or removed function.

Good Zig documentation is clear, concise, free from formatting markup,
focused on behavior (not implementation), and helpful without being
redundant.
