#!/bin/bash

# Script to run benchmarks on all utilities
# Saves results with timestamp

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESULTS_DIR="benchmark_results/all_utilities"
RESULTS_FILE="${RESULTS_DIR}/benchmark_all_${TIMESTAMP}.txt"

# Create results directory if it doesn't exist
mkdir -p "${RESULTS_DIR}"

echo "Running benchmarks for all utilities..."
echo "Results will be saved to: ${RESULTS_FILE}"
echo

# List of all utilities
UTILITIES="echo cat pwd chmod chown cp ln ls mkdir mv rm rmdir touch"

{
    echo "Complete Utility Benchmark Report"
    echo "================================="
    echo "Date: $(date)"
    echo "Build mode: $(grep -q "ReleaseSmall" .zig-cache/h/* 2>/dev/null && echo "ReleaseSmall" || echo "Debug")"
    echo
    
    for UTILITY in $UTILITIES; do
        if [ -f "zig-out/bin/$UTILITY" ]; then
            echo "========================================="
            ./benchmark_single_utility.sh "$UTILITY"
            echo
        else
            echo "Warning: $UTILITY not found in zig-out/bin/"
        fi
    done
    
    echo "========================================="
    echo "Overall Summary"
    echo "========================================="
    
    # Count utilities by parser type
    CLAP_COUNT=0
    CUSTOM_COUNT=0
    
    for UTILITY in $UTILITIES; do
        if [ -f "src/$UTILITY.zig" ]; then
            if grep -q '@import("clap")' "src/$UTILITY.zig" 2>/dev/null; then
                CLAP_COUNT=$((CLAP_COUNT + 1))
            else
                CUSTOM_COUNT=$((CUSTOM_COUNT + 1))
            fi
        fi
    done
    
    echo "Utilities using zig-clap: $CLAP_COUNT"
    echo "Utilities using custom parser: $CUSTOM_COUNT"
    echo
    
    # Total binary sizes
    echo "Total binary sizes:"
    ls -lh zig-out/bin/ | grep -E "(echo|cat|pwd|chmod|chown|cp|ln|ls|mkdir|mv|rm|rmdir|touch)" | \
        awk '{sum+=$5; print $9 ": " $5} END {print "Total: " sum " bytes"}'
    
} | tee "${RESULTS_FILE}"

echo
echo "Benchmark complete. Results saved to: ${RESULTS_FILE}"

# Create symlink to latest results
ln -sf "benchmark_all_${TIMESTAMP}.txt" "${RESULTS_DIR}/latest.txt"
echo "Latest results also available at: ${RESULTS_DIR}/latest.txt"