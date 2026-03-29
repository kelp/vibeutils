# seq Code Audit

Date: 2026-03-28
GNU coreutils 9.10 is the primary behavioral reference.
Build: passing. Unit tests: all pass (see seq-unit-tests.md).
Integration tests: 11/11 pass (see seq-integration-tests.md).

---

## Issues

### [IMPORTANT] -f format string: prefix/suffix text silently dropped

Location: `src/seq.zig:181-218` (`formatWithSpec`)

Problem: `formatWithSpec` scans for the `%` specifier and
immediately calls a format helper, discarding all literal
characters before and after the `%` conversion. GNU seq
prints the entire format string for each number, with only
the `%` conversion replaced by the value.

```
GNU:  seq -f 'val=%5.2f!' 3  →  "val= 1.00!"  "val= 2.00!" ...
Ours: seq -f 'val=%5.2f!' 3  →  "1.000000"   "2.000000"   ...
```

Fix: Rewrite `formatWithSpec` to walk the format string
character by character, writing literal bytes through to the
writer directly and substituting only the single `%…f/e/g`
conversion with the formatted number.

---

### [IMPORTANT] -f format string: width and precision specs ignored

Location: `src/seq.zig:207-212` (`formatWithSpec` conversion
dispatch)

Problem: The switch on the conversion character dispatches to
`formatDecimal(buf, value, 6)`, `formatScientific`, or
`formatGeneral` with hardcoded parameters. Any width (`%5`)
or precision (`.2`) parsed from the format string is parsed
syntactically (lines 195-204) but never used.

```
GNU:  seq -f '%05.1f' 3  →  "001.0"  "002.0"  "003.0"
Ours: seq -f '%05.1f' 3  →  "1.000000"  "2.000000"  "3.000000"
```

Fix: Extract the width and precision integers while parsing,
then pass them as arguments to a formatting function that
actually uses them (or delegate to libc `snprintf` via Zig's
`std.c`).

---

### [IMPORTANT] Negative increment without `--` rejected as unknown option

Location: `src/seq.zig:297-315` (argparse call in `runSeq`)

Problem: `seq 5 -1 1` is a standard GNU usage (count down
from 5 to 1 in steps of -1). Our argparse sees `-1` as an
unknown short flag and exits with "unrecognized option". GNU
seq parses all three operands positionally once it sees that
three non-option arguments are present; the middle operand
being negative is legal.

```
GNU:  seq 5 -1 1  →  5 4 3 2 1   (exit 0)
Ours: seq 5 -1 1  →  "seq: unrecognized option"  (exit 2)
```

The workaround (`seq 5 -- -1 1`) works but is not standard
usage and scripts that call `seq` without `--` will break.

Fix: After argparse collects positionals, if three positionals
are present and the second starts with `-` followed by a digit,
re-parse it as a number rather than treating it as an error.
Alternatively, teach argparse to stop flag scanning once it
encounters a digit-following-dash in a positional context.

---

### [IMPORTANT] Error exit code is 2 (misuse) where GNU uses 1

Location: `src/seq.zig:302`, `338`, `353`, `362`, `376`,
`383`, `392`

Problem: All error paths return
`@intFromEnum(common.ExitCode.misuse)` which is 2. GNU seq
exits 1 for all errors (invalid argument, missing operand,
zero increment, unknown flag). Only argument-parsing misuse
(e.g. extra operand) arguably warrants exit 2; all
value-related errors in GNU use exit 1.

```
GNU:  seq abc      → exit 1
GNU:  seq 1 0 5    → exit 1
GNU:  seq          → exit 1
Ours: all of above → exit 2
```

The integration test at seq_test.sh:61 explicitly checks
for exit 2 on `--invalid-flag`, which locks in the wrong
behavior.

Fix: Change `runSeq` error returns for operand and value
errors to use `common.ExitCode.general_error` (1). Keep
exit 2 only where it is truly warranted (or drop the
distinction and use exit 1 throughout to match GNU).

---

### [IMPORTANT] `nan` input silently produces empty output instead of error

Location: `src/seq.zig:351-386` (float parsing)

Problem: Zig's `std.fmt.parseFloat` accepts `"nan"` as a
valid f64 (`std.math.nan`). The loop condition
`current <= last + ...` is false immediately when `last` is
NaN, so nothing is printed and the program exits 0. GNU seq
rejects `nan` with "invalid 'not-a-number' argument" and
exits 1.

```
GNU:  seq nan  → "seq: invalid 'not-a-number' argument: 'nan'"  exit 1
Ours: seq nan  → (empty, exit 0)
```

Same problem applies to `seq 1 nan 5` and `seq 1 1 nan`.

Fix: After parsing each float operand, check
`std.math.isNan(value)` and emit the appropriate error.

---

### [SUGGESTION] Zero-increment error message capitalizes "Zero"

Location: `src/seq.zig:392`

Problem: The error string is `"invalid Zero increment
value: '{s}'"`. GNU says `"invalid Zero increment value: '0'"`.
The messages match by coincidence (GNU also capitalizes "Zero"
in this one case) — no change needed, but the message is
non-standard phrasing. Low priority.

---

### [SUGGESTION] `formatGeneral` is a hand-rolled approximation of `%g`

Location: `src/seq.zig:252-284`

Problem: `formatGeneral` formats with 10 decimal places then
trims trailing zeros. This deviates from `%g` semantics (use
shortest of `%f`/`%e`, 6 significant digits) for large or
very small numbers. For typical integer sequences this is
invisible, but for values like `1e10` or `0.0001` the output
may differ from GNU.

Fix: Implement true `%g` semantics (choose `%e` when exponent
< -4 or >= precision, otherwise `%f`, with 6 significant
digits) or use libc `snprintf` with `%g`.

---

## Flag Coverage

| Flag | Tier | Status |
|------|------|--------|
| -f FORMAT | MUST | Broken: prefix/suffix dropped, width/precision ignored |
| -s SEP | MUST | Correct |
| -w | MUST | Correct |
| Negative increment | — | Broken: requires `--` workaround |

---

## Summary

NEEDS_FIXES

| Severity | Count |
|----------|-------|
| IMPORTANT | 5 |
| SUGGESTION | 2 |

Fix Order:
1. [IMPORTANT] -f prefix/suffix text dropped — `src/seq.zig:181`
2. [IMPORTANT] -f width/precision ignored — `src/seq.zig:207`
3. [IMPORTANT] Negative increment without `--` rejected — `src/seq.zig:297`
4. [IMPORTANT] Error exit code 2 vs GNU's 1 — `src/seq.zig:302`
5. [IMPORTANT] `nan` input silently empty — `src/seq.zig:351`
6. [SUGGESTION] `formatGeneral` not true `%g` — `src/seq.zig:252`
7. [SUGGESTION] Error message phrasing — `src/seq.zig:392`
