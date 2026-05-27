# Tiger Style Review: G11-readlink-uniq-free-head-wc

**Files reviewed**: 5 files, ~4858 LOC.

---

## src/readlink.zig

### Line-length violations (>100 cols)

Production code only (test bodies repeat the same call-site pattern
mechanically and are omitted):

- L40–42: 109–110 cols — three `meta` descriptor strings inside
  `ReadlinkArgs`. Add trailing commas; `zig fmt` will wrap the struct
  literal onto multiple lines.
- L72: 146 cols — `runReadlink` signature. Add a trailing comma after
  the last parameter so `zig fmt` can format it vertically.
- L74: 165 cols — `parseOrExit` call. Extract the catch into a separate
  `else` branch or wrap with trailing comma.
- L121, L126: 113–115 cols — `printErrorWithProgram` call and return
  expression. Both fit if the return is extracted to a local variable.

### Assertions

Zero `std.debug.assert` calls across the entire file. Tiger Style
requires a minimum average of two assertions per function. None of the
following invariants are checked at runtime:

- `resolveLink`: `path.len > 0` is never asserted before calling OS
  APIs.
- `realPathAbsoluteDupe` / `realPathDupe`: `path.len > 0` and
  `buf.len >= std.Io.Dir.max_path_bytes` are silent preconditions.
- `getCanonicalizeMode`: the returned enum could assert that at most one
  mode flag is set (only one of `-f`, `-e`, `-m` wins).
- `runReadlink`: `parsed.positionals.len > 0` is checked with an `if`
  that returns early, but the loop at L100 could assert
  `parsed.positionals.len > 0` again as a postcondition guard.

### Unbounded loops / no recursion

No recursion found. No `while (true)` in production code.

### Error handling

`resolveCanonicalMissingOk` (L180) catches the `readLink` error with
`|_|` (L199), discarding the error value. When the OS returns an
unexpected error (e.g., `error.AccessDenied`) instead of `NotLink`, it
is silently treated as "not a symlink" and the function proceeds to call
`canonicalizeParentMustExist`. This masks permission errors as
behavioural non-symlink paths. Use a named binding and rethrow
non-`NotLink` errors:

```zig
} else |err| {
    if (err != error.NotLink and err != error.FileNotFound) return err;
    return path_utils.canonicalizeParentMustExist(allocator, io, path);
}
```

Similarly in `resolveLink` `.missing` arm (L168): `|_|` discards any
error from `realPathDupe` before falling back to
`canonicalizeMissing`. If the error was `error.AccessDenied` the
fallback silently continues where it should propagate.

### Variable scope

`has_error` (L98 in `runReadlink`) is declared before the `for` loop
that sets it. Tiger Style says declare at the smallest possible scope;
here the declaration must be before the loop, so this is acceptable. No
violation.

`verbose` (L97) is declared even when `parsed.quiet` is false, but is
only used inside the error branch of the loop. Low impact.

### Comments

`realPathAbsoluteDupe` (L129–131) has a useful block comment explaining
the debug-allocator size mismatch. The "why" is present. Good.

`resolveCanonicalMissingOk` (L177): comment says "Resolve a link target
or canonicalize a path" — this is `resolveLink`'s doc, not this
function's. The function-level comment should say: "GNU -f semantics:
resolve the symlink target, then canonicalize allowing the last
component to be absent."

### Other

`runReadlink` (L72–127): 55-line body. Within the 70-line limit.

---

## src/uniq.zig

### Function-length violations (>70 lines)

- `runUniq` (L74–203): **129 lines**. This is the main offender. The
  function performs three distinct phases: arg pre-processing, arg
  parsing, and I/O dispatch. The I/O dispatch section (L140–202) is
  itself nearly 63 lines and contains a full copy of the
  output-path-opening logic inside both the `if (input_path)` and
  `else` branches (see below). Extract an `openOutputWriter` helper and
  a `dispatchReader` helper to bring `runUniq` within the 70-line
  limit.
- `runUniqWithInput` (L206–271): **65 lines**. Within the limit but
  close. The `while (true)` loop body is dense; acceptable for now.

### Line-length violations (>100 cols)

- L74: 142 cols — `runUniq` signature. Add trailing comma to wrap.
- L86, L90, L97, L101: 196–206 cols — `printErrorWithProgram` calls
  with embedded multi-line `\n` format strings. Extract the format
  string to a constant:
  ```zig
  const invalid_method_msg =
      "invalid argument '{s}' for '--all-repeated'\n" ++
      "Valid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'";
  ```
- L110: 174 cols — `parseOrExit` call.
- L136: 166 cols — `printErrorWithProgram` with embedded hint string.
- L141, L158, L182: 114–119 cols — `input_path` / `output_path`
  ternary expressions.
- L150, L165, L174, L176, L189, L198, L200: 101–136 cols — scattered
  across dispatch block.
- L352: 159 cols — `outputLine` signature. Add trailing comma.

### Assertions

Zero `std.debug.assert` calls. Missing:

- `getCompareSlice`: should assert `pos <= line.len` after each skip
  phase before returning a slice.
- `outputLine`: should assert `count > 0` (a group of zero occurrences
  is never valid).
- `runUniqWithInput`: should assert that `count >= 1` when `prev_line`
  is non-null at the loop-break point.

### Unbounded loops / no recursion

`runUniqWithInput` (L231): `while (true)` is bounded by EOF from the
reader. The comment "End of input: flush last group" documents the exit
condition. Acceptable, but Tiger Style prefers asserting the loop is
not infinite: a comment asserting "this loop terminates on
`EndOfStream`" meets the spirit; adding `std.debug.assert(false)` on
the unreachable path would be stronger.

`readLine` (L279): `while (true)` is bounded by `EndOfStream` or
delimiter. Same note.

### Error handling

`runUniqWithInput` (L231–241): the two arms of the `catch |err|
switch` are identical:
```zig
error.OutOfMemory => { ... return general_error; },
else => { ... return general_error; },
```
This provides no distinction between OOM and I/O errors. Collapse to a
single `else` arm, or keep them distinct only if the error message
differs. Currently it does not.

### Variable scope / code duplication

`runUniq` (L140–202): the output-path-opening block (check positionals,
`createFile`, buffer, writer, `runUniqWithInput`) is duplicated verbatim
for the file-input path and the stdin path. The only difference is the
reader. Extract:

```zig
fn openOutputWriter(...) !?OutputWriterHandle { ... }
```

This cuts `runUniq` by ~30 lines and eliminates the duplication.

`output_path` (L158 and L182): two identically-named `const` bindings
in different scopes of the same function. While Zig scopes these
correctly, the duplicated name makes the function harder to audit.
Named differently or extracted to a helper, this ambiguity disappears.

### Comments

`runUniqWithInput` (L205): comment "Internal function that processes
input from a reader. Testable with fixed readers." — says what, not
why. Add: "Split from runUniq so unit tests can inject a fixed reader
without a real file."

---

## src/free.zig

### Function-length violations (>70 lines)

- `runFree` (L373–447): **74 lines**. Exceeds the 70-line limit by 4
  lines. The `-c/-s` validation block and continuous-mode loop could be
  extracted into `runContinuous(...)` to bring `runFree` within the
  limit.
- `getMemInfoLinux` (L116–175): **59 lines**. Within limit but dense.

### Line-length violations (>100 cols)

- L66: 119 cols — `@divExact(@sizeOf(...), @sizeOf(...))`. Wrap by
  extracting the count to a named constant:
  ```zig
  const vm_stats_count: c.mach_msg_type_number_t =
      @intCast(@divExact(@sizeOf(c.vm_statistics64_data_t), @sizeOf(c.natural_t)));
  ```
- L301: 133 cols — `printMemRow` signature. Add trailing comma.
- L332: 101 cols — `printTotalRow` signature. Add trailing comma.
- L360: 121 cols — `printReport` signature. Add trailing comma.
- L373: 142 cols — `runFree` signature. Add trailing comma.
- L377, L381, L385, L389, L407, L421, L427, L433, L451: 101–123 cols
  — various call sites in `runFree` and `displayOnce`.

### Assertions

Zero `std.debug.assert` calls. Missing:

- `scaleValue`: should assert `bytes` is representable in the chosen
  unit (or at minimum that `divisor > 0`, though it is a compile-time
  constant).
- `getMemInfoMacOS`: should assert `page_size > 0` after `getpagesize()`
  returns, before multiplying page counts.
- `printMemRow`: should assert `!is_swap` implies the label is not
  "Swap:" (or vice versa) — this coupling is invisible at the call site.
- `displayOnce`: should assert the returned `u8` is a valid exit code
  (i.e., `== 0 or == 1`).

### Unbounded loops / no recursion

`runFree` (L432): `while (repeat_count == 0 or iterations < repeat_count)`.
When `repeat_count == 0` this loop never terminates (intentional: `free
-s 1` polls forever). Tiger Style requires this to be asserted:

```zig
// This loop intentionally does not terminate when repeat_count == 0.
// It is bounded only by signal (SIGINT) or error.
std.debug.assert(interval > 0); // caller guarantees -s was provided
```

The redundant double-check on L438 (`if (repeat_count > 0 and
iterations >= repeat_count) break`) duplicates the while condition.
This is dead code when `repeat_count > 0`: the while condition already
prevents entry. Remove the inner `break` or document why it is present.

### Error handling

`printHelp` (L466–485) and `printVersion` (L487–489) are declared as
returning `void` and silently discard I/O errors with `catch {}`. If
stdout is closed (e.g., piped to `head -1`), help text is silently
lost. The callers `runFree` (L397, L402) do not check for errors
either. Compare with `readlink.zig` and `head.zig` where `printHelp`
returns `!void` and the caller propagates. Make `printHelp` and
`printVersion` in `free.zig` consistent: return `!void` and propagate.

`displayOnce` (L449–460): `printReport` errors are caught and converted
to exit code 1 with no diagnostic to stderr. An I/O write failure
should log `"free: write error: ..."` before returning, matching how
other utilities handle write failures.

`runFree` (L433–434): `displayOnce` returns plain `u8` (not `!u8`).
The comparison `if (result != 0) return result` is correct but the
`u8` vs `!u8` asymmetry with other `runXxx` functions is a style
inconsistency that could confuse readers.

### Comments

`printMemRow` (L300): no doc comment. The `is_swap` boolean parameter
is non-obvious at every call site. Document why swap and mem share one
function rather than having separate functions.

`runFree` (L419): comment says "Per GNU free: -c requires -s". This is
the "why" — good. But the comment is separated from the validation
block by the `interval`/`repeat_count` declarations above it. Move the
validation immediately after parsing to keep "assert preconditions early."

---

## src/head.zig

### Function-length violations (>70 lines)

- `runHead` (L103–204): **101 lines**. The function combines arg
  expansion, arg parsing, option validation, and per-file dispatch.
  Extract the per-file loop body into `processFile(...)` (open, stat,
  header, call `processInput`) to bring `runHead` within 70 lines.
- `processInput` (L252–322): **70 lines**. Exactly at the limit. The
  negative-count buffering branch (L253–294) is a natural extraction
  candidate: `processInputNegative(reader, writer, options, alloc)`.
- `expandObsoleteArgs` (L42–90): **48 lines**, within limit. The
  function makes two passes over `args` with near-identical loop
  bodies. A single pass that appends to a growing list would be both
  shorter and correct; the current approach is justified by the need to
  pre-size the output slice, but this is worth a comment.

### Line-length violations (>100 cols)

- L103: 150 cols — `runHead` signature. Add trailing comma.
- L107: 171 cols — `parseOrExit` call.
- L129, L134: 127 cols — `printErrorWithProgram` for invalid line
  count. Extract to a helper or split the format string.
- L146: 116 cols — nested ternary for `show_headers`. Extract to:
  ```zig
  const show_headers: bool = if (is_quiet) false
      else if (parsed_args.verbose) true
      else parsed_args.positionals.len > 1;
  ```
- L174, L181, L186: 136–157 cols — `printErrorWithProgram` calls in
  the file-dispatch loop.
- L252: 128 cols — `processInput` signature. `allocator: ?std.mem.Allocator`
  is the trigger; consider a named options struct.
- L304: 112 cols — double-nested `@min` / `@intCast`. Extract:
  ```zig
  const n = @min(remaining, std.math.maxInt(usize));
  const to_write = @min(@as(usize, @intCast(n)), available.len);
  ```

### Assertions

Zero `std.debug.assert` calls. Missing:

- `processInput`: should assert `options.line_count > 0 or
  options.negative_count > 0 or options.byte_count != null` — at least
  one mode must be active.
- `expandObsoleteArgs`: should assert the output slice length equals
  `args.len + extra` after the fill loop.
- `isObsoleteNumArg`: should assert `arg.len > 0` before indexing
  `arg[0]`.
- `streamOneLine`: should assert `delimiter` is not zero when called in
  line mode (the zero delimiter is only valid for `-z`).

### Unbounded loops / no recursion

`processInput` (L264): `while (true)` buffering all lines for negative
count. Bounded by EOF. Comment "Read all lines from the reader"
documents the exit condition; acceptable.

`streamOneLine` (L329): `while (true)` to handle `StreamTooLong`.
Bounded by the reader eventually delivering the delimiter or EOF. The
comment at L339 ("Line longer than read buffer; flush the buffered
prefix and keep looking") documents the retry intent. Acceptable, but
the loop should have a maximum-iteration assert if we ever care about
adversarial inputs.

### Error handling

`processInput` (L270, L272, L281, L283): OOM from `alloc.dupe` and
`all_lines.append` is caught with `catch return` (bare return of void),
silently truncating output without any diagnostic. Callers at L156,
L170, L196 use `try`, so they will propagate `!void` — but these OOM
paths return successfully (the error is lost). Fix:

```zig
const owned = try alloc.dupe(u8, remaining);
try all_lines.append(alloc, owned);
```

This lets OOM propagate to the caller which can print a diagnostic.

`processInput` (L256): `allocator orelse return` silently returns
without output when the allocator is null and negative count is
requested. This path can only be reached from tests that pass `null`
for the allocator and request negative count simultaneously — but it
produces no error. At minimum, `unreachable` (or `return error.NoAllocator`)
is more explicit than silent success.

### Variable scope

`line_count` and `negative_count` (L123–124 in `runHead`): declared
before the conditional block that sets them. Since they depend on
`parsed_args.lines`, they could be computed inline and passed directly
into `HeadOptions`, but the current form is clear enough.

### Comments

`processInput` (L249–251): "Streams data without reading the entire
input into memory (except for negative line counts which require
buffering the entire input)." Good — says why the exception exists.

`streamOneLine` (L324–327): documents both the goal and the
`StreamTooLong` handling strategy. Meets the Tiger Style "say how for
non-obvious logic" requirement.

---

## src/wc.zig

### Function-length violations (>70 lines)

- `runWc` (L123–231): **108 lines**. The largest function. It combines
  parsing, option defaulting, display-config resolution, style
  initialization, stdin dispatch, and per-file dispatch. The per-file
  loop (L182–222) is a natural extraction target:
  `processFiles(allocator, io, opts, files, stdout_writer,
  stderr_writer, style_inst, total_stats) !bool`. This would reduce
  `runWc` to ~50 lines.
- `countReader` (L237–344): **107 lines**. The hot path. The entire
  UTF-8 `-L` width computation (L267–309) could be extracted into
  `updateLineLength(byte, current_line_length, utf8_remaining,
  utf8_codepoint) u64` — a pure function that is easier to test and
  lets the compiler inline it. The remaining non-`-L` per-byte logic
  (char counting and word detection, L311–326) also reads as a
  separable concern.

### Line-length violations (>100 cols)

- L123: 140 cols — `runWc` signature. Add trailing comma.
- L125: 157 cols — `parseOrExit` call.
- L158: 186 cols — `printErrorWithProgram` for invalid color mode.
  Longest line in the file. Extract the format string to a constant.
- L193, L199, L206, L215: 118–139 cols — `printErrorWithProgram`
  calls in the per-file loop.
- L358: 127 cols — `printStats` signature. Add trailing comma.

### Assertions

Zero `std.debug.assert` calls. This is the most critical omission for a
hot counting loop. Missing:

- `countReader`: should assert `utf8_remaining <= 3` after every
  mutation (it is `u3` so the type already enforces this, but an
  explicit assertion documents the invariant for readers).
- `countReader`: should assert `stats.bytes >= stats.lines` (every line
  has at least one byte — the newline). This catches logic inversions.
- `addStats`: should assert `total.max_line_length >= stats.max_line_length`
  after the update (the max can only stay the same or grow).
- `printStats`: should assert at least one count flag is true before
  printing (printing zero columns with a newline would produce a blank
  line).

### Unbounded loops / no recursion

`countReader` (L246): `while (true)` bounded by `EndOfStream`. The
comment "Streams data in 8192-byte chunks" (L234) documents the
strategy but not the termination condition. Add: "Terminates when
`peekGreedy` returns `EndOfStream`."

### Error handling

`runWc` (L230): returns `if (has_error) @as(u8, 1) else 0` using a
raw integer literal `0` rather than `@intFromEnum(common.ExitCode.success)`.
The rest of the file and all other utilities use the enum. Inconsistent.

### Types and division

`wc.zig` has no bare `/` in production code — all integer division is
avoided by using bitwise tricks. The tab-stop rounding at L271:
```zig
current_line_length = (current_line_length + 8) & ~@as(u64, 7);
```
is correct and fast but the "why" is missing. Add a comment:
```zig
// Round up to next 8-column tab stop (equivalent to @divFloor(x+7, 8)*8).
```

### Performance

`countReader` processes bytes one at a time inside a `for (chunk)
|byte|` loop over the buffer returned by `peekGreedy`. This is the
intended pattern and avoids per-byte syscalls. No concern here.

The UTF-8 width computation (L267–309) is gated on `options.max_line_length`,
so it is skipped entirely in the common case. Good amortization.

The `std.ascii.isWhitespace(byte)` call on L320 inside the hot loop is
a library call for every byte. It could be replaced by a 256-entry
lookup table or a simple range check if profiling shows it is a
bottleneck — flag as a future optimization candidate.

### Comments

`countReader` (L233–235): "POSIX: lines are counted as the number of
newline characters (\n) / A file without a final newline has 0 lines"
— factually incorrect: a file with content but no trailing newline has
0 lines by POSIX. The comment should say "zero complete lines" to
avoid confusion with `wc -l` output for "hello\nworld" (which is 1).

---

## Summary

| Category | Count |
|---|---|
| Function-length | 7 |
| Line-length | 49 (concentrated in signatures and call sites) |
| Assertion gaps | 5 files × 0 assertions = systemic absence |
| Recursion/unbounded loops | 5 (all bounded by EOF; none documented) |
| Error handling | 6 |
| Naming | 0 |
| Variable scope | 1 (minor) |
| Comments | 5 |
| Types/division | 2 (missing intent comment on tab-stop; raw 0 vs enum) |
| Performance | 1 (future candidate only) |

**Overall impression**: The codebase is functionally solid with good
test coverage and correct stream-processing idioms, but it has a
systemic absence of runtime assertions across all five files — zero
`std.debug.assert` calls in ~4858 lines of production code. Line
lengths consistently exceed the 100-column limit in function signatures
and error-message call sites, which is addressable by adding trailing
commas and extracting long string constants. The most structurally
urgent fixes are the OOM-swallowing `catch return` in `head.zig`
`processInput`, the error-discarding `|_|` catch in `readlink.zig`
`resolveCanonicalMissingOk`, and the two oversized functions
`runUniq` (129 lines) and `runWc` / `countReader` (107–108 lines each).
