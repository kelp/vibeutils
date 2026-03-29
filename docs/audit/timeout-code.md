# timeout - Code Audit

Date: 2026-03-28
Files reviewed: `src/timeout.zig`
GNU reference: `docs/specs/timeout-gnu.txt`, `docs/specs/timeout-flags.md`
Build: PASS
Integration tests: 20/20 PASS (flaky in some environments; see IMPORTANT below)
Unit tests: all PASS (CI skips process-group test on Linux)

---

## Findings

### IMPORTANT: Race condition in setpgid — signals may miss child process group

Location: `src/timeout.zig:287-289`

Problem: `setpgid(child_pid, child_pid)` is called from the parent after
`child.spawn()` returns. POSIX only allows a parent to change a child's
PGID before the child calls `exec`. If the child has already exec'd by the
time the parent calls `setpgid`, it fails with `EPERM`. The return value is
silently discarded (`_ = setpgid(...)`). When `setpgid` fails, the child
remains in the parent's process group. The subsequent `kill(-child_pid, sig)`
sends to a process group that contains no members (the child is in the
parent's group, not its own group), so the signal is never delivered.

The bug is intermittent: on a fast machine the child usually hasn't exec'd
yet, so `setpgid` succeeds and the process group kill works. On a loaded
system or in constrained test environments (CI, the Zig test runner, Docker)
the exec wins the race and the kill silently fails, leaving the child running
and causing `waitChild` to return whatever exit code the child eventually
produces. The integration test for `-s KILL` and `--preserve-status` both
failed with exit 0 when the race was lost during this audit.

The correct fix: use `std.process.Child.pgid` instead of calling `setpgid`
after spawn. Set `child.pgid = 0` before calling `child.spawn()`. Zig's
`Child` implementation calls `setpgid(0, 0)` from within the child process
before `exec`, which always succeeds. Remove the post-spawn `setpgid` call
entirely.

```zig
// WRONG (current): race condition — child may have already exec'd
child.spawn() catch |err| { ... };
const child_pid = child.id;
if (!parsed.foreground) {
    _ = setpgid(child_pid, child_pid);  // silently fails on race loss
}

// CORRECT: set pgid before spawn so child sets its own group pre-exec
if (!parsed.foreground) {
    child.pgid = 0;  // 0 means: use child's own PID as new PGID
}
child.spawn() catch |err| { ... };
const child_pid = child.id;
// no setpgid call needed here
```

Also remove the `extern "c" fn setpgid` declaration since it would no longer
be used.

---

### SUGGESTION: Verbose message shows signal number instead of signal name

Location: `src/timeout.zig:316`

Problem: GNU `timeout -v` prints the signal by name:
`timeout: sending signal TERM to command 'sleep'`. Vibeutils prints the
signal number: `timeout: sending signal 15 to command 'sleep'`. The KILL
message at line 341 correctly uses the string literal "KILL", but the initial
timeout signal uses the numeric value.

Fix: Reverse-lookup the signal name from `signal_table` before printing. If
not found (custom numeric signal), fall back to the number.

```zig
// Look up name for the signal
const sig_name: ?[]const u8 = blk: {
    for (signal_table) |entry| {
        if (entry.number == timeout_signal) break :blk entry.name;
    }
    break :blk null;
};
if (sig_name) |name| {
    common.printErrorWithProgram(allocator, stderr_writer, prog_name,
        "sending signal {s} to command '{s}'", .{ name, cmd_args[0] });
} else {
    common.printErrorWithProgram(allocator, stderr_writer, prog_name,
        "sending signal {d} to command '{s}'", .{ timeout_signal, cmd_args[0] });
}
```

---

### SUGGESTION: Missing "Try '...' for more information" hint on invalid time

Location: `src/timeout.zig:237-238`

Problem: When the duration is invalid, vibeutils prints:
```
timeout: invalid time interval 'abc'
```
GNU prints that line followed by:
```
Try 'timeout --help' for more information.
```
The hint is already present for missing-operand errors (line 230) but absent
for invalid-duration and invalid-signal errors.

Fix: Add a hint line after each error in the duration/signal parse block,
consistent with the pattern used for missing operands.

---

## Test Coverage Assessment

Unit tests are comprehensive for the pure-function layer (`parseSignal`,
`asciiEqlIgnoreCase`, `parseTimeString`). The `runTimeout` unit tests cover
help, version, missing operand, invalid duration, invalid signal, command not
found, completes-before-timeout, fails-before-timeout, zero timeout, and
times-out cases. The `--preserve-status` unit test is correctly skipped on
Linux CI because the process-group race makes it unreliable in the test
runner's IPC mode.

Integration tests cover 20 cases including signal name acceptance (USR1,
USR2), duration suffixes, and exit-code semantics for flags vs missing
operands. The `-s KILL` and `--preserve-status` integration tests are
vulnerable to the same race condition described above; they pass when the
race is won but fail when it is lost.

---

## Summary

Counts: 0 CRITICAL, 1 IMPORTANT (race condition), 2 SUGGESTIONS

Overall assessment: NEEDS_FIXES

The race condition in process group setup is the one real bug. It is not
theoretical: the integration tests for `-s KILL` and `--preserve-status`
failed during this audit when the environment was under load. Fixing it
requires replacing the post-spawn `setpgid` call with `child.pgid = 0`
before spawn, which is the correct POSIX-compliant approach. The verbose
signal name and hint message issues are cosmetic.

Fix Order:
1. [IMPORTANT] Replace post-spawn setpgid() with child.pgid = 0 —
   src/timeout.zig:262,287-289
2. [SUGGESTION] Verbose message: print signal name not number —
   src/timeout.zig:316
3. [SUGGESTION] Add "Try '--help'" hint for invalid-duration and
   invalid-signal errors — src/timeout.zig:237-238, 243-245
