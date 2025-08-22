# Zig 0.15.1 Writer/Reader Migration Guide ("Writergate")

## Overview

Zig 0.15.1 introduces a fundamental redesign of the I/O system. The new system
uses `std.Io.Writer` and `std.Io.Reader` (capital I, lowercase o) which are
**non-generic concrete interfaces** with buffers as part of the interface
rather than the implementation.

## Key Changes

### 1. No More Generic Readers/Writers

**OLD (Zig 0.14.1):**
```zig
// Writers were generic
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const file_writer = file.writer();
```

**NEW (Zig 0.15.1):**
```zig
// Writers are concrete with explicit buffers
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [4096]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;
```

### 2. Buffer Management

The buffer is now **part of the interface**, not hidden in the implementation:

**OLD:**
```zig
// Buffer was hidden inside BufferedWriter
const stdout_file = std.io.getStdOut().writer();
var bw = std.io.bufferedWriter(stdout_file);
const stdout = bw.writer();
try stdout.print("Hello", .{});
try bw.flush();
```

**NEW:**
```zig
// Buffer is explicit and controlled by you
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
try stdout.print("Hello", .{});
try stdout.flush(); // Flush on the interface itself
```

### 3. Reader Pattern Changes

**OLD:**
```zig
const stdin = std.io.getStdIn().reader();
const file_reader = file.reader();
```

**NEW:**
```zig
var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;

var file_buffer: [4096]u8 = undefined;
var file_reader = file.reader(&file_buffer);
const reader = &file_reader.interface;
```

## Migration Patterns for vibeutils

### Pattern 1: Main Function I/O

**OLD (in main functions):**
```zig
pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();
    
    const exit_code = try runUtil(allocator, args, stdout_writer, stderr_writer);
}
```

**NEW:**
```zig
pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    
    const exit_code = try runUtil(allocator, args, stdout, stderr);
    
    // IMPORTANT: Flush before exit!
    try stdout.flush();
    try stderr.flush();
}
```

### Pattern 2: File Operations

**OLD (cat.zig example):**
```zig
const file = try std.fs.cwd().openFile(file_path, .{});
defer file.close();
try processInput(allocator, file.reader(), stdout_writer, options, &line_state);
```

**NEW:**
```zig
const file = try std.fs.cwd().openFile(file_path, .{});
defer file.close();

var file_buffer: [8192]u8 = undefined;
var file_reader = file.reader(&file_buffer);
const reader = &file_reader.interface;

try processInput(allocator, reader, stdout_writer, options, &line_state);
```

### Pattern 3: Test Writers

**OLD (in tests):**
```zig
test "basic functionality" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    
    const exit_code = try runUtil(allocator, args, stdout_buffer.writer(), common.null_writer);
}
```

**NEW:**
```zig
test "basic functionality" {
    var stdout_list = std.ArrayList(u8).init(testing.allocator);
    defer stdout_list.deinit();
    
    // ArrayList writer needs a buffer too
    var write_buffer: [1024]u8 = undefined;
    var array_writer = stdout_list.writer(&write_buffer);
    const stdout = &array_writer.interface;
    
    const exit_code = try runUtil(allocator, args, stdout, common.null_writer);
    try stdout.flush(); // Flush to ensure data is in ArrayList
}
```

### Pattern 4: Function Signatures

**OLD:**
```zig
pub fn runUtil(allocator: Allocator, args: []const []const u8,
               stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // ...
}
```

**NEW (Option 1 - Keep anytype):**
```zig
// Can still use anytype since interface is concrete
pub fn runUtil(allocator: Allocator, args: []const []const u8,
               stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Works the same, just pass &writer.interface
}
```

**NEW (Option 2 - Use concrete type):**
```zig
const Writer = std.io.Writer;

pub fn runUtil(allocator: Allocator, args: []const []const u8,
               stdout_writer: *Writer, stderr_writer: *Writer) !u8 {
    // More type-safe, clearer intent
}
```

## Critical API Changes

### std.io → std.fs.File
The old `std.io.getStdOut()`, `std.io.getStdIn()`, and `std.io.getStdErr()` 
functions **no longer exist**. They have been replaced with:
- `std.fs.File.stdout()` 
- `std.fs.File.stdin()`
- `std.fs.File.stderr()`

### std.io.bufferedWriter is GONE
The `std.io.bufferedWriter` function has been completely removed. Buffering is 
now handled by the buffer you provide to the writer.

### New Interface Types
- `std.Io.Writer` (capital I, lowercase o) - The new writer interface
- `std.Io.Reader` (capital I, lowercase o) - The new reader interface
- These are concrete types, not generic!

## Important Notes

### 1. Always Flush!
With the new system, you **MUST** explicitly flush writers before the buffer
goes out of scope or program exit:

```zig
defer stdout.flush() catch {}; // In main or before buffer deallocation
```

### 2. Buffer Sizing
Choose appropriate buffer sizes:
- Small operations: 1024-4096 bytes
- File I/O: 4096-8192 bytes (typical page size)
- Network I/O: Larger buffers may be beneficial

### 3. Stack vs Heap Buffers
```zig
// Stack buffer (fast, limited size)
var buffer: [4096]u8 = undefined;

// Heap buffer (for dynamic sizing)
const buffer = try allocator.alloc(u8, buffer_size);
defer allocator.free(buffer);
```

### 4. Removed Types
These no longer exist in 0.15.1:
- `BufferedWriter`
- `CountingWriter`
- `BufferedReader`
- Generic reader/writer functions

## Benefits of the New System

1. **Better Performance**: Optimizer can inline and optimize better
2. **Precise Error Sets**: No more generic error unions
3. **More Control**: You manage buffer lifetime and size
4. **New Features**: Support for peek, discard, vector operations
5. **Simpler Code**: Less generic complexity

## ArrayList API Changes

Zig 0.15.1 also changed ArrayList to be "unmanaged" by default, requiring allocator parameters:

### Key Changes:
```zig
// OLD (Zig 0.14.1)
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
list.append(value);
list.toOwnedSlice();
list.writer();

// NEW (Zig 0.15.1)
var list = try std.ArrayList(u8).initCapacity(allocator, 0);
defer list.deinit(allocator);
try list.append(allocator, value);
list.toOwnedSlice(allocator);
list.writer(allocator);
```

### Test Helper Pattern:
```zig
// For test helpers that use ArrayLists
const TestBuffers = struct {
    stdout: std.ArrayList(u8),
    stderr: std.ArrayList(u8),

    fn init() TestBuffers {
        return TestBuffers{
            .stdout = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable,
            .stderr = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable,
        };
    }

    fn deinit(self: *TestBuffers) void {
        self.stdout.deinit(testing.allocator);
        self.stderr.deinit(testing.allocator);
    }

    fn stdoutWriter(self: *TestBuffers) @TypeOf(self.stdout.writer(testing.allocator)) {
        return self.stdout.writer(testing.allocator);
    }
};
```

## Migration Checklist for vibeutils

- [x] Update all `main()` functions to use buffered writers
- [x] Fix ArrayList API usage throughout codebase
- [ ] Update all file reading code to use buffered readers
- [ ] Update all test code to handle new writer pattern
- [ ] Add explicit flush calls where needed
- [ ] Update common library helpers if they handle I/O
- [ ] Update documentation and examples
- [ ] Consider buffer size requirements for each utility
- [ ] Test privileged operations still work with new I/O

## Common Pitfalls

1. **Forgetting to flush**: Data stays in buffer without explicit flush
2. **Buffer going out of scope**: Ensure buffer lives as long as writer
3. **Wrong buffer size**: Too small causes frequent flushes, too large wastes memory
4. **Not using `&writer.interface`**: Pass the interface pointer, not the writer struct

## Example: Complete Migration (Real basename.zig)

**Before (basename.zig main - Zig 0.14.1):**
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runBasename(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}
```

**After (basename.zig main - Zig 0.15.1):**
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runBasename(allocator, args[1..], stdout, stderr);
    
    // CRITICAL: Flush buffers before exit!
    stdout.flush() catch {};
    stderr.flush() catch {};
    
    std.process.exit(exit_code);
}
```