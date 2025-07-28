# Argument Parser Migration Status

## Overview
This document tracks the migration from zig-clap to our custom argument parser implementation.

## Migration Progress

### ✅ Completed (3/13)
| Utility | Tests | Binary Size | Notes |
|---------|-------|-------------|-------|
| echo | 16/16 ✓ | 26K | First migration, all tests passing |
| cat | Builds ✓ | 32K | Complex flag combinations working |
| pwd | Builds ✓ | 30K | Simple utility, clean migration |

### 🔄 In Progress (0/13)
None currently in progress.

### ❌ Pending (10/13)
| Utility | Complexity | Current Size | Priority |
|---------|------------|--------------|----------|
| mkdir | Low | 41K | High - Simple flags |
| rmdir | Low | 35K | High - Similar to mkdir |
| touch | Medium | 86K | High - Date parsing |
| chmod | Medium | 43K | Medium - Mode parsing |
| chown | Medium | 44K | Medium - User/group |
| ln | Medium | 46K | Medium - Path handling |
| rm | High | 56K | Low - Safety features |
| cp | High | 107K | Low - Progress tracking |
| mv | High | 112K | Low - Cross-filesystem |
| ls | Very High | 156K | Low - Most complex |

## Benchmarking Infrastructure

### Scripts Created
1. `run_benchmark.sh` - Run parser benchmarks
2. `benchmark_single_utility.sh` - Benchmark individual utility
3. `compare_sizes.sh` - Compare binary sizes
4. `run_all_benchmarks.sh` - Benchmark all utilities

### Baseline Captured
- Binary sizes: `benchmark_results/baseline/sizes_with_mixed_parsers.txt`
- Individual benchmarks in `benchmark_results/baseline/`

## Key Findings So Far

### Performance
- Custom parser: 0.04-1.6 μs for typical operations
- With allocations: ~60-90 μs (positional args)

### Binary Size
- Migrated utilities average: ~29K
- Unmigrated utilities average: ~73K
- Expected reduction: ~60%

### Memory
- Custom parser: 1 allocation (positionals only)
- zig-clap: Multiple allocations

## Next Steps

1. **Immediate**: Migrate mkdir and rmdir (simplest remaining)
2. **This Week**: Complete touch, chmod, chown
3. **Next Week**: Tackle complex utilities (rm, cp, mv, ls)
4. **Final**: Remove zig-clap dependency entirely

## How to Track Progress

```bash
# Check migration status
grep -l "clap" src/*.zig | wc -l  # Count remaining

# Run benchmarks before migration
./benchmark_single_utility.sh <utility> > before.txt

# After migration
./benchmark_single_utility.sh <utility> > after.txt

# Compare
diff before.txt after.txt
```

## Success Metrics
- [ ] All tests passing (100%)
- [ ] Binary size reduction >50%
- [ ] Parse time <1ms for common cases
- [ ] Zero allocations for flag parsing
- [ ] Build time improvement