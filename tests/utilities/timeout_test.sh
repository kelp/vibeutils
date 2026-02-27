#!/usr/bin/env bash
# Integration tests for timeout utility
# Tests timeout behavior, signal handling, exit codes, and options

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_timeout() {
    local util="timeout"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing command completes before timeout...${NC}"

    # Command that finishes quickly
    test_command_exit_code "timeout command succeeds" 0 "$binary" 10 true

    # Command that fails before timeout
    test_command_exit_code "timeout command fails" 1 "$binary" 10 false

    echo -e "${CYAN}Testing timeout behavior...${NC}"

    # Command that times out (sleep 60 with 0.5s timeout)
    test_command_exit_code "timeout kills slow command" 124 "$binary" 0.5 sleep 60

    echo -e "${CYAN}Testing zero timeout...${NC}"

    # Zero timeout disables the timeout
    test_command_exit_code "timeout 0 disables timeout" 0 "$binary" 0 true

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Missing operand
    test_command_fails "timeout missing operand" "$binary"

    # Missing command
    "$binary" 5 >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 125 ]]; then
        print_test_result "timeout missing command" "PASS"
    else
        print_test_result "timeout missing command" "FAIL" \
            "Expected exit 125, got $exit_code"
    fi

    # Invalid duration
    "$binary" abc true >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 125 ]]; then
        print_test_result "timeout invalid duration" "PASS"
    else
        print_test_result "timeout invalid duration" "FAIL" \
            "Expected exit 125, got $exit_code"
    fi

    # Command not found
    "$binary" 1 /nonexistent/command >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 127 ]]; then
        print_test_result "timeout command not found" "PASS"
    else
        print_test_result "timeout command not found" "FAIL" \
            "Expected exit 127, got $exit_code"
    fi

    echo -e "${CYAN}Testing signal options...${NC}"

    # Custom signal name
    test_command_exit_code "timeout with -s KILL" 137 "$binary" -s KILL 0.5 sleep 60

    # Preserve status
    "$binary" --preserve-status 0.5 sleep 60 >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 143 ]]; then
        print_test_result "timeout --preserve-status" "PASS"
    else
        print_test_result "timeout --preserve-status" "FAIL" \
            "Expected exit 143 (128+TERM), got $exit_code"
    fi

    echo -e "${CYAN}Testing duration suffixes...${NC}"

    # Test with seconds suffix
    test_command_exit_code "timeout with seconds suffix" 0 "$binary" 10s true

    # Test with fractional duration
    test_command_exit_code "timeout with fractional duration" 0 "$binary" 0.5 true
}
