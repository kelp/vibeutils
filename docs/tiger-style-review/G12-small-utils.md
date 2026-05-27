# Tiger Style Audit: G12 Small Utilities

**Files reviewed**: realpath.zig, cat.zig, timeout.zig, mktemp.zig, mkdir.zig,
tac.zig, echo.zig, rmdir.zig, tee.zig, basename.zig, yes.zig, sleep.zig,
integration_tests.zig

---

## realpath.zig

### Function Length

`processPath` (lines 113–224): 111 lines — exceeds the 70-line limit. The
function repeats an identical `catch |err| { if (!opts.quiet) { printError... }
return false; }` pattern four times. Extract a `printPathError` helper to
eliminate the duplication and bring this under limit.

### Line Length

48 lines exceed 100 columns. All are `common.printErrorWithProgram(...)` call
sites and the `runRealpath` signature at line 227.

### Assertion Gaps

Zero `std.debug.assert` calls in the file. `resolveLogical` and `processPath`
have no precondition checks on the input path or options fields.

### Error Handling

Test at line 468: `_ = result;` — the test makes no assertion on the return
value of the function under test, so a regression could go undetected.

### Comments

The repeated error-handling branches in `processPath` have no comment
explaining why the same pattern appears four times rather than a shared helper.

---

## cat.zig

### Function Length

`runCat` (lines 69–148): 79 lines — exceeds the 70-line limit by 9 lines.

### Line Length

48 lines exceed 100 columns.

### Assertion Gaps

Zero assertions. `processInput` dispatches on `opts` but asserts nothing about
the options struct invariants (e.g., that `show_ends` and `show_tabs` are not
both active in a mode that forbids it).

### Unbounded Loops

Two `while (true)` loops at lines 226 and 243. Neither has a non-termination
assertion (e.g., `assert(false) // loop exits only on error or EOF`). Tiger
Style requires asserting intent when a loop is deliberately infinite.

### Types / Division

`LineNumberState.line_number: usize` (line 209). Line numbers are bounded by
the file size, which fits in `u32` on any sane input. Use `u32` to signal
intent.

---

## timeout.zig

### Function Length

`runTimeout` (lines 287–436): 149 lines — more than double the 70-line limit.
Candidate extractions: signal-setup block, the two poll-wait loops, and the
child-exit-code assembly.

### Line Length

39 lines exceed 100 columns.

### Assertion Gaps

Zero assertions. The signal mask setup and `sigaction` configuration have no
postcondition checks.

### Error Handling

Lines 413–417 — dead conditional branch:

```zig
const kill_exit = waitChild(child_pid);
if (parsed.@"preserve-status") {
    return kill_exit;
}
return kill_exit;
```

Both arms return the same value. `preserve-status` should change the exit code
to `128 + signal` when false; instead the flag has no effect. This is a logic
bug, not just a style issue.

### Comments

The two polling loops (lines 366–377, 390–403) have no comment stating the
bound that guarantees termination.

---

## mktemp.zig

### Function Length

`run` (lines 76–197): 121 lines — well over the 70-line limit. The function
repeats a `catch { if (!quiet) { printError... } return err_code }` pattern
approximately six times. Extract a `reportMktempError` helper.

### Line Length

28 lines exceed 100 columns.

### Assertion Gaps

Zero assertions. `findTemplateXs` and `generateTemp` have no precondition
checks on minimum template length or X count.

### Types / Division

`fillRandom` at line 338: `alphanumeric[byte % alphanumeric.len]` — modulo
bias. `alphanumeric.len` is 62; `256 % 62 = 8`, so characters 0–7 appear
roughly 0.4% more often than characters 8–61. Negligible for temp filenames
but worth noting.

---

## mkdir.zig

### Line Length

17 lines exceed 100 columns.

### Assertion Gaps

Zero assertions.

### Naming / Function Shape

`setDirectoryMode` (lines 128–148) takes six parameters:
`allocator, io, path, mode, prog_name, stderr_writer`. `createPathComponents`
takes seven. Tiger Style's inverse-hourglass principle calls for fewer
parameters; bundle the shared context (`allocator, io, prog_name,
stderr_writer`) into a small options struct.

---

## tac.zig

### Line Length

15 lines exceed 100 columns.

### Assertion Gaps

Zero assertions.

### Error Handling

`runTacOnInput` line 100: `_ = stderr_writer` discards the parameter. Read
errors from `readSliceShort` reach the `general_error` return path with no
diagnostic written to stderr. Either use `stderr_writer` to print the error or
remove the parameter from the signature.

### Static Memory

`runTacOnInput` reads the entire input file into an `ArrayListUnmanaged` with
no size cap. This is intentional for correctness (tac must reverse), but it
violates the static memory rule. A comment explaining the tradeoff would
satisfy Tiger Style's "always say why" requirement.

---

## echo.zig

### Function Length

`writeWithEscapes` (lines 154–263): 109 lines — well over the 70-line limit.
The function is a `while` loop over a large `switch` with 12 cases. Extract
the numeric escape parsers (`\0NNN`, `\xHH`) into helpers.

### Line Length

3 lines exceed 100 columns — minimal.

### Assertion Gaps

Zero assertions.

---

## rmdir.zig

### Line Length

25 lines exceed 100 columns, mostly function signatures.

### Assertion Gaps

Zero assertions. The `ParentIterator` has no assertion that it stops before
producing an empty path.

### Comments

Overall the file is clean and well-structured. The `ParentIterator` logic would
benefit from a one-line comment explaining why it stops at `.` and root.

---

## tee.zig

### Function Length

`runTeeWithInput` (lines 72–168): 96 lines — exceeds the 70-line limit.

### Line Length

16 lines exceed 100 columns.

### Assertion Gaps

Zero assertions.

### Error Handling

`MultiWriter.deinit` line 239: `fe.writer.interface.flush() catch {}` — silent
flush error drop. Flush errors in the destructor are discarded while the same
flush errors on the same writers are properly reported during the write loop
(lines 161–164). The inconsistency means a partial write on close goes
unreported.

---

## basename.zig

### Line Length

32 lines exceed 100 columns (mostly in test call sites).

### Assertion Gaps

Zero assertions.

### Comments

Overall the file is well-factored and clean. No significant issues.

---

## yes.zig

### Function Length

`runYes` (lines 21–110): 89 lines — exceeds the 70-line limit.

### Line Length

14 lines exceed 100 columns.

### Assertion Gaps

Zero assertions.

### Unbounded Loops

Two `while (true)` loops at lines 86 and 103. Both are intentionally infinite
(yes runs until the pipe breaks). Neither has a non-termination assertion.

---

## sleep.zig

### Line Length

33 lines exceed 100 columns.

### Assertion Gaps

Zero assertions. `parseTotalTime` has no precondition check that the input
slice is non-empty before indexing.

### Comments

`std.Io.sleep(io, duration, .awake) catch {}` at line 145 — the silent catch
is reasonable (EINTR from SIGALRM is expected), but a comment stating why the
error is intentionally ignored would satisfy Tiger Style's "always say why"
rule.

---

## integration_tests.zig

### Assertion Gaps

Zero assertions.

### Error Handling

`runUtilityTest` lines 33–36: stdin-dependent tests unconditionally return
`error.SkipZigTest` with a TODO comment. These tests are permanently dead and
contribute nothing to coverage.

### Types / Division

`benchmarkUtility` line 318: `total_ns / iterations` — bare division. Use
`@divTrunc(total_ns, iterations)` per Tiger Style.

### API Currency

Multiple functions use pre-0.16 file I/O APIs that lack the required `io`
parameter:
- `file.close()` — should be `file.close(io)`
- `file.writeAll(content)` — should be `file.writeAll(io, content)`
- `dst_file.read(&buffer)` — should be `dst_file.read(io, &buffer)`
- `tmp_dir.dir.realpath(".", &path_buf)` — should pass `io`

These will fail to compile against the pinned 0.16 toolchain if the functions
are ever called from a non-test context, or may already cause build warnings.

### Static Memory

`benchmarkUtility` casts `std.time.nanoTimestamp()` (returns `i128`) to `u64`
via `@intCast`. For benchmark durations this is safe, but the assumption is
implicit; a comment or `assert(ts >= 0)` would make the invariant explicit.

---

## Summary

| File | Fn >70L | Lines >100 | Asserts | Unbounded | Errors | Notes |
|---|---|---|---|---|---|---|
| realpath.zig | 1 (111L) | 48 | 0 | — | test no-assert | dead test, repeated catch pattern |
| cat.zig | 1 (79L) | 48 | 0 | 2 | — | usize line_number |
| timeout.zig | 1 (149L) | 39 | 0 | — | dead branch | preserve-status bug |
| mktemp.zig | 1 (121L) | 28 | 0 | — | — | modulo bias in fillRandom |
| mkdir.zig | — | 17 | 0 | — | — | 6–7 param functions |
| tac.zig | — | 15 | 0 | — | silent read err | unbounded heap read |
| echo.zig | 1 (109L) | 3 | 0 | — | — | |
| rmdir.zig | — | 25 | 0 | — | — | clean overall |
| tee.zig | 1 (96L) | 16 | 0 | — | silent flush | deinit drops errors |
| basename.zig | — | 32 | 0 | — | — | clean overall |
| yes.zig | 1 (89L) | 14 | 0 | 2 | — | |
| sleep.zig | — | 33 | 0 | — | — | undocumented catch |
| integration_tests.zig | — | — | 0 | — | skipped tests | stale 0.16 API, bare division |

**Totals**: 6 functions over 70 lines · 1 logic bug (timeout.zig) · 0 assertions
across all 13 files · 3 silent error drops (tac, tee, integration_tests) ·
2 permanently-skipped test blocks · 1 stale API block (integration_tests.zig)

**Cross-cutting**: Zero `std.debug.assert` calls across all 12 production files
is the single largest Tiger Style gap. Every function currently has 0
assertions; Tiger Style targets a minimum average of 2 per function.
