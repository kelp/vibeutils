# Zig Knowledge Prompts

Test Claude's base Zig knowledge by pasting these prompts into
a fresh conversation with NO project context. Save each response
to the numbered .zig file, then run the test harness.

## How to Test

1. Open a fresh Claude conversation (no project loaded)
2. For each prompt below, ask Claude the question
3. Save the code it produces to `probes/NN_name.zig`
4. Run: `./scripts/zig-knowledge-test.sh probes/`
5. Results show which patterns Claude gets wrong

## Prompts

### 01 - stdout (Writergate)

> Write a Zig program that prints "hello world" to stdout.
> Just the code, no explanation. Use the standard library.

Tests: Does Claude use `std.io.getStdOut()` (broken) or the
buffered writer pattern (correct)?

### 02 - stderr

> Write a Zig function that prints an error message to stderr.
> Just the code, no explanation.

Tests: Does Claude use `std.io.getStdErr()` (broken) or the
buffered writer pattern (correct)?

### 03 - ArrayList

> Write a Zig test that creates an ArrayList of u32, appends
> three values, and checks the length is 3. Just the code.

Tests: Does Claude use `.init(allocator)` managed pattern or
`ArrayListUnmanaged` with allocator-per-call?

### 04 - BoundedArray

> Write a Zig function that uses a stack-allocated bounded
> array (max 64 elements) of u8. Append a few values and
> return the slice. Just the code.

Tests: Does Claude use `std.BoundedArray` (removed) or
`ArrayListUnmanaged.initBuffer` (correct)?

### 05 - tokenize

> Write a Zig function that splits a string by whitespace and
> returns the token count. Just the code.

Tests: Does Claude use `std.mem.tokenize` (old name) or
`std.mem.tokenizeAny`/`tokenizeScalar` (current)?

### 06 - testing

> Write a Zig test that compares two strings for equality
> using the standard testing library. Just the code.

Tests: Does Claude use `expectEqualStrings` (still works) or
`expectEqualSlices(u8, ...)` (also works)?

### 07 - process args

> Write a Zig program that prints each command-line argument
> on its own line. Just the code.

Tests: Does Claude use `std.process.args()` (still works) or
`std.process.argsAlloc` (also works)?

### 08 - JSON parsing

> Write a Zig test that parses the JSON string
> `{"name":"alice","age":30}` into a struct and checks the
> values. Just the code.

Tests: Does Claude use `std.json.Parser` (removed) or
`std.json.parseFromSlice` (correct)?

### 09 - format method

> Write a Zig struct with an x:i32 field that implements the
> format method so it can be printed with std.fmt. Include a
> test that formats it to a buffer. Just the code.

Tests: Does Claude use old format signature with `comptime fmt,
options, writer: anytype` (broken) or new signature with
`writer: *std.Io.Writer` (correct)?

### 10 - usingnamespace

> Write a Zig mixin pattern where a struct gains methods from
> another type. Just the code.

Tests: Does Claude use `usingnamespace` (removed) or zero-bit
field with `@fieldParentPtr` (correct)?

### 11 - division

> Write a Zig function that takes two i32 parameters and
> returns their integer quotient. Just the code.

Tests: Does Claude use `a / b` (fails for runtime signed ints)
or `@divTrunc(a, b)` (correct)?

### 12 - for loop with index

> Write a Zig function that iterates over a slice and prints
> each element with its index. Just the code.

Tests: Does Claude use `for (items) |item, i|` (old syntax) or
`for (items, 0..) |item, i|` (correct)?

### 13 - build.zig executable

> Write a Zig build.zig file that builds an executable called
> "hello" from src/main.zig. Just the code.

Tests: Does Claude use `.root_source_file` directly (old) or
`.root_module = b.createModule(...)` (correct)?

### 14 - async/await

> Write a Zig program that runs two tasks concurrently using
> async/await. Just the code.

Tests: Does Claude try to use `async`/`await` (removed) or
explain they don't exist?
