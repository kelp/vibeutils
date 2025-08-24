# Zig Patterns for vibeutils

This document contains Zig 0.15.1 patterns and idioms commonly used in this
codebase. It serves as a quick reference for implementing GNU coreutils in Zig.

**⚠️ IMPORTANT: See `ZIG_BREAKING_CHANGES.md` for critical I/O changes in Zig 0.15.1**

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

### Standard Streams (Zig 0.15.1)
```zig
// NEW: Explicit buffers required
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [4096]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;

try stdout.print("Hello {s}\n", .{"world"});
try stdout.writeAll("Raw string\n");

// CRITICAL: Must flush before buffer goes out of scope!
stdout.flush() catch {};
stderr.flush() catch {};
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

### File I/O with Buffers (Zig 0.15.1)
```zig
// Reading with buffer
var read_buffer: [8192]u8 = undefined;
var file_reader = file.reader(&read_buffer);
const reader = &file_reader.interface;

// Writing with buffer
var write_buffer: [8192]u8 = undefined;
var file_writer = file.writer(&write_buffer);
const writer = &file_writer.interface;
defer writer.flush() catch {};

// Note: std.io.bufferedReader/Writer no longer exist!
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

### Testing Output (Zig 0.15.1)
```zig
test "test output" {
    // ArrayList now requires allocator for all operations
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    
    // writer() now requires allocator parameter
    try myFunction(buffer.writer(std.testing.allocator));
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

### Print Error and Exit (Zig 0.15.1)
```zig
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    // Note: For simple error printing, can still use unbuffered
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.print(fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}
```

### Argument Parsing Pattern (Zig 0.15.1)
```zig
var positional_args = try std.ArrayList([]const u8).initCapacity(allocator, 0);
defer positional_args.deinit(allocator);

var i: usize = 1; // Skip program name
while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "-n")) {
        suppress_newline = true;
    } else if (std.mem.eql(u8, arg, "--")) {
        // Everything after -- is positional
        try positional_args.appendSlice(allocator, args[i + 1 ..]);
        break;
    } else if (arg[0] == '-') {
        fatal("Unknown option: {s}", .{arg});
    } else {
        try positional_args.append(allocator, arg);
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

## Documentation Patterns

### Doc Comment Types

Zig has three types of comments with specific purposes:

1. **Normal Comments** (`//`) - Implementation details, not included in docs
2. **Doc Comments** (`///`) - Document declarations below them
3. **Top-Level Doc Comments** (`//!`) - Document the current module/file

### Doc Comment Rules
- Doc comments must immediately precede the declaration they document
- No blank lines between doc comment and declaration
- Multiple doc comments merge into a multiline comment
- Doc comments in unexpected places cause compile errors

### Good Documentation Examples

```zig
//! vibeutils common library - shared functionality for all utilities

const std = @import("std");

/// Common error types used across vibeutils
pub const Error = error{
    ArgumentError,
    FileNotFound,
    PermissionDenied,
};

/// Execute a copy operation with progress tracking
/// Returns error if source cannot be read or destination cannot be written
pub fn executeCopy(self: *CopyEngine, operation: types.CopyOperation) !void {
    // Implementation details use normal comments
    // These won't appear in generated documentation
}

/// Options controlling copy behavior
pub const CopyOptions = struct {
    /// Preserve file attributes (permissions, timestamps)
    preserve: bool = false,
    /// Prompt before overwriting existing files
    interactive: bool = false,
    /// Copy directories recursively
    recursive: bool = false,
};

/// Errors specific to copy operations
pub const CopyError = error{
    /// Source and destination refer to the same file
    SameFile,
    /// Filesystem does not support the requested operation
    UnsupportedFileType,
    /// Destination exists and would be overwritten
    DestinationExists,
};
```

### What NOT to Do

```zig
// ❌ BAD - Don't use JavaDoc tags
/// @param allocator The allocator to use
/// @return A new instance
/// @throws OutOfMemory if allocation fails

// ❌ BAD - Don't use markdown formatting
/// Creates a **new** instance with `default` values
/// See [documentation](https://example.com)

// ❌ BAD - Don't state the obvious
/// Adds two numbers
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

// ❌ BAD - Zig doesn't support /* */ comments
/*
 * This style is not valid in Zig
 */
```

### Naming Conventions

- **Functions**: camelCase (`copyFile`, `printError`)
- **Types**: PascalCase (`CopyEngine`, `FileType`)
- **Constants**: UPPER_SNAKE_CASE for truly constant values, otherwise camelCase
- **Variables**: snake_case (`file_path`, `dest_exists`)
- **Error Sets**: PascalCase ending with `Error` (`CopyError`, `ParseError`)

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

### When to Document

**Always Document:**
- Public functions, types, and constants
- Complex algorithms or non-obvious logic
- Error conditions and edge cases
- Module-level purpose with `//!`

**Let Code Speak:**
- Simple getters/setters with obvious behavior
- Internal implementation details
- Temporary variables with clear names
- Standard library usage patterns

### Documentation Best Practices

1. **Be Concise**: One or two lines is often sufficient
2. **Focus on "Why"**: Explain purpose and behavior, not implementation
3. **Document Contracts**: Preconditions, postconditions, and invariants
4. **Use Present Tense**: "Returns" not "Will return"
5. **Avoid Pronouns**: "Parse the string" not "This parses the string"
6. **Document Errors**: When functions return errors, explain when they occur

### File Headers

Start each file with a top-level doc comment:

```zig
//! Copy engine implementation for vibeutils cp command
//! Handles file copying with progress tracking and error recovery

const std = @import("std");
// ...
```

### Doctests

Use doctests to provide executable examples:

```zig
/// Parse a file mode string into numeric form
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

These patterns have been battle-tested in this codebase and follow Zig 0.15.1
best practices. When in doubt, look at existing implementations in `src/` for
examples of these patterns in action.

Good Zig documentation is clear, concise, free from formatting markup, focused 
on behavior (not implementation), and helpful without being redundant.