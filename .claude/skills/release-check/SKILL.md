---
description: Validate release readiness before tagging
disable-model-invocation: true
---

# /release-check [version]

Validate that the project is ready to cut a release. The
version argument must be provided (e.g., `0.7.4`).

## Procedure

Run each check in order. Stop at the first failure and
report what needs fixing.

### 1. Semver format

Verify the argument matches `x.y.z` where x, y, and z are
non-negative integers. Reject missing arguments, leading
zeros, or extra segments.

### 2. Branch check

Run `git branch --show-current`. Must be `main`.

### 3. Clean working tree

Run `git status --porcelain`. Output must be empty.

### 4. Unit tests

Run `timeout 120 zig build test`. Must exit 0.

### 5. Build

Run `make build`. Must exit 0.

### 6. Integration tests

Run `make it`. Must exit 0.

### 7. Man page lint

Run `mandoc -T lint man/man1/*.1`. Must produce no errors
or warnings.

### 8. Cross-platform tests (optional)

Check if `orb` is available (`command -v orb`). If present,
run `orb -m ubuntu zig build test`. If `orb` is not
available, mark as SKIP.

### 9. Tag check

Run `git tag -l "v$VERSION"`. Output must be empty
(tag must not already exist).

## Output

Report results as a checklist table:

```
Release Readiness: v$VERSION

| Check              | Result |
|--------------------|--------|
| Semver format      | PASS   |
| On main branch     | PASS   |
| Clean working tree | PASS   |
| Unit tests         | PASS   |
| Build              | PASS   |
| Integration tests  | PASS   |
| Man pages          | PASS   |
| Linux tests        | PASS   |
| Tag available      | PASS   |
```

Use PASS, FAIL, or SKIP for each result.

### On success

If all checks pass (SKIP is acceptable), print:

```
All checks passed. Ready to release:
  make release VERSION=$VERSION
```

### On failure

Stop at the first FAIL. Print the table with completed
rows, mark the failed row as FAIL, and leave remaining
rows blank. Then explain what needs fixing.
