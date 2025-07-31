# Zig Documentation Style Guide for vibeutils

This guide establishes documentation and style conventions for the vibeutils project, based on Zig's official style and documentation patterns.

## Doc Comment Syntax

### Three Types of Comments

1. **Normal Comments** (`//`) - Implementation details, not included in docs
2. **Doc Comments** (`///`) - Document declarations below them
3. **Top-Level Doc Comments** (`//!`) - Document the current module/file

### Basic Rules

- Doc comments must immediately precede the declaration they document
- No blank lines between doc comment and declaration
- Multiple doc comments merge into a multiline comment
- Doc comments in unexpected places cause compile errors

### Examples

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
```

## What NOT to Do

### ❌ No JavaDoc-style Tags
```zig
// BAD - Don't use JavaDoc tags
/// @param allocator The allocator to use
/// @return A new instance
/// @throws OutOfMemory if allocation fails
```

### ❌ No Markdown in Comments
```zig
// BAD - Don't use markdown formatting
/// Creates a **new** instance with `default` values
/// See [documentation](https://example.com)
```

### ❌ No Redundant Comments
```zig
// BAD - Don't state the obvious
/// Adds two numbers
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

### ❌ No Comment Blocks
```zig
// BAD - Zig doesn't support /* */ comments
/*
 * This style is not valid in Zig
 */
```

## Good vs Bad Documentation

### Functions

**Good:**
```zig
/// Print error message to stderr and exit with error code
/// The program name is automatically prepended to the message
pub fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    // ...
}
```

**Bad:**
```zig
/// fatal function
/// @param fmt format string
/// @param fmt_args format arguments
/// This function prints an error and exits
pub fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    // ...
}
```

### Structs and Types

**Good:**
```zig
/// Options controlling copy behavior
pub const CopyOptions = struct {
    /// Preserve file attributes (permissions, timestamps)
    preserve: bool = false,
    /// Prompt before overwriting existing files
    interactive: bool = false,
    /// Copy directories recursively
    recursive: bool = false,
};
```

**Bad:**
```zig
/// Struct for copy options
/// Contains various flags
pub const CopyOptions = struct {
    preserve: bool = false,    // preserve flag
    interactive: bool = false, // interactive flag
    recursive: bool = false,   // recursive flag
};
```

### Error Sets

**Good:**
```zig
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

**Bad:**
```zig
// Copy errors
pub const CopyError = error{
    SameFile,           // same file error
    UnsupportedFileType, // unsupported type
    DestinationExists,   // dest exists
};
```

## Naming Conventions

### General Rules
- **Functions**: camelCase (`copyFile`, `printError`)
- **Types**: PascalCase (`CopyEngine`, `FileType`)
- **Constants**: UPPER_SNAKE_CASE for truly constant values, otherwise camelCase
- **Variables**: snake_case (`file_path`, `dest_exists`)
- **Error Sets**: PascalCase ending with `Error` (`CopyError`, `ParseError`)

### Specific Patterns
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

## When to Document vs Let Code Speak

### Always Document
- Public functions, types, and constants
- Complex algorithms or non-obvious logic
- Error conditions and edge cases
- Module-level purpose with `//!`

### Let Code Speak
- Simple getters/setters with obvious behavior
- Internal implementation details
- Temporary variables with clear names
- Standard library usage patterns

### Examples

```zig
// Documentation needed - public API with specific behavior
/// Copy file attributes including permissions and timestamps
/// Requires appropriate permissions on both source and destination
pub fn copyAttributes(source: []const u8, dest: []const u8) !void {
    // ...
}

// No documentation needed - obvious from name and signature
fn isDirectory(file_type: std.fs.File.Kind) bool {
    return file_type == .directory;
}

// Documentation needed - explains "why" not "what"
/// Use arena allocator for CLI tools to simplify memory management
/// All allocations are freed when the program exits
pub fn setupAllocator() std.mem.Allocator {
    // ...
}
```

## Doctests

When appropriate, use doctests to provide executable examples:

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

## Best Practices

1. **Be Concise**: One or two lines is often sufficient
2. **Focus on "Why"**: Explain purpose and behavior, not implementation
3. **Document Contracts**: Preconditions, postconditions, and invariants
4. **Use Present Tense**: "Returns" not "Will return"
5. **Avoid Pronouns**: "Parse the string" not "This parses the string"
6. **Document Errors**: When functions return errors, explain when they occur

## File Headers

Start each file with a top-level doc comment explaining its purpose:

```zig
//! Copy engine implementation for vibeutils cp command
//! Handles file copying with progress tracking and error recovery

const std = @import("std");
// ...
```

## Summary

Good Zig documentation is:
- Clear and concise
- Free from formatting markup
- Focused on behavior, not implementation
- Written in plain English
- Helpful without being redundant

Remember: If the code is self-explanatory, additional documentation may not be necessary. When in doubt, imagine reading the code six months from now - would a comment help?