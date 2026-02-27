#!/usr/bin/env bash
# Integration tests for df utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_df() {
    local util="df"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output should contain header fields
    local output
    output=$("$binary" 2>/dev/null)
    local exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Filesystem" && "$output" =~ "Mounted on" ]]; then
        print_test_result "df default output has expected header" "PASS"
    else
        print_test_result "df default output has expected header" "FAIL" \
            "Exit code: $exit_code"
    fi

    # Default output should show 1K-blocks
    if [[ "$output" =~ "1K-blocks" ]]; then
        print_test_result "df default shows 1K-blocks" "PASS"
    else
        print_test_result "df default shows 1K-blocks" "FAIL"
    fi

    echo -e "${CYAN}Testing specific path...${NC}"

    # df / should show root filesystem
    output=$("$binary" / 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "/" ]]; then
        print_test_result "df / shows root filesystem" "PASS"
    else
        print_test_result "df / shows root filesystem" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing human-readable output...${NC}"

    # -h should show Size header instead of 1K-blocks
    output=$("$binary" -h 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Size" ]]; then
        print_test_result "df -h shows Size header" "PASS"
    else
        print_test_result "df -h shows Size header" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing type display...${NC}"

    # -T should show Type column
    output=$("$binary" -T 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Type" ]]; then
        print_test_result "df -T shows Type column" "PASS"
    else
        print_test_result "df -T shows Type column" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing inode display...${NC}"

    # -i should show Inodes header
    output=$("$binary" -i 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Inodes" ]]; then
        print_test_result "df -i shows Inodes header" "PASS"
    else
        print_test_result "df -i shows Inodes header" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing --total flag...${NC}"

    # --total should include a "total" row
    output=$("$binary" --total 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "total" ]]; then
        print_test_result "df --total shows total row" "PASS"
    else
        print_test_result "df --total shows total row" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "df invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    # Nonexistent file exits with code 1
    test_command_exit_code "df nonexistent file exits 1" 1 \
        "$binary" /nonexistent/path/file
}
