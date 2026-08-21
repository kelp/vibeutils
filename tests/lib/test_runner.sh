#!/usr/bin/env bash
# Test runner for individual utility tests
# Provides execution framework for per-utility test files

set -euo pipefail

# Source common test infrastructure  
LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/flag_parser.sh"

# Run tests for a specific utility
run_utility_tests() {
    local util="$1"
    local test_file="$TESTS_DIR/utilities/${util}_test.sh"
    
    echo -e "${BLUE}Testing $util utility${NC}"
    echo "$(printf '=%.0s' $(seq 1 $((${#util} + 16))))"
    
    # Initialize test session
    init_test_session
    
    # Check if utility-specific test file exists
    if [[ -f "$test_file" ]]; then
        echo -e "${CYAN}Running utility-specific tests...${NC}"
        source "$test_file"
        
        # Call the main test function if it exists
        # Special case for [ utility since test_[ is not a valid bash function name
        local test_func="test_${util}"
        if [[ "$util" == "[" ]]; then
            test_func="test_bracket"
        fi

        if declare -f "$test_func" >/dev/null; then
            "$test_func"
        else
            echo -e "${YELLOW}Warning: No $test_func function found in $test_file${NC}"
        fi
    else
        echo -e "${YELLOW}No specific test file found at $test_file${NC}"
        echo -e "${CYAN}Running automatic flag tests...${NC}"
        
        # Run automatic flag-based tests
        run_automatic_tests "$util"
    fi
    
    # Print summary and return status
    local exit_status
    if print_test_summary "$util"; then
        exit_status=0
    else
        exit_status=1
    fi

    # Clean up temp files between utilities to ensure clean slate
    cleanup_test_session

    return $exit_status
}

# Run automatic tests based on flag parsing
run_automatic_tests() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    
    # Test binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    # Automatic flag testing (requires bash 4.0+)
    echo -e "${CYAN}Automatic flag testing...${NC}"
    if test_automatic_flags "$util"; then
        echo -e "${YELLOW}Use utility-specific test files for comprehensive flag testing${NC}"
    fi
}

# List available utilities for testing
list_available_utilities() {
    echo -e "${BLUE}Available utilities for testing:${NC}"
    echo "================================"
    
    # List utilities with specific test files
    echo -e "\n${CYAN}Utilities with specific tests:${NC}"
    if ls "$TESTS_DIR/utilities/"*_test.sh >/dev/null 2>&1; then
        for test_file in "$TESTS_DIR/utilities/"*_test.sh; do
            local util=$(basename "$test_file" "_test.sh")
            if [[ -x "$BIN_DIR/$util" ]]; then
                echo -e "  ${GREEN}✓${NC} $util"
            else
                echo -e "  ${RED}✗${NC} $util (binary not found)"
            fi
        done
    else
        echo "  None found"
    fi
    
    # List all built utilities
    echo -e "\n${CYAN}All built utilities:${NC}"
    if [[ -d "$BIN_DIR" ]]; then
        for binary in "$BIN_DIR"/*; do
            if [[ -f "$binary" && -x "$binary" ]]; then
                local util=$(basename "$binary")
                local test_file="$TESTS_DIR/utilities/${util}_test.sh"
                if [[ -f "$test_file" ]]; then
                    echo -e "  ${GREEN}✓${NC} $util (has specific tests)"
                else
                    echo -e "  ${YELLOW}○${NC} $util (automatic tests only)"
                fi
            fi
        done
    else
        echo "  No binaries found. Run 'just build' first."
    fi
    
    echo -e "\n${CYAN}Usage:${NC}"
    echo "  just it-util <utility>    # Test specific utility"
    echo "  just it                   # Test all utilities"
}

# Run tests for all utilities
run_all_utility_tests() {
    echo -e "${BLUE}Running tests for all utilities${NC}"
    echo "==============================="
    
    local total_utilities=0
    local passed_utilities=0
    local failed_utilities=()
    
    # Test utilities with specific test files first
    if ls "$TESTS_DIR/utilities/"*_test.sh >/dev/null 2>&1; then
        for test_file in "$TESTS_DIR/utilities/"*_test.sh; do
            local util=$(basename "$test_file" "_test.sh")
            if [[ -x "$BIN_DIR/$util" ]]; then
                total_utilities=$((total_utilities + 1))
                echo -e "\n${YELLOW}========================================${NC}"
                if run_utility_tests "$util"; then
                    passed_utilities=$((passed_utilities + 1))
                else
                    failed_utilities+=("$util")
                fi
            fi
        done
    fi
    
    # Test remaining utilities with automatic tests
    for binary in "$BIN_DIR"/*; do
        if [[ -f "$binary" && -x "$binary" ]]; then
            local util=$(basename "$binary")
            local test_file="$TESTS_DIR/utilities/${util}_test.sh"

            # Skip if already tested
            if [[ ! -f "$test_file" ]]; then
                total_utilities=$((total_utilities + 1))
                echo -e "\n${YELLOW}========================================${NC}"
                if run_utility_tests "$util"; then
                    passed_utilities=$((passed_utilities + 1))
                else
                    failed_utilities+=("$util")
                fi
            fi
        fi
    done
    
    # Print overall summary
    echo -e "\n${BLUE}Overall Test Summary${NC}"
    echo "===================="
    echo "Utilities tested: $total_utilities"
    echo -e "Passed: ${GREEN}$passed_utilities${NC}"
    echo -e "Failed: ${RED}$((total_utilities - passed_utilities))${NC}"
    
    if [[ ${#failed_utilities[@]} -gt 0 ]]; then
        echo -e "\n${RED}Failed utilities:${NC}"
        for util in "${failed_utilities[@]}"; do
            echo -e "  ${RED}✗${NC} $util"
        done
        return 1
    else
        echo -e "\n${GREEN}All utilities passed!${NC}"
        return 0
    fi
}