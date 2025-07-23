# Zig Patterns for Zutils

This document contains Zig 0.14.1 patterns and idioms commonly used in this
codebase. It serves as a quick reference for implementing GNU coreutils in Zig.

## Memory Management

### Arena Allocator Pattern (Preferred for CLI tools)
```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
// All allocations are freed when arena.deinit() is called
```

### General Purpose Allocator (for testing)
```zig
const gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
```

## Command Line Arguments

### Basic Pattern
```zig
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);
// args[0] is the program name
// args[1..] are the actual arguments
```

### Iterator Pattern (no allocation)
```zig
var args_iter = std.process.args();
_ = args_iter.next(); // Skip program name
while (args_iter.next()) |arg| {
    // Process arg
}
```

## I/O Operations

### Standard Streams
```zig
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const stdin = std.io.getStdIn().reader();

try stdout.print("Hello {s}\n", .{"world"});
try stdout.writeAll("Raw string\n");
```

### File Operations
```zig
// Read entire file
const content = try std.fs.cwd().readFileAlloc(allocator, "file.txt", max_size);
defer allocator.free(content);

// Open and read file
const file = try std.fs.cwd().openFile("file.txt", .{});
defer file.close();
const content = try file.readToEndAlloc(allocator, max_size);

// Write file
try std.fs.cwd().writeFile("output.txt", "content");
```

### Buffered I/O
```zig
var buf_reader = std.io.bufferedReader(file.reader());
var reader = buf_reader.reader();

var buf_writer = std.io.bufferedWriter(file.writer());
var writer = buf_writer.writer();
defer buf_writer.flush() catch {};
```

## Error Handling

### Error Sets
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

### Error Union Pattern
```zig
fn mayFail() !void {
    // Use 'try' for propagation
    try doSomething();
    
    // Or handle explicitly
    doSomething() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
}
```

### Common Error Patterns
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
    else => return err,
};
```

## Testing

### Basic Test Pattern
```zig
test "description" {
    try std.testing.expect(true);
    try std.testing.expectEqual(@as(i32, 42), 42);
    try std.testing.expectEqualStrings("hello", "hello");
}
```

### Testing with Allocator
```zig
test "with allocation" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);
    // Test will fail if memory is leaked
}
```

### Testing Output
```zig
test "test output" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    
    try myFunction(buffer.writer());
    try std.testing.expectEqualStrings("expected output", buffer.items);
}
```

## String Operations

### String Comparison
```zig
std.mem.eql(u8, str1, str2) // Exact match
std.mem.startsWith(u8, haystack, needle)
std.mem.endsWith(u8, haystack, needle)
std.mem.indexOf(u8, haystack, needle) // Returns ?usize
```

### String Manipulation
```zig
// Tokenize
var iter = std.mem.tokenize(u8, input, " \t\n");
while (iter.next()) |token| {
    // Process token
}

// Split (includes empty strings)
var iter = std.mem.split(u8, input, ",");

// Trim
const trimmed = std.mem.trim(u8, input, " \t\n");
```

### Formatting
```zig
// Format to writer
try writer.print("{s}: {d}\n", .{name, value});

// Format to buffer
var buf: [100]u8 = undefined;
const formatted = try std.fmt.bufPrint(&buf, "{d}", .{42});

// Format with allocator
const formatted = try std.fmt.allocPrint(allocator, "{s}-{d}", .{prefix, num});
defer allocator.free(formatted);
```

## Path Operations

```zig
// Join paths
const path = try std.fs.path.join(allocator, &.{ "dir", "subdir", "file.txt" });
defer allocator.free(path);

// Get basename
const base = std.fs.path.basename("/path/to/file.txt"); // "file.txt"

// Get dirname  
const dir = std.fs.path.dirname("/path/to/file.txt"); // "/path/to"

// Get extension
const ext = std.fs.path.extension("file.txt"); // ".txt"
```

## Common Patterns for Coreutils

### Exit with Error Code
```zig
std.process.exit(1); // Non-zero for error
```

### Print Error and Exit
```zig
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print(fmt ++ "\n", args) catch {};
    std.process.exit(1);
}
```

### Argument Parsing Pattern
```zig
var positional_args = std.ArrayList([]const u8).init(allocator);
defer positional_args.deinit();

var i: usize = 1; // Skip program name
while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "-n")) {
        suppress_newline = true;
    } else if (std.mem.eql(u8, arg, "--")) {
        // Everything after -- is positional
        try positional_args.appendSlice(args[i + 1 ..]);
        break;
    } else if (arg[0] == '-') {
        fatal("Unknown option: {s}", .{arg});
    } else {
        try positional_args.append(arg);
    }
}
```

### Signal Handling
```zig
const signal = @import("std").posix.signal;
try signal.signal(.SIGINT, handleSignal);

fn handleSignal(sig: i32) callconv(.C) void {
    // Handle signal
}
```

## Performance Tips

1. Use `std.mem.copy` instead of loops for bulk copying
2. Prefer stack allocation with fixed buffers when size is known
3. Use `ArrayList` for dynamic arrays
4. Use `StringHashMap` for string-keyed maps
5. Buffered I/O for file operations
6. Arena allocator for short-lived programs

## Common Gotchas

1. **Slices don't own memory** - Be careful with lifetimes
2. **Integer overflow is defined behavior** - Use `%` operators for wrapping
3. **No null-terminated strings by default** - Use `[:0]const u8` when needed
4. **Comptime parameters** - Many std functions require comptime known values
5. **Error unions in structs** - Can't have error union fields

## Useful Standard Library

- `std.fs` - File system operations
- `std.process` - Process management
- `std.mem` - Memory operations
- `std.fmt` - Formatting
- `std.io` - Input/output
- `std.testing` - Testing utilities
- `std.time` - Time operations
- `std.sort` - Sorting algorithms
- `std.hash_map` - Hash maps
- `std.ArrayList` - Dynamic arrays