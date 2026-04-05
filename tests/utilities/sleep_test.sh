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

    echo -e "${CYAN}Testing audit findings (wave 5)...${NC}"

    # Audit: sleep inf should be accepted (GNU sleeps forever).
    # We start the binary in the background, verify it's still running
    # after a short delay, then kill it. No external watchdog needed
    # because we always send SIGTERM ourselves.
    "$binary" inf &
    local inf_pid=$!
    sleep 0.5
    if kill -0 "$inf_pid" 2>/dev/null; then
        kill "$inf_pid" 2>/dev/null
        wait "$inf_pid" 2>/dev/null
        print_test_result "sleep inf accepted (GNU compat)" "PASS"
    else
        wait "$inf_pid" 2>/dev/null
        local inf_exit=$?
        print_test_result "sleep inf accepted (GNU compat)" "FAIL" \
            "sleep inf exited immediately with code $inf_exit"
    fi

    # Audit: sleep infinity should be accepted (GNU sleeps forever)
    "$binary" infinity &
    local infinity_pid=$!
    sleep 0.5
    if kill -0 "$infinity_pid" 2>/dev/null; then
        kill "$infinity_pid" 2>/dev/null
        wait "$infinity_pid" 2>/dev/null
        print_test_result "sleep infinity accepted (GNU compat)" "PASS"
    else
        wait "$infinity_pid" 2>/dev/null
        local infinity_exit=$?
        print_test_result "sleep infinity accepted (GNU compat)" "FAIL" \
            "sleep infinity exited immediately with code $infinity_exit"
    fi

    # Audit: error message should include the invalid token
    local sleep_err
    sleep_err=$("$binary" xyz 2>&1)
    if [[ "$sleep_err" == *"'xyz'"* ]]; then
        print_test_result "sleep error includes invalid token" "PASS"
    else
        print_test_result "sleep error includes invalid token" "FAIL" \
            "Expected 'xyz' in error, got: '$sleep_err'"
    fi
}
