---
description: TDD workflow for implementing a new vibeutils utility
disable-model-invocation: true
---

# /new-util <utility-name>

Implement a new coreutils utility using strict TDD. The argument
is the utility name (e.g., `/new-util sort`).

## Before You Start

1. Read `docs/ZIG_BREAKING_CHANGES.md` -- your Zig training is
   outdated (covers 0.15.x)
2. Read `docs/TESTING_STRATEGY.md` -- especially the filter
   utility section
3. Read the template at
   `.claude/skills/new-util/references/template.md`

## Phase 1: Research & Design

Use the **architect agent** for this phase.

1. **Classify the utility:**
   - Filter (reads stdin): cat, sort, uniq, tr, cut, nl, tac,
     head, tail, wc, tee
   - File operation: cp, mv, rm, mkdir, rmdir, touch, chmod,
     chown, ln
   - Generator: echo, yes, true, false, sleep
   - Info/query: ls, pwd, dirname, basename, test

2. **Fetch reference specs** (use WebFetch):
   - POSIX:
     `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/$UTILITY.html`
   - OpenBSD: `https://man.openbsd.org/$UTILITY`
   - GNU:
     `https://www.gnu.org/software/coreutils/manual/html_node/$UTILITY-invocation.html`

3. **Design the flag set:**
   - Start with POSIX-required flags
   - Add commonly used GNU extensions
   - Include OpenBSD safety features where applicable
   - Always include `--help` (-h) and `--version` (-V)

4. **Document the design** in a brief summary before proceeding.

## Phase 2: Scaffold

Use the **programmer agent** for phases 2-4.

5. **Create `src/<utility>.zig`** using the template from
   `.claude/skills/new-util/references/template.md`. Include:
   - Imports (std, common)
   - Args struct with meta
   - Stub `run<Utility>` returning success
   - `main()` with buffered I/O setup
   - `printHelp` and `printVersion` functions
   - For filter utilities: add `runUtilWithInput` pattern

6. **Add to `build/utils.zig`:**
   ```zig
   .{ .name = "<utility>", .path = "src/<utility>.zig",
      .needs_libc = true, .description = "<description>" },
   ```

7. **Verify scaffold:**
   ```bash
   make build UTIL=<utility>
   zig-out/bin/<utility> --help
   ```

## Phase 3: TDD Implementation

Repeat this cycle for each feature/flag:

8. **Red:** Write a failing test for the next feature.
9. **Green:** Implement minimal code to pass the test.
10. **Refactor:** Clean up if needed, keeping it simple.
11. **Verify:** Run `zig build test` after each cycle.

### Filter utility rules:
- Use `appendRemaining` to read input, NOT
  `takeDelimiterExclusive` loops
- Skip stdin-dependent unit tests (they hang)
- Test via `runUtilWithInput()` with file-backed input
- Add integration smoke tests

### Test patterns:
```zig
test "<utility>: basic functionality" {
    const allocator = testing.allocator;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run<Utility>(
        allocator,
        &.{"--flag"},
        stdout_writer.writer(),
        stderr_writer.writer(),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    const output = stdout_buf[0..stdout_writer.pos];
    try testing.expectEqualStrings("expected output", output);
}
```

## Phase 4: Polish

12. **Edge cases:** Add tests for error handling, empty input,
    large input, invalid flags.

13. **Man page:** Create `man/man1/<utility>.1` in mdoc format.
    Required sections: NAME, SYNOPSIS, DESCRIPTION, EXIT STATUS,
    EXAMPLES, SEE ALSO, STANDARDS, AUTHORS.
    No HISTORY section. Validate: `mandoc -T lint`.

14. **Run `/zig-check`** to audit for Zig 0.15 correctness.

15. **Coverage:** Run `make coverage` targeting 90%+.

16. **Final verification:**
    ```bash
    zig build test
    make test UTIL=<utility>
    ```

## Checklist

Before declaring done, verify:
- [ ] All tests pass (`zig build test`)
- [ ] No test hangs (`timeout 60 zig build test`)
- [ ] Man page validates (`mandoc -T lint man/man1/<utility>.1`)
- [ ] Coverage >= 90% for new code
- [ ] `/zig-check src/<utility>.zig` passes
- [ ] Added to `build/utils.zig`
- [ ] Error messages use `printErrorWithProgram`
- [ ] Exit codes: `misuse` for arg errors, `general_error` for
  runtime failures
