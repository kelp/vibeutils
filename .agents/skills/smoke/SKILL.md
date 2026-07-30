---
description: Run binary smoke tests for a utility
disable-model-invocation: true
---

# /smoke <utility>

Quick smoke test that a built utility binary works. Lighter
than the full test suite for rapid iteration.

## Steps

1. Build the utility: `just build-util <utility>`
2. Run these checks against `./zig-out/bin/<utility>`:
   - `--version` exits 0 and prints a version string
   - `--help` exits 0 and prints usage text
   - Run with no arguments (note exit code — some utilities
     expect stdin, so a non-zero exit is acceptable)
3. Report pass/fail for each check

## Example output

```
Smoke test: wc
  --version  exit 0  "wc (vibeutils) 0.6.0"
  --help     exit 0  (21 lines)
  (no args)  exit 0  (reads stdin — expected)
All checks passed.
```

## Notes

- If the binary doesn't exist, run `just build-util <name>`
  first
- Some utilities (cat, tee, sort, etc.) read stdin when given
  no arguments — that's expected, not a failure
- This is a quick sanity check, not a substitute for
  `just test` or `just it-util <name>`
