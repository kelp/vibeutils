#!/bin/bash
# Lint man pages for quality and consistency
# This script is used both locally and in GitHub Actions CI

set -e  # Exit on error

# Configuration
CI_MODE=false
FAIL_ON_WARNINGS=false
VERBOSE=false
SPECIFIC_UTILITY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ci)
            CI_MODE=true
            shift
            ;;
        --fail-on-warnings)
            FAIL_ON_WARNINGS=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --utility)
            SPECIFIC_UTILITY="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --ci                 Run in CI mode (no colors, structured output)"
            echo "  --fail-on-warnings   Exit with error code on warnings"
            echo "  --verbose, -v        Show detailed output"
            echo "  --utility NAME       Lint only specific utility"
            echo "  --help, -h           Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Colors for output (disable in CI for cleaner logs)
if [ "$CI_MODE" = true ]; then
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
fi

# Counters
total_checked=0
warnings_found=0
errors_found=0

echo -e "${GREEN}=== vibeutils Man Page Linter ===${NC}"
echo "Mode: $([ "$CI_MODE" = true ] && echo "CI" || echo "Local")"
echo "Fail on warnings: $([ "$FAIL_ON_WARNINGS" = true ] && echo "Yes" || echo "No")"
[ -n "$SPECIFIC_UTILITY" ] && echo "Target utility: $SPECIFIC_UTILITY"
echo ""

# Check for mandoc
echo "Checking for mandoc..."
if ! command -v mandoc &> /dev/null; then
    echo -e "${RED}❌ Error: mandoc is not installed${NC}"
    echo ""
    echo "Install mandoc:"
    echo "  Ubuntu/Debian: sudo apt-get install mandoc"
    echo "  macOS: brew install mandoc"
    exit 1
fi
echo -e "${GREEN}✅ mandoc found${NC}"
echo ""

# Function to lint a single man page
lint_man_page() {
    local utility="$1"
    local man_file="man/man1/${utility}.1"
    
    if [ ! -f "$man_file" ]; then
        return 1  # Missing man page handled by caller
    fi
    
    total_checked=$((total_checked + 1))
    
    # Basic file checks
    if [ ! -s "$man_file" ]; then
        echo -e "${RED}❌ Empty: $man_file${NC}"
        errors_found=$((errors_found + 1))
        return 1
    fi
    
    # mandoc syntax check
    local lint_output
    lint_output=$(mandoc -T lint "$man_file" 2>&1)
    local lint_exit_code=$?
    
    # Filter out false positives
    # - "outdated mandoc.db" warnings are about the system's man database, not our pages
    # - "referenced manual not found" for standard Unix utilities/syscalls is usually OK
    local filtered_output
    filtered_output=$(echo "$lint_output" | grep -v "outdated mandoc.db" | \
                     grep -v "STYLE: referenced manual not found: Xr" || true)
    
    if [ $lint_exit_code -eq 0 ] && [ -z "$filtered_output" ]; then
        echo -e "${GREEN}✅ $utility: Clean${NC}"
    else
        # Check if we have real errors or just warnings
        local has_real_error=false
        if echo "$filtered_output" | grep -q "ERROR:\|UNSUPP:\|FATAL:"; then
            has_real_error=true
        fi
        
        if [ "$has_real_error" = true ]; then
            echo -e "${RED}❌ $utility: Syntax errors${NC}"
            errors_found=$((errors_found + 1))
        elif [ -n "$filtered_output" ]; then
            echo -e "${YELLOW}⚠️  $utility: Warnings${NC}"
            warnings_found=$((warnings_found + 1))
        else
            echo -e "${GREEN}✅ $utility: Clean${NC}"
        fi
        
        if [ "$VERBOSE" = true ] && [ -n "$filtered_output" ]; then
            echo "$filtered_output" | sed 's/^/    /'
        elif [ "$has_real_error" = true ]; then
            echo "$filtered_output" | sed 's/^/    /'
        fi
    fi
    
    # Content quality checks (only if verbose)
    if [ "$VERBOSE" = true ]; then
        local content_warnings=0
        
        # Check for required sections
        for section in NAME SYNOPSIS DESCRIPTION; do
            if ! grep -q "^\.Sh $section" "$man_file"; then
                echo -e "${YELLOW}    Missing .$section section${NC}"
                content_warnings=$((content_warnings + 1))
            fi
        done
        
        # Check for examples
        if ! grep -q "^\.Sh EXAMPLES" "$man_file"; then
            echo -e "${BLUE}    Info: Consider adding EXAMPLES section${NC}"
        fi
        
        # Check for placeholder text
        if grep -qi "TODO\|FIXME\|XXX" "$man_file"; then
            echo -e "${YELLOW}    Contains placeholder text${NC}"
            content_warnings=$((content_warnings + 1))
        fi
        
        if [ $content_warnings -gt 0 ]; then
            warnings_found=$((warnings_found + content_warnings))
        fi
    fi
    
    return 0
}

# Function to find all utilities that should have man pages
find_utilities() {
    local utilities=()
    
    # Find utilities with single .zig files (excluding test utilities)
    for file in src/*.zig; do
        if [ -f "$file" ]; then
            utility=$(basename "$file" .zig)
            # Skip test utilities and common modules
            case "$utility" in
                benchmark_parsers|common|main)
                    continue
                    ;;
                *)
                    utilities+=("$utility")
                    ;;
            esac
        fi
    done
    
    printf '%s\n' "${utilities[@]}" | sort
}

# Main linting logic
echo "Scanning for utilities and man pages..."

if [ -n "$SPECIFIC_UTILITY" ]; then
    # Lint specific utility
    echo "Linting man page for: $SPECIFIC_UTILITY"
    echo ""
    if ! lint_man_page "$SPECIFIC_UTILITY"; then
        echo -e "${RED}❌ Missing: man/man1/${SPECIFIC_UTILITY}.1${NC}"
        errors_found=$((errors_found + 1))
    fi
else
    # Lint all utilities
    utilities=($(find_utilities))
    utilities_with_man=0
    utilities_missing_man=()
    
    echo "Found ${#utilities[@]} utilities to check"
    echo ""
    
    for utility in "${utilities[@]}"; do
        if lint_man_page "$utility"; then
            utilities_with_man=$((utilities_with_man + 1))
        else
            utilities_missing_man+=("$utility")
        fi
    done
    
    # Report missing man pages
    if [ ${#utilities_missing_man[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Missing man pages for:${NC}"
        for utility in "${utilities_missing_man[@]}"; do
            echo "  - $utility"
        done
    fi
fi

echo ""
echo -e "${BLUE}=== Linting Summary ===${NC}"
echo "Man pages checked: $total_checked"
echo "Syntax errors: $errors_found"  
echo "Warnings found: $warnings_found"

# Determine exit code
exit_code=0

if [ $errors_found -gt 0 ]; then
    echo -e "${RED}❌ FAILED: $errors_found errors found${NC}"
    exit_code=1
elif [ "$FAIL_ON_WARNINGS" = true ] && [ $warnings_found -gt 0 ]; then
    echo -e "${YELLOW}❌ FAILED: $warnings_found warnings found (fail-on-warnings enabled)${NC}"
    exit_code=1
elif [ $warnings_found -gt 0 ]; then
    echo -e "${YELLOW}⚠️  PASSED WITH WARNINGS: $warnings_found warnings found${NC}"
else
    echo -e "${GREEN}✅ PASSED: All man pages are clean${NC}"
fi

# CI-specific output
if [ "$CI_MODE" = true ]; then
    if [ $errors_found -gt 0 ]; then
        echo "::error::Man page syntax errors must be fixed"
    fi
    
    if [ $warnings_found -gt 0 ]; then
        echo "::warning::$warnings_found man page warnings found"
    fi
fi

exit $exit_code