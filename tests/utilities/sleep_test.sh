#!/usr/bin/env bash
# Integration tests for sleep utility
# Tests zero sleep, fractional durations, error handling, and multiple args

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_sleep() {
    local util="sleep"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic functionality...${NC}"

    # sleep 0 should succeed immediately
    test_command_exit_code "sleep 0 succeeds" 0 "$binary" 0

    # sleep with short fractional duration should succeed
    test_command_exit_code "sleep 0.1 succeeds" 0 "$binary" 0.1

    echo -e "${CYAN}Testing multiple arguments (summed)...${NC}"

    # Multiple args should be summed (GNU extension)
    test_command_exit_code "sleep multiple args summed" 0 "$binary" 0.05 0.05

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid argument (non-numeric)
    test_command_fails "sleep invalid arg (abc)" "$binary" abc

    # Negative duration should fail
    test_command_fails "sleep negative duration (-1)" "$binary" -- -1

    # Missing operand (no arguments)
    test_command_fails "sleep missing operand" "$binary"

    # Regression test: basic operation safety net after arena allocator change
    echo -e "${CYAN}Testing sleep 0 exits immediately (arena regression)...${NC}"

    test_command_exit_code "sleep 0 exits 0 (arena safety net)" 0 "$binary" 0
}
