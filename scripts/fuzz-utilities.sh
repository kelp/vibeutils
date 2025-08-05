#!/bin/bash
# Selective fuzzing script for vibeutils
# This script allows fuzzing individual utilities or all utilities with time limits

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_TIMEOUT=300  # 5 minutes per utility
DEFAULT_ITERATIONS=10000

# All available utilities
UTILITIES=(
    "basename" "cat" "chmod" "chown" "cp" "dirname" "echo" "false" 
    "head" "ln" "ls" "mkdir" "mv" "pwd" "rm" "rmdir" "sleep" 
    "tail" "test" "touch" "true" "yes"
)

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [UTILITY_NAME|all]

Selective fuzzing for vibeutils. Only works on Linux.

ARGUMENTS:
    UTILITY_NAME        Name of the utility to fuzz (e.g., cat, ls, echo)
    all                 Fuzz all utilities sequentially

OPTIONS:
    -t, --timeout SECS  Timeout per utility in seconds (default: $DEFAULT_TIMEOUT)
    -i, --iterations N  Number of iterations per utility (default: $DEFAULT_ITERATIONS)
    -l, --list          List all available utilities
    -r, --rotate        Rotate through all utilities with time limits
    -h, --help          Show this help message

EXAMPLES:
    $0 cat                          # Fuzz only the cat utility
    $0 all                          # Fuzz all utilities sequentially  
    $0 -t 120 echo                  # Fuzz echo for 2 minutes
    $0 -r -t 60                     # Rotate through all utilities, 1 minute each
    $0 --list                       # List all available utilities

ENVIRONMENT:
    The script sets VIBEUTILS_FUZZ_TARGET internally. Do not set this manually.

REQUIREMENTS:
    - Linux operating system (fuzzing only works on Linux)
    - Zig build system configured
    - vibeutils project built and ready for testing

EXIT CODES:
    0   Success
    1   General error (wrong OS, invalid arguments, etc.)
    2   Build/test failure
    3   Timeout (when using --timeout)
EOF
}

# Check if we're on Linux
check_linux() {
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        echo -e "${RED}Error: Fuzzing only works on Linux${NC}" >&2
        echo "Current OS: $OSTYPE" >&2
        exit 1
    fi
}

# List all available utilities
list_utilities() {
    echo -e "${BLUE}Available utilities for fuzzing:${NC}"
    for util in "${UTILITIES[@]}"; do
        echo "  $util"
    done
    echo
    echo "Total: ${#UTILITIES[@]} utilities"
}

# Validate that a utility name is valid
validate_utility() {
    local util="$1"
    for valid_util in "${UTILITIES[@]}"; do
        if [[ "$util" == "$valid_util" ]]; then
            return 0
        fi
    done
    echo -e "${RED}Error: Unknown utility '$util'${NC}" >&2
    echo -e "${YELLOW}Use '$0 --list' to see available utilities${NC}" >&2
    return 1
}

# Fuzz a single utility
fuzz_utility() {
    local util="$1"
    local timeout="$2"
    local iterations="$3"
    
    echo -e "${BLUE}Fuzzing $util...${NC}"
    echo "  Timeout: ${timeout}s"
    echo "  Max iterations: $iterations"
    
    # Set environment variable for selective fuzzing
    export VIBEUTILS_FUZZ_TARGET="$util"
    
    # Build the project first
    echo -e "${YELLOW}Building project...${NC}"
    if ! zig build > /dev/null 2>&1; then
        echo -e "${RED}Build failed for utility: $util${NC}" >&2
        return 2
    fi
    
    # Run the fuzz test with timeout
    local start_time=$(date +%s)
    echo -e "${GREEN}Starting fuzz test for $util${NC}"
    
    if timeout "${timeout}s" zig build test --fuzz 2>&1 | tee "fuzz_${util}_$(date +%Y%m%d_%H%M%S).log"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo -e "${GREEN}✓ Fuzz test completed for $util (${duration}s)${NC}"
        return 0
    else
        local exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ $exit_code -eq 124 ]]; then
            echo -e "${YELLOW}⚠ Fuzz test timed out for $util after ${duration}s${NC}"
            return 3
        else
            echo -e "${RED}✗ Fuzz test failed for $util (${duration}s, exit code: $exit_code)${NC}" >&2
            return 2
        fi
    fi
}

# Fuzz all utilities sequentially
fuzz_all() {
    local timeout="$1"
    local iterations="$2"
    local failed_utils=()
    local timeout_utils=()
    local success_utils=()
    
    echo -e "${BLUE}Fuzzing all ${#UTILITIES[@]} utilities...${NC}"
    echo
    
    local total_start=$(date +%s)
    
    for util in "${UTILITIES[@]}"; do
        echo -e "${BLUE}━━━ Fuzzing $util ($(date '+%H:%M:%S')) ━━━${NC}"
        
        if fuzz_utility "$util" "$timeout" "$iterations"; then
            success_utils+=("$util")
        else
            local exit_code=$?
            if [[ $exit_code -eq 3 ]]; then
                timeout_utils+=("$util")
            else
                failed_utils+=("$util")
            fi
        fi
        echo
    done
    
    local total_end=$(date +%s)
    local total_duration=$((total_end - total_start))
    
    # Summary report
    echo -e "${BLUE}━━━ FUZZING SUMMARY ━━━${NC}"
    echo "Total time: ${total_duration}s"
    echo
    
    if [[ ${#success_utils[@]} -gt 0 ]]; then
        echo -e "${GREEN}✓ Successful (${#success_utils[@]}):${NC}"
        printf '  %s\n' "${success_utils[@]}"
        echo
    fi
    
    if [[ ${#timeout_utils[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠ Timed out (${#timeout_utils[@]}):${NC}"
        printf '  %s\n' "${timeout_utils[@]}"
        echo
    fi
    
    if [[ ${#failed_utils[@]} -gt 0 ]]; then
        echo -e "${RED}✗ Failed (${#failed_utils[@]}):${NC}"
        printf '  %s\n' "${failed_utils[@]}"
        echo
        return 2
    fi
    
    if [[ ${#timeout_utils[@]} -gt 0 ]]; then
        return 3
    fi
    
    return 0
}

# Rotate through utilities with time limits (useful for continuous fuzzing)
rotate_fuzz() {
    local timeout="$1"
    local iterations="$2"
    
    echo -e "${BLUE}Rotating fuzzing through all utilities (${timeout}s each)${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
    echo
    
    local round=1
    while true; do
        echo -e "${BLUE}━━━ ROUND $round ━━━${NC}"
        
        for util in "${UTILITIES[@]}"; do
            echo -e "${BLUE}[Round $round] Fuzzing $util${NC}"
            fuzz_utility "$util" "$timeout" "$iterations" || true
            echo
        done
        
        ((round++))
        echo -e "${GREEN}Round $round completed. Starting next round...${NC}"
        sleep 2
    done
}

# Parse command line arguments
timeout="$DEFAULT_TIMEOUT"
iterations="$DEFAULT_ITERATIONS"
list_only=false
rotate_mode=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--timeout)
            if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                timeout="$2"
                shift 2
            else
                echo -e "${RED}Error: --timeout requires a numeric argument${NC}" >&2
                exit 1
            fi
            ;;
        -i|--iterations)
            if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                iterations="$2"
                shift 2
            else
                echo -e "${RED}Error: --iterations requires a numeric argument${NC}" >&2
                exit 1
            fi
            ;;
        -l|--list)
            list_only=true
            shift
            ;;
        -r|--rotate)
            rotate_mode=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            echo -e "${YELLOW}Use '$0 --help' for usage information${NC}" >&2
            exit 1
            ;;
        *)
            if [[ -z "${target_utility:-}" ]]; then
                target_utility="$1"
            else
                echo -e "${RED}Error: Multiple utility names specified${NC}" >&2
                echo -e "${YELLOW}Use '$0 --help' for usage information${NC}" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Main execution
main() {
    check_linux
    
    if $list_only; then
        list_utilities
        exit 0
    fi
    
    if $rotate_mode; then
        rotate_fuzz "$timeout" "$iterations"
        exit 0
    fi
    
    if [[ -z "${target_utility:-}" ]]; then
        echo -e "${RED}Error: No utility specified${NC}" >&2
        echo -e "${YELLOW}Use '$0 --help' for usage information${NC}" >&2
        exit 1
    fi
    
    if [[ "$target_utility" == "all" ]]; then
        fuzz_all "$timeout" "$iterations"
    else
        validate_utility "$target_utility"
        fuzz_utility "$target_utility" "$timeout" "$iterations"
    fi
}

# Handle Ctrl+C gracefully
trap 'echo -e "\n${YELLOW}Fuzzing interrupted by user${NC}"; exit 130' INT

# Run main function
main "$@"