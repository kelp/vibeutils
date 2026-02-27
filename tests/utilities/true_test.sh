#!/usr/bin/env bash
# Integration tests for true utility
# Tests exit code, no output, and argument handling

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_true() {
    local util="true"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags (special handling for true in common.sh)
    test_basic_flags "$util"

    echo -e "${CYAN}Testing exit code...${NC}"

    # Exit code should be 0
    "$binary" >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "true exits with code 0" "PASS"
    else
        print_test_result "true exits with code 0" "FAIL" \
            "Expected exit code 0, got $exit_code"
    fi

    echo -e "${CYAN}Testing no output...${NC}"

    # No output on stdout
    local stdout_output
    stdout_output=$("$binary" 2>/dev/null)
    if [[ -z "$stdout_output" ]]; then
        print_test_result "true no stdout output" "PASS"
    else
        print_test_result "true no stdout output" "FAIL" \
            "Expected empty stdout, got '$stdout_output'"
    fi

    # No output on stderr
    local stderr_output
    stderr_output=$("$binary" 2>&1 >/dev/null)
    if [[ -z "$stderr_output" ]]; then
        print_test_result "true no stderr output" "PASS"
    else
        print_test_result "true no stderr output" "FAIL" \
            "Expected empty stderr, got '$stderr_output'"
    fi

    echo -e "${CYAN}Testing argument handling...${NC}"

    # Ignores arguments and still exits 0
    "$binary" --some-flag >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "true ignores --some-flag" "PASS"
    else
        print_test_result "true ignores --some-flag" "FAIL" \
            "Expected exit code 0, got $exit_code"
    fi

    "$binary" arg1 arg2 arg3 >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "true ignores positional args" "PASS"
    else
        print_test_result "true ignores positional args" "FAIL" \
            "Expected exit code 0, got $exit_code"
    fi

    "$binary" -x -y --foo=bar baz >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "true ignores mixed args" "PASS"
    else
        print_test_result "true ignores mixed args" "FAIL" \
            "Expected exit code 0, got $exit_code"
    fi
}
