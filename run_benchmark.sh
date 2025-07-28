#!/bin/bash

# Script to run benchmarks and save results with timestamp

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESULTS_DIR="benchmark_results"
RESULTS_FILE="${RESULTS_DIR}/benchmark_${TIMESTAMP}.txt"

# Create results directory if it doesn't exist
mkdir -p "${RESULTS_DIR}"

echo "Running argument parser benchmarks..."
echo "Results will be saved to: ${RESULTS_FILE}"

# Run the benchmark and save output
zig build benchmark > "${RESULTS_FILE}" 2>&1

# Also display the results
cat "${RESULTS_FILE}"

echo ""
echo "Benchmark complete. Results saved to: ${RESULTS_FILE}"

# Create a symlink to the latest results
ln -sf "benchmark_${TIMESTAMP}.txt" "${RESULTS_DIR}/latest.txt"

echo "Latest results also available at: ${RESULTS_DIR}/latest.txt"