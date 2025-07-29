#!/bin/bash
# run-kcov-coverage.sh - Run tests with kcov for detailed coverage reports

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

# Check if kcov is available
if ! command -v kcov &> /dev/null; then
    echo -e "${RED}Error: kcov is not installed${NC}"
    echo "Install with:"
    echo "  Ubuntu/Debian: sudo apt-get install kcov"
    echo "  macOS: brew install kcov (may require building from source)"
    exit 1
fi

echo -e "${GREEN}Running tests with kcov coverage...${NC}"

# Create coverage directory
mkdir -p coverage/kcov

# Build all utilities first
echo "Building utilities..."
zig build

# Function to run kcov for a single test
run_kcov_test() {
    local name=$1
    local test_file=$2
    
    echo -e "${GREEN}Running kcov for ${name}...${NC}"
    
    # Build test executable
    local test_exe="zig-out/test-${name}"
    zig test "${test_file}" --test-cmd "${test_exe}" --test-cmd-bin 2>/dev/null || true
    
    if [ -f "${test_exe}" ]; then
        kcov \
            --exclude-pattern=/usr/include,/usr/lib,/zig/,/snap/,zig-cache \
            --include-pattern="${PROJECT_ROOT}/src/" \
            "coverage/kcov/${name}" \
            "${test_exe}" || {
            echo -e "${YELLOW}Warning: kcov failed for ${name}${NC}"
        }
    else
        # Fallback: run test directly with kcov
        kcov \
            --exclude-pattern=/usr/include,/usr/lib,/zig/,/snap/,zig-cache \
            --include-pattern="${PROJECT_ROOT}/src/" \
            "coverage/kcov/${name}" \
            zig test "${test_file}" 2>&1 || {
            echo -e "${YELLOW}Warning: kcov failed for ${name}${NC}"
        }
    fi
}

# Run tests for each utility
for utility in echo cat ls cp mv rm mkdir rmdir touch pwd chmod chown ln; do
    if [ -f "src/${utility}.zig" ]; then
        run_kcov_test "${utility}" "src/${utility}.zig"
    elif [ -f "src/${utility}/main.zig" ]; then
        run_kcov_test "${utility}" "src/${utility}/main.zig"
    fi
done

# Run common library tests
run_kcov_test "common" "src/common/lib.zig"

# Merge coverage reports
echo -e "${GREEN}Merging coverage reports...${NC}"
mkdir -p coverage/merged

# Find all coverage directories
coverage_dirs=$(find coverage/kcov -maxdepth 1 -type d | grep -v "^coverage/kcov$" | tr '\n' ' ')

if [ -n "$coverage_dirs" ]; then
    kcov --merge coverage/merged $coverage_dirs || {
        echo -e "${YELLOW}Warning: Coverage merge failed${NC}"
    }
    echo -e "${GREEN}Coverage report available at: coverage/merged/index.html${NC}"
else
    echo -e "${YELLOW}No coverage data to merge${NC}"
fi

# Print summary
if [ -f "coverage/merged/index.json" ]; then
    # Extract coverage percentage from JSON if jq is available
    if command -v jq &> /dev/null; then
        coverage_percent=$(jq -r '.percent_covered // "unknown"' coverage/merged/index.json 2>/dev/null || echo "unknown")
        echo -e "${GREEN}Overall coverage: ${coverage_percent}%${NC}"
    fi
fi

echo -e "${GREEN}Coverage analysis complete!${NC}"