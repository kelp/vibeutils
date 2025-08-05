# Fuzzing Quick Start Guide

## Overview

The vibeutils fuzzing system now supports **selective fuzzing** of individual utilities, solving the previous limitation where fuzzing would get stuck on the first test forever.

## Quick Commands

### Using Make (Recommended)

```bash
# Show available fuzzing options
make fuzz

# Fuzz a specific utility
make fuzz UTIL=cat
make fuzz UTIL=echo

# List all available utilities
make fuzz-list

# Batch operations
make fuzz-all      # Fuzz all utilities (5 min each)
make fuzz-quick    # Quick test all utilities (30s each)
make fuzz-rotate   # Continuous rotation (2 min each)

# For macOS users (runs in Docker)
make fuzz-linux UTIL=cat
make fuzz-linux-all
make fuzz-linux-quick
```

### Using Build System Directly

```bash
# Individual utility targets
zig build fuzz-cat
zig build fuzz-echo
zig build fuzz-basename
# ... 22 total targets available
```

### Using Environment Variables

```bash
# Fuzz specific utility
VIBEUTILS_FUZZ_TARGET=cat zig build test --fuzz

# Fuzz all utilities
VIBEUTILS_FUZZ_TARGET=all zig build test --fuzz
```

### Using the Script

```bash
# Basic usage
./scripts/fuzz-utilities.sh cat          # Default 5 min timeout
./scripts/fuzz-utilities.sh -t 60 echo   # Custom 60s timeout

# Batch operations
./scripts/fuzz-utilities.sh all          # All utilities sequentially
./scripts/fuzz-utilities.sh -r -t 120    # Rotation mode, 2 min each

# Get help
./scripts/fuzz-utilities.sh -h
```

## Platform Requirements

- **Linux**: Full fuzzing support with all features
- **macOS**: Use `make fuzz-linux-*` targets (runs in Docker container)
- **Windows**: Not supported

## CI/CD Integration

```yaml
# GitHub Actions example
- name: Quick Fuzz Test
  run: make fuzz-quick
  
- name: Fuzz Critical Utilities
  run: |
    make fuzz UTIL=rm
    make fuzz UTIL=cp
    make fuzz UTIL=mv
```

## Common Workflows

### During Development

```bash
# After implementing a new feature in cat
make fuzz UTIL=cat

# Quick test before commit
make fuzz-quick
```

### Comprehensive Testing

```bash
# Full fuzzing session (Linux)
make fuzz-all

# From macOS
make fuzz-linux-all
```

### Debugging Fuzz Failures

```bash
# Interactive shell for manual fuzzing
make fuzz-linux-shell

# Then inside the container:
zig build fuzz-cat
# Or use the script:
./scripts/fuzz-utilities.sh -t 60 cat
```

## Available Utilities

All 23 utilities support fuzzing:
- `basename`, `cat`, `chmod`, `chown`, `cp`, `dirname`, `echo`
- `false`, `head`, `ln`, `ls`, `mkdir`, `mv`, `pwd`
- `rm`, `rmdir`, `sleep`, `tail`, `test`, `touch`, `true`, `yes`

## See Also

- [Full Fuzzing Documentation](FUZZING.md)
- [Selective Fuzzing Architecture](SELECTIVE_FUZZING.md)
- [Intelligent Fuzzer Implementation](../src/common/fuzz.zig)