#!/usr/bin/env bash
# coverage.sh - Run vibeutils test binaries under kcov for coverage
#
# Builds test binaries with LLVM backend (required for DWARF debug
# info), runs each under kcov, merges results, and prints a summary.
#
# Usage: scripts/coverage.sh
# Output: zig-out/coverage/merged/index.html

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

COVERAGE_DIR="zig-out/coverage"
PARTS_DIR="$COVERAGE_DIR/parts"
TESTS_DIR="zig-out/bin/tests"

# Check for kcov
if ! command -v kcov &>/dev/null; then
    echo "Error: kcov not found."
    echo ""
    echo "Install kcov or run coverage in Docker:"
    echo "  just test-linux-coverage"
    exit 1
fi

# Clean previous results
rm -rf "$COVERAGE_DIR"
mkdir -p "$PARTS_DIR"

# Build test binaries with LLVM backend
echo "Building test binaries with LLVM backend..."
if ! zig build coverage 2>&1; then
    echo "Error: failed to build test binaries"
    exit 1
fi

# Verify test binaries exist
if [ ! -d "$TESTS_DIR" ] || [ -z "$(ls -A "$TESTS_DIR" 2>/dev/null)" ]; then
    echo "Error: no test binaries found in $TESTS_DIR"
    exit 1
fi

# Count binaries
total=$(find "$TESTS_DIR" -maxdepth 1 -type f -executable | wc -l)
current=0
failed=0

echo "Running $total test binaries under kcov..."
echo ""

for test_bin in "$TESTS_DIR"/*; do
    [ -x "$test_bin" ] || continue

    name=$(basename "$test_bin")
    current=$((current + 1))

    printf "  [%2d/%2d] %s..." "$current" "$total" "$name"

    if kcov --include-pattern=src/ "$PARTS_DIR/$name" "$test_bin" >/dev/null 2>&1; then
        echo " ok"
    else
        echo " FAIL"
        failed=$((failed + 1))
    fi
done

echo ""

# Collect part directories that actually have coverage data
part_dirs=()
for d in "$PARTS_DIR"/*/; do
    [ -d "$d" ] && part_dirs+=("$d")
done

if [ ${#part_dirs[@]} -eq 0 ]; then
    echo "Error: no coverage data produced"
    exit 1
fi

# Merge results
echo "Merging coverage results..."
kcov --merge "$COVERAGE_DIR/merged" "${part_dirs[@]}" >/dev/null 2>&1

# Print summary
echo ""
if [ -f "$COVERAGE_DIR/merged/kcov-merged/coverage.json" ]; then
    percent=$(python3 -c "
import json, sys
try:
    d = json.load(open('$COVERAGE_DIR/merged/kcov-merged/coverage.json'))
    print(d.get('percent_covered', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
    echo "Coverage: ${percent}%"
else
    echo "Coverage: (could not parse summary)"
fi

echo "Report:   $COVERAGE_DIR/merged/index.html"

if [ "$failed" -gt 0 ]; then
    echo ""
    echo "Warning: $failed test binary(ies) failed under kcov"
fi
