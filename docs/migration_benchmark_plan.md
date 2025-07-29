# Migration Benchmarking Plan

## Objective
Systematically measure performance and size impact of migrating from zig-clap to custom argparse across all utilities.

## Metrics to Track
1. **Binary size** (bytes)
2. **Parse time** (microseconds) 
3. **Memory allocations** (count)
4. **Build time** (seconds)
5. **Test pass rate** (%)

## Phase 1: Baseline Measurements (Before Migration)

### 1.1 Capture Current State
```bash
# Build all utilities with zig-clap
zig build -Doptimize=ReleaseSmall

# Record binary sizes
ls -l zig-out/bin/ > benchmark_results/baseline_sizes.txt

# Record build time
time zig build clean && time zig build > benchmark_results/baseline_build_time.txt

# Run tests
zig build test > benchmark_results/baseline_tests.txt
```

### 1.2 Create Utility-Specific Benchmarks
For each utility still using zig-clap:
- chmod, chown, cp, ln, ls, mkdir, mv, rm, rmdir, touch

Create a benchmark measuring common argument patterns:
```
- Simple flags: -h, -v
- Complex flags: utility-specific combinations
- With values: string/numeric options
- Error cases: invalid arguments
```

## Phase 2: Migration Process

### 2.1 Migration Order (Simple to Complex)
1. **mkdir** - Simple flags only
2. **rmdir** - Simple with some options
3. **touch** - Date/time parsing
4. **chmod** - Mode parsing
5. **chown** - User/group parsing
6. **ln** - Path handling
7. **rm** - Safety features
8. **cp** - Progress tracking
9. **mv** - Cross-filesystem
10. **ls** - Most complex

### 2.2 Per-Utility Process
```bash
# Before migration
./scripts/benchmark_single_utility.sh <utility> > benchmark_results/<utility>_before.txt

# Migrate the utility
# ... code changes ...

# After migration  
./scripts/benchmark_single_utility.sh <utility> > benchmark_results/<utility>_after.txt

# Compare
diff benchmark_results/<utility>_before.txt benchmark_results/<utility>_after.txt
```

## Phase 3: Final Measurements

### 3.1 After All Migrations
```bash
# Remove zig-clap dependency
# Edit build.zig.zon to remove clap

# Clean rebuild
zig build clean
time zig build -Doptimize=ReleaseSmall

# Final binary sizes
ls -l zig-out/bin/ > benchmark_results/final_sizes.txt

# Size comparison
./scripts/compare_sizes.sh benchmark_results/baseline_sizes.txt benchmark_results/final_sizes.txt
```

### 3.2 Performance Testing
Run comprehensive benchmarks on all migrated utilities:
```bash
./scripts/run_all_benchmarks.sh > benchmark_results/final_performance.txt
```

## Scripts to Create

### scripts/benchmark_single_utility.sh
```bash
#!/bin/bash
UTILITY=$1
ITERATIONS=1000

echo "Benchmarking $UTILITY"
echo "==================="

# Binary size
SIZE=$(ls -l zig-out/bin/$UTILITY | awk '{print $5}')
echo "Binary size: $SIZE bytes"

# Common operations
echo -e "\nTiming common operations ($ITERATIONS iterations):"

# Help flag
time for i in $(seq 1 $ITERATIONS); do
    ./zig-out/bin/$UTILITY --help > /dev/null 2>&1
done

# Utility-specific tests
case $UTILITY in
    ls) time for i in $(seq 1 $ITERATIONS); do
            ./zig-out/bin/$UTILITY -la /tmp > /dev/null 2>&1
        done ;;
    cp) time for i in $(seq 1 $ITERATIONS); do
            ./zig-out/bin/$UTILITY --help > /dev/null 2>&1
        done ;;
    # Add more utility-specific tests
esac
```

### scripts/compare_sizes.sh
```bash
#!/bin/bash
echo "Size Comparison Report"
echo "====================="
echo "Utility | Before | After | Reduction"
echo "--------|--------|-------|----------"

# Parse and compare sizes
# Calculate total and average reduction
```

## Success Criteria

1. **No regression** in functionality (all tests pass)
2. **Binary size reduction** of at least 30%
3. **Parse time** remains sub-millisecond for common cases
4. **Zero allocation** for flag parsing verified
5. **Build time** reduction (no clap compilation)

## Timeline

- Week 1: Baseline measurements + migrate simple utilities (mkdir, rmdir, touch)
- Week 2: Migrate medium complexity (chmod, chown, ln, rm)
- Week 3: Migrate complex utilities (cp, mv, ls)
- Week 4: Final measurements and documentation

## Deliverables

1. `benchmark_results/migration_report.md` - Complete comparison
2. `benchmark_results/*/` - Per-utility measurements
3. Updated `BENCHMARK_SUMMARY.md` with final results
4. Performance regression test suite