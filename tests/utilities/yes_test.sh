#!/usr/bin/env bash
# Integration tests for yes utility
# Tests default output, custom strings, multiple args, and SIGPIPE handling
#
# CRITICAL: yes runs forever, so ALL tests pipe through head -n 1 or similar.
# Uses set +o pipefail before piped yes commands to handle SIGPIPE gracefully.

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_yes() {
    local util="yes"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output is "y"
    local output
    set +o pipefail
    output=$("$binary" | head -n 1)
    set -o pipefail
    if [[ "$output" == "y" ]]; then
        print_test_result "yes default output is y" "PASS"
    else
        print_test_result "yes default output is y" "FAIL" \
            "Expected 'y', got '$output'"
    fi

    echo -e "${CYAN}Testing custom string...${NC}"

    # Single custom string
    set +o pipefail
    output=$("$binary" "hello" | head -n 1)
    set -o pipefail
    if [[ "$output" == "hello" ]]; then
        print_test_result "yes custom string" "PASS"
    else
        print_test_result "yes custom string" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    echo -e "${CYAN}Testing multiple arguments...${NC}"

    # Multiple args joined with spaces
    set +o pipefail
    output=$("$binary" hello world | head -n 1)
    set -o pipefail
    if [[ "$output" == "hello world" ]]; then
        print_test_result "yes multiple args joined" "PASS"
    else
        print_test_result "yes multiple args joined" "FAIL" \
            "Expected 'hello world', got '$output'"
    fi

    echo -e "${CYAN}Testing SIGPIPE handling...${NC}"

    # yes should exit cleanly when the pipe breaks
    local exit_code
    set +o pipefail
    "$binary" | head -n 1 >/dev/null 2>&1
    exit_code=$?
    set -o pipefail
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "yes clean exit on broken pipe" "PASS"
    else
        print_test_result "yes clean exit on broken pipe" "FAIL" \
            "Expected exit code 0, got $exit_code"
    fi

    # Regression test: strings > 8192 bytes must produce output
    echo -e "${CYAN}Testing large string output...${NC}"

    local large_string
    large_string=$(printf 'A%.0s' $(seq 1 9000))
    set +o pipefail
    output=$("$binary" "$large_string" | head -n 1)
    set -o pipefail
    if [[ ${#output} -eq 9000 && "$output" == "$large_string" ]]; then
        print_test_result "yes large string (9000 chars)" "PASS"
    else
        print_test_result "yes large string (9000 chars)" "FAIL" \
            "Expected 9000 chars, got ${#output} chars"
    fi
}
