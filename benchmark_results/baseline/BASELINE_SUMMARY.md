# Baseline Benchmark Summary - zig-clap Utilities

Date: July 27, 2025

This document summarizes the baseline performance benchmarks for all utilities
that still use zig-clap before migration to the custom argument parser.

## Utilities Benchmarked

### Still using zig-clap:
- mkdir
- rmdir  
- touch
- chmod
- chown
- ln
- rm
- cp
- mv
- ls

### Already migrated (for comparison):
- echo (custom parser)
- cat (custom parser)
- pwd (custom parser)

## Binary Sizes

| Utility | Size (bytes) | Size (human) | Parser |
|---------|-------------|--------------|---------|
| mkdir   | 3,312,320   | 3.2M        | zig-clap |
| rmdir   | 3,268,960   | 3.2M        | zig-clap |
| touch   | 3,354,048   | 3.2M        | zig-clap |
| chmod   | 3,304,504   | 3.2M        | zig-clap |
| chown   | 3,358,528   | 3.3M        | zig-clap |
| ln      | 3,363,840   | 3.3M        | zig-clap |
| rm      | 3,468,632   | 3.4M        | zig-clap |
| cp      | 3,612,936   | 3.5M        | zig-clap |
| mv      | 3,662,464   | 3.5M        | zig-clap |
| ls      | 4,083,640   | 3.9M        | zig-clap |
| echo    | 3,239,152   | 3.1M        | custom   |
| cat     | 3,305,680   | 3.2M        | custom   |
| pwd     | 3,239,152   | 3.1M        | custom   |

## Performance Metrics

### Help Flag Performance (1000 iterations)

| Utility | Total Time | Per Iteration |
|---------|-----------|---------------|
| mkdir   | 2.30s     | 2300 μs      |
| rmdir   | 2.31s     | 2310 μs      |
| touch   | 2.37s     | 2370 μs      |
| chmod   | 2.29s     | 2290 μs      |
| chown   | 2.31s     | 2310 μs      |
| ln      | 2.29s     | 2290 μs      |
| rm      | 2.30s     | 2300 μs      |
| cp      | 2.29s     | 2290 μs      |
| mv      | 2.29s     | 2290 μs      |
| ls      | ~5.71s*   | ~5710 μs*    |
| echo    | 1.66s     | 1660 μs      |

*ls benchmark had issues completing, values are estimates

### Version Flag Performance (1000 iterations)

| Utility | Total Time | Per Iteration |
|---------|-----------|---------------|
| mkdir   | 1.77s     | 1770 μs      |
| rmdir   | 1.77s     | 1770 μs      |
| touch   | 1.77s     | 1770 μs      |
| chmod   | 1.77s     | 1770 μs      |
| chown   | 1.77s     | 1770 μs      |
| ln      | 1.77s     | 1770 μs      |
| rm      | 1.77s     | 1770 μs      |
| cp      | 1.77s     | 1770 μs      |
| mv      | 1.77s     | 1770 μs      |
| echo    | 1.17s     | 1170 μs      |

### Invalid Flag Performance (1000 iterations)

| Utility | Total Time | Per Iteration |
|---------|-----------|---------------|
| mkdir   | 1.78s     | 1780 μs      |
| rmdir   | 1.78s     | 1780 μs      |
| touch   | 1.78s     | 1780 μs      |
| chmod   | 1.78s     | 1780 μs      |
| chown   | 1.78s     | 1780 μs      |
| ln      | 1.78s     | 1780 μs      |
| cp      | 1.78s     | 1780 μs      |
| mv      | 1.78s     | 1780 μs      |
| echo    | 1.18s     | 1180 μs      |

### Memory Usage (Maximum RSS)

| Utility | Max RSS (KB) |
|---------|-------------|
| mkdir   | 3,900       |
| rmdir   | 3,724       |
| touch   | 3,916       |
| chmod   | 3,780       |
| chown   | 3,924       |
| ln      | 3,768       |
| rm      | 3,736       |
| cp      | 3,892       |
| mv      | 3,880       |
| ls      | 5,144       |
| echo    | 3,516       |

## Key Observations

1. **Binary Size Impact**: The size difference between zig-clap and custom
   parser utilities is minimal. Most utilities are in the 3.2-3.5M range, with
   echo and pwd being slightly smaller at 3.1M. The ls utility is the largest
   at 3.9M due to its extensive feature set.

2. **Performance Overhead**: 
   - Help flag: zig-clap utilities take ~2.3s for 1000 iterations vs 1.66s
     for custom parser (38% slower)
   - Version flag: zig-clap takes 1.77s vs 1.17s for custom parser (51%
     slower)
   - Invalid flag: zig-clap takes 1.78s vs 1.18s for custom parser (51%
     slower)

3. **Memory Usage**: zig-clap utilities use slightly more memory (3.7-3.9MB)
   compared to custom parser utilities (3.5MB).

4. **ls Special Case**: The ls utility has significantly higher resource usage
   (3.9M binary, 5.1MB RSS) and severe performance issues, with benchmarks
   timing out even at reduced iteration counts.

## Migration Priority

Based on these benchmarks, the recommended migration priority is:

1. **High Priority**:
   - ls (largest performance impact, timing out on benchmarks)
   - rm, cp, mv (core utilities with moderate usage)

2. **Medium Priority**:
   - mkdir, rmdir (frequently used but simpler)
   - touch, chmod, chown (moderate usage)

3. **Lower Priority**:
   - ln (less frequently used)

## Expected Benefits from Migration

Based on the already-migrated utilities (echo, cat, pwd):

- **Performance improvement**: 30-50% faster argument parsing
- **Memory reduction**: ~200-400KB lower RSS
- **Simplified dependencies**: No external clap dependency
- **Better error messages**: Custom error handling tailored to each utility
- **Maintainability**: Direct control over argument parsing logic
- **Reduced complexity**: Simpler codebase without macro-heavy dependencies