# Zig Standard Library Summary for Coreutils

This document summarizes the most relevant parts of Zig's standard library for
implementing GNU coreutils. For full documentation, run `zig std` or visit
https://ziglang.org/documentation/0.14.1/std/

## Essential Imports

```zig
const std = @import("std");
```

## Most Used Modules for Coreutils

### std.process
- `args()` - Iterator over command arguments
- `argsAlloc()` - Get all args as array (requires allocation)
- `exit()` - Exit with status code
- `getEnvMap()` - Environment variables
- `getCwd()` - Current working directory

### std.fs
- `cwd()` - Current working directory operations
- `openFile()` - Open files for reading
- `createFile()` - Create/overwrite files
- `Dir` - Directory operations
  - `iterate()` - Iterate directory entries
  - `makeDir()` - Create directory
  - `deleteFile()` - Delete file
  - `deleteDir()` - Delete empty directory
- `path` - Path manipulation
  - `join()` - Join path components
  - `basename()` - Get filename
  - `dirname()` - Get directory
  - `extension()` - Get file extension
  - `isAbsolute()` - Check if path is absolute

### std.io
- `getStdOut()` - Standard output stream
- `getStdErr()` - Standard error stream  
- `getStdIn()` - Standard input stream
- `bufferedReader()` - Buffered reading
- `bufferedWriter()` - Buffered writing

### std.mem
- `eql()` - Compare slices
- `startsWith()` - Check prefix
- `endsWith()` - Check suffix
- `indexOf()` - Find substring
- `split()` - Split string (includes empty)
- `tokenize()` - Split string (skips empty)
- `trim()` - Remove whitespace
- `copy()` - Copy memory
- `copyForwards()` - Copy with overlap

### std.fmt
- `parseInt()` - Parse integer from string
- `parseFloat()` - Parse float from string
- `bufPrint()` - Format to buffer
- `allocPrint()` - Format with allocation
- `formatInt()` - Format integer to buffer
- `formatFloat()` - Format float to buffer

### std.time
- `milliTimestamp()` - Current time in milliseconds
- `nanoTimestamp()` - Current time in nanoseconds
- `sleep()` - Sleep for nanoseconds

### std.sort
- `sort()` - Sort slice with comparison function
- `insertion()` - Insertion sort
- `heap()` - Heap sort

### std.heap
- `page_allocator` - Basic page allocator
- `ArenaAllocator` - Arena allocator (bulk free)
- `GeneralPurposeAllocator` - Debug allocator

### std.ArrayList
- Dynamic arrays with methods:
  - `init()` - Create new list
  - `append()` - Add single item
  - `appendSlice()` - Add multiple items
  - `items` - Get slice of contents
  - `clearAndFree()` - Clear and free memory

### std.hash_map
- `StringHashMap` - String-keyed hash map
- `AutoHashMap` - Auto-hashed keys
- Common methods:
  - `put()` - Insert/update
  - `get()` - Retrieve value
  - `remove()` - Delete entry
  - `contains()` - Check existence

## File I/O Patterns

### Reading Files
```zig
// Read entire file
const content = try fs.cwd().readFileAlloc(allocator, path, max_size);

// Read line by line
const file = try fs.cwd().openFile(path, .{});
defer file.close();
var buf_reader = io.bufferedReader(file.reader());
const reader = buf_reader.reader();
while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_line_size)) |line| {
    defer allocator.free(line);
    // Process line
}
```

### Writing Files
```zig
// Write entire file
try fs.cwd().writeFile(path, content);

// Write with buffering
const file = try fs.cwd().createFile(path, .{});
defer file.close();
var buf_writer = io.bufferedWriter(file.writer());
const writer = buf_writer.writer();
try writer.writeAll(content);
try buf_writer.flush();
```

## Error Handling for Coreutils

Common errors to handle:
- `error.FileNotFound`
- `error.AccessDenied` 
- `error.NotDir`
- `error.IsDir`
- `error.DiskQuota`
- `error.FileTooBig`
- `error.InputOutput`
- `error.NoSpaceLeft`
- `error.InvalidArgument`

## POSIX/System Calls

### std.posix
- `chmod()` - Change file permissions
- `chown()` - Change file ownership
- `link()` - Create hard link
- `symlink()` - Create symbolic link
- `unlink()` - Delete file
- `rename()` - Rename/move file
- `mkdir()` - Create directory
- `rmdir()` - Remove directory
- `stat()` - Get file info
- `fstat()` - Get file info from handle
- `lstat()` - Get symlink info
- `access()` - Check file accessibility
- `getcwd()` - Get current directory
- `chdir()` - Change directory
- `kill()` - Send signal
- `signal()` - Set signal handler

## Unicode Support

### std.unicode
- `utf8ValidateSlice()` - Validate UTF-8
- `utf8CountCodepoints()` - Count characters
- `Utf8Iterator` - Iterate UTF-8 codepoints
- `utf8Encode()` - Encode codepoint to UTF-8
- `utf8Decode()` - Decode UTF-8 to codepoint

## Testing Utilities

### std.testing
- `expect()` - Assert condition
- `expectEqual()` - Assert equality
- `expectEqualStrings()` - Compare strings
- `expectError()` - Expect specific error
- `expectEqualSlices()` - Compare slices
- `allocator` - Test allocator (detects leaks)

## Performance Tips

1. Use `std.BufMap` for string->string maps with automatic memory management
2. Use `std.ComptimeStringMap` for compile-time string lookups
3. Use `std.StaticBitSet` when bit count is known at compile time
4. Use `std.mem.bytesAsSlice()` for type punning
5. Use `std.math` for optimized math operations

## Useful Utilities

- `std.log` - Logging framework
- `std.crypto` - Cryptographic functions
- `std.json` - JSON parsing/writing
- `std.Uri` - URI parsing
- `std.base64` - Base64 encoding/decoding
- `std.Progress` - Progress reporting

For full details on any module, consult the official documentation or source code.