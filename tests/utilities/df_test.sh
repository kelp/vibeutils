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

    # Default output should show Size (human-readable is default)
    if [[ "$output" =~ "Size" ]]; then
        print_test_result "df default shows Size header" "PASS"
    else
        print_test_result "df default shows Size header" "FAIL"
    fi

    echo -e "${CYAN}Testing POSIX portability mode...${NC}"

    # -P should show 1024-blocks (POSIX mode)
    output=$("$binary" -P / 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "1024-blocks" ]]; then
        print_test_result "df -P shows 1024-blocks" "PASS"
    else
        print_test_result "df -P shows 1024-blocks" "FAIL"
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

    # ==================================================================
    # F20: POSIX -P header compliance
    # POSIX requires "1024-blocks" and "Capacity", not "1K-blocks"/"Use%"
    # ==================================================================
    echo -e "${CYAN}Testing POSIX -P header compliance...${NC}"

    output=$("$binary" -P / 2>/dev/null)
    exit_code=$?
    local header
    header=$(echo "$output" | head -1)

    # POSIX mandates "1024-blocks", not "1K-blocks"
    if [[ $exit_code -eq 0 && "$header" =~ "1024-blocks" ]]; then
        print_test_result "df -P header has POSIX 1024-blocks" "PASS"
    else
        print_test_result "df -P header has POSIX 1024-blocks" "FAIL" \
            "Header: $header"
    fi

    # POSIX mandates "Capacity", not "Use%"
    if [[ $exit_code -eq 0 && "$header" =~ "Capacity" ]]; then
        print_test_result "df -P header has POSIX Capacity" "PASS"
    else
        print_test_result "df -P header has POSIX Capacity" "FAIL" \
            "Header: $header"
    fi

    # ==================================================================
    # F21: df -n should be rejected on Linux (not a GNU flag)
    # ==================================================================
    if [[ "$(uname)" == "Linux" ]]; then
        echo -e "${CYAN}Testing -n rejected on Linux...${NC}"

        "$binary" -n / >/dev/null 2>&1
        exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            print_test_result "df -n rejected on Linux (exit 2)" "PASS"
        else
            print_test_result "df -n rejected on Linux (exit 2)" "FAIL" \
                "Exit code: $exit_code (expected 2)"
        fi
    fi

    # ==================================================================
    # F19: df -I without argument should work on macOS
    # ==================================================================
    if [[ "$(uname)" == "Darwin" ]]; then
        echo -e "${CYAN}Testing -I as boolean on macOS...${NC}"

        output=$("$binary" -I / 2>/dev/null)
        exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            print_test_result "df -I without arg succeeds on macOS" "PASS"
        else
            print_test_result "df -I without arg succeeds on macOS" "FAIL" \
                "Exit code: $exit_code (expected 0)"
        fi
    fi
}
