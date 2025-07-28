# Argument Parser Benchmark Results

## Date: 2025-07-27

### Custom Parser Performance (vibeutils argparse)

Implementation: `src/common/argparse.zig`
- Lines of code: ~579 (excluding tests)
- Test coverage: 30 tests, all passing

#### Performance Results (10,000 iterations each)

| Test Case | Description | Args | Total Time | Per Iteration | 
|-----------|-------------|------|------------|---------------|
| Simple flags | 3 boolean flags | `-h -v -d` | 0.33 ms | 33 ns (0.03 μs) |
| Combined flags | 5 flags combined | `-hvdfa` | 1.43 ms | 142 ns (0.14 μs) |
| Long flags | 5 long flags | `--help --verbose --debug --force --all` | 1.07 ms | 107 ns (0.11 μs) |
| Mixed with values | Flags + string/int/enum values | `-v --count=42 -o output.txt --level 5 -m fast` | 1.40 ms | 139 ns (0.14 μs) |
| Complex with positionals | Flags + values + positionals | `-vdf --count=100 -o out.txt -- file1.txt file2.txt file3.txt` | 566.93 ms | 56,692 ns (56.69 μs) |
| Many flags | 16 arguments total | `-h -v -q -d -f -r -a -I --count=10 --level=20 --output=test.txt --input=in.txt --format=json --mode=auto pos1 pos2` | 609.58 ms | 60,958 ns (60.96 μs) |

### Memory Usage

**Custom Parser Allocations:**
- 0 allocations for flag/option parsing
- 1 allocation for positional arguments array (only when positionals present)
- String options point directly to original argv (no copying)

### Binary Size Comparison (ReleaseSmall)

| Utility | Size | Parser Used |
|---------|------|-------------|
| echo | 26K | Custom argparse |
| cat | 32K | Custom argparse |
| pwd | 30K | Custom argparse |

### Comparison vs zig-clap

| Metric | Custom Parser | zig-clap |
|--------|---------------|----------|
| Implementation size | ~579 lines | ~3,000 lines |
| Allocations for flags | 0 | Multiple |
| API style | Type-safe struct | String-based |
| Compile-time validation | Yes | Limited |
| Type support | bool, int, float, enum, string | Similar |

### Test Environment

- Platform: Linux 6.15.2-arch1-1
- Zig version: 0.14.1
- Build mode: ReleaseFast for benchmarks, ReleaseSmall for size
- CPU: (system specific)

### Notes

1. The significant time increase for "Complex with positionals" and "Many flags" 
   tests is due to the allocation for the positionals array. Without positionals,
   parsing remains in the nanosecond range.

2. All string option values are zero-copy - they point directly into the original
   argument strings.

3. The parser uses compile-time reflection to generate optimal parsing code for
   each struct type.

### Migration Status

Utilities migrated to custom parser:
- ✅ echo (16 tests passing)
- ✅ cat (builds and runs correctly)
- ✅ pwd (builds and runs correctly)

Utilities still using zig-clap:
- ❌ ls, cp, mv, rm, mkdir, rmdir, touch, chmod, chown, ln (10 utilities)