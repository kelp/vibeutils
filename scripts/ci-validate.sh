#!/bin/bash
# ci-validate.sh - Smart CI validation script

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Track validation results
VALIDATION_FAILED=0

echo "Running CI validation checks..."

# 1. Check code formatting
echo -n "Checking code formatting... "
if zig fmt --check src/ build.zig build/ > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: Code is not properly formatted. Run 'make fmt' to fix.${NC}"
    VALIDATION_FAILED=1
fi

# 2. Check build configuration
echo -n "Checking build configuration... "
if zig build --help > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: Build configuration is invalid.${NC}"
    VALIDATION_FAILED=1
fi

# 3. Run tests
echo -n "Running tests... "
if zig build test --summary none > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: Tests failed.${NC}"
    VALIDATION_FAILED=1
fi

# 4. Check for common issues
echo "Checking for code quality issues..."

# Check for TODO/FIXME items
TODO_COUNT=$(grep -r "TODO\|FIXME" src/ --exclude-dir=zig-cache --exclude-dir=zig-out 2>/dev/null | wc -l || echo 0)
if [ "$TODO_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Notice: Found $TODO_COUNT TODO/FIXME items (non-blocking)${NC}"
fi

# Check for debug prints in non-test code
DEBUG_COUNT=$(grep -r "std\.debug\.print\|@import.*debug.*print" src/ 2>/dev/null | grep -v "test\|Test" | wc -l || echo 0)
if [ "$DEBUG_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Warning: Found $DEBUG_COUNT debug prints in non-test code${NC}"
fi

# Check for @panic in non-test code (unreachable is often legitimate in switch statements)
PANIC_COUNT=$(grep -r "@panic" src/ 2>/dev/null | grep -v "test\|Test" | wc -l || echo 0)
if [ "$PANIC_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Warning: Found $PANIC_COUNT @panic in non-test code${NC}"
    echo "Found @panic calls:"
    grep -r "@panic" src/ 2>/dev/null | grep -v "test\|Test" || echo "None"
fi

# Summary
echo ""
if [ "$VALIDATION_FAILED" -eq 0 ]; then
    echo -e "${GREEN}✅ All CI validation checks passed!${NC}"
else
    echo -e "${RED}❌ CI validation failed!${NC}"
    exit 1
fi

# If CI environment variable is set, export results
if [ "$CI" = "true" ]; then
    echo "CI_VALIDATION_PASSED=true" >> "$GITHUB_ENV" 2>/dev/null || true
fi