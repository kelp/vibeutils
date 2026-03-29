# df Code Audit

**Date:** 2026-03-28
**File:** `src/df.zig`
**Build:** passes (`just build-util df`)
**Unit tests:** 1783/1802 pass (all df tests pass)
**Integration tests:** 13/13 pass

> **Re-audited 2026-03-28**: Corrected from macOS-primary
> to GNU-primary behavioral reference per project spec.
> GNU coreutils is the primary reference for all flags
> present in GNU. macOS/OpenBSD semantics apply only to
> flags absent from GNU.

---

## Reclassifications from Previous Audit

| Old Finding | Old Verdict | Reclassification |
|-------------|-------------|------------------|
| CRITICAL-4: -T wrong meaning | CRITICAL | **CLOSED** — GNU -T is print-type boolean; our code is correct |
| IMPORTANT-2: -t/-T comma-sep/no-prefix | IMPORTANT | **RECLASSIFIED** — macOS-only behavior; replaced by GNU -t multi-flag bug |
| SUGGESTION: default block size vs macOS | SUGGESTION | **RECLASSIFIED** — GNU defaults to 1024 when no flag given; our `human_readable=true` default is still a deliberate deviation, but from GNU not macOS |

---

## Flag-by-Flag Verdict

| Flag | Tier | Ref | Verdict | Notes |
|------|------|-----|---------|-------|
| -a | SHOULD | GNU+macOS | PASS | Shows pseudo filesystems |
| -b | SHOULD | macOS | PASS | 512-byte blocks |
| -c | SHOULD | macOS | PASS | Grand total (alias for --total) |
| -g | SHOULD | macOS | PASS | 1G-blocks |
| -h | MUST | GNU+macOS | PASS | Human-readable sizes (default) |
| -H | SHOULD | GNU+macOS | PASS | SI powers-of-1000 |
| -i | MUST | GNU+macOS | PASS | Inode mode |
| -I | SHOULD | macOS-only | FAIL | See CRITICAL-1 |
| -k | MUST | GNU+macOS | PASS | 1024-byte blocks |
| -l | MUST | GNU+macOS | PASS | Local only |
| -m | SHOULD | macOS | PASS | 1M-blocks |
| -n | MUST | macOS+OpenBSD-only | FAIL | See CRITICAL-2 |
| -P | MUST | POSIX+GNU | FAIL | See CRITICAL-3 |
| -t | MUST | GNU+macOS | FAIL | See IMPORTANT-1 |
| -T | SHOULD | GNU+macOS | PASS | Print-type column — correct GNU behavior |
| -x | SHOULD | GNU | PASS | Type exclude filter |
| -Y | SHOULD | macOS-only | FAIL | See CRITICAL-4 |
| -, | SHOULD | macOS | PASS | Thousands grouping |
| --block-size | SHOULD | GNU | PASS | Custom block size |
| --output | SHOULD | GNU | FAIL | See IMPORTANT-2 |
| --total | SHOULD | GNU | PASS | Grand total |

---

## Findings

### [CRITICAL] -I flag wrong: treats macOS suppress-inode as
exclude-type
Location: `src/df.zig:300-313`
Problem: `-I` is macOS-only (absent from GNU). macOS `-I`
suppresses inode count display — it is a boolean toggle.
The code at line 300 instead treats `-I` identically to
`-x`, as an exclude-type filter that requires a TYPE
argument. Running `df -I` prints "option '-I' requires an
argument" when it should produce output with inodes
suppressed.
```
# Actual:
$ df -I
df: option '-I' requires an argument

# Expected (macOS):
$ df -I
Filesystem   1K-blocks  Used  Available  Use%  Mounted on
...  (no inode columns)
```
Fix: Change the `-I` branch to set `opts.inodes = false`
(or add a `suppress_inodes: bool` field). Do not require
an argument.

---

### [CRITICAL] -n is a stub: parsed but does not change
behavior
Location: `src/df.zig:253`, `src/df.zig:359,368`
Problem: `-n` is macOS+OpenBSD-only (absent from GNU). On
macOS it controls whether `getfsstat` uses `MNT_WAIT` or
`MNT_NOWAIT`. The field `no_sync` is set to `true` when
`-n` is passed, but both `getfsstat` calls at lines 359
and 368 unconditionally pass `MNT_NOWAIT`. The flag has
zero effect on output or behavior.

Additionally, GNU df on Linux has no `-n` flag and our
implementation silently accepts it as a no-op rather than
printing an error. The field name `no_sync` is also
misleading — macOS `-n` is about using cached stats, not
skipping a sync call (that is a separate GNU concept
covered by `--no-sync`/`--sync`, which are WONT in this
project).

Fix: On Darwin, pass `MNT_WAIT` (value 1) when `-n` is
NOT set, and `MNT_NOWAIT` (value 2) when `-n` IS set. On
Linux, reject `-n` with an invalid-option error and exit 2
to match GNU df behavior. Rename `no_sync` to
`use_cached_stats` for clarity.

---

### [CRITICAL] -P POSIX output format uses wrong column
headers
Location: `src/df.zig:1336-1394` (printHeader),
`src/df.zig:1384`
Problem: POSIX and GNU df both require specific column
header names in portability mode (-P). Our output does not
match:

| Column | Required (POSIX/GNU) | Ours |
|--------|---------------------|------|
| Block col | `1024-blocks` | `1K-blocks` |
| Space col | `Available` | `Avail` |
| Pct col | `Capacity` | `Use%` |

Verified against `/usr/bin/df -P /`:
```
# System df -P:
Filesystem     1024-blocks     Used Available Capacity Mounted on
/dev/vda1        164923768 28978660 129193152      19% /

# Our df -P:
Filesystem  1K-blocks      Used      Avail  Use%  Mounted on
/dev/vda1   164923768  28978660  129192500   19%  /
```
Scripts or tools that parse POSIX df output will break on
the wrong column names. This is a compliance failure for a
MUST-tier flag present in both POSIX and GNU.

Fix: In `printHeader`, when `opts.portability` is true,
use `"1024-blocks"`, `"Available"`, and `"Capacity"` as
headers instead of `"1K-blocks"`, `"Avail"`, and `"Use%"`.
Apply the same fix to `printHeaderDynamic` if called in
portability mode.

---

### [CRITICAL] -Y is a no-op stub: should add Type column
(macOS)
Location: `src/df.zig:318`
Problem: `-Y` is macOS-only (absent from GNU). macOS `-Y`
means "Include file system type" — it adds a Type column
to the output. The code at line 318 is a complete no-op
with a comment "don't resolve NFS paths" which is
incorrect (that is not what `-Y` does). The flags table
marks `-Y` as SHOULD with `Ours: yes`, but the
implementation is empty.
```zig
'Y' => {}, // no-op: don't resolve NFS paths
```
Note: The print-type column behavior (`opts.print_type =
true`) is already wired correctly through `-T` (the GNU
flag). `-Y` should activate the same output path.

Fix: Set `opts.print_type = true` in the `-Y` branch.
Remove the incorrect comment.

---

### [IMPORTANT] -t type filter silently drops all but the
last repeated flag (GNU incompatibility)
Location: `src/df.zig:101`, `src/df.zig:263-275`,
`src/df.zig:618-621`
Problem: GNU df supports repeated `-t` and `-x` flags to
specify multiple types: `df -t ext4 -t vfat`. Our
`DfOptions` uses a single `?[]const u8` field for both
`include_type` and `exclude_type`. Each repeated flag
overwrites the previous value. Running `df -t ext4 -t
vfat` silently applies only the `vfat` filter.
```
# Actual:
$ df -t ext4 -t vfat
(shows only vfat filesystems — ext4 silently dropped)

# Expected (GNU):
$ df -t ext4 -t vfat
(shows both ext4 and vfat filesystems)
```
Fix: Change `include_type` and `exclude_type` fields to
`std.ArrayListUnmanaged([]const u8)`. In
`shouldIncludeFs`, check if the fstype matches any entry
in the list. Apply the same change to `-x`/`--exclude-type`
and `--type`.

---

### [IMPORTANT] --output field-list is parsed but never
applied
Location: `src/df.zig:103`, `src/df.zig:229-232`
Problem: `--output` and `--output=FIELD_LIST` are accepted
and stored in `opts.output_fields`, but the field list is
never consulted anywhere in the rendering path. Running
`df --output=source,target` produces the same full output
as plain `df`. GNU df's `--output` is the only way to
select individual columns. This stub misleads callers into
thinking column selection works.

Fix: In `runDf`, after parsing, if `opts.output_fields !=
null`, parse the comma-separated field list and pass it to
the print functions to render only the requested columns.
Valid field names per GNU: `source`, `fstype`, `itotal`,
`iused`, `iavail`, `ipcent`, `size`, `used`, `avail`,
`pcent`, `file`, `target`.

---

### [IMPORTANT] -n field name misleading; Linux silently
accepts unknown flag
Location: `src/df.zig:94`, `src/df.zig:253`
Problem: Field `no_sync` does not describe what macOS `-n`
does. The name echoes a GNU concept (`--no-sync`) that is
a WONT in this project. The misname is a maintenance
hazard. Separately, GNU df on Linux rejects `-n` as
invalid; our implementation silently accepts it.

Fix: Rename `no_sync` to `use_cached_stats`. On Linux,
reject `-n` and print an invalid-option error.

---

### [IMPORTANT] Linux -l local filter list is incomplete
Location: `src/df.zig:645-650`
Problem: On Linux (no `MNT_LOCAL` flag available), the
`-l` filter checks `isNetworkFs(fstype)` against a
hard-coded list. Any network filesystem type not in the
list (`glusterfs`, `davfs`, `sshfs`, `ceph`, etc.) is
treated as local and incorrectly included. The list
contains `gfs`/`gfs2` which are cluster filesystems
sometimes run locally.

Fix: Expand `isNetworkFs` to include at minimum:
`glusterfs`, `ceph`, `davfs`, `davfs2`, `sshfs`,
`curlftpfs`.

---

### [SUGGESTION] Default block size deviates from GNU
without documentation
Location: `src/df.zig:88` (`human_readable: bool = true`)
Problem: GNU df defaults to 1024-byte blocks when no block
size flag is given (512 if `POSIXLY_CORRECT` is set). Our
implementation defaults to `human_readable = true`. This
is a deliberate UX improvement but is undocumented.

Fix: Add a comment near `human_readable: bool = true`
noting this intentional deviation from GNU defaults and
the `POSIXLY_CORRECT` behavior not being implemented.

---

### [SUGGESTION] printHeader and printHeaderDynamic
duplicate size-label logic
Location: `src/df.zig:1335-1347` and
`src/df.zig:1635-1646`
Problem: The `size_label` computation (mapping block size
to header string) is copy-pasted between `printHeader` and
`printHeaderDynamic`. Any change to one must be mirrored
in the other.

Fix: Extract to a `formatSizeLabel(opts: DfOptions,
buf: []u8) []const u8` helper.

---

## I/O Pattern Verification

- `writerStreaming` used correctly for stdout and stderr
  (lines 2055-2060). PASS.
- 8192-byte buffers for both stdout and stderr. PASS.
- `flush()` called on both before exit (lines 2064-2065).
  PASS.
- Error messages go to stderr via
  `common.printErrorWithProgram`. PASS.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4 |
| IMPORTANT | 4 |
| SUGGESTION | 2 |

**Overall assessment: BLOCKED**

Four flags declared as supported either do the wrong thing
(-I, -Y), are complete stubs (-n behavioral no-op on
Darwin), or violate POSIX/GNU compliance (-P column
headers). The previous CRITICAL-4 (-T wrong meaning) is
closed: our `-T` correctly implements the GNU print-type
boolean. The previous IMPORTANT-2 (comma-separated type
filter) is replaced by the GNU-primary multi-flag `-t`
overwrite bug.

---

## Fix Order

```
Fix Order:
1. [CRITICAL] -P wrong column headers (1K-blocks/Avail/
   Use% vs 1024-blocks/Available/Capacity) —
   src/df.zig:1384
2. [CRITICAL] -I flag wrong: should suppress inodes
   (boolean), not filter type — src/df.zig:300
3. [CRITICAL] -Y stub: should set print_type=true —
   src/df.zig:318
4. [CRITICAL] -n stub: Darwin must pass MNT_WAIT/MNT_NOWAIT
   based on flag; Linux must reject -n — src/df.zig:359
5. [IMPORTANT] -t/-x: repeated flags overwrite instead of
   accumulating; change to list — src/df.zig:101
6. [IMPORTANT] --output field filtering not implemented —
   src/df.zig:103
7. [IMPORTANT] Rename no_sync to use_cached_stats; reject
   -n on Linux — src/df.zig:94
8. [IMPORTANT] Expand isNetworkFs list for -l on Linux —
   src/df.zig:645
9. [SUGGESTION] Extract duplicate size_label logic to
   helper
10. [SUGGESTION] Document human_readable default deviation
    from GNU/POSIXLY_CORRECT behavior
```

REVIEW COMPLETE - BLOCKED
