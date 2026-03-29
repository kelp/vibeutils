# mktemp Code Audit

**Date:** 2026-03-28
**Reference:** GNU coreutils 9.10 (primary)
**Build:** passes `just build-util mktemp`
**Integration tests:** 24/24 pass (`just it-util mktemp`)
**Assessment:** NEEDS_FIXES

---

## Findings

### [CRITICAL] Bare template (user-supplied, no slash) always routed to /tmp instead of cwd

**Location:** `src/mktemp.zig:208` (`resolveTmpdir`)

**Problem:** GNU's rule is:
- No TEMPLATE given → default `tmp.XXXXXXXXXX` → `--tmpdir` is implied → use
  `$TMPDIR` or `/tmp`.
- TEMPLATE given with no directory component (bare name) → use cwd.
- TEMPLATE given with a path component → use that directory.
- `-t` flag → force use of `$TMPDIR` or `/tmp` regardless.

The code conflates the first two cases. The condition
`std.fs.path.dirname(template) == null` is true for both the default template
and a user-supplied bare template, so both always land in `$TMPDIR`/`/tmp`.
A user-supplied bare template should be created relative to cwd.

Observed:
```
# GNU
$ cd /tmp && mktemp myapp.XXXXXX
myapp.8c92Qo          # created in cwd

# Ours
$ cd /tmp && mktemp myapp.XXXXXX
/tmp/myapp.73rl8o     # incorrectly routed to /tmp
```

**Fix:** Pass a boolean indicating whether the template is the built-in
default into `resolveTmpdir`. Only redirect bare names to `$TMPDIR`/`/tmp`
when the template is the default (i.e., no template was supplied by the
user).

```zig
fn resolveTmpdir(
    allocator: Allocator,
    tmpdir_arg: ?[]const u8,
    t_flag: bool,
    template: []const u8,
    is_default_template: bool,  // true when no TEMPLATE arg was given
) ![]const u8 {
    if (tmpdir_arg) |dir| return try allocator.dupe(u8, dir);

    // GNU implies --tmpdir for the default template; -t also forces it.
    if (t_flag or is_default_template or std.fs.path.dirname(template) != null) {
        if (t_flag or is_default_template) {
            if (std.posix.getenv("TMPDIR")) |v| return try allocator.dupe(u8, v);
            return try allocator.dupe(u8, "/tmp");
        }
    }

    // User-supplied bare template: use cwd (return ".")
    if (std.fs.path.dirname(template)) |dir| return try allocator.dupe(u8, dir);
    return try allocator.dupe(u8, ".");
}
```

---

### [CRITICAL] `-t` with a template containing a slash silently uses the basename instead of failing

**Location:** `src/mktemp.zig:139` (`resolveTmpdir` call) and `src/mktemp.zig:147`

**Problem:** GNU rejects any template containing a directory separator when
`-t` is active:

```
$ mktemp -t mydir/XXXXXX
mktemp: invalid template, 'mydir/XXXXXX', contains directory separator
```

The code extracts the basename (`template_basename`) and uses that silently,
producing a file in `$TMPDIR` with no error.

**Fix:** Before the `resolveTmpdir` call, when `parsed.t` is true, check
whether `raw_template` contains `/`. If it does, emit an error (unless `-q`)
and return `general_error`:

```zig
if (parsed.t and std.mem.indexOfScalar(u8, raw_template, '/') != null) {
    if (!parsed.quiet) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name,
            "invalid template, '{s}', contains directory separator",
            .{raw_template});
    }
    return @intFromEnum(common.ExitCode.general_error);
}
```

---

### [CRITICAL] Implicit suffix not recognized: templates with X's not at the trailing position fail

**Location:** `src/mktemp.zig:130-136` (`countTrailingXs` + validation)

**Problem:** GNU treats trailing non-X characters after a run of X's as an
implicit `--suffix`. The file is created with those characters as a fixed
suffix after the randomized portion:

```
$ mktemp myapp.XXXXXXtxt
myapp.eRQowrtxt      # GNU succeeds

$ mktemp myapp.XXXXXXtxt
mktemp: too few X's in template 'myapp.XXXXXXtxt'  # ours fails
```

The existing `--suffix` machinery already handles a suffix correctly.
The code just needs to detect this case during template parsing and split the
template into `[base_with_Xs][implicit_suffix]` before the X-count check.

**Fix:** After extracting `raw_template`, locate the last run of X's. If the
template ends with non-X characters following those X's, treat the trailing
non-X portion as the implicit suffix (merge it into `suffix`). Only fail if
no run of at least 3 X's exists anywhere in the basename.

---

### [IMPORTANT] `--tmpdir` long option rejects the no-argument form that GNU accepts

**Location:** `src/mktemp.zig:82-98` (arg parsing), `MktempArgs.tmpdir`
definition

**Problem:** GNU defines `--tmpdir` with an optional argument (`[=DIR]`). When
given without a value (`--tmpdir` alone or `--tmpdir TEMPLATE`), GNU treats it
as "use `$TMPDIR` or `/tmp`" and takes the next positional as the template.
Our argparse treats `--tmpdir` as a required-value option and returns
`error.MissingValue`:

```
$ mktemp --tmpdir myfile.XXXXXX
GNU: /tmp/myfile.hyUutU
Ours: mktemp: option requires an argument
```

```
$ mktemp --tmpdir
GNU: /tmp/tmp.CrxjCGgc9T
Ours: mktemp: option requires an argument
```

**Fix:** If the argparse module supports optional long-option values, change
`tmpdir` to allow an optional value. When no value is provided, behave as if
`-t` were set (use `$TMPDIR` or `/tmp`).

---

### [IMPORTANT] `fillRandom` leaves X positions uninitialized when template exceeds 256 X's

**Location:** `src/mktemp.zig:291-309` (`fillRandom`)

**Problem:** `random_bytes` is 256 bytes. `needed = @min(buf.len, 256)`.
The loop iterates over the full `buf.len` but only assigns `b.*` when
`i < needed`. When `buf.len > 256`, positions `[256..buf.len)` are never
written; the loop guard `if (i < needed)` skips them. The `candidate` buffer
was allocated with the arena allocator, which returns undefined memory. Those
positions will contain whatever was in the allocation, not random data.

This is not exploitable in practice (256 X's is already absurd), but it is a
logic error. In Zig, the `if` branch could simply be removed: either fill
random_bytes in chunks or use the PRNG fallback for the overflow range.

**Fix:**

```zig
fn fillRandom(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        var chunk: [256]u8 = undefined;
        const n = @min(buf.len - i, chunk.len);
        std.posix.getrandom(chunk[0..n]) catch {
            var prng = std.Random.DefaultPrng.init(
                @as(u64, @intCast(@max(0, std.time.timestamp()))));
            const rng = prng.random();
            for (buf[i..]) |*b|
                b.* = alphanumeric[rng.intRangeAtMost(u8, 0, alphanumeric.len - 1)];
            return;
        };
        for (chunk[0..n], 0..) |byte, j| buf[i + j] = alphanumeric[byte % alphanumeric.len];
        i += n;
    }
}
```

---

### [IMPORTANT] Modulo bias in `fillRandom` produces slightly non-uniform distribution

**Location:** `src/mktemp.zig:304`

**Problem:** `alphanumeric[random_bytes[i] % alphanumeric.len]` has modulo
bias. `alphanumeric.len` is 62. `256 % 62 = 8`, so the first 8 characters
(`A`–`H`) appear with probability `5/256` while the remaining 54 appear with
`4/256`. For a temporary-file name this bias is not a security concern, but
it is a correctness note. GNU uses the same approach (libc `mkstemps`), so
this is consistent behavior — log as a suggestion rather than a required fix.

---

### [SUGGESTION] Integration tests do not cover the behavioral divergences found in this audit

**Location:** `tests/utilities/mktemp_test.sh`

**Problem:** No test verifies:
- A user-supplied bare template creates the file in cwd (not `/tmp`).
- `-t` with a slash in the template is rejected with an error.
- A template with X's not at the trailing position (implicit suffix) succeeds.
- `--tmpdir` with no value uses `$TMPDIR`/`/tmp`.

All 24 existing tests pass because they either use flags (`-p`, `-t`) or the
default template, which happen to work correctly.

**Fix:** Add integration test cases for each scenario listed above after the
code bugs are fixed.

---

### [SUGGESTION] Unit test `mktemp generateTemp creates unique names` is probabilistic

**Location:** `src/mktemp.zig:622-636`

**Problem:** The test generates two names in dry-run mode and verifies their
length, but only implicitly checks randomness (no assertion that `path1 !=
path2`). The actual assertion is missing — the test could pass even if both
names were identical. Since the test uses `getrandom`, collision probability
is negligible, but the assertion gap is real.

**Fix:**

```zig
try testing.expect(!std.mem.eql(u8, path1, path2));
```

---

## Coverage Summary

| Aspect | Status |
|--------|--------|
| Default template (no args) | Correct |
| `-d` directory creation | Correct |
| `-u` dry-run | Correct |
| `-q` quiet mode | Correct |
| `-p DIR` / `--tmpdir=DIR` | Correct |
| `-t` (bare template) | Correct |
| `-t` (template with slash) | WRONG — silent, should error |
| `--tmpdir` (no value) | WRONG — errors, should use $TMPDIR |
| Bare user-supplied template | WRONG — goes to /tmp, should use cwd |
| Implicit suffix (X's mid-template) | WRONG — errors, should succeed |
| `--suffix` validation | Correct |
| File permissions (0600/0700) | Correct |
| Uniqueness / retry loop | Correct |
| Error messages | Correct format |
| Exit codes | Correct |

---

## Fix Order

```
Fix Order:
1. [CRITICAL] Bare template uses /tmp instead of cwd — src/mktemp.zig:208
2. [CRITICAL] -t with slash template should error — src/mktemp.zig:139
3. [CRITICAL] Implicit suffix not recognized — src/mktemp.zig:130-136
4. [IMPORTANT] --tmpdir must accept optional value — src/mktemp.zig:29, 82
5. [IMPORTANT] fillRandom leaves positions uninitialized beyond 256 bytes — src/mktemp.zig:293
6. [SUGGESTION] Add integration tests for corrected behaviors
7. [SUGGESTION] Add non-equality assertion to generateTemp uniqueness test — src/mktemp.zig:622
```

REVIEW COMPLETE - NEEDS_FIXES
