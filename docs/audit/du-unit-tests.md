# Unit Test Audit: du

**Date**: 2026-03-28
**Source**: `src/du.zig`
**Tests run**: 82 total; all 82 pass

## Executive Summary

NEEDS_FIXES

The du unit tests are generally well-structured and exercise real
filesystem behavior through `runDu`. The three MUST symlink flags
(-H, -L, -P) and the MUST -t threshold flag each have genuine
behavioral tests using tmp directories. However, 10 of 82 tests are
parse-only stubs (accept-or-reject checks only). Two MUST flags
(-x, -k) and two SHOULD flags (-S, -l) have zero behavioral
verification through `runDu`. Two output-format tests (-h, --si)
call `runDu` but assert only that output is non-empty and contains
the path — they do not verify the human-readable suffix format, so
a formatting regression would not be caught.

---

## Test Inventory

| Test Name | Tests Behavior? | Verdict |
|-----------|-----------------|---------|
| parseBlockSize - pure numeric | No — parses, no runDu | STUB |
| parseBlockSize - with suffix | No — parses, no runDu | STUB |
| parseBlockSize - SI suffixes | No — parses, no runDu | STUB |
| parseBlockSize - invalid | No — parses, no runDu | STUB |
| parseBlockSize - bare suffix | No — parses, no runDu | STUB |
| formatHumanReadable - bytes | Yes — checks formatted string | PASS |
| formatHumanReadable - kilobytes | Yes — checks formatted string | PASS |
| formatHumanReadable - megabytes | Yes — checks formatted string | PASS |
| formatHumanReadable - gigabytes | Yes — checks formatted string | PASS |
| resolveConfig - defaults | Yes — checks config fields | PASS |
| resolveConfig - bytes flag | Yes — checks apparent_size and block_size | PASS |
| resolveConfig - kilobytes flag | Yes — checks block_size | PASS |
| resolveConfig - summarize implies max-depth=0 | Yes — checks max_depth | PASS |
| resolveConfig - max-depth | Yes — checks max_depth | PASS |
| resolveConfig - invalid max-depth | Yes — checks error | PASS |
| resolveConfig - block-size option | Yes — checks block_size | PASS |
| resolveConfig - invalid block-size | Yes — checks error | PASS |
| du --help shows usage | Yes — checks output content | PASS |
| du --version shows version | Yes — checks output content | PASS |
| du invalid flag exits with code 2 | Yes — checks exit code | PASS |
| du nonexistent path exits with code 1 | Yes — checks exit code and stderr | PASS |
| du -s and -d conflict exits with code 2 | Yes — checks exit code | PASS |
| du on a file reports its size | Yes — checks size in output | PASS |
| du on a directory reports size | Yes — checks path in output | PASS |
| du -s shows only total for argument | Yes — checks line count | PASS |
| du -c shows grand total | Yes — checks "total" in output | PASS |
| du -a shows all files | Yes — checks filenames in output | PASS |
| du -h formats human-readable | Weak — checks path only, not suffix | WEAK |
| du defaults to current directory | Yes — checks non-empty output | PASS |
| du -d 0 is like -s | Yes — compares -d 0 vs -s output | PASS |
| du shouldPrintAtDepth | Yes — tests depth boundary logic | PASS |
| du getFileSize apparent vs disk | Yes — stat-based check | PASS |
| resolveConfig - color mode always | Yes — checks config field | PASS |
| resolveConfig - color mode never | Yes — checks config field | PASS |
| resolveConfig - color mode default | Yes — checks config field | PASS |
| resolveConfig - invalid color mode | Yes — checks error | PASS |
| du --color=invalid exits with code 2 | Yes — checks exit code and stderr | PASS |
| resolveConfig - show_icons defaults to false | Yes — checks config field | PASS |
| resolveConfig - icons=always enables show_icons | Yes — checks config field | PASS |
| resolveConfig - icons=never disables show_icons | Yes — checks config field | PASS |
| resolveConfig - invalid icon mode | Yes — checks error | PASS |
| printEntry without icons shows clean output | Yes — checks exact output string | PASS |
| printEntry with icons shows icon glyph | Yes — checks icon in output | PASS |
| printEntry with directory icon | Yes — checks dir icon in output | PASS |
| du --help shows icons option | Yes — checks output content | PASS |
| du -r flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| du -r produces same output as du | Yes — compares output equality | PASS |
| du -H flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| du -H follows symlinks given as command-line arguments | Yes — checks traversal result | PASS |
| du -H does not follow symlinks found during traversal | Yes — counts occurrences | PASS |
| du -P flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| du -P does not follow symlinks | Yes — checks file absent from output | PASS |
| du -P overrides -L when specified last | Yes — last-wins semantics | PASS |
| du -A flag is accepted and acts as --apparent-size | Yes — checks exact byte count | PASS |
| du -B flag sets block size | Yes — checks exact byte count | PASS |
| du -B flag with suffix | Yes — checks config field | PASS |
| du -g flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| resolveConfig - gigabytes flag sets block_size to 1G | Yes — checks config field | PASS |
| du -m flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| resolveConfig - megabytes flag sets block_size to 1M | Yes — checks config field | PASS |
| du -I flag is accepted with value | No — only checks exit_code != 2 | STUB |
| du -I flag does not change output (stub) | Yes — documents stub equality | PASS |
| du -l flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| resolveConfig - count_links flag | Weak — checks config field only | WEAK |
| du -n flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| du -n acts as -P (no follow symlinks) | Yes — checks file absent from output | PASS |
| du -n overrides -L when specified last | Yes — checks resolveDerefMode | PASS |
| du -t flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| parseThreshold - positive values | No — parses, no runDu | STUB |
| parseThreshold - negative values | No — parses, no runDu | STUB |
| parseThreshold - invalid | No — parses, no runDu | STUB |
| du -t filters entries below threshold | Yes — checks inclusion/exclusion | PASS |
| du -t with negative threshold shows entries at or below size | Yes — checks inclusion/exclusion | PASS |
| resolveConfig - threshold | Yes — checks config field | PASS |
| resolveConfig - negative threshold | Yes — checks config field | PASS |
| resolveConfig - invalid threshold | Yes — checks error | PASS |
| du --si flag is accepted by argparse | No — only checks exit_code != 2 | STUB |
| resolveConfig - si flag enables human_readable and si | Yes — checks config fields | PASS |
| formatHumanReadable - SI units | Yes — checks formatted strings | PASS |
| formatHumanReadable - SI vs binary | Yes — checks formatted strings | PASS |
| du --si shows SI units in output | Weak — checks path only, not SI suffix | WEAK |
| du --help shows new flags | Yes — checks output content | PASS |

**Totals**: 57 genuine behavioral / 15 parse-only or weak (10 STUB +
5 STUB from parseBlockSize/parseThreshold + 3 WEAK)

---

## Issues

### [IMPORTANT] -x (MUST) has zero unit tests
**Location**: `src/du.zig` — no test references `-x` or
`one_file_system` in any `test "` block
**Problem**: `-x` is a POSIX MUST flag. The implementation
exists at line 391 but there is no acceptance test, no
`resolveConfig` test, and no behavioral `runDu` test verifying
that directories on a different filesystem are skipped.
**Fix**: Add at minimum a `resolveConfig` test asserting
`config.one_file_system == true` when `opts.one_file_system =
true`. Add a behavioral test using two directories on the same
filesystem to show -x does not suppress them (the cross-device
case requires mount namespaces and is harder, but the same-device
path is fully testable).

### [IMPORTANT] -S / --separate-dirs (SHOULD) has zero unit tests
**Location**: `src/du.zig` — `separate_dirs` appears only as
struct field defaults in DuConfig literals; no `test "` block
exercises it
**Problem**: `-S` changes how directory sizes are computed (line
465). There is no test confirming that with `-S` a subdirectory's
contents are excluded from the parent's reported size. A
one-line logic change at 465 would be invisible to the test suite.
**Fix**: Add a `resolveConfig` test for `separate_dirs = true`.
Add a `runDu` behavioral test: create a parent dir containing a
subdir with a known file, run with `-b -S`, and verify the parent's
reported size excludes the subdir's bytes.

### [IMPORTANT] -l (SHOULD) has no hard-link behavioral test
**Location**: `src/du.zig:1749` (`resolveConfig - count_links
flag`)
**Problem**: The only non-stub `-l` test checks
`config.count_links == true`. The actual hard-link deduplication
logic at lines 400-407 is completely uncovered. A regression that
broke `-l` (e.g., always deduplicating even with `-l` set) would
not be caught.
**Fix**: Add a `runDu` test: create a file, hard-link it, run
`du -b -a` without `-l` and confirm the size appears once; run
`du -b -a -l` and confirm the size appears twice.

### [IMPORTANT] -k (MUST) has no end-to-end output test
**Location**: `src/du.zig:831` (`resolveConfig - kilobytes flag`)
**Problem**: `-k` is a POSIX MUST flag. The test confirms
`config.block_size == 1024` but never calls `runDu` to verify
the reported number is expressed in 1K blocks. The analogous `-g`
and `-m` tests share this gap.
**Fix**: Add a `runDu` test: write a file of known size (e.g.,
2048 apparent bytes), run `du -k -A -b` equivalent, and verify
the output number is `2` (ceiling-divided into 1K blocks).

### [SUGGESTION] -h and --si output-format tests are too weak
**Location**: `src/du.zig:1050` (`du -h formats human-readable`)
and `src/du.zig:1955` (`du --si shows SI units in output`)
**Problem**: Both tests call `runDu` and then only check that
the output contains the path string. They do not assert any
human-readable suffix (e.g., `K`, `kB`). A formatting bug that
produces raw bytes would pass these tests.
**Fix**: Write a file of a known apparent size (e.g., exactly
1024 bytes for -h, 1000 bytes for --si), run `du -h -A` / `du
--si -A` with `--block-size=1`, and assert the output starts with
`1.0K` or `1.0kB` respectively.

### [SUGGESTION] 10 parse-only acceptance tests add noise without value
**Location**: Lines 1365, 1411, 1516, 1660, 1680, 1700, 1740,
1760, 1809, 1922
**Problem**: Each of these tests does `try testing.expect(exit_code
!= 2)` after calling `runDu` with no path arguments. Because du
defaults to `.` when no path is given, these actually run du on the
current working directory — so they test argparse acceptance and a
live filesystem scan in one shot. However none of them assert
anything about output, so any behavioral regression is invisible.
Where a companion behavioral test already exists (e.g., `-H`, `-P`,
`-n`, `-t`, `-r`) the acceptance test is redundant.
**Fix**: For flags that already have behavioral `runDu` tests
(-H, -P, -n, -r, -t), delete the acceptance-only test. For
flags that currently have no behavioral test (-g, -m, -l, --si),
replace the acceptance test with a behavioral `runDu` test.

### [SUGGESTION] 5 parseBlockSize/parseThreshold tests are pure
unit tests on private functions
**Location**: Lines 752-785, 1818-1832
**Problem**: These tests exercise `parseBlockSize` and
`parseThreshold` directly. They are useful for isolating parsing
logic but do not constitute behavioral coverage for the flags that
use them. They are correctly categorized as implementation tests,
not flag coverage.
**Note**: No action needed beyond awareness that these tests do
not substitute for end-to-end flag tests.

---

## Flag Coverage Summary

| Flag | Tier | Behavioral Test? |
|------|------|-----------------|
| -a | MUST | Yes |
| -H | MUST | Yes |
| -k | MUST | Config only — no output test |
| -L | MUST | Yes (via -P/-H comparison tests) |
| -s | MUST | Yes |
| -x | MUST | **None** |
| -c | MUST | Yes |
| -d | MUST | Yes |
| -h | MUST | Weak — no suffix assertion |
| -P | MUST | Yes |
| -r | MUST | Yes (no-op equality) |
| -A | SHOULD | Yes |
| -B | SHOULD | Yes |
| -g | SHOULD | Config only — no output test |
| -I | SHOULD | Stub documented correctly |
| -l | SHOULD | **Config only — no hard-link test** |
| -m | SHOULD | Config only — no output test |
| -n | SHOULD | Yes |
| -t | SHOULD | Yes |
| -b | SHOULD | Yes |
| -S | SHOULD | **None** |
| --si | SHOULD | Weak — no suffix assertion |
| --apparent-size | SHOULD | Yes (via -A) |
| --block-size | SHOULD | Yes |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -x (MUST) has zero unit tests — src/du.zig
2. [IMPORTANT] -S / --separate-dirs (SHOULD) has zero unit tests
   — src/du.zig
3. [IMPORTANT] -l has no hard-link behavioral test — src/du.zig
4. [IMPORTANT] -k/-g/-m have no end-to-end output tests
   — src/du.zig
5. [SUGGESTION] -h and --si output-format tests are too weak
   — src/du.zig:1050, 1955
6. [SUGGESTION] Replace 10 parse-only acceptance tests with
   behavioral tests or delete redundant ones — src/du.zig:1365,
   1411, 1516, 1660, 1680, 1700, 1740, 1760, 1809, 1922
```

REVIEW COMPLETE - NEEDS_FIXES
