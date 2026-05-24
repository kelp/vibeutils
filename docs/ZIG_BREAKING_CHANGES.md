# Zig 0.16.0 Breaking Changes — Training Override Sheet

This document corrects outdated training data with current Zig
0.16.0 reality. **Released 2026-04-14, 0.16.0 is a Writergate-scale
churn release** — the headline is "I/O as an Interface", and it
ripples through `std.fs`, `std.process`, `std.Thread`, `std.crypto`,
`std.time`, and the language itself.

If you learned Zig from 0.13/0.14 (the "managed ArrayList"
generation), or from 0.15 (the "Writergate" generation),
**most of what you know about touching the outside world is now
wrong**. I/O, filesystem, processes, threads, randomness, time,
and even `main` itself have new shapes.

Reference material on disk (always grep these before writing):

- `docs/zig-0.16.0-release-notes.md` — official 0.16.0 release notes
- `docs/zig-0.16.0-docs.md` — official 0.16.0 language reference
- `docs/zig-0.15.2-docs.md` — 0.15 language reference (for diffing)

**vibeutils builds against Zig 0.16.0.** `build.zig.zon` pins
`minimum_zig_version = "0.16.0"` and `flake.nix` pins the same
toolchain. The 0.15 → 0.16 source migration is complete: utilities
use "Juicy Main" (`pub fn main(init: std.process.Init)`), I/O is
plumbed through every `runUtil` entry point, `std.Io.File` and
`std.Io.Dir` replace the old `std.fs` types, and tests use
`std.testing.io` alongside `std.testing.allocator`. Use this doc
as a reference for the breaking changes that were applied, and as
ground truth when writing new code or reviewing patches.

## Quick Reference Table

The 30 highest-traffic items. Old column covers ≤0.15.x. Find
the section below for the verified rationale.

| Old (≤0.15.x)                                  | New (0.16)                                                          |
|------------------------------------------------|---------------------------------------------------------------------|
| `pub fn main() !void`                          | `pub fn main(init: std.process.Init) !void` ("Juicy Main")          |
| `std.fs.File.stdout().writerStreaming(&buf)`   | `std.Io.File.stdout().writerStreaming(io, &buf)` (buffered, O_APPEND-safe) |
| `std.io` namespace                             | `std.Io` (capitalized; old name deprecated)                         |
| `std.fs.Dir`                                   | `std.Io.Dir`                                                        |
| `std.fs.File`                                  | `std.Io.File`                                                       |
| `std.fs.cwd()`                                 | `std.Io.Dir.cwd()`                                                  |
| `file.close()`                                 | `file.close(io)`                                                    |
| `file.write(bytes)`                            | `file.writeStreaming(io, ...)` / `writeStreamingAll(io, ...)`       |
| `file.read(buf)`                               | `file.readStreaming(io, ...)`                                       |
| `dir.makeDir(name)`                            | `dir.createDir(io, name)`                                           |
| `dir.makePath(p)`                              | `dir.createDirPath(io, p)`                                          |
| `file.chmod(mode)`                             | `file.setPermissions(io, ...)`                                      |
| `file.getEndPos()` / `setEndPos()`             | `file.length(io)` / `setLength(io, ...)`                            |
| `std.mem.indexOf(u8, haystack, needle)`        | `std.mem.find(u8, haystack, needle)`                                |
| `std.mem.indexOfScalar(u8, s, c)`              | `std.mem.findScalar(u8, s, c)`                                      |
| `std.mem.lastIndexOf(...)`                     | `std.mem.findLast(...)`                                             |
| `std.os.environ`                               | gone — use `init.environ_map` from `std.process.Init`               |
| `std.process.argsAlloc(allocator)`             | `init.minimal.args.toSlice(allocator)`                              |
| `std.process.getCwd(buf)` / `getCwdAlloc(a)`   | `std.process.currentPath(io, buf)` / `currentPathAlloc(io, a)`      |
| `std.process.Child.init(...).spawn()`          | `std.process.spawn(io, .{ .argv, .stdin, ... })`                    |
| `std.process.execv(arena, argv)`               | `std.process.replace(io, .{ .argv })`                               |
| `std.posix.PROT.READ \| std.posix.PROT.WRITE`  | `.{ .READ = true, .WRITE = true }`                                  |
| `std.posix.mlock(slice)`                       | `std.process.lockMemory(slice, .{})`                                |
| `std.Thread.Mutex` / `Condition` / `Semaphore` | `std.Io.Mutex` / `Io.Condition` / `Io.Semaphore`                    |
| `std.Thread.Pool` + `spawnWg`                  | `std.Io.async` / `std.Io.Group.async` (Pool removed)                |
| `std.crypto.random.bytes(&buf)`                | `io.random(&buf)`                                                   |
| `std.time.Instant` / `Timer` / `timestamp`     | `std.Io.Timestamp` (one type) / `std.Io.Timestamp.now`              |
| `@Type(.{ .int = .{ ... } })`                  | `@Int(.unsigned, 10)` (and 7 sibling builtins)                      |
| `@cImport({ @cInclude(...) })`                 | `b.addTranslateC(...)` in build.zig                                 |
| `error.RenameAcrossMountPoints` / `NotSameFileSystem` | `error.CrossDevice`                                          |

## The Headline: I/O as an Interface

**The single biggest change in 0.16.** Anything that potentially
**blocks control flow** or **introduces nondeterminism** now
takes an `Io` parameter — file I/O, networking, timers, random,
sleep, sync primitives, child processes, even fetching the cwd.

### Implementations of `Io`

The interface ships with several backends:

- `Io.Threaded` — based on threads. With this, file system
  operations directly call read, write, open, close, etc.
  When updating from 0.15.x, this gives equivalent behavior.
  **Feature-complete and well-tested**, including cancelation.
  Default chosen by "Juicy Main".
  - `-fno-single-threaded` — supports task-level concurrency.
  - `-fsingle-threaded` — does not.
- `Io.Evented` — work-in-progress, experimental. Userspace
  stack switching with work stealing (M:N green threads).
- `Io.Uring` — proof-of-concept on Linux io_uring.
- `Io.Kqueue` — proof-of-concept on macOS/BSD kqueue.
- `Io.Dispatch` — based on Grand Central Dispatch (macOS).
- `Io.failing` — simulates a system supporting no operations.

### "Juicy Main"

The first parameter of `pub fn main` may now be one of three
things:

1. **Missing** — `pub fn main() void` is still legal, but you
   can't access CLI arguments or environment variables.
2. **`process.Init.Minimal`** — only argv and environ in raw form.
3. **`process.Init`** — full set of pre-initialized goodies:
   `gpa`, `io`, `arena`, `environ_map`, `preopens`, plus the
   nested `minimal` containing `args` and `environ`.

**Old (≤0.15.x):**
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("Hello\n", .{});
}
```

**New (0.16):**
```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    _ = gpa;

    try std.Io.File.stdout().writeStreamingAll(io, "Hello\n");

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| std.log.info("arg: {s}", .{arg});
}
```

Migration: rewrite. `main`'s contract changed; you now receive
`gpa`, `io`, an `arena`, an `environ_map`, and `preopens` for
free.

### When You Don't Have an `Io`

If a function deep in a call stack needs an `Io` and there's
none in scope, the release notes give a workaround:

```zig
var threaded: Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

This is described as "non-ideal, like reaching for
`std.heap.page_allocator` when you need an `Allocator` and don't
have one." The recommended fix is to **plumb `Io` through as a
parameter**, ideally from `main`.

### Tests Get a Free `Io`

Like `std.testing.allocator`, there is now `std.testing.io`:

```zig
test "demo" {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, "hello.txt", .{});
    defer file.close(io);
}
```

## Stdout / stderr / stdin

The lang ref's "Hello World" uses the **unbuffered** path:

```zig
pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
```

That's the only stdout pattern the language reference
demonstrates. `std.debug.print` to stderr also works (no `Io`
needed) for diagnostic output.

### Buffered Writer (verified against installed 0.16.0)

Use `writerStreaming` for stdout/stderr — same lesson as 0.15,
because shell `>>` redirects rely on O_APPEND and the
positional `writer()` form ignores it (the source comment in
`std/Io/File/Writer.zig` confirms this is the only difference
between the two constructors). `writerStreaming` initializes
the writer in `.streaming` mode; `writer` initializes in
`.positional` mode.

```zig
pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer =
        std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer =
        std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    try stdout.print("hello: {s}\n", .{name});
}
```

Public types: `std.Io.File.Writer` (the buffer-holding struct
returned by `writer`/`writerStreaming`) and `std.Io.Writer`
(the interface, accessed via `.interface`).

Reader signature is **symmetric** with writer:
```zig
pub fn reader(file: File, io: Io, buffer: []u8) Reader
pub fn readerStreaming(file: File, io: Io, buffer: []u8) Reader
pub fn writer(file: File, io: Io, buffer: []u8) Writer
pub fn writerStreaming(file: File, io: Io, buffer: []u8) Writer
```

(Earlier release-notes examples that show `file.reader(&.{})`
without `io` predate the final API. Both reader and writer
take `(file, io, buffer)`.)

### Removed I/O Types

Removed entirely from `std.io` / `std.Io`:

- `std.io.GenericReader`, `AnyReader` — collapsed into `std.Io.Reader`
- `std.Io.GenericWriter`, `AnyWriter`, `null_writer`, `CountingReader`
- `FixedBufferStream` — replaced by `Reader.fixed` / `Writer.fixed`

**Old:**
```zig
var fbs = std.io.fixedBufferStream(data);
const reader = fbs.reader();
```

**New:**
```zig
var reader: std.Io.Reader = .fixed(data);
```

Same shape on the writing side:

```zig
var writer: std.Io.Writer = .fixed(buffer);
```

LEB128 helpers moved:

- `std.leb.readUleb128` → `std.Io.Reader.takeLeb128`
- `std.leb.readIleb128` → `std.Io.Reader.takeLeb128`

## Filesystem Migration: `std.fs` → `std.Io`

All `fs` APIs have moved to `Io`. The release notes describe
this as "a lot of breaking changes, but unlike Writergate, this
changeset does not require much critical thinking." Typical
upgrade looks like:

**Old:**
```zig
file.close();
```

**New:**
```zig
file.close(io);
```

### Namespace Moves

| Old                              | New                              |
|----------------------------------|----------------------------------|
| `std.fs.Dir`                     | `std.Io.Dir`                     |
| `std.fs.File`                    | `std.Io.File`                    |
| `std.fs.cwd`                     | `std.Io.Dir.cwd`                 |
| `std.fs.path`                    | `std.Io.Dir.path` (deprecated alias) |
| `std.fs.max_path_bytes`          | `std.Io.Dir.max_path_bytes`      |
| `std.fs.max_name_bytes`          | `std.Io.Dir.max_name_bytes`      |
| `std.fs.has_executable_bit`      | `std.Io.File.Permissions.has_executable_bit` |

### Absolute-path Helpers

| Old                              | New                                 |
|----------------------------------|-------------------------------------|
| `fs.copyFileAbsolute`            | `std.Io.Dir.copyFileAbsolute`       |
| `fs.makeDirAbsolute`             | `std.Io.Dir.createDirAbsolute`      |
| `fs.deleteDirAbsolute`           | `std.Io.Dir.deleteDirAbsolute`      |
| `fs.openDirAbsolute`             | `std.Io.Dir.openDirAbsolute`        |
| `fs.openFileAbsolute`            | `std.Io.Dir.openFileAbsolute`      |
| `fs.accessAbsolute`              | `std.Io.Dir.accessAbsolute`         |
| `fs.createFileAbsolute`          | `std.Io.Dir.createFileAbsolute`     |
| `fs.deleteFileAbsolute`          | `std.Io.Dir.deleteFileAbsolute`     |
| `fs.renameAbsolute`              | `std.Io.Dir.renameAbsolute`         |
| `fs.readLinkAbsolute`            | `std.Io.Dir.readLinkAbsolute`       |
| `fs.symLinkAbsolute`             | `std.Io.Dir.symLinkAbsolute`        |
| `fs.realpath`                    | `std.Io.Dir.realPathFileAbsolute`   |
| `fs.realpathAlloc`               | `std.Io.Dir.realPathFileAbsoluteAlloc` |

### Self-Executable Helpers

| Old                            | New                                |
|--------------------------------|------------------------------------|
| `fs.openSelfExe`               | `std.process.openExecutable`       |
| `fs.selfExePath`               | `std.process.executablePath`       |
| `fs.selfExePathAlloc`          | `std.process.executablePathAlloc`  |
| `fs.selfExeDirPath`            | `std.process.executableDirPath`    |
| `fs.selfExeDirPathAlloc`       | `std.process.executableDirPathAlloc` |
| `fs.Dir.setAsCwd`              | `std.process.setCurrentDir`        |

### Dir Method Renames

| Old                              | New                                  |
|----------------------------------|--------------------------------------|
| `Dir.makeDir`                    | `Dir.createDir`                      |
| `Dir.makePath`                   | `Dir.createDirPath`                  |
| `Dir.makeOpenDir`                | `Dir.createDirPathOpen`              |
| `Dir.atomicSymLink`              | `Dir.symLinkAtomic`                  |
| `Dir.chmod`                      | `Dir.setPermissions`                 |
| `Dir.chown`                      | `Dir.setOwner`                       |
| `Dir.realpath`                   | `Dir.realPathFile`                   |
| `Dir.realpathAlloc`              | `Dir.realPathFileAlloc`              |

`Dir.rename` now requires two `Dir` parameters plus `Io`.

### File Method Renames

| Old                              | New                                  |
|----------------------------------|--------------------------------------|
| `File.Mode`                      | `File.Permissions`                   |
| `File.PermissionsWindows`        | `File.Permissions`                   |
| `File.PermissionsUnix`           | `File.Permissions`                   |
| `File.default_mode`              | `File.Permissions.default_file`      |
| `File.getOrEnableAnsiEscapeSupport` | `File.enableAnsiEscapeCodes`     |
| `File.setEndPos`                 | `File.setLength`                     |
| `File.getEndPos`                 | `File.length`                        |
| `File.seekTo`/`seekBy`/`seekFromEnd` | on `File.Reader`/`File.Writer`   |
| `File.getPos`                    | `File.Reader.logicalPos`, `Io.Writer.logicalPos` |
| `File.mode`                      | `File.stat().permissions.toMode`     |
| `File.chmod`                     | `File.setPermissions`                |
| `File.chown`                     | `File.setOwner`                      |
| `File.updateTimes`               | `File.setTimestamps` / `setTimestampsNow` |
| `File.read` / `readv`            | `File.readStreaming`                 |
| `File.pread` / `preadv`          | `File.readPositional`                |
| `File.preadAll`                  | `File.readPositionalAll`             |
| `File.write` / `writev`          | `File.writeStreaming`                |
| `File.writeAll`                  | `File.writeStreamingAll`             |
| `File.pwrite` / `pwritev`        | `File.writePositional`               |
| `File.pwriteAll`                 | `File.writePositionalAll`            |
| `File.copyRange` / `copyRangeAll`| `File.writer`                        |

### Removed With No Replacement

- All trailing-Z/W variants: `realpathZ`, `realpathW`, `renameZ`,
  `symLinkZ`, `readLinkZ`, `deleteFileZ`, `deleteDirZ`,
  `makeDirAbsoluteZ`, `deleteDirAbsoluteZ`, `openDirAbsoluteZ`,
  `renameAbsoluteZ`, `symLinkAbsoluteW`, `readLinkW`, `symLinkW`,
  `symLinkWasi`, `readLinkWasi`, `realpathW2`
- `fs.deleteTreeAbsolute`
- `fs.File.isCygwinPty`
- `fs.Dir.adaptToNewApi` / `adaptFromNewApi`
- `fs.File.adaptToNewApi` / `adaptFromNewApi`
- `fs.getAppDataDir` (use third-party
  [known-folders](https://github.com/ziglibs/known-folders))

### Signature Reshapes — Not Mechanical

Some methods didn't just gain `io`, the whole signature changed:

**`readFileAlloc`:**
```zig
// Old
const contents = try std.fs.cwd().readFileAlloc(allocator, name, 1234);

// New
const contents = try std.Io.Dir.cwd().readFileAlloc(io, name, allocator, .limited(1234));
```

Note: the limit semantics changed — if it's *reached* it returns
the error too. Error renamed `FileTooBig` → `StreamTooLong`.

**`readToEndAlloc`:**
```zig
// Old
const contents = try file.readToEndAlloc(allocator, 1234);

// New
var read_buffer: [4096]u8 = undefined;
var file_reader = file.reader(io, &read_buffer);
const contents = try file_reader.interface.allocRemaining(allocator, .limited(1234));
```

Migration: rewrite call site; `.limited(N)` is the new limit
constructor.

### Atomic File API Rewrite

```zig
// Old
var buffer: [1024]u8 = undefined;
var atomic_file = try dest_dir.atomicFile(io, dest_path, .{
    .permissions = actual_permissions,
    .write_buffer = &buffer,
});
defer atomic_file.deinit();
// ... use atomic_file.file_writer
try atomic_file.flush();
try atomic_file.renameIntoPlace();

// New
var atomic_file = try dest_dir.createFileAtomic(io, dest_path, .{
    .permissions = actual_permissions,
    .make_path = true,
    .replace = true,
});
defer atomic_file.deinit(io);

var buffer: [1024]u8 = undefined;
var file_writer = atomic_file.file.writer(io, &buffer);
// ... use file_writer
try file_writer.flush();
try atomic_file.replace(io); // or set .replace = false and link()
```

Migration: rewrite. Buffer ownership moved from the atomic-file
struct to the writer.

### `setTimestamps` Shape Change

`File.Stat.atime` is now optional (some filesystems refuse to
report access time). The setter takes a struct:

```zig
// Old
try file.setTimestamps(io, src_stat.atime, src_stat.mtime);

// New
try file.setTimestamps(io, .{
    .access_timestamp = .init(src_stat.atime),
    .modify_timestamp = .init(src_stat.mtime),
});

// Reading atime is now nullable:
const atime = stat.atime orelse return error.FileAccessTimeUnavailable;
```

Migration: rewrite; `.init(...)` constructs the per-field
timestamp option; `null` reads must be handled.

### `walkSelectively`

`Dir.walk` recurses unconditionally; new `walkSelectively`
opts in per directory entry, skipping the open/close syscalls
for directories you don't want:

```zig
var walker = try dir.walkSelectively(gpa);
defer walker.deinit();

while (try walker.next(io)) |entry| {
    if (failsFilter(entry)) continue;
    if (entry.kind == .directory) try walker.enter(io, entry);
    // ...
}
```

`Walker.Entry.depth()` and `Walker.leave()` / `SelectiveWalker.leave()`
are also new.

### `fs.path.relative` Became Pure

```zig
// Old
const rel = try std.fs.path.relative(gpa, from, to);

// New
const cwd_path = try std.process.currentPathAlloc(io, gpa);
defer gpa.free(cwd_path);
const rel = try std.fs.path.relative(gpa, cwd_path, environ_map, from, to);
```

The CWD and environment map are now explicit parameters; the
function no longer queries the OS internally.

## `std.mem.indexOf*` → `find*`

The release notes describe the rule: in `std.mem`, "find"
returns the index of a substring; "pos" is a starting-index
parameter; "last" searches from the end; "linear" is a simple
loop; "scalar" means the substring is one element.

The release notes do **not** print a literal one-to-one rename
table. The full rename map below is derived from that rule and
is widely repeated in migration notes. Verify against
`lib/std/mem.zig` in your installed Zig if a specific name
fails to compile.

| Old                          | New (per the rule)        |
|------------------------------|---------------------------|
| `indexOf`                    | `find`                    |
| `indexOfScalar`              | `findScalar`              |
| `indexOfPos`                 | `findPos`                 |
| `indexOfAny`                 | `findAny`                 |
| `lastIndexOf`                | `findLast`                |
| `lastIndexOfScalar`          | `findScalarLast`          |
| `lastIndexOfAny`             | `findLastAny`             |

(Note: 0.16 puts the `Last` qualifier *after* `Scalar`, not
before — `findScalarLast`, not `findLastScalar`. There is no
`findLastPos`; for last-position-bounded scans use
`findScalarPos` from a computed start, or `findLast` and check
the bound. New: `findNone` / `findLastNone` / `findNonePos`
return the first/last index whose value is *not* in a set.)

### New `cut*` Family

Added in 0.16: `cut`, `cutPrefix`, `cutSuffix`, `cutScalar`,
`cutLast`, `cutScalarLast`. These split a string at the first
(or last) occurrence of a delimiter, returning the prefix/
suffix pair — the equivalent of Go's `strings.Cut`.

## Process State (Args & Env) Is No Longer Global

`std.os.environ` was a footgun: it was declared global, but it
could not be populated from a library that doesn't link libc.
Setting environment variables from a thread is also unsound in
C. **As of 0.16, environment variables are available only
through `main`'s parameter.**

### Reading Args

**Old:**
```zig
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);
for (args[1..]) |arg| {}
```

**New (Init.Minimal, iterator):**
```zig
pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    while (args.next()) |arg| {
        std.log.info("arg: {s}", .{arg});
    }
}
```

**New (full Init, slice):**
```zig
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| std.log.info("arg: {s}", .{arg});
}
```

Migration: rewrite. Args plumbed through `main`'s parameter; no
more allocator-owned slice.

### Reading Environment

**Old:**
```zig
const home = std.os.getenv("HOME"); // global
```

**New (full Init):**
```zig
pub fn main(init: std.process.Init) !void {
    for (init.environ_map.keys(), init.environ_map.values()) |k, v| {
        std.log.info("env: {s}={s}", .{ k, v });
    }
}
```

**New (Init.Minimal, lazy):**
```zig
pub fn main(init: std.process.Init.Minimal) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const home = init.environ.getPosix("HOME"); // ?[]const u8
    const editor = try init.environ.getAlloc(arena, "EDITOR");
    _ = home; _ = editor;
}
```

Migration: functions that need env vars accept either the
specific values or a `*const process.Environ.Map` parameter —
same plumbing pattern as `Allocator` and `Io`.

## `std.process` / `std.posix` Rewrites

### Current Working Directory Renamed

In Zig stdlib, `Dir` means an open dir handle, `path` is a
filesystem identifier string. "get" and "working" are
superfluous.

```zig
// Old
const cwd = try std.process.getCwd(buffer);
const cwd_alloc = try std.process.getCwdAlloc(allocator);

// New
const cwd = try std.process.currentPath(io, buffer);
const cwd_alloc = try std.process.currentPathAlloc(io, allocator);
```

### Spawning a Child Process

```zig
// Old
var child = std.process.Child.init(argv, gpa);
child.stdin_behavior = .Pipe;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
try child.spawn(io);

// New
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
    .stdout = .pipe,
    .stderr = .pipe,
});
```

`std.process.Child.run` → `std.process.run(allocator, io, .{...})`.

### Replacing the Current Process Image

```zig
// Old
const err = std.process.execv(arena, argv);

// New
const err = std.process.replace(io, .{ .argv = argv });
```

### Memory Locking and Protection

mmap/mprotect flags are now type-safe:

```zig
// Old
std.posix.PROT.READ | std.posix.PROT.WRITE

// New
.{ .READ = true, .WRITE = true }
```

mlock family moved to `process`:

```zig
// Old
try std.posix.mlock();
try std.posix.mlock2(slice, std.posix.MLOCK_ONFAULT);
try std.posix.mlockall(slice, std.posix.MCL_CURRENT | std.posix.MCL_FUTURE);

// New
try std.process.lockMemory(slice, .{});
try std.process.lockMemory(slice, .{ .on_fault = true });
try std.process.lockMemoryAll(.{ .current = true, .future = true });
```

### `std.posix` and `std.os.windows` Removals

The release notes are explicit: "Most `std.posix` and
`std.os.windows` functions existed at an awkward **medium-level
abstraction** and have thus been removed. If you were using any
functions removed from those namespaces, you must now choose a
direction: **go higher (use `std.Io`) or go lower (use
`std.posix.system` directly).**"

`ucontext_t` and friends are also removed — the first use case
(non-local control flow with `ucontext.h`) was never supported
upstream and is deprecated in POSIX; the second (signal-handler
machine state) was poorly served by the stdlib types.

## Containers

### Managed Hash Maps Removed

```zig
// Old
var map: std.AutoArrayHashMap(K, V) = .init(allocator);
defer map.deinit();

// New
var map: std.array_hash_map.Auto(K, V) = .empty;
defer map.deinit(allocator);
```

| Old                              | New                          |
|----------------------------------|------------------------------|
| `ArrayHashMap` (managed)         | gone — use `array_hash_map.Custom` |
| `AutoArrayHashMap` (managed)     | gone — use `array_hash_map.Auto`   |
| `StringArrayHashMap` (managed)   | gone — use `array_hash_map.String` |
| `AutoArrayHashMapUnmanaged`      | `array_hash_map.Auto`        |
| `StringArrayHashMapUnmanaged`    | `array_hash_map.String`      |
| `ArrayHashMapUnmanaged`          | `array_hash_map.Custom`      |

Migration: drop the "Managed" variants entirely; the
unmanaged variants got the short names. Pass `allocator` to
each method.

### `SegmentedList` Removed

No replacement. If you were using it, fall back to
`ArrayListUnmanaged` or copy the old implementation out of
0.15.x stdlib.

### `PriorityQueue` / `PriorityDequeue` Reworked

Both lose their `Allocator` field. Initialize with the `.empty`
decl literal instead of `.init()`. Method renames:

| Old                  | New           |
|----------------------|---------------|
| `init` (PriorityQueue) | `initContext` (or `.empty` for default) |
| `init` (PriorityDequeue) | `.empty`  |
| `add` / `addUnchecked` / `addSlice` | `push` / `pushUnchecked` / `pushSlice` |
| `remove` / `removeOrNull`           | `pop`         |
| `removeMin` / `removeMinOrNull`     | `popMin`      |
| `removeMax` / `removeMaxOrNull`     | `popMax`      |
| `removeIndex`                       | `popIndex`    |

```zig
// Old
var queue = std.PriorityQueue(u32, void, lessThan).init(allocator, {});
defer queue.deinit();
try queue.add(42);

// New
var queue: std.PriorityQueue(u32, void, lessThan) = .empty;
defer queue.deinit(allocator);
try queue.push(allocator, 42);
```

### BitSet / EnumSet Decl Literals

`initEmpty` / `initFull` replaced by decl literals (e.g.
`.empty`, `.full`). Verify the exact decl name in your installed
stdlib — release notes only state the change conceptually.

## Sync Primitives: `Thread.*` → `Io.*`

Sync APIs migrated to `std.Io` so the synchronized code can
integrate with the application's chosen I/O implementation —
e.g. on `Io.Threaded` a contended mutex blocks the thread, on
`Io.Evented` it switches stacks. These also integrate with
cancelation.

| Old                       | New                |
|---------------------------|--------------------|
| `std.Thread.ResetEvent`   | `std.Io.Event`     |
| `std.Thread.WaitGroup`    | `std.Io.Group`     |
| `std.Thread.Futex`        | `std.Io.Futex`     |
| `std.Thread.Mutex`        | `std.Io.Mutex`     |
| `std.Thread.Condition`    | `std.Io.Condition` |
| `std.Thread.Semaphore`    | `std.Io.Semaphore` |
| `std.Thread.RwLock`       | `std.Io.RwLock`    |
| `std.once`                | removed; avoid global init or hand-roll |
| `std.Thread.Mutex.Recursive` | removed         |

### `std.Thread.Pool` Removed

```zig
// Old
fn doAllTheWork(pool: *std.Thread.Pool) void {
    var wg: std.Thread.WaitGroup = .{};
    pool.spawnWg(wg, doSomeWork, .{ pool, &wg, item });
    wg.wait();
}

// New
fn doAllTheWork(io: std.Io) !void {
    var g: std.Io.Group = .init;
    errdefer g.cancel(io);
    g.async(io, doSomeWork, .{ io, &g, item });
    try g.await(io);
}
```

When migrating, **all sync primitives in adjacent code must
also move from `Thread.*` to `Io.*`** — mixing the two on the
same data structure is incorrect.

For task patterns that aren't expressible as `async`, consult
`std.Io.async` and `std.Io.concurrent` documentation.

Notably, lock-free sync primitives (atomics, etc.) do **not**
require `Io` integration.

## Allocators

### `ArenaAllocator` Is Now Lock-Free Thread-Safe

No API change. Drop any `ThreadSafeAllocator` wrapping you had
around it. Performance is comparable to single-threaded use,
slightly faster than the previous Arena-wrapped-in-mutex up to
roughly 7 concurrent threads.

### `heap.ThreadSafeAllocator` Removed

The release notes call it "an anti-pattern": the only reasonable
implementation is mutex-based, which now requires an `Io`
instance and is generally slow. Make the underlying allocator
lock-free instead.

### New Unmanaged Memory Pool Variants

Added `heap.MemoryPoolUnmanaged`, `heap.MemoryPoolAlignedUnmanaged`,
`heap.MemoryPoolExtraUnmanaged`. The release notes don't show
worked examples — verify usage against the stdlib source.

### `Io.Writer.Allocating` Has an Alignment Field

```zig
alignment: std.mem.Alignment,
```

Runtime-known alignment value, supported via the Allocator
"raw" function variants.

## Random / Time / Format

### Entropy

```zig
// Old (cheap)
var buf: [123]u8 = undefined;
std.crypto.random.bytes(&buf);

// New
var buf: [123]u8 = undefined;
io.random(&buf);
```

```zig
// Old (Random interface)
const rng = std.crypto.random;

// New
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();
```

```zig
// Old
posix.getrandom(&buffer);

// New
io.random(&buffer);
```

For cryptographically-secure entropy that bypasses any in-process
RNG state, use `io.randomSecure(&buf)` (returns
`error.EntropyUnavailable` if unavailable; no fallback).

`std.Options.crypto_always_getrandom` and
`std.Options.crypto_fork_safety` are gone — use `Io.random` vs
`Io.randomSecure` to choose explicitly.

### Time

| Old                       | New                                |
|---------------------------|------------------------------------|
| `std.time.Instant`        | `std.Io.Timestamp`                 |
| `std.time.Timer`          | `std.Io.Timestamp`                 |
| `std.time.timestamp()`    | `std.Io.Timestamp.now`             |

The `Io` interface now exposes `Clock`, `Duration`, `Timestamp`,
`Timeout` types — type-safe units of measurement. Reading a
clock can now fail with `error.ClockUnsupported`, but that error
disappears from timeout/clock-reading sets if you call
`Clock.resolution` first.

### Format

| Old                       | New                                |
|---------------------------|------------------------------------|
| `std.fmt.Formatter`       | `std.fmt.Alt`                      |
| `std.fmt.format`          | `std.Io.Writer.print`              |
| `std.fmt.FormatOptions`   | `std.fmt.Options`                  |
| `std.fmt.bufPrintZ`       | `std.fmt.bufPrintSentinel`         |

The 0.15-era custom `format` method signature
(`pub fn format(self: T, writer: *std.Io.Writer) !void`) is
unchanged — the wrapping format machinery moved.

## Error Renames

| Old                                  | New                              |
|--------------------------------------|----------------------------------|
| `error.RenameAcrossMountPoints`      | `error.CrossDevice`              |
| `error.NotSameFileSystem`            | `error.CrossDevice`              |
| `error.SharingViolation`             | `error.FileBusy`                 |
| `error.EnvironmentVariableNotFound`  | `error.EnvironmentVariableMissing` |
| `error.FileTooBig` (`readFileAlloc`) | `error.StreamTooLong`            |
| `Dir.rename` returns `PathAlreadyExists` for non-empty dest | now returns `DirNotEmpty` |

## Language-Level Changes

### `@Type` Split Into Eight Builtins

`@Type` is gone. Replacements:

```zig
@EnumLiteral() type
@Int(comptime signedness: std.builtin.Signedness, comptime bits: u16) type
@Tuple(comptime field_types: []const type) type
@Pointer(size, attrs, Element, sentinel) type
@Fn(param_types, param_attrs, ReturnType, attrs) type
@Struct(layout, BackingInt, field_names, field_types, field_attrs) type
@Union(layout, ArgType, field_names, field_types, field_attrs) type
@Enum(TagInt, mode, field_names, field_values) type
```

Sample migrations:

```zig
// Old
@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })
// New
@Int(.unsigned, 10)
```

```zig
// Old
@Type(.enum_literal)
// New
@EnumLiteral()
```

```zig
// Old
@Type(.{ .@"struct" = .{ .layout = .auto, .fields = ..., .is_tuple = true, ... } })
// New
@Tuple(&.{ u32, [2]f64 })
```

`std.meta.Int` and `std.meta.Tuple` are deprecated in favor of
`@Int` and `@Tuple`.

There is **no** `@Float`, `@Array`, `@Opaque`, `@Optional`, or
`@ErrorUnion` builtin — write the literal type instead (`f32`,
`[N]T`, `opaque {}`, `?T`, `E!T`). There is no `@ErrorSet`
either; reifying error sets is no longer possible — declare
them with `error{ ... }` syntax.

**Tuple types with `comptime` fields can no longer be reified.**

### `@cImport` Deprecated

`@cImport` still exists, but is deprecated in favor of
`b.addTranslateC(...)` in `build.zig`:

```zig
// build.zig
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
translate_c.linkSystemLibrary("glfw", .{});

const exe = b.addExecutable(.{
    .name = "tetris",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{ .{
            .name = "c",
            .module = translate_c.createModule(),
        } },
    }),
});
```

`src/c.h` then is just a normal C header. In the Zig source,
`const c = @import("c");` replaces the old
`const c = @import("c.zig").c;`.

### Runtime Vector Indexing Forbidden

```zig
// Old
for (0..vector_len) |i| { _ = vector[i]; }

// New: coerce to array first
const vector_type = @typeInfo(@TypeOf(vector)).vector;
const array: [vector_type.len]vector_type.child = vector;
for (&array) |elem| { _ = elem; }
```

Migration: rewrite. Indexing a vector now requires comptime-known
indices.

### Vectors and Arrays No Longer Support In-Memory Coercion

If you used `@ptrCast` to convert between an array's memory and
a vector's memory, use coercion (assignment) instead. If you
were coercing `anyerror![4]i32` to `anyerror!@Vector(4, i32)`,
unwrap the error first.

### Trivial Local-Address Returns Forbidden

```zig
fn foo() *i32 {
    var x: i32 = 1234;
    return &x; // error: returning address of expired local variable 'x'
}
```

Migration: spell it as `return undefined;` if you genuinely want
to return an invalid pointer (the language no longer accepts the
syntactic shortcut).

### Small Int → Float Auto-Coercion

If all values of an int type fit in a float without rounding
(comparing precision bits to significand bits), the int coerces
implicitly:

```zig
var foo_int: u24 = 123;
var foo_float: f32 = foo_int; // OK in 0.16
```

`u25` still requires `@floatFromInt`.

### `@floor`/`@ceil`/`@round`/`@trunc` Convert to Integers

```zig
fn round_to_int(value: f32) u8 {
    return @round(value); // returns u8 directly
}
```

`@intFromFloat` is now redundant with `@trunc` and is
deprecated.

### Unary Float Builtins Forward Result Type

```zig
const x: f64 = @sqrt(@floatFromInt(N)); // now valid; previously not
```

Applies to `@sqrt`, `@sin`, `@cos`, `@tan`, `@exp`, `@exp2`,
`@log`, `@log2`, `@log10`, `@floor`, `@ceil`, `@trunc`, `@round`.

### Packed-Type Restrictions

- **No pointers in packed structs or unions.** Use `usize` plus
  `@ptrFromInt` / `@intFromPtr` if you need to pack a pointer.
- **All packed-union fields must have equal `@bitSizeOf`** — no
  unused bits permitted.
- **Explicit backing integer on packed unions** is now allowed:
  `packed union(u16) { ... }`.
- **`extern` types must specify backing/tag types explicitly.**
  `enum { a, b, c }` and `packed struct { a: u4, b: u4 }` no
  longer count as valid extern types — write `enum(u8) { ... }`
  and `packed struct(u8) { ... }`.

### Aligned vs Naturally-Aligned Pointers Are Distinct Types

`*u8` and `*align(1) u8` are no longer the literally same type.
They still coerce to each other (in-memory coercion is allowed),
so most code is unaffected — think `u32` vs `c_uint`.

### Pointers to Comptime-Only Types Can Exist at Runtime

`*comptime_int` is now a runtime type even though
`comptime_int` is comptime-only. You can pass a
`[]const std.builtin.Type.StructField` to a runtime function
and read each field's `name` (a runtime type) without
constructing a separate `[]const []const u8`. Dereferencing
still requires comptime.

### Lazy Field Analysis

Using a type as a namespace no longer triggers analysis of its
fields. `struct`, `union`, `enum`, and `opaque` types resolve
only when their size or one of their field types is needed.

### Zero-Bit Tuple Fields No Longer Implicitly `comptime`

Reverts a 0.14-era rule. `struct { void }` is no longer
considered a comptime field by `@typeInfo`. The field value is
still always comptime-known. The only breaking case is code
that reads `is_comptime` from `@typeInfo` or relies on type
equivalence between tuples with and without explicit `comptime`.

## Build System

### Override Packages Locally with `--fork`

```sh
zig build --fork=/home/andy/dev/dvui
```

The fork path must contain a `build.zig.zon` with matching
`name` and `fingerprint`. Useful when iterating on a local
checkout of a dependency without modifying the lockfile.

### Packages Fetched into `zig-pkg/`

Dependencies now land in `zig-pkg/` next to `build.zig` instead
of the global `$GLOBAL_ZIG_CACHE/p/$HASH` path. After fetching,
the package is recompressed into
`$GLOBAL_ZIG_CACHE/p/$HASH.tar.gz` for cross-machine sharing.
You can edit the local copies; you can swap one for a git clone.
Don't commit `zig-pkg/` (in general).

### `build.zig.zon` Required Fields

`zig build` now **fails** when:

- A dependency has no `fingerprint` field, or
- A dependency's `name` is a string rather than an enum literal.

Same `fingerprint` + same `version` + different hash anywhere
in the dependency tree is also an error — somebody forgot to
bump a version.

Legacy hash format support is removed.

### `--test-timeout`

```sh
zig build test --test-timeout 500ms
```

Per-`test`-block timeout. Real time, not CPU time, so heavily
loaded systems can produce false positives. Useful for
detecting hangs and runaway tests.

### `--error-style`

Replaces the removed `--prominent-compile-errors` flag. Values:
`verbose` (default), `minimal`, `verbose_clear`, `minimal_clear`.
The `_clear` variants clear the terminal on `--watch` rebuild.

`--prominent-compile-errors` ⇒ `--error-style minimal`.

Honors `ZIG_BUILD_ERROR_STYLE` env var.

### `--multiline-errors`

Values: `indent` (default), `newline`, `none`. Controls
formatting of multi-line error messages. Honors
`ZIG_BUILD_MULTILINE_ERRORS` env var.

### Temporary Files Reorganization

- `RemoveDir` step **removed** — had no valid purpose.
- `Build.makeTempPath` **removed** — wrong phase to allocate.
- `WriteFile` step gained "tmp mode" and "mutate mode".
- `Build.addTempFiles` — initialize a `WriteFile` in tmp mode.
- `Build.addMutateFiles` — initialize a `WriteFile` for in-place
  mutation of an existing temp dir.
- `Build.tmpPath` — shortcut for `addTempFiles` + `getDirectory`.

If you were doing `b.makeTempPath()` followed by
`addRemoveDirTree`, replace with `b.addTempFiles` and use the
`std.Build.Step.WriteFile` API. The build runner will clean up
tmp files automatically.

### `std.builtin.subsystem` Removed

Subsystem detection was flaky and not actually needed. The real
subsystem isn't known until link time. If you really need it at
runtime, see ziglang issue #25127 for techniques.

`std.Target.SubSystem` → `std.zig.Subsystem` (deprecated alias
remains so `exe.subsystem = .Windows` keeps working in build
scripts).

### `ZIG_BTRFS_WORKAROUND` Env Var Ignored

The upstream Linux btrfs bug it worked around has been fixed.
The variable is no longer observed.

## Subtle Gotchas

### `File.Stat.atime` Is Now Optional

Some filesystems (including ZFS) refuse to report access time.
`stat.atime` is `?Timestamp`. Always handle null:

```zig
const atime = stat.atime orelse return error.FileAccessTimeUnavailable;
```

### `Io.Dir.rename` Returns `DirNotEmpty`

Renaming over a non-empty destination directory used to fail with
`error.PathAlreadyExists`; now it's `error.DirNotEmpty`. Update
your error switches.

### `tar.extract` Sanitizes Path Traversal

Previous versions could extract `../etc/passwd`-style entries.
0.16 sanitizes by default. If you depended on the old behavior
for trusted archives, you'll need to do extraction manually.

### `math.sign`

Now returns the smallest integer type that fits possible values
(rather than the input type). Cast explicitly if you need a
specific width.

### `meta.declList` Removed

No replacement. Iterate with `@typeInfo(T).@"struct".decls`
manually.

### `DynLib` Lost Windows Support

Use `LoadLibraryExW` and `GetProcAddress` directly via `extern`
declarations. The release notes claim this is "probably what
you were doing already anyway."

### `std.Io.Dir.renamePreserve`

New API: rename without replacing the destination. Useful when
you want hardlink-style "fail if dest exists" semantics.

### `Io.net.Socket.createPair`

New API for creating a connected socketpair (replaces ad-hoc
`socketpair(2)` extern declarations).

## Migration Status in vibeutils

The 0.16 migration **is complete**. `build.zig.zon` and
`flake.nix` both pin **Zig 0.16.0**. Current state:

- **"Juicy Main" everywhere** — every utility's entry point is
  `pub fn main(init: std.process.Init)`, returning either `!void`
  or `noreturn` via `common.utilityMain`.
- **`Io` plumbed through `runUtil`** — every utility's runtime
  function takes `(allocator, io, args, stdout_writer, stderr_writer)`,
  same shape as the existing `Allocator` plumbing.
- **`std.Io.File` / `std.Io.Dir`** replace `std.fs.File` /
  `std.fs.Dir` across `src/`. A handful of stragglers
  (`std.fs.cwd().access`, `std.fs.path.join`, `std.fs.Dir`
  return types in `src/common/test_utils_privilege.zig` and
  `src/common/file_ops.zig`) remain, mostly in test utilities
  where the deprecated alias still compiles cleanly.
- **`writerStreaming` mandated for stdout/stderr** — enforced by
  the regression test in `src/common/lib.zig` (issue #5). The
  positional `writer()` form ignores `O_APPEND` on macOS and
  breaks shell `>>` redirects.
- **`std.testing.io`** is used alongside `std.testing.allocator`
  in every utility's embedded tests.
- **`environ_map`** is plumbed from `init.environ_map` — see
  `src/env.zig` for the canonical pattern. No surviving
  `std.os.environ` or `std.posix.setenv` workarounds.
- **`std.mem.find*`** is the canonical form (~617 call sites).
  ~73 call sites still use the deprecated `indexOf*` aliases
  (`indexOf`, `indexOfScalar`, `indexOfPos`) — these still
  compile because `mem.zig` retains them as `pub const indexOf =
  find;` etc., but new code should prefer `find*`.

**For new code today:**
- Follow the 0.16 patterns in `docs/ZIG_PATTERNS.md` and the
  shapes already in `src/`.
- When in doubt, copy the shape of a recently-touched utility
  (e.g. `src/wc.zig`, `src/cat.zig`, `src/true.zig`) rather
  than inventing one.
- Prefer `std.mem.find*` over `std.mem.indexOf*` even though
  the latter still compiles.

**Reference order when stuck:**
1. Grep this file for the symbol or error message
2. Grep an existing utility in `src/` for a known-good pattern
3. Grep `docs/zig-0.16.0-release-notes.md` for the same
4. Grep `docs/zig-0.16.0-docs.md` (the language reference)
5. As a last resort, read the actual `lib/std/Io/...` source in
   your installed Zig — the lang ref is incomplete, the source
   is not
