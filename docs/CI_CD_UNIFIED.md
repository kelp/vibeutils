# Unified CI/CD Approach

This document describes the unified CI/CD implementation for the vibeutils project.

## Overview

The build system has been enhanced to provide a single source of truth for both local development and CI workflows. All build commands are implemented in `build.zig`, with the Makefile serving as a thin convenience wrapper.

## Key Features

### 1. Format and Format-Check Steps
- `make fmt` / `zig build fmt` - Format all source files
- `make fmt-check` / `zig build fmt-check` - Check if files are properly formatted

### 2. Clean Step
- `make clean` / `zig build clean` - Remove all build artifacts (zig-cache, zig-out, coverage)

### 3. Coverage Support
- `make coverage` / `zig build coverage` - Run tests with native Zig coverage
- `make coverage-kcov` / `zig build coverage -Dcoverage-backend=kcov` - Run tests with kcov for detailed reports

### 4. CI Validation
- `make ci-validate` / `zig build ci-validate -Dci=true` - Run all CI validation checks
  - Code formatting check
  - Build configuration validation
  - Test execution
  - Code quality checks (TODOs, debug prints, panics)

### 5. Smart Privileged Test Detection
The build system automatically filters privileged tests based on the "privileged:" prefix in test names.

## CI/CD Workflows

### GitHub Actions Integration
The workflows have been updated to use the unified commands:

```yaml
# Format check
make fmt-check

# Run tests with coverage
make coverage
make coverage-kcov  # If kcov is available

# CI validation
make ci-validate
```

### Local Development
Developers use the same commands locally:

```bash
# Format code before committing
make fmt

# Check formatting
make fmt-check

# Run tests
make test

# Clean and rebuild
make clean
make build

# Run with coverage
make coverage
```

## Build Options

The build system supports several options:

- `-Doptimize=[Debug|ReleaseSafe|ReleaseFast|ReleaseSmall]` - Optimization level
- `-Dcoverage=true` - Enable coverage instrumentation
- `-Dci=true` - Enable CI-specific behavior
- `-Dcoverage-backend=[native|kcov]` - Coverage backend selection

## Coverage Backends

### Native Coverage
Uses Zig's built-in coverage support. Fast but currently limited in reporting capabilities.

### Kcov Coverage
Uses the external kcov tool for detailed coverage reports with HTML output. The `scripts/run-kcov-coverage.sh` script handles the complexity of running kcov for each test module.

## Benefits

1. **Single Source of Truth**: All build logic lives in `build.zig`
2. **Consistency**: Local development and CI use identical commands
3. **Maintainability**: Changes only need to be made in one place
4. **Platform Intelligence**: The build system handles platform differences automatically
5. **Better Error Handling**: Clear error messages and validation feedback

## Implementation Details

### build.zig Enhancements
- Added `addFormatSteps()` for code formatting
- Added `addCleanStep()` for artifact cleanup
- Added `addCoverageSteps()` with backend support
- Added `addCIValidateStep()` for CI validation

### Scripts
- `scripts/ci-validate.sh` - Smart CI validation with colored output
- `scripts/run-kcov-coverage.sh` - Kcov coverage runner
- `scripts/run-privileged-tests.sh` - Existing privileged test runner

### Makefile
Simplified to delegate to `zig build` commands, maintaining backward compatibility while reducing duplication.

## Future Enhancements

1. Add native Zig coverage report generation when the feature matures
2. Integrate coverage reports with GitHub Actions annotations
3. Add performance benchmarking to CI validation
4. Implement incremental build caching for faster CI runs