---
description: Run tests for a specific utility or the full suite
disable-model-invocation: true
---

# /test [utility]

Run tests for the given utility. If no argument, run full suite.

## With argument (e.g., `/test wc`):

Run these steps in order, reporting pass/fail for each:

1. **Build:** `make build UTIL=$ARG`
2. **Unit tests:** `zig build test 2>&1 | grep -E "$ARG\.zig|passed|failed"`
3. **Smoke test:** Run `./zig-out/bin/$ARG --help` and
   `./zig-out/bin/$ARG --version` — verify both exit 0
4. **Man page lint:** `mandoc -T lint man/man1/$ARG.1`
   (skip if man page does not exist)

Report a summary table:

```
| Step       | Result |
|------------|--------|
| Build      | PASS   |
| Unit tests | PASS   |
| Smoke test | PASS   |
| Man page   | PASS   |
```

## Without argument:

1. Run `timeout 120 zig build test`
2. Run `zig build fmt -- --check` to verify formatting
3. Report pass/fail summary
