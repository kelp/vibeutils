# Zig 0.15.1 Breaking Changes - Training Override Sheet

This document corrects Claude's outdated training data (pre-0.11.0) with current Zig 0.15.1 reality.

## ⚡ Quick Reference Table - "If You Think X, It's Actually Y"

| What Claude Thinks | Reality in 0.15.1 | Quick Fix |
|-------------------|-------------------|-----------|
| `std.io.getStdOut().writer()` | REMOVED - Writergate happened | Use buffered writer pattern (see below) |
| `std.io.getStdErr().writer()` | REMOVED - Writergate happened | Use buffered writer pattern (see below) |
| `usingnamespace` keyword exists | REMOVED completely from language | Use zero-bit fields + `@fieldParentPtr` for mixins |
| `async`/`await` keywords exist | REMOVED from language | Will be library features in future |
| `std.ArrayList(T).init(allocator)` | Now unmanaged by default | Use `std.ArrayListUnmanaged(T){}`, pass allocator to methods |
| `std.ArrayList(T)` | Moved to `std.array_list.Managed(T)` | Prefer unmanaged version |
| `std.BoundedArray` exists | REMOVED completely | Use `ArrayListUnmanaged.initBuffer(&buffer)` |
| `/` works on runtime signed ints | Must be comptime-known and positive | Use `@divTrunc`, `@divFloor`, or `@divExact` |
| `%` works on runtime signed floats | Must be comptime-known and positive | Use `@rem` or `@mod` |
| `{}` in format strings calls format | Now ambiguous - compile error | Use `{f}` to call format methods |
| Generic writers with `anytype` | Concrete `std.Io.Writer` type | Non-generic with buffer in interface (AnyWriter→Io.Writer) |
| `std.fifo.LinearFifo` exists | REMOVED | Use `std.Io.Reader`/`Writer` |
| `std.RingBuffer` exists | REMOVED | Use `std.Io.Reader`/`Writer` |
| Arithmetic on `undefined` allowed | Causes illegal behavior | Never operate on undefined values |
| Format methods have format strings | No format strings or options | Just `writer: *std.Io.Writer` parameter |
| `std.io.BufferedWriter` exists | REMOVED | Writers have built-in buffering |
| `std.io.CountingWriter` exists | REMOVED | Use alternatives (see Writergate) |
| Destructuring doesn't exist | ADDED in 0.15.x | `x, y, z = tuple` works now |
| `@ptrCast` can't make slices | Can cast pointer to slice | `const bytes: []const u8 = @ptrCast(&val)` |
| Assembly clobbers use strings | Use typed struct | `.{ .rcx = true, .r11 = true }` |
| `std.DoublyLinkedList(T)` generic | De-genericified | Use intrusive nodes with `@fieldParentPtr` |
| LLVM is default backend | x86 backend default for Debug | 5x faster compilation |
| `std.mem.tokenize(u8, str, delim)` | `std.mem.tokenizeAny(u8, str, delim)` | Also `tokenizeScalar`, `tokenizeSequence` |
| `std.testing.expectEqualStrings` | `std.testing.expectEqualSlices(u8, ...)` | Type parameter needed |
| `std.testing.expectEqualSlices` old signature | Swapped parameters | Expected first, actual second |
| `std.process.args()` returns iterator | `std.process.argsAlloc(allocator)` | Returns owned slice, must free |
| `std.json.Parser` | Complete redesign | Use `std.json.parseFromSlice` |
| `@typeInfo` returns old structure | Structure completely changed | Check docs for new fields |
| `@hasDecl` with usingnamespace | Won't find mixed-in decls | Decls must be direct members |
| `for` with multiple items | New syntax | `for (a, b, 0..) |x, y, i| {}` |
| `while` with multiple conditions | Use labeled blocks | `blk: { break :blk value; }` |
| `std.fs.Dir.openDir` | Added options parameter | `.{ .iterate = true }` for iteration |
| `std.mem.eql` generic | Requires type parameter | `std.mem.eql(u8, a, b)` |
| `std.fmt.allocPrint` | Returns `![]u8` not `![]const u8` | Caller owns memory |
| `std.hash_map.HashMap` | `std.hash_map.AutoHashMap` | Or use `std.hash.Map` |
| `std.heap.page_allocator` thread-safe | Not thread-safe on some platforms | Use `std.heap.GeneralPurposeAllocator` |
| Error set type syntax | Can use `||` to merge | `Error1 || Error2` |
| `@Frame` for async | REMOVED | No async support |
| `suspend`/`resume` keywords | Still exist but limited | Not for async/await |

## 🚨 Error Messages That Mean Your Training Is Wrong

```
"no member named 'getStdOut'" 
→ Writergate happened - see I/O pattern below

"no member named 'getStdErr'"
→ Writergate happened - see I/O pattern below

"no field named 'root_source_file'"
→ Build system changed - use .root_module = b.createModule(.{ .root_source_file = ... })

"ambiguous format string; specify {f} to call format method"
→ Must use {f} not {} for format methods

"use of undefined value here causes illegal behavior"
→ Can't do arithmetic on undefined anymore

"expected 2 arguments, found 1"
→ ArrayList methods need allocator parameter now

"no member named 'init'"
→ ArrayList is unmanaged - use {} or initCapacity(allocator, 0)

"usingnamespace is deprecated"
→ It's not deprecated, it's GONE - refactor completely

"async function called without await"
→ async/await don't exist - this is old error message

"no field named 'writer'"
→ Likely std.fs.File - use .deprecatedWriter() or new pattern

"error: expected type expression, found 'a document comment'"
→ Doc comment in wrong place - check placement rules

"error: unable to evaluate comptime expression"
→ Rules for comptime changed - check what's allowed

"error: dependency loop detected"
→ Circular imports - refactor module structure

"error: ambiguous reference"
→ Name collision - be more explicit with namespacing

"expected ';' after top-level decl"
→ Missing semicolon - every top-level needs one

"error: expected ',' after field"
→ Struct initialization syntax - need commas

"error: type 'T' cannot be used in runtime code"
→ Trying to use comptime type at runtime

"error: expected function or variable, found 'module'"
→ Trying to call import - need to access member

"error: integer overflow"
→ Use wrapping (+%) or saturating (+|) operators

"error: division by zero"
→ Runtime division needs safety checks

"error: expected error union type, found 'T'"
→ Missing ! in return type or try without error

"error: no member named 'allocator'"
→ ArrayList is unmanaged - pass allocator to methods

"error: expected 3 arguments, found 2"
→ std.testing functions changed signatures
```

## 📝 Critical Code Patterns

### I/O Pattern - MEMORIZE THIS
```zig
// ❌ YOUR TRAINING (WRONG)
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello, {}\n", .{world});

// ✅ ZIG 0.15.1 (RIGHT)  
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
defer stdout.flush() catch {};  // DON'T FORGET TO FLUSH!
try stdout.print("Hello, {s}\n", .{world});
```

### ArrayList Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
var list = std.ArrayList(u32).init(allocator);
defer list.deinit();
try list.append(42);

// ✅ ZIG 0.15.1 (RIGHT)
var list = std.ArrayListUnmanaged(u32){};
defer list.deinit(allocator);  // allocator needed for deinit
try list.append(allocator, 42);  // allocator needed for append
```

### Division Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
const result = a / b;  // runtime signed integers

// ✅ ZIG 0.15.1 (RIGHT)
const result = @divTrunc(a, b);  // or @divFloor, @divExact
```

### Format Method Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
pub fn format(value: T, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print("{}", .{value.field});
}

// ✅ ZIG 0.15.1 (RIGHT)
pub fn format(value: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{d}", .{value.field});  // explicit format specifier
}
```

### Mixin Pattern (replacing usingnamespace)
```zig
// ❌ YOUR TRAINING (WRONG)
const Foo = struct {
    data: u32,
    pub usingnamespace Mixin(Foo);
};

// ✅ ZIG 0.15.1 (RIGHT)
const Foo = struct {
    data: u32,
    mixin: Mixin(Foo) = .{},  // zero-bit field
};

pub fn Mixin(comptime T: type) type {
    return struct {
        pub fn method(m: *@This()) void {
            const self: *T = @alignCast(@fieldParentPtr("mixin", m));
            self.data += 1;
        }
    };
}
// Usage: foo.mixin.method() instead of foo.method()
```

### BoundedArray Replacement
```zig
// ❌ YOUR TRAINING (WRONG)  
var stack = try std.BoundedArray(i32, 8).fromSlice(initial_stack);

// ✅ ZIG 0.15.1 (RIGHT)
var buffer: [8]i32 = undefined;
var stack = std.ArrayListUnmanaged(i32).initBuffer(&buffer);
try stack.appendSliceBounded(initial_stack);
```

### Build System Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
const exe = b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// ✅ ZIG 0.15.1 (RIGHT)  
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Testing Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
try std.testing.expectEqualStrings("hello", actual);
try std.testing.expectEqual(expected, actual);  // wrong order

// ✅ ZIG 0.15.1 (RIGHT)
try std.testing.expectEqualSlices(u8, "hello", actual);
try std.testing.expectEqual(expected, actual);  // expected first
```

### JSON Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
var parser = std.json.Parser.init(allocator, false);
defer parser.deinit();
var tree = try parser.parse(json_text);
defer tree.deinit();

// ✅ ZIG 0.15.1 (RIGHT)
const parsed = try std.json.parseFromSlice(T, allocator, json_text, .{});
defer parsed.deinit();
const value = parsed.value;
```

### Tokenization Pattern  
```zig
// ❌ YOUR TRAINING (WRONG)
var it = std.mem.tokenize(u8, text, " ");
while (it.next()) |token| {}

// ✅ ZIG 0.15.1 (RIGHT)
var it = std.mem.tokenizeAny(u8, text, " ");  // or tokenizeScalar
while (it.next()) |token| {}
```

### Process Args Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
var args = std.process.args();
while (args.next()) |arg| {}

// ✅ ZIG 0.15.1 (RIGHT)
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);
for (args[1..]) |arg| {}  // skip program name
```

### For Loop Pattern
```zig
// ❌ YOUR TRAINING (WRONG)
for (items) |item, i| {}  // index as second capture

// ✅ ZIG 0.15.1 (RIGHT)
for (items, 0..) |item, i| {}  // explicit index range
for (a, b, c) |x, y, z| {}  // multiple arrays
```

### Destructuring (NEW FEATURE)
```zig
// ❌ YOUR TRAINING (Didn't exist)
const tuple = .{ 1, 2, 3 };
const x = tuple[0];
const y = tuple[1];
const z = tuple[2];

// ✅ ZIG 0.15.1 (NEW!)
const tuple = .{ 1, 2, 3 };
const x, const y, const z = tuple;  // or
var x: u32, var y: u32, var z: u32 = undefined;
x, y, z = tuple;
```

### Multi-Object For Loops (NEW FEATURE)
```zig
// ❌ YOUR TRAINING (Didn't exist)
for (names) |name, i| {
    const age = ages[i];
    const id = ids[i];
}

// ✅ ZIG 0.15.1 (NEW!)
for (names, ages, ids) |name, age, id| {
    // All three arrays iterated in parallel
}
// With index:
for (names, ages, ids, 0..) |name, age, id, i| {}
```

### Switch on Error Unions (NEW FEATURE)
```zig
// ❌ YOUR TRAINING (Required if/else or catch)
if (result) |value| {
    // use value
} else |err| {
    switch (err) {
        error.NotFound => {},
        else => {},
    }
}

// ✅ ZIG 0.15.1 (NEW!)
switch (result) {
    error.NotFound => return null,
    error.PermissionDenied => return error.AccessDenied,
    else => |value| return value * 2,  // unwrapped value
}
```

### Null-Terminated Strings & C Interop
```zig
// ❌ YOUR TRAINING (Old patterns)
extern fn puts(s: [*]const u8) c_int;
const c_str = try allocator.dupeZ(u8, zig_string);

// ✅ ZIG 0.15.1 (Current patterns)
extern fn puts(s: [*:0]const u8) c_int;  // :0 sentinel for null termination
const c_str = try allocator.dupeZ(u8, zig_string);  // Still works

// Convert C string to Zig slice
const c_string: [*:0]const u8 = c_func();
const zig_slice = std.mem.span(c_string);  // Converts to []const u8

// Sentinel arrays in structs (common in C interop)
const passwd = extern struct {
    pw_name: [*:0]u8,   // null-terminated
    pw_uid: c.uid_t,
};
```

### Allocator Best Practices
```zig
// Debug builds - use GPA for leak detection
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit(); // Reports leaks
const allocator = gpa.allocator();

// CLI tools - use Arena for simplicity
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();  // Free everything at once
const allocator = arena.allocator();

// Tests - use testing.allocator
test "example" {
    const allocator = testing.allocator;  // Detects leaks automatically
}

// AVOID page_allocator directly (no safety, can't free individual items)
```

### New Casting Builtins (NEW FEATURES)
```zig
// Remove const qualifier
const ptr: *const u8 = &value;
var mut_ptr = @constCast(ptr);  // *u8

// Remove volatile qualifier  
const vol_ptr: *volatile u8 = &hardware_register;
var normal_ptr = @volatileCast(vol_ptr);  // *u8

// Convert between error sets
const err: BigErrorSet!u32 = error.NotFound;
const smaller: SmallErrorSet!u32 = @errorCast(err);

// Check if running at comptime
if (@inComptime()) {
    // This code only runs at compile time
}

// Optimization hints
if (unlikely_condition) {
    @branchHint(.unlikely);
    // Rarely executed code
}

// Variadic min/max
const smallest = @min(a, b, c, d, e);  // Any number of args
const largest = @max(x, y, z);
```

### Comptime Evaluation Changes
```zig
// ❌ YOUR TRAINING (May not work)
comptime {
    var x = 0;
    while (x < 1000000) : (x += 1) {}  // May hit branch quota
}

// ✅ ZIG 0.15.1 (Increase quota if needed)
comptime {
    @setEvalBranchQuota(10000);  // Increase for complex comptime
    var x = 0;
    while (x < 1000) : (x += 1) {}
}

// inline else - new feature for exhaustive switching
const value = switch (compile_time_known) {
    .a => 1,
    .b => 2,
    inline else => |tag| @compileError("Unhandled: " ++ @tagName(tag)),
};

// Comptime var restrictions are stricter
test "comptime var" {
    comptime var x: i32 = 1;
    x += 1;  // OK at comptime
    
    // Can't modify comptime var in runtime context
    if (runtime_condition) {
        // x += 1;  // ERROR: can't modify comptime var here
    }
}
```

## 🔄 Migration Strategies

### Writergate Migration
1. Add buffer array before writer creation
2. Create writer with `.writer(&buffer)`
3. Use `&writer.interface` to get `*std.Io.Writer`
4. Always `defer flush()` or data may be lost

### ArrayList Migration
1. Replace `ArrayList(T)` with `ArrayListUnmanaged(T)`
2. Initialize with `{}` not `.init(allocator)`
3. Add allocator parameter to ALL method calls
4. If you really need managed: `std.array_list.Managed(T)`

### usingnamespace Migration
1. For conditional inclusion: use compile-time conditionals on the declaration
2. For mixins: use zero-bit fields with `@fieldParentPtr`
3. For implementation switching: use conditional assignment to public decls

### Format String Migration
1. Replace `{}` with explicit format specifiers
2. Use `{f}` to explicitly call format methods
3. Use `{s}` for strings, `{d}` for decimals
4. Use `{any}` to skip format methods

## ⚠️ Features That Are GONE
These aren't deprecated, they're DELETED:
- `usingnamespace` keyword
- `async`/`await` keywords  
- `@frameSize` builtin
- `std.io.getStdOut/In/Err`
- `std.BoundedArray`
- `std.fifo.LinearFifo`
- `std.io.BufferedWriter/Reader`
- `std.io.CountingWriter`
- Generic `std.DoublyLinkedList(T)`

## 🆕 Features That Are NEW
Things that didn't exist in your training:
- Destructuring assignments
- `@ptrCast` to slices
- Saturating operators: `+|`, `-|`, `*|`, `<<|`
- `{f}` format specifier requirement
- `{t}` for `@tagName()` and `@errorName()`
- `{b64}` for base64 output
- Non-exhaustive enum `_` with explicit tags
- Module-level UBSan configuration
- x86 backend as default for Debug
- `@inComptime` builtin - check if code is running at comptime
- `@branchHint` for optimization hints (.likely, .unlikely, .cold)
- `@min`/`@max` variadic builtins - any number of arguments
- `@errorCast` - convert between error sets
- `@constCast` - remove const qualifier
- `@volatileCast` - remove volatile qualifier
- `@addrSpaceCast` - convert between address spaces
- Multi-object for loops - iterate multiple arrays simultaneously
- Switch on error unions directly
- `inline for` - compile-time loop unrolling
- `inline switch` prongs - force inline specific cases
- Built-in package manager with `build.zig.zon`
- Result Location Semantics (RLS) improvements
- Lossy int-to-float coercion errors

## 📦 Standard Library Migrations

### Where Did It Go?
| Old Location | New Location | Notes |
|--------------|--------------|-------|
| `std.io.getStdOut()` | `std.fs.File.stdout()` | Returns File, not writer |
| `std.mem.tokenize` | `std.mem.tokenizeAny` | Multiple variants now |
| `std.ArrayList(T)` | `std.ArrayListUnmanaged(T)` | Default is unmanaged |
| `std.BoundedArray` | Use `ArrayListUnmanaged.initBuffer` | Completely removed |
| `std.json.Parser` | `std.json.parseFromSlice` | Complete API change |
| `std.fifo.LinearFifo` | Use `std.Io.Reader/Writer` | Removed |
| `std.testing.expectEqualStrings` | `std.testing.expectEqualSlices(u8, ...)` | Type param required |
| `std.hash_map.HashMap` | `std.hash_map.AutoHashMap` | Or `std.hash.Map` |
| `std.fmt.format` | `std.Io.Writer.print` | Different API |
| `std.io.BufferedWriter` | Built into writers | No separate type |
| `std.process.args()` | `std.process.argsAlloc()` | Returns owned slice |
| `std.compress.deflate` | REMOVED | Copy old code if needed |
| `std.http.Client/Server` | Complete rewrite | New stream-based API |
| Package management | Built-in with `build.zig.zon` | No more git submodules/manual deps |

## ⚠️ Subtle Gotchas

### Things That Look Similar But Aren't

1. **Division is restricted**: Runtime signed division must use `@divTrunc`
2. **Format strings are strict**: `{}` won't work, need `{any}` or `{f}` or specific type
3. **ArrayList methods need allocator**: EVERY method, even `toOwnedSlice`
4. **Writers must be flushed**: Data loss if buffer goes out of scope unflushed
5. **Testing parameter order**: Expected first, actual second (swapped in some functions)
6. **Error sets merge with `||`**: Not `error{A} | error{B}` but `Error1 || Error2`
7. **For loops need explicit index**: `for (items, 0..)` not `for (items) |item, i|`
8. **Build system uses modules**: Not just file paths anymore
9. **Arithmetic on undefined**: Any operation causes illegal behavior now
10. **Float coercion errors**: Can't coerce large ints to float if precision lost
11. **@intCast vs @truncate**: `@intCast` checks for overflow, `@truncate` silently cuts bits
12. **Sentinel arrays everywhere**: `[*:0]const u8` for C strings, use `std.mem.span` to convert
13. **inline else**: New option for exhaustive switching with comptime-known values
14. **Allocator choices matter**: GPA for debug (leak detection), Arena for CLI tools, page_allocator sparingly

## 🔍 Quick Diagnostics

### "Why doesn't this compile?"
1. Check if it uses removed features (usingnamespace, async, BoundedArray)
2. Check if it's missing allocator parameters (ArrayList methods)
3. Check if it's using old I/O patterns (getStdOut)
4. Check if format strings need specifiers ({} → {s}, {d}, {f})

### "Why does this crash?"
1. Unflushed writer buffers
2. Division by zero or signed division without @divTrunc
3. Arithmetic on undefined values
4. Memory not freed (if using argsAlloc, etc.)

## 📚 When You're Stuck

1. **First**: Check error message against the table above
2. **Second**: Grep working code in `src/` for similar patterns
3. **Third**: Check `docs/zig-0.15.1-docs.md` for current syntax
4. **Fourth**: Look at `docs/zig-0.15.1-release-notes.md` for migration guides

Remember: The language changed FUNDAMENTALLY. Your instincts are wrong. Always verify.